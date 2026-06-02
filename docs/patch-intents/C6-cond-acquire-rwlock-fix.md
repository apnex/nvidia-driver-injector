---
id: C6-cond-acquire-rwlock-fix
layer: base
source-branch: c6-cond-acquire-rwlock-fix
upstream-candidacy: high
telemetry-tier: none
status: v1-implemented-compiled-validated
related-patches: [A10-f40b-lockfree-sink]
---

# C6-cond-acquire-rwlock-fix — Correct the Inverted Conditional rwsem Acquire Primitive

## Purpose

The driver SHALL implement the conditional read/write rwsem acquire
primitives `os_cond_acquire_rwlock_read` / `os_cond_acquire_rwlock_write`
(`kernel-open/nvidia/os-interface.c`) with the correct success/failure
polarity, so that `API_LOCK_FLAGS_COND_ACQUIRE` on the global RM API lock
is genuinely non-blocking AND reports acquisition truthfully. The base
(stock) primitives are **inverted**: they were written with the
`down_trylock()` body (`if (trylock) return TIMEOUT_RETRY`) but
`down_{read,write}_trylock()` use the OPPOSITE Linux convention —
**1 = acquired, 0 = contended** — versus `down_trylock()`'s 0 = acquired
(the convention the correct `os_cond_acquire_mutex`/`_semaphore` in the
same file rely on). Empirically confirmed on the running kernel
(7.0.9-204.fc44): `down_write_trylock` returns 1 free / 0 held.

Consequence of the base bug: a SUCCESSFUL conditional acquire returned
`NV_ERR_TIMEOUT_RETRY` and **leaked the held rwsem**; a CONTENDED acquire
returned `NV_OK`, so the caller ran the protected body and then released a
lock it never held → **rwsem count corruption / releasing another
thread's lock**. The bug was latent since the base commit because no
stock code takes the RM API lock with `COND_ACQUIRE`. The first and only
consumer is [[A10-f40b-lockfree-sink]]'s `rm_cleanup_gpu_lost_state`
`COND_ACQUIRE` (`osapi.c:1913`), so the shipped F44 mitigation was a
corruption hazard rather than a working containment on its contended
path. The persistent capability granted: "a conditional RM-API-lock
acquire either takes the lock and says so, or takes nothing and says so —
never the reverse." This unblocks the F45 deadlock-breaker (the
eGPU-gated `COND_ACQUIRE` at `rm_get_adapter_status`), which would
otherwise inherit the corruption.

## Requirements

### Requirement: Conditional rwsem acquire reports acquisition truthfully

The driver SHALL, for both the read and write conditional rwsem acquire
primitives, return `NV_OK` **if and only if** the lock was acquired (and
is now held by the caller), and `NV_ERR_TIMEOUT_RETRY` if and only if the
lock was NOT acquired (and is NOT held). The primitive SHALL NOT block.

#### Scenario: Uncontended conditional acquire
- **GIVEN** the rwsem is free
- **WHEN** `os_cond_acquire_rwlock_write` (or `_read`) is called
- **THEN** it MUST return `NV_OK`
- **AND** the caller MUST hold the lock (a subsequent `rmapiLockIsOwner()` MUST be true) and MUST release it.

#### Scenario: Contended conditional acquire
- **GIVEN** the rwsem is held by another context
- **WHEN** `os_cond_acquire_rwlock_write` (or `_read`) is called
- **THEN** it MUST return `NV_ERR_TIMEOUT_RETRY` without blocking
- **AND** the caller MUST NOT hold the lock and MUST NOT call the matching release.

## Scope boundary

- This patch deliberately does NOT add any new `COND_ACQUIRE` consumer
  (the F45 site fix at `rm_get_adapter_status` is a SEPARATE patch that
  DEPENDS on this one).
- Out-of-scope: the blocking acquire paths (`os_acquire_rwlock_*`) — unchanged.
- Out-of-scope: the stochastic H16 cold-init reliability failure (F45
  trigger) — this patch only makes conditional acquires correct.
- Does NOT alter behaviour on any path that never takes a conditional
  acquire (i.e. all stock GPUs, normal operation) — the only runtime
  consumer is A10's gpu-lost cleanup on its contended branch.

## Telemetry contract

None. This is a correctness fix to a primitive; it adds no events.

## Validation

- **Compile:** real `make modules` against `7.0.9-204.fc44.x86_64` —
  clean, `LD [M] nvidia.ko` (not apply-check).
- **Empirical convention proof:** a throwaway kernel module
  (`down_write_trylock` free vs held) confirmed `1=acquired / 0=contended`
  on the live kernel — the exact fact the `!` depends on. Result:
  `C6TEST: free=1 held=0 -> CONFIRMED`.
- **Recommended follow-up (debug gate):** assert `rmapiLockIsOwner()==true`
  after a `COND_ACQUIRE` returns `NV_OK` (helper exists, used at
  `kernel_gsp.c`); this is the in-driver positive-assertion that would
  have caught the inversion.

## Provenance

- **Vanilla baseline:** `kernel-open/nvidia/os-interface.c` —
  `os_cond_acquire_rwlock_read` / `_write`, stock as of base commit
  `51edebee` (Andy Ritger, NVIDIA, 2026-04-28).
- **Fork branch:** `c6-cond-acquire-rwlock-fix` on `apnex/open-gpu-kernel-modules`, commit `a2af3389`.
- **Discovery:** F45 cold-bringup deadlock investigation, 2026-06-02
  (`docs/missions/mission-1-egpu-hot-plug-hot-power/f45-deadlock-fix-design-workflow-2026-06-02.json`).
- **Upstream issue:** genuine NVIDIA bug; upstream-report candidate AFTER
  a tested fix per project policy. n/a filed yet.
- **Reopens:** [[A10-f40b-lockfree-sink]] / F44 validation — C1/A10's
  contained-path behaviour was never exercised in its intended form
  (depended on this then-broken primitive); re-soak after this lands.
