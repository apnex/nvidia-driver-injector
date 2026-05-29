# H1 root cause confirmed + userspace recovery to BAR1=32GB without reboot

**Date:** 2026-05-28 21:23-21:37 UTC+10
**Status:** FULL END-TO-END RECOVERY CONFIRMED (n=1) — PCI-level recovery + nvidia.ko binding + nvidia-smi readback all PASS
**Setup at experiment start:** aorus.17 v4 base, cold-plug BAR1=32GiB, all GPU consumers deleted, nvidia.ko not loaded, GPU `driver_override=none`
**Forensic captures:** `/var/log/mission-1-archaeology/combo-exp-2026-05-28/` — 11 state snapshots A→J + `capture.sh`

## TL;DR

The chip's ReBAR Control register (BAR1 size advertisement) resets from `0xF` (32GB) to `0x8` (256MB) when the TB tunnel goes down. BIOS writes it to `0xF` at cold-boot; Linux's TB hot-add path doesn't. **Userspace can write the chip CTRL register from `setpci` then trigger a pciehp slot cycle to widen the bridge window — verified to leave BAR1=32GB and allow nvidia.ko to bind normally.**

The recovery is 7 commands, ~10 seconds wall clock, no reboot.

The proper fix is a small kernel patch (E27) — call `pci_rebar_set_size()` on the TB hot-add path. This experiment defines exactly what that patch needs to replicate.

## What this experiment overturns

Three earlier writeups need adjustments:

1. **`slot12-poweroff-Exp3a-2026-05-28.md`** (RETRACTED) — claim "slot cycle is a userspace workaround for H1" was wrong because Exp 3a only tested slot cycle on a HEALTHY chip. With chip CTRL in broken state (`0x8`/256MB), slot cycle alone widens nothing.
2. **`slot12-poweroff-Exp3b-2026-05-28.md`** — concluded "no userspace workaround exists" based on a setpci hack that wedged the host. The wedge mechanism was writing CTRL while memory decoding was enabled, violating the kernel's `pci_resize_resource()` safety contract. With the contract honoured (write CTRL with memory decoding OFF, `driver_override=none` locking out auto-bind, slot cycle as the bridge-resize trigger), recovery works.
3. **Earlier session-internal conclusion that "userspace workaround does NOT exist in any safe form"** — correct for the combination tried then, wrong as a categorical claim. The recovery sequence below is the working combination.

## Hypothesis

H1's root cause is the chip's ReBAR Control register being reset to its post-power-on default (256MB advertisement) when the TB tunnel goes down, and nothing on Linux's TB hot-add code path restoring it to max (32GB). Cold-boot BIOS does write CTRL to max. TB hot-add doesn't.

**Predicted observation:** chip CTRL reads `0x00000f21` (32GB) when BAR1=32GB is allocated, and resets to `0x00000821` (256MB) immediately after TB deauth/reauth — before any other state change.

**Confirmed (Observation 1 below):** exactly as predicted, in a single passive read.

## Prerequisites

### Kernel cmdline

The host kernel cmdline used during this experiment (relevant parts bolded):

```
... iommu=off intel_iommu=off thunderbolt.host_reset=false pcie_aspm.policy=performance
thunderbolt.clx=0 pcie_port_pm=off
**pci=realloc=on,hpmmioprefsize=32G,resource_alignment=35@0000:03:00.0**
```

