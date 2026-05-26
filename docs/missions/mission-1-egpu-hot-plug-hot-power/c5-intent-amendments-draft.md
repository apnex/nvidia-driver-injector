# C5 intent amendments — DRAFT for review

**Status:** DRAFT 2026-05-26 — for user approval before applying to `docs/patch-intents/C5-crash-safety.md`
**Purpose:** Add the sub-requirements + scenarios + telemetry-contract entries needed to absorb P-DISC-1 (cross-layer propagation at all disconnect-detection sites) and P-DISC-2 (broad NV_ASSERT_OR_GPU_LOST family application at the 8 swept sites) into C5's scope.
**Methodology:** matches the existing C5 intent doc's Requirements / Scenarios / Scope-boundary / Telemetry-contract structure exactly. Each amendment is keyed to its insertion point in the existing doc.

---

## Amendment 1 — Frontmatter update

**Where:** lines 1-9 of `docs/patch-intents/C5-crash-safety.md`

**Existing:**
```yaml
---
id: C5-crash-safety
layer: base
source-branch: c5-crash-safety
upstream-candidacy: high
telemetry-tier: nominal
status: reviewed
related-patches: [C2-aer-internal-unmask, C3-gpu-lost-retry, C4-err-handlers-scaffold]
---
```

**Proposed change:** `status: reviewed` → `status: amended-v3-draft` (pending the v3 review work). Otherwise unchanged. `related-patches` already references C3, which is the only relevant cross-link change.

---

## Amendment 2 — Purpose update

**Where:** the "Purpose" section, line ~17 of `docs/patch-intents/C5-crash-safety.md`

**Existing Purpose (verbatim, ~25 lines):** captures the dead-bus-signal handling at MMIO paths, RPC paths, resserv cleanup paths.

**Proposed addition (appended to the existing Purpose paragraph, before the issue-979 closing sentence):**

> The driver SHALL also guarantee that the cross-layer disconnect propagation (setting both `PDB_PROP_GPU_IS_LOST` and `pci_dev_is_disconnected` together) fires from **every** disconnect-detection site in the driver, not only the `osDevReadReg032` post-read check path. The disconnect-state markers MUST be consistent across detection paths so subsequent code that consults either marker observes the same answer. The `NV_ASSERT_OR_GPU_LOST` family of macros (which accepts `NV_ERR_GPU_IS_LOST` as a benign cleanup-path status) SHALL be applied at every cleanup-path assertion site that may receive `NV_ERR_GPU_IS_LOST` from a C5-guarded RPC funnel — not only at the resserv sites originally covered. A swept population of such sites includes `kernel_graphics.c`, `fecs_event_list.c`, `kernel_falcon_tu102.c`, `kernel_gsp_tu102.c`, `vaspace_api.c`, `mem.c`, and the missed third site in `rs_server.c`.

---

## Amendment 3 — Extend Requirement 2 (MMIO short-circuit) with cross-detection propagation

**Where:** end of the "Requirement: Driver SHALL short-circuit MMIO read paths on a known-dead bus" section, after the existing "Fresh dead-bus read promotes GPU to lost state" scenario, line ~115-ish of the intent doc.

**Proposed addition (new sub-requirement + scenarios):**

### Sub-requirement (NEW): Driver SHALL propagate disconnect to BOTH markers at every detection site, not only `osDevReadReg032`

When any code path in the driver determines that the GPU is genuinely off the bus (via PMC_BOOT_0 mismatch or any equivalent positive-evidence check), the driver MUST propagate the disconnect to BOTH the RM-level marker (`PDB_PROP_GPU_IS_LOST`, set by `gpuSetDisconnectedProperties`) AND the Linux-level marker (`pci_dev_is_disconnected`, set by `os_pci_set_disconnected`) at that detection site. The two markers MUST NOT diverge — every detection site MUST set both. The `osHandleGpuLost` lost-state branch in `src/nvidia/arch/nvalloc/unix/src/osinit.c` is one such detection site; its retry-exhausted branch ALREADY calls `gpuSetDisconnectedProperties` and MUST also call `os_pci_set_disconnected(nv->handle)` for marker consistency. (The retry logic itself is owned by [[C3-gpu-lost-retry]]; the propagation line is owned by C5.)

