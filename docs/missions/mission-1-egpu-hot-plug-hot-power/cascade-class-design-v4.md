# Cascade-class design synthesis — v4 architecture

**Status:** v1.1 2026-05-27 — design exercise informed by [[cascade-scope-audit]] + 9-issue tracker review.
**Revision:** v1 (2026-05-26) → v1.1 after adversarial review pass identified 2 Critical + 9 Important findings; revisions integrated below. Original v1 framing of "+26 net lines" and "5 independent detectors" was source-checked and corrected.
**Predecessor:** v3 of C5 (per-site sweep + macro family) + scattered detection across C5/C3/A2/C4.
**Goal:** Single coherent architecture for the surprise-removal cascade class that handles all 9 cited issues with bounded surface and provable completeness, while improving aggregate properties across the patch series.

## Design goals (multi-dimensional improvement targets)

The v4 redesign must improve on v2/v3 across **all** of:

| Dimension | v2/v3 state | v4 target |
|---|---|---|
| **Coverage** | 1 cascade entry class (MMIO 0xFFFFFFFF post-read) | 6 cascade entry classes (kernel PCI core async / AER fatal / MMIO 0xFFFFFFFF / GSP heartbeat timeout / Q-watchdog DMA / probe-time BAR-failure) |
| **Completeness** | Per-site sweep — unbounded; never converges; new driver versions surface new sites | Entry-point guards — bounded by design; new sites covered by upstream funnel where the funnel intercepts (DRM-side and chip-reset preconditions need their own guards) |
| **Convergence** | Scattered detection in C5 + C3 + A2 + C4; markers set inconsistently per detection path | Single sink-state primitive; all detection inputs route through it; markers always consistent |
| **Robustness** | Chip-reset path can loop forever on `NV_ERR_RESET_REQUIRED` while sink-state already set (#1134) | Recovery primitives query sink-state FIRST; bounded retry already aborts on sink-set |
| **Isolation (our driver's half)** | Our driver's detection is per-GPU but propagates via two scattered markers | Per-GPU sink-state with explicit per-GPU semantics in *our* code paths. **Caveat:** `nvGpuOpsReportFatalError` (`src/nvidia/src/kernel/rmapi/nv_gpu_ops.c:11678`) takes no `pGpu` and unconditionally calls `sysSetRecoveryRebootRequired(pSys, NV_TRUE)` — the #979 jciolek cross-contamination symptom requires a **separate follow-up patch** to that function's signature (out of scope for v4 base architecture; tracked as follow-up F1 below) |
| **Maintainability** | Site list grows linearly with driver-version changes; v3 sweep missed 3 sites; future sweeps will miss more | Funnel set is bounded by entry-point count, not by call-site count; survives driver-version churn for paths the funnels intercept |
| **Upstream-PR fitness** | "Convert 8 asserts" reads as a sweep, not a fix | "Single sink-state primitive with 6 detection inputs and 10 guards" reads as a coherent design |
| **Defense-in-depth (qualified)** | One detection input — if it fails, all downstream guards are silent | **2-3 independent upstream classes:** PCIe-completion-based (MMIO post-read, GSP heartbeat, osHandleGpuLost retry — all consume the same PCIe TLP-completion mechanism), PCIe-state-based (AER fatal callback signaled by root complex, kernel-side `pci_dev_is_disconnected`), and forward-progress-based (Q-watchdog DMA, probe-BAR). Failure of one *upstream class* is masked by the others; failure of one *detector* within a class may not be |
| **Code surface** | C5 v1+v3 = ~230 lines added across multiple files | Net delta after revisions: ~+8 lines (see [aggregate code delta](#aggregate-code-delta) below); excludes follow-up F1 (~+10-15 if pursued) |

The goal is **NOT** "fewer lines for the sake of fewer lines." It is "the smallest architectural surface that correctly handles the entire cited failure class with provable completeness."

## Per-issue design implications

The 9 surveyed issues map to 6 design-shaping inputs. Each issue's specifics inform a concrete v4 architectural choice.

| Issue | Cascade entry | Design implication for v4 |
|---|---|---|
| [#1134](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1134) (2026-05-07, RTX 3090, PCIe x16, **595.71.05**) | BAR1 VA-exhaustion → Xid 31 → Xid 154; chip-reset itself wedges in `NV_ERR_RESET_REQUIRED` loop; `systemctl reboot` blocks; `nvidia_drm` teardown hangs >5min | **Recovery must respect sink-state** (G8). **DRM teardown must observe sink** — `nv_drm_remove` (`kernel-open/nvidia-drm/nvidia-drm-drv.c:2187`) and KMS resource-release paths have ZERO sink-awareness today (grep confirmed); needs new guard G10. **`nvidia_close` / `nvidia_dev_put` must observe sink** (G7) — but the actual WARN at `nv.c:5445` is on `rm_set_external_kernel_client_count` return, so the guard belongs there, not at the dev_put entry. |
| [#1045](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1045) (2026-03-01, RTX 5080, PCIe x16) | Xid 62 → 45 → 119 (GSP timeout, 45s) → 154 | **GSP heartbeat timeout (Xid 119) is a dead-bus signal.** Add as sink-trigger input. The 30-45s gap between channel error and GSP timeout is a natural debounce window — fits one bounded retry per C3, no further RPCs. |
| [#979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979) (2025-12-04, multi-Blackwell, TB4/TB5/USB4 + Windows) | Xid 79 + uvm 0x60 + Xid 154; some reproducers show **AER error before any Xid** (TOSUKUi: `AER: device recovery failed`, `can't recover (no error_detected callback)`); other reproducers show **zero log signal** (silent host wedge); jciolek case: external 5090 loss rebooted internal 3060 (cross-GPU contamination) | **(a)** Wire `pci_error_handlers.error_detected` as sink-trigger. C4 already has a 60-line callback body in tree wired to addon `tb_egpu_recover_*` (`nv-pci.c:2868`); the addition is a `cleanupGpuLostStateAtomic` call inside that existing callback (NOT "adding a body"). Decide base/addon ownership of the sink primitive. **(b)** Q-watchdog stays as detector-of-last-resort for silent-wedge cases. **(c)** Confirms Linux can call `error_detected` BEFORE driver-internal detection — sink-state must accept inputs from this earliest layer. **(d) jciolek cross-contamination is NOT addressed by per-GPU sink alone.** `nvGpuOpsReportFatalError` (`src/nvidia/src/kernel/rmapi/nv_gpu_ops.c:11678`) is system-global and has no `pGpu`. Tracked as follow-up F1 below; v4 base architecture does not include this fix. |
| [#974](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/974) (2025-11-25, RTX 5060 Ti TB4) | Kernel PCI: `bridge window can't assign; no space` → driver probe → Xid 79 → `kgspBootstrap_GH100` fails → WPR2-stuck | **Boot-time BAR-allocation failure is a sink-trigger.** Detect at probe; refuse to continue into GSP-init that can only fail. Validates project's existing BAR1 alignment work in cmdline + addon layer. |
| [#888](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/888) (2025-11-25, RTX 5090 native PCIe) | gpu_burn → Xid 79 | Confirms Blackwell + sustained CUDA → bus loss is **transport-agnostic**. Reinforces Core (Option 1) scope. No new design input. |
| [#916](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/916) (2025-08-10, 2x RTX 4090) | NV_ERR_GPU_IS_LOST + IN_FULLCHIP_RESET storm; `WARN at nv.c:5039 nvidia_dev_put+0xb1` | **`nvidia_close` and `nvidia_dev_put` need sink-awareness.** Both fire on userspace process crash-cleanup after GPU lost; both currently WARN. Add sink-state check at refcount drop. |
| [#900](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/900) (2025-07-11 CLOSED hw-swap, RTX 5090 OCuLink) | Xid 79 under any sustained CUDA; nvidia-smi idle works | **Closure was hardware-workaround, not fix.** Confirms external-PCIe transport class is broader than TB. Boot-time GSP-FMC bootstrap precursor errors argue for early GSP-fragility detection. |
| [#776](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/776) (2025-02-02, RTX A2000 Laptop PRIME) | Alt-tab D3cold → Xid 79; `API_GPU_ATTACHED_SANITY_CHECK` fires 10× in 1s → uvm fatal 0x60 → Xid 154 | **`_threadNodeCheckTimeout: API_GPU_ATTACHED_SANITY_CHECK` already exists as a centralized "is GPU attached" gate.** v4 should ROUTE THROUGH this existing gate rather than adding parallel checks. This is a free architectural primitive nobody currently leverages. |
| [#461](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/461) (2023-02-18 CLOSED stale, RTX 3060 ARM64) | Xid 79 in `intrServiceStall_IMPL` (interrupt-context read returns 0xFFFFFFFF) → Xid 119 triggered by `DUMP_PROTOBUF_COMPONENT` (the crash-dump's own RPC blocks for 5s waiting for the dead GPU) | **(a)** Interrupt-context MMIO read is a sink-trigger source (existing C5 v1 post-read check works here). **(b)** **Crash-dump path must check sink-state before issuing diagnostic RPCs** — otherwise every cascade costs a free 5-45s wedge. C5 v1's `rcdbAddRmGpuDump` early-return already handles this; verify `RmLogGpuCrash` path is included. **(c)** Closure was wrong-tracker routing, not fix — NVIDIA's triage default is to disclaim non-TB eGPU-class failures, validating in-driver work has higher leverage than upstream advocacy. |

### Synthesis: five distinct cascade entry classes, one sink

The 9 issues span 5 structurally distinct cascade entry mechanisms, all converging to the same set of sink symptoms (Xid 154 "Node Reboot Required" / `nvGpuOpsReportFatalError: uvm global fatal 0x60` / `AER: device recovery failed`):

1. **MMIO read returns 0xFFFFFFFF** — current C5 v1 post-read check (osDevReadReg032). Covered.
2. **GSP heartbeat / RPC timeout (Xid 119, 45s)** — chip electrically present, firmware wedged. NOT covered by v3. Highest-leverage new input.
3. **AER `pci_error_handlers.error_detected` callback** — Linux PCI core detects fatal error before driver does. NOT currently wired as sink-trigger. C4 already registers handlers; just needs the sink-set in the callback.
4. **DMA-path silent wedge (Mode B class)** — no log, no Xid, no AER. Q-watchdog (A2) is the only detector. NOT routed to sink. Just needs the sink-set on detection.
5. **Kernel PCI bridge-window failure at probe** — BAR1/IO allocation rejected before driver-internal detection has any input. NOT covered; new input.

Plus a 6th input class that's a sink-trigger NOT a cascade entry: kernel-side `pci_dev_is_disconnected()` set asynchronously (e.g., from sysfs unbind, AER recovery completion). C5 v1 already consumes this via `osIsGpuBusDead`; just needs full coverage in the sink-state propagation primitive.

The sink itself is conceptually one bit per GPU: "this device is unrecoverable; do not issue new operations against it; allow cleanup paths to complete via short-circuit." The bit's physical representation is the existing two-marker pair (`PDB_PROP_GPU_IS_LOST` + `pci_dev_is_disconnected`), both set together via a single primitive (`gpuSetDisconnectedProperties` + `os_pci_set_disconnected`, already in C5 v1).

## v4 architecture

```
DETECTION INPUTS (6 classes; each calls cleanupGpuLostStateAtomic on detect)
│
│   ━━ PCIe-completion class (3 detectors; not independent of each other) ━━
├── [a] os.c MMIO-read post-check (C5 v1 — already done)
├── [b] C3 osHandleGpuLost retry-exhausted (C5 v3 — already done; line lives in C5)
├── [c] GSP heartbeat timeout (NEW) — hook at _kgspRpcRecvPoll fatal-timeout
│       branch (kernel_gsp.c ~2868), NOT by exposing static
│       _kgspIsHeartbeatTimedOut. ~2 lines.
│
│   ━━ PCIe-state class (2 detectors; independent of completion class) ━━
├── [d] AER pci_error_handlers.error_detected — C4 callback body ALREADY
│       EXISTS (nv-pci.c:2868, ~60 lines wired to addon tb_egpu_recover_*);
│       the addition is one cleanupGpuLostStateAtomic call inside that
│       existing callback. Base/addon ownership decision required (see C4
│       cross-patch section). ~1 line addition + 1 layering decision.
├── [e] Kernel-side pci_dev_is_disconnected set asynchronously (sysfs unbind,
│       AER recovery completion). osIsGpuBusDead already consumes this; sink
│       primitive must remain consistent when detection arrives from this
│       layer (no new code; verify existing path).
│
│   ━━ Forward-progress class (2 detectors; independent of both above) ━━
├── [f] Q-watchdog DMA wedge (A2 has detector — A2 routes to sink).
│       **Semantics change, not refactor:** A2 currently sets only Linux
│       marker; routing through unified primitive ALSO sets RM-side marker.
│       Test the resulting behavior on dmabuf/UVM consumers.
└── [g] Kernel PCI probe-time BAR-failure (NEW) — check pci_resource_flags
        & IORESOURCE_UNSET at nv_pci_probe entry, via existing
        nv_pci_validate_bars (nv-pci.c:1918). ~5 lines.
        │
        ▼
SINK-STATE PRIMITIVE: cleanupGpuLostStateAtomic(pGpu, detector_class)
   ├── Idempotent (atomic test-and-set on per-GPU flag)
   ├── Calls gpuSetDisconnectedProperties (sets PDB_PROP_GPU_IS_LOST)
   ├── Calls os_pci_set_disconnected (sets pci_channel_io_perm_failure)
   ├── Emits ONE canonical NV_GPU_LOST_LOG_ONCE per detector_class
   ├── Per-GPU within our driver's state machines
   └── DOES NOT prevent nvGpuOpsReportFatalError's system-wide flag
       (sysSetRecoveryRebootRequired) — see follow-up F1.
        │
        ▼
QUERY PREDICATE: osIsGpuBusDead(pGpu) (C5 v1 — already exists)
        │
        ▼
ENTRY-POINT GUARDS (10 guards)
├── [G1] osDevReadReg{08,16,32}             (C5 v1 — done)
├── [G2] _issueRpcAndWait                   (C5 v1 — done)
├── [G3] _issueRpcAndWaitLarge              (NEW gap from audit, multi-chunk RPC)
├── [G4] rpcRmApi{Alloc,Control,Free}_GSP   (C5 v1 — done)
├── [G5] (REDESIGNED) Rate-limit + early-exit at API_GPU_ATTACHED_SANITY_CHECK
│       call sites. The macro is a predicate inlined at 20+ sites
│       (g_gpu_nvoc.h:5883), NOT a centralized gate. Once sink is set,
│       gpuSetDisconnectedProperties already clears PDB_PROP_GPU_IS_CONNECTED
│       so the macro evaluates FALSE. The real #776 issue is 10 call sites
│       each LEVEL_ERROR + re-loop without rate-limiting. Fix: per-site
│       rate-limit (NV_GPU_LOST_LOG_ONCE) at the loud callers, NOT a "route
│       through a central gate" change.
├── [G6] rcdbAddRmGpuDump / RmLogGpuCrash   (C5 v1 partial — extend to RmLogGpuCrash for #461)
├── [G7] rm_set_external_kernel_client_count (NEW — actual WARN site at
│       nv.c:5445; guard tolerates IS_LOST instead of WARN_ON, addresses
│       #916 WARN class). nvidia_close / nvidia_dev_put may need additional
│       guard at file_operations.release path; verify against #1134 hang.
├── [G8] Chip-reset consumer-retry           (NEW — LOCATION TBD; six producer
│       sites of NV_ERR_RESET_REQUIRED in tree {heap.c:3960, kernel_gsp.c
│       :302/488/1885, message_queue_cpu.c:384, alloc_free.c:822} but the
│       #1134 consumer-retry loop site needs identification before this
│       guard can be specified or sized)
├── [G9] kfsp arithmetic invariants         (NEW site-local — #12 from audit)
└── [G10] DRM-side teardown                  (NEW — nv_drm_remove
        (nvidia-drm-drv.c:2187) and KMS resource-release-on-disconnected GPU.
        Grep confirmed zero sink-awareness in nvidia-drm-drv.c today.
        Addresses #1134's actual nvidia_drm teardown hang. ~10 lines.)

REDUNDANCY ELIMINATION
├── Per-site NV_GPU_LOST_LOG_ONCE latches at 8 v3 conversion sites retire
│   (consolidated into ONE canonical log per detector_class at sink)
├── NV_ASSERT_OR_GPU_LOST family kept at the 10 cleanup sites (NOT
│   redundant — funnels short-circuit upstream but cleanup must complete,
│   so cleanup-path asserts must accept NV_ERR_GPU_IS_LOST)
└── 2 of 3 macro variants potentially consolidatable if predicate body
    is the only differentiator (cosmetic; defer)
```

### Why each guard exists

Each entry-point guard is justified by either (a) a cited issue showing the path wedging in the wild, or (b) audit evidence that the funnel below it can't cover the entry. No speculative guards.

| Guard | Justified by | What it does |
|---|---|---|
| G1 osDevReadReg{08,16,32} | C5 v1 design + audit funnel #1 | Short-circuits MMIO reads when sink set; also detects fresh dead-bus and sets sink |
| G2 _issueRpcAndWait | C5 v1 design + audit funnel #3 | Returns NV_ERR_GPU_IS_LOST without issuing RPC when sink set |
| G3 _issueRpcAndWaitLarge | Audit gap (multi-chunk Control RPCs bypass G2) | Mirror G2 semantics |
| G4 rpcRmApi*_GSP | C5 v1 design (asymmetric: Free → NV_OK so cleanup completes; Alloc/Control → IS_LOST) | Per-call-type sink-aware response |
| G5 API_GPU_ATTACHED_SANITY_CHECK callers (rate-limit) | #776 (10× in 1s LEVEL_ERROR + re-loop) | Macro evaluates FALSE once sink is set (via PDB_PROP_GPU_IS_CONNECTED cleared by gpuSetDisconnectedProperties); the gap is rate-limiting at the 10 noisy call sites. NOT a "single central gate" change |
| G6 RmLogGpuCrash | #461 (crash-dump RPC fn 78 DUMP_PROTOBUF_COMPONENT triggers Xid 119 cascade) | Crash-dump paths must check sink before issuing diagnostic RPCs |
| G7 rm_set_external_kernel_client_count | #916 (WARN_ON at nv.c:5445), #1134 (close-path hang contribution) | Tolerate NV_ERR_GPU_IS_LOST instead of WARN_ON; document whether additional file_operations.release-path guard is needed |
| G8 Chip-reset consumer-retry | #1134 (`NV_ERR_RESET_REQUIRED` precondition loop) | LOCATION TBD: six producer sites of RESET_REQUIRED exist; the actual #1134 consumer-retry loop site must be identified during implementation Phase 1 before this guard can be sized or coded |
| G9 kfsp arithmetic invariants | E07 Run 3 site #12 + audit (sentinel value can't satisfy `end - start == wordsWritten`) | Site-local early-return on dead-bus first-read; OR top-of-function osIsGpuBusDead check |
| G10 DRM teardown | #1134 (`nvidia_drm` teardown hangs >5min); grep confirmed zero `GPU_IS_LOST` / `os_pci_is_disconnected` in `kernel-open/nvidia-drm/*.c` | `nv_drm_remove` (`nvidia-drm-drv.c:2187`) and KMS resource-release-on-disconnected-GPU need sink-checks to avoid hardware touches during teardown |

### Why per-GPU not global — and what it does NOT fix

Per-GPU sink-state is the right design choice for OUR driver's state machines: detection in one OBJGPU should not cause cleanup or recovery in another. C5 v1's `osIsGpuBusDead(pGpu)` and `gpuSetDisconnectedProperties(pGpu)` are already per-GPU; the v4 sink primitive preserves that.

**Critical caveat surfaced by adversarial review:** issue #979 jciolek (external 5090 loss rebooted internal 3060) is NOT addressed by per-GPU sink alone. The escalation path is `nvGpuOpsReportFatalError` at `src/nvidia/src/kernel/rmapi/nv_gpu_ops.c:11678`:

```c
void nvGpuOpsReportFatalError(NV_STATUS error)   /* no pGpu parameter */
{
    OBJSYS *pSys = SYS_GET_INSTANCE();
    NV_PRINTF(LEVEL_ERROR, "uvm encountered global fatal error 0x%x, …\n", error);
    sysSetRecoveryRebootRequired(pSys, NV_TRUE);  /* system-wide flag */
}
```

This function is in OUR tree (open-source RM code, modifiable), takes no `pGpu`, and unconditionally sets a system-global reboot flag. A per-GPU sink in `cleanupGpuLostStateAtomic` cannot stop this escalation because the call site never reaches the sink primitive — the global flag fires regardless. **Tracked as follow-up F1; out of scope for v4 base architecture.** Pursuing F1 means:

- Extending `nvGpuOpsReportFatalError`'s signature to accept `OBJGPU *pGpu` (or `NvU32 gpuId`)
- Updating callers (`rm-gpu-ops.c:918` + UVM ABI shim) to pass the originating GPU
- Gating `sysSetRecoveryRebootRequired` on whether a non-lost GPU remains in the system (gpumgr enumeration)
- Estimated +10-15 lines + API-shape consequences requiring UVM-side coordination

The v4 architecture does not block F1, but the #979 jciolek cross-contamination class remains an unaddressed failure mode until F1 lands.

## Cross-patch impact analysis

The v4 architecture is not just a C5 amendment — it consolidates primitives that today are scattered across the patch series. Each existing patch becomes simpler or more coherent.

### C2 (AER internal-unmask) — unchanged surface, cleaner role

C2's job is to make Internal Errors visible to the AER state machine. Unchanged. But in v4, the visible errors flow into the sink primitive via the wired `error_detected` callback (C4 → sink), making C2's contribution observable in a coherent way. No code delta.

### C3 (gpu-lost-retry) — no delta (reattributed)

**Correction from review:** the two-line propagation (`gpuSetDisconnectedProperties` + `os_pci_set_disconnected`) is NOT in C3's diff. C3 adds only the retry loop (`for (retry = 0; retry < NV_GPU_LOST_RETRY_COUNT; …)`). Both marker-setter calls live in C5's `osHandleGpuLost` hunk. The "−1 line" collapse should be charged to C5, not C3.

- **Code:** 0 lines in C3.
- **Behavior:** Unchanged — retry semantics intact.

### C4 (err-handlers-scaffold) — wire existing callback to sink + layering decision

**Correction from review:** C4 is NOT scaffold. `nv_pci_error_detected` at `kernel-open/nvidia/nv-pci.c:2868` already implements a ~60-line callback body — gate check, fire-count increment, uevent emission, returns `PCI_ERS_RESULT_NEED_RESET` or `PCI_ERS_RESULT_DISCONNECT`. The body is wired to addon `tb_egpu_recover_*` primitives via `tb_egpu_recover_pre_schedule_gates`. The v4 delta is:

- Adding a single `cleanupGpuLostStateAtomic(pGpu, DETECTOR_AER_FATAL)` call inside the existing callback, on the `PCI_ERS_RESULT_DISCONNECT` branch.
- **Layering decision required:** `cleanupGpuLostStateAtomic` is a sink primitive. If it lives in base (C5), then C4 (base) calling it is clean. If it lives in addon, then C4 calling addon-owned primitive breaks the C+E/A layer constraint. **Recommendation:** sink primitive owned by C5 (base layer); A2 (addon) and C4 (base) both call it; this preserves the layering.

- **Code:** +1 line of call insertion in C4. The new sink primitive code itself counts under C5.
- **Behavior:** Earliest possible sink-trigger (AER root-complex signal); works for any PCIe surprise removal that AER catches before the driver does.

### A1 (pcie-primitives, renamed from tb_egpu_recover_*) — unchanged

Primitives are recovery-action building blocks. Recovery actions read sink-state but don't set it. No delta.

### A2 (bus-loss-watchdog Q-watchdog) — detector becomes sink-trigger (semantics change)

A2 already detects DMA-path silent wedges via kthread + currently calls `os_pci_set_disconnected(nv->handle)` only (sets Linux marker, not RM marker). In v4, A2 calls `cleanupGpuLostStateAtomic(pGpu, DETECTOR_QWATCHDOG_DMA_WEDGE)` instead, which sets BOTH markers.

- **Code:** +2 lines in A2 (replace `os_pci_set_disconnected` call with `cleanupGpuLostStateAtomic`; possibly +1 for pGpu lookup if not already in scope).
- **Behavior change (NOT pure refactor):** Q-watchdog detection now ALSO sets `PDB_PROP_GPU_IS_LOST`. This affects any RM state machine that keys on the RM marker (UVM consumers, GR teardown, etc.). The change is correct (RM should know about DMA wedges) but requires soak validation; could perturb downstream state machines that previously only observed Linux marker.

### A3 (recovery) — minimal addition (already bounded)

**Correction from review:** A3 already has bounded retry via `atomic_inc_return(&st->attempt_count)` against `NVreg_TbEgpuRecoverMaxAttempts` (A3-recovery.patch:514, 637, 1255) with GATE_SURRENDER semantics. The v4 delta is one sink-query at the top of `tb_egpu_recover_pre_schedule_gates` so that if sink is already set before A3 starts, A3 surrenders immediately without consuming a retry budget.

- **Code:** +3 lines in A3 (single sink-query + early-surrender in pre_schedule_gates).
- **Behavior:** Recovery short-circuits faster when sink is already set; eliminates wasted retry-budget consumption on already-known-dead GPUs.

### A4 (close-path telemetry) — telemetry becomes coherent

A4 today logs close-path observations. In v4, A4's telemetry observes sink-state transitions, giving a single canonical timeline of "GPU $i became lost via detector $X at $T → cleanup paths invoked → recovery attempted Y times → final state Z" instead of scattered per-site logs. The log volume drops (per-detector-class log-once instead of per-site log-once × many sites).

- **Code:** -5 lines in A4 (consolidate observation points).
- **Behavior:** Cleaner telemetry, easier incident triage.

### C5 (parent — this is C5's home patch)

C5 v1's primitives stay. C5 v3's 8 site conversions stay (cleanup paths still need to accept IS_LOST). C5 v4 adds:
- Sink primitive `cleanupGpuLostStateAtomic` consolidating dual-marker write + canonical log (~15 lines for the primitive itself; absorbs C3's misattributed "−1" by consolidating the C5 osHandleGpuLost hunk)
- Detector classification enum (DETECTOR_MMIO_DEAD / DETECTOR_OSHANDLEGPULOST_RETRY_EXHAUSTED / DETECTOR_GSP_HEARTBEAT_TIMEOUT / DETECTOR_AER_FATAL / DETECTOR_QWATCHDOG_DMA_WEDGE / DETECTOR_PROBE_BAR_FAILURE / DETECTOR_SYSFS_DISCONNECTED) — ~8 lines for the enum
- New detectors wired in C5: GSP heartbeat hook at `_kgspRpcRecvPoll` fatal branch (~2 lines, not 10 — see I6 correction), probe-time BAR-failure hook at nv_pci_probe via existing `nv_pci_validate_bars` (~5 lines, not 15 — see I7 correction)
- G3 `_issueRpcAndWaitLarge` guard (~5 lines)
- G5 rate-limiting at hot API_GPU_ATTACHED_SANITY_CHECK callers (~5 lines — per-site rate-limit, NOT a single central route)
- G6 RmLogGpuCrash sink-check (~5 lines extension to existing rcdbAddRmGpuDump)
- G7 `rm_set_external_kernel_client_count` tolerates IS_LOST (~3 lines — single WARN_ON → tolerate path)
- G8 chip-reset consumer-retry guard (~? lines — LOCATION TBD, see I8 finding; cannot size until #1134 consumer-retry site is identified in Phase 1)
- G9 kfsp arithmetic-invariant guard (~5 lines site-local)
- G10 DRM teardown guard (~10 lines — `nv_drm_remove` + KMS resource-release-on-disconnected-GPU)
- Consolidated per-site logging into per-detector logging — retire 8 per-site `NV_GPU_LOST_LOG_ONCE` latches (~40 lines deleted)

C5 net (with G8 unknown deferred): **+58 lines added, -40 lines deleted = +18 lines** (excludes G8 which awaits Phase 1 site identification).

## Aggregate code delta

**Revised after review.** Original v1 estimate was +26 lines; many per-patch claims were misattributed or hid semantics changes. Source-checked revisions below:

| Patch | Δ lines | Rationale (revised) |
|---|---|---|
| C2 | 0 | Unchanged |
| C3 | 0 | Two-line propagation was misattributed; lines live in C5, not C3 |
| C4 | +1 | Single `cleanupGpuLostStateAtomic` call inserted into existing 60-line `nv_pci_error_detected` body (NOT "adding a body" — body exists) |
| C5 | +18 | Sink primitive + 6 new guards + retired per-site logging; G8 (chip-reset) deferred for Phase 1 site identification |
| A1 | 0 | Unchanged |
| A2 | +2 | Detector → sink primitive; **flagged as semantics change** (now sets RM marker too) |
| A3 | +3 | Single sink-query in pre_schedule_gates (already bounded; reduced from original +10) |
| A4 | ~-2 to -5 | Telemetry consolidation — depends on whether A4 currently has hooks to consume the canonical log; aspirational pending implementation verification |
| **TOTAL** | **+15 to +18 lines** | **vs ~230 added by C5 v1+v3** (G8 not included; F1 follow-up not included) |

**Out-of-scope:** follow-up F1 (`nvGpuOpsReportFatalError` signature change to address #979 jciolek cross-contamination) is +10-15 lines additional if pursued.

**Honest framing (revised):** v4 net delta is ~+15 to +18 lines for the base architecture. This is a modest add, well within budget for the architectural improvements gained. The "less code than v2/v3" target is achievable only if conditional Phase 2 revertability of v3 site conversions pans out (potentially −80 lines if all 8 revert; the revised intermediate honest answer is "perhaps −60 net" in that scenario; without revertability the answer is "+15 to +18, still strongly net-positive given the coverage/robustness gains").

What v4 achieves instead — and what the user's "improvement on multiple dimensions" actually asks for:

1. **6× coverage** (6 detection classes vs 1) — modest line count buys substantial failure-class coverage gain.
2. **Bounded vs unbounded surface** — v4 guard count is 10, fixed by design (G1-G10); v3 site count grew from 2 → 10 in two iterations and would grow further. Future driver-version site discovery costs v3 hours per site; costs v4 zero ONLY for sites that the funnels intercept — DRM-side, chip-reset, and arithmetic-invariant classes need their own guards (G10/G8/G9), so the bounded set is "10 guards" not "1 funnel."
3. **Single sink primitive** — replaces 4 scattered detection paths (C5 v1 post-read, C5 v3 osHandleGpuLost, A2 Q-watchdog, ad-hoc-via-AER-callback); marker-divergence bugs (the E07 Run 2 finding that motivated v3) become **structurally less likely** (not "impossible" — review pushback retained — but the single-primitive-with-test invariant is stronger than the v3 scattered-detection model).
4. **Recovery-respects-sink** — addresses the #1134 wedge-on-recovery class **at the layers we control** (A3 sink-query, G8 chip-reset consumer if identified, G10 DRM teardown). Does NOT claim "eliminates" — the consumer-retry loop site is still TBD; A3 surrender is one mitigation but not the whole story.
5. **Per-GPU isolation in our state machines** — preserves per-GPU semantics in `cleanupGpuLostStateAtomic` and all guards. Does NOT prevent `nvGpuOpsReportFatalError`'s system-global escalation (#979 jciolek class); that requires follow-up F1.
6. **Cross-patch coherence** — C3 (no delta, retry only), C4 (insert sink-call into existing body), A2 (route detector through sink) all converge on a shared primitive owned by C5; reduces coordination cost when one patch is updated.
7. **Upstream-PR fitness** — "one sink, six detectors, ten guards, with explicit base/addon ownership and identified follow-up F1" reads as a coherent design; reviewers can verify completeness from the architecture diagram, not from auditing a sweep regex.
8. **Defense-in-depth via independent upstream classes** — three independent upstream classes (PCIe-completion, PCIe-state, forward-progress). Failure of one class is masked by the other two. Within a class, detectors share upstream — so failure of one *class* is not masked; failure of one *detector within a class* often is.

**The aggregate surface improvement is real even at +15 to +18 lines.** The line count is the cost of explicit architecture over implicit sweep — and the explicit architecture pays back in every dimension that matters for a long-lived patch series.

### Shutdown ordering (module unload race)

When `nv_pci_remove` fires (module unload, hot-eject), the sink may be set during teardown by inputs (a)-(g). Implementation Phase 1 must specify:

- **Q-watchdog kthread (A2):** must observe sink and exit cleanly; cannot hold a reference that blocks teardown
- **In-flight `_kgspRpcRecvPoll`:** must short-circuit when sink fires; `wait_event_interruptible_timeout` paths should treat sink-set as wakeup
- **Pending UVM operations:** queue-flush behavior on sink-set TBD; coordinate with UVM-side coordination if F1 is pursued
- **AER `error_detected` callback re-entry:** if called multiple times during a single failure event, sink must be idempotent — confirmed by atomic test-and-set design

This subsection is a Phase 1 specification requirement, not a v4.1 architecture change.

### Conditional further reduction (defer to implementation)

If during v4 implementation the funnel completeness proof allows it:
- Some of the 8 v3 site conversions MAY be revertable (status arrives wrapped in NV_OK from upstream funnel; assertion never sees IS_LOST). Each reverted site saves ~10 lines. Up to -80 lines if all 8 revert.
- If all 8 revert, the macro family collapses to one variant (-30 lines).
- Worst-case-realistic if 4 of 8 revert: -40 lines on top of +26 = **-14 net**. This is the genuinely-less-code scenario.

Defer the revertability assessment to v4 implementation Phase 2 (after architecture lands and is verified on the rig).

## Robustness improvements (qualitative dimensions)

Beyond coverage and code count, v4 strengthens the patch series across operational dimensions:

- **Cross-class detection redundancy:** If one upstream class (e.g., PCIe-completion mechanism wedged but cables physically present) is silent, another class still fires (AER state-based or Q-watchdog forward-progress-based). v3 has no such redundancy. Within-class redundancy is weaker — see Defense-in-depth caveat above.
- **Cross-version stability:** The 6 detectors hook stable kernel/driver primitives (Linux PCI core callbacks, GSP RPC poll dispatch, MMIO read wrapper, AER handler table, watchdog kthread, probe-time BAR check). These rarely change between driver versions. The v3 sweep regex hooks raw assertion text which changes frequently.
- **Triage simplicity:** A canonical "GPU $i lost via detector $X at $T" log line per incident replaces N per-site logs. Operators triaging incidents see one line, not a flood.
- **Compositional with future work:** Future detectors (e.g., NVLink fatal, BAR-mapping rejection at IOCTL time) can be added as additional sink-trigger inputs without disturbing existing detectors or guards.
- **Testability:** The sink-state primitive is straightforwardly testable with a synthetic trigger (write to a sysfs knob → calls primitive → assert markers set → assert downstream guards short-circuit). v3 requires reproducing cascade conditions to test.

## What v4 explicitly does NOT do

To keep scope bounded and avoid speculative complexity:

- **Does not unify with eGPU-detection (E1).** E1's `is_external_gpu` detection serves a different purpose (transport-class identification for policy decisions); the sink-state is transport-agnostic.
- **Does not rework recovery semantics in A3.** A3's bus-reset attempts stay. Only the precondition (check sink before attempting reset) is added.
- **Does not address uvm global fatal 0x60 propagation in upstream uvm code.** The fix is to ensure our sink-state is per-GPU; the upstream uvm escalation is NVIDIA-owned. We document the symptom (jciolek case) and ensure our half doesn't contribute.
- **Does not register new IOCTLs or sysfs.** No userspace ABI change.
- **Does not introduce module parameters.** All guards unconditional.
- **Does not exhaustively sweep for new assertion sites in the v4 implementation.** If a new site is discovered post-v4 that the funnel misses, it indicates a funnel gap to close — not another sweep iteration.

## Open questions / risks (revised)

1. **GSP heartbeat detector wiring.** ~~Risk: small.~~ **Revised: clearer hook point identified.** Hook at the existing fatal-classification site in `_kgspRpcRecvPoll` (kernel_gsp.c ~2868) where `_kgspClassifyGspTimeout` already decides fatal-vs-warning. Detector is ~2 lines: when `bIsFatalTimeout == NV_TRUE`, call `cleanupGpuLostStateAtomic`. No new exposed entry point needed.
2. **Probe-time BAR-failure detector.** ~~Risk: moderate.~~ **Revised: risk LOW; hook exists.** `nv_pci_validate_bars(pci_dev, NV_TRUE)` is already called at `nv_pci_probe` entry (nv-pci.c:1918). Add `pci_resource_flags(pci_dev, i) & IORESOURCE_UNSET` check early in probe. ~5 lines.
3. **API_GPU_ATTACHED_SANITY_CHECK semantic shift.** ~~Today the check is timeout-based.~~ **Revised: macro is a predicate inlined at 20+ sites, not a central gate (per I2 finding).** Once sink is set, `gpuSetDisconnectedProperties` clears `PDB_PROP_GPU_IS_CONNECTED` and the macro evaluates FALSE everywhere. The actual #776 issue is 10 noisy call sites each LEVEL_ERROR + re-loop without rate-limiting; fix is per-site rate-limit at the loud callers (G5 as revised).
4. **Recovery precondition + bounded retry interaction.** A3's bounded retry already exists. v4 adds one sink-query at top of `tb_egpu_recover_pre_schedule_gates` as fast-path early-surrender. Sink-set always wins. ~3 lines.
5. **Revertability of v3 site conversions.** Assessment deferred to implementation Phase 2 (not Phase end as v1 said — promoted earlier per M3 recommendation). The +15 to +18 vs −60 swing decides whether v4 looks like an improvement to upstream reviewers, so the revertability question is on the critical path.
6. **G8 chip-reset consumer-retry site identification.** Cannot size G8 until the actual #1134 consumer-retry loop is located. Six `NV_ERR_RESET_REQUIRED` producer sites exist in tree but the consumer-retry that triggers the loop is unidentified. Phase 1 must include this investigation.
7. **C4 / sink-primitive base-vs-addon layering.** `cleanupGpuLostStateAtomic` owned by C5 (base) is recommended; C4 (base) calls it cleanly; A2 (addon) calls upward into base which is also clean per project geometry. Confirm during implementation that this layering holds (no addon-owned primitives called from base).
8. **F1 (`nvGpuOpsReportFatalError` system-global escalation) scope decision.** Pursue as part of MISSION-1 v4 or defer to a follow-on patch series? F1 has API-shape consequences for UVM-side coordination; user direction needed.

## Follow-up F1: `nvGpuOpsReportFatalError` signature change (out of scope for v4 base)

**Why this is its own patch:** `nvGpuOpsReportFatalError` takes `NV_STATUS error` with no GPU identity, then calls `sysSetRecoveryRebootRequired(pSys, NV_TRUE)` — system-wide. The #979 jciolek cross-contamination (external 5090 loss → Xid 154 on internal 3060) happens through this function regardless of our sink-state design. Fixing it requires:

- Signature: `nvGpuOpsReportFatalError(NV_STATUS error)` → `nvGpuOpsReportFatalError(OBJGPU *pGpu, NV_STATUS error)` (or NvU32 gpuId)
- Caller update: `rm_gpu_ops_report_fatal_error` (`rm-gpu-ops.c:918`) must pass the originating GPU
- UVM ABI shim: `nvGpuOpsReportFatalError` is called from UVM-side; the C-ABI between RM and UVM has to be updated in lockstep
- Gating: `sysSetRecoveryRebootRequired` should only fire if no non-lost GPU remains; query gpumgr to enumerate
- Scope: ~10-15 lines plus the ABI coordination

**Decision needed:** include F1 in MISSION-1 v4 implementation, or defer to a follow-up patch series after v4 base lands? My recommendation: defer F1 — it's a meaningful piece of work with cross-component coordination that warrants its own design + review cycle, and v4 base is already substantial. F1 can stay tracked as an open mitigation for the #979 jciolek case.

## Decision-doc impact

If v4 is the chosen Option 1 implementation strategy, this document supersedes the abbreviated "What the patches look like" section in [[decision-architecture-class-localization]] under Option 1. The decision doc's Option 1 section can be retained as the framing-level overview; this doc is the implementation-level architecture.

## Status

✅ Per-issue design implications mapped (9 issues → design inputs)
✅ Architecture proposed (6 detection inputs, 1 sink primitive, 10 entry-point guards)
✅ Cross-patch impact enumerated (C2/C3/C4/A1/A2/A3/A4/C5)
✅ Aggregate code delta computed (revised: +15 to +18 lines for base architecture; F1 follow-up adds +10-15 if pursued; conditional -60 net possible if Phase 2 revertability assessment succeeds)
✅ Robustness dimensions enumerated (with corrected independence claims per review)
✅ Adversarial review pass completed; v1 → v1.1 revisions integrated
☐ User commitment to Option 1 + v4 architecture
☐ Implementation plan (Phase 1: sink primitive + 6 detectors + G8 site identification; Phase 2: revertability assessment of v3 sites + DRM teardown G10; Phase 3: deploy + soak)
☐ F1 (`nvGpuOpsReportFatalError` signature change) — decision needed: include in v4 or defer as follow-up patch series
☐ Optional cross-hardware empirical test (per decision doc Step 3)

## Revision history

- **v1** (2026-05-26): initial design synthesis. Claimed +26 lines, 5 detectors, 9 guards. Several source-level claims unverified.
- **v1.1** (2026-05-27): post-adversarial-review revisions. Corrected: per-GPU sink does NOT block uvm-global escalation (F1 follow-up scoped separately); C4 has existing body (not scaffold); C3 −1 was misattributed (lives in C5); A2 +2 hides semantics change; "5 independent detectors" overclaimed (3 upstream classes); +26 line estimate revised to +15 to +18; G10 DRM teardown added (#1134 actual hang site); G8 chip-reset consumer-retry site flagged TBD; GSP and probe-BAR hook points refined per source verification; shutdown ordering subsection added.

## Cross-references

- [[cascade-scope-audit]] — site-level audit + issue-tracker survey (input to this doc)
- [[decision-architecture-class-localization]] — Option 1 vs Option 2 decision record (this doc is Option 1's detailed design)
- `experiments/E07-cable-replug-drain-first.md` — empirical record of v3 incompleteness
- `nvidia-driver-surprise-removal-audit.md` — earlier driver-side attribution
- `c3-c5-integration-audit.md` — placement audit (C3 vs C5 boundary)
- `consumer-holders-and-teardown-future-work.md` — quiesce tooling, complementary
- Memory: [[feedback_funnel_vs_per_site_patching_2026_05_26]] — architectural-vs-site lesson
- Memory: [[feedback_premature_success_overreach_pattern_2026_05_26]] — discipline lesson
- Memory: [[feedback_targeted_comprehensive_patches]] — "ship ONE complete patch covering all identified sites"
- Memory: [[feedback_native_in_driver_hardening]] — long-term posture
- Memory: [[project_issue_979_upstream_state_2026_05_22]] — upstream filing context
- Memory: [[project_cea_patch_geometry_2026_05_22]] — Core/eGPU/Addon classification
