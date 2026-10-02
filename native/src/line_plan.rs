use std::borrow::Cow;
use std::cell::Cell;
use std::ops::Range;
use std::sync::Arc;

use crate::sequence::{Entry, Measure, Sequence, Work};

use super::{AtomProperties, Line};

#[path = "line_metrics.rs"]
mod line_metrics;
#[path = "line_ops.rs"]
mod line_ops;
use line_metrics::{LineMetric, Metrics};
pub(super) use line_ops::{BoxProjectionSlot, LineOp};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) struct LinePlanWork {
    pub(crate) sequence_nodes_created: u64,
    pub(crate) sequence_entries_written: u64,
    pub(crate) iterator_nodes_visited: u64,
    pub(crate) lines_visited: u64,
    pub(crate) line_lookups: u64,
    pub(crate) range_queries: u64,
    pub(crate) lines_mapped: u64,
    pub(crate) breaks_mapped: u64,
    pub(crate) line_clones: u64,
    pub(crate) materialized_lines: u64,
    pub(crate) materialized_breaks: u64,
    pub(crate) materialized_chars: u64,
    pub(crate) metric_nodes_created: u64,
    pub(crate) metric_entries_written: u64,
    pub(crate) metric_nodes_visited: u64,
    pub(crate) projection_lines_measured: u64,
    pub(crate) projection_nodes_created: u64,
    pub(crate) projection_fallbacks: u64,
    pub(crate) projection_initial_lines_measured: u64,
    pub(crate) projection_fallback_lines_measured: u64,
    pub(crate) projection_splice_lines_measured: u64,
    pub(crate) frame_blank_lines_created: u64,
}

thread_local! {
    static WORK: Cell<LinePlanWork> = Cell::new(LinePlanWork::default());
}

pub(crate) fn reset_work() {
    WORK.set(LinePlanWork::default());
}

pub(crate) fn work() -> LinePlanWork {
    WORK.get()
}

impl LinePlanWork {
    pub(crate) fn accumulate(&mut self, other: Self) {
        macro_rules! add {
            ($($field:ident),+ $(,)?) => {
                $(self.$field = self.$field.checked_add(other.$field)
                    .expect("native line plan work counter overflow");)+
            };
        }
        add!(
            sequence_nodes_created,
            sequence_entries_written,
            iterator_nodes_visited,
            lines_visited,
            line_lookups,
            range_queries,
            lines_mapped,
            breaks_mapped,
            line_clones,
            materialized_lines,
            materialized_breaks,
            materialized_chars,
            metric_nodes_created,
            metric_entries_written,
            metric_nodes_visited,
            projection_lines_measured,
            projection_nodes_created,
            projection_fallbacks,
            projection_initial_lines_measured,
            projection_fallback_lines_measured,
            projection_splice_lines_measured,
            frame_blank_lines_created
        );
    }
}

fn record(delta: LinePlanWork) {
    let mut work = WORK.get();
    work.accumulate(delta);
    WORK.set(work);
}

fn record_sequence(work: Work) {
    record(LinePlanWork {
        sequence_nodes_created: work.nodes_created,
        sequence_entries_written: work.entries_written,
        ..LinePlanWork::default()
    });
}

pub(super) fn record_materialized(lines: usize, chars: u64) {
    record(LinePlanWork {
        materialized_lines: lines as u64,
        materialized_breaks: lines.saturating_sub(1) as u64,
        materialized_chars: chars,
        ..LinePlanWork::default()
    });
}

pub(super) fn clone_line(line: &Line) -> Line {
    record(LinePlanWork {
        line_clones: 1,
        ..LinePlanWork::default()
    });
    line.clone()
}

#[derive(Debug)]
struct LineEntry {
    line: Line,
    // Stored even at the terminal entry, where it is not part of the output.
    // Concatenation replaces that boundary explicitly before it becomes visible.
    break_after: Arc<AtomProperties>,
}

fn entry(line: Line, break_after: Arc<AtomProperties>) -> Entry<LineEntry> {
    // One virtual newline per entry makes prefixes additive. The final newline
    // is removed by each output-range summary, including empty/zero-width lines.
    let chars = line
        .atoms
        .char_count()
        .checked_add(1)
        .expect("validated native line character count fits u64");
    let measure = Measure::new(chars, 1, line.width, line.width)
        .expect("validated native line width is nonnegative");
    Entry::new(Arc::new(LineEntry { line, break_after }), measure)
        .expect("validated native line measure")
}

