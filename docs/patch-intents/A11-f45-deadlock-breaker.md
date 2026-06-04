---
id: A11-f45-deadlock-breaker
layer: addon
source-branch: a11-f45-deadlock-breaker
upstream-candidacy: medium
telemetry-tier: none
status: v1-implemented-compiled-validated
related-patches: [C6-cond-acquire-rwlock-fix, A9-egpu-probe-classify, C5-crash-safety]
---

# A11-f45-deadlock-breaker — Break the F45 Cold-Bringup RM-API-rwsem Deadlock

## Purpose

The driver SHALL NOT let a FAILED cold open of an external GPU wedge the
host on the global RM API lock (the F45 deadlock). When a cold first-open
of a Thunderbolt/USB4 eGPU fails (e.g. the stochastic H16 PCIe transient
at GSP boot → GSP heartbeat timeout → `RmInitAdapter (0x62:0xf)` → C5 sink
declares the GPU lost), the single-threaded `nv_open_q` deferred-open
worker proceeds to read adapter status via `rm_get_adapter_status` →
`rmapiLockAcquire`. On the deployed driver that acquire is BLOCKING, so
the worker parks behind a held/contended API write lock and can never
reach `complete_all(&nvlfp->open_complete)`. That single parked worker
transitively wedges (a) the close's `nv_wait_open_complete`, (b) the
pciehp surprise-removal `nv_kthread_q_flush` of the same single-threaded
queue, and (c) any other RM-API entrant — a reboot-only deadlock proven
immune to SIGKILL, FLR, and TB unauthorize/reauthorize (2026-06-02 obpc
wedge; `docs/missions/.../wedge-2026-06-02-coldboot-apilock-deadlock.md`).
The persistent capability granted: "a failed cold eGPU open is a bounded,
survivable event — the status read never blocks the deferred-open worker."

## Requirements

### Requirement: A failed external-GPU open must not block the deferred-open worker on the API lock

For an external GPU (`nv->is_external_gpu`), when a cold open fails, the
driver SHALL determine the open's adapter status WITHOUT a blocking RM API
lock acquire, so the `nv_open_q` worker always returns and signals
`open_complete`.

#### Scenario: D1 — failed open of an already-lost eGPU
- **GIVEN** an external GPU whose cold open failed AND which is already declared lost (`os_pci_is_disconnected` set by the C5 sink, or surprise removal)
- **WHEN** `nv_open_device_for_nvlfp` reaches the open-failure arm
- **THEN** it MUST set `adapter_status = NV_ERR_GPU_IS_LOST` WITHOUT calling `rm_get_adapter_status_external` (no RM API lock round-trip)
- **AND** the worker MUST proceed to `complete_all(&open_complete)` and return.

#### Scenario: A11 — failed open of a not-yet-lost but contended eGPU
- **GIVEN** an external GPU whose cold open failed but is not yet marked lost, and the RM API lock is currently contended
- **WHEN** `rm_get_adapter_status` runs (gated `RMAPI_LOCK_FLAGS_COND_ACQUIRE`)
- **THEN** `rmapiLockAcquire` MUST return `NV_ERR_TIMEOUT_RETRY` without blocking
- **AND** `rm_get_adapter_status` MUST return its best-effort default `NV_ERR_OPERATING_SYSTEM` and MUST NOT call `rmapiLockRelease`.

#### Scenario: Healthy and discrete GPUs are unchanged
- **GIVEN** a successful open, OR any discrete (non-external) GPU
- **WHEN** the open path runs
- **THEN** behaviour MUST be byte-for-byte identical to the unpatched driver (D1's `else if` is false; A11's flag is not set).

## Scope boundary

- This patch is a DEADLOCK BREAKER, NOT a cold-bringup reliability fix —
  the stochastic H16 transient still strands the chip lost (unusable until
  re-probe). Bounded cold-init retry is a separate task.
- `adapter_status` is best-effort telemetry, surfaced only as a userspace
  diagnostic (`NV_ESC_WAIT_OPEN_COMPLETE`, `NV_ESC_STATUS_CODE`); it is
  never an internal control-flow gate, so the contended fallback is benign.
- Out-of-scope: the F44 re-open lockdown wedge (that is A10-v2).
- **Residual limit (no vmcore):** the cut frees the worker + pciehp flush
  + close. If a 5th, uncaptured thread *permanently* holds the API write
  lock (vs. transient starvation), other waiters remain wedged and reboot
  is still required. All source evidence points to transience; confirming
  needs a live `drgn` read of `g_RmApiLock` on the next occurrence.

## Telemetry contract

None.

## Validation

- **Compile:** full composed set (C6 + C1–C5 + E1 + A1–A9 + A11) applies in
  order and `make modules` passes via `regen-base-patches.sh`.
- **Live (pending):** must reliably hit the F45 substrate (cold-init
  failure on an eGPU) and show the deferred-open worker returns + the host
  stays alive. Capture the holder via `drgn`/netconsole — NOT kdump (the
  capture kernel hangs re-probing the wedged eGPU; see
  `wedge-2026-06-02-kdump-capture-failure-forensics.md`).

## Provenance

- **Vanilla baseline:** `kernel-open/nvidia/nv.c` `nv_open_device_for_nvlfp`;
  `src/nvidia/arch/nvalloc/unix/src/osapi.c` `rm_get_adapter_status`.
- **Fork branch:** `a11-f45-deadlock-breaker` (off `a9`), commit `2532aac9`.
- **Design:** `docs/missions/mission-1-egpu-hot-plug-hot-power/f45-deadlock-fix-design-workflow-2026-06-02.json` (8-agent design + adversarial review).
- **Ordering constraints:** MUST apply after [[C6-cond-acquire-rwlock-fix]]
  (A11's COND_ACQUIRE depends on the corrected primitive) and after
  [[A9-egpu-probe-classify]] (the `is_external_gpu` gate). Disjoint from A10/A10-v2.
- **Upstream issue:** candidate after live validation; n/a filed.
