//! Editor-independent retained surface computation.
//!
//! This crate owns only deterministic data transformations.  It deliberately
//! has no editor, FFI, serialization, marker, face, or buffer dependency.

/// Monotonic retained surface revision.
pub type Revision = u64;

/// Half-open coordinate range in one retained surface revision.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TextRange {
    pub start: usize,
    pub end: usize,
}

impl TextRange {
    pub fn new(start: usize, end: usize) -> Result<Self, CommitError> {
        if start > end {
            return Err(CommitError::InvalidRange { start, end });
        }
        Ok(Self { start, end })
    }
}

/// One aligned replacement between base and target revisions.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SpanEdit {
    pub old_start: usize,
    pub old_end: usize,
    pub new_start: usize,
    pub new_end: usize,
}

/// Pure computation result consumed by an editor-specific commit adapter.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommitBatch {
    pub base_revision: Revision,
    pub target_revision: Revision,
    pub base_extent: usize,
    pub target_extent: usize,
    /// Text or semantic state changed in these aligned spans.
    pub semantic_edits: Vec<SpanEdit>,
    /// Only text coordinates changed in these aligned spans.
    pub coordinate_edits: Vec<SpanEdit>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CommitError {
    NonConsecutiveRevision {
        base: Revision,
        target: Revision,
    },
    InvalidRange {
        start: usize,
        end: usize,
    },
}

const MYERS_MAX_SEARCH_DISTANCE: usize = 1024;

fn trace_value(trace: &[isize], distance: usize, diagonal: isize) -> isize {
    let distance = distance as isize;
    if diagonal < -distance || diagonal > distance {
        -1
    } else {
        trace[(diagonal + distance) as usize]
    }
}

fn core_matches<T, F>(
    old: &[T],
    new: &[T],
    equal: &F,
    max_distance: usize,
) -> Option<Vec<(usize, usize, usize)>>
where
    F: Fn(&T, &T) -> bool,
{
    let old_length = old.len();
    let new_length = new.len();
    let maximum = old_length.saturating_add(new_length);
    let bounded = maximum.min(max_distance);
    let mut traces: Vec<Vec<isize>> = Vec::with_capacity(bounded.saturating_add(1));
    let mut final_distance = maximum;
    let mut found = false;

    'search: for distance in 0..=bounded {
        let previous = distance.checked_sub(1).and_then(|index| traces.get(index));
        let mut current = vec![-1; 1 + 2 * distance];
        let mut diagonal = -(distance as isize);
        while diagonal <= distance as isize {
            let down = previous.map(|trace| trace_value(trace, distance - 1, diagonal + 1));
            let right = previous.map(|trace| trace_value(trace, distance - 1, diagonal - 1));
            let mut old_position = if distance == 0 {
                0
            } else if diagonal == -(distance as isize) {
                down.unwrap_or(-1)
            } else if diagonal == distance as isize {
                right.unwrap_or(-1) + 1
            } else if right.unwrap_or(-1) < down.unwrap_or(-1) {
                down.unwrap_or(-1)
            } else {
                right.unwrap_or(-1) + 1
            };
            let mut new_position = old_position - diagonal;
            while old_position >= 0
                && new_position >= 0
                && (old_position as usize) < old_length
                && (new_position as usize) < new_length
                && equal(&old[old_position as usize], &new[new_position as usize])
            {
                old_position += 1;
                new_position += 1;
            }
            current[(diagonal + distance as isize) as usize] = old_position;
            if old_position >= old_length as isize && new_position >= new_length as isize {
                traces.push(current);
                final_distance = distance;
                found = true;
                break 'search;
            }
            diagonal += 2;
        }
        traces.push(current);
    }
    if !found {
        return None;
    }

    let mut old_position = old_length as isize;
    let mut new_position = new_length as isize;
    let mut matches = Vec::new();
    for distance in (1..=final_distance).rev() {
        let previous_distance = distance - 1;
        let previous = &traces[previous_distance];
        let diagonal = old_position - new_position;
        let previous_diagonal = if diagonal == -(distance as isize)
            || (diagonal != distance as isize
                && trace_value(previous, previous_distance, diagonal - 1)
                    < trace_value(previous, previous_distance, diagonal + 1))
        {
            diagonal + 1
        } else {
            diagonal - 1
        };
        let previous_old = trace_value(previous, previous_distance, previous_diagonal);
        let previous_new = previous_old - previous_diagonal;
        if old_position > previous_old && new_position > previous_new {
            let length = (old_position - previous_old).min(new_position - previous_new) as usize;
            matches.push((
                old_position as usize - length,
                new_position as usize - length,
                length,
            ));
        }
        old_position = previous_old;
        new_position = previous_new;
    }
    if old_position > 0 && new_position > 0 {
        let length = old_position.min(new_position) as usize;
        matches.push((
            old_position as usize - length,
            new_position as usize - length,
            length,
        ));
    }
    matches.reverse();
    Some(matches)
}

