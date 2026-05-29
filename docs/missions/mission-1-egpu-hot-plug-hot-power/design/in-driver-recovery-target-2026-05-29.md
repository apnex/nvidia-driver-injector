# In-driver recovery — target architecture (2026-05-29)

**Date:** 2026-05-29 evening
**Status:** Design — informs A7 (rmmod-path bounded-wait wrapper) + A8 (sysfs observability) + A9 (in-driver recovery state machine)
**Scope:** Long-term direction for the eGPU stack's response to F40-class wedge conditions
**Cross-refs:**
- F40 catalog (fake-5090): `failure-modes/F40-rmshutdownadapter-incomplete-init-wedge.md`
- F40b structural fix design: `F40b-structural-fix-2026-05-29.md` (same directory)
- A7 patch intent: `docs/patch-intents/A7-f40b-bounded-wait-shutdown.md` (forthcoming — rmmod-path symmetric counterpart of A6)
- A8 patch intent: `docs/patch-intents/A8-f40b-sysfs-observability.md` (forthcoming)
- A9 patch intent: `docs/patch-intents/A9-f40b-in-driver-recovery.md` (forthcoming)
- Project memory: `feedback_native_in_driver_hardening` (the destination preference)

## Purpose

Define the target architecture for the eGPU stack's response to F40-class wedge conditions: chip-touching MMIO from `RmInitAdapter` hangs on a userspace-recovered eGPU, and the host has to recover without a reboot. Current state (A6, 2026-05-29 evening) detects the wedge and fails fast; the operational recovery sequence (`rmmod + TB cycle + fix-bar1 + modprobe`) is orchestrated from userspace. The target state moves the recovery sequence into the driver itself — no userspace rmmod/modprobe round-trip, no DaemonSet watchdog, no external service.

## Reference model: Windows TDR

Windows' answer to "the GPU is hung" has been TDR (Timeout Detection and Recovery), built into the Direct3D Graphics Kernel (`Dxgkrnl.sys`), since Windows Vista. The architecture is instructive because it solves exactly our problem, in production, at scale:

- Every GPU command has a deadline (default 2 sec for graphics, longer for compute). DXG tracks every outstanding command.
- If the deadline is exceeded, DXG considers the engine hung and calls into the display miniport driver via `DxgkDdiResetEngine` / `DxgkDdiResetFromTimeout`.
- The driver's response is expected to (a) reset the engine or chip, (b) restore driver-side state, (c) tell DXG "ready for new work."
- If the driver fails 3 TDRs within 60 sec, DXG declares the adapter dead, marks it `LiveDump`, and removes it from the system. Apps see `DXGI_ERROR_DEVICE_REMOVED`.

WSL2 doesn't change any of this: GPU API calls forward to the host's Windows driver via the WDDM hypervisor interface, the host driver does TDR, the WSL2 VM sees the same error codes a native Windows app would. **There is no userspace recovery component in either Windows or WSL2** — TDR is end-to-end in the driver + DXG framework.

Three properties of the Windows model are worth preserving:

1. **In-driver recovery, period.** No userspace orchestration in the routine case. Operator sees the GPU briefly stutter then recover; only chronic failures (N strikes) escalate to a permanent-fail signal.
2. **Bounded detection at multiple layers.** Per-command deadlines (workload-level), per-engine resets (chip-level), per-adapter strikes (system-level). Each layer fails fast, hands off, and lets the next layer escalate.
3. **Application-level error returns are advisory.** Apps don't drive recovery; the framework does. The error is a result, not a request.

## Project trend — we're already heading this direction

Several recent project patches are foundational pieces of a Linux-side TDR equivalent:

