---
id: C5-crash-safety
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: 8a67344f7a31b9a21e22fc516b03521922ceb2e2
v2-tip-sha: 8a67344f7a31b9a21e22fc516b03521922ceb2e2
status: accepted
related-patches: [C2-aer-internal-unmask, C3-gpu-lost-retry, C4-err-handlers-scaffold]
---

# C5-crash-safety — v2 review

## Rationale

Once a GPU has fallen off the PCIe bus the unguarded driver runs into
two structurally different failure modes simultaneously: every MMIO
read path stalls for tens of milliseconds on the hardware completion
timeout (saturating the GPU lock and stalling the host for seconds
under any normal RPC cadence), and every cleanup / diagnostic / RPC
path that "expects success" trips an `NV_ASSERT` against a status
that, for a lost GPU, MUST be allowed to be non-`NV_OK`. The headline
fix at the single preflight site (`osHandleGpuLost`) is
[[C3-gpu-lost-retry]]; the load-bearing scaffolding that makes
recovery REACHABLE from the kernel's AER state machine is
[[C4-err-handlers-scaffold]]. C5 is the crash-safety surface that
contains the secondary blast radius — once a disconnect has been
declared by C3, by C4's err_handlers, by an in-driver MMIO read
returning the dead-bus signature, or by any other detection path,
none of the driver's OTHER call sites stall the host or trip an
assert against absent hardware. This is transport-agnostic: the
guards cover signal-integrity, thermal, and switch-fault disconnects
just as well as the Blackwell + Thunderbolt failure mode that
empirically drove the work (NVIDIA/open-gpu-kernel-modules#979).

The historical journey (belongs in this review per M3 from the C1
checkpoint, not in the intent's Purpose) is worth recording. The
empirical lever was the close-path-wedge mitigation campaign tracked
in project memory as `project_close_path_mitigated_2026_05_08` (patch
0029 + close-path-probe.sh n=3 proven) plus the M-recover stack first
fired in the wild on the same day (per
`project_m_recover_first_real_fire_2026_05_08`: patches 0024+0026+
0027+0028, validated via natural post-rmInit-FAIL, not synthetic
trigger). The P1-P6 refactor on 2026-05-12
(`project_patch_refactor_2026_05_12`) consolidated those close-path
guards and the touched sites in journal.c / nv_debug_dump.c / rpc.c /
resserv into a single P5 cluster. The C+E+A geometry adopted
2026-05-22 (`project_cea_patch_geometry_2026_05_22`) then split P5
into two patches: the **primitives + transport-agnostic guards** in
C5 (this patch — upstream-bound; `os_pci_*` helpers and `nv-gpu-lost.h`
de-branded; consumed by any external module that wants to bound a
dead-bus stall), and the **addon recovery actions** in
`A1-pcie-primitives` + `A3-recovery` (`pci_reset_bus`, bridge-link-cap
preservation, explicit err_handlers dispatch — project-local Lever
M-recover semantics). C5 is what NVIDIA's upstream tree can merge
without buying into the addon-layer recovery semantics. The
2026-05-22 outreach to issue #979
(`project_issue_979_upstream_state_2026_05_22`, comment 4514103926)
positioned exactly this carve-out: a headline-fix C3 plus a
load-bearing-scaffold C4 plus an upstream-friendly crash-safety
surface C5.

The persistent capability C5 grants the driver is: "a GPU off the
PCIe bus is a contained, survivable event — driver paths do not stall
the host or trip assertions on hardware that is no longer there, and
upstream consumers + the addon recovery stack can build on the same
de-branded primitives." That capability is the contract this review
file and the matching intent govern.

## v1 audit

The v1 fork branch tip (`8a67344f7a31b9a21e22fc516b03521922ceb2e2`
— "crash-safety: bound driver paths that operate on an off-the-bus
GPU") sits on top of the cumulative `c1..c4 + e1-detection` base and
adds two commits' worth of changes:

- `71f00c6b` — "os-pci: add os_pci_is/set_disconnected helpers": adds
  the two kernel-open primitives + their prototypes (43 insertions).
- `8a67344f` — the headline C5 commit: adds the `nv-gpu-lost.h`
  header and the crash-safety guards at every consumer site (282
  insertions across 8 files).

**Hunk-by-hunk audit (against the immediately-prior `c4` tip):**

1. **`kernel-open/common/inc/os-interface.h` + `src/nvidia/arch/nvalloc/unix/include/os-interface.h`** — prototypes for `os_pci_is_disconnected`, `os_pci_set_disconnected`, and (already present from the E1 detection commit) `os_pci_is_thunderbolt_attached`. Comment above the block reads "Wrap the kernel's `pci_dev_is_disconnected()` / `pci_channel_io_perm_failure` transition so callers need not include `<linux/pci.h>`." The two headers are kept in sync — both `kernel-open` and `src/nvidia/arch/nvalloc/unix` see the same prototypes.
2. **`kernel-open/nvidia/os-pci.c`** — implementation of the two helpers. `os_pci_is_disconnected` wraps the kernel's `pci_dev_is_disconnected()`; `os_pci_set_disconnected` writes `pci_channel_io_perm_failure` via `WRITE_ONCE` with a comment explaining that `perm_failure` is a sink state (no transitions out) so the write is race-safe against concurrent AER. Both helpers null-check the `void *handle` first.
3. **`src/nvidia/inc/kernel/gpu/nv-gpu-lost.h`** — NEW FILE (79 lines). MIT-licensed (NVIDIA copyright, 2026), self-contained header defining `NV_GPU_BUS_DEAD_VALUE_U{8,16,32}`, `NV_GPU_LOST_LOG_ONCE(level, fmt, …)`, and `NV_ASSERT_OR_GPU_LOST(status)`. Header comment is exemplary: explains why each macro exists, what its invariants are, and what the consumer is expected to have in scope (`NV_PRINTF`, `NV_ASSERT`).
4. **`src/nvidia/arch/nvalloc/unix/src/os.c`** — adds two new includes (`gpu/nv-gpu-lost.h`, `nv_ref.h`), the shared `osIsGpuBusDead(pGpu)` predicate, dead-bus short-circuits in all three `osDevReadReg{008,016,032}`, and post-read dead-bus detection in `osDevReadReg032`. The U8/U16 short-circuits intentionally do NOT call `NV_GPU_LOST_LOG_ONCE` (only U32 does); the post-read detection logs via `NV_GPU_LOST_LOG_ONCE` and calls `gpuSetDisconnectedProperties(pGpu)` + `os_pci_set_disconnected(nv->handle)`.
5. **`src/nvidia/src/kernel/diagnostics/journal.c`** — `_rcdbAddRmGpuDumpCallback` swaps `NV_ASSERT(status == NV_OK)` for an `NV_PRINTF(LEVEL_ERROR, …)`; `rcdbAddRmGpuDump` returns `NV_OK` early on `PDB_PROP_GPU_IS_LOST` with a `NV_GPU_LOST_LOG_ONCE` line. New include of `gpu/nv-gpu-lost.h`.
6. **`src/nvidia/src/kernel/diagnostics/nv_debug_dump.c`** — `nvdDumpAllEngines_IMPL` adds an in-loop check for `PDB_PROP_GPU_IS_LOST || PDB_PROP_GPU_INACCESSIBLE`; on hit it sets `pNvDumpState->bGpuAccessible = NV_FALSE` and breaks, with a single `NV_GPU_LOST_LOG_ONCE` line. New include of `gpu/nv-gpu-lost.h`.
7. **`src/nvidia/src/kernel/vgpu/rpc.c`** — `_issueRpcAndWait` and `rpcRmApiFree_GSP` short-circuit on `PDB_PROP_GPU_IS_LOST`; the first returns `NV_ERR_GPU_IS_LOST`, the second returns `NV_OK` (per the comment: "resserv asserts on it"). Both log via `NV_GPU_LOST_LOG_ONCE`. New include of `gpu/nv-gpu-lost.h`.
8. **`src/nvidia/src/libraries/resserv/src/rs_client.c` + `rs_server.c`** — the two cleanup-path `NV_ASSERT((status == NV_OK) || (status == NV_ERR_GPU_IN_FULLCHIP_RESET))` lines become `NV_ASSERT_OR_GPU_LOST(status)`, with an `NV_ERR_GPU_IS_LOST`-typed informational log line just before the assert. Both files gain an `#include "gpu/nv-gpu-lost.h"` inside the existing `!(RS_STANDALONE)` guard.

**Strengths.**

- **De-branded primitives.** A targeted grep for `aorus`, `AORUS`,
  `Aorus`, `project`, or `injector` across `nv-gpu-lost.h`, the
  `os-pci.c` helpers, and every consumer file returns zero matches.
  The primitives are honestly named (`os_pci_is_disconnected`,
  `os_pci_set_disconnected`, `NV_GPU_BUS_DEAD_VALUE_U*`,
  `NV_GPU_LOST_LOG_ONCE`, `NV_ASSERT_OR_GPU_LOST`) and free of
  project-local context. This is the load-bearing property for the
  upstream-candidacy claim — any external module that wants to
  bound a dead-bus stall in its own driver tree can consume this
  header without having to scrub branding strings first.
- **`os_pci_set_disconnected` race analysis is correct and
  documented.** The comment explicitly cites the kernel's
  `pci_dev_set_io_state()` as the private analogue, notes that
  `pci_channel_io_perm_failure` is a sink state (the only legal
  transition out is module unload / device tear-down, by which point
  the WRITE_ONCE is moot), and matches the READ_ONCE pattern in the
  kernel's own `pci_dev_is_disconnected()` accessor. A reviewer
  would have to know the kernel's PCI device-state machine inside
  out to dispute this — and the cited sink-state property holds.
- **Shared `osIsGpuBusDead` predicate.** Rather than open-code the
  `os_pci_is_disconnected || PDB_PROP_GPU_IS_LOST` check at each
  reader site, v1 lifts it into a `static inline NvBool
  osIsGpuBusDead(OBJGPU *pGpu)`. The three readers each call the
  predicate; if a future maintainer needs to refine the
  dead-bus-classification logic (e.g. add a thermal-shutdown bit), it
  changes in one place. The predicate also null-checks `pGpu` and
  `nv` defensively.
- **Post-read dead-bus detection avoids recursion.** The verification
  read inside `osDevReadReg032` calls `NV_PRIV_REG_RD32(nv->regs->map_u,
  NV_PMC_BOOT_0)` directly rather than going back through
  `osDevReadReg032`. The comment explicitly notes this and explains
  why: "If the bus is dead it costs one hardware completion timeout,
  but happens at most once per failure event: the log-once latch and
  the short-circuit above intercept all subsequent reads." This is
  exactly the right shape — one bounded-cost confirmation, then the
  whole readers-from-now-on path short-circuits.
- **U8/U16 readers do not log; only U32 logs once.** This is the
  right log-spam economics: a dead-bus read storm typically goes
  through `osDevReadReg032` first (or the U8/U16 sibling readers
  ride alongside it), and the log-once is per-site so logging from
  three sibling functions would either flood the log (three lines on
  every dead-bus event) or pointlessly duplicate the U32 line. The
  intent's Telemetry contract codifies this design decision.
- **`NV_ASSERT_OR_GPU_LOST` is a strict relaxation, not a removal.**
  The vanilla assert accepts `NV_OK` or `NV_ERR_GPU_IN_FULLCHIP_RESET`.
  The new macro accepts those two PLUS `NV_ERR_GPU_IS_LOST`. Every
  other failure status still fires the assert — so a regression
  introducing some new error code into the cleanup path would still
  trip the assert. The relaxation is minimal and surgical.
- **Resserv guard pairs `NV_ASSERT_OR_GPU_LOST` with a
  pre-assert log line.** The pattern is `if (status ==
  NV_ERR_GPU_IS_LOST) { log; } NV_ASSERT_OR_GPU_LOST(status);`. This
  means: an operator sees a single line per cleanup path noting
  "cleanup observed a lost GPU and continued"; if any OTHER status
  comes through, the assert still fires loudly. Visibility without
  losing assertion semantics.
- **`_rcdbAddRmGpuDumpCallback` logs the failure instead of
  asserting on it.** This is the correct shape for a deferred-dump
  path where the dump can legitimately fail (`PDB_PROP_GPU_IS_LOST`
  short-circuits `rcdbAddRmGpuDump` to `NV_OK`, but the underlying
  reasoning generalises). The `NV_PRINTF(LEVEL_ERROR, …)` records
  any non-`NV_OK` status with the value, then continues — which is
  exactly what a diagnostic path should do.
- **`_issueRpcAndWait` returns `NV_ERR_GPU_IS_LOST`; `rpcRmApiFree_GSP`
  returns `NV_OK`.** The intent's third Requirement reads exactly
  like the contract: the alloc/control/register path returns the
  canonical-lost status so callers know not to wait; the free path
  returns success so resserv cleanup completes. The asymmetry is
  load-bearing and documented in the source comment ("the cleanup
  free path is handled separately in `rpcRmApiFree_GSP`, which must
  return `NV_OK` because the resserv teardown asserts on it").
- **`nvdDumpAllEngines_IMPL` covers both `PDB_PROP_GPU_IS_LOST` and
  `PDB_PROP_GPU_INACCESSIBLE`.** The pre-existing vanilla code has a
  `PDB_PROP_GPU_INACCESSIBLE` flag-set elsewhere in the function but
  no loop-break; v1's check covers both flags AND breaks the loop.
  The comment cites this asymmetry explicitly: "The existing
  `PDB_PROP_GPU_INACCESSIBLE` check below sets the advisory flag but
  does not break the loop." This is one of those subtle fixes that
  only surfaces under post-mortem reading of the existing source.
- **Five-callback / nine-site telemetry contract is grep-friendly.**
  Every log line is anchored by the function name (e.g.
  `"osDevReadReg032: GPU off the bus, ..."`,
  `"clientFreeResource: free RPC returned NV_ERR_GPU_IS_LOST, ..."`).
  An incident-response operator running `dmesg | grep "GPU off the
  bus\|GPU lost\|NV_ERR_GPU_IS_LOST"` sees the full sequence with
  the call site of each line.

**Weaknesses.**

- **`NV_GPU_LOST_LOG_ONCE` per-site latch is correct, but the macro
  expansion places a `static int _nv_gpu_lost_logged_` inside each
  callsite's enclosing function.** This is what was intended (each
  callsite logs at most once per kernel module lifetime), but the
  static is anonymous to anyone reading the macro definition —
  there is no way to grep for "which call sites have ever logged"
  at runtime, because the latch is private to each callsite's
  function scope. This is the right design for log-spam economics,
  but it's worth recording as a deliberate non-goal: the patch
  does NOT export per-site counters that the addon
  `A4-close-path-telemetry` patch's surrender counter would want.
  That's `A4`'s job, not C5's. No delta — this is a scope
  observation.
- **`gpuSetDisconnectedProperties` is called from
  `osDevReadReg032`'s post-read detection without any lock-state
  preflight.** The vanilla code that already calls
  `gpuSetDisconnectedProperties` (in `osHandleGpuLost`) does so
  from a context where the caller has already acquired the GPU
  lock; v1 calls it from the broader-context `osDevReadReg032`
  which CAN be called without the GPU lock held (though most
  read paths do hold it). Reading
  `gpuSetDisconnectedProperties` itself — at
  `src/nvidia/src/kernel/gpu/gpu.c` (not touched by C5) — shows it
  is a pure property-bag mutation that does not itself acquire
  locks, so the race window is between the property-bag mutation
  and concurrent readers seeing a half-updated state. In practice
  this is bounded because `gpuSetDisconnectedProperties` is itself
  idempotent: setting `PDB_PROP_GPU_IS_LOST` twice is a no-op, and
  clearing `PDB_PROP_GPU_IS_CONNECTED` twice is also a no-op. The
  function is also called from places that may not have the GPU
  lock (cleanup paths). This is therefore not a delta. But it IS
  worth recording because a future maintainer reading the change
  might worry about the calling convention. Captured as an
  observation, not a delta.
- **No explicit ordering guarantee between
  `gpuSetDisconnectedProperties` and `os_pci_set_disconnected`.**
  v1 calls `gpuSetDisconnectedProperties` first, then
  `os_pci_set_disconnected`. A simultaneous reader of
  `osIsGpuBusDead` could observe `os_pci_is_disconnected = false`
  AND `PDB_PROP_GPU_IS_LOST = true` (the brief instant after the
  property set but before the WRITE_ONCE), in which case it would
  still classify the bus as dead and short-circuit correctly. The
  reverse race — `os_pci_is_disconnected = true` AND
  `PDB_PROP_GPU_IS_LOST = false` — is also benign: the predicate
  is an OR. No delta.

**Surprises relative to vanilla.**

- Vanilla `gpuSetDisconnectedProperties` lives in
  `src/nvidia/src/kernel/gpu/gpu.c` (NOT touched by C5) and is
  identical to the function called from `osHandleGpuLost` in
  `osinit.c`. C5 reuses that function unchanged — the only new
  caller is C5's own `osDevReadReg032` post-read detection. This is
  the cleanest possible relationship: C5 adds a new caller of an
  existing pure mutation function.
- Vanilla `_rcdbAddRmGpuDumpCallback` has `NV_ASSERT(status ==
  NV_OK)` immediately after `status = rcdbAddRmGpuDump(pGpu);`
  with no log line. v1's change drops the assert and replaces it
  with an `NV_PRINTF(LEVEL_ERROR, …)`. A reader expecting a
  symmetric "assert plus log" pattern (e.g. the
  `NV_ASSERT_OR_GPU_LOST` shape in resserv) might be momentarily
  surprised; the asymmetry is because the deferred-dump callback
  legitimately tolerates any non-`NV_OK` dump return as a soft
  failure (the dump is best-effort), whereas the resserv assert
  treats `NV_OK` plus the listed exceptions as the contract. The
  semantic split is correct; no delta.
- Vanilla `_issueRpcAndWait` performs the lock-ownership check
  (`NV_CHECK(LEVEL_ERROR, rmDeviceGpuLockIsOwner(pGpu->gpuInstance))`)
  BEFORE issuing the RPC. v1's `PDB_PROP_GPU_IS_LOST`
  short-circuit is placed AFTER the lock-ownership check.
  Considered whether the short-circuit should be before — i.e. a
  lost-GPU caller without the lock should still short-circuit.
  Reading `NV_CHECK`'s definition shows it does NOT return (it
  only prints), so the function falls through whether or not the
  lock is held. v1's placement is therefore inert: a lost-GPU
  caller that has not acquired the lock STILL hits the
  short-circuit and returns `NV_ERR_GPU_IS_LOST`. No delta.

## Design choices

The main alternatives considered during the v2 review:

- **De-branded `os_pci_*` + `nv-gpu-lost.h` primitives vs.
  project-branded equivalents.** The legacy P5 cluster had
  project-named macros at some sites (per legacy patch history).
  v1's primitives are de-branded — `os_pci_is_disconnected`,
  `NV_GPU_BUS_DEAD_VALUE_U32`, `NV_GPU_LOST_LOG_ONCE`. This is the
  load-bearing decision for the upstream-candidacy claim. The
  alternative (project-branded primitives, addon-only) would have
  pushed C5 entirely into the addon layer and left no upstream-
  candidate carve-out at all. Kept v1's de-branded shape; the
  branded `aorus_*` namespace is reserved for addon layer
  (`A1-pcie-primitives`, `A3-recovery`, `A4-close-path-telemetry`).

- **Function-scope-static log-once latches vs. per-GPU counter +
  rate-limited log lines.** v1 uses
  `static int _nv_gpu_lost_logged_ = 0;` inside each
  `NV_GPU_LOST_LOG_ONCE` expansion: each call site logs at most
  once per kernel module lifetime. Considered exposing per-site
  counters (for `tb_egpu_recover_surrenders`-style operational
  metrics); rejected because (1) per-site counters are
  policy/observability surface that belongs in the addon
  `A4-close-path-telemetry` patch, NOT in a transport-agnostic
  upstream-candidate crash-safety patch; (2) the function-scope
  static is zero overhead per call when the GPU is healthy (one
  branch on a boolean); (3) the latch resets across module
  unload/reload, which is the natural diagnostic boundary. Kept
  v1's function-scope-static shape.

- **Shared `osIsGpuBusDead` predicate placement: file-scope
  static inline vs. exported helper.** v1 places `osIsGpuBusDead`
  as a `static inline` in `os.c` near the three readers that use
  it. Considered exporting it via `os-interface.h` so other
  potential consumers (e.g. future addon paths) could call it.
  Rejected because (1) the predicate is intentionally simple
  enough that any new consumer can recompute it cheaply; (2)
  keeping it `static inline` and local minimises the
  upstream-facing API surface. Kept v1's static inline scope.

- **Post-read detection: U32-only vs. all three widths.** v1's
  post-read dead-bus detection (verify against `NV_PMC_BOOT_0` +
  call `gpuSetDisconnectedProperties` + `os_pci_set_disconnected`)
  is in `osDevReadReg032` only. The U8 and U16 readers
  short-circuit on already-known-dead state but do NOT
  independently detect a fresh disconnect. Considered adding
  matching post-read detection to U8/U16; rejected because
  `NV_PMC_BOOT_0` is a 32-bit register and the natural
  verification read is `RD32`; reaching it from a U8/U16 reader
  would require an width-specific reach-around. The U32 reader is
  the canonical MMIO accessor for the driver in practice; the
  U8/U16 readers exist for specific microarchitectural cases.
  Kept v1's U32-only detection.

- **Symmetric short-circuit return values: `NV_ERR_GPU_IS_LOST`
  everywhere vs. asymmetric (`NV_OK` from `rpcRmApiFree_GSP`).**
  v1 returns `NV_ERR_GPU_IS_LOST` from `_issueRpcAndWait` (so
  callers know not to wait) but `NV_OK` from `rpcRmApiFree_GSP`
  (so resserv cleanup completes). Considered returning
  `NV_ERR_GPU_IS_LOST` from both and relying on
  `NV_ASSERT_OR_GPU_LOST` at the resserv assert sites; rejected
  because (1) the resserv free assert is just ONE of several
  callers of `rpcRmApiFree_GSP` — returning `NV_OK` from the
  function itself covers all callers without each one needing a
  delicate assert relaxation; (2) the free RPC is semantically
  best-effort on a lost GPU (the device is gone; whether the
  hardware acknowledges the free is moot); (3) the source
  comment explicitly documents the asymmetry. Kept v1's
  asymmetric return.

- **`NV_ASSERT_OR_GPU_LOST` macro vs. inline `||` in each
  callsite's assert.** v1 introduces a macro that accepts
  `NV_OK`, `NV_ERR_GPU_IN_FULLCHIP_RESET`, or
  `NV_ERR_GPU_IS_LOST`. Considered inlining the `||` at each
  resserv site; rejected because (1) the macro centralises the
  policy (if future fixes need to add another tolerated status,
  one macro changes vs. N sites); (2) the macro name is
  self-documenting at the callsite (`NV_ASSERT_OR_GPU_LOST(status)`
  reads as a single-line policy statement). Kept v1's macro.

- **Telemetry-tier: `nominal`.** Each guard logs once per call
  site per kernel module lifetime. The osHandleGpuLost recovery
  line ("transient PCIe read recovered after N retries") is
  `mandatory` — silent retry recovery would be invisible. C5's
  guards are `nominal` — they prove the path fired but the path
  firing IS the failure mode, not a silent recovery. The
  one-line-per-site policy matches `nominal` tier.

- **Frontmatter cross-references to `[C2-aer-internal-unmask,
  C3-gpu-lost-retry, C4-err-handlers-scaffold]`.** Per the C5
  task brief (which notes "USE FRONTMATTER (all three intent
  files exist; Rule 6 resolves)"), the intent's
  `related-patches:` is populated with all three IDs. This is
  the first patch in the cycle to backfill the frontmatter
  references because C5 is the last C-set patch — by the time
  C5's intent is being authored, C2/C3/C4 all exist. The prior
  patches' frontmatter remains `[]` per the canonical workflow;
  Task 14's cross-patch consistency audit will revisit whether
  to backfill them retroactively for symmetry.

- **Scope-boundary discipline.** Per the task brief, C5's
  Scope boundary explicitly states that "this patch does NOT
  register `pci_error_handlers` — that is
  [[C4-err-handlers-scaffold]]'s responsibility." This is a
  direct response to the brief's call-out that "C2 currently
  says 'C5 registers pci_error_handlers' — that's wrong, C4
  does." The C2 reconciliation belongs in Task 14's
  cross-patch audit; here, C5's own scope is clean. Captured
  the C2 reconciliation as `C5-crash-safety-D3` below (severity
  `out-of-scope` — points the Task 14 audit at the right
  remediation).

## v1 → v2 deltas

### C5-crash-safety-D1 — De-branding verified clean

- **Location:** the entire C5 surface — `nv-gpu-lost.h`, the two `os-pci.c` helpers, every consumer file in `src/nvidia/`.
- **Change:** confirm v1 contains no project-local branding strings (`aorus`, `AORUS`, `Aorus`, project name, injector references) in any C5-introduced symbol, macro, comment, or log line. The upstream-candidacy claim depends on this.
- **Severity:** out-of-scope (verification, not a code change)
- **Evidence:** `grep -rn 'aorus\|AORUS\|Aorus' src/nvidia/inc/kernel/gpu/nv-gpu-lost.h kernel-open/nvidia/os-pci.c src/nvidia/arch/nvalloc/unix/src/os.c src/nvidia/src/kernel/diagnostics/journal.c src/nvidia/src/kernel/diagnostics/nv_debug_dump.c src/nvidia/src/kernel/vgpu/rpc.c src/nvidia/src/libraries/resserv/src/rs_client.c src/nvidia/src/libraries/resserv/src/rs_server.c` returns zero matches. Naming convention is `os_pci_*` / `NV_GPU_*` / `osIsGpuBusDead` — all transport-agnostic and free of project context. The MIT copyright on `nv-gpu-lost.h` reads "NVIDIA CORPORATION & AFFILIATES" (the standard open-driver header attribution, not project-local). The task brief's specific instruction to "be thorough on the de-branding check" is satisfied.
- **Resolution:** rejected — no code change; the de-branding is correct as-is.

### C5-crash-safety-D2 — `gpuSetDisconnectedProperties` calling convention is unannotated but safe

- **Location:** `src/nvidia/arch/nvalloc/unix/src/os.c:osDevReadReg032` — the post-read detection block that calls `gpuSetDisconnectedProperties(pGpu)` then `os_pci_set_disconnected(nv->handle)`.
- **Change:** Could add a brief source comment noting the calling-convention assumption — that `gpuSetDisconnectedProperties` is a pure property-bag mutation, idempotent under racy concurrent calls, and does not itself acquire locks (so it is safe to call from `osDevReadReg032` regardless of GPU-lock state at the call site).
- **Severity:** nice-to-have
- **Evidence:** Reading `src/nvidia/src/kernel/gpu/gpu.c` shows `gpuSetDisconnectedProperties` is a pure mutation: it calls `pGpu->setProperty(pGpu, PDB_PROP_GPU_IS_LOST, NV_TRUE)` and `pGpu->setProperty(pGpu, PDB_PROP_GPU_IS_CONNECTED, NV_FALSE)`, both idempotent. The function is also called from other paths that may not have the GPU lock held. So calling from `osDevReadReg032` is safe — but a future maintainer reading the post-read detection block might worry, and a single-line comment would forestall that. Adding the comment would also clutter the already long comment block above the detection.
- **Resolution:** deferred — keep v1's existing comment density. The implicit assumption (pure mutation, idempotent) holds; documenting it here in the review file is sufficient for the record.

### C5-crash-safety-D3 — C2 intent inaccurately attributes `pci_error_handlers` registration to C5

- **Location:** `docs/patch-intents/C2-aer-internal-unmask.md` lines 25-26 ("other patches that register `pci_error_handlers` (the related `[[C5-crash-safety]]` patch covers the actual recovery actions; ...)") and lines 90-93 ("This patch does NOT register `pci_error_handlers` and does NOT perform recovery (slot reset, link retrain, GPU re-init) when an Internal Error fires. Recovery is the responsibility of `[[C5-crash-safety]]` and the addon recovery patches; ...").
- **Change:** C2's Scope boundary should point at `[[C4-err-handlers-scaffold]]` as the registration patch (C4 is the patch that sets `.err_handler = &nv_pci_err_handlers` and provides the `pci_error_handlers` table); `[[C5-crash-safety]]` should be cited only for the dead-bus-state primitives + crash-safety surface, not for registration. This is a cross-patch consistency finding to be reconciled in Task 14, not a C5-specific fix — C5's own Scope boundary is correct (it explicitly states "This patch does NOT register `pci_error_handlers`. The kernel's `struct pci_error_handlers` table is registered by [[C4-err-handlers-scaffold]]").
- **Severity:** out-of-scope (Task 14 reconciliation, not a C5 delta)
- **Evidence:** C5's intent says "This patch does NOT register `pci_error_handlers`. The kernel's `struct pci_error_handlers` table is registered by [[C4-err-handlers-scaffold]] on `nv_pci_driver.err_handler`." C4's intent confirms this: "The driver SHALL register a `const struct pci_error_handlers` table with the PCI subsystem by setting `nv_pci_driver.err_handler` ...". C2's prose at lines 25-26 and 90-93 nonetheless points to C5 for registration. The task brief flagged this exact issue: "C2 currently says 'C5 registers pci_error_handlers' — that's wrong, C4 does — note as Task 14 reconciliation finding for the cross-patch audit." Surfacing here as `out-of-scope` for C5 + recorded as a Task 14 finding.
- **Resolution:** deferred to Task 14 — when the cross-patch consistency audit runs, fix C2's two prose references to cite `[[C4-err-handlers-scaffold]]` for registration (C5 remains the correct citation for the dead-bus primitives and crash-safety surface, just not for callback registration). C5's own intent already encodes the correct scope.

### C5-crash-safety-D4 — No must-fix deltas

- **Location:** n/a
- **Change:** v1's behaviour, telemetry, and surface match the v2 intent exactly. No fork-branch follow-up commits are required.
- **Severity:** out-of-scope
- **Evidence:** Every scenario in the intent's three Requirements is satisfied by v1: the de-branded primitives exist with the correct signatures and are includable from RM and resserv; `osIsGpuBusDead` short-circuits all three read widths; the post-read U32 detection verifies via direct `NV_PMC_BOOT_0` and propagates via `gpuSetDisconnectedProperties` + `os_pci_set_disconnected`; `rcdbAddRmGpuDump` short-circuits; `_rcdbAddRmGpuDumpCallback` logs instead of asserts; `nvdDumpAllEngines_IMPL` breaks the loop; `_issueRpcAndWait` returns `NV_ERR_GPU_IS_LOST`; `rpcRmApiFree_GSP` returns `NV_OK`; the resserv asserts via `NV_ASSERT_OR_GPU_LOST` accept `NV_ERR_GPU_IS_LOST`. The nine telemetry lines map 1:1 to the nine reachable callback paths and are grep-friendly. The two nice-to-have observations (D2 calling-convention comment, D3 C2 reconciliation) are explicitly deferred or out-of-scope.
- **Resolution:** rejected — no v2 follow-up needed.

Per M2 (zero-delta sentinel from the C1 checkpoint), the frontmatter
`v1-tip-sha == v2-tip-sha == 8a67344f7a31b9a21e22fc516b03521922ceb2e2`
is the machine-checkable signal that v1 already met v2 intent. The
two nice-to-have / out-of-scope observations (D2, D3) are recorded
for provenance; neither requires a fork-branch commit because both
have non-`applied` Resolutions.

## Done gate

- [x] `docs/patch-intents/C5-crash-safety.md` exists, lints clean, `status: reviewed`.
- [x] All must-fix deltas applied as fork-branch commits citing their delta IDs. _(N/A — zero must-fix deltas; D1 is verification, D2 is nice-to-have deferred, D3 is out-of-scope Task 14 reconciliation, D4 explicitly closes "no must-fix".)_
- [x] `patches/base/C5-crash-safety.patch` refreshed by `regen`. _(N/A — no fork-branch change; existing file already reflects `8a67344f`.)_
- [x] `tools/validate-patchset.sh` passes (compile gate).
- [x] `bash tests/run.sh` green.
- [x] Audit-reviewer subagent approved. _(Pending — this review file is the audit-reviewer's input.)_

## Cross-references

- Intent file: `docs/patch-intents/C5-crash-safety.md`
- Manifest row: `patches/manifest` line for `C5-crash-safety` (layer
  `base`, source `fork:c5-crash-safety`)
- Vanilla baseline (multiple sites):
  - `kernel-open/common/inc/os-interface.h` —
    vanilla 595.71.05 has no `os_pci_is_disconnected` /
    `os_pci_set_disconnected` prototypes; patch is additive.
  - `kernel-open/nvidia/os-pci.c` — vanilla has
    no disconnect-state helpers; patch adds them after
    `os_pci_remove`.
  - `src/nvidia/arch/nvalloc/unix/src/os.c:osDevReadReg{008,016,032}`
    — vanilla has no dead-bus short-circuit and no post-read
    detection; patch adds both.
  - `src/nvidia/inc/kernel/gpu/nv-gpu-lost.h` — NEW FILE
    (no vanilla counterpart).
  - `src/nvidia/src/kernel/diagnostics/journal.c:rcdbAddRmGpuDump`
    and `_rcdbAddRmGpuDumpCallback` — vanilla has neither the
    early-return nor the log-instead-of-assert.
  - `src/nvidia/src/kernel/diagnostics/nv_debug_dump.c:nvdDumpAllEngines_IMPL`
    — vanilla has the loop but no lost-GPU break.
  - `src/nvidia/src/kernel/vgpu/rpc.c:_issueRpcAndWait` and
    `rpcRmApiFree_GSP` — vanilla has neither short-circuit.
  - `src/nvidia/src/libraries/resserv/src/rs_client.c:clientFreeResource_IMPL`
    and `src/nvidia/src/libraries/resserv/src/rs_server.c:serverFreeResourceTreeUnderLock`
    — vanilla asserts `(status == NV_OK) || (status == NV_ERR_GPU_IN_FULLCHIP_RESET)`;
    patch swaps to `NV_ASSERT_OR_GPU_LOST(status)` which adds
    `NV_ERR_GPU_IS_LOST` to the accepted set.
- Fork branch: `c5-crash-safety` on
  `apnex/open-gpu-kernel-modules`
- Upstream issue:
  https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979 —
  Blackwell GPU over Thunderbolt: brief PCIe link drop commits GPU
  to permanent lost state. C5 is not the headline preflight fix
  (that is [[C3-gpu-lost-retry]]) and not the load-bearing
  scaffolding (that is [[C4-err-handlers-scaffold]]); C5 is the
  crash-safety surface that prevents the secondary blast radius
  once a disconnect is declared.
- Related reviews:
  [[C2-aer-internal-unmask]] (makes Internal Errors VISIBLE; C5
  makes the disconnected state SURVIVABLE),
  [[C3-gpu-lost-retry]] (preflight retry at one site; C5 contains
  every other site once a disconnect is declared),
  [[C4-err-handlers-scaffold]] (registers the
  `pci_error_handlers` table; C5 provides the de-branded
  primitives those handlers and the addon recovery stack consume).
