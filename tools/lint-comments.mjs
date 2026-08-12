#!/usr/bin/env node
// Comment-style linter for Depthwell.
//
// Enforces the "Comment style" section of AGENTS.md mechanically, so the rules
// hold without a human re-reading every diff.
//
//   node tools/lint-comments.mjs           lint files changed in the current jj revision
//   node tools/lint-comments.mjs --all     lint every tracked source file
//   node tools/lint-comments.mjs --strict  fail on warnings too, not only errors
//   node tools/lint-comments.mjs a.zig b.zig   lint an explicit list
//
// Exit code 1 means at least one error. Warnings alone exit 0 unless --strict.

import { execFileSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { readdir } from "node:fs/promises";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "..");
const SOURCE_EXT = new Set([".zig", ".ts", ".wgsl"]);
const SKIP_DIRS = new Set(["node_modules", "dist", "public", ".git", ".jj", ".zig-cache", "zig-out", ".claude"]);

// Words STE replaces with a shorter or plainer one. Value is the suggestion.
// Keep this list conservative: a false positive here trains people to ignore the tool.
const BANNED_WORDS = new Map([
    ["utilize", "use"],
    ["utilizes", "uses"],
    ["leverage", "use"],
    ["leverages", "uses"],
    ["facilitate", "help"],
    ["facilitates", "helps"],
    ["ensure", "make sure"],
    ["ensures", "makes sure"],
    ["prior to", "before"],
    ["subsequent to", "after"],
    ["in order to", "to"],
    ["additionally", "also"],
    ["furthermore", "also"],
    ["moreover", "also"],
    ["seamless", "(drop it)"],
    ["seamlessly", "(drop it)"],
    ["robust", "(say what it survives)"],
    ["powerful", "(drop it)"],
    ["comprehensive", "(drop it)"],
    ["effortless", "(drop it)"],
    ["cutting-edge", "(drop it)"],
    ["it is important to note", "(drop it)"],
    ["it should be noted", "(drop it)"],
    ["note that", "(drop it)"],
    ["essentially", "(drop it)"],
    ["basically", "(drop it)"],
]);

const CONTRACTIONS =
    /\b(?:don't|doesn't|didn't|isn't|aren't|wasn't|weren't|can't|won't|shouldn't|couldn't|wouldn't|it's|that's|there's|we're|we've|you're|you'll|let's|hasn't|haven't)\b/gi;

const MAX_SENTENCE_WORDS = 25;

function report(list, file, line, col, level, rule, message, endLine = line) {
    list.push({ file, line, col, level, rule, message, endLine });
}

/**
 * Splits one source line into code and comment.
 * Returns null when the line has no comment.
 * Understands Zig and TypeScript string literals, char literals, and Zig
 * multiline strings, so a "//" inside a string is not treated as a comment.
 */
function splitComment(rawLine) {
    const trimmed = rawLine.trimStart();
    // A Zig multiline string literal line is entirely a string.
    if (trimmed.startsWith("\\\\")) return null;

    let quote = null;
    for (let i = 0; i < rawLine.length; i++) {
        const c = rawLine[i];
        if (quote) {
            if (c === "\\") i++;
            else if (c === quote) quote = null;
            continue;
        }
        if (c === '"' || c === "'" || c === "`") {
            quote = c;
            continue;
        }
        if (c === "/" && rawLine[i + 1] === "/") {
            return { index: i, text: rawLine.slice(i) };
        }
    }
    return null;
}

/** Classifies a comment as a doc comment (`///`, `//!`) or a normal one (`//`). */
function commentKind(text) {
    if (text.startsWith("//!")) return "doc";
    if (text.startsWith("///")) return "doc";
    return "normal";
}

/** Strips the leading slashes so the remainder is prose. */
function commentBody(text) {
    return text.replace(/^\/\/[/!]?/, "");
}

/** Returns the character ranges covered by `backtick spans` in a string. */
function backtickRanges(body) {
    const ranges = [];
    const re = /`[^`]*`/g;
    let m;
    while ((m = re.exec(body)) !== null) ranges.push([m.index, m.index + m[0].length]);
    return ranges;
}

function inRanges(ranges, index) {
    return ranges.some(([a, b]) => index >= a && index < b);
}

/** Collects every `fn name(` in the Zig sources, so the linter knows real identifiers. */
async function collectFunctionNames(files) {
    const names = new Set();
    for (const file of files) {
        if (path.extname(file) !== ".zig") continue;
        const text = readFileSync(file, "utf8");
        for (const m of text.matchAll(/\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/g)) names.add(m[1]);
    }
    // Only camelCase names are safe to match in prose. A lowercase name like
    // "move" or "hash" collides with ordinary English and produces noise.
    return new Set([...names].filter((n) => /[a-z]/.test(n[0]) && /[A-Z]/.test(n)));
}

function countWords(s) {
    return s.split(/\s+/).filter(Boolean).length;
}

/** True for vendored code. Upstream prose is not ours to restyle. */
function isVendored(text) {
    const head = text.split("\n", 20).join("\n");
    return /The MIT License|Copyright \(c\)|Original `std\./.test(head);
}

