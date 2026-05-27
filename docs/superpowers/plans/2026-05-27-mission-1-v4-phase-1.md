# MISSION-1 v4 Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the v4 cascade-class architecture (6 detection inputs → 1 sink primitive → 10 entry-point guards) on top of the running aorus.16 production driver, delivered as a sequence of small fork-branch commits + container rebuilds + soak windows, with verification gates between phases.

**Architecture:** Per [[../missions/mission-1-egpu-hot-plug-hot-power/cascade-class-design-v4]] v1.2. Single sink primitive `cleanupGpuLostStateAtomic(pGpu, detector_class)` owned by C5 base layer; detectors feed it, guards consult it. Phase 1 covers C5 v4 + C2/C3/C4/A1/A2/A3/A4 deltas. Phase 2 (separate plan) covers C6 (F1) and v3 revertability assessment.

**Tech Stack:** Linux kernel 7.0.x, NVIDIA open-gpu-kernel-modules 595.71.05 (fork at `/root/open-gpu-kernel-modules`), stacked git branches (c1→c2→c3→c4→c5→e1→a1→a2→a3→a4→a5), `tools/regen-base-patches.sh` for .patch regeneration, OCI container build via `Dockerfile`, k3s deployment via `apnex/k8s-vllm` repo. Test rig: AORUS RTX 5090 AI BOX over TB4 → NUC 15 Pro+ (Arrow Lake). No automated unit tests; verification is build + smoke + soak + must-gather forensic capture.

---

## Conventions / notation

This plan uses notation defined in [[../missions/mission-1-egpu-hot-plug-hot-power/cascade-class-design-v4]] §"Conventions / notation". Key short-forms:

- **C1-C6** = base-layer patches (Core); **E1** = eGPU-detection; **A1-A5** = addon patches
- **G1-G10** = entry-point guards
- **`[a]`-`[g]`** = detection inputs (6 classes)
- **DETECTOR_*** = sink primitive's input-class enum
- **aorus.NN** = container image tag (currently soaking on aorus.16; Phase 1 targets aorus.17 through aorus.20)

## File structure

Source files (fork-branch tip, `/root/open-gpu-kernel-modules/`):
| File | Owner patch | Purpose |
|---|---|---|
| `src/nvidia/inc/kernel/gpu/nv-gpu-lost.h` | C5 | DETECTOR_* enum + sink primitive prototype + macro family (existing, extended) |
| `src/nvidia/arch/nvalloc/unix/src/os.c` | C5 | `osIsGpuBusDead` predicate + osDevReadReg* (G1) + sink primitive body |
| `kernel-open/nvidia/os-pci.c` | C5 | `os_pci_set_disconnected` (existing) + sink-side log canonicalization |
| `kernel-open/common/inc/os-interface.h` | C5 | Prototypes (existing, extended) |
| `src/nvidia/src/kernel/vgpu/rpc.c` | C5 | G2 `_issueRpcAndWait` (existing) + G3 `_issueRpcAndWaitLarge` (NEW) |
| `src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c` | C5 | `[c]` GSP heartbeat detector + G8 `_kgspRpcRecvPoll` pre-loop guard |
| `src/nvidia/src/kernel/diagnostics/journal.c` | C5 | G6 `rcdbAddRmGpuDump` + `RmLogGpuCrash` extension |
| `src/nvidia/src/kernel/diagnostics/nv_debug_dump.c` | C5 | `nvdDumpAllEngines_IMPL` (existing C5 v1) |
| `src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c` | C5 | G9 kfsp arithmetic-invariant site-local guard |
| `src/nvidia/arch/nvalloc/unix/src/osinit.c` | C3 + C5 | C3 retry-loop (existing) + C5 cross-layer propagation hunk |
| `kernel-open/nvidia/nv.c` | C5 | G7 `rm_set_external_kernel_client_count` tolerate IS_LOST |
| `kernel-open/nvidia/nv-pci.c` | C4 (callback exists) + C5 | C4 `nv_pci_error_detected` callback gains sink-call + `[g]` probe-time BAR-failure detector |
| `kernel-open/nvidia-drm/nvidia-drm-drv.c` | C5 | G10 `nv_drm_remove` + KMS resource-release-on-disconnected-GPU |

Project files (`/root/nvidia-driver-injector/`):
| File | Purpose |
|---|---|
| `patches/base/C5-crash-safety.patch` | Regenerated from fork branch tip per phase |
| `patches/addon/A2-bus-loss-watchdog.patch`, `A3-recovery.patch`, `A4-close-path-telemetry.patch` | Same |
| `docs/patch-intents/C5-crash-safety.md` | Intent doc updated per phase with new requirements |
| `docs/patches.md` | Per-patch reference doc updated |
| `tools/regen-base-patches.sh` | Existing tool — regenerates .patch from fork branch tips |
| `Dockerfile` + `entrypoint.sh` | Container build + version tag bumps |
| `k8s/daemonset.yaml` | DaemonSet image tag (in `k8s-vllm` repo) |

## Soak + validation discipline

Each phase ends with a soak window. Soak duration scales with risk:
- **Phase 1A/1B (consolidation + safe detectors):** 1-2 day soak after deploy
- **Phase 1C (G8 with lock-hold change):** 2-3 day soak — guarded by E07 Run 3 reproduction test
- **Phase 1D (10 guards landed):** 3-7 day soak
- **Phase 1E (full validation runs):** 7+ day soak before Phase 2

Soak is on the live aorus.NN deploy with vLLM workload (the production case). Forensic capture via `tools/must-gather.sh` is required if anything regresses; ANY regression triggers rollback to prior aorus.NN tag (`kubectl rollout undo`).

---

## Phase 1A — Sink primitive + DETECTOR enum (foundation)

