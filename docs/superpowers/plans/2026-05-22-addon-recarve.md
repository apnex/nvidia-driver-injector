# Addon Layer Re-carve (A1–A5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Carve the injector's addon layer — five patches `A1`–`A5` in `patches/addon/` — from the legacy P-clusters, so the composed `C+E+A` driver is a full replacement for the running `595.71.05-aorus.13` container.

**Architecture:** The addon layer is carved as a fork **branch stack** (`a1`…`a5` on `apnex/open-gpu-kernel-modules`, on top of the C/E stack), exactly like the base layer. `regen-base-patches.sh` exports each checkpoint to `patches/addon/`. A `pcie-primitives` foundation patch is extracted from cluster P2; the concentrated `[DIAG]` patch (old A4 / P6) is dissolved in favour of per-patch nominal telemetry.

**Tech Stack:** Bash, git, GNU make, the NVIDIA `open-gpu-kernel-modules` build.

---

## Context & scope

Implements `docs/superpowers/specs/2026-05-22-addon-recarve-design.md` — **read that spec first**. It also depends on understanding the base layer (`docs/superpowers/specs/2026-05-22-dynamic-patch-composition-design.md`).

**Two repositories are involved:**
- **Injector repo** — `/root/nvidia-driver-injector`, branch `migration/addon-recarve`. Holds `patches/`, `tools/`, `manifest`, docs.
- **Fork repo** — `/root/open-gpu-kernel-modules`. Holds the C/E/A patch *stack* as branches. Current stack tip: `c5-crash-safety` = `vanilla 595.71.05 + C1–C5 + E1`.

**Source material:** the legacy P-clusters in `patches/legacy/` —
`0003` (P3 → A2 watchdog), `0004` (P2 → A1 foundation + A3 recovery),
`0005` (P4 → A4 close-path), `0007` (P7 → A5 version). `0006` (P6) is **not
carved** — it is dissolved per the design.

**Delivered here:** the five addon patches, the `regen`/`manifest`/`manifest_lint`
changes, the verification, and the existing-doc reconciliation.

**Out of scope:** image rebuild (`aorus.14`), the ≥14-day soak, cutover.

## File structure

**Fork repo — new source files** (carried by the addon patches):
| File | Patch | Responsibility |
|---|---|---|
| `kernel-open/nvidia/nv-tb-egpu-pcie.{c,h}` | A1 | Shared PCIe/AER/WPR2 register-read primitives |
| `kernel-open/nvidia/nv-tb-egpu-qwd.{c,h}` | A2 | Bus-loss watchdog kthread + sysfs |
| `kernel-open/nvidia/nv-tb-egpu-recover.{c,h}` | A3 | Recovery state machine + policy |
| `kernel-open/nvidia/nv-tb-egpu-close.{c,h}` | A4 | RM-side close-path telemetry |
| `kernel-open/nvidia-uvm/nv-tb-egpu-uvm.{c,h}` | A4 | UVM-side close-path telemetry |

**Injector repo:**
| File | Action |
|---|---|
| `patches/addon/A1-pcie-primitives.patch` … `A5-version-and-toggles.patch` | created by `regen` (Task 10) |
| `patches/manifest` | +5 addon rows (Task 9) |
| `tools/lib/manifest.sh` | relax source lint (Task 1) |
| `tests/test-manifest-lib.sh` | update source-lint tests (Task 1) |
| `tools/regen-base-patches.sh` | handle addon rows (Task 2) |
| `docs/upstream-plan.md`, `docs/patches.md`, `docs/production-migration.md`, `docs/superpowers/specs/2026-05-22-dynamic-patch-composition-design.md` | reconcile (Task 13) |

---

# Phase 1 — Tooling

## Task 1: Relax `manifest_lint` to accept `fork:*` on all rows

The base layer carved `addon` rows to require `source: injector`. The design moves the addon layer onto the fork stack, so every row's source is now `fork:<branch>`. Make `manifest_lint` require `fork:*` for *all* rows, drop the per-layer source rule.

**Files:**
- Modify: `tools/lib/manifest.sh`
- Modify: `tests/test-manifest-lib.sh`

