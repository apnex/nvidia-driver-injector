# Documentation

**New here?** The repo [`README.md`](../README.md) is the starting point — what
the project is, quick start, and troubleshooting. The files in this directory
go deeper.

## For users

| Doc | Read it when |
|---|---|
| [install-workflow.md](install-workflow.md) | You're installing the stack — full step-by-step, prerequisites, and the post-install verification suite. |
| [architecture.md](architecture.md) | You want the three-layer design, the component-ownership table, and reboot-survival behaviour. |
| [patches.md](patches.md) | You want to know what each of the 7 patch clusters (P1–P7) does, the bug it fixes, and its upstream-readiness. |

## Deep dives

| Doc | Topic |
|---|---|
| [bridge-link-cap-mechanism.md](bridge-link-cap-mechanism.md) | Why the PCIe bridge link-speed cap (Lever H17) is needed, and how it's applied `Before=docker.service`. |

## Internal — refactor history & upstream plan

Refactor history and the forward plan. Useful if you're working on the patches
themselves; skip them otherwise.

| Doc | Content |
|---|---|
| [upstream-plan.md](upstream-plan.md) | Phase 3 plan — the 8 target upstream PRs (`U1`–`U5` core, `E1`–`E3` eGPU-path), the placement principle, and what stays project-local. |
| [patch-refactor-status.md](patch-refactor-status.md) | Phase-by-phase status of the P1–P7 refactor. |
| [patch-refactor-inventory.md](patch-refactor-inventory.md) | Phase 1 forensic inventory — the per-legacy-patch analysis the clustering was derived from. |
