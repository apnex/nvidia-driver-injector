# MISSION-1 — TB eGPU runtime hot-plug + hot-power

**Status:** ACTIVE (declared 2026-05-25)
**Owner:** apnex
**Repo home:** [`apnex/nvidia-driver-injector/docs/missions/mission-1-egpu-hot-plug-hot-power/`](https://github.com/apnex/nvidia-driver-injector/tree/main/docs/missions/mission-1-egpu-hot-plug-hot-power)

## What this mission is

Make the AORUS RTX 5090 eGPU connected over Thunderbolt 4 to a NUC 15 Pro+ host survive **cable + power transitions at runtime** without requiring a host reboot. Two equal-weight scenarios:

- **Sub-mission A** — cable unplug + replug (with workload drained)
- **Sub-mission B** — eGPU chassis power-cycle (cable stays connected)
- **Sub-mission C** — unexpected disconnect during active compute (informant for failure modes)

Cold-plug at boot is the only currently-reliable path; runtime transitions hit either:
- Linux PCIe hotplug fallback bridge-window allocation → BAR1=256M instead of 32G ("broken-BAR1 state")
- Xid 79 + Xid 154 cascade during surprise-removal-with-active-driver-session → host wedge

## Working geometry

Investigations under this mission map all observable behaviors and code paths that trigger failure, with the goal of building the body of forensic evidence required to design a **permanent corrective patch** (extension of existing patches like E1, or new addon/core patch — geometry decided once evidence is sufficient). See `../upstream-plan.md` for the C/E/A patch geometry this mission's findings will plug into.

## Documents in this mission

| File | What it is |
|---|---|
| [`mission.md`](mission.md) | Top-level mission doc — sub-missions, hypothesis registry (H1-H10), experiment registry (E1-E27), narrative context |
| [`matrix.md`](matrix.md) | Strategic experiment matrix — what, why, what order. Canonical numbering source. |
| [`experiments/`](experiments/) | Per-experiment scientific-method files (one per E-number), filled in as runs accumulate |
| [`experiments/README.md`](experiments/README.md) | Index of experiments with status |
| [`experiments/_TEMPLATE.md`](experiments/_TEMPLATE.md) | Template for new experiment files |
| [`experiments/_STARTING-STATE-RECIPE.md`](experiments/_STARTING-STATE-RECIPE.md) | How to enter the "broken-BAR1" starting state — Recipe A (cable, DANGEROUS) + Recipe B (software remove, SAFE) |
| [`experiments/_SECTION-3-CMDLINE-WORKFLOW.md`](experiments/_SECTION-3-CMDLINE-WORKFLOW.md) | Shared GRUB-edit-reboot workflow for cmdline-tuning experiments (E18-E24) |

## Tooling (sibling tools in this repo)

| Tool | Use |
|---|---|
| [`../../tools/get-pci-stats.sh`](../../../tools/get-pci-stats.sh) | Per-experiment state capture: `--baseline <eid>` / `--snapshot <eid>` / `--diff <eid>` / `--list`. Writes to `/var/log/mission-1-archaeology/`. |
| [`../../tools/must-gather.sh`](../../../tools/must-gather.sh) | Comprehensive forensic bundle on host. Captures dmesg, journalctl (-b 0, -b -1, -b -2), lspci, boltctl, nvidia-smi, k8s state, soak metrics. Run after any wedge-class event. |

## Runtime archive area

`/var/log/mission-1-archaeology/` (on the host, not in any repo):

```
phase-2-1-prebroken.baseline.txt       ← from get-pci-stats.sh --baseline
phase-2-1-prebroken.snapshot.txt       ← from --snapshot
E07-Run2-wedge/                         ← preserved must-gather bundle from wedge incident
  nvidia-injector-must-gather-20260526T083709Z-WITH-WEDGE.tar.gz
```

Pattern: per-experiment baseline/snapshot files live at the root of the archive. Wedge / failure-mode bundles get their own subdirectory named after the run identifier.

## Process for executing an experiment

1. Open the relevant `experiments/E??-*.md` file
2. Confirm prerequisites and current cluster starting state
3. Execute the `Method` section commands verbatim
4. Capture diff via `tools/get-pci-stats.sh --diff E??`
5. Add a `### Run N — YYYY-MM-DD` subsection under `## Per-run records` with:
   - Conditions (driver version, what's holding /dev/nvidia*, etc.)
   - Result (PASS / FAIL / INCONCLUSIVE / WEDGE)
   - Diff highlights
   - Forensic bundle path (if anomaly — run `tools/must-gather.sh` and preserve under `/var/log/mission-1-archaeology/`)
   - Conclusion
6. Update Status header at the top of the file
7. Update `experiments/README.md` index status
8. If failure mode surfaces driver-level behavior, populate `## Patch coverage analysis` and `## Patch design implications` sections
9. Commit (no AI attribution per `feedback_no_claude_attribution_in_commits`)

## Process for adding a new experiment

1. Copy `experiments/_TEMPLATE.md` → `experiments/E<NN>-<short-slug>.md`
2. Fill in Hypothesis / Falsification gates / Prerequisites / Method
3. Add to `experiments/README.md` index
4. Add to `matrix.md` registry if material
5. Commit before running

## Process for wedge-class incidents

After any wedge or unexpected hard failure:

```bash
# 1. Recover (forced reboot if needed)
# 2. IMMEDIATELY (before more reboots dilute -b -1):
sudo /root/nvidia-driver-injector/tools/must-gather.sh
# 3. Preserve under runtime archive
mkdir -p /var/log/mission-1-archaeology/E<NN>-Run<N>-<tag>/
cp /tmp/nvidia-injector-must-gather-*.tar.gz /var/log/mission-1-archaeology/E<NN>-Run<N>-<tag>/
# 4. Reference from the experiment file's `## Forensic bundles` section
# 5. Build patch-design analysis from the bundle, not chat scrollback
```

## Body-of-evidence model

Each experiment file accumulates a `## Per-run records` history. The body of evidence needed to design a corrective patch is built across:

- Multiple runs of the same experiment (confirm determinism per `feedback_reliability_methodology`)
- Variants discriminating between competing sub-hypotheses (e.g., H7a vs H7b in E08)
- Cross-experiment comparisons (e.g., E07 cable-yank failure mode vs E11 software-remove failure mode)

Decisions about patch geometry (extend existing patch / new addon / new core / userspace) are deferred until each `## Patch design implications` section can be filled with confidence.

## Cross-repo links

- [`apnex/k8s-vllm` mission manifest](https://github.com/apnex/k8s-vllm/blob/main/docs/mission-manifest.md) — MISSION-1 row points here from the consumer/deployment side
- [`apnex/nvidia-driver-injector` patch ecosystem](../) — adjacent patches.md, upstream-plan.md, patch-intents/, patch-reviews/, patch-improvements/
