# E19 — `pci=realloc=on,hpmmioprefsize=32G`

**Status:** Run 1 DONE 2026-05-26 — Phase A NO-OP (no observable cold-plug effect), Phase B BLOCKED. Net impact: = NEUTRAL on operational state, +narrow on patch scope (only proves THIS parameter is redundant at cold-plug; does NOT prove other cmdline knobs are useless — see Patch design implications correction)
**Sub-mission:** n/a (Phase 2.3 archaeology)
**Phase:** 2.3
**Risk:** LOW (confirmed — no boot regression, no perf change)
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

### Run 1 — 2026-05-26 — Phase A = NO-OP, Phase B BLOCKED

**Conditions:**
- Driver version: 595.71.05-aorus.15
- nvidia-device-plugin + injector: both 1/1 throughout, no restarts during experiment
- Persistence mode: engaged
- PC-3 heartbeat: active
- Workload: drained
- Pre-reboot cmdline: `pci=realloc=on,resource_alignment=35@0000:03:00.0`
- Post-reboot cmdline: `pci=realloc=on,hpmmioprefsize=32G,resource_alignment=35@0000:03:00.0`

**Protocol followed:** As documented in Method. Edit GRUB → grub2-mkconfig → reboot → verify cmdline → capture state.

**Result — Phase A (cold-plug control):** = **NO-OP**

The parameter is silently accepted by the kernel (visible in `/proc/cmdline`, no errors in dmesg) but produces **no observable change** in bridge window allocation at cold-plug compared to the E18 baseline (which had only `pci=realloc=on`):

| State | E18 baseline (before this experiment) | E19 post-reboot |
|---|---|---|
| BAR1 | 32 GiB | 32 GiB (unchanged) |
| Bridge 03:00.0 prefetchable | 33089M | 33089M (unchanged) |
| Bridge 02:00.0 prefetchable | 65856M | 65856M (unchanged) |
| Root port 00:07.0 prefetchable | 65856M | 65856M (unchanged) |
| Sub-bridges 03:01/02/03 prefetchable | 10922M each | 10922M each (unchanged) |
| nvbandwidth H2D / D2H / H2D-bidir | 2.84 / 3.29 / 2.71 GB/s | 2.84 / 3.29 / 2.71 GB/s (bit-identical) |

**Result — Phase B (runtime cable cycle test):** ⏸ BLOCKED (same reason as E18 — cannot safely produce broken-BAR1)

**Diff highlights** (from `get-pci-stats.sh --diff E19-Run1`):

```
cmdline:  + hpmmioprefsize=32G,
boltctl authorized timestamp:  updated (just shows reboot happened)
/dev/nvidia* mtimes:           updated (driver re-loaded post-reboot)
nvidia-driver-injector restart count: 2→3 (this reboot)
nvidia-device-plugin restart count:  3→4 (this reboot)
Bridge windows section:        UNCHANGED
PCI tree structure:            UNCHANGED
AER counters:                  UNCHANGED (no new errors)
```

**Anomalies / unexpected observations:**

1. **The "most-likely-PASS in Section 3" prediction was wrong on this hardware.** Per E19's own predicted-PASS-signature section (citing LF forum analysis), the expected outcome was bridge windows expanding to 32G+. They did NOT. This isn't a hardware fault — it's that the kernel's existing boot-time allocator ALREADY produces the maximum bridge windows possible given the host's PCI address space (33089M on 03:00.0, 65856M upstream). The `hpmmioprefsize` parameter would only matter if the kernel was choosing to allocate LESS than 32G at boot for some policy reason — it isn't.

2. **Sub-bridge prefetchable allocations were already 10922M in E18 baseline** (not zero as I misremembered intra-conversation). The E11 Run 1 dmesg messages about sub-bridge windows "failed to assign" were specifically about I/O windows, not prefetchable memory. So the visible cmdline effects from E18 were entirely on the I/O resource type.

3. **Perf parity confirmed** — nvbandwidth bit-identical to all prior runs (E11, E18, cold-plug aorus.14 baseline). Strong evidence the parameter doesn't affect anything tunnel-bandwidth-relevant.

**Conclusion — net impact: = NEUTRAL on operational state, +narrow on patch scope:**

E19 Run 1 produces a narrow patch-design observation. The kernel's boot-time allocator achieves 33089M on bridge 03:00.0 without any hint, and adding `hpmmioprefsize=32G` doesn't change this. So at minimum: the future corrective patch's runtime allocation logic does not require a size hint to produce the right window size; the boot-time path already proves the allocator has access to the necessary information.

