---
id: C7-292-inflight-deadbus-poll-coverage
layer: base
source-branch: c7-292-inflight-deadbus-poll-coverage
upstream-candidacy: high
telemetry-tier: none
status: designed
related-patches: [A13-292-inflight-aer-earlyfree, A14-292-reopen-failfast-gate, A10-f40b-lockfree-sink, A12-init-funnel, C5-crash-safety, C6-cond-acquire-rwlock-fix]
---

# C7-292-inflight-deadbus-poll-coverage — Teach Every GSP Poll Engine to Honor the Lock-Free Dead-Bus Marker

## Purpose

The driver SHALL make every GSP-init poll engine reachable from an in-flight
re-open (`RmInitAdapter → kgspInitRm → _kgspBootGspRm → kgspBootstrap_GH100`)
**honor the lock-free Linux dead-bus marker** (`os_pci_is_disconnected`) that the
in-flight AER early-free already sets, so that a surprise-removed eGPU re-open
self-terminates its bringup worker at **whichever** poll the dead chip is parked
on — instead of storming a dead bus until the foreground (parked in
`wait_for_completion_timeout` holding `nvl->ldata_lock` across `flush_work`)
hard-wedges the host (#292). It SHALL do this with a **single** new thin exported
**read-only** predicate `osIsGpuBusLost(pGpu)` — a wrapper over the existing
`osIsGpuBusDead` (`= os_pci_is_disconnected OR PDB_PROP_GPU_IS_LOST`, os.c:1884) —
wired into the **two shared poll chokepoints** (`timeoutCondWait` in
`gpu_timeout.c`, which subsumes every `gpuTimeoutCondWait` site;
`_kgspRpcRecvPoll` pre-loop + `_kgspRpcSanityCheck`), the heartbeat `done:`
print-gate, and the **three hand-rolled loops** (`message_queue_cpu.c:544` and
`:322`, `kern_fsp.c:411`). The predicate MUST be read-only: it MUST NOT take any
lock, MUST NOT write PM state, and MUST NOT violate any acquire precondition; it
therefore SHOULD compile to one `READ_ONCE` per poll iteration and MUST be a
pure-FALSE no-op on a live bus. This is the **load-bearing** #292 fix: it supplies
the missing READER for the lock-free marker [[A13-292-inflight-aer-earlyfree]]
already writes — A13 alone wedged the host live (apnex.31) because it covered
only the lockdown poll, and only by the `0xFFFFFFFF != 0` accident.

## Mechanism — the two-marker truth and why A13's marker alone is blind

There are **two** software "GPU-lost" markers, honored by **disjoint** code
regions (source-verified against `/root/open-gpu-kernel-modules`, 2026-06-06):

| Marker | Set by | Honored by (the ONLY readers) | Lock to set |
|---|---|---|---|
| `os_pci_is_disconnected` (Linux) | `os_pci_set_disconnected` (`WRITE_ONCE`) | **only** `osIsGpuBusDead()` (os.c:1884), referenced **only** inside the os.c MMIO readers `osDevReadReg008/016/032` + osinit.c | **lock-free** |
| `PDB_PROP_GPU_IS_LOST` (RM PDB bit) | `gpuSetDisconnectedProperties` / `cleanupGpuLostStateAtomic` | `_kgspRpcRecvPoll` pre-loop (kernel_gsp.c:2813-2814) + `_kgspRpcSanityCheck` (kernel_gsp.c:314-318) | lock-free to write; but the AER-reachable setter `rm_cleanup_gpu_lost_state` gates behind `rmapiLockAcquire(COND_ACQUIRE)` |

`grep` for `osIsGpuBusDead` / `os_pci_is_disconnected` returns **zero** hits in
`kernel_gsp.c`, `kernel_gsp_gh100.c`, and `gpu_timeout.c` — the GSP poll engines
are structurally blind to the Linux marker A13 sets. Consequences that this patch
exists to correct:

- **`timeoutCondWait` honors NO lost-marker.** Its loop is
  `while (!pCondFunc(pGpu, pCondData)) { osSpinLoop(); status = timeoutCheck(...); if (status != NV_OK) break; }`;
  the only non-timeout abort is the `API_GPU_IN_RESET_SANITY_CHECK` inside
  `timeoutCheck`. A `gpuTimeoutCondWait` aborts on a dead bus **only if its
  cond-fn's own MMIO read of `0xFFFFFFFF` happens to evaluate the cond TRUE.**
  `_kgspLockdownReleasedOrFmcError` returns TRUE on `mailbox0 != 0` →
  `0xFFFFFFFF != 0` → exits in one iteration: **this accident** is the *only*
  reason A13 advanced past the lockdown gate. The polarity is fragile —
  `_kgspFalconMailbox0Cleared` waits for `mailbox0 == 0`; `0xFFFFFFFF != 0` →
  **never satisfied** → spins to full timeout (`os_pci` makes that poll *worse*).
- **`_kgspRpcRecvPoll` decides loop-exit from `PDB_PROP_GPU_IS_LOST`, not an MMIO
  sentinel.** With only `os_pci` set, PDB stays clear, `IS_CONNECTED` stays TRUE,
  `osIsGpuShutdown` stays FALSE → no gate trips → the poll storms. This is the
  netcon3 live FAIL: the re-open advanced ~1 s into init, died mid-RPC at an AER
  CmpltTO, and the post-INIT_DONE control RPCs (`SET_GUEST_SYSTEM_INFO`@5105,
  `GET_GSP_STATIC_INFO`@5112) stormed a dead bus.
- **A13 is COUNTERPRODUCTIVE at the RPC poll, not merely insufficient.**
  `osDevReadReg032` (os.c:2050) short-circuits and returns
  `NV_GPU_BUS_DEAD_VALUE_U32` **before** reaching the post-read `DETECTOR_MMIO_DEAD`
  funnel (os.c:2081-2092) that would call `cleanupGpuLostStateAtomic` and set
  **both** markers. By pre-setting `os_pci`, A13 disables the one self-heal path
  that would have eventually set `PDB_PROP_GPU_IS_LOST` (the marker
  `_kgspRpcRecvPoll` honors). The vanilla surprise-removal path self-heals
  *because* that detector fires; A13 suppressed it for the re-open.
- **Routing PDB from the AER thread is rejected.** `rm_cleanup_gpu_lost_state`'s
  `COND_ACQUIRE` **defers** during the storm (the worker REACQUIRES the API lock
  at kernel_gsp.c:4818-4820 for the post-INIT_DONE phase — see GAP-5). And the
  lock-free `gpuSetDisconnectedProperties` writes **seven** PM/PDB bits (incl.
  `PDB_PROP_GPU_IN_PM_CODEPATH`, `IN_STANDBY`, `bInD3Cold`, GC6 state) racing a
  dynpower worker, and `NV_GET_NV_PRIV_PGPU` requires the API lock (nv-priv.h:352).
  A **read-only** reader at the poll loops sidesteps all of this.

The reachable wedge surface is **13 poll-sites across 2 engine primitives + 3
hand-rolled loops**, plus a **second** bringup funnel (`nv_dynpower_bounded`,
RTD3/GC6) that A13 never arms. C7 closes all 13 at their loop logic; the marker
source and the second funnel are closed by [[A13-292-inflight-aer-earlyfree]]
(A13'); a fix-bar1 fail-fast gate is [[A14-292-reopen-failfast-gate]].

## L1 sovereignty justification

C7 is justified L1 (base, in NVIDIA's fork) under the sovereign-modules policy:
the abort predicate lives **intrinsically** inside NVIDIA's GSP poll loops; there
is no L4-L6 (out-of-tree shim) way to make `timeoutCondWait` / `_kgspRpcRecvPoll`
/ the hand-rolled loops honor a disconnect marker. Blast radius is concentrated to
**one** new predicate — a thin wrapper over the existing `osIsGpuBusDead`, **no new
semantics** — at **exactly 6 call-sites across 4 files** (`os.c`, `gpu_timeout.c`,
`kernel_gsp.c`, `message_queue_cpu.c` + `kern_fsp.c`). It is upstream-aligned: a
GSP poll *should* honor `pci_dev_is_disconnected` for any surprise-removed GPU, so
this is an upstream-candidacy-`high` change, not a project-only workaround. The
declaration lives in the **project-owned** `src/nvidia/inc/kernel/gpu/nv-gpu-lost.h`
(already included by `kernel_gsp.c`), **NOT** the generated `g_os_nvoc.h` — no
NVOC-gen edits. `osIsGpuBusDead` stays `static inline` so the per-register hot read
path is not de-inlined.

## Requirements

### Requirement: Every GSP poll engine SHALL abort its loop on the lock-free dead-bus marker

When the lock-free `os_pci_is_disconnected` marker (or `PDB_PROP_GPU_IS_LOST`) is
set on an external GPU whose bringup worker is parked in a GSP poll, that poll
engine SHALL observe the marker via `osIsGpuBusLost(pGpu)` and SHALL break its
loop with a non-`NV_OK` status, polarity-independently — it MUST NOT depend on a
cond-fn's MMIO read of `0xFFFFFFFF` evaluating the cond TRUE. The reader MUST NOT
acquire any lock, MUST NOT write PM/PDB state, and MUST NOT call any helper that
requires a held API/GPU lock.

#### Scenario: Lockdown cond on a dead bus (netcon2 silent origin)
- **GIVEN** an in-flight re-open whose worker is parked in `kgspBootstrap_GH100 → _kgspLockdownReleasedOrFmcError` via `gpuTimeoutCondWait`, and the AER early-free has set `os_pci_is_disconnected`
- **WHEN** the next `timeoutCondWait` iteration runs
- **THEN** the loop MUST break with `NV_ERR_TIMEOUT` because `osIsGpuBusLost(pGpu)` is TRUE
- **AND** the break MUST NOT rely on the `mailbox0 != 0` (`0xFFFFFFFF != 0`) accident, so the SPDM `mailbox0 == 0` polarity-trap site is closed by the same edit.

#### Scenario: RPC recv-poll storm on a dead bus (netcon3 live FAIL)
- **GIVEN** an in-flight re-open that advanced past lockdown into the post-INIT_DONE control RPCs (`SET_GUEST_SYSTEM_INFO` / `GET_GSP_STATIC_INFO`) and then lost the bus at an AER CmpltTO, with `os_pci_is_disconnected` set but `PDB_PROP_GPU_IS_LOST` clear
- **WHEN** `_kgspRpcRecvPoll` is re-entered
- **THEN** the pre-loop condition (`bFatalError || PDB_PROP_GPU_IS_LOST || osIsGpuBusLost(pGpu)`) MUST return `NV_ERR_RESET_REQUIRED` **before** the for-loop and the `done:` label
- **AND** none of the heartbeat-timeout / "Bad TimeLo" storm lines MUST be emitted (the print-gate also reads `osIsGpuBusLost` so the dead-PTIMER read is never taken).

### Requirement: Coverage SHALL be complete across all 13 reachable poll-sites and hand-rolled loops

The patch SHALL close every poll-site reachable from a re-open bringup, including
the three hand-rolled loops that bypass both shared chokepoints. The
`message_queue_cpu.c:544` tx-full `while (NV_TRUE)` loop — which has **no MMIO
escape** (it waits on sysmem `msgqTxGetWriteBuffer`) and burns 1 s/element — MUST
be covered explicitly; "every poll covered" is false until it is.

#### Scenario: Hand-rolled tx-full loop with no MMIO escape
- **GIVEN** an in-flight worker parked in `GspMsgQueueSendCommand`'s `while (NV_TRUE)` tx-full wait on a dead bus
- **WHEN** the loop body re-evaluates
- **THEN** the inserted `if (osIsGpuBusLost(pGpu)) { nvStatus = NV_ERR_TIMEOUT; break; }` MUST fire (the worst silent F44 hold)
- **AND** the analogous short-circuits at `message_queue_cpu.c:322` (`GspStatusQueueInit` link wait) and `kern_fsp.c:411` (`kfspWaitForResponse`) MUST NOT rely on the accidental `kgspHealthCheck_HAL` MMIO escape.

### Requirement: The reader SHALL be a pure no-op on a live bus (no regression)

On a healthy bus (`os_pci_is_disconnected` clear AND `PDB_PROP_GPU_IS_LOST` clear)
every added check SHALL evaluate FALSE and SHALL NOT alter any control flow,
timing budget, return code, or log output. The added cost MUST be at most one
`READ_ONCE`-class load per poll iteration with no lock.

#### Scenario: Healthy cold init is byte-identical
- **GIVEN** a clean cold-plug bringup (BAR1 32 GiB, params 3000/2000) on a live bus
- **WHEN** the worker traverses all C7-instrumented poll-sites
- **THEN** `osIsGpuBusLost(pGpu)` MUST be FALSE at every site, no C7 break MUST be taken, and no new log line MUST appear
- **AND** `nvidia-smi -L` MUST succeed, BAR1 MUST be 32 GiB, and persistence MUST engage exactly as before C7.

## Scope boundary

- C7 deliberately does **NOT** set or own the marker. The marker SOURCE
  (`bootstrap_in_flight` + early lock-free `os_pci_set_disconnected`) is
  [[A13-292-inflight-aer-earlyfree]] (kept verbatim); arming the marker on the
  **second** funnel (`nv_dynpower_bounded`, RTD3/GC6 — closes GAP-1) and
  correcting the stale lock-model comment (GAP-5) are A13' edits, not C7.
- Out-of-scope: the fix-bar1 sticky-bit re-open fail-fast gate — that is
  [[A14-292-reopen-failfast-gate]], which ships **with** C7 as defense-in-depth,
  never instead of it (it is divergence-blind on a novel substrate).
- C7 does **NOT** make any `COND_ACQUIRE` blocking and does **NOT** write
  `PDB_PROP_GPU_IS_LOST` from the AER thread (both rejected — see Mechanism); it
  reads only, so the [[C6-cond-acquire-rwlock-fix]] / [[C5-crash-safety]] F44 fix
  is not weakened and the A13b 7-bit PM-state clobber race is avoided.
- Out-of-scope: the stochastic cold-bringup reliability of the eGPU (the EQ
  divergence / H16 transient that produces the lost state). C7 only bounds the
  worker once the bus is already dead.
- C7 does **NOT** guarantee `PDB_PROP_GPU_IS_LOST` ends up set (GAP-7): it frees
  the worker via the `os_pci` read short-circuit; the worker's own
  `NV_ERR_RESET_REQUIRED` unwind handles teardown under its already-held locks.

## Telemetry contract

None new. C7 is read-only and adds no events. Two telemetry-relevant effects:

| Effect | Level | Note |
|---|---|---|
| Heartbeat-timeout storm prints SUPPRESSED | n/a (suppression) | C7-e5 gates the full `_kgspHeartbeat*TimedOut` blocks (the `NV_PRINTF(LEVEL_ERROR, ...)` **and** the `tmrGetTimeEx_GH100` "Consistently Bad TimeLo ffffffff" reads) behind `if (!osIsGpuBusLost(pGpu))` — the netcon3 storm lines are eliminated at source, not hidden |
| Path attribution relies on existing logs | `NV_DBG_ERRORS` | The observable proof of C7 is the **absence** of the storm; attribution uses A13's existing `tb_egpu recover: AER during in-flight bootstrap -> early dead-bus marker (#292)` line and A12's existing bounded-wait timeout / `-EIO` line. No C7-specific event is emitted. |

`telemetry-tier: none` — the patch's correctness is observed as the disappearance
of pre-existing storm lines, validated by the dual-loglevel survival test, not by
a new event.

## Edits — C7-e1 .. C7-e6 (design-of-record §3)

- **C7-e1** — `os.c` (after `osIsGpuBusDead`, ~1896): add the exported thin
  wrapper `NvBool osIsGpuBusLost(OBJGPU *pGpu) { return osIsGpuBusDead(pGpu); }`.
  Keep `osIsGpuBusDead` `static inline` (hot read path not de-inlined); NULL-safe
  via the inline's `pGpu == NULL` guard.
- **C7-decl** — `src/nvidia/inc/kernel/gpu/nv-gpu-lost.h`: declare
  `NvBool osIsGpuBusLost(struct OBJGPU *pGpu);` (already included by
  `kernel_gsp.c`). Project-owned header, not generated `g_os_nvoc.h`.
- **C7-e2** — `gpu_timeout.c` `timeoutCondWait` (`while (!pCondFunc(...))` loop,
  ~591): add `#include "gpu/nv-gpu-lost.h"`; at loop top before `osSpinLoop()`
  insert `if (osIsGpuBusLost(pGpu)) { status = NV_ERR_TIMEOUT; break; }`.
  `pGpu = pTD->pGpu` is in scope and NULL-safe. **One** edit covers all
  `gpuTimeoutCondWait` sites (#1-#8), polarity-independently.
- **C7-e3** — `kernel_gsp.c` `_kgspRpcRecvPoll` pre-loop (2813-2814): OR-in
  `|| osIsGpuBusLost(pGpu)` into the **existing** `bFatalError ||
  PDB_PROP_GPU_IS_LOST` condition. Do NOT add a separate early-return — the
  existing block already clears `bPollingForRpcResponse = NV_FALSE` before
  returning `NV_ERR_RESET_REQUIRED`; OR-ing preserves that and avoids the
  `NV_ASSERT_OR_RETURN(!bPollingForRpcResponse)` trap the next entrant would hit.
- **C7-e4** — `kernel_gsp.c` `_kgspRpcSanityCheck` (314-318): OR-in
  `|| osIsGpuBusLost(pGpu)` into `!API_GPU_ATTACHED_SANITY_CHECK(pGpu) ||
  PDB_PROP_GPU_IS_LOST` → returns the existing `NV_ERR_GPU_IS_LOST`. Frees a
  worker already parked mid-for-loop via `goto done` on its next iteration.
- **C7-e5** — `kernel_gsp.c` `done:` block (2974-2981): wrap the **full**
  `if (_kgspHeartbeatIsGspRm/LibosHeartbeatTimedOut(...)) { NV_PRINTF(...) }`
  blocks (NOT just the `NV_PRINTF`) inside `if (!osIsGpuBusLost(pGpu)) { ... }` —
  the **predicate call** is what reads the dead PTIMER and emits "Bad TimeLo".
  Belt-and-suspenders (C7-e3 already prevents re-entry from reaching `done:`).
- **C7-e6** *(REQUIRED, closes GAP-2)* — the three hand-rolled loops:
  - `message_queue_cpu.c:544` `GspMsgQueueSendCommand` tx-full `while (NV_TRUE)`:
    insert `if (osIsGpuBusLost(pGpu)) { nvStatus = NV_ERR_TIMEOUT; break; }`
    (highest priority — no MMIO escape, 1 s/element silent F44).
  - `message_queue_cpu.c:322` `GspStatusQueueInit` link wait: same short-circuit
    (explicit, not relying on the accidental `kgspHealthCheck_HAL` MMIO escape at 382).
  - `kern_fsp.c:411` `kfspWaitForResponse` `while (!kfspIsResponseAvailable_HAL(...))`:
    same short-circuit (`pGpu` in scope).

## Complete poll-site coverage proof (13 sites + both funnels)

Engine classes: **E1** = `timeoutCondWait`/`gpuTimeoutCondWait`; **E2** =
`_kgspRpcRecvPoll`; **E3** = hand-rolled own-loop. GB202/5090 uses the GH100
KernelGsp HAL. F1/F2 = the two bringup funnels (closed by A13/A13', listed for
completeness — C7 supplies the readers the funnels' marker feeds).

| # | Site | Eng | Closed by | Mechanism (post-fix) |
|---|---|---|---|---|
| 1-3 | FSP GFW-boot / target-mask / can-send (`gpuTimeoutCondWait`) | E1 | C7-e2 | loop tests `osIsGpuBusLost(pGpu)` → break `NV_ERR_TIMEOUT`, polarity-independent |
| 4 | Lockdown `_kgspLockdownReleasedOrFmcError` **[netcon2]** | E1 | C7-e2 | same; no longer relies on the `mailbox0 != 0` accident |
| 5 | SPDM `mailbox0 == 0` **polarity trap** | E1 | C7-e2 | the one site `os_pci` dead-value could NOT close; marker break closes it (CC-off → unreachable today anyway) |
| 6 | `kgspResetHw` (TMR/PTIMER-dead edge) | E1 | C7-e2 | breaks on marker regardless of whether the dead PTIMER advances the timeout |
| 7-8 | CC-cleanup / Blackwell reset-access | E1 | C7-e2 | same chokepoint |
| 9 | `_kgspRpcRecvPoll(INIT_DONE)` | E2 | C7-e3/e4 | pre-loop `\|\| osIsGpuBusLost` → `NV_ERR_RESET_REQUIRED`; sanity `\|\| osIsGpuBusLost` → `NV_ERR_GPU_IS_LOST` |
| 10 | POST-INIT_DONE ctrl RPCs **[netcon3 STORM]** | E2 | C7-e3/e4/e5 | pre-loop returns BEFORE for-loop & `done:` → zero storm prints; e5 gates the heartbeat prints belt-and-suspenders |
| 11 | `GspMsgQueueSendCommand` tx-full (msgq:544) **[worst silent F44]** | E3 | C7-e6 | `if (osIsGpuBusLost(pGpu)) { NV_ERR_TIMEOUT; break; }` inside `while (NV_TRUE)`, no MMIO escape |
| 12 | `GspStatusQueueInit` link (msgq:322) | E3 | C7-e6 | explicit marker short-circuit (not the accidental `kgspHealthCheck` MMIO escape) |
| 13 | `kfspWaitForResponse` (kern_fsp.c:411) | E3 | C7-e6 | marker short-circuit in the hand-rolled loop |
| F1 | `nv_bootstrap_bounded` funnel (open/resume) | — | A13 (deployed) | `bootstrap_in_flight` armed → AER early-free sets `os_pci` |
| F2 | `nv_dynpower_bounded` funnel (RTD3/GC6) **[GAP-1]** | — | A13'-e1 | arm `bootstrap_in_flight` around dynpower `queue_work` → AER early-free fires there too |

**Captured-wedge walks (both prevented at source, loglevel-independently):**

- **netcon3 (A13 storm):** AER CmpltTO L687 → A13 sets `os_pci` L699. With C7 the
  first `_kgspRpcRecvPoll` re-entry hits the pre-loop (2813) `|| osIsGpuBusLost`
  → returns `NV_ERR_RESET_REQUIRED` at ~+34 ms **before** the for-loop / `done:`
  → none of L705-L844 (the heartbeat / Bad-TimeLo lines) are emitted.
  `SET_GUEST_SYSTEM_INFO` fails → `kgspInitRm` unwinds → API lock released →
  `flush_work` joins → foreground `-EIO`, `ldata_lock` released.
- **netcon2 (silent lockdown):** with A13' arming on whichever funnel + the early
  `os_pci`, the lockdown `timeoutCondWait` (C7-e2) breaks on `osIsGpuBusLost` on
  the next iteration → `kgspBootstrap_GH100` returns `NV_ERR_NOT_READY` → unwind →
  `flush_work` joins well before the +3000 ms A12 budget.

Both sequences close at the same structural property — a lock-free marker honored
by every poll engine — independent of which poll the diverged chip dies at.

## No-regression argument

`osIsGpuBusLost` is TRUE **only** when `os_pci_is_disconnected` OR
`PDB_PROP_GPU_IS_LOST` is set — a condition a healthy bus never has. Every added
check is a pure-FALSE no-op (one `READ_ONCE`, sub-ns, no lock) on a live bus.

| Prior result / invariant | Why preserved (source-verified) |
|---|---|
| **Normal cold-init** (~1.3-1.9 s, BAR1 32 GiB, params 3000/2000) | `os_pci` clear, PDB clear → all C7 checks FALSE; byte-identical control flow, no new log lines |
| **R1-R4 (WPR2 fast-fail contained; resets contain-only)** | Fast-fail re-open has a **live** bus → `osIsGpuBusLost` FALSE → identical fast-fail; [[A10-f40b-lockfree-sink]] grace arm skips the marker on fast-fail (chip NOT sunk) |
| **[[A10-f40b-lockfree-sink]] lockdown arm** | Byte-identical; C7 only makes its `flush_work` join **faster** (worker self-aborts sooner). Surprise-removal SURVIVAL (06-05 clean A2→C5→A7) is teardown-path, untouched |
| **[[A12-init-funnel]]** (3000 ms budget + grace discriminator) | Preserved; C7 makes the worker self-abort **before** the budget in the AER case → timeout arm fires **less** often; grace keys on completion-state, not markers; `-EIO` propagation unchanged |
| **[[C5-crash-safety]] / [[C6-cond-acquire-rwlock-fix]]** (F44 fix, `COND_ACQUIRE`) | NOT weakened to blocking. `rm_cleanup` keeps `COND_ACQUIRE`; C7 makes the lock-free `os_pci` marker sufficient so PDB-via-`rm_cleanup` is not load-bearing. No new blocking acquire on the AER/poll path |
| **A13 (deployed)** marker source | Kept verbatim; C7 only adds READERS for the marker A13 writes |
| **Error-code surface** | C7-e3/e4 reuse existing `NV_ERR_RESET_REQUIRED` / `NV_ERR_GPU_IS_LOST`; C7-e2 returns `NV_ERR_TIMEOUT` on a dead bus. Caller audit (GAP-6): lockdown caller verified generic `!= NV_OK`; SPDM/reset/CC callers confirmed not to branch on `NV_ERR_TIMEOUT` |

## Validation

- **(0) Build gate:** real `make modules` of the composed C+E+A+C7 tree against
  `7.0.9-204.fc44.x86_64` (compile, not `git apply --check`). Confirm the wrapper +
  `nv-gpu-lost.h` decl + `gpu_timeout.c` include build clean across all TUs.
  Caller audit (GAP-6) for any `NV_ERR_TIMEOUT`-specific branch on the
  `timeoutCondWait` callers.
- **(a) Observability-amplifier isolation:** run the apnex.31 Stage-5 repro at
  BOTH `console_loglevel=8` (netconsole armed) AND minimised observability
  (`echo 4 4 1 7 > /proc/sys/kernel/printk`, passive sysrq-w/t/l). **SURVIVAL at
  both loglevels** is the load-bearing proof the storm is removed at source.
- **(b) Coverage:** n≥3 primary repro + the GAP-1 runtime-PM (GC6/RTD3 resume)
  repro; expected signature = A13 marker fires → **zero** `_kgspRpcRecvPoll` /
  heartbeat / "Bad TimeLo" lines → worker returns → `flush_work` joins → `-EIO`,
  host alive, GPU cold-plug-recoverable.
- **(c) Recover-disabled control** (`NVreg_TbEgpuRecoverEnable=0`): C7 still frees
  the worker (it reads `os_pci`/PDB, independent of the recover module).
- 14-day soak before cutover (build `apnex.32`). Full plan: design-of-record §5.

## Provenance

- **Source cluster:** C7 — new base/L1 GSP-core dead-bus poll-reader cluster
  (upstream-bound; `docs/upstream-plan.md`).
- **Vanilla baseline:** `src/nvidia/arch/nvalloc/unix/src/os.c:osIsGpuBusDead`
  (~1884); `src/nvidia/src/kernel/gpu/timer/timeout.c:timeoutCondWait` (~591);
  `src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c:_kgspRpcRecvPoll` (2813-2814) /
  `_kgspRpcSanityCheck` (314-318) / heartbeat `done:` block (2974-2981);
  `src/nvidia/src/kernel/gpu/gsp/message_queue_cpu.c:GspMsgQueueSendCommand`
  (544) / `GspStatusQueueInit` (322); `kern_fsp.c:kfspWaitForResponse` (411).
  New decl: `src/nvidia/inc/kernel/gpu/nv-gpu-lost.h`.
- **Fork branch:** `c7-292-inflight-deadbus-poll-coverage` on
  `apnex/open-gpu-kernel-modules` — **not yet carved** (this is the build spec;
  `status: designed`). Packaged as `patches/base/C7-292-inflight-deadbus-poll-coverage.patch`.
- **Design-of-record:** `docs/missions/mission-1-egpu-hot-plug-hot-power/design-2026-06-06-292-redesign-C7-A13prime-A14.md`
  (19-agent redesign, source re-verified 2026-06-06). Live-FAIL that motivated it:
  `docs/missions/mission-1-egpu-hot-plug-hot-power/finding-2026-06-06-A13-live-FAIL-rpcpoll-wedge.md`
  (apnex.31, capture `captures/netcon3-2026-06-06-A13-live-FAIL-rpcpoll-wedge.log`).
- **Upstream issue:** NVIDIA #979 (Blackwell eGPU over TB hard-lock,
  https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979) — upstream-report
  candidate AFTER a tested fix per project policy; n/a filed yet. Mission-internal
  tracker: #292.
- **Composition:** load-bearing with [[A13-292-inflight-aer-earlyfree]] (marker
  source + GAP-1 funnel arm + GAP-5 comment) and [[A14-292-reopen-failfast-gate]]
  (fix-bar1 fail-fast, defense-in-depth). Build target `apnex.32`.
