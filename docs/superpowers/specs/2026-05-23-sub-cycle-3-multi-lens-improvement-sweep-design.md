# Sub-cycle 3 — Multi-lens triangulated improvement sweep (design)

**Status:** approved design — 2026-05-23. Third sub-cycle of the deep-review
initiative. Sub-cycle 1 built the patch-intent schema + tooling; sub-cycle 2
captured each patch's v2 normative intent and audited v1 conformance.
Sub-cycle 3 takes the v1==v2 fork-branch tips through a multi-lens
triangulated improvement sweep, applying high-value-low-cost improvements
to both code and intent in parallel.

## Context

Sub-cycle 2 converged 11 patches to `status: reviewed` with zero must-fix
deltas — every v1 fork-branch tip already met its v2 normative intent. The
zero-delta outcome reflects two things: (a) iteration N implementations
that have already absorbed earlier review cycles, and (b) a structural
self-confirmation bias in sub-cycle 2's methodology (the v2 intent was
authored after reading v1, so the conformance audit naturally found
convergence). See `docs/superpowers/specs/2026-05-23-sub-cycle-2-patch-deep-review-design.md`
§Risks for the original framing.

Sub-cycle 3 defeats the self-confirmation bias by **triangulating against
three baselines beyond v1**:

1. The v2 intent (sub-cycle 2 output) — useful as a conformance check.
2. The aorus-5090 repo's parallel implementation — different engineering
   choices for the same problem class, plus the investigation history that
   documents *why* each mechanism exists.
3. Community signal from NVIDIA issue #979 + related issues + upstream
   commits in the last 3 weeks — fresh independent input.

Plus a structured **multi-lens evaluation** of each patch against eight
quality dimensions (sovereignty / robustness / deduplication / duty /
naming / performance / quality / invariant clarity), with a value × cost
triage grid that defaults to *reject* and requires explicit justification
to land.

The cycle's framing constraint, per the user's direction: *"improvements
must deliver more than they cost — no bloat creep."*

## Goal

Identify and apply genuinely valuable improvements to the 11 fork-branch
patches across the 8 lenses, producing:

- **Per-patch improvement catalogs** at `docs/patch-improvements/<id>.md`
  documenting every candidate, its triage decision, and (where landed) its
  resolution.
- **Cross-patch findings** at `docs/patch-improvements/_cross-patch.md`
  for surface-lens patterns (dedup, naming, performance, quality) that
  span multiple patches.
- **Community-signal reconnaissance** at
  `docs/patch-improvements/_community-signal.md` from the pre-pilot scan
  (NVIDIA issue tracker + upstream activity, last 3 weeks).
- **Updated intent files** where triangulation surfaces normative gaps
  (new Requirements, refined Scenarios, telemetry contract additions).
- **Fork-branch v2→v3 commits** on `apnex/open-gpu-kernel-modules`
  carrying the landed code improvements.
- **Refreshed `patches/<layer>/<id>.patch`** files via regen.

## Scope

### In scope

- Triangulated reading of each patch: vanilla NVIDIA + v2 intent/review +
  aorus-5090 full-depth archaeology + community signal.
- Multi-lens evaluation across the 8 lenses (4 structural + 4 surface).
- Value × cost triage of every improvement candidate; default reject.
- Parallel intent + code updates where the triangulation surfaces
  intent-side gaps. Two-commit TDD discipline for substantive intent
  changes; single combined commit for cosmetic ones.
- Fork-branch follow-up commits applying "land" improvements, each
  citing its `<patch-id>-I<N>` improvement ID in the subject.
- Regen + compile + test gates at the per-patch done-gate.
- Cross-patch surface-lens audit + final cross-branch review.

### Out of scope

- Hardware behavioural validation; the `aorus.NN` rebuild; the ≥14-day
  soak. These remain `production-migration.md` steps 5–7.
- The `status: reviewed → approved` intent flip — still post-soak.
- NVIDIA upstream PR submission — gated by the standing
  no-premature-upstream-filing policy until soak completes.
