# Documentation style — applied entries

The canonical doc-style rules this project follows live in the
**mission-kit** repo (a separate cross-project knowledge base — see
the repo's `README.md` for the full hard-rules + entry shape).

This file is the *pointer*. It enumerates which mission-kit entries
this project has adopted, so the project's docs stay anchored to a
durable source-of-truth that doesn't drift across repos.

## Entries applied

| ID | Where it shows up in this repo |
|---|---|
| **S1** — Prerequisites explicit + cluster-agnostic + assumes authenticated tooling | `docs/install-workflow.md` Prerequisites section (Path B is described as "any Kubernetes distribution" + `kubectl get nodes` verify). |
| **S2** — Runnable workflow steps belong in code blocks | All Path A + Path B step bodies in `docs/install-workflow.md` + `docs/teardown-workflow.md` use fenced code blocks; inline backticks reserved for command-name references in prose. |
| **S3** — Producer / consumer doc split | This repo (producer) ships `docs/consumer-contract.md` documenting its public contract. Consumer repos (vLLM, kate, …) own their own Deployment + Service + state docs. |
| **S4** — Four-journey README | Top-level `README.md` orients on install / use / test / remove, each pointing at its deep-dive doc. |
| **M2** — Test-drive docs by execution, not by reading | `docs/teardown-workflow.md` was validated by literal execution on 2026-05-24; 4 drift items surfaced + fixed (commit `b5bc0ad`). Same discipline applies to future workflow-doc changes. |
| **M3** — Default-reject + honest yield | Applied to the sub-cycle 3 + 4 patch improvement campaigns (per project memories `project_patch_v3_improvements_complete_2026_05_23` + `project_sub_cycle_4_paired_cascade_2026_05_24`). |
| **M4** — Frozen-history rule | Per-patch `intent/review/improvement` files under `docs/patch-*/` are NOT rewritten on policy changes; design records under `docs/superpowers/plans/` + `docs/superpowers/specs/` likewise frozen. Status banners + cross-links instead. |
| **P1** — Path A / Path B dual-substrate labeling | `docs/install-workflow.md` + `docs/teardown-workflow.md` split into Path A (docker-compose) + Path B (k3s DaemonSet). |
| **P2** — Node-label gate for cross-component contracts | The producer/consumer contract uses `nvidia.driver/state=ready` + `nvidia.driver/version=<value>` labels written by the DaemonSet entrypoint; consumers `nodeSelector` against them. Documented at `docs/consumer-contract.md`. |
| **K1** — AI-attribution scrub | Applied 2026-05-23 across this repo + the apnex fork of open-gpu-kernel-modules; tooling at `/root/scrub-tools/`. Standing policy memory: `feedback_no_claude_attribution_in_commits`. |
| **K2** — Force-push carve-out for fork branches | Applied 2026-05-23 + 2026-05-24 for the A1-I8 cascade rebase + sub-cycle 4 paired-cascade rebase on the apnex fork's A* branches. Standing memory: `feedback_force_push_fork_carve_out`. |

## Adding new entries

If you find a project-applicable rule that ISN'T in mission-kit yet,
add it to mission-kit first (per its README's contribution flow),
then add a row above pointing at the new entry. Don't define
project-only style rules in this file — that's exactly the
drift-trap mission-kit is meant to prevent.
