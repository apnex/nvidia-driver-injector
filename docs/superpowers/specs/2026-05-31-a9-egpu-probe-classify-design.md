# A9 — eGPU probe-time classification (close the A6/A7 first-open coverage hole)

**Date:** 2026-05-31 · **Status:** design approved, pre-implementation · **Task:** #287 (fix) + #288 (A8 v2.2 deploy, bundled)
**Design provenance:** brainstorming + an 8-agent design-judge-panel (map → 3 independent approaches → adversarial stress-test → synthesis). Forensics: `docs/missions/mission-1-egpu-hot-plug-hot-power/experiments/OA-reset-ladder-wedge-forensics-2026-05-31.md`.

## Problem

A6 (open-path) and A7 (shutdown-path) bounded-wait wrappers gate on `nv->is_external_gpu`. That flag is set in exactly one place — `src/nvidia/.../osinit.c:1301`, inside `RmInitNvDevice`, which runs **during the first open's `RmInitAdapter`**. A fresh `nv_state_t` is zeroed at probe (`nv-pci.c`, `NV_KZALLOC`). So the flag is **FALSE on the first open of any bind** → A6/A7 fall through to the synchronous path. On a userspace-recovered (bad) chip the first open then runs the GSP-lockdown busy-poll on the *syscall thread* holding the GPU group lock → host hard-wedge. Reproduced 2026-05-31 (reset-ladder R0.5; 2 reboots). Any re-probe onto a bad chip (manual rebind, PCI-error recovery, A3 `slot_reset`, hot-plug) hits the same unguarded first open.

> **Correction of record:** an earlier premise that `osinit.c` lives in an un-editable precompiled blob was **false** — the build compiles `src/nvidia` from source (the Dockerfile `git apply`s the patch set then `make modules`; `nv-kernel.o_binary` is a symlink to a build artifact; E1/C3/C5 already edit `osinit.c`). The fix is placed in the open driver for **sovereignty**, not because the blob is unreachable.

## The fix (one line)

In `kernel-open/nvidia/nv-pci.c`, inside `nv_pci_probe`, on a new line **immediately after `nv->handle = pci_dev;`** (and before `nv_lock_init_locks`):

```c
nv->is_external_gpu = os_pci_is_thunderbolt_attached(nv->handle);
```

