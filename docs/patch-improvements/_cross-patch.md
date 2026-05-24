---
generated: 2026-05-23
reviewer: Claude Opus 4.7
parent-tip: 0f6aa0d424eaad805c4aae793ee9ac7db116dbc4
catalogs-aggregated: 11
status: complete
---

# Cross-patch surface-lens findings — sub-cycle 3

Sub-cycle 3 ran 11 per-patch triangulated reviews (C1, C2, C3, C4, C5, E1,
A1, A2, A3, A4, A5). This document aggregates the four surface-lens views
across all 11 catalogs, adjudicates cross-patch-only findings (those that
no single catalog could resolve in isolation), and records which atomic
sweeps landed vs. deferred.

The per-patch catalogs surfaced **77 candidate improvements** in total:

- **1 landed code change:** A1-I8 (DPC offset correction inherited from
  aorus 0023 — load CAP into ctl, CTL into status). Cascade-rebased A2-A5
  on the new A1 tip; intent precursor commit `2780596` corrected
  Requirement #2 to match canonical `<linux/pci_regs.h>` lines 1081-1096.
- **1 landed prose change:** C1-I1 (lift `.cmd`-hashing rebuild guarantee
  into in-file Kbuild comment).
- **1 landed re-frame:** C4-I5 (correct v2 review prose "five-field
  struct" → "seven-field struct" — cross-patch correction landed during
  C4 audit at `49ecc03`).
- **1 landed doc-fix:** A3-I15 (stale fork SHA remap on review/catalog
  frontmatters — landed at `43b8cc9`).
- **Remainder:** rejected (verification passed) or deferred (with
  documented trigger).

This cross-patch audit ratifies the per-patch dispositions and lands one
additional atomic frontmatter sweep covering the deferred-to-Task-14
cross-references.

## Deduplication patterns

Aggregated across all 11 catalogs the dedup lens surfaced **zero unmet
sweeps**:

- **A1-I7** verified A1 vs. kernel `pcie_aer_*` helpers — no duplication
  (A1 sequences reads of bridge AER + GPU AER + GPU DPC for the
  trigger-event dump; kernel helpers only read a single device's AER and
  return individual register values). Rejected.
- **C5-I6** verified C5↔A1 dedup — no overlap (C5 reads
  `NV_GPU_BUS_DEAD_VALUE_U32` for the post-read crash-safety promotion;
  A1 reads AER + DPC for trigger-event dumps). Rejected.
- **A4-I9** verified A4 vs. A3 telemetry surface non-overlap (A4 owns
  close-path predicted-LAST-CLOSE telemetry + MAPFAIL sentinel; A3 owns
  recovery state-machine telemetry). Rejected.
- **C5-I7** verified C4↔C5 contract (C4 registers `pci_error_handlers`;
  C5 only consumes the dispatched callbacks — explicit Scope boundary on
  both sides). Rejected. (Cross-checked also via C2 prose reconciliation
  at `e8fb311` from sub-cycle 2.)

**Cross-patch finding (XPATCH-D1):** the dedup lens is healthy across
the patch set. No atomic-sweep dedup improvements surface.

## Naming consistency

The naming lens surfaced **two minor items**, both deferred per the
patch-by-patch verdict:

- **A1-I1** (sub-cycle 2's `tb_egpu_recover_*` → `tb_egpu_pcie_*` infix
  rename) — deferred. Sub-cycle 3 re-examination upheld v2's "defer"
  because the rename is mechanical (signature unchanged) and would
  cascade across A2/A3/A4 fork branches for a cosmetic naming
  improvement. The naming inconsistency is contained (the infix appears
  in 4 sites total, all in `nv-tb-egpu*.c`); a maintainer-only refactor
  is a better moment to apply it.
- **E1-I1** (rename `os_pci_is_thunderbolt_attached` to reflect the
  union behaviour with `pdev->untrusted`) — deferred. Sub-cycle 3
  re-examination upheld v2's "defer" because the OS-API symbol crosses a
  large NVIDIA-internal contract surface; renaming it triggers
  unnecessary upstream-PR review friction for a documentation-shaped
  improvement.

**Cross-patch finding (XPATCH-N1):** no naming sweep gates the upstream
PRs. Naming dispositions are consistent across all 11 catalogs (default
to upholding v2's name choices unless a real footgun surfaces; both
deferrals match this discipline). No atomic sweep lands.

## Performance opportunities

The performance lens surfaced **one explicit item**, rejected:

