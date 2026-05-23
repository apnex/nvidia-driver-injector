---
id: C3-gpu-lost-retry
layer: base
source-branch: c3-gpu-lost-retry
upstream-candidacy: high
telemetry-tier: mandatory
status: reviewed
related-patches: [C5-crash-safety]
---

# C3-gpu-lost-retry — Survive Transient PCIe Reads in the GPU-Lost Preflight

## Purpose

`osHandleGpuLost` reads `NV_PMC_BOOT_0` once and, if the value does not
match the chip identifier stored at probe (`nvp->pmc_boot_0`), commits
the GPU permanently to the lost state by emitting the
`GPU_HAS_FALLEN_OFF_THE_BUS` Xid, latching the disconnected PDB
property, notifying clients, and (for eGPU) raising `SURPRISE_REMOVAL`.
A single transient PCIe read failure — routine on hot-pluggable and
tunnelled (Thunderbolt / USB4) links, where the link can briefly drop
and recover — therefore takes a still-attached GPU offline until
reboot; this is the failure mode reported upstream as
NVIDIA/open-gpu-kernel-modules#979. This patch bounds the preflight
with a small retry budget so a momentary glitch is distinguished from
a genuine disconnect: the read SHALL be repeated up to a fixed number
of attempts at a fixed sub-millisecond interval, the GPU SHALL be
declared lost only if every attempt reads back a mismatched value, and
every recovered transient SHALL produce one mandatory log line so the
event is not silent.

## Requirements

### Requirement: Driver SHALL bound the GPU-lost preflight with a retry budget

When `osHandleGpuLost` runs against a GPU whose `PDB_PROP_GPU_IS_CONNECTED`
property is still set, the driver SHALL re-read `NV_PMC_BOOT_0` up to a
fixed retry count and SHALL declare the GPU lost only if every read in
the retry window returns a value that does not equal the chip identifier
saved at probe (`nvp->pmc_boot_0`). If any read in the retry window
returns the matching chip identifier, the driver MUST treat the earlier
mismatched reads as transient, MUST NOT commit the GPU to the lost
state, and MUST return `NV_OK`. Between successive attempts the driver
SHALL pause for a fixed sub-millisecond delay using `osDelayUs`; the
driver MUST NOT pause after the final attempt. The cumulative delay
budget MUST remain below one millisecond so the retry is invisible to
every existing caller and below the GSP RPC poll cadence.

#### Scenario: A single bad read recovers on the next attempt
- **GIVEN** an attached GPU whose stored `nvp->pmc_boot_0` is `C`
- **AND** the first `NV_PMC_BOOT_0` read returns a value `V != C`
- **AND** a subsequent read within the retry window returns `C`
- **WHEN** `osHandleGpuLost(pGpu, bEmitXid)` runs
- **THEN** the function MUST return `NV_OK`
- **AND** the function MUST NOT call `gpuSetDisconnectedProperties`
- **AND** the function MUST NOT call `gpuNotifySubDeviceEvent` with
  `ROBUST_CHANNEL_GPU_HAS_FALLEN_OFF_THE_BUS`
- **AND** the function MUST NOT set `NV_FLAG_IN_SURPRISE_REMOVAL`
- **AND** the function MUST NOT emit the `Xid` for
  `ROBUST_CHANNEL_GPU_HAS_FALLEN_OFF_THE_BUS` regardless of `bEmitXid`

#### Scenario: A genuine disconnect reads dead on every attempt
- **GIVEN** an attached GPU whose stored `nvp->pmc_boot_0` is `C`
- **AND** every `NV_PMC_BOOT_0` read within the retry window returns a
  value `!= C` (including `0xFFFFFFFF`)
- **WHEN** `osHandleGpuLost(pGpu, NV_TRUE)` runs
- **THEN** after the retry budget is exhausted the driver MUST proceed
  to the lost-state branch
- **AND** the driver MUST emit the
  `ROBUST_CHANNEL_GPU_HAS_FALLEN_OFF_THE_BUS` Xid via `nvErrorLog_va`
- **AND** the driver MUST call `gpuSetDisconnectedProperties(pGpu)`
- **AND** for eGPUs the driver MUST set
  `NV_FLAG_IN_SURPRISE_REMOVAL`
- **AND** the function MUST return `NV_OK`

#### Scenario: The very first read returns the matching identifier
- **GIVEN** an attached GPU whose first `NV_PMC_BOOT_0` read equals
  `nvp->pmc_boot_0`
- **WHEN** `osHandleGpuLost(pGpu, bEmitXid)` runs
- **THEN** the function MUST return `NV_OK` immediately on the first
  iteration
- **AND** `osDelayUs` MUST NOT be called
- **AND** no recovery log line MUST be emitted

#### Scenario: The handler is a no-op when the GPU is already known disconnected
- **GIVEN** a GPU whose `PDB_PROP_GPU_IS_CONNECTED` property is
  cleared at entry
- **WHEN** `osHandleGpuLost(pGpu, bEmitXid)` runs
- **THEN** the function MUST return `NV_OK` immediately
- **AND** `NV_PMC_BOOT_0` MUST NOT be read
- **AND** no retry loop iteration MUST execute

### Requirement: Driver SHALL emit one log line on every recovered transient

On every invocation that returns `NV_OK` because a retry within the
retry window read back the matching chip identifier after one or more
mismatching reads, the driver SHALL emit exactly one kernel log line at
device-error severity (`NV_DEV_PRINTF(NV_DBG_ERRORS, nv, ...)`,
equivalent to `dev_err` with the device's PCI BDF prefixed by the
`NVRM: GPU` prefix) reporting the recovered-retry count. The driver
MUST NOT log per-retry attempts — high-frequency retry attempts on a
degraded link would otherwise spam the log. The driver MUST NOT emit
the recovery log when the first read already matched (no retry was
needed) and MUST NOT emit it when the retry budget was exhausted
without a match (the lost-state path emits its own diagnostic).

