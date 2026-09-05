mod layout;
pub mod sequence;

use layout::{
    encode_error_tape, DocumentDelta, LayoutContext, LayoutDocument, LayoutTape, RetainedDocument,
    TapeIdentity, TapeOutputOptions, MAX_LAYOUT_DIMENSION, MIN_TAPE_BYTES,
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
    delay_ms: u64,
}

#[derive(Debug)]
enum JobPayload {
    Echo(Vec<u8>),
    Layout {
        document: LayoutSource,
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
    styles: Vec<layout::StyleTemplate>,
}

#[derive(Debug)]
struct PendingBaseline {
    confirmed_identity: BaselineIdentity,
    document: LayoutSource,
    document_revision: u64,
    tape: LayoutTape,
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
                // Consume exact source facts for input accounting. The renderer
                // still evaluates the target normally; no history-bearing change
                // object is stored in a job, document or confirmed baseline.
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
) -> Result<PreparedJob, String> {
    layout::reset_resolver_lookups();
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
        },
        JobPayload::Layout {
            document,
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
                    bool,
                    u64,
                    u64,
                ),
                String,
            >;
            layout::reset_resolver_lookups();
            layout::reset_atom_plan_work();
            layout::reset_line_plan_work();
            let result = catch_unwind(AssertUnwindSafe(|| -> LayoutRenderOutcome {
                let target_styles = document.styles()?;
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
                        let target = document
                            .layout_tape(context, root_width_override.then_some(root_width))?;
                        let bytes = layout::encode_layout_tape(
                            target.clone(),
                            &target_styles,
                            identity,
                            output.root_metadata,
                            output.max_bytes,
                        )?;
                        return Ok((bytes, target, target_styles, false, 0, 1));
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
                    let target =
                        document.layout_tape(context, root_width_override.then_some(root_width))?;
                    let bytes = layout::encode_layout_patch_tape(
                        old,
                        target.clone(),
                        &target_styles,
                        identity,
                        output.root_metadata,
                        output.max_bytes,
                    )?;
                    Ok((bytes, target, target_styles, baseline_hit, base_renders, 1))
                } else {
                    let target =
                        document.layout_tape(context, root_width_override.then_some(root_width))?;
                    let bytes = layout::encode_layout_tape(
                        target.clone(),
                        &target_styles,
                        identity,
                        output.root_metadata,
                        output.max_bytes,
                    )?;
                    Ok((bytes, target, target_styles, false, 0, 1))
                }
            }));
            let resolver_lookups =
                validation_resolver_lookups.saturating_add(layout::resolver_lookups());
            let atom_plan_work = layout::atom_plan_work();
            let line_plan_work = layout::line_plan_work();
            match result {
                Ok(Ok((bytes, tape, styles, baseline_hit, base_renders, target_renders))) => {
                    RenderedJob {
                        bytes,
                        pending: Some(PendingBaseline {
                            confirmed_identity: pending_identity,
                            document: document.clone(),
                            document_revision: document_target_revision,
                            tape,
                            styles,
                        }),
                        baseline_hit,
                        base_renders,
                        target_renders,
                        resolver_lookups,
                        atom_plan_work,
                        line_plan_work,
                    }
                }
                Ok(Err(error)) => RenderedJob {
                    bytes: encode_error_tape(identity, &error, max_result_bytes),
                    pending: None,
                    baseline_hit: false,
                    base_renders: 0,
                    target_renders: 0,
                    resolver_lookups,
                    atom_plan_work,
                    line_plan_work,
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
    let prepared = prepare_layout_job(&document, frame, 0, 1)?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use std::time::{Duration, Instant};

    static READINESS_WAKE_COUNT: AtomicUsize = AtomicUsize::new(0);
    static READINESS_CLOSE_COUNT: AtomicUsize = AtomicUsize::new(0);
    static READINESS_FAILURE_CLOSE_COUNT: AtomicUsize = AtomicUsize::new(0);

    extern "C" fn test_readiness_signal(fd: c_int) -> bool {
        if fd == 7 {
            READINESS_WAKE_COUNT.fetch_add(1, Ordering::SeqCst);
        }
        true
    }

    extern "C" fn test_readiness_signal_failure(_fd: c_int) -> bool {
        false
    }

    extern "C" fn test_readiness_close(fd: c_int) {
        if fd == 7 {
            READINESS_CLOSE_COUNT.fetch_add(1, Ordering::SeqCst);
        } else {
            READINESS_FAILURE_CLOSE_COUNT.fetch_add(1, Ordering::SeqCst);
        }
    }

    fn batch(frames: &str) -> Vec<u8> {
        format!(r#"{{"version":1,"frames":{frames}}}"#).into_bytes()
    }

    fn proof_layout_payload(frames: &str) -> Vec<u8> {
        format!(
            r#"{{"version":1,"document-base-revision":0,"document-target-revision":1,"document":{{"version":2,"space-width":8,"style-count":0,"styles":[],"root":{{"type":"box","region-id":1,"content":{{"lines":[{{"clusters":[{{"text":"x","width":8,"cjk":false,"space":false}}]}}]}},"child":null,"content-width-exact":false,"width":{{"kind":"viewport"}},"min-width":{{"kind":"pixels","value":0}},"max-width":{{"kind":"none"}},"height":{{"kind":"auto"}},"min-height":{{"kind":"lines","value":0}},"max-height":{{"kind":"none"}},"box-sizing":"border-box","padding-left":0,"padding-right":0,"padding-top":0,"padding-bottom":0,"margin-left":0,"margin-right":0,"margin-top":0,"margin-bottom":0,"border-left":0,"border-right":0,"foreground-style":null,"background-style":null,"border-left-style":null,"border-right-style":null,"border-top-style":null,"border-bottom-style":null,"text-align":"left","vertical-align":"top","overflow":"scroll","wrap-mode":"word","scroll-offset":0}}}},"frames":{frames}}}"#
        )
        .into_bytes()
    }

    fn retained_layout_payload(document_revision: u64, frames: &str) -> Vec<u8> {
        format!(
            r#"{{"version":1,"document-base-revision":{document_revision},"document-target-revision":{document_revision},"frames":{frames}}}"#
        )
        .into_bytes()
    }

    fn identified_proof_layout_payload(frames: &str) -> Vec<u8> {
        let mut payload: serde_json::Value =
            serde_json::from_slice(&proof_layout_payload(frames)).unwrap();
        payload["document"]["root"]["node-id"] = serde_json::json!(1);
        payload["document"]["root"]["node-revision"] = serde_json::json!(7);
        serde_json::to_vec(&payload).unwrap()
    }

    fn replacement_layout_payload(
        document_base_revision: u64,
        document_target_revision: u64,
        frames: &str,
    ) -> Vec<u8> {
        let payload = String::from_utf8(proof_layout_payload(frames)).unwrap();
        payload
            .replacen(
                r#""document-base-revision":0"#,
                &format!(r#""document-base-revision":{document_base_revision}"#),
                1,
            )
            .replacen(
                r#""document-target-revision":1"#,
                &format!(r#""document-target-revision":{document_target_revision}"#),
                1,
            )
            .into_bytes()
    }

    fn styled_layout_payload(
        document_base_revision: u64,
        document_target_revision: u64,
        style_count: u32,
        styles: &str,
        foreground_style: u32,
        frames: &str,
    ) -> Vec<u8> {
        let payload = String::from_utf8(replacement_layout_payload(
            document_base_revision,
            document_target_revision,
            frames,
        ))
        .unwrap();
        payload
            .replacen(
                r#""style-count":0"#,
                &format!(r#""style-count":{style_count}"#),
                1,
            )
            .replacen(r#""styles":[]"#, &format!(r#""styles":{styles}"#), 1)
            .replacen(
                r#""foreground-style":null"#,
                &format!(r#""foreground-style":{foreground_style}"#),
                1,
            )
            .into_bytes()
    }

    fn column_proof_layout_payload(frames: &str) -> Vec<u8> {
        format!(
            r#"{{"version":1,"document-base-revision":0,"document-target-revision":1,"document":{{"version":2,"space-width":8,"style-count":0,"styles":[],"root":{{"type":"column","children":[{{"type":"box","region-id":1,"content":{{"lines":[{{"clusters":[{{"text":"x","width":8,"cjk":false,"space":false}}]}}]}},"child":null,"content-width-exact":false,"width":{{"kind":"content"}},"min-width":{{"kind":"pixels","value":0}},"max-width":{{"kind":"none"}},"height":{{"kind":"auto"}},"min-height":{{"kind":"lines","value":0}},"max-height":{{"kind":"none"}},"box-sizing":"border-box","padding-left":0,"padding-right":0,"padding-top":0,"padding-bottom":0,"margin-left":0,"margin-right":0,"margin-top":0,"margin-bottom":0,"border-left":0,"border-right":0,"foreground-style":null,"background-style":null,"border-left-style":null,"border-right-style":null,"border-top-style":null,"border-bottom-style":null,"text-align":"left","vertical-align":"top","overflow":"scroll","wrap-mode":"word","scroll-offset":0}},{{"type":"box","region-id":2,"content":{{"lines":[{{"clusters":[{{"text":"yy","width":16,"cjk":false,"space":false}}]}}]}},"child":null,"content-width-exact":false,"width":{{"kind":"content"}},"min-width":{{"kind":"pixels","value":0}},"max-width":{{"kind":"none"}},"height":{{"kind":"auto"}},"min-height":{{"kind":"lines","value":0}},"max-height":{{"kind":"none"}},"box-sizing":"border-box","padding-left":0,"padding-right":0,"padding-top":0,"padding-bottom":0,"margin-left":0,"margin-right":0,"margin-top":0,"margin-bottom":0,"border-left":0,"border-right":0,"foreground-style":null,"background-style":null,"border-left-style":null,"border-right-style":null,"border-top-style":null,"border-bottom-style":null,"text-align":"left","vertical-align":"top","overflow":"scroll","wrap-mode":"word","scroll-offset":0}}]}}}},"frames":{frames}}}"#
        )
        .into_bytes()
    }

    fn read_le_u64(bytes: &[u8], offset: usize) -> u64 {
        u64::from_le_bytes(bytes[offset..offset + 8].try_into().unwrap())
    }

    fn tape_patch_p(bytes: &[u8]) -> bool {
        u16::from_le_bytes(bytes[6..8].try_into().unwrap()) & (1 << 2) != 0
    }

    fn full_tape_character_count(bytes: &[u8]) -> u64 {
        read_le_u64(bytes, 92)
    }

    fn full_tape_line_widths(bytes: &[u8]) -> Vec<u64> {
        let line_count = u32::from_le_bytes(bytes[120..124].try_into().unwrap()) as usize;
        (0..line_count)
            .map(|index| read_le_u64(bytes, 152 + index * 8))
            .collect()
    }

    fn wait_until(mut predicate: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(2);
        while !predicate() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(1));
        }
        assert!(predicate());
    }

    #[test]
    fn bounded_session_round_trips_owned_payloads() {
        let session = Session::new(2, 8, 8, 4096).unwrap();
        let control = batch(r#"[{"key":1,"payload":"alpha"},{"key":2,"payload":"beta"}]"#);
        assert_eq!(session.submit(1, &control).unwrap(), 2);
        wait_until(|| session.ready(1, 1) && session.ready(1, 2));
        assert_eq!(session.take(1, 1).unwrap(), b"alpha");
        assert_eq!(session.take(1, 2).unwrap(), b"beta");
        assert_eq!(session.stats().result_bytes, 0);
        session.stop(true);
    }

    #[test]
    fn readiness_channel_wakes_on_completion_and_detaches_cleanly() {
        READINESS_WAKE_COUNT.store(0, Ordering::SeqCst);
        READINESS_CLOSE_COUNT.store(0, Ordering::SeqCst);
        let session = Session::new(1, 8, 8, 4096).unwrap();
        assert!(session.attach_readiness_channel(7, test_readiness_signal, test_readiness_close));
        assert!(!session.attach_readiness_channel(8, test_readiness_signal, test_readiness_close));
        let control =
            batch(r#"[{"key":1,"payload":"alpha"},{"key":2,"payload":"beta","delay-ms":20}]"#);
        assert_eq!(session.submit(1, &control).unwrap(), 2);
        wait_until(|| READINESS_WAKE_COUNT.load(Ordering::SeqCst) >= 1);
        assert!(session.ready(1, 1));
        assert_eq!(session.take(1, 1).unwrap(), b"alpha");

        session.cancel(1);
        let wakes_after_cancel = READINESS_WAKE_COUNT.load(Ordering::SeqCst);
        thread::sleep(Duration::from_millis(30));
        assert_eq!(
            READINESS_WAKE_COUNT.load(Ordering::SeqCst),
            wakes_after_cancel
        );

        session.detach_readiness_channel();
        assert_eq!(READINESS_CLOSE_COUNT.load(Ordering::SeqCst), 1);
        let detached_wakes = READINESS_WAKE_COUNT.load(Ordering::SeqCst);
        let detached = batch(r#"[{"key":3,"payload":"gamma"}]"#);
        assert_eq!(session.submit(2, &detached).unwrap(), 1);
        wait_until(|| session.ready(2, 3));
        thread::sleep(Duration::from_millis(5));
        assert_eq!(READINESS_WAKE_COUNT.load(Ordering::SeqCst), detached_wakes);
        session.stop(true);

        let raw = ebox_native_session_create(1, 2, 2, 4096, ptr::null_mut());
        assert!(!raw.is_null());
        assert!(ebox_native_session_attach_readiness_channel(
            raw,
            7,
            Some(test_readiness_signal),
            Some(test_readiness_close)
        ));
        ebox_native_session_release(raw);
        assert_eq!(READINESS_CLOSE_COUNT.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn readiness_signal_failure_closes_and_releases_the_channel() {
        READINESS_FAILURE_CLOSE_COUNT.store(0, Ordering::SeqCst);
        let session = Session::new(1, 2, 2, 4096).unwrap();
        assert!(session.attach_readiness_channel(
            9,
            test_readiness_signal_failure,
            test_readiness_close
        ));
        let control = batch(r#"[{"key":1,"payload":"ready"}]"#);
        assert_eq!(session.submit(1, &control).unwrap(), 1);
        wait_until(|| session.ready(1, 1));
        wait_until(|| READINESS_FAILURE_CLOSE_COUNT.load(Ordering::SeqCst) == 1);
        assert!(session.attach_readiness_channel(10, test_readiness_signal, test_readiness_close));
        session.detach_readiness_channel();
        assert_eq!(READINESS_FAILURE_CLOSE_COUNT.load(Ordering::SeqCst), 2);
        session.stop(true);
    }

    #[test]
    fn cancellation_drops_delayed_generation() {
        let session = Session::new(1, 4, 4, 4096).unwrap();
        let control = batch(r#"[{"key":1,"payload":"stale","delay-ms":50}]"#);
        assert_eq!(session.submit(7, &control).unwrap(), 1);
        session.cancel(7);
        thread::sleep(Duration::from_millis(80));
        assert!(!session.ready(7, 1));
        assert!(session.stats().stale_drops > 0);
        session.stop(true);
    }

    #[test]
    fn stopping_serializes_with_a_worker_holding_the_wait_predicate_lock() {
        let session = Arc::new(Session::new(1, 1, 1, 4).unwrap());
        let guard = session.shared.state.lock().unwrap();
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (completed_tx, completed_rx) = std::sync::mpsc::channel();
        let stopping = Arc::clone(&session);
        let stopper = thread::spawn(move || {
            started_tx.send(()).unwrap();
            stopping.stop(false);
            completed_tx.send(()).unwrap();
        });
        started_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        // A worker holds this mutex between checking the predicate and
        // entering Condvar::wait. Shutdown must not publish/notify in that gap.
        let completed_while_locked = completed_rx
            .recv_timeout(Duration::from_millis(100))
            .is_ok();
        drop(guard);
        if !completed_while_locked {
            completed_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        }
        stopper.join().unwrap();
        assert!(
            !completed_while_locked,
            "shutdown raced ahead of the worker wait predicate lock"
        );
    }

    #[test]
    fn stopping_joins_a_worker_blocked_on_result_capacity() {
        let session = Arc::new(Session::new(1, 2, 1, 8).unwrap());
        session
            .submit(
                1,
                &batch(r#"[{"key":1,"payload":"a"},{"key":2,"payload":"b"}]"#),
            )
            .unwrap();
        wait_until(|| {
            let stats = session.stats();
            stats.completed_jobs == 1 && stats.queued_jobs == 0
        });
        let stopping = Arc::clone(&session);
        let (completed_tx, completed_rx) = std::sync::mpsc::channel();
        let stopper = thread::spawn(move || {
            stopping.stop(true);
            completed_tx.send(()).unwrap();
        });
        let completed_without_rescue = completed_rx.recv_timeout(Duration::from_secs(2)).is_ok();
        if !completed_without_rescue {
            // Preserve the failure, but release a stranded waiter before the
            // assertion so a broken notification does not hang the test suite.
            session.shared.job_available.notify_all();
            session.shared.result_available.notify_all();
            completed_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        }
        stopper.join().unwrap();
        assert!(
            completed_without_rescue,
            "shutdown left a capacity waiter asleep"
        );
    }

    #[test]
    fn malformed_and_over_capacity_batches_are_rejected() {
        let session = Session::new(1, 1, 1, 4).unwrap();
        assert!(session.submit(1, b"not-json").is_err());
        let oversized = batch(r#"[{"key":1,"payload":"12345"}]"#);
        assert!(session.submit(1, &oversized).is_err());
        assert_eq!(session.stats().queued_jobs, 0);
        session.stop(true);
    }

    #[test]
    fn newer_generation_purges_old_capacity_and_duplicate_keys_are_rejected() {
        let session = Session::new(1, 2, 2, 4096).unwrap();
        let old = batch(r#"[{"key":1,"payload":"old","delay-ms":50},{"key":2,"payload":"old"}]"#);
        assert_eq!(session.submit(3, &old).unwrap(), 2);
        let replacement = batch(r#"[{"key":7,"payload":"new"}]"#);
        assert_eq!(session.submit(4, &replacement).unwrap(), 1);
        wait_until(|| session.ready(4, 7));
        assert_eq!(session.take(4, 7).unwrap(), b"new");
        assert!(!session.ready(3, 1));
        assert!(!session.ready(3, 2));

        let duplicate = batch(r#"[{"key":8,"payload":"a"},{"key":8,"payload":"b"}]"#);
        assert!(session.submit(4, &duplicate).is_err());
        session.stop(true);
    }

    #[test]
    fn registered_layout_is_reused_by_later_generations() {
        let session = Session::new(1, 2, 2, 4096).unwrap();
        let first = br#"{"version":1,"document":{"version":2,"space-width":8,"style-count":0,"styles":[],"root":{"type":"box","region-id":1,"content":{"lines":[{"clusters":[{"text":"x","width":8,"cjk":false,"space":false}]}]},"child":null,"content-width-exact":false,"width":{"kind":"viewport"},"min-width":{"kind":"pixels","value":0},"max-width":{"kind":"none"},"height":{"kind":"auto"},"min-height":{"kind":"lines","value":0},"max-height":{"kind":"none"},"box-sizing":"border-box","padding-left":0,"padding-right":0,"padding-top":0,"padding-bottom":0,"margin-left":0,"margin-right":0,"margin-top":0,"margin-bottom":0,"border-left":0,"border-right":0,"foreground-style":null,"background-style":null,"border-left-style":null,"border-right-style":null,"border-top-style":null,"border-bottom-style":null,"text-align":"left","vertical-align":"top","overflow":"scroll","wrap-mode":"word","scroll-offset":0}},"frames":[{"key":1,"viewport-width":80,"viewport-height":10}]}"#;
        assert_eq!(session.submit(1, first).unwrap(), 1);
        wait_until(|| session.ready(1, 1));
        assert!(!session.take(1, 1).unwrap().is_empty());

        let reused =
            br#"{"version":1,"frames":[{"key":2,"viewport-width":120,"viewport-height":12}]}"#;
        assert_eq!(session.submit(2, reused).unwrap(), 1);
        wait_until(|| session.ready(2, 2));
        assert!(!session.take(2, 2).unwrap().is_empty());
        session.stop(true);
    }

    #[test]
    fn confirmed_baseline_is_promoted_only_after_explicit_confirmation() {
        let session = Session::new(1, 4, 4, 64 * 1024).unwrap();
        let first = proof_layout_payload(
            r#"[{"key":1,"viewport-width":120,"viewport-height":10,"root-width":120,"patch":true,"base-viewport-width":80,"base-viewport-height":10,"base-root-width":80,"runtime-revision":0,"context-hash":77}]"#,
        );
        assert_eq!(session.submit(1, &first).unwrap(), 1);
        wait_until(|| session.ready(1, 1));
        assert!(!session.confirm(1, 99, 1).unwrap());
        let first_stats = session.stats();
        assert_eq!(first_stats.baseline_misses, 1);
        assert_eq!(first_stats.baseline_hits, 0);
        assert_eq!(first_stats.base_renders, 1);
        assert_eq!(first_stats.target_renders, 1);
        assert_eq!(first_stats.pending_baselines, 1);
        assert!(!first_stats.confirmed_baseline);

        assert!(!session.take(1, 1).unwrap().is_empty());
        let taken_stats = session.stats();
        assert_eq!(taken_stats.pending_baselines, 1);
        assert!(!taken_stats.confirmed_baseline);
        assert!(session.confirm(1, 1, 0).is_err());
        assert!(!session.stats().confirmed_baseline);

        let first_again = proof_layout_payload(
            r#"[{"key":2,"viewport-width":120,"viewport-height":10,"root-width":120,"patch":true,"base-viewport-width":80,"base-viewport-height":10,"base-root-width":80,"runtime-revision":0,"context-hash":77}]"#,
        );
        assert_eq!(session.submit(2, &first_again).unwrap(), 1);
        wait_until(|| session.ready(2, 2));
        assert!(session.confirm(2, 2, 1).unwrap());
        assert!(session.take(2, 2).unwrap().len() >= MIN_TAPE_BYTES);

        let second = batch(
            r#"[{"key":3,"viewport-width":80,"viewport-height":10,"root-width":80,"patch":true,"base-viewport-width":120,"base-viewport-height":10,"base-root-width":120,"runtime-revision":1,"context-hash":77}]"#,
        );
        assert_eq!(session.submit(3, &second).unwrap(), 1);
        wait_until(|| session.ready(3, 3));
        assert!(!session.take(3, 3).unwrap().is_empty());
        let final_stats = session.stats();
        assert_eq!(final_stats.baseline_misses, 2);
        assert_eq!(final_stats.baseline_hits, 1);
        assert_eq!(final_stats.base_renders, 2);
        assert_eq!(final_stats.target_renders, 3);
        session.stop(true);
    }

    #[test]
    fn confirmed_fork_shares_only_immutable_baseline() {
        let parent = Session::new(1, 4, 4, 64 * 1024).unwrap();
        assert!(parent.fork_confirmed().is_err());

        let first = proof_layout_payload(
            r#"[{"key":1,"viewport-width":120,"viewport-height":10,"root-width":120,"runtime-revision":0,"context-hash":77}]"#,
        );
        let first_tape = parent.render_sync(1, &first).unwrap();
        assert!(!tape_patch_p(&first_tape));
        assert!(parent.confirm(1, 1, 1).unwrap());
        let parent_before = parent.stats();

        let child = parent.fork_confirmed().unwrap();
        let child_initial = child.stats();
        assert_ne!(child_initial.session_id, parent_before.session_id);
        assert_eq!(child_initial.generation, 0);
        assert_eq!(child_initial.queued_jobs, 0);
        assert_eq!(child_initial.ready_results, 0);
        assert_eq!(child_initial.pending_baselines, 0);
        assert!(child_initial.confirmed_baseline);
        assert!(child_initial.layout_registered);

        parent.stop(true);
        let second = retained_layout_payload(
            1,
            r#"[{"key":2,"viewport-width":80,"viewport-height":10,"root-width":80,"patch":true,"base-viewport-width":120,"base-viewport-height":10,"base-root-width":120,"runtime-revision":1,"context-hash":77}]"#,
        );
        let second_tape = child.render_sync(1, &second).unwrap();
        assert!(tape_patch_p(&second_tape));
        let child_rendered = child.stats();
        assert_eq!(child_rendered.baseline_hits, 1);
        assert_eq!(child_rendered.base_renders, 0);
        assert_eq!(child_rendered.target_renders, 1);
        assert_eq!(child_rendered.pending_baselines, 1);
        assert!(child.confirm(1, 2, 2).unwrap());
        assert!(child.stats().confirmed_baseline);

        let parent_after = parent.stats();
        assert_eq!(parent_after.baseline_hits, parent_before.baseline_hits);
        assert_eq!(parent_after.base_renders, parent_before.base_renders);
        assert_eq!(parent_after.target_renders, parent_before.target_renders);
        assert_eq!(
            parent_after.pending_baselines,
            parent_before.pending_baselines
        );
        child.stop(true);
    }

    #[test]
    fn confirmed_fork_reuses_retained_document_without_reparse_or_revalidation() {
        let parent = Session::new(1, 4, 4, 64 * 1024).unwrap();
        let first = proof_layout_payload(
            r#"[{"key":1,"viewport-width":120,"viewport-height":10,"root-width":120,"runtime-revision":0,"context-hash":77}]"#,
        );
        assert!(!parent.render_sync(1, &first).unwrap().is_empty());
        assert!(parent.confirm(1, 1, 1).unwrap());

        let child = parent.fork_confirmed().unwrap();
        let retained = retained_layout_payload(
            1,
            r#"[{"key":2,"viewport-width":80,"viewport-height":10,"root-width":80,"patch":true,"base-viewport-width":120,"base-viewport-height":10,"base-root-width":120,"runtime-revision":1,"context-hash":77}]"#,
        );
        let tape = child.render_sync(1, &retained).unwrap();
        assert!(tape_patch_p(&tape));
        let stats = child.stats();
        assert_eq!(stats.document_parses, 0);
        assert_eq!(stats.document_validations, 0);
        assert_eq!(stats.document_reuses, 1);
        assert!(child.confirm(1, 2, 2).unwrap());

        let grandchild = child.fork_confirmed().unwrap();
        let next = retained_layout_payload(
            1,
            r#"[{"key":3,"viewport-width":100,"viewport-height":10,"root-width":100,"patch":true,"base-viewport-width":80,"base-viewport-height":10,"base-root-width":80,"runtime-revision":2,"context-hash":77}]"#,
        );
        assert!(tape_patch_p(&grandchild.render_sync(1, &next).unwrap()));
        assert_eq!(grandchild.stats().document_reuses, 1);
        parent.stop(true);
        child.stop(true);
        grandchild.stop(true);
    }

    #[test]
    fn nonzero_document_delta_renders_and_promotes_without_full_reparse() {
        let session = Session::new(1, 4, 4, 64 * 1024).unwrap();
        let first = identified_proof_layout_payload(
            r#"[{"key":1,"viewport-width":80,"viewport-height":10,"root-width":80,"runtime-revision":0,"context-hash":77}]"#,
        );
        let first_tape = session.render_sync(1, &first).unwrap();
        assert!(!tape_patch_p(&first_tape));
        assert!(session.confirm(1, 1, 1).unwrap());

        let delta = serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "document-base-revision": 1,
            "document-target-revision": 2,
            "document-delta": {
                "style-base-count": 0,
                "styles-append": [],
                "property-template-base-count": 0,
                "property-template-target-count": 0,
                "entries": [{
                    "node-id": 1,
                    "expected-revision": 7,
                    "target-revision": 21,
                    "slot-patches": [{
                        "slot": 0,
                        "local": {
                            "content": {"lines": [{"clusters": [{
                                "text": "y", "width": 8, "cjk": false, "space": false
                            }]}]}
                        }
                    }]
                }]
            },
            "frames": [{
                "key": 2,
                "viewport-width": 80,
                "viewport-height": 10,
                "root-width": 80,
                "patch": true,
                "base-viewport-width": 80,
                "base-viewport-height": 10,
                "base-root-width": 80,
                "runtime-revision": 1,
                "context-hash": 77
            }]
        }))
        .unwrap();
        let delta_tape = session.render_sync(2, &delta).unwrap();
        assert!(tape_patch_p(&delta_tape));
        let stats = session.stats();
        assert_eq!(stats.document_parses, 1);
        assert_eq!(stats.document_validations, 1);
        assert_eq!(stats.document_full_nodes_parsed, 1);
        assert_eq!(stats.document_delta_entries_parsed, 1);
        assert_eq!(stats.document_delta_entries_validated, 1);
        assert_eq!(stats.document_trie_path_nodes_copied, 17);
        assert_eq!(stats.document_delta_input_bytes, delta.len() as u64);
        assert_eq!(stats.source_change_work.fields_compared, 1);
        assert_eq!(stats.source_change_work.text_lines_compared, 1);
        assert_eq!(stats.source_change_work.text_clusters_compared, 1);
        assert_eq!(stats.source_change_work.text_bytes_compared, 1);
        assert_eq!(stats.source_change_work.local_nodes_copied, 1);
        assert_eq!(stats.source_change_work.owners_changed, 1);
        assert_eq!(stats.source_change_work.slots_changed, 1);
        assert_eq!(stats.source_change_work.fields_changed, 1);
        assert_eq!(
            stats.document_resolver_lookups, stats.target_renders,
            "each single-owner render resolves its root; retained context validation resolves no nodes"
        );
        assert!(session.confirm(2, 2, 2).unwrap());

        let child = session.fork_confirmed().unwrap();
        let retained = retained_layout_payload(
            2,
            r#"[{"key":3,"viewport-width":80,"viewport-height":10,"root-width":80,"runtime-revision":2,"context-hash":77}]"#,
        );
        assert!(!child.render_sync(1, &retained).unwrap().is_empty());
        session.stop(true);
        child.stop(true);
    }

    #[test]
    fn retained_source_input_counts_noops_and_registries_without_publishing_failed_work() {
        let session = Session::new(1, 4, 4, 64 * 1024).unwrap();
        let first = identified_proof_layout_payload(
            r#"[{"key":1,"viewport-width":80,"viewport-height":10,"root-width":80,"runtime-revision":0,"context-hash":77}]"#,
        );
        session.render_sync(1, &first).unwrap();
        assert!(session.confirm(1, 1, 1).unwrap());
        let document: serde_json::Value = serde_json::from_slice(&first).unwrap();
        let content = document["document"]["root"]["content"].clone();
        let payload = |padding| {
            serde_json::to_vec(&serde_json::json!({
            "version": 1, "document-base-revision": 1, "document-target-revision": 2,
            "document-delta": {
                "style-base-count": 0, "styles-append": [{"mode": "add", "face": {"foreground": "red"}}],
                "property-template-base-count": 0, "property-template-target-count": 2,
                "entries": [{"node-id": 1, "expected-revision": 7, "target-revision": 8,
                    "slot-patches": [{"slot": 0, "local": {"content": content, "padding-left": padding}}]}]
            },
            "frames": [{"key": 2, "viewport-width": 80, "viewport-height": 10,
                "root-width": 80, "runtime-revision": 1, "context-hash": 77}]
        })).unwrap()
        };
        let before = session.stats().source_change_work;
        assert!(session.render_sync(2, &payload(-1)).is_err());
        assert_eq!(session.stats().source_change_work, before);
        session.render_sync(3, &payload(0)).unwrap();
        let work = session.stats().source_change_work;
        assert_eq!(
            (
                work.fields_compared,
                work.text_lines_compared,
                work.text_clusters_compared,
                work.text_bytes_compared
            ),
            (2, 1, 1, 1)
        );
        assert_eq!(
            (
                work.local_nodes_copied,
                work.owners_changed,
                work.slots_changed,
                work.fields_changed
            ),
            (0, 0, 0, 0)
        );
        assert_eq!(
            (work.styles_appended, work.property_templates_added),
            (1, 2)
        );
        assert!(session.confirm(3, 2, 2).unwrap());
        session.stop(true);
    }

    #[test]
    fn retained_document_reuse_rejects_wrong_or_ambiguous_revision() {
        let parent = Session::new(1, 4, 4, 64 * 1024).unwrap();
        let first = proof_layout_payload(
            r#"[{"key":1,"viewport-width":120,"viewport-height":10,"runtime-revision":0}]"#,
        );
        parent.render_sync(1, &first).unwrap();
        assert!(parent.confirm(1, 1, 1).unwrap());
        let child = parent.fork_confirmed().unwrap();

        let wrong_document = retained_layout_payload(
            2,
            r#"[{"key":2,"viewport-width":80,"viewport-height":10,"runtime-revision":1}]"#,
        );
        assert!(child
            .render_sync(1, &wrong_document)
            .unwrap_err()
            .contains("document revision"));
        let wrong_runtime = retained_layout_payload(
            1,
            r#"[{"key":2,"viewport-width":80,"viewport-height":10,"runtime-revision":0}]"#,
        );
        assert!(child
            .render_sync(1, &wrong_runtime)
            .unwrap_err()
            .contains("runtime revision"));
        let ambiguous = br#"{"version":1,"frames":[{"key":2,"viewport-width":80,"viewport-height":10,"runtime-revision":1}]}"#;
        assert!(child
            .render_sync(1, ambiguous)
            .unwrap_err()
            .contains("document revisions"));
        assert_eq!(child.stats().document_reuses, 0);
        assert!(parent.stats().confirmed_baseline);
        parent.stop(true);
        child.stop(true);
    }

    #[test]
    fn cancelled_replacement_does_not_promote_or_contaminate_its_parent() {
        let parent = Session::new(1, 4, 4, 64 * 1024).unwrap();
        let first = proof_layout_payload(
            r#"[{"key":1,"viewport-width":120,"viewport-height":10,"runtime-revision":0}]"#,
        );
        parent.render_sync(1, &first).unwrap();
        assert!(parent.confirm(1, 1, 1).unwrap());
        let child = parent.fork_confirmed().unwrap();
        let replacement = replacement_layout_payload(
            1,
            2,
            r#"[{"key":2,"viewport-width":100,"viewport-height":10,"runtime-revision":1}]"#,
        );
        assert!(!child.render_sync(1, &replacement).unwrap().is_empty());
        assert_eq!(child.stats().pending_baselines, 1);
        child.cancel(1);
        assert_eq!(child.stats().pending_baselines, 0);

        let retry = child.fork_confirmed().unwrap();
        let retained = retained_layout_payload(
            1,
            r#"[{"key":3,"viewport-width":80,"viewport-height":10,"runtime-revision":1}]"#,
        );
        assert!(!retry.render_sync(1, &retained).unwrap().is_empty());
        assert_eq!(retry.stats().document_reuses, 1);
        assert_eq!(parent.stats().document_parses, 1);
        assert_eq!(parent.stats().document_reuses, 0);
        parent.stop(true);
        child.stop(true);
        retry.stop(true);
    }

    #[test]
    fn async_omit_uses_the_latest_synchronously_confirmed_document() {
        let parent = Session::new(1, 4, 4, 64 * 1024).unwrap();
        let first = proof_layout_payload(
            r#"[{"key":1,"viewport-width":120,"viewport-height":10,"runtime-revision":0}]"#,
        );
        let first_count = full_tape_character_count(&parent.render_sync(1, &first).unwrap());
        assert!(parent.confirm(1, 1, 1).unwrap());
        let parent_omit =
            batch(r#"[{"key":2,"viewport-width":120,"viewport-height":10,"runtime-revision":1}]"#);
        assert_eq!(parent.submit(2, &parent_omit).unwrap(), 1);
        wait_until(|| parent.ready(2, 2));
        assert_eq!(
            full_tape_character_count(&parent.take(2, 2).unwrap()),
            first_count
        );

        let child = parent.fork_confirmed().unwrap();
        let replacement = String::from_utf8(replacement_layout_payload(
            1,
            2,
            r#"[{"key":3,"viewport-width":120,"viewport-height":10,"runtime-revision":1}]"#,
        ))
        .unwrap()
        .replacen(r#""text":"x","width":8"#, r#""text":"yy","width":16"#, 1)
        .into_bytes();
        let replacement_count =
            full_tape_character_count(&child.render_sync(1, &replacement).unwrap());
        assert_ne!(replacement_count, first_count);
        assert!(child.confirm(1, 3, 2).unwrap());
        let child_omit =
            batch(r#"[{"key":4,"viewport-width":120,"viewport-height":10,"runtime-revision":2}]"#);
        assert_eq!(child.submit(2, &child_omit).unwrap(), 1);
        wait_until(|| child.ready(2, 4));
        assert_eq!(
            full_tape_character_count(&child.take(2, 4).unwrap()),
            replacement_count
        );
        parent.stop(true);
        child.stop(true);
    }

    #[test]
    fn confirmed_fork_falls_back_to_full_frame_on_identity_mismatch() {
        let parent = Session::new(1, 4, 4, 64 * 1024).unwrap();
        let first = proof_layout_payload(
            r#"[{"key":1,"viewport-width":120,"viewport-height":10,"root-width":120,"runtime-revision":0,"context-hash":77}]"#,
        );
        assert!(!parent.render_sync(1, &first).unwrap().is_empty());
        assert!(parent.confirm(1, 1, 1).unwrap());

        let child = parent.fork_confirmed().unwrap();
        let mismatched = replacement_layout_payload(
            1,
            2,
            r#"[{"key":2,"viewport-width":80,"viewport-height":10,"root-width":80,"patch":true,"base-viewport-width":120,"base-viewport-height":10,"base-root-width":120,"runtime-revision":2,"context-hash":77}]"#,
        );
        let tape = child.render_sync(1, &mismatched).unwrap();
        assert!(!tape_patch_p(&tape));
        assert_eq!(child.stats().baseline_hits, 0);
        assert_eq!(child.stats().base_renders, 0);
        assert_eq!(child.stats().target_renders, 1);
        parent.stop(true);
        child.stop(true);
    }

    #[test]
    fn confirmed_patch_base_accepts_only_append_stable_style_registries() {
        let parent = Session::new(1, 4, 4, 64 * 1024).unwrap();
        let first = styled_layout_payload(
            0,
            1,
            1,
            r##"[{"mode":"set","face":{"foreground":"#111111"}}]"##,
            0,
            r#"[{"key":1,"viewport-width":120,"viewport-height":10,"root-width":120,"runtime-revision":0,"context-hash":77}]"#,
        );
        assert!(!tape_patch_p(&parent.render_sync(1, &first).unwrap()));
        assert!(parent.confirm(1, 1, 1).unwrap());

        let appended_child = parent.fork_confirmed().unwrap();
        let appended = styled_layout_payload(
            1,
            2,
            2,
            r##"[{"mode":"set","face":{"foreground":"#111111"}},{"mode":"set","face":{"background":"#222222"}}]"##,
            1,
            r#"[{"key":2,"viewport-width":120,"viewport-height":10,"root-width":120,"patch":true,"base-viewport-width":120,"base-viewport-height":10,"base-root-width":120,"runtime-revision":1,"context-hash":77}]"#,
        );
        assert!(tape_patch_p(
            &appended_child.render_sync(1, &appended).unwrap()
        ));
        assert_eq!(appended_child.stats().baseline_hits, 1);
        assert_eq!(appended_child.stats().base_renders, 0);

        let changed_child = parent.fork_confirmed().unwrap();
        let changed = styled_layout_payload(
            1,
            2,
            2,
            r##"[{"mode":"set","face":{"foreground":"#999999"}},{"mode":"set","face":{"background":"#222222"}}]"##,
            1,
            r#"[{"key":3,"viewport-width":120,"viewport-height":10,"root-width":120,"patch":true,"base-viewport-width":120,"base-viewport-height":10,"base-root-width":120,"runtime-revision":1,"context-hash":77}]"#,
        );
        assert!(!tape_patch_p(
            &changed_child.render_sync(1, &changed).unwrap()
        ));
        assert_eq!(changed_child.stats().baseline_hits, 0);
        assert_eq!(changed_child.stats().base_renders, 0);

        parent.stop(true);
        appended_child.stop(true);
        changed_child.stop(true);
    }

    #[test]
    fn synchronous_proof_render_returns_full_tape_without_session() {
        let payload =
            proof_layout_payload(r#"[{"key":9,"viewport-width":80,"viewport-height":10}]"#);
        let tape = render_proof(&payload).unwrap();
        assert!(tape.len() >= MIN_TAPE_BYTES);
        assert_eq!(read_le_u64(&tape, 20), SYNC_RENDER_SESSION_ID);
    }

    #[test]
    fn synchronous_proof_render_distinguishes_known_and_unknown_width() {
        let known = render_proof(&column_proof_layout_payload(
            r#"[{"key":1,"viewport-width":80,"viewport-height":10}]"#,
        ))
        .unwrap();
        let unknown = render_proof(&column_proof_layout_payload(
            r#"[{"key":1,"viewport-width":80,"viewport-width-known":false,"viewport-height":10}]"#,
        ))
        .unwrap();

        assert_eq!(full_tape_character_count(&unknown), 5);
        assert_eq!(full_tape_character_count(&known), 6);
        assert_eq!(full_tape_line_widths(&unknown), vec![16, 16]);
        assert_eq!(full_tape_line_widths(&known), vec![80, 80]);
    }

    #[test]
    fn synchronous_proof_render_rejects_non_proof_batches() {
        let echo = batch(r#"[{"key":1,"payload":"not-layout"}]"#);
        assert!(render_proof(&echo)
            .unwrap_err()
            .contains("requires an inline document"));

        let multiple = proof_layout_payload(
            r#"[{"key":1,"viewport-width":80,"viewport-height":10},{"key":2,"viewport-width":80,"viewport-height":10}]"#,
        );
        assert!(render_proof(&multiple)
            .unwrap_err()
            .contains("exactly one layout frame"));

        let patch = proof_layout_payload(
            r#"[{"key":1,"viewport-width":80,"viewport-height":10,"patch":true,"base-viewport-width":80,"base-viewport-height":10}]"#,
        );
        assert!(render_proof(&patch)
            .unwrap_err()
            .contains("full layout frames only"));

        let incomplete = proof_layout_payload(
            r#"[{"key":1,"viewport-width":80,"viewport-height":10,"complete":false}]"#,
        );
        assert!(render_proof(&incomplete)
            .unwrap_err()
            .contains("requires complete frames"));

        let full_with_base = proof_layout_payload(
            r#"[{"key":1,"viewport-width":80,"viewport-height":10,"base-viewport-width-known":false}]"#,
        );
        assert!(render_proof(&full_with_base)
            .unwrap_err()
            .contains("cannot contain base geometry"));
    }
}
