use super::super::tests::{
    child_box, context_test_delta, identified, nonuniform_text, retained_document, test_context,
};
use super::super::{FlexAlign, FlexDirection, FlexItem, FlexWrap, Size, WrapMode};
use super::*;

fn flex(nodes: Vec<LayoutNode>, direction: FlexDirection, wrap: FlexWrap) -> LayoutNode {
    LayoutNode::Flex {
        node_id: None,
        node_revision: None,
        direction,
        wrap,
        justify: FlexAlign::FlexStart,
        align_items: FlexAlign::FlexStart,
        align_content: FlexAlign::FlexStart,
        width: Size::Pixels { value: 12 },
        height: Size::Auto,
        row_gap: 1,
        column_gap: 1,
        items: Arc::new(
            nodes
                .into_iter()
                .enumerate()
                .map(|(index, node)| FlexItem {
                    node,
                    order: (index % 2) as i64,
                    grow: 0.0,
                    shrink: 1.0,
                    basis: Size::Pixels { value: 3 },
                    align_self: FlexAlign::Auto,
                })
                .collect(),
        ),
    }
}

fn row_id(index: usize) -> u64 {
    index as u64 * 100 + 10
}

fn mixed(size: usize) -> Arc<RetainedDocument> {
    let rows = (0..size)
        .map(|index| {
            let id = row_id(index);
            let nodes = (0..3)
                .map(|item| {
                    let item_id = id + 20 + item;
                    let mut node = child_box(
                        item_id as i64,
                        nonuniform_text(item_id as i64 + 100_000, &[1]),
                        None,
                    );
                    let LayoutNode::Box { wrap_mode, .. } = &mut node else {
                        unreachable!()
                    };
                    *wrap_mode = WrapMode::Word;
                    identified(node, item_id, 1)
                })
                .collect();
            identified(
                LayoutNode::Row {
                    node_id: None,
                    node_revision: None,
                    children: Arc::new(vec![
                        identified(
                            child_box(
                                id as i64 + 1,
                                nonuniform_text(id as i64 + 100_001, &[1]),
                                None,
                            ),
                            id + 1,
                            1,
                        ),
                        identified(
                            flex(nodes, FlexDirection::RowReverse, FlexWrap::Wrap),
                            id + 2,
                            1,
                        ),
                    ]),
                },
                id,
                1,
            )
        })
        .collect();
    let root = identified(
        child_box(
            1,
            LayoutNode::Column {
                node_id: None,
                node_revision: None,
                children: Arc::new(rows),
            },
            None,
        ),
        1,
        1,
    );
    RetainedDocument::bootstrap(retained_document(root))
        .unwrap()
        .0
}

fn text_update(owner: u64, before: u64, slot: u8, text: &str, width: i64) -> serde_json::Value {
    serde_json::json!({"node-id": owner, "expected-revision": before, "target-revision": before + 1,
    "slot-patches": [{"slot": slot, "local": {"content": {"lines": [{"clusters": [{
        "text": text, "width": width, "cjk": false, "space": false,
    }]}]}}}]})
}

fn records(root: &Arc<EvalRecord>) -> Vec<&Arc<EvalRecord>> {
    let mut output = vec![root];
    for child in root.children.values() {
        output.extend(records(child));
    }
    output
}

fn owner_record(root: &Arc<EvalRecord>, owner: u64) -> &Arc<EvalRecord> {
    records(root)
        .into_iter()
        .find(|record| record.source.owner_id == owner && record.source.path.is_empty())
        .expect("fixture owner has a current evaluation")
}

fn assert_oracle(frame: &RetainedFrame, context: LayoutContext, root_width: Option<i64>) {
    assert_eq!(
        frame.materialize_tape(),
        frame.document.layout_tape(context, root_width).unwrap()
    );
}

fn sole_root_scroll_document(child: LayoutNode) -> Arc<RetainedDocument> {
    let mut root = child_box(1, child, None);
    let LayoutNode::Box { height, .. } = &mut root else {
        unreachable!()
    };
    *height = Size::ViewportHeight;
    RetainedDocument::bootstrap(retained_document(identified(root, 1, 1)))
        .unwrap()
        .0
}

#[test]
fn root_scroll_producer_preserves_mixed_children_and_cached_effects() {
    let document = sole_root_scroll_document(LayoutNode::Column {
        node_id: None,
        node_revision: None,
        children: Arc::new(vec![
            LayoutNode::Row {
                node_id: None,
                node_revision: None,
                children: Arc::new(vec![
                    nonuniform_text(2, &[1, 1]),
                    child_box(3, nonuniform_text(4, &[1]), None),
                ]),
            },
            flex(
                vec![nonuniform_text(5, &[1]), nonuniform_text(6, &[1])],
                FlexDirection::Column,
                FlexWrap::Nowrap,
            ),
        ]),
    });
    let context = LayoutContext {
        viewport_height: 1,
        ..test_context()
    };
    let frame = document
        .render_frame_with_root_scroll(None, None, context, None)
        .unwrap();
    assert_oracle(&frame, context, None);
    let producer = frame.root_scroll().expect("sole actual root owner");
    assert_eq!(producer.region_id, 1);
    assert!(producer.full_content.len() > 1);
    assert_eq!(producer.full_content.len(), producer.rendered_content.len());
    assert_eq!(producer.visible_height, 1);
    assert_eq!(frame.root.rendered.scroll_owners, 1);
    assert!(records(&frame.root)
        .into_iter()
        .skip(1)
        .all(|record| record.rendered.root_scroll.is_none()));
    reset_work();
    let reused = document
        .render_frame_with_root_scroll(Some(&frame), None, context, None)
        .unwrap();
    assert_eq!(work().hits, 1);
    assert_eq!(work().body_runs, 0);
    assert!(std::ptr::eq(producer, reused.root_scroll().unwrap()));
}

#[test]
fn root_scroll_producer_rejects_offscreen_nested_owners() {
    let mut nested = child_box(4, nonuniform_text(5, &[1, 1]), None);
    let LayoutNode::Box { height, .. } = &mut nested else {
        unreachable!()
    };
    *height = Size::Lines { value: 1 };
    let document = sole_root_scroll_document(LayoutNode::Column {
        node_id: None,
        node_revision: None,
        children: Arc::new(vec![nonuniform_text(2, &[1, 1, 1]), nested]),
    });
    for height in [1, 20] {
        let context = LayoutContext {
            viewport_height: height,
            ..test_context()
        };
        let frame = document
            .render_frame_with_root_scroll(None, None, context, None)
            .unwrap();
        assert_oracle(&frame, context, None);
        assert!(
            frame.root_scroll().is_none(),
            "nested owner at height {height}"
        );
        assert_eq!(
            frame.root.rendered.scroll_owners,
            if height == 1 { 2 } else { 1 }
        );
        assert!(records(&frame.root)
            .into_iter()
            .any(|record| record.rendered.own_scroll_owner && record.source.path.len() > 1));
        let reused = document
            .render_frame_with_root_scroll(Some(&frame), None, context, None)
            .unwrap();
        assert!(reused.root_scroll().is_none());
    }
}

