# Patch refactor inventory — 29-patch surface → P1-P6 clusters

Forensics pass over `patches/*.patch` (~4,873 lines across 29 files), prepared
2026-05-12. This doc drives the upcoming refactor that re-slices the legacy
patch series into 6 clean clusters (P1-P6) with consistent naming
(`aorus_*` → `tb_egpu_*`) and modern code style.

Read-only inventory — no source files were modified during this pass.

---

## Section 1: Patch-to-cluster assignment

| # | Filename | Lines | Cluster | One-line role |
|---|---|---|---|---|
| 0001 | `osHandleGpuLost-retry-on-transient-pcie-failure` | 44 | **P1** | Lever I — retry NV_PMC_BOOT_0 10× / 100us before declaring GPU lost (upstream bug #979 core fix) |
| 0002 | `journal-rcdbAddRmGpuDump-shortcircuit-and-relax-assert` | 38 | **P1** | Lever J-2 — short-circuit `rcdbAddRmGpuDump` on `PDB_PROP_GPU_IS_LOST`; relax NV_ASSERT |
| 0003 | `nvDumpAllEngines-break-on-gpu-lost` | 26 | **P1** | Lever J-2 — break engine-dump loop on `GPU_IS_LOST`/`GPU_INACCESSIBLE` |
| 0004 | `resserv-cleanup-asserts-accept-gpu-lost` | 36 | **P1** | Lever J-2 — accept `NV_ERR_GPU_IS_LOST` in two `clientFreeResource`/`serverFree*` asserts |
| 0005 | `version-mark-aorus-build` | 23 | **N/A** | Build metadata — set `NVIDIA_VERSION = 595.71.05-aorus.5`; superseded by 0025 |
| 0006 | `rpcRmApiFree-GSP-shortcircuit-on-gpu-lost` | 37 | **P1** | Lever N — `rpcRmApiFree_GSP` returns NV_OK silently when GPU lost (collapses 107-site cleanup-path assert cascade) |
| 0007 | `nv-pci-register-error-handlers-Lever-M-base` | 76 | **P2** | Lever M-base — register `pci_error_handlers` with `error_detected` (returns DISCONNECT) |
| 0008 | `issueRpcAndWait-shortcircuit-on-gpu-lost-Lever-O` | 42 | **P1** | Lever O — short-circuit `_issueRpcAndWait` on GPU lost, returning `NV_ERR_GPU_IS_LOST` |
| 0009 | `uvm-destroy-diagnostic-markers-Lever-P-probe` | 172 | **N/A**[1] | Lever P-probe — 18 UVM teardown markers; pure diagnostic; superseded; should be DROPPED |
| 0010 | `os-pci-is-disconnected-helpers-Lever-Q` | 90 | **P1** | Lever Q — `os_pci_is_disconnected` / `os_pci_set_disconnected` helpers (kernel ↔ RM bridge) |
| 0011 | `osDevReadReg032-Lever-Q-passive` | 50 | **P1** | Lever Q-passive — short-circuit 32-bit MMIO read when disconnected |
| 0012 | `osDevReadReg008-016-Lever-Q-passive` | 46 | **P1** | Lever Q-passive — 8/16-bit MMIO short-circuit variants |
| 0013 | `osDevReadReg032-Lever-Q-active` | 75 | **P1** | Lever Q-active — verify PMC_BOOT_0 on 0xFFFFFFFF read; propagate disconnect both directions |
| 0014 | `Lever-Q-watchdog-kthread` | 352 | **P3** | Lever Q-watchdog — new `nv-qwatchdog.{c,h}`; per-pdev heartbeat kthread; Mode B detector |
| 0015 | `Lever-Q-watchdog-sysfs-counters` | 81 | **P3**+**P6** | Q-watchdog sysfs counters (`cycles`, `detections`) |
| 0016 | `Lever-M-recover-scaffolding` | 450 | **P2**+**P6** | M-recover Commit 1 — new `nv-lever-m-recover.{c,h}`; struct + module params + 4 sysfs counters + workqueue plumbing (no-op handler) |
| 0017 | `Lever-M-recover-probe-time-WPR2-detection` | 243 | **P2** | M-recover Commit 2 — probe-time WPR2 check at BAR0+0x88a828; detection only |
| 0018 | `Lever-M-recover-diagnostic-telemetry` | 250 | **P6** | M-recover diag — `tb_egpu_lever_m_diag_dump()` at 4 lifecycle sites; PMC_BOOT_0 + WPR2 snapshot |
| 0020 | `Phase-A-PCIe-LnkSta-AER-telemetry` | 114 | **P6** | Extend diag with PCIe LnkSta + AER UncErr/CorErr capture (passive config-space) |
| 0021 | `G3-G-AER-Header-Log-capture` | 171 | **P6** | Extend diag with AER Header Log + UncMask + ASPM/LBMS/LABS |
| 0022 | `G3-H-clear-AER-UncMask-match-Windows` | 126 | **P5** | Clear GPU AER UncMask=0 at probe (Windows default); module param `NVreg_TbEgpuUncMaskClearEnable` |
| 0023 | `mode-b-telemetry-S1-S2-S3` | 464 | **P6**+**P3** | Mode B telemetry — `aorus_walk_to_root_port`, `tb_egpu_dump_aer_trigger_event`, 3 new qwd sysfs files |
| 0024 | `Lever-M-recover-Commit3-hardening` | 838 | **P2** | M-recover Commit 3 + H1/H2/H3/H4 hardening — real `pci_reset_bus` action, kill-switch file, slot_reset/resume helpers, NEED_RESET path |
| 0025 | `Kbuild-version-from-version-mk` | 46 | **N/A** | Build metadata — Kbuild reads `NVIDIA_VERSION` from `version.mk` (single source of truth) |
| 0026 | `Lever-M-recover-sysfs-force-trigger` | 106 | **P2** | M-recover write-only sysfs `tb_egpu_lever_m_force_trigger` (Phase 3 testing) |
| 0027 | `Lever-M-recover-dispatch-slot-reset-resume-from-work-handler` | 77 | **P2** | M-recover — work handler dispatches slot_reset+resume helpers explicitly (manual-trigger path) |
| 0028 | `Lever-M-recover-attempt-count-reset-at-post-rmInit-OK` | 159 | **P2** | M-recover — `attempt_count` reset moved from slot_reset_resume to post-rmInit-OK (makes H1 gate reachable) |
| 0029 | `Lever-M-recover-close-path-diag-and-AER-surface-completion` | 309 | **P4**+**P2**+**P6** | Close-path DIAG sites in nv.c, mmio_enabled + cor_error_detected callbacks on err_handlers struct |
| 0030 | `Lever-M-recover-UVM-close-path-DIAG` | 332 | **P4**+**P6** | UVM close-path DIAG — exports `tb_egpu_lever_m_diag_dump_pdev`; new `aorus_uvm_*` instrumentation in uvm.c |

[1] **Patch 0009 (Lever P-probe)** is purely diagnostic markers (18 sites)
that were added to localize a specific UVM deadlock; the resulting fix is
covered by the J-2 + N + O cascade. Recommendation: **drop entirely** in
the refactor — none of these markers should land in production. If retained,
the `aorus_uvm_status_at_entry` local variable and 18 marker strings need
renaming under `CONFIG_NV_TB_EGPU_DIAG`. Default assumption: drop.

---

## Section 2: Per-cluster deep dive

### P1 — GPU-lost crash-safety cascade

**Source lines pulled from**: 0001, 0002, 0003, 0004, 0006, 0008, 0010, 0011, 0012, 0013

**Sum of legacy lines**: ~485 (diff context); estimated **final size: ~280 lines**
after dedup of the 6 nearly-identical "if (GPU_IS_LOST) return NV_OK/silent" prologues.

**Function symbols touched** (no renames needed — these are upstream RM symbols):

```
osHandleGpuLost                 — add 10-retry loop on NV_PMC_BOOT_0
rcdbAddRmGpuDump                — short-circuit on GPU_IS_LOST
_rcdbAddRmGpuDumpCallback       — relax NV_ASSERT
nvdDumpAllEngines_IMPL          — break loop on GPU_IS_LOST / GPU_INACCESSIBLE
clientFreeResource_IMPL         — accept NV_ERR_GPU_IS_LOST in assert
serverFreeResourceTreeUnderLock — same
rpcRmApiFree_GSP                — short-circuit on GPU_IS_LOST, return NV_OK
_issueRpcAndWait                — short-circuit on GPU_IS_LOST, return NV_ERR_GPU_IS_LOST
osDevReadReg008/016/032         — short-circuit when disconnected (Q-passive)
osDevReadReg032 (post-read)     — verify PMC_BOOT_0, declare lost (Q-active)
```

New helpers (kernel-open side, `os-pci.c`):

```
os_pci_is_disconnected   →  os_pci_is_disconnected   (no rename — already correctly named)
os_pci_set_disconnected  →  os_pci_set_disconnected  (no rename)
```

**Sysfs attributes**: none

**Files touched**:

```
src/nvidia/arch/nvalloc/unix/src/osinit.c                  (0001)
src/nvidia/src/kernel/diagnostics/journal.c                (0002)
src/nvidia/src/kernel/diagnostics/nv_debug_dump.c          (0003)
src/nvidia/src/libraries/resserv/src/rs_client.c           (0004)
src/nvidia/src/libraries/resserv/src/rs_server.c           (0004)
src/nvidia/src/kernel/vgpu/rpc.c                           (0006, 0008)
kernel-open/common/inc/os-interface.h                      (0010)
kernel-open/nvidia/os-pci.c                                (0010)
src/nvidia/arch/nvalloc/unix/include/os-interface.h        (0010)
src/nvidia/arch/nvalloc/unix/src/os.c                      (0011-0013)
```

**Code smells / improvement opportunities**:

- Six near-identical `static int s_tb_egpu_lever_<X>_logged = 0;` log-once latches across 0001/0006/0008/0011/0013/0007. Consolidate into one macro `TB_EGPU_LOG_ONCE(fmt, ...)`.
- Magic constants: retry count `10`, delay `100us` in 0001 — promote to `TB_EGPU_GPU_LOST_RETRIES` / `TB_EGPU_GPU_LOST_DELAY_US`.
- Magic constant `0xFFFFFFFF` / `0xFF` / `0xFFFF` repeated as MMIO dead-bus return value — `TB_EGPU_DEAD_BUS_U32` / `_U16` / `_U8`.
- Comment strings ("AORUS Lever I", "AORUS Lever J-2", "AORUS Lever N", "AORUS Lever O") referencing the lever taxonomy from project memory. Decision: keep as inline `/* per Lever I, see docs/lever-catalog.md */` references but drop the "AORUS" prefix.
- Log strings reference patch numbers ("AORUS Lever J-2 patch (2026-05-03)") — drop date stamps, drop patch numbers; reference docs/lever-catalog.md.
- `NV_ASSERT(...) || (status == NV_ERR_GPU_IS_LOST)` triplet in 0004 — should be a helper macro `NV_ASSERT_OR_GPU_LOST(status)`.
- 8-bit and 16-bit MMIO short-circuit branches (0012) duplicate the 32-bit logic from 0011 with different return constants. Consolidate via a `_tb_egpu_check_dead_bus(pGpu)` inline predicate.
- The Q-active comment claims PMC_BOOT_0 read "bypasses our chokepoint to avoid recursion" — verify this is still true after refactor consolidates the chokepoint.
- `pmc_boot_0_now != nvp->pmc_boot_0` comparison in 0013 — semantically wrong if `nvp->pmc_boot_0` was 0 at boot due to a different transient; consider `pmc_boot_0_now == 0xFFFFFFFFU` as the dead-bus test.

**Test plan**:

1. Build: `make modules` succeeds; no warnings on `-Wall`.
2. Cold boot: `dmesg | grep -i "tb_egpu\|gpu lost\|gpu is lost"` shows zero output (no false-positive logs on healthy boot).
3. Inject transient: write `1` to `tb_egpu_lever_m_force_trigger`, observe the cascade — expect `osHandleGpuLost` retry, then `GPU_IS_LOST` set, then no further RPC traffic from `_issueRpcAndWait` to GSP. `journalctl -b -k | grep "Lever I"` shows one retry-cleared line OR a permanent-loss line.
4. Negative: confirm `nv_pci_remove_helper` runs cleanly without `NV_ASSERT` panics — `dmesg | grep "NV_ASSERT.*rs_client.c:8[34]"` empty.
5. Verify Q-passive: after force-trigger fires, `cat /sys/bus/pci/devices/0000:04:00.0/tb_egpu_qwatchdog_detections` is ≥1 AND subsequent `nvidia-smi` calls return immediately (no 50ms-per-read hang). Failure mode: 50ms × N register-read host wedge on subsequent userspace open.

---

### P2 — PCIe error handlers + Lever M-recover state machine

**Source lines pulled from**: 0007, 0016, 0017, 0024, 0026, 0027, 0028, 0029 (err_handlers parts)

**Sum of legacy lines**: ~2,050; estimated **final size: ~1,200 lines** after consolidating gates, removing inter-commit "Patch 0024 sets X / Patch 0028 corrects it" comments, and dropping resolved-iteration scaffolding.

**Function symbols touched** (with rename map):

```
nv_pci_error_detected                       →  nv_pci_error_detected           (keep; upstream-shape name)
nv_pci_slot_reset                           →  nv_pci_slot_reset               (keep)
nv_pci_resume                               →  nv_pci_resume                   (keep)
nv_pci_mmio_enabled                         →  nv_pci_mmio_enabled             (keep)
nv_pci_cor_error_detected                   →  nv_pci_cor_error_detected       (keep)
nv_pci_err_handlers (struct)                →  nv_pci_err_handlers             (keep)

tb_egpu_lever_m_recover_init                →  tb_egpu_recover_init
tb_egpu_lever_m_recover_stop                →  tb_egpu_recover_stop
tb_egpu_lever_m_check_wpr2_at_probe         →  tb_egpu_recover_check_wpr2_at_probe
tb_egpu_lever_m_trigger_post_rminit_fail    →  tb_egpu_recover_trigger_post_rminit_fail
tb_egpu_lever_m_emit_uevent                 →  tb_egpu_recover_emit_uevent
tb_egpu_lever_m_slot_reset                  →  tb_egpu_recover_slot_reset
tb_egpu_lever_m_slot_reset_resume           →  tb_egpu_recover_slot_reset_resume
tb_egpu_lever_m_record_post_rminit_ok       →  tb_egpu_recover_record_post_rminit_ok
tb_egpu_lever_m_reset_work_handler          →  tb_egpu_recover_reset_work_handler
tb_egpu_lever_m_force_trigger_store         →  tb_egpu_recover_force_trigger_store
tb_egpu_lever_m_apply_killswitch_file       →  tb_egpu_recover_apply_killswitch_file
tb_egpu_lever_m_read_killswitch_file        →  tb_egpu_recover_read_killswitch_file

struct tb_egpu_lever_m_recover              →  struct tb_egpu_recover_state
  .pdev_for_work, .in_progress, .fire_count,
  .success_count, .surrender_count,
  .last_fire_jiffies, .attempt_count, .reset_work — fields keep their names
```

**Module-param renames**:

```
NVreg_TbEgpuLeverMRecoverEnable             →  NVreg_TbEgpuRecoverEnable
NVreg_TbEgpuLeverMMaxAttempts               →  NVreg_TbEgpuRecoverMaxAttempts
NVreg_TbEgpuLeverMResetSettleMs             →  NVreg_TbEgpuRecoverResetSettleMs
NVreg_TbEgpuLeverMMinAttemptIntervalMs      →  NVreg_TbEgpuRecoverMinAttemptIntervalMs
NVreg_TbEgpuLeverMSurrenderResetSec         →  NVreg_TbEgpuRecoverSurrenderResetSec
NVreg_TbEgpuLeverMTestForceTrigger          →  NVreg_TbEgpuRecoverTestForceTrigger
```

**Sysfs attributes** (renames):

```
tb_egpu_lever_m_fires                       →  tb_egpu_recover_fires
tb_egpu_lever_m_successes                   →  tb_egpu_recover_successes
tb_egpu_lever_m_surrenders                  →  tb_egpu_recover_surrenders
tb_egpu_lever_m_last_fire_jiffies           →  tb_egpu_recover_last_fire_jiffies
tb_egpu_lever_m_force_trigger               →  tb_egpu_recover_force_trigger
```

**Kill-switch file path**:

```
/var/lib/aorus-egpu/lever-m-killswitch      →  /var/lib/tb-egpu/recover-killswitch
```

(Note: this is a userspace-facing file. Migration path: read either location during a transition window, document the rename in the install-workflow doc, update `usr/local/sbin/aorus-egpu-lever-m*` userspace scripts referenced in patch 0024.)

**Uevent envvar**:

```
TB_EGPU_GPU_STATE=READY|RECOVERING|PERMANENT_FAIL  — keep as-is (already correctly named)
```

**Files touched** (with project-private filename renames):

```
kernel-open/nvidia/nv-pci.c                            (0007, 0016, 0017, 0024, 0029)
kernel-open/common/inc/nv-linux.h                      (0016 — adds .lever_m pointer; rename field to .recover)
kernel-open/nvidia/nv-lever-m-recover.c                →  kernel-open/nvidia/nv-tb-egpu-recover.c
kernel-open/nvidia/nv-lever-m-recover.h                →  kernel-open/nvidia/nv-tb-egpu-recover.h
kernel-open/nvidia/nvidia-sources.Kbuild               (0016)
kernel-open/nvidia/nv.c                                (0024 — post-rmInit hook; 0028 — post-rmInit-OK hook)
```

**Kthread name**: none in P2 (the M-recover work runs on `system_wq` via `schedule_work`).

**Code smells / improvement opportunities**:

- Module parameters declared `unsigned int` at file scope without `static` (deliberate — `extern` in header) but the `extern`s in 0024 should be reviewed — they ought to live in the header from day one, not be added when a second TU starts referencing them.
- The H1/H2/Enable gate logic is duplicated between `tb_egpu_lever_m_trigger_post_rminit_fail()` and `nv_pci_error_detected()` (0024). Extract `tb_egpu_recover_pre_schedule_gates(struct tb_egpu_recover_state *, ...)` returning an enum (`GATE_OK / GATE_DISABLED / GATE_RATE_LIMITED / GATE_SURRENDER`) and a reason-string.
- Inter-commit history comments ("Patch 0024 v1 does NOT re-enter rm_init_adapter… ", "Patch 0028 (2026-05-08): attempt_count is NO LONGER reset here…") are forensic-archaeology only — strip in refactor. Keep the design intent, drop the chronology.
- Magic constants: `TB_EGPU_LEVER_M_WPR2_REG_OFFSET 0x88a828`, `TB_EGPU_LEVER_M_WPR2_VAL_MASK 0xfffffff0` — already symbolic, fine; rename prefix to `TB_EGPU_RECOVER_WPR2_*`.
- `kernel_read_file_from_path` with hardcoded `/var/lib/aorus-egpu/lever-m-killswitch` literal — promote to `#define TB_EGPU_RECOVER_KILLSWITCH_PATH "/var/lib/tb-egpu/recover-killswitch"`.
- `static int s_tb_egpu_lever_m_logged = 0;` log-once latch (0007) — same pattern as P1; share via `TB_EGPU_LOG_ONCE`.
- `lm->pdev_for_work` is owned by the work handler but written by the trigger function; the "Defensive: stale pdev_for_work from a previous trigger" branch is a workaround for missing in_progress ordering. Review: the in_progress atomic_xchg should make this race impossible — if it can happen, in_progress is broken. Audit.
- The `result_str` / `reason` string-construction pattern in `nv_pci_error_detected` (0024) is awkward — restructure as a small switch on the gate enum.
- WPR2 register access pattern (`ioremap → ioread32 → iounmap`) duplicated 3× (probe-time check, trigger function, slot_reset verify). Extract `tb_egpu_recover_read_wpr2(u64 bar0_phys, u32 *raw_out)` helper.
- The 4 `device_create_file` calls (and matching 4 `device_remove_file` calls) should be `sysfs_create_group` with a `const struct attribute_group` — both for `tb_egpu_recover_*` and for the Q-watchdog block.
- `EXPORT_SYMBOL(tb_egpu_dump_aer_trigger_event)` — should be `EXPORT_SYMBOL_GPL` if these stay; or, better, internal-only via a project-private header.
- Patch 0024 comment "Default OFF" but 0024 actually ships `= 0`; ensure refactor explicitly documents the default and the planned flip-to-1 milestone.

**Test plan**:

1. Build: `modinfo nvidia.ko | grep -E "NVreg_TbEgpuRecover"` lists all 6 params.
2. Phase 1 (build verification): all 5 sysfs files appear under `/sys/bus/pci/devices/0000:04:00.0/tb_egpu_recover_*` after probe; `tb_egpu_recover_force_trigger` is mode 0200 (write-only).
3. Phase 2 (baseline with Enable=0): cold-boot, `dmesg | grep "tb_egpu.*recover"` shows kill-switch read + "scaffolding initialised" only; no recovery activity.
4. Phase 3 (force-trigger): `NVreg_TbEgpuRecoverEnable=1 NVreg_TbEgpuRecoverTestForceTrigger=1`, then `echo 1 > .../tb_egpu_recover_force_trigger`. Expect dmesg trail: `force_trigger fired → scheduling recovery → bus-reset starting → pci_reset_bus OK → dispatching slot_reset + resume → PMC_BOOT_0=0xNNN; RECOVERED → success_count=1, emitting READY`. Verify `udevadm monitor` captured `TB_EGPU_GPU_STATE=RECOVERING` then `READY`.
5. Phase 4a (H1 MaxAttempts): with rm_init_adapter wedged (test harness), trigger 4× in succession ≥30 s apart. Expect attempts 1/2/3 → schedule, attempt 4 → "surrender (H1 MaxAttempts exhausted) → PERMANENT_FAIL". Failure mode caught: infinite recovery storm (the 21-fires-in-4-min 2026-05-06 incident).
6. Phase 4b (H2 rate-limit): trigger twice within 5 s. Expect first → schedule, second → "rate-limited (H2)" DISCONNECT. Failure mode caught: AER burst storm.
7. Phase 4c (H3 kill-switch file): `echo 0 > /var/lib/tb-egpu/recover-killswitch`, reload module with cmdline `Enable=1`. Expect dmesg "kill-switch file engaged… overriding NVreg_TbEgpuRecoverEnable to 0". Failure mode caught: panic-mode disable when recovery itself is buggy.
8. Cold-cold-boot real-world: n≥10 WPR2-stuck reproductions through this in-driver path with attempts ≤MaxAttempts. Milestone for retiring `aorus-egpu-wpr2-recovery.service`.

---

### P3 — Lever Q-watchdog Mode B detector

**Source lines pulled from**: 0014 (kthread core), 0015 (sysfs counters), 0023 (S3 persistent detection state)

**Sum of legacy lines**: ~775; estimated **final size: ~520 lines** after consolidating sysfs registration and de-duping the S1/S3 storage paths.

**Function symbols touched** (with rename map):

```
tb_egpu_qwatchdog_thread            →  tb_egpu_qwd_thread
tb_egpu_qwatchdog_init              →  tb_egpu_qwd_init
tb_egpu_qwatchdog_stop              →  tb_egpu_qwd_stop

tb_egpu_qwatchdog_cycles_show                       →  tb_egpu_qwd_cycles_show
tb_egpu_qwatchdog_detections_show                   →  tb_egpu_qwd_detections_show
tb_egpu_qwatchdog_last_detection_jiffies_show       →  tb_egpu_qwd_last_detection_jiffies_show
tb_egpu_qwatchdog_last_pmc_boot_0_show              →  tb_egpu_qwd_last_pmc_boot_0_show
tb_egpu_qwatchdog_last_aer_summary_show             →  tb_egpu_qwd_last_aer_summary_show

struct tb_egpu_qwatchdog                            →  struct tb_egpu_qwd
struct tb_egpu_qwatchdog_aer_snapshot               →  struct tb_egpu_qwd_aer_snapshot
```

**Kthread name** (mandatory rename, user-visible in `ps`):

```
aorus-qwd-%02x%02x                  →  tb-egpu-qwd-%02x%02x
```

Note: project README.md line 238 documents the old name `aorus-qwd-0400`; that doc needs updating too.

**Module parameters**:

```
NVreg_TbEgpuWatchdogEnable          →  NVreg_TbEgpuQwdEnable
NVreg_TbEgpuWatchdogIntervalMs      →  NVreg_TbEgpuQwdIntervalMs
```

**Sysfs attributes**:

```
tb_egpu_qwatchdog_cycles                            →  tb_egpu_qwd_cycles
tb_egpu_qwatchdog_detections                        →  tb_egpu_qwd_detections
tb_egpu_qwatchdog_last_detection_jiffies            →  tb_egpu_qwd_last_detection_jiffies
tb_egpu_qwatchdog_last_pmc_boot_0                   →  tb_egpu_qwd_last_pmc_boot_0
tb_egpu_qwatchdog_last_aer_summary                  →  tb_egpu_qwd_last_aer_summary
```

(Note: project README.md line 236 contains `grep tb_egpu_qwatchdog` — must update to `grep tb_egpu_qwd`. Two visible-to-user-tooling renames.)

**Files touched**:

```
kernel-open/nvidia/nv-qwatchdog.c   →  kernel-open/nvidia/nv-tb-egpu-qwd.c
kernel-open/nvidia/nv-qwatchdog.h   →  kernel-open/nvidia/nv-tb-egpu-qwd.h
kernel-open/nvidia/nv-pci.c                       (init/stop call sites)
kernel-open/common/inc/nv-linux.h                 (qwd member rename: nvl->qwd stays — it's a struct-internal name)
kernel-open/nvidia/nvidia-sources.Kbuild
```

**Macro renames**:

```
TB_EGPU_QWATCHDOG_MIN_INTERVAL_MS       →  TB_EGPU_QWD_MIN_INTERVAL_MS
TB_EGPU_QWATCHDOG_MAX_INTERVAL_MS       →  TB_EGPU_QWD_MAX_INTERVAL_MS
TB_EGPU_QWATCHDOG_PMC_BOOT_0_OFFSET     →  TB_EGPU_QWD_PMC_BOOT_0_OFFSET
TB_EGPU_QWATCHDOG_DEAD_BUS_VALUE        →  TB_EGPU_QWD_DEAD_BUS_VALUE
```

**Code smells / improvement opportunities**:

- `TB_EGPU_QWD_DEAD_BUS_VALUE 0xFFFFFFFFu` duplicates the same constant from P1's MMIO short-circuit path. Promote to a shared `tb-egpu-common.h`.
- `regs32 = (volatile NvU32 *)nv->regs->map; boot_0 = regs32[OFFSET];` — bypasses `ioread32` deliberately ("we want to be cleanly attributable in dmesg vs Q-active"). Acceptable, but should be `READ_ONCE` not raw volatile dereference. Document this is intentional vs the chokepoint.
- `detected_logged` is a per-thread local; `qwd->cycles` etc. are per-pdev. The first-fire-per-episode logic is fine, but the global module-param `NVreg_TbEgpuQwdEnable` is checked inside the loop on every cycle — fine, just note for the doc that runtime toggle works.
- Module params are global but the watchdog state is per-pdev. If a future system has 2 NVIDIA GPUs, the module param applies to both. Acceptable scope: this is a single-GPU eGPU project.
- `kthread_stop` is bounded by `interval_ms` which is clamped max 60 s. 60-s blocking unbind is a long time. Worth documenting; not worth fixing in v1.
- Per-pdev struct allocation in `tb_egpu_qwd_init` uses `kzalloc`; failure is non-fatal — but the failure path leaves `nvl->qwd = NULL`, and the kthread-side `nvl->qwd` deref is unprotected (only checked at thread entry). Audit: is there a probe-time vs first-iteration race?
- 5 separate `device_create_file` / `device_remove_file` pairs — switch to `sysfs_create_group` with a `static const struct attribute_group tb_egpu_qwd_attr_group`. Same advice as P2.
- `nvl->qwd` member field: keep `qwd` short name in the struct; it's project-internal.
- The S3 snapshot struct uses `u8 valid` flag instead of `bool` — minor cosmetic.
- `tb_egpu_dump_aer_trigger_event(... &qwd->last_aer)` — this struct write is not atomic; if userspace reads `last_aer_summary` mid-update, it can see torn state. Acceptable for diag, but document. Or: use a `seqlock_t` per struct.

**Test plan**:

1. Build: `lsmod | grep nvidia` + `ps aux | grep tb-egpu-qwd` shows kthread name. `dmesg | grep "kthread started"` shows one per GPU.
2. Healthy probe rate: `cat /sys/bus/pci/devices/0000:04:00.0/tb_egpu_qwd_cycles` increments at ~5/s (interval=200 ms default). After 60 s, value should be ~300 ± 10%.
3. Detection latency (synthetic): inject Mode B (DMA-path) failure via test harness (e.g. write garbage to BAR1 via uvm); within `IntervalMs` × 1.5 expect `tb_egpu_qwd_detections` to increment AND `dmesg | grep "qwatchdog: kthread DETECTED dead bus"` fires AND `cat tb_egpu_qwd_last_pmc_boot_0` returns `0xFFFFFFFF` AND `tb_egpu_qwd_last_aer_summary` is populated.
4. Runtime kill-switch: `echo 0 > /sys/module/nvidia/parameters/NVreg_TbEgpuQwdEnable`; `cycles` counter stops incrementing within `IntervalMs`. `echo 1 > ...`; counter resumes. Failure mode caught: cannot disable a misbehaving watchdog without unbind.
5. Re-entry safety: rapid `rmmod / insmod` cycles (n=10) without panic. Failure mode: dangling kthread reading freed `nvl`. `kthread_stop` must return before `kfree(qwd)`.

---

### P4 — Close-path safety

**Source lines pulled from**: 0029 (RM-side close DIAG sites + helper), 0030 (UVM-side instrumentation), parts of 0024 (slot_reset_resume completion semantics)

**Sum of legacy lines**: ~640; estimated **final size: ~280 lines** after dropping DIAG-only branches (those move to P6 under `CONFIG_NV_TB_EGPU_DIAG`).

**Note**: Patches 0029 and 0030 are entirely diagnostic ([CLOSE] / [UVM-DIAG]
markers). They IDENTIFY the close-path bug surface but do not contain a fix.
Per memory `project_close_path_mitigated_2026_05_08.md` the mitigation
is "close-path-probe.sh n=3 PROVEN" — i.e. the mitigation is currently
observational (the bug is mitigated because the conditions no longer
materialize on the current stack), not a code change.

P4's residual code surface after refactor is therefore SMALL:

1. The slot_reset_resume / post-rmInit-OK ordering fix (from 0028) — this
   is the actual close-path-relevant non-diagnostic change. Already
   listed under P2 above. Cross-reference here only.
2. A small set of `nvidia_close_callback` guards that defensively check
   `usage_count` transitions — currently implicit in the existing driver,
   should be made explicit per the close-path semantics nvtTested.

**Function symbols touched** (renames):

```
tb_egpu_lever_m_close_path_diag                →  tb_egpu_close_diag
tb_egpu_lever_m_diag_dump_pdev                 →  tb_egpu_close_diag_pdev
aorus_uvm_close_path_diag                      →  tb_egpu_uvm_close_diag
aorus_uvm_get_gpu_pdev                         →  tb_egpu_uvm_get_gpu_pdev
aorus_uvm_fd_count                             →  tb_egpu_uvm_fd_count
aorus_uvm_status_at_entry (in patch 0009)      →  (drop — see Section 1 note)
```

**Sysfs attributes**: none

**Files touched**:

```
kernel-open/nvidia/nv.c                                  (0029 — close-entry/pre-stop/post-shutdown/close-exit sites)
kernel-open/nvidia-uvm/uvm.c                             (0030 — 5 UVM sites)
kernel-open/nvidia-uvm/uvm_va_space.c                    (0009 — DROP)
kernel-open/nvidia/nv-tb-egpu-recover.c                  (close-diag helper)
kernel-open/nvidia/nv-tb-egpu-recover.h                  (close-diag prototype)
```

**Hardcoded BDF** (must remove):

Patch 0030's `aorus_uvm_get_gpu_pdev()` hardcodes `pci_get_domain_bus_and_slot(0, 0x04, PCI_DEVFN(0, 0))`. This is correct for the current eGPU setup but breaks if the topology changes or someone has a second GPU. The fix: walk `nv_linux_devices` (already exported per `nv-linux.h`) to find any NVIDIA pdev, or register an explicit pdev-from-UVM lookup helper.

**Code smells / improvement opportunities**:

- `extern void tb_egpu_lever_m_diag_dump_pdev(...)` declared in `uvm.c` rather than from the project header — every cross-module symbol should be visible via `nv-tb-egpu-recover.h` (with appropriate guard to avoid pulling RM internals).
- `extern void tb_egpu_dump_aer_trigger_event(struct pci_dev *, const char *, void *out)` — the `out` parameter is typed `void *` in uvm.c but `struct tb_egpu_qwd_aer_snapshot *` in the actual definition. Type-erased to avoid cross-module include; ugly. Fix: publish the snapshot struct in a shared header.
- Hardcoded BDF (see above).
- 4+ near-identical `int prev = atomic_inc_return(...) - 1;` / `int post = atomic_dec_return(...)` patterns in uvm.c — extract to helper.
- `pr_info` in uvm.c vs `NV_DEV_PRINTF(NV_DBG_ERRORS, nv, ...)` in nv.c — inconsistent log routing; the UVM side should use `UVM_ERR_PRINT_ALWAYS` or an equivalent gated channel for consistency under DIAG.
- `EXPORT_SYMBOL(tb_egpu_lever_m_diag_dump_pdev)` is GPL-compatibility-questionable — nvidia.ko itself is dual-licensed but UVM is separate. Audit symbol-export licence.

**Test plan**:

1. Healthy open/close cycle: `nvidia-smi -L` (which opens /dev/nvidia0 and closes). `dmesg | grep CLOSE` shows the 4 RM-side markers; `dmesg | grep "UVM \[CLOSE\]"` shows the 5 UVM-side markers when CUDA opens UVM fd.
2. Last-close diff: capture `[DIAG]` (open side) + `[CLOSE]` (close side) PMC_BOOT_0 and WPR2 values. Diff should be {WPR2 stays 0, PMC_BOOT_0 stays at boot ID}. Any drift indicates close-path mutating firmware state — the bug we're guarding.
3. Stress: 1000 open/close cycles via `tools/close-path-probe.sh n=3` clone with more iterations; expect 0 hangs, 0 panics. Failure mode: close-path-bug class resurfaces under refactor.
4. UVM concrete: `python -c "import torch; torch.cuda.init()"` then exit. Verify `tb_egpu_uvm_fd_count` returns to 0 (visible via dmesg [UVM CLOSE] last marker).

---

### P5 — AER UncMask = Windows defaults

**Source lines pulled from**: 0022

**Sum of legacy lines**: 126; estimated **final size: ~60 lines** (this is already small and reasonably clean).

**Function symbols touched**:

```
(no named function — inline at tb_egpu_recover_init() start)
```

Refactor: extract to `tb_egpu_aer_apply_windows_defaults(struct pci_dev *)` for clarity.

**Module parameter**:

```
NVreg_TbEgpuUncMaskClearEnable      →  NVreg_TbEgpuAerWindowsDefaults
```

(or keep the old name; `UncMaskClearEnable` is more descriptive of what it does.)

**Sysfs attributes**: none

**Files touched**:

```
kernel-open/nvidia/nv-tb-egpu-aer.c                     (NEW — extracted from nv-tb-egpu-recover.c)
kernel-open/nvidia/nv-tb-egpu-aer.h                     (NEW — prototype)
kernel-open/nvidia/nv-pci.c                             (call site moves here from tb_egpu_recover_init)
kernel-open/nvidia/nvidia-sources.Kbuild                (+1 line)
```

OR: keep the body inside `tb_egpu_recover_init` if a separate TU feels overkill; this is a 30-line function. Recommendation: separate TU, because it's logically distinct (works regardless of `NVreg_TbEgpuRecoverEnable`) and future tunables (Severity register, CorMask, etc.) could grow into the same file.

**Code smells / improvement opportunities**:

- Patch 0022 inlines AER mask manipulation at the start of `tb_egpu_lever_m_recover_init()` with the explicit comment "Runs regardless of NVreg_TbEgpuLeverMRecoverEnable since unmasking is independent of the recovery state machine." That coupling is wrong — the AER-mask clearing should live in its own init function, called from `nv_pci_probe` independently of M-recover init.
- `pci_read_config_dword(...)` + `pci_write_config_dword(...)` pair without intermediate validation. If the AER ext-cap is at a weird offset (broken hardware), the write could corrupt unrelated config-space. Bound-check `aer_pos` against PCIe config space (e.g. `aer_pos < 0x1000`).
- Hardcoded sites/comments referencing the Gen3 cor=0x2000 / UncMsk=0x400000 specifics — strip the specific bit numbers from comments after refactor; reference docs/lever-catalog.md.

**Test plan**:

1. Boot with `NVreg_TbEgpuAerWindowsDefaults=1` (default): `dmesg | grep "UncMaskClear"` shows old/new mask values. After boot, `setpci -s 0000:04:00.0 ECAP01.0c.l` should read 0x00000000 (verifying the mask is zero).
2. Boot with `=0`: AER mask stays at hardware default `0x00400000`; no log.
3. Regression sanity: after `=1`, observe `tb_egpu_recover_*` counters for 24 h; no spurious AER fires.

---

### P6 — Diagnostic telemetry surface (CONFIG_NV_TB_EGPU_DIAG)

**Source lines pulled from**: 0009 (drop), 0015 (sysfs counters — split), 0016 (sysfs counters — split), 0018 (diag dump core), 0020 (LnkSta/AER extension), 0021 (Header Log + ASPM extension), 0023 (Mode B telemetry, walk_to_root_port helper), parts of 0026 (force_trigger is P2 not P6 — but the help text is diag-grade), 0029 (close-path DIAG sites), 0030 (UVM DIAG dump_pdev variant)

**Sum of legacy lines**: ~1,700; estimated **final size under DIAG gate: ~900 lines**. All `#ifdef CONFIG_NV_TB_EGPU_DIAG` wrapped.

**Function symbols touched** (renames):

```
tb_egpu_lever_m_diag_dump                  →  tb_egpu_diag_dump
tb_egpu_lever_m_diag_dump_pdev             →  tb_egpu_diag_dump_pdev
tb_egpu_dump_aer_trigger_event             →  tb_egpu_diag_dump_aer_trigger
aorus_walk_to_root_port                    →  tb_egpu_walk_to_root_port
aorus_read_aer_full                        →  tb_egpu_read_aer_full
aorus_read_dpc_state                       →  tb_egpu_read_dpc_state
```

(The two `aorus_uvm_*` helpers in patch 0030 fold here under the DIAG gate; see P4 note that the UVM instrumentation is purely diag.)

**Sysfs attributes** (all DIAG-gated): the 4 M-recover counters and 5 Q-watchdog counters listed above (P2/P3) — when `CONFIG_NV_TB_EGPU_DIAG=n`, these still exist (they're tier-1 observability, not diag) but the `last_aer_summary` and `last_pmc_boot_0` should be DIAG-only. Recommendation:

| Sysfs attr | Always | DIAG-only |
|---|---|---|
| `tb_egpu_recover_fires` | ✓ | |
| `tb_egpu_recover_successes` | ✓ | |
| `tb_egpu_recover_surrenders` | ✓ | |
| `tb_egpu_recover_last_fire_jiffies` | ✓ | |
| `tb_egpu_recover_force_trigger` | | ✓ (test-only) |
| `tb_egpu_qwd_cycles` | ✓ | |
| `tb_egpu_qwd_detections` | ✓ | |
| `tb_egpu_qwd_last_detection_jiffies` | | ✓ |
| `tb_egpu_qwd_last_pmc_boot_0` | | ✓ |
| `tb_egpu_qwd_last_aer_summary` | | ✓ |

**Files touched**:

```
kernel-open/nvidia/nv-tb-egpu-diag.c                    (NEW — all diag_dump variants + AER read helpers)
kernel-open/nvidia/nv-tb-egpu-diag.h                    (NEW)
kernel-open/nvidia/nv.c                                 (4 open-side DIAG sites — under CONFIG_NV_TB_EGPU_DIAG)
kernel-open/nvidia/nv-pci.c                             (probe-end DIAG — under CONFIG_NV_TB_EGPU_DIAG)
kernel-open/nvidia/nv-tb-egpu-recover.c                 (cor_error_detected / mmio_enabled wired)
kernel-open/nvidia-uvm/uvm.c                            (5 UVM DIAG sites)
kernel-open/Kbuild                                      (config selection)
```

**Code smells / improvement opportunities**:

- 600+ lines of `pr_info(...big multi-line format string...)`. Hard to maintain. Restructure as `seq_buf_printf` building a per-line buffer, OR `pr_info_once` with a "first event per type" gate.
- AER register field-name spellings inconsistent: `gpu_aer_uesta` (status) vs `gpu_uesta` (status) vs `aer_uesta` — pick one (`uesta` ⇒ Uncorrectable Error Status).
- `tb_egpu_read_aer_full()` takes 12+ output pointers — repack into a `struct tb_egpu_aer_state { ... }`.
- Magic offsets `+ 0x04, + 0x06` for DPC capability (in `aorus_read_dpc_state`) — replace with PCIe spec `PCI_EXP_DPC_CTL` / `PCI_EXP_DPC_STATUS` macros (kernel may not export them; if not, define in our header with reference).
- The `aorus_walk_to_root_port` hop-bound `8` is a magic constant — `TB_EGPU_DIAG_MAX_BRIDGE_HOPS 8`.
- Several `[DIAG]` and `[DIAG-AER]` and `[DIAG-AER2]` format strings — consolidate into a single sysfs-like multi-line format with a constant prefix.
- `EXPORT_SYMBOL(tb_egpu_dump_aer_trigger_event)` and `EXPORT_SYMBOL(tb_egpu_lever_m_diag_dump_pdev)` — these become `EXPORT_SYMBOL_GPL` if used cross-module (uvm.c calls them).
- All diag callers go through `NV_DBG_ERRORS` to ensure visible at default verbosity. After the diag stops being load-bearing for active investigation, downgrade to `NV_DBG_INFO`.
- Patch 0009 (Lever P-probe) introduces 18 markers that should not survive into production; if any are kept, they belong here under DIAG.

**Test plan**:

1. `CONFIG_NV_TB_EGPU_DIAG=n` build: `objdump -t nvidia.ko | grep -E "tb_egpu_diag|tb_egpu_walk_to_root_port"` returns empty (DIAG TU compiled out). `dmesg | grep -E "\\[DIAG|\\[CLOSE"` empty after probe.
2. `CONFIG_NV_TB_EGPU_DIAG=y` build: dmesg shows the 4 open-side + 4 close-side + 5 UVM DIAG sites at each cycle. Counter sysfs files for `last_aer_summary` etc. exist.
3. Performance: cold-boot time with DIAG=y vs DIAG=n. Expect <50 ms difference (DIAG only fires at lifecycle boundaries, not in hot path). Failure mode: a stray DIAG ended up in `osDevReadReg032`.

---

## Section 3: Cross-cutting renames

Master alphabetical table. **Type** key: F=function, S=sysfs-attr, ST=struct, M=macro, MP=module-param, K=kthread, FN=filename, U=uevent-envvar, FP=filepath, MS=marker-string (log/comment).

| Old name | New name | Type | Patches |
|---|---|---|---|
| `aorus-egpu-lever-m` (sbin) | `tb-egpu-recover` (sbin) | FP | 0024 |
| `aorus-qwd-%02x%02x` | `tb-egpu-qwd-%02x%02x` | K | 0014 |
| `aorus_read_aer_full` | `tb_egpu_read_aer_full` | F | 0023 |
| `aorus_read_dpc_state` | `tb_egpu_read_dpc_state` | F | 0023 |
| `aorus_uvm_close_path_diag` | `tb_egpu_uvm_close_diag` | F | 0030 |
| `aorus_uvm_fd_count` | `tb_egpu_uvm_fd_count` | F (static) | 0030 |
| `aorus_uvm_get_gpu_pdev` | `tb_egpu_uvm_get_gpu_pdev` | F | 0030 |
| `aorus_uvm_status_at_entry` | (drop with patch 0009) | local var | 0009 |
| `aorus_walk_to_root_port` | `tb_egpu_walk_to_root_port` | F | 0023 |
| `AORUS Lever I/J-2/M-base/N/O/P-probe/Q*/M-recover/G3-*` | `[tb-egpu …]` short marker | MS (log strings) | many |
| `AORUS UVM [CLOSE]` | `[tb-egpu uvm-close]` | MS | 0030 |
| `AORUS Mode-B Trigger` | `[tb-egpu mode-b trigger]` | MS | 0023 |
| `dev_attr_tb_egpu_lever_m_fires` | `dev_attr_tb_egpu_recover_fires` | (auto from sysfs name) | 0016 |
| `dev_attr_tb_egpu_lever_m_force_trigger` | `dev_attr_tb_egpu_recover_force_trigger` | auto | 0026 |
| `dev_attr_tb_egpu_lever_m_last_fire_jiffies` | `dev_attr_tb_egpu_recover_last_fire_jiffies` | auto | 0016 |
| `dev_attr_tb_egpu_lever_m_successes` | `dev_attr_tb_egpu_recover_successes` | auto | 0016 |
| `dev_attr_tb_egpu_lever_m_surrenders` | `dev_attr_tb_egpu_recover_surrenders` | auto | 0016 |
| `dev_attr_tb_egpu_qwatchdog_cycles` | `dev_attr_tb_egpu_qwd_cycles` | auto | 0015 |
| `dev_attr_tb_egpu_qwatchdog_detections` | `dev_attr_tb_egpu_qwd_detections` | auto | 0015 |
| `dev_attr_tb_egpu_qwatchdog_last_aer_summary` | `dev_attr_tb_egpu_qwd_last_aer_summary` | auto | 0023 |
| `dev_attr_tb_egpu_qwatchdog_last_detection_jiffies` | `dev_attr_tb_egpu_qwd_last_detection_jiffies` | auto | 0023 |
| `dev_attr_tb_egpu_qwatchdog_last_pmc_boot_0` | `dev_attr_tb_egpu_qwd_last_pmc_boot_0` | auto | 0023 |
| `kernel-open/nvidia/nv-lever-m-recover.c` | `kernel-open/nvidia/nv-tb-egpu-recover.c` | FN | 0016+ |
| `kernel-open/nvidia/nv-lever-m-recover.h` | `kernel-open/nvidia/nv-tb-egpu-recover.h` | FN | 0016+ |
| `kernel-open/nvidia/nv-qwatchdog.c` | `kernel-open/nvidia/nv-tb-egpu-qwd.c` | FN | 0014+ |
| `kernel-open/nvidia/nv-qwatchdog.h` | `kernel-open/nvidia/nv-tb-egpu-qwd.h` | FN | 0014+ |
| `NVreg_TbEgpuLeverMMaxAttempts` | `NVreg_TbEgpuRecoverMaxAttempts` | MP | 0016+0024 |
| `NVreg_TbEgpuLeverMMinAttemptIntervalMs` | `NVreg_TbEgpuRecoverMinAttemptIntervalMs` | MP | 0024 |
| `NVreg_TbEgpuLeverMRecoverEnable` | `NVreg_TbEgpuRecoverEnable` | MP | 0016+0024 |
| `NVreg_TbEgpuLeverMResetSettleMs` | `NVreg_TbEgpuRecoverResetSettleMs` | MP | 0016+0024 |
| `NVreg_TbEgpuLeverMSurrenderResetSec` | `NVreg_TbEgpuRecoverSurrenderResetSec` | MP | 0024 |
| `NVreg_TbEgpuLeverMTestForceTrigger` | `NVreg_TbEgpuRecoverTestForceTrigger` | MP | 0024 |
| `NVreg_TbEgpuUncMaskClearEnable` | `NVreg_TbEgpuAerWindowsDefaults` | MP | 0022 |
| `NVreg_TbEgpuWatchdogEnable` | `NVreg_TbEgpuQwdEnable` | MP | 0014 |
| `NVreg_TbEgpuWatchdogIntervalMs` | `NVreg_TbEgpuQwdIntervalMs` | MP | 0014 |
| `nv-lever-m-recover.c` (basename) | `nv-tb-egpu-recover.c` | FN | 0016+ |
| `nv-lever-m-recover.h` (basename) | `nv-tb-egpu-recover.h` | FN | 0016+ |
| `nv-qwatchdog.c` (basename) | `nv-tb-egpu-qwd.c` | FN | 0014+ |
| `nv-qwatchdog.h` (basename) | `nv-tb-egpu-qwd.h` | FN | 0014+ |
| `s_tb_egpu_lever_m_logged` | `s_tb_egpu_recover_logged` (or shared latch) | static var | 0007 |
| `s_tb_egpu_lever_n_logged` | (consolidate to one latch) | static var | 0006 |
| `s_tb_egpu_lever_o_logged` | (consolidate) | static var | 0008 |
| `s_tb_egpu_lever_q_active_logged` | (consolidate) | static var | 0013 |
| `s_tb_egpu_lever_q_passive_logged` | (consolidate) | static var | 0011 |
| `struct tb_egpu_lever_m_recover` | `struct tb_egpu_recover_state` | ST | 0016 |
| `struct tb_egpu_qwatchdog` | `struct tb_egpu_qwd` | ST | 0014 |
| `struct tb_egpu_qwatchdog_aer_snapshot` | `struct tb_egpu_qwd_aer_snapshot` | ST | 0023 |
| `TB_EGPU_LEVER_M_WPR2_REG_OFFSET` | `TB_EGPU_RECOVER_WPR2_REG_OFFSET` | M | 0017 |
| `TB_EGPU_LEVER_M_WPR2_VAL_MASK` | `TB_EGPU_RECOVER_WPR2_VAL_MASK` | M | 0017 |
| `TB_EGPU_QWATCHDOG_DEAD_BUS_VALUE` | `TB_EGPU_QWD_DEAD_BUS_VALUE` (or share with P1) | M | 0014 |
| `TB_EGPU_QWATCHDOG_MAX_INTERVAL_MS` | `TB_EGPU_QWD_MAX_INTERVAL_MS` | M | 0014 |
| `TB_EGPU_QWATCHDOG_MIN_INTERVAL_MS` | `TB_EGPU_QWD_MIN_INTERVAL_MS` | M | 0014 |
| `TB_EGPU_QWATCHDOG_PMC_BOOT_0_OFFSET` | `TB_EGPU_QWD_PMC_BOOT_0_OFFSET` | M | 0014 |
| `tb_egpu_dump_aer_trigger_event` | `tb_egpu_diag_dump_aer_trigger` | F | 0023 |
| `TB_EGPU_GPU_STATE` (env key) | `TB_EGPU_GPU_STATE` (keep) | U | 0024 |
| `tb_egpu_lever_m_apply_killswitch_file` | `tb_egpu_recover_apply_killswitch_file` | F (static) | 0024 |
| `tb_egpu_lever_m_check_wpr2_at_probe` | `tb_egpu_recover_check_wpr2_at_probe` | F | 0017 |
| `tb_egpu_lever_m_close_path_diag` | `tb_egpu_close_diag` | F | 0029 |
| `tb_egpu_lever_m_diag_dump` | `tb_egpu_diag_dump` | F | 0018 |
| `tb_egpu_lever_m_diag_dump_pdev` | `tb_egpu_diag_dump_pdev` | F | 0030 |
| `tb_egpu_lever_m_emit_uevent` | `tb_egpu_recover_emit_uevent` | F | 0024 |
| `tb_egpu_lever_m_fires` | `tb_egpu_recover_fires` | S | 0016 |
| `tb_egpu_lever_m_force_trigger` | `tb_egpu_recover_force_trigger` | S | 0026 |
| `tb_egpu_lever_m_last_fire_jiffies` | `tb_egpu_recover_last_fire_jiffies` | S | 0016 |
| `tb_egpu_lever_m_read_killswitch_file` | `tb_egpu_recover_read_killswitch_file` | F (static) | 0024 |
| `tb_egpu_lever_m_record_post_rminit_ok` | `tb_egpu_recover_record_post_rminit_ok` | F | 0028 |
| `tb_egpu_lever_m_recover_init` | `tb_egpu_recover_init` | F | 0016 |
| `tb_egpu_lever_m_recover_stop` | `tb_egpu_recover_stop` | F | 0016 |
| `tb_egpu_lever_m_reset_work_handler` | `tb_egpu_recover_reset_work_handler` | F (static) | 0016 |
| `tb_egpu_lever_m_slot_reset` | `tb_egpu_recover_slot_reset` | F | 0024 |
| `tb_egpu_lever_m_slot_reset_resume` | `tb_egpu_recover_slot_reset_resume` | F | 0024 |
| `tb_egpu_lever_m_successes` | `tb_egpu_recover_successes` | S | 0016 |
| `tb_egpu_lever_m_surrenders` | `tb_egpu_recover_surrenders` | S | 0016 |
| `tb_egpu_lever_m_trigger_post_rminit_fail` | `tb_egpu_recover_trigger_post_rminit_fail` | F | 0024 |
| `tb_egpu_qwatchdog_cycles` | `tb_egpu_qwd_cycles` | S | 0015 |
| `tb_egpu_qwatchdog_cycles_show` | `tb_egpu_qwd_cycles_show` | F (static) | 0015 |
| `tb_egpu_qwatchdog_detections` | `tb_egpu_qwd_detections` | S | 0015 |
| `tb_egpu_qwatchdog_detections_show` | `tb_egpu_qwd_detections_show` | F (static) | 0015 |
| `tb_egpu_qwatchdog_init` | `tb_egpu_qwd_init` | F | 0014 |
| `tb_egpu_qwatchdog_last_aer_summary` | `tb_egpu_qwd_last_aer_summary` | S | 0023 |
| `tb_egpu_qwatchdog_last_detection_jiffies` | `tb_egpu_qwd_last_detection_jiffies` | S | 0023 |
| `tb_egpu_qwatchdog_last_pmc_boot_0` | `tb_egpu_qwd_last_pmc_boot_0` | S | 0023 |
| `tb_egpu_qwatchdog_stop` | `tb_egpu_qwd_stop` | F | 0014 |
| `tb_egpu_qwatchdog_thread` | `tb_egpu_qwd_thread` | F (static) | 0014 |
| `/var/lib/aorus-egpu/lever-m-killswitch` | `/var/lib/tb-egpu/recover-killswitch` | FP | 0024 |

**Rename count**: ~62 distinct symbols across function/sysfs/struct/macro/module-param/kthread/filename/uevent/filepath/marker-string categories.

---

## Section 4: Kconfig structure proposal

Two Kconfig symbols proposed, both rooted under `kernel-open/Kconfig` (a new file
created in this refactor — upstream open-gpu-kernel-modules doesn't currently
ship one, but `kernel-open/Kbuild` is the right scope).

**File location**: `kernel-open/Kconfig`

```kconfig
config NV_TB_EGPU
    bool "NVIDIA TB-attached eGPU reliability stack"
    default y
    help
      Enables the project-private Thunderbolt eGPU reliability surface
      (in-driver recovery state machine, MMIO-dead-bus short-circuit,
      Q-watchdog kthread, close-path safety, AER Windows-defaults).

      This is necessary for stable operation of an external NVIDIA GPU
      (e.g. RTX 5090) tunnelled over Thunderbolt 4, where upstream
      bug #979 (osHandleGpuLost committing to permanent GPU-lost on a
      single transient PCIe read) breaks the open driver.

      Default Y because this is the host's only path to a working GPU.
      Set N to revert to upstream-open behaviour for A/B comparison.

config NV_TB_EGPU_DIAG
    bool "NVIDIA TB-attached eGPU diagnostic telemetry"
    depends on NV_TB_EGPU
    default n
    help
      Enables diagnostic instrumentation around the eGPU reliability
      stack: PMC_BOOT_0/WPR2/LnkSta/AER state captures at probe,
      start-device, RM-init, and close-path lifecycle points; per-pdev
      AER trigger snapshots; extended sysfs counters
      (tb_egpu_qwd_last_aer_summary, tb_egpu_qwd_last_pmc_boot_0,
      tb_egpu_qwd_last_detection_jiffies).

      All instrumentation is passive (PCI config-space + temporary
      ioremap + ioread32 + iounmap). No DMA, no register writes outside
      the AER mask path (which is separately gated by
      NVreg_TbEgpuAerWindowsDefaults).

      Default N. Enable only for active investigation or development.
      Per feedback_observability_perturbs_bug, even passive
      observability can perturb the bug surface — A/B verify if your
      reproduction changes when this is on.
```

**What `CONFIG_NV_TB_EGPU` (master) gates**:
- All P1, P2, P3, P5 code paths.
- The `nv-tb-egpu-*.c` source files in `nvidia-sources.Kbuild`.
- `tb_egpu_recover_init` / `_stop` calls in `nv_pci_probe` / `_remove`.
- The `nv_pci_err_handlers` struct registration.
- The os_pci_is_disconnected / set_disconnected helper exports.
- The osDevReadReg* short-circuit branches.

**What `CONFIG_NV_TB_EGPU_DIAG` gates**:
- All P6 code (every DIAG_* function in `nv-tb-egpu-diag.c`).
- The 4 open-side + 4 close-side DIAG site calls.
- The 5 UVM DIAG site calls.
- The `last_aer_summary` / `last_pmc_boot_0` / `last_detection_jiffies` sysfs files.
- The `force_trigger` sysfs file (test-only).

**Note**: Most upstream Linux kernel modules use `Kconfig` inheriting from
the parent in-tree build system; out-of-tree modules (like NVIDIA's) often
use Makefile conditionals instead. Verify which approach NVIDIA's
`kernel-open/Kbuild` supports — they currently use `make` variables
(`NV_BUILD_OPENRM_RM_DLL_UNINSTALL=1`-style). If Kconfig integration is
not feasible, fall back to:

```makefile
# kernel-open/Kbuild
CONFIG_NV_TB_EGPU       ?= y
CONFIG_NV_TB_EGPU_DIAG  ?= n
ifeq ($(CONFIG_NV_TB_EGPU),y)
ccflags-y += -DCONFIG_NV_TB_EGPU
NVIDIA_SOURCES += nvidia/nv-tb-egpu-recover.c
NVIDIA_SOURCES += nvidia/nv-tb-egpu-qwd.c
NVIDIA_SOURCES += nvidia/nv-tb-egpu-aer.c
endif
ifeq ($(CONFIG_NV_TB_EGPU_DIAG),y)
ccflags-y += -DCONFIG_NV_TB_EGPU_DIAG
NVIDIA_SOURCES += nvidia/nv-tb-egpu-diag.c
endif
```

---

## Section 5: Risk / regression list

### Especially-careful refactors

1. **Patch 0024 (838 lines, M-recover Commit 3)** — the H1/H2/H3/H4 hardening is intricate. The H1 MaxAttempts gate was already broken once (fixed in 0028); the gate-and-counter dance has multiple cross-state preconditions. Refactor should keep the existing per-state truth-table comment block intact. **Property-test the gate logic** with fault injection before declaring done.

2. **Patch 0023 (464 lines, Mode B telemetry)** — many config-space register reads with magic offsets; `aorus_walk_to_root_port` traversal is bounded but bugs in `pci_pcie_type()` could loop. Keep the `hops < 8` invariant.

3. **Patch 0014 (352 lines, qwd kthread)** — concurrency-sensitive (kthread vs probe/remove). The current code uses `kthread_stop` + `kthread_should_stop` + `msleep_interruptible` correctly, but the field write to `nvl->qwd` from probe is unsynchronised vs the thread's read at entry. Audit for a probe-side `smp_wmb` / `WRITE_ONCE` or use of `cmpxchg`.

4. **Patch 0030 (332 lines, UVM cross-module)** — `extern` symbols from nvidia.ko into nvidia-uvm.ko. EXPORT_SYMBOL licence + ABI stability. The hardcoded BDF `0000:04:00.0` in `aorus_uvm_get_gpu_pdev` is a portability defect.

5. **Patch 0017 (243 lines, probe-time WPR2 check)** — uses temporary `ioremap` of BAR0 BEFORE the RM has set up its own mapping. Race-prone if probe-time PCI lifecycle changes in upstream.

### Userspace ABI dependencies

| Surface | Consumer | Migration |
|---|---|---|
| Kthread name `aorus-qwd-%02x%02x` | `ps`/`ls /proc` / project README example | README update; document the rename in CHANGELOG |
| Sysfs prefix `tb_egpu_qwatchdog_*` | project README line 236 | README update; tools/ has no references |
| Sysfs prefix `tb_egpu_lever_m_*` | None found in tools/, scripts/, etc. | safe rename |
| Kill-switch file `/var/lib/aorus-egpu/lever-m-killswitch` | userspace sbin scripts referenced by patch 0024 commit msg (`aorus-egpu-lever-m`, `aorus-egpu-lever-m-killswitch-restore`) and a udev rule `82-aorus-egpu-lever-m-killswitch.rules`. **These userspace artefacts are NOT in the current repo** — verify the live host's state before changing path. | Coordinated dual-read transition: driver reads both paths during transition window; rename sbin scripts; ship udev rule update |
| Uevent envvar `TB_EGPU_GPU_STATE=...` | udev rules in repo? grep showed none | safe to keep name as-is |
| Module-param names `NVreg_TbEgpu*` | `/etc/modprobe.d/` in install workflow | All renames touch this surface; `etc/modprobe.d/` in repo needs audit |

### Race conditions / locking to preserve

1. **`atomic_xchg(&lm->in_progress, 1)` re-entry guard** in `tb_egpu_lever_m_trigger_post_rminit_fail` — must remain atomic and ordered before any other state read. Don't replace with `READ_ONCE` + `WRITE_ONCE` separately.

2. **`pci_lock_rescan_remove() / unlock`** around `pci_reset_bus()` in the work handler — serializes vs hotplug. Keep.

3. **`cancel_work_sync(&lm->reset_work)` in stop path** — must run BEFORE `kfree(lm)`. Existing code is correct.

4. **`pci_dev_get` / `pci_dev_put` refcounting** for `pdev_for_work` — currently the trigger function grabs the ref, the work handler drops it (`out_put` label). The "defensive: stale pdev_for_work" path leaks one ref + drops it; this is correct but fragile. Either prove the in_progress guard makes the stale case impossible (then assert), or keep the defensive cleanup.

5. **kthread vs `nvl->qwd` write ordering** (see Risk #3 above).

6. **AER `error_detected` is in IRQ-ish context** — must not sleep. The `nv_pci_error_detected` path currently calls `tb_egpu_dump_aer_trigger_event` which does PCI config-space reads (potentially sleeping on some buses). Audit: are config-space reads OK from this context? If yes, document. If no, defer to work handler.

### Pre-existing `/dev/nvidia-uvm*` perm-drift gap (Gap #8)

Per the task brief: this is an out-of-scope known issue where the device-node
permissions on `/dev/nvidia-uvm` and `/dev/nvidia-uvm-tools` drift away from
the udev-rule-set values after some lifecycle event (likely the close-path
recreating the device). The refactor MUST NOT regress whatever permission-
setting behaviour exists today — specifically:

- Do not change anything in `nvidia_close_callback` / `uvm_release` that
  could alter the order in which the UVM character devices are destroyed
  and recreated.
- The new `tb_egpu_close_diag` calls are observational only and should not
  affect chardev lifecycle. Validate via a `stat /dev/nvidia-uvm*` after
  every open/close in the test plan.

No fix attempted in the refactor.

---

## Section 6: Summary

### Estimated final line counts (kernel patch surface only)

| Cluster | Legacy lines | Estimated post-refactor lines |
|---|---|---|
| P1 (GPU-lost crash safety) | ~485 | ~280 |
| P2 (PCIe err handlers + M-recover) | ~2,050 | ~1,200 |
| P3 (Q-watchdog) | ~775 | ~520 |
| P4 (Close-path safety, non-DIAG residual) | ~640 (mostly DIAG) | ~80 (non-DIAG residual; rest → P6) |
| P5 (AER Windows defaults) | 126 | ~60 |
| P6 (Diagnostic telemetry, gated) | ~1,700 | ~900 (under CONFIG_NV_TB_EGPU_DIAG) |
| **TOTAL** | ~4,873 (with overlap counted multiple times across patches that touched same files) | **~3,040** |
| N/A drop (patch 0009 Lever P-probe) | 172 | 0 |
| N/A build-metadata (0005, 0025) | 69 | ~10 (single Kbuild include) |

Net: ~38% reduction (~4,873 → ~3,040 effective lines).

### Distinct rename count

~62 across 10 categories (F, S, ST, M, MP, K, FN, U, FP, MS).

### Confidence levels

| Cluster | Confidence | Rationale |
|---|---|---|
| P1 | **HIGH** | Mostly mechanical short-circuit prologue additions; well-isolated; clear failure modes; no shared state |
| P5 | **HIGH** | Single function, one register write, well-tested mechanism, no concurrency |
| P3 | **MEDIUM-HIGH** | Kthread is concurrency-sensitive but the existing locking is straightforward; biggest risk is the probe/remove vs kthread race noted above |
| P2 | **MEDIUM** | H1/H2/H3/H4 gate logic is intricate; multiple inter-state preconditions; needs property-test |
| P4 | **MEDIUM-LOW** | Non-DIAG residual is small but the close-path semantics are subtle (LAST-CLOSE detection); UVM cross-module export is fragile |
| P6 | **LOW** | Pure diagnostic; correctness is "is the print correct?" rather than "does the bug get fixed?" — and there's a lot of it; perturbation risk to live bugs (`feedback_observability_perturbs_bug`) is real |

### Recommended order

`P5 → P1 → P3 → P2 → P4 → P6`

Reasoning:
- **P5 first**: trivially small (60 lines), entirely self-contained, no dependencies on other clusters. Builds momentum and validates the rename/Kconfig pipeline before any high-stakes work.
- **P1 next**: foundational. P2's `nv_pci_error_detected` DISCONNECT path RELIES on the P1 cleanup cascade being intact. Get P1 in cleanly first so P2 can build on a verified foundation.
- **P3**: independent of P2 (qwd has its own state). Lands the new `nv-tb-egpu-qwd.{c,h}` files and proves the Kbuild + EXPORT_SYMBOL + Kconfig wiring works.
- **P2**: the biggest cluster; depends on P1 (cleanup cascade for DISCONNECT branch), P3 (Mode B detector is the other entry point), P5 (Windows-defaults AER mask is part of probe init).
- **P4**: small residual; depends on P2 (close-path probes the recover state struct).
- **P6 last**: pure observability; can be added/removed without functional risk; minimal coupling. Doing it last avoids re-renaming after every prior cluster moves things around.

Alternative: brief told you "probably P1 → P5 → P2 → P3 → P4 → P6 — smallest first, largest last". My alternative `P5 → P1 → P3 → P2 → P4 → P6` differs only in trading "smallest first" for "self-contained first" (P5 is genuinely smaller than P1, but more important: P5 is fully isolated whereas P1 has 6 separate file touches). Either order works.

### Surprises in the patch surface

1. **Patch 0019 is missing** from the series. The patches jump from 0018 → 0020. Either it was retracted, or there was a renumbering. Worth confirming with the author before the refactor.
2. **Patch 0005 is already partially superseded by 0025** (`Kbuild-version-from-version-mk`); after refactor, the version-string mechanism should be the single Kbuild include, no manual `-DNV_VERSION_STRING=` literal anywhere.
3. **Patch 0007's `s_tb_egpu_lever_m_logged` and Patch 0024's revised `nv_pci_error_detected` both define the same static** — patch 0024 reuses the existing latch, which works but is a code smell. Consolidate.
4. **`tb_egpu_*` naming was already in flight** — patches 0014-0030 already use the `tb_egpu_*` prefix consistently for module-params, struct names, and most function names. The "rename" is therefore mostly: dropping `_lever_m_`, `_qwatchdog_`, and `aorus_` infixes, NOT a full naming overhaul. The brief's "ALL `aorus_*` / `AORUS_*` symbols must be renamed" mostly applies to: log marker strings ("AORUS Lever I …"), the kthread name (`aorus-qwd-%02x%02x`), the kill-switch path, and a small handful of `aorus_*` helpers in patches 0023 and 0030.
5. **Patch 0009 (Lever P-probe)** adds 18 dmesg markers with a single shared `aorus_uvm_status_at_entry` gating local. None of the markers are referenced from any other patch; the patch reads as fully consumed by its own diagnostic purpose. Strong recommendation to drop entirely rather than refactor.
6. **EXPORT_SYMBOL (non-GPL) usage** for cross-module symbols (`tb_egpu_dump_aer_trigger_event`, `tb_egpu_lever_m_diag_dump_pdev`) — nvidia.ko is dual-licensed but UVM linkage uses these as plain exports. If anything moves to GPL-only kernel APIs (and `kernel_read_file_from_path` is one of them — it's `EXPORT_SYMBOL_GPL` in mainline), the whole TU it lives in implicitly becomes GPL-tainted. Already true for the patched module; just flagging.

---

End of inventory. ~520 lines.