- **A2-I8** (polling cadence of the bus-loss-watchdog kthread) — v3
  re-verification confirms the cadence is appropriate (default heartbeat
  interval is `NV_TB_EGPU_BUS_LOSS_WATCHDOG_HZ` = 4 Hz, tunable;
  recovery latency floor is dominated by `pci_reset_bus` not by the
  watchdog cadence). Rejected.

Beyond the explicit `Lens: performance` tag, A4's catalog verified that
its close-path telemetry adds zero behavioural surface (no map-table
locks, no allocator pressure, no new syscalls); the patch is
prove-the-path-ran shape only. A3's catalog verified that its workqueue
lifecycle is appropriate (`cancel_work_sync` on teardown; no leaked
work items).

**Cross-patch finding (XPATCH-P1):** the patch set carries no
performance debt that sub-cycle 3 archaeology surfaces. The hottest
path (bus-loss-watchdog) was verified n=3 in earlier hypothesis-ledger
testing (project memory `feedback_reliability_methodology`); sub-cycle 3
adds no new performance contradictions. No atomic sweep lands.

## Quality patterns

The quality lens surfaced **multiple verifications and one cross-patch
correction landed during C4 audit**:

- **C4-I5** (v2 review's "five-field" `pci_error_handlers` miscount) —
  landed during the C4 audit pass as commit `49ecc03`, correcting the
  prose to "seven-field struct" matching kernel `<linux/pci.h>` (the
  struct populates 4 of 7 callbacks in C4; the remaining 3 surface
  defaults). Cross-patch correction because the same miscount could
  affect upstream-PR review prose.
- **A3-I13** quality-verified the recovery telemetry log levels match
  the telemetry contract. Rejected.
- **A4-I8** quality-verified MAPFAIL sentinel format alignment with
  intent. Rejected.
- **C2-I1** (offset-validation defensiveness) — rejected; intent
  doesn't constrain offset-validation behaviour, and the
  `pcie_aer_is_native()` precondition (per C2-I3) covers the missing
  AER cap case via the kernel's own bound semantics.
- **C5-I4** (log-line richness aorus 0013 form vs. C5 form) — rejected;
  C5's minimal form matches the project's "telemetry shape =
  proof-of-path-ran" discipline.

**Cross-patch finding (XPATCH-Q1):** the quality lens is healthy across
the patch set. The single quality correction (C4-I5) already landed in
the C4 audit cycle. No additional atomic sweep lands at Task 14.

## Atomic-sweep improvements (cross-patch landed)

### XPATCH-F1 — `related-patches:` frontmatter additions for forward-only references

Sub-cycle 2 closeout (commit `7af8369` → `1ca46ac`) ratified the
forward-only `related-patches:` convention: a patch's frontmatter lists
its forward references; reverse edges live in body prose via `[[<id>]]`
wikilinks. Per that convention, two catalog entries deferred-to-Task-14
land as a single atomic sweep:

- **E1 intent + review:** added `A2-bus-loss-watchdog, A3-recovery` to
  `related-patches:`. Rationale: E1 provides the `is_external_gpu`
  signal that gates both A2's watchdog and A3's recovery; the
  provider-lists-consumers direction is the forward edge per
  `docs/upstream-plan.md §E1`. Resolves **E1-I6** (catalog entry at
  `docs/patch-improvements/E1-egpu-detection.md` lines ~640-700).
- **C4 intent + review:** added `A3-recovery` to `related-patches:`.
  Rationale: C4 registers `pci_error_handlers` whose dispatched
  callbacks A3 implements; the provider-lists-consumers direction is
  the forward edge. Resolves **C4-I3** (catalog entry at
  `docs/patch-improvements/C4-err-handlers-scaffold.md` lines
  ~440-490).

The reverse edges (A2→E1, A3→E1, A3→C4) are NOT added — per the
forward-only convention they live in body-prose wikilinks. A2 + A3
already reference C4 + E1 via body prose (`docs/patch-intents/A2-bus-loss-watchdog.md:382`
and `docs/patch-intents/A3-recovery.md:548` cite the cumulative diff;
A3's Scope boundary cites `[[C4-err-handlers-scaffold]]` at intent line
144). No further additions required.

Gate impact: re-opens E1 + C4 `reviewed` lint state. `intent-lint.sh`
passes after the sweep (Rule 6 resolves all listed targets).
`validate-patchset.sh` passes (frontmatter is not load-bearing for
compose-or-compile).

## Sub-cycle 4 landed (XPATCH-S2 paired-cascade)

Sub-cycle 4 bundles two architectural-cleanup improvements that were
individually deferred from sub-cycle 3 with explicit revisit triggers,
because each alone was too cost-asymmetric for a single-improvement
sub-cycle (each triggers a 4-branch force-push cascade through A2-A5
on the fork). Bundling amortises the cascade cost exactly once.

### Improvements in the bundle

1. **A1-pcie-primitives-I1 (A1-D1)** — atomic-sweep rename of A1-owned
   `tb_egpu_recover_*` primitives to `tb_egpu_pcie_*`:
   - `TB_EGPU_RECOVER_WPR2_REG_OFFSET` → `TB_EGPU_PCIE_WPR2_REG_OFFSET`
   - `TB_EGPU_RECOVER_WPR2_VAL_MASK` → `TB_EGPU_PCIE_WPR2_VAL_MASK`
   - `tb_egpu_recover_read_wpr2` → `tb_egpu_pcie_read_wpr2`
   - `tb_egpu_recover_walk_to_root_port` →
     `tb_egpu_pcie_walk_to_root_port`
   - `tb_egpu_recover_read_dpc_state` → `tb_egpu_pcie_read_dpc_state`
   - `tb_egpu_recover_read_aer_full` → `tb_egpu_pcie_read_aer_full`

   A3's own `tb_egpu_recover_*` symbols (the recovery state machine,
   state struct, gate enums, slot_reset callbacks) stay as-is — those
   names continue to be accurate. Fork-branch commit `fe6ad92f` on
   `a1-pcie-primitives`; consumer references in A3/A4 updated in
   lockstep during cascade-rebase.

