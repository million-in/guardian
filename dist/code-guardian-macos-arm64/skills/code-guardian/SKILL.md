--
name: code-guardian
description: >
Enforces strict engineering discipline on all code generation and modification.
Trigger this skill on EVERY code-related task: writing new code, editing existing code,
reviewing code, generating tests, refactoring, debugging, or any task that touches
.go, .ts, .py, or .zig files. This skill defines hard constraints the agent MUST
follow before presenting any code to the user. If you are about to write or change
code, READ THIS SKILL FIRST. No exceptions.

---

# Code Guardian — Engineering Contract

## Workflow

### Before Coding

1. Read the relevant source files and the closest tests before proposing a change.
2. Define the smallest change that solves the task. If the fix requires a wider refactor, state why.
3. Decide which tests prove the behavior. Prefer red-green first when practical.
4. Identify every file you expect to modify and every file you must verify afterwards.

### While Coding

1. Keep the diff minimal and traceable to the task.
2. Prefer early returns, named helpers, and explicit types over deeper nesting.
3. Do not hide uncertainty with broad abstractions, generic types, or partial verification.
4. If a warning or rule needs to be violated, narrow the scope and document the reason.

### After Coding

1. Run the narrowest relevant test set, then any broader shared checks the change now depends on.
2. Verify every changed file with Guardian before presenting the result.
3. Fix every `error` violation. For every remaining `warn`, either fix it or justify it explicitly.
4. Report what you changed, what you verified, and what still carries risk.

You are building software for a resource-constrained startup on bare-metal Hetzner
infrastructure. Every line you write will be maintained by a solo engineer for 5+ years.
Act accordingly.

## Hard Constraints (violations = rejection)

### 1. Nesting: Max 3 Levels

No function body shall exceed 3 levels of nesting. Level 0 is the function body itself.

```
func Process(items []Item) error {       // level 0
    for _, item := range items {          // level 1
        if item.Valid() {                 // level 2
            handle(item)                  // level 3 — MAXIMUM
        }
    }
}
```

**Violations**: Any `if` inside an `if` inside a `for` inside another `if`. Early return,
guard clauses, and extraction into named functions are your tools.

**Fix pattern**: Invert conditions → early return → extract helper.

### 2. Cyclomatic Complexity: Max 8 Per Function

Count: 1 (base) + each `if`, `else if`, `elif`, `case`, `for`, `while`, `&&`, `||`,
`catch`, `except`, `orelse`, ternary `?`.

Target: 4-6 for normal functions. 8 is the hard ceiling and must be justified.

**Fix pattern**: Extract branches into named predicates. Replace switch/match with
dispatch tables or maps.

### 3. Strict Types Only

| Language   | Banned                                                                             | Required                                                                          |
| ---------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Go         | `interface{}`, `any` (unless generic constraint), type assertions without comma-ok | Concrete types, typed errors                                                      |
| TypeScript | `any`, `as any`, `@ts-ignore`, `@ts-expect-error` (unless documented)              | Strict mode, explicit return types on exported functions                          |
| Python     | Bare `dict`, `list` without type params, missing annotations on public functions   | `from __future__ import annotations`, full type hints, `TypedDict` over raw dicts |
| Zig        | Gratuitous `anytype` (>1 per function signature), `@intCast` without bounds check  | Concrete types, proper error sets                                                 |

### 4. Minimal Verified Changes

When modifying existing code:

- Touch ONLY the lines that fix the issue or implement the feature.
- No drive-by refactors. No reformatting unrelated code.
- If you see something broken elsewhere, report it — don't fix it in the same change.
- Every changed line must have a reason traceable to the task.

### 5. First Principles Thinking

Before writing any module, answer:

- Can this module be replaced without breaking its callers? If no, you have coupling.
- Does this module do exactly one thing? If you need "and" to describe it, split it.
- Would this design survive the hardware failing mid-operation? If no, add recovery.

### 6. SOLID / KISS / DRY / Fail Fast

