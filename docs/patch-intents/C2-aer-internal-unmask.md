---
id: C2-aer-internal-unmask
layer: base
source-branch: c2-aer-internal-unmask
upstream-candidacy: high
telemetry-tier: nominal
status: reviewed
related-patches: [C4-err-handlers-scaffold, C5-crash-safety]
---

# C2-aer-internal-unmask — Make AER Internal Errors Visible to the Recovery Path

## Purpose

Some platforms enumerate NVIDIA GPUs with the AER Uncorrectable Internal
Error bit (`PCI_ERR_UNC_INTN`) MASKED in the device's AER Uncorrectable
Error Mask register. Per PCIe r6.0 §6.2.3.2 a masked uncorrectable error
is demoted to Advisory Non-Fatal: its status is not latched, the Header
Log is not captured, and the device driver's `pci_error_handlers` are
never invoked — the error is invisible to the kernel's AER recovery
path. This patch clears the Internal Error bits (uncorrectable bit 22,
correctable bit 14) at the device's `pci_probe` entry so subsequent
Internal Errors take the standard AER recovery path, become visible in
`dmesg` and the kernel's AER decode, and can be acted on by other
patches: [[C4-err-handlers-scaffold]] registers the
`pci_error_handlers` table that the kernel dispatches to, and
[[C5-crash-safety]] (plus the addon recovery patches) supplies the
actual recovery actions. This patch's job is purely to make the errors
VISIBLE.

## Requirements

### Requirement: Driver SHALL unmask AER Internal Error bits at probe

When the driver's PCI probe runs against a Physical Function that
exposes the AER extended capability, the driver SHALL clear the
Uncorrectable Internal Error bit (`PCI_ERR_UNC_INTN`) of
`PCI_ERR_UNCOR_MASK` and the Correctable Internal Error bit
(`PCI_ERR_COR_INTERNAL`) of `PCI_ERR_COR_MASK`, leaving every other bit
in both registers unchanged. The driver MUST NOT mutate any other AER
register and MUST NOT change either mask register if the AER extended
capability is absent.

#### Scenario: Probe on a device whose firmware masked Internal Errors
- **GIVEN** a Physical Function whose AER `PCI_ERR_UNCOR_MASK` has
  `PCI_ERR_UNC_INTN` set at PCI enumeration
- **WHEN** the driver's PCI probe runs for that device
- **THEN** the driver MUST clear `PCI_ERR_UNC_INTN` in
  `PCI_ERR_UNCOR_MASK`
- **AND** the driver MUST emit one `pci_info`-level kernel log line
  confirming the unmask
- **AND** every other bit in `PCI_ERR_UNCOR_MASK` MUST retain its
  pre-probe value

#### Scenario: Probe on a device whose firmware already left Internal Errors unmasked
- **GIVEN** a Physical Function whose AER `PCI_ERR_UNCOR_MASK` already
  has `PCI_ERR_UNC_INTN` cleared
- **WHEN** the driver's PCI probe runs for that device
- **THEN** the driver MUST NOT write `PCI_ERR_UNCOR_MASK`
- **AND** the driver MUST NOT emit the unmask log line for that device

#### Scenario: Probe on a device without the AER extended capability
- **GIVEN** a Physical Function whose
  `pci_find_ext_capability(pci_dev, PCI_EXT_CAP_ID_ERR)` returns 0
- **WHEN** the driver's PCI probe runs for that device
- **THEN** the driver MUST return from the unmask helper without
  touching any config-space register
- **AND** probe MUST continue normally for that device

### Requirement: Unmask SHALL run for Physical Functions only

The driver's AER unmask helper SHALL execute on Physical Functions only.
It MUST NOT run on SR-IOV Virtual Functions — VFs return from probe
before the helper is reached. The helper itself SHALL be reachable from
exactly one site in `nv_pci_probe`, positioned AFTER the SR-IOV
early-exit guard and BEFORE the rest of probe begins.

#### Scenario: Probe of an SR-IOV Virtual Function
- **GIVEN** a `pci_dev` whose `is_virtfn` field is set
- **WHEN** the driver's PCI probe enters
- **THEN** the driver MUST return via the existing SR-IOV early-exit
  guard
- **AND** the AER unmask helper MUST NOT execute for that VF

## Scope boundary

- This patch deliberately does NOT clear other Uncorrectable Mask bits
  (e.g. Data Link Protocol Error, Completion Timeout, Unsupported
  Request). Only the two Internal Error bits are surgically unmasked;
  legacy ancestors of this patch cleared the entire mask register and
  that behaviour is explicitly NOT carried forward.
- This patch does NOT register `pci_error_handlers` and does NOT
  perform recovery (slot reset, link retrain, GPU re-init) when an
  Internal Error fires. Registration is the responsibility of
  [[C4-err-handlers-scaffold]]; recovery is the responsibility of
  [[C5-crash-safety]] and the addon recovery patches. C2's
  contribution is solely to make the error VISIBLE so a downstream
  handler exists for the kernel to dispatch.
- This patch does NOT mutate AER configuration on PCIe bridges,
  switches, or root ports — only on the NVIDIA Physical Function being
  probed.
- This patch does NOT manage AER state across `remove`/suspend/resume.
  The unmask is one-shot at probe; the kernel's normal AER lifecycle
  handles state across power transitions.
- This patch does NOT introduce a module parameter or sysfs toggle to
  disable the unmask. The narrowing to Internal-Error-only bits is
  considered safe enough for unconditional application; if a board
  ever regresses, the addon [[A5-version-and-toggles]] is the right
  layer to add a knob.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| AER unmask applied | `pci_info` | `"AER: unmasked Uncorrectable Internal Error at probe\n"` |

The log line fires exactly once per probed Physical Function whose
firmware left `PCI_ERR_UNC_INTN` set in `PCI_ERR_UNCOR_MASK`. No log
line is emitted for the correctable-mask write, for VFs, for devices
without AER, or for devices already in the desired state.

## Provenance

- **Source cluster:** P5 of the legacy P1-P6 refactor —
  `patches/legacy/0002-tb-egpu-aer-uncmask-clear.patch` (the P5
  carve-out that introduced a separate `nv-tb-egpu-aer.{c,h}` TU) and
  its pre-refactor predecessor
  `patches/legacy/0022-G3-H-clear-AER-UncMask-match-Windows.patch`
  (which inlined the clear inside the M-recover init function with the
  full Windows-parity rationale). C2 supersedes both: same
  observation, narrowed surface, no new TU.
- **Vanilla baseline:** `kernel-open/nvidia/nv-pci.c` — specifically
  the area immediately following `nv_pci_validate_bars` (new helper
  insertion site) and inside `nv_pci_probe` after the
  `NV_PCI_SRIOV_SUPPORT` early-exit block (helper call site).
- **Fork branch:** `c2-aer-internal-unmask` on
  `apnex/open-gpu-kernel-modules`.
- **Upstream issue:** n/a — empirical hardening on top of
  NVIDIA-bug-#979 (Blackwell eGPU over TB) work; the AER-mask
  observation is independently corroborated by PCIe r6.0 §6.2.3.2 and
  by Linux kernel 7.0's own (CXL-only-exported)
  `pci_aer_unmask_internal_errors()`.