**Outcome:** `cleanupGpuLostStateAtomic(pGpu, detector_class)` exists, is called by both existing C5 v1 detection paths (post-read check, osHandleGpuLost retry-exhausted). No new behavior — only consolidation. Soak validates the consolidation is harmless.

### Task 1A.1: Add DETECTOR_* enum to nv-gpu-lost.h

**Files:**
- Modify: `/root/open-gpu-kernel-modules/src/nvidia/inc/kernel/gpu/nv-gpu-lost.h`
- Fork branch: `c5-crash-safety`

- [ ] **Step 1: Read current nv-gpu-lost.h header**

Run: `cat /root/open-gpu-kernel-modules/src/nvidia/inc/kernel/gpu/nv-gpu-lost.h`
Expected: existing C5 v1+v3 macros + constants visible.

- [ ] **Step 2: Add enum at end of header (before include guard close)**

```c
/*
 * Detector classification — passed to cleanupGpuLostStateAtomic to identify
 * which input class fired. Used for canonical-log differentiation and
 * telemetry attribution. See cascade-class-design-v4.md §"Conventions".
 */
typedef enum {
    DETECTOR_MMIO_DEAD                  = 0,  /* C5 v1 — os.c post-read check */
    DETECTOR_OSHANDLEGPULOST_RETRY_EXHAUSTED = 1,  /* C3 v3 — retry budget exhausted */
    DETECTOR_GSP_HEARTBEAT_TIMEOUT      = 2,  /* C5 v4 — kernel_gsp.c fatal-timeout branch */
    DETECTOR_AER_FATAL                  = 3,  /* C4 — pci_error_handlers.error_detected */
    DETECTOR_QWATCHDOG_DMA_WEDGE        = 4,  /* A2 — Q-watchdog kthread */
    DETECTOR_PROBE_BAR_FAILURE          = 5,  /* C5 v4 — nv_pci_probe IORESOURCE_UNSET */
    DETECTOR_SYSFS_DISCONNECTED         = 6,  /* C5 v4 — kernel-side async set */
    DETECTOR_UVM_FATAL                  = 7,  /* C6 (Phase 2) — nvGpuOpsReportFatalError */
} nv_gpu_lost_detector_t;
```

- [ ] **Step 3: Add sink primitive prototype to same header**

```c
/*
 * Atomic per-GPU sink-state setter. Idempotent — safe to call from any
 * detection input. Sets both PDB_PROP_GPU_IS_LOST (via
 * gpuSetDisconnectedProperties) and pci_dev_is_disconnected (via
 * os_pci_set_disconnected). Emits one NV_GPU_LOST_LOG_ONCE per
 * detector_class per kernel module lifetime.
 */
void cleanupGpuLostStateAtomic(OBJGPU *pGpu, nv_gpu_lost_detector_t detector_class);
```

- [ ] **Step 4: Compile the kernel module against the header change**

Run: `cd /root/open-gpu-kernel-modules && make -j$(nproc) modules SYSSRC=/lib/modules/$(uname -r)/build 2>&1 | tail -20`
Expected: fails at the FIRST caller location (unresolved symbol). This is the failing-test analog — verifies the prototype is visible everywhere it needs to be.

- [ ] **Step 5: Commit on fork branch (no functional change yet)**

```bash
cd /root/open-gpu-kernel-modules
git checkout c5-crash-safety
git add src/nvidia/inc/kernel/gpu/nv-gpu-lost.h
git commit -m "C5 v4: add nv_gpu_lost_detector_t enum + cleanupGpuLostStateAtomic prototype"
```

### Task 1A.2: Implement cleanupGpuLostStateAtomic body

**Files:**
- Modify: `/root/open-gpu-kernel-modules/src/nvidia/arch/nvalloc/unix/src/os.c`
- Fork branch: `c5-crash-safety`

- [ ] **Step 1: Locate existing osIsGpuBusDead + gpuSetDisconnectedProperties usage**

Run: `grep -n "osIsGpuBusDead\|gpuSetDisconnectedProperties\|os_pci_set_disconnected" /root/open-gpu-kernel-modules/src/nvidia/arch/nvalloc/unix/src/os.c | head -10`
Expected: ~3-5 hits showing existing call sites.

- [ ] **Step 2: Implement primitive at end of os.c**

```c
void cleanupGpuLostStateAtomic(OBJGPU *pGpu, nv_gpu_lost_detector_t detector_class)
{
    nv_state_t *nv;
    static NvBool s_logged[DETECTOR_UVM_FATAL + 1] = { NV_FALSE };

    if (pGpu == NULL)
        return;

    /* Idempotent: if already marked, skip log + state-set but allow re-entry */
    if (pGpu->getProperty(pGpu, PDB_PROP_GPU_IS_LOST))
        return;

    gpuSetDisconnectedProperties(pGpu);

    nv = NV_GET_NV_STATE(pGpu);
    if (nv != NULL && nv->handle != NULL)
        os_pci_set_disconnected(nv->handle);

    /* Per-detector_class log-once (one per kernel module lifetime per class) */
    if (detector_class <= DETECTOR_UVM_FATAL && !s_logged[detector_class])
    {
        s_logged[detector_class] = NV_TRUE;
        NV_PRINTF(LEVEL_ERROR,
                  "GPU %u lost via detector_class=%u\n",
                  gpuGetInstance(pGpu), (unsigned)detector_class);
    }
}
```

- [ ] **Step 3: Compile**

Run: `cd /root/open-gpu-kernel-modules && make -j$(nproc) modules SYSSRC=/lib/modules/$(uname -r)/build 2>&1 | tail -10`
Expected: clean build. No unresolved symbols.

- [ ] **Step 4: Commit on c5-crash-safety**

```bash
git add src/nvidia/arch/nvalloc/unix/src/os.c
git commit -m "C5 v4: implement cleanupGpuLostStateAtomic sink primitive"
```