#[derive(Clone, Debug, Default)]
pub(super) struct LinePlan {
    // Raw plans retain the existing packed sequence. Extended plans keep this empty.
    entries: Sequence<LineEntry>,
    extension: Option<Arc<Extension>>,
    metrics: Metrics,
    identity: Arc<()>,
}

#[derive(Debug)]
enum Extension {
    Projection {
        input: LinePlan,
        ops: Arc<[LineOp]>,
        origin: usize,
        length: usize,
    },
    Concat {
        left: LinePlan,
        right: LinePlan,
        height: u32,
    },
    Break {
        input: LinePlan,
        properties: Arc<AtomProperties>,
    },
}

#[derive(Clone, Copy)]
struct Stage<'a> {
    ops: &'a [LineOp],
    index: usize,
    length: usize,
}

pub(super) struct LineView<'a> {
    entry: &'a Arc<LineEntry>,
    stages: Vec<Stage<'a>>,
    break_override: Option<&'a AtomProperties>,
    break_stage_start: usize,
}

impl<'a> LineView<'a> {
    fn metric(&self) -> LineMetric {
        let mut metric = LineMetric::line(&self.entry.line);
        for stage in &self.stages {
            for op in stage.ops {
                metric = op.metric(metric, stage.index, stage.length);
            }
        }
        metric
    }

    pub(super) fn width(&self) -> i64 {
        self.metric().width
    }

    /// Raw lines remain borrowed. Typed programs are realized only at an explicit boundary.
    pub(super) fn materialize(&self) -> Cow<'a, Line> {
        if self.stages.is_empty() {
            return Cow::Borrowed(&self.entry.line);
        }
        let mut line = clone_line(&self.entry.line);
        for stage in &self.stages {
            for op in stage.ops {
                line = op.apply(line, stage.index, stage.length);
            }
        }
        Cow::Owned(line)
    }

    fn break_view(&self) -> BreakView<'a> {
        BreakView {
            original: self.break_override.unwrap_or(&self.entry.break_after),
            stages: self.stages[self.break_stage_start..].to_vec(),
        }
    }
}

pub(super) struct BreakView<'a> {
    original: &'a AtomProperties,
    stages: Vec<Stage<'a>>,
}

impl<'a> BreakView<'a> {
    pub(super) fn materialize(&self) -> Cow<'a, AtomProperties> {
        if self.stages.is_empty() {
            return Cow::Borrowed(self.original);
        }
        let mut properties = self.original.clone();
        for stage in &self.stages {
            if stage.index + 1 < stage.length {
                for op in stage.ops {
                    op.apply_break(&mut properties);
                }
            }
        }
        Cow::Owned(properties)
    }
}

pub(super) struct Lines<'a> {
    inner: Box<dyn Iterator<Item = LineView<'a>> + 'a>,
    remaining: usize,
}

impl<'a> Iterator for Lines<'a> {
    type Item = LineView<'a>;
    fn next(&mut self) -> Option<Self::Item> {
        let value = self.inner.next();
        if value.is_some() {
            self.remaining -= 1;
        }
        value
    }
    fn size_hint(&self) -> (usize, Option<usize>) {
        (self.remaining, Some(self.remaining))
    }
}
impl ExactSizeIterator for Lines<'_> {}

pub(super) struct LinesAndBreaks<'a> {
    lines: Lines<'a>,
}
impl<'a> Iterator for LinesAndBreaks<'a> {
    type Item = (LineView<'a>, Option<BreakView<'a>>);
    fn next(&mut self) -> Option<Self::Item> {
        let line = self.lines.next()?;
        let properties = (self.lines.len() > 0).then(|| line.break_view());
        Some((line, properties))
    }
    fn size_hint(&self) -> (usize, Option<usize>) {
        self.lines.size_hint()
    }
}
impl ExactSizeIterator for LinesAndBreaks<'_> {}

