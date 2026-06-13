# A3 BAR-aware recovery hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Kernel-module adaptation of TDD:** the A3 recover path cannot be unit-tested (out-of-tree kernel C, recovery only fires on real broken hardware). The per-task "test" is a **real `make modules` compile** against the running kernel tree (per [[feedback-compile-validation-not-apply-check]]) plus a static diff assertion. The **behavioural** verdict is the operator-gated live wet run. Do NOT claim the hardening "works" from a clean compile alone.

**Goal:** Make the A3 in-driver recovery state machine BAR-aware — never falsely declare a broken-BAR1 (256 MiB) chip `RECOVERED`, never retry it into a wedge — and route its broken-BAR1 recovery down whichever mechanism E2-verify proves optimal: an **in-kernel light reset** (Branch A) or a **userspace `fix-bar1` escalation** (Branch B).

**Architecture:** Two phases. **Phase 0 (architecture-independent, do regardless):** add a ReBAR-size read primitive to the A1 foundation and make A3's `slot_reset` RECOVERED gate BAR-aware (CTRL-at-max **and** BAR1-window-full, else DISCONNECT). **Phase 1 (mechanism, set by E2-verify):** either fold the E27 resize+FLR+verify light reset *into* A3 so broken-BAR1 is recovered in-kernel (Branch A, retires `fix-bar1`), or escalate broken-BAR1 to an auto-triggered `fix-bar1` slot-cycle (Branch B). Edits land in stacked fork branches `a1-pcie-primitives` / `a3-recovery`; the addon stack `a4…a14` rebases unchanged; an `a5` version bump produces **apnex.34**.

**Tech Stack:** C (Linux kernel module, NVIDIA open-gpu-kernel-modules fork), out-of-tree `kernel-open` build against `7.0.9-204.fc44`, `tools/regen-base-patches.sh` (stacked series → `patches/addon/*.patch`), the injector container build for the production module.

---

## The decision fork (set by E2-verify)

The unified end goal is **in-driver recovery that retires `tools/fix-bar1.sh`**. The single unanswered question that fixes A3's architecture is: *can a broken-BAR1 be recovered in-kernel deterministically (resize+FLR+verify), or does it need the userspace slot-cycle/PERST?* **E2-verify measures exactly that**, and also validates + parameterizes the resize+FLR+verify mechanism itself. So E2-verify is the architectural decision point — run it first, then build A3 to the answer:

| | **Branch A — FLR+verify deterministic** | **Branch B — FLR+verify flaky** |
|---|---|---|
| A3's broken-BAR1 action | **in-kernel light reset** (port the validated E27 mechanism into A3's work handler), escalate to userspace only on failure | **escalate** to a udev/boltd-triggered `fix-bar1` slot-cycle |
| `fix-bar1` | retired (last-resort fallback only) | retained, auto-fired |
| Phase 0 (safety gate) | **identical** | **identical** |

Phase 0 is **common to both branches** and is grounded today (deterministic ReBAR-CTRL + BAR1-`resource_len` checks), so it is fully specified below. Phase 1's detailed code collapses to one branch once E2-verify reports; Branch A's exact port is intentionally left at design level here because its specifics (settle/verify params, re-drive-rm_init path) come from the E2-verify run.

---

## Why (hypothesis + root cause)

**Bug (source-confirmed, `patches/addon/A3-recovery.patch`):** `tb_egpu_recover_slot_reset()` declares `PCI_ERS_RESULT_RECOVERED` whenever `PMC_BOOT_0 != 0xffffffff` — a **BAR0-only** read. `PMC_BOOT_0` is in BAR0 (the register aperture), which reads sane even when the framebuffer BAR1/BAR2 apertures are desynced. So on a broken-256M chip (TB hot-add reset chip ReBAR CTRL `0xf→0x8`), `slot_reset` returns RECOVERED, `resume` bumps `success_count` + emits `READY`, and the next `rm_init_adapter` retry hits `kbusVerifyBar2` garbage → `RmInitAdapter 0x24:0x72:1307`; repeated MMIO on the desynced aperture is the E1 wedge / E2-cycle-2 platform-reset escalation.

