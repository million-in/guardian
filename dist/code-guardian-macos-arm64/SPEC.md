# SPEC.md

## Overview

Guardian is a Zig static-analysis engine for enforcing engineering discipline across polyglot repositories. It scans Go, TypeScript, Python, Rust, and Zig through the `gd` CLI and a C ABI library.

## Why it is built this way

Guardian must be small, fast, portable, and dependency-light. Language support is heuristic and source-text based: mask comments/strings, build a lightweight symbol model, then run focused analyzers for nesting, complexity, type-safety footguns, cohesion, design smells, and formatting.

## Stakeholders

The project owner wants Guardian usable as an installed binary/library, not as an agent plugin. Primary users are engineers and automation that call `gd` or link the ABI in local-first workflows.

## Edge cases and invariants

- Supported public surfaces are only `gd` and `libguardian`/`guardian.h`; do not reintroduce MCP servers, assistant plugins, or skills.
- Folder scans must honor configured extensions and ignored directories.
- Source masking must keep line/column positions stable and ignore patterns inside comments and strings.
- Config discovery walks from the target path, supports YAML plus legacy JSON, and resolves overrides per file in batch/folder scans.
- C ABI JSON strings are owned by Guardian and must be released with `guardian_free_string`.