impl LinePlan {
    pub(super) fn ptr_eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.identity, &other.identity)
    }

    pub(super) fn from_lines(lines: impl IntoIterator<Item = Line>) -> Self {
        let default_break = Arc::new(AtomProperties::default());
        Self::from_entries(
            lines
                .into_iter()
                .map(|line| entry(line, Arc::clone(&default_break))),
        )
    }

    fn from_entries(entries: impl IntoIterator<Item = Entry<LineEntry>>) -> Self {
        let mut work = Work::default();
        let entries = Sequence::from_entries(entries, &mut work)
            .expect("validated native line sequence aggregates fit limits");
        record_sequence(work);
        let metrics = Metrics::from_iter(
            entries
                .iter()
                .map(|entry| LineMetric::line(&entry.value().line)),
        );
        Self {
            entries,
            metrics,
            ..Self::default()
        }
    }

    fn extended(extension: Extension, metrics: Metrics) -> Self {
        record(LinePlanWork {
            projection_nodes_created: 1,
            ..LinePlanWork::default()
        });
        Self {
            extension: Some(Arc::new(extension)),
            metrics,
            ..Self::default()
        }
    }

    pub(super) fn len(&self) -> usize {
        self.metrics.summary().count
    }
    pub(super) fn is_empty(&self) -> bool {
        self.len() == 0
    }
    pub(super) fn first_width(&self) -> i64 {
        self.metrics.summary().first_width
    }
    pub(super) fn max_width(&self) -> i64 {
        self.metrics.summary().max_width
    }
    pub(super) fn min_content_width(&self) -> i64 {
        self.metrics.summary().min_content
    }
    pub(super) fn uniform_width(&self, width: i64) -> bool {
        self.is_empty() || (self.metrics.summary().min_width == width && self.max_width() == width)
    }
    pub(super) fn all_nonempty(&self) -> bool {
        self.is_empty() || self.metrics.summary().all_nonempty
    }
    pub(super) fn height(&self) -> i64 {
        i64::try_from(self.len()).expect("validated line height")
    }

    pub(super) fn iter(&self) -> Lines<'_> {
        let inner: Box<dyn Iterator<Item = LineView<'_>>> = match self.extension.as_deref() {
            None => {
                let mut iter = self.entries.iter();
                Box::new(std::iter::from_fn(move || {
                    let before = iter.nodes_visited();
                    let value = iter.next();
                    record(LinePlanWork {
                        iterator_nodes_visited: iter.nodes_visited() - before,
                        lines_visited: u64::from(value.is_some()),
                        ..LinePlanWork::default()
                    });
                    value.map(|entry| LineView {
                        entry: entry.value(),
                        stages: Vec::new(),
                        break_override: None,
                        break_stage_start: 0,
                    })
                }))
            }
            Some(Extension::Projection {
                input,
                ops,
                origin,
                length,
            }) => {
                record(LinePlanWork {
                    iterator_nodes_visited: 1,
                    ..LinePlanWork::default()
                });
                Box::new(input.iter().enumerate().map(move |(index, mut line)| {
                    line.stages.push(Stage {
                        ops,
                        index: origin + index,
                        length: *length,
                    });
                    line
                }))
            }
            Some(Extension::Concat { left, right, .. }) => {
                record(LinePlanWork {
                    iterator_nodes_visited: 1,
                    ..LinePlanWork::default()
                });
                Box::new(left.iter().chain(right.iter()))
            }
            Some(Extension::Break { input, properties }) => {
                record(LinePlanWork {
                    iterator_nodes_visited: 1,
                    ..LinePlanWork::default()
                });
                Box::new(input.iter().map(move |mut line| {
                    line.break_override = Some(properties);
                    line.break_stage_start = line.stages.len();
                    line
                }))
            }
        };
        Lines {
            inner,
            remaining: self.len(),
        }
    }

    pub(super) fn iter_with_breaks(&self) -> LinesAndBreaks<'_> {
        LinesAndBreaks { lines: self.iter() }
    }

    pub(super) fn get(&self, index: usize) -> Option<LineView<'_>> {
        record(LinePlanWork {
            line_lookups: 1,
            ..LinePlanWork::default()
        });
        if index >= self.len() {
            return None;
        }
        match self.extension.as_deref() {
            None => self.entries.get(index).map(|entry| LineView {
                entry: entry.value(),
                stages: Vec::new(),
                break_override: None,
                break_stage_start: 0,
            }),
            Some(Extension::Projection {
                input,
                ops,
                origin,
                length,
            }) => {
                let mut line = input.get(index)?;
                line.stages.push(Stage {
                    ops,
                    index: origin + index,
                    length: *length,
                });
                Some(line)
            }
            Some(Extension::Concat { left, right, .. }) => {
                if index < left.len() {
                    left.get(index)
                } else {
                    right.get(index - left.len())
                }
            }
            Some(Extension::Break { input, properties }) => {
                let mut line = input.get(index)?;
                line.break_override = Some(properties);
                line.break_stage_start = line.stages.len();
                Some(line)
            }
        }
    }

    pub(super) fn break_after(&self, index: usize) -> Option<BreakView<'_>> {
        (index < self.len().saturating_sub(1))
            .then(|| self.get(index).expect("checked break index").break_view())
    }

    pub(super) fn prefix_chars(&self, end: usize) -> u64 {
        let chars = self.range_measure(0..end).chars;
        chars
            .checked_add(u64::from(end > 0 && end < self.len()))
            .expect("validated line prefix")
    }

    pub(super) fn range_measure(&self, range: Range<usize>) -> Measure {
        record(LinePlanWork {
            range_queries: 1,
            ..LinePlanWork::default()
        });
        let summary = self.metrics.slice(range).summary();
        Measure::new(
            summary.chars + summary.count.saturating_sub(1) as u64,
            summary.count as u64,
            summary.width_sum,
            summary.max_width,
        )
        .expect("validated line range")
    }

    pub(super) fn slice(&self, range: Range<usize>) -> Self {
        assert!(range.start <= range.end && range.end <= self.len());
        if range.start == 0 && range.end == self.len() {
            return self.clone();
        }
        if range.is_empty() {
            return Self::default();
        }
        let metrics = self.metrics.slice(range.clone());
        match self.extension.as_deref() {
            None => {
                let mut work = Work::default();
                let entries = self
                    .entries
                    .slice(range, &mut work)
                    .expect("validated line slice");
                record_sequence(work);
                Self {
                    entries,
                    metrics,
                    ..Self::default()
                }
            }
            Some(Extension::Projection {
                input,
                ops,
                origin,
                length,
            }) => Self::extended(
                Extension::Projection {
                    input: input.slice(range.clone()),
                    ops: Arc::clone(ops),
                    origin: origin + range.start,
                    length: *length,
                },
                metrics,
            ),
            Some(Extension::Concat { left, right, .. }) => {
                if range.end <= left.len() {
                    left.slice(range)
                } else if range.start >= left.len() {
                    right.slice(range.start - left.len()..range.end - left.len())
                } else {
                    left.slice(range.start..left.len())
                        .join_stored(&right.slice(0..range.end - left.len()))
                }
            }
            Some(Extension::Break { input, properties }) => Self::extended(
                Extension::Break {
                    input: input.slice(range),
                    properties: Arc::clone(properties),
                },
                metrics,
            ),
        }
    }

    pub(super) fn with_break(&self, index: usize, properties: AtomProperties) -> Self {
        let old = self.break_after(index).expect("validated break index");
        if *old.materialize() == properties {
            return self.clone();
        }
        self.set_stored_break(index, Arc::new(properties))
    }

    fn set_stored_break(&self, index: usize, properties: Arc<AtomProperties>) -> Self {
        if self.extension.is_none() {
            let old = self
                .entries
                .get(index)
                .expect("validated break replacement");
            self.replace_entry(index, entry(clone_line(&old.value().line), properties))
        } else {
            let selected = self.slice(index..index + 1);
            // The new override replaces every property of the old one. Keep
            // its current line program, without retaining the shadowed root.
            let input = match selected.extension.as_deref() {
                Some(Extension::Break { input, .. }) => input.clone(),
                _ => selected.clone(),
            };
            let replacement =
                Self::extended(Extension::Break { input, properties }, selected.metrics);
            self.slice(0..index)
                .join_stored(&replacement)
                .join_stored(&self.slice(index + 1..self.len()))
        }
    }

    fn replace_entry(&self, index: usize, entry: Entry<LineEntry>) -> Self {
        let metric = LineMetric::line(&entry.value().line);
        let mut work = Work::default();
        let entries = self
            .entries
            .replace(index, entry, &mut work)
            .expect("validated line replacement");
        record_sequence(work);
        Self {
            entries,
            metrics: self.metrics.replace(index, metric),
            ..Self::default()
        }
    }

    fn tree_height(&self) -> u32 {
        if self.is_empty() {
            return 0;
        }
        match self.extension.as_deref() {
            Some(Extension::Concat { height, .. }) => *height,
            _ => 1,
        }
    }

    fn branch(left: Self, right: Self) -> Self {
        if left.is_empty() {
            return right;
        }
        if right.is_empty() {
            return left;
        }
        let metrics = left.metrics.concat(&right.metrics);
        let height = left.tree_height().max(right.tree_height()) + 1;
        Self::extended(
            Extension::Concat {
                left,
                right,
                height,
            },
            metrics,
        )
    }

    fn children(&self) -> (&Self, &Self) {
        let Some(Extension::Concat { left, right, .. }) = self.extension.as_deref() else {
            unreachable!("balanced line branch")
        };
        (left, right)
    }

    fn balanced(left: Self, right: Self) -> Self {
        if left.tree_height() > right.tree_height() + 1 {
            let (ll, lr) = left.children();
            if ll.tree_height() >= lr.tree_height() {
                Self::branch(ll.clone(), Self::branch(lr.clone(), right))
            } else {
                let (lrl, lrr) = lr.children();
                Self::branch(
                    Self::branch(ll.clone(), lrl.clone()),
                    Self::branch(lrr.clone(), right),
                )
            }
        } else if right.tree_height() > left.tree_height() + 1 {
            let (rl, rr) = right.children();
            if rr.tree_height() >= rl.tree_height() {
                Self::branch(Self::branch(left, rl.clone()), rr.clone())
            } else {
                let (rll, rlr) = rl.children();
                Self::branch(
                    Self::branch(left, rll.clone()),
                    Self::branch(rlr.clone(), rr.clone()),
                )
            }
        } else {
            Self::branch(left, right)
        }
    }

    /// Concatenate already-authorized stored breaks without introducing a new seam.
    fn join_stored(&self, other: &Self) -> Self {
        if self.is_empty() {
            return other.clone();
        }
        if other.is_empty() {
            return self.clone();
        }
        if self.extension.is_none() && other.extension.is_none() {
            let mut work = Work::default();
            let entries = self
                .entries
                .concat(&other.entries, &mut work)
                .expect("validated line concatenation");
            record_sequence(work);
            return Self {
                entries,
                metrics: self.metrics.concat(&other.metrics),
                ..Self::default()
            };
        }
        if self.tree_height() > other.tree_height() + 1 {
            let (left, right) = self.children();
            Self::balanced(left.clone(), right.join_stored(other))
        } else if other.tree_height() > self.tree_height() + 1 {
            let (left, right) = other.children();
            Self::balanced(self.join_stored(left), right.clone())
        } else {
            Self::branch(self.clone(), other.clone())
        }
    }

    pub(super) fn concat(&self, other: &Self) -> Self {
        self.concat_with_break(other, AtomProperties::default())
    }
    pub(super) fn concat_with_break(&self, other: &Self, properties: AtomProperties) -> Self {
        if self.is_empty() {
            return other.clone();
        }
        if other.is_empty() {
            return self.clone();
        }
        self.join_stored(other)
            .with_break(self.len() - 1, properties)
    }

    /// Full fallback/oracle transform; every visited line and copy is counted.
    pub(super) fn map_lines(&self, mut map: impl FnMut(usize, Line) -> Line) -> Self {
        Self::from_entries(self.iter().enumerate().map(|(index, old)| {
            record(LinePlanWork {
                lines_mapped: 1,
                ..LinePlanWork::default()
            });
            entry(
                map(index, clone_line(&old.materialize())),
                Arc::new(old.break_view().materialize().into_owned()),
            )
        }))
    }

    pub(super) fn map_breaks(&self, mut map: impl FnMut(&mut AtomProperties)) -> Self {
        let last = self.len().saturating_sub(1);
        Self::from_entries(self.iter().enumerate().map(|(index, old)| {
            if index == last && old.stages.is_empty() && old.break_override.is_none() {
                // Keep the raw terminal entry exactly as before.
                return Entry::new(
                    Arc::clone(old.entry),
                    Measure::new(
                        old.entry.line.atoms.char_count() + 1,
                        1,
                        old.entry.line.width,
                        old.entry.line.width,
                    )
                    .expect("line measure"),
                )
                .expect("line entry");
            }
            let mut properties = old.break_view().materialize().into_owned();
            if index != last {
                map(&mut properties);
                record(LinePlanWork {
                    breaks_mapped: 1,
                    ..LinePlanWork::default()
                });
            }
            entry(clone_line(&old.materialize()), Arc::new(properties))
        }))
    }
    pub(super) fn clear_breaks(&self) -> Self {
        self.map_breaks(|properties| *properties = AtomProperties::default())
    }
}

