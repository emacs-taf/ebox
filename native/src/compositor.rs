//! Bounded retained layer geometry. Text, properties and publication stay in Emacs.

use std::collections::BinaryHeap;
use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::{ptr, slice};

const MAX_RECORDS: usize = 16384;
const MAX_ROWS: usize = 8192;
const MAX_COORDINATE: f64 = 9007199254740991.0;

#[derive(Clone, Copy, Default)]
struct Placement {
    x: f64,
    row: i64,
    start: f64,
    end: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Change {
    pub index: usize,
    pub x: f64,
    pub row: i64,
    pub start: f64,
    pub end: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Span {
    pub row: usize,
    pub source: i64,
    pub start: f64,
    pub end: f64,
}

#[derive(Clone, Copy)]
struct Edge {
    row: usize,
    pixel: f64,
    source: usize,
    entering: bool,
}

struct Compositor {
    width: f64,
    height: usize,
    placements: Vec<Placement>,
    ranks: Vec<usize>,
    active: Vec<bool>,
    edges: Vec<Edge>,
    stack: BinaryHeap<(usize, usize)>,
    spans: Vec<Span>,
}

fn storage<T: Clone>(count: usize, value: T) -> Option<Vec<T>> {
    let mut values = Vec::new();
    values.try_reserve_exact(count).ok()?;
    values.resize(count, value);
    Some(values)
}

impl Compositor {
    fn new(count: usize, height: usize, width: f64) -> Option<Self> {
        if count > MAX_RECORDS || height > MAX_ROWS || !coordinate(width) || width < 0.0 {
            return None;
        }
        let mut edges = Vec::new();
        edges.try_reserve_exact(2 * count).ok()?;
        let mut stack = BinaryHeap::new();
        stack.try_reserve_exact(count).ok()?;
        let mut spans = Vec::new();
        spans.try_reserve_exact(2 * count + height).ok()?;
        Some(Self {
            width,
            height,
            placements: storage(count, Placement::default())?,
            ranks: storage(count, 0)?,
            active: storage(count, false)?,
            edges,
            stack,
            spans,
        })
    }

    fn emit(&mut self, row: usize, source: Option<usize>, left: f64, right: f64) {
        if left >= right {
            return;
        }
        let source_id = source.map_or(-1, |index| index as i64);
        let origin = source.map_or(0.0, |index| {
            self.placements[index].x - self.placements[index].start
        });
        let start = left - origin;
        let end = right - origin;
        if let Some(previous) = self.spans.last_mut() {
            if previous.row == row && previous.source == source_id && previous.end == start {
                previous.end = end;
                return;
            }
        }
        self.spans.push(Span {
            row,
            source: source_id,
            start,
            end,
        });
    }

    fn run(&mut self, changes: &[Change], order: &[usize], dirty: &[u8]) -> bool {
        let count = self.placements.len();
        if order.len() != count || dirty.len() != self.height {
            return false;
        }
        self.active.fill(false);
        for &index in order {
            if index >= count || self.active[index] {
                return false;
            }
            self.active[index] = true;
        }
        for change in changes {
            if change.index >= count
                || !coordinate(change.x)
                || !coordinate(change.start)
                || !coordinate(change.end)
                || change.start < 0.0
                || change.end < change.start
                || !coordinate(change.x + (change.end - change.start))
                || !coordinate(change.x - change.start)
            {
                return false;
            }
        }
        // All external values are validated before the retained numeric cache changes.
        for change in changes {
            self.placements[change.index] = Placement {
                x: change.x,
                row: change.row,
                start: change.start,
                end: change.end,
            };
        }
        for (rank, &index) in order.iter().enumerate() {
            self.ranks[index] = rank;
        }
        self.active.fill(false);
        self.edges.clear();
        self.spans.clear();
        self.stack.clear();
        for (index, placement) in self.placements.iter().enumerate() {
            let Ok(row) = usize::try_from(placement.row) else {
                continue;
            };
            if row >= self.height || dirty[row] == 0 {
                continue;
            }
            let left = placement.x.max(0.0);
            let right = (placement.x + (placement.end - placement.start)).min(self.width);
            if left < right {
                self.edges.push(Edge {
                    row,
                    pixel: left,
                    source: index,
                    entering: true,
                });
                self.edges.push(Edge {
                    row,
                    pixel: right,
                    source: index,
                    entering: false,
                });
            }
        }
        // Sorting and the sweep use only the storage reserved at preparation.
        self.edges
            .sort_unstable_by(|a, b| a.row.cmp(&b.row).then_with(|| a.pixel.total_cmp(&b.pixel)));
        let mut cursor = 0;
        for (row, &damaged) in dirty.iter().enumerate() {
            if damaged == 0 {
                continue;
            }
            self.stack.clear();
            let mut pixel = 0.0;
            while cursor < self.edges.len() && self.edges[cursor].row == row {
                let next = self.edges[cursor].pixel;
                while self
                    .stack
                    .peek()
                    .is_some_and(|&(_, index)| !self.active[index])
                {
                    self.stack.pop();
                }
                self.emit(row, self.stack.peek().map(|&(_, index)| index), pixel, next);
                while cursor < self.edges.len()
                    && self.edges[cursor].row == row
                    && self.edges[cursor].pixel == next
                {
                    let edge = self.edges[cursor];
                    self.active[edge.source] = edge.entering;
                    if edge.entering {
                        self.stack.push((self.ranks[edge.source], edge.source));
                    }
                    cursor += 1;
                }
                pixel = next;
            }
            self.emit(row, None, pixel, self.width);
        }
        true
    }
}

fn coordinate(value: f64) -> bool {
    value.is_finite() && value.abs() <= MAX_COORDINATE
}

#[no_mangle]
pub extern "C" fn ebox_native_compositor_create(
    count: usize,
    height: usize,
    width: f64,
) -> *mut c_void {
    catch_unwind(|| Compositor::new(count, height, width))
        .ok()
        .flatten()
        .map_or(ptr::null_mut(), |value| {
            Box::into_raw(Box::new(value)).cast()
        })
}

#[no_mangle]
/// # Safety
/// POINTER is a live compositor; input slices and output pointers belong to the C shim.
pub unsafe extern "C" fn ebox_native_compositor_run(
    pointer: *mut c_void,
    changes: *const Change,
    change_count: usize,
    order: *const usize,
    count: usize,
    dirty: *const u8,
    height: usize,
    output: *mut *const Span,
    output_count: *mut usize,
) -> bool {
    if pointer.is_null()
        || changes.is_null()
        || order.is_null()
        || dirty.is_null()
        || output.is_null()
        || output_count.is_null()
    {
        return false;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let compositor = unsafe { &mut *pointer.cast::<Compositor>() };
        let ok = compositor.run(
            unsafe { slice::from_raw_parts(changes, change_count) },
            unsafe { slice::from_raw_parts(order, count) },
            unsafe { slice::from_raw_parts(dirty, height) },
        );
        if ok {
            unsafe {
                *output = compositor.spans.as_ptr();
                *output_count = compositor.spans.len();
            }
        }
        ok
    }))
    .unwrap_or(false)
}

#[no_mangle]
/// # Safety
/// POINTER is null or a compositor returned by create, released exactly once.
pub unsafe extern "C" fn ebox_native_compositor_free(pointer: *mut c_void) {
    if !pointer.is_null() {
        drop(unsafe { Box::from_raw(pointer.cast::<Compositor>()) });
    }
}
