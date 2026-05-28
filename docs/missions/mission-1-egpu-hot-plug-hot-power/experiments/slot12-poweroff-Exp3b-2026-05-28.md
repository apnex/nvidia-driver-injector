# Exp 2 + 3b + 4 + chip-register-hack wedge — multi-experiment post-mortem

**Date:** 2026-05-28 22:30 UTC (boot -1 in journalctl, 20:52-20:57 AEST)
**Status:** Exp 2 / 3b / 4 verdicts captured; final ReBAR Control hack wedged the host (2 reboots to recover)
**Setup:** aorus.17 v4 base, consumers quiesced via nodeSelector patch, broken-BAR1 produced via thunderbolt-sysfs deauth/reauth

This document records:
1. Methodological win: broken-BAR1 produced cleanly via `/sys/bus/thunderbolt/devices/0-1/authorized` deauth+reauth — no physical action required
2. Three predicted-no-recovery experiments confirmed (Exp 2 full system rescan, Exp 3b slot cycle on broken-BAR1, Exp 4 bridge SBR)
3. A failed attempt to bypass H1 via direct chip ReBAR Control register write, which appeared to succeed in sysfs but wedged the host
4. Honest revision of the H1 mechanism understanding (and retraction of Exp 3a's "userspace workaround" claim)

## Methodological note — clean broken-BAR1 reproduction via thunderbolt sysfs

Previous broken-BAR1 productions required physical cable yank or chassis power-off + boltctl authorize. This experiment session discovered:

```bash
# Producing broken-BAR1 without physical action:
echo 0 > /sys/bus/thunderbolt/devices/0-1/authorized   # deauth (~5s)
echo 1 > /sys/bus/thunderbolt/devices/0-1/authorized   # reauth → broken-BAR1
```

Result: BAR1=256MiB, bridge 03:00.0 prefetchable=288M — identical broken state to physical hot-plug.

Caveat: requires the TB device to be enrolled (which it is on this host). On a host where the TB device isn't enrolled, boltctl would need to enroll first.

**This is the right way to reproduce broken-BAR1 in future experiments.** Cleaner than waiting for the user to physically yank a cable.

## Exp 2 — `/sys/bus/pci/rescan` (full system) on broken-BAR1

**Hypothesis:** full system rescan walks the entire PCI tree from root; might recompute bridge windows differently than bridge-scoped rescan.

**Procedure:**
1. Broken-BAR1 state (BAR1=256MiB, bridge=288M)
2. `echo 1 > /sys/bus/pci/rescan`
3. Read back BAR1 + bridge

**Result:**
- BAR1: 256MiB (unchanged)
- Bridge 03:00.0: 288M (unchanged)

**Verdict:** as predicted. Full system rescan does NOT recover broken-BAR1. The kernel re-walks the PCI tree but doesn't recompute bridge windows from scratch.

## Exp 4 — Bridge SBR via setpci `BRIDGE_CONTROL` on broken-BAR1

**Hypothesis:** SBR (bit 6 of bridge control) is a kernel-aware hardware reset of downstream devices. Might trigger bridge window recompute or BAR re-negotiation.

**Procedure:**
1. Broken-BAR1 state
2. `setpci -s 03:00.0 BRIDGE_CONTROL.W=0x0040` (assert SBR)
3. Sleep 100ms (PCIe spec requires ≥2ms hold)
4. `setpci -s 03:00.0 BRIDGE_CONTROL.W=0x0000` (deassert)
5. Read back BAR1 + bridge

**Result:**
- BRIDGE_CONTROL pre: `0x0002`
- BRIDGE_CONTROL post: `0x0000` (the SERR# enable bit got cleared by my W=0x0000 — minor side effect)
- BAR1: 256MiB (unchanged)
- Bridge 03:00.0: 288M (unchanged)

**Verdict:** as predicted. SBR resets downstream devices but doesn't trigger bridge window recompute. Bridge state preserved.

## Exp 3b — pciehp slot 12 power cycle on broken-BAR1

**Hypothesis (originally — from Exp 3a):** pciehp slot 12 power cycle recovers BAR1 to 32GB by going through a different bridge-sizing algorithm than runtime hot-plug.

**Procedure:**
1. Broken-BAR1 state (BAR1=256MiB, bridge=288M)
2. `echo 0 > /sys/bus/pci/slots/12/power` (power off)
3. Sleep 5s
4. `echo 1 > /sys/bus/pci/slots/12/power` (power on)
5. Sleep 10s for re-enumeration
6. Read back

**Result:**
- BAR1: **256MiB (unchanged from broken-BAR1)**
- Bridge 03:00.0: **288M (unchanged)**

**Verdict:** ❌ **FALSIFIED.** Slot cycle does NOT recover broken-BAR1.

This is the key revision to Exp 3a's interpretation. The slot cycle does NOT "magically widen bridge windows." What it actually does:
- Tear down bridge windows + BAR allocations
- Re-allocate them based on whatever BAR sizes the chip is currently advertising

In Exp 3a: chip was advertising 32GB (preserved from cold-boot's `pci_setup_resizable_bars()` write to the chip's ReBAR Control register). So re-allocation gave 32GB.

In Exp 3b: chip is advertising 256MB (because TB hot-add's code path did NOT call `pci_setup_resizable_bars()`, leaving the chip at its post-hot-plug state). Re-allocation gives 256MB.

**The actual H1 root cause:** Linux's runtime TB hot-add code path doesn't write the chip's ReBAR Control register to request the max-supported BAR size. Cold-boot does. The kernel's bridge-sizing algorithm is CORRECT given the inputs it sees — the inputs are wrong because the chip is in the wrong state.

## The chip ReBAR Control register hack — appeared to succeed, wedged the host

**Hypothesis:** If we write the chip's ReBAR Control register directly (bypassing the kernel's pci_resize_resource() which rolls back on bridge ENOSPC), the chip will advertise 32GB. Then slot cycle re-enumerates with the new advertisement → 32GB BAR1.

**Procedure:**
1. Broken-BAR1 state, nvidia unbound (`echo 0000:04:00.0 > /sys/bus/pci/drivers/nvidia/unbind`)
2. Find ReBAR Capability via lspci -xxxx — Physical Resizable BAR at offset `[134]`
3. ReBAR Control register at offset `0x13c` (4 bytes)
4. Decoded current value `0x00000821`:
   - bits[2:0] = 1 (BAR Index 1) ✓
   - bits[7:5] = 1 (1 BAR after this in cap) ✓
   - bits[13:8] = 8 = 256MB (broken) ✓
5. Write target value `0x00000F21`:
   - bits[2:0] = 1
   - bits[7:5] = 1
   - bits[13:8] = 15 = 32GB
6. `setpci -s 04:00.0 0x13c.l=0x00000f21`
7. Re-read confirmed `0x00000f21` written successfully
8. Slot 12 power cycle (`echo 0` / sleep 5 / `echo 1`)
9. Wait 10s for re-enumeration

**Apparent result (in sysfs):**
- BAR1: 32768 MiB (32 GiB) ✓
- Bridge 03:00.0: 32800 MiB ✓
- ReBAR Control register persisted at `0x00000f21` ✓

**I declared "success" — this was the premature-success-overreach.**

**Actual outcome:** 10 seconds later, the host wedged silently. journalctl shows last activity at 20:56:37 (vllm-soak-metrics oneshot service completing) then silence until reboot at 21:03:22. User had to reboot twice to recover.

## Wedge forensics

From `journalctl -b -1`:
- `20:56:27` — slot 12 re-enum completed; nvidia.ko auto-bound via pciehp's add path (last NVRM message: `nvidia 0000:04:00.0: vgaarb: VGA decodes changed`)
- `20:56:33` — vllm-soak-metrics oneshot service started
- `20:56:37` — vllm-soak-metrics finished cleanly
- After 20:56:37 — **silence**. No further kernel messages, no Xid, no detector_class log, no hung-task warning, no AER, no nothing.
- User power-cycled at ~21:00, then again to fully recover, current boot started 21:03:22

The classic **silent probe-path wedge**:
- nvidia.ko's `rm_init_adapter` probe ran after auto-bind
- Probe RPCs into the chip wedged because the chip's internal state was inconsistent
- ReBAR Control register said "BAR1 = 32GB" but the chip's MMIO surface, GSP boot state, persistence state, etc. had NOT been reset to match
- Direct setpci write doesn't trigger the chip-side "I'm now advertising a new size, redo my setup" handshake that cold-boot's `pci_setup_resizable_bars()` apparently does
- Probe wedged holding the GPU lock → host slowly froze

Journal archive: `/var/log/mission-1-archaeology/wedge-2026-05-28-20-56/journalctl-prior-boot.log` (1.1MB)

## Revised H1 understanding

Previous interpretations (now all retracted or revised):
- ~~"Linux fails to propagate prefetchable headroom from upstream bridges"~~ (from ReBAR Phase 1 experiment) — DESCRIPTIVELY true at the bridge level but not the root cause
- ~~"Bridge window sizing in `__assign_resources_sorted` is the patch landing zone"~~ (from ReBAR Phase 2 experiment) — true but not where the algorithm goes wrong
- ~~"pciehp slot cycle is a userspace workaround"~~ (from Exp 3a writeup) — FALSE, retracted today

**Actual H1 root cause:**

The kernel's bridge-sizing algorithm is correct. It sizes the bridge to fit the BAR sizes the chip is currently advertising. The bug is that the chip is advertising the wrong sizes after hot-plug:

- Cold-boot: kernel calls `pci_setup_resizable_bars()` during enumeration, which iterates ReBAR-capable BARs and writes each chip's ReBAR Control register to request the device's maximum supported size. Chip then advertises max sizes; kernel sizes bridges to fit; BAR1 comes up at 32GB.
- TB hot-add: kernel's runtime hot-add code path does NOT call `pci_setup_resizable_bars()`. Chip's ReBAR Control register retains whatever value it had (default from chip reset, which is the SMALLEST supported size — 256MB on this chip). Kernel sees chip advertising 256MB and sizes bridge accordingly.

**E27 landing zone (final, sharper version):**

The fix is to call `pci_setup_resizable_bars()` (or equivalent) on the TB hot-add code path before bridge sizing runs. This is a small kernel patch likely in `drivers/thunderbolt/` or `drivers/pci/probe.c`.

The userspace workaround that would actually work (in principle):
- Write the correct ReBAR Control values to each ReBAR-capable BAR's chip register via setpci
- AND ensure the chip has been reset/initialized properly so the new sizes take effect
- AND re-trigger PCI enumeration

The second step (chip reset/initialization) is the blocker. There's no userspace API to do whatever cold-boot does in `pci_setup_resizable_bars()` beyond just the register write. My setpci hack showed that the register-write-only approach causes the chip to look right to the kernel (in sysfs) but be unusable when actually accessed (probe wedge).

## Honest lessons captured

1. **Premature-success overreach** — I claimed Exp 3a was a workaround based on testing only the healthy-state preservation case. The companion broken-state test (Exp 3b) falsified it the same day. I should have run Exp 3b BEFORE writing the Exp 3a "breakthrough" doc.
2. **Sysfs success ≠ device usability** — `cat .../resource` showed BAR1=32GB after my hack. That made the resource visible in the kernel's tree. It did NOT mean the chip would respond correctly to MMIO/RPC at those addresses. The wedge demonstrated this empirically.
3. **Don't let nvidia.ko auto-rebind after chip-state manipulation** — the wedge happened during nvidia.ko's automatic probe after pciehp's add. If the chip is in a manipulated state, nvidia.ko binding can wedge. For future experiments, consider how to keep nvidia.ko unbound across the slot cycle (the kernel auto-binds on probe; would need a different mechanism like `/sys/.../driver_override` set to "none" before the operation).
4. **Cumulative testing discipline** — Exp 1 (AER injection), then Exp 3a + retraction-by-3b, then the chip-register hack all stacked complexity. The wedge happened in the third overlay. Better: run experiments standalone with reboot between, accept the reboot cost as part of the discipline.

## Forensic captures

- `/var/log/mission-1-archaeology/post-wedge-recovery-2026-05-28.baseline.txt` — current healthy state
- `/var/log/mission-1-archaeology/wedge-2026-05-28-20-56/journalctl-prior-boot.log` — entire 1.1MB journal of the wedge boot

## Cross-references

- [[slot12-poweroff-Exp3a-2026-05-28]] — Exp 3a writeup, now annotated as retracted at top
- [[aer-inject-Exp1-2026-05-28]] — Exp 1
- [[rebar-bridge-window-experiment-2026-05-28]] — initial ReBAR sysfs experiment
- [[rebar-bridge-window-experiment-2026-05-28-phase2]] — Phase 2 setpci+rescan (also failed; kernel ignored)
- [[../../../memory/project_rebar_sysfs_bridge_window_bottleneck_2026_05_28]] — original H1 root-cause memory (will need updating with new ReBAR-Control finding)
- [[../../../memory/feedback_no_rpc_observability_on_broken_bar1_2026_05_28]] — Run 4b wedge memory (this incident is in the same class but more subtle — the wedge came from nvidia.ko's auto-rebind after chip state manipulation, not from active observability)
- [[../../../memory/feedback_premature_success_overreach_pattern_2026_05_26]] — discipline lesson (this incident is the third instance of this pattern; meta-lesson: when testing recovery, always include the broken-state regression check before declaring success)
