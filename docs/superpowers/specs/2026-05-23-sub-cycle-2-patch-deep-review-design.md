# Sub-cycle 2 — per-patch v2 deep review (design)

**Status:** approved design — 2026-05-23. Defines the methodology that takes
each of the 11 fork-branch patches from draft (v1) to reviewed (v2), using the
patch-intent schema landed in sub-cycle 1 as the engineered output shape.

## Context

Sub-cycle 1 built the **machinery**: the canonical patch-intent schema
(`docs/patch-intent-schema.md`, v1.0), the `_template.md` skeleton,
`intent-lint` with 11 lint rules, `render-patch-index`, and the test harness.
What it did NOT do is *write* an intent file for any of the 11 fork-branch
patches — that's this cycle.

The 11 patches live on their own fork branches under
`apnex/open-gpu-kernel-modules`:

| Layer | Patches | Branches |
|---|---|---|
| Base (upstream-bound) | C1, C2, C3, C4, E1, C5 | `c1-kbuild-version-mk` … `c5-crash-safety` |
| Addon (project-local) | A1, A2, A3, A4, A5 | `a1-pcie-primitives` … `a5-version-and-toggles` |

Each is currently in "draft" state per the schema's status enum. Sub-cycle 2
takes them to "reviewed" — engineered intent captured, must-fix improvements
applied, composed patchset compiles, audit trail complete.

This is not a documentation pass. It is a **substantive engineering review
expressed through the schema**: the intent file is the v2 normative contract;
the review file is the v1→v2 audit; the fork-branch commits are the v2 code.

## Goal

Take all 11 patches to `status: reviewed`, producing:

- An intent file per patch at `docs/patch-intents/<id>.md` — schema-conformant,
  lint-clean, captures the v2 normative shape.
- A review file per patch at `docs/patch-reviews/<id>.md` — rationale, v1
  audit, design choices, structured v1→v2 deltas, done gate.
- Follow-up commits on each fork branch applying must-fix deltas, each commit
  subject leading with its delta ID.
- Regenerated `patches/<layer>/<id>.patch` files in the injector.
- Regenerated `docs/patch-index.md` with real (non-"intent file missing")
  rows for all 11 patches.

## Scope

**In scope:**

- Read vanilla NVIDIA source (`595.71.05` baseline) at relevant symbols.
- Read fork-branch v1 hunks; understand current behaviour.
- Capture engineered v2 intent per patch.
- Audit v1 against v2 intent; surface structured deltas.
- Apply must-fix deltas as follow-up commits on the existing fork branch.
- Regenerate the injector-side patch files, manifest validation, patch index.
- Verify composed patchset compiles via `tools/validate-patchset.sh`.

**Out of scope (deferred to follow-on initiatives):**

- Hardware behavioural validation; `aorus.NN` image rebuild; the ≥14-day soak.
- The `status: reviewed → approved` flip — that lives in a post-soak commit.
- NVIDIA upstream PR submission — gated by the standing
  no-premature-upstream-filing policy until soak validates the v2 set.
- Schema (sub-cycle 1) changes — frozen at v1.0 for this cycle. If a review
  surfaces a true schema gap, raise it explicitly and pause for a separate
  schema-v1.1 cycle rather than slipping the change into sub-cycle 2.
- Review-file lint tooling — review files are one-shot, human-judgment
  artefacts in this cycle; revisit if they become a recurring artefact.

## Architecture

**Methodology-once, execute-11-times.** This spec defines the per-patch
methodology; the writing-plans plan that follows breaks it into concrete
tasks (one per patch, plus checkpoint and final-review tasks). The 11-step
per-patch workflow (§Per-patch workflow) is the unit of work.

### Order and parallelism

- **Order:** dependency order, equal to fork-stack order and manifest apply
  order: `C1 → C2 → C3 → C4 → E1 → C5 → A1 → A2 → A3 → A4 → A5`.
- **Parallelism:** strict serial. One patch fully done (intent + review +
  fork commits + regenerated .patch + audit-reviewer approval) before the
  next starts.
- **Methodology checkpoint after C1.** C1 is the simplest patch (kbuild
  metadata). After C1 completes end-to-end, **pause** and evaluate: did the
  intent shape work, did the review file structure carry the right content,
  is anything missing or redundant. If methodology gaps surface, amend this
  spec and the plan before resuming with C2. If clean, proceed straight
  through to A5.

### Subagent topology

