# F1 design — `nvGpuOpsReportFatalError` per-GPU gating (patch C6)

**Status:** v1 2026-05-27 — design ready for Phase 2 implementation; in scope for MISSION-1 v4.
**Patch identity:** C6 (NEW base-layer patch, upstream-bound alongside C1-C5+E1).
**Ordering:** C5 v4 base must land first (C6 calls C5's `cleanupGpuLostStateAtomic` and uses a new `DETECTOR_UVM_FATAL` enum slot). Degraded-mode C6 (no sink call) is a fallback if C5 slips.

## Bug + impact

Issue [#979 jciolek](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979): external RTX 5090 over Thunderbolt falls off the bus → UVM raises `nvGpuOpsReportFatalError(NV_ERR_*)` → the function unconditionally calls `sysSetRecoveryRebootRequired(pSys, NV_TRUE)`. That system-wide flag triggers `_sysRefreshAllGpuRecoveryAction` (`src/nvidia/src/kernel/core/system.c:887`), which walks **every** attached GPU and refreshes its recovery action — including the perfectly healthy internal RTX 3060, on which Xid 154 then fires. One eGPU's surprise-removal cross-contaminates every other GPU in the box. The flag is also visible to userspace clients (NVML / nvidia-smi report "reboot required"), so the cross-contamination is observable, not merely cosmetic.

## Call chain analysis

Top-down, single linear chain:

1. **UVM internal callers** (10 sites) call macro `uvm_global_set_fatal_error(status)` (`kernel-open/nvidia-uvm/uvm_global.h:278`).
   - `uvm_channel.c:2122` — channel-error path, `channel` (→ `uvm_channel_get_gpu(channel)`) in scope.
   - `uvm_gpu.c:1403`, `uvm_gpu.c:2213` — ECC check, `gpu` in scope.
   - `uvm_gpu_semaphore.c:723` — semaphore decrypt failure, semaphore's owning `gpu` in scope.
   - `uvm_turing_fault_buffer.c:423` — fault-buffer parse, `parent_gpu` in scope.
   - `uvm_va_block.c:3689`, `uvm_va_block.c:9308` — CPU decrypt + push tracking, push/block has GPU.
   - `uvm_gpu_non_replayable_faults.c:228` — `parent_gpu` in scope.
   - `uvm_common.h:192` — always-true-assert path; **no GPU in scope** (design constraint accepted).
2. Macro expands to `uvm_global_set_fatal_error_impl(error)` (`uvm_global.c:416`) — **single funnel** for all UVM-side calls. No `gpu` parameter currently.
3. `uvm_global_set_fatal_error_impl` calls `nvUvmInterfaceReportFatalError(error)` (`uvm_global.c:433`).
4. ABI-shim `nvUvmInterfaceReportFatalError` (`kernel-open/nvidia/nv_uvm_interface.c:1577`) calls `rm_gpu_ops_report_fatal_error(sp, error)`.
5. `rm_gpu_ops_report_fatal_error` (`src/nvidia/arch/nvalloc/unix/src/rm-gpu-ops.c:918`) calls `nvGpuOpsReportFatalError(error)`.
6. `nvGpuOpsReportFatalError` (`src/nvidia/src/kernel/rmapi/nv_gpu_ops.c:11678`) sets the global flag.

Header declarations: `kernel-open/common/inc/nv_uvm_interface.h:1606`, `kernel-open/common/inc/rm-gpu-ops.h:108`, `kernel-open/nvidia/nv_gpu_ops.h:313`, `src/nvidia/inc/kernel/rmapi/nv_gpu_ops.h:307`. Linker token: `src/nvidia/exports_link_command.txt:132`.

ABI docstring (`nv_uvm_interface.h:1598-1606`) states the function "can be called from any lock environment, bottom half or non-interrupt context." RM-side entrypoint runs WITHOUT the RM lock held (`NV_ENTER_RM_RUNTIME` is stack-swap only, no `rmapiLockAcquire`).

## Recommended signature

**`(const NvProcessorUuid *uuid, NV_STATUS error)`** for the UVM-RM ABI boundary, with an RM-side wrapper that looks up `OBJGPU *` once at the bottom.

Rationale, comparing three candidates:

- **`OBJGPU *pGpu`** — cleanest internally, but `OBJGPU` is not visible across the `kernel-open` ↔ `src/nvidia` ABI boundary (UVM doesn't include RM headers). Hard rejection.
- **`NvU32 gpuId`** — boundary-clean, but UVM doesn't store the RM-side `gpuId`; it stores `NvProcessorUuid`. UVM would have to add new state or call a new lookup ABI at every fatal-error site. Extra surface.
- **`const NvProcessorUuid *uuid` — chosen.** UVM already has `NvProcessorUuid uuid` in `UvmGpuInfo` (`nv_uvm_types.h:594`); `uvm_parent_gpu_t` retains a copy. No new UVM-side state. RM has `gpumgrGetGpuFromUuid` (`gpu_mgr.c:2420`) ready. This is the existing convention for UVM↔RM identity.

`uvm_global_set_fatal_error_impl`'s signature changes to `(uvm_gpu_t *gpu, NV_STATUS error)` (with `NULL` accepted for the unattributable `uvm_common.h:192` case). The UVM macro at `uvm_global.h:278` grows a `gpu` parameter; 9 of 10 call sites pass GPU, the always-assert site passes `NULL`.

## Function body design (pseudocode)

```c
void nvGpuOpsReportFatalError(const NvProcessorUuid *pGpuUuid, NV_STATUS error)
{
    OBJSYS *pSys = SYS_GET_INSTANCE();
    OBJGPU *pLostGpu = NULL;
    NvU32 gpuMask = 0, gpuCount = 0, gpuInstance = 0;
    NvU32 healthyCount = 0;
    OBJGPU *pGpu;

    NV_ASSERT(error != NV_OK);

    if (pGpuUuid != NULL)
        pLostGpu = gpumgrGetGpuFromUuid(pGpuUuid->uuid,
                                       NV2080_GPU_CMD_GPU_GET_GID_FLAGS_TYPE_SHA1);

    if (pLostGpu != NULL)
    {
        NV_PRINTF(LEVEL_ERROR,
                  "uvm fatal error 0x%x on GPU %u; marking lost\n",
                  error, gpuGetInstance(pLostGpu));

        /* C5 v4 sink primitive — sets PDB_PROP_GPU_IS_LOST and Linux marker */
        cleanupGpuLostStateAtomic(pLostGpu, DETECTOR_UVM_FATAL);
    }
    else
    {
        NV_PRINTF(LEVEL_ERROR,
                  "uvm fatal error 0x%x (originating GPU unknown)\n", error);
    }

    /* Gate the system-wide flag on whether any healthy GPU remains. */
    gpumgrGetGpuAttachInfo(&gpuCount, &gpuMask);
    while ((pGpu = gpumgrGetNextGpu(gpuMask, &gpuInstance)) != NULL)
    {
        if (!pGpu->getProperty(pGpu, PDB_PROP_GPU_IS_LOST))
            healthyCount++;
    }

    if (healthyCount == 0)
    {
        NV_PRINTF(LEVEL_ERROR,
                  "no healthy GPU remains; system reboot required\n");
        sysSetRecoveryRebootRequired(pSys, NV_TRUE);
    }
    else
    {
        NV_PRINTF(LEVEL_NOTICE,
                  "%u healthy GPU(s) remain; suppressing system reboot flag\n",
                  healthyCount);
    }
}
```

Every primitive verified in source: `gpumgrGetGpuFromUuid` (`gpu_mgr.c:2420`), `gpumgrGetGpuAttachInfo` / `gpumgrGetNextGpu` (canonical idiom at `fm_session_api.c:43-72`), `PDB_PROP_GPU_IS_LOST`, `sysSetRecoveryRebootRequired`, `cleanupGpuLostStateAtomic` (v4 sink primitive in C5 — pending land).

## Caller-update list

| File:line | Change | GPU identity available |
|---|---|---|
| `src/nvidia/src/kernel/rmapi/nv_gpu_ops.c:11678` | Body rewrite per pseudocode | n/a (destination) |
| `src/nvidia/inc/kernel/rmapi/nv_gpu_ops.h:307` | Prototype change | n/a |
| `src/nvidia/arch/nvalloc/unix/src/rm-gpu-ops.c:918` | Add `const NvProcessorUuid *uuid` param; pass through | passed by caller |
| `kernel-open/common/inc/rm-gpu-ops.h:108` | Prototype change | n/a |
| `kernel-open/nvidia/nv_gpu_ops.h:313` | Prototype change | n/a |
| `kernel-open/nvidia/nv_uvm_interface.c:1577` | Add `const NvProcessorUuid *uuid` param; pass through | passed by caller |
| `kernel-open/common/inc/nv_uvm_interface.h:1606` | Prototype + docstring update | n/a |
| `kernel-open/nvidia-uvm/uvm_global.h:278` | Macro grows `gpu` param | callers' burden |
| `kernel-open/nvidia-uvm/uvm_global.c:416` | `_impl` takes `uvm_gpu_t *gpu`; pass `&gpu->parent->uuid` (or NULL) | parameter |
| `kernel-open/nvidia-uvm/uvm_channel.c:2122` | Add `uvm_channel_get_gpu(channel)` arg | `channel` |
| `kernel-open/nvidia-uvm/uvm_gpu.c:1403, 2213` | Add `gpu` arg | local `gpu` |
| `kernel-open/nvidia-uvm/uvm_gpu_semaphore.c:723` | Add `semaphore->channel->gpu` (verify accessor) | local `semaphore` |
| `kernel-open/nvidia-uvm/uvm_turing_fault_buffer.c:423` | Add `parent_gpu->gpus[0]` | `parent_gpu` |
| `kernel-open/nvidia-uvm/uvm_va_block.c:3689, 9308` | Add originating gpu from push/block | `push->channel`/`block` |
| `kernel-open/nvidia-uvm/uvm_gpu_non_replayable_faults.c:228` | Add `parent_gpu->gpus[0]` | `parent_gpu` |
| `kernel-open/nvidia-uvm/uvm_common.h:192` | Pass `NULL` | no GPU available — accepted design constraint |
| `src/nvidia/exports_link_command.txt:132` | Symbol unchanged (same name) | n/a |

The `uvm_common.h:192` `NULL` case is handled gracefully by the new body — gate decision still made via gpumgr walk, just without per-GPU sink-marking on that path. Does NOT regress on #979 because the original system-wide-flag behaviour is what we are escaping; the `NULL` branch is equivalent to "we don't know which GPU, so the gate decision rests purely on whether any GPU is already lost."

## Estimated line count

| Component | Lines |
|---|---|
| `nvGpuOpsReportFatalError` body | +25 / −5 |
| `nv_gpu_ops.c` / `nv_gpu_ops.h` / `nv_uvm_interface.h` prototype updates | +3 / 0 |
| `rm-gpu-ops.c` + headers (2 files) | +2 / 0 |
| `nv_uvm_interface.c:1577` shim | +1 / 0 |
| `uvm_global.h:278` macro + `uvm_global.c:416` `_impl` | +4 / −1 |
| UVM call site updates (10 sites) | +10 / 0 |
| **Total** | **+45 / −6 ≈ +39 net** |

**Revision to original estimate:** the +10-15 line estimate was the FUNNEL view (only the function body + 1 shim). Once per-GPU identity is threaded through the macro and 10 UVM call sites, real cost is **+39 net**. Still small for a cross-contamination fix.

## Layering decision

**New patch C6** (NOT a C5 extension). Reasoning:

- C5 owns sink-state primitives and detector classifications; F1 *calls into* C5 (`cleanupGpuLostStateAtomic`, `DETECTOR_UVM_FATAL` enum value) but does not modify them. The caller is in `nv_gpu_ops.c` (RM-API surface), not C5's `osHandleGpuLost`/dead-bus territory.
- F1 touches the UVM ABI boundary (`nv_uvm_interface.h`, 10 UVM call sites). C5 does not currently cross that boundary. Bundling would broaden C5's blast radius unnecessarily.
- F1 is independently bisectable: a reviewer can verify "system-wide flag now gated on per-GPU enumeration" without untangling sink-primitive plumbing.
- Patch geometry per the C/E/A convention: **C6 is base layer (upstream-bound)**, alongside C1-C5 + E1. NVIDIA can accept F1 standalone for cross-GPU isolation even if they reject the more aggressive C-cluster.

**Ordering:** C5 v4 base (sink primitive + `DETECTOR_*` enum + `cleanupGpuLostStateAtomic` exported) MUST land before C6.

C6 adds:
- `DETECTOR_UVM_FATAL` enum extension to C5's enum (one slot)
- Body rewrite + signature change

**Degraded-mode fallback:** if C5 v4 slips, a C6-without-sink-call still fixes #979 jciolek cross-contamination — the GPU's `PDB_PROP_GPU_IS_LOST` would not be set by this path, but the system-wide flag would still be suppressed because the gate walks gpumgr and observes that the OTHER GPUs are healthy. Reduced telemetry/coherence but the cross-contamination fix is preserved.

## Open questions / implementation risks

1. **UVM tarball ABI compatibility.** NVIDIA ships pre-built `nvidia-uvm.ko` for the closed driver, but the open-driver case (which is what we patch) ships UVM-from-source in the same tree. Same-tree-build means both sides of the ABI move together; no shim needed. Confirmed by `EXPORT_SYMBOL(nvUvmInterfaceReportFatalError)` at `nv_uvm_interface.c:1583` — it's an in-tree EXPORT, not a frozen vendor binary contract. **Resolved: no `#ifdef` bridge required.**

2. **gpumgr-walk safety in softirq/bottom-half.** ABI doc allows `nvUvmInterfaceReportFatalError` from bottom-half. `gpumgrGetGpuAttachInfo` reads a static mask and is safe; `gpumgrGetGpuFromUuid` calls `gpuGetGidInfo` → `portMemAllocNonPaged` per GPU. **In tasklet/workqueue (sleepable) this is fine.** In actual softirq context (`in_softirq() = true`), `portMemAllocNonPaged` uses GFP_ATOMIC or equivalent — verify via `port/inc/portMemory.h` actual flags. **Action item for Phase 2 implementation:** add a context-atomic guard; if true, skip the UUID lookup, walk gpumgr only with the property-read (allocation-free), and tolerate the missing per-GPU sink-marking. Practically the only fatal path that fires from softirq is the non-replayable-fault ISR bottom-half (`uvm_gpu_non_replayable_faults.c:228`); other 9 sites are workqueue context.

3. **Backwards compatibility for downstream UVM forks.** Some distros/labs ship modified `nvidia-uvm`. Adding a parameter to `nvUvmInterfaceReportFatalError` is a hard ABI break — but UVM is open-source-in-tree, downstream forks rebuild together. **Acceptable.**

4. **`DETECTOR_UVM_FATAL` enum slot.** Coordinate with C5 v4 enum (currently 7 slots: MMIO_DEAD, OSHANDLEGPULOST_RETRY_EXHAUSTED, GSP_HEARTBEAT_TIMEOUT, AER_FATAL, QWATCHDOG_DMA_WEDGE, PROBE_BAR_FAILURE, SYSFS_DISCONNECTED). F1 adds the 8th. Trivial.

5. **Idempotency.** `cleanupGpuLostStateAtomic` must be idempotent (re-call safe). C5 v4 specifies atomic_cmpxchg-style guarding internally — verify during Phase 2 that re-entry doesn't double-log or double-uevent.

## Cross-references

- [[cascade-class-design-v4]] — v4 architecture C6 plugs into
- [[cascade-scope-audit]] — site audit + issue tracker evidence
- [[decision-architecture-class-localization]] — Option 1 commitment
- Issue [#979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979) — jciolek cross-contamination report

## Status

✅ Call chain mapped
✅ Signature chosen (`const NvProcessorUuid *`)
✅ Function body designed
✅ Caller-update list complete
✅ Line count revised (+39 net)
✅ Layering decided (C6, base, upstream-bound)
✅ Open questions / risks enumerated
☐ Implementation Phase 2 (after C5 v4 base lands)
☐ Soak validation
