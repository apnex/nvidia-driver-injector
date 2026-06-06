# Finding — A13 live test FAILED: the wedge MOVED to the GSP RPC poll (2026-06-06)

**Test:** apnex.31 (A13 #292 in-flight-AER early-free), live, on a fix-bar1-recovered EQ-diverged 32 G chip,
persistence-OFF LAST-CLOSE → re-open (the captured #292 repro). **Result: HOST WEDGED (2 reboots).**
**Capture:** `captures/netcon3-2026-06-06-A13-live-FAIL-rpcpoll-wedge.log`.

## Verdict
**A13 fired correctly but did NOT prevent the wedge — the wedge moved deeper into GSP init.** A13 is
**necessary but insufficient**: it short-circuits one GSP poll, the re-open got past it into a second poll
A13 doesn't cover.

## Timeline (netcon3, uptime s)
- Stage 4 (1356.10) — persistence-OFF LAST-CLOSE completed **cleanly** (rm_disable 29 ms, rm_shutdown
  643 ms GSP unload, post-shutdown `WPR2=0`, close-exit clean). Correct diverged-WPR2-cleared substrate.
- Stage 5 (1396.565) — THE ROLL. `open scheduled to bounded worker (timeout=3000ms)` (1396.572).
- 1397.590 — **AER Uncorrectable Non-Fatal CmpltTO** from 04:00.0 (the re-open's MMIO touch on the now-dead
  chip), `channel state=1` (io_normal), `HdrLog=ffff…`.
- 1397.5938 — **A13 FIRES:** `tb_egpu recover: AER during in-flight bootstrap -> early dead-bus marker …
  (#292)` → `error_detected -> DISCONNECT (sink-set …)`. **No bus reset.** (A13's AER-handler half works.)
- 1397.628 → EOF (1397.647) — **GSP heartbeat-timeout STORM:** hundreds of
  `_kgspRpcRecvPoll: GSP RM / LibOS heartbeat timed out` + `_kgspIsHeartbeatTimedOut … timeout 5200` +
  `tmrGetTimeEx_GH100: Consistently Bad TimeLo value ffffffff`, ~3 lines/iteration, every ~0.1 ms. Capture
  ends mid-storm → host wedged.

## Root cause (source-confirmed)
A13 sets the **lock-free Linux marker `os_pci_set_disconnected`** (→ `os_pci_is_disconnected`). The **first**
GSP poll `_kgspLockdownReleasedOrFmcError` honors it via `osIsGpuBusDead` (os.c) and self-terminates — that
is what A13/A10-v2 target. **But:**
1. **This re-open advanced *past* the lockdown gate** (the chip stayed alive ~1 s into init, dying mid-RPC
   at the CmpltTO, +1.02 s) into the **GSP RPC handshake `_kgspRpcRecvPoll`** (kernel_gsp.c:2682).
2. **`_kgspRpcRecvPoll` checks `PDB_PROP_GPU_IS_LOST` (kernel_gsp.c:2814), NOT `os_pci_is_disconnected`.**
   `osIsGpuBusDead` is **only** in `os.c`/`osinit.c` — it is **not** referenced in `kernel_gsp.c`. So the RPC
   poll never sees A13's marker.
3. **A13 set only the Linux marker, never `PDB_PROP_GPU_IS_LOST`** (it calls `os_pci_set_disconnected`
   directly; only the full C5 sink `cleanupGpuLostStateAtomic` sets *both* markers). ⟹ the RPC poll keeps
   polling the dead bus → heartbeat-timeout storm → the foreground (holding `nvl->ldata_lock` across the
   bounded-wait) stays blocked → F44 wedge, **amplified** by the synchronous netconsole printk-storm
   (console_loglevel=8) — an "observability perturbs the bug" factor.

**Net:** the dead-bus short-circuit is **per-poll**. A13 covers `_kgspLockdownReleasedOrFmcError`
(via `os_pci_is_disconnected`); `_kgspRpcRecvPoll` uses a **different** marker (`PDB_PROP_GPU_IS_LOST`).
Freeing the worker by marker-setting is **whack-a-mole across GSP polls.**

## Fix directions (for the next iteration — NOT yet chosen)
1. **A13b — set BOTH markers.** Have `error_detected` (or A13) set `PDB_PROP_GPU_IS_LOST` too (the full C5
   sink), so the RPC poll also short-circuits. **Risk:** `gpuSetDisconnectedProperties` / the sink may need
   the GPU group lock the in-flight worker holds → could re-introduce contention; needs source analysis.
2. **kernel_gsp.c dead-bus short-circuit** — teach `_kgspRpcRecvPoll` (and the heartbeat path) to honor
   `os_pci_is_disconnected` / `osIsGpuBusDead`. **Cost:** an L1 patch into NVIDIA GSP core; covers the RPC
   poll but the whack-a-mole risk remains for yet other polls.
3. **C' — re-open FAIL-FAST GATE (the robust answer).** Refuse the diverged post-WPR2-cleared re-open at the
   A12 funnel **before** RM bring-up, so **no** GSP poll is entered. Sidesteps the whack-a-mole entirely.
   Caveat (from the design-of-record): divergence is invisible to the driver in the live case → needs the
   userspace `fix-bar1` sticky assertion or a passive divergence proxy.
4. **Methodology:** re-run with netconsole/console-loglevel **minimised** (or `printk` rate-limited) to test
   whether the storm itself is load-bearing — the 5200 ms heartbeat timeout means the worker is *bounded*;
   without the synchronous-printk amplifier the host might survive the stall.

## Status
A13 stays deployed-but-insufficient (do NOT claim #292 fixed). Host post-test: rebooted, chip restored to
apnex.31 healthy (un-drained). apnex.31 image + A13 patch on branch `a13-292-inflight-aer-earlyfree`.

## REDESIGN (2026-06-06) — supersedes the "fix directions" above
A 19-agent rigorous redesign (dual-capture triangulation, no-regression audit, completeness critic) went
**deeper** than this finding and **corrected its recommendation**. See
`design-2026-06-06-292-redesign-C7-A13prime-A14.md`. Three deepenings:
1. **A13 is COUNTERPRODUCTIVE, not merely insufficient.** Setting `os_pci_is_disconnected` early
   short-circuits `osDevReadReg032` (os.c:2050) **before** the `DETECTOR_MMIO_DEAD` funnel (os.c:2081) —
   disabling the one self-heal path that would eventually set `PDB_PROP_GPU_IS_LOST` (the marker
   `_kgspRpcRecvPoll` actually honors). The surprise-removal path self-heals *because* that detector fires;
   A13 suppressed it for the re-open.
2. **Two-marker truth:** `os_pci_is_disconnected` is honored **only** by `osIsGpuBusDead` inside the os.c
   MMIO readers (so it only changes what a poll's MMIO *read returns*, never the loop's abort predicate);
   `PDB_PROP_GPU_IS_LOST` is honored by `_kgspRpcRecvPoll`. `osIsGpuBusDead` is **absent** from
   `kernel_gsp.c`/`gpu_timeout.c`. A13 covered the lockdown poll only **by accident** (`0xFFFFFFFF != 0`).
3. **13 reachable GSP poll-sites across 2 engines + 3 hand-rolled loops, and a SECOND bringup funnel**
   (`nv_dynpower_bounded`, RTD3/GC6) that arms no marker (GAP-1) — coverage gaps that would have caused
   another live FAIL.
**Chosen fix = C7 (read-only dead-bus poll-reader at the 2 engine chokepoints + 3 hand-rolled loops) +
A13' (keep the lock-free marker source; close the dynpower funnel; fix the lock-model comment) + A14
(fix-bar1 sticky fail-fast gate, defense-in-depth).** Rejected: A13b lock-free PDB-write (clobbers 7 PM
bits + violates `NV_GET_NV_PRIV_PGPU` API-lock precondition); C' alone (divergence-blind). Build = apnex.32;
validate at **dual loglevel** (the storm may be a netconsole amplifier — unresolved), n≥3, on BOTH funnels,
every poll-site demonstrably short-circuited.