Per patch, a 2-subagent shape (review-implementer + audit-reviewer). This
deliberately collapses sub-cycle 1's separate spec-compliance and
code-quality reviewer stages into a single audit pass: a per-patch review
has smaller surface than sub-cycle 1's foundation work, and the
audit-reviewer's mandate covers both schema/spec conformance and
substantive engineering quality.

- **Review-implementer** (Opus) — executes the 11-step per-patch workflow.
  Reads vanilla, reads fork branch, writes intent file, writes review file,
  applies fork commits, regenerates patch file, runs compile + test gates,
  flips status to `reviewed`, commits the injector-side changes.
- **Audit-reviewer** (Opus) — independent verification. Reads the intent
  file, review file, fork-branch commits, regenerated .patch. Verifies the
  intent is anchored in vanilla NVIDIA source semantics; deltas are
  well-justified; must-fix items all have explicit `Resolution`; the compile
  gate actually passed; no silent drive-by commits on the fork branch.
- Audit findings → review-implementer fixes → audit re-runs. Loop until
  approved.

After all 11 patches:

- **Final cross-branch reviewer** (Opus) — holistic assessment. Cross-patch
  consistency (e.g. A1 primitives match what A2-A4 consumers assume);
  `docs/patch-index.md` correctly regenerated; full test suite green;
  branch ready to merge to `main`.

Estimated subagent count: ~25-35 invocations across the full cycle
(11 × 2-3 per patch, plus re-review loops, plus final).

## Per-patch workflow

For each patch, in order, the review-implementer subagent executes:

1. **Read vanilla** at `kernel-open/<file>:<symbol>` locations identified
   from the fork-branch diff.
2. **Read fork branch v1** hunk-by-hunk on `apnex/open-gpu-kernel-modules`.
   Note `v1-tip-sha:`.
3. **Write intent file** at `docs/patch-intents/<id>.md`:
   - Copy `docs/patch-intents/_template.md` as starting point.
   - Replace all placeholders. Frontmatter must match the manifest row for
     `id`, `layer`, `source-branch`.
   - Write Requirements (with UPPERCASE RFC 2119 keywords) and Scenarios
     (GIVEN/WHEN/THEN) that capture the v2 normative shape — what the patch
     SHALL do, not what v1 does.
   - Telemetry contract section names every log event and format.
   - Provenance section cites vanilla baseline + fork branch + upstream issue.
   - `status: draft`.
4. **Write review file** at `docs/patch-reviews/<id>.md`:
   - Frontmatter: `id`, `review-date`, `reviewer`, `v1-tip-sha`,
     `v2-tip-sha: <pending>`, `status: in-progress`.
   - Sections: Rationale, v1 audit, Design choices, v1→v2 deltas, Done gate,
     Cross-references.
   - Each delta entry has: id (`<patch-id>-D<N>`), Location, Change,
     Severity (`must-fix | should-fix | nice-to-have | out-of-scope`),
     Evidence, Resolution (initially `pending`).
5. **Apply must-fix deltas** as follow-up commits on the fork branch. Each
   commit subject leads with its delta ID:
   `<patch-id>-D<N>: <one-line description>`. Strict — every fork-branch
   v2 commit cites a delta ID; no silent drive-bys.
6. **Push fork branch** to `apnex/open-gpu-kernel-modules`.
7. **Run `tools/regen-base-patches.sh`** to refresh the injector's
   `patches/<layer>/<id>.patch`.
8. **Run `tools/validate-patchset.sh`** — compile gate. Composed patchset
   must still build. If it fails, the deltas need rework (return to step 5).
9. **Run `bash tests/run.sh`** — schema-machinery tests stay green
   (8/16/10/...).
