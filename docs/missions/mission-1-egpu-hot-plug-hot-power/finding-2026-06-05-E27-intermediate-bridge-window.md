# Finding — E27: intermediate TB bridge gets only 256 MiB prefetch window (2026-06-05)

**Class:** runtime/hot-plug PCIe resource-allocation failure. **Graceful (NO host wedge).** Categorically
**distinct from #292** (the re-open RM bring-up deadlock) — different mechanism, blast radius, and fix.
Do not conflate.

**Capture:** `captures/netcon-2026-06-05-E27-coldchassis-retest.log` (cold-chassis power-on retest boot,
RETEST-1/2/3/3b/3c). Adversarially verified (8-agent workflow grounding).

## One-line
On runtime/hot-plug re-allocation the **intermediate TB switch-upstream bridge `0000:02:00.0` is granted
only a 256 MiB prefetchable window**, so the 32 GiB GPU BAR1 child (under `03:00.0` under `02:00.0`)
**cannot fit** → BARs unbacked → `NVRM: BAR0 is 0M @ 0x0` → nvidia probe `-1`. The root port and the GPU
endpoint are both fine; the bottleneck is strictly the **intermediate** bridge.

## Proof (exact lines, `netcon-…E27….log`)
- Kernel computes the correct large requests: `03:00.0 … add_size 12100000` to bus 04 (L382);
  `02:00.0 … add_size 1812100000` (~96 GiB subtree) to bus 03-2b (L389).
- **PROOF line — L391:** `pci 0000:02:00.0: bridge window [mem 0x5000000000-0x500fffffff 64bit pref]:
  assigned` → `0x500fffffff − 0x5000000000 + 1 = 0x10000000 = exactly 256 MiB`. That is the *entire*
  prefetch window the intermediate bridge receives.
- Child can't fit: **L394-395** `03:00.0: bridge window [mem size 0x814100000 64bit pref]: can't assign;
  no space` / `failed to assign` (`0x814100000 ≈ 32.06 GiB` vs 256 MiB parent).
- Result: **L400-406** `AER: unmasked Uncorrectable Internal Error at probe` → `NVRM: BAR0 is 0M @ 0x0`
  → `probe … failed with error -1` → `None of the NVIDIA devices were initialized`. (`fix-bar1 rc=1`, L408.)
- **Contrast that pins it:** at enumerate time the endpoint asks for the right size — `04:00.0: BAR 1
  [mem 0x4800000000-0x4fffffffff 64bit pref]` = 32 GiB (L360) — and the **root port `00:07.0` holds a
  ~32 GiB window** (L626/711/888). Only `02:00.0` is starved.

## No runtime lever moves the intermediate window
- **TB deauth/reauth (RETEST-2):** same 256 MiB at `02:00.0` (L884), and now a **full BAR cascade
  collapse** — `03:00.0 … failed to expand by 0x12100000` (L571-572); GPU `BAR1 0x800000000`, `BAR0`,
  `BAR3`, all VF BARs, even audio `04:00.1 BAR0` all `can't assign; no space` (L837-869) → probe -1 again
  (L993-1001).
- **Native ReBAR `resource1_resize=15` → 32 GiB (RETEST-3):** synchronous **EINVAL no-op** (~19 ms,
  **zero** kernel resize lines, L1002-1003) — the sysfs write is rejected up front because the parent
  window is only 256 MiB.
- **`COMMAND=0`+resize (3b), `assign-256M`+resize-32G (3c):** neither grows BAR1 (L1004; L1266-1268,
  `Slot(12): Already disabled`). No lever satisfied the 32 GiB child.

## Graceful — NOT a wedge
Host stayed fully alive through all five destructive retests and ended in an **orderly
`systemd-shutdown → Powering off`** (L1369-1400). `grep` over the whole 1400-line boot: **zero** matches
for `Xid|hung task|RIP:|Call Trace|soft lockup|hard LOCKUP|BUG:|stuck`. E27 = "GPU simply absent," not a
host hang.

## Fix landing zone
Grow `02:00.0`'s **prefetchable** window at hot-plug/runtime realloc — the
`pci_reassign_bridge_resources` / `__assign_resources_sorted` path, specifically the
`failed to expand by 0x12100000` site (L571-572). This matches the standing design note
[[feedback-io-vs-prefetchable-realloc-asymmetry-2026-05-26]]: `pci=realloc=on` widens **I/O** bridge
windows but **not** prefetchable memory — extending that pattern to the prefetchable type on the
intermediate TB bridge is the additive fix. **Cold-plug at boot remains the only reliable 32 GiB path**
until E27 lands. Correct OS layer per [[feedback-tb-pcie-cap-architecture]] is `drivers/thunderbolt` /
the PCI realloc core, not the GPU driver.

## Status
Bottleneck **pinned**; needs a tracking task (E27). Reproduce/iterate on **fake-5090 (#290)** rather than
live. Distinct from and **independent of** #292 (re-open deadlock) — either can block reliable runtime
recovery on its own.
