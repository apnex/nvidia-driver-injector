---
id: C5-crash-safety
layer: base
source-branch: c5-crash-safety
upstream-candidacy: high
telemetry-tier: nominal
status: v4-target-ready
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

### Requirement (v4): Driver SHALL expose a single sink primitive that consolidates dual-marker writes

`src/nvidia/inc/kernel/gpu/nv-gpu-lost.h` SHALL declare a detector-class
enum `nv_gpu_lost_detector_t` allocating one slot per upstream detection
input (`DETECTOR_MMIO_DEAD`, `DETECTOR_OSHANDLEGPULOST_RETRY_EXHAUSTED`,
`DETECTOR_GSP_HEARTBEAT_TIMEOUT`, `DETECTOR_AER_FATAL`,
`DETECTOR_QWATCHDOG_DMA_WEDGE`, `DETECTOR_PROBE_BAR_FAILURE`,
`DETECTOR_SYSFS_DISCONNECTED`, `DETECTOR_UVM_FATAL` reserved for Phase
2 C6). The header SHALL declare
`void cleanupGpuLostStateAtomic(struct OBJGPU *, nv_gpu_lost_detector_t)`.
The implementation in `src/nvidia/arch/nvalloc/unix/src/os.c` SHALL be
idempotent (early-return when `PDB_PROP_GPU_IS_LOST` is already set) and
SHALL set both `PDB_PROP_GPU_IS_LOST` (via
`gpuSetDisconnectedProperties`) AND `pci_dev_is_disconnected` (via
`os_pci_set_disconnected(nv->handle)`) atomically.

The primitive SHALL emit at most one `NV_PRINTF(LEVEL_ERROR, ...)` per
**(GPU, detector class)** pair per kernel-module lifetime, naming the
GPU instance and the detector class. The log-once latch is a bitmap
field (`gpu_lost_detector_logged`) on `nv_state_t`, one bit per
detector class — keying on the per-GPU state means a second GPU's loss
is NOT silenced by the first GPU's log having already fired for the
same detector class.

The latch SHALL be exactly-once across concurrent detector fire on the
same (GPU, class): the implementation uses `__atomic_fetch_or` with
`__ATOMIC_RELAXED` and emits the `NV_PRINTF` only if the bit was clear
in the returned prior value. The dual-marker writes
(`gpuSetDisconnectedProperties` / `os_pci_set_disconnected`) are
already idempotent under the `PDB_PROP_GPU_IS_LOST` gate; the atomic
test-and-set on the log latch closes the only remaining
load-store-gap class (the rare double-log under simultaneous fire from
two detectors on the same GPU).

#### Scenario: Sink primitive sets both markers on first call
- **GIVEN** an OBJGPU whose `PDB_PROP_GPU_IS_LOST` is `NV_FALSE`
- **AND** `pci_dev_is_disconnected(nv->handle)` returns false
- **WHEN** `cleanupGpuLostStateAtomic(pGpu, DETECTOR_*)` is called
- **THEN** `PDB_PROP_GPU_IS_LOST` MUST be `NV_TRUE` after the call
- **AND** `pci_dev_is_disconnected(nv->handle)` MUST return true
- **AND** the primitive MUST emit exactly one log line naming the
  detector class

#### Scenario: Sink primitive is idempotent on re-entry
- **GIVEN** the primitive has already set both markers from a prior
  detector input (e.g. `DETECTOR_MMIO_DEAD` on GPU 0)
- **WHEN** the primitive is re-entered on the same GPU from the same
  detector class (e.g. another `DETECTOR_MMIO_DEAD` fire on GPU 0)
- **THEN** the primitive MUST return without re-issuing
  `gpuSetDisconnectedProperties` or `os_pci_set_disconnected`
- **AND** no additional dual-marker writes MUST be performed
- **AND** the log latch MUST suppress re-emission only when the same
  (gpu, detector class) pair has already fired; a different class on
  the same GPU (e.g. a subsequent `DETECTOR_AER_FATAL` after the
  initial `DETECTOR_MMIO_DEAD`) WILL emit its own canonical log line
  (see the per-(GPU, detector class) scenario below)