#[test]
fn root_scroll_owner_summary_distinguishes_measurements_and_final_windows() {
    let document = sole_root_scroll_document(nonuniform_text(2, &[1, 1]));
    let frame = document
        .render_frame_with_root_scroll(
            None,
            None,
            LayoutContext {
                viewport_height: 1,
                ..test_context()
            },
            None,
        )
        .unwrap();
    assert_eq!(frame.root.rendered.scroll_owners, 1);
    for (phase, expected) in [
        (Phase::FlexMeasure, 0),
        (Phase::FlexMinWidth, 0),
        (Phase::FlexAutoMinContent, 0),
        (Phase::FlexMaxWidth, 0),
        (Phase::FlexBasisContent, 0),
        (Phase::FlexBasisWidth, 0),
        (Phase::ContentIntrinsic, 0),
        (Phase::FlexCrossProbe, 0),
        (Phase::FlexFinal, 1),
        (Phase::WindowFull, 1),
        (Phase::WindowFallback, 1),
        (Phase::WindowChildFull, 1),
        (Phase::WindowChildPartial, 2),
    ] {
        let uses = ChildUses::from_fresh(BTreeMap::from([(
            UseSlot {
                path: vec![UseStep::Phase(phase)],
                occurrence: 0,
            },
            Arc::clone(&frame.root),
        )]));
        assert_eq!(uses.scroll_owners(), expected, "{phase:?}");
    }
}

#[test]
fn instrumentation_records_common_entries_without_changing_full_semantics() {
    let document = mixed(3);
    reset_work();
    let frame = document
        .render_frame(None, None, test_context(), None)
        .unwrap();
    let measured = work();
    assert_eq!(measured.hits, 0);
    assert_eq!(measured.lookups, measured.body_runs);
    assert_eq!(
        measured.records_created as usize,
        records(&frame.root).len()
    );
    assert_eq!(measured.caller_edges_written + 1, measured.records_created);
    assert_oracle(&frame, test_context(), None);
    let all = records(&frame.root);
    assert!(all
        .iter()
        .any(|record| matches!(record.source.path.as_ref(), [LocalStep::BoxChild])));
    let phases = all
        .iter()
        .flat_map(|record| record.children.keys())
        .flat_map(|slot| slot.path.iter())
        .filter_map(|step| match step {
            UseStep::Phase(phase) => Some(*phase),
            _ => None,
        })
        .collect::<BTreeSet<_>>();
    for phase in [
        Phase::FlexMeasure,
        Phase::FlexMinWidth,
        Phase::FlexAutoMinContent,
        Phase::FlexMaxWidth,
        Phase::FlexBasisContent,
        Phase::FlexBasisWidth,
        Phase::ContentIntrinsic,
        Phase::FlexCrossProbe,
        Phase::FlexFinal,
    ] {
        assert!(phases.contains(&phase), "missing phase {phase:?}");
    }
    let flex_record = owner_record(&frame.root, row_id(0) + 2);
    let original_positions = flex_record
        .children
        .keys()
        .filter_map(|slot| {
            slot.path.iter().find_map(|step| match step {
                UseStep::Child(LocalStep::FlexItem(index)) => Some(*index),
                _ => None,
            })
        })
        .collect::<BTreeSet<_>>();
    assert_eq!(original_positions, BTreeSet::from([0, 1, 2]));
    // The cache-disabled oracle builds neither records nor caller/source paths.
    reset_work();
    document.layout_tape(test_context(), None).unwrap();
    assert_eq!(work().records_created, 0);
    assert_eq!(work().child_slots_visited, 0);
    assert_eq!(work().source_path_steps_copied, 0);
    assert_eq!(work().use_path_steps_copied, 0);
}

#[test]
fn instrumentation_preserves_literal_column_paths_and_node_ref_boundaries() {
    let nested = LayoutNode::Column {
        node_id: None,
        node_revision: None,
        children: Arc::new(vec![
            nonuniform_text(2, &[2, 9]),
            identified(
                LayoutNode::Column {
                    node_id: None,
                    node_revision: None,
                    children: Arc::new(vec![nonuniform_text(3, &[5]), nonuniform_text(4, &[1])]),
                },
                2,
                1,
            ),
        ]),
    };
    let root = identified(
        child_box(
            1,
            LayoutNode::Column {
                node_id: None,
                node_revision: None,
                children: Arc::new(vec![nested, nonuniform_text(5, &[8])]),
            },
            None,
        ),
        1,
        1,
    );
    let document = RetainedDocument::bootstrap(retained_document(root))
        .unwrap()
        .0;
    let frame = document
        .render_frame(None, None, test_context(), None)
        .unwrap();
    assert_oracle(&frame, test_context(), None);
    let anonymous = records(&frame.root)
        .into_iter()
        .find(|record| {
            record.source.owner_id == 1
                && record.source.path.as_ref()
                    == [
                        LocalStep::BoxChild,
                        LocalStep::ColumnChild(0),
                        LocalStep::ColumnChild(0),
                    ]
        })
        .unwrap();
    assert_eq!(anonymous.rendered.height(), 2);
    let identified = owner_record(&frame.root, 2);
    assert_eq!(identified.children.len(), 2);
    assert!(identified
        .children
        .values()
        .all(|record| record.source.owner_id == 2));
}

#[test]
fn nonzero_mixed_leaf_delta_reuses_unchanged_subtree_bodies() {
    let document = mixed(8);
    let baseline = document
        .render_frame(None, None, test_context(), None)
        .unwrap();
    let update = document
        .apply_delta(context_test_delta(vec![text_update(
            row_id(3) + 1,
            1,
            1,
            "y",
            1,
        )]))
        .unwrap();
    reset_work();
    super::super::TEST_RENDER_NODE_COUNT.with(|count| count.set(Some(0)));
    let target = update
        .document
        .render_frame(Some(&baseline), Some(&update.changes), test_context(), None)
        .unwrap();
    let measured = work();
    let actual_bodies =
        super::super::TEST_RENDER_NODE_COUNT.with(|count| count.replace(None).unwrap());
    assert_eq!(actual_bodies as u64, measured.body_runs);
    assert_oracle(&target, test_context(), None);
    assert!(
        Arc::ptr_eq(
            owner_record(&baseline.root, row_id(7)),
            owner_record(&target.root, row_id(7))
        ),
        "unchanged row record must be shared across the nonzero delta: {measured:?}"
    );
    assert!(!Arc::ptr_eq(
        owner_record(&baseline.root, row_id(3)),
        owner_record(&target.root, row_id(3))
    ));
    assert_eq!(
        measured.body_runs, 5,
        "only root Box/Column, changed Row/Box/Text bodies run"
    );
    assert_eq!(
        measured.hits, 1,
        "the changed row's unchanged Flex is looked up; other rows stay in shared slots"
    );
    assert_eq!(measured.records_created, 5);
}

