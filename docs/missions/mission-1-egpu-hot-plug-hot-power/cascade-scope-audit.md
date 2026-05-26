# Cascade-scope audit — is the surprise-removal cascade TB-specific or general PCIe?

**Status:** v1 2026-05-26 — Step 1 source audit + Step 2 issue-tracker survey complete.
**Decision input for:** [[decision-architecture-class-localization]] — Option 1 (Core / C-series) vs Option 2 (Addon / E+A series).
**Method:** Per-site caller-chain trace across 13 observed assertion sites in the NVIDIA open-gpu-kernel-modules 595.71.05 tree at `/root/open-gpu-kernel-modules`, plus funnel-reachability audit on the proposed Option 1 guard set, plus targeted issue-tracker survey.

## Executive summary

**13 of 13 audited assertion sites are TRANSPORT-AGNOSTIC.**

Every observed site sits on the universal `nv_pci_remove` → `rm_shutdown_adapter` → `RmShutdownAdapter` → engstate/resserv teardown chain. There are NO `nv->is_external_gpu` gates on any of these paths that would filter out non-TB devices.

The one `is_external_gpu` reference along the teardown chain (`osinit.c:2413`) is **NOT a transport-class gate** — it only selects the lock-acquisition *strategy* (eGPU paths force `serverLockAllClients`; non-eGPU paths trust OS-level client quiescence). The teardown block, including the assertion at `osinit.c:2462`, runs on both paths.

The issue-tracker survey confirms the audit empirically: multiple discrete-PCIe RTX cards (3090, 4090, 5080, 5090-OCuLink) report the same Xid 79 / Xid 154 cascade as our TB-attached 5090, against the same driver branch.

**Recommendation: Option 1 (Core / transport-agnostic).**

Two concrete gaps in the current v1 funnel set were identified that v4 Option 1 implementation must close:
- `_issueRpcAndWaitLarge` (`rpc.c:2071`) lacks the `PDB_PROP_GPU_IS_LOST` short-circuit that `_issueRpcAndWait` has.
- `kern_fsp_gh100.c:649` is a NEW class — arithmetic invariant over two dead-bus reads — that the funnel-1 sentinel value cannot satisfy. Needs site-local handling.

## Per-site classification table

| # | Site | Containing function | Trigger path | `is_external_gpu` gates on path | Classification |
|---|---|---|---|---|---|
| 1 | `kernel_graphics.c:2608` | `kgraphicsFreeGlobalCtxBuffers_IMPL` | engstate `StatePreUnload`/`StateDestroy` → `gpuStatePreUnload` (gpu.c:3638); also MIG enable/disable | NONE | **TRANSPORT-AGNOSTIC** |
| 2 | `fecs_event_list.c:1623` | `fecsBufferDisableHw` (GET-side Control) | engstate `StateDestroy`; client free; FECS error report | NONE | **TRANSPORT-AGNOSTIC** |
| 3 | `fecs_event_list.c:1639` | `fecsBufferDisableHw` (SET-side Control) | Same as #2 | NONE | **TRANSPORT-AGNOSTIC** |
| 4 | `kernel_falcon_tu102.c:187`/195 | `kflcnReset_TU102` | GSP bootstrap (Turing through Blackwell) + teardown (Turing/Ampere/Ada only) | NONE | **TRANSPORT-AGNOSTIC** |
| 5 | `kernel_gsp_tu102.c:636` | `kgspTeardown_TU102` | `gpuStateDestroy` → `kgspUnloadRm` → `kgspTeardown_HAL` | NONE | **TRANSPORT-AGNOSTIC** (not reached on Blackwell — see note) |
| 6 | `vaspace_api.c:573` | `vaspaceapiDestruct_IMPL` | Resserv destructor; reached via free ioctl, fd close, pci_remove, module unload | NONE | **TRANSPORT-AGNOSTIC** |
| 7 | `mem.c:178` | `memDestruct_IMPL` | Resserv destructor; same upstream universe as #6 | NONE | **TRANSPORT-AGNOSTIC** |
| 8 | `rs_server.c:1388` | `serverFreeResourceList` (3rd resserv site) | Every client teardown — userland free, fd close, `pci_remove`, module unload | NONE | **TRANSPORT-AGNOSTIC** |
| 9 | `rs_client.c:855` (v1 site) | `clientFreeResource_IMPL` | Per-resource RPC during destruction; called by #8 + #10 | NONE | **TRANSPORT-AGNOSTIC** |
| 10 | `rs_server.c:272` (v1 site) | `serverFreeResourceTreeUnderLock` | Resserv tree-walk free; same caller universe as #8 | NONE | **TRANSPORT-AGNOSTIC** |
| 11 | `osinit.c:2462` (**NEW**) | `RmShutdownAdapter`, post-`gpuStateDestroy` | `nv_pci_remove` → `rm_shutdown_adapter` → `RmShutdownAdapter` | `is_external_gpu` at 2413 gates *lock strategy*, NOT teardown block | **TRANSPORT-AGNOSTIC** |
| 12 | `kern_fsp_gh100.c:649` (**NEW**) | `_kfspWriteToEmem_GH100`, arithmetic invariant | FSP packet send during init/control; surprise-removal mid-FSP-transaction | NONE | **TRANSPORT-AGNOSTIC** (Blackwell reaches via GB100 HAL fallthrough when MNOC disabled) |
| 13 | `gpu_user_shared_data.c:248` (**NEW**) | `_gpushareddataDestroyGsp` (NV_CHECK_OK on Control RPC) | `memmgrStateDestroy_IMPL` → mem-mgr teardown chain | NONE | **TRANSPORT-AGNOSTIC** (assertion-emitting on checked builds, log-only on release) |

