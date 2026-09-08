//! Persistent numeric summaries. No node retains a line, document, or old projection.
use std::ops::Range;
use std::sync::Arc;

use super::{record, Line, LinePlanWork};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct LineMetric {
    pub width: i64,
    pub chars: u64,
    pub min_content: i64,
    pub nonempty: bool,
    pub whitespace: bool,
    pub noncontent: bool,
}

impl LineMetric {
    pub fn line(line: &Line) -> Self {
        Self {
            width: line.width,
            chars: line.atoms.char_count(),
            min_content: line.atoms.min_content_width(),
            nonempty: !line.atoms.is_empty(),
            whitespace: line.whitespace_only(),
            noncontent: line.has_noncontent_properties(),
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub(super) struct Summary {
    pub count: usize,
    pub chars: u64,
    pub width_sum: i64,
    pub first_width: i64,
    pub min_width: i64,
    pub max_width: i64,
    pub min_content: i64,
    pub all_nonempty: bool,
}

impl Summary {
    fn line(line: LineMetric) -> Self {
        Self {
            count: 1,
            chars: line.chars,
            width_sum: line.width,
            first_width: line.width,
            min_width: line.width,
            max_width: line.width,
            min_content: line.min_content,
            all_nonempty: line.nonempty,
        }
    }

    fn combine(self, other: Self) -> Self {
        if self.count == 0 {
            return other;
        }
        if other.count == 0 {
            return self;
        }
        Self {
            count: self
                .count
                .checked_add(other.count)
                .expect("validated line count"),
            chars: self
                .chars
                .checked_add(other.chars)
                .expect("validated character count"),
            width_sum: self
                .width_sum
                .checked_add(other.width_sum)
                .expect("validated line widths"),
            first_width: self.first_width,
            min_width: self.min_width.min(other.min_width),
            max_width: self.max_width.max(other.max_width),
            min_content: self.min_content.max(other.min_content),
            all_nonempty: self.all_nonempty && other.all_nonempty,
        }
    }
}

#[derive(Clone, Debug, Default)]
pub(super) struct Metrics(Option<Arc<Node>>);

#[derive(Debug)]
struct Node {
    summary: Summary,
    height: u32,
    kind: Kind,
}

#[derive(Debug)]
enum Kind {
    Leaf(Box<[LineMetric]>),
    Branch(Metrics, Metrics),
}

impl Metrics {
    pub fn from_iter(lines: impl IntoIterator<Item = LineMetric>) -> Self {
        let mut lines = lines.into_iter();
        let mut blocks = Vec::new();
        loop {
            let block = lines.by_ref().take(16).collect::<Vec<_>>();
            if block.is_empty() {
                break;
            }
            blocks.push(Self::leaf(block.into_boxed_slice()));
        }
        fn build(lines: &[Metrics]) -> Metrics {
            match lines {
                [] => Metrics::default(),
                [line] => line.clone(),
                _ => Metrics::branch(
                    build(&lines[..lines.len() / 2]),
                    build(&lines[lines.len() / 2..]),
                ),
            }
        }
        build(&blocks)
    }

    fn line(line: LineMetric) -> Self {
        Self::leaf(Box::new([line]))
    }

    fn leaf(lines: Box<[LineMetric]>) -> Self {
        record(LinePlanWork {
            metric_nodes_created: 1,
            metric_entries_written: lines.len() as u64,
            ..LinePlanWork::default()
        });
        let summary = lines
            .iter()
            .copied()
            .fold(Summary::default(), |summary, line| {
                summary.combine(Summary::line(line))
            });
        Self(Some(Arc::new(Node {
            summary,
            height: 1,
            kind: Kind::Leaf(lines),
        })))
    }

    fn height(&self) -> u32 {
        self.0.as_ref().map_or(0, |node| node.height)
    }
    pub fn summary(&self) -> Summary {
        self.0
            .as_ref()
            .map_or(Summary::default(), |node| node.summary)
    }

    fn branch(left: Self, right: Self) -> Self {
        if left.0.is_none() {
            return right;
        }
        if right.0.is_none() {
            return left;
        }
        record(LinePlanWork {
            metric_nodes_created: 1,
            ..LinePlanWork::default()
        });
        Self(Some(Arc::new(Node {
            summary: left.summary().combine(right.summary()),
            height: left.height().max(right.height()) + 1,
            kind: Kind::Branch(left, right),
        })))
    }

    fn children(&self) -> (&Self, &Self) {
        let Kind::Branch(left, right) = &self.0.as_ref().expect("nonempty metrics").kind else {
            unreachable!("metric balance branch")
        };
        (left, right)
    }

    fn balanced(left: Self, right: Self) -> Self {
        if left.height() > right.height() + 1 {
            let (ll, lr) = left.children();
            if ll.height() >= lr.height() {
                Self::branch(ll.clone(), Self::branch(lr.clone(), right))
            } else {
                let (lrl, lrr) = lr.children();
                Self::branch(
                    Self::branch(ll.clone(), lrl.clone()),
                    Self::branch(lrr.clone(), right),
                )
            }
        } else if right.height() > left.height() + 1 {
            let (rl, rr) = right.children();
            if rr.height() >= rl.height() {
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

    pub fn concat(&self, other: &Self) -> Self {
        if self.height() > other.height() + 1 {
            let (left, right) = self.children();
            Self::balanced(left.clone(), right.concat(other))
        } else if other.height() > self.height() + 1 {
            let (left, right) = other.children();
            Self::balanced(self.concat(left), right.clone())
        } else {
            Self::branch(self.clone(), other.clone())
        }
    }

    #[cfg(test)]
    pub fn get(&self, index: usize) -> Option<LineMetric> {
        let node = self.0.as_ref()?;
        record(LinePlanWork {
            metric_nodes_visited: 1,
            ..LinePlanWork::default()
        });
        match &node.kind {
            Kind::Leaf(lines) => lines.get(index).copied(),
            Kind::Branch(left, right) => {
                if index < left.summary().count {
                    left.get(index)
                } else {
                    right.get(index - left.summary().count)
                }
            }
        }
    }

    pub fn slice(&self, range: Range<usize>) -> Self {
        assert!(range.start <= range.end && range.end <= self.summary().count);
        if range.is_empty() {
            return Self::default();
        }
        if range.start == 0 && range.end == self.summary().count {
            return self.clone();
        }
        record(LinePlanWork {
            metric_nodes_visited: 1,
            ..LinePlanWork::default()
        });
        if let Kind::Leaf(lines) = &self.0.as_ref().expect("nonempty metrics").kind {
            return Self::leaf(lines[range].into());
        }
        let (left, right) = self.children();
        let middle = left.summary().count;
        if range.end <= middle {
            left.slice(range)
        } else if range.start >= middle {
            right.slice(range.start - middle..range.end - middle)
        } else {
            left.slice(range.start..middle)
                .concat(&right.slice(0..range.end - middle))
        }
    }

    pub fn replace(&self, index: usize, line: LineMetric) -> Self {
        self.slice(0..index)
            .concat(&Self::line(line))
            .concat(&self.slice(index + 1..self.summary().count))
    }

    pub fn iter(&self) -> impl Iterator<Item = LineMetric> + '_ {
        let mut stack = self.0.as_deref().into_iter().collect::<Vec<_>>();
        let mut leaf = [].iter();
        std::iter::from_fn(move || loop {
            if let Some(line) = leaf.next() {
                return Some(*line);
            }
            let node = stack.pop()?;
            record(LinePlanWork {
                metric_nodes_visited: 1,
                ..LinePlanWork::default()
            });
            match &node.kind {
                Kind::Leaf(lines) => leaf = lines.iter(),
                Kind::Branch(left, right) => {
                    stack.push(right.0.as_deref().expect("nonempty metric branch"));
                    stack.push(left.0.as_deref().expect("nonempty metric branch"));
                }
            }
        })
    }
}