#[test]
fn fixed_changed_subtree_reuses_bodies_across_sibling_sizes() {
    for size in [32, 128, 512] {
        let document = mixed(size);
        let baseline = document
            .render_frame(None, None, test_context(), None)
            .unwrap();
        for (offset, text) in [(1, "y"), (20, "longer")] {
            let update = document
                .apply_delta(context_test_delta(vec![text_update(
                    row_id(size / 2) + offset,
                    1,
                    1,
                    text,
                    1,
                )]))
                .unwrap();
            reset_work();
            super::super::reset_line_plan_work();
            super::super::TEST_RENDER_NODE_COUNT.with(|count| count.set(Some(0)));
            let target = update
                .document
                .render_frame(Some(&baseline), Some(&update.changes), test_context(), None)
                .unwrap();
            let actual =
                super::super::TEST_RENDER_NODE_COUNT.with(|count| count.replace(None).unwrap());
            let measured = work();
            let line_work = super::super::line_plan_work();
            assert_eq!(measured.body_runs as usize, actual);
            assert!(
                measured.body_runs <= 20,
                "N={size}, offset={offset}: {measured:?}"
            );
            assert!(
                measured.caller_edges_written <= 64,
                "only changed-row calls write caller edges: {measured:?}"
            );
            assert_eq!(measured.dirty_seeds, 1);
            assert!(measured.dirty_addresses_inserted <= 9);
            assert!(Arc::ptr_eq(
                owner_record(&baseline.root, row_id(size - 1)),
                owner_record(&target.root, row_id(size - 1))
            ));
            assert_oracle(&target, test_context(), None);
            eprintln!(
                "N={size}, changed_offset={offset}, eval={measured:?}, lines_mapped={}",
                line_work.lines_mapped
            );
        }
    }
}

#[test]
fn sparse_column_update_does_not_visit_resolve_or_rewrite_unchanged_siblings() {
    for size in [32, 128, 512] {
        let document = mixed(size);
        let baseline = document
            .render_frame(None, None, test_context(), None)
            .unwrap();
        let update = document
            .apply_delta(context_test_delta(vec![text_update(
                row_id(size / 2) + 1,
                1,
                1,
                "changed",
                1,
            )]))
            .unwrap();
        reset_work();
        super::super::reset_resolver_lookups();
        let target = update
            .document
            .render_frame(Some(&baseline), Some(&update.changes), test_context(), None)
            .unwrap();
        let measured = work();
        let resolvers = super::super::resolver_lookups();
        eprintln!("sparse Column N={size}, eval={measured:?}, resolvers={resolvers}");
        assert_oracle(&target, test_context(), None);
        assert_eq!(measured.body_runs, 5);
        assert!(measured.child_slots_visited <= 12, "N={size}: {measured:?}");
        assert!(
            measured.caller_edges_written <= 12,
            "N={size}: {measured:?}"
        );
        assert!(resolvers <= 12, "N={size}: resolvers={resolvers}");
        assert!(Arc::ptr_eq(
            owner_record(&baseline.root, row_id(size - 1)),
            owner_record(&target.root, row_id(size - 1))
        ));
    }
}

fn root_column_record(frame: &RetainedFrame) -> &Arc<EvalRecord> {
    frame
        .root
        .children
        .values()
        .find(|child| child.column.is_some())
        .expect("fixture root has a complete retained Column")
}

fn root_column(frame: &RetainedFrame) -> &Arc<ColumnState> {
    root_column_record(frame).column.as_ref().unwrap()
}

#[test]
fn front_line_growth_and_shrink_share_column_suffix_slots_and_release_old_state() {
    for size in [32, 128, 512] {
        let mut document = mixed(size);
        let mut frame = document
            .render_frame(None, None, test_context(), None)
            .unwrap();
        let original_height = owner_record(&frame.root, row_id(0)).rendered.height();
        for (revision, line_count) in [(1, original_height + 3), (2, 1)] {
            let lines = (0..line_count)
                .map(|_| {
                    serde_json::json!({"clusters":[{
                        "text":"x", "width":1, "cjk":false, "space":false
                    }]})
                })
                .collect::<Vec<_>>();
            let update = document.apply_delta(context_test_delta(vec![serde_json::json!({
                "node-id":row_id(0)+1, "expected-revision":revision, "target-revision":revision+1,
                "slot-patches":[{"slot":1,"local":{"content":{"lines":lines}}}]
            })])).unwrap();
            let old_document = Arc::downgrade(&document);
            let old_column = Arc::downgrade(root_column(&frame));
            reset_work();
            super::super::reset_resolver_lookups();
            super::super::reset_line_plan_work();
            let target = update
                .document
                .render_frame(Some(&frame), Some(&update.changes), test_context(), None)
                .unwrap();
            let measured = work();
            let resolvers = super::super::resolver_lookups();
            let line_work = super::super::line_plan_work();
            assert!(measured.child_slots_visited <= 12, "N={size}: {measured:?}");
            assert!(
                measured.caller_edges_written <= 12,
                "N={size}: {measured:?}"
            );
            assert!(resolvers <= 12, "N={size}: {resolvers}");
            assert_eq!(measured.column_slots_updated, 1);
            assert_eq!(measured.column_slots_built, 0);
            assert_eq!(measured.column_full_rebuilds, 0);
            assert!(
                measured.child_use_nodes_created <= 32,
                "N={size}: {measured:?}"
            );
            assert!(
                measured.column_tree_nodes_created <= 12,
                "N={size}: {measured:?}"
            );
            assert!(root_column(&frame).shares_shape(root_column(&target)));
            assert!(root_column(&frame).shares_slot(root_column(&target), size - 1));
            assert!(!root_column(&frame).shares_slot(root_column(&target), 0));
            assert!(
                Arc::ptr_eq(
                    root_column_record(&frame)
                        .children
                        .0
                        .as_ref()
                        .unwrap()
                        .right
                        .0
                        .as_ref()
                        .unwrap(),
                    root_column_record(&target)
                        .children
                        .0
                        .as_ref()
                        .unwrap()
                        .right
                        .0
                        .as_ref()
                        .unwrap(),
                ),
                "the unchanged right half of the caller-use map must be shared"
            );
            assert_oracle(&target, test_context(), None);
            assert_ne!(frame.materialize_tape(), target.materialize_tape());
            eprintln!("front Column N={size}, lines={line_count}, eval={measured:?}, line_work={line_work:?}");
            document = Arc::clone(&update.document);
            drop(update);
            frame = target;
            assert!(
                old_document.upgrade().is_none(),
                "current slots must not retain the previous source document"
            );
            assert!(
                old_column.upgrade().is_none(),
                "current slots/projections must not retain old parent state"
            );
        }
    }
}