- **S**: One struct/class = one reason to change.
- **O**: Extend via composition, not modification.
- **L**: Subtypes must honor parent contracts.
- **I**: No interface with >5 methods. Split it.
- **D**: Depend on abstractions. Inject dependencies.
- **KISS**: If a junior can't read it in 30 seconds, simplify.
- **DRY**: Duplicated logic = extract. Duplicated data = single source of truth.
- **Fail fast**: Validate inputs at boundaries. Return errors immediately. No silent swallowing.

### 7. Maintainability Over Cleverness

- No single-letter variables outside loop counters (`i`, `j`, `k`).
- Function names are verb-noun: `ParseConfig`, `ValidateToken`, `SendResponse`.
- Struct/type names are nouns: `TokenCache`, `ConnectionPool`, `RouteEntry`.
- Comments explain WHY, never WHAT. If you need a WHAT comment, the code is unclear.

### 8. Single Responsibility — No Dead Code

- Every exported function, type, constant must be used.
- No commented-out code. Delete it; git remembers.
- No "just in case" abstractions. Build what you need today.
- If a function exceeds 40 lines, it probably does too much.

### 9. Public Over Private — Testability First

- Default to public/exported functions.
- Private functions are acceptable ONLY when they are pure implementation details
  that would pollute the package API.
- Every public function must be testable in isolation.
- No global mutable state. Pass dependencies explicitly.

### 10. TDD — Tests First, Always

**Order of operations:**

1. Write the test that describes the expected behavior.
2. Run it. Watch it fail (red).
3. Write the minimum code to pass (green).
4. Refactor under green tests.

**Test requirements:**

- Table-driven tests (Go), parameterized tests (Python/pytest), test.each (TS).
- Test the contract, not the implementation.
- No mocking unless crossing a system boundary (network, disk, clock).
- Test files live next to source: `foo.go` → `foo_test.go`.

## Performance Constraints

All code must be written with these priorities:

1. **Low latency**: Minimize allocations. Prefer stack over heap. Preallocate buffers.
2. **Concurrency**: Design for concurrent access from day one. No shared mutable state
   without explicit synchronization.
3. **High throughput**: Batch where possible. Avoid per-item syscalls.
4. **Cost efficiency**: No unnecessary dependencies. No runtime reflection in hot paths.

## Pre-Submission Checklist

Before presenting ANY code change, verify:

- [ ] No function exceeds 3 levels of nesting
- [ ] No function exceeds cyclomatic complexity of 8
- [ ] No banned type patterns present
- [ ] All public functions have tests
- [ ] All types are strict and explicit
- [ ] No dead code, unused imports, or commented-out blocks
- [ ] Error paths return meaningful errors, never nil/None/undefined
- [ ] Concurrent access patterns are explicitly handled
- [ ] The change is minimal and traceable to the task

## MCP Verification

After generating code, call the `code-guardian` MCP server's `analyze` tool with
each modified file. If ANY violation is returned at severity `error`, fix it before
presenting to the user. Violations at severity `warn` must be acknowledged with
justification.

Tool: `analyze`
Input: `{ "file_path": "<path>", "source": "<file contents>" }`
Output: List of violations with location, severity, rule, and message.

If the CLI is available, the equivalent verification path is:

- `gd analyze <file>` for one changed file
- `gd batch <file> <file> ...` for multiple changed files

`error` results block submission. `warn` results require a conscious decision: fix them
or explain why the warning is acceptable for this exact change.

## Language-Specific Notes

### Go

- `errcheck` every returned error. No `_ = doThing()`.
- Use `context.Context` for cancellation propagation.
- Prefer `sync.Pool` for high-frequency allocations.

### TypeScript

- `strict: true` in tsconfig. Non-negotiable.
- Prefer `readonly` on all fields unless mutation is required.
- Use discriminated unions over type assertions.

### Python

- `from __future__ import annotations` in every file.
- Use `@dataclass(frozen=True)` over raw classes where possible.
- `typing.Protocol` over ABC for structural typing.

### Zig

- Explicit allocators. Never use `std.heap.page_allocator` in production hot paths.
- `errdefer` on every resource acquisition.
- Prefer `comptime` validation over runtime checks.
