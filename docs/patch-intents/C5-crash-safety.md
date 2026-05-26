---
id: C5-crash-safety
layer: base
source-branch: c5-crash-safety
upstream-candidacy: high
telemetry-tier: nominal
status: partial-v3-needs-v4-architectural
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

The driver SHALL also guarantee that the cross-layer disconnect
propagation (setting both `PDB_PROP_GPU_IS_LOST` and
`pci_dev_is_disconnected` together) fires from **every** disconnect-
detection site in the driver, not only the `osDevReadReg032` post-read
check path. The disconnect-state markers MUST be consistent across
detection paths so subsequent code that consults either marker observes
the same answer. The `NV_ASSERT_OR_GPU_LOST` family of macros (which
accepts `NV_ERR_GPU_IS_LOST` as a benign cleanup-path status) SHALL be
applied at every cleanup-path assertion site that may receive
`NV_ERR_GPU_IS_LOST` from a C5-guarded RPC funnel — not only at the
resserv sites originally covered. A swept population of such sites
includes `kernel_graphics.c`, `fecs_event_list.c`,
`kernel_falcon_tu102.c`, `kernel_gsp_tu102.c`, `vaspace_api.c`,
`mem.c`, and the missed third site in `rs_server.c`.

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

### Requirement: Driver SHALL propagate disconnect to BOTH markers at every detection site, not only `osDevReadReg032`

When any code path in the driver determines that the GPU is genuinely
off the bus (via PMC_BOOT_0 mismatch or any equivalent positive-evidence
check), the driver MUST propagate the disconnect to BOTH the RM-level
marker (`PDB_PROP_GPU_IS_LOST`, set by `gpuSetDisconnectedProperties`)
AND the Linux-level marker (`pci_dev_is_disconnected`, set by
`os_pci_set_disconnected`) at that detection site. The two markers MUST
NOT diverge — every detection site MUST set both. The `osHandleGpuLost`
lost-state branch in `src/nvidia/arch/nvalloc/unix/src/osinit.c` is one
such detection site; its retry-exhausted branch ALREADY calls
`gpuSetDisconnectedProperties` and MUST also call
`os_pci_set_disconnected(nv->handle)` for marker consistency. (The
retry logic itself is owned by [[C3-gpu-lost-retry]]; the propagation
line is owned by C5.)

#### Scenario: osHandleGpuLost detection path propagates to Linux marker
- **GIVEN** an attached GPU whose `PDB_PROP_GPU_IS_CONNECTED` is set at
  entry to `osHandleGpuLost`
- **AND** every read in C3's retry window returns a mismatched value
  (genuine disconnect)
- **WHEN** the lost-state branch executes (after C3's retry budget is
  exhausted)
- **THEN** the driver MUST call `gpuSetDisconnectedProperties(pGpu)`
  (already happens — pre-existing vanilla behaviour)
- **AND** the driver MUST call `os_pci_set_disconnected(nv->handle)`
- **AND** both markers MUST be consistent after the function returns

#### Scenario: Subsequent osDevReadReg032 calls observe consistent disconnect state
- **GIVEN** `osHandleGpuLost` has set both markers in its lost-state
  branch
- **WHEN** any subsequent `osDevReadReg032` call fires for that GPU
- **THEN** the `osIsGpuBusDead(pGpu)` predicate MUST return `NV_TRUE`
- **AND** the short-circuit MUST fire returning `NV_GPU_BUS_DEAD_VALUE_U32`
  without issuing the MMIO read
- **AND** Linux kernel paths consulting `pci_dev_is_disconnected()`
  directly MUST also observe `NV_TRUE`

#### Scenario: osDevReadReg032 detection path remains unchanged
- **GIVEN** the GPU is not yet marked lost when `osDevReadReg032` is
  called
- **WHEN** the MMIO read returns `NV_GPU_BUS_DEAD_VALUE_U32`
- **THEN** the existing post-read verification + propagation logic
  MUST run unchanged
- **AND** the resulting state MUST be identical to the
  `osHandleGpuLost` path: both markers set

