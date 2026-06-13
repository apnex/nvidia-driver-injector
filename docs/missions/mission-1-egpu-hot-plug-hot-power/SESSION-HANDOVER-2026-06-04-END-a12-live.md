# Session handover — 2026-06-04 (END) — A12 LIVE + validated, soaking

**READ FIRST. Supersedes** `SESSION-HANDOVER-2026-06-04-A12-implementation.md` (which said "implement A12" —
that is now DONE).

## TL;DR
- **apnex.30 is LIVE + soaking.** A12 — the complete GSP-bootstrap funnel that closes **H-OA2 (#282),
  the last clearly-ours in-driver wedge** — is designed, implemented, deployed, cut over, and
  **fastfail-validated 3/3**. The host-wedge failure mode is now structurally closed across EVERY
  GSP-bootstrap entry point.
- apnex.30 = apnex.29 + A12. **Nothing upstream** (gate held). **No AI attribution** anywhere.

## What this session did (the arc)
1. Resumed from the A12 design-of-record (prior session's 4-pass adversarial design).
2. **Implemented A12** (writing-plans → executing-plans, inline): the `nv_bootstrap_bounded` funnel +
   both Family-2 resume sites; runtime-PM fast-follow.
3. **Built + deployed apnex.30 and cut over** — driver reloaded live; the funnel bounded a real cold
   init within budget at startup (`[F40b/A12]: open completed within budget rc=0`).
4. **Fastfail-validated 3/3** (`rung-a10v2-validate.sh fastfail 3`) — induced-timeout opens keep the
   bus alive (`0x10de`), `next-open rc=0`, chip NOT sunk. A6/A10-v2 behavior proven THROUGH the funnel.
5. **Reconciled the fake-5090 catalog** (#301 committed: F46 new, F40 split, README).
6. **Polished**: hybrid log relabel `[F40b]→[F40b/A12]` + harness FF-sentinel bounded-poll fix.

## A12 — what it is (one paragraph)
`nv_bootstrap_bounded(nv, sp, fn)` is A6's proven bounded-wait (`system_long_wq` worker + timeout +
A10-v2 grace discriminator + dead-bus marker + C5 sink + **kept `flush_work`**) generalized to a
function pointer and relocated DOWN from the per-open H-OA1 site to the **`nv_start_device` funnel** —
so it bounds all 5 cold-init limbs (foreground, deferred, `nvidia_dev_get`, `nvidia_dev_get_uuid`,
probe) at once, subsuming A6. Both Family-2 resume sites are bounded too (`__nv_pm_resume_locked` for
system-resume; `nv_dynpower_bounded` for runtime-PM/GC6-exit). The worker carries `{nv,sp,fn}` (never
`nvlfp`), so the F42 UAF surface is gone; keeping the synchronous `flush_work` join means no detached
worker (teardown-safe by construction). **The 4-pass adversarial design PROVED instant in-driver
termination is closed-RM-impossible** (dead-bus marker covers only the lockdown poll; resume holds the
RM API lock; a timeout ≠ proof of loss), so the `flush`/grace are load-bearing and the **sole residual
is a bounded recovery LATENCY (≤ RM gpuTimeout) — upstream-RM's to make instant**, NOT a wedge.

## Live state (verified at session end)
module=595.71.05-apnex.30 · BAR1=32 GiB (`0x40…00`–`0x47…ff`) · params TimeoutMs=3000/GraceMs=2000 ·
`tb_egpu_state`=healthy · injector 1/1 Running · nvidia-smi: RTX 5090 P8 persistence Enabled · no
Xid/BUG/wedge.

## Exact git state
- Fork `/root/open-gpu-kernel-modules`: branch **`a12-init-funnel`** HEAD **`b595aa45`** (on a10 tip);
  **`a5`** = apnex.30. Both pushed to origin.
- Injector `/root/nvidia-driver-injector` `main` **`54accb2`** (A12 patch + intent + manifest + deploy
  yaml apnex.30 + handovers + harness fix). Pushed.
- `/root/fake-5090` **`1e50c4d`** (F46/F40/README — #301), pushed to origin. The larger F15–F45 backlog
  remains uncommitted, user-review-gated — do NOT bundle-commit it.

## REMAINING
1. **apnex.30 14-day soak** — ongoing, automatic (`scripts/status.sh` to check; surrenders/qwd should
   stay 0).
2. **Relabel is source-only** — the `[F40b/A12]` relabel is in the a12 source + the regenerated
   `A12-init-funnel.patch`, but **live apnex.30 still logs `[F40b]`** (relabel rides the NEXT build;
   cosmetic, no rebuild warranted just for it).
3. **Upstream HELD** — C6/C3/C5/E1 + the A12 upstream-RM residual (sentinel-aware bootstrap polls +
   release the API lock on resume) all behind the deliberate gate. Even tested+deployed doesn't unlock.
4. **Optional further live validation** — the in-kernel persistence-engage H-OA2 path WAS validated at
   cutover (the funnel bounded it, rc=0); an explicit `nvidia_dev_get`/`_uuid` consumer test + a
   suspend/resume cycle were NOT run (both bounded by the same funnel mechanism; would further confirm).
5. **Related tasks**: #290 (fake-5090 F44/H-OA2 lockdown-poll substrate — would enable lockdown-arm +
   in-kernel-limb testing without the live wedge risk); #297 (F45 drgn residual-holder confirm); #282
   (open-arm — now CLOSED by A12, can be reviewed/closed).

## Cutover playbook (lessons from this session — for the next version bump)
1. **Firmware symlink (#294):** `ln -sfn 595.71.05 /lib/firmware/nvidia/595.71.05-apnex.NN` BEFORE the
   new driver loads (else `firmware load error -2`).
2. **docker→containerd:** the image builds with `docker` but k3s uses containerd — import it:
   `docker save apnex/nvidia-driver-injector:<ver> | k3s ctr -n k8s.io images import -` (imagePullPolicy
   is IfNotPresent, so the local image is used once present).
3. **DaemonSet is OnDelete:** `kubectl apply` does NOT restart the pod; cutover trigger is
   `kubectl delete pod -l app.kubernetes.io/name=nvidia-driver-injector -n kube-system`.
4. **Verify reload:** module version, BAR1 32 GiB, `tb_egpu_state`, nvidia-smi, params 3000/2000.
5. **Fastfail validation (DISRUPTIVE):** `sudo tools/oa-harness/rung-a10v2-validate.sh fastfail 3` —
   drains the injector, rmmod/modprobe-storms, induces timeouts; **operator at console, fastfail mode
   ONLY (never lockdown), wedge-risk-bounded.** Run it BACKGROUND (not a 600s-capped foreground call)
   so its restore trap always completes. Recovery if wedged: reboot; `fix-bar1.sh` if BAR1 breaks.

## Standing constraints (persist)
- **Upstream PRs HELD** until the user's deliberate gate. Fork pushes + injector-main merges OK.
- **No Claude/AI attribution** in any commit/PR/branch.
- **Subagents on opus.** Substantive work via the Workflow tool (ultracode on).
- **Safety on a suspect chip:** BAR1-via-sysfs first; passive reads; no nvidia-smi/MMIO on a
  suspected-wedged/broken-BAR1 chip; kdump can't capture the eGPU wedge (drgn passive); recovery =
  reboot. Quiesce (persistence off → drain injector → rmmod → `drivers_autoprobe=0`) before any
  unplug/power-cycle.
- **I run ON obpc** — a hard wedge kills the session; destructive/disruptive work = human-in-the-loop.

## Where everything is
- Design-of-record: `design/A12-init-funnel-design-of-record-2026-06-04.md`.
- Plan: `docs/superpowers/plans/2026-06-04-a12-init-funnel.md`. Intent: `docs/patch-intents/A12-init-funnel.md`.
- Cold-init finding: `finding-2026-06-04-a6-open-budget-vs-healthy-cold-init.md`.
- Failure modes: `fake-5090/failure-modes/{F46 new, F40 updated}`.
- Validation runner: `tools/oa-harness/rung-a10v2-validate.sh` (FF/LD-sentinel bounded-poll fixed).
- The 4 design workflows (this session's predecessor + this session): per-site/funnel/eager/async;
  perfection; constraint-driven; final worker-owned-sp+enumeration. Verdict: instant-perfection
  impossible (proven), wedge perfectly closeable, entry set provably closed.
- Memory: `project-a12-init-funnel-design-2026-06-04` (LIVE+validated status).
