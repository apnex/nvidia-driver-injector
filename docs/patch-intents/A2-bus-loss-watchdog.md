---
id: A2-bus-loss-watchdog
layer: addon
source-branch: a2-bus-loss-watchdog
upstream-candidacy: n/a
telemetry-tier: mandatory
status: reviewed
related-patches: [A1-pcie-primitives, A3-recovery]
---

# A2-bus-loss-watchdog — Per-Device Heartbeat Watchdog for Silent Bus-Loss Detection

## Purpose

The driver SHALL run a per-device kthread heartbeat that periodically
reads `NV_PMC_BOOT_0` via direct volatile BAR0 MMIO, recognises the
all-ones return as the dead-bus signature that PCIe completes after the
hardware completion timeout on a fallen-off-the-bus device, and on
detection latches the GPU into the kernel-side disconnected state via
[[C5-crash-safety]]'s `os_pci_set_disconnected` so every subsequent
RM-side MMIO read short-circuits via `os_pci_is_disconnected`. The
watchdog closes the DMA-path Mode B detection gap that Q-active alone
cannot cover — Mode B wedges in the DMA-upload path where no MMIO reads
fire from userspace context, so the Q-active wrapper at the ioctl path
stays silent. Q-watchdog provides an active heartbeat that fires
regardless of which subsystem stalled, latches the first detection of
each episode into per-device state (jiffies, raw PMC_BOOT_0 value, AER
snapshot embedded from [[A1-pcie-primitives]]), publishes the state as
five `tb_egpu_qwd_*` sysfs attributes for cross-boot post-mortems, and
honours a runtime kill switch (`NVreg_TbEgpuQwdEnable`) so the
heartbeat itself can be A/B-toggled to characterise whether the active
probe perturbs the observability-sensitive failure mode. The
[[A3-recovery]] state machine reads the latched AER snapshot when
deciding whether to escalate to `pci_reset_bus`; A2 is the detection
half, A3 is the recovery half.

## Requirements

### Requirement: Driver SHALL spawn one Q-watchdog kthread per probed eGPU after RM bring-up

For each `pci_dev` the driver successfully probes via `nv_pci_probe`,
the driver SHALL allocate a `struct tb_egpu_qwd`, store the pointer in
the corresponding `nv_linux_state_t::qwd` field, and spawn a kthread
named `tb-egpu-qwd-<bus><slot>` that runs the heartbeat loop. Spawning
SHALL occur after `rm_enable_dynamic_power_management` returns, so the
device is fully bound to RM before the heartbeat begins. The driver
SHALL skip kthread creation when the module parameter
`NVreg_TbEgpuQwdEnable` is `0` at probe time and SHALL set
`nvl->qwd = NULL` in that case. The driver MUST tolerate kthread
allocation failure (`kzalloc` or `kthread_run` returning an error) by
logging the failure, leaving `nvl->qwd = NULL`, and continuing with
probe — Q-watchdog failure MUST NOT abort device bring-up.

#### Scenario: Healthy probe spawns the kthread and publishes sysfs
- **GIVEN** an attached eGPU successfully passes `nv_pci_probe`
- **AND** `NVreg_TbEgpuQwdEnable == 1` at probe time
- **WHEN** `tb_egpu_qwd_init(nvl)` runs from the probe path
- **THEN** the call MUST return `0`
- **AND** `nvl->qwd` MUST point at a freshly-allocated zeroed
  `struct tb_egpu_qwd`
- **AND** a kthread named `tb-egpu-qwd-<bus><slot>` MUST be running
- **AND** the five `tb_egpu_qwd_*` sysfs attributes MUST be visible
  under the PCI device's sysfs directory (group create failure is
  non-fatal and logged at info level)

#### Scenario: Kill switch at module load suppresses kthread spawn
- **GIVEN** the operator has set `NVreg_TbEgpuQwdEnable=0` at module
  load
- **WHEN** `tb_egpu_qwd_init(nvl)` runs from the probe path
- **THEN** the call MUST log one info-level line announcing the
  disabled state
- **AND** `nvl->qwd` MUST be `NULL`
- **AND** no kthread MUST be spawned
- **AND** the probe path MUST continue normally (return `0`)

#### Scenario: Kthread allocation failure is non-fatal
- **GIVEN** an attached eGPU at probe time
- **AND** `kzalloc` or `kthread_run` returns an error
- **WHEN** `tb_egpu_qwd_init(nvl)` runs from the probe path
- **THEN** the call MUST log one error-level line citing the failure
- **AND** `nvl->qwd` MUST be `NULL`
- **AND** the probe path MUST continue normally — Q-watchdog failure
  MUST NOT abort device bring-up