fn matches<T, F>(old: &[T], new: &[T], equal: &F) -> Vec<(usize, usize, usize)>
where
    F: Fn(&T, &T) -> bool,
{
    let prefix = old
        .iter()
        .zip(new)
        .take_while(|(left, right)| equal(left, right))
        .count();
    let old_rest = &old[prefix..];
    let new_rest = &new[prefix..];
    let suffix = old_rest
        .iter()
        .rev()
        .zip(new_rest.iter().rev())
        .take_while(|(left, right)| equal(left, right))
        .count();
    let old_core = &old_rest[..old_rest.len() - suffix];
    let new_core = &new_rest[..new_rest.len() - suffix];
    let mut result = Vec::new();
    if prefix > 0 {
        result.push((0, 0, prefix));
    }
    if let Some(core) = core_matches(old_core, new_core, equal, MYERS_MAX_SEARCH_DISTANCE) {
        result.extend(
            core.into_iter()
                .map(|(old_start, new_start, length)| {
                    (old_start + prefix, new_start + prefix, length)
                }),
        );
    }
    if suffix > 0 {
        result.push((old.len() - suffix, new.len() - suffix, suffix));
    }
    result
}

fn push_edit(
    edits: &mut Vec<SpanEdit>,
    old_start: usize,
    old_end: usize,
    new_start: usize,
    new_end: usize,
) {
    if old_start == old_end && new_start == new_end {
        return;
    }
    if let Some(previous) = edits.last_mut() {
        if previous.old_end == old_start && previous.new_end == new_start {
            previous.old_end = old_end;
            previous.new_end = new_end;
            return;
        }
    }
    edits.push(SpanEdit {
        old_start,
        old_end,
        new_start,
        new_end,
    });
}

fn coordinate_edits(
    old_len: usize,
    new_len: usize,
    text_matches: &[(usize, usize, usize)],
) -> Vec<SpanEdit> {
    let mut old_position = 0;
    let mut new_position = 0;
    let mut edits = Vec::new();
    for &(matched_old, matched_new, length) in text_matches {
        if old_position < matched_old || new_position < matched_new {
            push_edit(
                &mut edits,
                old_position,
                matched_old,
                new_position,
                matched_new,
            );
        }
        old_position = matched_old + length;
        new_position = matched_new + length;
    }
    push_edit(
        &mut edits,
        old_position,
        old_len,
        new_position,
        new_len,
    );
    edits
}

