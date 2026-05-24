---
id: A1-pcie-primitives
layer: addon
source-branch: a1-pcie-primitives
upstream-candidacy: n/a
telemetry-tier: nominal
status: reviewed
related-patches: [A2-bus-loss-watchdog, A3-recovery, A4-close-path-telemetry, A5-version-and-toggles]
---

# A1-pcie-primitives — Shared PCIe/AER/WPR2 Register-Read Substrate for the Addon Stack

## Purpose

The driver SHALL expose a project-local, pure-observability register-read
substrate that the addon stack — `A2-bus-loss-watchdog`, `A3-recovery`,
and `A4-close-path-telemetry` — consumes to read WPR2 status, walk the
PCIe topology toward the host root port, sample the DPC and AER extended
capabilities at the GPU / immediate bridge / root port triple, and emit a
single trigger-event dump that snapshots the state at the moment a
recovery-class event fires. A1 owns no recovery semantics, no watchdog
loop, and no close-path policy — it is the foundation the three behaviour
addons reach into for their PCIe-side observability. Carving these
primitives out of legacy cluster P2 into their own translation unit
removes the cross-cluster coupling that the addon-recarve campaign
(`docs/superpowers/specs/2026-05-22-addon-recarve-design.md`) identified
between A2's file and A3/A4's call sites: with A1 in place every
addon-stack consumer depends only on this foundation, not on any
sibling addon's internals. The primitives are deliberately distinct from
[[C5-crash-safety]]'s upstream-bound `os_pci_*` helpers and `nv-gpu-lost.h`
header — those are vendor-neutral and de-branded, whereas A1's
`tb_egpu_*` symbols are project-branded, Thunderbolt-eGPU-specific, and
permanent project-local infrastructure.

## Requirements

### Requirement: Driver SHALL expose the `tb_egpu_pcie_read_wpr2` BAR0 helper with a stable signature

The driver SHALL provide `int tb_egpu_pcie_read_wpr2(u64 bar0_phys, u32 *raw_out)`
declared in `kernel-open/nvidia/nv-tb-egpu-pcie.h` and defined in
`kernel-open/nvidia/nv-tb-egpu-pcie.c`. The helper SHALL `ioremap` a
single page covering `bar0_phys + TB_EGPU_PCIE_WPR2_REG_OFFSET`
(`0x88a828`), `ioread32` the WPR2 status register at that offset, and
`iounmap` the temporary mapping before returning. The helper MUST
return `0` on success with the raw value stored through `*raw_out`,
`-EINVAL` if `raw_out` is `NULL` or `bar0_phys == 0`, and `-ENOMEM` if
the `ioremap` call fails. The mapping MUST NOT persist across the
call; every invocation MUST be page-bounded and self-contained. The
header MUST also expose the bit-mask `TB_EGPU_PCIE_WPR2_VAL_MASK`
(`0xfffffff0`) covering the `_VAL` DRF field (bits 31:4) so consumers
can extract the live-WPR2 indication from the raw register value
without re-deriving the mask.

