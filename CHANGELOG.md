# Changelog

All notable changes to Guardian are documented here. Versions follow [Semantic Versioning](https://semver.org/); while Guardian is pre-1.0, breaking changes bump the minor version.

## v0.4.1

### Fixed

- Folder/audit scans now always skip hidden directories (`.cache`, `.venv*`, `.git`, ...) and `__pycache__`/`node_modules`/`venv`/`dist`/`build`/`target`/`vendor`, even when the target workspace has no Guardian config listing them. Previously the default ignored only `.git`, so `guardian_audit`/`guardian_folder` via MCP scanned virtualenvs and caches, produced a >16 MiB stdio line, and the client closed the MCP connection for all later calls ([issue #3](https://github.com/million-in/guardian/issues/3)).
- MCP tool calls whose result would exceed 4 MiB now fail that single call with a recoverable error instead of emitting an oversized line that kills the connection.

## v0.4.0

### Added

- `gd mcp` — MCP server over stdio (newline-delimited JSON-RPC 2.0, protocol `2025-03-26`) exposing `guardian_analyze`, `guardian_analyze_source`, `guardian_batch`, `guardian_folder`, and `guardian_audit`. Register with Muse: `muse mcp add guardian -- gd mcp`. The MCP audit tool is static-only and never runs proof commands.
- Wiki documentation: MCP guide for Muse.

## v0.3.0

Rust rule expansion and hard bans ([PR #2](https://github.com/million-in/guardian/pull/2)).

### Breaking changes

- Config rename: `rust.warn_unsafe` → `rust.ban_unsafe`, `rust.warn_todo` → `rust.ban_dangerous_macros`. The loader rejects unknown fields, so configs using the old keys fail with `error.UnknownField` until renamed. New and renamed fields default to `true`, so omitting them enables the checks.
- `unsafe`, the dangerous macros, and clone are now reported at **error** severity (previously warnings, where they existed). Code that previously passed with warnings can now fail; `samples/rs_bad.rs` is the canonical example, and the CLI end-to-end check requires `error_count > 0` and `pass == false` for it.

### Added

- `ban_unsafe` (error): any `unsafe`.
- `ban_dangerous_macros` (error): `panic!()`, `unreachable!()`, `todo!()`, `unimplemented!()`, `dbg!()`. Other macros such as `vec!`, `format!`, and `matches!` remain allowed.
- `ban_clone` (error): `.clone()`, `.clone_from()`, `Clone::clone()`.
- `warn_unwrap_err`, `warn_transmute` (including `transmute_copy` and turbofish forms), `warn_static_mut`, `warn_raw_pointer` (`*const`/`*mut`), `warn_allow` (`#[allow(...)]`/`#![allow(...)]`), and `warn_box_leak` (all warn).
- Wiki documentation: Rust rules reference, configuration guide, and migration guide.

### Changed

- The broad runtime-risk pass no longer double-reports Rust panic paths, `dbg!`, or clone-in-a-loop; those constructs are reported once, by the bans above. `println!`/`eprintln!` remain audit debug-output warnings.
- Disabling `ban_dangerous_macros` therefore silences Rust panic-path reporting entirely; there is no warn-level fallback.

### Notes

- Rust matching is heuristic and text-based on comment/string-masked source, consistent with the rest of Guardian. Unusual spacing or bracket macro invocation (for example `panic! (` or `todo![]`) is not matched.
- Rationale for each rule follows the stable Rust documentation at <https://doc.rust-lang.org/stable/>; per-rule links are in the [Rust rules wiki page](https://github.com/million-in/guardian/wiki/Rust-Rules).

## v0.2.0

Previous tagged release. See the [GitHub release notes](https://github.com/million-in/guardian/releases/tag/v0.2.0).
