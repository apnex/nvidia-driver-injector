---
id: C4-err-handlers-scaffold
layer: base
source-branch: c4-err-handlers-scaffold
upstream-candidacy: high
telemetry-tier: nominal
status: reviewed
related-patches: [E1-egpu-detection, C5-crash-safety, A3-recovery]
---

# C4-err-handlers-scaffold — Register `pci_error_handlers` so PCIe Error Recovery Can Reach the Driver

## Purpose

Vanilla `struct pci_driver nv_pci_driver` in
`kernel-open/nvidia/nv-pci.c` leaves `.err_handler` unset, so the
kernel's PCIe error-recovery machinery (AER, DPC, surprise-removal) has
no callback to dispatch to NVIDIA-driver code. When a fatal or
non-fatal PCIe error fires, `drivers/pci/pcie/err.c` traverses the
affected sub-tree and skips any device whose driver did not register
`pci_error_handlers` — recovery aborts with "can't recover (no
error_detected callback)". The driver SHALL register a
`pci_error_handlers` table at module load via `pci_driver.err_handler`
that includes at minimum `.error_detected`, `.mmio_enabled`,
`.slot_reset`, and `.resume`. The handler bodies in this patch are
minimal correct stubs that participate honestly in the recovery state
machine — `.error_detected` is state-aware (CAN_RECOVER for non-fatal,
DISCONNECT for fatal), the others log and return the appropriate
result — without claiming reset-and-reinit capability the driver does
not yet possess; that real recovery behaviour is the responsibility of
[[C5-crash-safety]] and the addon recovery stack.

## Requirements

### Requirement: Driver SHALL register `pci_error_handlers` at module load

The driver SHALL register a `const struct pci_error_handlers` table
with the PCI subsystem by setting `nv_pci_driver.err_handler` to point
at the table before `pci_register_driver` is called. The table MUST
populate at minimum `.error_detected`, `.mmio_enabled`, `.slot_reset`,
and `.resume`. After successful `pci_register_driver`, the registered
NVIDIA `struct pci_dev`'s `pci_dev->driver->err_handler` field MUST
resolve to the table so the kernel's AER / DPC machinery can dispatch
into the driver.

#### Scenario: After `pci_register_driver` the handler table is reachable from `pci_dev`
- **GIVEN** the nvidia kernel module loads successfully
- **AND** the kernel registers `nv_pci_driver` via `pci_register_driver`
- **WHEN** any tool inspects an NVIDIA-bound `struct pci_dev` (e.g.
  via `to_pci_driver(pci_dev->dev.driver)->err_handler`)
- **THEN** the resolved `err_handler` pointer MUST be non-NULL
- **AND** the table MUST expose `.error_detected`, `.mmio_enabled`,
  `.slot_reset`, and `.resume` as non-NULL function pointers

#### Scenario: An AER event dispatches to the driver instead of aborting recovery
- **GIVEN** an NVIDIA device bound by `nv_pci_driver`
- **WHEN** the kernel's AER core decides to walk the affected
  sub-tree (e.g. `pcie_do_recovery` in `drivers/pci/pcie/err.c`)
- **THEN** the kernel MUST call the driver's `.error_detected`
  callback for the NVIDIA device
- **AND** the recovery path MUST NOT bail out with "no error_detected
  callback" for the NVIDIA device
- **AND** the dispatch MUST be observable via the callback's own
  log line (per the telemetry contract below)

### Requirement: Driver SHALL classify `.error_detected` results state-aware

`nv_pci_error_detected` SHALL inspect the `pci_channel_state_t state`
argument and return a result that honestly reflects the driver's
current capability. For `pci_channel_io_normal` (non-fatal, link still
up) the driver MUST return `PCI_ERS_RESULT_CAN_RECOVER` so a working
GPU is not torn down over a transient. For every other state
(`pci_channel_io_frozen`, `pci_channel_io_perm_failure`, or any
future value) the driver MUST return `PCI_ERS_RESULT_DISCONNECT` —
the honest answer for a driver with no reset-and-reinit path. Each
branch SHALL emit one log line naming the decision so the recovery
flow is observable.

