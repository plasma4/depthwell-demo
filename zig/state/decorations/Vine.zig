//! The hanging vine (spiral plant): a chain that anchors on a ceiling and grows down until it stops rolling.
//!
//! A COLUMN feature rather than a point decoration, because its length is not fixed.
const dw = @import("../../root.zig");
const decorations = @import("../decorations.zig");

pub const feature: decorations.ColumnFeature = .{
    .sprite = .spiral_plant,
    .dir = .down,
    .max_length = 20,
    .anchor_odds = 0.02,
    .grow_odds = 0.7,
};

/// Rows a chain can reach past its ceiling.
/// `world.computeColumnSeeds()` scans this far up to carry a chain across the chunk border.
pub const MAX_LENGTH: u32 = feature.max_length;
