# OA reset-efficacy ladder — does a runtime reset CURE the open-arm wedge?

**Status:** DESIGNED 2026-05-30, not yet executed. **Survivable** (A6 safety net) — does NOT need the destructive reboot-loop. Execution gated on a go.
**Series:** Open-Arm (OA), task #282. Constructive form of ladder hypothesis **H-OA12** (PCI-reset differential).
**Parent:** `open-arm-forensics-ledger.md` (Lane 2 confirmed the site = GSP lockdown-release wait).

## The question

Lane 2 confirmed: after cycle-1's clean open+close (which runs `nv_shutdown_adapter` and drives WPR2→0), the **next** GSP boot (cycle-2) stalls in `kgspBootstrap_GH100 → gpuTimeoutCondWait(_kgspLockdownReleasedOrFmcError)` — the GSP never releases lockdown. The chip is *un-rebootable for GSP* in that state.

**What reset depth (if any), applied between the shutdown and the re-init, lets the GSP boot succeed?** This is the **cure-vs-contain** verdict, and it directly tests **whether our own A3 recovery (`pci_reset_bus`) is a latent cure** or only containment.

## Why this matters (the A3 linchpin)

A3's recovery already calls **`pci_reset_bus()` on the upstream TB bridge** on post-`rm_init_adapter`-FAIL, and A3 is *designed* to recover-to-working (`success_count++` + `READY` uevent on a successful retry). **But no archive shows a successful recover-to-working** — so it's unknown whether A3's reset actually clears the GSP-boot-blocking state. If a secondary bus reset cures (variant R2 below), A3 needs only to **retry init after its existing reset** to turn contain→cure. If it doesn't, the cure lives deeper (slot-cycle / E27 kernel patch / cold-plug), which substantiates the Windows-resets-properly hypothesis.

## Hypotheses (minimum reset depth to cure)

