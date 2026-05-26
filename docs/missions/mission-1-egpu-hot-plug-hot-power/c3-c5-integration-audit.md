# C3 + C5 integration audit for P-DISC-1 / P-DISC-2

**Status:** v1 2026-05-26
**Purpose:** Validate whether the disconnect-propagation and assertion-relaxation extensions surfaced by the surprise-removal audit fit cleanly into C3 or C5. Identify co-adjustments. Confirm telemetry posture. Check upstream-PR-grade documentation rigor.
**Scope:** Read C3 + C5 patch files in full, their `docs/patch-intents/`, `docs/patch-reviews/`, `docs/patch-improvements/` triples, AND the kernel-open + RM sources they touch. Sweep the entire source tree for the assertion pattern E07 Run 2 surfaced.
**Why:** the user pushed back correctly — "is it literally a single line change?" — and asked for co-adjustment opportunities + telemetry posture review + upstream-PR-rigor confirmation before writing patches.

## Section A — C3 scope is rigorously narrow; the additions DO NOT fit C3

C3's patch-intent has an explicit "Scope boundary" section (197 lines, rigorous prose-grade — upstream-PR ready). Key exclusions:

> "This patch covers ONLY the `osHandleGpuLost` preflight in `src/nvidia/arch/nvalloc/unix/src/osinit.c`. Dead-bus reads from other call sites... are covered by [[C5-crash-safety]] and the addon recovery patches."
>
> "This patch does NOT alter the lost-state branch's behaviour (Xid, `gpuSetDisconnectedProperties`, surprise-removal flag, `RmLogGpuCrash`, `DBG_BREAKPOINT`). It only changes the condition under which the lost-state branch is entered."

Adding `os_pci_set_disconnected(nv->handle)` to the lost-state branch is **exactly** the kind of thing C3 says it doesn't do. The exclusion is deliberate — it preserves C3 as a single-purpose ~38-line upstream-PR candidate for issue #979.

**Conclusion: P-DISC-1 does NOT fit into C3.** Anything that extends osHandleGpuLost's lost-state branch must go elsewhere.

## Section B — C5 is already much more comprehensive than originally noted

The earlier surprise-removal audit captured C5 as "added `os_pci_set_disconnected/is_disconnected` APIs + `NV_ASSERT_OR_GPU_LOST` macro." That was incomplete. The full C5 (from reading the patch + intent doc) does:

| C5 component | What it does |
|---|---|
| Header `nv-gpu-lost.h` | Defines `NV_GPU_BUS_DEAD_VALUE_U{8,16,32}`, `NV_GPU_LOST_LOG_ONCE`, `NV_ASSERT_OR_GPU_LOST` — de-branded upstream-friendly infrastructure |
| os-pci.c additions | `os_pci_is_disconnected`, `os_pci_set_disconnected` — wrap Linux's `pci_dev_is_disconnected` / `pci_channel_io_perm_failure` |
| `osDevReadReg{8,16,32}` guards | Short-circuit via `osIsGpuBusDead(pGpu)` predicate (checks both RM marker + Linux marker) before issuing MMIO read |
| `osDevReadReg032` post-read | **When MMIO returns 0xFFFFFFFF, verify via PMC_BOOT_0; if confirmed dead, call BOTH `gpuSetDisconnectedProperties` AND `os_pci_set_disconnected`** — i.e., the cross-layer propagation P-DISC-1 wants, but ONLY in this detection path |
| `_issueRpcAndWait` guard | Short-circuits when `PDB_PROP_GPU_IS_LOST` set; returns `NV_ERR_GPU_IS_LOST` |
| `rpcRmApiFree_GSP` guard | Returns `NV_OK` when GPU lost (so cleanup completes) |
| `rcdbAddRmGpuDump` guard | Short-circuits when GPU lost; skips engine-callback iteration |
| `_rcdbAddRmGpuDumpCallback` | Removes `NV_ASSERT(status == NV_OK)`; logs error instead |
| `nvdDumpAllEngines_IMPL` | `break`s engine loop when GPU lost/inaccessible |
| `clientFreeResource_IMPL` | **Already uses `NV_ASSERT_OR_GPU_LOST(status)`** + log-once message |
| `serverFreeResourceTreeUnderLock` | **Already uses `NV_ASSERT_OR_GPU_LOST(status)`** + log-once message |

**C5 covers a LOT.** And it DID fire correctly in E07 Run 2 (the log lines "GPU lost, skipping crash dump", "GPU lost, returning NV_OK", "GPU lost, returning NV_ERR_GPU_IS_LOST" were all visible in journalctl).

