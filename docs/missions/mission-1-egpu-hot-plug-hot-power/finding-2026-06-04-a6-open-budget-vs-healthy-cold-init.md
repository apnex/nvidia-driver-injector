# Finding — 2026-06-04 — A6 open budget is shorter than a healthy full cold init

**Status:** OPEN finding (no fix shipped yet). Surfaced by the A10-v2 `fastfail`
live validation (`/var/log/mission-1-archaeology/ra10v2-fastfail-20260604T052224Z`,
3/3 PASS). Feeds task #282 (OPEN-arm A6 root-cause) and proposes a budget/grace
tuning change to A6 + A10. **Not active in the current deployment** (masked by
persistence + injector bring-up ordering) but a real correctness bug for the
A6-bounded open path, and for any consumer without the injector's persistence
workaround (i.e. the upstream-parity target).

## TL;DR

A6 bounds the chip-touching open at `NVreg_TbEgpuOpenTimeoutMs` (default **200 ms**,
chosen as "4× PCIe Completion Timeout" — a *wedge-detection* threshold). A10-v2
then re-waits `NVreg_TbEgpuOpenGraceMs` (default **50 ms**) and, if the worker is
still running, declares the GPU lost and **sinks the bus** (`os_pci_set_disconnected`
+ C5). But a **healthy full cold init** (`RmInitAdapter` / GSP bootstrap) through
the A6-bounded path takes **~1.3 s** — far longer than the 200 ms + 50 ms = 250 ms
ceiling. So a healthy-but-cold open is mis-classified as a stuck lockdown and the
chip is dead-bused, even though the init would have succeeded at ~1.3 s.

The trigger is a normal event: **a client opens `/dev/nvidia0` while the adapter is
not yet initialised** — exactly what lazy init (`NVreg_GpuInitOnProbe=0`) is designed
to do (first client triggers the bootstrap). A CUDA consumer is a first client.

## Evidence

| Fact | Value | Source |
|---|---|---|
| Healthy full cold init through A6 (H-OA1) | **1342 / 1324 / 1328 ms** (n=3) | `fastfail` run 2026-06-04, induced-timeout fires |
| KFENCE control (is 1.3 s a 1ms-KFENCE artifact?) | **No** — shutdown 605 ms (prod, no KFENCE) ≈ 603 ms (test, KFENCE=1ms) | dmesg `rm_shutdown_adapter` deltas |
| A6 open budget (live) | `NVreg_TbEgpuOpenTimeoutMs=200` | `/sys/module/nvidia/parameters` |
| A10 grace (live) | `NVreg_TbEgpuOpenGraceMs=50` | `/sys/module/nvidia/parameters` |
| Budget origin | "200 ms = 4× PCIe Completion Timeout" | A6 intent doc line 15 |
| Init mode (production) | `NVreg_GpuInitOnProbe=0` → **lazy** (first-open init, not probe) | nv-reg.h default 0; A9 design doc "live config is =0"; nv-pci.c:2157 |
| Production A6 opens, all boot | **every** one warm (max delta 0.0 ms; bringups @601/847/6802 s); **0** timeouts; **0** lockdown fires | dmesg |
| A7 precedent (the same bug, already fixed) | shutdown budget bumped **200 → 1200/2000 ms** for a ~600 ms op | task #279 |

## Mechanism (why it sinks a healthy chip)

1. Lazy init (`GpuInitOnProbe=0`, nv-pci.c:2232 `if (nvl->init_on_probe ...)` is
   false). The 1.3 s GSP bootstrap is deferred to the **first open**, via
   `nv_open_device → nv_start_device → rm_init_adapter` (nv.c:1723), **not** the
   probe-time `nv_start_device` (nv-pci.c:2239).
2. That first open, if it is a direct `/dev/nvidia0` open, takes the **H-OA1**
   path — `nv_open_device_for_nvlfp_bounded` (A6-wrapped).