#[derive(Clone, Debug)]
pub(super) struct LineSplice {
    pub(super) old: Range<usize>,
    pub(super) new: Range<usize>,
}
#[derive(Clone, Debug)]
pub(super) enum ChangeKind {
    Same,
    Splices(Box<[LineSplice]>),
    ReplaceAll,
}

/// Transaction-local authorization for this exact pair. Splices describe line programs,
/// not final properties: relative coordinates may move within otherwise shared suffixes.
#[derive(Clone, Debug)]
pub(crate) struct PlanChange {
    base: LinePlan,
    target: LinePlan,
    kind: ChangeKind,
}
impl PlanChange {
    pub(super) fn same(plan: &LinePlan) -> Self {
        Self {
            base: plan.clone(),
            target: plan.clone(),
            kind: ChangeKind::Same,
        }
    }
    pub(super) fn replace_all(base: &LinePlan, target: &LinePlan) -> Self {
        if base.ptr_eq(target) {
            return Self::same(base);
        }
        Self {
            base: base.clone(),
            target: target.clone(),
            kind: ChangeKind::ReplaceAll,
        }
    }
    pub(super) fn splices(base: &LinePlan, target: &LinePlan, splices: Vec<LineSplice>) -> Self {
        let (mut old_end, mut new_end) = (0, 0);
        for splice in &splices {
            if splice.old.start < old_end
                || splice.new.start < new_end
                || splice.old.start > splice.old.end
                || splice.new.start > splice.new.end
                || splice.old.end > base.len()
                || splice.new.end > target.len()
                || splice.old.start - old_end != splice.new.start - new_end
            {
                return Self::replace_all(base, target);
            }
            old_end = splice.old.end;
            new_end = splice.new.end;
        }
        if base.len() - old_end != target.len() - new_end {
            return Self::replace_all(base, target);
        }
        if base.ptr_eq(target) {
            return Self::same(base);
        }
        Self {
            base: base.clone(),
            target: target.clone(),
            kind: ChangeKind::Splices(splices.into_boxed_slice()),
        }
    }
    pub(super) fn applies_to(&self, base: &LinePlan, target: &LinePlan) -> bool {
        self.base.ptr_eq(base) && self.target.ptr_eq(target)
    }
    pub(super) fn kind(&self) -> &ChangeKind {
        &self.kind
    }

