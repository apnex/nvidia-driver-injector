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

## Verdict (⛔ REFUTED — see banner above)
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
