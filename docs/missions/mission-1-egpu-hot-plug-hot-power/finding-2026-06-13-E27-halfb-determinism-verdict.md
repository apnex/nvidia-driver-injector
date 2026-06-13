# Finding — 2026-06-13 — E27 half-(b) determinism: CONCLUSIVE (deterministic out-of-tree-module mechanism; conditional on n≥3 experiment)

> ⛔ **REFUTED BY LIVE TEST 2026-06-13 (Stage 1 wet run, n=1) — the determination below is WRONG on its
> load-bearing conclusion.** The module ran correctly + safely (apnex.33 contained the aftermath, host
> never wedged), BUT: (1) `pci_resize_resource` re-placed the window at **`0x6000000000`, not the
> predicted firmware-constant `0x4000000000`** (and grew the root-port window to 128 G) — so the
> "deterministic low-base placement" argument is false; (2) **the resulting layout left the GPU
> un-initable** — the injector reload's `RmInitAdapter` failed (`Failed to enable MSI-X` →
> `gpuSanityCheck 0x1` → `osInitNvMapping: Cannot attach gpu`, `0x22:0x38:859`), GPU declared lost;
> recovery required a full **TB deauth/reauth + `fix-bar1 --bind` slot-cycle**. ⇒ **the in-kernel
> `pci_resize_resource` approach does NOT retire `fix-bar1` — the pciehp slot-cycle / re-enumeration is
> LOAD-BEARING for a working GPU, and `pci_resize_resource` alone does not do it.** The source analysis
> (even on the real kernel, exports verified) could not predict the hardware MSI-X/init failure — exactly
> the gap live testing exists to close. See the LIVE RESULT section appended at the bottom. Next: either
> the in-kernel approach must replicate fix-bar1's chip-CTRL-write + slot-cycle (not `pci_resize_resource`),
> or keep `fix-bar1` and just automate it. fix-bar1 (#304/#305-hardened) remains the working recovery.
>
> **⮕ RE-OPENED 2026-06-13 (do not treat as dead):** Stage 1 refuted the NAIVE single-`pci_resize_resource`
> call run on a HEALTHY/aligned tree (it disrupted a *working* GPU) — that is NOT proof the mechanism is
> unsalvageable. UNTESTED and load-bearing: (a) the REAL broken-256 M scenario (the actual use case,
> reproducible via deauth/reauth — Stage 1 used the wrong substrate); (b) placement control (force
> `0x4000000000` / prevent the 128 G window growth); (c) a LIGHTER post-resize re-enumeration (FLR /
> secondary-bus-reset, not a full pciehp slot-cycle). **Pivotal open question: is the `RmInitAdapter`
> failure caused by the ADDRESS MOVE or by DEVICE STATE after the resize?** Under active investigation —
> the "slot-cycle is load-bearing" conclusion is an unverified inference, not established.
>
> **⮕ RESOLVED 2026-06-13 (high confidence): DEVICE STATE, not address — mechanism VIABLE with a 1-line
> fix (`pci_reset_function`/FLR after resize, now implemented as `flr=Y`). The address is exonerated (the
> GPU is healthy at `0x6000000000` right now). See the INVESTIGATION RESULT section at the bottom. Pending
> live re-test on the REAL broken-256 M substrate — the slot-cycle is likely NOT required.**

## Verdict (naive no-reset single-call REFUTED; mechanism VIABLE w/ FLR fix — see banners + INVESTIGATION RESULT)
**E27's broken-BAR1 recovery can be made fully deterministic from an out-of-tree kernel module — no
kernel rebuild, no cmdline — and a SINGLE module sequence retires `fix-bar1` entirely (both halves).
Confidence: high. Status: conditional, pending one live n≥3 aged-tree experiment.** Resolved against the
REAL running kernel (`/usr/src/kernels/7.0.9-204.fc44.x86_64/Module.symvers` + `ioport.h` + `pci.h`), not
a proxy.

## Source-fidelity provenance (why this supersedes the earlier survey)
The first determinism pass ran against `/root/linux-v6.19` as a proxy (the live kernel ships no readable
`drivers/pci/*.c`). On challenge, real upstream **v7.0.9** `drivers/pci` was fetched (kernel.org stable)
and the load-bearing symbol/semantics facts cross-checked against the **actual Fedora 7.0.9-204** tree on
disk. Two corrections resulted:
- **CORRECTION (mine, retracted):** an interim claim that "the 6.19 `b_res->parent` already-assigned skip
  is gone in 7.0.9" was a shallow-grep error. It **survives** as `setup-bus.c:1293
  `if (resource_assigned(b_res)) return;`` (`resource_assigned() == res->parent`, `ioport.h:347`). The
  "can't re-size an assigned window without releasing it first" wall still exists.
- **The real 7.0.9 delta** that makes this solvable: `pci_resize_resource` gained a 4th arg
  (`exclude_bars`) and now routes through the **exported** `pci_do_resource_release_and_resize →
  pbus_reassign_bridge_resources`, a release-and-reassign cascade reachable from an out-of-tree module.
  A 6.19-keyed analysis would have concluded "needs a kernel patch"; the real source moves it to
  "deterministic, module-reachable."

## Root cause of the non-determinism (resolved)
NOT fragmentation/occupancy, NOT our `resource_alignment` param, NOT retry exhaustion. **The root
hotplug port `00:07.0`'s OWN prefetch window freezes at a misaligned base on aged trees.** In the 06-05
failure it was `0x4810000000-0x500fffffff` — 32 GiB-sized but **256 MiB off the 32 GiB grid**
(`0x4810000000 mod 32G = 0x10000000`). The `resource_assigned()` skip then refuses to re-size it, and
neither the pciehp power-cycle (`pci_assign_unassigned_bridge_resources`, `pciehp_pci.c:64`) nor the
optional-grant retry (`reassign_resources_sorted → pci_reassign_resource`, `setup-res.c:375-412`, which
requires `res->parent` and only GROWS in place) can re-place an already-assigned window. Inside the
misaligned window the only 32 G-aligned interior slot is `0x5000000000` with ~256 MiB room → intermediate
bridge squished to 256 MiB → 32 G child "can't assign; no space" → GPU off-bus, `fix-bar1` rc=1.

The 32 GiB alignment is **natural** — propagated up from the GPU's 32 GiB BAR1 via `calculate_head_align`
(`setup-bus.c:1175-1208,1342-1344`); 7.0.9's `pbus_size_mem` dropped the `relaxed_align` escape hatch,
making the failure MORE deterministic. **`resource_alignment=35@0000:03:00.0` is redundant/not causal**
(`pci.c:6468-6518` only aligns device BARs and disables bridge windows; it cannot pin a bridge-window
base). Do not retarget it expecting a fix.

## The deterministic mechanism (the experiment module)
An out-of-tree module, run with the GPU on-bus but **nvidia unbound** and **memory-decode OFF**:
1. clear `PCI_COMMAND_MEMORY` on the GPU (decode off);
2. `pci_release_resource()` the **prefetch window of each empty downstream port** on the GPU's parent bus
   (live: `03:01.0/03:02.0/03:03.0`, ~10.7 GiB windows each, children of `02:00.0`'s window) — REQUIRED
   because the cascade's `!res->child` guard (`setup-bus.c:2275`) refuses to release `02:00.0`'s window
   while these assigned siblings remain, so a naive single `pci_resize_resource(GPU)` dies at `02:00.0`
   and never re-places `00:07.0`;
3. `pci_resize_resource(GPU, 1 /*BAR1*/, 15 /*32 GiB*/, 0 /*exclude_bars*/)` — now the cascade releases
   `03:00.0 → 02:00.0 → 00:07.0` (each childless in turn), `__pci_bus_size_bridges` re-sizes `00:07.0`
   WITH the `hpmmioprefsize` reserve (`setup-bus.c:1425-1428`, `is_hotplug_bridge`), and
   `__pci_bridge_assign_resources` re-places it **bottom-up first-fit** (`bus.c:190-289`) at the
   firmware-constant `0x4000000000` (verified `/proc/iomem` "PCI Bus 0000:00"; the eGPU subtree is the
   aperture's only prefetch consumer, so the landing is deterministic).

**Half (a) is subsumed:** `pci_do_resource_release_and_resize` calls `pci_rebar_set_size(pdev, resno, 15)`
(`setup-bus.c:2345`) — writing the chip's Physical ReBAR CTRL `0x8→0xF` as part of the same call. So this
one sequence performs BOTH the chip-CTRL restore AND the 32 G-aligned window assembly, replacing
`fix-bar1`'s config write AND its pciehp slot power-cycle entirely.

## Exported-symbol receipts (real kernel `Module.symvers`)
| Symbol | Export | Signature (real `pci.h`) |
|---|---|---|
| `pci_resize_resource` | `EXPORT_SYMBOL` (non-GPL) | `int pci_resize_resource(struct pci_dev*, int i, int size, int exclude_bars)` |
| `pci_release_resource` | `EXPORT_SYMBOL` (non-GPL) | `int pci_release_resource(struct pci_dev*, int resno)` |
| `pci_bus_size_bridges` | `EXPORT_SYMBOL` (non-GPL) | `void pci_bus_size_bridges(struct pci_bus*)` |
| `pci_assign_unassigned_bridge_resources` | `EXPORT_SYMBOL_GPL` | `void …(struct pci_dev *bridge)` (fallback path → GPL module) |

Prefetch window resno = `PCI_BRIDGE_PREF_MEM_WINDOW = PCI_BRIDGE_RESOURCES + 2`. `preserve_config` is
false on this host (realloc demonstrably ran; no `pci=preserve_config`), so `pci_resize_resource`'s
preserve gate passes.

## Decisive experiment (n≥3)
Aged tree (`00:07.0` base ≠ `0x4000000000`), GPU on-bus, nvidia unbound. Module: decode-off → release
empty-port sibling prefetch windows → `pci_resize_resource(gpu,1,15,0)`; log rc + pre/post `00:07.0` +
GPU BAR1. **PASS** = `00:07.0` prefetch base == `0x4000000000` AND GPU BAR1 == 32 GiB at a 32 G-aligned
base AND nvidia probe rc=0, repeated **n≥3** on independently re-aged trees. **FAIL** = `00:07.0` ≠
`0x4000000000`, or non-zero `pci_resize_resource`, or "was not released" on `00:07.0`.

## Fallback if the resize-cascade is flaky
Explicit bottom-up release chain via exported primitives: `pci_release_resource()` on GPU prefetch BARs →
`03:0x.0` windows → `02:00.0` window → `00:07.0` window (each childless in turn), then
`pci_assign_unassigned_bridge_resources(00:07.0)` (GPL → GPL shim module). If even that is
non-deterministic (e.g. a second `00:07.x` prefetch consumer occupies the low aperture between cycles),
`fix-bar1` cannot be retired out-of-kernel — remaining options are a `drivers/pci` patch (out of reach:
stock kernel, no build pipeline) or a boot-time hard reservation (no cmdline expresses a bridge-window
base pin).

## Why conditional, not "solved"
Untested live; the obvious single-`pci_resize_resource` call is provably insufficient (siblings must be
released first — confirmed live). Live unknowns: release ordering under the hotplug `reset_lock` with
nvidia unbound; a hypothetical second `00:07.x` prefetch consumer. Per project burn-history, do not claim
`fix-bar1` retired until the n≥3 aged-tree experiment passes.

## Corrections to prior docs (apply)
- **`finding-2026-06-05-E27-intermediate-bridge-window.md`** + memories
  `project_rebar_sysfs_bridge_window_bottleneck_2026_05_28` /
  `project_h1_revised_chip_rebar_control_state_2026_05_28`: the "`02:00.0` starves at 256 MiB on the
  native path" framing is an **artifact** — that 256 MiB window appears only INSIDE `fix-bar1`'s
  slot-cycle (chip=32 GiB); the native path is graceful (chip=256 MiB, kernel sizes to it). The binding
  constraint is the **`00:07.0` misaligned-window** cause above, not an intermediate-bridge bottleneck.

## Cross-refs
Survey: workflow `e27-survey-scoping`. Determinism: workflow `e27-halfb-determinism-7009` (real source).
Real source: `/root/linux-7.0.9-pci` (upstream v7.0.9 `drivers/pci`; SRPM-diff before shipping a patch —
load-bearing symbols already cross-checked vs Fedora `Module.symvers`/`ioport.h`). Experiment module +
harness: `tools/e27-bar1-rearm/` (this campaign). Stopgap: `tools/fix-bar1.sh` (#304/#305 hardened).

## LIVE RESULT — 2026-06-13 (Stages 0 + 1; module `tbegpu_bar1_rearm`, reviewed, `pci_lock_rescan_remove`-bracketed)
**Stage 0 (dry-run, n=1): PASS.** Survey correct — identified exactly the 3 empty downstream-port
siblings (`03:01/02/03`) and their assigned prefetch windows; the plan (decode-off → release ×3 →
`pci_resize_resource(04:00.0,1,15,0)`) is right; zero writes (PRE == POST); module loads/unloads clean;
host alive. Confirms the module is *correct + safe* and the sibling-walk (the review must-fix) enumerates
right under the lock.

**Stage 1 (wet, aligned positive control, n=1): the module is SAFE but the APPROACH FAILS.**
- Mechanism executed: decode cleared, 3 siblings released (rc=0 each), `pci_resize_resource` rc=0,
  `RESULT=OK`, BAR1 32 G/32 G-aligned, host alive — no wedge (this is the *safety* pass).
- **BUT the window moved to `0x6000000000`** (root-port window grew 64 G → 128 G), NOT the predicted
  `0x4000000000`. The "deterministic firmware-constant low placement" argument is **falsified**.
- **AND the moved layout broke the GPU:** the injector reload's `RmInitAdapter` failed (`Failed to
  enable MSI-X`, `gpuSanityCheck 0x1`, `osInitNvMapping: Cannot attach gpu`, `0x22:0x38:859`), GPU
  declared lost (apnex.33 F40b/A12 bounded it `rc=-5`, C5 sink PERMANENT_FAIL — host alive, contained).
  Recovery needed a full **TB deauth/reauth + `fix-bar1 --bind` slot-cycle** (BAR0 MMIO still read fine
  throughout — chip alive; it was the altered PCI resource layout that broke init).

**CONCLUSION (refutes the verdict):** `pci_resize_resource` produces a sysfs-valid 32 G-aligned BAR1 but
(a) places it non-deterministically and (b) leaves the GPU un-initable — it does **not** yield a working
GPU and does **not** retire `fix-bar1`. **fix-bar1's pciehp slot-cycle re-enumeration is load-bearing**
(it is what makes the GPU init after BAR recovery), and `pci_resize_resource` does not perform it. The
source analysis was right about the PCI-resource algebra and wrong about the hardware outcome — the
exact gap live testing exists to expose. Host left healthy on the `0x6000000000` layout (functional; a
reboot would restore the pristine `0x4000000000` base). Soak clock reset by the run.

**NEXT (re-scope):** (1) test the **fallback** path (explicit release chain +
`pci_assign_unassigned_bridge_resources`) — but it likely hits the same no-re-enumeration wall; (2) more
likely, an in-kernel E27 must replicate fix-bar1's actual mechanism (chip ReBAR-CTRL write **+ a pciehp
slot power-cycle / FLR re-enumeration**), since the slot-cycle is the load-bearing step — i.e. the
in-kernel version is "automate fix-bar1," not "replace its slot-cycle with `pci_resize_resource`"; (3)
or keep `fix-bar1` and just automate it via a TB-attach udev/boltd trigger. The window-placement
non-determinism (Stage 2's original question) is now moot for this approach — it failed for a more basic
reason.

## INVESTIGATION RESULT — 2026-06-13 (workflow `e27-resize-salvage`, high confidence) — MECHANISM VIABLE WITH A 1-LINE FIX
**The Stage-1 failure was DEVICE STATE, not the address move — and the mechanism is salvageable.**
- **Address exonerated (decisive live ground truth):** the GPU is bound + healthy RIGHT NOW at BAR1
  `0x6000000000` (the exact "failing" address). The recovery (deauth/reauth + `fix-bar1 --bind`) KEPT that
  base and only *reset/re-enumerated*. The failing address hosts a working GPU ⇒ the address is not the
  cause; the reset is the load-bearing step.
- **Root cause:** `gpuSanityCheck 0x1` = a live BAR0 BOOT_0 read returned garbage while config/decode/BAR0
  all checked out (the other 3 sanity bits passed) — a wedged register interface. We moved BAR1 of an
  *already-RM-initialized* chip (GSP up, internal aperture latched at `0x4000000000`); the reload's
  probe-time `nv_resize_pcie_bars` early-returned no-op (BAR1 already 32 G) so **nothing reset the chip** →
  internal-aperture-vs-config desync → dead MMIO. The MSI-X (BAR0-resident) + conf_compute failures are
  downstream red herrings. NVIDIA's own probe does the identical resize with NO reset and works *on a
  fresh chip* — confirming the missing ingredient is a reset, not the destination.
- **THE FIX (implemented):** keep `pci_resize_resource`, drop the "land at `0x4000000000`" idea, add one
  `pci_reset_function(gpu_dev)` (FLR; `EXPORT_SYMBOL_GPL`, GPU advertises FLReset+) after the resize,
  outside the rescan lock, only on `resize_rc==0`. It PRESERVES the resized BAR (save_state captures the
  new base + ReBAR CTRL; `pci_restore_rebar_state` re-latches 32 G/0xF). Shipped as the `flr=Y` module
  param (`flr=N` isolates resize-only).
- **NEXT (live, n≥3, on the REAL broken-256 M substrate — reproducible via deauth/reauth):** (E1) run the
  module `flr=0` on broken-256 M — predicted likely PASS *without* a reset (a never-RM-init'd chip matches
  nvidia's fresh-device precondition; Stage-1 used the WRONG healthy substrate); (E2) `flr=1` if E1 fails —
  predicted PASS at any address. **Honest residual (adversarial):** the real fix changes BAR1 *size*
  (256 M→32 G), not just base; if Blackwell only re-samples its ReBAR aperture at a true link-down/PERST,
  FLR (and even secondary-bus-reset) could be insufficient and fix-bar1's slot power-cycle irreplaceable
  for the *size* re-latch — the one path back to "automate fix-bar1, not replace its slot-cycle." Source
  counter-evidence (nvidia resizes size with no reset on fresh chips; ReBAR spec forbids a link reset for
  size change) makes this unlikely, but **validate live — source already mispredicted the placement once.**

## E1 LIVE RESULT — 2026-06-13 (flr=0 on the REAL broken-256 M substrate → HOST WEDGE) — capture `/root/netconsole-stage01-new.log`
**E1 (resize, NO reset) FAILED on the real substrate, and the recover module's response wedged the host.
The size-relatch residual is REAL.** Chain (capture line refs):
- **Step B (module `flr=0`) succeeded cleanly** (L307-358): broken 256 M → released 3 siblings → resize →
  BAR1 32 G @ `0x6000000000` (this time the window did NOT grow to 128 G — siblings re-placed higher;
  `00:07.0` stayed 64 G), `RESULT=OK`, host alive.
- **Step C (`modprobe nvidia`, recover=1) — init FAILED with a NEW, more fundamental error** (L359-381):
  `kbusVerifyBar2_GB202: MMUTest BAR2 readback ... returned garbage 0xffffffff` → `NV_ERR_MEMORY_ERROR`
  → `RmInitNvDevice: Cannot initialize the device` → `RmInitAdapter failed! (0x24:0x72:1307)`. This is the
  **GPU's memory-aperture subsystem desynced** because the 256 M→32 G *size* change was never latched into
  the chip (no reset) — distinct from Stage-1's base-only BOOT_0 failure; the *size* change is the deeper
  problem the investigation flagged.
- **THE WEDGE = the A3 recover module (recover=1), not my module** (L383-401): the init failure was first
  *contained* (`open completed within budget rc=-5`), but `tb_egpu recover` then fired (attempt 1/3) and
  did `pci_reset_bus(03:00.0)` (a secondary-bus / link-down reset — **NOT ReBAR-aware**, so it reverts the
  chip toward 256 M without re-latching 32 G), reported "RECOVERED" (PMC_BOOT_0 read OK post-reset), then
  **retried the open** (L400 "external GPU detected") — and the retry's MMIO against the now-re-desynced
  32 G aperture **wedged the host** (completion-timeout class; capture ends mid-retry). Operator rebooted.

**CONCLUSIONS:**
1. **`flr=0` (resize without reset) does NOT work on the real size change** — confirms a reset IS required
   (vindicates the FLR direction). Failure signature: `kbusVerifyBar2` BAR2 aperture garbage.
2. **The recover module's generic bus-reset is dangerous on a ReBAR-resized chip** (not ReBAR-aware →
   re-desync → retry wedge). Any E27 experiment that can leave a BAR/chip-size mismatch MUST run with
   **`NVreg_TbEgpuRecoverEnable=0`** so the recover retry can't fire.
3. **The size-relatch residual is now central, leaning toward the worst case:** even the recover's
   *link-down* bus-reset did not cleanly re-latch 32 G here. fix-bar1's slot power-cycle (true PERST) is the
   proven path. **NEXT = E2: `flr=1` (FLR, BAR/ReBAR-preserving via `pci_restore_rebar_state`) WITH
   `recover=0`** — does a BAR-aware FLR applied *before* any init (resource tree at 32 G) re-latch the size
   where the recover's after-the-fact SBR did not? If E2 also fails, the verdict shifts to "the in-kernel
   mechanism must do fix-bar1's slot-cycle/PERST" — automate fix-bar1, not replace its slot-cycle. **Process
   lesson:** the modprobe test ran with recover=1 — should have been recover=0 (recover-disabled-control
   discipline); that turned a contained init-fail into a host wedge.

## A3 RESET-PATH CHECK — 2026-06-13 (workflow `e27-a3-reset-rebar-check`, medium confidence) — H-B resolved; FLR likely doomed; mechanism re-scoped to PERST
**A3 DID restore the ReBAR to 32 G after its bus-reset — so the wedge was NOT a forgotten-restore; the
Blackwell genuinely won't re-latch a 256 M→32 G SIZE change without a PERST.** A3's `pci_reset_bus`
(nv-tb-egpu-recover.c:410) runs the kernel save/restore wrapper → `pci_restore_state` →
`pci_restore_rebar_state` re-derived 32 G from the live `dev->resource[1]` and rewrote ReBAR CTRL=0xF
*after* the link-down SBR (A3's own slot_reset/resume helpers are BAR0-only telemetry). The retry still
wedged ⇒ the chip never re-fenced its internal aperture to 32 G; the retry's MMIO hit a
config-32 G/chip-256 M mismatch → the documented broken-BAR1 hard-wedge.
- **E2 (`flr=1`) odds: likely FAILS.** Two resets already failed to re-latch (the bare config write; the
  SBR-plus-ReBAR-restore). FLR uses the *identical* restore wrapper but a *weaker* reset (no link-down)
  than the SBR that failed. A size re-latch needs the chip to re-sample its BAR from a PERST/cold state.
  Honest residual (why "medium" not "high"): E1's wedge happened on a chip *poisoned by a prior failed
  init*; a clean-ordering `flr=1`+`recover=0` run on a fresh resize *might* still pass — but the
  instant-hard-MMIO-wedge signature is the aperture-mismatch signature, not init-poisoning.
- **REVISED MECHANISM:** the size relatch is not achievable by any in-kernel config-write + GPU/bridge
  function-or-secondary-bus reset. E27 recovery must (a) decode-off; (b) program GPU ReBAR=32 G AND
  release+widen+realign the root-port `00:07.0` prefetch window; (c) **slot power-cycle / PERST +
  re-enumerate (fix-bar1's mechanism)**; (d) then bind. i.e. **automate fix-bar1's slot-cycle, not replace
  it.** Not a defeat — an in-kernel/auto-triggered version still retires the userspace step.
- **A3 HARDENING (needed regardless — real latent bug):** `tb_egpu_recover_slot_reset`
  (nv-tb-egpu-recover.c:602-625) declares RECOVERED on a single BAR0 PMC_BOOT_0 read — *size-blind*, a
  guaranteed false-positive for broken-BAR1, then lets a retry MMIO wedge. Fix: BAR-aware verification
  (read ReBAR current size + a BAR2 sentinel before RECOVERED → surrender on mismatch); signature-gate the
  broken-BAR1 class to slot-cycle-or-PERMANENT_FAIL (NEVER retry-MMIO a desynced chip); escalate (SBR→slot-
  cycle) don't repeat; keep `recover=0` default until BAR-aware gating lands.
- **NEXT:** one CONTAINED `flr=1`+`recover=0` run definitively closes FLR (the wedge was the recover
  retry, removed by `recover=0`; E1's first modprobe was contained). If it fails (predicted) → build the
  PERST automation (auto-trigger fix-bar1 now + A3 hardening; in-kernel slot-cycle module as the
  destination). The earlier optimistic FLR-fix banner is SUPERSEDED by this section.

## E2 LIVE RESULT — 2026-06-13 (flr=1 + recover=0 on the REAL broken-256 M substrate → PASS, n=1) — THE FLR FIX WORKS; the A3-check prediction is REFUTED
**Mechanism VIABLE.** Contained run (recover=0): deauth/reauth → broken 256 M → module `flr=1` (release 3
siblings → `pci_resize_resource` rc=0 → `pci_reset_function`/FLR rc=0; BAR1 32 G @ `0x6000000000`,
ReBAR CTRL=0xf21) → `modprobe --ignore-install nvidia` (recover=0) → **`RmInitAdapter` SUCCEEDED**
(`open completed within budget rc=0`, no `kbusVerifyBar2`, no recover fire). `nvidia-smi`: RTX 5090,
32607 MiB, P8; BAR1 PCI region `[size=32G]`; `/dev/nvidia*` + uvm present; **zero error-class lines**.
- **Why the A3-check predicted FAIL but E2 PASSED:** the prediction rested on "two resets already failed +
  FLR is weaker than the SBR." But neither prior was a clean FLR-*before*-init: E1's flr=0 was NO reset,
  and A3's SBR ran *after* a failed init had already poisoned the chip. The variable was reset **TIMING
  (clean fresh chip, before any init)**, not reset strength — exactly the residual the A3-check honestly
  flagged. A `pci_reset_function` (FLR) applied to a freshly-resized, never-RM-initialized chip DOES
  re-latch the 256 M→32 G size.
- **REVISED MECHANISM (back to the light path):** broken-256 M recovery = decode-off → release sibling
  prefetch windows → `pci_resize_resource(32 G)` → `pci_reset_function`/FLR → bind. NO slot-cycle/PERST
  required. `recover=0` is needed only as a SAFETY BELT (so a *failed* recovery can't trigger A3's
  wedge-prone retry); on a SUCCESSFUL recovery nvidia inits clean and A3 never fires.
- **STILL OPEN:** (1) **n≥3 determinism** (this is n=1 — confirm it's reliable, incl. the
  0x6000000000-vs-0x4000000000 placement variance and aged trees); (2) the A3 hardening (BAR-aware
  RECOVERED gate + signature gating) so recover can stay ENABLED in production without wedging on a
  failed recovery; (3) merge into the unified recovery. The "automate fix-bar1's slot-cycle" pivot is
  DEMOTED to the fallback if n≥3 shows non-determinism. **Lesson: don't over-conclude failure from
  source inference — the contained live check flipped a medium-confidence "doomed" to a working PASS
  ([[feedback-dont-give-up-pursue-creative-solutions]]).**

## E2 CYCLE-2 + SHUTDOWN FORENSICS — 2026-06-13 (n=1 PASS didn't replicate; likely a SETTLE-TIME variable, NOT proof FLR is dead)
**FLR-without-settle/verify is unreliable — but there is a strong untested, CONTROLLABLE variable
(post-reset settle time), so this is NOT "FLR is dead."** Evidence (prior-boot `journalctl -b -1`):
- **Cycle 2 FAILED** — same `flr=1` (module: resize + `pci_reset_function` rc=0, RESULT=OK, BAR1 32 G),
  but `modprobe` init **failed** at `kbusVerifyBar2_GB202` garbage `0xffffffff` → `RmInitAdapter
  0x24:0x72:1307` (contained, recover=0, rc=-5). So with identical kernel-side steps, the chip relatched
  in cycle 1 and did NOT in cycle 2 ⇒ **the FLR ReBAR-size relatch is NON-DETERMINISTIC** (cycle-1 PASS
  was a lucky draw, not viability). FLR (no link-down) is physically borderline for a size re-sample.
- **A failed relatch escalates:** the desynced chip stayed accessible + the driver loaded; **11 open
  attempts** hit it (my retry `nvidia-smi` re-triggered a 2nd open → a WORSE state: `_kgspBootGspRm:
  unexpected WPR2 already up` + GSP **crashcat** crash → `RmInitAdapter 0x62:0x40:2131`). Cumulative MMIO
  to the desynced aperture produced a **fatal uncorrectable HARDWARE error → firmware/platform RAS RESET**
  — NOT a kernel panic (no kdump vmcore; panics were armed) and NOT a software shutdown (journal ends
  abruptly at 19:07:41; next boot's `BERT: Total records found: 1 / Skipped 1 error records` = the
  firmware-logged hardware error). `recover=0` contained each init-fail but did NOT prevent the
  degrade-to-platform-reset.

**CONCLUSIONS ([[feedback-dont-give-up-pursue-creative-solutions]] — NOT a surrender; the next move
attacks the controllable variable):**
1. **The cycle-1-vs-cycle-2 difference was TIMING (settle), not pure randomness.** Cycle-1 (PASS) had
   ~seconds between the FLR and `modprobe` (separate commands); cycle-2 (FAIL) had ~ms (one back-to-back
   command). fix-bar1's slot-cycle has explicit settle `sleep`s precisely because the chip needs time to
   re-fence its aperture after a reset. So "resize+FLR is non-deterministic" really means
   "resize+FLR-**without a post-reset settle + verify** is non-deterministic." Don't retract the n=1
   PASS — re-scope it.
2. **NEXT (creative, evidence-based — the actual fix to try):** add to the module, after
   `pci_reset_function`, (a) a **settle delay** (poll a sentinel / msleep), then (b) a **relatch
   VERIFICATION** — read the chip's decoded aperture (ReBAR current size + a BAR2 sentinel) and only
   report success if it shows 32 G. This (i) tests the settle-time hypothesis and (ii) is **fail-safe**:
   on a non-relatch it reports FAIL and we DON'T bind → no degrade-to-platform-reset. Re-test n≥3.
3. **The platform reset was AGGRAVATED by experiment methodology, not purely inherent:** the failed-init
   chip stayed accessible + I retried `nvidia-smi` (11 opens → WPR2/crashcat → fatal HW error → firmware
   RAS reset; no kdump panic, next-boot `BERT: 1 record`). A verify-before-bind + fail-safe quiesce (never
   bind/retry-MMIO an unrelatched chip) removes that escalation — needed regardless, and it makes further
   FLR testing SAFE.
4. **fix-bar1's slot-cycle/PERST remains the proven FALLBACK** (deterministic, n≥5) if settle+verify
   still can't make FLR reliable — but it is NOT the foregone conclusion. **This SUPERSEDES the E2 LIVE
   PASS "VIABLE" banner above (re-scoped to "viable WITH settle+verify, pending n≥3"), not the
   mechanism.**

## 2026-06-14 — PRE-FLIGHT REVIEW → E2-VERIFY REDESIGN (verify-before-bind gate; BUILT + RE-REVIEWED, wet run pending)
Before committing the operator to the "E2-with-settle" wet run, two adversarial review rounds (opus
workflows) pressure-tested the module + procedure. They **reshaped the test** — the as-specified
settle-then-blind-bind was inconclusive *by construction* and repeated reset-risk footguns.

**Central discovery (3 of 4 pre-flight lenses, independently): `RESULT=OK` is a CONFIRMED false-positive.**
The module's old pass criterion read only the in-kernel `struct resource` (BAR1==32 G, aligned), which
`pci_resize_resource`+FLR make true *regardless* of whether the chip re-fenced its internal aperture — it
literally printed `RESULT=OK` in **both** the cycle-1 PASS and the cycle-2 FAIL. A fixed `settle_ms=2000 ×
n≥3` also cannot attribute a PASS to settle (vs "FLR-alone now works" / luck at the ~50% prior).

**The redesign — an in-module verify-before-bind gate** (`tbegpu_bar1_rearm.c`, param `verify=Y`): after
the FLR, re-enable memory decode, `ioremap` BAR0+BAR2, **poll `PMC_BOOT_0` (gate) + `BAR2[0]` (logged
diagnostic)** up to `settle_ms`, log time-to-sane, and gate `RESULT=OK` on a sane readback (+ `frc==0`).
This turns the wall-clock gamble into a readiness gate, makes `RESULT` honest, measures the relatch latency
directly, and mechanizes the fail-safe (only ever bless a verified chip). `verify=N` reverts to the blind
`msleep` control arm.

> **HONESTY CAVEAT (carried in-code + README):** `PMC_BOOT_0` lives in BAR0 (the register aperture), but the
> cycle-2 desync is in the **BAR2 MMU path** — so boot0 can read sane while BAR2 is stale. The gate
> therefore reliably catches the Stage-1 *dead-chip / BOOT_0-garbage* class but does **not** by itself
> discriminate the cycle-2 BAR2 desync. `BAR2[0]` raw is logged (not hard-gated — a raw read without RM's
> MMU setup is only a proxy) to learn empirically whether `0xffffffff` predicts the bind FAIL. **The true
> verdict stays `RmInitAdapter rc=0`**, backstopped by the runbook's atomic single-open + immediate-rmmod
> fail-safe (a boot0-false-pass costs one rc=-5-contained bind, never a reset).

**The hardened runbook `tools/e27-bar1-rearm/e2-verify.sh`** (NOT `run-experiment.sh` stage 2 — that
predates the 256 M root cause and stops at the false-positive `RESULT=OK`). Operator-gated verbs
(`preflight`/`status`/`substrate`/`rearm`/`bind`/`cycle`/`restore`/`teardown`), encoding every must-fix:
- **`recover=0` proven** by a resolved-arg dry-run (`modprobe -n -v --ignore-install nvidia | grep
  TbEgpuRecoverEnable | tail -1` ends in `=0`) **and** the loaded-module param (`cat .../NVreg_…==0`) — not
  `modprobe -c | grep` (which shows both `=1`/`=0` lines). A recover-fire tripwire discards + flags host-suspect.
- **`reset_method=flr` pinned** (preflight + re-pinned each cycle after reauth + asserted in `rearm`) so
  `pci_reset_function` can't escalate to a link-down slot/bus reset during the lock-dropped settle.
- **Per-cycle substrate assertion**: BAR1==256 MiB *exactly* AND chip ReBAR nibble==8 (reject off-bus/healthy/other).
- **Capture hard-gated** (netconsole enabled AND `hardlockup_panic==1`) at every wet verb, fatal — the
  on-host session's only net; `nvidia-persistenced` masked + injector drained so no auto-consumer opens
  the device in the fail window.
- **Atomic bind**: a single device open (`nvidia-smi -pm 1`, persistence-first per fix-bar1's close-path
  hazard); on FAIL it `rmmod`s immediately and **never re-opens** (the 11-retry hammering is what escalated
  cycle-2 to a platform reset); scores ONLY by `RmInitAdapter` and classifies the rc-triplet.

**Pre-registered decision rule:** one `0x24:0x72:1307` settle-FAIL at the adopted `settle_ms` REFUTES
determinism (do NOT retire fix-bar1) — the runbook declares it loudly and STOPs. A determinism claim needs
**≥10–12 consecutive clean binds** on independently re-deauth/reauth'd substrates; n≥3 is "promising". A
REARM-FAIL on a *valid* substrate is a recorded NEGATIVE (the light reset failed to reach a bindable state),
not a discard. NOTE: `verify=Y` adds post-FLR MMIO that `verify=N` lacks, so `verify=N` is a blind baseline,
not a strict A/B twin.

**Reviews:** pre-flight (4 lenses) + code re-review (3 lenses), opus. Module MMIO path cleared
`ship_ready` (BAR indices right, no ioremap leak/double-unmap, decode handling correct, the single readl
bounded by the PCIe completion timeout — categorically unlike the 11 GSP-bringup opens; fix-bar1/A3 read
`PMC_BOOT_0` routinely). **Must-fixes applied:** the `do_bind` rc-triplet regex (`[0-9a-f:]` excluded `x`
→ could never match `0x24:0x72:1307` → the decision rule couldn't be scored); the wet-verb capture
hard-gate (was preflight-only WARN). Plus should-fixes (fatal flr re-pin, `rearm` flr assert, settle-FAIL
STOP, REARM-FAIL-as-negative) and module nits (BAR2-stale caveat on the OK line, `frc=-1` skip-vs-fail
distinction, BAR2 ioremap pr_warn, settle clamp). Module builds clean (vermagic match); script `bash -n`
+ shellcheck clean; the triplet regex verified to match live.

**Fallback reality (determinism lens):** earliest-hook ReBAR-write and "in-kernel fix-bar1" both reduce to
needing the **slot-cycle/PERST, which has no exported symbol** (and A3 proved an SBR does NOT re-latch the
256 M→32 G size). So if FLR+verify stays flaky, the real fallback is a **udev/boltd-triggered
`fix-bar1.sh`**, not an in-kernel SBR.

**STATUS: BUILT + RE-REVIEWED + READY. Wet run (E2-verify, operator-at-console, capture armed) PENDING.**
