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

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(value: usize) -> Entry<String> {
        let text = if value % 5 == 0 {
            format!("界{value}")
        } else {
            value.to_string()
        };
        Entry::new(
            Arc::new(text.clone()),
            Measure::new(text.chars().count() as u64, 1, value as i64, value as i64).unwrap(),
        )
        .unwrap()
    }

    fn values(sequence: &Sequence<String>) -> Vec<String> {
        (0..sequence.len())
            .map(|index| sequence.get(index).unwrap().value().as_ref().clone())
            .collect()
    }

    fn height<T>(sequence: &Sequence<T>) -> u32 {
        sequence.root().map_or(0, |root| root.height())
    }

    fn shared_nodes<T>(left: &Arc<Node<T>>, right: &Arc<Node<T>>) -> usize {
        if Arc::ptr_eq(left, right) {
            return 1;
        }
        match (left.as_ref(), right.as_ref()) {
            (
                Node::Branch {
                    left: ll,
                    right: lr,
                    ..
                },
                Node::Branch {
                    left: rl,
                    right: rr,
                    ..
                },
            ) => shared_nodes(ll, rl) + shared_nodes(lr, rr),
            _ => 0,
        }
    }

    fn assert_valid<T>(node: &Arc<Node<T>>) -> (usize, u32, Measure) {
        match node.as_ref() {
            Node::Leaf { entries, measure } => {
                assert!(!entries.is_empty() && entries.len() <= LEAF_CAPACITY);
                let calculated = entries
                    .iter()
                    .try_fold(Measure::default(), |sum, entry| {
                        sum.checked_combine(entry.measure())
                    })
                    .unwrap();
                assert_eq!(*measure, calculated);
                (entries.len(), 1, calculated)
            }
            Node::Branch {
                left,
                right,
                len,
                height,
                measure,
            } => {
                let (left_len, left_height, left_measure) = assert_valid(left);
                let (right_len, right_height, right_measure) = assert_valid(right);
                assert!(left_height.abs_diff(right_height) <= 1);
                assert_eq!(*len, left_len + right_len);
                assert_eq!(*height, left_height.max(right_height) + 1);
                assert_eq!(
                    *measure,
                    left_measure.checked_combine(right_measure).unwrap()
                );
                (*len, *height, *measure)
            }
        }
    }

    #[test]
    fn empty_and_unicode_measures_are_exact() {
        let empty = Sequence::<String>::empty();
        assert!(empty.is_empty());
        assert_eq!(empty.measure(), Measure::default());
        let mut work = Work::default();
        let sequence = Sequence::from_entries([entry(0), entry(12)], &mut work).unwrap();
        assert_eq!(sequence.len(), 2);
        assert_eq!(sequence.measure().chars, 4);
        assert_eq!(sequence.measure().lines, 2);
        assert_eq!(sequence.measure().width_sum, 12);
        assert_eq!(sequence.measure().width_max, 12);
        assert_eq!(sequence.prefix_measure(1).unwrap().chars, 2);
        for size in 1..=257 {
            let mut work = Work::default();
            let varied = Sequence::from_entries((0..size).map(entry), &mut work).unwrap();
            assert_eq!(varied.len(), size);
            assert_valid(varied.root().unwrap());
        }
    }

    #[test]
    fn every_split_point_rejoins_exactly() {
        let mut setup = Work::default();
        let original = Sequence::from_entries((0..97).map(entry), &mut setup).unwrap();
        let oracle = values(&original);
        for index in 0..=original.len() {
            let mut work = Work::default();
            let (left, right) = original.split_at(index, &mut work).unwrap();
            assert_eq!(values(&left), oracle[..index]);
            assert_eq!(values(&right), oracle[index..]);
            let joined = left.concat(&right, &mut work).unwrap();
            assert_eq!(values(&joined), oracle);
            assert!(height(&joined) <= 8);
            assert_valid(joined.root().unwrap());
        }
    }

    #[test]
    fn repeated_left_and_right_concat_remain_balanced() {
        let mut left = Sequence::empty();
        let mut right = Sequence::empty();
        let mut work = Work::default();
        for index in 0..2048 {
            let one = Sequence::from_entries([entry(index)], &mut work).unwrap();
            left = left.concat(&one, &mut work).unwrap();
            right = one.concat(&right, &mut work).unwrap();
        }
        assert_eq!(left.len(), 2048);
        assert_eq!(right.len(), 2048);
        assert!(height(&left) <= 16, "left height={}", height(&left));
        assert!(height(&right) <= 16, "right height={}", height(&right));
        assert_valid(left.root().unwrap());
        assert_valid(right.root().unwrap());
    }

    #[test]
    fn deterministic_random_operations_match_vec_oracle() {
        let mut seed = 0x91e1_0da5_u64;
        let mut oracle = (0..64).collect::<Vec<_>>();
        let mut setup = Work::default();
        let mut sequence =
            Sequence::from_entries(oracle.iter().copied().map(entry), &mut setup).unwrap();
        for _ in 0..1000 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            let index = (seed as usize) % oracle.len();
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            let value = (seed >> 16) as usize % 10_000;
            oracle[index] = value;
            let mut work = Work::default();
            sequence = sequence.replace(index, entry(value), &mut work).unwrap();
            assert!(work.entries_written <= LEAF_CAPACITY as u64);
        }
        assert_eq!(
            values(&sequence),
            oracle
                .iter()
                .map(|value| entry(*value).value().as_ref().clone())
                .collect::<Vec<_>>()
        );
        assert_valid(sequence.root().unwrap());
    }

    #[test]
    fn single_replace_is_logarithmic_and_preserves_old_fork() {
        for size in [32, 128, 512, 8192] {
            let mut setup = Work::default();
            let original = Sequence::from_entries((0..size).map(entry), &mut setup).unwrap();
            let fork = original.clone();
            let old_value = original.get(1).unwrap().value().clone();
            let mut work = Work::default();
            let updated = original.replace(1, entry(99_999), &mut work).unwrap();
            assert!(work.nodes_created <= u64::from(height(&original)) + 1);
            assert!(work.entries_written <= LEAF_CAPACITY as u64);
            assert!(shared_nodes(original.root().unwrap(), updated.root().unwrap()) > 0);
            assert!(Arc::ptr_eq(fork.get(1).unwrap().value(), &old_value));
            assert_eq!(fork.get(1).unwrap().value().as_str(), "1");
            assert_eq!(updated.get(1).unwrap().value().as_str(), "99999");
            assert_valid(updated.root().unwrap());
        }
    }

    #[test]
    fn large_split_and_rejoin_touch_only_logarithmic_paths() {
        let mut setup = Work::default();
        let original = Sequence::from_entries((0..8192).map(entry), &mut setup).unwrap();
        let mut split_work = Work::default();
        let (left, right) = original.split_at(4097, &mut split_work).unwrap();
        assert!(split_work.nodes_created <= 32, "{split_work:?}");
        assert!(split_work.entries_written <= 32, "{split_work:?}");
        let mut concat_work = Work::default();
        let rejoined = left.concat(&right, &mut concat_work).unwrap();
        assert!(concat_work.nodes_created <= 32, "{concat_work:?}");
        assert_eq!(values(&rejoined), values(&original));
        assert_valid(rejoined.root().unwrap());
    }

    #[test]
    fn overflow_and_invalid_updates_leave_the_old_root_unchanged() {
        let huge = Entry::new(
            Arc::new("x".to_owned()),
            Measure::new(u64::MAX, 0, i64::MAX, i64::MAX).unwrap(),
        )
        .unwrap();
        let one = Entry::new(Arc::new("y".to_owned()), Measure::new(1, 0, 1, 1).unwrap()).unwrap();
        let mut work = Work::default();
        let base = Sequence::from_entries([huge], &mut work).unwrap();
        let old_root = Arc::clone(base.root().unwrap());
        let mut failed_work = Work::default();
        assert!(matches!(
            base.concat(
                &Sequence::from_entries([one], &mut Work::default()).unwrap(),
                &mut failed_work
            ),
            Err(Error::Overflow)
        ));
        assert!(Arc::ptr_eq(base.root().unwrap(), &old_root));
        assert!(matches!(
            base.replace(2, entry(2), &mut failed_work),
            Err(Error::IndexOutOfBounds)
        ));
        assert!(Measure::new(0, 0, -1, 0).is_err());
        assert!(Arc::ptr_eq(base.root().unwrap(), &old_root));
    }
}