10. **Update review file:** `v2-tip-sha:` frontmatter to new fork tip; each
    must-fix delta's `Resolution: applied as <SHA>` (or `deferred to
    <follow-up>` / `rejected because <reason>` for non-applied deltas).
    Flip review `status: in-progress → accepted`.
11. **Flip intent file `status: draft → reviewed`.** Commit the injector-side
    changes (intent file, review file, refreshed .patch, optionally
    regenerated `docs/patch-index.md`) as one commit per patch.

The audit-reviewer subagent then runs and either approves or returns issues.
Loop until approved. Then move to the next patch.

## Artefact specifications

### Intent file

Path: `docs/patch-intents/<id>.md`. Conforms to the schema at
`docs/patch-intent-schema.md` (v1.0). Lint-checked by `tools/intent-lint.sh`.
All 11 lint rules must pass. Status enum lifecycle: `draft → reviewed →
approved`. Sub-cycle 2 produces files at `reviewed`.

### Review file

Path: `docs/patch-reviews/<id>.md`. Not lint-checked in this cycle.

**Frontmatter (7 fields):**

```yaml
---
id: C3-gpu-lost-retry           # must match intent id
review-date: 2026-05-DD         # absolute date the review ran
reviewer: Claude Opus 4.7       # agent or human reviewer identity
v1-tip-sha: <SHA>               # fork-branch tip BEFORE v2 commits
v2-tip-sha: <SHA>               # fork-branch tip AFTER v2 commits
status: accepted                # in-progress | accepted | rejected
related-patches: []             # cross-refs to other reviews (optional)
---
```

**Required sections, in order:**

1. `# <id> — v2 review` — top heading.
2. `## Rationale` — why this patch exists; bug class; upstream issue;
   the persistent capability we want the driver to have. Anchors the audit.
3. `## v1 audit` — what the current fork branch does; strengths;
   weaknesses; surprises relative to vanilla NVIDIA.
4. `## Design choices` — significant decisions made during v2 review.
   "We considered X but chose Y because Z." Tradeoffs.
5. `## v1 → v2 deltas` — structured list. Each delta:

   ```markdown
   ### <patch-id>-D<N> — <one-line title>
   - **Location:** `kernel-open/<file>:<symbol>` (or commit-hunk reference)
   - **Change:** <what we're doing>
   - **Severity:** must-fix | should-fix | nice-to-have | out-of-scope
   - **Evidence:** <why this matters — vanilla-source citation, telemetry
     gap, intent-clause anchor>
   - **Resolution:** applied as <SHA> | deferred to <follow-up> | rejected
     because <reason>
   ```

6. `## Done gate` — concrete criteria proving v2 review complete for this
   patch (intent lints clean, compile passes, all must-fix resolved, etc.).
7. `## Cross-references` — links to intent file, manifest row, upstream
   issue, vanilla baseline, related patches.

Delta granularity: **change-level**, not commit-level. A "rethink telemetry
contract" delta may span multiple commits; a "fix typo + rename function"
delta may fold into one commit with other changes. The `Resolution` field
captures the SHA(s).

### Fork-branch commits

Each must-fix delta lands as one or more follow-up commits on the fork
branch. Commit subject format: `<patch-id>-D<N>: <description>`. Strict
delta-ID citation. No force-push to fork branches (v1 SHA preserved as the
first commit on each branch; v2 chain on top).

Trivial improvements (typos, whitespace) belong inside a substantive delta
or in a per-patch `<patch-id>-D-final-cleanup` catch-all delta. Nothing
lands without an audit trail in the review file.

### Regenerated patch files

`patches/<layer>/<id>.patch` is regenerated via `tools/regen-base-patches.sh`
after fork-branch v2 commits push. The injector consumes the cumulative diff,
so multi-commit fork branches still produce a single .patch artefact.

### Regenerated patch index

`docs/patch-index.md` regenerates via `tools/render-patch-index.sh`. After
each per-patch commit (step 11), the row for that patch flips from
"(intent file missing)" to populated content. Can be regenerated per-patch
or once at the end of the cycle — either works; production-migration prefers
the per-patch flow for incremental visibility.

## Done gate

### Per-patch done gate

For patch `<id>`:

- [ ] `docs/patch-intents/<id>.md` exists, lints clean, `status: reviewed`.
- [ ] `docs/patch-reviews/<id>.md` exists, all deltas have explicit
  `Resolution`, review `status: accepted`.
- [ ] Fork branch pushed; all must-fix deltas applied as commits citing
  their delta IDs.
- [ ] `patches/<layer>/<id>.patch` refreshed by `regen`.
- [ ] `tools/validate-patchset.sh` passes.
- [ ] `bash tests/run.sh` green.
- [ ] Audit-reviewer subagent approved.

### Full sub-cycle 2 done gate

- [ ] All 11 patches meet per-patch done gate.
- [ ] `docs/patch-index.md` shows real content for all 11 rows
  (no "intent file missing").
- [ ] All cross-patch `related-patches:` references resolve (Rule 6).
- [ ] `bash tests/run.sh` green.
- [ ] `tools/validate-patchset.sh` passes.
- [ ] Final cross-branch reviewer approved.
- [ ] Branch ready to merge to `main`.

