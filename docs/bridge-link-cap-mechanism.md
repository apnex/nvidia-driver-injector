# Bridge Link Cap — Mechanism (Lever H17)

## TL;DR

The "cap" the bridge-link-cap service applies is **not a bandwidth cap**.
It is a *controlled retrain trigger* whose stability depends on which
Target Link Speed value gets handshook between the Thunderbolt
controller firmware and the GPU's GSP firmware.
On TB-tunneled paths the link can never actually converge above Gen1
(upstream-of-tunnel bridges are virtualized at LnkCap=Gen1),
so any Target value above Gen1 is effectively a request that cannot
be granted.

Observed on this hardware (Meteor Lake-P TB4 + AORUS RTX 5090 TB5
dock,
2026-05-10):
**something during the GPU's stop_device path rewrites Target to
Gen1,**
regardless of what we set.
The exact rewriter is one of (bridge auto-sync, GSP firmware,
TB controller firmware) — I have not pinned it down.
The kernel's `pcie_failed_link_retrain()` quirk is a theoretical
recovery path but does not fire on this hardware (DLLLA stays up
during our cap retrain).

**Empirical recommendation: Target=Gen1 + bit 5.**
It matches the post-shutdown converged state from the start,
so no transition involving a contested handshake at higher virtual
speeds is ever attempted —
which is the regime that deadlocked the TB firmware on 2026-05-10
22:00 (Gen4+bit5 cap → host freeze on `nvidia-smi`).

## What the cap binary writes

