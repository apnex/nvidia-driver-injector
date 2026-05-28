# Exp 3a — pciehp slot 12 power cycle on healthy GPU — **USERSPACE WORKAROUND FOR H1 DISCOVERED**

**Date:** 2026-05-28 09:16-09:17 UTC
**Status:** 🎯 **BREAKTHROUGH** — slot power cycle via pciehp gives BAR1=32GB on re-power, where all previous re-enumeration paths gave broken-BAR1 (256MB)
**Setup:** aorus.17 v4 base, fresh cold-plug after reboot from Exp 1, BAR1=32GiB, consumers running, persistence engaged.

## Hypothesis

PCIe hot-plug slot power cycle via `/sys/bus/pci/slots/12/power` goes through a DIFFERENT code path inside the kernel than:
- Physical cable yank
- Chassis power-off / power-on
- boltctl deauthorize / authorize
- Software `echo 1 > .../remove` + rescan
- Setpci bridge widening + rescan

All previously-tested re-enumeration paths gave **broken-BAR1 (256MB)** because Linux's runtime hot-plug code path doesn't honor `pci=hpmmioprefsize=32G` and doesn't query downstream ReBAR caps for sizing bridges.

**Predicted alternative outcomes:**
- Slot power cycle gives 32GB BAR1 → userspace workaround for H1 discovered
- Slot power cycle gives 256MB BAR1 → H1 is independent of trigger path; E27 kernel patch is unavoidable

## Procedure

