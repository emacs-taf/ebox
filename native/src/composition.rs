//! Current Column slots and their persistent composition. Shape contains only
//! original structural paths; target nodes are read from the current document.

use std::sync::Arc;

use super::evaluation::{record, EvalRecord, EvalWork, RenderScope, RenderedChange};
use super::line_plan::{ChangeKind, LineOp, LinePlan, LineSplice, PlanChange, ProjectionState};
use super::{LayoutContext, LayoutNode, LocalStep, Rendered};

#[derive(Debug, Default)]
struct ShapeRoute {
    slot: Option<usize>,
    next: Box<[(LocalStep, ShapeRoute)]>,
}

#[derive(Debug)]
struct ColumnShape {
    paths: Box<[Arc<[LocalStep]>]>,
    routes: ShapeRoute,
}

impl ColumnShape {
    fn new(paths: Vec<Arc<[LocalStep]>>) -> Arc<Self> {
        // column_leaves supplies paths in original lexicographic order. Freeze
        // each prefix group once; updates only binary-search these shared arrays.
        fn build(paths: &[Arc<[LocalStep]>], first: usize, depth: usize) -> ShapeRoute {
            if paths.first().is_some_and(|path| path.len() == depth) {
                assert_eq!(paths.len(), 1, "one leaf at each original Column path");
                return ShapeRoute {
                    slot: Some(first),
                    next: Box::new([]),
                };
            }
            let mut next = Vec::new();
            let mut start = 0;
            while start < paths.len() {
                let step = paths[start][depth];
                let mut end = start + 1;
                while end < paths.len() && paths[end][depth] == step {
                    end += 1;
                }
                record(EvalWork {
                    column_shape_steps_visited: (end - start) as u64,
                    ..EvalWork::default()
                });
                next.push((step, build(&paths[start..end], first + start, depth + 1)));
                start = end;
            }
            ShapeRoute {
                slot: None,
                next: next.into_boxed_slice(),
            }
        }
        let routes = build(&paths, 0, 0);
        Arc::new(Self {
            paths: paths.into_boxed_slice(),
            routes,
        })
    }

    fn dirty_slots(&self, scope: &RenderScope<'_>) -> Vec<usize> {
        fn collect(
            route: &ShapeRoute,
            scope: &RenderScope<'_>,
            path: &mut Vec<LocalStep>,
            all: bool,
            slots: &mut Vec<usize>,
        ) {
            record(EvalWork {
                column_shape_steps_visited: 1,
                ..EvalWork::default()
            });
            if let Some(slot) = route.slot {
                slots.push(slot);
                return;
            }
            let dirty = scope.dirty_route(path);
            if all || dirty.local {
                for (step, child) in &route.next {
                    path.push(*step);
                    collect(child, scope, path, true, slots);
                    path.pop();
                }
            } else {
                for step in dirty.next {
                    if let Ok(index) = route.next.binary_search_by_key(&step, |(key, _)| *key) {
                        path.push(step);
                        collect(&route.next[index].1, scope, path, false, slots);
                        path.pop();
                    }
                }
            }
        }
        let mut slots = Vec::new();
        collect(&self.routes, scope, &mut Vec::new(), false, &mut slots);
        slots
    }

    fn scope<'a>(&self, scope: &RenderScope<'a>, index: usize) -> Result<RenderScope<'a>, String> {
        let mut result = scope.clone();
        for step in self.paths[index].iter() {
            record(EvalWork {
                column_shape_steps_visited: 1,
                ..EvalWork::default()
            });
            let (LayoutNode::Column { children, .. }, LocalStep::ColumnChild(index)) =
                (result.view.node, step)
            else {
                return Err("Native retained Column shape lost its original path".to_owned());
            };
            let child = children
                .get(*index)
                .ok_or_else(|| "Native retained Column shape lost its child slot".to_owned())?;
            result = result.child(*step, child);
        }
        Ok(result)
    }
}

#[derive(Debug)]
struct ColumnSlot {
    record: Option<Arc<EvalRecord>>,
    raw: LinePlan,
    empty_width: i64,
    normalized: LinePlan,
    projection: Option<Arc<ProjectionState>>,
}

