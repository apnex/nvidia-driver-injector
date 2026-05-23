---
id: E1-egpu-detection
layer: base
source-branch: e1-egpu-detection
upstream-candidacy: high
telemetry-tier: nominal
status: reviewed
related-patches: [C4-err-handlers-scaffold, A2-bus-loss-watchdog, A3-recovery]
---

# E1-egpu-detection — Detect TB4/USB4-Tunnelled GPUs via the Kernel's Own PCI Classification

## Purpose

Vanilla `RmCheckForExternalGpu` (in
`src/nvidia/arch/nvalloc/unix/src/osinit.c`) walks the PCIe bus
topology upward from the GPU, matching each intermediate bridge's
vendor/device ID against an internal RM control whitelist of
Thunderbolt-3-era bridges (`NV2080_CTRL_CMD_INTERNAL_GET_EGPU_BRIDGE_INFO`
returning `approvedBusType == NV2080_CTRL_INTERNAL_EGPU_BUS_TYPE_TB3`)
and requires hot-plug-surprise slot capability. GPUs reached over TB4
or USB4 (Intel Barlow Ridge, AMD USB4) use bridges absent from that
table, so they are silently misclassified as internal and receive
internal-GPU power management — a known instability source on
hot-pluggable / tunnelled links. The driver SHALL detect external GPUs
by consulting the Linux PCI subsystem's own transport classification
(`pci_is_thunderbolt_attached()` for the Intel Thunderbolt VSEC, which
USB4 host routers also carry; `pci_dev::untrusted` for devices below
a firmware-marked external-facing port), set
`PDB_PROP_GPU_IS_EXTERNAL_GPU` and `nv_state_t::is_external_gpu` from
the union of those signals, and emit one log line at detection so the
event is observable. The persistent capability granted is "an
externally-attached GPU on any current Thunderbolt or USB4 transport
is recognised as external at probe without operator intervention."
This is a prerequisite for downstream eGPU-specific behaviour
([[C4-err-handlers-scaffold]]'s registered callbacks may eventually
key per-device handling on this signal; the addon recovery stack
[[A2-bus-loss-watchdog]] and [[A3-recovery]] gate on
`is_external_gpu`).

## Requirements

### Requirement: Driver SHALL classify the GPU as external when the kernel's Thunderbolt-attached signal is true

The driver SHALL consult `pci_is_thunderbolt_attached(struct pci_dev *)`
against the GPU's `struct pci_dev` (reachable from
`nv_state_t::handle`) and, if it returns true, MUST treat the GPU as
external — set `PDB_PROP_GPU_IS_EXTERNAL_GPU` on the `OBJGPU`, set
`nv_state_t::is_external_gpu = NV_TRUE`, and return `NV_TRUE` from
`RmCheckForExternalGpu`. This kernel signal is true when the device,
or any bridge above it, carries the Intel Thunderbolt VSEC; USB4 host
routers carry the VSEC too, so this signal covers both classic
Thunderbolt and USB4-attached devices reachable via the VSEC path.
The driver MUST NOT consult the legacy TB3 vendor-ID whitelist
(`NV2080_CTRL_CMD_INTERNAL_GET_EGPU_BRIDGE_INFO`) for this
determination; the vendor-ID whitelist did not include TB4/USB4
bridges and therefore misclassified modern eGPUs as internal.

#### Scenario: A TB4/USB4 host-router-attached GPU is detected as external
- **GIVEN** an NVIDIA GPU reached over TB4 or USB4 hardware (e.g.
  Intel Barlow Ridge, AMD USB4 host router)
- **AND** the upstream bridges carry the Intel Thunderbolt VSEC so
  `pci_is_thunderbolt_attached(pdev)` returns true
- **WHEN** `RmCheckForExternalGpu(pGpu)` runs during
  `RmInitNvDevice`
- **THEN** the function MUST return `NV_TRUE`
- **AND** `PDB_PROP_GPU_IS_EXTERNAL_GPU` MUST be set on the `OBJGPU`
- **AND** `nv_state_t::is_external_gpu` MUST be set to `NV_TRUE`

