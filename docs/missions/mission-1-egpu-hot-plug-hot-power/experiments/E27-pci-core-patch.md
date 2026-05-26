# E27 — Patch drivers/pci/setup-bus.c::__assign_resources_sorted

**Status:** BLOCKED (needs kernel build env + understanding of PCI core resource assignment)
**Phase:** 2.5
**Risk:** HIGH (modifying PCI core — affects all PCI devices, not just GPU)
**Cost:** 3-5 days (analysis + patch + build + test)
**Reversibility:** boot to previous kernel
**Last updated:** 2026-05-26

## Hypothesis

If E25 (Miroshnichenko) doesn't fit and E26 (custom module) FAILs because the in-kernel function short-circuits on already-assigned buses, the deepest leverage point is the PCI core's resource assignment logic in `drivers/pci/setup-bus.c::__assign_resources_sorted`. This function handles the fallback budget when initial assignment fails. The "fallback" path is what assigns 288MB instead of 32GB during runtime hotplug.

Hypothesis: a small, surgical patch to this fallback path can change the budget calculation to honor the device's RBAR capability **even on hotplug-after-boot** events.

**Status:** BLOCKED — same prerequisites as E25 + much deeper analysis required.

## Falsification gates

**PASS:** patched kernel boots; post-cable-cycle BAR1=32G; no regressions on other PCI devices (notably the NUC's onboard NVMe / Ethernet / USB controllers).

**FAIL:** patched kernel boots; BAR1=256M; OR regressions appear.

**INCONCLUSIVE:** patched kernel doesn't boot; or patch breaks other devices.

## Prerequisites

- BLOCKED: kernel build env (E25 prereq)
- BLOCKED: deep understanding of `__assign_resources_sorted` + the "movable" vs "immovable" resource state machine
- Regression test suite for other PCI devices (NVMe, Ethernet, USB, audio)
- Optional: separate test host to avoid risking production

## Method (when unblocked)

### Step 1 — Analyze the fallback path

```bash
# Read the function in full
grep -n "__assign_resources_sorted" /root/kernel-src/drivers/pci/setup-bus.c

# Trace the fallback budget calculation:
#   - When does it run? (pci_bus_assign_resources_called_with_fail_head argument)
#   - What inputs control the budget?
#   - Where does it commit the narrowed window?

# Key concepts:
#   - "Required" vs "Optional" resources
#   - "fail_head" list (resources that couldn't fit)
#   - The 2nd pass that drops failed resources to free their budget
```

### Step 2 — Design the patch

The minimal change: when an RBAR-capable device's BAR is in `fail_head`, instead of dropping the BAR, expand the bridge window. Pseudo-patch:

```c
/* In __assign_resources_sorted fallback path */
list_for_each_entry_safe(fail_res, tmp, &fail_head, list) {
    if (pci_rebar_get_current_size(fail_res->dev, fail_res->resno) > 0) {
        /* Device requests resizable BAR; try expanding bridge window
         * instead of dropping this BAR. */
        struct pci_bus *bus = fail_res->dev->bus;
        if (try_expand_bridge_window(bus, fail_res->res, fail_res->size)) {
            pr_info("pci: expanded bridge window for %s BAR%d\n",
                    pci_name(fail_res->dev), fail_res->resno);
            continue;  /* keep this BAR; don't drop */
        }
    }
    /* Existing fallback behavior */
    drop_assignment(fail_res);
}
```

`try_expand_bridge_window` is the new helper — needs to:
- Find available parent-bus space
- Re-program bridge memory base/limit registers
- Re-call assignment for the bus

### Step 3 — Build + boot

Same as E25 method steps 3-5.

### Step 4 — Test PASS criterion

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E27-cold-control
# Enter broken-BAR1 state per recipe
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E27
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E27
```

### Step 5 — Regression test other PCI devices

```bash
# NVMe
sudo dmesg | grep -i nvme | tail
sudo nvme list

# Ethernet
ip link show
ethtool eno1

# USB
lsusb
dmesg | grep -i usb | tail

# Audio
aplay -l
```

Compare to baseline (stock kernel) regression set. Any device failure = FAIL even if BAR1 PASS.

### Step 6 — Long-soak test

If PASS + no regressions: leave patched kernel running for ≥24 hours under workload to surface latent issues.

### Step 7 — Revert to stock kernel

Regardless of outcome, revert to stock kernel for production. Patch is exploratory — would need formal upstream submission per `feedback_no_premature_upstream_filing` before being considered for permanent adoption.

## Predicted PASS signature

```
Phase B: BAR1: 256M → 32G after cable cycle
Regression tests: all other devices PASS
24-hour soak: no new issues
→ candidate for upstream submission
```

## Predicted FAIL signature

```
Phase B: BAR1: 256M (the fallback path is different layer than expected)
OR
Patch breaks other PCI devices (regression)
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Patch breaks NVMe boot | system unbootable | recovery boot to stock kernel; remove patched kernel |
| Patch causes panic in fallback | kernel panic at boot or during enumeration | recovery; revise patch |
| Patch expands wrong window | wrong bridge widens; conflicts with other device | revise to be more selective |
| Side-effect on other RBAR-capable devices | iGPU or other GPU BAR1 changes unexpectedly | scope patch to specific BDF |

## Per-run records

> One subsection per execution. Body-of-evidence builds across runs.

### Run 1 — pending

(Filled in when run. Conditions / Protocol deviations / Result / Diff highlights / Forensic bundle / Anomalies / Conclusion.)

## Patch coverage analysis

(Filled in if a run surfaces driver-level behavior.)

## Patch design implications

> Body-of-evidence accumulates here from related experiments. Each entry below cites the run that produced the insight.

### Asymmetry: I/O space vs prefetchable memory under `pci=realloc=on` (from E18 Run 1, 2026-05-26)

**The observation.** E18 Run 1 added `pci=realloc=on` to the GRUB cmdline and rebooted. Two measurable effects:

1. ✓ Bridge I/O windows widened — root port 0000:00:07.0 went `4K → 16K`, cascade through TB hierarchy. The realloc walker found unallocated headroom in the host's 64KB I/O pool and expanded the bridge windows accordingly.
2. ✗ Bridge prefetchable memory windows UNCHANGED — 03:00.0 stayed at 33089M, 02:00.0 at 65856M. Identical to the no-cmdline baseline.

**What this tells us about `__assign_resources_sorted`.** The function differentiates between resource types. The I/O re-allocation path IS responsive to `realloc=on`; the prefetchable memory re-allocation path is not (or has a different trigger). This is the design-level asymmetry that E27's corrective patch needs to address.

**Two patch shapes both follow from this observation:**

- **Option A — parallel parameter / mechanism.** Introduce `pci=realloc-pref=on` (or equivalent flag) that explicitly opts into prefetchable re-allocation, modelled on the existing realloc-on code path. Smaller blast radius (opt-in), narrower review surface. Userspace-controllable.
- **Option B — extend the existing walker.** Modify `__assign_resources_sorted` so the realloc-on flag triggers re-allocation for ALL resource types (I/O, non-prefetchable mem, prefetchable mem) uniformly. Larger blast radius (changes default behavior of an existing parameter), needs careful regression coverage on non-eGPU PCI devices. But: the upstream community might prefer this since it's the "fix the asymmetry" framing rather than the "add another flag" framing.

**Common code structure for both options** (sketch — needs verification against actual 7.0.x source):

```c
/* In __assign_resources_sorted's fallback path (or a new wrapper) */
struct list_head fail_head_pref;  /* prefetchable resources that failed assignment */
list_for_each_entry_safe(fail_res, tmp, &fail_head_pref, list) {
    /* If realloc enabled for prefetchable (Option A: a new flag;
     * Option B: the existing pci_realloc_enable flag covers this too): */
    if (prefetchable_realloc_enabled(...)) {
        struct pci_bus *bus = fail_res->dev->bus;
        if (try_expand_bridge_prefetchable_window(bus, fail_res->res, fail_res->size)) {
            pr_info("pci: expanded prefetchable bridge window for %s BAR%d\n",
                    pci_name(fail_res->dev), fail_res->resno);
            continue;
        }
    }
    drop_assignment(fail_res);
}
```

**Why E18's data strengthens confidence in this design direction:**

- The pattern of "realloc finds unallocated headroom → widens bridge window" IS proven to work (I/O case).
- The bug is essentially "this pattern wasn't extended to prefetchable memory."
- The fix is therefore additive (apply existing pattern to additional resource type), not architecturally novel.

**Open dependency before this can ship:** still need an actual broken-BAR1 producer to validate that the patch ALSO fixes the runtime hot-plug case (not just cold-plug). Currently blocked on either the surprise-removal teardown patch (E1 extension / new A6) OR an alternative broken-BAR1 producer.

### Surprise-removal teardown (from E07 Run 2, 2026-05-26)

See `E07-cable-replug-drain-first.md` Patch design implications section. The TB-unplug-aware teardown patch is a separate, parallel patch effort to E27. Together they would form a coherent runtime-hot-plug-hardening pair:

- TB-unplug-aware teardown → produces broken-BAR1 state safely (instead of wedging)
- E27 corrective patch → recovers from broken-BAR1 state automatically (or via explicit trigger)

### Boot-time allocator achieves target size without a hint (from E19 Run 1, 2026-05-26)

> ⚠️ **CORRECTION 2026-05-26:** the original framing of this section claimed E19's no-op result "eliminates the cmdline mitigation lane" and asserted the bug class as definitively "missing re-attempt, not missing hint." That was an inferential overreach from a single negative datapoint. The corrected version below preserves the narrow finding actually supported by the data. The broader scope-narrowing claim is deferred until the code audit (`../pci-cmdline-audit.md`, pending) and/or remaining Section 3 experiments produce supporting evidence.

**The observation.** E19 Run 1 added `pci=hpmmioprefsize=32G` (kernel hint: "size hotplug-capable bridges' prefetchable windows ≥ 32G at boot"). Result: **no observable change** to any bridge window vs the E18 baseline (which had `pci=realloc=on` only):

| State | E18 baseline | E19 (with hpmmioprefsize=32G) |
|---|---|---|
| Bridge 03:00.0 prefetchable | 33089M | 33089M (unchanged) |
| Bridge 02:00.0 prefetchable | 65856M | 65856M (unchanged) |
| Sub-bridges 03:01/02/03 | 10922M each | 10922M each (unchanged) |
| nvbandwidth | 2.84 / 3.29 / 2.71 GB/s | bit-identical |

**What this narrowly establishes:**

- ✓ The kernel's existing boot-time allocator already produces ≥ 32G prefetchable windows when the BAR1=32G device is present at cold-plug (33089M = 32G + overhead on the immediate parent bridge)
- ✓ This achievement does not require a `hpmmioprefsize` hint — the existing allocator has access to the necessary information by some other route (DEVICE_FLAG_HOTPLUG signal? PCI resource enumeration? — answered by the audit)
- ✓ Therefore: a future corrective patch that invokes the boot-time allocator at hot-plug time would not need to feed it a size hint to produce the right size

**What this does NOT establish (despite the previous version's overreach):**

- ✗ ~~"The bug is not 'missing size hint' — it's 'missing re-attempt'"~~ — too strong from this data alone
- ✗ ~~"Eliminates the userspace cmdline mitigation lane"~~ — only ONE cmdline parameter was tested; the parameter space is much larger
- A code-level audit is required to enumerate which cmdline knobs affect the runtime hot-plug allocation path (separate from the boot-time path), and whether any of them could redirect the allocator away from the 288M fallback. Until that audit completes, the runtime hot-plug fallback's relationship to cmdline parameters is not characterized.

**Refined patch design implications (the narrow version):**

- The boot-time allocation path **is** the reference implementation. Whatever code routes the kernel takes from `pci_assign_unassigned_root_bus_resources()` (or wherever boot-time enumeration kicks off) to the eventual 33089M assignment is the path the future patch should invoke at hot-plug events.
- Whether the patch needs to provide hints OR can rely on the boot-time logic's existing self-sizing depends on the audit findings. Today's E19 data is consistent with EITHER interpretation; it doesn't disambiguate.

**Still need (before final design):**

- The code audit (`../pci-cmdline-audit.md`) to enumerate runtime hot-plug cmdline knobs and characterize their effect on `__assign_resources_sorted`'s decision branches
- An actual broken-BAR1 reproduction with `__assign_resources_sorted` instrumented (bpftrace or strategic printk) to see exactly which fallback branch is taken at runtime hot-plug vs which branch boot takes
- Remaining Section 3 experiments (E20, E21, E22, E24) for empirical coverage of other cmdline parameters in this category

## Open follow-ups

- [ ] (Populated based on run results.)

## Forensic bundles

| Run | Bundle path | Size | Notes |
|---|---|---|---|
|     |             |      |       |

## Cross-references

- Linux source: `drivers/pci/setup-bus.c::__assign_resources_sorted`
- Linux source: `drivers/pci/setup-bus.c::__pci_setup_bridge_mmio_pref`
- Linux source: `drivers/pci/pci.c::pci_realloc_enable` (the global flag set by `pci=realloc=on`)
- E18 Run 1 — the I/O-vs-prefetchable asymmetry observation that informs E27's design
- E19 Run 1 — the "bug is not missing size hint" finding that narrows E27's design space (the patch must trigger re-allocation, not provide hints)
- E07 Run 2 — surprise-removal teardown patch (parallel patch effort; together with E27 forms a coherent runtime-hot-plug-hardening pair)
- E25 (Miroshnichenko v9 — same problem class, different patch approach)
- E26 (out-of-tree module — narrower-scope alternative)
- `feedback_no_premature_upstream_filing` — patch must be tested before any upstream submission