### Task 1A.3: Refactor C5 v1 post-read check to use sink primitive

**Files:**
- Modify: `/root/open-gpu-kernel-modules/src/nvidia/arch/nvalloc/unix/src/os.c` (osDevReadReg032 post-read block)
- Fork branch: `c5-crash-safety`

- [ ] **Step 1: Locate post-read check (currently calls both gpuSetDisconnectedProperties + os_pci_set_disconnected directly)**

Run: `grep -n "gpuSetDisconnectedProperties" /root/open-gpu-kernel-modules/src/nvidia/arch/nvalloc/unix/src/os.c`
Expected: ~2 hits — the post-read confirmation block in osDevReadReg032.

- [ ] **Step 2: Replace the two-line pair with the single primitive call**

Locate the block (around the existing dead-bus verification):
```c
gpuSetDisconnectedProperties(pGpu);
os_pci_set_disconnected(nv->handle);
```

Replace with:
```c
cleanupGpuLostStateAtomic(pGpu, DETECTOR_MMIO_DEAD);
```

- [ ] **Step 3: Compile + lkdiff check**

Run: `make -j$(nproc) modules SYSSRC=/lib/modules/$(uname -r)/build 2>&1 | tail -5 && cd /root/nvidia-driver-injector && ./tools/regen-base-patches.sh`
Expected: clean build; .patch files regenerated.

- [ ] **Step 4: Commit on c5-crash-safety**

```bash
cd /root/open-gpu-kernel-modules
git add src/nvidia/arch/nvalloc/unix/src/os.c
git commit -m "C5 v4: post-read check uses cleanupGpuLostStateAtomic"
```

### Task 1A.4: Refactor C3 osHandleGpuLost retry-exhausted path

**Files:**
- Modify: `/root/open-gpu-kernel-modules/src/nvidia/arch/nvalloc/unix/src/osinit.c` (osHandleGpuLost lost-state branch)
- Fork branch: `c5-crash-safety` (NOT c3 — the propagation line is C5-owned per intent doc)

- [ ] **Step 1: Locate the retry-exhausted branch propagation (added by C5 v3)**

Run: `grep -n "os_pci_set_disconnected\|gpuSetDisconnectedProperties" /root/open-gpu-kernel-modules/src/nvidia/arch/nvalloc/unix/src/osinit.c`
Expected: hits showing the C5 v3 propagation pair after retry exhaustion.

- [ ] **Step 2: Replace pair with primitive call**

Same pattern as 1A.3 — replace:
```c
gpuSetDisconnectedProperties(pGpu);
os_pci_set_disconnected(nv->handle);
```
with:
```c
cleanupGpuLostStateAtomic(pGpu, DETECTOR_OSHANDLEGPULOST_RETRY_EXHAUSTED);
```

- [ ] **Step 3: Compile + regen patches**

Run: `cd /root/open-gpu-kernel-modules && make -j$(nproc) modules SYSSRC=/lib/modules/$(uname -r)/build 2>&1 | tail -5 && cd /root/nvidia-driver-injector && ./tools/regen-base-patches.sh`
Expected: clean.

- [ ] **Step 4: Commit on c5-crash-safety**

```bash
cd /root/open-gpu-kernel-modules
git add src/nvidia/arch/nvalloc/unix/src/osinit.c
git commit -m "C5 v4: osHandleGpuLost retry-exhausted uses cleanupGpuLostStateAtomic"
```

### Task 1A.5: Update C5 intent doc + regen patches

**Files:**
- Modify: `/root/nvidia-driver-injector/docs/patch-intents/C5-crash-safety.md`
- Modify: `/root/nvidia-driver-injector/patches/base/C5-crash-safety.patch` (regenerated)
- Run: `/root/nvidia-driver-injector/tools/regen-base-patches.sh`

- [ ] **Step 1: Update intent doc status frontmatter**

Change from `status: partial-v3-v4-design-committed` to `status: partial-v4a-implementation-in-progress`.

- [ ] **Step 2: Add a new Requirement to intent doc: "Driver SHALL provide cleanupGpuLostStateAtomic sink primitive"**

Include Given/When/Then scenarios mirroring the design doc § "Sink primitive."

- [ ] **Step 3: Run regen**

Run: `cd /root/nvidia-driver-injector && ./tools/regen-base-patches.sh && git diff --stat patches/base/C5-crash-safety.patch`
Expected: non-trivial diff showing the new primitive + refactored call sites.

- [ ] **Step 4: Commit on injector repo**

```bash
cd /root/nvidia-driver-injector
git add patches/base/C5-crash-safety.patch docs/patch-intents/C5-crash-safety.md
git commit -m "patches(C5): v4a sink primitive — DETECTOR enum + cleanupGpuLostStateAtomic"
```

### Task 1A.6: Build aorus.17 container + deploy + smoke test

**Files:**
- Modify: `/root/nvidia-driver-injector/Dockerfile`, `entrypoint.sh`, k8s yaml (in k8s-vllm repo)

- [ ] **Step 1: Bump version in A5 patch source**

Run: `grep -n "aorus.16" /root/open-gpu-kernel-modules/version.mk`
Edit to `595.71.05-aorus.17`. Commit on `a5-version-and-toggles` fork branch.

- [ ] **Step 2: Regenerate all addon patches**

Run: `cd /root/nvidia-driver-injector && ./tools/regen-base-patches.sh`

- [ ] **Step 3: Build container**

Run: `cd /root/nvidia-driver-injector && docker build -t apnex/nvidia-driver-injector:595.71.05-aorus.17 . 2>&1 | tail -20`
Expected: successful build.

- [ ] **Step 4: Import to containerd**

Run: `docker save apnex/nvidia-driver-injector:595.71.05-aorus.17 | sudo k3s ctr -n=k8s.io images import -`
Expected: success.

- [ ] **Step 5: Deploy via k8s-vllm repo**

