mod composition_regressions {
    use super::*;

    fn expected_text_line(
        text: &str,
        properties: &AtomProperties,
        break_after: Option<AtomProperties>,
    ) -> TapeLine {
        TapeLine {
            width: text.chars().count() as i64,
            atoms: text
                .chars()
                .map(|character| TapeAtom::Text {
                    text: character.to_string(),
                    width: 1,
                    properties: properties.clone(),
                })
                .collect(),
            break_after,
        }
    }

    #[test]
    fn ownership_before_wrap_and_slice_keeps_its_source_index_anchor() {
        let mut line = Line::from_clusters(&[
            cluster("a", 1, Some(3)),
            cluster("b", 1, Some(3)),
            cluster("c", 1, Some(3)),
            cluster("d", 1, Some(3)),
        ]);
        line.own_content(11, 7);
        line.apply_style(Some(2));
        line.apply_property_template(Some(4));
        let source = Rendered::from_lines(vec![line]);
        let anchored = AtomProperties {
            style_ids: vec![2],
            content: Some(11),
            content_idx: Some(7),
            owner: Some(11),
            owners: vec![11],
            property_template_ids: vec![3, 4],
            ..AtomProperties::default()
        };
        assert_eq!(
            source.clone().into_tape(6),
            LayoutTape {
                style_count: 6,
                lines: vec![expected_text_line("abcd", &anchored, None)],
            }
        );

        let wrapped = wrap_rendered(source, 2, WrapMode::Char);
        let expected_wrapped = LayoutTape {
            style_count: 6,
            lines: vec![
                expected_text_line("ab", &anchored, Some(AtomProperties::default())),
                expected_text_line("cd", &anchored, None),
            ],
        };
        assert_eq!(wrapped.clone().into_tape(6), expected_wrapped);

        let mut selected = slice_rendered(wrapped.clone(), 1, 1);
        assert_eq!(
            selected.clone().into_tape(6),
            LayoutTape {
                style_count: 6,
                lines: vec![expected_text_line("cd", &anchored, None)],
            }
        );
        selected.lines = selected.lines.map_lines(|index, mut line| {
            line.own_content(22, 99 + index as i64);
            line.apply_style(Some(5));
            line.apply_property_template(Some(8));
            line
        });
        let outer = AtomProperties {
            style_ids: vec![2, 5],
            content: Some(11),
            content_idx: Some(7),
            owner: Some(22),
            owners: vec![11, 22],
            property_template_ids: vec![3, 4, 8],
            ..AtomProperties::default()
        };
        assert_eq!(
            selected.into_tape(6),
            LayoutTape {
                style_count: 6,
                lines: vec![expected_text_line("cd", &outer, None)],
            }
        );
        assert_eq!(wrapped.into_tape(6), expected_wrapped);
    }

    fn expected_column_with_prefix(prefix_lines: usize) -> LayoutTape {
        let parent_only = AtomProperties {
            owner: Some(1),
            owners: vec![1],
            ..AtomProperties::default()
        };
        let owned_line = |region_id, content_index| TapeLine {
            width: 4,
            atoms: vec![
                TapeAtom::Text {
                    text: "x".to_owned(),
                    width: 1,
                    properties: AtomProperties {
                        content: Some(region_id),
                        content_idx: Some(content_index),
                        owner: Some(1),
                        owners: vec![region_id, 1],
                        ..AtomProperties::default()
                    },
                },
                TapeAtom::Space {
                    width: 3,
                    properties: parent_only.clone(),
                },
            ],
            break_after: Some(AtomProperties::default()),
        };
        let mut lines = (0..prefix_lines)
            .map(|index| owned_line(10, index as i64))
            .collect::<Vec<_>>();
        lines.push(TapeLine {
            width: 4,
            atoms: vec![
                TapeAtom::Space {
                    width: 0,
                    properties: AtomProperties {
                        content: Some(20),
                        content_idx: Some(0),
                        owner: Some(1),
                        owners: vec![20, 1],
                        ..AtomProperties::default()
                    },
                },
                TapeAtom::Space {
                    width: 4,
                    properties: parent_only.clone(),
                },
            ],
            break_after: Some(AtomProperties::default()),
        });
        let mut suffix = owned_line(30, 0);
        suffix.break_after = None;
        lines.push(suffix);
        LayoutTape {
            style_count: 0,
            lines,
        }
    }

    #[test]
    fn prefix_line_growth_and_shrink_preserve_suffix_carrier_ownership() {
        let mut empty_suffix = nonuniform_text(20, &[0]);
        let LayoutNode::Text { content, .. } = &mut empty_suffix else {
            unreachable!()
        };
        *content = Arc::new(measured_text(vec![Vec::new()]));
        let root = identified(
            child_box(
                1,
                LayoutNode::Column {
                    node_id: None,
                    node_revision: None,
                    children: Arc::new(vec![
                        identified(nonuniform_text(10, &[1]), 2, 1),
                        identified(empty_suffix, 3, 1),
                        identified(nonuniform_text(30, &[1]), 4, 1),
                    ]),
                },
                None,
            ),
            1,
            1,
        );
        let mut document = RetainedDocument::bootstrap(retained_document(root))
            .unwrap()
            .0;
        let context = LayoutContext {
            viewport_width: 4,
            ..test_context()
        };
        let mut frame = document.render_frame(None, None, context, None).unwrap();
        assert_eq!(frame.materialize_tape(), expected_column_with_prefix(1));

        for (revision, prefix_lines) in [(1, 3), (2, 1)] {
            let lines = vec![
                serde_json::json!({"clusters":[{
                    "text":"x","width":1,"cjk":false,"space":false
                }]});
                prefix_lines
            ];
            let applied = document
                .apply_delta(context_test_delta(vec![serde_json::json!({
                    "node-id":2,"expected-revision":revision,"target-revision":revision+1,
                    "slot-patches":[{"slot":0,"local":{"content":{"lines":lines}}}]
                })]))
                .unwrap();
            frame = applied
                .document
                .render_frame(Some(&frame), Some(&applied.changes), context, None)
                .unwrap();
            assert_eq!(
                frame.materialize_tape(),
                expected_column_with_prefix(prefix_lines)
            );
            document = applied.document;
        }
    }
}
