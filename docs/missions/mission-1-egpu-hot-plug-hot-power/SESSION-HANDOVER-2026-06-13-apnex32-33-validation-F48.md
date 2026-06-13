# Session handover — 2026-06-13 — apnex.32/.33 built + live-validated; #292 CONTAINED; F48 found+fixed (READ FIRST)

## TL;DR — current state
- **apnex.33 is LIVE on obpc, healthy, SOAKING** (module `595.71.05-apnex.33`, BAR1 32 GiB, persistence
  Enabled, P8 ~23 W, injector DS 1/1, A14 sysfs attrs present, C8 silent on the healthy path). Capture
  DISARMED. 14-day soak clock runs from the 2026-06-13 apnex.33 deploy.
- **#292 is CONTAINED — live-proven on apnex.32:** the roll that wedged apnex.30 (silent) and apnex.31
  (storm) is now (a) **refused in 13 ms by the A14 gate** in production config, and (b) with the gate
  deliberately disarmed, **contained by C7 at BOTH loglevels** (AER → A13 marker → C7-e4 one-iteration exit
  at `SET_GUEST_SYSTEM_INFO` → bounded `rc=-5`, host alive, **zero storm lines**). **GAP-4 ANSWERED:** the
  storm was removed at source, not hidden.
- **F48 found (live) + FIXED (apnex.33/C8):** probe-time PBI capability-walk infinite spin on a stale
  disconnected pci_dev (`pci_pbi.c` — no TTL/0xFF-terminator; config space = a third I/O class outside the
  MMIO short-circuit and C7's table). Host survived it (contained 1-CPU spin); fix = TTL-48+0xFF terminator
  + `nv_pci_probe` early `-ENODEV` on `os_pci_is_disconnected`.
- **Recover-disabled control + C7 n=3 top-up: DONE 2026-06-13 — n=3 ALL PASS.** With
  `NVreg_TbEgpuRecoverEnable=0` (recover module disabled) and A14 disarmed, the #292 roll was contained by
  C7/A13 identically all 3 cycles (A12 bounded open → AER → A13 DISCONNECT explicitly logging
  `disabled (NVreg_TbEgpuRecoverEnable=0)` → C7 single-pass exit at `SET_GUEST_SYSTEM_INFO` →
  `RmInitAdapter failed (0x62:0xf:2131)` → `rc=-5` bounded ~1 s, host alive, **zero storm**: 30 lines,
  `_kgspRpcRecvPoll`=1, heartbeat=0). **Proves C7/A13 containment lives on `nvl`, independent of the
  recover module.** Host restored to soaking baseline (apnex.33, recover=1, injector re-adopted the
  running driver via "already loaded — skipping", capture disarmed). **No live items remain** — soak +
  post-soak only (§NEXT 2-3).

## Version ledger
| Build | Content | Live result |
|---|---|---|
| apnex.30 | A12 funnel | #292 roll → SILENT wedge (netcon2) |
| apnex.31 | +A13 (AER early-free marker) | #292 roll → RPC-poll STORM wedge (netcon3); A13 counterproductive |
| **apnex.32** | +A13′ (dynpower funnel, comments) +C7 (e1–e8 poll coverage) +A14 (fail-fast gate) | **A14 PASS (13 ms refusal); C7 PASS ×2 dual-loglevel; R2 + clean-chip regressions green** |
| **apnex.33** | +C8 (F48 fix: PBI cap-walk TTL + disconnected-probe gate) | **deployed, healthy, C8 silent on clean probe; SOAKING** |

## NEXT — precise steps, in order

### 1. ✅ DONE 2026-06-13 — Recover-disabled control + C7 n=3 top-up (n=3 ALL PASS)
**Result:** with `NVreg_TbEgpuRecoverEnable=0` (drop-in `zz-tbegpu-control-test.conf`, lexically-last so it
beat the injector's `=1` — verified via `modprobe -c`) and A14 disarmed (`echo 0 > tb_egpu_diverged_recovered`,
which the store clears both atomics so `reopen_blocked→0`), all 3 rolls contained identically:
`[F40b/A12] open scheduled (3000ms)` → `AER error_detected (state=1)` → `A13 marker: AER during in-flight
bootstrap → early dead-bus marker` → `error_detected → DISCONNECT (disabled (NVreg_TbEgpuRecoverEnable=0))`
→ C7 single-pass `SET_GUEST_SYSTEM_INFO failed: 0xf` → `RmInitAdapter failed! (0x62:0xf:2131)` →
`open completed within budget rc=-5`, host alive ~1 s. Storm quant per cycle: ~30 NVRM lines,
`_kgspRpcRecvPoll`=1, `RpcSanityCheckFailure`=1, heartbeat=0. **Conclusion: C7/A13 containment is
independent of the recover module — it lives on `nvl`.** Cleanup: drop-in removed → chip recovered
(deauth/reauth → fix-bar1 --bind, recover=1) → injector un-drained, **adopted the running driver
("nvidia already loaded — skipping", no rmmod/reload, 0 restarts)** → capture+panics disarmed. Host =
pre-test soaking baseline (apnex.33, P8 ~22W). The procedure below is retained as the validated playbook.

Purpose (historical): prove C7/A13 containment is independent of the recover module (they live on `nvl`), and reach
n≥3 C7 cycles. Runs on apnex.33. **Procedure (the udev race burned us once — follow exactly):**
1. Arm capture: `tools/oa-harness/arm-wedge-capture.sh arm 192.168.1.241` (+ listener on .241:
   `nc -u -l 6666 | tee log`; emit `… test`; CONFIRM markers); `echo 1 > /proc/sys/kernel/{softlockup,hardlockup}_panic`.
2. **Drop-in BEFORE anything touches the driver:**
   `echo 'options nvidia NVreg_TbEgpuRecoverEnable=0' > /etc/modprobe.d/zz-tbegpu-control-test.conf`
3. Drain injector (`kubectl patch ds … nodeSelector oa.recovery-drain/excluded=true` merge-patch; delete
   pod), `rmmod nvidia_uvm nvidia`.
4. Substrate: `echo 0 > /sys/bus/thunderbolt/devices/0-1/authorized; sleep 4; echo 1 > …; sleep 6` →
   BAR1 reads 256 M → `setpci -s 0000:04:00.0 COMMAND=0000` (the fix-bar1 guard wants EXACT 0000) →
   `tools/fix-bar1.sh --bind`. **Verify:** `GPU 0:` line (GSP booted), `A14 ✓` line, and
   `cat /sys/module/nvidia/parameters/NVreg_TbEgpuRecoverEnable` == **0**.
5. `nvidia-smi -pm 0` → verify `tb_egpu_reopen_blocked == 1` (real teardown) → disarm the gate:
   `echo 0 > /sys/bus/pci/devices/0000:04:00.0/tb_egpu_diverged_recovered`.
6. THE ROLL: `nvidia-smi -L`. **PASS** = A13 marker line + `error_detected -> DISCONNECT (disabled …)` +
   zero storm lines + `open completed within budget rc=-5` + host alive. (~1 s wall.)
7. Cleanup: **`rm /etc/modprobe.d/zz-tbegpu-control-test.conf`** (critical) → recover the chip
   (deauth/reauth → `COMMAND=0000` → `fix-bar1 --bind`) → un-drain injector → disarm capture + panics.
**Gotchas (paid-for lessons):** (a) after ANY contained failure, recovery needs the **TB deauth/reauth
first** — fix-bar1's slot-cycle alone leaves WPR2-stuck (fast-fail substrate, invalidates the cycle);
(b) with C8 live, a modprobe onto the stale marked pci_dev now gets a clean `-ENODEV` + `[C8]` log line —
that is CORRECT behavior, not a failure: re-enumerate; (c) `nvidia-smi` prints "All done" even when its
open failed — check dmesg `rc=`, not the CLI string.

### 2. Soak: 14 days on apnex.33 (from 2026-06-13)
`scripts/status.sh` green; no `[A14]`/`[C8]`/F40b lines on the healthy path. Cutover/upstream stay gated.

### 3. After soak (in rough priority)
- **E27** — the second recovery gate (intermediate TB bridge `02:00.0` 256 MiB prefetch window).
  Finding: `finding-2026-06-05-E27-intermediate-bridge-window.md`; landing zone
  `pci_reassign_bridge_resources`. Reproduce/iterate per its doc.
- **#304/#305** — fix-bar1 hardening bundle (BAR1=0 false-success; COMMAND auto-clear — note the guard
  also rejects non-zero non-decode bits, hit live 2026-06-13; fold that in).
