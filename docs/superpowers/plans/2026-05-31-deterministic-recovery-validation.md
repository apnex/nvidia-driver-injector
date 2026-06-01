# Deterministic userspace eGPU recovery validation — plan

> Source: Phase-0 chip-free workflow (`phase3-deterministic-userspace-recovery-premises`, 2026-05-31), both adversarial reviewers APPROVE-WITH-CHANGES. This plan folds in all required changes. Register item 1.

**Goal:** prove a re-plugged eGPU recovers **deterministically** in userspace on apnex.24 (`fix-bar1 --bind` + persistence + the A9 net) — the reliable bridge until E27 retires it. The deterministic recipe *is* E27's acceptance spec.

**Gating decision (load-bearing, source-confirmed):** an A9-armed bad-chip first-open that hits A6's 200 ms timeout is **NOT a clean outcome** on apnex.24 — A6 leaks its worker (A6 patch:117-134, no `flush_work`); the worker writes `nvlfp->open_rc/adapter_status` (nv.c:1779/1787) while `nvidia_open`'s `failed:` frees that `nvlfp` (nv.c:2135) → **zero-action UAF**; the worker also holds the RM GPU group lock for an open-source-unbounded multi-second GSP-lockdown poll. A9 *widens* the window. ⇒ **The destructive rungs (R2/R3) are HARD-BLOCKED on R0 landing.**

**Production calibration:** this UAF is **latent in healthy steady-state** (A6 only fires on a *timeout* — a bad-chip first-open / F40-precondition; in healthy prod with persistence + no re-plug, A6 completes in-budget every time, the worker never leaks). It is **live only on the bad-chip recovery path** we are about to validate. Not a fire-now emergency; a real defect that gates the validation and should be hardened regardless.

---

> **AMENDMENT (2026-05-31) — KASAN → KFENCE + source-audit-primary.** The live kernel (7.0.9-204.fc44) has **no `CONFIG_KASAN`** but **`CONFIG_KFENCE=y` is live** (debugfs present). A custom KASAN kernel is **rejected**: heavy (build + reboot) AND a ~3–5× slowdown would perturb the timing-sensitive F42 rmmod-vs-worker *race* → false negatives ("observability perturbs the eGPU bug"). So everywhere this plan says "KASAN": (1) the **primary R0 correctness proof is the source audit** (`r0-flush-work-correctness-audit`, 2026-05-31 — DONE: UAF-solved + deadlock-free); (2) **runtime UAF confirmation = KFENCE** (live; lower `kfence.sample_interval` during the run for coverage) — probabilistic, so absence-of-report is confirmatory, not definitive; (3) `oa_assert_r0_kasan` → `oa_assert_r0` + a `[ -d /sys/kernel/debug/kfence ]` check. R0's source change is **already compile-validated (apnex.25)**; the forced-short-timeout runtime check (R0b) runs on the healthy chip under KFENCE.

## R0 — A6 leak→join hardening (CHIP-FREE / source-only; the prerequisite)

**Files:** fork `kernel-open/nvidia/nv.c` (A6 timeout branch) → regen `patches/addon/A6-f40b-bounded-wait-open.patch`; `docs/patch-intents/A6-*.md`; `version.mk` (R0 tag).

1. **Two-part fix in A6's timeout branch** (after `rm_cleanup_gpu_lost_state`, before `nv_f40b_open_work_put`):
   - **(a) provable self-termination** — make the in-flight `nv_open_device_for_nvlfp` worker consult the C5 sink and/or a hard finite RM `gpuTimeout` so the GSP-lockdown poll returns promptly *even though the chip answers the polled reads* (the open-source-unbounded `gpuTimeoutCondWait` is the thing being capped).
   - **(b) join** — add `flush_work(&w->work)` (the A7/SH-3 pattern) to join the worker before `nvidia_open` frees `nvlfp/sp`; keep the refcount-2 put after the flush.
2. **Validate:** `make modules` against the live kernel tree (NOT `git apply --check` — P5/nv-misc.h lesson) + a **KASAN build**. Forced-short open timeout (e.g. 50 ms) + KASAN: worker **joined** (no zombie), **no UAF** on the freed nvlfp, `flush_work` returns in **microseconds** (sink fail-fast), **not** hanging.
3. **Version tag:** bump `version.mk` to carry an explicit `r0`/join tag so the harness can verify the loaded module is hardened (see harness changes).

