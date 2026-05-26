# E24 — `pci=resource_alignment` size variants

**Status:** PENDING
**Phase:** 2.3
**Risk:** LOW-MEDIUM (resource_alignment affects boot allocation)
**Cost:** ~10 min per variant × 5 variants = ~1 hr
**Reversibility:** revert grub + reboot
**Last updated:** 2026-05-26

## Hypothesis

Production cmdline currently has `pci=resource_alignment=35@0000:03:00.0` which forces the GPU's resources to align on 2^35 = 32GB boundaries. This was added for cold-plug BAR1=32G stability. Hypothesis: changing the alignment size may interact with hotplug bridge allocation differently — e.g., smaller alignment (2^28 = 256MB) may match the current broken-state window perfectly and produce a stable-if-narrow result; larger alignment may force the kernel to use a larger budget at hotplug time.

## Falsification gates

**PASS (any size):** post-runtime-cable-cycle with that alignment, BAR1=32G.

**FAIL (all sizes):** alignment doesn't materially change hotplug allocation outcome.

## Prerequisites

- E19 done (informs baseline)
- GRUB editable

## Method

For each alignment size variant, follow `_SECTION-3-CMDLINE-WORKFLOW.md`:

### Variants to test

| Variant | resource_alignment value | 2^N | Meaning |
|---|---|---|---|
| E24a | `pci=resource_alignment=32@0000:03:00.0` | 2^32 = 4GB | minimum that fits old BAR1 |
| E24b | `pci=resource_alignment=33@0000:03:00.0` | 2^33 = 8GB | mid |
| E24c | `pci=resource_alignment=34@0000:03:00.0` | 2^34 = 16GB | mid |
| E24d | `pci=resource_alignment=35@0000:03:00.0` | 2^35 = 32GB | current production |
| E24e | `pci=resource_alignment=36@0000:03:00.0` | 2^36 = 64GB | overshoot |

### Per variant — same two-phase pattern as E18

```bash
# Phase A: cold-plug baseline
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E24-<variant>-cold

# Phase B: runtime cable cycle
# (enter broken-BAR1 state per recipe)
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E24-<variant>
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E24-<variant>
```

## Predicted PASS signature

```
For some alignment value (likely 35 or 36): BAR1: 256M → 32G after cycle
```

## Predicted FAIL signature

```
All variants: BAR1=256M after cycle
                  → resource_alignment affects only boot allocation, not hotplug
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| E24e (36) overshoots and boot allocation fails | BAR1 absent at boot | revert; reboot |
| Cold-plug works on all but hotplug works on none | confirms boot ≠ hotplug allocation paths | conclusion in summary |

## Per-variant results matrix

| Variant | Phase A | Phase B | Status |
|---|---|---|---|
| E24a (4GB align) | | | |
| E24b (8GB align) | | | |
| E24c (16GB align) | | | |
| E24d (32GB align — production) | | | |
| E24e (64GB align) | | | |

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

- Linux source: `drivers/pci/pci.c::pci_specified_resource_alignment`
- `Documentation/admin-guide/kernel-parameters.txt` pci=resource_alignment
- Related memory: production cmdline currently uses 35