- **Upstream gate** (held, per policy): C7 + C8 are genuinely upstream-worthy (GSP polls honoring
  `pci_dev_is_disconnected`; bounded PBI cap walk). Only after soak + review.
- **Deferred, documented:** `osPciRead*` dead-bus class guard (blast-radius audit first — C8 intent Scope
  boundary); dynpower-funnel live repro (likely unreachable: `pcie_port_pm=off`); larger fake-5090 backlog.

## Where everything is
- **Findings:** `finding-2026-06-06-A13-live-FAIL-rpcpoll-wedge.md` (incl. redesign summary) →
  `design-2026-06-06-292-redesign-C7-A13prime-A14.md` (DoR, §3 amended by the audit) + RAW appendix →
  `audit-2026-06-06-GAP67-prebuild-verdict.md` (+RAW) → `finding-2026-06-13-F48-pbi-capwalk-spin.md`.
  Captures: `captures/netcon{2,3}-*.log` (the 06-13 campaign evidence is in dmesg quotes within the
  handover/register; netconsole receiver logs live on .241).
- **Patch-intents:** `docs/patch-intents/{C7,A13,A14,C8}-*.md` (statuses current). **Register:**
  `experiment-register.md` #292 entry (full ledger). **Failure modes:** fake-5090 `F47` (live-validated),
  `F48` (open→fixed-in-apnex.33; update row when the control passes).
- **Git: ALL PUSHED 2026-06-13** (user: "push now"; remote tips verified == local). Injector branch
  `a13-292-inflight-aer-earlyfree` (new on origin) @ `c228016`+ — all session work committed
  (`75c5784`→`ee8a3cb`→handover+housekeeping); fork branches (pushed): a13 `690b336f` → c7 `147285e6` →
  a14 `a705623e` → c8 `ec178e5d`; a5 `83d1308e` (apnex.33). fake-5090 main @ `8f3777b`, pushed.
  No PRs opened (gate holds). Injector branch is OFF main — merge decision pending soak.
- **Images:** apnex.32 `edbdb8ebc8e3`, apnex.33 `af7e15794672` — both in docker + k3s containerd.

## Standing constraints (persist)
- No Claude/AI attribution. Subagents on opus. Upstream HELD. One-variable-per-test, n≥3, compile-not-
  apply-check. Observability perturbs the bug (the amplifier is itself a variable). I run ON obpc — wedge
  kills the session; destructive/live-wedge steps are operator-at-console with capture armed.