2. **A3-recovery-I1 (A3-D3)** — hoist `tb_egpu_dump_aer_trigger_event`
   call OUT of A2's translation unit. A3 previously inserted the call
   into `nv-tb-egpu-qwd.c` (A2's TU) — the exact cross-cluster edit
   pattern the 2026-05-22 addon-recarve campaign was designed to
   eliminate. Mechanism: option (1) per the I1 deferral catalog — A1
   already declares the function in `nv-tb-egpu-pcie.h` (consumed by
   A2 transitively via `nv-tb-egpu-qwd.h`); A2 makes the call directly
   at its detection latch with zero new header plumbing. Fork-branch
   commit `353a859e` on `a2-bus-loss-watchdog` (lands the call in A2's
   own TU); A3's rebased commit `60dfe4c7` drops the cross-TU hunk
   entirely.

### Why bundle

Each improvement standalone hits the same 4-branch cascade
(A1→A5 or A2→A5). The cascade cost is fixed-per-execution, not
proportional to improvement count, so bundling halves the cumulative
cascade tax for the same surface payoff.

### Effect on patches

- `patches/addon/A1-pcie-primitives.patch`: 0-net-line rename only —
  same diff stat, different symbol spellings inside lines.
- `patches/addon/A2-bus-loss-watchdog.patch`: grows by ~7 lines (the
  call + the rewritten "filled by addon-A1 helper" comment).
- `patches/addon/A3-recovery.patch`: shrinks by ~8 lines (the
  cross-TU hunk into `nv-tb-egpu-qwd.c` GONE; A3 stays in its own
  TUs: `nv-tb-egpu-recover.{c,h}`, `nv-pci.c`, `nv-linux.h`, `nv.c`,
  `nvidia-sources.Kbuild`). The renamed A1 symbol consumers
  (`tb_egpu_recover_read_wpr2` → `tb_egpu_pcie_read_wpr2`, etc.)
  remain at 4 call sites with the new names.
- `patches/addon/A4-close-path-telemetry.patch`: 0-net-line — 2
  symbol-rename references propagated from A1-D1.
- `patches/addon/A5-version-and-toggles.patch`: 0-line change — A5
  references no A1 or A3 internal primitives.

### Fork-branch tip advances

| Branch                  | sub-cycle 3 tip | sub-cycle 4 tip |
|-------------------------|-----------------|-----------------|
| a1-pcie-primitives      | `124e9c5e`      | `fe6ad92f`      |
| a2-bus-loss-watchdog    | `cd1fe088`      | `353a859e`      |
| a3-recovery             | `f57a38b2`      | `60dfe4c7`      |
| a4-close-path-telemetry | `8d85e1db`      | `cddf8b9a`      |
| a5-version-and-toggles  | `9d62f2e6`      | `5fab2573`      |

### Range-diff verification

Each cascaded branch verified semantic-only changes:
- A1: original `124e9c5e` (I8) preserved 1:1; new commit `fe6ad92f`
  contains only the rename.
- A2: original `cd1fe088` preserved 1:1 (as `34397b21` after rebase
  on new A1 base); new commit `353a859e` contains the hoist.
- A3: original `f57a38b2` rebased to `60dfe4c7` with EXACTLY the
  expected deltas — the cross-TU hunk into `nv-tb-egpu-qwd.c` gone,
  and the A1 symbol references renamed.
- A4: original `8d85e1db` rebased to `cddf8b9a` with only A1 symbol
  references renamed.
- A5: original `9d62f2e6` rebased to `5fab2573` 1:1 identical.

### Force-push policy

5 fork branches (A1, A2, A3, A4, A5) force-pushed to
`apnex/open-gpu-kernel-modules` under the
`feedback_force_push_fork_carve_out` policy carve-out:
- Cascade is required for the paired improvement's correctness (A1's
  symbol exports must match A3's consumers); range-diff confirms
  zero semantic drift in A2-A5's own logic.
- Reflog preserves old SHAs (`124e9c5e`, `cd1fe088`, `f57a38b2`,
  `8d85e1db`, `9d62f2e6` all reachable via reflog for ≥30 days).
- Zero open PRs (NVIDIA-upstream or against the apnex fork) affected;
  the upstream PRs are scoped to C1-C5 + E1 — none of A1-A5 touched
  by sub-cycle 4 is upstream-bound.
- Blast radius: external readers re-fetch on next pull only.

## Atomic-sweep improvements (cross-patch deferred)

### XPATCH-S1 — A5↔C1 symmetric carve adjudication

Two catalog entries proposed symmetric carve documentation: **C1-I4**
(document A5's Kconfig-toggle carve in C1's intent Scope boundary) and
**A5-I1** (document the dropped `CONFIG_NV_TB_EGPU_DIAG` carve in A5's
intent Provenance). Both were individually deferred by their respective
audits with the recommendation that Task 14's cross-patch view
adjudicate them together.

**Adjudication: both stay deferred — symmetric deferral.** Rationale:

- A5's intent already documents the carve from A5's side at two
  locations: Purpose paragraph (lines 13-37 cite
  `[[C1-kbuild-version-mk]]`'s `version.mk`-as-single-source-of-truth)
  and Scope boundary clause 3 (lines 181-186 — "This patch does NOT
  modify the kbuild include... Those changes are owned by
  `[[C1-kbuild-version-mk]]` and pre-date A5 in the fork-branch
  sequence"). Verified by direct read of
  `docs/patch-intents/A5-version-and-toggles.md`.
- C1's intent already cites A5 from C1's side: Scope boundary clause 1
  (lines 78-81) names `[[A5-version-and-toggles]]` for the version-suffix
  carve. The MISSING piece is C1 doesn't cite A5 for the Kconfig-toggle
  carve specifically.
- The carve relationship is structurally captured by the manifest layer
  column (`patches/manifest`: C1=base/upstream-bound,
  A5=addon/project-local) and the C/E/A patch-id prefix convention
  (project memory `project_cea_patch_geometry_2026_05_22`).
- Lifting either I1 or I4 reopens the affected intent's `reviewed`
  lint state for sub-line cosmetic clarification.

The cross-patch view confirms the deferral is consistent: NEITHER side
needs the additional clarification because the manifest + existing
cross-citations + the C/E/A geometry memory together capture the
relationship durably. Disposition for follow-up: if a future maintainer
needs to understand the C1/A5 boundary from either side independently,
lift the relevant clause then.

### XPATCH-D2 — C3-I7 #916 broader-applicability for PR body

C3-I7 (document #916 RTX 4090 / Ampere as evidence for general-purpose
hardening) was deferred during the C3 catalog because the citation
belongs in the eventual upstream PR description for C3, not in the
sub-cycle 3 intent or review files. The community-signal tag at
`docs/patch-improvements/_community-signal.md` already carries the
#916 reference; the upstream-PR submission step (in
`docs/upstream-plan.md §C3`) is the appropriate locus.

**Adjudication: stays deferred to upstream-PR submission step.** Task
14 does not lift this — premature upstream filing is explicitly out of
scope (project memory
`feedback_no_premature_upstream_filing`).

### XPATCH-D3 — A2-I2 counter wrap-guard semantic clarification

A2-I2 (detection counter wrap-guard / semantic correction) was deferred
to post-soak with the rationale that both candidate fixes (cap-at-MAX
vs. allow-wrap) carry behavioural risk during the 14-day vLLM soak;
sub-cycle 3 archaeology does not surface a forcing function.

**Adjudication: stays deferred post-soak.** Tracked in the v3 deferred
items at `docs/superpowers/plans/2026-05-23-patch-v3-improvements.md`
close-out (Task 16 will roll this into the cycle deferred-items log).

### XPATCH-V1 — A4-I1 guardrail status (confirmation, not action)

Per A4's audit pre-warn (Task 12), the A2 audit raised a regression
concern that A4's close-path telemetry might inadvertently touch A2's
TU `nv-tb-egpu-bus-loss-watchdog.c`. Cross-patch verification
re-confirms:

- A4 modifies only `kernel-open/nvidia-uvm/uvm_va_space.c`,
  `kernel-open/nvidia/nv-mmap.c`, and adds the project-local TU
  `nv-tb-egpu-close-path-telemetry.c` (per
  `patches/addon/A4-close-path-telemetry.patch` file headers).
- A4 carries zero edits to `nv-tb-egpu-bus-loss-watchdog.c` (verified
  by `grep -l watchdog patches/addon/A4-close-path-telemetry.patch`
  returns no matches).
- A3-I1's revisit-trigger condition (cross-cluster
  `tb_egpu_dump_aer_trigger_event` call site hoist) is NOT fired by
  any sub-cycle 3 finding.

**Adjudication: confirmation only — no action required.** A4's
telemetry-only invariant is preserved across the cluster.

### XPATCH-V2 — C5-I3 C2 prose reconciliation (confirmation, not action)

C5-I3 (cross-patch C2-intent reconciliation: C2 prose said "C5
registers `pci_error_handlers`" but C4 is the registrar) was deferred
to Task 14 during the C5 audit. However, this finding was already
addressed in sub-cycle 2 cross-patch reconciliation at commit
`e8fb311` (2026-05-23, `docs: reconcile cross-patch prose drift
(C2/C4/C5 + A4/A5)`). C2's intent now correctly says C4 registers and
C5/recovery consumes (verified at intent lines 25-27 and 95-96).

**Adjudication: already resolved at `e8fb311` — no action required.**
Verification at Task 14: clean.

## Methodology notes for the final cross-branch review (Task 15)

- **Frontmatter sweep is forward-only.** The XPATCH-F1 sweep adds
  forward edges only; reverse edges live in body-prose wikilinks. Task
  15's reviewer should NOT flag the absence of paired entries in
  A2/A3/E1 frontmatters — this is the documented forward-only
  convention from sub-cycle 2 closeout (`docs/patch-intent-schema.md`).
- **Frontmatter cross-refs do not affect `patch-index.md`.** Regen at
  Task 14 produced zero diff against the committed index — the rendered
  table extracts only the `## Purpose` first paragraph + manifest
  metadata; `related-patches:` is intent-internal.
- **Symmetric carve deferrals (XPATCH-S1) are deliberate.** The Task 15
  reviewer should expect to see C1 + A5 deferrals upheld together. The
  cross-patch view explicitly adjudicated the symmetry.
- **Catalog-line-count discipline.** Across 11 catalogs the line-count
  range is 134 (C1) to 1679 (A3). The ratio (catalog lines : patched
  lines) reflects archaeology depth, NOT bloat — A1's 681 lines for
  a primitives-only patch and A5's 480 lines for a 14-line patch are
  high-archaeology / low-surface categories. Task 15 reviewer should
  not flag these as over-engineering.
- **Audit-approval bar is uniform.** All 11 catalogs carry an
  audit-reviewer approval annotation in their Done-gate sections,
  recording spot-checked citations, methodology drops/adds, and any
  pre-warns. Task 15's reviewer can cross-reference these annotations
  for spot-check coverage rather than re-deriving them.

## Cross-references

- Plan: `docs/superpowers/plans/2026-05-23-patch-v3-improvements.md`
  (Task 14 section, lines 809-901).
- Schema (forward-only convention):
  `docs/patch-intent-schema.md` (`related-patches` row + footnote).
- Sub-cycle 2 cross-patch reconciliation: commit `e8fb311`.
- Sub-cycle 3 in-cycle cross-patch corrections: commits `49ecc03`
  (C4-I5 five→seven field), `43b8cc9` (A2/A4/A5 review-frontmatter
  stale-SHA remap).
- Community-signal map: `docs/patch-improvements/_community-signal.md`.
- Per-patch catalogs: `docs/patch-improvements/{C1,C2,C3,C4,C5,E1,A1,A2,A3,A4,A5}-*.md`.