| ID | Statement | If TRUE → |
|---|---|---|
| **H-R1** | A **Function-Level Reset** (FLR) of the GPU function clears the GSP-boot-blocking state | cheapest fix; driver could FLR-on-reinit |
| **H-R2** | Only a **secondary bus reset** (= A3's `pci_reset_bus`, resets the link) suffices | **A3's reset IS a latent cure** — wire it to retry init |
| **H-R3** | Only a **pciehp slot power-cycle** (re-enumerates the device; what `fix-bar1` does) suffices | cure lives in the recovery-script / E27 kernel domain, not the driver |
| **H-R4** (null) | **No runtime reset cures** — only a true cold-plug / chassis power-cycle / reboot recovers | contain-not-cure at runtime; confirms the Linux-missing-full-TB-reset (E27) / Windows story |

These are an ordered ladder (increasing reset depth); the lowest-depth cure wins.

## Method (contained, A6 safety-net, survivable)

A6 stays at `NVreg_TbEgpuOpenTimeoutMs=200` throughout. Any variant that does **not** cure → cycle-2 hits A6 → `-EIO`, host survives. So the whole ladder runs **without a single forced reboot**.

Per variant: establish the F40 precondition → cycle-1 (clean, `nvidia-smi -L`) → **[variant reset]** → cycle-2 (`exec </dev/nvidia0`) under PMU sampling → classify.

| Variant | Between cycle-1 and cycle-2 | Isolates |
|---|---|---|
| **R0** (control) | nothing | the Lane-2 baseline (A6 fires) — already have, n=4 |
| **R0.5** (control) | unbind → rebind, **no reset** | does the **re-probe alone** cure? (separates rebind from reset) |
| **R1** | unbind → **FLR** → `fix-bar1` → rebind | FLR depth |
| **R2** | unbind → **secondary bus reset** (bridge 03:00.0) → `fix-bar1` → rebind | **A3's `pci_reset_bus` depth** |
| **R3** | unbind → **pciehp slot-cycle** (slot 12 power 0→1) → `fix-bar1` → rebind | cold-plug-equivalent depth |

Concrete reset commands (GPU `04:00.0`, audio `04:00.1`, bridge `03:00.0`, slot `12`; `reset_method=flr bus`):
- unbind: `echo 0000:04:00.0 > /sys/bus/pci/drivers/nvidia/unbind` (triggers `nv_pci_remove`; A7 bounds the teardown)
- **FLR:** `echo flr > .../04:00.0/reset_method; echo 1 > .../04:00.0/reset`
- **SBR:** `echo 1 > .../0000:03:00.0/reset` (bridge reset == secondary bus reset; == A3's `pci_reset_bus(bridge)`)
- **slot-cycle:** `echo 0 > /sys/bus/pci/slots/12/power; sleep 3; echo 1 > .../power; sleep 5` (re-breaks BAR1 → `fix-bar1`)
- every reset re-breaks ReBAR → re-run `tools/fix-bar1.sh` to restore 32 GiB before rebind
- rebind: `echo > .../04:00.0/driver_override; echo 0000:04:00.0 > /sys/bus/pci/drivers/nvidia/bind`

**"Cure" is a strong claim — require all three:** cycle-2 opens `rc=0` (no A6 fire) **AND** the GPU is functional afterward (`nvidia-smi -L` + BAR1=32 GiB + a short `nvbandwidth`/deviceQuery via the diag container) **AND** repeatable **n≥3**. A single non-wedge is a lead, not a cure (premature-success scar). Non-cures: **n≥2** (A6 fire is deterministic).

## Decision tree

- **R0.5 cures** → it's the *re-probe*, not the reset; re-scope (the unbind/remove+re-add is itself the recovery). Unlikely (unbind doesn't reset the chip) but must be controlled for.
- **R1 (FLR) cures** → lowest-cost runtime cure; candidate: FLR-on-reinit in the driver. Stop, characterize.
- **R2 (SBR) cures, R1 doesn't** → **A3's `pci_reset_bus` is a latent cure** → patch action: A3 retries init after its reset. *Highest-value outcome for the patch review.*
- **R3 (slot-cycle) cures, R2 doesn't** → cure needs device re-enumeration → recovery-script (`fix-bar1`) / E27 kernel domain; the driver can't do this mid-open. Confirms the reset must be deep.
- **Nothing cures (H-R4)** → the chip-internal GSP/secure-boot state survives every runtime PCI reset → only a cold-plug / chassis power / reboot recovers → **contain-not-cure verdict**, and strong support for "Linux's missing full-TB-reset is the gap (E27); Windows resets properly" — without needing Windows.

Each rung also runs the Rung-4 PMU capture: a *partial* cure (e.g., the stall moves from the lockdown-release wait to a later frame, or the dwell shortens) is itself a data point even if cycle-2 still fires A6.

## Safety

- A6 net (no `NVreg_TbEgpuOpenTimeoutMs=0` here — this is **not** the destructive lane).
- BAR1-via-sysfs is the first check after every reset and after cycle-2; abort to passive-only + reboot if BAR1 breaks and `fix-bar1` can't restore it.
- fsync'd markers (harness `oa_mark`), sysrq armed, 10 s thermal cap on the cycle-2 busy-poll.
- `thunderbolt.host_reset=false` guard respected — **do not** touch the TB host reset (known to break BAR1, 2026-05-08); stay at device/bridge resets.
- Driver-bound reset: always **unbind first** (clean `nv_pci_remove`) rather than resetting under a live bind — avoids racing the driver's own reset handlers.

## Harness

Extends `tools/oa-harness/` with `reset-ladder.sh` (variant selector `--reset {none,rebind,flr,sbr,slot}`), reusing `precondition.sh` + the Rung-4 PMU capture + `fix-bar1.sh`. ~1 short runner; the reset primitives are the 5 commands above.

## Cross-refs

`open-arm-forensics-ledger.md` (Lane 2 site) · `docs/patch-intents/A3-recovery.md` (the `pci_reset_bus` recovery) · `tools/fix-bar1.sh` (slot-cycle + ReBAR restore; the E27 band-aid) · `docs/upstream-plan.md` (E27 kernel-patch lane) · `pci-cmdline-audit.md` §E (cmdline staleness, sibling question).