impl ColumnSlot {
    fn normalize(
        raw: LinePlan,
        empty_width: i64,
        child: Option<Arc<EvalRecord>>,
        proof: Option<&PlanChange>,
        target: i64,
        previous: Option<&Self>,
    ) -> (Arc<Self>, Option<PlanChange>) {
        let extra = (target - raw.first_width()).max(0);
        let (normalized, projection, change) = if extra == 0 {
            let change = previous.map(|old| {
                proof
                    .filter(|proof| proof.applies_to(&old.normalized, &raw))
                    .cloned()
                    .unwrap_or_else(|| PlanChange::replace_all(&old.normalized, &raw))
            });
            (raw.clone(), None, change)
        } else {
            let ops = Arc::from([LineOp::AppendSpace(extra), LineOp::ClearBreaks]);
            if let Some(old) = previous.and_then(|old| old.projection.as_ref()) {
                let update = old.update(raw.clone(), proof, ops);
                (
                    update.state.plan().clone(),
                    Some(update.state),
                    Some(update.change),
                )
            } else {
                let projection = ProjectionState::new(raw.clone(), ops);
                let normalized = projection.plan().clone();
                let change =
                    previous.map(|old| PlanChange::replace_all(&old.normalized, &normalized));
                (normalized, Some(projection), change)
            }
        };
        (
            Arc::new(Self {
                record: child,
                raw,
                empty_width,
                normalized,
                projection,
            }),
            change,
        )
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct ColumnMeasure {
    slots: usize,
    lines: usize,
    max_first: i64,
    max_width: i64,
    max_width_minus_first: Option<i64>,
    first_nonempty: Option<i64>,
}

impl ColumnMeasure {
    fn leaf(slot: &ColumnSlot) -> Self {
        let first = if slot.raw.is_empty() {
            slot.empty_width
        } else {
            slot.raw.first_width()
        };
        let width = slot.raw.max_width();
        Self {
            slots: 1,
            lines: slot.raw.len(),
            max_first: first,
            max_width: width,
            max_width_minus_first: (!slot.raw.is_empty()).then_some(width - first),
            first_nonempty: (!slot.raw.is_empty()).then_some(first),
        }
    }

    fn combine(self, other: Self) -> Self {
        Self {
            slots: self.slots + other.slots,
            lines: self.lines + other.lines,
            max_first: self.max_first.max(other.max_first),
            max_width: self.max_width.max(other.max_width),
            max_width_minus_first: self.max_width_minus_first.max(other.max_width_minus_first),
            first_nonempty: self.first_nonempty.or(other.first_nonempty),
        }
    }

    fn normalized_max(self, target: i64) -> i64 {
        self.max_width_minus_first
            .map_or(0, |delta| self.max_width.max(target + delta))
    }
}

#[derive(Debug)]
enum ColumnNode {
    Leaf {
        slot: Arc<ColumnSlot>,
        measure: ColumnMeasure,
    },
    Branch {
        left: Arc<Self>,
        right: Arc<Self>,
        measure: ColumnMeasure,
        lines: LinePlan,
    },
}

impl ColumnNode {
    fn leaf(slot: Arc<ColumnSlot>) -> Arc<Self> {
        record(EvalWork {
            column_tree_nodes_created: 1,
            ..EvalWork::default()
        });
        Arc::new(Self::Leaf {
            measure: ColumnMeasure::leaf(&slot),
            slot,
        })
    }

    fn branch(left: Arc<Self>, right: Arc<Self>, previous: Option<&Self>) -> Arc<Self> {
        record(EvalWork {
            column_tree_nodes_created: 1,
            ..EvalWork::default()
        });
        let lines = match previous {
            Some(Self::Branch {
                left: old_left,
                right: old_right,
                lines,
                ..
            }) if left.lines().ptr_eq(old_left.lines())
                && right.lines().ptr_eq(old_right.lines()) =>
            {
                lines.clone()
            }
            _ => left.lines().concat(right.lines()),
        };
        Arc::new(Self::Branch {
            measure: left.measure().combine(right.measure()),
            left,
            right,
            lines,
        })
    }

    fn build(slots: &[Arc<ColumnSlot>]) -> Option<Arc<Self>> {
        match slots.len() {
            0 => None,
            1 => Some(Self::leaf(Arc::clone(&slots[0]))),
            count => {
                let mid = count / 2;
                Some(Self::branch(
                    Self::build(&slots[..mid]).unwrap(),
                    Self::build(&slots[mid..]).unwrap(),
                    None,
                ))
            }
        }
    }

    fn measure(&self) -> ColumnMeasure {
        match self {
            Self::Leaf { measure, .. } | Self::Branch { measure, .. } => *measure,
        }
    }

    fn lines(&self) -> &LinePlan {
        match self {
            Self::Leaf { slot, .. } => &slot.normalized,
            Self::Branch { lines, .. } => lines,
        }
    }

    fn slot(&self, index: usize) -> &Arc<ColumnSlot> {
        record(EvalWork {
            column_tree_nodes_visited: 1,
            ..EvalWork::default()
        });
        match self {
            Self::Leaf { slot, .. } => {
                assert_eq!(index, 0);
                slot
            }
            Self::Branch { left, right, .. } => {
                let left_len = left.measure().slots;
                if index < left_len {
                    left.slot(index)
                } else {
                    right.slot(index - left_len)
                }
            }
        }
    }

    fn prefix_lines(&self, end: usize) -> usize {
        record(EvalWork {
            column_tree_nodes_visited: 1,
            ..EvalWork::default()
        });
        if end == 0 {
            return 0;
        }
        if end == self.measure().slots {
            return self.measure().lines;
        }
        match self {
            Self::Leaf { .. } => unreachable!("validated Column prefix"),
            Self::Branch { left, right, .. } => {
                let left_len = left.measure().slots;
                if end <= left_len {
                    left.prefix_lines(end)
                } else {
                    left.measure().lines + right.prefix_lines(end - left_len)
                }
            }
        }
    }

    fn replace(&self, index: usize, slot: Arc<ColumnSlot>) -> Arc<Self> {
        record(EvalWork {
            column_tree_nodes_visited: 1,
            ..EvalWork::default()
        });
        match self {
            Self::Leaf { .. } => {
                assert_eq!(index, 0);
                Self::leaf(slot)
            }
            Self::Branch { left, right, .. } => {
                let left_len = left.measure().slots;
                if index < left_len {
                    Self::branch(left.replace(index, slot), Arc::clone(right), Some(self))
                } else {
                    Self::branch(
                        Arc::clone(left),
                        right.replace(index - left_len, slot),
                        Some(self),
                    )
                }
            }
        }
    }

    fn retarget(&self, target: i64) -> Arc<Self> {
        record(EvalWork {
            column_tree_nodes_visited: 1,
            ..EvalWork::default()
        });
        match self {
            Self::Leaf { slot, .. } => {
                record(EvalWork {
                    column_slots_updated: 1,
                    ..EvalWork::default()
                });
                let same = PlanChange::same(&slot.raw);
                Self::leaf(
                    ColumnSlot::normalize(
                        slot.raw.clone(),
                        slot.empty_width,
                        slot.record.clone(),
                        Some(&same),
                        target,
                        Some(slot),
                    )
                    .0,
                )
            }
            Self::Branch { left, right, .. } => {
                Self::branch(left.retarget(target), right.retarget(target), Some(self))
            }
        }
    }
}

#[derive(Debug)]
pub(super) struct ColumnState {
    shape: Arc<ColumnShape>,
    root: Option<Arc<ColumnNode>>,
    target: i64,
    lines: LinePlan,
}

#[cfg(test)]
impl ColumnState {
    pub(super) fn shares_slot(&self, other: &Self, index: usize) -> bool {
        Arc::ptr_eq(
            self.root.as_ref().unwrap().slot(index),
            other.root.as_ref().unwrap().slot(index),
        )
    }

    pub(super) fn shares_shape(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.shape, &other.shape)
    }
}

fn target_width(context: LayoutContext, intrinsic: bool, maximum: i64) -> i64 {
    if intrinsic || context.inline_auto_width_intrinsic || !context.viewport_width_known {
        maximum
    } else {
        context.viewport_width.max(0)
    }
}

fn output(root: Option<&Arc<ColumnNode>>, previous: Option<&ColumnState>) -> LinePlan {
    if let Some(root) = root.filter(|root| root.measure().lines > 0) {
        return root.lines().clone();
    }
    if let Some(previous) = previous.filter(|previous| {
        previous
            .root
            .as_ref()
            .is_none_or(|root| root.measure().lines == 0)
    }) {
        return previous.lines.clone();
    }
    LinePlan::default()
}

// A concatenation owns its joining break, including the former last line when
// an empty boundary moves. Include that predecessor in each changed span.
fn include_join_boundaries(splices: Vec<LineSplice>) -> Vec<LineSplice> {
    let mut result: Vec<LineSplice> = Vec::with_capacity(splices.len());
    for mut splice in splices {
        if splice.old.start == 0 || splice.new.start == 0 {
            splice.old.start = 0;
            splice.new.start = 0;
        } else {
            splice.old.start -= 1;
            splice.new.start -= 1;
        }
        if let Some(previous) = result.last_mut().filter(|previous| {
            splice.old.start <= previous.old.end || splice.new.start <= previous.new.end
        }) {
            previous.old.end = previous.old.end.max(splice.old.end);
            previous.new.end = previous.new.end.max(splice.new.end);
        } else {
            result.push(splice);
        }
    }
    result
}

pub(super) fn render_column<'a>(
    scope: &RenderScope<'a>,
    children: &'a [LayoutNode],
    context: LayoutContext,
    intrinsic: bool,
) -> Result<Rendered, String> {
    let state = if let Some(previous) = scope.previous_column() {
        let dirty = previous.shape.dirty_slots(scope);
        scope.inherit_column_uses();
        let mut root = previous.root.clone();
        let mut changes = Vec::with_capacity(dirty.len());
        for index in dirty {
            let child_scope = previous.shape.scope(scope, index)?;
            let result = child_scope.render_with_change(context, intrinsic, None)?;
            let old = previous
                .root
                .as_ref()
                .expect("dirty Column has slots")
                .slot(index);
            let (slot, change) = ColumnSlot::normalize(
                result.rendered.lines,
                result.rendered.empty_width,
                result.record,
                result.change.as_ref(),
                previous.target,
                Some(old),
            );
            record(EvalWork {
                column_slots_updated: 1,
                ..EvalWork::default()
            });
            root = Some(
                root.as_ref()
                    .expect("dirty Column root")
                    .replace(index, slot),
            );
            changes.push((index, change.expect("previous normalized child")));
        }
        let target = target_width(
            context,
            intrinsic,
            root.as_ref().map_or(0, |root| root.measure().max_first),
        );
        if target != previous.target {
            record(EvalWork {
                column_full_rebuilds: 1,
                ..EvalWork::default()
            });
            root = root.map(|root| root.retarget(target));
        }
        let lines = output(root.as_ref(), Some(&previous));
        let change = if lines.ptr_eq(&previous.lines) {
            PlanChange::same(&lines)
        } else if target != previous.target
            || previous
                .root
                .as_ref()
                .is_none_or(|root| root.measure().lines == 0)
            || root.as_ref().is_none_or(|root| root.measure().lines == 0)
        {
            PlanChange::replace_all(&previous.lines, &lines)
        } else {
            let old_root = previous.root.as_ref().unwrap();
            let new_root = root.as_ref().unwrap();
            let mut splices = Vec::new();
            for (index, change) in changes {
                let old_offset = old_root.prefix_lines(index);
                let new_offset = new_root.prefix_lines(index);
                match change.kind() {
                    ChangeKind::Same => {}
                    ChangeKind::Splices(parts) => {
                        splices.extend(parts.iter().map(|part| LineSplice {
                            old: old_offset + part.old.start..old_offset + part.old.end,
                            new: new_offset + part.new.start..new_offset + part.new.end,
                        }));
                    }
                    ChangeKind::ReplaceAll => splices.push(LineSplice {
                        old: old_offset..old_offset + old_root.slot(index).raw.len(),
                        new: new_offset..new_offset + new_root.slot(index).raw.len(),
                    }),
                }
            }
            PlanChange::splices(&previous.lines, &lines, include_join_boundaries(splices))
        };
        scope.publish_change(change);
        Arc::new(ColumnState {
            shape: Arc::clone(&previous.shape),
            root,
            target,
            lines,
        })
    } else {
        record(EvalWork {
            column_full_rebuilds: 1,
            ..EvalWork::default()
        });
        let mut paths = Vec::new();
        let mut results = Vec::new();
        for child in super::column_leaves(scope, children) {
            let path = &child.view.address.path[scope.view.address.path.len()..];
            record(EvalWork {
                source_path_steps_copied: path.len() as u64,
                column_slots_built: 1,
                ..EvalWork::default()
            });
            paths.push(Arc::from(path));
            results.push(child.render_with_change(context, intrinsic, None)?);
        }
        let maximum = results
            .iter()
            .map(|result| result.rendered.first_width())
            .max()
            .unwrap_or(0);
        let target = target_width(context, intrinsic, maximum);
        let slots = results
            .into_iter()
            .map(
                |RenderedChange {
                     rendered, record, ..
                 }| {
                    ColumnSlot::normalize(
                        rendered.lines,
                        rendered.empty_width,
                        record,
                        None,
                        target,
                        None,
                    )
                    .0
                },
            )
            .collect::<Vec<_>>();
        let root = ColumnNode::build(&slots);
        let lines = output(root.as_ref(), None);
        Arc::new(ColumnState {
            shape: ColumnShape::new(paths),
            root,
            target,
            lines,
        })
    };
    debug_assert_eq!(
        state
            .root
            .as_ref()
            .map_or(0, |root| root.measure().normalized_max(state.target)),
        state.lines.max_width()
    );
    let mut rendered = Rendered::from_line_plan(state.lines.clone());
    rendered.empty_width = state
        .root
        .as_ref()
        .map_or(0, |root| root.measure().max_first);
    scope.store_column(state);
    Ok(rendered)
}
