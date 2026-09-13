mod layout;
pub mod sequence;

use layout::{
    encode_error_tape, DocumentDelta, LayoutContext, LayoutDocument, LayoutTape, RetainedDocument,
    RetainedFrame, SourceChanges, TapeIdentity, TapeOutputOptions, MAX_LAYOUT_DIMENSION,
    MIN_TAPE_BYTES,
};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet, VecDeque};
use std::ffi::c_void;
use std::os::raw::c_int;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

const CONTROL_VERSION: u32 = 1;
const MAX_CONTROL_BYTES: usize = 64 * 1024 * 1024;
const SYNC_RENDER_MAX_RESULT_BYTES: usize = 64 * 1024 * 1024;
const SYNC_RENDER_SESSION_ID: u64 = u64::MAX;
static NEXT_SESSION_ID: AtomicU64 = AtomicU64::new(1);

fn default_true() -> bool {
    true
}

#[repr(C)]
pub struct NativeBytes {
    data: *mut u8,
    len: usize,
}

impl NativeBytes {
    fn empty() -> Self {
        Self {
            data: ptr::null_mut(),
            len: 0,
        }
    }

    fn from_vec(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self::empty();
        }
        let boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        let data = Box::into_raw(boxed) as *mut u8;
        Self { data, len }
    }

    fn from_error(message: impl Into<String>) -> Self {
        Self::from_vec(message.into().into_bytes())
    }
}

/// One already-normalized flex item crossing the pure geometry boundary.
///
/// Ebox owns the node identity, style cascade, display measurement, and
/// rendering.  The native kernel receives only integer geometry facts and
/// numeric distribution factors, then returns target main-axis sizes.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct NativeFlexItem {
    pub base: i64,
    pub hypothetical: i64,
    pub min_main: i64,
    pub max_main: i64,
    pub grow: f64,
    pub shrink: f64,
    pub max_known: bool,
}

const MAX_FLEX_ITEMS: usize = 8192;
const MAX_FLEX_LINES: usize = 2048;

fn flex_distribute(amount: i64, weights: &[f64]) -> Vec<i64> {
    let amount = amount.max(0);
    let total: f64 = weights.iter().copied().filter(|weight| *weight > 0.0).sum();
    if amount == 0 || total <= 0.0 {
        return vec![0; weights.len()];
    }
    let mut shares = weights
        .iter()
        .map(|weight| {
            if *weight > 0.0 {
                ((amount as f64 * *weight) / total).floor() as i64
            } else {
                0
            }
        })
        .collect::<Vec<_>>();
    let mut remaining = amount - shares.iter().sum::<i64>();
    while remaining > 0 {
        for (share, weight) in shares.iter_mut().zip(weights.iter()) {
            if remaining == 0 {
                break;
            }
            if *weight > 0.0 {
                *share += 1;
                remaining -= 1;
            }
        }
    }
    shares
}

fn clamp_flex_main(size: i64, min_main: i64, max_main: Option<i64>) -> i64 {
    let size = size.max(0);
    let min_main = min_main.max(0);
    let upper = max_main.unwrap_or(999_999_999).max(0);
    min_main.max(upper.min(size))
}

fn flex_size_line(items: &[NativeFlexItem], main_limit: i64, main_gap: i64) -> Vec<i64> {
    let count = items.len();
    let gap_total = main_gap * (count.saturating_sub(1) as i64);
    let available = main_limit - gap_total;
    let mut targets = items
        .iter()
        .map(|item| item.hypothetical)
        .collect::<Vec<_>>();
    let hypothetical_total = items.iter().map(|item| item.hypothetical).sum::<i64>();
    let grow = hypothetical_total < available;
    let mut frozen = vec![false; count];

    for (index, item) in items.iter().enumerate() {
        let factor = if grow { item.grow } else { item.shrink };
        targets[index] = item.base;
        if factor <= 0.0
            || (grow && item.base > item.hypothetical)
            || (!grow && item.base < item.hypothetical)
        {
            targets[index] = item.hypothetical;
            frozen[index] = true;
        }
    }

    let initial_free = available
        - items
            .iter()
            .enumerate()
            .map(|(index, item)| {
                if frozen[index] {
                    targets[index]
                } else {
                    item.base
                }
            })
            .sum::<i64>();
    loop {
        let free = available
            - items
                .iter()
                .enumerate()
                .map(|(index, item)| {
                    if frozen[index] {
                        targets[index]
                    } else {
                        item.base
                    }
                })
                .sum::<i64>();
        let active = (0..count)
            .filter(|index| !frozen[*index])
            .collect::<Vec<_>>();
        let weights = active
            .iter()
            .map(|index| {
                let item = items[*index];
                if grow {
                    item.grow
                } else {
                    item.base as f64 * item.shrink
                }
            })
            .collect::<Vec<_>>();
        let weight_total: f64 = weights.iter().copied().sum();
        let factor_total: f64 = active
            .iter()
            .map(|index| {
                let item = items[*index];
                if grow {
                    item.grow
                } else {
                    item.shrink
                }
            })
            .sum();
        let effective_free = if factor_total > 0.0 && factor_total < 1.0 {
            let partial = initial_free as f64 * factor_total;
            if partial.abs() < (free as f64).abs() {
                partial
            } else {
                free as f64
            }
        } else {
            free as f64
        };
        if active.is_empty()
            || weight_total <= 0.0
            || (grow && effective_free < 0.0)
            || (!grow && effective_free > 0.0)
        {
            break;
        }

        let deltas = flex_distribute(effective_free.abs().floor() as i64, &weights);
        let mut min_violations = Vec::new();
        let mut max_violations = Vec::new();
        let mut total_violation = 0i64;
        for (active_offset, index) in active.iter().enumerate() {
            let item = items[*index];
            let candidate = if grow {
                item.base + deltas[active_offset]
            } else {
                item.base - deltas[active_offset]
            };
            let clamped = clamp_flex_main(
                candidate,
                item.min_main,
                item.max_known.then_some(item.max_main),
            );
            let adjustment = clamped - candidate;
            targets[*index] = clamped;
            if adjustment > 0 {
                min_violations.push(*index);
            } else if adjustment < 0 {
                max_violations.push(*index);
            }
            total_violation += adjustment;
        }
        if total_violation == 0 {
            for index in active {
                frozen[index] = true;
            }
        } else if total_violation > 0 {
            let indices = if min_violations.is_empty() {
                active
            } else {
                min_violations
            };
            for index in indices {
                frozen[index] = true;
            }
        } else {
            let indices = if max_violations.is_empty() {
                active
            } else {
                max_violations
            };
            for index in indices {
                frozen[index] = true;
            }
        }
    }
    targets
}

