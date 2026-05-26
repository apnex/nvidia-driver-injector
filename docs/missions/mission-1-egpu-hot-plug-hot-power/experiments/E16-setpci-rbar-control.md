# E16 — setpci RBAR Control register write

**Status:** PENDING
**Phase:** 2.4
**Risk:** HIGH (writing device extended capability registers; mis-write can wedge GPU)
**Cost:** ~1 hr
**Reversibility:** difficult (write current value back; reboot if device hangs)
**Last updated:** 2026-05-26

## Hypothesis

The RTX 5090 implements PCIe Resizable BAR (RBAR) Extended Capability (ID 0x0015). This capability has a **Control register** at offset +0x08 from the capability header per BAR, with bits [5:0] = `BAR_Size`. Writing this register (with appropriate access protocol per PCIe spec) **forces** the BAR to the chosen size at the next BAR re-read. Hypothesis: directly writing RBAR Control register from userspace via `setpci` can override the kernel's negotiated BAR size and force BAR1 back to 32G.

**Critical:** RBAR Control writes also require the upstream bridge to have a window large enough — otherwise the device may BAR-out into invalid space. So this MUST be combined with E05 (bridge widen) — see E17 for the combined experiment.

## Falsification gates

**PASS:** post-experiment BAR1=32G, device functional, nvidia-smi reads OK. RBAR Control write directly overrode the size.

**FAIL:** BAR1 stays 256M after RBAR write — write was accepted but ignored, or kernel re-read other BARs without re-reading RBAR.

**INCONCLUSIVE:** device disappears, AER cascade, GPU wedge, nvidia.ko BUG/OOPS.

## Prerequisites

- Cluster in "broken-BAR1" state per `_STARTING-STATE-RECIPE.md`
- `setpci` available
- E05 (bridge widen) understood — RBAR alone may not be enough without upstream window

## Method

### Step 1 — Pre-experiment state capture

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E16
```

### Step 2 — Locate RBAR Extended Capability

```bash
GPU=0000:03:00.0

# Find the RBAR ECAP (extended capability ID 0x0015)
sudo lspci -s $GPU -vvv | grep -A 20 "Capabilities: \[" | grep -B 1 "Resizable BAR"
# Output like:
#   Capabilities: [bb0 v1] Physical Resizable BAR
# Save offset:
RBAR_OFFSET=0xbb0  # SET THIS based on lspci output

# Or programmatically:
RBAR_OFFSET=$(sudo lspci -s $GPU -xxx | head -300 | \
  awk -v rbar="15 00 .. .." 'BEGIN{IGNORECASE=1} /^[0-9a-f]+0:/ { offset=$1; sub(":","",offset); offset_val=strtonum("0x"offset) } ...')
# (this is fragile — easier to manually look at lspci -vvv output)
```

### Step 3 — Read current RBAR Control register

```bash
# RBAR header at $RBAR_OFFSET
# Capability layout:
#   +0x00: PCI Express Extended Capability Header (4 bytes)
#   +0x04: Capability register for BAR 0 (4 bytes)
#   +0x08: Control register for BAR 0 (4 bytes)
#   +0x0C: Capability register for BAR 1 (4 bytes)  ← we care about BAR1
#   +0x10: Control register for BAR 1 (4 bytes)
#   ... continues per BAR ...

# Read BAR1's Control register:
BAR1_CTRL_OFFSET=$((RBAR_OFFSET + 0x10))
sudo setpci -s $GPU $(printf '0x%x' $BAR1_CTRL_OFFSET).l
# Output: 32-bit value
# Bits [5:0]: BAR Size (current). 0x00=1MB, 0x01=2MB, ..., 0x14=16GB, 0x15=32GB
# Bits [7:6]: reserved
# Bits [10:8]: BAR Index (should be 1 for BAR1)
# Bits [31:16]: Reserved/RsvdZ

# Also read BAR1's Capability register (read-only — shows supported sizes):
BAR1_CAP_OFFSET=$((RBAR_OFFSET + 0x0C))
sudo setpci -s $GPU $(printf '0x%x' $BAR1_CAP_OFFSET).l
# Bits [31:4]: Supported BAR Sizes bitmap (bit N set = 2^N MB supported)
# For RTX 5090: should show bits 0..15 set (1MB through 32GB)
```

### Step 4 — Write target size to BAR1 Control

```bash
# Read current control value first
CURRENT_CTRL=$(sudo setpci -s $GPU $(printf '0x%x' $BAR1_CTRL_OFFSET).l)
echo "Current BAR1 Control: $CURRENT_CTRL"

# Target: BAR_Size=0x15 (32GB), BAR_Index=1, other bits preserved
# Mask: clear bits [5:0], OR in 0x15
NEW_CTRL=$(printf '0x%08x' $(((0x$CURRENT_CTRL & 0xFFFFFFC0) | 0x15)))
echo "New BAR1 Control: $NEW_CTRL"

# Drain workload (if not already drained)
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s

# Write the new control value
sudo setpci -s $GPU $(printf '0x%x' $BAR1_CTRL_OFFSET).l=$NEW_CTRL
```

### Step 5 — Trigger BAR re-read

The kernel doesn't re-read BARs spontaneously. Force it via FLR or remove+rescan:

```bash
# Option A: FLR (less disruptive, but may not re-read BARs from device)
echo 1 | sudo tee /sys/bus/pci/devices/$GPU/reset
sleep 3

# Option B: remove+rescan (kernel re-reads BAR sizes during probe)
# echo 1 | sudo tee /sys/bus/pci/devices/$GPU/remove
# sleep 2
# echo 1 | sudo tee /sys/bus/pci/rescan
# sleep 10
```

### Step 6 — Post-experiment state capture + diff

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E16
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E16
```

### Step 7 — Scale workload back up (only if PASS)

```bash
kubectl scale -n vllm deployment/vllm --replicas=1
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

## Predicted PASS signature

```
BAR1: 256M → 32G
RBAR Control[BAR1] bits[5:0]: 0x08 → 0x15
Device functional, nvidia-smi works
```

## Predicted FAIL signature

```
RBAR Control[BAR1] bits[5:0]: written but reverts to 0x08 (kernel re-programs)
OR
RBAR Control updated to 0x15 but BAR1 size unchanged (kernel doesn't re-read)
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Wrong RBAR offset | setpci writes to wrong reg; device hangs | reboot |
| Write blocked by kernel (RBAR is "owned" by kernel PCI core) | setpci returns success but reg unchanged | confirms kernel guards this; transitions experiment to "kernel-side patch needed" → E26/E27 |
| BAR size widens but device wedges (32GB BAR beyond bridge window) | nvidia-smi hangs; AER errors | this is why E05 must run first; reboot |
| Capability not present | `lspci -vvv` shows no RBAR | scope-out; device firmware doesn't support |

## Per-run records

> One subsection per execution. Body-of-evidence builds across runs.

### Run 1 — pending

(Filled in when run. Conditions / Protocol deviations / Result / Diff highlights / Forensic bundle / Anomalies / Conclusion.)

## Patch coverage analysis

(Filled in if a run surfaces driver-level behavior.)

## Patch design implications

(Filled in once body-of-evidence supports a design decision.)

## Open follow-ups

- [ ] (Populated based on run results.)

## Forensic bundles

| Run | Bundle path | Size | Notes |
|---|---|---|---|
|     |             |      |       |

## Cross-references

- PCIe Base Spec § 7.8.6 Resizable BAR Extended Capability
- Linux source: `drivers/pci/pci.c::pci_rebar_set_size`
- E05 (bridge widen — needs to be combined; see E17)
- E17 (combined experiment)