**⛔ R0 STOP-RULE (reviewer-required):** the GSP-lockdown poll lives in **closed RM** with no open-source-visible finite bound, and the chip *answers* the polled reads (no CTO for the C5 sink to convert) — so self-termination **may be unachievable from kernel-open**. If, after a bounded set of strategies (C5-sink-consult inside the poll **and** a hard RM `gpuTimeout` cap), the forced-timeout+KASAN gate still **hangs** or reports a **UAF**, declare *"A6 open path not cleanly hardenable in userspace-adjacent code"* and **route the determinism goal to E27 + in-driver recovery** (which never enters the lockdown poll on a divergent chip). That is a **defined, valuable outcome** (it justifies E27 as the only true fix), not a failure to grind on. R2/R3 stay blocked.

**Limit of the R0 gate (reviewer caveat):** the chip-free forced-short-timeout proves `flush_work` returns on a *responsive* chip; it does **not** exercise the *real divergent-chip lockdown poll*. That residual is only closed empirically at R2/R3 under KASAN.

---

## Harness prerequisites (CHIP-FREE; required before R1–R3 — close the silent-safety-net-disable confound)

The current `oa-harness/lib.sh` self-gates are **not implementable as the rungs claim** (same confound class as the 2026-05-31 R0.5 ladder). Fix before any rung:

- **`oa_assert_r0()` / `oa_assert_r0_kasan()`** (NEW): `oa_die` unless `/sys/module/nvidia/version` carries the R0 tag (and, for KASAN rungs, a KASAN-build marker — cheap proxy `dmesg | grep -q 'KASAN initialized'` or a build-stamped sysfs attr). `oa_assert_a6` only substring-matches the version + checks the param exists → it **cannot** tell a hardened build from unhardened apnex.24. Wire `oa_assert_r0*` as **HARD gates** into R2/R3 (and R1, see below).
- **Exact BAR1 assert**: `oa_bar1_ok()` is `-ge OA_BAR1_MIN_MIB` (lib.sh:99). The metric needs **`-eq 32768`** *and* parent-bridge prefetchable window **`>= 33089 MiB`** so a partial / 288 MB leg-b fallback cannot pass.
- **Budget-0 aborts**: `oa_assert_a6` only `oa_warn`s on `NVreg_TbEgpuOpenTimeoutMs==0` (lib.sh:146) — that is the **destructive synchronous lane**. Change to **`oa_die`**.
- **leg-a/leg-b discriminator** (NEW): on `BAR1 != 32768`, capture the parent-bridge prefetchable window size to distinguish a **288 MB leg-b fallback** (E27 territory — the JHL9480 Barlow Ridge hot-add window bug, *not* an A6/determinism failure) from a genuine recovery-loop failure, **before** logging a determinism FAIL.

---

## R1 — baseline recovery determinism (gated; recoverable-no-reboot)

**Gate:** R0 landed (run R1 on the hardened build). *If* a pre-R0 happy-path characterization is wanted, run it with `NVreg_TbEgpuOpenTimeoutMs` set **high** (e.g. 5000 ms) so A6 physically cannot fire on a benign cold open — because under A9 **every** first-open dispatches the A6 worker (R1 is *not* structurally A6-free; it merely expects in-budget completion), and a benign timeout on an unhardened build hits the same leak. Abort (not log) on **any** `tb_egpu_f40b_fires` increment.

**Action (n≥5):** Section-D quiesce → TB deauth/reauth → BAR1-first (expect ~256) → `fix-bar1.sh --bind` → 6 per-cycle PRIMARY asserts: (1) post-replug BAR1 ~256; (2) post-fix-bar1 **BAR1 `==32768`** + bridge window `>=33089`; (3) link Gen-equiv ×4; (4) persistence **Enabled before any active query**; (5) deviceQuery PASS + nvbandwidth H2D 2.7–2.9 GB/s; (6) AER clean. ZERO reboots, ZERO A6 fires.

