# Guardian

Use the local `gd` CLI on every code-writing, editing, review, debugging, and refactor task in this repository.

## Before Coding

- Read the relevant files and nearest tests first.
- Keep the planned change set minimal and directly tied to the task.
- Decide which tests and Guardian checks prove the change.

## While Coding

- Prefer explicit types, guard clauses, and small helpers.
- Avoid drive-by refactors unless they are required for safety or correctness.
- Treat any rule violation as a decision that needs justification, not as noise to ignore.

## After Coding

- Run the narrowest relevant tests first.
- Verify every changed source file with Guardian.
- Fix every `error` result before presenting work.
- For any remaining `warn`, either fix it or explain why it is intentional and bounded.

## Verification

- CLI: `./zig-out/bin/gd analyze <file>`
- Batch CLI: `./zig-out/bin/gd batch <file> <file> ...`
- No MCP, plugin, or skill integration is part of this project; use only `gd` or the installed C ABI.
