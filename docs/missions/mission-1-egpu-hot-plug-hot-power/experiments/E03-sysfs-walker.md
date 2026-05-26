# E03 — Exhaustive sysfs walker

**Status:** PENDING
**Phase:** 2.2
**Risk:** LOW (read-only enumeration, selective writes)
**Cost:** ~1-2 hr
**Reversibility:** varies per write
**Last updated:** 2026-05-26

## Hypothesis

The Linux PCI subsystem exposes many writable sysfs files under `/sys/bus/pci/devices/<BDF>/` and `/sys/bus/thunderbolt/devices/<UUID>/`. Most are documented (`reset`, `remove`, `power/control`) but the surface is large enough that an undocumented or rarely-used writable file may exist that triggers bridge re-enumeration. Hypothesis: somewhere in the sysfs surface there is a write that triggers `__pci_setup_bus()` or equivalent path with fresh resource budget.

This is **exhaustive enumeration** — write to every writable file and observe.

## Falsification gates

**PASS (any file):** writing to a sysfs file causes BAR1=32G recovery.

**FAIL (all files):** no sysfs write triggers recovery beyond what's already tested in E02, E10-E14, E04.

**INCONCLUSIVE:** write causes new failure mode; abort and reboot.

## Prerequisites

- Cluster in "broken-BAR1" state per `_STARTING-STATE-RECIPE.md`
- Root access
- E02, E10-E14, E04 already attempted (this experiment EXPANDS beyond the targeted ones)

## Method

### Step 1 — Pre-experiment state capture

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E03
```

### Step 2 — Enumerate writable sysfs surface

```bash
# PCI devices in the TB branch (00:07.x, 01:00.0, 02:00.0, 03:00.0, 03:00.1)
for bdf in 0000:00:07.X 0000:01:00.0 0000:02:00.0 0000:03:00.0 0000:03:00.1; do
  echo "=== $bdf ==="
  sudo find "/sys/bus/pci/devices/$bdf/" -maxdepth 2 -type f -writable -printf "%p\n" 2>/dev/null
done > /tmp/E03-writable-pci-sysfs.txt

# Thunderbolt subsystem
sudo find /sys/bus/thunderbolt/devices/ -type f -writable -printf "%p\n" 2>/dev/null \
  >> /tmp/E03-writable-pci-sysfs.txt

cat /tmp/E03-writable-pci-sysfs.txt
wc -l /tmp/E03-writable-pci-sysfs.txt
# Expected: ~50-150 writable files across all devices in the TB tree
```

### Step 3 — Filter to interesting candidates

Files to EXCLUDE (already covered):
- `remove`, `reset`, `rescan` (E10, E11, E12)
- `power/control`, `power_state` (E14)
- `reset_method` (E13)

Files of interest (candidates that may trigger re-enumeration):
- `enable`, `enabled` (PCI device enable)
- `msi_irqs/*` (MSI configuration)
- `numa_node` (NUMA placement)
- `boot_vga`, `current_link_speed`, `current_link_width` (PCIe link state)
- Thunderbolt-specific: `authorized`, `key`, `nvm_authenticate`

```bash
grep -vE 'remove$|/reset$|rescan|power/control|power_state|reset_method' \
  /tmp/E03-writable-pci-sysfs.txt > /tmp/E03-candidates.txt
cat /tmp/E03-candidates.txt
```

### Step 4 — Drain workload

```bash
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s
```

### Step 5 — For each candidate, attempt informed write

For each file in `/tmp/E03-candidates.txt`:

```bash
ENTRY=<file>
ENTRY_NAME=$(basename "$ENTRY")

# Read current value
PRE=$(sudo cat "$ENTRY" 2>/dev/null)

# Choose write value based on file semantics:
# - enable/enabled → write "1" (reapply enable)
# - msi_irqs → typically R-only ABI; skip
# - authorized (TB) → toggle 0 then 1
# - current_link_speed → write same value (no-op test) or higher value
# - boot_vga → write same (no semantic change expected)

WRITE_VAL=$PRE  # default: no-op (rewrite same value)
case "$ENTRY_NAME" in
  enable|enabled) WRITE_VAL=1 ;;
  authorized) WRITE_VAL=0; sleep 2; WRITE_VAL2=1 ;;
  current_link_speed) WRITE_VAL=3 ;;  # gen3
  boot_vga) WRITE_VAL=1 ;;
  *) WRITE_VAL=$PRE ;;
esac

# Try the write (capture err if any)
echo "$WRITE_VAL" | sudo tee "$ENTRY" 2>&1 || echo "write failed: $ENTRY"
sleep 2

# If authorized, do the followup
if [ "$ENTRY_NAME" = "authorized" ]; then
  echo "$WRITE_VAL2" | sudo tee "$ENTRY"
  sleep 2
fi

# Check if BAR1 changed
CURRENT_BAR1=$(cat /sys/bus/pci/devices/0000:03:00.0/resource | awk 'NR==2{print $2-$1+1}')
echo "$ENTRY: pre=$PRE wrote=$WRITE_VAL bar1=$CURRENT_BAR1"
```

### Step 6 — Final state capture + diff

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E03
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E03
```

### Step 7 — Scale workload back up (only if PASS)

```bash
kubectl scale -n vllm deployment/vllm --replicas=1
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

## Predicted PASS signature

```
BAR1: 256M → 32G after writing to <specific file>
```

## Predicted FAIL signature (likely)

```
BAR1: 256M → 256M across all tested files
No sysfs file outside the already-tested set triggers re-allocation
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Write to `enable` disables device | nvidia-smi fails | `echo 1 > .../enable` |
| TB `authorized=0` deauthorizes tunnel | TB link drops | `boltctl authorize <uuid>`; reboot if stuck |
| Some writes return -EINVAL | expected for type-mismatched values | log and continue |

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

- `Documentation/ABI/testing/sysfs-bus-pci`
- `Documentation/ABI/testing/sysfs-bus-thunderbolt`
- E02, E10-E14, E04 cover the documented writes; this experiment fills the rest
