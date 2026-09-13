use etaf_core::{diff_commit_batch, CommitBatch, SpanEdit};
use serde::{Deserialize, Deserializer};
use serde_json::{Map as JsonMap, Value as JsonValue};
use std::cell::Cell;
use std::collections::BTreeMap;
use std::collections::HashSet;
use std::sync::Arc;

#[path = "source_topology.rs"]
mod source_topology;
use source_topology::{LocalStep, SourceTopology, TopologyBuilder};

#[path = "atom_plan.rs"]
mod atom_plan;
use atom_plan::AtomPlan;
pub(crate) use atom_plan::AtomPlanWork;

pub(crate) fn reset_atom_plan_work() {
    atom_plan::reset_work();
}

pub(crate) fn atom_plan_work() -> AtomPlanWork {
    atom_plan::work()
}

#[path = "line_plan.rs"]
mod line_plan;
pub(crate) use line_plan::LinePlanWork;
use line_plan::{BoxProjectionSlot, FrameSpec, LineOp, LinePlan, PlanChange, ProjectionState};

pub(crate) fn reset_line_plan_work() {
    line_plan::reset_work();
}

pub(crate) fn line_plan_work() -> LinePlanWork {
    line_plan::work()
}

#[path = "composition.rs"]
mod composition;
#[path = "evaluation.rs"]
mod evaluation;
pub(crate) use evaluation::{EvalWork, RetainedFrame};
use evaluation::{Phase, RenderScope};

pub(crate) fn reset_eval_work() {
    evaluation::reset_work();
}
pub(crate) fn eval_work() -> EvalWork {
    evaluation::work()
}

fn deserialize_arc_vec<'de, D, T>(deserializer: D) -> Result<Arc<Vec<T>>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Vec::<T>::deserialize(deserializer).map(Arc::new)
}

fn deserialize_optional_arc<'de, D, T>(deserializer: D) -> Result<Option<Arc<T>>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer).map(|value| value.map(Arc::new))
}

fn deserialize_arc<'de, D, T>(deserializer: D) -> Result<Arc<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    T::deserialize(deserializer).map(Arc::new)
}

thread_local! {
    static RESOLVER_LOOKUP_COUNT: Cell<u64> = const { Cell::new(0) };

}

pub(crate) fn reset_resolver_lookups() {
    RESOLVER_LOOKUP_COUNT.with(|count| count.set(0));
}

pub(crate) fn resolver_lookups() -> u64 {
    RESOLVER_LOOKUP_COUNT.with(Cell::get)
}

const LAYOUT_VERSION: u32 = 2;
pub const TAPE_VERSION: u16 = 12;
pub const TAPE_HEADER_LEN: usize = 112;
pub const MIN_TAPE_BYTES: usize = TAPE_HEADER_LEN + 5;
const TAPE_MAGIC: &[u8; 4] = b"EBXT";
const TAPE_FLAG_OK: u16 = 1;
const TAPE_FLAG_COMPLETE: u16 = 1 << 1;
const TAPE_FLAG_PATCH: u16 = 1 << 2;
const MAX_LAYOUT_DEPTH: usize = 256;
const MAX_LAYOUT_NODES: usize = 100_000;
pub const MAX_LAYOUT_DIMENSION: i64 = 1_000_000;
const MAX_LAYOUT_WORK_UNITS: usize = 250_000;
const MAX_TAPE_PROPERTY_ENTRIES: usize = MAX_LAYOUT_DEPTH * 16;
const MAX_PROPERTY_TEMPLATE_COUNT: u32 = MAX_LAYOUT_NODES as u32;
const MAX_TAPE_METADATA_RECORDS: usize = MAX_LAYOUT_WORK_UNITS;
const MAX_STYLE_STRING_BYTES: usize = 4096;

const METADATA_ROLE_CONTENT: u8 = 1;
const METADATA_ROLE_CONTENT_OWNER: u8 = 2;
const METADATA_ROLE_PADDING_TOP: u8 = 3;
const METADATA_ROLE_PADDING_BOTTOM: u8 = 4;
const METADATA_ROLE_PADDING_LEFT: u8 = 5;
const METADATA_ROLE_PADDING_RIGHT: u8 = 6;
const METADATA_ROLE_MARGIN_TOP: u8 = 7;
const METADATA_ROLE_MARGIN_BOTTOM: u8 = 8;
const METADATA_ROLE_MARGIN_LEFT: u8 = 9;
const METADATA_ROLE_MARGIN_RIGHT: u8 = 10;
const METADATA_ROLE_BORDER_TOP: u8 = 11;
const METADATA_ROLE_BORDER_BOTTOM: u8 = 12;
const METADATA_ROLE_BORDER_LEFT: u8 = 13;
const METADATA_ROLE_BORDER_RIGHT: u8 = 14;
const METADATA_BOX_EXTENT: u8 = 15;
const METADATA_SCROLL_CONTENT: u8 = 16;
const METADATA_SCROLL_OWNER: u8 = 17;
const METADATA_SCROLL_WINDOW: u8 = 18;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
pub struct LayoutDocument {
    version: u32,
    space_width: i64,
    style_count: u32,
    #[serde(default)]
    property_template_count: u32,
    #[serde(default)]
    pub(crate) styles: Vec<StyleTemplate>,
    root: LayoutNode,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
pub(crate) struct DocumentDelta {
    pub(crate) style_base_count: u32,
    #[serde(default)]
    pub(crate) styles_append: Vec<StyleTemplate>,
    pub(crate) property_template_base_count: u32,
    pub(crate) property_template_target_count: u32,
    pub(crate) entries: Vec<DocumentDeltaEntry>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
pub(crate) struct DocumentDeltaEntry {
    pub(crate) node_id: u64,
    pub(crate) expected_revision: u64,
    pub(crate) target_revision: u64,
    #[serde(default)]
    slot_patches: Vec<LocalSlotPatch>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct LocalSlotPatch {
    slot: u8,
    local: JsonMap<String, JsonValue>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LocalField {
    RegionId,
    Content,
    ContentRegionId,
    ContentTypographyStyle,
    ContentForegroundStyle,
    ContentSurfaceTemplateId,
    ContentWidthExact,
    ContentMinWidth,
    Width,
    MinWidth,
    MaxWidth,
    Height,
    MinHeight,
    MaxHeight,
    BoxSizing,
    PaddingLeft,
    PaddingRight,
    PaddingTop,
    PaddingBottom,
    MarginLeft,
    MarginRight,
    MarginTop,
    MarginBottom,
    BorderLeft,
    BorderRight,
    TypographyStyle,
    ForegroundStyle,
    BackgroundStyle,
    BorderLeftStyle,
    BorderRightStyle,
    BorderTopStyle,
    BorderBottomStyle,
    SurfaceTemplateId,
    TextAlign,
    VerticalAlign,
    Overflow,
    WrapMode,
    ScrollOffset,
    Direction,
    Wrap,
    Justify,
    AlignItems,
    AlignContent,
    RowGap,
    ColumnGap,
}

#[derive(Debug)]
struct SlotChange {
    slot: u8,
    fields: Vec<LocalField>,
}

#[derive(Debug)]
struct OwnerChange {
    node_id: u64,
    expected_revision: u64,
    target_revision: u64,
    slots: Vec<SlotChange>,
}

/// Transient source facts for one exact pair of documents, never retained in a
/// document or confirmed baseline. The current renderer does not cache by these facts.
#[derive(Debug)]
pub(crate) struct SourceChanges {
    base: Arc<RetainedDocument>,
    target: Arc<RetainedDocument>,
    owners: Vec<OwnerChange>,
    styles: std::ops::Range<u32>,
    property_templates: std::ops::Range<u32>,
}

impl SourceChanges {
    pub(crate) fn applies_to(
        &self,
        base: &Arc<RetainedDocument>,
        target: &Arc<RetainedDocument>,
    ) -> bool {
        Arc::ptr_eq(&self.base, base) && Arc::ptr_eq(&self.target, target)
    }

    pub(crate) fn visit_changed_slots(
        &self,
        mut visit: impl FnMut(u64, u64, u64, u8, &[LocalField]),
    ) {
        for owner in &self.owners {
            for slot in &owner.slots {
                visit(
                    owner.node_id,
                    owner.expected_revision,
                    owner.target_revision,
                    slot.slot,
                    &slot.fields,
                );
            }
        }
    }

    pub(crate) fn registry_ranges(&self) -> (std::ops::Range<u32>, std::ops::Range<u32>) {
        (self.styles.clone(), self.property_templates.clone())
    }
}

/// Counts concrete comparisons/copies at delta preparation and emitted source
/// changes at input integration. These are not layout-cache or topology counters.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) struct SourceChangeWork {
    pub(crate) fields_compared: u64,
    pub(crate) size_nodes_compared: u64,
    pub(crate) text_lines_compared: u64,
    pub(crate) text_clusters_compared: u64,
    pub(crate) text_bytes_compared: u64,
    pub(crate) local_nodes_copied: u64,
    pub(crate) owners_changed: u64,
    pub(crate) slots_changed: u64,
    pub(crate) fields_changed: u64,
    pub(crate) styles_appended: u64,
    pub(crate) property_templates_added: u64,
}

impl SourceChangeWork {
    pub(crate) fn accumulate(&mut self, other: Self) {
        self.fields_compared += other.fields_compared;
        self.size_nodes_compared += other.size_nodes_compared;
        self.text_lines_compared += other.text_lines_compared;
        self.text_clusters_compared += other.text_clusters_compared;
        self.text_bytes_compared += other.text_bytes_compared;
        self.local_nodes_copied += other.local_nodes_copied;
        self.owners_changed += other.owners_changed;
        self.slots_changed += other.slots_changed;
        self.fields_changed += other.fields_changed;
        self.styles_appended += other.styles_appended;
        self.property_templates_added += other.property_templates_added;
    }
}

#[derive(Debug, Default)]
pub(crate) struct DeltaStats {
    pub(crate) entries_parsed: u64,
    pub(crate) trie_path_nodes_copied: u64,
    pub(crate) source_work: SourceChangeWork,
}

#[derive(Debug)]
pub(crate) struct AppliedDelta {
    pub(crate) document: Arc<RetainedDocument>,
    pub(crate) changes: SourceChanges,
    pub(crate) stats: DeltaStats,
}

struct PatchedOwner {
    node: Arc<LayoutNode>,
    slot_work: [Arc<LocalWorkSummary>; 2],
    work_delta: LocalWorkDelta,
    slots: Vec<SlotChange>,
}

struct PatchedLocal<'a> {
    node: Option<LayoutNode>,
    // Names come from the same dispatch as the typed identifiers, for the
    // existing local-work summary; no second field classification is needed.
    fields: Vec<(LocalField, &'a str)>,
}

#[derive(Debug)]
struct RetainedEntry {
    revision: u64,
    node: Arc<LayoutNode>,
    slot_work: [Arc<LocalWorkSummary>; 2],
}

#[derive(Debug, Clone, Default)]
struct LocalWorkSummary(BTreeMap<&'static str, LocalFieldWork>);

#[derive(Debug, Clone, PartialEq, Eq)]
struct LocalFieldWork {
    units: usize,
    viewport_heights: usize,
}

struct LocalWorkDelta {
    units: isize,
    viewport_heights: i128,
}

#[derive(Debug)]
struct RadixNode {
    children: [Option<Arc<RadixNode>>; 16],
    value: Option<Arc<RetainedEntry>>,
}

impl Default for RadixNode {
    fn default() -> Self {
        Self {
            children: std::array::from_fn(|_| None),
            value: None,
        }
    }
}

fn radix_lookup(root: &Arc<RadixNode>, key: u64) -> Option<&Arc<RetainedEntry>> {
    let mut current = root.as_ref();
    for level in 0..16 {
        let shift = 60 - level * 4;
        current = current.children[((key >> shift) & 0xf) as usize].as_deref()?;
    }
    current.value.as_ref()
}

fn radix_insert(
    root: &Arc<RadixNode>,
    key: u64,
    value: Arc<RetainedEntry>,
) -> (Arc<RadixNode>, u64) {
    fn insert_at(
        node: &Arc<RadixNode>,
        key: u64,
        level: usize,
        value: &Arc<RetainedEntry>,
        copied: &mut u64,
    ) -> Arc<RadixNode> {
        *copied += 1;
        let mut children = node.children.clone();
        let mut stored = node.value.clone();
        if level == 16 {
            stored = Some(Arc::clone(value));
        } else {
            let shift = 60 - level * 4;
            let index = ((key >> shift) & 0xf) as usize;
            let child = children[index]
                .clone()
                .unwrap_or_else(|| Arc::new(RadixNode::default()));
            children[index] = Some(insert_at(&child, key, level + 1, value, copied));
        }
        Arc::new(RadixNode {
            children,
            value: stored,
        })
    }

    let mut copied = 0;
    (insert_at(root, key, 0, &value, &mut copied), copied)
}

#[derive(Debug)]
pub(crate) struct RetainedDocument {
    root_id: u64,
    entries: Arc<RadixNode>,
    topology: Arc<SourceTopology>,
    styles: Arc<StyleRadixNode>,
    style_count: u32,
    property_template_count: u32,
    work_units: usize,
    context_viewport_heights: usize,
}

#[derive(Debug)]
struct StyleRadixNode {
    children: [Option<Arc<StyleRadixNode>>; 16],
    value: Option<Arc<StyleTemplate>>,
}

impl Default for StyleRadixNode {
    fn default() -> Self {
        Self {
            children: std::array::from_fn(|_| None),
            value: None,
        }
    }
}

fn style_lookup(root: &Arc<StyleRadixNode>, key: u64) -> Option<&Arc<StyleTemplate>> {
    let mut current = root.as_ref();
    for level in 0..16 {
        let shift = 60 - level * 4;
        current = current.children[((key >> shift) & 0xf) as usize].as_deref()?;
    }
    current.value.as_ref()
}

fn style_insert(
    root: &Arc<StyleRadixNode>,
    key: u64,
    value: Arc<StyleTemplate>,
) -> (Arc<StyleRadixNode>, u64) {
    fn insert_at(
        node: &Arc<StyleRadixNode>,
        key: u64,
        level: usize,
        value: &Arc<StyleTemplate>,
        copied: &mut u64,
    ) -> Arc<StyleRadixNode> {
        *copied += 1;
        let mut children = node.children.clone();
        let mut stored = node.value.clone();
        if level == 16 {
            stored = Some(Arc::clone(value));
        } else {
            let shift = 60 - level * 4;
            let index = ((key >> shift) & 0xf) as usize;
            let child = children[index]
                .clone()
                .unwrap_or_else(|| Arc::new(StyleRadixNode::default()));
            children[index] = Some(insert_at(&child, key, level + 1, value, copied));
        }
        Arc::new(StyleRadixNode {
            children,
            value: stored,
        })
    }

    let mut copied = 0;
    (insert_at(root, key, 0, &value, &mut copied), copied)
}

impl LayoutNode {
    fn node_id(&self) -> Option<u64> {
        match self {
            Self::Box { node_id, .. }
            | Self::Text { node_id, .. }
            | Self::Row { node_id, .. }
            | Self::Column { node_id, .. }
            | Self::Flex { node_id, .. } => *node_id,
            Self::NodeRef { node_id } => Some(*node_id),
        }
    }

    fn node_revision(&self) -> Option<u64> {
        match self {
            Self::Box { node_revision, .. }
            | Self::Text { node_revision, .. }
            | Self::Row { node_revision, .. }
            | Self::Column { node_revision, .. }
            | Self::Flex { node_revision, .. } => *node_revision,
            Self::NodeRef { .. } => None,
        }
    }
}

fn visit_layout_children(node: &LayoutNode, mut visit: impl FnMut(&LayoutNode)) {
    match node {
        LayoutNode::Box { child, .. } => {
            if let Some(child) = child.as_deref() {
                visit(child);
            }
        }
        LayoutNode::Row { children, .. } => {
            for child in children.iter() {
                visit(child);
            }
        }
        LayoutNode::Column { children, .. } => {
            for child in children.iter() {
                visit(child);
            }
        }
        LayoutNode::Flex { items, .. } => {
            for item in items.iter() {
                visit(&item.node);
            }
        }
        LayoutNode::Text { .. } | LayoutNode::NodeRef { .. } => {}
    }
}

impl RetainedDocument {
    pub(crate) fn bootstrap(document: LayoutDocument) -> Result<(Arc<Self>, u64), String> {
        let (node_count, work_units) = document.validate_metrics()?;

        struct BootstrapState {
            entries: Arc<RadixNode>,
            seen: HashSet<u64>,
            owner_count: u64,
            context_viewport_heights: usize,
            topology: TopologyBuilder,
        }

        fn localize_child(
            mut child: LayoutNode,
            owner_id: u64,
            path: &mut Vec<LocalStep>,
            slot: LocalStep,
            state: &mut BootstrapState,
        ) -> Result<LayoutNode, String> {
            if child.node_id().is_some() {
                let installed = install_owner(child, state)?;
                state.topology.add_use(owner_id, path, slot, installed)?;
                return Ok(LayoutNode::NodeRef { node_id: installed });
            }
            path.push(slot);
            let result = localize(&mut child, owner_id, path, state);
            path.pop();
            result?;
            Ok(child)
        }

        fn localize(
            node: &mut LayoutNode,
            owner_id: u64,
            path: &mut Vec<LocalStep>,
            state: &mut BootstrapState,
        ) -> Result<(), String> {
            // This is the existing one-time traversal, including anonymous nodes.
            visit_context_height_fields(node, |_, size| {
                state.context_viewport_heights = state
                    .context_viewport_heights
                    .checked_add(context_size_occurrences(size)?)
                    .ok_or_else(|| "Native retained context summary invariant failed".to_owned())?;
                Ok(())
            })?;
            let column = matches!(node, LayoutNode::Column { .. });
            match node {
                LayoutNode::Box { child, .. } => {
                    if let Some(old) = child.take() {
                        let old = Arc::try_unwrap(old).unwrap_or_else(|value| (*value).clone());
                        *child = Some(Arc::new(localize_child(
                            old,
                            owner_id,
                            path,
                            LocalStep::BoxChild,
                            state,
                        )?));
                    }
                }
                LayoutNode::Row { children, .. } | LayoutNode::Column { children, .. } => {
                    let old = std::mem::take(children);
                    let old = Arc::try_unwrap(old).unwrap_or_else(|value| (*value).clone());
                    let mut localized = Vec::with_capacity(old.len());
                    for (index, child) in old.into_iter().enumerate() {
                        let slot = if column {
                            LocalStep::ColumnChild(index)
                        } else {
                            LocalStep::RowChild(index)
                        };
                        localized.push(localize_child(child, owner_id, path, slot, state)?);
                    }
                    *children = Arc::new(localized);
                }
                LayoutNode::Flex { items, .. } => {
                    let old = std::mem::take(items);
                    let old = Arc::try_unwrap(old).unwrap_or_else(|value| (*value).clone());
                    let mut localized = Vec::with_capacity(old.len());
                    for (index, mut item) in old.into_iter().enumerate() {
                        item.node = localize_child(
                            item.node,
                            owner_id,
                            path,
                            LocalStep::FlexItem(index),
                            state,
                        )?;
                        localized.push(item);
                    }
                    *items = Arc::new(localized);
                }
                LayoutNode::Text { .. } => {}
                LayoutNode::NodeRef { .. } => {
                    return Err("Native retained bootstrap received a node reference".to_owned());
                }
            }
            Ok(())
        }

        fn install_owner(mut node: LayoutNode, state: &mut BootstrapState) -> Result<u64, String> {
            let node_id = node.node_id().ok_or_else(|| {
                "Native retained document owner is missing its node id".to_owned()
            })?;
            let revision = node.node_revision().ok_or_else(|| {
                "Native retained document node is missing its revision".to_owned()
            })?;
            if node_id == 0 || !state.seen.insert(node_id) {
                return Err("Native retained document has invalid duplicate node id".to_owned());
            }
            // Each owner starts a fresh local address; paths never cross NodeRefs.
            localize(&mut node, node_id, &mut Vec::new(), state)?;
            let slot_one = match &node {
                LayoutNode::Box {
                    child: Some(child), ..
                } if child.node_id().is_none() => local_work_summary(child)?,
                _ => LocalWorkSummary::default(),
            };
            let entry = Arc::new(RetainedEntry {
                revision,
                slot_work: [Arc::new(local_work_summary(&node)?), Arc::new(slot_one)],
                node: Arc::new(node),
            });
            let (updated, _) = radix_insert(&state.entries, node_id, entry);
            state.entries = updated;
            state.owner_count += 1;
            Ok(node_id)
        }

        let mut state = BootstrapState {
            entries: Arc::new(RadixNode::default()),
            seen: HashSet::new(),
            owner_count: 0,
            context_viewport_heights: 0,
            topology: TopologyBuilder::default(),
        };
        let root_id = install_owner(document.root, &mut state)?;
        debug_assert!(usize::try_from(state.owner_count).is_ok_and(|count| count <= node_count));
        let mut styles = Arc::new(StyleRadixNode::default());
        if document.styles.len() != document.style_count as usize {
            return Err("Native retained style table count mismatch".to_owned());
        }
        for (index, style) in document.styles.into_iter().enumerate() {
            let (updated, _) = style_insert(&styles, index as u64, Arc::new(style));
            styles = updated;
        }
        let topology = state.topology.finish(root_id);
        debug_assert!(topology.incoming_uses(root_id).is_empty());
        debug_assert_eq!(
            topology.build_work().occurrences_written,
            state.owner_count - 1
        );
        Ok((
            Arc::new(Self {
                root_id,
                entries: state.entries,
                topology,
                styles,
                style_count: document.style_count,
                property_template_count: document.property_template_count,
                work_units,
                context_viewport_heights: state.context_viewport_heights,
            }),
            node_count as u64,
        ))
    }

    fn effective_node(&self, node_id: u64) -> Option<&LayoutNode> {
        debug_assert_eq!(self.root_id, self.topology.root_owner());
        radix_lookup(&self.entries, node_id).map(|entry| entry.node.as_ref())
    }

    fn resolve<'a>(&'a self, fallback: &'a LayoutNode) -> Result<&'a LayoutNode, String> {
        match fallback {
            LayoutNode::NodeRef { node_id } => {
                RESOLVER_LOOKUP_COUNT.with(|count| count.set(count.get().saturating_add(1)));
                self.effective_node(*node_id).ok_or_else(|| {
                    "Native retained document has an unknown node reference".to_owned()
                })
            }
            _ => Ok(fallback),
        }
    }

    pub(crate) fn styles(&self) -> Result<Vec<StyleTemplate>, String> {
        (0..self.style_count)
            .map(|index| {
                style_lookup(&self.styles, index as u64)
                    .map(|style| style.as_ref().clone())
                    .ok_or_else(|| "Native retained style registry has a gap".to_owned())
            })
            .collect()
    }

    pub(crate) fn apply_delta(
        self: &Arc<Self>,
        delta: DocumentDelta,
    ) -> Result<AppliedDelta, String> {
        if delta.style_base_count != self.style_count
            || delta.property_template_base_count != self.property_template_count
            || delta.property_template_target_count < delta.property_template_base_count
            || delta.property_template_target_count > MAX_PROPERTY_TEMPLATE_COUNT
        {
            return Err("Native retained delta registry base mismatch".to_owned());
        }
        for style in &delta.styles_append {
            style.face.validate()?;
        }
        let target_style_count = self
            .style_count
            .checked_add(delta.styles_append.len() as u32)
            .ok_or_else(|| "Native retained style table count overflow".to_owned())?;
        if target_style_count as usize > MAX_TAPE_PROPERTY_ENTRIES {
            return Err("Native retained style table exceeds its entry limit".to_owned());
        }
        let mut seen = HashSet::with_capacity(delta.entries.len());
        let mut prepared = Vec::with_capacity(delta.entries.len());
        let mut owners = Vec::new();
        let mut stats = DeltaStats::default();
        let mut work_delta_total = 0_i128;
        let mut context_delta_total = 0_i128;
        for update in delta.entries {
            if !seen.insert(update.node_id) {
                return Err("Native retained delta contains a duplicate node id".to_owned());
            }
            let old = radix_lookup(&self.entries, update.node_id)
                .ok_or_else(|| "Native retained delta names an unknown node id".to_owned())?;
            if old.revision != update.expected_revision
                || update.target_revision <= update.expected_revision
            {
                return Err("Native retained delta node revision mismatch".to_owned());
            }
            let patched = patch_owner_slots(
                &old.node,
                &old.slot_work,
                &update.slot_patches,
                target_style_count,
                delta.property_template_target_count,
                &mut stats.source_work,
            )?;
            work_delta_total = work_delta_total
                .checked_add(patched.work_delta.units as i128)
                .ok_or_else(|| "Native layout work estimate overflowed".to_owned())?;
            context_delta_total = context_delta_total
                .checked_add(patched.work_delta.viewport_heights)
                .ok_or_else(|| "Native retained context summary invariant failed".to_owned())?;
            if !patched.slots.is_empty() {
                owners.push(OwnerChange {
                    node_id: update.node_id,
                    expected_revision: update.expected_revision,
                    target_revision: update.target_revision,
                    slots: patched.slots,
                });
            }
            prepared.push((
                update.node_id,
                Arc::new(RetainedEntry {
                    revision: update.target_revision,
                    node: patched.node,
                    slot_work: patched.slot_work,
                }),
            ));
        }
        let work_units = if work_delta_total < 0 {
            self.work_units
                .checked_sub(
                    usize::try_from(-work_delta_total)
                        .map_err(|_| "Native retained work summary invariant failed".to_owned())?,
                )
                .ok_or_else(|| "Native retained work summary invariant failed".to_owned())?
        } else {
            self.work_units
                .checked_add(
                    usize::try_from(work_delta_total)
                        .map_err(|_| "Native layout work estimate overflowed".to_owned())?,
                )
                .ok_or_else(|| "Native layout work estimate overflowed".to_owned())?
        };
        if work_units > MAX_LAYOUT_WORK_UNITS {
            return Err("Native layout exceeds the work-unit limit".to_owned());
        }
        let context_viewport_heights = (self.context_viewport_heights as i128)
            .checked_add(context_delta_total)
            .and_then(|count| usize::try_from(count).ok())
            .ok_or_else(|| "Native retained context summary invariant failed".to_owned())?;
        let parsed = prepared.len() as u64;
        let mut entries = Arc::clone(&self.entries);
        let mut copied = 0;
        for (node_id, entry) in prepared {
            let (next, count) = radix_insert(&entries, node_id, entry);
            entries = next;
            copied += count;
        }
        let mut styles = Arc::clone(&self.styles);
        for (offset, style) in delta.styles_append.into_iter().enumerate() {
            let style_id = self.style_count as u64 + offset as u64;
            let (updated, count) = style_insert(&styles, style_id, Arc::new(style));
            styles = updated;
            copied += count;
        }
        let document = Arc::new(Self {
            root_id: self.root_id,
            topology: Arc::clone(&self.topology),
            entries,
            styles,
            style_count: target_style_count,
            property_template_count: delta.property_template_target_count,
            work_units,
            context_viewport_heights,
        });
        stats.entries_parsed = parsed;
        stats.trie_path_nodes_copied = copied;
        let changes = SourceChanges {
            base: Arc::clone(self),
            target: Arc::clone(&document),
            owners,
            styles: self.style_count..target_style_count,
            property_templates: self.property_template_count..document.property_template_count,
        };
        Ok(AppliedDelta {
            document,
            changes,
            stats,
        })
    }
}

fn patch_owner_slots(
    base: &Arc<LayoutNode>,
    base_work: &[Arc<LocalWorkSummary>; 2],
    patches: &[LocalSlotPatch],
    style_count: u32,
    property_template_count: u32,
    source_work: &mut SourceChangeWork,
) -> Result<PatchedOwner, String> {
    let mut result = Arc::clone(base);
    let mut slot_work = base_work.clone();
    let mut work_delta = 0_isize;
    let mut context_delta = 0_i128;
    let mut seen = [false; 2];
    let mut slots = Vec::new();
    for patch in patches {
        let index = patch.slot as usize;
        if index >= seen.len() || std::mem::replace(&mut seen[index], true) {
            return Err("Native retained delta has an invalid duplicate slot".to_owned());
        }
        if patch.slot == 0 {
            let patched = patch_local_node(&result, &patch.local, source_work)?;
            validate_changed_fields(
                patched.node.as_ref().unwrap_or(&result),
                &patch.local,
                style_count,
                property_template_count,
            )?;
            let Some(node) = patched.node else { continue };
            let old_work = slot_work[0].changed_work(&patched.fields);
            let updated = slot_work[0].updated(&node, &patched.fields)?;
            context_delta += updated.changed_context_occurrences(&patched.fields)
                - slot_work[0].changed_context_occurrences(&patched.fields);
            let new_work = updated.changed_work(&patched.fields);
            work_delta += new_work as isize - old_work as isize;
            slot_work[0] = updated;
            result = Arc::new(node);
            slots.push(SlotChange {
                slot: 0,
                fields: patched.fields.into_iter().map(|(field, _)| field).collect(),
            });
        } else {
            let LayoutNode::Box { child, .. } = result.as_ref() else {
                return Err("Native retained delta slot one requires a box owner".to_owned());
            };
            let old_child = child
                .as_deref()
                .ok_or_else(|| "Native retained delta slot one is absent".to_owned())?;
            if old_child.node_id().is_some() {
                return Err("Native retained delta slot one must be anonymous".to_owned());
            }
            let patched = patch_local_node(old_child, &patch.local, source_work)?;
            validate_changed_fields(
                patched.node.as_ref().unwrap_or(old_child),
                &patch.local,
                style_count,
                property_template_count,
            )?;
            let Some(new_child) = patched.node else {
                continue;
            };
            let old_work = slot_work[1].changed_work(&patched.fields);
            let updated = slot_work[1].updated(&new_child, &patched.fields)?;
            context_delta += updated.changed_context_occurrences(&patched.fields)
                - slot_work[1].changed_context_occurrences(&patched.fields);
            let new_work = updated.changed_work(&patched.fields);
            work_delta += new_work as isize - old_work as isize;
            slot_work[1] = updated;
            if Arc::strong_count(&result) > 1 {
                source_work.local_nodes_copied += 1;
            }
            let LayoutNode::Box { child, .. } = Arc::make_mut(&mut result) else {
                unreachable!()
            };
            *child = Some(Arc::new(new_child));
            slots.push(SlotChange {
                slot: 1,
                fields: patched.fields.into_iter().map(|(field, _)| field).collect(),
            });
        }
    }
    Ok(PatchedOwner {
        node: result,
        slot_work,
        work_delta: LocalWorkDelta {
            units: work_delta,
            viewport_heights: context_delta,
        },
        slots,
    })
}

fn patch_local_node<'a>(
    base: &LayoutNode,
    fields: &'a JsonMap<String, JsonValue>,
    source_work: &mut SourceChangeWork,
) -> Result<PatchedLocal<'a>, String> {
    fn parsed<T: serde::de::DeserializeOwned>(value: &JsonValue) -> Result<T, String> {
        serde_json::from_value(value.clone())
            .map_err(|error| format!("Invalid native retained local field: {error}"))
    }
    let mut output = None;
    let mut changed_fields = Vec::new();
    for (name, value) in fields {
        macro_rules! assign {
            ($variant:ident, $field:ident, $id:ident, $same:ident, $parsed:expr) => {{
                let next = $parsed;
                source_work.fields_compared += 1;
                if !$same($field, &next, source_work) {
                    let node = output.get_or_insert_with(|| {
                        source_work.local_nodes_copied += 1;
                        base.clone()
                    });
                    let LayoutNode::$variant { $field, .. } = node else {
                        unreachable!()
                    };
                    *$field = next;
                    changed_fields.push((LocalField::$id, name.as_str()));
                }
            }};
            ($variant:ident, $field:ident, $id:ident) => {
                assign!($variant, $field, $id, same_scalar_source, parsed(value)?)
            };
            ($variant:ident, $field:ident, $id:ident, $same:ident) => {
                assign!($variant, $field, $id, $same, parsed(value)?)
            };
        }
        match output.as_ref().unwrap_or(base) {
            LayoutNode::Box {
                region_id,
                content,
                content_region_id,
                content_typography_style,
                content_foreground_style,
                content_surface_template_id,
                content_width_exact,
                content_min_width,
                width,
                min_width,
                max_width,
                height,
                min_height,
                max_height,
                box_sizing,
                padding_left,
                padding_right,
                padding_top,
                padding_bottom,
                margin_left,
                margin_right,
                margin_top,
                margin_bottom,
                border_left,
                border_right,
                typography_style,
                foreground_style,
                background_style,
                border_left_style,
                border_right_style,
                border_top_style,
                border_bottom_style,
                surface_template_id,
                text_align,
                vertical_align,
                overflow,
                wrap_mode,
                scroll_offset,
                ..
            } => match name.as_str() {
                "region-id" => assign!(Box, region_id, RegionId),
                "content" => assign!(
                    Box,
                    content,
                    Content,
                    same_optional_content_source,
                    parsed::<Option<MeasuredText>>(value)?.map(Arc::new)
                ),
                "content-region-id" => assign!(Box, content_region_id, ContentRegionId),
                "content-typography-style" => {
                    assign!(Box, content_typography_style, ContentTypographyStyle)
                }
                "content-foreground-style" => {
                    assign!(Box, content_foreground_style, ContentForegroundStyle)
                }
                "content-surface-template-id" => {
                    assign!(Box, content_surface_template_id, ContentSurfaceTemplateId)
                }
                "content-width-exact" => assign!(Box, content_width_exact, ContentWidthExact),
                "content-min-width" => assign!(Box, content_min_width, ContentMinWidth),
                "width" => assign!(Box, width, Width, same_size_source),
                "min-width" => assign!(Box, min_width, MinWidth, same_size_source),
                "max-width" => assign!(Box, max_width, MaxWidth, same_size_source),
                "height" => assign!(Box, height, Height, same_size_source),
                "min-height" => assign!(Box, min_height, MinHeight, same_size_source),
                "max-height" => assign!(Box, max_height, MaxHeight, same_size_source),
                "box-sizing" => assign!(Box, box_sizing, BoxSizing),
                "padding-left" => assign!(Box, padding_left, PaddingLeft),
                "padding-right" => assign!(Box, padding_right, PaddingRight),
                "padding-top" => assign!(Box, padding_top, PaddingTop),
                "padding-bottom" => assign!(Box, padding_bottom, PaddingBottom),
                "margin-left" => assign!(Box, margin_left, MarginLeft),
                "margin-right" => assign!(Box, margin_right, MarginRight),
                "margin-top" => assign!(Box, margin_top, MarginTop),
                "margin-bottom" => assign!(Box, margin_bottom, MarginBottom),
                "border-left" => assign!(Box, border_left, BorderLeft),
                "border-right" => assign!(Box, border_right, BorderRight),
                "typography-style" => assign!(Box, typography_style, TypographyStyle),
                "foreground-style" => assign!(Box, foreground_style, ForegroundStyle),
                "background-style" => assign!(Box, background_style, BackgroundStyle),
                "border-left-style" => assign!(Box, border_left_style, BorderLeftStyle),
                "border-right-style" => assign!(Box, border_right_style, BorderRightStyle),
                "border-top-style" => assign!(Box, border_top_style, BorderTopStyle),
                "border-bottom-style" => assign!(Box, border_bottom_style, BorderBottomStyle),
                "surface-template-id" => assign!(Box, surface_template_id, SurfaceTemplateId),
                "text-align" => assign!(Box, text_align, TextAlign),
                "vertical-align" => assign!(Box, vertical_align, VerticalAlign),
                "overflow" => assign!(Box, overflow, Overflow),
                "wrap-mode" => assign!(Box, wrap_mode, WrapMode),
                "scroll-offset" => assign!(Box, scroll_offset, ScrollOffset),
                _ => return Err(format!("Unsupported native retained box field {name}")),
            },
            LayoutNode::Text {
                region_id,
                content,
                typography_style,
                foreground_style,
                surface_template_id,
                wrap_mode,
                ..
            } => match name.as_str() {
                "region-id" => assign!(Text, region_id, RegionId),
                "content" => assign!(
                    Text,
                    content,
                    Content,
                    same_text_source,
                    Arc::new(parsed(value)?)
                ),
                "typography-style" => assign!(Text, typography_style, TypographyStyle),
                "foreground-style" => assign!(Text, foreground_style, ForegroundStyle),
                "surface-template-id" => assign!(Text, surface_template_id, SurfaceTemplateId),
                "wrap-mode" => assign!(Text, wrap_mode, WrapMode),
                _ => return Err(format!("Unsupported native retained text field {name}")),
            },
            LayoutNode::Flex {
                direction,
                wrap,
                justify,
                align_items,
                align_content,
                width,
                height,
                row_gap,
                column_gap,
                ..
            } => match name.as_str() {
                "direction" => assign!(Flex, direction, Direction),
                "wrap" => assign!(Flex, wrap, Wrap),
                "justify" => assign!(Flex, justify, Justify),
                "align-items" => assign!(Flex, align_items, AlignItems),
                "align-content" => assign!(Flex, align_content, AlignContent),
                "width" => assign!(Flex, width, Width, same_size_source),
                "height" => assign!(Flex, height, Height, same_size_source),
                "row-gap" => assign!(Flex, row_gap, RowGap),
                "column-gap" => assign!(Flex, column_gap, ColumnGap),
                _ => return Err(format!("Unsupported native retained flex field {name}")),
            },
            LayoutNode::Row { .. } | LayoutNode::Column { .. } => {
                return Err("Native retained axis slots have no local scalar fields".to_owned());
            }
            LayoutNode::NodeRef { .. } => {
                return Err("Native retained node reference cannot be patched".to_owned())
            }
        }
    }
    Ok(PatchedLocal {
        node: output,
        fields: changed_fields,
    })
}

fn same_scalar_source<T: PartialEq>(base: &T, target: &T, _: &mut SourceChangeWork) -> bool {
    base == target
}

fn same_size_source(base: &Size, target: &Size, work: &mut SourceChangeWork) -> bool {
    work.size_nodes_compared += 1;
    match (base, target) {
        (Size::Pixels { value: left }, Size::Pixels { value: right })
        | (Size::Lines { value: left }, Size::Lines { value: right }) => left == right,
        (Size::FitContent { limit: left }, Size::FitContent { limit: right }) => {
            match (left, right) {
                (None, None) => true,
                (Some(left), Some(right)) => same_size_source(left, right, work),
                _ => false,
            }
        }
        (Size::Add { values: left }, Size::Add { values: right })
        | (Size::Subtract { values: left }, Size::Subtract { values: right }) => {
            left.0.len() == right.0.len()
                && left
                    .0
                    .iter()
                    .zip(right.0.iter())
                    .all(|(left, right)| same_size_source(left, right, work))
        }
        (Size::Auto, Size::Auto)
        | (Size::Content, Size::Content)
        | (Size::None, Size::None)
        | (Size::Viewport, Size::Viewport)
        | (Size::ViewportHeight, Size::ViewportHeight)
        | (Size::MinContent, Size::MinContent)
        | (Size::MaxContent, Size::MaxContent)
        | (Size::Stretch, Size::Stretch)
        | (Size::Contain, Size::Contain) => true,
        _ => false,
    }
}

fn same_optional_content_source(
    base: &Option<Arc<MeasuredText>>,
    target: &Option<Arc<MeasuredText>>,
    work: &mut SourceChangeWork,
) -> bool {
    match (base, target) {
        (None, None) => true,
        (Some(base), Some(target)) => same_text_source(base, target, work),
        _ => false,
    }
}

fn same_text_source(
    base: &MeasuredText,
    target: &MeasuredText,
    work: &mut SourceChangeWork,
) -> bool {
    base.lines.len() == target.lines.len()
        && base.lines.iter().zip(&target.lines).all(|(left, right)| {
            work.text_lines_compared += 1;
            left.clusters.len() == right.clusters.len()
                && left
                    .clusters
                    .iter()
                    .zip(&right.clusters)
                    .all(|(left, right)| {
                        work.text_clusters_compared += 1;
                        left.width == right.width
                            && left.cjk == right.cjk
                            && left.space == right.space
                            && left.pixel_space == right.pixel_space
                            && left.source_template_id == right.source_template_id
                            && left.text.len() == right.text.len()
                            && left
                                .text
                                .bytes()
                                .zip(right.text.bytes())
                                .all(|(left, right)| {
                                    work.text_bytes_compared += 1;
                                    left == right
                                })
                    })
        })
}

fn measured_text_work(text: &MeasuredText, property_template_count: u32) -> Result<usize, String> {
    let mut work = text.lines.len();
    for line in &text.lines {
        work = work
            .checked_add(line.clusters.len())
            .ok_or_else(|| "Native layout work estimate overflowed".to_owned())?;
        for cluster in &line.clusters {
            if cluster.text.is_empty() {
                return Err("Native layout cluster text cannot be empty".to_owned());
            }
            validate_dimension("cluster width", cluster.width)?;
            if cluster
                .source_template_id
                .is_some_and(|id| id >= property_template_count)
            {
                return Err(
                    "Native layout property template id exceeds the property template table"
                        .to_owned(),
                );
            }
        }
    }
    Ok(work)
}

fn size_work(size: &Size) -> Result<usize, String> {
    let mut work = 0;
    add_vertical_size_work(size, &mut work)?;
    Ok(work)
}

fn context_size_occurrences(size: &Size) -> Result<usize, String> {
    let mut count = 0_usize;
    visit_context_size_occurrences(size, &mut || {
        count = count
            .checked_add(1)
            .ok_or_else(|| "Native retained context summary invariant failed".to_owned())?;
        Ok(())
    })?;
    Ok(count)
}

fn context_field_occurrences(node: &LayoutNode, name: &str) -> Result<usize, String> {
    let mut count = 0;
    visit_context_height_fields(node, |field, size| {
        if field == name {
            count = context_size_occurrences(size)?;
        }
        Ok(())
    })?;
    Ok(count)
}

fn field_work(node: &LayoutNode, name: &str) -> Result<Option<usize>, String> {
    Ok(match (node, name) {
        (LayoutNode::Box { content, .. }, "content") => {
            content.as_deref().map_or(Ok(Some(0)), |text| {
                measured_text_work(text, u32::MAX).map(Some)
            })?
        }
        (LayoutNode::Text { content, .. }, "content") => {
            Some(measured_text_work(content, u32::MAX)?)
        }
        (LayoutNode::Box { height, .. }, "height") => Some(size_work(height)?),
        (LayoutNode::Box { min_height, .. }, "min-height") => Some(size_work(min_height)?),
        (LayoutNode::Box { max_height, .. }, "max-height") => Some(size_work(max_height)?),
        (LayoutNode::Flex { height, .. }, "height") => Some(size_work(height)?),
        (LayoutNode::Box { padding_top, .. }, "padding-top") => {
            Some(usize::try_from(*padding_top).unwrap_or(usize::MAX))
        }
        (LayoutNode::Box { padding_bottom, .. }, "padding-bottom") => {
            Some(usize::try_from(*padding_bottom).unwrap_or(usize::MAX))
        }
        (LayoutNode::Box { margin_top, .. }, "margin-top") => {
            Some(usize::try_from(*margin_top).unwrap_or(usize::MAX))
        }
        (LayoutNode::Box { margin_bottom, .. }, "margin-bottom") => {
            Some(usize::try_from(*margin_bottom).unwrap_or(usize::MAX))
        }
        (LayoutNode::Flex { row_gap, items, .. }, "row-gap") => Some(
            usize::try_from(*row_gap)
                .unwrap_or(usize::MAX)
                .saturating_mul(items.len()),
        ),
        _ => None,
    })
}

fn local_work_summary(node: &LayoutNode) -> Result<LocalWorkSummary, String> {
    const FIELDS: [&str; 9] = [
        "content",
        "height",
        "min-height",
        "max-height",
        "padding-top",
        "padding-bottom",
        "margin-top",
        "margin-bottom",
        "row-gap",
    ];
    let mut values = BTreeMap::new();
    for name in FIELDS {
        if let Some(value) = field_work(node, name)? {
            values.insert(
                name,
                LocalFieldWork {
                    units: value,
                    viewport_heights: context_field_occurrences(node, name)?,
                },
            );
        }
    }
    Ok(LocalWorkSummary(values))
}

impl LocalWorkSummary {
    fn changed_work(&self, fields: &[(LocalField, &str)]) -> usize {
        fields
            .iter()
            .filter_map(|(_, name)| self.0.get(name))
            .map(|work| work.units)
            .sum()
    }

