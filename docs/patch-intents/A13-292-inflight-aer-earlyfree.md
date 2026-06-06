---
id: A13-292-inflight-aer-earlyfree
layer: addon
source-branch: a13-292-inflight-aer-earlyfree
upstream-candidacy: n/a
telemetry-tier: mandatory
status: deployed-insufficient-superseded
related-patches: [C7-292-inflight-deadbus-poll-coverage, A14-292-reopen-failfast-gate, A10-f40b-lockfree-sink, A12-init-funnel, A3-recovery]
---

# A13-292-inflight-aer-earlyfree — In-Flight AER Early Dead-Bus Marker (the lock-free marker SOURCE that C7's poll-readers honor)

## Purpose

On an AER fault that fires while a GSP bringup is **in flight** (the #292
substrate: a persistence-OFF re-open of a #979-EQ-diverged TB-tunneled RTX
5090 dies mid-init, raising an Uncorrectable Non-Fatal CmpltTO on the now-dead
chip), the driver SHALL set the **lock-free Linux dead-bus marker**
`os_pci_is_disconnected` **early** — from the `nv_pci_error_detected` handler,
gated on an in-flight flag, BEFORE the standard DISCONNECT sink runs — and SHALL
take the DISCONNECT branch **without** issuing a bus reset. This early marker is
intended to let an in-flight GSP poll-engine worker self-terminate (so the
foreground releases `nvl->ldata_lock` from its bounded-wait and the host does
not wedge). A13 deployed live as **apnex.31 and live-FAILED 2026-06-06**: the
marker is **necessary but insufficient ALONE** — the marker it sets is honored
only by the os.c MMIO readers, not by the GSP RPC poll engine, so the wedge
merely *moved* deeper. A13 is therefore retained NOT as a standalone fix but as
the **marker SOURCE** that the [[C7-292-inflight-deadbus-poll-coverage]]
read-only poll-readers consume; the marker source MUST be kept verbatim and is
extended in place (A13', see below) to close a funnel gap and a lock-model
comment regression. Build target for the corrected composition: `apnex.32`.

## What A13 does, the live FAIL, and the two corrections (the record this intent pins)

**What A13 does (deployed apnex.31, verbatim, KEPT):**

- `nv.c` `nv_bootstrap_bounded` (the A12 open/resume funnel) arms a per-device
  in-flight flag `atomic_set(&nvl->bootstrap_in_flight, 1)` (nv.c:1924) around
  the GSP-bringup `queue_work`, cleared on both worker-return arms (nv.c:1937
  normal completion, nv.c:2040 grace/timeout).
- `nv-pci.c` `nv_pci_error_detected`: when `bootstrap_in_flight` is set
  (nv-pci.c:2974) it calls `os_pci_set_disconnected(lost_nv->handle)`
  (nv-pci.c:2981) — a **lock-free** `WRITE_ONCE` of the Linux marker — and
  returns the DISCONNECT result (no bus reset). The DISCONNECT branch's full
  sink `rm_cleanup_gpu_lost_state(AER_FATAL)` (nv-pci.c:3023) still dispatches
  but acquires the RM API lock with `API_LOCK_FLAGS_COND_ACQUIRE` (the
  non-blocking C1/C6 F44 acquire).

**The LIVE FAIL (apnex.31, 2026-06-06, host wedged, 2 reboots; capture
`netcon3-2026-06-06-A13-live-FAIL-rpcpoll-wedge.log`):** the AER half fired
correctly (marker set at +1.0 s, DISCONNECT, no bus reset), but the re-open had
already advanced **past** the lockdown gate and died mid-RPC; the wedge **moved
to a `_kgspRpcRecvPoll` GSP-heartbeat-timeout STORM** (hundreds of
`GSP RM / LibOS heartbeat timed out` + `_kgspIsHeartbeatTimedOut ... 5200` +
`tmrGetTimeEx_GH100: Consistently Bad TimeLo value ffffffff`, ~3 lines/iter).
`_kgspRpcRecvPoll` keys its pre-loop abort on
`bFatalError || PDB_PROP_GPU_IS_LOST` (kernel_gsp.c:2813-2814) — **NOT** on
`os_pci_is_disconnected`. `osIsGpuBusDead` (= `os_pci OR PDB`, os.c:1884) is
absent from `kernel_gsp.c`/`gpu_timeout.c`, so the GSP poll engines are
structurally blind to A13's Linux marker. The storming worker holds the GPU
group lock; the foreground stays parked in the bounded-wait holding
`nvl->ldata_lock` across `flush_work` → F44 wedge, amplified by the synchronous
netconsole printk-storm at `console_loglevel=8`.

**Correction 1 — A13 covered the lockdown poll only BY ACCIDENT.** The dead-bus
"coverage" from `os_pci` is per-poll and accidental, mediated entirely by the
os.c MMIO readers returning `0xFFFFFFFF` (`NV_GPU_BUS_DEAD_VALUE_U32`).
`_kgspLockdownReleasedOrFmcError` (gh100:1050) returns TRUE on `mailbox0 != 0`,
and `0xFFFFFFFF != 0` → the lockdown `gpuTimeoutCondWait` exits in **one
iteration**. That is the *only* reason A13 advanced past the lockdown gate. The
polarity-trap sibling `_kgspFalconMailbox0Cleared` (gh100:662) waits for
`mailbox0 == 0`; `0xFFFFFFFF != 0` is never satisfied → `os_pci` makes that poll
*worse*. Dead-value coverage is fragile/whack-a-mole, not load-bearing.

**Correction 2 — A13 is COUNTERPRODUCTIVE, not merely insufficient.** Setting
`os_pci_is_disconnected` early makes `osDevReadReg032` short-circuit and return
`NV_GPU_BUS_DEAD_VALUE_U32` at os.c:2050 **before** ever reaching the post-read
`DETECTOR_MMIO_DEAD` funnel (os.c:2081-2092) that calls
`cleanupGpuLostStateAtomic(DETECTOR_MMIO_DEAD)` and sets **both** markers
(including `PDB_PROP_GPU_IS_LOST`, the one `_kgspRpcRecvPoll` actually honors).
The vanilla surprise-removal path self-heals *because* that detector fires; A13
**suppressed** the one self-heal path that would have eventually set the PDB bit
for the re-open. (Note: even the AER-thread sink at nv-pci.c:3023 cannot rescue
this — the worker REACQUIRES the API lock at kernel_gsp.c:4818-4820 for the
post-INIT_DONE control RPCs, so `rm_cleanup`'s `COND_ACQUIRE` **defers** during
the storm; PDB is never set. Do NOT route PDB through `rm_cleanup` from the AER
thread, and do NOT make `COND_ACQUIRE` blocking — that re-introduces the F44
wedge C1/C6 fixed.)

**The redesigned composition (apnex.32):** the load-bearing fix is
[[C7-292-inflight-deadbus-poll-coverage]] — a read-only `osIsGpuBusLost(pGpu)`
predicate inserted at the 2 GSP engine chokepoints (`timeoutCondWait`,
`_kgspRpcRecvPoll`) + the 3 hand-rolled poll loops (all 13 reachable poll-sites)
so every poll engine *reads* the lock-free marker A13 sets. A13 supplies the
**marker source**; C7 supplies the **reader**. A14 (fix-bar1 sticky fail-fast
gate) is defense-in-depth, shipped WITH C7, never instead.

**The A13' EXTENSION (planned; same A13 patch extended IN PLACE, not a new
patch):**