#[test]
fn padded_box_same_parameter_updates_bound_metric_work_and_release_previous_frames() {
    use super::super::VerticalAlign;

    let mut excessive_work = Vec::new();
    for size in [32, 128, 512] {
        for align in [
            VerticalAlign::Top,
            VerticalAlign::Center,
            VerticalAlign::Bottom,
        ] {
            let children = (0..size)
                .map(|index| {
                    let id = index as u64 + 2;
                    identified(nonuniform_text(id as i64, &[1]), id, 1)
                })
                .collect();
            let mut root = child_box(
                1,
                LayoutNode::Column {
                    node_id: None,
                    node_revision: None,
                    children: Arc::new(children),
                },
                None,
            );
            let LayoutNode::Box {
                width,
                height,
                padding_top,
                padding_bottom,
                padding_left,
                padding_right,
                margin_top,
                margin_bottom,
                margin_left,
                margin_right,
                foreground_style,
                vertical_align,
                ..
            } = &mut root
            else {
                unreachable!()
            };
            *width = Size::Pixels { value: 80 };
            *height = if align == VerticalAlign::Top {
                Size::Auto
            } else {
                Size::Lines {
                    value: size as i64 + 12,
                }
            };
            *padding_top = 2;
            *padding_bottom = 3;
            *padding_left = 1;
            *padding_right = 2;
            *margin_top = 1;
            *margin_bottom = 2;
            *margin_left = 1;
            *margin_right = 1;
            *foreground_style = Some(0);
            *vertical_align = align;
            let mut input = retained_document(identified(root, 1, 1));
            input.style_count = 1;
            input.styles.push(
                serde_json::from_value(serde_json::json!({
                    "mode":"set", "face":{"foreground":"red"}
                }))
                .unwrap(),
            );
            let mut document = RetainedDocument::bootstrap(input).unwrap().0;
            let mut frame = document
                .render_frame(None, None, test_context(), None)
                .unwrap();
            assert_oracle(&frame, test_context(), None);
            for (revision, line_count, text) in
                [(1, 1, "same-height"), (2, 4, "grow"), (3, 1, "shrink")]
            {
                let lines = (0..line_count)
                    .map(|_| {
                        serde_json::json!({"clusters":[{
                            "text":text, "width":1, "cjk":false, "space":false
                        }]})
                    })
                    .collect::<Vec<_>>();
                let mut delta = context_test_delta(vec![serde_json::json!({
                    "node-id":2,"expected-revision":revision,"target-revision":revision+1,
                    "slot-patches":[{"slot":0,"local":{"content":{"lines":lines}}}]
                })]);
                delta.style_base_count = 1;
                let update = document.apply_delta(delta).unwrap();
                let old_document = Arc::downgrade(&document);
                let old_frame = Arc::downgrade(&frame);
                let old_column = Arc::downgrade(root_column(&frame));
                let old_projections = frame
                    .root
                    .projections
                    .values()
                    .map(Arc::downgrade)
                    .collect::<Vec<_>>();
                super::super::reset_line_plan_work();
                reset_work();
                let target = update
                    .document
                    .render_frame(Some(&frame), Some(&update.changes), test_context(), None)
                    .unwrap();
                let line_work = super::super::line_plan_work();
                let evaluated = work();
                assert_eq!(evaluated.column_slots_updated, 1);
                assert_eq!(evaluated.column_full_rebuilds, 0);
                assert!(root_column(&frame).shares_slot(root_column(&target), size - 1));
                assert_oracle(&target, test_context(), None);
                assert_ne!(frame.materialize_tape(), target.materialize_tape());
                eprintln!("padded Box N={size}, align={align:?}, update={text}, eval={evaluated:?}, line_work={line_work:?}");
                if line_work.projection_lines_measured > 48
                    || line_work.projection_fallback_lines_measured > 16
                {
                    excessive_work.push(format!("N={size}, align={align:?}, update={text}: projection_lines_measured={}, fallback_lines_measured={}",
                        line_work.projection_lines_measured, line_work.projection_fallback_lines_measured));
                }
                document = Arc::clone(&update.document);
                drop(update);
                frame = target;
                assert!(
                    old_document.upgrade().is_none(),
                    "framing must not retain the old document"
                );
                assert!(
                    old_frame.upgrade().is_none(),
                    "framing must not retain the old frame"
                );
                assert!(
                    old_column.upgrade().is_none(),
                    "framing must not retain the old Column state"
                );
                assert!(
                    old_projections
                        .iter()
                        .all(|state| state.upgrade().is_none()),
                    "framing must not retain old projection states"
                );
            }
        }
    }
    assert!(
        excessive_work.is_empty(),
        "same-parameter padded Box work must remain bounded:\n{}",
        excessive_work.join("\n")
    );
}

#[test]
fn cold_column_and_child_uses_freeze_linear_nodes_and_request_changes_rebuild() {
    for size in [32, 128, 512] {
        let document = mixed(size);
        reset_work();
        let baseline = document
            .render_frame(None, None, test_context(), None)
            .unwrap();
        let cold = work();
        assert_eq!(
            cold.child_use_nodes_created + 1,
            cold.records_created,
            "fresh maps freeze once per current caller edge: {cold:?}"
        );
        assert_eq!(cold.column_slots_built, size as u64);
        assert_eq!(cold.column_tree_nodes_created, 2 * size as u64 - 1);
        let changed_context = LayoutContext {
            viewport_width: 79,
            ..test_context()
        };
        reset_work();
        let target = document
            .render_frame(Some(&baseline), None, changed_context, None)
            .unwrap();
        let changed = work();
        assert_eq!(changed.column_slots_built, size as u64);
        assert_eq!(changed.column_slots_updated, 0);
        assert!(!root_column(&baseline).shares_shape(root_column(&target)));
        assert_oracle(&target, changed_context, None);
    }
}

