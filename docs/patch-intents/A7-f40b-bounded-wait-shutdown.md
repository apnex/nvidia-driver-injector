---
id: A7-f40b-bounded-wait-shutdown
layer: addon
source-branch: a7-f40b-bounded-wait-shutdown
upstream-candidacy: n/a
telemetry-tier: mandatory
status: draft
related-patches: [C5-crash-safety, E1-egpu-detection, A6-f40b-bounded-wait-open, A8-f40b-sysfs-observability]
---

# A7-f40b-bounded-wait-shutdown — Bounded-Wait Wrapper for Chip-Touching Shutdown-Path RM Calls on E1-Classified eGPUs

> **v1.2 (2026-05-30) — SH-1 reframing + budget fix to 1200 ms.** Experiment SH-1 (n=3, ledger `docs/missions/mission-1-egpu-hot-plug-hot-power/shutdown-hang-ledger.md`) measured `rm_shutdown_adapter` with a 10 s budget and found it **completes gracefully in ~600 ms** — it does NOT hang. It busy-polls a GSP shutdown handshake on `system_long_wq` (R-state, chip alive, AER clean) and finishes. The "every healthy teardown hits the rm_shutdown_adapter hang / structural" framing throughout this doc and in Test A was an **artifact of the old 200 ms budget** (~3× too tight), which guillotined a teardown that was going to succeed and declared the GPU lost prematurely. **The default is now `1200 ms` (2× the measured ~600 ms).** With 1200 ms, `rm_shutdown_adapter` completes within budget on every normal teardown — no premature GPU-lost, no sink-set, no leaked worker. A7's timeout branch is now a **true-timeout safety net** (fires only if a teardown genuinely exceeds 1200 ms), not the every-teardown behavior. The historical scenarios below describe the OLD 200 ms behavior and are retained for provenance; read them as "at the superseded 200 ms default." OPEN: why ~600 ms (SH-2).

> **v1.3 (2026-05-30) — SH-3 UAF guard + provenance correction.**
> **(a) UAF guard.** The SH-3 understand-gate proved (from source) a real latent **double use-after-free** on the rmmod path: A7's leaked worker runs `nv_f40b_shutdown_worker` + `rm_shutdown_adapter` (both nvidia.ko `.text`) on the **shared** `system_long_wq`, holds **no** module reference, and nothing flushes it on unload — so on a genuine rmmod-path timeout, `nv_pci_remove_helper` could free the module `.text` and `NV_KFREE(nvl)` while the worker still executes/dereferences them → kernel panic. `try_module_get` is ineffective (the worker is queued *after* `delete_module`'s refcount gate). **Fix:** the timeout branch now calls `flush_work(&w->work)` after the C5 sink-set, before returning — blocking until the worker has left module text. The 1200 ms budget makes the timeout branch rare; the flush makes the rare case unload-safe (worst case: a bounded hang on a genuinely-stuck MMIO → reboot, strictly safer than a UAF panic). Budget + guard are complementary.
> **(b) Provenance correction.** A7's Purpose/Provenance below cites the 2026-05-29 20:52 forensics as A7's originating attestation. SH-3 showed this **overstates the link**: A7 was **not in the 20:52 build** (that was `aorus.18-f40b`, A6-only; A7 first shipped aorus.19 ~40 min later, running vanilla synchronous `nv_shutdown_adapter` — no worker, none leaked), and the +10 s wedge timing aligns with the *new pod's container setup*, not a teardown-worker UAF. Combined with SH-1 (no hang), the 20:52 → A7 attribution does not hold. A7's real justification is now: a structural safety net for the (unmeasured, possibly-longer) rmmod-path teardown tail, made UAF-safe by the guard. See `shutdown-hang-ledger.md` and `.workflow-sh3-gate-raw-2026-05-30.json`.

## Purpose