## Section C — the specific gap, refined

What FIRED correctly in C5 during E07 Run 2:
- `_issueRpcAndWait` returned `NV_ERR_GPU_IS_LOST` (logged)
- `rpcRmApiFree_GSP` returned `NV_OK` (logged)
- `rcdbAddRmGpuDump` short-circuited (logged "GPU lost, skipping crash dump")

What FAILED:
- The CALLERS of the RPC functions received `NV_ERR_GPU_IS_LOST` and then **asserted** on it because they use `NV_ASSERT(...)` accepting only `NV_OK | NV_ERR_GPU_IN_FULLCHIP_RESET`.

So **C5 made the RPC paths return cleanly. The gap is that the CALLERS of those RPCs are scattered across the codebase using NV_ASSERT macros that don't accept the lost-status.**

C5's existing solution: `NV_ASSERT_OR_GPU_LOST(status)`. Used at 2 sites. **Needs broader application** to all assertion sites that may receive `NV_ERR_GPU_IS_LOST` from C5-guarded RPC paths.

## Section D — comprehensive site sweep

A grep across the fork branch for the exact assertion pattern E07 Run 2 surfaced finds **8 call sites** in 7 files that need attention:

| # | File:line | Macro variant | Status |
|---|---|---|---|
| 1 | `src/nvidia/src/kernel/gpu/gr/kernel_graphics.c:2608` | `NV_ASSERT(...)` | ✓ **confirmed fired E07 Run 2** |
| 2 | `src/nvidia/src/kernel/gpu/gr/fecs_event_list.c:1623` | `NV_ASSERT_OR_RETURN_VOID(...)` | ✓ **confirmed fired E07 Run 2** |
| 3 | `src/nvidia/src/kernel/gpu/gr/fecs_event_list.c:1639` | `NV_ASSERT_OR_RETURN_VOID(...)` | second instance in same file |
| 4 | `src/nvidia/src/kernel/gpu/falcon/arch/turing/kernel_falcon_tu102.c:187` | `NV_ASSERT_OR_RETURN(..., status)` | speculative — same pattern |
| 5 | `src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c:636` | `NV_ASSERT(...)` | speculative — same pattern |
| 6 | `src/nvidia/src/kernel/gpu/mem_mgr/vaspace_api.c:573` | `NV_ASSERT(...)` | speculative — same pattern |
| 7 | `src/nvidia/src/kernel/mem_mgr/mem.c:178` | `NV_ASSERT(...)` | speculative — same pattern |
| 8 | `src/nvidia/src/libraries/resserv/src/rs_server.c:1388` | `NV_ASSERT(...)` | a third site in rs_server.c, missed by the existing C5 application |

Of these:
- **2 are confirmed-fired** (1 + 2) in E07 Run 2
- **6 are speculative** (same pattern; would fire under similar conditions)

Also note that `gpu_user_shared_data.c:248` (the `_kccuUnmapAndFreeMemory`-related site that E07 also showed) uses `NV_CHECK_OK` not `NV_ASSERT`. Different macro family. `NV_CHECK_OK` doesn't crash; it logs and propagates. Its behavior under `NV_ERR_GPU_IS_LOST` is "log + return error" — that's already acceptable. So this site does NOT need conversion. The cascade in E07 Run 2 was driven by the 2 confirmed-fired NV_ASSERT sites.

## Section E — macro variants needed

The 8 sites use **three different macro variants**:

| Macro | Sites using it | New variant needed |
|---|---|---|
| `NV_ASSERT(condition)` | 4 sites (1, 5, 6, 7, 8) | Already covered by `NV_ASSERT_OR_GPU_LOST(status)` |
| `NV_ASSERT_OR_RETURN_VOID(condition)` | 2 sites (2, 3) | **NEW: `NV_ASSERT_OR_GPU_LOST_OR_RETURN_VOID(status)`** needed |
| `NV_ASSERT_OR_RETURN(condition, status)` | 1 site (4) | **NEW: `NV_ASSERT_OR_GPU_LOST_OR_RETURN(status)`** needed |

So the extension to `nv-gpu-lost.h` is NOT just "apply the existing macro" — it requires **2 new macro variants** to handle the `_OR_RETURN_VOID` and `_OR_RETURN` cases (which return early from their enclosing function on failure).

