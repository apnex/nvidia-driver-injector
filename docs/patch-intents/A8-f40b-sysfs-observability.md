---
id: A8-f40b-sysfs-observability
layer: addon
source-branch: a8-f40b-sysfs-observability
upstream-candidacy: n/a
telemetry-tier: nominal
status: reviewed
related-patches: [A2-bus-loss-watchdog, A3-recovery, A6-f40b-bounded-wait-open, A7-f40b-bounded-wait-shutdown]
---

# A8-f40b-sysfs-observability — Per-PCI-Device Sysfs Surface for F40b State and Counters

> **v2 (2026-05-30).** v1 registered the attribute group via
> `pci_driver.driver.dev_groups`. It compiled and every symbol loaded
> (`dev_attr_tb_egpu_*` present in `/proc/kallsyms`), but produced **zero** sysfs
> paths at runtime — verified empirically on aorus.19 (A7 Test A/B: attributes
> absent at `/sys/bus/pci/devices/<bdf>/`). Root cause: `__pci_register_driver()`
> executes `drv->driver.dev_groups = drv->dev_groups;`
> (`drivers/pci/pci-driver.c`), clobbering the inner `.driver.dev_groups` field
> v1 set with the NULL *outer* `pci_driver.dev_groups`. v2 switches to the
> explicit `sysfs_create_group` / `sysfs_remove_group` idiom proven on this
> driver by addon A2 (Q-watchdog) and A3 (recovery). This doc describes v2.
>
> **v2.2 (2026-05-31).** Adds a 6th attribute, `tb_egpu_is_external`, exposing the
> live per-device `nv->is_external_gpu` flag — the E1 classification that **gates**
> the A6 open-path and A7 shutdown-path bounded-wait wrappers. Motivated by the
> reset-ladder wedge forensics (`docs/missions/.../open-arm-forensics-ledger.md`):
> A6 only engages when `is_external_gpu` is set, and it is set **lazily** during the
> first open's `RmInitAdapter` (`osinit.c:1301`) — so the **first open of any bind is
> unguarded**, and a driver unbind→rebind makes a dangerous re-init *be* that
> unguarded first open. This attribute makes the A6/A7 armed-state observable and the
> first-open coverage hole detectable, via a plain sysfs `read()` (no chip touch —
> safe to poll even on a wedge-prone chip).

## Purpose

Expose the F40b-managed state and recovery counters as read-only sysfs attributes on each nvidia-bound PCI device. Monitoring systems (Prometheus, nvidia-smi, ops dashboards, post-mortem tooling) consume this surface to track GPU health, F40b fire rates, and recovery outcomes. A8 establishes the surface; A6 and A7 (already shipped) increment the F40b fire counter on every open-path and shutdown-path timeout respectively; A9 (forthcoming) will populate the recovery counters and drive the state transitions through the recovering / lost-permanent / back-to-healthy lifecycle.

## Requirements

### Requirement: Driver SHALL expose six read-only sysfs attributes on every bound PCI device

The driver MUST expose, at `/sys/bus/pci/devices/<bdf>/`, the following read-only attributes on every PCI device that nvidia.ko binds:

| Attribute | Content | Reader format |
|---|---|---|
| `tb_egpu_state` | one of `healthy`, `recovering`, `lost-temporary`, `lost-permanent` | newline-terminated string |
| `tb_egpu_is_external` | live `nv->is_external_gpu` — the E1 eGPU classification gating A6/A7 bounded-wait; `1` armed, `0` **unguarded** (e.g. first open of a bind / post-rebind), or `unknown` (drvdata unset) | `%d\n` / `unknown\n` |
| `tb_egpu_f40b_fires` | counter of F40b timeout fires **since the current device bind** (both A6 open-path and A7 shutdown-path) | `%d\n` |
| `tb_egpu_recovery_count` | counter of successful recoveries since bind (set by A9) | `%d\n` |
| `tb_egpu_recovery_failures` | counter of failed recovery attempts since bind (set by A9) | `%d\n` |
| `tb_egpu_last_recovery_ns` | `ktime_get_ns()` of last successful recovery (set by A9) | `%llu\n` |

Attributes MUST be created at device-bind time and removed at device-unbind time. The driver MUST register the group explicitly via `sysfs_create_group(&nvl->pci_dev->dev.kobj, &tb_egpu_metrics_attr_group)` from a probe-time lifecycle helper (`tb_egpu_metrics_init`), and MUST remove it via `sysfs_remove_group(...)` from a remove-time helper (`tb_egpu_metrics_stop`), mirroring the A2/A3 idiom. The driver MUST NOT use the `pci_driver.driver.dev_groups` mechanism — `__pci_register_driver` clobbers that field to NULL (see the v2 banner above).