### Requirement: Q-watchdog kthread SHALL poll PMC_BOOT_0 at the runtime-tunable interval and detect the dead-bus signature

The kthread SHALL loop until `kthread_should_stop()` returns true. On
each iteration the kthread SHALL (1) read the current
`NVreg_TbEgpuQwdIntervalMs` value, clamp it to `[10, 60000]`
milliseconds, and sleep for that duration via `msleep_interruptible`;
(2) honour the runtime kill switch by skipping the read when
`NVreg_TbEgpuQwdEnable == 0`; (3) defensively skip the read when
`nv->regs->map` is `NULL` (early-probe / late-remove race); (4) skip
the read when the GPU is already declared disconnected via
`os_pci_is_disconnected(nv->handle)` — the disconnect propagation has
already fired and re-firing the latch within the same episode would
spam the log; (5) increment the per-device cycle counter and read the
32-bit value at `nv->regs->map + 0` (PMC_BOOT_0 offset) via `READ_ONCE`
on a `volatile NvU32 *` so the compiler emits a single non-tearing,
non-reordered 32-bit MMIO load. When the read returns `0xFFFFFFFFu`
(the dead-bus signature) the kthread SHALL declare detection per the
next Requirement; otherwise the kthread SHALL clear the
once-per-episode log latch so a future episode logs again.

#### Scenario: Healthy poll cycle increments cycles and clears the latch
- **GIVEN** a kthread running with a live BAR0 mapping
- **AND** the GPU is not yet declared disconnected
- **WHEN** the kthread reads `PMC_BOOT_0` and gets the chip identifier
  (any value `!= 0xFFFFFFFFu`)
- **THEN** the cycle counter MUST be incremented atomically
- **AND** the once-per-episode log latch MUST be cleared so a future
  detection re-fires the log line

#### Scenario: Runtime interval tuning takes effect on the next cycle
- **GIVEN** a kthread running with `NVreg_TbEgpuQwdIntervalMs = 200`
- **WHEN** an operator writes `1000` to
  `/sys/module/nvidia/parameters/NVreg_TbEgpuQwdIntervalMs`
- **THEN** the next iteration of the kthread MUST observe the new
  value
- **AND** the iteration MUST sleep for the clamped value
  (`[10, 60000]` ms) — values below 10 ms MUST be clamped to 10 ms
  and values above 60000 ms MUST be clamped to 60000 ms

#### Scenario: Runtime kill switch suppresses MMIO reads without stopping the kthread
- **GIVEN** a kthread running with `NVreg_TbEgpuQwdEnable = 1`
- **WHEN** an operator writes `0` to
  `/sys/module/nvidia/parameters/NVreg_TbEgpuQwdEnable`
- **THEN** subsequent cycles MUST NOT read `PMC_BOOT_0`
- **AND** the kthread MUST continue sleeping at the configured
  interval so the kill switch is reversible without a module reload

### Requirement: On dead-bus detection the kthread SHALL latch episode state, emit one mandatory log line, and propagate the disconnect