At this point `nv` is zeroed, `nv->handle` is valid, and we are on the synchronous probe thread holding no GPU lock. The helper (`os_pci_is_thunderbolt_attached`, added by E1, `os-pci.c`) is **probe-safe**: pure PCI topology (`pci_is_thunderbolt_attached(pdev)` + `pdev->untrusted`), no chip MMIO, no lock. It is declared in `os-interface.h` and `NV_API_CALL`-linked; `nv-pci.c` already calls sibling `os_pci_*` helpers (C5's `os_pci_is_disconnected`), so it links and compiles.

A6 (`nv.c:1866`) and A7 (`nv.c:2222`) gates stay **verbatim** (`if (!nv->is_external_gpu) <synchronous>`) — they now read a correct flag at first open/close. No OR-helper, no per-gate topology call, no duplicated detection.

## Why this shape

- **Byte-identical verdict.** E1 made `RmCheckForExternalGpu`'s entire body `return os_pci_is_thunderbolt_attached(nv->handle)`, so the probe-time value equals the blob's lazy value exactly — zero divergence risk.
- **Sovereignty.** Carve the line in a **new `patches/addon/A9-egpu-probe-classify.patch`** (Addon layer, where A6/A7 live; A3 already has a probe-time addon hook as precedent). **E1 stays byte-for-byte unchanged** (it is the upstream-bound *detector*; set-*timing* is our project-local workaround). This avoids re-opening E1 review and the base-patch regen cascade.
- **Monotonic / no-regression.** No code writes `is_external_gpu = FALSE` anywhere post-probe (verified tree-wide); the only other writer is the blob's TRUE-only set at `osinit.c:1301`. So the probe-set can only **add** arming. Worst case (a TB/USB4 eGPU the kernel fails to classify) degrades to today's lazy behaviour — no regression. **Load-bearing invariant: no future code may write `is_external_gpu = FALSE`** (it would silently disarm A6/A7); assert this in the A9 intent doc.
- **Free wins.** A7's without-prior-open gate closes too; the upstream usage-count skip (`nv-pci.c:2467`) becomes correct earlier; and **A8's `tb_egpu_is_external` reads accurate-from-probe** — making it a valid pre-flight guard (closes the #288 observability caveat).
- **`RmForceExternalGpu` retired** — zero references tree-wide; no override to honour. No action.

## Scope boundary (mandatory wording — honours the forensics scar)

This **closes the A6-coverable first-open hole (the H-OA1 site:** wedge inside `RmInitAdapter` on the worker-queued `nv_open_device_for_nvlfp`**)**. It explicitly does **not**:
- fix the co-leading **H-OA2** pre-`nv_open_device` PM-resume site (flag timing doesn't reach it; H-OA1/H-OA2 are equal-prior, n=1, unresolved);
- cover `NVreg_GpuInitOnProbe=1` (`nv_start_device` is called raw from probe, not via the wrapper; live config is `=0`);
- *prevent the wedge.* It **converts an immediate syscall-thread wedge into a bounded `-EIO`** — with a worker that A6 leaks (see Residual risks). Commit/docs say "**closes the A6-coverable first-open (H-OA1) hole**," never "fixes the open-arm wedge."

## Residual risks (EXPOSED by this fix, not introduced — deferred to a coupled follow-up)

Arming A6 on a bad-chip first open routes the wedge into A6's leaked worker, which surfaces A6's pre-existing leaked-worker design (both gaps share one root — the refcount-2 leak):
1. **Worker holds the GPU lock.** The leaked worker stays in the GSP-lockdown busy-poll holding the group lock; the syscall returns `-EIO` but the next lock-taker can wedge. The open-arm "fails-fast on C5 sink-set" assumption is **unverified** (evidenced only for the shutdown arm; `pmu.log` was empty).
2. **UAF.** A6 has no `flush_work` guard (A7 has the SH-3 guard); a leaked worker still in `RmInitAdapter` when rebind→remove frees module/`nvl` text is a UAF — and arming A6 on re-probe paths broadens that window.

**Decision (option a):** ship A9 minimal now; the principled fix for *both* — make A6's worker **provably self-terminating** (sink-aware bail / link-disable to force the MMIO to fail) so it can be safely **joined** (`flush_work`) — is a **coupled follow-up** (A6 "leak→join lifecycle"), driven by the destructive test and aligned with the v5 strategic review. A naive `flush_work` guard is *not* safe to add now: if the worker never exits, flush hangs the remove path.

## Verification plan (gates; honours "apply ≠ validated" + the survivable-from-unverified scar)

1. **Compile (non-negotiable).** Build the image (compose-patchset → `git apply` → `make modules` against the matching kernel). `git apply --check` is insufficient. Confirm A9 applies in compose order and the module links (`os_pci_is_thunderbolt_attached` resolves).
2. **Source data-flow (composed tree).** Re-derive in the *composed* tree that the insertion lands strictly after `nv->handle = pci_dev;` (before it, `handle` is NULL → helper returns `NV_FALSE` → silent no-op that re-wedges with no compile error); `nv` is zeroed before it; no FALSE-writer exists; A6/A7 gates + the `nv-pci.c:2467` skip + A8 sysfs all read the probe-set field. **Line numbers drift after composition — author against the composed snapshot, not base-tree offsets.**
3. **Healthy-deploy invariant (non-destructive).** On a healthy chip, *before* any open: `cat …/tb_egpu_is_external` MUST read `1` from probe (old build: `0` until first open). First open MUST log `tb_egpu [F40b]: open scheduled to bounded worker` (old build: synchronous, no line). Across an unbind→rebind: `tb_egpu_is_external` MUST stay `1` (the exact invariant whose violation caused the wedge).
4. **Source-delta review.** The one behavioural delta (an early-`RmInitAdapter`-failure of a *genuine* eGPU now takes the eGPU all-clients-lock teardown shape at `osinit.c:2415/2515`) is source-visible and compile-checked — inspect `osinit.c` directly; arguably more correct. `fake-5090` reproduction is **aspirational** (survey-only repo) — not a passed gate.
5. **Destructive (required before claiming "survivable").** "First-open-on-a-bad-chip now engages the bounded worker AND the host survives" is **unproven by inspection** — the only time that path ran on a bad chip is the run that wedged. Gate the *survivable* claim on a destructive first-open-on-bad-chip test (Lane-3 Rung-8 class). Until then the claim is scoped to "closes the hole; compile- + healthy-sysfs-validated." (Does **not** block the A9 deploy — A9 is monotonic-safe and strictly better; it blocks the *wording* "wedge survived.")

## Files & changes

| File | Change |
|---|---|
| `patches/addon/A9-egpu-probe-classify.patch` | **NEW.** Single hunk in `nv_pci_probe` inserting the probe-set line after `nv->handle = pci_dev;`. Prose header per the A6/A8 convention. |
| `docs/patch-intents/A9-egpu-probe-classify.md` | **NEW.** Intent doc (A6/A8 style): SHALL classify at probe; the dual-writer (probe-set + blob's TRUE-only `osinit.c:1301`) is intentionally monotonic; **assert the no-FALSE-writer invariant**; scope = H-OA1 first-open only; `RmForceExternalGpu` retired; status `needs-review`. |
| `patches/manifest` | Add A9 to the addon manifest in compose order (after the A6/A8 region; A9 only writes a field A6/A7 read — no cross-TU reach, satisfies the addon-recarve invariant). |
| `docs/patches.md`, `docs/upstream-plan.md` | Record A9 as `A`=Addon (project-local); note E1 stays upstream-clean. |
| **A8 v2.2** (`tb_egpu_is_external`, already committed `bcdd58c`) | Deployed *with* A9 (bundles #288). No code change — it just becomes accurate-from-probe. |
| E1, A6, A7 patches | **UNCHANGED.** |

Fork: amend/extend the `a9` branch (new), regenerate via `regen-base-patches.sh` (preserving the addon prose-header convention as done for A6/A7/A8). Local only; fork push + deploy gated.

## Settled decisions
- **Approach:** probe-time set in the open driver, Addon layer (A9). E1/A6/A7 gates unchanged.
- **#1 survivability:** ship scoped; queue the destructive test; do not block deploy.
- **#2 residual gaps:** defer the A6 leaked-worker hardening (sink-aware self-terminating worker + join guard) to a coupled follow-up (v5-aligned, test-driven).
- **#3 shape:** standalone `A9-egpu-probe-classify.patch`.
- **#4 wording:** "closes the A6-coverable first-open (H-OA1) hole," never "fixes the open-arm wedge."

## Cross-refs
Forensics `experiments/OA-reset-ladder-wedge-forensics-2026-05-31.md` · ledger `open-arm-forensics-ledger.md` · A8 v2.2 intent · v5 queue `docs/architecture-v5-deep-review-queued.md` (A6 leak→join follow-up) · design panel run `wg9ytrfzk`.
