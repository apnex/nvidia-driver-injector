# Runtime ReBAR Phase 2 — setpci + rescan attempt to widen bridge: kernel ignores hardware widening

**Date:** 2026-05-28 09:41 UTC (immediate follow-on to Phase 1 ReBAR experiment)
**Status:** EXPERIMENT COMPLETE — definitive confirmation that userspace cannot fix H1

## Hypothesis tested

If we widen bridge 03:00.0's prefetchable window in hardware via setpci, then trigger a PCI rescan, does the kernel honor the widened bridge config (allowing BAR1 to expand) or revert it during its resource assignment?

## Procedure

Starting state from Phase 1 — broken-BAR1 (256MB), consumers quiesced, nvidia unbound, GPU sitting at 04:00.0.

### Step 1 — capture baseline bridge config

```
# bridge 03:00.0 (GPU's parent — bottleneck)
setpci -s 03:00.0 0x24.w 0x26.w 0x28.l 0x2c.l
0001 / 11f1 / 00000040 / 00000040
  → window: 0x4000000000-0x4011ffffff (288MB)

# bridge 03:01.0 (empty sibling — hot-plug slot, no devices)
setpci -s 03:01.0 0x24.w 0x26.w 0x28.l 0x2c.l
1201 / 6741 / 00000040 / 00000045
  → window: 0x4012000000-0x45674fffff (21.6GB)
```

### Step 2 — remove GPU + empty sibling 03:01.0

```bash
echo 1 > /sys/bus/pci/devices/0000:04:00.0/remove
sudo setpci -s 03:01.0 0x24.w=0xfff1 0x26.w=0x0001 0x2c.l=0x00000000
# → base > limit; window disabled. 21.6GB now available in parent 02:00.0
```

### Step 3 — widen 03:00.0 to 32GB

```bash
sudo setpci -s 03:00.0 0x24.w=0x0001 0x26.w=0xfff1 0x28.l=0x00000040 0x2c.l=0x00000047
# → new window: 0x4000000000-0x47ffffffff (32GB)
# Re-read after write: 0001 / fff1 / 00000040 / 00000047 ← writes stuck
```

### Step 4 — trigger rescan

```bash
echo 1 > /sys/bus/pci/devices/0000:03:00.0/rescan
```

## Observed result

**The kernel ignored our hardware widening.**

```
[ 1969.127619] pcieport 0000:03:00.0: bridge window [mem size 0x22000000 64bit pref]: can't assign; no space
[ 1969.127620] pcieport 0000:03:00.0: bridge window [mem size 0x22000000 64bit pref]: failed to assign
[ 1969.127622] pci 0000:04:00.0: BAR 1 [mem size 0x20000000 64bit pref]: can't assign; no space
[ 1969.127623] pci 0000:04:00.0: BAR 3 [mem size 0x02000000 64bit pref]: can't assign; no space
[ 1969.127679] pci 0000:04:00.0: BAR 3 [mem 0x4010000000-0x4011ffffff 64bit pref]: old value restored
[ 1969.127693] pci 0000:04:00.0: BAR 1 [mem 0x4000000000-0x400fffffff 64bit pref]: old value restored
```

Notable observations:

1. **`pci=realloc=on` IS being honored on rescan** — the kernel asked for a 544MB bridge window (0x22000000) which is BAR1 sized to next-up (512MB) + BAR3 (32MB). This is the realloc-on path attempting headroom.

2. **The kernel's resource tree is the authoritative source for allocation** — even though hardware config space had a 32GB window, the kernel's internal `struct resource` tree for bridge 03:00.0 still said 288MB. Allocation decisions consulted the tree, not hardware.

3. **The "old value restored" rollback** — when the realloc-on attempt failed, the kernel restored the pre-rescan BAR allocations. BAR1 stayed at 256MB, BAR3 at 32MB.

4. **Surprisingly, the kernel did NOT overwrite our setpci writes to bridge config space** — after rescan, the hardware still had 32GB window written. But that doesn't help because the kernel's tree wasn't updated.

5. **lspci -v shows the kernel's view, not hardware config** — `Prefetchable memory behind bridge: 4000000000-4011ffffff [size=288M]` was reported despite the hardware actually having 32GB written.

## Definitive conclusion

The hypothesis is **falsified for userspace workaround**:

- ✅ The chip supports 32GB BAR1 (ReBAR cap is fine)
- ✅ Bridge config space CAN be widened from userspace via setpci
- ✅ Setpci writes persist (kernel doesn't immediately overwrite)
- ❌ Kernel's resource tree is **not updated** by config space writes
- ❌ Allocation decisions consult the tree, not hardware
- ❌ Rescan from a specific bridge doesn't recompute upstream resource trees
- ❌ Result: BAR1 stuck at 256MB regardless of hardware widening

**There is no userspace workaround for H1 broken-BAR1.** The fix must be in the kernel.

## Implications for E27

E27 must modify the kernel's `__assign_resources_sorted` (or `pci_assign_unassigned_bridge_resources`) on the hot-plug code path so that bridge windows are sized to accommodate downstream BARs' ReBAR-capable max sizes given upstream room is available. Two specific approaches:

### Approach A (cmdline-respect, minimal patch)

The `pci=hpmmioprefsize=32G` cmdline param IS honored at cold-boot enumeration. Make it ALSO honored on the hot-plug code path. This is likely the smallest patch — find the cold-boot code path that consumes `hpmmioprefsize` and ensure the hot-plug code path also does.

### Approach B (downstream-aware, larger patch)

When sizing a bridge on hot-plug, query `pci_rebar_get_possible_sizes()` on downstream devices to compute the upper bound of what they could need, and size the bridge accordingly given upstream room.

Either approach removes the hot-plug-specific limitation. Approach A is the minimal change; Approach B is more general.

## State after experiment

- Both bridge configs restored to baseline (verified by re-read)
- GPU re-enumerated at 256MB BAR1 (the broken-BAR1 state)
- Host fully responsive
- nvidia.ko bound to GPU (was rebound by rescan)
- DaemonSets remain quiesced (nodeSelector patches still in place)

Recovery: reboot for cold-plug to restore BAR1=32GB; then `kubectl patch ds ... --type=json -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'` to restore consumers.

## Cross-references

- [[rebar-bridge-window-experiment-2026-05-28]] — Phase 1 (just ReBAR sysfs alone; ENOSPC)
- [[../../../memory/project_rebar_sysfs_bridge_window_bottleneck_2026_05_28]] — bottleneck characterization
- [[../../../memory/feedback_io_vs_prefetchable_realloc_asymmetry_2026_05_26]] — original E27 framing (now sharpened: it's not asymmetry in realloc, it's the tree-vs-hardware split)
- [[../../../memory/project_e7_cable_replug_h1_falsified_2026_05_25]] — original H1 hypothesis