This is the **same blind spot** E27's verify-before-bind gate characterized (see `finding-2026-06-13-E27-halfb-determinism-verdict.md`, 2026-06-14): BAR0/boot0 can't see a large-aperture desync. **Why a bus reset can't fix it:** A3's own `pci_reset_bus` (SBR) was proven NOT to relatch a 256 M→32 G ReBAR *size* (A3-CHECK 2026-06-13) — only a slot-cycle/PERST or a clean FLR-before-init relatches a size. So a broken-BAR1 is out of scope for SBR recovery and must be handled by the mechanism E2-verify selects.

**Payoff:** with Phase 0 + the selected Phase 1 in place, `NVreg_TbEgpuRecoverEnable` can stay **1** in production without the broken-BAR1 wedge — closing the reason E27 experiments must run `recover=0`.

---

## File structure

**Fork repo `/root/open-gpu-kernel-modules`:**
- `kernel-open/nvidia/nv-tb-egpu-pcie.{c,h}` (branch `a1-pcie-primitives`) — add `tb_egpu_pcie_read_rebar_size()`. (Branch A may add more shared primitives here — release-siblings/resize/FLR/verify — TBD post-E2-verify.)
- `kernel-open/nvidia/nv-tb-egpu-recover.c` (branch `a3-recovery`) — BAR-aware `slot_reset` gate (Phase 0) + the Phase-1 broken-BAR1 action.

**Injector repo `/root/nvidia-driver-injector` (regenerated, not hand-edited):**
- `patches/addon/A1…A14.patch` via `tools/regen-base-patches.sh`; `experiment-register.md` + finding updates.

**Cascade scope:** branches above `a3-recovery` (`a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14`) rebase with no content change; `a5-version-and-toggles` gets the apnex.34 bump.

---

# PHASE 0 — architecture-independent safety core (do regardless of branch)

## Task 1: A1 primitive — `tb_egpu_pcie_read_rebar_size`

**Files:**
- Modify: `/root/open-gpu-kernel-modules/kernel-open/nvidia/nv-tb-egpu-pcie.c` (branch `a1-pcie-primitives`)
- Modify: `/root/open-gpu-kernel-modules/kernel-open/nvidia/nv-tb-egpu-pcie.h` (same branch)

- [ ] **Step 1: Check out the fork branch**

```bash
cd /root/open-gpu-kernel-modules
git checkout a1-pcie-primitives
git log --oneline -1   # note the tip for regen provenance
```

- [ ] **Step 2: Add the implementation** to `nv-tb-egpu-pcie.c`, after `tb_egpu_pcie_read_wpr2()` (match its style: config-space, no mutation).

```c
/*
 * Read the GPU's Physical Resizable BAR (ReBAR) capability for BAR1 and
 * report both the current size encoding (CTRL register) and the maximum
 * the chip supports (CAP register supported-size bitmap). The encoding is
 * the power-of-two exponent minus 20: enc=15 => 2^35 = 32 GiB, enc=8 =>
 * 2^28 = 256 MiB. A TB hot-add resets the chip CTRL from max (0xf) to 0x8
 * (256 MiB) — the broken-BAR1 signature.
 *
 * BAR_IDX in the first ReBAR CTRL slot reads 1 (BAR1) on this driver's
 * GPUs, matching tools/fix-bar1.sh. Bit layout per PCIe spec / pci_regs.h:
 *   CTRL bits [13:8]  = current BAR size encoding (6-bit, mask 0x3f)
 *   CAP  bits [31:4]  = supported-size bitmap (highest set bit = max enc)
 *
 * Returns 0 with *cur_enc_out / *max_enc_out set on success; -ENODEV if
 * pdev is NULL or has no ReBAR capability. Config-space only; no MMIO.
 */
int tb_egpu_pcie_read_rebar_size(struct pci_dev *pdev,
                                 u8 *cur_enc_out, u8 *max_enc_out)
{
    int pos;
    u32 cap = 0, ctrl = 0, sizes;

    if (cur_enc_out) *cur_enc_out = 0;
    if (max_enc_out) *max_enc_out = 0;

    if (!pdev)
        return -ENODEV;

    pos = pci_find_ext_capability(pdev, PCI_EXT_CAP_ID_REBAR);
    if (!pos)
        return -ENODEV;

    (void)pci_read_config_dword(pdev, pos + PCI_REBAR_CTRL, &ctrl);
    (void)pci_read_config_dword(pdev, pos + PCI_REBAR_CAP,  &cap);

    if (cur_enc_out)
        *cur_enc_out = (u8)((ctrl >> 8) & 0x3fu);

    if (max_enc_out)
    {
        /* Supported-size bitmap = CAP[31:4]; highest set bit is max enc. */
        sizes = cap >> 4;
        *max_enc_out = sizes ? (u8)(fls(sizes) - 1) : 0;
    }

    return 0;
}
```

