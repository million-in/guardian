# DELTA.md

## Conventions

- Keep Guardian dependency-light Zig 0.16 code; prefer explicit small helpers over broad parser rewrites.
- Add language support by extending `types.Language`, config schema/defaults, source masking, targeted analyzers, symbol model, samples, and tests together.
- Preserve line/column stability when masking comments and strings.
- Keep release/package contents aligned with supported surfaces: `gd`, C ABI library, header, config, docs, license.

## Build and test

- Format: `zig build fmt`
- Unit tests: `zig build test --summary all`
- Build/install artifacts: `zig build`
- CLI/release e2e: `zig build e2e`
- Full suite: `zig build ci`
- Spot-check Rust: `./zig-out/bin/gd analyze samples/rs_bad.rs --raw-json | jq .`
- Guardian check changed source files with `./zig-out/bin/gd analyze <file>` or `batch` after building.

## Guardrails

- Do not reintroduce MCP, JSON-RPC server mode, assistant plugins, or skills without explicit owner approval.
- Do not set git identity manually.
- Do not edit generated/cache/release archive outputs unless the task explicitly asks for packaging artifacts.