#### Scenario: A TB3-attached GPU (preserved coverage) is detected as external
- **GIVEN** an NVIDIA GPU reached over classic Thunderbolt 3 hardware
- **AND** the upstream bridges carry the Intel Thunderbolt VSEC
- **WHEN** `RmCheckForExternalGpu(pGpu)` runs
- **THEN** the function MUST return `NV_TRUE`
- **AND** the result MUST NOT depend on the legacy TB3 vendor-ID
  whitelist remaining accurate for any specific TB3 bridge silicon

### Requirement: Driver SHALL classify the GPU as external when the kernel's external-facing-port signal is true

The driver SHALL consult `pci_dev::untrusted` on the GPU's
`struct pci_dev` and, if it is set, MUST treat the GPU as external
even when `pci_is_thunderbolt_attached()` is false. The kernel sets
`untrusted` on devices reached through a firmware-marked
external-facing root port (the endpoint-local form of the
`external_facing` ACPI / DT marker). This second signal covers
external transports that do not expose the Intel Thunderbolt VSEC,
giving the detection robustness across vendor/transport combinations
the VSEC walk would miss.

#### Scenario: A non-TB external-facing-port-attached GPU is detected as external
- **GIVEN** an NVIDIA GPU reached through a root port whose firmware
  marks it as external-facing
- **AND** the kernel has set `pdev->untrusted = 1` on the GPU
- **AND** `pci_is_thunderbolt_attached(pdev)` returns false (no
  Intel Thunderbolt VSEC on the path)
- **WHEN** `RmCheckForExternalGpu(pGpu)` runs
- **THEN** the function MUST return `NV_TRUE`
- **AND** `PDB_PROP_GPU_IS_EXTERNAL_GPU` MUST be set on the `OBJGPU`

#### Scenario: A purely internal GPU (PCH-rooted, no external markers) is NOT detected as external
- **GIVEN** an NVIDIA GPU on a built-in PCIe slot whose bridges do
  NOT carry the Intel Thunderbolt VSEC
- **AND** the GPU's root port is not firmware-marked external-facing,
  so `pdev->untrusted` is zero
- **WHEN** `RmCheckForExternalGpu(pGpu)` runs
- **THEN** the function MUST return `NV_FALSE`
- **AND** `PDB_PROP_GPU_IS_EXTERNAL_GPU` MUST NOT be set on the
  `OBJGPU` by this code path
- **AND** `nv_state_t::is_external_gpu` MUST remain `NV_FALSE`
- **AND** no detection log line MUST be emitted

### Requirement: Driver SHALL emit one log line at detection naming the kernel markers that fired

When detection returns `NV_TRUE`, the driver SHALL emit exactly one
`pci_info(pdev, ...)` line recording which of the two kernel signals
fired. The log line MUST include both flags as yes/no values so an
operator can distinguish "VSEC-only" (classic TB / USB4 host router)
from "untrusted-only" (firmware external-facing port without VSEC)
from "both" (the common case on TB-attached hardware). When detection
returns `NV_FALSE` (the internal-GPU path) the driver MUST NOT emit
any line — eGPU detection is a low-frequency probe-time event, not a
heartbeat.

#### Scenario: External-detection log line is emitted exactly once per probe
- **GIVEN** any GPU for which detection returns `NV_TRUE`
- **WHEN** `os_pci_is_thunderbolt_attached(nv->handle)` runs
- **THEN** the driver MUST emit exactly one `pci_info(pdev, ...)`
  line via the `pci_info` macro
- **AND** the line MUST name both signals as
  `thunderbolt-attached=<yes|no>` and `external/untrusted=<yes|no>`
- **AND** no further log lines from this code path MUST be emitted
  for subsequent calls in the same probe

## Scope boundary

- This patch covers ONLY the classification of the GPU as external at
  probe time inside `RmCheckForExternalGpu` and its supporting
  os-interface wrapper `os_pci_is_thunderbolt_attached`. It does NOT
  alter the `pci_error_handlers` table registration or its callback
  bodies — that is [[C4-err-handlers-scaffold]]'s responsibility.
- This patch does NOT engage any recovery path. Driving real PCIe
  error recovery (slot reset, bridge-link-cap preservation, explicit
  err_handlers dispatch — Lever M-recover) belongs to
  [[C5-crash-safety]] (de-branded primitives) and the addon
  [[A3-recovery]] (project-local recovery actions).