When the heartbeat read returns `0xFFFFFFFFu` the kthread SHALL
atomically increment the per-device detection counter and, if the
once-per-episode log latch has not yet fired in the current episode,
SHALL emit exactly one log line at the `NV_DBG_ERRORS` level (the
mandatory telemetry tier — silent bus-loss is untraceable) naming the
`PMC_BOOT_0` value, the cycle count at detection, and the
`os_pci_set_disconnected` action being taken. The kthread SHALL latch
`jiffies` into `qwd->last_detection_jiffies`, the raw
`PMC_BOOT_0` value into `qwd->last_pmc_boot_0`, and SHALL leave the
`qwd->last_aer` snapshot for [[A3-recovery]] to populate via
[[A1-pcie-primitives]]'s `tb_egpu_dump_aer_trigger_event(pdev,
"watchdog", &qwd->last_aer)` call (A3 owns the call site because A3
is the recovery state machine that consumes the snapshot; A2 only
provides the persistent storage). The kthread SHALL call
`os_pci_set_disconnected(nv->handle)` on every detection cycle (not
just the latched first detection) so the disconnect propagation is
re-asserted in case it was cleared by another path. The kthread MUST
continue looping after detection — the cycle counter continues
ticking, and if the disconnect ever clears the kthread MUST be ready
to re-fire and re-log.

#### Scenario: First dead-bus read in an episode emits the mandatory log and latches state
- **GIVEN** a kthread reading a live BAR0 mapping
- **AND** the GPU is not yet declared disconnected
- **AND** the once-per-episode log latch is clear (this is the first
  detection in the current episode)
- **WHEN** the kthread reads `PMC_BOOT_0` and gets `0xFFFFFFFFu`
- **THEN** the detection counter MUST be incremented atomically
- **AND** exactly one log line MUST be emitted at `NV_DBG_ERRORS`
  level naming the `PMC_BOOT_0` value (`0xffffffff`) and the cycle
  count
- **AND** `qwd->last_detection_jiffies` MUST be set to the current
  `jiffies` value
- **AND** `qwd->last_pmc_boot_0` MUST be set to `0xFFFFFFFFu`
- **AND** `os_pci_set_disconnected(nv->handle)` MUST be called
- **AND** the once-per-episode log latch MUST be set so subsequent
  detections within the same episode do not re-log

#### Scenario: Subsequent dead-bus reads in the same episode are silent but still propagate
- **GIVEN** a kthread that has already logged once for the current
  episode (the latch is set)
- **WHEN** the kthread reads `PMC_BOOT_0` and gets `0xFFFFFFFFu`
  again on the next cycle
- **THEN** the detection counter MUST be incremented atomically
- **AND** no additional log line MUST be emitted (latch suppresses
  per-cycle logging)
- **AND** `os_pci_set_disconnected(nv->handle)` MAY still be called
  to re-assert propagation
- **AND** the latched state (`jiffies`, `pmc_boot_0`) MUST NOT be
  overwritten — only the first detection of an episode latches state

#### Scenario: Already-disconnected GPU is skipped without re-firing the latch
- **GIVEN** a kthread whose GPU has already been declared
  disconnected (`os_pci_is_disconnected(nv->handle)` returns true)
- **WHEN** the kthread enters its next iteration
- **THEN** the kthread MUST skip the `PMC_BOOT_0` MMIO read entirely
- **AND** the kthread MUST continue sleeping at the configured
  interval — the kthread MUST NOT exit on disconnect (the kthread's
  lifetime is bound to `tb_egpu_qwd_stop` called from the remove
  path, not to disconnect state)

### Requirement: Driver SHALL publish per-device episode state as five `tb_egpu_qwd_*` sysfs attributes

The driver SHALL register an `attribute_group` containing exactly
five `DEVICE_ATTR_RO` entries under the PCI device's sysfs directory:
`tb_egpu_qwd_cycles` (cumulative kthread iterations),
`tb_egpu_qwd_detections` (dead-bus episodes detected),
`tb_egpu_qwd_last_detection_jiffies` (jiffies at first detect of
last episode), `tb_egpu_qwd_last_pmc_boot_0` (PMC_BOOT_0 value at
last detect), and `tb_egpu_qwd_last_aer_summary` (compact AER + DPC
snapshot at last detect, populated by [[A3-recovery]]). Each
attribute SHALL emit a `scnprintf`-bounded string fitting in one
`PAGE_SIZE` buffer. When `nvl->qwd` is `NULL` (kill switch active
or allocation failure) each attribute SHALL emit a placeholder
("0\n" or "0x00000000\n" or "(no qwd state)\n"). When the AER
snapshot's `valid` field is `0` (no detection has fired yet) the
summary attribute SHALL emit the placeholder "(no detection event
yet — qwd has run %d cycles)\n". The sysfs attributes MUST be
removed before the kthread is stopped in `tb_egpu_qwd_stop` so a
sysfs read concurrent with teardown cannot reach a freed
`nvl->qwd`.

#### Scenario: Cold-boot sysfs read before any detection emits placeholders
- **GIVEN** a freshly probed eGPU with a kthread running but no
  detections yet
- **WHEN** an operator reads each of the five `tb_egpu_qwd_*`
  attributes
- **THEN** `tb_egpu_qwd_cycles` MUST emit the current cycle count
  (a decimal followed by `\n`)
- **AND** `tb_egpu_qwd_detections` MUST emit `0\n`
- **AND** `tb_egpu_qwd_last_detection_jiffies` MUST emit `0\n`
- **AND** `tb_egpu_qwd_last_pmc_boot_0` MUST emit `0x00000000\n`
- **AND** `tb_egpu_qwd_last_aer_summary` MUST emit the "no
  detection event yet" placeholder

#### Scenario: Post-detection sysfs read emits the latched state
- **GIVEN** a kthread that has logged one detection (latch fired)
- **WHEN** an operator reads `tb_egpu_qwd_last_pmc_boot_0`
- **THEN** the attribute MUST emit `0xffffffff\n`
- **AND** `tb_egpu_qwd_last_detection_jiffies` MUST emit the
  decimal `jiffies` value at first detect of the episode
- **AND** `tb_egpu_qwd_last_aer_summary` MUST emit the
  AER/DPC/Root summary block when [[A3-recovery]]'s
  `tb_egpu_dump_aer_trigger_event` has populated the snapshot
  (`s->valid == 1`)

### Requirement: Driver SHALL stop the kthread cleanly on module unload before any state teardown

The driver SHALL invoke `tb_egpu_qwd_stop(nvl)` from
`nv_pci_remove_helper` before any other state teardown. The stop
function SHALL remove the sysfs attribute group, call
`kthread_stop(qwd->thread)` to block until the kthread observes
`kthread_should_stop` and returns, set `qwd->thread = NULL`,
`kfree(qwd)`, and set `nvl->qwd = NULL`. The stop function MUST be
idempotent against the kill-switch path (where `nvl->qwd` is
already `NULL`) and against the allocation-failure path (same).
The stop function MUST tolerate `nvl == NULL`. The kthread's
worst-case stop latency MUST be bounded by the maximum interval
clamp (60000 ms) since `msleep_interruptible` is interruptible by
the kthread-stop signal and the loop checks `kthread_should_stop`
immediately after sleep returns.

#### Scenario: Normal unload stops the kthread and frees state
- **GIVEN** a probed eGPU with a running kthread
- **WHEN** `tb_egpu_qwd_stop(nvl)` is called from the remove path
- **THEN** the sysfs attribute group MUST be removed first
- **AND** `kthread_stop` MUST be called and MUST return before
  `kfree(qwd)` runs
- **AND** `nvl->qwd` MUST be `NULL` after the call returns
- **AND** the call MUST emit one info-level line announcing cycle
  count and detection count at exit (from the kthread itself, just
  before returning)

#### Scenario: Stop on a kill-switch device is a safe no-op
- **GIVEN** an `nv_linux_state_t` where `tb_egpu_qwd_init` set
  `nvl->qwd = NULL` (kill switch was on at module load)
- **WHEN** `tb_egpu_qwd_stop(nvl)` is called from the remove path
- **THEN** the sysfs group removal MUST be skipped or be safe
  against absence
- **AND** the function MUST return without dereferencing the NULL
  `nvl->qwd` pointer

## Scope boundary

- This patch deliberately does NOT implement the recovery state
  machine (`pci_reset_bus`, slot-reset dispatch, bridge-link-cap
  preservation, post-`rm_init_adapter`-FAIL trigger,
  re-init policy). Recovery is the responsibility of
  [[A3-recovery]]; A2 is the detection half whose latched state A3
  reads.
- This patch does NOT register any `pci_error_handlers` callbacks.
  The err_handlers table is registered by
  [[C4-err-handlers-scaffold]]; A3 wires bodies into the C4 stubs.
- This patch does NOT call [[A1-pcie-primitives]]'s register-read
  primitives directly. The `last_aer` field is allocated and
  embedded by A2 (per A1's consumer-owned-lifetime contract) but
  populated by [[A3-recovery]]'s call to
  `tb_egpu_dump_aer_trigger_event(pdev, "watchdog", &qwd->last_aer)`
  at the recovery dispatch site. A2 owns storage; A3 owns the call.
- This patch does NOT poll WPR2 or AER status registers. The
  heartbeat reads only `PMC_BOOT_0` at BAR0 offset 0 via direct
  volatile MMIO. WPR2 polling and AER sampling live in
  [[A3-recovery]] (recovery-time observability) and
  [[A1-pcie-primitives]] (the substrate); A2's job is the cheapest
  possible heartbeat that detects bus loss in the DMA-path
  context where Q-active is silent.
- This patch does NOT consume [[A1-pcie-primitives]]'s
  `TB_EGPU_PCIE_WPR2_REG_OFFSET` or
  `TB_EGPU_PCIE_WPR2_VAL_MASK` constants because A2 does not
  read WPR2 at all. Those constants are for [[A3-recovery]]'s
  WPR2-stuck detection path. A2 defines its own dead-bus value
  `TB_EGPU_QWD_DEAD_BUS_VALUE = 0xFFFFFFFFu` because the dead-bus
  signature is a property of the PCIe completion timeout, not a
  GPU register field.
- This patch does NOT instrument any RM close-path or UVM
  open/release transition — those events are
  [[A4-close-path-telemetry]]'s scope.
- This patch does NOT introduce a `CONFIG_NV_TB_EGPU` build-time
  gate on its source-list line. The master toggle is owned by
  `A5-version-and-toggles` and applies at the consumer call sites
  (this file plus A3 / A4); A2's compilation is unconditional once
  its row in `nvidia-sources.Kbuild` is in effect. A2 instead
  exposes runtime `NVreg_TbEgpuQwdEnable` (kill switch) and
  `NVreg_TbEgpuQwdIntervalMs` (interval) module parameters because
  the Heisenbug A/B characterisation requires runtime toggleability,
  which is finer-grained than a build-time `CONFIG_*` gate provides.
- This patch does NOT propagate the dead-bus event to userspace via
  `kobject_uevent` or netlink. Userspace observability is provided
  by the five `tb_egpu_qwd_*` sysfs attributes, polled by the
  watchdog daemon (`usr/local/sbin/watchdog-*` in the injector
  repo). A future enhancement could add `kobject_uevent` emission
  to remove the polling cost — out of scope for v1.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| Kthread spawned at probe | `NV_DBG_INFO` (info) | `"tb_egpu: qwd kthread started (interval=%ums, enable=%u)\n"` |
| Kthread suppressed by kill switch at module load | `NV_DBG_INFO` (info) | `"tb_egpu: qwd disabled at module load (NVreg_TbEgpuQwdEnable=0); kthread not spawned\n"` |
| Kthread allocation failure (`kzalloc`) | `NV_DBG_ERRORS` (err) | `"tb_egpu: qwd kzalloc failed; continuing without watchdog\n"` |
| Kthread allocation failure (`kthread_run`) | `NV_DBG_ERRORS` (err) | `"tb_egpu: qwd kthread_run failed: %d; continuing without watchdog\n"` |
| Sysfs group create failure | `NV_DBG_INFO` (info) | `"tb_egpu: qwd sysfs_create_group failed: %d\n"` |
| **Dead-bus detected (first detection per episode — mandatory tier)** | **`NV_DBG_ERRORS` (err)** | `"tb_egpu: qwd DETECTED dead bus (PMC_BOOT_0=0x%08x after %d cycles).\n  action: os_pci_set_disconnected called; subsequent ioctl-path MMIO reads will short-circuit via Q-passive.\n"` |
| Kthread stopped | `NV_DBG_INFO` (info) | `"tb_egpu: qwd kthread stopped (cycles=%d detections=%d)\n"` |

The mandatory-tier log line is the detection event itself —
exactly one `NV_DBG_ERRORS`-level emit per dead-bus episode,
latched so subsequent cycles within the same episode do not
re-log. Silent bus-loss is the failure mode this patch exists to
eliminate; the log line proves the watchdog fired, names the
`PMC_BOOT_0` value (operators verify it is `0xffffffff` rather
than some intermediate corruption), names the cycle count at
detection (operators verify the heartbeat was actually running),
and names the propagation action so the dead-bus episode is
fully traceable from this single log line plus the latched sysfs
state.

## Provenance

- **Source cluster:** Carved from legacy cluster P3
  (`patches/legacy/0003-tb-egpu-qwatchdog.patch`) during the
  2026-05-22 addon-recarve campaign
  (`project_addon_recarve_merged_2026_05_22`). Legacy P3 already
  contained the full Q-watchdog kthread plus sysfs surface plus
  module parameters; the recarve was reconciliation against the
  newly-carved [[A1-pcie-primitives]] foundation (snapshot struct
  moved from A2's header to A1's header; A2 now includes
  `nv-tb-egpu-pcie.h` to get the type transitively) and not a
  redesign. The cross-cluster comment in `nv-tb-egpu-qwd.c` was
  updated to point at `nv-tb-egpu-pcie.c` (A1) instead of the
  legacy `nv-lever-m-recover.c`; the call site for
  `tb_egpu_dump_aer_trigger_event` is owned by [[A3-recovery]] and
  is added by A3's hunk into A2's detection latch site.
- **Vanilla baseline:** Two new files (`nv-tb-egpu-qwd.c`,
  `nv-tb-egpu-qwd.h`) with no vanilla counterpart. Two vanilla
  files modified additively: `kernel-open/common/inc/nv-linux.h`
  gains a `struct tb_egpu_qwd *qwd;` field at the end of
  `struct nv_linux_state_s`; `kernel-open/nvidia/nv-pci.c` gains
  one `#include "nv-tb-egpu-qwd.h"`, one
  `tb_egpu_qwd_init(nvl)` call in `nv_pci_probe` (after
  `rm_enable_dynamic_power_management`), and one
  `tb_egpu_qwd_stop(nvl)` call in `nv_pci_remove_helper` (before
  state teardown). `kernel-open/nvidia/nvidia-sources.Kbuild`
  gains one additive line `NVIDIA_SOURCES +=
  nvidia/nv-tb-egpu-qwd.c` after the existing
  `nv-tb-egpu-pcie.c` line.
