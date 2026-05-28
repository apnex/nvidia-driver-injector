# Power-off wedge Run 1 — 2026-05-28 09:08 UTC — **PASS under aorus.17 with v4 base architecture**

**Status:** PASS — host survived AORUS chassis power-off; clean PCIe teardown in ~34ms; no wedge.

**Trigger:** physical power-off via AORUS AI BOX power switch (cable remained connected). Distinct from E07's cable-yank scenario; tests the silent-power-loss failure class that A2 Q-watchdog and MMIO post-read detectors are designed for.

**Driver:** `595.71.05-aorus.17` (v4 base architecture, post-cold-plug).

## Setup

- Cold-boot to aorus.17, kernel uptime 457s at trigger
- BAR1 = 32GiB; bridge 03:00.0 prefetch = 33089M; TB authorized
- Active consumers: nvidia-device-plugin DaemonSet (NVML probes ~30s) + injector with persistence engaged (P8 @ 21W)
- vLLM not running (vllm namespace empty)
- Zero pre-trigger detector fires
- Pre-trigger forensic capture: `/var/log/mission-1-archaeology/power-off-Run1.baseline.txt`, `/var/log/mission-1-archaeology/power-off-Run1-aorus17/pre-trigger.tar.gz`

## dmesg cascade (post-trigger, ~34ms total)

```
[  549.140665] usb 3-1: USB disconnect, device number 2        ← USB tunnel goes down first (chassis power dies)
[  549.142153] thunderbolt: acking hot unplug event on 0:1
[  549.142282] thunderbolt 0-0:1.1: retimer disconnected
[  549.142390] thunderbolt: 0:8 <-> 1:9 (PCI): deactivating    ← PCIe tunnel torn down
[  549.144154] thunderbolt: 0:12 <-> 1:20 (USB3): deactivating
[  549.165056] pcieport 0000:00:07.0: pciehp: Slot(12): Link Down
[  549.165058] pcieport 0000:00:07.0: pciehp: Slot(12): Card not present
[  549.167333] NVRM: GPU at PCI:0000:04:00: GPU-90b9424e-7236-fd4d-d903-44e565e1bd42
[  549.167335] NVRM: Xid (PCI:0000:04:00): 79, GPU has fallen off the bus.
[  549.167345] NVRM: cleanupGpuLostStateAtomic: GPU 0 lost via detector_class=1   ← ONE canonical sink fire (DETECTOR_OSHANDLEGPULOST_RETRY_EXHAUSTED)
[  549.167346] NVRM: krcRcAndNotifyAllChannels_IMPL: RC all channels for critical error 79.
[  549.167351] NVRM: _threadNodeCheckTimeout: API_GPU_ATTACHED_SANITY_CHECK failed   ← G5 rate-limit: ONE line
[  549.167369] NVRM: RmLogGpuCrash: GPU lost, skipping crash log to avoid diagnostic-RPC cascade   ← G6 fired
[  549.167379] NVRM: Xid (PCI:0000:04:00): 154, GPU recovery action changed from 0x0 (None) to 0x1 (GPU Reset Required)
[  549.168518] NVRM: GPU0 _kccuUnmapAndFreeMemory: CCU memdesc unmap request failed with status: 0xf   ← cleanup-path graceful IS_LOST
[  549.168948] NVRM: _kfspWriteToEmem_GH100: dead-bus read on EMEMC; aborting EMEM write   ← G9 fired
[  549.169136] NVRM: nvCheckOkFailedNoLog: ... NV_ERR_GPU_IS_LOST ... @ gpu_user_shared_data.c:248   ← C5 v4 absorbed via NV_CHECK_OK graceful return
[  549.169175] NVRM: nvAssertFailedNoLog: Assertion failed: rmStatus == NV_OK @ osinit.c:2464   ← ⚠️ unconverted v4 site — non-fatal (same as Run 4)
[  549.170227] pci_bus 0000:04: busn_res: [bus 04] is released
[  549.170285] pci_bus 0000:05: busn_res: [bus 05-11] is released
[  549.170361] pci_bus 0000:12: busn_res: [bus 12-1e] is released
[  549.170393] pci_bus 0000:1f: busn_res: [bus 1f-2b] is released
[  549.170422] pci_bus 0000:03: busn_res: [bus 03-2b] is released
[  549.175000] usb 2-1: USB disconnect (Realtek LAN etc tunneled USB devices)
```

## v4 design promises — all verified

