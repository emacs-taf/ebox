use etaf_core::{diff_commit_batch, CommitBatch, SpanEdit};
use serde::Deserialize;
use std::collections::BTreeMap;

#[cfg(test)]
use std::cell::Cell;

#[cfg(test)]
thread_local! {
    static TEST_RENDER_NODE_COUNT: Cell<Option<usize>> = const { Cell::new(None) };
    static TEST_DISABLE_WINDOW_RENDER: Cell<bool> = const { Cell::new(false) };
}

const LAYOUT_VERSION: u32 = 2;
pub const TAPE_VERSION: u16 = 12;
pub const TAPE_HEADER_LEN: usize = 112;
pub const MIN_TAPE_BYTES: usize = TAPE_HEADER_LEN + 5;
const TAPE_MAGIC: &[u8; 4] = b"EBXT";
const TAPE_FLAG_OK: u16 = 1;
const TAPE_FLAG_COMPLETE: u16 = 1 << 1;
const TAPE_FLAG_PATCH: u16 = 1 << 2;
const MAX_LAYOUT_DEPTH: usize = 256;
const MAX_LAYOUT_NODES: usize = 100_000;
pub const MAX_LAYOUT_DIMENSION: i64 = 1_000_000;
const MAX_LAYOUT_WORK_UNITS: usize = 250_000;
const MAX_TAPE_PROPERTY_ENTRIES: usize = MAX_LAYOUT_DEPTH * 16;
const MAX_PROPERTY_TEMPLATE_COUNT: u32 = MAX_LAYOUT_NODES as u32;
const MAX_TAPE_METADATA_RECORDS: usize = MAX_LAYOUT_WORK_UNITS;
const MAX_STYLE_STRING_BYTES: usize = 4096;

