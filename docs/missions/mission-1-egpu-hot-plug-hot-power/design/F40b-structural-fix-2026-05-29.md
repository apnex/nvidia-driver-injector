# F40b — structural fix for the chip re-init wedge class

**Date:** 2026-05-29 evening (revised)
**Status:** Design phase — initial design REPLACED below per Test #1 (2026-05-29 evening) findings
**Scope:** NVIDIA driver fork (this project) — independent of E27 (Linux kernel)
**Cross-refs:** `fake-5090/failure-modes/F40-reinit-gsp-lockdown-wedge.md` (§Mechanism, revised 2026-05-29 evening); `docs/missions/.../experiments/h1-userspace-recovery-2026-05-28.md`

## What changed (2026-05-29 evening)

Test #1 (2x `nvidia-smi -L` cycle on userspace-recovered chip, forensics at `/var/log/mission-1-archaeology/c1-test1-wedge-2026-05-29/`) produced a clean, fast, controllable reproduction of F40. The data falsifies the original F40b wrap-site recommendation:

- **Cycle 1 close-path completed cleanly.** A4 logged `post-shutdown` with `WPR2 → 0`; `close-exit` fired; the host stayed responsive.
- **Cycle 2 (`nvidia-smi -L` 2 seconds later) wedged the host immediately.** No further kernel journal output after the cycle-2 start kmsg marker.

The F40 wedge mechanism is **chip re-init hanging on the OPEN path after a clean LAST-CLOSE**, not destructive teardown hanging on the CLOSE path. The original F40b design's bounded-wait wrapper around `nv_shutdown_adapter` would not help — shutdown completes fine.

The revised F40b design (below) wraps the right code site and adds a probe-time poison flag as the cheapest correct fix.

The original F40b design (the §"Three-layer architecture" section further down) is preserved verbatim for historical traceability but is **superseded by §"Revised architecture (2026-05-29 evening)" below**.

## Purpose

Close the F40 failure class structurally in our nvidia.ko fork. F40 is "the chip re-init wedges the host on a chip in a state the driver doesn't fully model" — currently observed when the chip is in the userspace-recovered state from `fix-bar1.sh`, but the failure class is broader than that single trigger.

Goal: tear down the device correctly (free resources, clean kernel-side state) WITHOUT freezing the host if the chip won't cooperate.

This fix is **independent of E27**. E27 (Linux kernel patch for F41) prevents the userspace-recovered chip state in the TB-hot-add case; F40b makes the driver resilient to any analogous chip state from any cause. Either fix alone resolves the user-visible failure; together they're defense in depth.

## Revised architecture (2026-05-29 evening)

> **Framing correction (2026-05-29 late evening):** the tiers below are STOPGAPS, not the structural close. Per the project's user-directive on 2026-05-29 morning ("the actual failure class should be structurally closed in the nvidia driver via carefully thought out error handling EVEN WITHOUT E27"), the perfect answer requires identifying the actual hanging function and wrapping IT — not avoiding the state machine the function lives in. After five wedge reproductions on 2026-05-29 we have ruled out `RmInitAdapter`, `pci_pm_runtime_resume`, and the `0x110094` sentinel as the gate; the wedge fires somewhere in the open syscall path BEFORE `nv_open_device` is reached and we have not yet instrumented that span. PINPOINT-3 (markers inside `nvidia_open`'s file_operations callback, before the queue-to-`nv_open_q` step) is the queued next characterization step. The bounded-wait + sink-state structural fix can only be designed once PINPOINT-3 identifies the site.
>
> Until then, Tier 0 (below) is the shippable in-driver stopgap. It matches what production already does in userspace via `nvidia-smi -pm 1`. It is debt-shaped per `feedback_native_in_driver_hardening` (in-driver, but a dodge) and explicitly does NOT close the failure class on the rmmod / driver-unbind path — yesterday's PINPOINT-2 Run 2 "restore-attempt" wedge on the rmmod+modprobe cycle is not addressed by Tier 0.

Three patch tiers, in increasing order of complexity. Tier 0 is the cheap in-driver stopgap; Tier 1 + Tier 2 are speculative architectures pending PINPOINT-3.