### Notes on individual sites

**Site 5 (`kernel_gsp_tu102.c:636`) — Blackwell HAL dispatch.** This site is in the TU102 HAL implementation of `kgspTeardown`. Per `g_kernel_gsp_nvoc.c:807-826`, Hopper (GH100) and Blackwell (GB10x/GB20x including GB202=5090) dispatch to `kgspTeardown_GH100` instead, which is a thin wrapper that calls `kflcnWaitForHaltRiscv_HAL` and never invokes `kflcnReset`. So this assertion is **not reachable on the 5090 in our test rig** during teardown. It remains a real concern for discrete Turing/Ampere/Ada cards under surprise removal — still transport-agnostic, just for older arch.

**Site 11 (`osinit.c:2462`) — the misleading `is_external_gpu` check.** This is the most important "gotcha" in the audit. The conditional at `osinit.c:2413` reads:
```c
if (!nv->is_external_gpu || serverLockAllClients(&g_resServ) == NV_OK)
```
The comment immediately above says *"LOCK: lock all clients in case of eGPU hot unplug, which will not wait for all existing RM clients to stop using the GPU."* This is easy to misread as "the whole shutdown block is eGPU-gated." It is NOT. The `||` means: on a non-eGPU (discrete RTX 5090, regular PCIe slot), the left-hand `!nv->is_external_gpu` evaluates TRUE and the condition is satisfied without ever calling `serverLockAllClients`. The block proceeds to execute. The assertion at line 2462 fires for discrete-card surprise removal exactly the same as for eGPU.

**Site 12 (`kern_fsp_gh100.c:649`) — Blackwell EMEM path.** Per `g_kern_fsp_nvoc.c:343-356`, `kfspSendPacket` dispatches to `kfspSendPacket_GB100` for Blackwell. However, `kfspSendPacket_GB100` (`kern_fsp_gb100.c:276-295`) only takes the new MNOC mbox path when `PDB_PROP_KFSP_USE_MNOC_CPU` is set; otherwise it tail-calls `kfspSendPacket_GH100`, which calls `_kfspWriteToEmem_GH100` at line 690 → reaches line 649. The property is NOT set by default on consumer Blackwell parts, so 5090 IS reachable.

