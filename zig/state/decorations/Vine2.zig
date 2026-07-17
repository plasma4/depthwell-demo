//! A hanging vine chain that anchors on a ceiling and grows downward.
const dw = @import("../../root.zig");
const decorations = @import("../decorations.zig");

pub const feature: decorations.ColumnFeature = .{
    .sprite = .twinklemoss,
    .dir = .down,
    // # of rows the chain can reach past the ceiling
    .max_length = 24,
    .anchor_odds = 0.01,
    .grow_odds = 0.8,
};

pub const MAX_LENGTH: u32 = feature.max_length;