/// Calculate all flex line target sizes without touching Ebox state.
///
/// `line_offsets` contains `line_count + 1` offsets into ITEMS.  The output
/// is a little-endian i64 stream whose values follow the input line order.
///
/// # Safety
///
/// Nonempty ITEMS and LINE_OFFSETS must reference their declared readable
/// lengths, and OUTPUT must point to writable `NativeBytes` storage.
#[no_mangle]
pub unsafe extern "C" fn ebox_native_flex_size_lines(
    items: *const NativeFlexItem,
    item_count: usize,
    line_offsets: *const usize,
    line_count: usize,
    main_limit: i64,
    main_gap: i64,
    output: *mut NativeBytes,
) -> bool {
    if output.is_null()
        || (item_count > 0 && items.is_null())
        || (line_count > 0 && line_offsets.is_null())
        || item_count > MAX_FLEX_ITEMS
        || line_count > MAX_FLEX_LINES
        || !(-MAX_LAYOUT_DIMENSION..=MAX_LAYOUT_DIMENSION).contains(&main_limit)
        || !(0..=MAX_LAYOUT_DIMENSION).contains(&main_gap)
    {
        set_error(
            output,
            "Native flex geometry input is outside the bounded contract",
        );
        return false;
    }
    let items = slice::from_raw_parts(items, item_count);
    let offsets = slice::from_raw_parts(line_offsets, line_count.saturating_add(1));
    if offsets.first().copied().unwrap_or(0) != 0
        || offsets.last().copied().unwrap_or(0) != item_count
        || offsets.windows(2).any(|window| window[0] > window[1])
    {
        set_error(output, "Native flex geometry line offsets are invalid");
        return false;
    }
    if items.iter().any(|item| {
        !item.grow.is_finite() || !item.shrink.is_finite() || item.grow < 0.0 || item.shrink < 0.0
    }) {
        set_error(output, "Native flex geometry factors are invalid");
        return false;
    }
    let mut bytes = Vec::with_capacity(item_count.saturating_mul(8));
    for window in offsets.windows(2).take(line_count) {
        for target in flex_size_line(&items[window[0]..window[1]], main_limit, main_gap) {
            bytes.extend_from_slice(&target.to_le_bytes());
        }
    }
    unsafe {
        *output = NativeBytes::from_vec(bytes);
    }
    true
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ControlBatch {
    version: u32,
    #[serde(default)]
    document: Option<LayoutDocument>,
    #[serde(default, rename = "document-delta")]
    document_delta: Option<DocumentDelta>,
    #[serde(default, rename = "document-base-revision")]
    document_base_revision: Option<u64>,
    #[serde(default, rename = "document-target-revision")]
    document_target_revision: Option<u64>,
    frames: Vec<ControlFrame>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct ControlFrame {
    key: i64,
    #[serde(default)]
    payload: Option<String>,
    #[serde(default)]
    viewport_width: Option<i64>,
    #[serde(default = "default_true")]
    viewport_width_known: bool,
    #[serde(default)]
    viewport_height: Option<i64>,
    #[serde(default)]
    root_width: Option<i64>,
    #[serde(default)]
    root_width_override: bool,
    #[serde(default)]
    patch: bool,
    #[serde(default)]
    base_viewport_width: Option<i64>,
    #[serde(default = "default_true")]
    base_viewport_width_known: bool,
    #[serde(default)]
    base_viewport_height: Option<i64>,
    #[serde(default)]
    base_root_width: Option<i64>,
    #[serde(default)]
    base_root_width_override: bool,
    #[serde(default)]
    runtime_revision: u64,
    #[serde(default)]
    context_hash: i64,
    #[serde(default = "default_true")]
    complete: bool,
    #[serde(default = "default_true")]
    root_metadata: bool,
    #[serde(default)]
    root_scroll_producer: bool,
    #[serde(default)]
    delay_ms: u64,
}

#[derive(Debug)]
enum JobPayload {
    Echo(Vec<u8>),
    Layout {
        document: LayoutSource,
        source_changes: Option<SourceChanges>,
        context: LayoutContext,
        root_width: i64,
        root_width_override: bool,
        base_context: Option<LayoutContext>,
        base_root_width: i64,
        base_root_width_override: bool,
        runtime_revision: u64,
        context_hash: i64,
        complete: bool,
        root_metadata: bool,
        root_scroll_producer: bool,
        document_base_revision: u64,
        document_target_revision: u64,
        validation_resolver_lookups: u64,
    },
}

#[derive(Clone, Debug)]
enum LayoutSource {
    Full(Arc<LayoutDocument>),
    Retained(Arc<RetainedDocument>),
}

impl LayoutSource {
    fn validate_context(&self, context: LayoutContext) -> Result<(), String> {
        match self {
            Self::Full(document) => document.validate_context(context),
            Self::Retained(document) => document.validate_context(context),
        }
    }

    fn layout_tape(
        &self,
        context: LayoutContext,
        root_width: Option<i64>,
    ) -> Result<LayoutTape, String> {
        match self {
            Self::Full(document) => document.layout_tape(context, root_width),
            Self::Retained(document) => document.layout_tape(context, root_width),
        }
    }

    fn styles(&self) -> Result<Vec<layout::StyleTemplate>, String> {
        match self {
            Self::Full(document) => Ok(document.styles.clone()),
            Self::Retained(document) => document.styles(),
        }
    }

    fn render_target(
        &self,
        context: LayoutContext,
        root_width: Option<i64>,
        previous: Option<&RetainedFrame>,
        changes: Option<&SourceChanges>,
        root_scroll_producer: bool,
    ) -> Result<(LayoutTape, Option<Arc<RetainedFrame>>), String> {
        match self {
            Self::Full(document) => {
                if changes.is_some() {
                    return Err("Native source changes require a retained document".to_owned());
                }
                Ok((document.layout_tape(context, root_width)?, None))
            }
            Self::Retained(document) => {
                let frame = if root_scroll_producer {
                    document
                        .render_frame_with_root_scroll(previous, changes, context, root_width)?
                } else {
                    document.render_frame(previous, changes, context, root_width)?
                };
                Ok((frame.materialize_tape(), Some(frame)))
            }
        }
    }
}

#[derive(Clone, Debug)]
struct BaselineIdentity {
    context: LayoutContext,
    root_width: i64,
    root_width_override: bool,
    runtime_revision: u64,
    context_hash: i64,
    complete: bool,
}

#[derive(Clone, Debug)]
struct ConfirmedBaseline {
    identity: BaselineIdentity,
    document: LayoutSource,
    document_revision: u64,
    tape: LayoutTape,
    retained_frame: Option<Arc<RetainedFrame>>,
    styles: Vec<layout::StyleTemplate>,
}

#[derive(Debug)]
struct PendingBaseline {
    confirmed_identity: BaselineIdentity,
    document: LayoutSource,
    document_revision: u64,
    tape: LayoutTape,
    retained_frame: Option<Arc<RetainedFrame>>,
    styles: Vec<layout::StyleTemplate>,
}

#[derive(Debug)]
struct ResultEntry {
    bytes: Vec<u8>,
}

#[derive(Debug)]
struct RenderedJob {
    bytes: Vec<u8>,
    pending: Option<PendingBaseline>,
    baseline_hit: bool,
    base_renders: u64,
    target_renders: u64,
    resolver_lookups: u64,
    atom_plan_work: layout::AtomPlanWork,
    line_plan_work: layout::LinePlanWork,
    eval_work: layout::EvalWork,
}

#[derive(Default)]
struct DocumentInputStats {
    parses: u64,
    validations: u64,
    reuses: u64,
    full_input_bytes: u64,
    delta_input_bytes: u64,
    full_nodes_parsed: u64,
    delta_entries_parsed: u64,
    delta_entries_validated: u64,
    trie_path_nodes_copied: u64,
    source_change_work: layout::SourceChangeWork,
}

#[derive(Debug)]
struct Job {
    generation: u64,
    key: i64,
    payload: JobPayload,
    delay_ms: u64,
}

#[derive(Debug)]
struct PreparedJob {
    key: i64,
    delay_ms: u64,
    payload: JobPayload,
}

#[derive(Debug)]
struct RuntimeState {
    jobs: VecDeque<Job>,
    results: HashMap<(u64, i64), ResultEntry>,
    pending_baselines: HashMap<(u64, i64), PendingBaseline>,
    result_bytes: usize,
    stale_drops: u64,
    completed_jobs: u64,
    baseline_hits: u64,
    baseline_misses: u64,
    base_renders: u64,
    target_renders: u64,
    document_parses: u64,
    document_validations: u64,
    document_reuses: u64,
    document_full_input_bytes: u64,
    document_delta_input_bytes: u64,
    document_full_nodes_parsed: u64,
    document_delta_entries_parsed: u64,
    document_delta_entries_validated: u64,
    document_trie_path_nodes_copied: u64,
    document_resolver_lookups: u64,
    source_change_work: layout::SourceChangeWork,
    atom_plan_work: layout::AtomPlanWork,
    line_plan_work: layout::LinePlanWork,
    eval_work: layout::EvalWork,
    confirmed_baseline: Option<Arc<ConfirmedBaseline>>,
}

#[derive(Clone, Copy, Debug)]
struct ReadinessChannel {
    fd: c_int,
    signal: extern "C" fn(c_int) -> bool,
    close: extern "C" fn(c_int),
}

#[derive(Debug)]
struct Shared {
    id: u64,
    alive: AtomicBool,
    generation: AtomicU64,
    max_jobs: usize,
    max_results: usize,
    max_result_bytes: usize,
    state: Mutex<RuntimeState>,
    readiness_channel: Mutex<Option<ReadinessChannel>>,
    job_available: Condvar,
    result_available: Condvar,
}

impl Shared {
    fn request_stop(&self) {
        // Both worker condition variables inspect `alive` under this mutex.
        // Publish shutdown under the same lock so notification cannot fall
        // between a worker's predicate check and its atomic unlock-and-wait.
        {
            let _state = self
                .state
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            self.alive.store(false, Ordering::Release);
        }
        self.job_available.notify_all();
        self.result_available.notify_all();
    }
}

#[derive(Debug)]
struct Session {
    shared: Arc<Shared>,
    workers: Mutex<Option<Vec<JoinHandle<()>>>>,
    layout_document: Mutex<Option<LayoutSource>>,
    worker_count: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "kebab-case")]
struct SessionStats {
    session_id: u64,
    workers: usize,
    queued_jobs: usize,
    ready_results: usize,
    result_bytes: usize,
    max_jobs: usize,
    max_results: usize,
    max_result_bytes: usize,
    generation: u64,
    stale_drops: u64,
    completed_jobs: u64,
    baseline_hits: u64,
    baseline_misses: u64,
    base_renders: u64,
    target_renders: u64,
    document_parses: u64,
    document_validations: u64,
    document_reuses: u64,
    document_full_input_bytes: u64,
    document_delta_input_bytes: u64,
    document_full_nodes_parsed: u64,
    document_delta_entries_parsed: u64,
    document_delta_entries_validated: u64,
    document_trie_path_nodes_copied: u64,
    document_resolver_lookups: u64,
    source_change_work: layout::SourceChangeWork,
    atom_plan_work: layout::AtomPlanWork,
    line_plan_work: layout::LinePlanWork,
    eval_work: layout::EvalWork,
    pending_baselines: usize,
    confirmed_baseline: bool,
    confirmed_baseline_bytes: usize,
    layout_registered: bool,
    alive: bool,
}

impl Shared {
    fn signal_readiness(&self) {
        let mut readiness_channel = self
            .readiness_channel
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if let Some(channel) = *readiness_channel {
            if !(channel.signal)(channel.fd) {
                (channel.close)(channel.fd);
                *readiness_channel = None;
            }
        }
    }
}

impl Session {
    fn new(
        workers: usize,
        max_jobs: usize,
        max_results: usize,
        max_result_bytes: usize,
    ) -> Result<Box<Self>, String> {
        Self::new_with_confirmed_baseline(workers, max_jobs, max_results, max_result_bytes, None)
    }

    fn new_with_confirmed_baseline(
        workers: usize,
        max_jobs: usize,
        max_results: usize,
        max_result_bytes: usize,
        confirmed_baseline: Option<Arc<ConfirmedBaseline>>,
    ) -> Result<Box<Self>, String> {
        if workers == 0 || max_jobs == 0 || max_results == 0 || max_result_bytes == 0 {
            return Err("Native reflow capacities must be positive".to_owned());
        }
        let available = thread::available_parallelism().map_or(1, usize::from);
        let worker_count = workers.min(available).min(max_jobs).max(1);
        let shared = Arc::new(Shared {
            id: NEXT_SESSION_ID.fetch_add(1, Ordering::Relaxed),
            alive: AtomicBool::new(true),
            generation: AtomicU64::new(0),
            max_jobs,
            max_results,
            max_result_bytes,
            state: Mutex::new(RuntimeState {
                jobs: VecDeque::new(),
                results: HashMap::new(),
                pending_baselines: HashMap::new(),
                result_bytes: 0,
                stale_drops: 0,
                completed_jobs: 0,
                baseline_hits: 0,
                baseline_misses: 0,
                base_renders: 0,
                target_renders: 0,
                document_parses: 0,
                document_validations: 0,
                document_reuses: 0,
                document_full_input_bytes: 0,
                document_delta_input_bytes: 0,
                document_full_nodes_parsed: 0,
                document_delta_entries_parsed: 0,
                document_delta_entries_validated: 0,
                document_trie_path_nodes_copied: 0,
                document_resolver_lookups: 0,
                source_change_work: layout::SourceChangeWork::default(),
                atom_plan_work: layout::AtomPlanWork::default(),
                line_plan_work: layout::LinePlanWork::default(),
                eval_work: layout::EvalWork::default(),
                confirmed_baseline,
            }),
            readiness_channel: Mutex::new(None),
            job_available: Condvar::new(),
            result_available: Condvar::new(),
        });
        let mut handles = Vec::with_capacity(worker_count);
        for index in 0..worker_count {
            let worker_shared = Arc::clone(&shared);
            let spawn = thread::Builder::new()
                .name(format!("ebox-native-reflow-{index}"))
                .spawn(move || worker_loop(worker_shared));
            match spawn {
                Ok(handle) => handles.push(handle),
                Err(error) => {
                    shared.request_stop();
                    for handle in handles {
                        let _ = handle.join();
                    }
                    return Err(format!("Native reflow worker spawn failed: {error}"));
                }
            }
        }
        let layout_document = shared
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .confirmed_baseline
            .as_ref()
            .map(|baseline| baseline.document.clone());
        Ok(Box::new(Self {
            shared,
            workers: Mutex::new(Some(handles)),
            layout_document: Mutex::new(layout_document),
            worker_count,
        }))
    }

    fn fork_confirmed(&self) -> Result<Box<Self>, String> {
        if !self.shared.alive.load(Ordering::Acquire) {
            return Err("Native reflow source session is closed".to_owned());
        }
        let confirmed_baseline = self
            .shared
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .confirmed_baseline
            .clone()
            .ok_or_else(|| "Native reflow source has no confirmed baseline".to_owned())?;
        Self::new_with_confirmed_baseline(
            self.worker_count,
            self.shared.max_jobs,
            self.shared.max_results,
            self.shared.max_result_bytes,
            Some(confirmed_baseline),
        )
    }

    fn submit(&self, generation: u64, payload: &[u8]) -> Result<usize, String> {
        let batch = parse_control_batch(payload)?;
        if batch.document_delta.is_some() {
            return Err("Native async reflow does not accept retained document deltas".to_owned());
        }
        if !self.shared.alive.load(Ordering::Acquire) {
            return Err("Native reflow session is closed".to_owned());
        }
        let layout_requested =
            batch.document.is_some() || batch.frames.iter().any(|frame| frame.payload.is_none());
        let register_document = batch.document.is_some();
        let confirmed_baseline = self
            .shared
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .confirmed_baseline
            .clone();
        let confirmed_document_revision = confirmed_baseline
            .as_ref()
            .map_or(0, |baseline| baseline.document_revision);
        let document_base_revision = batch
            .document_base_revision
            .unwrap_or(confirmed_document_revision);
        let document_target_revision = match batch.document_target_revision {
            Some(revision) => revision,
            None if register_document => document_base_revision
                .checked_add(1)
                .ok_or_else(|| "Native layout document revision overflow".to_owned())?,
            None => document_base_revision,
        };
        let document = match batch.document {
            Some(document) => {
                document.validate()?;
                Some(LayoutSource::Full(Arc::new(document)))
            }
            None if layout_requested => Some(
                confirmed_baseline
                    .as_ref()
                    .map(|baseline| baseline.document.clone())
                    .or_else(|| {
                        self.layout_document
                            .lock()
                            .unwrap_or_else(|poison| poison.into_inner())
                            .clone()
                    })
                    .ok_or_else(|| {
                        "Native layout frames require a registered document".to_owned()
                    })?,
            ),
            None => None,
        };
        if document.is_some() && self.shared.max_result_bytes < MIN_TAPE_BYTES {
            return Err(format!(
                "Native layout results require at least {MIN_TAPE_BYTES} bytes"
            ));
        }

        let mut prepared = Vec::with_capacity(batch.frames.len());
        for frame in batch.frames {
            let job = if let Some(document) = &document {
                prepare_layout_job(
                    document,
                    frame,
                    document_base_revision,
                    document_target_revision,
                    None,
                )?
            } else {
                let payload = frame
                    .payload
                    .ok_or_else(|| format!("Native echo frame {} requires payload", frame.key))?;
                if payload.len() > self.shared.max_result_bytes {
                    return Err(format!(
                        "Native reflow frame {} exceeds the result byte limit",
                        frame.key
                    ));
                }
                PreparedJob {
                    key: frame.key,
                    delay_ms: frame.delay_ms,
                    payload: JobPayload::Echo(payload.into_bytes()),
                }
            };
            prepared.push(job);
        }

        let mut state = self
            .shared
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let current = self.shared.generation.load(Ordering::Acquire);
        if generation < current {
            return Err(format!(
                "Native reflow generation {generation} is stale; current generation is {current}"
            ));
        }
        if generation > current {
            self.shared.generation.store(generation, Ordering::Release);
            let jobs_before = state.jobs.len();
            state.jobs.retain(|job| job.generation >= generation);
            let removed_jobs = jobs_before - state.jobs.len();
            let result_keys: Vec<_> = state
                .results
                .keys()
                .copied()
                .filter(|(result_generation, _)| *result_generation < generation)
                .collect();
            let mut removed_results = 0;
            for key in result_keys {
                if let Some(entry) = state.results.remove(&key) {
                    state.result_bytes = state.result_bytes.saturating_sub(entry.bytes.len());
                    removed_results += 1;
                }
            }
            state
                .pending_baselines
                .retain(|(pending_generation, _), _| *pending_generation >= generation);
            state.stale_drops += (removed_jobs + removed_results) as u64;
            self.shared.result_available.notify_all();
        }
        if state.jobs.len() + prepared.len() > self.shared.max_jobs {
            return Err("Native reflow job queue is full".to_owned());
        }
        let mut batch_keys = HashSet::with_capacity(prepared.len());
        for job in &prepared {
            if !batch_keys.insert(job.key) {
                return Err(format!(
                    "Duplicate native reflow frame key {} in generation {generation}",
                    job.key
                ));
            }
            let duplicate_job = state
                .jobs
                .iter()
                .any(|queued| queued.generation == generation && queued.key == job.key);
            if duplicate_job || state.results.contains_key(&(generation, job.key)) {
                return Err(format!(
                    "Duplicate native reflow frame key {} in generation {generation}",
                    job.key
                ));
            }
        }
        let accepted = prepared.len();
        for job in prepared {
            state.jobs.push_back(Job {
                generation,
                key: job.key,
                payload: job.payload,
                delay_ms: job.delay_ms,
            });
        }
        drop(state);
        if register_document {
            *self
                .layout_document
                .lock()
                .unwrap_or_else(|poison| poison.into_inner()) = document;
            let mut state = self
                .shared
                .state
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            state.confirmed_baseline = None;
            state.pending_baselines.clear();
        }
        self.shared.job_available.notify_all();
        Ok(accepted)
    }

    fn ready(&self, generation: u64, key: i64) -> bool {
        let state = self
            .shared
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        state.results.contains_key(&(generation, key))
    }

    fn take(&self, generation: u64, key: i64) -> Option<Vec<u8>> {
        let mut state = self
            .shared
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let result = state.results.remove(&(generation, key));
        if let Some(entry) = &result {
            state.result_bytes = state.result_bytes.saturating_sub(entry.bytes.len());
            self.shared.result_available.notify_all();
        }
        result.map(|entry| entry.bytes)
    }

    fn render_sync(&self, generation: u64, payload: &[u8]) -> Result<Vec<u8>, String> {
        if !self.shared.alive.load(Ordering::Acquire) {
            return Err("Native reflow session is closed".to_owned());
        }
        let batch = parse_control_batch(payload)?;
        if batch.frames.len() != 1 {
            return Err("Native retained render requires exactly one frame".to_owned());
        }
        let document_base_revision = batch
            .document_base_revision
            .ok_or_else(|| "Native retained render requires exact document revisions".to_owned())?;
        let document_target_revision = batch
            .document_target_revision
            .ok_or_else(|| "Native retained render requires exact document revisions".to_owned())?;
        let confirmed = self
            .shared
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .confirmed_baseline
            .clone();
        let mut source_changes = None;
        let (document, input_stats) = match (batch.document, batch.document_delta) {
            (Some(_), Some(_)) => {
                return Err(
                    "Native retained render cannot combine document and document-delta".to_owned(),
                );
            }
            (Some(document), None) => {
                if document_base_revision.checked_add(1) != Some(document_target_revision) {
                    return Err(
                        "Native retained document replacement must advance one revision".to_owned(),
                    );
                }
                match &confirmed {
                    Some(baseline) if baseline.document_revision != document_base_revision => {
                        return Err(
                            "Native retained document base revision does not match confirmed state"
                                .to_owned(),
                        );
                    }
                    None if document_base_revision != 0 => {
                        return Err(
                            "Native retained document bootstrap must start at revision zero"
                                .to_owned(),
                        );
                    }
                    _ => {}
                }
                let retained = document.retained_root_p();
                let (source, node_count) = if retained {
                    let (document, node_count) = RetainedDocument::bootstrap(document)?;
                    (LayoutSource::Retained(document), node_count)
                } else {
                    document.validate()?;
                    let node_count = document.input_node_count();
                    (LayoutSource::Full(Arc::new(document)), node_count)
                };
                (
                    source,
                    DocumentInputStats {
                        parses: 1,
                        validations: 1,
                        full_input_bytes: payload.len() as u64,
                        full_nodes_parsed: node_count,
                        ..DocumentInputStats::default()
                    },
                )
            }
            (None, Some(delta)) => {
                if document_base_revision.checked_add(1) != Some(document_target_revision) {
                    return Err(
                        "Native retained document delta must advance one revision".to_owned()
                    );
                }
                let baseline = confirmed.as_ref().ok_or_else(|| {
                    "Native retained document delta requires a confirmed baseline".to_owned()
                })?;
                if baseline.document_revision != document_base_revision {
                    return Err(
                        "Native retained document delta base revision does not match confirmed state"
                            .to_owned(),
                    );
                }
                let LayoutSource::Retained(document) = &baseline.document else {
                    return Err(
                        "Native retained document delta requires an identified bootstrap"
                            .to_owned(),
                    );
                };
                let applied = document.apply_delta(delta)?;
                if !applied.changes.applies_to(document, &applied.document) {
                    return Err(
                        "Native retained source changes document identity mismatch".to_owned()
                    );
                }
                // Account for exact input work, then carry these facts only for
                // this render job. Documents and baselines never store the
                // descriptor's references to both versions.
                let mut source_change_work = applied.stats.source_work;
                let mut previous_owner = None;
                applied
                    .changes
                    .visit_changed_slots(|owner, _, _, _, fields| {
                        if previous_owner != Some(owner) {
                            source_change_work.owners_changed += 1;
                            previous_owner = Some(owner);
                        }
                        source_change_work.slots_changed += 1;
                        source_change_work.fields_changed += fields.len() as u64;
                    });
                let (styles, property_templates) = applied.changes.registry_ranges();
                source_change_work.styles_appended = styles.len() as u64;
                source_change_work.property_templates_added = property_templates.len() as u64;
                source_changes = Some(applied.changes);
                (
                    LayoutSource::Retained(applied.document),
                    DocumentInputStats {
                        delta_input_bytes: payload.len() as u64,
                        delta_entries_parsed: applied.stats.entries_parsed,
                        delta_entries_validated: applied.stats.entries_parsed,
                        trie_path_nodes_copied: applied.stats.trie_path_nodes_copied,
                        source_change_work,
                        ..DocumentInputStats::default()
                    },
                )
            }
            (None, None) => {
                if document_base_revision != document_target_revision {
                    return Err(
                        "Native retained document reuse requires equal base and target revisions"
                            .to_owned(),
                    );
                }
                let baseline = confirmed.as_ref().ok_or_else(|| {
                    "Native retained document reuse requires a confirmed baseline".to_owned()
                })?;
                if baseline.document_revision != document_target_revision {
                    return Err(
                        "Native retained document revision does not match confirmed state"
                            .to_owned(),
                    );
                }
                let frame = batch.frames.first().expect("checked retained frame");
                if frame.runtime_revision != baseline.identity.runtime_revision {
                    return Err(
                        "Native retained runtime revision does not match confirmed state"
                            .to_owned(),
                    );
                }
                (
                    baseline.document.clone(),
                    DocumentInputStats {
                        reuses: 1,
                        ..DocumentInputStats::default()
                    },
                )
            }
        };
        let frame = batch
            .frames
            .into_iter()
            .next()
            .expect("checked retained frame");
        if !frame.complete || frame.delay_ms != 0 {
            return Err("Native retained render requires one immediate complete frame".to_owned());
        }
        let prepared = prepare_layout_job(
            &document,
            frame,
            document_base_revision,
            document_target_revision,
            source_changes,
        )?;
        let output = render_layout_payload(
            prepared.payload,
            self.shared.id,
            generation,
            prepared.key,
            self.shared.max_result_bytes,
            confirmed,
            true,
        );
        if output.bytes.len() > self.shared.max_result_bytes {
            return Err("Native retained render exceeds the result byte limit".to_owned());
        }
        let mut state = self
            .shared
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if output.base_renders > 0 {
            state.baseline_misses += 1;
        } else if output.baseline_hit {
            state.baseline_hits += 1;
        }
        state.base_renders += output.base_renders;
        state.target_renders += output.target_renders;
        state.document_resolver_lookups += output.resolver_lookups;
        state.atom_plan_work.accumulate(output.atom_plan_work);
        state.line_plan_work.accumulate(output.line_plan_work);
        state.eval_work.accumulate(output.eval_work);
        state.document_parses += input_stats.parses;
        state.document_validations += input_stats.validations;
        state.document_reuses += input_stats.reuses;
        state.document_full_input_bytes += input_stats.full_input_bytes;
        state.document_delta_input_bytes += input_stats.delta_input_bytes;
        state.document_full_nodes_parsed += input_stats.full_nodes_parsed;
        state.document_delta_entries_parsed += input_stats.delta_entries_parsed;
        state.document_delta_entries_validated += input_stats.delta_entries_validated;
        state.document_trie_path_nodes_copied += input_stats.trie_path_nodes_copied;
        state
            .source_change_work
            .accumulate(input_stats.source_change_work);
        state.pending_baselines.clear();
        if let Some(pending) = output.pending {
            state
                .pending_baselines
                .insert((generation, prepared.key), pending);
        }
        state.completed_jobs += 1;
        Ok(output.bytes)
    }

    fn confirm(&self, generation: u64, key: i64, confirmed_revision: u64) -> Result<bool, String> {
        let mut state = self
            .shared
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let Some(pending) = state.pending_baselines.remove(&(generation, key)) else {
            return Ok(state
                .confirmed_baseline
                .as_ref()
                .is_some_and(|baseline| baseline.identity.runtime_revision == confirmed_revision));
        };
        if pending.confirmed_identity.runtime_revision.checked_add(1) != Some(confirmed_revision) {
            return Err("Native confirmed frame revision mismatch".to_owned());
        }
        let mut identity = pending.confirmed_identity;
        identity.runtime_revision = confirmed_revision;
        state.confirmed_baseline = Some(Arc::new(ConfirmedBaseline {
            identity,
            document: pending.document,
            document_revision: pending.document_revision,
            tape: pending.tape,
            retained_frame: pending.retained_frame,
            styles: pending.styles,
        }));
        Ok(true)
    }

    fn cancel(&self, generation: u64) {
        let next = generation.saturating_add(1);
        self.shared.generation.fetch_max(next, Ordering::AcqRel);
        let mut state = self
            .shared
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let jobs_before = state.jobs.len();
        state.jobs.retain(|job| job.generation > generation);
        let removed_jobs = jobs_before - state.jobs.len();
        let result_keys: Vec<_> = state
            .results
            .keys()
            .copied()
            .filter(|(result_generation, _)| *result_generation <= generation)
            .collect();
        let mut removed_results = 0;
        for key in result_keys {
            if let Some(entry) = state.results.remove(&key) {
                state.result_bytes = state.result_bytes.saturating_sub(entry.bytes.len());
                removed_results += 1;
            }
        }
        state.stale_drops += (removed_jobs + removed_results) as u64;
        state
            .pending_baselines
            .retain(|(pending_generation, _), _| *pending_generation > generation);
        drop(state);
        self.shared.job_available.notify_all();
        self.shared.result_available.notify_all();
    }

    fn attach_readiness_channel(
        &self,
        fd: c_int,
        signal: extern "C" fn(c_int) -> bool,
        close: extern "C" fn(c_int),
    ) -> bool {
        if fd < 0 || !self.shared.alive.load(Ordering::Acquire) {
            return false;
        }
        let mut channel = self
            .shared
            .readiness_channel
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if channel.is_some() {
            return false;
        }
        *channel = Some(ReadinessChannel { fd, signal, close });
        true
    }

    fn detach_readiness_channel(&self) {
        let mut channel = self
            .shared
            .readiness_channel
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if let Some(channel) = channel.take() {
            (channel.close)(channel.fd);
        }
    }

    fn stats(&self) -> SessionStats {
        let state = self
            .shared
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let pending_baselines = state.pending_baselines.len();
        // Compatibility field: the shallow tape container only, not retained
        // plan allocations, shared heap memory or a cache memory bound.
        let confirmed_baseline_bytes = state
            .confirmed_baseline
            .as_ref()
            .map_or(0, |baseline| std::mem::size_of_val(&baseline.tape));
        SessionStats {
            session_id: self.shared.id,
            workers: self.worker_count,
            queued_jobs: state.jobs.len(),
            ready_results: state.results.len(),
            result_bytes: state.result_bytes,
            max_jobs: self.shared.max_jobs,
            max_results: self.shared.max_results,
            max_result_bytes: self.shared.max_result_bytes,
            generation: self.shared.generation.load(Ordering::Acquire),
            stale_drops: state.stale_drops,
            completed_jobs: state.completed_jobs,
            baseline_hits: state.baseline_hits,
            baseline_misses: state.baseline_misses,
            base_renders: state.base_renders,
            target_renders: state.target_renders,
            document_parses: state.document_parses,
            document_validations: state.document_validations,
            document_reuses: state.document_reuses,
            document_full_input_bytes: state.document_full_input_bytes,
            document_delta_input_bytes: state.document_delta_input_bytes,
            document_full_nodes_parsed: state.document_full_nodes_parsed,
            document_delta_entries_parsed: state.document_delta_entries_parsed,
            document_delta_entries_validated: state.document_delta_entries_validated,
            document_trie_path_nodes_copied: state.document_trie_path_nodes_copied,
            document_resolver_lookups: state.document_resolver_lookups,
            source_change_work: state.source_change_work,
            atom_plan_work: state.atom_plan_work,
            line_plan_work: state.line_plan_work,
            eval_work: state.eval_work,
            pending_baselines,
            confirmed_baseline: state.confirmed_baseline.is_some(),
            confirmed_baseline_bytes,
            layout_registered: self
                .layout_document
                .lock()
                .unwrap_or_else(|poison| poison.into_inner())
                .is_some(),
            alive: self.shared.alive.load(Ordering::Acquire),
        }
    }

    fn stop(&self, join: bool) {
        self.detach_readiness_channel();
        self.shared.request_stop();
        if let Some(handles) = self
            .workers
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .take()
        {
            if join {
                for handle in handles {
                    let _ = handle.join();
                }
            }
        }
    }
}

fn parse_control_batch(payload: &[u8]) -> Result<ControlBatch, String> {
    if payload.len() > MAX_CONTROL_BYTES {
        return Err("Native reflow control payload exceeds the hard limit".to_owned());
    }
    let batch: ControlBatch = serde_json::from_slice(payload)
        .map_err(|error| format!("Invalid native reflow control JSON: {error}"))?;
    if batch.version != CONTROL_VERSION {
        return Err(format!(
            "Unsupported native reflow control version {}",
            batch.version
        ));
    }
    if batch.frames.is_empty() {
        return Err("Native reflow control batch has no frames".to_owned());
    }
    Ok(batch)
}

fn checked_layout_context(
    document: &LayoutSource,
    frame_key: i64,
    viewport_width: i64,
    viewport_width_known: bool,
    viewport_height: i64,
    label: &str,
) -> Result<LayoutContext, String> {
    if viewport_width <= 0
        || viewport_height <= 0
        || viewport_width > MAX_LAYOUT_DIMENSION
        || viewport_height > MAX_LAYOUT_DIMENSION
    {
        return Err(format!(
            "Native layout frame {frame_key} {label} viewport is outside the dimension limit"
        ));
    }
    let context = LayoutContext {
        viewport_width,
        css_viewport_width: viewport_width,
        viewport_width_known,
        viewport_height,
        inline_auto_width_intrinsic: false,
    };
    document.validate_context(context)?;
    Ok(context)
}

fn checked_root_width(frame_key: i64, root_width: i64, label: &str) -> Result<i64, String> {
    if root_width <= 0 || root_width > MAX_LAYOUT_DIMENSION {
        return Err(format!(
            "Native layout frame {frame_key} {label} root width is outside the dimension limit"
        ));
    }
    Ok(root_width)
}

fn confirmed_baseline_matches(
    baseline: &ConfirmedBaseline,
    document_base_revision: u64,
    identity: &BaselineIdentity,
) -> bool {
    baseline.document_revision == document_base_revision
        && baseline.identity.context == identity.context
        && baseline.identity.root_width == identity.root_width
        && baseline.identity.root_width_override == identity.root_width_override
        && baseline.identity.runtime_revision == identity.runtime_revision
        && baseline.identity.context_hash == identity.context_hash
        && baseline.identity.complete == identity.complete
}

fn prepare_layout_job(
    document: &LayoutSource,
    frame: ControlFrame,
    document_base_revision: u64,
    document_target_revision: u64,
    source_changes: Option<SourceChanges>,
) -> Result<PreparedJob, String> {
    layout::reset_resolver_lookups();
    if frame.root_scroll_producer && !frame.complete {
        return Err("Native root scroll producer requires complete properties".to_owned());
    }
    if frame.payload.is_some() {
        return Err(format!(
            "Native layout frame {} cannot contain an echo payload",
            frame.key
        ));
    }
    let viewport_width = frame
        .viewport_width
        .ok_or_else(|| format!("Native layout frame {} requires viewport-width", frame.key))?;
    let viewport_height = frame
        .viewport_height
        .ok_or_else(|| format!("Native layout frame {} requires viewport-height", frame.key))?;
    let context = checked_layout_context(
        document,
        frame.key,
        viewport_width,
        frame.viewport_width_known,
        viewport_height,
        "target",
    )?;
    let root_width = checked_root_width(
        frame.key,
        frame.root_width.unwrap_or(viewport_width),
        "target",
    )?;
    let (base_context, base_root_width) = if frame.patch {
        let base_viewport_width = frame.base_viewport_width.ok_or_else(|| {
            format!(
                "Native layout patch frame {} requires base-viewport-width",
                frame.key
            )
        })?;
        let base_viewport_height = frame.base_viewport_height.ok_or_else(|| {
            format!(
                "Native layout patch frame {} requires base-viewport-height",
                frame.key
            )
        })?;
        let base_context = checked_layout_context(
            document,
            frame.key,
            base_viewport_width,
            frame.base_viewport_width_known,
            base_viewport_height,
            "base",
        )?;
        let base_root_width = checked_root_width(
            frame.key,
            frame.base_root_width.unwrap_or(base_viewport_width),
            "base",
        )?;
        (Some(base_context), base_root_width)
    } else {
        if frame.base_viewport_width.is_some()
            || frame.base_viewport_height.is_some()
            || frame.base_root_width.is_some()
            || !frame.base_viewport_width_known
            || frame.base_root_width_override
        {
            return Err(format!(
                "Native full layout frame {} cannot contain base geometry",
                frame.key
            ));
        }
        (None, root_width)
    };
    Ok(PreparedJob {
        key: frame.key,
        delay_ms: frame.delay_ms,
        payload: JobPayload::Layout {
            document: document.clone(),
            source_changes,
            context,
            root_width,
            root_width_override: frame.root_width_override,
            base_context,
            base_root_width,
            base_root_width_override: frame.base_root_width_override,
            runtime_revision: frame.runtime_revision,
            context_hash: frame.context_hash,
            complete: frame.complete,
            root_metadata: frame.root_metadata,
            root_scroll_producer: frame.root_scroll_producer,
            document_base_revision,
            document_target_revision,
            validation_resolver_lookups: layout::resolver_lookups(),
        },
    })
}

fn render_layout_payload(
    payload: JobPayload,
    session_id: u64,
    generation: u64,
    key: i64,
    max_result_bytes: usize,
    confirmed_baseline: Option<Arc<ConfirmedBaseline>>,
    require_confirmed_patch_base: bool,
) -> RenderedJob {
    match payload {
        JobPayload::Echo(bytes) => RenderedJob {
            bytes,
            pending: None,
            baseline_hit: false,
            base_renders: 0,
            target_renders: 0,
            resolver_lookups: 0,
            atom_plan_work: layout::AtomPlanWork::default(),
            line_plan_work: layout::LinePlanWork::default(),
            eval_work: layout::EvalWork::default(),
        },
        JobPayload::Layout {
            document,
            source_changes,
            context,
            root_width,
            root_width_override,
            base_context,
            base_root_width,
            base_root_width_override,
            runtime_revision,
            context_hash,
            complete,
            root_metadata,
            root_scroll_producer,
            document_base_revision,
            document_target_revision,
            validation_resolver_lookups,
        } => {
            let identity = TapeIdentity {
                session_id,
                generation,
                key,
                runtime_revision,
                context_hash,
                viewport_width: context.viewport_width,
                viewport_height: context.viewport_height,
                root_width,
                complete,
            };
            let output = TapeOutputOptions {
                root_metadata,
                max_bytes: max_result_bytes,
            };
            let pending_identity = BaselineIdentity {
                context,
                root_width,
                root_width_override,
                runtime_revision,
                context_hash,
                complete,
            };
            // Worker threads have no other panic boundary: an unwinding
            // panic would silently kill the worker and leave the popped
            // job with neither result nor error tape, so the Elisp ready
            // watcher would poll forever.  Convert panics into the same
            // error-tape channel ordinary layout failures use.
            type LayoutRenderOutcome = Result<
                (
                    Vec<u8>,
                    LayoutTape,
                    Vec<layout::StyleTemplate>,
                    Option<Arc<RetainedFrame>>,
                    bool,
                    u64,
                    u64,
                ),
                String,
            >;
            layout::reset_resolver_lookups();
            layout::reset_atom_plan_work();
            layout::reset_line_plan_work();
            layout::reset_eval_work();
            let result = catch_unwind(AssertUnwindSafe(|| -> LayoutRenderOutcome {
                let target_styles = document.styles()?;
                let render_target = || {
                    document.render_target(
                        context,
                        root_width_override.then_some(root_width),
                        confirmed_baseline
                            .as_ref()
                            .and_then(|baseline| baseline.retained_frame.as_deref()),
                        source_changes.as_ref(),
                        root_scroll_producer,
                    )
                };
                if let Some(base_context) = base_context {
                    let base_identity = BaselineIdentity {
                        context: base_context,
                        root_width: base_root_width,
                        root_width_override: base_root_width_override,
                        runtime_revision,
                        context_hash,
                        complete,
                    };
                    let base_hit = confirmed_baseline
                        .as_ref()
                        .filter(|baseline| {
                            confirmed_baseline_matches(
                                baseline,
                                document_base_revision,
                                &base_identity,
                            ) && layout::style_registry_extends_exact_prefix(
                                &baseline.styles,
                                &target_styles,
                            )
                        })
                        .cloned();
                    if require_confirmed_patch_base && base_hit.is_none() {
                        let (target, retained_frame) = render_target()?;
                        let bytes = layout::encode_layout_tape_with_scroll(
                            target.clone(),
                            &target_styles,
                            identity,
                            output.root_metadata,
                            output.max_bytes,
                            retained_frame
                                .as_ref()
                                .and_then(|frame| frame.root_scroll()),
                        )?;
                        return Ok((bytes, target, target_styles, retained_frame, false, 0, 1));
                    }
                    let (old, baseline_hit, base_renders) = if let Some(baseline) = base_hit {
                        (baseline.tape.clone(), true, 0)
                    } else {
                        (
                            document.layout_tape(
                                base_context,
                                base_root_width_override.then_some(base_root_width),
                            )?,
                            false,
                            1,
                        )
                    };
                    let (target, retained_frame) = render_target()?;
                    let bytes = layout::encode_layout_patch_tape_with_scroll(
                        old,
                        target.clone(),
                        &target_styles,
                        identity,
                        output.root_metadata,
                        output.max_bytes,
                        retained_frame
                            .as_ref()
                            .and_then(|frame| frame.root_scroll())
                            .map(|scroll| {
                                (
                                    scroll,
                                    confirmed_baseline
                                        .as_ref()
                                        .filter(|_| baseline_hit)
                                        .and_then(|base| base.retained_frame.as_ref())
                                        .and_then(|frame| frame.root_scroll()),
                                )
                            }),
                    )?;
                    Ok((
                        bytes,
                        target,
                        target_styles,
                        retained_frame,
                        baseline_hit,
                        base_renders,
                        1,
                    ))
                } else {
                    let (target, retained_frame) = render_target()?;
                    let bytes = layout::encode_layout_tape_with_scroll(
                        target.clone(),
                        &target_styles,
                        identity,
                        output.root_metadata,
                        output.max_bytes,
                        retained_frame
                            .as_ref()
                            .and_then(|frame| frame.root_scroll()),
                    )?;
                    Ok((bytes, target, target_styles, retained_frame, false, 0, 1))
                }
            }));
            let resolver_lookups =
                validation_resolver_lookups.saturating_add(layout::resolver_lookups());
            let atom_plan_work = layout::atom_plan_work();
            let line_plan_work = layout::line_plan_work();
            let eval_work = layout::eval_work();
            match result {
                Ok(Ok((
                    bytes,
                    tape,
                    styles,
                    retained_frame,
                    baseline_hit,
                    base_renders,
                    target_renders,
                ))) => RenderedJob {
                    bytes,
                    pending: Some(PendingBaseline {
                        confirmed_identity: pending_identity,
                        document: document.clone(),
                        document_revision: document_target_revision,
                        tape,
                        retained_frame,
                        styles,
                    }),
                    baseline_hit,
                    base_renders,
                    target_renders,
                    resolver_lookups,
                    atom_plan_work,
                    line_plan_work,
                    eval_work,
                },
                Ok(Err(error)) => RenderedJob {
                    bytes: encode_error_tape(identity, &error, max_result_bytes),
                    pending: None,
                    baseline_hit: false,
                    base_renders: 0,
                    target_renders: 0,
                    resolver_lookups,
                    atom_plan_work,
                    line_plan_work,
                    eval_work,
                },
                Err(_) => RenderedJob {
                    bytes: encode_error_tape(identity, "native layout panicked", max_result_bytes),
                    pending: None,
                    baseline_hit: false,
                    base_renders: 0,
                    target_renders: 0,
                    resolver_lookups,
                    atom_plan_work,
                    line_plan_work,
                    eval_work,
                },
            }
        }
    }
}

fn render_proof(payload: &[u8]) -> Result<Vec<u8>, String> {
    let batch = parse_control_batch(payload)?;
    let document = batch
        .document
        .ok_or_else(|| "Native proof render requires an inline document".to_owned())?;
    document.validate()?;
    if batch.frames.len() != 1 {
        return Err("Native proof render requires exactly one layout frame".to_owned());
    }
    if SYNC_RENDER_MAX_RESULT_BYTES < MIN_TAPE_BYTES {
        return Err(format!(
            "Native layout results require at least {MIN_TAPE_BYTES} bytes"
        ));
    }
    let frame = batch
        .frames
        .into_iter()
        .next()
        .expect("checked single proof frame");
    if frame.patch {
        return Err("Native proof render supports full layout frames only".to_owned());
    }
    if !frame.complete {
        return Err("Native proof render requires complete frames".to_owned());
    }
    if frame.delay_ms != 0 {
        return Err("Native proof render cannot contain delay-ms".to_owned());
    }
    let document = LayoutSource::Full(Arc::new(document));
    let prepared = prepare_layout_job(&document, frame, 0, 1, None)?;
    let output = render_layout_payload(
        prepared.payload,
        SYNC_RENDER_SESSION_ID,
        0,
        prepared.key,
        SYNC_RENDER_MAX_RESULT_BYTES,
        None,
        false,
    );
    if output.bytes.len() > SYNC_RENDER_MAX_RESULT_BYTES {
        return Err("Native proof render exceeds the result byte limit".to_owned());
    }
    Ok(output.bytes)
}

fn worker_loop(shared: Arc<Shared>) {
    loop {
        let job = {
            let mut state = shared
                .state
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            while shared.alive.load(Ordering::Acquire) && state.jobs.is_empty() {
                state = shared
                    .job_available
                    .wait(state)
                    .unwrap_or_else(|poison| poison.into_inner());
            }
            if !shared.alive.load(Ordering::Acquire) {
                return;
            }
            state.jobs.pop_front()
        };
        let Some(job) = job else {
            continue;
        };

        let mut remaining_delay = job.delay_ms;
        while remaining_delay > 0 {
            let slice_ms = remaining_delay.min(2);
            thread::sleep(Duration::from_millis(slice_ms));
            remaining_delay -= slice_ms;
            if !shared.alive.load(Ordering::Acquire)
                || shared.generation.load(Ordering::Acquire) != job.generation
            {
                break;
            }
        }
        if !shared.alive.load(Ordering::Acquire)
            || shared.generation.load(Ordering::Acquire) != job.generation
        {
            let mut state = shared
                .state
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            state.stale_drops += 1;
            continue;
        }

        let confirmed_baseline = {
            let state = shared
                .state
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            state.confirmed_baseline.clone()
        };
        let output = render_layout_payload(
            job.payload,
            shared.id,
            job.generation,
            job.key,
            shared.max_result_bytes,
            confirmed_baseline,
            false,
        );
        if output.bytes.len() > shared.max_result_bytes {
            let mut state = shared
                .state
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            state.stale_drops += 1;
            continue;
        }
        let output_len = output.bytes.len();
        let mut state = shared
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        while shared.alive.load(Ordering::Acquire)
            && shared.generation.load(Ordering::Acquire) == job.generation
            && (state.results.len() >= shared.max_results
                || state.result_bytes + output_len > shared.max_result_bytes)
        {
            state = shared
                .result_available
                .wait(state)
                .unwrap_or_else(|poison| poison.into_inner());
        }
        if !shared.alive.load(Ordering::Acquire)
            || shared.generation.load(Ordering::Acquire) != job.generation
        {
            state.stale_drops += 1;
            continue;
        }
        state.result_bytes += output_len;
        if output.base_renders > 0 {
            state.baseline_misses += 1;
        } else if output.baseline_hit {
            state.baseline_hits += 1;
        }
        state.base_renders += output.base_renders;
        state.target_renders += output.target_renders;
        state.document_resolver_lookups += output.resolver_lookups;
        state.atom_plan_work.accumulate(output.atom_plan_work);
        state.line_plan_work.accumulate(output.line_plan_work);
        state.eval_work.accumulate(output.eval_work);
        state.results.insert(
            (job.generation, job.key),
            ResultEntry {
                bytes: output.bytes,
            },
        );
        if let Some(pending) = output.pending {
            state
                .pending_baselines
                .insert((job.generation, job.key), pending);
        }
        state.completed_jobs += 1;
        drop(state);
        shared.signal_readiness();
    }
}

fn session_ref<'a>(pointer: *mut c_void) -> Option<&'a Session> {
    if pointer.is_null() {
        None
    } else {
        Some(unsafe { &*(pointer as *mut Session) })
    }
}

fn set_error(output: *mut NativeBytes, message: impl Into<String>) {
    if !output.is_null() {
        unsafe {
            *output = NativeBytes::from_error(message);
        }
    }
}

#[no_mangle]
pub static plugin_is_GPL_compatible: i32 = 0;

extern "C" {
    fn ebox_module_init_impl(runtime: *mut c_void) -> i32;
}

#[no_mangle]
/// Initialize the module through Emacs's official runtime pointer.
///
/// # Safety
///
/// `runtime` must be the live `emacs_runtime` pointer supplied by Emacs for
/// this module initialization call.
pub unsafe extern "C" fn emacs_module_init(runtime: *mut c_void) -> i32 {
    catch_unwind(AssertUnwindSafe(|| unsafe {
        ebox_module_init_impl(runtime)
    }))
    .unwrap_or(99)
}

#[no_mangle]
pub extern "C" fn ebox_native_layout_ready() -> bool {
    true
}

#[no_mangle]
pub extern "C" fn ebox_native_session_create(
    workers: u32,
    max_jobs: u32,
    max_results: u32,
    max_result_bytes: u64,
    error: *mut NativeBytes,
) -> *mut c_void {
    match catch_unwind(AssertUnwindSafe(|| {
        Session::new(
            workers as usize,
            max_jobs as usize,
            max_results as usize,
            usize::try_from(max_result_bytes)
                .map_err(|_| "Native reflow byte limit exceeds this platform".to_owned())?,
        )
    })) {
        Ok(Ok(session)) => Box::into_raw(session) as *mut c_void,
        Ok(Err(message)) => {
            set_error(error, message);
            ptr::null_mut()
        }
        Err(_) => {
            set_error(error, "Native reflow session creation panicked");
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn ebox_native_session_fork_confirmed(
    source: *mut c_void,
    error: *mut NativeBytes,
) -> *mut c_void {
    match catch_unwind(AssertUnwindSafe(|| {
        let source =
            session_ref(source).ok_or_else(|| "Native reflow source session is null".to_owned())?;
        source.fork_confirmed()
    })) {
        Ok(Ok(session)) => Box::into_raw(session) as *mut c_void,
        Ok(Err(message)) => {
            set_error(error, message);
            ptr::null_mut()
        }
        Err(_) => {
            set_error(error, "Native reflow confirmed fork panicked");
            ptr::null_mut()
        }
    }
}

#[no_mangle]
/// Copy and submit one versioned control payload to a live native session.
///
/// # Safety
///
/// `session` must come from `ebox_native_session_create`. When `payload_len`
/// is nonzero, `payload` must reference that many readable bytes for the
/// duration of this call. `error`, when non-null, must be writable.
pub unsafe extern "C" fn ebox_native_session_submit(
    session: *mut c_void,
    generation: u64,
    payload: *const u8,
    payload_len: usize,
    error: *mut NativeBytes,
) -> i64 {
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        let session =
            session_ref(session).ok_or_else(|| "Native reflow session is null".to_owned())?;
        if payload.is_null() && payload_len != 0 {
            return Err("Native reflow payload pointer is null".to_owned());
        }
        let bytes = if payload_len == 0 {
            &[][..]
        } else {
            unsafe { slice::from_raw_parts(payload, payload_len) }
        };
        session.submit(generation, bytes)
    }));
    match outcome {
        Ok(Ok(accepted)) => accepted as i64,
        Ok(Err(message)) => {
            set_error(error, message);
            -1
        }
        Err(_) => {
            set_error(error, "Native reflow submission panicked");
            -1
        }
    }
}

#[no_mangle]
/// Render one retained frame synchronously through a live native session.
///
/// # Safety
///
/// `session` must come from `ebox_native_session_create`.  PAYLOAD and OUTPUT
/// follow the same validity rules as `ebox_native_render_proof`.
pub unsafe extern "C" fn ebox_native_session_render_sync(
    session: *mut c_void,
    generation: u64,
    payload: *const u8,
    payload_len: usize,
    output: *mut NativeBytes,
) -> bool {
    if output.is_null() {
        return false;
    }
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        let session =
            session_ref(session).ok_or_else(|| "Native reflow session is null".to_owned())?;
        if payload.is_null() && payload_len != 0 {
            return Err("Native retained render payload pointer is null".to_owned());
        }
        let bytes = if payload_len == 0 {
            &[][..]
        } else {
            unsafe { slice::from_raw_parts(payload, payload_len) }
        };
        session.render_sync(generation, bytes)
    }));
    let result = match outcome {
        Ok(result) => result,
        Err(_) => Err("Native retained render panicked".to_owned()),
    };
    let success = result.is_ok();
    unsafe {
        *output = match result {
            Ok(bytes) => NativeBytes::from_vec(bytes),
            Err(message) => NativeBytes::from_error(message),
        };
    }
    success
}

