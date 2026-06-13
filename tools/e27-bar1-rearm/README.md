# e27-bar1-rearm — deterministic in-kernel BAR1 recovery experiment

Experiment toward **E27**: retire `tools/fix-bar1.sh` (a heavy but proven pciehp
slot-cycle / PERST) with a **light** in-kernel recovery of a TB-hot-add broken
BAR1 (256 MiB instead of 32 GiB), using **exported PCI primitives only** (no
kernel rebuild, no cmdline). Full saga + verdict:
`docs/missions/mission-1-egpu-hot-plug-hot-power/finding-2026-06-13-E27-halfb-determinism-verdict.md`.

## Mechanism (`tbegpu_bar1_rearm.c`)
GPU on-bus, nvidia **unbound**, all under `pci_lock_rescan_remove()` for steps 1-3:
1. decode off (clear `PCI_COMMAND_MEMORY`).
2. `pci_release_resource()` the empty downstream-port sibling prefetch windows
   (the cascade-blockers).
3. `pci_resize_resource(gpu,1,15,0)` → cascades release GPU→root, re-sizes the
   root hotplug port with the `hpmmioprefsize` reserve at the 32 G-aligned base,
   and writes chip ReBAR CTRL `0x8→0xF` (`pci_rebar_set_size`) in the same call.
4. `pci_reset_function()` **(FLR)** — the resize only re-fences the chip's
   internal aperture across a reset; the FLR's save/restore rewrites CTRL=0xF for
   the resized size. **Pin `reset_method=flr` first** so this cannot escalate to a
   link-down slot/bus reset.
5. **verify-before-bind** (`verify=Y`, default): re-enable decode, `ioremap` BAR0
   + BAR2, poll `PMC_BOOT_0` (gate) + `BAR2[0]` (logged diagnostic) until the chip
   re-fences, up to `settle_ms`; gate `RESULT=OK` on a sane readback. `verify=N`
   reverts to a blind `msleep(settle_ms)` control arm.

> **`RESULT=OK` is necessary, not sufficient.** It read 32 G/aligned in *both* the
> cycle-1 PASS and the cycle-2 FAIL. The true verdict is **`RmInitAdapter rc=0`**
> at bind. The verify gate (boot0 in BAR0) catches the Stage-1 dead-chip class but
> does **not** by itself discriminate the cycle-2 BAR2-MMU desync — `BAR2[0]` raw
> is logged to learn whether it predicts the bind, backstopped by the runbook
> fail-safe.

## Params
`gpu` (BDF), `size` (ReBAR enc, 15=32G), `dry_run` (Y), `flr` (Y), `verify` (Y),
`settle_ms` (2000 — verify poll budget / blind sleep).

## Build
```
make            # against the running kernel
```

## Run — use `e2-verify.sh` (⚠ wet PCI surgery + GPU init; operator at console, capture armed, soak reset)
The deciding test is **E2-verify**, driven by the hardened runbook (NOT
`run-experiment.sh` stage 2, whose substrate model predates the 256 M root-cause
and which stops at the false-positive `RESULT=OK`). Each verb is a deliberate step:
```
sudo ./e2-verify.sh preflight              # once: drain, mask persistenced, recover=0 drop-in + resolved-arg proof, pin flr
sudo ./e2-verify.sh status                 # state readout, any time
sudo ./e2-verify.sh cycle 1 2000           # one full data point (substrate → rearm → atomic bind)
sudo ./e2-verify.sh restore                # recover the chip (fix-bar1 --bind), keeps the recover=0 belt
sudo ./e2-verify.sh teardown               # remove drop-in, unmask, un-drain, unpin
```
The `bind` step is a single atomic open: on FAIL it `rmmod`s immediately and
**never re-opens** (the 11-retry hammering on a desynced aperture is what
escalated cycle-2 to a platform reset). It scores ONLY by `RmInitAdapter`, and
classifies the rc-triplet (`0x24:0x72:1307` = the settle-relevant FAIL).

**Decision rule (pre-registered):** one settle-FAIL at the adopted `settle_ms`
refutes determinism — do **not** retire `fix-bar1`. A determinism claim needs
≥10–12 consecutive clean binds on independently re-deauth/reauth'd substrates;
n≥3 is "promising", never "deterministic". If the FLR relatch stays flaky, the
proven fallback is a **udev/boltd-triggered `fix-bar1.sh`** (an in-kernel SBR is
NOT equivalent — A3 proved SBR doesn't re-latch the 256 M→32 G size; the
slot-cycle/PERST has no exported symbol).

`run-experiment.sh` (stages 0/1/2) is retained for the dry-run survey only.
