# A12 — Complete GSP-bootstrap funnel: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Relocate the proven A6 bounded-wait + A10-v2 grace-discriminator from the single H-OA1 per-open site down to a complete funnel over every GSP-bootstrap entry, so a stuck chip-init can never wedge the host from any path (closes H-OA2, #282).

**Architecture:** One reusable primitive `nv_bootstrap_bounded(nv, sp, fn)` (global `system_long_wq` worker + timeout + grace discriminator + dead-bus marker + C5 sink + **`flush_work` join, kept**) wraps the two RM bootstrap families: Family-1 cold init at `nv_start_device` (covers all 5 limbs, subsumes A6), and Family-2 power-resume at `rm_power_management(RESUME)` (+ optionally the runtime-PM `rm_transition_dynamic_power`). Because the flush is kept, the worker is always joined synchronously inside the bounding call — no detached worker, no `nvlfp` in the worker, no `nv_pci_remove` tracking needed.

**Tech Stack:** C (NVIDIA open-gpu-kernel-modules fork), git-branch patch stack regen'd via `tools/regen-base-patches.sh`, compile-gated by `tools/validate-patchset.sh`, live-validated by `tools/oa-harness/rung-a10v2-validate.sh`.

**The sole residual (carried, not closed):** a genuinely-stuck non-lockdown stall blocks the `flush_work` up to RM `gpuTimeout` (~4–30 s) holding `ldata_lock` — finite, host-alive (the ① closed-RM residual; upstream-RM to make instant). Matches A6/A10 today, now uniform across all entries.

---

## File Structure

All code lives in the fork `/root/open-gpu-kernel-modules` on a NEW branch `a12-init-funnel` (based on the `a10-f40b-lockfree-sink` tip `a93196d7`). Patches are regen-generated; do NOT hand-edit `patches/*/*.patch`.

- `kernel-open/nvidia/nv.c` — the primitive + the `nv_start_device` refactor + the A6 subsume + the Family-2 resume wrap.
- `version.mk` (on the `a5-version-and-toggles` branch) — version bump.
- `/root/nvidia-driver-injector/patches/manifest` — one new addon row.
- `/root/nvidia-driver-injector/docs/patch-intents/A12-init-funnel.md` — the intent doc (new).

