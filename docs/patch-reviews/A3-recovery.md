---
id: A3-recovery
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: f5216ee20bcc803a265a6cb99bc0b246a10b6338
v2-tip-sha: f5216ee20bcc803a265a6cb99bc0b246a10b6338
status: accepted
related-patches: [A1-pcie-primitives, A2-bus-loss-watchdog]
---

# A3-recovery — v2 review

## Rationale

A3 is the project's in-driver self-healing layer. The underlying
failure modes — transient eGPU bus loss across a Thunderbolt tunnel
and the WPR2-stuck firmware-boot class — are characterised in the
project's reliability ledger as classes the upstream NVIDIA driver
does not handle at all (the open module commits to a permanent
GPU-lost state on transient PCIe failures; see `project_aorus_egpu_setup`
and upstream bug #979). Before A3 the project relied on a userspace
recovery helper (`aorus-5090-wpr2-recovery.service`) which raced the
disconnect-propagation window and frequently lost; the in-driver
recovery is faster (~700 ms kernel work-handler turnaround) and lives
inside the kernel-side lifecycle where the disconnect is itself
declared, so the race is closed by construction. The persistent
capability A3 grants the driver is: "on the characterised transient
bus loss and the WPR2-stuck firmware-boot class the driver
self-heals — pci_reset_bus on the upstream Thunderbolt bridge, then
the explicit slot_reset / resume dispatch the kernel's `pci_reset_bus`
API does not do for us — and surrenders predictably when the failure
is beyond software reach."

The historical context (belongs here per M3 from the C1 checkpoint,
not in the intent's Purpose) is layered. Lever M-recover landed
2026-05-08 as five patches (0024 + 0025 + 0026 + 0027 + 0028);
`project_lever_m_recover_landed_2026_05_08` records the non-obvious
learnings — patch 0027 (work-handler dispatches slot_reset + resume
explicitly because `pci_reset_bus` does not), patch 0028
(attempt_count must reset only at verified post-rmInit-OK, never at
intermediate slot_reset success, or the H1 gate cycles 0→1→0 forever
in real-world storms). The first natural production fire happened
later the same day (`project_m_recover_first_real_fire_2026_05_08`);
the bus turned out to be beyond software recovery in that incident
(slot_reset read PMC_BOOT_0=0xffffffff and surrendered cleanly), but
the surrender path itself was production-validated — no storm, no
host wedge, clean fallback. The 2026-05-22 addon-recarve campaign
(`project_addon_recarve_merged_2026_05_22`) reshaped the legacy
single-file `nv-lever-m-recover.c` into A1 (primitives) plus A3
(state machine) plus C4 (err_handlers registration only, upstream-
bound), eliminating the cross-cluster coupling between sibling
addons. A3 is the recovery state machine — opinionated, project-
specific, never upstream-bound. The five hardening dimensions are
H1 (per-burst attempt cap), H2 (rate limit between attempts), H3
(master enable plus persistent kill-switch file), H4 (truth-table
gating of NEED_RESET vs DISCONNECT — folded into the gate function
itself), and the bridge-link-cap dependency (load-bearing per
`project_m_recover_first_real_fire_2026_05_08` Q2 — but provided
by an L4 userspace helper, NOT by A3 in-driver). The mechanism
docs are at `docs/patches.md` plus this review.

The persistent capability A3 grants the driver is, restated: "the
driver runs a state-machine recovery cycle on its own — without
depending on a userspace helper — when post-rmInit-FAIL coincides
with WPR2 stuck, OR when the kernel's AER subsystem dispatches
`error_detected` on the GPU pdev. Both paths funnel through one
hardening gate that bounds attempt count and rate, and through one
slot_reset / resume body that decides RECOVERED vs DISCONNECT
based on a fresh PMC_BOOT_0 read. On exhaustion the driver surrenders
predictably with a counter that the standing soak gate reads."

## v1 audit

The v1 fork branch tip (`f5216ee20bcc803a265a6cb99bc0b246a10b6338` —
"tb-egpu: self-triggered recovery state machine (A3)") sits on top
of the cumulative `a2-bus-loss-watchdog` base and adds one commit's
worth of changes: 1243 insertions / 44 deletions across 7 files
(two new files plus five additive-and-rewriting hunks into vanilla
or earlier-patch files).

**Hunk-by-hunk audit (against the immediately-prior `a2` tip
`6d5e5e7190f8030f76da63d643469645d6f9f4a2`):**

1. **`kernel-open/nvidia/nv-tb-egpu-recover.c`** — NEW FILE (854
   lines). MIT-licensed (SPDX `nvidia-driver-injector contributors`
   — the project-local attribution). File-level comment explicitly:
   (a) names the two trigger paths (post-rmInit-FAIL with WPR2-stuck;
   kernel AER `error_detected`); (b) calls out that both funnel
   through `tb_egpu_recover_pre_schedule_gates()` so the H1 / H2 /
   H3 policy stays in lockstep; (c) names the A1 dependency on
   shared primitives in `nv-tb-egpu-pcie.{c,h}`; (d) declares the
   L1 sovereignty layer (BAR0 phys address + lifecycle-bound nvl
   state); (e) declares the DPM-disabled posture that makes BAR0
   reads safe; (f) explicitly notes `pci_reset_bus` does NOT
   dispatch err_handlers and the work handler does it itself.

   The file contains:
   - Six `module_param uint` definitions (Enable=0, MaxAttempts=3,
     ResetSettleMs=500, MinAttemptIntervalMs=30000,
     SurrenderResetSec=300, TestForceTrigger=0). Each has a
     `MODULE_PARM_DESC` describing its role in the hardening table
     (e.g. "H1 cap", "H2 rate-limit"). The Enable=0 default has a
     `TODO: flip to 1 once production soak passes` comment — A3
     ships disabled in v1 because production posture is set via
     `etc/modprobe.d` rather than the in-tree default.
   - `tb_egpu_recover_read_killswitch_file()` reads
     `/var/lib/tb-egpu/recover-killswitch` via
     `kernel_read_file_from_path` with a 16-byte hard cap;
     `vfree`s the buffer; returns `0` / `1` / `-1` based on the
     first byte's content. `tb_egpu_recover_apply_killswitch_file()`
     forces `NVreg_TbEgpuRecoverEnable` to `0` if the file is
     present and begins with `'0'`. Idempotent across multiple
     devices (called once per `tb_egpu_recover_init`).
   - `tb_egpu_recover_emit_uevent(pdev, state)` builds a single
     `TB_EGPU_GPU_STATE=<state>` env entry on a stack buffer and
     calls `kobject_uevent_env(KOBJ_CHANGE)` on the pdev's kobj.
   - `tb_egpu_recover_pre_schedule_gates(st, pdev, &reason_out)`
     — the single source of truth for the H1 / H2 / Enable gate
     decision. The function:
     - Returns `GATE_DISABLED` if `st == NULL` or
       `NVreg_TbEgpuRecoverEnable == 0`.
     - Resets `attempt_count` to `0` if
       `time_after(jiffies, last_fire_jiffies +
       msecs_to_jiffies(NVreg_TbEgpuRecoverSurrenderResetSec * 1000U))`
       — the H1 idle burst-boundary BEFORE any H2 / H1 check.
     - Returns `GATE_RATE_LIMITED` if elapsed since
       `last_fire_jiffies` is `< NVreg_TbEgpuRecoverMinAttemptIntervalMs`
       (H2 rate-limit — checked second because cheaper than H1).
     - `atomic_inc_return(&st->attempt_count)` and returns
       `GATE_SURRENDER` if the post-increment value exceeds
       `NVreg_TbEgpuRecoverMaxAttempts` — also incrementing
       `surrender_count` and emitting PERMANENT_FAIL.
     - Returns `GATE_OK` otherwise.
   - `tb_egpu_recover_check_wpr2_at_probe(nvl, bar0_phys)` —
     informational only (detection-only counter). Reads WPR2 via
     A1's `tb_egpu_recover_read_wpr2`; masks with
     `TB_EGPU_RECOVER_WPR2_VAL_MASK`; if non-zero, increments
     `fire_count` and logs at NV_DBG_ERRORS; does NOT schedule
     recovery from here. The file-level comment cites
     `project_wpr2_mechanism_2026_05_06` — the boot-persistence
     hypothesis was falsified 2026-05-06; this probe-time check is
     preserved as cheap visibility.
   - `tb_egpu_recover_reset_work_handler(work)` — the workqueue
     handler. Acquires upstream bridge via `pci_upstream_bridge`;
     surrenders if no bridge (no host PCIe root → cannot drive a
     bus reset). Emits RECOVERING uevent; `pci_lock_rescan_remove` /
     `pci_reset_bus(bridge)` / `pci_unlock_rescan_remove` /
     `msleep(NVreg_TbEgpuRecoverResetSettleMs)`. On bus-reset
     failure: surrender_count++, PERMANENT_FAIL, exit. On success:
     **explicitly** call `tb_egpu_recover_slot_reset(pdev)`; if
     RECOVERED, explicitly call `tb_egpu_recover_slot_reset_resume(pdev)`.
     `pci_dev_put` on the refcount held by `pdev_for_work`; NULL
     out `pdev_for_work`; `atomic_set(&in_progress, 0)` as the
     final action so the next trigger can re-arm.
   - `tb_egpu_recover_trigger_post_rminit_fail(nvl)` — the
     post-rmInit-FAIL trigger. Reads WPR2; honours
     `NVreg_TbEgpuRecoverTestForceTrigger` to override the
     WPR2-clear branch; if WPR2 stuck (or override): atomic_xchg
     re-entry guard, gate function, on GATE_OK: pci_dev_get +
     `pdev_for_work` store + `schedule_work`. Returns 0 in all
     cases — the caller's existing failure path runs unchanged.
     File-level comment explicitly documents the pdev_for_work
     ownership ordering (refactor brief item 6) — the legacy
     "Defensive: stale pdev_for_work" branch was dead code under
     the new ordering and was removed; a `WARN_ON_ONCE` tripwire
     guards against ordering regressions.
   - `tb_egpu_recover_slot_reset(pdev)` — `pci_get_drvdata` →
     nvl → nv → bar0_phys. `ioremap(bar0_phys, PAGE_SIZE)` →
     `ioread32` PMC_BOOT_0 → `iounmap`. If `0xffffffff` (bus
     still down): surrender_count++, PERMANENT_FAIL, return
     DISCONNECT. Otherwise: return RECOVERED.
   - `tb_egpu_recover_slot_reset_resume(pdev)` — success_count++,
     emit READY uevent. The file-level comment explicitly says
     the attempt_count reset is NOT done here — it lives at
     `tb_egpu_recover_record_post_rminit_ok` because slot_reset
     RECOVERED proves only that PMC_BOOT_0 reads OK, not that GSP
     / rm_init_adapter will succeed on the next attempt (per the
     2026-05-08 storm-driven design lesson — `project_lever_m_recover_landed_2026_05_08`
     §2).
   - `tb_egpu_recover_record_post_rminit_ok(nvl)` —
     `atomic_set(&attempt_count, 0)`. If the previous value was
     non-zero, logs the reset action. Idempotent on cold boot
     (counter is already 0).
   - Five sysfs `show` / `store` functions plus the
     `attribute_group`. Four read-only counters
     (`tb_egpu_recover_fires`, `_successes`, `_surrenders`,
     `_last_fire_jiffies`) and one write-only test entry point
     (`tb_egpu_recover_force_trigger`, mode `0200`, calls back
     into `tb_egpu_recover_trigger_post_rminit_fail`).
   - `tb_egpu_recover_init(nvl)` and `tb_egpu_recover_stop(nvl)`
     lifecycle entrypoints. `init` calls the killswitch-file
     apply, short-circuits to NULL state if disabled, otherwise
     `kzalloc` / `INIT_WORK` / `atomic_set`s / sysfs group create
     (failure non-fatal). `stop` removes sysfs group first,
     `cancel_work_sync(&reset_work)` to drain pending work,
     defensively `pci_dev_put`s any straggler `pdev_for_work`
     refcount, `kfree(st)`, `nvl->recover = NULL`.

2. **`kernel-open/nvidia/nv-tb-egpu-recover.h`** — NEW FILE (228
   lines). MIT-licensed. Includes `linux/atomic.h`, `linux/pci.h`,
   `linux/types.h`, `linux/workqueue.h`. Forward-declares
   `nv_linux_state_s`, `pci_dev`. Defines
   `TB_EGPU_RECOVER_KILLSWITCH_PATH = "/var/lib/tb-egpu/recover-killswitch"`,
   `struct tb_egpu_recover_state` (eight fields: `reset_work`,
   `pdev_for_work`, `in_progress`, `fire_count`, `success_count`,
   `surrender_count`, `last_fire_jiffies`, `attempt_count`). Six
   `extern unsigned int NVreg_TbEgpuRecover*` declarations.
   Lifecycle + trigger + slot_reset + record_post_rminit_ok +
   emit_uevent + check_wpr2_at_probe prototypes. The
   `tb_egpu_recover_gate` enum (DISABLED / RATE_LIMITED / SURRENDER
   / OK) plus the `tb_egpu_recover_pre_schedule_gates` prototype.

3. **`kernel-open/common/inc/nv-linux.h`** — additive: one new
   field `struct tb_egpu_recover_state *recover;` appended to
   `struct nv_linux_state_s` immediately after A2's `qwd` field.
   Comment explicitly states forward-declared opaque pointer +
   the killswitch-file override semantics.

4. **`kernel-open/nvidia/nv-pci.c`** — substantive: replaces the
   stub `pci_error_handlers` bodies that C4 registered with real
   recovery logic. Specifically:
   - One `#include "nv-tb-egpu-recover.h"` after A2's
     qwd include.
   - Two probe-path additions in `nv_pci_probe` —
     `(void)tb_egpu_recover_init(nvl);` early (so the probe-time
     WPR2 check can use it) and
     `(void)tb_egpu_recover_check_wpr2_at_probe(nvl, nv->bars[NV_GPU_BAR_INDEX_REGS].cpu_address);`
     immediately after.
   - One remove-path addition in `nv_pci_remove_helper` —
     `tb_egpu_recover_stop(nvl);` after A2's
     `tb_egpu_qwd_stop(nvl);`.
   - Substantive rewrite of `nv_pci_error_detected` from C4's
     stub two-state switch (`io_normal → CAN_RECOVER` else
     `DISCONNECT`) to the gated NEED_RESET / DISCONNECT decision.
     The new body: static `s_error_detected_logged` first-fire
     log; `tb_egpu_dump_aer_trigger_event(pci_dev, "error-handler", NULL)`
     AER snapshot; `tb_egpu_recover_pre_schedule_gates(st, pci_dev, &reason)`
     decision; on GATE_OK: fire_count++, last_fire_jiffies++,
     RECOVERING uevent, return NEED_RESET; on any other gate:
     return DISCONNECT. Logs the decision and reason.
   - `nv_pci_mmio_enabled` rewritten to NV_DBG_ERRORS + AER
     dump + return RECOVERED.
   - New `nv_pci_cor_error_detected` callback added — pure
     observability for correctable AER errors. The comment cites
     the Gen3 demotion empirical finding from 2026-05-07
     (`project_gen3_signal_integrity_2026_05_07` — though not
     by that name).
   - `nv_pci_slot_reset` becomes a thin dispatcher into
     `tb_egpu_recover_slot_reset(pci_dev)`.
   - `nv_pci_resume` becomes a thin dispatcher into
     `tb_egpu_recover_slot_reset_resume(pci_dev)`.
   - `nv_pci_err_handlers` struct gains the
     `.cor_error_detected = nv_pci_cor_error_detected` field. The
     other four fields remain the same names; only the bodies
     they point at have changed.

5. **`kernel-open/nvidia/nv-tb-egpu-qwd.c`** — A3 patches into
   A2's translation unit: the comment at the detection latch is
   updated (from "A3 patches in the call to
   tb_egpu_dump_aer_trigger_event" to "The AER snapshot is filled
   by the addon-A1 helper below"), and ONE line is added:
   `tb_egpu_dump_aer_trigger_event(nvl->pci_dev, "qwd-detect", &qwd->last_aer);`
   immediately after `qwd->last_pmc_boot_0 = boot_0;`. This is the
   D1 deferral from A2's review now resolved.

6. **`kernel-open/nvidia/nv.c`** — additive: one `#include
   "nv-tb-egpu-recover.h"` plus two call sites in `nv_start_device`:
   `(void)tb_egpu_recover_trigger_post_rminit_fail(nvl);` BEFORE
   `rc = -EIO; goto failed_release_irq;` on the `rm_init_adapter`
   failure branch, and `tb_egpu_recover_record_post_rminit_ok(nvl);`
   AFTER the success branch (right before
   `(void)rm_get_gpu_uuid_raw`). Both call sites have explicit
   comments.

7. **`kernel-open/nvidia/nvidia-sources.Kbuild`** — additive: one
   line `NVIDIA_SOURCES += nvidia/nv-tb-egpu-recover.c` inserted
   after A2's `nv-tb-egpu-qwd.c` line. No `CONFIG_*` gate.

**Strengths.**

- **A1 ABI consumption is verbatim.** A3's source consumes
  `tb_egpu_recover_read_wpr2(bar0_phys, &raw)` (called from both
  the probe-time check and the post-rmInit-FAIL trigger),
  `TB_EGPU_RECOVER_WPR2_VAL_MASK` (used to mask raw value before
  the non-zero comparison), and
  `tb_egpu_dump_aer_trigger_event(pci_dev, "<event>", out)` (called
  with the "error-handler", "mmio-enabled", "cor-error", and
  "qwd-detect" event tags). No symbol drift, no re-declaration, no
  re-imports. A3's `nv-tb-egpu-recover.c` `#include`s
  `nv-tb-egpu-pcie.h` to get the A1 surface transitively. The
  topology walker (`tb_egpu_recover_walk_to_root_port`), DPC reader
  (`tb_egpu_recover_read_dpc_state`), and full AER reader
  (`tb_egpu_recover_read_aer_full`) from A1's surface are not
  directly called by A3 — they are reachable through
  `tb_egpu_dump_aer_trigger_event` which composes them internally
  (so A3's audit point is correct: a direct grep for those symbol
  names in A3's source returns zero hits, but A3 reaches them
  transitively).
- **The `pci_reset_bus` does NOT dispatch err_handlers — A3
  handles it.** This is the load-bearing finding from
  `project_lever_m_recover_landed_2026_05_08` §1. The work
  handler calls `tb_egpu_recover_slot_reset(pdev)` and
  `tb_egpu_recover_slot_reset_resume(pdev)` directly after a
  successful `pci_reset_bus`. The file-level comment cites the
  reasoning in the body text. Without the explicit dispatch the
  manual-trigger path would never reach the PMC_BOOT_0 verify,
  the success_count, or the READY uevent. The AER-driven path
  (kernel returns NEED_RESET → kernel drives the bus reset →
  kernel dispatches slot_reset / resume on the pdev's err_handlers)
  is unchanged; the work handler only explicit-dispatches when
  IT (the manual-trigger path) drove the bus reset, never when
  the kernel did. This separation is correct and matches the
  kernel's pci_error_handlers API.
- **attempt_count reset semantics is correct.** The reset lives at
  `tb_egpu_recover_record_post_rminit_ok` — called from
  `nv_start_device` AFTER `rm_init_adapter` returns success. Not
  at slot_reset (bus reset succeeded but GSP may still fail), not
  at resume (same reason), not at any intermediate success site.
  This matches the `project_lever_m_recover_landed_2026_05_08`
  §2 finding: resetting too early makes the H1 gate unreachable
  in real-world storms (the counter cycles 0→1→0 forever). The
  burst-boundary fallback (idle > SurrenderResetSec) is also
  correct — if a device has been quiet for 5 minutes, a fresh
  burst starts with attempt_count=0 instead of starting partway
  toward surrender.
- **Pre-schedule gate is the single source of truth.** Both
  the post-rmInit-FAIL trigger and the AER `error_detected`
  callback call `tb_egpu_recover_pre_schedule_gates(st, pdev,
  &reason)`. The two trigger paths cannot diverge — H1 / H2 /
  H3 / Enable are evaluated by one function. The reason_out
  parameter (optional) lets each caller log the gate decision
  with the same string vocabulary. The gate function's side
  effects (attempt_count inc, surrender_count inc on H1, uevent
  on surrender) are documented in the function comment so callers
  know what NOT to repeat.
- **`pdev_for_work` ownership ordering is documented and
  defended.** The function-level comment in
  `tb_egpu_recover_trigger_post_rminit_fail` enumerates the
  trigger-side steps (xchg → ownership → write pdev_for_work →
  schedule_work) and the handler-side steps (read pdev_for_work
  → run → pci_dev_put + NULL out → atomic_set(in_progress=0)).
  The "defensive: stale pdev_for_work" branch that the legacy
  code carried was correctly identified as dead code under the
  new ordering and removed; a `WARN_ON_ONCE` tripwire guards
  against ordering regressions. This is the kind of architectural
  cleanup the recarve campaign was designed to surface — the
  audit went deeper than mechanical extraction.
- **Probe-time WPR2 check is detection-only.** The
  `tb_egpu_recover_check_wpr2_at_probe` function increments
  `fire_count` for visibility but never schedules recovery from
  the probe path. The boot-persistence hypothesis was falsified
  2026-05-06 (`project_wpr2_mechanism_2026_05_06`); the production
  trigger lives in `nv_start_device` post-rmInit-FAIL where WPR2 is
  set during a failed first attempt rather than persisted across
  reboots. The probe-time check is preserved as cheap visibility
  and may fire on legitimate WPR2-stuck scenarios (e.g.
  cold-boot-from-suspend with a prior aborted GSP boot); it does
  not affect the recovery state machine.
- **`pci_reset_bus` is locked correctly.** The work handler
  acquires `pci_lock_rescan_remove()` before calling
  `pci_reset_bus(bridge)` and releases it after. This serialises
  the reset against the kernel's PCI rescan / remove paths so a
  concurrent hotplug / unbind cannot race the reset. The lock
  is correct in scope (held only around the reset, not the
  msleep or the slot_reset / resume dispatch).
- **The `cor_error_detected` callback is pure observability.**
  Adding the callback to the err_handlers struct lets the
  driver see correctable AER errors that wouldn't otherwise
  reach the driver. The comment cites the Gen3 demotion
  finding from 2026-05-07 (Br_AER_Cor=0x1 + GPU_AER_UncMsk=0x400000
  demoting an Internal Error to a correctable error reported as
  Cor=0x2000). A3 emits a log line and an AER dump for the
  correctable event; no state change, no recovery action. This
  is the correct shape for a class of errors that should be
  visible-but-not-acted-on.
- **H1/H2/H3 hardening is well-documented in the truth table.**
  The file-level comment in `nv-pci.c` includes a four-row
  truth table:
  ```
  | Enable | attempts<Max | rate-limit OK | result        |
  |   0    |      —       |       —       | DISCONNECT    |
  |   1    |     YES      |      YES      | NEED_RESET    |
  |   1    |      NO      |       —       | DISCONNECT    |
  |   1    |     YES      |       NO      | DISCONNECT    |
  ```
  This is the H4 truth table from
  `project_lever_m_recover_landed_2026_05_08` § Phase 5
  retirement: every recovery decision is one of these four
  outcomes, and the gate function maps each row to a single
  `enum tb_egpu_recover_gate` value.
- **Sysfs surface is per-pdev under the PCI device kobject.**
  Five attributes registered via `sysfs_create_group` on
  `nvl->pci_dev->dev.kobj`. The `force_trigger` write-only
  surface re-enters the trigger function as if from a real
  failure; all gates still apply (Enable=0 → no-op,
  rate-limited → deferred). This is correct for a test
  surface — it tests the production path, not a stub. Phase 3
  testing depends on it (per
  `project_lever_m_recover_landed_2026_05_08` §4).
- **Lifecycle ordering is correct.** `tb_egpu_recover_init` is
  called early in `nv_pci_probe` (so the probe-time WPR2 check
  has state available). `tb_egpu_recover_stop` is called in
  `nv_pci_remove_helper` after `tb_egpu_qwd_stop` — the
  watchdog kthread is stopped first so it cannot fire a fresh
  trigger into a dying state machine. `cancel_work_sync` blocks
  until the handler returns, so the `kfree(st)` is safe.
  Defensive `pci_dev_put` on a straggler `pdev_for_work` is a
  belt-and-braces safety net that shouldn't fire in normal
  paths (the handler clears it) but is correct if it does.

**Weaknesses.**

- **Bridge-link-cap preservation is documented as in-scope but is
  actually a userspace L4 dependency, not in-driver code.** The
  task bindings (and project memory `feedback_bridge_cap_needs_both_knobs`)
  describe A3 as "preserving bridge-link-cap across the reset",
  but `grep -n "bridge.*link\|LnkCtl2\|target.*link" patches/addon/A3-recovery.patch`
  returns zero hits. The actual mechanism: the userspace systemd
  service `nvidia-driver-injector-bridge-link-cap.service` sets
  LnkCtl2 (Target=Gen3 + bit 5) on the parent bridge ONCE at boot
  BEFORE nvidia.ko binds; that boot-time write commits the TB
  tunnel rate for the session. `pci_reset_bus` issues a secondary
  bus reset that resets devices behind the bridge but does NOT
  reset the bridge's own LnkCtl2 register, so the boot-time cap
  survives. A3 thus depends on the L4 service having run
  successfully; A3 itself does NOT save / restore the bridge
  config. This is correct architecturally (L4 is the right home
  for the cap-set; A3 is the right home for the reset), but the
  bindings phrasing risks future-reader confusion. Surfaced as
  `A3-recovery-D1` below with severity `nice-to-have` — the
  intent's Scope boundary captures this explicitly so the
  contract is clear.
- **`pdev_for_work` lifecycle has a subtle race window if the
  handler is delayed and `tb_egpu_recover_stop` runs.** Order
  on the handler side: read `pdev_for_work` → run recovery →
  `pci_dev_put` → NULL out → `atomic_set(in_progress=0)`. Order
  on stop: `sysfs_remove_group` → `cancel_work_sync` → defensive
  `pci_dev_put` if `pdev_for_work` is non-NULL → `kfree(st)`. If
  the handler is mid-flight when stop is called,
  `cancel_work_sync` blocks until the handler returns, after
  which `pdev_for_work` is NULL and the defensive put is a
  no-op. If the handler hasn't started yet (work item was
  scheduled but never ran), `cancel_work_sync` returns true
  (work cancelled), but `pdev_for_work` is still set (the trigger
  set it before `schedule_work`). The defensive put correctly
  releases the refcount in that case. So the lifecycle is correct
  but relies on the defensive put — which is documented but
  surfaced here for auditor visibility. No delta.
- **The `s_error_detected_logged` static is module-global, not
  per-device.** The flag suppresses the "AER error_detected
  fired on <BDF>" log line after the first fire on ANY device.
  In a single-device deployment (this project's posture — one
  eGPU per host) this is correct: the first fire is the only
  one that needs the verbose initial log. In a hypothetical
  multi-device deployment, a second device's first fire would
  inherit the latched-suppression and NOT log the BDF that
  fired — only the per-decision log line ("error_detected ->
  NEED_RESET (...) ") would identify the device. This is a
  documentation-tier concern; the project doesn't ship
  multi-device. Surfaced as `A3-recovery-D2` below with
  severity `nice-to-have`.
- **The default `NVreg_TbEgpuRecoverEnable=0` is correct for v1
  but is operator-surprising.** Production deployments engage
  the state machine via `etc/modprobe.d/aorus-lever-m.conf`
  (or the analogous file in the injector's `host-files`
  layout). A developer running with stock modprobe.d would have
  A3 disabled at module load and might wonder why the recovery
  counters stay at zero. The TODO comment in the source ("flip
  to 1 once production soak passes") acknowledges this. The
  default may be flipped to 1 once the v2 → production cutover
  completes (per `docs/production-migration.md`). No delta —
  the v1 default is correct and the operator surface is
  documented in production-migration.
- **The probe-time WPR2 check's success path increments
  `fire_count` but does NOT call the trigger.** This is by
  design — the boot-persistence hypothesis was falsified
  2026-05-06 — but it means `fire_count` is a slightly impure
  metric (it counts "moments A3 noticed something" not
  "moments A3 actually scheduled work"). Consumers (the soak
  gate, incident postmortems) typically read
  `tb_egpu_recover_surrenders` and the dmesg log; `fire_count`
  is mostly a visibility metric. The documentation in the
  source file's comment and in the intent's telemetry contract
  makes this explicit. No delta.

**Surprises relative to vanilla.**

- The patch is pure-additive against vanilla NVIDIA source for
  the new file inventory (`nv-tb-egpu-recover.{c,h}`) and the
  Kbuild line. The substantive rewrites are against the C4-stub
  bodies of the err_handlers callbacks in `nv-pci.c`, not against
  vanilla — vanilla's `pci_error_handlers` table was unset, so
  C4 introduced the registration with stubs and A3 fills the
  bodies. There is no vanilla semantic drift; the four
  `nv_pci_*` functions A3 rewrites were stubs the previous
  patch (C4) added.
- Vanilla `kernel-open/common/inc/nv-linux.h` defines
  `struct nv_linux_state_s` with ~70 fields; A2 already
  appended `struct tb_egpu_qwd *qwd;` and A3 appends
  `struct tb_egpu_recover_state *recover;` immediately after.
  Forward-declared opaque pointer; comment explicitly states
  full struct in `nv-tb-egpu-recover.h`.
- Vanilla `kernel-open/nvidia/nv.c:nv_start_device` already has
  the `rm_init_adapter failed` log line and the
  `failed_release_irq` goto target; A3 splices its trigger call
  immediately after the log and before the goto so the existing
  failure path runs unchanged. The post-rmInit-OK reset call
  goes immediately after the success branch, before the
  `(void)rm_get_gpu_uuid_raw(sp, nv)` call. Both spots are
  natural — the log is the canonical "post-rmInit-FAIL" marker,
  and the success branch is the canonical "post-rmInit-OK"
  marker.
- Vanilla `kernel-open/nvidia/nv-pci.c:nv_pci_driver` already
  references `nv_pci_err_handlers` (C4's hunk). A3 modifies the
  struct definition only — adds the `cor_error_detected` slot.
  The C4 stub had four slots (`.error_detected`, `.mmio_enabled`,
  `.slot_reset`, `.resume`); A3 keeps the same four names and
  adds the fifth. Compatible with C4's expectations.

## Design choices

The main alternatives considered during the v2 review:

- **In-driver recovery vs. continuing the userspace helper.**
  Pre-A3 the project ran `aorus-5090-wpr2-recovery.service` —
  a userspace systemd helper that detected the WPR2-stuck
  failure mode and wrote sysfs PCI rescan / remove from
  userspace. A3 supersedes that helper. Considered keeping
  userspace-only (simpler operationally; the kernel patch
  surface is smaller). Rejected because the userspace helper
  races the disconnect-propagation window — by the time
  systemd schedules the helper, the kernel has already
  declared GPU-lost and downstream subsystems (UVM,
  persistenced) have started teardown. A3's in-driver trigger
  fires from inside `nv_start_device`, ~700 ms before the
  failure path runs to completion; the race is closed by
  construction. The userspace helper is preserved as a
  belt-and-braces fallback during the cutover/soak window (per
  `project_lever_m_recover_landed_2026_05_08` §7) but is
  targeted for retirement once A3's production posture is
  proven. Kept v1's in-driver implementation.

- **Workqueue context vs. inline `pci_reset_bus`.** A3's
  trigger schedules a `work_struct` and the handler runs
  `pci_reset_bus` in workqueue context. Considered calling
  `pci_reset_bus` inline from the trigger to avoid the
  schedule_work latency. Rejected because the trigger is
  called from `nv_start_device` which runs in `open()` /
  `ioctl()` syscall context; `pci_reset_bus` can sleep
  (msleep settle delay), and the rest of the open() path
  expects to return promptly. The workqueue context is the
  correct home for the reset action. Kept v1's workqueue shape.

- **`pci_reset_bus` vs `pci_reset_function` vs custom FLR.**
  A3 uses `pci_reset_bus` on the upstream Thunderbolt bridge.
  Considered the alternatives. `pci_reset_function` would
  reset only the GPU itself, not the bridge — and the WPR2-
  stuck failure mode involves the bridge state (the TB tunnel
  retrains on bus reset). Custom FLR (PCI function-level reset
  via the Express capability) is per-device and would not
  bring the bridge into the reset scope. `pci_reset_bus` is
  the correct primitive — secondary bus reset on the parent
  bridge resets everything behind the bridge including the
  GPU, which is what the WPR2-stuck recovery requires. Kept
  v1's `pci_reset_bus` choice.

- **NEED_RESET vs CAN_RECOVER from `error_detected`.** v1
  returns `PCI_ERS_RESULT_NEED_RESET` on `GATE_OK` (kernel
  drives the bus reset, then dispatches our slot_reset /
  resume). Considered returning `PCI_ERS_RESULT_CAN_RECOVER`
  (kernel skips the bus reset, calls mmio_enabled, then
  resume). Rejected because CAN_RECOVER assumes the device
  itself is fine and just needs a re-enable. The eGPU failure
  modes A3 addresses are bus-state failures — the tunnel
  needs the link retrained, which requires the secondary bus
  reset. NEED_RESET is the correct return code. Kept v1's
  NEED_RESET shape.

- **Per-pdev `s_error_detected_logged` vs. module-global.**
  v1 uses a module-global `static int s_error_detected_logged`
  flag that suppresses the verbose first-fire log after the
  first fire on ANY device. Considered making it per-pdev (a
  field in `struct tb_egpu_recover_state`). The project
  ships single-device only, so the global flag is correct in
  practice. Rejected the per-pdev refactor because the cost
  (added field, more state to manage) doesn't buy anything
  for the project's actual deployment shape. If a future
  deployment ships multi-device this can be revisited.
  Surfaced as a documentation-tier observation in `A3-recovery-D2`
  with severity `nice-to-have`.

- **Persistent kill-switch via file vs. via sysfs.** v1 reads
  `/var/lib/tb-egpu/recover-killswitch` via
  `kernel_read_file_from_path`. Considered exposing a
  writable sysfs attribute instead. Rejected because the
  kill-switch needs to survive reboots (it's the "if recovery
  itself misbehaves" escape hatch) — sysfs writes don't
  persist; a file in `/var/lib` does. udev maintains the
  file. Kept v1's file-based persistence.

- **A3 ownership of A2's qwd-detect dump call (D1 from A2's
  review).** A2's v2 review left this open: A3 could either
  (a) patch the `tb_egpu_dump_aer_trigger_event(nvl->pci_dev,
  "qwd-detect", &qwd->last_aer)` line into A2's translation
  unit (matching v1 shape — sibling-addon coupling), or
  (b) hoist the call into A2 here at A3's review, leaving
  A3 to only READ `nvl->qwd->last_aer.valid`. v1 takes
  option (a) — A3's hunk modifies A2's
  `tb_egpu_qwd_thread`. Considered hoisting. **Kept v1's
  option-(a) shape.** Reasoning:
  1. A3 OWNS the recovery state machine that consumes the
     snapshot. The call belongs at the site where the
     snapshot is going to be used; A2 only persists the
     snapshot, A3 acts on it.
  2. The "sibling-addon coupling" concern from A2's review is
     real for shared helpers (where two addons need the same
     code), but the qwd-detect dump is a unidirectional
     dependency (A2's TU is the storage; A3's TU is the
     consumer that wants the data captured at A2's detection
     site). Hoisting into A2 would put the call site away
     from the consumer that uses it.
  3. The cross-TU patching shape is one hunk (3 lines added,
     4 lines of comment refactored). It's not a recurring
     pattern — A3 doesn't otherwise touch A2's source.
  4. The contract is documented in both A2's intent (Scope
     boundary: "A2 owns storage; A3 owns the call") and A3's
     intent (A2 ABI consumed: "A3 patches into A2's
     translation unit ... to add one call"). Both
     intents are explicit; future readers will not be
     surprised.
  Surfaced as `A3-recovery-D3` below with severity
  `out-of-scope` — documenting the resolution, not requesting
  a change.

- **Bridge-link-cap as in-driver vs. userspace L4.** Project
  memory `feedback_bridge_cap_needs_both_knobs` documents
  Target=Gen3+bit5 as load-bearing for both firmware-handshake
  stability AND TB tunnel bandwidth, with the boot-time write
  committing the TB tunnel rate. Considered moving the
  bridge-cap-set into A3's work handler (so the cap is
  re-applied after each pci_reset_bus). Rejected because:
  1. `pci_reset_bus` issues a secondary bus reset on the
     bridge but does NOT reset the bridge's own LnkCtl2
     register. The boot-time cap survives the reset.
  2. The TB tunnel rate is committed at the FIRST boot-time
     retrain; subsequent runtime LnkCtl2 writes can change the
     register state but do NOT move the actual tunnel
     bandwidth (per the empirical evidence in the
     `nvidia-driver-injector-bridge-link-cap` source comment).
     So even if A3 re-wrote the cap after a reset, it wouldn't
     help.
  3. The userspace L4 service is the correct home — it runs
     before nvidia.ko binds, sees the bridge BDF before any
     race, and is operationally controllable (start / stop /
     status). Putting it in A3 would conflate two concerns
     (cap-set + recovery) and complicate the L1 vs L4 split.
  Kept v1's userspace-L4 shape. Surfaced as `A3-recovery-D1`
  below with severity `nice-to-have` (documenting the
  architectural boundary so future readers don't expect
  in-driver cap preservation).

- **`os_pci_set_disconnected` integration with C5.** A3 does
  NOT directly call C5's `os_pci_set_disconnected` API. The
  disconnect propagation on dead-bus detection is owned by
  A2 (the watchdog kthread). Considered having A3 also call
  `os_pci_set_disconnected` on the DISCONNECT exit from
  slot_reset (so a hard-failure surrender propagates the
  disconnect through the same API that A2 uses). Rejected
  because:
  1. By the time slot_reset returns DISCONNECT, the kernel
     has already marked the device permanently failed via the
     err_handlers state machine — `os_pci_set_disconnected`
     would be redundant.
  2. The PERMANENT_FAIL uevent A3 emits is the userspace-
     facing surface; the kernel-side disconnect propagation
     runs in parallel via the kernel's own AER machinery.
  3. Adding a call would couple A3 to C5's API more tightly
     and increase the patch surface. The current shape is
     cleaner.
  Kept v1's no-direct-C5-calls shape.

- **`fire_count` semantics: schedule_work invocations vs.
  trigger entries.** v1 increments `fire_count` at the point
  where `schedule_work` is about to be called (in
  `tb_egpu_recover_trigger_post_rminit_fail` after gate
  passes) AND at the AER `error_detected` GATE_OK exit AND in
  the probe-time WPR2 check (detection-only). The probe-time
  increment is the slightly impure one — it counts "moments
  A3 noticed something" not "moments A3 actually scheduled
  work". Considered making `fire_count` strictly the
  schedule_work counter and adding a separate
  `probe_wpr2_detections` counter. Rejected because the
  probe-time increment fires at most once per probe (very
  rare in practice — the boot-persistence hypothesis was
  falsified) and adding a counter for a single rare event is
  overkill. `fire_count` is documented as "schedule_work
  invocations + probe-time WPR2 detections" with the
  probe-time detection cited explicitly in its log line. Kept
  v1's combined semantics.

## v1 → v2 deltas

### A3-recovery-D1 — Bridge-link-cap preservation is an L4 userspace dependency, not in-driver code

- **Location:** Architectural — A3's relationship to the userspace
  systemd service `nvidia-driver-injector-bridge-link-cap.service`
  and the `usr/local/sbin/nvidia-driver-injector-bridge-link-cap`
  binary.
- **Change:** No code change — documentation in the intent's Scope
  boundary now explicitly captures that A3 does NOT save / restore
  the bridge LnkCtl2 register across `pci_reset_bus`. The L4
  userspace service sets the cap ONCE at boot before nvidia.ko
  binds; `pci_reset_bus` issues a secondary bus reset that does
  not reset the bridge's own register, so the boot-time cap
  survives.
- **Severity:** nice-to-have
- **Evidence:** `grep -n "bridge.*link\|LnkCtl2\|target.*link" patches/addon/A3-recovery.patch`
  returns zero hits — A3 has no bridge-cap preservation code. The
  `nvidia-driver-injector-bridge-link-cap` script's source comment
  documents the boot-time-once mechanism and the empirical evidence
  that runtime writes don't move tunnel bandwidth. Project memory
  `feedback_bridge_cap_needs_both_knobs` is correct that
  Gen3+bit5 is load-bearing; the memory does not say A3 implements
  it. Task binding phrasing "(b) bridge-link-cap preservation" is a
  binding-document drift. The intent's Scope boundary captures the
  L4 boundary explicitly.
- **Resolution:** documented in intent — no code change. The
  bindings phrasing for downstream tasks (especially Task 14) should
  be updated to make the L1 vs L4 split clearer.

### A3-recovery-D2 — `s_error_detected_logged` is module-global, not per-device

- **Location:** `kernel-open/nvidia/nv-pci.c:nv_pci_error_detected`
  — the `static int s_error_detected_logged = 0;` declaration.
- **Change:** Could move the latch into
  `struct tb_egpu_recover_state` as a per-device flag
  (`bool error_detected_logged;`) so each device's first-fire log
  emits independently.
- **Severity:** nice-to-have
- **Evidence:** The project ships single-device only (one eGPU per
  host — per the broader project geometry). In a hypothetical
  multi-device deployment, the second device's first fire would
  inherit the latched-suppression and would not emit the verbose
  BDF-citing log line. The per-decision log line ("error_detected ->
  NEED_RESET (...) ") still identifies the device, so the
  observability gap is narrow. The project doesn't currently care
  about multi-device, but a future general-distribution build might.
- **Resolution:** deferred to a follow-on cleanup or to Task 14's
  cross-patch consistency audit. Single-device deployment makes
  this harmless in v1.

### A3-recovery-D3 — A2-qwd-detect dump-call ownership: confirmed in A2's translation unit (resolves A2-D1)

- **Location:** `kernel-open/nvidia/nv-tb-egpu-qwd.c:tb_egpu_qwd_thread`
  — A3's hunk patches one line into A2's per-episode detection
  latch: `tb_egpu_dump_aer_trigger_event(nvl->pci_dev, "qwd-detect", &qwd->last_aer);`.
- **Change:** None — confirming v1's shape. A2's review (D1)
  deferred the decision to A3's review: A3 could either (a) patch
  the call into A2's translation unit (v1 shape — sibling-addon
  cross-patching), or (b) hoist the call into A2 here and have A3
  read the populated `last_aer` only. A3 chooses option (a) and
  documents the reasoning.
- **Severity:** out-of-scope
- **Evidence:** Three reasons keep v1's shape:
  1. A3 owns the recovery state machine that consumes the AER
     snapshot. The call belongs at the site where the snapshot
     will be used; A2 only persists the storage.
  2. The cross-TU patching is a unidirectional dependency (A2's
     TU stores, A3's TU calls). It's not a recurring shared-helper
     pattern — A3 doesn't otherwise touch A2's source.
  3. The contract is documented symmetrically: A2's intent's
     Scope boundary says "A2 owns storage; A3 owns the call",
     and A3's intent's A2-ABI section says "A3 patches into A2's
     translation unit ... to add one call". Both intents are
     explicit; future readers will not be surprised.
  The 2026-05-22 addon-recarve design spec
  (`docs/superpowers/specs/2026-05-22-addon-recarve-design.md`)
  §"Carve approach" anticipated this exact split: shared
  PRIMITIVES (A1) are extracted to eliminate cross-cluster
  coupling, but consumer-owned CALLS at specific sites in a
  sibling's TU are an acceptable pattern.
- **Resolution:** accepted. A2-bus-loss-watchdog-D1 is now
  closed by v1 shape (the call lives in A2's TU, patched in by
  A3). The contract is documented in both intents.

### A3-recovery-D4 — No must-fix or should-fix deltas

- **Location:** n/a
- **Change:** v1's behaviour, telemetry, and surface match the v2
  intent's normative shape. The intent's eight Requirements are
  satisfied: the post-rmInit-FAIL trigger is wired correctly
  (WPR2 read, re-entry guard, gate function, schedule_work); the
  AER `error_detected` callback returns NEED_RESET / DISCONNECT
  via the same gate; the work handler runs `pci_reset_bus` with
  the rescan-remove lock and dispatches slot_reset / resume
  explicitly; the gate function is the single source of truth
  with H1 / H2 / H3 / Enable evaluated in the documented order;
  attempt_count resets only at verified post-rmInit-OK; the
  sysfs surface has four read-only counters plus the
  force_trigger write-only test entry point; the master enable
  and the persistent kill-switch file are honoured at every
  relevant entry point; and the remove path drains the work
  handler and frees state cleanly. A1's ABI consumption is
  verbatim (`tb_egpu_recover_read_wpr2`,
  `TB_EGPU_RECOVER_WPR2_VAL_MASK`,
  `tb_egpu_dump_aer_trigger_event` with four event tags).
  C4's err_handlers struct is filled with real bodies (and one
  new slot `cor_error_detected`). C5's `os_pci_*` surface is
  NOT touched (correct per the architectural split — A2 owns
  the disconnect-propagation call). No fork-branch follow-up
  commits are required.
- **Severity:** out-of-scope
- **Evidence:** Every scenario in the eight Requirements maps to
  a v1 code path. The Scope boundary's nine non-goals are each
  satisfiable by inspection of the v1 file: no PMC_BOOT_0
  polling (→ A2); no primitive expose (→ A1); no close-path
  instrumentation (→ A4); no err_handlers struct registration
  (→ C4); no bridge-link-cap preservation (→ L4 userspace); no
  BAR1 preservation (out-of-scope per recarve); no
  `os_pci_set_disconnected` direct call (→ A2 + C5); no
  `CONFIG_NV_TB_EGPU` gate (→ A5); no userspace recovery
  helper (superseded by A3).
- **Resolution:** rejected — no v2 follow-up needed.

Per M2 (zero-delta sentinel from the C1 checkpoint), the frontmatter
`v1-tip-sha == v2-tip-sha == f5216ee20bcc803a265a6cb99bc0b246a10b6338`
is the machine-checkable signal that v1 already met v2 intent. The
four deltas (D1 nice-to-have architectural boundary, D2
nice-to-have single-vs-multi-device, D3 out-of-scope confirming
A2-D1 resolution, D4 explicit no-must-fix) are recorded for
provenance and to give the next downstream task reviewers (A4 / A5)
the contract they should code against:

- A3's recovery counters (`tb_egpu_recover_fires`,
  `tb_egpu_recover_successes`, `tb_egpu_recover_surrenders`,
  `tb_egpu_recover_last_fire_jiffies`) are stable PCI-device
  sysfs surfaces. The standing soak gate reads `tb_egpu_recover_surrenders`
  — a non-zero value in a soak window blocks promotion.
- A3's uevents (`TB_EGPU_GPU_STATE=READY|RECOVERING|PERMANENT_FAIL`)
  are stable userspace surfaces. udev rules and container restart
  hooks subscribe to them.
- A3's interaction with A2 is unidirectional: A3 patches the
  `tb_egpu_dump_aer_trigger_event(nvl->pci_dev, "qwd-detect",
  &qwd->last_aer)` line into A2's detection latch. A2 owns the
  storage; A3 owns the call. The contract is documented in both
  intents.
- A3's interaction with C4 is "fill the stubs": A3 replaces C4's
  stub `error_detected` / `mmio_enabled` / `slot_reset` / `resume`
  bodies with real recovery logic and adds the
  `.cor_error_detected` slot to the struct.
- A3's interaction with C5 is none-direct: A3 emits uevents
  (`PERMANENT_FAIL` on surrender), but does NOT call
  `os_pci_set_disconnected`. A2 owns the disconnect-propagation
  call via C5's API.
- A3's interaction with the L4 userspace bridge-link-cap service
  is documentary: A3 expects the cap to be pre-set by the userspace
  systemd service before nvidia.ko binds; A3 does not save /
  restore the cap across `pci_reset_bus`.
- A3's relationship to [[A4-close-path-telemetry]] is not yet
  defined — A4 doesn't exist yet. Anticipated contract: A4's
  close-path observability fires from RM close-path callbacks
  (independent of A3's recovery dispatch). A4 may consume
  `tb_egpu_dump_aer_trigger_event` from A1 (matching A3's
  pattern at the `"error-handler"`/`"mmio-enabled"`/`"cor-error"`
  call sites) and may register additional sysfs counters under
  the per-pdev kobj. A4's review (Task 12) will pin down the
  contract.

## Done gate

- [x] `docs/patch-intents/A3-recovery.md` exists, lints clean, `status: reviewed`.
- [x] All must-fix deltas applied as fork-branch commits citing their delta IDs. _(N/A — zero must-fix deltas; D1 nice-to-have documented, D2 nice-to-have deferred, D3 out-of-scope confirming A2-D1, D4 explicitly closes "no must-fix".)_
- [x] `patches/addon/A3-recovery.patch` refreshed by `regen`. _(N/A — no fork-branch change; existing file already reflects `f5216ee2`.)_
- [x] `tools/validate-patchset.sh` passes (compile gate).
- [x] `bash tests/run.sh` green.
- [ ] Audit-reviewer subagent approved. _(Pending — this review file is the audit-reviewer's input.)_

## Cross-references

- Intent file: `docs/patch-intents/A3-recovery.md`
- Manifest row: `patches/manifest` line for `A3-recovery`
  (layer `addon`, source `fork:a3-recovery`)
- Vanilla baseline:
  - `kernel-open/common/inc/nv-linux.h` — vanilla 595.71.05
    `struct nv_linux_state_s`; A3 appends one field
    `struct tb_egpu_recover_state *recover;` after A2's qwd
    field.
  - `kernel-open/nvidia/nv-pci.c:nv_pci_probe` — vanilla calls
    `rm_enable_dynamic_power_management`; A3 adds
    `tb_egpu_recover_init` and `tb_egpu_recover_check_wpr2_at_probe`
    calls.
  - `kernel-open/nvidia/nv-pci.c:nv_pci_remove_helper` — vanilla
    runs structured teardown; A2 prepends `tb_egpu_qwd_stop`; A3
    adds `tb_egpu_recover_stop` after A2's stop.
  - `kernel-open/nvidia/nv-pci.c:nv_pci_error_detected` and
    siblings — C4 introduced stub bodies for the err_handlers
    callbacks; A3 rewrites the bodies with real recovery logic
    and adds the `cor_error_detected` slot.
  - `kernel-open/nvidia/nv.c:nv_start_device` — vanilla logs
    `rm_init_adapter failed`; A3 adds
    `tb_egpu_recover_trigger_post_rminit_fail(nvl)` immediately
    after the log and `tb_egpu_recover_record_post_rminit_ok(nvl)`
    on the success branch.
  - `kernel-open/nvidia/nvidia-sources.Kbuild` — vanilla
    enumerates the standard module sources; A3 adds one line
    `NVIDIA_SOURCES += nvidia/nv-tb-egpu-recover.c` after A2's
    `nv-tb-egpu-qwd.c` line.
  - `kernel-open/nvidia/nv-tb-egpu-recover.c` — NEW FILE
    (no vanilla counterpart; carved from legacy
    `nv-lever-m-recover.c` plus the 0024/0026/0027/0028
    hardening commits).
  - `kernel-open/nvidia/nv-tb-egpu-recover.h` — NEW FILE
    (no vanilla counterpart).
- Fork branch: `a3-recovery` on
  `apnex/open-gpu-kernel-modules` tip `f5216ee2`.
- Upstream issue: n/a (addon-layer; not upstream-bound; per
  Rule 5 `upstream-candidacy: n/a` for `layer: addon`). The
  underlying failure mode is tracked at NVIDIA bug #979 (Blackwell
  eGPU over TB hard-lock); recovery is the project's local
  response to a failure NVIDIA has not root-caused upstream.
- Related reviews: [[A1-pcie-primitives]] (foundation that A3
  consumes via `tb_egpu_recover_read_wpr2`,
  `TB_EGPU_RECOVER_WPR2_VAL_MASK`, and four
  `tb_egpu_dump_aer_trigger_event` call sites — see "A1 ABI
  consumed" in the intent's Provenance).
  [[A2-bus-loss-watchdog]] (the detection half whose state
  machine A3 reads via the patched qwd-detect dump call; A3
  patches into A2's TU to add the call at A2's detection latch).
  [[A4-close-path-telemetry]] (anticipated — A4 doesn't exist yet;
  A3's relationship is described in body prose above).
  [[C4-err-handlers-scaffold]] (the registration that A3 fills
  with real bodies; C4 is upstream-bound and A3 is addon —
  upstream NVIDIA can merge C4 without buying into A3).
  [[C5-crash-safety]] (the disconnect-propagation surface that
  A2 calls into; A3 does not call C5 directly — see "C5 ABI
  consumed" in the intent's Provenance).
- Carve provenance:
  `docs/superpowers/specs/2026-05-22-addon-recarve-design.md`
  — §"Carve approach" describes A3's split from legacy
  `nv-lever-m-recover.c` plus the 2026-05-08 hardening
  commits (0024 / 0026 / 0027 / 0028).
  `project_lever_m_recover_landed_2026_05_08` — the
  non-obvious design lessons from the original implementation
  (pci_reset_bus does NOT dispatch err_handlers; attempt_count
  must reset only at post-rmInit-OK).
  `project_m_recover_first_real_fire_2026_05_08` — the first
  natural production fire that validated the surrender path
  (slot_reset DISCONNECT on PMC_BOOT_0=0xffffffff, clean
  surrender, no storm).