3. A6 trips at 200 ms → A10-v2 grace re-wait 50 ms → at 250 ms the worker is still
   doing a legitimate 1.3 s init → `jiffies_left == 0` → **LOCKDOWN arm** →
   `os_pci_set_disconnected` + `rm_cleanup_gpu_lost_state` → bus dead-bused.
4. The open returns `-EIO`; the worker finishes the init at ~1.3 s onto an
   already-sunk bus. Net: a healthy GPU, sunk by a normal cold open.

## Why it does not fire in the current deployment (and why that is not "handled")

- The injector runs `nvidia-smi -pm 1` (the **H-OA2**, un-A6-bounded path; A9 docs:
  "does NOT cover the H-OA2 pre-`nv_open_device` site") at bring-up, *before* any
  CUDA consumer. The cold init runs off-A6; the adapter is warm by the time any
  A6-bounded `/dev/nvidia0` open happens — hence **0 production A6 timeouts ever**.
- This is a workaround (persistence + ordering), not driver correctness. It breaks when:
  - persistence is not engaged yet / has dropped, **or**
  - a CUDA consumer races the injector during a hot-replug recovery, **or**
  - the patches run on **any deployment without the injector's persistence+ordering**
    — i.e. the upstream-parity goal (Path A); a stock lazy-init host hits H-OA1
    on the first CUDA open routinely.

## Root cause