/** True when a doc line carries a code example, where prose rules do not apply. */
function looksLikeCode(body) {
    return /;\s*$|=>|\.\{|\(@|^\s{4,}\S/.test(body);
}

/** True for a list item, which is measured on its own rather than joined to prose. */
function isListItem(body) {
    return /^\s*(?:[-*+]\s|\d+[.)]\s)/.test(body);
}

function lintFile(file, fnNames, out) {
    // Keep paths repo-relative so they stay clickable. A file outside the repo
    // keeps its absolute path instead of a "../../.." chain.
    const relative = path.relative(ROOT, file);
    const rel = relative.startsWith("..") ? file : relative;
    let text;
    try {
        text = readFileSync(file, "utf8");
    } catch {
        return;
    }
    if (isVendored(text)) return;
    const lines = text.split("\n");
    const isZig = path.extname(file) === ".zig";

    // A doc-comment block is a run of consecutive `///` or `//!` lines. Sentence
    // length is measured over the joined block, because one sentence often wraps
    // across lines. A list item, a blank doc line, and a code example each end a
    // run, so unterminated bullets do not concatenate into one fake sentence.
    let block = null;
    const flushBlock = () => {
        if (!block) return;
        const joined = block.parts.join(" ").trim();
        if (joined) {
            for (const sentence of joined.split(/(?<=[.!?])\s+/)) {
                const words = countWords(sentence);
                if (words > MAX_SENTENCE_WORDS) {
                    report(out, rel, block.startLine, 1, "warn", "long-sentence", `${words} words in one sentence (max ${MAX_SENTENCE_WORDS}); split it`, block.endLine);
                }
            }
        }
        block = null;
    };

    lines.forEach((rawLine, i) => {
        const lineNo = i + 1;
        const split = splitComment(rawLine);
        if (!split) {
            flushBlock();
            return;
        }
        const { index, text: comment } = split;
        const kind = commentKind(comment);
        const body = commentBody(comment);
        const bodyOffset = index + comment.length - body.length;
        const ticks = backtickRanges(body);

        const codeLine = looksLikeCode(body);
        if (kind === "doc") {
            if (isListItem(body) || codeLine || body.trim() === "") {
                flushBlock();
            } else {
                if (!block) block = { startLine: lineNo, parts: [], endLine: lineNo };
                block.parts.push(body.trim());
                block.endLine = lineNo;
            }
        } else {
            flushBlock();
        }

        // R1: normal `//` comments never use backticks. Zig only; the rule in
        // AGENTS.md is written for Zig comment kinds.
        if (kind === "normal" && isZig) {
            const tick = body.indexOf("`");
            if (tick !== -1) {
                report(out, rel, lineNo, bodyOffset + tick + 1, "error", "no-backticks-in-line-comment", "`//` comments never use backticks (AGENTS.md, Comment style)");
            }
        }

        // R2: a function name inside backticks needs parens: `myFn()`.
        if (isZig && kind === "doc" && !codeLine) {
            for (const [a, b] of ticks) {
                const span = body.slice(a + 1, b - 1);
                if (fnNames.has(span)) {
                    report(out, rel, lineNo, bodyOffset + a + 1, "error", "fn-needs-parens", `\`${span}\` is a function; write \`${span}()\``);
                }
            }
        }

        // R3: a known function name in doc prose needs backticks.
        if (isZig && kind === "doc" && !codeLine) {
            for (const m of body.matchAll(/\b([a-z][A-Za-z0-9_]*[A-Z][A-Za-z0-9_]*)\b/g)) {
                if (!fnNames.has(m[1])) continue;
                if (inRanges(ticks, m.index)) continue;
                report(out, rel, lineNo, bodyOffset + m.index + 1, "warn", "identifier-needs-backticks", `\`${m[1]}()\` should be in backticks`);
            }
        }

        // R4: banned words, in every comment kind.
        const lower = body.toLowerCase();
        for (const [word, better] of BANNED_WORDS) {
            const re = new RegExp(`(?<![A-Za-z])${word.replace(/[-]/g, "\\-")}(?![A-Za-z])`, "g");
            let m;
            while ((m = re.exec(lower)) !== null) {
                if (inRanges(ticks, m.index)) continue;
                report(out, rel, lineNo, bodyOffset + m.index + 1, "error", "banned-word", `"${word}" -> ${better}`);
            }
        }

        // R5: no contractions in doc comments. STE writes them out.
        if (kind === "doc") {
            let m;
            CONTRACTIONS.lastIndex = 0;
            while ((m = CONTRACTIONS.exec(body)) !== null) {
                if (inRanges(ticks, m.index)) continue;
                report(out, rel, lineNo, bodyOffset + m.index + 1, "warn", "contraction", `"${m[0]}" — write it out`);
            }
        }

        // R6: one idea per line. Two full sentences on one `///` line should wrap.
        if (kind === "doc" && !codeLine && /[.!?]\s+[A-Z]/.test(body) && countWords(body) > 12) {
            report(out, rel, lineNo, bodyOffset + 1, "warn", "two-sentences-one-line", "two sentences on one doc line; break at the sentence");
        }
    });
    flushBlock();
}

async function walk(dir, acc) {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
        if (entry.name.startsWith(".") && entry.name !== ".") {
            if (SKIP_DIRS.has(entry.name)) continue;
        }
        if (SKIP_DIRS.has(entry.name)) continue;
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) await walk(full, acc);
        else if (SOURCE_EXT.has(path.extname(entry.name))) acc.push(full);
    }
    return acc;
}