- **A13'-e1 (GAP-1, REQUIRED):** the in-flight flag is armed **only** in
  `nv_bootstrap_bounded`. The **second** GSP-bringup funnel
  `nv_dynpower_bounded` (RTD3/GC6 resume → `rm_transition_dynamic_power`,
  nv.c:2094-2117) has its own `queue_work` and arms nothing → on a dynpower-driven
  re-bringup the AER early-free never fires and the wedge reproduces regardless
  of poll coverage. A13' arms `bootstrap_in_flight` around the dynpower
  `queue_work` and clears it on both return arms, mirroring nv.c:1924/1937/2040.
- **A13'-e3 (GAP-5, REQUIRED):** the A12 lock-model comment (nv.c:1959-1968) and
  the JOIN-COST comment (nv.c:2027-2036) state the worker "holds the GPU GROUP
  lock, NOT the API lock, across the poll." Source shows this holds **only for
  the lockdown window**: `kgspInitRm` releases the API lock at kernel_gsp.c:4785
  across the lockdown cond but **REACQUIRES** it at 4818-4820 for the
  post-INIT_DONE control-RPC phase. The stale comment silently underwrites the
  false belief that the lockdown-arm `rm_cleanup` `COND_ACQUIRE` "will succeed" —
  it **defers** during the RPC storm. A13' corrects the comment to say the
  lock-free `os_pci` marker + C7 poll-readers (not `rm_cleanup`'s PDB set) free
  the poll.
- **A13'-e2:** **no change** to the nv-pci.c early-free block (2974-2982) — keep
  `os_pci_set_disconnected` first; keep the DISCONNECT-branch
  `rm_cleanup_gpu_lost_state` (3023) unchanged; do NOT weaken `COND_ACQUIRE`.

## Requirements

### Requirement: An in-flight AER must set the lock-free dead-bus marker early, with no bus reset

When an AER `error_detected` callback fires for an external GPU whose GSP
bringup is in flight, the driver SHALL set the lock-free `os_pci_is_disconnected`
marker before the standard DISCONNECT sink, and SHALL return the DISCONNECT
result WITHOUT issuing a bus reset. The marker write MUST remain lock-free; the
handler MUST NOT acquire (and MUST NOT block on) the RM API lock or the GPU group
lock that the in-flight worker holds.

#### Scenario: AER CmpltTO during an in-flight re-open bootstrap
- **GIVEN** a persistence-OFF re-open of a diverged eGPU whose `nv_bootstrap_bounded` worker is in flight (`bootstrap_in_flight == 1`)
- **WHEN** the re-open's MMIO touch raises an Uncorrectable Non-Fatal CmpltTO and `nv_pci_error_detected` runs
- **THEN** the handler MUST call `os_pci_set_disconnected` (lock-free) at nv-pci.c:2981 and MUST take the DISCONNECT branch
- **AND** it MUST NOT trigger a bus reset, and MUST NOT block on the worker's locks.

#### Scenario: AER outside any in-flight bootstrap is unchanged
- **GIVEN** an AER `error_detected` for a GPU with `bootstrap_in_flight == 0`
- **WHEN** the handler runs
- **THEN** behaviour MUST be byte-identical to the pre-A13 path (the early-free block is bypassed; the standard DISCONNECT/sink logic is unchanged).

### Requirement: The in-flight flag MUST be armed on BOTH GSP-bringup funnels (A13'-e1, GAP-1)

The `bootstrap_in_flight` flag SHALL be armed around the `queue_work` of BOTH
GSP-bringup funnels — `nv_bootstrap_bounded` (open/resume) AND
`nv_dynpower_bounded` (RTD3/GC6 resume) — and SHALL be cleared on every
worker-return arm of each. The driver MUST NOT leave the dynpower funnel
unarmed, since the AER early-free would otherwise never fire on a dynpower-driven
re-bringup.

#### Scenario: RTD3/GC6 resume re-bringup raises an in-flight AER
- **GIVEN** a diverged eGPU idled into GC6/RTD3, then touched, driving `nv_dynpower_bounded` to queue a `rm_transition_dynamic_power` worker
- **WHEN** the dynpower-driven re-bringup dies and raises an AER while that worker is in flight
- **THEN** `bootstrap_in_flight` MUST already be set (armed around the dynpower `queue_work`, nv.c:2094-2117) so the AER early-free fires on this funnel too
- **AND** the flag MUST be cleared on both the normal-completion and grace/timeout return arms.

### Requirement: The lock-model comment MUST reflect the API-lock reacquisition (A13'-e3, GAP-5)

The A12 lock-model comment and the JOIN-COST comment SHALL be corrected to state
that the worker releases the API lock across the lockdown cond (kernel_gsp.c:4785)
but REACQUIRES it across the post-INIT_DONE control-RPC phase (4818-4820), and
that `rm_cleanup`'s `COND_ACQUIRE` MAY therefore DEFER during the RPC storm. The
comment MUST NOT continue to assert that the worker holds only the group lock for
the whole poll, and MUST attribute worker-freeing to the lock-free `os_pci`
marker plus the C7 poll-readers, not to `rm_cleanup`'s PDB set.

#### Scenario: A maintainer reads the in-flight lock model in source
- **GIVEN** the corrected nv.c:1959-1968 and nv.c:2027-2036 comments
- **WHEN** a reviewer reasons about whether the AER-thread sink can set `PDB_PROP_GPU_IS_LOST` during the RPC storm
- **THEN** the comment MUST make clear the API lock is reacquired for post-INIT_DONE RPCs and the `COND_ACQUIRE` sink defers
- **AND** it MUST NOT perpetuate the false "rm_cleanup will succeed" assumption that produced the live FAIL.

## Scope boundary

- A13 is **NOT a standalone fix for #292** — it is `deployed-insufficient-superseded`.
  Setting the marker is necessary but insufficient; the loop-exit coverage is
  delivered by [[C7-292-inflight-deadbus-poll-coverage]]. Do NOT claim #292 fixed
  on A13 alone.
- A13 does NOT (and MUST NOT) set `PDB_PROP_GPU_IS_LOST` from the AER thread.
  The rejected A13b variant (lock-free `gpuSetDisconnectedProperties` /
  `cleanupGpuLostStateAtomic` from AER) clobbers 7 live PM bits
  (`PDB_PROP_GPU_IN_PM_CODEPATH`, `IN_STANDBY`, `bInD3Cold`, `IN_HIBERNATE`,
  `GC6_STATE`, `IS_CONNECTED`, `IS_LOST`) racing a dynpower worker, and violates
  the `NV_GET_NV_PRIV_PGPU` API-lock precondition (nv-priv.h:352). Out of scope.
- A13 does NOT weaken `rm_cleanup`'s `COND_ACQUIRE` to a blocking acquire (that
  re-introduces the F44 wedge C1/C6 fixed). Out of scope.