Before this sub-requirement was added, the cross-layer propagation only
fired from `osDevReadReg032`'s post-read check. Once `osHandleGpuLost`
set `PDB_PROP_GPU_IS_LOST` (via `gpuSetDisconnectedProperties`),
`osIsGpuBusDead` returned TRUE on subsequent reads and the short-circuit
fired BEFORE the post-read check could run — so `os_pci_set_disconnected`
was never called from the `osHandleGpuLost` detection path. The
propagation gap manifested in MISSION-1 E07 Run 2 (2026-05-26): Linux
marker stayed unset while RM marker was set, leaving the two state
systems inconsistent. This sub-requirement closes the gap.

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

### Requirement: Driver SHALL provide the `NV_ASSERT_OR_GPU_LOST` family covering `_OR_RETURN` and `_OR_RETURN_VOID` variants

The `nv-gpu-lost.h` header SHALL provide three assertion-relaxation
macros, not one, to cover the three structural variants of NV_ASSERT-
family used at sites that may receive `NV_ERR_GPU_IS_LOST` from C5-
guarded RPC funnels:

- `NV_ASSERT_OR_GPU_LOST(status)` — already defined; accepts
  `NV_OK || NV_ERR_GPU_IN_FULLCHIP_RESET || NV_ERR_GPU_IS_LOST`
- `NV_ASSERT_OR_GPU_LOST_OR_RETURN(status)` — NEW; same predicate but
  returns `status` on failure (mirrors `NV_ASSERT_OR_RETURN`)
- `NV_ASSERT_OR_GPU_LOST_OR_RETURN_VOID(status)` — NEW; same predicate
  but returns void on failure (mirrors `NV_ASSERT_OR_RETURN_VOID`)

The three macros MUST share the predicate body for consistency: an
assertion site that currently accepts
`NV_OK || NV_ERR_GPU_IN_FULLCHIP_RESET` MUST continue accepting those
statuses AND MUST additionally accept `NV_ERR_GPU_IS_LOST` for the
cleanup-path-on-lost-GPU case.

#### Scenario: Three macros share the predicate body
- **GIVEN** the three macros are defined in `nv-gpu-lost.h`
- **WHEN** code reads any of them
- **THEN** the predicate MUST be exactly `((status) == NV_OK) ||
  ((status) == NV_ERR_GPU_IN_FULLCHIP_RESET) ||
  ((status) == NV_ERR_GPU_IS_LOST)`
- **AND** the macros MUST differ ONLY in their assertion-failure
  behaviour (assert-and-continue, assert-and-return-status,
  assert-and-return-void)

### Requirement: Driver SHALL apply the `NV_ASSERT_OR_GPU_LOST` family at every cleanup-path assertion site that may receive `NV_ERR_GPU_IS_LOST`

A site identification sweep across the source tree for the pattern
`NV_ASSERT*(status == NV_OK || status == NV_ERR_GPU_IN_FULLCHIP_RESET)`
finds the following sites, all in cleanup or post-RPC paths that may
legitimately encounter `NV_ERR_GPU_IS_LOST`. The driver MUST convert
each to the appropriate macro from the family:

| Site | Macro variant before | Macro variant after |
|---|---|---|
| `src/nvidia/src/kernel/gpu/gr/kernel_graphics.c:2608` (kgraphicsFreeContextBuffers, post-`kmemsysCacheOp_HAL`) | `NV_ASSERT(...)` | `NV_ASSERT_OR_GPU_LOST(status)` |
| `src/nvidia/src/kernel/gpu/gr/fecs_event_list.c:1623` (post-RPC check) | `NV_ASSERT_OR_RETURN_VOID(...)` | `NV_ASSERT_OR_GPU_LOST_OR_RETURN_VOID(status)` |
| `src/nvidia/src/kernel/gpu/gr/fecs_event_list.c:1639` (second instance) | `NV_ASSERT_OR_RETURN_VOID(...)` | `NV_ASSERT_OR_GPU_LOST_OR_RETURN_VOID(status)` |
| `src/nvidia/src/kernel/gpu/falcon/arch/turing/kernel_falcon_tu102.c:187` (post-RPC check) | `NV_ASSERT_OR_RETURN(..., status)` | `NV_ASSERT_OR_GPU_LOST_OR_RETURN(status)` |
| `src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c:636` (post-RPC check) | `NV_ASSERT(...)` | `NV_ASSERT_OR_GPU_LOST(status)` |
| `src/nvidia/src/kernel/gpu/mem_mgr/vaspace_api.c:573` (vaspace teardown post-RPC) | `NV_ASSERT(...)` | `NV_ASSERT_OR_GPU_LOST(status)` |
| `src/nvidia/src/kernel/mem_mgr/mem.c:178` (memdesc teardown post-RPC) | `NV_ASSERT(...)` | `NV_ASSERT_OR_GPU_LOST(status)` |
| `src/nvidia/src/libraries/resserv/src/rs_server.c:1388` (third site, missed by v1) | `NV_ASSERT(...)` | `NV_ASSERT_OR_GPU_LOST(status)` |

