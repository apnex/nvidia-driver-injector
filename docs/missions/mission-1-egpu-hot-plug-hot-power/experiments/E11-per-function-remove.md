# E11 — Per-function remove (GPU + audio) + global rescan

**Status:** PENDING
**Phase:** 2.1
**Risk:** LOW
**Cost:** ~3 min
**Reversibility:** manual (rescan)
**Last updated:** 2026-05-26

## Hypothesis

The RTX 5090 device exposes two PCI functions: `0000:03:00.0` (GPU/VGA) and `0000:03:00.1` (HDMI audio). Removing **only** these device-leaves (not the parent bridge) and then rescanning narrows the experiment to function-level re-enumeration without re-running bridge-window allocation. Hypothesis: function-level remove+rescan reuses the existing (broken) bridge windows — confirming that the bridge-window allocation is the failure point, not the device probe.

This is a **control experiment** for E10 (root-port-level): if E11 FAILs and E10 PASSes, the failure point is bridge-level; if both FAIL, it's a more fundamental issue.

## Falsification gates

**PASS:** post-experiment BAR1=32G, bridge 03:00.0 prefetchable ≥32G. Function-level reload alone was sufficient (would be a surprise).

**FAIL:** post-experiment BAR1=256M, bridge prefetchable=288M. Device re-enumerated but bridge windows unchanged. **This is the expected outcome.**

**INCONCLUSIVE:** GPU function reloads but audio function fails to rescan back (or vice versa).

## Prerequisites

- Cluster in "broken-BAR1" state per `_STARTING-STATE-RECIPE.md`
- Both 0000:03:00.0 (GPU) and 0000:03:00.1 (audio) present in lspci

## Method

### Step 1 — Pre-experiment state capture

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E11
```

### Step 2 — Drain workload

```bash
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s
```

### Step 3 — Remove both functions

```bash
# Remove audio function first (less critical)
echo 1 | sudo tee /sys/bus/pci/devices/0000:03:00.1/remove
sleep 1

# Remove GPU function
echo 1 | sudo tee /sys/bus/pci/devices/0000:03:00.0/remove
sleep 2

# Verify both gone
lspci -s 0000:03:00 || echo "expected: no devices on 03:00.x"
```

### Step 4 — Global rescan

```bash
echo 1 | sudo tee /sys/bus/pci/rescan
```

### Step 5 — Wait for re-enumeration

```bash
sleep 10  # rationale: only function-level probe; faster than E10
```

### Step 6 — Post-experiment state capture + diff

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E11
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E11
```

### Step 7 — Scale workload back up (only if PASS)

```bash
kubectl scale -n vllm deployment/vllm --replicas=1
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

## Predicted PASS signature

```
BAR1: 256M → 32G
Bridge 03:00.0 pref: 288M → 33089M
```

## Predicted FAIL signature (expected)

```
BAR1: 256M → 256M
Bridge 03:00.0 pref: 288M → 288M (windows intact, just narrow)
/dev/nvidia0: re-created
nvidia.ko: re-probed
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Audio function fails to rescan | `lspci -s 0000:03:00.1` empty after 30s | `echo 1 | sudo tee /sys/bus/pci/rescan` again; check `dmesg` for probe error |
| nvidia.ko probe fails | `dmesg | grep -i nvidia` shows `rm_init_adapter failed` | check injector state; in broken-BAR1, this may surface as new failure mode |
| BAR1 enumerates at different small size (e.g., 64M) | suggests the BAR-size-truncation logic depends on current bridge window | log as INCONCLUSIVE; informs E16 design |

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

- Linux source: `drivers/pci/remove.c::pci_stop_and_remove_bus_device_locked`
- E10 (root-port-level remove — broader scope)
- Confirms or denies that bridge-window is the failure point