#### Scenario: WPR2 read succeeds and returns the raw register value
- **GIVEN** a non-zero `bar0_phys` reachable as MMIO
- **AND** a valid non-NULL `raw_out` pointer
- **WHEN** the consumer (e.g. `A3-recovery`'s WPR2 polling loop) calls
  `tb_egpu_pcie_read_wpr2(bar0_phys, &raw)`
- **THEN** the call MUST return `0`
- **AND** `raw` MUST hold the 32-bit value read from
  `bar0_phys + 0x88a828`
- **AND** the temporary `ioremap` mapping MUST be released before
  return (no leak)

#### Scenario: WPR2 read rejects bad inputs and ioremap failures
- **GIVEN** either `bar0_phys == 0` or `raw_out == NULL`
- **WHEN** the consumer calls `tb_egpu_pcie_read_wpr2(...)`
- **THEN** the call MUST return `-EINVAL`
- **AND** when `raw_out != NULL` the function MUST first set `*raw_out
  = 0` (so a caller that ignores the return code does not read stale
  bytes from the output pointer)
- **AND** when `ioremap` fails the call MUST return `-ENOMEM`
- **AND** the call MUST NOT panic or leak any mapping on any error
  path

### Requirement: Driver SHALL expose the PCIe topology walker and AER/DPC capture helpers with stable signatures

The driver SHALL provide four passive sample helpers in
`kernel-open/nvidia/nv-tb-egpu-pcie.{c,h}` whose signatures are
load-bearing for downstream consumers — every prototype MUST be
treated as a stable contract for the lifetime of the addon stack:

- `struct pci_dev *tb_egpu_pcie_walk_to_root_port(struct pci_dev *start)`
  — iterates `pci_upstream_bridge()` from `start` until
  `pci_pcie_type(p) == PCI_EXP_TYPE_ROOT_PORT`, bounded to at most
  8 hops; MUST return the matching `pci_dev *` on success, or
  `NULL` if no root port is reached within the hop budget.
- `void tb_egpu_pcie_read_dpc_state(struct pci_dev *pdev, bool *present_out, u16 *dpc_status_out, u16 *dpc_ctl_out)`
  — reads the DPC extended capability; MUST zero all three output
  values before any other action, MUST set `*present_out = false`
  and return immediately if `pdev == NULL` or the DPC cap is
  absent, otherwise MUST set `*present_out = true` and read
  `PCI_EXP_DPC_CTL` (`+0x06`) and `PCI_EXP_DPC_STATUS` (`+0x08`)
  into the matching outputs (per kernel canonical layout in
  `<linux/pci_regs.h>`; `+0x04` is `PCI_EXP_DPC_CAP` and is
  deliberately not read — its bits are static capability
  declarations rather than incident-analysis state).
- `void tb_egpu_pcie_read_aer_full(struct pci_dev *pdev, int *pos_out, u32 *uesta, u32 *uemsk, u32 *uesvrt, u32 *cesta, u32 *cemsk, u32 hdrlog[4], u32 *rootcmd, u32 *rootsta, u32 *errsrc)`
  — reads the AER extended capability; MUST zero every output
  before any other action; MUST tolerate `pdev == NULL` (returns
  with all-zero outputs and `*pos_out = 0`); MUST tolerate any
  optional output pointer (`hdrlog`, `rootcmd`, `rootsta`,
  `errsrc`) being `NULL` and skip that field; MUST set `*pos_out`
  to the AER capability offset on success.
- `void tb_egpu_dump_aer_trigger_event(struct pci_dev *gpu_pdev, const char *trigger, struct tb_egpu_qwd_aer_snapshot *out)`
  — combines a `walk_to_root_port` plus three `read_aer_full`
  samples plus `read_dpc_state` plus link/device-status reads into
  one `pr_info` block tagged with the `trigger` string; MUST
  emit `tb_egpu trigger [event=...]: gpu_pdev=NULL\n` and return
  early if `gpu_pdev == NULL`; MUST tolerate `trigger == NULL` by
  substituting `"?"`; MUST tolerate `out == NULL` (no snapshot
  persistence); MUST set `out->valid = 1` and populate every
  declared field when `out != NULL`.

The driver SHALL also expose the AER snapshot struct
`struct tb_egpu_qwd_aer_snapshot` from `nv-tb-egpu-pcie.h` with the
9-field layout `gpu_aer_uesta, gpu_aer_cesta, br_aer_uesta,
br_aer_cesta, root_aer_uesta, root_aer_cesta, root_rootsta, dpc_status,
valid`. The struct's lifetime is owned by the consuming addon (the A2
watchdog embeds one in its per-device state per the file-level comment
in `nv-tb-egpu-pcie.h`); A1 only writes the fields when
`tb_egpu_dump_aer_trigger_event` is called with a non-NULL `out`.

#### Scenario: Topology walker reaches the host root port within the hop budget
- **GIVEN** a GPU `pci_dev *start` reachable via at most 7 upstream
  bridges to the host root port
- **WHEN** the consumer calls `tb_egpu_pcie_walk_to_root_port(start)`
- **THEN** the call MUST return the `pci_dev *` whose
  `pci_pcie_type` is `PCI_EXP_TYPE_ROOT_PORT`
- **AND** the call MUST NOT walk past the root port (the walk stops
  on the first root-port match)

#### Scenario: Topology walker surrenders past the hop budget
- **GIVEN** a starting `pci_dev` whose host root port is more than 8
  hops up the upstream chain (pathological topology — does not
  occur on any supported hardware but the bound is load-bearing)
- **WHEN** the consumer calls `tb_egpu_pcie_walk_to_root_port(start)`
- **THEN** the call MUST return `NULL`
- **AND** the call MUST NOT spin or recurse — the walker MUST
  terminate after at most 8 hops

#### Scenario: AER read tolerates absent capability without crashing
- **GIVEN** a `pci_dev` whose extended-cap chain has no AER
  capability
- **WHEN** the consumer calls `tb_egpu_pcie_read_aer_full(pdev,
  &pos, ...)`
- **THEN** every output MUST be zeroed (`*pos = 0`,
  `*uesta = *uemsk = ... = 0`)
