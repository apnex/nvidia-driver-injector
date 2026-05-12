# Patches — purpose, bug fixed, surface

Reference for the seven `tb_egpu_*` clusters in `patches/`. Each row of
the TL;DR table links to the per-cluster detail below; each cluster
section names the specific bug, the empirical incident that drove it
into scope, and the surface (module params, sysfs, kthread) it
introduces.

For the refactor mechanics (commits, line counts, cross-cluster touches),
see `docs/patch-refactor-status.md`. For the forensic design analysis,
see `docs/patch-refactor-inventory.md` (810 lines).

---

## TL;DR

| File | Cluster | Purpose | Resolves |
|---|---|---|---|
| [`0001-tb-egpu-gpu-lost-crash-safety.patch`](#p1-gpu-lost-crash-safety-cascade) | **P1** | Stop the open driver committing the GPU to permanent-lost on a single transient PCIe read | NVIDIA/open-gpu-kernel-modules **bug #979** |
| [`0002-tb-egpu-aer-uncmask-clear.patch`](#p5-aer-uncmask-clear-at-probe) | **P5** | Clear the AER Uncorrectable Mask at probe so Internal Errors surface as Uncorrectable instead of demoting to Cor=0x2000 | Gen3 demotion blinding (2026-05-07 observation) |
| [`0003-tb-egpu-qwatchdog.patch`](#p3-q-watchdog-mode-b-detector) | **P3** | Active kthread probes `PMC_BOOT_0` at 5 Hz to detect DMA-path "Mode B" silent freezes that the existing `Q-active` ioctl wrapper misses | 2026-05-05 cold-boot Mode B silent wedge (loop-2026-05-05-165029) |
| [`0004-tb-egpu-pcie-error-handlers-recover.patch`](#p2-pcie-error-handlers--recovery-state-machine) | **P2** | Register the AER `pci_error_handlers`, add in-driver recovery state machine (H1 MaxAttempts / H2 rate-limit / H3 kill-switch) | WPR2-stuck on post-rmInit-FAIL; 21-fires-in-4-min recovery storm (2026-05-06) |
| [`0005-tb-egpu-close-path-safety.patch`](#p4-close-path-observability) | **P4** | Markers + passive state capture at 4 RM-side + 5 UVM-side close-path sites so we know the close-path-bug class stays mitigated | Close-path bug class (`docs/architecture.md` Problem 2 + Problem 4) — observational mitigation |
| [`0006-tb-egpu-diag-telemetry.patch`](#p6-diag-telemetry-surface) | **P6** | Rich PMC_BOOT_0 + WPR2 + LnkSta + AER capture at 6 open-side lifecycle sites; Kconfig-gated for production stripping | Open-side bug-class diagnosis surface (drives all the above) |
| [`0007-tb-egpu-version-mark-and-kbuild.patch`](#p7-build-metadata--kconfig-wiring) | **P7** | Bump `NVIDIA_VERSION` to `595.71.05-aorus.13`; Kbuild reads from version.mk; `CONFIG_NV_TB_EGPU_DIAG` toggle | Kbuild/version.mk drift; production-vs-diag binary toggle |

**Apply order = file-number order**. Write order is `P5 → P1 → P3 → P2 → P4 → P6 → P7` (smallest-first / self-contained-first; see status doc). The legacy patches consolidated by each cluster are listed below and remain in `patches/legacy/` as fallback during transition.

---

## P1 — GPU-lost crash-safety cascade

**File**: `patches/0001-tb-egpu-gpu-lost-crash-safety.patch`
**Cluster**: P1
**Legacy patches consolidated**: 0001, 0002, 0003, 0004, 0006, 0008, 0010, 0011, 0012, 0013

### What it does

Adds short-circuit prologues at every kernel and RM-side site that can be
entered with the GPU already disconnected, so the driver stops committing
to permanent GPU-lost state on a single transient PCIe failure. The eight
sites cover osDevReadReg* / osHandleGpuLost / rcdbAddRmGpuDump /
nvdDumpAllEngines / two `rs_server` deletion paths / Q-passive / Q-active.

### What it fixes

[NVIDIA/open-gpu-kernel-modules#979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979)
— the upstream open driver, on observing a single MMIO read returning
`0xFFFFFFFF` (the dead-bus signature returned after a PCIe completion
timeout), unconditionally calls `osHandleGpuLost`, marks
`PDB_PROP_GPU_IS_LOST`, and never re-attempts. On Thunderbolt-attached
GPUs where transient PCIe link drops are routine (TB packet loss, hub
retraining), this turns recoverable hiccups into permanent
GPU-offline-until-reboot states.

### Bug signature

```
nvidia 0000:04:00.0: Direct firmware load for nvidia/... failed
NVRM: GPU 0000:04:00.0: GPU has fallen off the bus.
NVRM: GPU 0000:04:00.0: PDB_PROP_GPU_IS_LOST set; refusing further ops
```
Subsequent `nvidia-smi` invocations report "No devices were found" until reboot.

### Surface

- New header: `src/nvidia/arch/nvalloc/unix/include/nv-tb-egpu.h`
- Macros: `TB_EGPU_LOG_ONCE`, `NV_ASSERT_OR_GPU_LOST`
- Constants: `TB_EGPU_GPU_LOST_RETRIES`, `TB_EGPU_GPU_LOST_DELAY_US`, `TB_EGPU_DEAD_BUS_U32/U16/U8`
- Inline helper: `tb_egpu_check_dead_bus(OBJGPU *)`

### Upstream candidacy

**HIGH** — bug #979 is upstream-acknowledged; the fix is well-scoped and
doesn't depend on any project-private symbols. Most upstream-ready of the
seven clusters.

### Related memory

- `project_aorus_egpu_setup.md` — bug fully characterised
- `feedback_native_in_driver_hardening.md` — upstream destination

---

## P5 — AER UncMask clear at probe

**File**: `patches/0002-tb-egpu-aer-uncmask-clear.patch`
**Cluster**: P5
**Legacy patches consolidated**: 0022

### What it does

At probe, clears the AER Uncorrectable Mask register on the GPU
(`PCI_ERR_UNCOR_MASK`). Default-on via `NVreg_TbEgpuAerUncMaskClear=1`.
Gated by `pci_find_ext_capability` so it's a no-op on devices without
AER ext-cap.

### What it fixes

A demotion path observed on this hardware where AER Uncorrectable errors
are masked at the GPU side and re-surface as a Correctable error with
status `0x2000` ("Advisory Non-Fatal"). The kernel AER subsystem then
treats them as recoverable correctables — i.e. it does nothing — and the
underlying transient never triggers the recovery state machine.

### Bug signature

```
Br_AER_Cor=0x1 + GPU_AER_UncMsk=0x400000 demoting Internal Error to Cor=0x2000
```
PCIe link issues that should drive recovery are invisible to err_handlers.

### Surface

- Module param: `NVreg_TbEgpuAerUncMaskClear` (default 1)
- Public API: `int tb_egpu_aer_clear_uncor_mask(struct pci_dev *)`
- New files: `kernel-open/nvidia/nv-tb-egpu-aer.{c,h}`

### Upstream candidacy

**MEDIUM-HIGH** — small, self-contained, and the Windows closed driver
does this same clear. Reasonable as a standalone upstream PR.

### Related memory

- `project_gen3_signal_integrity_2026_05_07.md` — empirical observation

---

## P3 — Q-watchdog Mode B detector

**File**: `patches/0003-tb-egpu-qwatchdog.patch`
**Cluster**: P3
**Legacy patches consolidated**: 0014 (kthread), 0015 (basic sysfs), 0023 S3 portion (persistent detection state)

### What it does

Per-device kthread that reads `NV_PMC_BOOT_0` (BAR0 offset 0) at a
configurable interval (default 200 ms = 5 Hz). On `0xFFFFFFFF` it
declares the GPU disconnected via `os_pci_set_disconnected`. Same kernel
propagation as the existing `Q-active` MMIO-read wrapper, but driven by
an active heartbeat rather than waiting for ioctl-path traffic. Records
detection state (jiffies, PMC_BOOT_0 value, AER snapshot) in sysfs for
post-mortem.

### What it fixes

The existing `Q-active` reliability lever wraps `osDevReadReg032` to
detect dead-bus reads from the ioctl path. But **DMA-path wedges** (Mode
B) happen during model upload via UVM, where no MMIO reads fire from
userspace context — so `Q-active` stayed silent through a real freeze
event on 2026-05-05. Q-watchdog catches Mode B because it probes
unconditionally regardless of which subsystem stalled.

### Bug signature

```
2026-05-05 165029: model load via UVM stalls; no Xid, no AER, no
osDevReadReg032 fires; system hard-freezes mid-DMA. dmesg silent.
```
This is the `project_close_path_mitigated_2026_05_08` precedent —
Q-watchdog wakes up such freezes within `IntervalMs * 1.5` of failure.

### Surface

- Module params: `NVreg_TbEgpuQwdEnable` (default 1), `NVreg_TbEgpuQwdIntervalMs` (default 200; clamped [10, 60000])
- Kthread: `[tb-egpu-qwd-<bus><slot>]`
- Sysfs (per-device): `tb_egpu_qwd_cycles`, `tb_egpu_qwd_detections`, `tb_egpu_qwd_last_detection_jiffies`, `tb_egpu_qwd_last_pmc_boot_0`, `tb_egpu_qwd_last_aer_summary`
- New files: `kernel-open/nvidia/nv-tb-egpu-qwd.{c,h}`

### Upstream candidacy

**LOW** — Thunderbolt-eGPU-specific. Not relevant on internal GPUs
where DMA-path wedges are vanishingly rare. Stays project-local.

### Related memory

- `feedback_lever_q_insufficient_for_dma.md` — why Q-active alone wasn't enough

---

## P2 — PCIe error handlers + recovery state machine

**File**: `patches/0004-tb-egpu-pcie-error-handlers-recover.patch`
**Cluster**: P2
**Legacy patches consolidated**: 0007 (err_handlers base), 0016 (recover scaffolding), 0017 (probe-time WPR2 detection), 0023 S1 portion (AER capture helper), 0024 (H1/H2/H3 hardening), 0026 (force_trigger sysfs), 0027 (slot_reset_resume dispatch), 0028 (attempt_count semantics), 0029 err_handlers parts (mmio_enabled + cor_error_detected)

### What it does

Registers the `nv_pci_err_handlers` struct (which upstream open never
populates), adds an in-driver recovery state machine that on a
post-`rm_init_adapter` failure schedules a PCI bus reset on the parent
bridge, dispatches `slot_reset` + `resume` from the work handler, and
re-attempts `rm_init_adapter`. Three production gates:

- **H1 MaxAttempts** — bounded retry count (default 3); after exhaustion → `PERMANENT_FAIL` uevent
- **H2 MinAttemptInterval** — rate-limit (default 30 s) prevents recovery storms
- **H3 Kill-switch file** — `/var/lib/tb-egpu/recover-killswitch` lets ops force-disable a buggy recovery state machine without a reboot

Plus the trigger-event AER capture helper (`tb_egpu_dump_aer_trigger_event`)
used by both the err_handler callbacks and the Q-watchdog detect path.

### What it fixes

Two related bugs:

**WPR2-stuck**: when `rm_init_adapter` fails mid-GSP-boot, the GSP MMU's
WPR2 register stays set. Subsequent open attempts see `WPR2 != 0` and
also fail. Without recovery, the GPU is offline until reboot.
P2 detects this at probe (legacy 0017) and triggers a bus reset.

**Recovery storm**: an earlier prototype without H1+H2 fired the recovery
work handler 21 times in 4 minutes during a hardware fault scenario,
each failed reset polluting state further. H1+H2 bound the blast radius.

### Bug signature

```
NVRM: GPU 0000:04:00.0: RmInitAdapter failed! (0x61:0x56:2101)
WPR2_ADDR_HI=0x07f4a000 (stuck; cold boot value)
... 21 recovery attempts in 4 minutes, all failed ...
```

### Surface

- Module params: `NVreg_TbEgpuRecoverEnable` (default 0; modprobe.d sets 1 in production), `NVreg_TbEgpuRecoverMaxAttempts` (3), `NVreg_TbEgpuRecoverMinAttemptIntervalMs` (30000), `NVreg_TbEgpuRecoverResetSettleMs`, `NVreg_TbEgpuRecoverSurrenderResetSec`, `NVreg_TbEgpuRecoverTestForceTrigger`
- Sysfs (per-device): `tb_egpu_recover_fires`, `tb_egpu_recover_successes`, `tb_egpu_recover_surrenders`, `tb_egpu_recover_last_fire_jiffies`, `tb_egpu_recover_force_trigger`
- Kill-switch path: `/var/lib/tb-egpu/recover-killswitch`
- Uevent envvar: `TB_EGPU_GPU_STATE=READY|RECOVERING|PERMANENT_FAIL`
- New files: `kernel-open/nvidia/nv-tb-egpu-recover.{c,h}`

### Upstream candidacy

**MEDIUM** — registering `pci_error_handlers` on the open driver is
strictly upstream-improving (the open driver currently NULL-pads the
struct), but the AORUS-specific recovery state machine is too
opinionated for upstream. Possible upstream split: ship just the
`nv_pci_err_handlers` registration + a thin default that returns
`PCI_ERS_RESULT_DISCONNECT` everywhere; keep the recovery state
machine project-local.

### Related memory

- `project_wpr2_mechanism_2026_05_06.md` — WPR2 stuck mechanism (post-rmInit-FAIL, not boot-persistence)
- `project_lever_m_recover_landed_2026_05_08.md` — first synthetic Phase 1-4 PASS
- `project_m_recover_first_real_fire_2026_05_08.md` — first real-world fire (natural post-rmInit-FAIL, not force_trigger)
- `project_iommu_dmar_finding_2026_05_06.md` — IOMMU contributing cause; H16 PCIe transient

---

## P4 — Close-path observability

**File**: `patches/0005-tb-egpu-close-path-safety.patch`
**Cluster**: P4
**Legacy patches consolidated**: 0029 (RM-side close-path DIAG, minus err_handlers parts already in P2), 0030 (UVM-side close-path DIAG)

### What it does

Markers + passive state capture at:

- **4 RM-side sites** in `nvidia_close_callback` / `nv_stop_device`: `close-entry`, `pre-stop`, `post-shutdown`, `close-exit`
- **5 UVM-side sites** in `uvm_open` / `uvm_release`: `uvm-open-entry`, `uvm-release-entry`, `uvm-pre-destroy`, `uvm-post-destroy`, `uvm-release-exit`

On a LAST-CLOSE transition (usage_count crosses to 0 or fd_count comes
back from 0), captures full state (`PMC_BOOT_0`, `WPR2`, `LnkSta`, AER on
GPU + bridge) and an AER snapshot. UVM-side uses an `EXPORT_SYMBOL_GPL`
helper to look up the GPU pdev cross-module (no hardcoded BDF).

### What it fixes

There's a known close-path bug class (`docs/architecture.md` Problem 2 +
Problem 4) where the open/close lifecycle leaves the GPU's firmware
state in a configuration that breaks the next open. The bug class is
currently **mitigated observationally** — `tools/close-path-probe.sh`
n=3 PROVEN on 2026-05-08 — not by a code fix. P4 is how we know the
mitigation stays in place under future stack changes: any regression
will show up as a state diff across the open→close→reopen lifecycle in
the captured snapshots.

### Bug signature

(No live bug today — these markers prove its continued absence.)
Symptom if it returns: the second `nvidia-smi` after a clean first one
fails to enumerate, or `cuda.init()` succeeds first run but fails on
re-init of the same process tree.

### Surface

- New files: `kernel-open/nvidia-uvm/nv-tb-egpu-uvm.{c,h}` (UVM-side helpers, separated from `uvm.c` for cohesion)
- Exported helpers (EXPORT_SYMBOL_GPL): `tb_egpu_get_gpu_pdev`, `tb_egpu_close_diag_pdev`, `tb_egpu_dump_aer_trigger_event` (promoted from P2's internal-only)
- Log prefixes: `tb_egpu [CLOSE]`, `tb_egpu UVM [CLOSE]`, `tb_egpu [UVM-DIAG]`

### Upstream candidacy

**LOW** — pure observational instrumentation, project-specific bug class.

### Related memory

- `project_close_path_mitigated_2026_05_08.md` — observational mitigation evidence
- `feedback_observability_perturbs_bug.md` — passive instrumentation only

---

## P6 — DIAG telemetry surface

**File**: `patches/0006-tb-egpu-diag-telemetry.patch`
**Cluster**: P6
**Legacy patches consolidated**: 0018 (diag dump core), 0020 (LnkSta/AER extension), 0021 (Header Log + ASPM + LBMS), 0023 S2 portion (DIAG-AER2)
**Legacy dropped**: 0009 (Lever P-probe — 18 investigation markers, none survived their original purpose)

### What it does

Rich passive state capture at 6 open-side lifecycle sites:

- `probe-end` (end of `nv_pci_probe`)
- `startdev-entry` (entry of `nv_start_device`)
- `pre-rmInit` (immediately before `rm_init_adapter`)
- `post-rmInit-FAIL` (after `rm_init_adapter` failure)
- `post-rmInit-OK` (after `rm_init_adapter` success)
- `mmio-enabled` (inside `nv_pci_mmio_enabled` err_handler)

Three log line classes per site:
- `[DIAG]` — primary: PMC_BOOT_0 + WPR2 + LnkSta + LnkCtl + AER status (always emitted)
- `[DIAG-AER]` — Header Log + UncMask + CapCtl (only when AER status non-zero)
- `[DIAG-AER2]` — root port AER + DPC + bridge masks (always; cheap)

Gated by `CONFIG_NV_TB_EGPU_DIAG` (default n in production; see P7);
when off, the header provides an inline no-op stub so call sites compile
to nothing.

### What it fixes

This is the diagnostic surface that **identified** the bugs P1/P2/P5
exist to fix. Empirically: 2026-05-06's WPR2-stuck root-cause analysis
was driven by these site dumps showing `WPR2_ADDR_HI=0x07f4a000` at
post-rmInit-FAIL but `0x00000000` at probe-end. Without the per-site
diff, the mechanism would have stayed hypothetical.

### Bug signature

(Doesn't fix a bug; produces the data needed to diagnose new ones.)

### Surface

- New files: `kernel-open/nvidia/nv-tb-egpu-diag.{c,h}`
- Function: `tb_egpu_diag_dump(nvl, site)`
- Re-uses 4 P2 helpers (`read_wpr2`, `walk_to_root_port`, `read_dpc_state`, `read_aer_full`) — P6 promotes them from file-static to module-internal linkage

### Upstream candidacy

**LOW** — pure project-private diagnostic. Probably stripped if any P1/P2/P5 piece goes upstream.

### Related memory

- `feedback_observability_perturbs_bug.md` — passive only, log at lifecycle boundaries
- `project_wpr2_mechanism_2026_05_06.md` — case study where DIAG diff was load-bearing

---

## P7 — Build metadata + Kconfig wiring

**File**: `patches/0007-tb-egpu-version-mark-and-kbuild.patch`
**Cluster**: P7
**Legacy patches consolidated**: 0005 (version-string mark), 0025 (Kbuild reads version.mk)

### What it does

Three things:

1. **NVIDIA_VERSION bump** to `595.71.05-aorus.13` (continues production sequence; aorus.12 was last legacy).
2. **Kbuild reads `NVIDIA_VERSION` from `version.mk`** via `include $(src)/../version.mk` — single source of truth. Prior to this, the Kbuild and version.mk would drift; modinfo's `version:` field could lag the actual feature set by several aorus.N bumps.
3. **Kconfig wiring**:
   - `CONFIG_NV_TB_EGPU ?= y` — master gate, documentation-only today (full opt-out across P1-P5 is a future tightening)
   - `CONFIG_NV_TB_EGPU_DIAG ?= n` — real toggle. When n, P6 `nv-tb-egpu-diag.c` is excluded from `NVIDIA_SOURCES` and the header's inline no-op stub keeps call sites at zero cost. ~10% binary size reduction on production builds.

### What it fixes

The drift bug — fixed by the version.mk-as-truth mechanism (a clean
upstream candidate independent of the eGPU stack).

### Surface

- `kernel-open/Kbuild` — version include + Kconfig toggles
- `kernel-open/nvidia/nvidia-sources.Kbuild` — conditional `nv-tb-egpu-diag.c`
- `kernel-open/nvidia/nv-tb-egpu-diag.h` — inline no-op stub when DIAG=n
- `version.mk` — bumped to aorus.13

Override at build time:
```bash
make CONFIG_NV_TB_EGPU_DIAG=y modules
```

### Upstream candidacy

**HIGH** for the version.mk-as-truth fix (purely a Kbuild cleanup;
independent of the eGPU work). **N/A** for the CONFIG_NV_TB_EGPU_DIAG
toggle (project-private).

---

## Cross-cutting facts

### Module parameters (all `NVreg_TbEgpu*`)

| Param | Default | Cluster | Notes |
|---|---|---|---|
| `NVreg_TbEgpuAerUncMaskClear` | 1 | P5 | clear AER UncMask at probe |
| `NVreg_TbEgpuQwdEnable` | 1 | P3 | qwd kthread armed |
| `NVreg_TbEgpuQwdIntervalMs` | 200 | P3 | clamp [10, 60000] |
| `NVreg_TbEgpuRecoverEnable` | **0** (modprobe.d sets to 1) | P2 | recovery state machine armed |
| `NVreg_TbEgpuRecoverMaxAttempts` | 3 | P2 | H1 gate |
| `NVreg_TbEgpuRecoverMinAttemptIntervalMs` | 30000 | P2 | H2 gate (30s) |
| `NVreg_TbEgpuRecoverResetSettleMs` | (see source) | P2 | post-reset settle time |
| `NVreg_TbEgpuRecoverSurrenderResetSec` | (see source) | P2 | surrender-reset window |
| `NVreg_TbEgpuRecoverTestForceTrigger` | 0 | P2 | test-only force trigger |

### Sysfs surface (per-device, under `/sys/bus/pci/devices/0000:04:00.0/`)

| Attribute | Mode | Cluster |
|---|---|---|
| `tb_egpu_recover_fires` | 0444 | P2 |
| `tb_egpu_recover_successes` | 0444 | P2 |
| `tb_egpu_recover_surrenders` | 0444 | P2 |
| `tb_egpu_recover_last_fire_jiffies` | 0444 | P2 |
| `tb_egpu_recover_force_trigger` | 0200 | P2 |
| `tb_egpu_qwd_cycles` | 0444 | P3 |
| `tb_egpu_qwd_detections` | 0444 | P3 |
| `tb_egpu_qwd_last_detection_jiffies` | 0444 | P3 |
| `tb_egpu_qwd_last_pmc_boot_0` | 0444 | P3 |
| `tb_egpu_qwd_last_aer_summary` | 0444 | P3 |

### Kthread

| Name | Cluster |
|---|---|
| `[tb-egpu-qwd-<bus><slot>]` (e.g. `[tb-egpu-qwd-0400]`) | P3 |

### Userspace contracts

- Kill-switch file: `/var/lib/tb-egpu/recover-killswitch` (P2 H3 gate)
- Uevent envvar: `TB_EGPU_GPU_STATE=READY|RECOVERING|PERMANENT_FAIL` (P2)
- Production posture: `/etc/modprobe.d/nvidia-driver-injector.conf` sets `NVreg_TbEgpuRecoverEnable=1` at module load

---

## Upstream-readiness summary

If any of these go upstream as standalone NVIDIA/open-gpu-kernel-modules
PRs, in priority order:

1. **P1** — bug #979 fix. Well-scoped, no project dependencies, addresses a real upstream bug.
2. **P7 (version.mk part only)** — Kbuild/version.mk-as-truth. Pure cleanup; no eGPU coupling.
3. **P5** — AER UncMask clear. Small, self-contained, matches Windows driver behaviour.
4. **P2 (err_handlers struct registration only)** — strictly upstream-improving (open driver currently NULL-pads); the recovery state machine itself stays project-local.

**Stays project-local indefinitely**: P3 (qwd kthread, TB-specific), P4 (close-path observability), P6 (DIAG), P2's recovery state machine.

Decision per `feedback_no_premature_upstream_filing.md`: do not file
until production-validated. Phase 3 soak is the gate.

---

## See also

- `docs/patch-refactor-status.md` — refactor mechanics (commits, line counts, cross-cluster touches), current phase
- `docs/patch-refactor-inventory.md` — Phase 1 forensics (810 lines)
- `docs/lever-catalog.md` — reliability levers, including those that became these patches
- Memory: `MEMORY.md` indexes the empirical observations and locked decisions