### Tier 0 (NEW, recommended as stopgap) — probe-time persistence force-engage for E1 GPUs

**Status: stopgap. Ships immediately. Does NOT close the failure class structurally.**

At probe time, if `os_pci_is_thunderbolt_attached` returns true (the E1 detection), set `NV_FLAG_PERSISTENT_SW_STATE` on the device automatically. From then on, `usage_count` doesn't matter for the chip-state lifecycle — the chip stays initialized until module unload.

Mechanism: persistence keeps `usage_count > 0`, so LAST-CLOSE never fires `nv_shutdown_adapter`, so the chip never enters the post-shutdown "MMIO-responsive, GSP-off" state, so the cycle-2 trigger never has a precondition to wedge on. The actual wedging code is never reached.

This is identical in effect to what the injector entrypoint already does via `nvidia-smi -pm 1` shortly after probe. Moving it into the driver eliminates the small userspace-engagement window AND removes one of the injector's userspace dependencies (per the native-in-driver hardening direction).

**What Tier 0 does NOT do:**
- It does not fix the `rmmod` / driver-unbind path. `rmmod nvidia` fires `nv_pci_remove_helper → nv_shutdown_adapter` regardless of persistence flag. The next `modprobe`'s first open then re-inits from a userspace-recovered chip — same wedge precondition. PINPOINT-2 Run 2 yesterday confirmed this case wedges.
- It does not identify or close the underlying init-on-divergent-chip-hangs mechanism. The wedge condition still exists; we just stay out of its state space until module unload.

Implementation cost: a few lines in `nv_pci_probe`. Validation: existing production runs that engage persistence are the regression-witness — Tier 0 reaches the same end state via a different mechanism.

### Tier 1 — probe-time poison flag (speculative, downgraded)