This pushes the patch from "literally a single line change" to a moderate-but-still-small change:
- 2 new macros in `nv-gpu-lost.h` (~10 lines)
- 8 site conversions across 7 files (~5-10 lines each, including log-once messages following C5's pattern)
- (Optional) 1 line in osinit.c for P-DISC-1
- **Total: ~50-70 lines added/modified across 8 files**

Not "single line" — but small in absolute terms, with each change being individually trivial.

## Section F — co-adjustment opportunities

The audit identified two co-adjustments that strengthen the patch as a whole:

### Co-adjustment 1: P-DISC-1 belongs in C5, not as a separate orphan

C5's intent says: "C5 contains the consequences at every OTHER call site once a disconnect has been declared (or once an MMIO read independently surfaces the dead-bus signature)."

C5's existing `osDevReadReg032` post-read check IS where C5 propagates the disconnect to both layers. The gap is that **once `PDB_PROP_GPU_IS_LOST` is set by ANY path (including C3's osHandleGpuLost), C5's `osIsGpuBusDead` short-circuit fires for subsequent reads — the post-read check NEVER runs again, so `os_pci_set_disconnected` never gets called from this path.**

The ordering problem:

```
Path 1: osHandleGpuLost detects loss first
  → gpuSetDisconnectedProperties(pGpu)          [sets PDB_PROP_GPU_IS_LOST]
  → returns
  → subsequent osDevReadReg032 calls fire
  → osIsGpuBusDead() returns TRUE              [PDB_PROP_GPU_IS_LOST is set]
  → short-circuit: return NV_GPU_BUS_DEAD_VALUE_U32
  → post-read check NEVER reached
  → os_pci_set_disconnected() NEVER called
  → Linux marker stays unset

Path 2: osDevReadReg032 detects loss first
  → MMIO returns NV_GPU_BUS_DEAD_VALUE_U32
  → PDB_PROP_GPU_IS_LOST not yet set, post-read check runs
  → verify via PMC_BOOT_0 → confirmed dead
  → gpuSetDisconnectedProperties + os_pci_set_disconnected (BOTH set)
  → markers consistent
```

In E07 Run 2, Path 1 was the actual path. So Linux marker was never set.

**Co-adjustment:** add `os_pci_set_disconnected(nv->handle)` to osHandleGpuLost's lost-state branch (or a small helper that osHandleGpuLost calls). This belongs in C5 (cross-layer propagation), not C3 (preflight-only). C5's intent already covers Path 2 propagation via `osDevReadReg032`'s post-read check; the co-adjustment ensures BOTH detection paths propagate, not just one.

### Co-adjustment 2: comprehensive site sweep finds 8 sites, not 3

The original P-DISC-2 targeted only the sites observed firing in E07 Run 2 (kernel_graphics.c:2608, fecs_event_list.c:1623). The broad sweep found 8 sites with the same pattern. Converting all 8 (with the 2 new macro variants for the `_OR_RETURN*` cases) is a more complete and upstream-PR-friendly approach than converting only the 3 observed ones.

Reasoning: "we only convert sites we've seen fire" is less robust than "we convert all sites that COULD fire under the same conditions, since the conditions can recur." The latter is the framing an upstream reviewer would prefer.

## Section G — telemetry posture

C5's existing telemetry pattern: `NV_GPU_LOST_LOG_ONCE(level, "msg\n")` — function-scope static latch, one log line per call site per kernel module lifetime.

For the new 8 sites, **the existing telemetry pattern applies unchanged**. Each gets its own log-once latch (the function-scope-static design means each call site gets its own independent latch automatically). No new telemetry tier, no new infrastructure, no policy change.

C5's intent telemetry contract says: "at most one log-once line per call site per kernel module lifetime" — that's exactly what the extension inherits. The 8 new conversions add 8 new latches, all following the existing contract.

So:
- ✓ Telemetry stance is unchanged
- ✓ Existing log-once macro covers the new sites
- ✓ No new tier or policy needed
- ✓ "Minimal but present telemetry for this kind of failure to surface" is already satisfied

## Section H — upstream-PR-grade documentation review

### C3 docs (intent + review + improvement)

**Quality assessment: high**.
- `patch-intents/C3-gpu-lost-retry.md` (~210 lines) — has frontmatter, Purpose, Requirements with structured Scenarios (Given/When/Then), Scope boundary, Telemetry contract, Provenance
- `patch-reviews/C3-gpu-lost-retry.md` — Rationale, v1 audit (strengths, weaknesses, surprises), Design choices section with multiple alternative-analysis bullets, v1→v2 deltas, Done gate, Cross-references
- `patch-improvements/C3-gpu-lost-retry.md` exists (not read in this audit, but consistent with the schema)

C3 is upstream-PR ready as-is. No changes needed to C3.