```bash
cd /root/k8s-vllm
# Update DaemonSet image tag
sed -i 's|aorus.16|aorus.17|g' k8s/nvidia-driver-injector/daemonset.yaml
git add k8s/nvidia-driver-injector/daemonset.yaml
git commit -m "k8s: bump nvidia-driver-injector to aorus.17"
kubectl apply -f k8s/nvidia-driver-injector/daemonset.yaml
kubectl delete pod -n kube-system -l name=nvidia-driver-injector
sudo reboot   # to clear kernel-loaded .16 module
```

- [ ] **Step 6: Post-reboot smoke test**

After reboot, run:
```bash
cat /sys/module/nvidia/version
# Expect: 595.71.05-aorus.17
kubectl get pods -n kube-system | grep nvidia
# Expect: both pods 1/1
/root/nvidia-driver-injector/tools/get-pci-stats.sh
# Expect: BAR1=32GiB, healthy
```

- [ ] **Step 7: Commit final state in injector repo**

```bash
cd /root/nvidia-driver-injector
git add docs/patch-intents/C5-crash-safety.md patches/base/C5-crash-safety.patch patches/addon/A5-version-and-toggles.patch
git commit -m "release: aorus.17 — C5 v4a sink primitive consolidation (no behavior change)"
git push origin main
```

### Task 1A.7: 1-day soak

- [ ] **Step 1: Start vLLM workload, monitor 24 hours**

Run normal vLLM serving traffic. Periodically check:
```bash
dmesg | tail -20
/root/nvidia-driver-injector/tools/get-pci-stats.sh
```
Expected: no regressions, no new error messages, BAR1 stable.

- [ ] **Step 2: Capture must-gather snapshot at 24h mark**

Run: `/root/nvidia-driver-injector/tools/must-gather.sh > /var/log/mission-1-archaeology/phase-1A-soak-24h.tar.gz 2>&1`

- [ ] **Step 3: Phase 1A exit gate**

If 24h soak shows no regression, Phase 1A is complete. Proceed to Phase 1B.
If regression detected, rollback to aorus.16, root-cause via must-gather, fix, retry.

---

## Phase 1B — Wire new detectors `[c]`, `[d]`, `[f]`, `[g]`

**Outcome:** GSP heartbeat detector + AER callback body insert + Q-watchdog routing + probe-BAR detector all call sink primitive. Detection layer is multi-input, but no new guards yet — just observing how often each detector fires under normal load.

### Task 1B.1: GSP heartbeat detector at `_kgspRpcRecvPoll` fatal-timeout branch

**Files:**
- Modify: `/root/open-gpu-kernel-modules/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c` (around line 2868)
- Fork branch: `c5-crash-safety`

- [ ] **Step 1: Locate the existing fatal-timeout classification**

Run: `grep -n "bIsFatalTimeout\|_kgspClassifyGspTimeout" /root/open-gpu-kernel-modules/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c | head -5`
Expected: hits showing where fatal-vs-warning is decided.

- [ ] **Step 2: Insert sink call in fatal branch**

Right after the existing fatal-classification (before existing early-return), add:
```c
if (bIsFatalTimeout)
{
    cleanupGpuLostStateAtomic(pGpu, DETECTOR_GSP_HEARTBEAT_TIMEOUT);
    /* existing early-return code follows */
}
```