    fn boundary_splices(&self) -> Vec<LineSplice> {
        let ChangeKind::Splices(splices) = &self.kind else {
            return Vec::new();
        };
        let mut result = splices.to_vec();
        let (mut old_start, mut new_start) = (0, 0);
        let terminal = LineSplice {
            old: self.base.len()..self.base.len(),
            new: self.target.len()..self.target.len(),
        };
        for splice in splices.iter().chain(std::iter::once(&terminal)) {
            // Only unchanged-gap endpoints need adding; changed ranges already cover the rest.
            for old in [0, self.base.len().saturating_sub(1)] {
                if old >= old_start && old < splice.old.start {
                    let new = new_start + old - old_start;
                    result.push(LineSplice {
                        old: old..old + 1,
                        new: new..new + 1,
                    });
                }
            }
            for new in [0, self.target.len().saturating_sub(1)] {
                if new >= new_start && new < splice.new.start {
                    let old = old_start + new - new_start;
                    result.push(LineSplice {
                        old: old..old + 1,
                        new: new..new + 1,
                    });
                }
            }
            old_start = splice.old.end;
            new_start = splice.new.end;
        }
        result.sort_by_key(|splice| (splice.old.start, splice.new.start));
        let mut merged: Vec<LineSplice> = Vec::new();
        for splice in result {
            if let Some(previous) = merged.last_mut() {
                if splice.old.start <= previous.old.end && splice.new.start <= previous.new.end {
                    previous.old.end = previous.old.end.max(splice.old.end);
                    previous.new.end = previous.new.end.max(splice.new.end);
                    continue;
                }
            }
            merged.push(splice);
        }
        merged
    }
}