- This patch does NOT introduce a module parameter to force-detect
  external. The legacy `NVreg_RegistryDwords="RmForceExternalGpu=1"`
  modprobe override carried by the project (see
  `scripts/host-files/etc/modprobe.d/nvidia-driver-injector.conf`
  line 55) is the workaround E1 is replacing — once a driver carries
  E1, auto-detection sets `is_external_gpu` correctly on TB4/USB4
  hardware and the project drops the modprobe knob. The
  `RmForceExternalGpu` knob itself stays in the (unmodified)
  registry-dword parsing code as a manual escape hatch; E1 does not
  remove or alter it.
- This patch does NOT remove the `OBJCL *pCl` second argument from
  `RmCheckForExternalGpu`'s callers globally; the signature change
  is local to the one caller (`RmInitNvDevice`) and the two
  unused `pSys`/`pCl` lookups in that caller. The internal RM
  control `NV2080_CTRL_CMD_INTERNAL_GET_EGPU_BRIDGE_INFO` and its
  TB3 vendor-ID whitelist remain defined in core RM headers and may
  be used elsewhere; E1 only stops the unix-side osinit path from
  consulting them.
- This patch does NOT change the downstream consequences of
  `is_external_gpu` (eGPU-specific unbind/serialisation paths,
  surprise-removal flag handling in `osHandleGpuLost`). Those paths
  remain as the vanilla driver wrote them; E1 just ensures they
  apply on modern hardware.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| External GPU detected at probe | `pci_info` | `"external GPU detected (thunderbolt-attached=%s, external/untrusted=%s)\n"` (with each `%s` resolving to `"yes"` or `"no"`) |

Exactly one line is emitted per detection-returns-true call. The
internal-GPU path (detection returns false) is silent. The line is at
`pci_info` level because external-GPU detection is a normal,
operationally interesting event — not a warning — and `pci_info`
automatically prefixes the BDF and driver name, matching the format
of the surrounding PCIe-subsystem log lines. No log line is gated
behind a debug flag.

## Provenance

- **Source cluster:** This patch is not derived from the legacy
  P1-P6 stack — it is a forward-looking modernisation of vanilla
  NVIDIA detection code, classified as `E` in the C/E/A geometry
  (eGPU-specific, upstream-bound, retires a project workaround). See
  `docs/upstream-plan.md §E1`.
- **Vanilla baseline:** `src/nvidia/arch/nvalloc/unix/src/osinit.c:RmCheckForExternalGpu`
  (vanilla 595.71.05 walks the bus topology via `clFindP2PBrdg` and
  matches bridge vendor/device IDs against the TB3 whitelist returned
  by `NV2080_CTRL_CMD_INTERNAL_GET_EGPU_BRIDGE_INFO`, requiring
  `approvedBusType == NV2080_CTRL_INTERNAL_EGPU_BUS_TYPE_TB3` plus
  hot-plug-surprise slot capability — see vanilla osinit.c around
  the function signature `RmCheckForExternalGpu(OBJGPU *pGpu,
  OBJCL *pCl)` and its caller `RmInitNvDevice` at the
  `if (RmCheckForExternalGpu(pGpu, pCl))` site). Companion vanilla
  baselines added by E1:
  `kernel-open/nvidia/os-pci.c` (new wrapper
  `os_pci_is_thunderbolt_attached` placed adjacent to
  `os_pci_remove`),
  `kernel-open/common/inc/os-interface.h` and
  `src/nvidia/arch/nvalloc/unix/include/os-interface.h` (declaration
  added next to the existing `os_pci_remove` declaration).
- **Fork branch:** `e1-egpu-detection` on
  `apnex/open-gpu-kernel-modules` — sits on top of
  `c4-err-handlers-scaffold` so the cumulative diff carries
  C1-C4 + E1.
- **Upstream issue:**
  https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979 —
  Blackwell GPU over Thunderbolt: brief PCIe link drop commits GPU
  to permanent lost state. E1 is not the headline fix for #979 (the
  headline fix is [[C3-gpu-lost-retry]]) but is the
  classification prerequisite without which eGPU-specific behaviour
  is gated out on modern hardware — including the surprise-removal
  flag path inside `osHandleGpuLost` that #979 reproduces.
  Memory: `project_nvidia_open_driver_egpu_layer_tb3_era` documents
  the original TB3-era detection and why the project had to set
  `RmForceExternalGpu=1` as a workaround.