Registration failure MUST be non-fatal: on `sysfs_create_group` error the driver SHALL log at `NV_DBG_INFO` and continue to bind (the GPU still works, just without the observability surface), exactly as A2/A3 do.

#### Scenario: Sysfs attributes appear on bind

```
GIVEN nvidia.ko is loaded with A8 v2 applied
AND   the kernel binds nvidia.ko to a PCI device at /sys/bus/pci/devices/0000:04:00.0
WHEN  nv_pci_probe runs tb_egpu_metrics_init and sysfs_create_group succeeds
THEN  /sys/bus/pci/devices/0000:04:00.0/tb_egpu_state exists and is readable
AND   the same path also contains tb_egpu_f40b_fires, tb_egpu_recovery_count, tb_egpu_recovery_failures, tb_egpu_last_recovery_ns
AND   reading tb_egpu_state returns "healthy\n"
AND   reading each counter attribute returns "0\n"
```

#### Scenario: Sysfs attributes disappear on unbind

```
GIVEN nvidia.ko is bound to a PCI device with attributes visible
WHEN  the device is unbound (rmmod nvidia, or echo > /sys/bus/pci/.../driver/unbind)
AND   nv_pci_remove_helper runs tb_egpu_metrics_stop -> sysfs_remove_group
THEN  the five attributes are no longer present at /sys/bus/pci/devices/<bdf>/
AND   sysfs_remove_group has drained any in-flight show() callback before returning
```

### Requirement: Counters SHALL reset to zero and state to healthy on each device bind

The backing metrics struct is module-global single-instance (single-eGPU deployment posture), so it persists across an unbind-rebind. To prevent a DaemonSet pod restart / unbind-rebind from re-exposing stale counters from the prior bind generation, `tb_egpu_metrics_init` MUST call a reset helper (`nv_tb_egpu_metrics_reset`) that sets `state = healthy` and all four counters to `0`, **before** publishing the sysfs group. Consequently `tb_egpu_f40b_fires` (and the recovery counters) are "since the current bind", not "since module load".

#### Scenario: Counters reset across a pod restart

```
GIVEN nvidia.ko is bound and tb_egpu_f40b_fires reads 3 from a prior workload
WHEN  the injector pod is deleted (rmmod) and the DaemonSet respawns it (modprobe + rebind)
THEN  after rebind, tb_egpu_f40b_fires reads 0
AND   tb_egpu_state reads "healthy"
```

### Requirement: Both F40b timeout paths SHALL increment the fires counter; only the open path SHALL set state to lost-temporary

When A6's `nv_open_device_for_nvlfp_bounded` (open path) OR A7's `nv_f40b_shutdown_bounded` (shutdown/rmmod/close path) hits its timeout branch and calls `rm_cleanup_gpu_lost_state(...)`, the driver MUST increment `tb_egpu_f40b_fires` atomically. The shutdown path is the **dominant** fire class — A7 Test A (n=2, 2026-05-29; n=3 on the aorus.20 deploy uninstall) proved it fires on every healthy rmmod on this hardware — so the counter MUST cover it; counting only the open path would make `tb_egpu_f40b_fires` silently miss its primary production fire path and would violate A7's documented contract that "A8 increments a single counter for both A6 and A7 fires". The hook MUST be placed once in the shared `nv_f40b_shutdown_bounded` helper (per-timeout), not at the two call sites, so each genuine MMIO timeout counts exactly once.

The `tb_egpu_state` transition to `lost-temporary`, however, MUST happen ONLY on the **open path** (A6), via `nv_tb_egpu_f40b_fired()`. The shutdown path (A7) MUST use a counter-only variant `nv_tb_egpu_f40b_fired_teardown()` that does NOT touch state. Rationale: an open-path timeout means the GPU failed to come up and is genuinely unusable (`lost-temporary` is correct). A shutdown-path timeout is a teardown artifact — it fires during `nv_shutdown_adapter` (rmmod, or a pre-persistence close-path `nv_stop_device` on bring-up), after which a fresh bind works fine. Setting `lost-temporary` on a teardown fire would strand a demonstrably healthy GPU's `tb_egpu_state` at `lost-temporary` after **every normal bring-up** (which includes a pre-persistence close-path fire), with no path back to `healthy` until A9 lands — a false-negative health signal. This was found in the live aorus.20 deploy (`state` read `lost-temporary` while the GPU was at P8 with persistence engaged and nvidia-smi fully functional) and corrected in v2.1.