(Exact line + surrounding context depends on what's in tree; the SUBJECT is "fatal-timeout branch" — adapt to actual code.)

- [ ] **Step 3: Compile + regen + commit on c5-crash-safety**

Same pattern as Task 1A.3.

### Task 1B.2: AER error_detected callback body — insert sink call

**Files:**
- Modify: `/root/open-gpu-kernel-modules/kernel-open/nvidia/nv-pci.c` (`nv_pci_error_detected` body, line ~2868)
- Fork branch: `c5-crash-safety` (NOT c4 — C5 owns the sink primitive; C4's callback registration is unchanged)

- [ ] **Step 1: Locate the DISCONNECT-return branch**

Run: `grep -n "PCI_ERS_RESULT_DISCONNECT\|nv_pci_error_detected" /root/open-gpu-kernel-modules/kernel-open/nvidia/nv-pci.c | head -10`
Expected: hits showing the `default: PCI_ERS_RESULT_DISCONNECT` branch.

- [ ] **Step 2: Add sink-call before return**

Inside the `default:` branch:
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

- [ ] **Step 3: Compile + regen + commit**

Same pattern.

### Task 1B.3: A2 Q-watchdog → sink primitive (semantics change)

**Files:**
- Modify: `/root/open-gpu-kernel-modules/kernel-open/nvidia/...` (A2's existing kthread detection path; locate via patches/addon/A2-bus-loss-watchdog.patch)
- Fork branch: `a2-bus-loss-watchdog`

- [ ] **Step 1: Locate A2's existing os_pci_set_disconnected call**

Run: `grep -rn "os_pci_set_disconnected" /root/open-gpu-kernel-modules/kernel-open/ | grep -v "^Binary"`
Expected: at least one hit in A2's territory (the Q-watchdog kthread on DMA-wedge detection).

- [ ] **Step 2: Replace with sink primitive call**

Change:
```c
os_pci_set_disconnected(nv->handle);
```
to:
```c
cleanupGpuLostStateAtomic(pGpu, DETECTOR_QWATCHDOG_DMA_WEDGE);
```

(May require a pGpu lookup if not in scope; check surrounding code.)

- [ ] **Step 3: Compile + regen + commit on a2-bus-loss-watchdog**

```bash
git checkout a2-bus-loss-watchdog
# edit + verify
git add <file>
git commit -m "A2 v4: Q-watchdog routes through cleanupGpuLostStateAtomic (semantics: now sets RM marker too)"
```

**Note:** This is a SEMANTICS change — A2 now sets `PDB_PROP_GPU_IS_LOST` whereas it previously only set the Linux marker. Add explicit soak attention to A2 in Phase 1B/1C — verify no UVM-side state machines regress.

### Task 1B.3.5: Verify SYSFS_DISCONNECTED detection path (no new code)

**Files:** None modified — verification-only step.
**Purpose:** `[e]` input class in the architecture is "kernel-side `pci_dev_is_disconnected` set asynchronously (sysfs unbind, AER recovery completion)." No new code is required because `osIsGpuBusDead` already consumes this. Verify on the running aorus.18.

- [ ] **Step 1: Trigger sysfs-async-disconnect with a safe non-driver-resident path**

Pick a non-NVIDIA PCI device (e.g., a Realtek NIC if present) for the test, OR use a synthetic test on the NVIDIA device only if rig is recoverable. Set `pci_dev_is_disconnected` via `echo 1 > /sys/bus/pci/devices/.../remove` and observe.

- [ ] **Step 2: For NVIDIA device — only if rig is safely recoverable — trigger sysfs remove**

```bash
echo 1 | sudo tee /sys/bus/pci/devices/0000:04:00.0/remove
```

- [ ] **Step 3: Verify osIsGpuBusDead returns TRUE on next driver query**

`dmesg | grep "lost via detector_class"` should show DETECTOR_SYSFS_DISCONNECTED firing.

If detector class enum doesn't fire from this path (because the existing post-read check would catch it first via [a] MMIO_DEAD), document the actual fire pattern in `experiments/sysfs-disconnect-Run-1.md`.

- [ ] **Step 4: Recovery**

```bash
echo 1 | sudo tee /sys/bus/pci/rescan
# Reboot if state doesn't fully recover
```

This task is verification-only; no commits.

### Task 1B.4: Probe-time BAR-failure detector

**Files:**
- Modify: `/root/open-gpu-kernel-modules/kernel-open/nvidia/nv-pci.c` (`nv_pci_probe`)
- Fork branch: `c5-crash-safety`

- [ ] **Step 1: Locate existing nv_pci_validate_bars call at nv_pci_probe entry**

Run: `grep -n "nv_pci_validate_bars\|IORESOURCE_UNSET" /root/open-gpu-kernel-modules/kernel-open/nvidia/nv-pci.c | head -10`
Expected: at least one hit at probe entry.

- [ ] **Step 2: Add IORESOURCE_UNSET check + early sink-set**

Right after existing validate_bars call, before going into rmInitAdapter:
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
            /* Sink set here is best-effort — pGpu may not be attached yet */
            return -ENODEV;
        }
    }
}
```

(Sink primitive call deferred — at probe-entry pGpu isn't constructed yet; the early `return -ENODEV` is the actionable bit. Document as such in the intent.)

- [ ] **Step 3: Compile + regen + commit**

Same pattern.

### Task 1B.5: Update C5 + A2 intent docs

- [ ] **Step 1: Add Requirements for new detectors to C5 intent doc**

Add Requirements: "Driver SHALL set sink-state on GSP heartbeat fatal-timeout" + "Driver SHALL set sink-state on AER error_detected fatal" + "Driver SHALL refuse probe on IORESOURCE_UNSET BAR allocation failure."

- [ ] **Step 2: Update A2 intent doc to note semantics change**

Add new Requirement: "A2's bus-loss-watchdog SHALL route detection through C5's cleanupGpuLostStateAtomic sink primitive (sets both markers)."

- [ ] **Step 3: Commit intent doc updates**

```bash
cd /root/nvidia-driver-injector
git add docs/patch-intents/C5-crash-safety.md docs/patch-intents/A2-bus-loss-watchdog.md
git commit -m "intent: C5+A2 v4b — wire new detectors through sink primitive"
```

### Task 1B.6: Build aorus.18 + deploy + smoke

Same pattern as Task 1A.6. Bump version, build, deploy, reboot, smoke-test.

### Task 1B.7: 2-day soak with detector activity logging

- [ ] **Step 1: Configure detector-activity log harvest**

```bash
# 4-hour interval check
while sleep 14400; do
    /root/nvidia-driver-injector/tools/get-pci-stats.sh > /var/log/mission-1-archaeology/phase-1B-soak-$(date +%s).log
