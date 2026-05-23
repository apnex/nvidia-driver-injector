---
id: C3-gpu-lost-retry
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: c589673a33729e24c5179f92c5c98dbac4886d6b
v2-tip-sha: c589673a33729e24c5179f92c5c98dbac4886d6b
status: accepted
related-patches: [C5-crash-safety]
---

# C3-gpu-lost-retry — v2 review

## Rationale

Vanilla `osHandleGpuLost` in
`src/nvidia/arch/nvalloc/unix/src/osinit.c` performs a single
`NV_PRIV_REG_RD32` against `NV_PMC_BOOT_0` and, on any mismatch
against the chip identifier saved at probe (`nvp->pmc_boot_0`),
unconditionally commits the GPU to a permanent lost state:
`gpuSetDisconnectedProperties` latches `PDB_PROP_GPU_IS_LOST` and
clears `PDB_PROP_GPU_IS_CONNECTED`, the
`GPU_HAS_FALLEN_OFF_THE_BUS` Xid is emitted, every subdevice
listener gets `NV2080_NOTIFIERS_GPU_UNAVAILABLE`, eGPU paths set
`NV_FLAG_IN_SURPRISE_REMOVAL`, and a crash dump is initiated. The
GPU stays offline until module unload + reload, which on this
project's deployment means a reboot. This is the failure mode
reported upstream as
[NVIDIA/open-gpu-kernel-modules#979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979)
— "Blackwell GPU over Thunderbolt: brief PCIe link drop commits
GPU to permanent lost state." On the project's NUC 15 Pro+ +
AORUS RTX 5090 eGPU setup, transient PCIe link blips at GSP boot
and during heavy MMIO traffic are routine; the single-read
preflight makes the driver's surprise-removal handling
disproportionately fragile to events the link itself recovers
from in microseconds. C3 is the canonical fix — a bounded retry
of the preflight read that distinguishes a glitch from a genuine
disconnect.

The historical journey to this patch (which belongs in this
review per M3 from the C1 checkpoint, not in the intent's
Purpose) is worth recording. The empirical lever was Lever P in
the legacy stack, originally implemented as a `gpu-lost-retry`
patch in `patches/legacy/` and folded together with the
M-recover work into a combined surprise-removal recovery suite.
The P1-P6 refactor on 2026-05-12 surfaced the need to decouple
the preflight retry (cheap, narrow, no infrastructure
dependencies) from the actual recovery actions (slot reset,
link retrain, `pci_reset_bus` dispatch — the M-recover stack
now consolidated in [[C5-crash-safety]] for primitives and the
addon `A3-recovery` for behaviour). C3 is the standalone
carve-out of that preflight retry: ~38 lines added to a single
function in `osinit.c`, no new files, no module parameter, no
dependencies on any other patch in the set. The headline #979
fix is now a self-contained patch that NVIDIA's upstream tree
can merge without buying into anything else this project
ships.

The persistent capability C3 grants the driver is: "a single
transient PCIe read returning a value that fails to match the
chip identifier no longer commits the GPU to a permanent lost
state." That capability is the contract this review file and
the matching intent govern.

## v1 audit

The v1 fork branch tip
(`c589673a33729e24c5179f92c5c98dbac4886d6b` — "osinit: retry
NV_PMC_BOOT_0 before declaring the GPU lost") makes one
behavioural change against the vanilla 595.71.05 baseline in
`src/nvidia/arch/nvalloc/unix/src/osinit.c`:

**Hunk 1** — new file-scope constants and an explanatory block
comment inserted immediately before `osHandleGpuLost`:

```c
/*
 * osHandleGpuLost() retries the NV_PMC_BOOT_0 read this many times, with
 * this delay between attempts, before concluding the GPU has fallen off
 * the bus. A single transient PCIe read failure -- routine on
 * hot-pluggable / tunnelled links -- would otherwise commit the GPU to a
 * permanent lost state from one bad read. ~1 ms total is well within any
 * caller's tolerance and far below the GSP RPC poll cadence.
 */
#define NV_GPU_LOST_RETRY_COUNT     10U
#define NV_GPU_LOST_RETRY_DELAY_US  100U
```

**Hunk 2** — new `NvU32 retry;` local variable in
`osHandleGpuLost`, plus replacement of the single MMIO read with
a bounded for-loop:

```c
//
// Retry NV_PMC_BOOT_0 before concluding the GPU has fallen off the
// bus. A momentary glitch reads back wrong on one attempt but correct
// on a subsequent one; a genuine disconnect reads wrong on every
// attempt. The bounded retry distinguishes the two -- fixing the
// single-bad-read commit-to-permanent-loss behaviour reported upstream
// as NVIDIA/open-gpu-kernel-modules#979.
//
for (retry = 0; retry < NV_GPU_LOST_RETRY_COUNT; retry++)
{
    pmc_boot_0 = NV_PRIV_REG_RD32(nv->regs->map_u, NV_PMC_BOOT_0);
    if (pmc_boot_0 == nvp->pmc_boot_0)
    {
        if (retry > 0)
        {
            NV_DEV_PRINTF(NV_DBG_ERRORS, nv,
                          "GPU-lost check: transient PCIe read recovered "
                          "after %u retr%s\n",
                          retry, (retry == 1) ? "y" : "ies");
        }
        return NV_OK;
    }
    if (retry < (NV_GPU_LOST_RETRY_COUNT - 1))
        osDelayUs(NV_GPU_LOST_RETRY_DELAY_US);
}
```

The pre-existing `if (pmc_boot_0 != nvp->pmc_boot_0) { ... }`
block that contains the lost-state logic is left unchanged.

**Strengths.**

- **Comparison is against the stored chip identifier, not the
  literal `0xFFFFFFFF`.** The task brief described the dead-bus
  signature as "single completion-timeout manifesting as
  `0xFFFFFFFF`," but v1 is strictly stronger: it compares
  `pmc_boot_0 == nvp->pmc_boot_0`. That catches `0xFFFFFFFF` as
  one instance, but it also catches any other corruption mode
  (partial completion, scrambled TLP payload, wrong-address
  response) where the read returns something that isn't the
  chip identifier. The narrowing logic in the vanilla code
  already uses this comparison; v1 inherits it correctly.
- **Retry budget is small and bounded.** 10 iterations × 100 µs
  = 900 µs of MMIO + 9 × 100 µs busy-wait = ~1 ms worst case.
  `osDelayUs(100)` resolves to `nv_sleep_us(100)` which uses
  `udelay()` for sub-millisecond delays (busy-wait, not
  `msleep`), so the retry is safe to call from atomic contexts
  including interrupt handlers — `nv_sleep_us` explicitly
  guards `nv_in_hardirq() && (us > NV_MAX_ISR_DELAY_US)` and
  100 µs sits well under that threshold.
- **Last-iteration sleep is correctly skipped.** The
  `if (retry < (NV_GPU_LOST_RETRY_COUNT - 1))` guard ensures
  the function never trails a useless 100 µs delay after the
  final read. This is a textbook bounded-retry detail and v1
  gets it right.
- **Recovery telemetry exists, fires exactly once per recovery,
  and never on the no-retry-needed fast path.** The
  `if (retry > 0)` guard inside the success branch is the
  schema's "no per-retry logging" requirement realised in
  code. The format string includes the retry count via `%u`
  and uses a ternary for grammatical agreement (`"retry"` vs
  `"retries"`).
- **`NV_DEV_PRINTF` automatically prefixes the PCI BDF.** The
  task brief flagged "format string might be missing context
  (e.g. the PCI BDF, the GPU index)" as a possible delta;
  reading
  `src/nvidia/arch/nvalloc/unix/include/os-interface.h:265`
  shows the macro expands to
  `nv_printf(debuglevel, "NVRM: GPU " NV_PCI_DEV_FMT ": " format, …)`
  — so the BDF prefix is automatic. No delta needed; the v1
  log line is well-formed.
- **No module parameter.** The task brief asked us to confirm
  this matches the schema example's "introduces NO module
  parameter" stipulation. Confirmed: the constants are
  file-scope `#define`s, not registry variables, and there is
  no `NVreg_GpuLostRetry*` knob.
- **In-source comment block explains the WHY.** The block
  comment above the constants and the inline comment above the
  for-loop both cite #979 by name; a future maintainer reading
  the source has the rationale on-hand.

**Weaknesses.**

- **Stylistic dead-code: the post-loop
  `if (pmc_boot_0 != nvp->pmc_boot_0)` is always true.** Once
  control falls through the for-loop without an early
  `return NV_OK`, every iteration must have hit the
  `pmc_boot_0 != nvp->pmc_boot_0` branch (otherwise the early
  return fired). The pre-existing `if` is harmless — the
  compiler likely elides it — but a careful reader notices the
  redundancy. v1 deliberately preserves the original `if`
  shape to minimise the diff against vanilla, which is
  reasonable for an upstream-candidate patch but is worth
  calling out. Captured as `C3-gpu-lost-retry-D1` below with
  `Severity: nice-to-have` and a `Resolution: deferred`
  recommendation.
- **Log level is `NV_DBG_ERRORS`, not `NV_DBG_WARNINGS`.** A
  successful recovery is semantically a warning ("anomaly
  detected, mitigated") rather than an error ("operation
  failed"). The file's own convention is to use
  `NV_DBG_ERRORS` for every `NV_DEV_PRINTF` call site (0 uses
  of `NV_DBG_WARNINGS` in `osinit.c`), so v1's choice matches
  surrounding style. Captured as `C3-gpu-lost-retry-D2` below
  with `Severity: nice-to-have` and a `Resolution: deferred`
  recommendation.

**Surprises relative to vanilla.**

- Vanilla `osHandleGpuLost` already has the comment
  `"This doesn't support PEX Reset and Recovery yet."` —
  NVIDIA themselves flagged the missing recovery in the
  immediate vicinity of the single-read preflight. The C3
  patch does NOT introduce PEX reset and recovery (that's
  C5/A3 territory); it addresses the strictly narrower
  problem of "is this a transient or a real loss?" before
  any recovery question is even asked. The semantic split is
  clean.
- Vanilla 595.71.05's `RmInitPrivateState` (lines 1610-1720
  of `osinit.c`) saves `pmc_boot_0` directly from the same
  `NV_PMC_BOOT_0` register at probe time; the stored value is
  preserved across `RmClearPrivateState` (which clears most
  of `nv_priv_t` but explicitly hoists `pmc_boot_0` through
  the clear). The retry comparison sentinel is therefore
  well-defined across the full GPU lifecycle.
- `osHandleGpuLost` has 9 call sites (`osapi.c:5443`,
  `gpu_access.c` ×4, the per-arch detach paths in
  `kern_gpu_gb100.c`, `kern_gpu_gb10b.c`, `kern_gpu_gb202.c`,
  `kern_gpu_gb20b.c`, `kern_gpu_gh100.c`). All callers
  tolerate the ~1 ms latency: `gpuVerifyExistence_IMPL` (the
  canonical RM-side caller from `gpu_access.c`) already does
  a follow-up `GPU_REG_RD32(pGpu, NV_PMC_BOOT_0)` after
  calling `osHandleGpuLost`, demonstrating that the existence
  check is designed to absorb additional MMIO probe cost.
  The per-arch detach paths call from teardown sequences
  where the budget is similarly inconsequential.

## Design choices

The main alternatives considered during the v2 review:

- **Comparison against `0xFFFFFFFF` literal vs. against
  `nvp->pmc_boot_0`.** The task brief described the dead-bus
  signature as "completion-timeout manifesting as
  `0xFFFFFFFF`," which would have justified a narrower
  comparison
  (`if (pmc_boot_0 == 0xFFFFFFFF) retry; else accept`). v1
  inherits vanilla's broader comparison (any mismatch against
  the stored chip identifier triggers the lost-state path)
  and applies the retry to it. The broader comparison is
  strictly better: it catches partial completions, address
  scrambling, and any other corruption mode where the read
  succeeds but returns a wrong value. The narrower comparison
  would silently let those modes through. Kept v1's
  vanilla-inherited comparison.

- **Retry count + delay constants vs. module parameters.**
  The schema's worked example for C3 explicitly says "NO
  module parameter"; v1 conforms. Considered offering
  `NVreg_GpuLostRetryCount` and `NVreg_GpuLostRetryDelayUs`
  for upstream-review flexibility. Chose against on two
  grounds: (1) the cumulative budget is ~1 ms, small enough
  that no caller has standing to demand a different value;
  (2) upstream-PR surface is smaller without the registry
  scaffolding. If a regression ever surfaces, the constants
  can be tuned in a follow-up; this patch sets the right
  default.

- **Block comment placement: above the function vs. inside
  the function body.** v1 puts the long-form rationale in a
  block comment immediately ABOVE the `osHandleGpuLost`
  function (between `osDpcDetachGpu` and the function
  signature) where it describes the retry constants, and a
  shorter inline comment INSIDE the function body just above
  the for-loop. The split keeps the function body readable
  while documenting the "why bother retrying" question at the
  constant-definition site. Considered consolidating both
  into one location; the split is more navigable. Kept v1's
  two-location comment structure.

- **Linear back-off vs. exponential vs. fixed delay.** v1
  uses a fixed 100 µs between every attempt — 10 reads × 100
  µs ≈ 1 ms total. Exponential back-off (e.g. 50 → 100 →
  200 → 400 µs, total ~750 µs) would converge to roughly the
  same budget but with longer tail intervals; linear back-off
  (100, 200, 300, … µs, total ~5.5 ms) would exceed the
  ~1 ms budget. Fixed delay is the simplest and matches the
  ~1 ms-budget rationale in the block comment. Kept v1's
  fixed delay.

- **Log level: `NV_DBG_ERRORS` (file convention) vs.
  `NV_DBG_WARNINGS` (semantic accuracy).** The recovered-
  transient event is semantically a WARNING (anomaly
  observed, mitigated). The file's surrounding convention
  uses `NV_DBG_ERRORS` for every `NV_DEV_PRINTF` call site.
  v1 follows the file convention. Considered switching to
  `NV_DBG_WARNINGS` for semantic accuracy; chose to defer
  because: (1) the surrounding lost-state branch uses
  `NV_DBG_ERRORS` and consistency aids grep-based incident
  response; (2) `NV_DBG_ERRORS` ensures the log appears even
  on production kernels where lower-severity messages may be
  rate-limited or filtered; (3) on the project's empirical
  ground truth (transient blips on TB4-tunnelled PCIe links),
  a recovered transient IS an event the operator should
  notice — error severity reflects operational concern even
  if not formal kernel taxonomy. See `C3-gpu-lost-retry-D2`
  below.

- **Dead-code simplification: the post-loop `if` is now
  always true.** Once the for-loop falls through, every read
  must have missed (the early return swallows the success
  case), so the pre-existing
  `if (pmc_boot_0 != nvp->pmc_boot_0)` block becomes
  unconditional. Considered simplifying to a plain `{` block;
  chose to preserve the original `if` shape to minimise the
  diff against vanilla and to keep upstream review focused on
  the additive retry-loop change rather than a stylistic
  rewrite. See `C3-gpu-lost-retry-D1` below.

- **Telemetry-tier: `mandatory`.** The schema doc names C3 as
  the canonical example of `telemetry-tier: mandatory` —
  "silent retry recovery would be invisible without the
  `dev_warn` 'transient bus read recovered after %d retries'
  line." The intent's Requirement-2 enshrines the
  log-once-on-recovery contract. v1 matches the contract
  (the level is `NV_DBG_ERRORS` rather than `dev_warn` per
  the schema's illustrative anchor, but the file-convention
  reasoning in the previous bullet justifies the
  substitution; the intent's telemetry contract names
  `NV_DBG_ERRORS` explicitly so the schema example's
  `dev_warn` and the intent's `NV_DBG_ERRORS` are
  reconciled).

- **Vanilla-baseline location: schema example anchor vs.
  actual source location.** The task brief and the schema doc
  use `kernel-open/nvidia/os-mlock.c:osHandleGpuLost` as an
  illustrative backtick anchor. The actual implementation of
  `osHandleGpuLost` lives in
  `src/nvidia/arch/nvalloc/unix/src/osinit.c`; the
  `kernel-open/nvidia/os-mlock.c` file exists but does not
  define this symbol. The intent's Provenance section and
  this review's Cross-references both name the real location.
  This is methodology friction worth surfacing to the
  controller (see "Methodology friction to surface" below).

- **Frontmatter cross-reference to [[C5-crash-safety]].**
  Per the C2 review precedent and the canonical workflow,
  `related-patches:` stays `[]` in the intent file's
  frontmatter (Rule 6 lint resolution requires the target
  intent file to exist, and C5 is authored later in Task 8).
  The body-prose `[[C5-crash-safety]]` wikilink is used
  throughout for presentation. Task 14's cross-patch
  consistency audit will revisit whether to backfill the
  frontmatter once C5's intent exists.

## v1 → v2 deltas

### C3-gpu-lost-retry-D1 — Stylistic dead-code in post-loop `if`

- **Location:** `src/nvidia/arch/nvalloc/unix/src/osinit.c:osHandleGpuLost` — the `if (pmc_boot_0 != nvp->pmc_boot_0)` immediately after the new for-loop.
- **Change:** Could simplify to a plain block (`{ ... }`), removing the always-true conditional, on the grounds that control only reaches that point if every retry returned a mismatched value.
- **Severity:** nice-to-have
- **Evidence:** After the for-loop, an early `return NV_OK` is the only way out of the success case. Falling through to the `if` means `pmc_boot_0 != nvp->pmc_boot_0` must hold. The conditional is technically dead. However, removing it expands the diff surface against vanilla (a brace-only block vs. an `if` block), which would make the upstream PR review larger for no behavioural benefit. The compiler likely elides the always-true comparison.
- **Resolution:** deferred — keep the `if` to minimise vanilla-diff surface for the upstream PR. Documented here so future maintainers don't mistake the redundancy for a bug.

### C3-gpu-lost-retry-D2 — Recovery log level matches file convention not semantic class

- **Location:** `src/nvidia/arch/nvalloc/unix/src/osinit.c:osHandleGpuLost` — the `NV_DEV_PRINTF(NV_DBG_ERRORS, nv, "GPU-lost check: transient PCIe read recovered ...")` inside the retry-success branch.
- **Change:** Could switch the log level from `NV_DBG_ERRORS` to `NV_DBG_WARNINGS` to reflect that a recovered transient is operationally a warning (anomaly mitigated), not an error (operation failed).
- **Severity:** nice-to-have
- **Evidence:** Counts in v1's `osinit.c` show `NV_DBG_ERRORS` × 6, `NV_DBG_WARNINGS` × 0 — the file's surrounding convention uses `NV_DBG_ERRORS` for every `NV_DEV_PRINTF` call site, including informational lines like `"GPU serial number is %s."`. The lost-state branch immediately below uses `NV_DBG_ERRORS` for `"GPU has fallen off the bus."`. Switching only the recovery line to `NV_DBG_WARNINGS` would break the file's grep-for-incidents pattern. Project memory's recent precedent (operators rely on noticing these events) supports keeping the recovery log at the more visible severity.
- **Resolution:** deferred — keep `NV_DBG_ERRORS` to match the surrounding file convention and to ensure the recovery event is visible on production kernels where lower-severity messages may be filtered. The intent's Requirement-2 explicitly names `NV_DBG_ERRORS` so the telemetry contract is not in conflict.

### C3-gpu-lost-retry-D3 — No must-fix deltas

- **Location:** n/a
- **Change:** v1's behaviour, telemetry, and surface match the v2 intent exactly. No fork-branch follow-up commits are required.
- **Severity:** out-of-scope
- **Evidence:** Every scenario in the intent's two Requirements is satisfied by v1 as audited above. Possible improvements (D1 stylistic dead-code, D2 log-level semantics) are explicitly deferred. The retry count, delay, comparison sentinel, last-iteration sleep guard, recovery log shape, no-per-retry-logging policy, BDF prefix via `NV_DEV_PRINTF`, and no-module-parameter posture are all correctly realised in v1.
- **Resolution:** rejected — no v2 follow-up needed.

Per M2 (zero-delta sentinel from the C1 checkpoint), the
frontmatter `v1-tip-sha == v2-tip-sha ==
c589673a33729e24c5179f92c5c98dbac4886d6b` is the
machine-checkable signal that v1 already met v2 intent. The
two `nice-to-have` deltas (D1, D2) are recorded for
provenance; they do not require fork-branch commits because
their Resolutions are `deferred`.

## Done gate

- [x] `docs/patch-intents/C3-gpu-lost-retry.md` exists, lints clean, `status: reviewed`.
- [x] All must-fix deltas applied as fork-branch commits citing their delta IDs. _(N/A — zero must-fix deltas; D1 and D2 are nice-to-have with deferred Resolutions.)_
- [x] `patches/base/C3-gpu-lost-retry.patch` refreshed by `regen`. _(N/A — no fork-branch change; existing file already reflects `c589673a`.)_
- [x] `tools/validate-patchset.sh` passes (compile gate).
- [x] `bash tests/run.sh` green.
- [x] Audit-reviewer subagent approved.

## Cross-references

- Intent file: `docs/patch-intents/C3-gpu-lost-retry.md`
- Manifest row: `patches/manifest` line for `C3-gpu-lost-retry`
  (layer `base`, source `fork:c3-gpu-lost-retry`)
- Vanilla baseline:
  `src/nvidia/arch/nvalloc/unix/src/osinit.c:osHandleGpuLost`
  (vanilla 595.71.05 — single `NV_PRIV_REG_RD32` against
  `NV_PMC_BOOT_0`, immediate fall-through to the lost-state
  branch on mismatch; the comment block immediately above the
  lost-state branch flags `"This doesn't support PEX Reset
  and Recovery yet."`)
- Fork branch: `c3-gpu-lost-retry` on
  `apnex/open-gpu-kernel-modules`
- Upstream issue:
  https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979 —
  Blackwell GPU over Thunderbolt: brief PCIe link drop commits
  GPU to permanent lost state. C3 is the headline fix.
- Related reviews: [[C5-crash-safety]] (covers dead-bus reads
  on the OTHER call sites — `osGpuReadReg*` family, RPC paths
  to GSP, cleanup paths — that C3's `osHandleGpuLost`
  preflight does NOT cover; the addon A3-recovery patch
  performs the actual PEX reset and recovery once C3 or C5
  surface a genuine bus drop).
