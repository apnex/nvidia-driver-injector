# MISSION-1 session handover — 2026-05-31 (R0 deployed; deterministic-recovery validation underway)

**Supersedes** `session-handover-2026-05-31.md` (that one is the apnex.24/A9 state at this session's *start*; this session moved to **apnex.25/R0**). Single re-orientation point for resuming after the pause.

## TL;DR

1. **Production is now `595.71.05-apnex.25`** (was apnex.24). It adds **R0** = the A6 `flush_work` leak→join that closes the F42 use-after-free. LIVE, healthy, pod 1/1.
2. **Boot-readiness CONFIRMED GREEN** — a reboot brings the GPU back on apnex.25 automatically (k3s→DaemonSet→pod rebuilds+loads apnex.25 ~2 min→persistence→healthy). **No manual action needed on boot.** Evidence in §Boot-readiness below.
3. **R0 is correct + shipped**, but it is the **safe interim FLOOR, not the elegant fix**. Two adversarial audits proved it UAF-solved + **deadlock-free**; the honest caveat (in-code + v5 queue): on a *bad-chip* open it blocks up to the RM `gpuTimeout` (~4–30 s) holding `ldata_lock`, because the C5 sink can't fast-fail that poll. The **elegant fix** (route the bounded open through the kernel's existing deferred-open lifecycle) is queued for v5 = E27's in-driver-recovery shape.
4. **We are mid the deterministic userspace recovery validation.** R0 done + deployed; the harness is gate-validated; **R1 is the next fire** (chip-touching, recoverable, needs operator at the console). R2/R3 are reboot-likely.
5. **Everything is LOCAL — nothing pushed all session** (~50 injector `main` commits + fork `a5–a9` rebased to apnex.25). Pushing is the standing unmade decision (force-push carve-out for a5–a8, new a9).

## Current production + repo state

```
Driver:   595.71.05-apnex.25  (C1-C5 + E1 + A1-A9, with R0 = A6 flush_work join). LIVE, healthy, BAR1 32 GiB, persistence on.
Pod:      nvidia-driver-injector-x8kbt 1/1 Running (kube-system)
Host:     obpc (NUC15). I RUN ON IT — a hard wedge kills the session; destructive rungs = human-in-the-loop reboot-loop.
Injector: /root/nvidia-driver-injector, branch main, ~50 commits ahead of origin (NOT pushed)
Fork:     /root/open-gpu-kernel-modules, branch a9-egpu-probe-classify
          tips (LOCAL): a5 2290c423, a6 690e13c5, a7 55d2af38, a8 0e7b9a37, a9 6a25b26c
KFENCE:   live (CONFIG_KFENCE=y, /sys/kernel/debug/kfence) — used in place of KASAN (no KASAN kernel; KASAN would perturb the timing race).
```

## What R0 is (the patch)

`patches/addon/A6-f40b-bounded-wait-open.patch` — one line added to A6's open-path timeout branch: `flush_work(&w->work)` (mirrors A7's SH-3 guard), after the C5 sink, before the refcount put.

- **The bug it closes (F42, source-confirmed):** A6 dispatched the chip-touching open to a worker that writes `nvlfp`/`sp`; on timeout the syscall returned `-EIO` and `nvidia_open`'s `failed:` path freed that very `nvlfp` while the leaked worker still wrote it → use-after-free, reachable with **zero operator action**, *widened* by A9 (every first-open now dispatches a leakable worker).
- **Audit verdict (`r0-flush-work-correctness-audit`, 4 agents):** `uafSolved: yes`, `deadlockRisk: none` (the flushing syscall under `ldata_lock` and the worker under the RM GPU-group lock are disjoint domains; same pattern A7 ships), `selfTerminationBounded: bounded` (by the RM `gpuTimeout`, ~4 s graphics / ~30 s compute).
- **The caveat (corrected in-code):** my first comment claimed the sink makes it "return quickly" — FALSE. `rm_cleanup_gpu_lost_state` itself takes a BLOCKING RM API-lock the worker holds, so the timeout branch blocks up to the `gpuTimeout` with `ldata_lock` held. R0 trades "fast `-EIO` + UAF panic" for "bounded soft-block + no UAF" — strictly safer, but regressive on A6's decoupling. → **FLOOR, not elegant.**
- **The elegant fix (queued v5, `architecture-v5-deep-review-queued.md`):** reuse `nvidia_open_deferred` + `open_complete` + `is_accepting_opens` (kernel already solves "async open that doesn't free nvlfp + syncs with close") — keeps the fast `-EIO`, closes the UAF structurally, and is the right shape for E27's in-driver recovery. Needs a bounded `nv_wait_open_complete` (currently unbounded) sized by the R2/R3 gpuTimeout measurement.

## The deterministic-recovery validation (where to resume)

**Goal:** prove a re-plugged eGPU recovers *deterministically* in userspace (`fix-bar1 --bind` + persistence + the A9/R0 net), the bridge until E27 — and the recipe IS E27's acceptance spec. **Plan:** `docs/superpowers/plans/2026-05-31-deterministic-recovery-validation.md`. **Index/priority:** `experiment-register.md`.

