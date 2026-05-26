# E12 — FLR reset on GPU

**Status:** PENDING
**Phase:** 2.1
**Risk:** LOW
**Cost:** ~1 min
**Reversibility:** auto (reset returns to functional state)
**Last updated:** 2026-05-26

## Hypothesis

Function Level Reset (FLR) issues a PCIe-defined function reset via the device's PCIe capability. FLR alone (without remove/rescan) does NOT trigger bridge re-enumeration — the device just resets internal state. Hypothesis: FLR is **insufficient** alone to recover BAR1 size, because BAR size negotiation happens at PCI bus enumeration time (in `pci_setup_device`), not at reset time.

This is a **negative-control experiment**: we expect FAIL. Confirming FAIL here helps prove that bridge-window-allocation is the failure point (not device-internal state).

## Falsification gates

**PASS:** post-experiment BAR1=32G. Would be very surprising; suggests FLR triggers an unexpected re-enumeration path.

**FAIL:** post-experiment BAR1=256M. **Expected outcome.** FLR reset device internal state but didn't re-negotiate BAR sizes.

**INCONCLUSIVE:** FLR completes but device fails to resume; nvidia.ko probe fails post-FLR.

## Prerequisites

- Cluster in "broken-BAR1" state per `_STARTING-STATE-RECIPE.md`
- GPU supports FLR: `cat /sys/bus/pci/devices/0000:03:00.0/reset_method` should include `flr`

## Method

### Step 1 — Pre-experiment state capture

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E12
```

### Step 2 — Verify FLR support

```bash
cat /sys/bus/pci/devices/0000:03:00.0/reset_method
# Expected output includes: flr
# If `flr` missing, set reset_method:
# echo flr | sudo tee /sys/bus/pci/devices/0000:03:00.0/reset_method
```

### Step 3 — Drain workload

```bash
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s
```

### Step 4 — Issue FLR

```bash
echo 1 | sudo tee /sys/bus/pci/devices/0000:03:00.0/reset
```

### Step 5 — Wait for reset to settle

```bash
sleep 3  # rationale: FLR PCIe spec mandates ≤100ms; nvidia.ko driver reset path adds more
```

### Step 6 — Post-experiment state capture + diff

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E12
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E12
```

### Step 7 — Scale workload back up (only if PASS)

```bash
kubectl scale -n vllm deployment/vllm --replicas=1
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

## Predicted PASS signature

```
BAR1: 256M → 32G                  ← would be surprising
Bridge 03:00.0 pref: 288M → 33089M
```

## Predicted FAIL signature (expected)

```
BAR1: 256M → 256M  (unchanged)
Bridge 03:00.0 pref: 288M → 288M
Driver: nvidia.ko probe re-triggered, device responsive
nvidia-smi: works
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| FLR succeeds but driver fails to resume | `nvidia-smi` errors after reset | restart nvidia-driver-injector pod |
| Device hangs post-FLR | `lspci -s 0000:03:00.0 -v` shows `Memory at <ignored>` | reboot required |
| Reset method falls back to "bus" | dmesg shows `pci 0000:03:00.0: not ready 65535ms after FLR` | bus reset is in E13 territory; transitions to E13 |

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

- PCIe Base Spec 6.0 § 6.6.2 Function Level Reset
- Linux source: `drivers/pci/pci.c::pci_dev_specific_reset`
- E13 (other reset methods)
- E17 (FLR combined with setpci widen)