#### Scenario: Sink primitive accepts pGpu == NULL safely
- **GIVEN** a caller dispatches with `pGpu == NULL` (defensive path)
- **WHEN** the primitive is entered
- **THEN** the primitive MUST return immediately without dereferencing

#### Scenario: Log-once latch is per-(GPU, detector class)
- **GIVEN** two physical GPUs (GPU 0 and GPU 1)
- **AND** GPU 0 has already fired `DETECTOR_AER_FATAL` and the
  canonical "GPU 0 lost via detector_class=3" log has emitted
- **WHEN** GPU 1 subsequently fires `DETECTOR_AER_FATAL`
- **THEN** the primitive MUST emit a "GPU 1 lost via detector_class=3"
  log line for GPU 1 (the latch is keyed on the per-GPU
  `nv_state_t::gpu_lost_detector_logged` bitmap, not a module-global
  per-class array)

#### Scenario: Log-once latch is exactly-once under concurrent fire
- **GIVEN** two detectors fire on the same (GPU, detector class) pair
  simultaneously (e.g. AER callback + osHandleGpuLost on the same CPU
  cycle)
- **WHEN** both invocations reach the log latch concurrently
- **THEN** the `__atomic_fetch_or` operation MUST guarantee exactly
  one of the invocations sees `(prior & mask) == 0` and emits the
  NV_PRINTF
- **AND** the other invocation MUST observe `(prior & mask) != 0` and
  skip the log

### Requirement (v4): Driver SHALL route the MMIO post-read detector and the osHandleGpuLost retry-exhausted detector through the sink primitive

The two detection sites that pre-date v4 (`osDevReadReg032` post-read
verification in `os.c`, and `osHandleGpuLost` retry-exhausted branch in
`osinit.c`) SHALL be refactored to invoke `cleanupGpuLostStateAtomic`
with the appropriate `DETECTOR_*` tag (`DETECTOR_MMIO_DEAD` and
`DETECTOR_OSHANDLEGPULOST_RETRY_EXHAUSTED` respectively) rather than
calling `gpuSetDisconnectedProperties` + `os_pci_set_disconnected`
directly. This ensures every dual-marker transition lands through the
canonical idempotent path.

#### Scenario: MMIO post-read detector routes through primitive
- **GIVEN** the GPU is not yet marked lost
- **WHEN** `osDevReadReg032` returns `NV_GPU_BUS_DEAD_VALUE_U32`
- **AND** the NV_PMC_BOOT_0 verification read confirms the dead-bus
  sentinel
- **THEN** `cleanupGpuLostStateAtomic(pGpu, DETECTOR_MMIO_DEAD)` MUST
  be invoked
- **AND** both dual markers MUST be set after the call
- **AND** no direct invocation of `gpuSetDisconnectedProperties` /
  `os_pci_set_disconnected` MUST appear in the v4 post-read code path

#### Scenario: osHandleGpuLost detector routes through primitive
- **GIVEN** the C3 retry loop in `osHandleGpuLost` has exhausted its
  retry budget and confirmed the GPU is genuinely off the bus
- **WHEN** the lost-state branch executes
- **THEN** `cleanupGpuLostStateAtomic(pGpu,
  DETECTOR_OSHANDLEGPULOST_RETRY_EXHAUSTED)` MUST be invoked
- **AND** both dual markers MUST be coherent for any subsequent
  query through either `osIsGpuBusDead` or `pci_dev_is_disconnected`

### Requirement (v4): Driver SHALL wire GSP heartbeat timeout as detector [c]

In `_kgspRpcRecvPoll` (`src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c`),
the branch that classifies a fatal GSP timeout (when
`bIsFatalTimeout == NV_TRUE`) SHALL call
`cleanupGpuLostStateAtomic(pGpu, DETECTOR_GSP_HEARTBEAT_TIMEOUT)`
immediately after the existing handle-fatal-timeout path so the sink-
state is set with the canonical detector class. The hook keys on the
existing `_kgspIsTimeoutFatal` classifier so no new exposed entry
point is introduced.

