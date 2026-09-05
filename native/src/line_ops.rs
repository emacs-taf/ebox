use super::super::{AtomProperties, HorizontalAlign, Line, RegionRole};
use super::line_metrics::LineMetric;
use std::sync::Arc;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(in crate::layout) enum BoxProjectionSlot {
    ContentPad,
    ContentOwn,
    ContentCollapse,
    VerticalFrame,
    PaddingFrame,
    MarginFrame,
    PaddingEdges,
    BoundaryBorders,
    SurfaceTemplate,
    MarginEdges,
    OverflowEdges,
    ScrollWindow,
    TransparentContent,
}

/// Ordered, cardinality-preserving operations. Each index is in this stage's input.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::layout) enum LineOp {
    PadTo {
        width: i64,
        align: HorizontalAlign,
    },
    AppendSpace(i64),
    OwnContent {
        region: i64,
        start: i64,
    },
    CollapseWhitespace {
        width: i64,
        region: i64,
    },
    EdgeSpaces {
        left: i64,
        left_properties: Arc<AtomProperties>,
        right: i64,
        right_properties: Arc<AtomProperties>,
    },
    Style(u32),
    Template(u32),
    ClearBreaks,
    ScrollWindow(i64),
    FirstStyleRole {
        style: u32,
        region: i64,
    },
    LastStyleRole {
        style: u32,
        region: i64,
    },
}

impl LineOp {
    pub fn apply(&self, mut line: Line, index: usize, length: usize) -> Line {
        match self {
            Self::PadTo { width, align } => line = line.padded(*width, *align),
            Self::AppendSpace(width) => line.push_space(*width),
            Self::OwnContent { region, start } => line.own_content(*region, *start + index as i64),
            Self::CollapseWhitespace { width, region } => {
                line = line.collapse_whitespace_content(*width, *region)
            }
            Self::EdgeSpaces {
                left,
                left_properties,
                right,
                right_properties,
            } => {
                line.prepend_space_with_properties(*left, left_properties.as_ref().clone());
                line.push_space_with_properties(*right, right_properties.as_ref().clone());
            }
            Self::Style(style) => line.apply_style(Some(*style)),
            Self::Template(template) => line.apply_property_template(Some(*template)),
            Self::ScrollWindow(region) => line.atoms = line.atoms.apply_scroll_window(*region),
            Self::FirstStyleRole { style, region } if index == 0 => {
                line.apply_style(Some(*style));
                line.apply_role(RegionRole::BorderTop, *region);
            }
            Self::LastStyleRole { style, region } if index + 1 == length => {
                line.apply_style(Some(*style));
                line.apply_role(RegionRole::BorderBottom, *region);
            }
            Self::FirstStyleRole { .. } | Self::LastStyleRole { .. } | Self::ClearBreaks => {}
        }
        line
    }

    pub(super) fn metric(&self, mut line: LineMetric, index: usize, length: usize) -> LineMetric {
        fn space(line: &mut LineMetric, width: i64, properties: Option<&AtomProperties>) {
            if width <= 0 {
                return;
            }
            line.width += width;
            line.chars += 1;
            if !line.nonempty {
                line.whitespace = true;
            }
            line.nonempty = true;
            line.noncontent |= properties.is_some_and(|p| {
                !p.style_ids.is_empty()
                    || !p.roles.is_empty()
                    || !p.property_template_ids.is_empty()
            });
        }
        match self {
            Self::PadTo { width, align } => {
                let remaining = (*width - line.width).max(0);
                let left = match align {
                    HorizontalAlign::Left => 0,
                    HorizontalAlign::Right => remaining,
                    HorizontalAlign::Center => remaining / 2,
                };
                space(&mut line, left, None);
                space(&mut line, remaining - left, None);
            }
            Self::AppendSpace(width) => space(&mut line, *width, None),
            Self::EdgeSpaces {
                left,
                left_properties,
                right,
                right_properties,
            } => {
                space(&mut line, *left, Some(left_properties));
                space(&mut line, *right, Some(right_properties));
            }
            Self::CollapseWhitespace { width, .. } if line.whitespace && !line.noncontent => {
                line = LineMetric {
                    width: (*width).max(0),
                    chars: u64::from(*width > 0),
                    min_content: 0,
                    nonempty: *width > 0,
                    whitespace: *width > 0,
                    noncontent: false,
                };
            }
            Self::Style(_) | Self::Template(_) => line.noncontent |= line.nonempty,
            Self::FirstStyleRole { .. } if index == 0 => line.noncontent |= line.nonempty,
            Self::LastStyleRole { .. } if index + 1 == length => line.noncontent |= line.nonempty,
            _ => {}
        }
        line
    }

    pub fn apply_break(&self, properties: &mut AtomProperties) {
        match self {
            Self::ClearBreaks => *properties = AtomProperties::default(),
            Self::ScrollWindow(region) => properties.scroll_window = Some(*region),
            _ => {}
        }
    }

    pub fn boundary_sensitive(&self) -> bool {
        matches!(
            self,
            Self::FirstStyleRole { .. } | Self::LastStyleRole { .. }
        )
    }

    pub fn preserves_metrics(&self) -> bool {
        matches!(
            self,
            Self::OwnContent { .. } | Self::ClearBreaks | Self::ScrollWindow(_)
        )
    }
}