- [ ] **Step 1: Update the tests first**

In `tests/test-manifest-lib.sh`, find the two source-lint test blocks. Replace the block that currently reads (the addon-fork-source rejection):

```bash
# manifest_lint rejects an addon row whose source is not 'injector'
printf '  A1-a  addon  -  fork:a1\n' > "$d/addon-bad-src"
manifest_lint "$d/addon-bad-src" 2>/dev/null
assert_eq "$?" "1" "manifest_lint rejects an addon row with a fork source"
```

with:

```bash
# manifest_lint accepts an addon row with a fork:<branch> source
printf '  A1-a  addon  -  fork:a1\n' > "$d/addon-fork-src"
manifest_lint "$d/addon-fork-src" 2>/dev/null
assert_eq "$?" "0" "manifest_lint accepts an addon row with a fork source"
```

And replace the block that currently reads (the `injector`-source acceptance):

```bash
# manifest_lint accepts a well-formed addon row
printf '  A1-a  addon  -  injector\n' > "$d/addon-ok"
manifest_lint "$d/addon-ok" 2>/dev/null
assert_eq "$?" "0" "manifest_lint accepts a well-formed addon row"
```

with:

```bash
# manifest_lint rejects any row whose source is not fork:<branch>
printf '  A1-a  addon  -  injector\n' > "$d/non-fork-src"
manifest_lint "$d/non-fork-src" 2>/dev/null
assert_eq "$?" "1" "manifest_lint rejects a non-fork source"
```

- [ ] **Step 2: Run the tests, confirm the two changed cases now FAIL**

Run: `cd /root/nvidia-driver-injector && bash tests/test-manifest-lib.sh`
Expected: `10 run, 2 failed` — the two changed assertions fail against the old `manifest.sh` (old code rejects addon+fork and accepts addon+injector).

- [ ] **Step 3: Relax the lint rule**

In `tools/lib/manifest.sh`, inside `manifest_lint`, find the `case "$layer:$src"` block:

```bash
        case "$layer:$src" in
            base:fork:*)    ;;
            addon:injector) ;;
            base:*)  echo "manifest: row '$id': base row needs a fork:<branch> source, got '$src'" >&2; rc=1 ;;
            addon:*) echo "manifest: row '$id': addon row needs source 'injector', got '$src'" >&2; rc=1 ;;
        esac
```

Replace it with a layer-agnostic `fork:*` requirement:

```bash
        case "$src" in
            fork:*) ;;
            *) echo "manifest: row '$id': source must be fork:<branch>, got '$src'" >&2; rc=1 ;;
        esac
```

- [ ] **Step 4: Run tests, confirm all pass**

Run: `cd /root/nvidia-driver-injector && bash tests/run.sh; echo "exit=$?"`
Expected: `test-manifest-lib.sh: 10 run, 0 failed`, `test-compose.sh: 8 run, 0 failed`, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add tools/lib/manifest.sh tests/test-manifest-lib.sh
git commit -m "$(printf 'feat: manifest_lint requires fork:<branch> source on all rows\n\nThe addon layer moves onto the fork stack; addon rows are now\nfork:a* like base rows.\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"
```

---

## Task 2: Extend `regen-base-patches.sh` to export the addon layer

`regen` currently skips non-`base` rows (`[ "$layer" = "base" ] || continue`). Make it process every row, exporting to `patches/<layer>/<id>.patch`. The fork checkpoint chain continues unbroken across the base→addon boundary (`a1`'s previous checkpoint is `c5`, `a2`'s is `a1`, …).

**Files:**
- Modify: `tools/regen-base-patches.sh`

- [ ] **Step 1: Make the row loop layer-agnostic**

In `tools/regen-base-patches.sh`, the row loop currently begins:

```bash
while read -r id layer up src; do
    [ "$layer" = "base" ] || continue
    [ "$up" = "-" ] || continue          # upstreamed: nothing to generate
```

Replace those lines with:

```bash
while read -r id layer up src; do
    case "$layer" in base|addon) ;; *) continue ;; esac
    [ "$up" = "-" ] || continue          # upstreamed: nothing to generate