**Site 13 (`gpu_user_shared_data.c:248`) — `NV_CHECK_OK` is assertion-emitting on checked builds.** `NV_CHECK_OK` (`nvassert.h:746`) expands via `NV_CHECK_OK_OR_ELSE_STR` to call `NV_CHECK_OK_FAILED(level, exprStr, status)` on non-`NV_OK`. On checked builds, this produces an `NV_ASSERT_FAILED_INLINE` stack emit; on release builds it prints at `LEVEL_ERROR`. Either way the path is hit; the noise/severity depends on build configuration.

## Per-cluster narrative

### GR cluster (sites 1-3, 13)

All four sites (kernel_graphics.c:2608, fecs_event_list.c:1623/1639, plus the related gpu_user_shared_data.c:248 mem-mgr piece) reach their assertion via the engstate dispatch chain `gpuStatePreUnload` / `gpuStateDestroy`, which is in turn driven by `nv_pci_remove_helper` (`kernel-open/nvidia/nv-pci.c:2319`) for any PCIe `.remove` callback. That callback is registered universally at `nv-pci.c:2988` — it fires for AER fatal recovery, sysfs unbind, hot-eject, AND Thunderbolt disconnect alike. Additional non-removal routes exist for the FECS sites (MIG enable/disable, client free), all without `is_external_gpu` checks.

### Falcon/GSP cluster (sites 4, 5)

`kflcnReset_TU102` at line 187/195 is reached on **Blackwell 5090** via the GSP-**bootstrap** path (any unplug during init or reload) and on Turing/Ampere/Ada via both bootstrap and teardown. `kgspTeardown_TU102` at line 636 is NOT reached on Blackwell (HAL dispatches to GH100 wrapper) but is fully reachable on Turing/Ampere/Ada discrete cards. Zero `is_external_gpu` gating exists on either call path.

### Mem-mgr cluster (sites 6, 7)

`vaspaceapiDestruct_IMPL` and `memDestruct_IMPL` are Resource Server destructors invoked on every client/device free path: (A) `NV_ESC_RM_FREE` ioctl, (B) `nvidia_close` → `RmFreeUnusedClients`, (C) `nvidia_pci_remove` → `RmShutdownAdapter` → `rmapiShutdown` → `serverFreeDomain`. No transport gating exists anywhere on these chains. The mem.c site additionally requires `IS_GSP_CLIENT || IS_VIRTUAL` which is true for all modern dGPUs under GSP-RM.

### Resserv cluster (sites 8, 9, 10)

Three sites in the generic Resource Server free-tree walk. These are the highest-volume sites on lost-GPU teardown (they fire once per resource being freed). The caller universe is "every client teardown" — userland free, fd close, pci_remove, module unload. Zero transport gating; they are by construction architecture-agnostic library code.

### NEW uncovered sites (11, 12, 13)

The three sites discovered in E07 Run 3 represent three distinct patterns:
- **#11 osinit.c:2462** — generic post-`gpuStateDestroy` NV_ASSERT in `RmShutdownAdapter`. Reached on every device removal.
- **#12 kern_fsp_gh100.c:649** — arithmetic invariant on two register reads (`(ememOffsetEnd - ememOffsetStart) == wordsWritten`). Both reads return `0xFFFFFFFF` on dead bus; the difference is 0 and `wordsWritten > 0`, tripping the assert. This is a NEW pattern class — invariant on dead-bus reads, NOT a status check that can be relaxed via `NV_ASSERT_OR_GPU_LOST`.
- **#13 gpu_user_shared_data.c:248** — Control RPC during mem-mgr destroy. Behaves as assertion (checked) or log (release) depending on build.

None of the three new sites is eGPU-gated. All three reach via `RmShutdownAdapter` or its descendants.

## Funnel reachability audit (Option 1 design completeness)

### Funnel 1: `osDevReadReg{08,16,32}` — C5 v1 ✅ + gap at #12

Confirmed in tree at `src/nvidia/arch/nvalloc/unix/src/os.c:1898-2027`. All three sizes call `osIsGpuBusDead(pGpu)` and short-circuit to `NV_GPU_BUS_DEAD_VALUE_U{8,16,32}` (`0xFF`/`0xFFFF`/`0xFFFFFFFF`). The 32-bit path has post-read detection that sets `PDB_PROP_GPU_IS_LOST` via `gpuSetDisconnectedProperties()` when a read returns all-1s and verification confirms.