#### Scenario: Non-fatal error returns CAN_RECOVER and logs at info
- **GIVEN** the kernel calls `nv_pci_error_detected(pci_dev,
  pci_channel_io_normal)`
- **WHEN** the callback runs
- **THEN** the callback MUST return `PCI_ERS_RESULT_CAN_RECOVER`
- **AND** the callback MUST emit exactly one `pci_info(pci_dev, ...)`
  line naming the decision (`"AER: error_detected (non-fatal) ->
  CAN_RECOVER"`)

#### Scenario: Fatal / frozen state returns DISCONNECT and logs at warn
- **GIVEN** the kernel calls `nv_pci_error_detected(pci_dev,
  state)` with `state != pci_channel_io_normal`
- **WHEN** the callback runs
- **THEN** the callback MUST return `PCI_ERS_RESULT_DISCONNECT`
- **AND** the callback MUST emit exactly one `pci_warn(pci_dev, ...)`
  line naming the state value (`"AER: error_detected (state=%d) ->
  DISCONNECT"`)
- **AND** the callback MUST NOT promise recovery the driver cannot
  perform

### Requirement: Driver SHALL participate in the rest of the recovery state machine with honest stubs

The driver SHALL provide `.mmio_enabled`, `.slot_reset`, and `.resume`
callbacks that participate correctly in the kernel's PCIe recovery
state machine. `mmio_enabled` SHALL return `PCI_ERS_RESULT_RECOVERED`
(the kernel has re-enabled MMIO, the driver has nothing to undo).
`slot_reset` SHALL return `PCI_ERS_RESULT_DISCONNECT` (the driver
does NOT yet implement reset-and-reinit; an honest DISCONNECT is
preferable to a false RECOVERED). `resume` SHALL be a no-op apart
from a single log line. Each callback MUST emit one log line so the
recovery flow is end-to-end observable.

#### Scenario: `mmio_enabled` returns RECOVERED
- **GIVEN** the kernel dispatches `nv_pci_mmio_enabled(pci_dev)`
  after a prior CAN_RECOVER from `.error_detected`
- **WHEN** the callback runs
- **THEN** the callback MUST return `PCI_ERS_RESULT_RECOVERED`
- **AND** the callback MUST emit one `pci_info(pci_dev, ...)` line
  naming the result (`"AER: mmio_enabled -> RECOVERED"`)

#### Scenario: `slot_reset` returns DISCONNECT (no reinit path yet)
- **GIVEN** the kernel dispatches `nv_pci_slot_reset(pci_dev)`
- **WHEN** the callback runs
- **THEN** the callback MUST return `PCI_ERS_RESULT_DISCONNECT`
- **AND** the callback MUST emit one `pci_warn(pci_dev, ...)` line
  naming the limitation (`"AER: slot_reset with no reinit path ->
  DISCONNECT"`)

#### Scenario: `resume` logs and returns
- **GIVEN** the kernel dispatches `nv_pci_resume(pci_dev)` at the
  end of a successful recovery sequence
- **WHEN** the callback runs
- **THEN** the callback MUST emit one `pci_info(pci_dev, ...)` line
  (`"AER: resume"`)
- **AND** the callback MUST NOT alter driver state

## Scope boundary

- This patch covers ONLY the registration of `pci_error_handlers` and
  the minimum-correct stub bodies for `.error_detected`,
  `.mmio_enabled`, `.slot_reset`, and `.resume`. A real
  reset-and-reinit `slot_reset` that revives a disconnected GPU is
  deliberately out of scope; that behaviour belongs to
  [[C5-crash-safety]] (de-branded primitives and dead-bus read
  handling) and the addon `A3-recovery` stack (explicit
  `pci_reset_bus` + bridge-link-cap preservation + err_handlers
  dispatch — the Lever M-recover surface). C4 makes the recovery
  callbacks REACHABLE; the consumers make them USEFUL.
