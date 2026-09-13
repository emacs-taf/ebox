use std::ops::Range;
use std::sync::Arc;

const LEAF_CAPACITY: usize = 16;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Measure {
    pub chars: u64,
    pub lines: u64,
    pub width_sum: i64,
    pub width_max: i64,
}

impl Measure {
    pub fn new(chars: u64, lines: u64, width_sum: i64, width_max: i64) -> Result<Self, Error> {
        if width_sum < 0 || width_max < 0 {
            return Err(Error::NegativeWidth);
        }
        Ok(Self {
            chars,
            lines,
            width_sum,
            width_max,
        })
    }

    pub fn checked_combine(self, other: Self) -> Result<Self, Error> {
        Ok(Self {
            chars: self.chars.checked_add(other.chars).ok_or(Error::Overflow)?,
            lines: self.lines.checked_add(other.lines).ok_or(Error::Overflow)?,
            width_sum: self
                .width_sum
                .checked_add(other.width_sum)
                .ok_or(Error::Overflow)?,
            width_max: self.width_max.max(other.width_max),
        })
    }
}

#[derive(Debug)]
pub struct Entry<T> {
    value: Arc<T>,
    measure: Measure,
}

impl<T> Clone for Entry<T> {
    fn clone(&self) -> Self {
        Self {
            value: Arc::clone(&self.value),
            measure: self.measure,
        }
    }
}

impl<T> Entry<T> {
    pub fn new(value: Arc<T>, measure: Measure) -> Result<Self, Error> {
        if measure.width_sum < 0 || measure.width_max < 0 {
            return Err(Error::NegativeWidth);
        }
        Ok(Self { value, measure })
    }

    pub fn value(&self) -> &Arc<T> {
        &self.value
    }

    pub fn measure(&self) -> Measure {
        self.measure
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Work {
    pub nodes_created: u64,
    pub entries_written: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    IndexOutOfBounds,
    NegativeWidth,
    Overflow,
}

#[derive(Debug)]
pub enum Node<T> {
    Leaf {
        entries: Box<[Entry<T>]>,
        measure: Measure,
    },
    Branch {
        left: Arc<Node<T>>,
        right: Arc<Node<T>>,
        len: usize,
        height: u32,
        measure: Measure,
    },
}

pub enum NodeView<'a, T> {
    Leaf {
        entries: &'a [Entry<T>],
        measure: Measure,
    },
    Branch {
        left: &'a Arc<Node<T>>,
        right: &'a Arc<Node<T>>,
        len: usize,
        height: u32,
        measure: Measure,
    },
}

type OptionalRoot<T> = Option<Arc<Node<T>>>;
type SplitRoots<T> = (OptionalRoot<T>, OptionalRoot<T>);

impl<T> Node<T> {
    pub fn view(&self) -> NodeView<'_, T> {
        match self {
            Self::Leaf { entries, measure } => NodeView::Leaf {
                entries,
                measure: *measure,
            },
            Self::Branch {
                left,
                right,
                len,
                height,
                measure,
            } => NodeView::Branch {
                left,
                right,
                len: *len,
                height: *height,
                measure: *measure,
            },
        }
    }

    fn len(&self) -> usize {
        match self {
            Self::Leaf { entries, .. } => entries.len(),
            Self::Branch { len, .. } => *len,
        }
    }

    fn height(&self) -> u32 {
        match self {
            Self::Leaf { .. } => 1,
            Self::Branch { height, .. } => *height,
        }
    }

    fn measure(&self) -> Measure {
        match self {
            Self::Leaf { measure, .. } | Self::Branch { measure, .. } => *measure,
        }
    }
}

#[derive(Debug)]
pub struct Sequence<T> {
    root: Option<Arc<Node<T>>>,
}

/// Borrowed in-order traversal with an O(log N) stack and no entry clones.
pub struct Iter<'a, T> {
    pending: Vec<&'a Node<T>>,
    leaf: std::slice::Iter<'a, Entry<T>>,
    remaining: usize,
    nodes_visited: u64,
}

impl<T> Iter<'_, T> {
    pub fn nodes_visited(&self) -> u64 {
        self.nodes_visited
    }
}