**GPU_REG_RD32 routing chain (verified):** `GPU_REG_RD32(g,a)` → `REG_INST_RD32` → `regRead032()` (`gpu_access.c:736`) → `_regRead()` (`gpu_access.c:595`) → `osDevReadReg032(pGpu, pMapping, addr)`. All variants (`_UNCHECKED`, `_EX`) land on `osDevReadReg032`.

**Gap at site 12 (`kern_fsp_gh100.c:649`):** Funnel returns `0xFFFFFFFF`. `_kfspWriteToEmem_GH100` does `DRF_VAL(_PFSP,_EMEMC,_OFFS, 0xFFFFFFFF)` on both reads — bitfield extraction makes both equal, their arithmetic difference is 0, and `wordsWritten > 0`, so the invariant fails. Funnel prevents the PCIe completion-timeout stall but not the assertion firing. **Requires site-local fix** (top-of-function `osIsGpuBusDead` check returning `NV_ERR_GPU_IS_LOST`, OR detect `reg32 == 0xFFFFFFFF` immediately after the first read at line 621).

### Funnel 2: `NV_PRIV_REG_RD{08,16,32}` — no funnel needed

Macro expands inline to `((b)->Reg0NN[(o)/N])` at `src/nvidia/arch/nvalloc/unix/include/nv-priv.h:37-39`. The only direct callers outside `os.c` are intentional — the post-read verification in `osDevReadReg032` itself (recursion-avoidance). No additional funnel layer needed here.

### Funnel 3: `_issueRpcAndWait` — C5 v1 ✅ + gap at large-buffer path

Confirmed in tree at `rpc.c:1854-1859`. Returns `NV_ERR_GPU_IS_LOST` when `PDB_PROP_GPU_IS_LOST` is set, before issuing the RPC.

**Sites covered:** Every site whose path ends in this funnel — sites 2, 3, 6, 7, 8, 9, 10, 11 (indirectly via `gpuStateDestroy`), 13.

**Gap at `_issueRpcAndWaitLarge` (`rpc.c:2258`):** When `total_size > maxRpcSize`, `rpcRmApiControl_GSP` (line 11236) routes to `_issueRpcAndWaitLarge` instead. This wrapper does NOT contain the `PDB_PROP_GPU_IS_LOST` short-circuit. A surprise-removal during a multi-chunk Control RPC bypasses the funnel and hits MMIO-completion-timeout territory with the GPU lock held. **Required addition:** mirror the `_issueRpcAndWait` short-circuit at top of `_issueRpcAndWaitLarge`. Same patch applies to `_issuePteDescRpc` (`rpc.c`, related primitive).

### Funnel 4: `rpcRmApi{Alloc,Control,Free}_GSP` — C5 v1 partial ✅

`rpcRmApiFree_GSP` (`rpc.c:11500-11526`) has its own dedicated guard that returns `NV_OK` (not `NV_ERR_GPU_IS_LOST`) — so resserv cleanup completes its host-side bookkeeping. `rpcRmApiAlloc_GSP` and `rpcRmApiControl_GSP` rely on the downstream `_issueRpcAndWait` guard (NV_ERR_GPU_IS_LOST propagates up). Coverage is asymmetric by design: Free returns OK so cleanup proceeds; Alloc/Control return IS_LOST so callers know.

### Funnel 5: `nvidia_{open,mmap,ioctl}` entry points — NOT needed

Currently no guard at entry. The downstream `NV_ASSERT_OR_GPU_LOST*` relaxations + the `nv->removed` post-dispatch check (nv.c:2101) already cover the userspace-re-entry-after-surprise-removal case. An entry-side guard would be redundant.

### Gap summary — what Option 1 v4 must add beyond C5 v1+v3