Close the F40-shutdown-arm host-wedge first attested by the 2026-05-29 20:52 forensics report (`/var/log/mission-1-archaeology/a7-deploy-wedge-2026-05-29/FORENSICS-REPORT.md`) and validated as STRUCTURAL by A7 Test A n=2 (2026-05-29 evening, see `docs/missions/mission-1-egpu-hot-plug-hot-power/design/A7-test-A-validation-2026-05-29.md`). The original framing for A7 — based on the 20:52 forensics inference — was "F40-precondition chip + rmmod → wedge." A7 Test A n=2 sharpened this to: **every healthy rmmod on this hardware hits the rm_shutdown_adapter MMIO hang**, independent of F40-precondition state. The rmmod-path chip-touching MMIO hang is structural to this driver + chip + TB-tunnel combination, not edge-case. A7 wraps `rm_disable_adapter` and `rm_shutdown_adapter` inside `nv_shutdown_adapter` in the same bounded-wait primitive A6 uses, generalised to accept any `void (*)(nvidia_stack_t *, nv_state_t *)` RM call. On timeout, A7 declares the GPU lost via the C5 sink primitive and lets `nv_shutdown_adapter` proceed with its host-side safe-synchronous teardown so `nv_pci_remove` returns and rmmod completes — the host does not wedge. The leaked worker exits when sink-aware MMIO inside RM fails-fast. **A7 is load-bearing for production**: without it, every routine pod restart, image upgrade, or manual `rmmod nvidia` risks the host wedge the 20:52 forensics report attests to. See `docs/missions/mission-1-egpu-hot-plug-hot-power/design/in-driver-recovery-target-2026-05-29.md` for the broader detection-layer architecture A6+A7 sit inside.

## Requirements

### Requirement: Driver SHALL wrap rm_disable_adapter and rm_shutdown_adapter in a bounded-wait worker when feature is enabled and chip is E1-classified

The driver MUST schedule both `rm_disable_adapter(sp, nv)` and `rm_shutdown_adapter(sp, nv)` calls inside `nv_shutdown_adapter` onto a kernel worker (`system_long_wq`) and SHALL wait for each completion with a timeout of `NVreg_TbEgpuShutdownTimeoutMs` milliseconds when both of the following are true:

- `NVreg_TbEgpuShutdownTimeoutMs > 0` (the feature is enabled; default **1200 ms** since v1.2 — 2× the ~600 ms measured `rm_shutdown_adapter` completion, per SH-1; was 200 ms, which was ~3× too tight)
- `nv->is_external_gpu` (E1 classification — the device is a Thunderbolt-attached eGPU)

When either condition is false, the driver MUST fall through to the original synchronous RM calls. The wrapper MUST NOT introduce a worker hop or scheduling delay for non-eGPU users or when the feature is disabled.

The wrapper SHALL be implemented as a generic helper `nv_f40b_shutdown_bounded(rm_call, sp, nv, call_name)` that both call sites invoke. The helper SHALL accept a function pointer of type `void (*)(nvidia_stack_t *, nv_state_t *)` to allow reuse across additional RM calls in future patches without duplication.

#### Scenario: Bounded-wait wrapper schedules worker on E1-classified eGPU during rmmod

```
GIVEN nvidia.ko is loaded with NVreg_TbEgpuShutdownTimeoutMs=200 (default)
AND   the bound eGPU is E1-classified (nv->is_external_gpu is true)
WHEN  the operator runs rmmod nvidia and nv_pci_remove_helper reaches nv_shutdown_adapter
THEN  the rm_disable_adapter call SHALL be queued onto system_long_wq
AND   the teardown thread SHALL wait via wait_for_completion_timeout with timeout=200 ms
AND   a mandatory-tier kernel-log line "tb_egpu [F40b]: rm_disable_adapter scheduled to bounded worker (timeout=200 ms)" SHALL be emitted
AND   the same wrap SHALL be applied to the subsequent rm_shutdown_adapter call site
```

#### Scenario: Wrapper short-circuits to synchronous path on non-eGPU

```
GIVEN nvidia.ko is loaded with NVreg_TbEgpuShutdownTimeoutMs=200
AND   the device being torn down is NOT E1-classified (nv->is_external_gpu is false)
WHEN  nv_shutdown_adapter is called from nv_pci_remove_helper
THEN  the wrapper SHALL call rm_disable_adapter synchronously without queuing work
AND   no worker SHALL be allocated and no "tb_egpu [F40b]" log line SHALL be emitted for either rm_* call
AND   the teardown behaviour SHALL be byte-identical to the pre-A7 code
```

#### Scenario: Wrapper short-circuits to synchronous path when feature is disabled

```
GIVEN nvidia.ko is loaded with NVreg_TbEgpuShutdownTimeoutMs=0
AND   the device is E1-classified
WHEN  nv_shutdown_adapter is called
THEN  the wrapper SHALL call both rm_* functions synchronously without queuing work
AND   no worker SHALL be allocated and no "tb_egpu [F40b]" log line SHALL be emitted for either call
```

