use std::cell::Cell;
use std::ops::Range;
use std::sync::Arc;

use crate::sequence::{Entry, Iter, Measure, Sequence, Work};

use super::{AtomProperties, Line};

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
            materialized_chars
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
    entries: Sequence<LineEntry>,
}

/// Borrowed traversal; counts both sequence-node visits and yielded lines.
pub(super) struct Lines<'a> {
    entries: Iter<'a, LineEntry>,
}

impl<'a> Iterator for Lines<'a> {
    type Item = &'a Line;

    fn next(&mut self) -> Option<Self::Item> {
        let before = self.entries.nodes_visited();
        let value = self.entries.next();
        record(LinePlanWork {
            iterator_nodes_visited: self.entries.nodes_visited() - before,
            lines_visited: u64::from(value.is_some()),
            ..LinePlanWork::default()
        });
        value.map(|entry| &entry.value().line)
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.entries.size_hint()
    }
}

impl ExactSizeIterator for Lines<'_> {}

pub(super) struct LinesAndBreaks<'a> {
    lines: Lines<'a>,
}

impl<'a> Iterator for LinesAndBreaks<'a> {
    type Item = (&'a Line, Option<&'a AtomProperties>);

    fn next(&mut self) -> Option<Self::Item> {
        let before = self.lines.entries.nodes_visited();
        let value = self.lines.entries.next();
        record(LinePlanWork {
            iterator_nodes_visited: self.lines.entries.nodes_visited() - before,
            lines_visited: u64::from(value.is_some()),
            ..LinePlanWork::default()
        });
        let entry = value?.value();
        Some((
            &entry.line,
            (self.lines.entries.len() > 0).then_some(entry.break_after.as_ref()),
        ))
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.lines.size_hint()
    }
}

impl ExactSizeIterator for LinesAndBreaks<'_> {}

