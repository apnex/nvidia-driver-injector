# Documentation

**New here?** The repo [`README.md`](../README.md) is the starting point — what
the project is, quick start, and troubleshooting. The files in this directory
go deeper.

## For users

| Doc | Read it when |
|---|---|
| [install-workflow.md](install-workflow.md) | You're installing the stack — Layer 1 + Layer 2 step-by-step with verification. |
| [teardown-workflow.md](teardown-workflow.md) | You're unloading the module (graceful pause), bumping the driver image (cutover + rollback), or removing the stack entirely (full uninstall, `--purge`). |
| [testing.md](testing.md) | You want to disambiguate the three "test" flows — install verify, the diag container, repo gates. |
| [architecture.md](architecture.md) | You want the three-layer design, the component-ownership table, and reboot-survival behaviour. |
| [patches.md](patches.md) | You want to know what each patch cluster does, the bug it fixes, and how it maps to the C/E/A upstream geometry. |

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
| [patch-refactor-status.md](patch-refactor-status.md) | Phase-by-phase status of the P1–P7 refactor. |
| [patch-refactor-inventory.md](patch-refactor-inventory.md) | Phase 1 forensic inventory — the per-legacy-patch analysis the clustering was derived from. |
