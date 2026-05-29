---
id: A6-f40b-bounded-wait-open
layer: addon
source-branch: a6-f40b-bounded-wait-open
upstream-candidacy: n/a
telemetry-tier: mandatory
status: draft
related-patches: [C5-crash-safety, E1-egpu-detection, A7-f40b-bounded-wait-shutdown, A8-f40b-sysfs-observability]
---

# A6-f40b-bounded-wait-open — Bounded-Wait Wrapper for Chip-Touching Open-Path MMIO on E1-Classified eGPUs

## Purpose

Close the F40 open-path host-wedge class on userspace-recovered Blackwell eGPUs over Thunderbolt 4. Chip-touching MMIO inside `RmInitAdapter` (reached from `nv_open_device_for_nvlfp`) can hang indefinitely on a chip that has been recovered in userspace via the `rmmod + TB cycle + fix-bar1 + modprobe` sequence — the chip does not produce a PCIe completion, the syscall thread deadlocks holding the global lock, and the kernel wedges before AER processing can fire the C5 sink. A6 schedules the chip-touching open onto `system_long_wq`, lets the syscall thread wait with a bounded timeout (default 200 ms = 4× PCIe Completion Timeout), and on timeout declares the GPU lost via the C5 sink primitive and returns `-EIO`. Userspace sees the same error code it would see on a successful kernel AER race; the wrapper makes the outcome deterministic instead of timing-dependent. See `fake-5090/failure-modes/F40-rmshutdownadapter-incomplete-init-wedge.md` and `docs/missions/mission-1-egpu-hot-plug-hot-power/design/F40b-structural-fix-2026-05-29.md` for mechanism evidence (n=13 wedges + Test B v2 + TBv2-n2 + F40B-TEST n=2 validation).

## Requirements

### Requirement: Driver SHALL wrap chip-touching open in a bounded-wait worker when feature is enabled and chip is E1-classified

The driver MUST schedule the call to `nv_open_device_for_nvlfp` from the foreground branch of `nvidia_open` onto a kernel worker (`system_long_wq`) and SHALL wait for completion with a timeout of `NVreg_TbEgpuOpenTimeoutMs` milliseconds when both of the following are true:

- `NVreg_TbEgpuOpenTimeoutMs > 0` (the feature is enabled; default 200 ms)
- `nv->is_external_gpu` (E1 classification — the device is a Thunderbolt-attached eGPU)

When either condition is false, the driver MUST fall through to the original synchronous `nv_open_device_for_nvlfp` call with zero behaviour change. The wrapper MUST NOT introduce a worker hop or scheduling delay for non-eGPU users or when the feature is disabled.

#### Scenario: Bounded-wait wrapper schedules worker on E1-classified eGPU

```
GIVEN nvidia.ko is loaded with NVreg_TbEgpuOpenTimeoutMs=200 (default)
AND   the chip at /dev/nvidia0 is E1-classified (nv->is_external_gpu is true)
WHEN  a userspace process calls open("/dev/nvidia0", O_RDWR) on the foreground path
THEN  the chip-touching nv_open_device_for_nvlfp call SHALL be queued onto system_long_wq
AND   the syscall thread SHALL wait via wait_for_completion_timeout with timeout=200 ms
AND   a mandatory-tier kernel-log line "tb_egpu [F40b]: open scheduled to bounded worker (timeout=200 ms)" SHALL be emitted
```

#### Scenario: Wrapper short-circuits to synchronous path on non-eGPU

```
GIVEN nvidia.ko is loaded with NVreg_TbEgpuOpenTimeoutMs=200
AND   the device being opened is NOT E1-classified (nv->is_external_gpu is false)
WHEN  the foreground open path reaches the wrapper
THEN  the wrapper SHALL call nv_open_device_for_nvlfp synchronously without queuing work
AND   no worker SHALL be allocated and no "tb_egpu [F40b]" log line SHALL be emitted
AND   the syscall behaviour SHALL be byte-identical to the pre-A6 code
```

