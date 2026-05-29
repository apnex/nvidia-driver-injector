# A9 patch intent (DRAFT — not yet bound to manifest)

**Date:** 2026-05-29 evening
**Status:** Draft — design captured pre-implementation; will graduate to `docs/patch-intents/A9-f40b-in-driver-recovery.md` (and a manifest row) when implementation begins
**Cross-refs:**
- `in-driver-recovery-target-2026-05-29.md` (sibling design doc — the architectural context)
- `F40b-structural-fix-2026-05-29.md` (sibling design doc — the current Tier 2 fix this builds on)
- `../../patch-intents/A3-recovery.md` (analogous existing state machine; A9 reuses its primitives)
- `../../patch-intent-schema.md` (the schema this draft will conform to when promoted)

> When this draft is promoted to `docs/patch-intents/A9-f40b-in-driver-recovery.md`, the frontmatter below will be authoritative and intent-lint will enforce it. Until then this is design prose.

## Proposed frontmatter (will become the lint-checked spec once A9 implementation starts)

```yaml
id: A9-f40b-in-driver-recovery
layer: addon
source-branch: a9-f40b-in-driver-recovery
upstream-candidacy: n/a
telemetry-tier: mandatory
status: draft
related-patches: [A1-pcie-primitives, A3-recovery, A6-f40b-bounded-wait-open, A7-f40b-bounded-wait-shutdown, A8-f40b-sysfs-observability, C5-crash-safety, E1-egpu-detection]
```

# A9-f40b-in-driver-recovery — In-Driver Recovery State Machine for F40b-Triggered Wedges

## Purpose

Eliminate the userspace orchestration round-trip currently required to recover from F40-class wedges. After A6 (F40b Tier 2 bounded-wait wrapper) catches the wedge condition and returns -EIO, the chip is in a C5-sink-set lost state and is unusable until the operator runs the documented `rmmod + TB cycle + fix-bar1 + modprobe` sequence (~17 seconds wall-clock). A9 moves that sequence into the driver: on F40b timeout, schedule a recovery worker that performs the chip-side reset, BAR restoration, and re-probe entirely in kernel context, then clears the sink. Userspace sees a brief -EIO followed by a healthy GPU on retry, ~5-10 seconds later. No rmmod/modprobe round-trip, no DaemonSet watchdog, no external service. Matches the Windows TDR reference model (see `docs/missions/mission-1-egpu-hot-plug-hot-power/design/in-driver-recovery-target-2026-05-29.md`).

## Requirements

### Requirement: Driver SHALL schedule recovery on F40b timeout when feature is enabled and chip is E1-classified

The recovery worker MUST be scheduled exactly when A6's `nv_open_device_for_nvlfp_bounded` hits its timeout path. The schedule MUST be gated on:

- `NVreg_TbEgpuRecoverEnable == 1` (master enable, shared with A3)
- `NVreg_TbEgpuF40bRecoverEnable == 1` (per-feature enable, defaults to 1)
- `nv->is_external_gpu` (E1 classification — non-eGPUs SHALL NOT have F40b recovery scheduled)

When all gates pass, the F40b timeout path SHALL:

