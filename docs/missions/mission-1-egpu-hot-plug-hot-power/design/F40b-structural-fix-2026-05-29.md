# F40b — structural fix for the destructive-teardown wedge class

**Date:** 2026-05-29
**Status:** Design phase — pending characterization (C1–C4) before implementation
**Scope:** NVIDIA driver fork (this project) — independent of E27 (Linux kernel)
**Cross-refs:** `fake-5090/failure-modes/F40-rmshutdownadapter-incomplete-init-wedge.md`; `docs/missions/.../experiments/h1-userspace-recovery-2026-05-28.md`

## Purpose

Close the F40 failure class structurally in our nvidia.ko fork. F40 is "the destructive teardown wedges the host on a chip in a state the driver doesn't fully model" — currently observed when the chip is in the userspace-recovered state from `fix-bar1.sh`, but the failure class is broader than that single trigger.

Goal: tear down the device correctly (free resources, clean kernel-side state) WITHOUT freezing the host if the chip won't cooperate.

This fix is **independent of E27**. E27 (Linux kernel patch for F41) prevents the userspace-recovered chip state in the TB-hot-add case; F40b makes the driver resilient to any analogous chip state from any cause. Either fix alone resolves the user-visible failure; together they're defense in depth.

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