#### Scenario: Wrapper short-circuits to synchronous path when feature is disabled

```
GIVEN nvidia.ko is loaded with NVreg_TbEgpuOpenTimeoutMs=0
AND   the device is E1-classified
WHEN  the foreground open path reaches the wrapper
THEN  the wrapper SHALL call nv_open_device_for_nvlfp synchronously without queuing work
AND   no worker SHALL be allocated and no "tb_egpu [F40b]" log line SHALL be emitted
```

### Requirement: On worker completion within timeout SHALL propagate worker rc to caller

When the worker's `nv_open_device_for_nvlfp` returns before the timeout expires, the wrapper MUST propagate the worker's return code (`open_rc`) verbatim to the caller of `nvidia_open`. The wrapper MUST NOT mask, translate, or override the worker's rc on the happy path.

#### Scenario: Worker succeeds within budget

```
GIVEN the worker is running nv_open_device_for_nvlfp on an E1-classified eGPU
WHEN  the call returns 0 within the timeout budget (typically ~10-50 ms on healthy hardware)
THEN  wait_for_completion_timeout SHALL return a positive jiffies-remaining value
AND   the wrapper SHALL emit "tb_egpu [F40b]: open completed within budget rc=0"
AND   the wrapper SHALL return 0 to nvidia_open
AND   the file descriptor SHALL be returned to userspace as on the synchronous path
```

#### Scenario: Worker fails within budget

```
GIVEN the worker is running nv_open_device_for_nvlfp on an E1-classified eGPU
WHEN  the call returns -ENOMEM (or any other error) within the timeout budget
THEN  wait_for_completion_timeout SHALL return a positive jiffies-remaining value
AND   the wrapper SHALL emit "tb_egpu [F40b]: open completed within budget rc=-12"
AND   the wrapper SHALL return -ENOMEM to nvidia_open
AND   userspace SHALL see the appropriate errno
```

### Requirement: On timeout SHALL declare GPU lost via C5 sink and return -EIO

When the worker has not completed within `NVreg_TbEgpuOpenTimeoutMs` milliseconds, the wrapper MUST:

1. Emit a mandatory-tier kernel-log line identifying the F40b timeout (per Telemetry contract).
2. Call `rm_cleanup_gpu_lost_state(sp, nv, NV_GPU_LOST_DETECTOR_AER_FATAL)` to invoke the C5 sink primitive. This sets `PDB_PROP_GPU_IS_LOST` and propagates the lost-state to all subsequent RM operations on this device, including any operations the leaked worker still has in flight.
3. Drop the wrapper's reference to the heap-allocated work struct via `nv_f40b_open_work_put` (decrement-and-free).
4. Return `-EIO` to `nvidia_open`, which the userspace open syscall observes as `errno=EIO`.

The wrapper MUST NOT attempt to cancel, join, or otherwise interfere with the in-flight worker. The leaked worker is expected to exit on its own when its next sink-aware MMIO check observes the C5 sink and aborts. The refcount-2 / decrement-and-free protocol ensures the work struct outlives both the wrapper's return and the worker's eventual exit without leaks.

The detector class passed to `rm_cleanup_gpu_lost_state` SHALL be `NV_GPU_LOST_DETECTOR_AER_FATAL` (value 3) as a placeholder. A future patch (A9) introduces a dedicated `NV_GPU_LOST_DETECTOR_F40B_OPEN_TIMEOUT` detector class to enable correct telemetry routing; until A9 lands, AER_FATAL is the closest existing semantically-correct detector class.

#### Scenario: Wedge condition triggers F40b timeout path