#### Scenario: Recovered after one retry
- **GIVEN** the first read returns a mismatched value and the second
  read returns `nvp->pmc_boot_0`
- **WHEN** `osHandleGpuLost(pGpu, bEmitXid)` runs
- **THEN** exactly one kernel log line MUST be emitted naming the
  device's PCI BDF and reporting a retry count of `1`
- **AND** the format string MUST grammatically agree with the singular
  count (e.g. `"1 retry"`, not `"1 retries"`)

#### Scenario: Recovered after multiple retries
- **GIVEN** the first `N > 1` reads return mismatched values and the
  `(N+1)`th read returns `nvp->pmc_boot_0`
- **WHEN** `osHandleGpuLost(pGpu, bEmitXid)` runs
- **THEN** exactly one kernel log line MUST be emitted naming the
  device's PCI BDF and reporting a retry count of `N`
- **AND** the format string MUST use the plural form (`"N retries"`)

#### Scenario: No recovery log when the budget is exhausted
- **GIVEN** every read in the retry window returns a mismatched value
- **WHEN** `osHandleGpuLost(pGpu, bEmitXid)` runs
- **THEN** the recovery log line MUST NOT be emitted
- **AND** the existing `"GPU has fallen off the bus."` diagnostic
  remains the sole device log line for that invocation (besides Xid
  emission when `bEmitXid` is set)

## Scope boundary

- This patch covers ONLY the `osHandleGpuLost` preflight in
  `src/nvidia/arch/nvalloc/unix/src/osinit.c`. Dead-bus reads from
  other call sites — `osGpuReadReg*` family, RPC paths to GSP,
  cleanup paths, `gpuSanityCheckRegRead_IMPL` — are covered by
  [[C5-crash-safety]] and the addon recovery patches.
- This patch deliberately does NOT introduce a module parameter for
  the retry count or the delay. The constants
  (`NV_GPU_LOST_RETRY_COUNT = 10`, `NV_GPU_LOST_RETRY_DELAY_US = 100`)
  are file-scope `#define`s in `osinit.c`; the cumulative ~1 ms
  budget is small enough to be safe unconditionally. If upstream
  review requests a tunable, the change is local to this file and
  does not affect any other patch.
- This patch does NOT perform PCIe-link recovery (slot reset, link
  retrain). The retry distinguishes a transient READ-result glitch
  from a genuine bus drop; any recovery action when the bus is
  genuinely gone is the responsibility of [[C5-crash-safety]] and the
  addon recovery stack.
- This patch does NOT alter the lost-state branch's behaviour
  (Xid, `gpuSetDisconnectedProperties`, surprise-removal flag,
  `RmLogGpuCrash`, `DBG_BREAKPOINT`). It only changes the condition
  under which the lost-state branch is entered.
- This patch does NOT change the `bEmitXid` semantics. Callers
  passing `NV_FALSE` (the per-arch detach paths in
  `kern_gpu_gb*.c`, `kern_gpu_gh100.c`) continue to suppress the
  Xid as before; only the success-on-retry path becomes silent for
  the Xid signal.
- This patch does NOT modify the `nvp->pmc_boot_0` capture site in
  `RmInitPrivateState` / `RmClearPrivateState` — the stored chip
  identifier and its lifecycle are unchanged.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| Transient PCIe read recovered after retry | `NV_DEV_PRINTF(NV_DBG_ERRORS, nv, ...)` (the project's `dev_err`-equivalent with the `NVRM: GPU <BDF>:` prefix expanded automatically) | `"GPU-lost check: transient PCIe read recovered after %u retr%s\n"` where `%u` is the retry count and `%s` selects between `"y"` (count == 1) and `"ies"` (count > 1) |

The log line fires exactly once per `osHandleGpuLost` invocation that
recovers within the retry budget. No per-retry log line is emitted —
high-frequency retry attempts on a degraded link would otherwise spam
the kernel log. The retry-budget-exhausted path emits the pre-existing
`"GPU has fallen off the bus."` diagnostic via the lost-state branch
and is not part of this contract.

## Provenance

- **Source cluster:** P2 of the legacy P1-P6 refactor — the
  pre-refactor predecessors of this patch were folded into the
  M-recover work in `patches/legacy/`; C3 is the standalone
  carve-out of the `osHandleGpuLost` preflight retry, decoupled
  from M-recover (which is now [[C5-crash-safety]] for the
  base-layer primitives + addon A3-recovery for the recovery
  actions).
- **Vanilla baseline:**
  `src/nvidia/arch/nvalloc/unix/src/osinit.c:osHandleGpuLost`
  (vanilla 595.71.05 issues exactly one `NV_PRIV_REG_RD32`
  against `NV_PMC_BOOT_0` and falls through to the lost-state
  branch on mismatch; the comment block immediately preceding the
  lost-state branch already acknowledges the missing PEX Reset
  and Recovery — `"This doesn't support PEX Reset and Recovery
  yet."`).
- **Fork branch:** `c3-gpu-lost-retry` on
  `apnex/open-gpu-kernel-modules`.
- **Upstream issue:**
  https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979 —
  Blackwell GPU over Thunderbolt: brief PCIe link drop commits
  GPU to permanent lost state. This patch is the direct fix for
  the reported failure mode; the upstream report's implied
  remedy (bounded retry of the single-read preflight) is
  realised here.