| Gap | Where | Fix |
|---|---|---|
| `_issueRpcAndWaitLarge` lacks `PDB_PROP_GPU_IS_LOST` short-circuit | `rpc.c:2071`/`2258` | Add same guard as `_issueRpcAndWait` |
| `kern_fsp_gh100.c:649` arithmetic-invariant pattern | function `_kfspWriteToEmem_GH100` | Top-of-function `osIsGpuBusDead` check returning `NV_ERR_GPU_IS_LOST`; or early-out on first dead-bus read at line 621 |
| Funnel coverage for additional arithmetic-invariant sites (if any) | Sweep needed | grep for similar `NV_ASSERT.*RD32.*==.*RD32` patterns and audit; sweep methodology in v3 missed this class |

## Issue-tracker survey (Step 2)

Survey of `github.com/NVIDIA/open-gpu-kernel-modules` issues for Xid 79 / Xid 154 / "fallen off the bus" on non-TB / non-eGPU systems:

| Issue | Hardware | Transport | Symptom | Driver |
|---|---|---|---|---|
| [#1134](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1134) | RTX 3090 single-GPU desktop | **PCIe x16 (discrete, NOT TB)** | Xid 31 → Xid 154 "Node Reboot Required" under Chromium GPU workload | **nvidia-open 595.71.05** (same as our test rig) |
| [#916](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/916) | Zotac RTX 4090 | PCIe x16 (discrete, NOT TB) | NV_ERR_GPU_IS_LOST + NV_ERR_GPU_IN_FULLCHIP_RESET during CUDA workload | open-driver |
| [#1045](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1045) | RTX 5080 | PCIe x16 (discrete, NOT TB) | Xid 62/45 → Xid 119 → Xid 154 desktop lockup | nvidia-open 590.48.01 |
| [#888](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/888) | unspecified RTX | discrete | "GPU has fallen off the bus" | nvidia-open 570.1169 |
| [#461](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/461) | ARM64 server | discrete | Xid 79 + system crash | open-driver |
| [#776](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/776) | unspecified | desktop | Xid 79 during alt-tab game/KDE | open-driver |
| [#900](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/900) | RTX 5090 | OCuLink (external PCIe, NOT Thunderbolt) | Xid 79 under load | nvidia-open |
| [#974](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/974) | RTX 5060 Ti | Thunderbolt eGPU | Xid 79 init failure | nvidia-open |
| [#979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979) | RTX 5090 (apnex) | Thunderbolt eGPU | Xid 79 + cascade — **our case** | 595.71.05 |

**Empirical finding:** The same Xid 79 / Xid 154 cascade fires on:
- Discrete RTX 3090 / 4090 / 5080 single-GPU desktops (PCIe x16, no external transport at all)
- ARM64 server (discrete)
- OCuLink-attached RTX 5090 (external PCIe but not TB)
- Thunderbolt eGPU 5060 Ti / 5090 (our class)

The failure class is clearly **PCIe surprise removal in general**, not "Thunderbolt cable yank" specifically. Issue #1134 is particularly load-bearing evidence: same driver version (`595.71.05`), discrete RTX 3090 desktop card, same `Xid 154 / Node Reboot Required` marker that fires in our E07 Run 3 forensics. No Thunderbolt anywhere in #1134.

## Recommendation

### Option 1 — Core / C-series (RECOMMENDED)

**The audit is clear: the failure class is transport-agnostic.** Every observed assertion site is reachable on a discrete RTX 5090 in a PCIe x16 slot experiencing AER fatal / hot-eject / signal-integrity link drop. Multiple independent issue reports confirm the cascade fires on non-TB discrete cards in the wild.

Option 2 (eGPU-localized via `is_external_gpu` gates) would:
- Leave discrete-GPU users (Issue #1134, #916, #1045, #888, #461, #776, #900) unfixed
- Diverge from the existing C5 v1 design intent ("a dead bus is a dead bus whether the transport is integrated, discrete-x16, or Thunderbolt")
- Be wrong as a model of the failure class itself

### What Option 1 v4 must do beyond C5 v1+v3

1. **Close `_issueRpcAndWaitLarge` gap** (`rpc.c:2258`) — mirror the `_issueRpcAndWait` short-circuit.
2. **Add site-local fix at `kern_fsp_gh100.c:649`** — arithmetic-invariant pattern that funnel-1 sentinel cannot satisfy.
3. **Address site #11 `osinit.c:2462`** — either convert to `NV_ASSERT_OR_GPU_LOST` accepting the lost-GPU status, OR add early-return on `PDB_PROP_GPU_IS_LOST` at top of `RmShutdownAdapter`'s gpuStateDestroy hunk.
4. **Sweep for additional arithmetic-invariant patterns** — the v3 status-pattern regex missed this class; a new sweep should run against `NV_ASSERT.*GPU_REG_RD` or similar patterns to identify analogous sites.
5. **Retire the per-site coverage discipline as load-bearing** — promote funnel coverage + the few site-local fixes (kfsp arithmetic, osinit assert) to load-bearing; demote per-site `NV_ASSERT_OR_GPU_LOST` conversions to defense-in-depth.

### What Option 1 implementation work looks like

The 5 funnels + 2-3 site-local fixes form a **bounded** completeness proof. No further site iteration needed. The funnel set is:

| Layer | Funnels |
|---|---|
| MMIO read path | `osDevReadReg{08,16,32}` (already done in C5 v1) |
| Single RPC | `_issueRpcAndWait` (already done) |
| Large RPC | `_issueRpcAndWaitLarge` (**NEW for v4**) |
| Free RPC | `rpcRmApiFree_GSP` returning `NV_OK` (already done) |
| Arithmetic invariants on dead-bus reads | `_kfspWriteToEmem_GH100` site-local (**NEW for v4**); sweep for analogous sites |

Plus the existing detection layer (`os.c` post-read check setting both `PDB_PROP_GPU_IS_LOST` and `pci_dev_is_disconnected` via `gpuSetDisconnectedProperties` + `os_pci_set_disconnected`). The detection layer is transport-agnostic and unchanged.

## Confidence + caveats

- **High confidence** on transport-agnostic classification for sites 1, 2, 3, 6, 7, 8, 9, 10, 11, 13 (10 sites). Each has clean caller-chain evidence; multiple sites have empirical issue-tracker corroboration.
- **High confidence** on classification for sites 4, 12 (Blackwell-reachable via specific HAL dispatch verified).
- **Medium confidence** on site 5 — transport-agnostic in the abstract, but not reachable on the 5090 in our test rig due to HAL dispatch. Listed as transport-agnostic because the same code path is fully reachable on discrete Turing/Ampere/Ada cards.
- **Caveat on funnel completeness:** Sweep for arithmetic-invariant patterns has not been exhaustively run. Site #12 was discovered in E07 Run 3 forensics, not by source sweep. Implementation work should include a targeted regex pass for `NV_ASSERT.*GPU_REG_RD` and similar patterns to surface other instances of this class before declaring v4 complete.
- **Caveat on issue tracker survey:** Survey was limited to top-of-search-results issues; deeper grep may surface more cases or counterexamples. None found suggest TB-specificity; all reinforce transport-agnostic class.

## Cross-references

- `experiments/E07-cable-replug-drain-first.md` — Run 3 forensic record (the 3 NEW sites)
- `nvidia-driver-surprise-removal-audit.md` — earlier driver-side attribution work
- `c3-c5-integration-audit.md` — C3+C5 placement audit
- `decision-architecture-class-localization.md` — the binary decision this audit informs
- `session-handover-2026-05-26.md` — overall session state
- Memory: [[feedback_funnel_vs_per_site_patching_2026_05_26]] — architectural-vs-site lesson
- Memory: [[project_issue_979_upstream_state_2026_05_22]] — upstream context

## Status

✅ Step 1 source audit complete.
✅ Step 2 issue-tracker survey complete.
☐ Step 3 (optional) cross-hardware empirical test — not required by audit findings, would corroborate; awaits user direction.
☐ Step 4 — formal Option 1 commitment + v4 implementation plan; queued for next session per user direction ("we'll wait until the audit lands").
