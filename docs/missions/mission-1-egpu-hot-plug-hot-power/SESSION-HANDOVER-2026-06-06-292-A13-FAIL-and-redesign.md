# Session handover — 2026-06-06 — #292 A13 live-FAIL + rigorous redesign (READ FIRST)

## TL;DR — current state
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
2. **Build apnex.32:** carve `C7` on the fork (base, after C6), extend `A13` in place (A13′), add `A14`
   addon; add patch-intent + review files (intents drafted this session — see below); manifest + version
   bump (A5-branch commit, no cascade — see the apnex.31 build for the procedure). **Real `make modules`**
   (the P5 lesson; `git apply --check` is NOT validation).
3. **Live test (the §5 validation plan):** the exact apnex.31 Stage-5 repro (TB deauth/reauth → `fix-bar1
   --bind` → `nvidia-smi -pm 0` → roll) at **both** `console_loglevel=8` AND minimised observability
   (`echo 4 4 1 7 > /proc/sys/kernel/printk` + external liveness probe + passive sysrq-w/t/l), **n≥3**, on
   **both** the open funnel and the **dynpower** funnel (idle→GC6→resume). Acceptance = host survives at
   both loglevels + zero storm lines + every poll-site short-circuited + the no-regression matrix.

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
