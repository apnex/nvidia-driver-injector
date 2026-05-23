---
id: C3-gpu-lost-retry
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: c589673a33729e24c5179f92c5c98dbac4886d6b
v2-tip-sha: c589673a33729e24c5179f92c5c98dbac4886d6b
status: accepted
intent-updates: []
---

# C3-gpu-lost-retry — improvement triage

## Triangulation sources

- **Vanilla NVIDIA 595.71.05:** `src/nvidia/arch/nvalloc/unix/src/osinit.c:osHandleGpuLost` (single `NV_PRIV_REG_RD32(NV_PMC_BOOT_0)` then fall-through to lost-state branch on mismatch).
- **v2 intent:** `/root/nvidia-driver-injector/docs/patch-intents/C3-gpu-lost-retry.md` (two Requirements: bounded retry budget + log-once-on-recovery; four scenarios on Requirement 1; three scenarios on Requirement 2).
- **v2 review:** `/root/nvidia-driver-injector/docs/patch-reviews/C3-gpu-lost-retry.md` (zero must-fix deltas; D1 stylistic dead-code and D2 log-level both `nice-to-have` with deferred Resolutions).
- **Fork branch tip (v1 == v2):** `c589673a33729e24c5179f92c5c98dbac4886d6b` on `apnex/open-gpu-kernel-modules` branch `c3-gpu-lost-retry`.
- **aorus-5090 ancestor patch:** `/root/aorus-5090-egpu/patches/0001-osHandleGpuLost-retry-on-transient-pcie-failure.patch` (the original Lever I implementation, 2026-05-03).
- **aorus-5090 docs:**
  - `/root/aorus-5090-egpu/docs/lever-catalog.md` §"Lever I — osHandleGpuLost retry on transient PCIe failure" (lines 178-206): class + status + mechanism + code surface.
  - `/root/aorus-5090-egpu/docs/source-review-notes.md` §"Pass 7: Lever I patch surface (full implementation, 2026-05-03 late)" (lines 993-1198): implementation-grade documentation including parameter-choice justifications.
  - `/root/aorus-5090-egpu/docs/reliability-hypothesis-ledger.md` §H14 (lines 226-254) and §H16 (lines 193-209): empirical PMC_BOOT_0 transient values observed in the field.
  - `/root/aorus-5090-egpu/docs/architecture-and-modularity.md` §"L1 — NVIDIA open KMD fork" (lines 64-100): sovereignty justification for Lever I living in the fork.
- **Community-signal entries:** `/root/nvidia-driver-injector/docs/patch-improvements/_community-signal.md` §"Bus-loss / GPU-lost class" — #916 (broader applicability beyond Blackwell/eGPU) and #1151 (symptom-adjacent only). Methodology guardrail from Task 0: TOSUKUi is **not** tagged for C3.

## v1 archaeology