#[derive(Debug)]
pub(super) struct ProjectionState {
    input: LinePlan,
    ops: Arc<[LineOp]>,
    plan: LinePlan,
    frame: Option<FrameState>,
}

/// Current blank-row framing parameters; counts can change with child height.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct FrameSpec {
    pub(super) prefix: usize,
    pub(super) suffix: usize,
    pub(super) width: i64,
    pub(super) prefix_properties: Arc<AtomProperties>,
    pub(super) suffix_properties: Arc<AtomProperties>,
}

#[derive(Debug)]
struct FrameState {
    spec: FrameSpec,
    prefix: LinePlan,
    suffix: LinePlan,
}

impl FrameSpec {
    fn same_parameters(&self, other: &Self) -> bool {
        self.width == other.width
            && self.prefix_properties == other.prefix_properties
            && self.suffix_properties == other.suffix_properties
    }
}
pub(super) struct ProjectionUpdate {
    pub(super) state: Arc<ProjectionState>,
    pub(super) change: PlanChange,
}
impl ProjectionState {
    fn measure(input: &LinePlan, ops: &[LineOp], range: Range<usize>) -> Metrics {
        if ops.iter().all(LineOp::preserves_metrics) {
            return input.metrics.slice(range);
        }
        let selected = input.metrics.slice(range.clone());
        Metrics::from_iter(selected.iter().enumerate().map(|(offset, mut metric)| {
            let index = range.start + offset;
            record(LinePlanWork {
                projection_lines_measured: 1,
                ..LinePlanWork::default()
            });
            for op in ops {
                metric = op.metric(metric, index, input.len());
            }
            metric
        }))
    }