| Patch | What it does | TDR-equivalent role |
|---|---|---|
| C5 (crash-safety) | Defines `cleanupGpuLostStateAtomic` sink primitive + `NV_GPU_LOST_DETECTOR_*` taxonomy | Adapter-marked-dead bookkeeping (the "device removed" state) |
| A2 (bus-loss-watchdog) | Watchdog for Mode B DMA wedge | Per-engine deadline detection (workload-level) |
| A3 (recovery) | Self-triggered bus reset state machine with H1/H2/H3 gates + counter publication | Per-engine reset (chip-level) + multi-attempt escalation |
| Lever M (in A3's lineage) | PCIe bus reset orchestration | The "reset the engine" primitive Windows calls `DxgkDdiResetEngine` |
| E1 (egpu-detection) | `nv->is_external_gpu` classifier | Adapter-type discriminator (gates Win-only behaviour) |
| **A6 (F40b — this evening)** | Bounded-wait wrapper for open-path MMIO | Per-syscall deadline detection (workload-level) for the open syscall |
| **A7 (forthcoming)** | Bounded-wait wrapper for rmmod-path MMIO (`nv_shutdown_adapter`) | Per-syscall deadline detection (workload-level) for the rmmod path — symmetric to A6 for the FORENSICS-attested rmmod-path wedge class |
| **A8 (forthcoming)** | sysfs observability for the F40b/recovery state machine | DXG-equivalent state tracking, exposed for monitors |
| **A9 (forthcoming)** | In-driver recovery state machine triggered by F40b | The chip-side reset + state restoration glue |

The pattern is consistent: each patch closes a specific failure class with a kernel-side response, leaving userspace to consume errors but not orchestrate recovery. After A7+A8+A9, the F40 case has the same property the Windows TDR cases have — detection (open + rmmod paths), response, recovery, observability — all in-driver.

## Target architecture

```
┌──────────────────────────────────────────────────────────────┐
│  userspace (apps, vLLM, nvidia-smi, monitoring)              │
│  • Sees -EIO for in-flight ops during recovery               │
│  • Reads sysfs attributes for current state + counters       │
│  • DOES NOT drive recovery                                   │
└──────────────────────────────────────────────────────────────┘
                              │
                              │  errno; sysfs reads
                              │
┌──────────────────────────────────────────────────────────────┐
│  nvidia.ko (kernel module, our fork)                         │
│                                                              │
│  Detection layer:                                            │
│    • F40b bounded-wait wrapper on open path (A6 — current)   │
│    • F40b bounded-wait wrapper on rmmod path (A7 — target)   │
│    • A2 bus-loss watchdog (existing)                         │
│    • C3 GPU-lost retry (existing)                            │
│    • C5 sink-state propagation (existing)                    │
│                                                              │
│  Recovery layer (A9 — target):                               │
│    • Recovery state machine, scheduled on detection          │
│    • pci_reset_bus(pdev)         ← chip-side reset           │
│    • Thunderbolt rebind via tb_*  ← TB-aware reset           │
│    • pci_resize_resource()       ← BAR1 restore              │
│    • Re-probe via nvidia.ko's own probe path                 │
│    • Clear sink, state → healthy                             │
│    • Multi-attempt with backoff (A3-style H1/H2/H3 gates)    │
│    • After N attempts: permanent-fail, state → lost-perm     │
│                                                              │
│  Observability layer (A8 — target):                          │
│    • /sys/bus/pci/devices/.../tb_egpu_state                  │
│    • /sys/bus/pci/devices/.../tb_egpu_recovery_count         │
│    • /sys/bus/pci/devices/.../tb_egpu_recovery_failures      │
│    • /sys/bus/pci/devices/.../tb_egpu_last_recovery_ns       │
│    • Existing kernel-log markers (already emitted by F40b)   │
└──────────────────────────────────────────────────────────────┘
                              │
                              │  PCIe, MMIO, Thunderbolt protocol
                              │
┌──────────────────────────────────────────────────────────────┐
│  hardware: NVIDIA GB202, Thunderbolt 4 tunnel                │
│  (chip-side defect causing F40 lives here; we work around    │
│   it from the driver layer)                                  │
└──────────────────────────────────────────────────────────────┘
```

## Signaling decision — sysfs alone, no uevent

Under in-driver recovery, the signal consumer is observability (monitoring, ops dashboards, post-mortem analysis), not reactive automation. Observability wants current state and counters; it does not need transition events.

| Consumer | Question | Mechanism |
|---|---|---|
| Prometheus / monitoring | "What is the current state? How many recoveries?" | sysfs scrape every N sec |
| nvidia-smi (future) | "Show a 'Recovery State' column" | sysfs read at query time |
| Post-mortem analysis | "When did the last F40b fire?" | journalctl -k (already emitted by F40b) |
| Reactive userspace recovery service | "Wake me on F40b fire to do rmmod/modprobe" | **Not needed in target state** — driver handles it |

The last row is the test of whether we need uevent. In the target state, no userspace process is waiting to take action — so no uevent. Adding one would be debt: API surface area whose only legitimate consumer is "the thing we're trying to eliminate."

Reference patterns in mainline Linux:
- **NVMe controller `state`** (`/sys/class/nvme/nvme0/state`) — sysfs only, polled by ops
- **Block device `state`** (`/sys/block/sda/device/state`) — sysfs only
- **Network device `operstate`** — sysfs + uevent (because OTHER userspace components react to link changes — that justifies the uevent there)
- **DRM connector `status`** — sysfs + uevent (because the display server reacts)

The justification for uevent in the network and DRM cases is that mainline already has userspace components that react. We don't, and we're deliberately not building any.

## What needs to be built

### A7 — rmmod-path bounded-wait wrapper (this round, smallest patch)

- Mirror A6's bounded-wait wrapper for the chip-touching MMIO inside `nv_shutdown_adapter` on the rmmod / `nv_pci_remove` path
- Gated on `nv->is_external_gpu` + `NVreg_TbEgpuShutdownTimeoutMs > 0`
- On timeout: set C5 sink-state, skip chip-touching teardown steps, allow remove callback to complete cleanly so rmmod returns
- Closes the rmmod-path F40-class wedge attested by the 20:52 FORENSICS report (the wedge that A6 alone cannot prevent)
- Estimated size: ~30-50 lines of patch (smaller than A6 because the wrapper pattern is already established)

### A8 — sysfs observability (this round, smaller patch)

- Add four per-PCI-device sysfs attributes via the standard `device_attribute` mechanism
- Hook the attribute backing values to the F40b state machine that already exists (after A6 + A7)
- No behaviour change beyond exposing state
- Estimated size: ~50-80 lines of patch

### A9 — in-driver recovery state machine (later round, larger patch)

- New file `kernel-open/nvidia/nv-f40b-recovery.c` (or extend existing recovery file)
- Recovery worker registered on F40b timeout path
- Multi-attempt state machine using A3-style gates (H1/H2/H3) — leverage Lever M's existing primitives
- TB rebind glue: call into `tb_switch_authorize` / `tb_unauthorize` from kernel
- BAR1 restore: `pci_resize_resource()` calls matching what fix-bar1.sh does from userspace
- Counter increments wired to A8's sysfs attributes
- Estimated size: ~300-500 lines of patch (the largest part is the TB rebind glue and the recovery state machine; the rest reuses existing primitives)

## Open design questions

1. **Recovery latency budget.** What's the acceptable wall-clock for a successful in-driver recovery? Order-of-magnitude estimate: bus reset (~100 ms) + TB rebind (~3-5 sec) + ReBAR resize + re-probe (~1-2 sec) = ~5-10 sec total. Comparable to Windows TDR which targets sub-second to multi-second. Acceptable for our workload class.
2. **Should recovery be transparent or visible?** Windows TDR returns `DXGI_ERROR_DEVICE_REMOVED` to apps even on successful recovery — apps must recreate their device. Linux equivalent: should the in-flight open syscall be re-tried internally (return success after recovery) or should it always return -EIO and let userspace retry? Latter is simpler and matches Windows semantics.
3. **Recovery escalation.** After how many recovery failures do we declare `lost-permanent`? Windows uses 3-strikes-in-60-sec. We'd want similar but tunable via NVreg.
4. **Thunderbolt rebind from kernel.** Verify the `tb_switch_*` APIs exposed by `drivers/thunderbolt` are sufficient for what we need to do from nvidia.ko. If not, we may need to drop down to direct sysfs writes (`pci_write_config_word` to PCIe link control on the parent bridge) — less elegant but bypasses the cross-module API question.
5. **Coexistence with current operator-driven recovery.** While A9 is in development, the operator-driven sequence is still available. After A9 lands, do we deprecate the userspace recovery path entirely or keep it as an escape hatch? Recommended: keep it documented as the recovery-of-last-resort if A9 has bugs.

## Status / next-steps

1. ✅ A6 implemented + validated (2026-05-29 evening, F40B-TEST n=2)
2. **A7 next** — rmmod-path bounded-wait wrapper (symmetric to A6; closes the FORENSICS-attested rmmod-path wedge)
3. **A8 alongside A7** — sysfs observability surface (small patch, batched with A7 per the (C) recommendation in the FORENSICS report)
4. A9 — full in-driver recovery state machine, larger patch (designed in A9 patch intent, revisit before implementation)
5. After A7+A8+A9 land, deprecate the userspace recovery path (or keep as escape hatch)
6. Future: extend the same approach (in-driver recovery, sysfs observability) to other failure classes (close-path wedges, surprise-removal cascade, etc.)