impl<'a, T> Iterator for Iter<'a, T> {
    type Item = &'a Entry<T>;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            if let Some(entry) = self.leaf.next() {
                self.remaining -= 1;
                return Some(entry);
            }
            let node = self.pending.pop()?;
            self.nodes_visited = self
                .nodes_visited
                .checked_add(1)
                .expect("sequence traversal count fits u64");
            match node {
                Node::Leaf { entries, .. } => self.leaf = entries.iter(),
                Node::Branch { left, right, .. } => {
                    self.pending.push(right);
                    self.pending.push(left);
                }
            }
        }
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        (self.remaining, Some(self.remaining))
    }
}

impl<T> ExactSizeIterator for Iter<'_, T> {}

impl<T> Clone for Sequence<T> {
    fn clone(&self) -> Self {
        Self {
            root: self.root.as_ref().map(Arc::clone),
        }
    }
}

impl<T> Default for Sequence<T> {
    fn default() -> Self {
        Self::empty()
    }
}

impl<T> Sequence<T> {
    pub fn empty() -> Self {
        Self { root: None }
    }

    pub fn from_entries<I>(entries: I, work: &mut Work) -> Result<Self, Error>
    where
        I: IntoIterator<Item = Entry<T>>,
    {
        let entries = entries.into_iter().collect::<Vec<_>>();
        let mut leaves = Vec::with_capacity(entries.len().div_ceil(LEAF_CAPACITY));
        for chunk in entries.chunks(LEAF_CAPACITY) {
            leaves.push(make_leaf(chunk.to_vec(), work)?);
        }
        fn build<T>(leaves: &[Arc<Node<T>>], work: &mut Work) -> Result<Arc<Node<T>>, Error> {
            if leaves.len() == 1 {
                return Ok(Arc::clone(&leaves[0]));
            }
            let middle = leaves.len() / 2;
            make_branch(
                build(&leaves[..middle], work)?,
                build(&leaves[middle..], work)?,
                work,
            )
        }
        Ok(Self {
            root: if leaves.is_empty() {
                None
            } else {
                Some(build(&leaves, work)?)
            },
        })
    }

    pub fn len(&self) -> usize {
        self.root.as_ref().map_or(0, |root| root.len())
    }

    pub fn is_empty(&self) -> bool {
        self.root.is_none()
    }

    pub fn measure(&self) -> Measure {
        self.root
            .as_ref()
            .map_or(Measure::default(), |root| root.measure())
    }

    pub fn root(&self) -> Option<&Arc<Node<T>>> {
        self.root.as_ref()
    }