    fn build(input: LinePlan, ops: Arc<[LineOp]>, metrics: Metrics) -> Arc<Self> {
        let plan = if ops.is_empty() {
            input.clone()
        } else {
            LinePlan::extended(
                Extension::Projection {
                    input: input.clone(),
                    ops: Arc::clone(&ops),
                    origin: 0,
                    length: input.len(),
                },
                metrics,
            )
        };
        Arc::new(Self {
            input,
            ops,
            plan,
            frame: None,
        })
    }

    pub(super) fn new(input: LinePlan, ops: Arc<[LineOp]>) -> Arc<Self> {
        let before = work().projection_lines_measured;
        let metrics = Self::measure(&input, &ops, 0..input.len());
        record(LinePlanWork {
            projection_initial_lines_measured: work().projection_lines_measured - before,
            ..LinePlanWork::default()
        });
        Self::build(input, ops, metrics)
    }

    pub(super) fn plan(&self) -> &LinePlan {
        &self.plan
    }

    pub(super) fn update(
        self: &Arc<Self>,
        input: LinePlan,
        proof: Option<&PlanChange>,
        ops: Arc<[LineOp]>,
    ) -> ProjectionUpdate {
        let valid = proof.filter(|proof| proof.applies_to(&self.input, &input));
        if self.frame.is_none() && ops == self.ops {
            if input.ptr_eq(&self.input) {
                return ProjectionUpdate {
                    state: Arc::clone(self),
                    change: PlanChange::same(&self.plan),
                };
            }
            if let Some(PlanChange {
                kind: ChangeKind::Splices(splices),
                ..
            }) = valid
            {
                let before = work().projection_lines_measured;
                // New and former endpoints are explicit changed ranges; all other
                // numeric subtrees remain shared even when their coordinates shift.
                let output_splices = if ops.iter().any(LineOp::boundary_sensitive) {
                    valid.expect("validated splice proof").boundary_splices()
                } else {
                    splices.to_vec()
                };
                let metrics = if ops.iter().all(LineOp::preserves_metrics) {
                    input.metrics.clone()
                } else {
                    let mut metrics = Metrics::default();
                    let mut old_end = 0;
                    for splice in &output_splices {
                        metrics =
                            metrics.concat(&self.plan.metrics.slice(old_end..splice.old.start));
                        metrics = metrics.concat(&Self::measure(&input, &ops, splice.new.clone()));
                        old_end = splice.old.end;
                    }
                    metrics.concat(&self.plan.metrics.slice(old_end..self.input.len()))
                };
                debug_assert_eq!(metrics.summary().count, input.len());
                record(LinePlanWork {
                    projection_splice_lines_measured: work().projection_lines_measured - before,
                    ..LinePlanWork::default()
                });
                let state = Self::build(input, ops, metrics);
                let change = PlanChange::splices(&self.plan, &state.plan, output_splices);
                return ProjectionUpdate { state, change };
            }
        }
        record(LinePlanWork {
            projection_fallbacks: 1,
            ..LinePlanWork::default()
        });
        let before = work().projection_lines_measured;
        let metrics = Self::measure(&input, &ops, 0..input.len());
        record(LinePlanWork {
            projection_fallback_lines_measured: work().projection_lines_measured - before,
            ..LinePlanWork::default()
        });
        let state = Self::build(input, ops, metrics);
        let change = PlanChange::replace_all(&self.plan, &state.plan);
        ProjectionUpdate { state, change }
    }

    fn blanks(count: usize, width: i64, properties: &Arc<AtomProperties>) -> LinePlan {
        record(LinePlanWork {
            frame_blank_lines_created: count as u64,
            ..LinePlanWork::default()
        });
        LinePlan::from_lines(
            (0..count).map(|_| Line::blank_with_properties(width, properties.as_ref().clone())),
        )
    }

    fn build_frame(
        input: LinePlan,
        spec: FrameSpec,
        prefix: LinePlan,
        suffix: LinePlan,
    ) -> Arc<Self> {
        let plan = if spec.prefix == 0 && spec.suffix == 0 {
            // Zero framing forwards input-bound proofs, including empty roots.
            input.clone()
        } else {
            prefix.concat(&input).concat(&suffix)
        };
        Arc::new(Self {
            input,
            ops: Arc::from([]),
            plan,
            frame: Some(FrameState {
                spec,
                prefix,
                suffix,
            }),
        })
    }

