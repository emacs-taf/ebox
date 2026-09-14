//! One immutable tree of current evaluation uses, scoped to an exact document pair.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use super::composition::ColumnState;
use super::line_plan::{BoxProjectionSlot, PlanChange, ProjectionState};
use super::source_topology::SourceAddress;
use super::{
    BoxOverride, LayoutContext, LayoutNode, LayoutTape, LocalStep, Rendered, RetainedDocument,
    SourceChanges,
};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) struct EvalWork {
    pub(crate) lookups: u64,
    pub(crate) hits: u64,
    pub(crate) body_runs: u64,
    pub(crate) records_created: u64,
    pub(crate) caller_edges_written: u64,
    pub(crate) occurrence_slots_written: u64,
    pub(crate) child_slots_visited: u64,
    pub(crate) source_path_steps_copied: u64,
    pub(crate) use_path_steps_copied: u64,
    pub(crate) dirty_seeds: u64,
    pub(crate) dirty_prefixes_visited: u64,
    pub(crate) dirty_addresses_inserted: u64,
    pub(crate) topology_lookups: u64,
    pub(crate) incoming_uses_visited: u64,
    pub(crate) height_queries: u64,
    pub(crate) child_use_nodes_created: u64,
    pub(crate) child_use_nodes_visited: u64,
    pub(crate) dirty_routes_written: u64,
    pub(crate) dirty_routes_visited: u64,
    pub(crate) column_shape_steps_visited: u64,
    pub(crate) column_slots_built: u64,
    pub(crate) column_slots_updated: u64,
    pub(crate) column_tree_nodes_created: u64,
    pub(crate) column_tree_nodes_visited: u64,
    pub(crate) column_full_rebuilds: u64,
    pub(crate) scroll_producer_lines_encoded: u64,
    pub(crate) scroll_producer_chars_encoded: u64,
    pub(crate) scroll_producer_reuses: u64,
}

thread_local! {
    static WORK: Cell<EvalWork> = Cell::new(EvalWork::default());
}

impl EvalWork {
    pub(crate) fn accumulate(&mut self, other: Self) {
        macro_rules! add {
            ($($field:ident),+ $(,)?) => { $(self.$field = self.$field.checked_add(other.$field)
                .expect("native evaluation work counter overflow");)+ };
        }
        add!(
            lookups,
            hits,
            body_runs,
            records_created,
            caller_edges_written,
            occurrence_slots_written,
            child_slots_visited,
            source_path_steps_copied,
            use_path_steps_copied,
            dirty_seeds,
            dirty_prefixes_visited,
            dirty_addresses_inserted,
            topology_lookups,
            incoming_uses_visited,
            height_queries,
            child_use_nodes_created,
            child_use_nodes_visited,
            dirty_routes_written,
            dirty_routes_visited,
            column_shape_steps_visited,
            column_slots_built,
            column_slots_updated,
            column_tree_nodes_created,
            column_tree_nodes_visited,
            column_full_rebuilds,
            scroll_producer_lines_encoded,
            scroll_producer_chars_encoded,
            scroll_producer_reuses
        );
    }
}

pub(crate) fn reset_work() {
    WORK.set(EvalWork::default());
}
pub(crate) fn work() -> EvalWork {
    WORK.get()
}

pub(super) fn record(delta: EvalWork) {
    let mut work = WORK.get();
    work.accumulate(delta);
    WORK.set(work);
}

pub(super) fn record_height_query() {
    record(EvalWork {
        height_queries: 1,
        ..EvalWork::default()
    });
}

