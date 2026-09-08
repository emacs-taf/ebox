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

    #[cfg(test)]
    pub(super) fn first(&self) -> Option<LineView<'_>> {
        self.get(0)
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

    #[cfg(test)]
    pub(super) fn replace_line(&self, index: usize, line: Line) -> Self {
        let old = self
            .get(index)
            .expect("validated line replacement")
            .break_view()
            .materialize()
            .into_owned();
        if self.extension.is_none() {
            self.replace_entry(index, entry(line, Arc::new(old)))
        } else {
            let replacement = Self::from_entries([entry(line, Arc::new(old))]);
            self.slice(0..index)
                .join_stored(&replacement)
                .join_stored(&self.slice(index + 1..self.len()))
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
pub(super) struct PlanChange {
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

#[cfg(test)]
mod tests {
    use super::super::{MeasuredCluster, Rendered};
    use super::*;

    fn text(value: &str, width: i64) -> Line {
        Line::from_clusters(&[MeasuredCluster {
            text: value.to_owned(),
            width,
            cjk: false,
            space: false,
            pixel_space: false,
            source_template_id: None,
        }])
    }

    #[test]
    fn typed_projection_keeps_exact_spaces_and_relative_content_without_line_maps() {
        let input = LinePlan::from_lines([
            text("界a", 3),
            Line::default(),
            Line::blank(2),
            text("z", 4),
        ]);
        reset_work();
        let state = ProjectionState::new(
            input,
            Arc::from([
                LineOp::PadTo {
                    width: 5,
                    align: super::super::HorizontalAlign::Center,
                },
                LineOp::OwnContent {
                    region: 42,
                    start: 7,
                },
            ]),
        );
        let projected = state.plan().clone();
        let projection_work = work();
        let tape = Rendered::from_line_plan(projected.clone()).into_tape(0);
        assert_eq!(projected.prefix_chars(4), 14);
        assert_eq!(
            tape.lines.iter().map(|line| line.width).collect::<Vec<_>>(),
            [5; 4]
        );
        for (index, line) in tape.lines.iter().enumerate() {
            for atom in &line.atoms {
                let properties = match atom {
                    super::super::TapeAtom::Text { properties, .. }
                    | super::super::TapeAtom::Space { properties, .. } => properties,
                };
                assert_eq!(properties.content_idx, Some(7 + index as i64));
            }
        }
        assert_eq!(projection_work.lines_mapped, 0);
    }

    fn assert_exact_metrics(plan: &LinePlan) {
        let mut chars = plan.len().saturating_sub(1) as u64;
        let mut max_width = 0;
        let mut min_content = 0;
        for (index, view) in plan.iter().enumerate() {
            let line = view.materialize();
            let expected = LineMetric::line(&line);
            assert_eq!(plan.metrics.get(index), Some(expected), "line {index}");
            chars += expected.chars;
            max_width = max_width.max(expected.width);
            min_content = min_content.max(expected.min_content);
        }
        assert_eq!(plan.prefix_chars(plan.len()), chars);
        assert_eq!(plan.max_width(), max_width);
        assert_eq!(plan.min_content_width(), min_content);
        assert_eq!(
            plan.first_width(),
            plan.first().map_or(0, |line| line.width())
        );
    }

    #[test]
    fn projection_cold_build_is_packed_and_same_parameter_splices_are_bounded() {
        for size in [32_usize, 128, 512, 8192] {
            let input = LinePlan::from_lines((0..size).map(|_| text("界", 2)));
            let ops: Arc<[LineOp]> = Arc::from([
                LineOp::PadTo {
                    width: 7,
                    align: super::super::HorizontalAlign::Center,
                },
                LineOp::OwnContent {
                    region: 9,
                    start: 0,
                },
            ]);
            reset_work();
            let original = ProjectionState::new(input.clone(), Arc::clone(&ops));
            let cold = work();
            assert_eq!(cold.projection_initial_lines_measured, size as u64);
            assert_eq!(cold.metric_entries_written, size as u64);
            assert!(cold.metric_nodes_created <= size as u64 / 8);
            assert!(cold.metric_nodes_visited <= size as u64 / 8);
            assert_eq!((cold.lines_mapped, cold.lines_visited), (0, 0));

            let replacement = input.replace_line(1, text("wide", 8));
            let proof = PlanChange::splices(
                &input,
                &replacement,
                vec![LineSplice {
                    old: 1..2,
                    new: 1..2,
                }],
            );
            reset_work();
            let changed = original.update(replacement.clone(), Some(&proof), Arc::clone(&ops));
            let steady = work();
            assert_eq!(steady.projection_splice_lines_measured, 1);
            assert_eq!(steady.projection_fallbacks, 0);
            assert_eq!(
                (
                    steady.lines_mapped,
                    steady.lines_visited,
                    steady.materialized_lines
                ),
                (0, 0, 0)
            );
            assert!(steady.metric_nodes_created <= 12 * u64::from(size.ilog2()) + 8);
            assert!(changed
                .change
                .applies_to(original.plan(), changed.state.plan()));
            assert_exact_metrics(changed.state.plan());
            let oracle = replacement.map_lines(|index, line| {
                let mut line = line.padded(7, super::super::HorizontalAlign::Center);
                line.own_content(9, index as i64);
                line
            });
            assert_eq!(
                Rendered::from_line_plan(changed.state.plan().clone()).into_tape(0),
                Rendered::from_line_plan(oracle).into_tape(0)
            );

            let changed_ops: Arc<[LineOp]> = Arc::from([LineOp::AppendSpace(2)]);
            reset_work();
            let fallback = changed.state.update(replacement, None, changed_ops);
            assert_eq!(work().projection_fallback_lines_measured, size as u64);
            assert_eq!(work().projection_initial_lines_measured, 0);
            assert_eq!(work().projection_fallbacks, 1);
            assert!(matches!(fallback.change.kind(), ChangeKind::ReplaceAll));
            assert_exact_metrics(fallback.state.plan());
        }
    }

    #[test]
    fn projection_coordinates_shift_shared_suffixes_and_slices_keep_stage_origins() {
        let mut owned = text("owned", 5);
        owned.own_content(20, 0);
        let input = LinePlan::from_lines([Line::blank(2), Line::blank(2), owned]);
        let ops: Arc<[LineOp]> = Arc::from([LineOp::OwnContent {
            region: 9,
            start: 10,
        }]);
        let original = ProjectionState::new(input.clone(), Arc::clone(&ops));
        let grown = LinePlan::from_lines([Line::blank(2), Line::blank(2), Line::blank(2)])
            .concat(&input.slice(1..3));
        let proof = PlanChange::splices(
            &input,
            &grown,
            vec![LineSplice {
                old: 0..1,
                new: 0..3,
            }],
        );
        reset_work();
        let changed = original.update(grown, Some(&proof), Arc::clone(&ops));
        assert_eq!(work().projection_lines_measured, 0);
        let tape = Rendered::from_line_plan(changed.state.plan().clone()).into_tape(0);
        let properties = |atom: &super::super::TapeAtom| match atom {
            super::super::TapeAtom::Text { properties, .. }
            | super::super::TapeAtom::Space { properties, .. } => properties.content_idx,
        };
        assert_eq!(properties(&tape.lines[3].atoms[0]), Some(13));
        assert_eq!(properties(&tape.lines[4].atoms[0]), Some(0));
        let selected = changed.state.plan().slice(2..4);
        assert_eq!(
            selected
                .first()
                .unwrap()
                .materialize()
                .atoms
                .first()
                .unwrap()
                .properties()
                .content_idx,
            Some(12)
        );
        let sliced_first = ProjectionState::new(input.slice(1..2), ops);
        assert_eq!(
            sliced_first
                .plan()
                .first()
                .unwrap()
                .materialize()
                .atoms
                .first()
                .unwrap()
                .properties()
                .content_idx,
            Some(10)
        );
        assert_exact_metrics(&selected);
    }

    #[test]
    fn projection_empty_zero_width_and_ordered_decorations_match_eager_oracle() {
        let mut mixed = Line::blank(2);
        mixed.append(&text("a b", 3));
        let input = LinePlan::from_lines([
            Line::default(),
            text("", 0),
            text(" \t", 2),
            Line::blank(0),
            mixed,
        ]);
        for width in [0, 1, 6] {
            let left_properties =
                super::super::region_properties(super::super::RegionRole::PaddingLeft, 44, None);
            let ops = Arc::from([
                LineOp::OwnContent {
                    region: 12,
                    start: 4,
                },
                LineOp::CollapseWhitespace { width, region: 12 },
                LineOp::Style(3),
                LineOp::EdgeSpaces {
                    left: 2,
                    left_properties: Arc::new(left_properties.clone()),
                    right: 0,
                    right_properties: Arc::new(AtomProperties::default()),
                },
                LineOp::Template(7),
                LineOp::ClearBreaks,
                LineOp::ScrollWindow(88),
            ]);
            let state = ProjectionState::new(input.clone(), ops);
            let oracle = input
                .map_lines(|index, mut line| {
                    line.own_content(12, 4 + index as i64);
                    line = line.collapse_whitespace_content(width, 12);
                    line.apply_style(Some(3));
                    line.prepend_space_with_properties(2, left_properties.clone());
                    line.push_space(0);
                    line.apply_property_template(Some(7));
                    line.atoms = line.atoms.apply_scroll_window(88);
                    line
                })
                .map_breaks(|properties| {
                    *properties = AtomProperties {
                        scroll_window: Some(88),
                        ..AtomProperties::default()
                    }
                });
            assert_exact_metrics(state.plan());
            assert_eq!(
                Rendered::from_line_plan(state.plan().clone()).into_tape(0),
                Rendered::from_line_plan(oracle).into_tape(0)
            );
        }
    }

    #[test]
    fn projection_endpoints_repair_metrics_and_propagate_precise_change() {
        let input = LinePlan::from_lines([Line::blank(2), Line::blank(2), Line::blank(2)]);
        let ops: Arc<[LineOp]> = Arc::from([
            LineOp::FirstStyleRole {
                style: 3,
                region: 9,
            },
            LineOp::LastStyleRole {
                style: 4,
                region: 9,
            },
        ]);
        let original = ProjectionState::new(input.clone(), Arc::clone(&ops));
        let grown = LinePlan::from_lines([Line::blank(2)]).concat(&input);
        let proof = PlanChange::splices(
            &input,
            &grown,
            vec![LineSplice {
                old: 0..0,
                new: 0..1,
            }],
        );
        let changed = original.update(grown.clone(), Some(&proof), ops);
        assert!(matches!(changed.change.kind(), ChangeKind::Splices(_)));
        assert_exact_metrics(changed.state.plan());
        let oracle = grown.map_lines(|index, mut line| {
            if index == 0 {
                line.apply_style(Some(3));
                line.apply_role(super::super::RegionRole::BorderTop, 9);
            }
            if index + 1 == grown.len() {
                line.apply_style(Some(4));
                line.apply_role(super::super::RegionRole::BorderBottom, 9);
            }
            line
        });
        assert_eq!(
            Rendered::from_line_plan(changed.state.plan().clone()).into_tape(0),
            Rendered::from_line_plan(oracle).into_tape(0)
        );
    }

    #[test]
    fn projection_hints_require_exact_roots_and_replaced_history_is_released() {
        let input = LinePlan::from_lines([text("old", 3), text("kept", 4)]);
        let removed = Arc::downgrade(input.entries.get(0).unwrap().value());
        let ops: Arc<[LineOp]> = Arc::from([LineOp::AppendSpace(1)]);
        let original = ProjectionState::new(input.clone(), Arc::clone(&ops));
        let old_state = Arc::downgrade(&original);
        let old_root = Arc::downgrade(&original.plan.identity);
        let replacement = input.replace_line(0, text("new", 3));
        let unrelated = input.replace_line(0, text("new", 3));
        let wrong = PlanChange::splices(
            &input,
            &unrelated,
            vec![LineSplice {
                old: 0..1,
                new: 0..1,
            }],
        );
        reset_work();
        let fallback = original.update(replacement.clone(), Some(&wrong), Arc::clone(&ops));
        assert_eq!(work().projection_fallback_lines_measured, 2);
        assert!(matches!(fallback.change.kind(), ChangeKind::ReplaceAll));
        let proof = PlanChange::splices(
            &input,
            &replacement,
            vec![LineSplice {
                old: 0..1,
                new: 0..1,
            }],
        );
        let updated = original.update(replacement.clone(), Some(&proof), Arc::clone(&ops));
        let same = updated.state.update(
            replacement,
            Some(&PlanChange::same(&updated.state.input)),
            ops,
        );
        assert!(Arc::ptr_eq(&same.state, &updated.state));
        assert!(matches!(same.change.kind(), ChangeKind::Same));
        let retained = updated.state.plan().clone();
        drop((
            input, original, proof, wrong, unrelated, fallback, updated, same,
        ));
        assert!(old_state.upgrade().is_none());
        assert!(old_root.upgrade().is_none());
        assert!(removed.upgrade().is_none());
        assert_exact_metrics(&retained);
        assert_eq!(
            retained
                .first()
                .unwrap()
                .materialize()
                .atoms
                .first()
                .unwrap()
                .width(),
            3
        );
    }

    #[test]
    fn projection_slice_prunes_old_inputs_and_breaks_follow_their_stage() {
        let input = LinePlan::from_lines((0..4).map(|_| text("x", 1)));
        let removed = Arc::downgrade(input.entries.get(3).unwrap().value());
        let state = ProjectionState::new(input.clone(), Arc::from([LineOp::ScrollWindow(8)]));
        let old_root = Arc::downgrade(&state.plan.identity);
        let selected = state.plan().slice(0..2);
        let joined = selected.concat(&LinePlan::from_lines([text("y", 1)]));
        assert_eq!(
            joined.break_after(0).unwrap().materialize().scroll_window,
            Some(8)
        );
        assert_eq!(
            joined.break_after(1).unwrap().materialize().scroll_window,
            None
        );
        let outer = ProjectionState::new(joined, Arc::from([LineOp::ScrollWindow(9)]));
        assert_eq!(
            outer
                .plan()
                .break_after(1)
                .unwrap()
                .materialize()
                .scroll_window,
            Some(9)
        );
        assert!(outer.plan().break_after(2).is_none());
        drop((input, state, selected));
        assert!(old_root.upgrade().is_none());
        assert!(removed.upgrade().is_none());
        assert_exact_metrics(outer.plan());
    }

    #[test]
    fn repeated_projected_break_override_releases_shadowed_roots_and_properties() {
        let mut plan = ProjectionState::new(
            LinePlan::from_lines([text("a", 1), text("b", 1)]),
            Arc::from([LineOp::Style(3)]),
        )
        .plan()
        .clone()
        .with_break(
            0,
            AtomProperties {
                owner: Some(10),
                ..AtomProperties::default()
            },
        );
        for owner in 11..75 {
            let old_line = plan.slice(0..1);
            let old_root =
                Arc::downgrade(old_line.extension.as_ref().expect("projected break root"));
            let Some(Extension::Break { properties, .. }) = old_line.extension.as_deref() else {
                panic!("break override")
            };
            let old_properties = Arc::downgrade(properties);
            plan = plan.with_break(
                0,
                AtomProperties {
                    owner: Some(owner),
                    ..AtomProperties::default()
                },
            );
            drop(old_line);
            assert!(
                old_root.upgrade().is_none(),
                "old override root retained at {owner}"
            );
            assert!(
                old_properties.upgrade().is_none(),
                "old override properties retained at {owner}"
            );
            let line = plan.slice(0..1);
            let Some(Extension::Break { input, .. }) = line.extension.as_deref() else {
                panic!("current break override")
            };
            assert!(!matches!(
                input.extension.as_deref(),
                Some(Extension::Break { .. })
            ));
            assert_eq!(
                plan.break_after(0).unwrap().materialize().owner,
                Some(owner)
            );
        }
    }

    #[test]
    fn zero_blank_frame_binds_forwarded_changes_across_empty_transitions() {
        let mut bindings = Vec::new();
        for starts_empty in [true, false] {
            let empty = LinePlan::default();
            let nonempty = LinePlan::from_lines([text("x", 1)]);
            let (input, target) = if starts_empty {
                (empty, nonempty)
            } else {
                (nonempty, empty)
            };
            let spec = FrameSpec {
                prefix: 0,
                suffix: 0,
                width: 3,
                prefix_properties: Arc::new(AtomProperties::default()),
                suffix_properties: Arc::new(AtomProperties::default()),
            };
            let state = ProjectionState::new_frame(input.clone(), spec.clone());
            let proof = PlanChange::splices(
                &input,
                &target,
                vec![LineSplice {
                    old: 0..input.len(),
                    new: 0..target.len(),
                }],
            );
            let updated = state.update_frame(target.clone(), Some(&proof), spec);
            bindings.push((
                updated
                    .change
                    .applies_to(state.plan(), updated.state.plan()),
                updated.state.plan().ptr_eq(&target),
            ));
        }
        assert_eq!(bindings, [(true, true), (true, true)]);
    }

    #[test]
    fn retained_blank_frame_matches_vertical_oracle_and_keeps_only_current_state() {
        let input = LinePlan::from_lines((0..5).map(|_| text("x", 2)));
        let spec = FrameSpec {
            prefix: 2,
            suffix: 3,
            width: 3,
            prefix_properties: Arc::new(AtomProperties::default()),
            suffix_properties: Arc::new(AtomProperties::default()),
        };
        let state = ProjectionState::new_frame(input.clone(), spec.clone());
        let old_state = Arc::downgrade(&state);
        let old_root = Arc::downgrade(&state.plan.identity);
        let same = state.update_frame(input.clone(), Some(&PlanChange::same(&input)), spec.clone());
        assert!(Arc::ptr_eq(&state, &same.state));
        assert!(matches!(same.change.kind(), ChangeKind::Same));
        let target = LinePlan::from_lines((0..4).map(|_| text("y", 2))).concat(&input.slice(1..5));
        let proof = PlanChange::splices(
            &input,
            &target,
            vec![LineSplice {
                old: 0..1,
                new: 0..4,
            }],
        );
        reset_work();
        let updated = state.update_frame(
            target.clone(),
            Some(&proof),
            FrameSpec {
                prefix: 1,
                suffix: 1,
                ..spec.clone()
            },
        );
        assert_eq!(work().frame_blank_lines_created, 0);
        assert!(matches!(updated.change.kind(), ChangeKind::Splices(_)));
        let oracle = super::super::vertical_align(
            target.clone(),
            10,
            super::super::VerticalAlign::Center,
            3,
        );
        assert_eq!(
            Rendered::from_line_plan(updated.state.plan().clone()).into_tape(0),
            Rendered::from_line_plan(oracle).into_tape(0)
        );
        assert_exact_metrics(updated.state.plan());
        // The transaction-local result deliberately owns its exact old root;
        // only the retained state must release history after that proof drops.
        let ProjectionUpdate {
            state: updated,
            change,
        } = updated;
        drop((same, state, input, proof));
        assert!(old_state.upgrade().is_none());
        assert_eq!(
            old_root.strong_count(),
            1,
            "only the transient change owns the old root"
        );
        assert!(Arc::ptr_eq(
            &change.base.identity,
            &old_root.upgrade().unwrap()
        ));
        drop(change);
        assert!(old_root.upgrade().is_none());
        reset_work();
        let changed_parameters = updated.update_frame(
            target,
            None,
            FrameSpec {
                prefix: 1,
                suffix: 1,
                width: 7,
                ..spec
            },
        );
        assert_eq!(work().projection_fallbacks, 1);
        assert_eq!(work().frame_blank_lines_created, 2);
        assert!(matches!(
            changed_parameters.change.kind(),
            ChangeKind::ReplaceAll
        ));
        assert_exact_metrics(changed_parameters.state.plan());
    }

    #[test]
    fn prefix_and_range_summaries_exclude_exactly_one_terminal_newline() {
        let empty = LinePlan::default();
        assert_eq!(empty.prefix_chars(0), 0);
        assert_eq!(empty.range_measure(0..0), Measure::default());
        let lines = LinePlan::from_lines([text("界a", 3), Line::default(), text("z", 0)]);
        assert_eq!((lines.height(), lines.max_width()), (3, 3));
        assert_eq!(
            (0..=3)
                .map(|end| lines.prefix_chars(end))
                .collect::<Vec<_>>(),
            [0, 3, 4, 5]
        );
        let middle = lines.range_measure(1..3);
        assert_eq!((middle.chars, middle.lines, middle.width_max), (2, 2, 0));
        let single_empty = lines.slice(1..2);
        assert_eq!(single_empty.prefix_chars(1), 0);
        assert_eq!(single_empty.height(), 1);
        let two_empty = LinePlan::from_lines([Line::default(), Line::default()]);
        assert_eq!(two_empty.prefix_chars(1), 1);
        assert_eq!(two_empty.prefix_chars(2), 1);
        assert_eq!(two_empty.range_measure(0..2).chars, 1);
    }

    #[test]
    fn sliced_terminal_break_never_reappears_as_a_default_join() {
        let original = LinePlan::from_lines([text("a", 1), text("b", 1), text("c", 1)])
            .with_break(
                0,
                AtomProperties {
                    owner: Some(11),
                    ..AtomProperties::default()
                },
            )
            .with_break(
                1,
                AtomProperties {
                    scroll_window: Some(12),
                    ..AtomProperties::default()
                },
            );
        let prefix = original.slice(0..1);
        assert!(prefix.break_after(0).is_none());
        let joined = prefix.concat(&original.slice(1..3));
        assert_eq!(
            joined
                .break_after(0)
                .map(|view| view.materialize().into_owned()),
            Some(AtomProperties::default())
        );
        assert_eq!(
            joined.break_after(1).unwrap().materialize().scroll_window,
            Some(12)
        );
        assert_eq!(
            original.break_after(0).unwrap().materialize().owner,
            Some(11)
        );
        let explicit = prefix.concat_with_break(
            &original.slice(1..3),
            AtomProperties {
                owner: Some(13),
                ..AtomProperties::default()
            },
        );
        assert_eq!(
            explicit.break_after(0).unwrap().materialize().owner,
            Some(13)
        );
        assert_eq!(prefix.concat(&LinePlan::default()).prefix_chars(1), 1);
    }

    #[test]
    fn replacement_slice_and_concat_share_paths_across_sizes() {
        for size in [32_usize, 128, 512, 8192] {
            let original = LinePlan::from_lines((0..size).map(|_| text("a", 1)));
            let suffix_entry = Arc::clone(original.entries.get(size - 1).unwrap().value());
            let before = Rendered::from_line_plan(original.clone()).into_tape(0);
            reset_work();
            let fork = original.clone();
            assert_eq!(work(), LinePlanWork::default());
            let updated = original.replace_line(1, text("hello", 5));
            let replaced = work();
            assert!(replaced.sequence_nodes_created <= u64::from(size.ilog2()) + 1);
            assert!(replaced.sequence_entries_written <= 16);
            assert_eq!((replaced.lines_mapped, replaced.materialized_lines), (0, 0));
            assert!(Arc::ptr_eq(
                updated.entries.get(size - 1).unwrap().value(),
                &suffix_entry
            ));
            assert_eq!(
                updated.prefix_chars(size - 1),
                original.prefix_chars(size - 1) + 4
            );
            assert_eq!((updated.height(), updated.max_width()), (size as i64, 5));
            reset_work();
            let selected = updated.slice(size / 4..size * 3 / 4);
            let rejoined = updated
                .slice(0..size / 4)
                .concat(&selected)
                .concat(&updated.slice(size * 3 / 4..size));
            let maintained = work();
            assert!(maintained.sequence_nodes_created <= 12 * u64::from(size.ilog2()) + 16);
            assert!(maintained.sequence_entries_written <= 128);
            assert_eq!(
                (
                    maintained.lines_visited,
                    maintained.lines_mapped,
                    maintained.materialized_lines
                ),
                (0, 0, 0)
            );
            assert!(Arc::ptr_eq(
                rejoined.entries.get(size - 1).unwrap().value(),
                &suffix_entry
            ));
            assert_eq!(Rendered::from_line_plan(fork).into_tape(0), before);
            let mut oracle = before;
            oracle.lines[1] = Rendered::from_lines(vec![text("hello", 5)])
                .into_tape(0)
                .lines
                .remove(0);
            oracle.lines[1].break_after = Some(AtomProperties::default());
            assert_eq!(Rendered::from_line_plan(rejoined).into_tape(0), oracle);
        }
    }

    #[test]
    fn full_maps_iteration_and_tape_materialization_report_real_work() {
        let size = 128;
        let lines = LinePlan::from_lines((0..size).map(|_| text("a", 1)));
        reset_work();
        let mapped = lines.map_lines(|_, mut line| {
            line.push_space(1);
            line
        });
        let line_work = work();
        assert_eq!(
            (
                line_work.lines_visited,
                line_work.lines_mapped,
                line_work.line_clones
            ),
            (size, size, size)
        );
        assert_eq!(line_work.sequence_entries_written, size);
        assert_eq!(line_work.iterator_nodes_visited, 15);
        assert_eq!(line_work.materialized_lines, 0);
        reset_work();
        let decorated = mapped.map_breaks(|properties| properties.owner = Some(9));
        let break_work = work();
        assert_eq!(break_work.lines_visited, size);
        assert_eq!(break_work.breaks_mapped, size - 1);
        assert_eq!(break_work.sequence_entries_written, size);
        assert_eq!(break_work.iterator_nodes_visited, 15);
        reset_work();
        let borrowed = decorated.iter().count();
        assert_eq!(borrowed, size as usize);
        assert_eq!(work().line_clones, 0);
        assert_eq!(work().iterator_nodes_visited, 15);
        reset_work();
        let tape = Rendered::from_line_plan(decorated).into_tape(0);
        assert_eq!(work().materialized_lines, size);
        assert_eq!(work().materialized_breaks, size - 1);
        assert_eq!(work().materialized_chars, size * 3 - 1);
        assert_eq!(work().lines_visited, size);
        assert_eq!(work().iterator_nodes_visited, 15);
        assert_eq!(work().line_clones, 0);
        assert!(tape.lines.last().unwrap().break_after.is_none());
    }

    #[test]
    fn bulk_vertical_stack_shares_children_with_linear_sequence_work() {
        for size in [32_usize, 128, 512, 8192] {
            let children = (0..size)
                .map(|_| LinePlan::from_lines([text("a", 1)]))
                .collect::<Vec<_>>();
            let parts = children
                .iter()
                .cloned()
                .map(Rendered::from_line_plan)
                .collect();
            reset_work();
            let stacked = super::super::stack_vertical(parts);
            let joined = work();
            assert_eq!(joined.sequence_nodes_created, size as u64 - 1);
            assert_eq!(joined.sequence_entries_written, size as u64 * 4);
            assert_eq!(
                (
                    joined.lines_visited,
                    joined.line_clones,
                    joined.materialized_lines
                ),
                (0, 0, 0)
            );
            for (index, child) in children.iter().enumerate() {
                assert!(Arc::ptr_eq(
                    stacked.lines.entries.get(index).unwrap().value(),
                    child.entries.get(0).unwrap().value()
                ));
            }
            assert_eq!(stacked.lines.prefix_chars(size), size as u64 * 2 - 1);
        }
    }
}
