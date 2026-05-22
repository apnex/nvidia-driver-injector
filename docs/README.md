# Documentation

**New here?** The repo [`README.md`](../README.md) is the starting point — what
the project is, quick start, and troubleshooting. The files in this directory
go deeper.

## For users

| Doc | Read it when |
|---|---|
| [install-workflow.md](install-workflow.md) | You're installing the stack — full step-by-step, prerequisites, and the post-install verification suite. |
| [architecture.md](architecture.md) | You want the three-layer design, the component-ownership table, and reboot-survival behaviour. |
| [patches.md](patches.md) | You want to know what each of the 7 patch clusters (P1–P7) does, the bug it fixes, and how it maps to the C/E/A upstream geometry. |

## Deep dives

| Doc | Topic |
|---|---|
| [bridge-link-cap-mechanism.md](bridge-link-cap-mechanism.md) | Why the PCIe bridge link-speed cap (Lever H17) is needed, and how it's applied `Before=docker.service`. |

## Internal — refactor history & upstream plan

Refactor history and the forward plan. Useful if you're working on the patches
themselves; skip them otherwise.

| Doc | Content |
|---|---|
| [upstream-plan.md](upstream-plan.md) | Phase 3 plan — the C/E/A patch geometry: six upstream-bound PRs (`C1`–`C5` core, `E1` eGPU) plus the project-local Addon layer (`A`), the placement principle, and the carve. |
| [production-migration.md](production-migration.md) | Step 3 — moving the production driver onto the C/E/A geometry (base + additive): the sequence, the additive re-carve, the soak gate, and the open design questions. |
| [patch-refactor-status.md](patch-refactor-status.md) | Phase-by-phase status of the P1–P7 refactor. |
| [patch-refactor-inventory.md](patch-refactor-inventory.md) | Phase 1 forensic inventory — the per-legacy-patch analysis the clustering was derived from. |
