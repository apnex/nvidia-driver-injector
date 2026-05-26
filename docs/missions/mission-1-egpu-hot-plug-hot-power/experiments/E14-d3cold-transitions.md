# E14 — D3cold transitions

**Status:** PENDING
**Phase:** 2.1
**Risk:** MEDIUM
**Cost:** ~5 min
**Reversibility:** auto (D0 transition restores)
**Last updated:** 2026-05-26

## Hypothesis

PCIe power state D3cold removes power from the device entirely (similar in effect to physical unplug, without cable manipulation). Linux exposes runtime PM control via `/sys/bus/pci/devices/<BDF>/power/control` (`on` / `auto`). With `auto` and supporting userspace, the kernel can transition the device to D3cold when idle. Hypothesis: forcing D3cold → D0 transition triggers full re-initialization including BAR size negotiation, which could fix the bridge window.

**Caveat:** D3cold is a power state, not an enumeration trigger. It may or may not re-run `pci_setup_device()`. Per kernel source, D3cold→D0 does re-program BARs from saved config space, which means BAR1=256M would be re-programmed as 256M (unchanged). This experiment may FAIL by design.

## Falsification gates

**PASS:** post-D3cold-resume BAR1=32G. D3cold transition re-ran BAR size negotiation (would imply Linux PM code does more than expected).

**FAIL:** BAR1=256M post-resume. **Expected outcome.** D3cold restores from saved config, doesn't re-negotiate.

**INCONCLUSIVE:** device fails to resume from D3cold; nvidia.ko probe fails post-resume; AER errors during resume.

## Prerequisites

- Cluster in "broken-BAR1" state per `_STARTING-STATE-RECIPE.md`
- nvidia.ko's runtime PM support (varies by driver version; check `power/control` readable)
- ACPI must support D3cold for this PCIe slot

## Method

### Step 1 — Pre-experiment state capture

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E14
```

### Step 2 — Verify D3cold capability

```bash
# Check runtime PM is exposed
cat /sys/bus/pci/devices/0000:03:00.0/power/control
# Expected: "on" or "auto"

# Check power state support
cat /sys/bus/pci/devices/0000:03:00.0/power_state
# Expected: D0

# Check ACPI _PR3 method for D3cold support
ls -la /sys/bus/pci/devices/0000:03:00.0/firmware_node/ 2>/dev/null || echo "no ACPI firmware_node"
```

### Step 3 — Drain workload

```bash
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s

# Also stop nvidia-persistenced if running (it prevents D3cold)
sudo systemctl stop nvidia-persistenced 2>/dev/null
sudo nvidia-smi -pm 0  # disable persistence mode
```

### Step 4 — Enable D3cold transition

```bash
# Enable runtime PM
echo auto | sudo tee /sys/bus/pci/devices/0000:03:00.0/power/control

# Force the device idle (sleep gives runtime PM time to transition)
sleep 30
```

### Step 5 — Verify D3cold reached

```bash
cat /sys/bus/pci/devices/0000:03:00.0/power_state
# Expected: D3cold (or D3hot if D3cold ACPI path missing)
```

### Step 6 — Force resume to D0

```bash
echo on | sudo tee /sys/bus/pci/devices/0000:03:00.0/power/control
# OR trigger via touching the device:
lspci -s 0000:03:00.0 -v
```

### Step 7 — Post-experiment state capture + diff

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E14
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E14
```

### Step 8 — Scale workload back up (only if PASS)

```bash
kubectl scale -n vllm deployment/vllm --replicas=1
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

## Predicted PASS signature

```
BAR1: 256M → 32G                  ← would be surprising
power_state: D3cold → D0
Bridge 03:00.0 pref: 288M → 33089M
```

## Predicted FAIL signature (expected)

```
BAR1: 256M → 256M (unchanged)
power_state: D3cold → D0  (transition happened)
Bridge 03:00.0 pref: 288M → 288M
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Device fails to enter D3cold | `power_state` stays D0 even after 30s idle | check nvidia-persistenced is stopped; check ACPI _PR3 |
| Device fails to resume from D3cold | `lspci` shows device but reads return 0xff | reboot required |
| AER cascade on resume | dmesg AER storm | scope-out; reboot |
| nvidia.ko crashes on D3cold | dmesg shows nvidia.ko BUG or NULL deref | reboot; do not retry without driver patch |

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

- Linux source: `drivers/pci/pci-driver.c::pci_pm_runtime_suspend`
- Linux source: `drivers/pci/pci.c::pci_set_power_state`
- ACPI 6.0 § 7.3.5 _PR3 (Power Resources for D3hot/D3cold)