    pub fn iter(&self) -> Iter<'_, T> {
        Iter {
            pending: self.root.as_deref().into_iter().collect(),
            leaf: [].iter(),
            remaining: self.len(),
            nodes_visited: 0,
        }
    }

    pub fn get(&self, index: usize) -> Option<&Entry<T>> {
        fn get_at<T>(node: &Node<T>, index: usize) -> Option<&Entry<T>> {
            match node {
                Node::Leaf { entries, .. } => entries.get(index),
                Node::Branch { left, right, .. } => {
                    if index < left.len() {
                        get_at(left, index)
                    } else {
                        get_at(right, index - left.len())
                    }
                }
            }
        }
        (index < self.len()).then(|| get_at(self.root.as_deref()?, index))?
    }

    pub fn prefix_measure(&self, end: usize) -> Result<Measure, Error> {
        fn prefix<T>(node: &Node<T>, end: usize) -> Result<Measure, Error> {
            match node {
                Node::Leaf { entries, .. } => entries[..end]
                    .iter()
                    .try_fold(Measure::default(), |sum, entry| {
                        sum.checked_combine(entry.measure)
                    }),
                Node::Branch { left, right, .. } => {
                    if end <= left.len() {
                        prefix(left, end)
                    } else {
                        left.measure()
                            .checked_combine(prefix(right, end - left.len())?)
                    }
                }
            }
        }
        if end > self.len() {
            return Err(Error::IndexOutOfBounds);
        }
        self.root
            .as_deref()
            .map_or(Ok(Measure::default()), |root| prefix(root, end))
    }

    /// Aggregate a range by visiting its boundary paths and cached interior nodes.
    pub fn range_measure(&self, range: Range<usize>) -> Result<Measure, Error> {
        fn measure<T>(node: &Node<T>, start: usize, end: usize) -> Result<Measure, Error> {
            if start == end {
                return Ok(Measure::default());
            }
            if start == 0 && end == node.len() {
                return Ok(node.measure());
            }
            match node {
                Node::Leaf { entries, .. } => entries[start..end]
                    .iter()
                    .try_fold(Measure::default(), |sum, entry| {
                        sum.checked_combine(entry.measure)
                    }),
                Node::Branch { left, right, .. } => {
                    let middle = left.len();
                    if end <= middle {
                        measure(left, start, end)
                    } else if start >= middle {
                        measure(right, start - middle, end - middle)
                    } else {
                        measure(left, start, middle)?.checked_combine(measure(
                            right,
                            0,
                            end - middle,
                        )?)
                    }
                }
            }
        }
        if range.start > range.end || range.end > self.len() {
            return Err(Error::IndexOutOfBounds);
        }
        self.root.as_deref().map_or(Ok(Measure::default()), |root| {
            measure(root, range.start, range.end)
        })
    }

    /// Share the interior of a range, copying only its two boundary paths.
    pub fn slice(&self, range: Range<usize>, work: &mut Work) -> Result<Self, Error> {
        if range.start > range.end || range.end > self.len() {
            return Err(Error::IndexOutOfBounds);
        }
        let (before, _) = self.split_at(range.end, work)?;
        let (_, selected) = before.split_at(range.start, work)?;
        Ok(selected)
    }

    pub fn split_at(&self, index: usize, work: &mut Work) -> Result<(Self, Self), Error> {
        if index > self.len() {
            return Err(Error::IndexOutOfBounds);
        }
        let (left, right) = split_node(self.root.as_ref(), index, work)?;
        Ok((Self { root: left }, Self { root: right }))
    }

    pub fn concat(&self, other: &Self, work: &mut Work) -> Result<Self, Error> {
        Ok(Self {
            root: join(self.root.clone(), other.root.clone(), work)?,
        })
    }

    pub fn replace(&self, index: usize, entry: Entry<T>, work: &mut Work) -> Result<Self, Error> {
        if index >= self.len() {
            return Err(Error::IndexOutOfBounds);
        }
        Ok(Self {
            root: Some(replace_node(
                self.root.as_ref().expect("nonempty checked"),
                index,
                entry,
                work,
            )?),
        })
    }
}

fn count_node(work: &mut Work) -> Result<(), Error> {
    work.nodes_created = work.nodes_created.checked_add(1).ok_or(Error::Overflow)?;
    Ok(())
}

fn make_leaf<T>(entries: Vec<Entry<T>>, work: &mut Work) -> Result<Arc<Node<T>>, Error> {
    debug_assert!(!entries.is_empty() && entries.len() <= LEAF_CAPACITY);
    let measure = entries.iter().try_fold(Measure::default(), |sum, entry| {
        sum.checked_combine(entry.measure)
    })?;
    let written = u64::try_from(entries.len()).map_err(|_| Error::Overflow)?;
    let next_written = work
        .entries_written
        .checked_add(written)
        .ok_or(Error::Overflow)?;
    count_node(work)?;
    work.entries_written = next_written;
    Ok(Arc::new(Node::Leaf {
        entries: entries.into_boxed_slice(),
        measure,
    }))
}

fn make_branch<T>(
    left: Arc<Node<T>>,
    right: Arc<Node<T>>,
    work: &mut Work,
) -> Result<Arc<Node<T>>, Error> {
    let len = left.len().checked_add(right.len()).ok_or(Error::Overflow)?;
    let height = left
        .height()
        .max(right.height())
        .checked_add(1)
        .ok_or(Error::Overflow)?;
    let measure = left.measure().checked_combine(right.measure())?;
    count_node(work)?;
    Ok(Arc::new(Node::Branch {
        left,
        right,
        len,
        height,
        measure,
    }))
}