**A broader claim than that requires more work.** Specifically: whether the runtime hot-plug fallback (288M) is reachable via cmdline tuning — and therefore whether the userspace mitigation lane should be considered closed — is NOT answered by E19 alone. That conclusion requires either a code-level audit of the runtime hot-plug allocation path's cmdline-controllable knobs, OR exhaustive testing of remaining Section 3 parameters (E20, E21, E22, E24).

Correction logged 2026-05-26 after review identified the previous "eliminates the cmdline mitigation lane" framing as an unsupported inferential leap from a single negative datapoint. See `../pci-cmdline-audit.md` (pending) for the audit that will properly bound this claim.

## Patch coverage analysis

Not stress-tested in Run 1 (no failure mode exercised). The cmdline parameter is upstream Linux PCI code, not our driver patches.

## Patch design implications

**Operational result with narrow patch-scope value.** Captured in `E27-pci-core-patch.md` → Patch design implications.

**What this run actually supports:**

- ✓ `pci=hpmmioprefsize=32G` specifically is a no-op at cold-plug on this hardware (n=1)
- ✓ The kernel's existing boot-time allocator achieves 33089M on bridge 03:00.0 without any hint
- ✓ This single parameter does not change cold-plug allocation behavior

**What it does NOT support (correction 2026-05-26 after review):**

- ✗ ~~"No cmdline parameter can fix runtime hot-plug fallback"~~ — This sweeping claim was an inferential overreach from a single negative datapoint. The previous commit asserted this elimination of the entire userspace mitigation lane; that's not what the data shows.
- A proper "no cmdline helps" claim requires either: (a) code-level audit of `drivers/pci/setup-bus.c::__assign_resources_sorted` + hot-plug allocation callers, enumerating every cmdline-controllable knob affecting the runtime hot-plug path; OR (b) exhaustive testing of remaining cmdline variants (E20 `hpmmiosize`, E21 `hpmemsize` — structurally different syntax, E22 `pcie_aspm=off` — different mechanism, E24 `resource_alignment` variants). E19 tested ONE parameter.

**What the run DOES contribute (narrow positive):**

- The kernel's boot-time allocator clearly can produce ≥ 32G windows when the device is present at cold-plug, WITHOUT any size hint. Whatever mechanism the boot-time allocator uses, it does not require external sizing direction from cmdline parameters.
- Therefore: a future patch that triggers boot-time-style allocation logic at hot-plug events should likewise not need a hint to produce the right size. This is one design-direction insight (the patch invokes existing capability rather than introducing new sizing).
- Does NOT eliminate the possibility that some OTHER cmdline parameter helps the existing hot-plug allocation path. That remains an open question gated on the audit / further experiments.

Memory: [[feedback_io_vs_prefetchable_realloc_asymmetry_2026_05_26]] (E18 finding) and [[feedback_single_datapoint_inferential_overreach_2026_05_26]] (today's correction) bear on this.

See `../pci-cmdline-audit.md` (pending) for the code-level enumeration that would convert today's narrow result into a stronger scope-narrowing claim.

## Open follow-ups

- [ ] **E20 (`+hpmmiosize=256M`)** — adds non-prefetchable hint. Likely also no-op for the same reason E19 was, but worth confirming pattern.
- [ ] **E22 (`+pcie_aspm=off`)** — different parameter type; might affect runtime allocation behavior via link-state. Worth running.
- [ ] **E24 (resource_alignment size variants)** — could probe whether the existing param's alignment value affects re-allocation behavior.
- [ ] **Phase B test once broken-BAR1 producer exists** — currently blocked.
- [ ] **Consider skipping E20-E21** — given hpmmioprefsize is a no-op, the analogous hpmmiosize and hpmemsize parameters are also likely no-ops. Could drop those experiments from the plan to save reboots, OR could run them to confirm the pattern.

## Forensic bundles

| Run | Bundle | Size | Notes |
|---|---|---|---|
| Run 1 pre | `/var/log/mission-1-archaeology/E19-Run1/pre.tar.gz` | ~310 KB | E18-state captured before GRUB edit + reboot |
| Run 1 post | `/var/log/mission-1-archaeology/E19-Run1/post.tar.gz` | ~310 KB | Post-reboot ready state |
| Run 1 nvbandwidth | `/var/log/mission-1-archaeology/E19-Run1/nvbandwidth-postboot.txt` | 4 KB | Confirms bit-identical perf parity |

## Cross-references

- Linux source: `drivers/pci/setup-bus.c::pci_hp_bridge_mmio_pref_size`
- `Documentation/admin-guide/kernel-parameters.txt` pci=hpmmioprefsize
- E18 (preceding iteration)
- E20 (next: adds hpmmiosize)
