---
name: guardian
description: Apply the Code Guardian workflow before coding and verify every changed file after coding.
---

Use this command on any task that writes, edits, debugs, reviews, or refactors code.

## Before Coding

- Read the relevant files and tests first.
- Define the smallest change set that solves the task.
- Decide which tests prove the behavior before you touch the implementation.
- Note every file that must be verified after coding.

## While Coding

- Keep the diff minimal and directly tied to the task.
- Prefer guard clauses, small helpers, and explicit types over clever control flow.
- Avoid drive-by refactors unless they are required to make the requested change safe.

## After Coding

- Run the smallest relevant test set first, then broader project checks if shared behavior moved.
- Verify every changed file with Guardian:
  - CLI: `gd analyze <file>`
  - MCP: call `analyze` or `analyze_batch`
- Fix every `error` violation worth fixing before presenting the result.
- For any remaining `warn`, either fix it or explain why it is intentional and bounded.

## Contract

Use the full engineering contract in `SKILL.md` (alongside this file) as the source of truth.