1. Set C5 sink-state via `rm_cleanup_gpu_lost_state(... NV_GPU_LOST_DETECTOR_F40B_OPEN_TIMEOUT)` (new detector value; see Telemetry contract). The current A6 code uses `NV_GPU_LOST_DETECTOR_AER_FATAL` as a placeholder; A9 SHALL introduce a dedicated detector class to enable correct telemetry routing.
2. Increment `tb_egpu_f40b_fires` counter (exposed by A8).
3. Transition state to `recovering` (exposed by A8's `tb_egpu_state` attribute).
4. Schedule the recovery worker via the existing A3 work queue (or a dedicated F40b-recovery work queue — implementation choice).
5. Return -EIO to the syscall caller (unchanged from A6 behaviour).

Driver MUST NOT block the syscall thread waiting for recovery to complete — the syscall thread returns immediately after scheduling.

#### Scenario: F40b timeout schedules recovery on E1-classified eGPU

```
GIVEN nvidia.ko is loaded with NVreg_TbEgpuRecoverEnable=1 and NVreg_TbEgpuF40bRecoverEnable=1
AND   the chip is E1-classified (nv->is_external_gpu is true)
AND   A6's bounded-wait wrapper hits its timeout on a chip-touching open
WHEN  the F40b timeout path executes
THEN  C5 sink-state is set via rm_cleanup_gpu_lost_state with DETECTOR_F40B_OPEN_TIMEOUT
AND   tb_egpu_f40b_fires counter is incremented
AND   tb_egpu_state transitions to "recovering"
AND   a recovery work item is scheduled
AND   the syscall returns -EIO to userspace within the configured timeout budget
```

#### Scenario: F40b timeout on non-eGPU does NOT schedule recovery

```
GIVEN nvidia.ko is loaded with both enables set
AND   the chip is NOT E1-classified (nv->is_external_gpu is false)
WHEN  the F40b timeout path executes (which would only happen if a non-eGPU somehow hits the bounded wrapper)
THEN  no recovery work item is scheduled
AND   the existing A6 behaviour (sink-set + -EIO) is preserved without addition
```

#### Scenario: F40b timeout with master disable does NOT schedule recovery

```
GIVEN nvidia.ko is loaded with NVreg_TbEgpuRecoverEnable=0
AND   the chip is E1-classified
WHEN  the F40b timeout path executes
THEN  no recovery work item is scheduled
AND   the existing A6 behaviour (sink-set + -EIO) is preserved without addition
AND   tb_egpu_f40b_fires counter is still incremented (telemetry survives gating)
AND   tb_egpu_state remains "lost-temporary"
```

### Requirement: Recovery worker SHALL execute the documented chip-reset sequence in-kernel and SHALL gate every attempt through pre-schedule gates

The recovery worker MUST execute the following sequence, in order, with each step gated and instrumented:

1. **Pre-schedule gates (reuse A3's `pre_schedule_gates`):** H1 (max attempts), H2 (rate limit), H3 (concurrent-fire guard). If gates fail, the worker SHALL emit `PERMANENT_FAIL` uevent equivalent via state transition to `lost-permanent` and abort.
2. **PCI bus reset:** `pci_reset_bus(pdev->bus)` on the upstream Thunderbolt bridge (reuse A3 / Lever M-recover infrastructure).
3. **Thunderbolt rebind:** call `tb_switch_unauthorize` then `tb_switch_authorize` on the TB switch holding this device. This is the kernel-side equivalent of `echo 0 > authorized; echo 1 > authorized` from userspace. If the `tb_*` API surface is insufficient, fall back to direct PCI config-space link control writes on the parent bridge (documented as the escape hatch).
4. **BAR1 restoration:** detect broken-BAR1 state via `pci_resource_len(pdev, 1)`; if smaller than expected 32 GiB, perform ReBAR resize via `pci_resize_resource(pdev, 1, NV_GB202_BAR1_LOG_SIZE_BYTES)`. This is the kernel-side equivalent of fix-bar1.sh's ReBAR Control write.
5. **Probe re-run:** re-invoke the nvidia.ko probe path's chip-init for this device. This SHALL NOT involve `rmmod` / `modprobe` — the work happens in the existing bound module's context.
6. **Verification:** issue a passive MMIO probe (PMC_BOOT_0 via A1's primitive); if value is the expected chip-identity 0x1b2000a1, recovery is verified.
7. **Sink clear:** on verified end-to-end recovery, atomically clear the C5 sink-state (PDB_PROP_GPU_IS_LOST cleared + Linux-side device error_state cleared if set) and transition `tb_egpu_state` to `healthy`. Reset `attempt_count` to 0.

Driver MUST emit a mandatory-tier telemetry line at the end of each attempt indicating the final outcome (`RECOVERED` or `DISCONNECT-permanent` or `DISCONNECT-rate-limited`).

#### Scenario: Successful single-attempt recovery on F40b fire

```
GIVEN F40b has just fired and scheduled a recovery work item
AND   pre-schedule gates all pass (first attempt of the period)
WHEN  the recovery worker runs
THEN  pci_reset_bus succeeds on the upstream Thunderbolt bridge
AND   tb_switch_unauthorize + tb_switch_authorize complete successfully
AND   ReBAR resize restores BAR1 to 32 GiB
AND   probe re-run completes within timeout
AND   PMC_BOOT_0 reads 0x1b2000a1 (verifying the chip is responsive)
AND   C5 sink is cleared atomically
AND   tb_egpu_state transitions to "healthy"
AND   tb_egpu_recovery_count is incremented
AND   total wall-clock from F40b fire to healthy is within the documented budget (target ~10 sec)
```

#### Scenario: Recovery fails after N attempts and surrenders

```
GIVEN F40b has fired and previous recovery attempts have failed
AND   pre-schedule gate H1 (max attempts) fires
WHEN  the F40b timeout path checks gates
THEN  no further recovery work item is scheduled
AND   tb_egpu_state transitions to "lost-permanent"
AND   tb_egpu_recovery_failures counter is incremented
AND   a mandatory-tier kernel log emits the permanent-fail message
AND   future opens on the device receive -EIO via fail-fast (no waiting on F40b timeout, no recovery attempt)
```

#### Scenario: Thunderbolt rebind step fails — recovery gives up cleanly

```
GIVEN the recovery worker has completed pci_reset_bus successfully
AND   the worker calls tb_switch_unauthorize then tb_switch_authorize
WHEN  the tb_switch_authorize call returns an error
THEN  the worker SHALL skip subsequent steps (ReBAR resize, probe re-run)
AND   tb_egpu_state SHALL remain "lost-temporary" (NOT transition to healthy)
AND   tb_egpu_recovery_failures is incremented
AND   a mandatory-tier kernel log emits "tb_egpu f40b-recover: tb_switch_authorize FAILED rc=%d; cannot complete recovery this attempt"
AND   the next F40b fire (if it happens) SHALL re-evaluate gates and may try again until H1 is exhausted
```

### Requirement: Driver SHALL coexist cleanly with A3's existing bus-reset recovery state machine

The recovery state machine introduced by A9 MAY share infrastructure with A3 (pre-schedule gates, work queue, counter publication) but MUST NOT cause A3's recovery to be triggered spuriously, and MUST NOT cause A9's recovery to be skipped when A3 is the legitimate trigger source.

When both A3 and A9 are eligible to trigger recovery for the same chip:

- A3's existing post-rmInit-FAIL trigger SHALL continue to fire as documented in its intent.
- A9's F40b timeout trigger SHALL fire ADDITIONALLY (not exclusively) — the two trigger sources are orthogonal.
- The shared `pre_schedule_gates` SHALL apply to both — a single H1 (max attempts) counter covers both A3 and A9 fires.
- Counters published via A3's existing sysfs attributes SHALL include A9 fires (i.e., A9 increments the same `attempt_count` that A3 reads).

#### Scenario: Both A3 and A9 are triggers — gates are shared

```
GIVEN nvidia.ko is loaded with both A3 and A9 enabled
AND   the chip has been recovered N-1 times in the current period via A3's post-rmInit-FAIL path
WHEN  F40b fires and tries to schedule A9 recovery
THEN  the shared H1 gate observes attempt_count = N-1
AND   if N is the configured max, the gate fires and A9 SHALL surrender (state → lost-permanent)
AND   if attempt_count < max, A9 SHALL proceed with recovery as normal
```

### Requirement: Driver SHALL drain pending recovery work and free state cleanly on remove

When nvidia.ko is unloaded (rmmod) or the device is unbound, any pending or in-flight A9 recovery work item MUST be drained before the remove callback returns. State (work queue, counters, sink-aware flags) MUST be freed.

The drain MUST NOT block indefinitely — if a work item is stuck (the very condition A9 is designed to handle), the drain SHALL time out at a documented bound and the remove callback SHALL proceed with a log warning. This is analogous to A6's "leaked worker" behaviour: a stuck recovery worker should not prevent driver unload.

#### Scenario: rmmod with pending recovery work succeeds within bounded time

```
GIVEN A9 has scheduled a recovery work item that is currently running
WHEN  the operator runs rmmod nvidia
THEN  the remove callback SHALL initiate drain of the work queue
AND   the drain SHALL wait up to NVreg_TbEgpuRecoverDrainTimeoutMs (default 1000ms)
AND   on success, the remove SHALL log "tb_egpu f40b-recover: drained N work items on remove" and complete
AND   on timeout, the remove SHALL log "tb_egpu f40b-recover: drain timed out; abandoning N work items" and complete anyway
```

## Scope boundary

- A9 SHALL NOT address F41 (chip ReBAR Control register reset on TB hot-add). F41 is the chip-side root cause that puts the chip into the userspace-recovered state in the first place; A9 only handles the recovery once F40 fires.
- A9 SHALL NOT recover from PCIe link-down hardware failures. If `pci_reset_bus` fails or returns "device not present," recovery is impossible from kernel space; the worker SHALL surrender and emit permanent-fail.
- A9 SHALL NOT retry the failed open syscall. Userspace sees -EIO; userspace decides whether to retry. This matches Windows TDR semantics (DXGI_ERROR_DEVICE_REMOVED) and is simpler than syscall-level transparency.
- A9 SHALL NOT attempt cross-module recovery (e.g., reset of unrelated PCI devices on the same bus segment). The recovery scope is strictly the eGPU and its upstream TB switch.
- A9 SHALL NOT replace A3's existing recovery for the post-rmInit-FAIL path. The two recovery paths coexist; A9 adds a new trigger source (F40b timeout) and reuses A3's infrastructure where appropriate.
- A9 SHALL NOT touch nvidia_uvm or the DRM stack. Those subsystems learn about the recovery via the existing sink-state propagation in C5.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| **F40b fire scheduled A9 recovery (mandatory tier)** | **`NV_DBG_ERRORS` (err)** | `"tb_egpu f40b-recover: scheduling recovery (attempt=%d/%u, fire_count=%d, F40b_timeout_ms=%u)\n"` |
| F40b fire gated (master disable) | `NV_DBG_ERRORS` (err) | `"tb_egpu f40b-recover: scheduling gated (master disable); not recovering\n"` |
| F40b fire gated (rate limit) | `NV_DBG_ERRORS` (err) | `"tb_egpu f40b-recover: scheduling gated (rate-limited (H2)); deferring\n"` |
| F40b fire gated (surrender after N) | `NV_DBG_ERRORS` (err) | `"tb_egpu f40b-recover: scheduling gated (surrender after %d attempts); emitting PERMANENT_FAIL\n"` |
| Work handler: pci_reset_bus starting | `NV_DBG_ERRORS` (err) | `"tb_egpu f40b-recover: pci_reset_bus starting on bridge %s (GPU=%s; attempt=%d/%u)\n"` |
| Work handler: pci_reset_bus failed | `NV_DBG_ERRORS` (err) | `"tb_egpu f40b-recover: pci_reset_bus(%s) FAILED rc=%d; cannot complete recovery this attempt\n"` |
| Work handler: TB rebind starting | `NV_DBG_ERRORS` (err) | `"tb_egpu f40b-recover: tb_switch unauthorize+authorize starting on switch %s\n"` |
| Work handler: TB rebind failed | `NV_DBG_ERRORS` (err) | `"tb_egpu f40b-recover: tb_switch_authorize FAILED rc=%d; cannot complete recovery this attempt\n"` |
| Work handler: BAR1 resize starting | `NV_DBG_ERRORS` (err) | `"tb_egpu f40b-recover: BAR1 resize starting (current=%llu MiB, target=32768 MiB)\n"` |
| Work handler: BAR1 resize failed | `NV_DBG_ERRORS` (err) | `"tb_egpu f40b-recover: pci_resize_resource FAILED rc=%d; cannot complete recovery this attempt\n"` |
| Work handler: probe re-run starting | `NV_DBG_ERRORS` (err) | `"tb_egpu f40b-recover: chip-init re-run starting\n"` |
| Work handler: probe re-run failed | `NV_DBG_ERRORS` (err) | `"tb_egpu f40b-recover: chip-init re-run FAILED; cannot complete recovery this attempt\n"` |
| **Verification: PMC_BOOT_0 read OK — RECOVERED (mandatory tier)** | **`NV_DBG_ERRORS` (err)** | `"tb_egpu f40b-recover: verification PMC_BOOT_0=0x%08x — RECOVERED (recovery_count=%d, total_ms=%lu)\n"` |
| **Verification: PMC_BOOT_0 read sentinel — DISCONNECT (mandatory tier)** | **`NV_DBG_ERRORS` (err)** | `"tb_egpu f40b-recover: verification PMC_BOOT_0=0x%08x (sentinel) — DISCONNECT; cannot verify recovery\n"` |
| Sink clear succeeded | `NV_DBG_ERRORS` (err) | `"tb_egpu f40b-recover: sink cleared; state -> healthy\n"` |
| Drain on remove (success) | `NV_DBG_INFO` (info) | `"tb_egpu f40b-recover: drained %d work items on remove\n"` |
| Drain on remove (timeout) | `NV_DBG_ERRORS` (err) | `"tb_egpu f40b-recover: drain timed out after %u ms; abandoning %d work items\n"` |
| Init succeeded at module load | `NV_DBG_INFO` (info) | `"tb_egpu f40b-recover: scaffolding initialised (MaxAttempts=%u; coexisting with A3 recovery)\n"` |

The mandatory-tier events are: F40b fire scheduling recovery; verification RECOVERED-or-DISCONNECT. Every recovery cycle reaches at least one mandatory log line.

A9 also writes to sysfs counters exposed by A8:
- `tb_egpu_f40b_fires` — increments on every F40b fire (gated or not)
- `tb_egpu_recovery_count` — increments on every verified RECOVERED outcome (shared with A3)
- `tb_egpu_recovery_failures` — increments on every DISCONNECT / permanent-fail outcome (shared with A3)
- `tb_egpu_last_recovery_ns` — set to ktime monotonic on every RECOVERED outcome
- `tb_egpu_state` — set to one of `healthy` / `recovering` / `lost-temporary` / `lost-permanent` at each transition

A new C5 detector class `NV_GPU_LOST_DETECTOR_F40B_OPEN_TIMEOUT` SHALL be added to the C5 mirror enum (value 8, next after the existing 0-7). This replaces A6's placeholder use of `NV_GPU_LOST_DETECTOR_AER_FATAL` for the F40b timeout path and enables proper telemetry routing.

## Provenance

- **Source cluster**: addon — project-local; complements A3 (existing post-rmInit-FAIL recovery), depends on A6 (F40b detection), depends on A8 (sysfs publication surface).
- **Vanilla baseline files**: `kernel-open/nvidia/nv.c` (new function `nv_f40b_schedule_recovery` added to A6's timeout path), `kernel-open/nvidia/nv-f40b-recovery.c` (new file, recovery state machine + work handler).
- **Fork branch**: `a9-f40b-in-driver-recovery`.
- **Upstream candidacy**: n/a — addon layer, project-local; recovery state machines for specific failure classes are not generally upstreamable as-is.
- **Upstream issues**:
  - F40 chip-side root cause: NVIDIA bug #979 (Blackwell eGPU over TB hard-lock) — see `project_issue_979_upstream_state_2026_05_22.md` memory.
  - F41 kernel-side prevention (E27 candidate): drivers/pci ReBAR sizing on hot-add — see `project_rebar_sysfs_bridge_window_bottleneck_2026_05_28.md` memory.
