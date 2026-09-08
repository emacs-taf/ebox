//! Immutable source-reference occurrences, independent of layout evaluation phases.

use std::collections::BTreeMap;
use std::sync::Arc;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum LocalStep {
    BoxChild,
    RowChild(usize),
    ColumnChild(usize),
    FlexItem(usize),
}

/// A local structural address stops before crossing an identified node reference.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct SourceAddress {
    pub(super) owner_id: u64,
    pub(super) path: Arc<[LocalStep]>,
}

/// One structural occurrence can have several distinct layout evaluation uses.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct ParentUse {
    pub(super) use_id: u64,
    pub(super) parent: SourceAddress,
    pub(super) child_slot: LocalStep,
    pub(super) target_owner: u64,
}

/// Explicit bootstrap work; excludes allocator/map internals and layout work/K.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct TopologyBuildWork {
    pub(super) occurrences_written: u64,
    pub(super) path_steps_copied: u64,
    pub(super) incoming_lists_frozen: u64,
}

#[derive(Debug)]
pub(super) struct SourceTopology {
    root_owner: u64,
    incoming: BTreeMap<u64, Box<[ParentUse]>>,
    build_work: TopologyBuildWork,
}

impl SourceTopology {
    pub(super) fn root_owner(&self) -> u64 {
        self.root_owner
    }

    /// Borrows the complete occurrence list; no owner-pair deduplication.
    pub(super) fn incoming_uses(&self, owner_id: u64) -> &[ParentUse] {
        self.incoming.get(&owner_id).map_or(&[], Box::as_ref)
    }

    pub(super) fn build_work(&self) -> TopologyBuildWork {
        self.build_work
    }
}

/// Only the bootstrap traversal can create a topology. Scalar deltas share it.
#[derive(Default)]
pub(super) struct TopologyBuilder {
    incoming: BTreeMap<u64, Vec<ParentUse>>,
    work: TopologyBuildWork,
}

impl TopologyBuilder {
    pub(super) fn add_use(
        &mut self,
        parent_owner: u64,
        parent_path: &[LocalStep],
        child_slot: LocalStep,
        target_owner: u64,
    ) -> Result<(), String> {
        let use_id = self.work.occurrences_written;
        let occurrences_written = use_id
            .checked_add(1)
            .ok_or_else(|| "Native source topology occurrence count overflow".to_owned())?;
        let path_steps_copied = self
            .work
            .path_steps_copied
            .checked_add(parent_path.len() as u64)
            .ok_or_else(|| "Native source topology path count overflow".to_owned())?;
        self.incoming
            .entry(target_owner)
            .or_default()
            .push(ParentUse {
                use_id,
                parent: SourceAddress {
                    owner_id: parent_owner,
                    path: Arc::from(parent_path),
                },
                child_slot,
                target_owner,
            });
        self.work.occurrences_written = occurrences_written;
        self.work.path_steps_copied = path_steps_copied;
        Ok(())
    }

    /// The caller has already validated owner uniqueness and rejected NodeRef input.
    pub(super) fn finish(self, root_owner: u64) -> Arc<SourceTopology> {
        let mut work = self.work;
        let incoming = self
            .incoming
            .into_iter()
            .map(|(owner, uses)| {
                work.incoming_lists_frozen += 1;
                (owner, uses.into_boxed_slice())
            })
            .collect();
        Arc::new(SourceTopology {
            root_owner,
            incoming,
            build_work: work,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anonymous_paths_and_structural_slots_remain_distinct() {
        let mut builder = TopologyBuilder::default();
        builder
            .add_use(11, &[LocalStep::BoxChild], LocalStep::FlexItem(3), 29)
            .unwrap();
        builder
            .add_use(
                29,
                &[LocalStep::BoxChild, LocalStep::RowChild(2)],
                LocalStep::ColumnChild(1),
                41,
            )
            .unwrap();
        let topology = builder.finish(11);
        assert_eq!(topology.root_owner(), 11);
        assert!(topology.incoming_uses(11).is_empty());
        assert!(topology.incoming_uses(999).is_empty());
        let first = &topology.incoming_uses(29)[0];
        assert_eq!(first.use_id, 0);
        assert_eq!(first.parent.owner_id, 11);
        assert_eq!(first.parent.path.as_ref(), &[LocalStep::BoxChild]);
        assert_eq!(first.child_slot, LocalStep::FlexItem(3));
        assert_eq!(first.target_owner, 29);
        let second = &topology.incoming_uses(41)[0];
        assert_eq!(second.parent.owner_id, 29);
        assert_eq!(second.use_id, 1);
        assert_eq!(
            second.parent.path.as_ref(),
            &[LocalStep::BoxChild, LocalStep::RowChild(2)]
        );
        assert_eq!(second.child_slot, LocalStep::ColumnChild(1));
        assert_eq!(
            topology.build_work(),
            TopologyBuildWork {
                occurrences_written: 2,
                path_steps_copied: 3,
                incoming_lists_frozen: 2,
            }
        );
    }

    #[test]
    fn every_occurrence_is_retained_even_for_the_same_owner_pair() {
        // The storage must not silently deduplicate occurrences. This does not
        // authorize duplicate identified owners in the public bootstrap input.
        let mut builder = TopologyBuilder::default();
        for slot in [2, 7, 2] {
            builder
                .add_use(1, &[], LocalStep::RowChild(slot), 9)
                .unwrap();
        }
        let topology = builder.finish(1);
        let uses = topology.incoming_uses(9);
        assert_eq!(uses.len(), 3);
        assert_eq!(
            uses.iter().map(|usage| usage.use_id).collect::<Vec<_>>(),
            [0, 1, 2]
        );
        assert_eq!(uses[0].child_slot, uses[2].child_slot);
        assert_ne!(uses[0].use_id, uses[2].use_id);
        assert_eq!(topology.build_work().incoming_lists_frozen, 1);
    }

    #[test]
    fn forks_borrow_the_same_lists_without_changing_build_work() {
        for n in [32, 128, 512] {
            let mut builder = TopologyBuilder::default();
            for index in 0..n {
                builder
                    .add_use(1, &[], LocalStep::ColumnChild(index), index as u64 + 2)
                    .unwrap();
            }
            let base = builder.finish(1);
            let original_work = base.build_work();
            let left = Arc::clone(&base);
            let right = Arc::clone(&base);
            let target = (n / 2 + 2) as u64;
            assert!(Arc::ptr_eq(&base, &left));
            assert!(Arc::ptr_eq(&left, &right));
            assert!(std::ptr::eq(
                base.incoming_uses(target),
                right.incoming_uses(target)
            ));
            assert_eq!(base.build_work(), original_work);
            assert_eq!(original_work.occurrences_written, n as u64);
            assert_eq!(original_work.path_steps_copied, 0);
            assert_eq!(original_work.incoming_lists_frozen, n as u64);
        }
    }
}
