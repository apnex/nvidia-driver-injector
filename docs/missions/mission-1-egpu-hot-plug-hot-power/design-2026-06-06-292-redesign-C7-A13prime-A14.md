# #292 REDESIGN — DESIGN-OF-RECORD (build spec, apnex.32)

**Subject:** Host hard-wedge on a persistence-OFF re-open of a #979-EQ-diverged TB-tunneled RTX 5090.
**Supersedes:** A13 (fork `a13-292-inflight-aer-earlyfree`, live-FAIL 2026-06-06, apnex.31).
**Status of A13:** AER-handler half KEPT (correct); the marker is insufficient and is made sufficient here.
**Verification basis:** every load-bearing claim below re-checked against `/root/open-gpu-kernel-modules` source on 2026-06-06 (cited inline). Captures: `netcon2-2026-06-05-292-pathB-wedge.log` (apnex.30 silent), `netcon3-2026-06-06-A13-live-FAIL-rpcpoll-wedge.log` (apnex.31 storm).

---

## 1. ROOT CAUSE (verified)

### 1.1 The two-marker truth (source-confirmed)

There are **two** software "GPU-lost" markers and they are honored by **disjoint** code regions:

| Marker | Set by | Honored by (the ONLY readers) | Lock to set |
|---|---|---|---|
| `os_pci_is_disconnected` (Linux) | `os_pci_set_disconnected` (WRITE_ONCE) | **only** `osIsGpuBusDead()` (os.c:1884), which is referenced **only** inside the os.c MMIO readers `osDevReadReg008/016/032` + osinit.c | **lock-free** |
| `PDB_PROP_GPU_IS_LOST` (RM PDB bit) | `gpuSetDisconnectedProperties` / `cleanupGpuLostStateAtomic` | `_kgspRpcRecvPoll` pre-loop (kernel_gsp.c:2813-2814) + `_kgspRpcSanityCheck` (kernel_gsp.c:314-318) | lock-free to write the bit; but the **AER-reachable** setter `rm_cleanup_gpu_lost_state` gates behind `rmapiLockAcquire(COND_ACQUIRE)` |

**Verified:** `grep` for `osIsGpuBusDead` / `os_pci_is_disconnected` returns **zero** hits in `kernel_gsp.c`, `kernel_gsp_gh100.c`, and `gpu_timeout.c`. The GSP poll engines are structurally blind to the Linux marker.

A13 sets **only** `os_pci_is_disconnected`, directly (nv-pci.c:2981), and **never** `PDB_PROP_GPU_IS_LOST`. Confirmed at source: nv-pci.c:2974 gates on `bootstrap_in_flight`, then nv-pci.c:2981 calls `os_pci_set_disconnected(lost_nv->handle)` — not `cleanupGpuLostStateAtomic`.

### 1.2 Why A13 covered the lockdown poll but NOT the RPC poll

The dead-bus "coverage" from `os_pci` is **per-poll and accidental**, mediated entirely by the MMIO readers returning `0xFFFFFFFF` (`NV_GPU_BUS_DEAD_VALUE_U32`):

- **`timeoutCondWait` (gpu_timeout.c) honors NO lost-marker.** Verified: its loop is `while (!pCondFunc(pGpu, pCondData)) { osSpinLoop(); status = timeoutCheck(...); if (status != NV_OK) break; }`. The only non-timeout abort is `API_GPU_IN_RESET_SANITY_CHECK` inside `timeoutCheck`. A `gpuTimeoutCondWait` aborts on a dead bus **only if its cond-fn's own MMIO read of `0xFFFFFFFF` happens to evaluate the cond TRUE.**
  - `_kgspLockdownReleasedOrFmcError` (gh100:499) returns TRUE on `mailbox0 != 0` → `0xFFFFFFFF != 0` → exits in **one iteration**. This is the **accident** that let A13 advance past the lockdown gate.
  - **Polarity trap:** `_kgspFalconMailbox0Cleared` (gh100:662) waits for `mailbox0 == 0`; `0xFFFFFFFF != 0` → **never satisfied** → spins to full timeout. `os_pci` makes this poll *worse*, not better. (Unreachable today — CC/SPDM off on the consumer 5090 — but it proves dead-value coverage is fragile.)

- **`_kgspRpcRecvPoll` does NOT decide loop-exit from an MMIO sentinel.** It exits on `bFatalError || PDB_PROP_GPU_IS_LOST` (pre-loop, kernel_gsp.c:2813) and on `_kgspRpcSanityCheck` (per-iteration). With only `os_pci` set, `PDB_PROP_GPU_IS_LOST` stays clear, `IS_CONNECTED` stays TRUE, `osIsGpuShutdown` (=`nv->is_shutdown`) stays FALSE → **no gate trips** → the poll storms.

### 1.3 The decisive surprise: the AER path's own PDB-setter was lock-gated out

The DISCONNECT branch of `nv_pci_error_detected` (nv-pci.c:3023) **does** dispatch the full sink `rm_cleanup_gpu_lost_state(AER_FATAL)` — but that wrapper acquires the RM API lock with `API_LOCK_FLAGS_COND_ACQUIRE` (osapi.c:1913, the **non-blocking** acquire introduced by the C1/C6 F44 fix). During the netcon3 storm the worker **holds the reacquired API lock**:

- **Verified:** the storm fires `_kgspIsHeartbeatTimedOut`, which is only meaningful after `_kgspHeartbeatInit` (kernel_gsp.c:6162), which runs only **after** `INIT_DONE` drains. So the storm is the **post-INIT_DONE control RPCs** (`SET_GUEST_SYSTEM_INFO`@5105, `GET_GSP_STATIC_INFO`@5112), and `_kgspBootGspRm` **REACQUIRES** the API lock at kernel_gsp.c:4818-4820 before that phase.
- Therefore the AER thread's `COND_ACQUIRE` **defers** → `PDB_PROP_GPU_IS_LOST` is never set → the storm continues. **Proof from capture:** the storm runs via the `done:` label (kernel_gsp.c:2974-2981); had PDB been set, the pre-loop short-circuit (2813) would have returned `NV_ERR_RESET_REQUIRED` *before* the for-loop and `done:`.

**Refinement to prior finding (no contradiction):** "A13 never *attempts* PDB" is imprecise — the sink **is** dispatched but is **COND_ACQUIRE-deferred** by the worker's reacquired API lock. Outcome (PDB unset → storm) is unchanged; mechanism is sharpened. This **rejects** any fix that routes PDB through `rm_cleanup_gpu_lost_state` from the AER thread.

### 1.4 A13 is COUNTERPRODUCTIVE at the RPC poll, not merely insufficient

**Verified at os.c:2050 vs os.c:2081.** `osDevReadReg032` short-circuits and returns `NV_GPU_BUS_DEAD_VALUE_U32` **before** ever reaching the post-read `DETECTOR_MMIO_DEAD` funnel (os.c:2081-2092) that would call `cleanupGpuLostStateAtomic(DETECTOR_MMIO_DEAD)` and set **both** markers. By pre-setting `os_pci`, A13 **disables the one self-heal path** that would have eventually set `PDB_PROP_GPU_IS_LOST`. The vanilla surprise-removal path self-heals *because* that detector fires; A13 suppressed it for the re-open.

### 1.5 The lock-model correction (GAP-5 — a regression-in-understanding that MUST be fixed in source)

The deployed comment at nv.c:1959-1968 states the worker "holds the GPU GROUP lock, NOT the API lock, across the poll." **Source shows this is true only for the lockdown window.** `kgspInitRm` releases the API lock at kernel_gsp.c:4785 across the lockdown cond, then **REACQUIRES** it at 4818-4820 before INIT_DONE / control RPCs. The stale comment silently underwrites the false belief that A12's lockdown-arm `rm_cleanup` COND_ACQUIRE "will succeed" — it **defers** during the storm. This comment must be corrected (see §3, edit A13'-e3) or the source perpetuates the exact error that produced the live FAIL.

### 1.6 The 5200 ms heartbeat is a red herring; the storm is PTIMER-driven

`_kgspIsHeartbeatTimedOut` computes elapsed time from the GPU **PTIMER** (`tmrGetTime`, kernel_gsp.c:2294), not wall-clock. On the dead bus `tmrGetTimeEx_GH100` returns 0 with "Consistently Bad TimeLo ffffffff" → `diff > 5200` always TRUE, but this boolean is **only logged** (the `done:` block); it never breaks the loop. The per-call OSTIMER `gpuCheckTimeout` is re-armed every call (GSP-client default `GPU_TIMEOUT_FLAGS_OSTIMER`), so the multi-second per-RPC timeout never accumulates. Each `_kgspRpcRecvPoll` returns in ~0.3-3 ms and is re-invoked → tight re-call storm. The worker is **bounded per-call** but the outer re-dispatch is effectively unbounded within the lifetime the host survives.

### 1.7 Observability factor (confidence: medium)

The netcon3 host died at **+1.075 s** (capture EOF L844), ~1.9 s before A12's +3000 ms foreground arm could fire. The proximate killer is co-caused:
- **Substrate:** F44 — the foreground parked in `wait_for_completion_timeout` holding `nvl->ldata_lock` across `flush_work` (nv.c:2037), a second contender wedges.
- **Converter:** the synchronous netconsole printk-storm at `console_loglevel=8` saturating the storming CPU in the netpoll path.