done &
```

- [ ] **Step 2: Run normal vLLM workload for 48 hours**

- [ ] **Step 3: Verify zero detector fires under normal load**

Expected: `dmesg | grep "lost via detector_class"` returns 0 lines. Healthy operation does not fire any detector.

- [ ] **Step 4: Phase 1B exit gate**

If 48h soak shows zero false-positives and zero regressions, proceed to Phase 1C.

---

## Phase 1C — G8 dynamic confirmation + implementation

**Outcome:** G8 hypothesis (per-call 75s lock-hold × ioctl-storm) confirmed dynamically before committing the guard. If hypothesis fails, G8 design is revised; if confirmed, G8 lands.

### Task 1C.1: Build instrumented variant aorus.18-inst

- [ ] **Step 1: Add lock-hold-time instrumentation at `_kgspRpcRecvPoll` entry**

Edit `kernel_gsp.c:2787`:
```c
static NV_STATUS
_kgspRpcRecvPoll(...)
{
    NvU64 entry_jiffies = jiffies;
    NvBool b_was_fatal_on_entry = pKernelGsp->bFatalError;

    /* ... existing body ... */

done:
    if (jiffies - entry_jiffies > msecs_to_jiffies(5000))
    {
        NV_PRINTF(LEVEL_ERROR,
            "_kgspRpcRecvPoll: lock-held %u ms; bFatalError-on-entry=%d\n",
            jiffies_to_msecs(jiffies - entry_jiffies),
            (int)b_was_fatal_on_entry);
    }
    return rpcStatus;
}
```

- [ ] **Step 2: Build aorus.18-inst (no version bump — local-only image)**

```bash
docker build -t apnex/nvidia-driver-injector:595.71.05-aorus.18-inst .
```

- [ ] **Step 3: Deploy aorus.18-inst, reboot**

### Task 1C.2: Synthetic reproduction of #1134 (or analogue)

- [ ] **Step 1: Choose reproduction strategy**

Options:
1. BAR1 exhaustion via `gpu_burn` + many concurrent CUDA streams
2. Cable yank (E07 protocol)
3. AORUS power toggle (power-off wedge protocol)

For G8 specifically, what matters is "GPU enters bFatalError state, userspace continues to issue ioctls, lock-hold time on each call." Cable yank is the easiest to reliably trigger.

- [ ] **Step 2: Run reproduction**

Recipe per E07-cable-replug-drain-first.md. Capture `dmesg` for "_kgspRpcRecvPoll: lock-held" lines.

- [ ] **Step 3: Verify hypothesis**

Expected pattern: many "lock-held >5000 ms with bFatalError-on-entry=1" lines after the trigger event.

If observed: hypothesis confirmed. Proceed to G8 implementation.
If NOT observed (lock-hold << 5s per call): hypothesis falsified. Halt; revise G8 design before implementation.

### Task 1C.3: Implement G8 placement A

**Files:**
- Modify: `/root/open-gpu-kernel-modules/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c:2787` (pre-loop)
- Fork branch: `c5-crash-safety`

- [ ] **Step 1: Locate `_kgspRpcSanityCheck` call (currently inside the loop)**

Run: `grep -n "_kgspRpcSanityCheck" /root/open-gpu-kernel-modules/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c`
Expected: ~2 hits — one definition, one current call inside the for-loop.

- [ ] **Step 2: Hoist check to BEFORE the `for(;;)` loop**

Around line 2787 (just after lock-owner assert, before the for-loop entry):
```c
/* G8: pre-loop sanity check. If GSP is already in bFatalError or the
 * GPU is known-dead, return immediately without polling. Avoids
 * 75s lock-hold storms under ioctl-storm after Xid 154. */
if (pKernelGsp->bFatalError || osIsGpuBusDead(pGpu))
{
    NV_PRINTF_COND(NV_PRINTF_LEVEL_DEBUG, ...);
    return NV_ERR_RESET_REQUIRED;
}
```

- [ ] **Step 3: Remove the redundant in-loop check OR leave it as defense-in-depth**

Defense-in-depth is fine; keep the existing in-loop check.

- [ ] **Step 4: Compile + regen + commit on c5-crash-safety**

Same pattern.

### Task 1C.4: Remove instrumentation; build aorus.19

- [ ] **Step 1: Revert the lock-hold-time printk added in 1C.1**

- [ ] **Step 2: Bump version (a5-version-and-toggles fork branch) to aorus.19**

- [ ] **Step 3: Build + deploy + reboot + smoke**

### Task 1C.5: Validate G8 with same reproduction

- [ ] **Step 1: Re-run synthetic reproduction**

- [ ] **Step 2: Verify lock-hold time collapses**

Expected: post-fatal-error RPCs return in microseconds, not 75 seconds. `dmesg` should show fast `_kgspRpcRecvPoll` returns even under ioctl storm.

- [ ] **Step 3: Verify cleanup completes within minutes (not 5+)**

`nvidia_drm` teardown should NOT hang.

- [ ] **Step 4: Phase 1C exit gate**

If G8 validated with reproduction, proceed to Phase 1D. If wedge still occurs, G8 design needs revision (Placement B fallback or new investigation).

### Task 1C.6: 3-day soak under normal workload

Run vLLM normal workload for 72h. Verify G8 fires zero times under healthy operation.

---

## Phase 1D — Remaining 6 guards (G3, G5, G6, G7, G9, G10)

**Outcome:** All 10 v4 guards implemented; entry-point coverage complete; ready for full validation.

### Task 1D.1: G3 — `_issueRpcAndWaitLarge` guard

**Files:** `src/nvidia/src/kernel/vgpu/rpc.c:2071` (`_issueRpcLarge`)
**Fork branch:** `c5-crash-safety`

- [ ] **Step 1: Mirror existing G2 pattern from `_issueRpcAndWait` (rpc.c:1854)**

Add at top of `_issueRpcLarge`:
```c
if (pGpu->getProperty(pGpu, PDB_PROP_GPU_IS_LOST))
    return NV_ERR_GPU_IS_LOST;
```

- [ ] **Step 2: Compile + regen + commit**

### Task 1D.2: G5 — rate-limit at noisy API_GPU_ATTACHED_SANITY_CHECK callers

**Files:** Multiple call sites (10+); use `NV_GPU_LOST_LOG_ONCE` at the LOUDEST 3-5 hot sites identified during #776's repro.

- [ ] **Step 1: Identify hot callers from #776 dmesg pattern**

Run `gh issue view 776 --repo NVIDIA/open-gpu-kernel-modules | grep -A 3 "API_GPU_ATTACHED_SANITY_CHECK"`.

- [ ] **Step 2: For each hot site, wrap the `LEVEL_ERROR` print with `NV_GPU_LOST_LOG_ONCE`**

(Specific call sites to be identified per Step 1.)

- [ ] **Step 3: Compile + regen + commit**

### Task 1D.3: G6 — RmLogGpuCrash sink-check

**Files:** `src/nvidia/src/kernel/diagnostics/journal.c` (or wherever `RmLogGpuCrash` lives)
**Fork branch:** `c5-crash-safety`

- [ ] **Step 1: Locate RmLogGpuCrash**

Run: `grep -rn "RmLogGpuCrash" /root/open-gpu-kernel-modules/src/ | head -5`

- [ ] **Step 2: Add `osIsGpuBusDead(pGpu)` early-return at entry**

Pattern matching existing `rcdbAddRmGpuDump` from C5 v1.

- [ ] **Step 3: Compile + regen + commit**

### Task 1D.4: G7 — rm_set_external_kernel_client_count tolerate IS_LOST

**Files:** `kernel-open/nvidia/nv.c:5445` (WARN_ON site)
**Fork branch:** `c5-crash-safety`

- [ ] **Step 1: Locate WARN_ON at nv.c:5445**

Run: `sed -n '5435,5455p' /root/open-gpu-kernel-modules/kernel-open/nvidia/nv.c`

- [ ] **Step 2: Replace WARN_ON pattern with IS_LOST tolerance**

```c
NV_STATUS s = rm_set_external_kernel_client_count(...);
if (s != NV_OK && s != NV_ERR_GPU_IS_LOST)
    WARN_ON(1);
