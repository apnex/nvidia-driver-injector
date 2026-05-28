# MISSION-1 v4 Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the v4 cascade-class architecture (6 detection inputs → 1 sink primitive → 10 entry-point guards) as a coherent target-state update of each affected fork branch, then deliver via a SINGLE integrated cutover to aorus.17.

**Architecture:** Per [[../missions/mission-1-egpu-hot-plug-hot-power/cascade-class-design-v4]] v1.2. Each fork branch (`c5-crash-safety`, `c4-err-handlers-scaffold`, `a2-bus-loss-watchdog`, `a3-recovery`, `a4-close-path-telemetry`) is amended to its v4 target state, then cascade-rebased and regenerated as a complete `.patch` set. One container build, one cutover. G8 lands with the rest (medium confidence accepted; validation gate is E07 Run 4 + power-off wedge regression tests). C6 (F1) is deferred to Phase 2 (separate plan) due to scope + cross-component coordination + multi-GPU validation gap.

**Tech Stack:** Linux kernel 7.0.x, NVIDIA open-gpu-kernel-modules 595.71.05 (fork at `/root/open-gpu-kernel-modules`), stacked git branches (c1→c2→c3→c4→c5→e1→a1→a2→a3→a4→a5), `tools/regen-base-patches.sh` for .patch regeneration, OCI container build via `Dockerfile`, k3s deployment via `apnex/k8s-vllm` repo. Test rig: AORUS RTX 5090 AI BOX over TB4 → NUC 15 Pro+ (Arrow Lake). Verification is build + smoke + soak + must-gather forensic capture; no automated unit tests.

---

## Conventions / notation

Per [[../missions/mission-1-egpu-hot-plug-hot-power/cascade-class-design-v4]] §"Conventions / notation":
- **C1-C5 + E1** = upstream-bound base patches (C6 deferred to Phase 2)
- **A1-A5** = addon patches (project-local)
- **G1-G10** = entry-point guards
- **`[a]`-`[g]`** = detection inputs (6 classes)
- **DETECTOR_*** = sink primitive's input-class enum
- **aorus.NN** = container image tag (currently soaking on aorus.16; Phase 1 ships aorus.17 as the single cutover)

## File structure

Source files (fork-branch tips, `/root/open-gpu-kernel-modules/`):

