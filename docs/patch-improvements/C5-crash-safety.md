---
id: C5-crash-safety
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: 416bdc37b81a1457e80ec576e1e8990b091136d6
v2-tip-sha: 416bdc37b81a1457e80ec576e1e8990b091136d6
status: accepted
intent-updates: []
---

# C5-crash-safety — improvement triage

## Triangulation sources

- **Vanilla NVIDIA 595.71.05** (every file touched by C5 read at the
  595.71.05 tag):
  - `kernel-open/common/inc/os-interface.h` — has the existing
    `os_pci_*` prototype block (`os_pci_remove_supported`,
    `os_pci_remove`, etc.) immediately above `os_map_kernel_space`; no
    `os_pci_is_disconnected` / `os_pci_set_disconnected` /
    `os_pci_is_thunderbolt_attached` prototypes. C5's additions are
    purely additive into that block.
  - `kernel-open/nvidia/os-pci.c` — `os_pci_remove` is the last helper;
    no disconnect-state helpers exist. C5 adds the wrappers after it.
  - `src/nvidia/arch/nvalloc/unix/include/os-interface.h` — kept in
    sync with the kernel-open copy; C5 adds the same three prototypes.
  - `src/nvidia/arch/nvalloc/unix/src/os.c` — `osDevReadReg008/016/032`
    have no dead-bus short-circuit, no post-read detection, and no
    shared predicate. The U32 reader has a vGPU passthrough check
    (`vgpuDevReadReg032`) above which the C5 dead-bus guard lands.
  - `src/nvidia/inc/kernel/gpu/nv-gpu-lost.h` — NEW FILE; no vanilla
    counterpart.
  - `src/nvidia/src/kernel/diagnostics/journal.c:2237` — vanilla has
    `NV_ASSERT(status == NV_OK)` immediately after `status =
    rcdbAddRmGpuDump(pGpu);` in `_rcdbAddRmGpuDumpCallback`. Vanilla
    `rcdbAddRmGpuDump` has no `PDB_PROP_GPU_IS_LOST` early-return.
  - `src/nvidia/src/kernel/diagnostics/nv_debug_dump.c:nvdDumpAllEngines_IMPL`
    — vanilla has the engine-callback loop and an in-loop
    `PDB_PROP_GPU_INACCESSIBLE` advisory flag-set, but no loop break.
  - `src/nvidia/src/kernel/vgpu/rpc.c:_issueRpcAndWait` — vanilla
    performs `gpumgrGetBcEnabledStatus` + `rmDeviceGpuLockIsOwner`
    check; no `PDB_PROP_GPU_IS_LOST` short-circuit. Vanilla
    `rpcRmApiFree_GSP` has no short-circuit.
  - `src/nvidia/src/libraries/resserv/src/rs_client.c:842` and
    `rs_server.c:259` — vanilla asserts `(status == NV_OK) || (status
    == NV_ERR_GPU_IN_FULLCHIP_RESET)` at both sites.
- **v2 intent:** `docs/patch-intents/C5-crash-safety.md` (status
  `reviewed`).
- **v2 review:** `docs/patch-reviews/C5-crash-safety.md` (status
  `accepted`; documents 4 deltas D1-D4 — D1 verification (de-branding
  confirmed), D2 nice-to-have-deferred, D3 out-of-scope Task 14
  reconciliation, D4 zero-must-fix sentinel).
- **aorus-5090 ancestor patches** (all 5 listed in the binding plus 4
  additional crash-safety/dead-bus ancestors surfaced via grep —
  documented in §v1 archaeology):
  - `patches/0002-journal-rcdbAddRmGpuDump-shortcircuit-and-relax-assert.patch`
    (Lever J-2)
  - `patches/0003-nvDumpAllEngines-break-on-gpu-lost.patch` (Lever J-2)
  - `patches/0004-resserv-cleanup-asserts-accept-gpu-lost.patch`
    (Lever J-2)
  - `patches/0006-rpcRmApiFree-GSP-shortcircuit-on-gpu-lost.patch`
    (Lever N)
  - `patches/0008-issueRpcAndWait-shortcircuit-on-gpu-lost-Lever-O.patch`
    (Lever O)
  - `patches/0010-os-pci-is-disconnected-helpers-Lever-Q.patch` (Lever
    Q primitives — the os-pci.c wrappers)
  - `patches/0011-osDevReadReg032-Lever-Q-passive.patch` (Lever
    Q-passive 32-bit short-circuit)
  - `patches/0012-osDevReadReg008-016-Lever-Q-passive.patch` (Lever
    Q-passive 8/16-bit short-circuit)
  - `patches/0013-osDevReadReg032-Lever-Q-active.patch` (Lever Q-active
    post-read detection + verification)
