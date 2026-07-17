//! Hanging vine chains: each anchors on a ceiling and grows downward.
//! Every entry is an independent `ColumnFeature`; add another by appending to `features`.
//! Distinct `salt` values keep two vines from sharing a hash stream and stamping in lockstep.
const decorations = @import("../decorations.zig");

pub const features = [_]decorations.ColumnFeature{
    .{
        .sprite = .spiralvine,
        .dir = .down,
        // # of rows the chain can reach past the ceiling
        .max_length = 20,
        .anchor_odds = 0.02,
        .grow_odds = 0.7,
        .anchor_seed = .vine1,
        .grow_seed = .vine2,
    },
    .{
        .sprite = .twinklemoss,
        .dir = .down,
        .max_length = 24,
        .anchor_odds = 0.01,
        .grow_odds = 0.8,
        .anchor_seed = .vine3,
        .grow_seed = .vine4,
    },
};
