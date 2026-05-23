---
id: PATCH-ID-HERE
review-date: 2026-05-DD
reviewer: Claude Opus 4.7
v1-tip-sha: SHA-OF-V1-FORK-BRANCH-TIP
v2-tip-sha: pending
status: in-progress
related-patches: []
---

# PATCH-ID-HERE — v2 review

## Rationale

Why this patch exists. Bug class. Upstream issue. The persistent capability
the driver should gain. One or two paragraphs.

## v1 audit

What the current fork branch does (anchored in hunks). Strengths. Weaknesses.
Surprises relative to vanilla NVIDIA source.

## Design choices

Significant decisions made during the v2 review. "We considered X but chose
Y because Z." Tradeoffs surfaced.

## v1 → v2 deltas

### PATCH-ID-HERE-D1 — Example delta title

- **Location:** `kernel-open/<file>:<symbol>` (or commit-hunk reference)
- **Change:** What we're doing.
- **Severity:** must-fix | should-fix | nice-to-have | out-of-scope
- **Evidence:** Why this matters — vanilla source citation, telemetry gap,
  intent clause anchor.
- **Resolution:** pending

(repeat for each delta; if no deltas, replace with "(no v1→v2 deltas — v1
already meets the v2 intent)")

## Done gate

- [ ] `docs/patch-intents/PATCH-ID-HERE.md` exists, lints clean, `status: reviewed`.
- [ ] All must-fix deltas applied as fork-branch commits citing their delta IDs.
- [ ] `patches/<layer>/PATCH-ID-HERE.patch` refreshed by `regen`.
- [ ] `tools/validate-patchset.sh` passes (compile gate).
- [ ] `bash tests/run.sh` green.
- [ ] Audit-reviewer subagent approved.

## Cross-references

- Intent file: `docs/patch-intents/PATCH-ID-HERE.md`
- Manifest row: `patches/manifest` line for `PATCH-ID-HERE`
- Vanilla baseline: `kernel-open/<dir>/<file>:<symbol>`
- Fork branch: `BRANCH-NAME-HERE` on `apnex/open-gpu-kernel-modules`
- Upstream issue: URL or "n/a"
- Related reviews: `[[<id>]]` wikilinks (presentation only — not lint-resolved)
