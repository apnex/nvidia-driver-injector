# MISSION-1 Phase 2 — Software-path archaeology matrix

> ⚠️ **RESOLVED / SUPERSEDED (2026-05-31).** This matrix's central question (H10 — does a software BAR1-recovery trigger exist) was **ANSWERED 2026-05-28**: `tools/fix-bar1.sh` is the trigger (= **E16** chip RBAR-CTRL write + **E2** pciehp slot-cycle). Exit-criterion (a) met. **E2–E24 are SUPERSEDED** (they searched for the trigger we found); **E27** (in-kernel) remains the target. Current status + priority live in [`experiment-register.md`](./experiment-register.md). This matrix is retained for the per-experiment protocols + numbering provenance.

**Purpose:** Exhaustively enumerate untested userspace + kernel mechanisms that might restore BAR1=32GB / bridge window=32GB+ on a TB-attached eGPU at runtime, without host reboot.

**Question we're answering:** Does **any** software-only path exist that triggers fresh PCIe bridge window allocation matching the device's actual ReBAR request? (H10 — **ANSWERED 2026-05-28 by `fix-bar1.sh`**; see banner above.)

**Status of H1 (cable replug → 32GB)**: FALSIFIED 2026-05-25 by E7. This doc is the follow-up.

**Canonical experiment registry.** This doc is the single source of truth for Phase 2 experiment **numbering + hypothesis + ordering**. Mission doc's experiment table cross-references this file.

**Per-experiment operational truth** (exact commands, predicted PASS/FAIL signatures, recovery procedures, actual results) lives in `docs/phase-2-experiments/` — one file per experiment, scientific-method format. Strategic question + execution detail are split for readability and concurrent updateability. See `docs/phase-2-experiments/README.md` for the index.

## Numbering convention

- **E1-E9** were allocated in the mission doc before this matrix was written. They cover both Phase 2 sub-paths and other axes (E1 / E7 are H1 tests; E6 is informational; E8 / E9 are Sub-mission C). E2 / E3 / E4 / E5 are Phase 2 experiments — their protocols are detailed below.
- **E10 onwards** are net-new experiments allocated as part of this matrix.

| ID | One-liner | Status |
|---|---|---|
| E1 | Cable replug WITH active workload | **DEPRECATED** (caused Xid 154 today; replaced by E7) |
| E2 | pciehp slot power cycle (`/sys/bus/pci/slots/<N>/power`) | Phase 2 — detailed below |
| E3 | Exhaustive sysfs walker under `/sys/bus/pci/devices/` + `/sys/bus/thunderbolt/` | Phase 2 — detailed below |
| E4 | `udevadm trigger` with various subsystem filters | Phase 2 — detailed below |
| E5 | `setpci` writes to bridge BAR registers + rescan | Phase 2 — detailed below |
| E6 | Test with a different TB chassis | Informational (chassis-side, OOS for our investigation) |
| E7 | Cable replug WITH drain-first protocol | **DONE 2026-05-25 — H1 FALSIFIED** |
| E8 | Cable yank on IDLE GPU (control for H7) | Sub-mission C scope |
| E9 | Instrumented controlled disconnect during compute (H9 hunt) | Sub-mission C scope |
| **E10-E27** | This matrix (18 new) | Phase 2 — detailed below |

---

## Section 1 — No-reboot, no-setup experiments (~4 hours total)

Each is reversible by reboot. Run from a broken-BAR1 starting state (e.g., post-E7) — if a test recovers BAR1=32GB, we have a winner.

