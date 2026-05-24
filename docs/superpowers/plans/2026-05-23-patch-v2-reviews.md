# Sub-cycle 2 — Per-Patch v2 Deep Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take the 11 fork-branch patches (`C1`–`C5`, `E1`, `A1`–`A5`) from draft (v1) to reviewed (v2), producing per-patch intent + review files, applying must-fix improvements as fork-branch commits, and merging the resulting candidate set to `main`.

**Architecture:** Methodology-once, execute-11-times. A canonical 12-step per-patch workflow is defined below; Tasks 2 and 4–13 apply it to one patch each with task-specific bindings. Strict serial in dependency order. 2-subagent topology per patch (review-implementer + audit-reviewer) plus a final cross-branch reviewer. Methodology checkpoint after the first patch (C1).

**Tech Stack:** Patch-intent schema v1.0 from sub-cycle 1 (`docs/patch-intent-schema.md`). Existing bash tooling — `tools/intent-lint.sh`, `tools/regen-base-patches.sh`, `tools/validate-patchset.sh`, `tools/render-patch-index.sh`. Git for fork-branch commits.

---

## Context & scope

Implements `docs/superpowers/specs/2026-05-23-sub-cycle-2-patch-deep-review-design.md` — **read that spec first**.

**Delivered here:**

- 11 intent files at `docs/patch-intents/<id>.md` — schema-conformant, lint-clean, `status: reviewed`.
- 11 review files at `docs/patch-reviews/<id>.md` — rationale + v1 audit + structured deltas + done gate.
- One review-file template at `docs/patch-reviews/_template.md`.
- Follow-up commits on each fork branch (apnex/open-gpu-kernel-modules) applying must-fix deltas, each commit citing its delta ID.
- Regenerated `patches/<layer>/<id>.patch` for each patch.
- Regenerated `docs/patch-index.md` with real content for all 11 rows.

**Out of scope (per spec):**

- Hardware behavioural validation; aorus image rebuild; the soak.
- The `status: reviewed → approved` flip.
- NVIDIA upstream PR submission.
- Schema (sub-cycle 1) changes.
- Review-file lint tooling.

**Working state:** branch `feature/v2-patch-reviews` (already created, off `main`; the spec doc is already committed). Fork repo at `/root/open-gpu-kernel-modules` (confirmed by `tools/regen-base-patches.sh:19`).

## File structure

| File | Responsibility | Created in |
|---|---|---|
| `docs/patch-reviews/_template.md` | Review-file skeleton for authors. Not lint-checked. | Task 1 |
| `docs/patch-intents/<id>.md` | v2 normative intent for each of the 11 patches. Schema-conformant, lint-clean. | Tasks 2 + 4–13 |
| `docs/patch-reviews/<id>.md` | Rationale, v1 audit, structured deltas, done gate for each patch. | Tasks 2 + 4–13 |
| `patches/<layer>/<id>.patch` | Regenerated patch artefacts after fork-branch v2 commits. | Tasks 2 + 4–13 (regen step) |
| `docs/patch-index.md` | Regenerated index showing real content for all 11 rows. | Task 14 (final regen) |

---

## Per-patch workflow (canonical 12-step procedure)

**Tasks 2 and 4–13 each execute this workflow against one patch.** Each task's header provides the **bindings**:

- `<patch-id>` — manifest id (e.g. `C3-gpu-lost-retry`).
- `<layer>` — `base` or `addon`.
- `<source-branch>` — fork branch name (without `fork:` prefix).
- `<related-patches>` — starter list of related intent ids (subagent may add more during review).

The workflow steps below reference these bindings; replace at execution time. **Subagent topology:** each task is run by the **review-implementer** subagent (steps 1–12). The **audit-reviewer** subagent then verifies the outputs. Loop until approved.

### Step 1: Identify and read vanilla NVIDIA source

```bash
cd /root/open-gpu-kernel-modules
git checkout <source-branch>
# Inspect the full diff against the 595.71.05 baseline:
git diff 595.71.05 -- kernel-open/
# Note every kernel-open/<file> touched by this patch.
```

For each touched file, read the vanilla version:

```bash
cd /root/open-gpu-kernel-modules
git show 595.71.05:kernel-open/<file>
```

