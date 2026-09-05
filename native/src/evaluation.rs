//! One immutable tree of current evaluation uses, scoped to an exact document pair.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

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
            height_queries
        );
    }
}

pub(crate) fn reset_work() {
    WORK.set(EvalWork::default());
}
pub(crate) fn work() -> EvalWork {
    WORK.get()
}

fn record(delta: EvalWork) {
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
}

#[derive(Debug)]
struct EvalRecord {
    source: SourceAddress,
    request: EvalRequest,
    rendered: Rendered,
    children: BTreeMap<UseSlot, Arc<EvalRecord>>,
}

/// Owns the current document and current evaluation tree, never a previous frame.
#[derive(Debug)]
pub(crate) struct RetainedFrame {
    document: Arc<RetainedDocument>,
    root: Arc<EvalRecord>,
}

impl RetainedFrame {
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
    children: BTreeMap<UseSlot, Arc<EvalRecord>>,
    occurrences: BTreeMap<Vec<UseStep>, usize>,
}

#[derive(Debug)]
struct RenderTxn {
    previous: Option<Arc<EvalRecord>>,
    dirty: BTreeSet<SourceAddress>,
    stack: Vec<BuildingRecord>,
    root: Option<Arc<EvalRecord>>,
}

impl RenderTxn {
    fn begin(
        &mut self,
        source: &SourceAddress,
        path: &[UseStep],
        request: EvalRequest,
    ) -> Option<Rendered> {
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
            old.source == *source && old.request == request && !self.dirty.contains(source)
        }) {
            record(EvalWork {
                hits: 1,
                ..EvalWork::default()
            });
            let rendered = old.rendered.clone();
            self.attach(slot, Arc::clone(old));
            return Some(rendered);
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
            children: BTreeMap::new(),
            occurrences: BTreeMap::new(),
        });
        None
    }

    fn finish(&mut self, rendered: &Result<Rendered, String>) {
        let current = self.stack.pop().expect("native evaluation builder stack");
        if let Ok(rendered) = rendered {
            record(EvalWork {
                records_created: 1,
                ..EvalWork::default()
            });
            self.attach(
                current.slot,
                Arc::new(EvalRecord {
                    source: current.source,
                    request: current.request,
                    rendered: rendered.clone(),
                    children: current.children,
                }),
            );
        }
    }

    fn attach(&mut self, slot: UseSlot, record: Arc<EvalRecord>) {
        if let Some(parent) = self.stack.last_mut() {
            record_work_edge();
            assert!(
                parent.children.insert(slot, record).is_none(),
                "unique caller use slot"
            );
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
        let source = self.resolve()?;
        if let Some(transaction) = source.transaction {
            let request = EvalRequest {
                context,
                intrinsic,
                size_override,
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
            transaction.borrow_mut().finish(&rendered);
        }
        rendered
    }
}

fn dirty_sources(document: &RetainedDocument, changes: &SourceChanges) -> BTreeSet<SourceAddress> {
    fn mark(address: SourceAddress, dirty: &mut BTreeSet<SourceAddress>, owners: &mut Vec<u64>) {
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
            if dirty.insert(prefix) {
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
    let mut dirty = BTreeSet::new();
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
            _ => BTreeSet::new(),
        };
        let transaction = RefCell::new(RenderTxn {
            previous: reusable.map(|previous| Arc::clone(&previous.root)),
            dirty,
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
        Ok(Arc::new(RetainedFrame {
            document: Arc::clone(self),
            root,
        }))
    }
}

#[cfg(test)]
#[path = "evaluation_tests.rs"]
mod tests;