- Schema (v1.0) changes. If the triangulation surfaces a real schema gap,
  pause and lift to a separate schema-v1.1 cycle.
- A1-D1 rename atomic-sweep (`tb_egpu_recover_*` → `tb_egpu_pcie_*` across
  A1+A2+A3+A4) — its own future naming-consistency initiative.
- `tools/regen-base-patches.sh` timestamp-churn fix — separate small
  follow-up.
- A2-D1 hoist of `tb_egpu_dump_aer_trigger_event` call site — preserved
  per sub-cycle 2 A3 review's "consumer owns the call" rationale.

## Architecture

**Methodology-once, execute-eleven-times.** This spec defines the per-patch
methodology; the writing-plans plan that follows breaks it into concrete
tasks (Task 0 community-signal recon; Task 1 setup; Task 2 C3 pilot; Task
3 methodology checkpoint; Tasks 4–13 the remaining 10 patches; Task 14
cross-patch surface-lens audit; Task 15 final review; Task 16 finishing).

### Triangulation inputs (per patch)

Four independent inputs feed each per-patch review:

1. **Vanilla NVIDIA 595.71.05** at the touched files/symbols (run
   `git show 595.71.05:<file>` in `/root/open-gpu-kernel-modules` on the
   fork branch). Identifies what NVIDIA's baseline does and where the
   patch diverges.
2. **v2 intent + review** at `docs/patch-intents/<id>.md` and
   `docs/patch-reviews/<id>.md`. The conformance baseline from sub-cycle 2.
3. **aorus-5090 archaeology (full depth)** at `/root/aorus-5090-egpu`.
   Per patch, read:
   - The ancestor patch (e.g. C3's ancestor is
     `patches/0001-osHandleGpuLost-retry-on-transient-pcie-failure.patch`).
   - Relevant Lever design docs (e.g. `lever-M-recover-design.md`,
     `recovery.md`, `recovery-mechanism-findings.md`).
   - `reliability-hypothesis-ledger.md` entries for the bug class.
   - Forensic data (e.g. `freeze-2026-05-05-investigation.md`,
     `iommu-gsp-lockdown-analysis.md`,
     `h17-g3-gen3-investigation-2026-05-07.md`) when relevant.
   - `source-review-notes.md` and `architecture-and-modularity.md`
     for architectural context.
4. **Community signal** from `docs/patch-improvements/_community-signal.md`
   (produced by Task 0). Filtered for entries tagged with the current
   patch.

### Lens taxonomy

Eight lenses split by application shape:

**Structural lenses (per-patch deep analysis):**

- **Sovereignty** — does the patch concentrate its blast radius? Does any
  duty leak to other modules or files unnecessarily?
- **Robustness** — error paths, lifetime, race conditions, edge cases
  vanilla NVIDIA assumes; what does the patch fail to handle?
- **Duty** — single-responsibility per patch; is anything mis-located?
- **Invariant clarity** — non-obvious invariants captured as comments /
  assertions / types, or only in the original author's head?

**Surface lenses (cross-patch comparative; partly defer to Task 14):**

- **Deduplication** — primitives copied across patches that could be
  unified.
- **Naming** — symbols, variables, log strings consistent across the
  stack.
- **Performance** — algorithmic / memory / hot-path tightening.
- **Quality** — comments, log levels, error messages, idioms.

### Value × cost triage

Every improvement candidate is scored on:

- **Value** = correctness / robustness / clarity / performance gain.
  Must be concrete and citable (line numbers, observable outputs,
  measured behaviour).
- **Cost** = LoC delta + complexity delta + risk delta.

Default disposition is **reject**. Triage matrix:

| Value | Cost | Default |
|---|---|---|
| High | Low | **Land** |
| High | High | Defer or design as its own initiative |
| Low | Low | Case-by-case; default reject unless it removes a real footgun |
| Low | High | Hard reject |

The "must deliver more than it costs" bar is the cycle's guiding principle.
The improvement-catalog format makes the scoring explicit per candidate.

