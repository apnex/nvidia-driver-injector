# Bridge Link Cap — Mechanism (Lever H17)

## TL;DR

The "cap" the bridge-link-cap service applies has TWO simultaneous
effects:

1. **Stability:** the boot-time retrain handshake between the TB
   controller firmware and the GPU GSP firmware can deadlock at some
   Target values (Gen4 froze the host on 2026-05-10 22:00) and
   succeeds cleanly at others (Gen3 PASS on n=1 retest 2026-05-10
   13:11).
2. **Bandwidth:** the Target value at the BOOT-TIME retrain commits
   the TB tunnel rate for the rest of the session. Subsequent
   runtime LnkCtl2 writes do NOT move the tunnel rate. Measured
   2026-05-10:
   Gen1+bit5 from boot → 0.61 GB/s H2D (Gen1 x4 saturated);
   Gen3+bit5 from boot → 2.83 GB/s H2D (TB4 saturated).

**Empirical recommendation: Target=Gen3 + bit 5.**
It is the boot-time-validated stability PASS AND the
TB4-saturated-bandwidth setting.
Gen1+bit5 is safe but costs ~80% of bandwidth and provides no
stability advantage.
Gen4+bit5 is dangerous (froze the host).
Bit 5 is independently load-bearing for boot-time GSP stability
across all Target values.

What lspci shows is misleading: the upstream-of-tunnel ports advertise
LnkCap=Gen1 and the eGPU-side bridge often reports LnkSta=Gen1
regardless of the actual tunnel rate.
Use `nvbandwidth` (real bytes/sec) to know what's really happening.

What the kernel does NOT do:
the `pcie_failed_link_retrain()` quirk in `drivers/pci/quirks.c` is
a theoretical recovery path but does NOT fire on this hardware
(its dmesg pci_info is absent;
M-recover diag traces show DLLLA stayed up during our retrains,
so the quirk's `!DLLLA && LBMS_seen` trigger is never met).
The Target=Gen3→Gen1 transition we observed during stop_device on
LAST-CLOSE is done by an unidentified entity (bridge auto-sync,
GSP firmware via BR04 LinkCtrlStat2, or TB controller firmware) —
but that transition is purely a register cosmetic;
it does NOT move the tunnel rate.

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

When our cap writes Target=Gen3+bit5 + retrain at boot:

1. The TB controller and GPU GSP firmware run their initial
   PCIe-virtual handshake.
2. The handshake commits a TB tunnel rate that maps roughly to
   Gen3 throughput — measured ~2.83 GB/s H2D, consistent with TB4
   saturation.
3. From the kernel's perspective:
   bridge LnkCtl2 = `0x0063` (Target=Gen3, bit 5 set);
   bridge LnkSta = `0x7043` (Speed=Gen3 visually, Width=x4,
   DLLLA=Y, LBMS=Y).
   The Speed=Gen3 in LnkSta is the TB controller's virtualized
   representation;
   the upstream-of-tunnel ports still report LnkCap=Gen1.
4. The cap stays at Target=Gen3 across the workload.
5. During the GPU's stop_device path on LAST-CLOSE of
   `/dev/nvidia0`, Target gets rewritten from Gen3 to Gen1 by some
   entity (bridge auto-sync, GSP firmware, or TB controller firmware
   — not pinned down).
   This is purely a register cosmetic;
   the tunnel rate is unchanged and will resume at full bandwidth
   on the next workload.

When our cap writes Target=Gen1+bit5 + retrain at boot:

1. Same handshake as above but at Gen1.
2. **The TB tunnel commits at Gen1 x4 throughput — measured
   0.61 GB/s H2D — and stays there for the rest of the session.**
3. Live-writing Target=Gen3 after this boot does NOT move the
   tunnel rate (verified empirically 2026-05-10).
4. On stop_device, Target stays at Gen1 (no rewrite needed since
   it's already there).

The boot-time Target value is therefore load-bearing for both
stability AND bandwidth.
Higher Targets give higher tunnel rates (up to TB4 saturation at
Gen3) but expose the firmware-handshake surface that froze us at
Gen4.

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

Cap behaviour at boot:

| Setting | Stability | Bandwidth (measured 2026-05-10) | Recommendation |
|---|---|---|---|
| Target=Gen1 + bit 5 | ✓ safe | **0.61 GB/s** (Gen1 x4 saturated; ~80% loss vs TB4) | Diagnostic / fallback only |
| Target=Gen2 + bit 5 | untested | expected ~2 GB/s (Gen2 x4 max) | Untested; no reason to choose over Gen3 |
| **Target=Gen3 + bit 5** | ✓ n=1 PASS 2026-05-10 13:11 | **2.83 GB/s** (TB4 saturated) | **DEFAULT** |
| Target=Gen4 + bit 5 | ✗ n=1 freeze 2026-05-10 22:00 | n/a | **Dangerous** |
| No cap (vendor default Gen4 + bit 5=0) | ✗ 36 GSP_LOCKDOWN_NOTICE | n/a | Confirmed bad (project history) |

Gen3+bit5 is the empirically validated sweet spot:
high enough that the TB tunnel commits at full bandwidth,
low enough that the firmware handshake doesn't enter the
deadlock-prone Gen4-virtual regime,
combined with bit 5 that prevents firmware-autonomous re-oscillation.

Bit 5 is independently load-bearing across all Target values:
without bit 5,
the link autonomously oscillates Gen3↔Gen4 at boot and GSP fires
36 LOCKDOWN_NOTICE events.
With bit 5,
both Gen1+bit5 and Gen3+bit5 boot cleanly (different bandwidth,
same stability).

## Universality

The Gen3+bit5 default is empirically validated only on this hardware
(NUC 15 Pro+ Meteor Lake-P TB4 + AORUS RTX 5090 TB5/USB4 dock,
n=1 boot-time PASS).
Other hardware combinations may differ.

Mechanism observations that are likely generalizable:

- The TB controller's tunnel-rate handshake commits at boot.
  Subsequent runtime LnkCtl2 changes are register cosmetics that
  don't move the tunnel rate.
  This appears to be how TB virtualization works in general.
- Bit 5 (Hardware Autonomous Speed Disable) is PCIe-spec and applies
  uniformly across vendors.
- The kernel's `pcie_failed_link_retrain()` quirk is a generic
  fallback but does not necessarily fire on TB hardware
  (its DLLLA-down trigger is too-strict for TB controllers that
  keep DLLLA up even when the requested speed isn't met).

Things that may be hardware-specific:

- The Gen4-virtual handshake deadlock observed on JHL9480 may be a
  firmware bug specific to that controller.
  Other TB controllers could deadlock at different Target values
  or none at all.
- The exact bandwidth-vs-Target curve depends on the TB controller's
  internal tunnel-rate-selection logic.
  Other controllers might not give the clean Gen1<<Gen3 step we see.
- Non-NVIDIA GPUs may behave differently at the GSP-equivalent
  firmware level.

Use Gen3+bit5 as a strong starting point on novel hardware.
`tools/cap-retest-probe.sh` exercises the relevant state and
bandwidth at any cap setting —
running it at a few Target values per hardware combination is the
right way to confirm before locking in a default.

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
