# E02 — pciehp slot power-cycle

**Status:** PENDING
**Phase:** 2.1
**Risk:** LOW
**Cost:** ~2 min
**Reversibility:** auto (slot powers back on)
**Last updated:** 2026-05-26

## Hypothesis

The Linux PCIe hotplug subsystem (pciehp) exposes per-slot `power` sysfs files at `/sys/bus/pci/slots/<N>/power`. Writing `0` triggers a **slot-OFF** transition (drv_remove → pciehp_unconfigure_device → release of bridge resources), and writing `1` triggers a **slot-ON** transition (pciehp_configure_device → bus enumeration). This is the kernel's own hotplug primitive, distinct from physical cable cycling. Hypothesis: a slot power-cycle re-runs `pci_bus_assign_resources()` and may produce a different bridge window allocation than the runtime cable replug path (E7) did.

## Falsification gates

**PASS:** post-experiment BAR1=32G, bridge 03:00.0 prefetchable window ≥32G. The pciehp slot-cycle path triggered correct bridge re-allocation.

**FAIL:** post-experiment BAR1=256M, bridge 03:00.0 prefetchable window=288M (or any value <32G). The slot-cycle path produces the same fallback allocation as the cable-replug path (i.e., pciehp uses the same `__pci_setup_bus()` logic that already failed).

**INCONCLUSIVE:** slot fails to power back on (driver doesn't reload); device disappears from `lspci` and doesn't return; or the GPU enumerates with new failures (Xid cascade, AER storm). Reboot to recover.

## Prerequisites

- Cluster in "broken-BAR1" state per `_STARTING-STATE-RECIPE.md`
- pciehp module must be loaded: `lsmod | grep pciehp` → expect present
- Slot number for the TB-tunneled GPU bridge must be discoverable

## Method

### Step 1 — Pre-experiment state capture

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E02
```

### Step 2 — Find the slot number for the GPU's parent bridge

```bash
# Walk /sys/bus/pci/slots/ to find the slot whose 'address' matches
# the GPU's parent bridge (typically 0000:02:00.0 — the TB-tunneled downstream)
for slot in /sys/bus/pci/slots/*/; do
  addr=$(cat "$slot/address" 2>/dev/null)
  echo "slot=$(basename "$slot") addr=$addr"
done

# Expected output includes a line like:
#   slot=12 addr=0000:02:00
# (i.e., slot 12 covers the TB-tunneled downstream port)
# Save the slot number — SLOT=<N>
SLOT=<N>  # SET THIS based on output above
```

### Step 3 — Drain workload

```bash
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s
```

### Step 4 — Execute slot power-cycle

```bash
# Slot OFF
echo 0 | sudo tee /sys/bus/pci/slots/$SLOT/power
sleep 2

# Verify slot is off (no devices below this point)
lspci -s 0000:03: 2>&1 || echo "expected: no devices on bus 03"

# Slot ON
echo 1 | sudo tee /sys/bus/pci/slots/$SLOT/power
```

### Step 5 — Wait for re-enumeration

```bash
sleep 10  # rationale: pciehp enumeration + nvidia.ko probe both async; 10s
          # covers worst case observed in /var/log/messages
```

### Step 6 — Post-experiment state capture + diff

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E02
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E02
```

### Step 7 — Scale workload back up (only if PASS)

```bash
kubectl scale -n vllm deployment/vllm --replicas=1
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

## Predicted PASS signature

```
BAR1:        256M → 32G          ← key indicator
Bridge 03:00.0:
  pref_window: 288M → 33089M     ← key indicator
  res 1: 0xb0000000-0xb0fffffff → 0xb0000000-0x4b0ffffff
```

## Predicted FAIL signature

```
BAR1:        256M → 256M (unchanged)
Bridge 03:00.0:
  pref_window: 288M → 288M (unchanged)
Device DID re-enumerate (driver reload, /dev/nvidia* recreated)
                         ← experiment ran; just didn't fix the problem
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Slot won't power back on | `echo 1 > .../power` succeeds but `lspci -s 0000:03:` empty after 30s | `sudo systemctl reboot` |
| nvidia.ko fails to probe after re-enum | `dmesg | tail -50` shows `rm_init_adapter failed` or `firmware load error` | check `/run/nvidia/injector/state`; if stuck, `systemctl restart nvidia-driver-injector` (host pod); reboot if injector itself wedged |
| TB tunnel doesn't reconnect | `boltctl list` shows `disconnected` | `boltctl authorize <uuid>`; if persists, reboot |
| GPU enumerates but Xid 154 fires | `dmesg | grep -i xid` shows Node Reboot Required | sub-mission C territory; reboot required |

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

- Linux source: `drivers/pci/hotplug/pciehp_ctrl.c::pciehp_power_thread`
- Linux source: `drivers/pci/hotplug/pciehp_pci.c::pciehp_configure_device`
- Matrix doc: Section 1 entry for E02
- Mission doc: H10 (some software trigger exists)