- [ ] **Step 3: Declare it** in `nv-tb-egpu-pcie.h`, next to the `tb_egpu_pcie_read_wpr2` declaration.

```c
/*
 * Read the GPU's ReBAR (Resizable BAR) current + max BAR1 size encodings
 * from config space. cur_enc < max_enc => the chip is advertising a shrunk
 * BAR1 (the broken-256M signature after a TB hot-add). Returns 0 on
 * success, -ENODEV if pdev is NULL or lacks the ReBAR capability.
 */
int tb_egpu_pcie_read_rebar_size(struct pci_dev *pdev,
                                 u8 *cur_enc_out, u8 *max_enc_out);
```

- [ ] **Step 4: Compile-validate the fork branch** (the per-task "test")

```bash
cd /root/open-gpu-kernel-modules
make modules -j"$(nproc)" SYSSRC="/usr/src/kernels/$(uname -r)" 2>&1 | tail -20
```
Expected: builds to completion, `nv-tb-egpu-pcie.o` rebuilt, no errors. If `fls`/`PCI_REBAR_*`/`PCI_EXT_CAP_ID_REBAR` are unresolved, add `#include <linux/bitops.h>` / confirm `<linux/pci_regs.h>` is in scope (via `<linux/pci.h>`).

- [ ] **Step 5: Commit on the fork branch**

```bash
cd /root/open-gpu-kernel-modules
git add kernel-open/nvidia/nv-tb-egpu-pcie.c kernel-open/nvidia/nv-tb-egpu-pcie.h
git commit -m "A1: add tb_egpu_pcie_read_rebar_size (ReBAR cur/max size read)"
```

---

## Task 2: A3 — BAR-aware `slot_reset` RECOVERED gate

**Files:** Modify `/root/open-gpu-kernel-modules/kernel-open/nvidia/nv-tb-egpu-recover.c` (branch `a3-recovery`)

- [ ] **Step 1: Rebase a3 onto the new a1, check it out**

