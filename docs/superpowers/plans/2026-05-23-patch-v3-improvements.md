# Sub-cycle 3 — Multi-Lens Improvement Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Triage and apply genuinely valuable improvements to the 11 fork-branch patches (`C1`–`C5`, `E1`, `A1`–`A5`) across 8 quality lenses, anchored in triangulation against vanilla NVIDIA + v2 intent + aorus-5090 archaeology + community signal. Default reject; bar is "must deliver more than it costs."

**Architecture:** One Task 0 (community-signal recon) feeds the per-patch reviews. A canonical 11-step per-patch workflow is defined below; Tasks 2 and 4–13 apply it to one patch each with patch-specific bindings. Strict serial in dependency order. 2-subagent topology per patch (review-implementer + audit-reviewer) plus a final cross-branch reviewer. Methodology checkpoint after the C3 pilot.

**Tech Stack:** v1.0 patch-intent schema from sub-cycle 1; v2 intent + review files from sub-cycle 2; existing bash tooling (`intent-lint`, `regen-base-patches`, `validate-patchset`, `render-patch-index`); `gh` CLI for community-signal recon; git for fork-branch commits.

---

## Context & scope

Implements `docs/superpowers/specs/2026-05-23-sub-cycle-3-multi-lens-improvement-sweep-design.md` — **read that spec first**.

**Delivered here:**

- 11 improvement-catalog files at `docs/patch-improvements/<id>.md` — status: `accepted`, every candidate triaged.
- 1 improvement-catalog template at `docs/patch-improvements/_template.md`.
- 1 cross-patch findings doc at `docs/patch-improvements/_cross-patch.md`.
- 1 community-signal recon doc at `docs/patch-improvements/_community-signal.md`.
- Updated intent files at `docs/patch-intents/<id>.md` where triangulation surfaces substantive normative gaps (each as a precursor commit).
- Fork-branch v2→v3 commits on `apnex/open-gpu-kernel-modules` for landed code improvements (each cites its `<patch-id>-I<N>` improvement ID in the subject).
- Refreshed `patches/<layer>/<id>.patch` files via regen where code changes land.

**Out of scope (per spec):**

- Hardware behavioural validation; `aorus.NN` rebuild; the soak.
- The `status: reviewed → approved` intent flip.
- NVIDIA upstream PR submission.
- Schema (v1.0) changes.
- A1-D1 rename atomic-sweep (`tb_egpu_recover_*` → `tb_egpu_pcie_*`).
- `tools/regen-base-patches.sh` content-hash gate fix.
- A2-D1 hoist of `tb_egpu_dump_aer_trigger_event` call site.

**Working state:** branch `feature/v3-patch-improvements` (already created, off `main`; spec already committed at `4a524db`). Fork repo at `/root/open-gpu-kernel-modules`; aorus-5090 archaeology repo at `/root/aorus-5090-egpu`.

## File structure

| File | Responsibility | Created in |
|---|---|---|
| `docs/patch-improvements/_template.md` | Catalog skeleton; copied by per-patch reviewers | Task 1 |
| `docs/patch-improvements/_community-signal.md` | Pre-pilot recon output: #979/#981 activity + related issues + upstream activity, last 3 weeks | Task 0 |
| `docs/patch-improvements/<id>.md` | Per-patch improvement triage catalog | Tasks 2 + 4–13 |
| `docs/patch-intents/<id>.md` | Updated where substantive intent changes land (precursor commits) | Tasks 2 + 4–13 (selective) |
| `patches/<layer>/<id>.patch` | Regenerated where code improvements land | Tasks 2 + 4–13 (selective; regen step) |
| `docs/patch-improvements/_cross-patch.md` | Cross-patch surface-lens findings + atomic-sweep recommendations | Task 14 |

---

## Per-patch workflow (canonical 11-step procedure)

**Tasks 2 and 4–13 each execute this workflow against one patch.** Each task's header provides the **bindings**:

- `<patch-id>` — manifest id (e.g. `C3-gpu-lost-retry`).
- `<layer>` — `base` or `addon`.
- `<source-branch>` — fork branch name (without `fork:` prefix).
- `<aorus-ancestor>` — corresponding aorus-5090 patch filename (e.g. `patches/0001-osHandleGpuLost-retry-on-transient-pcie-failure.patch`).
- `<aorus-docs>` — relevant aorus-5090 design/investigation docs (per patch — see each task's bindings).

**Subagent topology:** the review-implementer subagent (Opus) executes steps 1–11. The audit-reviewer subagent (Opus) then verifies the outputs independently. Loop until approved.

### Step 1: Read vanilla NVIDIA source + capture v1-tip-sha

```bash
cd /root/open-gpu-kernel-modules
git checkout <source-branch>
v1_tip_sha="$(git rev-parse <source-branch>)"
echo "v1-tip-sha: $v1_tip_sha"
git diff 595.71.05 -- kernel-open/ | head -200
```

Identify every kernel-open/<file> touched by the patch. For each, read the vanilla version:

```bash
git show 595.71.05:kernel-open/<file>
```

Document the vanilla baseline locations as scratch notes for the triangulation-sources section in step 8.

### Step 2: Read fork-branch v1 hunks (v1+v2 sub-cycle 2 state)

```bash
cd /root/open-gpu-kernel-modules
git log --oneline <source-branch>
git show <source-branch>
```

Note: as of sub-cycle 2's close, `v1-tip-sha == v2-tip-sha` for all patches (zero-delta sentinel). Sub-cycle 3 introduces v3 commits on top.

### Step 3: Read v2 intent + review (conformance baseline)

```bash
cat /root/nvidia-driver-injector/docs/patch-intents/<patch-id>.md
cat /root/nvidia-driver-injector/docs/patch-reviews/<patch-id>.md
```

The v2 intent defines what the code SHALL do. The v2 review captures the rationale + deltas (mostly zero-delta with deferrals). Both feed the triangulation.

### Step 4: Read aorus-5090 archaeology (full depth)

```bash
cd /root/aorus-5090-egpu
# Ancestor patch
cat <aorus-ancestor>
# Design / investigation docs for this patch's problem class
cat <aorus-docs>
# Search for related entries in the reliability ledger
grep -nE "<bug-class-keywords>" docs/reliability-hypothesis-ledger.md
```

For each cited aorus-5090 source, capture:

- Original design intent — what the lever investigation actually intended.
- Constraints discovered during investigation (e.g. "delay of 100µs chosen because of X").
- Alternative implementations considered + rejected.
- Forgotten / latent invariants — load-bearing assumptions not yet captured in the v2 intent.

**Every claim in step 8's `## v1 archaeology` section MUST cite a specific aorus-5090 path + section (line ranges preferred — 5-line windows are audit-friendly).** The audit-reviewer enforces this.

**Methodology refinement from C3 pilot (M1+M2):** the `<aorus-docs>` binding in each task header is a **starting recommendation**, not a closed list. Before reading:

1. **Verify the lever letter** by grepping `lever-catalog.md` for the patch's actual bug class. The plan's binding may name the wrong lever (C3's pilot found "Lever P" was wrong — actual is Lever I).
2. **Drop irrelevant paths** if the document covers a different lever family. C3's pilot found `recovery.md` (operator runbook), `recovery-mechanism-findings.md` (Lever M, not Lever I), and `h17-g3-gen3-investigation-2026-05-07.md` (C2 territory) were not relevant despite being in the binding.
3. **Add omitted paths** if the actual ancestor cites docs the binding missed (C3 added `architecture-and-modularity.md` for sovereignty-lens grounding).

Document the actual sources consulted in §Triangulation sources of the catalog. Audit-reviewer cross-checks.

### Step 5: Read community-signal entries tagged for this patch

```bash
grep -A 5 "patches:.*<patch-id>" /root/nvidia-driver-injector/docs/patch-improvements/_community-signal.md
```

Capture any community / maintainer / upstream signal that affects this patch. Tag each as: bug-class-variant / engineering-feedback / conflict-detection / outreach-response.

### Step 6: Apply 8 lenses; surface improvement candidates

For each of the 8 lenses, ask: *does the patch have a gap?*

**Structural lenses (per-patch deep):**
- **Sovereignty** — blast radius concentrated?
- **Robustness** — error paths, lifetime, races, edge cases?
- **Duty** — single-responsibility intact?
- **Invariant clarity** — non-obvious invariants explicit?

**Surface lenses (cross-patch comparative — surface notes here; cross-patch aggregation lands in Task 14):**
- **Deduplication** — primitives copied elsewhere?
- **Naming** — symbols, log strings consistent with the stack?
- **Performance** — algorithmic / memory / hot-path tightening?
- **Quality** — comments, log levels, error messages, idioms?

For each candidate that surfaces, capture:

- **Lens** that surfaced it.
- **Current state** (code excerpt or intent reference).
- **Proposed state** (what changes).
- **Value** — concrete gain.
- **Cost** — LoC delta, complexity delta, risk delta.
- **Verification mode** (A for code-reading, B for exact observable).
- **Intent impact** — none / refine Scenario / add Requirement.

### Step 7: Triage each candidate on value × cost

| Value | Cost | Disposition |
|---|---|---|
| High | Low | **Land** |
| High | High | Defer or design as its own initiative |
| Low | Low | Case-by-case; **default reject** unless removes real footgun |
| Low | High | Hard reject |

Triage decision for every candidate: `land` / `defer` / `reject`. No `pending` is allowed in the final catalog.

### Step 8: Write `docs/patch-improvements/<patch-id>.md`

```bash
cp /root/nvidia-driver-injector/docs/patch-improvements/_template.md \
   /root/nvidia-driver-injector/docs/patch-improvements/<patch-id>.md
```

Edit the new file:

- **Frontmatter (7 fields):**
  - `id: <patch-id>`
  - `review-date: 2026-05-DD` (today)
  - `reviewer: Claude Opus 4.7`
  - `v1-tip-sha: $v1_tip_sha` from step 1
  - `v2-tip-sha: pending` (filled in step 11)
  - `status: in-progress` (flips to `accepted` in step 11)
  - `intent-updates: []` (list of intent precursor commit SHAs, populated in step 9)
- **Sections (8, in order):**
  1. `# <patch-id> — improvement triage` (top heading).
  2. `## Triangulation sources` — vanilla NVIDIA paths, v2 intent + review paths, aorus-5090 ancestor patch path, aorus-5090 docs cited (with section anchors), community-signal entries referenced.
  3. `## v1 archaeology` — what the aorus-5090 mining surfaced. Every claim cites a specific aorus-5090 source path + section.
  4. `## Improvements considered` — structured `### <patch-id>-I<N>` entries per the template; one entry per candidate.
  5. `## Improvements landed` — summary list, one line per landed improvement (with SHAs).
  6. `## Intent updates landed` — summary of intent edits (new Requirements, refined Scenarios, telemetry additions) with precursor commit SHAs.
  7. `## Done gate` — per-patch checklist.
  8. `## Cross-references` — intent, review, aorus-5090 ancestor, vanilla source, upstream issue, community-signal sources.

### Step 9: Land precursor commits for substantive intent updates

For each candidate with `Intent impact: refine Scenario <name>` or `add Requirement <name>` and triage `land`:

```bash
cd /root/nvidia-driver-injector
# Edit docs/patch-intents/<patch-id>.md to apply the substantive change.
tools/intent-lint.sh docs/patch-intents/<patch-id>.md; echo "exit=$?"  # must be 0
git add docs/patch-intents/<patch-id>.md
git commit -m "$(cat <<'EOF'
intent: <patch-id> add/refine <Requirement-or-Scenario-name>

Precursor for <patch-id>-I<N>. v1 does not yet satisfy this claim;
implementation follows in a subsequent commit on fork branch
<source-branch>.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
intent_commit_sha="$(git rev-parse HEAD)"
```

Capture `$intent_commit_sha` for the catalog's `intent-updates:` frontmatter and the improvement's `Resolution:` field.

For cosmetic intent changes (clarification, format string drift, link fix): defer to step 11's combined commit.

### Step 10: Apply land-tier code improvements as fork-branch commits

For each candidate with `Triage decision: land` requiring a code change:

```bash
cd /root/open-gpu-kernel-modules
git checkout <source-branch>
# Edit files per the candidate's Proposed state.
git add <files>
git commit -m "$(cat <<'EOF'
<patch-id>-I<N>: <one-line description from improvement title>

<Optional body citing catalog file path and Value excerpt.>

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
improvement_N_sha="$(git rev-parse HEAD)"
```

Push when all v3 commits for this patch are in:

```bash
cd /root/open-gpu-kernel-modules
git push origin <source-branch>
```

Then regen the injector's patch file:

```bash
cd /root/nvidia-driver-injector
tools/regen-base-patches.sh
git diff patches/<layer>/<patch-id>.patch
```

### Step 11: Compile gate + test gate + catalog closeout + commit

Run compile gate:

```bash
cd /root/nvidia-driver-injector
tools/validate-patchset.sh; echo "exit=$?"   # must be 0
```

Run test gate:

```bash
bash tests/run.sh; echo "exit=$?"   # must be 0; 8/16/10 expected
```

If either fails, the code change needs rework — return to step 10.

Update the catalog file (`docs/patch-improvements/<patch-id>.md`):

- Frontmatter: set `v2-tip-sha: $v2_tip_sha` (the new fork-branch tip from step 10's `git rev-parse <source-branch>`).
- Frontmatter: populate `intent-updates: [<sha1>, <sha2>, ...]` with intent-precursor commits from step 9.
- Frontmatter: flip `status: in-progress → accepted`.
- For each improvement: set `Resolution:` field per the outcome (`applied as <SHA>` / `precursor intent <SHA> + impl <SHA>` / `deferred to <follow-up>` / `rejected because <reason>`). No `pending` remains.
- Populate `## Improvements landed` and `## Intent updates landed` summary sections.

Final commit of injector-side closeout for this patch:

```bash
cd /root/nvidia-driver-injector
git add docs/patch-improvements/<patch-id>.md
# Include refreshed .patch if regen produced a diff:
if ! git diff --quiet patches/<layer>/<patch-id>.patch 2>/dev/null; then
    git add patches/<layer>/<patch-id>.patch
fi
# Include any cosmetic intent edits not landed as precursor:
if ! git diff --quiet docs/patch-intents/<patch-id>.md 2>/dev/null; then
    git add docs/patch-intents/<patch-id>.md
fi
git commit -m "$(cat <<'EOF'
improvement: <patch-id> v3 triage complete

Catalog: docs/patch-improvements/<patch-id>.md.
Improvements landed: <count> code-side, <count> intent-side.
Fork tip advanced to <v2_tip_sha>; composed patchset compiles; tests green.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

Audit-reviewer subagent runs after step 11; either approves or returns issues. Loop until approved.

---

## Task 0: Community-signal reconnaissance

**Files:**
- Create: `docs/patch-improvements/_community-signal.md`

Dispatches one Opus subagent for a scoped scan via the `gh` CLI. Time budget: ~30 minutes of subagent compute.

- [ ] **Step 1: Run the scan**

The subagent executes the following scan and writes the output:

```bash
# NVIDIA #979 activity since 2026-05-02:
gh issue view NVIDIA/open-gpu-kernel-modules/979 --comments \
  --json title,state,comments,updatedAt,labels
gh issue view NVIDIA/open-gpu-kernel-modules/981 --comments \
  --json title,state,comments,updatedAt,labels

# Related open issues in the 2026-05-02 → today window:
gh issue list --repo NVIDIA/open-gpu-kernel-modules --state open \
  --search "Blackwell OR eGPU OR Thunderbolt OR surprise-removal OR bus loss OR PCIe transient OR AER created:>=2026-05-02" \
  --json number,title,createdAt,updatedAt,labels

# NVIDIA upstream commits touching our patched files since 2026-05-02:
gh api -X GET /repos/NVIDIA/open-gpu-kernel-modules/commits \
  -f since=2026-05-02T00:00:00Z \
  -f path=kernel-open/nvidia/os-mlock.c
gh api -X GET /repos/NVIDIA/open-gpu-kernel-modules/commits \
  -f since=2026-05-02T00:00:00Z \
  -f path=src/nvidia/arch/nvalloc/unix/src/osinit.c
gh api -X GET /repos/NVIDIA/open-gpu-kernel-modules/commits \
  -f since=2026-05-02T00:00:00Z \
  -f path=kernel-open/nvidia/nv-pci.c
gh api -X GET /repos/NVIDIA/open-gpu-kernel-modules/commits \
  -f since=2026-05-02T00:00:00Z \
  -f path=kernel-open/nvidia/os-pci.c
```

- [ ] **Step 2: Write the recon doc**

Create `docs/patch-improvements/_community-signal.md` with this structure:

```markdown
---
generated: 2026-05-23
scope: NVIDIA/open-gpu-kernel-modules issues #979 + #981 + related; upstream commits 2026-05-02 → 2026-05-23
reviewer: Claude Opus 4.7
---

# Community signal — sub-cycle 3 pre-pilot reconnaissance

## #979 activity since 2026-05-02

- Comment <author> on <date>: <one-line summary>. Tagged patches: [C3, ...].
- Comment <author> on <date>: <one-line summary>. Tagged patches: [...].
- (or "no activity" if scan returns empty)

## #981 (closed PR) activity since 2026-05-02

- <activity or "no activity">

## Related open issues (2026-05-02 → today)

- Issue #<N> "<title>": <one-line of relevance>. Tagged patches: [...].
- (repeat per relevant issue; skip clearly-unrelated ones)

## NVIDIA upstream activity

### Commits touching our patched files

- `<file>`: <commit SHA> "<commit title>" (<date>). Conflict with: [<patch-id>, ...] / no conflict.
- (repeat per file)

## Direct responses to apnex outreach (comment-4514103926, 2026-05-22)

- <response or "no response yet">

## Summary

- Material findings: <count>. By lens: <robustness: N, ...>.
- Patches with tagged findings: [<patch-id>, ...].
- Conflict-detection: <count of upstream commits that touch our files>.
```

Tag every finding with its affected patch(es) so step 5 of the per-patch workflow can grep for them.

- [ ] **Step 3: Commit**

```bash
cd /root/nvidia-driver-injector
mkdir -p docs/patch-improvements
git add docs/patch-improvements/_community-signal.md
git commit -m "$(cat <<'EOF'
feat: community-signal reconnaissance for sub-cycle 3

Pre-pilot scan of NVIDIA #979/#981 activity, related issues, and
upstream commits in the 2026-05-02 → 2026-05-23 window. Findings
tagged per affected patch; feeds the per-patch triangulation in
subsequent tasks.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 1: Setup — improvement-catalog template

**Files:**
- Create: `docs/patch-improvements/_template.md`

- [ ] **Step 1: Create the template**

Create `docs/patch-improvements/_template.md`:

```markdown
---
id: PATCH-ID-HERE
review-date: 2026-05-DD
reviewer: Claude Opus 4.7
v1-tip-sha: SHA-BEFORE-V3-COMMITS
v2-tip-sha: pending
status: in-progress
intent-updates: []
---

# PATCH-ID-HERE — improvement triage

## Triangulation sources

- **Vanilla NVIDIA 595.71.05:** `kernel-open/<file>:<symbol>` (and other touched files).
- **v2 intent:** `docs/patch-intents/PATCH-ID-HERE.md`.
- **v2 review:** `docs/patch-reviews/PATCH-ID-HERE.md`.
- **aorus-5090 ancestor patch:** `/root/aorus-5090-egpu/patches/<filename>.patch`.
- **aorus-5090 docs:** `<paths + section anchors>`.
- **Community-signal entries:** `<section in _community-signal.md>` (or "none tagged").

## v1 archaeology

(What the aorus-5090 mining surfaced. Every claim MUST cite a specific
aorus-5090 source path + section.)

- **Original design intent:** <citation>
- **Constraints discovered:** <citation>
- **Alternatives considered + rejected:** <citation>
- **Forgotten / latent invariants:** <citation>

## Improvements considered

### PATCH-ID-HERE-I1 — Example improvement title

- **Lens:** sovereignty | robustness | dedup | duty | naming | performance | quality | invariant clarity
- **Current state:** <code excerpt or intent reference>
- **Proposed state:** <what changes>
- **Value:** <concrete: correctness / robustness / clarity / perf gain>
- **Cost:** <LoC delta, complexity delta, risk delta>
- **Verification mode:** A (code-reading) | B (observable assertion)
- **Intent impact:** none | refine Scenario <name> | add Requirement <name>
- **Triage decision:** land | defer | reject
- **Resolution:** pending

(repeat for each improvement; if no improvements surface, replace with
"(no improvements surfaced — v2 already meets v3 quality bar)")

## Improvements landed

(populate in step 11 — one line per landed improvement with SHAs)

## Intent updates landed

(populate in step 11 — one line per intent edit with precursor commit SHAs)

## Done gate

- [ ] Every candidate improvement has explicit `Resolution:` (no `pending`).
- [ ] All "land" improvements applied as fork-branch commits citing their `<id>-I<N>` IDs.
- [ ] Substantive intent updates landed as precursor commits.
- [ ] `tools/intent-lint.sh` passes.
- [ ] `tools/validate-patchset.sh` passes.
- [ ] `bash tests/run.sh` green.
- [ ] Audit-reviewer subagent approved.

## Cross-references

- Intent file: `docs/patch-intents/PATCH-ID-HERE.md`
- Review file: `docs/patch-reviews/PATCH-ID-HERE.md`
- Manifest row: `patches/manifest` line for `PATCH-ID-HERE`
- Vanilla baseline: `kernel-open/<dir>/<file>:<symbol>`
- Fork branch: `BRANCH-NAME-HERE` on `apnex/open-gpu-kernel-modules`
- aorus-5090 ancestor: `/root/aorus-5090-egpu/patches/<filename>.patch`
- Upstream issue: URL or "n/a"
- Community signal: `docs/patch-improvements/_community-signal.md` <section>
```

- [ ] **Step 2: Sanity-check**

```bash
cd /root/nvidia-driver-injector
ls -la docs/patch-improvements/_template.md
head -30 docs/patch-improvements/_template.md
```

- [ ] **Step 3: Commit**

```bash
cd /root/nvidia-driver-injector
git add docs/patch-improvements/_template.md
git commit -m "$(cat <<'EOF'
feat: add improvement-catalog template for sub-cycle 3

Skeleton for per-patch v3 improvement catalogs. Not lint-checked
(human judgment, mirroring sub-cycle 2's review-file pattern).
Authors copy to docs/patch-improvements/<id>.md.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: C3-gpu-lost-retry (methodology checkpoint pilot)

**Bindings:**

- `<patch-id>`: `C3-gpu-lost-retry`
- `<layer>`: `base`
- `<source-branch>`: `c3-gpu-lost-retry`
- `<aorus-ancestor>`: `patches/0001-osHandleGpuLost-retry-on-transient-pcie-failure.patch`
- `<aorus-docs>`:
  - `docs/recovery.md` (sections referencing dead-bus / preflight retry)
  - `docs/recovery-mechanism-findings.md`
  - `docs/reliability-hypothesis-ledger.md` (entries on transient PCIe / GPU-lost)
  - `docs/source-review-notes.md` (osHandleGpuLost coverage)
  - `docs/h17-g3-gen3-investigation-2026-05-07.md` (if relevant to PCIe transient root cause)

Apply the **per-patch workflow** (above), steps 1–11.

**Pilot stakes:** highest-priority patch (headline #979 fix). After audit-reviewer approves the catalog, the controller pauses for Task 3 (user gate). Apply the M3 Purpose-discipline reminder from sub-cycle 2: keep intent's `## Purpose` tight; historical context belongs in catalog's `## v1 archaeology`.

**Expected friction:** the aorus-5090 archaeology should surface why the retry constants (`NV_GPU_LOST_RETRY_COUNT = 10`, `NV_GPU_LOST_RETRY_DELAY_US = 100`) were chosen, and any considered-and-rejected alternatives (e.g. module_param tunability). Sub-cycle 2 found `0 must-fix, 2 nice-to-have` for C3. The v3 sweep may surface more given the deep aorus-5090 read.

After audit-reviewer approves: PAUSE for Task 3.

---

## Task 3: Methodology checkpoint (user gate)

**Files:** none (gate task).

- [ ] **Step 1: Surface C3 pilot outputs**

The controller presents to the user:

- `docs/patch-improvements/C3-gpu-lost-retry.md` (the catalog).
- Any intent precursor commits on the injector branch.
- Any fork-branch v3 commits (with their delta IDs).
- The audit-reviewer's final approval message.

Concrete questions for the user:

- Did the triangulation surface real value (above what sub-cycle 2 captured)?
- Did the 8-lens framework produce balanced findings, or did some lenses dominate / starve?
- Was the value × cost triage discipline appropriate, or did the bar shift implicitly?
- Was aorus-5090 archaeology load-bearing (genuine forgotten-constraint surfacing), or noise?
- Did community signal contribute (or was Task 0's recon empty)?
- Should the spec / plan be amended before C1 starts?

- [ ] **Step 2: User decision**

The user either:

- **Approves continuing** — proceed straight to Task 4 (C1).
- **Requests amendments** — controller amends spec/plan + the canonical workflow (commit) before continuing. If the methodology changes (e.g. drop a lens, adjust triage threshold), the C3 catalog may need a refresh.

This task ends when the user gives explicit approval to continue with C1.

---

## Task 4: C1-kbuild-version-mk

**Bindings:**

- `<patch-id>`: `C1-kbuild-version-mk`
- `<layer>`: `base`
- `<source-branch>`: `c1-kbuild-version-mk`
- `<aorus-ancestor>`: `patches/0005-version-mark-aorus-build.patch`
- `<aorus-docs>`:
  - `docs/patched-driver-runbook.md` (build-time identity)
  - `docs/recommended-install-path.md` (version handling)

Apply the per-patch workflow.

**Expected scope:** small. C1 is kbuild metadata. Lenses most likely to apply: naming, quality, invariant clarity. Likely zero code-side improvements; possible intent-side clarifications.

---

## Task 5: C2-aer-internal-unmask

**Bindings:**

- `<patch-id>`: `C2-aer-internal-unmask`
- `<layer>`: `base`
- `<source-branch>`: `c2-aer-internal-unmask`
- `<aorus-ancestor>`: (search aorus-5090 patches/ for AER unmask — likely `patches/0022-*` or similar; reviewer to identify in step 4)
- `<aorus-docs>`:
  - `docs/lever-catalog.md` (G3-H lever entry — AER unmask)
  - `docs/recovery.md` (AER role in recovery)
  - `docs/source-review-notes.md` (AER surface)
  - `docs/reliability-hypothesis-ledger.md` (AER-related hypotheses)

Apply the per-patch workflow.

**Expected scope:** medium. The kernel 7.0 `pci_aer_unmask_internal_errors()` symbol-restriction is the key context; reviewer should confirm the hand-roll matches what the kernel function does internally.

---

## Task 6: C4-err-handlers-scaffold

**Bindings:**

- `<patch-id>`: `C4-err-handlers-scaffold`
- `<layer>`: `base`
- `<source-branch>`: `c4-err-handlers-scaffold`
- `<aorus-ancestor>`: `patches/0007-nv-pci-register-error-handlers-Lever-M-base.patch`
- `<aorus-docs>`:
  - `docs/lever-M-recover-design.md` (Lever M base)
  - `docs/lever-M-recover-commit3-handover.md`
  - `docs/lever-M-recover-commit3-hardening-design.md`
  - `docs/recovery.md` (handler registration role)

Apply the per-patch workflow.

**Expected scope:** medium. C4's `pci_error_handlers` registration is the load-bearing scaffold. Lenses: sovereignty (does it register only what's needed?), robustness (state-aware `.error_detected` correctness), duty (does it cleanly delegate to C5/A3 for actual recovery?).

---

## Task 7: E1-egpu-detection

**Bindings:**

- `<patch-id>`: `E1-egpu-detection`
- `<layer>`: `base`
- `<source-branch>`: `e1-egpu-detection`
- `<aorus-ancestor>`: (search aorus-5090 — possibly no direct ancestor; the older repo used `RmForceExternalGpu=1` cmdline override instead of in-driver detection)
- `<aorus-docs>`:
  - `docs/tb4-pcie-topology.md` (TB4 / USB4 detection context)
  - `docs/source-review-notes.md` (`RmCheckForExternalGpu` analysis)
  - `docs/pcie-kernel-cmdline-options.md` (cmdline-based detection background)

Apply the per-patch workflow.

**Expected scope:** medium. E1 replaces the project's earlier `RmForceExternalGpu=1` cmdline workaround with in-driver detection. Lenses: sovereignty (single source of truth for external-ness), robustness (TB3 vs TB4 vs USB4 cases), naming (helper name `os_pci_is_thunderbolt_attached` — sub-cycle 2 flagged as narrower than behaviour).

---

## Task 8: C5-crash-safety

**Bindings:**

- `<patch-id>`: `C5-crash-safety`
- `<layer>`: `base`
- `<source-branch>`: `c5-crash-safety`
- `<aorus-ancestor>`: search aorus-5090 patches/ — multiple ancestors likely:
  - `patches/0002-journal-rcdbAddRmGpuDump-shortcircuit-and-relax-assert.patch`
  - `patches/0003-nvDumpAllEngines-break-on-gpu-lost.patch`
  - `patches/0004-resserv-cleanup-asserts-accept-gpu-lost.patch`
  - `patches/0006-rpcRmApiFree-GSP-shortcircuit-on-gpu-lost.patch`
  - `patches/0008-issueRpcAndWait-shortcircuit-on-gpu-lost-Lever-O.patch`
- `<aorus-docs>`:
  - `docs/recovery.md` (crash-safety role)
  - `docs/recovery-mechanism-findings.md`
  - `docs/source-review-notes.md` (per-callsite analysis)
  - `docs/lever-catalog.md` (G3 / G4 / G5 / Lever O entries)

Apply the per-patch workflow.

**Expected scope:** large. C5 consolidates multiple aorus-5090 ancestors into one upstream-bound primitives + per-site guards patch. Lenses: sovereignty (de-branded primitives are project-neutral), robustness (every covered call site has its dead-bus guard), dedup (are the primitives genuinely shared with A1 or duplicated?), naming (`os_pci_set_disconnected` etc. — match kernel idiom).

---

## Task 9: A1-pcie-primitives

**Bindings:**

- `<patch-id>`: `A1-pcie-primitives`
- `<layer>`: `addon`
- `<source-branch>`: `a1-pcie-primitives`
- `<aorus-ancestor>`: search aorus-5090 patches/ — the project-local primitives split out during the addon-recarve, originally part of Lever Q / Lever M's foundation:
  - `patches/0010-os-pci-is-disconnected-helpers-Lever-Q.patch`
  - `patches/0011-osDevReadReg032-Lever-Q-passive.patch`
  - `patches/0012-osDevReadReg008-016-Lever-Q-passive.patch`
- `<aorus-docs>`:
  - `docs/lever-Q-design.md`
  - `docs/lever-M-recover-design.md` (primitives consumed by Lever M)
  - `docs/recovery-mechanism-findings.md`

Apply the per-patch workflow.

**Expected scope:** medium-large. A1 is the foundation A2/A3/A4 consume. Lenses: sovereignty (does it expose only what consumers need?), invariant clarity (the 5 function signatures + struct ownership + constants are the load-bearing ABI — are invariants explicit?), naming (the `tb_egpu_recover_*` legacy infix from sub-cycle 2 A1-D1 — note that the atomic rename is OUT OF SCOPE for sub-cycle 3 per the spec).

---

## Task 10: A2-bus-loss-watchdog

**Bindings:**

- `<patch-id>`: `A2-bus-loss-watchdog`
- `<layer>`: `addon`
- `<source-branch>`: `a2-bus-loss-watchdog`
- `<aorus-ancestor>`:
  - `patches/0014-Lever-Q-watchdog-kthread.patch`
  - `patches/0015-Lever-Q-watchdog-sysfs-counters.patch`
- `<aorus-docs>`:
  - `docs/lever-Q-design.md`
  - `docs/lever-R-design.md` (kthread lifecycle considerations if applicable)
  - `docs/reliability-hypothesis-ledger.md` (watchdog effectiveness measurements)
  - `docs/recovery.md` (watchdog → recovery handoff)

Apply the per-patch workflow.

**Expected scope:** medium. A2 is the kthread-based watchdog. Lenses: robustness (atomic counter wrap, idle-burst boundary, kthread teardown), duty (PMC_BOOT_0 polling is correct boundary vs WPR2 polling which belongs to A3), naming (sysfs counter semantics), invariant clarity (when is `last_aer.valid` true?).

---

## Task 11: A3-recovery

**Bindings:**

- `<patch-id>`: `A3-recovery`
- `<layer>`: `addon`
- `<source-branch>`: `a3-recovery`
- `<aorus-ancestor>`:
  - `patches/0016-Lever-M-recover-scaffolding.patch`
  - `patches/0017-Lever-M-recover-probe-time-WPR2-detection.patch`
  - `patches/0018-Lever-M-recover-diagnostic-telemetry.patch`
- `<aorus-docs>`:
  - `docs/lever-M-recover-design.md`
  - `docs/lever-M-recover-commit3-handover.md`
  - `docs/lever-M-recover-commit3-hardening-design.md`
  - `docs/recovery-mechanism-findings.md`
  - `docs/recovery.md`

Apply the per-patch workflow.

**Expected scope:** large. A3 is the M-recover stack — most substantive addon. Lenses: robustness (`pci_reset_bus` semantics, attempt_count reset, surrender), invariant clarity (when does attempt_count reset — only post-rmInit-OK), performance (recovery hot path), duty (does A3 contain ONLY recovery? bridge-link-cap preservation is L4 userspace per sub-cycle 2).

---

## Task 12: A4-close-path-telemetry

**Bindings:**

- `<patch-id>`: `A4-close-path-telemetry`
- `<layer>`: `addon`
- `<source-branch>`: `a4-close-path-telemetry`
- `<aorus-ancestor>`:
  - `patches/0009-uvm-destroy-diagnostic-markers-Lever-P-probe.patch`
  - `patches/0020-Phase-A-PCIe-LnkSta-AER-telemetry.patch`
  - `patches/0021-G3-G-AER-Header-Log-capture.patch`
  - Plus any close-path-specific patches in archive/
- `<aorus-docs>`:
  - `docs/lever-catalog.md` (Phase A telemetry)
  - `docs/event-capture-methodology.md`
  - `docs/state-capture-methodology.md`
  - `docs/recovery-mechanism-findings.md` (close-path bug class)

Apply the per-patch workflow.

**Expected scope:** medium. A4 instruments the RM close-path + UVM fd tracking. Lenses: robustness (silent close-path wedges are exactly the bug class A4 prevents), duty (telemetry-only, no behavioural change), dedup (vs A3's recovery telemetry), naming (`tb_egpu_close_diag_pdev`, `tb_egpu_get_gpu_pdev` EXPORT_SYMBOL_GPL semantics).

---

## Task 13: A5-version-and-toggles

**Bindings:**

- `<patch-id>`: `A5-version-and-toggles`
- `<layer>`: `addon`
- `<source-branch>`: `a5-version-and-toggles`
- `<aorus-ancestor>`: (aorus-5090 used the legacy `patches/0005-version-mark-aorus-build.patch` shape; reviewer to confirm)
- `<aorus-docs>`:
  - `docs/architecture-and-modularity.md` (CONFIG_NV_TB_EGPU toggle role)
  - `docs/recommended-install-path.md` (version handling)

Apply the per-patch workflow.

**Expected scope:** small. A5 is version-stamp + reserved toggle declaration. Lenses: duty (CONFIG_NV_TB_EGPU is documentation-only in v1 — is that still right, or should it actually gate something?), naming (`aorus.NN` convention).

---

## Task 14: Cross-patch surface-lens audit + final index regenerate

**Files:**
- Create: `docs/patch-improvements/_cross-patch.md`
- Modify: `docs/patch-index.md` (regenerate if any intent updates landed)

- [ ] **Step 1: Aggregate surface-lens findings**

For each surface lens (dedup, naming, performance, quality), read every per-patch catalog's improvements with that lens. Aggregate into cross-patch patterns.

```bash
cd /root/nvidia-driver-injector
grep -hE "^\*\*Lens:\*\* (dedup|naming|performance|quality)" docs/patch-improvements/*.md
```

- [ ] **Step 2: Write `_cross-patch.md`**

```markdown
---
generated: 2026-05-DD
reviewer: Claude Opus 4.7
---

# Cross-patch surface-lens findings — sub-cycle 3

## Deduplication patterns

- Pattern: <description>. Affects: [<patch-id>, ...]. Atomic-sweep recommendation: <land/defer/reject>.
- (repeat per pattern)

## Naming consistency

- Inconsistency: <description>. Affects: [<patch-id>, ...]. Recommendation: <land/defer/reject>.

## Performance opportunities

- Opportunity: <description>. Affects: [<patch-id>, ...]. Recommendation: <land/defer/reject>.

## Quality patterns

- Pattern: <description>. Affects: [<patch-id>, ...]. Recommendation: <land/defer/reject>.

## Atomic-sweep improvements (cross-patch landed)

- <description>. Commits: [<SHA>, ...].

## Atomic-sweep improvements (cross-patch deferred)

- <description>. Cited in: [<catalog-path>, ...]. Deferral rationale.
```

- [ ] **Step 3: Apply approved atomic-sweep improvements**

For each cross-patch finding triaged `land`, apply across all affected fork branches in lockstep. Each commit cites the cross-patch finding ID (e.g. `XPATCH-D1`). Push all affected branches. Regen affected `patches/<layer>/<id>.patch` files.

- [ ] **Step 4: Compile gate + test gate**

```bash
cd /root/nvidia-driver-injector
tools/validate-patchset.sh; echo "exit=$?"
bash tests/run.sh; echo "exit=$?"
```

- [ ] **Step 5: Regenerate patch-index if intent updates landed**

```bash
cd /root/nvidia-driver-injector
tools/render-patch-index.sh
```

- [ ] **Step 6: Commit**

```bash
cd /root/nvidia-driver-injector
git add docs/patch-improvements/_cross-patch.md
# Include refreshed patch files + index if regen produced diffs:
if ! git diff --quiet patches/; then
    git add patches/
fi
if ! git diff --quiet docs/patch-index.md; then
    git add docs/patch-index.md
fi
git commit -m "$(cat <<'EOF'
feat: cross-patch surface-lens audit (sub-cycle 3 Task 14)

Aggregated dedup / naming / performance / quality findings across the
11 per-patch catalogs. Landed atomic-sweep improvements: <count>.
Deferred / rejected: <count>.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: Final cross-branch review

**Files:** none directly — dispatches one Opus subagent.

- [ ] **Step 1: Dispatch the final reviewer**

```
Final cross-branch code review of sub-cycle 3 on
feature/v3-patch-improvements in /root/nvidia-driver-injector.

BASE: main (commit before the branch diverged — likely 7af8369).
HEAD: current tip of feature/v3-patch-improvements.

Spec: docs/superpowers/specs/2026-05-23-sub-cycle-3-multi-lens-improvement-sweep-design.md
Plan: docs/superpowers/plans/2026-05-23-patch-v3-improvements.md

Assess:

1. All 11 patches have improvement-catalog files at status: accepted, every
   candidate triaged (no pending).
2. _community-signal.md and _cross-patch.md both populated.
3. Triangulation discipline: every v1-archaeology claim cites a specific
   aorus-5090 path + section.
4. Triage discipline: value × cost grid applied consistently; default-reject
   bar held; bloat budget intact (composed patchset LoC delta tracked).
5. Intent updates: substantive ones landed as precursor commits BEFORE
   their code-side commits.
6. Fork-branch v3 commits all cite their improvement IDs in subject lines.
7. tools/validate-patchset.sh exit 0; bash tests/run.sh green.
8. Cross-patch atomic sweeps in _cross-patch.md applied or deferred with
   explicit rationale.
9. Spec coverage: every "in scope" item delivered; no "out of scope" items
   snuck in.
10. Quality of the per-patch catalogs: archaeology rigorous, lens
    application balanced, no lens dominating or starving.

Report:
- Overall verdict: Ready to merge | Mergeable with caveats | Needs more work.
- Strengths.
- Concerns (Critical / Important / Minor).
- Per-patch audit table (one row per patch + cross-patch row).
- Bloat-budget verdict: did the cycle keep net LoC delta in check?
- Recommendation on merge readiness.
```

- [ ] **Step 2: Handle outcome**

If approved → Task 16. If Critical/Important issues → fix subagent → audit re-runs → Task 15 re-runs. Iterate until approved.

---

## Task 16: Finishing

**Files:** none — triggers `superpowers:finishing-a-development-branch`.

- [ ] **Step 1: Verify branch state**

```bash
cd /root/nvidia-driver-injector
git status
bash tests/run.sh; echo "exit=$?"
tools/validate-patchset.sh; echo "exit=$?"
git log --oneline main..HEAD | wc -l
```

Expected: clean tree, tests green, compile gate green, 15+ commits on branch.

- [ ] **Step 2: Invoke superpowers:finishing-a-development-branch**

Present the 4 finishing options with a recommendation (matching sub-cycle 2's pattern). Natural call: merge-to-main locally + push to origin.

- [ ] **Step 3: Update memory**

After merge, update auto-memory with sub-cycle 3 completion entry — paths, commit range, key findings, deferred items if any new ones surfaced.

- [ ] **Step 4: Surface follow-on work**

Remind user of natural successors:

- `production-migration.md` steps 5–7: build next aorus image picking up v3 set; ≥14-day soak; cutover.
- Post-soak: flip all 11 intents from `reviewed → approved`.
- After approval: prepare NVIDIA upstream PRs for C1–C5 + E1 anchored in v3 intent files (with sub-cycle 3's improvement catalogs as engineering trace).
- Still-deferred from prior cycles: A1-D1 rename atomic-sweep; A2-D1 hoist; regen-base-patches.sh content-hash gate fix. Carry forward.

---

## Self-review summary

**Spec coverage:** every "in scope" item from the design spec maps to at least one task. The 11-step per-patch workflow from the spec matches Task 2 + 4–13's bindings. Triangulation inputs (4) are all present in per-patch workflow steps 1–5. The 8 lenses applied at step 6. Value × cost triage at step 7. Intent-optimisation flow (precursor commits) at step 9. Verification modes A/B in the catalog template.

**Placeholder scan:** no TBDs or TODOs. Per-patch tasks intentionally leave delta content un-prescribed (deltas surface during the review — that IS the review). aorus-5090 ancestor / docs bindings are concrete paths or explicit "reviewer to identify in step 4" notes where the mapping isn't 1:1.

**Type/name consistency:** `<patch-id>`, `<layer>`, `<source-branch>`, `<aorus-ancestor>`, `<aorus-docs>` bindings consistent across the canonical workflow and all task headers. Path conventions (`docs/patch-improvements/<id>.md`, `docs/patch-intents/<id>.md`, `docs/patch-reviews/<id>.md`, `patches/<layer>/<id>.patch`) uniform. Tool invocations match live filenames.

---

## Deferred follow-ups (carried from prior cycles)

Items deferred during sub-cycles 1+2 that this cycle does NOT address:

- A1-D1 rename `tb_egpu_recover_*` → `tb_egpu_pcie_*` (future naming-consistency initiative).
- A2-D1 hoist `tb_egpu_dump_aer_trigger_event` call site (architectural; preserved per sub-cycle 2 A3 review).
- A2-D2 detection counter wrap-guard / semantics clarification.
- `tools/regen-base-patches.sh` content-hash gate fix.
- Multi-eGPU refactor for A4's `tb_egpu_get_gpu_pdev` + UVM `fd_count` (deferred pending single-eGPU deployment assumption).
- Schema-doc illustrative-anchor audit (spot-check other anchors).

If sub-cycle 3's findings retire any of these, document in the per-patch catalog. Otherwise they continue to carry forward.
