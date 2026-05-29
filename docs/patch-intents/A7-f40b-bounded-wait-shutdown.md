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

## Purpose

Close the F40-class rmmod-path host-wedge directly attested by the 2026-05-29 20:52 forensics report (`/var/log/mission-1-archaeology/a7-deploy-wedge-2026-05-29/FORENSICS-REPORT.md`). With A6 alone, a userspace-recovered Blackwell eGPU lets cycle-1 open succeed, cycle-2 open trigger F40b and `-EIO` cleanly — BUT a subsequent rmmod (k8s pod restart, image upgrade, manual `rmmod nvidia`) hits the same chip-touching MMIO hazard via `nv_pci_remove → nv_shutdown_adapter → rm_disable_adapter / rm_shutdown_adapter` and wedges the host. A7 wraps both of those chip-touching RM calls inside `nv_shutdown_adapter` in the same bounded-wait primitive A6 uses, generalised to accept any `void (*)(nvidia_stack_t *, nv_state_t *)` RM call. On timeout, A7 declares the GPU lost via the C5 sink primitive and lets `nv_shutdown_adapter` proceed with its host-side safe-synchronous teardown so `nv_pci_remove` returns and rmmod completes — the host does not wedge. The leaked worker exits when sink-aware MMIO inside RM fails-fast. See `docs/missions/mission-1-egpu-hot-plug-hot-power/design/in-driver-recovery-target-2026-05-29.md` for the broader detection-layer architecture A6+A7 sit inside.

## Requirements

### Requirement: Driver SHALL wrap rm_disable_adapter and rm_shutdown_adapter in a bounded-wait worker when feature is enabled and chip is E1-classified

The driver MUST schedule both `rm_disable_adapter(sp, nv)` and `rm_shutdown_adapter(sp, nv)` calls inside `nv_shutdown_adapter` onto a kernel worker (`system_long_wq`) and SHALL wait for each completion with a timeout of `NVreg_TbEgpuShutdownTimeoutMs` milliseconds when both of the following are true:

- `NVreg_TbEgpuShutdownTimeoutMs > 0` (the feature is enabled; default 200 ms)
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

#### Scenario: rm_shutdown_adapter completes-fast post-sink-set

```
GIVEN the first wrapper (rm_disable_adapter) timed out and set the C5 sink
AND   nv_shutdown_adapter has finished host-side teardown steps and reaches the rm_shutdown_adapter wrap
WHEN  the second wrapper schedules rm_shutdown_adapter
THEN  RM closed code SHALL observe the sink at the next sink-aware check and fast-fail
AND   the worker SHALL return quickly (well within the 200 ms budget)
AND   the wrapper SHALL emit "tb_egpu [F40b]: rm_shutdown_adapter completed within budget"
AND   no second sink-set SHALL be required (the sink is already set)
```

### Requirement: On timeout SHALL declare GPU lost via C5 sink and skip the wedged call so nv_shutdown_adapter continues

When the worker has not completed within `NVreg_TbEgpuShutdownTimeoutMs` milliseconds, the wrapper MUST:

1. Emit a mandatory-tier kernel-log line identifying the F40b shutdown-path timeout (per Telemetry contract).
2. Call `rm_cleanup_gpu_lost_state(sp, nv, NV_GPU_LOST_DETECTOR_AER_FATAL)` to invoke the C5 sink primitive. This sets `PDB_PROP_GPU_IS_LOST` and propagates the lost-state to all subsequent RM operations on this device, including the in-flight wedged worker and the upcoming `rm_shutdown_adapter` call.
3. Drop the wrapper's reference to the heap-allocated work struct via `nv_f40b_shutdown_work_put` (decrement-and-free).
4. Return to `nv_shutdown_adapter`, which SHALL proceed with its next teardown step (or finish if this was the last RM call).

The wrapper MUST NOT attempt to cancel, join, or otherwise interfere with the in-flight worker. The leaked worker is expected to exit on its own when its next sink-aware MMIO check observes the C5 sink and aborts. The refcount-2 / decrement-and-free protocol (identical to A6's protocol) ensures the work struct outlives both the wrapper's return and the worker's eventual exit without leaks.

The detector class passed to `rm_cleanup_gpu_lost_state` SHALL be `NV_GPU_LOST_DETECTOR_AER_FATAL` (value 3) as a placeholder, matching A6's placeholder usage. A future patch (A9) introduces a dedicated `NV_GPU_LOST_DETECTOR_F40B_SHUTDOWN_TIMEOUT` detector class; until then, AER_FATAL is the closest existing semantically-correct detector class.

#### Scenario: rmmod on wedged chip — A7 contains the wedge and lets rmmod return

```
GIVEN nvidia.ko is loaded with NVreg_TbEgpuShutdownTimeoutMs=200 and the eGPU is in the F40-precondition state (userspace-recovered)
WHEN  the operator runs `rmmod nvidia` and nv_pci_remove_helper reaches nv_shutdown_adapter, whose rm_disable_adapter wrapper schedules a worker that hangs in chip-touching MMIO
THEN  wait_for_completion_timeout SHALL return 0 after approximately 200 ms
AND   the wrapper SHALL emit "tb_egpu [F40b]: rm_disable_adapter timed out after 200 ms — declaring GPU lost (detector_class=3 DETECTOR_AER_FATAL); worker leaked, will exit when MMIO fails-fast post-sink-set"
AND   the wrapper SHALL call rm_cleanup_gpu_lost_state with NV_GPU_LOST_DETECTOR_AER_FATAL
AND   nv_shutdown_adapter SHALL proceed with nv_kthread_q_stop, IRQ teardown, msix mutex free, and the second wrapped rm_shutdown_adapter call (which fast-fails post-sink-set)
AND   nv_pci_remove_helper SHALL continue and complete
AND   rmmod SHALL return with exit code 0 within ~500 ms wall-clock
AND   the host SHALL remain responsive (no kernel-wide wedge, no reboot required)
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

- **Source cluster**: addon — project-local; F40-class wedge containment, symmetric to A6 on the rmmod path. The F40 chip-side root cause is NVIDIA bug #979 (`project_issue_979_upstream_state_2026_05_22.md`) and is out of scope for our fork; A7 is the kernel-side containment for the rmmod path, attested by the 2026-05-29 20:52 forensics report.
- **Vanilla baseline files**: `kernel-open/nvidia/nv.c` (insertion of `nv_f40b_shutdown_bounded`, supporting `struct nv_f40b_shutdown_work` / worker / put primitives, and `NVreg_TbEgpuShutdownTimeoutMs` immediately before `nv_shutdown_adapter`; modification of the two RM call sites inside `nv_shutdown_adapter` to invoke the wrapper).
- **Fork branch**: `a7-f40b-bounded-wait-shutdown`.
- **Upstream candidacy**: n/a — addon layer. Same rationale as A6: the bounded-wait wrapper is specific to the F40 wedge class on TB-attached Blackwell eGPUs and depends on E1's `is_external_gpu` classifier (also addon). Upstream candidacy would require both (a) C5's sink primitive in mainline form, and (b) a generalised "chip-touching MMIO can hang" framework that does not exist in upstream nvidia-open today.
- **Upstream issues**: NVIDIA bug #979 (Blackwell eGPU over Thunderbolt hard-lock) — open, no NVIDIA response in 5 months as of 2026-05-22.
