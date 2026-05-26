# E18 — `pci=realloc=on` alone

**Status:** Run 1 DONE 2026-05-26 — Phase A PASS (cmdline safe), Phase B BLOCKED (need safe broken-BAR1 producer)
**Sub-mission:** n/a (Phase 2.3 archaeology)
**Phase:** 2.3
**Risk:** LOW (confirmed — no boot regression)
**Cost:** ~3 min editing + 1 reboot + post-test
**Reversibility:** revert grub + reboot
**Last updated:** 2026-05-26

## Hypothesis

The kernel cmdline `pci=realloc=on` enables `pci_realloc_enable=PCI_REALLOC_ENABLE` in `drivers/pci/pci.c`, which causes the PCI subsystem to re-attempt resource assignment when initial allocation fails. Hypothesis: enabling realloc-on may cause the PCI core to widen bridge windows when downstream BAR sizes exceed the budget — potentially fixing the broken-BAR1 issue at boot, and possibly also when triggered via remove+rescan.

**Note from LF forum discussion** (audit/tb-pcie/CONSOLIDATED.md Q3): `pci=realloc=on` alone has been **tested by users** and reported insufficient. This experiment **confirms locally** so we have a documented baseline.

## Falsification gates

**PASS:** post-reboot-with-cmdline AND post-runtime-cable-cycle, BAR1=32G.

**FAIL:** post-runtime-cable-cycle, BAR1=256M (same as without cmdline). LF forum corroboration confirmed.

**INCONCLUSIVE:** boot-time allocation breaks unexpectedly with cmdline present.

## Prerequisites

- Working production baseline (BAR1=32G via cold-plug)
- GRUB editable

## Method

Follow `_SECTION-3-CMDLINE-WORKFLOW.md`. Specific parameter to ADD to `GRUB_CMDLINE_LINUX`:

```
pci=realloc=on
```

After reboot:

### Phase A — Cold-plug control

Verify BAR1=32G is still achievable at boot with the new cmdline (control test):

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E18-cold-control
grep 'size=32G' /var/log/mission-1-archaeology/E18-cold-control.baseline.txt
# Expected: PASS — cmdline shouldn't break cold-plug
```

### Phase B — Runtime cable cycle test

```bash
# 1. Enter broken-BAR1 state via cable cycle (per _STARTING-STATE-RECIPE.md)
# 2. Capture E18 snapshot
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E18
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E18
```

## Predicted PASS signature

```
Phase A (cold control): BAR1=32G (unchanged from baseline)
Phase B (runtime cycle): BAR1: 256M → 32G after cable cycle
                        → cmdline made hotplug allocation succeed
```

## Predicted FAIL signature (likely per LF forum)

```
Phase A: BAR1=32G (control passes)
Phase B: BAR1=256M after cable cycle (same as without cmdline)
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Phase A breaks (boot allocation fails) | BAR1=64M at boot | revert cmdline; reboot; document INCONCLUSIVE |
| Phase B AER cascade | dmesg shows AER storm post-cable-cycle | reboot; this surfaces a different failure mode than the matrix targets |

## Per-run records

### Run 1 — 2026-05-26 — Phase A PASS, Phase B BLOCKED

**Conditions:**
- Driver version: 595.71.05-aorus.15
- nvidia-device-plugin: running (1/1 throughout — survived reboot)
- Persistence mode: engaged (post-injector-startup)
- PC-3 heartbeat: active
- Workload: drained (no vLLM)
- Pre-reboot cmdline: `... pci=resource_alignment=35@0000:03:00.0 ...`
- Post-reboot cmdline: `... pci=realloc=on,resource_alignment=35@0000:03:00.0 ...`
  (combined via kernel `pci=` comma syntax to coexist with the existing resource_alignment param)

**Protocol followed:** As documented in Method. Edit GRUB → grub2-mkconfig → reboot → verify cmdline → capture state.

**Result — Phase A (cold-plug control):** ✓ **PASS**
- BAR1 = 32 GiB (preserved)
- Bridge 03:00.0 prefetchable = 33089M (unchanged from no-cmdline baseline)
- Bridge 02:00.0 prefetchable = 65856M (unchanged)
- Driver loaded and bound correctly
- nvbandwidth bit-identical to pre-cmdline baseline: H2D=2.84, D2H=3.29, H2D-bidir=2.71 GB/s

**Result — Phase B (runtime cable cycle test):** ⏸ **BLOCKED**
- Cannot safely produce broken-BAR1 starting state per E11 Run 1 finding (software remove preserves bridge windows; cable yank wedges per E07 Run 2)
- Phase B remains untested until either (a) corrective patch makes cable yank survivable, or (b) alternative broken-BAR1 producer is identified

**Diff highlights** (from `get-pci-stats.sh --diff E18-Run1`):

