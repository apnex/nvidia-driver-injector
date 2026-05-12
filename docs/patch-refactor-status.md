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
| **Phase** | 2 of 5 |
| **Patches landed** | P5 (commit `b2891e5`), P1 (commit `f5d0900`) — 2 of 6 |
| **Patches pending** | P3, P2, P4, P6 + metadata (P7) |
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
patches/0003-tb-egpu-pcie-error-handlers-recover.patch (P2 — apply 3rd; needs P1)
patches/0004-tb-egpu-qwatchdog.patch                   (P3 — apply 4th; needs P2)
patches/0005-tb-egpu-close-path-safety.patch           (P4 — apply 5th; needs P2)
patches/0006-tb-egpu-diag-telemetry.patch              (P6 — apply 6th; Kconfig-gated)
patches/0007-tb-egpu-version-mark-and-kbuild.patch     (build metadata)
```

**File-number = apply order** (kernel patch convention). **Px label = cluster identity**. **Write order ≠ either**: we write smallest-first for confidence (P5 → P1 → P3 → P2 → P4 → P6).

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

### P3 — Q-watchdog Mode B detector (PENDING — write NEXT)

| | |
|---|---|
| Estimated patch file | `patches/0004-tb-egpu-qwatchdog.patch` |
| Legacy source | 0014, 0015 (kthread + sysfs) |
| Estimated final size | ~500 lines |
| Dependencies | P1 (`tb_egpu_check_dead_bus`, `TB_EGPU_LOG_ONCE`) |
| Key changes | kthread name rename `aorus-qwd-<bdf>` → `tb-egpu-qwd-<bdf>`; sysfs attr group consolidation; cross-reference docs/lever-catalog.md |
| Open question | Should sysfs attrs go under `/sys/bus/pci/devices/<bdf>/tb_egpu_qwd_*` (per-attr) or `tb_egpu_qwd/<attr>` (kobj subdir)? Inventory recommends per-attr for simplicity. |

### P2 — PCIe error handlers + Lever M-recover (PENDING — biggest)

| | |
|---|---|
| Estimated patch file | `patches/0003-tb-egpu-pcie-error-handlers-recover.patch` |
| Legacy source | 0007, 0016, 0017, 0024, 0026, 0027, 0028 |
| Estimated final size | ~1,400 lines (largest of all six) |
| Dependencies | P1 (crash-safety guards; recovery state machine needs them) |
| Key changes | State machine consolidation; sysfs `tb_egpu_recover_*` attrs; H1/H2 gate result extraction (inventory item — duplicated between trigger and `nv_pci_error_detected`) |
| Strategy | Delegate to subagent like P1; review carefully due to size + ordering invariants |

### P4 — close-path safety (PENDING)

| | |
|---|---|
| Estimated patch file | `patches/0005-tb-egpu-close-path-safety.patch` |
| Legacy source | parts of 0029, 0030 |
| Estimated final size | ~300 lines |
| Dependencies | P2 (recovery state ref needed) |
| Key changes | Strip the legacy DIAG bits (those go to P6); keep only the close-path mitigation |

### P6 — Diagnostic telemetry surface (PENDING — Kconfig-gated)

| | |
|---|---|
| Estimated patch file | `patches/0006-tb-egpu-diag-telemetry.patch` |
| Legacy source | 0009 (DROP — pure investigation probes), 0018, 0020, 0021, 0023 + diag parts of 0029, 0030 |
| Estimated final size | ~600 lines |
| Dependencies | P2 (telemetry hooks attach to recovery state machine) |
| Gating | `#ifdef CONFIG_NV_TB_EGPU_DIAG` |
| Drop list | Patch 0009 (Lever P-probe) deleted entirely per inventory recommendation (purely investigation-period probes) |

### P7 — version mark + kbuild (PENDING — trivial)

| | |
|---|---|
| Estimated patch file | `patches/0007-tb-egpu-version-mark-and-kbuild.patch` |
| Legacy source | 0005, 0025 |
| Estimated final size | ~16 lines |
| Dependencies | none |
| Strategy | Hand-write at end of Phase 2; combine the two metadata patches into one |

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
3. **P3 sysfs path layout** — pending: per-attr (`tb_egpu_qwd_*`) vs kobj subdir (`tb_egpu_qwd/<attr>`). Lean per-attr per inventory.
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
| _next_ | resume | Phase 2 (3/6) | P3 — Q-watchdog kthread + sysfs |