#[test]
fn intrinsic_column_target_changes_retarget_constant_child_extra_and_count_full_work() {
    let document = RetainedDocument::bootstrap(retained_document(identified(
        LayoutNode::Column {
            node_id: None,
            node_revision: None,
            children: Arc::new(vec![
                identified(nonuniform_text(2, &[1, 9]), 2, 1),
                identified(nonuniform_text(3, &[5, 1]), 3, 1),
            ]),
        },
        1,
        1,
    )))
    .unwrap()
    .0;
    let context = LayoutContext {
        viewport_width_known: false,
        ..test_context()
    };
    let baseline = document.render_frame(None, None, context, None).unwrap();
    assert_eq!(
        baseline
            .materialize_tape()
            .lines
            .iter()
            .map(|line| line.width)
            .collect::<Vec<_>>(),
        [5, 13, 5, 1]
    );
    let lines = [7, 9]
        .into_iter()
        .map(|width| {
            serde_json::json!({"clusters":[{
                "text":"x", "width":width, "cjk":false, "space":false
            }]})
        })
        .collect::<Vec<_>>();
    let update = document
        .apply_delta(context_test_delta(vec![serde_json::json!({
            "node-id":2,"expected-revision":1,"target-revision":2,
            "slot-patches":[{"slot":0,"local":{"content":{"lines":lines}}}]
        })]))
        .unwrap();
    reset_work();
    let target = update
        .document
        .render_frame(Some(&baseline), Some(&update.changes), context, None)
        .unwrap();
    let measured = work();
    assert_eq!(
        target
            .materialize_tape()
            .lines
            .iter()
            .map(|line| line.width)
            .collect::<Vec<_>>(),
        [7, 9, 7, 3]
    );
    assert_eq!(measured.column_full_rebuilds, 1);
    assert_eq!(
        measured.column_slots_updated, 3,
        "one raw replacement and both normalized slots"
    );
    assert_eq!(measured.column_slots_built, 0);
    assert!(Arc::ptr_eq(
        owner_record(&baseline.root, 3),
        owner_record(&target.root, 3)
    ));
    assert_oracle(&target, context, None);
}

#[test]
fn sparse_routes_keep_nested_literal_paths_zero_width_lines_and_node_ref_boundaries() {
    let column = |children| LayoutNode::Column {
        node_id: None,
        node_revision: None,
        children: Arc::new(children),
    };
    let document = RetainedDocument::bootstrap(retained_document(identified(
        child_box(
            1,
            column(vec![
                column(vec![
                    identified(child_box(2, nonuniform_text(12, &[1]), None), 2, 1),
                    column(vec![nonuniform_text(99, &[0])]),
                    identified(nonuniform_text(3, &[1]), 3, 1),
                ]),
                identified(
                    column(vec![identified(
                        child_box(5, nonuniform_text(15, &[1]), None),
                        5,
                        1,
                    )]),
                    4,
                    1,
                ),
            ]),
            None,
        ),
        1,
        1,
    )))
    .unwrap()
    .0;
    let baseline = document
        .render_frame(None, None, test_context(), None)
        .unwrap();
    assert_oracle(&baseline, test_context(), None);
    let update = document
        .apply_delta(context_test_delta(vec![
            text_update(2, 1, 1, "left", 2),
            text_update(5, 1, 1, "right", 3),
        ]))
        .unwrap();
    reset_work();
    let target = update
        .document
        .render_frame(Some(&baseline), Some(&update.changes), test_context(), None)
        .unwrap();
    let measured = work();
    assert_eq!(
        measured.column_slots_updated, 3,
        "two outer slots and one NodeRef Column slot"
    );
    assert_eq!(measured.column_slots_built, 0);
    assert_eq!(measured.column_full_rebuilds, 0);
    assert!(root_column(&baseline).shares_shape(root_column(&target)));
    assert!(root_column(&baseline).shares_slot(root_column(&target), 1));
    assert!(root_column(&baseline).shares_slot(root_column(&target), 2));
    let paths = root_column_record(&target)
        .children
        .keys()
        .map(|slot| slot.path.clone())
        .collect::<Vec<_>>();
    assert_eq!(
        paths,
        vec![
            vec![
                UseStep::Child(LocalStep::ColumnChild(0)),
                UseStep::Child(LocalStep::ColumnChild(0))
            ],
            vec![
                UseStep::Child(LocalStep::ColumnChild(0)),
                UseStep::Child(LocalStep::ColumnChild(1)),
                UseStep::Child(LocalStep::ColumnChild(0))
            ],
            vec![
                UseStep::Child(LocalStep::ColumnChild(0)),
                UseStep::Child(LocalStep::ColumnChild(2))
            ],
            vec![UseStep::Child(LocalStep::ColumnChild(1))],
        ]
    );
    assert!(
        owner_record(&target.root, 4).column.is_some(),
        "NodeRef Column remains its own caller"
    );
    assert_oracle(&target, test_context(), None);
}

#[test]
fn parent_and_child_source_updates_share_only_clean_descendants() {
    let document = mixed(4);
    let baseline = document
        .render_frame(None, None, test_context(), None)
        .unwrap();
    let update = document
        .apply_delta(context_test_delta(vec![
            serde_json::json!({"node-id":1,"expected-revision":1,"target-revision":2,
            "slot-patches":[{"slot":0,"local":{"width":{"kind":"pixels","value":80}}}]}),
            text_update(row_id(1) + 20, 1, 1, "changed", 2),
        ]))
        .unwrap();
    let target = update
        .document
        .render_frame(Some(&baseline), Some(&update.changes), test_context(), None)
        .unwrap();
    assert_oracle(&target, test_context(), None);
    assert!(Arc::ptr_eq(
        owner_record(&baseline.root, row_id(3)),
        owner_record(&target.root, row_id(3))
    ));
    assert!(!Arc::ptr_eq(
        owner_record(&baseline.root, row_id(1) + 20),
        owner_record(&target.root, row_id(1) + 20)
    ));
}

#[test]
fn exact_document_pair_authority_rejects_mismatch_and_cold_renders_without_proof() {
    let document = mixed(2);
    let baseline = document
        .render_frame(None, None, test_context(), None)
        .unwrap();
    let update = document
        .apply_delta(context_test_delta(vec![text_update(
            row_id(0) + 1,
            1,
            1,
            "y",
            1,
        )]))
        .unwrap();
    reset_work();
    let cold = update
        .document
        .render_frame(Some(&baseline), None, test_context(), None)
        .unwrap();
    assert_eq!(work().hits, 0);
    assert!(!Arc::ptr_eq(
        owner_record(&baseline.root, row_id(1)),
        owner_record(&cold.root, row_id(1))
    ));
    assert_oracle(&cold, test_context(), None);
    let foreign = mixed(2);
    let foreign_frame = foreign
        .render_frame(None, None, test_context(), None)
        .unwrap();
    for (target, previous) in [(&document, &baseline), (&update.document, &foreign_frame)] {
        assert!(target
            .render_frame(Some(previous), Some(&update.changes), test_context(), None)
            .is_err());
    }
    assert!(foreign
        .render_frame(None, Some(&update.changes), test_context(), None)
        .is_err());
    assert!(update
        .document
        .render_frame(None, Some(&update.changes), test_context(), None)
        .is_ok());
}