### Intent-optimisation flow (hybrid TDD)

When triangulation surfaces that the v2 intent itself needs refinement,
disposition by substance:

- **Substantive intent change** — new Requirement, new Scenario,
  telemetry contract addition. Lands as a **precursor commit** on the
  injector branch, with a message stating "v1 does not yet satisfy this;
  implementation follows." The follow-up code commit on the fork branch
  satisfies the new claim. Two-commit TDD discipline.
- **Cosmetic intent change** — clarification prose, format string drift
  correction, link fix. Lands in a single combined commit alongside the
  code change.

Threshold: *does the change articulate a new normative claim about
behaviour?* Yes → substantive; no → cosmetic. Reviewer judgement.

### Verification mode (per improvement)

Each improvement declares its mode:

- **Mode A (default):** Scenario-first + code-reading verification.
  Audit-reviewer reads v1, confirms it doesn't satisfy the Scenario;
  reads v2 after the change, confirms it does.
- **Mode B:** Scenario specifies an exact observable assertion (log
  string, sysfs value, counter behaviour). Audit-reviewer greps the code
  for the exact output.

Mode C (runtime probes) is **explicitly out of scope**. The soak is the
integration test; per-improvement probe scripts have no payoff window.

## Per-patch workflow (canonical 11-step procedure)

For each patch, the review-implementer subagent executes:

1. **Read vanilla NVIDIA** at the touched files (run `git diff 595.71.05`
   on the fork branch).
2. **Read fork-branch v1** hunks; capture `v1-tip-sha`.
3. **Read v2 intent + review** to anchor in the sub-cycle 2 baseline.
4. **Read aorus-5090 archaeology** at full depth: ancestor patch, Lever
   design docs, hypothesis-ledger entries, forensic data, source-review
   notes. Cite specific paths + sections.
5. **Read community-signal entries** tagged for this patch (from Task 0's
   output).
6. **Apply the 8 lenses;** surface improvement candidates. Each candidate
   captured with Lens / Current / Proposed / Value / Cost / Verification
   mode / Intent impact.
7. **Score each candidate** on value × cost; triage to land / defer /
   reject.
8. **Write `docs/patch-improvements/<id>.md`** with the catalog
   (status: in-progress). Includes triangulation-sources section, v1
   archaeology section citing aorus-5090 sources, improvements-considered
   section with structured per-improvement entries, landed/intent-updates
   summary, Done gate, Cross-references.
9. **For each substantive intent change:** land precursor commit on the
   injector branch. Lint must pass.
10. **For each "land" improvement** (code-side): apply as fork-branch
    follow-up commit (`<patch-id>-I<N>: <description>` subject), push,
    regen `patches/<layer>/<id>.patch`.
11. **Compile gate + test gate + flip catalog status to `accepted` +
    commit injector-side closeout.**

Audit-reviewer subagent then verifies and either approves or returns
issues. Loop until approved.

## Output artefact specifications

### Per-patch improvement catalog