## Branch strategy

**Injector:** single feature branch `feature/v2-patch-reviews` off `main`.
Per-patch commits accumulate. Final cross-branch review at the end. Merge
fast-forward to `main` when done gate passes.

**Fork:** v2 commits land on the existing 11 fork branches on
`apnex/open-gpu-kernel-modules`. No new branches, no force-push, no rename.

## Relationship to other initiatives

- **Sub-cycle 1 (schema):** input. Sub-cycle 2 consumes the schema, the
  template, the tooling. Frozen at v1.0 for this cycle.
- **`docs/production-migration.md` steps 5-7:** downstream. After sub-cycle 2
  merges, the next aorus image build picks up the v2 patches (exact tag
  depends on whether aorus.14 was built from the v1 C+E+A state before
  sub-cycle 2 lands). Soak validates the v2 set. Post-soak, a single
  follow-on commit flips all 11 intents from `reviewed → approved`.
- **Issue #979 outreach:** the v2 patches + intents become the public-facing
  artefacts. The intent files anchor the eventual NVIDIA upstream PR bodies
  for C1-C5 + E1 (when no-premature-upstream gate lifts).
- **`feedback_compile_validation_not_apply_check`:** load-bearing.
  `tools/validate-patchset.sh` (which runs `make modules` against the
  project's kernel) is the per-patch gate, not `git apply --check`.
- **`feedback_subagents_on_opus`:** all dispatched subagents on Opus.

## Tooling

**Reuse only.** No new tools introduced by sub-cycle 2.

- `tools/intent-lint.sh` — validates each intent file (all 11 rules).
- `tools/render-patch-index.sh` — regenerates `docs/patch-index.md`.
- `tools/regen-base-patches.sh` — regenerates `patches/<layer>/<id>.patch`
  from the corresponding fork branch.
- `tools/validate-patchset.sh` — compile gate (composes the patchset and
  runs `make modules` against the project kernel).
- `tools/compose-patchset.sh` — composes the in-tree patchset for build
  consumption.
- `tests/run.sh` — schema-machinery test suite.

If a recurring need surfaces during C1's checkpoint (e.g. a helper to read
vanilla NVIDIA source at a given symbol), add it then — not pre-emptively.

## Out of scope

- Hardware behavioural validation; `aorus.NN` image rebuild; the soak.
- The `status: reviewed → approved` flip.
- NVIDIA upstream PR submission.
- Schema (sub-cycle 1) changes; lint rule additions; new `##` sections.
- Review-file lint tooling.
- Re-carving any v1 fork branch to a `<id>-v2` branch.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Methodology gaps surface mid-cycle | First-patch (C1) checkpoint forces an explicit pause + amendment cycle before C2 |
| Cross-patch consistency drift (A1 primitives ↔ A2-A4 consumers) | Final cross-branch reviewer's mandate; `intent-lint` Rule 6 enforces `related-patches:` resolution |
| Fork-branch commit churn breaks `regen` cleanly | `validate-patchset.sh` compile gate catches before the per-patch commit lands |
| Reviewer subagent invents intent rather than anchoring in vanilla source | Audit-reviewer's mandate is to verify anchoring against `kernel-open/<file>:<symbol>` |
| Scope creep into hardware-soak territory | Explicit out-of-scope section; intent `status: approved` is the only marker that demands hardware evidence |
| 11-review fatigue → quality drops on later patches | Strict serial + per-patch audit-reviewer + final cross-branch reviewer triple-gate against this |
| Schema gap surfaces (e.g. need for a new section) | Pause; lift to a separate schema-v1.1 cycle; do not slip into sub-cycle 2 |
| Force-push on a fork branch loses v1 audit | Strict no-force-push policy; v1 preserved as the first commit on each branch |

## Relationship to prior decisions

This design **consumes** the schema landed in sub-cycle 1
([patch-intent-schema-design](2026-05-22-patch-intent-schema-design.md))
and the C/E/A patch geometry captured in the addon-recarve and
dynamic-patch-composition design specs
([addon-recarve-design](2026-05-22-addon-recarve-design.md),
[dpc-design](2026-05-22-dynamic-patch-composition-design.md)).
It runs **in parallel** with
`production-migration.md` steps 5-7 (image rebuild → soak → cutover) which
are the other outstanding production work. The two streams converge
post-soak when intents flip to `approved`.