#### Scenario: GSP fatal timeout fires the sink primitive
- **GIVEN** `_kgspRpcRecvPoll` is polling and the GPU timeout fires
- **AND** `_kgspIsTimeoutFatal` returns `NV_TRUE`
- **WHEN** the fatal-timeout branch executes
- **THEN** `cleanupGpuLostStateAtomic(pGpu,
  DETECTOR_GSP_HEARTBEAT_TIMEOUT)` MUST be invoked before the function
  returns
- **AND** subsequent `osDevReadReg032` calls on the same GPU MUST
  observe the dead-bus short-circuit through `osIsGpuBusDead`

### Requirement (v4): Driver SHALL wire AER `error_detected` DISCONNECT as detector [d]

In `nv_pci_error_detected` (`kernel-open/nvidia/nv-pci.c`), the
`default:` branch returning `PCI_ERS_RESULT_DISCONNECT` SHALL dispatch
through the new exported RM-side entry point `rm_cleanup_gpu_lost_state`
to set the RM marker. The kernel's PCI core sets the Linux marker
unconditionally on the DISCONNECT return path, so the RM-side dispatch
is the missing half of the dual-marker write. The dispatch uses
`pci_get_drvdata`/`NV_STATE_PTR`/`nv_kmem_cache_alloc_stack` per the
existing kernel-open patterns; the cross-module boundary is necessary
because OBJGPU is not addressable from `kernel-open/nvidia` directly.