```
cmdline:  + pci=realloc=on,
GPU I/O ports:           3000-307f → 5000-507f   (range moved)
Bridge 0000:00:07.0 I/O: 3000-3fff [size=4K] → 5000-8fff [size=16K]  ← EXPANDED 4×
Bridge 02:00.0 I/O:      3000-3fff [size=4K] → 5000-8fff [size=16K]  ← EXPANDED
Bridge 03:00.0 I/O:      (similar expansion through TB hierarchy)
Bridge prefetchable windows:  UNCHANGED (still 33089M / 65856M)
```

**Anomalies / unexpected observations:**

1. **I/O window expansion is real and active.** `pci=realloc=on` DID cause the kernel to widen I/O port windows on the TB bridge hierarchy (size=4K → size=16K on the root port). The bridges below 00:07.0 inherited the wider window from the parent allocation.

2. **Prefetchable memory window UNCHANGED.** The 33089M prefetchable window allocation that hosts BAR1 was identical with vs without `pci=realloc=on`. This confirms the LF forum analysis: realloc=on affects I/O space (where unallocated headroom exists) but not the prefetchable allocation pass that the BAR1=32G case needs at runtime hot-plug time.

3. **No regression.** Both nvbandwidth and BAR1 size + driver function are bit-identical to pre-cmdline baseline. `pci=realloc=on` is a safe-to-add parameter on this hardware.

**Forensic bundles:**
- Pre-experiment: `/var/log/mission-1-archaeology/E18-Run1/pre.tar.gz` (316 KB)
- Post-reboot: `/var/log/mission-1-archaeology/E18-Run1/post.tar.gz` (368 KB)
- nvbandwidth: `/var/log/mission-1-archaeology/E18-Run1/nvbandwidth-postboot.txt`
- Stats delta: `E18-Run1.baseline.txt` + `.snapshot.txt` in same dir

**Conclusion:**

E18 Run 1 confirms **two things, leaves the primary test blocked, surfaces one informative behavior:**

1. ✓ **`pci=realloc=on` is a safe boot parameter** on this hardware — does not regress cold-plug allocation, does not affect nvbandwidth measurements, does not change driver behavior.
2. ✓ **The parameter DOES take effect** — observable widening of I/O port windows in the TB bridge hierarchy (4K → 16K on root port).
3. ⏸ The hypothesis-of-record (does `pci=realloc=on` help runtime hot-plug bridge re-allocation?) **remains UNTESTED** because we cannot safely produce the broken-BAR1 starting state to test recovery from.
4. ℹ️ The parameter affects I/O space allocation, NOT prefetchable memory allocation. The "runtime hot-plug fallback gives 288M prefetchable instead of 32G+" failure mode would need a parameter that targets prefetchable memory allocation specifically — that's E19's `hpmmioprefsize=32G` territory.

This makes E19 the more likely-PASS variant within Section 3 (as predicted in E19's predicted-PASS-signature section).

## Patch coverage analysis

Not stress-tested in Run 1 (no failure mode exercised). The cmdline parameter is upstream Linux PCI code, not our driver patches. No driver-level behavior observed.

## Patch design implications

If a future runtime-hot-plug recovery path uses `pci=realloc=on` semantics internally (re-attempt allocation when bridge windows insufficient), the kernel call site is:

```
drivers/pci/setup-bus.c::pci_assign_unassigned_resources    (the realloc-aware entry)
drivers/pci/setup-bus.c::__assign_resources_sorted          (the fallback path inside)
```

This is the same call site noted in E27 (PCI core patch experiment). Today's observation that realloc=on works for I/O space but not prefetchable space suggests `__assign_resources_sorted` differentiates between resource types — a corrective patch would need to make the prefetchable path equally responsive to realloc semantics.

Not yet a design — just a note that the boundary between "what realloc=on touches" and "what it doesn't" maps to specific kernel code.

## Open follow-ups

- [ ] **E19 next** (`+hpmmioprefsize=32G`) — most-likely-PASS variant per LF forum analysis. Pre-budgets prefetchable bridge window at 32G at boot time, which is the missing piece E18 confirmed.
- [ ] **Phase B test once broken-BAR1 producer exists** — currently blocked.
- [ ] **n≥2 reproductions of Phase A** — confirm I/O window expansion is deterministic.

## Forensic bundles

| Run | Bundle | Size | Notes |
|---|---|---|---|
| Run 1 pre | `/var/log/mission-1-archaeology/E18-Run1/pre.tar.gz` | 316 KB | State immediately before GRUB edit + reboot |
| Run 1 post | `/var/log/mission-1-archaeology/E18-Run1/post.tar.gz` | 368 KB | State after post-reboot injector ready |
| Run 1 nvbandwidth | `/var/log/mission-1-archaeology/E18-Run1/nvbandwidth-postboot.txt` | 4 KB | Confirms bit-identical perf parity |

## Cross-references

- Linux source: `drivers/pci/pci.c::pci_realloc_setup`
- `Documentation/admin-guide/kernel-parameters.txt` pci=realloc
- LF forum thread: linked from audit/tb-pcie/CONSOLIDATED.md Q3
- E19 (next iteration adds hpmmioprefsize)
