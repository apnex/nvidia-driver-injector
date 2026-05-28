# Exp 1 — Synthetic AER fatal injection on healthy GPU

**Date:** 2026-05-28 09:05 UTC
**Status:** PARTIAL FALSIFICATION — sink fired (good) but via different detector class than predicted (design-relevant)
**Setup:** aorus.17 v4 base, cold-plug BAR1=32GiB, both pods 1/1 Running, persistence engaged.

## Hypothesis

Synthetic fatal-uncorrectable AER at `0000:04:00.0` (MalfTLP bit 18, severity=fatal per UESvrt) will:
- Trigger Linux's AER recovery path
- Invoke C4's `nv_pci_error_detected` callback
- v4 hunk in DISCONNECT branch calls `rm_cleanup_gpu_lost_state(...DETECTOR_AER_FATAL)`
- One canonical `cleanupGpuLostStateAtomic: GPU 0 lost via detector_class=3` line in dmesg

**Predicted acceptance criterion:** ONE sink log with `detector_class=3`.

## Procedure

1. Loaded `aer_inject` kernel module: `sudo modprobe aer_inject` → `/dev/aer_inject` created
2. Pre-state captured (BAR1=32GiB, zero detector fires, pods 1/1)
3. Confirmed UESvrt at AER cap offset `[1b8]`: DLP+, FCP+, RxOF+, **MalfTLP+** = all FATAL
4. Wrote 32-byte struct via Python to `/dev/aer_inject`:
   - bus=0x04, dev=0x00, fn=0x00, uncor_status=0x00040000 (MalfTLP), domain=0
5. Observed cascade in dmesg + sysfs

## Observed cascade

```
[1179.162740]  pcieport 0000:00:07.0: AER: Uncorrectable (Fatal) error message received from 04:00.0
[1179.162744]  nvidia 0000:04:00.0: AER: PCIe Bus Error: severity=Uncorrectable (Fatal), type=Inaccessible
[1179.162942]  tb_egpu recover: AER error_detected fired on 0000:04:00.0 (channel state=2)   ← C4 callback (1st call)
[1179.163047]  tb_egpu recover: error_detected -> NEED_RESET (scheduling bus reset; attempts=1/3)   ← A3 → recovery path
[1179.163054]  pci 0000:04:00.1: AER: can't recover (no error_detected callback)    ← audio fn unbound (expected)
[1179.171494]  NVRM: cleanupGpuLostStateAtomic: GPU 0 lost via detector_class=4   ← SINK FIRE (Q-watchdog)
[1179.171527]  NVRM: GPU at PCI:0000:04:00: GPU-90b9424e-...
[1179.171538]  Xid (PCI:0000:04:00): 154, GPU recovery action 0x0 -> 0x1
[1179.338749]  pcieport 0000:03:00.0: AER: Downstream Port link has been reset (-25)   ← kernel attempted SBR
[1179.338761]  pcieport 0000:03:00.0: AER: subordinate device reset failed             ← reset FAILED
[1179.338804]  tb_egpu recover: error_detected -> DISCONNECT (sink-set: GPU already declared lost (C5 sink); attempts=1/3)   ← C4 (2nd call) → A3 GATE_SURRENDER
[1179.338817]  pcieport 0000:03:00.0: AER: device recovery failed
```

## Verdict

**Partial falsification of hypothesis:** sink fired (good) but with `detector_class=4` (Q-watchdog) instead of predicted `detector_class=3` (AER fatal).

**Why the prediction was wrong:**

C4's sink-call for `DETECTOR_AER_FATAL` is in the **DISCONNECT branch** of `nv_pci_error_detected`. The first call from kernel's AER recovery went through the `NEED_RESET` branch (because A3 gate evaluation said "attempt recovery, attempts=1/3"). The DISCONNECT branch was reached on the SECOND callback after kernel's bus reset attempt failed — but by then Q-watchdog (with 200ms cycle) had already detected DMA forward-progress halt (~8ms after the AER signal) and set the sink with `DETECTOR_QWATCHDOG_DMA_WEDGE` (class 4). The sink primitive is idempotent, so C4's second callback didn't add a second log line.

## Design-relevant finding

**`DETECTOR_AER_FATAL` (class 3) is rarely the FIRST detector class to fire under realistic AER conditions.** It's reachable only via:
- A3 returning DISCONNECT on the first callback (gate already says surrender — e.g., max attempts hit)
- OR a path that goes straight to the default branch (e.g., null state pointer; unlikely)

In practice, Q-watchdog or osHandleGpuLost retry exhaustion will win the race in most AER cascades because:
- Q-watchdog has a 200ms cycle — fast enough to fire before kernel's bus reset attempt completes (~175ms in this test)
- osHandleGpuLost retries exhaust in microseconds when MMIO reads start returning 0xFFFFFFFF

The architecture's promise ("SOME detector fires, not WHICH one") still holds. The `detector_class` in the canonical log identifies what won the race, not the underlying trigger.

## Bonus finding

**Linux's automated bus reset via the AER recovery path FAILED on this TB-tunneled bridge** (`subordinate device reset failed`, error -25 = `-EILSEQ`). This empirically confirms `feedback_pex_recovery_in_scope` — the kernel's pci_reset_bus()-based recovery isn't reliable on TB tunnels. A3's bounded-retry design correctly anticipated this.

The mature design of A3 prevented unbounded retry — first call attempts (NEED_RESET; attempts=1/3); second call sees sink-set from Q-watchdog and surrenders.

## Comparison to cable yank + power-off tests

| Metric | E07 Run 4 (cable yank) | Power-off Run 1 | Exp 1 (AER inject) |
|---|---|---|---|
| Trigger | physical TB yank | AORUS power switch off | software AER inject |
| Detector class that fired | 1 (OSHANDLEGPULOST) | 1 (OSHANDLEGPULOST) | **4 (Q-WATCHDOG)** |
| Time to sink fire | ~6ms | ~34ms (USB unplug first) | ~8.5ms |
| C4 callback invoked | yes | yes | **yes (twice)** |
| Kernel bus-reset attempted | n/a (device gone) | n/a (device gone) | **yes, FAILED -25** |
| Host wedge | none | none | none |
| Recovery | reboot | reboot | reboot |
| Pods state | still 1/1 | still 1/1 | **still 1/1, 0 restarts** |

## Recovery

GPU is in sink-lost state but still physically on the PCI bus (the bus reset attempt and failure didn't trigger device removal). Pods continue to run (both 1/1) but won't be able to use the GPU. Reboot needed to recover for next experiments.

## Forensic captures

- `/var/log/mission-1-archaeology/aer-inject-Exp1.baseline.txt`
- `/var/log/mission-1-archaeology/aer-inject-Exp1.snapshot.txt`

## Cross-references

- [[../cascade-class-design-v4]] — Exp 1 partial falsification suggests rethinking the relationship between `DETECTOR_AER_FATAL` and the C4 callback's NEED_RESET path
- [[E07-cable-replug-drain-first]] — Run 4 cable yank comparison
- [[power-off-wedge-Run-1]] — power-off comparison
- [[../../../memory/feedback_pex_recovery_in_scope]] — confirms Linux bus reset unreliable on TB bridges
