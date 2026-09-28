//! Retained numeric ownership projection; Lisp owns objects, tags and publication.

use std::collections::{HashMap, HashSet};
use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;
use std::{ptr, slice};

const MAX_NODES: usize = 131_072;
const MAX_PROGRAMS: usize = 131_072;
const MAX_RANGES: usize = 262_144;
const MAX_PROGRAM_OWNERS: usize = 1_048_576;

#[derive(Clone, Default)]
struct Topology {
    parents: HashMap<i64, i64>,
    regions: HashMap<i64, i64>,
}

impl Topology {
    fn validate(&self) -> Option<()> {
        if self.parents.len() > MAX_NODES || self.regions.len() > MAX_NODES {
            return None;
        }
        let mut complete = HashSet::with_capacity(self.parents.len());
        for &node in self.parents.keys() {
            let mut path = HashSet::new();
            let mut cursor = node;
            while cursor != 0 && !complete.contains(&cursor) {
                if !path.insert(cursor) {
                    return None;
                }
                cursor = *self.parents.get(&cursor)?;
            }
            complete.extend(path);
        }
        if self
            .regions
            .values()
            .any(|node| !self.parents.contains_key(node))
        {
            return None;
        }
        Some(())
    }

    fn owners(&self, direct: &[(i64, i64)], layout: &[i64]) -> Option<Vec<(i64, i64)>> {
        let mut attached = HashSet::new();
        let mut owners = Vec::new();
        for &(region, tag) in direct {
            let node = *self.regions.get(&region)?;
            if attached.insert(node) {
                owners.push((node, tag));
            }
            let mut parent = *self.parents.get(&node)?;
            while parent != 0 {
                if attached.insert(parent) {
                    owners.push((parent, 0));
                }
                parent = *self.parents.get(&parent)?;
            }
        }
        // Lisp pushes each newly discovered layout owner before direct owners.
        let mut dependencies = Vec::new();
        for &region in layout {
            let mut node = *self.regions.get(&region)?;
            while node != 0 {
                if attached.insert(node) {
                    dependencies.push((node, 1));
                }
                node = *self.parents.get(&node)?;
            }
        }
        dependencies.reverse();
        dependencies.extend(owners);
        Some(dependencies)
    }
}

#[derive(Clone)]
struct Program {
    direct: Arc<[(i64, i64)]>,
    layout: Arc<[i64]>,
    owners: Arc<[(i64, i64)]>,
    dirty: bool,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct OwnershipRange {
    node: i64,
    tag: i64,
    start: i64,
    end: i64,
}

struct Ownership {
    topology: Arc<Topology>,
    programs: Arc<HashMap<i64, Program>>,
    program_owners: usize,
    capacity: usize,
    ranges: Vec<OwnershipRange>,
    active: HashMap<(i64, i64), usize>,
}

fn update_pairs(
    target: &mut HashMap<i64, i64>,
    pairs: &[i64],
    removals: &[i64],
    parent: bool,
) -> Option<()> {
    if pairs.len() % 2 != 0 || pairs.len() > MAX_NODES * 2 || removals.len() > MAX_NODES {
        return None;
    }
    for &id in removals {
        if id <= 0 {
            return None;
        }
        target.remove(&id);
    }
    for pair in pairs.chunks_exact(2) {
        if pair[0] <= 0 || pair[1] < i64::from(!parent) {
            return None;
        }
        target.insert(pair[0], pair[1]);
    }
    Some(())
}

impl Ownership {
    fn create(parents: &[i64], regions: &[i64], capacity: usize) -> Option<Self> {
        if capacity == 0 || capacity > MAX_RANGES {
            return None;
        }
        let mut topology = Topology::default();
        update_pairs(&mut topology.parents, parents, &[], true)?;
        update_pairs(&mut topology.regions, regions, &[], false)?;
        topology.validate()?;
        Some(Self {
            topology: Arc::new(topology),
            programs: Arc::new(HashMap::new()),
            program_owners: 0,
            capacity,
            ranges: Vec::new(),
            active: HashMap::new(),
        })
    }