**✅ RESULT — 2026-06-01 (DETERMINISTIC, n=5 clean, zero reboots).** Run `r1-baseline-determinism-20260601T044533Z` (preceded by 3× N=1 smokes). Every cycle identical: broken BAR1 256 → `fix-bar1 --bind` (rc=0) → **complete CUDA bringup** → BAR1 `==32768` + window 32800 → persistence Enabled + Gen3 ×4 → nvbandwidth H2D **2.71–2.75 GB/s** (TB4-saturated, no degradation across reps) → AER clean (device+bridge UE/CE=0) → `tb_egpu_f40b_fires=0` (A6 **never armed** — the non-adversarial path, as expected). Drain-first orchestration (DS nodeSelector-patch + delete / restore) validated chip-safe in isolation first.

Two harness defects found+fixed via the cycle-1 smokes (the reason the smoke exists):
- **Gate over-strict:** the planned bridge-window threshold `>=33089` was a *boot-time* artifact; the host-side `fix-bar1` re-enum yields a **32800 MiB** window (both fully contain the 32768 BAR1). `oa_bar1_recovered` recalibrated to `>= OA_BAR1_MIN_MIB`. **Supersedes the `>=33089` figure everywhere in this plan** (harness-prereq, this §, determinism metric).
- **Recovery-completeness (substantive):** `fix-bar1 --bind` loads `nvidia` + persistence but **NOT `nvidia_uvm` / the UVM device node** → CUDA `cuInit` fails (`CUDA_ERROR_UNKNOWN`). A fix-bar1-only recovery is nvidia-smi-ready but **NOT CUDA/vLLM-ready**. Complete recipe = `fix-bar1 --bind` **+ `modprobe --ignore-install nvidia_uvm` + `nvidia-modprobe -u -c 0`** (mirrors the injector entrypoint); added to `rung1.sh` step 3b. **Open for strategic review:** fold the UVM bringup into `fix-bar1 --bind` itself so the recovery *primitive* is CUDA-complete; and **the E27 acceptance spec must mean "CUDA-ready", not just "BAR1=32 GiB"** (sharpens §E27 below).

**Scope:** this validates the **baseline / non-adversarial** recovery (A6 never fires). The **adversarial** F40-precondition path (**R2**) and the re-recovery race (**R3**) remain — those exercise R0's flush-under-fire and are reboot-likely.

---

## R2 — adversarial bound (KASAN; HARD-BLOCKED on R0; reboot-likely)

**Gate:** R0 landed + `oa_assert_r0_kasan` passes + R1 clean n≥5 + Section-D quiesce + `NVreg_TbEgpuOpenTimeoutMs>0` (`oa_die` if 0) + BAR1==32768. **Run under KASAN** (reviewer-added: R2 is the first rung firing A6 on hardware). Build the F40 substrate via `precondition.sh`.