#### Scenario: Allocation failure falls through synchronously

```
GIVEN nvidia.ko is loaded with the feature enabled and the chip is E1-classified
AND   the kernel is under memory pressure such that kzalloc(GFP_KERNEL) for the work struct fails
WHEN  the wrapper attempts to allocate the work struct and receives NULL
THEN  the wrapper SHALL call the rm_* function synchronously
AND   no worker SHALL be queued
AND   the teardown SHALL proceed as if the feature were disabled (the hang risk is identical to pre-A7 baseline; under memory pressure the worker indirection would add risk, not subtract it)
```

### Requirement: On worker completion within timeout SHALL pass through and proceed to next teardown step

When the worker's RM call returns before the timeout expires, the wrapper MUST emit a mandatory-tier "completed within budget" log line and return to `nv_shutdown_adapter`, which SHALL proceed to its next teardown step (host-side kthread stops, IRQ teardown, mutex frees, or the second wrapped RM call as applicable).

The wrapper MUST NOT translate or interpret the void RM return — the call signature is `void` and the wrapper SHALL NOT introduce error propagation that doesn't exist in the original.

#### Scenario: rm_disable_adapter succeeds within budget

```
GIVEN the worker is running rm_disable_adapter on an E1-classified eGPU
WHEN  the call returns within the timeout budget (typically tens of ms on healthy hardware)
THEN  wait_for_completion_timeout SHALL return a positive jiffies-remaining value
AND   the wrapper SHALL emit "tb_egpu [F40b]: rm_disable_adapter completed within budget"
AND   the wrapper SHALL return to nv_shutdown_adapter without further action
AND   nv_shutdown_adapter SHALL proceed to nv_kthread_q_stop on the bottom_half_q (next teardown step)
```

#### Scenario: rm_shutdown_adapter completes-fast post-sink-set (PREDICTED, not yet validated)

```
GIVEN the first wrapper (rm_disable_adapter) timed out and set the C5 sink, OR A6 has set the sink earlier in the boot via a cycle-2 open
AND   nv_shutdown_adapter has finished host-side teardown steps and reaches the rm_shutdown_adapter wrap
WHEN  the second wrapper schedules rm_shutdown_adapter
THEN  RM closed code SHOULD observe the sink at the next sink-aware check and fast-fail
AND   the worker SHOULD return quickly (well within the 200 ms budget)
AND   the wrapper SHOULD emit "tb_egpu [F40b]: rm_shutdown_adapter completed within budget"
AND   no second sink-set SHOULD be required (the sink is already set)

Validation status: Test A n=2 (healthy chip, no prior sink-set) observed rm_shutdown_adapter timing out at 200 ms. This scenario predicts that a prior sink-set causes rm_shutdown_adapter to fast-fail instead — but tonight's data is consistent with TWO equally-valid interpretations:
  (a) The structural hang IS sink-state-dependent and a prior sink would short-circuit it (Test B will validate).
  (b) The structural hang is INDEPENDENT of sink-state and rm_shutdown_adapter would time out even with a prior sink. In this case A7's timeout branch fires twice (once for sink-set, once for the structural hang), still containing the wedge.
Both interpretations preserve host-survival. SHOULD vs MUST language used here because the fast-pass is a secondary optimisation; the load-bearing guarantee is the timeout branch.
```

### Requirement: On timeout SHALL declare GPU lost via C5 sink and skip the wedged call so nv_shutdown_adapter continues

When the worker has not completed within `NVreg_TbEgpuShutdownTimeoutMs` milliseconds, the wrapper MUST:

1. Emit a mandatory-tier kernel-log line identifying the F40b shutdown-path timeout (per Telemetry contract).
2. Call `rm_cleanup_gpu_lost_state(sp, nv, NV_GPU_LOST_DETECTOR_AER_FATAL)` to invoke the C5 sink primitive. This sets `PDB_PROP_GPU_IS_LOST` and propagates the lost-state to all subsequent RM operations on this device, including the in-flight wedged worker and the upcoming `rm_shutdown_adapter` call.
3. Drop the wrapper's reference to the heap-allocated work struct via `nv_f40b_shutdown_work_put` (decrement-and-free).
4. Return to `nv_shutdown_adapter`, which SHALL proceed with its next teardown step (or finish if this was the last RM call).

