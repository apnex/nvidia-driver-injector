# GAP-6 / GAP-7 PRE-BUILD VERDICT — C7 (apnex.32)

**GATE RESULT: GO — build apnex.32, with two spec deltas (C7-e7 REQUIRED, C7-e8 recommended) folded in before compile.** All claims below re-verified against the live tree at `/root/open-gpu-kernel-modules` (grep + source reads this session), reconciling 5 independent audit streams.

**Authoritative caller count: 25, not 27.** Tree-wide grep of `gpuTimeoutCondWait(` (excluding the `#define`) returns exactly 25 call sites; the two audit streams reporting "27" over-counted. No site is missing from the table below.

---

## 1. GAP-6 VERDICT

### Caller table (all 25 sites)

| # | file:line | cond fn (what it reads) | status consumption | reachable on GB202/GSP-RM/TB-eGPU | verdict |
|---|---|---|---|---|---|
| 1 | `src/kernel/gpu/arch/blackwell/kern_gpu_gb100.c:1578` | `_gpuMnocMboxSendReceiverCond` (MNOC PRI MMIO) | returned directly; callers generic `!=NV_OK` | NO — `gpuMnocMboxSend` GB202-binds stub (g_gpu_nvoc.c:1789) AND regkey-gated (`NV_REG_STR_RM_FSP_USE_MNOC_CPU`, kern_fsp.c:166-172) | SAFE |
| 2 | `kern_gpu_gb100.c:1620` | `_gpuMnocMboxSendCreditCond` (MMIO) | same | NO (same double gate) | SAFE |
| 3 | `kern_gpu_gb100.c:1690` | `_gpuMnocMboxPollCond` (MMIO) | same | NO (same double gate) | SAFE |
| 4 | `src/kernel/gpu/falcon/arch/ampere/kernel_falcon_ga102.c:264` | `_kflcnWaitForScrubbingToFinish` (HWCFG2 MMIO) | returned directly; `NV_ASSERT_OK` upstream | YES — GB202 binds `_GA102`; every falcon/GSP reset | SAFE |
| 5 | `src/kernel/gpu/falcon/arch/turing/kernel_falcon_tu102.c:323` | `_kflcnMemScrubbingFinished` (DMACTL MMIO) | returned directly | NO — `_TU102` bound TU102-GA100 only | SAFE |
| 6 | `kernel_falcon_tu102.c:549` | `s_riscvIsIcdNotBusy` (ICD MMIO) | `!= NV_OK → return NV_ERR_TIMEOUT`; 5 consumers at :606/661/707/747/785 gate further ICD pokes on `!= NV_ERR_TIMEOUT` | YES — `kflcnRiscvIcdWaitForIdle` GB202→`_TU102`; RISCV crash forensics | SAFE — **the only TIMEOUT-specific consumers in the tree**, and the TIMEOUT branch is the bail-out (`return NV_ERR_INVALID_STATE`, skips dead MMIO writes); early TIMEOUT lands on the identical branch a natural timeout takes, in the safe direction |
| 7 | `src/kernel/gpu/gsp/arch/hopper/kernel_gsp_gh100.c:133` | `_kgspWaitForAsserted` (RESET_STATUS MMIO, TMR flags) | print + `DBG_BREAKPOINT`, status propagated generically | YES — `kgspResetHw` GB202→`_GB100`→`_GH100`; every GSP reset | SAFE |
| 8 | `kernel_gsp_gh100.c:144` | `_kgspWaitForDeasserted` (same reg) | same | YES | SAFE |
| 9 | `kernel_gsp_gh100.c:620` | `_kgspSpdmBootedOrFmcError` (mailbox MMIO) | `!=NV_OK → goto exit` | NO — SPDM-gated (gh100:1026, `PDB_PROP_SPDM_ENABLED`); no CC/SPDM on this host | SAFE |
| 10 | `kernel_gsp_gh100.c:662` | `_kgspFalconMailbox0Cleared` (mailbox `==0` — the polarity-trap site) | `!=NV_OK → goto exit` | NO (same SPDM gate) | SAFE |
| 11 | `kernel_gsp_gh100.c:1050` | `_kgspLockdownReleasedOrFmcError` (HWCFG2/mailbox MMIO) — **THE #292 wedge site** | `!=NV_OK →` prints + `kgspFmcReportErrorCode` + `kfspDumpDebugState` (all dead reads short-circuit) + return; `kgspBootstrap_GH100` propagates generically into the bounded boot-retry loop (kernel_gsp.c:4798/5077) | YES — `kgspBootstrap` GB202→`_GH100` (g_kernel_gsp_nvoc.c:801-804); every boot/resume | SAFE + **PRIMARY TARGET** — e2 converts the spin/accidental-0xFFFFFFFF exit into prompt clean `NV_ERR_TIMEOUT` |
| 12 | `kernel_gsp_gh100.c:1271` | `_kgspHasCcCleanupFinished` (mailbox MMIO) | `!=NV_OK → goto exit` (posted ack write, harmless); return DISCARDED at kernel_gsp.c:5190 | NO — `gpuIsCCFeatureEnabled`-gated | SAFE |
| 13 | `src/kernel/gpu/gsp/arch/blackwell/kernel_gsp_gb100.c:83` | `_kgspWaitForResetAccess` (PLM MMIO, TMR flags) | print + `DBG_BREAKPOINT`, then **status discarded** — proceeds into `kgspResetHw_GH100` regardless | YES — GB202's bound resetHw | SAFE — timeout deliberately non-fatal; note 0xFFFFFFFF makes cond accidentally TRUE (exits NV_OK before e2) |
| 14 | `src/kernel/gpu/gsp/arch/ampere/kernel_gsp_falcon_ga102.c:92` | `s_dmaPollCondFunc` (DMATRFCMD MMIO) | print + `DBG_BREAKPOINT` + return; `NV_ASSERT_OK_OR_RETURN` upstream; RPC dispatcher prints-and-continues | RARE — only via `kgspLoadAndExecuteHsBinary_GA102` (GB202-bound, GSP RPC `load_exec_hs_binary`, PM path) | SAFE |
| 15 | `src/kernel/gpu/gsp/arch/turing/kernel_gsp_falcon_tu102.c:473` | `_kgspIsReloadCompleted` (BSI scratch MMIO) | `(status != NV_OK) \|\| (secMailbox0 != NV_OK) → return NV_ERR_TIMEOUT` — **produces** TIMEOUT, consumed generically | RARE — `kgspExecuteCoreResume` GB202→`_TU102`, resume/HS-binary path only | SAFE |
| 16 | `src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c:1155` | `_kgspIsProcessorSuspended` (mailbox bit 31 MMIO — 0xFFFFFFFF evaluates TRUE) | return **DISCARDED** at `kgspUnloadRm_IMPL` (kernel_gsp.c:5194); generic at falcon_ga102.c:325/falcon_tu102.c:531 | YES — every unload/suspend (the A7/F40 shutdown arm) | SAFE — accidental-TRUE means dead-bus never spins here even pre-C7; teardown proceeds either way |
| 17 | `src/kernel/gpu/sec2/arch/blackwell/kernel_sec2_gb10b.c:308` | `_ksec2IsCmdhandlingCompleted_GB10B` (MMIO) | generic | NO — GB10B Tegra SoC only | SAFE |
| 18 | `kernel_sec2_gb10b.c:376` | `_ksec2IsGspTargetMaskReleased` (HWCFG2 MMIO) | generic | NO — GB202 binds stub (g_kernel_sec2_nvoc.c:840) + `PDB_PROP_KSEC2_BOOT_GSPFMC` gate | SAFE |
| 19 | `src/kernel/gpu/sec2/arch/blackwell/kernel_sec2_gb20b.c:577` | `_ksec2WaitBootCond_GB20B` (MMIO) | generic | NO — GB20B/GB20C only (g_kernel_sec2_nvoc.c:885) | SAFE |
| 20 | `src/kernel/gpu/fsp/kern_fsp.c:364` | `_kfspWaitForCanSend` (queue HEAD/TAIL MMIO) | print + return; `kfspSendPacket_GH100`:701 remaps to `NV_ERR_INSUFFICIENT_RESOURCES` | YES — every FSP send (GB202 falls back to GH100 EMEM path, MNOC regkey off) | SAFE — note dead-bus HEAD==TAIL (both 0xFFFFFFFF) is accidental-TRUE; recovery falls to `kfspWaitForResponse` (C7-e6) |
| 21 | `src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c:828` | `_kfspWaitBootCond_GH100` (THERM scratch MMIO) | `gpuMarkDeviceForReset` (SW scratch only) + log + return, generic | NO — GH100-only binding (g_kern_fsp_nvoc.c:488-490); GB202 uses `_GB202` | SAFE |
| 22 | `kern_fsp_gh100.c:1158` | `_kfspIsGspTargetMaskReleased` (`GPU_REG_RD32_UNCHECKED` HWCFG2 — bypasses 0xbadf check; 0xFFFFFFFF reads "released") | returned directly; `kgspBootstrap_GH100` prints + propagates generically | YES — GB202-bound (g_kern_fsp_nvoc.c:630-636); every GSP boot, immediately before the #292 lockdown wait | SAFE — accidental-TRUE site; exits NV_OK before e2 (identical to today); next covered poll fails fast |
| 23 | `src/kernel/gpu/fsp/arch/blackwell/kern_fsp_gb202.c:80` | `_kfspWaitBootCond_GB202` (THERM scratch `==0xFF`, 5s OSTIMER) | `gpuMarkDeviceForReset` + `NV_ERROR_LOG` (5 short-circuited reads) + `kfspDumpDebugState` + return; consumers all generic | YES — **the hot cold-init site**, every RmInitAdapter (A6/A12 path) | SAFE — strict improvement: dead-value ≠ 0xFF so today burns the full 5s; e2 makes it prompt |
| 24 | `src/kernel/gpu/fsp/arch/blackwell/kern_fsp_gb100.c:95` | `_kfspWaitBootCond_GB100` (THERM scratch) | same shape + FUSE check, generic | NO — GB100/102/110/112 only (g_kern_fsp_nvoc.c:496-499) | SAFE |
| 25 | `src/kernel/gpu/bif/arch/ada/kernel_bif_ad102.c:73` | `_kbifPreOsCheckErotGrantAllowed_AD102` (PBUS scratch MMIO) | print + return, generic | NO — AD102-AD107 only; GB202 gets inline NV_OK stub (g_kernel_bif_nvoc.c:1056-1064); on Ada dead-bus it early-returns NV_OK at the :65 pre-check anyway | SAFE |

