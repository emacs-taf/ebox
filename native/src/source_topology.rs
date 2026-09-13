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
