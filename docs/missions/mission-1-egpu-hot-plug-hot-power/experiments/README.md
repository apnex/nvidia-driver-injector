# MISSION-1 Phase 2 experiments — index

This directory carries one file per Phase 2 archaeology experiment.\
Each file is a self-contained scientific-method record: **hypothesis, method, predicted outcomes, actual result, conclusion**.

**Mission context:** [`../mission.md`](../mission.md) — MISSION-1 root doc, hypothesis registry
**Strategic context:** [`../matrix.md`](../matrix.md) — strategic experiment matrix, canonical numbering
**State-capture tool:** [`../../../tools/get-pci-stats.sh`](../../../../tools/get-pci-stats.sh) — used by every experiment
**Forensic bundle tool:** [`../../../tools/must-gather.sh`](../../../../tools/must-gather.sh) — run after any wedge-class event

## Status legend

| Status | Meaning |
|---|---|
| `PENDING` | not yet run |
| `RUNNING` | currently in progress |
| `PASS` | recovered BAR1 ≥ 32GB (H10 confirmed via this path) |
| `FAIL` | did NOT recover BAR1 to 32GB (H10 not confirmed via this path) |
| `INCONCLUSIVE` | ran but outcome ambiguous; needs re-run with different inputs |
| `SKIPPED` | superseded by other experiment OR scope-out |
| `BLOCKED` | needs upstream resource (e.g., E25 needs custom kernel build env) |

## Index

### Sub-mission A / C informants — mission-level cable+power tests

| ID | File | Status |
|---|---|---|
| E07 | [Cable replug WITH drain-first](E07-cable-replug-drain-first.md) | RUN 1 DONE (2026-05-25, clean) / RUN 2 WEDGE (2026-05-26) |
| E08 | [Cable yank on IDLE GPU (H7 control)](E08-cable-yank-idle-gpu.md) | PARTIAL — full quiesce variant pending |

### Section 1 — No-reboot, no-setup (Phase 2.1 + 2.2)

| ID | File | Status |
|---|---|---|
| E02 | [pciehp slot power-cycle](E02-pciehp-slot-power-cycle.md) | PENDING |
| E10 | [Remove root port + rescan from parent](E10-root-port-remove-rescan.md) | PENDING |
| E11 | [Per-function remove (GPU + audio) + global rescan](E11-per-function-remove.md) | Run 1 DONE 2026-05-26 — Recipe B SAFE confirmed; doesn't produce broken-BAR1 from healthy state |
| E12 | [FLR reset on GPU](E12-flr-reset.md) | PENDING |
| E13 | [reset_method permutations](E13-reset-method-permutations.md) | PENDING |
| E14 | [D3cold transitions](E14-d3cold-transitions.md) | PENDING |
| E04 | [udevadm trigger](E04-udevadm-trigger.md) | PENDING |
| E15 | [debugfs surface scan](E15-debugfs-survey.md) | PENDING |
| E03 | [Exhaustive sysfs walker](E03-sysfs-walker.md) | PENDING |

### Section 2 — setpci direct config writes (Phase 2.4 — HIGH risk)

| ID | File | Status |
|---|---|---|
| E05 | [setpci bridge memory base/limit widen](E05-setpci-bridge-widen.md) | PENDING |
| E16 | [setpci RBAR Control register write](E16-setpci-rbar-control.md) | PENDING |
| E17 | [Combined setpci widen + FLR chain](E17-setpci-flr-chain.md) | PENDING |

### Section 3 — Cmdline tuning (Phase 2.3 — reboot per iter)

| ID | File | Status |
|---|---|---|
| E18 | [`pci=realloc=on` alone](E18-cmdline-realloc-on.md) | Run 1 DONE 2026-05-26 — Phase A PASS (safe); Phase B BLOCKED; I/O window expansion confirmed, prefetchable unchanged |
| E19 | [`+hpmmioprefsize=32G`](E19-cmdline-hpmmioprefsize.md) | PENDING |
| E20 | [`+hpmmiosize=256M`](E20-cmdline-hpmmiosize.md) | PENDING |
| E21 | [`hpmemsize=33G`](E21-cmdline-hpmemsize.md) | PENDING |
| E22 | [`+pcie_aspm=off`](E22-cmdline-aspm-off.md) | PENDING |
| E23 | [Each cmdline × cold-boot-off path](E23-cmdline-cold-boot-off.md) | PENDING |
| E24 | [`pci=resource_alignment` size variants](E24-cmdline-resource-alignment.md) | PENDING |

### Section 4 — Custom kernel build (Phase 2.5 — last resort)

| ID | File | Status |
|---|---|---|
| E25 | [Cherry-pick Miroshnichenko v9 "movable BARs"](E25-miroshnichenko-cherry-pick.md) | BLOCKED |
| E26 | [Custom kernel module exposing trigger_bridge_resize](E26-custom-kernel-module.md) | BLOCKED |
| E27 | [Patch drivers/pci/setup-bus.c::__assign_resources_sorted](E27-pci-core-patch.md) | BLOCKED |

## How to use

### Running an experiment

1. Open the experiment's file
2. Confirm prerequisites and that GPU/cluster is in the documented starting state
3. Execute the `Method` section commands verbatim
4. Capture diff via `tools/get-pci-stats.sh --diff E<N>`
5. Fill in the `Actual result` section:
   - Status (PASS / FAIL / INCONCLUSIVE)
   - Date
   - Diff highlights (key state changes)
   - Conclusion (1 paragraph)
6. Update status in this README's index table
7. Commit (per `feedback_no_claude_attribution_in_commits` — no AI authorship)

### Adding a new experiment

1. Copy `_TEMPLATE.md` to `E<NN>-<short-name>.md` (zero-padded for sort order)
2. Fill in all required sections
3. Add to the index table above with `PENDING` status
4. Cross-reference from `docs/phase-2-archaeology-matrix.md` if substantive enough

## Shared workflow docs

| Doc | When |
|---|---|
| [`_TEMPLATE.md`](_TEMPLATE.md) | Empty experiment template — copy when adding new |
| [`_SECTION-3-CMDLINE-WORKFLOW.md`](_SECTION-3-CMDLINE-WORKFLOW.md) | Shared cmdline-edit-reboot-capture procedure for E18-E24 |
| [`_STARTING-STATE-RECIPE.md`](_STARTING-STATE-RECIPE.md) | How to deliberately enter "broken-BAR1" starting state for Section 1 + 2 experiments |