#[derive(Clone, Debug)]
pub(super) struct SourceView<'a> {
    pub(super) node: &'a LayoutNode,
    pub(super) address: SourceAddress,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum Phase {
    FlexMeasure,
    FlexMinWidth,
    FlexAutoMinContent,
    FlexMaxWidth,
    FlexBasisContent,
    FlexBasisWidth,
    ContentIntrinsic,
    FlexCrossProbe,
    FlexFinal,
    GridIntrinsic,
    GridWidthProbe,
    GridFinal,
    WindowFull,
    WindowFallback,
    WindowChildFull,
    WindowChildPartial,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum UseStep {
    Child(LocalStep),
    Phase(Phase),
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct UseSlot {
    path: Vec<UseStep>,
    occurrence: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct EvalRequest {
    context: LayoutContext,
    intrinsic: bool,
    size_override: Option<BoxOverride>,
    complete_scroll_effects: bool,
}

#[derive(Debug)]
pub(super) struct EvalRecord {
    source: SourceAddress,
    request: EvalRequest,
    rendered: Rendered,
    children: ChildUses,
    column: Option<Arc<ColumnState>>,
    projections: BTreeMap<BoxProjectionSlot, Arc<ProjectionState>>,
}

/// Persistent caller-local map. Path copying writes only the search path; keys
/// and current child records remain shared. There is no historical use table.
#[derive(Clone, Debug, Default)]
struct ChildUses(Option<Arc<UseNode>>);

#[derive(Debug)]
struct UseNode {
    slot: Arc<UseSlot>,
    value: Arc<EvalRecord>,
    left: ChildUses,
    right: ChildUses,
    height: u32,
    len: usize,
    scroll_owners: u8,
    final_use: bool,
}

impl ChildUses {
    fn from_fresh(entries: BTreeMap<UseSlot, Arc<EvalRecord>>) -> Self {
        fn build(
            entries: &mut impl Iterator<Item = (UseSlot, Arc<EvalRecord>)>,
            count: usize,
        ) -> ChildUses {
            if count == 0 {
                return ChildUses::default();
            }
            let middle = count / 2;
            let left = build(entries, middle);
            let (slot, value) = entries.next().expect("fresh caller-use count");
            let right = build(entries, count - middle - 1);
            ChildUses::node(Arc::new(slot), value, left, right)
        }
        let count = entries.len();
        build(&mut entries.into_iter(), count)
    }

    fn height(&self) -> u32 {
        self.0.as_ref().map_or(0, |node| node.height)
    }

    fn len(&self) -> usize {
        self.0.as_ref().map_or(0, |node| node.len)
    }

    fn scroll_owners(&self) -> u8 {
        self.0.as_ref().map_or(0, |node| node.scroll_owners)
    }

    fn node(slot: Arc<UseSlot>, value: Arc<EvalRecord>, left: Self, right: Self) -> Self {
        record(EvalWork {
            child_use_nodes_created: 1,
            ..EvalWork::default()
        });
        let final_use = !slot.path.iter().any(|step| {
            matches!(
                step,
                UseStep::Phase(
                    Phase::FlexMeasure
                        | Phase::FlexMinWidth
                        | Phase::FlexAutoMinContent
                        | Phase::FlexMaxWidth
                        | Phase::FlexBasisContent
                        | Phase::FlexBasisWidth
                        | Phase::ContentIntrinsic
                        | Phase::FlexCrossProbe
                        | Phase::GridIntrinsic
                        | Phase::GridWidthProbe
                )
            )
        });
        let incomplete_window = slot
            .path
            .iter()
            .any(|step| matches!(step, UseStep::Phase(Phase::WindowChildPartial)));
        let scroll_owners = (left.scroll_owners()
            + right.scroll_owners()
            + if final_use {
                if incomplete_window {
                    2
                } else {
                    value.rendered.scroll_owners
                }
            } else {
                0
            })
        .min(2);
        Self(Some(Arc::new(UseNode {
            slot,
            value,
            height: 1 + left.height().max(right.height()),
            len: 1 + left.len() + right.len(),
            scroll_owners,
            final_use,
            left,
            right,
        })))
    }

    fn balanced(slot: Arc<UseSlot>, value: Arc<EvalRecord>, left: Self, right: Self) -> Self {
        if left.height() > right.height() + 1 {
            let root = left.0.as_ref().expect("left-heavy caller tree");
            if root.left.height() >= root.right.height() {
                return Self::node(
                    Arc::clone(&root.slot),
                    Arc::clone(&root.value),
                    root.left.clone(),
                    Self::node(slot, value, root.right.clone(), right),
                );
            }
            let middle = root.right.0.as_ref().expect("left-right caller tree");
            return Self::node(
                Arc::clone(&middle.slot),
                Arc::clone(&middle.value),
                Self::node(
                    Arc::clone(&root.slot),
                    Arc::clone(&root.value),
                    root.left.clone(),
                    middle.left.clone(),
                ),
                Self::node(slot, value, middle.right.clone(), right),
            );
        }
        if right.height() > left.height() + 1 {
            let root = right.0.as_ref().expect("right-heavy caller tree");
            if root.right.height() >= root.left.height() {
                return Self::node(
                    Arc::clone(&root.slot),
                    Arc::clone(&root.value),
                    Self::node(slot, value, left, root.left.clone()),
                    root.right.clone(),
                );
            }
            let middle = root.left.0.as_ref().expect("right-left caller tree");
            return Self::node(
                Arc::clone(&middle.slot),
                Arc::clone(&middle.value),
                Self::node(slot, value, left, middle.left.clone()),
                Self::node(
                    Arc::clone(&root.slot),
                    Arc::clone(&root.value),
                    middle.right.clone(),
                    root.right.clone(),
                ),
            );
        }
        Self::node(slot, value, left, right)
    }

    fn get(&self, slot: &UseSlot) -> Option<&Arc<EvalRecord>> {
        let mut current = self.0.as_deref();
        while let Some(node) = current {
            record(EvalWork {
                child_use_nodes_visited: 1,
                ..EvalWork::default()
            });
            match slot.cmp(&node.slot) {
                std::cmp::Ordering::Less => current = node.left.0.as_deref(),
                std::cmp::Ordering::Greater => current = node.right.0.as_deref(),
                std::cmp::Ordering::Equal => return Some(&node.value),
            }
        }
        None
    }

    fn inserted(&self, slot: Arc<UseSlot>, value: Arc<EvalRecord>) -> Self {
        let Some(node) = &self.0 else {
            return Self::node(slot, value, Self::default(), Self::default());
        };
        record(EvalWork {
            child_use_nodes_visited: 1,
            ..EvalWork::default()
        });
        match slot.cmp(&node.slot) {
            std::cmp::Ordering::Less => Self::balanced(
                Arc::clone(&node.slot),
                Arc::clone(&node.value),
                node.left.inserted(slot, value),
                node.right.clone(),
            ),
            std::cmp::Ordering::Greater => Self::balanced(
                Arc::clone(&node.slot),
                Arc::clone(&node.value),
                node.left.clone(),
                node.right.inserted(slot, value),
            ),
            std::cmp::Ordering::Equal => Self::node(
                Arc::clone(&node.slot),
                value,
                node.left.clone(),
                node.right.clone(),
            ),
        }
    }
}

impl EvalRecord {
    fn collect_scroll_plans(&self, plans: &mut super::ScrollPlans) -> Result<(), String> {
        if let Some(plan) = &self.rendered.scroll_plan {
            if plans.insert(plan.region_id, Arc::clone(plan)).is_some() {
                return Err("Native scroll owner has multiple final layout uses".to_owned());
            }
        } else if self.rendered.own_scroll_owner {
            return Err("Native scroll container requires complete content geometry".to_owned());
        }
        self.children.collect_scroll_plans(plans)
    }
}

impl ChildUses {
    fn collect_scroll_plans(&self, plans: &mut super::ScrollPlans) -> Result<(), String> {
        let Some(node) = self.0.as_ref().filter(|node| node.scroll_owners != 0) else {
            return Ok(());
        };
        node.left.collect_scroll_plans(plans)?;
        if node.final_use {
            if node
                .slot
                .path
                .iter()
                .any(|step| matches!(step, UseStep::Phase(Phase::WindowChildPartial)))
            {
                return Err(
                    "Native scroll layout requires complete child window effects".to_owned(),
                );
            }
            node.value.collect_scroll_plans(plans)?;
        }
        node.right.collect_scroll_plans(plans)
    }
}

/// Full evaluation uses a mutable fresh collector, then freezes exactly N nodes.
/// A proven sparse Column starts from an immutable current root and path-copies.
#[derive(Debug)]
enum BuildingUses {
    Fresh(BTreeMap<UseSlot, Arc<EvalRecord>>),
    Sparse(ChildUses),
}

impl Default for BuildingUses {
    fn default() -> Self {
        Self::Fresh(BTreeMap::new())
    }
}

impl BuildingUses {
    fn len(&self) -> usize {
        match self {
            Self::Fresh(entries) => entries.len(),
            Self::Sparse(entries) => entries.len(),
        }
    }

    fn insert(&mut self, slot: UseSlot, value: Arc<EvalRecord>) {
        match self {
            Self::Fresh(entries) => assert!(
                entries.insert(slot, value).is_none(),
                "unique caller use slot"
            ),
            Self::Sparse(entries) => *entries = entries.inserted(Arc::new(slot), value),
        }
    }

    fn finish(self) -> ChildUses {
        match self {
            Self::Fresh(entries) => ChildUses::from_fresh(entries),
            Self::Sparse(entries) => entries,
        }
    }
}

#[derive(Debug)]
pub(super) struct RenderedChange {
    pub(super) rendered: Rendered,
    pub(super) change: Option<PlanChange>,
    pub(super) record: Option<Arc<EvalRecord>>,
}

/// Owns the current document and current evaluation tree, never a previous frame.
#[derive(Debug)]
pub(crate) struct RetainedFrame {
    document: Arc<RetainedDocument>,
    root: Arc<EvalRecord>,
    scroll_plans: super::ScrollPlans,
}

impl RetainedFrame {
    pub(crate) fn scroll_plans(&self) -> Option<&super::ScrollPlans> {
        self.root
            .request
            .complete_scroll_effects
            .then_some(&self.scroll_plans)
    }
    pub(crate) fn materialize_tape(&self) -> LayoutTape {
        self.root
            .rendered
            .clone()
            .into_tape(self.document.style_count)
    }
}

#[derive(Debug)]
struct BuildingRecord {
    slot: UseSlot,
    source: SourceAddress,
    request: EvalRequest,
    previous: Option<Arc<EvalRecord>>,
    children: BuildingUses,
    occurrences: BTreeMap<Vec<UseStep>, usize>,
    column: Option<Arc<ColumnState>>,
    projections: BTreeMap<BoxProjectionSlot, Arc<ProjectionState>>,
    pending_change: Option<PlanChange>,
}

#[derive(Debug)]
struct RenderTxn {
    previous: Option<Arc<EvalRecord>>,
    dirty: DirtySources,
    same_shape: bool,
    stack: Vec<BuildingRecord>,
    root: Option<Arc<EvalRecord>>,
    complete_scroll_effects: bool,
}

impl RenderTxn {
    fn begin(
        &mut self,
        source: &SourceAddress,
        path: &[UseStep],
        request: EvalRequest,
    ) -> Option<RenderedChange> {
        record(EvalWork {
            lookups: 1,
            ..EvalWork::default()
        });
        let (slot, previous) = if let Some(parent) = self.stack.last_mut() {
            let occurrence = parent.occurrences.entry(path.to_vec()).or_default();
            let slot = UseSlot {
                path: path.to_vec(),
                occurrence: *occurrence,
            };
            *occurrence += 1;
            record(EvalWork {
                occurrence_slots_written: 1,
                use_path_steps_copied: (path.len() * 2) as u64,
                ..EvalWork::default()
            });
            let previous = parent
                .previous
                .as_ref()
                .and_then(|old| old.children.get(&slot))
                .cloned();
            (slot, previous)
        } else {
            (
                UseSlot {
                    path: Vec::new(),
                    occurrence: 0,
                },
                self.previous.clone(),
            )
        };
        if let Some(old) = previous.as_ref().filter(|old| {
            old.source == *source && old.request == request && !self.dirty.contains_key(source)
        }) {
            record(EvalWork {
                hits: 1,
                ..EvalWork::default()
            });
            let result = RenderedChange {
                rendered: old.rendered.clone(),
                change: Some(PlanChange::same(&old.rendered.lines)),
                record: Some(Arc::clone(old)),
            };
            self.attach(slot, Arc::clone(old));
            return Some(result);
        }
        record(EvalWork {
            body_runs: 1,
            ..EvalWork::default()
        });
        self.stack.push(BuildingRecord {
            slot,
            source: source.clone(),
            request,
            previous,
            children: BuildingUses::default(),
            occurrences: BTreeMap::new(),
            column: None,
            projections: BTreeMap::new(),
            pending_change: None,
        });
        None
    }

    fn finish(&mut self, rendered: Result<Rendered, String>) -> Result<RenderedChange, String> {
        let current = self.stack.pop().expect("native evaluation builder stack");
        let mut rendered = rendered?;
        let children = current.children.finish();
        let child_owners = children.scroll_owners();
        rendered.scroll_owners = (child_owners
            + u8::from(rendered.own_scroll_owner || rendered.scroll_plan.is_some()))
        .min(2);
        let change = current.previous.as_ref().map(|previous| {
            current
                .pending_change
                .filter(|change| change.applies_to(&previous.rendered.lines, &rendered.lines))
                .unwrap_or_else(|| {
                    PlanChange::replace_all(&previous.rendered.lines, &rendered.lines)
                })
        });
        record(EvalWork {
            records_created: 1,
            ..EvalWork::default()
        });
        let retained = Arc::new(EvalRecord {
            source: current.source,
            request: current.request,
            rendered: rendered.clone(),
            children,
            column: current.column,
            projections: current.projections,
        });
        self.attach(current.slot, Arc::clone(&retained));
        Ok(RenderedChange {
            rendered,
            change,
            record: Some(retained),
        })
    }

    fn attach(&mut self, slot: UseSlot, record: Arc<EvalRecord>) {
        if let Some(parent) = self.stack.last_mut() {
            record_work_edge();
            parent.children.insert(slot, record);
        } else {
            self.root = Some(record);
        }
    }
}

fn record_work_edge() {
    record(EvalWork {
        caller_edges_written: 1,
        ..EvalWork::default()
    });
}

/// Explicit source/callsite context. Interior mutability is transaction-local;
/// no borrow of the builder stack spans a recursive renderer call.
#[derive(Debug)]
pub(super) struct RenderScope<'a> {
    pub(super) view: SourceView<'a>,
    pub(super) resolver: Option<&'a RetainedDocument>,
    transaction: Option<&'a RefCell<RenderTxn>>,
    path: Vec<UseStep>,
}

impl Clone for RenderScope<'_> {
    fn clone(&self) -> Self {
        if self.transaction.is_some() {
            record(EvalWork {
                use_path_steps_copied: self.path.len() as u64,
                ..EvalWork::default()
            });
        }
        Self {
            view: self.view.clone(),
            resolver: self.resolver,
            transaction: self.transaction,
            path: self.path.clone(),
        }
    }
}

impl<'a> RenderScope<'a> {
    pub(super) fn uncached(node: &'a LayoutNode, resolver: Option<&'a RetainedDocument>) -> Self {
        Self {
            view: SourceView {
                node,
                address: SourceAddress {
                    owner_id: node.node_id().unwrap_or(0),
                    path: Arc::from([]),
                },
            },
            resolver,
            transaction: None,
            path: Vec::new(),
        }
    }

    pub(super) fn resolve(&self) -> Result<Self, String> {
        let mut resolved = self.clone();
        if let LayoutNode::NodeRef { node_id } = self.view.node {
            if let Some(resolver) = self.resolver {
                resolved.view = SourceView {
                    node: resolver.resolve(self.view.node)?,
                    address: SourceAddress {
                        owner_id: *node_id,
                        path: Arc::from([]),
                    },
                };
            }
        }
        Ok(resolved)
    }

    pub(super) fn child(&self, step: LocalStep, node: &'a LayoutNode) -> Self {
        if self.transaction.is_none() {
            return Self::uncached(node, self.resolver);
        }
        let mut address = self.view.address.path.to_vec();
        address.push(step);
        let mut path = self.path.clone();
        path.push(UseStep::Child(step));
        if self.transaction.is_some() {
            record(EvalWork {
                child_slots_visited: 1,
                source_path_steps_copied: address.len() as u64,
                use_path_steps_copied: path.len() as u64,
                ..EvalWork::default()
            });
        }
        Self {
            view: SourceView {
                node,
                address: SourceAddress {
                    owner_id: self.view.address.owner_id,
                    path: address.into(),
                },
            },
            resolver: self.resolver,
            transaction: self.transaction,
            path,
        }
    }

    pub(super) fn phase(&self, phase: Phase) -> Self {
        if self.transaction.is_none() {
            return self.clone();
        }
        let mut scoped = self.clone();
        scoped.path.push(UseStep::Phase(phase));
        if self.transaction.is_some() {
            record(EvalWork {
                use_path_steps_copied: 1,
                ..EvalWork::default()
            });
        }
        scoped
    }

    pub(super) fn render(
        &self,
        context: LayoutContext,
        intrinsic: bool,
        size_override: Option<BoxOverride>,
    ) -> Result<Rendered, String> {
        self.render_with_change(context, intrinsic, size_override)
            .map(|result| result.rendered)
    }

    pub(super) fn render_with_change(
        &self,
        context: LayoutContext,
        intrinsic: bool,
        size_override: Option<BoxOverride>,
    ) -> Result<RenderedChange, String> {
        let source = self.resolve()?;
        if let Some(transaction) = source.transaction {
            let request = EvalRequest {
                context,
                intrinsic,
                size_override,
                complete_scroll_effects: transaction.borrow().complete_scroll_effects,
            };
            if let Some(rendered) =
                transaction
                    .borrow_mut()
                    .begin(&source.view.address, &source.path, request)
            {
                return Ok(rendered);
            }
        }
        // Descendant slots are local to this caller, even on a parent request miss.
        let body_scope = Self {
            path: Vec::new(),
            ..source
        };
        let rendered = super::render_node_body(&body_scope, context, intrinsic, size_override);
        if let Some(transaction) = body_scope.transaction {
            return transaction.borrow_mut().finish(rendered);
        }
        rendered.map(|rendered| RenderedChange {
            rendered,
            change: None,
            record: None,
        })
    }

    pub(super) fn is_retained(&self) -> bool {
        self.transaction.is_some()
    }

    pub(super) fn complete_scroll_effects_requested(&self) -> bool {
        self.transaction
            .is_some_and(|transaction| transaction.borrow().complete_scroll_effects)
    }

    pub(super) fn previous_scroll_plan(&self) -> Option<Arc<super::ScrollPlan>> {
        let transaction = self.transaction?.borrow();
        let current = transaction.stack.last()?;
        current
            .previous
            .as_ref()
            .filter(|old| old.source == current.source)?
            .rendered
            .scroll_plan
            .clone()
    }

    pub(super) fn publish_change(&self, change: PlanChange) {
        if let Some(transaction) = self.transaction {
            transaction
                .borrow_mut()
                .stack
                .last_mut()
                .expect("current evaluation")
                .pending_change = Some(change);
        }
    }

    pub(super) fn previous_projection(
        &self,
        slot: BoxProjectionSlot,
    ) -> Option<Arc<ProjectionState>> {
        let transaction = self.transaction?.borrow();
        let current = transaction.stack.last()?;
        let previous = current
            .previous
            .as_ref()
            .filter(|old| old.source == current.source)?;
        previous.projections.get(&slot).cloned()
    }

    pub(super) fn store_projection(&self, slot: BoxProjectionSlot, state: Arc<ProjectionState>) {
        if let Some(transaction) = self.transaction {
            transaction
                .borrow_mut()
                .stack
                .last_mut()
                .expect("current evaluation")
                .projections
                .insert(slot, state);
        }
    }

    pub(super) fn previous_column(&self) -> Option<Arc<ColumnState>> {
        let transaction = self.transaction?.borrow();
        let current = transaction.stack.last()?;
        let previous = current.previous.as_ref().filter(|old| {
            transaction.same_shape
                && old.source == current.source
                && old.request == current.request
                && !transaction
                    .dirty
                    .get(&current.source)
                    .is_some_and(|route| route.local)
        })?;
        previous.column.clone()
    }

    pub(super) fn inherit_column_uses(&self) {
        let mut transaction = self.transaction.expect("retained Column").borrow_mut();
        let current = transaction.stack.last_mut().expect("current evaluation");
        assert_eq!(
            current.children.len(),
            0,
            "inherit before evaluating dirty Column slots"
        );
        current.children = BuildingUses::Sparse(
            current
                .previous
                .as_ref()
                .expect("previous Column")
                .children
                .clone(),
        );
    }

    pub(super) fn store_column(&self, state: Arc<ColumnState>) {
        self.transaction
            .expect("retained Column")
            .borrow_mut()
            .stack
            .last_mut()
            .expect("current evaluation")
            .column = Some(state);
    }

    pub(super) fn dirty_route(&self, relative: &[LocalStep]) -> DirtyRoute {
        let Some(transaction) = self.transaction else {
            return DirtyRoute::default();
        };
        let mut path = self.view.address.path.to_vec();
        path.extend_from_slice(relative);
        record(EvalWork {
            source_path_steps_copied: path.len() as u64,
            dirty_routes_visited: 1,
            ..EvalWork::default()
        });
        transaction
            .borrow()
            .dirty
            .get(&SourceAddress {
                owner_id: self.view.address.owner_id,
                path: path.into(),
            })
            .cloned()
            .unwrap_or_default()
    }
}

#[derive(Clone, Debug, Default)]
pub(super) struct DirtyRoute {
    pub(super) local: bool,
    pub(super) next: BTreeSet<LocalStep>,
}

type DirtySources = BTreeMap<SourceAddress, DirtyRoute>;

fn dirty_sources(document: &RetainedDocument, changes: &SourceChanges) -> DirtySources {
    fn mark(address: SourceAddress, dirty: &mut DirtySources, owners: &mut Vec<u64>) {
        for length in (0..=address.path.len()).rev() {
            record(EvalWork {
                dirty_prefixes_visited: 1,
                source_path_steps_copied: length as u64,
                ..EvalWork::default()
            });
            let prefix = SourceAddress {
                owner_id: address.owner_id,
                path: Arc::from(&address.path[..length]),
            };
            let is_new = !dirty.contains_key(&prefix);
            let route = dirty.entry(prefix).or_default();
            if length == address.path.len() {
                route.local = true;
            } else if route.next.insert(address.path[length]) {
                record(EvalWork {
                    dirty_routes_written: 1,
                    ..EvalWork::default()
                });
            }
            if is_new {
                record(EvalWork {
                    dirty_addresses_inserted: 1,
                    ..EvalWork::default()
                });
                if length == 0 {
                    owners.push(address.owner_id);
                }
            }
        }
    }
    let mut dirty = BTreeMap::new();
    let mut owners = Vec::new();
    changes.visit_changed_slots(|owner_id, _, _, slot, _| {
        record(EvalWork {
            dirty_seeds: 1,
            ..EvalWork::default()
        });
        let path: Arc<[LocalStep]> = match slot {
            0 => Arc::from([]),
            1 => Arc::from([LocalStep::BoxChild]),
            _ => unreachable!("validated native source slot"),
        };
        mark(SourceAddress { owner_id, path }, &mut dirty, &mut owners);
    });
    while let Some(owner) = owners.pop() {
        record(EvalWork {
            topology_lookups: 1,
            ..EvalWork::default()
        });
        for incoming in document.topology.incoming_uses(owner) {
            record(EvalWork {
                incoming_uses_visited: 1,
                ..EvalWork::default()
            });
            let mut path = incoming.parent.path.to_vec();
            path.push(incoming.child_slot);
            record(EvalWork {
                source_path_steps_copied: path.len() as u64,
                ..EvalWork::default()
            });
            mark(
                SourceAddress {
                    owner_id: incoming.parent.owner_id,
                    path: path.into(),
                },
                &mut dirty,
                &mut owners,
            );
        }
    }
    dirty
}

impl RetainedDocument {
    pub(crate) fn render_frame(
        self: &Arc<Self>,
        previous: Option<&RetainedFrame>,
        changes: Option<&SourceChanges>,
        context: LayoutContext,
        root_width_override: Option<i64>,
    ) -> Result<Arc<RetainedFrame>, String> {
        self.render_frame_mode(previous, changes, context, root_width_override, false)
    }

    pub(crate) fn render_frame_with_scroll(
        self: &Arc<Self>,
        previous: Option<&RetainedFrame>,
        changes: Option<&SourceChanges>,
        context: LayoutContext,
        root_width_override: Option<i64>,
    ) -> Result<Arc<RetainedFrame>, String> {
        self.render_frame_mode(previous, changes, context, root_width_override, true)
    }

    fn render_frame_mode(
        self: &Arc<Self>,
        previous: Option<&RetainedFrame>,
        changes: Option<&SourceChanges>,
        context: LayoutContext,
        root_width_override: Option<i64>,
        complete_scroll_effects: bool,
    ) -> Result<Arc<RetainedFrame>, String> {
        let reusable = match (previous, changes) {
            (Some(previous), Some(changes)) => {
                if !changes.applies_to(&previous.document, self) {
                    return Err(
                        "Native retained frame source changes do not match the document pair"
                            .to_owned(),
                    );
                }
                Some(previous)
            }
            (Some(previous), None) if Arc::ptr_eq(&previous.document, self) => Some(previous),
            (None, Some(changes)) if !Arc::ptr_eq(&changes.target, self) => {
                return Err(
                    "Native retained frame source changes do not match the target document"
                        .to_owned(),
                );
            }
            _ => None,
        };
        let dirty = match (reusable, changes) {
            (Some(_), Some(changes)) => dirty_sources(self, changes),
            _ => BTreeMap::new(),
        };
        let transaction = RefCell::new(RenderTxn {
            complete_scroll_effects,
            previous: reusable.map(|previous| Arc::clone(&previous.root)),
            dirty,
            same_shape: reusable
                .is_some_and(|previous| Arc::ptr_eq(&previous.document.topology, &self.topology)),
            stack: Vec::new(),
            root: None,
        });
        let root = self
            .effective_node(self.root_id)
            .ok_or_else(|| "Native retained document lost its root".to_owned())?;
        super::RESOLVER_LOOKUP_COUNT.with(|count| count.set(count.get().saturating_add(1)));
        if root_width_override.is_some() && !matches!(root, LayoutNode::Box { .. }) {
            return Err("Native root width override requires a box root".to_owned());
        }
        let scope = RenderScope {
            view: SourceView {
                node: root,
                address: SourceAddress {
                    owner_id: self.root_id,
                    path: Arc::from([]),
                },
            },
            resolver: Some(self),
            transaction: Some(&transaction),
            path: Vec::new(),
        };
        scope.render(
            context,
            false,
            root_width_override.map(|declared_width| BoxOverride {
                declared_width: Some(declared_width),
                ..BoxOverride::default()
            }),
        )?;
        let root = transaction
            .into_inner()
            .root
            .expect("native retained root evaluation");
        let mut scroll_plans = super::ScrollPlans::new();
        if complete_scroll_effects {
            root.collect_scroll_plans(&mut scroll_plans)?;
        }
        Ok(Arc::new(RetainedFrame {
            document: Arc::clone(self),
            root,
            scroll_plans,
        }))
    }
}
