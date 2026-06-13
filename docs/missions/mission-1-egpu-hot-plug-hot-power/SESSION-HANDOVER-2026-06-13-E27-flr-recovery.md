# Session handover — 2026-06-13 (cont.) — E27 FLR-resize recovery saga; #292/#304/#305 CLOSED (READ FIRST)

> Supersedes `SESSION-HANDOVER-2026-06-13-apnex32-33-validation-F48.md` as the resume anchor (that one is
> still valid for the #292/apnex.32/.33 provenance). This doc carries everything after the #292 soak began.

## TL;DR — current state
- **Host HEALTHY** (just rebooted after an E27 experiment triggered a platform reset): apnex.33, fresh
  cold-plug (BAR1 32 G @ `0x4000000000`), injector pod Ready 1/1, `recover=1` (the E27 `recover=0` drop-in
  was removed), capture + panic sysctls OFF.
- **The apnex.33 14-day SOAK clock was reset MANY times** by the E27 live experiments + reboots. Treat
  the soak as **restarting now** from a clean idle baseline — do NOT count prior soak time.
- **CLOSED this session:** (1) #292 recover-disabled control + C7 **n=3 ALL PASS** (#292 live work done);
  (2) **#304/#305 fix-bar1 hardening** (integer BAR1 sizing + memory-decode-bit COMMAND guard).
- **ACTIVE: E27** broken-BAR1 in-kernel recovery. The light-reset (resize + **FLR**) mechanism is
  **RE-SCOPED to "viable WITH a post-reset settle, pending n≥3"** — NOT dead, NOT proven. The slot-cycle/
  PERST (automate fix-bar1) is the proven-deterministic fallback. **Next = one more careful live test
  (E2-with-settle).**
- **Git:** all on injector branch `a13-292-inflight-aer-earlyfree` @ **`9e82b15`**, pushed. Fork branches
  unchanged (apnex.33). Branch is OFF `main` — merge pending soak.

## Version ledger (unchanged from #292 work)
| Build | Content | State |
|---|---|---|
| apnex.33 | #292 (C7+A13′+A14) + C8 (F48) | LIVE, healthy, soaking (clock restarted) |
Fork: a13 `690b336f` → c7 `147285e6` → a14 `a705623e` → c8 `ec178e5d` → a5 (apnex.33). All pushed.

## What this session did (chronological)
1. **Housekeeping** — persisted stray artifacts; corrected stale "NOT pushed" claims; trimmed MEMORY.md.
2. **#292 recover-disabled control + C7 n=3 top-up — DONE, n=3 ALL PASS.** With `NVreg_TbEgpuRecoverEnable=0`
   and A14 disarmed, all 3 #292 rolls contained identically (A13 DISCONNECT explicitly `disabled
   (recover=0)` → C7 single-pass exit → `rc=-5`, host alive, zero storm). C7/A13 live on `nvl`,
   independent of the recover module. #292 live work CLOSED.
3. **#304/#305 fix-bar1 hardening — DONE** (`tools/fix-bar1.sh`): #304 integer `bar1_size_mib()` + off-bus
   fatal (kills the BAR1=0 float-swallow); #305 COMMAND guard → memory-decode-bit-only + dry-run-safe
   self-heal. Validated (bash-n + shellcheck + unit tests + 3-reviewer opus workflow, ship-with-fixes).
   Live device-test deferred to next real recovery.
4. **Kernel update assessment** — `kernel-core 7.0.12-201.fc44` available (from 7.0.9-204; a stable patch
   bump). **DEFER** until post-soak: low risk (injector rebuilds the patched module per-kernel; no DKMS
   collision currently; `kernel-devel-matched` auto-pulls). Watch surface = the `kernel-open` glue. When
   updating: validated op (rebuild + cmdline re-assert + smoke-test), not blind `dnf update`.
5. **E27 deep dive (the bulk)** — see below.

## E27 — the active work, precise current state
**Goal:** retire the userspace `tools/fix-bar1.sh` with an automatic in-driver/in-module recovery of a
TB-hot-add broken BAR1 (256 M instead of 32 G). Settled root cause (real 7.0.9 source + live): on TB
hot-add the chip's ReBAR resets to 256 M; the **root hotplug port `00:07.0`'s own prefetch window** and
the chip aperture both need to be brought to 32 G. The address is **exonerated** (GPU runs fine at
`0x6000000000`). Full detail: **`finding-2026-06-13-E27-halfb-determinism-verdict.md`** (READ it — it has
the whole saga: survey → determinism → Stage-1 → salvage → E1 → A3-check → E2 cycle-1 PASS → cycle-2 FAIL
+ platform reset → settle re-scope).

**The mechanism (module `tools/e27-bar1-rearm/tbegpu_bar1_rearm.c`, built clean vs the real kernel):**
`decode-off → pci_release_resource() the empty downstream-port sibling prefetch windows (03:01/02/03,
the cascade-blockers) → pci_resize_resource(gpu,1,15,0) → pci_reset_function(FLR) → settle_ms → bind`.
All primitives `EXPORT_SYMBOL` in the real `Module.symvers`. Params: `gpu`, `size=15`, `dry_run=Y`,
`flr=Y`, `settle_ms=2000` (NEW). Harness: `run-experiment.sh` (staged 0/1/2).

**The live-test arc (why the mechanism is "re-scoped, pending"):**
- **Stage 0 (dry-run): PASS.** Survey correct (exact 3 siblings), zero writes.
- **Stage 1 (wet, WRONG substrate — a healthy aligned tree): misleading FAIL.** Moved a *working* GPU's
  BAR1 → init failed → I over-concluded "approach dead." User pushed back → salvage investigation found
  the cause = **device-state desync** (the resize moved/grew the BAR but the chip wasn't reset), fix =
  **FLR after resize**. Implemented `flr` param.
- **E1 (`flr=0`, real broken-256 M): FAILED + WEDGED.** Resize-without-reset desynced the aperture
  (`kbusVerifyBar2` garbage → `RmInitAdapter 0x24:0x72:1307`, contained) → then the **A3 recover module
  (`recover=1`)** fired a non-ReBAR-aware `pci_reset_bus` + retry → the retry's MMIO **wedged**. ⇒ (a) a
  reset IS required; (b) **experiments MUST run `recover=0`**.
- **A3-check (source): A3 DID restore ReBAR=0xF after its SBR, yet the retry wedged** → predicted FLR
  (weaker) likely fails; recommended automating fix-bar1's slot-cycle. (Honest residual flagged: a clean
  FLR-before-init might still pass.)
- **E2 cycle-1 (`flr=1` + `recover=0`): PASS** — FLR re-latched the 256 M→32 G size on a fresh chip,
  `RmInitAdapter rc=0`, GPU healthy (RTX 5090, 32 G, P8), zero errors. Refuted the A3-check prediction.
- **E2 cycle-2: FAILED** (same `flr=1`; `kbusVerifyBar2` garbage). **The difference was TIMING** — cycle-1
  had ~seconds between FLR and bind (separate commands); cycle-2 ran FLR + `modprobe` back-to-back in ~ms.
  ⇒ the FLR relatch likely needs a **post-reset settle** (fix-bar1's slot-cycle has settle sleeps). Then
  the failed-init chip, **repeatedly accessed (11 opens — my retry `nvidia-smi` re-triggered worse
  WPR2/crashcat opens)**, escalated to a **fatal hardware error → firmware/platform RAS reset** (no kdump
  panic; next-boot `BERT: 1 record`). The reset was **aggravated by experiment methodology**, not purely
  inherent.
- **Resolution: re-scoped, NOT dead.** Added `settle_ms` (default 2000) → `msleep` after the FLR. The
  mechanism is "viable WITH settle+verify, pending n≥3." The slot-cycle/PERST (automate fix-bar1) remains
  the proven fallback if settle can't make FLR deterministic.

## NEXT (in order)
### 1. E27 — E2-with-settle (operator-gated; the deciding test). ⚠ wet PCI surgery + GPU init; resets soak.
Run the **hard-won safe procedure** (lessons paid for in wedges/resets):
1. Operator at console; bring `.241` capture box + listener up (`nc -u -l 6666 | tee log`); arm capture
   (`tools/oa-harness/arm-wedge-capture.sh arm 192.168.1.241`) + `echo 1 > /proc/sys/kernel/{soft,hard}lockup_panic`.
2. **`recover=0` drop-in BEFORE touching the driver** (udev-race fix): `echo 'options nvidia
   NVreg_TbEgpuRecoverEnable=0' > /etc/modprobe.d/zz-e27-recover-off.conf`; verify with `modprobe -c`.
3. Drain injector + `rmmod nvidia_uvm nvidia`.
4. **Substrate:** deauth/reauth (`echo 0 > /sys/bus/thunderbolt/devices/0-1/authorized; sleep4; echo 1; sleep6`)
   → BAR1 = 256 M.
5. `insmod tbegpu_bar1_rearm.ko dry_run=0 flr=1 settle_ms=2000` → expect FLR rc=0 + RESULT=OK; `rmmod` it.
6. `modprobe --ignore-install nvidia` (plain modprobe is blocked by the injector's `install /bin/false`).
   **PASS** = `RmInitAdapter rc=0` + `nvidia-smi` shows the GPU 32 G. **FAIL** = `kbusVerifyBar2`/`rc=-5`.
7. **FAIL-SAFE (critical):** on FAIL, **immediately `rmmod nvidia`; do NOT retry `nvidia-smi`** (retries on
   a desynced chip degrade it → platform reset). Then deauth/reauth to a fresh substrate for the next cycle.
8. **n≥3** on independent substrates. Cleanup: remove the drop-in, recover the chip (deauth/reauth +
   `fix-bar1 --bind`), un-drain injector, disarm capture.
- **Decision after E2-with-settle:** deterministic n≥3 PASS → the light FLR mechanism is the recovery
  (then build the fail-safe-quiesce + verify-before-bind into it, + decide auto-trigger). Still flaky →
  pivot to **automate fix-bar1's chip-CTRL + window-fix + slot-cycle/PERST** (proven deterministic).

### 2. E27 follow-ons (after the mechanism is decided)
- **A3 recover-module hardening (real latent bug, needed either way):** `tb_egpu_recover_slot_reset`
  declares `RECOVERED` on a **BAR0-only `PMC_BOOT_0` read = size-blind false-positive** for broken-BAR1,
  then lets a retry MMIO wedge. Make it **BAR-aware** (ReBAR current-size + BAR2 sentinel before
  RECOVERED), **signature-gate** broken-BAR1 → slot-cycle-or-`PERMANENT_FAIL` (never retry-MMIO a
  desynced chip), **escalate-not-repeat**. Then `recover` can stay ENABLED in production.
- **Unified recovery merge** (the user's "validate first, then design the merge"): one dispatcher,
  signature-classified, all reset paths BAR/ReBAR-aware. Design AFTER E2-with-settle decides the
  mechanism.

### 3. Soak + the rest of the backlog
- Restart the **apnex.33 14-day soak** from a clean idle baseline (no E27 experiments). Cutover/upstream
  gated on it.
- **#304/#305 device-test** (fix-bar1 hardening, on next real recovery). **Kernel 7.0.12 update**
  (post-soak, validated). **Upstream** C7+C8 (HELD). **Injector branch→main merge** (pending soak).

## Standing constraints + the discipline that bit/helped this session
- No Claude/AI attribution. Subagents on opus. Upstream HELD. **I run ON obpc — wet/live-wedge work is
  operator-at-console with capture armed; it resets the soak.**
- **DON'T-GIVE-UP** ([[feedback-dont-give-up-pursue-creative-solutions]], new this session): on an
  unfavorable result, attack the controllable variable before concluding a path dead (the FLR was
  "doomed" by 3 source workflows, then PASSED live; cycle-2 "dead" was actually a settle-time variable).
  COMPLEMENT to the don't-over-claim-SUCCESS guards — hold both; obey test-live + n≥3.
- **E27 experiment safety (paid for in resets):** run `recover=0`; **fail-safe `rmmod` on init-fail, NEVER
  retry `nvidia-smi` on a desynced chip** (that caused the platform reset); `modprobe --ignore-install`;
  the size relatch needs a reset (FLR maybe-with-settle, or slot-cycle).

## Where everything is
- **E27 finding (the saga, full detail):** `finding-2026-06-13-E27-halfb-determinism-verdict.md`
  (banners + INVESTIGATION RESULT + E1/E2 LIVE RESULT + E2 CYCLE-2 FORENSICS). **Register:**
  `experiment-register.md` #2 (E27, current status at the head). Captures: `/root/netconsole-stage01-new.log`
  (E1 wedge); the cycle-2 evidence is in `journalctl -b -1` (not persisted past 19:07:41 — the platform
  reset was abrupt; the `.241` log has the final moments if the operator kept it).
- **Module + harness:** `tools/e27-bar1-rearm/` (`.c` + Makefile + README + `run-experiment.sh`). Real
  7.0.9 PCI source for analysis: `/root/linux-7.0.9-pci`.
- **#304/#305:** `tools/fix-bar1.sh`. **#292 recover-disabled control:** in the apnex.32/33 handover +
  register #292.
