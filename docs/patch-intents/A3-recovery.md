---
id: A3-recovery
layer: addon
source-branch: a3-recovery
upstream-candidacy: n/a
telemetry-tier: mandatory
status: reviewed
related-patches: [A1-pcie-primitives, A2-bus-loss-watchdog]
---

# A3-recovery — In-Driver Self-Triggered Bus Reset and PCIe Error-Recovery State Machine

## Purpose

The driver SHALL recover from transient eGPU bus-loss and the WPR2-stuck
firmware-boot failure by running an in-driver state machine that
performs a bounded recovery cycle on its own — without depending on a
userspace recovery helper. On a post-`rm_init_adapter` failure with a
non-zero WPR2 status register the driver SHALL schedule a
`pci_reset_bus` against the upstream Thunderbolt bridge from a work
queue, and after the reset settles SHALL explicitly dispatch the
`pci_error_handlers` `slot_reset` and `resume` bodies (because the
kernel's `pci_reset_bus` API does not itself fire those callbacks); on
a kernel-driven AER `error_detected` callback the driver SHALL run the
same hardening gates and return `PCI_ERS_RESULT_NEED_RESET` so the
kernel drives the bus reset and dispatches the same `slot_reset` and
`resume` bodies. Both paths funnel through one `pre_schedule_gates()`
function so the H1 (per-burst attempt cap), H2 (per-device rate limit
between attempts), and H3 (master enable plus persistent kill-switch
file) policies stay in lockstep. The driver SHALL reset the per-device
`attempt_count` ONLY on a verified end-to-end recovery
(post-`rm_init_adapter`-OK) — never on intermediate bus-reset success
— so the H1 cap measures consecutive failed full-recoveries instead of
raw retry count. On attempt exhaustion the driver SHALL increment the
`tb_egpu_recover_surrenders` counter, emit a `TB_EGPU_GPU_STATE=PERMANENT_FAIL`
uevent against the GPU pdev, and stop scheduling further work for the
device. The persistent capability is: "the driver self-heals from the
characterised transient bus loss and the WPR2-stuck firmware-boot
class without operator intervention, and surrenders predictably when
the failure is beyond its software reach."

## Requirements

### Requirement: Driver SHALL trigger an in-driver recovery on post-`rm_init_adapter`-FAIL when WPR2 is stuck

When `rm_init_adapter` returns failure in `nv_start_device`, the driver
SHALL call `tb_egpu_recover_trigger_post_rminit_fail(nvl)` BEFORE the
existing failure path runs. The trigger SHALL read WPR2 via
[[A1-pcie-primitives]]'s `tb_egpu_pcie_read_wpr2(bar0_phys, &raw)`
and mask the raw value with `TB_EGPU_PCIE_WPR2_VAL_MASK`; if the
masked value is non-zero (WPR2 stuck) — or if
`NVreg_TbEgpuRecoverTestForceTrigger == 1` overrides the WPR2-clear
branch — the trigger SHALL run the pre-schedule gate function and on
`GATE_OK` SHALL atomically take exclusive ownership of `pdev_for_work`
under an `atomic_xchg(&in_progress, 1) == 0` guard, set
`last_fire_jiffies`, increment `fire_count`, take a `pci_dev_get` on
the pdev, store it in `pdev_for_work`, and call `schedule_work` on the
recovery work item. The trigger MUST return `0` in all cases — the
caller's existing failure path runs unchanged regardless of whether
the trigger fired, deferred, or surrendered.

#### Scenario: WPR2 stuck after rmInit failure schedules recovery
- **GIVEN** `rm_init_adapter` returns failure in `nv_start_device`
- **AND** `NVreg_TbEgpuRecoverEnable == 1`
- **AND** `tb_egpu_pcie_read_wpr2(bar0_phys, &raw)` returns
  `raw & TB_EGPU_PCIE_WPR2_VAL_MASK != 0`
- **AND** the H1 attempt cap is not yet exhausted (the gate returns
  `GATE_OK`)
- **AND** the H2 rate-limit has elapsed since `last_fire_jiffies`
- **WHEN** `tb_egpu_recover_trigger_post_rminit_fail(nvl)` runs
- **THEN** the function MUST return `0`
- **AND** `atomic_xchg(&in_progress, 1)` MUST return `0` (no concurrent
  trigger)
- **AND** `pdev_for_work` MUST hold `pci_dev_get(nvl->pci_dev)` (a
  fresh refcount)
- **AND** `last_fire_jiffies` MUST be set to `jiffies`
- **AND** `fire_count` MUST be incremented atomically
- **AND** `schedule_work(&st->reset_work)` MUST be invoked
- **AND** the existing failure-path label (`failed_release_irq`) MUST
  still be reached so `nv_start_device` returns `-EIO`

#### Scenario: WPR2 clear after rmInit failure does not trigger recovery
- **GIVEN** `rm_init_adapter` returns failure
- **AND** `NVreg_TbEgpuRecoverEnable == 1`
- **AND** the WPR2 raw value masked with `TB_EGPU_PCIE_WPR2_VAL_MASK`
  is `0`
- **AND** `NVreg_TbEgpuRecoverTestForceTrigger == 0`
- **WHEN** the trigger runs
- **THEN** the function MUST log one `NV_DBG_INFO` line announcing
  "not the WPR2-stuck failure mode; not triggering"
- **AND** the function MUST return `0` without touching
  `in_progress`, `pdev_for_work`, `last_fire_jiffies`, or
  `fire_count`

#### Scenario: Re-entry guard suppresses overlapping triggers
- **GIVEN** a previous trigger has scheduled the work and the handler
  has not yet cleared `in_progress`
- **WHEN** a fresh trigger fires (e.g. a parallel
  `nv_start_device` from a second opener)
- **THEN** `atomic_xchg(&in_progress, 1)` MUST return `1` (the slot is
  taken)
- **AND** the trigger MUST log one `NV_DBG_ERRORS` line and return `0`
  without touching `pdev_for_work` or `schedule_work`

### Requirement: Driver SHALL participate in kernel-driven AER recovery via state-aware `error_detected` and explicit `slot_reset` / `resume` bodies

The driver SHALL fill [[C4-err-handlers-scaffold]]'s stub callbacks
with bodies. The `error_detected` callback SHALL emit one mandatory
log line on first fire per device (latched via a static
`s_error_detected_logged` flag), call A1's
`tb_egpu_dump_aer_trigger_event(pci_dev, "error-handler", NULL)` to
snapshot the AER state, run the same pre-schedule gate function used
by the post-rmInit-FAIL trigger, and return
`PCI_ERS_RESULT_NEED_RESET` on `GATE_OK` (with `fire_count` and
`last_fire_jiffies` updated and a `RECOVERING` uevent emitted) or
`PCI_ERS_RESULT_DISCONNECT` on any other gate result. The
`mmio_enabled` and `cor_error_detected` callbacks SHALL be pure
observability — emit one log line, call
`tb_egpu_dump_aer_trigger_event` with the appropriate event tag, and
return `PCI_ERS_RESULT_RECOVERED` (mmio_enabled) or nothing
(cor_error_detected). The `slot_reset` callback SHALL `ioremap` a
single page at `bar0_phys`, `ioread32` PMC_BOOT_0, `iounmap`, and
return `PCI_ERS_RESULT_RECOVERED` if PMC_BOOT_0 is not `0xffffffff`,
else `PCI_ERS_RESULT_DISCONNECT` (and on DISCONNECT increment
`surrender_count` and emit `PERMANENT_FAIL`). The `resume` callback
SHALL increment `success_count` and emit a `READY` uevent.

#### Scenario: First AER error_detected with healthy gates returns NEED_RESET
- **GIVEN** the kernel's AER subsystem dispatches `error_detected` on
  the GPU pdev
- **AND** this is the first `error_detected` fire since module load
  (`s_error_detected_logged == 0`)
- **AND** the pre-schedule gates return `GATE_OK`
- **WHEN** `nv_pci_error_detected(pci_dev, state)` runs
- **THEN** exactly one `NV_DBG_ERRORS` log line MUST be emitted
  citing the BDF and channel state
- **AND** `tb_egpu_dump_aer_trigger_event(pci_dev, "error-handler", NULL)`
  MUST be called
- **AND** `fire_count` MUST be incremented atomically
- **AND** `last_fire_jiffies` MUST be set to `jiffies`
- **AND** a `TB_EGPU_GPU_STATE=RECOVERING` uevent MUST be emitted
  against `pci_dev->dev.kobj`
- **AND** the function MUST return `PCI_ERS_RESULT_NEED_RESET`

#### Scenario: slot_reset on bus-still-down PMC_BOOT_0 returns DISCONNECT and surrenders
- **GIVEN** the kernel (or the explicit dispatch from the work
  handler) calls `slot_reset` on the GPU pdev
- **AND** the `ioread32` at `bar0_phys` returns `0xffffffff` (bus
  still down)
- **WHEN** `tb_egpu_recover_slot_reset(pdev)` runs
- **THEN** the function MUST emit one `NV_DBG_ERRORS` log line
  identifying the PMC_BOOT_0 value and the DISCONNECT decision
- **AND** `surrender_count` MUST be incremented atomically
- **AND** a `TB_EGPU_GPU_STATE=PERMANENT_FAIL` uevent MUST be emitted
- **AND** the function MUST return `PCI_ERS_RESULT_DISCONNECT`

#### Scenario: slot_reset on healthy PMC_BOOT_0 returns RECOVERED and resume fires
- **GIVEN** `slot_reset` finds `PMC_BOOT_0 != 0xffffffff`
- **WHEN** `tb_egpu_recover_slot_reset(pdev)` runs and the caller
  subsequently invokes `tb_egpu_recover_slot_reset_resume(pdev)`
- **THEN** `slot_reset` MUST emit one `NV_DBG_ERRORS` line citing the
  read value and return `PCI_ERS_RESULT_RECOVERED`
- **AND** `success_count` MUST be incremented atomically
- **AND** a `TB_EGPU_GPU_STATE=READY` uevent MUST be emitted
- **AND** `attempt_count` MUST NOT be reset here (the reset happens
  only at verified post-`rm_init_adapter`-OK)

### Requirement: Work handler SHALL drive `pci_reset_bus` on the upstream Thunderbolt bridge and explicitly dispatch `slot_reset` / `resume`

The recovery work item handler SHALL acquire the upstream bridge via
`pci_upstream_bridge(pdev)`, refuse to proceed and surrender if no
bridge is available, emit one mandatory `NV_DBG_ERRORS` log line
announcing the reset, emit a `RECOVERING` uevent, call
`pci_lock_rescan_remove()` / `pci_reset_bus(bridge)` /
`pci_unlock_rescan_remove()`, `msleep(NVreg_TbEgpuRecoverResetSettleMs)`
to let the link retrain, log the result. On `pci_reset_bus`
failure the handler SHALL increment `surrender_count`, emit
`PERMANENT_FAIL`, and return. On success the handler SHALL EXPLICITLY
call `tb_egpu_recover_slot_reset(pdev)` because `pci_reset_bus` does
NOT itself dispatch `pci_error_handlers` callbacks (only the
AER-driven NEED_RESET path does); on `PCI_ERS_RESULT_RECOVERED` the
handler SHALL EXPLICITLY call `tb_egpu_recover_slot_reset_resume(pdev)`
to reach the same completion state (success_count++, READY uevent)
the AER-driven path reaches for free. The handler MUST `pci_dev_put`
the pdev, NULL out `pdev_for_work`, and `atomic_set(&in_progress, 0)`
under every exit path so the next trigger can re-arm. The handler
SHALL run in workqueue context (process context, may sleep,
pre-emption permitted).

#### Scenario: Successful recovery walks through reset + explicit slot_reset + explicit resume
- **GIVEN** the work handler runs with `pdev_for_work` holding a
  refcounted pdev and a valid upstream bridge
- **AND** `pci_reset_bus(bridge)` returns `0`
- **AND** the explicit `slot_reset` dispatch returns
  `PCI_ERS_RESULT_RECOVERED`
- **WHEN** `tb_egpu_recover_reset_work_handler` runs
- **THEN** one `NV_DBG_ERRORS` log line MUST announce the reset
  starting on the bridge BDF, the GPU BDF, the attempt count, and the
  settle time
- **AND** a `TB_EGPU_GPU_STATE=RECOVERING` uevent MUST be emitted
- **AND** `pci_lock_rescan_remove` MUST be held across the
  `pci_reset_bus` call
- **AND** `msleep(NVreg_TbEgpuRecoverResetSettleMs)` MUST be invoked
  before any verification
- **AND** `tb_egpu_recover_slot_reset(pdev)` MUST be called
- **AND** `tb_egpu_recover_slot_reset_resume(pdev)` MUST be called
- **AND** `pci_dev_put(pdev)` MUST run before exit
- **AND** `pdev_for_work` MUST be `NULL` after exit
- **AND** `atomic_set(&in_progress, 0)` MUST be the final action

#### Scenario: pci_reset_bus failure surrenders cleanly
- **GIVEN** the work handler reaches `pci_reset_bus(bridge)` and the
  call returns a non-zero error code
- **WHEN** the handler examines the result
- **THEN** one `NV_DBG_ERRORS` log line MUST announce the failure and
  the `rc` value
- **AND** `surrender_count` MUST be incremented atomically
- **AND** a `TB_EGPU_GPU_STATE=PERMANENT_FAIL` uevent MUST be emitted
- **AND** the handler MUST NOT dispatch `slot_reset` / `resume`
- **AND** the handler MUST still `pci_dev_put(pdev)`, NULL out
  `pdev_for_work`, and clear `in_progress`

### Requirement: Driver SHALL gate every recovery schedule through one shared `pre_schedule_gates` function that enforces H1 / H2 / H3

The driver SHALL provide one `tb_egpu_recover_pre_schedule_gates(st,
pdev, &reason_out)` function called by both the post-rmInit-FAIL
trigger and the AER `error_detected` callback so the two trigger
paths cannot diverge. The function SHALL return
`TB_EGPU_RECOVER_GATE_DISABLED` when `st == NULL` or
`NVreg_TbEgpuRecoverEnable == 0`. The function SHALL, before any other
check, reset `attempt_count` to `0` when `last_fire_jiffies != 0` and
the elapsed time since `last_fire_jiffies` exceeds
`NVreg_TbEgpuRecoverSurrenderResetSec` seconds (the H1 idle
burst-boundary). The function SHALL return
`TB_EGPU_RECOVER_GATE_RATE_LIMITED` when `last_fire_jiffies != 0` and
the elapsed time is below `NVreg_TbEgpuRecoverMinAttemptIntervalMs`
(the H2 per-device rate limit). The function SHALL
`atomic_inc_return(&attempt_count)` and return
`TB_EGPU_RECOVER_GATE_SURRENDER` if the post-increment value exceeds
`NVreg_TbEgpuRecoverMaxAttempts`, also incrementing
`surrender_count` and emitting a `PERMANENT_FAIL` uevent against
`pdev` so the caller does not need to repeat those side effects. The
function SHALL return `TB_EGPU_RECOVER_GATE_OK` otherwise. The
`reason_out` parameter (optional) SHALL receive a short static-string
reason suitable for the caller's log line.

#### Scenario: Gate reset on idle burst boundary clears attempt_count
- **GIVEN** `attempt_count == 3` from a prior burst
- **AND** `NVreg_TbEgpuRecoverMaxAttempts == 3`
- **AND** the time since `last_fire_jiffies` is greater than
  `NVreg_TbEgpuRecoverSurrenderResetSec` seconds
- **WHEN** `tb_egpu_recover_pre_schedule_gates(st, pdev, &reason)`
  runs
- **THEN** `attempt_count` MUST be reset to `0` before any other
  check
- **AND** the function MUST then check H2 and H1 against the fresh
  counter (so an idle device that re-enters trouble does not
  start by surrendering)

#### Scenario: H2 rate-limit defers a too-quick re-trigger
- **GIVEN** `last_fire_jiffies` is recent (elapsed < MinIntervalMs)
- **WHEN** the gate function runs
- **THEN** the function MUST return `TB_EGPU_RECOVER_GATE_RATE_LIMITED`
- **AND** `attempt_count` MUST NOT be incremented (rate-limit is
  cheaper than H1 and must be checked first)

#### Scenario: H1 cap exhaustion surrenders with PERMANENT_FAIL uevent
- **GIVEN** `attempt_count == NVreg_TbEgpuRecoverMaxAttempts` going
  into this gate call
- **WHEN** the gate function `atomic_inc_return(&attempt_count)`
  yields a value greater than `NVreg_TbEgpuRecoverMaxAttempts`
- **THEN** the function MUST return `TB_EGPU_RECOVER_GATE_SURRENDER`
- **AND** `surrender_count` MUST be incremented atomically
- **AND** a `TB_EGPU_GPU_STATE=PERMANENT_FAIL` uevent MUST be emitted
  against `pdev`
- **AND** `reason_out` (if non-NULL) MUST receive a short string
  citing the H1 exhaustion

### Requirement: Driver SHALL reset `attempt_count` ONLY on verified end-to-end recovery

The driver SHALL call `tb_egpu_recover_record_post_rminit_ok(nvl)`
from `nv_start_device` AFTER `rm_init_adapter` returns success. The
function SHALL atomically set `attempt_count` to `0` and, if the
previous value was non-zero, MUST log one `NV_DBG_ERRORS` line
announcing the end-to-end recovery completion and the previous
counter value. The driver MUST NOT reset `attempt_count` from
`slot_reset_resume` (bus reset succeeded but GSP boot may still fail)
or from any other intermediate success site (per
`project_lever_m_recover_landed_2026_05_08`: resetting too early
makes the H1 gate unreachable in real-world recovery storms — the
counter cycles 0→1→0 forever).

#### Scenario: Cold-boot rmInit success is a no-op reset
- **GIVEN** `attempt_count == 0` at cold boot (allocated by
  `kzalloc`)
- **WHEN** `nv_start_device` reaches its post-rmInit-OK site after
  `rm_init_adapter` returns success
- **THEN** `tb_egpu_recover_record_post_rminit_ok(nvl)` MUST be called
- **AND** the function MUST be a no-op log-wise (no line emitted,
  because previous counter was `0`)
- **AND** `attempt_count` MUST remain `0`

#### Scenario: Recovery-after-storm rmInit success clears counter and logs
- **GIVEN** a prior burst incremented `attempt_count` to `2` (one
  failed attempt, one in-flight that just succeeded end-to-end)
- **WHEN** `nv_start_device` reaches the post-rmInit-OK site
- **THEN** the function MUST log one `NV_DBG_ERRORS` line citing the
  previous counter value (`2`) and the reset action
- **AND** `attempt_count` MUST be set to `0` atomically
- **AND** the next H1 cap measurement MUST start from a fresh burst

### Requirement: Driver SHALL publish recovery counters as PCI-device sysfs attributes and accept a write-only `force_trigger` test surface

The driver SHALL register an `attribute_group` containing five
attributes under the GPU's PCI device sysfs directory:
`tb_egpu_recover_fires` (cumulative `schedule_work` invocations,
read-only `0444`), `tb_egpu_recover_successes` (cumulative
recoveries that reached `resume`, read-only `0444`),
`tb_egpu_recover_surrenders` (cumulative H1 exhaustions plus
hard-failure surrenders, read-only `0444`),
`tb_egpu_recover_last_fire_jiffies` (last `last_fire_jiffies` value,
read-only `0444`), and `tb_egpu_recover_force_trigger` (write-only
`0200` test path that re-enters
`tb_egpu_recover_trigger_post_rminit_fail` as if from a real failure
— all gates still apply). When `nvl->recover` is `NULL` (master
disable engaged) each read attribute SHALL emit the `"0\n"`
placeholder via `scnprintf`. The sysfs attribute group SHALL be
created in `tb_egpu_recover_init` (failure is non-fatal — recovery
still runs but without userspace counters) and removed in
`tb_egpu_recover_stop` before the work item is drained.

#### Scenario: Cold-boot sysfs read returns zero counters
- **GIVEN** a freshly probed eGPU with `NVreg_TbEgpuRecoverEnable == 1`
- **AND** no recovery has fired yet (`fire_count == 0`)
- **WHEN** an operator reads each of the four read-only counters
- **THEN** `tb_egpu_recover_fires` MUST emit `0\n`
- **AND** `tb_egpu_recover_successes` MUST emit `0\n`
- **AND** `tb_egpu_recover_surrenders` MUST emit `0\n`
- **AND** `tb_egpu_recover_last_fire_jiffies` MUST emit `0\n`

#### Scenario: force_trigger write replays the trigger function
- **GIVEN** a running module with `NVreg_TbEgpuRecoverEnable == 1`
- **AND** `NVreg_TbEgpuRecoverTestForceTrigger == 1`
- **WHEN** an operator writes `1` to
  `/sys/bus/pci/devices/<BDF>/tb_egpu_recover_force_trigger`
- **THEN** the store callback MUST call
  `tb_egpu_recover_trigger_post_rminit_fail(nvl)`
- **AND** if the H1 / H2 / H3 gates pass, the recovery MUST schedule
  the work item exactly as a natural post-rmInit-FAIL trigger would
- **AND** `tb_egpu_recover_fires` MUST observe the increment

### Requirement: Driver SHALL honour the master enable and the persistent kill-switch file at every relevant entry point

The driver SHALL provide `NVreg_TbEgpuRecoverEnable` (uint, default
`0`, mode `0644`) as the master enable. The driver SHALL read the
file at `/var/lib/tb-egpu/recover-killswitch` once at
`tb_egpu_recover_init` time via `kernel_read_file_from_path` (16-byte
cap); if the file is present and its content begins with `'0'`, the
driver SHALL override `NVreg_TbEgpuRecoverEnable` to `0` and SHALL
emit one `NV_DBG_ERRORS` log line announcing the override. When
`NVreg_TbEgpuRecoverEnable == 0` at probe time the driver SHALL skip
the state allocation (`nvl->recover = NULL`) and SHALL ensure every
later entry point (`trigger_post_rminit_fail`,
`check_wpr2_at_probe`, `record_post_rminit_ok`,
`pre_schedule_gates`, the sysfs `force_trigger`) bails out
gracefully on `nvl->recover == NULL`. The `tb_egpu_recover_stop`
function MUST tolerate `nvl->recover == NULL` (clean unload on a
disabled device is a no-op).

#### Scenario: Master disable at module load suppresses state allocation
- **GIVEN** `NVreg_TbEgpuRecoverEnable == 0` at module load
- **WHEN** `tb_egpu_recover_init(nvl)` runs
- **THEN** the function MUST emit one `NV_DBG_INFO` line announcing
  the disabled state
- **AND** `nvl->recover` MUST be `NULL`
- **AND** the function MUST return `0`
- **AND** subsequent calls to
  `tb_egpu_recover_trigger_post_rminit_fail(nvl)`,
  `tb_egpu_recover_record_post_rminit_ok(nvl)`, and
  `tb_egpu_recover_check_wpr2_at_probe(nvl, ...)` MUST be no-ops

#### Scenario: Persistent kill-switch file overrides cmdline Enable=1
- **GIVEN** `NVreg_TbEgpuRecoverEnable == 1` from the cmdline /
  modprobe.d default
- **AND** `/var/lib/tb-egpu/recover-killswitch` exists and its
  first byte is `'0'`
- **WHEN** the first device's `tb_egpu_recover_init(nvl)` runs
- **THEN** the file read MUST succeed and force
  `NVreg_TbEgpuRecoverEnable` to `0`
- **AND** one `NV_DBG_ERRORS` log line MUST announce the override
- **AND** `nvl->recover` MUST be `NULL` for THIS device and every
  subsequent device probed after the override

### Requirement: Driver SHALL drain pending work and free state cleanly on remove

The driver SHALL invoke `tb_egpu_recover_stop(nvl)` from
`nv_pci_remove_helper` after [[A2-bus-loss-watchdog]]'s
`tb_egpu_qwd_stop(nvl)` and before any other state teardown. The
function SHALL remove the sysfs attribute group (idempotent against
`nvl->recover == NULL`), then `cancel_work_sync(&st->reset_work)` so
the work handler has fully returned before any state is freed, then
`pci_dev_put` any straggler refcount on `pdev_for_work` (defensive —
the handler normally does this itself), `kfree(st)`, and set
`nvl->recover = NULL`. The function MUST tolerate `nvl == NULL` and
`nvl->recover == NULL`.

#### Scenario: Normal unload drains the work handler and frees state
- **GIVEN** a probed eGPU with a running recovery state and a
  potentially in-flight work item
- **WHEN** `tb_egpu_recover_stop(nvl)` is called from the remove path
- **THEN** the sysfs attribute group MUST be removed first
- **AND** `cancel_work_sync(&st->reset_work)` MUST block until the
  handler returns
- **AND** any straggler `pdev_for_work` refcount MUST be released
- **AND** `kfree(st)` MUST run only after the handler has returned
- **AND** `nvl->recover` MUST be `NULL` after the call returns

## Scope boundary

- This patch deliberately does NOT poll PMC_BOOT_0 for bus-loss
  detection. Active heartbeat polling is [[A2-bus-loss-watchdog]]'s
  responsibility; A3 only consumes A2's latched state and the
  kernel's AER dispatch.
- This patch does NOT expose the PCIe / AER / WPR2 register-read
  primitives or the topology walker. Those live in
  [[A1-pcie-primitives]]; A3 consumes them as a star-dependency
  consumer.
- This patch does NOT instrument the RM close-path or any UVM
  open/release lifecycle event. Close-path observability is
  [[A4-close-path-telemetry]]'s scope.
- This patch does NOT register the `pci_error_handlers` table.
  Registration is owned by [[C4-err-handlers-scaffold]]; A3 only
  fills the body slots that C4 declares and adds the
  `cor_error_detected` slot (C4's struct does not include it
  because the cor-error callback is purely observability-tier and
  upstream review may treat it as non-load-bearing).
- This patch does NOT preserve PCIe bridge-link-cap state across
  `pci_reset_bus`. Bridge LnkCtl2 (Gen3 + bit 5) is set ONCE at
  boot by the userspace L4 helper
  (`usr/local/sbin/nvidia-driver-injector-bridge-link-cap`) BEFORE
  nvidia.ko binds; that boot-time write commits the TB tunnel rate
  for the session. A3 relies on the cap being pre-set; A3 itself
  does NOT save / restore the bridge config across the reset. The
  M-recover series name "preserve bridge-link-cap" describes the
  L4 service contract, not A3 in-driver logic.
- This patch does NOT preserve BAR1 sizing across the reset. BAR1
  preservation was scoped as M-preserve in the legacy series and
  was explicitly dropped from the addon-recarve design (per
  `project_addon_recarve_merged_2026_05_22`: A3 is recover-only,
  M-preserve is out of scope).
- This patch does NOT propagate the kernel-side disconnect via
  `os_pci_set_disconnected`. That propagation is
  [[C5-crash-safety]]'s API surface; [[A2-bus-loss-watchdog]] calls
  into it from the watchdog kthread. A3 emits uevents
  (`READY` / `RECOVERING` / `PERMANENT_FAIL`) for userspace
  observability but does NOT touch C5's disconnect state directly.
- This patch does NOT introduce a build-time `CONFIG_NV_TB_EGPU`
  gate on its source-list line. The master toggle is owned by
  `A5-version-and-toggles` and applies at the consumer-call-site
  level (this file plus A2 plus A4); A3 compiles unconditionally
  once its row in `nvidia-sources.Kbuild` is in effect. A3
  instead exposes runtime `NVreg_TbEgpuRecoverEnable` (master
  enable) and five tuning module parameters for operator control.
- This patch does NOT implement a userspace recovery helper.
  Pre-A3 the project ran `aorus-5090-wpr2-recovery.service`
  (an L4 systemd helper) to perform WPR2-stuck recovery from
  userspace; A3 supersedes that helper. The userspace service is
  preserved as a belt-and-braces fallback during the
  cutover/soak window (per
  `project_lever_m_recover_landed_2026_05_08` §7) but is targeted
  for retirement once A3's production posture is proven.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| Post-rmInit-FAIL trigger scheduled recovery | `NV_DBG_ERRORS` (err) | `"tb_egpu recover: scheduling recovery (attempt=%d/%u, WPR2=0x%08x, ForceTrigger=%u, fires=%d)\n"` |
| Post-rmInit-FAIL but WPR2 clear (not the failure mode) | `NV_DBG_INFO` (info) | `"tb_egpu recover: post-rmInit-FAIL but WPR2 clear (raw=0x%08x); not the WPR2-stuck failure mode; not triggering\n"` |
| Trigger gated (rate-limit / disabled) | `NV_DBG_ERRORS` (err) | `"tb_egpu recover: trigger gated (%s); deferring\n"` |
| Trigger gated (surrender) | `NV_DBG_ERRORS` (err) | `"tb_egpu recover: trigger gated (%s); emitting PERMANENT_FAIL\n"` |
| Re-entry guard suppressed concurrent trigger | `NV_DBG_ERRORS` (err) | `"tb_egpu recover: trigger fired but in_progress=1; previous attempt still running; skipping\n"` |
| Work handler: bus reset starting | `NV_DBG_ERRORS` (err) | `"tb_egpu recover: bus-reset starting on bridge %s (GPU=%s; attempt=%d/%u; settle=%ums)\n"` |
| Work handler: bus reset failed | `NV_DBG_ERRORS` (err) | `"tb_egpu recover: pci_reset_bus(%s) FAILED rc=%d; emitting PERMANENT_FAIL\n"` |
| Work handler: bus reset succeeded | `NV_DBG_ERRORS` (err) | `"tb_egpu recover: pci_reset_bus(%s) OK; dispatching slot_reset + resume helpers explicitly\n"` |
| Work handler: no upstream bridge | `NV_DBG_ERRORS` (err) | `"tb_egpu recover: no upstream bridge for %s; cannot bus-reset; surrendering\n"` |
| **slot_reset DISCONNECT (mandatory tier)** | **`NV_DBG_ERRORS` (err)** | `"tb_egpu recover: slot_reset — PMC_BOOT_0=0xffffffff (bus still down); DISCONNECT\n"` |
| **slot_reset RECOVERED (mandatory tier)** | **`NV_DBG_ERRORS` (err)** | `"tb_egpu recover: slot_reset — PMC_BOOT_0=0x%08x; RECOVERED\n"` |
| **resume: READY uevent + success_count++ (mandatory tier)** | **`NV_DBG_ERRORS` (err)** | `"tb_egpu recover: resume — success_count=%d, bus reset done; emitting READY (attempt_count cleared at next post-rmInit-OK)\n"` |
| Verified end-to-end recovery (attempt_count reset) | `NV_DBG_ERRORS` (err) | `"tb_egpu recover: post-rmInit-OK observed with attempt_count=%d; verified end-to-end recovery — resetting attempt_count to 0\n"` |
| AER error_detected first fire | `NV_DBG_ERRORS` (err) | `"tb_egpu recover: AER error_detected fired on %04x:%02x:%02x.%x (channel state=%d)\n"` |
| AER error_detected gate decision | `NV_DBG_ERRORS` (err) | `"tb_egpu recover: error_detected -> %s (%s; attempts=%d/%u)\n"` |
| AER mmio_enabled callback fired | `NV_DBG_ERRORS` (err) | `"tb_egpu recover: mmio_enabled callback fired on %s\n"` |
| AER cor_error_detected callback fired | `NV_DBG_ERRORS` (err) | `"tb_egpu recover: cor_error_detected callback fired on %s\n"` |
| Probe-time WPR2 stuck (detection-only) | `NV_DBG_ERRORS` (err) | `"tb_egpu recover: probe WPR2 DETECTED up (raw=0x%08x val=0x%08x). Detection-only at probe; the load-bearing trigger is the post-rmInit-FAIL hook in nv_start_device. fire_count=%d\n"` |
| Killswitch file engaged | `NV_DBG_ERRORS` (err) | `"tb_egpu recover: killswitch file engaged (%s=0); overriding NVreg_TbEgpuRecoverEnable to 0\n"` |
| Master disable at module load | `NV_DBG_INFO` (info) | `"tb_egpu recover: disabled at module load (NVreg_TbEgpuRecoverEnable=0); state not allocated\n"` |
| Init succeeded | `NV_DBG_INFO` (info) | `"tb_egpu recover: scaffolding initialised (MaxAttempts=%u, SettleMs=%u, MinIntervalMs=%u, ResetSec=%u)\n"` |
| Sysfs force_trigger write fired | `NV_DBG_ERRORS` (err) | `"tb_egpu recover: sysfs force_trigger fired (val=%lu) — invoking trigger as if from post-rmInit-FAIL\n"` |

The mandatory-tier events are the recovery success / surrender / and
per-slot_reset decision logs. Every recovery cycle reaches at least
one mandatory log line (slot_reset's PMC_BOOT_0 read decides
RECOVERED-or-DISCONNECT and emits the corresponding line) plus the
per-cycle uevent (`RECOVERING` → `READY` or `PERMANENT_FAIL`). The
`tb_egpu_recover_surrenders` counter is read by the standing soak
gate (per the upstream-plan Gate §5) — a non-zero value in a
soak window blocks promotion.

## Provenance

- **Source cluster:** Carved from legacy cluster P2 (the recovery
  state machine portion of `patches/legacy/0004-pci-err-handlers-and-recovery.patch`
  plus the hardening patches 0024 / 0026 / 0027 / 0028 / 0029 from the
  2026-05-08 Lever M-recover landing —
  `project_lever_m_recover_landed_2026_05_08`,
  `project_m_recover_first_real_fire_2026_05_08`) during the
  2026-05-22 addon-recarve campaign
  (`project_addon_recarve_merged_2026_05_22`). The recarve reshaped
  the legacy single-file `nv-lever-m-recover.c` into two layers:
  the shared register-read primitives moved to [[A1-pcie-primitives]]
  (so [[A2-bus-loss-watchdog]] and [[A4-close-path-telemetry]] could
  consume them without a sibling-addon dependency), and the
  pure-state-machine code stayed here as A3. The `pci_error_handlers`
  registration was separated again into [[C4-err-handlers-scaffold]]
  (registration only; upstream-bound) so A3 fills C4's stub bodies
  with real recovery logic instead of duplicating the registration.
- **Vanilla baseline:** Two new files (`nv-tb-egpu-recover.c` 854
  lines, `nv-tb-egpu-recover.h` 228 lines) with no vanilla
  counterpart. Four vanilla files modified additively:
  `kernel-open/common/inc/nv-linux.h` gains one new field
  `struct tb_egpu_recover_state *recover;` at the end of
  `struct nv_linux_state_s` (immediately after A2's `qwd` field).
  `kernel-open/nvidia/nv-pci.c` gains one `#include`, two probe-path
  calls (`tb_egpu_recover_init` + `tb_egpu_recover_check_wpr2_at_probe`),
  one remove-path call (`tb_egpu_recover_stop`), real bodies for the
  C4-registered `error_detected` / `mmio_enabled` / `slot_reset` /
  `resume` callbacks, and a new `cor_error_detected` callback added
  to the `pci_error_handlers` struct. `kernel-open/nvidia/nv.c`
  gains one `#include` and two calls in `nv_start_device` — one
  `tb_egpu_recover_trigger_post_rminit_fail(nvl)` after the
  `rm_init_adapter` failure log and one
  `tb_egpu_recover_record_post_rminit_ok(nvl)` after the success
  path. `kernel-open/nvidia/nvidia-sources.Kbuild` gains one
  additive line `NVIDIA_SOURCES += nvidia/nv-tb-egpu-recover.c`
  after A2's line.
- **Fork branch:** `a3-recovery` on `apnex/open-gpu-kernel-modules`
  (sits on top of the cumulative `a2-bus-loss-watchdog` base; the
  cumulative diff carries C1-C5 + E1 + A1 + A2 + A3 at tip
  `60dfe4c7f2bcb4fdae4be1d4073f432ebfba4f40` (sub-cycle 4 paired
  cascade; previously `f57a38b2f45b7f757e1982734e587336bb25606a`
  at sub-cycle 3 close).
- **A1 ABI consumed:** A3 calls A1's
  `tb_egpu_pcie_read_wpr2(bar0_phys, &raw)` verbatim from both
  the probe-time check and the post-rmInit-FAIL trigger; masks the
  result with A1's `TB_EGPU_PCIE_WPR2_VAL_MASK` constant; and
  calls A1's `tb_egpu_dump_aer_trigger_event(pci_dev, "<event>", out)`
  three times from `nv-pci.c` (event tags `"error-handler"`,
  `"mmio-enabled"`, `"cor-error"`). The `"qwd-detect"` call site
  (formerly inserted into `nv-tb-egpu-qwd.c` by A3's patch as a
  cross-cluster edit) was hoisted INTO A2's commit in sub-cycle 4
  per A3-recovery-I1 (see catalog "Improvements landed (sub-cycle 4)"
  section). A3 no longer reaches into A2's TU. The topology walker,
  DPC reader, and full AER reader from A1's surface are NOT
  directly called by A3 in v1;
  they are reachable through `tb_egpu_dump_aer_trigger_event` which
  composes them internally.
- **A2 ABI consumed:** A3 patches into A2's translation unit
  (`nv-tb-egpu-qwd.c:tb_egpu_qwd_thread`) to add one call —
  `tb_egpu_dump_aer_trigger_event(nvl->pci_dev, "qwd-detect", &qwd->last_aer)`
  — at A2's per-episode detection latch. A3 also reads A2's latched
  AER snapshot (`nvl->qwd->last_aer.valid`) as a trigger condition
  via the body-prose contract documented in A2's review (the
  contract is documentary in v1 — A3's `nv-tb-egpu-recover.c` does
  NOT directly read `nvl->qwd->last_aer` in v1; the AER snapshot
  exists for sysfs-visible observability and incident forensics).
- **C4 ABI consumed:** A3 fills the body slots of the
  `pci_error_handlers` struct that C4 registered with stub bodies:
  `error_detected` (state-aware → `NEED_RESET` on `GATE_OK`,
  `DISCONNECT` otherwise), `mmio_enabled` (observability →
  `RECOVERED`), `slot_reset` (PMC_BOOT_0 read → `RECOVERED` or
  `DISCONNECT`), `resume` (success_count++ + READY uevent). A3 also
  adds the `cor_error_detected` slot to the struct — C4's
  registration declared the struct's fields up to `.resume`; A3's
  hunk appends `.cor_error_detected = nv_pci_cor_error_detected`.
- **C5 ABI consumed:** A3 does NOT directly call into [[C5-crash-safety]]'s
  `os_pci_set_disconnected` API. The disconnect propagation on
  dead-bus detection is owned by [[A2-bus-loss-watchdog]] (the
  watchdog kthread calls C5's API on first detection). A3
  observes disconnect state via the same `pci_get_drvdata` →
  `nvl->recover` lookup but does NOT directly toggle the
  disconnect flag. The PERMANENT_FAIL uevent is A3's userspace
  surface; the kernel-side disconnect propagation runs in parallel
  via A2 / C5.
- **Module parameter surface:** six parameters, all `uint` /
  mode `0644`, all `module_param`-registered and
  `MODULE_PARM_DESC`-documented.
  `NVreg_TbEgpuRecoverEnable` (default `0` — see "TODO: flip to 1
  once production soak passes" comment), `NVreg_TbEgpuRecoverMaxAttempts`
  (H1 cap, default `3`), `NVreg_TbEgpuRecoverResetSettleMs`
  (post-reset delay, default `500`),
  `NVreg_TbEgpuRecoverMinAttemptIntervalMs` (H2 rate-limit, default
  `30000`), `NVreg_TbEgpuRecoverSurrenderResetSec` (H1 burst-boundary
  idle, default `300`), `NVreg_TbEgpuRecoverTestForceTrigger`
  (Phase 3 test override, default `0`).
- **Sysfs surface:** Five attributes under each eGPU's PCI device
  kobject — `tb_egpu_recover_fires`, `tb_egpu_recover_successes`,
  `tb_egpu_recover_surrenders`, `tb_egpu_recover_last_fire_jiffies`
  (all read-only `0444`), `tb_egpu_recover_force_trigger`
  (write-only `0200`). The four counters are read by the standing
  soak gate; the force-trigger is the Phase 3 test entry point.
- **Persistent kill-switch surface:** A3 reads
  `/var/lib/tb-egpu/recover-killswitch` once at
  `tb_egpu_recover_init` time. Userspace tooling (udev rule + CLI
  binary) maintains the file. The file is the H3 hardening — if
  recovery itself misbehaves, an operator writes `0` to the file
  and reboots; the driver then comes up disabled even though
  `NVreg_TbEgpuRecoverEnable == 1`.
- **Uevent surface:** Three states emitted as
  `TB_EGPU_GPU_STATE=<state>` on the GPU pdev's kobject —
  `RECOVERING` (recovery scheduled), `READY` (resume callback fired
  → recovery succeeded), `PERMANENT_FAIL` (surrender — H1
  exhausted, no upstream bridge, slot_reset bus-down, or
  `pci_reset_bus` failed). Userspace subscribers (udev rules,
  vLLM container restart hooks) act on the uevents.
- **Upstream issue:** n/a. Addon-layer recovery state machine is
  project-local and never upstream-bound (per Rule 5:
  `upstream-candidacy: n/a` is the only allowed value for
  `layer: addon`). The mechanism (post-rmInit-FAIL trigger +
  pci_reset_bus + explicit slot_reset / resume dispatch +
  H1/H2/H3 hardening + persistent kill-switch file) is specific
  to the project's failure taxonomy and operational policy.
  Upstream NVIDIA's bug #979 covers the underlying failure mode;
  recovery is the project's local response, not a candidate for
  upstream.