- **AND** the call MUST NOT issue any further config-space reads
- **AND** the consumer that subsequently inspects `pos` can use
  `pos == 0` as "AER absent"

#### Scenario: Trigger-event dump samples the GPU/bridge/root triple and snapshots into the consumer's struct
- **GIVEN** a `pci_dev` for an attached GPU reachable through a
  walkable bridge chain
- **AND** a non-NULL `out` pointer to a
  `struct tb_egpu_qwd_aer_snapshot` owned by the consumer
- **WHEN** the consumer (e.g. A2 watchdog detection, A3 recovery
  err_handler dispatch, A4 close-path event) calls
  `tb_egpu_dump_aer_trigger_event(pdev, "<event-tag>", out)`
- **THEN** the function MUST emit one `pr_info` block tagged with
  `event=<event-tag>` covering the GPU's, bridge's, and root port's
  `LnkSta`, `DevSta`, and AER UE/CE status (plus the GPU's
  HdrLog) plus the root port's RootCmd/RootSta/ErrorSrc plus the
  root port's DPC state
- **AND** if DPC is present a separate follow-up `pr_info` line
  MUST be emitted with the DPC `Status` and `Ctl`
- **AND** the snapshot struct MUST be populated with the six AER
  status values, the root status, the DPC status, and
  `valid = 1`

### Requirement: Driver SHALL keep the primitives pure-observability with no state mutation outside the caller's snapshot

The primitives in `nv-tb-egpu-pcie.c` SHALL NOT mutate any driver
state, any device state, any kernel state (other than transient
`ioremap`/`iounmap` of the WPR2 page), or any consumer-owned data
beyond the `*raw_out` / `*..._out` / `*out` parameters explicitly
declared in the prototype. All PCI accesses MUST go through passive
helpers: `pci_read_config_word`, `pci_read_config_dword`,
`pcie_capability_read_word`, `pci_find_ext_capability`,
`pci_upstream_bridge`, `pci_pcie_type`, `pci_name`. The driver MUST
NOT issue `pci_write_config_*`, `pci_reset_*`, AER mask edits, or any
other state-mutating PCI call from A1's primitives — those belong to
[[A3-recovery]]. The driver MUST NOT take any global lock; the
helpers MUST be safe to call from a kthread (the A2 watchdog), from
the `pci_error_handlers` callback dispatch (A3), and from RM
close-path callbacks (A4) without coordination beyond each consumer's
own locking discipline.

#### Scenario: Repeated calls to a primitive from any context are independent
- **GIVEN** the A2 watchdog kthread calls
  `tb_egpu_dump_aer_trigger_event(pdev, "watchdog", &qwd->last_aer)`
  simultaneously with the A3 `nv_pci_error_detected` callback
  calling `tb_egpu_dump_aer_trigger_event(pdev, "err_detected", NULL)`
- **WHEN** both calls execute concurrently for the same `pdev`
- **THEN** each call MUST complete independently with consistent
  per-call output (no inter-call shared state in A1)
- **AND** the two `pr_info` blocks may interleave in `dmesg` — the
  per-call `event=...` tag makes them unambiguously
  attributable

#### Scenario: WPR2 helper does not retain any mapping across calls
- **GIVEN** a consumer calls `tb_egpu_pcie_read_wpr2(bar0_phys,
  &raw)` repeatedly in a polling loop
- **WHEN** each call completes
- **THEN** the temporary `ioremap` mapping MUST be released via
  `iounmap` before that call returns
- **AND** the driver MUST NOT retain any `void __iomem *` across
  calls — every invocation is page-bounded and self-contained

## Scope boundary

- This patch deliberately does NOT introduce any watchdog kthread or
  per-poll register read at any cadence. The polling loop that
  consumes `tb_egpu_pcie_read_wpr2` and tracks the dead-bus
  signature lives in [[A2-bus-loss-watchdog]]; A1 only provides the
  read helper.
- This patch does NOT implement reset-and-reinit recovery or any
  policy decision about when to fire `pci_reset_bus`. The recovery
  state machine, bridge-link-cap preservation, slot-reset dispatch,
  and post-`rm_init_adapter`-FAIL trigger all live in
  [[A3-recovery]]; A1 only provides the AER/DPC read substrate that
  [[A3-recovery]]'s err_handler callbacks and recovery routine
  sample at trigger time.
- This patch does NOT instrument any RM close-path or UVM
  open/release transition. Close-path telemetry events live in
  [[A4-close-path-telemetry]]; A1 only provides the
  `tb_egpu_dump_aer_trigger_event` primitive that A4's close-path
  events invoke when they fire.