#[no_mangle]
/// Render one complete layout proof synchronously from a versioned payload.
///
/// # Safety
///
/// When `payload_len` is nonzero, `payload` must reference that many readable
/// bytes for the duration of this call. `output` must be writable.
pub unsafe extern "C" fn ebox_native_render_proof(
    payload: *const u8,
    payload_len: usize,
    output: *mut NativeBytes,
) -> bool {
    if output.is_null() {
        return false;
    }
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        if payload.is_null() && payload_len != 0 {
            return Err("Native proof render payload pointer is null".to_owned());
        }
        let bytes = if payload_len == 0 {
            &[][..]
        } else {
            unsafe { slice::from_raw_parts(payload, payload_len) }
        };
        render_proof(bytes)
    }));
    let result = match outcome {
        Ok(result) => result,
        Err(_) => Err("Native proof render panicked".to_owned()),
    };
    let success = result.is_ok();
    unsafe {
        *output = match result {
            Ok(bytes) => NativeBytes::from_vec(bytes),
            Err(message) => NativeBytes::from_error(message),
        };
    }
    success
}

#[no_mangle]
pub extern "C" fn ebox_native_session_ready(
    session: *mut c_void,
    generation: u64,
    key: i64,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        session_ref(session).is_some_and(|session| session.ready(generation, key))
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn ebox_native_session_take(
    session: *mut c_void,
    generation: u64,
    key: i64,
) -> NativeBytes {
    catch_unwind(AssertUnwindSafe(|| {
        session_ref(session)
            .and_then(|session| session.take(generation, key))
            .map_or_else(NativeBytes::empty, NativeBytes::from_vec)
    }))
    .unwrap_or_else(|_| NativeBytes::empty())
}

#[no_mangle]
pub extern "C" fn ebox_native_session_confirm_frame(
    session: *mut c_void,
    generation: u64,
    key: i64,
    confirmed_revision: u64,
    error: *mut NativeBytes,
) -> bool {
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        let session =
            session_ref(session).ok_or_else(|| "Native reflow session is null".to_owned())?;
        session.confirm(generation, key, confirmed_revision)
    }));
    match outcome {
        Ok(Ok(confirmed)) => confirmed,
        Ok(Err(message)) => {
            set_error(error, message);
            false
        }
        Err(_) => {
            set_error(error, "Native reflow confirmation panicked");
            false
        }
    }
}

