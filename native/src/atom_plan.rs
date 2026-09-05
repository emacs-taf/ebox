use std::cell::Cell;
use std::sync::Arc;

use crate::sequence::{Entry, Measure, Node, NodeView, Sequence, Work};

use super::{Atom, AtomProperties, RegionRole, RegionRoleEntry};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) struct AtomPlanWork {
    pub(crate) sequence_nodes_created: u64,
    pub(crate) sequence_entries_written: u64,
    pub(crate) materialized_atoms: u64,
    pub(crate) property_applications: u64,
    pub(crate) atom_clones: u64,
    pub(crate) operation_block_writes: u64,
}

thread_local! {
    static WORK: Cell<AtomPlanWork> = Cell::new(AtomPlanWork::default());
}

pub(crate) fn reset_work() {
    WORK.set(AtomPlanWork::default());
}

pub(crate) fn work() -> AtomPlanWork {
    WORK.get()
}

fn record_sequence(work: Work) {
    WORK.set(WORK.get().checked_add(AtomPlanWork {
        sequence_nodes_created: work.nodes_created,
        sequence_entries_written: work.entries_written,
        materialized_atoms: 0,
        property_applications: 0,
        atom_clones: 0,
        operation_block_writes: 0,
    }));
}

fn record_materialized(count: usize) {
    let count = u64::try_from(count).expect("validated native atom count fits u64");
    WORK.set(WORK.get().checked_add(AtomPlanWork {
        materialized_atoms: count,
        atom_clones: count,
        ..AtomPlanWork::default()
    }));
}

fn record_atom_clones(count: usize) {
    let count = u64::try_from(count).expect("validated native atom count fits u64");
    WORK.set(WORK.get().checked_add(AtomPlanWork {
        atom_clones: count,
        ..AtomPlanWork::default()
    }));
}

fn record_operation_block_writes(count: usize) {
    let count = u64::try_from(count).expect("native atom decoration block fits u64");
    WORK.set(WORK.get().checked_add(AtomPlanWork {
        operation_block_writes: count,
        ..AtomPlanWork::default()
    }));
}

fn record_property_application() {
    WORK.set(WORK.get().checked_add(AtomPlanWork {
        property_applications: 1,
        ..AtomPlanWork::default()
    }));
}

impl AtomPlanWork {
    pub(crate) fn accumulate(&mut self, other: Self) {
        let combined = Self {
            sequence_nodes_created: self
                .sequence_nodes_created
                .checked_add(other.sequence_nodes_created)
                .expect("native atom plan node work counter overflow"),
            sequence_entries_written: self
                .sequence_entries_written
                .checked_add(other.sequence_entries_written)
                .expect("native atom plan entry work counter overflow"),
            materialized_atoms: self
                .materialized_atoms
                .checked_add(other.materialized_atoms)
                .expect("native atom plan materialization counter overflow"),
            property_applications: self
                .property_applications
                .checked_add(other.property_applications)
                .expect("native atom plan property work counter overflow"),
            atom_clones: self
                .atom_clones
                .checked_add(other.atom_clones)
                .expect("native atom plan clone work counter overflow"),
            operation_block_writes: self
                .operation_block_writes
                .checked_add(other.operation_block_writes)
                .expect("native atom plan operation work counter overflow"),
        };
        *self = combined;
    }

