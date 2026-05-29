---
id: A8-f40b-sysfs-observability
layer: addon
source-branch: a8-f40b-sysfs-observability
upstream-candidacy: n/a
telemetry-tier: nominal
status: draft
related-patches: [A3-recovery, A6-f40b-bounded-wait-open, A7-f40b-bounded-wait-shutdown]
---

# A8-f40b-sysfs-observability — Per-PCI-Device Sysfs Surface for F40b State and Counters

## Purpose

Expose the F40b-managed state and recovery counters as read-only sysfs attributes on each E1-classified eGPU's PCI device. Monitoring systems (Prometheus, nvidia-smi, ops dashboards, post-mortem tooling) consume this surface to track GPU health, F40b fire rates, and recovery outcomes. A8 establishes the surface; A6 (already shipped) increments the F40b fire counter on every timeout; A9 (forthcoming) will populate the recovery counters and drive the state transitions through the recovering / lost-permanent / back-to-healthy lifecycle.

## Requirements

### Requirement: Driver SHALL expose five read-only sysfs attributes on every bound PCI device

The driver MUST expose, at `/sys/bus/pci/devices/<bdf>/`, the following read-only attributes on every PCI device that nvidia.ko binds (E1-classified or otherwise — the kernel handles add/remove via `pci_driver.driver.dev_groups`):

| Attribute | Content | Reader format |
|---|---|---|
| `tb_egpu_state` | one of `healthy`, `recovering`, `lost-temporary`, `lost-permanent` | newline-terminated string |
| `tb_egpu_f40b_fires` | monotonic counter of F40b timeout fires since module load | `%d\n` |
| `tb_egpu_recovery_count` | monotonic counter of successful recoveries (set by A9) | `%d\n` |
| `tb_egpu_recovery_failures` | monotonic counter of failed recovery attempts (set by A9) | `%d\n` |
| `tb_egpu_last_recovery_ns` | `ktime_get_ns()` of last successful recovery (set by A9) | `%llu\n` |

Attributes MUST be created at device-bind time and removed at device-unbind time. The kernel's `pci_driver.driver.dev_groups` mechanism handles both transitions automatically; driver code MUST NOT call `sysfs_create_group` / `sysfs_remove_group` explicitly.

#### Scenario: Sysfs attributes appear on bind

```
GIVEN nvidia.ko is loaded with A8 applied
AND   the kernel binds nvidia.ko to a PCI device at /sys/bus/pci/devices/0000:04:00.0
WHEN  the bind completes
THEN  /sys/bus/pci/devices/0000:04:00.0/tb_egpu_state exists and is readable
AND   the same path also contains tb_egpu_f40b_fires, tb_egpu_recovery_count, tb_egpu_recovery_failures, tb_egpu_last_recovery_ns
AND   reading tb_egpu_state returns "healthy\n"
AND   reading each counter attribute returns "0\n"
```

#### Scenario: Sysfs attributes disappear on unbind

```
GIVEN nvidia.ko is bound to a PCI device with attributes visible
WHEN  the device is unbound (rmmod nvidia, or echo > /sys/bus/pci/.../driver/unbind)
THEN  the five attributes are no longer present at /sys/bus/pci/devices/<bdf>/
AND   the unbind completed without driver-code involvement in attribute lifecycle
```

### Requirement: A6's F40b timeout path SHALL increment the fires counter AND set state to lost-temporary

When A6's `nv_open_device_for_nvlfp_bounded` hits its timeout branch and calls `rm_cleanup_gpu_lost_state(...)`, the driver MUST also:

1. Increment `tb_egpu_f40b_fires` atomically.
2. Set `tb_egpu_state` atomically to `lost-temporary`.

The order is unimportant; both updates MUST be observable via sysfs read by the time A6's bounded wrapper returns `-EIO` to the caller. The C5 sink-set + the state transition MUST happen on every F40b timeout, regardless of which detector class is passed to `rm_cleanup_gpu_lost_state` or whether subsequent recovery (A9) is enabled.

