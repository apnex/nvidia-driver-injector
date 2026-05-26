# E21 — `pci=realloc=on,hpmemsize=33G`

**Status:** PENDING
**Phase:** 2.3
**Risk:** LOW
**Cost:** ~3 min editing + 1 reboot + post-test
**Reversibility:** revert grub + reboot
**Last updated:** 2026-05-26

## Hypothesis

`hpmemsize=N` is the **combined** prefetchable + non-prefetchable bridge window budget (older naming, alternative to `hpmmioprefsize`/`hpmmiosize`). Hypothesis: setting `hpmemsize=33G` (32G prefetchable + 256M non-pref + headroom) covers the combined budget in one parameter, possibly behaving differently from the split parameters (E20).

`hpmemsize=N` REPLACES the prior E18-E20 parameters (mutually exclusive).

## Falsification gates

**PASS:** post-runtime-cable-cycle, BAR1=32G.

**FAIL:** BAR1=256M; the combined budget didn't unlock the allocation.

## Prerequisites

- E19/E20 result understood (informs whether combined-budget syntax produces different outcome)
- GRUB editable

## Method

Follow `_SECTION-3-CMDLINE-WORKFLOW.md`. **REPLACE** any prior `hpmmio*` params with:

```
pci=realloc=on,hpmemsize=33G
```

After reboot, two-phase test.

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E21-cold-control
# enter broken-BAR1 state per recipe
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E21
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E21
```

## Predicted PASS signature

```
Phase B: BAR1=32G after cable cycle
```

## Predicted FAIL signature

```
Phase B: BAR1=256M
```

## Known failure modes / recovery

Same as E18-E20.

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

- Linux source: `drivers/pci/setup-bus.c::pci_hp_bridge_mem_size`
- E19 (split-param prefetchable variant)
- E20 (split-param both)
- This is an alternative axis: combined budget vs split budgets
