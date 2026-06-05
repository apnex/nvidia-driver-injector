# Host hard-wedge forensics — lockdown-substrate re-open (2026-06-02)

**Severity:** total host loss, 2 reboots to recover. **Status:** root-caused + REPRODUCIBLE. The wedge is the trigger for fixing a real in-driver patch gap (task #292) and is blocked-cause for #291 (TB-tunnel cure isolation).

> ⚠️ **LOCK-MODEL SUPERSEDED (added 2026-06-05).** §"What wedged" below (item 3) describes an **RM
> API-lock inversion** (`rm_cleanup_gpu_lost_state → rmapiLockAcquire(API_LOCK_FLAGS_NONE)` blocking behind
> the worker holding the API lock). That reading was **falsified the SAME day** by the source-comment
> correction now in `nv.c:1950-1959` ("corrected 2026-06-02; the old comment here was FALSE"): under relaxed
> GSP init locking the worker **releases the RM API lock** at `kernel_gsp.c:4785` and holds only the **GPU
> group lock**, so the wedge is **`ldata_lock` + an unbounded `flush_work`**, *not* an API-lock inversion.
> This doc was never updated. **What HOLDS:** item 4's prediction — *the AER `error_detected` path as a
> second lock-contender → instant total wedge* — which the **2026-06-05 Path-B capture live-confirmed**
> (the AER fires in the in-flight bounded-wait window, before the A10-v2 timeout+grace discriminator runs).
> Current, source-true mechanism + the fix design:
> [`finding-2026-06-05-recovery-bringup-wedge-forensics.md`](./finding-2026-06-05-recovery-bringup-wedge-forensics.md)
> §"Reconciliation with the CURRENT source" and `experiment-register.md` #292.

## What ran

`tools/oa-harness/rung5-tbcure.sh --variant tb-only 1` (the lowest-risk guard-smoke of the #2 TB-tunnel-recovery isolation matrix), on `595.71.05-apnex.25`. Predicted "low-risk / INCONCLUSIVE-by-construction" (the cycle-2 fire would be refused at the BAR1 gate). **That prediction was wrong** — the wedge was in the *pre-fire recovery*, never reaching the gate.

## The fsync'd trail (`r5-tbcure-tb-only-20260602T052002Z/markers.log`)

Last marker, nothing after:
```
05:20:21.341 i1: cycle-1 (nvidia-smi -L — destructive close)
05:20:23.368 i1: RECOVERY[tb-only] — host rmmod (full nv_shutdown_adapter)   <-- WEDGE HERE
```
⇒ the host wedged inside `apply_recovery`'s `host_unload` (whose **first action is `nvidia-smi -pm 0`**, rung5:85), **before cycle-2 ever fired**.

## Kernel evidence (wedge boot = journal `-b -1`, persistent journald)

cycle-1's close completed **cleanly**, then the log **stops dead** — no panic, no oops, no NMI backtrace, no hung_task:
```
15:20:22 rm_disable_adapter completed within budget
15:20:23 rm_shutdown_adapter completed within budget
15:20:23 [CLOSE] site=post-shutdown ... WPR2=0x00000000 wpr2_up:no   <-- cycle-1 cleanly CLEARED WPR2
15:20:23 [CLOSE] site=close-exit    ... WPR2=0x00000000 wpr2_up:no
<<< log ends — instant total freeze, no further kernel output >>>
```
Note: **`CONFIG_DETECT_HUNG_TASK` is NOT set** and `hardlockup_panic=0` on this kernel — so a soft OR hard deadlock is *undetectable/silent* here. That is why nothing was captured. (Fix for next time: kdump is ACTIVE + `crashkernel=256M` + pstore mounted; set `hardlockup_panic=1`/`softlockup_panic=1` + sysrq-c → a deliberate reproduction panics → kdump grabs the vmcore.)

## Root cause

1. cycle-1 (`nvidia-smi -L`) opened + **cleanly closed** the chip → **WPR2 → 0**.
2. `host_unload`'s **`nvidia-smi -pm 0` re-opened** that chip → re-attempts GSP boot from **WPR2=0** on a #979-divergent chip → enters `kgspBootstrap_GH100 → gpuTimeoutCondWait(_kgspLockdownReleasedOrFmcError)` — the **WPR2-CLEAR lockdown busy-poll** substrate (NOT the WPR2-already-up fast-fail that R2/R3/R4's 30 fires all hit, and that A6/R0/C5 were validated against).
3. The open-worker holds the RM API lock across the multi-second poll; A6's 200ms timeout fires but `rm_cleanup_gpu_lost_state` (nv.c:1905) then calls `rmapiLockAcquire(API_LOCK_FLAGS_NONE)` = **BLOCKING** (osapi.c:1906), behind the worker, holding `ldata_lock`, **before `flush_work` (nv.c:1943)** even runs. The "API lock contended, deferring" branch (osapi.c:1922) is **unreachable** (NONE lacks `RMAPI_LOCK_FLAGS_COND_ACQUIRE`).
4. A second lock-contender (the trailing `rmmod`, or the GPU CTO's AER `error_detected` path = the ledger's **H-OA6** lock-inversion) → **instant total wedge**.

**Why A6/R0/C5 don't contain it:** A6 bounds the *wait* (200ms) but can't make the worker *leave* the closed-RM poll; R0's `flush_work` is *downstream* of `rm_cleanup`'s blocking acquire; the C5 sink can't be *set* because setting it needs the same API lock the worker holds. All three were validated only on the WPR2-fast-fail twin (worker exits in µs).

## Findings that change the record

- **The lockdown substrate IS userspace-reproducible** (clean shutdown → WPR2=0 → re-open), and it **hard-wedges**. This **falsifies the `8ae8ec9` claim** that it is "not userspace-reproducible on demand," and the workflow's "live-with-A6-net" firability call. The source-settled worst case (block up to `gpuTimeout` + H-OA6) is now empirically triggered.
- **Every `rung5` variant shares the exposure** — the experiment's re-open hard-wedges whenever cycle-1 clears WPR2 (stochastic), so **live #2 is blocked on the patch-gap fix (#292)**, not merely a harness tweak.

## Disposition

- `rung5-tbcure.sh`: not safe to re-run live until #292 lands (the re-open is the experiment; it can't be tweaked away). Header marked.
- The fix (#292): contain the lockdown-substrate re-open in-driver (candidates: `rm_cleanup` → `COND_ACQUIRE` so the deferring branch is reachable; a worker fail-fast out of `gpuTimeoutCondWait` via a sink flag that does NOT need the API lock; break the H-OA6 inversion). Must NOT regress the WPR2-fast-fail path (R2–R4). Design: workflow `lockdown-reopen-wedge-fix-design`.