| Promise | Result |
|---|---|
| ONE canonical detector log per (gpu, class) | ✅ Single line `detector_class=1` (OSHANDLEGPULOST_RETRY_EXHAUSTED) |
| Cleanup completes within seconds (not minutes) | ✅ ~34ms total (USB unplug at 549.140 → final bus release 549.175) |
| Host SSH responsive throughout | ✅ `systemctl is-system-running` = `running`; uptime increasing |
| G5 rate-limit at API_GPU_ATTACHED_SANITY_CHECK | ✅ ONE line |
| G6 RmLogGpuCrash sink-check | ✅ "skipping crash log to avoid diagnostic-RPC cascade" |
| G9 kfsp arithmetic-invariant guard | ✅ "dead-bus read on EMEMC; aborting EMEM write" |
| gpu_user_shared_data.c:248 graceful absorb | ✅ NV_CHECK_OK graceful return |
| PCIe bus release sequence clean | ✅ 04 → 05-11 → 12-1e → 1f-2b → 03-2b in microseconds |
| Pods survive (no restart from event) | ✅ nvidia-device-plugin + nvidia-driver-injector still 1/1 |
| GPU cleanly removed from sysfs | ✅ `/sys/bus/pci/devices/0000:04:00.0/` gone |

## Finding: Q-watchdog (`[f]`) did NOT fire as primary detector

The architecture predicted that power-off (silent power loss, possibly without AER fatal) would be A2 Q-watchdog's primary detection class. Observed reality: **C3 osHandleGpuLost retry path won the race** — same detector_class=1 as Run 4 cable yank.

**Why:** consumers (nvidia-device-plugin NVML probes, injector persistence reads) issue MMIO reads frequently enough that one was in flight when chassis power dropped. The osHandleGpuLost retry budget exhausts in microseconds (the C3 retry loop's max delay × NV_GPU_LOST_RETRY_COUNT). Q-watchdog polls at 5Hz (~200ms cycle) — much slower than the osHandleGpuLost retry exhaust.

**Implication:** Q-watchdog is correctly designed as detector-of-last-resort for the case where NO consumer activity is in flight. In practice, the active-consumer state (which is the production case for vLLM workloads) makes C3 the primary detector. Q-watchdog still serves the silent-DMA-wedge class (`feedback_surprise_removal_wedge_class_2026_05_26`) where MMIO reads succeed but DMA forward-progress stalls — that's a distinct failure mode not covered by C3's retry.

**Architecture is correct:** the design promise is that SOME detection class fires, not WHICH one. All six detection inputs route through the same sink primitive, so the system-level invariant ("v4 detects + contains the failure") holds regardless of which detector wins the race.

## Comparison to Run 4 (cable yank, E07)

| Metric | Run 4 cable yank (E07) | Power-off Run 1 |
|---|---|---|
| Trigger | TB cable yanked | AORUS chassis power switch off |
| First detector | DETECTOR_OSHANDLEGPULOST_RETRY_EXHAUSTED | DETECTOR_OSHANDLEGPULOST_RETRY_EXHAUSTED (same) |
| Explicit Xid 79 line | implicit (sink fired before print) | EXPLICIT (kernel printed Xid 79 + sink in same μs window) |
| TB tunnel deactivation events in dmesg | TB-side just goes silent | EXPLICIT deactivation sequence (PCIe Down + Up paths, USB3 paths, retimer disconnect) |
| pciehp Slot signal | n/a | `Slot(12): Link Down`, `Slot(12): Card not present` |
| USB tunnel disconnect order | parallel with PCIe | USB ports first, then PCIe |
| Total cascade time | ~6ms | ~34ms (USB tunnel deactivation adds ~25ms) |
| Host result | RUNNING, responsive | RUNNING, responsive |
| Recovery required | None | None |
| All v4 guards fired correctly | ✅ | ✅ (same set) |
| `osinit.c:2464` nvAssertFailedNoLog | ⚠️ fires | ⚠️ fires (same gap, universal across trigger modes) |

## Known gap (carries forward from Run 4)

`osinit.c:2464` `NV_ASSERT(rmStatus == NV_OK)` was not converted to `NV_ASSERT_OR_GPU_LOST` in v4 implementation. Fires `nvAssertFailedNoLog` (soft, non-fatal). Universal across all unplug scenarios. v4.1 sub-cycle candidate.

## Post-trigger state

- Host: responsive; `systemctl is-system-running` = `running`
- GPU: removed from PCI bus (`/sys/bus/pci/devices/0000:04:00.0/` gone)
- Pods: nvidia-device-plugin + nvidia-driver-injector both 1/1 Running (NO restart from event)
- Forensic capture: `/var/log/mission-1-archaeology/power-off-Run1.snapshot.txt`, `/var/log/mission-1-archaeology/power-off-Run1-aorus17/post-trigger.tar.gz`

## Verdict

**PASS.** v4 architecture handles the power-off failure mode identically to cable yank — clean detection, contained cleanup, host survival. Phase 1 exit gate criterion 2 of 2 (validation tests) is met. The remaining exit-gate criterion is the 7-day production soak.

## Cross-references

- [[E07-cable-replug-drain-first]] — Run 4 (cable yank) sibling test, same PASS outcome
- [[../cascade-class-design-v4]] — v1.2 architecture (all design promises validated)
- [[../decision-architecture-class-localization]] — Option 1 commitment
- Memory: [[feedback_surprise_removal_wedge_class_2026_05_26]] — the wedge class v4 was designed to defeat
- Memory: [[feedback_no_rpc_observability_on_broken_bar1_2026_05_28]] — Run 4b lesson; not violated here (passive reads only post-trigger)