#[test]
fn revision_and_registry_only_changes_reuse_output_and_release_old_document() {
    let document = mixed(1);
    let old_document = Arc::downgrade(&document);
    let baseline = document
        .render_frame(None, None, test_context(), None)
        .unwrap();
    let delta = serde_json::from_value(serde_json::json!({
        "style-base-count":0,"styles-append":[{"mode":"set","face":{"foreground":"red"}}],
        "property-template-base-count":0,"property-template-target-count":1,
        "entries":[{"node-id":1,"expected-revision":1,"target-revision":2}],
    }))
    .unwrap();
    let update = document.apply_delta(delta).unwrap();
    reset_work();
    let target = update
        .document
        .render_frame(Some(&baseline), Some(&update.changes), test_context(), None)
        .unwrap();
    assert_eq!(
        (work().hits, work().body_runs, work().records_created),
        (1, 0, 0)
    );
    assert!(Arc::ptr_eq(&baseline.root, &target.root));
    assert_eq!(target.materialize_tape().style_count, 1);
    assert_oracle(&target, test_context(), None);
    drop(update);
    drop(document);
    assert!(
        old_document.upgrade().is_some(),
        "the old frame still owns its document"
    );
    drop(baseline);
    assert!(
        old_document.upgrade().is_none(),
        "shared evaluation records must not retain old documents"
    );
    assert_eq!(target.document.style_count, 1);
}

fn render_request(
    document: &Arc<RetainedDocument>,
    previous: Option<&RetainedFrame>,
    context: LayoutContext,
    intrinsic: bool,
    size_override: Option<BoxOverride>,
) -> Arc<RetainedFrame> {
    let transaction = RefCell::new(RenderTxn {
        complete_scroll_effects: false,
        previous: previous.map(|frame| Arc::clone(&frame.root)),
        dirty: BTreeMap::new(),
        same_shape: true,
        stack: Vec::new(),
        root: None,
    });
    let scope = RenderScope {
        view: SourceView {
            node: document.effective_node(document.root_id).unwrap(),
            address: SourceAddress {
                owner_id: document.root_id,
                path: Arc::from([]),
            },
        },
        resolver: Some(document),
        transaction: Some(&transaction),
        path: Vec::new(),
    };
    let rendered = scope.render(context, intrinsic, size_override).unwrap();
    let oracle = super::super::render_node_with_override(
        scope.view.node,
        Some(document),
        context,
        intrinsic,
        size_override,
    )
    .unwrap();
    assert_eq!(
        rendered.into_tape(document.style_count),
        oracle.into_tape(document.style_count)
    );
    Arc::new(RetainedFrame {
        document: Arc::clone(document),
        root: transaction.into_inner().root.unwrap(),
    })
}

#[test]
fn requests_preserve_all_context_intrinsic_and_override_fields_exactly() {
    let document = mixed(1);
    let context = test_context();
    let baseline = render_request(&document, None, context, false, None);
    let requests = [
        (
            LayoutContext {
                viewport_width: 79,
                ..context
            },
            false,
            None,
        ),
        (
            LayoutContext {
                viewport_width_known: false,
                ..context
            },
            false,
            None,
        ),
        (
            LayoutContext {
                viewport_height: 23,
                ..context
            },
            false,
            None,
        ),
        (
            LayoutContext {
                inline_auto_width_intrinsic: true,
                ..context
            },
            false,
            None,
        ),
        (context, true, None),
        (context, false, Some(BoxOverride::default())),
        (
            context,
            false,
            Some(BoxOverride {
                content_width: Some(80),
                ..BoxOverride::default()
            }),
        ),
        (
            context,
            false,
            Some(BoxOverride {
                content_height: Some(2),
                ..BoxOverride::default()
            }),
        ),
        (
            context,
            false,
            Some(BoxOverride {
                declared_width: Some(80),
                ..BoxOverride::default()
            }),
        ),
    ];
    for (context, intrinsic, size_override) in requests {
        let changed = render_request(
            &document,
            Some(&baseline),
            context,
            intrinsic,
            size_override,
        );
        assert!(!Arc::ptr_eq(&baseline.root, &changed.root));
        let repeated = render_request(&document, Some(&changed), context, intrinsic, size_override);
        assert!(Arc::ptr_eq(&changed.root, &repeated.root));
    }
}

#[test]
fn viewport_a_b_a_prunes_old_records_and_has_no_history_chain() {
    let document = mixed(2);
    let context_a = test_context();
    let context_b = LayoutContext {
        viewport_height: 42,
        ..context_a
    };
    let a = document.render_frame(None, None, context_a, None).unwrap();
    let old_root = Arc::downgrade(&a.root);
    let old_leaf = Arc::downgrade(owner_record(&a.root, row_id(0) + 20));
    let b = document
        .render_frame(Some(&a), None, context_b, None)
        .unwrap();
    let count = records(&b.root).len();
    drop(a);
    assert!(old_root.upgrade().is_none());
    assert!(old_leaf.upgrade().is_none());
    let weak_b = Arc::downgrade(&b.root);
    let current = document
        .render_frame(Some(&b), None, context_a, None)
        .unwrap();
    drop(b);
    assert!(weak_b.upgrade().is_none());
    assert_eq!(records(&current.root).len(), count);
    assert_oracle(&current, context_a, None);
}

fn scroll_document() -> Arc<RetainedDocument> {
    let children = (2..6)
        .map(|id| {
            let mut node = child_box(id, nonuniform_text(id + 100, &[1, 1, 1]), None);
            let LayoutNode::Box { height, .. } = &mut node else {
                unreachable!()
            };
            *height = Size::Lines { value: 3 };
            identified(node, id as u64, 1)
        })
        .collect();
    let mut root = child_box(
        1,
        LayoutNode::Column {
            node_id: None,
            node_revision: None,
            children: Arc::new(children),
        },
        None,
    );
    let LayoutNode::Box {
        width,
        height,
        content_width_exact,
        scroll_offset,
        ..
    } = &mut root
    else {
        unreachable!()
    };
    *width = Size::Viewport;
    *height = Size::Lines { value: 2 };
    *content_width_exact = false;
    *scroll_offset = 4;
    RetainedDocument::bootstrap(retained_document(identified(root, 1, 1)))
        .unwrap()
        .0
}