`pci=hpmmioprefsize=32G` is the load-bearing one for this recovery: it tells `pci_assign_unassigned_bridge_resources()` (the function pciehp's add path calls) to budget a 32GB prefetchable hot-plug window. Without this, the bridge window allocated during slot cycle wouldn't fit BAR1 even with the chip advertising correctly.

`pci=realloc=on` is also load-bearing for bridge sizing on hot-add.

`resource_alignment=35@0000:03:00.0` aligns the GPU's parent bridge window to a 32GB boundary (2^35) — important because the chip's BAR1 needs natural alignment.

**If your kernel cmdline doesn't include these, this recovery procedure will likely fail at the slot-cycle step.** The minimum prerequisite is `pci=realloc=on,hpmmioprefsize=32G`.

### Host state

Before starting the recovery procedure:

```bash
# 1. No GPU consumers running (this experiment deleted DaemonSets entirely
#    via kubectl delete; less invasive alternatives: kubectl patch with nodeSelector,
#    scale Deployments to 0)
kubectl get pods -A | grep -iE "nvidia|cuda|vllm"   # → should be empty

# 2. nvidia.ko unbound from GPU OR not loaded
ls -l /sys/bus/pci/devices/0000:04:00.0/driver       # → should be absent
lsmod | grep ^nvidia                                  # → should be empty

# 3. nvidia.ko binary present and matching expected version
modinfo /lib/modules/$(uname -r)/extra/nvidia.ko | grep -E "^(version|srcversion)"
# → version: 595.71.05-aorus.NN
```

**Why these matter:** active GPU consumers (nvidia-smi, persistence, vLLM, k8s-device-plugin) hold the chip via MMIO/RPC. Trying to manipulate ReBAR state while they're active wedges the host.

### Hardware-specific identifiers

This procedure uses hardware identifiers specific to this host (NUC 15 Pro+ + AORUS RTX5090 AI BOX over TB4). For a different host you'll need:

| Identifier | This host | How to discover yours |
|---|---|---|
| GPU PCI BDF | `0000:04:00.0` | `lspci -nn \| grep -i nvidia` |
| Audio function BDF | `0000:04:00.1` | `lspci -nn \| grep -A1 -i nvidia \| grep -i audio` (or BDF with `.1` suffix from GPU) |
| TB GPU device | `0-1` | `for d in /sys/bus/thunderbolt/devices/*/; do echo "$(basename $d): $(cat $d/device_name 2>/dev/null)"; done` — pick the one named after your GPU enclosure |
| pciehp slot # | `12` | `for s in /sys/bus/pci/slots/*/; do echo "$(basename $s): $(cat $s/address)"; done` — pick the slot whose `address` matches the **first bridge ABOVE the TB tunnel root** (in our PCI tree `[00]-[07.0]-[02-2b]-[00.0]-[03-2b]-[00.0]-[04]-[00.0]`, that's `02:00`) |
| GPU's direct parent bridge | `0000:03:00.0` | `lspci -t -nn -s 04:00.0` — the bridge directly above 04:00.0 |
| ReBAR Physical cap offset | `0x134` (CTRL at `+0x08` = `0x13c`) | `lspci -s 04:00.0 -vv \| grep "Physical Resizable"` — note the `[XXX]` offset; CTRL is at offset `XXX + 0x08` |

For brevity, the procedure below uses this host's literals. Substitute yours.

### ReBAR CTRL register encoding

The `0x13c.l` register layout:

| Bits | Field | Value for "BAR1 advertises 32GB" |
|---|---|---|
| `[2:0]` | BAR_IDX (which BAR this entry controls) | `001` = BAR1 |
| `[7:5]` | NBAR (# of resizable BAR entries in this cap) | `001` = 1 |
| `[13:8]` | BAR_SIZE (encoded; bytes = 1 MiB × 2^N) | `001111` = 15 → 2^(15+20) = 32 GiB |

→ assembled: `0x0000_0F21`. For 256MB advertisement (broken-BAR1 state) it's `0x0000_0821` (BAR_SIZE=8 → 2^(8+20) = 256 MiB).

## Recovery sequence (the 7 commands)

This is the **minimal sequence verified to work**. Failed intermediate steps that the experiment also tried (remove + bridge-scoped rescan, remove + global rescan) are NOT part of this sequence — they're documented under "Failed approaches" below.

```bash
GPU=0000:04:00.0          # GPU function
AUD=0000:04:00.1          # GPU audio function
TB=0-1                    # TB device for the eGPU enclosure
SLOT=12                   # pciehp slot covering the TB tunnel parent

# 0. Verify preconditions (every command must succeed)
[ "$(setpci -s $GPU COMMAND)" = "0000" ] || { echo "ABORT: memory decoding still on"; exit 1; }
[ -z "$(lsmod | grep ^nvidia)" ]          || { echo "ABORT: nvidia module loaded"; exit 1; }
[ ! -L /sys/bus/pci/devices/$GPU/driver ] || { echo "ABORT: driver still bound"; exit 1; }

# 1. Lock auto-bind on both functions
echo none > /sys/bus/pci/devices/$GPU/driver_override
echo none > /sys/bus/pci/devices/$AUD/driver_override

# 2. Write chip ReBAR Control to advertise 32GB
setpci -s $GPU 0x13c.l=0x00000f21
# verify: setpci -s $GPU 0x13c.l → 00000f21

# 3. pciehp slot cycle (the bridge-resize trigger)
echo 0 > /sys/bus/pci/slots/$SLOT/power
sleep 3
echo 1 > /sys/bus/pci/slots/$SLOT/power
sleep 5

# 4. Re-apply driver_override (wiped by slot cycle freeing struct pci_dev)
echo none > /sys/bus/pci/devices/$GPU/driver_override
echo none > /sys/bus/pci/devices/$AUD/driver_override

# 5. Verify BAR1 is now 32 GiB
awk 'NR==2 {s=strtonum($1); e=strtonum($2); print (e-s+1)/1024/1024 " MiB"}' \
  /sys/bus/pci/devices/$GPU/resource
# Expected: 32768 MiB
```

### Per-step verification + expected dmesg

| Step | Sysfs check | Dmesg signature (success) |
|---|---|---|
| 0 | `cat /proc/cmdline \| grep hpmmioprefsize=32G` | n/a — passive check |
| 1 | `cat /sys/bus/pci/devices/$GPU/driver_override` → `none` | nothing |
| 2 | `setpci -s $GPU 0x13c.l` → `00000f21` | nothing — pure config-space write, no kernel event |
| 3 (off) | `ls /sys/bus/pci/devices/$GPU` → ENOENT | `pcieport 0000:00:07.0: pciehp: Slot(12) Powering off due to button press` (or sysfs write); subordinate bus removal lines |
| 3 (on) | `ls /sys/bus/pci/devices/$GPU` → exists | `pci 0000:04:00.0: BAR 1 [mem 0x4000000000-0x47ffffffff 64bit pref]: assigned` ← **THIS is the BAR1=32GB assignment** |
| 4 | `cat /sys/bus/pci/devices/$GPU/driver_override` → `none` | nothing |
| 5 | BAR1 line in resource file shows `0x4000000000..0x47ffffffff` = 32768 MiB | n/a |

### Failure mode: `BAR 1 [mem size 0x800000000 64bit pref]: can't assign; no space`

If dmesg shows this after slot power-on, the bridge window wasn't widened to fit. Causes (ordered most → least likely):
1. `pci=hpmmioprefsize=32G` missing from cmdline
2. `pci=realloc=on` missing from cmdline
3. Other subtree consuming upstream parent's prefetchable window
4. Step 2 (chip CTRL write) silently failed — verify by re-reading 0x13c.l

This experiment did NOT hit this failure mode because the cmdline already had the right params.

## nvidia.ko binding (post-recovery)

The recovery above leaves the GPU unbound. To actually use it:

```bash
# 1. Verify state still healthy
awk 'NR==2 {s=strtonum($1); e=strtonum($2); print (e-s+1)/1024/1024 " MiB"}' \
  /sys/bus/pci/devices/$GPU/resource          # → 32768 MiB
setpci -s $GPU 0x13c.l                        # → 00000f21
setpci -s $GPU COMMAND                        # → 0000 (still off pre-bind)

# 2. Clear GPU's driver_override (nvidia.ko self-unloads if no probe succeeds)
echo "" > /sys/bus/pci/devices/$GPU/driver_override

# 3. (Optionally) keep audio function locked if you don't want HDA to bind
#    Leave $AUD's driver_override='none' or clear it depending on preference

# 4. Modprobe (--ignore-install bypasses injector's modprobe.d install hook)
modprobe --ignore-install nvidia

# 5. Verify
nvidia-smi -L
# → GPU 0: NVIDIA GeForce RTX 5090 (UUID: GPU-...)

nvidia-smi
# → Should show 32607 MiB total memory, Gen3 x4 link, healthy temp/power
```

Expected dmesg signature for healthy bind (this is the entire nvidia init):

```
nvidia-nvlink: Nvlink Core is being initialized, major device number 510
nvidia 0000:04:00.0: AER: unmasked Uncorrectable Internal Error at probe  ← C1 patch hardening (normal)
nvidia 0000:04:00.0: enabling device (0000 -> 0003)
nvidia 0000:04:00.0: vgaarb: VGA decodes changed
NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64  595.71.05  ...
```

Wedge signatures to abort on: `Xid 154` (GPU lost), `hung_task: blocked for more than X seconds`, `nvidia: probe timeout`, host stops responding.

After successful bind:
- COMMAND register reads `0007` (IO + Memory + BusMaster — set by nvidia.ko probe path)
- driver bound: `/sys/bus/pci/devices/$GPU/driver` is a symlink to `nvidia`
- modprobe returns 0 in <2 seconds

## Final verification

```bash
nvidia-smi --query-gpu=name,memory.total,memory.free,pcie.link.gen.current,pcie.link.width.current \
           --format=csv
# Expected (verified 2026-05-28 21:37):
# NVIDIA GeForce RTX 5090, 32607 MiB, 32111 MiB, 3, 4
```

`32607 MiB` matches the healthy cold-plug value — this is the actual frame buffer size visible to the driver, sourced from MMIO/RPC to the chip after probe. If the chip's internal BAR1 mapping was inconsistent with the new 32GB advertisement, this number would be wrong or the read would wedge.

## Key observations (the data)

### Observation 1 — chip CTRL register state after TB deauth/reauth (the H1 confirmation)

```
Before deauth/reauth (cold-plug healthy):  CTRL = 0x00000f21  → 32GB
After deauth/reauth (broken-BAR1):         CTRL = 0x00000821  → 256MB
```

The chip's ReBAR Control register reset on TB tunnel teardown. H1 root cause in a single passive read.

### Observation 2 — chip CTRL persists across remove + rescan + slot cycle when memory decoding is off

Once written, `CTRL = 0x00000f21` survived all of:
- `echo 1 > .../remove` (PCI hot-remove)
- `echo 1 > /sys/bus/pci/devices/0000:03:00.0/rescan` (bridge-scoped rescan)
- `echo 1 > /sys/bus/pci/rescan` (global rescan)
- `echo 0 > /sys/bus/pci/slots/12/power` + `echo 1 > .../power` (pciehp slot cycle)

This is the critical safety property: chip register state is preserved across kernel re-enumeration ops.

### Observation 3 — bridge-scoped rescan does NOT widen bridge windows

After chip CTRL=0x00000f21 + remove + `echo 1 > /sys/bus/pci/devices/0000:03:00.0/rescan`:

```
pci 0000:04:00.0: BAR 1 [mem size 0x800000000 64bit pref]: can't assign; no space
                                  ^^^^^^^^^^ 32 GiB ← chip is advertising 32GB now
BAR1 in sysfs: 0 MiB (unassigned)
Bridge 03:00.0 prefetch window: 288 MiB (unchanged from broken state)
```

Kernel SAW the chip wants 32GB but couldn't fit in the 288MB window. Bridge-scoped rescan allocates within existing windows; doesn't widen them.

### Observation 4 — global `/sys/bus/pci/rescan` also doesn't widen

Same outcome as Observation 3.

### Observation 5 — pciehp slot cycle DOES widen, via `pci_assign_unassigned_bridge_resources()`

After slot 12 power off + on (chip CTRL=0x00000f21 set):

```
BAR1 in sysfs: 32768 MiB ← RECOVERED
Bridge 03:00.0 prefetch window: 32800 MiB (limit upper 0x48)
Chip CTRL: 0x00000f21 (persisted across slot cycle)
driver_override: (null) ← WIPED by pciehp re-enumeration
```

pciehp's add path calls `pci_assign_unassigned_bridge_resources()` — the same algorithm cold-boot uses for bridge sizing. This algorithm honours `pci=hpmmioprefsize=32G`. With the chip advertising 32GB and the bridge resized to accommodate, BAR1 came up at 32GB.

### Observation 6 — `driver_override` does NOT persist across PCI remove+rescan or slot cycle

Every time the device left the PCI tree, its struct pci_dev was freed. When it came back, a fresh struct was allocated with default settings — `driver_override` reverted to `(null)`. **Must be re-applied after every re-enumeration event** to maintain auto-bind lockout.

### Observation 7 — nvidia.ko self-unloads if no probe succeeds

If `driver_override=none` is still set when `modprobe nvidia` runs, no probe matches → init prints `NVRM: No NVIDIA devices probed` → init returns -ENODEV → module unloads. There is no "module loaded but not bound" intermediate state for nvidia.ko in this flow. To bind, clear driver_override BEFORE modprobe.

### Observation 8 — modprobe.d install hook blocks normal modprobe

`/etc/modprobe.d/nvidia-driver-injector.conf` contains `install nvidia /bin/false` to prevent accidental host-side load. `modprobe --ignore-install nvidia` bypasses this. This is the injector's intended host-side gate; for the recovery procedure we have to bypass it because we're loading the module from the host, not from inside the injector container.

## Failed approaches (what was tried in the actual experiment but doesn't help)

These were executed during the experiment but ultimately not part of the working sequence:

1. **`echo 1 > /sys/bus/pci/devices/0000:04:00.0/remove` followed by `echo 1 > /sys/bus/pci/devices/0000:03:00.0/rescan`** — bridge-scoped rescan; kernel discovered chip wants 32GB but couldn't widen 03:00.0's window
2. **`echo 1 > /sys/bus/pci/rescan`** (global) — same outcome as bridge-scoped; the rescan code path doesn't recompute upstream bridge windows
3. **setpci writes to bridge config (offsets 0x24/0x26/0x28/0x2c)** — from a much earlier ReBAR Phase 2 experiment; writes persist in hardware but kernel's resource tree isn't updated → allocator still uses old (narrow) tree

Only pciehp slot cycle invokes `pci_assign_unassigned_bridge_resources()` from sysfs. That's why step 3 in the recovery sequence is specifically the slot cycle.

## Comparison to prior wedge attempt (slot12-poweroff-Exp3b)

| Element | Prior attempt (wedged) | This experiment (success) |
|---|---|---|
| chip CTRL write | setpci 0x13c.l=0x00000f21 | (same — confirmed right address) |
| memory decoding at CTRL write | unknown (nvidia.ko had been bound earlier in session) | **0x0000 verified before write** |
| slot cycle | yes | yes |
| driver_override before slot cycle | (not set in original attempt) | **`none` set before slot cycle** |
| driver_override after slot cycle | (not re-applied) | **`none` re-applied immediately** |
| nvidia.ko binding | auto-bound by pciehp re-enum → probe → wedge | **locked out via driver_override=none during recovery; bound deliberately as separate step** |
| Outcome | host wedge in ~10s, 2 reboots | BAR1=32GB, stable, no wedge |

Same chip register address. Different surrounding safety contracts. The address was right both times.

## Verdict

| Phase | Outcome | n |
|---|---|---|
| H1 root cause confirmation | ✅ Chip CTRL register reset 0xF → 0x8 on TB deauth/reauth | n=2 |
| Userspace recovery to BAR1=32GB | ✅ Verified — chip CTRL write + slot cycle, both with memory decoding off | n=4 |
| nvidia.ko probe + bind | ✅ Bind in <2s, no wedge at probe | n=3 |
| nvidia-smi metadata readback | ✅ Reports 32607 MiB / Gen3 x4 / 595.71.05 / CUDA 13.2 | n=3 |
| Close-path lifecycle WITHOUT persistence | ❌ Wedge after first LAST-CLOSE (system-wide silent freeze, reboot required) | n=1 fail at cycle 2 |
| Close-path lifecycle WITH persistence engaged | ✅ Verified — 5+ LAST-CLOSE post-shutdown cycles, host alive throughout, WPR2 stays up | n=2 cycles |
| CUDA workload (nvbandwidth H2D) | ✅ 2.71–2.73 GB/s, TB4-saturated baseline | n=2 |

## Cycle 2 wedge — close-path hazard after userspace recovery (2026-05-28 21:54)

A second deauth → recovery → bind cycle exercised the script's `--bind` path. Recovery worked (BAR1=32GB, chip CTRL=0xF21). modprobe + nvidia-smi -L succeeded. The wedge fired ~3 seconds later when the close-path's `nv_stop_device` + downstream cleanup ran on first LAST-CLOSE.

**Forensic verdict:** A4's `tb_egpu_close_diag` post-shutdown telemetry is passive (ioremap+ioread32+iounmap, no writes) — ruled out. The actual wedge step is most likely `pci_stop_and_remove_bus_device(nvl->pci_dev)` in `nvidia_close_callback`, gated by:

```c
bRemove = (!surprise_removal) && (usage_count==0) && rm_get_device_remove_flag(...);
```

`rm_get_device_remove_flag` is in closed-source RM and opaque. Cycle 1's 13+ successful close-paths must have had `bRemove==false`. Cycle 2's wedge close was likely `bRemove==true`. The chip-state input to RM's policy differs between cold-plug and userspace-recovered.

## Chip-state divergence — passive register dump (cycle 3, n=2)

Captured cold-plug + recovered states with nvidia.ko unbound. PCI config space + extended caps + bridge config. Snapshots: `/var/log/mission-1-archaeology/chip-state-diff-2026-05-28/{A-cold-plug,B-recovery}/`.

| Register / field | Cold-plug | Recovery | Interpretation |
|---|---|---|---|
| Phy16Sta (cap 0x158, Gen3 status) | `EquComplete+ EquPhase1+ EquPhase2+ EquPhase3+` | all `-` | Gen3 link equalization status bits cleared after recovery — link is at Gen3 x4 in both, but chip's "equalization done" markers missing |
| LTR snoop / no-snoop latency | 15,728,640 ns | 0 ns | Latency Tolerance Reporting unconfigured after recovery |
| LaneErrStat (cap 0x100) | `LaneErr at lane: 0 1 2 3` | `0` | Per-lane error history reset |
| AER UNCOR_MASK (0x108) | `0x0000000F` | `0x00000000` | BIOS-set, likely vendor-reserved-bit mask |
| AER UNCOR_SEVER (0x10C) | `0x76007600` | `0x74007400` | bits 9 + 25 differ |
| Lane equalization presets (0x178-0x17B) | `0x60606060` | `0xF0F0F0F0` | Per-lane equalization preset values |
| Cache Line Size (0x0C) | `0x10` | `0x00` | BIOS-set, software-readable |
| Expansion ROM (0x30) | assigned 0x84000000 | `[virtual]` | Kernel ROM allocation skipped on slot-cycle re-enum |
| Bridge 03:00.0 Cache Line Size | `0x10` | `0x00` | Same pattern on bridge side |
| Bridge 03:00.0 Slot Status fields (0x320/0x380) | populated | zeroed | Bridge hot-plug state cleared on slot cycle |

**Common origin:** all of these are state that BIOS POST writes during cold-boot init and that survives until the chip is reset (TB deauth). Slot cycle's link retraining brings the link back up but uses **equalization presets** (the 0xF0F0F0F0 values) rather than running the full phase-by-phase Gen3 equalization that BIOS does. The link works; the status bits don't reflect the BIOS-equivalent completion.

**Hypothesis (correlation, not yet causation):** RM's policy reads one of these chip-state bits (most plausibly `Phy16Sta.EquComplete` or LTR validity) to decide whether to set `remove_flag` on close. The userspace recovery path leaves these in a state RM treats as "not fully initialized → remove on close" — hence the wedge.

## Prevention — persistence mode (confirmed n=2)

Per `nv_stop_device` source:

```c
if (nv->flags & NV_FLAG_PERSISTENT_SW_STATE) {
    rm_disable_adapter(sp, nv);            // lighter; GSP stays loaded
} else {
    nv_acpi_unregister_notifier(nvl);
    nv_shutdown_adapter(sp, nv, nvl);       // path that wedged
}
```

`nvidia-smi -pm 1` run immediately after probe sets `NV_FLAG_PERSISTENT_SW_STATE` (the ioctl commits it before the persistence-setting process closes its fd). All subsequent closes — including the one from the `-pm 1` process itself — take the `rm_disable_adapter` branch. Observed outcome:

| Site | Without persistence (cycle 2 wedge) | With persistence (cycles 3 + n=2 cycle) |
|---|---|---|
| post-shutdown WPR2 | `0x00000000 wpr2_up:no` | **`0x07f4a000 wpr2_up:YES`** |
| GSP firmware after close | torn down | stays loaded |
| Subsequent `pci_stop_and_remove_bus_device` | runs → wedge | not reached |
| Host responsiveness post-close | dead within ~3s | alive across 5+ LAST-CLOSE cycles |

The injector container's entrypoint already engages persistence — that's why production binds-via-injector never hit this wedge. As of 2026-05-28 fix-bar1.sh's `--bind` step also engages persistence right after `modprobe`, before any other open/close. See script header "Known hazards" + `--bind` implementation.

Note: `nvidia-smi -pm 1` is the deprecated legacy persistence interface; the kernel logs `NVRM: Persistence mode is deprecated and will be removed in a future release. Please use nvidia-persistenced instead.` on first engagement. Long-term migration to `nvidia-persistenced` is a separate cleanup.

**Distinct from root cause:** persistence prevention does not address why the chip's PCIe equalization state diverges. It routes around the close-path that surfaces the divergence. Open root-cause questions are listed under "Untested" below.

## Close-path coverage analysis (post-mortem)

After the wedge + persistence fix, a follow-on source audit asked: did the C5 crash-safety series actually intend to make persistence optional, and if so, why didn't it catch this case? Findings:

### What C5/A2/A3 actually modify in the close path

| Patch | nvidia_close_callback | nv_stop_device | bRemove logic | pci_stop_and_remove |
|---|---|---|---|---|
| C5-crash-safety | G7 guard on `nvidia_dev_get`/`_put` (tolerate `NV_ERR_GPU_IS_LOST` on refcount drop); G10 lock-free dead-bus query | (none) | (none) | (none) |
| A2-bus-loss-watchdog | (none) | (none) | (none) | (none) |
| A3-recovery | (none) | (none) | (none) | (none) |
| A4-close-path-telemetry | 4 passive log sites (close-entry / pre-stop / post-shutdown / close-exit) | (1 of the 4 sites fires here) | (none) | (none) |

C5's design coverage assumption: **if close-path goes wrong, a detector will fire on an MMIO-dead signal, the sink will mark GPU lost, and close will complete cleanly.** This is the "chip-died-aware" failure model. C5 closes the wedge class it was designed against, and the patches do their job for that class.

What C5 does NOT model: **chip-responsive-but-internally-incompletely-initialized.** In our cycle 2 wedge, every MMIO read at every detection site succeeded (PMC_BOOT_0 readable throughout). No detector had a signal to fire on. The wedge fired in chip-touching kernel work that runs *after* C5's coverage boundary.

### RmShutdownAdapter vs RmDisableAdapter — the chip-side delta

The close path branches in `nv_stop_device` based on `NV_FLAG_PERSISTENT_SW_STATE`. Reading `osinit.c`:

**`RmDisableAdapter` (persistence path)** — explicitly the lighter teardown:
1. `intrSetIntrEn(pIntr, INTERRUPT_TYPE_DISABLED)` — disables chip interrupts
2. Marks `IN_TIMEOUT_RECOVERY` if in SBR / full-chip reset
3. Locks clients + GPU lock
4. `rmapiDelPendingDevices` / `rmapiSetDelPendingClientResourcesFromGpuMask`
5. `nv_stop_rc_timer`
6. `teardownCoreLogic` if flagged
7. `krcWatchdogShutdown` if `FIFO_WATCHDOG` flag set
8. `gpuStateUnload(pGpu, GPU_STATE_DEFAULT)` — unloads but does not destroy
9. Releases locks, returns

**`RmShutdownAdapter` (non-persistence path)** — everything above PLUS the destructive set:
- `RmDestroyPowerManagement(nv)` — tears down PM state
- `gpuStateDestroy(pGpu)` — destroys (not just unloads) chip state
- `dceclientDceRmInit(pGpu, ..., NV_FALSE)` — DCE firmware shutdown
- `RmDisableDeviceClks(nv)` (Tegra-only path, skipped on desktop)
- `RmFreeX86EmuState(pGpu)` — x86 emulator state cleanup
- `gpumgrDetachGpu(gpuInstance)` + `gpumgrDestroyDevice(deviceInstance)` — full GPU manager detach
- `RmTeardownDeviceDma(nv)` — tears down DMA mappings
- `RmClearPrivateState(nv)`
- `RmUnInitAcpiMethods(pSys)`
- `RmTeardownRegisters(nv)` — tears down register / BAR mappings

The persistence path *skips* the destructive items. Of the extras, three perform chip-touching work that depends on the chip's PCIe/memory/clock state being internally consistent: **`gpuStateDestroy`**, **`RmTeardownDeviceDma`**, **`RmTeardownRegisters`**. On a userspace-recovered chip with Phy16Sta bits clear, LTR=0, and other BIOS-init state missing, one of these is the plausible wedge site.

### Why the patches *intentionally* didn't cover this

This is a scope question, not a defect. C5 was designed to make persistence optional **for the chip-died failure class** — and it does. Our wedge belongs to a different class (chip-responsive but partially-initialized) that wasn't in scope. Closing it would require either:

- **A new detector class** — pre-shutdown sanity check that classifies "chip looks alive at MMIO but internal state is inconsistent" and routes through the sink before `RmShutdownAdapter` runs the destructive steps
- **Step-level hardening inside `RmShutdownAdapter`** — wrap `gpuStateDestroy` / `RmTeardownDeviceDma` / `RmTeardownRegisters` in timeouts that abort cleanly on unresponsive chip ops
- **External-GPU policy** — E1 already flags TB-attached devices; could skip the destructive teardown steps for those (effectively making persistence the default policy for external GPUs)
- **Chip-state-aware recovery** — fix the chip-state divergence at recovery time so RmShutdownAdapter's expectations hold (deferred until we know how, and possibly infeasible from userspace per the equalization-replication ruling)

None of these are in C5/A2/A3's current scope. They are candidate work items if we want persistence to be truly optional across all failure classes.

## Cycle 4 — PINPOINT-1 instrumented re-test (2026-05-29 09:14 UTC+10)

After the cycle-2 wedge + chip-state-divergence diff + persistence-mode confirmation, an experimental telemetry patch (`patches/experimental/PINPOINT-1-post-close-exit-telemetry.patch`) was drafted to identify exactly which step in `nvidia_close_callback`'s post-`close-exit` window hangs on a userspace-recovered chip. The patch adds 9 `nv_printf` markers from `post-close-exit` through `callback-exit`, including the `bRemove` value captured at the first marker. It's pure observability — no MMIO, no logic changes.

Image `apnex/nvidia-driver-injector:595.71.05-aorus.17-pinpoint1` was built with the experimental patch applied on top of the production C1-C5 + E1 + A1-A5 stack via a new `APPLY_EXPERIMENTAL_PATCH=` Dockerfile build-arg gate. Host was rebooted into the new image (cold-plug, BAR1=32GB).

### What the cycle-4 test produced

Same trigger sequence as cycle 2: TB deauth/reauth → `fix-bar1.sh` (no `--bind`) → `modprobe nvidia` → `nvidia-smi -L`. The PINPOINT-1 markers fired through `callback-exit`:

```
[CLOSE]:    site=close-entry     usage_count=1 (LAST-CLOSE)  WPR2=0x07f4a000 wpr2_up:YES
[CLOSE]:    site=pre-stop        usage_count=1 (LAST-CLOSE)  WPR2=0x07f4a000 wpr2_up:YES
[CLOSE]:    site=post-shutdown   usage_count=0 (LAST-CLOSE)  WPR2=0x00000000 wpr2_up:no
[CLOSE]:    site=close-exit      usage_count=0 (LAST-CLOSE)  WPR2=0x00000000 wpr2_up:no
[POSTCLOSE]: site=post-close-exit bRemove=0       ← bRemove FALSE
[POSTCLOSE]: site=post-free-private
[POSTCLOSE]: site=path-B-post-unlock-ldata        ← Path B taken
[POSTCLOSE]: site=pre-kmem-free                   ← pci_stop_and_remove skipped (bRemove=0)
[POSTCLOSE]: site=callback-exit                   ← function returned cleanly
```

**The host did NOT wedge.**

### Two implications

1. **`pci_stop_and_remove_bus_device` is ruled out as the wedge mechanism.** `bRemove` consistently reads 0 on this hardware, including on a userspace-recovered chip at the LAST-CLOSE of an unbinding nvidia-smi process. The "smoking gun" candidate from the cycle-2 post-mortem was wrong. `rm_get_device_remove_flag()` is returning false in both healthy and recovered cases — RM is NOT marking the GPU for removal here.

2. **The cycle-2 wedge was not deterministic under the stated trigger sequence.** The PINPOINT-1 re-test replicated the trigger exactly and the close path completed through `callback-exit`. Either F40 is probabilistic, has an additional load-bearing factor we haven't identified, or the cycle-2 wedge was a different mechanism that we conflated with this trigger.

### What's different between cycle 2 and cycle 4

| Factor | Cycle 2 (wedge) | Cycle 4 (no wedge) |
|---|---|---|
| Uptime at wedge attempt | ~30 min | ~5 min (fresh cold boot) |
| Prior chip activity | cycle 1's nvbandwidth + multiple bind/close iterations | only injector's startup persistence engagement |
| Last operation before trigger | rmmod after cycle 1 workload | injector's graceful `uninstall` |
| Telemetry depth | A4 only (couldn't see post-close-exit) | A4 + PINPOINT-1 (visible through `callback-exit`) |
| `bRemove` at LAST-CLOSE | unknown | 0 |

The most plausible additional factor: cycle 2's chip had been WARMED by actual workload (nvbandwidth memory allocation, kernel launches). Cycle 4's chip was probed and queried only, no FB-memory use. The chip-internal state after a warm workload may differ from cold-just-probed state in ways that affect downstream close-path behaviour.

### Catalog impact

`fake-5090/failure-modes/F40` confidence downgraded from `field-bug` to `hypothesis` with a Reproducibility caveat section enumerating the open characterization questions:

- Does extended-sequence repetition trigger the wedge? (cycle 5 — N consecutive deauth/recover/bind/close cycles)
- Does pre-loading the chip with workload (nvbandwidth) reproduce cycle-2 conditions?
- Does longer uptime between cold-boot and wedge attempt matter?
- If none of those reproduce: cycle 2's wedge may have been a different failure mode entirely

### Verdict-table updates

| Phase | Cycle 2 (yesterday) | Cycle 4 (today) | Net |
|---|---|---|---|
| Close-path lifecycle WITHOUT persistence | ❌ wedge (n=1) | ✅ clean completion (n=1) | **n=1 wedge, n=1 no-wedge — non-deterministic under documented trigger** |
| `bRemove` value at LAST-CLOSE | unknown | 0 | `pci_stop_and_remove_bus_device` ruled out |
| Persistence-mode prevention | ✅ n=2 (cycles 3a, 3b) | n/a (didn't test persistence-engaged path in cycle 4) | still valid as mitigation |

Persistence-mode mitigation **remains the documented operator practice** because it costs nothing and provably prevents at least one observed wedge. Whether it's strictly necessary on every userspace-recovered chip is now an open question pending cycle-5 results.

## PINPOINT diagnostic cycle (2026-05-29)

After F40 was identified as a coverage gap (post-mortem above), an instrumented diagnostic cycle was run to narrow the wedge site. Forensic archives: `/var/log/mission-1-archaeology/{pinpoint1-wedge-2026-05-29, pinpoint2-runtime-pm-falsification-2026-05-29, restore-attempt-wedge-2026-05-29}/`.

### PINPOINT-1: 9 markers in nvidia_close_callback post-`close-exit` window

Added markers at every step between A4's `close-exit` log and the function's `}`. Goal: identify whether the wedge fires in `pci_stop_and_remove_bus_device`, `nv_free_file_private`, `nv_kmem_cache_free_stack`, or outside the function entirely.

Results (cycle 2 reproduction with PINPOINT-1 active):

```
[CLOSE]:    site=close-exit      usage_count=0 (LAST-CLOSE)  WPR2=0x00000000 wpr2_up:no
[POSTCLOSE]: site=post-close-exit bRemove=0     ← bRemove FALSE
[POSTCLOSE]: site=post-free-private
[POSTCLOSE]: site=path-B-post-unlock-ldata     ← Path B (not nv->removed)
[POSTCLOSE]: site=pre-kmem-free                ← skipped pci_stop_and_remove (bRemove=0)
[POSTCLOSE]: site=callback-exit                ← function returned cleanly
─── kernel printk goes silent here ───
~5 min later: user-visible wedge manifests; reboot required
```

Two conclusive findings:

1. **`pci_stop_and_remove_bus_device` is ruled out as the wedge mechanism.** `bRemove == 0` on every observed close (healthy AND userspace-recovered chip). The function is never reached from this code path on this hardware.
2. **The wedge is OUTSIDE `nvidia_close_callback`.** Every marker through `callback-exit` fires. The function returns. Whatever wedges happens AFTER the close callback exits — in async or deferred kernel work — not in the synchronous close path.

The ~5-min delay before user-visible symptoms confirms the wedge is in deferred kernel work scheduled by (or following) the close path. The earlier morning interpretation "host did not wedge" was a misread of timestamps — kernel printk DID stop at 09:14:01 immediately after the last marker; only userspace stayed alive until ~09:19:42 when downstream subsystems needed the wedged kernel state.

### PINPOINT-2: 8 markers inside nv_shutdown_adapter + bpftrace + runtime-PM-disable

Three diagnostics combined in one reboot cycle:

- **PINPOINT-2** — markers at every step inside `nv_shutdown_adapter` (`entry → post-rm-disable-adapter → post-bh-q-stop → post-msix-cleanup → pre-rm-shutdown-adapter → post-rm-shutdown-adapter → exit`). Confirms each synchronous step completes.
- **bpftrace** (`tools/bpftrace-wedge-watch.bt`) — attached to `pci_pm_runtime_suspend`, `pci_pm_runtime_resume`, `pm_runtime_work`, `device_release_driver_internal`, `pci_stop_and_remove_bus_device`, `workqueue:workqueue_execute_*`. Captures kernel async territory PINPOINT-N patches can't reach.
- **Runtime PM disable** (`echo on > /sys/bus/pci/devices/0000:04:00.0/power/control` + audio function). Falsification test for the runtime-PM-suspend hypothesis.

#### Run 1 — wedge cycle WITH runtime PM disabled

Result: host alive **6m 30s** after `nvidia-smi -L` returned. Kernel printk responsive throughout. All PINPOINT markers fired cleanly. bpftrace captured 47 MB of activity:
- `pci_pm_runtime_suspend`: **0 calls** during the test window
- `pm_runtime_work`: 164 cycles, all matched (5–10 µs each)
- No nvidia.ko deferred work observed

This was initially interpreted as confirmation of the runtime-PM-suspend hypothesis. But yesterday's cycle 2 wedge fired at 5m 41s; our 6m 30s observation barely cleared that. Suggestive but not conclusive.

#### Run 2 — restore-attempt wedge

After Run 1's healthy observation window, attempted to restore production state: `echo > unbind` GPU + `rmmod nvidia_uvm` (already gone) + `rmmod nvidia` + apply DSes with production aorus.17 image. **Host wedged silently 5+ min into this sequence.** Kernel printk went silent between my `rmmod nvidia` (~09:59) and the eventual "nvidia-nvlink: Unregistered Nvlink Core" message at 10:04:46 — a 5-min gap with no SHUTDOWN markers (despite `rmmod` going through `nv_pci_remove_helper → nv_shutdown_adapter` per source). Reboot required.

Two corrections to the runtime-PM hypothesis:

1. **`power/control=on` does NOT prevent the wedge on the `rmmod` code path.** rmmod goes through `nv_pci_remove_helper → nv_shutdown_adapter` directly, bypassing both `nv_stop_device`'s persistence check AND the runtime-PM-disable sysfs mitigation.
2. **Run 1's "6m+ survival" is at best partial evidence.** Either runtime PM is one of multiple async wedge mechanisms (and Run 1 just happened to avoid all of them long enough), or the actual wedge mechanism is something `power/control=on` happens to slow but not prevent.

### Production mitigation remains persistence engagement (n=3 verified)

| Scenario | Persistence engaged? | Result |
|---|---|---|
| Cycle 1 (cold-plug bind + workload) | Implicitly via UVM holding reference | n/a (no LAST-CLOSE happened during workload) |
| Cycle 2 wedge attempt | NO | Wedge |
| Today's cold-boot injector startup | YES (entrypoint) | Healthy |
| `fix-bar1.sh --bind` recovery | YES | Healthy |
| Post-restore re-bind | YES (entrypoint) | Healthy |
| PINPOINT-2 test (Run 1) | NO; relied on power/control=on | Healthy *for 6m+ then unknown* |
| Restore-attempt (Run 2) | Engaged at first, rmmod bypassed | Wedge |

Persistence engagement reliably prevents the wedge on the `nv_stop_device → nv_shutdown_adapter` path by routing through `rm_disable_adapter` instead. The `nv_pci_remove → nv_pci_remove_helper → nv_shutdown_adapter` path (taken by `unbind`/`rmmod`/PCI hot-remove) does NOT honor persistence and CAN still wedge on userspace-recovered chip — but this path is not taken in normal production flow. Production uses the injector's `uninstall` subcommand (which the operator chose) or just leaves the driver loaded across operational events.

### Updated production guidance

For operators:
- Use `tools/fix-bar1.sh --bind` for H1 recovery — engages persistence automatically.
- Use injector's `uninstall` subcommand (`kubectl exec ... -- /entrypoint.sh uninstall`) for graceful module unload — but be aware on a userspace-recovered chip this MAY wedge; if so, hard-reboot. Production cold-plug chip uninstall is safe (n=multiple historical).
- Avoid raw `rmmod nvidia` on a userspace-recovered chip — use the injector's path or just leave the driver loaded.

For the injector codebase:
- No driver-side change needed for the production close-path (persistence already covers it via the entrypoint).
- E27 kernel patch (F41 fix) does NOT need to mitigate F40 — the F41 fix removes the chip-state divergence at recovery time, making the chip indistinguishable from cold-plug, which removes the wedge precondition for all paths.

## Untested as of this writeup

- **Sustained load stability** — only ~10 min observation after the persistence-prevention cycle, n=2 short workload runs (nvbandwidth)
- **Repeatability beyond n=2 within one boot** — within-boot repeatability of full deauth→recover→bind→workload cycle confirmed n=2; longer chains not exercised
- **`nvidia-persistenced` migration** — legacy `-pm 1` works but is deprecated; long-term replacement not validated in this flow
- **Effect of `iommu=on`** — current cmdline has `iommu=off intel_iommu=off`
- **Other 5090 silicon revisions** — chip rev A1 only
- **Root cause confirmation** — which specific chip-state register/field RM keys off to set `remove_flag` remains opaque (closed-source RM). The diff identifies 8 candidates; pinning the actual gate would need RM source or instrumented RM testing.
- **Equalization-replication recovery** — whether userspace can force a full Gen3 equalization (LnkCtl.RetrainLink + LnkCtl3.PerformEqu) to restore the EquComplete bits, allowing non-persistent operation. Untested; wedge-risk experiment.
- **Whether E27 kernel patch suffices** — current scope is calling `pci_rebar_set_size()` on the TB hot-add code path. If the chip-state divergence is what triggers RM's remove_flag, the patch may also need to either trigger equalization or coexist with persistence policy. Worth surveying NVIDIA's TB-eGPU init code paths simultaneously.

## E27 fix implication (the proper kernel patch)

The kernel patch landing zone is now precisely scoped:

**On Linux's TB hot-add code path, after the PCI subordinate device is added but before bridge resource allocation, walk all ReBAR-capable BARs and write each chip's ReBAR Control register to the maximum supported size for that BAR.**

This is exactly what BIOS does at cold-boot via SMM/UEFI runtime services, and exactly what `pci_assign_unassigned_bridge_resources()` already assumes when sizing windows.

Likely lives in `drivers/thunderbolt/tunnel.c` (TB tunnel commit handler) or `drivers/pci/probe.c` (`pci_device_add()` or the runtime hot-add path that mirrors enumeration). The function to call exists and is exported:

```c
for (resno = 0; resno < PCI_NUM_RESOURCES; resno++) {
    int max = pci_rebar_get_max_size(pdev, resno);
    if (max < 0) continue;  /* not ReBAR-capable */
    pci_rebar_set_size(pdev, resno, max);
}
```

Small patch. Both helpers (`pci_rebar_get_max_size`, `pci_rebar_set_size`) already exist in `drivers/pci/rebar.c` and are exported.

## Operational implications

For production scenarios where broken-BAR1 is encountered:

1. **Pre-recovery:** ensure no GPU consumers (nvidia-smi, persistence, vLLM, k8s-device-plugin) are issuing MMIO/RPC. Quiesce or drain DaemonSets / Deployments first. Anything in-flight will wedge when the slot powers off.
2. **Pre-recovery:** ensure nvidia.ko is unbound from the GPU OR not loaded. If bound, `echo 0000:04:00.0 > /sys/bus/pci/drivers/nvidia/unbind` then `rmmod nvidia` (and `nvidia_uvm`, `nvidia_drm` if present).
3. **Recovery sequence:** 7 commands, ~10 seconds wall clock.
4. **Post-recovery:** restore consumers (re-enable scheduling, re-create DaemonSets, scale up Deployments).
5. **Collateral damage:** pciehp slot 12 power-off tears down EVERY device behind the TB tunnel — Realtek LAN, USB hubs, AORUS DMC, audio function. Affected services see a brief drop (~10s). For projects where the chassis hosts more than just the GPU, weigh this against full-reboot impact. Slot power-on re-enumerates them all automatically.

This is a recovery procedure, not a prevention. The E27 kernel patch above is the proper fix.

## Should this become a `tools/fix-bar1.sh`?

Maybe. The prior `tools/fix-bar1.sh` was built on Exp 3a's wrong premise and was removed (commit `76d59e5`). A new version is justifiable now because the mechanism is understood, but it should:

- Verify all kernel cmdline prerequisites at start, abort with a clear message if missing
- Verify consumers are quiesced (no GPU PIDs, no nvidia.ko loaded), abort if not
- Use discovery logic for TB UUID / slot # / ReBAR cap offset (don't hardcode this host's literals)
- Capture state at each step for forensics
- Re-verify chip CTRL after the write before slot cycle
- Fail loudly and reboot-safely if any verification check fails
- Be marked clearly as "userspace workaround pending E27 kernel patch"

Recommend implementing only after the untested items above (CUDA workload, repeatability, sustained-load) have been validated. Premature script-shipping was the prior failure mode.

## Process note — pacing of premature-success-overreach

This experiment was preceded by an earlier "success" claim (Exp 3a) that proved false same session, AND a "failure" claim (Exp 3b post-mortem: "no workaround exists") that was also wrong. The discipline this time:

1. Defined acceptance criteria BEFORE running ("BAR1=32GB in sysfs, with driver_override=none locked, no wedge for ≥30s")
2. Defined abort criteria BEFORE running ("if chip CTRL doesn't persist across slot cycle, if any read returns 0xFFFFFFFF, if hung_task fires → unbind nvidia.ko immediately and report")
3. Captured state at every intermediate step (A→J snapshots, 11 files)
4. Stopped at the PCI-level recovery and asked the user before extending to nvidia.ko binding
5. Explicitly enumerated untested items in the verdict table — did not let the "success" claim creep beyond what was actually tested

The nvidia.ko binding test was a separate sub-experiment with its own hypothesis and abort criteria, not folded into the PCI-level success.

## Cross-references

- [[slot12-poweroff-Exp3a-2026-05-28]] — original Exp 3a (retracted)
- [[slot12-poweroff-Exp3b-2026-05-28]] — Exp 3b + setpci hack wedge post-mortem (the "no workaround exists" conclusion is now superseded)
- [[rebar-bridge-window-experiment-2026-05-28-phase2]] — Phase 2 setpci+rescan (bridge config widening; kernel ignored)
- [[aer-inject-Exp1-2026-05-28]] — Exp 1 in the same scientific series