Each converted site MUST also emit a single `NV_GPU_LOST_LOG_ONCE`
line guarded by `if (status == NV_ERR_GPU_IS_LOST)`, matching the
pattern already established at the rs_client.c and rs_server.c sites
covered by v1 C5.

#### Scenario: A converted site receives NV_OK and the assertion is a no-op
- **GIVEN** any of the 8 converted sites is reached during normal
  (non-lost-GPU) operation
- **AND** the relevant RPC or status check returns `NV_OK`
- **WHEN** the assertion macro evaluates
- **THEN** the macro MUST NOT trigger assertion firing
- **AND** the function MUST proceed as it did pre-conversion

#### Scenario: A converted site receives NV_ERR_GPU_IS_LOST during cleanup
- **GIVEN** the GPU is marked lost
- **AND** any of the 8 converted sites is reached during teardown
- **AND** the upstream RPC returns `NV_ERR_GPU_IS_LOST` (via
  `_issueRpcAndWait`'s C5 guard)
- **WHEN** the assertion macro evaluates
- **THEN** the macro MUST NOT trigger assertion firing (the new
  predicate accepts GPU_IS_LOST)
- **AND** the function MUST emit one log-once line acknowledging the
  lost-GPU status
- **AND** the function MUST continue / return per its original
  control flow

#### Scenario: A converted site receives an unexpected status
- **GIVEN** any of the 8 converted sites is reached
- **AND** the upstream RPC returns a status NOT in
  {NV_OK, NV_ERR_GPU_IN_FULLCHIP_RESET, NV_ERR_GPU_IS_LOST}
- **WHEN** the assertion macro evaluates
- **THEN** the macro MUST trigger assertion firing (unchanged
  behaviour for non-lost-GPU error classes)

#### Scenario: Each converted site has its own independent log-once latch
- **GIVEN** the 8 sites are converted, each with its own
  `NV_GPU_LOST_LOG_ONCE` call
- **WHEN** a lost-GPU teardown sequence exercises multiple sites
- **THEN** each site MUST log at most once per kernel module lifetime,
  independently of other sites
- **AND** kernel log MUST NOT be flooded by repeated log lines from
  the same site

Before this sub-requirement was added, C5 defined
`NV_ASSERT_OR_GPU_LOST` and applied it at only 2 sites
(`rs_client.c:855`, `rs_server.c:272`). A swept population of sites
used the same `NV_ASSERT*((status == NV_OK) || (status ==
NV_ERR_GPU_IN_FULLCHIP_RESET))` pattern but was not converted.
MISSION-1 E07 Run 2 (2026-05-26) confirmed 2 of these sites
(`kernel_graphics.c:2608`, `fecs_event_list.c:1623`) firing under a
lost-GPU teardown sequence. The cascade contributed to a silent host
wedge requiring forced reboot. This sub-requirement applies the same
relaxation at every swept site, including 6 additional sites that
would fire under analogous conditions. Two new macro variants
(`_OR_RETURN`, `_OR_RETURN_VOID`) are needed to cover the three
structural variants in use.

## Scope boundary

- This patch does NOT cover the `osHandleGpuLost` preflight retry
  logic — that is [[C3-gpu-lost-retry]]'s responsibility. C3 owns the
  **bounded-retry** changes (the for-loop, the per-retry delay, the
  retry-recovered log line, the constants `NV_GPU_LOST_RETRY_COUNT`
  and `NV_GPU_LOST_RETRY_DELAY_US`). C5 owns the **cross-layer
  propagation** that runs in `osHandleGpuLost`'s lost-state branch
  (the single `os_pci_set_disconnected(nv->handle)` line added
  immediately after `gpuSetDisconnectedProperties(pGpu)`). The two
  patches modify the same file (`osinit.c`) but different hunks — the
  boundary is clean and reviewable: C3 = retry logic, C5 = cross-
  layer propagation. Beyond `osHandleGpuLost`, C5 contains the
  consequences at every OTHER call site once a disconnect has been
  declared (or once an MMIO read independently surfaces the dead-bus
  signature).
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
| `osHandleGpuLost` lost-state branch propagates Linux disconnect marker | (no new log — propagation only; vanilla `"GPU has fallen off the bus."` already records the event) | n/a |
| `kgraphicsFreeContextBuffers` post-cache-evict observes `NV_ERR_GPU_IS_LOST` | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"kgraphicsFreeContextBuffers: cache evict returned NV_ERR_GPU_IS_LOST, continuing teardown\n"` |
| `fecs_event_list.c:1623` post-RPC observes `NV_ERR_GPU_IS_LOST` | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"<function>: post-RPC status NV_ERR_GPU_IS_LOST, continuing teardown\n"` |
| `fecs_event_list.c:1639` post-RPC observes `NV_ERR_GPU_IS_LOST` | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"<function>: post-RPC status NV_ERR_GPU_IS_LOST, continuing teardown\n"` |
| `kernel_falcon_tu102.c:187` falcon teardown observes `NV_ERR_GPU_IS_LOST` | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"<function>: post-RPC status NV_ERR_GPU_IS_LOST, returning early\n"` |
| `kernel_gsp_tu102.c:636` GSP teardown observes `NV_ERR_GPU_IS_LOST` | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"<function>: post-RPC status NV_ERR_GPU_IS_LOST, continuing teardown\n"` |
| `vaspace_api.c:573` vaspace teardown observes `NV_ERR_GPU_IS_LOST` | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"<function>: post-RPC status NV_ERR_GPU_IS_LOST, continuing teardown\n"` |
| `mem.c:178` memdesc teardown observes `NV_ERR_GPU_IS_LOST` | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"<function>: post-RPC status NV_ERR_GPU_IS_LOST, continuing teardown\n"` |
| `rs_server.c:1388` third site observes `NV_ERR_GPU_IS_LOST` | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"<function>: post-RPC status NV_ERR_GPU_IS_LOST, continuing cleanup\n"` |

*(Function-name prefixes for the 8 new entries above are looked up at conversion time from the actual function name at each site; `<function>` placeholders here are filled in during the fork-branch commit.)*

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
- **2026-05-26 v3 amendment provenance:** the cross-layer propagation
  gap (Requirement: BOTH markers at every detection site) and the
  swept-site application gap (Requirements: macro family +
  application) were surfaced by MISSION-1 E07 Run 2 wedge
  (2026-05-26 18:08:45). Forensic record + audit chain documented at
  `docs/missions/mission-1-egpu-hot-plug-hot-power/`:
  - `experiments/E07-cable-replug-drain-first.md` — Run 2 forensic
    evidence (Xid 79+154 cascade, kernel call sites firing
    assertions, host silent wedge ~3 min post-yank)
  - `nvidia-driver-surprise-removal-audit.md` — initial driver-side
    attribution + gap identification
  - `userspace-reset-recover-survey.md` — confirms userspace
    primitives can't substitute for the driver fix
  - `c3-c5-integration-audit.md` — validates patch placement (the
    extensions fit C5, not C3) + comprehensive 8-site sweep
  - `c5-intent-amendments-draft.md` — the draft applied by this
    amendment
- **v3 site sweep methodology:**
  `grep -rn 'NV_ASSERT.*== NV_OK.*NV_ERR_GPU_IN_FULLCHIP_RESET'
   --include='*.c' --include='*.h'` across the fork branch
  `c5-crash-safety` tip, 2026-05-26. 8 sites identified; 2 confirmed-
  fired in E07 Run 2 forensic record, 6 speculative-but-same-pattern.
  All 8 converted by this amendment for completeness.
- **Macro-variant expansion provenance:** the 3 structural variants
  (`NV_ASSERT`, `NV_ASSERT_OR_RETURN`, `NV_ASSERT_OR_RETURN_VOID`)
  were observed in the swept site set. The 2 new macros
  (`NV_ASSERT_OR_GPU_LOST_OR_RETURN`,
  `NV_ASSERT_OR_GPU_LOST_OR_RETURN_VOID`) mirror the existing
  kernel-side conventions; their predicate body is shared with
  `NV_ASSERT_OR_GPU_LOST` for consistency.