#[test]
fn root_scroll_mode_is_explicit_and_cannot_reuse_lazy_caller_records() {
    let document = scroll_document();
    let lazy = document
        .render_frame(None, None, test_context(), None)
        .unwrap();
    assert!(lazy.root_scroll().is_none());
    assert!(!records(&lazy.root)
        .iter()
        .any(|record| record.source.owner_id == 2));
    assert!(records(&lazy.root)
        .iter()
        .all(|record| !record.request.complete_scroll_effects));
    let complete = document
        .render_frame_with_root_scroll(Some(&lazy), None, test_context(), None)
        .unwrap();
    assert_eq!(complete.root_scroll().unwrap().full_content.len(), 12);
    assert!(records(&complete.root)
        .iter()
        .all(|record| record.request.complete_scroll_effects));
    assert!(!Arc::ptr_eq(
        owner_record(&lazy.root, 3),
        owner_record(&complete.root, 3)
    ));
    assert_oracle(&complete, test_context(), None);
    let update = document
        .apply_delta(context_test_delta(vec![serde_json::json!({
            "node-id":2,"expected-revision":1,"target-revision":2,
            "slot-patches":[{"slot":0,"local":{"height":{"kind":"lines","value":5}}}]
        })]))
        .unwrap();
    let target = update
        .document
        .render_frame_with_root_scroll(Some(&complete), Some(&update.changes), test_context(), None)
        .unwrap();
    assert_eq!(target.root_scroll().unwrap().full_content.len(), 14);
    assert_ne!(complete.materialize_tape(), target.materialize_tape());
    assert_oracle(&target, test_context(), None);
    reset_work();
    let lazy_again = update
        .document
        .render_frame(Some(&target), None, test_context(), None)
        .unwrap();
    assert!(work().height_queries > 0);
    assert!(lazy_again.root_scroll().is_none());
    assert!(records(&lazy_again.root)
        .iter()
        .all(|record| !record.request.complete_scroll_effects));
    assert_oracle(&lazy_again, test_context(), None);
}

#[test]
fn unrendered_height_dependencies_invalidate_scroll_and_windows_cache_only_complete_values() {
    let document = scroll_document();
    let baseline = document
        .render_frame(None, None, test_context(), None)
        .unwrap();
    assert_oracle(&baseline, test_context(), None);
    assert!(!records(&baseline.root)
        .iter()
        .any(|record| record.source.owner_id == 2));
    assert_eq!(
        owner_record(&baseline.root, 3).rendered.height(),
        3,
        "the partially visible child is retained as a complete render"
    );
    let update = document
        .apply_delta(context_test_delta(vec![serde_json::json!({
            "node-id":2,"expected-revision":1,"target-revision":2,
            "slot-patches":[{"slot":0,"local":{"height":{"kind":"lines","value":5}}}]
        })]))
        .unwrap();
    reset_work();
    let target = update
        .document
        .render_frame(Some(&baseline), Some(&update.changes), test_context(), None)
        .unwrap();
    assert!(work().body_runs > 0);
    assert!(work().incoming_uses_visited > 0);
    assert!(work().height_queries > 0);
    assert_oracle(&target, test_context(), None);
    assert_ne!(baseline.materialize_tape(), target.materialize_tape());
    assert!(
        Arc::ptr_eq(
            owner_record(&baseline.root, 3),
            owner_record(&target.root, 3)
        ),
        "reuse a complete child while selecting a different visible slice"
    );
    let expanded = update.document.apply_delta(context_test_delta(vec![serde_json::json!({
        "node-id":1,"expected-revision":1,"target-revision":2,
        "slot-patches":[{"slot":0,"local":{"height":{"kind":"lines","value":20},"scroll-offset":0}}]
    })])).unwrap();
    let full = expanded
        .document
        .render_frame(Some(&target), Some(&expanded.changes), test_context(), None)
        .unwrap();
    assert_oracle(&full, test_context(), None);
    let column = full
        .root
        .children
        .values()
        .find(|record| record.source.path.as_ref() == [LocalStep::BoxChild])
        .unwrap();
    assert_eq!(column.rendered.height(), 14);
    let old_column = Arc::downgrade(column);
    let collapsed = expanded.document.apply_delta(context_test_delta(vec![serde_json::json!({
        "node-id":1,"expected-revision":2,"target-revision":3,
        "slot-patches":[{"slot":0,"local":{"height":{"kind":"lines","value":2},"scroll-offset":4}}]
    })])).unwrap();
    let window = collapsed
        .document
        .render_frame(Some(&full), Some(&collapsed.changes), test_context(), None)
        .unwrap();
    assert_oracle(&window, test_context(), None);
    assert!(!window
        .root
        .children
        .values()
        .any(|record| record.source.path.as_ref() == [LocalStep::BoxChild]));
    drop(full);
    assert!(
        old_column.upgrade().is_none(),
        "the old full-column use must be pruned"
    );
}

#[test]
fn nested_reversed_wrapped_flex_preserves_distinct_uses_on_geometry_changes() {
    let inner = flex(
        (11..14)
            .map(|id| {
                identified(
                    child_box(id, nonuniform_text(id + 100, &[1]), None),
                    id as u64,
                    1,
                )
            })
            .collect(),
        FlexDirection::RowReverse,
        FlexWrap::WrapReverse,
    );
    let outer = flex(
        vec![
            identified(child_box(10, inner, None), 10, 1),
            identified(child_box(20, nonuniform_text(120, &[1]), None), 20, 1),
        ],
        FlexDirection::ColumnReverse,
        FlexWrap::WrapReverse,
    );
    let document = RetainedDocument::bootstrap(retained_document(identified(
        child_box(1, outer, None),
        1,
        1,
    )))
    .unwrap()
    .0;
    let baseline = document
        .render_frame(None, None, test_context(), None)
        .unwrap();
    let update = document
        .apply_delta(context_test_delta(vec![text_update(
            12, 1, 1, "expanded", 7,
        )]))
        .unwrap();
    reset_work();
    let target = update
        .document
        .render_frame(Some(&baseline), Some(&update.changes), test_context(), None)
        .unwrap();
    assert!(work().hits > 0);
    assert_oracle(&target, test_context(), None);
    assert!(Arc::ptr_eq(
        owner_record(&baseline.root, 20),
        owner_record(&target.root, 20)
    ));
    assert!(
        records(&target.root)
            .iter()
            .filter(|record| record.source.owner_id == 12 && record.source.path.is_empty())
            .count()
            > 1,
        "a Flex owner has multiple current evaluation uses"
    );
}