**Signature confidence: PARTIALLY FALSIFIED 2026-05-29 evening (Test #1 FULLPRE + Differential test).** Two wedge runs (n=2 of 5) showed the `0x110094 == 0xbadf2100` sentinel absent. The Differential test (power/control=on) also ruled out runtime-PM resume as the wedge site. Tier 1 retained below for traceability and as a possible secondary signal; not the primary fix path.

(Original Tier 1 writeup, preserved for traceability:) Earlier same day this section claimed "HIGH (n=4 sentinel-present-with-wedge + n=1 sentinel-absent-without-wedge)" and "empirically necessary AND sufficient." Two wedges later we have n=2 sentinel-absent-WITH-wedge. The "necessary" claim is false. The signal correlates (n=3 of 5 wedges where probe-time emission was actually observed) but does not gate. As a single-register canary, it would miss the un-sentineled wedges entirely. Forensics: `/var/log/mission-1-archaeology/c1-test1-fullpre-wedge-2026-05-29/FORENSICS-REPORT.md` and `/var/log/mission-1-archaeology/diff-test-wedge-2026-05-29/FORENSICS-REPORT.md`.

Additionally, the **wedge-site assumption** built into Tier 2's wrap recommendation is partially falsified: bpftrace captured cycle 1 cleanly (5 ENTER / 5 RETURN: `nv_open_device`, `nv_stop_device`, `nv_shutdown_adapter`) but captured **zero** cycle 2 events. The wedge fires BEFORE `nv_open_device` is reached. Wrapping `RmInitAdapter` (which `nv_open_device` would call) does not help if the wedge fires earlier in the syscall path.

**New leading site: PCI runtime-PM resume.** The 58-sec gap between cycle 1 and cycle 2 in Test #1 FULLPRE was long enough for runtime auto-suspend to fire (Linux default = 5 s idle). Cycle 2's `open()` would trigger `pci_pm_runtime_resume` BEFORE any nvidia.ko callback runs. On the userspace-recovered chip, the D3→D0 PCIe link retrain / GSP restore is the candidate hang site. This is testable with one differential experiment: re-run the precondition sequence with `power/control=on` on the GPU + audio function before cycle 1.

Tier 1's design path forward (pending the differential test result):

- **If runtime-PM resume IS the wedge site:** the cheapest fix is `pm_runtime_forbid(&pdev->dev)` at probe time for E1-classified GPUs. This pins the device in D0; no auto-suspend, no resume cycle, no D3→D0 chip-touching at next open. Production persistence engagement achieves similar effect through a different mechanism (usage_count > 0 keeps things active); `pm_runtime_forbid` is direct and applies even when the driver is bound but no userspace process is keeping it open. Trade-off: ~30 W idle vs ~few W D3. Acceptable for an eGPU on a desktop NUC where chip idle dominates.
- **If runtime-PM resume is NOT the wedge site:** the wrap must move even earlier — to `nvidia_open` entry, or to a pre-callback hook. This is much more invasive and we'd need more characterization (full kernel-side bpftrace covering pci_pm/runtime_pm/device_release_driver_internal + a wedge cycle that captures the actual orphan ENTER).

The original Tier 1 (read `0x110094`, set flag, refuse re-init) is preserved below but is now ONE input among possibly several, not the primary gate. It may still be useful in combination with PM behavior changes.

(Below, retained from the original Tier 1 design.)

At probe time, detect the userspace-recovered chip-state divergent signature: any read of `0x110094` returning the sentinel `0xbadf2100` is sufficient (this is the same sentinel `gpuHandleSanityCheckRegReadError_GH100` already warns on — we just elevate it to a poison decision). If detected:

1. Set a per-device flag `NV_FLAG_FRAGILE_CHIP_REINIT`.
2. Bind to the device and allow the first OPEN → MMIO → CLOSE cycle (A4 telemetry has confirmed the first cycle is safe on n=4 reproductions).
3. On the NEXT `nv_open_device` after a `LAST-CLOSE` with `NV_FLAG_FRAGILE_CHIP_REINIT` set, return `-EIO` instead of running first-fd-init / `RmInitAdapter`. Log a single line explaining what's happening so userspace knows to issue a PCI re-enum (or engage persistence) before retrying.

This dodges the wedge by **refusing to enter the hanging operation**. No bounded-wait worker required, no PCIe link manipulation, no sink-state escalation. The chip is preserved in its "MMIO-responsive, GSP-off" state and remains recoverable via either reboot or PCI re-enum.

Variant A (stricter): set the flag on probe and never re-init at all on flagged devices. Production safety wins; one MMIO probe per probe is the entire chip touch budget.

Variant B (production-permissive): set the flag on probe and re-init at most once before refusing. To be validated by characterization — currently we do NOT have data that the n-th re-init survives on a userspace-recovered chip.

Recommend Variant A by default; revisit if production breaks.

### Tier 2 — bounded-wait wrap around re-init (PROMOTED to primary structural fix, 2026-05-29 evening)

**Status promotion (2026-05-29 evening):** based on Test B v2 + VERIFY + TBv2-n2 data (see F40 catalog §"Mechanism pinned, but AER+C5 path is NOT reliable"), Tier 2 is the structural fix. The race is non-deterministic — Test B v2 caught the failure via AER+C5; VERIFY and TBv2-n2 (the n=2 repro of Test B v2 with identical setup) both wedged. The AER+C5 path is observed n=1 of 3 attempts. Tier 1's sentinel-based detection is brittle (n=2 sentinel-absent-with-wedge); Tier 0 (probe-time persistence) is a workaround not a fix. Tier 2 deterministically engineers the AER+sink-state behavior that Test B v2 achieved through lucky timing — but does so without depending on AER firing reliably.

**Mechanism (as proven by Test B v2 + VERIFY)**:

The F40 wedge is a PCIe Completion Timeout AER race:
- chip-touching MMIO in `RmInitAdapter` on a userspace-recovered chip
- chip does not produce a completion → PCIe Completion Timeout (50 ms default) fires
- AER signals a Non-Fatal Uncorrectable Error (UESta=0x00004000 = Completion Timeout bit)
- C5's `pci_error_handlers.error_detected` callback IS registered and CAN handle it cleanly (returns -EIO via sink-state)
- BUT: without enough scheduling slack, the kernel deadlocks before AER handler runs, host wedges

Test B v2 (with bpftrace running) showed the FULL CLEAN-FAIL path: AER fires, C5 catches, `nvidia_open` returns -EIO, bash gets EIO. VERIFY (no bpftrace) showed the deadlock path. The difference was timing-only.

**The fix engineers Test B v2's outcome deterministically:**

1. **Bounded-wait wrapper** around `nv_open_device_for_nvlfp` — schedule the chip-touching init call on a kthread/workqueue. Main thread (the open syscall) waits with a configurable timeout. Target timeout > 50 ms (longer than PCIe CTO so AER has time to fire naturally).
2. **On timeout**:
   - `pci_dev_set_disconnected(pdev)` — mark the device as kernel-disconnected; future MMIO from the wedged worker will fail-fast
   - Fire `cleanupGpuLostStateAtomic(pGpu, DETECTOR_REINIT_TIMEOUT)` — C5 sink-set
   - Return -EIO from the open syscall
3. **The wedged worker (if any)** will eventually exit because its in-flight MMIO will fail-fast once `pci_dev_disconnected` is set. The thread is leaked (no `cancel_work_sync` because that would itself block on the wedged worker); leak is bounded per cycle, recovered at next reboot.

**Empirical support for this Tier 2 design**: Test B v2 demonstrated the END-STATE we want (AER fires, C5 catches it, returns -EIO cleanly), proving the C5 sink machinery is correct. But TBv2-n2 demonstrated that the AER path is NOT reliably taken — same setup, race went the wrong way, wedge fired. The bounded-wait wrapper forces the same END-STATE deterministically by setting `pci_dev_disconnected` + sink-state on timeout regardless of whether AER fires naturally.

### IMPLEMENTED + VALIDATED 2026-05-29 evening (n=2)

The A6 patch (`patches/addon/A6-f40b-bounded-wait-open.patch`, committed at injector-repo c8d3c68) implements this Tier 2 design as `nv_open_device_for_nvlfp_bounded()`:

- Heap-allocated, refcounted work struct (`struct nv_f40b_open_work`) for safe concurrent lifetime management
- Scheduled on `system_long_wq`
- `wait_for_completion_timeout(&w->done, msecs_to_jiffies(NVreg_TbEgpuOpenTimeoutMs))`
- On timeout: `rm_cleanup_gpu_lost_state(sp, nv, NV_GPU_LOST_DETECTOR_AER_FATAL)` + return -EIO; worker is leaked
- Gated by `NVreg_TbEgpuOpenTimeoutMs > 0` AND `nv->is_external_gpu`; non-eGPU and disabled paths bypass the wrapper

F40B-TEST validation (both runs same boot, IDENTICAL F40 precondition: deploy + persistence + nvbandwidth + uninstall + TB recycle + fix-bar1 + modprobe with A6-built nv.ko):

| Run | Cycle 1 (nvidia-smi -L) | Cycle 2 (bash exec 3</dev/nvidia0) | Total wait | Host alive? |
|---|---|---|---|---|
| 19:48 | rc=0, close-path clean | rc=1, EIO, `Input/output error` | 201.7 ms | ✓ |
| 19:50 | rc=0, close-path clean | rc=1, EIO, `Input/output error` | 203.5 ms | ✓ |

Kernel markers in both runs:
```
[F40b]: open scheduled to bounded worker (timeout=200 ms)
[F40b]: open completed within budget rc=0          ← cycle 1 opens (foreground, fast)
[F40b]: open scheduled to bounded worker (timeout=200 ms)
[F40b]: open timed out after 200 ms — declaring GPU lost (detector_class=3 DETECTOR_AER_FATAL); worker leaked, will exit when MMIO fails-fast post-sink-set
tb_egpu recover: trigger gated (sink-set: GPU already declared lost (C5 sink)); emitting PERMANENT_FAIL
```

**The F40 wedge class is now structurally closed at n=2 validation.**

**Implementation locus**: `nv_open_device_for_nvlfp` at `kernel-open/nvidia/nv.c:~1794`. Wrap its body in the bounded-wait pattern. The C5 sink-state machinery is already correct; only the wrap site changes.

**Timeout value**: 200 ms is a safe default (4× the 50 ms CTO). Can be a module parameter for tuning.

**Risk note on PCIe link-disable fallback**: TB-tunneled bridges may not honor `PCI_EXP_LNKCTL_LD` identically to standard PCIe bridges (per `feedback_lspci_lnkcap_tb_virtual`). The Tier 2 design above does NOT require LNKCTL_LD — `pci_dev_set_disconnected` is the simpler and correct mechanism. The earlier draft's LNKCTL_LD fallback can be removed.

**Original Tier 2 draft (preserved for reference):**

If the divergent-state signature proves unreliable as a poison-flag trigger (e.g., signature varies across chip generations or false-positives on healthy chips), fall back to:

1. **Bounded-wait wrapper** around `nv_open_device`'s first-fd-init branch — specifically the call into `RmInitAdapter`. Schedule the init call on a worker thread; main thread (the open syscall) waits with a configurable timeout. If the worker hangs in MMIO, the open syscall returns `-EIO`.
2. **PCIe link-disable fallback on timeout** — once the worker is presumed wedged, write the `PCI_EXP_LNKCTL_LD` bit on the parent bridge to force-disable the link. Subsequent MMIO from the wedged worker fails fast (CRS abort or `0xFFFFFFFF` reads). The worker can then exit cleanly.
3. **C5 sink-state escalation with new detector class.** Fire `cleanupGpuLostStateAtomic(pGpu, DETECTOR_REINIT_TIMEOUT)`. C5's existing sink-state propagation handles the rest.

The bounded-wait timeout is empirically derivable from a "healthy re-init" baseline measurement on a cold-plug chip. Target: `2 × max(healthy_RmInitAdapter_time)`.

Risk: TB-tunneled bridges may not honor `PCI_EXP_LNKCTL_LD` identically to standard PCIe bridges (per `feedback_lspci_lnkcap_tb_virtual`). We need to validate the primitive separately before relying on it here.

### What stays the same as the original F40b design

- **C5 sink-state model** is unchanged — it's the right escalation primitive. Only the detector name changes (`DETECTOR_REINIT_TIMEOUT` not `DETECTOR_TEARDOWN_TIMEOUT`).
- **F40a (probe-time persistence engagement) is still useful** but for a different reason: with persistence engaged, `usage_count` never returns to 0, `LAST-CLOSE` never fires `nv_shutdown_adapter`, the chip never enters the post-shutdown state, the re-init path is never reached. F40a is now framed as "stay out of the wedge state machine entirely" not "detect-and-prevent."
- **Decoupling from E27 still holds.** E27 prevents F41 → no userspace-recovered chip state → no F40 trigger. F40b makes the driver resilient if F41 fires anyway (or if a similar chip-state divergence comes from another cause).

### Phased implementation plan (revised)

| Phase | Work | Validation gate |
|---|---|---|
| **F40b.1 (rev)** | Add `NV_FLAG_FRAGILE_CHIP_REINIT` flag + probe-time poison detector reading `0x110094` for the sentinel. Wire to `nv_open_device`'s first-fd-init branch: if flag set + post-LAST-CLOSE re-init imminent, return `-EIO`. | On userspace-recovered chip: cycle 1 succeeds, cycle 2 returns `-EIO` cleanly (no wedge). On cold-plug chip: both cycles succeed (flag not set). |
| **F40b.2 (rev)** | Implement `nv_force_pcie_link_disable(struct pci_dev *)` + standalone validation on TB-tunneled bridge (same as original F40b.1; required for Tier 2). | MMIO fails fast within bounded time on the TB-tunneled GPU bridge. |
| **F40b.3 (rev)** | Tier 2 — implement bounded-wait wrapper around `RmInitAdapter` call site. Wire to flag-OR-fallback policy. | On userspace-recovered chip with simulated Tier 1 false-negative: timeout fires, link-disable executes, open returns `-EIO`, host alive. |
| **F40b.4 (rev)** | Add `DETECTOR_REINIT_TIMEOUT` to C5's detector enum. Audit `gpuStateDestroy` and friends for sink-state awareness on the re-init failure path. | No `NV_ASSERT_FAILED` during lost-mode handling on flagged devices. |
| **F40b.5 (rev)** | Patch series finalization, commit, docs update, fake-5090 substrate update (open-2-wedges-not-close-1 model). | PR-grade artifact. |

Estimated effort: 1–2 days for Tier 1 alone (poison flag + open-path gate). 3–4 days for both tiers.

### Coverage matrix (revised)

| Failure path | Currently | After F40b Tier 1 | After F40b Tier 2 | After E27 | After all |
|---|---|---|---|---|---|
| Re-open after LAST-CLOSE on userspace-recovered chip (the F40 case) | wedge | open returns `-EIO` (clean) | wrapped + link-disable on hang | precondition absent | safe |
| rmmod / driver-unbind path on userspace-recovered chip | wedge (via the rebind/re-init half of the cycle) | rebind returns `-EIO` on the open after rmmod+modprobe | wrapped re-init | precondition absent | safe |
| PCIe surprise removal (cable yank) | C5 covers | unchanged | unchanged | unchanged | unchanged |
| Chip-state divergence from non-F41 cause (hypothetical) | wedge | safe IF divergent signature still surfaces at probe; else degenerate to wedge | safe (bounded-wait catches regardless of detection) | NOT covered (E27 only fixes F41) | safe |

Tier 1 alone covers the documented failure class. Tier 2 covers hypothetical variants where the probe-time signature differs.

### Open design questions (revised)

1. **Is `0x110094 == 0xbadf2100` the right poison signature?** ANSWERED partial-positive on this hardware (n=5 as of Test #1 REDO, 2026-05-29 evening) — signature present in every wedge, absent in the one no-wedge case. Still open: stability across chip generations (only GH100/RTX 5090 Blackwell tested), false-positive on any other chip family, behavior under partial recovery (e.g., if `0x110094` reads `0xbadf2100` on probe but then changes on subsequent MMIO).
2. **Tier 1 Variant A vs Variant B** — refuse all re-init, or allow at most one. Requires data we don't have. Conservative default: Variant A. Revisit if production breaks.
3. **Should F40a (probe-time persistence engagement) be folded into the same patch series, or stay separate?** Both fix the same field bug from different angles. Recommendation: separate patches, same series, ordered F40a → F40b Tier 1 → F40b Tier 2.

### Status next-steps (revised)

1. Verify the `0x110094` sentinel does not false-positive on a healthy cold-plug chip (cheap, no wedge cost — read the register on the live host). One transition.
2. Implement Tier 1 prototype as a small patch.
3. Test on userspace-recovered chip (the F40 trigger). Validate `-EIO` return on cycle 2 with no wedge.
4. Run cycle-3 to confirm Tier 1 doesn't break the recovery path.
5. If Tier 1 holds on n≥3 reproductions, ship it. Tier 2 only if Tier 1 proves brittle in field.

---

# Historical original design (superseded — kept for traceability)

The text below is the design as of 2026-05-29 morning, BEFORE the Test #1 reproduction (2026-05-29 evening) showed the wedge is in re-init not in teardown. It is preserved verbatim so the reasoning path is reviewable.

## Principle

Tear down what needs tearing down. Make every chip-touching step cancellable or skippable when the chip stops cooperating. This mirrors Windows-driver behavior where the OS gives drivers bounded teardown contracts and a PCIe-link-level fallback for misbehaving chips.

What we do NOT do:
- "Just dodge to `rm_disable_adapter` on the rmmod path." This skips resource cleanup that's required for correctness (DMA unmap, BAR iounmap, gpumgr detach, `gpuStateDestroy`). It would leak kernel resources and corrupt GPU-manager state.

What we DO do:
- Run the destructive teardown. Wrap chip-touching steps in bounded waits.
- On timeout, escalate: force-detach the device via PCIe link disable, mark the GPU lost via C5's sink primitive, then complete kernel-side resource cleanup in lost-mode.

## Three-layer architecture

### Layer 1 — bounded-wait wrapper for destructive teardown

Schedule chip-touching teardown calls on a worker thread; main thread waits with a configurable timeout. If the worker is hung in MMIO that won't complete, the main thread proceeds to escalation (Layer 2) rather than freezing the entire host.

The wedged worker is leaked. This is intentional: `cancel_work_sync()` would itself hang if the worker is stuck in MMIO. The leak is bounded per teardown timeout (one worker structure plus its in-flight MMIO context). Recovered at next system reboot.

### Layer 2 — PCIe link-disable fallback

Write the `PCI_EXP_LNKCTL_LD` bit on the parent bridge's Link Control register. After this, MMIO to the device fails fast (CRS abort or `0xFFFFFFFF` reads) instead of hanging.

This is what the Linux kernel itself does in PCIe surprise-removal handling. The mechanism is well-defined and the kernel's `pci_dev_set_disconnected()` records the disconnection for downstream code to consult.

Risk: TB-tunneled bridges may not honor the link-disable bit identically to standard PCIe bridges. The TB controller virtualizes some PCIe registers (per `feedback_lspci_lnkcap_tb_virtual`). We need to test that this primitive actually causes MMIO to fail-fast on our hardware before relying on it in the F40b path. See F40b.1 in the implementation phases below.

### Layer 3 — C5 sink-state escalation + lost-mode cleanup

On timeout, fire C5's `cleanupGpuLostStateAtomic(pGpu, DETECTOR_TEARDOWN_TIMEOUT)` with a new detector class. This sets the dual-marker sink state (RM-side flag + Linux `pci_dev_is_disconnected`). C5's existing sink-state awareness in `gpuStateDestroy → engstateDestroy → ...` short-circuits chip-touching code in lost-mode.

After the sink is set, we continue calling the kernel-side resource cleanup functions:
- `RmTeardownDeviceDma(nv)` — pci_unmap_* equivalents; kernel-side bookkeeping, no chip touch
- `RmTeardownRegisters(nv)` — iounmap of BAR mappings; kernel VA space
- `gpumgrDetachGpu` + `gpumgrDestroyDevice` — GPU manager registry; RM-side
- `RmClearPrivateState(nv)` — nv_state cleanup

These are safe to run with sink-state set; they don't touch the chip.

`gpuStateDestroy(pGpu)` is also called — C5's existing sink-state awareness should short-circuit the chip-touching parts. We need to audit specifically what `gpuStateDestroy → engstateDestroy → ...` calls and confirm all chip-touching sub-sites consult sink. See F40b.4 in the implementation phases below.

## Where the wrapper goes

The bounded-wait wrapper applies to the destructive teardown invoked from `nv_pci_remove_helper` (the rmmod / driver-unbind path). The close-path (`nv_stop_device` on LAST-CLOSE) is already covered by the persistence-engagement policy via `NV_FLAG_PERSISTENT_SW_STATE` — the close-path branch in `nv_stop_device` routes through `rm_disable_adapter` which is the existing safe path. We do NOT need to add F40b's bounded wait to the close-path.

A separate (much smaller) close-path probe-time policy patch — F40a — ensures `NV_FLAG_PERSISTENT_SW_STATE` is force-set for E1-detected external GPUs that have a divergent chip state at probe time. F40a uses the existing persistence policy as the mechanism; F40b uses the new bounded-wait + link-disable as the mechanism. They're orthogonal patches; F40a is a few lines, F40b is hundreds.

This document covers F40b only. F40a may be folded into the same patch series at implementation time.

## Phased implementation plan

| Phase | Work | Validation gate |
|---|---|---|
| **F40b.1** | Implement `nv_force_pcie_link_disable(struct pci_dev *)` + standalone test (small kernel module that triggers it on our hardware; verify MMIO fails fast within bounded time). Verify the TB-tunneled bridge actually honors the link-disable bit. | Confirmed MMIO failure-fast behavior on TB-tunneled bridge. |
| **F40b.2** | Implement `nv_run_teardown_with_timeout(nv, nvl, sp, site, op, timeout_ms)`. Test on cold-plug chip (positive control) — wrapped call must complete cleanly without timeout firing. | Normal teardown unaffected; markers fire as expected. |
| **F40b.3** | Wire into `nv_pci_remove_helper` behind `NV_FLAG_EXTERNAL_TEARDOWN_PROTECTION`. Test on userspace-recovered chip (the F40 scenario) — timeout fires, link-disable executes, kernel-side cleanup completes, host stays alive. | rmmod completes; host doesn't freeze; bpftrace confirms expected primitive invocations. |
| **F40b.4** | Audit `gpuStateDestroy` call chain for sink-state awareness on the F40b path. Add `NV_ASSERT_OR_GPU_LOST` to any newly-discovered call sites that observe `NV_ERR_GPU_IS_LOST`. | No `NV_ASSERT_FAILED` during lost-mode cleanup. |
| **F40b.5** | Add `DETECTOR_TEARDOWN_TIMEOUT` to C5's detector enum. Document; write commit message; draft as a project patch (likely new C-level entry in patch geometry — covers a core failure class). | PR-grade artifact ready for review. |

Total estimated effort: 1–2 focused engineering days.

## Coverage matrix

| Failure path | Currently | After F40b | After E27 | After both |
|---|---|---|---|---|
| Close-path (`nv_stop_device → nv_shutdown_adapter`) without persistence | Wedge | Detector fires at probe → flag set → close-path takes persistent branch → safe | Precondition absent → safe | safe |
| rmmod / driver-unbind path (`nv_pci_remove_helper → nv_shutdown_adapter`) | Wedge | Wrapped + link-disable fallback → safe | Precondition absent → safe | safe |
| PCIe surprise removal (cable yank) | Existing C5 handles it | Same | Same | Same |
| Chip-state divergence from non-F41 cause (future) | Wedge | Detector still fires (Phy16Sta read at probe) → safe | NOT covered — E27 only fixes F41 | safe |

The fourth row is the architectural value of F40b. E27 doesn't cover failures we haven't seen yet but whose mechanism is analogous. F40b covers them by construction.

## Open design questions (resolved before/during implementation)

1. **Timeout value for the bounded-wait wrapper** — TBD based on characterization (C1 will give us the timing distribution of the actual wedge mechanism).
2. **How to detect chip-state divergence at probe time** — currently the candidate is Phy16Sta `EquComplete` bits (we observed cold-plug shows them set, recovered shows them clear). May need additional signals; may need empirical tuning per chip generation. See `chip-state-diff-2026-05-28/` archive.
3. **Whether to gate F40b behind `NV_FLAG_EXTERNAL_TEARDOWN_PROTECTION` (E1-detected external GPUs only) or apply universally** — performance/risk trade-off. The wrapper's overhead on healthy chips is one work_struct allocation per teardown; tiny. May make sense to enable universally for symmetry.
4. **Whether `gpuStateDestroy` is sink-state-aware enough today, or needs additional `NV_ASSERT_OR_GPU_LOST` sites added on the lost-mode path** — F40b.4 audit answers this.

## Dependencies

- C5 (cleanupGpuLostStateAtomic primitive + dual-marker sink state + DETECTOR_* enum)
- E1 (external-GPU detection at probe)
- A4 (close-path telemetry — for diagnosing F40b firing in the field)

No conflict with existing patches. F40b extends C5's architecture; doesn't replace any existing work.

## What characterization must answer before implementation

These are the open questions the C1–C4 test sequence will answer. The patch design will be informed by the results:

- **C1**: actual kernel function that hangs (with bpftrace attached during a real wedge). If a specific function emerges as "always the one stuck," we can target the wrapper more surgically rather than wrapping the whole `nv_shutdown_adapter` call.
- **C2**: whether the rmmod-path wedge is the same mechanism as the close-path wedge or a separate failure mode. Informs whether F40b's coverage of the rmmod path is identical to what F40a (close-path probe-time policy) covers, or different.
- **C3**: whether the production `uninstall` graceful-teardown path is safe on a userspace-recovered chip. If yes, the failure class only manifests on the raw `unbind`/`rmmod` path. If no, our production injector container may have a latent risk.
- **C4 (optional)**: ftrace function_graph capture if C1 inconclusive — gives the complete kernel call chain through the wedge moment.

## Status next-steps

1. Run C1-C3 characterization (3 reboots total).
2. Capture results in companion experiment writeups.
3. Update this document with the empirical findings: actual wedge function, timing distribution, link-disable behavior on TB-tunneled bridge.
4. Refine the implementation phases based on findings.
5. Implement F40b.1 (the cheapest, independently-testable piece) first.

Implementation work is gated on characterization. This is by design — the test results are the input to the patch's empirical decisions (timeout values, which functions to wrap, etc.).