fn semantic_edits<T, FSemantic>(
    old: &[T],
    new: &[T],
    text_matches: &[(usize, usize, usize)],
    semantic_equal: &FSemantic,
) -> Vec<SpanEdit>
where
    FSemantic: Fn(&T, &T) -> bool,
{
    let mut old_position = 0;
    let mut new_position = 0;
    let mut edits = Vec::new();
    for &(matched_old, matched_new, length) in text_matches {
        if old_position < matched_old || new_position < matched_new {
            push_edit(
                &mut edits,
                old_position,
                matched_old,
                new_position,
                matched_new,
            );
        }
        let mut run_start = None;
        for offset in 0..length {
            let equal = semantic_equal(&old[matched_old + offset], &new[matched_new + offset]);
            match (run_start, equal) {
                (None, false) => run_start = Some(offset),
                (Some(start), true) => {
                    push_edit(
                        &mut edits,
                        matched_old + start,
                        matched_old + offset,
                        matched_new + start,
                        matched_new + offset,
                    );
                    run_start = None;
                }
                _ => {}
            }
        }
        if let Some(start) = run_start {
            push_edit(
                &mut edits,
                matched_old + start,
                matched_old + length,
                matched_new + start,
                matched_new + length,
            );
        }
        old_position = matched_old + length;
        new_position = matched_new + length;
    }
    push_edit(
        &mut edits,
        old_position,
        old.len(),
        new_position,
        new.len(),
    );
    edits
}

/// Diff two retained frames without knowing their editor-specific cell type.
pub fn diff_commit_batch<T, FText, FSemantic>(
    base_revision: Revision,
    target_revision: Revision,
    old: &[T],
    new: &[T],
    text_equal: FText,
    semantic_equal: FSemantic,
) -> Result<CommitBatch, CommitError>
where
    FText: Fn(&T, &T) -> bool,
    FSemantic: Fn(&T, &T) -> bool,
{
    if target_revision != base_revision.saturating_add(1) {
        return Err(CommitError::NonConsecutiveRevision {
            base: base_revision,
            target: target_revision,
        });
    }
    let text_matches = matches(old, new, &text_equal);
    Ok(CommitBatch {
        base_revision,
        target_revision,
        base_extent: old.len(),
        target_extent: new.len(),
        semantic_edits: semantic_edits(old, new, &text_matches, &semantic_equal),
        coordinate_edits: coordinate_edits(old.len(), new.len(), &text_matches),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone, Debug, PartialEq, Eq)]
    struct Cell {
        text: char,
        style: u32,
    }

    #[test]
    fn commit_batch_separates_text_and_style_changes() {
        let old = [
            Cell { text: 'a', style: 1 },
            Cell { text: 'b', style: 1 },
            Cell { text: 'c', style: 1 },
        ];
        let new = [
            Cell { text: 'a', style: 1 },
            Cell { text: 'B', style: 2 },
            Cell { text: 'c', style: 3 },
        ];
        let batch = diff_commit_batch(
            7,
            8,
            &old,
            &new,
            |left, right| left.text == right.text,
            |left, right| left.style == right.style,
        )
        .unwrap();
        assert_eq!(
            batch.coordinate_edits,
            vec![SpanEdit {
                old_start: 1,
                old_end: 2,
                new_start: 1,
                new_end: 2,
            }]
        );
        assert_eq!(
            batch.semantic_edits,
            vec![SpanEdit {
                old_start: 1,
                old_end: 3,
                new_start: 1,
                new_end: 3,
            }]
        );
    }

    #[test]
    fn commit_batch_rejects_revision_gaps() {
        let result = diff_commit_batch::<u8, _, _>(1, 3, &[], &[], |a, b| a == b, |a, b| a == b);
        assert_eq!(
            result,
            Err(CommitError::NonConsecutiveRevision { base: 1, target: 3 })
        );
    }

    #[test]
    fn pathological_diff_degrades_to_one_bounded_edit() {
        let old = vec![b'a'; 30_000];
        let new = vec![b'b'; 30_000];
        let batch = diff_commit_batch(0, 1, &old, &new, |a, b| a == b, |a, b| a == b)
            .unwrap();
        assert_eq!(
            batch.semantic_edits,
            vec![SpanEdit {
                old_start: 0,
                old_end: 30_000,
                new_start: 0,
                new_end: 30_000,
            }]
        );
    }
}
