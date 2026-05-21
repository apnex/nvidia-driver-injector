# Patch refactor — status + handover

Working document for the P1-P6 patch refactor of the
`nvidia-driver-injector` driver patch series.
Updated through Phase 2 as each patch lands.
Use this as the entry point when resuming work in a fresh session.

**Last updated:** 2026-05-12.

---

## TL;DR — where we are now

| | |
|---|---|
| **Phase** | 2 ✓ — ready for Phase 3 |
| **Patches landed** | P5 (`b2891e5`), P1 (`f5d0900`), P3 (`a19c1ac`), P2 (`e4cb622`), P4 (`52b43f0`), P6 (`6d52a06`), P7 (`16921cb`) — **7 of 7 ✓** |
| **Patches pending** | none |
| **Branch** | `refactor/p1-p6` in `/root/nvidia-driver-injector` |
| **Legacy patches** | All 29 retained at `patches/legacy/` (fallback during transition) |
| **Container image tag** | `apnex/nvidia-driver-injector:refactor-rc1` (refactor build); `:595.71.05-aorus.12` (legacy production build) |
| **Production safety** | Untouched — the running container still uses the legacy image tag |

---

## First-day-back orientation (read these in order)

1. **This file** (`docs/patch-refactor-status.md`) — you are here
2. **Inventory** (`docs/patch-refactor-inventory.md`) — 810 lines, the design source-of-truth
3. **`git log refactor/p1-p6 ^main --oneline`** — see what's already committed
4. **`git diff main...refactor/p1-p6 -- patches/`** — see exactly what's changed in `patches/`
5. **Memory entries** (auto-loaded):
   - `project_geometry_pivot_to_injector_2026_05_12.md` — the two-geometry context
   - `project_nvidia_lazy_init_persistence_2026_05_12.md` — recent thermal fix work
   - `feedback_lever_catalog_discipline.md` — naming + cross-reference discipline
   - `feedback_native_in_driver_hardening.md` — destination architecture

---

## Decisions locked (do not re-litigate)

### Naming