```bash
cd /root/open-gpu-kernel-modules
# a2 is unchanged but must sit on the new a1: rebase a2 then a3.
git checkout a2-bus-loss-watchdog && git rebase a1-pcie-primitives
git checkout a3-recovery && git rebase a2-bus-loss-watchdog
git log --oneline -3
```
Expected: clean rebases (a2/a3 don't touch nv-tb-egpu-pcie.{c,h}).

- [ ] **Step 2: Insert the BAR-aware gate** in `tb_egpu_recover_slot_reset()`, immediately BEFORE the final success block (the `"PMC_BOOT_0=0x%08x; RECOVERED"` log + `return PCI_ERS_RESULT_RECOVERED;`).

```c
    /*
     * BAR-aware gate (2026-06-14 hardening). PMC_BOOT_0 is in BAR0 (the
     * register aperture) and reads sane even when BAR1/BAR2 are desynced —
     * the broken-256M signature. A bus reset does NOT relatch a ReBAR *size*
     * (A3-CHECK 2026-06-13), so declaring RECOVERED here on BAR0 alone
     * blesses a still-256M chip and the next rm_init_adapter retry wedges
     * (E1 / E2-cycle-2). Require the chip ReBAR CTRL at max AND the kernel to
     * have assigned the full BAR1 window; otherwise DISCONNECT + escalate so
     * the Phase-1 broken-BAR1 path (in-kernel light reset, or userspace
     * fix-bar1) handles it.
     */
    {
        u8  cur_enc = 0, max_enc = 0;
        int rrc = tb_egpu_pcie_read_rebar_size(pdev, &cur_enc, &max_enc);
        u64 bar1_len = pci_resource_len(pdev, 1);
        u64 want_len = max_enc ? (1ULL << ((unsigned)max_enc + 20)) : 0;

        if (rrc == 0 && max_enc != 0 &&
            (cur_enc != max_enc || bar1_len < want_len))
        {
            NV_DEV_PRINTF(NV_DBG_ERRORS, nv,
                "tb_egpu recover: slot_reset — PMC_BOOT_0=0x%08x sane but "
                "BAR1 NOT recovered (rebar cur=%u max=%u, BAR1=%lluMiB "
                "want=%lluMiB); a bus reset cannot relatch a ReBAR size — "
                "DISCONNECT + escalate\n",
                pmc_boot_0, cur_enc, max_enc,
                bar1_len >> 20, want_len >> 20);
            if (nvl->recover)
            {
                atomic_inc(&nvl->recover->surrender_count);
                tb_egpu_recover_emit_uevent(pdev, "PERMANENT_FAIL");
            }
            return PCI_ERS_RESULT_DISCONNECT;
        }
    }
```

- [ ] **Step 3: Compile-validate**

```bash
cd /root/open-gpu-kernel-modules
make modules -j"$(nproc)" SYSSRC="/usr/src/kernels/$(uname -r)" 2>&1 | tail -20
```
Expected: clean build (`tb_egpu_pcie_read_rebar_size` is in scope via the existing `#include "nv-tb-egpu-pcie.h"`).

- [ ] **Step 4: Commit**

```bash
git add kernel-open/nvidia/nv-tb-egpu-recover.c
git commit -m "A3: BAR-aware slot_reset gate — DISCONNECT a still-256M chip instead of false RECOVERED"
```

> **Top review target (false negative):** if the chip's ReBAR CAP max-enc ever legitimately exceeds the assigned BAR1 window (firmware caps the window below chip-max), `cur_enc != max_enc` could DISCONNECT a *healthy* recovery. On this hardware a healthy chip reads `cur_enc == max_enc` (fix-bar1 writes CTRL to CAP-max) — confirm in Phase 3 review and treat any divergence as a must-fix. The `max_enc != 0` guard already neutralises a no-ReBAR / read-fail device.

---

# PHASE 1 — broken-BAR1 recovery mechanism (collapses to ONE branch after E2-verify)

> Implement exactly one of the two branches below, chosen by the E2-verify verdict. Both replace/augment the broken-BAR1 handling in `tb_egpu_recover_reset_work_handler()` (the work handler, which already runs in sleepable workqueue context — correct for a settle/verify poll or a slot-cycle).

## Branch B — escalate broken-BAR1 to userspace `fix-bar1` (if FLR+verify is flaky)

This is the fully-specified, lower-risk branch (the proven slot-cycle stays authoritative; A3 just stops doing the futile SBR and hands off).

- [ ] **B-Task 3: Early escalation in `tb_egpu_recover_reset_work_handler()`**, immediately AFTER the `bridge = pci_upstream_bridge(pdev)` null-check and BEFORE the `"bus-reset starting"` log / `pci_reset_bus`.

```c
    /*
     * Broken-BAR1 signature gate (2026-06-14 hardening). If the chip's
     * ReBAR CTRL advertises less than max (256M after a TB hot-add), a
     * pci_reset_bus/SBR cannot relatch the size — it only re-enumerates —
     * and retrying rm_init_adapter on the desynced aperture is the E1 wedge.
     * Skip the futile bus reset and escalate to userspace (fix-bar1's
     * slot-cycle/PERST) via PERMANENT_FAIL; a udev rule fires fix-bar1.
     */
    {
        u8 cur_enc = 0, max_enc = 0;
        if (tb_egpu_pcie_read_rebar_size(pdev, &cur_enc, &max_enc) == 0 &&
            max_enc != 0 && cur_enc < max_enc)
        {
            nv_printf(NV_DBG_ERRORS,
                "tb_egpu recover: %s has broken BAR1 (rebar cur=%u < max=%u, "
                "~%uMiB); a bus reset cannot relatch a ReBAR size — escalating "
                "to userspace recovery (PERMANENT_FAIL), NOT bus-resetting\n",
                pci_name(pdev), cur_enc, max_enc,
                (unsigned)(1u << cur_enc));   /* 1<<enc MiB: enc=8 => 256 */
            atomic_inc(&st->surrender_count);
            tb_egpu_recover_emit_uevent(pdev, "PERMANENT_FAIL");
            goto out_put;
        }
    }
```

- [ ] **B-Task 4: udev auto-trigger.** Add a udev rule (injector repo, shipped via the container) that runs `fix-bar1.sh --bind` on `TB_EGPU_GPU_STATE=PERMANENT_FAIL` for the GPU pdev. Exact rule + drop-in path specified at implementation time against the injector's existing udev layout. Compile/verify: `udevadm test` dry-run.

## Branch A — in-kernel light reset (if FLR+verify is deterministic)

This branch ports the **E2-verify-validated** `tbegpu_bar1_rearm` mechanism (release sibling prefetch windows → `pci_resize_resource` → FLR → verify-before-bind) into A3 so broken-BAR1 is recovered entirely in-kernel, with Branch-B's escalation as the last-resort fallback. **Detailed code deferred to post-E2-verify** because its parameters and the re-drive-`rm_init_adapter` sequencing come from the run. Design-level spec:

- [ ] **A-Task 3a: Shared primitives into A1** (`nv-tb-egpu-pcie.{c,h}`): port from `tools/e27-bar1-rearm/tbegpu_bar1_rearm.c` as exported helpers — `tb_egpu_pcie_release_empty_sibling_prefwins(gpu)`, `tb_egpu_pcie_resize_bar1(gpu, enc)`, `tb_egpu_pcie_verify_refenced(gpu, budget_ms)` (the boot0 + BAR2 poll). Reuse the E2-verify-final parameters (settle/verify budget, the sentinel set the run validated). Bracket the surgery in `pci_lock_rescan_remove()` exactly as the module does.
- [ ] **A-Task 3b: Broken-BAR1 path in the work handler** — on `cur_enc < max_enc`: decode-off → `release_empty_sibling_prefwins` → `resize_bar1(max_enc)` → `pci_reset_function` (FLR, with `reset_method` pinned to flr) → `verify_refenced`; on verified, re-drive the bind (the open path / `rm_init_adapter` retry — exact mechanism is the key design item the E2-verify run informs); on NOT verified, fall through to Branch-B escalation.
- [ ] **A-Task 3c: Decision gates** — keep H1/H2 attempt accounting; a verified in-kernel relatch counts as success; a non-verify escalates (never retry-MMIO a desynced chip). Re-review the in-kernel-FLR-while-bound safety (E2-verify runs unbound; in-driver A3 fires post-rmInit-FAIL with the adapter partially up — the re-drive sequencing must quiesce first; this is the principal Branch-A review item).

---

# PHASE 2 — cascade, regenerate, build (do regardless of branch)

## Task 4: Rebase the addon stack + bump the version

- [ ] **Step 1: Cascade-rebase `a4…a14` onto the new a3**, each onto its immediate parent in stack order (a4 onto a3-recovery, a5 onto a4, … a14 onto a13).

```bash
cd /root/open-gpu-kernel-modules
prev=a3-recovery
for b in a4-close-path-telemetry a5-version-and-toggles a6-f40b-bounded-wait-open \
         a7-f40b-bounded-wait-shutdown a8-f40b-sysfs-observability a9-egpu-probe-classify \
         a10-f40b-lockfree-sink a11-f45-deadlock-breaker a12-init-funnel \
         a13-292-inflight-aer-earlyfree a14-292-reopen-failfast-gate; do
    git checkout "$b" && git rebase "$prev" || { echo "MANUAL REBASE NEEDED at $b (conflict = an addon already touches these lines)"; break; }
    prev="$b"
done
```
Expected: every rebase conflict-free (none of a4…a14 touch nv-tb-egpu-pcie.{c,h} or the recover functions changed here). A conflict = STOP and resolve manually.

- [ ] **Step 2: Version-bump commit on `a5-version-and-toggles`** (template = the apnex.33 bump `git show 83d1308e`), then re-run Step 1's loop from `a6` so the new a5 tip propagates.

```bash
git checkout a5-version-and-toggles
# edit the version string to 595.71.05-apnex.34, then:
git commit -am "A5: bump version -> 595.71.05-apnex.34 (A3 BAR-aware recovery: no false-RECOVERED / no broken-BAR1 retry-wedge)"
```

- [ ] **Step 3: Range-diff the untouched branches** (carve-out precondition, [[feedback-force-push-fork-carve-out]])

```bash
# Per branch a4,a6..a14: expect content-identical "=" rows (only the base moved).
git range-diff @{u}...HEAD
```

## Task 5: Regenerate patches + build the production module

- [ ] **Step 1: Regenerate the addon series**

```bash
cd /root/nvidia-driver-injector
FORK_REPO=/root/open-gpu-kernel-modules tools/regen-base-patches.sh
git diff --stat patches/addon/   # A1/A3/A5 real diffs; A2/A4/A6..A14 base-hash churn only
```

- [ ] **Step 2: Build the production module via the injector** (the real composed-patch `make modules`, [[feedback-compile-validation-not-apply-check]]).

```bash
cd /root/nvidia-driver-injector
# project's documented container build; confirm: all addon patches apply in
# manifest order; kernel-open builds nvidia.ko vs 7.0.9-204; version reads apnex.34.
```
Expected: clean apply + compile; `modinfo -F vermagic` == `7.0.9-204.fc44.x86_64`, `modinfo -F version` == `595.71.05-apnex.34`.

- [ ] **Step 3: Commit the regenerated patches**

```bash
git add patches/addon/
git commit -m "patches: regenerate addon series for A3 BAR-aware recovery (apnex.34)"
```

---

# PHASE 3 — review + live validation (do regardless of branch)

## Task 6: Adversarial review + live-validation handoff

- [ ] **Step 1: Adversarial code review** (opus subagents, [[feedback-subagents-on-opus]]) — lenses: (a) ReBAR bit math + `fls` edges (cur/max both 0, `-ENODEV`); (b) the DISCONNECT/escalate refcount + uevent + counter accounting vs the existing surrender path; (c) **false DISCONNECT of a healthy recovery** (the Task-2 review-target above); for Branch A additionally (d) in-kernel-FLR-while-the-adapter-is-partially-up safety + the re-drive-`rm_init_adapter` sequencing. Apply must-fixes; rebuild.

- [ ] **Step 2: Live validation (operator-gated, `recover=1`).** Deploy apnex.34; arm capture; make a broken-256M substrate (TB deauth/reauth); let `rm_init_adapter` fail → A3 fires. Assert:
  - **Phase 0/Branch B:** capture shows `broken BAR1 … escalating … PERMANENT_FAIL`, NO `pci_reset_bus`-then-retry, host up, uevent → userspace `fix-bar1` recovers to 32 G.
  - **Branch A:** capture shows the in-kernel resize→FLR→verify, a verified relatch, a clean rebind to 32 G with no wedge; a forced non-relatch falls through to the escalation.
  - **Negative control (both):** a WPR2-stuck-but-BAR1-healthy fault still takes the normal bus-reset recovery (no regression).

- [ ] **Step 3: Update docs + register.** Record the landed branch; note `recover=1` is now broken-BAR1-safe (closing the reason E27 forced `recover=0`); if Branch A, record that `fix-bar1` is demoted to fallback (the unified-recovery milestone).

---

## Self-review

**Spec coverage:**
- BAR-aware RECOVERED gate → Task 2 (Phase 0). ✓
- New A1 ReBAR primitive (A1 had none) → Task 1 (Phase 0). ✓
- Broken-BAR1 handled by the E2-verify-selected mechanism → Phase 1 fork (Branch A in-kernel light reset / Branch B escalate). ✓
- escalate-not-repeat → both branches route to `PERMANENT_FAIL`, never a silent retry-MMIO. ✓
- recover can stay enabled in production → Phase 0 + Phase 1, asserted in Task 6 Step 2. ✓
- stacked fork rebase + regen + build → Phase 2. ✓
- E2-verify is the decision point → the decision-fork table + Phase 1. ✓

**Placeholder scan:** Phase 0 (Tasks 1+2) and Branch B (B-Task 3) carry complete code. Deliberately design-level (not placeholders): Branch A's port (its params/sequencing come from E2-verify — implementing concrete code now would be guessing the validated mechanism), the udev rule path (B-Task 4 — points at the injector's existing udev layout), and the container build invocation (the canonical project build). Each is a pointer to a real, discoverable mechanic or an explicit post-experiment dependency, not an invented API.

**Type consistency:** `tb_egpu_pcie_read_rebar_size(struct pci_dev *, u8 *cur_enc_out, u8 *max_enc_out)` declared (Task 1) and called identically in Task 2 + B-Task 3. `max_enc==0` (no-ReBAR/read-fail) guards both call sites against a false DISCONNECT. `pmc_boot_0/nvl/nv` (Task 2) and `st/pdev/out_put` (B-Task 3) are pre-existing locals in their functions (verified against `A3-recovery.patch`).

**Sequencing invariant:** Phase 0 is branch-independent and could land first, but provides no benefit before E2-verify (which runs `recover=0`, A3 disabled) and would split the cascade — so the optimal path is E2-verify → one apnex.34 cascade carrying Phase 0 + the selected Phase 1.