**Hazard (a) — TIMEOUT-specific consumers: EMPTY of danger.** The only sites branching on `NV_ERR_TIMEOUT` specifically are the 5 ICD gates (`kernel_falcon_tu102.c:606/661/707/747/785`) where the TIMEOUT branch *skips* hardware touches and returns `NV_ERR_INVALID_STATE`. Sites #15 and #6 *manufacture* `NV_ERR_TIMEOUT` (producers, not consumers). All other `==NV_ERR_TIMEOUT` hits in gsp/fsp/sec2 (kern_fsp.c:418, kernel_sec2.c:220/625, kernel_gsp.c:426/2866) consume hand-rolled-loop or msgq statuses, not `timeoutCondWait` outputs.

**Hazard (b) — non-MMIO-completing conds: ZERO among all 25.** Every cond function reads BAR0 (`GPU_REG_RD32` / `_UNCHECKED` / `kflcnRegRead_HAL` / IoAperture `REG_RD32`), all short-circuited via `osIsGpuBusDead`. The one genuine sysmem-completing poll in the GSP family — `kgspIssueNotifyOp_GH100`'s seq poll at `kernel_gsp_gh100.c:1238` — is a hand-rolled `gpuCheckTimeout` loop, **not** a `timeoutCondWait` caller; e2 cannot touch it (see Spec Deltas §4).