    fn fork(
        &self,
        parents: &[i64],
        removed_nodes: &[i64],
        regions: &[i64],
        removed_regions: &[i64],
    ) -> Option<Self> {
        let changed = !(parents.is_empty()
            && removed_nodes.is_empty()
            && regions.is_empty()
            && removed_regions.is_empty());
        let (topology, programs) = if changed {
            let mut topology = (*self.topology).clone();
            update_pairs(&mut topology.parents, parents, removed_nodes, true)?;
            update_pairs(&mut topology.regions, regions, removed_regions, false)?;
            topology.validate()?;
            let nodes: HashSet<i64> = parents
                .chunks_exact(2)
                .map(|p| p[0])
                .chain(removed_nodes.iter().copied())
                .collect();
            let regions: HashSet<i64> = regions
                .chunks_exact(2)
                .map(|p| p[0])
                .chain(removed_regions.iter().copied())
                .collect();
            let mut programs = (*self.programs).clone();
            for program in programs.values_mut() {
                program.dirty |= program.owners.iter().any(|(node, _)| nodes.contains(node))
                    || program
                        .direct
                        .iter()
                        .any(|(region, _)| regions.contains(region))
                    || program.layout.iter().any(|region| regions.contains(region));
            }
            (Arc::new(topology), Arc::new(programs))
        } else {
            (self.topology.clone(), self.programs.clone())
        };
        Some(Self {
            topology,
            programs,
            program_owners: self.program_owners,
            capacity: self.capacity,
            ranges: Vec::new(),
            active: HashMap::new(),
        })
    }

    fn register(&mut self, payload: &[i64]) -> Option<()> {
        if payload.is_empty() {
            return Some(());
        }
        let programs = Arc::make_mut(&mut self.programs);
        let mut offset = 0;
        while offset < payload.len() {
            let header = payload.get(offset..offset.checked_add(3)?)?;
            let id = header[0];
            let direct_count = usize::try_from(header[1]).ok()?;
            let layout_count = usize::try_from(header[2]).ok()?;
            if id < 0
                || programs.contains_key(&id)
                || programs.len() >= MAX_PROGRAMS
                || direct_count > MAX_NODES
                || layout_count > MAX_NODES
            {
                return None;
            }
            offset += 3;
            let direct_end = offset.checked_add(direct_count.checked_mul(2)?)?;
            let direct: Vec<(i64, i64)> = payload
                .get(offset..direct_end)?
                .chunks_exact(2)
                .map(|p| (p[0], p[1]))
                .collect();
            if direct.iter().any(|(region, tag)| *region <= 0 || *tag < 2) {
                return None;
            }
            offset = direct_end;
            let layout_end = offset.checked_add(layout_count)?;
            let layout = payload.get(offset..layout_end)?;
            if layout.iter().any(|region| *region <= 0) {
                return None;
            }
            let owners = self.topology.owners(&direct, layout)?;
            self.program_owners = self.program_owners.checked_add(owners.len())?;
            if self.program_owners > MAX_PROGRAM_OWNERS {
                return None;
            }
            programs.insert(
                id,
                Program {
                    direct: direct.into(),
                    layout: layout.into(),
                    owners: owners.into(),
                    dirty: false,
                },
            );
            offset = layout_end;
        }
        Some(())
    }