**Honest verdict (VERIFIED claim 2, refuted-medium):** whether the host would *recover* absent the storm is **unresolved** — both captures died before any bound was testable, and the grounding findings internally disagree (the post-INIT_DONE API-lock reacquisition implies A12's `rm_cleanup` rescue **also** defers, i.e. no recovery, which my source read favors). **The redesign is engineered to be correct under BOTH readings** (no storm AND worker freed deterministically), so this open question does not gate the fix — but it gates the *validation method* (§5).

### 1.8 Full poll-site table (every site reachable from a re-open `RmInitAdapter → kgspInitRm → _kgspBootGspRm → kgspBootstrap_GH100`)

GB202/5090 uses the GH100 KernelGsp HAL (no GB20x bootstrap override; confirmed by `tmrGetTimeEx_GH100` + `_kgspLockdownReleasedOrFmcError` in capture). Engine classes: **E1** = `timeoutCondWait`/`gpuTimeoutCondWait`; **E2** = `_kgspRpcRecvPoll`; **E3** = hand-rolled own-loop.

| # | Poll-site | Eng | Cond-fn | Marker honored today | Reachable | Covered by A13 (os_pci) alone? |
|---|---|---|---|---|---|---|
| 1 | `kfspWaitForSecureBoot_GH100/GB202` GFW-boot (gh100:828 / gb202:80, via `gpuTimeoutCondWait`) | E1 | THERM_I2CS_SCRATCH FSP_BOOT_COMPLETE | none (cond/timeout) | YES (pre-lockdown) | accidental (encoding-dependent) |
| 2 | `kfspWaitForGspTargetMaskReleased_GH100` (gh100:1158, `gpuTimeoutCondWait`) | E1 | HWCFG2 ≠0 && ≠0xBADF41 | none | YES | accidental (≠ → TRUE) |
| 3 | `_kfspWaitForCanSend` (kern_fsp.c:364, `gpuTimeoutCondWait`) | E1 | FSP EMEM head/tail | none | YES (FSP send) | accidental |
| 4 | **`_kgspLockdownReleasedOrFmcError`** (gh100:1050) **[netcon2 silent origin]** | E1 | MAILBOX0≠0 \|\| HWCFG2 _UNLOCK | none | YES | **YES, accidental** (0xFFFFFFFF→≠0→TRUE 1 iter) |
| 5 | `_kgspFalconMailbox0Cleared` / `_kgspSpdmBootedOrFmcError` (gh100:620/662) | E1 | MAILBOX0 **==0** (trap) / ≠0 | none | NO (CC/SPDM off) | **NO** (==0 polarity trap) |
| 6 | `kgspResetHw` asserted/deasserted (gh100:133/144) | E1 | FALCON RESET_STATUS | none | conditional (reset only) | accidental; **TMR/PTIMER-dead edge** |
| 7 | `_kgspHasCcCleanupFinished` (gh100:1271) | E1 | CC mailbox | none | NO (CC off) | accidental |
| 8 | `_kgspWaitForResetAccess` (gb100:83) | E1 | reset-access | none | conditional | accidental |
| 9 | `kgspWaitForRmInitDone → _kgspRpcRecvPoll(INIT_DONE)` (6151→2682) | E2 | drain + sanity | **PDB_PROP_GPU_IS_LOST** | YES | **NO** (gates on PDB, not os_pci) |
| 10 | **POST-INIT_DONE ctrl RPCs** (5105/5112, `_issueRpcAndWait`→2682) **[netcon3 STORM]** | E2 | drain + sanity + heartbeat | **PDB_PROP_GPU_IS_LOST** | YES | **NO** (+ worker holds reacquired API lock → AER sink defers) |
| 11 | **`GspMsgQueueSendCommand` tx-full** (message_queue_cpu.c:544) | E3 | `msgqTxGetWriteBuffer != NULL` (sysmem) | **none** — `while(NV_TRUE)`, 1 s/element, **NO MMIO escape** | YES (init RPC send) | **NO** (sysmem; os_pci immune) — *worst silent F44* |
| 12 | `GspStatusQueueInit` link (message_queue_cpu.c:322/382) | E3 | `msgqRxLink==0` (sysmem) + `kgspHealthCheck_HAL` (MMIO) | partial (MMIO escape only) | YES | partial/accidental |
| 13 | `kfspWaitForResponse` (kern_fsp.c:411) | E3 | `!kfspIsResponseAvailable_HAL` (MMIO) | none — hand-rolled | YES (FSP recv) | accidental |

**Plus the funnel-coverage gap (GAP-1):** the AER early-free (nv-pci.c:2974) is gated on `bootstrap_in_flight`, set **only** in `nv_bootstrap_bounded` (nv.c:1924). The **second** GSP-bringup funnel `nv_dynpower_bounded` (RTD3/GC6 resume → `rm_transition_dynamic_power`, nv.c:2094-2117) has its **own** `queue_work` and **never arms the flag** → on a dynpower-driven re-bringup, A13's marker is never set at AER time and the wedge reproduces regardless of poll coverage.

---

## 2. CHOSEN APPROACH + complete coverage proof

### 2.1 Composition (apnex.32)

**Load-bearing layer — `C7` (base/L1, upstream-bound): in-flight dead-bus poll READER.**
Make every GSP poll-engine **read** the lock-free `os_pci` marker A13 already sets, via one new thin exported predicate `osIsGpuBusLost(pGpu)` (wraps the existing `osIsGpuBusDead` = `os_pci OR PDB`), at the **shared chokepoints** plus the three hand-rolled loops. Read-only: **no lock, no PM-state write, no precondition violation.**

**Marker source — `A13` KEPT verbatim** (`bootstrap_in_flight` + early lock-free `os_pci_set_disconnected`), **extended (`A13'`)** to arm `bootstrap_in_flight` around the `nv_dynpower_bounded` `queue_work` too (closes GAP-1), and to correct the lock-model comment (GAP-5).

**Defense-in-depth — `A14` (addon): fix-bar1 sticky-bit re-open fail-fast gate** in BOTH funnels. Deterministic for the known production substrate; **probabilistic** (false-negative on novel divergence), so it ships **with** C7, never instead.

**Why C7 is load-bearing and not whack-a-mole:** the captured wedges live on exactly two engine primitives (`timeoutCondWait`, `_kgspRpcRecvPoll`), each a **shared** chokepoint that subsumes its whole family. The marker SOURCE is the lock-free `os_pci` flag — proven set at AER time (+1.0 s, before any storm). C7 supplies the missing **reader** so the lock-free marker self-terminates the poll the way A13 intended.

### 2.2 What is REJECTED and why

| Rejected | Reason (source-verified) |
|---|---|
| **A13b — set both markers lock-free from the AER thread** via `gpuSetDisconnectedProperties`/`cleanupGpuLostStateAtomic` | **GAP-3, confirmed at gpu.c:5272-5290:** `gpuSetDisconnectedProperties_IMPL` writes **seven** bits — `PDB_PROP_GPU_IS_LOST`, `PDB_PROP_GPU_IS_CONNECTED`, **`PDB_PROP_GPU_IN_PM_CODEPATH`**, **`PDB_PROP_GPU_IN_STANDBY`**, **`bInD3Cold`**, `PDB_PROP_GPU_IN_HIBERNATE`, **`SET_GPU_GC6_STATE(POWERED_ON)`**. Called lock-free from AER **concurrently with a dynpower (RTD3/GC6) worker** that is actively managing those exact bits → PM-state corruption race, not the benign monotonic LOST-flip the design assumed. **Plus** it resolves `pGpu` via `NV_GET_NV_PRIV_PGPU`, whose definition (nv-priv.h:352) documents *"Make sure that your stack has taken API Lock before using this macro"* — A13b's lock-free deref violates it (same unreviewed-precondition class that shipped A13). REJECTED as primary. |
| **Make `rm_cleanup`'s `COND_ACQUIRE` blocking** so PDB always sets | Re-introduces the **F44 hard wedge** that C1/C6 fixed (the worker holds the API lock; a blocking acquire from the AER thread deadlocks). Hard NO. |
| **C' fail-fast gate as the SOLE fix** | Divergence is **driver-invisible live** (PMC_BOOT_0=0x1b2000a1, WPR2 up, LnkSta Gen3 x4 all read healthy; Phy16Sta.EquComplete is endpoint-only under TB register virtualization, n=2). The gate's predicate is blind to a **novel** divergence with no prior fix-bar1 run → worker queued → wedge. Demoted to defense-in-depth. |
| **Naive per-cond-fn dead-value patching** | The polarity trap (site #5, `==0`) proves dead-value coverage is fragile/whack-a-mole. C7 patches the **loop logic** (osIsGpuBusLost), not the dead value. |

### 2.3 COMPLETE poll-site coverage proof

Every site #1-#13 from §1.8, and BOTH funnels, closed:

| # | Site | Closed by | Mechanism (post-fix) |
|---|---|---|---|
| 1-3 | FSP GFW / target-mask / can-send (`gpuTimeoutCondWait`) | **C7-e2** | `timeoutCondWait` loop tests `osIsGpuBusLost(pGpu)` → break `NV_ERR_TIMEOUT`, polarity-independent |
| 4 | Lockdown `_kgspLockdownReleasedOrFmcError` **[netcon2]** | **C7-e2** | same; no longer relies on the `mailbox0≠0` accident |
| 5 | SPDM `==0` **polarity trap** | **C7-e2** | the one site `os_pci` dead-value could NOT close — `timeoutCondWait` marker break closes it (CC-off → unreachable today anyway) |
| 6 | `kgspResetHw` (TMR/PTIMER-dead edge) | **C7-e2** | breaks on marker regardless of whether the dead PTIMER advances the timeout |
| 7-8 | CC-cleanup / Blackwell reset | **C7-e2** | same chokepoint |
| 9 | `_kgspRpcRecvPoll(INIT_DONE)` | **C7-e3/e4** | pre-loop `\|\| osIsGpuBusLost` → `NV_ERR_RESET_REQUIRED`; sanity-check `\|\| osIsGpuBusLost` → `NV_ERR_GPU_IS_LOST` |
| 10 | POST-INIT_DONE ctrl RPCs **[netcon3 STORM]** | **C7-e3/e4/e5** | pre-loop returns BEFORE for-loop & `done:` → zero storm prints; e5 gates the heartbeat prints belt-and-suspenders |
| 11 | `GspMsgQueueSendCommand` tx-full (msgq:544) **[GAP-2, REQUIRED]** | **C7-e6** | `if (osIsGpuBusLost(pGpu)) { status = NV_ERR_TIMEOUT; break; }` inside `while(NV_TRUE)` — the worst silent F44 hold |
| 12 | `GspStatusQueueInit` link (msgq:322) **[GAP-2]** | **C7-e6** | explicit marker short-circuit (don't rely on the accidental `kgspHealthCheck` MMIO escape) |
| 13 | `kfspWaitForResponse` (kern_fsp.c:411) **[GAP-2]** | **C7-e6** | marker short-circuit in the hand-rolled loop |
| F1 | `nv_bootstrap_bounded` funnel (open/resume) | **A13** (deployed) | `bootstrap_in_flight` armed → AER early-free sets `os_pci` |
| F2 | `nv_dynpower_bounded` funnel (RTD3/GC6) **[GAP-1, REQUIRED]** | **A13'-e1** | arm `bootstrap_in_flight` around dynpower `queue_work` → AER early-free fires there too |

**Captured-wedge walks (both prevented at source, loglevel-independently):**

- **netcon3 (A13 storm):** AER CmpltTO L687 [1397.590] → A13 sets `os_pci` L699 [1397.5939]. With C7, the first `_kgspRpcRecvPoll` re-entry after L699 hits the pre-loop (2813) `|| osIsGpuBusLost` → `os_pci` set → returns `NV_ERR_RESET_REQUIRED` at ~+34 ms **BEFORE** the for-loop/`done:` label → **none of L705-L844 (the 46 heartbeat / 47 Bad-TimeLo lines) are emitted**. `SET_GUEST_SYSTEM_INFO` fails → `kgspInitRm` unwinds → API lock released → `flush_work` joins → foreground `-EIO`, `ldata_lock` released. Storm eliminated at source → netconsole has nothing to amplify.
- **netcon2 (silent lockdown):** With A13' arming on whichever funnel + the early `os_pci`, the lockdown `timeoutCondWait` (C7-e2) breaks on `osIsGpuBusLost` on the next iteration → `kgspBootstrap_GH100` returns `NV_ERR_NOT_READY` → unwind → `flush_work` joins well before the +3000 ms budget. The silent +1.067 s death is eliminated.

Both sequences close at the **same structural property** (lock-free marker honored by every poll engine), independent of which poll the diverged chip dies at — the property A13 lacked.

---

## 3. PATCH PLAN (file:line → patch ID; minimal L1)

### C7 — base/L1 GSP-core dead-bus poll-reader (upstream-bound, carve as `C7` on fork)

> Justified L1 (sovereign-modules policy): the abort predicate lives **intrinsically** inside NVIDIA's poll loops; there is no L4-L6 way to make those loops honor a disconnect marker. Blast radius concentrated to **one** new predicate (a thin wrapper over the existing `osIsGpuBusDead`, no new semantics) at **exactly 6 call-sites across 4 files**. Upstream-aligned: GSP polls *should* honor `pci_dev_is_disconnected` for any surprise-removed GPU. Declared in the **project-owned** `nv-gpu-lost.h`, NOT generated `g_os_nvoc.h` (no NVOC-gen edits).

- **C7-e1** — `os.c` (after `osIsGpuBusDead`, ~1896): add exported thin wrapper
  `NvBool osIsGpuBusLost(OBJGPU *pGpu) { return osIsGpuBusDead(pGpu); }`. Keep `osIsGpuBusDead` `static inline` so the per-register hot read path is NOT de-inlined. NULL-safe via the inline's `pGpu == NULL` guard.
- **C7-decl** — `src/nvidia/inc/kernel/gpu/nv-gpu-lost.h`: declare `NvBool osIsGpuBusLost(struct OBJGPU *pGpu);` (already included by kernel_gsp.c).
- **C7-e2** — `gpu_timeout.c` `timeoutCondWait` (the `while (!pCondFunc(...))` loop, ~591): add `#include "gpu/nv-gpu-lost.h"`; insert at loop top before `osSpinLoop()`:
  `if (osIsGpuBusLost(pGpu)) { status = NV_ERR_TIMEOUT; break; }`
  `pGpu = pTD->pGpu` is in scope and NULL-safe. **One** edit covers all `gpuTimeoutCondWait` sites (#1-#8).
- **C7-e3** — `kernel_gsp.c` `_kgspRpcRecvPoll` pre-loop (2813-2814): OR-in `|| osIsGpuBusLost(pGpu)` into the **existing** `bFatalError || PDB_PROP_GPU_IS_LOST` condition (do NOT add a separate early-return — the existing block already clears `bPollingForRpcResponse = NV_FALSE` before returning `NV_ERR_RESET_REQUIRED`; OR-ing preserves that, avoiding the `NV_ASSERT_OR_RETURN(!bPollingForRpcResponse)` trap the next entrant would hit). **Verified the clear is present at source.**
- **C7-e4** — `kernel_gsp.c` `_kgspRpcSanityCheck` (314-318): OR-in `|| osIsGpuBusLost(pGpu)` into `!API_GPU_ATTACHED_SANITY_CHECK(pGpu) || PDB_PROP_GPU_IS_LOST` → returns `NV_ERR_GPU_IS_LOST` (existing code). Frees a worker already parked mid-for-loop via `goto done` on its next iteration.
- **C7-e5** — `kernel_gsp.c` `done:` block (2974-2981): wrap the **full** `if (_kgspHeartbeatIsGspRm/LibosHeartbeatTimedOut(...)) { NV_PRINTF(LEVEL_ERROR, ...) }` blocks (NOT just the `NV_PRINTF`) inside `if (!osIsGpuBusLost(pGpu)) { ... }` — the **predicate call** is what reads the dead PTIMER and emits "Bad TimeLo"; short-circuit it. Belt-and-suspenders (C7-e3 already prevents re-entry from reaching `done:`).
- **C7-e6** *(REQUIRED, closes GAP-2)* — three hand-rolled loops:
  - `message_queue_cpu.c:544` `GspMsgQueueSendCommand` tx-full `while(NV_TRUE)`: insert `if (osIsGpuBusLost(pGpu)) { nvStatus = NV_ERR_TIMEOUT; break; }` (highest priority — no MMIO escape, 1 s/element silent F44).
  - `message_queue_cpu.c:322` `GspStatusQueueInit` link wait: same short-circuit (explicit, not relying on the accidental `kgspHealthCheck_HAL` MMIO escape at 382).
  - `kern_fsp.c:411` `kfspWaitForResponse` `while(!kfspIsResponseAvailable_HAL(...))`: same short-circuit (`pGpu` in scope).

### A13' — extend deployed A13 (addon; keep marker source, close funnel gap, fix comment)

- **A13'-e1** *(REQUIRED, closes GAP-1)* — `nv.c` `nv_dynpower_bounded` (~2110-2117): `atomic_set(&nvl->bootstrap_in_flight, 1)` immediately before `queue_work` (2117); `atomic_set(..., 0)` on **both** worker-return arms (the normal completion and the grace/timeout arm at ~2141), mirroring `nv_bootstrap_bounded` (1924/1937/2040). This makes the AER early-free fire for the RTD3/GC6 re-bringup path.
- **A13'-e2** — `nv-pci.c`: **no change** to the early-free block (2974-2982) — keep `os_pci_set_disconnected` first; keep the DISCONNECT-branch `rm_cleanup_gpu_lost_state` (3023) unchanged (now a harmless idempotent no-op for the in-flight case; still load-bearing for non-in-flight DISCONNECT). Do **not** weaken `COND_ACQUIRE`.
- **A13'-e3** *(REQUIRED, closes GAP-5)* — `nv.c:1959-1968` + JOIN-COST comment (2027-2036): correct to *"API lock released across the lockdown cond (kernel_gsp.c:4785), **REACQUIRED across the post-INIT_DONE control-RPC phase (4818-4820)**; therefore `rm_cleanup`'s COND_ACQUIRE may DEFER during the RPC storm — the lock-free `os_pci` marker + C7 poll-readers (not `rm_cleanup`'s PDB set) free that poll."* Note C7 now bounds the RPC poll too, not just the lockdown MMIO-cond.

### A14 — fix-bar1 sticky-bit fail-fast gate (addon, defense-in-depth, separable)

> A-series addon, retire-able. Deterministic for the known production substrate (fix-bar1-recovered EQ-diverged chip); a probabilistic first line that enters **zero** GSP polls when it fires. **Never** the completeness guarantee (false-negative on novel divergence).

- **nv-linux.h** (`nv_linux_state_t`, ~1462, beside `bootstrap_in_flight`): add `atomic_t diverged_recovered;` + `atomic_t reopen_gsp_torndown;` (per-device, lock-free, kzalloc-zero-init at `nv_pci_probe`, destroyed with `nvl` on remove → **structural false-positive guard**: fresh enumeration re-creates `nvl` → bits clear).
- **Divergence predicate** (3 lock-free conjuncts):
  `nv->is_external_gpu && atomic_read(&nvl->diverged_recovered) && atomic_read(&nvl->reopen_gsp_torndown)`
- **Gate placement** — `nv.c` at the TOP of **both** `nv_bootstrap_bounded` (~1904, before the feature gates and `atomic_set(bootstrap_in_flight,1)`) **and** `nv_dynpower_bounded` (before its `queue_work`): if predicate TRUE → `nv_printf(NV_DBG_ERRORS, "NVRM: tb_egpu [A14]: refusing re-open of diverged-recovered eGPU (WPR2-torndown) before GSP bringup -> -EIO (#292); cold-recover via fix-bar1\n"); return -EIO;` (dynpower returns the `NV_STATUS` equivalent). Enters zero polls, queues no worker, no `flush_work`.
- **Arming `reopen_gsp_torndown`** — `nv-tb-egpu-close.c` last-close block (~155): when `is_last_close && atomic_read(&nvl->diverged_recovered)`, do one **passive** WPR2 read (the chip is still alive at last-close — capture-confirmed n=2: netcon2 L878, netcon3 L682 both `WPR2=0x00000000`); if cleared, `atomic_set(&nvl->reopen_gsp_torndown, 1)`. Reaching the post-`nv_shutdown_adapter` site (nv.c:2668, persistence-OFF branch) is itself the GSP-teardown signal; the WPR2 read corroborates the design-of-record conjunct.
- **Out-of-band assertion (false-positive guard)** — `nv-tb-egpu-recover.c` sysfs (~735/774): add write-only `DEVICE_ATTR(tb_egpu_diverged_recovered, 0200, NULL, store)` → `kstrtoul` + `atomic_set(&nvl->diverged_recovered, val?1:0)`; optional read-only `DEVICE_ATTR(tb_egpu_reopen_blocked, 0444, show)` returning `diverged_recovered && reopen_gsp_torndown` (lets orchestration distinguish an A14 `-EIO` from other `-EIO`). **CRITICAL:** register these in an **always-on** attr group created in `nv_pci_probe` and removed in `nv_pci_remove` **before** `nvl` is freed — NOT the `Enable`-gated `tb_egpu_recover_attr_group` (recover.c:803-810 only creates that when `NVreg_TbEgpuRecoverEnable != 0`; live default is 0). The bits live on `nvl` and must work with `NVreg_TbEgpuRecoverEnable=0`.
- **`tools/fix-bar1.sh`** (injector repo, `--bind` block after persistence engage): `echo 1 > /sys/bus/pci/devices/$GPU/tb_egpu_diverged_recovered 2>/dev/null || warn ...`. Document the `-EIO = cold-recover` contract (re-run `fix-bar1 --bind` → slot power-cycle → fresh `nvl` → bits clear → clean bringup) in the header "Known hazards".

### Packaging

`patches/base/C7-292-inflight-deadbus-poll-coverage.patch` (upstream-bound; docs/upstream-plan.md). `patches/addon/A13-292-inflight-aer-earlyfree.patch` extended in place (A13'). `patches/addon/A14-292-reopen-failfast-gate.patch` (project-local). Patch-intent + review files per schema. Build `apnex.32`.

---

## 4. NO-REGRESSION

`osIsGpuBusLost` (and the A14 predicate) are TRUE **only** when `os_pci_is_disconnected` OR `PDB_PROP_GPU_IS_LOST` is set — a condition a healthy bus never has. Every added check is a pure-FALSE no-op on a live bus.

| Prior result / invariant | Why preserved (source-verified) | Asserts that must still pass |
|---|---|---|
| **Normal cold-init** (~1.3-1.9 s, BAR1 32 GiB, params 3000/2000) | Healthy chip: `os_pci` clear, PDB clear → all C7 checks FALSE (one `READ_ONCE` per poll iter, sub-ns, no lock); A14 `diverged_recovered=0` (kzalloc; fix-bar1 never ran) → gate bypassed, byte-identical | Cold-plug `nvidia-smi -L` succeeds; BAR1=32 GiB; persistence engages; no new log lines |
| **R1-R4 (WPR2 fast-fail contained; resets contain-only)** | Fast-fail re-open has a **live** bus (no `os_pci`, no PDB) → `osIsGpuBusLost` FALSE → no short-circuit → identical fast-fail. A10-v2 grace arm **skips** the marker on fast-fail (nv.c:1981-1988, chip NOT sunk) → A14 never fires. Reset paths are pre-bringup-untouched | WPR2-stuck re-open still fast-fails `NV_ERR_INVALID_STATE` (kernel_gsp.c:4763); chip not sunk; recoverable |
| **A10-v2 lockdown arm** (nv.c:1990-2004) | Byte-identical; C7 only makes its `flush_work` join **faster** (worker self-aborts sooner). Surprise-removal SURVIVAL (06-05 clean A2→C5→A7) is on the teardown path, untouched | A12 budget still bounds a synthetic stuck worker; surprise-removal SURVIVAL still clean |
| **A12 funnel** (3000 ms budget + grace discriminator) | Preserved; C7 makes the worker self-abort **before** the budget in the AER case → timeout arm fires **less** often; grace keys on completion-state, not markers | A12 still bounds; `-EIO` propagation unchanged (same path as lockdown-arm return at nv.c:2042) |
| **C1/C5/C6 (F44 fix, `COND_ACQUIRE`)** | NOT weakened to blocking (that is the F44 wedge). `rm_cleanup` keeps `COND_ACQUIRE`; C7 makes the lock-free `os_pci` marker sufficient so PDB-via-`rm_cleanup` is not load-bearing | No new blocking acquire anywhere on the AER/poll path |
| **A13 (deployed)** | Marker source kept verbatim; A14 sits before `atomic_set(bootstrap_in_flight,1)` so a refused open leaves the flag 0 and the AER branch stays correct | A13 AER half still fires DISCONNECT (no bus reset) on a real in-flight AER |
| **Error-code surface** | C7-e3/e4 reuse existing `NV_ERR_RESET_REQUIRED`/`NV_ERR_GPU_IS_LOST`; C7-e2 returns `NV_ERR_TIMEOUT` on a dead bus | Caller audit (§5/§6 GAP-6): lockdown caller gh100:1050 verified generic `!= NV_OK`; SPDM/reset/CC callers confirmed not to branch on `NV_ERR_TIMEOUT` |

---

## 5. VALIDATION PLAN (does NOT repeat the netcon3 mistakes)

Per reliability methodology: one variable per test, written hypothesis, n≥3 to resolve, cheapest first. **Compile, not `git apply --check`** (the P5 lesson).

**(0) Build gate.** Real `make modules` of the composed C+E+A+C7 tree against the live `7.0.9-fc44` kernel. Confirm `osIsGpuBusLost` wrapper + `nv-gpu-lost.h` decl + `gpu_timeout.c` include build clean across all TUs. **Caller audit (GAP-6):** grep every `gpuTimeoutCondWait` caller for an `NV_ERR_TIMEOUT`-specific branch (lockdown gh100:1050 = generic; verify SPDM gh100:620/662, reset gh100:133/144, CC gh100:1271); grep every `timeoutCondWait` caller for a cond that completes via a **non-MMIO/sysmem** path after the GPU is marked lost (low risk — lost-GPU MMIO conds never complete — but confirm, since the primitive is driver-wide).

**(a) Observability-amplifier isolation — the netcon3 fix.** Run the **primary repro** at BOTH `console_loglevel=8` (netconsole armed) **AND** minimised observability: `echo 4 4 1 7 > /proc/sys/kernel/printk` + async `/dev/kmsg` + **external** 100 ms ping/ssh liveness probe + fsync'd heartbeat-file + **passive** sysrq-w/t/l armed. **SURVIVAL at BOTH loglevels is the load-bearing proof** that the storm is removed *at source* (C7-e3 pre-loop return + C7-e5 print-gate), not merely hidden. Passive channels only (memory: observability perturbs this bug; IBT blocks kprobe on closed RM; kdump/drgn can't capture the live wedge).

**(b) Coverage of ALL poll-sites, not just lockdown.** Primary repro = exact apnex.31 Stage-5 sequence (fix-bar1 `--bind` the 32 GiB-diverged chip → engage then DISABLE persistence → THE ROLL `nvidia-smi -L`), n≥3. **Expected log signature:** A13 `os_pci` marker fires at AER CmpltTO (~+1.0 s) → **zero** `_kgspRpcRecvPoll` / `_kgspIsHeartbeatTimedOut` / "Bad TimeLo" lines → worker returns `NV_ERR_RESET_REQUIRED` → `flush_work` joins → open `-EIO`, `ldata_lock` released, host alive, GPU recoverable by a subsequent cold-plug. On ANY residual wedge, the passive sysrq blocked-task + all-CPU backtrace **attributes it to a specific poll** (retires GAP-2/GAP-9). **Add the GAP-1 runtime-PM repro:** idle the diverged chip → GC6/RTD3 → touch → resume, n≥3 (confirms A13'-e1 arms `bootstrap_in_flight` on the dynpower path so the AER early-free fires).

**(c) Recover-disabled control.** Repeat the primary repro with `NVreg_TbEgpuRecoverEnable=0`. Confirm: (i) C7 still frees the worker (it reads `os_pci`/PDB, independent of the recover module); (ii) the A14 sysfs nodes are present + writable (always-on attr group); (iii) `fix-bar1` still asserts `diverged_recovered`. Host survives identically.

**(d) Acceptance criteria.** ALL must hold:
1. Host **survives** the diverged re-open (no power-cycle) at loglevel 8 **and** 4, n≥3, on **both** the open funnel and the dynpower funnel.
2. **Every** poll-site demonstrably short-circuits: zero storm lines in the capture; passive sysrq (if armed) shows no worker parked at any of sites #1-#13.
3. **No-regression matrix** (each n≥3): clean cold-plug works (gate inert); fix-bar1-first-open works (`reopen_gsp_torndown` not yet armed); persistence-ON open/close/re-open works (WPR2 not cleared → A14 inert); R2 WPR2 fast-fail still contained, not refused.
4. **Userspace contract:** after an A14 `-EIO`, `fix-bar1 --bind` (slot-cycle) → fresh `nvl` → bits clear → re-bringup succeeds.
5. 14-day soak before cutover.

---

## 6. RISKS / OPEN (ranked; each with resolver)

| # | Risk | Sev | Resolver / status |
|---|---|---|---|
| **GAP-1** | `nv_dynpower_bounded` (RTD3/GC6) is a SECOND bringup funnel that arms neither A13 nor C7's marker source → wedge reproduces on dynpower resume | **HIGH** | **In spec: A13'-e1** arms `bootstrap_in_flight` around the dynpower `queue_work`; A14 gate placed there too; runtime-PM repro added to test matrix (5b). Verified at nv.c:2094-2117 + the only `bootstrap_in_flight` refs (1924/1937/2040 + nv-pci.c:2974). |
| **GAP-2** | Three hand-rolled loops (msgq:544 `while(NV_TRUE)` 1 s/elem no-MMIO-escape = worst silent F44; msgq:322; kern_fsp.c:411) bypass both chokepoints | **HIGH** | **In spec: C7-e6 promoted to REQUIRED.** Verified source: msgq:544 escapes only on sysmem `msgqTxGetWriteBuffer` or `gpuCheckTimeout`; kern_fsp.c:411 is `while(!kfspIsResponseAvailable_HAL)`. Until patched, "every poll covered" is false. |
| **GAP-3** | Lock-free `gpuSetDisconnectedProperties` from AER clobbers live PM state (7 bits incl. PM_CODEPATH/STANDBY/bInD3Cold/GC6) racing a dynpower worker; `NV_GET_NV_PRIV_PGPU` violates its API-lock precondition | **HIGH** | **Resolved by rejecting A13b** and making **C7 read-only** load-bearing (reads `os_pci`/PDB, never writes → no lock, no PM clobber, no precondition violation). Verified gpu.c:5272-5290, nv-priv.h:352. |
| **GAP-4** | "Does the wedge survive netconsole-off?" unresolved (both captures died +1.07 s); GAP-1/GAP-2 leave reachable **storm-free** F44 holds a loglevel change can't reveal | **HIGH** | Dual-loglevel survival test (5a) + passive blocked-task capture; the fix is correct under BOTH the printk-amplifier and the genuine-F44 readings (no storm AND worker freed). |
| **GAP-5** | A12 lock-model comment (nv.c:1959-1968) is known-incomplete (says worker holds only group lock; truth: API lock REACQUIRED at 4818-4820 for post-INIT_DONE RPCs) — perpetuates the false "rm_cleanup will succeed" assumption | **MED** | **In spec: A13'-e3** corrects the comment + the JOIN-COST comment. Verified kernel_gsp.c:4785/4818-4820 + heartbeat-init-after-INIT_DONE proof. |
| **GAP-6** | C7-e2 edits `timeoutCondWait`, a **driver-wide** primitive, and changes the dead-bus return to `NV_ERR_TIMEOUT` | **MED** | Caller audit + real `make modules` (5/0). Low risk (lost-GPU MMIO conds never complete anyway); confirm explicitly. |
| **GAP-7** | C7 frees the worker via the `os_pci` READ short-circuit; PDB may end up **never set** (os.c:2050 pre-empts the MMIO_DEAD funnel; heartbeat self-sink needs `timeoutCount==3`, never reached; `rm_cleanup` defers) → chip left os_pci-dead but RM-PDB-unset until teardown | **MED** | Confirm the close/teardown path (`nv_shutdown_adapter`, `rm_cleanup`, device free) + any subsequent re-open do NOT depend on `PDB_PROP_GPU_IS_LOST==TRUE`. If they do, have the worker's own `NV_ERR_RESET_REQUIRED` unwind set PDB under its already-held locks (safe — worker owns them). Cheap; do before the live test so a teardown anomaly isn't misread as a new wedge. |
| **GAP-8** | A14 sticky-bit gate is structurally blind to a **novel** divergence (driver-invisible live) → false-negative → worker queued | **MED** | C7 stays the load-bearing layer; A14 ships WITH, never instead. Document the false-negative in-code so no future reviewer elevates the gate to "the fix." |
| **GAP-9** | Storm re-caller multiplier (~23 returns vs one abort), absent "API lock contended, deferring" line, and netcon2's exact stuck poll are unpinned | **LOW** | C7's pre-loop catches every re-entry (coverage unaffected); minimised-observability re-test (5a) captures a clean blocked-task stack to retire these. |

**Bottom line:** C7 (read-only dead-bus poll-reader at 2 chokepoints + 3 hand-rolled loops) is the load-bearing fix; A13' keeps the lock-free marker source and closes the dynpower funnel + lock-model comment; A14 is fix-bar1 fail-fast defense-in-depth. GAP-1 and GAP-2 are reachable wedge paths the prior candidates left open and are patched first; GAP-3 rejects the A13b PDB-write variant and confirms the read-only approach is the safe primary; GAP-4/5/6/7 gate a trustworthy test. Build `apnex.32`; validate at dual loglevel, n≥3, on both funnels, with every poll-site demonstrably short-circuited before cutover.

**Source-verified anchors (this session):** `nv.c` 1924/1937/2040 (only `bootstrap_in_flight` sites), 2094-2117 (dynpower funnel, own `queue_work`, no flag), 2479 (F40b-shutdown funnel — teardown, no bringup polls); `nv-pci.c` 2974/2981/3023; `message_queue_cpu.c` 544 (`while(NV_TRUE)`, 1 s/elem)/322/377/382; `kern_fsp.c` 364 (`gpuTimeoutCondWait` send) / 411 (hand-rolled recv); `gpu.c` 5266-5290 (7-property write + deferred `bLockGpuGroupDevice` work-item); `os.c` 1884 (`osIsGpuBusDead` = os_pci OR PDB) / 2050 (short-circuit pre-empts) / 2081 (MMIO_DEAD funnel); `kernel_gsp.c` 2813-2822 (pre-loop, clears `bPollingForRpcResponse`) / 305-322 (sanity) / 2928-2933 (self-sink) / 2974-2981 (heartbeat prints); `gpu_timeout.c` `timeoutCondWait` (honors no marker); `nv-priv.h` 352-355 (API-lock precondition). `osIsGpuBusDead`/`os_pci_is_disconnected` confirmed absent from `kernel_gsp.c` and `gpu_timeout.c`.
