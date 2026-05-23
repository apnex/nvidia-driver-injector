---
title: Patch-intent schema
version: 1.0
status: approved
last-updated: 2026-05-22
---

# Patch-intent schema

The canonical, machine-validated schema for per-patch intent specifications in
the `nvidia-driver-injector` project. Authors copy
[`docs/patch-intents/_template.md`](patch-intents/_template.md) and replace
its placeholder values. The validator at `tools/intent-lint.sh` enforces every
rule below; the renderer at `tools/render-patch-index.sh` builds the
consolidated index `docs/patch-index.md` from frontmatter.

This document is the **persistent reference**. Decision context and design
rationale live in [the brainstorming
spec](superpowers/specs/2026-05-22-patch-intent-schema-design.md).

## Frontmatter — 7 required fields

| Field | Type / values | Meaning |
|---|---|---|
| `id` | string | Logical patch identity. Must equal the filename stem **and** the patch's `patches/manifest` row id. |
| `layer` | `base` \| `addon` | Must match the manifest row's layer for this id. |
| `source-branch` | string | The fork branch name (without the `fork:` prefix). Must equal the manifest row's `source: fork:<branch>` value. |
| `upstream-candidacy` | `high` \| `medium` \| `low` \| `n/a` | Likelihood of upstream acceptance. `n/a` is the **only** allowed value when `layer: addon`. |
| `telemetry-tier` | `mandatory` \| `nominal` \| `none` | `mandatory` — silent behaviour invisible without logs (e.g. C3 retry, A3 recovery). `nominal` — standard prove-the-path-ran. `none` — no telemetry expected. |
| `status` | `draft` \| `reviewed` \| `approved` | Workflow state. |
| `related-patches` | YAML list of ids | Cross-references to other intent files. `[]` allowed. Every listed id must resolve to another `docs/patch-intents/<id>.md`. |

## Markdown sections — required, in this order

1. `# <id> — <human title>` — top heading. The id prefix must equal the frontmatter `id`.
2. `## Purpose` — one paragraph stating the persistent capability the patch grants.
3. `## Requirements` — ≥ 1 `### Requirement: <name>` blocks. Each requirement contains normative prose (RFC 2119 keywords UPPERCASE) and ≥ 1 `#### Scenario: <name>` block written in GIVEN/WHEN/THEN/AND style.
4. `## Scope boundary` — bullet list of deliberate non-goals.
5. `## Telemetry contract` — table or list: Event / Level / Format.
6. `## Provenance` — source cluster, vanilla baseline file(s), fork branch, upstream issues.

## RFC 2119 conformance (strict)

The normative keywords are **MUST / MUST NOT / REQUIRED / SHALL / SHALL NOT / SHOULD / SHOULD NOT / RECOMMENDED / MAY / OPTIONAL**.

- Inside `## Requirements` blocks, RFC 2119 keywords MUST appear UPPERCASE when used normatively.
- Every `### Requirement:` block MUST contain at least one UPPERCASE keyword.
- Outside `## Requirements`, RFC 2119 keywords in prose use lowercase (descriptive, not normative).

## Cross-reference syntax

| Reference target | Form |
|---|---|
| Another patch's intent | `[[<id>]]` — wiki-style; `intent-lint` resolves to a file under `docs/patch-intents/`. |
| Vanilla NVIDIA source | Backticked `path:symbol` — e.g. `` `kernel-open/nvidia/os-mlock.c:osHandleGpuLost` ``. Not lint-resolved. |
| Upstream issue | Full URL. |

## Validation rules — enforced by `intent-lint`

| Rule | Check |
|---|---|
| R1 | Frontmatter parses; all 7 required fields present. |
| R2 | `id` equals filename stem. |
| R3 | `layer` matches `patches/manifest` row. |
| R4 | `source-branch` matches manifest's `fork:<branch>`. |
| R5 | `upstream-candidacy: n/a` iff `layer: addon`. |
| R6 | Every `related-patches` entry resolves to another intent file. |
| R7 | Required `##` sections present in the exact order specified. |
| R8 | `## Requirements` contains ≥ 1 `### Requirement:` block. |
| R9 | Each `### Requirement:` block contains ≥ 1 UPPERCASE RFC 2119 keyword. |
| R10 | Each `### Requirement:` has ≥ 1 `#### Scenario:` block. |
| R11 | Top heading `# <id>` matches frontmatter `id`. |

Tests for each rule live in `tests/test-intent-lint.sh`.

## Schema versioning

This document's `version` frontmatter field is the schema's authoritative version.

- **`1.0`** (2026-05-22) — initial release.

Bump the major version for breaking changes (removed fields, restructured sections, changed semantics). Bump the minor version for additive changes (new optional fields, new permitted enum values). Update `last-updated` on every revision.

## Tooling

- `tools/intent-lint.sh [--manifest FILE] [--intents-dir DIR] [file...]` — validates intents.
- `tools/render-patch-index.sh [--manifest FILE] [--intents-dir DIR] [--out FILE]` — generates `docs/patch-index.md`.
- `tools/lib/intent.sh` — shared parsing helpers.

## Relationship to other documents

- `docs/patch-intents/_template.md` — copy-and-edit starter; lint-excluded by filename.
- `docs/patch-index.md` — generated; do not hand-edit.
- `patches/manifest` — identity ground-truth for `id` / `layer` / `source-branch` cross-checks.
- `docs/superpowers/specs/2026-05-22-patch-intent-schema-design.md` — brainstorming-cycle decision record (context and rationale; this schema reference is the living distillation).
