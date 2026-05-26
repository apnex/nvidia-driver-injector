# E19 — `pci=realloc=on,hpmmioprefsize=32G`

**Status:** PENDING
**Phase:** 2.3
**Risk:** LOW
**Cost:** ~3 min editing + 1 reboot + post-test
**Reversibility:** revert grub + reboot
**Last updated:** 2026-05-26

## Hypothesis

`hpmmioprefsize=32G` is a kernel cmdline parameter that hints to the PCI core: when a hotplug bridge needs a prefetchable MMIO window allocation, allocate at least 32GB. This addresses the **specific** failure mode: the default fallback window is 288MB because the kernel doesn't know in advance the device will request 32GB BAR1. With `hpmmioprefsize=32G`, the bridge window is pre-budgeted to fit.

Combined with E18's `pci=realloc=on`, this should cover both:
1. Pre-allocate 32G for hotplug windows (this experiment's addition)
2. Re-attempt if initial fails (E18's contribution)

Hypothesis: this combination is the **most likely PASS** in Section 3.

## Falsification gates

**PASS:** post-runtime-cable-cycle, BAR1=32G AND bridge prefetchable=32G.

**FAIL:** BAR1=256M after cable cycle.

**INCONCLUSIVE:** boot-time allocation breaks (the cmdline pre-budgets 32G but other state on the bus blocks it).

## Prerequisites

- E18 done (or skipped — this is the most-likely-PASS so prioritize this if time-constrained)
- GRUB editable

## Method

Follow `_SECTION-3-CMDLINE-WORKFLOW.md`. Specific parameter combination to ADD:

```
pci=realloc=on pci=hpmmioprefsize=32G
```

Or in compact form:
```
pci=realloc=on,hpmmioprefsize=32G
```

After reboot, same two-phase test as E18:

### Phase A — Cold-plug control

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E19-cold-control
grep 'size=32G' /var/log/mission-1-archaeology/E19-cold-control.baseline.txt
```

### Phase B — Runtime cable cycle test

```bash
# Enter broken-BAR1 state per _STARTING-STATE-RECIPE.md, then:
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E19
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E19
```

## Predicted PASS signature (most likely PASS in Section 3)

```
Phase A: BAR1=32G (control)
Phase B: BAR1: 256M → 32G after cable cycle
         Bridge 02:00.0 pref: 288M → 32G
```

## Predicted FAIL signature

```
Phase A: BAR1=32G
Phase B: BAR1=256M (cmdline didn't reach hotplug allocation path)
         OR bridge widened to 32G but BAR didn't re-negotiate
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Phase A breaks | BAR1 < 32G at cold boot — cmdline too aggressive for available PCI hole | revert; reboot |
| Phase B partial PASS (bridge widens, BAR doesn't) | bridge pref=32G but BAR1=256M | confirms two-layer problem; transitions to E16 territory |

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

- Linux source: `drivers/pci/setup-bus.c::pci_hp_bridge_mmio_pref_size`
- `Documentation/admin-guide/kernel-parameters.txt` pci=hpmmioprefsize
- E18 (preceding iteration)
- E20 (next: adds hpmmiosize)