The 200 ms budget was tuned for the **two** cases the F40b work looked at:
warm opens (µs) and the WPR2 fast-fail bail (~205 ms — caught by the 50 ms grace).
It was **never tuned against a healthy *full* cold init (1.3 s)**, because in the
persistence-engaged deployment that init always ran off-A6 (H-OA2) and was never
observed on the A6 path. The A6 intent's "healthy-path note" (line 17, "completes
well within the 200 ms budget") generalised from **warm** opens — it is correct for
warm opens and wrong for a full cold init. This is the exact twin of the A7
shutdown-budget bug (#279): the open path guards the *longest* operation (1.3 s)
with the *smallest* ceiling (250 ms), and never got the A7 re-tuning.

## Proposed fix (tuning the existing A10-v2 mechanism — no new mechanism)

A10-v2's completion-state discriminator ("worker returned → don't sink") is the
right design; it is simply not given long enough to *see* a healthy worker return.

1. **Raise `NVreg_TbEgpuOpenTimeoutMs` (A6 budget)** above the worst-case healthy
   full cold init so a healthy cold open **completes within budget → open succeeds
   (`rc=0`, no `-EIO`, no sink)** — the stock lazy-init experience. Primary fix.
2. **Raise `NVreg_TbEgpuOpenGraceMs` (A10 grace)** as a secondary net: even if an
   init overshoots the budget, the worker returning routes to **fast-fail (chip
   preserved)**, not lockdown.
3. Headroom à la A7 (1200 ms for a ~600 ms op ≈ 2×). For a ~1.3 s op that is
   ~**2.5–3 s** — *pending a worst-case measurement* (n≥5, including from-cold-boot
   and any H16-transient-affected inits; do not tune to an optimistic sample).

**Tradeoff:** a *genuinely* stuck open is now contained at the (larger) budget+grace
instead of 250 ms — the foreground holds `nvl->ldata_lock` that long. Bounded, and
identical to the tradeoff A7 already accepted at 1200 ms. Still infinitely better
than the original unbounded wedge.

## Measurement result (2026-06-04, task #299)

Expanded sample via `fastfail 10` (`ra10v2-fastfail-20260604T055330Z`) + the
original n=3:

```
n=13: 1319 1321 1323 1323 1324 1325 1327 1328 1331 1335 1324 1328 1342 ms
min 1319 · max 1342 · mean ~1327 · spread 23 ms (±1%)
```

The base GSP-cold-reload init is **deterministic ~1.33 s** (±1%) — the bootstrap
itself is rock-stable. (A10-v2 also re-validated **10/10** in this run.)

**What this sample captures:** GSP firmware cold-reload (rmmod→modprobe→first-open)
with the **TB link stable** (BAR1 healthy, no TB-reauth) and **no concurrent load**.

**What it does NOT capture (the tail that sets the real worst case):**
- from-cold-**boot** init (needs a reboot — operator-driven),
- TB-link-**retrain** init (needs a TB deauth/replug),
- **H16-transient**-affected init (stochastic; the project has seen multi-second
  cold-bringup transients — see [[project-iommu-dmar-finding-2026-05-06]] / the F45
  coldboot RCA),
- init under **production CPU/IO load**.

So **1.33 s is a tight FLOOR, not the worst case.** The budget must sit above the
*tail*, which is uncharacterised here — argues for generous headroom and for using
the A10 grace as the catch-all for slow-but-returning inits.

## Proposed values (for task #300 — needs sign-off)

| Knob | Current | Proposed | Rationale |
|---|---|---|---|
| `NVreg_TbEgpuOpenTimeoutMs` (A6 budget) | 200 ms | **~3000 ms** | 2.25× the 1.33 s floor; a healthy cold init (incl. modest transient) **completes-within-budget → open succeeds rc=0** (stock UX, no -EIO) |
| `NVreg_TbEgpuOpenGraceMs` (A10 grace) | 50 ms | **~2000 ms** | catch-all: a worse transient-slowed init that overshoots the budget still **fast-fails → chip preserved** (-EIO + retry works), not sunk |

Worst-case containment for a *genuinely* stuck open becomes budget+grace ≈ **5 s**
(foreground holds `ldata_lock` that long — bounded; cf. A7 @ 1200 ms). Tradeoff:
bias toward a larger **budget** = more inits succeed outright; bias toward larger
**grace** = more land in (recoverable) fast-fail. The split above favours success.
**Caveat:** if a healthy init under a real transient can exceed ~5 s, even this
sinks it — so the genuinely-robust validation of the tail still wants the fake-5090
F44 model (#290) or a captured transient. The proposed values are a large, safe
improvement over 250 ms, not a proof against the unmeasured tail.

## Part-1 runtime validation (2026-06-04, task #300 part 1)

Ran the runner with the production-candidate config (`FF_TO=3000 FF_GR=2000`,
`ra10v2-fastfail-20260604T060042Z`, n=3). Driver dmesg, all 3 iterations:
`open scheduled to bounded worker (timeout=3000 ms)` → `open completed within
budget rc=0`. Fire `rc=0` (open SUCCEEDED), `tb_state=healthy`, host alive. So with
a 3000 ms budget the healthy cold init **completes-within-budget → open succeeds** —
exactly where the deployed 200 ms budget trips → sinks. Fix behavior CONFIRMED live
(runtime params only; no rebuild yet).

**Tail update — init latency is wider than the first sample.** This run's init
measured **~1.93 s** (1935/1933/1930 ms), vs ~1.33 s in the earlier back-to-back
runs — a real ~45% swing on the same healthy chip, most likely a colder GSP after
the idle gap vs a warm GSP across tight cycles. Confirms 1.33 s was a FLOOR; the
working worst-case so far is **~1.93 s**, and a from-cold-boot init is plausibly
higher. This validates the 3000 ms budget over a tighter 2000 ms (which this 1.93 s
init would have tripped). Open datapoint still wanted: a from-cold-**boot** init
(reboot-gated) measured through the A6 path — run the budget-verify as the first
GPU activity after a reboot.

## Cold-SILICON datapoint — physical chassis power-cycle (2026-06-04)

To capture a true silicon-cold init without a reboot, the operator physically
unplugged the TB cable + powered the AORUS chassis OFF, then ON + replugged (OS
stayed up). This is the ONLY path that genuinely de-powers the GB202 (confirmed:
ReBAR CTRL came back at its power-on default `0x00000821`, the signature of cold
silicon). Replug landed the TB device **unauthorised** (`authorized=0` — physical
replug needs `echo 1 > .../authorized` to establish the PCIe tunnel), then
broken-BAR1 (256 MB / 288 MB bridge), recovered live by `fix-bar1` (→ 32 GB, no
reboot). The driver was fully quiesced first (persistence off → injector drained →
rmmod → `drivers_autoprobe=0`) to avoid the surprise-removal wedge.

**Cold-silicon first-open init = 1199 ms** (induced-timeout, worker rc=0, fast-fail
chip-NOT-sunk, config-vendor 0x10de, host alive, no KFENCE/Xid/lockdown).

Full ladder now:
```
cold-silicon (chassis power-cycle, clean) : 1199 ms   <- LOWEST
warm GSP-reload, back-to-back (n=13)       : 1319-1342 ms
warm GSP-reload, after idle gap (n=3)      : 1930-1935 ms  <- observed MAX baseline
```

**Conclusion — the "colder = slower" hypothesis is REFUTED for the baseline.** A
clean cold-silicon init is the *fastest*, not the slowest. The init-latency tail
is NOT driven by silicon coldness; it is driven by the **stochastic H16 cold-bringup
PCIe transient** (which this clean shot did NOT hit) and apparently by some
idle/runtime-PM state drift (the 1.93 s outlier). So the worst-case the A6 budget
must clear is the *transient* tail (uncharacterised, multi-second when it fires —
needs the fake-5090 F44 model #290 or luck), not a high cold baseline. The proposed
**3000 ms budget covers all observed baselines (≤1.93 s) with headroom**, and the
**2000 ms grace is the catch-all** for a transient overshoot → fast-fail (chip
preserved). No change to the #300 proposal.

**Bonus — F45/F44 fix validated on a REAL cold bringup (n=1).** The cold-silicon
first open IS the F45 cold-bringup scenario that, pre-apnex.28, produced the
RM-API-rwsem deadlock wedge (reboot-only). On apnex.28 it fast-failed cleanly
(worker rc=0, chip NOT sunk, host alive) — no deadlock, no wedge. First live
exercise of C6+A11+A10-v2 on an actual cold silicon bringup. (n=1, did not hit the
transient, but the path is clean.)

**Reset/coldness model — empirically confirmed live** (see the 4-lens research
synthesis): physical power-off is the only silicon-de-power path; ReBAR resets to
the 256 MB power-on default; TB replug needs re-auth; broken-BAR1 is the runtime
hot-add allocator (not silicon state); `fix-bar1` rebuilds the 32 GB window at
runtime via the pciehp slot-cycle — all without a reboot, OS up throughout.

## Open / next steps

1. **Measure** worst-case healthy cold-init latency (n≥5, induced-timeout timing;
   non-destructive — same method as the `fastfail` run).
2. **Set** `OpenTimeoutMs` / `OpenGraceMs` defaults with A7-style headroom in
   `a5-version-and-toggles` (the toggle-defaults branch) + modprobe.d if pinned.
3. **Correct** the A6 intent "healthy-path note" (warm vs full-cold-init) and add a
   requirement that the budget MUST exceed a healthy full cold init; add the same
   note to the A10 intent grace.
4. **Re-validate** `fastfail` at the *new production-default* grace to confirm a
   1.3 s init now lands in `completed-within-budget` (open succeeds), not lockdown.
5. **Separable:** the H-OA2 un-bounded second site (A9 known gap, #282) — a cold
   init via H-OA2 is currently unbounded (no wedge protection at all on that path).
   Out of scope for this budget fix but tracked together under #282.

## Cross-refs

- A6 intent: `docs/patch-intents/A6-f40b-bounded-wait-open.md` (line 15 budget origin, line 17 healthy-path note)
- A10 intent: `docs/patch-intents/A10-f40b-lockfree-sink.md`
- A7 precedent: task #279 (shutdown budget 200→~2000)
- H-OA1/H-OA2: `docs/patch-intents/A9-egpu-probe-classify.md` + the A9 design/plan docs
- Validation run: `/var/log/mission-1-archaeology/ra10v2-fastfail-20260604T052224Z/`
- Runner: `tools/oa-harness/rung-a10v2-validate.sh`