What the aorus-5090 mining surfaced about Lever I (C3's direct ancestor):

- **Original design intent.** Lever I is classified as a **Recovery** lever at the **L1** sovereign layer (`docs/lever-catalog.md:179-181`). The justification for L1 is "hot path inside `osHandleGpuLost`; touches NV-internal retry logic" (`docs/architecture-and-modularity.md:86`). The lever was the *cheapest first move* in the recovery family — "Lever I remains the most promising not-yet-tested lever … in `osHandleGpuLost`" (`docs/source-review-notes.md:787-790`).
- **Constraint discovered — why 100µs delay.** `docs/source-review-notes.md:1092-1096` documents the choice: "matches the cadence used by other polling loops in this driver. Existing precedent: `kbifPollBarFirewallDisengage_GB202` in `kernel_bif_gb202.c:327` uses `osDelayUs(100)` between attempts of a similar BAR-firewall poll. `thread_state.c:444` and `gpu_timeout.c:382` also use 100 µs as a polling tick." The 100µs constant is **not arbitrary** — it is the established NV polling tick for sub-millisecond MMIO waits.
- **Constraint discovered — why 10 iterations.** `docs/source-review-notes.md:1097-1103`: "gives a 1 ms window without going so long that we add meaningful latency to a real disconnect. Empirically, TB retimer drops, link power-state transitions, and LTR re-negotiation events are sub-ms phenomena. Issue #979 reporters' 'unicorn boot' patterns (jciolek comment 14) imply the trigger is near-instantaneous — within ms of the first PCIe transaction the GPU may recover or fail permanently. 1 ms straddles the recoverable window." The author also documents the **escape hatch** (`docs/source-review-notes.md:1104-1107`): "What if 1 ms isn't enough? Bump `N_RETRIES` to e.g. 50 (5 ms). … If 5 ms doesn't catch it, the trigger likely isn't a TB transient at all."
- **Constraint discovered — empirical transient values observed.** The reliability ledger captures field readings beyond the canonical `0xFFFFFFFF` electrical-dead signature: `docs/reliability-hypothesis-ledger.md:232` "At post-rmInit-FAIL site of the FIRST failed attempt: PMC_BOOT_0 reads 0 (not 0xFFFFFFFF — bus is electrically alive but the register is literally zero). At every subsequent read site (including post-rmInit-FAIL of retries): PMC_BOOT_0 = 0x1b2000a1 (normal value). The bus enters and exits a transient state during the first GSP boot attempt." This vindicates v1's broader comparison (`pmc_boot_0 != nvp->pmc_boot_0`) over a narrower `== 0xFFFFFFFF` check — the broader test catches the empirically-observed `0x00000000` transient as well.
- **Alternatives considered + rejected.** `docs/source-review-notes.md:1124-1143`: the author considered patching `gpuVerifyExistence_IMPL` (`gpu_access.c:1215-1233`) and `gpuSanityCheckRegRead_IMPL` (`gpu_access.c:1245-1320`) instead of / in addition to `osHandleGpuLost`. Decision was **patch only `osHandleGpuLost`** because `gpuVerifyExistence_IMPL` already has a 1-retry wrapping around its `osHandleGpuLost` call site, giving an effective 11+1 = 12 attempts; `gpuSanityCheckRegRead_IMPL` similarly calls into `osHandleGpuLost`. "Patching only `osHandleGpuLost` keeps the surface minimal while covering all the read-failure entry points." This is the duty-boundary rationale.
- **Alternatives considered + rejected — log-level choice.** `docs/source-review-notes.md:1109-1122` explicitly considers `NV_DBG_WARNINGS` vs `NV_DBG_ERRORS` and explicitly defers the warning level as cosmetic: "A future tuning: bump to `NV_DBG_WARNINGS` if we want to differentiate the catch message from 'real' errors. Cosmetic." This is the **same disposition** sub-cycle 2 captured as D2 — the aorus author already triaged this as cosmetic-defer 19 days earlier.
- **Alternatives considered + rejected — fall-through behaviour.** `docs/source-review-notes.md:1145-1159`: leaving the existing `if (pmc_boot_0 != nvp->pmc_boot_0)` block unchanged on fall-through is **deliberate**: "On a real GPU disconnect (eGPU unplugged), retries will all fail and the original code path runs — preserving the existing Xid 79 emit, channel notification, crash-dump attempt, etc. This means Lever I does not break the disconnect signal path." Sub-cycle 2's D1 ("the post-loop `if` is dead code") therefore inherits a documented *upstream-diff-minimisation rationale* from the aorus archaeology, not just project-internal preference.
- **Forgotten / latent invariant — `nvp->pmc_boot_0` lifecycle.** The retry sentinel `nvp->pmc_boot_0` is captured at probe in `RmInitPrivateState` and explicitly preserved across `RmClearPrivateState` (the v2 review surfaced this at lines 210-216). The v2 intent's Scope boundary already names this: "This patch does NOT modify the `nvp->pmc_boot_0` capture site in `RmInitPrivateState` / `RmClearPrivateState` — the stored chip identifier and its lifecycle are unchanged" (intent lines 160-162). Archaeology corroborates the invariant but does not surface anything the intent does not already capture.
- **Forgotten / latent constraint — atomic-context safety.** `osDelayUs(100)` resolves to `nv_sleep_us(100)` which uses `udelay()` for sub-millisecond delays (busy-wait, not `msleep`), so the retry is safe to call from atomic contexts including interrupt handlers. `nv_sleep_us` explicitly guards `nv_in_hardirq() && (us > NV_MAX_ISR_DELAY_US)` and 100 µs sits well under that threshold. This is captured in the v2 review (lines 137-142) but is implicit (not explicit) in the v2 intent. The intent says "below one millisecond" without grounding the safety claim — could be lifted, but the v2 review already names the atomic-context safety and the constraint is invariant across all call sites. **Not a finding for v3.**

## Improvements considered

### C3-gpu-lost-retry-I1 — Remove provably-dead post-loop `if (pmc_boot_0 != nvp->pmc_boot_0)`

- **Lens:** quality (re-examination of v2's D1)
- **Current state:** v1 retains the vanilla `if (pmc_boot_0 != nvp->pmc_boot_0) { ...lost-state... }` immediately after the new retry loop. Control can only fall through the for-loop without an early `return NV_OK` when every iteration's read mismatched the stored chip identifier, so the conditional is provably always true (`src/nvidia/arch/nvalloc/unix/src/osinit.c:396` in the patched source).
- **Proposed state:** Replace the always-true conditional with a plain block (or drop the wrapping `if` and let the lost-state statements run unconditionally).
- **Value:** Removes a stylistic redundancy that a careful reader will pause on.
- **Cost:** Diff-surface against vanilla expands from "add a for-loop" to "add a for-loop AND restructure the lost-state branch." Upstream-PR reviewer cognitive cost increases. Compiler likely already elides the always-true comparison, so no runtime cost recovered.
- **Verification mode:** A (code-reading; the compiler-elision claim is verifiable by reading the produced assembly but not necessary for triage).
- **Intent impact:** none.
- **Triage decision:** reject (re-defer).
- **Resolution:** rejected — the aorus archaeology (`docs/source-review-notes.md:1145-1159`) and the v2 review concur that preserving the original `if` shape minimises the diff against vanilla, which matters for the upstream PR posture of this `upstream-candidacy: high` patch. The redundancy is harmless (compiler elides it). Sub-cycle 2's D1 disposition stands; the deeper archaeology only strengthens the upstream-diff-minimisation rationale.

### C3-gpu-lost-retry-I2 — Switch recovery log level from `NV_DBG_ERRORS` to `NV_DBG_WARNINGS`

- **Lens:** quality (re-examination of v2's D2)
- **Current state:** Recovery-log call site uses `NV_DEV_PRINTF(NV_DBG_ERRORS, nv, "GPU-lost check: transient PCIe read recovered after %u retr%s\n", retry, (retry == 1) ? "y" : "ies");` in the retry-success branch.
- **Proposed state:** Switch the macro level to `NV_DBG_WARNINGS` to reflect that a recovered transient is operationally a warning (anomaly mitigated), not an error (operation failed).
- **Value:** Semantic accuracy — `NV_DBG_ERRORS` semantically means "operation failed" and a recovered transient is a successful recovery.
- **Cost:** Breaks the file's grep-for-incidents convention (`osinit.c` has six `NV_DBG_ERRORS` call sites and zero `NV_DBG_WARNINGS` call sites — confirmed in v2 review). Project operators rely on noticing the recovery event in `dmesg`; `NV_DBG_ERRORS` is the highest-visibility severity in `kernel.log` after `printk(KERN_ALERT/CRIT)`. The aorus archaeology pre-empted this exact change: `docs/source-review-notes.md:1121-1122` labels the WARNINGS upgrade as "cosmetic" and explicitly defers it.
- **Verification mode:** A (code-reading: confirm the macro expansion against `src/nvidia/arch/nvalloc/unix/include/os-interface.h:265`).
- **Intent impact:** none — the intent's Telemetry contract names `NV_DEV_PRINTF(NV_DBG_ERRORS, nv, ...)` explicitly. Switching the level would also require an intent update for self-consistency, doubling the change surface.
- **Triage decision:** reject (re-defer).
- **Resolution:** rejected — aorus archaeology (`docs/source-review-notes.md:1109-1122`) shows the original author already triaged this exact question as cosmetic-defer. File-convention consistency and operator-visibility considerations point the same way. Sub-cycle 2's D2 disposition stands; archaeology confirms it is not a forgotten constraint.

### C3-gpu-lost-retry-I3 — Include microseconds-elapsed in the recovery log line

- **Lens:** quality (surfaced by aorus archaeology — log format differs)
- **Current state:** v1 log line: `"GPU-lost check: transient PCIe read recovered after %u retr%s\n"` — the retry count only.
- **Proposed state:** Match the aorus precedent (`docs/source-review-notes.md:1067`) and emit the microseconds elapsed alongside the count: `"GPU-lost check: transient PCIe read recovered after %u retr%s (%u us)\n"` with `retry, suffix, retry * NV_GPU_LOST_RETRY_DELAY_US` as args.
- **Value:** Operator gets one-glance time-spent data for incident triage without having to multiply by the documented delay constant.
- **Cost:** One extra format argument + one extra word in the log line. Format-string complexity rises trivially; the intent's Telemetry contract would need to be updated to match. Information is fully derivable from `retry * NV_GPU_LOST_RETRY_DELAY_US` (the constant is named and documented in the same file).
- **Verification mode:** A.
- **Intent impact:** refine Scenario "Recovered after one retry" + "Recovered after multiple retries" + the Telemetry contract format-string row — three site updates for a derivable datum.
- **Triage decision:** reject.
- **Resolution:** rejected — the elapsed-microseconds value is mechanically derivable from `count * 100µs` (the constant is documented in the same translation unit). Default-reject: low value, low cost, but no concrete operational gap. The v1 line is already self-documenting via the `transient PCIe read recovered after` framing.

### C3-gpu-lost-retry-I4 — Introduce module parameters `NVreg_GpuLostRetryCount` / `NVreg_GpuLostRetryDelayUs`

- **Lens:** robustness (re-considered against archaeology's "what if 1 ms isn't enough?" escape hatch)
- **Current state:** Constants are file-scope `#define`s in `osinit.c`. No runtime tuning surface.
- **Proposed state:** Wire the two constants through `nv-reg.h` as `NVreg_GpuLostRetryCount` (default 10) and `NVreg_GpuLostRetryDelayUs` (default 100), expose as `modprobe nvidia` parameters.
- **Value:** Future field-tuning without rebuild — the archaeology explicitly contemplates "bump `N_RETRIES` to e.g. 50 (5 ms)" as a possible follow-up if 1 ms is insufficient (`docs/source-review-notes.md:1104-1107`).
- **Cost:** Adds two `NVreg_*` declarations in `nv-reg.h`, two registry-binding stanzas, two storage globals, and two-side parsing in `osHandleGpuLost`. Expands upstream-PR review surface measurably. The schema's worked example for C3 explicitly stipulates "introduces NO module parameter" — adding one would conflict with the schema's anchor. The v2 review reaffirms the no-parameter posture: "the cumulative budget is ~1 ms, small enough that no caller has standing to demand a different value" (review lines 248-258).
- **Verification mode:** A.
- **Intent impact:** add Requirement covering tunable; refine Scope boundary; update Telemetry contract for tunable-aware log lines.
- **Triage decision:** reject.
- **Resolution:** rejected — schema-anchor conflict (the schema names C3 as the canonical example of *no module parameter*); aorus archaeology and v2 review both explicitly choose against the parameter; the escape-hatch documented in `docs/source-review-notes.md:1104-1107` is *write-once-then-bump-the-constant*, not *tunable-at-runtime*. The 1 ms budget is small enough that no operator workflow requires per-boot tuning. If the constant ever proves insufficient, the change is local to one `#define` and ships as a follow-up patch.

### C3-gpu-lost-retry-I5 — Replace fixed 100 µs delay with exponential or linear back-off

- **Lens:** performance / robustness
- **Current state:** Fixed 100 µs between every retry attempt (`osDelayUs(NV_GPU_LOST_RETRY_DELAY_US)` × 9 between 10 reads).
- **Proposed state:** Linear back-off (100, 200, 300, ..., 1000 µs — total ~5.5 ms) or exponential back-off (50, 100, 200, 400, ..., 1600 µs — total ~3.2 ms).
- **Value:** Longer-tail attempts could catch slower-recovering transients that fixed-100 µs misses.
- **Cost:** Linear back-off exceeds the ~1 ms budget the intent guarantees ("the cumulative delay budget MUST remain below one millisecond"). Exponential back-off would converge to roughly the same budget with longer tail intervals and would silently violate the intent's invariant that the retry is *invisible to every existing caller*. Either change would require the intent's Requirement-1 to be re-stated.
- **Verification mode:** A (code-reading on the intent invariant; B would be needed to validate that callers actually tolerate the new budget).
- **Intent impact:** refine Requirement "Driver SHALL bound the GPU-lost preflight with a retry budget" (relax the sub-1 ms invariant).
- **Triage decision:** reject.
- **Resolution:** rejected — would relax the sub-1 ms invariant the intent guarantees, with no field evidence that 100 µs × 10 is insufficient. The archaeology's empirical observation that transient durations are "sub-ms phenomena" (`docs/source-review-notes.md:1097-1103`) sets the budget at the right order of magnitude. If field evidence ever surfaces a slow-recovering transient, the escape hatch in I4's archaeology citation applies (bump the count, keep the delay).

### C3-gpu-lost-retry-I6 — Lift the atomic-context safety invariant from v2 review prose into the intent

- **Lens:** invariant clarity
- **Current state:** The v2 intent says "cumulative delay budget MUST remain below one millisecond so the retry is invisible to every existing caller and below the GSP RPC poll cadence" (intent line 44-47). The atomic-context-safety constraint (osDelayUs(100) → udelay() → safe in IRQ contexts via `nv_in_hardirq() && (us > NV_MAX_ISR_DELAY_US)` guard) is captured in the v2 review (lines 137-142) but is implicit in the intent.
- **Proposed state:** Add an explicit clause to the intent's scope boundary or Requirement 1 stating that the retry is safe to invoke from atomic contexts including interrupt handlers, with the `osDelayUs(100) → nv_sleep_us → udelay` resolution chain as the justification.
- **Value:** Captures a forgotten invariant before it bit-rots; future maintainers won't have to re-derive the atomic-context safety claim.
- **Cost:** ~2 sentences added to the intent's Scope boundary. The constraint is invariant across the call-site set (all 9 known callers are pre-atomic or non-atomic). Lifting it from review prose to intent prose changes status from `reviewed` to needing re-lint.
- **Verification mode:** A.
- **Intent impact:** refine Scope boundary (add atomic-context-safety clause).
- **Triage decision:** defer.
- **Resolution:** deferred — the invariant IS captured in the v2 review, which is durable provenance for the patch; the intent's existing "below one millisecond … invisible to every existing caller" already implies caller-context-agnostic safety. Lifting the explicit `udelay()` chain into the intent would re-open the intent's `reviewed` lint state for marginal clarity gain. **Disposition for follow-up:** if a future patch in this set adds a new `osHandleGpuLost` caller in a previously-unreached atomic context (none planned), bring this clause forward. Tracked here so a future maintainer doesn't re-litigate.

### C3-gpu-lost-retry-I7 — Document #916 (RTX 4090 / Ampere) as evidence for general-purpose hardening

- **Lens:** invariant clarity (community-signal triangulation)
- **Current state:** The intent's Purpose and Provenance both name #979 (Blackwell-over-Thunderbolt) as the upstream-issue anchor. The community-signal recon found #916 ("GPU lost from the bus … Zotac RTX 4090") with an Ampere + Ada follow-up (`sebjohansen04-cpu` 2026-05-20) confirming the same `NV_ERR_GPU_IS_LOST` code path is hit on non-Blackwell, non-eGPU, non-TB hardware.
- **Proposed state:** Add a one-line note to the intent's Provenance section or the v2 review's Cross-references section: "The single-read commit pattern fixed here also affects non-Blackwell, non-eGPU paths — see #916 (RTX 4090) — strengthening the upstream PR's case for general-purpose hardening."
- **Value:** When the upstream PR lands, the broader applicability evidence is co-located with the intent and helps reviewers see the change as a general improvement rather than an eGPU-specific workaround.
- **Cost:** ~1 line added to either Provenance (intent) or Cross-references (review). No code impact.
- **Verification mode:** A.
- **Intent impact:** refine Provenance section.
- **Triage decision:** defer.
- **Resolution:** deferred — belongs in the eventual upstream PR description rather than in the intent/review files for this sub-cycle. The community-signal doc already captures the #916 tag and the cross-reference is one query away. Lifting it into the intent now would mix sub-cycle 3 archaeology with the upstream-PR submission step, which is explicitly out-of-scope per the plan's "Out of scope" list. **Disposition for follow-up:** include the #916 evidence in the upstream PR body when C3 is submitted (post sub-cycle 3 of the patch-v3-improvements work).

## Improvements landed

(none — every candidate triaged `reject` or `defer`; v1 == v2 == v3 fork-branch tip.)

## Intent updates landed

(none — no candidate surfaced a substantive normative gap requiring an intent precursor.)

## Done gate

- [x] Every candidate improvement has explicit `Resolution:` (no `pending`).
- [x] All "land" improvements applied as fork-branch commits citing their `<id>-I<N>` IDs. _(N/A — zero land-tier improvements.)_
- [x] Substantive intent updates landed as precursor commits. _(N/A — zero substantive intent updates.)_
- [x] `tools/intent-lint.sh` passes _(no intent change; lint re-verified after Step 11 catalog write)._
- [x] `tools/validate-patchset.sh` passes (compile gate).
- [x] `bash tests/run.sh` green.
- [ ] Audit-reviewer subagent approved.

## Cross-references

- Intent file: `docs/patch-intents/C3-gpu-lost-retry.md`
- Review file: `docs/patch-reviews/C3-gpu-lost-retry.md`
- Manifest row: `patches/manifest` line for `C3-gpu-lost-retry` (layer `base`, source `fork:c3-gpu-lost-retry`)
- Vanilla baseline: `src/nvidia/arch/nvalloc/unix/src/osinit.c:osHandleGpuLost` (vanilla 595.71.05)
- Fork branch: `c3-gpu-lost-retry` on `apnex/open-gpu-kernel-modules` (tip `c589673a33729e24c5179f92c5c98dbac4886d6b`)
- aorus-5090 ancestor: `/root/aorus-5090-egpu/patches/0001-osHandleGpuLost-retry-on-transient-pcie-failure.patch`
- aorus-5090 design + investigation: `/root/aorus-5090-egpu/docs/lever-catalog.md:178-206` (Lever I entry); `/root/aorus-5090-egpu/docs/source-review-notes.md:993-1198` (Pass 7 implementation analysis); `/root/aorus-5090-egpu/docs/reliability-hypothesis-ledger.md:226-254` (H14 — PMC_BOOT_0 transient evidence); `/root/aorus-5090-egpu/docs/architecture-and-modularity.md:64-100` (L1 sovereignty justification).
- Upstream issue: <https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979> (Blackwell GPU over Thunderbolt: brief PCIe link drop commits GPU to permanent lost state) — C3 is the headline fix.
- Community signal: `docs/patch-improvements/_community-signal.md` §"Bus-loss / GPU-lost class" — #916 (RTX 4090 / Ampere — broader applicability evidence) and #1151 (RTX 5080 Xid 79 — symptom-adjacent only).