#### Scenario: Open-path F40b fire updates state and counter

```
GIVEN nvidia.ko is loaded with A6 + A8
AND   the eGPU is in the F40-precondition state (userspace-recovered-after-prior-bind)
AND   tb_egpu_state currently reads "healthy" and tb_egpu_f40b_fires reads N
WHEN  the bash command `exec 3</dev/nvidia0` runs and A6's wrapper times out
THEN  the bash exec returns "Input/output error" (rc=1)
AND   tb_egpu_state subsequently reads "lost-temporary"
AND   tb_egpu_f40b_fires subsequently reads N+1
```

#### Scenario: Shutdown-path F40b fire increments counter but leaves state healthy

```
GIVEN nvidia.ko is freshly bound, tb_egpu_state reads "healthy", tb_egpu_f40b_fires reads 0
AND   the GPU is healthy (persistence engaged, nvidia-smi functional)
WHEN  a pre-persistence close-path open/close during bring-up drives nv_shutdown_adapter
      and A7's rm_shutdown_adapter wrap times out at 200 ms (structural on this hardware)
THEN  tb_egpu_f40b_fires reads 1 (the teardown fire is counted)
AND   tb_egpu_state STILL reads "healthy" (a teardown timeout is not a usability event)
```

(Verified live on aorus.20 before v2.1: a single counter+state hook left `tb_egpu_state=lost-temporary` / `f40b_fires=1` after bring-up on a healthy GPU. After v2.1 the same bring-up yields `state=healthy` / `f40b_fires=1`.)

### Requirement: A9 (forthcoming) hooks SHALL be provided as function symbols

The driver MUST provide the following function symbols:

- `nv_tb_egpu_f40b_fired(void)` — invoked by A6 (open path), already wired. fires++ AND state -> lost-temporary. SHALL be safe to call from any context the open timeout path runs in (pure atomic ops, no sleeping).
- `nv_tb_egpu_f40b_fired_teardown(void)` — invoked by A7 (shutdown path), already wired. fires++ ONLY (state untouched — see the state-transition requirement above). Same context-safety.
- `nv_tb_egpu_recovery_succeeded(void)` — reserved for A9. recovery_count++; last_recovery_ns := ktime_get_ns(); state -> healthy.
- `nv_tb_egpu_recovery_failed(int permanent)` — reserved for A9. recovery_failures++; state -> lost-permanent (if `permanent` non-zero) or lost-temporary (if `permanent` is zero).

A8 SHALL define all four functions even though A9 is the eventual consumer of the last two. This decouples A8 from A9's timeline and ensures A8's surface is complete without A9.

#### Scenario: A9 hooks are linkable today

```
GIVEN A8 is applied
WHEN  the build completes
THEN  the symbols nv_tb_egpu_f40b_fired, nv_tb_egpu_recovery_succeeded, nv_tb_egpu_recovery_failed are present in the built nvidia.ko
AND   the kallsyms entry exists for each (verified via grep on /proc/kallsyms after module load)
```

## Scope boundary

- A8 SHALL NOT drive any recovery action. It exposes state; A9 will mutate state through recovery.
- A8 SHALL NOT emit uevents on state transitions. Under the in-driver recovery target (see `docs/missions/mission-1-egpu-hot-plug-hot-power/design/in-driver-recovery-target-2026-05-29.md`), there is no reactive userspace consumer that needs to be woken up; observability wants current state, which sysfs reads provide. Adding uevents would be debt-shaped.
- A8 SHALL NOT add a sysfs `force_trigger` write-only attribute (analogous to A3's). F40b's fire is not test-triggered from userspace; it fires when the bounded-wait timeout expires, which is itself a function of the chip's behaviour. If a test mechanism is needed in the future, it MAY be added as a separate patch.
- A8 SHALL NOT implement per-device storage for counters. Single-GPU is the project's deployment target; the attribute group attaches per-device but the backing storage is a single module-global instance. Per-device storage MAY be added in a future patch when multi-GPU support is needed. (Documented assumption: on a hypothetical multi-eGPU host all devices' attributes alias the same backing counters.)
- A8 SHALL NOT modify the existing A2 (Q-watchdog) or A3 (recovery) sysfs attributes. Those surfaces publish their own counters under disjoint `tb_egpu_qwd_*` / `tb_egpu_recover_*` prefixes; A8's flat attribute group coexists on the same device kobj without name collision.
- A8 intentionally adopts `sysfs_emit()` in its show functions where A2/A3 use `scnprintf()`. `sysfs_emit` is the modern PAGE_SIZE-bounded writer; this is a deliberate forward-looking choice, not an oversight — do not "fix" it back to `scnprintf`.

