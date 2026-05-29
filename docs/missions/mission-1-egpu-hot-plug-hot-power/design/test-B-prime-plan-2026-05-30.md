# Test B-prime — persistence-engaged rmmod variant (executable plan, safety-reviewed)

**Status:** READY — gated on (a) aorus.20 deployed + A8 v2 sysfs verified, (b) clean substrate, (c) explicit go.
**Date authored:** 2026-05-30 (design workflow + adversarial safety review)
**Safety score:** 6/10 — **proceed-with-mitigations** (NOT proceed-as-planned). Real Variant-C host-wedge risk; recovery = reboot.
**n:** 1 (single reboot-gated run on a never-before-tested doubly-stressed substrate; frame ALL outcomes as provisional per the n≥3 reliability methodology).

## The sharpened question

Test B (2026-05-29) found rmmod fast-passed in 100 ms with ZERO A7 events — but the mechanism was `nv_pci_remove_helper` skipping `nv_shutdown_adapter` entirely (NV_FLAG_INITIALIZED cleared by the prior LAST-CLOSE `nv_stop_device` teardown, because persistence was off). So Test B never actually reached A7's wrap on the rmmod path.

**Test B-prime question:** With persistence engaged (NV_FLAG_INITIALIZED stays set across LAST-CLOSE), the Phase 3 rmmod *does* call `nv_shutdown_adapter` and reaches A7's wrap — on a chip whose C5 sink was *already set* by a prior A6 open-path fire (Phase 2 cycle-2). Does `rm_disable_adapter` / `rm_shutdown_adapter` then **fast-fail on the pre-existing sink** (A7 logs "completed within budget" for both — the patch intent's original prediction), **OR** does `rm_shutdown_adapter` **still time out structurally at 200 ms** like Test A (proving the hang is sink-independent)?

**Delta from Test B:** insert one step — `nvidia-smi -pm 1` — into Phase 1 after `modprobe` and before cycle 1. Everything else identical.

## Expected outcomes (all host-safe except C)

| Variant | Mechanism | Journal signature | Survival |
|---|---|---|---|
| **A** — RM fast-fails on pre-set sink (intent prediction confirmed) | RM observes GPU-already-lost at a sink-aware gate, returns without the chip-touching MMIO | `rm_disable_adapter completed within budget` + `rm_shutdown_adapter completed within budget` — TWO "completed", NO "timed out" | safe |
| **B** — structural hang, sink-independent (intent prediction refuted) | sink does not gate the specific MMIO inside rm_shutdown_adapter; A7 times out exactly as Test A | `rm_disable_adapter completed within budget` + `rm_shutdown_adapter timed out after 200 ms` | safe |
| **C** — chained wedge escapes A7 (low-prob, must-name) | doubly-stressed substrate; CPU deadlocks before A7's bounded worker timeout is observed (the AER-vs-deadlock race that wedged 11/12 open-path attempts historically) | journal SILENT after `rm_shutdown_adapter scheduled to bounded worker`; rmmod in D-state; `timeout 20` returns 124 | **at-risk → reboot** |

Both A and B answer the question and preserve host survival. C is the abort/reboot case. A7's worker-hop is *designed* to defeat C by moving the blocking MMIO off the syscall thread, but has **never been validated on this A6-pre-fired + persistence doubly-stressed substrate** — hence n=0 prior evidence and the 6/10 score.

## A8 v2 bonus observability

Run on aorus.20 (A8 v2), the `tb_egpu_f40b_fires` counter now works AND covers both paths. Each F40b fire (A6 open in step 8, A7 shutdown in step 9) increments it — so we get a machine-readable cross-check against the journal greps. This is strictly safer observation than Test B had (journalctl-grep only). Read `/sys/bus/pci/devices/0000:04:00.0/tb_egpu_f40b_fires` and `tb_egpu_state` passively at each checkpoint.

## Procedure (mitigations baked in)

**Phase -1 — clean-substrate gate (MANDATORY; the safety reviewer verified the live host was dirty).**
Verify persistence is OFF and zero prior F40b shutdown-path fires this boot, OR reboot first. The DaemonSet auto-engages persistence on boot, so "reboot" alone is insufficient — either deploy aorus.20 fresh and capture the baseline before any workload, or uninstall→clean. Treat a pre-existing "persistence already Enabled" at step 6 as a soft-abort signal, not success.

**Phase 0 — passive pre-flight.** `T0=$(date '+%F %T')`; BAR1 via sysfs FIRST (position-independent ≥32 GiB check, NOT `sed -n 2p`), then `/proc/modules`, `NVreg_TbEgpuShutdownTimeoutMs`, uptime. NO nvidia-smi until BAR1 confirmed 32 GiB.

