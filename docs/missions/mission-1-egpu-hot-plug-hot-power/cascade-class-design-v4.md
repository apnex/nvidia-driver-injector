# Cascade-class design synthesis — v4 architecture

**Status:** v1 2026-05-26 — design exercise informed by [[cascade-scope-audit]] + 9-issue tracker review.
**Predecessor:** v3 of C5 (per-site sweep + macro family) + scattered detection across C5/C3/A2/C4.
**Goal:** Single coherent architecture for the surprise-removal cascade class that handles all 9 cited issues with bounded surface and provable completeness, while improving aggregate properties across the patch series.

## Design goals (multi-dimensional improvement targets)

The v4 redesign must improve on v2/v3 across **all** of:

| Dimension | v2/v3 state | v4 target |
|---|---|---|
| **Coverage** | 1 cascade entry class (MMIO 0xFFFFFFFF post-read) | 5 cascade entry classes (PCI core / AER / MMIO / GSP timeout / DMA watchdog) |
| **Completeness** | Per-site sweep — unbounded; never converges; new driver versions surface new sites | Entry-point guards — bounded by design; new sites covered automatically by upstream funnel |
| **Convergence** | Scattered detection in C5 + C3 + A2 + C4; markers set inconsistently per detection path | Single sink-state primitive; all detection inputs route through it; markers always consistent |
| **Robustness** | Chip-reset path can loop forever on `NV_ERR_RESET_REQUIRED` while sink-state already set (#1134) | Recovery primitives query sink-state FIRST; bounded retry already aborts on sink-set |
| **Isolation** | Detection is per-GPU but `nvGpuOpsReportFatalError: uvm global fatal 0x60` can propagate Xid 154 to other GPUs (#979 jciolek) | Per-GPU sink-state with explicit per-GPU semantics; no global escalation paths |
| **Maintainability** | Site list grows linearly with driver-version changes; v3 sweep missed 3 sites; future sweeps will miss more | Funnel set is bounded by entry-point count, not by call-site count; survives driver-version churn |
| **Upstream-PR fitness** | "Convert 8 asserts" reads as a sweep, not a fix | "Single sink-state primitive with 5 detection inputs and N guards" reads as a coherent design |
| **Defense-in-depth depth** | One detection input — if it fails, all downstream guards are silent | 5 independent detection inputs — failure of any one is masked by the others |
| **Code surface** | C5 v1+v3 = ~230 lines added across multiple files | Target net delta vs v2/v3 ≤ 0 lines (see [aggregate code delta](#aggregate-code-delta) below) |

The goal is **NOT** "fewer lines for the sake of fewer lines." It is "the smallest architectural surface that correctly handles the entire cited failure class with provable completeness."

## Per-issue design implications

The 9 surveyed issues map to 6 design-shaping inputs. Each issue's specifics inform a concrete v4 architectural choice.

| Issue | Cascade entry | Design implication for v4 |
|---|---|---|
| [#1134](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1134) (2026-05-07, RTX 3090, PCIe x16, **595.71.05**) | BAR1 VA-exhaustion → Xid 31 → Xid 154; chip-reset itself wedges in `NV_ERR_RESET_REQUIRED` loop; `systemctl reboot` blocks | **Recovery must respect sink-state.** Once sink is set, every reset precondition must short-circuit before re-attempting `NV_ERR_RESET_REQUIRED` operations. `nvidia_drm` teardown and `nvidia_close` must observe sink. |
| [#1045](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1045) (2026-03-01, RTX 5080, PCIe x16) | Xid 62 → 45 → 119 (GSP timeout, 45s) → 154 | **GSP heartbeat timeout (Xid 119) is a dead-bus signal.** Add as sink-trigger input. The 30-45s gap between channel error and GSP timeout is a natural debounce window — fits one bounded retry per C3, no further RPCs. |
| [#979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979) (2025-12-04, multi-Blackwell, TB4/TB5/USB4 + Windows) | Xid 79 + uvm 0x60 + Xid 154; some reproducers show **AER error before any Xid** (TOSUKUi: `AER: device recovery failed`, `can't recover (no error_detected callback)`); other reproducers show **zero log signal** (silent host wedge) | **(a)** Wire `pci_error_handlers.error_detected` as sink-trigger (C4 already registers, just needs to set sink). **(b)** Q-watchdog stays as detector-of-last-resort for silent-wedge cases. **(c)** Sink-state is per-GPU; uvm global 0x60 path must respect that (jciolek's cross-contamination case). **(d)** Confirms Linux can call `error_detected` BEFORE driver-internal detection — sink-state must accept inputs from this earliest layer. |
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
DETECTION INPUTS (each calls cleanupGpuLostStateAtomic on detect)
├── [a] os.c MMIO-read post-check (C5 v1 — already done)
├── [b] C3 osHandleGpuLost retry-exhausted (C5 v3 — already done)
├── [c] GSP heartbeat timeout (NEW) — _kgspIsHeartbeatTimedOut sets sink
├── [d] AER pci_error_handlers.error_detected (NEW wiring of C4 callback)
├── [e] Q-watchdog DMA wedge (A2 has detector — A2 now sets sink)
└── [f] Kernel PCI probe-time BAR-failure (NEW) — early probe gate
        │
        ▼
SINK-STATE PRIMITIVE: cleanupGpuLostStateAtomic(pGpu, detector_class)
   ├── Idempotent (atomic test-and-set on per-GPU flag)
   ├── Calls gpuSetDisconnectedProperties (sets PDB_PROP_GPU_IS_LOST)
   ├── Calls os_pci_set_disconnected (sets pci_channel_io_perm_failure)
   ├── Emits ONE canonical NV_GPU_LOST_LOG_ONCE per detector_class
   └── Per-GPU only — never escalates to global state
        │
        ▼
QUERY PREDICATE: osIsGpuBusDead(pGpu) (C5 v1 — already exists)
        │
        ▼
ENTRY-POINT GUARDS (bounded set)
├── [G1] osDevReadReg{08,16,32}             (C5 v1 — done; covers MMIO path)
├── [G2] _issueRpcAndWait                   (C5 v1 — done; covers single RPC)
├── [G3] _issueRpcAndWaitLarge              (NEW gap from audit; covers multi-chunk RPC)
├── [G4] rpcRmApi{Alloc,Control,Free}_GSP   (C5 v1 — done; per-call-type behavior)
├── [G5] _threadNodeCheckTimeout: API_GPU_ATTACHED_SANITY_CHECK (NEW — leverage existing centralized gate from #776)
├── [G6] rcdbAddRmGpuDump / RmLogGpuCrash   (C5 v1 partial — extend to RmLogGpuCrash for #461)
├── [G7] nvidia_close / nvidia_dev_put      (NEW — #916 WARN; #1134 hang)
├── [G8] Chip-reset preconditions           (NEW — #1134 reset-itself-wedges)
└── [G9] kfsp arithmetic invariants         (NEW site-local — #12 from audit)

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
| G5 API_GPU_ATTACHED_SANITY_CHECK | #776 (10×/sec invocations already exist; just need them to consult sink instead of independent timeout) | Centralized "is GPU here" gate that already exists in driver |
| G6 RmLogGpuCrash | #461 (crash-dump RPC fn 78 DUMP_PROTOBUF_COMPONENT triggers Xid 119 cascade) | Crash-dump paths must check sink before issuing diagnostic RPCs |
| G7 nvidia_close / nvidia_dev_put | #916 (WARN at nv.c:5039), #1134 (`nvidia_drm` teardown hangs >5min) | Refcount-drop on a wedged GPU must short-circuit instead of touching hw |
| G8 Chip-reset preconditions | #1134 (`NV_ERR_RESET_REQUIRED` precondition loop), recovery wedge | Before each reset attempt, query sink; if set, bail with NV_ERR_GPU_IS_LOST (let cleanup proceed) |
| G9 kfsp arithmetic invariants | E07 Run 3 site #12 + audit (sentinel value can't satisfy `end - start == wordsWritten`) | Site-local early-return on dead-bus first-read; OR top-of-function osIsGpuBusDead check |

### Why per-GPU not global

Issue #979 jciolek showed that an external 5090 falling off the bus propagated `nvGpuOpsReportFatalError: uvm global fatal 0x60` → Xid 154 to the internal RTX 3060. That's a usability regression (one bus-loss reboots the whole machine) AND a correctness smell (the failure isn't actually global). v4's sink-state must be strictly per-`OBJGPU` (or per-`nv_state_t`); the uvm-global escalation path must be reworked or suppressed when only one device is lost. This is a **design constraint**, not an optional improvement.

## Cross-patch impact analysis

The v4 architecture is not just a C5 amendment — it consolidates primitives that today are scattered across the patch series. Each existing patch becomes simpler or more coherent.

### C2 (AER internal-unmask) — unchanged surface, cleaner role

C2's job is to make Internal Errors visible to the AER state machine. Unchanged. But in v4, the visible errors flow into the sink primitive via the wired `error_detected` callback (C4 → sink), making C2's contribution observable in a coherent way. No code delta.

### C3 (gpu-lost-retry) — primitive consolidation

C3's retry-exhausted branch currently calls `gpuSetDisconnectedProperties(pGpu)` (per vanilla) plus `os_pci_set_disconnected(nv->handle)` (per C5 v3 amendment). In v4, this collapses to a single call to the unified `cleanupGpuLostStateAtomic(pGpu, DETECTOR_OSHANDLEGPULOST_RETRY_EXHAUSTED)`. The bridge between RM-level and Linux-level markers stops being scattered across detection paths.

- **Code:** -1 line in C3 (collapse two-line propagation to one-line primitive call).
- **Behavior:** Stronger consistency guarantee — single point that sets both markers + emits canonical log.

### C4 (err-handlers-scaffold) — gains a body

C4 today is scaffold: it registers `pci_error_handlers` on `nv_pci_driver.err_handler` with minimal/empty callback bodies. In v4, the `.error_detected` callback gains a body that calls `cleanupGpuLostStateAtomic(pGpu, DETECTOR_AER_FATAL)`. This addresses issue #979 TOSUKUi's `AER: can't recover (no error_detected callback)` symptom directly.

- **Code:** +5 lines in C4 (callback body + return PCI_ERS_RESULT_DISCONNECT).
- **Behavior:** Earliest possible sink-trigger; works for any PCIe surprise removal that AER catches before the driver does.

### A1 (pcie-primitives, renamed from tb_egpu_recover_*) — unchanged

Primitives are recovery-action building blocks. Recovery actions read sink-state but don't set it. No delta.

### A2 (bus-loss-watchdog Q-watchdog) — detector becomes sink-trigger

A2 already detects DMA-path silent wedges via 5Hz kthread. In v4, on detection it calls `cleanupGpuLostStateAtomic(pGpu, DETECTOR_QWATCHDOG_DMA_WEDGE)` instead of (or in addition to) its current dedicated state machine. The Q-watchdog stays as detector-of-last-resort for the no-log-signal cases (#979 mihau81, fanfanmgz).

- **Code:** +2 lines in A2 (route detection to unified primitive).
- **Behavior:** Q-watchdog's detection now feeds the same sink as MMIO/AER/GSP-timeout — unified semantics across detector classes.

### A3 (recovery) — recovery respects sink

A3 today attempts bus-reset recovery on detection. In v4, A3 also queries sink BEFORE each reset attempt: if sink is set AND retry budget exceeded, bail with NV_ERR_GPU_IS_LOST so cleanup can proceed (addressing issue #1134's `NV_ERR_RESET_REQUIRED` precondition loop and the `nvidia_drm` teardown hang).

- **Code:** +10 lines in A3 (precondition checks before each reset attempt; bounded-retry abort logic).
- **Behavior:** Recovery is now bounded by sink-state observability, not just by attempt counter. Eliminates the #1134 wedge-on-recovery class.

### A4 (close-path telemetry) — telemetry becomes coherent

A4 today logs close-path observations. In v4, A4's telemetry observes sink-state transitions, giving a single canonical timeline of "GPU $i became lost via detector $X at $T → cleanup paths invoked → recovery attempted Y times → final state Z" instead of scattered per-site logs. The log volume drops (per-detector-class log-once instead of per-site log-once × many sites).

- **Code:** -5 lines in A4 (consolidate observation points).
- **Behavior:** Cleaner telemetry, easier incident triage.

### C5 (parent — this is C5's home patch)

C5 v1's primitives stay. C5 v3's 8 site conversions stay (cleanup paths still need to accept IS_LOST). C5 v4 adds:
- Sink primitive `cleanupGpuLostStateAtomic` consolidating dual-marker write + canonical log
- Detector classification enum (DETECTOR_MMIO_DEAD / DETECTOR_OSHANDLEGPULOST_RETRY_EXHAUSTED / DETECTOR_GSP_HEARTBEAT_TIMEOUT / DETECTOR_AER_FATAL / DETECTOR_QWATCHDOG_DMA_WEDGE / DETECTOR_PROBE_BAR_FAILURE)
- New detectors not previously wired: GSP heartbeat (~10 lines), probe-time BAR-failure (~15 lines)
- G3 _issueRpcAndWaitLarge guard (~5 lines)
- G5 API_GPU_ATTACHED_SANITY_CHECK consultation of sink (~5 lines)
- G6 RmLogGpuCrash sink-check (~5 lines extension to existing rcdbAddRmGpuDump)
- G7 nvidia_close / nvidia_dev_put sink-check (~10 lines)
- G9 kfsp arithmetic-invariant guard (~5 lines site-local)
- Consolidated per-site logging into per-detector logging — retire 8 per-site `NV_GPU_LOST_LOG_ONCE` latches (~40 lines deleted)

C5 net: **+55 lines added, -40 lines deleted = +15 lines.**

## Aggregate code delta

| Patch | Δ lines | Rationale |
|---|---|---|
| C2 | 0 | Unchanged |
| C3 | -1 | Two-line propagation → one-line primitive call |
| C4 | +5 | `error_detected` callback body |
| C5 | +15 | New detectors + new guards − retired per-site logging |
| A1 | 0 | Unchanged |
| A2 | +2 | Q-watchdog → sink primitive |
| A3 | +10 | Recovery precondition + bounded-retry abort |
| A4 | -5 | Consolidated telemetry observation points |
| **TOTAL** | **+26 lines** | **vs ~230 added by C5 v1+v3** |

**Honest framing:** v4 does NOT achieve "less code than v2/v3" in raw line count. The net delta is +26 lines (≈11% larger than C5 v1+v3 in isolation, ≈3% larger than the C+A series as a whole).

What v4 achieves instead — and what the user's "improvement on multiple dimensions" actually asks for:

1. **5× coverage** (5 detection classes vs 1) — same line count buys 5× the failure-class coverage.
2. **Bounded vs unbounded surface** — v4 guard count is 9, fixed by design; v3 site count grew from 2 → 10 in two iterations and would grow further. Future driver-version site discovery costs v3 hours per site; costs v4 zero (funnels intercept upstream).
3. **Single sink primitive** — replaces 4 scattered detection paths (C5 v1 post-read, C5 v3 osHandleGpuLost, A2 Q-watchdog, ad-hoc-via-C3); marker-divergence bugs (the E07 Run 2 finding that motivated v3) become structurally impossible.
4. **Recovery-respects-sink** — eliminates the entire #1134 wedge-on-recovery class (NV_ERR_RESET_REQUIRED loop, nvidia_drm teardown hang) which v3 doesn't address at all.
5. **Per-GPU isolation** — eliminates the #979 jciolek cross-GPU contamination class which v3 doesn't address.
6. **Cross-patch coherence** — C3, C4, A2 all converge on a shared primitive; reduces coordination cost when one patch is updated.
7. **Upstream-PR fitness** — "one sink, five detectors, nine guards" reads as a coherent design; reviewers can verify completeness from the architecture diagram, not from auditing a sweep regex.
8. **Defense-in-depth depth** — 5 detection inputs means failure of any single detector (e.g., post-read check fails because the read raced ahead of the sentinel) is still caught by another.

**The aggregate surface improvement is real even at +26 lines.** The line count is the cost of explicit architecture over implicit sweep — and the explicit architecture pays back in every dimension that matters for a long-lived patch series.

### Conditional further reduction (defer to implementation)

If during v4 implementation the funnel completeness proof allows it:
- Some of the 8 v3 site conversions MAY be revertable (status arrives wrapped in NV_OK from upstream funnel; assertion never sees IS_LOST). Each reverted site saves ~10 lines. Up to -80 lines if all 8 revert.
- If all 8 revert, the macro family collapses to one variant (-30 lines).
- Worst-case-realistic if 4 of 8 revert: -40 lines on top of +26 = **-14 net**. This is the genuinely-less-code scenario.

Defer the revertability assessment to v4 implementation Phase 2 (after architecture lands and is verified on the rig).

## Robustness improvements (qualitative dimensions)

Beyond coverage and code count, v4 strengthens the patch series across operational dimensions:

- **Detection redundancy:** If one detector misfires or is silent (e.g., interrupt-context MMIO read masked by RT throttling), another fires. v3 has no such redundancy.
- **Cross-version stability:** The 5 detectors hook stable kernel/driver primitives (Linux PCI core callbacks, GSP RPC dispatch, MMIO read wrapper, AER handler table, watchdog kthread). These rarely change between driver versions. The v3 sweep regex hooks raw assertion text which changes frequently.
- **Triage simplicity:** A canonical "GPU $i lost via detector $X at $T" log line per incident replaces N per-site logs. Operators triaging incidents see one line, not a flood.
- **Compositional with future work:** Future detectors (e.g., GR-class Xid 62, NVLink fatal, BAR-mapping rejection) can be added as additional sink-trigger inputs without disturbing existing detectors or guards. v3 has no such composition point.
- **Testability:** The sink-state primitive is straightforwardly testable with a synthetic trigger (write to a sysfs knob → calls primitive → assert markers set → assert downstream guards short-circuit). v3 requires reproducing cascade conditions to test.

## What v4 explicitly does NOT do

To keep scope bounded and avoid speculative complexity:

- **Does not unify with eGPU-detection (E1).** E1's `is_external_gpu` detection serves a different purpose (transport-class identification for policy decisions); the sink-state is transport-agnostic.
- **Does not rework recovery semantics in A3.** A3's bus-reset attempts stay. Only the precondition (check sink before attempting reset) is added.
- **Does not address uvm global fatal 0x60 propagation in upstream uvm code.** The fix is to ensure our sink-state is per-GPU; the upstream uvm escalation is NVIDIA-owned. We document the symptom (jciolek case) and ensure our half doesn't contribute.
- **Does not register new IOCTLs or sysfs.** No userspace ABI change.
- **Does not introduce module parameters.** All guards unconditional.
- **Does not exhaustively sweep for new assertion sites in the v4 implementation.** If a new site is discovered post-v4 that the funnel misses, it indicates a funnel gap to close — not another sweep iteration.

## Open questions / risks

1. **GSP heartbeat detector wiring.** `_kgspIsHeartbeatTimedOut` and `_kgspRpcRecvPoll` are private statics in `kernel_gsp.c`. Hooking them as sink-triggers may require introducing a new exposed entry point. Risk: small; pattern is similar to existing C5 v1 hooks.
2. **Probe-time BAR-failure detector.** Linux PCI calls `pci_resize_resource()` and similar in `__assign_resources_sorted` before the driver probes. Hooking pre-probe failures cleanly may need a `pci_dev` sysfs check at `nv_pci_probe` entry. Risk: moderate; needs a Linux kernel reference to confirm the right hook point.
3. **API_GPU_ATTACHED_SANITY_CHECK semantic shift.** Today the check is timeout-based (#776 shows it firing 10× in 1s). Switching it to sink-state-based changes its semantics. Risk: small if the timeout path is left as fallback when sink not yet set; high if it replaces the timeout entirely.
4. **Recovery precondition + bounded retry interaction.** A3's existing bus-reset retry already has an attempt counter. Adding sink-check creates two abort conditions. Need clear specification of which wins when (sink-set always wins).
5. **Revertability of v3 site conversions.** Assessment deferred to implementation. May save 40-80 lines OR may not (cleanup paths may still receive NV_ERR_GPU_IS_LOST from upstream funnels even when the sink is set, because the funnel chooses what to return based on call-type semantics).

## Decision-doc impact

If v4 is the chosen Option 1 implementation strategy, this document supersedes the abbreviated "What the patches look like" section in [[decision-architecture-class-localization]] under Option 1. The decision doc's Option 1 section can be retained as the framing-level overview; this doc is the implementation-level architecture.

## Status

✅ Per-issue design implications mapped (9 issues → 6 design inputs)
✅ Architecture proposed (5 detection inputs, 1 sink primitive, 9 entry-point guards)
✅ Cross-patch impact enumerated (C2/C3/C4/A1/A2/A3/A4/C5)
✅ Aggregate code delta computed (+26 lines, with -14 conditional on revertability assessment)
✅ Robustness dimensions enumerated
☐ User commitment to Option 1 + v4 architecture
☐ Implementation plan (Phase 1: sink primitive + new detectors; Phase 2: revertability assessment of v3 sites; Phase 3: deploy + soak)
☐ Optional cross-hardware empirical test (per decision doc Step 3)

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
