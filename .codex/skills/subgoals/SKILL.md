---
name: subgoals
description: Break one named task into the fewest ordered subgoals and write them under it in NEXT.md. Use when asked to unpack, split, or scope a task.
---

# Actionable subgoals

Turn one named task into the fewest subgoals that finish it. Do not implement any of them.

## Read first

- `DESIGN.md` for the settled facts, the current slice, and what is already checked off.
- `NEXT.md` for the task itself and what sits around it.
- The files the task touches. A subgoal that names no file is a guess.

## Write

If no task is specified, nest the subgoals under the first task in `NEXT.md`, one bullet each. Every bullet says:

- the domain, meaning the file or system that changes, and
- the requirement, meaning what is true once it is done.

Order them so each one is playable or testable alone on the day it lands.

If a task is specified, write these subgoals in your response instead.

No more than seven bullets. If it needs more, it is two tasks; say that instead of writing ten.

## Rules

- Check `DESIGN.md` before writing a subgoal for something already checked off.
- Placeholder art and placeholder numbers are allowed, so they are never subgoals.
- No subgoal for art, audio, or tuning unless a mechanic is blocked without it.
- No estimates, no phases, no "then polish".
- A subgoal that only refactors needs its gameplay reason on the same line, or it is cut.
- Plain sentences. No bold labels, no restating the task in its own children.

## Rough shape

```
- Implement X.
    - <Verb> <thing> in `path/file.zig`, so <requirement>.
```

Then stop, and say which parts you are least sure of. Never line wrap until a bullet point is complete based on the character count: finish the entire bullet point in one single coherent line.