- **Fork branch:** `a2-bus-loss-watchdog` on
  `apnex/open-gpu-kernel-modules` (sits on top of
  `a1-pcie-primitives`; the cumulative diff carries C1-C5 + E1 +
  A1 + A2).
- **A1 ABI consumed:** A2 consumes the [[A1-pcie-primitives]]
  surface in the following ways:
  - Embeds `struct tb_egpu_qwd_aer_snapshot last_aer` in
    `struct tb_egpu_qwd` (A1 declares the type, A2 owns the
    per-device instance — exact match for A1's "consumer-owned
    lifetime" contract).
  - Includes A1's header `nv-tb-egpu-pcie.h` from
    `nv-tb-egpu-qwd.h` to get the snapshot type transitively;
    A2 MUST NOT re-define the struct (the header comment makes
    this explicit).
  - Does NOT call `tb_egpu_pcie_read_wpr2`,
    `tb_egpu_pcie_walk_to_root_port`,
    `tb_egpu_pcie_read_dpc_state`, or
    `tb_egpu_pcie_read_aer_full` — A2's heartbeat reads only
    `PMC_BOOT_0` directly; the AER/DPC/topology primitives are
    consumed by [[A3-recovery]] at the recovery dispatch site.
  - Does NOT call `tb_egpu_dump_aer_trigger_event` from A2's
    detection latch — [[A3-recovery]] owns the call site (passes
    `out = &nvl->qwd->last_aer` so the snapshot lands in A2's
    per-device storage). A2 provides storage; A3 provides the
    call.
  - Does NOT consume `TB_EGPU_PCIE_WPR2_REG_OFFSET` or
    `TB_EGPU_PCIE_WPR2_VAL_MASK` because A2 does not poll WPR2.
- **C5 ABI consumed:** A2 calls
  [[C5-crash-safety]]'s `os_pci_is_disconnected(nv->handle)` (skip
  read if already disconnected) and `os_pci_set_disconnected(nv->handle)`
  (propagate the disconnect on detection). These calls are reached
  through the de-branded `nv-gpu-lost.h` API surface; A2 does NOT
  touch C5's internal state directly.
