# E05 — setpci bridge memory base/limit widen

**Status:** PENDING
**Phase:** 2.4
**Risk:** HIGH (config space mis-write can hang the PCI bus)
**Cost:** ~30 min
**Reversibility:** difficult (revert by writing original values, but if bus hangs, only reboot recovers)
**Last updated:** 2026-05-26

## Hypothesis

The PCIe bridge at `0000:03:00.0` has its prefetchable memory window defined by registers `Prefetchable Memory Base (0x24)` + `Prefetchable Memory Limit (0x26)` (plus 64-bit upper halves at 0x28/0x2C). The kernel programs these during enumeration; in the broken-BAR1 state they're set to a 288MB window. Hypothesis: directly writing wider values into these registers via `setpci` will allow the downstream device's BAR1 to size up beyond 256M.

**Critical caveat:** PCIe bridges enforce that BAR sizes are negotiated at probe time and downstream devices have their BAR sizes captured in config space. Even if the bridge window is widened post-hoc, the GPU's BAR1 size register may not change. This experiment may produce a wider bridge window with an unchanged-size GPU BAR (interesting but not PASS).

This is most useful when combined with E12 FLR or E16 RBAR Control write (see E17).

## Falsification gates

**PASS:** post-experiment BAR1=32G AND bridge prefetchable window ≥32G AND device functional. Window widening allowed BAR size up-negotiation.

**FAIL:** BAR1=256M (unchanged) even with widened bridge window. Bridge window expanded but device didn't re-size its BAR.

**INCONCLUSIVE:** PCI bus hangs; device disappears; AER cascade.

## Prerequisites

- Cluster in "broken-BAR1" state per `_STARTING-STATE-RECIPE.md`
- `setpci` available (`pciutils` package)
- **Read PCIe Base Spec § 7.5.1.13 (Prefetchable Memory Base/Limit) first**

## Method

### Step 1 — Pre-experiment state capture

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E05
```

### Step 2 — Read current bridge memory base/limit

```bash
BRIDGE=0000:03:00.0  # Wait — 03:00.0 is the GPU itself, not the bridge.
                      # The bridge ABOVE the GPU is 0000:02:00.0 (TB downstream)
BRIDGE=0000:02:00.0

# Read current prefetchable window (registers 0x24-0x2F):
#   0x24-0x25: Prefetchable Memory Base (low 16 bits)
#   0x26-0x27: Prefetchable Memory Limit (low 16 bits)
#   0x28-0x2B: Prefetchable Memory Base Upper 32 bits
#   0x2C-0x2F: Prefetchable Memory Limit Upper 32 bits

sudo setpci -s $BRIDGE 0x24.l 0x28.l 0x2c.l
# Example output (current narrow window):
#   pref_base_lo  = 0x0001b001  (base=0x10000000, 64-bit indicator bit set)
#   pref_base_hi  = 0x00000000
#   pref_lim_hi   = 0x00000000
# Decode: base=0x10000000, limit=0x21FFFFFF → 288MB window

# Also read memory base/limit (32-bit non-prefetchable, registers 0x20-0x23):
sudo setpci -s $BRIDGE 0x20.l
# pref_lim_hi   = 0x00000000 → limit_lo[15:4]=0x21F
```

### Step 3 — Calculate widened values

```bash
# Target: 32GB prefetchable window starting at 0x10000000
# Base (low 16 bits): 0x1001 (high 12 bits of base[31:20] = 0x100, prefetchable 64-bit = bit 0 set)
# Limit (low 16 bits): need to round up
# Base upper 32: 0x00000000
# Limit upper 32: depends on absolute address

# Wider window starting at 0x10000000, size 32GB:
#   base  = 0x0000_0000_1000_0000
#   limit = 0x0000_0008_0FFF_FFFF  (0x10000000 + 32GB - 1)
#
# Encoded:
#   pref_base_lo (reg 0x24-0x25) = 0x1001 (base_low[15:0] = 0x100<<4 | 0x1 for 64-bit)
#   pref_lim_lo  (reg 0x26-0x27) = 0x80FF (limit_low[15:0] = 0x80F<<4 | 0x1)
#   pref_base_hi (reg 0x28-0x2B) = 0x00000000
#   pref_lim_hi  (reg 0x2C-0x2F) = 0x00000008

# But — the OS-side struct resource also tracks bridge windows independently.
# Writing setpci alone may not update kernel's resource tracking, so the GPU
# BAR allocator (when it next runs) may not see the new window.

# Combined write of base+limit registers (low halves):
sudo setpci -s $BRIDGE 0x24.l=0x80FF1001
# (0x80FF1001 = base_lo=0x1001 (low half) | limit_lo=0x80FF (high half of 32-bit value))
# Wait — endian of setpci 4-byte write: byte 0x24 LSB. So 0x80FF1001 written at 0x24:
#   reg 0x24 (base_lo)   = 0x1001 (correct)
#   reg 0x26 (limit_lo)  = 0x80FF (correct)

# Upper halves:
sudo setpci -s $BRIDGE 0x28.l=0x00000000
sudo setpci -s $BRIDGE 0x2c.l=0x00000008
```

### Step 4 — Drain workload (already drained by starting-state recipe)

```bash
# (skip if already drained)
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s
```

### Step 5 — Verify register state changed

```bash
sudo setpci -s $BRIDGE 0x24.l 0x28.l 0x2c.l
# Expected: 0x80FF1001, 0x00000000, 0x00000008
```

### Step 6 — Issue PCI rescan to make kernel see the new window

```bash
echo 1 | sudo tee /sys/bus/pci/devices/0000:03:00.0/remove
sleep 2
echo 1 | sudo tee /sys/bus/pci/rescan
sleep 10
```

### Step 7 — Post-experiment state capture + diff

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E05
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E05
```

### Step 8 — Scale workload back up (only if PASS)

```bash
kubectl scale -n vllm deployment/vllm --replicas=1
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

## Predicted PASS signature

```
BAR1: 256M → 32G
Bridge 02:00.0 pref: 288M → 32G (widened by setpci)
Bridge 03:00.0 (the GPU's parent): may need separate widening — chain effect
Device functional, no AER
```

## Predicted FAIL signature

```
Bridge 02:00.0 pref: 288M → 32G (widened OK)
BAR1: 256M → 256M (UNCHANGED — kernel didn't re-negotiate)
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Register write returns error | setpci stderr | check BDF, check capability presence; abort experiment |
| Bus hang on rescan | `lspci` blocks | reboot required |
| Kernel sees overlap with another bridge | dmesg shows resource conflict | restore original register values; if persists, reboot |
| BAR1 sizes up but to wrong value (e.g., 1G, not 32G) | partial PASS | check GPU's RBAR capability for supported sizes (E16); log INCONCLUSIVE |

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

- PCIe Base Spec § 7.5.1.13 Prefetchable Memory Base/Limit
- Linux source: `drivers/pci/setup-bus.c::pci_setup_bridge_mmio_pref`
- E16 (RBAR Control register — complementary)
- E17 (combined E05 + FLR sequence)