- A13 does NOT cover any GSP poll loop's abort predicate (it cannot — the GSP
  engines never read `os_pci`); it only changes what an MMIO *read returns*. The
  abort-predicate coverage is C7's job.
- The fix-bar1 sticky fail-fast gate (refuse the diverged re-open before any GSP
  poll is entered) is [[A14-292-reopen-failfast-gate]], not A13.
- A13' is an **in-place extension** of the existing A13 patch on the same fork
  branch, not a new patch id.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| In-flight AER early marker (the A13 fire) | `NV_DBG_ERRORS` | `"tb_egpu recover: AER during in-flight bootstrap -> early dead-bus marker ... (#292)"` |
| DISCONNECT result (no bus reset) | `NV_DBG_ERRORS` | `"error_detected -> DISCONNECT (sink-set ...)"` |
| In-flight funnel arm (open + dynpower, A13') | `NV_DBG_INFO` | `"open scheduled to bounded worker (timeout=%u ms)"` / dynpower-resume equivalent (bootstrap_in_flight armed) |

`mandatory` tier: without these lines the early-marker fire is invisible
(silent `WRITE_ONCE`), and the apnex.31 capture analysis that proved the wedge
*moved* to `_kgspRpcRecvPoll` depended on netconsole-captured AER + storm lines.
Per the observability-perturbs-the-bug discipline, capture passively (netconsole
/ `/dev/kmsg`); the synchronous printk-storm at `console_loglevel=8` is itself a
co-cause of the wedge severity — validation runs C7 at dual loglevel.

## Validation

- **Live (apnex.31, 2026-06-06): FAILED.** Primary repro = fix-bar1 `--bind` the
  32 GiB-diverged chip → engage then DISABLE persistence → LAST-CLOSE → THE ROLL
  `nvidia-smi -L`. AER half fired correctly (marker at +1.0 s, DISCONNECT, no bus
  reset) but the host wedged in a `_kgspRpcRecvPoll` heartbeat-timeout storm; 2
  reboots. Capture `netcon3-2026-06-06-A13-live-FAIL-rpcpoll-wedge.log`.
  Root-caused to the two-marker truth (Correction 1 + Correction 2 above).
- **No standalone re-validation of A13 is planned.** A13's marker source is
  re-validated only as part of the apnex.32 C7+A13'+A14 composition: dual
  loglevel (8 and 4), n≥3, on BOTH the open funnel and the dynpower funnel
  (A13'-e1 runtime-PM repro), with every poll-site demonstrably short-circuiting
  and zero storm lines in the capture. Acceptance + the no-regression matrix are
  specified in the design-of-record §5/§4.

## Provenance

- **Vanilla baseline:** `kernel-open/nvidia/nv-pci.c` `nv_pci_error_detected`
  (early-free at 2974/2981, DISCONNECT sink at 3023); `kernel-open/nvidia/nv.c`
  `nv_bootstrap_bounded` (flag 1924/1937/2040) and `nv_dynpower_bounded`
  (2094-2117, own `queue_work`); `src/nvidia/arch/nvalloc/unix/src/os.c`
  `osIsGpuBusDead` (1884), `osDevReadReg032` short-circuit (2050) vs
  `DETECTOR_MMIO_DEAD` funnel (2081-2092). Source re-verified against
  `/root/open-gpu-kernel-modules` on 2026-06-06.
- **Fork branch:** `a13-292-inflight-aer-earlyfree`. Deployed image
  `595.71.05-apnex.31` (live-FAILED 2026-06-06). A13' extends this branch in place.
- **Packaging:** `patches/addon/A13-292-inflight-aer-earlyfree.patch` (extended
  in place for A13'); build `apnex.32`.
- **Design-of-record (build spec):**
  `docs/missions/mission-1-egpu-hot-plug-hot-power/design-2026-06-06-292-redesign-C7-A13prime-A14.md`
  (19-agent redesign; C7 + A13' + A14). The patches C7 and A14 do NOT exist yet —
  this is the build spec; A13 itself is `deployed-insufficient-superseded`.
- **Live-FAIL finding:**
  `docs/missions/mission-1-egpu-hot-plug-hot-power/finding-2026-06-06-A13-live-FAIL-rpcpoll-wedge.md`.
- **Captures:** `captures/netcon3-2026-06-06-A13-live-FAIL-rpcpoll-wedge.log`
  (apnex.31 storm); `captures/netcon2-2026-06-05-292-pathB-wedge.log` (apnex.30
  silent lockdown).
- **Composition / ordering:** A13 is the lock-free marker SOURCE that
  [[C7-292-inflight-deadbus-poll-coverage]]'s read-only poll-readers honor; it
  rides the [[A12-init-funnel]] bounded funnels (where `bootstrap_in_flight` is
  armed) and the [[A3-recovery]] AER `error_detected` recovery surface;
  [[A14-292-reopen-failfast-gate]] is defense-in-depth shipped WITH C7. Builds on
  the [[A10-f40b-lockfree-sink]] lock-free `os_pci` mechanism and is correct only
  under the C5 two-marker model.
- **Upstream issues:** NVIDIA #979
  (https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979); project #292.
  A13 is addon (`n/a` upstream-candidacy); the load-bearing C7 poll-reader is the
  upstream-bound base patch.