| Layer | Convention |
|---|---|
| New helpers, macros, constants | `tb_egpu_*` / `TB_EGPU_*` |
| New module params | `NVreg_TbEgpu*` |
| Sysfs attributes | `/sys/.../tb_egpu_*` |
| Kthread names | `tb-egpu-*` |
| Log prefix | `"tb_egpu: "` |
| Upstream RM/kernel-open symbols | UNCHANGED (we insert code INTO them, don't rename) |

Naming reasoning rule: symbols describe **what they do**, not **how we found we needed them** (e.g., NOT `NVreg_TbEgpuAerWindowsDefaults` — `Windows` was a discovery artifact, not a design statement).

### Kconfig (planned, NOT yet wired up — deferred to end of Phase 2)

| Symbol | Default | Gates |
|---|---|---|
| `CONFIG_NV_TB_EGPU` | y | P1-P5 (all stability features) |
| `CONFIG_NV_TB_EGPU_DIAG` | n | P6 only (telemetry; ~10% binary win on production builds) |

### Cluster → file-number mapping

```
patches/0001-tb-egpu-gpu-lost-crash-safety.patch       (P1 — apply 1st)
patches/0002-tb-egpu-aer-uncmask-clear.patch           (P5 — apply 2nd; standalone)
patches/0003-tb-egpu-qwatchdog.patch                   (P3 — apply 3rd; needs P1 only)
patches/0004-tb-egpu-pcie-error-handlers-recover.patch (P2 — apply 4th; needs P1 + P3)
patches/0005-tb-egpu-close-path-safety.patch           (P4 — apply 5th; needs P2)
patches/0006-tb-egpu-diag-telemetry.patch              (P6 — apply 6th; Kconfig-gated)
patches/0007-tb-egpu-version-mark-and-kbuild.patch     (build metadata)
```

**File-number = apply order** (kernel patch convention). **Px label = cluster identity**. **Write order ≠ either**: we write smallest-first for confidence (P5 → P1 → P3 → P2 → P4 → P6).

**P2/P3 file numbers swapped 2026-05-12**: the original inventory assumed P3 depended on P2 (qwd would call into P2's recovery state machine). Option-1 cross-cluster split during P3 write inverted that — P3 now stands alone on P1, and P2 patches into P3's qwd code to wire the AER-capture call. File 0003 = P3, file 0004 = P2 reflects the correct apply-time dependency direction.

### What's deliberately NOT renamed

- Upstream NVIDIA function names (`osHandleGpuLost`, `rcdbAddRmGpuDump`, etc.) — we insert into them
- Files in `kernel-open/` other than what each Px touches
- Legacy patches in `patches/legacy/` (frozen reference)

---

## Per-cluster status

### P5 — clear AER UncMask at probe (DONE)

| | |
|---|---|
| Commit | `b2891e5` |
| Patch file | `patches/0002-tb-egpu-aer-uncmask-clear.patch` (322 lines) |
| Legacy source | 0022 |
| Net code | +193 lines |
| Module param | `NVreg_TbEgpuAerUncMaskClear` (default 1) |
| Public API | `int tb_egpu_aer_clear_uncor_mask(struct pci_dev *)` |
| New files | `kernel-open/nvidia/nv-tb-egpu-aer.{c,h}` |
| Validation | git apply --check OK; container build OK |

### P1 — GPU-lost crash-safety cascade (DONE)

| | |
|---|---|
| Commit | `f5d0900` |
| Patch file | `patches/0001-tb-egpu-gpu-lost-crash-safety.patch` (681 lines) |
| Legacy source | 0001, 0002, 0003, 0004, 0006, 0008, 0010, 0011, 0012, 0013 |
| Net code | +366 / -4 vs vanilla |
| New header | `src/nvidia/arch/nvalloc/unix/include/nv-tb-egpu.h` |
| New macros | `TB_EGPU_LOG_ONCE`, `NV_ASSERT_OR_GPU_LOST` |
| New constants | `TB_EGPU_GPU_LOST_RETRIES`, `_DELAY_US`, `TB_EGPU_DEAD_BUS_U32/U16/U8` |
| New helper | `tb_egpu_check_dead_bus(OBJGPU *)` (consolidates 8/16/32-bit MMIO) |
| Semantic correction | Q-active sanity test uses canonical `TB_EGPU_DEAD_BUS_U32` (not the legacy `!= nvp->pmc_boot_0`) |
| Validation | git apply --check vs vanilla OK; P5 stacks cleanly on top; container build OK |
| Open items | (1) `TB_EGPU_LOG_ONCE` is per-site latch (matches legacy); user confirmed. (2) `rs_server.c` has two NV_ASSERT sites; legacy + subagent kept relaxed scope to the second only (recursive site unreachable on GPU-lost path). |

### P3 — Q-watchdog Mode B detector (DONE)

| | |
|---|---|
| Commit | `a19c1ac` (renamed to file 0003 in commit follow-up) |
| Patch file | `patches/0003-tb-egpu-qwatchdog.patch` (673 lines incl. header) |
| Legacy source | 0014, 0015, S3 portion of 0023 |
| Net code | +515 lines (new files +485, edits +30) |
| New files | `kernel-open/nvidia/nv-tb-egpu-qwd.{c,h}` |
| Module params | `NVreg_TbEgpuQwdEnable`, `NVreg_TbEgpuQwdIntervalMs` |
| kthread name | `tb-egpu-qwd-<bus><slot>` |
| Sysfs surface | per-attr (under `/sys/bus/pci/devices/<bdf>/`); registered via single `attribute_group` + `sysfs_create_group` |
| Sysfs files | `tb_egpu_qwd_cycles`, `tb_egpu_qwd_detections`, `tb_egpu_qwd_last_detection_jiffies`, `tb_egpu_qwd_last_pmc_boot_0`, `tb_egpu_qwd_last_aer_summary` |
| Validation | git apply --check vs vanilla 595.71.05 with P1+P5 stacked OK; container build (refactor-rc1) OK |
| Cross-cluster note | **P2 must add one line to `tb_egpu_qwd_thread` detect branch**: `tb_egpu_dump_aer_trigger_event(nvl->pci_dev, "qwd-detect", &qwd->last_aer);`. Until then, `last_aer.valid` stays 0 and `last_aer_summary` reads `(no detection event yet)`. |
| Open items | (1) README.md lines 236 + 238 still reference old sysfs prefix `tb_egpu_qwatchdog` and old kthread name `aorus-qwd-0400`; updates scoped to Phase 4. (2) Sysfs path layout: chose per-attr (decision #3 below). |

### P2 — PCIe error handlers + recovery state machine (DONE)

| | |
|---|---|
| Commit | `e4cb622` |
| Patch file | `patches/0004-tb-egpu-pcie-error-handlers-recover.patch` (1807 lines incl. header) |
| Legacy source | 0007, 0016, 0017, **S1 portion of 0023** (S2 deferred to P6 — see below), 0024, 0026, 0027, 0028, err_handlers parts of 0029 |
| Net code | +1521 / -5 (incl. new `nv-tb-egpu-recover.{c,h}`: 1074 + 255 lines) |
| New files | `kernel-open/nvidia/nv-tb-egpu-recover.{c,h}` |
| Module params | 6 × `NVreg_TbEgpuRecover*` (Enable default 0; TODO flip to 1 after Phase-3 soak) |
| Sysfs surface | `tb_egpu_recover_{fires, successes, surrenders, last_fire_jiffies, force_trigger}` under `/sys/bus/pci/devices/<bdf>/`; registered via single `attribute_group` + `sysfs_create_group` |
| Kill-switch file | `/var/lib/tb-egpu/recover-killswitch` (promoted to `TB_EGPU_RECOVER_KILLSWITCH_PATH`) |
| Consolidation wins | (1) gate logic deduped via `enum tb_egpu_recover_gate` + `tb_egpu_recover_pre_schedule_gates()`; (2) WPR2 ioremap/read/iounmap triplet extracted to `tb_egpu_recover_read_wpr2()`; (3) `pdev_for_work` defensive branch removed (dead code per ordering audit, WARN_ON_ONCE tripwire kept); (4) AER-capture helper de-EXPORT_SYMBOL'd (internal to nvidia.ko); (5) inter-commit chronology comments stripped. |
| Cross-cluster touch | One-line `tb_egpu_dump_aer_trigger_event(nvl->pci_dev, "qwd-detect", &qwd->last_aer)` added inside P3's `tb_egpu_qwd_thread` `!detected_logged` latch. With P2 in series, P3's `last_aer_summary` sysfs reads the full AER + DPC snapshot at first detect of each episode. |
| Validation | git apply --check vs vanilla 595.71.05 with P1+P5+P3 stacked OK; container build (refactor-rc1) OK |
| Deviations (carry forward) | (a) **S2 (DIAG-AER2) deferred to P6** — extends `tb_egpu_lever_m_diag_dump` which legacy 0018 introduces (= P6 territory). P6 will own: introduction of `diag_dump` from 0018, the S2 expansion, and re-introducing the `diag_dump` call sites in P2's err_handlers (the AER-capture call already lives here). (b) Gate helper takes a `pdev` parameter (not in original brief) so `GATE_SURRENDER` can emit `PERMANENT_FAIL` uevent in-helper. |

### P4 — close-path observability (DONE)

| | |
|---|---|
| Commit | `52b43f0` |
| Patch file | `patches/0005-tb-egpu-close-path-safety.patch` (691 lines incl. header) |
| Legacy source | 0029 (RM-side close-path DIAG, minus err_handlers parts already in P2), 0030 (UVM-side close-path DIAG) |
| Net code | +423 / -2 across 7 files |
| New files | `kernel-open/nvidia-uvm/nv-tb-egpu-uvm.{c,h}` (project-private UVM-side cluster) |
| RM-side call sites (`nv.c`) | close-entry, pre-stop, post-shutdown, close-exit |
| UVM-side call sites (`uvm.c`) | uvm-open-entry, uvm-release-entry, uvm-pre-destroy, uvm-post-destroy, uvm-release-exit |
| Cross-module exports | `tb_egpu_dump_aer_trigger_event` (now EXPORT_SYMBOL_GPL — was internal in P2), `tb_egpu_close_diag_pdev`, `tb_egpu_get_gpu_pdev` |
| Sovereignty/cohesion wins | (1) hardcoded BDF replaced by `tb_egpu_get_gpu_pdev()` (walks `nv_linux_devices`); (2) 60+ line inline blob in `uvm.c` moved to new `nv-tb-egpu-uvm.{c,h}` pair (uvm.c touch is now 1 include + 8 single-line calls); (3) `void *out` type-erasure eliminated; (4) 5 site-named atomic-pattern helpers; (5) reuses P2's WPR2 helper; (6) EXPORT_SYMBOL_GPL audit done. |
| Cross-cluster | `tb_egpu_close_diag` (RM-side) uses its own `close_diag_pdev` for state capture — does NOT depend on P6's `recover_diag_dump`. P4 lands fully functional without P6. P4 also promotes P2's `tb_egpu_dump_aer_trigger_event` to `EXPORT_SYMBOL_GPL`. |
| Validation | git apply --check vs vanilla 595.71.05 with P1+P5+P3+P2 stacked OK; container build (refactor-rc1) OK |

### P6 — Diagnostic telemetry surface (DONE)

| | |
|---|---|
| Commit | `6d52a06` |
| Patch file | `patches/0006-tb-egpu-diag-telemetry.patch` (611 lines incl. header) |
| Legacy source | 0018, 0020, 0021, S2 portion of 0023 (DIAG-AER2 expansion); err_handlers parts of 0029 reintroduce diag_dump call. Legacy 0009 (Lever P-probe) DROPPED entirely. |
| Net code | +364 / -6 across 7 files |
| New files | `kernel-open/nvidia/nv-tb-egpu-diag.{c,h}` (223 + 52 lines) |
| Function | `tb_egpu_diag_dump(nvl, site)` |
| Call sites | 6 — probe-end (nv-pci.c), startdev-entry / pre-rmInit / post-rmInit-FAIL / post-rmInit-OK (nv.c), mmio-enabled (re-introduced in nv-pci.c — P2 had to drop pending P6) |
| Log line classes | `[DIAG]` (always), `[DIAG-AER]` (GPU AER status non-zero only), `[DIAG-AER2]` (root port AER + DPC, always; cheap) |
| Cohesion wins | (1) new file pair separates always-load-bearing recovery from observational diag; (2) reuses 4 P2 helpers (read_wpr2, walk_to_root_port, read_dpc_state, read_aer_full) via static-to-module-internal promotion — zero code duplication; (3) inventory's aspirational rename to `tb_egpu_diag_dump_pdev` rejected (would have duplicated P4's `tb_egpu_close_diag_pdev` — as-shipped name wins); (4) inter-commit history comments from legacy 0018 stripped |
| Cross-cluster | Modifies P2: 4 helper `static` qualifiers lifted to module-internal linkage; declarations added to recover.h. Modifies P2: re-introduces `tb_egpu_diag_dump` call inside `nv_pci_mmio_enabled` (P2 forecast this). |
| Kconfig gating | **NOT in P6.** P6 ships always-on. Deferred to P7 per locked decision "Kconfig wiring deferred to end of Phase 2". |
| Validation | git apply --check vs vanilla 595.71.05 with P1+P5+P3+P2+P4 stacked OK; container build (refactor-rc1) OK |

### P7 — build metadata + Kconfig wiring (DONE)

| | |
|---|---|
| Commit | `16921cb` |
| Patch file | `patches/0007-tb-egpu-version-mark-and-kbuild.patch` (219 lines incl. header) |
| Legacy source | 0005 (NVIDIA_VERSION bump), 0025 (Kbuild version-mk include) |
| Net code | +61 / -2 across 4 files |
| Version | NVIDIA_VERSION bumped to `595.71.05-aorus.13` |
| Single source of truth | `kernel-open/Kbuild` now `include $(src)/../version.mk` and uses `$(NVIDIA_VERSION)` in `-DNV_VERSION_STRING` — Kbuild/version.mk drift impossible |
| Kconfig toggles | `CONFIG_NV_TB_EGPU ?= y` (master, documentation-only today), `CONFIG_NV_TB_EGPU_DIAG ?= n` (real toggle for P6 diag content) |
| DIAG=n strip mechanism | nvidia-sources.Kbuild wraps `nv-tb-egpu-diag.c` in `ifeq ($(CONFIG_NV_TB_EGPU_DIAG),y)`; `nv-tb-egpu-diag.h` provides `static inline` no-op stub. The 6 call sites in nv.c + nv-pci.c compile to nothing when DIAG=n. ~10% binary size win on production builds per inventory Section 4 |
| Deferred to follow-up | (a) CONFIG_NV_TB_EGPU=n full opt-out (would require wrapping all P1-P5 additions in `#ifdef` — hundreds of additional gates); (b) DIAG-only sysfs gating for qwd `last_aer_summary` / `last_pmc_boot_0` / `last_detection_jiffies` files |
| Validation | git apply --check vs vanilla 595.71.05 with all 6 prior patches stacked OK; container build (refactor-rc1) OK with default DIAG=n and with explicit DIAG=y override |

---

## Workflow recipe (what each Px takes)

### Standard procedure for writing the next Px

```bash
# 1. Read the cluster's section in docs/patch-refactor-inventory.md

# 2. Reset the working tree to a known stacked state
cd /tmp/nv-vanilla
# Make sure it's at the right base for this Px — i.e. has all prior Px applied.
# If lost or in unknown state:
rm -rf /tmp/nv-vanilla
git clone --depth 1 -b 595.71.05 \
    https://github.com/NVIDIA/open-gpu-kernel-modules /tmp/nv-vanilla
cd /tmp/nv-vanilla
# Apply the patches in the new series that come BEFORE this Px:
for p in /root/nvidia-driver-injector/patches/0001-*.patch /root/nvidia-driver-injector/patches/0002-*.patch; do
    git apply "$p"
done
git -c user.email="bot@nvidia-driver-injector" -c user.name="nvidia-driver-injector" \
    commit -am "stacked baseline"

# 3. Write the new Px:
#    - Read the legacy patches it consolidates in patches/legacy/
#    - Apply the inventory's improvements (naming, constants, macros, etc.)
#    - Edit /tmp/nv-vanilla source files directly

# 4. Commit + generate the patch file:
git add -A
git commit -m "tb-egpu: <cluster purpose> (cluster Px)"

# Write the patch file with a hand-crafted header (NOT format-patch auto-header):
cat > /root/nvidia-driver-injector/patches/000N-tb-egpu-<purpose>.patch <<'PATCH_HEADER'
From: nvidia-driver-injector <noreply@example.invalid>
Date: 2026-05-12
Subject: [PATCH 000N/0007] tb-egpu: <subject>

<thorough commit message>

PATCH_HEADER

git format-patch -1 --stdout | awk '/^---$/{found=1} found' \
    >> /root/nvidia-driver-injector/patches/000N-tb-egpu-<purpose>.patch

# 5. Verify the patch:
cd /tmp && rm -rf nv-test
git clone --depth 1 -b 595.71.05 \
    https://github.com/NVIDIA/open-gpu-kernel-modules nv-test
cd nv-test
for p in /root/nvidia-driver-injector/patches/000*-tb-egpu-*.patch; do
    git apply --check "$p"
    [ $? -ne 0 ] && echo "FAIL: $p" && exit 1
    git apply "$p"
done

# 6. Container build (validates the full stack):
cd /root/nvidia-driver-injector
sudo docker build -t apnex/nvidia-driver-injector:refactor-rc1 .

# 7. Commit to the refactor branch:
git add patches/000N-tb-egpu-<purpose>.patch
git commit -m "Px: <subject>"

# 8. Update this status doc
```

### When to delegate to a subagent vs write yourself

- **Mechanical / pattern-following** (P5, P1, P6): subagent works well
- **Large state-machine** (P2): subagent works if given strong inventory section
- **Subtle ordering / locking semantics**: write yourself or supervise closely
- **Final polish (header file, commit message)**: review whatever the subagent produces

---

## Phase 3 — stack validation plan (after all 6 land)

Run the full uninstall/reinstall cycle from `docs/install-workflow.md` against the refactored patches:

```bash
# Phase 2 done; container already built with all new patches in patches/
# Validate the stack survives the same test cycle we ran 2026-05-12

# 1. Stop legacy production
sudo docker compose down       # in /root/nvidia-driver-injector
sudo docker compose down       # in /root/vllm (if running)

# 2. Switch image tag to refactor-rc1 (one-line edit in compose):
#    image: apnex/nvidia-driver-injector:refactor-rc1
# Or, after a final test:
sudo docker tag apnex/nvidia-driver-injector:refactor-rc1 \
                apnex/nvidia-driver-injector:595.71.05-aorus.13

# 3. Bring up: docker compose up -d --build
# 4. Verify with sudo ./scripts/status.sh — expect ≥38/40 OK

# 5. Run the uninstall/reinstall cycle:
sudo docker compose run --rm driver-injector uninstall
sudo docker compose down
sudo ./scripts/remove.sh --purge
sudo reboot                    # USER ACTION

# After reboot:
cd /root/nvidia-driver-injector
sudo ./scripts/apply.sh
sudo reboot                    # USER ACTION (if cmdline changed)

# After 2nd reboot:
sudo docker compose up -d --build
sudo ./scripts/status.sh       # expect ≥38/40 OK

# 6. Soak test 24-48h, verify counters in /sys/.../tb_egpu_*
```

---

## Phase 4 — documentation plan (after Phase 3 green)

```
docs/patches.md              NEW — explains P1..P6 architecture
docs/architecture.md         UPDATE — Layer 2 now references P1..P6 not "29 patches"
README.md                    UPDATE — patch summary table
patches/README.md            NEW — for the patch directory itself
```

Each Px commit message becomes part of the architecture documentation.

---

## Phase 5 — upstream prep (DEFERRED until production-validated)

Decision: do NOT prep upstream submission until at least one production soak passes (probably 1-2 weeks of vLLM workload on the new patches).

If pursued: P1 is the most upstream-ready (bug #979 core fix); P5 is also reasonable (AER tuning).

---

## Open decisions (carry forward to Phase 2 continuation)

1. **`TB_EGPU_LOG_ONCE` semantics** — DECIDED 2026-05-12: per-site latch (matches legacy). Each call site gets its own function-scope-static.
2. **`rs_server.c` two NV_ASSERT sites** — DECIDED 2026-05-12: kept legacy scope (relaxed only the in-place call, recursive site unreachable on GPU-lost path).
3. **P3 sysfs path layout** — DECIDED 2026-05-12: per-attr at the device level, but registered as a single `static const struct attribute_group` via `sysfs_create_group` (consolidates the 5 legacy `device_create_file` pairs to one init + one teardown call).
4. **Kconfig wiring** — DEFERRED to end of Phase 2 (mechanical once all 6 patches exist).
5. **Patch 0019 gap in legacy series** — irrelevant; legacy is going away.
6. **Patch 0009 (Lever P-probe)** — DECIDED: drop entirely (purely investigation-period probes).
7. **Patch metadata (legacy 0005 + 0025)** — combined into single P7 patch at end.

---

## Risks (carry forward)

- **P2 is the biggest patch** (~1,400 lines). Subagent works but supervise carefully.
- **Race / locking invariants** in P2 + P3 must be preserved exactly. The inventory's Section 5 lists 6 of them.
- **Gap #8** (`/dev/nvidia-uvm*` perm-drift to 666 root:root) is pre-existing. Don't try to fix during refactor; don't regress it either.
- **userspace ABI** dependencies: kthread name + sysfs prefix are referenced in `README.md` and `tools/` scripts. Plan to update README in Phase 4 to reflect the rename.

---

## Quick commands cheat sheet

```bash
# See what's done in the refactor branch
cd /root/nvidia-driver-injector
git log refactor/p1-p6 ^main --oneline

# See what patches exist in the new series
ls patches/ | grep -v legacy

# Check current image tags
sudo docker images apnex/nvidia-driver-injector

# Validate a patch applies to vanilla
cd /tmp && rm -rf nv-check && \
    git clone --depth 1 -b 595.71.05 https://github.com/NVIDIA/open-gpu-kernel-modules nv-check && \
    cd nv-check && \
    for p in /root/nvidia-driver-injector/patches/000*-tb-egpu-*.patch; do
        git apply --check "$p" && git apply "$p" || break
    done

# Rebuild the refactor-rc1 image
cd /root/nvidia-driver-injector
sudo docker build -t apnex/nvidia-driver-injector:refactor-rc1 .

# Roll back to a checkpoint
git -C /root/nvidia-driver-injector reset --hard <commit>

# Read the inventory for the next cluster
sed -n '/^### P3 /,/^### P/p' /root/nvidia-driver-injector/docs/patch-refactor-inventory.md
```

---

## Session log

| Date | Session | Phase | Work |
|---|---|---|---|
| 2026-05-12 | initial | Phase 1 | Inventory doc produced (810 lines) |
| 2026-05-12 | continued | Phase 2 (1/6) | P5 written + committed (b2891e5); naming rename ("Windows" → spec-justified) |
| 2026-05-12 | continued | Phase 2 (2/6) | P1 written + committed (f5d0900); 6 consolidation wins; semantic correction |
| 2026-05-12 | continued | Phase 2 (3/6) | P3 written + committed (a19c1ac); legacy 0023 split — P3 owns S3 storage + sysfs, P2 will own AER-capture helper + call site |
| 2026-05-12 | continued | Phase 2 (3.5/6) | Renumber chore (aacf661): P3 file 0004→0003, P2 reserved as 0004 (correct apply-time dependency direction after Option-1 split) |
| 2026-05-12 | continued | Phase 2 (4/6) | P2 written via subagent + committed (e4cb622); 5 consolidation wins; S2/DIAG-AER2 deferred to P6 (host function lives in legacy 0018 = P6 territory); gate helper takes pdev |
| 2026-05-12 | continued | Phase 2 (5/6) | P4 written + committed (52b43f0); UVM-side helpers moved to new nv-tb-egpu-uvm.{c,h} pair (cohesion win); hardcoded BDF replaced by walker; close_diag uses pdev variant — no P6 dependency |
| 2026-05-12 | continued | Phase 2 (6/6) | P6 written + committed (6d52a06); new nv-tb-egpu-diag.{c,h} pair; reuses 4 P2 helpers via static-to-module-internal promotion; S2/DIAG-AER2 expansion landed; mmio-enabled diag_dump re-introduction landed; legacy 0009 dropped. |
| 2026-05-12 | continued | **Phase 2 ✓** | P7 written + committed (16921cb); NVIDIA_VERSION → aorus.13; version.mk-as-source-of-truth; CONFIG_NV_TB_EGPU_DIAG toggle (default n) with inline no-op stub. **Phase 2 complete — all 7 patches in.** |
| _next_ | resume | Phase 3 | Stack validation: switch live host from legacy aorus.12 to refactor-rc1, run the uninstall/reinstall cycle from docs/install-workflow.md, soak test 24-48h on production vLLM workload, verify counters in /sys/.../tb_egpu_*. If green, promote `refactor-rc1` → `595.71.05-aorus.13` and merge `refactor/p1-p6` to main. |