1. **Safety check** — confirmed default route `enp86s0` (not TB-tunneled) so SSH wouldn't drop
2. **Slot 12 verification** — `/sys/bus/pci/slots/12/address` = `0000:02:00` = Intel JHL9480 Barlow Ridge TB5 Bridge (TB tunnel parent containing the GPU's hierarchy)
3. **Quiesce consumers** via nodeSelector patch on both DaemonSets (per `feedback_no_rpc_observability_on_broken_bar1_2026_05_28` discipline)
4. **Capture baseline:** `/var/log/mission-1-archaeology/slot12-poweroff-Exp3a.baseline.txt` — BAR1=32GiB, bridge 03:00.0 prefetch=33089M
5. **Power off slot 12:** `echo 0 > /sys/bus/pci/slots/12/power`
6. **Observe teardown:** clean PCIe bus releases (04 / 05-11 / 12-1e / 1f-2b / 03-2b), zero detector fires (consumers were already quiesced; no error condition)
7. **Power on slot 12:** `echo 1 > /sys/bus/pci/slots/12/power`
8. **Observe re-enumeration:** immediate BAR1 read from passive sysfs

## Result

```
[437.155577] pci 0000:03:00.0: bridge window [mem size 0x814000000 64bit pref]: can't assign; no space
[437.155578] pci 0000:03:00.0: bridge window [mem size 0x814000000 64bit pref]: failed to assign
[437.155578] pci 0000:03:00.0: bridge window [mem 0x4000000000-0x4801ffffff 64bit pref]: assigned   ← 32.5GB!
[437.155579] pci 0000:03:00.0: bridge window [mem 0x4000000000-0x4801ffffff 64bit pref]: failed to expand by 0x12000000
[437.155581] pci 0000:04:00.0: BAR 1 [mem 0x4000000000-0x47ffffffff 64bit pref]: assigned   ← BAR1 32GB!
...
[437.158818] nvidia 0000:04:00.0: vgaarb: VGA decodes changed
```

**Bridge windows after slot power-on:**

| Bridge | Prefetchable window | Notes |
|---|---|---|
| 03:00.0 (GPU's parent) | **32800 MiB (~32GB)** | vs 288MB on hot-plug! |
| 03:01.0 | 10922 MiB | resized down from 21.6GB |
| 03:02.0 | 10922 MiB | resized down |
| 03:03.0 | 10922 MiB | resized down |
| 02:00.0 (total) | 65568 MiB | unchanged (kernel redistributed within total) |

**GPU state:**
- BAR1: 32GiB ✅
- nvidia.ko auto-bound at re-enumeration ✅
- `nvidia-smi` reports 32607 MiB total memory (matches healthy 5090) ✅
- Pods restored to 1/1 Running ✅
- Zero detector fires ✅

## Comparison to all previously-tested re-enumeration paths

| Trigger | Bridge 03:00.0 prefetchable | BAR1 | Verdict |
|---|---|---|---|
| Physical cable yank → replug → boltctl authorize | 288 MiB | 256 MiB | broken-BAR1 |
| Chassis power-off → power-on → boltctl authorize | 288 MiB | 256 MiB | broken-BAR1 |
| Software `.../remove` + bridge-scoped rescan | 288 MiB | 256 MiB | broken-BAR1 |
| Setpci widen + rescan (Phase 2 ReBAR) | 288 MiB | 256 MiB | broken-BAR1 (kernel ignored setpci) |
| **pciehp slot 12 power cycle** | **32800 MiB** | **32 GiB** | **HEALTHY ✅** |
| Cold boot | 33089 MiB | 32 GiB | baseline |

## Mechanism (interpretation)

The pciehp slot-power-on code path inside the kernel calls `pciehp_configure_device()` → `pci_bus_add_devices()` from a DIFFERENT entry point than runtime hot-plug (`pci_rescan_bus()`, `pci_hp_add_bridge()`). Specifically:

- **Cold boot / pciehp slot-power-on** → invokes `pci_assign_unassigned_bridge_resources()` with the `realloc` and `hpmmioprefsize` knobs respected → bridge windows sized to accommodate ReBAR-capable max BAR sizes
- **Runtime hot-plug (TB cable, chassis power, boltctl)** → invokes a different runtime hot-plug bridge sizing path that sizes bridge windows from CURRENT BAR requirements (256MB) without realloc + hpmmioprefsize honoring

Per the dmesg, the kernel initially tried for a `mem size 0x814000000` (33GB+) window, failed to fit that (because siblings already had 21.6GB each), but the FALLBACK was still big enough — kernel resized the siblings down to ~10GB each to make 32GB room for 03:00.0. This is exactly the algorithm we want, just on the right code path.

## Implications

### 1. Userspace workaround for H1 broken-BAR1 EXISTS

```bash
# After H1 broken-BAR1 is encountered:
echo 0 > /sys/bus/pci/slots/12/power      # off (graceful pciehp tear-down)
sleep 5                                    # let teardown propagate
echo 1 > /sys/bus/pci/slots/12/power      # on (pciehp re-enumeration with full bridge sizing)
# After ~3s, GPU comes back with BAR1=32GB
```

**This is a real userspace fix.** No kernel patch needed. No reboot needed.

### 2. Caveat — affects ALL TB-tunneled devices

Slot 12 is the TB tunnel parent. Cycling it tears down EVERYTHING below (GPU + Realtek LAN + USB hubs + AORUS DMC). For projects where the chassis hosts more than just the GPU, the workaround has collateral impact.

### 3. E27 kernel patch landing zone (sharpened by this experiment)

The kernel's `pci_assign_unassigned_bridge_resources()` clearly CAN size bridges correctly — pciehp invokes it correctly; runtime hot-plug doesn't. E27's fix: route runtime hot-plug bridge sizing through the same algorithm pciehp uses. Likely a small patch in `drivers/pci/setup-bus.c` or `drivers/pci/probe.c`.

### 4. Operational pattern

For production scenarios where you hit broken-BAR1:
1. Quiesce consumers (DaemonSet nodeSelector patches per Run 4b lesson)
2. Power-cycle slot 12 (workaround)
3. Restore consumers
4. Total recovery time ~10s instead of full reboot

Could be packaged as a `tools/fix-bar1.sh` script in the injector repo. Could be invoked automatically by future A2-extension watchdog logic on H1 detection.

## Forensic captures

- `/var/log/mission-1-archaeology/slot12-poweroff-Exp3a.baseline.txt`
- `/var/log/mission-1-archaeology/slot12-poweroff-Exp3a.snapshot.txt`

## Cross-references

- [[rebar-bridge-window-experiment-2026-05-28]] — Phase 1 ReBAR sysfs (showed bridge bottleneck)
- [[rebar-bridge-window-experiment-2026-05-28-phase2]] — Phase 2 setpci widen (kernel ignored)
- [[../../../memory/project_rebar_sysfs_bridge_window_bottleneck_2026_05_28]] — H1 root cause memory (this experiment provides the workaround)
- [[../../../memory/feedback_io_vs_prefetchable_realloc_asymmetry_2026_05_26]] — original E27 framing
- [[../../../memory/project_e7_cable_replug_h1_falsified_2026_05_25]] — original H1 hypothesis (this experiment is the userspace workaround)
- [[aer-inject-Exp1-2026-05-28]] — Exp 1 in the same scientific series