```

- [ ] **Step 2: Write each patch to its layer directory**

Still in the loop, `out` is currently:

```bash
    out="$base_dir/$id.patch"
```

Replace with:

```bash
    out="$repo_root/patches/$layer/$id.patch"
    mkdir -p "$repo_root/patches/$layer"
```

And the progress/state lines that reference `$base_dir` — change the `echo "regen: wrote ${out#$repo_root/} ..."` to use `${out#$repo_root/}` as before (it already prints the relative path, so it now naturally prints `patches/addon/...` for addon rows — no change needed). The `.regen-state` file: keep it at `$base_dir/.regen-state` (`patches/base/.regen-state`) — it records the whole stack's checkpoint SHAs in row order, base and addon together; that single file remains the provenance record.

- [ ] **Step 3: Verify regen still reproduces the base layer unchanged**

Run (the addon manifest rows do not exist yet, so this regenerates only base):
```bash
cd /root/nvidia-driver-injector
sha256sum patches/base/*.patch | sort > /tmp/base-before
tools/regen-base-patches.sh >/dev/null
sha256sum patches/base/*.patch | sort > /tmp/base-after
diff /tmp/base-before /tmp/base-after && echo "BASE UNCHANGED"
git checkout -- patches/base/.regen-state
```
Expected: `BASE UNCHANGED` — the layer-agnostic loop still produces byte-identical base patches.

- [ ] **Step 4: Commit**

```bash
git add tools/regen-base-patches.sh
git commit -m "$(printf 'feat: regen exports the addon layer as well as base\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"
```

---

# Phase 2 — The carve (fork repo)

All Phase 2 tasks work in the **fork repo** `/root/open-gpu-kernel-modules`. Each carves one commit onto the stack and **must compile-check** before commit, per the project rule that `git apply --check` is not validation.

**Compile-check procedure** (used by every Phase 2 task — `KVER` is the host kernel `7.0.9-204.fc44`):
```bash
cd /root/open-gpu-kernel-modules
make modules SYSSRC="/lib/modules/$(uname -r)/build" -j"$(nproc)" IGNORE_CC_MISMATCH=1 > /tmp/carve-build.log 2>&1 \
  && echo "COMPILE OK" || { echo "COMPILE FAILED"; tail -40 /tmp/carve-build.log; }
git clean -fdx >/dev/null 2>&1   # drop build artifacts before checkout/commit
```

## Task 3: Carve A1 — `pcie-primitives` foundation

Extract the shared register-read primitives out of cluster P2 (`patches/legacy/0004`) into their own new files, as a fork branch on top of `c5-crash-safety`.

**Files (in the fork):**
- Create: `kernel-open/nvidia/nv-tb-egpu-pcie.c`, `nv-tb-egpu-pcie.h`
- Modify: `kernel-open/nvidia/nvidia-sources.Kbuild` (+1 line)

- [ ] **Step 1: Branch off the stack tip**

```bash
cd /root/open-gpu-kernel-modules
git checkout c5-crash-safety
git checkout -b a1-pcie-primitives
```

- [ ] **Step 2: Identify the foundation primitives in `patches/legacy/0004`**

Read `/root/nvidia-driver-injector/patches/legacy/0004-tb-egpu-pcie-error-handlers-recover.patch`. The foundation = these functions and the constants/types they need, currently defined in that patch's `nv-tb-egpu-recover.c`:
- `tb_egpu_recover_read_wpr2`
- `tb_egpu_recover_walk_to_root_port`
- `tb_egpu_recover_read_dpc_state`
- `tb_egpu_recover_read_aer_full`
- `tb_egpu_dump_aer_trigger_event`
- supporting: `TB_EGPU_RECOVER_WPR2_REG_OFFSET`, `TB_EGPU_RECOVER_WPR2_VAL_MASK`, and the AER-snapshot struct/typedef these use.

These are *pure register/config-space reads* — no recovery-state coupling. Keep the function names unchanged (renaming is deliberately out of scope — it multiplies caller churn and carve risk).

- [ ] **Step 3: Create the foundation files**

Create `kernel-open/nvidia/nv-tb-egpu-pcie.c` containing the function bodies above (copied verbatim from `legacy/0004`'s `nv-tb-egpu-recover.c`) plus the `#include`s they need. Create `nv-tb-egpu-pcie.h` with the matching declarations + the constants/struct. Add `NVIDIA_SOURCES += nvidia/nv-tb-egpu-pcie.c` to `kernel-open/nvidia/nvidia-sources.Kbuild`.

- [ ] **Step 4: Compile-check**

Run the compile-check procedure. Expected: `COMPILE OK`. (A1's functions are non-static and header-declared, so no `unused-function` warning fires even though no caller exists yet.)

- [ ] **Step 5: Commit the checkpoint**

```bash
cd /root/open-gpu-kernel-modules
git add -A
git commit -m "tb-egpu: shared PCIe/AER register-read primitives (A1)"
```

---

## Task 4: Carve A2 — `bus-loss-watchdog`

Cluster P3 (`patches/legacy/0003`) is wholly additive and applies on top of the stack. Carve it as `a2`, then run the observability audit.

**Files (in the fork):** per `legacy/0003` — `nv-tb-egpu-qwd.{c,h}` (new), `nv-linux.h` (+`qwd` field), `nv-pci.c` (probe/remove wire-in), `nvidia-sources.Kbuild` (+1).

- [ ] **Step 1: Branch and apply P3**

```bash
cd /root/open-gpu-kernel-modules
git checkout a1-pcie-primitives
git checkout -b a2-bus-loss-watchdog
git apply --check /root/nvidia-driver-injector/patches/legacy/0003-tb-egpu-qwatchdog.patch \
  && git apply /root/nvidia-driver-injector/patches/legacy/0003-tb-egpu-qwatchdog.patch
```
If `--check` fails, the base layer drifted P3's context — resolve by hand-applying the failing hunks (they will be small wire-in hunks in `nv-pci.c`/`nv-linux.h`); do not skip any.

- [ ] **Step 2: Re-point the watchdog's AER call at the foundation**

`legacy/0003` calls `tb_egpu_dump_aer_trigger_event` (now in A1's `nv-tb-egpu-pcie.h`, not in `recover.h`). In `nv-tb-egpu-qwd.c`, ensure the `#include` for that helper points at `"nv-tb-egpu-pcie.h"`. (Pre-foundation, P3 expected this symbol from the recovery cluster; A1 now owns it.)

- [ ] **Step 3: Compile-check** — run the procedure. Expected: `COMPILE OK`.

- [ ] **Step 4: Observability audit**

Per the design's Observability audit: A2's Telemetry contract is "log on a detection event; `tb_egpu_qwd_*` sysfs; no per-poll logging." Verify in `nv-tb-egpu-qwd.c`: the 5 Hz poll loop must NOT log per cycle; a log line fires only on a dead-bus detection. Trim any per-cycle or debug-level spam. The five `tb_egpu_qwd_*` sysfs attributes stay.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "tb-egpu: bus-loss watchdog (A2)"
```

---

## Task 5: Carve A3 — `recovery`

The hard task. Cluster P2 (`patches/legacy/0004`) minus the A1 primitives, minus the `C4` err-handler *registration* that the base layer already carries. P2 patched *vanilla* `nv-pci.c`; the base's `C4` already added the `pci_error_handlers` struct + four **stub** callbacks — so A3's `nv-pci.c` change is a **delta over C4**, not a re-add.

**Files (in the fork):** `nv-tb-egpu-recover.{c,h}` (new — state machine only), `nv-pci.c` (replace C4's stub bodies), `nv-linux.h` (+`recover` field), `nv.c` (post-rmInit hooks), `nvidia-sources.Kbuild` (+1).

- [ ] **Step 1: Branch**

```bash
cd /root/open-gpu-kernel-modules
git checkout a2-bus-loss-watchdog
git checkout -b a3-recovery
```

- [ ] **Step 2: Apply the non-`nv-pci.c`, non-primitive parts of P2**

From `patches/legacy/0004`, apply to the working tree everything EXCEPT (a) the foundation primitives (already in A1 — do not re-create them) and (b) the `nv-pci.c` hunks. Concretely: create `nv-tb-egpu-recover.{c,h}` containing the recovery state machine **without** the five A1 functions; have `nv-tb-egpu-recover.c` `#include "nv-tb-egpu-pcie.h"` for them. Apply P2's `nv-linux.h` (`recover` field), `nv.c` (post-rmInit-FAIL/OK hooks), the `nv-tb-egpu-qwd.c` wire-in, and `nvidia-sources.Kbuild` (+`nv-tb-egpu-recover.c`).

- [ ] **Step 3: Re-express the `nv-pci.c` hunk as a delta over C4**

Inspect `kernel-open/nvidia/nv-pci.c` on this branch — it already has `C4`'s four stub callbacks (`nv_pci_error_detected`, `nv_pci_mmio_enabled`, `nv_pci_slot_reset`, `nv_pci_resume`) and the `nv_pci_err_handlers` struct with `.err_handler` wired into `nv_pci_driver`. From `legacy/0004`, take the **real** callback bodies and:
- **Replace** each of C4's four stub bodies with P2's real body (`error_detected` → the gate-aware recovery logic; `mmio_enabled`, `slot_reset`, `resume` → the real dispatchers).
- **Add** `nv_pci_cor_error_detected` (new — not in C4).
- **Add** `.cor_error_detected = nv_pci_cor_error_detected` to the existing `nv_pci_err_handlers` struct.
- Do **NOT** re-add the struct definition or the `.err_handler =` wiring — C4 already has them.

- [ ] **Step 4: Compile-check** — run the procedure. Expected: `COMPILE OK`.

- [ ] **Step 5: Observability audit**

A3's Telemetry contract (mandatory, `C3` rationale — recovery is invisible otherwise): verify A3 logs every recovery **fire**, **gate decision** (OK / disabled / rate-limited / surrender), and **outcome** (success / permanent-fail), at `dev_warn`/`dev_info` levels. Keep the `tb_egpu_recover_*` sysfs and the `TB_EGPU_GPU_STATE` uevent. Confirm no investigation-grade register dumps remain in the recovery path.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "tb-egpu: self-triggered recovery state machine (A3)"
```

---

## Task 6: Carve A4 — `close-path-telemetry`

Cluster P4 (`patches/legacy/0005`), **re-scoped to nominal telemetry** per the design — and given its own RM-side file instead of appending into `recover.c`.

**Files (in the fork):** `nv-tb-egpu-close.{c,h}` (new — A4's RM-side functions), `nv-tb-egpu-uvm.{c,h}` (new, UVM side, per `legacy/0005`), `nv.c` + `uvm.c` (close/open/release sites), the two `*-sources.Kbuild` files (+1 each).

- [ ] **Step 1: Branch**

```bash
cd /root/open-gpu-kernel-modules
git checkout a3-recovery
git checkout -b a4-close-path-telemetry
```

- [ ] **Step 2: Apply P4 into its own RM-side file**

`legacy/0005` appends its RM-side functions (`tb_egpu_close_diag`, `tb_egpu_close_diag_pdev`, `tb_egpu_get_gpu_pdev`) into `nv-tb-egpu-recover.c`. Instead, place them in a **new** `kernel-open/nvidia/nv-tb-egpu-close.{c,h}`, add it to `nvidia-sources.Kbuild`, and `#include "nv-tb-egpu-close.h"` at the `nv.c` call sites. Apply P4's UVM-side files (`nv-tb-egpu-uvm.{c,h}`, `uvm.c` sites, the UVM Kbuild) as-is. Any AER/WPR2 reads use A1's `nv-tb-egpu-pcie.h`.

- [ ] **Step 3: Observability audit — re-scope to nominal**

Per the design: A4 is *event-triggered nominal* telemetry. Audit `legacy/0005`'s logging:
- **Keep:** a single log line on the meaningful **last-close transition** (usage_count→0 / fd_count returning from 0).
- **Trim:** the multi-register full-state dump (`PMC_BOOT_0` + `WPR2` + `LnkSta` + `AER`-on-GPU-and-bridge) on every close — reduce to the nominal last-close line plus, at most, `PMC_BOOT_0` and a one-word health verdict. Drop the per-site `[UVM-DIAG]`-style verbose markers.
- When uncertain whether something is nominal, keep less. The bar is the C/E telemetry standard in the design.

- [ ] **Step 4: Compile-check** — run the procedure. Expected: `COMPILE OK`. (UVM is a separate module; the build covers both.)

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "tb-egpu: close-path nominal telemetry (A4)"
```

---

## Task 7: Carve A5 — `version-and-toggles`

Cluster P7's addon half (`patches/legacy/0007`), minus the `CONFIG_NV_TB_EGPU_DIAG` toggle (A4-DIAG is dissolved).

**Files (in the fork):** `version.mk`, `kernel-open/Kbuild`.

- [ ] **Step 1: Branch**

```bash
cd /root/open-gpu-kernel-modules
git checkout a4-close-path-telemetry
git checkout -b a5-version-and-toggles
```

- [ ] **Step 2: Apply the A5 half of P7**

From `legacy/0007`, apply only:
- `version.mk` — set `NVIDIA_VERSION = 595.71.05-aorus.14`.
- `kernel-open/Kbuild` — the `CONFIG_NV_TB_EGPU ?= y` master toggle and its `ccflags-y += -DCONFIG_NV_TB_EGPU` block, sitting on top of `C1`'s `include $(src)/../version.mk` line (already present from the base layer).

Do **NOT** apply: the `CONFIG_NV_TB_EGPU_DIAG` toggle, the `nv-tb-egpu-diag.h` `#ifdef`, or the `nvidia-sources.Kbuild` conditional for `nv-tb-egpu-diag.c` — all belonged to the dissolved DIAG patch.

- [ ] **Step 3: Compile-check** — run the procedure. Expected: `COMPILE OK`, and the built `nvidia.ko` reports `595.71.05-aorus.14` (`modinfo` on the freshly built module, or check `NV_VERSION_STRING`).

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "tb-egpu: version value + CONFIG_NV_TB_EGPU toggle (A5)"
```

---

## Task 8: Push the addon branches to the fork origin

The base branches `c1`…`e1` live on the fork's `origin`; the addon branches join them as durable storage of the carve.

- [ ] **Step 1: Push**

```bash
cd /root/open-gpu-kernel-modules
for b in a1-pcie-primitives a2-bus-loss-watchdog a3-recovery a4-close-path-telemetry a5-version-and-toggles; do
    git push -u origin "$b"
done
```
Expected: five branches pushed (or "Everything up-to-date" if a re-run).

- [ ] **Step 2: Verify the stack topology**

```bash
cd /root/open-gpu-kernel-modules
git merge-base --is-ancestor c5-crash-safety a1-pcie-primitives && \
git merge-base --is-ancestor a1-pcie-primitives a2-bus-loss-watchdog && \
git merge-base --is-ancestor a2-bus-loss-watchdog a3-recovery && \
git merge-base --is-ancestor a3-recovery a4-close-path-telemetry && \
git merge-base --is-ancestor a4-close-path-telemetry a5-version-and-toggles && \
echo "STACK ORDER OK"
```
Expected: `STACK ORDER OK` — the addon stack sits cleanly on `c5` in order. (No injector-repo commit in this task.)

---

# Phase 3 — Compose & verify (injector repo)

All Phase 3 tasks: `cd /root/nvidia-driver-injector`, branch `migration/addon-recarve`.

## Task 9: Add the five addon rows to the manifest

**Files:** Modify `patches/manifest`.

- [ ] **Step 1: Append the addon rows**

Append to `patches/manifest`, after the `C5-crash-safety` row, in stack order:

```
  A1-pcie-primitives         addon  -              fork:a1-pcie-primitives
  A2-bus-loss-watchdog       addon  -              fork:a2-bus-loss-watchdog
  A3-recovery                addon  -              fork:a3-recovery
  A4-close-path-telemetry    addon  -              fork:a4-close-path-telemetry
  A5-version-and-toggles     addon  -              fork:a5-version-and-toggles
```

- [ ] **Step 2: Verify the manifest lints clean**

Run:
```bash
cd /root/nvidia-driver-injector
bash -c '. tools/lib/manifest.sh && manifest_lint patches/manifest && echo LINT_OK'
```
Expected: `LINT_OK` (11 rows: 6 base + 5 addon, all `fork:*`).

- [ ] **Step 3: Commit**

```bash
git add patches/manifest
git commit -m "$(printf 'feat: add the five addon rows to the patch manifest\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"
```

---

## Task 10: Generate `patches/addon/`

**Files:** created (generated) — `patches/addon/A1-pcie-primitives.patch` … `A5-version-and-toggles.patch`.

- [ ] **Step 1: Run regen**

```bash
cd /root/nvidia-driver-injector
tools/regen-base-patches.sh
```
Expected: regen now writes eleven patches — six `patches/base/*` (unchanged) and five `patches/addon/*` — then runs `validate-patchset.sh` (Task 11's gate runs automatically here).

- [ ] **Step 2: Verify compose accepts the full set**

```bash
cd /root/nvidia-driver-injector
tools/compose-patchset.sh --patches-dir patches | wc -l
```
Expected: `11` (6 base + 5 addon, in manifest order).

- [ ] **Step 3: Verify regen idempotence**

```bash
cd /root/nvidia-driver-injector
sha256sum patches/base/*.patch patches/addon/*.patch | sort > /tmp/all-before
tools/regen-base-patches.sh >/dev/null
sha256sum patches/base/*.patch patches/addon/*.patch | sort > /tmp/all-after
diff /tmp/all-before /tmp/all-after && echo "IDEMPOTENT"
```
Expected: `IDEMPOTENT`.

- [ ] **Step 4: Commit the generated addon patches**

```bash
cd /root/nvidia-driver-injector
git add patches/addon/ patches/base/.regen-state
git commit -m "$(printf 'feat: generate patches/addon from the fork addon stack\n\nFive addon patches (A1-A5) exported from apnex/open-gpu-kernel-modules.\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"
```

---

## Task 11: Compile gate — full C+E+A

**Files:** none (verification).

- [ ] **Step 1: Run the compile gate**

```bash
cd /root/nvidia-driver-injector
tools/validate-patchset.sh
```
Expected: `validate: OK -- composed patch set compiles against kernel 7.0.9-204.fc44` — the full `vanilla + C1–C5 + E1 + A1–A5` set applies and `make modules` succeeds.

If it fails, the failure is in the carve — capture the build-log tail, identify the offending patch, and STOP; report it (do not edit generated patches to force green).

---

## Task 12: Behavioural-equivalence verification + telemetry sign-off

Prove the composed `C+E+A` driver is functionally the running `aorus.13` driver, modulo the *intended* changes.

**Files:** none (verification).

- [ ] **Step 1: Build both source trees**

```bash
cd /tmp && rm -rf cea p1p7
git -C /root/open-gpu-kernel-modules worktree add /tmp/cea a5-version-and-toggles
git -C /root/open-gpu-kernel-modules worktree add --detach /tmp/p1p7 595.71.05
cd /tmp/p1p7 && for p in /root/nvidia-driver-injector/patches/legacy/000{1,2,3,4,5,6,7}-*.patch; do git apply "$p"; done
```
`/tmp/cea` = the composed C+E+A tree (the `a5` fork tip). `/tmp/p1p7` = vanilla + the legacy P1–P7 set.

- [ ] **Step 2: Diff the addon-relevant files**

```bash
for f in kernel-open/nvidia/nv-pci.c kernel-open/nvidia/nv.c \
         kernel-open/common/inc/nv-linux.h kernel-open/nvidia-uvm/uvm.c; do
    echo "=== $f ==="; diff -u "/tmp/p1p7/$f" "/tmp/cea/$f" || true
done
```

- [ ] **Step 3: Classify every difference**

Every hunk of difference must fall into an **explainable bucket** — write down which, for each:
- base **de-branding** (`tb_egpu_*` → neutral names in the C/E layer);
- **E1**'s eGPU-detection rewrite;
- the **A1 foundation code-motion** (primitives in `nv-tb-egpu-pcie.c`, not `recover.c`);
- **P6/`[DIAG]` dissolution** — P6's `tb_egpu_diag_dump` call sites present in `/tmp/p1p7`, absent in `/tmp/cea`;
- **nominal-telemetry trims** in A2/A4 from the observability audit.

Any difference that fits **none** of these buckets is a carve bug — STOP and report it.

- [ ] **Step 4: Telemetry sign-off**

Confirm each runtime addon patch meets its Telemetry contract (design §Observability audit): A2 logs detections only (no per-poll spam); A3 logs every fire/gate/outcome; A4 logs the last-close transition nominally. Record the verdict.

- [ ] **Step 5: Clean up worktrees**

```bash
git -C /root/open-gpu-kernel-modules worktree remove --force /tmp/cea
git -C /root/open-gpu-kernel-modules worktree remove --force /tmp/p1p7
git -C /root/open-gpu-kernel-modules worktree prune
```

No commit — verification only. If Steps 3–4 surface an unexplained difference or a telemetry gap, that is a blocker.

---

# Phase 4 — Documentation

## Task 13: Reconcile the existing docs

Bring the four stale docs in line with the carved addon layer.

**Files:** Modify `docs/upstream-plan.md`, `docs/patches.md`, `docs/production-migration.md`, `docs/superpowers/specs/2026-05-22-dynamic-patch-composition-design.md`.

- [ ] **Step 1: `upstream-plan.md` — the "Addon layer — A" section**

Renumber to the new `A1`–`A5`: `A1` `pcie-primitives` (new, foundation — carved from P2); `A2` watchdog; `A3` recovery; `A4` close-path; `A5` version+toggles. Mark the old `A4` DIAG / cluster P6 **dissolved** (per-patch nominal telemetry replaces it; `legacy/0006` preserved as resurrection source). Add the per-patch nominal-telemetry duty. The C/E sections are unaffected.

- [ ] **Step 2: `patches.md` — per-cluster geometry + final table**

Update each "Upstream geometry" block and the final C/E/A table: P3 → `A2`; **P2 → `C4` + `A1` + `A3`** (three-way — the foundation primitives are `A1`); P4 → `A4`; **P6 → dissolved** (note `legacy/0006` retained, not carved); P7 → `C1` + `A5`. Update the "watchdog and recovery (A1/A2)" sentence to the new numbering.

- [ ] **Step 2b: Run a stale-reference scan**

```bash
cd /root/nvidia-driver-injector
grep -rn -E '\bA[1-5]\b' docs/upstream-plan.md docs/patches.md docs/production-migration.md
```
Inspect each hit — confirm every `A`-number reference uses the new meaning. Fix any missed.

- [ ] **Step 3: `production-migration.md` + the dynamic-patch-composition design**

In `production-migration.md`, update §3 to point at `docs/superpowers/specs/2026-05-22-addon-recarve-design.md` and note the foundation extraction + P6 dissolution. In `2026-05-22-dynamic-patch-composition-design.md`, change the addon-delivery statement from "hand-authored, `source: injector`" to "fork-carved, `source: fork:a*`", and update the manifest section's `addon` source rule.

- [ ] **Step 4: Verify nothing else broke + commit**

```bash
cd /root/nvidia-driver-injector
bash tests/run.sh && tools/compose-patchset.sh --patches-dir patches | wc -l
git add docs/
git commit -m "$(printf 'docs: reconcile upstream-plan/patches/migration with the carved addon layer\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"
```
Expected: tests pass, compose emits `11`.

---

## Done — definition of complete

- `manifest_lint` requires `fork:*` on all rows; `regen` exports base + addon.
- Five fork branches `a1`…`a5` carved, compiled, pushed; the addon stack sits cleanly on `c5`.
- `patches/manifest` has 11 rows; `patches/addon/` holds 5 generated patches; `regen` idempotent.
- `validate-patchset.sh` compiles the full C+E+A set against kernel 7.0.9.
- Behavioural-equivalence diff vs P1–P7 fully explained; telemetry sign-off recorded.
- The four stale docs reconciled.

## Follow-on (not this plan)

`production-migration.md` steps 5–8 — rebuild the image to `595.71.05-aorus.14`, the ≥14-day soak, cutover, and (separately gated) the upstream PRs. The `regen` tag-bump rebase path remains a deferred follow-on.