#### Scenario: F40b fire updates state and counter

```
GIVEN nvidia.ko is loaded with A6 + A8
AND   the eGPU is in the F40-precondition state (userspace-recovered-after-prior-bind)
AND   tb_egpu_state currently reads "healthy"
AND   tb_egpu_f40b_fires currently reads N
WHEN  the bash command `exec 3</dev/nvidia0` runs and A6's wrapper times out
THEN  the bash exec returns "Input/output error" (rc=1)
AND   tb_egpu_state subsequently reads "lost-temporary"
AND   tb_egpu_f40b_fires subsequently reads N+1
```

#### Scenario: F40b fire on non-eGPU still updates global counter

```
GIVEN nvidia.ko is loaded with A6 + A8
AND   a non-E1-classified PCI device is bound
WHEN  A6's wrapper short-circuits (non-eGPU path, no actual bounded wait)
THEN  the global tb_egpu_f40b_fires counter is NOT incremented (the timeout path is not reached)
AND   the device's tb_egpu_state attribute continues to report "healthy"
```

### Requirement: A9 (forthcoming) hooks SHALL be provided as exported function symbols

The driver MUST provide three exported function symbols for A9 to call when it lands:

- `nv_tb_egpu_f40b_fired(void)` — invoked by A6 (already wired in this patch) on each F40b timeout. State -> lost-temporary; fires++. SHALL be safe to call from any context A6's timeout path runs in.
- `nv_tb_egpu_recovery_succeeded(void)` — reserved for A9. recovery_count++; last_recovery_ns := ktime_get_ns(); state -> healthy.
- `nv_tb_egpu_recovery_failed(int permanent)` — reserved for A9. recovery_failures++; state -> lost-permanent (if `permanent` non-zero) or lost-temporary (if `permanent` is zero).

A8 SHALL define all three functions even though A9 is the eventual consumer of two of them. This decouples A8 from A9's timeline and ensures A8's surface is complete without A9.

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
- A8 SHALL NOT implement per-device storage for counters. Single-GPU is the project's deployment target. Per-device storage MAY be added in a future patch when multi-GPU support is needed.
- A8 SHALL NOT modify the existing A3 sysfs attributes. A3's surface continues to publish bus-reset-cycle counters under its own attribute names; the two surfaces coexist without overlap.

## Telemetry contract

A8 emits no kernel-log messages. State + counters are surfaced exclusively via sysfs. The telemetry tier is `nominal` — A6 (mandatory tier) and A9 (mandatory tier) emit the kernel-log lines that humans read; A8's job is the machine-readable observability layer.

| Event | Level | Format |
|---|---|---|
| Attribute group registered with PCI core (at module init) | (none — kernel handles registration silently via dev_groups) | n/a |
| F40b fire updates global state | (none — A6 already emits the mandatory `tb_egpu [F40b]: open timed out ...` line; A8 just bumps counters silently) | n/a |
| Sysfs attribute read by userspace | (none — sysfs reads are silent by design) | n/a |

Userspace consumers that want a kernel-log signal at state change SHOULD subscribe to A6's existing `tb_egpu [F40b]:` markers via `journalctl -k -f`.

## Provenance

- **Source cluster**: addon — project-local; complements A6 (consumer of A8's hook for F40b fires) and is consumed by A9 (forthcoming, will populate the recovery counters).
- **Vanilla baseline files**: `kernel-open/nvidia/nv.c` (new state + counters + sysfs show functions added after the A6-introduced module parameter), `kernel-open/nvidia/nv-pci.c` (extern declaration + `dev_groups` field added to `nv_pci_driver`).
- **Fork branch**: `a8-f40b-sysfs-observability`.
- **Upstream candidacy**: n/a — addon layer, project-local. The sysfs surface is specific to F40b's lifecycle and depends on A6, neither of which is upstream-bound.
- **Upstream issues**: none directly; the broader context is `docs/missions/mission-1-egpu-hot-plug-hot-power/design/in-driver-recovery-target-2026-05-29.md`.
