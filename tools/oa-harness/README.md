# oa-harness — #282 OPEN-arm experiment harness

Freeze-safe runners for the open-arm (RmInitAdapter wedge) experiment ladder.
Design + hypotheses + ladder: `docs/missions/mission-1-egpu-hot-plug-hot-power/open-arm-forensics-ledger.md`.

## Why this exists (and is committed)
The 2026-05-29 trigger scripts were ad-hoc and lost on reboot. These are committed
and **freeze-safe**: `oa_mark()` fsyncs a timestamped marker to disk **before and
after every step that can wedge the host**, so forensics survive a hard kernel lock
(the reason 5 of 6 prior wedge archives lost their trigger — journald never flushed).

## Operational reality
We run **on `obpc`**. A hard wedge kills the running process → the host needs a
**reboot** (yours). Continuity across a death = the committed ledger + the fsync'd
run dir under `/var/log/mission-1-archaeology/<run>-<utc>/`. After a reboot, resume
by reading that dir.

## Safety invariants (enforced in `lib.sh`)
- **BAR1-via-sysfs is the first post-fire check.** Never nvidia-smi / MMIO / RPC on a
  suspected-wedged or broken-BAR1 chip (passive `oa_passive_snapshot` only).
- **Rung 3.5 gate** before any contained fire: assert the module carries A6
  (`oa_assert_a6`) + pin the chip at D0 (`oa_pin_d0`) so the wedge lands at A6's
  RmInitAdapter site, not the A6-uncovered pre-`nv_open_device` site.
- sysrq armed; one variable per run; 10s thermal cap on busy-poll fires.

## Files
- `lib.sh` — shared: discovery, fsync'd `oa_mark`, BAR1 check, passive snapshot,
  Rung 3.5 gate (assert-A6 + pin-D0).
- `precondition.sh` — establishes the F40 substrate: graceful `uninstall` (rmmod via
  the injector's own path — **not** pod-delete) → TB deauth/reauth → `fix-bar1` →
  `modprobe` no-persistence → Rung 3.5 gate. `--dry-run` stubs the destructive steps.
- `rung4.sh` — Lane 2 Rung 4: cycle-1 (`nvidia-smi -L`) → PMU sampler
  (`profile:hz`, not kprobe) → cycle-2 fire (`exec </dev/nvidia0`) → BAR1-first +
  passive snapshot + frame attribution (`ATTRIBUTION.txt`).

## Run (Lane 2, contained — wedge-class, be reboot-ready)
```
sudo tools/oa-harness/precondition.sh --dry-run     # validate the flow (no chip touch)
sudo tools/oa-harness/rung4.sh --hz 4999 --gap 2 --precond
# inspect: /var/log/mission-1-archaeology/rung4-*/ATTRIBUTION.txt
# then vary: --hz 997 (frame must be stable across rates), repeat n>=3
```
After each fire the chip is in C5-sink/lost state — re-run the precondition before
the next fire.