### Engine-dispatch answer

**ONE edit intercepts everything.** Verified this session:
- `gpuTimeoutCondWait` is a plain compile-time macro — `inc/kernel/gpu/gpu_timeout.h:147`: `#define gpuTimeoutCondWait(g,a,b,t) timeoutCondWait(&(g)->timeoutData, t, a, b, __LINE__)`. No NVOC/HAL vtable; `TIMEOUT_DATA` (gpu_timeout.h:76-92) holds scalars + `pGpu`, no function pointers.
- `timeoutCondWait` (`gpu_timeout.c:572-608`) is the **only** cond-wait body in the tree: case-insensitive grep for `condwait` across `src/nvidia`, `src/common`, `kernel-open` finds no `tmrApiCondWait` and no second engine. **There is no TMR-variant body** — `GPU_TIMEOUT_FLAGS_TMR/TMRDELAY/OSTIMER/OSDELAY` are clock-selection branches *inside* `timeoutCheck`/`_checkTimeout` (gpu_timeout.c:330-465), called from the single `while (!pCondFunc(...))` loop. `pTimeout==NULL` callers get `GPU_TIMEOUT_DEFAULT` built at :585-589 in the same loop.
- TMR-flagged waits (sites #7/#8/#13) already self-terminate on a dead bus (`tmrGetCurrentTime` reads 0xFF.. ≥ deadline); e2 makes them deterministic.
- Precedent: the engine already fabricates early `NV_ERR_TIMEOUT` on GPU-state grounds — `timeoutCheck:483-484` (`(pGpu != NULL) && API_GPU_IN_RESET_SANITY_CHECK(pGpu) → return NV_ERR_TIMEOUT`, verified) and `_checkTimeout`'s detached checks (:416/438). Every caller already tolerates a spontaneous early TIMEOUT. Note `API_GPU_IN_RESET_SANITY_CHECK` (g_gpu_nvoc.h:5873) does **not** test `PDB_PROP_GPU_IS_LOST` — the precise gap e2 fills.
- e2's `break` correctly bypasses the rescue recheck at gpu_timeout.c:598-602 (the `TIMEOUT && cond-now-true → NV_OK` branch) — on a dead bus that recheck IS the accidental-0xFFFFFFFF hazard; bypassing it is design intent.

### NET effect on the C7-e2 spec

**Spec stands, with three amendments (none structural):**
1. **NULL guard** (hardening): write the edit as `if ((pGpu != NULL) && osIsGpuBusLost(pGpu)) { status = NV_ERR_TIMEOUT; break; }` — mirrors `timeoutCheck:483`'s own guard. Analysis shows `pGpu` non-NULL by invariant (the loop already passes it unguarded into `pCondFunc`; the `pTimeout==NULL` path derefs it in `timeoutSet` at gpu_timeout.c:285), so this is belt-and-braces.
2. **Claim wording**: e2 short-circuits every *spinning* poll-site, not every poll-site. The cond is evaluated in the `while` condition **before** the loop body, so accidental-true-on-dead-bus conds (#13, #16, #20, #22) return NV_OK without e2 firing — identical to today, no regression, bounded by the next covered poll. Live-test log signatures must NOT expect TIMEOUT from those four sites. This conservative placement is correct — hoisting the check above the cond evaluation is what would create hazard-(b) flips.
3. **Insertion point confirmed vanilla**: `while (!pCondFunc(pGpu, pCondData))` at gpu_timeout.c:591 is intact vendor code in this (partially composed) tree; insert at loop top before `osSpinLoop()`. Build-order: C7-e1 (`osIsGpuBusLost` decl) must land first or e2 won't compile.

---

## 2. GAP-7 VERDICT

**No teardown, re-open, or diagnostic path depends on PDB_PROP_GPU_IS_LOST==TRUE for CORRECTNESS in the #292 sequence. C7 ships WITHOUT a PDB write.**

Full-sequence trace (source-verified by the teardown-trace audit, anchors re-confirmed):
- The freed worker's unwind never reads the PDB: `kgspInitRm` done-block (kernel_gsp.c:5129-5158) → `RmInitAdapter` `shutdown:` (osinit.c:2371) → `RmShutdownAdapter` (2392-2525) skips `gpuStateUnload`/`gpuStateDestroy`/`kgspUnloadRm` via **unset `NV_INIT_FLAG_GPU_STATE*`** (osinit.c:865/1310/1339/1369), not via PDB. `rmapiDelPendingDevices` is a no-op (no clients pre-`gpuStateInit`) → no free RPCs.
- **PDB lifetime ends inside the unwind**: `gpumgrDetachGpu` → `_gpumgrDestroyGpu` (gpu_mgr.c:1636/1640) destroys the OBJGPU. A late PDB-set is structurally impossible *and* unnecessary.
- **Re-open is ungated**: `nv_check_gpu_state` (nv-linux.h:1620) tests only `NV_FLAG_IN_SURPRISE_REMOVAL`, whose sole setter (`osHandleGpuLost`, osinit.c:461) never ran. Re-open builds a **fresh OBJGPU with PDB unset by construction**; only `pci_dev->error_state=perm_failure` persists (os-pci.c:165-177). All MMIO short-circuits on os_pci alone (os.c:1895/2050); first cond-wait breaks via e2; clean −EIO in ms. A14 remains DiD, not correctness.
- Every direct `getProperty(PDB_PROP_GPU_IS_LOST)` reader audited (journal.c:565/1089/2934/3133, nv_debug_dump.c:282, rpc.c:1854/2097/11530, kernel_gsp.c:315/2814, kern_fsp_gh100.c:638, osapi.c:424-451, gpu.c:7427, gpu_access.c:838, mem_mgr_pwr_mgmt.c:257, kernel_rc_watchdog_callback.c:155, kernel_nvlink.c:1159/1213, gpu_protobuf.c:85) is a **protective skip**: PDB-unset degrades to "attempts the access, which the os_pci short-circuit / C7-bounded RPC absorbs" — latency and log noise, never a leak, hang, or must-skip HW touch.

**The one genuine PDB-only correctness branch**: `rpcRmApiFree_GSP` at `rpc.c:11530` (verified: returns `NV_OK` on PDB so resserv teardown doesn't assert). It is **unreachable in the #292 failed-init sequence** (zero GSP-backed objects exist pre-`gpuStateInit`). In the *adjacent* post-init-loss family (GPU dies while initialized), PDB-unset turns every object free into a per-object `NV_ASSERT` + LEVEL_ERROR line — `NV_ASSERT` is non-fatal in release and host-side bookkeeping completes (no leak), but the volume is exactly the netconsole-amplifier print-storm class that wedged apnex.31. Handled by spec delta C7-e7, not by a PDB write.

**If a PDB-set is ever wanted anyway** (documented, NOT required): the one precondition-clean point is RmInitAdapter's `shutdown:` label (osinit.c:2371-2376) — worker provably holds the API lock (osapi.c:1761 + the `rmapiLockIsOwner()` assert at kernel_gsp.c:5075), OBJGPU alive, invisible to other threads, GAP-3 PM-bit-clobber objection moot for a never-initialized GPU. It would be dead state microseconds later and cannot influence the re-open.

**Systemic finding**: the fork's entire C5-v4 guard layer (G2/G3/G6/G8/G9 + journal/nvd guards) keys on PDB alone, so the os_pci-set/PDB-unset end-state **bypasses the fork's own guard layer wholesale**. Boundedness then rests entirely on (a) the os.c:2050 read short-circuit and (b) C7's engine-level edits (e2/e3/e4/e6) — which the audits confirm is sufficient. C7-e7 re-coheres the guard layer for one token per site.

---

## 3. SPEC DELTAS (amendments to design-of-record §3)

1. **C7-e2 AMENDED (wording only)**: insert as `if ((pGpu != NULL) && osIsGpuBusLost(pGpu)) { status = NV_ERR_TIMEOUT; break; }` at the top of the `while` body, gpu_timeout.c:~593, before `osSpinLoop()`. Mirrors timeoutCheck:483's NULL guard. e1 must land before e2 compiles.
2. **C7-e7 NEW — REQUIRED for apnex.32**: widen the five fork PDB-only guards to `osIsGpuBusLost(pGpu)` (one token each, read-only, no new locking):
   - `rpc.c:1854` (`_issueRpcAndWait` G2) — kills per-RPC LEVEL_ERROR stream (`bQuietPrints` never set on the GPU-lost branch, kernel_gsp.c:317);
   - `rpc.c:2097` (`_issueRpcLarge` G3) — also kills the bare `NV_ASSERT(0)` at 2116/2153 firing per chunked RPC;
   - `rpc.c:11530` (`rpcRmApiFree_GSP`) — **the load-bearing one**: restores the designed return-NV_OK-so-resserv-stays-quiet semantics in the os_pci-only state, preventing a per-freed-object assert/log storm of the proven apnex.31 wedge class;
   - `journal.c:2934` (`rcdbAddRmGpuDump` skip);
   - `nv_debug_dump.c:282` (`nvdDumpAllEngines` break — keep the `|| PDB_PROP_GPU_INACCESSIBLE` term).
3. **C7-e8 NEW — recommended polish**: `kern_fsp_gh100.c:637-638` G9 guard, replace `pGpu->getProperty(pGpu, PDB_PROP_GPU_IS_LOST)` with `osIsGpuBusLost(pGpu)` — currently dead in the os_pci-only state; without it `_kfspWriteToEmem_GH100` exits via the `NV_ASSERT_OR_RETURN` at :672 (`NV_ERR_INVALID_STATE` + assert noise) instead of its designed clean `NV_ERR_GPU_IS_LOST` (bounded either way; `kfspSendPacket_GH100:713` discards the return regardless).
4. **C7-e5/e6 scope note**: the only non-MMIO-completing poll in the GSP path — `kgspIssueNotifyOp_GH100`'s sysmem seq poll at `kernel_gsp_gh100.c:1238` (hand-rolled, OSTIMER-bounded ~4s) — is NOT in the design's list of 3 hand-rolled targets; if added, use `NV_ERR_TIMEOUT` and note the sysmem semantics; if not, no action. Verified: `kfspWaitForResponse`'s `==NV_ERR_TIMEOUT` rescue at kern_fsp.c:418 cannot flip a C7-e6 break back to NV_OK (dead head==tail reads FALSE, kern_fsp_gh100.c:219-231).
5. **C7-e3 placement confirmed**: must remain an OR-in to the existing `bFatalError ||` condition at kernel_gsp.c:2813-2814 to preserve the `bPollingForRpcResponse = NV_FALSE` clear at :2820 (verified present). C7-e4's anchor at kernel_gsp.c:315 confirmed.
6. **Test-plan amendment**: dead-bus shutdown (`kgspWaitForProcessorSuspend`, status discarded at kernel_gsp.c:5194) and dead-bus cold-init (`kfspWaitForSecureBoot_GB202` 5s poll) become near-instant; A7 (1200ms) and A12 (3000/2000) interactions are improvements, but apnex.32 live-test latency assertions must expect the new faster bounds — and must NOT expect TIMEOUT log lines from the four accidental-true sites (kern_fsp_gh100.c:1158, kernel_gsp_gb100.c:83, kern_fsp.c:364, kernel_gsp_tu102.c:1155). New early log line expected: `gpuMarkDeviceForReset` from kern_fsp_gb202.c:84 on dead-bus re-open.

Everything else in §3 (e1, e2 placement, e3, e4, e5, e6): **build as specified.**

---

## 4. RESIDUAL RISKS (ranked)

1. **Print-storm class if C7-e7 is dropped** — post-init-loss teardown in the PDB-unset state emits one LEVEL_ERROR + one NV_ASSERT per freed object (rpc.c:11530 path); same netconsole-amplifier class as the A13 live FAIL. Mitigation: e7 is in the build. Residual after e7: low.
2. **Netconsole-amplifier hypothesis still unresolved** (carried from the A13 post-mortem) — the dual-loglevel live test (n≥3, both funnels) remains the gate; this audit does not discharge it.
3. **Accidental-true first-eval residual (by design)** — 4 reachable sites return NV_OK on a dead bus before e2 fires; bounded by the next covered poll, but it is a live-divergence-invisible window of one boot step; documented in e2's claim wording so the live test doesn't misread logs as e2 failure.
4. **Tree-composition / port risk** — audit ran on the apnex-composed tree (C5-v4 guards present); `gpu_timeout.c` and all 25 call sites verified vanilla and the e2 anchor intact, but the C7 patch must be cut against the composed manifest order (e1 → e2..e6 → e7/e8). Per project policy, validation = real `make modules` compile, not `git apply --check`.
5. **Adjacent-family exposure (out of #292 scope, backlog)** — PM-resume-after-loss keys FBSR DESTROY-vs-RESTORE on PDB (`mem_mgr_pwr_mgmt.c:257`): PDB-unset attempts RESTORE and fails bounded/noisy. Not reachable in the #292 window; track as a follow-on, not an apnex.32 blocker.
6. **Caller-count discrepancy in inputs** — two audit streams reported 27 sites; authoritative grep = 25 with full per-site coverage in §1. No uncovered site; risk retired.