- This patch does NOT replace, supersede, or duplicate
  [[C5-crash-safety]]'s upstream-bound `os_pci_is_disconnected` /
  `os_pci_set_disconnected` / `nv-gpu-lost.h` primitives. C5's
  primitives are vendor-neutral, de-branded, and reachable from
  core RM via the opaque `nv_state_t::handle`; A1's primitives are
  branded (`tb_egpu_*`), Thunderbolt-eGPU-specific, take
  `struct pci_dev *` directly, and live only in `kernel-open/`. The
  two surfaces are complementary; consumer addons hold both kinds
  of state in flight.
- This patch does NOT register any `pci_error_handlers` table or
  modify any vanilla NVIDIA call site outside the source list. The
  err_handlers table is registered by [[C4-err-handlers-scaffold]];
  the bodies that fill in A1's `tb_egpu_dump_aer_trigger_event`
  call into the dispatch are added by [[A3-recovery]].
- This patch does NOT expose its symbols across module boundaries.
  Every prototype lives in `kernel-open/nvidia/nv-tb-egpu-pcie.h`
  and is consumed only by other `nvidia.ko` translation units; the
  symbols are not `EXPORT_SYMBOL`'d. The file-level comment in the
  header notes this explicitly.
- This patch does NOT gate compilation of `nv-tb-egpu-pcie.c` on
  `CONFIG_NV_TB_EGPU`. The toggle is owned by
  [[A5-version-and-toggles]] and applies at the consumer call
  sites (the A2/A3/A4 source files), not at A1's foundation
  translation unit. A1's compilation is unconditional once its row
  in `nvidia-sources.Kbuild` is in effect — this is a deliberate
  composition decision so the foundation primitives compile
  alongside the unmodified `kernel-open/` set even when the
  consumer addons would be conditionally elided.
- This patch does NOT emit per-primitive entry/exit/error log
  lines. Only `tb_egpu_dump_aer_trigger_event` logs (via
  `pr_info`); the WPR2 read, the topology walker, the DPC reader,
  and the AER reader are all silent. Per the addon-recarve design
  spec's observability audit, A1 is "a primitive library; its
  callers log" — the consumer addons own the meaningful-event
  telemetry, A1 only provides the dump-block-on-demand surface.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| Trigger-event dump fires with `gpu_pdev == NULL` | `pr_info` | `"tb_egpu trigger [event=%s]: gpu_pdev=NULL\n"` (the `event` placeholder uses the `trigger` argument or `"?"` if NULL) |
| Trigger-event dump fires with valid `gpu_pdev` — main block | `pr_info` | Multi-line block tagged `"tb_egpu trigger [event=%s]:\n  GPU(%s)    LnkSta=0x%04x DevSta=0x%04x  AER UESta=0x%08x UEMsk=0x%08x UESvrt=0x%08x CESta=0x%08x CEMsk=0x%08x\n             AER HdrLog=%08x_%08x_%08x_%08x\n  Bridge(%s) LnkSta=0x%04x DevSta=0x%04x  AER UESta=0x%08x UEMsk=0x%08x UESvrt=0x%08x CESta=0x%08x CEMsk=0x%08x\n  Root(%s)   LnkSta=0x%04x DevSta=0x%04x  AER UESta=0x%08x UEMsk=0x%08x CESta=0x%08x CEMsk=0x%08x\n             RootCmd=0x%08x RootSta=0x%08x ErrorSrc=0x%08x\n  DPC: %s\n"` (the `DPC` placeholder resolves to `"(see follow-up)"` if DPC is present on the root port, else `"absent"`) |
| Trigger-event dump follow-up — DPC detail (only when DPC is present) | `pr_info` | `"tb_egpu trigger [event=%s]: DPC Status=0x%04x Ctl=0x%04x\n"` |

The four non-dump primitives (`tb_egpu_pcie_read_wpr2`,
`tb_egpu_pcie_walk_to_root_port`, `tb_egpu_pcie_read_dpc_state`,
`tb_egpu_pcie_read_aer_full`) intentionally emit no log output —
they are passive readers consumed inside hot polling loops and
err_handler callbacks where per-call logging would either flood the
log or distort the failure mode under investigation. The
`tb_egpu_dump_aer_trigger_event` primitive is the only logging
surface in A1; consumer addons MUST call it explicitly at rare,
meaningful events (watchdog detection, err_handler firing, close-path
last-close transition). Telemetry tier is `nominal` — the dump block
proves the consumer's trigger path fired and captures the
hardware state for incident analysis; it is not a `mandatory`
silent-recovery log (those live in [[A3-recovery]] and
[[C3-gpu-lost-retry]]).

## Provenance