| File | Owner patch | Phase 1 change |
|---|---|---|
| `src/nvidia/inc/kernel/gpu/nv-gpu-lost.h` | C5 | Add `nv_gpu_lost_detector_t` enum + `cleanupGpuLostStateAtomic` prototype |
| `src/nvidia/arch/nvalloc/unix/src/os.c` | C5 | Implement `cleanupGpuLostStateAtomic` body; refactor v1 post-read to use it |
| `src/nvidia/arch/nvalloc/unix/src/osinit.c` | C5 | Refactor v3 osHandleGpuLost retry-exhausted hunk to use primitive |
| `kernel-open/nvidia/nv-pci.c` | C5 + C4 | C5: probe-time BAR-failure `[g]`. C4: sink-call insert in existing `nv_pci_error_detected` body |
| `src/nvidia/src/kernel/vgpu/rpc.c` | C5 | G3 `_issueRpcLarge` guard |
| `src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c` | C5 | `[c]` GSP heartbeat detector + G8 `_kgspRpcRecvPoll` pre-loop guard |
| `src/nvidia/src/kernel/diagnostics/journal.c` | C5 | G6 RmLogGpuCrash sink-check |
| `src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c` | C5 | G9 kfsp arithmetic-invariant guard |
| `kernel-open/nvidia/nv.c` | C5 | G7 rm_set_external_kernel_client_count tolerate IS_LOST |
| `kernel-open/nvidia-drm/nvidia-drm-drv.c` | C5 | G10 nv_drm_remove sink-check |
| (multiple — TBD per #776 dmesg) | C5 | G5 rate-limit at noisy API_GPU_ATTACHED_SANITY_CHECK callers |
| (A2 source — locate via patch) | A2 | Q-watchdog routes through sink (semantics change) |
| (A3 source — `tb_egpu_recover_pre_schedule_gates`) | A3 | Sink-query early surrender |
| (A4 source) | A4 | Telemetry consolidation |
| `version.mk` | A5 | Bump to `595.71.05-aorus.17` |

Project files (`/root/nvidia-driver-injector/`):
- `patches/base/C{4,5}-*.patch` and `patches/addon/A{2,3,4,5}-*.patch` — regenerated after fork-branch work
- `docs/patch-intents/C{4,5}-*.md` and `docs/patch-intents/A{2,3,4,5}-*.md` — updated to v4 requirements
- `docs/patches.md` — per-patch canonical reference updated
- `tools/regen-base-patches.sh` — existing tool; produces `.patch` files from fork tips

---

## Phase 1 — Build target-state patches on fork branches (NO deploys)

All work in this phase happens in `/root/open-gpu-kernel-modules` on fork branches. No container builds, no deploys, no reboots. The rig stays running on aorus.16 throughout.

### Task 1A: C5 v4 complete build

**Branch:** `c5-crash-safety`
**Outcome:** sink primitive + 7 new entry-point guards + 4 new detection inputs + telemetry consolidation. ONE patch, internally consistent.

#### Sub-task 1A-1: Sink primitive + DETECTOR enum

- [ ] **Step 1: Read current `nv-gpu-lost.h`**

Run: `cat /root/open-gpu-kernel-modules/src/nvidia/inc/kernel/gpu/nv-gpu-lost.h`
Expected: existing C5 v1+v3 macros + constants.

- [ ] **Step 2: Add detector enum + sink primitive prototype**

Append to `nv-gpu-lost.h` (before include guard close):

```c
typedef enum {
    DETECTOR_MMIO_DEAD                       = 0,
    DETECTOR_OSHANDLEGPULOST_RETRY_EXHAUSTED = 1,
    DETECTOR_GSP_HEARTBEAT_TIMEOUT           = 2,
    DETECTOR_AER_FATAL                       = 3,
    DETECTOR_QWATCHDOG_DMA_WEDGE             = 4,
    DETECTOR_PROBE_BAR_FAILURE               = 5,
    DETECTOR_SYSFS_DISCONNECTED              = 6,
    DETECTOR_UVM_FATAL                       = 7,   /* reserved for Phase 2 C6 */
} nv_gpu_lost_detector_t;

/*
 * Atomic per-GPU sink-state setter. Idempotent; safe from any detection
 * input. Sets PDB_PROP_GPU_IS_LOST (via gpuSetDisconnectedProperties) +
 * pci_dev_is_disconnected (via os_pci_set_disconnected). Emits one
 * NV_GPU_LOST_LOG_ONCE per detector_class per kernel module lifetime.
 */
void cleanupGpuLostStateAtomic(OBJGPU *pGpu, nv_gpu_lost_detector_t detector_class);
```

- [ ] **Step 3: Implement primitive body in `os.c`**

Append to `/root/open-gpu-kernel-modules/src/nvidia/arch/nvalloc/unix/src/os.c`:

```c
void cleanupGpuLostStateAtomic(OBJGPU *pGpu, nv_gpu_lost_detector_t detector_class)
{
    nv_state_t *nv;
    static NvBool s_logged[DETECTOR_UVM_FATAL + 1] = { NV_FALSE };

    if (pGpu == NULL)
        return;

    if (pGpu->getProperty(pGpu, PDB_PROP_GPU_IS_LOST))
        return;  /* idempotent: already lost, no-op */

    gpuSetDisconnectedProperties(pGpu);

    nv = NV_GET_NV_STATE(pGpu);
    if (nv != NULL && nv->handle != NULL)
        os_pci_set_disconnected(nv->handle);

    if (detector_class <= DETECTOR_UVM_FATAL && !s_logged[detector_class])
    {
        s_logged[detector_class] = NV_TRUE;
        NV_PRINTF(LEVEL_ERROR,
                  "GPU %u lost via detector_class=%u\n",
                  gpuGetInstance(pGpu), (unsigned)detector_class);
    }
}
```

- [ ] **Step 4: Compile against current kernel**

Run: `cd /root/open-gpu-kernel-modules && make -j$(nproc) modules SYSSRC=/lib/modules/$(uname -r)/build 2>&1 | tail -10`
Expected: clean build.

- [ ] **Step 5: Refactor v1 post-read check in `os.c` to call the primitive**

Locate the existing post-read confirmation block in `osDevReadReg032`:

```bash
grep -n "gpuSetDisconnectedProperties\|os_pci_set_disconnected" \
    /root/open-gpu-kernel-modules/src/nvidia/arch/nvalloc/unix/src/os.c
```

Replace the two-line pair with:
```c
cleanupGpuLostStateAtomic(pGpu, DETECTOR_MMIO_DEAD);
```

- [ ] **Step 6: Refactor v3 osHandleGpuLost retry-exhausted hunk in `osinit.c`**

Locate the C5 v3 propagation block (pair of `gpuSetDisconnectedProperties` + `os_pci_set_disconnected`) and replace with:
```c
cleanupGpuLostStateAtomic(pGpu, DETECTOR_OSHANDLEGPULOST_RETRY_EXHAUSTED);
```

- [ ] **Step 7: Compile**

Same as Step 4. Verify still clean.

#### Sub-task 1A-2: GSP heartbeat detector `[c]`

- [ ] **Step 1: Locate fatal-timeout classification in `_kgspRpcRecvPoll`**

```bash
grep -n "bIsFatalTimeout\|_kgspClassifyGspTimeout" \
    /root/open-gpu-kernel-modules/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c | head -5
```

- [ ] **Step 2: Insert sink-call in the fatal branch**

Right where `bIsFatalTimeout == NV_TRUE` is decided (around line 2868), before the existing early-return:

```c
if (bIsFatalTimeout)
{
    cleanupGpuLostStateAtomic(pGpu, DETECTOR_GSP_HEARTBEAT_TIMEOUT);
    /* existing early-return follows */
}
```

#### Sub-task 1A-3: Probe-time BAR-failure detector `[g]`

- [ ] **Step 1: Locate `nv_pci_validate_bars` call at probe entry**

```bash
grep -n "nv_pci_validate_bars\|IORESOURCE_UNSET" \
    /root/open-gpu-kernel-modules/kernel-open/nvidia/nv-pci.c | head -5
```

- [ ] **Step 2: Add IORESOURCE_UNSET check at probe entry**

Right after `nv_pci_validate_bars`:

```c
{
    int i;
    for (i = 0; i < NV_GPU_NUM_BARS; i++)
    {
        if (pci_resource_flags(pci_dev, i) & IORESOURCE_UNSET)
        {
            nv_printf(NV_DBG_ERRORS,
                "nvidia: BAR %d not assigned by Linux PCI core "
                "(IORESOURCE_UNSET); refusing to probe further\n", i);
            return -ENODEV;
        }
    }
}
```

(pGpu is not constructed at this point, so sink-primitive call is not applicable here; the return -ENODEV is the actionable behavior. Document this constraint in the intent doc.)

#### Sub-task 1A-4: G3 `_issueRpcAndWaitLarge` guard

- [ ] **Step 1: Locate `_issueRpcLarge` at `rpc.c:2071`**

```bash
sed -n '2060,2090p' /root/open-gpu-kernel-modules/src/nvidia/src/kernel/vgpu/rpc.c
```

- [ ] **Step 2: Mirror G2 guard pattern from `_issueRpcAndWait`**

Add at top of `_issueRpcLarge`:
```c
if (pGpu->getProperty(pGpu, PDB_PROP_GPU_IS_LOST))
{
    NV_GPU_LOST_LOG_ONCE(LEVEL_ERROR,
        "_issueRpcLarge: GPU lost, returning NV_ERR_GPU_IS_LOST without issuing large RPC\n");
    return NV_ERR_GPU_IS_LOST;
}
```

#### Sub-task 1A-5: G5 rate-limit at noisy API_GPU_ATTACHED_SANITY_CHECK callers

- [ ] **Step 1: Identify hot callers from #776 dmesg pattern**

```bash
gh issue view 776 --repo NVIDIA/open-gpu-kernel-modules | \
    grep -A 1 "API_GPU_ATTACHED_SANITY_CHECK\|_threadNodeCheckTimeout" | head -20
```

Expected: function names emerging from the user's stack trace. Map each to source location:

```bash
grep -rn "API_GPU_ATTACHED_SANITY_CHECK" /root/open-gpu-kernel-modules/src/ | head -20
```

- [ ] **Step 2: For each of the top 3-5 hottest callers (per #776 dmesg), wrap the LEVEL_ERROR print with NV_GPU_LOST_LOG_ONCE**

Pattern at each call site:
```c
if (!API_GPU_ATTACHED_SANITY_CHECK(pGpu))
{
    NV_GPU_LOST_LOG_ONCE(LEVEL_ERROR,
        "<function>: API_GPU_ATTACHED_SANITY_CHECK failed\n");
    return /* appropriate error */;
}
```

(The existing macro evaluation already short-circuits once sink is set via `PDB_PROP_GPU_IS_CONNECTED` being cleared. Only the LOG_ONCE wrap is new.)

#### Sub-task 1A-6: G6 RmLogGpuCrash sink-check (extension of existing rcdbAddRmGpuDump)

- [ ] **Step 1: Locate RmLogGpuCrash**

```bash
grep -rn "RmLogGpuCrash\|rcdbAddRmGpuDump" \
    /root/open-gpu-kernel-modules/src/nvidia/src/kernel/diagnostics/journal.c | head -10
```

- [ ] **Step 2: Add sink-check at RmLogGpuCrash entry (mirror C5 v1 rcdbAddRmGpuDump pattern)**

```c
NV_STATUS RmLogGpuCrash(...)
{
    if (pGpu != NULL && osIsGpuBusDead(pGpu))
    {
        NV_GPU_LOST_LOG_ONCE(LEVEL_ERROR,
            "RmLogGpuCrash: GPU lost, skipping crash log\n");
        return NV_OK;  /* cleanup proceeds without diagnostic RPC */
    }
    /* existing body */
}
```

#### Sub-task 1A-7: G7 rm_set_external_kernel_client_count tolerate IS_LOST

- [ ] **Step 1: Locate WARN_ON at `nv.c:5445` (or nearby line in current tree)**

```bash
grep -n "rm_set_external_kernel_client_count\|nvidia_dev_put" \
    /root/open-gpu-kernel-modules/kernel-open/nvidia/nv.c | head -10
```

- [ ] **Step 2: Replace WARN_ON pattern with IS_LOST tolerance**

```c
NV_STATUS s = rm_set_external_kernel_client_count(...);
if (s != NV_OK && s != NV_ERR_GPU_IS_LOST)
    WARN_ON(1);
/* IS_LOST is silent — sink-state already logged it elsewhere */
```

#### Sub-task 1A-8: G8 chip-reset RPC lock-hold guard (medium-confidence; validation gate is E07 Run 4)

- [ ] **Step 1: Locate `_kgspRpcRecvPoll` at `kernel_gsp.c:2787` (pre-loop)**

```bash
sed -n '2780,2810p' /root/open-gpu-kernel-modules/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c
```

- [ ] **Step 2: Hoist sanity check before the for-loop**

After lock-owner assertion, before the `for(;;)` loop entry:

```c
/* G8 v4: pre-loop check. If GSP is in bFatalError or GPU is known dead,
 * return immediately. Avoids 75s lock-hold storms under ioctl-storm after
 * Xid 154 (#1134 wedge class). */
if (pKernelGsp->bFatalError || osIsGpuBusDead(pGpu))
{
    NV_GPU_LOST_LOG_ONCE(LEVEL_ERROR,
        "_kgspRpcRecvPoll: pre-loop short-circuit on bFatalError/sink-set, "
        "returning NV_ERR_RESET_REQUIRED without polling\n");
    return NV_ERR_RESET_REQUIRED;
}
```

#### Sub-task 1A-9: G9 kfsp arithmetic-invariant guard

- [ ] **Step 1: Locate `_kfspWriteToEmem_GH100` at `kern_fsp_gh100.c:621-649`**

```bash
sed -n '610,660p' /root/open-gpu-kernel-modules/src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c
```

- [ ] **Step 2: Add early-return on dead-bus first-read at line 621**

After the first `GPU_REG_RD32(pGpu, NV_PFSP_EMEMC(...))`, if the value is the dead-bus sentinel:

```c
reg32 = GPU_REG_RD32(pGpu, NV_PFSP_EMEMC(FSP_EMEM_CHANNEL_RM));
if (reg32 == 0xFFFFFFFF && osIsGpuBusDead(pGpu))
{
    NV_GPU_LOST_LOG_ONCE(LEVEL_ERROR,
        "_kfspWriteToEmem_GH100: dead-bus read; aborting EMEM write\n");
    return NV_ERR_GPU_IS_LOST;
}
ememOffsetStart = DRF_VAL(_PFSP, _EMEMC, _OFFS, reg32);
```

#### Sub-task 1A-10: G10 DRM teardown guard

- [ ] **Step 1: Locate `nv_drm_remove` at `nvidia-drm-drv.c:2187`**

```bash
sed -n '2180,2210p' /root/open-gpu-kernel-modules/kernel-open/nvidia-drm/nvidia-drm-drv.c
```

- [ ] **Step 2: Add sink-check at entry, before hardware-touching teardown**

```c
void nv_drm_remove(NvU32 gpuId)
{
    /* G10 v4: if sink is set, skip hardware-touching teardown.
     * Linux DRM core frees resources regardless. Prevents the #1134
     * nvidia_drm teardown hang. */
    nv_state_t *nv = nv_get_adapter_state(gpuId);
    if (nv != NULL)
    {
        OBJGPU *pGpu = NV_GET_NV_PRIV_PGPU(nv);
        if (pGpu != NULL && osIsGpuBusDead(pGpu))
        {
            nv_drm_log(NV_DRM_LOG_INFO,
                "nv_drm_remove: skipping hardware teardown on lost GPU %u\n",
                gpuId);
            return;
        }
    }
    /* existing body */
}
```

(KMS resource-release paths may need similar guards; identify via grep during implementation.)

#### Sub-task 1A-11: Telemetry consolidation — retire per-site NV_GPU_LOST_LOG_ONCE latches

- [ ] **Step 1: Audit existing per-site latches**

```bash
grep -rn "NV_GPU_LOST_LOG_ONCE" /root/open-gpu-kernel-modules/
```
Expected: ~10 hits from v1 + v3 sites.

- [ ] **Step 2: For each site downstream of a v4 funnel (the 8 v3 site conversions + 2 v1 resserv sites), remove the LOG_ONCE call**

The canonical sink-side log replaces them. Keep AT MOST 2 canonical site-level logs (e.g., at rs_client.c and rs_server.c) as defense-in-depth.

#### Sub-task 1A-12: Compile + intent doc update

- [ ] **Step 1: Full module rebuild**

```bash
cd /root/open-gpu-kernel-modules && make -j$(nproc) modules SYSSRC=/lib/modules/$(uname -r)/build 2>&1 | tail -10
```
Expected: clean build.

- [ ] **Step 2: Update `docs/patch-intents/C5-crash-safety.md`**

Bump frontmatter `status:` to `v4-target-ready`. Add Requirements + Scenarios for:
- Sink primitive `cleanupGpuLostStateAtomic`
- 4 new detection inputs ([c], [d already in C4], [f via A2], [g])
- 7 new guards (G3, G5, G6, G7, G8, G9, G10)
- Telemetry consolidation

Match the per-Requirement Given/When/Then style from C5 v3.

- [ ] **Step 3: Commit C5 v4 on fork branch as ONE coherent commit**

Squash intermediate work commits into a single coherent commit:

```bash
cd /root/open-gpu-kernel-modules
git checkout c5-crash-safety
# Optional: squash sub-task working commits if multiple
git reset --soft <pre-v4-base-commit>
git add -A
git commit -m "C5 v4: sink primitive + 4 detectors + 7 guards + telemetry consolidation

Implements MISSION-1 v4 architecture per
docs/missions/mission-1-egpu-hot-plug-hot-power/cascade-class-design-v4.md
(v1.2).

- cleanupGpuLostStateAtomic primitive consolidates dual-marker write
- DETECTOR_* enum classifies detection input by class for telemetry
- Detectors: GSP heartbeat timeout, probe-time BAR failure
  (AER and Q-watchdog feed sink via C4 and A2 respectively)
- Guards: G3 _issueRpcAndWaitLarge, G5 API_GPU_ATTACHED_SANITY_CHECK
  rate-limit, G6 RmLogGpuCrash, G7 rm_set_external_kernel_client_count,
  G8 _kgspRpcRecvPoll pre-loop, G9 kfsp arithmetic-invariant, G10
  nv_drm_remove
- Per-site log latches retired in favor of canonical sink-side logs

Related: GitHub issues #461, #776, #888, #900, #916, #974, #979,
#1045, #1134."
```

### Task 1B: C4 v4 — sink-call insertion ABSORBED INTO C5

**EXECUTION DEVIATION 2026-05-27:** The original plan put the +1 line into a separate `c4-err-handlers-scaffold` commit. This is a **branch-ordering violation**: C4 is upstream of C5 in the stack, so a call from C4 to a function defined in C5 leaves C4-tip alone broken (call without definition) — breaks bisection + upstream-PR piecewise acceptance. **Fix:** absorb the +1 line into C5's diff to `nv-pci.c`. C4 stays unchanged; the AER callback gains its sink-call via a C5 hunk on top of C4's existing scaffold body. Layering preserved.

Task 1B (as a separate task) is therefore SKIPPED — see Task 1A's expanded scope which now includes the AER body edit.

**Aggregate delta correction:** C4 = 0 lines (was +1); C5 absorbs the +1 line into its existing +26-28 range. No net change to aggregate.

---

### Task 1B (ORIGINAL — kept for reference; absorbed into 1A above)

**Branch:** `c4-err-handlers-scaffold`
**Outcome:** existing `nv_pci_error_detected` callback gains one `cleanupGpuLostStateAtomic` call on the DISCONNECT branch.

- [ ] **Step 1: Locate the `default: PCI_ERS_RESULT_DISCONNECT` branch in `nv_pci_error_detected`**

```bash
sed -n '2860,2930p' /root/open-gpu-kernel-modules/kernel-open/nvidia/nv-pci.c
```

- [ ] **Step 2: Add sink-call inside the default branch**

```c
default:
    if (nvl != NULL)
    {
        OBJGPU *pGpu = NV_GET_NV_PRIV_PGPU(NV_STATE_PTR(nvl));
        if (pGpu != NULL)
            cleanupGpuLostStateAtomic(pGpu, DETECTOR_AER_FATAL);
    }
    result = PCI_ERS_RESULT_DISCONNECT;
    result_str = "DISCONNECT";
    break;
```

- [ ] **Step 3: Compile**

- [ ] **Step 4: Update `docs/patch-intents/C4-err-handlers-scaffold.md`**

Bump status to `v4-target-ready`. Add Requirement: "Driver SHALL call sink primitive on AER DISCONNECT branch."

- [ ] **Step 5: Commit on c4-err-handlers-scaffold**

```bash
git checkout c4-err-handlers-scaffold
git add kernel-open/nvidia/nv-pci.c
git commit -m "C4 v4: route AER error_detected DISCONNECT branch through cleanupGpuLostStateAtomic"
```

### Task 1C: A2 v4 — Q-watchdog routes through sink (SEMANTICS CHANGE)

**Branch:** `a2-bus-loss-watchdog`
**Outcome:** Q-watchdog detection sets BOTH RM and Linux markers (was: Linux only).

- [ ] **Step 1: Locate A2's current `os_pci_set_disconnected` call**

```bash
grep -rn "os_pci_set_disconnected" /root/open-gpu-kernel-modules/kernel-open/ | head
```

- [ ] **Step 2: Replace with sink primitive call**

```c
/* A2 v4 (SEMANTICS CHANGE): route through sink primitive. This now sets
 * BOTH PDB_PROP_GPU_IS_LOST (RM marker) AND pci_dev_is_disconnected
 * (Linux marker). Previously set Linux marker only. */
cleanupGpuLostStateAtomic(pGpu, DETECTOR_QWATCHDOG_DMA_WEDGE);
```

(May require a `pGpu` lookup if not in scope at the kthread callsite; pattern after existing C4/G10 patterns.)

- [ ] **Step 3: Compile**

- [ ] **Step 4: Update `docs/patch-intents/A2-bus-loss-watchdog.md`**

Bump status to `v4-target-ready`. Add Requirement noting the semantics change. Add Scenario covering the case where downstream UVM consumers observe RM-marker set in addition to Linux marker.

- [ ] **Step 5: Commit on a2-bus-loss-watchdog**

```bash
git checkout a2-bus-loss-watchdog
git add <file>
git commit -m "A2 v4: Q-watchdog routes through cleanupGpuLostStateAtomic

SEMANTICS CHANGE: A2's detector previously set only the Linux-side marker
(os_pci_set_disconnected). Routing through the unified sink primitive now
ALSO sets the RM-side marker (PDB_PROP_GPU_IS_LOST). This makes detection
coherent across markers but may perturb UVM-side state machines that
previously observed only the Linux marker. Validation: Phase 4 E07 Run 4
+ 7-day production soak."
```

### Task 1D: A3 v4 — sink-query early surrender

**Branch:** `a3-recovery`
**Outcome:** A3's recovery flow short-circuits when sink is already set; saves retry-budget.

- [ ] **Step 1: Locate `tb_egpu_recover_pre_schedule_gates`**

```bash
grep -rn "tb_egpu_recover_pre_schedule_gates" /root/open-gpu-kernel-modules/ | head -5
```

- [ ] **Step 2: Add sink-query at function entry (immediately after argument validation)**

```c
enum tb_egpu_recover_gate
tb_egpu_recover_pre_schedule_gates(struct tb_egpu_recover_state *st,
                                   struct pci_dev *pci_dev,
                                   const char **reason)
{
    /* A3 v4: if v4 sink primitive has already declared the GPU lost,
     * surrender immediately without consuming retry budget. */
    {
        nv_linux_state_t *nvl = pci_get_drvdata(pci_dev);
        OBJGPU *pGpu = (nvl != NULL) ?
            NV_GET_NV_PRIV_PGPU(NV_STATE_PTR(nvl)) : NULL;
        if (pGpu != NULL && osIsGpuBusDead(pGpu))
        {
            *reason = "sink-set: GPU already declared lost";
            return TB_EGPU_RECOVER_GATE_SURRENDER;
        }
    }
    /* existing body */
}
```

- [ ] **Step 3: Compile**

- [ ] **Step 4: Update `docs/patch-intents/A3-recovery.md`**

Add Requirement: "A3 SHALL query sink primitive at pre_schedule_gates entry; surrender if already set."

- [ ] **Step 5: Commit on a3-recovery**

### Task 1E: A4 v4 — telemetry consolidation

**Branch:** `a4-close-path-telemetry`
**Outcome:** A4 observes canonical sink-side log instead of scattered per-site logs.

- [ ] **Step 1: Audit A4's current observation hooks**

```bash
cat /root/nvidia-driver-injector/patches/addon/A4-close-path-telemetry.patch | grep -A 2 "^+.*\(NV_PRINTF\|NV_GPU_LOST_LOG_ONCE\)"
```

- [ ] **Step 2: Consolidate to single canonical observation point**

Wherever A4 emits a "GPU lost via XXX" diagnostic, route through the sink-side log primitive instead. Specific refactor depends on A4's current shape; see existing patch for context.

- [ ] **Step 3: Compile**

- [ ] **Step 4: Update `docs/patch-intents/A4-close-path-telemetry.md`**

- [ ] **Step 5: Commit on a4-close-path-telemetry**

---

## Phase 2 — Cascade rebases + patch regeneration + version bump

**Outcome:** All fork branches updated to v4 target state; `.patch` files regenerated; A5 version bumped to aorus.17. Ready for container build.

### Task 2A: Cascade-rebase the stacked branches

**Pattern:** branch stack is c1→c2→c3→c4→c5→e1→a1→a2→a3→a4→a5. Phase 1 modified c4, c5, a2, a3, a4. Each modified branch needs its downstream branches rebased onto its new tip.

- [ ] **Step 1: Rebase e1 atop new c5 tip**

```bash
cd /root/open-gpu-kernel-modules
git checkout e1-egpu-detection
git rebase c5-crash-safety
```

- [ ] **Step 2: Rebase a1 atop new e1 tip**

```bash
git checkout a1-pcie-primitives
git rebase e1-egpu-detection
```

- [ ] **Step 3: Rebase a2 atop new a1 tip — A2 already has v4 commit on top, ensure ordering correct**

```bash
git checkout a2-bus-loss-watchdog
git rebase a1-pcie-primitives
```

- [ ] **Step 4: Rebase a3 atop new a2 tip**

```bash
git checkout a3-recovery
git rebase a2-bus-loss-watchdog
```

- [ ] **Step 5: Rebase a4 atop new a3 tip**

```bash
git checkout a4-close-path-telemetry
git rebase a3-recovery
```

- [ ] **Step 6: Rebase a5 atop new a4 tip**

```bash
git checkout a5-version-and-toggles
git rebase a4-close-path-telemetry
```

- [ ] **Step 7: Compile a5 tip to verify the stack is consistent**

```bash
make -j$(nproc) modules SYSSRC=/lib/modules/$(uname -r)/build 2>&1 | tail -5
```
Expected: clean.

### Task 2B: Bump A5 version to aorus.17

- [ ] **Step 1: Edit version.mk on a5-version-and-toggles**

```bash
git checkout a5-version-and-toggles
sed -i 's/aorus\.16/aorus.17/g' version.mk
git add version.mk
git commit --amend --no-edit  # fold into a5's existing commit
```

(Or `git commit` as a new commit if A5's history is multi-commit; project pattern is single coherent commit per addon.)

### Task 2C: Regenerate `.patch` files

```bash
cd /root/nvidia-driver-injector
./tools/regen-base-patches.sh
git diff --stat patches/
```
Expected: non-trivial diff across C4, C5, A2, A3, A4, A5 `.patch` files.

### Task 2D: Force-push fork branches per carve-out

Per `feedback_force_push_fork_carve_out`: lease-push acceptable when cascade rebase requires it AND user has confirmed (this plan is the confirmation).

- [ ] **Step 1: Lease-push each rebased fork branch**

```bash
cd /root/open-gpu-kernel-modules
for branch in c4-err-handlers-scaffold c5-crash-safety e1-egpu-detection \
              a1-pcie-primitives a2-bus-loss-watchdog a3-recovery \
              a4-close-path-telemetry a5-version-and-toggles; do
    git push origin "$branch" --force-with-lease
done
```

- [ ] **Step 2: Verify origin tips match local**

```bash
for branch in c4-err-handlers-scaffold c5-crash-safety e1-egpu-detection \
              a1-pcie-primitives a2-bus-loss-watchdog a3-recovery \
              a4-close-path-telemetry a5-version-and-toggles; do
    echo "$branch: $(git rev-parse $branch) vs origin: $(git rev-parse origin/$branch)"
done
```
Expected: pairs match.

### Task 2E: Commit Phase 1 + 2 state in injector repo

- [ ] **Step 1: Stage updated patches + intent docs**

```bash
cd /root/nvidia-driver-injector
git add patches/base/C{4,5}-*.patch patches/addon/A{2,3,4,5}-*.patch \
        docs/patch-intents/C{4,5}-*.md docs/patch-intents/A{2,3,4,5}-*.md \
        docs/patches.md
```

- [ ] **Step 2: Single commit with comprehensive message**

```bash
git commit -m "patches: v4 base architecture — aorus.17

C5 v4 (load-bearing):
- cleanupGpuLostStateAtomic sink primitive + DETECTOR_* enum
- 4 detectors (MMIO existing, GSP heartbeat NEW, probe-BAR NEW; AER via C4; Q-watchdog via A2)
- 7 guards added (G3, G5, G6, G7, G8, G9, G10)
- Telemetry consolidation: per-site log latches retired

C4 v4: sink-call insertion in existing AER DISCONNECT branch.

A2 v4: Q-watchdog routes through sink (SEMANTICS CHANGE: now sets RM marker too).

A3 v4: sink-query early-surrender in pre_schedule_gates.

A4 v4: telemetry consolidation to canonical sink log.

A5: version -> aorus.17.

Architecture: docs/missions/mission-1-egpu-hot-plug-hot-power/cascade-class-design-v4.md (v1.2).
Phase 2 deferred: C6 (F1) uvm-global escalation gating.

Related issues: #461, #776, #888, #900, #916, #974, #979, #1045, #1134."
```

- [ ] **Step 3: Push to origin/main**

```bash
git push origin main
```

---

## Phase 3 — Single integrated cutover (aorus.17)

**Outcome:** patched 595.71.05-aorus.17 driver running on the rig. ONE deploy.

### Task 3A: Build container

- [ ] **Step 1: Build**

```bash
cd /root/nvidia-driver-injector
docker build -t apnex/nvidia-driver-injector:595.71.05-aorus.17 . 2>&1 | tail -20
```
Expected: successful build, image present.

- [ ] **Step 2: Import to k3s containerd**

```bash
docker save apnex/nvidia-driver-injector:595.71.05-aorus.17 | \
    sudo k3s ctr -n=k8s.io images import -
```

### Task 3B: Update k8s deployment

- [ ] **Step 1: Bump DaemonSet image tag in k8s-vllm repo**

```bash
cd /root/k8s-vllm
sed -i 's|aorus\.16|aorus.17|g' k8s/nvidia-driver-injector/daemonset.yaml
git add k8s/nvidia-driver-injector/daemonset.yaml
git commit -m "k8s: bump nvidia-driver-injector to aorus.17"
git push origin main
```

- [ ] **Step 2: Apply + force pod roll**

```bash
kubectl apply -f k8s/nvidia-driver-injector/daemonset.yaml
kubectl delete pod -n kube-system -l name=nvidia-driver-injector
```

### Task 3C: Reboot to load new module

- [ ] **Step 1: Reboot host**

The .16 module is loaded in kernel; reboot is needed to load .17 cleanly.

```bash
sudo reboot
```

### Task 3D: Post-reboot smoke test

- [ ] **Step 1: Verify driver version**

```bash
cat /sys/module/nvidia/version
```
Expected: `595.71.05-aorus.17`.

- [ ] **Step 2: Verify pods**

```bash
kubectl get pods -n kube-system | grep nvidia
```
Expected: nvidia-driver-injector + nvidia-device-plugin both 1/1.

- [ ] **Step 3: Verify PCIe state**

```bash
/root/nvidia-driver-injector/tools/get-pci-stats.sh
```
Expected: BAR1 32GiB, prefetchable window healthy, link state Gen3 (or per current cmdline).

- [ ] **Step 4: Verify zero detector fires under healthy operation**

```bash
dmesg | grep "lost via detector_class"
```
Expected: zero lines.

- [ ] **Step 5: Verify vLLM workload starts**

```bash
kubectl get pods -n vllm
kubectl logs -n vllm <pod> | tail -20
```
Expected: vLLM pod running, model loaded, requests served.

---

## Phase 4 — Validation (regression tests + soak)

**Outcome:** v4 demonstrably handles the failure modes v3 didn't. Forensic artifacts captured for upstream PR evidence + v4 confidence baseline.

### Task 4A: E07 Run 4 — cable-yank regression test

- [ ] **Step 1: Pre-test forensic snapshot**

```bash
/root/nvidia-driver-injector/tools/must-gather.sh > \
    /var/log/mission-1-archaeology/E07-Run4-aorus17-pre.tar.gz
```

- [ ] **Step 2: Trigger cable yank while vLLM is mid-inference**

Per E07 protocol in `docs/missions/.../experiments/E07-cable-replug-drain-first.md`.

- [ ] **Step 3: Observe host behavior**

Expected:
- ONE canonical "GPU lost via detector_class=X" line in dmesg (not multiple)
- Cleanup completes within seconds (not minutes)
- `nvidia_drm` teardown does NOT hang
- Host remains responsive; SSH still works
- `systemctl reboot` would succeed (test without actually rebooting)
- No 75s lock-hold stall

- [ ] **Step 4: Post-test forensic snapshot**

```bash
/root/nvidia-driver-injector/tools/must-gather.sh > \
    /var/log/mission-1-archaeology/E07-Run4-aorus17-post.tar.gz
```

- [ ] **Step 5: Document result in experiments/E07-cable-replug-drain-first.md**

Add "Run 4 (aorus.17)" section. PASS/FAIL with key forensic excerpts.

### Task 4B: Power-off wedge regression test

- [ ] **Step 1: Pre-test snapshot**

- [ ] **Step 2: Power off AORUS AI BOX via its switch during vLLM workload**

- [ ] **Step 3: Observe**

Expected: detector input from MMIO/heartbeat/Q-watchdog; cleanup; host survives.

- [ ] **Step 4: Post-test snapshot + document**

New experiment file: `docs/missions/.../experiments/power-off-wedge-Run-1.md`.

### Task 4C: 7-day production soak

- [ ] **Step 1: Run normal vLLM production workload for 7 days**

- [ ] **Step 2: 4-hour interval get-pci-stats snapshots**

```bash
while sleep 14400; do
    /root/nvidia-driver-injector/tools/get-pci-stats.sh > \
        /var/log/mission-1-archaeology/phase-4-soak-$(date +%Y%m%d-%H%M%S).log
done &
```

- [ ] **Step 3: Daily dmesg checks**

```bash
dmesg | grep -E "lost via detector_class|Xid|NV_ERR" | tail -10
```
Expected: zero detector fires under healthy operation; no new Xids.

- [ ] **Step 4: 7-day snapshot**

```bash
/root/nvidia-driver-injector/tools/must-gather.sh > \
    /var/log/mission-1-archaeology/phase-4-soak-7d-final.tar.gz
```

---

## Phase 5 — Phase 1 exit gate

Phase 1 is COMPLETE when:
- [ ] Task 4A E07 Run 4: PASS (host survives cable yank; no nvidia_drm teardown hang; ≤ one detector fire per yank event)
- [ ] Task 4B power-off wedge: PASS (host survives external enclosure power-off)
- [ ] Task 4C 7-day soak: clean (zero spurious detector fires; no new error categories)
- [ ] No regression in vLLM workload (throughput + latency within ±5% of aorus.16 baseline)
- [ ] All intent docs updated to status:reviewed
- [ ] All fork branches pushed to origin

If any criterion fails: root-cause via must-gather, fix on appropriate fork branch, regen, build aorus.17.1, redeploy, re-validate.

Phase 1 exit gate met → Phase 2 plan (`2026-MM-DD-mission-1-v4-phase-2.md`) covers:
- C6 (F1) — `nvGpuOpsReportFatalError` per-GPU gating
- v3 site revertability assessment (potentially −80 lines)
- Optional cross-hardware empirical test on non-TB Blackwell
- Upstream PR preparation (C1-C6 + E1)

---

## Risks + rollback

**Rollback unit:** aorus.17 → aorus.16. Single command:

```bash
cd /root/k8s-vllm
git revert <aorus.17 bump commit>
kubectl apply -f k8s/nvidia-driver-injector/daemonset.yaml
sudo reboot
```

**Detected regression triggers immediate rollback:**
- vLLM workload latency/throughput degrades > 5% from aorus.16 baseline
- New Xid messages under healthy operation
- Spurious detector fires under normal load
- Module load failures
- `must-gather` shows new error categories

**Known risks:**
1. **A2 semantics change** (Q-watchdog now sets RM marker). Could perturb UVM consumers; soak monitor for new UVM-related dmesg.
2. **G8 MEDIUM confidence**. If hypothesis is wrong, G8 doesn't fix #1134's 75s lock-hold class. E07 Run 4 (Phase 4) is the validation gate. If E07 Run 4 shows lock-hold cascade STILL present, G8 design needs revision (Placement B fallback or new investigation) in a follow-on sub-cycle.
3. **G5 rate-limiting** could hide a legitimate log under normal load. Mitigate: soak-monitor for "missing" expected log lines.
4. **Retired per-site latches** could hide debug info if a future failure occurs at those sites. Mitigate: keep at least one canonical NV_GPU_LOST_LOG_ONCE at resserv level.
5. **Cascade rebase conflicts** during Phase 2A. Mitigate: each branch rebase compiles + tests cleanly before pushing.

## Cross-references

- [[../missions/mission-1-egpu-hot-plug-hot-power/cascade-class-design-v4]] — v1.2 architecture
- [[../missions/mission-1-egpu-hot-plug-hot-power/cascade-scope-audit]] — site + issue evidence
- [[../missions/mission-1-egpu-hot-plug-hot-power/decision-architecture-class-localization]] — Option 1 commitment
- [[../missions/mission-1-egpu-hot-plug-hot-power/f1-uvm-fatal-error-gating-design]] — C6 (deferred to Phase 2)
- `docs/upstream-plan.md` — C/E/A patch geometry + upstream filing strategy
- `docs/patches.md` — per-patch canonical reference
- `tools/regen-base-patches.sh` — patch regeneration mechanic
- `tools/must-gather.sh`, `tools/get-pci-stats.sh` — forensic capture
- Memories: `project_addon_recarve_merged_2026_05_22`, `project_sub_cycle_4_paired_cascade_2026_05_24`, `feedback_force_push_fork_carve_out`, `feedback_propose_options_dont_ask_blind`

## Scope clarification — hot-unplug vs hot-replug vs application-transparent reattach

Phase 1 explicitly addresses **hot-unplug survival**: when the GPU disappears (cable yank, power-off, sysfs unbind), the host stays alive, cleanup completes, no nvidia_drm hang, no 75s lock-hold cascade. This is what the validation gates (Task 4A E07 Run 4, Task 4B power-off wedge) test.

Phase 1 also delivers basic **hot-replug enumeration**: when the GPU reappears, Linux PCI re-enumeration creates a fresh `OBJGPU` via standard `.probe`. The probe-time BAR-failure detector `[g]` rejects probe cleanly if BAR allocation didn't work.

Phase 1 does NOT deliver **application-transparent reattach**: the original `pGpu` is lost with sink-set; the new probe creates a new GPU instance; applications holding device handles must release + reacquire. Acceptable workflow under v4: unplug → host stays healthy → replug → fresh OBJGPU via probe → workload pod restart (e.g., `kubectl rollout restart`) acquires the new GPU. Application-transparent reattach (sink-clear + in-place re-init + in-flight workload migration) is a LATER PHASE design problem, not in Phase 1 or Phase 2 scope.

## Phase 2 preview (separate plan, to follow Phase 1)

Phase 2 will cover:
- C6 (F1) per `f1-uvm-fatal-error-gating-design.md` — `nvGpuOpsReportFatalError` per-GPU gating (+39 lines, ordered after Phase 1 confirmed stable)
- Revertability assessment of v3 site conversions — potentially −80 lines if all 8 revert
- Optional cross-hardware empirical test on non-TB Blackwell
- Upstream PR preparation for C1-C6 + E1 series

Plan to be written after Phase 1 exit gate is met.

## Phase 3+ preview (later phases; not yet planned)

Phase 3 candidate scope (subject to user direction; no design yet):
- **Application-transparent reattach.** Sink-clear path on confirmed device re-enumeration; in-place `OBJGPU` resurrection; workload migration semantics; UVM-side coordination for in-flight handles. Substantially larger design surface than Phase 1+2 — likely a multi-month design + implementation effort if pursued.
- Open question: is this even tractable on TB without GPU UUID drift across replug? Some hardware/firmware may make in-place resurrection impossible by construction (the new device-instance has a new identity); in that case, the right design is a userspace coordinator (workload manager that orchestrates pod-restart on hot-replug) rather than a driver-internal resurrection path.

Phase 3 design work begins (if at all) only after Phase 2 ships and is stable.