`/usr/local/sbin/nvidia-driver-injector-bridge-link-cap apply`
performs three register writes against the GPU's parent bridge
(`vendor:device == 0x10de:0x2b85`'s `dirname` in /sys/bus/pci):

1. Read LnkCtl2 (PCIe Express Capability offset 0x30, word).
2. Set bit 5 (Hardware Autonomous Speed Disable) in LnkCtl2.
3. Optionally overwrite bits[3:0] (Target Link Speed) per
   `CAP_TARGET_SPEED` env (default Gen3 prior to 2026-05-10 13:11).
4. Write LnkCtl2 back.
5. Trigger Retrain Link via LnkCtl bit 5 (offset 0x10).

The retrain causes the bridge to renegotiate its downstream link.

## What rewrites Target to Gen1 — the empirical answer

I initially hypothesised the kernel's
[`pcie_failed_link_retrain()` quirk in `drivers/pci/quirks.c`]
was the rewriter — fired by DLLLA-down + LBMS-seen,
forcing Target=Gen1 via `pcie_set_target_speed()`.

**The empirical evidence on this hardware says NO.**

On 2026-05-10 13:11 we re-applied Target=Gen3+bit5,
ran nvbandwidth + nvidia-smi,
and observed Target rewritten to Gen1.
But:

- `dmesg` contains zero matches for the quirk's pci_info() message
  `"broken device, retraining non-functional downstream link at
  2.5GT/s"` — it didn't fire.
- The M-recover [DIAG] traces show DLLLA=Y on the bridge (`Br_LnkSta
  bit 13 = 1`) at every observation site between cap-apply and
  shutdown — which means the quirk's trigger condition (`!DLLLA &&
  LBMS seen`) was never satisfied.
- Br_LnkSta transitioned `0x7043 → 0x7041` (Gen3 → Gen1) between the
  M-recover `pre-stop` site (`t=1850.974`) and the `post-shutdown`
  site (`t=1851.594`) — i.e. **during the GPU's stop_device path**,
  not during cap-apply or workload.

So the actual rewriter on this hardware is NOT the kernel quirk.
The candidates that fit the observed timing:

1. **The bridge auto-syncs LnkCtl2 Target to match LnkSta** when the
   link transitions through a low-power state.
   PCIe spec doesn't mandate this,
   but some bridges/TB controllers do it as a vendor extension.
2. **GSP firmware re-writes LnkCtl2 during shutdown** via its
   internal BR04 LinkCtrlStat2 register
   (NV_BR04_XVU_LINK_CTRLSTAT2_TARGET_LINK_SPEED in
   `src/common/inc/swref/published/br04/dev_br04_xvu.h`).
3. **TB controller firmware syncs the virtual register state** when
   the host driver's shutdown sequence runs.

I do not have direct evidence of which of these fires.
What we DO know empirically:
**Target gets rewritten to Gen1 during the GPU's stop_device path,
regardless of what we wrote earlier.**
The kernel's `pcie_failed_link_retrain()` quirk is a *theoretical*
fallback if our cap-write itself caused link training to fail
(DLLLA-down + LBMS-seen) — but on this hardware our cap-write doesn't
push DLLLA down,
so the quirk is an unused safety net,
not the active mechanism.

`pcie_set_target_speed()` lives in
`drivers/pci/pcie/bwctrl.c` and writes LnkCtl2 via
`pcie_capability_clear_and_set_word(port, PCI_EXP_LNKCTL2,
PCI_EXP_LNKCTL2_TLS, target_speed)` then calls `pcie_retrain_link()`.
The bwctrl service is also wired to the LBMS interrupt and tracks
PCI_LINK_LBMS_SEEN in priv_flags —
but does NOT itself write LnkCtl2 in the IRQ handler.

The Intel JHL9480 TB controller's VID:DID (`0x8086:0x5786`) does NOT
match the ASM2824 ID list,
so even if the quirk were to fire,
the post-quirk path that lifts the Gen1 restriction back to LnkCap
max would not run.

## Why TB-tunneled paths can't actually converge above Gen1

The Intel TB controller virtualizes PCIe topology to the host:

| BDF | Component | LnkCap (advertised max) | LnkSta (live) |
|---|---|---|---|
| 00:07.0 | Meteor Lake-P TB4 root port | Gen1 x4 (virtualized) | Gen1 x4 |
| 02:00.0 | JHL9480 TB5 hub upstream port | Gen1 x4 (virtualized) | Gen1 x4 |
| 03:00.0 | JHL9480 TB5 hub downstream port | Gen4 x4 (advertised) | Gen1 x4 |
| 04:00.0 | RTX 5090 endpoint | Gen5 x16 (real chip) | Gen1 x4 |

The bridge advertises Gen4 x4 in its LnkCap — but the link can never
converge above Gen1 because the upstream port is virtualized at Gen1.
PCIe spec: the link converges at the slowest port in the chain.

So when our cap writes Target=Gen3 + retrain:

1. The bridge attempts to renegotiate at Gen3 with the GPU
   (its downstream device).
2. The TB controller does not move LnkSta above Gen1 — but DLLLA
   stays up,
   LBMS gets set,
   and Br_LnkSta becomes `0x7043` (Speed=Gen3 visually,
   Width=x4,
   DLLLA=Y,
   LBMS=Y).
3. The cap remains at Target=Gen3 across the workload (we observed
   this — Target=Gen3 stayed stable through nvbandwidth and
   nvidia-smi -L).
4. **During the GPU's stop_device path on the LAST close of
   `/dev/nvidia0`, Target gets rewritten to Gen1 by some entity
   (bridge auto-sync, GSP firmware, or TB controller firmware —
   not pinned down).**
5. After post-shutdown the cap is Target=Gen1, LnkSta=Gen1,
   stable until next cap-script apply.

Bandwidth is unchanged — TB4 saturates at ~2.83 GB/s H2D regardless,
verified with nvbandwidth at both Gen1 and Gen3 cap states (2.84 and
2.83 GB/s respectively, well within measurement noise).

## What bit 5 does (still load-bearing)

`LnkCtl2` bit 5 = "Hardware Autonomous Speed Disable" (`SpeedDis+` in
lspci output).
It blocks **hardware-initiated** autonomous speed changes — the
firmware-driven oscillation between speeds that pre-dates kernel
involvement.

bit 5 does NOT block:

- Software-driven retrains via LnkCtl bit 5 (the cap script's own
  retrain).
- Software writes to LnkCtl2 Target.

That is why the kernel quirk can still rewrite Target to Gen1 even
with bit 5 set — software-driven changes are allowed.

bit 5 is sticky once set;
the kernel does not clear it across the pcie_failed_link_retrain quirk
or normal operation.

Bit 5 is the load-bearing knob for boot-time GSP stability,
independently established by project history:
without bit 5 at boot the link autonomously oscillates Gen3↔Gen4 and
GSP firmware fires 36 LOCKDOWN_NOTICE events during init.
With bit 5 set,
both Gen1+bit5 and Gen3+bit5 boot cleanly.

## How the 2026-05-10 freeze fits the mechanism

The 2026-05-10 22:00 incident (n=1, no kernel trace preserved):

1. We shipped a "bit 5 alone, Target=Gen4 vendor default" cap.
2. Boot was clean —
   0 AER UE-Non-Fatal events,
   container loaded,
   /dev/nvidia* materialised,
   status HEALTHY.
3. User ran `nvidia-smi` manually.
4. Host froze hard,
   required power-cycle.

A plausible mechanism — though I cannot prove it without
reproducing the freeze with kernel-trace preservation:

1. The cap script (or vendor default) left Target=Gen4 in the
   bridge's LnkCtl2 with bit 5 set.
2. nvidia-smi opened `/dev/nvidia0` → driver did its standard init →
   driver shutdown on close → at some point in this sequence the
   firmware (TB controller or GPU GSP) attempted a transition that
   involved Target=Gen4.
3. The Gen4-virtual handshake deadlocked one of the firmware state
   machines (TB controller most likely, given TB virtualizes the
   PCIe state) →
   PCIe config space wedged for that bridge →
   any subsequent driver or kernel access to the bridge or
   downstream device blocked indefinitely →
   host froze.

Open question: what specifically about Target=Gen4 caused the
deadlock?
Possibilities — none confirmed:

- TB controller firmware has a bug in its Gen4-virtual handshake
  state machine that lower-Gen handshakes don't trigger.
- Bit 5 + Gen4 specifically prevents some recovery path the
  controller would otherwise take.
- The freeze was actually unrelated to the cap and was a stochastic
  Mode B / close-path event we attributed via correlation.

The "Gen3+bit5 wedged n=2 on Port A" entry from earlier project
history predates Lever M-recover (2026-05-08) and Lever T (iommu=off,
2026-05-07).
The 2026-05-10 13:11 retest at Gen3+bit5 on the current stack passed
cleanly with bandwidth unchanged.
Whether that's because the failure mode was always stochastic,
or because the new stack catches it,
is undetermined.

## Implications for cap policy

| Setting | What happens | Recommendation |
|---|---|---|
| Target=Gen1 + bit 5 | Matches the natural converged state from the start → no contested handshake ever attempted → stable | **Default — universally safe for TB-tunneled** |
| Target=Gen2 + bit 5 | Initial retrain converges at Gen1 LnkSta but Target stays Gen2 in LnkCtl2; gets resynced to Gen1 during stop_device | Works, no observed failures, but no advantage over Gen1 |
| Target=Gen3 + bit 5 | Same pattern as Gen2; n=1 PASS on this stack 2026-05-10 13:11 | Works, no observed failures, but no advantage over Gen1 |
| Target=Gen4 + bit 5 | n=1 host freeze 2026-05-10 22:00 — most plausible mechanism is the TB-firmware handshake deadlocking on the contested virtual-Gen4 retrain | **Dangerous** |
| No cap (vendor default Gen4 + bit 5=0) | Hardware autonomous Gen3↔Gen4 oscillation → 36 GSP_LOCKDOWN_NOTICE events during GSP boot | Confirmed bad (project history) |

Gen1+bit5 is preferred not because anything actively rescues us from
higher Targets,
but because the higher-Target cases are pure exposure to a firmware
handshake that we don't fully understand and that has demonstrated
the ability to deadlock the host (Gen4 case).
Gen2 and Gen3 happen to work with no observed failures —
but with zero performance benefit and no recovery story if the
firmware ever changes behaviour,
they're strictly more risk than Gen1.

## Universality

The reasoning behind "Gen1 is universally safe" is mechanism-based,
not data-based — we have one Linux host, one TB controller, one GPU.
Caveats apply.

Mechanism arguments for universality:

- TB tunnel bandwidth is set at the TB layer (TB3/TB4/TB5) and is
  decoupled from the PCIe-virtual Target value seen by the OS.
  This appears to be intrinsic to how TB virtualizes PCIe.
- Intel TB controllers virtualize upstream-of-tunnel PCIe ports with
  LnkCap=Gen1 across the Intel TB family
  (verified on Meteor Lake-P TB4 + JHL9480 TB5;
  same pattern reported on earlier Intel TB hosts).
- Bit 5 (Hardware Autonomous Speed Disable) is part of the PCIe
  base spec and present on every PCIe Gen2+ device.
- A Target=Gen1 cap therefore matches the post-shutdown converged
  state on any TB-tunneled host;
  no contested handshake at higher virtual speeds is ever attempted;
  the firmware-deadlock surface that produced the 2026-05-10 freeze
  is sidestepped entirely.

Concrete things I do NOT know:

- Whether Intel TB controllers other than JHL9480 deadlock on Gen4
  Target the same way — could be JHL9480-specific firmware.
- Whether non-NVIDIA GPUs over TB exhibit the same handshake-
  sensitivity at higher Target values.
- Whether non-Intel TB controllers (e.g. AMD's USB4 implementations)
  virtualize PCIe topology the same way.

Use the Gen1+bit5 default as a strong baseline,
not as a proven invariant.
The injector repo's `tools/cap-retest-probe.sh` will exercise the
relevant register state and bandwidth on any host that has the
binary installed —
running it at a few Target values is the right way to confirm before
deploying on novel hardware.

## References

| Source | Where |
|---|---|
| `pcie_failed_link_retrain()` | `drivers/pci/quirks.c` — function defined ~line 95 |
| Quirk callers | `drivers/pci/pci.c:1269`, `drivers/pci/pci.c:4594`, `drivers/pci/probe.c:2775` |
| `pcie_set_target_speed()` | `drivers/pci/pcie/bwctrl.c` |
| `pcie_bwctrl_select_speed()` (clamps to intersection of supported speeds) | `drivers/pci/pcie/bwctrl.c` |
| LBMS interrupt handler that sets PCI_LINK_LBMS_SEEN | `drivers/pci/pcie/bwctrl.c:211` (`pcie_bwnotif_irq`) |
| TB driver — does NOT touch LnkCtl2 (verified) | `drivers/thunderbolt/` (no PCI_EXP_LNKCTL2 references) |
| Lever H17 catalog reference | `apnex/aorus-5090-egpu` `docs/lever-catalog.md` (referenced in service-retirement-roadmap; needs formal entry) |
| Empirical retest dossier | `archive/cap-retest-probes/2026-05-10T13-11-35+10-00/` |
| Project history of bit-5 / cap experiments | `apnex/aorus-5090-egpu` `docs/reliability-hypothesis-ledger.md` H17 entries |

## Open follow-ups

1. **n=1 → n≥3 for Gen1+bit5 cap-retest probe.** The current Gen1+bit5
   data point comes from the post-shutdown converged state observed
   at 13:11 — not from a fresh boot with `CAP_TARGET_SPEED=1`.
   A fresh-boot probe is the cleanest validation.
2. **Identify the actual rewriter of Target during stop_device.**
   Candidates: bridge auto-sync,
   GSP firmware (NV_BR04_XVU_LINK_CTRLSTAT2),
   TB controller firmware.
   Approach: read LnkCtl2 at fine timing intervals through
   stop_device,
   or instrument the M-recover patch with a `pre_close_lnkctl2`
   capture.
3. **Confirm or falsify on Port B** (project history says Gen3+bit5
   works on Port B but Gen3+bit5 wedged on Port A pre-M-recover).
   Universality claim should be checked across both NUC TB4 ports
   on this NUC.
4. **Reproduce the 2026-05-10 Gen4+bit5 freeze with kernel-trace
   preservation** —
   only way to nail the actual mechanism.
   Currently a known-bad config, n=1, no trace.
5. **Formal H17 entry in `aorus-5090-egpu/docs/lever-catalog.md`** —
   the lever has been load-bearing since 2026-05-08 but only has a
   service-retirement-roadmap mention,
   not a Per-lever spec entry.