#### Scenario: osHandleGpuLost detection path propagates to Linux marker
- **GIVEN** an attached GPU whose `PDB_PROP_GPU_IS_CONNECTED` is set at entry to `osHandleGpuLost`
- **AND** every read in C3's retry window returns a mismatched value (genuine disconnect)
- **WHEN** the lost-state branch executes (after C3's retry budget is exhausted)
- **THEN** the driver MUST call `gpuSetDisconnectedProperties(pGpu)` (already happens — pre-existing vanilla behaviour)
- **AND** the driver MUST call `os_pci_set_disconnected(nv->handle)` (NEW — this amendment adds this line)
- **AND** both markers MUST be consistent after the function returns

#### Scenario: Subsequent osDevReadReg032 calls observe consistent disconnect state
- **GIVEN** `osHandleGpuLost` has set both markers in its lost-state branch
- **WHEN** any subsequent `osDevReadReg032` call fires for that GPU
- **THEN** the `osIsGpuBusDead(pGpu)` predicate MUST return `NV_TRUE` (it already returns true for either marker independently; the propagation closes the consistency gap)
- **AND** the short-circuit MUST fire returning `NV_GPU_BUS_DEAD_VALUE_U32` without issuing the MMIO read
- **AND** Linux kernel paths consulting `pci_dev_is_disconnected()` directly MUST also observe `NV_TRUE`

#### Scenario: osDevReadReg032 detection path remains unchanged
- **GIVEN** the GPU is not yet marked lost when `osDevReadReg032` is called
- **WHEN** the MMIO read returns `NV_GPU_BUS_DEAD_VALUE_U32`
- **THEN** the existing post-read verification + propagation logic MUST run unchanged
- **AND** the resulting state MUST be identical to the osHandleGpuLost path: both markers set

**Rationale (block comment for the implementer):**

> Before this amendment, the cross-layer propagation only fired from `osDevReadReg032`'s post-read check. Once `osHandleGpuLost` set `PDB_PROP_GPU_IS_LOST` (via `gpuSetDisconnectedProperties`), `osIsGpuBusDead` would return TRUE on subsequent reads and the short-circuit would fire BEFORE the post-read check could run — so `os_pci_set_disconnected` would never be called from the osHandleGpuLost detection path. The propagation gap manifested in E07 Run 2 (2026-05-26): Linux marker stayed unset while RM marker was set, leaving the two state systems inconsistent. This sub-requirement closes the gap.

---

## Amendment 4 — Extend Requirement 3 (bound cleanup paths) with macro-family expansion

**Where:** end of the "Requirement: Driver SHALL bound diagnostic, RPC, and resserv cleanup paths against a lost GPU" section, after the existing "GSP RPC short-circuits and resource cleanup completes" scenario, line ~200-ish of the intent doc.

**Proposed addition (new sub-requirement + scenarios):**

### Sub-requirement (NEW): Driver SHALL provide the `NV_ASSERT_OR_GPU_LOST` family covering `_OR_RETURN` and `_OR_RETURN_VOID` variants

The `nv-gpu-lost.h` header SHALL provide three assertion-relaxation macros, not one, to cover the three structural variants of NV_ASSERT-family used at sites that may receive `NV_ERR_GPU_IS_LOST` from C5-guarded RPC funnels:

- `NV_ASSERT_OR_GPU_LOST(status)` — already defined; accepts `NV_OK || NV_ERR_GPU_IN_FULLCHIP_RESET || NV_ERR_GPU_IS_LOST`
- `NV_ASSERT_OR_GPU_LOST_OR_RETURN(status)` — NEW; same predicate but returns `status` on failure (mirrors `NV_ASSERT_OR_RETURN`)
- `NV_ASSERT_OR_GPU_LOST_OR_RETURN_VOID(status)` — NEW; same predicate but returns void on failure (mirrors `NV_ASSERT_OR_RETURN_VOID`)

The three macros MUST share the predicate body for consistency: an assertion site that currently accepts `NV_OK || NV_ERR_GPU_IN_FULLCHIP_RESET` MUST continue accepting those statuses, AND MUST additionally accept `NV_ERR_GPU_IS_LOST` for the cleanup-path-on-lost-GPU case.

#### Scenario: Three macros share the predicate body
- **GIVEN** the three macros are defined in `nv-gpu-lost.h`
- **WHEN** code reads any of them
- **THEN** the predicate MUST be exactly `((status) == NV_OK) || ((status) == NV_ERR_GPU_IN_FULLCHIP_RESET) || ((status) == NV_ERR_GPU_IS_LOST)`
- **AND** the macros MUST differ ONLY in their assertion-failure behaviour (assert-and-continue, assert-and-return-status, assert-and-return-void)

### Sub-requirement (NEW): Driver SHALL apply the family at every cleanup-path assertion site that may receive `NV_ERR_GPU_IS_LOST`

A site identification sweep across the source tree for the pattern `NV_ASSERT*(status == NV_OK || status == NV_ERR_GPU_IN_FULLCHIP_RESET)` finds the following sites, all in cleanup or post-RPC paths that may legitimately encounter `NV_ERR_GPU_IS_LOST`. The driver MUST convert each to the appropriate macro from the family:

| Site | Macro variant before | Macro variant after | Reason |
|---|---|---|---|
| `src/nvidia/src/kernel/gpu/gr/kernel_graphics.c:2608` (kgraphicsFreeContextBuffers, post-`kmemsysCacheOp_HAL`) | `NV_ASSERT(...)` | `NV_ASSERT_OR_GPU_LOST(status)` | Cache eviction RPC may return GPU_IS_LOST under C5's _issueRpcAndWait guard; cleanup must continue |
| `src/nvidia/src/kernel/gpu/gr/fecs_event_list.c:1623` (fecsBuffer-related post-RPC check) | `NV_ASSERT_OR_RETURN_VOID(...)` | `NV_ASSERT_OR_GPU_LOST_OR_RETURN_VOID(status)` | Same RPC-result class; teardown context |
| `src/nvidia/src/kernel/gpu/gr/fecs_event_list.c:1639` (second instance in same file) | `NV_ASSERT_OR_RETURN_VOID(...)` | `NV_ASSERT_OR_GPU_LOST_OR_RETURN_VOID(status)` | Same as above |
| `src/nvidia/src/kernel/gpu/falcon/arch/turing/kernel_falcon_tu102.c:187` (falcon teardown post-RPC) | `NV_ASSERT_OR_RETURN(..., status)` | `NV_ASSERT_OR_GPU_LOST_OR_RETURN(status)` | Returns status on failure; teardown context |
| `src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c:636` (GSP-side post-RPC check) | `NV_ASSERT(...)` | `NV_ASSERT_OR_GPU_LOST(status)` | Post-RPC class |
| `src/nvidia/src/kernel/gpu/mem_mgr/vaspace_api.c:573` (vaspace teardown post-RPC) | `NV_ASSERT(...)` | `NV_ASSERT_OR_GPU_LOST(status)` | Post-RPC class |
| `src/nvidia/src/kernel/mem_mgr/mem.c:178` (memory descriptor teardown post-RPC) | `NV_ASSERT(...)` | `NV_ASSERT_OR_GPU_LOST(status)` | Post-RPC class |
| `src/nvidia/src/libraries/resserv/src/rs_server.c:1388` (third site in rs_server.c, missed by initial C5) | `NV_ASSERT(...)` | `NV_ASSERT_OR_GPU_LOST(status)` | Post-cleanup-RPC class |

Each converted site MUST also emit a single `NV_GPU_LOST_LOG_ONCE` line guarded by `if (status == NV_ERR_GPU_IS_LOST)`, matching the pattern already established at the rs_client.c and rs_server.c sites covered by v1 C5 (line 855 of `rs_client.c`, line 272 of `rs_server.c`).

#### Scenario: A converted site receives NV_OK and the assertion is a no-op
- **GIVEN** any of the 8 converted sites is reached during normal (non-lost-GPU) operation
- **AND** the relevant RPC or status check returns `NV_OK`
- **WHEN** the assertion macro evaluates
- **THEN** the macro MUST NOT trigger assertion firing
- **AND** the function MUST proceed as it did pre-conversion (NV_OK is a valid status under both old and new macros)

#### Scenario: A converted site receives NV_ERR_GPU_IS_LOST during cleanup
- **GIVEN** the GPU is marked lost (`PDB_PROP_GPU_IS_LOST` set or `os_pci_is_disconnected` returns true)
- **AND** any of the 8 converted sites is reached during teardown
- **AND** the upstream RPC returns `NV_ERR_GPU_IS_LOST` (via `_issueRpcAndWait`'s C5 guard)
- **WHEN** the assertion macro evaluates
- **THEN** the macro MUST NOT trigger assertion firing (the new predicate accepts GPU_IS_LOST)
- **AND** the function MUST emit one log-once line acknowledging the lost-GPU status
- **AND** the function MUST continue / return per its original control flow

#### Scenario: A converted site receives an unexpected status (e.g., NV_ERR_INVALID_STATE)
- **GIVEN** any of the 8 converted sites is reached
- **AND** the upstream RPC returns a status NOT in {NV_OK, NV_ERR_GPU_IN_FULLCHIP_RESET, NV_ERR_GPU_IS_LOST}
- **WHEN** the assertion macro evaluates
- **THEN** the macro MUST trigger assertion firing (unchanged behaviour for non-lost-GPU error classes)
- **AND** the behaviour MUST be identical to the pre-conversion `NV_ASSERT*` for that status

#### Scenario: Each converted site has its own independent log-once latch
- **GIVEN** the 8 sites are converted, each with its own `NV_GPU_LOST_LOG_ONCE` call
- **WHEN** a lost-GPU teardown sequence executes that exercises multiple sites
- **THEN** each site MUST log at most once per kernel module lifetime, independently of other sites
- **AND** kernel log MUST not be flooded by repeated log lines from the same site

**Rationale (block comment for the implementer):**

> Before this amendment, C5 defined `NV_ASSERT_OR_GPU_LOST` and applied it at 2 sites (rs_client.c:855, rs_server.c:272). A swept population of sites uses the same `NV_ASSERT*((status == NV_OK) || (status == NV_ERR_GPU_IN_FULLCHIP_RESET))` pattern but was not converted. E07 Run 2 (2026-05-26) confirmed 2 of these sites (kernel_graphics.c:2608, fecs_event_list.c:1623) firing under a lost-GPU teardown sequence. The cascade caused state inconsistency that contributed to a silent host wedge requiring forced reboot. This sub-requirement applies the same relaxation at every swept site, including 6 additional sites that would fire under analogous conditions. Two new macro variants (`_OR_RETURN`, `_OR_RETURN_VOID`) are needed to cover the three structural variants in use.

---

## Amendment 5 — Scope boundary update

**Where:** the "Scope boundary" section's first bullet, line ~205 of the intent doc.

**Existing first bullet (verbatim):**

> "This patch does NOT cover the `osHandleGpuLost` preflight retry — that is [[C3-gpu-lost-retry]]'s responsibility. C3 distinguishes a glitch from a genuine disconnect at one specific call site; C5 contains the consequences at every OTHER call site once a disconnect has been declared (or once an MMIO read independently surfaces the dead-bus signature)."

**Proposed replacement:**

> "This patch does NOT cover the `osHandleGpuLost` preflight retry logic — that is [[C3-gpu-lost-retry]]'s responsibility. C3 owns the **bounded-retry** changes (the for-loop, the per-retry delay, the retry-recovered log line, the constants `NV_GPU_LOST_RETRY_COUNT` and `NV_GPU_LOST_RETRY_DELAY_US`). C5 owns the **cross-layer propagation** that runs in `osHandleGpuLost`'s lost-state branch (the single `os_pci_set_disconnected(nv->handle)` line added immediately after `gpuSetDisconnectedProperties(pGpu)`). The two patches modify the same file (`osinit.c`) but different hunks — the boundary is clean and reviewable: C3 = retry logic, C5 = cross-layer propagation. Beyond `osHandleGpuLost`, C5 contains the consequences at every OTHER call site once a disconnect has been declared (or once an MMIO read independently surfaces the dead-bus signature)."

---

## Amendment 6 — Telemetry contract — append 8 new rows + reaffirm policy

**Where:** the existing Telemetry contract table, line ~240-ish of the intent doc.

**Proposed addition (8 new rows appended to the existing table):**

| Event | Level | Format |
|---|---|---|
| `osHandleGpuLost` lost-state branch propagates Linux disconnect marker | (no new log — propagation only; the existing "GPU has fallen off the bus." line from vanilla osinit.c already records the event) | n/a |
| `kgraphicsFreeContextBuffers` post-cache-evict observes `NV_ERR_GPU_IS_LOST` | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"kgraphicsFreeContextBuffers: cache evict returned NV_ERR_GPU_IS_LOST, continuing teardown\n"` |
| `fecs_event_list.c:1623` post-RPC observes `NV_ERR_GPU_IS_LOST` | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"fecsBufferTeardown<site1>: post-RPC status NV_ERR_GPU_IS_LOST, continuing teardown\n"` |
| `fecs_event_list.c:1639` post-RPC observes `NV_ERR_GPU_IS_LOST` | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"fecsBufferTeardown<site2>: post-RPC status NV_ERR_GPU_IS_LOST, continuing teardown\n"` |
| `kernel_falcon_tu102.c:187` falcon teardown observes `NV_ERR_GPU_IS_LOST` | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"kernelFalconTeardown: post-RPC status NV_ERR_GPU_IS_LOST, returning early\n"` |
| `kernel_gsp_tu102.c:636` GSP teardown observes `NV_ERR_GPU_IS_LOST` | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"kernelGspTu102Teardown: post-RPC status NV_ERR_GPU_IS_LOST, continuing teardown\n"` |
| `vaspace_api.c:573` vaspace teardown observes `NV_ERR_GPU_IS_LOST` | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"vaspaceTeardown: post-RPC status NV_ERR_GPU_IS_LOST, continuing teardown\n"` |
| `mem.c:178` memdesc teardown observes `NV_ERR_GPU_IS_LOST` | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"memdescTeardown: post-RPC status NV_ERR_GPU_IS_LOST, continuing teardown\n"` |
| `rs_server.c:1388` third site observes `NV_ERR_GPU_IS_LOST` | `LEVEL_ERROR` (via `NV_GPU_LOST_LOG_ONCE`) | `"serverFreeResourceTreeUnderLock<site2>: clientFreeResource returned NV_ERR_GPU_IS_LOST, continuing cleanup\n"` |

*(Format strings are illustrative; final wording can match the existing C5 pattern more closely when the source is touched. The exact function-name prefix should be the actual function name at each site, looked up at conversion time.)*

**Reaffirm telemetry-tier:** still `nominal` (per the existing intent). Each new log-once latch is prove-the-path observability for a rare-but-important failure mode, identical in tier to the existing 9 latches in C5. The `telemetry-tier: nominal` frontmatter value remains correct after amendment.

---

## Amendment 7 — Provenance update

**Where:** the "Provenance" section, line ~270-ish of the intent doc.

**Existing Provenance bullets (paraphrased):** Source cluster history (P2 → C5 carve-out from M-recover), vanilla baseline citations, fork branch identifier, upstream issue link.

**Proposed addition (new bullets appended):**

> - **2026-05-26 amendment provenance:** the cross-layer propagation gap (Amendment 3) and the swept-site application gap (Amendment 4) were surfaced by MISSION-1 E07 Run 2 wedge (2026-05-26 18:08:45). Forensic record + audit chain documented at `docs/missions/mission-1-egpu-hot-plug-hot-power/`:
>   - `experiments/E07-cable-replug-drain-first.md` — Run 2 forensic evidence (Xid 79+154 cascade, kernel call sites firing assertions, host silent wedge ~3 min post-yank)
>   - `nvidia-driver-surprise-removal-audit.md` — initial driver-side attribution + gap identification
>   - `userspace-reset-recover-survey.md` — confirms userspace primitives can't substitute for the driver fix
>   - `c3-c5-integration-audit.md` — validates patch placement (P-DISC-1/2 fit C5, not C3) + comprehensive 8-site sweep
> - **Amendment v3 site sweep methodology:** `grep -rn 'NV_ASSERT.*== NV_OK.*NV_ERR_GPU_IN_FULLCHIP_RESET' --include='*.c' --include='*.h'` across the fork branch `c5-crash-safety` tip, 2026-05-26. 8 sites identified; 2 confirmed-fired in E07 Run 2 forensic record, 6 speculative-but-same-pattern. All 8 converted by this amendment for completeness.
> - **Macro-variant expansion provenance:** the 3 structural variants (`NV_ASSERT`, `NV_ASSERT_OR_RETURN`, `NV_ASSERT_OR_RETURN_VOID`) were observed in the swept site set. The 2 new macros (`NV_ASSERT_OR_GPU_LOST_OR_RETURN`, `NV_ASSERT_OR_GPU_LOST_OR_RETURN_VOID`) mirror the existing kernel-side conventions; their predicate body is shared with `NV_ASSERT_OR_GPU_LOST` for consistency.

---

## Companion: review v3 deltas to capture in `docs/patch-reviews/C5-crash-safety.md`

The patch-review doc needs a parallel v3 section. Following the v1→v2 delta tradition from `C3-gpu-lost-retry.md`:

### Anticipated v2 → v3 deltas

- **C5-crash-safety-D3** — Cross-layer propagation at osHandleGpuLost lost-state branch. **Severity:** must-fix. **Resolution:** applied via Amendment 3 to the intent + corresponding fork-branch commit.
- **C5-crash-safety-D4** — Macro family expansion: 2 new macros + 8 site conversions. **Severity:** must-fix. **Resolution:** applied via Amendment 4 to the intent + corresponding fork-branch commits per the file map in Amendment 4's table.
- **C5-crash-safety-D5** — Patch-boundary clarification in Scope boundary for the C3/C5 split in osinit.c. **Severity:** must-fix (documentation). **Resolution:** applied via Amendment 5.

The review-doc structure (Rationale → v1/v2 audit → Design choices → Deltas → Done gate → Cross-references) carries forward unchanged; a v3 section appends to the existing.

---

## What needs user approval before applying

| # | Decision | Default proposed |
|---|---|---|
| 1 | Apply amendments as proposed to `docs/patch-intents/C5-crash-safety.md`? | YES — apply verbatim |
| 2 | Update `docs/patch-reviews/C5-crash-safety.md` with v3 deltas? | YES — write v3 section as outlined |
| 3 | Update `docs/patch-improvements/C5-crash-safety.md` to capture the lineage? | YES — add a row for the v3 improvement cycle |
| 4 | Frontmatter `status: reviewed → amended-v3-draft` while doc work is in progress, flip to `reviewed` when v3 review work is also done? | YES — standard pattern |
| 5 | New macro names — confirm `NV_ASSERT_OR_GPU_LOST_OR_RETURN` / `_OR_RETURN_VOID` or prefer shorter? | proposed |
| 6 | Log message text — should follow existing C5 site format closely or rewrite? | follow existing pattern |

## What happens after approval

1. Apply all 7 amendments to `docs/patch-intents/C5-crash-safety.md` (single commit)
2. Add v3 deltas section to `docs/patch-reviews/C5-crash-safety.md` (separate commit)
3. Update improvements doc lineage (separate commit, optional same time)
4. **THEN:** fork-branch implementation work (separate session — apply the 2 new macros + 8 site conversions + 1 osinit.c line)
5. Regen `patches/base/C5-crash-safety.patch`
6. validate-patchset, container rebuild, deploy, verify

The intent + review docs MUST land BEFORE the fork-branch work, so the code follows the spec rather than the other way around (per user's "upstream-PR-grade documentation rigor" requirement).

## Cross-references

- `c3-c5-integration-audit.md` — the audit that produced these amendments
- `nvidia-driver-surprise-removal-audit.md` — the driver-side root-cause attribution
- `experiments/E07-cable-replug-drain-first.md` — the empirical event chain
- Existing C5 docs: `docs/patch-intents/C5-crash-safety.md`, `docs/patch-reviews/C5-crash-safety.md`, `docs/patch-improvements/C5-crash-safety.md`
- C3 docs (referenced for boundary clarification): `docs/patch-intents/C3-gpu-lost-retry.md`, `docs/patch-reviews/C3-gpu-lost-retry.md`