**Phase 1 — F40-precondition substrate:**
1. `kubectl exec <pod> -- /entrypoint.sh uninstall` (fires A7 once on healthy unload; host-safe per Test A n=2).
2. `echo 0 > .../0-1/authorized; sleep 2; echo 1 > .../0-1/authorized; sleep 4` (TB cycle → broken BAR1).
3. `setpci -s 04:00.0 COMMAND=0:3; tools/fix-bar1.sh; echo > .../driver_override` (restore BAR1 → 32 GiB).
4. `timeout 30 modprobe --ignore-install nvidia` (load patched .ko; **timeout-wrapped** — if 124 or 99.6%-CPU R-state spin, forensic-capture-then-reboot, do NOT SIGKILL-and-nurse).
5. **DELTA:** `nvidia-smi -pm 1` (engage persistence; safe — BAR1 confirmed 32 GiB at step 3).

**Phase 2:**
6. `nvidia-smi -L` (cycle 1, clean). **Go/no-go checkpoint:** confirm NO close-path A7 fire in journal — its absence proves persistence engaged. If A7 fires here, persistence did NOT take → soft-abort.
7. `exec 3</dev/nvidia0; echo rc=$?; exec 3<&-` (cycle 2 → A6 fires, sets C5 sink). **Go/no-go checkpoint:** confirm the `open timed out — declaring GPU lost` line IS present before Phase 3. If A6 completed-within-budget (no sink set), the run tests a different sub-case — note it but the structural-vs-sink question degrades.

**Phase 3 — the measurement:**
8. **Arm out-of-band recovery BEFORE this step:** `echo 1 > /proc/sys/kernel/sysrq`; start an fsync'd `journalctl -kf` tee to `/var/log/mission-1-archaeology/test-B-prime-2026-05-30/`; pre-position a reboot in an already-forked shell; arm the kernel hung-task detector if available.
9. `T3=$(date '+%F %T'); timeout 20 rmmod nvidia; echo rc=$?` (THE test — reaches A7's wrap with sink pre-set).
10. `journalctl -k --since "$T3" | grep -E 'tb_egpu \[F40b\]:|Unregistered Nvlink'` (classify variant). Also read `tb_egpu_f40b_fires` from sysfs (A8 v2 cross-check — must show ≥2: A6 step 7 + A7 step 9).

**Phase 4 — recovery:**
11. Passive confirm: modules clean, BAR1 32 GiB, host alive. **DEFER the pod respawn by default** — the science is done after step 10; prefer leaving modules cleanly unloaded and rebooting to restore the injector rather than re-exposing the host to the unresolved Test-B Phase-4 modprobe-spin. If respawn IS attempted, gate on host-healthy + forensics-preserved, and pre-accept that a spin = immediate reboot.

## Abort criteria (any → stop)

- Journal goes SILENT after `rm_shutdown_adapter scheduled to bounded worker` (or `open scheduled`) with no matching `completed`/`timed out` within ~5 s → Variant-C deadlock → reboot.
- `timeout 20 rmmod nvidia` returns 124, OR rmmod observed in uninterruptible D-state → wedged on blocked MMIO → reboot.
- Modprobe spin recurs (99.6% CPU, R-state, SIGKILL-immune, no return in ~30 s) → forensic-capture-if-responsive → reboot.
- Persistence did not engage: step 5 nvidia-smi -pm 1 returns non-zero, OR an A7 close-path fire appears during step 6's LAST-CLOSE → soft-abort (question unanswerable) → reboot before retry.
- Any passive BAR1 read reports ≠ 32 GiB where 32 GiB expected AND a subsequent step would issue an RPC tool → do NOT run the RPC tool → reboot.
- systemd/k3s timers or unrelated subsystems stop emitting in journalctl (scheduler-wide wedge) → immediate reboot.

## Recovery path

**Any wedge → host reboot.** There is NO in-driver recovery for these wedge classes yet (A9 draft-only). Chip substrate stays structurally fine (BAR1 32 GiB through the wedge); only kernel/userspace wedges, so a clean reboot restores the pre-injector baseline and the DaemonSet re-binds on next boot. Before rebooting IF partially responsive: preserve `journalctl -k --since $T0` + `/var/log/fix-bar1-*` to `/var/log/mission-1-archaeology/test-B-prime-2026-05-30/`. Do NOT run the userspace rmmod→TB→fix-bar1→modprobe loop to un-wedge a deadlocked kernel (that loop is for clean F40-recovery between healthy runs; Test B showed SIGKILL on a spun modprobe fails). Do NOT run nvidia-smi to "check on" a suspected-wedged chip — passive reads only, then reboot.

## Estimated wall-clock

~270 s for the happy path (each phase 30-60 s + respawn wait), plus reboot (~90 s) if deferred-respawn path is taken or any abort fires.

## Cross-refs

- A7 Test A validation (n=2): `A7-test-A-validation-2026-05-29.md`
- A7 Test B validation (n=1): `A7-test-B-validation-2026-05-29.md`
- F40 catalog (two-arm): `/root/fake-5090/failure-modes/F40-rmshutdownadapter-incomplete-init-wedge.md`
- A7 intent v1.1: `../../../patch-intents/A7-f40b-bounded-wait-shutdown.md`
- Safety memories: `feedback_no_rpc_observability_on_broken_bar1`, `feedback_freeze_risk_methodology`, `feedback_surprise_removal_wedge_class_2026_05_26`