## Telemetry contract

A8 emits no kernel-log messages on the normal path. State + counters are surfaced exclusively via sysfs. The telemetry tier is `nominal` — A6/A7 (mandatory tier) and A9 (mandatory tier) emit the kernel-log lines that humans read; A8's job is the machine-readable observability layer.

| Event | Level | Format |
|---|---|---|
| Attribute group registered at probe | (none on success) | n/a |
| `sysfs_create_group` failed at probe | `NV_DBG_INFO` | `"tb_egpu metrics: sysfs_create_group failed: %d\n"` |
| F40b fire updates state + counter | (none — A6/A7 already emit the mandatory `tb_egpu [F40b]: ... timed out ...` line; A8 just bumps counters silently) | n/a |
| Sysfs attribute read by userspace | (none — sysfs reads are silent by design) | n/a |

Userspace consumers that want a kernel-log signal at fire time SHOULD subscribe to A6/A7's existing `tb_egpu [F40b]:` markers via `journalctl -k -f`; the `tb_egpu_f40b_fires` counter is the recommended machine-readable equivalent.

## Provenance

- **Source cluster**: addon — project-local; consumes A6 (open-path hook site) and A7 (shutdown-path hook site); consumed by A9 (forthcoming, populates the recovery counters). Mirrors the A2/A3 per-device sysfs idiom.
- **Vanilla baseline files**:
  - `kernel-open/nvidia/nv-tb-egpu-metrics.c` (new TU): enum, module-static atomic metrics struct, `nv_tb_egpu_state_str`, `nv_tb_egpu_metrics_reset`, the three hooks, the 5 `DEVICE_ATTR_RO` show functions + flat `tb_egpu_metrics_attr_group`, and the `tb_egpu_metrics_init` / `tb_egpu_metrics_stop` lifecycle helpers (sysfs_create_group / sysfs_remove_group on `&nvl->pci_dev->dev.kobj`).
  - `kernel-open/nvidia/nv-tb-egpu-metrics.h` (new TU): lifecycle + hook declarations, with the v1-failure rationale.
  - `kernel-open/nvidia/nvidia-sources.Kbuild`: `NVIDIA_SOURCES += nvidia/nv-tb-egpu-metrics.c`.
  - `kernel-open/nvidia/nv-pci.c`: `#include "nv-tb-egpu-metrics.h"`; `(void)tb_egpu_metrics_init(nvl)` in `nv_pci_probe` after `tb_egpu_qwd_init`; `tb_egpu_metrics_stop(nvl)` in `nv_pci_remove_helper` before `tb_egpu_qwd_stop`. (The v1 `dev_groups` field + extern are NOT present.)
  - `kernel-open/nvidia/nv.c`: `#include "nv-tb-egpu-metrics.h"`; `nv_tb_egpu_f40b_fired()` in A6's open-path timeout branch (counter + state) and `nv_tb_egpu_f40b_fired_teardown()` in A7's shutdown-path timeout branch (counter only).
- **Fork branch**: `a8-f40b-sysfs-observability`.
- **Validation**: full C1-C5 + E1 + A1-A8 stack compiles clean (`make modules`, kernel 7.0.9); `nv-tb-egpu-metrics.o` links into nvidia.ko; patch applies clean on a fresh `595.71.05` tag checkout. Adversarially reviewed 2026-05-30 (4-lens workflow + per-finding verification): no use-after-free, reset-vs-reader race safe, atomic types consistent, sysfs_emit buffer-safe. Runtime sysfs materialisation pending deployment on the next image (aorus.20).
- **Upstream candidacy**: n/a — addon layer, project-local. The sysfs surface is specific to F40b's lifecycle and depends on A6/A7, none of which is upstream-bound.
- **Upstream issues**: none directly; the broader context is `docs/missions/mission-1-egpu-hot-plug-hot-power/design/in-driver-recovery-target-2026-05-29.md`.