```
GIVEN nvidia.ko is loaded with NVreg_TbEgpuOpenTimeoutMs=200
AND   the eGPU at /dev/nvidia0 is in the F40-precondition state (userspace-recovered after a prior bind cycle)
WHEN  bash executes `exec 3</dev/nvidia0` and the wrapper's worker hangs in RmInitAdapter MMIO
THEN  wait_for_completion_timeout SHALL return 0 after approximately 200 ms
AND   the wrapper SHALL emit "tb_egpu [F40b]: open timed out after 200 ms — declaring GPU lost (detector_class=3 DETECTOR_AER_FATAL); worker leaked, will exit when MMIO fails-fast post-sink-set"
AND   the wrapper SHALL call rm_cleanup_gpu_lost_state with NV_GPU_LOST_DETECTOR_AER_FATAL
AND   the wrapper SHALL return -EIO to nvidia_open
AND   bash SHALL print "Input/output error" and exit with rc=1
AND   the host kernel SHALL remain responsive (no wedge, no reboot required)
AND   the wall-clock duration of the wedged exec SHALL be approximately 200 ms (±10 ms scheduling jitter)
```

#### Scenario: Validated reproducibility (F40B-TEST n=2)

```
GIVEN A6 is loaded as part of the aorus.18-f40b image (2026-05-29 evening)
WHEN  cycle 1 (cold-open) is executed: exec 3</dev/nvidia0; exec 3<&-
THEN  cycle 1 SHALL complete cleanly (3 fd opens, LAST-CLOSE, WPR2 -> 0)
WHEN  cycle 2 (the F40-precondition-triggering second open) is executed: exec 3</dev/nvidia0
THEN  cycle 2 SHALL trigger the F40b timeout path
AND   bash SHALL exit with "Input/output error" rc=1
AND   the F40B-TEST log SHALL show a timeout in the range 200-210 ms (n=2 measurements: 201.7 ms and 203.5 ms recorded 2026-05-29 19:48 and 19:50)
AND   the host SHALL remain alive (no kernel-wide freeze, no reboot)
```

### Requirement: Refcounted work struct SHALL not leak on either happy or timeout path

The heap-allocated `struct nv_f40b_open_work` MUST be initialised with `atomic_set(&w->refcount, 2)` — one reference for the caller (the wrapper) and one for the worker. Both the wrapper and the worker MUST call `nv_f40b_open_work_put` exactly once, which atomically decrements the refcount and frees the struct when the count reaches zero.

#### Scenario: Refcount on happy path

```
GIVEN the worker completes within budget
WHEN  the wrapper observes wait_for_completion_timeout > 0
THEN  the worker has already called nv_f40b_open_work_put (refcount 2 -> 1) before signalling completion
AND   the wrapper SHALL call nv_f40b_open_work_put after reading w->rc, dropping refcount 1 -> 0
AND   kfree(w) SHALL be called by the wrapper's put (the last reference holder)
AND   no use-after-free SHALL occur on the wrapper's final read of w->rc (the read happens before put)
```

#### Scenario: Refcount on timeout path

```
GIVEN the worker has not yet completed at the timeout
WHEN  the wrapper observes wait_for_completion_timeout == 0
THEN  the wrapper SHALL call nv_f40b_open_work_put (refcount 2 -> 1), retaining the struct for the worker's eventual completion
AND   the worker SHALL eventually exit (when MMIO fails-fast post-sink-set) and call nv_f40b_open_work_put (refcount 1 -> 0)
AND   kfree(w) SHALL be called by the worker's put (the last reference holder)
AND   no leak SHALL occur even though the worker exits after the wrapper has returned
```

## Scope boundary