The wrapper MUST NOT attempt to cancel, join, or otherwise interfere with the in-flight worker. The leaked worker is expected to exit on its own when its next sink-aware MMIO check observes the C5 sink and aborts. The refcount-2 / decrement-and-free protocol (identical to A6's protocol) ensures the work struct outlives both the wrapper's return and the worker's eventual exit without leaks.

The detector class passed to `rm_cleanup_gpu_lost_state` SHALL be `NV_GPU_LOST_DETECTOR_AER_FATAL` (value 3) as a placeholder, matching A6's placeholder usage. A future patch (A9) introduces a dedicated `NV_GPU_LOST_DETECTOR_F40B_SHUTDOWN_TIMEOUT` detector class; until then, AER_FATAL is the closest existing semantically-correct detector class.

#### Scenario: rmmod on healthy chip — rm_shutdown_adapter times out, A7 contains it (VALIDATED n=2 in Test A 2026-05-29)

```
GIVEN nvidia.ko is loaded with NVreg_TbEgpuShutdownTimeoutMs=200 (default)
AND   the eGPU is in healthy state (BAR1=32GiB, P8, no prior F40 fire, no userspace-recovered substrate, no sink set)
AND   persistence mode is engaged
WHEN  the operator runs `kubectl exec <injector-pod> -- /entrypoint.sh uninstall` and nv_pci_remove_helper reaches nv_shutdown_adapter
THEN  the rm_disable_adapter wrapper SHALL emit "scheduled to bounded worker (timeout=200 ms)"
AND   rm_disable_adapter SHALL return within budget (chip is responsive at this point in the teardown)
AND   the wrapper SHALL emit "rm_disable_adapter completed within budget"
AND   nv_shutdown_adapter SHALL proceed with host-side teardown (kthread stops, IRQ teardown, MSI-X mutex frees)
AND   the rm_shutdown_adapter wrapper SHALL emit "scheduled to bounded worker (timeout=200 ms)"
AND   rm_shutdown_adapter SHALL NOT return within budget — wait_for_completion_timeout SHALL return 0 after approximately 200 ms
AND   the wrapper SHALL emit "rm_shutdown_adapter timed out after 200 ms — declaring GPU lost (detector_class=3 DETECTOR_AER_FATAL); worker leaked, will exit when MMIO fails-fast post-sink-set"
AND   the wrapper SHALL call rm_cleanup_gpu_lost_state with NV_GPU_LOST_DETECTOR_AER_FATAL
AND   nv_shutdown_adapter SHALL proceed with remaining teardown (FLR check, NUMA memory queue stop)
AND   nv_pci_remove_helper SHALL continue and complete
AND   "nvidia-nvlink: Unregistered Nvlink Core" SHALL appear in the kernel log
AND   rmmod SHALL return with exit code 0 within ~1 second wall-clock
AND   the host SHALL remain responsive (no kernel-wide wedge, no reboot required)
AND   chip substrate SHALL remain healthy (BAR1=32GiB) for subsequent modprobe to bind cleanly

Observation 2026-05-29 21:56:55 (n=1) and 22:06:35 (n=2): byte-identical kernel-log signatures across both runs; chip recovered cleanly on each reload.
```

#### Scenario: rmmod on F40-precondition (userspace-recovered) chip — A7 still contains the wedge

```
GIVEN nvidia.ko is loaded with NVreg_TbEgpuShutdownTimeoutMs=200 and the eGPU is in the F40-precondition state (userspace-recovered)
WHEN  the operator runs `rmmod nvidia` and nv_pci_remove_helper reaches nv_shutdown_adapter
THEN  rm_disable_adapter MAY time out (chip-state-dependent — Test A n=2 saw rm_disable_adapter complete within budget on healthy chips, but F40-precondition chips MAY behave differently)
AND   IF rm_disable_adapter times out, the wrapper SHALL set sink and continue per the timeout requirement above
AND   the rm_shutdown_adapter wrapper SHALL emit "scheduled to bounded worker (timeout=200 ms)"
AND   rm_shutdown_adapter SHALL either time out (and A7 sets sink) OR fast-fail (if A6 has already set sink from a prior cycle-2 open in the same boot)
AND   nv_pci_remove_helper SHALL continue and complete in either case
AND   rmmod SHALL return with exit code 0 within ~500 ms wall-clock
AND   the host SHALL remain responsive (no kernel-wide wedge, no reboot required)

Note: this scenario is NOT yet validated empirically. The 2026-05-29 20:52 forensics report is the only documented F40-precondition + rmmod event, and that wedged BEFORE A7 was deployed. Test B (planned) will exercise this scenario to verify the predicted "rm_shutdown_adapter fast-fails after A6 sink-set" behaviour or refute it (in which case A7's timeout still contains the wedge — host-survival is the load-bearing guarantee, fast-pass is a secondary optimisation).
```

#### Scenario: rmmod after F40b open fired — chip already sink-set, A7 fast-passes

```
GIVEN A6 has already fired (F40b open-path timeout, sink set in earlier nvidia_open syscall)
AND   the operator runs rmmod nvidia immediately after
WHEN  nv_shutdown_adapter is called and reaches the rm_disable_adapter wrap
THEN  RM closed code SHALL observe the existing sink and fast-fail
AND   the worker SHALL return well within the 200 ms budget
AND   the wrapper SHALL emit "tb_egpu [F40b]: rm_disable_adapter completed within budget"
AND   no second sink-set SHALL be needed
AND   rmmod SHALL complete without any timeout-triggered wedge
```

### Requirement: Refcounted work struct SHALL not leak on either happy or timeout path

The heap-allocated `struct nv_f40b_shutdown_work` MUST be initialised with `atomic_set(&w->refcount, 2)` — one reference for the caller (the wrapper) and one for the worker. Both the wrapper and the worker MUST call `nv_f40b_shutdown_work_put` exactly once, which atomically decrements the refcount and frees the struct when the count reaches zero. The protocol is identical to A6's.

#### Scenario: Refcount on happy path

```
GIVEN the worker completes within budget
WHEN  the wrapper observes wait_for_completion_timeout > 0
THEN  the worker has already called nv_f40b_shutdown_work_put (refcount 2 -> 1) before signalling completion
AND   the wrapper SHALL call nv_f40b_shutdown_work_put after observing completion, dropping refcount 1 -> 0
AND   kfree(w) SHALL be called by the wrapper's put
AND   no use-after-free SHALL occur
```

#### Scenario: Refcount on timeout path

```
GIVEN the worker has not yet completed at the timeout
WHEN  the wrapper observes wait_for_completion_timeout == 0
THEN  the wrapper SHALL call nv_f40b_shutdown_work_put (refcount 2 -> 1), retaining the struct for the worker's eventual completion
AND   the worker SHALL eventually exit (when MMIO fails-fast post-sink-set) and call nv_f40b_shutdown_work_put (refcount 1 -> 0)
AND   kfree(w) SHALL be called by the worker's put
AND   no leak SHALL occur even though the worker exits after the wrapper has returned
```

## Scope boundary

- A7 SHALL NOT wrap chip-touching MMIO on paths other than `nv_shutdown_adapter`. Other potential chip-touching sites (probe-path post-reset, runtime power management, ACPI events) are out of scope for this patch and may be addressed by future patches if attested by forensics.
- A7 SHALL NOT attempt recovery. On timeout, the GPU is declared lost via the C5 sink primitive; the chip remains in a lost state until the operator's external recovery sequence runs OR A9's in-driver recovery state machine fires. The primary value of A7 is **host-survival during rmmod**, not chip-recovery.
- A7 SHALL NOT introduce a per-PCI-device sysfs observability surface. That surface is implemented by A8 (which hooks A6 + A7's timeout paths to update per-device counters and `tb_egpu_state`).
- A7 SHALL NOT cancel the in-flight worker. The leaked-worker design is intentional and matches A6: cancel-on-timeout would require sleep-cancel-safe MMIO, which the chip does not provide on the wedge path. Sink-aware fail-fast inside the worker is the supported termination path.
- A7 SHALL NOT change the order or content of the host-side teardown steps in `nv_shutdown_adapter` (kthread stops, IRQ teardown, MSI/MSI-X disable, mutex frees). It only wraps the two chip-touching RM calls.
- A7 SHALL NOT special-case the close-path caller (`nv_stop_device → nv_shutdown_adapter`). Because the wrap lives inside `nv_shutdown_adapter`, the close-path caller also benefits at no extra cost; the close-path bug class is primarily mitigated by C5, and A7's wrap is additive insurance there.
- A7 SHALL NOT modify `rm_disable_adapter`, `rm_shutdown_adapter`, or any closed-source RM code. The wrappers sit entirely in the open kernel-open driver layer.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| **rm_* scheduled to bounded worker (mandatory tier)** | **`NV_DBG_ERRORS` (err)** | `"NVRM: tb_egpu [F40b]: %s scheduled to bounded worker (timeout=%u ms)\n"` |
| **rm_* completed within budget (mandatory tier)** | **`NV_DBG_ERRORS` (err)** | `"NVRM: tb_egpu [F40b]: %s completed within budget\n"` |
| **rm_* timed out — sink-set + skip (mandatory tier)** | **`NV_DBG_ERRORS` (err)** | `"NVRM: tb_egpu [F40b]: %s timed out after %u ms — declaring GPU lost (detector_class=3 DETECTOR_AER_FATAL); worker leaked, will exit when MMIO fails-fast post-sink-set\n"` |

The `%s` is the call name (`"rm_disable_adapter"` or `"rm_shutdown_adapter"`). All three events are mandatory-tier — every wrapped rm_* call on an E1-classified eGPU with feature enabled reaches at least one of these lines. The "scheduled" line emits unconditionally on every wrapped call; exactly one of "completed" or "timed out" follows per call.

Userspace consumers SHOULD monitor for the "timed out" line via `journalctl -k -f` to detect F40b shutdown-path fires. A8 publishes the same fact via the `tb_egpu_f40b_fires` sysfs counter (shared with A6's open-path fires — A8 increments a single counter for both A6 and A7 fires; per-path counters are out of scope for A8 v1).

## Provenance

- **Source cluster**: addon — project-local; F40-shutdown-arm wedge containment, symmetric to A6 on the open path. The F40 chip-side root cause is NVIDIA bug #979 (`project_issue_979_upstream_state_2026_05_22.md`) and is out of scope for our fork; A7 is the kernel-side containment for the rmmod path. The original trigger was the 2026-05-29 20:52 forensics report (`/var/log/mission-1-archaeology/a7-deploy-wedge-2026-05-29/FORENSICS-REPORT.md`); the n=2 validation that promoted the patch from "defense before A9 lands" to "load-bearing on every rmmod" is the 2026-05-29 evening A7 Test A.
- **Empirical validation (2026-05-29 evening, n=2)**: see `docs/missions/mission-1-egpu-hot-plug-hot-power/design/A7-test-A-validation-2026-05-29.md`. Test A ran `kubectl exec entrypoint.sh uninstall` against a healthy aorus.19 deployment twice (21:56:55 and 22:06:35); both runs produced byte-identical kernel-log signatures: rm_disable_adapter completed within budget, rm_shutdown_adapter timed out at 200 ms, sink set, nvlink unregistered, rmmod returned, host alive. Reproducibility 2/2 = 100%. The structural-vs-precondition conclusion is provisional pending wider parameter sweep (chip cold-load timing, CUDA workload history, ASPM state, etc.).
- **Vanilla baseline files**: `kernel-open/nvidia/nv.c` (insertion of `nv_f40b_shutdown_bounded`, supporting `struct nv_f40b_shutdown_work` / worker / put primitives, and `NVreg_TbEgpuShutdownTimeoutMs` immediately before `nv_shutdown_adapter`; modification of the two RM call sites inside `nv_shutdown_adapter` to invoke the wrapper).
- **Fork branch**: `a7-f40b-bounded-wait-shutdown` (in `/root/open-gpu-kernel-modules`; not yet pushed to apnex fork).
- **Injector main commit**: `429615c` (2026-05-29 evening; A7 patch + A8 patch + A6/A7/A8 intent docs + renumber + v5 deep-review placeholder).
- **Image first deployed**: `apnex/nvidia-driver-injector:595.71.05-aorus.19` (built + imported to k3s containerd + DaemonSet rolled 2026-05-29 21:35 wall-clock).
- **Upstream candidacy**: n/a — addon layer. Same rationale as A6: the bounded-wait wrapper is specific to the F40 wedge class on TB-attached Blackwell eGPUs and depends on E1's `is_external_gpu` classifier (also addon). Upstream candidacy would require both (a) C5's sink primitive in mainline form, and (b) a generalised "chip-touching MMIO can hang" framework that does not exist in upstream nvidia-open today.
- **Upstream issues**: NVIDIA bug #979 (Blackwell eGPU over Thunderbolt hard-lock) — open, no NVIDIA response in 5 months as of 2026-05-22.