### C5 docs (intent + review + improvement)

Same shape and depth as C3. Quality: high.

C5's intent says: "exposes the de-branded primitives... as reusable infrastructure that upstream consumers and the addon recovery stack can build on." This sentence ENVISIONS the kind of extension P-DISC-2 represents — additional consumers of the macros.

**For the extension (P-DISC-1 + P-DISC-2) to be upstream-PR-grade, C5's intent + review docs need to be amended** with:
- New sub-requirements covering: (a) propagation from osHandleGpuLost's detection path, (b) application of `NV_ASSERT_OR_GPU_LOST` at the 8 swept sites, (c) the 2 new macro variants
- New scenarios for each sub-requirement (Given/When/Then format)
- Updated Telemetry contract section noting the additional 8 log-once latches
- New review document v2 noting the v1→v2 deltas

The work to update the docs is **comparable in size to the code work** — maybe ~100-150 lines of structured prose. Not trivial, but well within the schema's pattern.

## Section I — answer to the user's direct questions

| Question | Answer |
|---|---|
| Can we authoritatively audit C3 + C5 patches and validate "perfect" inclusion? | YES — audit done. **P-DISC-1 fits cleanly into C5 (cross-layer propagation extension), NOT into C3.** **P-DISC-2 fits into C5 (extending NV_ASSERT_OR_GPU_LOST application), but requires 2 new macro variants to cover the _OR_RETURN family.** |
| Any co-adjustments from the aggregate surface? | YES — TWO. (1) P-DISC-1 belongs in C5, not C3 (the surprise-removal audit's original framing was wrong). (2) Comprehensive sweep finds 8 sites, not 3; converting all 8 is more upstream-PR-friendly than only the observed ones. |
| Is it literally a single-line change? | NO. The complete extension is: 2 new macros in nv-gpu-lost.h (~10 lines) + 8 site conversions across 7 files (~5-10 lines each including log-once messages) + 1 line in osinit.c for P-DISC-1. Total: ~50-70 lines across 8 files. Each change is individually trivial. |
| Does it change our "minimal but present telemetry" stance? | NO. C5's existing `NV_GPU_LOST_LOG_ONCE` pattern covers all new sites unchanged. Each new site gets an independent function-scope-static latch. Existing telemetry contract carries forward. |
| Does our existing logging cover this failure to surface? | PARTIALLY. The existing logging covers the C5-guarded paths (rcdbAddRmGpuDump, _issueRpcAndWait, rpcRmApiFree_GSP, etc.) which all fired correctly in E07 Run 2. The 8 NEW conversions need their own log-once messages following C5's pattern (one per site). The pattern is already established; just needs application at the new sites. |
| Upstream-PR-grade documentation rigor — covered? | C3 and C5 docs are already at upstream-PR rigor (Purpose, Requirements with Scenarios, Scope boundary, Telemetry contract, Provenance, multi-section reviews with strengths/weaknesses/design-choices). The EXTENSION (P-DISC-1/2 work) needs C5's intent + review docs amended with new sub-requirements + scenarios + delta notes. ~100-150 lines of structured prose, comparable in size to the code work. |
| Will writing these patches improve continued testing including BAR1 recovery? | **YES. Critically yes.** With these patches: cable yank → orderly tear-down (no assertion cascade, no host wedge) → broken-BAR1 state safely reproducible → **unblocks ALL Phase 2.1/2.2 experiments** (E02, E10, E12, E13, E14, E04, E15, E03) AND **unblocks bpftrace instrumentation work** for E27 patch design (the BAR1 fix). The wedge fix is a literal prerequisite for the BAR1 work moving forward — that's the leverage. |

## Section J — net recommendation

**Extend C5 (do not modify C3).** Specifically:

### Source code changes (fork branch `c5-crash-safety`)

1. **Add 2 macros** to `src/nvidia/inc/kernel/gpu/nv-gpu-lost.h`:
   ```c
   #define NV_ASSERT_OR_GPU_LOST_OR_RETURN(status)                                \
       NV_ASSERT_OR_RETURN(((status) == NV_OK) ||                                  \
                           ((status) == NV_ERR_GPU_IN_FULLCHIP_RESET) ||           \
                           ((status) == NV_ERR_GPU_IS_LOST), status)

   #define NV_ASSERT_OR_GPU_LOST_OR_RETURN_VOID(status)                            \
       NV_ASSERT_OR_RETURN_VOID(((status) == NV_OK) ||                             \
                                ((status) == NV_ERR_GPU_IN_FULLCHIP_RESET) ||      \
                                ((status) == NV_ERR_GPU_IS_LOST))
   ```

2. **Add `os_pci_set_disconnected` call** in `src/nvidia/arch/nvalloc/unix/src/osinit.c::osHandleGpuLost`, in the lost-state branch immediately after `gpuSetDisconnectedProperties(pGpu)`. (One line.) Note: this is in osinit.c which C3 currently owns the diff for — coordination needed so the patch boundary stays clean.

3. **Convert 8 sites** to the appropriate macro variant, each with a log-once message:
   - `kernel_graphics.c:2608` — `NV_ASSERT` → `NV_ASSERT_OR_GPU_LOST` + log-once
   - `fecs_event_list.c:1623, 1639` — `NV_ASSERT_OR_RETURN_VOID` → `NV_ASSERT_OR_GPU_LOST_OR_RETURN_VOID` + log-once
   - `kernel_falcon_tu102.c:187` — `NV_ASSERT_OR_RETURN` → `NV_ASSERT_OR_GPU_LOST_OR_RETURN` + log-once
   - `kernel_gsp_tu102.c:636` — `NV_ASSERT` → `NV_ASSERT_OR_GPU_LOST` + log-once
   - `vaspace_api.c:573` — `NV_ASSERT` → `NV_ASSERT_OR_GPU_LOST` + log-once
   - `mem.c:178` — `NV_ASSERT` → `NV_ASSERT_OR_GPU_LOST` + log-once
   - `rs_server.c:1388` — `NV_ASSERT` → `NV_ASSERT_OR_GPU_LOST` + log-once

### Documentation changes (in this repo)

4. **Amend `docs/patch-intents/C5-crash-safety.md`** with:
   - New sub-requirement: "Driver SHALL propagate disconnect to both RM-level and Linux-level markers at every detection site, not only the osDevReadReg032 post-read check path"
   - New scenarios for that sub-requirement
   - New sub-requirement: "Driver SHALL relax the NV_ASSERT family at every cleanup-path assertion site that may receive `NV_ERR_GPU_IS_LOST` from a C5-guarded RPC path, via the `NV_ASSERT_OR_GPU_LOST(_OR_RETURN[_VOID])` macro family"
   - Enumerated list of the 8 sites with file:line citations
   - Updated Telemetry contract section noting the 8 new log-once latches (each one line of contract)

5. **Add `docs/patch-reviews/C5-crash-safety.md` v3 section** noting:
   - v2 → v3 deltas (the extension surfaced by mission-1 E07 Run 2 wedge)
   - Evidence chain: E07 Run 2 forensic record → surprise-removal audit → integration audit → this extension
   - Design choices for the 2 new macro variants
   - Site sweep methodology + how the 8 sites were identified

6. **Regen `patches/base/C5-crash-safety.patch`** via `tools/regen-base-patches.sh` after the fork-branch changes.

### Estimated effort

- Source code changes: ~1 hour (concentrated, mostly mechanical)
- Documentation changes: ~1.5 hours (structured prose matching the existing rigor)
- Validation: `tools/validate-patchset.sh` + container rebuild + container roll: ~30 min
- **Total: ~3 hours of focused work, no reboots needed during fork-branch + doc work, ONE reboot at end to deploy + test**

### Sequencing within the broader mission

1. This integration audit (done — current commit)
2. Fork-branch changes + doc updates + regen + validate
3. Container rebuild as aorus.16 (driver version bump too, since the patched module changes)
4. k3s containerd import + pod roll
5. Reboot to load aorus.16 module
6. **Then:** retry the cable-yank experiment (formerly E07/E08 wedging) — should be wedge-free now → broken-BAR1 reproducible cleanly → Phase 2.1/2.2 unblocked

## Cross-references

- `nvidia-driver-surprise-removal-audit.md` — original surprise-removal attribution (this audit refines the patch placement framing)
- `userspace-reset-recover-survey.md` — confirms userspace primitives can't replace the driver fix
- `pci-cmdline-audit.md` — companion BAR1 audit (separable problem; this fix unblocks BAR1 testing)
- `experiments/E07-cable-replug-drain-first.md` — Run 2 evidence base
- C3 docs: `docs/patch-intents/C3-gpu-lost-retry.md`, `docs/patch-reviews/C3-gpu-lost-retry.md`
- C5 docs: `docs/patch-intents/C5-crash-safety.md`, `docs/patch-reviews/C5-crash-safety.md`, `docs/patch-improvements/C5-crash-safety.md`
- Fork branches affected: `c5-crash-safety` (a3-recovery and downstream branches will rebase against the updated tip)