- A6 SHALL NOT wrap the background (O_NONBLOCK) open path. That path runs in the `nv_open_q` kthread and shares the same MMIO hazard, but is exercised only by clients passing `O_NONBLOCK` with `NVreg_EnableNonblockingOpen=1` and is not currently observed in production. A future patch MAY extend the bounded-wait pattern to the background path.
- A6 SHALL NOT wrap chip-touching MMIO on the rmmod / `nv_pci_remove → nv_shutdown_adapter` path. That path has the same hazard class and is documented as a known coverage gap by the 2026-05-29 20:52 forensics report (`/var/log/mission-1-archaeology/a7-deploy-wedge-2026-05-29/FORENSICS-REPORT.md`). The symmetric rmmod-path wrapper is implemented by A7.
- A6 SHALL NOT attempt recovery. On timeout, the GPU is declared lost via the C5 sink primitive and userspace receives `-EIO`; the operator's existing recovery sequence (`rmmod + TB cycle + fix-bar1 + modprobe`) is the recovery path until A9 lands.
- A6 SHALL NOT introduce a per-PCI-device sysfs observability surface. That surface is implemented by A8 (which hooks A6's timeout path to update per-device counters and the `tb_egpu_state` attribute).
- A6 SHALL NOT cancel the in-flight worker. The leaked-worker design is intentional: cancel-on-timeout would require sleep-cancel-safe MMIO, which the chip does not provide on the wedge path. Sink-aware fail-fast inside the worker is the supported termination path.
- A6 SHALL NOT modify `RmInitAdapter` itself or any closed-source RM code. The wrapper sits entirely in the open kernel-open driver layer.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| **Open scheduled to bounded worker (mandatory tier)** | **`NV_DBG_ERRORS` (err)** | `"NVRM: tb_egpu [F40b]: open scheduled to bounded worker (timeout=%u ms)\n"` |
| **Open completed within budget (mandatory tier)** | **`NV_DBG_ERRORS` (err)** | `"NVRM: tb_egpu [F40b]: open completed within budget rc=%d\n"` |
| **Open timed out — sink-set + EIO (mandatory tier)** | **`NV_DBG_ERRORS` (err)** | `"NVRM: tb_egpu [F40b]: open timed out after %u ms — declaring GPU lost (detector_class=3 DETECTOR_AER_FATAL); worker leaked, will exit when MMIO fails-fast post-sink-set\n"` |

All three events are mandatory-tier — every F40b-relevant open syscall (on E1-classified eGPU with feature enabled) reaches at least one of these lines. The "scheduled" line emits unconditionally on every wrapped open; exactly one of "completed" or "timed out" follows.

Userspace consumers SHOULD monitor for the "timed out" line via `journalctl -k -f` to detect F40b fires. A8 publishes the same fact via the `tb_egpu_f40b_fires` sysfs counter, which is the recommended machine-readable surface.

## Provenance

- **Source cluster**: addon — project-local; F40-class wedge containment. The F40 chip-side root cause is NVIDIA bug #979 (`project_issue_979_upstream_state_2026_05_22.md`) and is out of scope for our fork; A6 is the kernel-side containment.
- **Vanilla baseline files**: `kernel-open/nvidia/nv.c` (insertion of `nv_open_device_for_nvlfp_bounded` and supporting `struct nv_f40b_open_work` / worker / put primitives between `nv_open_device_for_nvlfp` and `nvidia_open_deferred`; one-line call-site change in `nvidia_open`'s foreground path).
- **Fork branch**: `a6-f40b-bounded-wait-open`.
- **Upstream candidacy**: n/a — addon layer. The bounded-wait wrapper is specific to the F40 wedge class on TB-attached Blackwell eGPUs and depends on E1's `is_external_gpu` classifier (also addon). Mainline candidacy would require both (a) C5's sink primitive in mainline form, and (b) a generalised "chip-touching MMIO can hang" framework that does not exist in upstream nvidia-open today. A8/A9 (forthcoming) and the broader in-driver recovery architecture (see `docs/missions/mission-1-egpu-hot-plug-hot-power/design/in-driver-recovery-target-2026-05-29.md`) are more plausible upstream candidates over the long horizon.
- **Upstream issues**: NVIDIA bug #979 (Blackwell eGPU over Thunderbolt hard-lock) — open, no NVIDIA response in 5 months as of 2026-05-22.
