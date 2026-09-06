---
name: review
description: Use when asked to review code Leo wrote, found from the last Jujutsu change or from files he names; reports findings and never rewrites them.
---

# Review

Leo wrote this code. The job is to find what is wrong with it, not to replace it.

## Find the diff

Unless the prompt names files/differences:

1. `jj diff --stat` for the working copy. Review that if it is not empty.
2. Otherwise `jj diff -r @- --stat` for the last described change.
3. `jj diff --git -r <rev>` for the patch.

Name the revision you reviewed in the first line of the report.

## Read past the diff

A hunk hides its own bug. Before judging a change, read

- every function it touches, whole, not the 40-line window,
- every caller of a changed function (`grep -rn "fnName" zig`),
- the reference file for that area from the table in `CLAUDE.md`,
- the sibling arms of any enum switch or rule table it edits.

## What to look for, in order

1. Correctness. Name the input that breaks it and what comes out.
2. A broken invariant: route independence, a computable seam, aliasing, the save format, a WASM export. Name the invariant, not the smell.
3. A contract in the wrong place: a precondition asserted where the body computes it instead of where the caller sets it, or one a new caller can now violate.
4. Work bound, in hot, input, render, worldgen, or startup code. Say what scales with what.
5. Comment rot the change created.
6. Simplification, but only where it deletes a real branch or a real piece of state.

## Report

Three lines per finding, at most:

- `path/file.zig:123`, then one sentence on the defect.
- The exact input or sequence that triggers it.
- The smallest fix, in prose. Not a patch.

Rank by severity. Put anything you did not confirm by reading or running on its own line as `Unverified: ...`.

Say plainly when the code is fine. An empty review is a result, and a padded one is worse than none.

## Do not

- Do not edit a file. Do not open a patch. Suggest, and let Leo write it.
- Do not report naming, style, or anything `zig fmt` already decides.
- Do not restate what the code does back to its author.
