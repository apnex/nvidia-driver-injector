# E22 — `pci=realloc=on,hpmmioprefsize=32G + pcie_aspm=off`

**Status:** PENDING
**Phase:** 2.3
**Risk:** LOW (perf impact only; ASPM is power-saving)
**Cost:** ~3 min editing + 1 reboot + post-test
**Reversibility:** revert grub + reboot
**Last updated:** 2026-05-26

## Hypothesis

ASPM (Active State Power Management) is the PCIe link-power-management feature that puts links into low-power states (L0s, L1) when idle. The production cmdline currently has `pcie_aspm.policy=performance` (i.e., ASPM is on but biased to performance). Hypothesis: ASPM interaction with hotplug bridge allocation may interfere — the link may be in L1 when the kernel attempts re-allocation, and the link state transition adds latency or signaling differences that cause allocation to fail. Disabling ASPM entirely (`pcie_aspm=off`) eliminates this variable.

## Falsification gates

**PASS:** post-runtime-cable-cycle, BAR1=32G — confirming ASPM was interfering.

**FAIL:** BAR1=256M — ASPM is not the differentiator.

## Prerequisites

- E19 done (this experiment adds `pcie_aspm=off` to the E19 baseline)
- GRUB editable

## Method

Follow `_SECTION-3-CMDLINE-WORKFLOW.md`. Modify cmdline:
- REMOVE: `pcie_aspm.policy=performance`
- ADD: `pcie_aspm=off`
- KEEP from E19: `pci=realloc=on pci=hpmmioprefsize=32G`

After reboot, two-phase test:

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E22-cold-control
# enter broken-BAR1 state per recipe
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E22
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E22
```

## Predicted PASS signature

```
Phase B: BAR1=32G — disabling ASPM allowed the allocation to succeed
```

## Predicted FAIL signature

```
Phase B: BAR1=256M — ASPM not the differentiator
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Disabling ASPM increases idle power | nvidia-smi shows higher idle wattage | informational; not a recovery action |
| Boot allocation behavior changes | new failure mode emerges | revert; reboot |

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

- Linux source: `drivers/pci/pcie/aspm.c`
- `Documentation/admin-guide/kernel-parameters.txt` pcie_aspm
- E19 (preceding without ASPM change)
- Related memory: `feedback_bridge_cap_needs_both_knobs` (link policy interactions)
