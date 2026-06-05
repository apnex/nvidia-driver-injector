# Forensics — recovery bring-up wedge (2026-06-05) [CORRECTED v2]

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

## Current state + safe path
- GPU **powered off** (operator); injector **drained** (nodeSelector `oa.recovery-drain/excluded`,
  persisted across reboots — why no driver loads now). Host healthy (boot 0). Nothing urgent.
- When ready: power GPU on, and recovery via the normal path (it works); revert the injector drain:
  `kubectl patch ds nvidia-driver-injector -n kube-system --type=json -p
  '[{"op":"remove","path":"/spec/template/spec/nodeSelector/oa.recovery-drain~1excluded"}]'`.
