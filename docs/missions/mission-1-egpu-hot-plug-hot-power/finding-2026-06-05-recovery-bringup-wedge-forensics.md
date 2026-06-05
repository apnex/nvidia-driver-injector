# Forensics — recovery bring-up wedge (2026-06-05) [v3 — CAPTURED + adversarially verified]

> **v3 (2026-06-05, latest):** the Path-B wedge was **captured** (netconsole) and the mechanism
> **corrected** — it is the **in-flight re-OPEN RM bring-up deadlock**, NOT a close-path teardown and NOT
> the AER/bus-reset path (an interim bus-reset claim is retracted). Jump to **"CAPTURED (v3)"** below.
> v1/v2 history is preserved underneath for provenance.

**Event:** silent host wedge during a runtime surprise-removal **recovery** (fix-bar1 `--bind`) on
apnex.30. ~10:43:46 AEST, boot −1. 2 reboots; GPU since powered off.

> **CORRECTION (v2):** the v1 conclusion ("physical replug recovery isn't robust / needs cold-plug",
> "12-cycle churn caused it", "draining the injector + legacy persistence caused it") was **WRONG** —
> operator pushed back that runtime re-plug recovery worked yesterday, and the evidence confirms it.
> See "What v1 got wrong" below. The mechanism (deferred post-close hang) holds; the *framing* was an
> over-generalisation.