**Key decisions (locked):**
1. **Keep `flush_work`** (synchronous join) → worker never outlives caller → no per-`nvl` tracking, no remove-path join (red-team constraint #2 satisfied by construction).
2. **Worker carries `{nv, sp, fn}`** (a function pointer), NEVER `nvlfp` → the `nvlfp`/F42 UAF surface is gone; the `nvlfp` write stays on the syscall thread in `nv_open_device_for_nvlfp` exactly as today.
3. **Subsume A6/A10-open:** the funnel replaces `nv_open_device_for_nvlfp_bounded`; revert the call site at `nv.c:1947` to the plain call and delete A6's now-dead wrapper + worker struct. A10's open-path logic (grace + marker) re-homes into the primitive. A10's **shutdown**-path arm and the `osapi.c` `COND_ACQUIRE` flip are UNTOUCHED.
4. **Gate unchanged:** `NVreg_TbEgpuOpenTimeoutMs==0 || !nv->is_external_gpu` → byte-identical synchronous passthrough (zero non-eGPU / disabled change).

---

## Task 1: Create the A12 fork branch

**Files:** none yet (git branch only).

- [ ] **Step 1: Confirm the a10 tip and branch off it**

```bash
cd /root/open-gpu-kernel-modules
git fetch --all -q
git rev-parse --short a10-f40b-lockfree-sink   # expect a93196d7
git switch -c a12-init-funnel a10-f40b-lockfree-sink
git log --oneline -1   # confirm HEAD == a10 tip
```

Expected: new branch `a12-init-funnel` at `a93196d7`.

- [ ] **Step 2: Sanity-read the funnel + A6/A10 sites you will edit**

```bash
sed -n '1380,1382p;1525,1530p;1571,1576p;1593,1596p;1657,1661p' kernel-open/nvidia/nv.c   # nv_start_device shape
sed -n '1789,1815p' kernel-open/nvidia/nv.c    # A6 worker scaffold start
grep -n 'nv_open_device_for_nvlfp_bounded\|NVreg_TbEgpuOpenGraceMs\|os_pci_set_disconnected\|rm_power_management\|rm_transition_dynamic_power' kernel-open/nvidia/nv.c
```

Expected: `int nv_start_device(nv_state_t *nv, nvidia_stack_t *sp)` at 1380; labels `failed_release_irq:`@~1575, `failed:`@~1595; A6 `nv_open_device_for_nvlfp_bounded` present; the A6 call swap at ~1947.

---

## Task 2: Add the `nv_bootstrap_bounded` primitive

**Files:** Modify `kernel-open/nvidia/nv.c` — insert ABOVE `nv_start_device` (before line 1380).

This is A6's proven scaffold generalized to a function pointer + A10-v2's grace discriminator folded in. The params `NVreg_TbEgpuOpenTimeoutMs` / `NVreg_TbEgpuOpenGraceMs` already exist (A6/A10 declared them); reuse them, do NOT redeclare.

- [ ] **Step 1: Insert the primitive**

```c
/* === A12: complete GSP-bootstrap funnel ===
 * One bounded-wait primitive for ANY chip-touching GSP bootstrap (rm_init_adapter
 * via nv_start_device; rm_power_management RESUME). Generalises A6's per-open
 * bounded worker (the worker now carries a function pointer + {nv,sp} only, never
 * nvlfp) and folds in A10-v2's grace discriminator + dead-bus marker. flush_work
 * is KEPT (load-bearing: distinguishes slow-healthy from stuck; joins the worker
 * before the caller's sp can be freed). See
 * docs/missions/.../design/A12-init-funnel-design-of-record-2026-06-04.md.
 *
 * Gated by NVreg_TbEgpuOpenTimeoutMs>0 AND nv->is_external_gpu (E1/A9-classified).
 * Sole residual (①, closed-RM): a non-lockdown stall holds the flush up to RM
 * gpuTimeout — finite, host-alive.
 */
struct nv_bootstrap_work {
    struct work_struct  work;
    struct completion   done;
    nv_state_t         *nv;
    nvidia_stack_t     *sp;
    int               (*fn)(nv_state_t *, nvidia_stack_t *);
    int                 rc;
    atomic_t            refcount;
};

static void nv_bootstrap_work_put(struct nv_bootstrap_work *w)
{
    if (atomic_dec_and_test(&w->refcount))
        kfree(w);
}

static void nv_bootstrap_worker(struct work_struct *ws)
{
    struct nv_bootstrap_work *w = container_of(ws, struct nv_bootstrap_work, work);

    w->rc = w->fn(w->nv, w->sp);
    complete(&w->done);
    nv_bootstrap_work_put(w);
}

static int nv_bootstrap_bounded(
    nv_state_t     *nv,
    nvidia_stack_t *sp,
    int           (*fn)(nv_state_t *, nvidia_stack_t *)
)
{
    struct nv_bootstrap_work *w;
    unsigned int              timeout_ms = NVreg_TbEgpuOpenTimeoutMs;
    long                      jiffies_left;
    int                       rc;

    /* Feature gates: disabled or non-eGPU → original synchronous path (byte-identical). */
    if (timeout_ms == 0 || !nv->is_external_gpu)
        return fn(nv, sp);

    w = kzalloc(sizeof(*w), GFP_KERNEL);
    if (w == NULL)
        return fn(nv, sp);   /* cannot bound → synchronous fallback (do not fail the bringup) */

    INIT_WORK(&w->work, nv_bootstrap_worker);
    init_completion(&w->done);
    w->nv = nv;
    w->sp = sp;
    w->fn = fn;
    atomic_set(&w->refcount, 2);   /* one ref caller, one ref worker */

    nv_printf(NV_DBG_ERRORS,
        "NVRM: tb_egpu [A12]: bootstrap scheduled to bounded worker (timeout=%u ms)\n",
        timeout_ms);

    queue_work(system_long_wq, &w->work);

    jiffies_left = wait_for_completion_timeout(&w->done, msecs_to_jiffies(timeout_ms));

    if (jiffies_left > 0)
    {
        rc = w->rc;   /* healthy: completed within budget */
    }
    else
    {
        /* A10-v2 grace discriminator: re-wait to tell a worker that RETURNED
         * (fast-fail, chip recoverable) from one still STUCK (lockdown). */
        jiffies_left = wait_for_completion_timeout(&w->done,
                              msecs_to_jiffies(NVreg_TbEgpuOpenGraceMs));
        if (jiffies_left > 0)
        {
            nv_printf(NV_DBG_ERRORS,
                "NVRM: tb_egpu [A12]: bootstrap timed out after %u ms but worker "
                "returned rc=%d within +%u ms grace — fast-fail, chip NOT sunk\n",
                timeout_ms, w->rc, NVreg_TbEgpuOpenGraceMs);
            /* skip marker AND sink: error_state stays normal, chip recoverable */
        }
        else
        {
            nv_printf(NV_DBG_ERRORS,
                "NVRM: tb_egpu [A12]: bootstrap timed out after %u ms + %u ms grace, "
                "worker still in GSP lockdown poll — declaring GPU lost; dead-bus "
                "marker + sink\n", timeout_ms, NVreg_TbEgpuOpenGraceMs);
            os_pci_set_disconnected(nv->handle);   /* marker FIRST → poll self-terminates */
            rm_cleanup_gpu_lost_state(sp, nv, NV_GPU_LOST_DETECTOR_AER_FATAL);
        }

        /* LOAD-BEARING JOIN (kept): on fast-fail an immediate no-op; on lockdown the
         * marker makes the poll self-terminate so this joins in ~ms; on a non-lockdown
         * stall this is the ① bounded-latency hold (≤ gpuTimeout, ldata_lock held). */
        flush_work(&w->work);
        rc = -EIO;
    }

    nv_bootstrap_work_put(w);
    return rc;
}
```

- [ ] **Step 2: Provisional compile sanity (the primitive is unused yet — expect an unused-function warning only, not an error)**

```bash
cd /root/nvidia-driver-injector
git -C /root/open-gpu-kernel-modules add -A && git -C /root/open-gpu-kernel-modules commit -q -m "A12: add nv_bootstrap_bounded primitive (WIP)"
# full compile happens in Task 8 after wiring; here just confirm the fork tree still parses:
grep -n 'nv_bootstrap_bounded' /root/open-gpu-kernel-modules/kernel-open/nvidia/nv.c
```

Expected: the primitive present above `nv_start_device`. (Unused until Task 3.)

---

## Task 3: Refactor `nv_start_device` into `__nv_start_device_locked` + bounded shim

**Files:** Modify `kernel-open/nvidia/nv.c:1380-1660`.

This is a **mechanical verbatim move**. The body (1381→1659, including `rm_init_adapter`@1527, the A3 grafts `tb_egpu_recover_trigger_post_rminit_fail`@1539 / `tb_egpu_recover_record_post_rminit_ok`@1550, both labels `failed_release_irq:` / `failed:`, and both `return 0;` / `return rc;`) moves UNCHANGED into a new static helper. Do not alter a single statement inside the moved body.

- [ ] **Step 1: Rename the function to the locked helper**

Change the signature line (was `int nv_start_device(nv_state_t *nv, nvidia_stack_t *sp)`):

```c
/* A12: the original nv_start_device body, verbatim — now the worker callee.
 * Assumes nvl->ldata_lock held (same contract as before). */
static int __nv_start_device_locked(nv_state_t *nv, nvidia_stack_t *sp)
{
    /* ... ENTIRE original body 1381-1659 unchanged, incl. labels + A3 grafts ... */
}
```

- [ ] **Step 2: Add the public shim immediately after the helper's closing brace**

```c
/* A12: nv_start_device is now the bounded funnel. ALL cold-init limbs
 * (nvidia_open foreground, deferred-open, nvidia_dev_get/_uuid, nv_pci_probe)
 * reach the chip-touching init through here → all bounded by construction. */
int nv_start_device(nv_state_t *nv, nvidia_stack_t *sp)
{
    return nv_bootstrap_bounded(nv, sp, __nv_start_device_locked);
}
```

- [ ] **Step 3: Range-diff the move to prove the body is byte-identical**

```bash
cd /root/open-gpu-kernel-modules
git diff -U0 a10-f40b-lockfree-sink -- kernel-open/nvidia/nv.c | grep -E '^[-+]' | grep -vE '^[-+]{3}' \
  | grep -vE 'nv_start_device|__nv_start_device_locked|nv_bootstrap_bounded|^\+\}|^\+\{|A12' | head
```

Expected: NO surviving `+`/`-` lines from inside the moved body — only the rename, the new shim, and the new comment. If any body statement appears changed, the move was not verbatim — revert and redo.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -q -m "A12: funnel nv_start_device via nv_bootstrap_bounded (verbatim body → __nv_start_device_locked)"
```

---

## Task 4: Subsume A6 — revert the per-open wrapper, delete dead code

**Files:** Modify `kernel-open/nvidia/nv.c` (the call site ~1947 + A6's wrapper/worker block ~1789-1815 region as carried on this branch).

The funnel now bounds the foreground open (via `nv_open_device → nv_start_device`), so A6's per-open wrapper is redundant. Removing it is the net-simplification the design calls for. A10's open-path grace logic is already re-homed in `nv_bootstrap_bounded` (Task 2).

- [ ] **Step 1: Revert the foreground call site to the plain call**

Find (the A6 swap, ~nv.c:1947):
```c
        rc = nv_open_device_for_nvlfp_bounded(nv, nvlfp->sp, nvlfp);
```
Replace with:
```c
        /* A12: bounding moved DOWN to the nv_start_device funnel; the per-open
         * wrapper is subsumed. nvlfp is written here on the syscall thread, never
         * by a worker → no nvlfp UAF. */
        rc = nv_open_device_for_nvlfp(nv, nvlfp->sp, nvlfp);
```

- [ ] **Step 2: Delete A6's now-dead `nv_open_device_for_nvlfp_bounded`, `nv_f40b_open_work`, `nv_f40b_open_work_put`, `nv_f40b_open_worker`**

Remove the entire A6 block (struct + put + worker + the `nv_open_device_for_nvlfp_bounded` function). Keep the `NVreg_TbEgpuOpenTimeoutMs` / `NVreg_TbEgpuOpenGraceMs` param declarations (the primitive uses them). Verify nothing else references the deleted symbols:

```bash
cd /root/open-gpu-kernel-modules
grep -n 'nv_open_device_for_nvlfp_bounded\|nv_f40b_open_work' kernel-open/nvidia/nv.c
```
Expected: NO matches after deletion.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -q -m "A12: subsume A6 per-open wrapper (revert call site, delete dead worker; funnel covers it)"
```

---

## Task 5: Family-2 — bound the power-resume bootstrap(s)

**Files:** Modify `kernel-open/nvidia/nv.c` (the RESUME arm ~4550; optionally the runtime-PM site ~5172).

- [ ] **Step 1: Add the resume adapter fn (near the primitive, after Task 2's block)**

```c
/* A12: Family-2 adapter — system-resume GSP bootstrap, bounded via the funnel.
 * Holds nvl->ldata_lock (taken in nvidia_resume); the ① hold applies here too. */
static int __nv_pm_resume_locked(nv_state_t *nv, nvidia_stack_t *sp)
{
    return (rm_power_management(sp, nv, NV_PM_ACTION_RESUME) == NV_OK) ? 0 : -EIO;
}
```

- [ ] **Step 2: Wire the RESUME arm through the funnel (nv.c ~4550, inside the RESUME `case`)**

Find (RESUME case):
```c
            status = rm_power_management(sp, nv, pm_action);
```
Replace with:
```c
            /* A12: bound the resume GSP bootstrap (Family-2). */
            status = (nv_bootstrap_bounded(nv, sp, __nv_pm_resume_locked) == 0)
                         ? NV_OK : NV_ERR_GENERIC;
```
NOTE: only the **RESUME** arm (~4550). Do NOT touch the STANDBY/HIBERNATE `rm_power_management` call at ~4532 (that is a teardown, bounded separately by A7's shutdown path).

- [ ] **Step 3: (Optional, evaluate) the runtime-PM site `rm_transition_dynamic_power` (~nv.c:5172)**

This site has a different shape (an `enter` bool + a `bTryAgain` OUT param) and holds **no `ldata_lock`** (a stall wedges a PM-core runtime worker, not a device-lock holder — lower severity). It needs a dedicated bounded wrapper carrying `enter`/`bTryAgain`. **Recommendation: ship Tasks 1–2 (cold init) + Steps 1–2 here (system resume) first; treat this site as a fast-follow** unless the reviewer wants full Family-2 coverage in one cut. If included, add a parallel `nv_bootstrap_bounded_dynpower(nv, sp, enter, &bTryAgain)` modeled on the primitive with a work struct `{nv, sp, NvBool enter, NvBool bTryAgain, int rc}` and wire it at 5172. Decision point — flag for the user.

- [ ] **Step 4: Verify the RM bootstrap entries are safe on `system_long_wq`**

A6's worker already runs `nv_open_device_for_nvlfp` (→ `rm_init_adapter`) on `system_long_wq` (proven live). Confirm `rm_power_management(RESUME)` makes no assumption that `current` is the PM-core thread (read `dynamic-power.c:2568` context + `rm_power_management` in `osapi.c`). If it touches `current`/PM-core-thread-local state, escalate before wiring (do not ship a context-unsafe worker).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -q -m "A12: bound the system-resume GSP bootstrap (Family-2) via the funnel"
```

---

## Task 6: Verify the A3-recovery grafts are worker-safe

**Files:** read `patches/addon/A3-recovery.patch` (or the A3 code on the branch).

The A3 grafts `tb_egpu_recover_trigger_post_rminit_fail` / `tb_egpu_recover_record_post_rminit_ok` now execute inside `__nv_start_device_locked` ON the `system_long_wq` worker (Family-1). They already ran in multiple thread contexts (syscall thread + the `open_q` kthread), so `system_long_wq` is not a new context class — but confirm.

- [ ] **Step 1: Confirm A3's post-rminit hooks take no lock the worker can't take / queue no work that joins the worker (no A3 AB-BA)**

```bash
cd /root/nvidia-driver-injector
grep -n 'tb_egpu_recover_trigger_post_rminit_fail\|tb_egpu_recover_record_post_rminit_ok' patches/addon/A3-recovery.patch
```
Read each function body. Expected: they record state / maybe schedule the A3 watchdog; they must NOT `flush_work`/`cancel_work_sync` the bootstrap worker (would self-join) and must NOT acquire a lock the worker already holds. If they do, escalate. (Documented finding either way.)

---

## Task 7: Bump the version

**Files:** Modify `version.mk` on the `a5-version-and-toggles` fork branch.

- [ ] **Step 1: Bump on a5, then return to a12**

```bash
cd /root/open-gpu-kernel-modules
git switch a5-version-and-toggles
sed -i 's/^NVIDIA_VERSION = 595\.71\.05-apnex\.29$/NVIDIA_VERSION = 595.71.05-apnex.30/' version.mk
head -1 version.mk    # expect 595.71.05-apnex.30
git add version.mk && git commit -q -m "A5: bump version → 595.71.05-apnex.30 (A12)"
git switch a12-init-funnel
```

NOTE (task #294): a runtime deploy of apnex.30 also needs a matching `/lib/firmware/nvidia/595.71.05-apnex.30` symlink — a deploy-time concern (Task 10), not a build concern.

---

## Task 8: Regen patches, update manifest, compile-validate (NON-DISRUPTIVE)

**Files:** Modify `/root/nvidia-driver-injector/patches/manifest`; regen produces `patches/addon/A12-init-funnel.patch`.

- [ ] **Step 1: Add the manifest row after the A10 row**

Append (exactly 4 whitespace-separated fields; row order = apply order — A12 must come after A10):
```
  A12-init-funnel            addon  -              fork:a12-init-funnel
```

- [ ] **Step 2: Regen (also re-emits A5's version patch)**

```bash
cd /root/nvidia-driver-injector
tools/regen-base-patches.sh
```
Expected: writes `patches/addon/A12-init-funnel.patch` (header `Source: fork branch a12-init-funnel @ <sha>`, `Base: a10-f40b-lockfree-sink @ a93196d7…`); `A5-version-and-toggles.patch` now shows `apnex.30`; auto-runs `validate-patchset.sh`.

- [ ] **Step 3: Compile-validate the full composition (isolated worktree + `make modules`; does NOT touch the running driver / soak)**

```bash
tools/validate-patchset.sh
```
Expected: every patch applies clean (`git apply --check`), then `make modules` succeeds against `/lib/modules/$(uname -r)/build`. PASS = a clean `nvidia.ko` built in the throwaway worktree. If `nv_start_device` linkage breaks (it is non-static, called from nv-pci.c), confirm the public shim kept the exact `int nv_start_device(nv_state_t*, nvidia_stack_t*)` signature.

- [ ] **Step 4: Commit the injector-side regen artifacts (manifest + regenerated patches + .regen-state)**

```bash
git add patches/manifest patches/addon/A12-init-funnel.patch patches/addon/A5-version-and-toggles.patch patches/base/.regen-state
git commit -m "A12: add init-funnel addon patch + manifest row; bump apnex.30"
```
(No `Co-Authored-By` / AI attribution — project rule.)

---

## Task 9: Write the A12 patch-intent doc

**Files:** Create `/root/nvidia-driver-injector/docs/patch-intents/A12-init-funnel.md`.

- [ ] **Step 1: Author the intent (mirror `A6-f40b-bounded-wait-open.md` / `A10-f40b-lockfree-sink.md` structure + the project intent schema)**

Cover: intent (close H-OA2 — bound all GSP-bootstrap entries); mechanism (`nv_bootstrap_bounded` funnel at `nv_start_device` + resume wrap; keeps flush; worker carries `{nv,sp,fn}`); the provably-closed 2-family entry set; what it subsumes (A6 per-open wrapper, A10 open-path arm re-homed); the ① residual (bounded latency, upstream-RM); sovereignty L1/addon; validation (compile + rung-a10v2 fastfail); cross-ref the design-of-record. Status: `reviewed` once the user signs off.

- [ ] **Step 2: Commit**

```bash
git add docs/patch-intents/A12-init-funnel.md && git commit -m "A12: patch-intent doc"
```

---

## Task 10: [DEFERRED — POST-SOAK, OPERATOR AT CONSOLE] Live validate + cutover

**Do NOT run during the apnex.29 soak.** `rung-a10v2-validate.sh fastfail` is DISRUPTIVE — it drains the injector DaemonSet, `rmmod`/`modprobe`s the stack, and mutates live params. It takes over the module, so it cannot run concurrently with the soak. Gate this task on: apnex.29 soak complete (or the user explicitly accepts interrupting it), operator present.

- [ ] **Step 1: Build + deploy apnex.30** (container build; create the `/lib/firmware/nvidia/595.71.05-apnex.30` symlink — task #294).
- [ ] **Step 2: Fastfail validation, n≥3** (the precond regex already accepts apnex.30):

```bash
sudo tools/oa-harness/rung-a10v2-validate.sh fastfail 3
```
Expected: `FAST-FAIL VALIDATED` (≥3 `fastfail-PASS`: dmesg `chip NOT sunk` + passive config vendor `0x10de` (bus alive) + secondary next-open rc=0). Confirms the funnel bounds the induced-timeout open without sinking a healthy chip.

- [ ] **Step 3: Validate an in-kernel + a resume limb** — drive a cold init via `nvidia-smi -pm 1` (the H-OA2 `nvidia_dev_get` path) and a suspend/resume cycle; confirm each yields a bounded outcome (host alive), passive-only on a suspect chip.
- [ ] **Step 4: Cutover** — set the DaemonSet image to apnex.30; confirm `status.sh` green; start the apnex.30 soak. Update `feedback`/handover.

---

## Self-Review

**Spec coverage (design-of-record §1-6):** §2 closed entry set → Tasks 3 (Family-1 all 5 limbs via the funnel) + 5 (Family-2 resume; runtime-PM flagged in 5.3). §4 mechanism (`nv_bootstrap_bounded`, system_long_wq, keep flush, worker {nv,sp,fn}) → Task 2. §4 subsume A6 → Task 4; A10 open-arm re-homed → Task 2 (grace+marker), with A10 shutdown/osapi untouched (noted Task 4). §6.2 red-team constraints: no open_q (Task 2 uses system_long_wq ✓); sound join (kept flush → no detached worker, noted in File Structure ✓); cover both families (Tasks 3+5 ✓); A3 AB-BA (Task 6 ✓); verbatim nv_start_device move + range-diff (Task 3 Step 3 ✓). §5 residual → carried + logged (Task 9). Mechanics: regen/manifest (Task 8), version (Task 7), compile (Task 8), live validate (Task 10).

**Gap surfaced:** the runtime-PM Family-2 site (`rm_transition_dynamic_power`) has a genuinely different shape (out-param, no lock) — scoped as an evaluate/fast-follow (Task 5.3) rather than forced into the fn-pointer primitive. This is a real completeness decision for the user, flagged explicitly, not a silent drop.

**Placeholder scan:** none — all code blocks complete; the verbatim move is the one mechanical step (with a range-diff verification gate).

**Type consistency:** `nv_bootstrap_bounded(nv, sp, fn)` with `fn` = `int(*)(nv_state_t*, nvidia_stack_t*)`; `__nv_start_device_locked` and `__nv_pm_resume_locked` both match; `nv_start_device` keeps its public `int(nv_state_t*, nvidia_stack_t*)` signature (linkage from nv-pci.c preserved). Params `NVreg_TbEgpuOpenTimeoutMs`/`GraceMs` reused (declared by A6/A10), not redeclared.
