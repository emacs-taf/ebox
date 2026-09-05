// Included in layout::tests after the production bootstrap topology is attached.

#[test]
fn retained_topology_bootstrap_records_exact_anonymous_use_paths() {
    use source_topology::LocalStep;
    let leaf = |id| {
        identified(
            text_box(
                id as i64,
                measured_text(vec![vec![cluster("x", 1, None)]]),
                None,
            ),
            id,
            1,
        )
    };
    let nested_owner = identified(child_box(3, child_box(30, leaf(4), None), None), 3, 1);
    let root = identified(
        child_box(
            1,
            LayoutNode::Column {
                node_id: None,
                node_revision: None,
                children: Arc::new(vec![
                    LayoutNode::Row {
                        node_id: None,
                        node_revision: None,
                        children: Arc::new(vec![
                            text_box(20, measured_text(vec![vec![cluster("a", 1, None)]]), None),
                            leaf(2),
                        ]),
                    },
                    context_test_flex(Size::Auto, vec![nested_owner]),
                ]),
            },
            None,
        ),
        1,
        1,
    );
    let full = retained_document(root);
    let (retained, _) = RetainedDocument::bootstrap(full.clone()).unwrap();
    let topology = &retained.topology;
    assert_eq!(topology.root_owner(), 1);
    assert!(topology.incoming_uses(1).is_empty());
    let cases = [
        (
            2,
            1,
            vec![LocalStep::BoxChild, LocalStep::ColumnChild(0)],
            LocalStep::RowChild(1),
        ),
        (
            3,
            1,
            vec![LocalStep::BoxChild, LocalStep::ColumnChild(1)],
            LocalStep::FlexItem(0),
        ),
        (4, 3, vec![LocalStep::BoxChild], LocalStep::BoxChild),
    ];
    let mut use_ids = HashSet::new();
    for (target, parent, path, slot) in cases {
        let uses = topology.incoming_uses(target);
        assert_eq!(uses.len(), 1);
        assert_eq!(uses[0].target_owner, target);
        assert_eq!(uses[0].parent.owner_id, parent);
        assert_eq!(uses[0].parent.path.as_ref(), path.as_slice());
        assert_eq!(uses[0].child_slot, slot);
        assert!(use_ids.insert(uses[0].use_id));
    }
    assert_eq!(topology.build_work().occurrences_written, 3);
    assert_eq!(topology.build_work().path_steps_copied, 5);
    assert_eq!(
        retained.layout_tape(test_context(), None).unwrap(),
        full.layout_tape(test_context(), None).unwrap()
    );
}

#[test]
fn retained_topology_real_deltas_share_lists_across_forks_and_failures() {
    for n in [32, 128, 512] {
        let children = (0..n)
            .map(|i| {
                identified(
                    text_box(
                        i + 2,
                        measured_text(vec![vec![cluster("x", 1, None)]]),
                        None,
                    ),
                    (i + 2) as u64,
                    1,
                )
            })
            .collect();
        let root = identified(
            LayoutNode::Column {
                node_id: None,
                node_revision: None,
                children: Arc::new(children),
            },
            1,
            1,
        );
        let (base, _) = RetainedDocument::bootstrap(retained_document(root)).unwrap();
        let target_id = (n / 2 + 2) as u64;
        let original = Arc::clone(&base.topology);
        let original_list = original.incoming_uses(target_id);
        let patch = |region| {
            context_test_delta(vec![serde_json::json!({
                "node-id": target_id, "expected-revision": 1, "target-revision": 2,
                "slot-patches": [{"slot": 0, "local": {"region-id": region}}]
            })])
        };
        let left = base.apply_delta(patch(100_000)).unwrap().document;
        let right = base.apply_delta(patch(100_001)).unwrap().document;
        for target in [&base, &left, &right] {
            assert!(Arc::ptr_eq(&original, &target.topology));
            assert!(std::ptr::eq(
                original_list,
                target.topology.incoming_uses(target_id)
            ));
            assert_eq!(target.topology.root_owner(), 1);
        }
        assert_eq!(original.incoming_uses(target_id)[0].target_owner, target_id);
        assert_eq!(original.build_work().occurrences_written, n as u64);
        // Later-entry rejection cannot install a partially updated topology.
        let failed = base.apply_delta(context_test_delta(vec![
            serde_json::json!({"node-id": target_id, "expected-revision": 1, "target-revision": 2}),
            serde_json::json!({"node-id": 999_999, "expected-revision": 1, "target-revision": 2}),
        ]));
        assert!(failed.is_err());
        assert!(Arc::ptr_eq(&base.topology, &original));
        assert_eq!(radix_lookup(&base.entries, target_id).unwrap().revision, 1);
    }
}

#[test]
fn retained_topology_identity_is_local_to_one_validated_bootstrap() {
    let leaf = identified(
        text_box(1, measured_text(vec![vec![cluster("x", 1, None)]]), None),
        1,
        1,
    );
    let full = retained_document(leaf.clone());
    let (first, _) = RetainedDocument::bootstrap(full.clone()).unwrap();
    let (second, _) = RetainedDocument::bootstrap(full).unwrap();
    assert!(!Arc::ptr_eq(&first.topology, &second.topology));
    assert!(first.topology.incoming_uses(1).is_empty());
    assert_eq!(first.topology.build_work().occurrences_written, 0);
    let duplicate = identified(
        LayoutNode::Row {
            node_id: None,
            node_revision: None,
            children: Arc::new(vec![leaf.clone(), leaf]),
        },
        2,
        1,
    );
    assert!(RetainedDocument::bootstrap(retained_document(duplicate)).is_err());
    let external = identified(child_box(2, LayoutNode::NodeRef { node_id: 1 }, None), 2, 1);
    assert!(RetainedDocument::bootstrap(retained_document(external)).is_err());
}