    fn changed_context_occurrences(&self, fields: &[(LocalField, &str)]) -> i128 {
        fields
            .iter()
            .filter_map(|(_, name)| self.0.get(name))
            .map(|work| work.viewport_heights as i128)
            .sum()
    }

    fn updated(
        self: &Arc<Self>,
        node: &LayoutNode,
        fields: &[(LocalField, &str)],
    ) -> Result<Arc<Self>, String> {
        let mut output = Arc::clone(self);
        for (_, name) in fields {
            if let Some(value) = field_work(node, name)? {
                let value = LocalFieldWork {
                    units: value,
                    viewport_heights: context_field_occurrences(node, name)?,
                };
                if output.0.get(name) == Some(&value) {
                    continue;
                }
                Arc::make_mut(&mut output).0.insert(
                    match *name {
                        "content" => "content",
                        "height" => "height",
                        "min-height" => "min-height",
                        "max-height" => "max-height",
                        "padding-top" => "padding-top",
                        "padding-bottom" => "padding-bottom",
                        "margin-top" => "margin-top",
                        "margin-bottom" => "margin-bottom",
                        "row-gap" => "row-gap",
                        _ => continue,
                    },
                    value,
                );
            }
        }
        Ok(output)
    }
}

fn validate_changed_fields(
    node: &LayoutNode,
    fields: &JsonMap<String, JsonValue>,
    style_count: u32,
    property_template_count: u32,
) -> Result<(), String> {
    let style_field = |name: &str| {
        matches!(
            name,
            "typography-style"
                | "foreground-style"
                | "background-style"
                | "border-left-style"
                | "border-right-style"
                | "border-top-style"
                | "border-bottom-style"
                | "content-typography-style"
                | "content-foreground-style"
        )
    };
    let template_field =
        |name: &str| matches!(name, "surface-template-id" | "content-surface-template-id");
    for (name, value) in fields {
        if style_field(name) {
            let id: Option<u32> = serde_json::from_value(value.clone())
                .map_err(|error| format!("Invalid native retained style field: {error}"))?;
            if id.is_some_and(|id| id >= style_count) {
                return Err("Native retained style id exceeds the style table".to_owned());
            }
        }
        if template_field(name) {
            let id: Option<u32> = serde_json::from_value(value.clone())
                .map_err(|error| format!("Invalid native retained template field: {error}"))?;
            if id.is_some_and(|id| id >= property_template_count) {
                return Err("Native retained property template id exceeds the table".to_owned());
            }
        }
    }
    match node {
        LayoutNode::Box {
            region_id,
            content,
            child,
            content_region_id,
            content_min_width,
            width,
            min_width,
            max_width,
            height,
            min_height,
            max_height,
            padding_left,
            padding_right,
            padding_top,
            padding_bottom,
            margin_left,
            margin_right,
            margin_top,
            margin_bottom,
            border_left,
            border_right,
            scroll_offset,
            ..
        } => {
            if fields.contains_key("region-id") && *region_id <= 0 {
                return Err("Native retained box region id must be positive".to_owned());
            }
            if fields.contains_key("content") {
                if content.is_some() == child.is_some() {
                    return Err(
                        "Native layout box must contain exactly one text or child value".to_owned(),
                    );
                }
                if let Some(text) = content {
                    measured_text_work(text, property_template_count)?;
                }
            }
            if fields.contains_key("content-region-id")
                && (content_region_id.is_some_and(|id| id <= 0)
                    || content_region_id.is_some() && content.is_none())
            {
                return Err("Native retained content region id is invalid".to_owned());
            }
            if fields.contains_key("content-min-width") {
                if let Some(value) = content_min_width {
                    validate_dimension("content-min-width", *value)?;
                }
            }
            for (name, size) in [
                ("width", width),
                ("min-width", min_width),
                ("max-width", max_width),
                ("height", height),
                ("min-height", min_height),
                ("max-height", max_height),
            ] {
                if fields.contains_key(name) {
                    validate_size(name, size)?;
                }
            }
            for (name, value) in [
                ("padding-left", *padding_left),
                ("padding-right", *padding_right),
                ("padding-top", *padding_top),
                ("padding-bottom", *padding_bottom),
                ("margin-left", *margin_left),
                ("margin-right", *margin_right),
                ("margin-top", *margin_top),
                ("margin-bottom", *margin_bottom),
                ("border-left", *border_left),
                ("border-right", *border_right),
                ("scroll-offset", *scroll_offset),
            ] {
                if fields.contains_key(name) {
                    validate_dimension(name, value)?;
                }
            }
        }
        LayoutNode::Text {
            region_id, content, ..
        } => {
            if fields.contains_key("region-id") && *region_id <= 0 {
                return Err("Native retained text region id must be positive".to_owned());
            }
            if fields.contains_key("content") {
                measured_text_work(content, property_template_count)?;
            }
        }
        LayoutNode::Flex {
            width,
            height,
            row_gap,
            column_gap,
            ..
        } => {
            if fields.contains_key("width") {
                validate_size("flex width", width)?;
            }
            if fields.contains_key("height") {
                validate_size("flex height", height)?;
            }
            if fields.contains_key("row-gap") {
                validate_dimension("flex row gap", *row_gap)?;
            }
            if fields.contains_key("column-gap") {
                validate_dimension("flex column gap", *column_gap)?;
            }
        }
        LayoutNode::Row { .. } | LayoutNode::Column { .. } | LayoutNode::NodeRef { .. } => {}
    }
    Ok(())
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
pub(crate) struct StyleTemplate {
    mode: StyleMode,
    face: FaceTemplate,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum StyleMode {
    Set,
    Add,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct FaceTemplate {
    #[serde(default)]
    lisp: Option<String>,
    #[serde(default)]
    inherit: Option<String>,
    #[serde(default)]
    inverse_video: Option<bool>,
    #[serde(default)]
    foreground: Option<String>,
    #[serde(default)]
    background: Option<String>,
    #[serde(default)]
    overline: Option<ColorOrTrue>,
    #[serde(default)]
    underline: Option<UnderlineTemplate>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(untagged)]
enum ColorOrTrue {
    Boolean(bool),
    Color(String),
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct UnderlineTemplate {
    position: bool,
    #[serde(default)]
    color: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
// Keeping the node payload inline avoids another allocation on the hot layout path.
#[allow(clippy::large_enum_variant)]
#[serde(
    tag = "type",
    rename_all = "kebab-case",
    rename_all_fields = "kebab-case",
    deny_unknown_fields
)]
enum LayoutNode {
    NodeRef {
        node_id: u64,
    },
    Box {
        #[serde(default)]
        node_id: Option<u64>,
        #[serde(default)]
        node_revision: Option<u64>,
        region_id: i64,
        #[serde(default, deserialize_with = "deserialize_optional_arc")]
        content: Option<Arc<MeasuredText>>,
        #[serde(default)]
        content_region_id: Option<i64>,
        #[serde(default)]
        content_typography_style: Option<u32>,
        #[serde(default)]
        content_foreground_style: Option<u32>,
        #[serde(default)]
        content_surface_template_id: Option<u32>,
        #[serde(
            default,
            deserialize_with = "deserialize_optional_arc",
            skip_serializing
        )]
        child: Option<Arc<LayoutNode>>,
        content_width_exact: bool,
        #[serde(default)]
        content_min_width: Option<i64>,
        width: Size,
        min_width: Size,
        max_width: Size,
        height: Size,
        min_height: Size,
        max_height: Size,
        box_sizing: BoxSizing,
        padding_left: i64,
        padding_right: i64,
        padding_top: i64,
        padding_bottom: i64,
        margin_left: i64,
        margin_right: i64,
        margin_top: i64,
        margin_bottom: i64,
        border_left: i64,
        border_right: i64,
        #[serde(default)]
        typography_style: Option<u32>,
        foreground_style: Option<u32>,
        background_style: Option<u32>,
        border_left_style: Option<u32>,
        border_right_style: Option<u32>,
        border_top_style: Option<u32>,
        border_bottom_style: Option<u32>,
        #[serde(default)]
        surface_template_id: Option<u32>,
        text_align: HorizontalAlign,
        vertical_align: VerticalAlign,
        overflow: Overflow,
        wrap_mode: WrapMode,
        scroll_offset: i64,
    },
    Text {
        #[serde(default)]
        node_id: Option<u64>,
        #[serde(default)]
        node_revision: Option<u64>,
        region_id: i64,
        #[serde(deserialize_with = "deserialize_arc")]
        content: Arc<MeasuredText>,
        #[serde(default)]
        typography_style: Option<u32>,
        foreground_style: Option<u32>,
        #[serde(default)]
        surface_template_id: Option<u32>,
        wrap_mode: WrapMode,
    },
    Row {
        #[serde(default)]
        node_id: Option<u64>,
        #[serde(default)]
        node_revision: Option<u64>,
        #[serde(default, deserialize_with = "deserialize_arc_vec", skip_serializing)]
        children: Arc<Vec<LayoutNode>>,
    },
    Column {
        #[serde(default)]
        node_id: Option<u64>,
        #[serde(default)]
        node_revision: Option<u64>,
        #[serde(default, deserialize_with = "deserialize_arc_vec", skip_serializing)]
        children: Arc<Vec<LayoutNode>>,
    },
    Flex {
        #[serde(default)]
        node_id: Option<u64>,
        #[serde(default)]
        node_revision: Option<u64>,
        direction: FlexDirection,
        wrap: FlexWrap,
        justify: FlexAlign,
        align_items: FlexAlign,
        align_content: FlexAlign,
        width: Size,
        height: Size,
        row_gap: i64,
        column_gap: i64,
        #[serde(default, deserialize_with = "deserialize_arc_vec", skip_serializing)]
        items: Arc<Vec<FlexItem>>,
    },
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case", deny_unknown_fields)]
enum Size {
    Auto,
    Content,
    None,
    Pixels {
        value: i64,
    },
    Lines {
        value: i64,
    },
    Viewport,
    ViewportHeight,
    MinContent,
    MaxContent,
    FitContent {
        #[serde(default)]
        limit: Option<Box<Size>>,
    },
    Stretch,
    Contain,
    Add {
        values: Box<SizeValues>,
    },
    Subtract {
        values: Box<SizeValues>,
    },
}

#[derive(Debug, Clone, Deserialize)]
#[serde(transparent)]
struct SizeValues(Box<[Size]>);

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum FlexDirection {
    Row,
    RowReverse,
    Column,
    ColumnReverse,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum FlexWrap {
    Nowrap,
    Wrap,
    WrapReverse,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum FlexAlign {
    Auto,
    Normal,
    Stretch,
    FlexStart,
    FlexEnd,
    Center,
    Start,
    End,
    SelfStart,
    SelfEnd,
    Left,
    Right,
    Top,
    Bottom,
    Baseline,
    SpaceBetween,
    SpaceAround,
    SpaceEvenly,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct FlexItem {
    node: LayoutNode,
    order: i64,
    grow: f64,
    shrink: f64,
    basis: Size,
    align_self: FlexAlign,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum BoxSizing {
    ContentBox,
    BorderBox,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum HorizontalAlign {
    Left,
    Center,
    Right,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum VerticalAlign {
    Top,
    Center,
    Bottom,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum Overflow {
    Scroll,
    Hidden,
    Visible,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum WrapMode {
    None,
    Word,
    Char,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct MeasuredText {
    lines: Vec<MeasuredLine>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct MeasuredLine {
    clusters: Vec<MeasuredCluster>,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
struct MeasuredCluster {
    text: String,
    width: i64,
    cjk: bool,
    space: bool,
    #[serde(rename = "pixel-space", default)]
    pixel_space: bool,
    #[serde(default, rename = "source-template-id")]
    source_template_id: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LayoutContext {
    pub viewport_width: i64,
    pub viewport_width_known: bool,
    pub viewport_height: i64,
    pub inline_auto_width_intrinsic: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct TapeIdentity {
    pub session_id: u64,
    pub generation: u64,
    pub key: i64,
    pub runtime_revision: u64,
    pub context_hash: i64,
    pub viewport_width: i64,
    pub viewport_height: i64,
    pub root_width: i64,
    pub complete: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct TapeOutputOptions {
    pub root_metadata: bool,
    pub max_bytes: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LayoutTape {
    style_count: u32,
    lines: Vec<TapeLine>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct TapeCharacter {
    value: char,
    pixel_width: Option<u64>,
    properties: AtomProperties,
}

#[derive(Debug)]
struct FlatLayoutTape {
    style_count: u32,
    line_count: u32,
    characters: Vec<TapeCharacter>,
}

type TapePatch = SpanEdit;

#[derive(Debug, Clone, PartialEq, Eq)]
struct TapeLine {
    width: i64,
    atoms: Vec<TapeAtom>,
    break_after: Option<AtomProperties>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum TapeAtom {
    Text {
        text: String,
        width: i64,
        properties: AtomProperties,
    },
    Space {
        width: i64,
        properties: AtomProperties,
    },
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct AtomProperties {
    style_ids: Vec<u32>,
    content: Option<i64>,
    content_idx: Option<i64>,
    owner: Option<i64>,
    owners: Vec<i64>,
    roles: Vec<RegionRoleEntry>,
    scroll_window: Option<i64>,
    property_template_ids: Vec<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RegionRole {
    PaddingLeft,
    PaddingRight,
    PaddingTop,
    PaddingBottom,
    BorderLeft,
    BorderRight,
    BorderTop,
    BorderBottom,
    MarginLeft,
    MarginRight,
    MarginTop,
    MarginBottom,
}

const REGION_ROLES: [RegionRole; 12] = [
    RegionRole::PaddingLeft,
    RegionRole::PaddingRight,
    RegionRole::PaddingTop,
    RegionRole::PaddingBottom,
    RegionRole::BorderLeft,
    RegionRole::BorderRight,
    RegionRole::BorderTop,
    RegionRole::BorderBottom,
    RegionRole::MarginLeft,
    RegionRole::MarginRight,
    RegionRole::MarginTop,
    RegionRole::MarginBottom,
];

#[derive(Debug, Clone, PartialEq, Eq)]
struct RegionRoleEntry {
    role: RegionRole,
    region_id: i64,
}

#[derive(Debug, Clone)]
enum Atom {
    Text {
        text: String,
        width: i64,
        cjk: bool,
        space: bool,
        properties: AtomProperties,
    },
    Space {
        width: i64,
        properties: AtomProperties,
    },
}

#[derive(Debug, Clone, Default)]
struct Line {
    atoms: AtomPlan,
    width: i64,
}

impl Line {
    fn from_clusters(clusters: &[MeasuredCluster]) -> Self {
        let mut atoms = Vec::with_capacity(clusters.len());
        for cluster in clusters {
            let properties = AtomProperties {
                property_template_ids: cluster.source_template_id.into_iter().collect(),
                ..AtomProperties::default()
            };
            if cluster.pixel_space {
                atoms.push(Atom::Space {
                    width: cluster.width,
                    properties,
                });
            } else {
                atoms.push(Atom::Text {
                    text: cluster.text.clone(),
                    width: cluster.width,
                    cjk: cluster.cjk,
                    space: cluster.space,
                    properties,
                });
            }
        }
        let atoms = AtomPlan::from_owned_atoms(atoms);
        Self {
            width: atoms.width(),
            atoms,
        }
    }

    fn from_atoms(atoms: &[Atom]) -> Self {
        let atoms = AtomPlan::from_atoms(atoms);
        Self {
            width: atoms.width(),
            atoms,
        }
    }

    fn push_space(&mut self, width: i64) {
        self.push_space_with_properties(width, AtomProperties::default());
    }

    fn push_space_with_properties(&mut self, width: i64, properties: AtomProperties) {
        if width <= 0 {
            return;
        }
        self.width += width;
        self.atoms = self.atoms.push(Atom::Space { width, properties });
    }

    fn prepend_space(&mut self, width: i64) {
        self.prepend_space_with_properties(width, AtomProperties::default());
    }

    fn prepend_space_with_properties(&mut self, width: i64, properties: AtomProperties) {
        if width <= 0 {
            return;
        }
        self.width += width;
        self.atoms = self.atoms.prepend(Atom::Space { width, properties });
    }

    fn append(&mut self, other: &Self) {
        self.width += other.width;
        self.atoms = self.atoms.append(&other.atoms);
    }

    fn padded(mut self, target: i64, align: HorizontalAlign) -> Self {
        let remaining = (target - self.width).max(0);
        let left = match align {
            HorizontalAlign::Left => 0,
            HorizontalAlign::Right => remaining,
            HorizontalAlign::Center => remaining / 2,
        };
        self.prepend_space(left);
        self.push_space(remaining - left);
        self
    }

    fn clipped(&self, width: i64) -> Self {
        if self.width <= width {
            return line_plan::clone_line(self);
        }
        let mut kept = Vec::new();
        let mut remaining = width.max(0);
        for atom in self.atoms.to_vec() {
            if atom.width() <= remaining {
                remaining -= atom.width();
                kept.push(atom);
            } else {
                if remaining > 0 {
                    // A display space can shrink.  An indivisible glyph is
                    // omitted and its replacement blank has no hit ownership.
                    let properties = match atom {
                        Atom::Space { properties, .. } => properties,
                        Atom::Text { .. } => AtomProperties::default(),
                    };
                    kept.push(Atom::Space {
                        width: remaining,
                        properties,
                    });
                }
                break;
            }
        }
        Self::from_atoms(&kept)
    }

    fn blank(width: i64) -> Self {
        Self::blank_with_properties(width, AtomProperties::default())
    }

    fn blank_with_properties(width: i64, properties: AtomProperties) -> Self {
        // A requested line has height even at zero width.  Optional horizontal
        // edge/gap insertion still uses push/prepend_space and skips width zero.
        Self::from_atoms(&[Atom::Space {
            width: width.max(0),
            properties,
        }])
    }

    fn whitespace_only(&self) -> bool {
        self.atoms.whitespace_only()
    }

    fn has_noncontent_properties(&self) -> bool {
        self.atoms.has_noncontent_properties()
    }

    fn own_content(&mut self, region_id: i64, content_idx: i64) {
        self.atoms = self.atoms.own_content(region_id, content_idx);
    }

    fn collapse_whitespace_content(self, width: i64, region_id: i64) -> Self {
        if !self.whitespace_only() || self.has_noncontent_properties() {
            return self;
        }
        let first_atom = self.atoms.first();
        let first = first_atom.as_ref().map(Atom::properties);
        let mut properties = AtomProperties {
            content: first
                .and_then(|properties| properties.content)
                .or(Some(region_id)),
            content_idx: first
                .and_then(|properties| properties.content_idx)
                .or(Some(0)),
            owner: Some(region_id),
            ..AtomProperties::default()
        };
        if properties.content.is_none() {
            properties.content = Some(region_id);
        }
        Self::blank_with_properties(width, properties)
    }

    fn apply_style(&mut self, style_id: Option<u32>) {
        if let Some(style_id) = style_id {
            self.atoms = self.atoms.apply_style(style_id);
        }
    }

    fn apply_property_template(&mut self, template_id: Option<u32>) {
        if let Some(template_id) = template_id {
            self.atoms = self.atoms.apply_template(template_id);
        }
    }

    fn apply_role(&mut self, role: RegionRole, region_id: i64) {
        self.atoms = self.atoms.apply_role(role, region_id);
    }
}

fn region_properties(role: RegionRole, region_id: i64, style_id: Option<u32>) -> AtomProperties {
    AtomProperties {
        style_ids: style_id.into_iter().collect(),
        roles: vec![RegionRoleEntry { role, region_id }],
        ..AtomProperties::default()
    }
}

impl Atom {
    fn width(&self) -> i64 {
        match self {
            Self::Text { width, .. } | Self::Space { width, .. } => *width,
        }
    }

    fn wrap_space(&self) -> bool {
        match self {
            Self::Text { space, .. } => *space,
            Self::Space { .. } => true,
        }
    }

    fn wrap_cjk(&self) -> bool {
        matches!(self, Self::Text { cjk: true, .. })
    }

    fn properties(&self) -> &AtomProperties {
        match self {
            Self::Text { properties, .. } | Self::Space { properties, .. } => properties,
        }
    }

    fn properties_mut(&mut self) -> &mut AtomProperties {
        match self {
            Self::Text { properties, .. } | Self::Space { properties, .. } => properties,
        }
    }
}

#[derive(Debug, Clone)]
struct Rendered {
    lines: LinePlan,
    // A zero-height box still has an inline layout extent.  Text lines alone
    // cannot retain that fact for Row slots, Flex bases, or intrinsic Columns.
    empty_width: i64,
    root_scroll: Option<Arc<RootScrollPlan>>,
    own_scroll_owner: bool,
    scroll_owners: u8,
}

#[derive(Debug)]
pub(crate) struct RootScrollPlan {
    region_id: i64,
    full_content: LinePlan,
    rendered_content: LinePlan,
    visible_height: i64,
    effective_offset: i64,
    text_input: Option<RootTextInput>,
}

#[derive(Debug)]
struct RootTextInput {
    source: Arc<MeasuredText>,
    width: i64,
    wrap: WrapMode,
    region: Option<i64>,
    styles: [Option<u32>; 3],
    lines: LinePlan,
}

impl Rendered {
    fn from_lines(lines: Vec<Line>) -> Self {
        Self {
            lines: LinePlan::from_lines(lines),
            empty_width: 0,
            root_scroll: None,
            own_scroll_owner: false,
            scroll_owners: 0,
        }
    }

    fn from_line_plan(lines: LinePlan) -> Self {
        Self {
            lines,
            empty_width: 0,
            root_scroll: None,
            own_scroll_owner: false,
            scroll_owners: 0,
        }
    }

    fn first_width(&self) -> i64 {
        if self.lines.is_empty() {
            self.empty_width
        } else {
            self.lines.first_width()
        }
    }

    fn max_width(&self) -> i64 {
        if self.lines.is_empty() {
            self.empty_width
        } else {
            self.lines.max_width()
        }
    }

    fn min_content_width(&self, wrap_mode: WrapMode) -> i64 {
        if wrap_mode == WrapMode::None || self.lines.is_empty() {
            return self.max_width();
        }
        self.lines.min_content_width()
    }

    fn height(&self) -> i64 {
        self.lines.height()
    }

    fn into_tape(self, style_count: u32) -> LayoutTape {
        line_plan::record_materialized(self.lines.len(), self.lines.prefix_chars(self.lines.len()));
        LayoutTape {
            style_count,
            lines: self
                .lines
                .iter_with_breaks()
                .map(|(view, break_after)| {
                    let line = view.materialize();
                    TapeLine {
                        width: view.width(),
                        atoms: line
                            .atoms
                            .to_vec()
                            .into_iter()
                            .map(|atom| match atom {
                                Atom::Text {
                                    text,
                                    width,
                                    properties,
                                    ..
                                } => TapeAtom::Text {
                                    text,
                                    width,
                                    properties,
                                },
                                Atom::Space { width, properties } => {
                                    TapeAtom::Space { width, properties }
                                }
                            })
                            .collect(),
                        break_after: break_after.map(|view| view.materialize().into_owned()),
                    }
                })
                .collect(),
        }
    }
}

struct TapeWriter {
    bytes: Vec<u8>,
    limit: usize,
}

impl TapeWriter {
    fn new(limit: usize) -> Result<Self, String> {
        if limit < TAPE_HEADER_LEN {
            return Err("Native layout tape limit is smaller than its header".to_owned());
        }
        Ok(Self {
            bytes: vec![0; TAPE_HEADER_LEN],
            limit,
        })
    }

    fn reserve(&self, additional: usize) -> Result<(), String> {
        if self
            .bytes
            .len()
            .checked_add(additional)
            .is_none_or(|length| length > self.limit)
        {
            Err("Native layout tape exceeds the result byte limit".to_owned())
        } else {
            Ok(())
        }
    }

    fn push_bytes(&mut self, bytes: &[u8]) -> Result<(), String> {
        self.reserve(bytes.len())?;
        self.bytes.extend_from_slice(bytes);
        Ok(())
    }

    fn push_u32(&mut self, value: u32) -> Result<(), String> {
        self.push_bytes(&value.to_le_bytes())
    }

    fn push_u64(&mut self, value: u64) -> Result<(), String> {
        self.push_bytes(&value.to_le_bytes())
    }

    fn patch_u16(&mut self, offset: usize, value: u16) {
        self.bytes[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
    }

    fn patch_u32(&mut self, offset: usize, value: u32) {
        self.bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
    }

    fn patch_u64(&mut self, offset: usize, value: u64) {
        self.bytes[offset..offset + 8].copy_from_slice(&value.to_le_bytes());
    }

    fn patch_i64(&mut self, offset: usize, value: i64) {
        self.bytes[offset..offset + 8].copy_from_slice(&value.to_le_bytes());
    }

    fn finish_header(
        mut self,
        identity: TapeIdentity,
        ok: bool,
        patch: bool,
        style_count: u32,
        line_count: u32,
        character_count: u64,
    ) -> Vec<u8> {
        let mut flags = if ok { TAPE_FLAG_OK } else { 0 };
        if identity.complete {
            flags |= TAPE_FLAG_COMPLETE;
        }
        if patch {
            flags |= TAPE_FLAG_PATCH;
        }
        let total_len = self.bytes.len() as u64;
        let body_len = total_len - TAPE_HEADER_LEN as u64;
        self.bytes[..4].copy_from_slice(TAPE_MAGIC);
        self.patch_u16(4, TAPE_VERSION);
        self.patch_u16(6, flags);
        self.patch_u32(8, TAPE_HEADER_LEN as u32);
        self.patch_u64(12, total_len);
        self.patch_u64(20, identity.session_id);
        self.patch_u64(28, identity.generation);
        self.patch_i64(36, identity.key);
        self.patch_u64(44, identity.runtime_revision);
        self.patch_i64(52, identity.context_hash);
        self.patch_i64(60, identity.viewport_width);
        self.patch_i64(68, identity.viewport_height);
        self.patch_i64(76, identity.root_width);
        self.patch_u32(84, style_count);
        self.patch_u32(88, line_count);
        self.patch_u64(92, character_count);
        self.patch_u64(100, body_len);
        self.patch_u32(108, 0);
        self.bytes
    }
}

impl RegionRole {
    fn lisp_property(self) -> &'static str {
        match self {
            Self::PaddingLeft => "ebox-pl",
            Self::PaddingRight => "ebox-pr",
            Self::PaddingTop => "ebox-pt",
            Self::PaddingBottom => "ebox-pb",
            Self::BorderLeft => "ebox-bl",
            Self::BorderRight => "ebox-br",
            Self::BorderTop => "ebox-bt",
            Self::BorderBottom => "ebox-bb",
            Self::MarginLeft => "ebox-ml",
            Self::MarginRight => "ebox-mr",
            Self::MarginTop => "ebox-mt",
            Self::MarginBottom => "ebox-mb",
        }
    }

    fn metadata_kind(self) -> u8 {
        match self {
            Self::PaddingLeft => METADATA_ROLE_PADDING_LEFT,
            Self::PaddingRight => METADATA_ROLE_PADDING_RIGHT,
            Self::PaddingTop => METADATA_ROLE_PADDING_TOP,
            Self::PaddingBottom => METADATA_ROLE_PADDING_BOTTOM,
            Self::BorderLeft => METADATA_ROLE_BORDER_LEFT,
            Self::BorderRight => METADATA_ROLE_BORDER_RIGHT,
            Self::BorderTop => METADATA_ROLE_BORDER_TOP,
            Self::BorderBottom => METADATA_ROLE_BORDER_BOTTOM,
            Self::MarginLeft => METADATA_ROLE_MARGIN_LEFT,
            Self::MarginRight => METADATA_ROLE_MARGIN_RIGHT,
            Self::MarginTop => METADATA_ROLE_MARGIN_TOP,
            Self::MarginBottom => METADATA_ROLE_MARGIN_BOTTOM,
        }
    }
}

fn count_u32(value: usize, label: &str) -> Result<u32, String> {
    u32::try_from(value).map_err(|_| format!("Native layout tape has too many {label}"))
}

fn tape_width(value: i64, label: &str) -> Result<u64, String> {
    u64::try_from(value).map_err(|_| format!("Native layout tape has negative {label}"))
}

#[derive(Debug)]
struct TapeSpaceSpan {
    start: u64,
    width: u64,
}

#[derive(Debug)]
struct TapePropertySpan {
    start: u64,
    end: u64,
    properties: AtomProperties,
}

#[derive(Debug)]
struct LiteralInterval {
    start: u64,
    end: u64,
    properties: String,
}

#[derive(Debug)]
struct TapeMetadataRecord {
    kind: u8,
    region_id: i64,
    index: u32,
    start: u64,
    end: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct FragmentTemplate {
    start: u64,
    end: u64,
    line: u64,
    roles: Vec<(&'static str, i64)>,
    content_owner: Option<i64>,
    content_index: Option<i64>,
    property_template_ids: Vec<u32>,
    style_ids: Vec<u32>,
}

type FragmentRoles = Vec<(&'static str, i64)>;
type FragmentOwnershipSpan = (u64, u64, FragmentRoles);
type RegionMountKey = (i64, Vec<&'static str>);
type RegionMountSpan = (RegionMountKey, u64, u64);
type FragmentStyleDelta = Vec<(usize, Vec<u32>)>;

fn propagated_fragment_roles(fragments: &[FragmentTemplate]) -> Vec<Vec<(&'static str, i64)>> {
    let mut propagated = vec![Vec::new(); fragments.len()];
    let mut previous = Vec::new();
    for (index, fragment) in fragments.iter().enumerate() {
        if fragment.roles.is_empty() {
            propagated[index] = previous.clone();
        } else {
            previous = fragment.roles.clone();
            propagated[index] = previous.clone();
        }
    }
    let mut next = Vec::new();
    for index in (0..fragments.len()).rev() {
        if fragments[index].roles.is_empty() {
            for role in &next {
                if !propagated[index].contains(role) {
                    propagated[index].push(*role);
                }
            }
        } else {
            next = fragments[index].roles.clone();
        }
    }
    propagated
}

fn fragment_ownership_spans(fragments: &[FragmentTemplate]) -> Vec<FragmentOwnershipSpan> {
    let mut spans: Vec<FragmentOwnershipSpan> = Vec::new();
    for (fragment, roles) in fragments.iter().zip(propagated_fragment_roles(fragments)) {
        if let Some(previous) = spans.last_mut() {
            if previous.1 == fragment.start && previous.2 == roles {
                previous.1 = fragment.end;
                continue;
            }
        }
        spans.push((fragment.start, fragment.end, roles));
    }
    spans
}

fn fragment_region_mount_projection(fragments: &[FragmentTemplate]) -> Vec<RegionMountSpan> {
    let mut spans: Vec<RegionMountSpan> = Vec::new();
    let mut active: BTreeMap<RegionMountKey, usize> = BTreeMap::new();
    for fragment in fragments {
        let mut roles_by_region: BTreeMap<i64, Vec<&'static str>> = BTreeMap::new();
        for (role, region_id) in &fragment.roles {
            roles_by_region.entry(*region_id).or_default().push(*role);
        }
        for (region_id, roles) in roles_by_region {
            let key = (region_id, roles);
            if let Some(index) = active.get(&key).copied() {
                if spans[index].2 == fragment.start {
                    spans[index].2 = fragment.end;
                    continue;
                }
            }
            let index = spans.len();
            spans.push((key.clone(), fragment.start, fragment.end));
            active.insert(key, index);
        }
    }
    spans
}

fn fragment_style_delta(
    old: &[FragmentTemplate],
    target: &[FragmentTemplate],
) -> Option<FragmentStyleDelta> {
    if old.len() != target.len() {
        return None;
    }
    let mut delta = Vec::new();
    for (index, (old, target)) in old.iter().zip(target).enumerate() {
        if old.start != target.start
            || old.end != target.end
            || old.line != target.line
            || old.roles != target.roles
            || old.content_owner != target.content_owner
            || old.content_index != target.content_index
            || old.property_template_ids != target.property_template_ids
        {
            return None;
        }
        if old.style_ids != target.style_ids {
            delta.push((index, target.style_ids.clone()));
        }
    }
    Some(delta)
}

#[derive(Debug)]
struct CompiledStyle {
    mode: StyleMode,
    face: String,
}

fn validate_style_string(value: &str, label: &str) -> Result<(), String> {
    if value.len() > MAX_STYLE_STRING_BYTES {
        return Err(format!("Native layout {label} exceeds its byte limit"));
    }
    Ok(())
}

fn push_lisp_string(output: &mut String, value: &str) {
    output.push('"');
    for character in value.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            character if character.is_control() => {
                output.push_str(&format!("\\u{:04x}", character as u32));
            }
            character => output.push(character),
        }
    }
    output.push('"');
}

fn push_property(output: &mut String, first: &mut bool, name: &str, value: &str) {
    if !*first {
        output.push(' ');
    }
    *first = false;
    output.push_str(name);
    output.push(' ');
    output.push_str(value);
}

impl FaceTemplate {
    fn validate(&self) -> Result<(), String> {
        if let Some(lisp) = &self.lisp {
            validate_style_string(lisp, "face literal")?;
            if self.inherit.is_some()
                || self.inverse_video.is_some()
                || self.foreground.is_some()
                || self.background.is_some()
                || self.overline.is_some()
                || self.underline.is_some()
            {
                return Err("Native layout literal face cannot mix typed fields".to_owned());
            }
            return Ok(());
        }
        if self.inherit.is_none()
            && self.inverse_video.is_none()
            && self.foreground.is_none()
            && self.background.is_none()
            && self.overline.is_none()
            && self.underline.is_none()
        {
            return Err("Native layout face template is empty".to_owned());
        }
        if let Some(inherit) = &self.inherit {
            if inherit != "default" {
                return Err("Native layout inherit face must be default".to_owned());
            }
        }
        if self.inverse_video == Some(false) {
            return Err("Native layout inverse-video face must be true".to_owned());
        }
        if let Some(value) = &self.foreground {
            validate_style_string(value, "foreground color")?;
        }
        if let Some(value) = &self.background {
            validate_style_string(value, "background color")?;
        }
        if let Some(value) = &self.overline {
            match value {
                ColorOrTrue::Boolean(true) => {}
                ColorOrTrue::Boolean(false) => {
                    return Err("Native layout overline face must be true or a color".to_owned());
                }
                ColorOrTrue::Color(color) => {
                    validate_style_string(color, "overline color")?;
                }
            }
        }
        if let Some(underline) = &self.underline {
            if !underline.position {
                return Err("Native layout underline position must be true".to_owned());
            }
            if let Some(color) = &underline.color {
                validate_style_string(color, "underline color")?;
            }
        }
        Ok(())
    }

    fn to_lisp(&self) -> String {
        if let Some(lisp) = &self.lisp {
            return lisp.clone();
        }
        let mut output = String::from("(");
        let mut first = true;
        if self.inherit.as_deref() == Some("default") {
            push_property(&mut output, &mut first, ":inherit", "default");
        }
        if self.inverse_video == Some(true) {
            push_property(&mut output, &mut first, ":inverse-video", "t");
        }
        if let Some(color) = &self.foreground {
            let mut value = String::new();
            push_lisp_string(&mut value, color);
            push_property(&mut output, &mut first, ":foreground", &value);
        }
        if let Some(color) = &self.background {
            let mut value = String::new();
            push_lisp_string(&mut value, color);
            push_property(&mut output, &mut first, ":background", &value);
        }
        if let Some(overline) = &self.overline {
            let value = match overline {
                ColorOrTrue::Boolean(true) => "t".to_owned(),
                ColorOrTrue::Boolean(false) => unreachable!("validated face template"),
                ColorOrTrue::Color(color) => {
                    let mut value = String::new();
                    push_lisp_string(&mut value, color);
                    value
                }
            };
            push_property(&mut output, &mut first, ":overline", &value);
        }
        if let Some(underline) = &self.underline {
            let mut value = String::from("(:position t");
            if let Some(color) = &underline.color {
                value.push_str(" :color ");
                push_lisp_string(&mut value, color);
            }
            value.push(')');
            push_property(&mut output, &mut first, ":underline", &value);
        }
        output.push(')');
        output
    }
}

impl StyleTemplate {
    fn compile(&self) -> Result<CompiledStyle, String> {
        self.face.validate()?;
        Ok(CompiledStyle {
            mode: self.mode,
            face: self.face.to_lisp(),
        })
    }
}

pub(crate) fn style_registry_extends_exact_prefix(
    old: &[StyleTemplate],
    target: &[StyleTemplate],
) -> bool {
    target.starts_with(old)
}

fn composed_face(
    properties: &AtomProperties,
    styles: &[CompiledStyle],
) -> Result<Option<String>, String> {
    if properties.style_ids.len() > MAX_TAPE_PROPERTY_ENTRIES {
        return Err("Native layout tape has too many style layers".to_owned());
    }
    let mut faces: Vec<usize> = Vec::new();
    let mut list_value = false;
    for style_id in &properties.style_ids {
        let style_index = *style_id as usize;
        let style = styles
            .get(style_index)
            .ok_or_else(|| format!("Native layout tape has invalid style id {style_id}"))?;
        match style.mode {
            StyleMode::Set => {
                faces.clear();
                faces.push(style_index);
                list_value = false;
            }
            StyleMode::Add => {
                if faces.len() == 1 && styles[faces[0]].face == style.face {
                    continue;
                }
                if !faces.is_empty() {
                    list_value = true;
                }
                faces.push(style_index);
            }
        }
    }
    if faces.is_empty() {
        Ok(None)
    } else if list_value {
        Ok(Some(format!(
            "({})",
            faces
                .iter()
                .map(|index| format!("#{}#", index + 1))
                .collect::<Vec<_>>()
                .join(" ")
        )))
    } else {
        Ok(Some(format!("#{}#", faces[0] + 1)))
    }
}

fn properties_to_lisp(
    properties: Option<&AtomProperties>,
    pixel_width: Option<u64>,
    styles: &[CompiledStyle],
) -> Result<Option<String>, String> {
    let mut output = String::from("(");
    let mut first = true;
    if let Some(properties) = properties {
        if properties.owners.len() > MAX_TAPE_PROPERTY_ENTRIES
            || properties.roles.len() > MAX_TAPE_PROPERTY_ENTRIES
            || properties.property_template_ids.len() > MAX_TAPE_PROPERTY_ENTRIES
        {
            return Err("Native layout tape property record exceeds its entry limit".to_owned());
        }
        if let Some(face) = composed_face(properties, styles)? {
            push_property(&mut output, &mut first, "face", &face);
        }
        if let Some(content) = properties.content {
            push_property(
                &mut output,
                &mut first,
                "ebox-content",
                &content.to_string(),
            );
        }
        if let Some(content_idx) = properties.content_idx {
            push_property(
                &mut output,
                &mut first,
                "ebox-content-idx",
                &content_idx.to_string(),
            );
        }
        if let Some(owner) = properties.owner {
            push_property(
                &mut output,
                &mut first,
                "ebox-content-owner",
                &owner.to_string(),
            );
        }
        if !properties.owners.is_empty() {
            let owners = format!(
                "({})",
                properties
                    .owners
                    .iter()
                    .map(i64::to_string)
                    .collect::<Vec<_>>()
                    .join(" ")
            );
            push_property(&mut output, &mut first, "ebox-content-owners", &owners);
        }
        for role in REGION_ROLES {
            if let Some(entry) = properties
                .roles
                .iter()
                .rev()
                .find(|entry| entry.role == role)
            {
                push_property(
                    &mut output,
                    &mut first,
                    role.lisp_property(),
                    &entry.region_id.to_string(),
                );
            }
        }
        if let Some(scroll_window) = properties.scroll_window {
            push_property(
                &mut output,
                &mut first,
                "ebox-scroll-window",
                &scroll_window.to_string(),
            );
        }
        if !properties.property_template_ids.is_empty() {
            let template_ids = format!(
                "({})",
                properties
                    .property_template_ids
                    .iter()
                    .map(u32::to_string)
                    .collect::<Vec<_>>()
                    .join(" ")
            );
            push_property(
                &mut output,
                &mut first,
                "ebox-native-property-template-ids",
                &template_ids,
            );
        }
    }
    if let Some(pixel_width) = pixel_width {
        push_property(
            &mut output,
            &mut first,
            "display",
            &format!("(space :width ({pixel_width}))"),
        );
    }
    output.push(')');
    if first {
        Ok(None)
    } else {
        Ok(Some(output))
    }
}

fn encode_lisp_literal(
    text: &str,
    spaces: &[TapeSpaceSpan],
    property_spans: &[TapePropertySpan],
    styles: &[CompiledStyle],
    character_count: u64,
    max_bytes: usize,
) -> Result<String, String> {
    encode_lisp_literal_inner(
        text,
        spaces,
        property_spans,
        styles,
        character_count,
        max_bytes,
        true,
    )
}

fn encode_lisp_literal_inner(
    text: &str,
    spaces: &[TapeSpaceSpan],
    property_spans: &[TapePropertySpan],
    styles: &[CompiledStyle],
    character_count: u64,
    max_bytes: usize,
    define_styles: bool,
) -> Result<String, String> {
    let mut boundaries = Vec::with_capacity(2 + spaces.len() * 2 + property_spans.len() * 2);
    boundaries.push(0);
    boundaries.push(character_count);
    for space in spaces {
        boundaries.push(space.start);
        boundaries.push(space.start + 1);
    }
    for span in property_spans {
        boundaries.push(span.start);
        boundaries.push(span.end);
    }
    boundaries.sort_unstable();
    boundaries.dedup();

    let mut intervals: Vec<LiteralInterval> = Vec::new();
    let mut property_index = 0;
    let mut space_index = 0;
    for boundary in boundaries.windows(2) {
        let start = boundary[0];
        let end = boundary[1];
        if start == end {
            continue;
        }
        while property_index < property_spans.len() && property_spans[property_index].end <= start {
            property_index += 1;
        }
        while space_index < spaces.len() && spaces[space_index].start < start {
            space_index += 1;
        }
        let properties = property_spans
            .get(property_index)
            .filter(|span| span.start <= start && end <= span.end)
            .map(|span| &span.properties);
        let pixel_width = spaces
            .get(space_index)
            .filter(|space| space.start == start)
            .map(|space| space.width);
        if let Some(properties) = properties_to_lisp(properties, pixel_width, styles)? {
            if let Some(previous) = intervals.last_mut() {
                if previous.end == start && previous.properties == properties {
                    previous.end = end;
                    continue;
                }
            }
            intervals.push(LiteralInterval {
                start,
                end,
                properties,
            });
        }
    }

    let mut shared_properties = shared_literal_properties(&intervals, styles.len());
    let mut literal = String::with_capacity(text.len().saturating_mul(2));
    literal.push_str("#(");
    push_lisp_string(&mut literal, text);
    if define_styles {
        for (index, style) in styles.iter().enumerate() {
            literal.push_str(" 0 0 (face #");
            literal.push_str(&(index + 1).to_string());
            literal.push('=');
            literal.push_str(&style.face);
            literal.push(')');
        }
    }
    for interval in intervals {
        literal.push(' ');
        literal.push_str(&interval.start.to_string());
        literal.push(' ');
        literal.push_str(&interval.end.to_string());
        literal.push(' ');
        if let Some(label) = shared_properties.get_mut(&interval.properties) {
            if !label.defined {
                literal.push('#');
                literal.push_str(&label.id.to_string());
                literal.push('=');
                literal.push_str(&interval.properties);
                label.defined = true;
            } else {
                literal.push('#');
                literal.push_str(&label.id.to_string());
                literal.push('#');
            }
        } else {
            literal.push_str(&interval.properties);
        }
        if literal.len() > max_bytes {
            return Err("Native layout tape exceeds its byte limit".to_owned());
        }
    }
    literal.push(')');
    if literal.len() > max_bytes {
        return Err("Native layout tape exceeds its byte limit".to_owned());
    }
    Ok(literal)
}

#[derive(Debug)]
struct SharedLiteralProperty {
    id: usize,
    defined: bool,
}

fn shared_literal_properties(
    intervals: &[LiteralInterval],
    reserved_label_count: usize,
) -> BTreeMap<String, SharedLiteralProperty> {
    let mut counts = BTreeMap::new();
    for interval in intervals {
        *counts.entry(interval.properties.clone()).or_insert(0_usize) += 1;
    }
    let mut labels = BTreeMap::new();
    let mut next_label = reserved_label_count + 1;
    for interval in intervals {
        if labels.contains_key(&interval.properties) {
            continue;
        }
        let count = *counts.get(&interval.properties).unwrap_or(&0);
        if count < 2 {
            continue;
        }
        let id = next_label;
        let definition_overhead = format!("#{id}=").len();
        let reference_length = format!("#{id}#").len();
        let saved_references = count - 1;
        let saved_bytes = saved_references
            .saturating_mul(interval.properties.len().saturating_sub(reference_length));
        if saved_bytes > definition_overhead {
            labels.insert(
                interval.properties.clone(),
                SharedLiteralProperty { id, defined: false },
            );
            next_label += 1;
        }
    }
    labels
}

fn tape_properties(mut properties: AtomProperties, complete: bool) -> AtomProperties {
    if !complete {
        properties.content = None;
        properties.content_idx = None;
        properties.owner = None;
        properties.owners.clear();
        properties.roles.clear();
        properties.scroll_window = None;
        properties.property_template_ids.clear();
    }
    properties
}

fn tape_properties_empty(properties: &AtomProperties) -> bool {
    properties.style_ids.is_empty()
        && properties.content.is_none()
        && properties.content_idx.is_none()
        && properties.owner.is_none()
        && properties.owners.is_empty()
        && properties.roles.is_empty()
        && properties.scroll_window.is_none()
        && properties.property_template_ids.is_empty()
}

fn push_property_span(
    spans: &mut Vec<TapePropertySpan>,
    start: u64,
    end: u64,
    properties: AtomProperties,
    complete: bool,
) {
    let properties = tape_properties(properties, complete);
    if start == end || tape_properties_empty(&properties) {
        return;
    }
    if let Some(previous) = spans.last_mut() {
        if previous.end == start && previous.properties == properties {
            previous.end = end;
            return;
        }
    }
    spans.push(TapePropertySpan {
        start,
        end,
        properties,
    });
}

fn push_metadata_span(
    records: &mut Vec<TapeMetadataRecord>,
    last_by_key: &mut BTreeMap<(u8, i64, u32), usize>,
    kind: u8,
    region_id: i64,
    index: u32,
    start: u64,
    end: u64,
) -> Result<(), String> {
    if start >= end {
        return Ok(());
    }
    if region_id <= 0 {
        return Err("Native layout tape metadata has an invalid region id".to_owned());
    }
    let key = (kind, region_id, index);
    if let Some(previous_index) = last_by_key.get(&key).copied() {
        let previous = &mut records[previous_index];
        if previous.end == start {
            previous.end = end;
            return Ok(());
        }
    }
    if records.len() >= MAX_TAPE_METADATA_RECORDS {
        return Err("Native layout tape has too many metadata records".to_owned());
    }
    let record_index = records.len();
    records.push(TapeMetadataRecord {
        kind,
        region_id,
        index,
        start,
        end,
    });
    last_by_key.insert(key, record_index);
    Ok(())
}

fn metadata_extent_region_ids(properties: &AtomProperties) -> Vec<i64> {
    let mut region_ids = properties.owners.clone();
    if let Some(region_id) = properties.owner {
        if !region_ids.contains(&region_id) {
            region_ids.push(region_id);
        }
    }
    if let Some(region_id) = properties.content {
        if !region_ids.contains(&region_id) {
            region_ids.push(region_id);
        }
    }
    for role in &properties.roles {
        if !region_ids.contains(&role.region_id) {
            region_ids.push(role.region_id);
        }
    }
    region_ids
}

#[derive(Debug)]
struct MetadataExtentRange {
    start: u64,
    end: u64,
    last_event: u64,
    last_safe_event: u64,
    interleaved: bool,
}

fn push_box_extent_metadata_records(
    text: &str,
    property_spans: &[TapePropertySpan],
    records: &mut Vec<TapeMetadataRecord>,
    last_by_key: &mut BTreeMap<(u8, i64, u32), usize>,
) -> Result<(), String> {
    let mut non_newline_prefix = Vec::with_capacity(text.chars().count() + 1);
    non_newline_prefix.push(0_u64);
    for character in text.chars() {
        let previous = *non_newline_prefix.last().unwrap_or(&0);
        non_newline_prefix.push(previous + u64::from(character != '\n'));
    }
    let mut ranges: BTreeMap<i64, MetadataExtentRange> = BTreeMap::new();
    let mut safe_events: BTreeMap<i64, u64> = BTreeMap::new();
    let mut event = 0_u64;
    for span in property_spans {
        let region_ids = metadata_extent_region_ids(&span.properties);
        for region_id in &region_ids {
            let region_id = *region_id;
            if region_id <= 0 {
                return Err("Native layout tape metadata has an invalid extent id".to_owned());
            }
            if let Some(range) = ranges.get_mut(&region_id) {
                let safe_event = safe_events.get(&region_id).copied().unwrap_or(0);
                if span.start > range.end
                    && event - range.last_event > safe_event - range.last_safe_event
                {
                    range.interleaved = true;
                }
                range.start = range.start.min(span.start);
                range.end = range.end.max(span.end);
            } else {
                ranges.insert(
                    region_id,
                    MetadataExtentRange {
                        start: span.start,
                        end: span.end,
                        last_event: event,
                        last_safe_event: safe_events.get(&region_id).copied().unwrap_or(0),
                        interleaved: false,
                    },
                );
            }
        }
        let start = usize::try_from(span.start)
            .map_err(|_| "Native layout tape metadata span is too large".to_owned())?;
        let end = usize::try_from(span.end)
            .map_err(|_| "Native layout tape metadata span is too large".to_owned())?;
        let contains_non_newline = non_newline_prefix
            .get(end)
            .zip(non_newline_prefix.get(start))
            .is_some_and(|(end_count, start_count)| end_count > start_count);
        if contains_non_newline && !region_ids.is_empty() {
            event += 1;
            let mut safe_region_ids = span.properties.owners.clone();
            if region_ids.len() == 1 && !safe_region_ids.contains(&region_ids[0]) {
                safe_region_ids.push(region_ids[0]);
            }
            for region_id in safe_region_ids {
                *safe_events.entry(region_id).or_insert(0) += 1;
            }
        }
        for region_id in region_ids {
            let range = ranges
                .get_mut(&region_id)
                .ok_or_else(|| "Native layout tape extent state disappeared".to_owned())?;
            range.last_event = event;
            range.last_safe_event = safe_events.get(&region_id).copied().unwrap_or(0);
        }
    }
    for (region_id, range) in ranges {
        if !range.interleaved {
            push_metadata_span(
                records,
                last_by_key,
                METADATA_BOX_EXTENT,
                region_id,
                0,
                range.start,
                range.end,
            )?;
        }
    }
    Ok(())
}

fn build_root_metadata_records(
    text: &str,
    property_spans: &[TapePropertySpan],
) -> Result<Vec<TapeMetadataRecord>, String> {
    let mut records = Vec::new();
    let mut last_by_key = BTreeMap::new();

    push_box_extent_metadata_records(text, property_spans, &mut records, &mut last_by_key)?;

    // Root replacement role templates use one-based buffer points.  Keep the
    // tape zero-based and translate only after the sidecar has been validated
    // by Emacs.
    for span in property_spans {
        if let Some(region_id) = span.properties.content {
            push_metadata_span(
                &mut records,
                &mut last_by_key,
                METADATA_ROLE_CONTENT,
                region_id,
                0,
                span.start,
                span.end,
            )?;
        }
        if let Some(region_id) = span.properties.owner {
            push_metadata_span(
                &mut records,
                &mut last_by_key,
                METADATA_ROLE_CONTENT_OWNER,
                region_id,
                0,
                span.start,
                span.end,
            )?;
        }
        for role in REGION_ROLES {
            if let Some(entry) = span
                .properties
                .roles
                .iter()
                .rev()
                .find(|entry| entry.role == role)
            {
                push_metadata_span(
                    &mut records,
                    &mut last_by_key,
                    role.metadata_kind(),
                    entry.region_id,
                    0,
                    span.start,
                    span.end,
                )?;
            }
        }
    }

    // Direct scroll content spans precede wrapper-owner line spans, matching
    // `ebox--build-scroll-content-span-template'.  Extra non-scroll region ids
    // are harmless: installation filters against the live scroll-state table.
    for span in property_spans {
        if let (Some(region_id), Some(index)) =
            (span.properties.content, span.properties.content_idx)
        {
            let index = u32::try_from(index)
                .map_err(|_| "Native layout tape has an invalid content index".to_owned())?;
            push_metadata_span(
                &mut records,
                &mut last_by_key,
                METADATA_SCROLL_CONTENT,
                region_id,
                index,
                span.start,
                span.end,
            )?;
        }
    }

    let mut line_ranges = Vec::new();
    let mut line_start = 0_u64;
    let mut position = 0_u64;
    for character in text.chars() {
        if character == '\n' {
            if line_start < position {
                line_ranges.push((line_start, position));
            }
            line_start = position + 1;
        }
        position += 1;
    }
    if line_start < position {
        line_ranges.push((line_start, position));
    }

    let mut owner_line_indexes: BTreeMap<i64, u32> = BTreeMap::new();
    let mut first_span = 0_usize;
    for (line_start, line_end) in line_ranges {
        while first_span < property_spans.len() && property_spans[first_span].end <= line_start {
            first_span += 1;
        }
        let mut line_owners: BTreeMap<i64, (u64, u64)> = BTreeMap::new();
        let mut span_index = first_span;
        while span_index < property_spans.len() && property_spans[span_index].start < line_end {
            let span = &property_spans[span_index];
            let start = span.start.max(line_start);
            let end = span.end.min(line_end);
            if start < end {
                let mut owner_ids = span.properties.owners.clone();
                if let Some(owner) = span.properties.owner {
                    if !owner_ids.contains(&owner) {
                        owner_ids.push(owner);
                    }
                }
                for region_id in owner_ids {
                    if region_id <= 0 {
                        return Err(
                            "Native layout tape metadata has an invalid owner id".to_owned()
                        );
                    }
                    line_owners
                        .entry(region_id)
                        .and_modify(|record| record.1 = record.1.max(end))
                        .or_insert((start, end));
                }
            }
            span_index += 1;
        }
        for (region_id, (start, end)) in line_owners {
            let index = owner_line_indexes.entry(region_id).or_insert(0);
            push_metadata_span(
                &mut records,
                &mut last_by_key,
                METADATA_SCROLL_OWNER,
                region_id,
                *index,
                start,
                end,
            )?;
            *index = index
                .checked_add(1)
                .ok_or_else(|| "Native layout tape owner index overflow".to_owned())?;
        }
    }

    if let Some((region_id, start, end)) = property_spans.iter().find_map(|span| {
        span.properties
            .scroll_window
            .map(|region_id| (region_id, span.start, span.end))
    }) {
        push_metadata_span(
            &mut records,
            &mut last_by_key,
            METADATA_SCROLL_WINDOW,
            region_id,
            0,
            start,
            end,
        )?;
    }
    Ok(records)
}

fn push_fragment_role(
    roles: &mut Vec<(&'static str, i64)>,
    role: &'static str,
    region_id: i64,
) -> Result<(), String> {
    if region_id <= 0 {
        return Err("Native layout fragment has an invalid region id".to_owned());
    }
    if !roles
        .iter()
        .any(|(existing_role, existing_id)| *existing_role == role && *existing_id == region_id)
    {
        roles.push((role, region_id));
    }
    Ok(())
}

fn fragment_roles(properties: &AtomProperties) -> Result<Vec<(&'static str, i64)>, String> {
    let mut roles = Vec::new();
    for region_id in &properties.owners {
        push_fragment_role(&mut roles, "content-owner", *region_id)?;
    }
    if let Some(region_id) = properties.content {
        push_fragment_role(&mut roles, "content", region_id)?;
    }
    if let Some(region_id) = properties.owner {
        push_fragment_role(&mut roles, "content-owner", region_id)?;
    }
    for role in REGION_ROLES {
        if let Some(entry) = properties
            .roles
            .iter()
            .rev()
            .find(|entry| entry.role == role)
        {
            let symbol = metadata_role_symbol(role.metadata_kind())
                .ok_or_else(|| "Native layout fragment has an unknown role".to_owned())?;
            push_fragment_role(&mut roles, symbol, entry.region_id)?;
        }
    }
    Ok(roles)
}

fn build_fragment_templates(
    text: &str,
    spaces: &[TapeSpaceSpan],
    property_spans: &[TapePropertySpan],
) -> Result<Vec<FragmentTemplate>, String> {
    let character_count = u64::try_from(text.chars().count())
        .map_err(|_| "Native layout fragment character count overflow".to_owned())?;
    let mut boundaries = Vec::with_capacity(2 + spaces.len() * 2 + property_spans.len() * 2);
    boundaries.push(0);
    boundaries.push(character_count);
    for space in spaces {
        boundaries.push(space.start);
        boundaries.push(space.start + 1);
    }
    for span in property_spans {
        boundaries.push(span.start);
        boundaries.push(span.end);
    }
    boundaries.sort_unstable();
    boundaries.dedup();

    let mut line_prefix = Vec::with_capacity(text.chars().count() + 1);
    line_prefix.push(0_u64);
    for character in text.chars() {
        let previous = *line_prefix.last().unwrap_or(&0);
        line_prefix.push(previous + u64::from(character == '\n'));
    }

    let empty = AtomProperties::default();
    let mut property_index = 0;
    let mut fragments = Vec::with_capacity(boundaries.len().saturating_sub(1));
    for boundary in boundaries.windows(2) {
        let start = boundary[0];
        let end = boundary[1];
        if start == end {
            continue;
        }
        while property_index < property_spans.len() && property_spans[property_index].end <= start {
            property_index += 1;
        }
        let properties = property_spans
            .get(property_index)
            .filter(|span| span.start <= start && end <= span.end)
            .map_or(&empty, |span| &span.properties);
        let line_index = usize::try_from(start)
            .map_err(|_| "Native layout fragment offset is too large".to_owned())?;
        let line = *line_prefix
            .get(line_index)
            .ok_or_else(|| "Native layout fragment line offset is invalid".to_owned())?;
        if properties.content_idx.is_some_and(|index| index < 0) {
            return Err("Native layout fragment has a negative content index".to_owned());
        }
        fragments.push(FragmentTemplate {
            start,
            end,
            line,
            roles: fragment_roles(properties)?,
            content_owner: properties.owner,
            content_index: properties.content_idx,
            property_template_ids: properties.property_template_ids.clone(),
            style_ids: properties.style_ids.clone(),
        });
    }
    Ok(fragments)
}

struct RootMetadataPayload {
    literal: String,
    record_count: usize,
    fragments: Vec<FragmentTemplate>,
    fragment_bytes: Vec<u8>,
    fragment_count: usize,
}

fn append_scroll_metadata(
    payload: &mut Option<RootMetadataPayload>,
    scroll: Option<(&RootScrollPlan, Option<&RootScrollPlan>)>,
    styles: &[CompiledStyle],
    style_count: u32,
    max_bytes: usize,
) -> Result<(), String> {
    let (Some(payload), Some((scroll, base))) = (payload.as_mut(), scroll) else {
        return Ok(());
    };
    let mut effect = format!(
        " :root-scroll-producer [{} {} {} {} ",
        scroll.region_id,
        scroll.full_content.len(),
        scroll.visible_height,
        scroll.effective_offset
    );
    let inactive = scroll.full_content.len() as i64 <= scroll.visible_height;
    let reused = !inactive
        && base.is_some_and(|base| {
            base.region_id == scroll.region_id
                && base.full_content.len() as i64 > base.visible_height
                && base.full_content.ptr_eq(&scroll.full_content)
                && base.rendered_content.ptr_eq(&scroll.rendered_content)
        });
    if inactive {
        // The receiver needs only geometry to retire its active scroll state.
        // Keep the complete plans in this frame for a later clipped request.
        effect.push_str(":inactive :inactive ");
    } else if reused {
        effect.push_str(":reuse :reuse ");
        evaluation::record(EvalWork {
            scroll_producer_reuses: 1,
            ..EvalWork::default()
        });
    } else {
        for plan in [&scroll.full_content, &scroll.rendered_content] {
            evaluation::record(EvalWork {
                scroll_producer_lines_encoded: plan.len() as u64,
                scroll_producer_chars_encoded: plan.prefix_chars(plan.len()),
                ..EvalWork::default()
            });
            let tape = Rendered::from_line_plan(plan.clone()).into_tape(style_count);
            let flat = flatten_layout_tape(tape, true)?;
            let (text, spaces, properties) = tape_character_encoding_parts(&flat.characters)?;
            let literal = encode_lisp_literal(
                &text,
                &spaces,
                &properties,
                styles,
                flat.characters.len() as u64,
                max_bytes,
            )?;
            // Each nested literal has its own read-circle label namespace.
            push_lisp_string(&mut effect, &literal);
            effect.push(' ');
        }
    }
    effect.push_str("])");
    payload.literal.pop();
    payload.literal.push_str(&effect);
    payload.record_count += 1;
    if payload
        .literal
        .len()
        .saturating_add(payload.fragment_bytes.len())
        > max_bytes
    {
        return Err("Native scroll producer exceeds its byte limit".to_owned());
    }
    Ok(())
}

fn metadata_role_symbol(kind: u8) -> Option<&'static str> {
    match kind {
        METADATA_ROLE_CONTENT => Some("content"),
        METADATA_ROLE_CONTENT_OWNER => Some("content-owner"),
        METADATA_ROLE_PADDING_TOP => Some("pt"),
        METADATA_ROLE_PADDING_BOTTOM => Some("pb"),
        METADATA_ROLE_PADDING_LEFT => Some("pl"),
        METADATA_ROLE_PADDING_RIGHT => Some("pr"),
        METADATA_ROLE_MARGIN_TOP => Some("mt"),
        METADATA_ROLE_MARGIN_BOTTOM => Some("mb"),
        METADATA_ROLE_MARGIN_LEFT => Some("ml"),
        METADATA_ROLE_MARGIN_RIGHT => Some("mr"),
        METADATA_ROLE_BORDER_TOP => Some("bt"),
        METADATA_ROLE_BORDER_BOTTOM => Some("bb"),
        METADATA_ROLE_BORDER_LEFT => Some("bl"),
        METADATA_ROLE_BORDER_RIGHT => Some("br"),
        _ => None,
    }
}

fn push_hash_table(output: &mut String, entries: Vec<String>) {
    output.push_str("#s(hash-table test equal data (");
    output.push_str(&entries.join(" "));
    output.push_str("))");
}

fn metadata_literal_from_records(records: &[TapeMetadataRecord]) -> Result<String, String> {
    let mut role_table: BTreeMap<(i64, &'static str), Vec<(u64, u64)>> = BTreeMap::new();
    let mut extent_table: BTreeMap<i64, (u64, u64)> = BTreeMap::new();
    let mut scroll_table: BTreeMap<i64, Vec<(u32, u64, u64)>> = BTreeMap::new();
    let mut scroll_window_p = false;

    for record in records {
        if let Some(role) = metadata_role_symbol(record.kind) {
            if record.index != 0 {
                return Err("Native layout tape role metadata has a line index".to_owned());
            }
            role_table
                .entry((record.region_id, role))
                .or_default()
                .push((record.start + 1, record.end + 1));
        } else if record.kind == METADATA_BOX_EXTENT {
            if record.index != 0 {
                return Err("Native layout tape box extent metadata has a line index".to_owned());
            }
            extent_table
                .entry(record.region_id)
                .and_modify(|extent| {
                    extent.0 = extent.0.min(record.start + 1);
                    extent.1 = extent.1.max(record.end + 1);
                })
                .or_insert((record.start + 1, record.end + 1));
        } else if record.kind == METADATA_SCROLL_CONTENT || record.kind == METADATA_SCROLL_OWNER {
            scroll_table.entry(record.region_id).or_default().push((
                record.index,
                record.start,
                record.end,
            ));
        } else if record.kind == METADATA_SCROLL_WINDOW {
            if record.index != 0 {
                return Err("Native layout tape scroll-window metadata has a line index".to_owned());
            }
            scroll_window_p = true;
        } else {
            return Err("Native layout tape has unknown metadata kind".to_owned());
        }
    }

    let role_entries = role_table
        .into_iter()
        .map(|((region_id, role), spans)| {
            let spans = spans
                .into_iter()
                .map(|(start, end)| format!("({start} . {end})"))
                .collect::<Vec<_>>()
                .join(" ");
            format!("({region_id} {role}) ({spans})")
        })
        .collect::<Vec<_>>();
    let extent_entries = extent_table
        .into_iter()
        .map(|(region_id, (start, end))| format!("{region_id} ({start} . {end})"))
        .collect::<Vec<_>>();
    let scroll_entries = scroll_table
        .into_iter()
        .map(|(region_id, spans)| {
            let spans = spans
                .into_iter()
                .map(|(index, start, end)| format!("({index} {start} . {end})"))
                .collect::<Vec<_>>()
                .join(" ");
            format!("{region_id} ({spans})")
        })
        .collect::<Vec<_>>();

    let mut literal = String::from("(:prepared-p t :role-span-template ");
    push_hash_table(&mut literal, role_entries);
    literal.push_str(" :box-extent-template ");
    push_hash_table(&mut literal, extent_entries);
    literal.push_str(" :scroll-content-span-template ");
    push_hash_table(&mut literal, scroll_entries);
    literal.push_str(" :scroll-window-p ");
    literal.push_str(if scroll_window_p { "t" } else { "nil" });
    literal.push(')');
    Ok(literal)
}

fn push_fragment_u32(output: &mut Vec<u8>, value: usize, label: &str) -> Result<(), String> {
    output.extend_from_slice(
        &u32::try_from(value)
            .map_err(|_| format!("Native layout fragment has too many {label}"))?
            .to_le_bytes(),
    );
    Ok(())
}

fn encode_fragment_templates(fragments: &[FragmentTemplate]) -> Result<Vec<u8>, String> {
    let mut output = Vec::new();
    for fragment in fragments {
        output.extend_from_slice(&fragment.start.to_le_bytes());
        output.extend_from_slice(&fragment.end.to_le_bytes());
        output.extend_from_slice(&fragment.line.to_le_bytes());
        output.extend_from_slice(&fragment.content_owner.unwrap_or(i64::MIN).to_le_bytes());
        output.extend_from_slice(&fragment.content_index.unwrap_or(i64::MIN).to_le_bytes());
        push_fragment_u32(&mut output, fragment.roles.len(), "roles")?;
        push_fragment_u32(
            &mut output,
            fragment.property_template_ids.len(),
            "property templates",
        )?;
        push_fragment_u32(&mut output, fragment.style_ids.len(), "styles")?;
        output.extend_from_slice(&0_u32.to_le_bytes());
        for (role, region_id) in &fragment.roles {
            let kind = match *role {
                "content" => METADATA_ROLE_CONTENT,
                "content-owner" => METADATA_ROLE_CONTENT_OWNER,
                "pt" => METADATA_ROLE_PADDING_TOP,
                "pb" => METADATA_ROLE_PADDING_BOTTOM,
                "pl" => METADATA_ROLE_PADDING_LEFT,
                "pr" => METADATA_ROLE_PADDING_RIGHT,
                "mt" => METADATA_ROLE_MARGIN_TOP,
                "mb" => METADATA_ROLE_MARGIN_BOTTOM,
                "ml" => METADATA_ROLE_MARGIN_LEFT,
                "mr" => METADATA_ROLE_MARGIN_RIGHT,
                "bt" => METADATA_ROLE_BORDER_TOP,
                "bb" => METADATA_ROLE_BORDER_BOTTOM,
                "bl" => METADATA_ROLE_BORDER_LEFT,
                "br" => METADATA_ROLE_BORDER_RIGHT,
                _ => return Err("Native layout fragment has an unknown role".to_owned()),
            };
            output.push(kind);
            output.extend_from_slice(&region_id.to_le_bytes());
        }
        for template_id in &fragment.property_template_ids {
            output.extend_from_slice(&template_id.to_le_bytes());
        }
        for style_id in &fragment.style_ids {
            output.extend_from_slice(&style_id.to_le_bytes());
        }
    }
    Ok(output)
}

fn root_metadata_payload(
    text: &str,
    spaces: &[TapeSpaceSpan],
    property_spans: &[TapePropertySpan],
    complete: bool,
    root_metadata: bool,
    max_bytes: usize,
) -> Result<Option<RootMetadataPayload>, String> {
    if !complete {
        return Ok(None);
    }
    let records = if root_metadata {
        build_root_metadata_records(text, property_spans)?
    } else {
        property_spans
            .iter()
            .find_map(|span| {
                span.properties.scroll_window.map(|region_id| {
                    vec![TapeMetadataRecord {
                        kind: METADATA_SCROLL_WINDOW,
                        region_id,
                        index: 0,
                        start: span.start,
                        end: span.end,
                    }]
                })
            })
            .unwrap_or_default()
    };
    let mut fragments = build_fragment_templates(text, spaces, property_spans)?;
    let propagated_roles = propagated_fragment_roles(&fragments);
    for (fragment, roles) in fragments.iter_mut().zip(propagated_roles) {
        fragment.roles = roles;
    }
    if records.is_empty() && fragments.is_empty() {
        return Ok(None);
    }
    let literal = metadata_literal_from_records(&records)?;
    let fragment_bytes = encode_fragment_templates(&fragments)?;
    let fragment_count = fragments.len();
    if literal
        .len()
        .checked_add(fragment_bytes.len())
        .is_none_or(|length| length > max_bytes)
    {
        return Err("Native layout tape metadata exceeds its byte limit".to_owned());
    }
    Ok(Some(RootMetadataPayload {
        literal,
        record_count: records.len(),
        fragments,
        fragment_bytes,
        fragment_count,
    }))
}

fn validate_tape_style_ids(properties: &AtomProperties, style_count: u32) -> Result<(), String> {
    if properties
        .style_ids
        .iter()
        .any(|style_id| *style_id >= style_count)
    {
        return Err("Native layout tape has invalid style id".to_owned());
    }
    Ok(())
}

fn flatten_layout_tape(tape: LayoutTape, complete: bool) -> Result<FlatLayoutTape, String> {
    let line_count = tape.lines.len();
    let mut characters = Vec::new();
    for (line_index, line) in tape.lines.into_iter().enumerate() {
        let line_width = tape_width(line.width, "line width")?;
        let expected_break = line_index + 1 < line_count;
        if line.break_after.is_some() != expected_break {
            return Err("Native layout tape break invariant failed".to_owned());
        }
        let mut encoded_width = 0_u64;
        for atom in line.atoms {
            match atom {
                TapeAtom::Text {
                    text,
                    width,
                    properties,
                } => {
                    validate_tape_style_ids(&properties, tape.style_count)?;
                    let width = tape_width(width, "text width")?;
                    if text.is_empty() || text.contains('\n') {
                        return Err("Native layout tape has invalid text atom".to_owned());
                    }
                    let properties = tape_properties(properties, complete);
                    characters.extend(text.chars().map(|value| TapeCharacter {
                        value,
                        pixel_width: None,
                        properties: properties.clone(),
                    }));
                    encoded_width = encoded_width
                        .checked_add(width)
                        .ok_or_else(|| "Native layout tape width overflow".to_owned())?;
                }
                TapeAtom::Space { width, properties } => {
                    validate_tape_style_ids(&properties, tape.style_count)?;
                    let width = tape_width(width, "space width")?;
                    characters.push(TapeCharacter {
                        value: ' ',
                        pixel_width: Some(width),
                        properties: tape_properties(properties, complete),
                    });
                    encoded_width = encoded_width
                        .checked_add(width)
                        .ok_or_else(|| "Native layout tape width overflow".to_owned())?;
                }
            }
        }
        if encoded_width != line_width {
            return Err("Native layout tape line width invariant failed".to_owned());
        }
        if let Some(properties) = line.break_after {
            validate_tape_style_ids(&properties, tape.style_count)?;
            characters.push(TapeCharacter {
                value: '\n',
                pixel_width: None,
                properties: tape_properties(properties, complete),
            });
        }
    }
    Ok(FlatLayoutTape {
        style_count: tape.style_count,
        line_count: count_u32(line_count, "lines")?,
        characters,
    })
}

fn tape_commit_batch(old: &[TapeCharacter], new: &[TapeCharacter]) -> CommitBatch {
    diff_commit_batch(
        0,
        1,
        old,
        new,
        |left, right| left.value == right.value,
        |left, right| left.pixel_width == right.pixel_width && left.properties == right.properties,
    )
    .expect("fixed consecutive adapter revisions")
}

fn tape_character_encoding_parts(
    characters: &[TapeCharacter],
) -> Result<(String, Vec<TapeSpaceSpan>, Vec<TapePropertySpan>), String> {
    let mut text = String::new();
    let mut spaces = Vec::new();
    let mut property_spans = Vec::new();
    for (position, character) in characters.iter().enumerate() {
        let start = u64::try_from(position)
            .map_err(|_| "Native layout tape character count overflow".to_owned())?;
        text.push(character.value);
        if let Some(width) = character.pixel_width {
            spaces.push(TapeSpaceSpan { start, width });
        }
        push_property_span(
            &mut property_spans,
            start,
            start + 1,
            character.properties.clone(),
            true,
        );
    }
    Ok((text, spaces, property_spans))
}

fn encode_patch_replacement_body(
    target: &[TapeCharacter],
    patches: &[TapePatch],
    styles: &[CompiledStyle],
    max_bytes: usize,
) -> Result<Vec<u8>, String> {
    let replacement_count = patches.iter().try_fold(0_usize, |count, patch| {
        count
            .checked_add(patch.new_end - patch.new_start)
            .ok_or_else(|| "Native layout patch replacement count overflow".to_owned())
    })?;
    let mut replacement_characters = Vec::with_capacity(replacement_count);
    for patch in patches {
        replacement_characters.extend_from_slice(&target[patch.new_start..patch.new_end]);
    }
    let (text, spaces, property_spans) = tape_character_encoding_parts(&replacement_characters)?;
    let character_count = u64::try_from(replacement_count)
        .map_err(|_| "Native layout patch replacement count overflow".to_owned())?;
    encode_lisp_literal_inner(
        &text,
        &spaces,
        &property_spans,
        styles,
        character_count,
        max_bytes,
        true,
    )
    .map(String::into_bytes)
}

fn encode_patch_combined_payload(
    replacement: &[u8],
    metadata: Option<&RootMetadataPayload>,
    fragment_style_delta: Option<&FragmentStyleDelta>,
    max_bytes: usize,
) -> Result<Vec<u8>, String> {
    let metadata_literal = metadata.map_or("nil", |payload| payload.literal.as_str());
    let style_delta_literal = fragment_style_delta.map(|delta| {
        let entries = delta
            .iter()
            .map(|(index, style_ids)| {
                let ids = style_ids
                    .iter()
                    .map(u32::to_string)
                    .collect::<Vec<_>>()
                    .join(" ");
                if ids.is_empty() {
                    format!("({index})")
                } else {
                    format!("({index} {ids})")
                }
            })
            .collect::<Vec<_>>()
            .join(" ");
        format!("({entries})")
    });
    let payload_len = 1_usize
        .checked_add(replacement.len())
        .and_then(|size| size.checked_add(1))
        .and_then(|size| size.checked_add(metadata_literal.len()))
        .and_then(|size| {
            style_delta_literal
                .as_ref()
                .map_or(Some(size), |literal| size.checked_add(1 + literal.len()))
        })
        .and_then(|size| size.checked_add(1))
        .ok_or_else(|| "Native layout patch payload size overflow".to_owned())?;
    if payload_len > max_bytes {
        return Err("Native layout patch exceeds its byte limit".to_owned());
    }
    let mut payload = Vec::with_capacity(payload_len);
    payload.push(b'[');
    payload.extend_from_slice(replacement);
    payload.push(b' ');
    payload.extend_from_slice(metadata_literal.as_bytes());
    if let Some(literal) = style_delta_literal {
        payload.push(b' ');
        payload.extend_from_slice(literal.as_bytes());
    }
    payload.push(b']');
    Ok(payload)
}

/// Emacs adapter payload built on the editor-independent core batch.
struct EmacsCommitBatch {
    core: CommitBatch,
    publication_edits: Vec<SpanEdit>,
    combined_payload: Vec<u8>,
    metadata_records: usize,
    fragment_bytes: Vec<u8>,
    fragment_records: usize,
    reuse_fragment_template: bool,
    reuse_ownership_template: bool,
    reuse_mount_projection: bool,
    fragment_style_delta: Option<FragmentStyleDelta>,
}

fn coalesce_publication_edits(edits: &[SpanEdit]) -> Vec<SpanEdit> {
    const MAX_UNCHANGED_GAP: usize = 1;
    let mut result: Vec<SpanEdit> = Vec::with_capacity(edits.len());
    for &edit in edits {
        if let Some(previous) = result.last_mut() {
            let old_gap = edit.old_start.saturating_sub(previous.old_end);
            let new_gap = edit.new_start.saturating_sub(previous.new_end);
            if old_gap == new_gap && old_gap <= MAX_UNCHANGED_GAP {
                previous.old_end = edit.old_end;
                previous.new_end = edit.new_end;
                continue;
            }
        }
        result.push(edit);
    }
    result
}

fn build_emacs_commit_batch(
    old: &FlatLayoutTape,
    target: &FlatLayoutTape,
    compiled_styles: &[CompiledStyle],
    complete: bool,
    root_metadata: bool,
    max_bytes: usize,
    scroll: Option<(&RootScrollPlan, Option<&RootScrollPlan>)>,
) -> Result<EmacsCommitBatch, String> {
    let core = tape_commit_batch(&old.characters, &target.characters);
    let publication_edits = coalesce_publication_edits(&core.semantic_edits);
    let descriptor_bytes = publication_edits
        .len()
        .checked_add(core.coordinate_edits.len())
        .ok_or_else(|| "Native layout patch descriptor count overflow".to_owned())?
        .checked_mul(32)
        .ok_or_else(|| "Native layout patch size overflow".to_owned())?;
    let fixed_body_bytes = 56_usize
        .checked_add(descriptor_bytes)
        .ok_or_else(|| "Native layout patch size overflow".to_owned())?;
    let payload_limit = max_bytes
        .checked_sub(TAPE_HEADER_LEN)
        .and_then(|remaining| remaining.checked_sub(fixed_body_bytes))
        .ok_or_else(|| "Native layout patch exceeds its byte limit".to_owned())?;
    let (target_text, target_spaces, target_property_spans) =
        tape_character_encoding_parts(&target.characters)?;
    let mut metadata_payload = root_metadata_payload(
        &target_text,
        &target_spaces,
        &target_property_spans,
        complete,
        root_metadata,
        payload_limit,
    )?;
    append_scroll_metadata(
        &mut metadata_payload,
        scroll,
        compiled_styles,
        target.style_count,
        payload_limit,
    )?;
    let old_fragments = if metadata_payload.is_some() {
        let (old_text, old_spaces, old_property_spans) =
            tape_character_encoding_parts(&old.characters)?;
        let mut fragments = build_fragment_templates(&old_text, &old_spaces, &old_property_spans)?;
        let roles = propagated_fragment_roles(&fragments);
        for (fragment, roles) in fragments.iter_mut().zip(roles) {
            fragment.roles = roles;
        }
        Some(fragments)
    } else {
        None
    };
    let reuse_fragment_template = old_fragments
        .as_ref()
        .zip(metadata_payload.as_ref())
        .is_some_and(|(old, target)| *old == target.fragments);
    let reuse_ownership_template = old_fragments
        .as_ref()
        .zip(metadata_payload.as_ref())
        .is_some_and(|(old, target)| {
            fragment_ownership_spans(old) == fragment_ownership_spans(&target.fragments)
        });
    let reuse_mount_projection = old_fragments
        .as_ref()
        .zip(metadata_payload.as_ref())
        .is_some_and(|(old, target)| {
            fragment_region_mount_projection(old)
                == fragment_region_mount_projection(&target.fragments)
        });
    let fragment_style_delta = if reuse_fragment_template {
        None
    } else {
        old_fragments
            .as_ref()
            .zip(metadata_payload.as_ref())
            .and_then(|(old, target)| fragment_style_delta(old, &target.fragments))
    };
    let replacements = encode_patch_replacement_body(
        &target.characters,
        &publication_edits,
        compiled_styles,
        payload_limit,
    )?;
    let combined_payload = encode_patch_combined_payload(
        &replacements,
        metadata_payload.as_ref(),
        fragment_style_delta.as_ref(),
        payload_limit,
    )?;
    let metadata_records = metadata_payload
        .as_ref()
        .map_or(0, |payload| payload.record_count);
    let fragment_records = if reuse_fragment_template || fragment_style_delta.is_some() {
        0
    } else {
        metadata_payload
            .as_ref()
            .map_or(0, |payload| payload.fragment_count)
    };
    let fragment_bytes = if reuse_fragment_template || fragment_style_delta.is_some() {
        Vec::new()
    } else {
        metadata_payload.as_mut().map_or_else(Vec::new, |payload| {
            std::mem::take(&mut payload.fragment_bytes)
        })
    };
    Ok(EmacsCommitBatch {
        core,
        publication_edits,
        combined_payload,
        metadata_records,
        fragment_bytes,
        fragment_records,
        reuse_fragment_template,
        reuse_ownership_template,
        reuse_mount_projection,
        fragment_style_delta,
    })
}

pub(crate) fn encode_layout_patch_tape_with_scroll(
    old_tape: LayoutTape,
    target_tape: LayoutTape,
    styles: &[StyleTemplate],
    identity: TapeIdentity,
    root_metadata: bool,
    max_bytes: usize,
    scroll: Option<(&RootScrollPlan, Option<&RootScrollPlan>)>,
) -> Result<Vec<u8>, String> {
    let old = flatten_layout_tape(old_tape, identity.complete)?;
    let target = flatten_layout_tape(target_tape, identity.complete)?;
    if old.style_count > target.style_count || target.style_count as usize != styles.len() {
        return Err("Native layout patch style table mismatch".to_owned());
    }
    let compiled_styles = styles
        .iter()
        .map(StyleTemplate::compile)
        .collect::<Result<Vec<_>, _>>()?;
    let batch = build_emacs_commit_batch(
        &old,
        &target,
        &compiled_styles,
        identity.complete,
        root_metadata,
        max_bytes,
        scroll.filter(|_| identity.complete),
    )?;
    let patch_count = count_u32(batch.publication_edits.len(), "patches")?;
    let coordinate_patch_count =
        count_u32(batch.core.coordinate_edits.len(), "coordinate patches")?;
    let target_character_count = u64::try_from(target.characters.len())
        .map_err(|_| "Native layout patch character count overflow".to_owned())?;
    let base_character_count = u64::try_from(old.characters.len())
        .map_err(|_| "Native layout patch base character count overflow".to_owned())?;
    let mut writer = TapeWriter::new(max_bytes)?;
    writer.push_u64(base_character_count)?;
    writer.push_u32(patch_count)?;
    // Publication coalesces only one-character equal-coordinate gaps.  The
    // pure core retains its exact minimal semantic edits, while the compact
    // target role sidecar lets Emacs swap exact runtime indexes without
    // synchronously rescanning the page or rebuilding thousands of markers.
    writer.push_u32(
        u32::from(batch.reuse_fragment_template)
            | (u32::from(batch.reuse_ownership_template) << 1)
            | (u32::from(batch.reuse_mount_projection) << 2)
            | (u32::from(batch.fragment_style_delta.is_some()) << 3),
    )?;
    writer.push_u64(
        u64::try_from(batch.metadata_records)
            .map_err(|_| "Native layout patch has too many metadata records".to_owned())?,
    )?;
    writer.push_u64(
        u64::try_from(batch.combined_payload.len())
            .map_err(|_| "Native layout patch body is too large".to_owned())?,
    )?;
    writer.push_u64(
        u64::try_from(batch.fragment_bytes.len())
            .map_err(|_| "Native layout fragment tape is too large".to_owned())?,
    )?;
    writer.push_u64(
        u64::try_from(batch.fragment_records)
            .map_err(|_| "Native layout fragment tape has too many records".to_owned())?,
    )?;
    writer.push_u32(coordinate_patch_count)?;
    writer.push_u32(0)?;
    for patch in &batch.publication_edits {
        writer.push_u64(patch.old_start as u64)?;
        writer.push_u64(patch.old_end as u64)?;
        writer.push_u64(patch.new_start as u64)?;
        writer.push_u64(patch.new_end as u64)?;
    }
    for patch in &batch.core.coordinate_edits {
        writer.push_u64(patch.old_start as u64)?;
        writer.push_u64(patch.old_end as u64)?;
        writer.push_u64(patch.new_start as u64)?;
        writer.push_u64(patch.new_end as u64)?;
    }
    writer.push_bytes(&batch.combined_payload)?;
    writer.push_bytes(&batch.fragment_bytes)?;
    Ok(writer.finish_header(
        identity,
        true,
        true,
        target.style_count,
        target.line_count,
        target_character_count,
    ))
}

pub(crate) fn encode_layout_tape_with_scroll(
    tape: LayoutTape,
    styles: &[StyleTemplate],
    identity: TapeIdentity,
    root_metadata: bool,
    max_bytes: usize,
    scroll: Option<&RootScrollPlan>,
) -> Result<Vec<u8>, String> {
    let line_count = count_u32(tape.lines.len(), "lines")?;
    if tape.style_count as usize != styles.len() {
        return Err("Native layout tape style table mismatch".to_owned());
    }
    let compiled_styles = styles
        .iter()
        .map(StyleTemplate::compile)
        .collect::<Result<Vec<_>, _>>()?;
    let mut text = String::new();
    let mut line_widths = Vec::with_capacity(tape.lines.len());
    let mut spaces = Vec::new();
    let mut property_spans = Vec::new();
    let mut character_count = 0_u64;

    for (line_index, line) in tape.lines.into_iter().enumerate() {
        let line_width = tape_width(line.width, "line width")?;
        line_widths.push(line_width);
        let expected_break = line_index + 1 < line_count as usize;
        if line.break_after.is_some() != expected_break {
            return Err("Native layout tape break invariant failed".to_owned());
        }
        let mut encoded_width = 0_u64;
        for atom in line.atoms {
            match atom {
                TapeAtom::Text {
                    text: atom_text,
                    width,
                    properties,
                } => {
                    let width = tape_width(width, "text width")?;
                    if atom_text.is_empty() || atom_text.contains('\n') {
                        return Err("Native layout tape has invalid text atom".to_owned());
                    }
                    let start = character_count;
                    text.push_str(&atom_text);
                    character_count = character_count
                        .checked_add(u64::try_from(atom_text.chars().count()).map_err(|_| {
                            "Native layout tape character count overflow".to_owned()
                        })?)
                        .ok_or_else(|| "Native layout tape character overflow".to_owned())?;
                    push_property_span(
                        &mut property_spans,
                        start,
                        character_count,
                        properties,
                        identity.complete,
                    );
                    encoded_width = encoded_width
                        .checked_add(width)
                        .ok_or_else(|| "Native layout tape width overflow".to_owned())?;
                }
                TapeAtom::Space { width, properties } => {
                    let width = tape_width(width, "space width")?;
                    let start = character_count;
                    text.push(' ');
                    spaces.push(TapeSpaceSpan { start, width });
                    character_count = character_count
                        .checked_add(1)
                        .ok_or_else(|| "Native layout tape character overflow".to_owned())?;
                    push_property_span(
                        &mut property_spans,
                        start,
                        character_count,
                        properties,
                        identity.complete,
                    );
                    encoded_width = encoded_width
                        .checked_add(width)
                        .ok_or_else(|| "Native layout tape width overflow".to_owned())?;
                }
            }
        }
        if encoded_width != line_width {
            return Err("Native layout tape line width invariant failed".to_owned());
        }
        if let Some(properties) = line.break_after {
            let start = character_count;
            text.push('\n');
            character_count = character_count
                .checked_add(1)
                .ok_or_else(|| "Native layout tape character overflow".to_owned())?;
            push_property_span(
                &mut property_spans,
                start,
                character_count,
                properties,
                identity.complete,
            );
        }
    }

    let fixed_body_bytes = 40_usize
        .checked_add(
            (line_count as usize)
                .checked_mul(8)
                .ok_or_else(|| "Native layout tape size overflow".to_owned())?,
        )
        .ok_or_else(|| "Native layout tape size overflow".to_owned())?;
    let metadata_limit = max_bytes
        .checked_sub(TAPE_HEADER_LEN)
        .and_then(|remaining| remaining.checked_sub(fixed_body_bytes))
        .ok_or_else(|| "Native layout tape exceeds its byte limit".to_owned())?;
    let mut metadata_payload = root_metadata_payload(
        &text,
        &spaces,
        &property_spans,
        identity.complete,
        root_metadata,
        metadata_limit,
    )?;
    append_scroll_metadata(
        &mut metadata_payload,
        scroll
            .filter(|_| identity.complete)
            .map(|scroll| (scroll, None)),
        &compiled_styles,
        tape.style_count,
        metadata_limit,
    )?;
    let metadata_bytes = metadata_payload
        .as_ref()
        .map_or(0, |payload| payload.literal.len());
    let metadata_records = metadata_payload
        .as_ref()
        .map_or(0, |payload| payload.record_count);
    let fragment_bytes = metadata_payload
        .as_ref()
        .map_or(0, |payload| payload.fragment_bytes.len());
    let fragment_records = metadata_payload
        .as_ref()
        .map_or(0, |payload| payload.fragment_count);
    let literal_limit = max_bytes
        .checked_sub(TAPE_HEADER_LEN)
        .and_then(|remaining| remaining.checked_sub(fixed_body_bytes))
        .and_then(|remaining| remaining.checked_sub(metadata_bytes))
        .and_then(|remaining| remaining.checked_sub(fragment_bytes))
        .ok_or_else(|| "Native layout tape exceeds its byte limit".to_owned())?;
    let literal = encode_lisp_literal(
        &text,
        &spaces,
        &property_spans,
        &compiled_styles,
        character_count,
        literal_limit,
    )?;

    let mut writer = TapeWriter::new(max_bytes)?;
    writer.push_u64(
        u64::try_from(literal.len())
            .map_err(|_| "Native layout tape literal is too large".to_owned())?,
    )?;
    writer.push_u32(line_count)?;
    writer.push_u32(
        u32::try_from(metadata_bytes)
            .map_err(|_| "Native layout tape metadata is too large".to_owned())?,
    )?;
    writer.push_u64(
        u64::try_from(metadata_records)
            .map_err(|_| "Native layout tape has too many metadata records".to_owned())?,
    )?;
    writer.push_u64(
        u64::try_from(fragment_bytes)
            .map_err(|_| "Native layout fragment tape is too large".to_owned())?,
    )?;
    writer.push_u64(
        u64::try_from(fragment_records)
            .map_err(|_| "Native layout fragment tape has too many records".to_owned())?,
    )?;
    for width in line_widths {
        writer.push_u64(width)?;
    }
    writer.push_bytes(literal.as_bytes())?;
    if let Some(payload) = metadata_payload {
        writer.push_bytes(payload.literal.as_bytes())?;
        writer.push_bytes(&payload.fragment_bytes)?;
    }

    Ok(writer.finish_header(
        identity,
        true,
        false,
        tape.style_count,
        line_count,
        character_count,
    ))
}

pub fn encode_error_tape(identity: TapeIdentity, message: &str, max_bytes: usize) -> Vec<u8> {
    let limit = max_bytes.max(MIN_TAPE_BYTES);
    let mut writer = TapeWriter::new(limit).expect("minimum tape limit");
    let capacity = limit - TAPE_HEADER_LEN - 4;
    let mut length = message.len().min(capacity);
    while !message.is_char_boundary(length) {
        length -= 1;
    }
    let message = &message.as_bytes()[..length];
    writer
        .push_u32(u32::try_from(message.len()).unwrap_or(u32::MAX))
        .expect("bounded error length");
    writer.push_bytes(message).expect("bounded error body");
    writer.finish_header(identity, false, false, 0, 0, 0)
}

impl LayoutDocument {
    pub(crate) fn retained_root_p(&self) -> bool {
        self.root.node_id().is_some()
    }

    pub(crate) fn input_node_count(&self) -> u64 {
        fn count(node: &LayoutNode) -> u64 {
            let mut total = 1;
            visit_layout_children(node, |child| total += count(child));
            total
        }
        count(&self.root)
    }
    fn validate_metrics(&self) -> Result<(usize, usize), String> {
        if self.version != LAYOUT_VERSION {
            return Err(format!(
                "Unsupported native layout IR version {}",
                self.version
            ));
        }
        if self.space_width <= 0 {
            return Err("Native layout space width must be positive".to_owned());
        }
        if self.styles.len() != self.style_count as usize {
            return Err("Native layout style table length mismatch".to_owned());
        }
        if self.styles.len() > MAX_TAPE_PROPERTY_ENTRIES {
            return Err("Native layout style table exceeds its entry limit".to_owned());
        }
        if self.property_template_count > MAX_PROPERTY_TEMPLATE_COUNT {
            return Err("Native layout property template table exceeds its entry limit".to_owned());
        }
        for style in &self.styles {
            style.face.validate()?;
        }
        let mut nodes = 0;
        let mut work_units = 0;
        validate_node(
            &self.root,
            0,
            &mut nodes,
            &mut work_units,
            self.style_count,
            self.property_template_count,
        )?;
        Ok((nodes, work_units))
    }

    pub fn validate(&self) -> Result<(), String> {
        self.validate_metrics().map(|_| ())
    }

    pub fn validate_context(&self, context: LayoutContext) -> Result<(), String> {
        let mut work_units = 0;
        add_context_work(&self.root, context, &mut work_units)
    }

    pub(crate) fn layout_tape(
        &self,
        context: LayoutContext,
        root_width_override: Option<i64>,
    ) -> Result<LayoutTape, String> {
        if root_width_override.is_some() && !matches!(self.root, LayoutNode::Box { .. }) {
            Err("Native root width override requires a box root".to_owned())
        } else {
            render_node_with_override(
                &self.root,
                None,
                context,
                false,
                root_width_override.map(|declared_width| BoxOverride {
                    declared_width: Some(declared_width),
                    ..BoxOverride::default()
                }),
            )
            .map(|rendered| rendered.into_tape(self.style_count))
        }
    }
}

impl RetainedDocument {
    pub(crate) fn validate_context(&self, context: LayoutContext) -> Result<(), String> {
        // Bootstrap establishes the root/reference invariant and deltas cannot
        // change topology. The full traversal adds the same nonnegative amount
        // for every occurrence, stopping at the work limit before a later add
        // could overflow. Division preserves that error without multiplying.
        if self.context_viewport_heights == 0 {
            return Ok(());
        }
        let height = usize::try_from(context.viewport_height).unwrap_or(usize::MAX);
        if height > MAX_LAYOUT_WORK_UNITS / self.context_viewport_heights {
            Err("Native layout exceeds the work-unit limit".to_owned())
        } else {
            Ok(())
        }
    }

    pub(crate) fn layout_tape(
        &self,
        context: LayoutContext,
        root_width_override: Option<i64>,
    ) -> Result<LayoutTape, String> {
        let root = self
            .effective_node(self.root_id)
            .ok_or_else(|| "Native retained document lost its root".to_owned())?;
        RESOLVER_LOOKUP_COUNT.with(|count| count.set(count.get().saturating_add(1)));
        if root_width_override.is_some() && !matches!(root, LayoutNode::Box { .. }) {
            Err("Native root width override requires a box root".to_owned())
        } else {
            render_node_with_override(
                root,
                Some(self),
                context,
                false,
                root_width_override.map(|declared_width| BoxOverride {
                    declared_width: Some(declared_width),
                    ..BoxOverride::default()
                }),
            )
            .map(|rendered| rendered.into_tape(self.style_count))
        }
    }
}

fn validate_nonnegative(name: &str, value: i64) -> Result<(), String> {
    if value < 0 {
        Err(format!("Native layout {name} cannot be negative"))
    } else {
        Ok(())
    }
}

fn validate_dimension(name: &str, value: i64) -> Result<(), String> {
    validate_nonnegative(name, value)?;
    if value > MAX_LAYOUT_DIMENSION {
        Err(format!("Native layout {name} exceeds the dimension limit"))
    } else {
        Ok(())
    }
}

fn add_work_units(work_units: &mut usize, amount: usize) -> Result<(), String> {
    *work_units = work_units
        .checked_add(amount)
        .ok_or_else(|| "Native layout work estimate overflowed".to_owned())?;
    if *work_units > MAX_LAYOUT_WORK_UNITS {
        Err("Native layout exceeds the work-unit limit".to_owned())
    } else {
        Ok(())
    }
}

fn add_vertical_size_work(size: &Size, work_units: &mut usize) -> Result<(), String> {
    match size {
        Size::Lines { value } => {
            add_work_units(work_units, usize::try_from(*value).unwrap_or(usize::MAX))
        }
        Size::FitContent { limit: Some(limit) } => add_vertical_size_work(limit, work_units),
        Size::Add { values } | Size::Subtract { values } => {
            for value in &values.0 {
                add_vertical_size_work(value, work_units)?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn visit_context_size_occurrences(
    size: &Size,
    visit: &mut impl FnMut() -> Result<(), String>,
) -> Result<(), String> {
    // Validation work adds every operand, including subtraction operands.
    match size {
        Size::ViewportHeight => visit(),
        Size::FitContent { limit: Some(limit) } => visit_context_size_occurrences(limit, visit),
        Size::Add { values } | Size::Subtract { values } => {
            for value in &values.0 {
                visit_context_size_occurrences(value, visit)?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn add_context_size_work(
    size: &Size,
    context: LayoutContext,
    work_units: &mut usize,
) -> Result<(), String> {
    visit_context_size_occurrences(size, &mut || {
        add_work_units(
            work_units,
            usize::try_from(context.viewport_height).unwrap_or(usize::MAX),
        )
    })
}

fn visit_context_height_fields(
    node: &LayoutNode,
    mut visit: impl FnMut(&'static str, &Size) -> Result<(), String>,
) -> Result<(), String> {
    match node {
        LayoutNode::Box {
            height,
            min_height,
            max_height,
            ..
        } => {
            for (name, size) in [
                ("height", height),
                ("min-height", min_height),
                ("max-height", max_height),
            ] {
                visit(name, size)?;
            }
        }
        LayoutNode::Flex { height, .. } => visit("height", height)?,
        _ => {}
    }
    Ok(())
}

fn add_context_work(
    node: &LayoutNode,
    context: LayoutContext,
    work_units: &mut usize,
) -> Result<(), String> {
    visit_context_height_fields(node, |_, size| {
        add_context_size_work(size, context, work_units)
    })?;
    match node {
        LayoutNode::NodeRef { .. } => {
            return Err("Native full layout cannot contain a node reference".to_owned());
        }
        LayoutNode::Text { .. } => {}
        LayoutNode::Box { child, .. } => {
            if let Some(child) = child {
                add_context_work(child, context, work_units)?;
            }
        }
        LayoutNode::Row { children, .. } | LayoutNode::Column { children, .. } => {
            for child in children.iter() {
                add_context_work(child, context, work_units)?;
            }
        }
        LayoutNode::Flex { items, .. } => {
            for item in items.iter() {
                add_context_work(&item.node, context, work_units)?;
            }
        }
    }
    Ok(())
}

fn validate_size_at_depth(name: &str, size: &Size, depth: usize) -> Result<(), String> {
    if depth > MAX_LAYOUT_DEPTH {
        return Err(format!(
            "Native layout {name} expression exceeds the depth limit"
        ));
    }
    match size {
        Size::Pixels { value } | Size::Lines { value } => validate_dimension(name, *value),
        Size::FitContent { limit: Some(limit) } => validate_size_at_depth(name, limit, depth + 1),
        Size::Add { values } | Size::Subtract { values } => {
            if values.0.is_empty() {
                return Err(format!("Native layout {name} expression cannot be empty"));
            }
            for value in &values.0 {
                validate_size_at_depth(name, value, depth + 1)?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn validate_size(name: &str, size: &Size) -> Result<(), String> {
    validate_size_at_depth(name, size, 0)
}

fn validate_node(
    node: &LayoutNode,
    depth: usize,
    nodes: &mut usize,
    work_units: &mut usize,
    style_count: u32,
    property_template_count: u32,
) -> Result<(), String> {
    if depth > MAX_LAYOUT_DEPTH {
        return Err("Native layout tree exceeds the depth limit".to_owned());
    }
    *nodes += 1;
    if *nodes > MAX_LAYOUT_NODES {
        return Err("Native layout tree exceeds the node limit".to_owned());
    }
    add_work_units(work_units, 1)?;
    match node {
        LayoutNode::NodeRef { .. } => {
            return Err("Native full layout cannot contain a node reference".to_owned());
        }
        LayoutNode::Text {
            region_id,
            content,
            typography_style,
            foreground_style,
            surface_template_id,
            ..
        } => {
            if *region_id <= 0 {
                return Err("Native layout Text region id must be positive".to_owned());
            }
            for style_id in [typography_style, foreground_style].into_iter().flatten() {
                if *style_id >= style_count {
                    return Err("Native layout Text style id exceeds the style table".to_owned());
                }
            }
            if let Some(template_id) = surface_template_id {
                if *template_id >= property_template_count {
                    return Err(
                        "Native layout Text property template id exceeds the property template table"
                            .to_owned(),
                    );
                }
            }
            add_work_units(work_units, content.lines.len())?;
            for line in &content.lines {
                add_work_units(work_units, line.clusters.len())?;
                for cluster in &line.clusters {
                    if cluster.text.is_empty() {
                        return Err("Native layout Text cluster cannot be empty".to_owned());
                    }
                    validate_dimension("Text cluster width", cluster.width)?;
                    if let Some(template_id) = cluster.source_template_id {
                        if template_id >= property_template_count {
                            return Err(
                                "Native layout Text property template id exceeds the property template table"
                                    .to_owned(),
                            );
                        }
                    }
                }
            }
        }
        LayoutNode::Box {
            region_id,
            content,
            content_region_id,
            content_typography_style,
            content_foreground_style,
            content_surface_template_id,
            child,
            content_width_exact: _,
            content_min_width,
            width,
            min_width,
            max_width,
            height,
            min_height,
            max_height,
            padding_left,
            padding_right,
            padding_top,
            padding_bottom,
            margin_left,
            margin_right,
            margin_top,
            margin_bottom,
            border_left,
            border_right,
            typography_style,
            foreground_style,
            background_style,
            border_left_style,
            border_right_style,
            border_top_style,
            border_bottom_style,
            surface_template_id,
            scroll_offset,
            ..
        } => {
            if *region_id <= 0 {
                return Err("Native layout region id must be positive".to_owned());
            }
            if let Some(content_min_width) = content_min_width {
                validate_dimension("content-min-width", *content_min_width)?;
            }
            if content.is_some() == child.is_some() {
                return Err(
                    "Native layout box must contain exactly one text or child value".to_owned(),
                );
            }
            if content_region_id.is_some() && content.is_none() {
                return Err("Native layout box content identity requires measured text".to_owned());
            }
            if let Some(content_region_id) = content_region_id {
                if *content_region_id <= 0 {
                    return Err("Native layout box content region id must be positive".to_owned());
                }
            }
            for (name, size) in [
                ("width", width),
                ("min-width", min_width),
                ("max-width", max_width),
                ("height", height),
                ("min-height", min_height),
                ("max-height", max_height),
            ] {
                validate_size(name, size)?;
            }
            for size in [height, min_height, max_height] {
                add_vertical_size_work(size, work_units)?;
            }
            for (name, value) in [
                ("padding-left", *padding_left),
                ("padding-right", *padding_right),
                ("padding-top", *padding_top),
                ("padding-bottom", *padding_bottom),
                ("margin-left", *margin_left),
                ("margin-right", *margin_right),
                ("margin-top", *margin_top),
                ("margin-bottom", *margin_bottom),
                ("border-left", *border_left),
                ("border-right", *border_right),
                ("scroll-offset", *scroll_offset),
            ] {
                validate_dimension(name, value)?;
            }
            add_work_units(
                work_units,
                usize::try_from(padding_top + padding_bottom + margin_top + margin_bottom)
                    .unwrap_or(usize::MAX),
            )?;
            for style_id in [
                content_typography_style,
                content_foreground_style,
                typography_style,
                foreground_style,
                background_style,
                border_left_style,
                border_right_style,
                border_top_style,
                border_bottom_style,
            ]
            .into_iter()
            .flatten()
            {
                if *style_id >= style_count {
                    return Err("Native layout style id exceeds the style table".to_owned());
                }
            }
            if let Some(template_id) = surface_template_id {
                if *template_id >= property_template_count {
                    return Err(
                        "Native layout property template id exceeds the property template table"
                            .to_owned(),
                    );
                }
            }
            if let Some(template_id) = content_surface_template_id {
                if *template_id >= property_template_count {
                    return Err(
                        "Native layout box content property template id exceeds the property template table"
                            .to_owned(),
                    );
                }
            }
            if let Some(text) = content {
                add_work_units(work_units, text.lines.len())?;
                for line in &text.lines {
                    add_work_units(work_units, line.clusters.len())?;
                    for cluster in &line.clusters {
                        if cluster.text.is_empty() {
                            return Err("Native layout cluster text cannot be empty".to_owned());
                        }
                        validate_dimension("cluster width", cluster.width)?;
                        if let Some(template_id) = cluster.source_template_id {
                            if template_id >= property_template_count {
                                return Err(
                                    "Native layout property template id exceeds the property template table"
                                        .to_owned(),
                                );
                            }
                        }
                    }
                }
            }
            if let Some(child) = child {
                validate_node(
                    child,
                    depth + 1,
                    nodes,
                    work_units,
                    style_count,
                    property_template_count,
                )?;
            }
        }
        LayoutNode::Row { children, .. } | LayoutNode::Column { children, .. } => {
            if children.is_empty() {
                return Err("Native layout container must contain a child".to_owned());
            }
            for child in children.iter() {
                validate_node(
                    child,
                    depth + 1,
                    nodes,
                    work_units,
                    style_count,
                    property_template_count,
                )?;
            }
        }
        LayoutNode::Flex {
            width,
            height,
            row_gap,
            column_gap,
            items,
            ..
        } => {
            validate_size("flex width", width)?;
            validate_size("flex height", height)?;
            add_vertical_size_work(height, work_units)?;
            validate_dimension("flex row gap", *row_gap)?;
            validate_dimension("flex column gap", *column_gap)?;
            if items.is_empty() {
                return Err("Native flex container must contain an item".to_owned());
            }
            add_work_units(
                work_units,
                usize::try_from(*row_gap)
                    .unwrap_or(usize::MAX)
                    .saturating_mul(items.len()),
            )?;
            for item in items.iter() {
                if !item.grow.is_finite()
                    || item.grow < 0.0
                    || !item.shrink.is_finite()
                    || item.shrink < 0.0
                {
                    return Err("Native flex factors must be finite and nonnegative".to_owned());
                }
                validate_size("flex basis", &item.basis)?;
                validate_node(
                    &item.node,
                    depth + 1,
                    nodes,
                    work_units,
                    style_count,
                    property_template_count,
                )?;
            }
        }
    }
    Ok(())
}

fn box_sizing_content_width(
    value: i64,
    sizing: BoxSizing,
    padding_left: i64,
    padding_right: i64,
    border_left: i64,
    border_right: i64,
) -> i64 {
    if sizing == BoxSizing::BorderBox {
        (value - padding_left - padding_right - border_left - border_right).max(0)
    } else {
        value
    }
}

fn box_sizing_content_height(
    value: i64,
    sizing: BoxSizing,
    padding_top: i64,
    padding_bottom: i64,
) -> i64 {
    if sizing == BoxSizing::BorderBox {
        (value - padding_top - padding_bottom).max(0)
    } else {
        value
    }
}

#[allow(clippy::too_many_arguments)]
fn resolve_width(
    size: &Size,
    fallback: Option<i64>,
    context: LayoutContext,
    sizing: BoxSizing,
    padding_left: i64,
    padding_right: i64,
    border_left: i64,
    border_right: i64,
    stretch: Option<i64>,
    min_content: i64,
    max_content: i64,
) -> Option<i64> {
    let convert = |value| {
        box_sizing_content_width(
            value,
            sizing,
            padding_left,
            padding_right,
            border_left,
            border_right,
        )
    };
    match size {
        Size::Auto => fallback,
        Size::Content => Some(max_content),
        Size::None => None,
        Size::Pixels { value } => Some(convert(*value)),
        Size::Viewport => context
            .viewport_width_known
            .then(|| convert(context.viewport_width))
            .or(fallback),
        Size::MinContent => Some(min_content),
        Size::MaxContent => Some(max_content),
        Size::FitContent { limit } => {
            let available = limit
                .as_deref()
                .and_then(|limit| {
                    resolve_width(
                        limit,
                        None,
                        context,
                        sizing,
                        padding_left,
                        padding_right,
                        border_left,
                        border_right,
                        stretch,
                        min_content,
                        max_content,
                    )
                })
                .or(stretch)
                .unwrap_or(max_content);
            Some(min_content.max(max_content.min(available)))
        }
        Size::Stretch | Size::Contain => stretch.or(fallback),
        Size::Lines { .. } | Size::ViewportHeight | Size::Add { .. } | Size::Subtract { .. } => {
            fallback
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn resolve_definite_width(
    size: &Size,
    context: LayoutContext,
    sizing: BoxSizing,
    padding_left: i64,
    padding_right: i64,
    border_left: i64,
    border_right: i64,
    stretch: Option<i64>,
) -> Option<i64> {
    let convert = |value| {
        box_sizing_content_width(
            value,
            sizing,
            padding_left,
            padding_right,
            border_left,
            border_right,
        )
    };
    match size {
        Size::Pixels { value } => Some(convert(*value)),
        Size::Viewport => context
            .viewport_width_known
            .then(|| convert(context.viewport_width)),
        Size::Stretch | Size::Contain | Size::FitContent { limit: None } => stretch,
        Size::FitContent { limit: Some(limit) } => resolve_definite_width(
            limit,
            context,
            sizing,
            padding_left,
            padding_right,
            border_left,
            border_right,
            stretch,
        ),
        _ => None,
    }
}

#[allow(clippy::too_many_arguments)]
fn resolve_child_viewport_width(
    width: &Size,
    min_width: &Size,
    max_width: &Size,
    context: LayoutContext,
    sizing: BoxSizing,
    padding_left: i64,
    padding_right: i64,
    border_left: i64,
    border_right: i64,
    stretch: Option<i64>,
) -> Option<i64> {
    let definite = |size| {
        resolve_definite_width(
            size,
            context,
            sizing,
            padding_left,
            padding_right,
            border_left,
            border_right,
            stretch,
        )
    };
    let minimum = definite(min_width).unwrap_or(0);
    let maximum = definite(max_width);
    let auto_stretch = if matches!(width, Size::Auto) {
        (!context.inline_auto_width_intrinsic)
            .then_some(stretch)
            .flatten()
    } else {
        None
    };
    let preferred = definite(width).or(auto_stretch).or(maximum);
    preferred.map(|preferred| minimum.max(preferred.max(0).min(maximum.unwrap_or(i64::MAX))))
}

fn resolve_raw_height(size: &Size, context: LayoutContext) -> Option<i64> {
    fn resolve(size: &Size, context: LayoutContext) -> Option<i128> {
        match size {
            Size::Lines { value } | Size::Pixels { value } => Some(i128::from(*value)),
            Size::ViewportHeight => {
                (context.viewport_height > 0).then_some(i128::from(context.viewport_height))
            }
            Size::Add { values } => values.0.iter().try_fold(0_i128, |total, value| {
                resolve(value, context).and_then(|value| total.checked_add(value))
            }),
            Size::Subtract { values } => {
                let mut values = values.0.iter();
                let first = resolve(values.next()?, context)?;
                if values.len() == 0 {
                    first.checked_neg()
                } else {
                    values.try_fold(first, |total, value| {
                        resolve(value, context).and_then(|value| total.checked_sub(value))
                    })
                }
            }
            _ => None,
        }
    }

    resolve(size, context).map(|value| value.clamp(i64::MIN as i128, i64::MAX as i128) as i64)
}

fn resolve_height(
    size: &Size,
    fallback: Option<i64>,
    context: LayoutContext,
    sizing: BoxSizing,
    padding_top: i64,
    padding_bottom: i64,
) -> Option<i64> {
    match size {
        Size::Auto | Size::None | Size::Content => fallback,
        Size::Lines { .. }
        | Size::Pixels { .. }
        | Size::ViewportHeight
        | Size::Add { .. }
        | Size::Subtract { .. } => resolve_raw_height(size, context).map(|value| {
            box_sizing_content_height(value.max(0), sizing, padding_top, padding_bottom)
        }),
        _ => fallback,
    }
}

#[allow(clippy::too_many_arguments)]
fn resolve_definite_box_content_width(
    width: &Size,
    min_width: &Size,
    max_width: &Size,
    context: LayoutContext,
    sizing: BoxSizing,
    padding_left: i64,
    padding_right: i64,
    border_left: i64,
    border_right: i64,
    stretch: Option<i64>,
    override_width: Option<i64>,
) -> Option<i64> {
    let intrinsic_width = |size: &Size| {
        matches!(
            size,
            Size::Content | Size::MinContent | Size::MaxContent | Size::Auto
        )
    };
    if intrinsic_width(min_width) || intrinsic_width(max_width) {
        return None;
    }
    let definite = |size| {
        resolve_definite_width(
            size,
            context,
            sizing,
            padding_left,
            padding_right,
            border_left,
            border_right,
            stretch,
        )
    };
    let minimum = definite(min_width).unwrap_or(0);
    let maximum = definite(max_width);
    let preferred = override_width
        .or_else(|| definite(width))
        .or_else(|| {
            (matches!(width, Size::Auto) && !context.inline_auto_width_intrinsic)
                .then_some(stretch)
                .flatten()
        })
        .or(maximum);
    preferred.map(|preferred| minimum.max(preferred.max(0).min(maximum.unwrap_or(i64::MAX))))
}

#[allow(clippy::too_many_arguments)]
fn resolve_definite_box_content_height(
    height: &Size,
    min_height: &Size,
    max_height: &Size,
    context: LayoutContext,
    sizing: BoxSizing,
    padding_top: i64,
    padding_bottom: i64,
    override_height: Option<i64>,
) -> Option<i64> {
    let minimum = resolve_height(
        min_height,
        Some(0),
        context,
        sizing,
        padding_top,
        padding_bottom,
    )
    .unwrap_or(0);
    let maximum = resolve_height(
        max_height,
        None,
        context,
        sizing,
        padding_top,
        padding_bottom,
    )
    .unwrap_or(i64::MAX);
    let preferred = override_height
        .or_else(|| resolve_height(height, None, context, sizing, padding_top, padding_bottom))?;
    Some(minimum.max(0).max(preferred.max(0).min(maximum)))
}

fn measured_max_width(text: &MeasuredText) -> i64 {
    text.lines
        .iter()
        .map(|line| line.clusters.iter().map(|cluster| cluster.width).sum())
        .max()
        .unwrap_or(0)
}

fn measured_min_width(text: &MeasuredText, wrap_mode: WrapMode) -> i64 {
    if wrap_mode == WrapMode::None {
        return measured_max_width(text);
    }
    text.lines
        .iter()
        .map(|line| {
            let mut maximum = 0;
            let mut run = 0;
            for cluster in &line.clusters {
                if cluster.space {
                    maximum = maximum.max(run);
                    run = 0;
                } else if cluster.cjk {
                    maximum = maximum.max(run).max(cluster.width);
                    run = 0;
                } else {
                    run += cluster.width;
                }
            }
            maximum.max(run)
        })
        .max()
        .unwrap_or(0)
}

fn wrap_line(clusters: &[MeasuredCluster], max_width: i64, mode: WrapMode) -> Vec<Line> {
    if clusters.is_empty() {
        return vec![Line::blank(0)];
    }
    let total: i64 = clusters.iter().map(|cluster| cluster.width).sum();
    if mode == WrapMode::None || total <= max_width {
        return vec![Line::from_clusters(clusters)];
    }

    let count = clusters.len();
    let mut ranges = Vec::new();
    let mut line_start = 0;
    let mut current_width = 0;
    let mut index = 0;
    let flush_before = |end: usize,
                        ranges: &mut Vec<(usize, usize)>,
                        line_start: &mut usize,
                        current_width: &mut i64| {
        if *line_start < end {
            ranges.push((*line_start, end));
        }
        *line_start = end;
        *current_width = 0;
    };

    while index < count {
        let cluster_width = clusters[index].width;
        if clusters[index].cjk {
            if current_width + cluster_width > max_width {
                flush_before(index, &mut ranges, &mut line_start, &mut current_width);
            }
            current_width += cluster_width;
            index += 1;
        } else if mode == WrapMode::Word {
            let mut word_end = index;
            let mut word_width = 0;
            while word_end < count && !clusters[word_end].space && !clusters[word_end].cjk {
                word_width += clusters[word_end].width;
                word_end += 1;
            }
            if word_width > max_width {
                while index < word_end {
                    let width = clusters[index].width;
                    if current_width + width > max_width {
                        flush_before(index, &mut ranges, &mut line_start, &mut current_width);
                    }
                    current_width += width;
                    index += 1;
                }
            } else if current_width + word_width <= max_width {
                current_width += word_width;
                index = word_end;
            } else {
                flush_before(index, &mut ranges, &mut line_start, &mut current_width);
                current_width = word_width;
                index = word_end;
            }
            if index < count && clusters[index].space {
                let width = clusters[index].width;
                if current_width + width <= max_width {
                    current_width += width;
                    index += 1;
                } else {
                    flush_before(index, &mut ranges, &mut line_start, &mut current_width);
                    index += 1;
                    line_start = index;
                }
            }
        } else {
            if current_width + cluster_width > max_width {
                flush_before(index, &mut ranges, &mut line_start, &mut current_width);
            }
            current_width += cluster_width;
            index += 1;
        }
    }
    if line_start < count {
        ranges.push((line_start, count));
    }
    ranges
        .into_iter()
        .map(|(start, end)| Line::from_clusters(&clusters[start..end]))
        .collect()
}

fn measured_lines(text: &MeasuredText, width: i64, mode: WrapMode) -> Vec<Line> {
    text.lines
        .iter()
        .flat_map(|line| wrap_line(&line.clusters, width, mode))
        .collect()
}

fn wrap_rendered_line(line: &Line, max_width: i64, mode: WrapMode) -> Vec<Line> {
    if line.atoms.is_empty() {
        return vec![Line::blank(0)];
    }
    if mode == WrapMode::None || line.width <= max_width {
        return vec![line_plan::clone_line(line)];
    }

    // Wrapping inspects the actual atom boundaries. Composition and decoration
    // preserve the plan; only this geometry-dependent operation materializes it.
    let atoms = line.atoms.to_vec();
    let count = atoms.len();
    let mut ranges = Vec::new();
    let mut line_start = 0;
    let mut current_width = 0;
    let mut index = 0;
    let flush_before = |end: usize,
                        ranges: &mut Vec<(usize, usize)>,
                        line_start: &mut usize,
                        current_width: &mut i64| {
        if *line_start < end {
            ranges.push((*line_start, end));
        }
        *line_start = end;
        *current_width = 0;
    };

    while index < count {
        let atom_width = atoms[index].width();
        if atoms[index].wrap_cjk() {
            if current_width + atom_width > max_width {
                flush_before(index, &mut ranges, &mut line_start, &mut current_width);
            }
            current_width += atom_width;
            index += 1;
        } else if mode == WrapMode::Word {
            let mut word_end = index;
            let mut word_width = 0;
            while word_end < count && !atoms[word_end].wrap_space() && !atoms[word_end].wrap_cjk() {
                word_width += atoms[word_end].width();
                word_end += 1;
            }
            if word_width > max_width {
                while index < word_end {
                    let width = atoms[index].width();
                    if current_width + width > max_width {
                        flush_before(index, &mut ranges, &mut line_start, &mut current_width);
                    }
                    current_width += width;
                    index += 1;
                }
            } else if current_width + word_width <= max_width {
                current_width += word_width;
                index = word_end;
            } else {
                flush_before(index, &mut ranges, &mut line_start, &mut current_width);
                current_width = word_width;
                index = word_end;
            }
            if index < count && atoms[index].wrap_space() {
                let width = atoms[index].width();
                if current_width + width <= max_width {
                    current_width += width;
                    index += 1;
                } else {
                    flush_before(index, &mut ranges, &mut line_start, &mut current_width);
                    index += 1;
                    line_start = index;
                }
            }
        } else {
            if current_width + atom_width > max_width {
                flush_before(index, &mut ranges, &mut line_start, &mut current_width);
            }
            current_width += atom_width;
            index += 1;
        }
    }
    if line_start < count {
        ranges.push((line_start, count));
    }
    ranges
        .into_iter()
        .map(|(start, end)| Line::from_atoms(&atoms[start..end]))
        .collect()
}

fn wrap_rendered(rendered: Rendered, max_width: i64, mode: WrapMode) -> Rendered {
    if mode == WrapMode::None || rendered.lines.is_empty() {
        return rendered;
    }
    let mut lines = LinePlan::default();
    let mut joining_break = AtomProperties::default();
    for (line, break_after) in rendered.lines.iter_with_breaks() {
        let pieces = LinePlan::from_lines(wrap_rendered_line(&line.materialize(), max_width, mode));
        lines = lines.concat_with_break(&pieces, joining_break);
        joining_break = break_after
            .map(|view| view.materialize().into_owned())
            .unwrap_or_default();
    }
    Rendered::from_line_plan(lines)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FlexAxis {
    Row,
    Column,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FlexMode {
    Grow,
    Shrink,
}

#[derive(Debug, Clone)]
struct FlexRuntimeItem<'a> {
    source: &'a LayoutNode,
    scope: RenderScope<'a>,
    grow: f64,
    shrink: f64,
    align_self: FlexAlign,
    min_main: i64,
    max_main: Option<i64>,
    base: i64,
    hypothetical: i64,
    target: i64,
}

#[derive(Debug)]
struct FlexSizedEntry {
    rendered: Rendered,
    cross: i64,
}

#[derive(Debug)]
struct FlexCrossLayout {
    crosses: Vec<i64>,
    leading: i64,
    between: i64,
}

fn flex_axis(direction: FlexDirection) -> FlexAxis {
    match direction {
        FlexDirection::Row | FlexDirection::RowReverse => FlexAxis::Row,
        FlexDirection::Column | FlexDirection::ColumnReverse => FlexAxis::Column,
    }
}

fn flex_direction_reversed(direction: FlexDirection) -> bool {
    matches!(
        direction,
        FlexDirection::RowReverse | FlexDirection::ColumnReverse
    )
}

fn flex_horizontal_size(size: &Size, context: LayoutContext) -> Option<i64> {
    match size {
        Size::Auto | Size::Stretch | Size::Contain => context
            .viewport_width_known
            .then_some(context.viewport_width.max(0)),
        Size::Pixels { value } | Size::Lines { value } => Some(*value),
        Size::Viewport => context
            .viewport_width_known
            .then_some(context.viewport_width.max(0)),
        Size::None | Size::Content => None,
        Size::MinContent | Size::MaxContent | Size::FitContent { .. } => context
            .viewport_width_known
            .then_some(context.viewport_width.max(0)),
        Size::ViewportHeight | Size::Add { .. } | Size::Subtract { .. } => None,
    }
}

fn flex_vertical_size(size: &Size, context: LayoutContext) -> Option<i64> {
    match size {
        Size::Lines { .. }
        | Size::Pixels { .. }
        | Size::ViewportHeight
        | Size::Add { .. }
        | Size::Subtract { .. } => resolve_raw_height(size, context).map(|value| value.max(0)),
        _ => None,
    }
}

fn flex_inline_viewport(
    axis: FlexAxis,
    main_size: Option<i64>,
    cross_size: Option<i64>,
) -> Option<i64> {
    match axis {
        FlexAxis::Row => main_size,
        FlexAxis::Column => cross_size,
    }
}

fn box_horizontal_side(node: &LayoutNode) -> Option<i64> {
    if let LayoutNode::Box {
        padding_left,
        padding_right,
        margin_left,
        margin_right,
        border_left,
        border_right,
        ..
    } = node
    {
        Some(padding_left + padding_right + margin_left + margin_right + border_left + border_right)
    } else {
        None
    }
}

fn box_vertical_side(node: &LayoutNode) -> Option<i64> {
    if let LayoutNode::Box {
        padding_top,
        padding_bottom,
        margin_top,
        margin_bottom,
        ..
    } = node
    {
        Some(padding_top + padding_bottom + margin_top + margin_bottom)
    } else {
        None
    }
}

fn box_content_intrinsics(
    node: &LayoutNode,
    scope: &RenderScope<'_>,
    context: LayoutContext,
) -> Result<Option<(i64, i64)>, String> {
    let LayoutNode::Box {
        content,
        child,
        content_min_width,
        wrap_mode,
        ..
    } = node
    else {
        return Ok(None);
    };
    if let Some(text) = content {
        Ok(Some((
            content_min_width.unwrap_or_else(|| measured_min_width(text, *wrap_mode)),
            measured_max_width(text),
        )))
    } else if let Some(child) = child {
        // Ebox measures a composite box's child under the flex container's
        // current inline viewport.  Treating that width as unknown makes
        // responsive descendants collapse to their narrow intrinsic form and
        // produces a different automatic minimum from the visible renderer.
        let rendered = scope
            .child(LocalStep::BoxChild, child)
            .phase(Phase::ContentIntrinsic)
            .render(context, true, None)?;
        Ok(Some((
            content_min_width.unwrap_or_else(|| rendered.min_content_width(*wrap_mode)),
            rendered.max_width(),
        )))
    } else {
        Ok(Some((0, 0)))
    }
}

fn flex_box_resolve_width(
    node: &LayoutNode,
    size: &Size,
    fallback: Option<i64>,
    scope: &RenderScope<'_>,
    context: LayoutContext,
) -> Result<Option<i64>, String> {
    let LayoutNode::Box {
        box_sizing,
        padding_left,
        padding_right,
        border_left,
        border_right,
        ..
    } = node
    else {
        return Ok(fallback);
    };
    let (min_content, max_content) =
        box_content_intrinsics(node, scope, context)?.unwrap_or((0, 0));
    let side = box_horizontal_side(node).unwrap_or(0);
    let stretch = context
        .viewport_width_known
        .then_some((context.viewport_width - side).max(0));
    Ok(resolve_width(
        size,
        fallback,
        context,
        *box_sizing,
        *padding_left,
        *padding_right,
        *border_left,
        *border_right,
        stretch,
        min_content,
        max_content,
    ))
}

fn flex_box_resolve_height(
    node: &LayoutNode,
    size: &Size,
    fallback: Option<i64>,
    context: LayoutContext,
) -> Option<i64> {
    let LayoutNode::Box {
        box_sizing,
        padding_top,
        padding_bottom,
        ..
    } = node
    else {
        return fallback;
    };
    resolve_height(
        size,
        fallback,
        context,
        *box_sizing,
        *padding_top,
        *padding_bottom,
    )
}

fn flex_min_main(
    source: &LayoutNode,
    rendered: &Rendered,
    axis: FlexAxis,
    scope: &RenderScope<'_>,
    context: LayoutContext,
) -> Result<i64, String> {
    let LayoutNode::Box {
        width,
        height,
        min_width,
        min_height,
        max_width,
        max_height,
        overflow,
        wrap_mode,
        content_min_width,
        ..
    } = source
    else {
        return Ok(match axis {
            FlexAxis::Row => rendered.max_width(),
            FlexAxis::Column => rendered.height(),
        });
    };
    let horizontal = matches!(axis, FlexAxis::Row);
    let side = if horizontal {
        box_horizontal_side(source).unwrap_or(0)
    } else {
        box_vertical_side(source).unwrap_or(0)
    };
    let minimum = if horizontal { min_width } else { min_height };
    let declared = if horizontal {
        flex_box_resolve_width(
            source,
            minimum,
            Some(0),
            &scope.phase(Phase::FlexMinWidth),
            context,
        )?
    } else {
        flex_box_resolve_height(source, minimum, Some(0), context)
    }
    .unwrap_or(0);
    // Explicit minima replace the automatic content constraint. Scrollable
    // overflow also has a zero automatic minimum on either main axis.
    if !matches!(minimum, Size::Auto) || *overflow != Overflow::Visible {
        return Ok(side + declared);
    }
    let content_min = if horizontal && *wrap_mode != WrapMode::None {
        match content_min_width {
            Some(value) => *value,
            None => {
                box_content_intrinsics(source, &scope.phase(Phase::FlexAutoMinContent), context)?
                    .unwrap_or((0, 0))
                    .0
            }
        }
    } else if horizontal {
        (rendered.max_width() - side).max(0)
    } else {
        (rendered.height() - side).max(0)
    };
    let preferred = if horizontal { width } else { height };
    let definite = match preferred {
        Size::Pixels { .. } | Size::Lines { .. } => {
            if horizontal {
                flex_box_resolve_width(source, preferred, None, scope, context)?
            } else {
                flex_box_resolve_height(source, preferred, None, context)
            }
        }
        _ => None,
    };
    let maximum = if horizontal {
        flex_box_resolve_width(
            source,
            max_width,
            None,
            &scope.phase(Phase::FlexMaxWidth),
            context,
        )?
    } else {
        flex_box_resolve_height(source, max_height, None, context)
    };
    Ok(side.max(
        (side + content_min)
            .min(definite.map(|value| side + value).unwrap_or(i64::MAX))
            .min(maximum.map(|value| side + value).unwrap_or(i64::MAX)),
    ))
}

fn flex_max_main(
    source: &LayoutNode,
    axis: FlexAxis,
    scope: &RenderScope<'_>,
    context: LayoutContext,
) -> Result<Option<i64>, String> {
    let LayoutNode::Box {
        max_width,
        max_height,
        ..
    } = source
    else {
        return Ok(None);
    };
    Ok(match axis {
        FlexAxis::Row => flex_box_resolve_width(
            source,
            max_width,
            None,
            &scope.phase(Phase::FlexMaxWidth),
            context,
        )?
        .map(|value| value + box_horizontal_side(source).unwrap_or(0)),
        FlexAxis::Column => flex_box_resolve_height(source, max_height, None, context)
            .map(|value| value + box_vertical_side(source).unwrap_or(0)),
    })
}

fn flex_horizontal_basis_value(size: &Size, context: LayoutContext) -> i64 {
    match size {
        Size::Pixels { value } | Size::Lines { value } => *value,
        Size::Viewport => context.viewport_width.max(0),
        Size::Stretch | Size::Contain => context.viewport_width.max(0),
        _ => 0,
    }
}

fn flex_vertical_basis_value(size: &Size) -> i64 {
    match size {
        Size::Pixels { value } | Size::Lines { value } => *value,
        _ => 0,
    }
}

fn flex_basis_main(
    source: &LayoutNode,
    rendered: &Rendered,
    axis: FlexAxis,
    basis: &Size,
    scope: &RenderScope<'_>,
    context: LayoutContext,
) -> Result<i64, String> {
    let rendered_main = match axis {
        FlexAxis::Row => rendered.max_width(),
        FlexAxis::Column => rendered.height(),
    };
    if matches!(basis, Size::Auto) {
        return Ok(rendered_main);
    }
    if matches!(basis, Size::Content) {
        if axis == FlexAxis::Row && matches!(source, LayoutNode::Box { .. }) {
            let (_, content_max) =
                box_content_intrinsics(source, &scope.phase(Phase::FlexBasisContent), context)?
                    .unwrap_or((0, 0));
            return Ok(box_horizontal_side(source).unwrap_or(0) + content_max);
        }
        return Ok(rendered_main);
    }
    if axis == FlexAxis::Row && matches!(source, LayoutNode::Box { .. }) {
        let (_, content_max) =
            box_content_intrinsics(source, &scope.phase(Phase::FlexBasisContent), context)?
                .unwrap_or((0, 0));
        let content = flex_box_resolve_width(
            source,
            basis,
            Some(content_max),
            &scope.phase(Phase::FlexBasisWidth),
            context,
        )?
        .unwrap_or(content_max);
        return Ok(box_horizontal_side(source).unwrap_or(0) + content);
    }
    Ok(match axis {
        FlexAxis::Row => flex_horizontal_basis_value(basis, context),
        FlexAxis::Column => flex_vertical_basis_value(basis),
    })
}

fn flex_clamp_main(value: i64, minimum: i64, maximum: Option<i64>) -> i64 {
    minimum.max(value.max(0).min(maximum.unwrap_or(999_999_999)))
}

// Plain boxes receive their flex target through BoxOverride.  Composite
// layouts, including the exact wrapper emitted for a visual flex container,
// must instead resolve viewport sizes against the item's inline allocation.
fn flex_item_uses_inline_viewport(node: &LayoutNode) -> bool {
    match node {
        LayoutNode::Box {
            content,
            child: Some(child),
            content_width_exact: true,
            ..
        } if content.is_none() => matches!(child.as_ref(), LayoutNode::Flex { .. }),
        LayoutNode::Box { .. } => false,
        _ => true,
    }
}

fn measure_flex_item<'a>(
    item: &'a FlexItem,
    axis: FlexAxis,
    inline_viewport: Option<i64>,
    scope: RenderScope<'a>,
    context: LayoutContext,
) -> Result<FlexRuntimeItem<'a>, String> {
    let scope = scope.resolve()?;
    let source = scope.view.node;
    let uses_inline_viewport = flex_item_uses_inline_viewport(source);
    let measurement_context = LayoutContext {
        viewport_width: if uses_inline_viewport {
            inline_viewport.unwrap_or(0)
        } else {
            0
        },
        viewport_width_known: uses_inline_viewport && inline_viewport.is_some(),
        viewport_height: context.viewport_height,
        inline_auto_width_intrinsic: context.inline_auto_width_intrinsic,
    };
    let rendered =
        scope
            .phase(Phase::FlexMeasure)
            .render(measurement_context, uses_inline_viewport, None)?;
    let min_main = flex_min_main(source, &rendered, axis, &scope, context)?;
    let max_main = flex_max_main(source, axis, &scope, context)?;
    let base = flex_basis_main(source, &rendered, axis, &item.basis, &scope, context)?.max(0);
    let hypothetical = flex_clamp_main(base, min_main, max_main);
    Ok(FlexRuntimeItem {
        source,
        scope,
        grow: item.grow,
        shrink: item.shrink,
        align_self: item.align_self,
        min_main,
        max_main,
        base,
        hypothetical,
        target: hypothetical,
    })
}

fn flex_break_lines<'a>(
    items: Vec<FlexRuntimeItem<'a>>,
    main_limit: Option<i64>,
    main_gap: i64,
    wrap: FlexWrap,
) -> Vec<Vec<FlexRuntimeItem<'a>>> {
    if wrap == FlexWrap::Nowrap || main_limit.is_none() {
        return vec![items];
    }
    let limit = main_limit.unwrap_or(0);
    let mut lines = Vec::new();
    let mut current = Vec::new();
    let mut current_size = 0;
    for item in items {
        let next_size =
            current_size + if current.is_empty() { 0 } else { main_gap } + item.hypothetical;
        if !current.is_empty() && next_size > limit {
            lines.push(current);
            current = vec![item];
            current_size = current[0].hypothetical;
        } else {
            current_size = next_size;
            current.push(item);
        }
    }
    if !current.is_empty() {
        lines.push(current);
    }
    lines
}

fn flex_factor(item: &FlexRuntimeItem<'_>, mode: FlexMode) -> f64 {
    match mode {
        FlexMode::Grow => item.grow,
        FlexMode::Shrink => item.shrink,
    }
}

fn flex_distribution_weight(item: &FlexRuntimeItem<'_>, mode: FlexMode) -> f64 {
    match mode {
        FlexMode::Grow => item.grow,
        FlexMode::Shrink => item.base as f64 * item.shrink,
    }
}

fn flex_line_free_space(
    line: &[FlexRuntimeItem<'_>],
    targets: &[i64],
    frozen: &[bool],
    available: i64,
) -> i64 {
    available
        - line
            .iter()
            .enumerate()
            .map(|(index, item)| {
                if frozen[index] {
                    targets[index]
                } else {
                    item.base
                }
            })
            .sum::<i64>()
}

fn flex_effective_free_space(initial: i64, free: i64, factor_total: f64) -> f64 {
    if factor_total > 0.0 && factor_total < 1.0 {
        let partial = initial as f64 * factor_total;
        if partial.abs() < (free as f64).abs() {
            partial
        } else {
            free as f64
        }
    } else {
        free as f64
    }
}

fn flex_distribute(amount: f64, weights: &[f64]) -> Vec<i64> {
    let amount = amount.max(0.0).floor() as i64;
    let total = weights
        .iter()
        .copied()
        .filter(|weight| *weight > 0.0)
        .sum::<f64>();
    if amount <= 0 || total <= 0.0 {
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
        for (share, weight) in shares.iter_mut().zip(weights) {
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

fn flex_size_line(line: &mut [FlexRuntimeItem<'_>], main_limit: Option<i64>, main_gap: i64) {
    let count = line.len();
    let Some(limit) = main_limit else {
        return;
    };
    let available = limit - main_gap * count.saturating_sub(1) as i64;
    let hypothetical_total = line.iter().map(|item| item.hypothetical).sum::<i64>();
    let mode = if hypothetical_total < available {
        FlexMode::Grow
    } else {
        FlexMode::Shrink
    };
    let mut targets = line.iter().map(|item| item.base).collect::<Vec<_>>();
    let mut frozen = vec![false; count];
    for (index, item) in line.iter().enumerate() {
        let factor = flex_factor(item, mode);
        if factor <= 0.0
            || (mode == FlexMode::Grow && item.base > item.hypothetical)
            || (mode == FlexMode::Shrink && item.base < item.hypothetical)
        {
            targets[index] = item.hypothetical;
            frozen[index] = true;
        }
    }
    let initial_free = flex_line_free_space(line, &targets, &frozen, available);
    loop {
        let free = flex_line_free_space(line, &targets, &frozen, available);
        let active = (0..count)
            .filter(|index| !frozen[*index])
            .collect::<Vec<_>>();
        let weights = active
            .iter()
            .map(|index| flex_distribution_weight(&line[*index], mode))
            .collect::<Vec<_>>();
        let weight_total = weights.iter().sum::<f64>();
        let factor_total = active
            .iter()
            .map(|index| flex_factor(&line[*index], mode))
            .sum::<f64>();
        let effective = flex_effective_free_space(initial_free, free, factor_total);
        if active.is_empty()
            || weight_total <= 0.0
            || (mode == FlexMode::Grow && effective < 0.0)
            || (mode == FlexMode::Shrink && effective > 0.0)
        {
            break;
        }
        let deltas = flex_distribute(effective.abs(), &weights);
        let mut min_violations = Vec::new();
        let mut max_violations = Vec::new();
        let mut total_violation = 0;
        for ((index, delta), _) in active.iter().zip(deltas).zip(&weights) {
            let item = &line[*index];
            let candidate = match mode {
                FlexMode::Grow => item.base + delta,
                FlexMode::Shrink => item.base - delta,
            };
            let clamped = flex_clamp_main(candidate, item.min_main, item.max_main);
            let adjustment = clamped - candidate;
            targets[*index] = clamped;
            if adjustment > 0 {
                min_violations.push(*index);
            } else if adjustment < 0 {
                max_violations.push(*index);
            }
            total_violation += adjustment;
        }
        let to_freeze = if total_violation == 0 {
            active
        } else if total_violation > 0 {
            if min_violations.is_empty() {
                active
            } else {
                min_violations
            }
        } else if max_violations.is_empty() {
            active
        } else {
            max_violations
        };
        for index in to_freeze {
            frozen[index] = true;
        }
    }
    for (item, target) in line.iter_mut().zip(targets) {
        item.target = target;
    }
}

fn flex_line_main_size(line: &[FlexRuntimeItem<'_>], main_gap: i64) -> i64 {
    line.iter().map(|item| item.target).sum::<i64>()
        + main_gap * line.len().saturating_sub(1) as i64
}

fn flex_spacing(mode: FlexAlign, leftover: i64, count: usize, base_gap: i64) -> (i64, i64, i64) {
    let leftover = leftover.max(0);
    match mode {
        FlexAlign::FlexEnd | FlexAlign::End | FlexAlign::Right | FlexAlign::Bottom => {
            (leftover, base_gap, 0)
        }
        FlexAlign::Center => {
            let leading = leftover / 2;
            (leading, base_gap, leftover - leading)
        }
        FlexAlign::SpaceBetween if count > 1 => (0, base_gap + leftover / (count as i64 - 1), 0),
        FlexAlign::SpaceBetween => (0, base_gap, leftover),
        FlexAlign::SpaceAround => {
            let unit = if count > 0 {
                leftover / count as i64
            } else {
                0
            };
            let leading = unit / 2;
            (
                leading,
                base_gap + unit,
                leftover - leading - unit * count.saturating_sub(1) as i64,
            )
        }
        FlexAlign::SpaceEvenly => {
            let unit = if count > 0 {
                leftover / (count as i64 + 1)
            } else {
                0
            };
            (unit, base_gap + unit, unit)
        }
        _ => (0, base_gap, leftover),
    }
}

fn flex_cross_offset(align: FlexAlign, extra: i64) -> i64 {
    match align {
        FlexAlign::FlexEnd
        | FlexAlign::End
        | FlexAlign::SelfEnd
        | FlexAlign::Right
        | FlexAlign::Bottom => extra,
        FlexAlign::Center => extra / 2,
        _ => 0,
    }
}

fn flex_resolved_align(item: &FlexRuntimeItem<'_>, container: FlexAlign) -> FlexAlign {
    if item.align_self == FlexAlign::Auto {
        container
    } else {
        item.align_self
    }
}

fn pad_rendered_width(mut rendered: Rendered, width: i64, align: FlexAlign) -> Rendered {
    rendered.empty_width = rendered.empty_width.max(width);
    rendered.lines = rendered.lines.map_lines(|_, mut line| {
        let extra = (width - line.width).max(0);
        let left = match align {
            FlexAlign::FlexEnd | FlexAlign::End | FlexAlign::Right | FlexAlign::SelfEnd => extra,
            FlexAlign::Center => extra / 2,
            _ => 0,
        };
        line.prepend_space(left);
        line.push_space(extra - left);
        line
    });
    rendered
}

fn pad_rendered_height(rendered: Rendered, height: i64, offset: i64, width: i64) -> Rendered {
    let extra = (height - rendered.height()).max(0);
    let top = extra.min(offset.max(0));
    let bottom = extra - top;
    let mut parts = Vec::with_capacity(3);
    if top > 0 {
        parts.push(Rendered::from_lines(
            (0..top).map(|_| Line::blank(width)).collect(),
        ));
    }
    parts.push(rendered);
    if bottom > 0 {
        parts.push(Rendered::from_lines(
            (0..bottom).map(|_| Line::blank(width)).collect(),
        ));
    }
    stack_vertical(parts)
}

fn box_override_for_flex(
    source: &LayoutNode,
    axis: FlexAxis,
    main: i64,
    cross: Option<i64>,
    stretch: bool,
) -> Option<BoxOverride> {
    if !matches!(source, LayoutNode::Box { .. }) {
        return None;
    }
    let horizontal_side = box_horizontal_side(source).unwrap_or(0);
    let vertical_side = box_vertical_side(source).unwrap_or(0);
    Some(match axis {
        FlexAxis::Row => BoxOverride {
            content_width: Some((main - horizontal_side).max(0)),
            content_height: (stretch && cross.is_some())
                .then_some((cross.unwrap_or(0) - vertical_side).max(0)),
            declared_width: None,
        },
        FlexAxis::Column => BoxOverride {
            content_width: (stretch && cross.is_some())
                .then_some((cross.unwrap_or(0) - horizontal_side).max(0)),
            content_height: Some((main - vertical_side).max(0)),
            declared_width: None,
        },
    })
}

#[allow(clippy::too_many_arguments)]
fn render_flex_sized_entry(
    item: &FlexRuntimeItem<'_>,
    axis: FlexAxis,
    main: i64,
    cross: Option<i64>,
    container_align: FlexAlign,
    phase: Phase,
    context: LayoutContext,
    intrinsic: bool,
) -> Result<FlexSizedEntry, String> {
    let align = flex_resolved_align(item, container_align);
    let stretch = matches!(align, FlexAlign::Stretch | FlexAlign::Normal);
    let source_box = !flex_item_uses_inline_viewport(item.source);
    let item_viewport = flex_inline_viewport(axis, Some(main), cross);
    let render_context = LayoutContext {
        viewport_width: if source_box {
            context.viewport_width
        } else {
            item_viewport.unwrap_or(context.viewport_width)
        },
        viewport_width_known: if source_box {
            context.viewport_width_known
        } else {
            item_viewport.is_some() || context.viewport_width_known
        },
        viewport_height: context.viewport_height,
        inline_auto_width_intrinsic: context.inline_auto_width_intrinsic,
    };
    let override_size = box_override_for_flex(item.source, axis, main, cross, stretch);
    let mut rendered = item
        .scope
        .phase(phase)
        .render(render_context, intrinsic, override_size)?;
    match axis {
        FlexAxis::Row => {
            rendered = pad_rendered_width(rendered, main, FlexAlign::FlexStart);
        }
        FlexAxis::Column => {
            let width = rendered.max_width();
            rendered = pad_rendered_height(rendered, main, 0, width);
        }
    }
    if let Some(cross) = cross {
        match axis {
            FlexAxis::Row => {
                let width = main.max(rendered.max_width());
                let extra = (cross - rendered.height()).max(0);
                rendered =
                    pad_rendered_height(rendered, cross, flex_cross_offset(align, extra), width);
            }
            FlexAxis::Column => {
                rendered = pad_rendered_width(rendered, cross, align);
            }
        }
    }
    let rendered_cross = cross.unwrap_or_else(|| match axis {
        FlexAxis::Row => rendered.height(),
        FlexAxis::Column => rendered.max_width(),
    });
    Ok(FlexSizedEntry {
        rendered,
        cross: rendered_cross,
    })
}

fn concat_horizontal_sized(parts: Vec<(Rendered, i64)>, target_height: i64) -> Rendered {
    let empty_width = parts.iter().map(|(_, width)| width).sum();
    let height = parts
        .iter()
        .map(|(rendered, _)| rendered.height())
        .max()
        .unwrap_or(0)
        .max(target_height);
    let mut parts = parts
        .iter()
        .map(|(rendered, width)| (rendered.lines.iter(), *width))
        .collect::<Vec<_>>();
    let lines = LinePlan::from_lines((0..height as usize).map(|_| {
        let mut line = Line::default();
        for (lines, width) in &mut parts {
            if let Some(part) = lines.next() {
                line.append(&part.materialize());
            } else {
                line.push_space(*width);
            }
        }
        if line.atoms.is_empty() {
            Line::blank(0)
        } else {
            line
        }
    }));
    let mut rendered = Rendered::from_line_plan(lines);
    rendered.empty_width = empty_width;
    rendered
}

fn stack_vertical(parts: Vec<Rendered>) -> Rendered {
    fn join_parts(parts: &[Rendered]) -> LinePlan {
        match parts {
            [] => LinePlan::default(),
            [part] => part.lines.clone(),
            _ => {
                let middle = parts.len() / 2;
                join_parts(&parts[..middle]).concat(&join_parts(&parts[middle..]))
            }
        }
    }
    let lines = join_parts(&parts);
    let mut rendered = Rendered::from_line_plan(lines);
    rendered.empty_width = parts.iter().map(Rendered::max_width).max().unwrap_or(0);
    rendered
}

fn slice_rendered(rendered: Rendered, start: i64, height: i64) -> Rendered {
    let start = usize::try_from(start.max(0)).unwrap_or(usize::MAX);
    let height = usize::try_from(height.max(0)).unwrap_or(0);
    let end = start.saturating_add(height).min(rendered.lines.len());
    if start >= end {
        let mut empty = Rendered::from_line_plan(LinePlan::default());
        empty.empty_width = rendered.max_width();
        return empty;
    }
    Rendered::from_line_plan(rendered.lines.slice(start..end))
}

fn exact_rendered_height(
    node: &LayoutNode,
    resolver: Option<&RetainedDocument>,
    context: LayoutContext,
) -> Option<i64> {
    evaluation::record_height_query();
    let node = resolver
        .and_then(|value| value.resolve(node).ok())
        .unwrap_or(node);
    match node {
        LayoutNode::NodeRef { .. } => None,
        LayoutNode::Text { content, .. } => i64::try_from(content.lines.len()).ok(),
        LayoutNode::Box {
            height,
            min_height,
            max_height,
            box_sizing,
            padding_top,
            padding_bottom,
            margin_top,
            margin_bottom,
            overflow,
            ..
        } => {
            if *overflow == Overflow::Visible {
                return None;
            }
            let content_height = resolve_definite_box_content_height(
                height,
                min_height,
                max_height,
                context,
                *box_sizing,
                *padding_top,
                *padding_bottom,
                None,
            )?;
            Some(content_height + padding_top + padding_bottom + margin_top + margin_bottom)
        }
        LayoutNode::Row { children, .. } => children
            .iter()
            .map(|child| exact_rendered_height(child, resolver, context))
            .try_fold(0_i64, |maximum, height| {
                height.map(|height| maximum.max(height))
            }),
        LayoutNode::Column { children, .. } => children
            .iter()
            .map(|child| exact_rendered_height(child, resolver, context))
            .try_fold(0_i64, |total, height| {
                height.and_then(|height| total.checked_add(height))
            }),
        LayoutNode::Flex { .. } => None,
    }
}

fn render_node_window(
    scope: &RenderScope<'_>,
    context: LayoutContext,
    intrinsic: bool,
    start: i64,
    height: i64,
) -> Option<Result<Rendered, String>> {
    let scope = match scope.resolve() {
        Ok(scope) => scope,
        Err(error) => return Some(Err(error)),
    };
    let node = scope.view.node;
    let resolver = scope.resolver;
    let total_height = exact_rendered_height(node, resolver, context)?;
    if start <= 0 && height >= total_height {
        return Some(
            scope
                .phase(Phase::WindowFull)
                .render(context, intrinsic, None),
        );
    }
    match node {
        LayoutNode::Column { children, .. }
            if !intrinsic
                && !context.inline_auto_width_intrinsic
                && context.viewport_width_known =>
        {
            Some(render_column_window(
                children, &scope, context, start, height,
            ))
        }
        _ => Some(
            scope
                .phase(Phase::WindowFallback)
                .render(context, intrinsic, None)
                .map(|rendered| slice_rendered(rendered, start, height)),
        ),
    }
}

fn render_column_window<'a>(
    children: &'a [LayoutNode],
    scope: &RenderScope<'a>,
    context: LayoutContext,
    start: i64,
    height: i64,
) -> Result<Rendered, String> {
    let end = start.saturating_add(height).max(start);
    let target = context.viewport_width.max(0);
    let mut offset = 0_i64;
    let mut parts = Vec::new();

    for child in column_leaves(scope, children) {
        let child_height = exact_rendered_height(child.view.node, child.resolver, context)
            .ok_or_else(|| "Native layout column window has an unbounded child".to_owned())?;
        let child_end = offset.saturating_add(child_height);
        if child_end <= start {
            offset = child_end;
            continue;
        }
        if offset >= end {
            break;
        }

        let child_start = start.saturating_sub(offset);
        let child_window_height = (child_end.min(end) - (offset + child_start)).max(0);
        let mut rendered = if child_start == 0 && child_window_height >= child_height {
            child
                .phase(Phase::WindowChildFull)
                .render(context, false, None)?
        } else {
            render_node_window(
                &child.phase(Phase::WindowChildPartial),
                context,
                false,
                child_start,
                child_window_height,
            )
            .unwrap_or_else(|| {
                child
                    .phase(Phase::WindowFallback)
                    .render(context, false, None)
                    .map(|rendered| slice_rendered(rendered, child_start, child_window_height))
            })?
        };

        let extra = (target - rendered.first_width()).max(0);
        if extra > 0 {
            rendered.lines = rendered
                .lines
                .map_lines(|_, mut line| {
                    line.push_space(extra);
                    line
                })
                .clear_breaks();
        }
        if !rendered.lines.is_empty() {
            parts.push(rendered);
        }
        offset = child_end;
    }

    Ok(stack_vertical(parts))
}

fn flex_line_cross(
    line: &[FlexRuntimeItem<'_>],
    axis: FlexAxis,
    container_align: FlexAlign,
    context: LayoutContext,
    intrinsic: bool,
) -> Result<i64, String> {
    let mut maximum = 1;
    for item in line {
        maximum = maximum.max(
            render_flex_sized_entry(
                item,
                axis,
                item.target,
                None,
                container_align,
                Phase::FlexCrossProbe,
                context,
                intrinsic,
            )?
            .cross,
        );
    }
    Ok(maximum)
}

fn flex_layout_cross(
    crosses: Vec<i64>,
    container_cross: Option<i64>,
    cross_gap: i64,
    align: FlexAlign,
    single_line: bool,
) -> FlexCrossLayout {
    let count = crosses.len();
    let natural = crosses.iter().sum::<i64>() + cross_gap * count.saturating_sub(1) as i64;
    let leftover = container_cross.map_or(0, |cross| cross - natural);
    if let Some(cross) = container_cross {
        if single_line && count == 1 {
            return FlexCrossLayout {
                crosses: vec![cross],
                leading: 0,
                between: cross_gap,
            };
        }
        if leftover > 0 && matches!(align, FlexAlign::Stretch | FlexAlign::Normal) {
            let extras = flex_distribute(leftover as f64, &vec![1.0; count]);
            return FlexCrossLayout {
                crosses: crosses
                    .into_iter()
                    .zip(extras)
                    .map(|(value, extra)| value + extra)
                    .collect(),
                leading: 0,
                between: cross_gap,
            };
        }
    }
    let (leading, between, _) = flex_spacing(align, leftover, count, cross_gap);
    FlexCrossLayout {
        crosses,
        leading,
        between,
    }
}

#[allow(clippy::too_many_arguments)]
fn render_flex_row_line(
    line: &[FlexRuntimeItem<'_>],
    line_cross: i64,
    main_size: i64,
    main_gap: i64,
    justify: FlexAlign,
    align: FlexAlign,
    context: LayoutContext,
    intrinsic: bool,
) -> Result<Rendered, String> {
    let line_main = flex_line_main_size(line, main_gap);
    let (leading, between, trailing) =
        flex_spacing(justify, main_size - line_main, line.len(), main_gap);
    let mut parts = Vec::new();
    if leading > 0 {
        parts.push((Rendered::from_line_plan(LinePlan::default()), leading));
    }
    for (index, item) in line.iter().enumerate() {
        let entry = render_flex_sized_entry(
            item,
            FlexAxis::Row,
            item.target,
            Some(line_cross),
            align,
            Phase::FlexFinal,
            context,
            intrinsic,
        )?;
        parts.push((entry.rendered, item.target));
        if index + 1 < line.len() && between > 0 {
            parts.push((Rendered::from_line_plan(LinePlan::default()), between));
        }
    }
    if trailing > 0 {
        parts.push((Rendered::from_line_plan(LinePlan::default()), trailing));
    }
    Ok(concat_horizontal_sized(parts, line_cross))
}

#[allow(clippy::too_many_arguments)]
fn render_flex_column_line(
    line: &[FlexRuntimeItem<'_>],
    line_cross: i64,
    main_size: Option<i64>,
    main_gap: i64,
    justify: FlexAlign,
    align: FlexAlign,
    context: LayoutContext,
    intrinsic: bool,
) -> Result<Rendered, String> {
    let line_main = flex_line_main_size(line, main_gap);
    let target_main = main_size.unwrap_or(line_main);
    let (leading, between, _) =
        flex_spacing(justify, target_main - line_main, line.len(), main_gap);
    let mut parts = Vec::new();
    if leading > 0 {
        parts.push(Rendered::from_lines(
            (0..leading).map(|_| Line::blank(line_cross)).collect(),
        ));
    }
    for (index, item) in line.iter().enumerate() {
        parts.push(
            render_flex_sized_entry(
                item,
                FlexAxis::Column,
                item.target,
                Some(line_cross),
                align,
                Phase::FlexFinal,
                context,
                intrinsic,
            )?
            .rendered,
        );
        if index + 1 < line.len() && between > 0 {
            parts.push(Rendered::from_lines(
                (0..between).map(|_| Line::blank(line_cross)).collect(),
            ));
        }
    }
    let rendered = stack_vertical(parts);
    Ok(pad_rendered_height(rendered, target_main, 0, line_cross))
}

#[allow(clippy::too_many_arguments)]
fn render_flex_row(
    mut lines: Vec<Vec<FlexRuntimeItem<'_>>>,
    main_size: Option<i64>,
    cross_size: Option<i64>,
    main_gap: i64,
    cross_gap: i64,
    justify: FlexAlign,
    align: FlexAlign,
    align_content: FlexAlign,
    single_line: bool,
    context: LayoutContext,
    intrinsic: bool,
) -> Result<Rendered, String> {
    for line in &mut lines {
        flex_size_line(line, main_size, main_gap);
    }
    let container_main = main_size.unwrap_or_else(|| {
        lines
            .iter()
            .map(|line| flex_line_main_size(line, main_gap))
            .max()
            .unwrap_or(0)
    });
    let crosses = if cross_size.is_some() && single_line {
        vec![cross_size.unwrap_or(0)]
    } else {
        lines
            .iter()
            .map(|line| flex_line_cross(line, FlexAxis::Row, align, context, intrinsic))
            .collect::<Result<Vec<_>, _>>()?
    };
    let cross_layout =
        flex_layout_cross(crosses, cross_size, cross_gap, align_content, single_line);
    let mut parts = Vec::new();
    if cross_layout.leading > 0 {
        parts.push(Rendered::from_lines(
            (0..cross_layout.leading)
                .map(|_| Line::blank(container_main))
                .collect(),
        ));
    }
    let line_count = lines.len();
    for (index, (line, line_cross)) in lines
        .iter()
        .zip(cross_layout.crosses.iter().copied())
        .enumerate()
    {
        parts.push(render_flex_row_line(
            line,
            line_cross,
            container_main,
            main_gap,
            justify,
            align,
            context,
            intrinsic,
        )?);
        if index + 1 < line_count && cross_layout.between > 0 {
            parts.push(Rendered::from_lines(
                (0..cross_layout.between)
                    .map(|_| Line::blank(container_main))
                    .collect(),
            ));
        }
    }
    let rendered = stack_vertical(parts);
    Ok(if let Some(cross) = cross_size {
        pad_rendered_height(rendered, cross, 0, container_main)
    } else {
        rendered
    })
}

#[allow(clippy::too_many_arguments)]
fn render_flex_column(
    mut lines: Vec<Vec<FlexRuntimeItem<'_>>>,
    main_size: Option<i64>,
    cross_size: Option<i64>,
    main_gap: i64,
    cross_gap: i64,
    justify: FlexAlign,
    align: FlexAlign,
    align_content: FlexAlign,
    single_line: bool,
    context: LayoutContext,
    intrinsic: bool,
) -> Result<Rendered, String> {
    for line in &mut lines {
        flex_size_line(line, main_size, main_gap);
    }
    let crosses = if cross_size.is_some() && single_line {
        vec![cross_size.unwrap_or(0)]
    } else {
        lines
            .iter()
            .map(|line| flex_line_cross(line, FlexAxis::Column, align, context, intrinsic))
            .collect::<Result<Vec<_>, _>>()?
    };
    let cross_layout =
        flex_layout_cross(crosses, cross_size, cross_gap, align_content, single_line);
    let mut parts = Vec::new();
    if cross_layout.leading > 0 {
        parts.push((
            Rendered::from_line_plan(LinePlan::default()),
            cross_layout.leading,
        ));
    }
    let line_count = lines.len();
    for (index, (line, line_cross)) in lines
        .iter()
        .zip(cross_layout.crosses.iter().copied())
        .enumerate()
    {
        let rendered = render_flex_column_line(
            line, line_cross, main_size, main_gap, justify, align, context, intrinsic,
        )?;
        parts.push((rendered, line_cross));
        if index + 1 < line_count && cross_layout.between > 0 {
            parts.push((
                Rendered::from_line_plan(LinePlan::default()),
                cross_layout.between,
            ));
        }
    }
    let mut rendered = concat_horizontal_sized(parts, 0);
    if let Some(cross) = cross_size {
        rendered = pad_rendered_width(rendered, cross, FlexAlign::FlexStart);
    }
    Ok(rendered)
}

#[allow(clippy::too_many_arguments)]
fn render_flex<'a>(
    direction: FlexDirection,
    wrap: FlexWrap,
    justify: FlexAlign,
    align_items: FlexAlign,
    align_content: FlexAlign,
    width: &Size,
    height: &Size,
    row_gap: i64,
    column_gap: i64,
    source_items: &'a [FlexItem],
    scope: &RenderScope<'a>,
    context: LayoutContext,
    intrinsic: bool,
) -> Result<Rendered, String> {
    let axis = flex_axis(direction);
    let width = flex_horizontal_size(width, context);
    let height = flex_vertical_size(height, context);
    let (main_size, cross_size) = match axis {
        FlexAxis::Row => (width, height),
        FlexAxis::Column => (height, width),
    };
    let inline_viewport = flex_inline_viewport(axis, main_size, cross_size);
    let mut indices = (0..source_items.len()).collect::<Vec<_>>();
    indices.sort_by_key(|index| (source_items[*index].order, *index));
    let mut items = indices
        .into_iter()
        .map(|index| {
            measure_flex_item(
                &source_items[index],
                axis,
                inline_viewport,
                scope.child(LocalStep::FlexItem(index), &source_items[index].node),
                context,
            )
        })
        .collect::<Result<Vec<_>, _>>()?;
    if flex_direction_reversed(direction) {
        items.reverse();
    }
    let (main_gap, cross_gap) = match axis {
        FlexAxis::Row => (column_gap, row_gap),
        FlexAxis::Column => (row_gap, column_gap),
    };
    let mut lines = flex_break_lines(items, main_size, main_gap, wrap);
    if wrap == FlexWrap::WrapReverse {
        lines.reverse();
    }
    let single_line = wrap == FlexWrap::Nowrap;
    match axis {
        FlexAxis::Row => render_flex_row(
            lines,
            main_size,
            cross_size,
            main_gap,
            cross_gap,
            justify,
            align_items,
            align_content,
            single_line,
            context,
            intrinsic,
        ),
        FlexAxis::Column => render_flex_column(
            lines,
            main_size,
            cross_size,
            main_gap,
            cross_gap,
            justify,
            align_items,
            align_content,
            single_line,
            context,
            intrinsic,
        ),
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct BoxOverride {
    content_width: Option<i64>,
    content_height: Option<i64>,
    declared_width: Option<i64>,
}

fn render_node_with_override(
    node: &LayoutNode,
    resolver: Option<&RetainedDocument>,
    context: LayoutContext,
    intrinsic: bool,
    size_override: Option<BoxOverride>,
) -> Result<Rendered, String> {
    RenderScope::uncached(node, resolver).render(context, intrinsic, size_override)
}

fn project_box_lines(
    scope: &RenderScope<'_>,
    slot: BoxProjectionSlot,
    input: LinePlan,
    change: &mut Option<PlanChange>,
    ops: Vec<LineOp>,
) -> LinePlan {
    let ops: Arc<[LineOp]> = ops.into();
    let state = if let Some(previous) = scope.previous_projection(slot) {
        let update = previous.update(input, change.as_ref(), ops);
        *change = Some(update.change);
        update.state
    } else {
        *change = None;
        ProjectionState::new(input, ops)
    };
    let lines = state.plan().clone();
    scope.store_projection(slot, state);
    lines
}

fn frame_box_lines(
    scope: &RenderScope<'_>,
    slot: BoxProjectionSlot,
    input: LinePlan,
    change: &mut Option<PlanChange>,
    frame: FrameSpec,
) -> LinePlan {
    let state = if let Some(previous) = scope.previous_projection(slot) {
        let update = previous.update_frame(input, change.as_ref(), frame);
        *change = Some(update.change);
        update.state
    } else {
        *change = None;
        ProjectionState::new_frame(input, frame)
    };
    let lines = state.plan().clone();
    scope.store_projection(slot, state);
    lines
}

fn render_node_body(
    scope: &RenderScope<'_>,
    context: LayoutContext,
    intrinsic: bool,
    size_override: Option<BoxOverride>,
) -> Result<Rendered, String> {
    let node = scope.view.node;
    let resolver = scope.resolver;

    match node {
        LayoutNode::NodeRef { .. } => Err("Native unresolved retained node reference".to_owned()),
        LayoutNode::Box {
            region_id,
            content,
            content_region_id,
            content_typography_style,
            content_foreground_style,
            content_surface_template_id,
            child,
            content_width_exact,
            content_min_width: _,
            width,
            min_width,
            max_width,
            height,
            min_height,
            max_height,
            box_sizing,
            padding_left,
            padding_right,
            padding_top,
            padding_bottom,
            margin_left,
            margin_right,
            margin_top,
            margin_bottom,
            border_left,
            border_right,
            typography_style,
            foreground_style,
            background_style,
            border_left_style,
            border_right_style,
            border_top_style,
            border_bottom_style,
            surface_template_id,
            text_align,
            vertical_align: vertical,
            overflow,
            wrap_mode,
            scroll_offset,
            ..
        } => {
            let declared_width_override =
                size_override.and_then(|override_size| override_size.declared_width);
            let declared_width_size = declared_width_override.map(|value| Size::Pixels { value });
            let effective_width = declared_width_size.as_ref().unwrap_or(width);
            let side_width = padding_left
                + padding_right
                + margin_left
                + margin_right
                + border_left
                + border_right;
            let stretch = context
                .viewport_width_known
                .then_some((context.viewport_width - side_width).max(0));

            let preliminary_child_width = size_override
                .and_then(|override_size| override_size.content_width)
                .or_else(|| {
                    resolve_child_viewport_width(
                        effective_width,
                        min_width,
                        max_width,
                        context,
                        *box_sizing,
                        *padding_left,
                        *padding_right,
                        *border_left,
                        *border_right,
                        stretch,
                    )
                });
            let preliminary_child_height = size_override
                .and_then(|override_size| override_size.content_height)
                .or_else(|| {
                    resolve_height(
                        height,
                        None,
                        context,
                        *box_sizing,
                        *padding_top,
                        *padding_bottom,
                    )
                });
            let intrinsic_child = matches!(effective_width, Size::MaxContent);
            let definite_content_width = resolve_definite_box_content_width(
                effective_width,
                min_width,
                max_width,
                context,
                *box_sizing,
                *padding_left,
                *padding_right,
                *border_left,
                *border_right,
                stretch,
                size_override.and_then(|override_size| override_size.content_width),
            );
            let definite_content_height = resolve_definite_box_content_height(
                height,
                min_height,
                max_height,
                context,
                *box_sizing,
                *padding_top,
                *padding_bottom,
                size_override.and_then(|override_size| override_size.content_height),
            );
            let window_rendering_disabled = {
                {
                    false
                }
            };
            let simple_scroll_window = *overflow == Overflow::Scroll
                // Only a requested complete producer needs effects from every
                // child, including offscreen owners. Ordinary retained layout
                // keeps the existing window shortcut.
                && !scope.complete_scroll_effects_requested()
                && child.is_some()
                && definite_content_width.is_some()
                && definite_content_height.is_some()
                && !intrinsic
                && !intrinsic_child
                && !window_rendering_disabled
                && *padding_left == 0
                && *padding_right == 0
                && *padding_top == 0
                && *padding_bottom == 0
                && *margin_left == 0
                && *margin_right == 0
                && *margin_top == 0
                && *margin_bottom == 0
                && *border_left == 0
                && *border_right == 0
                && border_top_style.is_none()
                && border_bottom_style.is_none()
                && *vertical == VerticalAlign::Top;
            let mut windowed_child_start = None;
            let mut windowed_child_height = None;
            let mut child_change = None;
            let mut child_rendered = if let Some(child) = child {
                let child_scope = scope.child(LocalStep::BoxChild, child);
                let child_context = LayoutContext {
                    viewport_width: if intrinsic_child {
                        0
                    } else {
                        preliminary_child_width.unwrap_or(context.viewport_width)
                    },
                    viewport_width_known: !intrinsic_child
                        && (preliminary_child_width.is_some() || context.viewport_width_known),
                    viewport_height: preliminary_child_height.unwrap_or(context.viewport_height),
                    inline_auto_width_intrinsic: context.inline_auto_width_intrinsic
                        && matches!(effective_width, Size::Auto),
                };
                if simple_scroll_window {
                    if let Some(total_height) =
                        exact_rendered_height(child, resolver, child_context)
                    {
                        let content_height = definite_content_height.expect("checked above");
                        let max_offset = (total_height - content_height).max(0);
                        let start = (*scroll_offset).max(0).min(max_offset);
                        windowed_child_start = Some(start);
                        windowed_child_height = Some(total_height);
                        Some(
                            render_node_window(
                                &child_scope,
                                child_context,
                                intrinsic || intrinsic_child,
                                start,
                                content_height,
                            )
                            .expect("exact height checked above")?,
                        )
                    } else {
                        let evaluated = child_scope.render_with_change(
                            child_context,
                            intrinsic || intrinsic_child,
                            None,
                        )?;
                        child_change = evaluated.change;
                        Some(evaluated.rendered)
                    }
                } else {
                    let evaluated = child_scope.render_with_change(
                        child_context,
                        intrinsic || intrinsic_child,
                        None,
                    )?;
                    child_change = evaluated.change;
                    Some(evaluated.rendered)
                }
            } else {
                None
            };

            let (min_content, max_content) = if let Some(text) = content {
                (
                    measured_min_width(text, *wrap_mode),
                    measured_max_width(text),
                )
            } else {
                let rendered = child_rendered.as_ref().expect("validated child");
                (rendered.min_content_width(*wrap_mode), rendered.max_width())
            };
            let auto_width = if context.inline_auto_width_intrinsic {
                max_content
            } else {
                stretch.unwrap_or(max_content)
            };
            let minimum = resolve_width(
                min_width,
                Some(0),
                context,
                *box_sizing,
                *padding_left,
                *padding_right,
                *border_left,
                *border_right,
                stretch,
                min_content,
                max_content,
            )
            .unwrap_or(0);
            let maximum = resolve_width(
                max_width,
                None,
                context,
                *box_sizing,
                *padding_left,
                *padding_right,
                *border_left,
                *border_right,
                stretch,
                min_content,
                max_content,
            )
            .unwrap_or(i64::MAX);
            let preferred = size_override
                .and_then(|override_size| override_size.content_width)
                .unwrap_or_else(|| {
                    resolve_width(
                        effective_width,
                        Some(auto_width),
                        context,
                        *box_sizing,
                        *padding_left,
                        *padding_right,
                        *border_left,
                        *border_right,
                        stretch,
                        min_content,
                        max_content,
                    )
                    .unwrap_or(auto_width)
                });
            let content_width = minimum.max(preferred.max(0).min(maximum));
            let transparent_preformatted = child.is_some()
                && *content_width_exact
                && *wrap_mode == WrapMode::None
                && *text_align == HorizontalAlign::Left
                && *vertical == VerticalAlign::Top
                && matches!(height, Size::Auto)
                && matches!(min_height, Size::Lines { value: 0 })
                && matches!(max_height, Size::None)
                && *overflow == Overflow::Scroll
                && *padding_left == 0
                && *padding_right == 0
                && *padding_top == 0
                && *padding_bottom == 0
                && *margin_left == 0
                && *margin_right == 0
                && *margin_top == 0
                && *margin_bottom == 0
                && *border_left == 0
                && *border_right == 0
                && foreground_style.is_none()
                && background_style.is_none()
                && border_left_style.is_none()
                && border_right_style.is_none()
                && border_top_style.is_none()
                && border_bottom_style.is_none()
                && child_rendered.as_ref().is_some_and(|rendered| {
                    rendered.lines.all_nonempty() && rendered.lines.uniform_width(content_width)
                });
            if transparent_preformatted {
                let mut rendered = child_rendered.take().expect("validated child");
                rendered.empty_width = content_width;
                rendered.root_scroll = None;
                rendered.own_scroll_owner = false;
                let mut ops = vec![LineOp::OwnContent {
                    region: *region_id,
                    start: 0,
                }];
                ops.extend(surface_template_id.map(LineOp::Template));
                rendered.lines = project_box_lines(
                    scope,
                    BoxProjectionSlot::TransparentContent,
                    rendered.lines,
                    &mut child_change,
                    ops,
                );
                if let Some(change) = child_change {
                    scope.publish_change(change);
                }
                return Ok(rendered);
            }

            let previous_scroll = scope.previous_root_scroll();
            let text_styles = [
                *content_typography_style,
                *content_foreground_style,
                *content_surface_template_id,
            ];
            let reusable_text = previous_scroll
                .as_ref()
                .and_then(|scroll| scroll.text_input.as_ref())
                .filter(|input| {
                    content
                        .as_ref()
                        .is_some_and(|text| Arc::ptr_eq(text, &input.source))
                        && input.width == content_width
                        && input.wrap == *wrap_mode
                        && input.region == *content_region_id
                        && input.styles == text_styles
                });
            let mut formatted = if let Some(input) = reusable_text {
                child_change = Some(PlanChange::same(&input.lines));
                input.lines.clone()
            } else if let Some(text) = content {
                let mut content_lines = measured_lines(text, content_width, *wrap_mode);
                if let Some(content_region_id) = content_region_id {
                    for (index, line) in content_lines.iter_mut().enumerate() {
                        line.own_content(*content_region_id, index as i64);
                        line.apply_style(*content_typography_style);
                        line.apply_style(*content_foreground_style);
                        line.apply_property_template(*content_surface_template_id);
                    }
                }
                LinePlan::from_lines(content_lines)
            } else {
                let rendered = child_rendered.expect("validated child");
                let uniform_width = rendered.lines.uniform_width(content_width);
                let rendered = if *wrap_mode != WrapMode::None && !uniform_width {
                    child_change = None;
                    wrap_rendered(rendered, content_width, *wrap_mode)
                } else {
                    rendered
                };
                rendered.lines
            };
            let text_input = if scope.root_scroll_requested() {
                content.as_ref().map(|text| RootTextInput {
                    source: Arc::clone(text),
                    width: content_width,
                    wrap: *wrap_mode,
                    region: *content_region_id,
                    styles: text_styles,
                    lines: formatted.clone(),
                })
            } else {
                None
            };
            // Ordinary Box formatting historically rebuilds default breaks;
            // the transparent preformatted branch above preserves child breaks.
            let mut change = child_change;
            let mut pad_ops = Vec::new();
            if content.is_some() || !(*content_width_exact && *wrap_mode == WrapMode::None) {
                pad_ops.push(LineOp::PadTo {
                    width: content_width,
                    align: *text_align,
                });
            }
            pad_ops.push(LineOp::ClearBreaks);
            formatted = project_box_lines(
                scope,
                BoxProjectionSlot::ContentPad,
                formatted,
                &mut change,
                pad_ops,
            );
            let text_height = windowed_child_height.unwrap_or(formatted.len() as i64);
            let minimum_height = resolve_height(
                min_height,
                Some(0),
                context,
                *box_sizing,
                *padding_top,
                *padding_bottom,
            )
            .unwrap_or(0);
            let maximum_height = resolve_height(
                max_height,
                None,
                context,
                *box_sizing,
                *padding_top,
                *padding_bottom,
            )
            .unwrap_or(i64::MAX);
            let preferred_height = size_override
                .and_then(|override_size| override_size.content_height)
                .unwrap_or_else(|| {
                    resolve_height(
                        height,
                        None,
                        context,
                        *box_sizing,
                        *padding_top,
                        *padding_bottom,
                    )
                    .unwrap_or(text_height)
                });
            let content_height = minimum_height
                .max(0)
                .max(preferred_height.max(0).min(maximum_height));
            let simple_scroll_rendered = *overflow == Overflow::Scroll
                && text_height >= content_height
                && *padding_left == 0
                && *padding_right == 0
                && *padding_top == 0
                && *padding_bottom == 0
                && *margin_left == 0
                && *margin_right == 0
                && *margin_top == 0
                && *margin_bottom == 0
                && *border_left == 0
                && *border_right == 0
                && border_top_style.is_none()
                && border_bottom_style.is_none()
                && *vertical == VerticalAlign::Top;

            let root_scroll = if scope.root_scroll_requested()
                && *overflow == Overflow::Scroll
                && *padding_left == 0
                && *padding_right == 0
                && *padding_top == 0
                && *padding_bottom == 0
                && *margin_left == 0
                && *margin_right == 0
                && *margin_top == 0
                && *margin_bottom == 0
                && *border_left == 0
                && *border_right == 0
                && border_top_style.is_none()
                && border_bottom_style.is_none()
                && surface_template_id.is_none()
                && *vertical == VerticalAlign::Top
            {
                let full_content = formatted.clone();
                let mut ops = vec![LineOp::OwnContent {
                    region: *region_id,
                    start: 0,
                }];
                ops.extend(
                    [*typography_style, *foreground_style, *background_style]
                        .into_iter()
                        .flatten()
                        .map(LineOp::Style),
                );
                let rendered_content = project_box_lines(
                    scope,
                    BoxProjectionSlot::ScrollContent,
                    full_content.clone(),
                    &mut change.clone(),
                    ops,
                );
                Some(Arc::new(RootScrollPlan {
                    region_id: *region_id,
                    full_content,
                    rendered_content,
                    visible_height: content_height,
                    effective_offset: (*scroll_offset)
                        .max(0)
                        .min((text_height - content_height).max(0)),
                    text_input,
                }))
            } else {
                None
            };

            let mut content_index_start = 0_i64;
            let mut overflow_lines = LinePlan::default();
            if let Some(start) = windowed_child_start {
                content_index_start = start;
            } else if formatted.len() > content_height as usize {
                // Clipping changes operation origins. Until the exact old/new window
                // anchors are available, the next stage takes its counted fallback.
                change = None;
                match overflow {
                    Overflow::Scroll => {
                        let max_offset = formatted.len() - content_height as usize;
                        let start = (*scroll_offset as usize).min(max_offset);
                        if simple_scroll_rendered {
                            content_index_start = start as i64;
                        }
                        formatted = formatted.slice(start..start + content_height as usize);
                    }
                    Overflow::Hidden => {
                        formatted = formatted.slice(0..content_height as usize);
                    }
                    Overflow::Visible => {
                        overflow_lines = formatted.slice(content_height as usize..formatted.len());
                        formatted = formatted.slice(0..content_height as usize);
                    }
                }
            }
            if *overflow == Overflow::Hidden && formatted.max_width() > content_width {
                // Horizontal clipping changes atom positions but not line
                // origins.  Preserve break properties and let the ordinary
                // owner projection rebuild the affected local metadata.
                formatted = formatted.map_lines(|_, line| line.clipped(content_width));
                change = None;
            }
            formatted = project_box_lines(
                scope,
                BoxProjectionSlot::ContentOwn,
                formatted,
                &mut change,
                vec![LineOp::OwnContent {
                    region: *region_id,
                    start: content_index_start,
                }],
            );
            if formatted.len() > content_height as usize {
                change = None;
                formatted = formatted.slice(0..content_height as usize);
            }
            let remaining = content_height as usize - formatted.len();
            let top = match vertical {
                VerticalAlign::Top => 0,
                VerticalAlign::Bottom => remaining,
                VerticalAlign::Center => remaining / 2,
            };
            let lines = frame_box_lines(
                scope,
                BoxProjectionSlot::VerticalFrame,
                formatted,
                &mut change,
                FrameSpec {
                    prefix: top,
                    suffix: remaining - top,
                    width: content_width,
                    prefix_properties: Arc::new(AtomProperties::default()),
                    suffix_properties: Arc::new(AtomProperties::default()),
                },
            );
            let collapse_ops = if simple_scroll_rendered {
                Vec::new()
            } else {
                vec![LineOp::CollapseWhitespace {
                    width: content_width,
                    region: *region_id,
                }]
            };
            let lines = project_box_lines(
                scope,
                BoxProjectionSlot::ContentCollapse,
                lines,
                &mut change,
                collapse_ops,
            );

            let mut padded = frame_box_lines(
                scope,
                BoxProjectionSlot::PaddingFrame,
                lines,
                &mut change,
                FrameSpec {
                    prefix: *padding_top as usize,
                    suffix: *padding_bottom as usize,
                    width: content_width,
                    prefix_properties: region_properties(RegionRole::PaddingTop, *region_id, None)
                        .into(),
                    suffix_properties: region_properties(
                        RegionRole::PaddingBottom,
                        *region_id,
                        None,
                    )
                    .into(),
                },
            );
            // Horizontal border paint needs a carrier even when auto content
            // and block padding have no lines.  Background alone does not.
            if padded.is_empty() && (border_top_style.is_some() || border_bottom_style.is_some()) {
                padded = LinePlan::from_lines([Line::blank(content_width)]);
                change = None;
            }
            let mut edge_ops = vec![LineOp::EdgeSpaces {
                left: *padding_left,
                left_properties: region_properties(RegionRole::PaddingLeft, *region_id, None)
                    .into(),
                right: *padding_right,
                right_properties: region_properties(RegionRole::PaddingRight, *region_id, None)
                    .into(),
            }];
            edge_ops.extend(
                [*typography_style, *foreground_style, *background_style]
                    .into_iter()
                    .flatten()
                    .map(LineOp::Style),
            );
            edge_ops.push(LineOp::EdgeSpaces {
                left: *border_left,
                left_properties: region_properties(
                    RegionRole::BorderLeft,
                    *region_id,
                    *border_left_style,
                )
                .into(),
                right: *border_right,
                right_properties: region_properties(
                    RegionRole::BorderRight,
                    *region_id,
                    *border_right_style,
                )
                .into(),
            });
            padded = project_box_lines(
                scope,
                BoxProjectionSlot::PaddingEdges,
                padded,
                &mut change,
                edge_ops,
            );
            let mut boundary_ops = Vec::new();
            boundary_ops.extend(border_top_style.map(|style| LineOp::FirstStyleRole {
                style,
                region: *region_id,
            }));
            boundary_ops.extend(border_bottom_style.map(|style| LineOp::LastStyleRole {
                style,
                region: *region_id,
            }));
            padded = project_box_lines(
                scope,
                BoxProjectionSlot::BoundaryBorders,
                padded,
                &mut change,
                boundary_ops,
            );
            padded = project_box_lines(
                scope,
                BoxProjectionSlot::SurfaceTemplate,
                padded,
                &mut change,
                surface_template_id
                    .map(LineOp::Template)
                    .into_iter()
                    .collect(),
            );
            padded = project_box_lines(
                scope,
                BoxProjectionSlot::MarginEdges,
                padded,
                &mut change,
                vec![LineOp::EdgeSpaces {
                    left: *margin_left,
                    left_properties: region_properties(RegionRole::MarginLeft, *region_id, None)
                        .into(),
                    right: *margin_right,
                    right_properties: region_properties(RegionRole::MarginRight, *region_id, None)
                        .into(),
                }],
            );
            let total_width = content_width + side_width;
            let output = frame_box_lines(
                scope,
                BoxProjectionSlot::MarginFrame,
                padded,
                &mut change,
                FrameSpec {
                    prefix: *margin_top as usize,
                    suffix: *margin_bottom as usize,
                    width: total_width,
                    prefix_properties: region_properties(RegionRole::MarginTop, *region_id, None)
                        .into(),
                    suffix_properties: region_properties(
                        RegionRole::MarginBottom,
                        *region_id,
                        None,
                    )
                    .into(),
                },
            );
            let mut rendered = Rendered::from_line_plan(output);
            rendered.empty_width = total_width;
            if !overflow_lines.is_empty() {
                let left_space = margin_left + border_left + padding_left;
                let right_space = padding_right + border_right + margin_right;
                let mut ops = foreground_style
                    .map(LineOp::Style)
                    .into_iter()
                    .collect::<Vec<_>>();
                ops.push(LineOp::EdgeSpaces {
                    left: left_space,
                    left_properties: Arc::new(AtomProperties::default()),
                    right: right_space,
                    right_properties: Arc::new(AtomProperties::default()),
                });
                overflow_lines = project_box_lines(
                    scope,
                    BoxProjectionSlot::OverflowEdges,
                    overflow_lines,
                    &mut None,
                    ops,
                );
                rendered = stack_vertical(vec![rendered, Rendered::from_line_plan(overflow_lines)]);
                change = None;
            }
            if *overflow == Overflow::Scroll && text_height > content_height {
                rendered.own_scroll_owner = true;
                rendered.lines = project_box_lines(
                    scope,
                    BoxProjectionSlot::ScrollWindow,
                    rendered.lines,
                    &mut change,
                    vec![LineOp::ScrollWindow(*region_id)],
                );
            }
            rendered.root_scroll = root_scroll;
            if let Some(change) = change {
                scope.publish_change(change);
            }
            Ok(rendered)
        }
        LayoutNode::Text {
            region_id,
            content,
            typography_style,
            foreground_style,
            surface_template_id,
            wrap_mode,
            ..
        } => {
            let width = measured_max_width(content);
            let mut lines = measured_lines(content, width, *wrap_mode);
            for (index, line) in lines.iter_mut().enumerate() {
                line.own_content(*region_id, index as i64);
                line.apply_style(*typography_style);
                line.apply_style(*foreground_style);
                line.apply_property_template(*surface_template_id);
            }
            Ok(Rendered::from_lines(lines))
        }
        LayoutNode::Row { children, .. } => {
            let child_context = LayoutContext {
                inline_auto_width_intrinsic: true,
                ..context
            };
            let rendered = children
                .iter()
                .enumerate()
                .map(|(index, child)| {
                    scope.child(LocalStep::RowChild(index), child).render(
                        child_context,
                        intrinsic,
                        None,
                    )
                })
                .collect::<Result<Vec<_>, _>>()?;
            let parts = rendered
                .into_iter()
                .map(|rendered| {
                    let width = rendered.first_width();
                    (rendered, width)
                })
                .collect();
            Ok(concat_horizontal_sized(parts, 0))
        }
        LayoutNode::Column { children, .. } => {
            if scope.is_retained() {
                return composition::render_column(scope, children, context, intrinsic);
            }
            let rendered = column_leaves(scope, children)
                .map(|child| child.render(context, intrinsic, None))
                .collect::<Result<Vec<_>, _>>()?;
            let maximum = rendered
                .iter()
                .map(Rendered::first_width)
                .max()
                .unwrap_or(0);
            let target = if intrinsic
                || context.inline_auto_width_intrinsic
                || !context.viewport_width_known
            {
                maximum
            } else {
                context.viewport_width.max(0)
            };
            let mut parts = Vec::with_capacity(rendered.len());
            for mut item in rendered {
                let extra = (target - item.first_width()).max(0);
                if extra > 0 {
                    item.lines = item
                        .lines
                        .map_lines(|_, mut line| {
                            line.push_space(extra);
                            line
                        })
                        .clear_breaks();
                }
                parts.push(item);
            }
            Ok(stack_vertical(parts))
        }
        LayoutNode::Flex {
            direction,
            wrap,
            justify,
            align_items,
            align_content,
            width,
            height,
            row_gap,
            column_gap,
            items,
            ..
        } => render_flex(
            *direction,
            *wrap,
            *justify,
            *align_items,
            *align_content,
            width,
            height,
            *row_gap,
            *column_gap,
            items,
            scope,
            context,
            intrinsic,
        ),
    }
}

// Flatten only literal Columns. In particular, a retained NodeRef remains a
// child evaluation boundary even when it resolves to an identified Column.
fn column_leaves<'a>(
    scope: &RenderScope<'a>,
    children: &'a [LayoutNode],
) -> impl Iterator<Item = RenderScope<'a>> {
    let mut stack = vec![(scope.clone(), children.iter().enumerate())];
    std::iter::from_fn(move || loop {
        let (scope, children) = stack.last_mut()?;
        match children.next() {
            Some((index, child @ LayoutNode::Column { children, .. })) => {
                let child_scope = scope.child(LocalStep::ColumnChild(index), child);
                stack.push((child_scope, children.iter().enumerate()));
            }
            Some((index, child)) => return Some(scope.child(LocalStep::ColumnChild(index), child)),
            None => {
                stack.pop();
            }
        }
    })
}
