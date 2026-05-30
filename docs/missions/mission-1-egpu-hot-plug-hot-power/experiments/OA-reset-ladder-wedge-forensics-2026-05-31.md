# Forensics — reset-ladder R0.5 host wedge (2026-05-31)

**Status:** ROOT CAUSE CONFIRMED (adversarially verified). Host recovered (2 reboots). No lasting damage.
**Series:** Open-Arm (OA), task #282. Triggered by the first run of the reset-efficacy ladder (`OA-reset-efficacy-ladder.md`), variant R0.5 (rebind-only).
**Headline:** a host hard-wedge that exposed a **real coverage hole in A6** — *A6 does not guard the first open of any bind* — not just an experiment artifact.

## What happened (timeline, from fsync'd markers + wedge-boot journal)

```
unbind nvidia       → OK            (markers + journal got past it)
rebind nvidia       → OK            (driver=nvidia, "vgaarb: VGA decodes changed")
pre-cycle2 BAR1=32768 driver=nvidia → chip bound, BAR1 healthy, D0-pinned, AER=0
cycle-2 FIRE (exec open /dev/nvidia0) ← LAST MARKER. No "cycle-2 RETURNED". WEDGE.
```

The host did **not** die in the unbind/rebind machinery — it got cleanly past both. It died at **cycle-2's open**, the same open A6 contained 4/4 in Lane 2.

## Root cause (confirmed)

**A6 was bypassed because `nv->is_external_gpu` was FALSE on the post-rebind open.**

- **A6's gate** (`nv.c:1862-1867`): `if (timeout==0 || !nv->is_external_gpu) return nv_open_device_for_nvlfp(...)` — i.e. it falls through to the **raw synchronous open** (no bounded worker) when `is_external_gpu` is false. `timeout` was 200 (live), so the failed gate was `is_external_gpu`.
- **`is_external_gpu` is set in exactly one place** — `osinit.c:1301`, inside `RmInitNvDevice`, which runs **during `rm_init_adapter`** — i.e. *partway through the first open of a bind*. A fresh `nv_state_t` is zeroed at probe (`nv-pci.c:1969`); the flag is **never cleared**.
- ⇒ **A6 cannot guard the first open of any bind.** It only protects the 2nd+ opens within one bind (after the first open's `RmInitAdapter` set the flag).
- **Differential proof:** in cycle-1 (modprobe-bound) the journal shows "external GPU detected" *preceding* the first "open scheduled to bounded worker" — the first open ran synchronously-but-on-a-healthy-chip (no wedge), subsequent opens got the bounded path. After unbind→rebind, `is_external_gpu` is back to FALSE, so cycle-2 is the **first open of the new bind → synchronous → on a BAD chip → wedge**.

**Why it hard-wedged (uncontained):** the synchronous open ran `RmInitAdapter` → the GSP lockdown-release busy-poll (the Lane-2 Rung-4 confirmed site, `kgspBootstrap_GH100 → gpuTimeoutCondWait(_kgspLockdownReleasedOrFmcError)`) on the syscall thread, holding the GPU group lock for its full multi-second duration → host deadlock. (The locus is *inferred* from Lane 2 — `pmu.log` was 0 bytes this run, bpftrace never flushed.)

## Evidence chain
1. `markers.log` ends at `cycle-2 FIRE`, no `RETURNED` — the syscall **never returned**. A6's `wait_for_completion_timeout` always returns at 200 ms, so had A6 engaged the syscall would have returned → no engage.
2. `nv.c:1866` — the gate falls through to synchronous when `!is_external_gpu`.
3. `osinit.c:1297-1302` — the *only* assignment of `is_external_gpu = NV_TRUE`, inside `RmInitNvDevice` (runs during the first open's `RmInitAdapter`); `nv-pci.c:1969` zeroes it at probe.
4. Journal: A6 engaged on cycle-1 (modprobe-bound); no bounded-worker line for the post-rebind cycle-2 (flush stopped at sampler-start, 1 s before the wedge).
5. `snap-post-reset-pre-cycle2.txt`: BAR1=32768, `tb_egpu_state=healthy`, AER=0 — **not** a BAR1-failure wedge; genuinely the GSP/lockdown site on a known-good chip.

## Implications

1. **The reset-ladder is unsafe AND unmeasurable as designed.** R1/R2/R3 all do unbind→reset→rebind, so cycle-2 is always a first-open → A6 bypassed regardless of reset depth. The "A6 net → every non-curing variant survives" claim is **false for every variant**. Worse, even if a deeper reset *cured* the chip, you couldn't distinguish "cured" from "wedged-before-A6-could-contain." The ladder belongs in the **destructive reboot-loop**, redesigned (see Fixes).
2. **The H-OA6 datapoint is confounded, n=1.** Consistent with H-OA6 (lock-holding busy-poll deadlocks the host) but A6 was bypassed by an *artifact* (rebind), not the intended `OpenTimeoutMs=0` lever; `pmu.log` empty. Suggestive, not the clean test. The clean H-OA6 test remains Lane-3 Rung-8.
3. **A6 first-open coverage hole — a real, production-relevant defect** (the most important finding): the first open after *any* (re)bind is unguarded. Cold-boot / fresh-modprobe first opens are unguarded too (they don't wedge only because the chip is clean). Anything that re-probes the driver on a *bad* chip (PCI error recovery, A3's `slot_reset`/`pci_reset_bus` re-probe paths, hotplug, manual rebind) makes the dangerous re-init the unguarded first open. **This is a patch-review-grade A6 robustness gap.**

## My design error (owned)

I claimed the reset-ladder was "survivable, A6 as the safety net." That was wrong, and it cost two reboots. The unbind/rebind the ladder uses to apply a reset is *exactly* what disengages A6 — and the deeper reason (A6 never guards a first open) means I asserted "survivable" without verifying A6 survives a rebind. Discipline lesson: **verify the safety-net invariant holds across the experiment's own scaffolding before calling it survivable.**

## Fixes / follow-ons

- **Shipped (source, not deployed):** `tb_egpu_is_external` sysfs attribute (A8 v2.2) — makes A6/A7 armed-state observable; enables a **pre-flight guard** (read it before any chip-touching open; abort if `0`) and a **non-destructive root-cause confirmation** (read before/after a rebind on a healthy chip).
- **A6 coverage-hole fix candidates** (patch review, not yet implemented): (a) establish `is_external_gpu` at **probe** time (run the E1 classification / force-flag before the first open) so the first open is guarded; (b) have A6 gate on a probe-time-available signal (TB-tunnelled topology) instead of a lazily-set flag. Either closes the hole.
- **Reset-ladder redesign:** drop the "A6 net" premise; run it in the reboot-loop OR gate every first-open on `tb_egpu_is_external` (after the attr deploys) so it aborts instead of wedging; resolve the BAR1-bridge-window coupling (FLR/SBR break BAR1, only slot-cycle restores) — see `OA-reset-efficacy-ladder.md`.

## Cross-refs
`OA-reset-efficacy-ladder.md` (the experiment; now marked unsafe) · `open-arm-forensics-ledger.md` (Lane 2 site; the "A6 placement validated" claim now carries the first-open caveat) · `docs/patch-intents/A8-f40b-sysfs-observability.md` (v2.2) · run dir `/var/log/mission-1-archaeology/resetladder-rebind-hz4999-20260530T082930Z/`.
