# E25 — Cherry-pick Miroshnichenko v9 "movable BARs"

**Status:** BLOCKED (needs kernel build environment setup)
**Phase:** 2.5
**Risk:** MEDIUM (custom kernel, narrow blast radius if isolated to non-production host first)
**Cost:** 1-2 days (porting + build + boot test)
**Reversibility:** boot to previous kernel
**Last updated:** 2026-05-26

## Hypothesis

In December 2020, Sergey Miroshnichenko submitted a kernel patch series v9 titled "PCI: Allow BAR movement after enumeration" addressing exactly this class of problem: hotplug bridge windows can't expand because BAR sizes are committed at enumeration time. The series introduces "movable BARs" that allow runtime resizing. The series **stalled** (didn't merge) but the patches exist on lkml.

Hypothesis: cherry-picking the v9 series onto the current 7.0.x kernel and rebuilding may allow the hotplug bridge window to expand to fit BAR1=32G on cable replug.

**Status:** BLOCKED until we have a kernel build environment outside the production node (the production node should not host kernel build iterations). Two options:
1. Set up a separate Fedora 44 VM with the same kernel sources for build iteration
2. Use the production node but build into a test partition; keep production kernel as fallback boot entry

## Falsification gates

**PASS:** patched kernel boots; post-runtime-cable-cycle BAR1=32G.

**FAIL:** patched kernel boots; BAR1=256M after cycle (movable-BARs feature exists but doesn't trigger on TB hotplug events).

**INCONCLUSIVE:** patched kernel doesn't boot (patch series doesn't port cleanly to 7.0.x); or boots with new failure modes.

## Prerequisites

- BLOCKED: need kernel build env
- LKML archive access to retrieve Miroshnichenko v9 series
- Fedora 44 kernel source tree (matching production kernel version)
- Patch series understanding (read all 24+ patches)

## Method (when unblocked)

### Step 1 — Retrieve patch series

```bash
# Fetch from LKML archive
# Series cover letter: https://lore.kernel.org/lkml/20201202174011.13.... (find exact URL)
# Patches typically 1/24 through 24/24

# Save to local
mkdir -p ~/kernel-patches/miroshnichenko-v9/
cd ~/kernel-patches/miroshnichenko-v9/

# Use b4 to fetch the series:
b4 am 20201202174011.<message-id>@example.com  # adjust message ID
```

### Step 2 — Set up build environment

```bash
# Pull Fedora 44 kernel source
sudo dnf install rpmdevtools kernel-devel kernel-headers
rpmdev-setuptree
cd ~/rpmbuild/SOURCES/
curl -O <fedora-kernel-srpm-url>
rpm -ivh kernel-*.src.rpm

cd ~/rpmbuild/SPECS/
rpmbuild -bp kernel.spec  # extract source

cd ~/rpmbuild/BUILD/kernel-*/linux-*/
```

### Step 3 — Apply Miroshnichenko series

```bash
git init  # if not already
git am ~/kernel-patches/miroshnichenko-v9/*.patch
# Resolve any conflicts (Linux 6.19→7.0 source review notes some PCI subsys churn)
```

### Step 4 — Build kernel

```bash
make olddefconfig
make -j$(nproc) bzImage modules
sudo make modules_install
sudo make install
# Confirm new kernel listed in `grubby --info=ALL`
```

### Step 5 — Boot patched kernel + run two-phase test

```bash
# Set patched kernel as default boot
sudo grubby --set-default-index=0  # adjust index
sudo systemctl reboot

# After reboot, confirm running patched kernel
uname -r

# Phase A: cold control
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E25-cold-control

# Phase B: enter broken-BAR1 state, capture
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E25
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E25
```

### Step 6 — Revert to stock kernel if FAIL

```bash
sudo grubby --set-default-index=1  # stock kernel
sudo systemctl reboot
```

## Predicted PASS signature

```
Patched kernel boots; uname -r shows custom suffix
Phase B: BAR1: 256M → 32G after cable cycle
         The movable-BARs feature kicked in on the hotplug event
```

## Predicted FAIL signature

```
Patched kernel boots
Phase B: BAR1: 256M → 256M
         Movable-BARs feature requires explicit trigger that TB hotplug doesn't fire
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Patch series doesn't apply cleanly | git am conflicts | manual conflict resolution; if too divergent, port forward; or stop here |
| Patched kernel doesn't boot | grub falls back; or panic at boot | boot to stock kernel; rebuild without specific problem patch |
| Boots but new regressions | dmesg shows BUG / OOPS | revert; investigate; possibly file bug or skip |

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

- Miroshnichenko v9 series: https://lore.kernel.org/lkml/ (search "PCI: Allow BAR movement")
- Kernel 7.0 source review: `project_kernel_6_19_to_7_0_source_review` memory
- E26 (custom module — narrower-scope alternative)
- E27 (PCI core patch — most invasive)
