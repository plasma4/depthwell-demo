//! Scratch file for a policy test. Delete after use.

const std = @import("std");

pub fn existing(a: u32) u32 {
    return a *% 2654435761;
}