Capture the vanilla baseline locations as a scratch note for use in Steps 3 and 5 (these become the `## Provenance` section's `Vanilla baseline:` entries and anchor every `### Requirement:` in the intent).

### Step 2: Read fork-branch v1 hunks; capture v1-tip-sha

```bash
cd /root/open-gpu-kernel-modules
git log --oneline <source-branch>
git show <source-branch>
v1_tip_sha="$(git rev-parse <source-branch>)"
echo "v1-tip-sha: $v1_tip_sha"
```

Record `$v1_tip_sha` — Step 5 puts it in the review file's frontmatter.

### Step 3: Write intent file (v2 normative shape)

```bash
cp /root/nvidia-driver-injector/docs/patch-intents/_template.md \
   /root/nvidia-driver-injector/docs/patch-intents/<patch-id>.md
```

Edit `/root/nvidia-driver-injector/docs/patch-intents/<patch-id>.md`:

- Frontmatter:
  - `id: <patch-id>` (must equal the new filename stem).
  - `layer: <layer>`.
  - `source-branch: <source-branch>`.
  - `upstream-candidacy:` — `high` / `medium` / `low` for base patches; `n/a` for addon patches (Rule 5).
  - `telemetry-tier:` — `mandatory` if silent recovery, `nominal` for prove-the-path logs, `none` for build metadata.
  - `status: draft` (will flip to `reviewed` in Step 12).
  - `related-patches: <related-patches>` (use `[]` if none).
- Top heading: `# <patch-id> — <Human Title>`.
- `## Purpose` — one paragraph stating the persistent capability this patch grants. Cite bug class and upstream issue (#979 if applicable).
- `## Requirements` — one or more `### Requirement: <name>` blocks. Each contains normative prose with UPPERCASE RFC 2119 keywords AND at least one `#### Scenario: <name>` block in GIVEN/WHEN/THEN/AND style.
- `## Scope boundary` — bullet list of deliberate non-goals.
- `## Telemetry contract` — table or list naming every log event, level, and format.
- `## Provenance` — source cluster (`P<n>` from legacy), vanilla baseline files/symbols, fork branch, upstream issue URL or `n/a`.

**Capture the v2 NORMATIVE shape — what the code SHALL do, not what v1 does.**

**Purpose discipline (M3 from C1 checkpoint):** keep `## Purpose` tight — one paragraph stating the persistent capability. Historical context (project incidents, previous patch generations, debugging journey) belongs in the review file's `## Rationale` section, not the intent's Purpose. For richer-history patches (C3, C5, A2, A3) this matters more — Purpose can easily bloat to 3+ paragraphs of backstory if discipline slips.

Lint immediately:

```bash
cd /root/nvidia-driver-injector
tools/intent-lint.sh docs/patch-intents/<patch-id>.md; echo "exit=$?"
```

Expected: `exit=0`, no output. If lint fails, iterate on the intent file (fix and re-lint) until clean.

### Step 4: Sanity-lint the full intents directory

```bash
cd /root/nvidia-driver-injector
tools/intent-lint.sh; echo "exit=$?"
```

Expected: `exit=0`. Catches any cross-file issue (related-patches resolution etc.) early.

### Step 5: Write review file

```bash
cp /root/nvidia-driver-injector/docs/patch-reviews/_template.md \
   /root/nvidia-driver-injector/docs/patch-reviews/<patch-id>.md
```

Edit `/root/nvidia-driver-injector/docs/patch-reviews/<patch-id>.md`:

- **Frontmatter (7 fields):**
  - `id: <patch-id>` (must match intent file's id).
  - `review-date: 2026-05-DD` (today's date).
  - `reviewer: Claude Opus 4.7`.
  - `v1-tip-sha: $v1_tip_sha` from Step 2.
  - `v2-tip-sha: pending` (filled in Step 11).
  - `status: in-progress` (will flip to `accepted` in Step 11).
  - `related-patches: <related-patches>` (mirror the intent file).
- **Sections (7, in order):**
  1. `# <patch-id> — v2 review` (top heading).
  2. `## Rationale` — why this patch exists; bug class; upstream issue; persistent capability.
  3. `## v1 audit` — what v1 does (anchored in fork-branch hunks read in Step 2); strengths; weaknesses; surprises relative to vanilla baseline.
  4. `## Design choices` — significant decisions for v2. "We considered X but chose Y because Z." Tradeoffs.
  5. `## v1 → v2 deltas` — structured deltas (see below).
  6. `## Done gate` — concrete per-patch criteria.
  7. `## Cross-references` — intent file, manifest row, vanilla baseline, upstream issue URL.

Each delta in Section 5 has this shape:

```markdown
### <patch-id>-D<N> — <one-line title>
- **Location:** `kernel-open/<file>:<symbol>` (or commit-hunk reference)
- **Change:** <what we're doing>
- **Severity:** must-fix | should-fix | nice-to-have | out-of-scope
- **Evidence:** <why this matters — vanilla source citation, telemetry gap, intent clause anchor>
- **Resolution:** pending
```

Delta IDs are sequential per patch: `<patch-id>-D1`, `<patch-id>-D2`, etc.

If a patch has zero must-fix deltas (e.g. trivial patches like C1-kbuild may need no changes), the deltas section uses the canonical zero-delta wording `(no v1→v2 deltas — v1 already meets the v2 intent)` and Steps 6–8 are skipped.

**Zero-delta sentinel convention (M2 from C1 checkpoint):** when a review surfaces zero deltas, the review file's frontmatter has `v1-tip-sha == v2-tip-sha` (both pointing at the unchanged fork-branch tip). This pair-of-identical-SHAs is the machine-checkable sentinel for "v1 already met v2 intent." Audit-reviewers should treat the sentinel as a valid green state — no Resolution updates required, no fork-branch commits expected. Don't write `v2-tip-sha: pending` and don't write `v2-tip-sha: n/a`; mirror the v1 SHA so cross-references work.

### Step 6: Apply must-fix deltas as fork-branch commits

For each `Severity: must-fix` delta:

```bash
cd /root/open-gpu-kernel-modules
git checkout <source-branch>
# Edit files per the delta's Change description.
git add <files>
git commit -m "$(cat <<'EOF'
<patch-id>-D<N>: <one-line description from delta title>

<Optional longer body citing review file path and Evidence excerpt.>

EOF
)"
delta_N_sha="$(git rev-parse HEAD)"
```

Capture each commit's SHA — they go into Step 11's Resolution updates.

**Strict discipline:** every commit on the fork branch during this step must lead its subject with the delta ID. No silent drive-bys. If a trivial improvement (typo, whitespace) is warranted, add it as a delta first (e.g. `<patch-id>-D-cleanup` with Severity `nice-to-have`) and cite it.

### Step 7: Push fork branch

```bash
cd /root/open-gpu-kernel-modules
git push origin <source-branch>
```

This pushes to `apnex/open-gpu-kernel-modules` per the fork's remote config.

### Step 8: Regenerate the injector patch file

```bash
cd /root/nvidia-driver-injector
tools/regen-base-patches.sh
```

Expected: writes `patches/<layer>/<patch-id>.patch` with the cumulative v2 diff. Inspect:

```bash
git diff patches/<layer>/<patch-id>.patch
```

Confirm the diff reflects the v2 changes from Step 6.

### Step 9: Compile gate

```bash
cd /root/nvidia-driver-injector
tools/validate-patchset.sh; echo "exit=$?"
```

Expected: `exit=0`. The composed patchset applies cleanly and `make modules` succeeds against the project kernel.

**If compile fails:** the deltas need rework. Return to Step 6, amend or add new deltas, push, regen, retry compile.

### Step 10: Test gate

```bash
cd /root/nvidia-driver-injector
bash tests/run.sh; echo "exit=$?"
```

Expected: `test-compose.sh: 8 run, 0 failed`, `test-intent-lint.sh: 16 run, 0 failed`, `test-manifest-lib.sh: 10 run, 0 failed`, `exit=0`.

### Step 11: Update review file with results

```bash
cd /root/open-gpu-kernel-modules
v2_tip_sha="$(git rev-parse <source-branch>)"
echo "v2-tip-sha: $v2_tip_sha"
```

Edit `/root/nvidia-driver-injector/docs/patch-reviews/<patch-id>.md`:

- Frontmatter: set `v2-tip-sha: $v2_tip_sha`.
- Frontmatter: flip `status: in-progress → accepted`.
- For each delta: set `Resolution: applied as <SHA>` (Step 6 SHAs) OR `Resolution: deferred to <follow-up>` OR `Resolution: rejected because <reason>`. No delta may remain `pending`.

### Step 12: Update intent status + commit injector-side changes

Edit `/root/nvidia-driver-injector/docs/patch-intents/<patch-id>.md`:

- Frontmatter: flip `status: draft → reviewed`.

Optionally regenerate the patch index (or defer to Task 14):

```bash
cd /root/nvidia-driver-injector
tools/render-patch-index.sh
```

Final commit of the injector-side changes:

```bash
cd /root/nvidia-driver-injector
git add docs/patch-intents/<patch-id>.md \
        docs/patch-reviews/<patch-id>.md \
        patches/<layer>/<patch-id>.patch \
        docs/patch-index.md
git commit -m "$(cat <<'EOF'
review: <patch-id> v2 reviewed

Intent file authored against v2 normative shape; review file complete
with structured deltas all resolved; fork branch advanced to v2-tip
<v2_tip_sha>; composed patchset compiles; tests green.

EOF
)"
```

**Audit-reviewer subagent runs after Step 12** and either approves or returns issues. If issues, the review-implementer subagent loops back to the relevant step. Repeat until approved. Then the next task starts.

---

## Task 1: Setup — review-file template

**Files:**
- Create: `docs/patch-reviews/_template.md`

- [ ] **Step 1: Create the directory and template**

```bash
mkdir -p /root/nvidia-driver-injector/docs/patch-reviews
```

Create `docs/patch-reviews/_template.md`:

```markdown
<!--
  Canonical patch-review template for sub-cycle 2.

  Copy to docs/patch-reviews/<PATCH-ID>.md and fill in every placeholder.
  Keep the section order; deltas use the ### <id>-D<N> heading shape.
  Review files are NOT lint-checked in sub-cycle 2 — discipline is human.

  See docs/superpowers/specs/2026-05-23-sub-cycle-2-patch-deep-review-design.md
  for the full spec.
-->
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
```

- [ ] **Step 2: Sanity-check**

```bash
cd /root/nvidia-driver-injector
ls -la docs/patch-reviews/_template.md
head -20 docs/patch-reviews/_template.md
```

Confirm the file exists and renders readably.

- [ ] **Step 3: Commit**

```bash
cd /root/nvidia-driver-injector
git add docs/patch-reviews/_template.md
git commit -m "$(cat <<'EOF'
feat: add patch-review template for sub-cycle 2

Skeleton for per-patch v2 review files. Not lint-checked in this cycle
per the design spec. Authors copy this to docs/patch-reviews/<id>.md.

EOF
)"
```

---

## Task 2: C1-kbuild-version-mk (methodology checkpoint patch)

**Bindings:**

- `<patch-id>`: `C1-kbuild-version-mk`
- `<layer>`: `base`
- `<source-branch>`: `c1-kbuild-version-mk`
- `<related-patches>`: `[]` (kbuild metadata is independent of other patches)

Apply the **per-patch workflow** (above), Steps 1–12.

Suggested upstream-candidacy: `high` (kbuild metadata is the simplest C-set patch; upstream-friendly).

Suggested telemetry-tier: `none` (no runtime behaviour, no log events expected; the Telemetry contract section may be a single line: `_No runtime telemetry — build-time metadata only._`).

After the audit-reviewer approves, the controller proceeds to Task 3 (methodology checkpoint).

---

## Task 3: Methodology checkpoint (user gate)

**Files:** none (this is a gate task).

- [ ] **Step 1: Surface the C1 outputs for review**

The controller pauses and presents to the user:

- The committed intent file at `docs/patch-intents/C1-kbuild-version-mk.md`.
- The committed review file at `docs/patch-reviews/C1-kbuild-version-mk.md`.
- Any fork-branch commits made during Task 2 (likely zero or one).
- The audit-reviewer's final approval message.

Concrete questions for the user:

- Did the intent-file shape work? Anything missing or redundant?
- Did the review-file structure carry the right content?
- Were the deltas (or lack thereof) appropriately surfaced?
- Was anything about the methodology painful or confusing?
- Should the spec or this plan be amended before proceeding?

- [ ] **Step 2: User decision**

The user either:

- **Approves continuing** — proceed straight to Task 4.
- **Requests amendments** — the controller amends the spec/plan (commit), then proceeds. If the amendments touch the per-patch workflow or any Task 4–13's bindings, they are amended in the plan file before proceeding.

This task ends when the user gives explicit approval to continue with C2.

---

## Task 4: C2-aer-internal-unmask

**Bindings:**

- `<patch-id>`: `C2-aer-internal-unmask`
- `<layer>`: `base`
- `<source-branch>`: `c2-aer-internal-unmask`
- `<related-patches>`: `[C5-crash-safety]` (C5 also touches AER paths; C2 narrows the AER unmask to internal-error bits per `kernel-6_19_to_7_0_source_review`)

Apply the per-patch workflow.

Suggested upstream-candidacy: `medium`–`high` (narrow well-defined hardening; the 7.0 kernel ships `pci_aer_unmask_internal_errors()` but `EXPORT_SYMBOL_FOR_MODULES("cxl_core")`-restricted, so C2 hand-rolls the same surgical effect for nvidia.ko).

Suggested telemetry-tier: `nominal` (mode-change-time log line confirming the unmask).

---

## Task 5: C3-gpu-lost-retry

**Bindings:**

- `<patch-id>`: `C3-gpu-lost-retry`
- `<layer>`: `base`
- `<source-branch>`: `c3-gpu-lost-retry`
- `<related-patches>`: `[C5-crash-safety]` (C5 covers dead-bus reads on other call sites; C3 is the `osHandleGpuLost` preflight)

Apply the per-patch workflow.

Suggested upstream-candidacy: `high` (the headline #979 fix).

Suggested telemetry-tier: `mandatory` (silent retry recovery would be invisible without the `dev_warn` "transient bus read recovered after %d retries" line; this is the C3 mandatory-telemetry rationale captured in the schema's example).

Vanilla baseline hint: `kernel-open/nvidia/os-mlock.c:osHandleGpuLost` (per the schema's concrete example).

---

## Task 6: C4-err-handlers-scaffold

**Bindings:**

- `<patch-id>`: `C4-err-handlers-scaffold`
- `<layer>`: `base`
- `<source-branch>`: `c4-err-handlers-scaffold`
- `<related-patches>`: `[E1-egpu-detection, C5-crash-safety]` (C4 registers the `pci_error_handlers`; E1's eGPU detection and C5's crash-safety scaffolding both depend on the registered handlers)

Apply the per-patch workflow.

Suggested upstream-candidacy: `high` (vanilla nvidia.ko registers no `pci_error_handlers`; this is the load-bearing scaffolding for any subsequent PCIe error handling).

Suggested telemetry-tier: `nominal` (registration confirmation log; per-event logs come from the handlers in C5/A2/A3).

---

## Task 7: E1-egpu-detection

**Bindings:**

- `<patch-id>`: `E1-egpu-detection`
- `<layer>`: `base`
- `<source-branch>`: `e1-egpu-detection`
- `<related-patches>`: `[C4-err-handlers-scaffold]` (E1 builds on C4's registered handlers; eGPU detection drives behaviour in those handlers)

Apply the per-patch workflow.

Suggested upstream-candidacy: `medium`–`high` (vanilla `RmCheckForExternalGpu` keys on TB3 bridge vendor IDs and misses TB4/USB4; E1 detects TB4/USB4 too, replacing the project's earlier `RmForceExternalGpu=1` cmdline override).

Suggested telemetry-tier: `nominal` (one log line at probe time naming the detected external transport).

---

## Task 8: C5-crash-safety

**Bindings:**

- `<patch-id>`: `C5-crash-safety`
- `<layer>`: `base`
- `<source-branch>`: `c5-crash-safety`
- `<related-patches>`: `[C2-aer-internal-unmask, C3-gpu-lost-retry, C4-err-handlers-scaffold]` (C5 sits on top of C2/C3/C4; covers dead-bus reads on `osDevReadReg*`, RPC paths, cleanup paths that C3 does not)

Apply the per-patch workflow.

Suggested upstream-candidacy: `high` (the de-branded primitives — `os_pci_set_disconnected`, `nv-gpu-lost.h` — are reusable infrastructure even for upstream consumers).

Suggested telemetry-tier: `nominal` (per-site recovery log; the primitives carry mandatory-tier semantics already captured by C3).

---

## Task 9: A1-pcie-primitives

**Bindings:**

- `<patch-id>`: `A1-pcie-primitives`
- `<layer>`: `addon`
- `<source-branch>`: `a1-pcie-primitives`
- `<related-patches>`: `[A2-bus-loss-watchdog, A3-recovery, A4-close-path-telemetry]` (A1 is the foundation A2/A3/A4 reach into — the addon-recarve carved this out specifically; see the addon-recarve design spec)

Apply the per-patch workflow.

Suggested upstream-candidacy: `n/a` (addon — project-local primitives that wrap PCIe operations; not upstream-bound).

Suggested telemetry-tier: `nominal` (primitive entry/exit; consumers add behaviour-specific logs).

**Critical:** because A1 is the foundation that A2–A4 consume, any A1 delta affects downstream tasks. The audit-reviewer must catch ABI/API drift between A1 and A2–A4 consumers.

---

## Task 10: A2-bus-loss-watchdog

**Bindings:**

- `<patch-id>`: `A2-bus-loss-watchdog`
- `<layer>`: `addon`
- `<source-branch>`: `a2-bus-loss-watchdog`
- `<related-patches>`: `[A1-pcie-primitives, A3-recovery]` (A2 consumes A1's primitives; A2's detection drives A3's recovery)

Apply the per-patch workflow.

Suggested upstream-candidacy: `n/a` (addon — project-local watchdog kthread; specific to the eGPU surprise-removal failure mode).

Suggested telemetry-tier: `mandatory` (silent bus-loss without a log would be untraceable; the watchdog must announce trigger events with severity).

---

## Task 11: A3-recovery

**Bindings:**

- `<patch-id>`: `A3-recovery`
- `<layer>`: `addon`
- `<source-branch>`: `a3-recovery`
- `<related-patches>`: `[A1-pcie-primitives, A2-bus-loss-watchdog]` (A3 consumes A1's primitives; A2 triggers A3's recovery via post-rmInit-FAIL detection)

Apply the per-patch workflow.

Suggested upstream-candidacy: `n/a` (addon — Lever M-recover stack: `pci_reset_bus` + explicit err_handlers dispatch + bridge-link-cap preservation; first real fire 2026-05-08 per project memory).

Suggested telemetry-tier: `mandatory` (recovery success / surrender / attempt count must be observable; the `tb_egpu_recover_surrenders` counter feeds the standing soak gate).

**Critical:** A3's intent should explicitly state that "PEX Reset and Recovery is in scope" — the lever was promoted from deferred to in-scope per the standing `feedback_pex_recovery_in_scope`. The intent should also acknowledge the design boundary against M-preserve (BAR1 sizing preservation across reset) — out of scope unless the audit surfaces a need.

---

## Task 12: A4-close-path-telemetry

**Bindings:**

- `<patch-id>`: `A4-close-path-telemetry`
- `<layer>`: `addon`
- `<source-branch>`: `a4-close-path-telemetry`
- `<related-patches>`: `[A1-pcie-primitives, A3-recovery]` (A4 instruments A1's close path; A3 references A4's events when recovery interleaves with close)

Apply the per-patch workflow.

Suggested upstream-candidacy: `n/a` (addon — close-path observability; complements A3's recovery telemetry).

Suggested telemetry-tier: `mandatory` (the close-path bug class — patch 0029 — was discovered specifically because close-path wedges were silent; the telemetry IS the mitigation).

---

## Task 13: A5-version-and-toggles

**Bindings:**

- `<patch-id>`: `A5-version-and-toggles`
- `<layer>`: `addon`
- `<source-branch>`: `a5-version-and-toggles`
- `<related-patches>`: `[]` (version metadata and CONFIG_NV_TB_EGPU toggle are independent of other patches)

Apply the per-patch workflow.

Suggested upstream-candidacy: `n/a` (addon — `-aorus.NN` version string + `CONFIG_NV_TB_EGPU` build flag are project branding).

Suggested telemetry-tier: `none` (version metadata; printed at module load, not behavioural telemetry).

---

## Task 14: Cross-patch consistency audit + final index regenerate

**Files:**

- Modify: `docs/patch-index.md` (regenerate)
- Audit: every `docs/patch-intents/<id>.md` cross-reference resolves correctly

- [ ] **Step 1: Run a final intent-lint sweep**

```bash
cd /root/nvidia-driver-injector
tools/intent-lint.sh; echo "exit=$?"
```

Expected: `exit=0`. All 11 intents lint clean, including Rule 6 (`related-patches:` resolution).

- [ ] **Step 2: Cross-patch consistency check (manual or via subagent)**

Audit:

- **A1 primitives ↔ A2–A4 consumers.** Read A1's intent + the consuming intents (A2, A3, A4). Confirm consumers cite the primitives A1 actually exposes. Any disagreement is a delta-worthy bug; surface it as a follow-on commit on the relevant fork branch (and record it as a delta in the relevant review file with `Resolution: applied as <SHA>`).
- **C4 handlers ↔ E1 + C5 consumers.** Same check.
- **C2/C3 ↔ C5 coverage.** C5's Scope boundary should cite which call sites C2/C3 do NOT cover, and C2/C3's Scope boundary should reference C5 for those.
- **`related-patches:` set is symmetric.** If C3 lists C5 as related, C5 should list C3 (Rule 6 only checks that the referenced file exists, not symmetry; this is a human-judgment check).

Dispatching a dedicated audit subagent (Opus) for this is reasonable; the prompt asks them to scan all 11 intents for cross-reference drift and surface any inconsistencies.

- [ ] **Step 3: Regenerate patch-index**

```bash
cd /root/nvidia-driver-injector
tools/render-patch-index.sh
cat docs/patch-index.md
```

Expected: 11 rows with real content (no "(intent file missing)"). Each row shows `id`, `layer`, `upstream-candidacy`, `telemetry-tier`, `status: reviewed`, and the first paragraph of `## Purpose`.

- [ ] **Step 4: Compile + test gates one more time**

```bash
cd /root/nvidia-driver-injector
tools/validate-patchset.sh; echo "exit=$?"
bash tests/run.sh; echo "exit=$?"
```

Both should be `exit=0`.

- [ ] **Step 5: Commit**

```bash
cd /root/nvidia-driver-injector
git add docs/patch-index.md
git commit -m "$(cat <<'EOF'
feat: regenerate patch-index with all 11 v2 reviews populated

All 11 fork-branch patches reviewed; intent files at status: reviewed;
docs/patch-index.md now shows real content for every row.

EOF
)"
```

(If cross-patch audit surfaces inconsistencies that need fork-branch follow-ups, those land as additional per-patch commits before this final commit. The audit doesn't necessarily produce its own commit beyond the index regenerate.)

---

## Task 15: Final cross-branch review

**Files:** none directly — this task dispatches a single Opus subagent to review the full `feature/v2-patch-reviews` branch as a unified whole.

- [ ] **Step 1: Dispatch the final reviewer**

Dispatch one Opus subagent with this brief:

```
Final cross-branch code review of the sub-cycle 2 implementation on
feature/v2-patch-reviews in /root/nvidia-driver-injector.

BASE: main (commit before the branch diverged — likely acfc713).
HEAD: current tip of feature/v2-patch-reviews.

Spec: docs/superpowers/specs/2026-05-23-sub-cycle-2-patch-deep-review-design.md
Plan: docs/superpowers/plans/2026-05-23-patch-v2-reviews.md

Assess:

1. All 11 patches have intent files at docs/patch-intents/<id>.md, lint
   clean, status: reviewed.
2. All 11 patches have review files at docs/patch-reviews/<id>.md, every
   delta has explicit Resolution.
3. Each fork branch (apnex/open-gpu-kernel-modules) shows v2 commits with
   delta IDs in commit messages.
4. patches/<layer>/<id>.patch refreshed for every patch with a non-zero
   delta count.
5. docs/patch-index.md shows real content for all 11 rows.
6. tools/validate-patchset.sh passes (compile gate).
7. bash tests/run.sh green.
8. Cross-patch consistency: A1 primitives ↔ A2-A4 consumers; C4 handlers
   ↔ E1/C5; C2/C3 ↔ C5; related-patches symmetry.
9. Spec coverage: every "in scope" item from the spec is delivered; no
   "out of scope" items snuck in.
10. Quality: no obvious gaps, contradictions, or weak intents.

Report:
- Overall verdict: Ready to merge | Mergeable with caveats | Needs more work
- Strengths
- Concerns (Critical / Important / Minor)
- Per-patch audit table (one row per patch, ok/concern/blocker)
- Recommendation on merge readiness
```

- [ ] **Step 2: Handle review outcome**

If the final reviewer approves: proceed to Task 16.

If the final reviewer surfaces Critical or Important issues: the controller dispatches a fix subagent (Opus) to address them, the audit-reviewer pass repeats, and Task 15 re-runs. Iterate until approved.

---

## Task 16: Finishing

**Files:** none — this triggers `superpowers:finishing-a-development-branch`.

- [ ] **Step 1: Verify branch state**

```bash
cd /root/nvidia-driver-injector
git status
bash tests/run.sh; echo "exit=$?"
tools/validate-patchset.sh; echo "exit=$?"
git log --oneline main..HEAD | wc -l
```

Expected: clean tree, tests green, compile gate green, ~13+ commits on the branch (Task 1 + 11 per-patch tasks + Task 14 + possibly more from review-loop fixes).

- [ ] **Step 2: Invoke superpowers:finishing-a-development-branch**

Per the standing project pattern (matching sub-cycle 1), present the 4 finishing options to the user with a recommendation. The natural call is merge-to-main locally (this branch is the foundation for downstream production-migration steps 5–7 picking up the v2 set in the next aorus image build).

- [ ] **Step 3: Update memory after merge**

After merge to `main`, update the auto-memory entry capturing sub-cycle 2's completion (similar to the sub-cycle 1 memory update done at the end of that cycle).

- [ ] **Step 4: Surface follow-on work**

Remind the user of the natural successors:

- `production-migration.md` steps 5–7: build the next aorus image; ≥14-day soak; cutover.
- Post-soak: flip all 11 intents from `reviewed → approved` (single commit or per-patch).
- After approval: lift the no-premature-upstream-filing gate for the C-set + E1; prepare upstream PR bodies anchored in the intent files.

---

## Self-review summary

**Spec coverage:** every "in scope" item from the design spec maps to at least one task. The 11-step per-patch workflow from the spec is implemented as the 12-step workflow above (1 extra: a sanity-lint-full step after writing the intent, catching cross-file issues early). Subagent topology matches spec. Done gates match. Branch strategy matches.

**Placeholder scan:** no TBDs or TODOs in the plan. The per-patch tasks intentionally leave specific delta content un-prescribed (because deltas surface during the review — that IS the review). Every other step has concrete commands and expected outputs.

**Type/name consistency:** `<patch-id>`, `<layer>`, `<source-branch>`, `<related-patches>` bindings are consistent across the per-patch workflow and all 11 task headers. Path conventions (`docs/patch-intents/<id>.md`, `docs/patch-reviews/<id>.md`, `patches/<layer>/<id>.patch`) are uniform. Tool invocations (`tools/intent-lint.sh`, `tools/regen-base-patches.sh`, `tools/validate-patchset.sh`, `tools/render-patch-index.sh`) match the live filenames on `main`.

---

## Deferred follow-ups (sub-cycle 2 close-out)

These items were surfaced during the cycle and consciously deferred. They are not blocking sub-cycle 2's done-gate but should be tracked across cycle boundaries.

| Item | Origin | Disposition |
|---|---|---|
| **Rename `tb_egpu_recover_*` → `tb_egpu_pcie_*`** symbol prefix. 4 of 5 A1 helpers carry a legacy `_recover_` infix from the pre-recarve filename; helpers now live in `nv-tb-egpu-pcie.c` and serve A2/A3/A4 (only one of which is recovery). Atomic rename across A1+A2+A3+A4 fork branches required. | A1-D1 (`docs/patch-reviews/A1-pcie-primitives.md`) | Defer to a future naming-consistency mini-initiative. Cosmetic; zero must-fix urgency. |
| **Hoist `tb_egpu_dump_aer_trigger_event` call site** from A3-patches-into-A2 to A2-owns-it. Current shape: A3 adds a one-line dump call into A2's `tb_egpu_qwd_thread` because A3 owns the consumer state machine. Alternative: A2 owns the call and writes into its own `qwd->last_aer` directly. | A2-D1 / A3-D3 | Defer. A3's review accepted the cross-TU patching shape as correct (consumer-owns-call). Revisit only if a future A2/A3 refactor surfaces a cleaner seam. |
| **Detection counter semantics drift in A2.** The `detections` counter increments per dead-bus *cycle* within an episode rather than per *episode*. Documented vs. actual semantics mismatch is a diagnostic-surface clarity issue, not a correctness bug. Single-eGPU deployment makes wrap-at-INT_MAX (~13 years at 5 Hz) a non-concern. | A2-D2 (`docs/patch-reviews/A2-bus-loss-watchdog.md`) | Defer to a future operational-cleanup pass; check whether watchdog daemon consumers rely on current semantics first. |
| **`tools/regen-base-patches.sh` timestamp churn.** The script writes `patches/base/.regen-state` with a fresh timestamp on every run even when no patch content changes. Per-patch implementers worked around by `git checkout -- patches/base/.regen-state` before commit. | Surfaced by C4 / E1 / multiple implementer reports | Fix candidate: content-hash gate on `.regen-state` write. Small follow-up; not blocking. |
| **`tb_egpu_get_gpu_pdev` is single-pdev.** A4's userspace-facing helper assumes one eGPU; multi-eGPU deployment would need a per-fd pdev lookup, which is a UVM-side fd-table refactor outside A4's scope. | A4-D1 (`docs/patch-reviews/A4-close-path-telemetry.md`) | Defer pending hardware reality (project ships single-eGPU). Documented in intent. |
| **UVM `fd_count` is module-global.** Same multi-eGPU boundary as A4-D1. | A4-D2 | Defer. |
| **Schema-doc illustrative-anchor audit.** The vanilla-source anchor on line 56 was found wrong mid-cycle (commit `4307f3b`). Suggests other illustrative anchors in `docs/patch-intent-schema.md` deserve a spot-check before sub-cycle 3. | Final cross-branch review | Spot-check before sub-cycle 3 brainstorming begins. |

## Reverse-edge `related-patches:` convention

The schema's Rule 6 enforces **forward-only** cross-reference resolution: if A's frontmatter lists B, B's file must exist, but B's frontmatter is NOT required to list A. This is by design — reverse edges (where the related patch *is the consumer*, not the dependency) live in body prose via `[[<id>]]` wikilinks when meaningful. Captured in the schema doc's "Frontmatter" table after the cycle's cross-patch audit pass surfaced the asymmetry.