`rm_cleanup_gpu_lost_state` SHALL acquire the API lock best-effort and
skip the RM-marker set if contention prevents acquisition; the Linux
marker (set by the kernel's AER state machine) plus the next MMIO read
funnel (which fires `DETECTOR_MMIO_DEAD`) close the coverage gap in
that case.

#### Scenario: AER fatal callback routes through sink primitive
- **GIVEN** the kernel's PCIe AER state machine has classified a fatal
  error on the device
- **WHEN** `nv_pci_error_detected` is invoked with a non-normal
  `pci_channel_state_t`
- **THEN** the callback MUST dispatch
  `rm_cleanup_gpu_lost_state(sp, NV_STATE_PTR(nvl), DETECTOR_AER_FATAL)`
- **AND** the callback MUST return `PCI_ERS_RESULT_DISCONNECT`
- **AND** the RM-side `PDB_PROP_GPU_IS_LOST` marker MUST be set if the
  API lock was acquired successfully; otherwise the next MMIO read
  funnel MUST converge on the same state via `DETECTOR_MMIO_DEAD`

### Requirement (v4): Driver SHALL detect probe-time BAR-allocation failure as detector [g]

In `nv_pci_probe` (`kernel-open/nvidia/nv-pci.c`), immediately after
`nv_pci_validate_bars(pci_dev, /* only_bar0 = */ NV_TRUE)` returns
TRUE, the driver SHALL iterate `pci_resource_flags(pci_dev, i)` for
`i ∈ [0, NV_GPU_NUM_BARS)` and SHALL refuse to continue probing (goto
the existing probe-failure path) if any BAR has `IORESOURCE_UNSET`.
OBJGPU is not constructed at this point in probe, so no sink-primitive
call is applicable here; the -ENODEV return is the actionable
behaviour. The log line SHALL name `detector_class=5
DETECTOR_PROBE_BAR_FAILURE` so the failure is greppable alongside the
sink-side detector logs.

#### Scenario: Probe with unassigned BAR refuses to continue
- **GIVEN** the Linux PCI core could not assign a memory window for
  one of the GPU's BARs (`pci_resource_flags(pci_dev, N) &
  IORESOURCE_UNSET`)
- **WHEN** `nv_pci_probe` reaches the BAR-validation block
- **THEN** the probe MUST log a NVRM error naming the failing BAR
  index and the detector class
- **AND** the probe MUST take the `goto failed` path (return -ENODEV)
- **AND** the driver MUST NOT proceed into `rm_init_adapter` /
  GSP-FMC bootstrap which can only fail in obscure ways

### Requirement (v4): Driver SHALL add seven new entry-point guards

G3, G5, G6, G7, G8, G9, G10 each SHALL short-circuit a specific class
of operations against a known-dead GPU. Each guard's site, condition,
and action are enumerated in the cascade-class-design-v4 architecture
diagram.

| Guard | Site | Condition | Action |
|---|---|---|---|
| G3 | `_issueRpcLarge` (rpc.c) | `PDB_PROP_GPU_IS_LOST` set | return `NV_ERR_GPU_IS_LOST` (mirror G2) |
| G5 | `_threadNodeCheckTimeout` (thread_state.c) | `API_GPU_ATTACHED_SANITY_CHECK` failed | `NV_GPU_LOST_LOG_ONCE` + return `NV_ERR_TIMEOUT` |
| G6 | `RmLogGpuCrash` (osapi.c) | `os_pci_is_disconnected` AND `PDB_PROP_GPU_IS_LOST` | `NV_GPU_LOST_LOG_ONCE` + return without crash-dump RPC |
| G7 | `rm_set_external_kernel_client_count` callers (nv.c) | return == `NV_ERR_GPU_IS_LOST` | suppress `WARN_ON` (silent tolerate) |
| G8 | `_kgspRpcRecvPoll` pre-loop (kernel_gsp.c) | `pKernelGsp->bFatalError` OR `PDB_PROP_GPU_IS_LOST` | return `NV_ERR_RESET_REQUIRED` (skip 75s lock-hold) |
| G9 | `_kfspWriteToEmem_GH100` post-first-read (kern_fsp_gh100.c) | first EMEMC read == 0xFFFFFFFF AND `PDB_PROP_GPU_IS_LOST` | `NV_GPU_LOST_LOG_ONCE` + return `NV_ERR_GPU_IS_LOST` |
| G10 | `nv_drm_remove` (nvidia-drm-drv.c) | `nvKms->isGpuLost(nv_dev->pDevice) == NV_TRUE` | skip `nv_drm_dev_destroy` hardware-touching teardown; route to `nv_drm_dev_destroy_lost` (cancel work, drop refcount, free wrapper -- no MMIO / RPC) |

#### Scenario: G3 short-circuits multi-chunk RPC on lost GPU
- **GIVEN** `PDB_PROP_GPU_IS_LOST` is set
- **WHEN** `_issueRpcLarge` is called
- **THEN** the function MUST return `NV_ERR_GPU_IS_LOST` before any
  send/poll cycle

#### Scenario: G5 rate-limits noisy sanity-check log
- **GIVEN** the GPU has gone off the bus
- **AND** `_threadNodeCheckTimeout` is being called repeatedly under
  timeout-storm conditions (e.g. issue #776 reproduction)
- **WHEN** `API_GPU_ATTACHED_SANITY_CHECK(pGpu)` returns false
- **THEN** the `NV_PRINTF(LEVEL_ERROR, ...)` log line MUST fire AT
  MOST ONCE per kernel-module lifetime per call site
- **AND** the function MUST still return `NV_ERR_TIMEOUT` so the
  caller's error-handling proceeds

#### Scenario: G6 skips diagnostic RPCs on confirmed-lost GPU
- **GIVEN** both `os_pci_is_disconnected(nv->handle)` returns true
  AND `PDB_PROP_GPU_IS_LOST` is set
- **WHEN** `RmLogGpuCrash(pGpu)` is entered
- **THEN** the function MUST log once and return early
- **AND** the function MUST NOT issue the
  `DUMP_PROTOBUF_COMPONENT`-class RPCs that would otherwise trigger
  the issue #461 cascade

#### Scenario: G7 suppresses WARN_ON on IS_LOST close-path
- **GIVEN** the close-path refcount drop encounters
  `rm_set_external_kernel_client_count` returning `NV_ERR_GPU_IS_LOST`
- **WHEN** the close-path code observes the return status
- **THEN** `WARN_ON` MUST NOT fire (no stack-trace flood)
- **AND** non-`NV_ERR_GPU_IS_LOST` non-`NV_OK` returns MUST retain
  the original `WARN_ON(1)` behaviour

#### Scenario: G8 pre-loop short-circuit avoids 75s lock-hold storm
- **GIVEN** `pKernelGsp->bFatalError` is already `NV_TRUE` (or
  `PDB_PROP_GPU_IS_LOST` is set) when `_kgspRpcRecvPoll` is entered
- **WHEN** the function executes the pre-loop check
- **THEN** the function MUST clear `pKernelGsp->bPollingForRpcResponse`
  and return `NV_ERR_RESET_REQUIRED` without entering the `for(;;)`
  loop
- **AND** the GPU lock MUST NOT be held for the timeout window
  (lock-hold time SHOULD be ≤ 1ms per call)

#### Scenario: G9 bypasses arithmetic invariant under dead-bus read
- **GIVEN** the FSP EMEMC register read returns `0xFFFFFFFF` AND
  `PDB_PROP_GPU_IS_LOST` is set
- **WHEN** `_kfspWriteToEmem_GH100` reaches the post-first-read check
- **THEN** the function MUST log once and return `NV_ERR_GPU_IS_LOST`
- **AND** the function MUST NOT enter the write loop and subsequent
  `NV_ASSERT_OR_RETURN((ememOffsetEnd - ememOffsetStart) ==
  wordsWritten)` invariant check

#### Scenario: G10 short-circuits hardware-touching teardown when sink is set
- **GIVEN** the C5 v4 sink primitive has set the dead-bus marker on the
  affected GPU (either Linux `pci_dev_is_disconnected` via the AER
  DISCONNECT callback / `os_pci_set_disconnected`, or the RM marker
  `PDB_PROP_GPU_IS_LOST` via `cleanupGpuLostStateAtomic`)
- **WHEN** `nv_drm_remove(gpuId)` is invoked (normal unload OR
  hot-eject) and a matching `nv_drm_device` is found
- **THEN** `nv_drm_remove` MUST query the cross-module
  `nvKms->isGpuLost(nv_dev->pDevice)` predicate exposed through the
  `NvKmsKapiFunctionsTable` extension (provider: nvidia-modeset.ko's
  `IsGpuLost` -> `nvkms_is_gpu_lost` -> `__rm_ops.is_gpu_lost`
  jump-table entry -> nvidia.ko's `nvidia_dev_is_gpu_lost` ->
  `os_pci_is_disconnected`)
- **AND** the query MUST return `NV_TRUE`
- **AND** the teardown MUST route to `nv_drm_dev_destroy_lost` which
  cancels in-flight workers, drops the DRM refcount via `drm_dev_put`,
  and frees the `nv_drm_device` wrapper via `nv_drm_free`
- **AND** the teardown MUST NOT call `nv_drm_dev_unload` (i.e. MUST
  NOT invoke `drm_atomic_helper_shutdown`, `nvKms->releaseOwnership`,
  `drm_kms_helper_poll_fini`, `drm_mode_config_cleanup`,
  `nvKms->declareEventInterest`, or `nvKms->freeDevice` -- each of
  which issues NVKMS RPC that would timeout against the dead bus and
  reproduce the >5min teardown hang documented in GitHub #1134)
- **AND** `drm_dev_unplug(nv_dev->dev)` MUST still be called
  unconditionally BEFORE the destroyer (DRM-core requirement; releases
  userspace file-op waiters and tears down dma-buf bindings)
- **AND** an `NV_DRM_DEV_LOG_INFO` line MUST fire reporting the
  `gpuLost=true` branch
- **AND** (trade-off acknowledged) this path leaks
  (1) DRM-core internal state — connector / encoder / crtc objects,
      mode config — reclaimed by `drm_dev_put` refcount drop only if
      `drm_mode_config_cleanup` runs (which is skipped here); and
  (2) the underlying `NvKmsKapiDevice` struct (kmalloc-backed via
      `nvkms_alloc` → `kmalloc(GFP_KERNEL)`) including the RM client
      handle and the per-device semaphore — normally freed by
      `nvKms->freeDevice`, skipped here to avoid the RPC → MMIO chain
      against a dead bus.
- **AND** the `NvKmsKapiDevice` leak is bounded but real:
  `nvKmsModuleUnload` does not walk a master list to free outstanding
  per-GPU devices (none exists — they are owned by external callers
  like nvidia-drm), so the leak persists across rmmod/insmod of
  `nvidia-modeset`, freed only at host reboot. Per-event cost is
  O(1KB) and the event is once per lost-GPU teardown (typically 0–1
  over a host lifetime), so the steady-state footprint is bounded.
  A forced-cleanup path that calls `freeDevice` through the C5 G2/G3
  funnels (which short-circuit on `PDB_PROP_GPU_IS_LOST`) is feasible
  follow-on work; deferred from this commit pending a dedicated
  review of the `freeDevice` teardown chain.
- **AND** the bounded leak remains strictly preferable to the
  multi-minute teardown hang documented in #1134.

#### Scenario: Stale-read race on `isGpuLost` query in `nv_drm_remove` is benign
- **GIVEN** `nv_drm_remove` has read the `isGpuLost` predicate as
  `NV_FALSE` and is about to dispatch the normal `nv_drm_dev_destroy`
  path
- **WHEN** an AER fatal callback fires on the same GPU AFTER the
  `isGpuLost` read but BEFORE the normal-path destroyer begins
  issuing NVKMS RPCs (i.e. the query is a stale-read)
- **THEN** the C5 G2/G3 funnels in `nvidia.ko`'s `_issueRpcAndWait`
  and `_issueRpcAndWaitLarge` MUST short-circuit any RPCs the
  destroyer subsequently issues (the sink has been set by the AER
  path before any RPC reaches the funnel)
- **AND** the hang class documented in #1134 MUST NOT be
  reintroduced; the worst-case outcome is a heavier teardown path
  with extra G2/G3 short-circuit log lines
- **AND** therefore no re-query of `isGpuLost` inside the destroyer
  is required (defense-in-depth is provided by the downstream
  funnels, not by re-querying at every dispatch site)

#### Scenario: G10 falls through to normal teardown when GPU is alive
- **GIVEN** the sink primitive has NOT marked the GPU lost
- **WHEN** `nv_drm_remove(gpuId)` is invoked (e.g. clean module
  unload, suspend-driven device removal)
- **THEN** `nvKms->isGpuLost(nv_dev->pDevice)` MUST return `NV_FALSE`
- **AND** the teardown MUST route to the original `nv_drm_dev_destroy`
  full-unload path (i.e. `nv_drm_dev_unload` MUST run normally, doing
  the hardware-touching NVKMS teardown that the alive GPU can service)
- **AND** an `NV_DRM_DEV_LOG_INFO` line MUST fire reporting the
  `gpuLost=false` branch (useful for triage to confirm the sink-aware
  path is reachable but not gating the normal teardown)

### Requirement (v4): Telemetry consolidation — per-site logs retire in favor of canonical sink log

The per-site `NV_GPU_LOST_LOG_ONCE` latches added by C5 v1 and v3 at
the 8 cleanup-path conversion sites (`nv_debug_dump.c`,
`kernel_graphics.c`, `fecs_event_list.c` ×2,
`kernel_falcon_tu102.c`, `kernel_gsp_tu102.c`, `vaspace_api.c`,
`mem.c`, `rs_server.c:1389`) SHALL be removed in v4. The canonical
per-detector-class log line emitted by `cleanupGpuLostStateAtomic`
replaces them. At most two canonical site-level logs SHALL be retained
as defense-in-depth (one in `rs_client.c`, one in `rs_server.c:268`).
The three NEW guard-specific logs (G5 thread_state, G6 RmLogGpuCrash,
G9 kfsp) are not retirements — they're new guard entry-point logs
covering surfaces where the canonical sink log alone is insufficient
for triage (high call frequency, distinct diagnostic context).

#### Scenario: Cleanup-path site receives IS_LOST without flooding the kernel log
- **GIVEN** a cleanup cascade traverses the 8 converted sites under
  a lost-GPU teardown
- **WHEN** each site evaluates its `NV_ASSERT_OR_GPU_LOST*` macro
- **THEN** no additional log line MUST fire from the per-site code
  path (the canonical sink-side log fired once at detection)
- **AND** the assertion MUST still accept `NV_ERR_GPU_IS_LOST`
  without firing (covered by the v3 macro family)
- **AND** the 2 retained resserv canonical logs MUST still fire
  (defense-in-depth: if the sink primitive was somehow bypassed,
  these logs are the last-resort record)

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