    fn checked_add(mut self, other: Self) -> Self {
        self.accumulate(other);
        self
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct RunSummary {
    prefix: i64,
    suffix: i64,
    maximum: i64,
    all_run: bool,
}

impl RunSummary {
    fn atom(atom: &Atom) -> Self {
        if atom.wrap_space() {
            Self::default()
        } else if atom.wrap_cjk() {
            Self {
                maximum: atom.width(),
                ..Self::default()
            }
        } else {
            Self {
                prefix: atom.width(),
                suffix: atom.width(),
                maximum: atom.width(),
                all_run: true,
            }
        }
    }

    fn combine(self, other: Self) -> Self {
        let cross = self
            .suffix
            .checked_add(other.prefix)
            .expect("validated native atom widths fit i64");
        Self {
            prefix: if self.all_run {
                self.prefix
                    .checked_add(other.prefix)
                    .expect("validated native atom widths fit i64")
            } else {
                self.prefix
            },
            suffix: if other.all_run {
                self.suffix
                    .checked_add(other.suffix)
                    .expect("validated native atom widths fit i64")
            } else {
                other.suffix
            },
            maximum: self.maximum.max(other.maximum).max(cross),
            all_run: self.all_run && other.all_run,
        }
    }
}

#[derive(Clone, Debug, Default)]
struct Summary {
    atom_count: usize,
    any_owner: bool,
    any_content: bool,
    noncontent: bool,
    whitespace: bool,
    first_properties: Option<AtomProperties>,
    runs: RunSummary,
}

impl Summary {
    fn atom(atom: &Atom) -> Self {
        let properties = atom.properties();
        Self {
            atom_count: 1,
            any_owner: properties.owner.is_some() || !properties.owners.is_empty(),
            any_content: properties.content.is_some(),
            noncontent: !properties.style_ids.is_empty()
                || !properties.roles.is_empty()
                || !properties.property_template_ids.is_empty(),
            whitespace: match atom {
                Atom::Text { text, .. } => text.trim().is_empty(),
                Atom::Space { .. } => true,
            },
            first_properties: Some(properties.clone()),
            runs: RunSummary::atom(atom),
        }
    }

    fn combine(self, other: Self) -> Self {
        Self {
            atom_count: self
                .atom_count
                .checked_add(other.atom_count)
                .expect("validated native atom count fits usize"),
            any_owner: self.any_owner || other.any_owner,
            any_content: self.any_content || other.any_content,
            noncontent: self.noncontent || other.noncontent,
            whitespace: self.whitespace && other.whitespace,
            first_properties: self.first_properties.or(other.first_properties),
            runs: self.runs.combine(other.runs),
        }
    }

    fn atoms(atoms: &[Atom]) -> Self {
        let first = atoms.first().expect("nonempty native atom block");
        let mut summary = Self {
            atom_count: 0,
            any_owner: false,
            any_content: false,
            noncontent: false,
            whitespace: true,
            first_properties: Some(first.properties().clone()),
            runs: RunSummary {
                all_run: true,
                ..RunSummary::default()
            },
        };
        for atom in atoms {
            let properties = atom.properties();
            summary.atom_count = summary
                .atom_count
                .checked_add(1)
                .expect("validated native atom count fits usize");
            summary.any_owner |= properties.owner.is_some() || !properties.owners.is_empty();
            summary.any_content |= properties.content.is_some();
            summary.noncontent |= !properties.style_ids.is_empty()
                || !properties.roles.is_empty()
                || !properties.property_template_ids.is_empty();
            summary.whitespace &= match atom {
                Atom::Text { text, .. } => text.trim().is_empty(),
                Atom::Space { .. } => true,
            };
            summary.runs = summary.runs.combine(RunSummary::atom(atom));
        }
        summary
    }
}

#[derive(Clone, Debug)]
enum Decoration {
    OwnContent {
        region: i64,
        index: i64,
        had_owner: bool,
        had_content: bool,
    },
    Style(u32),
    Template(u32),
    Role(RegionRole, i64),
    ScrollWindow(i64),
}

#[derive(Clone, Debug)]
enum Part {
    Atoms(Box<[Atom]>),
    Decorated {
        input: Arc<AtomPlan>,
        decorations: Box<[Decoration]>,
    },
}

#[must_use]
#[derive(Debug, Clone)]
pub(super) struct AtomPlan {
    parts: Sequence<Part>,
    summary: Summary,
}

impl Default for AtomPlan {
    fn default() -> Self {
        Self {
            parts: Sequence::empty(),
            summary: Summary {
                whitespace: true,
                ..Summary::default()
            },
        }
    }
}

impl AtomPlan {
    pub(super) fn from_atoms(atoms: &[Atom]) -> Self {
        record_atom_clones(atoms.len());
        Self::from_owned_atoms(atoms.to_vec())
    }

    pub(super) fn from_owned_atoms(atoms: Vec<Atom>) -> Self {
        if atoms.is_empty() {
            return Self::default();
        }
        let summary = Summary::atoms(&atoms);
        let mut sequence_work = Work::default();
        let mut entries = Vec::with_capacity(atoms.len().div_ceil(16));
        let mut atoms = atoms.into_iter();
        loop {
            let chunk = atoms.by_ref().take(16).collect::<Vec<_>>();
            if chunk.is_empty() {
                break;
            }
            let measure = atoms_measure(&chunk);
            entries.push(
                Entry::new(Arc::new(Part::Atoms(chunk.into_boxed_slice())), measure)
                    .expect("validated native atom measure is nonnegative"),
            );
        }
        let parts = Sequence::from_entries(entries, &mut sequence_work)
            .expect("validated native atom sequence aggregates fit limits");
        record_sequence(sequence_work);
        Self { parts, summary }
    }

    pub(super) fn is_empty(&self) -> bool {
        self.parts.is_empty()
    }

    pub(super) fn append(&self, other: &Self) -> Self {
        if self.is_empty() {
            return other.clone();
        }
        if other.is_empty() {
            return self.clone();
        }
        let mut sequence_work = Work::default();
        let parts = self
            .parts
            .concat(&other.parts, &mut sequence_work)
            .expect("validated native atom sequence aggregates fit limits");
        record_sequence(sequence_work);
        Self {
            parts,
            summary: self.summary.clone().combine(other.summary.clone()),
        }
    }

    pub(super) fn push(&self, atom: Atom) -> Self {
        self.append(&Self::from_single(atom))
    }

    pub(super) fn prepend(&self, atom: Atom) -> Self {
        Self::from_single(atom).append(self)
    }

    pub(super) fn to_vec(&self) -> Vec<Atom> {
        let mut output = Vec::with_capacity(self.summary.atom_count);
        if let Some(root) = self.parts.root() {
            materialize_node(root, &mut output);
        }
        record_materialized(output.len());
        output
    }

    pub(super) fn first(&self) -> Option<Atom> {
        first_node(self.parts.root()?)
    }

    pub(super) fn whitespace_only(&self) -> bool {
        self.summary.whitespace
    }

    pub(super) fn has_noncontent_properties(&self) -> bool {
        self.summary.noncontent
    }

    pub(super) fn own_content(&self, region: i64, index: i64) -> Self {
        if self.is_empty() {
            return self.clone();
        }
        self.decorate(Decoration::OwnContent {
            region,
            index,
            had_owner: self.summary.any_owner,
            had_content: self.summary.any_content,
        })
    }

    pub(super) fn apply_style(&self, style: u32) -> Self {
        self.decorate(Decoration::Style(style))
    }

    pub(super) fn apply_template(&self, template: u32) -> Self {
        self.decorate(Decoration::Template(template))
    }

    pub(super) fn apply_role(&self, role: RegionRole, region: i64) -> Self {
        self.decorate(Decoration::Role(role, region))
    }

    pub(super) fn apply_scroll_window(&self, region: i64) -> Self {
        self.decorate(Decoration::ScrollWindow(region))
    }

    pub(super) fn min_content_width(&self) -> i64 {
        self.summary.runs.maximum
    }

    pub(super) fn width(&self) -> i64 {
        self.parts.measure().width_sum
    }

    fn from_single(atom: Atom) -> Self {
        let summary = Summary::atom(&atom);
        let measure = atom_measure(&atom);
        let mut sequence_work = Work::default();
        let parts = Sequence::from_entries(
            [Entry::new(
                Arc::new(Part::Atoms(vec![atom].into_boxed_slice())),
                measure,
            )
            .expect("validated native atom measure is nonnegative")],
            &mut sequence_work,
        )
        .expect("single native atom sequence fits limits");
        record_sequence(sequence_work);
        Self { parts, summary }
    }

    fn decorate(&self, decoration: Decoration) -> Self {
        if self.is_empty() {
            return self.clone();
        }
        let mut summary = self.summary.clone();
        if let Some(properties) = &mut summary.first_properties {
            apply_decoration(properties, &decoration);
        }
        match &decoration {
            Decoration::OwnContent { .. } => {
                summary.any_owner = true;
                summary.any_content = true;
            }
            Decoration::Style(_) | Decoration::Template(_) | Decoration::Role(_, _) => {
                summary.noncontent = true;
            }
            Decoration::ScrollWindow(_) => {}
        }
        let (input, decorations) = self
            .parts
            .get(0)
            .filter(|_| self.parts.len() == 1)
            .and_then(|entry| match entry.value().as_ref() {
                Part::Decorated { input, decorations } if decorations.len() < 16 => {
                    let mut combined = decorations.to_vec();
                    combined.push(decoration.clone());
                    Some((input.clone(), combined.into_boxed_slice()))
                }
                _ => None,
            })
            .unwrap_or_else(|| (Arc::new(self.clone()), vec![decoration].into_boxed_slice()));
        record_operation_block_writes(decorations.len());
        let measure = self.parts.measure();
        let mut sequence_work = Work::default();
        let parts = Sequence::from_entries(
            [
                Entry::new(Arc::new(Part::Decorated { input, decorations }), measure)
                    .expect("validated native atom plan measure is nonnegative"),
            ],
            &mut sequence_work,
        )
        .expect("decorated native atom sequence fits limits");
        record_sequence(sequence_work);
        Self { parts, summary }
    }
}

fn atom_measure(atom: &Atom) -> Measure {
    let chars = match atom {
        Atom::Text { text, .. } => text.chars().count() as u64,
        Atom::Space { .. } => 1,
    };
    Measure::new(chars, 0, atom.width(), atom.width())
        .expect("validated native atom width is nonnegative")
}

fn atoms_measure(atoms: &[Atom]) -> Measure {
    atoms.iter().fold(Measure::default(), |measure, atom| {
        measure
            .checked_combine(atom_measure(atom))
            .expect("validated native atom measures fit limits")
    })
}

fn apply_decoration(properties: &mut AtomProperties, decoration: &Decoration) {
    record_property_application();
    match decoration {
        Decoration::OwnContent {
            region,
            index,
            had_owner,
            had_content,
        } => {
            if *had_owner {
                let mut owners = properties.owners.clone();
                if let Some(owner) = properties.owner {
                    if !owners.contains(&owner) {
                        owners.push(owner);
                    }
                }
                if !owners.contains(region) {
                    owners.push(*region);
                }
                properties.owner = Some(*region);
                properties.owners = owners;
            } else {
                properties.owner = Some(*region);
                properties.owners = vec![*region];
            }
            if !had_content {
                properties.content = Some(*region);
                properties.content_idx = Some(*index);
            }
        }
        Decoration::Style(style) => properties.style_ids.push(*style),
        Decoration::Template(template) => properties.property_template_ids.push(*template),
        Decoration::Role(role, region) => properties.roles.push(RegionRoleEntry {
            role: *role,
            region_id: *region,
        }),
        Decoration::ScrollWindow(region) => properties.scroll_window = Some(*region),
    }
}

fn decorate_atom(mut atom: Atom, decoration: &Decoration) -> Atom {
    apply_decoration(atom.properties_mut(), decoration);
    atom
}

fn materialize_node(node: &Arc<Node<Part>>, output: &mut Vec<Atom>) {
    match node.view() {
        NodeView::Leaf { entries, .. } => {
            for entry in entries {
                match entry.value().as_ref() {
                    Part::Atoms(atoms) => output.extend(atoms.iter().cloned()),
                    Part::Decorated { input, decorations } => {
                        let start = output.len();
                        if let Some(root) = input.parts.root() {
                            materialize_node(root, output);
                        }
                        for atom in &mut output[start..] {
                            for decoration in decorations {
                                apply_decoration(atom.properties_mut(), decoration);
                            }
                        }
                    }
                }
            }
        }
        NodeView::Branch { left, right, .. } => {
            materialize_node(left, output);
            materialize_node(right, output);
        }
    }
}

fn first_node(node: &Arc<Node<Part>>) -> Option<Atom> {
    match node.view() {
        NodeView::Leaf { entries, .. } => match entries.first()?.value().as_ref() {
            Part::Atoms(atoms) => {
                record_materialized(1);
                Some(atoms.first()?.clone())
            }
            Part::Decorated { input, decorations } => input
                .first()
                .map(|atom| decorations.iter().fold(atom, decorate_atom)),
        },
        NodeView::Branch { left, .. } => first_node(left),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(value: &str, width: i64, cjk: bool, space: bool) -> Atom {
        Atom::Text {
            text: value.to_owned(),
            width,
            cjk,
            space,
            properties: AtomProperties::default(),
        }
    }

    #[test]
    fn decoration_is_lazy_ordered_and_new_padding_is_not_retroactive() {
        reset_work();
        let content = AtomPlan::from_atoms(&[text("x", 1, false, false)])
            .apply_style(3)
            .own_content(7, 2);
        let plan = content.prepend(Atom::Space {
            width: 4,
            properties: AtomProperties::default(),
        });
        assert_eq!(work().materialized_atoms, 0);
        let atoms = plan.to_vec();
        assert!(atoms[0].properties().style_ids.is_empty());
        assert_eq!(atoms[1].properties().style_ids, vec![3]);
        assert_eq!(atoms[1].properties().content, Some(7));
        assert_eq!(atoms[1].properties().content_idx, Some(2));
        assert_eq!(work().materialized_atoms, 2);
    }

    #[test]
    fn own_content_uses_whole_line_owner_and_content_branches() {
        let mut owned = text("a", 1, false, false);
        owned.properties_mut().owner = Some(5);
        owned.properties_mut().owners = vec![5];
        owned.properties_mut().content = Some(4);
        let plan = AtomPlan::from_atoms(&[owned, text("b", 1, false, false)]).own_content(9, 3);
        let atoms = plan.to_vec();
        assert_eq!(atoms[0].properties().content, Some(4));
        assert_eq!(atoms[1].properties().content, None);
        assert_eq!(atoms[0].properties().owner, Some(9));
        assert_eq!(atoms[0].properties().owners, vec![5, 9]);
        assert_eq!(atoms[1].properties().owner, Some(9));
        assert_eq!(atoms[1].properties().owners, vec![9]);
    }

    #[test]
    fn min_content_summary_matches_space_and_cjk_breaks() {
        let plan = AtomPlan::from_atoms(&[
            text("ab", 2, false, false),
            text(" ", 1, false, true),
            text("界", 4, true, false),
            text("cd", 3, false, false),
        ]);
        assert_eq!(plan.min_content_width(), 4);
        assert!(!plan.whitespace_only());
        assert!(!plan.has_noncontent_properties());
        assert!(!plan.is_empty());
        assert!(AtomPlan::default().first().is_none());
    }

    #[test]
    fn append_shares_parts_and_materializes_once() {
        reset_work();
        let left = AtomPlan::from_atoms(&[text("a", 1, false, false)]);
        let right = AtomPlan::from_owned_atoms(vec![text("b", 2, false, false)]);
        let plan = left.append(&right).apply_template(2).apply_scroll_window(8);
        assert_eq!(plan.width(), 3);
        assert_eq!(work().materialized_atoms, 0);
        let atoms = plan.to_vec();
        assert_eq!(atoms.len(), 2);
        assert_eq!(atoms[0].properties().property_template_ids, vec![2]);
        assert_eq!(atoms[1].properties().scroll_window, Some(8));
    }

    #[test]
    fn wide_append_and_decorations_do_no_atom_work_until_materialized() {
        for size in [32, 128, 512, 8192] {
            let atoms = (0..size)
                .map(|_| text("x", 1, false, false))
                .collect::<Vec<_>>();
            let plan = AtomPlan::from_atoms(&atoms);
            reset_work();
            let combined = plan
                .append(&plan)
                .own_content(7, 0)
                .apply_style(1)
                .apply_template(2)
                .apply_role(RegionRole::PaddingLeft, 7)
                .apply_scroll_window(7);
            let lazy = work();
            assert_eq!(lazy.materialized_atoms, 0);
            assert_eq!(lazy.sequence_nodes_created, 6);
            assert!(lazy.sequence_entries_written <= 21, "{lazy:?}");
            assert_eq!(lazy.property_applications, 5);
            assert_eq!(lazy.atom_clones, 0);
            assert_eq!(lazy.operation_block_writes, 15);

            let materialized = combined.to_vec();
            assert_eq!(materialized.len(), size * 2);
            let eager = work();
            assert_eq!(eager.materialized_atoms, (size * 2) as u64);
            assert_eq!(eager.property_applications, 5 + (size * 2 * 5) as u64);
        }
    }

    #[test]
    fn min_content_randomized_summary_matches_vec_oracle() {
        fn oracle(atoms: &[Atom]) -> i64 {
            let mut maximum = 0;
            let mut run = 0_i64;
            for atom in atoms {
                if atom.wrap_space() {
                    maximum = maximum.max(run);
                    run = 0;
                } else if atom.wrap_cjk() {
                    maximum = maximum.max(run).max(atom.width());
                    run = 0;
                } else {
                    run += atom.width();
                }
            }
            maximum.max(run)
        }

        let mut seed = 0x5e91_7ac3_u64;
        for size in 0..257 {
            let mut atoms = Vec::with_capacity(size);
            for _ in 0..size {
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
                let width = ((seed >> 32) % 8 + 1) as i64;
                atoms.push(match seed % 5 {
                    0 => text(" ", width, false, true),
                    1 => text("界", width, true, false),
                    _ => text("x", width, false, false),
                });
            }
            let split = size / 3;
            let plan = AtomPlan::default()
                .append(&AtomPlan::from_atoms(&atoms[..split]))
                .append(&AtomPlan::default())
                .append(&AtomPlan::from_atoms(&atoms[split..]));
            assert_eq!(plan.min_content_width(), oracle(&atoms));
            assert_eq!(plan.is_empty(), atoms.is_empty());
        }
    }

    #[test]
    fn first_counts_one_atom_and_each_lazy_property_application() {
        let plan = AtomPlan::from_atoms(&[text("a", 1, false, false), text("b", 1, false, false)])
            .apply_style(3)
            .apply_template(4);
        reset_work();
        let first = plan.first().unwrap();
        assert_eq!(first.properties().style_ids, vec![3]);
        assert_eq!(first.properties().property_template_ids, vec![4]);
        assert_eq!(work().materialized_atoms, 1);
        assert_eq!(work().property_applications, 2);
        assert_eq!(work().atom_clones, 1);
    }

    #[test]
    fn decoration_blocks_are_bounded_ordered_and_keep_old_fork() {
        let base = AtomPlan::from_owned_atoms(vec![text("x", 1, false, false)]);
        let fork = base.clone();
        let old_root = Arc::clone(base.parts.root().unwrap());
        reset_work();
        let decorated = (0..33).fold(base, |plan, style| plan.apply_style(style));
        assert!(Arc::ptr_eq(fork.parts.root().unwrap(), &old_root));
        assert_eq!(work().materialized_atoms, 0);
        assert_eq!(work().operation_block_writes, 273);

        let mut block_lengths = Vec::new();
        let mut current = &decorated;
        loop {
            let part = current.parts.get(0).unwrap().value().as_ref();
            match part {
                Part::Decorated { input, decorations } => {
                    block_lengths.push(decorations.len());
                    current = input;
                }
                Part::Atoms(_) => break,
            }
        }
        assert_eq!(block_lengths, vec![1, 16, 16]);
        assert_eq!(
            decorated.to_vec()[0].properties().style_ids,
            (0..33).collect::<Vec<_>>()
        );
        assert!(fork.to_vec()[0].properties().style_ids.is_empty());
    }

    #[test]
    fn wide_owned_bootstrap_writes_one_sequence_entry_per_atom_block() {
        let atoms = (0..8192)
            .map(|_| text("x", 1, false, false))
            .collect::<Vec<_>>();
        reset_work();
        let plan = AtomPlan::from_owned_atoms(atoms);
        let bootstrap = work();
        assert_eq!(bootstrap.atom_clones, 0);
        assert_eq!(bootstrap.sequence_entries_written, 512);
        assert_eq!(bootstrap.sequence_nodes_created, 63);
        assert_eq!(plan.width(), 8192);
        assert_eq!(plan.summary.atom_count, 8192);
    }
}