#[no_mangle]
pub extern "C" fn ebox_native_session_attach_readiness_channel(
    session: *mut c_void,
    fd: c_int,
    signal: Option<extern "C" fn(c_int) -> bool>,
    close: Option<extern "C" fn(c_int)>,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(session) = session_ref(session) else {
            return false;
        };
        let Some(signal) = signal else {
            return false;
        };
        let Some(close) = close else {
            return false;
        };
        session.attach_readiness_channel(fd, signal, close)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn ebox_native_session_detach_readiness_channel(session: *mut c_void) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(session) = session_ref(session) {
            session.detach_readiness_channel();
        }
    }));
}

#[no_mangle]
pub extern "C" fn ebox_native_session_cancel(session: *mut c_void, generation: u64) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(session) = session_ref(session) {
            session.cancel(generation);
        }
    }));
}

#[no_mangle]
pub extern "C" fn ebox_native_session_stats(session: *mut c_void) -> NativeBytes {
    catch_unwind(AssertUnwindSafe(|| {
        session_ref(session)
            .and_then(|session| serde_json::to_vec(&session.stats()).ok())
            .map_or_else(NativeBytes::empty, NativeBytes::from_vec)
    }))
    .unwrap_or_else(|_| NativeBytes::empty())
}

#[no_mangle]
pub extern "C" fn ebox_native_session_release(session: *mut c_void) {
    if session.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let session = unsafe { Box::from_raw(session as *mut Session) };
        session.stop(false);
    }));
}

#[no_mangle]
pub extern "C" fn ebox_native_session_finalize(session: *mut c_void) {
    if session.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let session = unsafe { Box::from_raw(session as *mut Session) };
        session.stop(false);
    }));
}

#[no_mangle]
pub extern "C" fn ebox_native_bytes_free(bytes: NativeBytes) {
    if bytes.data.is_null() || bytes.len == 0 {
        return;
    }
    let pointer = ptr::slice_from_raw_parts_mut(bytes.data, bytes.len);
    unsafe {
        drop(Box::from_raw(pointer));
    }
}