- **Source cluster:** Extracted from legacy cluster P2
  (`patches/legacy/0004-*.patch` — the original
  `nv-tb-egpu-recover.c` and `.h`) during the 2026-05-22
  addon-recarve campaign (`project_addon_recarve_merged_2026_05_22`).
  P2 bundled the shared register-read primitives AND the recovery
  state machine in one file; the recarve split P2 three ways —
  the `pci_error_handlers` registration into base
  [[C4-err-handlers-scaffold]], the shared primitives into this
  patch (A1), and the state machine into addon
  [[A3-recovery]]'s `nv-tb-egpu-recover.{c,h}`. See
  `docs/superpowers/specs/2026-05-22-addon-recarve-design.md`
  §"Carve approach" for the non-mechanical operations involved.
- **Vanilla baseline:** No vanilla NVIDIA source is modified by the
  primitives themselves — `kernel-open/nvidia/nv-tb-egpu-pcie.c`
  and `.h` are wholly new files with no vanilla counterpart. The
  only vanilla file touched is
  `kernel-open/nvidia/nvidia-sources.Kbuild` (additive: one line
  `NVIDIA_SOURCES += nvidia/nv-tb-egpu-pcie.c` inserted after the
  existing `nv-pci.c` line; no other Kbuild edits).
- **Function signatures (load-bearing for downstream consumers —
  see [[A2-bus-loss-watchdog]], [[A3-recovery]],
  [[A4-close-path-telemetry]] reviews):**
  - `int tb_egpu_pcie_read_wpr2(u64 bar0_phys, u32 *raw_out)`
  - `struct pci_dev *tb_egpu_pcie_walk_to_root_port(struct pci_dev *start)`
  - `void tb_egpu_pcie_read_dpc_state(struct pci_dev *pdev, bool *present_out, u16 *dpc_status_out, u16 *dpc_ctl_out)`
  - `void tb_egpu_pcie_read_aer_full(struct pci_dev *pdev, int *pos_out, u32 *uesta, u32 *uemsk, u32 *uesvrt, u32 *cesta, u32 *cemsk, u32 hdrlog[4], u32 *rootcmd, u32 *rootsta, u32 *errsrc)`
  - `void tb_egpu_dump_aer_trigger_event(struct pci_dev *gpu_pdev, const char *trigger, struct tb_egpu_qwd_aer_snapshot *out)`
- **Public struct (consumer-embedded):**
  `struct tb_egpu_qwd_aer_snapshot { u32 gpu_aer_uesta; u32 gpu_aer_cesta; u32 br_aer_uesta; u32 br_aer_cesta; u32 root_aer_uesta; u32 root_aer_cesta; u32 root_rootsta; u16 dpc_status; u8 valid; }`
  — defined in `nv-tb-egpu-pcie.h`; embedded by the consumer
  (e.g. A2's `struct tb_egpu_qwd` per the header's file-level
  comment). A1 is the only writer of the fields; consumers are
  the only readers.
- **Public constants:** `TB_EGPU_PCIE_WPR2_REG_OFFSET = 0x88a828u`
  (NV_HUBMMU0_PRI_BASE + NV_HUBMMU_PRI_MMU_WPR2_ADDR_HI for
  Blackwell GB100/GB202 per published headers
  `src/common/inc/swref/published/blackwell/gb100/{hwproject.h,
  dev_hubmmu_base.h}`); `TB_EGPU_PCIE_WPR2_VAL_MASK =
  0xfffffff0u` (bits 31:4 — the `_VAL` DRF field).
- **Symbol-naming note:** the helpers all use the
  `tb_egpu_recover_*` prefix (with the single exception of
  `tb_egpu_dump_aer_trigger_event` — no `_recover_` infix). The
  `_recover_` infix is a carry-over from the legacy P2 file
  `nv-tb-egpu-recover.c` where these primitives originally lived
  before the addon-recarve. The infix is harmless (every symbol
  is still uniquely prefixed `tb_egpu_*`) but a future reader who
  expects A1's symbols to be free of `_recover_` for clarity
  should know the legacy provenance.
- **Fork branch:** `a1-pcie-primitives` on
  `apnex/open-gpu-kernel-modules` (sits on top of
  `c5-crash-safety` — the cumulative diff carries
  C1-C5 + E1 + A1).
- **Upstream issue:** n/a. Addon-layer primitives are
  project-local and never upstream-bound (per Rule 5:
  `upstream-candidacy: n/a` is the only allowed value for
  `layer: addon`). The upstream-bound primitives for the
  dead-bus crash-safety surface live in [[C5-crash-safety]];
  A1's surface is complementary (PCIe topology + AER/DPC +
  WPR2) and project-permanent.