| Rung | What | Status |
|---|---|---|
| **R0** | A6 leak→join hardening (chip-free) | **DONE + deployed apnex.25 + audit-confirmed** |
| **R0b** | runtime flush confirm | **FOLDED into R2** (the natural bad-chip fire under KFENCE; an artificial healthy-chip smoke-test was rejected) |
| **R1** | baseline determinism: N≥5 quiesce→TB deauth/reauth→`fix-bar1 --bind`→6 PRIMARY asserts | **NEXT FIRE** — `tools/oa-harness/rung1.sh [N]`. Recoverable-no-reboot (leg-b fallback is the only reboot path). Operator at console. |
| **R2** | adversarial F40-precondition, N≥10 = the R0-flush-under-fire test, KFENCE | gated on R1 clean. **reboot-likely** |
| **R3** | re-recovery race (rmmod vs in-flight worker), N≥10, KFENCE | gated on R2. **reboot-likely** |
| **R4** | cure-vs-contain discrimination (does any reset clear the GSP-lockdown, or #979) | gated. reboot-likely |

**Harness** (`tools/oa-harness/`, all committed + gate-validated on live apnex.25):
- `lib.sh` — added `oa_assert_r0` (HARD-gate the rungs on the R0 flush→join string in the loaded module + KFENCE live + bounded open-timeout — closes the silent-safety-net-disable confound), `oa_bar1_recovered` (exact `==32768` + bridge window `>=33089`, not `>=`), `oa_bar1_leg_diagnose` (288 MB leg-b fallback = E27 territory vs a real recovery failure), `oa_bridge_pref_window_mib`.
- `rung1.sh` — the R1 loop (fsync'd `oa_mark`, BAR1-first, the 6 PRIMARY asserts incl. nvbandwidth H2D via the diag container).
- **RUN THE RUNGS AS SCRIPTS** (`bash tools/oa-harness/rung1.sh 1`), NOT sourced inline — `set -u` collides with the harness shell-snapshot's unguarded `$ZSH_VERSION` only when sourced into the interactive shell. Also: `find` is unreliable traversing `/lib/modules` on this host — use direct `extra/nvidia.ko` paths (already done in `oa_assert_r0`).

**OPEN caveat to resolve on the R1 run (the one thing flagged before firing):** `rung1.sh` recovers host-side (`fix-bar1 --bind`) while the injector pod also manages the module. The pod *should* be a passive bystander (loads once, then heartbeats; a kubelet restart would skip-load since the module is already up). Confirm pod-as-bystander on cycle 1, OR drain the injector pod first (nodeSelector-patch the DS to prevent respawn) and recover host-side, restoring the pod after. Do NOT assume it's benign — verify on cycle 1's markers.

## Boot-readiness (audited 2026-05-31, GREEN)

- DaemonSet: image `apnex/nvidia-driver-injector:595.71.05-apnex.25`, `imagePullPolicy: IfNotPresent`, `updateStrategy: OnDelete`, desired/ready 1/1.
- apnex.25 image present in k3s containerd (k8s.io ns) → persists across reboot, no registry pull needed.
- Host-autoload blocked: `/etc/modprobe.d/nvidia-driver-injector.conf` (`install nvidia|nvidia_modeset|nvidia_uvm|nvidia_drm /bin/false`); the pod uses `modprobe --ignore-install`.
- No DKMS `.ko.xz` shadow under `/lib/modules/$(uname -r)/extra` or `updates/dkms` (only `extra/nvidia.ko` apnex.25; the only `.ko.xz` is the unrelated `nvidia-wmi-ec-backlight`).
- k3s `enabled` + `active`; node `obpc` `Ready`.
- ⇒ On boot: k3s → DaemonSet → pod rebuilds + loads apnex.25 (~2 min) → persistence → healthy. **No manual step.**

## Key commits this session (injector `main`, all LOCAL)

R0 patch + plan: `8346951` (A6 R0 + deterministic-recovery plan), `b83b3a8` (daemonset→apnex.25). Harness: `da9ae6c` (R0/determinism gates + rung1.sh), `ef5020d` (robust R0 detection). Doc consolidation: `3769cfb` (experiment-register + de-stale indices + F40 slug refs), `ccbc534` (earlier daemonset→apnex.24). fake-5090 (separate repo, UNCOMMITTED for review): the F40→F40-open/F43/F42 catalog split + F42 source-confirmed update.

## Resume checklist (when the operator is back at the console)

1. Confirm healthy after boot: `cat /sys/module/nvidia/version` == apnex.25, `tb_egpu_state`=healthy, BAR1=32768, pod 1/1.
2. Re-validate the gates (chip-free): `bash -c 'source tools/oa-harness/lib.sh; oa_discover; oa_assert_r0; oa_bar1_recovered && echo OK'`.
3. Fire **R1**: `bash tools/oa-harness/rung1.sh 1` (smoke-cycle) → check markers + the injector-pod interaction → if clean, `rung1.sh 5` for the determinism bar. Forensics land in `/var/log/mission-1-archaeology/r1-baseline-determinism-*/`.
4. Then R2 (reboot-likely; this is the R0-flush-under-fire + adversarial bound), R3, R4 — rung-by-rung, operator present, BAR1-first after every step.

## Standing constraints (carry forward)

No Claude attribution in commits. No upstream filing without a tested fix (fork push OK; NVIDIA-repo PR gated). Force-push-with-lease to apnex fork only under the 5 carve-out conditions. After any wedge/replug: **BAR1-via-sysfs FIRST**, passive-read only, no nvidia-smi/MMIO on a suspected-broken-BAR1/wedged chip. Subagents on Opus. f40b → failure-mode-IDs-in-identifiers cleanup is **deferred to v5** (don't rename mid-stream).

## Cross-refs

`docs/superpowers/plans/2026-05-31-deterministic-recovery-validation.md` · `experiment-register.md` · `architecture-v5-deep-review-queued.md` (R0 audit result + the elegant-solution + naming-hygiene items) · the R0 audit run `r0-flush-work-correctness-audit` · deploy forensics `/var/log/mission-1-archaeology/r0b-deploy-20260530T135326Z/` · `fake-5090/failure-modes/{F40-reinit-gsp-lockdown-wedge,F42-leaked-bounded-wait-worker-uaf,F43-gsp-unload-rpc-latency-vs-naive-budget}.md`.