Path: `docs/patch-improvements/<id>.md`. Not lint-checked in this cycle
(human judgment, mirroring sub-cycle 2's review-file pattern).

**Frontmatter (7 fields):**

```yaml
---
id: <patch-id>
review-date: 2026-05-DD
reviewer: Claude Opus 4.7
v1-tip-sha: <SHA before v3 commits>
v2-tip-sha: <SHA after v3 commits — equals v1 if no code change>
status: in-progress | accepted | rejected
intent-updates: []           # list of precursor intent commit SHAs (substantive changes only)
---
```

**Required sections, in order:**

1. `# <patch-id> — improvement triage` (top heading).
2. `## Triangulation sources` — v2 intent path, vanilla baseline path,
   aorus-5090 ancestor patch path, aorus-5090 docs cited, community-signal
   entries referenced.
3. `## v1 archaeology` — what the aorus-5090 mining surfaced: original
   design intent, constraints discovered, alternatives considered and
   rejected, forgotten / latent invariants. Every claim cites a specific
   aorus-5090 source path + section.
4. `## Improvements considered` — structured entries:

   ```markdown
   ### <patch-id>-I<N> — <one-line title>
   - **Lens:** sovereignty | robustness | dedup | duty | naming | performance | quality | invariant clarity
   - **Current state:** <code excerpt or intent reference>
   - **Proposed state:** <what changes>
   - **Value:** <concrete gain — correctness / robustness / clarity / perf>
   - **Cost:** <LoC delta, complexity delta, risk delta>
   - **Verification mode:** A | B
   - **Intent impact:** none | refine Scenario <name> | add Requirement <name>
   - **Triage decision:** land | defer | reject
   - **Resolution:** applied as <SHA> / precursor intent <SHA> + impl <SHA> / deferred to <follow-up> / rejected because <reason>
   ```

5. `## Improvements landed` — summary list with one-line description per
   landed improvement.
6. `## Intent updates landed` — summary list of intent edits (new
   Requirements, refined Scenarios, telemetry additions).
7. `## Done gate` — per-patch checklist.
8. `## Cross-references` — intent, review, aorus-5090 ancestor, vanilla
   source, upstream issue, community-signal sources.

### Cross-patch findings

Path: `docs/patch-improvements/_cross-patch.md`. Created in this cycle's
Task 14. Surface lenses (dedup, naming, performance, quality) with
per-patch contributions and atomic-sweep recommendations. Findings that
span multiple patches (e.g. dedup opportunities or naming consistency
issues across A1-A5) live here rather than in any single per-patch
catalog.

### Community-signal reconnaissance

Path: `docs/patch-improvements/_community-signal.md`. Created in Task 0
(pre-pilot). Single subagent scan via `gh` CLI of:

- NVIDIA `open-gpu-kernel-modules` issues `#979` + `#981` activity since
  2026-05-02.
- Open issues mentioning {Blackwell, eGPU, Thunderbolt, surprise-removal,
  bus loss, PCIe transient, AER} in the 2026-05-02 → today window.
- NVIDIA upstream commits / PRs in the same window touching files our
  patches modify (`os-mlock.c`, `osinit.c`, `nv-pci.c`, `os-pci.c`, etc.).
- Direct responses to the apnex outreach comment-4514103926 from 2026-05-22.

Output sectioned by source. Each finding tagged with affected patch(es).
Time-budget: ~30 minutes of subagent compute. Expected output: 50–200
lines.

### Improvement-catalog template

Path: `docs/patch-improvements/_template.md`. Created in Task 1.
Skeleton mirroring the schema above; copied by per-patch reviewer
subagents.

## Subagent topology

Per patch (mirrors sub-cycle 2's 2-stage pattern):

- **Review-implementer** (Opus) — executes the 11-step per-patch
  workflow. Reads triangulation inputs, surfaces candidates, triages,
  writes catalog, applies landed improvements (intent precursor + fork
  commits), runs gates, commits injector-side closeout.
- **Audit-reviewer** (Opus) — independent verification:
  - Triangulation claims cite real aorus-5090 paths/sections.
  - Improvements are correctly scored on value × cost.
  - Landed improvements actually exist in the code at the cited SHAs.
  - Intent updates (precursor commits) are followed by code-side commits
    that satisfy them.
  - Compile + test gates passed.

If issues, review-implementer fixes; audit re-runs; loop until approved.

Additional subagents:

- **Task 0 community-signal scanner** (one Opus subagent).
- **Task 14 cross-patch surface-lens auditor** (one Opus subagent).
- **Task 15 final cross-branch reviewer** (one Opus subagent).

Total estimated subagent invocations: ~25-30 across the full cycle.

## Order, parallelism, methodology checkpoint

**Order:**

- **Task 0** (community-signal recon) — runs first, output feeds all subsequent per-patch reviews.
- **Task 1** (setup: improvement-catalog template).
- **Task 2** (C3 pilot — full triangulation + 8-lens evaluation + triage + improvements applied).
- **Task 3** (methodology checkpoint user gate) — pause + amend if needed.
- **Tasks 4–13** — the remaining 10 patches in dependency order, matching
  sub-cycle 2 modulo C3 having already run as the pilot:
  C1 → C2 → C4 → E1 → C5 → A1 → A2 → A3 → A4 → A5.
- **Task 14** (cross-patch surface-lens audit + cross-patch findings doc + final index regen).
- **Task 15** (final cross-branch review).
- **Task 16** (finishing: invoke superpowers:finishing-a-development-branch; memory update; surface follow-on work).

**Parallelism:** strict serial.

**Methodology checkpoint after C3.** C3 is the highest-stakes pilot
(headline #979 fix, substantive engineering, aorus-5090 has direct
ancestor). After audit-reviewer approves the C3 catalog, **pause** for
user gate. Evaluate: did the triangulation surface real value, did the
lens scoring + triage discipline hold, did community signal contribute,
should we amend before propagating. Same pattern as sub-cycle 2's C1
checkpoint.

## Done gate

### Per-patch done gate

For patch `<id>`:

- [ ] `docs/patch-improvements/<id>.md` exists with status: `accepted`.
- [ ] Every improvement has explicit Resolution (no `pending`).
- [ ] Every "land" improvement applied as fork-branch commit citing
  `<patch-id>-I<N>` in subject.
- [ ] Substantive intent updates landed as precursor commits on injector
  branch BEFORE the corresponding code commit.
- [ ] `patches/<layer>/<id>.patch` refreshed by regen if code change.
- [ ] `tools/intent-lint.sh` passes (intent updates are Rules 1–11 clean).
- [ ] `tools/validate-patchset.sh` exit 0.
- [ ] `bash tests/run.sh` green (34/0).
- [ ] Audit-reviewer subagent approved.

### Full sub-cycle 3 done gate

- [ ] All 11 patches meet per-patch done gate.
- [ ] `docs/patch-improvements/_cross-patch.md` populated with cross-patch
  findings.
- [ ] `docs/patch-improvements/_community-signal.md` populated.
- [ ] `docs/patch-index.md` regenerated if any intent updates landed.
- [ ] `tools/validate-patchset.sh` exit 0 on final state.
- [ ] `bash tests/run.sh` green on final state.
- [ ] Final cross-branch reviewer approved.
- [ ] Branch ready to merge to `main`.

## Branch strategy

**Injector:** single feature branch `feature/v3-patch-improvements` off
`main`. Per-patch commits accumulate (each per-patch task may produce
1-3 commits: optional intent precursor + optional regen-refreshed-patch
+ closeout commit). Final cross-branch review at the end. Fast-forward
merge to `main` when done gate passes.

**Fork:** v3 code commits land on the existing 11 fork branches on
`apnex/open-gpu-kernel-modules`. No new branches; no force-push (v1+v2
tips preserved as first/intermediate commits on each branch; v3 chain on
top).

## Relationship to other initiatives

- **Sub-cycle 1 (schema):** input. The schema (v1.0) is the spec
  language. Frozen for this cycle.
- **Sub-cycle 2 (v2 intent + review):** input. Conformance baseline. May
  receive precursor-commit intent updates during this cycle (the intent
  is a living artefact per the user's "engineered intent as a product"
  framing).
- **`docs/production-migration.md` steps 5–7:** downstream. After sub-cycle
  3 merges, the next aorus image build picks up the v3 patches. Soak
  validates. Post-soak commit flips all 11 intents from `reviewed →
  approved`.
- **NVIDIA #979 upstream effort:** the v3 patches become the public-facing
  artefacts for the eventual C1-C5 + E1 upstream PR. Their intent files
  anchor the PR bodies. The community-signal recon in Task 0 directly
  informs upstream-PR prep.
- **Deferred items from sub-cycle 2** (A1-D1 rename, A2-D1 hoist,
  regen-base-patches.sh timestamp churn): tracked in
  `docs/superpowers/plans/2026-05-23-patch-v2-reviews.md` §"Deferred
  follow-ups"; not addressed in this cycle.

## Tooling

**Reuse only.** No new tools introduced by sub-cycle 3.

- `tools/intent-lint.sh` — validates intent updates after precursor commits.
- `tools/render-patch-index.sh` — regenerates `docs/patch-index.md` if any
  intent updates land.
- `tools/regen-base-patches.sh` — regenerates `patches/<layer>/<id>.patch`
  from fork branch after v3 commits.
- `tools/validate-patchset.sh` — compile gate.
- `tests/run.sh` — test gate (schema-machinery tests stay green).

If a recurring need surfaces during the C3 checkpoint (e.g. a helper to
diff aorus-5090 ancestor against current fork branch), add it then —
not pre-emptively.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Triangulation surfaces nothing material (same outcome as sub-cycle 2's "all zero deltas") | Community signal is a fresh independent input; aorus-5090 full-depth read surfaces forgotten constraints; pilot-then-decide preserves option to stop early |
| Methodology checkpoint after C3 reveals lens scoring doesn't generalise | Explicit pause gate; amend spec + plan before C1 starts; same pattern as sub-cycle 2's C1 checkpoint |
| Bloat creep — every "nice-to-have" lands | Default reject + value × cost grid; threshold "must deliver more than it costs" |
| Intent updates introduce contradictions with v2 baseline | Lint Rules 1–11 enforce schema; audit-reviewer cross-checks against unchanged Requirements |
| Per-patch reviewer invents archaeology rather than citing sources | Audit-reviewer mandate: every archaeology claim must cite a specific aorus-5090 doc + section/path |
| Community-signal scope creep | Task 0 is one-shot recon, not ongoing surveillance; explicit time-box (~30 min); output capped at one doc |
| Self-confirmation bias persists (audit-reviewer trusts the implementer's framing) | Audit-reviewer reads the same triangulation sources independently; can override the implementer's triage decisions |
| Schema gap surfaces during a per-patch review | Pause; lift to a separate schema-v1.1 cycle; do not slip the schema change into sub-cycle 3 |
| Fork-branch v3 commits accidentally drift v1/v2 audit trail | Strict no-force-push policy; v1+v2 tips preserved as first/intermediate commits |
| Per-patch ordering surfaces cross-patch coupling mid-cycle | A3/A4 ordering matches sub-cycle 2 (A3 before A4); cross-patch findings from any pair surface during Task 14 audit rather than block per-patch flow |

## Out of scope (reaffirmed)

- Hardware behavioural validation; aorus.NN rebuild; the soak.
- The `status: reviewed → approved` flip — still post-soak.
- NVIDIA upstream PR submission.
- Schema (v1.0) changes.
- Review-file lint tooling.
- A1-D1 rename atomic-sweep.
- `regen-base-patches.sh` content-hash gate fix.
- A2-D1 hoist of `tb_egpu_dump_aer_trigger_event` call site.

These remain in the deferred-items tracker until their own initiative.

## Relationship to prior decisions

Sub-cycle 3 **consumes** the patch-intent schema landed in sub-cycle 1
([patch-intent-schema-design](2026-05-22-patch-intent-schema-design.md)),
the v2 intent + review artefacts landed in sub-cycle 2
([sub-cycle-2-patch-deep-review-design](2026-05-23-sub-cycle-2-patch-deep-review-design.md)),
and the C/E/A patch geometry from the addon-recarve and
dynamic-patch-composition design specs
([addon-recarve-design](2026-05-22-addon-recarve-design.md),
[dpc-design](2026-05-22-dynamic-patch-composition-design.md)).

It runs **in parallel** with `production-migration.md` steps 5–7
(image rebuild → soak → cutover). The two streams converge post-soak
when intents flip to `approved`. The v3 patches replace the v2 set as
the soak candidate **if and only if** they merge to `main` before the
next aorus image build is initiated; otherwise the soak proceeds against
v2 and sub-cycle 3 lands behind it as a follow-on.