- **Module parameter surface:** `NVreg_TbEgpuQwdEnable` (uint,
  default 1, mode 0644) and `NVreg_TbEgpuQwdIntervalMs` (uint,
  default 200, clamped to `[10, 60000]`, mode 0644). Both are
  runtime-tunable so the Heisenbug A/B characterisation can
  enable/disable the watchdog and tune the interval without a
  module reload.
- **Sysfs surface:** Five `DEVICE_ATTR_RO` attributes under each
  eGPU's PCI device kobject — `tb_egpu_qwd_cycles`,
  `tb_egpu_qwd_detections`, `tb_egpu_qwd_last_detection_jiffies`,
  `tb_egpu_qwd_last_pmc_boot_0`, `tb_egpu_qwd_last_aer_summary`.
  Read-only (no operator writes); all reads bounded to one
  `PAGE_SIZE` buffer via `scnprintf`.
- **Upstream issue:** n/a. Addon-layer watchdog is project-local
  and never upstream-bound (per Rule 5:
  `upstream-candidacy: n/a` is the only allowed value for
  `layer: addon`). The detection mechanism (active MMIO heartbeat
  with module-parameter kill switch) is specific to the Mode B
  DMA-path silent freeze characterised in the project's reliability
  ledger (`project_mode_b_root_cause_open`,
  `feedback_lever_q_insufficient_for_dma`).