- **aorus-5090 docs consulted (M1+M2 verification):**
  - `docs/lever-Q-design.md` lines 169-340 — full design rationale for
    Q-passive, Q-active, the `os_pci_*` helpers, sink-state
    race-analysis, and effect matrix. **Highly relevant** (this is the
    canonical design doc for what became C5's read-path primitives).
  - `docs/source-review-notes.md` lines 816-976 (Pass 6) — per-callsite
    bug analysis + patch-surface tables for journal.c, nv_debug_dump.c,
    rs_client.c, rs_server.c. **Highly relevant** (canonical bug
    analysis for Lever J-2's 5 sites — exactly the 5 sites C5 covers,
    plus the two Lever N/O sites added later).
  - `docs/lever-catalog.md` lines 210-277 — Lever J-2, N, O entries
    consolidating the run-time justifications. **Relevant** for cross-
    referencing the lever taxonomy.
  - `docs/recovery.md` (binding starter) — operator runbook, **NOT
    relevant** (it covers Lever M-recover semantics, not the crash-
    safety primitives). Dropped per M1.
  - `docs/recovery-mechanism-findings.md` (binding starter) — covers
    bus-reset primitive evidence for Lever M, **NOT relevant** for C5's
    primitives + guards surface. Dropped per M1.
- **Community-signal entries:**
  `docs/patch-improvements/_community-signal.md` §"Bus-loss / GPU-lost
  class" lines 52-64 (#916, #1151) and §1 line 22 (TOSUKUi #979). All
  three are **error-code-commonality** signals (the symptom is
  `NV_ERR_GPU_IS_LOST` or "GPU off the bus"), not **code-path
  commonality** — none of the upstream issues report exercising the
  specific journal.c / nv_debug_dump.c / resserv / `osDevReadReg032`
  paths C5 patches. They support the upstream-PR rationale ("this bug
  class hits Ampere + Ada + Blackwell on non-eGPU, non-TB hardware
  too") without demonstrably running through C5's patched sites. Per
  M5, framed as upstream-PR-rationale strengthening for the C-series
  bundle, not as proof that C5's specific guards fire on those reports.

## v1 archaeology

The C5 surface consolidates **9 aorus-5090 ancestor patches** into a
single primitives-plus-guards cluster, applied 2026-05-12 in the P1-P6
refactor (project memory `project_patch_refactor_2026_05_12`) and
re-carved 2026-05-22 in the C+E+A geometry
(`project_cea_patch_geometry_2026_05_22`). The binding listed 5
ancestors; the grep for `gpu_lost|dead.?bus|shortcircuit|disconnected`
surfaced 4 additional ancestors — patches 0010, 0011, 0012, 0013 —
which contributed the `os_pci_*` helpers, the U8/U16/U32 read-path
short-circuits, and the post-read U32 detection. All 9 are
consolidated into C5; none are missed.

- **Original design intent (Lever J-2 — journal/dump/resserv guards):**
  `docs/source-review-notes.md` lines 791-796 ("Lever J-2 patch surface
  expanded. Originally needed L3 graceful-failure — now needs all
  three: short-circuit on `PDB_PROP_GPU_IS_LOST`, log-instead-of-
  assert, and break-the-loop. ~13 lines total."). Lines 961-976
  enumerate the **5-site, ~13-line** "L3 patch surface table" that C5
  implements verbatim: `rs_client.c:844`, `rs_server.c:259`,
  `nv_debug_dump.c:269`, `rcdbAddRmGpuDump` short-circuit,
  `journal.c:2239` assert relaxation. Original justification was the
  Pass 5 deadlock-locus inventory (lines 753-775) which traced kernel
  hangs to nested-lock-held GSP RPC failures in those exact 5 sites.

- **Original design intent (Lever Q — read-path primitives + guards):**
  `docs/lever-Q-design.md` lines 219-234 ("If **either** is set,
  return `0xFFFFFFFF`... immediately without reading. This makes
  every subsequent MMIO read after a loss event return fast, draining
  locks, allowing the kernel scheduler to make progress, allowing the
  AER recovery workqueue to dispatch (which might finally let M-base
  fire)..."). The two-source predicate
  (`os_pci_is_disconnected || PDB_PROP_GPU_IS_LOST`) was designed
  because **either** the kernel's AER machinery or the driver itself
  can declare loss first; consulting both keeps detection symmetric.

- **Original design intent (Lever N — `rpcRmApiFree_GSP` asymmetric
  return):** `docs/lever-catalog.md` lines 234-253 ("at entry of
  `rpcRmApiFree_GSP`, check `PDB_PROP_GPU_IS_LOST`; if set, return
  `NV_OK` silently — the resource is going to be freed by hardware
  reset anyway"). The asymmetric `NV_OK` return (vs. Lever O's
  `NV_ERR_GPU_IS_LOST`) was empirically validated in lite-145232 /
  lite-153940: it "collapsed 107 cleanup-path assertions to zero" by
  funnel-fixing at the one call site instead of patching each
  individual assert.

- **Constraints discovered (`os_pci_set_disconnected` race analysis):**
  `docs/lever-Q-design.md` lines 195-207. The kernel's
  `pci_dev_set_io_state()` is private (not exported); the design
  reproduces the relevant `WRITE_ONCE` for `pci_channel_io_perm_failure`,
  explicitly citing this as a **sink state** (no transitions out) which
  makes the non-atomic write race-safe against concurrent AER. C5's
  source comment (`os-pci.c` lines 220-232) preserves this exact
  rationale.

- **Constraints discovered (post-read U32 verification avoids
  recursion):** `docs/lever-Q-design.md` lines 285-334 (Q-active). The
  verification read uses `NV_PRIV_REG_RD32(nv->regs->map_u,
  NV_PMC_BOOT_0)` directly rather than going through `osDevReadReg032`
  to avoid recursion + log-spam. "If the bus is dead, this read takes
  one hardware-completion-timeout (~50ms) but happens at most ONCE per
  failure event due to the first-fire latch." C5 preserves this design
  in source comments at `os.c` lines 1997-2005 and 2001-2005.

- **Alternatives considered + rejected (asymmetric Lever N/O return
  vs. uniform `NV_ERR_GPU_IS_LOST` everywhere):** `docs/lever-catalog.md`
  lines 240-273 explicitly contrasted the two options. Lever N's
  `NV_OK` return was chosen because (a) the resserv asserts at 107
  sites would otherwise each need individual relaxation; (b) the free
  RPC is best-effort on a lost GPU (the device is gone; the host's
  bookkeeping is what matters); (c) Lever O covers the other ~50 RPC
  paths (alloc/control/register/etc.) with the canonical
  `NV_ERR_GPU_IS_LOST`. C5 preserves this asymmetry verbatim and
  documents it inline at `rpc.c` line 11516 ("which must return NV_OK
  because the resserv teardown asserts on it").

- **Alternatives considered + rejected (post-read verification
  comparison: `!= saved_boot_id` vs. `== 0xFFFFFFFF`):** The aorus
  ancestor `patches/0013-osDevReadReg032-Lever-Q-active.patch` lines
  47-48 compared `pmc_boot_0_now != nvp->pmc_boot_0` (any mismatch
  from saved boot ID). C5's consolidation refined this to `pmcBoot0 ==
  NV_GPU_BUS_DEAD_VALUE_U32` (strictly the dead-bus signature). This is
  a **deliberate strictness refinement**: the aorus form would
  false-positive on any non-saved-boot-ID value (e.g. a register that
  happens to share an upper word with the boot ID); C5's form fires
  only on the canonical all-1s PCIe completion-timeout return. The
  verification site reads `NV_PMC_BOOT_0` specifically — by PCIe
  hardware semantics, a torn or absent device returns all-1s after the
  completion timeout, so the stricter check is both safer and complete.
  Captured as a deliberate evolution in `## Improvements considered`
  below (C5-crash-safety-I1, rejected — the strictness IS the
  improvement, already applied in the P5 → C5 consolidation).

- **Alternatives considered + rejected (U8/U16 readers logging vs.
  U32-only logging):** `docs/lever-Q-design.md` lines 270-272 ("The
  8/16-bit variants get the same protection structure with
  `0xFF`/`0xFFFF` returns") + aorus
  `patches/0012-osDevReadReg008-016-Lever-Q-passive.patch` lines 9-27
  which intentionally omit any log line from the U8/U16 short-circuit.
  C5 preserves this design (`os.c:osDevReadReg008` and `osDevReadReg016`
  have the short-circuit but no `NV_GPU_LOST_LOG_ONCE` call). The
  rationale: a dead-bus read storm flows through U32 first (or
  alongside it); logging from three sibling readers either floods the
  log or duplicates the U32 line uselessly. Codified in C5's v2
  Telemetry contract (intent lines 248-252).

- **Alternatives considered + rejected (function-scope-static
  log-once latches vs. per-GPU counters):** The aorus ancestors used a
  per-site `static int s_tb_egpu_lever_<X>_logged = 0` pattern (visible
  in patches 0006 lines 26-31, 0008 lines 30-37, 0011 lines 32-43,
  0013 lines 49-65). C5 abstracts this into the
  `NV_GPU_LOST_LOG_ONCE(level, fmt, ...)` macro in `nv-gpu-lost.h`
  lines 49-57 — same shape (function-scope-static one-shot latch), no
  per-GPU counter, no exported sysfs surface. The v2 review (lines
  279-291) captured the rationale: the latch is zero overhead on
  healthy paths; per-GPU counters are policy/observability surface
  that belongs in the addon-layer `A4-close-path-telemetry`, not in a
  transport-agnostic upstream-candidate Core patch.

- **Forgotten / latent invariants surfaced (the
  `_rcdbAddRmGpuDumpCallback` assert is held under three nested
  locks):** `docs/source-review-notes.md` lines 920-933. Pass 6 noted
  that `_rcdbAddRmGpuDumpDeferred` holds **RM Semaphore + API lock +
  GPU lock** when the `NV_ASSERT(status == NV_OK)` fires; if the assert
  takes a debug breakpoint or if its own state-collection code attempts
  more register reads, the resulting hang is under three nested locks
  and tears down the host. The C5 fix (log-instead-of-assert at the
  callback site PLUS short-circuit at `rcdbAddRmGpuDump` entry) is
  defense-in-depth precisely because of this latent invariant: even if
  the short-circuit somehow failed, the assert-to-log relaxation
  prevents the nested-lock deadlock. v2 intent encodes this as the
  "Crash dump path on a lost GPU returns immediately" Scenario
  (intent lines 150-160).

- **Forgotten / latent invariants surfaced (the engine-dump loop's
  existing `PDB_PROP_GPU_INACCESSIBLE` check sets a flag but does not
  break):** `docs/source-review-notes.md` lines 832-840 and 851. The
  vanilla loop in `nvdDumpAllEngines_IMPL` HAS a
  `PDB_PROP_GPU_INACCESSIBLE` advisory flag-set inside the loop, but
  the flag is purely informational — the loop continues to call every
  remaining engine callback. C5's fix promotes that flag-set to a
  loop-break and additionally covers `PDB_PROP_GPU_IS_LOST` (the
  vanilla code "doesn't even check the latter here", per source-
  review-notes line 852). C5's source comment at `nv_debug_dump.c`
  lines 278-283 explicitly cites this asymmetry, making the latent
  invariant explicit for future maintainers.

## Improvements considered

### C5-crash-safety-I1 — Post-read verification: keep `== NV_GPU_BUS_DEAD_VALUE_U32` (strict) vs. aorus form `!= nvp->pmc_boot_0` (loose)

- **Lens:** robustness
- **Current state:** `src/nvidia/arch/nvalloc/unix/src/os.c` line 2014
  compares the verification read against `NV_GPU_BUS_DEAD_VALUE_U32`
  (the canonical all-1s PCIe completion-timeout return). The aorus
  ancestor patch `0013-osDevReadReg032-Lever-Q-active.patch` lines
  47-48 compared against the saved boot ID `nvp->pmc_boot_0` (any
  mismatch triggers loss declaration).
- **Proposed state:** keep v1's strict `== NV_GPU_BUS_DEAD_VALUE_U32`
  comparison. (Considered: revert to the aorus form for symmetry with
  `osHandleGpuLost` which compares against `nvp->pmc_boot_0`.)
- **Value:** keeps the false-positive risk minimal. The verification
  site reads `NV_PMC_BOOT_0` directly; PCIe hardware semantics
  guarantee an all-1s return on a torn or absent device after the
  completion timeout. A partial-corruption case (returning some
  non-all-1s, non-saved-boot-ID value) is not a real-world dead-bus
  failure mode at this register, so the loose form would only add
  false-positive risk without expanding genuine coverage. The strict
  form also matches the symmetric U8/U16/U32 short-circuit values in
  `nv-gpu-lost.h` (all defined as the all-1s sentinel), so the
  predicate-and-value relationship is consistent across the C5
  surface.
- **Cost:** zero (already in v1; this is a re-verification of the P5 →
  C5 consolidation decision).
- **Verification mode:** A (code-reading against
  `docs/lever-Q-design.md` lines 301-321 + aorus patch 0013 lines
  47-48).
- **Intent impact:** none (the intent's "Fresh dead-bus read promotes
  GPU to lost state" Scenario at intent lines 117-128 already specifies
  the verification check returns `NV_GPU_BUS_DEAD_VALUE_U32` —
  encoded explicitly).
- **Triage decision:** reject
- **Resolution:** rejected because the strict check is the deliberate
  refinement applied during the P5 → C5 consolidation; reverting to
  the aorus form would re-introduce false-positive risk without
  expanding genuine coverage. The asymmetry with `osHandleGpuLost`'s
  saved-boot-ID compare is intentional: `osHandleGpuLost` is a
  preflight at a single site (C3) where the saved boot ID is in scope
  and the comparison narrows false positives via retry; C5's post-read
  detection is a generic chokepoint that needs the canonical hardware-
  guaranteed signature only.

### C5-crash-safety-I2 — Document the `gpuSetDisconnectedProperties` calling-convention assumption inline (v2-D2 re-examination)

- **Lens:** quality (comment clarity)
- **Current state:** `os.c:osDevReadReg032` post-read detection block
  (lines 1997-2024) calls `gpuSetDisconnectedProperties(pGpu)` then
  `os_pci_set_disconnected(nv->handle)` with no inline comment about
  the calling-convention assumption (that
  `gpuSetDisconnectedProperties` is a pure property-bag mutation,
  idempotent under racy concurrent calls, and does not itself acquire
  locks).
- **Proposed state:** add a one-line comment noting the calling-
  convention.
- **Value:** future maintainer reading the post-read detection block
  does not have to chase `gpuSetDisconnectedProperties` (in
  `src/nvidia/src/kernel/gpu/gpu.c`, not touched by C5) to verify the
  call is safe from a path that may not hold the GPU lock.
- **Cost:** +1 line of comment text; adds to an already long comment
  block above the detection.
- **Verification mode:** A (code-reading).
- **Intent impact:** none (calling-convention assumption is
  implementation detail, not a requirement-level claim).
- **Triage decision:** reject
- **Resolution:** rejected per the bloat budget for low-value comment
  churn on the largest Core patch. The v2 review (D2) deferred this
  same comment; sub-cycle 3's archaeology confirms the deferral —
  `docs/lever-Q-design.md` lines 301-321 already note the calling-
  convention in the design doc, and v1's existing comment block (15
  lines) already explains the recursion-avoidance and one-time-cost
  rationale. Adding another line crosses into bloat territory without
  removing a real footgun.

### C5-crash-safety-I3 — Cross-patch C2-intent reconciliation (v2-D3 re-examination)

- **Lens:** dedup (cross-patch consistency, not C5-internal)
- **Current state:** `docs/patch-intents/C2-aer-internal-unmask.md`
  lines 25-26 and 90-93 attribute `pci_error_handlers` registration to
  `[[C5-crash-safety]]`. The correct attribution is
  `[[C4-err-handlers-scaffold]]` (C4 sets
  `.err_handler = &nv_pci_err_handlers`; C5 consumes the disconnected
  state without registering callbacks). v2-D3 in
  `docs/patch-reviews/C5-crash-safety.md` lines 393-399 flagged this
  for Task 14 cross-patch consistency reconciliation.
- **Proposed state:** Task 14's cross-patch audit fixes C2's two prose
  references. C5 itself is correct (its own Scope boundary explicitly
  states "This patch does NOT register `pci_error_handlers`").
- **Value:** prevents future readers from believing C5 registers
  callbacks; preserves the C4↔C5 separation.
- **Cost:** zero for C5 (the fix lands in C2's intent during Task 14).
- **Verification mode:** A (cross-patch prose).
- **Intent impact:** none for C5; refines C2 in Task 14.
- **Triage decision:** defer
- **Resolution:** deferred to Task 14 — out-of-scope for C5's own
  triage. C5's own intent is correct; the inconsistency lives in C2's
  Scope boundary text. Captured here so Task 14 doesn't have to
  re-derive the finding.

### C5-crash-safety-I4 — Log line includes pre-state context (aorus 0013 form) vs. minimal (C5 form)

- **Lens:** quality (telemetry richness)
- **Current state:** `os.c:osDevReadReg032` post-read detection logs
  `"... (offset=0x%08x, NV_PMC_BOOT_0=0x%08x); declaring GPU lost\n"`
  via `NV_GPU_LOST_LOG_ONCE`. The aorus ancestor `0013` lines 49-65
  also captured `os_pci_disconnected` and `gpu_is_lost` pre-state in
  the log block.
- **Proposed state:** keep v1's minimal log. (Considered: add
  pre-state context.)
- **Value:** the aorus-era richness was diagnostic scaffolding from
  the bug-investigation period. With C5's design invariants in place,
  the pre-state is implied: entry to the post-read block requires
  `!pGpu->getProperty(pGpu, PDB_PROP_GPU_IS_LOST)` (gated at line
  2011) AND the U32 short-circuit at line 1992 was not taken (so
  `os_pci_is_disconnected` was also false). Adding the pre-state would
  reprint values whose truth is structurally guaranteed by the entry
  gate.
- **Cost:** zero (the strict-minimal log is already in v1).
- **Verification mode:** A (code-reading).
- **Intent impact:** none.
- **Triage decision:** reject
- **Resolution:** rejected because the structural guarantees from the
  entry gate make the additional pre-state context redundant. The v2
  Telemetry contract (intent lines 234-235) already specifies the
  exact format string and the rationale ("the offset that triggered
  detection and the verification result").

### C5-crash-safety-I5 — Sovereignty re-verification: C5 primitives match Core-layer canonical placement

- **Lens:** sovereignty
- **Current state:** C5's primitives live in:
  - `os_pci_is_disconnected` / `os_pci_set_disconnected` /
    `os_pci_is_thunderbolt_attached` — `kernel-open/nvidia/os-pci.c`
    (the canonical OS-shim PCI helper file) + the two `os-interface.h`
    headers (kept in sync).
  - `NV_GPU_BUS_DEAD_VALUE_U{8,16,32}` + `NV_GPU_LOST_LOG_ONCE` +
    `NV_ASSERT_OR_GPU_LOST` — `src/nvidia/inc/kernel/gpu/nv-gpu-lost.h`
    (a new GPU-scoped header in the canonical `inc/kernel/gpu/`
    location).
  - `osIsGpuBusDead` predicate — `static inline` in
    `src/nvidia/arch/nvalloc/unix/src/os.c` immediately above the
    three readers (file-scope private).
- **Proposed state:** keep v1's placement. Verify no `tb_egpu_*` /
  `aorus_*` branding leaked from the aorus ancestors.
- **Value:** the de-branded, canonically-placed primitives are the
  upstream-PR-ready surface. Any leaked branding would gate the C5
  upstream filing.
- **Cost:** zero (already correct in v1).
- **Verification mode:** B (grep evidence).
- **Intent impact:** none.
- **Triage decision:** reject
- **Resolution:** rejected because no change is needed — verification
  passes. Evidence: `grep -nE 'aorus|AORUS|Aorus|injector|tb_egpu'
  src/nvidia/inc/kernel/gpu/nv-gpu-lost.h kernel-open/nvidia/os-pci.c
  src/nvidia/arch/nvalloc/unix/src/os.c
  src/nvidia/src/kernel/diagnostics/journal.c
  src/nvidia/src/kernel/diagnostics/nv_debug_dump.c
  src/nvidia/src/kernel/vgpu/rpc.c
  src/nvidia/src/libraries/resserv/src/rs_client.c
  src/nvidia/src/libraries/resserv/src/rs_server.c` returns zero
  matches. The sovereignty check is the load-bearing precondition for
  C5's upstream-candidacy claim; v1 satisfies it.

### C5-crash-safety-I6 — Cross-patch C5↔A1 dedup re-verification

- **Lens:** dedup
- **Current state:** C5 defines `os_pci_is_disconnected`,
  `os_pci_set_disconnected`, `os_pci_is_thunderbolt_attached`,
  `osIsGpuBusDead`, and the `NV_GPU_BUS_DEAD_VALUE_U*` /
  `NV_GPU_LOST_LOG_ONCE` / `NV_ASSERT_OR_GPU_LOST` macros. A1
  (`a1-pcie-primitives`, branch `a1-pcie-primitives`) defines
  `tb_egpu_recover_read_wpr2`, `tb_egpu_recover_walk_to_root_port`,
  `tb_egpu_recover_read_dpc_state`, `tb_egpu_recover_read_aer_full`,
  `tb_egpu_dump_aer_trigger_event` in
  `kernel-open/nvidia/nv-tb-egpu-pcie.{c,h}`.
- **Proposed state:** confirm zero overlap; document the genuine
  separation.
- **Value:** confirms the C5 / A1 split: C5 wraps the kernel's
  `pci_dev_*` PCI-state machinery (state queries/transitions); A1
  builds AER snapshot + WPR2 read infrastructure on top of the kernel's
  PCI config-space helpers. Different layer of the same kernel API.
  Different responsibilities. Different naming. No primitives are
  duplicated.
- **Cost:** zero (already separated in v1).
- **Verification mode:** B (cross-branch diff).
- **Intent impact:** none.
- **Triage decision:** reject
- **Resolution:** rejected because no change is needed.
  `git diff c5-crash-safety..a1-pcie-primitives -- src/ kernel-open/ |
  head -200` shows A1 adds **only**
  `kernel-open/nvidia/nv-tb-egpu-pcie.{c,h}` + a Kbuild source-list
  line — no overlap with C5's `os-pci.c` additions or `nv-gpu-lost.h`.
  Function-name overlap check: A1's `tb_egpu_*` namespace and C5's
  `os_pci_*` / `NV_GPU_*` namespace are disjoint. The split is
  honest: C5's primitives are addon-consumable + upstream-friendly;
  A1's primitives are addon-internal AER/WPR2 capture helpers.

### C5-crash-safety-I7 — Cross-patch C4↔C5 contract verification

- **Lens:** dedup / sovereignty
- **Current state:** C4 (`c4-err-handlers-scaffold`) registers
  `pci_error_handlers` via `nv_pci_driver.err_handler =
  &nv_pci_err_handlers` in `kernel-open/nvidia/nv-pci.c`. C5 (this
  patch) does NOT register handlers; it provides the de-branded
  primitives (`os_pci_*` + `nv-gpu-lost.h`) that the C4 handlers and
  the addon recovery stack consume.
- **Proposed state:** confirm the contract. Note that the unified diff
  `595.71.05..c5-crash-safety` carries the C4 hunks too (because C5's
  branch sits on top of C4 in the stack), but the **specific** commits
  separate cleanly: `75e823ef` is C4 (`nv-pci: register
  pci_error_handlers`); `b215ec9f` + `416bdc37` are the C5-specific
  commits.
- **Value:** confirms the C4↔C5 separation that sub-cycle 2's C2
  review (commit `89a69b9`) had to retroactively correct (per
  `docs/patch-reviews/C5-crash-safety.md` lines 393-399, the v2-D3
  finding). C5's own intent + review have always carried the correct
  attribution.
- **Cost:** zero.
- **Verification mode:** B (`git log` separation + intent prose).
- **Intent impact:** none.
- **Triage decision:** reject
- **Resolution:** rejected because no change is needed.
  `git log --oneline 595.71.05..c5-crash-safety` confirms the
  per-commit separation:
  - `75e823ef` C4 — `nv-pci: register pci_error_handlers`
  - `b215ec9f` C5 — `os-pci: add os_pci_is/set_disconnected helpers`
  - `416bdc37` C5 — `crash-safety: bound driver paths that operate on
    an off-the-bus GPU`
  C5's intent Scope boundary (intent lines 196-201) explicitly states
  "This patch does NOT register `pci_error_handlers`. The kernel's
  `struct pci_error_handlers` table is registered by
  [[C4-err-handlers-scaffold]] on `nv_pci_driver.err_handler`."

## Re-examination of sub-cycle 2 deferrals

- **v2-D1** — "De-branding verified clean" → v3 disposition:
  **upheld**. Re-verified via the same grep at v3-tip; result is still
  zero matches. Evidence:
  `grep -nE 'aorus|AORUS|Aorus|injector|tb_egpu'` across all 8 C5-
  touched files (covered in I5 above).
- **v2-D2** — "`gpuSetDisconnectedProperties` calling-convention
  comment" → v3 disposition: **upheld (still deferred)**. The aorus
  archaeology (`docs/lever-Q-design.md` lines 301-321) confirms the
  calling-convention is implementation detail; v1's 15-line comment
  block above the post-read detection already captures the
  recursion-avoidance, one-time-cost, and entry-gate rationale.
  Adding more comment text crosses the bloat threshold without
  removing a footgun. Captured here as I2 (reject).
- **v2-D3** — "C2 intent inaccurately attributes `pci_error_handlers`
  registration to C5" → v3 disposition: **upheld (deferred to Task
  14)**. C5's own intent + review are correct; the inconsistency is
  in C2's prose. Task 14's cross-patch audit owns the fix. Evidence:
  v1 commit log shows C4 registers (`75e823ef`); C5 does not (`b215ec9f`
  + `416bdc37`). Captured here as I3 (defer).
- **v2-D4** — "No must-fix deltas" → v3 disposition: **upheld**. The
  triangulated 9-ancestor archaeology surfaces no new must-fix items.
  Every Scenario in v2 intent's three Requirements remains satisfied
  by v1. Zero-delta sentinel `v1-tip-sha == v2-tip-sha ==
  416bdc37b81a1457e80ec576e1e8990b091136d6` holds.

## Improvements landed

(no code-side improvements landed — all 7 candidates triaged as
reject/defer; the zero-delta sentinel holds.)

## Intent updates landed

(no intent updates landed — v2 intent already encodes the deliberate
P5 → C5 strictness refinements, the asymmetric Lever N/O return, the
de-branded primitive placement, and the C4↔C5 contract. v3
re-triangulation against 9 aorus ancestors strengthens but does not
modify the intent.)

## Done gate

- [x] Every candidate improvement has explicit `Resolution:` (no
  `pending`). _(7 candidates: 1 deferred to Task 14, 6 rejected.)_
- [x] All "land" improvements applied as fork-branch commits citing
  their `<id>-I<N>` IDs. _(N/A — zero "land" triage decisions.)_
- [x] Substantive intent updates landed as precursor commits. _(N/A
  — zero intent changes.)_
- [x] `tools/intent-lint.sh` passes. _(N/A — intent unchanged; same
  v2-status as before.)_
- [x] `tools/validate-patchset.sh` passes. _(Verified at v3 close;
  see closeout commit.)_
- [x] `bash tests/run.sh` green. _(Verified at v3 close: 34/0/0.)_
- [x] Audit-reviewer subagent approved. _(Sub-cycle 3 audit-reviewer
  returned ✅ APPROVED — clean verdict, no "WITH NOTES" caveat.
  All ~10 spot-checked citations verbatim; 9-ancestor consolidation
  confirmed complete (none missed; 14 candidate ancestors grep'd → 9
  in C5 + 5 correctly attributed to C3/C4/A2/A3/A4); C4↔C5 contract
  (C4 registers, C5 consumes) verified; C5↔A1 dedup namespace-disjoint
  (`os_pci_*` + `NV_GPU_*` vs `tb_egpu_*`); sovereignty zero
  project-brand matches across 13 touched files; all 7 triages SOUND;
  I1 strict-vs-loose adjudication SOUND. Audit verdict: "C5 is
  upstream-PR-ready from a triangulated-review perspective." Audit
  deltas: none required.)_

## Cross-references

- Intent file: `docs/patch-intents/C5-crash-safety.md`
- Review file: `docs/patch-reviews/C5-crash-safety.md`
- Manifest row: `patches/manifest` line for `C5-crash-safety` (layer
  `base`, source `fork:c5-crash-safety`)
- Vanilla baseline files (all 8):
  - `kernel-open/common/inc/os-interface.h`
  - `kernel-open/nvidia/os-pci.c`
  - `src/nvidia/arch/nvalloc/unix/include/os-interface.h`
  - `src/nvidia/arch/nvalloc/unix/src/os.c`
  - `src/nvidia/inc/kernel/gpu/nv-gpu-lost.h` (NEW; no vanilla
    counterpart)
  - `src/nvidia/src/kernel/diagnostics/journal.c`
  - `src/nvidia/src/kernel/diagnostics/nv_debug_dump.c`
  - `src/nvidia/src/kernel/vgpu/rpc.c`
  - `src/nvidia/src/libraries/resserv/src/{rs_client.c,rs_server.c}`
- Fork branch: `c5-crash-safety` on `apnex/open-gpu-kernel-modules`
  (tip `416bdc37`)
- aorus-5090 ancestor patches (9 consolidated into C5):
  - `patches/0002-journal-rcdbAddRmGpuDump-shortcircuit-and-relax-assert.patch`
  - `patches/0003-nvDumpAllEngines-break-on-gpu-lost.patch`
  - `patches/0004-resserv-cleanup-asserts-accept-gpu-lost.patch`
  - `patches/0006-rpcRmApiFree-GSP-shortcircuit-on-gpu-lost.patch`
  - `patches/0008-issueRpcAndWait-shortcircuit-on-gpu-lost-Lever-O.patch`
  - `patches/0010-os-pci-is-disconnected-helpers-Lever-Q.patch`
  - `patches/0011-osDevReadReg032-Lever-Q-passive.patch`
  - `patches/0012-osDevReadReg008-016-Lever-Q-passive.patch`
  - `patches/0013-osDevReadReg032-Lever-Q-active.patch`
- aorus-5090 docs cited:
  - `docs/lever-Q-design.md` lines 169-340 (Q-passive + Q-active
    design)
  - `docs/source-review-notes.md` lines 791-976 (Pass 6 — Lever J-2
    patch surface, 5-site table)
  - `docs/lever-catalog.md` lines 210-277 (Lever J-2/N/O entries)
- Upstream issue:
  <https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979> —
  Blackwell GPU over Thunderbolt: brief PCIe link drop commits GPU to
  permanent lost state. C5 is the upstream-friendly crash-safety
  surface that contains the secondary blast radius once a disconnect
  is declared (by C3's preflight retry, by C4's err_handlers, or by
  C5's own post-read detection).
- Community signal: `docs/patch-improvements/_community-signal.md`
  §1 (TOSUKUi #979 — bus-loss class), §"Bus-loss / GPU-lost class"
  (#916 Palit 3090, #1151 RTX 5080 Xid 79). All three are error-code-
  commonality signals (NV_ERR_GPU_IS_LOST / "GPU off the bus"); per
  M5 framed as upstream-PR-rationale strengthening, not as proof that
  C5's specific code paths fire on those reports.
- Related catalogs: `docs/patch-improvements/C2-aer-internal-unmask.md`
  (makes Internal Errors visible — C5 makes the disconnected state
  survivable); `docs/patch-improvements/C3-gpu-lost-retry.md` (the
  preflight retry at one site — C5 contains every other site once a
  disconnect is declared); `docs/patch-improvements/C4-err-handlers-scaffold.md`
  (registers `pci_error_handlers` — C5 provides the de-branded
  primitives those handlers and the addon recovery stack consume).
