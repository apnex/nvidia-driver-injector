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

(Filled in once body-of-evidence supports a design decision.)

## Open follow-ups

- [ ] (Populated based on run results.)

## Forensic bundles

| Run | Bundle path | Size | Notes |
|---|---|---|---|
|     |             |      |       |

## Cross-references

- Linux source: `drivers/pci/setup-bus.c::__assign_resources_sorted`
- Linux source: `drivers/pci/setup-bus.c::__pci_setup_bridge_mmio_pref`
- E25 (Miroshnichenko v9 — same problem class, different patch approach)
- E26 (out-of-tree module — narrower-scope alternative)
- `feedback_no_premature_upstream_filing` — patch must be tested before any upstream submission
