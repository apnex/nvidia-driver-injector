# Session handover — 2026-06-05 — surprise-removal recovery testing (READ FIRST)

## ⮕ ADDENDUM (2026-06-05 PM — supersedes the TL;DR below)
The session that wrote the TL;DR died on a repeated cyber-safeguard API error mid-forensics; a follow-up
session recovered its lost progress from the transcript + two netconsole captures and **corrected the
#292 root cause**. Net new state:
- **GPU is HEALTHY again (cold-plugged):** BAR1=32768 MiB, TB `0-1 authorized`. **Injector un-drained →
  apnex.30 loaded, persistence engaged** (P8 / ~33 W / cooler 41%); **apnex.30 soak RESUMED.** **Capture
  DISARMED.** (The TL;DR's "GPU OFF-BUS / injector DRAINED / capture ARMED" is now obsolete.)
- **#292 CAPTURED + RE-ROOT-CAUSED (verified, 3/3 adversarial):** it is the **in-flight re-OPEN RM
  GSP-lockdown bring-up deadlock** (`RmInitAdapter → kgspBootstrap_GH100 → gpuTimeoutCondWait` spinning
  while holding the GPU group lock), **NOT** a close-path teardown and **NOT** the AER/secondary-bus-reset
  path. The close completes cleanly; the CmpltTO AER is a *symptom* of the hung re-open; our `tb_egpu
  recover` handler is **exonerated** (the kernel reset nothing — audio-fn `NO_AER_DRIVER` vote aborts
  recovery). An interim "bus-reset wedges the host" claim was **retracted**. A12 bounds the *caller*, not
  the lock-holding *worker* — that's why it didn't save it. Full writeup:
  `finding-2026-06-05-recovery-bringup-wedge-forensics.md` **§CAPTURED (v3)**.
- **E27 pinned + documented** (separate, graceful, NON-wedging): intermediate TB bridge `02:00.0` gets
  only a 256 MiB prefetch window → 32 G child can't fit. `finding-2026-06-05-E27-intermediate-bridge-window.md`.
- **Captures archived:** `captures/netcon2-…-292-pathB-wedge.log`, `captures/netcon-…-E27-coldchassis-retest.log`.
- **Decisive next experiment** (settles the one residual): re-run Path-B with `NVreg_TbEgpuRecoverEnable=0`
  (cheap control — if it still wedges, re-open is conclusively the cause); then a kernel-side
  `/proc/sysrq-trigger` task dump (keyboard SysRq is dead) for the worker stack; then port to fake-5090
  (#290). Fix lands at the **re-open gate** (F1/F2), not the AER state machine (F3/F4 are defense-in-depth).
- **Tasks:** #292 re-scoped (see finding). **E27 needs a tracking task.** #304/#305 (fix-bar1 P1 BAR1=0
  false-success / P2 COMMAND-decode self-heal) still queued.

---

## TL;DR — current state (⚠ SUPERSEDED by the addendum above — kept for provenance)
- **GPU is OFF the bus.** TB `0-1` `authorized=0` (tunnel down), PCI `0000:04:00.0` absent, nvidia not
  loaded. **Host is HEALTHY** (up ~4h, no wedge, no Call-Trace/hung signs).
- **Injector is DRAINED** (DS nodeSelector `oa.recovery-drain/excluded`, desired=0 — persisted across
  reboots; that's why no driver loads).
- **Capture is ARMED** (sysrq=1 persisted via sysctl.d; netconsole → `192.168.1.241:6666` enabled).
- **Reliable recovery = COLD-PLUG** (reboot NUC with GPU attached). Runtime recovery is exhausted and
  will not reach 32 GiB from the current degraded/off-bus state.
- apnex.30 (A12 funnel) was **interrupted** by this test (injector drained); resume its soak after the
  cold-plug + un-drain.

## What this session did
1. **(Earlier) A12 complete GSP-bootstrap funnel** — implemented, deployed **apnex.30**, fastfail-validated
   3/3, catalog reconciled, polished. **DONE** (see the A12 handover/finding). H-OA2 closed.
2. **Surprise-removal design pass-1** (ultracode) → reframe: the host-*survival* half is already closed;
   the open work is *recovery*.
3. **Recovery design pass-1** (ultracode) → corrected baseline: validated userspace recovery already
   exists (`fix-bar1.sh` + TB re-auth + #289 n=5). Winner: v4 orchestrate-now/converge-in-driver.
4. **LIVE surprise-removal test:**
   - **SURVIVAL (physical cable yank): PASSED, clean.** A2 watchdog → C5 v4 sink → A7 bounded shutdown
     (in budget) → host survived, GPU cleanly removed. Fresh apnex.30 confirmation.
   - **RECOVERY (fix-bar1 --bind): hit the #292 close-wedge** → silent host freeze → 2 reboots.
   - Forensics written + **corrected** (operator pushback): it's the *non-deterministic* #292 wedge, NOT
     "recovery isn't robust / needs cold-plug" — that framing was retracted.
   - **Capture armed** (netconsole + sysrq) for a #292 reproduction; verified flowing to the receiver.
   - **Runtime power-on retest (cold chassis): NO wedge** (cold path), but recovery **failed on
     bridge-window allocation**; tried fix-bar1 ×2, TB-reauth, native ReBAR-resize ×2 — all failed; GPU
     dropped off-bus.

## KEY FINDINGS (the real value — feed the recovery design + reviews)
1. **Survival is solid (live, apnex.30).** Real yank + persistence holding → bounded clean teardown,
   host survives. The surprise-removal *host-wedge* class is closed.
2. **#292 close-wedge confirmed LIVE.** Recovering a userspace-recovered (warm/EQ-diverged) chip can hang
   in **deferred kernel work AFTER the final LAST-CLOSE** — silent, non-deterministic, un-instrumentable
   by hung_task (compiled out). A6/A7/A12 bounded-waits ALL completed in-budget; the hang is *after* the
   close callback returns. NOT a regression. (finding-2026-06-05-recovery-bringup-wedge-forensics.md v2.)
3. **THE E27 BOTTLENECK — pinned precisely.** The 32 GiB prefetchable window IS reserved at the root
   pciehp port `00:07.0` (`[0x4810000000–0x500fffffff]` = 32 GiB, ~31.75 GiB free), but the
   **intermediate TB bridge `02:00.0` only claims 256 MiB of it** — so the GPU (under `03:00.0` under
   `02:00.0`) gets "can't assign; no space" for its 32 GiB BAR1. **No runtime lever grows `02:00.0`:**
   the slot-cycle only re-assigns at the GPU/`03:00` level; TB-reauth rebuilds the window but still at
   256 MiB; the kernel-native ReBAR resize (`resource1_resize`, supports 32 GiB) **EINVALs** because the
   repeated failed 32 GiB attempts left BAR1 fully *unset* (flags=0). ⟹ **E27 must propagate the 32 GiB
   budget through the INTERMEDIATE TB bridges, not just the root/leaf.**
4. **Two runtime-recovery failure modes, both live-confirmed:** (a) #292 close-wedge (recovery *succeeds*
   to 32 GiB then wedges on close); (b) bridge-window allocation failure (recovery *can't reach* 32 GiB).
   Both ⟹ cold-plug is the only *reliable* 32 GiB path — but runtime IS possible (worked earlier today +
   #289 n=5), just unreliable; **E27 is the reliable-runtime fix, #292 is the close-path containment.**
5. **fix-bar1 bug:** mishandles BAR1=0 (float arithmetic "9.53674e-07", falsely prints "✓ recovered"
   instead of failing fast → proceeds to a guaranteed-failing modprobe). Fix queued.
6. **Correction discipline note:** I over-generalized twice this session ("needs cold-plug", "impossible
   at runtime") and retracted both on operator pushback. Both retractions are in the forensics doc.

## RECOMMENDED NEXT STEPS
1. **Recover the GPU — COLD-PLUG:** power the GPU on (chassis), then reboot the NUC with it attached →
   clean 32 GiB. (Do NOT keep trying runtime recovery from the off-bus state.)
2. **Un-drain the injector** post-cold-plug so apnex.30 auto-loads + the soak resumes:
   `kubectl patch ds nvidia-driver-injector -n kube-system --type=json -p
   '[{"op":"remove","path":"/spec/template/spec/nodeSelector/oa.recovery-drain~1excluded"}]'`
3. **Disarm capture** if not immediately retesting: `tools/oa-harness/arm-wedge-capture.sh disarm`.
4. **#292 forensics (still uncaptured — the original goal):** from a clean cold-plugged 32 GiB baseline,
   do the **WARM cable-yank → fix-bar1 recovery** (the wedge-prone path), capture armed (tooling +
   sysctl.d persist). The COLD runtime power-on does NOT trigger #292.

## Design implications (recovery design v4 + the review phase)
- **#292** (in-driver close-path containment on a diverged chip) and **E27** (multi-level runtime
  bridge-window regrow — grow the intermediate TB bridge) are BOTH load-bearing for *reliable* no-reboot
  recovery. Today's live data sharpens both.
- v4 (orchestrate-now/converge-in-driver) holds, with the hard caveat: robust runtime recovery is gated
  on #292 + E27; until then cold-plug is the reliable fallback for the physical-replug case. Consider
  characterising both failure modes on **fake-5090 (#290)** rather than live (each live attempt risks a
  wedge or an off-bus GPU + reboot).

## Standing constraints (persist)
- **Upstream HELD** (deliberate gate). **No Claude/AI attribution.** **Subagents on opus.** Safety on a
  suspect chip: passive-first, no MMIO/nvidia-smi on a wedged/broken-BAR1 chip. **I run ON obpc** — a
  hard wedge kills the session; destructive/disruptive work = human-in-the-loop.

## Where everything is
- This session's forensics: `finding-2026-06-05-recovery-bringup-wedge-forensics.md` (v2 corrected).
- Capture tool: `tools/oa-harness/arm-wedge-capture.sh` (committed `acd5180`).
- A12 / apnex.30: `SESSION-HANDOVER-2026-06-04-END-a12-live.md` + the A12 design-of-record/plan/intent.
- fix-bar1: `tools/fix-bar1.sh` (has the BAR1=0 bug to fix); today's snapshots `/var/log/fix-bar1-20260605*`.
- Tasks: #292 (close-path wedge — live-confirmed), #291 (TB-tunnel recovery isolation), #290 (fake-5090
  substrate — the safe place to reproduce both failure modes). **E27 needs a tracking task** (the
  intermediate-bridge regrow; bottleneck now pinned).
