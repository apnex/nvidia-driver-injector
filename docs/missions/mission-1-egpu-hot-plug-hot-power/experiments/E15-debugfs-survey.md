# E15 — debugfs surface scan

**Status:** PENDING
**Phase:** 2.2
**Risk:** MEDIUM
**Cost:** ~30 min
**Reversibility:** varies per entry
**Last updated:** 2026-05-26

## Hypothesis

`/sys/kernel/debug/` exposes kernel-internal debugfs entries. The PCI and PCIe subsystems publish entries here that are typically R-only but some are writable and could trigger re-enumeration or window-allocation behavior not exposed via sysfs. Hypothesis: there exists at least one debugfs write that triggers bridge re-allocation.

This is exploratory: we don't know in advance which entries are useful. The experiment is to **enumerate writables under pci/pcie debugfs, identify candidates, test in order of expected utility**.

## Falsification gates

**PASS (any entry):** writing to a debugfs file causes BAR1=32G recovery.

**FAIL (all entries):** no debugfs write triggers the recovery.

**INCONCLUSIVE:** debugfs write causes new failure mode (panic, OOPS, system instability).

## Prerequisites

- Cluster in "broken-BAR1" state per `_STARTING-STATE-RECIPE.md`
- debugfs mounted: `mount | grep debugfs` → expect `/sys/kernel/debug type debugfs`
- Root access (debugfs entries are root-only)

## Method

### Step 1 — Pre-experiment state capture

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E15
```

### Step 2 — Enumerate PCI/PCIe writable debugfs entries

```bash
# Find writable files under pci/pcie debugfs
sudo find /sys/kernel/debug/pci /sys/kernel/debug/pcie 2>/dev/null \
  -type f -writable -printf "%p\n" > /tmp/E15-writable-debugfs.txt

# Also check for our device specifically
sudo find /sys/kernel/debug 2>/dev/null \
  -name "*0000:03:00*" -type f -writable -printf "%p\n" >> /tmp/E15-writable-debugfs.txt

cat /tmp/E15-writable-debugfs.txt
```

### Step 3 — Categorize entries

Expected categories (based on typical kernel debugfs layout):
- `/sys/kernel/debug/pci/<BDF>/config` — config space dump (R-only typically)
- `/sys/kernel/debug/pci/<BDF>/aer_stats` — AER statistics
- `/sys/kernel/debug/aspm_*` — ASPM control entries
- `/sys/kernel/debug/dynamic_debug/control` — dynamic debug print control
- vendor-specific (nvidia, thunderbolt) entries

### Step 4 — Drain workload

```bash
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s
```

### Step 5 — Test each writable entry

For each writable entry under `/tmp/E15-writable-debugfs.txt`:

```bash
ENTRY=<path>
# Read current value (where readable)
sudo cat "$ENTRY" > /tmp/E15-$(basename "$ENTRY").pre

# Try writing meaningful values per entry type:
# - For boolean toggles: try "0" and "1"
# - For ASPM: try "disable" and "L0s,L1"
# - For dynamic_debug: try "+p" to enable prints (informational only)

# Example:
echo "1" | sudo tee "$ENTRY"
sleep 2

# Capture state after each write
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E15-after-$(basename "$ENTRY")
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E15-after-$(basename "$ENTRY")

# Revert if no PASS
sudo tee "$ENTRY" < /tmp/E15-$(basename "$ENTRY").pre
```

### Step 6 — Final post-experiment state capture + diff

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E15
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E15
```

### Step 7 — Scale workload back up (only if PASS)

```bash
kubectl scale -n vllm deployment/vllm --replicas=1
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

## Predicted PASS signature

```
BAR1: 256M → 32G  via specific debugfs entry <X>
```

## Predicted FAIL signature

```
BAR1: 256M → 256M across all tested entries
No debugfs entry triggers bridge re-allocation
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Write to debugfs hangs | command blocks indefinitely | Ctrl-C; if persists, reboot |
| Kernel OOPS on write | dmesg shows BUG/OOPS | reboot; file bug report; skip that entry on retry |
| ASPM disable changes link state but not BAR | log as informational; not a PASS | continue testing other entries |

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

- `Documentation/admin-guide/dynamic-debug-howto.rst`
- Linux source: `drivers/pci/pcie/aspm.c` (debugfs entries)
- Linux source: `drivers/pci/probe.c` (no debugfs trigger we know of, hence "exploratory")