    fn project(&mut self, recipes: &[i64], runs: &[i64]) -> Option<()> {
        if runs.len() % 3 != 0 || runs.len() / 3 > MAX_RANGES {
            return None;
        }
        // Retain recipes only for this generation.  Prune before registering
        // replacements so an active-set bound does not include retired owners.
        let used: HashSet<i64> = runs.chunks_exact(3).map(|run| run[0]).collect();
        Arc::make_mut(&mut self.programs).retain(|id, _| used.contains(id));
        self.program_owners = self
            .programs
            .values()
            .map(|program| program.owners.len())
            .sum();
        self.register(recipes)?;
        self.ranges.clear();
        self.active.clear();
        let mut previous_end = 0;
        for run in runs.chunks_exact(3) {
            let id = run[0];
            let start = run[1];
            let end = run[2];
            if start < previous_end || end < start {
                return None;
            }
            previous_end = end;
            if self.programs.get(&id)?.dirty {
                let programs = Arc::make_mut(&mut self.programs);
                let program = programs.get_mut(&id)?;
                let owners = self.topology.owners(&program.direct, &program.layout)?;
                self.program_owners = self
                    .program_owners
                    .checked_sub(program.owners.len())?
                    .checked_add(owners.len())?;
                if self.program_owners > MAX_PROGRAM_OWNERS {
                    return None;
                }
                program.owners = owners.into();
                program.dirty = false;
            }
            for &(node, tag) in self.programs.get(&id)?.owners.iter() {
                let key = (node, tag);
                if let Some(&index) = self.active.get(&key) {
                    if self.ranges[index].end == start {
                        self.ranges[index].end = end;
                        continue;
                    }
                }
                if self.ranges.len() == self.capacity {
                    return None;
                }
                self.active.insert(key, self.ranges.len());
                self.ranges.push(OwnershipRange {
                    node,
                    tag,
                    start,
                    end,
                });
            }
        }
        Arc::make_mut(&mut self.programs).retain(|id, _| used.contains(id));
        self.program_owners = self
            .programs
            .values()
            .map(|program| program.owners.len())
            .sum();
        Some(())
    }
}

unsafe fn input<'a>(values: *const i64, count: usize) -> Option<&'a [i64]> {
    if values.is_null() || count > MAX_PROGRAM_OWNERS * 4 {
        return None;
    }
    Some(unsafe { slice::from_raw_parts(values, count) })
}

#[no_mangle]
/// # Safety
/// Input arrays are live numeric storage owned by the C shim.
pub unsafe extern "C" fn ebox_native_ownership_create(
    parents: *const i64,
    parent_count: usize,
    regions: *const i64,
    region_count: usize,
    capacity: usize,
) -> *mut c_void {
    catch_unwind(|| {
        Ownership::create(
            unsafe { input(parents, parent_count)? },
            unsafe { input(regions, region_count)? },
            capacity,
        )
    })
    .ok()
    .flatten()
    .map_or(ptr::null_mut(), |value| {
        Box::into_raw(Box::new(value)).cast()
    })
}

#[no_mangle]
/// # Safety
/// POINTER is live; input arrays are bounded numeric C-shim storage.
pub unsafe extern "C" fn ebox_native_ownership_fork(
    pointer: *mut c_void,
    parents: *const i64,
    parent_count: usize,
    removed_nodes: *const i64,
    removed_node_count: usize,
    regions: *const i64,
    region_count: usize,
    removed_regions: *const i64,
    removed_region_count: usize,
) -> *mut c_void {
    if pointer.is_null() {
        return ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        unsafe { &*pointer.cast::<Ownership>() }.fork(
            unsafe { input(parents, parent_count)? },
            unsafe { input(removed_nodes, removed_node_count)? },
            unsafe { input(regions, region_count)? },
            unsafe { input(removed_regions, removed_region_count)? },
        )
    }))
    .ok()
    .flatten()
    .map_or(ptr::null_mut(), |value| {
        Box::into_raw(Box::new(value)).cast()
    })
}

#[no_mangle]
/// # Safety
/// POINTER is a private candidate; arrays and output pointers belong to the shim.
pub unsafe extern "C" fn ebox_native_ownership_project(
    pointer: *mut c_void,
    recipes: *const i64,
    recipe_count: usize,
    runs: *const i64,
    run_count: usize,
    output: *mut *const OwnershipRange,
    output_count: *mut usize,
) -> bool {
    if pointer.is_null() || output.is_null() || output_count.is_null() {
        return false;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let ownership = unsafe { &mut *pointer.cast::<Ownership>() };
        ownership.project(unsafe { input(recipes, recipe_count)? }, unsafe {
            input(runs, run_count)?
        })?;
        unsafe {
            *output = ownership.ranges.as_ptr();
            *output_count = ownership.ranges.len();
        }
        Some(())
    }))
    .ok()
    .flatten()
    .is_some()
}

#[no_mangle]
/// # Safety
/// POINTER is live; output pointers belong to the shim.
pub unsafe extern "C" fn ebox_native_ownership_ranges(
    pointer: *mut c_void,
    output: *mut *const OwnershipRange,
    output_count: *mut usize,
) -> bool {
    if pointer.is_null() || output.is_null() || output_count.is_null() {
        return false;
    }
    let ownership = unsafe { &*pointer.cast::<Ownership>() };
    unsafe {
        *output = ownership.ranges.as_ptr();
        *output_count = ownership.ranges.len();
    }
    true
}

#[no_mangle]
/// # Safety
/// POINTER is null or a returned handle, released exactly once.
pub unsafe extern "C" fn ebox_native_ownership_free(pointer: *mut c_void) {
    if !pointer.is_null() {
        drop(unsafe { Box::from_raw(pointer.cast::<Ownership>()) });
    }
}