impl LinePlan {
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
        Self { entries }
    }

    pub(super) fn len(&self) -> usize {
        self.entries.len()
    }

    pub(super) fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub(super) fn iter(&self) -> Lines<'_> {
        Lines {
            entries: self.entries.iter(),
        }
    }

    pub(super) fn iter_with_breaks(&self) -> LinesAndBreaks<'_> {
        LinesAndBreaks { lines: self.iter() }
    }

    fn get_entry(&self, index: usize) -> Option<&LineEntry> {
        record(LinePlanWork {
            line_lookups: 1,
            ..LinePlanWork::default()
        });
        self.entries.get(index).map(|entry| entry.value().as_ref())
    }

    pub(super) fn get(&self, index: usize) -> Option<&Line> {
        self.get_entry(index).map(|entry| &entry.line)
    }

    pub(super) fn first(&self) -> Option<&Line> {
        self.get(0)
    }

    pub(super) fn max_width(&self) -> i64 {
        self.entries.measure().width_max
    }

    pub(super) fn height(&self) -> i64 {
        i64::try_from(self.entries.measure().lines).expect("validated native line height fits i64")
    }

    pub(super) fn break_after(&self, index: usize) -> Option<&AtomProperties> {
        (index < self.len().saturating_sub(1)).then(|| {
            self.get_entry(index)
                .expect("checked line index")
                .break_after
                .as_ref()
        })
    }

    /// Character offset of a line start, or the complete output length at len().
    pub(super) fn prefix_chars(&self, end: usize) -> u64 {
        let chars = self.range_measure(0..end).chars;
        chars
            .checked_add(u64::from(end > 0 && end < self.len()))
            .expect("validated native line prefix fits u64")
    }

    /// Exact standalone range extent: height, widths, and chars excluding its final newline.
    pub(super) fn range_measure(&self, range: Range<usize>) -> Measure {
        record(LinePlanWork {
            range_queries: 1,
            ..LinePlanWork::default()
        });
        let mut measure = self
            .entries
            .range_measure(range)
            .expect("validated native line range");
        measure.chars = measure.chars.saturating_sub(u64::from(measure.lines > 0));
        measure
    }

    pub(super) fn slice(&self, range: Range<usize>) -> Self {
        let mut work = Work::default();
        let entries = self
            .entries
            .slice(range, &mut work)
            .expect("validated native line slice");
        record_sequence(work);
        Self { entries }
    }

    pub(super) fn replace_line(&self, index: usize, line: Line) -> Self {
        let old = self
            .get_entry(index)
            .expect("validated native line replacement");
        self.replace_entry(index, entry(line, Arc::clone(&old.break_after)))
    }

    pub(super) fn update_line(&self, index: usize, update: impl FnOnce(Line) -> Line) -> Self {
        let line = clone_line(self.get(index).expect("validated native line update"));
        record(LinePlanWork {
            lines_mapped: 1,
            ..LinePlanWork::default()
        });
        self.replace_line(index, update(line))
    }

    pub(super) fn with_break(&self, index: usize, properties: AtomProperties) -> Self {
        let old = self
            .break_after(index)
            .expect("validated native break index");
        if *old == properties {
            return self.clone();
        }
        self.set_stored_break(index, Arc::new(properties))
    }

    fn set_stored_break(&self, index: usize, properties: Arc<AtomProperties>) -> Self {
        let old = self
            .get_entry(index)
            .expect("validated native break replacement");
        self.replace_entry(index, entry(clone_line(&old.line), properties))
    }

    fn replace_entry(&self, index: usize, entry: Entry<LineEntry>) -> Self {
        let mut work = Work::default();
        let entries = self
            .entries
            .replace(index, entry, &mut work)
            .expect("validated native line replacement aggregates fit limits");
        record_sequence(work);
        Self { entries }
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
        let mut work = Work::default();
        let entries = self
            .entries
            .concat(&other.entries, &mut work)
            .expect("validated native line concatenation aggregates fit limits");
        record_sequence(work);
        Self { entries }.with_break(self.len() - 1, properties)
    }

    /// Full O(N) line transform. Atom payloads remain shared until changed by the callback.
    pub(super) fn map_lines(&self, mut map: impl FnMut(usize, Line) -> Line) -> Self {
        let mut iter = self.entries.iter();
        let result = Self::from_entries(iter.by_ref().enumerate().map(|(index, old)| {
            record(LinePlanWork {
                lines_visited: 1,
                lines_mapped: 1,
                ..LinePlanWork::default()
            });
            entry(
                map(index, clone_line(&old.value().line)),
                Arc::clone(&old.value().break_after),
            )
        }));
        record(LinePlanWork {
            iterator_nodes_visited: iter.nodes_visited(),
            ..LinePlanWork::default()
        });
        result
    }

    /// Full O(N) break transform. Its traversal and rewritten sequence entries are counted.
    pub(super) fn map_breaks(&self, mut map: impl FnMut(&mut AtomProperties)) -> Self {
        let mut iter = self.entries.iter();
        let last = self.len().saturating_sub(1);
        let result = Self::from_entries(iter.by_ref().enumerate().map(|(index, old)| {
            record(LinePlanWork {
                lines_visited: 1,
                ..LinePlanWork::default()
            });
            if index == last {
                return old.clone();
            }
            let mut properties = old.value().break_after.as_ref().clone();
            map(&mut properties);
            record(LinePlanWork {
                breaks_mapped: 1,
                ..LinePlanWork::default()
            });
            entry(clone_line(&old.value().line), Arc::new(properties))
        }));
        record(LinePlanWork {
            iterator_nodes_visited: iter.nodes_visited(),
            ..LinePlanWork::default()
        });
        result
    }

    pub(super) fn clear_breaks(&self) -> Self {
        self.map_breaks(|properties| *properties = AtomProperties::default())
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
        assert_eq!(joined.break_after(0), Some(&AtomProperties::default()));
        assert_eq!(joined.break_after(1).unwrap().scroll_window, Some(12));
        assert_eq!(original.break_after(0).unwrap().owner, Some(11));
        let explicit = prefix.concat_with_break(
            &original.slice(1..3),
            AtomProperties {
                owner: Some(13),
                ..AtomProperties::default()
            },
        );
        assert_eq!(explicit.break_after(0).unwrap().owner, Some(13));
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
