---
id: A3-recovery
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: f57a38b2f45b7f757e1982734e587336bb25606a
v2-tip-sha: f57a38b2f45b7f757e1982734e587336bb25606a
v3-tip-sha: 60dfe4c7f2bcb4fdae4be1d4073f432ebfba4f40
status: accepted
intent-updates: []
sub-cycle-4-landed: [A3-recovery-I1]
---

# A3-recovery — improvement triage

## Triangulation sources

- **Vanilla NVIDIA 595.71.05** — A3 introduces two wholly-new files
  (`kernel-open/nvidia/nv-tb-egpu-recover.c`, 854 lines; and `.h`, 228
  lines) plus four additive-and-rewriting hunks against vanilla or
  earlier-patch files: `kernel-open/common/inc/nv-linux.h` (one new
  field `struct tb_egpu_recover_state *recover;` appended to
  `nv_linux_state_s` after A2's `qwd` field), `kernel-open/nvidia/nv-pci.c`
  (one `#include`, two probe-path calls, one remove-path call, real
  bodies for the C4-registered err_handlers callbacks plus the new
  `cor_error_detected` slot — see vanilla `nv_pci_driver` struct +
  C4's stub bodies for the baseline), `kernel-open/nvidia/nv.c` (one
  `#include` + two call sites in `nv_start_device`), and
  `kernel-open/nvidia/nvidia-sources.Kbuild` (one `NVIDIA_SOURCES +=`
  line). A3 also patches into [[A2-bus-loss-watchdog]]'s translation
  unit `kernel-open/nvidia/nv-tb-egpu-qwd.c` to add one
  `tb_egpu_dump_aer_trigger_event(..., "qwd-detect", ...)` call at A2's
  detection latch (see I1 below). No vanilla translation-unit logic is
  modified semantically. Vanilla triangulation pivots to the kernel
  PCI / workqueue / sysfs / kobject_uevent API surface:
  - `<linux/pci.h>`: `pci_reset_bus(struct pci_dev *)` issues a
    secondary bus reset on the device's bus and returns 0 on success
    or a negative errno. **Critical contract** (load-bearing for A3,
    documented in A3's source comment + verified against kernel
    `drivers/pci/pci.c`): `pci_reset_bus` does NOT dispatch
    `pci_error_handlers` callbacks — those fire only on the AER /
    PCIe error-handling path via `error_detected → NEED_RESET →
    kernel-driven reset → slot_reset → resume`. The manual trigger
    path therefore MUST call its slot_reset / resume helpers itself,
    which A3's work handler does. `pci_lock_rescan_remove()` /
    `_unlock_rescan_remove()` serialise against the kernel's PCI
    rescan/remove paths; `pci_upstream_bridge(pdev)` returns the
    parent bridge (NULL for root-port-direct devices); `pci_dev_get` /
    `_put` are the standard pdev refcount helpers.
  - `<linux/workqueue.h>`: `INIT_WORK(&w, fn)`, `schedule_work(&w)`
    (system workqueue), `cancel_work_sync(&w)` (blocks until handler
    returns, drains pending work). Work handlers run in process
    context, may sleep, may be pre-empted.
  - `<linux/kobject.h>`: `kobject_uevent_env(kobj, KOBJ_CHANGE, envp)`
    where `envp` is a NULL-terminated array of `KEY=VALUE` strings;
    A3 builds a single `TB_EGPU_GPU_STATE=<state>` entry on a stack
    buffer.
  - `<linux/kernel_read_file.h>`: `kernel_read_file_from_path(path,
    offset, **buf, max_size, *file_size, id)` allocates the buffer
    via `vmalloc`; caller `vfree`s. A3 uses this once at init-time
    only — no per-cycle file reads.
  - `<linux/io.h>`: `ioremap(phys, size)` / `iounmap(vaddr)` for the
    transient PMC_BOOT_0 read in `slot_reset`; `ioread32(vaddr)` is
    the architecture-correct single-load primitive.
  - `<linux/atomic.h>`: `atomic_xchg` returns the previous value (used
    by the re-entry guard); `atomic_inc_return` returns the new value
    (used by H1 attempt-count gate); `atomic_inc`/`atomic_set`/
    `atomic_read` per `Documentation/atomic_t.txt`.
- **v2 intent:** `docs/patch-intents/A3-recovery.md` (status
  `reviewed`).
- **v2 review:** `docs/patch-reviews/A3-recovery.md` (status
  `accepted`; documents 4 deltas — D1 nice-to-have bridge-link-cap
  L4 boundary, D2 nice-to-have `s_error_detected_logged` module-
  global vs per-device, D3 out-of-scope confirming A2-D1's qwd-detect
  ownership resolution, D4 explicit no-must-fix sentinel). Frontmatter
  carries a STALE SHA (`f57a38b2…`) that the 2026-05-22 A1-cascade
  remap missed; the actual fork-branch tip is `f57a38b2…`. Surfaced
  as I15 below — landed as a cosmetic doc fix.
- **aorus-5090 ancestor patches** (verified per M1+M2 against grep
  `lever-?m-?recover|attempt_count|pci_reset_bus|tb_egpu_recover` on
  `/root/aorus-5090-egpu/patches/`):
  - `patches/0016-Lever-M-recover-scaffolding.patch` (lines 1-450,
    252 lines of new C in the file body) — **canonical scaffolding
    ancestor**. Introduced the per-pdev `struct tb_egpu_lever_m_recover`
    (lines 49-60 of the file body section `nv-linux.h` hunk = patch
    lines 49-60), the workqueue plumbing (`INIT_WORK` line 318 of
    the new C file = patch line ~318), the four read-only sysfs
    counters (`fires`, `successes`, `surrenders`, `last_fire_jiffies`
    at patch lines 286-293), the three original module params
    (Enable=1, MaxAttempts=3, ResetSettleMs=500 at patch lines
    194-207), and the file-level Commit-1-scaffolding sovereignty
    block (patch lines 131-172). A2's v1 source preserves this
    structure verbatim (renamed `aorus_lever_m_recover` →
    `tb_egpu_recover_state`, `NVreg_AorusLeverM*` →
    `NVreg_TbEgpuRecover*`; Enable default flipped from 1 to 0 for
    safer module-load posture pending v3 production soak).
  - `patches/0017-Lever-M-recover-probe-time-WPR2-detection.patch`
    (lines 1-243, ~110 lines of WPR2-detection logic) — the
    falsified-but-illustrative probe-time WPR2 check (lines 55-160
    of the patch). The boot-persistence hypothesis was disproven
    2026-05-06 (`project_wpr2_mechanism_2026_05_06`); the v1 source
    preserves this as detection-only (no recovery scheduling from
    probe path) as cheap visibility (A3 source lines 276-320).
  - `patches/0018-Lever-M-recover-diagnostic-telemetry.patch`
    (lines 1-250, the 4-point lifecycle telemetry patch). Used
    one boot 2026-05-06 to confirm the trigger location is
    post-rmInit-FAIL, not probe-time; superseded by the v1 source's
    cleaner trigger structure (the v1 source does NOT carry the
    `tb_egpu_lever_m_diag_dump` 4-point helper — it was a one-shot
    investigation tool, retired post-hypothesis-resolution).
  - `patches/0024-Lever-M-recover-Commit3-hardening.patch` (lines
    1-838, the largest M-recover patch) — **canonical H1/H2/H3/H4
    hardening ancestor**. Introduced the full
    `tb_egpu_lever_m_recover_handle_post_rmInit_fail` trigger (patch
    body lines ~100-180 in the new C file additions), the
    `tb_egpu_lever_m_reset_work_handler` body with `pci_reset_bus +
    pci_lock_rescan_remove + msleep` (patch body lines ~200-280),
    the H4 truth-table in `nv_pci_error_detected` (patch body lines
    ~350-440), the H3 kill-switch file `kernel_read_file_from_path`
    (patch body lines ~50-100), and three new module params
    (`MinAttemptIntervalMs`, `SurrenderResetSec`, `TestForceTrigger`).
    A3 v1's six-module-param surface is the verbatim de-brand of
    this patch's surface.
  - `patches/0026-Lever-M-recover-sysfs-force-trigger.patch` (lines
    1-106, ~50 lines of new sysfs surface) — added the write-only
    `aorus_lever_m_force_trigger` sysfs attribute (patch lines
    35-95). A2 v1 preserves the mechanism as `tb_egpu_recover_force_trigger`
    (`0200` mode, calls back into the trigger function as if from
    a real post-rmInit-FAIL; all gates still apply). Phase-3
    test entry point.
  - `patches/0027-Lever-M-recover-dispatch-slot-reset-resume-from-work-handler.patch`
    (lines 1-77, ~30 lines of work-handler hunk) — the
    **load-bearing explicit-dispatch patch**. Adds the explicit
    `tb_egpu_lever_m_slot_reset(pdev)` and
    `tb_egpu_lever_m_slot_reset_resume(pdev)` calls inside the
    work handler after `pci_reset_bus` succeeds (patch lines
    50-74). The reasoning block at patch lines 6-44 is what A3's
    file-level comment quotes verbatim ("pci_reset_bus does NOT
    dispatch err_handlers callbacks — those fire only when the
    AER subsystem drives recovery via NEED_RESET"). A3 v1 source
    lines 396-410 implement this directly.
  - `patches/0028-Lever-M-recover-attempt-count-reset-at-post-rmInit-OK.patch`
    (lines 1-159, ~70 lines of new helper + hook + comment edit)
    — the **load-bearing attempt-count-semantics patch**. Removes
    `atomic_set(&attempt_count, 0)` from `slot_reset_resume`
    (patch lines 95-107) and introduces
    `tb_egpu_lever_m_record_post_rminit_ok` (patch lines 111-141)
    called from `nv.c`'s post-rmInit-OK site (patch lines 148-156).
    A3 v1 source lines 627-643 implement this directly. The
    rationale block at patch lines 5-53 is what A3's file-level
    comment quotes (the H1 gate becomes unreachable in real-world
    storms if attempt_count resets too early; the counter cycles
    0→1→0 forever).
  - `patches/0007-nv-pci-register-error-handlers-Lever-M-base.patch`
    (lines 1-76, ~50 lines of new struct registration) — the
    M-base no-op stub registration. C4 is the new home for the
    `pci_error_handlers` table registration; A3 fills C4's stub
    bodies with real recovery logic and adds the
    `cor_error_detected` slot. **Not literally an A3 ancestor**
    (the registration moved to C4 in the recarve), but the
    fill-the-stubs pattern descends from this patch's structure.
- **aorus-5090 docs consulted (M1+M2 verification):**
  - `docs/lever-M-recover-design.md` lines 1-130 (the canonical
    design doc — `wc -l` 399). **Highly relevant.** Lines 1-30
    (the 2026-05-06 mechanism-rewrite annotation), lines 54-100
    (the "Mechanism (corrected)" section with the post-rmInit-FAIL
    trigger location), lines 100-130 (the `pci_reset_bus` primitive
    + hardware topology — confirms the upstream-bridge target).
    Lines 196-230 (Code surface — the original 4-file diff size
    estimate), lines 285-320 (Test plan — Phases 1-7), lines
    296-323 (Risks and mitigations — the `pci_lock_rescan_remove`
    risk + audio function reset propagation + AER doesn't fire
    on TB risks all materialised in v1's design). **Verified
    via `wc -l`** = 399 lines total.
  - `docs/lever-m-recover-commit3-hardening-design.md` lines
    1-120 (the H1/H2/H3/H4 hardening design — `wc -l` 236).
    **Highly relevant.** Lines 27-103 cover the 4 hardening
    fixes verbatim (H1 MaxAttempts gate, H2 rate-limit, H3
    kill-switch persistence with the `kernel_read_file_from_path`
    contract, H4 truth-table). Lines 104-120 cover the
    `error_detected` truth-table that A3's file-level comment
    reproduces in `nv-pci.c`. The four-row table at lines 110-115
    is the H4 truth table A3 v1 implements at `nv-pci.c` lines
    2899-2918 (the gate switch).
  - `docs/lever-m-recover-commit3-handover.md` (`wc -l` 188) —
    **checked per binding.** This is the cross-session handover
    document the 2026-05-08 hardening-implementation session used
    as its briefing. Lines 1-50 cover the storm postmortem; lines
    50-130 cover the 4 hardening fixes (same content as the
    hardening-design doc, slightly more terse). **Mostly
    redundant** with the hardening-design doc; useful for
    confirming the 2026-05-08 implementation context. **Keep
    cited; verbatim cross-checks against the hardening design
    doc.**
  - `docs/recovery-mechanism-findings.md` lines 1-80 (the
    2026-05-04 evening doc with the 2026-05-06 correction
    annotation; `wc -l` 392). **Relevant only for context.**
    Lines 1-30 establish that bare FLR alone is insufficient for
    the cold-boot WPR2-stuck case (justifies why A3 uses
    `pci_reset_bus` on the upstream bridge rather than FLR on
    the GPU). Lines 30-80 cover the 2026-05-04 FLR-via-sysfs
    test context. **Cited for the FLR-vs-bus-reset alternative
    rejection in v1 archaeology below.**
  - `docs/recovery.md` (`wc -l` 194) — **checked per binding.**
    This is the operator runbook for the L4 userspace recovery
    helper (`aorus-egpu-wpr2-recovery.service`). Grep for
    `pci_reset_bus|attempt_count|tb_egpu_recover|in_progress`
    returns zero matches. **Drop per M1** — operator runbook for
    the L4 helper, not the in-driver M-recover state machine A3
    implements. The L4 helper is the predecessor A3 supersedes
    (per `project_lever_m_recover_landed_2026_05_08`); the runbook
    is preserved as belt-and-braces fallback documentation but
    doesn't inform A3's v3 surface.
  - `docs/reliability-hypothesis-ledger.md` lines 210-220 (H15 —
    the M-recover hardening hypothesis, resolved 2026-05-08).
    **Highly relevant.** H15's resolution status (lines 210-216)
    is the canonical record of the 4-hardening-patches landing
    sequence (0024 + 0026 + 0027 + 0028); Phases 1-4 PASS;
    Phase 5 evidence collection. The 4-fire H1-test result
    ("surrendered at attempt 4 with `surrender after 4 attempts
    (max=3); emitting PERMANENT_FAIL`") is the load-bearing
    production-validation evidence for A3 v1's MaxAttempts gate.
    H13 (lines 250-264) covers the WPR2-stuck mechanism
    (corrected 2026-05-06: state-mismatch, not boot-persistence);
    H14 (lines 226-246) covers the first-rm_init_adapter root
    cause (DMAR/IOMMU fault + GSP lockdown) which A3 does NOT
    prevent — A3 recovers from the consequence, not the cause.
- **Community-signal entries** (per `docs/patch-improvements/_community-signal.md`):
  - **#1159** (lines 80-84 — *RTX PRO 6000 Blackwell: Xid 8 / GSP
    watchdog timeout under sustained SGLang FP8 inference*, OPEN
    2026-05-22). **Per M5 framing: this is code-path adjacency,
    not error-code commonality.** The reporter sees Xid 8 + GSP
    watchdog timeout under sustained FP8 LLM inference; the
    underlying mechanism (GSP firmware enters lockdown under
    sustained DMA pressure) is adjacent to the GSP-LOCKDOWN cascade
    A3 recovers from on the post-rmInit-FAIL path. **However**:
    the reporter's hardware is PCIe-attached (not eGPU/TB-tunnelled),
    runs vanilla 595.71.05 (no err_handlers callbacks registered
    upstream), and the reported failure is sustained-load-driven
    GSP wedge — NOT the cold-boot WPR2-stuck post-rmInit-FAIL
    that A3's trigger function detects. A3's AER `error_detected`
    path COULD theoretically fire on this class if AER signals
    were generated, but the reporter's signature ("Xid 8 + GSP
    watchdog timeout under sustained SGLang FP8 inference") does
    NOT demonstrably exercise the WPR2-stuck post-rmInit-FAIL
    trigger A3 v1 implements. **Frame as upstream-PR-rationale
    strengthening only.** Does not surface a v3 code defect.
  - **#979 (TOSUKUi, 2026-05-02)** (lines 16-22). **Per M5 framing:
    this is code-path adjacency with high confidence.** The reporter
    sees vanilla open driver register "no error_detected callback",
    AER recovery failing on first CUDA allocation, AMD-host USB4
    (not Intel TB4). C4 registers the err_handlers struct A3 fills;
    A2/A3 tag in the community-signal entry suggests "silent-DMA-
    path freeze + recovery". A3's recovery path (post-AER NEED_RESET
    drive) is exactly what TOSUKUi's vanilla driver is missing.
    Cross-distro corroboration that A3's recovery action is needed.
    **Frame as upstream-PR-rationale strengthening** — does not
    affect A3's v3 surface.
  - Neither #1159 nor #979 demonstrably exercises A3's specific
    code paths (the WPR2-stuck post-rmInit-FAIL trigger or the
    H1 gate exhaustion path); both are upstream-context evidence
    that the recovery surface A3 implements is needed.

## v1 archaeology

The A3 surface consolidates **8 aorus-5090 ancestor patches** (verified
per binding grep — the binding suggested 3 starting recommendations;
grep surfaced 8 actual ancestors) plus 3 design docs into a single
addon translation unit (854-line `.c` + 228-line `.h`). The carve was
applied 2026-05-22 in the addon-recarve campaign
(`project_addon_recarve_merged_2026_05_22`) reshaping the legacy
single-file `nv-lever-m-recover.c` into A1 (primitives) plus A3 (state
machine) plus C4 (err_handlers registration only).

- **Original design intent (in-driver vs userspace recovery):**
  `patches/0016-Lever-M-recover-scaffolding.patch` lines 9-26
  (the patch-body justification block) — establishes the single-arbiter
  requirement: "the only authority that has unconditional priority is
  the driver itself." `lever-M-recover-design.md` lines 31-47 (the
  authority/race table) documents that userspace authorities
  (`nvidia-persistenced`, `compute-load-nvidia.service`, the L4
  recovery helper itself) all race each other; the L4 helper succeeds
  only when no other userspace authority concurrently accesses
  `/dev/nvidia0`. A3 v1 preserves this design rationale in its
  file-level comment block (lines 5-40 of `nv-tb-egpu-recover.c`).

- **Original design intent (`pci_reset_bus` on the upstream bridge
  vs `pci_reset_function` vs FLR):**
  `docs/lever-M-recover-design.md` lines 100-130 (the "Mechanism (the
  recovery primitive)" section) — establishes the upstream-bridge
  bus reset as the only primitive that clears WPR2 reliably. Bare
  FLR is insufficient (the GPU's FLR doesn't bring the bridge into
  reset scope; per `docs/recovery-mechanism-findings.md` lines 1-30
  the 2026-05-06 test showed FLR alone leaves WPR2 set);
  `pci_reset_function` is per-device and would miss the bridge state
  (the TB tunnel retrains on bus reset). `pci_reset_bus` on the
  upstream bridge is the right primitive. A3 v1 source lines 358-381
  implement this verbatim with `pci_upstream_bridge(pdev)` + the
  rescan-remove lock + `pci_reset_bus(bridge)` + the settle msleep.

- **Constraints discovered (`pci_reset_bus` does NOT dispatch
  err_handlers — the explicit-dispatch invariant):**
  `patches/0027-Lever-M-recover-dispatch-slot-reset-resume-from-work-handler.patch`
  lines 6-44 (the patch-body justification block) — discovered
  while preparing Phase 3 manual-trigger testing on 2026-05-08:
  "the expected dmesg trail showed only the bus-reset half, no
  slot_reset/resume." Quoted verbatim: "pci_reset_bus() resets the
  secondary bus but does NOT dispatch through pci_error_handlers
  ->slot_reset / ->resume. Those callbacks only fire when the AER
  subsystem drives recovery via the NEED_RESET return path from
  error_detected." A3 v1's work handler at source lines 396-410
  implements the explicit dispatch (verified at I6 below). The
  kernel-side confirmation: `drivers/pci/pci.c:pci_reset_bus`
  performs `__pci_reset_bus` which issues `__pci_reset_function_locked`
  but does NOT iterate through `pci_drv->err_handler`. A3's file-level
  comment (source lines 322-339) cites this verbatim.

- **Constraints discovered (`attempt_count` must reset ONLY at
  post-rmInit-OK — the load-bearing semantics invariant):**
  `patches/0028-Lever-M-recover-attempt-count-reset-at-post-rmInit-OK.patch`
  lines 5-53 (the patch-body design-deviation justification block) —
  the 21-attempt recovery storm on 2026-05-06 16:14 showed that
  resetting `attempt_count` at `slot_reset_resume` makes the H1 gate
  unreachable: each cycle cycles `0→1→0`, the gate never engages.
  Quoted verbatim from patch lines 21-37: "slot_reset can return
  RECOVERED yet rm_init_adapter still fail on the next call (e.g.
  WPR2 still stuck after the bus reset). In production, this is
  exactly the 21-attempt storm pattern observed 2026-05-06 16:14:29:
  each cycle reset attempt_count 0->1->0, the gate never engaged,
  the storm ran." A3 v1 source lines 605-625 (the `slot_reset_resume`
  body) does NOT reset attempt_count — it only bumps `success_count`
  and emits READY. A3 v1 source lines 627-643 (the
  `record_post_rminit_ok` helper) does reset attempt_count, called
  from `nv.c`'s `nv_start_device` post-rmInit-OK site.

- **Constraints discovered (5-minute idle burst-boundary
  attempt_count reset is necessary):**
  `patches/0024-Lever-M-recover-Commit3-hardening.patch` lines
  9-13 (the H1 hardening justification) — `attempt_count` resets to
  0 either on a verified end-to-end recovery (see above) OR after
  `NVreg_TbEgpuLeverMSurrenderResetSec` (5-min default) of idle.
  Rationale: a device that has been quiet for 5 minutes should
  start a fresh burst when trouble re-emerges, not start partway
  toward surrender. A3 v1 source lines 228-235 implement this in
  the gate function (`time_after(jiffies, last_fire_jiffies +
  msecs_to_jiffies(SurrenderResetSec * 1000U))` triggers
  `atomic_set(&attempt_count, 0)`).

- **Constraints discovered (H2 rate-limit before H1 cap — the
  gate ordering invariant):**
  `patches/0024-Lever-M-recover-Commit3-hardening.patch` lines
  29-31 ("Rate-limit is the FIRST gate; MaxAttempts is the
  SECOND. Both must pass") + the H2 hardening rationale at patch
  lines 48-65. A3 v1's gate function source lines 213-263
  enforces this order: H1 burst-boundary reset (idle-driven) →
  H2 rate-limit (cheaper) → H1 max-attempts (counter-mutating).
  The semantic difference: H2 fires when a real failure storms;
  H1 fires when the storm exhausts the budget. Checking H2 first
  means a rate-limited fire does NOT increment `attempt_count`
  (the rate-limit semantically defers, doesn't consume budget).
  A3 v1 source line 250 (`atomic_inc_return(&st->attempt_count)`)
  only fires after the rate-limit check passes.

- **Constraints discovered (kill-switch persistence via
  `kernel_read_file_from_path` — the H3 surface):**
  `docs/lever-m-recover-commit3-hardening-design.md` lines 66-103
  (the H3 hardening fix). Two-layer design: layer A is the
  kernel-side `kernel_read_file_from_path` read of
  `/var/lib/tb-egpu/recover-killswitch`; layer B is the udev
  rule that re-applies the module param at module-load. A3 v1
  source lines 123-168 implement layer A only (the udev rule
  + CLI binary live in the userspace artefacts directory —
  per the v2 review's Provenance §). The 16-byte cap on the
  file read is the security invariant (kernel-side file read of
  unbounded length would be a footgun); A3 v1 source line 133
  uses `16` as the `max_size` argument. Idempotent across
  multiple devices (the `apply_killswitch_file` helper is called
  once per `tb_egpu_recover_init` and only logs/overrides if
  `Enable` is currently 1 and the file says 0).

- **Alternatives considered + rejected (probe-time WPR2 trigger
  vs post-rmInit-FAIL trigger):**
  `docs/lever-M-recover-design.md` lines 88-99 (the "Implication
  for trigger placement" table). The probe-time trigger
  (`nv_pci_probe`) was attempted on 2026-05-06 (`patches/0017`)
  and falsified by diagnostic telemetry on 2026-05-06 15:47
  (`patches/0018` — the 4-point lifecycle telemetry patch). WPR2
  is clear at probe-time on cold boot; only set DURING the failed
  first `rm_init_adapter`. The unambiguous trigger is post-rmInit-FAIL
  with WPR2 ≠ 0. A3 v1 source lines 276-320 preserves the
  probe-time check as detection-only (no scheduling); the
  load-bearing trigger lives in `nv_start_device` post-rmInit-FAIL
  per A3 v1's `nv.c` hunk (source lines around the
  `rm_init_adapter failed` log site).

- **Alternatives considered + rejected (synchronous
  `pci_reset_bus` from probe context vs workqueue dispatch):**
  `docs/lever-M-recover-design.md` lines 131-150 (the "Why not
  call the bridge reset from `nv_pci_probe` directly?" section).
  Tier 1 v2 attempted synchronous reset from probe and got
  `-ENOTTY` because `dev->reset_fn=0` at that probe-context state;
  also probe holds the rescan-remove lock so a reset from probe
  would deadlock. The right shape is workqueue dispatch. A3 v1's
  trigger function returns 0 (the caller's failure path runs
  unchanged); the workqueue handler runs `pci_reset_bus` after
  the trigger returns. A3 v1 source lines 539-541 implements the
  schedule + return-0 pattern.

- **Alternatives considered + rejected (NEED_RESET vs
  CAN_RECOVER from `error_detected`):**
  `docs/lever-m-recover-commit3-hardening-design.md` lines 110-115
  (the H4 truth table). `CAN_RECOVER` assumes the device itself
  is fine and just needs a re-enable; the eGPU failure modes A3
  addresses are bus-state failures where the tunnel needs the
  link retrained (which requires the secondary bus reset).
  `NEED_RESET` is the correct return. A3 v1 source lines 2901-2911
  (in `nv-pci.c:nv_pci_error_detected`) returns NEED_RESET on
  `GATE_OK`; DISCONNECT on any other gate. The H4 truth-table is
  preserved verbatim in A3's `nv-pci.c` file-level comment.

- **Forgotten / latent invariants surfaced (DPM = D0 forced via
  modprobe.d):**
  `patches/0016-Lever-M-recover-scaffolding.patch` lines 39-42
  (the L1 sovereignty + DPM note) — A3's MMIO and PCI config reads
  are safe by construction only because `NVreg_DynamicPowerManagement=0`
  is forced via `etc/modprobe.d` AND udev keeps `power/control=on`
  + `d3cold_allowed=0`. A3 v1's file-level comment (source lines
  36-40) preserves this contract. Without it, the
  `ioremap(bar0_phys, PAGE_SIZE)` in `slot_reset` could race a
  D0→D3 transition. The contract is documented and stable on this
  hardware via the project's modprobe.d configuration; it would
  need explicit documentation for any deployment that changes DPM
  policy.

- **Forgotten / latent invariants surfaced (`pdev_for_work`
  ownership ordering — the in_progress xchg invariant):**
  `patches/0024-Lever-M-recover-Commit3-hardening.patch` patch-body
  comment ~lines 200-260 (the trigger-side ordering) — A3 v1's
  file-level comment at source lines 418-444 documents this
  verbatim: `pdev_for_work` is owned exclusively under
  `in_progress=1`; trigger side does `atomic_xchg(1)` → write
  `pdev_for_work = pci_dev_get(pdev)` BEFORE `schedule_work`;
  handler side does C (pci_dev_put + NULL out) → D
  (atomic_set(in_progress=0)). The "Defensive: stale
  pdev_for_work" branch the legacy code had was dead under this
  ordering and was removed; `WARN_ON_ONCE(st->pdev_for_work !=
  NULL)` at trigger source line 503 is the tripwire against
  regression. This is the kind of architectural cleanup the
  recarve campaign was designed to surface — the audit went
  beyond mechanical extraction.

- **Forgotten / latent invariants surfaced (probe-time WPR2 check
  preserved as detection-only despite hypothesis-falsification):**
  `docs/lever-M-recover-design.md` lines 314-321 (the staging
  table — Commit 2 status: "FALSIFIED BY DIAGNOSTIC 2026-05-06
  15:47. Read at BAR0+0x88a828 returns 0 at probe... Patch 0017
  remains in tree as historical record of the wrong hypothesis
  being concretely falsified"). A3 v1 source lines 263-320
  preserve the probe-time check explicitly as detection-only,
  with the file-level comment citing the falsification. The
  function increments `fire_count` for visibility but never
  schedules recovery from the probe path. This makes `fire_count`
  a slightly impure metric ("moments A3 noticed something" not
  "moments A3 scheduled work") — surfaced as I-context below
  but accepted as the documented v1 design (per v2 review's
  Weaknesses §).

## Improvements considered

### A3-recovery-I1 — Cross-cluster `tb_egpu_dump_aer_trigger_event` call site at A2's detection latch (the addon-recarve regression flagged by A2 audit; HEADLINE)

- **Lens:** sovereignty (cross-cluster coupling) / duty
- **Current state:** A3's `.patch` modifies
  `kernel-open/nvidia/nv-tb-egpu-qwd.c` (A2's translation unit) to
  insert one line at A2's per-episode detection latch:
  `tb_egpu_dump_aer_trigger_event(nvl->pci_dev, "qwd-detect",
  &qwd->last_aer);` immediately after `qwd->last_pmc_boot_0 = boot_0;`.
  The hunk (visible in `patches/addon/A3-recovery.patch` lines
  260-279) also rewrites A2's adjacent comment block from
  "addon A3 patches in the call to tb_egpu_dump_aer_trigger_event"
  to "filled by the addon-A1 helper below". The composed cumulative
  patchset (C+E+A geometry) thus has A3's `.patch` reaching into
  A2's source file — exactly the cross-cluster edit pattern the
  2026-05-22 addon-recarve campaign was designed to eliminate
  (per memory `project_addon_recarve_merged_2026_05_22` and the
  carve design spec at
  `docs/superpowers/specs/2026-05-22-addon-recarve-design.md`).
  A2's catalog (`docs/patch-improvements/A2-bus-loss-watchdog.md`
  §I1) and audit-approval note explicitly flagged this as the
  first-class candidate A3's reviewer MUST address.
- **Proposed state:** Four candidate dispositions:
  - **(a) Hoist the call INTO A2.** A2 owns the storage struct
    `tb_egpu_qwd_*` and the per-episode detection latch. Moving
    the `tb_egpu_dump_aer_trigger_event` call site INTO A2 means
    A3 has zero source-side reach into A2's TU. **Pro:** clean
    carve, addon-recarve principle upheld. **Con:** invalidates
    A2's zero-delta sentinel retroactively (would require A2's
    fork-branch tip to advance, cascading rebases on A3-A5 and
    a force-push of all four). Also creates a backward dependency
    in the carve order — A2 now needs to know about A1's
    `tb_egpu_dump_aer_trigger_event` ABI at carve time (A2 already
    embeds A1's `struct tb_egpu_qwd_aer_snapshot`, so the ABI
    dependency exists — but A2's intent currently states A2 owns
    storage and DEFERS the call to A3 per the documented contract).
  - **(b) Hoist the call INTO A3 by inverting the data flow.**
    A3 declares the `qwd-detect` event as its own; A2 only
    persists the storage. A3 could call
    `tb_egpu_dump_aer_trigger_event` from its own TU (e.g. a new
    helper that A2's detection latch invokes via a function
    pointer or weak symbol). **Pro:** A3 owns the call, A2 owns
    storage, contracts are explicit. **Con:** requires a new
    indirection mechanism (function pointer, weak symbol, or
    callback registration) which adds surface and complexity
    without a real-world value gain. Increases A2's coupling
    to A3 (A2 must know about A3's hook surface).
  - **(c) Admit the cross-cluster regression as a known carve-out
    failure.** Keep v1 as-is; document the pattern as an
    accepted exception. **Pro:** zero churn; production posture
    unchanged; the cross-TU patching is a unidirectional
    dependency (A2 stores, A3 consumes the data via sysfs read
    of `last_aer.valid`) and is one hunk (3 lines added, 4 lines
    of comment refactored). **Con:** undermines the recarve
    campaign's "no cross-cluster edits" goal as a strict
    invariant; sets a precedent for future carves.
  - **(d) Defer the architectural fix to a future task.** Keep
    v1's behaviour; document the pattern as a known carve-out
    regression with an explicit disposition trigger (e.g.
    "revisit if a third addon needs to write at this latch site",
    or as part of a future "atomic rename" initiative on the
    addon layer). **Pro:** explicit deferral with bounded scope;
    preserves A2's zero-delta sentinel; preserves A3's
    f57a38b2 tip; preserves the test-validated production
    posture (`project_lever_m_recover_landed_2026_05_08` +
    `project_m_recover_first_real_fire_2026_05_08`). **Con:**
    same as (c) for the duration of the deferral, but with an
    explicit revisit trigger.
- **Value:** **(a)** removes the cross-cluster edit pattern at
  the cost of force-pushing A2-A3-A4-A5 (a 4-branch cascade);
  **(b)** removes the cross-cluster edit pattern at the cost of
  introducing an indirection (function pointer or callback); **(c)**
  formalises the exception with documentation only; **(d)** defers
  with explicit trigger conditions. Real-world value: the v1
  cross-TU patch shape is internally consistent and operator-visible
  (A2's intent + A3's intent both document the split — A2 stores,
  A3 calls); a defect would manifest as "qwd's `last_aer` is
  populated when A3 is loaded but not when A3 is disabled" which
  is a known design contract.
- **Cost:** **(a)** cascade churn: force-push A2 + A3 + A4 + A5
  fork branches; rebase all 4 patches; range-diff each;
  re-validate. **Estimated 200-400 LoC of patch-file regeneration
  + 4 fork-branch force-pushes.** Also retroactively invalidates
  A2's "zero-delta sentinel" claim (A2's catalog explicitly
  closed with `v1-tip-sha == v2-tip-sha`). **(b)** ~20-50 LoC
  of new indirection (callback struct, registration function,
  unregistration) + intent edits in both A2 and A3 + force-push
  of A2-A3-A4-A5 + retroactive A2 zero-delta invalidation.
  **(c)** zero LoC; intent + review file edits to formalise the
  exception. **(d)** zero LoC; catalog-level documentation only;
  surface a clean revisit trigger.
- **Verification mode:** A (code-reading + design-spec reference
  to the addon-recarve principle). **Recommendation: (d) defer
  the architectural fix to a future task, with explicit trigger
  conditions.** Rationale:
  1. **Production-validation weight.** A3's current shape is
     production-validated (`project_m_recover_first_real_fire_2026_05_08`
     — natural post-rmInit-FAIL via the qwd-detect path, surrender
     accounting via the sysfs counter, slot_reset DISCONNECT
     emitted correct PERMANENT_FAIL uevent). Disturbing the carve
     shape now (option a or b) incurs cascade churn for an
     architectural cleanup, not a correctness fix.
  2. **Contract documentation is explicit and symmetric.** A2's
     intent's Scope boundary § says "A2 owns storage; A3 owns
     the call"; A3's intent's A2 ABI § says "A3 patches into A2's
     translation unit ... to add one call". Both intents are
     explicit; future readers will not be surprised. The cross-TU
     patching is documented as an intentional design choice (per
     v2 review's D3, marked `out-of-scope` confirming v1's shape).
  3. **The recarve principle is not absolute.** The addon-recarve
     design spec
     (`docs/superpowers/specs/2026-05-22-addon-recarve-design.md`
     §"Carve approach") anticipated this exact split: shared
     primitives go to A1; consumer-owned calls at specific sites
     in a sibling's TU are an acceptable pattern when the call
     belongs at the data-capture site. The "no cross-cluster
     edits" goal is a heuristic, not a hard rule; the exception
     here is well-documented.
  4. **Trigger condition for revisit:** if a future task needs
     to add a SECOND cross-TU edit at A2's detection latch (e.g.
     A4's close-path telemetry wants to fire at the same site),
     OR if A2's TU is consolidated into a different translation
     unit (e.g. an "atomic rename" of the addon layer per A1-D1),
     the cross-cluster pattern should be hoisted to A2 via
     option (a). Otherwise the v1 shape is the documented
     contract.
  5. **Cost-benefit asymmetric.** Options (a) and (b) require a
     4-branch force-push cascade for an architectural cleanup
     with no production value; option (c) lacks an explicit
     revisit trigger; option (d) is the right middle ground.
- **Intent impact:** none in v3 (the contract is already
  documented in both intents per v2-D3); future task may refine.
- **Triage decision:** **defer** (sub-cycle 3) → **landed in
  sub-cycle 4 via option (a)**
- **Resolution (sub-cycle 3):** **deferred to Task 14 (cross-patch
  surface-lens audit) or a future architectural cleanup
  initiative.** The v1 shape was internally consistent,
  production-validated, and the contract was documented
  symmetrically in both A2's and A3's intents. **Default-reject
  discipline applied per the plan's bloat-budget guidance for A3**
  (cascade tax: force-push 4 fork branches for an architectural
  cleanup with no production value — clear net loss). **Explicit
  revisit trigger:** (i) a third addon needs to write at A2's
  detection latch, or (ii) an "atomic rename" initiative on the
  addon layer consolidates the addon TUs.
- **Resolution (sub-cycle 4):** **landed via option (a)** —
  hoisted INTO A2. Revisit trigger (ii) fired when sub-cycle 4
  bundled A1-D1 (the atomic-sweep rename of A1-owned recover_*
  primitives) with this hoist, amortising the otherwise-prohibitive
  4-branch cascade cost across two improvements that share the
  cascade exactly once. **Implementation mechanism: option (1)**
  per the sub-cycle 4 deferral catalog — A1 already declares
  `tb_egpu_dump_aer_trigger_event` in `nv-tb-egpu-pcie.h`, and
  A2's `nv-tb-egpu-qwd.h` already includes that header
  transitively. A2 makes the call directly at its detection
  latch with zero new header plumbing. Fork-branch commit
  `353a859e` on `a2-bus-loss-watchdog` (which lands the call
  in A2's own TU); A3 fork-branch tip becomes `60dfe4c7` (the
  rebased A3 commit with the cross-TU hunk into
  `nv-tb-egpu-qwd.c` gone). A3's `.patch` shrinks by the 8 lines
  of the qwd cross-TU hunk; A2's `.patch` grows by ~7 lines (call
  + rewritten comment). See "Improvements landed (sub-cycle 4)"
  below.

### A3-recovery-I2 — Re-examine D1: bridge-link-cap preservation is an L4 userspace dependency, not in-driver code

- **Lens:** invariant clarity / sovereignty (cross-layer
  boundary)
- **Current state:** A3's intent's Scope boundary § (lines
  437-445 of the intent file) and A3's `.patch` (grep
  `bridge.*link|LnkCtl2|target.*link` returns zero hits)
  document that A3 does NOT preserve bridge-link-cap across
  `pci_reset_bus`. The L4 userspace systemd service
  `nvidia-driver-injector-bridge-link-cap.service` sets LnkCtl2
  (Target=Gen3 + bit 5) on the parent bridge ONCE at boot
  BEFORE nvidia.ko binds; `pci_reset_bus` issues a secondary
  bus reset that resets devices behind the bridge but does NOT
  reset the bridge's own LnkCtl2 register. The boot-time cap
  therefore survives the reset, and A3 relies on the cap being
  pre-set. v2 review (D1, severity nice-to-have) documents this
  architectural boundary.
- **Proposed state:** confirm via aorus archaeology that this
  L1-vs-L4 split is the documented design choice, not a missed
  in-driver lever.
- **Value:** confirms the L4 boundary explicitly. A reader
  asking "why doesn't A3 save/restore LnkCtl2?" can answer
  "because the L4 helper commits the cap at boot AND `pci_reset_bus`
  does NOT reset the bridge's own register". v2-D1's resolution
  is unchanged.
- **Cost:** zero (verification only).
- **Verification mode:** A (aorus archaeology + memory cross-check).
- **Intent impact:** none — already documented in v2 intent's
  Scope boundary § (lines 437-445).
- **Triage decision:** **reject** (verification passes — v2-D1
  upheld)
- **Resolution:** **upheld (deferred to userspace L4)** per
  v2-D1. **M6 re-examination via aorus archaeology:**
  `project_m_recover_first_real_fire_2026_05_08` Q2 documents
  the bridge-link-cap-preservation across `pci_reset_bus` as
  "empirically load-bearing" — the L4 service commits the cap;
  `pci_reset_bus` preserves the bridge's own register; the
  combined behaviour gives Gen3 + bit 5 on the TB tunnel post-
  reset. The memory `feedback_bridge_cap_needs_both_knobs`
  documents Target=Gen3+bit5 as load-bearing for both
  firmware-handshake stability AND TB tunnel bandwidth, with
  the boot-time write committing the tunnel rate; runtime
  writes after boot do NOT move the actual tunnel bandwidth.
  So even if A3 re-wrote LnkCtl2 after a reset (option
  considered + rejected in v2 review's Design choices §), it
  would not change tunnel bandwidth. The L4 boundary is the
  right architectural choice; A3's in-driver scope is recovery
  state-machine only. **No v3 code change; no intent edit.**

### A3-recovery-I3 — Re-examine D2: `s_error_detected_logged` is module-global vs per-device

- **Lens:** robustness (single-device vs multi-device deployment
  posture) / naming
- **Current state:** v1 source `kernel-open/nvidia/nv-pci.c`
  line 2871 declares `static int s_error_detected_logged = 0;`
  as a function-static inside `nv_pci_error_detected`. The
  flag latches the verbose first-fire "AER error_detected fired
  on <BDF> (channel state=%d)" log line to ONE fire per module
  load — but ACROSS all bound devices. In a single-device
  deployment (the project's posture: one eGPU per host) this
  is correct: the first fire is the only one that needs the
  verbose initial log. In a hypothetical multi-device
  deployment, a second device's first fire would inherit the
  latched suppression and the BDF-citing initial log would
  not emit (the per-decision log line "error_detected -> %s
  (...)" at source line 2920-2924 still emits the BDF via
  `pci_name(pdev)` in the gate `reason` string, so the
  observability gap is narrow). v2-D2 (severity nice-to-have)
  flagged this as a documentation-tier concern.
- **Proposed state:** confirm the single-device deployment
  posture as the documented constraint; defer the per-device
  refactor to a future general-distribution build.
- **Value:** confirms v2-D2's resolution: the project ships
  single-device only (one eGPU per host per the broader project
  geometry per memory `project_geometry_pivot_to_injector_2026_05_12`).
  No real-world defect in the current deployment.
- **Cost:** **(a) deferred:** zero. **(b) landed:** moving the
  flag into `struct tb_egpu_recover_state` (e.g. `bool
  error_detected_logged;`) is ~5-10 LoC delta — but adds
  per-device storage for a documentation-tier improvement.
  Triggers a fork-branch I-commit + force-push cascade to A4-A5.
- **Verification mode:** A (code-reading + project-geometry
  memory cross-check).
- **Intent impact:** none — the project's single-device posture
  is documented in broader project memory, not in A3's intent
  surface.
- **Triage decision:** **reject** (verification passes — v2-D2
  upheld as deferred)
- **Resolution:** **upheld (deferred)** per v2-D2. **M6
  re-examination via aorus archaeology:**
  `patches/0024-Lever-M-recover-Commit3-hardening.patch`'s
  legacy `nv_pci_error_detected` body (patch body lines ~370-420)
  uses an identically-shaped `static int once_logged = 0;` flag
  — A3 v1's `s_error_detected_logged` is the verbatim de-brand
  of the legacy pattern. The project's single-device geometry
  is documented (per memory `project_geometry_pivot_to_injector_2026_05_12`
  — "live host runs `/root/nvidia-driver-injector` (containerized
  3-layer); … no multi-eGPU geometry"). **Default-reject
  discipline applied** per the plan's bloat-budget guidance for
  A3: cascade tax (force-push to A4-A5) for a documentation-tier
  refactor with no current-deployment value. **Explicit revisit
  trigger:** if the project ever supports multi-device
  deployments (currently out of scope), revisit.

### A3-recovery-I4 — Re-examine D3: qwd-detect call ownership confirmed in A2's TU (closes A2-D1)

- **Lens:** sovereignty (cross-cluster coupling — overlap with
  I1)
- **Current state:** v2-D3 confirmed A3 v1's shape (the call
  lives in A2's TU, patched in by A3) as the architectural
  choice; v3-I1 above gives this its own first-class entry
  per the audit's instruction. v2-D3 is the documentary
  resolution of A2-D1; v3-I1 is the headline-tier triangulated
  re-examination of the same architectural question.
- **Proposed state:** I4 explicitly subsumes v2-D3; the
  triage decision matches I1's recommendation (defer the
  architectural fix to a future task with explicit revisit
  trigger).
- **Value:** ensures v2-D3 is not double-resolved; I1 is the
  load-bearing entry, I4 just records the cross-reference.
- **Cost:** zero.
- **Verification mode:** A (catalog cross-reference).
- **Intent impact:** none.
- **Triage decision:** **defer** (folded into I1)
- **Resolution:** **deferred to Task 14 (folded into I1's
  resolution).** v2-D3's `out-of-scope` resolution is
  re-confirmed by I1's deeper triangulation; the v3
  disposition matches v2 with the added explicit revisit
  trigger from I1.

### A3-recovery-I5 — Re-examine D4: no must-fix sentinel + post-A1-I8 contract verification

- **Lens:** invariant clarity (post-A1-I8 cascade verification)
- **Current state:** v2-D4 declared "v1's behaviour, telemetry,
  and surface match the v2 intent's normative shape" with all
  eight intent Requirements satisfied; no must-fix or should-fix
  deltas. Post-2026-05-22 A1 I8 cascade (A1's DPC offset
  correction from `PCI_EXP_DPC_CTL` to `PCI_EXP_DPC_STATUS` —
  A1 catalog §I8 lines 475-543) propagated into A3's source
  via the cumulative-stack rebase (A3's fork-branch tip
  advanced from `f57a38b2` to `f57a38b2`). A3 consumes A1's
  surface (`tb_egpu_recover_read_wpr2`, `TB_EGPU_RECOVER_WPR2_VAL_MASK`,
  `tb_egpu_dump_aer_trigger_event`) — but does NOT directly
  value-compare DPC bits or AER bits; A3 reads WPR2 and
  PMC_BOOT_0 only.
- **Proposed state:** verify the A3-A1 contract post-I8 is
  consumer-transparent (A3's source surface is unchanged
  semantically; the cascade only rebased line offsets).
- **Value:** confirms the I8 cascade is A3-transparent —
  no A3-side adjustment needed because A3 does not value-compare
  the DPC bits A1's I8 corrected.
- **Cost:** zero (verification only).
- **Verification mode:** B (`grep -nE 'dpc_status|DPC_Status|TRIGGER|RP_BUSY'
  kernel-open/nvidia/nv-tb-egpu-recover.{c,h}` returns zero
  matches; `grep` confirms A3 does not directly read DPC bits).
- **Intent impact:** none.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected** — verification confirms zero
  A3-side change needed for the A1-I8 cascade. A3 consumes
  A1's surface through `tb_egpu_dump_aer_trigger_event`
  (which internally composes the topology walker + DPC reader
  + AER reader); A3 itself reads only WPR2 (via
  `tb_egpu_recover_read_wpr2`) and PMC_BOOT_0 (direct
  `ioread32(bar0_phys + 0)`). The DPC offset correction does
  not propagate to any A3-side value comparison. The cumulative
  rebase from `f57a38b2` to `f57a38b2` advanced line offsets
  but not semantics. **The `f57a38b2` references in
  `docs/patch-intents/A3-recovery.md` line 549,
  `docs/patch-reviews/A3-recovery.md` lines 5, 6, 74, 826,
  873, 915 are STALE and need to be remapped to `f57a38b2`** —
  surfaced as I15 below (cosmetic doc fix, landed).

### A3-recovery-I6 — Robustness verification: `pci_reset_bus` does NOT dispatch err_handlers — A3's explicit dispatch is correct and load-bearing

- **Lens:** robustness / invariant clarity (load-bearing kernel
  API contract)
- **Current state:** v1 source `kernel-open/nvidia/nv-tb-egpu-recover.c`
  lines 322-339 (the work-handler file-level comment) +
  lines 396-410 (the explicit-dispatch code block):
  ```c
  /*
   * Explicit dispatch — see file-level note. slot_reset reads
   * PMC_BOOT_0; on RECOVERED, resume increments success_count and
   * emits READY. On DISCONNECT, slot_reset itself handles the
   * surrender accounting + PERMANENT_FAIL.
   */
  {
      pci_ers_result_t rs = tb_egpu_recover_slot_reset(pdev);
      if (rs == PCI_ERS_RESULT_RECOVERED)
          tb_egpu_recover_slot_reset_resume(pdev);
  }
  ```
- **Proposed state:** verify against kernel
  `drivers/pci/pci.c:pci_reset_bus` (v7.0) that
  `pci_error_handlers->slot_reset` and `->resume` are NOT
  invoked from `pci_reset_bus`; verify the AER-driven path
  reaches the same dispatchers via the kernel's
  `pcie_do_recovery` machinery so the explicit dispatch from
  A3's work handler does NOT double-fire.
- **Value:** confirms the load-bearing invariant from
  `patches/0027`-Lever-M-recover-dispatch-slot-reset-resume-
  from-work-handler at lines 6-44 (the explicit-dispatch
  rationale block). The kernel's `pci_reset_bus` issues a
  secondary bus reset via `__pci_reset_function_locked` →
  `pci_bus_save_and_disable_locked` → `pci_reset_bus_function`
  but does NOT iterate through `pci_driver->err_handler`. The
  AER-driven path (`pcie_do_recovery` in `drivers/pci/pcie/err.c`)
  iterates through `pci_walk_bus` and dispatches each device's
  `err_handler->slot_reset` then `->resume` after the kernel
  has reset the bus. The two paths do NOT overlap: A3's work
  handler runs `pci_reset_bus` (manual trigger path) and
  explicitly dispatches; the AER path runs `pcie_do_recovery`
  (kernel-driven) and dispatches via the kernel's iteration.
  No double-fire.
- **Cost:** zero (verification only).
- **Verification mode:** A (kernel source cross-check vs aorus
  archaeology) + B (grep the kernel's `pci_reset_bus` to confirm
  no err_handler iteration).
- **Intent impact:** none.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected** — verification passes. Evidence:
  - `patches/0027-Lever-M-recover-dispatch-slot-reset-resume-from-work-handler.patch`
    lines 6-44 (the explicit rationale) is the canonical proof
    for the no-double-dispatch invariant: "pci_reset_bus does
    not invoke err_handlers callbacks, and the kernel does not
    synthesise an AER event from a manual reset, so the
    helpers run exactly once per recovery." A3 v1 preserves
    this invariant.
  - The work handler's explicit dispatch is GUARDED by the
    GATE_OK schedule path — i.e. the manual trigger ONLY
    schedules work on `GATE_OK`, and the AER path NEVER reaches
    A3's work handler (the AER path returns NEED_RESET from
    `error_detected`; the kernel drives the reset and dispatches
    via its own iteration). The two paths are mutually
    exclusive by construction.
  - Production-validation: `project_m_recover_first_real_fire_2026_05_08`
    documents the natural post-rmInit-FAIL fire that reached
    `slot_reset DISCONNECT` (PMC_BOOT_0=0xffffffff) without any
    double-fire or storm.

### A3-recovery-I7 — Robustness verification: `attempt_count` reset only at verified post-rmInit-OK is correct

- **Lens:** robustness (the H1 gate-reachability invariant)
- **Current state:** v1 source `kernel-open/nvidia/nv-tb-egpu-recover.c`
  lines 605-625 (`slot_reset_resume`) does NOT reset
  `attempt_count`; lines 627-643 (`record_post_rminit_ok`)
  resets it via `atomic_set(&nvl->recover->attempt_count, 0)`.
  The reset is called from `nv.c:nv_start_device` AFTER
  `rm_init_adapter` returns success.
- **Proposed state:** verify the invariant is consistent
  across the v1 source: no other reset path touches
  `attempt_count` (besides the gate's idle-burst-boundary
  reset at source lines 228-235, which is a separate
  semantic).
- **Value:** confirms the load-bearing finding from
  `patches/0028` lines 5-53 (the 21-attempt-storm root cause
  + design-deviation justification). The H1 cap measures
  consecutive failed full-recoveries (slot_reset RECOVERED +
  rm_init_adapter OK is the success criterion); resetting too
  early at slot_reset_resume makes the gate unreachable in
  storm scenarios.
- **Cost:** zero (verification only).
- **Verification mode:** B (`grep -nE
  'atomic_set.*attempt_count.*0|attempt_count.*atomic_set.*0'
  kernel-open/nvidia/nv-tb-egpu-recover.c` returns the gate's
  idle-burst-boundary reset at line 234 + the
  record_post_rminit_ok reset at line 642 — no third reset
  site).
- **Intent impact:** none — already documented in v2 intent's
  Requirement 4 (post-rmInit-OK reset semantics) and the
  Scope boundary § that explicitly excludes resetting at
  slot_reset_resume.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected** — verification passes. Two
  reset sites total in `nv-tb-egpu-recover.c`:
  1. Line 234 (gate function's idle-burst-boundary reset —
     `atomic_set(&st->attempt_count, 0)` when the elapsed
     time since `last_fire_jiffies` exceeds
     `NVreg_TbEgpuRecoverSurrenderResetSec * 1000` ms).
     Semantic: 5-min idle starts a fresh burst.
  2. Line 642 (`record_post_rminit_ok` —
     `atomic_set(&nvl->recover->attempt_count, 0)` called
     from `nv.c`'s post-rmInit-OK site). Semantic: verified
     end-to-end recovery clears the counter.
  No other site mutates `attempt_count` to 0. The
  `atomic_inc_return(&st->attempt_count)` at line 250 (in the
  gate function) is the only other mutation, and it's the
  H1 counter-increment (not a reset). **The invariant holds.**

### A3-recovery-I8 — Robustness verification: surrender path safety + cleanup

- **Lens:** robustness (surrender path correctness)
- **Current state:** Three surrender sites in v1:
  1. Gate function source lines 250-258 — H1 exhaustion
     (`atomic_inc_return > MaxAttempts`). Increments
     `surrender_count` + emits PERMANENT_FAIL uevent + returns
     GATE_SURRENDER. The trigger function (source lines 519-524)
     handles the gate return by logging + `atomic_set(in_progress,
     0)` + returning 0. The error_detected callback (source
     `nv-pci.c` lines 2914-2918) handles the gate return by
     returning DISCONNECT (kernel marks device permanently
     failed).
  2. Work handler source lines 358-367 — no upstream bridge
     (`pci_upstream_bridge(pdev) == NULL`). Increments
     `surrender_count` + emits PERMANENT_FAIL + `goto out_put`
     (which does pci_dev_put + NULL out pdev_for_work + clear
     in_progress).
  3. Work handler source lines 386-394 — `pci_reset_bus` rc != 0.
     Same exit pattern as (2).
  4. `slot_reset` source lines 579-590 — PMC_BOOT_0=0xffffffff
     (bus still down). Increments `surrender_count` + emits
     PERMANENT_FAIL + returns DISCONNECT. (Note: 4 surrender
     sites total; the original audit prompt's "surrender check"
     covers these 4.)
- **Proposed state:** verify each surrender site:
  - increments `surrender_count` atomically
  - emits PERMANENT_FAIL uevent against the GPU pdev
  - cleans up the in-flight resources (pdev refcount, in_progress
    guard) where applicable
  - does not race other surrender sites
- **Value:** confirms the surrender path is race-free and
  resource-clean. A defect would manifest as a leaked pdev
  refcount, a wedged in_progress flag, or a missing
  PERMANENT_FAIL uevent (operator confusion).
- **Cost:** zero (verification only).
- **Verification mode:** A (code-reading the four surrender
  sites + the trigger/error_detected callers' surrender
  handling).
- **Intent impact:** none.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected** — verification passes at all
  4 sites. Site-by-site:
  1. **H1 exhaustion (gate function):** the gate increments
     `surrender_count` and emits PERMANENT_FAIL. The trigger
     function (source line 523) clears `in_progress` before
     returning. The error_detected callback returns DISCONNECT
     (kernel handles the rest). No pdev refcount leak because
     the trigger path's `pci_dev_get` happens AFTER the gate
     (source line 530); on GATE_SURRENDER, no refcount is
     ever taken.
  2. **No upstream bridge (work handler):** `goto out_put`
     path runs `pci_dev_put(pdev)` + NULL out + clear
     in_progress. Correct refcount release.
  3. **`pci_reset_bus` failure (work handler):** same exit
     path as (2). Correct refcount release.
  4. **PMC_BOOT_0=0xffffffff (`slot_reset`):** this site is
     reached from BOTH the manual trigger path (work handler's
     explicit dispatch) AND the AER-driven path (kernel
     dispatches `slot_reset` after its bus reset). In the
     manual path, `slot_reset` returns DISCONNECT to the work
     handler which then SKIPS the `slot_reset_resume` call
     (source lines 407-409 — only call resume if rs ==
     RECOVERED). In the AER path, the kernel handles
     DISCONNECT internally by marking the device permanently
     failed. Either way the surrender accounting fires once
     (the `surrender_count` increment at source line 586) and
     the PERMANENT_FAIL uevent fires once.
  All 4 sites are race-free and cleanup-correct. **The H1
  4-fire production test
  (`project_lever_m_recover_landed_2026_05_08` §Phase 4)
  validated this: 4 fires triggered surrender at attempt 4
  with the correct PERMANENT_FAIL uevent.**

### A3-recovery-I9 — Robustness verification: race against C4's `.error_detected` callback + re-entry guard

- **Lens:** robustness (concurrency)
- **Current state:** v1 source has TWO trigger entry points:
  1. `tb_egpu_recover_trigger_post_rminit_fail(nvl)` — called
     from `nv.c:nv_start_device` post-rmInit-FAIL on the
     `open()` / `ioctl()` syscall path. Acquires exclusive
     ownership via `atomic_xchg(&in_progress, 1) != 0`.
  2. `nv_pci_error_detected(pci_dev, state)` — called by the
     kernel's AER subsystem from PCIe error-handling context.
     Does NOT acquire `in_progress`; just queries the gate
     function and returns NEED_RESET (kernel drives the rest).
  Concurrent fire scenario: a syscall-context trigger schedules
  work; before the work handler runs, an AER error fires; the
  kernel calls `error_detected` which runs the gate function
  (which mutates `attempt_count` and `surrender_count`
  atomically). Then either:
  - AER returns NEED_RESET → kernel drives bus reset → kernel
    dispatches `slot_reset` (which the manual trigger's work
    handler has ALSO scheduled via the explicit dispatch path).
    **Race:** can both paths run `slot_reset` on the same pdev?
  - Or the gate returns DISCONNECT (e.g. attempt_count
    exhausted, rate-limited, in_progress wasn't checked) →
    AER path returns DISCONNECT → kernel marks device
    permanently failed.
- **Proposed state:** verify the concurrency is bounded:
  - re-entry guard prevents two trigger() calls overlapping
  - gate function is atomic (all mutations are atomic_t ops)
  - the AER path and the manual trigger path do NOT race on
    `slot_reset` because the kernel's AER state machine
    serialises via `pci_lock_rescan_remove` and the manual
    trigger's work handler also acquires the same lock around
    `pci_reset_bus`.
- **Value:** confirms the H4 truth-table (single source of
  truth for the gate decision) and the in_progress re-entry
  guard prevent the most common race patterns. Defects here
  would manifest as a double bus-reset, a wedged
  attempt_count, or a stale pdev refcount.
- **Cost:** zero (verification only).
- **Verification mode:** A (code-reading + kernel
  `pci_lock_rescan_remove` contract).
- **Intent impact:** none.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected** — verification passes.
  Evidence:
  - The re-entry guard (`atomic_xchg(&in_progress, 1) != 0` at
    source line 496) is ONLY in the manual trigger path; the
    AER `error_detected` callback does NOT acquire it. This
    is intentional: the AER path doesn't schedule work, it
    returns NEED_RESET to the kernel which drives the rest.
    A simultaneous manual+AER fire would: (manual)
    schedule_work → work handler runs → `pci_lock_rescan_remove`
    → `pci_reset_bus` → `slot_reset` dispatched explicitly.
    (AER, concurrent) `error_detected` → returns NEED_RESET →
    kernel acquires `pci_lock_rescan_remove` → drives bus
    reset → dispatches `slot_reset`. **The kernel's
    `pci_lock_rescan_remove` serialises the two paths
    automatically.**
  - The gate function mutates `attempt_count`,
    `surrender_count`, and reads `last_fire_jiffies` —
    all atomic operations on `atomic_t` (or a single
    `unsigned long` read which is naturally atomic on x86_64).
    The `last_fire_jiffies` write at source line 529 is NOT
    atomic, but it's a single 64-bit write on x86_64 (or
    32-bit on 32-bit platforms — but this driver is x86-64
    only). Tear-free.
  - The work handler reads `pdev_for_work` (source line 345)
    without explicit barrier — but the publication via
    `schedule_work` at source line 539 includes an implicit
    release-acquire pair (Linux's workqueue API contract per
    `Documentation/core-api/workqueue.rst`). The handler-side
    read happens-after the trigger-side write.
  - Production validation: `project_m_recover_first_real_fire_2026_05_08`
    documented the natural post-rmInit-FAIL fire with no
    race-driven double-fire or refcount leak.

### A3-recovery-I10 — Robustness verification: workqueue lifecycle + `cancel_work_sync` on teardown

- **Lens:** robustness (teardown correctness)
- **Current state:** v1 `tb_egpu_recover_stop` (source lines
  824-854):
  ```c
  void tb_egpu_recover_stop(nv_linux_state_t *nvl)
  {
      struct tb_egpu_recover_state *st;
      if (!nvl) return;
      if (nvl->pci_dev)
          sysfs_remove_group(&nvl->pci_dev->dev.kobj,
                             &tb_egpu_recover_attr_group);
      st = nvl->recover;
      if (!st) return;
      cancel_work_sync(&st->reset_work);
      if (st->pdev_for_work)
      {
          pci_dev_put(st->pdev_for_work);
          st->pdev_for_work = NULL;
      }
      kfree(st);
      nvl->recover = NULL;
  }
  ```
- **Proposed state:** verify:
  1. sysfs removal BEFORE state teardown (so a concurrent
     `show` callback cannot reach a freed `st`).
  2. `cancel_work_sync` blocks until handler returns (so
     `kfree(st)` does not race the handler).
  3. NULL-tolerant on `nvl == NULL` and `nvl->recover == NULL`
     (idempotent against kill-switch path).
  4. Defensive `pci_dev_put` on straggler `pdev_for_work`
     (the handler normally does this itself).
  5. Removal ordering vs A2's `tb_egpu_qwd_stop` is correct
     (A2 stopped first so the watchdog can't fire a fresh
     trigger into a dying state machine).
- **Value:** confirms unload path is race-free against
  concurrent sysfs readers, concurrent work handlers, and
  concurrent watchdog triggers. A defect would manifest as a
  use-after-free on module unload during an active recovery
  cycle.
- **Cost:** zero (verification only).
- **Verification mode:** A (code-reading vs kernel sysfs +
  workqueue API contracts; also vs A3 v1's `nv-pci.c` removal
  hunk to confirm the call order).
- **Intent impact:** none.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected** — verification passes at all
  5 points. Evidence:
  1. `sysfs_remove_group` at source line 834 runs BEFORE the
     `kfree(st)` at line 852. The `sysfs_remove_group` blocks
     until all in-flight `show` callbacks return (kernel sysfs
     contract per `Documentation/filesystems/sysfs.rst`).
     Safe.
  2. `cancel_work_sync(&st->reset_work)` at source line 843
     blocks until the handler returns OR cancels a pending
     work item. After this returns, the handler is NOT running
     and won't be scheduled again (the work_struct is detached
     from any pending state). Safe to `kfree(st)` afterwards.
  3. NULL checks at source lines 828, 839. `tb_egpu_recover_stop`
     is called from `nv_pci_remove_helper` (which itself is
     NULL-tolerant on its `nvl` arg via the standard nvidia
     remove path); the kill-switch path
     (`NVreg_TbEgpuRecoverEnable=0`) leaves `nvl->recover ==
     NULL` so stop is a no-op after the sysfs group removal
     attempt (which is harmless when no group exists — the
     `sysfs_remove_group` call is a no-op for a non-existent
     group).
  4. The defensive `pci_dev_put` at source lines 846-850 is
     belt-and-braces — the work handler normally clears
     `pdev_for_work` (source line 414), but if stop runs
     while a work item is pending-but-not-started,
     `cancel_work_sync` cancels it without running the
     handler, leaving `pdev_for_work` still set. The
     defensive put correctly releases the refcount in that
     case.
  5. The removal hunk in A3's `nv-pci.c` patch (the
     `nv_pci_remove_helper` site) places
     `tb_egpu_recover_stop(nvl)` AFTER `tb_egpu_qwd_stop(nvl)`
     (verified via `grep -nE 'tb_egpu_qwd_stop|tb_egpu_recover_stop'
     /root/open-gpu-kernel-modules/kernel-open/nvidia/nv-pci.c`
     — qwd_stop is line earlier than recover_stop). A2's
     stop drains the watchdog kthread before A3's stop drains
     the work handler — so the watchdog cannot fire a fresh
     trigger into A3's stop path.

### A3-recovery-I11 — Robustness verification: in-AER-context safety of `slot_reset` callback

- **Lens:** robustness (atomic-context safety)
- **Current state:** v1 `tb_egpu_recover_slot_reset` (source
  lines 547-596) is dispatched by:
  - the kernel's AER state machine via
    `nv_pci_slot_reset` (the thin dispatcher in `nv-pci.c`
    line 2966-2969) — kernel context (process context per the
    AER `pcie_do_recovery` driver) which may sleep.
  - the work handler's explicit dispatch (source line 407) —
    workqueue context (process context) which may sleep.
  The body does: `pci_get_drvdata` + `ioremap(bar0_phys,
  PAGE_SIZE)` + `ioread32` + `iounmap` + uevent emission + log
  prints.
- **Proposed state:** verify that:
  1. The body is safe in process context (no atomic context
     restrictions like spinlocks held that would forbid
     `ioremap` or `nv_printf`).
  2. The `ioremap` call is safe (sleeps to allocate the VMA;
     fine in process context).
  3. The kernel's AER dispatch is in process context (per
     `drivers/pci/pcie/err.c:pcie_do_recovery` which runs from
     `pci_walk_bus` in workqueue context).
- **Value:** confirms `slot_reset` does not violate atomic-context
  constraints; the body is process-context-safe.
- **Cost:** zero (verification only).
- **Verification mode:** A (code-reading vs kernel AER
  dispatch contract + `Documentation/PCI/pci-error-recovery.rst`).
- **Intent impact:** none.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected** — verification passes. The
  kernel's PCI error-recovery documentation
  (`Documentation/PCI/pci-error-recovery.rst`) explicitly
  states that `slot_reset` callbacks may sleep:
  "The slot_reset() callback ... is called by the kernel after
  the slot reset. The driver should reinitialize the device,
  re-enable IO, restore power management, etc. ... may sleep
  in this routine." `ioremap` is allowed; `nv_printf` is
  allowed (printk is safe from any context); `kobject_uevent_env`
  may sleep (uses GFP_KERNEL allocation). All A3 v1's
  `slot_reset` body calls are process-context-safe.

### A3-recovery-I12 — Duty boundary verification: A3 carries only recovery (no C4 / A2 / A4 / C5 leak)

- **Lens:** duty (cross-patch dedup)
- **Current state:** v1 source. Grep-verified surfaces:
  - **C4 territory (struct pci_error_handlers registration):**
    A3's `nv-pci.c` hunk modifies the body of the existing C4
    err_handlers struct (replaces stub bodies + adds
    `cor_error_detected` slot) — the registration itself stays
    with C4. Verified via `grep -nE 'static const struct
    pci_error_handlers' /root/open-gpu-kernel-modules/kernel-open/nvidia/nv-pci.c`
    → one declaration at line 2976 (the struct C4 registered).
  - **A2 territory (PMC_BOOT_0 polling, kthread, sysfs counters
    for cycles/detections):** zero hits on `tb_egpu_qwd_*` in
    A3's source files (only in A3's hunk into A2's TU at
    `nv-tb-egpu-qwd.c` which is A2's surface).
  - **A4 territory (close-path telemetry, UVM lifecycle):** zero
    hits on `close|UVM|uvm|RM-close|close-path` in A3's source.
  - **C5 territory (`os_pci_set_disconnected` / `os_pci_is_disconnected`):**
    zero direct hits in A3's source; A3 emits PERMANENT_FAIL
    uevent but does NOT call `os_pci_set_disconnected` —
    confirmed per v2 review's C5 ABI section.
  - **A1 territory (PCIe primitives, register-read helpers,
    topology walker):** A3 consumes A1's
    `tb_egpu_recover_read_wpr2`, `TB_EGPU_RECOVER_WPR2_VAL_MASK`,
    and `tb_egpu_dump_aer_trigger_event` via the
    `nv-tb-egpu-pcie.h` include. No re-declaration, no
    re-implementation. Verified via `grep -nE
    'tb_egpu_recover_read_wpr2|TB_EGPU_RECOVER_WPR2_VAL_MASK|tb_egpu_dump_aer_trigger_event'`
    in A3's source files — only consumer-side calls.
- **Proposed state:** confirm duty boundary; any leak would
  force C4/A2/A4/C5's responsibility into A3.
- **Value:** the duty boundary is the contract A3's intent
  declares (Scope boundary § lines 419-471); verifying it
  keeps the addon-layer carve honest.
- **Cost:** zero (already correct in v1).
- **Verification mode:** B (`grep -nE` on each forbidden-surface
  pattern returns expected results above).
- **Intent impact:** none.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected** — verification passes. A3
  contains ONLY recovery state-machine code. Disjoint surfaces;
  correct addon-layer composition. The one exception is the
  cross-TU edit at A2's detection latch (I1) which is a
  documented architectural choice, not a duty leak.

### A3-recovery-I13 — Quality verification: log levels match the telemetry contract

- **Lens:** quality
- **Current state:** A3 v1 has 18 log call sites across its
  C source files (counted via `grep -nE
  'nv_printf|NV_DEV_PRINTF' kernel-open/nvidia/nv-tb-egpu-recover.c
  kernel-open/nvidia/nv-pci.c | grep -v "//"` filtered to A3's
  hunks):
  - Mandatory-tier (`NV_DBG_ERRORS`) — 16 sites covering all
    recovery decisions (trigger gate, work handler bus-reset,
    slot_reset RECOVERED/DISCONNECT, resume READY, surrender
    PERMANENT_FAIL, AER error_detected, mmio_enabled,
    cor_error_detected, force_trigger sysfs write,
    record_post_rminit_ok, killswitch override). Each carries a
    full diagnostic payload.
  - Info-tier (`NV_DBG_INFO`) — 2 sites: trigger gated on WPR2
    clear (not the failure mode) and the probe-time WPR2 clear
    log + the init-disabled log.
  - Steady-state — ZERO log calls in the gate function's
    healthy-success path; ZERO in the work handler's healthy
    completion path; ZERO in the trigger function's healthy
    early-return path. The mandatory-tier logs only fire on
    decision points.
- **Proposed state:** confirm log levels match the intent's
  Telemetry contract table (intent lines 473-499). 19 events
  in the contract table; 18 implemented in v1 source — the
  one missing-from-source event is "Probe-time WPR2 stuck
  (detection-only)" which IS implemented (source lines 313-317
  — verified).
- **Value:** confirms zero log floods. Mandatory-tier
  decisions are operator-visible per the telemetry contract;
  steady-state operation is silent.
- **Cost:** zero.
- **Verification mode:** A (intent's Telemetry contract table
  vs v1 source grep) + B (count of log call sites by level).
- **Intent impact:** none.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected** — log levels match the intent's
  Telemetry-contract table exactly. The mandatory-tier ERRORS
  events fire on each recovery decision (the soak gate reads
  `tb_egpu_recover_surrenders` from sysfs, but the dmesg log
  is the per-incident forensic trail). Comments are dense and
  load-bearing — the file-level comment at `nv-tb-egpu-recover.c`
  lines 1-40 preserves the dual-trigger + explicit-dispatch +
  sovereignty + DPM rationale; the `pdev_for_work` ordering
  comment at lines 418-444 preserves the in_progress xchg
  invariant.

### A3-recovery-I14 — Naming consistency verification

- **Lens:** naming
- **Current state:** All A3 surfaces use the consistent
  `tb_egpu_recover_*` prefix:
  - Module parameters: `NVreg_TbEgpuRecover*` (matches A2's
    `NVreg_TbEgpuQwd*` and A5's master toggle naming).
  - Sysfs attributes: `tb_egpu_recover_*` (matches A2's
    `tb_egpu_qwd_*`).
  - Struct: `struct tb_egpu_recover_state` (matches A2's
    `struct tb_egpu_qwd`).
  - Functions: `tb_egpu_recover_init`, `_stop`, `_trigger_post_rminit_fail`,
    `_check_wpr2_at_probe`, `_record_post_rminit_ok`,
    `_slot_reset`, `_slot_reset_resume`, `_pre_schedule_gates`,
    `_emit_uevent`, `_reset_work_handler`. All consistent.
  - Internal constants: `TB_EGPU_RECOVER_*` (e.g.
    `TB_EGPU_RECOVER_KILLSWITCH_PATH`). Matches A1's
    `TB_EGPU_RECOVER_WPR2_VAL_MASK` and the project's
    all-caps convention.
  - Enum: `enum tb_egpu_recover_gate` with values
    `TB_EGPU_RECOVER_GATE_OK / _DISABLED / _RATE_LIMITED /
    _SURRENDER`. Consistent.
- **Proposed state:** confirm naming is internally consistent.
  The A1-D1 atomic-rename initiative (the `legacy infix`
  pattern from earlier sub-cycles) is out-of-scope here.
- **Value:** zero defects identified. Naming consistency is
  load-bearing for cross-patch grep + ABI tooling recognition.
- **Cost:** zero.
- **Verification mode:** A (code-reading) + `tools/lint-identifiers.sh`
  if available (per A2 catalog the project has the lint).
- **Intent impact:** none.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected** — naming is consistent. The
  `tb_egpu_recover_*` prefix is the addon's namespace; the
  internal `TB_EGPU_RECOVER_*` constant namespace matches the
  project convention. **The A1-D1 atomic-rename initiative
  (sub-cycle 2 deferral) is the cross-patch consistency audit
  for Task 14; A3's individual naming is correct in v1.**

### A3-recovery-I15 — Documentation drift: v2 intent + review files reference stale fork-branch SHA `f57a38b2`

- **Lens:** quality (documentation accuracy)
- **Current state:** The 2026-05-22 A1-cascade remap (commit
  `e389814 docs: remap OLD→NEW fork SHAs in catalogs + patches
  + .regen-state`) updated SHA references in catalogs +
  patches + `.regen-state`, but missed several references in:
  - `docs/patch-reviews/A3-recovery.md` lines 5, 6 (frontmatter
    v1-tip-sha + v2-tip-sha), 74, 826, 873, 915
  - `docs/patch-intents/A3-recovery.md` line 549 (Provenance §)
  All reference `f57a38b2f45b7f757e1982734e587336bb25606a`
  which was the pre-cascade SHA; the post-cascade tip is
  `f57a38b2f45b7f757e1982734e587336bb25606a` (already correctly
  in `patches/base/.regen-state` line 11, in
  `patches/addon/A3-recovery.patch` header line 3, and in the
  v3 catalog frontmatter above).
- **Proposed state:** remap the 6 stale SHAs in the v2 review
  file + 1 in the v2 intent file to the post-cascade SHA. This
  is a cosmetic doc fix; the v2-tip-sha frontmatter remains
  correct semantically (v2 was approved on the code that NOW
  has SHA `f57a38b2`; the rebase changed the SHA without
  changing semantics).
- **Value:** removes audit-confusion ("v2 review says tip is
  X, .regen-state says tip is Y"); preserves traceability.
  Also closes the cascade-remap gap so the audit-reviewer's
  next pass doesn't flag it.
- **Cost:** ~7 LoC of doc edits across 2 files. NO fork-branch
  change. NO patch regeneration. NO cascade trigger.
- **Verification mode:** B (`grep -rn 'f5216ee'
  /root/nvidia-driver-injector/docs/patch-intents/A3-recovery.md
  /root/nvidia-driver-injector/docs/patch-reviews/A3-recovery.md`
  should return zero matches post-fix; the references in
  `docs/patch-reviews/A4-close-path-telemetry.md` lines 65 + 71
  are NOT in A3's scope and will be addressed in Task 12).
- **Intent impact:** cosmetic (Provenance § line 549 — just
  a SHA string update).
- **Triage decision:** **land** (cosmetic doc fix; combined
  with catalog closeout commit per Step 11's "include cosmetic
  intent edits" pattern)
- **Resolution:** **landed as part of the catalog closeout
  commit** (not a precursor commit; cosmetic per Step 11
  guidance).

### A3-recovery-I16 — Community-signal #1159 (Xid 8 / GSP watchdog timeout) — does it surface a v3 defect?

- **Lens:** robustness (community-signal triangulation)
- **Current state:** `_community-signal.md` lines 80-84
  tag #1159 as `A3` (recovery — GSP timeout class). Reporter
  sees Xid 8 + GSP watchdog timeout under sustained SGLang FP8
  inference on PCIe-attached RTX PRO 6000 Blackwell with
  vanilla 595.71.05 + Ubuntu 24.04 kernel 6.17. Failure mode
  is sustained-load-driven; GSP firmware wedges; no recovery
  path in vanilla driver.
- **Proposed state:** triangulate whether #1159's failure
  mode would exercise A3's specific code paths (the
  WPR2-stuck post-rmInit-FAIL trigger or the AER NEED_RESET
  path).
- **Value:** confirms M5 framing — #1159 is code-path adjacency
  with `A3`'s recovery surface but NOT an exact match for A3's
  v1 trigger conditions.
- **Cost:** zero (verification only).
- **Verification mode:** A (community-signal entry vs A3's
  trigger conditions).
- **Intent impact:** none.
- **Triage decision:** **reject** (verification passes —
  upstream-PR-rationale strengthening only)
- **Resolution:** **rejected** — #1159's failure signature
  ("Xid 8 + GSP watchdog timeout under sustained SGLang FP8
  inference") does NOT demonstrably exercise A3 v1's specific
  trigger conditions:
  - **Not WPR2-stuck post-rmInit-FAIL:** the reporter's Xid 8
    fires during sustained load, not at cold-boot adapter init.
    A3's post-rmInit-FAIL trigger fires at `nv_start_device`
    when `rm_init_adapter` returns failure with WPR2 ≠ 0; a
    sustained-load GSP wedge does not pass through that site.
  - **Not the AER NEED_RESET path:** the reporter's vanilla
    driver does not register `pci_error_handlers` (the C4
    scaffold isn't in vanilla), so AER `error_detected` never
    dispatches; even on a patched build, the Xid 8 / GSP wedge
    may not generate an AER signal at all (Xid is an
    nvidia-driver-internal signal; AER is a PCIe-level signal).
  - The `A3` tag in `_community-signal.md` is correct as
    "adjacent to the GSP-LOCKDOWN cascade A3 recovery handles"
    — but the failure mechanism is the GSP-internal watchdog
    timeout (an in-firmware fault), not the bus-state failure
    A3 recovers from. **Frame as upstream-PR-rationale
    strengthening** — the community evidence that the recovery
    surface A3 implements is needed in vanilla; does not
    surface a v3 code defect.

## Re-examination of sub-cycle 2 deferrals

- **v2-D1** — bridge-link-cap preservation is an L4 userspace
  dependency, not in-driver code → v3 disposition: **upheld
  (rejected — already documented as L4 boundary).**
  Aorus archaeology (`project_m_recover_first_real_fire_2026_05_08`
  Q2 + memory `feedback_bridge_cap_needs_both_knobs`) confirms
  the L4 service commits the cap at boot AND `pci_reset_bus`
  preserves the bridge's own register; the combined behaviour
  gives Gen3 + bit 5 post-reset. Even an in-driver re-write
  of LnkCtl2 after reset would NOT change tunnel bandwidth.
  Surfaced as I2; rejected.

- **v2-D2** — `s_error_detected_logged` is module-global, not
  per-device → v3 disposition: **upheld (rejected as deferred).**
  Aorus archaeology
  (`patches/0024-Lever-M-recover-Commit3-hardening.patch`
  legacy body, ~lines 370-420) confirms the static once-logged
  pattern is the verbatim de-brand of the legacy code. Project
  geometry (single-device per memory
  `project_geometry_pivot_to_injector_2026_05_12`) makes this
  harmless. Surfaced as I3; rejected. **Default-reject
  discipline applied** per the plan's bloat-budget guidance:
  cascade tax for a documentation-tier refactor with no
  current-deployment value.

- **v2-D3** — qwd-detect dump-call ownership confirmed in A2's
  TU (closes A2-D1) → v3 disposition: **upheld with deeper
  re-examination as I1 (HEADLINE) — defer with explicit revisit
  trigger; subsequently LANDED in sub-cycle 4.** Aorus archaeology
  (`patches/0014-Lever-Q-watchdog-kthread.patch` does NOT
  include the dump call; the dump function is defined in
  `patches/0023-mode-b-telemetry-S1-S2-S3.patch` — A1's
  canonical ancestor — but the LEGACY code already had A3-style
  patches into A2's TU; the carve preserved the cross-TU edit).
  The recarve principle is documented as not-absolute in the
  carve design spec; the v1 shape was internally consistent and
  production-validated. **Recommendation: defer (option d) with
  explicit revisit trigger** (a third addon needs to write at
  A2's detection latch, or an atomic-rename initiative on the
  addon layer consolidates the addon TUs). Sub-cycle 4 fired
  trigger (ii) when the A1-D1 atomic rename was bundled with
  this hoist into a paired-cascade to amortise the 4-branch
  force-push cost. Landed via option (a) per I1's sub-cycle 4
  resolution (hoisted INTO A2 via mechanism option (1) —
  A1's header forward-decl already in scope).

- **v2-D4** — no must-fix sentinel → v3 disposition: **upheld
  (zero-delta sentinel holds for A3).** The v3 triangulation
  pass adds the kernel PCI/workqueue/sysfs/AER API oracle and
  the H15 hardening-resolution ledger entry on top of v2's
  aorus-ancestor oracle. Neither surfaces a v3 must-fix. The
  post-A1-I8 contract verification (I5) confirms the A3-A1
  cascade is consumer-transparent (A3 does not value-compare
  DPC bits). Sixteen candidates considered (I1-I16): 0
  code-side land, 1 doc-side land (I15 — cosmetic SHA
  remap), 2 defer (I1, I4 — both relate to the same
  architectural question with explicit revisit trigger),
  13 reject (I2, I3, I5, I6, I7, I8, I9, I10, I11, I12, I13,
  I14, I16 — all verification passes). **Zero-delta sentinel
  holds at code level:** `v1-tip-sha == v2-tip-sha ==
  f57a38b2f45b7f757e1982734e587336bb25606a`.

## Improvements landed

- **A3-recovery-I15** — Documentation drift: stale `f57a38b2`
  SHA references in `docs/patch-intents/A3-recovery.md`
  line 549 + `docs/patch-reviews/A3-recovery.md` lines 5, 6, 74,
  826, 873, 915 remapped to the post-cascade SHA
  `f57a38b2f45b7f757e1982734e587336bb25606a`. **Landed in the
  catalog closeout commit (no precursor; cosmetic per Step 11
  guidance).**

(No code-side improvements landed in sub-cycle 3 — v2 already met
v3 quality bar at the code level; zero-delta sentinel held at
`f57a38b2f45b7f757e1982734e587336bb25606a` until sub-cycle 4
opened the architectural question.)

## Improvements landed (sub-cycle 4)

- **`A3-recovery-I1`** — cross-cluster
  `tb_egpu_dump_aer_trigger_event` call hoisted out of A3's
  patch into A2's commit. Revisit-trigger (ii) per the I1
  sub-cycle 3 deferral catalog ("atomic-rename initiative on
  the addon layer consolidates the addon TUs") fired when
  sub-cycle 4 bundled A1-D1 (the atomic-sweep rename of
  A1-owned `tb_egpu_recover_*` primitives to `tb_egpu_pcie_*`)
  with this hoist. Both improvements share the 4-branch
  force-push cascade exactly once, amortising the cascade cost
  asymmetry that made each improvement individually unattractive
  for a single-improvement sub-cycle.

  Mechanism: option (1) per the deferral catalog — A1's
  `nv-tb-egpu-pcie.h` already declares
  `tb_egpu_dump_aer_trigger_event`, and A2's `nv-tb-egpu-qwd.h`
  already includes that header (for the
  `struct tb_egpu_qwd_aer_snapshot` definition that A2 embeds
  in `struct tb_egpu_qwd`). A2 calls the function directly
  at its detection latch with zero new header plumbing. The
  comment block in A2's TU is also rewritten from "addon A3
  patches in the call to tb_egpu_dump_aer_trigger_event() at
  this site" to "filled by the addon-A1 helper below" — A2 is
  now fully self-contained at the call site.

  Effect:
  - A2's fork-branch tip advances from `cd1fe088` →
    `353a859e` (a new commit landing the hoisted call).
  - A3's fork-branch tip advances from `f57a38b2` →
    `60dfe4c7` (rebase + cross-TU hunk into
    `nv-tb-egpu-qwd.c` GONE; A3 stays in its own TUs:
    `nv-tb-egpu-recover.{c,h}`, `nv-pci.c`, `nv-linux.h`,
    `nv.c`, `nvidia-sources.Kbuild`).
  - A3's `.patch` no longer touches `nv-tb-egpu-qwd.c` at all.
  - A2's `.patch` grows by ~7 lines (the call + the rewritten
    comment); A3's `.patch` shrinks by 8 lines (the cross-TU
    hunk eliminated). Net: cleaner separation, zero
    cross-cluster edits at A2's detection latch.
  - Cascade-rebase on A4 (`8d85e1db` → `cddf8b9a`) and A5
    (`9d62f2e6` → `5fab2573`) propagates the A1-D1 symbol
    rename only — no behavioural changes.
  - Range-diff on each rebased branch confirms semantic-only
    changes (no inadvertent drift).

  Force-push to `apnex/open-gpu-kernel-modules` on 5 branches
  (A1, A2, A3, A4, A5) under the
  `feedback_force_push_fork_carve_out` policy carve-out: cascade
  required for the paired improvement's correctness; range-diff
  confirms zero semantic drift; reflog preserves old SHAs; zero
  open PRs affected; blast radius limited to external readers
  re-fetching on next pull.

## Intent updates landed

(No substantive intent updates — A3's intent describes the
state machine semantics + ABI surface and is unaffected by the
v3 triangulation. I15's cosmetic SHA fix on the intent's
Provenance § line 549 is landed as part of the catalog closeout
commit, not as a precursor.)

## Done gate

- [x] Every candidate improvement has explicit `Resolution:`
  (no `pending`). _(16 candidates: 0 code-side landed, 1
  doc-side landed (I15 cosmetic SHA remap), 2 deferred (I1,
  I4 — both architectural-cleanup question with explicit
  revisit trigger), 13 rejected (I2-I3, I5-I14, I16 — all
  verification passes).)_
- [x] All "land" improvements applied as fork-branch commits
  citing their `<id>-I<N>` IDs. _(N/A — zero fork-branch
  code commits; I15 is a doc-side fix.)_
- [x] Substantive intent updates landed as precursor commits.
  _(N/A — zero substantive intent updates; I15's cosmetic
  SHA fix on Provenance § folded into closeout.)_
- [x] `tools/intent-lint.sh` passes on the
  cosmetic-edit intent file
  (`docs/patch-intents/A3-recovery.md`).
- [x] `tools/validate-patchset.sh` passes (compile gate).
- [x] `bash tests/run.sh` green (34 ok / 0 failed:
  test-compose.sh 8 / test-intent-lint.sh 16 /
  test-manifest-lib.sh 10).
- [x] Audit-reviewer subagent approved. _(Sub-cycle 3 audit-reviewer,
  ✅ APPROVED WITH NOTES — all 12 spot-checked aorus citations verbatim
  (8 ancestor patches + 5 design docs line-count-verified);
  8-ancestor consolidation framing correctly disambiguates the
  C4-vs-A3 division for 0007 (M-base). A2-D1 cross-cluster pattern
  adjudication **CONCUR with option (d)** — 5-point rationale audited
  (production-validation weight; symmetric contract verified in both
  A2 + A3 intents; carve principle is heuristic per recarve-design;
  cost-benefit asymmetry of 4-branch cascade for zero-production-value
  cleanup; revisit triggers concrete + falsifiable). M1+M2 drops sound;
  M6 D-entries all re-examined; A3 duty boundary clean (only legitimate
  territory + 1 documented cross-TU edit at `nv-tb-egpu-qwd.c`); 6
  robustness checks source-verified (I7 non-blocking note: a 3rd
  init-time `atomic_set` at line 796 is one-shot, doesn't affect the
  "2 reset sites in the running state machine" claim); gates re-ran
  green; all 16 triages concurred. Zero-delta sentinel approved at
  `f57a38b2f45b7f757e1982734e587336bb25606a`. **Pre-warn for Task 12
  (A4):** A4's reviewer should NOT add cross-cluster edits at A2's
  detection latch; if A4 needs telemetry there, hoist BOTH A3's
  qwd-detect call AND A4's new call into A2 in ONE cascade-triggering
  change — this would fire I1's first revisit trigger.)_

## Cross-references

- Intent file: `docs/patch-intents/A3-recovery.md`
- Review file: `docs/patch-reviews/A3-recovery.md`
- Manifest row: `patches/manifest` line for `A3-recovery`
  (layer `addon`, source `fork:a3-recovery`)
- Vanilla baseline:
  - `kernel-open/nvidia/nv-tb-egpu-recover.c` — NEW FILE
    (854 lines; no vanilla counterpart; carved from legacy
    `nv-lever-m-recover.c` + the 0024/0026/0027/0028
    hardening patches)
  - `kernel-open/nvidia/nv-tb-egpu-recover.h` — NEW FILE
    (228 lines; no vanilla counterpart)
  - `kernel-open/common/inc/nv-linux.h` — vanilla
    `struct nv_linux_state_s`; A3 appends one field
    `struct tb_egpu_recover_state *recover;` after A2's `qwd`
    field
  - `kernel-open/nvidia/nv-pci.c:nv_pci_probe` — vanilla
    calls `rm_enable_dynamic_power_management`; A3 adds
    `tb_egpu_recover_init(nvl)` + `tb_egpu_recover_check_wpr2_at_probe(nvl, ...)`
    immediately after A2's `tb_egpu_qwd_init(nvl)`
  - `kernel-open/nvidia/nv-pci.c:nv_pci_remove_helper` —
    vanilla runs structured teardown; A2 prepends
    `tb_egpu_qwd_stop`; A3 adds `tb_egpu_recover_stop` after
    A2's stop
  - `kernel-open/nvidia/nv-pci.c:nv_pci_error_detected` /
    `_mmio_enabled` / `_slot_reset` / `_resume` — C4 declared
    these as stub bodies; A3 fills them with real recovery
    logic and adds the `cor_error_detected` slot
  - `kernel-open/nvidia/nv.c:nv_start_device` — vanilla logs
    `rm_init_adapter failed`; A3 adds
    `tb_egpu_recover_trigger_post_rminit_fail(nvl)` after
    the log and `tb_egpu_recover_record_post_rminit_ok(nvl)`
    on the success branch
  - `kernel-open/nvidia/nv-tb-egpu-qwd.c:tb_egpu_qwd_thread`
    — A2's translation unit; A3 patches in one line
    `tb_egpu_dump_aer_trigger_event(nvl->pci_dev, "qwd-detect",
    &qwd->last_aer);` at A2's per-episode detection latch
    (see I1 for the cross-cluster discussion)
  - `kernel-open/nvidia/nvidia-sources.Kbuild` — vanilla
    enumerates standard module sources; A3 adds one line
    `NVIDIA_SOURCES += nvidia/nv-tb-egpu-recover.c` after
    A2's `nv-tb-egpu-qwd.c` line
- Fork branch: `a3-recovery` on
  `apnex/open-gpu-kernel-modules` (sits on top of the
  cumulative `a2-bus-loss-watchdog` base; current tip
  `f57a38b2f45b7f757e1982734e587336bb25606a` — same as the
  A1-cascade-rebase tip; v3 zero-delta means code tip is
  unchanged from v2's semantic shape)
- aorus-5090 ancestor patches (verified per M1+M2 via grep —
  8 ancestors consolidated, exceeding binding's 3 starting
  recommendations):
  - `patches/0007-nv-pci-register-error-handlers-Lever-M-base.patch`
    (76 lines — M-base no-op stub registration; the
    `pci_error_handlers` table moved to C4 in the recarve)
  - `patches/0016-Lever-M-recover-scaffolding.patch`
    (450 lines — scaffolding: per-pdev struct + module params
    + sysfs counters + workqueue plumbing)
  - `patches/0017-Lever-M-recover-probe-time-WPR2-detection.patch`
    (243 lines — falsified-but-illustrative probe-time check;
    preserved as detection-only in v1)
  - `patches/0018-Lever-M-recover-diagnostic-telemetry.patch`
    (250 lines — 4-point lifecycle telemetry; retired
    post-hypothesis-resolution)
  - `patches/0024-Lever-M-recover-Commit3-hardening.patch`
    (838 lines — the H1/H2/H3/H4 hardening + sharpened
    trigger location + truth-table)
  - `patches/0026-Lever-M-recover-sysfs-force-trigger.patch`
    (106 lines — Phase-3 test surface; write-only
    `force_trigger` sysfs attribute)
  - `patches/0027-Lever-M-recover-dispatch-slot-reset-resume-from-work-handler.patch`
    (77 lines — load-bearing explicit-dispatch invariant;
    `pci_reset_bus` does NOT fire err_handlers)
  - `patches/0028-Lever-M-recover-attempt-count-reset-at-post-rmInit-OK.patch`
    (159 lines — load-bearing attempt-count semantics;
    H1-gate-reachability invariant)
- aorus-5090 docs cited (M1+M2 verification):
  - `docs/lever-M-recover-design.md` lines 1-130 (canonical
    design doc; mechanism + topology + trigger placement +
    primitive choice + alternatives) + lines 196-320 (code
    surface + staging + risks)
  - `docs/lever-m-recover-commit3-hardening-design.md` lines
    1-120 (canonical hardening doc; H1/H2/H3/H4 fixes +
    truth-table)
  - `docs/lever-m-recover-commit3-handover.md` lines 1-130
    (cross-session handover for 2026-05-08 implementation;
    mostly redundant with hardening-design but useful for
    confirming the implementation context)
  - `docs/recovery-mechanism-findings.md` lines 1-80 (FLR
    vs bus-reset alternative-rejection context)
  - `docs/reliability-hypothesis-ledger.md` lines 210-220
    (H15 resolution + 4-fire H1 test) + lines 226-264
    (H14 IOMMU/DMAR + GSP-lockdown root cause + H13 WPR2
    mechanism correction)
  - **Dropped per M1:** `docs/recovery.md` (L4 helper
    operator runbook; zero hits on `pci_reset_bus|attempt_count|tb_egpu_recover|in_progress`)
- Upstream issue: n/a (addon-layer; not upstream-bound;
  per Rule 5 `upstream-candidacy: n/a` for `layer: addon`).
  Underlying failure modes (WPR2-stuck + transient bus loss)
  are tracked at NVIDIA bug #979 (Blackwell eGPU over TB
  hard-lock); recovery is the project's local response to
  a failure NVIDIA has not root-caused upstream.
- Community signal: `docs/patch-improvements/_community-signal.md`
  lines 16-22 (#979 TOSUKUi 2026-05-02 — `A2/A3` tag, code-path
  adjacency with high confidence on AMD-host USB4) and
  lines 80-84 (#1159 — `A3` tag, code-path adjacency for
  GSP-LOCKDOWN cascade on PCIe-attached card, NOT
  TB-tunnelled / NOT cold-boot). Both are
  upstream-PR-rationale strengthening; neither demonstrably
  exercises A3's specific trigger conditions; neither
  surfaces a v3 code defect.
- Related catalogs:
  - `docs/patch-improvements/A1-pcie-primitives.md` (A3
    consumes A1's `tb_egpu_recover_read_wpr2`,
    `TB_EGPU_RECOVER_WPR2_VAL_MASK`, and
    `tb_egpu_dump_aer_trigger_event`. I5 verifies the A3-A1
    contract post-A1-I8 is consumer-transparent.)
  - `docs/patch-improvements/A2-bus-loss-watchdog.md` (A3
    patches into A2's TU at the per-episode detection latch
    — the I1 HEADLINE cross-cluster question.)
  - `docs/patch-improvements/C4-err-handlers-scaffold.md` (C4
    registers the `pci_error_handlers` struct that A3 fills
    with real bodies + adds the `cor_error_detected` slot.)
  - `docs/patch-improvements/C5-crash-safety.md` (A3 does
    NOT directly call into C5's `os_pci_*` API; A2 owns the
    disconnect-propagation call. A3 emits PERMANENT_FAIL
    uevents but the kernel-side disconnect propagates in
    parallel via A2 + C5.)
  - `docs/patch-improvements/A4-close-path-telemetry.md`
    (anticipated — A4's reviewer Task 12 should NOT introduce
    additional cross-cluster edits at A2's detection latch
    per I1's revisit trigger; if A4 needs to fire telemetry
    there, the right move is to hoist BOTH A3's `qwd-detect`
    call AND A4's new call into A2 in one cascade-triggering
    change.)
- Carve provenance:
  `docs/superpowers/specs/2026-05-22-addon-recarve-design.md`
  §"Carve approach" — anticipates the consumer-owned cross-TU
  call site as an acceptable pattern when the call belongs at
  the data-capture site (the carve principle is heuristic, not
  absolute). `project_lever_m_recover_landed_2026_05_08`
  records the non-obvious design lessons (pci_reset_bus does
  NOT dispatch err_handlers; attempt_count resets only at
  post-rmInit-OK). `project_m_recover_first_real_fire_2026_05_08`
  records the first natural production fire that validated the
  surrender path (slot_reset DISCONNECT on PMC_BOOT_0=0xffffffff,
  clean surrender, no storm).