    pub(super) fn new_frame(input: LinePlan, spec: FrameSpec) -> Arc<Self> {
        let prefix = Self::blanks(spec.prefix, spec.width, &spec.prefix_properties);
        let suffix = Self::blanks(spec.suffix, spec.width, &spec.suffix_properties);
        Self::build_frame(input, spec, prefix, suffix)
    }

    pub(super) fn update_frame(
        self: &Arc<Self>,
        input: LinePlan,
        proof: Option<&PlanChange>,
        spec: FrameSpec,
    ) -> ProjectionUpdate {
        let Some(previous) = self
            .frame
            .as_ref()
            .filter(|previous| previous.spec.same_parameters(&spec))
        else {
            record(LinePlanWork {
                projection_fallbacks: 1,
                ..LinePlanWork::default()
            });
            let state = Self::new_frame(input, spec);
            let change = PlanChange::replace_all(&self.plan, &state.plan);
            return ProjectionUpdate { state, change };
        };
        if input.ptr_eq(&self.input) && previous.spec == spec {
            return ProjectionUpdate {
                state: Arc::clone(self),
                change: PlanChange::same(&self.plan),
            };
        }
        let resize = |old: &LinePlan, count: usize, properties: &Arc<AtomProperties>| {
            if count <= old.len() {
                old.slice(0..count)
            } else {
                old.concat(&Self::blanks(count - old.len(), spec.width, properties))
            }
        };
        let prefix = resize(&previous.prefix, spec.prefix, &spec.prefix_properties);
        let suffix = resize(&previous.suffix, spec.suffix, &spec.suffix_properties);
        let valid = proof.filter(|proof| proof.applies_to(&self.input, &input));
        let child_splices = if input.ptr_eq(&self.input) {
            Some(Vec::new())
        } else {
            valid.map(|proof| match proof.kind() {
                ChangeKind::Splices(splices) => splices.to_vec(),
                ChangeKind::ReplaceAll => vec![LineSplice {
                    old: 0..self.input.len(),
                    new: 0..input.len(),
                }],
                ChangeKind::Same => Vec::new(),
            })
        };
        let state = Self::build_frame(input, spec.clone(), prefix, suffix);
        let Some(child_splices) = child_splices else {
            record(LinePlanWork {
                projection_fallbacks: 1,
                ..LinePlanWork::default()
            });
            let change = PlanChange::replace_all(&self.plan, &state.plan);
            return ProjectionUpdate { state, change };
        };
        if previous.spec.prefix == 0
            && previous.spec.suffix == 0
            && spec.prefix == 0
            && spec.suffix == 0
        {
            let change = valid
                .cloned()
                .unwrap_or_else(|| PlanChange::replace_all(&self.plan, &state.plan));
            return ProjectionUpdate { state, change };
        }
        let old_prefix = previous.spec.prefix;
        let new_prefix = spec.prefix;
        let mut splices = Vec::new();
        if old_prefix != new_prefix {
            let shared = old_prefix.min(new_prefix);
            splices.push(LineSplice {
                old: shared..old_prefix,
                new: shared..new_prefix,
            });
        }
        splices.extend(child_splices.into_iter().map(|splice| LineSplice {
            old: old_prefix + splice.old.start..old_prefix + splice.old.end,
            new: new_prefix + splice.new.start..new_prefix + splice.new.end,
        }));
        if previous.spec.suffix != spec.suffix {
            let shared = previous.spec.suffix.min(spec.suffix);
            splices.push(LineSplice {
                old: old_prefix + self.input.len() + shared..self.plan.len(),
                new: new_prefix + state.input.len() + shared..state.plan.len(),
            });
        }
        // Default joins replace the stored predecessor break. Include that row,
        // including the terminal-row case when a child or blank tail disappears.
        for splice in &mut splices {
            if splice.old.start > 0 && splice.new.start > 0 {
                splice.old.start -= 1;
                splice.new.start -= 1;
            } else {
                splice.old.start = 0;
                splice.new.start = 0;
            }
        }
        splices.sort_by_key(|splice| (splice.old.start, splice.new.start));
        let mut merged: Vec<LineSplice> = Vec::new();
        for splice in splices {
            if let Some(previous) = merged.last_mut() {
                if splice.old.start <= previous.old.end && splice.new.start <= previous.new.end {
                    previous.old.end = previous.old.end.max(splice.old.end);
                    previous.new.end = previous.new.end.max(splice.new.end);
                    continue;
                }
            }
            merged.push(splice);
        }
        let change = PlanChange::splices(&self.plan, &state.plan, merged);
        ProjectionUpdate { state, change }
    }
}
