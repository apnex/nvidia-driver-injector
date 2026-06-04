---
id: A10-f40b-lockfree-sink
layer: addon
source-branch: a10-f40b-lockfree-sink
upstream-candidacy: medium
telemetry-tier: nominal
status: v2-implemented-compiled-validated
related-patches: [C6-cond-acquire-rwlock-fix, A9-egpu-probe-classify, C5-crash-safety, A6-f40b-bounded-wait-open, A11-f45-deadlock-breaker]
---

# A10-f40b-lockfree-sink (v2) — Contain the F44 Re-open Lockdown Wedge Without Dead-Busing the Fast-Fail

## Purpose

The driver SHALL contain the F44 re-open lockdown wedge (a re-open of a
cleanly-shut-down, WPR2=0, but #979-divergent eGPU hard-wedges the host)
WITHOUT permanently dead-busing the chip on the common WPR2-fast-fail
re-open. The A6 200ms open bounded-wait timeout fires on TWO substrates
that need OPPOSITE handling, and the deployed A6 (and the abandoned
A10-v1) conflated them by sinking the bus on BOTH. The persistent
capability granted: "a bounded-open timeout that distinguishes a returned
fast-fail worker (chip recoverable — do NOT sink) from a stuck lockdown
worker (force-terminate the GSP poll), so neither the host wedges nor a
recoverable chip is bricked."

## Corrected mechanism + baseline (the record this v2 fixes)

- **True F44 lock cycle (relaxed locking):** on a consumer 5090 relaxed GSP
  init locking is ON by default — `_kgspBootGspRm` RELEASES the RM API
  write-lock (`kernel_gsp.c:4785`) BEFORE the bootstrap poll and reacquires
  after. So across the `gpuTimeoutCondWait` lockdown poll the worker holds
  the GPU GROUP lock, **not** the API lock. The wedge is NOT an API-lock
  inversion (the prior RCA + in-tree comments were FALSE): it is the
  foreground sitting in `flush_work` HOLDING `nvl->ldata_lock` until the
  worker leaves the multi-second poll, while a second `ldata_lock` contender
  (rmmod/close/AER `error_detected`) piles up behind it → silent host wedge
  (`CONFIG_DETECT_HUNG_TASK` unset).
- **Corrected baseline (the false "self-heal"):** the deployed A6 timeout
  branch calls `rm_cleanup_gpu_lost_state` unconditionally; on the
  WPR2-fast-fail the worker has RETURNED by ~205-210ms, the path never sets
  `PDB_PROP_GPU_IS_LOST`, so `cleanupGpuLostStateAtomic`'s idempotency gate
  (`os.c:1935`) is FALSE and it calls `os_pci_set_disconnected` (`os.c:1942`)
  = the PERMANENT `pci_channel_io_perm_failure` sink. So **the deployed
  driver permanently dead-buses the chip on the FIRST fast-fail timeout**;
  it does NOT self-heal in-driver (the `rc=0` re-opens in r2/r3/r4 were
  budget-completing opens BEFORE the first sink; recovery was always an
  external `fix-bar1` rebind). A10-v2 makes the fast-fail recoverable
  in-driver for the first time.

## Requirements

### Requirement: The bounded-open timeout must not sink a recoverable fast-fail chip

On the A6 open bounded-wait timeout for an external GPU, the driver SHALL
distinguish the fast-fail substrate (worker returned) from the lockdown
substrate (worker stuck) and SHALL NOT mark the bus disconnected on the
former.

#### Scenario: WPR2-fast-fail — worker returns within the grace
- **GIVEN** an external-GPU open whose worker fails `rm_init_adapter` at the WPR2 check and returns just over the 200ms budget
- **WHEN** the A6 timeout branch runs a bounded `NVreg_TbEgpuOpenGraceMs` (default 50ms) grace re-wait and the worker's completion fires within it
- **THEN** the driver MUST skip BOTH `os_pci_set_disconnected` AND `rm_cleanup_gpu_lost_state`
- **AND** `pdev->error_state` MUST remain `pci_channel_io_normal` (a subsequent open MUST be able to succeed; `PDB_PROP_GPU_IS_LOST` MUST NOT be set).

#### Scenario: WPR2-clear lockdown — worker still stuck after the grace
- **GIVEN** an external-GPU open whose worker is stuck in `kgspBootstrap_GH100` → `gpuTimeoutCondWait` (chip never releases lockdown)
- **WHEN** the grace re-wait expires with the worker still in-flight
- **THEN** the driver MUST set the lock-free `os_pci_set_disconnected` marker FIRST (so the worker's poll cond self-terminates via `osIsGpuBusDead`), THEN run `rm_cleanup_gpu_lost_state`
- **AND** `flush_work` MUST join in ~ms (not the full RM gpuTimeout), so the foreground releases `ldata_lock` and no second contender wedges.

#### Scenario: Healthy opens, dGPUs, and the shutdown path are unchanged
- **GIVEN** an open that completes within budget, OR a discrete (non-external) GPU, OR the A7 shutdown-path timeout
- **THEN** behaviour MUST be unchanged (the discriminator is OPEN-path + `is_external_gpu`-gated only; A7 stays unconditional — its worker runs `rm_shutdown_adapter`, never `kgspBootstrap`, so there is no fast-fail twin).

## Scope boundary

- The lockdown half ships validated by **source derivation + the deterministic
  fast-fail self-heal gate only** — the lockdown substrate is stochastic and
  cannot be triggered on demand on hardware; on-demand validation needs the
  fake-5090 F44 model ([[F44]], task #290, deferred).
- Out-of-scope: the cold-bringup reliability of the eGPU (the H16 transient
  that produces the lost state); the F45 deferred-open deadlock (that is A11).
- The completion discriminator depends on `complete(&w->done)` firing only on
  worker RETURN (never mid-GSP-retry), which holds for the current worker.

> **⚠️ FOLLOW-UP 2026-06-04 — grace must exceed a healthy full cold init.** The
> discriminator only distinguishes "worker returned" from "worker stuck" if the
> grace is long enough to *wait for* a slow-but-healthy worker to return. A
> healthy **full cold init** (`RmInitAdapter`) through the A6 path measures
> **~1.3 s** (n=3, 2026-06-04 `fastfail` run). With the production grace at
> **50 ms** (and A6 budget 200 ms), a healthy cold open that takes the A6-bounded
> H-OA1 path is mis-classified as lockdown and **sunk** — a healthy-chip dead-bus,
> not a real stuck poll. The deployed config avoids this only because production
> cold inits run off-A6 (H-OA2 / persistence engage); it breaks for a CUDA
> consumer opening a cold adapter directly (no-persistence / recovery race /
> upstream). Fix = raise A6 `NVreg_TbEgpuOpenTimeoutMs` (so a healthy cold init
> completes-within-budget → open succeeds) AND/OR raise `NVreg_TbEgpuOpenGraceMs`
> (so it fast-fails → chip preserved). Pending a worst-case cold-init measurement.
> Full analysis: `docs/missions/mission-1-egpu-hot-plug-hot-power/finding-2026-06-04-a6-open-budget-vs-healthy-cold-init.md`. The `fastfail` validation
> on 2026-06-04 PASSED only because it overrode the grace to 30000 ms — i.e. it
> proved the *mechanism*, while incidentally exposing that the *default* grace is
> the misclassifier.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| fast-fail (chip not sunk) | `NV_DBG_ERRORS` | `"open timed out after %u ms but worker returned rc=%d within +%u ms grace — fast-fail, chip NOT sunk (recoverable)"` |
| lockdown (sink) | `NV_DBG_ERRORS` | `"open timed out after %u ms + %u ms grace, worker still in GSP lockdown poll — declaring GPU lost (DETECTOR_AER_FATAL); dead-bus marker + sink"` |

Plus the existing `nv_tb_egpu_f40b_fired()` counter (fires on both arms).

## Validation

- **Compile:** full composed set (C6 + C1–C5 + E1 + A1–A9 + A11 + A10) applies in
  order and `make modules` passes; the apnex.28 image was built and the composed
  source verified to carry C6's corrected primitive + C1 + the discriminator.
- **Implementation red-team:** an independent adversarial review confirmed the
  nv.c discriminator (completion semantics, jiffies_left reuse, grace=0 fallback,
  UAF guard both arms, A7 unconditional, format specifiers, no dropped lines).
- **Live (fast-fail, deterministic):** n≥3 — `error_state` stays normal,
  next open rc=0, `PDB_PROP_GPU_IS_LOST` not set (drgn). Passive reads only.
- **Live (lockdown):** source-derived; the rung5 tb-only repro (now expected to
  be contained) + fake-5090 F44 model.

## Provenance

- **Vanilla baseline:** `kernel-open/nvidia/nv.c` `nv_open_device_for_nvlfp_bounded`
  A6 timeout branch; `src/nvidia/arch/nvalloc/unix/src/osapi.c` `rm_cleanup_gpu_lost_state` (C1).
- **Fork branch:** `a10-f40b-lockfree-sink` (off `a9`), commit `e51a664e` (v2; amended over the abandoned A10-v1 `d2a4e514`).
- **Design:** `docs/missions/mission-1-egpu-hot-plug-hot-power/f44-a10v2-rederive-workflow-2026-06-02.json` (8-agent re-derivation + adversarial review — the THIRD pass; the first two A10 designs were each built on a false premise).
- **Ordering:** MUST apply after [[C6-cond-acquire-rwlock-fix]] (C1's COND_ACQUIRE is corruption without it) and [[A9-egpu-probe-classify]] (the gate). Disjoint from [[A11-f45-deadlock-breaker]].
- **Supersedes the FALSE claims** in the older lockdown-reopen forensics + several patch-intent docs that the deployed driver "self-heals the fast-fail" — it does not.
