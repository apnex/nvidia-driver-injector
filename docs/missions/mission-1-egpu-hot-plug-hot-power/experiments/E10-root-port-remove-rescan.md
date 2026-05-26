# E10 — Remove root port + rescan from parent

**Status:** PENDING
**Phase:** 2.1
**Risk:** MEDIUM
**Cost:** ~5 min
**Reversibility:** manual (rescan command)
**Last updated:** 2026-05-26

## Hypothesis

Going further up the PCI tree than E02 (slot-level) by removing the **root port** itself and then rescanning from the PCIe root (`/sys/bus/pci/rescan`) forces full re-enumeration of the entire branch including the root port. This re-runs `pci_assign_unassigned_root_bus_resources()` from a deeper layer than the pciehp path, potentially producing fresh bridge window allocation. Hypothesis: removing the root port re-enables size-discovery for the bridge windows because the parent bus probe is restarted.

## Falsification gates

**PASS:** post-experiment BAR1=32G, bridge 03:00.0 prefetchable ≥32G. Root-level re-enumeration produced correct allocation.

**FAIL:** post-experiment BAR1=256M, bridge 03:00.0 prefetchable=288M. Going up to root port doesn't change the fallback allocation outcome.

**INCONCLUSIVE:** root port doesn't reappear after rescan; PCIe tree partially populated; host reports "PCI: failed to assign resource" in dmesg for the bridge window. Reboot to recover.

## Prerequisites

- Cluster in "broken-BAR1" state per `_STARTING-STATE-RECIPE.md`
- Identify root port BDF that's the parent of the TB controller

## Method

### Step 1 — Pre-experiment state capture

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E10
```

### Step 2 — Find root port BDF

```bash
# Walk up from the GPU to find root ports (Class 0x0604, Type 1)
GPU=0000:03:00.0
parent=$(readlink /sys/bus/pci/devices/$GPU | xargs dirname | xargs basename)
echo "GPU parent: $parent"

# Continue walking up
current=$parent
while [ "$current" != "pci0000:00" ]; do
  current_path=$(readlink /sys/bus/pci/devices/$current 2>/dev/null)
  if [ -z "$current_path" ]; then break; fi
  parent=$(echo "$current_path" | xargs dirname | xargs basename)
  echo "$current → parent: $parent"
  current=$parent
done

# The last PCI device before pci0000:00 is the root port — capture as ROOT
ROOT=0000:00:07.X  # SET THIS based on output above (typically 00:07.0, 00:07.1, or 00:07.2)
```

### Step 3 — Drain workload

```bash
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s
```

### Step 4 — Execute root port remove + global rescan

```bash
# Remove the entire branch from the root port down
echo 1 | sudo tee /sys/bus/pci/devices/$ROOT/remove
sleep 5

# Verify branch is empty
lspci -s 0000:0[1-9]: 2>&1 || echo "expected: no devices on TB branch"

# Global rescan from PCIe root
echo 1 | sudo tee /sys/bus/pci/rescan
```

### Step 5 — Wait for re-enumeration

```bash
sleep 30  # rationale: full PCIe root rescan + TB tunnel re-establishment +
          # nvidia.ko probe + injector pod re-bind; observed up to 25s in prior runs
```

### Step 6 — Post-experiment state capture + diff

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E10
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E10
```

### Step 7 — Scale workload back up (only if PASS)

```bash
kubectl scale -n vllm deployment/vllm --replicas=1
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

## Predicted PASS signature

```
BAR1:        256M → 32G
Bridge 03:00.0 pref: 288M → 33089M
All bridges 00:07.X, 01:00.0, 02:00.0, 03:00.0 windows: re-allocated
TB tunnel: re-established (boltctl shows authorized)
```

## Predicted FAIL signature

```
BAR1:        256M → 256M
Bridge 03:00.0 pref: 288M → 288M
PCI branch re-enumerated but with same fallback budget
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Root port removal hangs | `echo 1 > .../remove` blocks indefinitely | `sudo systemctl reboot` |
| Branch doesn't rescan back | After 30s, `lspci -s 0000:01:` empty | `echo 1 | sudo tee /sys/bus/pci/rescan` again; if fails, reboot |
| TB tunnel doesn't re-authorize | `boltctl list` shows device with `disconnected` | `boltctl authorize <uuid>`; verify auto-authorize policy in `bolt.conf` |
| AER storm on rescan | dmesg shows AER cascade on root port | scope-out for now; suggests deeper hardware issue; reboot |

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

- Linux source: `drivers/pci/probe.c::pci_scan_root_bus_bridge`
- Linux source: `drivers/pci/setup-bus.c::pci_assign_unassigned_root_bus_resources`
- E02 (slot power-cycle — narrower scope; this is the broader-scope version)
