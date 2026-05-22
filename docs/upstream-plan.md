# Upstream submission plan

**Status:** draft — 2026-05-22. Defines the target set; does not authorise
filing (see [Gate](#gate)).

## Purpose

Phase 3 of the patch work: identify and submit the subset of this project's
patches that belongs in NVIDIA's upstream `open-gpu-kernel-modules`, for the
benefit of every open-driver user — not just Thunderbolt eGPU users.

This document is the *target set* and the per-PR spec — **7 target PRs**: 4
core-path (`U1`–`U4`) + 3 eGPU-path (`E1`–`E3`), carved from the project's 7
`tb_egpu_*` clusters. (`U3` may split into 2 if review prefers → up to 8.) The
remainder of the 7 clusters stays project-local and never becomes a PR.

**This doc also defines the project's target patch geometry.** The same
classification that sorts code for upstream re-architects the project's own
driver — a **base layer** (the would-be-upstream set `U1`–`U4` + `E1`–`E3`,
clean and de-brandable) plus a thin **additive layer** of genuinely
project-local code (configurable recovery policy, kill-switch, the
`TB_EGPU_GPU_STATE` uevent, P4/P6 observability) on top. The production driver
is *base + additive*; the carving design pass (Execution, below) migrates
today's 7-cluster geometry into it. The fork then reads "stock driver + known
deltas" and shrinks monotonically as base PRs land upstream — its floor is the
additive layer alone. (The kernel-cmdline / bridge-cap host setup is a separate
Layer-1 concern, not patch geometry.)

## Placement principle

Every piece of the project's patch set is sorted by *where it correctly
belongs*. The rule, in priority order:

1. **Core, transport-agnostic paths — the default.** If a change benefits every
   open-driver user — or *can be generalised* to — it belongs in the driver's
   core logic, not behind any eGPU gate. "It was discovered through eGPU work"
   is not a reason to scope it to eGPU. Push to core wherever possible. This is
   the `U1`–`U4` core-path set.

2. **The eGPU code path — the exception, kept minimal.** Only code that is
   *intrinsically* eGPU-specific — cannot be generalised without harming the
   general case — and is genuinely valuable for the eGPU case belongs here. It
   must be **gated on the driver's existing `is_external_gpu` flag** (zero cost
   to internal GPUs) and **neatly centralised** — one cohesive eGPU unit, not
   touches scattered across the tree. This is the `E1`–`E3` eGPU-path set.

3. **Project-local — neither.** This project's *operational policy* — the
   specific recovery-gate values, the kill-switch file, the `TB_EGPU_GPU_STATE`
   uevent contract — plus observability and build metadata, never go upstream;
   this project carries them. This is *not* an anti-tunable rule: a genuine
   general user choice can be a fine upstream module parameter. What stays
   local is config that exists only to encode *this deployment's* opinion.
   Upstream ships a correct, safe *default* — hardcoded where a default
   suffices; a knob only if review asks.

4. **A different upstream.** Some eGPU-correctness work is not NVIDIA-driver
   code at all — it belongs in the Linux kernel (`drivers/thunderbolt`, PCIe
   core) or in NVIDIA GSP firmware. Noted, not owned here.

"Perfect" for an upstream change also means **de-branded**: stripped of
`tb_egpu_*` / `TB_EGPU_*` naming and `NVreg_TbEgpu*` params, cut to the minimal
correct change — the *mechanism*, re-expressed in neutral form.

**Telemetry — nominal, not investigation-grade.** Each upstream patch carries
enough logging to prove its code path ran and to show its outcome — a log line
on the rare, meaningful events, at kernel-appropriate levels (`pci_info` /
`dev_warn` on errors and recoveries; at most one `dev_info` for a per-probe
event). This is the same instrument-so-you-can-prove-what-happened discipline
used during the investigation, calibrated down to *operational* level — it is
explicitly **not** the heavy `[DIAG]` surface (P4/P6), which stays
project-local. The patch whose value is otherwise invisible — `U3` (a transient
silently recovered) — **must** log; that telemetry is mandatory, not optional.
Each PR below carries a **Telemetry** line.

## Core-path set — U1–U4

The transport-agnostic changes: each benefits every open-driver user and goes
in the driver's **core** logic, behind no eGPU gate. Submission order =
U-number (see [Submission order](#submission-order)).

### U1 — Kbuild reads NVIDIA_VERSION from version.mk

- **Source:** cluster P7 (`patches/0007`), the version.mk-as-truth half only.
- **Change:** `kernel-open/Kbuild` does `include $(src)/../version.mk` and uses
  `$(NVIDIA_VERSION)` for `-DNV_VERSION_STRING`, instead of a hardcoded literal.
- **Benefit to all:** pure build hygiene. Today the version literal can drift
  between `Kbuild` and `version.mk`, so `modinfo` can report a stale version.
  Single-source-of-truth fixes it. Zero coupling to eGPU or PCIe behaviour.
- **De-brand:** none needed — already generic.
- **Scope boundary:** the `NVIDIA_VERSION` *value* and the `CONFIG_NV_TB_EGPU*`
  toggles are NOT part of this — project-only.
- **Telemetry:** none — no runtime path. `modinfo` showing the correct version
  is the proof-of-correctness.
- **Review risk:** minimal; self-evidently correct. Good trust-builder.
- **Candidacy:** HIGH.

### U2 — Clear the AER internal-error mask bits at probe

- **Source:** cluster P5 (`patches/0002`).
- **Change:** at probe, clear the *internal-error* mask bits — `PCI_ERR_UNC_INTN`
  (Uncorrectable Mask) + `PCI_ERR_COR_INTERNAL` (Correctable Mask) — so the GPU
  stops masking its own internal PCIe errors and demoting them to "advisory
  correctable", which blinds the kernel AER subsystem to real link faults.
  Gated on `pci_find_ext_capability` — a no-op on devices without an AER ext-cap.
- **Kernel-7.0 finding — narrowed + hand-rolled.** Kernel 7.0 added
  `pci_aer_unmask_internal_errors()` (`drivers/pci/pcie/aer.c`) — the surgical
  version doing exactly those two bits. The project's bug was precisely the
  Internal Error bit (`UncMsk=0x00400000`), so **U2 narrows to it**; P5's
  whole-`PCI_ERR_UNCOR_MASK` clear was over-broad. U2 **cannot call** the kernel
  function — it is `EXPORT_SYMBOL_FOR_MODULES(…, "cxl_core")`, not linkable by
  `nvidia.ko`. Widening that export is a separate *Linux-kernel* PR the PCI
  maintainers would likely decline (they restricted it deliberately — "internal
  errors are too device-specific to enable generally"). So U2 hand-rolls the two
  register writes; the kernel function is the canonical *reference for scope*,
  not a callee.
- **Framing:** the kernel's "device-specific" stance reframes U2 honestly as a
  *device-specific* unmask — a call the device's own driver is entitled to make
  — rather than a pure benefit-all change. NVIDIA's Windows closed driver does
  the same clear.
- **De-brand:** drop the `NVreg_TbEgpuAerUncMaskClear` module param entirely —
  no user-facing toggle; the clear is **unconditional**, matching the Windows
  driver (decided 2026-05-22). The `pci_find_ext_capability` guard is not an
  opt-out — just a correct no-op where there is no AER ext-cap.
- **Scope boundary:** just the internal-error mask bits — no err_handler wiring
  (that is U4).
- **Telemetry:** one `pci_info` at probe noting the internal-error mask bits
  were cleared — the audit trail for the change in error visibility.
- **Review risk:** low. Narrowing to the two canonical bits (matching the
  kernel's `pci_aer_unmask_internal_errors`) plus the Windows-parity point make
  it a well-grounded PR.
- **Candidacy:** MEDIUM-HIGH.

### U3 — Retry a transient bus read before declaring the GPU permanently lost

- **Source:** cluster P1 (`patches/0001`), the core mechanism.
- **Change:** before `osHandleGpuLost` commits `PDB_PROP_GPU_IS_LOST`, retry
  the dead-bus read a small bounded number of times (project value: 10× /
  100 µs ≈ 1 ms) — recover a transient, still declare a genuinely-dead GPU
  dead.
- **Benefit to all:** transient `0xFFFFFFFF` reads after a PCIe completion
  timeout are not eGPU-specific — marginal signal integrity, risers, PCIe
  switches, and thermal events all produce them. The open driver's current
  one-strike → permanent-lost, never-retry behaviour is too brittle for
  everyone. This is the fix for the symptom users report in upstream
  issue #979.
- **De-brand:** remove the `TB_EGPU_*` macros/header (`nv-tb-egpu.h`,
  `TB_EGPU_GPU_LOST_RETRIES`, etc.); express as generic crash-safety with
  neutral names.
- **Scope boundary (decided 2026-05-22):** the project's P1 spans two
  sub-themes across 8 sites — *retry-before-declaring-lost* (`osHandleGpuLost`
  + the `osDevReadReg*` read sites) and *don't-crash-when-already-lost*
  (`rcdbAddRmGpuDump`, `nvdDumpAllEngines`, two `rs_server` deletion paths).
  **Lead the PR with the retry sub-theme only** — the smallest reviewable unit
  that fully addresses #979. Offer the crash-safety sites as a follow-on
  (folded in if review asks, otherwise a sibling PR). Do not submit all 8 at
  once — that lets the PR stall on the least-obvious site.
- **Telemetry (mandatory):** log the *recovery* — "transient bus read recovered
  after N retries" (`dev_warn`) — and log exhaustion. Without the recovery line
  U3 works invisibly and can never be shown to have mattered.
- **Review risk:** moderate. Propose the 10× / 100 µs default as-is, with the
  empirical backing stated; treat the exact number as review-negotiable rather
  than pre-compromising. Tie the PR explicitly to issue #979.
- **Candidacy:** HIGH — the headline fix.

### U4 — Register pci_error_handlers — error-recovery scaffolding

- **Source:** cluster P2 (`patches/0004`), the err_handlers registration only.
- **Change:** populate the `pci_error_handlers` struct in the driver's
  `struct pci_driver`. `error_detected` is **state-aware** (decided
  2026-05-22): `pci_channel_io_normal` (non-fatal) → `PCI_ERS_RESULT_CAN_RECOVER`
  — a non-fatal error must not tear down a working GPU; `pci_channel_io_frozen`
  and `pci_channel_io_perm_failure` → `PCI_ERS_RESULT_DISCONNECT` — the bare
  driver has no reset/recovery, so an honest give-up. `mmio_enabled` is a
  trivial stub returning `PCI_ERS_RESULT_RECOVERED`; `slot_reset` / `resume`
  are minimal correct stubs.
- **Interaction with U2:** U2 un-masks uncorrectable AER errors so they now
  reach `error_detected`. The state-aware branch is what keeps that safe — a
  non-fatal uncorrectable error returns `CAN_RECOVER`, not `DISCONNECT`. A
  plain unconditional `DISCONNECT` would, combined with U2, convert "silently
  masked" into "kills the GPU". Independent to *submit*, but must stay coherent
  if both land.
- **Benefit to all:** the open driver currently NULL-pads `pci_error_handlers`.
  Any GPU on any topology that hits a PCIe error therefore gets the kernel's
  `AER: can't recover (no error_detected callback)` (this exact line appears in
  third-party logs on issue #979). Registering the struct lets the kernel
  AER/DPC machinery reach the driver. Every mature in-tree PCIe driver does
  this; the open driver is the outlier.
- **De-brand:** the callbacks must be *thin and generic* — return the correct
  `pci_ers_result_t`, carry no project state.
- **Scope boundary:** U4 is the err_handlers registration plus the four
  callbacks — state-aware `error_detected` and minimal `mmio_enabled` /
  `slot_reset` / `resume`. It is the **complete, final** general contribution:
  the kernel can reach the driver, non-fatal errors recover, fatal errors
  honestly disconnect. There is no U5 — a "real `slot_reset`" that revives a
  *running* GPU does not cleanly exist (see [U5 — dropped](#u5--dropped-2026-05-22)).
  `error_detected` stays at `DISCONNECT` on fatal. The eGPU-specific
  reset-and-retry recovery is `E3`; the operational policy — H1/H2/H3 gates,
  kill-switch file, `TB_EGPU_GPU_STATE` uevent — is project-local.
- **Telemetry:** each callback logs its decision and the channel state (e.g.
  "error_detected: frozen → DISCONNECT"). Rare events — one line each is
  correct, not noise.
- **Review risk:** moderate. The callback behaviour is settled (state-aware
  `error_detected`, above). Submit last, after U1–U3.
- **Candidacy:** MEDIUM (registration is strictly upstream-improving; the
  policy half deliberately withheld).

### U5 — dropped (2026-05-22)

U5 was specified as "a real `slot_reset` that re-initialises the GPU." Carving
it revealed the spec did not match reality. P2's `slot_reset` is a *bus
verification* — `ioremap` BAR0, read `PMC_BOOT_0`, return `RECOVERED` if the
bus is back or `DISCONNECT` if still `0xffffffff` — **not** a re-init routine.
That is not a P2 oversight: the open driver has **no capability to revive a
*running* GPU** (one with live clients / contexts / allocations) after a
hardware reset — the live state is physically destroyed by the reset. There is
no "context-free re-init routine" to extract.

The recovery that genuinely works is *reset + retry the init path* for a
boot-time `rm_init_adapter` failure (no live clients yet) — and that is `E3`,
not a general `slot_reset`. So the core set ends at **U4**: registering
`pci_error_handlers` with a state-aware `error_detected` (non-fatal →
`CAN_RECOVER`, fatal → `DISCONNECT`) is the honest, complete general
contribution. `error_detected` stays at `DISCONNECT` on fatal — there is no U5
to flip it to `NEED_RESET`. The eGPU-specific reset-and-retry recovery lives
entirely in `E3`.

## eGPU-path set — E1–E3

Code that is intrinsically eGPU-specific, gated on `is_external_gpu`, and
**centralised into one cohesive eGPU unit**. This set is deliberately small —
the placement principle pushes everything generalisable into the core set
above. It is more speculative than the core set: a larger design conversation
with NVIDIA, and it depends on `E1` landing first.

### E1 — Modernise eGPU detection (prerequisite)

- **Source:** `RmCheckForExternalGpu` (`osinit.c`) — vanilla NVIDIA code, not a
  project cluster; E1 modernises what NVIDIA already has.
- **Problem:** the existing detection walks the topology for Thunderbolt-3
  bridge vendor IDs + hotplug capability. It does not fire on TB4 / USB4
  hardware (Barlow Ridge, AMD USB4 tunnels) — so modern eGPUs are silently
  misclassified as internal and get internal-GPU power management (a known
  instability source). It is why this project must force `RmForceExternalGpu=1`.
- **Change:** replace the vendor-ID walk with the kernel's own classification —
  `pci_is_thunderbolt_attached()` *or* the firmware-driven `external_facing` /
  `untrusted` markers (which cover USB4 and other external transports). Set
  `is_external_gpu` at probe from the union. The kernel's classification is
  authoritative and TB/USB4-subsystem-maintained — future-proof, and *less*
  code than the walk it replaces.
- **Decisions (2026-05-22):** signal = union of TB-attached and
  external-facing/untrusted (covers USB4, not just classic TB); **replace** the
  vendor-ID walk outright (no stale fallback); keep the `RmForceExternalGpu`
  registry knob as a manual escape hatch; E1 fixes only *what sets* the flag,
  not what it gates. Verification needed: confirm which kernel marker actually
  fires on the project's Barlow Ridge hardware.
- **Retires a project workaround:** once a running driver carries E1,
  auto-detection sets `is_external_gpu` correctly and the project drops
  `NVreg_RegistryDwords="RmForceExternalGpu=1"` from modprobe.d. The knob stays
  in the driver; the project just stops needing to set it. E1 is small enough
  to carry as a project patch *ahead of* upstreaming — so the workaround can
  retire without waiting for upstream.
- **Telemetry:** one `pci_info` at probe — "external GPU detected via
  <signal>" — recording the classification and which kernel marker fired.
- **Benefit to all eGPU users:** correct classification on modern hardware, no
  manual registry override. Prerequisite for E2/E3 (both gate on the flag).

### E2 — eGPU-gated bus-loss watchdog (from cluster P3)

- **Source:** cluster P3 (`patches/0003`), de-branded and `is_external_gpu`-gated.
- **Change:** a per-eGPU kthread that polls `NV_PMC_BOOT_0` at a fixed 200 ms
  (5 Hz); on `0xFFFFFFFF` (dead-bus signature) it marks the GPU disconnected
  (`os_pci_set_disconnected`) so U3's crash-safety and the err_handlers react,
  and logs. Gated on `is_external_gpu` — never runs on internal GPUs.
- **Scope — detect + propagate + log only.** E2 does **not** recover. It
  catches the Mode B wedge nothing else sees, contains it (the host survives),
  and stops. Recovery is E3's job — E2's detection is one of E3's triggers.
- **Decisions (2026-05-22):** (1) **log-only** — no sysfs; the detection log is
  the entire upstream observable surface (the project keeps its rich five-file
  `tb_egpu_qwd_*` sysfs locally). (2) **No knobs** — fixed 200 ms default; "on
  for eGPUs" is already expressed by the `is_external_gpu` gate, so no enable
  param.
- **Telemetry:** the detection `dev_warn` — "external GPU stopped responding,
  marked disconnected" — which doubles as the entire observability surface.
- **Benefit to all eGPU users:** a silent host hard-lock becomes a detected,
  contained event. Zero cost to internal GPUs.
- **Why eGPU-path:** a perpetual poll is only cost-justified on the
  hot-pluggable external link (placement principle). Most speculative item —
  NVIDIA may prefer to root-cause Mode B; offering E2 puts the failure mode in
  front of them regardless.

### E3 — eGPU-gated self-triggered recovery (from cluster P2)

- **Source:** cluster P2 (`patches/0004`), the self-triggered recovery slice —
  not the err_handlers registration (`U4`).
- **Requires E1** — for the `is_external_gpu` gate. Otherwise self-contained:
  E3 *is* the whole recovery mechanism (there is no U5 — see
  [U5 — dropped](#u5--dropped-2026-05-22)).
- **The gap it fills:** on a TB-tunnelled GPU the failures that need recovery
  often raise *no kernel AER event* — so the kernel never runs its recovery
  sequence at all, and the `pci_error_handlers` (`U4`) are never invoked. E3 is
  the self-trigger for exactly those AER-less cases.
- **Two triggers:** (a) a probe-time `rm_init_adapter` failure (WPR2-stuck);
  (b) E2's runtime watchdog detection. Both mean "no AER fired — self-trigger."
- **Action:** on a trigger, E3 performs a parent-bridge `pci_reset_bus()` and
  re-runs the driver's adapter init. This works because the failures E3
  recovers from are pre-client: a boot-time `rm_init_adapter` failure has no
  live GPU state to lose, so reset + retry-init brings the GPU up cleanly. A
  runtime Mode B loss recovers the GPU to a *fresh* state (no host reboot) —
  the in-flight workload's GPU state is gone, which is fundamental to any
  hardware reset, not an E3 limitation.
- **Storm-guard (hardcoded, not configurable):** a fixed cap (~3 attempts),
  modest fixed spacing between attempts, counter reset on a successful
  recovery, give up after the cap (the GPU stays disconnected — E2/U3 already
  contained the host). Safe by construction; no configuration surface. Values
  match the project's empirically-tuned H1/H2 defaults.
- **Telemetry:** `dev_warn` on the trigger, each recovery attempt, and the
  outcome (recovered / exhausted).
- **Stays project-local — not in E3:** the *configurable* H1/H2/H3 gates, the
  kill-switch file (`/var/lib/tb-egpu/recover-killswitch`), the
  `TB_EGPU_GPU_STATE` uevent. The project layers its tunable policy on top of
  E3's fixed safe default, locally.
- **Why eGPU-path:** the AER-less failure modes it recovers from are specific
  to the TB-tunnelled topology. Most speculative alongside E2 — NVIDIA may
  prefer to root-cause; offering E3 is the statement of intent.

## Stays project-local

Never upstreamed, in any form — this project carries it:

| Item | Why |
|---|---|
| Recovery policy — H1/H2/H3 gates, kill-switch file, `TB_EGPU_GPU_STATE` uevent | Operational policy; an opinionated deployment choice, not a driver default. |
| P4 — close-path observability | Project-private instrumentation for a project-specific bug class. |
| P6 — DIAG telemetry | Project-private diagnostic surface. |
| P7 — `NVIDIA_VERSION` value + `CONFIG_NV_TB_EGPU*` | Project metadata and build toggles. |

Belongs in a **different upstream**, not NVIDIA's driver at all:

| Item | Correct home |
|---|---|
| TB-tunnel BAR-window sizing; downstream link-speed cap | Linux kernel `drivers/thunderbolt` / PCIe core (today worked around by `pci=resource_alignment` + a userspace bridge-cap service) |
| IOMMU-correct GSP DMA | NVIDIA GSP firmware + kernel IOMMU (today worked around by `iommu=off`) |

## Execution — carving the PRs from the clusters

The `U` / `E` entries above are the *target spec*, not existing patches. The
project's code is the seven `tb_egpu_*` clusters (P1–P7). Phase 3's first and
largest task is the **carving design pass**: for each PR, extract its slice from
the source cluster, decide the exact split (how P1's code divides into `U3` plus
the crash-safety follow-on; how P2 divides across `U4` / `E3`), de-brand
it, re-express it with neutral names, and add the patch's telemetry. Only then
does the per-PR readiness checklist (see [Gate](#gate)) — rebase, compile+load
test, project-local separation — apply. The carving is design work, not a
mechanical extraction; it is where the plan meets the code.

## Submission order

Submitted in trust-building order — independent PRs:

1. **U1** — trivial, zero-risk build cleanup. Easy first "yes".
2. **U2** — small, self-contained, Windows-parity argument.
3. **U3** — the headline #979 fix; higher visibility, more review.
4. **U4** — err_handlers scaffolding; the honest end of the core set, submitted
   once the prior three have built credibility.

Framed together, the four say: *make the open driver survive a transient PCIe
error the way every other in-tree PCIe driver already does.* None of them
mentions Thunderbolt — that is the test each one passes.

The **eGPU-path set follows the core set**. `E1` (detection) is the
prerequisite and goes first; `E2` / `E3` only after the core set has landed and
built credibility. The core set is the concrete near-term deliverable; the
eGPU-path set is the stretch goal and the statement of intent — the project
exists not to maintain a fork, but to make the fork unnecessary.

## Gate

Do not file until the patches are production-validated with a tested fix (the
project's standing "no premature upstream filing" policy — see the
upstream-readiness summary in `docs/patches.md`). This document defines the
*set*; it does not authorise filing.

The gate is **two-tier** — the PRs do not all carry the same risk:

- **Fast tier — U1 (and E1).** U1 is a build-system change with no runtime
  path; it cannot regress stability. E1 is a small, low-risk detection swap.
  Gate: a `make modules` compile test. No behavioural soak — these can file as
  soon as Phase 3 opens.
- **Soaked tier — U2–U4.** These change runtime PCIe-error behaviour. Gate: a
  defined soak on the live F44 / kernel-7.0 stack **under real workload**,
  green throughout. Milestone: vLLM back as the daily compute path, **≥ 14
  days** of genuine workload, all criteria held —
  - `status.sh` at 38/2/0 or better
  - `tb_egpu_recover_surrenders` = 0
  - every `tb_egpu_qwd_detections` increment either 0 or individually explained
  - no unexplained host hard-lock
- **eGPU-path E2 / E3.** Inherit the soaked-tier criteria, and follow the core
  set — more speculative (a larger design conversation with NVIDIA).

Per-PR readiness checklist, before any submission:

- [ ] carving design pass done — the slice cleanly extracted from its source cluster
- [ ] rebased + re-validated against the current upstream tag (not only 595.71.05)
- [ ] de-branded per the per-PR notes above
- [ ] telemetry added per the patch's **Telemetry** line
- [ ] a real `make modules` compile + load test (an `apply --check` alone is not validation)
- [ ] the project-local half cleanly separated out (especially U4 / E3)
- [ ] PR description drafted, referencing issue #979 where relevant (U3 especially)

## Provenance

Derived from `docs/patches.md` (per-cluster upstream-candidacy ratings) and the
2026-05-22 issue-#979 follow-up review. The seven-cluster refactor itself is
documented in `docs/patch-refactor-status.md`.