fn repeated_calls(
    document: &Arc<RetainedDocument>,
    previous: Option<&RetainedFrame>,
    widths: &[i64],
) -> Arc<RetainedFrame> {
    let source = SourceAddress {
        owner_id: document.root_id,
        path: Arc::from([]),
    };
    let transaction = RefCell::new(RenderTxn {
        complete_scroll_effects: false,
        previous: previous.map(|frame| Arc::clone(&frame.root)),
        dirty: BTreeMap::from([(
            source.clone(),
            DirtyRoute {
                local: true,
                next: BTreeSet::new(),
            },
        )]),
        same_shape: true,
        stack: Vec::new(),
        root: None,
    });
    let node = document.effective_node(document.root_id).unwrap();
    let scope = RenderScope {
        view: SourceView {
            node,
            address: source.clone(),
        },
        resolver: Some(document),
        transaction: Some(&transaction),
        path: Vec::new(),
    };
    let request = EvalRequest {
        root_scroll_request: false,
        complete_scroll_effects: false,
        context: test_context(),
        intrinsic: false,
        size_override: None,
    };
    assert!(transaction
        .borrow_mut()
        .begin(&source, &[], request)
        .is_none());
    let LayoutNode::Box {
        child: Some(child), ..
    } = node
    else {
        unreachable!()
    };
    let child_scope = scope
        .child(LocalStep::BoxChild, child)
        .phase(Phase::ContentIntrinsic);
    let parts = widths
        .iter()
        .map(|width| {
            child_scope
                .render(
                    LayoutContext {
                        viewport_width: *width,
                        ..test_context()
                    },
                    true,
                    None,
                )
                .unwrap()
        })
        .collect();
    transaction
        .borrow_mut()
        .finish(Ok(super::super::stack_vertical(parts)))
        .unwrap();
    Arc::new(RetainedFrame {
        document: Arc::clone(document),
        root: transaction.into_inner().root.unwrap(),
    })
}

#[test]
fn repeated_callsite_uses_have_local_occurrences_and_prune_unused_contexts() {
    let document = RetainedDocument::bootstrap(retained_document(identified(
        child_box(1, nonuniform_text(2, &[1]), None),
        1,
        1,
    )))
    .unwrap()
    .0;
    let baseline = repeated_calls(&document, None, &[10, 20]);
    let keys = baseline.root.children.keys().collect::<Vec<_>>();
    assert_eq!(keys[0].path, keys[1].path);
    assert_eq!((keys[0].occurrence, keys[1].occurrence), (0, 1));
    let removed = Arc::downgrade(baseline.root.children.get(keys[1]).unwrap());
    reset_work();
    let one = repeated_calls(&document, Some(&baseline), &[10]);
    assert_eq!(work().hits, 1);
    assert_eq!(one.root.children.len(), 1);
    drop(baseline);
    assert!(removed.upgrade().is_none());
    reset_work();
    let changed = repeated_calls(&document, Some(&one), &[20]);
    assert_eq!(
        work().hits,
        0,
        "a discarded second occurrence is not a historical context cache"
    );
    assert_eq!(changed.root.children.len(), 1);
}

#[test]
fn independent_nonzero_forks_share_clean_records_without_retaining_old_documents() {
    let document = mixed(3);
    let old_document = Arc::downgrade(&document);
    let baseline = document
        .render_frame(None, None, test_context(), None)
        .unwrap();
    let left_update = document
        .apply_delta(context_test_delta(vec![text_update(
            row_id(0) + 1,
            1,
            1,
            "left",
            1,
        )]))
        .unwrap();
    let right_update = document
        .apply_delta(context_test_delta(vec![text_update(
            row_id(1) + 1,
            1,
            1,
            "right",
            1,
        )]))
        .unwrap();
    let left = left_update
        .document
        .render_frame(
            Some(&baseline),
            Some(&left_update.changes),
            test_context(),
            None,
        )
        .unwrap();
    let right = right_update
        .document
        .render_frame(
            Some(&baseline),
            Some(&right_update.changes),
            test_context(),
            None,
        )
        .unwrap();
    assert_oracle(&left, test_context(), None);
    assert_oracle(&right, test_context(), None);
    assert!(Arc::ptr_eq(
        owner_record(&left.root, row_id(2)),
        owner_record(&right.root, row_id(2))
    ));
    assert!(!Arc::ptr_eq(
        owner_record(&left.root, row_id(0)),
        owner_record(&right.root, row_id(0))
    ));
    let old_changed = Arc::downgrade(owner_record(&baseline.root, row_id(0)));
    drop(left_update);
    drop(right_update);
    drop(baseline);
    drop(document);
    assert!(old_document.upgrade().is_none());
    assert!(
        old_changed.upgrade().is_some(),
        "the independent right fork still shares this row"
    );
    drop(right);
    assert!(old_changed.upgrade().is_none());
    assert_oracle(&left, test_context(), None);
}

#[test]
fn unwinding_discards_current_builder_records_without_mutating_previous_frame() {
    let document = mixed(1);
    let baseline = document
        .render_frame(None, None, test_context(), None)
        .unwrap();
    let baseline_tape = baseline.materialize_tape();
    let created = RefCell::new(None);
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let source = baseline.root.source.clone();
        let transaction = RefCell::new(RenderTxn {
            complete_scroll_effects: false,
            previous: Some(Arc::clone(&baseline.root)),
            dirty: BTreeMap::from([(
                source.clone(),
                DirtyRoute {
                    local: true,
                    next: BTreeSet::new(),
                },
            )]),
            same_shape: true,
            stack: Vec::new(),
            root: None,
        });
        let node = document.effective_node(document.root_id).unwrap();
        let scope = RenderScope {
            view: SourceView {
                node,
                address: source.clone(),
            },
            resolver: Some(&document),
            transaction: Some(&transaction),
            path: Vec::new(),
        };
        transaction
            .borrow_mut()
            .begin(&source, &[], baseline.root.request);
        let LayoutNode::Box {
            child: Some(child), ..
        } = node
        else {
            unreachable!()
        };
        scope
            .child(LocalStep::BoxChild, child)
            .render(
                LayoutContext {
                    viewport_height: 99,
                    ..test_context()
                },
                false,
                None,
            )
            .unwrap();
        *created.borrow_mut() = Some(Arc::downgrade(
            transaction
                .borrow()
                .stack
                .last()
                .unwrap()
                .children
                .values()
                .next()
                .unwrap(),
        ));
        panic!("injected caller failure after child evaluation");
    }));
    assert!(result.is_err());
    assert!(created.into_inner().unwrap().upgrade().is_none());
    assert_eq!(baseline.materialize_tape(), baseline_tape);
    let retry = document
        .render_frame(Some(&baseline), None, test_context(), None)
        .unwrap();
    assert!(Arc::ptr_eq(&retry.root, &baseline.root));
}
