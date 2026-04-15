---
name: code-guardian
description: >
  Use this skill on every coding task in this repository. It defines the
  required workflow before coding, while coding, and after coding, and it
  requires Guardian verification before results are shown to the user.
---

# Code Guardian

## Before Coding

1. Read the relevant source files and the closest tests before proposing a change.
2. Define the smallest change that solves the task. If a wider refactor is required, say why.
3. Decide which tests and Guardian checks will prove the change.
4. Identify every file you expect to modify and verify afterwards.

## While Coding

1. Keep the diff minimal and traceable to the task.
2. Prefer guard clauses, named helpers, and explicit types over deeper nesting.
3. Do not hide uncertainty behind generic types, broad abstractions, or partial verification.
4. If a rule needs to be bent, narrow the scope and document the reason.

## After Coding

1. Run the smallest relevant test set first, then broader checks only if shared behavior moved.
2. Verify every changed file with Guardian before presenting the result.
3. Fix every `error` violation. For every remaining `warn`, either fix it or justify it explicitly.
4. Report what changed, what was verified, and what still carries risk.

## Guardian Verification

- CLI: `./zig-out/bin/gd analyze <file>`
- Batch CLI: `./zig-out/bin/gd batch <file> <file> ...`
- MCP tools from the `guardian` server:
  - `analyze`
  - `analyze_batch`
  - `analyze_folder`

## Engineering Contract

The full contract lives in `skill/SKILL.md`. Use it as the source of truth for:

- nesting and complexity limits
- strict typing rules
- minimal verified changes
- maintainability and naming standards
- TDD expectations
- fail-fast and testability requirements