**One-line root cause:** the host hit the **known, non-deterministic #292 close-path wedge** (a hang in
deferred kernel work after a LAST-CLOSE on a userspace-recovered chip) on the **2nd close** of an
otherwise-normal `fix-bar1 --bind`. Runtime re-plug recovery **works reliably most of the time**
(yesterday ×3 in boot −3; #289 n=5) — today it hit the low-probability tail. **NOT a regression, NOT a
deterministic procedural error, NOT evidence recovery is broken.**

---

## What actually happened (boot −1)
1. **~10:39:59 — SURVIVAL (cable yank): clean PASS** (Xid 154 + A7 bounded shutdown completed; host
   survived). Unchanged from v1 — survival is solid.
2. **~10:43:34 — RECOVERY:** replug → TB `0-1` re-auth → GPU re-enumerated (broken BAR1 256 MiB) →
   `fix-bar1 --bind`. **HW recovery WORKED** (snapshot E: BAR1=32768, CTRL `0x00000f21`, bridge window
   full, nvidia bound).
3. **10:43:43–46 — the bind sequence (NOT a churn):** after the slot-cycle, **2** cold-init opens
   (fix-bar1's `nvidia-smi -pm 1` then `nvidia-smi -L`), each `[F40b]: open completed within budget
   rc=0` (A12 funnel fine), each followed by a LAST-CLOSE. Chip **alive** (`PMC_BOOT_0=0x1b2000a1`,
   WPR2 up — not dead-bus).
4. **10:43:46 — FREEZE** on the 2nd close. Last line = `close-exit usage_count=0 (LAST-CLOSE)` (callback
   returned), then silence. No Xid, no panic, **pstore empty**.

## Decisive evidence (unchanged, accurate)
- **All bounded workers completed** (open 12/12 whole-boot, rm_shutdown 2/2, rm_disable 2/2) → not a
  bounded-wait hang; A6/A7/A12 all worked.
- **Last op = `close-exit` (callback returned), then freeze** → hang is in **deferred kernel work after
  the close** (= PINPOINT-1).
- **Chip alive, not dead-bus** → the dead-bus short-circuit (which saved the yank) doesn't apply.
- **Silent freeze + pstore empty** → the un-instrumentable eGPU wedge; the *exact* hung deferred op is
  unrecoverable (which is why #292 is open).

## Root cause
The userspace-recovered chip carries the PCIe-equalization-status divergence. On a LAST-CLOSE of that
**alive-but-diverged** chip, closed RM can treat it as a removal candidate and the **post-close deferred
teardown can hang** → silent host freeze. This is the **#292 hard-wedge gap**, documented as
**NON-DETERMINISTIC** ("cycle-2 wedged, cycle-4 didn't"; `project_mode_b_root_cause_open` converged on
*no single fixable cause*). Today it fired on the 2nd close; yesterday (×3) it did not. The wedge is a
**low-probability tail event of an otherwise-working recovery**, not a deterministic outcome.

## What v1 got wrong (the correction)
- ❌ **"12-cycle churn caused it."** The recovery window had **2** opens + **2** LAST-CLOSEs. The "12"
  was the whole-boot total. No churn.
- ❌ **"Draining the injector + legacy persistence caused it."** The injector uses the **same** legacy
  `nvidia-smi -pm 1` (entrypoint.sh:809); yesterday's working recoveries ran the same way. My drain
  meant only fix-bar1 touched the GPU — it did not add churn.
- ❌ **"Physical replug recovery isn't robust / needs cold-plug."** FALSE — boot −3 shows **3** runtime
  fix-bar1 recoveries that worked and ran for hours; #289 validated it n=5. Recovery works.
- ✅ **What holds:** the *mechanism* (deferred post-close hang on the diverged chip = #292), survival is
  solid, and A12/A6/A7 all did their jobs.

## Honest unknowns (do NOT over-claim)
- **Why today vs yesterday** is not pinned. It is consistent with #292's documented non-determinism. One
  **untested hypothesis**: today was a *cable-yank* (chip stayed powered → warm/EQ-diverged) whereas some
  of yesterday's recoveries may have been colder (chassis power-cycle / TB-reauth) — a warm-diverged
  close path *may* be more wedge-prone. **Not established** — flagged for the recovery design to test,
  not asserted.
- The **exact deferred kernel op** that hung is not visible (silent freeze, pstore empty, kdump can't
  capture — drgn-passive only). Consistent with prior #292 investigations.

## Implication for the recovery design (v4)
This is real evidence that **robust runtime recovery is exposed to the #292 non-deterministic close-path
wedge** — so #292 (in-driver containment of the diverged-chip LAST-CLOSE) is the **load-bearing
prerequisite** for *reliable* (not just usually-works) no-reboot recovery. The recovery design should
(a) keep the adapter **held** through recovery (minimise LAST-CLOSE events on the freshly-recovered
diverged chip), and (b) treat #292 as the gating dependency — and may want to characterise the
warm-yank vs cold-cycle hypothesis on fake-5090 (#290) rather than live.

---

# CAPTURED (v3, 2026-06-05) — Path-B deliberate-wedge: the instrumented twin

> **What v3 adds:** v1/v2 said the exact hung op was *"un-instrumentable (silent freeze, pstore empty,
> kdump can't capture)."* **That is now superseded.** A later, deliberately-triggered persistence-OFF
> LAST-CLOSE roll (the "Path-B" experiment, 2026-06-05T06:12Z) was captured **passively via netconsole**
> — the printks flushed before the CPU wedged. The capture is archived at
> `captures/netcon2-2026-06-05-292-pathB-wedge.log` (and the separate E27 boot at
> `captures/netcon-2026-06-05-E27-coldchassis-retest.log`). This section was **adversarially verified**
> (8-agent workflow, 3/3 skeptics; source-grounded against `patches/addon/A3-recovery.patch` and this
> host's `/root/linux-v6.19/drivers/pci/pcie/err.c`).

## RETRACTION (mechanism, not locus)
An interim claim this session — *"the wedge is our `tb_egpu recover` handler → NEED_RESET **scheduling a
secondary bus reset** → the bus-reset/re-enumeration of the TB-tunneled chip wedges the host"* — was
**WRONG on the primitive and is retracted.** The **locus** (post-close, on the diverged chip) was right;
the **named primitive** (a PCIe bus reset / our recover code) was not. See "what survives / what's
retracted" below. (Third over-generalisation caught-and-corrected this session; the discipline holds.)

## The captured sequence (uptime seconds; `netcon2…pathB-wedge.log`)
| t (s) | event |
|---|---|
| 3373.432 | marker: `#292 PATH-B DELIBERATE WEDGE … persistence about to be disabled` |
| 3472.155 | open scheduled → **completed rc=0** (the `nvidia-smi -pm 0` open) |
| 3472.168994 | `close-entry usage_count=1` **(LAST-CLOSE)**; probe `WPR2=0x07f4a000 wpr2_up:YES` |
| 3472.197491 | `rm_disable_adapter` **completed in budget** (~28 ms) |
| 3472.834715 | `rm_shutdown_adapter` **completed in budget** (~637 ms GSP unload) |
| 3472.834766 | post-shutdown probe `WPR2=0x00000000 wpr2_up:no` (GSP cleanly torn down) |
| 3472.834772 | **`close-exit usage_count=0` (LAST-CLOSE) — close callback RETURNED CLEANLY** |
| 3472.870770 | a **new open** scheduled (next `nvidia-smi -L`) — **never logs "completed"** |
| 3473.887623 | **AER Uncorrectable (Non-Fatal) from 04:00.0** — `[14] CmpltTO (First)`, UESta=`0x00004000` |
| 3473.889–891 | `tb_egpu recover: error_detected` → `NEED_RESET` then (H2-rate-limited) `DISCONNECT`; `AER: device recovery failed` |
| 3473.937751 | `nvidia 04:00.0: external GPU detected` ← **last line; netconsole silent; host wedged** |

## What survives / what is retracted (verified)
**SURVIVES:** The NVIDIA **close path is not the wedge** — LAST-CLOSE completed cleanly, fully in-budget,
GSP torn down (WPR2→0). The wedge is **post-close**: the re-open at 3472.870 never completes.

**RETRACTED — no bus reset ran, our recover code is exonerated:**
- `nv_pci_error_detected` (A3:114-219) executes **no reset**; on GATE_OK it only *returns*
  `PCI_ERS_RESULT_NEED_RESET` (A3:162). "scheduling bus reset" is a **log string, not an action.**
- The kernel AER core (`err.c`) **never reaches** `reset_subordinates`/SBR: the audio function `04:00.1`
  has no handler → votes `NO_AER_DRIVER`, which is **sticky in `merge_result` and dominates** NEED_RESET
  → merged status aborts to `failed:` → `AER: device recovery failed`. The 28 µs NEED_RESET→failed gap
  is far too fast for a real SBR (ms-scale hold + ~100 ms-1 s link retrain); **zero**
  slot_reset/`PMC_BOOT_0`/RECOVERED/resume/Link-Up lines exist in the window.
- The trailing `external GPU detected` (`RmCheckForExternalGpu`, E1) is an **OPEN-path fingerprint, not a
  re-enumeration probe** — genuine re-enum probes are always preceded by `enabling device (… -> …)`; this
  one is not, and it follows the un-completed re-open of 3472.870. It is the bounded open worker reaching
  `RmInitNvDevice` inside the **still-in-flight re-open**, then hanging.

## CORRECTED ROOT CAUSE (#292)
The wedge is the **in-flight re-OPEN hanging in RM GSP-lockdown bring-up on the torn-down/EQ-diverged
chip** — `RmInitAdapter → kgspBootstrap_GH100 → gpuTimeoutCondWait(_kgspLockdownReleasedOrFmcError)`
busy-polls forever **holding the GPU group lock**. The CmpltTO AER and the A1/A3 recover handler are
**downstream observers**, not the cause (handler ran correctly, µs-fast, surrendered via DISCONNECT; the
kernel reset nothing). This **confirms and sharpens** v2's "deferred post-close hang = re-open
`RmInitAdapter` deadlock," and inverts the interim bus-reset claim — corroborated by **R4
(experiment-register.md:37)**: SBR/FLR/slot-cycle on *this exact diverged chip* are **CONTAIN-ONLY, host
survives** (a reset is the *least* likely wedge primitive).

**Reconciliation with the CURRENT source (precise mechanism — supersedes the 06-02 "API-lock inversion"
reading).** The 2026-06-02 origin framed this as an RM-API-lock inversion; the **current `nv.c`
(post-C6; comments at nv.c:1950-1959 and 2023-2027) corrects that as FALSE.** Under relaxed GSP init
locking (default on this 5090) the worker **releases the RM API lock** (`kernel_gsp.c:4785`) before the
bootstrap poll and holds only the **GPU group lock**. The real wedge is **`nvl->ldata_lock`, held by the
foreground re-open (`__nv_start_device_locked`) across an unbounded `flush_work` of the stuck worker**,
where **any second `ldata_lock` contender (rmmod / close / AER `error_detected`) hard-wedges the host
(F44).** The deployed **A12 / A10-v2** path already *bounds the LOCKDOWN arm*: at `timeout+grace` it sets
the **lock-free `os_pci_set_disconnected` marker** so the worker's GSP poll cond
(`_kgspLockdownReleasedOrFmcError → osIsGpuBusDead → 0xFFFFFFFF`) self-terminates and the flush joins in
~ms (nv.c:1983-2028); C1/C6 keep `rm_cleanup` non-blocking.

**The residual gap this 06-05 capture exposes (the actual #292 work):** the wedge fired at **~1.07 s —
inside the in-flight bounded-wait window, *before* the 3000 ms timeout** — because the re-open's MMIO
touch raised an **AER CmpltTO (~1.02 s)** and `nv_pci_error_detected` became the **second `ldata_lock`
contender before the timeout+grace discriminator could run.** The **first** `error_detected` fire returns
`NEED_RESET` and sets **no** lock-free marker (nv-pci.c GATE_OK path, nv-pci.c:2963-2974), so nothing
frees the stuck worker early; the rate-limited second fire then calls `rm_cleanup_gpu_lost_state`
(nv-pci.c:2998) which contends `ldata_lock`. **Fix direction:** have `error_detected` set the lock-free
dead-bus marker **early** when a bootstrap worker is in-flight (reuse the A10-v2 marker, triggered by the
AER signal — the correct signal, the chip genuinely CmpltTO'd), so the in-flight re-open self-heals before
any `ldata_lock` contention; and/or **fail-fast the diverged re-open at the A12 funnel** before the
chip-touch. **Precondition:** requires a **#979-EQ-diverged** chip — a *clean* cold-plug re-opens fine, so
reproducing needs a diverged chip (yank + `fix-bar1` first), not a fresh cold-plug.

**Key A12 caveat (new):** the A12 bounded-open funnel does **not** save this — its 3000 ms
`wait_for_completion_timeout` bounds only the **caller**; the **worker thread** can spin in the lockdown
poll holding the GPU group lock past budget, and the host died at 3473.937 (before the
3472.870+3000 ms≈3475.87 deadline), so no budget-exceeded line ever printed. **Bounding the caller ≠
bounding the lock-holding worker.**

**Still uncertain (one narrow fact):** netconsole is passive (no stack). "Worker spins in
`gpuTimeoutCondWait` holding the GPU group lock" is inferred from the open-path fingerprint + the
2026-06-02 origin trace + R4 — not from a captured wedged-CPU stack. §"Next capture" closes it.

## RE-SCOPED #292 (replaces "NVIDIA close-path containment")
> **#292 — Re-open into RM GSP-lockdown bring-up deadlocks on an EQ-diverged TB-tunneled chip.** After a
> clean persistence-OFF LAST-CLOSE (WPR2→0) on a chip whose PCIe equalization diverged from a prior
> userspace recovery, the *next* `open()` schedules a bounded worker whose RM bring-up
> (`RmInitAdapter → kgspBootstrap_GH100 → gpuTimeoutCondWait`) busy-polls forever holding the GPU group
> lock; its early MMIO touch CmpltTOs (a *symptom*), the AER core logs-and-aborts (no reset — the audio
> fn's `NO_AER_DRIVER` vote suppresses `reset_subordinates`), and the host wedges. A **re-open / RM
> bring-up** containment problem — NOT a close-path and NOT an AER-reset problem.

**Repro (near-deterministic, roll-1):** diverged live 32 G chip, `NVreg_TbEgpuRecoverEnable=1` → arm
netconsole+sysrq → `nvidia-smi -pm 0` → drive LAST-CLOSE (`close-exit … wpr2_up:no`) → one more open
(`nvidia-smi -L`). The next open wedges.

## FIX OPTIONS (ranked) — fix the re-open gate, not the AER state machine
- **F1 (primary) — gate/bound the post-teardown re-open.** At the A12 `nv_bootstrap_bounded` /
  `nv_start_device` funnel: if external **and** last-seen WPR2→0 from a persistence-OFF LAST-CLOSE **and**
  EQ-diverged, **fail the open fast (-EIO)** instead of entering the lockdown busy-poll; and make
  `gpuTimeoutCondWait(_kgspLockdownReleasedOrFmcError)` **cooperatively abortable** so the worker can't
  spin holding the GPU group lock past budget. Removes the only confirmed wedge.
- **F2 (strong, cheap) — quiesce/mark-surprise-removed before teardown-then-reopen** on a diverged chip
  (`pci_dev_set_io_state`/our surprise-removed flag) so the next open is rejected at the boundary →
  clean `-ENODEV`. Pairs with F1.
- **F3 (defense-in-depth) — A3 go straight to DISCONNECT on a post-shutdown/diverged chip with CmpltTO**
  (guard at the GATE_OK branch A3:153-163; dispatch the existing C5 sink). Removes reliance on the
  *accidental* audio-fn `NO_AER_DRIVER` vote to suppress a reset on other topologies; also drop the
  `last_fire_jiffies` stamp from GATE_OK (A3:160) that creates the misleading H2 DISCONNECT line.
- **F4 (hardening) — bound `tb_egpu_recover_slot_reset`'s `ioread32(PMC_BOOT_0)` (A3:901-905)** in case a
  topology ever reaches slot_reset. Low priority.
- **Do NOT** treat `NVreg_TbEgpuRecoverEnable=0` as the fix — it only prevents NEED_RESET; the wedge is in
  the re-open and fires regardless.

## NEXT CAPTURE (the one decisive experiment) — keyboard SysRq is DEAD on this host
1. **Recover-disabled control (cheapest, run first):** repeat Path-B with `NVreg_TbEgpuRecoverEnable=0`
   (error_detected → DISCONNECT immediately, kernel never contemplates a reset). **If it still wedges
   identically at the in-flight open → conclusively the re-open; AER/reset fully exonerated** (expected).
2. **Definitive stack:** arm a **kernel-side** task dump (userspace watchdog on a pinned non-GPU cpuset
   writing `t`/`l`/`w` to `/proc/sysrq-trigger` on open-completion-loss, → the already-armed
   netconsole). Predict: open worker in `RmInitAdapter → kgspBootstrap_GH100 → gpuTimeoutCondWait`
   holding the GPU group lock — **not** in `pci_bridge_secondary_bus_reset`/pciehp.
3. **Move off the live host:** reproduce on **fake-5090 (#290)** (GSP-lockdown busy-poll stub +
   EQ-diverged flag) to iterate F1/F3 without live wedges.

---

## Current state + safe path (updated 2026-06-05 ~17:0xZ)
- **GPU cold-plugged and HEALTHY** (BAR1=32768 MiB, TB `0-1 authorized`); **injector un-drained →
  apnex.30 loaded, persistence engaged** (P8 / ~33 W / cooler 41%); **apnex.30 soak resumed.**
- **Capture DISARMED** (netconsole removed; sysrq persistence drop-in removed; runtime `sysrq=1` resets
  next reboot).
- #292 reproduction is **deliberate and live-wedging** — do it only with the §"Next capture" tooling
  armed, or on fake-5090 (#290). Cold-plug remains the reliable 32 G path; runtime recovery is gated on
  #292 (re-open) + E27 (bridge window — separate doc).