| # | Experiment | Hypothesis | Cost | Risk |
|---|---|---|---|---|
| **E2** | `echo 0 > /sys/bus/pci/slots/<N>/power; sleep 2; echo 1 > /sys/bus/pci/slots/<N>/power` (pciehp slot power-cycle — different from `remove`/`rescan`) | Slot power-cycle path forces full pciehp re-enumeration including bridge window reallocation | 2 min | LOW |
| **E10** | Remove the **root port** (`0000:00:07.0`) + rescan from `0000:00` parent | Removing at root-port level lets the kernel reallocate windows for the entire TB subtree from scratch (we only went as high as `02:00.0` in prior tests) | 5 min | MEDIUM (may need reboot if root port doesn't come back) |
| **E11** | `echo 1 > /sys/bus/pci/devices/0000:04:00.0/remove; echo 1 > /sys/bus/pci/devices/0000:04:00.1/remove; echo 1 > /sys/bus/pci/rescan` (per-function removal, not bridge-level) | Per-function removal followed by global rescan may take a different allocation path | 3 min | LOW |
| **E12** | `echo 1 > /sys/bus/pci/devices/0000:04:00.0/reset` (PCIe function-level reset / FLR) | FLR may trigger BAR re-negotiation through the bridge | 1 min | LOW |
| **E13** | Iterate `reset_method` (`pm`, `bus`, `flr`, etc.) + trigger reset for each | Different reset methods exercise different kernel code paths | 5 min × N | LOW |
| **E14** | `echo 0 > /sys/bus/pci/devices/0000:04:00.0/d3cold_allowed`, cycle through D3cold | D-state transitions force certain re-init paths in pcieport | 5 min | MEDIUM |
| **E4** | `udevadm trigger --subsystem-match=pci --action=remove` then `--action=add` for the GPU device | udev-driven re-trigger may invoke different kernel paths than direct sysfs writes | 3 min | LOW |
| **E15** | debugfs scan: `find /sys/kernel/debug/pci/ -writable -type f`; toggle each (with care) | Kernel may expose realloc / bridge-resize triggers under debugfs that aren't in public sysfs | 30 min | MEDIUM (some debugfs writes can hang the kernel) |
| **E3** | Exhaustive sysfs surface walker: `find /sys/bus/pci/devices/ /sys/bus/thunderbolt/ -writable -type f` — for each, identify "could plausibly trigger reallocation" candidates | Some writable sysfs file does what we want; we just haven't found it | 1-2 hr | LOW |

## Section 2 — `setpci` direct config writes (~half day, HIGH risk)

Direct PCI config-space writes. The kernel may or may not honor externally-modified register values; this is the "is the kernel's bridge-window-sizing decision *consultative* or *authoritative*?" question.

| # | Experiment | Hypothesis | Cost | Risk |
|---|---|---|---|---|
| **E5** | `setpci -s 0000:03:00.0 PREF_MEMORY_BASE=…` + `PREF_MEMORY_LIMIT=…` (widen the bridge's prefetchable memory window to 32GB directly) | Bridge windows are config-space registers; rewriting may be honored on next enumeration | 30 min | **HIGH** (mis-written bridge windows can hang the bus) |
| **E16** | `setpci -s 0000:04:00.0 <RBAR_CONTROL>=15` (write to the device's Resizable BAR Control register to request 32GB explicitly) | Device-side ReBAR negotiation may complete if we ask for 32G after bridge window is widened | 1 hr | **HIGH** |
| **E17** | Chain: E5 (widen bridge windows) + E12 (FLR) | Combined chain may complete the negotiation cycle | 2 hr | **HIGH** |

## Section 3 — Cmdline tuning + reboot per iter (~half day)

Each iteration requires a host reboot. ~3 min per iter (edit cmdline, reboot, capture stats).

| # | Experiment | Hypothesis | Cost | Risk |
|---|---|---|---|---|
| **E18** | Add `pci=realloc=on` to cmdline | LF forum says doesn't help alone — validate on our specific hardware | 3 min | LOW |
| **E19** | `pci=realloc=on hpmmioprefsize=32G` | Combine "didn't help alone" with explicit 32G hint for prefetchable memory | 3 min | LOW |
| **E20** | `pci=realloc=on hpmmioprefsize=32G hpmmiosize=256M` | Add non-prefetchable hint too — LF forum tested without this | 3 min | LOW |
| **E21** | `pci=realloc=on hpmemsize=33G` | Alternative combined-budget hint form | 3 min | LOW |
| **E22** | `pci=realloc=on hpmmioprefsize=32G pcie_aspm=off` | Test interaction with ASPM fully off (we have `pcie_aspm.policy=performance`; trying full off) | 3 min | LOW |
| **E23** | Each cmdline above × cold-boot-WITH-device-OFF, then power on at runtime | Test whether cmdline hints take effect on runtime hotplug after they were set at boot | 10 min each | LOW |
| **E24** | `pci=resource_alignment=NN@<bridge>` variations (our current `35@0000:03:00.0` is one specific value) | Alignment hint at a different size may shape allocation differently | 3 min each | LOW |

## Section 4 — Custom kernel build (~1-2 weeks; last resort)

| # | Experiment | Hypothesis | Cost | Risk |
|---|---|---|---|---|
| **E25** | Cherry-pick Miroshnichenko "movable BARs" v9 (Dec 2020, 26 patches) onto current kernel 7.0.x; build; install; test | The proposed mechanism explicitly addresses our class of problem; even though stalled in mainline review, it may work in practice | 1-2 days | MEDIUM |
| **E26** | Write a minimal custom kernel module that exposes `/sys/.../trigger_bridge_resize` and triggers `pci_resize_resource` + bridge reallocation | If the API exists internally but isn't exposed to userspace, we can expose it | 1-3 days | MEDIUM |
| **E27** | Patch `drivers/pci/setup-bus.c::__assign_resources_sorted` to retry with larger windows when initial allocation < device's ReBAR cap | Direct surgical fix at the location LF forum identified | 3-5 days | HIGH (changes core PCI behavior) |

---

## Recommended evaluation order

Prioritised by **information-per-cost** + **least-invasive first** + **dependency**:

### Phase 2.1 — Quick wins (~4 hours total)

1. **E2** (slot power-cycle) — highest "different code path" probability
2. **E10** (remove root port + rescan) — never tested at this level; high-info
3. **E12** (FLR reset) — cheap; FLR is a different code path than remove/rescan
4. **E13** (reset_method permutations) — extends E12
5. **E14** (D3cold transitions) — different init path
6. **E4** (udevadm trigger) — different event source
7. **E11** (per-function remove) — variant of what we've tried but different selector

### Phase 2.2 — Surveys (half day)

8. **E3** (full sysfs surface enumeration) — produces a matrix of candidates
9. **E15** (debugfs survey) — kernel-internal API surface

### Phase 2.3 — Cmdline tuning (half day; needs reboot per iter)

10. **E18** (`pci=realloc=on` alone) — establishes baseline
11. **E19** (`+hpmmioprefsize=32G`) — most-likely-to-work combo
12. **E20-E21** (variants if E19 partial)
13. **E22** (ASPM interaction if E19 still partial)
14. **E23** (cmdline × cold-boot-off path) — tests how cmdline hints flow into hotplug allocation
15. **E24** (resource_alignment variants)

### Phase 2.4 — setpci (half day; HIGH risk)

16. **E5** (bridge window widen)
17. **E16** (device RBAR control register)
18. **E17** (combined E5+E12)

### Phase 2.5 — Kernel work (1-2 weeks; last resort)

19. **E25** (Miroshnichenko patches)
20. **E26** (custom module)
21. **E27** (direct PCI core patch)

---

## Exit criteria

The archaeology completes when ONE of:

- **(a)** A working software-only trigger is found — E2-E24 all run at least once; at least one produced BAR1=32GB after a runtime cycle. → Integrate into Option B in-container watcher; Sub-mission A closes.
- **(b)** Exhaustively proven that no software-only trigger exists — all E2-E24 produce the same 256MB outcome. → Phase 3 upstream work (E25-E27) becomes the only path; we have a citation-ready bug report.
- **(c)** Partial success — a path works some of the time / on some kernels. → Document the working envelope; ship Option B with the documented limitation.

---

## Operational protocol per experiment

1. Capture **before** state: `tools/get-pci-stats.sh --baseline <experiment-id>`
2. Run the experiment per its row above
3. Capture **after** state: `tools/get-pci-stats.sh --snapshot <experiment-id>`
4. Diff: `tools/get-pci-stats.sh --diff <experiment-id>`
5. Record outcome in this doc's "Results" section (added when run begins)
6. If the experiment broke the cluster, reboot to recover before proceeding

Drain-first protocol from MISSION-1 mission doc applies — no experiment runs while vLLM is actively serving CUDA compute.

---

## Cross-references

- Mission: `docs/mission-egpu-hot-plug-hot-power.md` (especially H10 + experiment list — this doc is the detail layer)
- M1 research: `audit/tb-pcie/CONSOLIDATED.md` (Q1-Q6 + LF forum analysis)
- E7 result (H1 falsified): `archive/cable-replug-test-E7-20260525T084717Z/post-test-finding.txt`
- Stats script: `tools/get-pci-stats.sh`
