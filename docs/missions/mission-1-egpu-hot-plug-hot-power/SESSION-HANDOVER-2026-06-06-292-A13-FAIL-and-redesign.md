# Session handover — 2026-06-06 — #292 A13 live-FAIL + rigorous redesign

> ⚠ **SUPERSEDED as the resume anchor (2026-06-13).** The TL;DR below is STALE (apnex.32/.33 were since
> built, live-validated — **#292 is now CONTAINED** — and F48 was found+fixed). Current READ-FIRST:
> **`SESSION-HANDOVER-2026-06-13-apnex32-33-validation-F48.md`**. This doc remains the provenance for the
> A13 FAIL → redesign decision trail; its NEXT-STEPS ledger (items 1-3) carries the per-step results.

## TL;DR — current state (⚠ STALE — see banner)
- **apnex.31 is LIVE on obpc, healthy** (driver `595.71.05-apnex.31`, BAR1 32 GiB, P8, ~25 W, persistence
  engaged, injector un-drained, pod Ready). Capture disarmed. Soak runs on apnex.31.
- **apnex.31 contains A13** (the first #292 fix). A13 is **dormant on the healthy path** but is
  **insufficient AND counterproductive on the #292 wedge path** — do NOT treat #292 as fixed.
- **#292 is DESIGNED, not built.** The fix is **C7 + A13′ + A14** (build target **apnex.32**). The
  build-spec design-of-record is `design-2026-06-06-292-redesign-C7-A13prime-A14.md`.
- **Open empirical question (GAP-4):** whether the wedge survives netconsole-OFF is unresolved (both
  captures died at +1.07 s). The next live test runs at **dual loglevel, n≥3, on both funnels**.

## What this session did
1. Recovered a lost prior session from the transcript + captures; re-root-caused #292; deployed apnex.31
   (A13), live-tested it. **A13 FAILED — host wedged (2 reboots).**
2. Forensics on the FAIL (`finding-2026-06-06-A13-live-FAIL-rpcpoll-wedge.md`, capture
   `captures/netcon3-2026-06-06-A13-live-FAIL-rpcpoll-wedge.log`): A13 fired correctly but the wedge MOVED
   past the lockdown poll into `_kgspRpcRecvPoll` (a GSP heartbeat-timeout storm).
3. **19-agent rigorous redesign** (dual-capture triangulation, no-regression audit, completeness critic):
   `design-2026-06-06-292-redesign-C7-A13prime-A14.md` + raw appendix
   `design-2026-06-06-292-redesign-RAW-analysis-appendix.md`.

## ROOT CAUSE (verified, source-cited in the DoR)
- **Two-marker truth.** `os_pci_is_disconnected` (Linux) is honored **only** by `osIsGpuBusDead()` inside
  the os.c MMIO readers — it changes what a poll's MMIO **read returns**, never the loop's abort predicate.
  `PDB_PROP_GPU_IS_LOST` (RM) is honored by `_kgspRpcRecvPoll`. `osIsGpuBusDead` is **absent** from
  `kernel_gsp.c`/`gpu_timeout.c`.
- **A13 cleared the lockdown poll only by ACCIDENT** (`_kgspLockdownReleasedOrFmcError` exits on
  `mailbox0 != 0`; `0xFFFFFFFF != 0` → TRUE). `_kgspRpcRecvPoll` has no such MMIO clause → storms.
- **A13 is COUNTERPRODUCTIVE.** Its early `os_pci` set short-circuits `osDevReadReg032` (os.c:2050)
  **before** the `DETECTOR_MMIO_DEAD` funnel (os.c:2081) — disabling the one self-heal that would set
  `PDB_PROP_GPU_IS_LOST`. The AER DISCONNECT sink's PDB-setter is also **COND_ACQUIRE-deferred** because the
  worker holds the **reacquired** API lock during the post-INIT_DONE control-RPC storm (the deployed
  nv.c:1959-1968 lock-model comment is **wrong** — GAP-5).
- **13 reachable GSP poll-sites** across 2 engines (`timeoutCondWait`, `_kgspRpcRecvPoll`) + 3 hand-rolled
  loops, and a **2nd bringup funnel** `nv_dynpower_bounded` (RTD3/GC6) that arms no marker (**GAP-1**).
- **Observability factor (medium):** the netcon3 hard wedge is co-caused by F44 (`ldata_lock` held across
  `flush_work`) + the synchronous netconsole printk-storm at `console_loglevel=8`. The 5200 ms heartbeat is
  a red herring (PTIMER, only logged, never breaks the loop).

## THE FIX (apnex.32) — see the DoR for file:line edits + the complete coverage proof
- **C7 (base/L1, load-bearing):** one read-only predicate `osIsGpuBusLost(pGpu)` (wraps `osIsGpuBusDead`)
  taught to the 2 engine chokepoints + 3 hand-rolled loops (C7-e1..e6) → covers ALL 13 poll-sites. Read-only
  ⇒ no lock, no PM-write, pure-FALSE no-op on a live bus.
- **A13′ (addon, extend A13 in place):** keep the lock-free `os_pci` marker SOURCE; arm `bootstrap_in_flight`
  on `nv_dynpower_bounded` (GAP-1); fix the lock-model comment (GAP-5).
- **A14 (addon, defense-in-depth):** fix-bar1 sticky-bit re-open fail-fast gate in both funnels;
  probabilistic (divergence is driver-invisible live) ⇒ ships WITH C7, never instead.
- **REJECTED:** A13b lock-free PDB-write (`gpuSetDisconnectedProperties` clobbers 7 PM bits + violates the
  `NV_GET_NV_PRIV_PGPU` API-lock precondition — the same unreviewed-precondition class that shipped A13);
  blocking `COND_ACQUIRE` (re-opens F44); C′-alone (divergence-blind).

## NEXT STEPS (the build — gated on operator go)
1. ✅ **Pre-build source checks DONE 2026-06-06** — **GATE: GO** (`audit-2026-06-06-GAP67-prebuild-verdict.md`
   + RAW appendix). GAP-6: all **25** callers safe; one `timeoutCondWait` edit intercepts everything (plain
   macro, no TMR variant); hazards (a)/(b) empty. GAP-7: **no PDB write needed** — but the C5-v4 guard layer
   keys on PDB alone ⇒ **NEW REQUIRED C7-e7** (widen 5 guards to `osIsGpuBusLost`; `rpc.c:11530` is
   load-bearing — prevents a per-freed-object print-storm of the apnex.31 wedge class) + recommended C7-e8.
   DoR §3 amended in place with all deltas.
2. ✅ **apnex.32 BUILT 2026-06-13** (injector commit `e8a2c74`). Fork stack (linear): a13 tip `690b336f`
   (A13′: dynpower flag GAP-1 + comments GAP-5) → c7 `147285e6` (e1–e8, 10 files, +128) → a14 `a705623e`
   (gate both funnels + per-nvl bits + always-on sysfs in nv-pci.c + auto-OR; addon-TU sovereignty kept —
   arming uses the structural post-`nv_shutdown_adapter` signal, no A4-TU edit) → a5 `eba925ef`
   (→ apnex.32). `fix-bar1 --bind` now asserts `tb_egpu_diverged_recovered`. Validation: per-branch
   `make modules` clean ×2; regen composed-stack compile OK; image
   `apnex/nvidia-driver-injector:595.71.05-apnex.32` (edbdb8ebc8e3) builds, all 22 patches apply cleanly.
   **NOT deployed; NOT live-validated.**
3. ⮕ **LIVE TEST RUN 2026-06-13 — #292 CONTAINMENT VALIDATED (partial n; one new finding):**
   - **A14 gate: PASS** — the apnex.30/31-killer roll refused in **13 ms** (`-EIO`, zero chip touch);
     arming line + `reopen_blocked` semantics all correct; fix-bar1 assertion works end-to-end.
   - **C7 cycle-1 (min-observability): PASS** — real AER cycle (~1.04 s): A13 marker → C7-e4 sanity-exit at
     `SET_GUEST_SYSTEM_INFO` (the netcon3 storm RPC) in ONE iteration → `open completed within budget
     rc=-5` → host alive. **Zero storm lines.**
   - **C7 cycle-2 (loglevel 8): PASS — GAP-4 ANSWERED**: zero storm lines under the exact netcon3 amplifier
     conditions ⇒ the storm is removed at SOURCE, not hidden.
   - **Bonus regression set:** clean-chip matrix all green (deploy cold-init; persistence-ON ×3;
     persistence-OFF healthy teardown→re-open 1947 ms, gate inert, zero false fires) + an accidental **R2
     WPR2-fast-fail regression PASS** (bounded, NOT sunk, H2 gating correct, auto-OR correctly inert).
   - **Cycle-3 (recover-disabled control): INCOMPLETE** — udev's modprobe raced the `Enable=0` param (the
     raced roll itself was contained, rc=-5); the re-probe of the stale marked-disconnected pci_dev then hit
     **F48** (`finding-2026-06-13-F48-pbi-capwalk-spin.md`): probe-time PBI capability-walk infinite spin on
     0xFF config reads (`pci_pbi.c:88`, vendor latent bug, C6-class; config space = a third I/O class outside
     both the MMIO short-circuit and C7's table). **Host SURVIVED** (contained 1-CPU spin, unkillable
     modprobe holding the device lock) → operator reboot to clear; post-reboot cold-plug clean, apnex.32
     restored, capture disarmed.
   - **Residual to close:** (a) ✅ **F48 fix BUILT 2026-06-13 → apnex.33** (`C8-f48-pbi-capwalk-probe-gate`,
     fork `ec178e5d`: TTL-48 + 0xFF-terminator on the PBI cap walk in `pci_pbi.c` + `nv_pci_probe` early
     `-ENODEV` on `os_pci_is_disconnected`; intent `docs/patch-intents/C8-…md`; the `osPciRead*` class
     guard deliberately deferred pending blast-radius audit — see the intent's Scope boundary); (b) re-run
     the recover-disabled control — **procedure (avoids the udev race):**
     `echo 'options nvidia NVreg_TbEgpuRecoverEnable=0' > /etc/modprobe.d/zz-tbegpu-control-test.conf`
     BEFORE the substrate rebuild, then deauth/reauth → `fix-bar1 --bind` (its modprobe inherits the
     drop-in) → verify `/sys/module/nvidia/parameters/NVreg_TbEgpuRecoverEnable == 0` → pm0 → disarm gate →
     roll → expect identical C7 containment (A13/C7 live on nvl, independent of the recover module) →
     **remove the drop-in after**; (c) C7 n≥3 top-up (rides the same session) + the dynpower-funnel repro
     (likely unreachable on this host: `pcie_port_pm=off`); (d) 14-day soak (restarted on apnex.33 deploy).

## Where everything is
- **Build spec:** `design-2026-06-06-292-redesign-C7-A13prime-A14.md` (+ RAW appendix). **FAIL forensics:**
  `finding-2026-06-06-A13-live-FAIL-rpcpoll-wedge.md`. **Captures:** `captures/netcon2-…-292-pathB-wedge.log`
  (apnex.30 silent lockdown wedge), `captures/netcon3-2026-06-06-A13-live-FAIL-rpcpoll-wedge.log` (apnex.31
  storm). **Register:** `experiment-register.md` #292.
- **Patch-intents (this session):** `docs/patch-intents/{C7-292-…,A13-292-…,A14-292-…}.md` (lint with
  `tools/intent-lint.sh`). **Failure modes:** `/root/fake-5090/failure-modes/F47-…` (new) + F09/F11 updated.
- **Source for the build:** `/root/open-gpu-kernel-modules` (fork; A13 is on branch
  `a13-292-inflight-aer-earlyfree`). The DoR §3 cites every edit's `file:line`.
- **apnex.31 image:** in docker + imported to k3s containerd; DS image = apnex.31, `OnDelete` strategy.

## Standing constraints (persist)
- **No Claude/AI attribution** in commits/PRs/branches. **Subagents on opus.** Upstream HELD (gate).
- **I run ON obpc** — a hard wedge kills the session; the live wedge test is **operator-driven at the
  console** (cable/keyboard + reboot). Capture is the safety net (netconsole→.241 + kdump; note kdump did
  NOT capture this wedge — netconsole is the load-bearing record).
- **Reliability methodology:** one variable per test, written hypothesis, n≥3, cheapest first, compile-not-
  apply-check. **Observability perturbs this bug** — prefer passive; the netconsole amplifier is itself a
  live variable (GAP-4).
