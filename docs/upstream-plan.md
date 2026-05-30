# Upstream submission plan

**Status:** draft — 2026-05-22 (rev: C/E/A geometry). Defines the target set;
it does not authorise filing or opening pull requests (see [Gate](#gate)).

## Purpose

Phase 3 of the patch work: identify and submit the subset of this project's
patches that belongs in NVIDIA's upstream `open-gpu-kernel-modules`, for the
benefit of every open-driver user — not just Thunderbolt eGPU users.

This document is the *target set* and the per-PR spec. The upstream-bound set
is **six target PRs** — five core-path (`C1`–`C5`) + one eGPU-path (`E1`).
(`C3` may split in two if review prefers → up to seven.) Everything else stays
project-local in the **Addon layer** (`A`) and never becomes a PR.

## Geometry — C / E / A

This doc also defines the project's target patch geometry. Three prefixes, one
per placement-principle category:

| Prefix | Meaning | Destination | Layer |
|---|---|---|---|
| **C** | Core, transport-agnostic | upstream PR | base |
| **E** | eGPU-specific, `is_external_gpu`-gated | upstream PR | base |
| **A** | Addon — project-local | never a PR | additive |

The production driver is **base (`C` + `E`) + additive (`A`)**. The base layer
is clean and de-brandable; the additive layer is the genuinely project-local
code — the bus-loss watchdog, the self-triggered recovery and its policy,
observability, build metadata. The fork then reads "stock driver + known
deltas" and shrinks monotonically as base PRs land upstream — its floor is the
additive layer alone. (The kernel-cmdline / bridge-cap host setup is a separate
Layer-1 concern, not patch geometry.)

The carving design pass (Execution, below) migrates today's seven `tb_egpu_*`
clusters (`P1`–`P7`, the pre-carve geometry) into this `C`/`E`/`A` geometry.
`P1`–`P7` is retired terminology once the carve completes.

## Placement principle

Every piece of the project's patch set is sorted by *where it correctly
belongs*. The rule, in priority order — each category carries its prefix:

1. **Core, transport-agnostic paths — the default → `C`.** If a change benefits
   every open-driver user — or *can be generalised* to — it belongs in the
   driver's core logic, behind no eGPU gate. "It was discovered through eGPU
   work" is not a reason to scope it to eGPU. Push to core wherever possible.
   This is the `C1`–`C5` set.

2. **The eGPU code path — the exception, kept minimal → `E`.** Only code that
   is *intrinsically* eGPU-specific — cannot be generalised without harming the
   general case — *and* is a genuine correctness fix (not a workaround) belongs
   here. It must be **gated on the driver's existing `is_external_gpu` flag**
   (zero cost to internal GPUs) and **neatly centralised**. This is the `E`
   set — currently a single member, `E1`. A one-member set is correct: `E` is a
   real structural category (eGPU code has a distinct gating and review
   framing), and it leaves room if NVIDIA engagement ever makes an `E2`
   worthwhile.

3. **Project-local — the Addon layer → `A`.** Three things live here: this
   project's *operational policy* (recovery-gate values, kill-switch, the
   `TB_EGPU_GPU_STATE` uevent); its *workarounds for failure modes upstream has
   not root-caused* (the bus-loss watchdog, the self-triggered recovery); and
   its observability and build metadata. Never upstreamed — this project
   carries it. This is *not* an anti-tunable rule: a genuine general user
   choice can be a fine upstream module parameter. What stays local is code
   that exists only to encode *this deployment's* opinion, or to paper over a
   root cause that is not ours to fix.

4. **A different upstream.** Some eGPU-correctness work is not NVIDIA-driver
   code at all — it belongs in the Linux kernel (`drivers/thunderbolt`, PCIe
   core) or NVIDIA GSP firmware. Noted, not owned here; carries no prefix.

"Perfect" for an upstream (`C`/`E`) change also means **de-branded**: stripped
of `tb_egpu_*` / `TB_EGPU_*` naming and `NVreg_TbEgpu*` params, cut to the
minimal correct change — the *mechanism*, re-expressed in neutral form. Addon
(`A`) code stays branded: it is the project's, and cohesion there is worth more
than de-branding.

**Telemetry — nominal, not investigation-grade.** Each upstream patch carries
enough logging to prove its code path ran and to show its outcome — a log line
on the rare, meaningful events, at kernel-appropriate levels (`pci_info` /
`dev_warn` on errors and recoveries; at most one `dev_info` for a per-probe
event). This is the same instrument-so-you-can-prove-what-happened discipline
used during the investigation, calibrated down to *operational* level — it is
explicitly **not** the heavy `[DIAG]` surface, which has been dissolved (see
[Addon layer — A](#addon-layer--a)); every runtime patch now carries its own
nominal telemetry duty. The patch whose value is otherwise invisible — `C3`
(a transient silently recovered) — **must** log; that telemetry is mandatory,
not optional. Each `C`/`E` PR below carries a **Telemetry** line, as do the
runtime addon patches.

## Core set — C1–C5

The transport-agnostic changes: each benefits every open-driver user and goes
in the driver's **core** logic, behind no eGPU gate. Submission order =
C-number (see [Submission order](#submission-order)).

### C1 — Kbuild reads NVIDIA_VERSION from version.mk

- **Source:** cluster P7 (`patches/legacy/0007`), the version.mk-as-truth half only.
- **Change:** `kernel-open/Kbuild` does `include $(src)/../version.mk` and uses
  `$(NVIDIA_VERSION)` for `-DNV_VERSION_STRING`, instead of a hardcoded literal.
- **Benefit to all:** pure build hygiene. Today the version literal can drift
  between `Kbuild` and `version.mk`, so `modinfo` can report a stale version.
  Single-source-of-truth fixes it. Zero coupling to eGPU or PCIe behaviour.
- **De-brand:** none needed — already generic.
- **Scope boundary:** the `NVIDIA_VERSION` *value* and the `CONFIG_NV_TB_EGPU`
  master toggle are NOT part of this — they are Addon (`A5`).
- **Telemetry:** none — no runtime path. `modinfo` showing the correct version
  is the proof-of-correctness.
- **Review risk:** minimal; self-evidently correct. Good trust-builder.
- **Candidacy:** HIGH.
- **Branch:** `c1-kbuild-version-mk` (carved, built, pushed to fork).

### C2 — Clear the AER internal-error mask bits at probe

- **Source:** cluster P5 (`patches/legacy/0002`).
- **Change:** at probe, clear the *internal-error* mask bits — `PCI_ERR_UNC_INTN`
  (Uncorrectable Mask) + `PCI_ERR_COR_INTERNAL` (Correctable Mask) — so the GPU
  stops masking its own internal PCIe errors and demoting them to "advisory
  correctable", which blinds the kernel AER subsystem to real link faults.
  Gated on `pci_find_ext_capability` — a no-op on devices without an AER ext-cap.
- **Kernel-7.0 finding — narrowed + hand-rolled.** Kernel 7.0 added
  `pci_aer_unmask_internal_errors()` (`drivers/pci/pcie/aer.c`) — the surgical
  version doing exactly those two bits. The project's bug was precisely the
  Internal Error bit (`UncMsk=0x00400000`), so **C2 narrows to it**; P5's
  whole-`PCI_ERR_UNCOR_MASK` clear was over-broad. C2 **cannot call** the kernel
  function — it is `EXPORT_SYMBOL_FOR_MODULES(…, "cxl_core")`, not linkable by
  `nvidia.ko`. Widening that export is a separate *Linux-kernel* PR the PCI
  maintainers would likely decline (they restricted it deliberately — "internal
  errors are too device-specific to enable generally"). So C2 hand-rolls the two
  register writes; the kernel function is the canonical *reference for scope*,
  not a callee.
- **Framing:** the kernel's "device-specific" stance reframes C2 honestly as a
  *device-specific* unmask — a call the device's own driver is entitled to make
  — rather than a pure benefit-all change. NVIDIA's Windows closed driver does
  the same clear.
- **De-brand:** drop the `NVreg_TbEgpuAerUncMaskClear` module param entirely —
  no user-facing toggle; the clear is **unconditional**, matching the Windows
  driver. The `pci_find_ext_capability` guard is not an opt-out — just a correct
  no-op where there is no AER ext-cap.
- **Scope boundary:** just the internal-error mask bits — no err_handler wiring
  (that is C4).
- **Telemetry:** one `pci_info` at probe noting the internal-error mask bits
  were cleared — the audit trail for the change in error visibility.
- **Review risk:** low.
- **Candidacy:** MEDIUM-HIGH.
- **Branch:** `c2-aer-internal-unmask` (carved, built, pushed to fork).

### C3 — Retry a transient bus read before declaring the GPU permanently lost

- **Source:** cluster P1 (`patches/legacy/0001`), the retry sub-theme.
- **Change:** before `osHandleGpuLost` commits `PDB_PROP_GPU_IS_LOST`, retry
  the dead-bus read a small bounded number of times (project value: 10× /
  100 µs ≈ 1 ms) — recover a transient, still declare a genuinely-dead GPU
  dead.
- **Benefit to all:** transient `0xFFFFFFFF` reads after a PCIe completion
  timeout are not eGPU-specific — marginal signal integrity, risers, PCIe
  switches, and thermal events all produce them. The open driver's current
  one-strike → permanent-lost, never-retry behaviour is too brittle for
  everyone. This is the fix for the symptom users report in upstream issue #979.
- **De-brand:** remove the `TB_EGPU_*` macros/header (`nv-tb-egpu.h`,
  `TB_EGPU_GPU_LOST_RETRIES`, etc.); express as generic crash-safety with
  neutral names.
- **Scope boundary:** the project's P1 splits in two — *retry-before-declaring-lost*
  (the `osHandleGpuLost` retry) and *don't-crash-when-already-lost* (the
  dead-bus guards: the `osDevReadReg*` short-circuits, `rcdbAddRmGpuDump`,
  `nvdDumpAllEngines`, the `rs_server` deletion paths, the GSP-RPC paths).
  **C3 is the retry sub-theme only** — the smallest reviewable unit that fully
  addresses #979; everything else is `C5`.
  The crash-safety sub-theme is carved separately as **`C5`** (a sibling PR, or
  folded into C3 if review asks). Do not submit all 8 sites at once — that lets
  the PR stall on the least-obvious site.
- **Telemetry (mandatory):** log the *recovery* — "transient bus read recovered
  after N retries" (`dev_warn`) — and log exhaustion. Without the recovery line
  C3 works invisibly and can never be shown to have mattered.
- **Review risk:** moderate. Propose the 10× / 100 µs default as-is, with the
  empirical backing stated; treat the exact number as review-negotiable. Tie
  the PR explicitly to issue #979.
- **Candidacy:** HIGH — the headline fix.
- **Branch:** `c3-gpu-lost-retry` (carved, built, pushed to fork).

### C4 — Register pci_error_handlers — error-recovery scaffolding

- **Source:** cluster P2 (`patches/legacy/0004`), the err_handlers registration only.
- **Change:** populate the `pci_error_handlers` struct in the driver's
  `struct pci_driver`. `error_detected` is **state-aware**:
  `pci_channel_io_normal` (non-fatal) → `PCI_ERS_RESULT_CAN_RECOVER` — a
  non-fatal error must not tear down a working GPU; `pci_channel_io_frozen` and
  `pci_channel_io_perm_failure` → `PCI_ERS_RESULT_DISCONNECT` — the bare driver
  has no reset/recovery, so an honest give-up. `mmio_enabled` is a trivial stub
  returning `PCI_ERS_RESULT_RECOVERED`; `slot_reset` / `resume` are minimal
  correct stubs.
- **Interaction with C2:** C2 un-masks uncorrectable AER errors so they now
  reach `error_detected`. The state-aware branch keeps that safe — a non-fatal
  uncorrectable error returns `CAN_RECOVER`, not `DISCONNECT`. A plain
  unconditional `DISCONNECT` would, combined with C2, convert "silently masked"
  into "kills the GPU". Independent to *submit*, but must stay coherent if both
  land.
- **Benefit to all:** the open driver currently NULL-pads `pci_error_handlers`.
  Any GPU on any topology that hits a PCIe error therefore gets the kernel's
  `AER: can't recover (no error_detected callback)` (this exact line appears in
  third-party logs on issue #979). Registering the struct lets the kernel
  AER/DPC machinery reach the driver. Every mature in-tree PCIe driver does
  this; the open driver is the outlier.
- **De-brand:** the callbacks must be *thin and generic* — return the correct
  `pci_ers_result_t`, carry no project state.
- **Scope boundary:** C4 is the err_handlers registration plus the four
  callbacks. It is the **complete, final** general contribution: the kernel can
  reach the driver, non-fatal errors recover, fatal errors honestly disconnect.
  There is no "real `slot_reset`" PR (see [Considered and dropped](#considered-and-dropped-a-real-slot_reset)).
  The eGPU-specific reset-and-retry recovery is Addon `A3`; the operational
  policy is Addon.
- **Telemetry:** each callback logs its decision and the channel state.
- **Review risk:** moderate. Submit last among C1–C4.
- **Candidacy:** MEDIUM (registration is strictly upstream-improving).
- **Branch:** `c4-err-handlers-scaffold` (carved, built, pushed to fork).

### C5 — Crash-safety: don't panic operating on an already-lost GPU

- **Source:** cluster P1 (`patches/legacy/0001`), the *don't-crash-when-already-lost*
  sub-theme — the sibling of C3.
- **Change, two parts:**
  1. **The os-pci disconnect bridge.** Two kernel-open helpers —
     `os_pci_is_disconnected()` / `os_pci_set_disconnected()` — wrapping the
     kernel's `pci_dev_is_disconnected()` and the `pci_channel_io_perm_failure`
     transition, so RM-side code can query/mark disconnect state without
     including `<linux/pci.h>`. **Already carved** (commit on branch
     `c5-crash-safety`, compile-validated).
  2. **The crash-safety guards.** Bound the call sites that, on the unpatched
     driver, panic or starve the GPU lock when invoked on an already-lost GPU —
     the crash-dump path (`rcdbAddRmGpuDump`, `nvdDumpAllEngines`), the
     `rs_server` deletion paths, the GSP-RPC paths, and the `osDevReadReg*`
     dead-bus short-circuits. **Carved** on `c5-crash-safety`,
     compile-validated.
- **Benefit to all:** crash-safety is transport-agnostic — any GPU that becomes
  lost (signal integrity, thermal, a switch fault) can drive these cascades.
  The unpatched driver turns a lost GPU into a kernel panic or a multi-second
  lock stall; the guards make "GPU lost" a contained, survivable event.
- **De-brand:** remove the `TB_EGPU_*` macros; neutral names.
- **Relationship to C3:** C3 (retry) and C5 (crash-safety) are the two halves
  of cluster P1. C3 leads — it is the smallest unit that closes #979. C5 is the
  sibling PR; review may ask to fold it into C3.
- **Telemetry:** `dev_warn` when a guard short-circuits a cascade on a lost GPU.
- **Review risk:** moderate — several sites; submit after C3 has built credibility.
- **Candidacy:** MEDIUM-HIGH (crash-safety is hard to argue against).
- **Branch:** `c5-crash-safety` (bridge + crash-safety guards carved, compiled, pushed).

### Considered and dropped — a real slot_reset

An earlier draft specified a fifth core item: "a real `slot_reset` that
re-initialises the GPU." Carving it revealed the spec did not match reality.
P2's `slot_reset` is a *bus verification* — `ioremap` BAR0, read `PMC_BOOT_0`,
return `RECOVERED` if the bus is back or `DISCONNECT` if still `0xffffffff` —
**not** a re-init routine. That is not an oversight: the open driver has **no
capability to revive a *running* GPU** (one with live clients / contexts /
allocations) after a hardware reset — the live state is physically destroyed by
the reset. There is no "context-free re-init routine" to extract.

The recovery that genuinely works is *reset + retry the init path* for a
boot-time `rm_init_adapter` failure (no live clients yet) — and that is the
Addon `A3` recovery, not a general `slot_reset`. So the core error-handler
story ends at **C4**: a state-aware `error_detected` that honestly
`DISCONNECT`s on fatal is the complete general contribution.

## eGPU set — E1

Code that is intrinsically eGPU-specific, gated on `is_external_gpu`, and a
genuine correctness fix. Currently one member.

### E1 — Modernise eGPU detection

- **Source:** `RmCheckForExternalGpu` (`osinit.c`) — vanilla NVIDIA code, not a
  project cluster; E1 modernises what NVIDIA already has.
- **Problem:** the existing detection walks the topology for Thunderbolt-3
  bridge vendor IDs + hotplug capability. It does not fire on TB4 / USB4
  hardware (Barlow Ridge, AMD USB4 tunnels) — so modern eGPUs are silently
  misclassified as internal and get internal-GPU power management (a known
  instability source). It is why this project must force `RmForceExternalGpu=1`.
- **Change:** replace the vendor-ID walk with the kernel's own classification —
  `pci_is_thunderbolt_attached()` *or* the firmware-driven `untrusted` /
  `external_facing` markers (which cover USB4 and other external transports).
  Set `is_external_gpu` at probe from the union. The kernel's classification is
  authoritative and TB/USB4-subsystem-maintained — future-proof, and *less*
  code than the walk it replaces.
- **Hardware-verified (2026-05-22):** on the project's Barlow Ridge / Thunderbolt 5
  hardware, `pci_is_thunderbolt_attached()` returns true — the Barlow Ridge
  bridges carry the Intel Thunderbolt VSEC. `untrusted` is the endpoint-local
  union member (it propagates down from the external-facing root port).
- **Why this is `E`, not speculative:** E1 is a *bug fix to NVIDIA's own code*,
  self-evidently correct and smaller than what it replaces. It is core-tier in
  confidence; it is filed under `E` only because it touches eGPU detection.
- **Retires a project workaround:** once a running driver carries E1,
  auto-detection sets `is_external_gpu` correctly and the project drops
  `NVreg_RegistryDwords="RmForceExternalGpu=1"` from modprobe.d. The knob stays
  in the driver as a manual escape hatch; the project just stops needing it.
- **Telemetry:** one `pci_info` at probe — "external GPU detected" — recording
  which kernel marker fired.
- **Benefit to all eGPU users:** correct classification on modern hardware, no
  manual registry override. Prerequisite for the Addon watchdog/recovery
  (`A2`/`A3` gate on `is_external_gpu`).
- **Branch:** `e1-egpu-detection` (carved, built, pushed to fork).

## Addon layer — A

Project-local. **Never upstreamed, in any form** — this project carries it.
The `A` items are *not* PR candidates; they stay branded (`tb_egpu_*`) and live
in the injector's `patches/addon/` set, carved as a fork branch stack on top of
the base layer. Canonical carve spec:
[`docs/superpowers/specs/2026-05-22-addon-recarve-design.md`](superpowers/specs/2026-05-22-addon-recarve-design.md).

The addon set is a **foundation** (`A1`) plus four feature patches
(`A2`–`A5`) — five members. The set is permanent: it shrinks only if a defect
is upstream-rootcaused, at which point its addon goes away — it does not get
promoted upstream.

### Why the watchdog and recovery are Addon, not eGPU-path PRs

`A2` (watchdog) and `A3` (recovery) were earlier drafted as upstream `E2`/`E3`.
They are reclassified as Addon (decided 2026-05-22), for three reasons:

1. **They are workarounds for un-owned root causes.** The watchdog detects
   Mode B — whose root cause is open and never resolved. The recovery papers
   over AER-less failure modes upstream has not acknowledged. A maintainer's
   correct response to a workaround for a bug they have not root-caused is
   *"root-cause it"*, not *"merge the band-aid"*. Issue #979 has had **no
   NVIDIA response in five months** and the community fix PR was closed
   unmerged — speculative workaround PRs would simply rot.
2. **Workarounds get retired, not upstreamed.** `A2`/`A3` exist because the
   real defects (Mode B; the TB/PCIe gaps) are unfixed. The fork "becomes
   unnecessary" when those *root causes* are fixed — at which point `A2`/`A3`
   are *deleted*, not promoted upstream. Upstreaming a workaround merely exports
   the project's maintenance burden to a maintainer who has not accepted the
   bug.
3. **Cohesion.** Keeping the watchdog whole and local — kthread *and* its rich
   five-file `tb_egpu_qwd_*` sysfs together — avoids an artificial up-stream /
   local seam that existed only to manufacture an upstreamable sliver.

The upstream value is delivered better by a tight `C1`–`C5` + `E1` set of
unarguable fixes than by padding it with speculative items; one eyebrow-raising
PR taints reviewer trust in the whole series. Mode B is already in front of
NVIDIA via the issue #979 forensics and outreach — a PR is not needed for that.

### A1 — PCIe primitives (foundation)

- **Source:** cluster P2 (`patches/legacy/0004`), the shared register-read
  primitives slice — carved out as foundation so `A2`/`A3`/`A4` consume one
  copy rather than each carrying its own.
- **What:** the shared PCIe/AER/WPR2 register-read substrate — `read_wpr2`,
  `walk_to_root_port`, `read_dpc_state`, `read_aer_full`,
  `dump_aer_trigger_event`. Lives in a new
  `kernel-open/nvidia/nv-tb-egpu-pcie.{c,h}` module plus a single
  `nvidia-sources.Kbuild` line. Pure code-motion out of `nv-tb-egpu-recover.c`
  — no behaviour change.
- **Why Addon:** a primitive library for the addon layer's PCIe-state
  introspection; its callers are addon by definition.
- **Telemetry:** none — a primitive library; its callers log.

### A2 — Bus-loss watchdog

- **Source:** cluster P3 (`patches/legacy/0003`).
- **What:** a per-eGPU kthread polling `NV_PMC_BOOT_0` at a fixed 200 ms (5 Hz);
  on `0xFFFFFFFF` (dead-bus signature) it marks the GPU disconnected via
  `os_pci_set_disconnected` (the `C5` bridge) so the crash-safety guards and
  err_handlers react, and logs. Carries the rich five-file `tb_egpu_qwd_*`
  sysfs detection-state surface. Gated on `is_external_gpu`. Consumes `A1`'s
  primitives.
- **Why Addon:** a detector for Mode B, an un-root-caused failure — see above.
- **Telemetry:** log on detection only — no per-poll (5 Hz) logging; the
  `tb_egpu_qwd_*` sysfs counters carry the cycle accounting.

### A3 — Self-triggered recovery + recovery policy

- **Source:** cluster P2 (`patches/legacy/0004`), the self-triggered recovery
  slice (not the `pci_error_handlers` registration — that is `C4` — and not
  the shared primitives — those are `A1`).
- **What:** on a trigger — a probe-time `rm_init_adapter` failure (WPR2-stuck),
  or A2's watchdog detection — perform a parent-bridge `pci_reset_bus()` and
  re-run the driver's adapter init, behind a storm-guard. Carries the
  *configurable* H1/H2/H3 gates, the kill-switch file
  (`/var/lib/tb-egpu/recover-killswitch`), and the `TB_EGPU_GPU_STATE` uevent.
  Fills `C4`'s `pci_error_handlers` stub callbacks with real bodies. Consumes
  `A1`'s primitives.
- **Why Addon:** recovery for the project's specific failure taxonomy; the
  storm-guard values are project-tuned policy; depends on A2's trigger.
- **Telemetry (mandatory):** log every fire, gate decision, and outcome — same
  rationale as `C3`: a silent recovery can never be shown to have mattered.
  `tb_egpu_recover_*` sysfs counters.
- **Possible future follow-on:** the narrowest slice — "recover a *probe-time*
  `rm_init_adapter` failure by bridge-reset + retry-init" — is the least
  policy-laden, most general piece. *If* NVIDIA ever engages on #979 it could
  be offered as a core follow-on. Not carved now; noted only.

### A4 — Close-path telemetry

- **Source:** cluster P4 (`patches/legacy/0005`), held to the nominal bar.
- **What:** event-triggered nominal telemetry at close-path transitions —
  markers at RM close callbacks (`nvidia_close_callback` / `nv_stop_device`)
  and UVM open/release (`uvm_open` / `uvm_release`), with a last-close
  marker plus a tight `PMC_BOOT_0`/WPR2/one-word verdict capture on the
  meaningful transition. Re-scoped from P4's broader observational surface to
  the nominal telemetry bar. Consumes `A1`'s primitives.
- **Why Addon:** project-specific bug-class observability; no upstream value.
- **Telemetry:** *is* telemetry — event-triggered only (one line on the
  meaningful last-close transition); no per-call dumping. Audited against the
  Observability audit in the carve design.

### Dissolved — old A4 / DIAG / cluster P6

The concentrated `[DIAG]` diagnostic surface (formerly drafted as `A4`, source
cluster P6, `patches/legacy/0006`) is **dissolved — not carried**. Its job is
covered by the per-patch nominal telemetry the `C`/`E`/`A` patches each carry;
a centralised, compiled-out, investigation-grade dump is redundant once every
runtime patch logs its own operational events. `patches/legacy/0006` remains in
`legacy/` as the documented resurrection source if an investigation reopens.
The `CONFIG_NV_TB_EGPU_DIAG` toggle — which existed only to gate the dissolved
surface — is removed from `A5`.

### A5 — Version value + build toggles

- **Source:** cluster P7 (`patches/legacy/0007`), the project half — the
  `NVIDIA_VERSION` *value* (e.g. `595.71.05-aorus.NN`) and the
  `CONFIG_NV_TB_EGPU` master toggle (documentation-only today). Project
  metadata; the *mechanism* that consumes `NVIDIA_VERSION` is `C1`. **Minus**
  the `CONFIG_NV_TB_EGPU_DIAG` toggle, which is gone with the dissolved DIAG
  surface.
- **Telemetry:** none — build metadata.

### A6–A9 — F40b open/shutdown-arm family (added after the original A1–A5)

Four addons added 2026-05-29..05-31, all project-local (`A`); detail in `docs/patch-intents/A6..A9-*.md`:

- **A6** — bounded-wait wrapper on the open path (`nv_open_device_for_nvlfp`); on timeout, declare the GPU lost via the C5 sink and return `-EIO`. Closes the F40 open-arm host-wedge.
- **A7** — symmetric bounded-wait wrapper on the shutdown path (`rm_shutdown_adapter`), with the SH-3 `flush_work` UAF guard.
- **A8** — read-only `tb_egpu_*` sysfs surface (state + F40b/recovery counters + `tb_egpu_is_external`); observability only.
- **A9** — probe-time eGPU classification: set `nv->is_external_gpu` in `nv_pci_probe` via E1's `os_pci_is_thunderbolt_attached`, so A6/A7's gates read a correct flag on the **first** open of a bind (closes the first-open coverage hole). The set-*timing* is the project-local workaround; the *detector* is E1 (base, upstream-bound) — so E1 stays clean and A9 is `A`.

**Upstream candidacy:** n/a for the addons themselves. The upstream-relevant threads are E1 (the detector) and the standing observation (A9) that the RM sets `is_external_gpu` too late for any open-driver consumer — a candidate to raise on NVIDIA bug #979 once the open-arm characterization lands.

### Belongs in a different upstream

Not NVIDIA-driver code at all — no prefix, noted not owned:

| Item | Correct home |
|---|---|
| TB-tunnel BAR-window sizing; downstream link-speed cap | Linux kernel `drivers/thunderbolt` / PCIe core (today worked around by `pci=resource_alignment` + a userspace bridge-cap service) |
| IOMMU-correct GSP DMA | NVIDIA GSP firmware + kernel IOMMU (today worked around by `iommu=off`) |

## Execution — carving the PRs from the clusters

The `C` / `E` entries above are the *target spec*, not existing patches. The
project's code is the seven `tb_egpu_*` clusters (`P1`–`P7`). The cluster →
geometry map:

| Cluster | Becomes |
|---|---|
| P1 (`patches/legacy/0001`) gpu-lost-crash-safety | `C3` (retry) + `C5` (crash-safety) |
| P5 (`patches/legacy/0002`) aer-uncmask-clear | `C2` |
| P3 (`patches/legacy/0003`) qwatchdog | `A2` |
| P2 (`patches/legacy/0004`) pcie-error-handlers-recover | `C4` (err_handlers) + `A1` (foundation primitives) + `A3` (recovery) |
| P4 (`patches/legacy/0005`) close-path-safety | `A4` (re-scoped to nominal telemetry) |
| P6 (`patches/legacy/0006`) diag-telemetry | **dissolved** — not carved; `legacy/0006` preserved as resurrection source |
| P7 (`patches/legacy/0007`) version-mark-and-kbuild | `C1` (Kbuild mechanism) + `A5` (value + toggles, minus the DIAG toggle) |
| — | `E1` modernises vanilla `RmCheckForExternalGpu` — no cluster source |

For each `C`/`E` PR: extract its slice from the source cluster, de-brand it,
re-express with neutral names, add the patch's telemetry, then run the per-PR
readiness checklist ([Gate](#gate)). The carving is design work, not a
mechanical extraction.

**Carve status (2026-05-22):** the full upstream base set is carved, compiled,
and pushed to the fork — `C1`–`C5` + `E1`. The addon set `A1`–`A5` is also
carved as a fork branch stack on top of `C5` and exported into
`patches/addon/` — see
[`docs/superpowers/specs/2026-05-22-addon-recarve-design.md`](superpowers/specs/2026-05-22-addon-recarve-design.md).
The legacy `P1`–`P7` clusters remain under `patches/legacy/` as the documented
provenance source.

## Submission order

Submitted in trust-building order — independent PRs:

1. **C1** — trivial, zero-risk build cleanup. Easy first "yes".
2. **C2** — small, self-contained, Windows-parity argument.
3. **C3** — the headline #979 fix; higher visibility, more review.
4. **C4** — err_handlers scaffolding; the honest end of the error-handler story.
5. **C5** — crash-safety sibling of C3; after C3 has built credibility.

Framed together, the core set says: *make the open driver survive a transient
PCIe error the way every other in-tree PCIe driver already does.* None of them
mentions Thunderbolt — that is the test each one passes.

**`E1` follows the core set** — a small, low-risk detection fix. The Addon
layer (`A`) is never submitted.

## Gate

Do not file, and do not open a pull request, until the patches are
production-validated with a tested fix. This is the project's standing **"no
premature upstream"** policy: pushing branches to the *fork*
(`apnex/open-gpu-kernel-modules`) is durable storage of the carve, **not** a
submission; opening a PR against `NVIDIA/open-gpu-kernel-modules` happens only
after thorough review + the soak below, and only on explicit go-ahead. This
document defines the *set*; it does not authorise filing.

The gate is **two-tier** — the PRs do not all carry the same risk:

- **Fast tier — C1 and E1.** C1 is a build-system change with no runtime path.
  E1 is a small, low-risk detection swap. Gate: a `make modules` compile test.
  No behavioural soak.
- **Soaked tier — C2–C5.** These change runtime PCIe-error behaviour. Gate: a
  defined soak on the live F44 / kernel-7.0 stack **under real workload**, green
  throughout. Milestone: vLLM back as the daily compute path, **≥ 14 days** of
  genuine workload, all criteria held —
  - `status.sh` at 40/0/0 (Path A) or 39/0/0 (Path B) or better
  - `tb_egpu_recover_surrenders` = 0
  - every `tb_egpu_qwd_detections` increment either 0 or individually explained
  - no unexplained host hard-lock

Per-PR readiness checklist, before any submission:

- [ ] carving design pass done — the slice cleanly extracted from its source cluster
- [ ] rebased + re-validated against the current upstream tag (not only 595.71.05)
- [ ] de-branded per the per-PR notes above
- [ ] telemetry added per the patch's **Telemetry** line
- [ ] a real `make modules` compile + load test (an `apply --check` alone is not validation)
- [ ] the Addon half cleanly separated out (especially C4 vs A3)
- [ ] PR description drafted, referencing issue #979 where relevant (C3 especially)

## Provenance

Derived from `docs/patches.md` (per-cluster upstream-candidacy ratings) and the
2026-05-22 issue-#979 follow-up review. The seven-cluster refactor itself is
documented in `docs/patch-refactor-status.md`. The C/E/A geometry and the
`A2`/`A3` (ex-`E2`/`E3`) reclassification were decided 2026-05-22. The addon
layer's foundation extraction and the DIAG dissolution are in
`docs/superpowers/specs/2026-05-22-addon-recarve-design.md`.
