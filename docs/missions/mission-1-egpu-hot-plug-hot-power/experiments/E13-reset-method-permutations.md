# E13 — reset_method permutations

**Status:** PENDING
**Phase:** 2.1
**Risk:** LOW-MEDIUM (varies per method)
**Cost:** ~5 min per method (4-5 methods to test)
**Reversibility:** auto for flr/pm; manual for bus
**Last updated:** 2026-05-26

## Hypothesis

Linux PCI exposes multiple reset methods at `/sys/bus/pci/devices/<BDF>/reset_method`. Each method has different scope:
- `flr` — Function Level Reset (per-function)
- `pm` — Power Management D3hot/D0 cycle
- `bus` — Secondary bus reset (resets entire bus)
- `device_specific` — vendor-specific reset

E12 tests FLR specifically. E13 systematically tries the other methods. Hypothesis: `bus` reset (secondary bus reset on the parent bridge) may trigger more aggressive re-enumeration than FLR, because it forces the entire downstream bus to re-initialize.

## Falsification gates

**PASS (any method):** BAR1=32G post-reset. The method's reset scope was wide enough to trigger bridge-window re-allocation.

**FAIL (all methods):** BAR1=256M post-reset across all methods. None of the reset primitives is sufficient.

**INCONCLUSIVE:** any method causes device to disappear, AER storm, or Xid cascade.

## Prerequisites

- Cluster in "broken-BAR1" state per `_STARTING-STATE-RECIPE.md`
- Each method must be supported (check `reset_method` file)
- After each method's test, RE-ENTER broken state if PASS happens early (to test remaining methods independently)

## Method

### Step 1 — Enumerate supported reset methods

```bash
cat /sys/bus/pci/devices/0000:03:00.0/reset_method
# Example output: "flr bus pm device_specific"
# Track which methods to test in METHODS variable
METHODS="flr bus pm device_specific"  # adjust based on output
```

### Step 2 — For each method, run the sub-experiment

For each method, repeat steps 2a-2g:

#### 2a. Pre-experiment state capture

```bash
METHOD=<flr|bus|pm|device_specific>
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E13-$METHOD
```

#### 2b. Set the reset method

```bash
echo $METHOD | sudo tee /sys/bus/pci/devices/0000:03:00.0/reset_method
# Verify:
cat /sys/bus/pci/devices/0000:03:00.0/reset_method
```

#### 2c. Drain workload

```bash
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s
```

#### 2d. Issue reset

```bash
echo 1 | sudo tee /sys/bus/pci/devices/0000:03:00.0/reset
```

#### 2e. Wait

```bash
sleep 5  # rationale: bus reset takes longer than FLR; 5s safe upper bound
```

#### 2f. Post-experiment state capture + diff

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E13-$METHOD
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E13-$METHOD
```

#### 2g. Note result, re-enter broken state if needed

If PASS — that's the answer; scale workload back up; stop testing remaining methods.
If FAIL — proceed to next method (broken state still applies).
If INCONCLUSIVE — diagnose; may need reboot before continuing.

### Step 3 — Restore default reset method when done

```bash
echo flr | sudo tee /sys/bus/pci/devices/0000:03:00.0/reset_method
```

## Predicted PASS signature (per method)

```
BAR1: 256M → 32G
Bridge 03:00.0 pref: 288M → 33089M
```

## Predicted FAIL signature (per method)

```
BAR1: 256M → 256M (unchanged)
Bridge 03:00.0 pref: 288M → 288M
```

## Expected outcomes per method

| Method | Predicted outcome | Reason |
|---|---|---|
| flr | FAIL | function-only scope; same as E12 |
| pm | FAIL | D3hot is power management, not enumeration |
| bus | POSSIBLY PASS | secondary bus reset = wider scope; may trigger re-enum |
| device_specific | UNKNOWN | NVIDIA's per-device reset; behavior undocumented |

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| `bus` reset hangs bus | dmesg shows secondary bus reset timeout | reboot required |
| `pm` reset puts GPU in D3cold, won't wake | nvidia-smi fails with "no device" | `echo on > /sys/bus/pci/devices/<BDF>/power/control`; reboot if persists |
| `device_specific` undocumented behavior | unexpected errors | reboot |

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

- Linux source: `drivers/pci/pci.c::pci_reset_methods`
- Linux source: `drivers/pci/pci.c::pci_bus_reset`
- E12 (flr specifically — subset of this experiment)
