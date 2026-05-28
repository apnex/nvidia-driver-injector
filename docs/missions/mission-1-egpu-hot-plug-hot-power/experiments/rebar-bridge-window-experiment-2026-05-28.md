# Runtime ReBAR sysfs experiment — bridge window is the bottleneck

**Date:** 2026-05-28 09:30 UTC
**Status:** EXPERIMENT COMPLETE — decisive characterization of H1 root cause
**Setup:** aorus.17 v4 base, host healthy; chassis powered on with cable connected; GPU not yet authorized.

## Hypothesis tested

Can Linux PCI runtime ReBAR (`/sys/bus/pci/devices/<BDF>/resourceN_resize`) be used to widen BAR1 from broken-BAR1 state (256MB) back to 32GB after a TB hot-plug, as a userspace workaround for the H1 bridge-window-allocation problem?

## Setup discipline

Per [[../../../../.claude/projects/-root/memory/feedback_no_rpc_observability_on_broken_bar1_2026_05_28]] — quiesce ALL consumers BEFORE authorize so no NVML probes hit broken-BAR1:

```bash
# nodeSelector patch terminates DaemonSet pods without deleting manifests
kubectl patch ds -n kube-system nvidia-driver-injector \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"rebar-experiment-quiesced":"true"}}}}}'
kubectl patch ds -n kube-system nvidia-device-plugin-daemonset \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"rebar-experiment-quiesced":"true"}}}}}'
```

Verified clean: no nvidia pods, no nvidia processes, no `/dev/nvidia*` handles open, nvidia.ko refcount = 1 (kernel module dep only).

## Experiment sequence

### Step 1 — boltctl authorize

```bash
boltctl authorize c4148780-00a9-7ce8-ffff-ffffffffffff
```
→ Linux PCI re-enumerated GPU at 04:00.0; nvidia.ko auto-bound to device via probe.

### Step 2 — immediate passive BAR1 size check

```
Region 1: Memory at 4000000000 (64-bit, prefetchable) [size=256M]
```
**Broken-BAR1 reproduced.**

### Step 3 — read ReBAR capability

```
$ cat /sys/bus/pci/devices/0000:04:00.0/resource1_resize
000000000000ffc0
```

Bitmap = `0xffc0` = bits 6-15 set. Per Linux PCI ReBAR convention bit N → 2^N MB:
- Bit 6 = 64 MB
- Bit 8 = 256 MB ← current
- Bit 15 = 32 GB ← target

**The 5090 chip itself supports 32GB BAR1.**

### Step 4 — unbind nvidia + attempt resize

```bash
echo 0000:04:00.0 > /sys/bus/pci/drivers/nvidia/unbind
echo 15 > /sys/bus/pci/devices/0000:04:00.0/resource1_resize
```

Result: `tee: '/sys/bus/pci/devices/0000:04:00.0/resource1_resize': No space left on device`

`ENOSPC` from `pci_resize_resource()`. The chip accepts the resize request but the kernel can't find space in the parent bridge window.

### Step 5 — walk down sizes to characterize the bridge limit

```
bit 14 (16 GB) → ENOSPC
bit 13 (8 GB)  → ENOSPC
bit 12 (4 GB)  → ENOSPC
bit 11 (2 GB)  → ENOSPC
bit 10 (1 GB)  → ENOSPC
bit 9  (512 MB) → ENOSPC
```

**Anything above 256MB fails.**

## Root cause characterized

The PCI bridge hierarchy:

| Bridge | Description | Prefetchable window |
|---|---|---|
| `00:07.0` | Meteor Lake-P TB4 root port | 65856 MB (64 GB) |
| `02:00.0` | TB tunnel parent | 65824 MB (64 GB) |
| `03:00.0` | **JHL9480 Barlow Ridge TB5 80/120G Bridge** (immediate parent of GPU) | **288 MB** ← BOTTLENECK |
| `04:00.0` | RTX 5090 (BAR1=256MB + BAR3=32MB = 288MB exactly) | |

On hot-plug, Linux PCI core gave bridge 03:00.0 a 288MB prefetchable window — exactly enough for the current BARs with **zero headroom**. The upstream bridges (02:00.0, 00:07.0) have ~64GB each of unused prefetchable space.

The H1 root cause is now precisely characterized: **Linux fails to propagate enough prefetchable headroom from upstream bridges (02:00.0 → 03:00.0) on hot-plug enumeration**. The chip supports the resize; the BARs would fit; the upstream resources exist — but the bridge window at 03:00.0 wasn't sized to accommodate them.

## Implications for E27

The E27 patch landing zone is now sharper than "widen the realloc-on path" (per [[../../../memory/feedback_io_vs_prefetchable_realloc_asymmetry_2026_05_26]]):

- **Wrong target:** ReBAR sysfs / BAR negotiation. The BAR is fine.
- **Wrong target:** widen the realloc-on path. We're not asking for new allocations; the question is whether existing room is propagated.
- **Right target:** bridge window sizing in `__assign_resources_sorted` (or `pci_setup_bridges` / `pci_setup_bridge`) — on hot-plug, the algorithm should look at all downstream BARs' ReBAR-capable max sizes and size the bridge window to accommodate them, given upstream room is available.
- **Even sharper:** the kernel cmdline `pci=hpmmioprefsize=32G` instructs the kernel to pre-size hot-plug bridges' prefetchable windows. This is honored at COLD-BOOT enumeration (BAR1=32GB works) but BYPASSED on runtime hot-plug. Either fix the hot-plug path to honor `hpmmioprefsize`, or rework the bridge-sizing algorithm to compute from downstream ReBAR caps.

## Recovery state

- nvidia.ko unbound from 04:00.0 (clean — no consumers were probing)
- DaemonSets remain quiesced (nodeSelector patches in place)
- Host fully responsive
- Cleanest recovery: reboot for cold-plug, then remove nodeSelector patches to restore consumers

```bash
# Recovery steps (post-reboot):
kubectl patch ds -n kube-system nvidia-driver-injector \
    --type='json' -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector"}]'
kubectl patch ds -n kube-system nvidia-device-plugin-daemonset \
    --type='json' -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector"}]'
```

## Forensic captures

- `/var/log/mission-1-archaeology/rebar-experiment-2026-05-28/state.tar.gz` (337KB) — full must-gather

## Cross-references

- [[E07-cable-replug-drain-first]] — Run 4b documented original broken-BAR1 observation
- [[../../../memory/project_e7_cable_replug_h1_falsified_2026_05_25]] — original H1 hypothesis confirmation
- [[../../../memory/feedback_io_vs_prefetchable_realloc_asymmetry_2026_05_26]] — design implication framing
- [[../../../memory/feedback_no_rpc_observability_on_broken_bar1_2026_05_28]] — Run 4b lesson applied here
- E27 (planned Linux PCI core patch; tracked in [[../upstream-plan]] / docs/patches.md if applicable)
