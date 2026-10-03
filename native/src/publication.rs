//! Materialize only proved, coordinate-stable line changes for Emacs publication.
//!
//! The retained evaluator owns the changed line programs. This adapter reuses
//! the ordinary character diff and fragment semantics inside those ranges; it
//! never infers damage by scanning the frame. Anything that changes fragment
//! coordinates/ownership, scroll producers or root metadata uses the full encoder.

use super::line_plan::ChangeKind;
use super::*;
use std::ops::Range;

/// Cold-path fragment boundaries. Paint deltas can share these immutable facts.
pub(crate) fn fragment_starts(tape: &LayoutTape) -> Result<Arc<[u64]>, String> {
    let flat = flatten_layout_tape(tape.clone(), true)?;
    let (text, spaces, properties) = tape_character_encoding_parts(&flat.characters)?;
    let fragments = build_fragment_templates(&text, &spaces, &properties)?;
    Ok(fragments
        .iter()
        .map(|fragment| fragment.start)
        .chain(std::iter::once(flat.characters.len() as u64))
        .collect::<Vec<_>>()
        .into())
}

fn offset_edit(edit: SpanEdit, offset: usize) -> SpanEdit {
    SpanEdit {
        old_start: edit.old_start + offset,
        old_end: edit.old_end + offset,
        new_start: edit.new_start + offset,
        new_end: edit.new_end + offset,
    }
}

/// Prove coordinate- and property-stable space changes from shared line programs.
/// Unlike the ordinary encoder, this never expands unchanged text or its owners.
fn space_width_replacements(
    base: &line_plan::LinePlan,
    next: &line_plan::LinePlan,
    range: Range<usize>,
    boundaries: &[u64],
) -> Option<Vec<(usize, TapeCharacter)>> {
    let mut position = base.prefix_chars(range.start);
    let old_lines = base.slice(range.clone());
    let new_lines = next.slice(range);
    let mut replacements = Vec::new();
    for ((old, old_break), (new, new_break)) in
        old_lines.iter_with_breaks().zip(new_lines.iter_with_breaks())
    {
        match (&old_break, &new_break) {
            (None, None) => {}
            (Some(a), Some(b)) if a.materialize() == b.materialize() => {}
            _ => return None,
        }
        let old_line = old.materialize();
        let new_line = new.materialize();
        for (offset, atom) in old_line.atoms.space_width_changes(&new_line.atoms)? {
            let start = position + offset;
            // A pixel-space remains one complete existing fragment. No new
            // boundary or ownership interval is inferred by this shortcut.
            boundaries.binary_search(&start).ok()?;
            boundaries.binary_search(&(start + 1)).ok()?;
            let Atom::Space { width, properties } = atom else { return None };
            replacements.push((
                usize::try_from(start).ok()?,
                TapeCharacter {
                    value: ' ',
                    pixel_width: Some(u64::try_from(width).ok()?),
                    properties,
                },
            ));
        }
        position += old_line.atoms.char_count() + u64::from(old_break.is_some());
    }
    Some(replacements)
}