fn join<T>(
    left: Option<Arc<Node<T>>>,
    right: Option<Arc<Node<T>>>,
    work: &mut Work,
) -> Result<Option<Arc<Node<T>>>, Error> {
    let (left, right) = match (left, right) {
        (None, right) => return Ok(right),
        (left, None) => return Ok(left),
        (Some(left), Some(right)) => (left, right),
    };
    if let (Node::Leaf { entries: a, .. }, Node::Leaf { entries: b, .. }) =
        (left.as_ref(), right.as_ref())
    {
        if a.len() + b.len() <= LEAF_CAPACITY {
            let mut entries = Vec::with_capacity(a.len() + b.len());
            entries.extend_from_slice(a);
            entries.extend_from_slice(b);
            return make_leaf(entries, work).map(Some);
        }
    }
    if left.height() > right.height().saturating_add(1) {
        let Node::Branch {
            left: outer,
            right: inner,
            ..
        } = left.as_ref()
        else {
            unreachable!()
        };
        let joined = join(Some(Arc::clone(inner)), Some(right), work)?.expect("nonempty join");
        return rebalance(Arc::clone(outer), joined, work).map(Some);
    }
    if right.height() > left.height().saturating_add(1) {
        let Node::Branch {
            left: inner,
            right: outer,
            ..
        } = right.as_ref()
        else {
            unreachable!()
        };
        let joined = join(Some(left), Some(Arc::clone(inner)), work)?.expect("nonempty join");
        return rebalance(joined, Arc::clone(outer), work).map(Some);
    }
    make_branch(left, right, work).map(Some)
}

fn rebalance<T>(
    left: Arc<Node<T>>,
    right: Arc<Node<T>>,
    work: &mut Work,
) -> Result<Arc<Node<T>>, Error> {
    if left.height() > right.height().saturating_add(1) {
        let Node::Branch {
            left: ll,
            right: lr,
            ..
        } = left.as_ref()
        else {
            unreachable!()
        };
        if ll.height() >= lr.height() {
            return make_branch(
                Arc::clone(ll),
                make_branch(Arc::clone(lr), right, work)?,
                work,
            );
        }
        let Node::Branch {
            left: lrl,
            right: lrr,
            ..
        } = lr.as_ref()
        else {
            unreachable!()
        };
        return make_branch(
            make_branch(Arc::clone(ll), Arc::clone(lrl), work)?,
            make_branch(Arc::clone(lrr), right, work)?,
            work,
        );
    }
    if right.height() > left.height().saturating_add(1) {
        let Node::Branch {
            left: rl,
            right: rr,
            ..
        } = right.as_ref()
        else {
            unreachable!()
        };
        if rr.height() >= rl.height() {
            return make_branch(
                make_branch(left, Arc::clone(rl), work)?,
                Arc::clone(rr),
                work,
            );
        }
        let Node::Branch {
            left: rll,
            right: rlr,
            ..
        } = rl.as_ref()
        else {
            unreachable!()
        };
        return make_branch(
            make_branch(left, Arc::clone(rll), work)?,
            make_branch(Arc::clone(rlr), Arc::clone(rr), work)?,
            work,
        );
    }
    make_branch(left, right, work)
}

fn split_node<T>(
    node: Option<&Arc<Node<T>>>,
    index: usize,
    work: &mut Work,
) -> Result<SplitRoots<T>, Error> {
    let Some(node) = node else {
        return Ok((None, None));
    };
    if index == 0 {
        return Ok((None, Some(Arc::clone(node))));
    }
    if index == node.len() {
        return Ok((Some(Arc::clone(node)), None));
    }
    match node.as_ref() {
        Node::Leaf { entries, .. } => Ok((
            Some(make_leaf(entries[..index].to_vec(), work)?),
            Some(make_leaf(entries[index..].to_vec(), work)?),
        )),
        Node::Branch { left, right, .. } => {
            if index < left.len() {
                let (before, after) = split_node(Some(left), index, work)?;
                Ok((before, join(after, Some(Arc::clone(right)), work)?))
            } else if index == left.len() {
                Ok((Some(Arc::clone(left)), Some(Arc::clone(right))))
            } else {
                let (before, after) = split_node(Some(right), index - left.len(), work)?;
                Ok((join(Some(Arc::clone(left)), before, work)?, after))
            }
        }
    }
}

fn replace_node<T>(
    node: &Arc<Node<T>>,
    index: usize,
    entry: Entry<T>,
    work: &mut Work,
) -> Result<Arc<Node<T>>, Error> {
    match node.as_ref() {
        Node::Leaf { entries, .. } => {
            let mut entries = entries.to_vec();
            entries[index] = entry;
            make_leaf(entries, work)
        }
        Node::Branch { left, right, .. } => {
            if index < left.len() {
                make_branch(
                    replace_node(left, index, entry, work)?,
                    Arc::clone(right),
                    work,
                )
            } else {
                make_branch(
                    Arc::clone(left),
                    replace_node(right, index - left.len(), entry, work)?,
                    work,
                )
            }
        }
    }
}