- This patch does NOT key any callback behaviour on eGPU-ness. The
  eGPU-aware detection that may drive future per-device handler
  behaviour is the responsibility of [[E1-egpu-detection]]; C4's
  stubs treat every NVIDIA-bound device the same.
- This patch does NOT request `PCI_ERS_RESULT_NEED_RESET` from
  `.error_detected`. Without a working reinit path the request would
  be a false promise; `slot_reset` therefore is unreachable through
  the normal flow and exists for `struct pci_error_handlers`
  completeness.
- This patch does NOT introduce a module parameter. The handler
  registration is unconditional for every NVIDIA-bound PCI device.
- This patch does NOT manipulate AER mask bits or attempt to make
  Internal Errors visible — that is [[C2-aer-internal-unmask]]'s
  responsibility (C2 makes errors visible; C4 makes them reachable;
  C5 / A-stack acts on them).

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| `error_detected` decides CAN_RECOVER (non-fatal) | `pci_info` | `"AER: error_detected (non-fatal) -> CAN_RECOVER"` |
| `error_detected` decides DISCONNECT (fatal / frozen / perm_failure) | `pci_warn` | `"AER: error_detected (state=%d) -> DISCONNECT"` (where `%d` is the `pci_channel_state_t` integer value) |
| `mmio_enabled` dispatched | `pci_info` | `"AER: mmio_enabled -> RECOVERED"` |
| `slot_reset` dispatched (no reinit path yet) | `pci_warn` | `"AER: slot_reset with no reinit path -> DISCONNECT"` |
| `resume` dispatched | `pci_info` | `"AER: resume"` |

Each handler emits exactly one log line per dispatch. No per-callback
telemetry is gated behind a debug flag — the recovery flow is
sufficiently rare and operationally important that the prove-the-path
log lines belong at info/warn severity unconditionally. The
registration-time confirmation (that the table is wired into
`nv_pci_driver.err_handler`) is statically inspectable in the source
and at runtime via `pci_dev->driver->err_handler`; no separate
registration log line is required.

## Provenance

- **Source cluster:** P4 of the legacy P1-P6 refactor — the
  pre-refactor predecessor was the err_handlers-registration plus
  recovery-action portion of the legacy Lever M-recover series.
  The refactor split it into (a) C4 — registration of the handler
  table with honest stub bodies, upstream-bound — and (b)
  `A3-recovery` — the addon recovery actions (explicit dispatch,
  `pci_reset_bus`, bridge-link-cap preservation) that consume the
  registered callbacks. C4 is what NVIDIA's upstream tree can merge
  without buying into the addon-layer recovery semantics.
- **Vanilla baseline:**
  `kernel-open/nvidia/nv-pci.c:nv_pci_driver` (vanilla 595.71.05
  leaves `.err_handler` unset; no `pci_error_handlers` table is
  defined anywhere in `kernel-open/`; `grep -E
  'pci_error_handlers|err_handler|error_detected|slot_reset|mmio_enabled'
  kernel-open/nvidia/nv-pci.c` against the vanilla tree returns no
  matches). The patch is purely additive against a no-AER-callbacks
  baseline.
- **Fork branch:** `c4-err-handlers-scaffold` on
  `apnex/open-gpu-kernel-modules`.
- **Upstream issue:**
  https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979 —
  Blackwell GPU over Thunderbolt: brief PCIe link drop commits GPU
  to permanent lost state. C4 is not the headline fix (that is
  [[C3-gpu-lost-retry]]) but is the load-bearing scaffolding that
  any subsequent PCIe error-recovery work in NVIDIA's tree needs.
  The kernel's own `drivers/pci/pcie/err.c` documents the
  `pci_error_handlers` contract; every mature in-tree PCIe driver
  registers these callbacks — the open driver was the outlier.