pub(crate) fn encode_retained_patch(
    old: &RetainedFrame,
    target: &RetainedFrame,
    change: &PlanChange,
    boundaries: &[u64],
    styles: &[StyleTemplate],
    identity: TapeIdentity,
    output: TapeOutputOptions,
) -> Result<Option<Vec<u8>>, String> {
    let base = old.lines();
    let next = target.lines();
    if !identity.complete
        || output.root_metadata
        || !change.applies_to(base, next)
        || base.len() != next.len()
        || [old, target].iter().any(|frame| {
            frame.scroll_plans().is_some_and(|plans| {
                plans
                    .values()
                    .any(|scroll| scroll.full_content.len() as i64 > scroll.visible_height)
            })
        })
    {
        return Ok(None);
    }
    let characters = base.prefix_chars(base.len());
    if characters != next.prefix_chars(next.len()) || boundaries.last() != Some(&characters) {
        return Ok(None);
    }
    let mut ranges: Vec<Range<usize>> = Vec::new();
    match change.kind() {
        ChangeKind::Same => {}
        // A viewport change may touch every line while leaving every fragment
        // coordinate and owner intact (for example, centered outer spacing).
        // Validate the full declared damage range with the same proofs below
        // rather than rebuilding the complete fragment ledger a second time.
        ChangeKind::ReplaceAll => ranges.push(0..base.len()),
        ChangeKind::Splices(splices) => {
            for splice in splices {
                // A shared suffix can still move. Equal line numbers alone do
                // not prove that its character coordinates remain unchanged.
                if splice.old != splice.new
                    || base.prefix_chars(splice.old.start) != next.prefix_chars(splice.new.start)
                    || base.prefix_chars(splice.old.end) != next.prefix_chars(splice.new.end)
                {
                    return Ok(None);
                }
                // Include the adjoining line programs so changed seams are
                // compared too. The outer breaks belong to unchanged guards.
                let range =
                    splice.old.start.saturating_sub(1)..(splice.old.end + 1).min(base.len());
                if let Some(previous) = ranges.last_mut() {
                    if range.start <= previous.end {
                        previous.end = previous.end.max(range.end);
                        continue;
                    }
                }
                ranges.push(range);
            }
        }
    }
    let style_count = count_u32(styles.len(), "styles")?;
    let compiled_styles = styles
        .iter()
        .map(StyleTemplate::compile)
        .collect::<Result<Vec<_>, _>>()?;
    let mut edits = Vec::new();
    let mut coordinate_edits = Vec::new();
    let mut replacements = Vec::new();
    let mut paint_delta = Vec::new();
    for range in ranges {
        let start = base.prefix_chars(range.start);
        if start != next.prefix_chars(range.start) {
            return Ok(None);
        }
        if let Some(spaces) = space_width_replacements(base, next, range.clone(), boundaries) {
            for (position, character) in spaces {
                edits.push(SpanEdit {
                    old_start: position,
                    old_end: position + 1,
                    new_start: position,
                    new_end: position + 1,
                });
                replacements.push(character);
            }
            continue;
        }
        let old_tape = Rendered::from_line_plan(base.slice(range.clone())).into_tape(style_count);
        let new_tape = Rendered::from_line_plan(next.slice(range)).into_tape(style_count);
        let old_flat = flatten_layout_tape(old_tape, true)?;
        let new_flat = flatten_layout_tape(new_tape, true)?;
        if old_flat.characters.len() != new_flat.characters.len() {
            return Ok(None);
        }
        let end = start + old_flat.characters.len() as u64;
        let (Ok(first), Ok(last)) = (
            boundaries.binary_search(&start),
            boundaries.binary_search(&end),
        ) else {
            return Ok(None);
        };
        let (old_text, old_spaces, old_properties) =
            tape_character_encoding_parts(&old_flat.characters)?;
        let (new_text, new_spaces, new_properties) =
            tape_character_encoding_parts(&new_flat.characters)?;
        let old_fragments = build_fragment_templates(&old_text, &old_spaces, &old_properties)?;
        let new_fragments = build_fragment_templates(&new_text, &new_spaces, &new_properties)?;
        if last - first != old_fragments.len()
            || old_fragments
                .iter()
                .enumerate()
                .any(|(index, fragment)| boundaries[first + index] != start + fragment.start)
        {
            return Ok(None);
        }
        // Compare unpropagated roles. Equal declarations also preserve role
        // propagation through unchanged surrounding fragments, including gaps.
        let Some(delta) = fragment_paint_delta(&old_fragments, &new_fragments) else {
            return Ok(None);
        };
        paint_delta.extend(
            delta
                .into_iter()
                .map(|(index, properties, styles)| (first + index, properties, styles)),
        );
        let batch = tape_commit_batch(&old_flat.characters, &new_flat.characters);
        for edit in coalesce_publication_edits(&batch.semantic_edits) {
            replacements.extend_from_slice(&new_flat.characters[edit.new_start..edit.new_end]);
            edits.push(offset_edit(edit, start as usize));
        }
        coordinate_edits.extend(
            batch
                .coordinate_edits
                .into_iter()
                .map(|edit| offset_edit(edit, start as usize)),
        );
    }
    let replacement_edit = SpanEdit {
        old_start: 0,
        old_end: 0,
        new_start: 0,
        new_end: replacements.len(),
    };
    let replacement_body = encode_patch_replacement_body(
        &replacements,
        &[replacement_edit],
        &compiled_styles,
        output.max_bytes,
    )?;
    let reuse_fragment_template = paint_delta.is_empty();
    let paint_delta = (!reuse_fragment_template).then_some(paint_delta);
    let mut metadata = Some(RootMetadataPayload {
        literal: metadata_literal_from_records(&[])?,
        record_count: 0,
        fragments: Vec::new(),
        fragment_bytes: Vec::new(),
        fragment_count: 0,
    });
    append_scroll_metadata(
        &mut metadata,
        target
            .scroll_plans()
            .map(|plans| (plans, old.scroll_plans())),
        &compiled_styles,
        style_count,
        output.max_bytes,
    )?;
    let combined_payload = encode_patch_combined_payload(
        &replacement_body,
        metadata.as_ref(),
        paint_delta.as_ref(),
        output.max_bytes,
    )?;
    let batch = EmacsCommitBatch {
        core: CommitBatch {
            base_revision: 0,
            target_revision: 1,
            base_extent: characters as usize,
            target_extent: characters as usize,
            semantic_edits: Vec::new(),
            coordinate_edits,
        },
        publication_edits: edits,
        combined_payload,
        metadata_records: metadata
            .as_ref()
            .map_or(0, |metadata| metadata.record_count),
        fragment_bytes: Vec::new(),
        fragment_records: 0,
        reuse_fragment_template,
        reuse_ownership_template: true,
        reuse_mount_projection: true,
        fragment_paint_delta: paint_delta,
    };
    encode_commit_batch(
        &batch,
        identity,
        style_count,
        count_u32(next.len(), "lines")?,
        characters,
        characters,
        output.max_bytes,
    )
    .map(Some)
}
