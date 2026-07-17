//! A hanging vine chain that anchors on a ceiling and grows downward.
const dw = @import("../../root.zig");
const decorations = @import("../decorations.zig");

pub const feature: decorations.ColumnFeature = .{
    .sprite = .spiralvine,
    .dir = .down,
    // # of rows the chain can reach past the ceiling
    .max_length = 20,
    .anchor_odds = 0.02,
    .grow_odds = 0.7,
};

pub const MAX_LENGTH: u32 = feature.max_length;