/**
 * Reads the current jj revision as a unified diff and returns, per file, the set
 * of line numbers that this revision added or changed.
 *
 * The linter reports only findings that touch those lines. Without this, a
 * three-line edit to `world.zig` would print every legacy finding in a 4967-line
 * file, and everyone would learn to ignore the tool.
 */
function changedLines(revision) {
    let diff;
    try {
        diff = execFileSync("jj", ["diff", "--git", "-r", revision], { cwd: ROOT, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
    } catch {
        return null;
    }
    const perFile = new Map();
    let current = null;
    let newLine = 0;
    for (const line of diff.split("\n")) {
        const fileMatch = /^\+\+\+ b\/(.+)$/.exec(line);
        if (fileMatch) {
            current = fileMatch[1];
            if (!perFile.has(current)) perFile.set(current, new Set());
            continue;
        }
        const hunk = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(line);
        if (hunk) {
            newLine = Number(hunk[1]);
            continue;
        }
        if (!current) continue;
        if (line.startsWith("+")) {
            perFile.get(current).add(newLine);
            newLine++;
        } else if (line.startsWith("-")) {
            // A deletion leaves no new line, but the surrounding prose may now be
            // wrong, so mark the line that closed the gap.
            perFile.get(current).add(newLine);
        } else if (line.startsWith(" ")) {
            newLine++;
        }
    }
    return perFile;
}

async function main() {
    const argv = process.argv.slice(2);
    const strict = argv.includes("--strict");
    const all = argv.includes("--all");
    const revArg = argv.find((a) => a.startsWith("--rev="));
    const revision = revArg ? revArg.slice("--rev=".length) : "@";
    const explicit = argv.filter((a) => !a.startsWith("--"));

    const every = await walk(ROOT, []);
    let targets;
    let scope = null;

    if (explicit.length > 0) {
        targets = explicit.map((f) => path.resolve(ROOT, f));
    } else if (all) {
        targets = every;
    } else {
        scope = changedLines(revision);
        if (scope === null) {
            console.error("lint-comments: jj unavailable, linting everything instead.");
            targets = every;
        } else {
            targets = [...scope.keys()].filter((f) => SOURCE_EXT.has(path.extname(f))).map((f) => path.join(ROOT, f));
            targets = targets.filter((f) => {
                try {
                    return statSync(f).isFile();
                } catch {
                    return false;
                }
            });
        }
    }

    if (targets.length === 0) {
        console.log(`lint-comments: no source changes in revision ${revision}.`);
        return 0;
    }

    // Function names come from the whole tree, not only the linted subset.
    const fnNames = await collectFunctionNames(every);

    let findings = [];
    for (const f of targets) lintFile(f, fnNames, findings);

    // Keep only findings that overlap a line this revision touched.
    let suppressed = 0;
    if (scope) {
        const before = findings.length;
        findings = findings.filter((f) => {
            const touched = scope.get(f.file);
            if (!touched) return false;
            for (let l = f.line; l <= f.endLine; l++) if (touched.has(l)) return true;
            return false;
        });
        suppressed = before - findings.length;
    }

    findings.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line || a.col - b.col);
    for (const f of findings) {
        const tag = f.level === "error" ? "error" : "warn ";
        console.log(`${f.file}:${f.line}:${f.col}  ${tag}  [${f.rule}] ${f.message}`);
    }

    const errors = findings.filter((f) => f.level === "error").length;
    const warns = findings.length - errors;
    const tail = suppressed > 0 ? `, ${suppressed} pre-existing finding(s) outside this change` : "";
    console.log(`\nlint-comments: ${targets.length} file(s), ${errors} error(s), ${warns} warning(s)${tail}.`);
    if (errors > 0) return 1;
    if (strict && warns > 0) return 1;
    return 0;
}

process.exit(await main());
