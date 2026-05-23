---
id: C5-crash-safety
layer: base
source-branch: c5-crash-safety
upstream-candidacy: high
telemetry-tier: nominal
status: reviewed
related-patches: [C2-aer-internal-unmask, C3-gpu-lost-retry, C4-err-handlers-scaffold]
---

# C5-crash-safety — Contain Dead-Bus Reads and Cleanup Paths Across the Driver

## Purpose

The driver SHALL recognise dead-bus signals at the broad set of call
sites OUTSIDE the `osHandleGpuLost` preflight (covered by
[[C3-gpu-lost-retry]]) and convert them into a graceful disconnected
state rather than stalling the GPU lock for seconds per MMIO completion
timeout or asserting during resource teardown. Concretely, the driver
SHALL short-circuit `osDevReadReg008/016/032` once the GPU is known to
be off the bus, detect a fresh disconnect when an MMIO read returns
all-1s and propagate that state kernel-wide, bound the journal /
`nv_debug_dump` / GSP-RPC / resserv cleanup paths so a lost GPU does
not panic them, and expose the de-branded primitives
`os_pci_is_disconnected`, `os_pci_set_disconnected`, and the
`nv-gpu-lost.h` header (`NV_GPU_BUS_DEAD_VALUE_U{8,16,32}`,
`NV_GPU_LOST_LOG_ONCE`, `NV_ASSERT_OR_GPU_LOST`) as reusable
infrastructure that upstream consumers and the addon recovery stack can
build on. The persistent capability granted is: "a GPU off the PCIe bus
is a contained, survivable event — driver paths do not stall the host
or trip assertions on hardware that is no longer there." This is
transport-agnostic: signal-integrity, thermal, or switch-fault events
can take a GPU off the bus, not only hot-pluggable links — so the
guards cover every path where a dead-bus read or assert would otherwise
escape, even though the empirical driver of the work is the Blackwell
eGPU surprise-removal failure mode tracked upstream as
[NVIDIA/open-gpu-kernel-modules#979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979).

## Requirements

### Requirement: Driver SHALL expose de-branded dead-bus primitives

The driver SHALL provide a self-contained header
`src/nvidia/inc/kernel/gpu/nv-gpu-lost.h` defining the constants
`NV_GPU_BUS_DEAD_VALUE_U32 = 0xFFFFFFFFU`, `NV_GPU_BUS_DEAD_VALUE_U16 =
0xFFFFU`, `NV_GPU_BUS_DEAD_VALUE_U8 = 0xFFU`, the function-scope-static
log-once macro `NV_GPU_LOST_LOG_ONCE(level, fmt, …)`, and the cleanup-
path assert relaxation `NV_ASSERT_OR_GPU_LOST(status)` that accepts
`NV_OK`, `NV_ERR_GPU_IN_FULLCHIP_RESET`, or `NV_ERR_GPU_IS_LOST`. The
driver SHALL also export the kernel-open primitives
`os_pci_is_disconnected(void *handle)` and
`os_pci_set_disconnected(void *handle)` via the generic `os_pci_*`
prototypes in both `kernel-open/common/inc/os-interface.h` and
`src/nvidia/arch/nvalloc/unix/include/os-interface.h`, so callers in
core RM (which cannot include `<linux/pci.h>`) can query and set the
kernel's `pci_channel_io_perm_failure` state through an opaque handle.
All primitives MUST be free of project-local branding (no `aorus`,
`AORUS`, `Aorus`, project name, or injector references); they are
upstream-candidate infrastructure.

#### Scenario: Header is self-contained and includable from RM and resserv
- **GIVEN** any translation unit in `src/nvidia/` that already has
  `NV_PRINTF` and `NV_ASSERT` in scope
- **WHEN** that file includes `gpu/nv-gpu-lost.h`
- **THEN** the file MUST compile without needing any additional
  pre-include
- **AND** the macros `NV_GPU_BUS_DEAD_VALUE_U{8,16,32}`,
  `NV_GPU_LOST_LOG_ONCE`, and `NV_ASSERT_OR_GPU_LOST` MUST be in scope

#### Scenario: `os_pci_*` primitives are reachable from core RM via an opaque handle
- **GIVEN** core RM code (e.g. `src/nvidia/arch/nvalloc/unix/src/os.c`)
  holding `nv->handle` for the GPU's `struct pci_dev`
- **WHEN** that code calls `os_pci_is_disconnected(nv->handle)` or
  `os_pci_set_disconnected(nv->handle)`
- **THEN** the call MUST resolve through the os-interface prototype
  without requiring `<linux/pci.h>` at the call site
- **AND** `os_pci_set_disconnected` MUST transition the device to
  `pci_channel_io_perm_failure` using `WRITE_ONCE` (race-safe against
  concurrent AER state changes — `perm_failure` is a sink state)
- **AND** `os_pci_is_disconnected` MUST return `NV_TRUE` if and only
  if the kernel's `pci_dev_is_disconnected()` predicate is true for
  the device

### Requirement: Driver SHALL short-circuit MMIO read paths on a known-dead bus

`osDevReadReg008`, `osDevReadReg016`, and `osDevReadReg032` SHALL
consult a shared `osIsGpuBusDead(pGpu)` predicate before issuing the
underlying `NV_PRIV_REG_RD{08,16,32}`. The predicate MUST return
`NV_TRUE` if either `os_pci_is_disconnected(nv->handle)` is true OR
`PDB_PROP_GPU_IS_LOST` is set. When the predicate is true the readers
MUST return the corresponding `NV_GPU_BUS_DEAD_VALUE_U*` immediately,
without issuing the MMIO read. `osDevReadReg032` MUST additionally
perform post-read dead-bus detection: when the unguarded
`NV_PRIV_REG_RD32` returns `NV_GPU_BUS_DEAD_VALUE_U32` and
`PDB_PROP_GPU_IS_LOST` is not yet set, the driver MUST confirm by
re-reading `NV_PMC_BOOT_0` directly through `NV_PRIV_REG_RD32` (no
recursion through `osDevReadReg032`), and if the confirmation also
returns the dead-bus value the driver MUST call
`gpuSetDisconnectedProperties(pGpu)` and
`os_pci_set_disconnected(nv->handle)` so subsequent calls short-circuit
through the predicate.

#### Scenario: Read after disconnect returns the dead-bus sentinel without MMIO
- **GIVEN** `os_pci_is_disconnected(nv->handle)` returns `NV_TRUE` OR
  `pGpu->getProperty(pGpu, PDB_PROP_GPU_IS_LOST)` is `NV_TRUE`
- **WHEN** any of `osDevReadReg008`, `osDevReadReg016`,
  `osDevReadReg032` is called for that GPU
- **THEN** the function MUST return
  `NV_GPU_BUS_DEAD_VALUE_U{8,16,32}` respectively
- **AND** the function MUST NOT issue `NV_PRIV_REG_RD{08,16,32}`
- **AND** the GPU lock MUST NOT be stalled on a PCIe completion
  timeout

#### Scenario: Fresh dead-bus read promotes GPU to lost state
- **GIVEN** the GPU is not yet marked lost (`PDB_PROP_GPU_IS_LOST`
  unset, `os_pci_is_disconnected` false)
- **WHEN** `osDevReadReg032` issues an MMIO read and that read returns
  `NV_GPU_BUS_DEAD_VALUE_U32`
- **THEN** the driver MUST verify by reading `NV_PMC_BOOT_0` directly
  via `NV_PRIV_REG_RD32(nv->regs->map_u, NV_PMC_BOOT_0)`
- **AND** if the verification read also returns
  `NV_GPU_BUS_DEAD_VALUE_U32` the driver MUST call
  `gpuSetDisconnectedProperties(pGpu)` to set `PDB_PROP_GPU_IS_LOST`
- **AND** the driver MUST call `os_pci_set_disconnected(nv->handle)`
  so the kernel-wide PCI disconnect state is set
- **AND** the driver MUST emit exactly one log line per kernel
  module lifetime per call site (via `NV_GPU_LOST_LOG_ONCE`) naming
  the offset that triggered detection and the verification result

### Requirement: Driver SHALL bound diagnostic, RPC, and resserv cleanup paths against a lost GPU

The driver SHALL prevent a lost GPU from panicking or stalling the
following non-MMIO paths. `rcdbAddRmGpuDump` MUST return early
(`NV_OK`) when `PDB_PROP_GPU_IS_LOST` is set so the engine-callback
loop never runs against absent hardware. The deferred-dump callback
(`_rcdbAddRmGpuDumpCallback`) MUST log on a non-`NV_OK`
`rcdbAddRmGpuDump` return rather than `NV_ASSERT`-ing on it.
`nvdDumpAllEngines_IMPL` MUST `break` its engine-iteration loop when
either `PDB_PROP_GPU_IS_LOST` or `PDB_PROP_GPU_INACCESSIBLE` is set,
setting `pNvDumpState->bGpuAccessible = NV_FALSE` and emitting a
single log-once line. `_issueRpcAndWait` MUST short-circuit and return
`NV_ERR_GPU_IS_LOST` when `PDB_PROP_GPU_IS_LOST` is set, before
issuing the GSP RPC. `rpcRmApiFree_GSP` MUST short-circuit and return
`NV_OK` when `PDB_PROP_GPU_IS_LOST` is set, so resserv teardown
completes its host-side bookkeeping. The resserv cleanup asserts in
`clientFreeResource_IMPL` and `serverFreeResourceTreeUnderLock` MUST
accept `NV_ERR_GPU_IS_LOST` (via `NV_ASSERT_OR_GPU_LOST`) in addition
to the pre-existing `NV_OK` / `NV_ERR_GPU_IN_FULLCHIP_RESET` statuses.

#### Scenario: Crash dump path on a lost GPU returns immediately
- **GIVEN** `PDB_PROP_GPU_IS_LOST` is set on the GPU
- **WHEN** `rcdbAddRmGpuDump(pGpu)` is called (directly or via the
  deferred-dump callback)
- **THEN** the function MUST return `NV_OK` without iterating engine
  callbacks
- **AND** if the call originated from `_rcdbAddRmGpuDumpCallback`,
  that callback MUST log the (now-impossible) failure rather than
  `NV_ASSERT(status == NV_OK)`
- **AND** the call MUST emit at most one log-once line per kernel
  module lifetime naming the lost-GPU short-circuit

#### Scenario: Engine-dump loop stops on inaccessibility instead of running every callback
- **GIVEN** `PDB_PROP_GPU_IS_LOST` or `PDB_PROP_GPU_INACCESSIBLE` is
  set
- **WHEN** `nvdDumpAllEngines_IMPL` iterates its
  `pEngineCallback` chain
- **THEN** the loop MUST `break` before invoking the next callback
- **AND** the function MUST set
  `pNvDumpState->bGpuAccessible = NV_FALSE`
- **AND** the function MUST emit at most one log-once line per
  kernel module lifetime

#### Scenario: GSP RPC short-circuits and resource cleanup completes
- **GIVEN** `PDB_PROP_GPU_IS_LOST` is set
- **WHEN** `_issueRpcAndWait(pGpu, pRpc)` is entered
- **THEN** the function MUST return `NV_ERR_GPU_IS_LOST` without
  issuing the RPC
- **AND** when `rpcRmApiFree_GSP` is entered for the same GPU it MUST
  return `NV_OK` (cleanup must complete; the resserv asserts allow
  `NV_OK`)
- **AND** in `clientFreeResource_IMPL` and
  `serverFreeResourceTreeUnderLock`, an `NV_ERR_GPU_IS_LOST` status
  from the free path MUST NOT fire `NV_ASSERT` — the
  `NV_ASSERT_OR_GPU_LOST` macro accepts it
- **AND** each guard MUST emit at most one log-once line per call
  site per kernel module lifetime

## Scope boundary

- This patch does NOT cover the `osHandleGpuLost` preflight retry —
  that is [[C3-gpu-lost-retry]]'s responsibility. C3 distinguishes a
  glitch from a genuine disconnect at one specific call site; C5
  contains the consequences at every OTHER call site once a disconnect
  has been declared (or once an MMIO read independently surfaces the
  dead-bus signature).
- This patch does NOT register `pci_error_handlers`. The kernel's
  `struct pci_error_handlers` table is registered by
  [[C4-err-handlers-scaffold]] on `nv_pci_driver.err_handler`; C5
  consumes the disconnected state that the kernel's AER machinery and
  driver-side dead-bus detection cooperatively maintain, but does not
  itself wire the callback table.
- This patch does NOT mutate AER mask bits or make Internal Errors
  visible — that is [[C2-aer-internal-unmask]]'s responsibility. C2
  ensures the errors fire visibly; C4 ensures the driver is reachable
  by the AER state machine; C5 ensures the driver paths that operate
  on the device survive its absence.
- This patch does NOT implement reset-and-reinit recovery. A real
  reset-and-reinit (slot reset, bridge link cap preservation, explicit
  err_handlers dispatch — the legacy Lever M-recover stack) is the
  responsibility of the addon `A3-recovery` patch. C5 provides the
  primitives (`os_pci_set_disconnected`, `NV_GPU_LOST_*` macros) that
  A1's addon PCIe primitives and A3's recovery actions build on; C5
  itself is contention containment, not recovery.
- This patch does NOT introduce module parameters. All guards are
  unconditional. Behaviour can be characterised statically by reading
  the source.
- This patch does NOT key behaviour on eGPU-ness. `osIsGpuBusDead`
  and every guard treat every NVIDIA-bound device the same — a dead
  bus is a dead bus whether the transport is integrated, discrete-x16,
  or Thunderbolt. eGPU detection ([[E1-egpu-detection]]) feeds into
  other policy decisions but not into C5's crash-safety surface.
- This patch's log-once policy uses function-scope-static latches:
  each call site logs at most once per kernel module lifetime. The
  log lines are nominal-tier (per-site prove-the-path; the
  mandatory-tier recovery telemetry lives in [[C3-gpu-lost-retry]]'s
  `osHandleGpuLost` recovery line). C5's logs prove the guard fired,
  not that a recovery completed.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| `osDevReadReg032` short-circuits on a known-dead bus | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"osDevReadReg032: GPU off the bus, short-circuiting reads at offset 0x%08x\n"` (offset of triggering read) |
| `osDevReadReg032` declares the GPU lost from a fresh dead-bus signature | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"osDevReadReg032: GPU off the bus detected via post-read check (offset=0x%08x, NV_PMC_BOOT_0=0x%08x); declaring GPU lost\n"` |
| `rcdbAddRmGpuDump` short-circuits on a lost GPU | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"rcdbAddRmGpuDump: GPU lost, skipping crash dump\n"` |
| `_rcdbAddRmGpuDumpCallback` observes a non-`NV_OK` dump status | `LEVEL_ERROR` (plain `NV_PRINTF`) | `"rcdbAddRmGpuDump returned 0x%x in deferred dump path\n"` |
| `nvdDumpAllEngines` breaks engine-dump loop on a lost/inaccessible GPU | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"nvdDumpAllEngines: GPU lost or inaccessible, skipping remaining engine dumps\n"` |
| `_issueRpcAndWait` short-circuits on a lost GPU | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"_issueRpcAndWait: GPU lost, returning NV_ERR_GPU_IS_LOST without issuing RPC\n"` |
| `rpcRmApiFree_GSP` short-circuits on a lost GPU | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"rpcRmApiFree_GSP: GPU lost, returning NV_OK so resource cleanup completes\n"` |
| `clientFreeResource_IMPL` observes `NV_ERR_GPU_IS_LOST` from free RPC | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"clientFreeResource: free RPC returned NV_ERR_GPU_IS_LOST, continuing cleanup\n"` |
| `serverFreeResourceTreeUnderLock` observes `NV_ERR_GPU_IS_LOST` from cleanup | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"serverFreeResourceTreeUnderLock: clientFreeResource returned NV_ERR_GPU_IS_LOST, continuing cleanup\n"` |

Each `NV_GPU_LOST_LOG_ONCE` site uses a function-scope-static latch so
the line fires at most once per kernel module lifetime per call site.
This is `telemetry-tier: nominal` — prove-the-path observability for a
rare-but-important failure mode. The mandatory-tier recovery
telemetry (`osHandleGpuLost`'s "transient PCIe read recovered after N
retries") lives in [[C3-gpu-lost-retry]]. The osDevReadReg008 /
osDevReadReg016 short-circuit paths intentionally do NOT log (they
piggy-back on osDevReadReg032's logging — the bus is dead, the U32
path has already logged once, and re-logging from the narrower-width
sibling readers would only flood the kernel log).

## Provenance

- **Source cluster:** P5 of the legacy P1-P6 refactor (crash-safety
  surface). Predecessor was a set of legacy patches each touching one
  site individually plus a separate macros header carrying the
  log-once and dead-value constants. The C+E+A refactor adopted on
  2026-05-22 (per memory: `project_cea_patch_geometry_2026_05_22`)
  classified C5 as a base-layer upstream candidate because the
  primitives (`os_pci_set_disconnected`, `nv-gpu-lost.h`) are
  transport-agnostic and de-branded; the project-specific recovery
  ACTIONS that consume them live in the addon layer as
  `A1-pcie-primitives` + `A3-recovery`.
- **Vanilla baseline:**
  - `kernel-open/common/inc/os-interface.h` — vanilla 595.71.05 has
    no `os_pci_is_disconnected` / `os_pci_set_disconnected` /
    `os_pci_is_thunderbolt_attached` prototypes; the patch is purely
    additive to the existing `os_pci_*` block.
  - `kernel-open/nvidia/os-pci.c` — vanilla 595.71.05 has no
    disconnect-state helpers; patch adds them after `os_pci_remove`.
  - `src/nvidia/arch/nvalloc/unix/include/os-interface.h` — same
    additive prototypes as the kernel-open copy (the two headers are
    kept in sync by convention).
  - `src/nvidia/arch/nvalloc/unix/src/os.c:osDevReadReg008/016/032`
    — vanilla 595.71.05 has no dead-bus short-circuit; the U8/U16
    readers go straight to `NV_PRIV_REG_RD08/16` after a length
    check; the U32 reader has the vGPU-passthrough guard but no
    dead-bus guard and no post-read detection.
  - `src/nvidia/inc/kernel/gpu/nv-gpu-lost.h` — NEW FILE. No vanilla
    counterpart exists.
  - `src/nvidia/src/kernel/diagnostics/journal.c:rcdbAddRmGpuDump`
    and `_rcdbAddRmGpuDumpCallback` — vanilla 595.71.05 has neither
    the early-return on `PDB_PROP_GPU_IS_LOST` nor the
    log-instead-of-assert in the deferred-dump callback.
  - `src/nvidia/src/kernel/diagnostics/nv_debug_dump.c:nvdDumpAllEngines_IMPL`
    — vanilla 595.71.05 has the loop but no break on
    lost/inaccessible state.
  - `src/nvidia/src/kernel/vgpu/rpc.c:_issueRpcAndWait` and
    `rpcRmApiFree_GSP` — vanilla 595.71.05 has neither short-circuit.
  - `src/nvidia/src/libraries/resserv/src/rs_client.c:clientFreeResource_IMPL`
    and
    `src/nvidia/src/libraries/resserv/src/rs_server.c:serverFreeResourceTreeUnderLock`
    — vanilla 595.71.05 asserts `(status == NV_OK) || (status ==
    NV_ERR_GPU_IN_FULLCHIP_RESET)` at both sites; the patch
    introduces `NV_ASSERT_OR_GPU_LOST` to accept
    `NV_ERR_GPU_IS_LOST` additionally.
- **Fork branch:** `c5-crash-safety` on
  `apnex/open-gpu-kernel-modules`.
- **Upstream issue:**
  https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979 —
  Blackwell GPU over Thunderbolt: brief PCIe link drop commits GPU
  to permanent lost state. C5 is not the headline preflight fix
  (that is [[C3-gpu-lost-retry]]) and not the registration scaffold
  (that is [[C4-err-handlers-scaffold]]); C5 is the crash-safety
  surface that prevents the secondary blast radius — once a
  disconnect is declared, no driver path should stall the host or
  trip an assert against absent hardware. The primitives
  (`os_pci_set_disconnected`, `nv-gpu-lost.h`) are reusable by any
  upstream consumer, not only by this project's addon recovery
  stack.