const METADATA_ROLE_CONTENT: u8 = 1;
const METADATA_ROLE_CONTENT_OWNER: u8 = 2;
const METADATA_ROLE_PADDING_TOP: u8 = 3;
const METADATA_ROLE_PADDING_BOTTOM: u8 = 4;
const METADATA_ROLE_PADDING_LEFT: u8 = 5;
const METADATA_ROLE_PADDING_RIGHT: u8 = 6;
const METADATA_ROLE_MARGIN_TOP: u8 = 7;
const METADATA_ROLE_MARGIN_BOTTOM: u8 = 8;
const METADATA_ROLE_MARGIN_LEFT: u8 = 9;
const METADATA_ROLE_MARGIN_RIGHT: u8 = 10;
const METADATA_ROLE_BORDER_TOP: u8 = 11;
const METADATA_ROLE_BORDER_BOTTOM: u8 = 12;
const METADATA_ROLE_BORDER_LEFT: u8 = 13;
const METADATA_ROLE_BORDER_RIGHT: u8 = 14;
const METADATA_BOX_EXTENT: u8 = 15;
const METADATA_SCROLL_CONTENT: u8 = 16;
const METADATA_SCROLL_OWNER: u8 = 17;
const METADATA_SCROLL_WINDOW: u8 = 18;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
pub struct LayoutDocument {
    version: u32,
    space_width: i64,
    style_count: u32,
    #[serde(default)]
    property_template_count: u32,
    #[serde(default)]
    pub(crate) styles: Vec<StyleTemplate>,
    root: LayoutNode,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
pub(crate) struct StyleTemplate {
    mode: StyleMode,
    face: FaceTemplate,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum StyleMode {
    Set,
    Add,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct FaceTemplate {
    #[serde(default)]
    lisp: Option<String>,
    #[serde(default)]
    inherit: Option<String>,
    #[serde(default)]
    inverse_video: Option<bool>,
    #[serde(default)]
    foreground: Option<String>,
    #[serde(default)]
    background: Option<String>,
    #[serde(default)]
    overline: Option<ColorOrTrue>,
    #[serde(default)]
    underline: Option<UnderlineTemplate>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(untagged)]
enum ColorOrTrue {
    Boolean(bool),
    Color(String),
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct UnderlineTemplate {
    position: bool,
    #[serde(default)]
    color: Option<String>,
}

#[derive(Debug, Deserialize)]
// Keeping the node payload inline avoids another allocation on the hot layout path.
#[allow(clippy::large_enum_variant)]
#[serde(
    tag = "type",
    rename_all = "kebab-case",
    rename_all_fields = "kebab-case",
    deny_unknown_fields
)]
enum LayoutNode {
    Box {
        region_id: i64,
        content: Option<Box<MeasuredText>>,
        child: Option<Box<LayoutNode>>,
        content_width_exact: bool,
        #[serde(default)]
        content_min_width: Option<i64>,
        width: Size,
        min_width: Size,
        max_width: Size,
        height: Size,
        min_height: Size,
        max_height: Size,
        box_sizing: BoxSizing,
        padding_left: i64,
        padding_right: i64,
        padding_top: i64,
        padding_bottom: i64,
        margin_left: i64,
        margin_right: i64,
        margin_top: i64,
        margin_bottom: i64,
        border_left: i64,
        border_right: i64,
        foreground_style: Option<u32>,
        background_style: Option<u32>,
        border_left_style: Option<u32>,
        border_right_style: Option<u32>,
        border_top_style: Option<u32>,
        border_bottom_style: Option<u32>,
        #[serde(default)]
        surface_template_id: Option<u32>,
        text_align: HorizontalAlign,
        vertical_align: VerticalAlign,
        overflow: Overflow,
        wrap_mode: WrapMode,
        scroll_offset: i64,
    },
    Row {
        children: Vec<LayoutNode>,
    },
    Column {
        children: Vec<LayoutNode>,
    },
    Flex {
        direction: FlexDirection,
        wrap: FlexWrap,
        justify: FlexAlign,
        align_items: FlexAlign,
        align_content: FlexAlign,
        width: Size,
        height: Size,
        row_gap: i64,
        column_gap: i64,
        items: Vec<FlexItem>,
    },
}

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case", deny_unknown_fields)]
enum Size {
    Auto,
    Content,
    None,
    Pixels {
        value: i64,
    },
    Lines {
        value: i64,
    },
    Viewport,
    ViewportHeight,
    MinContent,
    MaxContent,
    FitContent {
        #[serde(default)]
        limit: Option<Box<Size>>,
    },
    Stretch,
    Contain,
    Add {
        values: Box<SizeValues>,
    },
    Subtract {
        values: Box<SizeValues>,
    },
}

#[derive(Debug, Deserialize)]
#[serde(transparent)]
struct SizeValues(Box<[Size]>);

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum FlexDirection {
    Row,
    RowReverse,
    Column,
    ColumnReverse,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum FlexWrap {
    Nowrap,
    Wrap,
    WrapReverse,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum FlexAlign {
    Auto,
    Normal,
    Stretch,
    FlexStart,
    FlexEnd,
    Center,
    Start,
    End,
    SelfStart,
    SelfEnd,
    Left,
    Right,
    Top,
    Bottom,
    Baseline,
    SpaceBetween,
    SpaceAround,
    SpaceEvenly,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct FlexItem {
    node: LayoutNode,
    order: i64,
    grow: f64,
    shrink: f64,
    basis: Size,
    align_self: FlexAlign,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum BoxSizing {
    ContentBox,
    BorderBox,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum HorizontalAlign {
    Left,
    Center,
    Right,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum VerticalAlign {
    Top,
    Center,
    Bottom,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum Overflow {
    Scroll,
    Hidden,
    Visible,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum WrapMode {
    None,
    Word,
    Char,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct MeasuredText {
    lines: Vec<MeasuredLine>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct MeasuredLine {
    clusters: Vec<MeasuredCluster>,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
struct MeasuredCluster {
    text: String,
    width: i64,
    cjk: bool,
    space: bool,
    #[serde(rename = "pixel-space", default)]
    pixel_space: bool,
    #[serde(default, rename = "source-template-id")]
    source_template_id: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LayoutContext {
    pub viewport_width: i64,
    pub viewport_width_known: bool,
    pub viewport_height: i64,
}

#[derive(Debug, Clone, Copy)]
pub struct TapeIdentity {
    pub session_id: u64,
    pub generation: u64,
    pub key: i64,
    pub runtime_revision: u64,
    pub context_hash: i64,
    pub viewport_width: i64,
    pub viewport_height: i64,
    pub root_width: i64,
    pub complete: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct TapeOutputOptions {
    pub root_metadata: bool,
    pub max_bytes: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LayoutTape {
    style_count: u32,
    lines: Vec<TapeLine>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct TapeCharacter {
    value: char,
    pixel_width: Option<u64>,
    properties: AtomProperties,
}

#[derive(Debug)]
struct FlatLayoutTape {
    style_count: u32,
    line_count: u32,
    characters: Vec<TapeCharacter>,
}

type TapePatch = SpanEdit;

#[derive(Debug, Clone, PartialEq, Eq)]
struct TapeLine {
    width: i64,
    atoms: Vec<TapeAtom>,
    break_after: Option<AtomProperties>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum TapeAtom {
    Text {
        text: String,
        width: i64,
        properties: AtomProperties,
    },
    Space {
        width: i64,
        properties: AtomProperties,
    },
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct AtomProperties {
    style_ids: Vec<u32>,
    content: Option<i64>,
    content_idx: Option<i64>,
    owner: Option<i64>,
    owners: Vec<i64>,
    roles: Vec<RegionRoleEntry>,
    scroll_window: Option<i64>,
    property_template_ids: Vec<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RegionRole {
    PaddingLeft,
    PaddingRight,
    PaddingTop,
    PaddingBottom,
    BorderLeft,
    BorderRight,
    BorderTop,
    BorderBottom,
    MarginLeft,
    MarginRight,
    MarginTop,
    MarginBottom,
}

const REGION_ROLES: [RegionRole; 12] = [
    RegionRole::PaddingLeft,
    RegionRole::PaddingRight,
    RegionRole::PaddingTop,
    RegionRole::PaddingBottom,
    RegionRole::BorderLeft,
    RegionRole::BorderRight,
    RegionRole::BorderTop,
    RegionRole::BorderBottom,
    RegionRole::MarginLeft,
    RegionRole::MarginRight,
    RegionRole::MarginTop,
    RegionRole::MarginBottom,
];

#[derive(Debug, Clone, PartialEq, Eq)]
struct RegionRoleEntry {
    role: RegionRole,
    region_id: i64,
}

#[derive(Debug, Clone)]
enum Atom {
    Text {
        text: String,
        width: i64,
        cjk: bool,
        space: bool,
        properties: AtomProperties,
    },
    Space {
        width: i64,
        properties: AtomProperties,
    },
}

#[derive(Debug, Clone, Default)]
struct Line {
    atoms: Vec<Atom>,
    width: i64,
}

impl Line {
    fn from_clusters(clusters: &[MeasuredCluster]) -> Self {
        let mut line = Self::default();
        for cluster in clusters {
            let properties = AtomProperties {
                property_template_ids: cluster.source_template_id.into_iter().collect(),
                ..AtomProperties::default()
            };
            if cluster.pixel_space {
                line.push_space_with_properties(cluster.width, properties);
            } else {
                line.width += cluster.width;
                line.atoms.push(Atom::Text {
                    text: cluster.text.clone(),
                    width: cluster.width,
                    cjk: cluster.cjk,
                    space: cluster.space,
                    properties,
                });
            }
        }
        line
    }

    fn from_atoms(atoms: &[Atom]) -> Self {
        Self {
            atoms: atoms.to_vec(),
            width: atoms.iter().map(Atom::width).sum(),
        }
    }

    fn push_space(&mut self, width: i64) {
        self.push_space_with_properties(width, AtomProperties::default());
    }

    fn push_space_with_properties(&mut self, width: i64, properties: AtomProperties) {
        if width <= 0 {
            return;
        }
        self.width += width;
        self.atoms.push(Atom::Space { width, properties });
    }

    fn prepend_space(&mut self, width: i64) {
        self.prepend_space_with_properties(width, AtomProperties::default());
    }

    fn prepend_space_with_properties(&mut self, width: i64, properties: AtomProperties) {
        if width <= 0 {
            return;
        }
        self.width += width;
        self.atoms.insert(0, Atom::Space { width, properties });
    }

    fn append(&mut self, other: &Self) {
        self.width += other.width;
        self.atoms.extend(other.atoms.iter().cloned());
    }

    fn padded(mut self, target: i64, align: HorizontalAlign) -> Self {
        let remaining = (target - self.width).max(0);
        let left = match align {
            HorizontalAlign::Left => 0,
            HorizontalAlign::Right => remaining,
            HorizontalAlign::Center => remaining / 2,
        };
        self.prepend_space(left);
        self.push_space(remaining - left);
        self
    }

    fn blank(width: i64) -> Self {
        let mut line = Self::default();
        line.push_space(width);
        line
    }

    fn blank_with_properties(width: i64, properties: AtomProperties) -> Self {
        let mut line = Self::default();
        line.push_space_with_properties(width, properties);
        line
    }

    fn whitespace_only(&self) -> bool {
        self.atoms.iter().all(|atom| match atom {
            Atom::Space { .. } => true,
            Atom::Text { text, .. } => text.trim().is_empty(),
        })
    }

    fn has_noncontent_properties(&self) -> bool {
        self.atoms.iter().any(|atom| {
            let properties = atom.properties();
            !properties.style_ids.is_empty()
                || !properties.roles.is_empty()
                || !properties.property_template_ids.is_empty()
        })
    }

    fn own_content(&mut self, region_id: i64, content_idx: i64) {
        let has_owner = self
            .atoms
            .iter()
            .any(|atom| atom.properties().owner.is_some() || !atom.properties().owners.is_empty());
        for atom in &mut self.atoms {
            let properties = atom.properties_mut();
            if has_owner {
                let mut owners = properties.owners.clone();
                if let Some(owner) = properties.owner {
                    if !owners.contains(&owner) {
                        owners.push(owner);
                    }
                }
                if !owners.contains(&region_id) {
                    owners.push(region_id);
                }
                properties.owner = Some(region_id);
                properties.owners = owners;
            } else {
                properties.owner = Some(region_id);
                properties.owners = vec![region_id];
            }
        }
        let has_content = self
            .atoms
            .iter()
            .any(|atom| atom.properties().content.is_some());
        if !has_content {
            for atom in &mut self.atoms {
                let properties = atom.properties_mut();
                properties.content = Some(region_id);
                properties.content_idx = Some(content_idx);
            }
        }
    }

    fn collapse_whitespace_content(self, width: i64, region_id: i64) -> Self {
        if !self.whitespace_only() || self.has_noncontent_properties() {
            return self;
        }
        let first = self.atoms.first().map(Atom::properties);
        let mut properties = AtomProperties {
            content: first
                .and_then(|properties| properties.content)
                .or(Some(region_id)),
            content_idx: first
                .and_then(|properties| properties.content_idx)
                .or(Some(0)),
            owner: Some(region_id),
            ..AtomProperties::default()
        };
        if properties.content.is_none() {
            properties.content = Some(region_id);
        }
        let mut line = Self::default();
        line.push_space_with_properties(width, properties);
        line
    }

    fn apply_style(&mut self, style_id: Option<u32>) {
        if let Some(style_id) = style_id {
            for atom in &mut self.atoms {
                atom.properties_mut().style_ids.push(style_id);
            }
        }
    }

    fn apply_property_template(&mut self, template_id: Option<u32>) {
        if let Some(template_id) = template_id {
            for atom in &mut self.atoms {
                atom.properties_mut()
                    .property_template_ids
                    .push(template_id);
            }
        }
    }

    fn apply_role(&mut self, role: RegionRole, region_id: i64) {
        for atom in &mut self.atoms {
            atom.properties_mut()
                .roles
                .push(RegionRoleEntry { role, region_id });
        }
    }
}

fn region_properties(role: RegionRole, region_id: i64, style_id: Option<u32>) -> AtomProperties {
    AtomProperties {
        style_ids: style_id.into_iter().collect(),
        roles: vec![RegionRoleEntry { role, region_id }],
        ..AtomProperties::default()
    }
}

impl Atom {
    fn width(&self) -> i64 {
        match self {
            Self::Text { width, .. } | Self::Space { width, .. } => *width,
        }
    }

    fn wrap_space(&self) -> bool {
        match self {
            Self::Text { space, .. } => *space,
            Self::Space { .. } => true,
        }
    }

    fn wrap_cjk(&self) -> bool {
        matches!(self, Self::Text { cjk: true, .. })
    }

    fn properties(&self) -> &AtomProperties {
        match self {
            Self::Text { properties, .. } | Self::Space { properties, .. } => properties,
        }
    }

    fn properties_mut(&mut self) -> &mut AtomProperties {
        match self {
            Self::Text { properties, .. } | Self::Space { properties, .. } => properties,
        }
    }
}

#[derive(Debug, Clone)]
struct Rendered {
    lines: Vec<Line>,
    breaks: Vec<AtomProperties>,
}

impl Rendered {
    fn from_lines(lines: Vec<Line>) -> Self {
        let breaks = vec![AtomProperties::default(); lines.len().saturating_sub(1)];
        Self { lines, breaks }
    }

    fn first_width(&self) -> i64 {
        self.lines.first().map_or(0, |line| line.width)
    }

    fn max_width(&self) -> i64 {
        self.lines.iter().map(|line| line.width).max().unwrap_or(0)
    }

    fn min_content_width(&self, wrap_mode: WrapMode) -> i64 {
        if wrap_mode == WrapMode::None {
            return self.max_width();
        }
        self.lines
            .iter()
            .map(|line| {
                let mut maximum = 0;
                let mut run = 0;
                for atom in &line.atoms {
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
            })
            .max()
            .unwrap_or(0)
    }

    fn height(&self) -> i64 {
        self.lines.len() as i64
    }

    fn apply_scroll_window(&mut self, region_id: i64) {
        for line in &mut self.lines {
            for atom in &mut line.atoms {
                atom.properties_mut().scroll_window = Some(region_id);
            }
        }
        for properties in &mut self.breaks {
            properties.scroll_window = Some(region_id);
        }
    }

    fn into_tape(self, style_count: u32) -> LayoutTape {
        let last_line = self.lines.len().saturating_sub(1);
        let mut breaks = self.breaks.into_iter();
        LayoutTape {
            style_count,
            lines: self
                .lines
                .into_iter()
                .enumerate()
                .map(|(index, line)| TapeLine {
                    width: line.width,
                    atoms: line
                        .atoms
                        .into_iter()
                        .map(|atom| match atom {
                            Atom::Text {
                                text,
                                width,
                                properties,
                                ..
                            } => TapeAtom::Text {
                                text,
                                width,
                                properties,
                            },
                            Atom::Space { width, properties } => {
                                TapeAtom::Space { width, properties }
                            }
                        })
                        .collect(),
                    break_after: (index < last_line)
                        .then(|| breaks.next().expect("rendered break invariant")),
                })
                .collect(),
        }
    }
}

struct TapeWriter {
    bytes: Vec<u8>,
    limit: usize,
}

impl TapeWriter {
    fn new(limit: usize) -> Result<Self, String> {
        if limit < TAPE_HEADER_LEN {
            return Err("Native layout tape limit is smaller than its header".to_owned());
        }
        Ok(Self {
            bytes: vec![0; TAPE_HEADER_LEN],
            limit,
        })
    }

    fn reserve(&self, additional: usize) -> Result<(), String> {
        if self
            .bytes
            .len()
            .checked_add(additional)
            .is_none_or(|length| length > self.limit)
        {
            Err("Native layout tape exceeds the result byte limit".to_owned())
        } else {
            Ok(())
        }
    }

    fn push_bytes(&mut self, bytes: &[u8]) -> Result<(), String> {
        self.reserve(bytes.len())?;
        self.bytes.extend_from_slice(bytes);
        Ok(())
    }

    fn push_u32(&mut self, value: u32) -> Result<(), String> {
        self.push_bytes(&value.to_le_bytes())
    }

    fn push_u64(&mut self, value: u64) -> Result<(), String> {
        self.push_bytes(&value.to_le_bytes())
    }

    fn patch_u16(&mut self, offset: usize, value: u16) {
        self.bytes[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
    }

    fn patch_u32(&mut self, offset: usize, value: u32) {
        self.bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
    }

    fn patch_u64(&mut self, offset: usize, value: u64) {
        self.bytes[offset..offset + 8].copy_from_slice(&value.to_le_bytes());
    }

    fn patch_i64(&mut self, offset: usize, value: i64) {
        self.bytes[offset..offset + 8].copy_from_slice(&value.to_le_bytes());
    }

    fn finish_header(
        mut self,
        identity: TapeIdentity,
        ok: bool,
        patch: bool,
        style_count: u32,
        line_count: u32,
        character_count: u64,
    ) -> Vec<u8> {
        let mut flags = if ok { TAPE_FLAG_OK } else { 0 };
        if identity.complete {
            flags |= TAPE_FLAG_COMPLETE;
        }
        if patch {
            flags |= TAPE_FLAG_PATCH;
        }
        let total_len = self.bytes.len() as u64;
        let body_len = total_len - TAPE_HEADER_LEN as u64;
        self.bytes[..4].copy_from_slice(TAPE_MAGIC);
        self.patch_u16(4, TAPE_VERSION);
        self.patch_u16(6, flags);
        self.patch_u32(8, TAPE_HEADER_LEN as u32);
        self.patch_u64(12, total_len);
        self.patch_u64(20, identity.session_id);
        self.patch_u64(28, identity.generation);
        self.patch_i64(36, identity.key);
        self.patch_u64(44, identity.runtime_revision);
        self.patch_i64(52, identity.context_hash);
        self.patch_i64(60, identity.viewport_width);
        self.patch_i64(68, identity.viewport_height);
        self.patch_i64(76, identity.root_width);
        self.patch_u32(84, style_count);
        self.patch_u32(88, line_count);
        self.patch_u64(92, character_count);
        self.patch_u64(100, body_len);
        self.patch_u32(108, 0);
        self.bytes
    }
}

impl RegionRole {
    fn lisp_property(self) -> &'static str {
        match self {
            Self::PaddingLeft => "ebox-pl",
            Self::PaddingRight => "ebox-pr",
            Self::PaddingTop => "ebox-pt",
            Self::PaddingBottom => "ebox-pb",
            Self::BorderLeft => "ebox-bl",
            Self::BorderRight => "ebox-br",
            Self::BorderTop => "ebox-bt",
            Self::BorderBottom => "ebox-bb",
            Self::MarginLeft => "ebox-ml",
            Self::MarginRight => "ebox-mr",
            Self::MarginTop => "ebox-mt",
            Self::MarginBottom => "ebox-mb",
        }
    }

    fn metadata_kind(self) -> u8 {
        match self {
            Self::PaddingLeft => METADATA_ROLE_PADDING_LEFT,
            Self::PaddingRight => METADATA_ROLE_PADDING_RIGHT,
            Self::PaddingTop => METADATA_ROLE_PADDING_TOP,
            Self::PaddingBottom => METADATA_ROLE_PADDING_BOTTOM,
            Self::BorderLeft => METADATA_ROLE_BORDER_LEFT,
            Self::BorderRight => METADATA_ROLE_BORDER_RIGHT,
            Self::BorderTop => METADATA_ROLE_BORDER_TOP,
            Self::BorderBottom => METADATA_ROLE_BORDER_BOTTOM,
            Self::MarginLeft => METADATA_ROLE_MARGIN_LEFT,
            Self::MarginRight => METADATA_ROLE_MARGIN_RIGHT,
            Self::MarginTop => METADATA_ROLE_MARGIN_TOP,
            Self::MarginBottom => METADATA_ROLE_MARGIN_BOTTOM,
        }
    }
}

fn count_u32(value: usize, label: &str) -> Result<u32, String> {
    u32::try_from(value).map_err(|_| format!("Native layout tape has too many {label}"))
}

fn tape_width(value: i64, label: &str) -> Result<u64, String> {
    u64::try_from(value).map_err(|_| format!("Native layout tape has negative {label}"))
}

#[derive(Debug)]
struct TapeSpaceSpan {
    start: u64,
    width: u64,
}

#[derive(Debug)]
struct TapePropertySpan {
    start: u64,
    end: u64,
    properties: AtomProperties,
}

#[derive(Debug)]
struct LiteralInterval {
    start: u64,
    end: u64,
    properties: String,
}

#[derive(Debug)]
struct TapeMetadataRecord {
    kind: u8,
    region_id: i64,
    index: u32,
    start: u64,
    end: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct FragmentTemplate {
    start: u64,
    end: u64,
    line: u64,
    roles: Vec<(&'static str, i64)>,
    content_owner: Option<i64>,
    content_index: Option<i64>,
    property_template_ids: Vec<u32>,
    style_ids: Vec<u32>,
}

type FragmentRoles = Vec<(&'static str, i64)>;
type FragmentOwnershipSpan = (u64, u64, FragmentRoles);
type RegionMountKey = (i64, Vec<&'static str>);
type RegionMountSpan = (RegionMountKey, u64, u64);
type FragmentStyleDelta = Vec<(usize, Vec<u32>)>;

fn propagated_fragment_roles(fragments: &[FragmentTemplate]) -> Vec<Vec<(&'static str, i64)>> {
    let mut propagated = vec![Vec::new(); fragments.len()];
    let mut previous = Vec::new();
    for (index, fragment) in fragments.iter().enumerate() {
        if fragment.roles.is_empty() {
            propagated[index] = previous.clone();
        } else {
            previous = fragment.roles.clone();
            propagated[index] = previous.clone();
        }
    }
    let mut next = Vec::new();
    for index in (0..fragments.len()).rev() {
        if fragments[index].roles.is_empty() {
            for role in &next {
                if !propagated[index].contains(role) {
                    propagated[index].push(*role);
                }
            }
        } else {
            next = fragments[index].roles.clone();
        }
    }
    propagated
}

fn fragment_ownership_spans(fragments: &[FragmentTemplate]) -> Vec<FragmentOwnershipSpan> {
    let mut spans: Vec<FragmentOwnershipSpan> = Vec::new();
    for (fragment, roles) in fragments.iter().zip(propagated_fragment_roles(fragments)) {
        if let Some(previous) = spans.last_mut() {
            if previous.1 == fragment.start && previous.2 == roles {
                previous.1 = fragment.end;
                continue;
            }
        }
        spans.push((fragment.start, fragment.end, roles));
    }
    spans
}

fn fragment_region_mount_projection(fragments: &[FragmentTemplate]) -> Vec<RegionMountSpan> {
    let mut spans: Vec<RegionMountSpan> = Vec::new();
    let mut active: BTreeMap<RegionMountKey, usize> = BTreeMap::new();
    for fragment in fragments {
        let mut roles_by_region: BTreeMap<i64, Vec<&'static str>> = BTreeMap::new();
        for (role, region_id) in &fragment.roles {
            roles_by_region.entry(*region_id).or_default().push(*role);
        }
        for (region_id, roles) in roles_by_region {
            let key = (region_id, roles);
            if let Some(index) = active.get(&key).copied() {
                if spans[index].2 == fragment.start {
                    spans[index].2 = fragment.end;
                    continue;
                }
            }
            let index = spans.len();
            spans.push((key.clone(), fragment.start, fragment.end));
            active.insert(key, index);
        }
    }
    spans
}

fn fragment_style_delta(
    old: &[FragmentTemplate],
    target: &[FragmentTemplate],
) -> Option<FragmentStyleDelta> {
    if old.len() != target.len() {
        return None;
    }
    let mut delta = Vec::new();
    for (index, (old, target)) in old.iter().zip(target).enumerate() {
        if old.start != target.start
            || old.end != target.end
            || old.line != target.line
            || old.roles != target.roles
            || old.content_owner != target.content_owner
            || old.content_index != target.content_index
            || old.property_template_ids != target.property_template_ids
        {
            return None;
        }
        if old.style_ids != target.style_ids {
            delta.push((index, target.style_ids.clone()));
        }
    }
    Some(delta)
}

#[derive(Debug)]
struct CompiledStyle {
    mode: StyleMode,
    face: String,
}

fn validate_style_string(value: &str, label: &str) -> Result<(), String> {
    if value.len() > MAX_STYLE_STRING_BYTES {
        return Err(format!("Native layout {label} exceeds its byte limit"));
    }
    Ok(())
}

fn push_lisp_string(output: &mut String, value: &str) {
    output.push('"');
    for character in value.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            character if character.is_control() => {
                output.push_str(&format!("\\u{:04x}", character as u32));
            }
            character => output.push(character),
        }
    }
    output.push('"');
}

fn push_property(output: &mut String, first: &mut bool, name: &str, value: &str) {
    if !*first {
        output.push(' ');
    }
    *first = false;
    output.push_str(name);
    output.push(' ');
    output.push_str(value);
}

impl FaceTemplate {
    fn validate(&self) -> Result<(), String> {
        if let Some(lisp) = &self.lisp {
            validate_style_string(lisp, "face literal")?;
            if self.inherit.is_some()
                || self.inverse_video.is_some()
                || self.foreground.is_some()
                || self.background.is_some()
                || self.overline.is_some()
                || self.underline.is_some()
            {
                return Err("Native layout literal face cannot mix typed fields".to_owned());
            }
            return Ok(());
        }
        if self.inherit.is_none()
            && self.inverse_video.is_none()
            && self.foreground.is_none()
            && self.background.is_none()
            && self.overline.is_none()
            && self.underline.is_none()
        {
            return Err("Native layout face template is empty".to_owned());
        }
        if let Some(inherit) = &self.inherit {
            if inherit != "default" {
                return Err("Native layout inherit face must be default".to_owned());
            }
        }
        if self.inverse_video == Some(false) {
            return Err("Native layout inverse-video face must be true".to_owned());
        }
        if let Some(value) = &self.foreground {
            validate_style_string(value, "foreground color")?;
        }
        if let Some(value) = &self.background {
            validate_style_string(value, "background color")?;
        }
        if let Some(value) = &self.overline {
            match value {
                ColorOrTrue::Boolean(true) => {}
                ColorOrTrue::Boolean(false) => {
                    return Err("Native layout overline face must be true or a color".to_owned());
                }
                ColorOrTrue::Color(color) => {
                    validate_style_string(color, "overline color")?;
                }
            }
        }
        if let Some(underline) = &self.underline {
            if !underline.position {
                return Err("Native layout underline position must be true".to_owned());
            }
            if let Some(color) = &underline.color {
                validate_style_string(color, "underline color")?;
            }
        }
        Ok(())
    }

    fn to_lisp(&self) -> String {
        if let Some(lisp) = &self.lisp {
            return lisp.clone();
        }
        let mut output = String::from("(");
        let mut first = true;
        if self.inherit.as_deref() == Some("default") {
            push_property(&mut output, &mut first, ":inherit", "default");
        }
        if self.inverse_video == Some(true) {
            push_property(&mut output, &mut first, ":inverse-video", "t");
        }
        if let Some(color) = &self.foreground {
            let mut value = String::new();
            push_lisp_string(&mut value, color);
            push_property(&mut output, &mut first, ":foreground", &value);
        }
        if let Some(color) = &self.background {
            let mut value = String::new();
            push_lisp_string(&mut value, color);
            push_property(&mut output, &mut first, ":background", &value);
        }
        if let Some(overline) = &self.overline {
            let value = match overline {
                ColorOrTrue::Boolean(true) => "t".to_owned(),
                ColorOrTrue::Boolean(false) => unreachable!("validated face template"),
                ColorOrTrue::Color(color) => {
                    let mut value = String::new();
                    push_lisp_string(&mut value, color);
                    value
                }
            };
            push_property(&mut output, &mut first, ":overline", &value);
        }
        if let Some(underline) = &self.underline {
            let mut value = String::from("(:position t");
            if let Some(color) = &underline.color {
                value.push_str(" :color ");
                push_lisp_string(&mut value, color);
            }
            value.push(')');
            push_property(&mut output, &mut first, ":underline", &value);
        }
        output.push(')');
        output
    }
}

impl StyleTemplate {
    fn compile(&self) -> Result<CompiledStyle, String> {
        self.face.validate()?;
        Ok(CompiledStyle {
            mode: self.mode,
            face: self.face.to_lisp(),
        })
    }
}

fn composed_face(
    properties: &AtomProperties,
    styles: &[CompiledStyle],
) -> Result<Option<String>, String> {
    if properties.style_ids.len() > MAX_TAPE_PROPERTY_ENTRIES {
        return Err("Native layout tape has too many style layers".to_owned());
    }
    let mut faces: Vec<usize> = Vec::new();
    let mut list_value = false;
    for style_id in &properties.style_ids {
        let style_index = *style_id as usize;
        let style = styles
            .get(style_index)
            .ok_or_else(|| format!("Native layout tape has invalid style id {style_id}"))?;
        match style.mode {
            StyleMode::Set => {
                faces.clear();
                faces.push(style_index);
                list_value = false;
            }
            StyleMode::Add => {
                if !faces.is_empty() {
                    list_value = true;
                }
                faces.push(style_index);
            }
        }
    }
    if faces.is_empty() {
        Ok(None)
    } else if list_value {
        Ok(Some(format!(
            "({})",
            faces
                .iter()
                .map(|index| format!("#{}#", index + 1))
                .collect::<Vec<_>>()
                .join(" ")
        )))
    } else {
        Ok(Some(format!("#{}#", faces[0] + 1)))
    }
}

fn properties_to_lisp(
    properties: Option<&AtomProperties>,
    pixel_width: Option<u64>,
    styles: &[CompiledStyle],
) -> Result<Option<String>, String> {
    let mut output = String::from("(");
    let mut first = true;
    if let Some(properties) = properties {
        if properties.owners.len() > MAX_TAPE_PROPERTY_ENTRIES
            || properties.roles.len() > MAX_TAPE_PROPERTY_ENTRIES
            || properties.property_template_ids.len() > MAX_TAPE_PROPERTY_ENTRIES
        {
            return Err("Native layout tape property record exceeds its entry limit".to_owned());
        }
        if let Some(face) = composed_face(properties, styles)? {
            push_property(&mut output, &mut first, "face", &face);
        }
        if let Some(content) = properties.content {
            push_property(
                &mut output,
                &mut first,
                "ebox-content",
                &content.to_string(),
            );
        }
        if let Some(content_idx) = properties.content_idx {
            push_property(
                &mut output,
                &mut first,
                "ebox-content-idx",
                &content_idx.to_string(),
            );
        }
        if let Some(owner) = properties.owner {
            push_property(
                &mut output,
                &mut first,
                "ebox-content-owner",
                &owner.to_string(),
            );
        }
        if !properties.owners.is_empty() {
            let owners = format!(
                "({})",
                properties
                    .owners
                    .iter()
                    .map(i64::to_string)
                    .collect::<Vec<_>>()
                    .join(" ")
            );
            push_property(&mut output, &mut first, "ebox-content-owners", &owners);
        }
        for role in REGION_ROLES {
            if let Some(entry) = properties
                .roles
                .iter()
                .rev()
                .find(|entry| entry.role == role)
            {
                push_property(
                    &mut output,
                    &mut first,
                    role.lisp_property(),
                    &entry.region_id.to_string(),
                );
            }
        }
        if let Some(scroll_window) = properties.scroll_window {
            push_property(
                &mut output,
                &mut first,
                "ebox-scroll-window",
                &scroll_window.to_string(),
            );
        }
        if !properties.property_template_ids.is_empty() {
            let template_ids = format!(
                "({})",
                properties
                    .property_template_ids
                    .iter()
                    .map(u32::to_string)
                    .collect::<Vec<_>>()
                    .join(" ")
            );
            push_property(
                &mut output,
                &mut first,
                "ebox-native-property-template-ids",
                &template_ids,
            );
        }
    }
    if let Some(pixel_width) = pixel_width {
        push_property(
            &mut output,
            &mut first,
            "display",
            &format!("(space :width ({pixel_width}))"),
        );
    }
    output.push(')');
    if first {
        Ok(None)
    } else {
        Ok(Some(output))
    }
}

fn encode_lisp_literal(
    text: &str,
    spaces: &[TapeSpaceSpan],
    property_spans: &[TapePropertySpan],
    styles: &[CompiledStyle],
    character_count: u64,
    max_bytes: usize,
) -> Result<String, String> {
    encode_lisp_literal_inner(
        text,
        spaces,
        property_spans,
        styles,
        character_count,
        max_bytes,
        true,
    )
}

fn encode_lisp_literal_inner(
    text: &str,
    spaces: &[TapeSpaceSpan],
    property_spans: &[TapePropertySpan],
    styles: &[CompiledStyle],
    character_count: u64,
    max_bytes: usize,
    define_styles: bool,
) -> Result<String, String> {
    let mut boundaries = Vec::with_capacity(2 + spaces.len() * 2 + property_spans.len() * 2);
    boundaries.push(0);
    boundaries.push(character_count);
    for space in spaces {
        boundaries.push(space.start);
        boundaries.push(space.start + 1);
    }
    for span in property_spans {
        boundaries.push(span.start);
        boundaries.push(span.end);
    }
    boundaries.sort_unstable();
    boundaries.dedup();

    let mut intervals: Vec<LiteralInterval> = Vec::new();
    let mut property_index = 0;
    let mut space_index = 0;
    for boundary in boundaries.windows(2) {
        let start = boundary[0];
        let end = boundary[1];
        if start == end {
            continue;
        }
        while property_index < property_spans.len() && property_spans[property_index].end <= start {
            property_index += 1;
        }
        while space_index < spaces.len() && spaces[space_index].start < start {
            space_index += 1;
        }
        let properties = property_spans
            .get(property_index)
            .filter(|span| span.start <= start && end <= span.end)
            .map(|span| &span.properties);
        let pixel_width = spaces
            .get(space_index)
            .filter(|space| space.start == start)
            .map(|space| space.width);
        if let Some(properties) = properties_to_lisp(properties, pixel_width, styles)? {
            if let Some(previous) = intervals.last_mut() {
                if previous.end == start && previous.properties == properties {
                    previous.end = end;
                    continue;
                }
            }
            intervals.push(LiteralInterval {
                start,
                end,
                properties,
            });
        }
    }

    let mut shared_properties = shared_literal_properties(&intervals, styles.len());
    let mut literal = String::with_capacity(text.len().saturating_mul(2));
    literal.push_str("#(");
    push_lisp_string(&mut literal, text);
    if define_styles {
        for (index, style) in styles.iter().enumerate() {
            literal.push_str(" 0 0 (face #");
            literal.push_str(&(index + 1).to_string());
            literal.push('=');
            literal.push_str(&style.face);
            literal.push(')');
        }
    }
    for interval in intervals {
        literal.push(' ');
        literal.push_str(&interval.start.to_string());
        literal.push(' ');
        literal.push_str(&interval.end.to_string());
        literal.push(' ');
        if let Some(label) = shared_properties.get_mut(&interval.properties) {
            if !label.defined {
                literal.push('#');
                literal.push_str(&label.id.to_string());
                literal.push('=');
                literal.push_str(&interval.properties);
                label.defined = true;
            } else {
                literal.push('#');
                literal.push_str(&label.id.to_string());
                literal.push('#');
            }
        } else {
            literal.push_str(&interval.properties);
        }
        if literal.len() > max_bytes {
            return Err("Native layout tape exceeds its byte limit".to_owned());
        }
    }
    literal.push(')');
    if literal.len() > max_bytes {
        return Err("Native layout tape exceeds its byte limit".to_owned());
    }
    Ok(literal)
}

#[derive(Debug)]
struct SharedLiteralProperty {
    id: usize,
    defined: bool,
}

fn shared_literal_properties(
    intervals: &[LiteralInterval],
    reserved_label_count: usize,
) -> BTreeMap<String, SharedLiteralProperty> {
    let mut counts = BTreeMap::new();
    for interval in intervals {
        *counts.entry(interval.properties.clone()).or_insert(0_usize) += 1;
    }
    let mut labels = BTreeMap::new();
    let mut next_label = reserved_label_count + 1;
    for interval in intervals {
        if labels.contains_key(&interval.properties) {
            continue;
        }
        let count = *counts.get(&interval.properties).unwrap_or(&0);
        if count < 2 {
            continue;
        }
        let id = next_label;
        let definition_overhead = format!("#{id}=").len();
        let reference_length = format!("#{id}#").len();
        let saved_references = count - 1;
        let saved_bytes = saved_references
            .saturating_mul(interval.properties.len().saturating_sub(reference_length));
        if saved_bytes > definition_overhead {
            labels.insert(
                interval.properties.clone(),
                SharedLiteralProperty { id, defined: false },
            );
            next_label += 1;
        }
    }
    labels
}

fn tape_properties(mut properties: AtomProperties, complete: bool) -> AtomProperties {
    if !complete {
        properties.content = None;
        properties.content_idx = None;
        properties.owner = None;
        properties.owners.clear();
        properties.roles.clear();
        properties.scroll_window = None;
        properties.property_template_ids.clear();
    }
    properties
}

fn tape_properties_empty(properties: &AtomProperties) -> bool {
    properties.style_ids.is_empty()
        && properties.content.is_none()
        && properties.content_idx.is_none()
        && properties.owner.is_none()
        && properties.owners.is_empty()
        && properties.roles.is_empty()
        && properties.scroll_window.is_none()
        && properties.property_template_ids.is_empty()
}

fn push_property_span(
    spans: &mut Vec<TapePropertySpan>,
    start: u64,
    end: u64,
    properties: AtomProperties,
    complete: bool,
) {
    let properties = tape_properties(properties, complete);
    if start == end || tape_properties_empty(&properties) {
        return;
    }
    if let Some(previous) = spans.last_mut() {
        if previous.end == start && previous.properties == properties {
            previous.end = end;
            return;
        }
    }
    spans.push(TapePropertySpan {
        start,
        end,
        properties,
    });
}

fn push_metadata_span(
    records: &mut Vec<TapeMetadataRecord>,
    last_by_key: &mut BTreeMap<(u8, i64, u32), usize>,
    kind: u8,
    region_id: i64,
    index: u32,
    start: u64,
    end: u64,
) -> Result<(), String> {
    if start >= end {
        return Ok(());
    }
    if region_id <= 0 {
        return Err("Native layout tape metadata has an invalid region id".to_owned());
    }
    let key = (kind, region_id, index);
    if let Some(previous_index) = last_by_key.get(&key).copied() {
        let previous = &mut records[previous_index];
        if previous.end == start {
            previous.end = end;
            return Ok(());
        }
    }
    if records.len() >= MAX_TAPE_METADATA_RECORDS {
        return Err("Native layout tape has too many metadata records".to_owned());
    }
    let record_index = records.len();
    records.push(TapeMetadataRecord {
        kind,
        region_id,
        index,
        start,
        end,
    });
    last_by_key.insert(key, record_index);
    Ok(())
}

fn metadata_extent_region_ids(properties: &AtomProperties) -> Vec<i64> {
    let mut region_ids = properties.owners.clone();
    if let Some(region_id) = properties.owner {
        if !region_ids.contains(&region_id) {
            region_ids.push(region_id);
        }
    }
    if let Some(region_id) = properties.content {
        if !region_ids.contains(&region_id) {
            region_ids.push(region_id);
        }
    }
    for role in &properties.roles {
        if !region_ids.contains(&role.region_id) {
            region_ids.push(role.region_id);
        }
    }
    region_ids
}

#[derive(Debug)]
struct MetadataExtentRange {
    start: u64,
    end: u64,
    last_event: u64,
    last_safe_event: u64,
    interleaved: bool,
}

fn push_box_extent_metadata_records(
    text: &str,
    property_spans: &[TapePropertySpan],
    records: &mut Vec<TapeMetadataRecord>,
    last_by_key: &mut BTreeMap<(u8, i64, u32), usize>,
) -> Result<(), String> {
    let mut non_newline_prefix = Vec::with_capacity(text.chars().count() + 1);
    non_newline_prefix.push(0_u64);
    for character in text.chars() {
        let previous = *non_newline_prefix.last().unwrap_or(&0);
        non_newline_prefix.push(previous + u64::from(character != '\n'));
    }
    let mut ranges: BTreeMap<i64, MetadataExtentRange> = BTreeMap::new();
    let mut safe_events: BTreeMap<i64, u64> = BTreeMap::new();
    let mut event = 0_u64;
    for span in property_spans {
        let region_ids = metadata_extent_region_ids(&span.properties);
        for region_id in &region_ids {
            let region_id = *region_id;
            if region_id <= 0 {
                return Err("Native layout tape metadata has an invalid extent id".to_owned());
            }
            if let Some(range) = ranges.get_mut(&region_id) {
                let safe_event = safe_events.get(&region_id).copied().unwrap_or(0);
                if span.start > range.end
                    && event - range.last_event > safe_event - range.last_safe_event
                {
                    range.interleaved = true;
                }
                range.start = range.start.min(span.start);
                range.end = range.end.max(span.end);
            } else {
                ranges.insert(
                    region_id,
                    MetadataExtentRange {
                        start: span.start,
                        end: span.end,
                        last_event: event,
                        last_safe_event: safe_events.get(&region_id).copied().unwrap_or(0),
                        interleaved: false,
                    },
                );
            }
        }
        let start = usize::try_from(span.start)
            .map_err(|_| "Native layout tape metadata span is too large".to_owned())?;
        let end = usize::try_from(span.end)
            .map_err(|_| "Native layout tape metadata span is too large".to_owned())?;
        let contains_non_newline = non_newline_prefix
            .get(end)
            .zip(non_newline_prefix.get(start))
            .is_some_and(|(end_count, start_count)| end_count > start_count);
        if contains_non_newline && !region_ids.is_empty() {
            event += 1;
            let mut safe_region_ids = span.properties.owners.clone();
            if region_ids.len() == 1 && !safe_region_ids.contains(&region_ids[0]) {
                safe_region_ids.push(region_ids[0]);
            }
            for region_id in safe_region_ids {
                *safe_events.entry(region_id).or_insert(0) += 1;
            }
        }
        for region_id in region_ids {
            let range = ranges
                .get_mut(&region_id)
                .ok_or_else(|| "Native layout tape extent state disappeared".to_owned())?;
            range.last_event = event;
            range.last_safe_event = safe_events.get(&region_id).copied().unwrap_or(0);
        }
    }
    for (region_id, range) in ranges {
        if !range.interleaved {
            push_metadata_span(
                records,
                last_by_key,
                METADATA_BOX_EXTENT,
                region_id,
                0,
                range.start,
                range.end,
            )?;
        }
    }
    Ok(())
}

fn build_root_metadata_records(
    text: &str,
    property_spans: &[TapePropertySpan],
) -> Result<Vec<TapeMetadataRecord>, String> {
    let mut records = Vec::new();
    let mut last_by_key = BTreeMap::new();

    push_box_extent_metadata_records(text, property_spans, &mut records, &mut last_by_key)?;

    // Root replacement role templates use one-based buffer points.  Keep the
    // tape zero-based and translate only after the sidecar has been validated
    // by Emacs.
    for span in property_spans {
        if let Some(region_id) = span.properties.content {
            push_metadata_span(
                &mut records,
                &mut last_by_key,
                METADATA_ROLE_CONTENT,
                region_id,
                0,
                span.start,
                span.end,
            )?;
        }
        if let Some(region_id) = span.properties.owner {
            push_metadata_span(
                &mut records,
                &mut last_by_key,
                METADATA_ROLE_CONTENT_OWNER,
                region_id,
                0,
                span.start,
                span.end,
            )?;
        }
        for role in REGION_ROLES {
            if let Some(entry) = span
                .properties
                .roles
                .iter()
                .rev()
                .find(|entry| entry.role == role)
            {
                push_metadata_span(
                    &mut records,
                    &mut last_by_key,
                    role.metadata_kind(),
                    entry.region_id,
                    0,
                    span.start,
                    span.end,
                )?;
            }
        }
    }

    // Direct scroll content spans precede wrapper-owner line spans, matching
    // `ebox--build-scroll-content-span-template'.  Extra non-scroll region ids
    // are harmless: installation filters against the live scroll-state table.
    for span in property_spans {
        if let (Some(region_id), Some(index)) =
            (span.properties.content, span.properties.content_idx)
        {
            let index = u32::try_from(index)
                .map_err(|_| "Native layout tape has an invalid content index".to_owned())?;
            push_metadata_span(
                &mut records,
                &mut last_by_key,
                METADATA_SCROLL_CONTENT,
                region_id,
                index,
                span.start,
                span.end,
            )?;
        }
    }

    let mut line_ranges = Vec::new();
    let mut line_start = 0_u64;
    let mut position = 0_u64;
    for character in text.chars() {
        if character == '\n' {
            if line_start < position {
                line_ranges.push((line_start, position));
            }
            line_start = position + 1;
        }
        position += 1;
    }
    if line_start < position {
        line_ranges.push((line_start, position));
    }

    let mut owner_line_indexes: BTreeMap<i64, u32> = BTreeMap::new();
    let mut first_span = 0_usize;
    for (line_start, line_end) in line_ranges {
        while first_span < property_spans.len() && property_spans[first_span].end <= line_start {
            first_span += 1;
        }
        let mut line_owners: BTreeMap<i64, (u64, u64)> = BTreeMap::new();
        let mut span_index = first_span;
        while span_index < property_spans.len() && property_spans[span_index].start < line_end {
            let span = &property_spans[span_index];
            let start = span.start.max(line_start);
            let end = span.end.min(line_end);
            if start < end {
                let mut owner_ids = span.properties.owners.clone();
                if let Some(owner) = span.properties.owner {
                    if !owner_ids.contains(&owner) {
                        owner_ids.push(owner);
                    }
                }
                for region_id in owner_ids {
                    if region_id <= 0 {
                        return Err(
                            "Native layout tape metadata has an invalid owner id".to_owned()
                        );
                    }
                    line_owners
                        .entry(region_id)
                        .and_modify(|record| record.1 = record.1.max(end))
                        .or_insert((start, end));
                }
            }
            span_index += 1;
        }
        for (region_id, (start, end)) in line_owners {
            let index = owner_line_indexes.entry(region_id).or_insert(0);
            push_metadata_span(
                &mut records,
                &mut last_by_key,
                METADATA_SCROLL_OWNER,
                region_id,
                *index,
                start,
                end,
            )?;
            *index = index
                .checked_add(1)
                .ok_or_else(|| "Native layout tape owner index overflow".to_owned())?;
        }
    }

    if let Some((region_id, start, end)) = property_spans.iter().find_map(|span| {
        span.properties
            .scroll_window
            .map(|region_id| (region_id, span.start, span.end))
    }) {
        push_metadata_span(
            &mut records,
            &mut last_by_key,
            METADATA_SCROLL_WINDOW,
            region_id,
            0,
            start,
            end,
        )?;
    }
    Ok(records)
}

fn push_fragment_role(
    roles: &mut Vec<(&'static str, i64)>,
    role: &'static str,
    region_id: i64,
) -> Result<(), String> {
    if region_id <= 0 {
        return Err("Native layout fragment has an invalid region id".to_owned());
    }
    if !roles
        .iter()
        .any(|(existing_role, existing_id)| *existing_role == role && *existing_id == region_id)
    {
        roles.push((role, region_id));
    }
    Ok(())
}

fn fragment_roles(properties: &AtomProperties) -> Result<Vec<(&'static str, i64)>, String> {
    let mut roles = Vec::new();
    for region_id in &properties.owners {
        push_fragment_role(&mut roles, "content-owner", *region_id)?;
    }
    if let Some(region_id) = properties.content {
        push_fragment_role(&mut roles, "content", region_id)?;
    }
    if let Some(region_id) = properties.owner {
        push_fragment_role(&mut roles, "content-owner", region_id)?;
    }
    for role in REGION_ROLES {
        if let Some(entry) = properties
            .roles
            .iter()
            .rev()
            .find(|entry| entry.role == role)
        {
            let symbol = metadata_role_symbol(role.metadata_kind())
                .ok_or_else(|| "Native layout fragment has an unknown role".to_owned())?;
            push_fragment_role(&mut roles, symbol, entry.region_id)?;
        }
    }
    Ok(roles)
}

fn build_fragment_templates(
    text: &str,
    spaces: &[TapeSpaceSpan],
    property_spans: &[TapePropertySpan],
) -> Result<Vec<FragmentTemplate>, String> {
    let character_count = u64::try_from(text.chars().count())
        .map_err(|_| "Native layout fragment character count overflow".to_owned())?;
    let mut boundaries = Vec::with_capacity(2 + spaces.len() * 2 + property_spans.len() * 2);
    boundaries.push(0);
    boundaries.push(character_count);
    for space in spaces {
        boundaries.push(space.start);
        boundaries.push(space.start + 1);
    }
    for span in property_spans {
        boundaries.push(span.start);
        boundaries.push(span.end);
    }
    boundaries.sort_unstable();
    boundaries.dedup();

    let mut line_prefix = Vec::with_capacity(text.chars().count() + 1);
    line_prefix.push(0_u64);
    for character in text.chars() {
        let previous = *line_prefix.last().unwrap_or(&0);
        line_prefix.push(previous + u64::from(character == '\n'));
    }

    let empty = AtomProperties::default();
    let mut property_index = 0;
    let mut fragments = Vec::with_capacity(boundaries.len().saturating_sub(1));
    for boundary in boundaries.windows(2) {
        let start = boundary[0];
        let end = boundary[1];
        if start == end {
            continue;
        }
        while property_index < property_spans.len() && property_spans[property_index].end <= start {
            property_index += 1;
        }
        let properties = property_spans
            .get(property_index)
            .filter(|span| span.start <= start && end <= span.end)
            .map_or(&empty, |span| &span.properties);
        let line_index = usize::try_from(start)
            .map_err(|_| "Native layout fragment offset is too large".to_owned())?;
        let line = *line_prefix
            .get(line_index)
            .ok_or_else(|| "Native layout fragment line offset is invalid".to_owned())?;
        if properties.content_idx.is_some_and(|index| index < 0) {
            return Err("Native layout fragment has a negative content index".to_owned());
        }
        fragments.push(FragmentTemplate {
            start,
            end,
            line,
            roles: fragment_roles(properties)?,
            content_owner: properties.owner,
            content_index: properties.content_idx,
            property_template_ids: properties.property_template_ids.clone(),
            style_ids: properties.style_ids.clone(),
        });
    }
    Ok(fragments)
}

struct RootMetadataPayload {
    literal: String,
    record_count: usize,
    fragments: Vec<FragmentTemplate>,
    fragment_bytes: Vec<u8>,
    fragment_count: usize,
}

fn metadata_role_symbol(kind: u8) -> Option<&'static str> {
    match kind {
        METADATA_ROLE_CONTENT => Some("content"),
        METADATA_ROLE_CONTENT_OWNER => Some("content-owner"),
        METADATA_ROLE_PADDING_TOP => Some("pt"),
        METADATA_ROLE_PADDING_BOTTOM => Some("pb"),
        METADATA_ROLE_PADDING_LEFT => Some("pl"),
        METADATA_ROLE_PADDING_RIGHT => Some("pr"),
        METADATA_ROLE_MARGIN_TOP => Some("mt"),
        METADATA_ROLE_MARGIN_BOTTOM => Some("mb"),
        METADATA_ROLE_MARGIN_LEFT => Some("ml"),
        METADATA_ROLE_MARGIN_RIGHT => Some("mr"),
        METADATA_ROLE_BORDER_TOP => Some("bt"),
        METADATA_ROLE_BORDER_BOTTOM => Some("bb"),
        METADATA_ROLE_BORDER_LEFT => Some("bl"),
        METADATA_ROLE_BORDER_RIGHT => Some("br"),
        _ => None,
    }
}

fn push_hash_table(output: &mut String, entries: Vec<String>) {
    output.push_str("#s(hash-table test equal data (");
    output.push_str(&entries.join(" "));
    output.push_str("))");
}

fn metadata_literal_from_records(records: &[TapeMetadataRecord]) -> Result<String, String> {
    let mut role_table: BTreeMap<(i64, &'static str), Vec<(u64, u64)>> = BTreeMap::new();
    let mut extent_table: BTreeMap<i64, (u64, u64)> = BTreeMap::new();
    let mut scroll_table: BTreeMap<i64, Vec<(u32, u64, u64)>> = BTreeMap::new();
    let mut scroll_window_p = false;

    for record in records {
        if let Some(role) = metadata_role_symbol(record.kind) {
            if record.index != 0 {
                return Err("Native layout tape role metadata has a line index".to_owned());
            }
            role_table
                .entry((record.region_id, role))
                .or_default()
                .push((record.start + 1, record.end + 1));
        } else if record.kind == METADATA_BOX_EXTENT {
            if record.index != 0 {
                return Err("Native layout tape box extent metadata has a line index".to_owned());
            }
            extent_table
                .entry(record.region_id)
                .and_modify(|extent| {
                    extent.0 = extent.0.min(record.start + 1);
                    extent.1 = extent.1.max(record.end + 1);
                })
                .or_insert((record.start + 1, record.end + 1));
        } else if record.kind == METADATA_SCROLL_CONTENT || record.kind == METADATA_SCROLL_OWNER {
            scroll_table.entry(record.region_id).or_default().push((
                record.index,
                record.start,
                record.end,
            ));
        } else if record.kind == METADATA_SCROLL_WINDOW {
            if record.index != 0 {
                return Err("Native layout tape scroll-window metadata has a line index".to_owned());
            }
            scroll_window_p = true;
        } else {
            return Err("Native layout tape has unknown metadata kind".to_owned());
        }
    }

    let role_entries = role_table
        .into_iter()
        .map(|((region_id, role), spans)| {
            let spans = spans
                .into_iter()
                .map(|(start, end)| format!("({start} . {end})"))
                .collect::<Vec<_>>()
                .join(" ");
            format!("({region_id} {role}) ({spans})")
        })
        .collect::<Vec<_>>();
    let extent_entries = extent_table
        .into_iter()
        .map(|(region_id, (start, end))| format!("{region_id} ({start} . {end})"))
        .collect::<Vec<_>>();
    let scroll_entries = scroll_table
        .into_iter()
        .map(|(region_id, spans)| {
            let spans = spans
                .into_iter()
                .map(|(index, start, end)| format!("({index} {start} . {end})"))
                .collect::<Vec<_>>()
                .join(" ");
            format!("{region_id} ({spans})")
        })
        .collect::<Vec<_>>();

    let mut literal = String::from("(:prepared-p t :role-span-template ");
    push_hash_table(&mut literal, role_entries);
    literal.push_str(" :box-extent-template ");
    push_hash_table(&mut literal, extent_entries);
    literal.push_str(" :scroll-content-span-template ");
    push_hash_table(&mut literal, scroll_entries);
    literal.push_str(" :scroll-window-p ");
    literal.push_str(if scroll_window_p { "t" } else { "nil" });
    literal.push(')');
    Ok(literal)
}

fn push_fragment_u32(output: &mut Vec<u8>, value: usize, label: &str) -> Result<(), String> {
    output.extend_from_slice(
        &u32::try_from(value)
            .map_err(|_| format!("Native layout fragment has too many {label}"))?
            .to_le_bytes(),
    );
    Ok(())
}

fn encode_fragment_templates(fragments: &[FragmentTemplate]) -> Result<Vec<u8>, String> {
    let mut output = Vec::new();
    for fragment in fragments {
        output.extend_from_slice(&fragment.start.to_le_bytes());
        output.extend_from_slice(&fragment.end.to_le_bytes());
        output.extend_from_slice(&fragment.line.to_le_bytes());
        output.extend_from_slice(&fragment.content_owner.unwrap_or(i64::MIN).to_le_bytes());
        output.extend_from_slice(&fragment.content_index.unwrap_or(i64::MIN).to_le_bytes());
        push_fragment_u32(&mut output, fragment.roles.len(), "roles")?;
        push_fragment_u32(
            &mut output,
            fragment.property_template_ids.len(),
            "property templates",
        )?;
        push_fragment_u32(&mut output, fragment.style_ids.len(), "styles")?;
        output.extend_from_slice(&0_u32.to_le_bytes());
        for (role, region_id) in &fragment.roles {
            let kind = match *role {
                "content" => METADATA_ROLE_CONTENT,
                "content-owner" => METADATA_ROLE_CONTENT_OWNER,
                "pt" => METADATA_ROLE_PADDING_TOP,
                "pb" => METADATA_ROLE_PADDING_BOTTOM,
                "pl" => METADATA_ROLE_PADDING_LEFT,
                "pr" => METADATA_ROLE_PADDING_RIGHT,
                "mt" => METADATA_ROLE_MARGIN_TOP,
                "mb" => METADATA_ROLE_MARGIN_BOTTOM,
                "ml" => METADATA_ROLE_MARGIN_LEFT,
                "mr" => METADATA_ROLE_MARGIN_RIGHT,
                "bt" => METADATA_ROLE_BORDER_TOP,
                "bb" => METADATA_ROLE_BORDER_BOTTOM,
                "bl" => METADATA_ROLE_BORDER_LEFT,
                "br" => METADATA_ROLE_BORDER_RIGHT,
                _ => return Err("Native layout fragment has an unknown role".to_owned()),
            };
            output.push(kind);
            output.extend_from_slice(&region_id.to_le_bytes());
        }
        for template_id in &fragment.property_template_ids {
            output.extend_from_slice(&template_id.to_le_bytes());
        }
        for style_id in &fragment.style_ids {
            output.extend_from_slice(&style_id.to_le_bytes());
        }
    }
    Ok(output)
}

fn root_metadata_payload(
    text: &str,
    spaces: &[TapeSpaceSpan],
    property_spans: &[TapePropertySpan],
    complete: bool,
    root_metadata: bool,
    max_bytes: usize,
) -> Result<Option<RootMetadataPayload>, String> {
    if !complete {
        return Ok(None);
    }
    let records = if root_metadata {
        build_root_metadata_records(text, property_spans)?
    } else {
        property_spans
            .iter()
            .find_map(|span| {
                span.properties.scroll_window.map(|region_id| {
                    vec![TapeMetadataRecord {
                        kind: METADATA_SCROLL_WINDOW,
                        region_id,
                        index: 0,
                        start: span.start,
                        end: span.end,
                    }]
                })
            })
            .unwrap_or_default()
    };
    let mut fragments = build_fragment_templates(text, spaces, property_spans)?;
    let propagated_roles = propagated_fragment_roles(&fragments);
    for (fragment, roles) in fragments.iter_mut().zip(propagated_roles) {
        fragment.roles = roles;
    }
    if records.is_empty() && fragments.is_empty() {
        return Ok(None);
    }
    let literal = metadata_literal_from_records(&records)?;
    let fragment_bytes = encode_fragment_templates(&fragments)?;
    let fragment_count = fragments.len();
    if literal
        .len()
        .checked_add(fragment_bytes.len())
        .is_none_or(|length| length > max_bytes)
    {
        return Err("Native layout tape metadata exceeds its byte limit".to_owned());
    }
    Ok(Some(RootMetadataPayload {
        literal,
        record_count: records.len(),
        fragments,
        fragment_bytes,
        fragment_count,
    }))
}

fn flatten_layout_tape(tape: LayoutTape, complete: bool) -> Result<FlatLayoutTape, String> {
    if tape.lines.is_empty() {
        return Err("Native layout tape has no lines".to_owned());
    }
    let line_count = tape.lines.len();
    let mut characters = Vec::new();
    for (line_index, line) in tape.lines.into_iter().enumerate() {
        let line_width = tape_width(line.width, "line width")?;
        let expected_break = line_index + 1 < line_count;
        if line.break_after.is_some() != expected_break {
            return Err("Native layout tape break invariant failed".to_owned());
        }
        let mut encoded_width = 0_u64;
        for atom in line.atoms {
            match atom {
                TapeAtom::Text {
                    text,
                    width,
                    properties,
                } => {
                    let width = tape_width(width, "text width")?;
                    if text.is_empty() || text.contains('\n') {
                        return Err("Native layout tape has invalid text atom".to_owned());
                    }
                    let properties = tape_properties(properties, complete);
                    characters.extend(text.chars().map(|value| TapeCharacter {
                        value,
                        pixel_width: None,
                        properties: properties.clone(),
                    }));
                    encoded_width = encoded_width
                        .checked_add(width)
                        .ok_or_else(|| "Native layout tape width overflow".to_owned())?;
                }
                TapeAtom::Space { width, properties } => {
                    let width = tape_width(width, "space width")?;
                    if width == 0 {
                        return Err("Native layout tape has empty pixel space".to_owned());
                    }
                    characters.push(TapeCharacter {
                        value: ' ',
                        pixel_width: Some(width),
                        properties: tape_properties(properties, complete),
                    });
                    encoded_width = encoded_width
                        .checked_add(width)
                        .ok_or_else(|| "Native layout tape width overflow".to_owned())?;
                }
            }
        }
        if encoded_width != line_width {
            return Err("Native layout tape line width invariant failed".to_owned());
        }
        if let Some(properties) = line.break_after {
            characters.push(TapeCharacter {
                value: '\n',
                pixel_width: None,
                properties: tape_properties(properties, complete),
            });
        }
    }
    Ok(FlatLayoutTape {
        style_count: tape.style_count,
        line_count: count_u32(line_count, "lines")?,
        characters,
    })
}

fn tape_commit_batch(old: &[TapeCharacter], new: &[TapeCharacter]) -> CommitBatch {
    diff_commit_batch(
        0,
        1,
        old,
        new,
        |left, right| left.value == right.value,
        |left, right| left.pixel_width == right.pixel_width && left.properties == right.properties,
    )
    .expect("fixed consecutive adapter revisions")
}

#[cfg(test)]
fn minimal_tape_patches(old: &[TapeCharacter], new: &[TapeCharacter]) -> Vec<TapePatch> {
    tape_commit_batch(old, new).semantic_edits
}

fn tape_character_encoding_parts(
    characters: &[TapeCharacter],
) -> Result<(String, Vec<TapeSpaceSpan>, Vec<TapePropertySpan>), String> {
    let mut text = String::new();
    let mut spaces = Vec::new();
    let mut property_spans = Vec::new();
    for (position, character) in characters.iter().enumerate() {
        let start = u64::try_from(position)
            .map_err(|_| "Native layout tape character count overflow".to_owned())?;
        text.push(character.value);
        if let Some(width) = character.pixel_width {
            spaces.push(TapeSpaceSpan { start, width });
        }
        push_property_span(
            &mut property_spans,
            start,
            start + 1,
            character.properties.clone(),
            true,
        );
    }
    Ok((text, spaces, property_spans))
}

fn encode_patch_replacement_body(
    target: &[TapeCharacter],
    patches: &[TapePatch],
    styles: &[CompiledStyle],
    max_bytes: usize,
) -> Result<Vec<u8>, String> {
    let replacement_count = patches.iter().try_fold(0_usize, |count, patch| {
        count
            .checked_add(patch.new_end - patch.new_start)
            .ok_or_else(|| "Native layout patch replacement count overflow".to_owned())
    })?;
    let mut replacement_characters = Vec::with_capacity(replacement_count);
    for patch in patches {
        replacement_characters.extend_from_slice(&target[patch.new_start..patch.new_end]);
    }
    let (text, spaces, property_spans) = tape_character_encoding_parts(&replacement_characters)?;
    let character_count = u64::try_from(replacement_count)
        .map_err(|_| "Native layout patch replacement count overflow".to_owned())?;
    encode_lisp_literal_inner(
        &text,
        &spaces,
        &property_spans,
        styles,
        character_count,
        max_bytes,
        true,
    )
    .map(String::into_bytes)
}

fn encode_patch_combined_payload(
    replacement: &[u8],
    metadata: Option<&RootMetadataPayload>,
    fragment_style_delta: Option<&FragmentStyleDelta>,
    max_bytes: usize,
) -> Result<Vec<u8>, String> {
    let metadata_literal = metadata.map_or("nil", |payload| payload.literal.as_str());
    let style_delta_literal = fragment_style_delta.map(|delta| {
        let entries = delta
            .iter()
            .map(|(index, style_ids)| {
                let ids = style_ids
                    .iter()
                    .map(u32::to_string)
                    .collect::<Vec<_>>()
                    .join(" ");
                if ids.is_empty() {
                    format!("({index})")
                } else {
                    format!("({index} {ids})")
                }
            })
            .collect::<Vec<_>>()
            .join(" ");
        format!("({entries})")
    });
    let payload_len = 1_usize
        .checked_add(replacement.len())
        .and_then(|size| size.checked_add(1))
        .and_then(|size| size.checked_add(metadata_literal.len()))
        .and_then(|size| {
            style_delta_literal
                .as_ref()
                .map_or(Some(size), |literal| size.checked_add(1 + literal.len()))
        })
        .and_then(|size| size.checked_add(1))
        .ok_or_else(|| "Native layout patch payload size overflow".to_owned())?;
    if payload_len > max_bytes {
        return Err("Native layout patch exceeds its byte limit".to_owned());
    }
    let mut payload = Vec::with_capacity(payload_len);
    payload.push(b'[');
    payload.extend_from_slice(replacement);
    payload.push(b' ');
    payload.extend_from_slice(metadata_literal.as_bytes());
    if let Some(literal) = style_delta_literal {
        payload.push(b' ');
        payload.extend_from_slice(literal.as_bytes());
    }
    payload.push(b']');
    Ok(payload)
}

/// Emacs adapter payload built on the editor-independent core batch.
struct EmacsCommitBatch {
    core: CommitBatch,
    combined_payload: Vec<u8>,
    metadata_records: usize,
    fragment_bytes: Vec<u8>,
    fragment_records: usize,
    reuse_fragment_template: bool,
    reuse_ownership_template: bool,
    reuse_mount_projection: bool,
    fragment_style_delta: Option<FragmentStyleDelta>,
}

fn build_emacs_commit_batch(
    old: &FlatLayoutTape,
    target: &FlatLayoutTape,
    compiled_styles: &[CompiledStyle],
    complete: bool,
    root_metadata: bool,
    max_bytes: usize,
) -> Result<EmacsCommitBatch, String> {
    let core = tape_commit_batch(&old.characters, &target.characters);
    let descriptor_bytes = core
        .semantic_edits
        .len()
        .checked_add(core.coordinate_edits.len())
        .ok_or_else(|| "Native layout patch descriptor count overflow".to_owned())?
        .checked_mul(32)
        .ok_or_else(|| "Native layout patch size overflow".to_owned())?;
    let fixed_body_bytes = 56_usize
        .checked_add(descriptor_bytes)
        .ok_or_else(|| "Native layout patch size overflow".to_owned())?;
    let payload_limit = max_bytes
        .checked_sub(TAPE_HEADER_LEN)
        .and_then(|remaining| remaining.checked_sub(fixed_body_bytes))
        .ok_or_else(|| "Native layout patch exceeds its byte limit".to_owned())?;
    let (target_text, target_spaces, target_property_spans) =
        tape_character_encoding_parts(&target.characters)?;
    let mut metadata_payload = root_metadata_payload(
        &target_text,
        &target_spaces,
        &target_property_spans,
        complete,
        root_metadata,
        payload_limit,
    )?;
    let old_fragments = if metadata_payload.is_some() {
        let (old_text, old_spaces, old_property_spans) =
            tape_character_encoding_parts(&old.characters)?;
        let mut fragments = build_fragment_templates(&old_text, &old_spaces, &old_property_spans)?;
        let roles = propagated_fragment_roles(&fragments);
        for (fragment, roles) in fragments.iter_mut().zip(roles) {
            fragment.roles = roles;
        }
        Some(fragments)
    } else {
        None
    };
    let reuse_fragment_template = old_fragments
        .as_ref()
        .zip(metadata_payload.as_ref())
        .is_some_and(|(old, target)| *old == target.fragments);
    let reuse_ownership_template = old_fragments
        .as_ref()
        .zip(metadata_payload.as_ref())
        .is_some_and(|(old, target)| {
            fragment_ownership_spans(old) == fragment_ownership_spans(&target.fragments)
        });
    let reuse_mount_projection = old_fragments
        .as_ref()
        .zip(metadata_payload.as_ref())
        .is_some_and(|(old, target)| {
            fragment_region_mount_projection(old)
                == fragment_region_mount_projection(&target.fragments)
        });
    let fragment_style_delta = if reuse_fragment_template {
        None
    } else {
        old_fragments
            .as_ref()
            .zip(metadata_payload.as_ref())
            .and_then(|(old, target)| fragment_style_delta(old, &target.fragments))
    };
    let replacements = encode_patch_replacement_body(
        &target.characters,
        &core.semantic_edits,
        compiled_styles,
        payload_limit,
    )?;
    let combined_payload = encode_patch_combined_payload(
        &replacements,
        metadata_payload.as_ref(),
        fragment_style_delta.as_ref(),
        payload_limit,
    )?;
    let metadata_records = metadata_payload
        .as_ref()
        .map_or(0, |payload| payload.record_count);
    let fragment_records = if reuse_fragment_template || fragment_style_delta.is_some() {
        0
    } else {
        metadata_payload
            .as_ref()
            .map_or(0, |payload| payload.fragment_count)
    };
    let fragment_bytes = if reuse_fragment_template || fragment_style_delta.is_some() {
        Vec::new()
    } else {
        metadata_payload.as_mut().map_or_else(Vec::new, |payload| {
            std::mem::take(&mut payload.fragment_bytes)
        })
    };
    Ok(EmacsCommitBatch {
        core,
        combined_payload,
        metadata_records,
        fragment_bytes,
        fragment_records,
        reuse_fragment_template,
        reuse_ownership_template,
        reuse_mount_projection,
        fragment_style_delta,
    })
}

pub(crate) fn encode_layout_patch_tape(
    old_tape: LayoutTape,
    target_tape: LayoutTape,
    styles: &[StyleTemplate],
    identity: TapeIdentity,
    root_metadata: bool,
    max_bytes: usize,
) -> Result<Vec<u8>, String> {
    let old = flatten_layout_tape(old_tape, identity.complete)?;
    let target = flatten_layout_tape(target_tape, identity.complete)?;
    if old.style_count != target.style_count || target.style_count as usize != styles.len() {
        return Err("Native layout patch style table mismatch".to_owned());
    }
    let compiled_styles = styles
        .iter()
        .map(StyleTemplate::compile)
        .collect::<Result<Vec<_>, _>>()?;
    let batch = build_emacs_commit_batch(
        &old,
        &target,
        &compiled_styles,
        identity.complete,
        root_metadata,
        max_bytes,
    )?;
    let patch_count = count_u32(batch.core.semantic_edits.len(), "patches")?;
    let coordinate_patch_count =
        count_u32(batch.core.coordinate_edits.len(), "coordinate patches")?;
    let target_character_count = u64::try_from(target.characters.len())
        .map_err(|_| "Native layout patch character count overflow".to_owned())?;
    let base_character_count = u64::try_from(old.characters.len())
        .map_err(|_| "Native layout patch base character count overflow".to_owned())?;
    let mut writer = TapeWriter::new(max_bytes)?;
    writer.push_u64(base_character_count)?;
    writer.push_u32(patch_count)?;
    // Publication remains a minimal text/property patch.  The compact target
    // role sidecar lets Emacs swap exact runtime indexes without synchronously
    // rescanning the page or rebuilding thousands of markers per frame.
    writer.push_u32(
        u32::from(batch.reuse_fragment_template)
            | (u32::from(batch.reuse_ownership_template) << 1)
            | (u32::from(batch.reuse_mount_projection) << 2)
            | (u32::from(batch.fragment_style_delta.is_some()) << 3),
    )?;
    writer.push_u64(
        u64::try_from(batch.metadata_records)
            .map_err(|_| "Native layout patch has too many metadata records".to_owned())?,
    )?;
    writer.push_u64(
        u64::try_from(batch.combined_payload.len())
            .map_err(|_| "Native layout patch body is too large".to_owned())?,
    )?;
    writer.push_u64(
        u64::try_from(batch.fragment_bytes.len())
            .map_err(|_| "Native layout fragment tape is too large".to_owned())?,
    )?;
    writer.push_u64(
        u64::try_from(batch.fragment_records)
            .map_err(|_| "Native layout fragment tape has too many records".to_owned())?,
    )?;
    writer.push_u32(coordinate_patch_count)?;
    writer.push_u32(0)?;
    for patch in &batch.core.semantic_edits {
        writer.push_u64(patch.old_start as u64)?;
        writer.push_u64(patch.old_end as u64)?;
        writer.push_u64(patch.new_start as u64)?;
        writer.push_u64(patch.new_end as u64)?;
    }
    for patch in &batch.core.coordinate_edits {
        writer.push_u64(patch.old_start as u64)?;
        writer.push_u64(patch.old_end as u64)?;
        writer.push_u64(patch.new_start as u64)?;
        writer.push_u64(patch.new_end as u64)?;
    }
    writer.push_bytes(&batch.combined_payload)?;
    writer.push_bytes(&batch.fragment_bytes)?;
    Ok(writer.finish_header(
        identity,
        true,
        true,
        target.style_count,
        target.line_count,
        target_character_count,
    ))
}

pub(crate) fn encode_layout_tape(
    tape: LayoutTape,
    styles: &[StyleTemplate],
    identity: TapeIdentity,
    root_metadata: bool,
    max_bytes: usize,
) -> Result<Vec<u8>, String> {
    if tape.lines.is_empty() {
        return Err("Native layout tape has no lines".to_owned());
    }
    let line_count = count_u32(tape.lines.len(), "lines")?;
    if tape.style_count as usize != styles.len() {
        return Err("Native layout tape style table mismatch".to_owned());
    }
    let compiled_styles = styles
        .iter()
        .map(StyleTemplate::compile)
        .collect::<Result<Vec<_>, _>>()?;
    let mut text = String::new();
    let mut line_widths = Vec::with_capacity(tape.lines.len());
    let mut spaces = Vec::new();
    let mut property_spans = Vec::new();
    let mut character_count = 0_u64;

    for (line_index, line) in tape.lines.into_iter().enumerate() {
        let line_width = tape_width(line.width, "line width")?;
        line_widths.push(line_width);
        let expected_break = line_index + 1 < line_count as usize;
        if line.break_after.is_some() != expected_break {
            return Err("Native layout tape break invariant failed".to_owned());
        }
        let mut encoded_width = 0_u64;
        for atom in line.atoms {
            match atom {
                TapeAtom::Text {
                    text: atom_text,
                    width,
                    properties,
                } => {
                    let width = tape_width(width, "text width")?;
                    if atom_text.is_empty() || atom_text.contains('\n') {
                        return Err("Native layout tape has invalid text atom".to_owned());
                    }
                    let start = character_count;
                    text.push_str(&atom_text);
                    character_count = character_count
                        .checked_add(u64::try_from(atom_text.chars().count()).map_err(|_| {
                            "Native layout tape character count overflow".to_owned()
                        })?)
                        .ok_or_else(|| "Native layout tape character overflow".to_owned())?;
                    push_property_span(
                        &mut property_spans,
                        start,
                        character_count,
                        properties,
                        identity.complete,
                    );
                    encoded_width = encoded_width
                        .checked_add(width)
                        .ok_or_else(|| "Native layout tape width overflow".to_owned())?;
                }
                TapeAtom::Space { width, properties } => {
                    let width = tape_width(width, "space width")?;
                    if width == 0 {
                        return Err("Native layout tape has empty pixel space".to_owned());
                    }
                    let start = character_count;
                    text.push(' ');
                    spaces.push(TapeSpaceSpan { start, width });
                    character_count = character_count
                        .checked_add(1)
                        .ok_or_else(|| "Native layout tape character overflow".to_owned())?;
                    push_property_span(
                        &mut property_spans,
                        start,
                        character_count,
                        properties,
                        identity.complete,
                    );
                    encoded_width = encoded_width
                        .checked_add(width)
                        .ok_or_else(|| "Native layout tape width overflow".to_owned())?;
                }
            }
        }
        if encoded_width != line_width {
            return Err("Native layout tape line width invariant failed".to_owned());
        }
        if let Some(properties) = line.break_after {
            let start = character_count;
            text.push('\n');
            character_count = character_count
                .checked_add(1)
                .ok_or_else(|| "Native layout tape character overflow".to_owned())?;
            push_property_span(
                &mut property_spans,
                start,
                character_count,
                properties,
                identity.complete,
            );
        }
    }

    let fixed_body_bytes = 40_usize
        .checked_add(
            (line_count as usize)
                .checked_mul(8)
                .ok_or_else(|| "Native layout tape size overflow".to_owned())?,
        )
        .ok_or_else(|| "Native layout tape size overflow".to_owned())?;
    let metadata_limit = max_bytes
        .checked_sub(TAPE_HEADER_LEN)
        .and_then(|remaining| remaining.checked_sub(fixed_body_bytes))
        .ok_or_else(|| "Native layout tape exceeds its byte limit".to_owned())?;
    let metadata_payload = root_metadata_payload(
        &text,
        &spaces,
        &property_spans,
        identity.complete,
        root_metadata,
        metadata_limit,
    )?;
    let metadata_bytes = metadata_payload
        .as_ref()
        .map_or(0, |payload| payload.literal.len());
    let metadata_records = metadata_payload
        .as_ref()
        .map_or(0, |payload| payload.record_count);
    let fragment_bytes = metadata_payload
        .as_ref()
        .map_or(0, |payload| payload.fragment_bytes.len());
    let fragment_records = metadata_payload
        .as_ref()
        .map_or(0, |payload| payload.fragment_count);
    let literal_limit = max_bytes
        .checked_sub(TAPE_HEADER_LEN)
        .and_then(|remaining| remaining.checked_sub(fixed_body_bytes))
        .and_then(|remaining| remaining.checked_sub(metadata_bytes))
        .and_then(|remaining| remaining.checked_sub(fragment_bytes))
        .ok_or_else(|| "Native layout tape exceeds its byte limit".to_owned())?;
    let literal = encode_lisp_literal(
        &text,
        &spaces,
        &property_spans,
        &compiled_styles,
        character_count,
        literal_limit,
    )?;

    let mut writer = TapeWriter::new(max_bytes)?;
    writer.push_u64(
        u64::try_from(literal.len())
            .map_err(|_| "Native layout tape literal is too large".to_owned())?,
    )?;
    writer.push_u32(line_count)?;
    writer.push_u32(
        u32::try_from(metadata_bytes)
            .map_err(|_| "Native layout tape metadata is too large".to_owned())?,
    )?;
    writer.push_u64(
        u64::try_from(metadata_records)
            .map_err(|_| "Native layout tape has too many metadata records".to_owned())?,
    )?;
    writer.push_u64(
        u64::try_from(fragment_bytes)
            .map_err(|_| "Native layout fragment tape is too large".to_owned())?,
    )?;
    writer.push_u64(
        u64::try_from(fragment_records)
            .map_err(|_| "Native layout fragment tape has too many records".to_owned())?,
    )?;
    for width in line_widths {
        writer.push_u64(width)?;
    }
    writer.push_bytes(literal.as_bytes())?;
    if let Some(payload) = metadata_payload {
        writer.push_bytes(payload.literal.as_bytes())?;
        writer.push_bytes(&payload.fragment_bytes)?;
    }

    Ok(writer.finish_header(
        identity,
        true,
        false,
        tape.style_count,
        line_count,
        character_count,
    ))
}

pub fn encode_error_tape(identity: TapeIdentity, message: &str, max_bytes: usize) -> Vec<u8> {
    let limit = max_bytes.max(MIN_TAPE_BYTES);
    let mut writer = TapeWriter::new(limit).expect("minimum tape limit");
    let capacity = limit - TAPE_HEADER_LEN - 4;
    let mut length = message.len().min(capacity);
    while !message.is_char_boundary(length) {
        length -= 1;
    }
    let message = &message.as_bytes()[..length];
    writer
        .push_u32(u32::try_from(message.len()).unwrap_or(u32::MAX))
        .expect("bounded error length");
    writer.push_bytes(message).expect("bounded error body");
    writer.finish_header(identity, false, false, 0, 0, 0)
}

impl LayoutDocument {
    pub fn validate(&self) -> Result<(), String> {
        if self.version != LAYOUT_VERSION {
            return Err(format!(
                "Unsupported native layout IR version {}",
                self.version
            ));
        }
        if self.space_width <= 0 {
            return Err("Native layout space width must be positive".to_owned());
        }
        if self.styles.len() != self.style_count as usize {
            return Err("Native layout style table length mismatch".to_owned());
        }
        if self.styles.len() > MAX_TAPE_PROPERTY_ENTRIES {
            return Err("Native layout style table exceeds its entry limit".to_owned());
        }
        if self.property_template_count > MAX_PROPERTY_TEMPLATE_COUNT {
            return Err("Native layout property template table exceeds its entry limit".to_owned());
        }
        for style in &self.styles {
            style.face.validate()?;
        }
        let mut nodes = 0;
        let mut work_units = 0;
        validate_node(
            &self.root,
            0,
            &mut nodes,
            &mut work_units,
            self.style_count,
            self.property_template_count,
        )
    }

    pub fn validate_context(&self, context: LayoutContext) -> Result<(), String> {
        let mut work_units = 0;
        add_context_work(&self.root, context, &mut work_units)
    }

    pub(crate) fn layout_tape(
        &self,
        context: LayoutContext,
        root_width_override: Option<i64>,
    ) -> Result<LayoutTape, String> {
        if root_width_override.is_some() && !matches!(self.root, LayoutNode::Box { .. }) {
            Err("Native root width override requires a box root".to_owned())
        } else {
            render_node_with_override(
                &self.root,
                context,
                false,
                root_width_override.map(|declared_width| BoxOverride {
                    declared_width: Some(declared_width),
                    ..BoxOverride::default()
                }),
            )
            .map(|rendered| rendered.into_tape(self.style_count))
        }
    }
}

fn validate_nonnegative(name: &str, value: i64) -> Result<(), String> {
    if value < 0 {
        Err(format!("Native layout {name} cannot be negative"))
    } else {
        Ok(())
    }
}

fn validate_dimension(name: &str, value: i64) -> Result<(), String> {
    validate_nonnegative(name, value)?;
    if value > MAX_LAYOUT_DIMENSION {
        Err(format!("Native layout {name} exceeds the dimension limit"))
    } else {
        Ok(())
    }
}

fn add_work_units(work_units: &mut usize, amount: usize) -> Result<(), String> {
    *work_units = work_units
        .checked_add(amount)
        .ok_or_else(|| "Native layout work estimate overflowed".to_owned())?;
    if *work_units > MAX_LAYOUT_WORK_UNITS {
        Err("Native layout exceeds the work-unit limit".to_owned())
    } else {
        Ok(())
    }
}

fn add_vertical_size_work(size: &Size, work_units: &mut usize) -> Result<(), String> {
    match size {
        Size::Lines { value } => {
            add_work_units(work_units, usize::try_from(*value).unwrap_or(usize::MAX))
        }
        Size::FitContent { limit: Some(limit) } => add_vertical_size_work(limit, work_units),
        Size::Add { values } | Size::Subtract { values } => {
            for value in &values.0 {
                add_vertical_size_work(value, work_units)?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn add_context_size_work(
    size: &Size,
    context: LayoutContext,
    work_units: &mut usize,
) -> Result<(), String> {
    match size {
        Size::ViewportHeight => add_work_units(
            work_units,
            usize::try_from(context.viewport_height).unwrap_or(usize::MAX),
        ),
        Size::FitContent { limit: Some(limit) } => {
            add_context_size_work(limit, context, work_units)
        }
        Size::Add { values } | Size::Subtract { values } => {
            for value in &values.0 {
                add_context_size_work(value, context, work_units)?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn add_context_work(
    node: &LayoutNode,
    context: LayoutContext,
    work_units: &mut usize,
) -> Result<(), String> {
    match node {
        LayoutNode::Box {
            child,
            height,
            min_height,
            max_height,
            ..
        } => {
            for size in [height, min_height, max_height] {
                add_context_size_work(size, context, work_units)?;
            }
            if let Some(child) = child {
                add_context_work(child, context, work_units)?;
            }
        }
        LayoutNode::Row { children } | LayoutNode::Column { children } => {
            for child in children {
                add_context_work(child, context, work_units)?;
            }
        }
        LayoutNode::Flex { height, items, .. } => {
            add_context_size_work(height, context, work_units)?;
            for item in items {
                add_context_work(&item.node, context, work_units)?;
            }
        }
    }
    Ok(())
}

fn validate_size_at_depth(name: &str, size: &Size, depth: usize) -> Result<(), String> {
    if depth > MAX_LAYOUT_DEPTH {
        return Err(format!(
            "Native layout {name} expression exceeds the depth limit"
        ));
    }
    match size {
        Size::Pixels { value } | Size::Lines { value } => validate_dimension(name, *value),
        Size::FitContent { limit: Some(limit) } => validate_size_at_depth(name, limit, depth + 1),
        Size::Add { values } | Size::Subtract { values } => {
            if values.0.is_empty() {
                return Err(format!("Native layout {name} expression cannot be empty"));
            }
            for value in &values.0 {
                validate_size_at_depth(name, value, depth + 1)?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn validate_size(name: &str, size: &Size) -> Result<(), String> {
    validate_size_at_depth(name, size, 0)
}

fn validate_node(
    node: &LayoutNode,
    depth: usize,
    nodes: &mut usize,
    work_units: &mut usize,
    style_count: u32,
    property_template_count: u32,
) -> Result<(), String> {
    if depth > MAX_LAYOUT_DEPTH {
        return Err("Native layout tree exceeds the depth limit".to_owned());
    }
    *nodes += 1;
    if *nodes > MAX_LAYOUT_NODES {
        return Err("Native layout tree exceeds the node limit".to_owned());
    }
    add_work_units(work_units, 1)?;
    match node {
        LayoutNode::Box {
            region_id,
            content,
            child,
            content_width_exact: _,
            content_min_width,
            width,
            min_width,
            max_width,
            height,
            min_height,
            max_height,
            padding_left,
            padding_right,
            padding_top,
            padding_bottom,
            margin_left,
            margin_right,
            margin_top,
            margin_bottom,
            border_left,
            border_right,
            foreground_style,
            background_style,
            border_left_style,
            border_right_style,
            border_top_style,
            border_bottom_style,
            surface_template_id,
            scroll_offset,
            ..
        } => {
            if *region_id <= 0 {
                return Err("Native layout region id must be positive".to_owned());
            }
            if let Some(content_min_width) = content_min_width {
                validate_dimension("content-min-width", *content_min_width)?;
            }
            if content.is_some() == child.is_some() {
                return Err(
                    "Native layout box must contain exactly one text or child value".to_owned(),
                );
            }
            for (name, size) in [
                ("width", width),
                ("min-width", min_width),
                ("max-width", max_width),
                ("height", height),
                ("min-height", min_height),
                ("max-height", max_height),
            ] {
                validate_size(name, size)?;
            }
            for size in [height, min_height, max_height] {
                add_vertical_size_work(size, work_units)?;
            }
            for (name, value) in [
                ("padding-left", *padding_left),
                ("padding-right", *padding_right),
                ("padding-top", *padding_top),
                ("padding-bottom", *padding_bottom),
                ("margin-left", *margin_left),
                ("margin-right", *margin_right),
                ("margin-top", *margin_top),
                ("margin-bottom", *margin_bottom),
                ("border-left", *border_left),
                ("border-right", *border_right),
                ("scroll-offset", *scroll_offset),
            ] {
                validate_dimension(name, value)?;
            }
            add_work_units(
                work_units,
                usize::try_from(padding_top + padding_bottom + margin_top + margin_bottom)
                    .unwrap_or(usize::MAX),
            )?;
            for style_id in [
                foreground_style,
                background_style,
                border_left_style,
                border_right_style,
                border_top_style,
                border_bottom_style,
            ]
            .into_iter()
            .flatten()
            {
                if *style_id >= style_count {
                    return Err("Native layout style id exceeds the style table".to_owned());
                }
            }
            if let Some(template_id) = surface_template_id {
                if *template_id >= property_template_count {
                    return Err(
                        "Native layout property template id exceeds the property template table"
                            .to_owned(),
                    );
                }
            }
            if let Some(text) = content {
                if text.lines.is_empty() {
                    return Err("Native layout measured text must contain one line".to_owned());
                }
                add_work_units(work_units, text.lines.len())?;
                for line in &text.lines {
                    add_work_units(work_units, line.clusters.len())?;
                    for cluster in &line.clusters {
                        if cluster.text.is_empty() {
                            return Err("Native layout cluster text cannot be empty".to_owned());
                        }
                        validate_dimension("cluster width", cluster.width)?;
                        if let Some(template_id) = cluster.source_template_id {
                            if template_id >= property_template_count {
                                return Err(
                                    "Native layout property template id exceeds the property template table"
                                        .to_owned(),
                                );
                            }
                        }
                    }
                }
            }
            if let Some(child) = child {
                validate_node(
                    child,
                    depth + 1,
                    nodes,
                    work_units,
                    style_count,
                    property_template_count,
                )?;
            }
        }
        LayoutNode::Row { children } | LayoutNode::Column { children } => {
            if children.is_empty() {
                return Err("Native layout container must contain a child".to_owned());
            }
            for child in children {
                validate_node(
                    child,
                    depth + 1,
                    nodes,
                    work_units,
                    style_count,
                    property_template_count,
                )?;
            }
        }
        LayoutNode::Flex {
            width,
            height,
            row_gap,
            column_gap,
            items,
            ..
        } => {
            validate_size("flex width", width)?;
            validate_size("flex height", height)?;
            add_vertical_size_work(height, work_units)?;
            validate_dimension("flex row gap", *row_gap)?;
            validate_dimension("flex column gap", *column_gap)?;
            if items.is_empty() {
                return Err("Native flex container must contain an item".to_owned());
            }
            add_work_units(
                work_units,
                usize::try_from(*row_gap)
                    .unwrap_or(usize::MAX)
                    .saturating_mul(items.len()),
            )?;
            for item in items {
                if !item.grow.is_finite()
                    || item.grow < 0.0
                    || !item.shrink.is_finite()
                    || item.shrink < 0.0
                {
                    return Err("Native flex factors must be finite and nonnegative".to_owned());
                }
                validate_size("flex basis", &item.basis)?;
                validate_node(
                    &item.node,
                    depth + 1,
                    nodes,
                    work_units,
                    style_count,
                    property_template_count,
                )?;
            }
        }
    }
    Ok(())
}

fn box_sizing_content_width(
    value: i64,
    sizing: BoxSizing,
    padding_left: i64,
    padding_right: i64,
    border_left: i64,
    border_right: i64,
) -> i64 {
    if sizing == BoxSizing::BorderBox {
        (value - padding_left - padding_right - border_left - border_right).max(0)
    } else {
        value
    }
}

fn box_sizing_content_height(
    value: i64,
    sizing: BoxSizing,
    padding_top: i64,
    padding_bottom: i64,
) -> i64 {
    if sizing == BoxSizing::BorderBox {
        (value - padding_top - padding_bottom).max(0)
    } else {
        value
    }
}

#[allow(clippy::too_many_arguments)]
fn resolve_width(
    size: &Size,
    fallback: Option<i64>,
    context: LayoutContext,
    sizing: BoxSizing,
    padding_left: i64,
    padding_right: i64,
    border_left: i64,
    border_right: i64,
    stretch: Option<i64>,
    min_content: i64,
    max_content: i64,
) -> Option<i64> {
    let convert = |value| {
        box_sizing_content_width(
            value,
            sizing,
            padding_left,
            padding_right,
            border_left,
            border_right,
        )
    };
    match size {
        Size::Auto => fallback,
        Size::Content => Some(max_content),
        Size::None => None,
        Size::Pixels { value } => Some(convert(*value)),
        Size::Viewport => context
            .viewport_width_known
            .then(|| convert(context.viewport_width))
            .or(fallback),
        Size::MinContent => Some(min_content),
        Size::MaxContent => Some(max_content),
        Size::FitContent { limit } => {
            let available = limit
                .as_deref()
                .and_then(|limit| {
                    resolve_width(
                        limit,
                        None,
                        context,
                        sizing,
                        padding_left,
                        padding_right,
                        border_left,
                        border_right,
                        stretch,
                        min_content,
                        max_content,
                    )
                })
                .or(stretch)
                .unwrap_or(max_content);
            Some(min_content.max(max_content.min(available)))
        }
        Size::Stretch | Size::Contain => stretch.or(fallback),
        Size::Lines { .. } | Size::ViewportHeight | Size::Add { .. } | Size::Subtract { .. } => {
            fallback
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn resolve_definite_width(
    size: &Size,
    context: LayoutContext,
    sizing: BoxSizing,
    padding_left: i64,
    padding_right: i64,
    border_left: i64,
    border_right: i64,
    stretch: Option<i64>,
) -> Option<i64> {
    let convert = |value| {
        box_sizing_content_width(
            value,
            sizing,
            padding_left,
            padding_right,
            border_left,
            border_right,
        )
    };
    match size {
        Size::Pixels { value } => Some(convert(*value)),
        Size::Viewport => context
            .viewport_width_known
            .then(|| convert(context.viewport_width)),
        Size::Stretch | Size::Contain | Size::FitContent { limit: None } => stretch,
        Size::FitContent { limit: Some(limit) } => resolve_definite_width(
            limit,
            context,
            sizing,
            padding_left,
            padding_right,
            border_left,
            border_right,
            stretch,
        ),
        _ => None,
    }
}

#[allow(clippy::too_many_arguments)]
fn resolve_child_viewport_width(
    width: &Size,
    min_width: &Size,
    max_width: &Size,
    context: LayoutContext,
    sizing: BoxSizing,
    padding_left: i64,
    padding_right: i64,
    border_left: i64,
    border_right: i64,
    stretch: Option<i64>,
) -> Option<i64> {
    let definite = |size| {
        resolve_definite_width(
            size,
            context,
            sizing,
            padding_left,
            padding_right,
            border_left,
            border_right,
            stretch,
        )
    };
    let minimum = definite(min_width).unwrap_or(0);
    let maximum = definite(max_width);
    let auto_stretch = if matches!(width, Size::Auto) {
        stretch
    } else {
        None
    };
    let preferred = definite(width).or(auto_stretch).or(maximum);
    preferred.map(|preferred| minimum.max(preferred.max(0).min(maximum.unwrap_or(i64::MAX))))
}

fn resolve_raw_height(size: &Size, context: LayoutContext) -> Option<i64> {
    fn resolve(size: &Size, context: LayoutContext) -> Option<i128> {
        match size {
            Size::Lines { value } | Size::Pixels { value } => Some(i128::from(*value)),
            Size::ViewportHeight => {
                (context.viewport_height > 0).then_some(i128::from(context.viewport_height))
            }
            Size::Add { values } => values.0.iter().try_fold(0_i128, |total, value| {
                resolve(value, context).and_then(|value| total.checked_add(value))
            }),
            Size::Subtract { values } => {
                let mut values = values.0.iter();
                let first = resolve(values.next()?, context)?;
                if values.len() == 0 {
                    first.checked_neg()
                } else {
                    values.try_fold(first, |total, value| {
                        resolve(value, context).and_then(|value| total.checked_sub(value))
                    })
                }
            }
            _ => None,
        }
    }

    resolve(size, context).map(|value| value.clamp(i64::MIN as i128, i64::MAX as i128) as i64)
}

fn resolve_height(
    size: &Size,
    fallback: Option<i64>,
    context: LayoutContext,
    sizing: BoxSizing,
    padding_top: i64,
    padding_bottom: i64,
) -> Option<i64> {
    match size {
        Size::Auto | Size::None | Size::Content => fallback,
        Size::Lines { .. }
        | Size::Pixels { .. }
        | Size::ViewportHeight
        | Size::Add { .. }
        | Size::Subtract { .. } => resolve_raw_height(size, context).map(|value| {
            box_sizing_content_height(value.max(0), sizing, padding_top, padding_bottom)
        }),
        _ => fallback,
    }
}

#[allow(clippy::too_many_arguments)]
fn resolve_definite_box_content_width(
    width: &Size,
    min_width: &Size,
    max_width: &Size,
    context: LayoutContext,
    sizing: BoxSizing,
    padding_left: i64,
    padding_right: i64,
    border_left: i64,
    border_right: i64,
    stretch: Option<i64>,
    override_width: Option<i64>,
) -> Option<i64> {
    let intrinsic_width = |size: &Size| {
        matches!(
            size,
            Size::Content | Size::MinContent | Size::MaxContent | Size::Auto
        )
    };
    if intrinsic_width(min_width) || intrinsic_width(max_width) {
        return None;
    }
    let definite = |size| {
        resolve_definite_width(
            size,
            context,
            sizing,
            padding_left,
            padding_right,
            border_left,
            border_right,
            stretch,
        )
    };
    let minimum = definite(min_width).unwrap_or(0);
    let maximum = definite(max_width);
    let preferred = override_width
        .or_else(|| definite(width))
        .or_else(|| matches!(width, Size::Auto).then_some(stretch).flatten())
        .or(maximum);
    preferred.map(|preferred| minimum.max(preferred.max(0).min(maximum.unwrap_or(i64::MAX))))
}

#[allow(clippy::too_many_arguments)]
fn resolve_definite_box_content_height(
    height: &Size,
    min_height: &Size,
    max_height: &Size,
    context: LayoutContext,
    sizing: BoxSizing,
    padding_top: i64,
    padding_bottom: i64,
    override_height: Option<i64>,
) -> Option<i64> {
    let minimum = resolve_height(
        min_height,
        Some(0),
        context,
        sizing,
        padding_top,
        padding_bottom,
    )
    .unwrap_or(0);
    let maximum = resolve_height(
        max_height,
        None,
        context,
        sizing,
        padding_top,
        padding_bottom,
    )
    .unwrap_or(i64::MAX);
    let preferred = override_height
        .or_else(|| resolve_height(height, None, context, sizing, padding_top, padding_bottom))?;
    Some(minimum.max(1).max(preferred.max(1).min(maximum)))
}

fn measured_max_width(text: &MeasuredText) -> i64 {
    text.lines
        .iter()
        .map(|line| line.clusters.iter().map(|cluster| cluster.width).sum())
        .max()
        .unwrap_or(0)
}

fn measured_min_width(text: &MeasuredText, wrap_mode: WrapMode) -> i64 {
    if wrap_mode == WrapMode::None {
        return measured_max_width(text);
    }
    text.lines
        .iter()
        .map(|line| {
            let mut maximum = 0;
            let mut run = 0;
            for cluster in &line.clusters {
                if cluster.space {
                    maximum = maximum.max(run);
                    run = 0;
                } else if cluster.cjk {
                    maximum = maximum.max(run).max(cluster.width);
                    run = 0;
                } else {
                    run += cluster.width;
                }
            }
            maximum.max(run)
        })
        .max()
        .unwrap_or(0)
}

fn wrap_line(clusters: &[MeasuredCluster], max_width: i64, mode: WrapMode) -> Vec<Line> {
    if clusters.is_empty() {
        return vec![Line::default()];
    }
    let total: i64 = clusters.iter().map(|cluster| cluster.width).sum();
    if mode == WrapMode::None || total <= max_width {
        return vec![Line::from_clusters(clusters)];
    }

    let count = clusters.len();
    let mut ranges = Vec::new();
    let mut line_start = 0;
    let mut current_width = 0;
    let mut index = 0;
    let flush_before = |end: usize,
                        ranges: &mut Vec<(usize, usize)>,
                        line_start: &mut usize,
                        current_width: &mut i64| {
        if *line_start < end {
            ranges.push((*line_start, end));
        }
        *line_start = end;
        *current_width = 0;
    };

    while index < count {
        let cluster_width = clusters[index].width;
        if clusters[index].cjk {
            if current_width + cluster_width > max_width {
                flush_before(index, &mut ranges, &mut line_start, &mut current_width);
            }
            current_width += cluster_width;
            index += 1;
        } else if mode == WrapMode::Word {
            let mut word_end = index;
            let mut word_width = 0;
            while word_end < count && !clusters[word_end].space && !clusters[word_end].cjk {
                word_width += clusters[word_end].width;
                word_end += 1;
            }
            if word_width > max_width {
                while index < word_end {
                    let width = clusters[index].width;
                    if current_width + width > max_width {
                        flush_before(index, &mut ranges, &mut line_start, &mut current_width);
                    }
                    current_width += width;
                    index += 1;
                }
            } else if current_width + word_width <= max_width {
                current_width += word_width;
                index = word_end;
            } else {
                flush_before(index, &mut ranges, &mut line_start, &mut current_width);
                current_width = word_width;
                index = word_end;
            }
            if index < count && clusters[index].space {
                let width = clusters[index].width;
                if current_width + width <= max_width {
                    current_width += width;
                    index += 1;
                } else {
                    flush_before(index, &mut ranges, &mut line_start, &mut current_width);
                    index += 1;
                    line_start = index;
                }
            }
        } else {
            if current_width + cluster_width > max_width {
                flush_before(index, &mut ranges, &mut line_start, &mut current_width);
            }
            current_width += cluster_width;
            index += 1;
        }
    }
    if line_start < count {
        ranges.push((line_start, count));
    }
    ranges
        .into_iter()
        .map(|(start, end)| Line::from_clusters(&clusters[start..end]))
        .collect()
}

fn measured_lines(text: &MeasuredText, width: i64, mode: WrapMode) -> Vec<Line> {
    text.lines
        .iter()
        .flat_map(|line| wrap_line(&line.clusters, width, mode))
        .collect()
}

fn wrap_rendered_line(line: &Line, max_width: i64, mode: WrapMode) -> Vec<Line> {
    if line.atoms.is_empty() {
        return vec![Line::default()];
    }
    if mode == WrapMode::None || line.width <= max_width {
        return vec![line.clone()];
    }

    let atoms = &line.atoms;
    let count = atoms.len();
    let mut ranges = Vec::new();
    let mut line_start = 0;
    let mut current_width = 0;
    let mut index = 0;
    let flush_before = |end: usize,
                        ranges: &mut Vec<(usize, usize)>,
                        line_start: &mut usize,
                        current_width: &mut i64| {
        if *line_start < end {
            ranges.push((*line_start, end));
        }
        *line_start = end;
        *current_width = 0;
    };

    while index < count {
        let atom_width = atoms[index].width();
        if atoms[index].wrap_cjk() {
            if current_width + atom_width > max_width {
                flush_before(index, &mut ranges, &mut line_start, &mut current_width);
            }
            current_width += atom_width;
            index += 1;
        } else if mode == WrapMode::Word {
            let mut word_end = index;
            let mut word_width = 0;
            while word_end < count && !atoms[word_end].wrap_space() && !atoms[word_end].wrap_cjk() {
                word_width += atoms[word_end].width();
                word_end += 1;
            }
            if word_width > max_width {
                while index < word_end {
                    let width = atoms[index].width();
                    if current_width + width > max_width {
                        flush_before(index, &mut ranges, &mut line_start, &mut current_width);
                    }
                    current_width += width;
                    index += 1;
                }
            } else if current_width + word_width <= max_width {
                current_width += word_width;
                index = word_end;
            } else {
                flush_before(index, &mut ranges, &mut line_start, &mut current_width);
                current_width = word_width;
                index = word_end;
            }
            if index < count && atoms[index].wrap_space() {
                let width = atoms[index].width();
                if current_width + width <= max_width {
                    current_width += width;
                    index += 1;
                } else {
                    flush_before(index, &mut ranges, &mut line_start, &mut current_width);
                    index += 1;
                    line_start = index;
                }
            }
        } else {
            if current_width + atom_width > max_width {
                flush_before(index, &mut ranges, &mut line_start, &mut current_width);
            }
            current_width += atom_width;
            index += 1;
        }
    }
    if line_start < count {
        ranges.push((line_start, count));
    }
    ranges
        .into_iter()
        .map(|(start, end)| Line::from_atoms(&atoms[start..end]))
        .collect()
}

fn wrap_rendered(rendered: Rendered, max_width: i64, mode: WrapMode) -> Rendered {
    if mode == WrapMode::None {
        return rendered;
    }
    let original_breaks = rendered.breaks;
    let mut lines = Vec::new();
    let mut breaks = Vec::new();
    for (line_index, line) in rendered.lines.into_iter().enumerate() {
        for (piece_index, piece) in wrap_rendered_line(&line, max_width, mode)
            .into_iter()
            .enumerate()
        {
            if !lines.is_empty() {
                breaks.push(if piece_index == 0 {
                    original_breaks[line_index - 1].clone()
                } else {
                    AtomProperties::default()
                });
            }
            lines.push(piece);
        }
    }
    Rendered { lines, breaks }
}

fn vertical_align(
    mut lines: Vec<Line>,
    height: usize,
    align: VerticalAlign,
    width: i64,
) -> Vec<Line> {
    lines.truncate(height);
    if lines.len() >= height {
        return lines;
    }
    let rest = height - lines.len();
    let top = match align {
        VerticalAlign::Top => 0,
        VerticalAlign::Bottom => rest,
        VerticalAlign::Center => rest / 2,
    };
    let mut output = Vec::with_capacity(height);
    output.extend((0..top).map(|_| Line::blank(width)));
    output.append(&mut lines);
    output.extend((0..(rest - top)).map(|_| Line::blank(width)));
    output
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FlexAxis {
    Row,
    Column,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FlexMode {
    Grow,
    Shrink,
}

#[derive(Debug, Clone)]
struct FlexRuntimeItem<'a> {
    source: &'a LayoutNode,
    grow: f64,
    shrink: f64,
    align_self: FlexAlign,
    min_main: i64,
    max_main: Option<i64>,
    base: i64,
    hypothetical: i64,
    target: i64,
}

#[derive(Debug)]
struct FlexSizedEntry {
    rendered: Rendered,
    cross: i64,
}

#[derive(Debug)]
struct FlexCrossLayout {
    crosses: Vec<i64>,
    leading: i64,
    between: i64,
}

fn flex_axis(direction: FlexDirection) -> FlexAxis {
    match direction {
        FlexDirection::Row | FlexDirection::RowReverse => FlexAxis::Row,
        FlexDirection::Column | FlexDirection::ColumnReverse => FlexAxis::Column,
    }
}

fn flex_direction_reversed(direction: FlexDirection) -> bool {
    matches!(
        direction,
        FlexDirection::RowReverse | FlexDirection::ColumnReverse
    )
}

fn flex_horizontal_size(size: &Size, context: LayoutContext) -> Option<i64> {
    match size {
        Size::Auto | Size::Stretch | Size::Contain => context
            .viewport_width_known
            .then_some(context.viewport_width.max(0)),
        Size::Pixels { value } | Size::Lines { value } => Some(*value),
        Size::Viewport => context
            .viewport_width_known
            .then_some(context.viewport_width.max(0)),
        Size::None | Size::Content => None,
        Size::MinContent | Size::MaxContent | Size::FitContent { .. } => context
            .viewport_width_known
            .then_some(context.viewport_width.max(0)),
        Size::ViewportHeight | Size::Add { .. } | Size::Subtract { .. } => None,
    }
}

fn flex_vertical_size(size: &Size, context: LayoutContext) -> Option<i64> {
    match size {
        Size::Lines { .. }
        | Size::Pixels { .. }
        | Size::ViewportHeight
        | Size::Add { .. }
        | Size::Subtract { .. } => resolve_raw_height(size, context).map(|value| value.max(0)),
        _ => None,
    }
}

fn flex_inline_viewport(
    axis: FlexAxis,
    main_size: Option<i64>,
    cross_size: Option<i64>,
) -> Option<i64> {
    match axis {
        FlexAxis::Row => main_size,
        FlexAxis::Column => cross_size,
    }
}

fn box_horizontal_side(node: &LayoutNode) -> Option<i64> {
    if let LayoutNode::Box {
        padding_left,
        padding_right,
        margin_left,
        margin_right,
        border_left,
        border_right,
        ..
    } = node
    {
        Some(padding_left + padding_right + margin_left + margin_right + border_left + border_right)
    } else {
        None
    }
}

fn box_vertical_side(node: &LayoutNode) -> Option<i64> {
    if let LayoutNode::Box {
        padding_top,
        padding_bottom,
        margin_top,
        margin_bottom,
        ..
    } = node
    {
        Some(padding_top + padding_bottom + margin_top + margin_bottom)
    } else {
        None
    }
}

fn box_content_intrinsics(
    node: &LayoutNode,
    context: LayoutContext,
) -> Result<Option<(i64, i64)>, String> {
    let LayoutNode::Box {
        content,
        child,
        content_min_width,
        wrap_mode,
        ..
    } = node
    else {
        return Ok(None);
    };
    if let Some(text) = content {
        Ok(Some((
            content_min_width.unwrap_or_else(|| measured_min_width(text, *wrap_mode)),
            measured_max_width(text),
        )))
    } else if let Some(child) = child {
        // Ebox measures a composite box's child under the flex container's
        // current inline viewport.  Treating that width as unknown makes
        // responsive descendants collapse to their narrow intrinsic form and
        // produces a different automatic minimum from the visible renderer.
        let rendered = render_node(child, context, true)?;
        Ok(Some((
            content_min_width.unwrap_or_else(|| rendered.min_content_width(*wrap_mode)),
            rendered.max_width(),
        )))
    } else {
        Ok(Some((0, 0)))
    }
}

fn flex_box_resolve_width(
    node: &LayoutNode,
    size: &Size,
    fallback: Option<i64>,
    context: LayoutContext,
) -> Result<Option<i64>, String> {
    let LayoutNode::Box {
        box_sizing,
        padding_left,
        padding_right,
        border_left,
        border_right,
        ..
    } = node
    else {
        return Ok(fallback);
    };
    let (min_content, max_content) = box_content_intrinsics(node, context)?.unwrap_or((0, 0));
    let side = box_horizontal_side(node).unwrap_or(0);
    let stretch = context
        .viewport_width_known
        .then_some((context.viewport_width - side).max(0));
    Ok(resolve_width(
        size,
        fallback,
        context,
        *box_sizing,
        *padding_left,
        *padding_right,
        *border_left,
        *border_right,
        stretch,
        min_content,
        max_content,
    ))
}

fn flex_box_resolve_height(
    node: &LayoutNode,
    size: &Size,
    fallback: Option<i64>,
    context: LayoutContext,
) -> Option<i64> {
    let LayoutNode::Box {
        box_sizing,
        padding_top,
        padding_bottom,
        ..
    } = node
    else {
        return fallback;
    };
    resolve_height(
        size,
        fallback,
        context,
        *box_sizing,
        *padding_top,
        *padding_bottom,
    )
}

fn flex_min_main(
    source: &LayoutNode,
    rendered: &Rendered,
    axis: FlexAxis,
    context: LayoutContext,
) -> Result<i64, String> {
    let LayoutNode::Box {
        min_width,
        min_height,
        wrap_mode,
        content_min_width,
        ..
    } = source
    else {
        return Ok(match axis {
            FlexAxis::Row => rendered.max_width(),
            FlexAxis::Column => rendered.height(),
        });
    };
    Ok(match axis {
        FlexAxis::Row => {
            let side = box_horizontal_side(source).unwrap_or(0);
            let declared =
                flex_box_resolve_width(source, min_width, Some(0), context)?.unwrap_or(0);
            if *wrap_mode == WrapMode::None {
                rendered.max_width().max(side + declared)
            } else {
                let content_min = match content_min_width {
                    Some(content_min_width) => *content_min_width,
                    None => box_content_intrinsics(source, context)?.unwrap_or((0, 0)).0,
                };
                side + declared.max(content_min)
            }
        }
        FlexAxis::Column => {
            box_vertical_side(source).unwrap_or(0)
                + flex_box_resolve_height(source, min_height, Some(0), context)
                    .unwrap_or(0)
                    .max(1)
        }
    })
}

fn flex_max_main(
    source: &LayoutNode,
    axis: FlexAxis,
    context: LayoutContext,
) -> Result<Option<i64>, String> {
    let LayoutNode::Box {
        max_width,
        max_height,
        ..
    } = source
    else {
        return Ok(None);
    };
    Ok(match axis {
        FlexAxis::Row => flex_box_resolve_width(source, max_width, None, context)?
            .map(|value| value + box_horizontal_side(source).unwrap_or(0)),
        FlexAxis::Column => flex_box_resolve_height(source, max_height, None, context)
            .map(|value| value + box_vertical_side(source).unwrap_or(0)),
    })
}

fn flex_horizontal_basis_value(size: &Size, context: LayoutContext) -> i64 {
    match size {
        Size::Pixels { value } | Size::Lines { value } => *value,
        Size::Viewport => context.viewport_width.max(0),
        Size::Stretch | Size::Contain => context.viewport_width.max(0),
        _ => 0,
    }
}

fn flex_vertical_basis_value(size: &Size) -> i64 {
    match size {
        Size::Pixels { value } | Size::Lines { value } => *value,
        _ => 0,
    }
}

fn flex_basis_main(
    source: &LayoutNode,
    rendered: &Rendered,
    axis: FlexAxis,
    basis: &Size,
    context: LayoutContext,
) -> Result<i64, String> {
    let rendered_main = match axis {
        FlexAxis::Row => rendered.max_width(),
        FlexAxis::Column => rendered.height(),
    };
    if matches!(basis, Size::Auto) {
        return Ok(rendered_main);
    }
    if matches!(basis, Size::Content) {
        if axis == FlexAxis::Row && matches!(source, LayoutNode::Box { .. }) {
            let (_, content_max) = box_content_intrinsics(source, context)?.unwrap_or((0, 0));
            return Ok(box_horizontal_side(source).unwrap_or(0) + content_max);
        }
        return Ok(rendered_main);
    }
    if axis == FlexAxis::Row && matches!(source, LayoutNode::Box { .. }) {
        let (_, content_max) = box_content_intrinsics(source, context)?.unwrap_or((0, 0));
        let content = flex_box_resolve_width(source, basis, Some(content_max), context)?
            .unwrap_or(content_max);
        return Ok(box_horizontal_side(source).unwrap_or(0) + content);
    }
    Ok(match axis {
        FlexAxis::Row => flex_horizontal_basis_value(basis, context),
        FlexAxis::Column => flex_vertical_basis_value(basis),
    })
}

fn flex_clamp_main(value: i64, minimum: i64, maximum: Option<i64>) -> i64 {
    minimum.max(value.max(0).min(maximum.unwrap_or(999_999_999)))
}

// Plain boxes receive their flex target through BoxOverride.  Composite
// layouts, including the exact wrapper emitted for a visual flex container,
// must instead resolve viewport sizes against the item's inline allocation.
fn flex_item_uses_inline_viewport(node: &LayoutNode) -> bool {
    match node {
        LayoutNode::Box {
            content,
            child: Some(child),
            content_width_exact: true,
            ..
        } if content.is_none() => matches!(child.as_ref(), LayoutNode::Flex { .. }),
        LayoutNode::Box { .. } => false,
        _ => true,
    }
}

fn measure_flex_item<'a>(
    item: &'a FlexItem,
    axis: FlexAxis,
    inline_viewport: Option<i64>,
    context: LayoutContext,
) -> Result<FlexRuntimeItem<'a>, String> {
    let uses_inline_viewport = flex_item_uses_inline_viewport(&item.node);
    let measurement_context = LayoutContext {
        viewport_width: if uses_inline_viewport {
            inline_viewport.unwrap_or(0)
        } else {
            0
        },
        viewport_width_known: uses_inline_viewport && inline_viewport.is_some(),
        viewport_height: context.viewport_height,
    };
    let rendered = render_node(&item.node, measurement_context, uses_inline_viewport)?;
    let min_main = flex_min_main(&item.node, &rendered, axis, context)?;
    let max_main = flex_max_main(&item.node, axis, context)?;
    let base = flex_basis_main(&item.node, &rendered, axis, &item.basis, context)?.max(0);
    let hypothetical = flex_clamp_main(base, min_main, max_main);
    Ok(FlexRuntimeItem {
        source: &item.node,
        grow: item.grow,
        shrink: item.shrink,
        align_self: item.align_self,
        min_main,
        max_main,
        base,
        hypothetical,
        target: hypothetical,
    })
}

fn flex_break_lines<'a>(
    items: Vec<FlexRuntimeItem<'a>>,
    main_limit: Option<i64>,
    main_gap: i64,
    wrap: FlexWrap,
) -> Vec<Vec<FlexRuntimeItem<'a>>> {
    if wrap == FlexWrap::Nowrap || main_limit.is_none() {
        return vec![items];
    }
    let limit = main_limit.unwrap_or(0);
    let mut lines = Vec::new();
    let mut current = Vec::new();
    let mut current_size = 0;
    for item in items {
        let next_size =
            current_size + if current.is_empty() { 0 } else { main_gap } + item.hypothetical;
        if !current.is_empty() && next_size > limit {
            lines.push(current);
            current = vec![item];
            current_size = current[0].hypothetical;
        } else {
            current_size = next_size;
            current.push(item);
        }
    }
    if !current.is_empty() {
        lines.push(current);
    }
    lines
}

fn flex_factor(item: &FlexRuntimeItem<'_>, mode: FlexMode) -> f64 {
    match mode {
        FlexMode::Grow => item.grow,
        FlexMode::Shrink => item.shrink,
    }
}

fn flex_distribution_weight(item: &FlexRuntimeItem<'_>, mode: FlexMode) -> f64 {
    match mode {
        FlexMode::Grow => item.grow,
        FlexMode::Shrink => item.base as f64 * item.shrink,
    }
}

fn flex_line_free_space(
    line: &[FlexRuntimeItem<'_>],
    targets: &[i64],
    frozen: &[bool],
    available: i64,
) -> i64 {
    available
        - line
            .iter()
            .enumerate()
            .map(|(index, item)| {
                if frozen[index] {
                    targets[index]
                } else {
                    item.base
                }
            })
            .sum::<i64>()
}

fn flex_effective_free_space(initial: i64, free: i64, factor_total: f64) -> f64 {
    if factor_total > 0.0 && factor_total < 1.0 {
        let partial = initial as f64 * factor_total;
        if partial.abs() < (free as f64).abs() {
            partial
        } else {
            free as f64
        }
    } else {
        free as f64
    }
}

fn flex_distribute(amount: f64, weights: &[f64]) -> Vec<i64> {
    let amount = amount.max(0.0).floor() as i64;
    let total = weights
        .iter()
        .copied()
        .filter(|weight| *weight > 0.0)
        .sum::<f64>();
    if amount <= 0 || total <= 0.0 {
        return vec![0; weights.len()];
    }
    let mut shares = weights
        .iter()
        .map(|weight| {
            if *weight > 0.0 {
                ((amount as f64 * *weight) / total).floor() as i64
            } else {
                0
            }
        })
        .collect::<Vec<_>>();
    let mut remaining = amount - shares.iter().sum::<i64>();
    while remaining > 0 {
        for (share, weight) in shares.iter_mut().zip(weights) {
            if remaining == 0 {
                break;
            }
            if *weight > 0.0 {
                *share += 1;
                remaining -= 1;
            }
        }
    }
    shares
}

fn flex_size_line(line: &mut [FlexRuntimeItem<'_>], main_limit: Option<i64>, main_gap: i64) {
    let count = line.len();
    let Some(limit) = main_limit else {
        return;
    };
    let available = limit - main_gap * count.saturating_sub(1) as i64;
    let hypothetical_total = line.iter().map(|item| item.hypothetical).sum::<i64>();
    let mode = if hypothetical_total < available {
        FlexMode::Grow
    } else {
        FlexMode::Shrink
    };
    let mut targets = line.iter().map(|item| item.base).collect::<Vec<_>>();
    let mut frozen = vec![false; count];
    for (index, item) in line.iter().enumerate() {
        let factor = flex_factor(item, mode);
        if factor <= 0.0
            || (mode == FlexMode::Grow && item.base > item.hypothetical)
            || (mode == FlexMode::Shrink && item.base < item.hypothetical)
        {
            targets[index] = item.hypothetical;
            frozen[index] = true;
        }
    }
    let initial_free = flex_line_free_space(line, &targets, &frozen, available);
    loop {
        let free = flex_line_free_space(line, &targets, &frozen, available);
        let active = (0..count)
            .filter(|index| !frozen[*index])
            .collect::<Vec<_>>();
        let weights = active
            .iter()
            .map(|index| flex_distribution_weight(&line[*index], mode))
            .collect::<Vec<_>>();
        let weight_total = weights.iter().sum::<f64>();
        let factor_total = active
            .iter()
            .map(|index| flex_factor(&line[*index], mode))
            .sum::<f64>();
        let effective = flex_effective_free_space(initial_free, free, factor_total);
        if active.is_empty()
            || weight_total <= 0.0
            || (mode == FlexMode::Grow && effective < 0.0)
            || (mode == FlexMode::Shrink && effective > 0.0)
        {
            break;
        }
        let deltas = flex_distribute(effective.abs(), &weights);
        let mut min_violations = Vec::new();
        let mut max_violations = Vec::new();
        let mut total_violation = 0;
        for ((index, delta), _) in active.iter().zip(deltas).zip(&weights) {
            let item = &line[*index];
            let candidate = match mode {
                FlexMode::Grow => item.base + delta,
                FlexMode::Shrink => item.base - delta,
            };
            let clamped = flex_clamp_main(candidate, item.min_main, item.max_main);
            let adjustment = clamped - candidate;
            targets[*index] = clamped;
            if adjustment > 0 {
                min_violations.push(*index);
            } else if adjustment < 0 {
                max_violations.push(*index);
            }
            total_violation += adjustment;
        }
        let to_freeze = if total_violation == 0 {
            active
        } else if total_violation > 0 {
            if min_violations.is_empty() {
                active
            } else {
                min_violations
            }
        } else if max_violations.is_empty() {
            active
        } else {
            max_violations
        };
        for index in to_freeze {
            frozen[index] = true;
        }
    }
    for (item, target) in line.iter_mut().zip(targets) {
        item.target = target;
    }
}

fn flex_line_main_size(line: &[FlexRuntimeItem<'_>], main_gap: i64) -> i64 {
    line.iter().map(|item| item.target).sum::<i64>()
        + main_gap * line.len().saturating_sub(1) as i64
}

fn flex_spacing(mode: FlexAlign, leftover: i64, count: usize, base_gap: i64) -> (i64, i64, i64) {
    let leftover = leftover.max(0);
    match mode {
        FlexAlign::FlexEnd | FlexAlign::End | FlexAlign::Right | FlexAlign::Bottom => {
            (leftover, base_gap, 0)
        }
        FlexAlign::Center => {
            let leading = leftover / 2;
            (leading, base_gap, leftover - leading)
        }
        FlexAlign::SpaceBetween if count > 1 => (0, base_gap + leftover / (count as i64 - 1), 0),
        FlexAlign::SpaceBetween => (0, base_gap, leftover),
        FlexAlign::SpaceAround => {
            let unit = if count > 0 {
                leftover / count as i64
            } else {
                0
            };
            let leading = unit / 2;
            (
                leading,
                base_gap + unit,
                leftover - leading - unit * count.saturating_sub(1) as i64,
            )
        }
        FlexAlign::SpaceEvenly => {
            let unit = if count > 0 {
                leftover / (count as i64 + 1)
            } else {
                0
            };
            (unit, base_gap + unit, unit)
        }
        _ => (0, base_gap, leftover),
    }
}

fn flex_cross_offset(align: FlexAlign, extra: i64) -> i64 {
    match align {
        FlexAlign::FlexEnd
        | FlexAlign::End
        | FlexAlign::SelfEnd
        | FlexAlign::Right
        | FlexAlign::Bottom => extra,
        FlexAlign::Center => extra / 2,
        _ => 0,
    }
}

fn flex_resolved_align(item: &FlexRuntimeItem<'_>, container: FlexAlign) -> FlexAlign {
    if item.align_self == FlexAlign::Auto {
        container
    } else {
        item.align_self
    }
}

fn pad_rendered_width(mut rendered: Rendered, width: i64, align: FlexAlign) -> Rendered {
    for line in &mut rendered.lines {
        let extra = (width - line.width).max(0);
        let left = match align {
            FlexAlign::FlexEnd | FlexAlign::End | FlexAlign::Right | FlexAlign::SelfEnd => extra,
            FlexAlign::Center => extra / 2,
            _ => 0,
        };
        line.prepend_space(left);
        line.push_space(extra - left);
    }
    rendered
}

fn pad_rendered_height(rendered: Rendered, height: i64, offset: i64, width: i64) -> Rendered {
    let extra = (height - rendered.height()).max(0);
    let top = extra.min(offset.max(0));
    let bottom = extra - top;
    let mut parts = Vec::with_capacity(3);
    if top > 0 {
        parts.push(Rendered::from_lines(
            (0..top).map(|_| Line::blank(width)).collect(),
        ));
    }
    parts.push(rendered);
    if bottom > 0 {
        parts.push(Rendered::from_lines(
            (0..bottom).map(|_| Line::blank(width)).collect(),
        ));
    }
    stack_vertical(parts)
}

fn box_override_for_flex(
    source: &LayoutNode,
    axis: FlexAxis,
    main: i64,
    cross: Option<i64>,
    stretch: bool,
) -> Option<BoxOverride> {
    if !matches!(source, LayoutNode::Box { .. }) {
        return None;
    }
    let horizontal_side = box_horizontal_side(source).unwrap_or(0);
    let vertical_side = box_vertical_side(source).unwrap_or(0);
    Some(match axis {
        FlexAxis::Row => BoxOverride {
            content_width: Some((main - horizontal_side).max(0)),
            content_height: (stretch && cross.is_some())
                .then_some((cross.unwrap_or(0) - vertical_side).max(0)),
            declared_width: None,
        },
        FlexAxis::Column => BoxOverride {
            content_width: (stretch && cross.is_some())
                .then_some((cross.unwrap_or(0) - horizontal_side).max(0)),
            content_height: Some((main - vertical_side).max(0)),
            declared_width: None,
        },
    })
}

fn render_flex_sized_entry(
    item: &FlexRuntimeItem<'_>,
    axis: FlexAxis,
    main: i64,
    cross: Option<i64>,
    container_align: FlexAlign,
    context: LayoutContext,
    intrinsic: bool,
) -> Result<FlexSizedEntry, String> {
    let align = flex_resolved_align(item, container_align);
    let stretch = matches!(align, FlexAlign::Stretch | FlexAlign::Normal);
    let source_box = !flex_item_uses_inline_viewport(item.source);
    let item_viewport = flex_inline_viewport(axis, Some(main), cross);
    let render_context = LayoutContext {
        viewport_width: if source_box {
            context.viewport_width
        } else {
            item_viewport.unwrap_or(context.viewport_width)
        },
        viewport_width_known: if source_box {
            context.viewport_width_known
        } else {
            item_viewport.is_some() || context.viewport_width_known
        },
        viewport_height: context.viewport_height,
    };
    let override_size = box_override_for_flex(item.source, axis, main, cross, stretch);
    let mut rendered =
        render_node_with_override(item.source, render_context, intrinsic, override_size)?;
    match axis {
        FlexAxis::Row => {
            rendered = pad_rendered_width(rendered, main, FlexAlign::FlexStart);
        }
        FlexAxis::Column => {
            let width = rendered.max_width();
            rendered = pad_rendered_height(rendered, main, 0, width);
        }
    }
    if let Some(cross) = cross {
        match axis {
            FlexAxis::Row => {
                let width = main.max(rendered.max_width());
                let extra = (cross - rendered.height()).max(0);
                rendered =
                    pad_rendered_height(rendered, cross, flex_cross_offset(align, extra), width);
            }
            FlexAxis::Column => {
                rendered = pad_rendered_width(rendered, cross, align);
            }
        }
    }
    let rendered_cross = cross.unwrap_or_else(|| match axis {
        FlexAxis::Row => rendered.height(),
        FlexAxis::Column => rendered.max_width(),
    });
    Ok(FlexSizedEntry {
        rendered,
        cross: rendered_cross,
    })
}

fn concat_horizontal_sized(parts: Vec<(Rendered, i64)>, target_height: i64) -> Rendered {
    let height = parts
        .iter()
        .map(|(rendered, _)| rendered.height())
        .max()
        .unwrap_or(1)
        .max(target_height);
    let mut lines = Vec::with_capacity(height as usize);
    for index in 0..height as usize {
        let mut line = Line::default();
        for (rendered, width) in &parts {
            if let Some(part) = rendered.lines.get(index) {
                line.append(part);
            } else {
                line.push_space(*width);
            }
        }
        lines.push(line);
    }
    Rendered::from_lines(lines)
}

fn stack_vertical(parts: Vec<Rendered>) -> Rendered {
    let mut lines = Vec::new();
    let mut breaks = Vec::new();
    for mut part in parts {
        if part.lines.is_empty() {
            continue;
        }
        if !lines.is_empty() {
            breaks.push(AtomProperties::default());
        }
        lines.append(&mut part.lines);
        breaks.append(&mut part.breaks);
    }
    if lines.is_empty() {
        lines.push(Line::default());
    }
    Rendered { lines, breaks }
}

fn slice_rendered(rendered: Rendered, start: i64, height: i64) -> Rendered {
    let start = usize::try_from(start.max(0)).unwrap_or(usize::MAX);
    let height = usize::try_from(height.max(0)).unwrap_or(0);
    let end = start.saturating_add(height).min(rendered.lines.len());
    if start >= end {
        return Rendered {
            lines: Vec::new(),
            breaks: Vec::new(),
        };
    }
    let line_count = end - start;
    let lines = rendered
        .lines
        .into_iter()
        .skip(start)
        .take(line_count)
        .collect::<Vec<_>>();
    let breaks = rendered
        .breaks
        .into_iter()
        .skip(start)
        .take(line_count.saturating_sub(1))
        .collect::<Vec<_>>();
    Rendered { lines, breaks }
}

fn exact_rendered_height(node: &LayoutNode, context: LayoutContext) -> Option<i64> {
    match node {
        LayoutNode::Box {
            height,
            min_height,
            max_height,
            box_sizing,
            padding_top,
            padding_bottom,
            margin_top,
            margin_bottom,
            overflow,
            ..
        } => {
            if *overflow == Overflow::Visible {
                return None;
            }
            let content_height = resolve_definite_box_content_height(
                height,
                min_height,
                max_height,
                context,
                *box_sizing,
                *padding_top,
                *padding_bottom,
                None,
            )?;
            Some(content_height + padding_top + padding_bottom + margin_top + margin_bottom)
        }
        LayoutNode::Row { children } => children
            .iter()
            .map(|child| exact_rendered_height(child, context))
            .try_fold(1_i64, |maximum, height| {
                height.map(|height| maximum.max(height))
            }),
        LayoutNode::Column { children } => children
            .iter()
            .map(|child| exact_rendered_height(child, context))
            .try_fold(0_i64, |total, height| {
                height.and_then(|height| total.checked_add(height))
            }),
        LayoutNode::Flex { .. } => None,
    }
}

fn render_node_window(
    node: &LayoutNode,
    context: LayoutContext,
    intrinsic: bool,
    start: i64,
    height: i64,
) -> Option<Result<Rendered, String>> {
    let total_height = exact_rendered_height(node, context)?;
    if start <= 0 && height >= total_height {
        return Some(render_node(node, context, intrinsic));
    }
    match node {
        LayoutNode::Column { children } if !intrinsic && context.viewport_width_known => {
            Some(render_column_window(children, context, start, height))
        }
        _ => Some(
            render_node(node, context, intrinsic)
                .map(|rendered| slice_rendered(rendered, start, height)),
        ),
    }
}

fn render_column_window(
    children: &[LayoutNode],
    context: LayoutContext,
    start: i64,
    height: i64,
) -> Result<Rendered, String> {
    let mut leaves = Vec::new();
    collect_column_leaves(children, &mut leaves);
    let end = start.saturating_add(height).max(start);
    let target = context.viewport_width.max(0);
    let mut offset = 0_i64;
    let mut parts = Vec::new();

    for child in leaves {
        let child_height = exact_rendered_height(child, context)
            .ok_or_else(|| "Native layout column window has an unbounded child".to_owned())?;
        let child_end = offset.saturating_add(child_height);
        if child_end <= start {
            offset = child_end;
            continue;
        }
        if offset >= end {
            break;
        }

        let child_start = start.saturating_sub(offset);
        let child_window_height = (child_end.min(end) - (offset + child_start)).max(0);
        let mut rendered = if child_start == 0 && child_window_height >= child_height {
            render_node(child, context, false)?
        } else {
            render_node_window(child, context, false, child_start, child_window_height)
                .unwrap_or_else(|| {
                    render_node(child, context, false)
                        .map(|rendered| slice_rendered(rendered, child_start, child_window_height))
                })?
        };

        let extra = (target - rendered.first_width()).max(0);
        for line in &mut rendered.lines {
            line.push_space(extra);
        }
        if extra > 0 {
            rendered.breaks =
                vec![AtomProperties::default(); rendered.lines.len().saturating_sub(1)];
        }
        if !rendered.lines.is_empty() {
            parts.push(rendered);
        }
        offset = child_end;
    }

    Ok(stack_vertical(parts))
}

fn flex_line_cross(
    line: &[FlexRuntimeItem<'_>],
    axis: FlexAxis,
    container_align: FlexAlign,
    context: LayoutContext,
    intrinsic: bool,
) -> Result<i64, String> {
    let mut maximum = 1;
    for item in line {
        maximum = maximum.max(
            render_flex_sized_entry(
                item,
                axis,
                item.target,
                None,
                container_align,
                context,
                intrinsic,
            )?
            .cross,
        );
    }
    Ok(maximum)
}

fn flex_layout_cross(
    crosses: Vec<i64>,
    container_cross: Option<i64>,
    cross_gap: i64,
    align: FlexAlign,
    single_line: bool,
) -> FlexCrossLayout {
    let count = crosses.len();
    let natural = crosses.iter().sum::<i64>() + cross_gap * count.saturating_sub(1) as i64;
    let leftover = container_cross.map_or(0, |cross| cross - natural);
    if let Some(cross) = container_cross {
        if single_line && count == 1 {
            return FlexCrossLayout {
                crosses: vec![cross],
                leading: 0,
                between: cross_gap,
            };
        }
        if leftover > 0 && matches!(align, FlexAlign::Stretch | FlexAlign::Normal) {
            let extras = flex_distribute(leftover as f64, &vec![1.0; count]);
            return FlexCrossLayout {
                crosses: crosses
                    .into_iter()
                    .zip(extras)
                    .map(|(value, extra)| value + extra)
                    .collect(),
                leading: 0,
                between: cross_gap,
            };
        }
    }
    let (leading, between, _) = flex_spacing(align, leftover, count, cross_gap);
    FlexCrossLayout {
        crosses,
        leading,
        between,
    }
}

#[allow(clippy::too_many_arguments)]
fn render_flex_row_line(
    line: &[FlexRuntimeItem<'_>],
    line_cross: i64,
    main_size: i64,
    main_gap: i64,
    justify: FlexAlign,
    align: FlexAlign,
    context: LayoutContext,
    intrinsic: bool,
) -> Result<Rendered, String> {
    let line_main = flex_line_main_size(line, main_gap);
    let (leading, between, trailing) =
        flex_spacing(justify, main_size - line_main, line.len(), main_gap);
    let mut parts = vec![(Rendered::from_lines(vec![Line::blank(leading)]), leading)];
    for (index, item) in line.iter().enumerate() {
        let entry = render_flex_sized_entry(
            item,
            FlexAxis::Row,
            item.target,
            Some(line_cross),
            align,
            context,
            intrinsic,
        )?;
        parts.push((entry.rendered, item.target));
        if index + 1 < line.len() {
            parts.push((Rendered::from_lines(vec![Line::blank(between)]), between));
        }
    }
    if trailing > 0 {
        parts.push((Rendered::from_lines(vec![Line::blank(trailing)]), trailing));
    }
    Ok(concat_horizontal_sized(parts, line_cross))
}

#[allow(clippy::too_many_arguments)]
fn render_flex_column_line(
    line: &[FlexRuntimeItem<'_>],
    line_cross: i64,
    main_size: Option<i64>,
    main_gap: i64,
    justify: FlexAlign,
    align: FlexAlign,
    context: LayoutContext,
    intrinsic: bool,
) -> Result<Rendered, String> {
    let line_main = flex_line_main_size(line, main_gap);
    let target_main = main_size.unwrap_or(line_main);
    let (leading, between, _) =
        flex_spacing(justify, target_main - line_main, line.len(), main_gap);
    let mut parts = Vec::new();
    if leading > 0 {
        parts.push(Rendered::from_lines(
            (0..leading).map(|_| Line::blank(line_cross)).collect(),
        ));
    }
    for (index, item) in line.iter().enumerate() {
        parts.push(
            render_flex_sized_entry(
                item,
                FlexAxis::Column,
                item.target,
                Some(line_cross),
                align,
                context,
                intrinsic,
            )?
            .rendered,
        );
        if index + 1 < line.len() && between > 0 {
            parts.push(Rendered::from_lines(
                (0..between).map(|_| Line::blank(line_cross)).collect(),
            ));
        }
    }
    let rendered = stack_vertical(parts);
    Ok(pad_rendered_height(rendered, target_main, 0, line_cross))
}

#[allow(clippy::too_many_arguments)]
fn render_flex_row(
    mut lines: Vec<Vec<FlexRuntimeItem<'_>>>,
    main_size: Option<i64>,
    cross_size: Option<i64>,
    main_gap: i64,
    cross_gap: i64,
    justify: FlexAlign,
    align: FlexAlign,
    align_content: FlexAlign,
    single_line: bool,
    context: LayoutContext,
    intrinsic: bool,
) -> Result<Rendered, String> {
    for line in &mut lines {
        flex_size_line(line, main_size, main_gap);
    }
    let container_main = main_size.unwrap_or_else(|| {
        lines
            .iter()
            .map(|line| flex_line_main_size(line, main_gap))
            .max()
            .unwrap_or(0)
    });
    let crosses = if cross_size.is_some() && single_line {
        vec![cross_size.unwrap_or(0)]
    } else {
        lines
            .iter()
            .map(|line| flex_line_cross(line, FlexAxis::Row, align, context, intrinsic))
            .collect::<Result<Vec<_>, _>>()?
    };
    let cross_layout =
        flex_layout_cross(crosses, cross_size, cross_gap, align_content, single_line);
    let mut parts = Vec::new();
    if cross_layout.leading > 0 {
        parts.push(Rendered::from_lines(
            (0..cross_layout.leading)
                .map(|_| Line::blank(container_main))
                .collect(),
        ));
    }
    let line_count = lines.len();
    for (index, (line, line_cross)) in lines
        .iter()
        .zip(cross_layout.crosses.iter().copied())
        .enumerate()
    {
        parts.push(render_flex_row_line(
            line,
            line_cross,
            container_main,
            main_gap,
            justify,
            align,
            context,
            intrinsic,
        )?);
        if index + 1 < line_count && cross_layout.between > 0 {
            parts.push(Rendered::from_lines(
                (0..cross_layout.between)
                    .map(|_| Line::blank(container_main))
                    .collect(),
            ));
        }
    }
    let rendered = stack_vertical(parts);
    Ok(if let Some(cross) = cross_size {
        pad_rendered_height(rendered, cross, 0, container_main)
    } else {
        rendered
    })
}

#[allow(clippy::too_many_arguments)]
fn render_flex_column(
    mut lines: Vec<Vec<FlexRuntimeItem<'_>>>,
    main_size: Option<i64>,
    cross_size: Option<i64>,
    main_gap: i64,
    cross_gap: i64,
    justify: FlexAlign,
    align: FlexAlign,
    align_content: FlexAlign,
    single_line: bool,
    context: LayoutContext,
    intrinsic: bool,
) -> Result<Rendered, String> {
    for line in &mut lines {
        flex_size_line(line, main_size, main_gap);
    }
    let crosses = if cross_size.is_some() && single_line {
        vec![cross_size.unwrap_or(0)]
    } else {
        lines
            .iter()
            .map(|line| flex_line_cross(line, FlexAxis::Column, align, context, intrinsic))
            .collect::<Result<Vec<_>, _>>()?
    };
    let cross_layout =
        flex_layout_cross(crosses, cross_size, cross_gap, align_content, single_line);
    let mut parts = vec![(
        Rendered::from_lines(vec![Line::blank(cross_layout.leading)]),
        cross_layout.leading,
    )];
    let line_count = lines.len();
    for (index, (line, line_cross)) in lines
        .iter()
        .zip(cross_layout.crosses.iter().copied())
        .enumerate()
    {
        let rendered = render_flex_column_line(
            line, line_cross, main_size, main_gap, justify, align, context, intrinsic,
        )?;
        parts.push((rendered, line_cross));
        if index + 1 < line_count {
            parts.push((
                Rendered::from_lines(vec![Line::blank(cross_layout.between)]),
                cross_layout.between,
            ));
        }
    }
    let mut rendered = concat_horizontal_sized(parts, 1);
    if let Some(cross) = cross_size {
        rendered = pad_rendered_width(rendered, cross, FlexAlign::FlexStart);
    }
    Ok(rendered)
}

#[allow(clippy::too_many_arguments)]
fn render_flex(
    direction: FlexDirection,
    wrap: FlexWrap,
    justify: FlexAlign,
    align_items: FlexAlign,
    align_content: FlexAlign,
    width: &Size,
    height: &Size,
    row_gap: i64,
    column_gap: i64,
    source_items: &[FlexItem],
    context: LayoutContext,
    intrinsic: bool,
) -> Result<Rendered, String> {
    let axis = flex_axis(direction);
    let width = flex_horizontal_size(width, context);
    let height = flex_vertical_size(height, context);
    let (main_size, cross_size) = match axis {
        FlexAxis::Row => (width, height),
        FlexAxis::Column => (height, width),
    };
    let inline_viewport = flex_inline_viewport(axis, main_size, cross_size);
    let mut indices = (0..source_items.len()).collect::<Vec<_>>();
    indices.sort_by_key(|index| (source_items[*index].order, *index));
    let mut items = indices
        .into_iter()
        .map(|index| measure_flex_item(&source_items[index], axis, inline_viewport, context))
        .collect::<Result<Vec<_>, _>>()?;
    if flex_direction_reversed(direction) {
        items.reverse();
    }
    let (main_gap, cross_gap) = match axis {
        FlexAxis::Row => (column_gap, row_gap),
        FlexAxis::Column => (row_gap, column_gap),
    };
    let mut lines = flex_break_lines(items, main_size, main_gap, wrap);
    if wrap == FlexWrap::WrapReverse {
        lines.reverse();
    }
    let single_line = wrap == FlexWrap::Nowrap;
    match axis {
        FlexAxis::Row => render_flex_row(
            lines,
            main_size,
            cross_size,
            main_gap,
            cross_gap,
            justify,
            align_items,
            align_content,
            single_line,
            context,
            intrinsic,
        ),
        FlexAxis::Column => render_flex_column(
            lines,
            main_size,
            cross_size,
            main_gap,
            cross_gap,
            justify,
            align_items,
            align_content,
            single_line,
            context,
            intrinsic,
        ),
    }
}

#[derive(Debug, Clone, Copy, Default)]
struct BoxOverride {
    content_width: Option<i64>,
    content_height: Option<i64>,
    declared_width: Option<i64>,
}

fn render_node(
    node: &LayoutNode,
    context: LayoutContext,
    intrinsic: bool,
) -> Result<Rendered, String> {
    render_node_with_override(node, context, intrinsic, None)
}

fn render_node_with_override(
    node: &LayoutNode,
    context: LayoutContext,
    intrinsic: bool,
    size_override: Option<BoxOverride>,
) -> Result<Rendered, String> {
    #[cfg(test)]
    TEST_RENDER_NODE_COUNT.with(|count| {
        if let Some(value) = count.get() {
            count.set(Some(value + 1));
        }
    });
    match node {
        LayoutNode::Box {
            region_id,
            content,
            child,
            content_width_exact,
            content_min_width: _,
            width,
            min_width,
            max_width,
            height,
            min_height,
            max_height,
            box_sizing,
            padding_left,
            padding_right,
            padding_top,
            padding_bottom,
            margin_left,
            margin_right,
            margin_top,
            margin_bottom,
            border_left,
            border_right,
            foreground_style,
            background_style,
            border_left_style,
            border_right_style,
            border_top_style,
            border_bottom_style,
            surface_template_id,
            text_align,
            vertical_align: vertical,
            overflow,
            wrap_mode,
            scroll_offset,
        } => {
            let declared_width_override =
                size_override.and_then(|override_size| override_size.declared_width);
            let declared_width_size = declared_width_override.map(|value| Size::Pixels { value });
            let effective_width = declared_width_size.as_ref().unwrap_or(width);
            let side_width = padding_left
                + padding_right
                + margin_left
                + margin_right
                + border_left
                + border_right;
            let stretch = context
                .viewport_width_known
                .then_some((context.viewport_width - side_width).max(0));

            let preliminary_child_width = size_override
                .and_then(|override_size| override_size.content_width)
                .or_else(|| {
                    resolve_child_viewport_width(
                        effective_width,
                        min_width,
                        max_width,
                        context,
                        *box_sizing,
                        *padding_left,
                        *padding_right,
                        *border_left,
                        *border_right,
                        stretch,
                    )
                });
            let preliminary_child_height = size_override
                .and_then(|override_size| override_size.content_height)
                .or_else(|| {
                    resolve_height(
                        height,
                        None,
                        context,
                        *box_sizing,
                        *padding_top,
                        *padding_bottom,
                    )
                });
            let intrinsic_child = matches!(effective_width, Size::MaxContent);
            let definite_content_width = resolve_definite_box_content_width(
                effective_width,
                min_width,
                max_width,
                context,
                *box_sizing,
                *padding_left,
                *padding_right,
                *border_left,
                *border_right,
                stretch,
                size_override.and_then(|override_size| override_size.content_width),
            );
            let definite_content_height = resolve_definite_box_content_height(
                height,
                min_height,
                max_height,
                context,
                *box_sizing,
                *padding_top,
                *padding_bottom,
                size_override.and_then(|override_size| override_size.content_height),
            );
            let window_rendering_disabled = {
                #[cfg(test)]
                {
                    TEST_DISABLE_WINDOW_RENDER.with(Cell::get)
                }
                #[cfg(not(test))]
                {
                    false
                }
            };
            let simple_scroll_window = *overflow == Overflow::Scroll
                && child.is_some()
                && definite_content_width.is_some()
                && definite_content_height.is_some()
                && !intrinsic
                && !intrinsic_child
                && !window_rendering_disabled
                && *padding_left == 0
                && *padding_right == 0
                && *padding_top == 0
                && *padding_bottom == 0
                && *margin_left == 0
                && *margin_right == 0
                && *margin_top == 0
                && *margin_bottom == 0
                && *border_left == 0
                && *border_right == 0
                && border_top_style.is_none()
                && border_bottom_style.is_none()
                && *vertical == VerticalAlign::Top;
            let mut windowed_child_start = None;
            let mut windowed_child_height = None;
            let mut child_rendered = if let Some(child) = child {
                let child_context = LayoutContext {
                    viewport_width: if intrinsic_child {
                        0
                    } else {
                        preliminary_child_width.unwrap_or(context.viewport_width)
                    },
                    viewport_width_known: !intrinsic_child
                        && (preliminary_child_width.is_some() || context.viewport_width_known),
                    viewport_height: preliminary_child_height.unwrap_or(context.viewport_height),
                };
                if simple_scroll_window {
                    if let Some(total_height) = exact_rendered_height(child, child_context) {
                        let content_height = definite_content_height.expect("checked above");
                        let max_offset = (total_height - content_height).max(0);
                        let start = (*scroll_offset).max(0).min(max_offset);
                        windowed_child_start = Some(start);
                        windowed_child_height = Some(total_height);
                        Some(
                            render_node_window(
                                child,
                                child_context,
                                intrinsic || intrinsic_child,
                                start,
                                content_height,
                            )
                            .expect("exact height checked above")?,
                        )
                    } else {
                        Some(render_node(
                            child,
                            child_context,
                            intrinsic || intrinsic_child,
                        )?)
                    }
                } else {
                    Some(render_node(
                        child,
                        child_context,
                        intrinsic || intrinsic_child,
                    )?)
                }
            } else {
                None
            };

            let (min_content, max_content) = if let Some(text) = content {
                (
                    measured_min_width(text, *wrap_mode),
                    measured_max_width(text),
                )
            } else {
                let rendered = child_rendered.as_ref().expect("validated child");
                (rendered.min_content_width(*wrap_mode), rendered.max_width())
            };
            let auto_width = stretch.unwrap_or(max_content);
            let minimum = resolve_width(
                min_width,
                Some(0),
                context,
                *box_sizing,
                *padding_left,
                *padding_right,
                *border_left,
                *border_right,
                stretch,
                min_content,
                max_content,
            )
            .unwrap_or(0);
            let maximum = resolve_width(
                max_width,
                None,
                context,
                *box_sizing,
                *padding_left,
                *padding_right,
                *border_left,
                *border_right,
                stretch,
                min_content,
                max_content,
            )
            .unwrap_or(i64::MAX);
            let preferred = size_override
                .and_then(|override_size| override_size.content_width)
                .unwrap_or_else(|| {
                    resolve_width(
                        effective_width,
                        Some(auto_width),
                        context,
                        *box_sizing,
                        *padding_left,
                        *padding_right,
                        *border_left,
                        *border_right,
                        stretch,
                        min_content,
                        max_content,
                    )
                    .unwrap_or(auto_width)
                });
            let content_width = minimum.max(preferred.max(0).min(maximum));
            let transparent_preformatted = child.is_some()
                && *content_width_exact
                && *wrap_mode == WrapMode::None
                && *text_align == HorizontalAlign::Left
                && *vertical == VerticalAlign::Top
                && matches!(height, Size::Auto)
                && matches!(min_height, Size::Lines { value: 0 })
                && matches!(max_height, Size::None)
                && *overflow == Overflow::Scroll
                && *padding_left == 0
                && *padding_right == 0
                && *padding_top == 0
                && *padding_bottom == 0
                && *margin_left == 0
                && *margin_right == 0
                && *margin_top == 0
                && *margin_bottom == 0
                && *border_left == 0
                && *border_right == 0
                && foreground_style.is_none()
                && background_style.is_none()
                && border_left_style.is_none()
                && border_right_style.is_none()
                && border_top_style.is_none()
                && border_bottom_style.is_none()
                && child_rendered.as_ref().is_some_and(|rendered| {
                    rendered
                        .lines
                        .iter()
                        .all(|line| !line.atoms.is_empty() && line.width == content_width)
                });
            if transparent_preformatted {
                let mut rendered = child_rendered.take().expect("validated child");
                for (index, line) in rendered.lines.iter_mut().enumerate() {
                    line.own_content(*region_id, index as i64);
                    line.apply_property_template(*surface_template_id);
                }
                return Ok(rendered);
            }

            let mut formatted = if let Some(text) = content {
                measured_lines(text, content_width, *wrap_mode)
                    .into_iter()
                    .map(|line| line.padded(content_width, *text_align))
                    .collect::<Vec<_>>()
            } else {
                let rendered = child_rendered.expect("validated child");
                let uniform_width = rendered
                    .lines
                    .iter()
                    .all(|line| line.width == content_width);
                let preserve_exact_width = *content_width_exact && *wrap_mode == WrapMode::None;
                let rendered = if *wrap_mode != WrapMode::None && !uniform_width {
                    wrap_rendered(rendered, content_width, *wrap_mode)
                } else {
                    rendered
                };
                rendered
                    .lines
                    .into_iter()
                    .map(|line| {
                        if preserve_exact_width {
                            line
                        } else {
                            line.padded(content_width, *text_align)
                        }
                    })
                    .collect::<Vec<_>>()
            };
            let text_height = windowed_child_height.unwrap_or(formatted.len() as i64);
            let minimum_height = resolve_height(
                min_height,
                Some(0),
                context,
                *box_sizing,
                *padding_top,
                *padding_bottom,
            )
            .unwrap_or(0);
            let maximum_height = resolve_height(
                max_height,
                None,
                context,
                *box_sizing,
                *padding_top,
                *padding_bottom,
            )
            .unwrap_or(i64::MAX);
            let preferred_height = size_override
                .and_then(|override_size| override_size.content_height)
                .unwrap_or_else(|| {
                    resolve_height(
                        height,
                        None,
                        context,
                        *box_sizing,
                        *padding_top,
                        *padding_bottom,
                    )
                    .unwrap_or(text_height)
                });
            let content_height = minimum_height
                .max(1)
                .max(preferred_height.max(1).min(maximum_height));
            let simple_scroll_rendered = *overflow == Overflow::Scroll
                && text_height >= content_height
                && *padding_left == 0
                && *padding_right == 0
                && *padding_top == 0
                && *padding_bottom == 0
                && *margin_left == 0
                && *margin_right == 0
                && *margin_top == 0
                && *margin_bottom == 0
                && *border_left == 0
                && *border_right == 0
                && border_top_style.is_none()
                && border_bottom_style.is_none()
                && *vertical == VerticalAlign::Top;

            let mut content_index_start = 0_i64;
            let mut overflow_lines = Vec::new();
            if let Some(start) = windowed_child_start {
                content_index_start = start;
            } else if formatted.len() > content_height as usize {
                match overflow {
                    Overflow::Scroll => {
                        let max_offset = formatted.len() - content_height as usize;
                        let start = (*scroll_offset as usize).min(max_offset);
                        if simple_scroll_rendered {
                            content_index_start = start as i64;
                        }
                        formatted = formatted[start..start + content_height as usize].to_vec();
                    }
                    Overflow::Hidden => {
                        formatted.truncate(content_height as usize);
                    }
                    Overflow::Visible => {
                        overflow_lines = formatted.split_off(content_height as usize);
                    }
                }
            }
            for (index, line) in formatted.iter_mut().enumerate() {
                line.own_content(*region_id, content_index_start + index as i64);
            }
            let mut lines =
                vertical_align(formatted, content_height as usize, *vertical, content_width)
                    .into_iter()
                    .map(|line| {
                        if simple_scroll_rendered {
                            line
                        } else {
                            line.collapse_whitespace_content(content_width, *region_id)
                        }
                    })
                    .collect::<Vec<_>>();

            let mut padded =
                Vec::with_capacity(lines.len() + *padding_top as usize + *padding_bottom as usize);
            padded.extend((0..*padding_top).map(|_| {
                Line::blank_with_properties(
                    content_width,
                    region_properties(RegionRole::PaddingTop, *region_id, None),
                )
            }));
            padded.append(&mut lines);
            padded.extend((0..*padding_bottom).map(|_| {
                Line::blank_with_properties(
                    content_width,
                    region_properties(RegionRole::PaddingBottom, *region_id, None),
                )
            }));

            for line in &mut padded {
                line.prepend_space_with_properties(
                    *padding_left,
                    region_properties(RegionRole::PaddingLeft, *region_id, None),
                );
                line.push_space_with_properties(
                    *padding_right,
                    region_properties(RegionRole::PaddingRight, *region_id, None),
                );
                line.apply_style(*foreground_style);
                line.apply_style(*background_style);
                line.prepend_space_with_properties(
                    *border_left,
                    region_properties(RegionRole::BorderLeft, *region_id, *border_left_style),
                );
                line.push_space_with_properties(
                    *border_right,
                    region_properties(RegionRole::BorderRight, *region_id, *border_right_style),
                );
            }
            if border_top_style.is_some() {
                if let Some(first) = padded.first_mut() {
                    first.apply_style(*border_top_style);
                    first.apply_role(RegionRole::BorderTop, *region_id);
                }
            }
            if border_bottom_style.is_some() {
                if let Some(last) = padded.last_mut() {
                    last.apply_style(*border_bottom_style);
                    last.apply_role(RegionRole::BorderBottom, *region_id);
                }
            }
            for line in &mut padded {
                line.apply_property_template(*surface_template_id);
            }
            for line in &mut padded {
                line.prepend_space_with_properties(
                    *margin_left,
                    region_properties(RegionRole::MarginLeft, *region_id, None),
                );
                line.push_space_with_properties(
                    *margin_right,
                    region_properties(RegionRole::MarginRight, *region_id, None),
                );
            }
            let total_width = content_width + side_width;
            let mut output =
                Vec::with_capacity(padded.len() + *margin_top as usize + *margin_bottom as usize);
            output.extend((0..*margin_top).map(|_| {
                Line::blank_with_properties(
                    total_width,
                    region_properties(RegionRole::MarginTop, *region_id, None),
                )
            }));
            output.append(&mut padded);
            output.extend((0..*margin_bottom).map(|_| {
                Line::blank_with_properties(
                    total_width,
                    region_properties(RegionRole::MarginBottom, *region_id, None),
                )
            }));
            let mut rendered = Rendered::from_lines(output);
            if !overflow_lines.is_empty() {
                let left_space = margin_left + border_left + padding_left;
                let right_space = padding_right + border_right + margin_right;
                for line in &mut overflow_lines {
                    line.apply_style(*foreground_style);
                    line.prepend_space(left_space);
                    line.push_space(right_space);
                }
                rendered = stack_vertical(vec![rendered, Rendered::from_lines(overflow_lines)]);
            }
            if *overflow == Overflow::Scroll && text_height > content_height {
                rendered.apply_scroll_window(*region_id);
            }
            Ok(rendered)
        }
        LayoutNode::Row { children } => {
            let rendered = children
                .iter()
                .map(|child| render_node(child, context, intrinsic))
                .collect::<Result<Vec<_>, _>>()?;
            let height = rendered
                .iter()
                .map(|item| item.lines.len())
                .max()
                .unwrap_or(1);
            let mut lines = Vec::with_capacity(height);
            for index in 0..height {
                let mut line = Line::default();
                for item in &rendered {
                    if let Some(child_line) = item.lines.get(index) {
                        line.append(child_line);
                    } else {
                        line.push_space(item.first_width());
                    }
                }
                lines.push(line);
            }
            Ok(Rendered::from_lines(lines))
        }
        LayoutNode::Column { children } => {
            let mut leaves = Vec::new();
            collect_column_leaves(children, &mut leaves);
            let rendered = leaves
                .into_iter()
                .map(|child| render_node(child, context, intrinsic))
                .collect::<Result<Vec<_>, _>>()?;
            let maximum = rendered
                .iter()
                .map(Rendered::first_width)
                .max()
                .unwrap_or(0);
            let target = if intrinsic || !context.viewport_width_known {
                maximum
            } else {
                context.viewport_width.max(0)
            };
            let mut parts = Vec::with_capacity(rendered.len());
            for mut item in rendered {
                let extra = (target - item.first_width()).max(0);
                for line in &mut item.lines {
                    line.push_space(extra);
                }
                if extra > 0 {
                    item.breaks =
                        vec![AtomProperties::default(); item.lines.len().saturating_sub(1)];
                }
                parts.push(item);
            }
            Ok(stack_vertical(parts))
        }
        LayoutNode::Flex {
            direction,
            wrap,
            justify,
            align_items,
            align_content,
            width,
            height,
            row_gap,
            column_gap,
            items,
        } => render_flex(
            *direction,
            *wrap,
            *justify,
            *align_items,
            *align_content,
            width,
            height,
            *row_gap,
            *column_gap,
            items,
            context,
            intrinsic,
        ),
    }
}

fn collect_column_leaves<'a>(children: &'a [LayoutNode], output: &mut Vec<&'a LayoutNode>) {
    for child in children {
        if let LayoutNode::Column { children } = child {
            collect_column_leaves(children, output);
        } else {
            output.push(child);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn counted_layout_tape(
        document: &LayoutDocument,
        context: LayoutContext,
    ) -> (LayoutTape, usize) {
        TEST_RENDER_NODE_COUNT.with(|count| count.set(Some(0)));
        let tape = document.layout_tape(context, None).unwrap();
        let count = TEST_RENDER_NODE_COUNT.with(|count| count.replace(None).unwrap());
        (tape, count)
    }

    fn eager_layout_tape(document: &LayoutDocument, context: LayoutContext) -> LayoutTape {
        TEST_DISABLE_WINDOW_RENDER.with(|disabled| disabled.set(true));
        let tape = document.layout_tape(context, None).unwrap();
        TEST_DISABLE_WINDOW_RENDER.with(|disabled| disabled.set(false));
        tape
    }

    fn document(json: &str) -> LayoutDocument {
        serde_json::from_str(json).unwrap()
    }

    fn cluster(text: &str, width: i64, source_template_id: Option<u32>) -> MeasuredCluster {
        MeasuredCluster {
            text: text.to_owned(),
            width,
            cjk: false,
            space: text == " ",
            pixel_space: false,
            source_template_id,
        }
    }

    fn measured_text(lines: Vec<Vec<MeasuredCluster>>) -> MeasuredText {
        MeasuredText {
            lines: lines
                .into_iter()
                .map(|clusters| MeasuredLine { clusters })
                .collect(),
        }
    }

    fn text_box(
        region_id: i64,
        content: MeasuredText,
        surface_template_id: Option<u32>,
    ) -> LayoutNode {
        LayoutNode::Box {
            region_id,
            content: Some(Box::new(content)),
            child: None,
            content_width_exact: false,
            content_min_width: None,
            width: Size::Content,
            min_width: Size::Pixels { value: 0 },
            max_width: Size::None,
            height: Size::Auto,
            min_height: Size::Lines { value: 0 },
            max_height: Size::None,
            box_sizing: BoxSizing::BorderBox,
            padding_left: 0,
            padding_right: 0,
            padding_top: 0,
            padding_bottom: 0,
            margin_left: 0,
            margin_right: 0,
            margin_top: 0,
            margin_bottom: 0,
            border_left: 0,
            border_right: 0,
            foreground_style: None,
            background_style: None,
            border_left_style: None,
            border_right_style: None,
            border_top_style: None,
            border_bottom_style: None,
            surface_template_id,
            text_align: HorizontalAlign::Left,
            vertical_align: VerticalAlign::Top,
            overflow: Overflow::Scroll,
            wrap_mode: WrapMode::None,
            scroll_offset: 0,
        }
    }

    fn child_box(
        region_id: i64,
        child: LayoutNode,
        surface_template_id: Option<u32>,
    ) -> LayoutNode {
        LayoutNode::Box {
            region_id,
            content: None,
            child: Some(Box::new(child)),
            content_width_exact: true,
            content_min_width: None,
            width: Size::Content,
            min_width: Size::Pixels { value: 0 },
            max_width: Size::None,
            height: Size::Auto,
            min_height: Size::Lines { value: 0 },
            max_height: Size::None,
            box_sizing: BoxSizing::BorderBox,
            padding_left: 0,
            padding_right: 0,
            padding_top: 0,
            padding_bottom: 0,
            margin_left: 0,
            margin_right: 0,
            margin_top: 0,
            margin_bottom: 0,
            border_left: 0,
            border_right: 0,
            foreground_style: None,
            background_style: None,
            border_left_style: None,
            border_right_style: None,
            border_top_style: None,
            border_bottom_style: None,
            surface_template_id,
            text_align: HorizontalAlign::Left,
            vertical_align: VerticalAlign::Top,
            overflow: Overflow::Scroll,
            wrap_mode: WrapMode::None,
            scroll_offset: 0,
        }
    }

    fn fixed_scroll_column_document(scroll_offset: i64) -> LayoutDocument {
        let children = (0..20)
            .map(|index| {
                let mut node = text_box(
                    index + 2,
                    measured_text(vec![vec![cluster(&format!("line-{index:03}"), 8, None)]]),
                    Some((index % 2) as u32),
                );
                let LayoutNode::Box { width, height, .. } = &mut node else {
                    unreachable!();
                };
                *width = Size::Viewport;
                *height = Size::Lines { value: 1 };
                node
            })
            .collect();
        let mut root = child_box(1, LayoutNode::Column { children }, Some(2));
        let LayoutNode::Box {
            width,
            height,
            content_width_exact,
            scroll_offset: offset,
            ..
        } = &mut root
        else {
            unreachable!();
        };
        *width = Size::Viewport;
        *height = Size::Lines { value: 5 };
        *content_width_exact = false;
        *offset = scroll_offset;
        LayoutDocument {
            version: LAYOUT_VERSION,
            space_width: 1,
            style_count: 0,
            property_template_count: 3,
            styles: Vec::new(),
            root,
        }
    }

    fn test_context() -> LayoutContext {
        LayoutContext {
            viewport_width: 80,
            viewport_width_known: true,
            viewport_height: 24,
        }
    }

    fn complete_identity() -> TapeIdentity {
        TapeIdentity {
            session_id: 1,
            generation: 2,
            key: 3,
            runtime_revision: 4,
            context_hash: 5,
            viewport_width: 80,
            viewport_height: 24,
            root_width: 80,
            complete: true,
        }
    }

    fn literal_from_full_tape(tape: &[u8]) -> &str {
        let literal_length = u64::from_le_bytes(tape[112..120].try_into().unwrap()) as usize;
        let line_count = u32::from_le_bytes(tape[120..124].try_into().unwrap()) as usize;
        let literal_start = 152 + line_count * 8;
        std::str::from_utf8(&tape[literal_start..literal_start + literal_length]).unwrap()
    }

    fn metadata_from_full_tape(tape: &[u8]) -> &str {
        let literal_length = u64::from_le_bytes(tape[112..120].try_into().unwrap()) as usize;
        let line_count = u32::from_le_bytes(tape[120..124].try_into().unwrap()) as usize;
        let metadata_length = u32::from_le_bytes(tape[124..128].try_into().unwrap()) as usize;
        let literal_start = 152 + line_count * 8;
        let metadata_start = literal_start + literal_length;
        std::str::from_utf8(&tape[metadata_start..metadata_start + metadata_length]).unwrap()
    }

    #[test]
    fn rejects_invalid_layout_versions_and_negative_geometry() {
        let invalid_version = document(
            r#"{"version":3,"space-width":8,"style-count":0,"root":{"type":"row","children":[{"type":"column","children":[]}]}}"#,
        );
        assert!(invalid_version.validate().is_err());

        let negative = document(
            r#"{"version":2,"space-width":8,"style-count":0,"root":{"type":"box","region-id":1,"content":{"lines":[{"clusters":[{"text":"x","width":8,"cjk":false,"space":false}]}]},"child":null,"content-width-exact":false,"width":{"kind":"pixels","value":-1},"min-width":{"kind":"pixels","value":0},"max-width":{"kind":"none"},"height":{"kind":"auto"},"min-height":{"kind":"lines","value":0},"max-height":{"kind":"none"},"box-sizing":"border-box","padding-left":0,"padding-right":0,"padding-top":0,"padding-bottom":0,"margin-left":0,"margin-right":0,"margin-top":0,"margin-bottom":0,"border-left":0,"border-right":0,"foreground-style":null,"background-style":null,"border-left-style":null,"border-right-style":null,"border-top-style":null,"border-bottom-style":null,"text-align":"left","vertical-align":"top","overflow":"scroll","wrap-mode":"word","scroll-offset":0}}"#,
        );
        assert!(negative.validate().is_err());
        assert!(validate_dimension("width", MAX_LAYOUT_DIMENSION + 1).is_err());
        let mut work_units = MAX_LAYOUT_WORK_UNITS;
        assert!(add_work_units(&mut work_units, 1).is_err());
        let mut context_work = 0;
        assert!(add_context_size_work(
            &Size::ViewportHeight,
            LayoutContext {
                viewport_width: 80,
                viewport_width_known: true,
                viewport_height: MAX_LAYOUT_WORK_UNITS as i64 + 1,
            },
            &mut context_work,
        )
        .is_err());
    }

    #[test]
    fn word_and_character_wrapping_preserve_measured_clusters() {
        let clusters = "alpha beta"
            .chars()
            .map(|character| MeasuredCluster {
                text: character.to_string(),
                width: 1,
                cjk: false,
                space: character == ' ',
                pixel_space: false,
                source_template_id: None,
            })
            .collect::<Vec<_>>();
        let word_lines = wrap_line(&clusters, 5, WrapMode::Word);
        let texts = word_lines
            .iter()
            .map(|line| {
                line.atoms
                    .iter()
                    .map(|atom| match atom {
                        Atom::Text { text, .. } => text.as_str(),
                        Atom::Space { .. } => " ",
                    })
                    .collect::<String>()
            })
            .collect::<Vec<_>>();
        assert_eq!(texts, ["alpha", "beta"]);

        let character_lines = wrap_line(&clusters, 3, WrapMode::Char);
        assert_eq!(character_lines.len(), 4);
        assert!(character_lines.iter().all(|line| line.width <= 3));
    }

    #[test]
    fn source_template_ids_follow_measured_clusters() {
        let root = text_box(
            1,
            measured_text(vec![vec![
                cluster("a", 1, Some(0)),
                cluster("b", 1, None),
                cluster("c", 1, Some(1)),
            ]]),
            None,
        );
        let document = LayoutDocument {
            version: LAYOUT_VERSION,
            space_width: 1,
            style_count: 0,
            property_template_count: 2,
            styles: Vec::new(),
            root,
        };
        document.validate().unwrap();
        let tape = document.layout_tape(test_context(), None).unwrap();
        let flat = flatten_layout_tape(tape, true).unwrap();

        assert_eq!(
            flat.characters
                .iter()
                .map(|character| character.properties.property_template_ids.as_slice())
                .collect::<Vec<_>>(),
            vec![&[0][..], &[][..], &[1][..]]
        );
    }

    #[test]
    fn whitespace_only_source_template_survives_content_collapse() {
        let mut root = text_box(1, measured_text(vec![vec![cluster(" ", 1, Some(0))]]), None);
        let LayoutNode::Box { overflow, .. } = &mut root else {
            unreachable!();
        };
        *overflow = Overflow::Hidden;

        let document = LayoutDocument {
            version: LAYOUT_VERSION,
            space_width: 1,
            style_count: 0,
            property_template_count: 1,
            styles: Vec::new(),
            root,
        };
        document.validate().unwrap();
        let tape = document.layout_tape(test_context(), None).unwrap();
        let flat = flatten_layout_tape(tape, true).unwrap();

        assert_eq!(flat.characters.len(), 1);
        assert_eq!(flat.characters[0].properties.property_template_ids, vec![0]);
    }

    #[test]
    fn surface_template_ids_cover_border_box_but_not_margins_or_newlines() {
        let mut root = text_box(
            1,
            measured_text(vec![
                vec![cluster("x", 1, None)],
                vec![cluster("y", 1, None)],
            ]),
            Some(0),
        );
        let LayoutNode::Box {
            padding_left,
            padding_right,
            padding_top,
            padding_bottom,
            margin_left,
            margin_right,
            margin_top,
            margin_bottom,
            ..
        } = &mut root
        else {
            unreachable!();
        };
        *padding_left = 1;
        *padding_right = 1;
        *padding_top = 1;
        *padding_bottom = 1;
        *margin_left = 1;
        *margin_right = 1;
        *margin_top = 1;
        *margin_bottom = 1;

        let document = LayoutDocument {
            version: LAYOUT_VERSION,
            space_width: 1,
            style_count: 0,
            property_template_count: 1,
            styles: Vec::new(),
            root,
        };
        document.validate().unwrap();
        let tape = document.layout_tape(test_context(), None).unwrap();
        let flat = flatten_layout_tape(tape, true).unwrap();
        let rows = flat
            .characters
            .split(|character| character.value == '\n')
            .collect::<Vec<_>>();

        assert_eq!(rows.len(), 6);
        assert!(rows[0]
            .iter()
            .all(|character| character.properties.property_template_ids.is_empty()));
        assert!(rows[5]
            .iter()
            .all(|character| character.properties.property_template_ids.is_empty()));
        for row in &rows[1..5] {
            assert_eq!(row.len(), 5);
            assert!(row[0].properties.property_template_ids.is_empty());
            assert_eq!(row[1].properties.property_template_ids, vec![0]);
            assert_eq!(row[2].properties.property_template_ids, vec![0]);
            assert_eq!(row[3].properties.property_template_ids, vec![0]);
            assert!(row[4].properties.property_template_ids.is_empty());
        }
        assert!(flat
            .characters
            .iter()
            .filter(|character| character.value == '\n')
            .all(|character| character.properties.property_template_ids.is_empty()));
    }

    #[test]
    fn nested_template_ids_are_ordered_inner_to_outer() {
        let inner = text_box(
            1,
            measured_text(vec![vec![cluster("x", 1, Some(0))]]),
            Some(1),
        );
        let outer = child_box(2, inner, Some(2));
        let document = LayoutDocument {
            version: LAYOUT_VERSION,
            space_width: 1,
            style_count: 0,
            property_template_count: 3,
            styles: Vec::new(),
            root: outer,
        };
        document.validate().unwrap();
        let tape = document.layout_tape(test_context(), None).unwrap();
        let flat = flatten_layout_tape(tape, true).unwrap();

        assert_eq!(flat.characters.len(), 1);
        assert_eq!(
            flat.characters[0].properties.property_template_ids,
            vec![0, 1, 2]
        );
    }

    #[test]
    fn property_template_ids_are_validated_against_the_declared_table() {
        let source = LayoutDocument {
            version: LAYOUT_VERSION,
            space_width: 1,
            style_count: 0,
            property_template_count: 1,
            styles: Vec::new(),
            root: text_box(1, measured_text(vec![vec![cluster("x", 1, Some(1))]]), None),
        };
        assert!(source.validate().is_err());

        let surface = LayoutDocument {
            version: LAYOUT_VERSION,
            space_width: 1,
            style_count: 0,
            property_template_count: 1,
            styles: Vec::new(),
            root: text_box(1, measured_text(vec![vec![cluster("x", 1, None)]]), Some(1)),
        };
        assert!(surface.validate().is_err());

        let oversized_table = LayoutDocument {
            property_template_count: MAX_PROPERTY_TEMPLATE_COUNT + 1,
            ..surface
        };
        assert!(oversized_table.validate().is_err());

        let larger_than_atom_depth = LayoutDocument {
            version: LAYOUT_VERSION,
            space_width: 1,
            style_count: 0,
            property_template_count: MAX_TAPE_PROPERTY_ENTRIES as u32 + 2,
            styles: Vec::new(),
            root: text_box(
                1,
                measured_text(vec![vec![cluster(
                    "x",
                    1,
                    Some(MAX_TAPE_PROPERTY_ENTRIES as u32 + 1),
                )]]),
                Some(MAX_TAPE_PROPERTY_ENTRIES as u32),
            ),
        };
        assert!(larger_than_atom_depth.validate().is_ok());
    }

    #[test]
    fn rendered_min_content_matches_elisp_separators_and_cjk_runs() {
        let clusters = vec![
            MeasuredCluster {
                text: "a".to_owned(),
                width: 2,
                cjk: false,
                space: false,
                pixel_space: false,
                source_template_id: None,
            },
            MeasuredCluster {
                text: "b".to_owned(),
                width: 3,
                cjk: false,
                space: false,
                pixel_space: false,
                source_template_id: None,
            },
            MeasuredCluster {
                text: " ".to_owned(),
                width: 4,
                cjk: false,
                space: true,
                pixel_space: false,
                source_template_id: None,
            },
            MeasuredCluster {
                text: "界".to_owned(),
                width: 9,
                cjk: true,
                space: false,
                pixel_space: false,
                source_template_id: None,
            },
            MeasuredCluster {
                text: " ".to_owned(),
                width: 40,
                cjk: false,
                space: true,
                pixel_space: true,
                source_template_id: None,
            },
            MeasuredCluster {
                text: "c".to_owned(),
                width: 6,
                cjk: false,
                space: false,
                pixel_space: false,
                source_template_id: None,
            },
            MeasuredCluster {
                text: "d".to_owned(),
                width: 7,
                cjk: false,
                space: false,
                pixel_space: false,
                source_template_id: None,
            },
        ];
        let rendered = Rendered::from_lines(vec![Line::from_clusters(&clusters)]);

        assert_eq!(rendered.min_content_width(WrapMode::Word), 13);
        assert_eq!(rendered.min_content_width(WrapMode::Char), 13);
        assert_eq!(rendered.min_content_width(WrapMode::None), 71);
    }

    #[test]
    fn border_box_resolution_subtracts_only_box_chrome() {
        assert_eq!(
            box_sizing_content_width(100, BoxSizing::BorderBox, 8, 7, 2, 3),
            80
        );
        assert_eq!(
            box_sizing_content_width(100, BoxSizing::ContentBox, 8, 7, 2, 3),
            100
        );
        assert_eq!(box_sizing_content_height(9, BoxSizing::BorderBox, 2, 1), 6);
    }

    #[test]
    fn bounded_intrinsic_widths_and_height_expressions_resolve_exactly() {
        let context = LayoutContext {
            viewport_width: 320,
            viewport_width_known: true,
            viewport_height: 10,
        };
        let fit_content = Size::FitContent {
            limit: Some(Box::new(Size::Pixels { value: 180 })),
        };
        assert_eq!(
            resolve_width(
                &fit_content,
                None,
                context,
                BoxSizing::ContentBox,
                0,
                0,
                0,
                0,
                Some(320),
                40,
                300,
            ),
            Some(180)
        );

        let height = Size::Subtract {
            values: Box::new(SizeValues(
                vec![Size::ViewportHeight, Size::Lines { value: 2 }].into_boxed_slice(),
            )),
        };
        assert_eq!(
            resolve_height(&height, None, context, BoxSizing::BorderBox, 1, 1),
            Some(6)
        );

        let empty = Size::Add {
            values: Box::new(SizeValues(Vec::new().into_boxed_slice())),
        };
        assert!(validate_size("height", &empty).is_err());

        let unavailable = LayoutContext {
            viewport_width: 0,
            viewport_width_known: false,
            viewport_height: 0,
        };
        assert_eq!(
            resolve_width(
                &Size::Viewport,
                None,
                unavailable,
                BoxSizing::ContentBox,
                0,
                0,
                0,
                0,
                None,
                40,
                300,
            ),
            None
        );
        assert_eq!(resolve_raw_height(&Size::ViewportHeight, unavailable), None);

        assert_eq!(
            resolve_child_viewport_width(
                &Size::Pixels { value: 300 },
                &Size::Pixels { value: 0 },
                &Size::Viewport,
                LayoutContext {
                    viewport_width: 298,
                    viewport_width_known: true,
                    viewport_height: 20,
                },
                BoxSizing::BorderBox,
                0,
                0,
                0,
                0,
                Some(298),
            ),
            Some(298)
        );
    }

    #[test]
    fn zero_width_remains_a_known_nested_flex_constraint() {
        let known_zero = LayoutContext {
            viewport_width: 0,
            viewport_width_known: true,
            viewport_height: 10,
        };
        let unavailable = LayoutContext {
            viewport_width: 0,
            viewport_width_known: false,
            viewport_height: 10,
        };

        assert_eq!(flex_horizontal_size(&Size::Auto, known_zero), Some(0));
        assert_eq!(flex_horizontal_size(&Size::Viewport, known_zero), Some(0));
        assert_eq!(flex_horizontal_size(&Size::Auto, unavailable), None);
        assert_eq!(flex_horizontal_size(&Size::Viewport, unavailable), None);
    }

    #[test]
    fn flex_integer_distribution_and_spacing_preserve_elisp_rounding() {
        assert_eq!(flex_distribute(7.0, &[1.0, 2.0, 1.0]), [2, 4, 1]);
        assert_eq!(flex_distribute(3.9, &[1.0, 1.0]), [2, 1]);
        assert_eq!(flex_spacing(FlexAlign::SpaceAround, 11, 3, 2), (1, 5, 4));
        assert_eq!(flex_spacing(FlexAlign::SpaceEvenly, 11, 3, 2), (2, 4, 2));
    }

    #[test]
    fn flex_partial_fill_and_min_wins_clamping_match_the_oracle() {
        assert_eq!(flex_effective_free_space(200, 200, 0.5), 100.0);
        assert_eq!(flex_effective_free_space(-50, -50, 0.5), -25.0);
        assert_eq!(flex_clamp_main(40, 80, Some(60)), 80);
        assert_eq!(flex_clamp_main(-5, 0, None), 0);
    }

    #[test]
    fn vertical_stack_and_scroll_preserve_break_metadata() {
        let mut first = Rendered::from_lines(vec![Line::blank(1), Line::blank(1)]);
        first.breaks[0].owner = Some(11);
        let second = Rendered::from_lines(vec![Line::blank(1)]);
        let mut stacked = stack_vertical(vec![first, second]);

        assert_eq!(stacked.breaks.len(), 2);
        assert_eq!(stacked.breaks[0].owner, Some(11));
        assert_eq!(stacked.breaks[1], AtomProperties::default());

        stacked.apply_scroll_window(9);
        assert!(stacked
            .breaks
            .iter()
            .all(|properties| { properties.scroll_window == Some(9) }));
        assert!(stacked.lines.iter().all(|line| {
            line.atoms
                .iter()
                .all(|atom| atom.properties().scroll_window == Some(9))
        }));

        let tape = stacked.into_tape(0);
        assert_eq!(tape.lines[0].break_after.as_ref().unwrap().owner, Some(11));
        assert_eq!(
            tape.lines[1].break_after.as_ref().unwrap().scroll_window,
            Some(9)
        );
        assert!(tape.lines[2].break_after.is_none());
    }

    #[test]
    fn binary_tapes_are_versioned_bounded_and_support_light_frames() {
        let properties = AtomProperties {
            style_ids: vec![2],
            content: Some(11),
            content_idx: Some(0),
            owner: Some(11),
            owners: vec![11],
            roles: vec![RegionRoleEntry {
                role: RegionRole::PaddingLeft,
                region_id: 11,
            }],
            scroll_window: Some(11),
            property_template_ids: vec![4],
        };
        let mut rendered = Rendered::from_lines(vec![
            Line::blank_with_properties(8, properties.clone()),
            Line::blank_with_properties(8, properties.clone()),
        ]);
        rendered.breaks[0] = properties;
        let tape = rendered.into_tape(3);
        let styles = vec![
            StyleTemplate {
                mode: StyleMode::Add,
                face: FaceTemplate {
                    lisp: None,
                    inherit: None,
                    inverse_video: None,
                    foreground: Some("red".to_owned()),
                    background: None,
                    overline: None,
                    underline: None,
                },
            },
            StyleTemplate {
                mode: StyleMode::Add,
                face: FaceTemplate {
                    lisp: None,
                    inherit: None,
                    inverse_video: None,
                    foreground: None,
                    background: Some("blue".to_owned()),
                    overline: None,
                    underline: None,
                },
            },
            StyleTemplate {
                mode: StyleMode::Set,
                face: FaceTemplate {
                    lisp: None,
                    inherit: None,
                    inverse_video: Some(true),
                    foreground: Some("white".to_owned()),
                    background: None,
                    overline: None,
                    underline: None,
                },
            },
        ];
        let identity = TapeIdentity {
            session_id: 7,
            generation: 9,
            key: 13,
            runtime_revision: 17,
            context_hash: -19,
            viewport_width: 320,
            viewport_height: 40,
            root_width: 300,
            complete: true,
        };

        let full = encode_layout_tape(tape.clone(), &styles, identity, true, 4096).unwrap();
        assert_eq!(&full[..4], TAPE_MAGIC);
        assert_eq!(
            u16::from_le_bytes(full[4..6].try_into().unwrap()),
            TAPE_VERSION
        );
        assert_eq!(u16::from_le_bytes(full[6..8].try_into().unwrap()), 3);
        assert_eq!(
            u64::from_le_bytes(full[12..20].try_into().unwrap()) as usize,
            full.len()
        );
        assert_eq!(u64::from_le_bytes(full[20..28].try_into().unwrap()), 7);
        assert_eq!(u32::from_le_bytes(full[84..88].try_into().unwrap()), 3);
        assert_eq!(u32::from_le_bytes(full[88..92].try_into().unwrap()), 2);
        assert_eq!(u64::from_le_bytes(full[92..100].try_into().unwrap()), 3);
        let literal_length = u64::from_le_bytes(full[112..120].try_into().unwrap()) as usize;
        assert_eq!(u32::from_le_bytes(full[120..124].try_into().unwrap()), 2);
        let metadata_length = u32::from_le_bytes(full[124..128].try_into().unwrap()) as usize;
        let metadata_records = u64::from_le_bytes(full[128..136].try_into().unwrap()) as usize;
        let fragment_length = u64::from_le_bytes(full[136..144].try_into().unwrap()) as usize;
        let fragment_records = u64::from_le_bytes(full[144..152].try_into().unwrap()) as usize;
        assert!(metadata_length > 0);
        assert!(metadata_records > 0);
        assert!(fragment_length > 0);
        assert!(fragment_records > 0);
        assert_eq!(u64::from_le_bytes(full[152..160].try_into().unwrap()), 8);
        assert_eq!(u64::from_le_bytes(full[160..168].try_into().unwrap()), 8);
        let literal_start = 168;
        let literal_end = literal_start + literal_length;
        let literal = std::str::from_utf8(&full[literal_start..literal_end]).unwrap();
        assert_eq!(literal.len(), literal_length);
        assert!(literal.starts_with("#(\" \\n \""));
        assert!(literal.contains("face #3=(:inverse-video t :foreground \"white\")"));
        assert!(literal.contains("face #3#"));
        assert!(literal.contains("ebox-content 11"));
        assert!(literal.contains("ebox-native-property-template-ids (4)"));
        assert!(literal.contains("display (space :width (8))"));
        let metadata = &full[literal_end..literal_end + metadata_length];
        assert_eq!(metadata.len(), metadata_length);
        let metadata_literal = metadata_from_full_tape(&full);
        assert!(metadata_literal.starts_with("(:prepared-p t"));
        assert!(metadata_literal.contains("#s(hash-table test equal data"));
        assert!(metadata_literal.contains("(11 content) ((1 . 4))"));
        assert!(metadata_literal.contains("(11 pl) ((1 . 4))"));
        assert!(metadata_literal.contains("data (11 (1 . 4))"));
        assert!(metadata_literal.contains("data (11 ((0 0 . 3)"));
        assert!(metadata_literal.contains(":scroll-window-p t"));
        assert!(metadata_literal.ends_with(":scroll-window-p t)"));

        let full_without_root_metadata =
            encode_layout_tape(tape.clone(), &styles, identity, false, 4096).unwrap();
        assert_eq!(
            u16::from_le_bytes(full_without_root_metadata[6..8].try_into().unwrap()),
            3
        );
        assert!(u32::from_le_bytes(full_without_root_metadata[124..128].try_into().unwrap()) > 0);
        assert_eq!(
            u64::from_le_bytes(full_without_root_metadata[128..136].try_into().unwrap()),
            1
        );
        assert!(u64::from_le_bytes(full_without_root_metadata[136..144].try_into().unwrap()) > 0);
        assert!(u64::from_le_bytes(full_without_root_metadata[144..152].try_into().unwrap()) > 0);
        let full_without_root_metadata_literal =
            literal_from_full_tape(&full_without_root_metadata);
        assert!(full_without_root_metadata_literal.contains("ebox-content 11"));
        assert!(
            full_without_root_metadata_literal.contains("ebox-native-property-template-ids (4)")
        );

        let light = encode_layout_tape(
            tape.clone(),
            &styles,
            TapeIdentity {
                complete: false,
                ..identity
            },
            true,
            4096,
        )
        .unwrap();
        assert_eq!(u16::from_le_bytes(light[6..8].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(light[124..128].try_into().unwrap()), 0);
        assert_eq!(u64::from_le_bytes(light[128..136].try_into().unwrap()), 0);
        assert_eq!(u64::from_le_bytes(light[136..144].try_into().unwrap()), 0);
        assert_eq!(u64::from_le_bytes(light[144..152].try_into().unwrap()), 0);
        assert!(light.len() < full.len());
        assert!(encode_layout_tape(tape, &styles, identity, true, TAPE_HEADER_LEN).is_err());

        let error = encode_error_tape(identity, &"x".repeat(1024), 160);
        assert!(error.len() <= 160);
        assert_eq!(u16::from_le_bytes(error[6..8].try_into().unwrap()), 2);
        assert_eq!(u32::from_le_bytes(error[88..92].try_into().unwrap()), 0);
    }

    #[test]
    fn root_metadata_emits_only_safe_box_extents() {
        let text = "abbc";
        let property_spans = vec![
            TapePropertySpan {
                start: 0,
                end: 1,
                properties: AtomProperties {
                    content: Some(2),
                    owner: Some(2),
                    owners: vec![1, 2],
                    ..AtomProperties::default()
                },
            },
            TapePropertySpan {
                start: 1,
                end: 3,
                properties: AtomProperties {
                    content: Some(3),
                    owner: Some(3),
                    owners: vec![1, 3],
                    ..AtomProperties::default()
                },
            },
            TapePropertySpan {
                start: 3,
                end: 4,
                properties: AtomProperties {
                    content: Some(2),
                    owner: Some(2),
                    owners: vec![1, 2],
                    roles: vec![RegionRoleEntry {
                        role: RegionRole::PaddingRight,
                        region_id: 2,
                    }],
                    ..AtomProperties::default()
                },
            },
        ];

        let records = build_root_metadata_records(text, &property_spans).unwrap();
        assert!(records.iter().any(|record| {
            record.kind == METADATA_BOX_EXTENT
                && record.region_id == 1
                && record.start == 0
                && record.end == 4
        }));
        assert!(records.iter().any(|record| {
            record.kind == METADATA_BOX_EXTENT
                && record.region_id == 3
                && record.start == 1
                && record.end == 3
        }));
        assert!(!records
            .iter()
            .any(|record| record.kind == METADATA_BOX_EXTENT && record.region_id == 2));
        assert!(records
            .iter()
            .any(|record| record.kind == METADATA_ROLE_CONTENT && record.region_id == 2));
    }

    #[test]
    fn root_metadata_literal_preserves_zero_metadata_and_byte_limit() {
        let fragment_only_payload = root_metadata_payload("x", &[], &[], true, true, 4096)
            .unwrap()
            .unwrap();
        assert_eq!(fragment_only_payload.record_count, 0);
        assert_eq!(fragment_only_payload.fragment_count, 1);
        assert!(!fragment_only_payload.fragment_bytes.is_empty());

        let property_spans = vec![TapePropertySpan {
            start: 0,
            end: 1,
            properties: AtomProperties {
                content: Some(42),
                owner: Some(42),
                ..AtomProperties::default()
            },
        }];
        let payload = root_metadata_payload("x", &[], &property_spans, true, true, 4096)
            .unwrap()
            .unwrap();
        assert_eq!(payload.record_count, 4);
        assert_eq!(payload.fragment_count, 1);
        assert!(payload.literal.contains("(42 content) ((1 . 2))"));
        assert!(payload.literal.contains("data (42 (1 . 2))"));
        assert!(payload.literal.contains("data (42 ((0 0 . 1)))"));
        assert!(root_metadata_payload(
            "x",
            &[],
            &property_spans,
            true,
            true,
            payload.literal.len() - 1,
        )
        .is_err());
    }

    #[test]
    fn complete_tape_emits_property_template_ids_and_light_tape_strips_them() {
        let tape = LayoutTape {
            style_count: 0,
            lines: vec![TapeLine {
                width: 1,
                atoms: vec![TapeAtom::Text {
                    text: "x".to_owned(),
                    width: 1,
                    properties: AtomProperties {
                        property_template_ids: vec![2, 4],
                        ..AtomProperties::default()
                    },
                }],
                break_after: None,
            }],
        };
        let identity = complete_identity();

        let full = encode_layout_tape(tape.clone(), &[], identity, true, 4096).unwrap();
        let full_literal = literal_from_full_tape(&full);
        assert!(full_literal.contains("ebox-native-property-template-ids (2 4)"));

        let light = encode_layout_tape(
            tape,
            &[],
            TapeIdentity {
                complete: false,
                ..identity
            },
            true,
            4096,
        )
        .unwrap();
        let light_literal = literal_from_full_tape(&light);
        assert!(!light_literal.contains("ebox-native-property-template-ids"));
        assert!(flatten_layout_tape(
            LayoutTape {
                style_count: 0,
                lines: vec![TapeLine {
                    width: 1,
                    atoms: vec![TapeAtom::Text {
                        text: "x".to_owned(),
                        width: 1,
                        properties: AtomProperties {
                            property_template_ids: vec![2, 4],
                            ..AtomProperties::default()
                        },
                    }],
                    break_after: None,
                }],
            },
            false,
        )
        .unwrap()
        .characters[0]
            .properties
            .property_template_ids
            .is_empty());
    }

    #[test]
    fn repeated_literal_property_plists_are_shared_with_read_circle_labels() {
        let properties = AtomProperties {
            content: Some(42),
            property_template_ids: vec![3, 7],
            ..AtomProperties::default()
        };
        let literal = encode_lisp_literal_inner(
            "abcd",
            &[],
            &[
                TapePropertySpan {
                    start: 0,
                    end: 1,
                    properties: properties.clone(),
                },
                TapePropertySpan {
                    start: 2,
                    end: 3,
                    properties,
                },
            ],
            &[],
            4,
            4096,
            true,
        )
        .unwrap();
        assert_eq!(
            literal,
            "#(\"abcd\" 0 1 #1=(ebox-content 42 ebox-native-property-template-ids (3 7)) 2 3 #1#)"
        );
    }

    #[test]
    fn myers_diff_bounds_pathological_search_memory() {
        let character = |value: char| TapeCharacter {
            value,
            pixel_width: None,
            properties: AtomProperties::default(),
        };
        let old: Vec<TapeCharacter> = (0..30_000).map(|_| character('a')).collect();
        let new: Vec<TapeCharacter> = (0..30_000).map(|_| character('b')).collect();
        let patches = minimal_tape_patches(&old, &new);
        assert_eq!(
            patches,
            vec![TapePatch {
                old_start: 0,
                old_end: 30_000,
                new_start: 0,
                new_end: 30_000,
            }]
        );
    }

    #[test]
    fn myers_diff_trims_common_affixes_before_search() {
        let character = |value: char| TapeCharacter {
            value,
            pixel_width: None,
            properties: AtomProperties::default(),
        };
        let old: Vec<TapeCharacter> = "prefixXsuffix".chars().map(character).collect();
        let new: Vec<TapeCharacter> = "prefixYsuffix".chars().map(character).collect();
        let patches = minimal_tape_patches(&old, &new);
        assert_eq!(
            patches,
            vec![TapePatch {
                old_start: 6,
                old_end: 7,
                new_start: 6,
                new_end: 7,
            }]
        );
    }

    #[test]
    fn fixed_height_scroll_layout_does_not_render_offscreen_column_suffix() {
        let children = (0..200)
            .map(|index| {
                let mut node = text_box(
                    index + 2,
                    measured_text(vec![vec![cluster(&format!("line-{index:03}"), 8, None)]]),
                    None,
                );
                let LayoutNode::Box { width, height, .. } = &mut node else {
                    unreachable!();
                };
                *width = Size::Viewport;
                *height = Size::Lines { value: 1 };
                node
            })
            .collect();
        let mut root = child_box(1, LayoutNode::Column { children }, None);
        let LayoutNode::Box {
            width,
            height,
            content_width_exact,
            ..
        } = &mut root
        else {
            unreachable!();
        };
        *width = Size::Viewport;
        *height = Size::Lines { value: 5 };
        *content_width_exact = false;
        let document = LayoutDocument {
            version: LAYOUT_VERSION,
            space_width: 1,
            style_count: 0,
            property_template_count: 0,
            styles: Vec::new(),
            root,
        };
        document.validate().unwrap();

        let (tape, rendered_nodes) = counted_layout_tape(&document, test_context());

        assert_eq!(tape.lines.len(), 5);
        assert!(
            rendered_nodes <= 8,
            "fixed scroll rendered {rendered_nodes} nodes for five visible lines"
        );
    }

    #[test]
    fn fixed_height_scroll_layout_uses_nonzero_offset_window() {
        let document = fixed_scroll_column_document(7);
        document.validate().unwrap();

        let (tape, rendered_nodes) = counted_layout_tape(&document, test_context());
        let flat = flatten_layout_tape(tape, true).unwrap();
        let text = flat
            .characters
            .iter()
            .map(|character| character.value)
            .collect::<String>();

        assert_eq!(
            text,
            "line-007 \nline-008 \nline-009 \nline-010 \nline-011 "
        );
        assert!(
            rendered_nodes <= 8,
            "fixed scroll rendered {rendered_nodes} nodes for five visible lines"
        );
    }

    #[test]
    fn fixed_height_scroll_window_matches_eager_tape_exactly() {
        let document = fixed_scroll_column_document(13);
        document.validate().unwrap();

        let eager = eager_layout_tape(&document, test_context());
        let (windowed, rendered_nodes) = counted_layout_tape(&document, test_context());

        assert_eq!(windowed, eager);
        assert!(
            rendered_nodes <= 8,
            "fixed scroll rendered {rendered_nodes} nodes for five visible lines"
        );
    }

    #[test]
    fn native_patch_solver_returns_only_disjoint_semantic_changes() {
        let old = LayoutTape {
            style_count: 0,
            lines: vec![TapeLine {
                width: 6,
                atoms: vec![TapeAtom::Text {
                    text: "abcdef".to_owned(),
                    width: 6,
                    properties: AtomProperties::default(),
                }],
                break_after: None,
            }],
        };
        let target = LayoutTape {
            style_count: 0,
            lines: vec![TapeLine {
                width: 13,
                atoms: vec![
                    TapeAtom::Text {
                        text: "abX".to_owned(),
                        width: 3,
                        properties: AtomProperties::default(),
                    },
                    TapeAtom::Text {
                        text: "d".to_owned(),
                        width: 1,
                        properties: AtomProperties::default(),
                    },
                    TapeAtom::Text {
                        text: "e".to_owned(),
                        width: 1,
                        properties: AtomProperties {
                            content: Some(9),
                            ..AtomProperties::default()
                        },
                    },
                    TapeAtom::Text {
                        text: "f".to_owned(),
                        width: 1,
                        properties: AtomProperties::default(),
                    },
                    TapeAtom::Space {
                        width: 7,
                        properties: AtomProperties::default(),
                    },
                ],
                break_after: None,
            }],
        };

        let old = flatten_layout_tape(old, true).unwrap();
        let target = flatten_layout_tape(target, true).unwrap();
        let patches = minimal_tape_patches(&old.characters, &target.characters);

        assert_eq!(
            patches,
            vec![
                TapePatch {
                    old_start: 2,
                    old_end: 3,
                    new_start: 2,
                    new_end: 3,
                },
                TapePatch {
                    old_start: 4,
                    old_end: 5,
                    new_start: 4,
                    new_end: 5,
                },
                TapePatch {
                    old_start: 6,
                    old_end: 6,
                    new_start: 6,
                    new_end: 7,
                },
            ]
        );

        let identity = TapeIdentity {
            session_id: 1,
            generation: 2,
            key: 3,
            runtime_revision: 4,
            context_hash: 5,
            viewport_width: 140,
            viewport_height: 20,
            root_width: 140,
            complete: true,
        };
        let encoded = encode_layout_patch_tape(
            LayoutTape {
                style_count: old.style_count,
                lines: vec![TapeLine {
                    width: 6,
                    atoms: vec![TapeAtom::Text {
                        text: "abcdef".to_owned(),
                        width: 6,
                        properties: AtomProperties::default(),
                    }],
                    break_after: None,
                }],
            },
            LayoutTape {
                style_count: target.style_count,
                lines: vec![TapeLine {
                    width: 13,
                    atoms: vec![
                        TapeAtom::Text {
                            text: "abXd".to_owned(),
                            width: 4,
                            properties: AtomProperties::default(),
                        },
                        TapeAtom::Text {
                            text: "e".to_owned(),
                            width: 1,
                            properties: AtomProperties {
                                content: Some(9),
                                property_template_ids: vec![4],
                                ..AtomProperties::default()
                            },
                        },
                        TapeAtom::Text {
                            text: "f".to_owned(),
                            width: 1,
                            properties: AtomProperties::default(),
                        },
                        TapeAtom::Space {
                            width: 7,
                            properties: AtomProperties::default(),
                        },
                    ],
                    break_after: None,
                }],
            },
            &[],
            identity,
            true,
            4096,
        )
        .unwrap();
        assert_eq!(u16::from_le_bytes(encoded[6..8].try_into().unwrap()), 7);
        assert_eq!(
            u16::from_le_bytes(encoded[4..6].try_into().unwrap()),
            TAPE_VERSION
        );
        assert_eq!(u64::from_le_bytes(encoded[92..100].try_into().unwrap()), 7);
        assert_eq!(u64::from_le_bytes(encoded[112..120].try_into().unwrap()), 6);
        let patch_count = u32::from_le_bytes(encoded[120..124].try_into().unwrap()) as usize;
        assert_eq!(patch_count, 3);
        let reserved = u32::from_le_bytes(encoded[124..128].try_into().unwrap());
        let metadata_records = u64::from_le_bytes(encoded[128..136].try_into().unwrap());
        let payload_length = u64::from_le_bytes(encoded[136..144].try_into().unwrap()) as usize;
        let fragment_length = u64::from_le_bytes(encoded[144..152].try_into().unwrap()) as usize;
        let fragment_records = u64::from_le_bytes(encoded[152..160].try_into().unwrap()) as usize;
        let coordinate_patch_count =
            u32::from_le_bytes(encoded[160..164].try_into().unwrap()) as usize;
        assert!(coordinate_patch_count > 0);
        let payload_start = 168 + (patch_count + coordinate_patch_count) * 32;
        let payload_end = payload_start + payload_length;
        let payload = std::str::from_utf8(&encoded[payload_start..payload_end]).unwrap();
        assert_eq!(reserved, 0);
        assert!(metadata_records > 0);
        assert!(fragment_length > 0);
        assert!(fragment_records > 0);
        assert_eq!(encoded.len(), payload_end + fragment_length);
        assert!(payload.starts_with("[#(\"Xe \""));
        assert!(payload.contains("1 2 (ebox-content 9 ebox-native-property-template-ids (4))"));
        assert!(payload.contains("2 3 (display (space :width (7)))"));
        assert!(payload.contains("(:prepared-p t"));
        assert!(payload.contains("(9 content) ((5 . 6))"));
        assert!(payload.contains("data (9 (5 . 6))"));
        assert!(payload.contains(":scroll-window-p nil"));
        assert!(payload.ends_with(":scroll-window-p nil)]"));
    }

    #[test]
    fn mount_projection_reuse_ignores_fragment_splits_but_not_roles() {
        fn fragment(start: u64, end: u64, region_id: i64) -> FragmentTemplate {
            FragmentTemplate {
                start,
                end,
                line: 0,
                roles: vec![("content", region_id), ("content-owner", region_id)],
                content_owner: Some(region_id),
                content_index: None,
                property_template_ids: Vec::new(),
                style_ids: Vec::new(),
            }
        }
        let old = vec![fragment(0, 2, 7)];
        let target = vec![fragment(0, 1, 7), fragment(1, 2, 7)];
        assert_eq!(
            fragment_region_mount_projection(&old),
            fragment_region_mount_projection(&target)
        );
        let mut styled = target.clone();
        styled[1].style_ids = vec![3, 5];
        assert_eq!(
            fragment_style_delta(&target, &styled),
            Some(vec![(1, vec![3, 5])])
        );
        let changed = vec![fragment(0, 2, 8)];
        assert_ne!(
            fragment_region_mount_projection(&old),
            fragment_region_mount_projection(&changed)
        );
        assert!(fragment_style_delta(&old, &changed).is_none());
    }
}