**Action (n≥10 — reviewer-raised from 3; native F40 resolution is ~1/12–1/3 favorable so 3/3 can be luck):** cycle-1 open/close (clean) → cycle-2 open = the trigger. **Require the matched pair** in dmesg: `open scheduled to bounded worker` **AND** `open timed out after 200 ms`, `tb_egpu_f40b_fires` increments, `-EIO`, host alive. **Any single unmatched-scheduled fire = determinism FAIL → back to R0** (it means the worker wasn't joined). Pre-rmmod assert: **worker joined** (matched line present) before the recovery rmmod. Then re-recover (`fix-bar1 --bind`) to a full clean cycle. KASAN clean throughout.

**wedgeIf:** cycle-2 hard-wedges with no matching `timed out` line (R0.5 signature → A9 didn't arm / synchronous / lock held), OR KASAN UAF at the recovery rmmod (R0's join didn't self-terminate the worker → STOP, return to R0).

**✅ RESULT — 2026-06-01 (CONTAINED, n=10, 0 fails; KFENCE not KASAN per amendment).** Runner `tools/oa-harness/rung2.sh` (drain-first + no-persistence F40 precond + cycle-1 destructive close + cycle-2 fire). Smoke n=1 then bound n=10 (`r2-adversarial-bound-*`). **All 10 iterations were genuine divergent fires** (`open timed out`, not "completed within budget") and **every one contained**: bounded `-EIO` 205–214 ms, host survived, **every `scheduled` matched by a `timed out`/`completed` (worker JOINED)** — zero unmatched, `tb_egpu_f40b_fires` incremented, **0 KFENCE UAF** at `sample_interval=1`, each re-recovered to BAR1 32768. The wedgeIf never triggered. **R0 stop-rule — partial, SUBSTRATE-LIMITED (corrected 2026-06-01 after adversarial review + forensic verification):** the precond reproduces the **WPR2-already-up fast-fail** divergence (`_kgspBootGspRm: unexpected WPR2 already up` → `RmInitAdapter failed 0x62:0x40:2131`), where the worker reaches the WPR2 check at ~200 ms and fails → flush_work join ≈ 10 ms, total ~210 ms. This does **NOT** exercise the `gpuTimeoutCondWait(_kgspLockdownReleasedOrFmcError)` GSP-lockdown busy-poll that the R0 stop-rule was actually written for — on that substrate `flush_work` could still block up to RM `gpuTimeout` (~4–30 s) holding `ldata_lock` (the C5 sink's blocking `rmapiLockAcquire` can't fast-fail it). So the stop-rule is **untested for the worst case, not retired**; size E27/A9 bounded-wait against `gpuTimeout`, not the observed 210 ms. (n=10 iter-1 also showed a single open fanning out to 16 bounded-worker dispatches, all 16 matched/joined — valid for the lifecycle/leak invariant regardless of substrate.)

---

## R3 — re-recovery race (KASAN; HARD-BLOCKED on R0+R1+R2; reboot-likely)

**Gate:** R0 landed + R1 clean n≥5 + R2 bounded n≥10 (every fire matched) + `oa_assert_r0_kasan` + Section-D quiesce + BAR1==32768.

**Action (n≥10):** induce the bounded `-EIO` → **immediately** begin the recovery `rmmod` (deliberately race it against any still-in-flight A6 open-worker — the F42 double-UAF trigger). Confirm rmmod completes with **NO KASAN UAF** and **does not hang** (R0's join is microseconds; worker self-terminated). Instrument the worker with an **exit sentinel** so a hang is detected as "worker still running" not an indefinite block. Complete the loop → full clean cycle. **Framed as hypothesis-under-test**, not foregone: exit criterion = join `<X ms` across n≥10 forced races, zero KASAN, zero hangs. If R0's self-termination can't be demonstrated → escalate to the R0 stop-rule (route to E27).

**✅ RESULT — 2026-06-01 (RACE-SAFE, n=10, 0 fails) + CUDA-functional recovery.** Runner `tools/oa-harness/rung3.sh` (same precond/fire as R2; the IMMEDIATE timed `rmmod` race is the core; exit-sentinel = `timeout 15s` per rmmod). Smoke n=1 then bound n=10 (`r3-rerecovery-race-*`). **All 10 were timed-fires**, and on every one the immediate post-`-EIO` `rmmod nvidia_uvm`+`nvidia` completed **bounded 53–86 ms**, `hung=0`, module unloaded, **`kfence_new=0`** — no F42 double-UAF, because R0 joined the worker before the open returned `-EIO` (no in-flight worker for rmmod to race). The hypothesis "join is microseconds" → ~60–80 ms observed. Recovery additionally ran the **CUDA workload** (nvbandwidth H2D **2.72–2.76 GB/s**, 10/10) → post-fire recovery is **CUDA-functional**, not just BAR1-restored. (CUDA workload added to `rung1/2/3` recovery; R2 alone did not run it.)

---

## R4 — cure-vs-contain (the science tail; reboot-risk; lower-priority)

**Question:** does any runtime reset between cycle-1 (destructive close) and cycle-2 *cure* the F40-open GSP-lockdown divergence (cycle-2 opens clean), or only leave it *contained* (A6 fires)? = the safe re-incarnation of the retired #286 reset-ladder (which hard-wedged the host 2026-05-31 via the A6 first-open hole, now closed by A9). Designed + adversarially safety-reviewed via workflow `r4-cure-vs-contain-design`; runner `tools/oa-harness/rung4-cure.sh --reset {none|rebind|flr|sbr|slot}`. The load-bearing safety control: assert `tb_egpu_is_external==1` AFTER reset+rebind, ABORT the fire if 0 (the exact bypass that wedged 2026-05-31).

**✅ RESULT — 2026-06-01 (CONTAIN-ONLY across all 5 variants; n=1 smoke each; ZERO reboots).** none/rebind/flr/sbr/slot all **CONTAINED** — every fire divergence-confirmed (`timed≥1`), bounded `-EIO` ~210 ms, 0 KFENCE UAF, recovered CUDA-functional. **No PCIe-level reset (FLR, SBR=A3 `pci_reset_bus`, pciehp slot-cycle) cures the divergence ⇒ sticky = #979; A6 + TB-reenum recovery is the right-and-only fix.** Refinement: slot-cycle re-enumerated the device (BAR1→32768) yet didn't cure, while recovery (which adds a **TB deauth/reauth**) does → cure boundary is the **TB-tunnel level, not PCIe**. A9 empirically validated: `rebind` (the 2026-05-31 wedge variant) + device-drop-risk `sbr`/`slot` all ran contained, zero reboots. **Open:** n=1 per variant (divergence-confirmed so valid, but a `slot`/`sbr` n≥3 would harden the null-cure claim); the TB-tunnel-cure-boundary hypothesis (slot-cycle vs TB-reenum) is untested mechanistically.

---

## Global gates (every rung)

Section-D quiesce (nodeSelector-patch to defeat DaemonSet respawn; `oa_die` if **any** `/dev/nvidia*` holder) · **BAR1-first passive** (no nvidia-smi/MMIO on suspected-broken-BAR1/wedged/post-EIO-sink chip) · **persistence on every bind** (`fix-bar1 --bind`; the durable F40 mitigation) · **human present** for R2/R3 + sysrq armed · **fsync'd markers** (`oa_mark`: printf→`sync`, mirrored to /dev/kmsg — fixes the lost-trigger problem) immediately before+after every wedge-capable step · **PMU sampler verified-flushing** (assert pmu.log non-zero before trusting; the R0.5 pmu.log was 0 bytes; 10 s thermal cap; treat PMU-on vs PMU-off outcome divergence as perturbation signal) · **KASAN** for R0/R2/R3 · **compile-validate not apply-check**.

## Determinism metric (corrected)

PRIMARY (R1): **N≥5** consecutive replug→`fix-bar1 --bind`→workload cycles, ZERO reboots, every cycle passing all 6 PRIMARY asserts (BAR1 **`==32768`** exact + bridge `>=33089`). SECONDARY (R2/R3): every induced failure **bounded** to a *matched* `-EIO` (host alive, KASAN clean) AND re-recovered without reboot, **N≥10** induce→bound→re-recover loops; any host wedge, any unmatched-scheduled fire, or any `-EIO` that a subsequent `fix-bar1 --bind` can't clear without reboot = FAIL. Gated on R0.

## E27 acceptance spec (the deliverable for the in-kernel destination)

With E27 present, a TB hot-add yields **BAR1=32 GiB with ZERO userspace steps** (BAR1-first/passive). Two **independently-necessary** legs: **leg-a** (F41 chip fix — walk ReBAR-capable BARs, `pci_rebar_set_size`→max on the TB hot-add path before bridge alloc, mem-decode naturally OFF) + **leg-b** (bridge-window fix — hot-add `__assign_resources_sorted` allocates the full 32 GB prefetchable window, not the 288 MB fallback; `hpmmioprefsize=32G` is honored at boot but bypassed on hot-add = the gap). Secondary gates (MUST measure, not assume): (1) F40-precondition non-creation post-E27; (2) chip-state-divergence diff vs cold-plug (does persistence-default-for-eGPU still need to coexist); (3) no PCI-core regression on NVMe/Ethernet/USB/audio; (4) self-sizing vs cmdline dependence. **E27 must also satisfy the same A6 leak→join invariant in-kernel** — the in-driver recovery path must be provably self-terminating + join-safe. Until gates 1–2 pass, ship E27 as the F41/BAR1 fix and keep persistence-default-for-eGPU as the independent F40 mitigation.

## The strategic conclusion this validation can reach

If R0 proves the A6 open-worker **cannot** be made provably self-terminating from kernel-open (closed-RM poll, responsive chip), then **the bad-chip recovery path is only deterministically survivable via E27 + in-driver recovery** — i.e. userspace recovery is deterministic for the *happy* path but has a hard ceiling on the *adversarial* path, and that ceiling is itself the strongest justification for E27. The validation is designed to *reach and document* that conclusion, not to grind against it.