```

- [ ] **Step 3: Compile + regen + commit**

### Task 1D.5: G9 — kfsp arithmetic-invariant guard

**Files:** `src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c:649`
**Fork branch:** `c5-crash-safety`

- [ ] **Step 1: Add early-return on dead-bus first-read at line 621**

Right after first GPU_REG_RD32 of NV_PFSP_EMEMC, if value is `0xFFFFFFFF`:
```c
if (reg32 == 0xFFFFFFFF)
{
    if (osIsGpuBusDead(pGpu))
        return NV_ERR_GPU_IS_LOST;
}
```

- [ ] **Step 2: Compile + regen + commit**

### Task 1D.5.5: A3 sink-query at top of `tb_egpu_recover_pre_schedule_gates`

**Files:** A3-recovery patch source (locate via patches/addon/A3-recovery.patch)
**Fork branch:** `a3-recovery`

- [ ] **Step 1: Locate `tb_egpu_recover_pre_schedule_gates`**

Run: `grep -rn "tb_egpu_recover_pre_schedule_gates" /root/open-gpu-kernel-modules/ | head -5`

- [ ] **Step 2: Add early sink-query at function entry (immediately after parameter validation)**

```c
enum tb_egpu_recover_gate
tb_egpu_recover_pre_schedule_gates(struct tb_egpu_recover_state *st,
                                   struct pci_dev *pci_dev,
                                   const char **reason)
{
    /* A3 sink-query: if v4 sink primitive has already declared the GPU lost,
     * surrender immediately without consuming retry budget. Faster path
     * than the existing attempt-count check. */
    {
        nv_linux_state_t *nvl = pci_get_drvdata(pci_dev);
        OBJGPU *pGpu = (nvl != NULL) ? NV_GET_NV_PRIV_PGPU(NV_STATE_PTR(nvl)) : NULL;
        if (pGpu != NULL && osIsGpuBusDead(pGpu))
        {
            *reason = "sink-set: GPU already declared lost";
            return TB_EGPU_RECOVER_GATE_SURRENDER;
        }
    }
    /* existing body */
}
```

- [ ] **Step 3: Compile + regen + commit on a3-recovery fork branch**

```bash
git checkout a3-recovery
git add <file>
git commit -m "A3 v4: sink-query early surrender in pre_schedule_gates"
```

### Task 1D.6: G10 — DRM teardown guard

**Files:** `kernel-open/nvidia-drm/nvidia-drm-drv.c` (nv_drm_remove + KMS resource-release paths)
**Fork branch:** `c5-crash-safety`

- [ ] **Step 1: Locate `nv_drm_remove`**

Run: `grep -n "nv_drm_remove\|drm_dev_unregister\|drm_dev_put" /root/open-gpu-kernel-modules/kernel-open/nvidia-drm/nvidia-drm-drv.c`

- [ ] **Step 2: Add osIsGpuBusDead check at entry**

```c
void nv_drm_remove(NvU32 gpuId)
{
    /* If GPU is already known dead, skip hardware-touching teardown.
     * Linux DRM core will free resources regardless. */
    /* ... lookup pGpu by gpuId ... */
    if (pGpu != NULL && osIsGpuBusDead(pGpu))
    {
        nv_drm_log(NV_DRM_LOG_INFO, "skipping hardware teardown on lost GPU");
        return;
    }
    /* existing body */
}
```

- [ ] **Step 3: Compile + regen + commit**

### Task 1D.7: Intent doc updates for all 6 guards

Update `docs/patch-intents/C5-crash-safety.md` with one new Requirement per guard. Commit.

### Task 1D.8: Build aorus.20 + deploy + smoke

Bump version, build, deploy, reboot, smoke-test.

### Task 1D.9: 3-day soak

Normal vLLM workload. Verify zero false-positive guard fires; zero regressions.

---

## Phase 1E — Full validation runs (regression tests of v3 failure modes)

**Outcome:** v4 demonstrably handles the scenarios v3 failed on. Forensic artifacts captured for upstream PR evidence.

### Task 1E.1: E07 Run 4 — cable-yank regression test

- [ ] **Step 1: Pre-test snapshot**

```bash
/root/nvidia-driver-injector/tools/must-gather.sh > /var/log/mission-1-archaeology/E07-Run4-pre.tar.gz
```

- [ ] **Step 2: Yank TB cable while vLLM is mid-inference**

- [ ] **Step 3: Observe host survival**

Expected: dmesg shows ONE canonical "GPU lost via detector_class=X" line (not multiple); cleanup completes; nvidia_drm teardown does NOT hang; host remains responsive; SSH still works; `systemctl reboot` succeeds.

- [ ] **Step 4: Post-test snapshot**

```bash
/root/nvidia-driver-injector/tools/must-gather.sh > /var/log/mission-1-archaeology/E07-Run4-post.tar.gz
```

- [ ] **Step 5: Document result in experiments/E07-cable-replug-drain-first.md**

Add "Run 4 (aorus.20)" section with PASS/FAIL + key forensic excerpts.

### Task 1E.2: Power-off wedge regression test

- [ ] **Step 1: Pre-test snapshot**

- [ ] **Step 2: Power off AORUS AI BOX via its power switch while vLLM is running**

- [ ] **Step 3: Observe**

Expected: detector input from MMIO/heartbeat/Q-watchdog redundancy; cleanup; host survives.

- [ ] **Step 4: Post-test snapshot + document**

Add new experiments file or section: `experiments/power-off-wedge-Run-1.md`.

### Task 1E.3: Synthetic uvm-fatal cross-GPU test (deferred — needs C6)

Only meaningful once C6 (F1) lands in Phase 2. Skip in Phase 1.

### Task 1E.4: 7-day soak under production vLLM load

Real production traffic. Verify zero unexpected detector fires. Build confidence baseline before claiming Phase 1 complete.

### Task 1E.5: Phase 1 exit gate

If E07 Run 4 + power-off test both PASS, AND 7-day soak shows clean operation, Phase 1 is complete.

If anything fails, root-cause via must-gather, fix on appropriate fork branch, regen, build, deploy, retest.

---

## Phase 1F — Telemetry consolidation (cleanup; optional within Phase 1)

**Outcome:** Per-site `NV_GPU_LOST_LOG_ONCE` latches from C5 v3 retire in favor of canonical sink-side per-detector logging. Reduces log volume; improves triage simplicity. May defer to Phase 2 if Phase 1E already exhausts session scope.

### Task 1F.1: Audit existing per-site NV_GPU_LOST_LOG_ONCE call sites

Run: `grep -rn "NV_GPU_LOST_LOG_ONCE" /root/open-gpu-kernel-modules/`
Expected: ~10 hits across v1 + v3 sites.

### Task 1F.2: Retire per-site latches (keep at most 2 canonical sites)

For each site that's downstream of a v4 funnel (the 8 v3 sites + 2 v1 resserv sites), remove the LOG_ONCE call. The sink primitive's canonical log replaces them.

### Task 1F.3: Build aorus.21 + 1-day soak

Sanity check that retiring the logs doesn't break anything else.

### Task 1F.4: A4 telemetry consume canonical sink-side logs

Update A4-close-path-telemetry to OBSERVE the canonical log instead of scattered per-site logs.

---

## Phase 1 exit gate — criteria for "done"

- [ ] All Phase 1A-1E tasks completed (1F optional)
- [ ] E07 Run 4 (cable yank): PASS
- [ ] Power-off wedge test: PASS
- [ ] 7-day soak under production load: clean
- [ ] Aggregate line count tracked in `docs/patches.md`
- [ ] All intent docs updated to status:reviewed or status:implemented
- [ ] All fork branches pushed (with force-push-with-lease per carve-out)
- [ ] Decision-doc (`decision-architecture-class-localization.md`) status updated to reflect Phase 1 complete

Phase 1 complete → ready for Phase 2 (C6 implementation + v3 site revertability assessment).

---

## Risks + rollback plan

**Rollback unit:** aorus.NN tag. Each phase produces a new immutable tag; rollback is `kubectl rollout undo` + reboot + revert k8s yaml.

**Detected regression triggers immediate rollback:**
- vLLM workload latency or throughput degradation
- New Xid messages under normal load
- Spurious detector fires (`grep "lost via detector_class"` in dmesg)
- Build failures
- Module load failures
- `must-gather` shows new error categories

**Known risks per phase:**
- **1A:** None expected (refactor; no behavior change). If sink primitive's idempotency check is wrong, could cause infinite recursion (impossible per design).
- **1B (A2 semantics change):** could perturb UVM state machines that key on RM marker. Soak monitor for any UVM-related dmesg.
- **1C (G8):** if hypothesis is wrong, G8 doesn't address #1134. Hypothesis-confirm BEFORE landing G8 (Task 1C.2 gate).
- **1D (10 guards):** most guards are short-circuits; biggest risk is G5 rate-limit hiding a legitimate log under normal load. Soak monitor for "missing" log lines.
- **1E:** validation tests may force a host wedge if v4 is insufficient. Have recovery plan (E07 Run 3 recovery protocol) ready.
- **1F:** retiring per-site logs could hide important debug info if a future failure occurs there. Mitigate by keeping at least one canonical NV_GPU_LOST_LOG_ONCE at the resserv level.

## Cross-references

- [[../missions/mission-1-egpu-hot-plug-hot-power/cascade-class-design-v4]] — v1.2 architecture (load-bearing)
- [[../missions/mission-1-egpu-hot-plug-hot-power/cascade-scope-audit]] — site audit + issue-tracker survey
- [[../missions/mission-1-egpu-hot-plug-hot-power/decision-architecture-class-localization]] — Option 1 commitment
- [[../missions/mission-1-egpu-hot-plug-hot-power/f1-uvm-fatal-error-gating-design]] — C6 (Phase 2 plan target)
- `docs/upstream-plan.md` — C/E/A patch geometry + upstream filing strategy
- `docs/patches.md` — per-patch canonical reference
- `tools/regen-base-patches.sh` — patch regeneration mechanic
- `tools/must-gather.sh`, `tools/get-pci-stats.sh` — forensic capture
- Memories: `project_dynamic_patch_composition_merged_2026_05_22`, `project_addon_recarve_merged_2026_05_22`, `feedback_force_push_fork_carve_out`

## Phase 2 preview (separate plan)

Phase 2 covers:
- C6 (F1) — `nvGpuOpsReportFatalError` per-GPU gating per `f1-uvm-fatal-error-gating-design.md`
- v3 site revertability assessment (potentially −80 lines)
- Optional cross-hardware empirical test on non-TB Blackwell
- Upstream PR preparation (C1-C6 + E1 series)

Plan to be written after Phase 1 exit gate is met.
