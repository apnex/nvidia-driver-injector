# v5 architecture deep review — queued (2026-05-29)

**Status:** Out of scope for immediate work. Captured so it doesn't get forgotten.

## Observation

The injector patch stack (C1-C5, E1, A1-A6, with A7/A8/A9 imminent) has been built incrementally over multiple iteration cycles (v1 → v2 → v3 → v4+). Each patch was written under a specific failure-mode understanding that has, in several cases, since shifted. Examples of evolution evident in today's work alone:

- **F40 catalog**: originally framed as a teardown wedge in `RmShutdownAdapter`. Investigation through the day proved it's actually a chip re-init MMIO race in `RmInitAdapter`'s open-path. The catalog was cleaned up this evening to lead with the corrected mechanism, but the patch C5 / A3 / A2 still reference the older framing in places.
- **F40b**: design doc went through Tier 0 / Tier 1 / Tier 2 over the day, then walked back the "AER+C5 is reliable" claim after the n=2 reproducibility check failed. A6 landed as Tier 2; A7+A8+A9 are bolt-ons on top of Tier 2. If we'd known what we know now at the start, F40b might have been one larger patch instead of three siblings.
- **C5**: documented as v4 (cascade-class-design-v4); has accumulated detector classes that were added as new failure modes were catalogued. Some may be redundant or could be unified.
- **A3**: also v4-target-ready. Its `force_trigger` sysfs surface is test-only; could be folded or removed.
- **PINPOINT patches**: were diagnostic-only and are now obsolete (PINPOINT-1, -2, -3 in `patches/experimental/`). Should be deleted but were preserved during the investigation.

## Hypothesis worth testing in v5

If we re-architected the patch stack starting from current understanding (mechanism pinned, F40b structural close validated, in-driver recovery target articulated), we would likely:

1. **Consolidate the F40 family** into fewer, larger patches: one for detection (current A6 + A7 rmmod-path), one for observability (A8 sysfs), one for in-driver recovery (A9). Possibly merge A7 into A6 since both implement the same bounded-wait primitive on adjacent failure sites.
2. **Refine C5's sink primitive** to expose a more orthogonal interface for callers (open-path, rmmod-path, future failure paths). The detector enum has grown organically; some classes overlap.
3. **Simplify A3's state machine** now that A8 will introduce a recovery-state-machine pattern that A3 could share. A3's `pre_schedule_gates` is the right primitive; the rest could be a thinner consumer of it.
4. **Retire PINPOINT patches** outright. They've served their purpose (diagnostic phases are complete). Keep their content in the historical investigation archive only.
5. **Test the patch set against the original NVIDIA source code surface** to see whether some patches are now unnecessary (i.e., upstream has moved closer to the behaviour we wanted) or whether some should split / merge to match upstream's natural seams.

## A7 shutdown-arm — leak→join lifecycle + does-it-need-to-exist (added 2026-05-30, post-SH-1/SH-3)

The SH-series root-cause work (`docs/missions/mission-1-egpu-hot-plug-hot-power/shutdown-hang-ledger.md`) materially changed what A7 *is*, and surfaced two redesign questions that were deliberately deferred from the surgical SH-3 UAF-guard fix:

1. **Lifecycle: the "leak" concept is now obsolete.** A7 was built as a *leak-on-timeout* design (refcount-2 "one for caller, one for worker, last-one-frees"; the worker runs on after the wrapper returns). The SH-3 guard added `flush_work(&w->work)` on the timeout path, so the worker is now **always joined** — completion-wait on the happy path, flush on the timeout path. The refcount-2 protocol is still load-bearing *only* for the happy-path race (worker between `complete()` and `work_put()`), but the overall lifecycle could collapse into a cleaner always-join design (no "leaked worker" concept). Redesign, not a fix — v5.
2. **Existence: does A7's shutdown-arm bounded-wait need to exist at all?** SH-1 (n=3) proved `rm_shutdown_adapter` does NOT hang — it completes in ~600 ms; the original "hang" was the 200 ms budget guillotine, and the 20:52 forensics that "originated" A7 didn't even have A7 in the build (provenance corrected, A7 intent v1.3). So A7's shutdown arm may reduce to "call it, expect ~600 ms" with no wrapper at all — UNLESS the **rmmod-path teardown tail can genuinely exceed the budget** in some chip state (the F40 scenario), which SH-3 Rung-1 (rmmod-path latency, unmeasured) + the open-arm forensics (task #282) must settle first. If the rmmod tail is always bounded, A7-shutdown is a candidate for **removal**, not just simplification — contrast with A6-open, which guards a genuine chip-dead+AER+deadlock wedge (n=13) and is clearly needed.

This connects to item 1 below (consolidate the F40 family) but sharpens it: the merge-A7-into-A6 idea assumed both are needed; SH-1 suggests A7-shutdown might be *deletable*. Decide with SH-3 Rung-1 + SH-2 + the open-arm data in hand.

**Update 2026-05-31 (R0): the leak→join now spans BOTH arms.** R0 added `flush_work(&w->work)` to A6's open-path timeout branch (the Phase-0-confirmed F42 UAF fix — the worker was writing a freed `nvlfp`). So the "leaked worker" concept is obsolete on the open path too; item-1's always-join redesign applies to A6 *and* A7. v5 residual: A6's open-path flush can block `open()` until the closed-RM GSP-lockdown poll returns (bounded only if the RM gpuTimeout is finite) — the recovery-validation R2/R3 rungs measure that bound; if unbounded, the honest conclusion is A6's open path isn't cleanly hardenable in userspace-adjacent code, and E27 + in-driver recovery (reusing the *existing* deferred-open lifecycle: `nvidia_open_deferred` + `open_complete` + `is_accepting_opens`, rather than a bespoke worker) is the structural answer.

### The more-correct A6 open-path design — the "elegant solution" (capture for v5 / post-v5 triage)

R0's `flush_work` is the *minimal, safe containment* of the F42 UAF, but it re-couples the open syscall to the worker — partly undoing A6's whole fast-`-EIO` purpose. Two more-correct designs, to **triage at the v5 review** (do-during-v5 vs defer-post-v5):

- **(a) ownership-transfer** — on the leaked-timeout path, hand `nvlfp`+`sp` ownership to the worker so `nvidia_open`'s `failed:` path does NOT free them; the worker frees them when it completes. Keeps A6's fast 200 ms `-EIO` *and* closes the UAF. Cost: an abandon-flag race + `sp` lifetime care.
- **(b) deferred-open lifecycle reuse (preferred)** — route the bounded open through the kernel's *existing* async-open machinery (`nvidia_open_deferred` + `nvlfp->open_complete` + `nvl->is_accepting_opens` + `open_q` flushes + the close-side `nv_wait_open_complete`), which *already* solves "async open that doesn't free `nvlfp` and synchronizes with close/remove" correctly — instead of A6's bespoke worker + refcount-2 + flush. This is also the right shape for **E27's in-driver recovery** (`docs/missions/mission-1-egpu-hot-plug-hot-power/design/in-driver-recovery-target-2026-05-29.md`).

**Audit result (2026-05-31, `r0-flush-work-correctness-audit`, 4-agent):** R0 is **deadlock-free** (the flushing syscall under `ldata_lock` and the worker under the RM GPU-group lock are disjoint lock domains; the worker chain `rm_init_adapter → nv_start_device` takes no `ldata_lock`; same pattern A7's SH-3 already ships) and **UAF-solved** → R0 ships as the safe containment, and this redesign **stays post-v5** (not promoted to before-ship). The audit ruled **(b) deferred-open reuse is the most-correct fix** and **(a) ownership-transfer is strictly worse** (an `sp`-lifetime/double-free race vs flush_work's clean join) — so v5 should pursue **(b)**.

Two findings that *sharpen* (b)'s case:
- **The C5 sink cannot fast-fail this poll.** `rm_cleanup_gpu_lost_state()` itself takes a BLOCKING `rmapiLockAcquire(API_LOCK_FLAGS_NONE)` (osapi.c:1906 / rmapi.c:638), and the worker holds that RM API lock for the whole GSP-lockdown poll (the chip answers the reads, so no dead-bus sentinel trips). So R0's timeout branch re-couples the syscall and blocks for up to the **RM `gpuTimeout` (~4 s graphics / ~30 s compute, os.c gpu_timeout)** with `ldata_lock` HELD — the exact long-block A6 was built to avoid. (b) is the structural escape because it returns `-EIO` *without* joining and does not hold `ldata_lock` for the worker's run. This same sink-can't-fast-fail property also undercuts A7's "returns in microseconds" claim → fold into the C5-sink refinement (item 2).
- **(b) is not free:** the close-side `nv_wait_open_complete` is currently UNBOUNDED, so close would re-inherit the hang unless given a timeout variant + lost-state gating.

**Priority:** a refinement, NOT something R0 needs — R0 ships as the safe containment meanwhile; the actual `gpuTimeout` bound is measured by the recovery-validation R2/R3 rungs.

## Naming hygiene — failure-mode IDs leaked into identifiers (added 2026-05-31)

The user flagged that failure-mode catalog IDs (`F40b`) leak into implementation **identifiers**, not just comments. Failure-mode IDs are catalog/disease identifiers whose taxonomy EVOLVES (the same-day F40 → F40-open / F43 / F42 split is the proof); coupling code to them is the naming corollary of "patches != failure modes." **v5 sweep:** rename identifiers for behaviour/mechanism; keep F-IDs in comments/docs + the `fake-5090` reverse-map only. Inventory of current leaks:
- fork branches `a{6,7,8}-f40b-*`; patch filenames `A{6,7,8}-f40b-*.patch`; C symbols `nv_f40b_*`, `nv_tb_egpu_f40b_fired`; log strings `tb_egpu [F40b]: ...`.
- **`tb_egpu_f40b_fires` sysfs attr is user-visible ABI** — rename needs a deprecation path (expose the new name, keep the old as an alias for one cycle), NOT a free internal rename.

Deferred by the user (do NOT rename mid-stream). Memory: `feedback_no_failure_mode_ids_in_code`.

## Process suggestion when we get to v5

Per-patch deep dive, in order:
1. Re-read the patch's intent doc against the F40 catalog (and other failure modes the patch touches).
2. Re-read the patch's code against the vanilla NVIDIA source for that version (`595.71.05`).
3. Ask: "if we were writing this for the first time today, knowing what we know, would this look the same?"
4. Categorise: (a) keep as-is, (b) simplify, (c) merge with sibling, (d) split, (e) delete (subsumed by another patch or by upstream change).

Then a cross-cutting consolidation pass that triangulates:
- Patch intent docs (what we said we'd do)
- Failure mode catalog (what the problem actually is)
- Current code (what we actually built)
- Vanilla source (what upstream looks like)

Each axis is a corner of a quad — disagreements between corners are the refactor opportunities.

## What this doc is NOT

- Not a blocker for current work. A7 (rmmod-path wrapper), A8 (sysfs), A9 (in-driver recovery) all proceed under current scope.
- Not a commitment to a specific v5 timeline. The trigger is "current incremental work has stabilised enough that a focused architectural pass is the right next investment" — sometime after A9 lands and the soak gates pass.
- Not a list of bugs. The current stack works (validated n=2 for F40b today). This is about code aesthetics, maintainability, and reviewer-friendliness of the patch set.

## Inputs queued from #282 (open-arm forensics, 2026-05-30)

Two questions the open-arm work surfaced that belong in the strategic review:

1. **Does A3's `pci_reset_bus` cure, or only contain?** Lane 2 confirmed the open-arm wedge is the GSP lockdown-release wait; A3 already does a bridge bus-reset on rmInit-FAIL and is *designed* to recover-to-working, but no archive shows a successful recovery. The **reset-efficacy ladder** (`docs/missions/mission-1-egpu-hot-plug-hot-power/experiments/OA-reset-efficacy-ladder.md`) is the survivable (A6-net) experiment that settles it; if a secondary bus reset cures, the patch action is "A3 retries init after its existing reset" (contain→cure). Also revisit **A6 wrap-site placement** — Lane 2 *validated* A6 wraps the correct frame for the D0 site, but the >58 s-gap pre-`nv_open_device` site (H-OA2) is A6-uncovered.
2. **cmdline staleness vs the patch stack** — assessed in `pci-cmdline-audit.md` §E: scope is largely still correct (orthogonal kernel-layer concerns), but `pcie_aspm.policy` + `thunderbolt.clx` are candidate-stale and `pcie_port_pm=off` is intertwined with H-OA2. Test plan deferred (reboot-heavy).

## Cross-refs

- F40 catalog (refreshed today): `fake-5090/failure-modes/F40-reinit-gsp-lockdown-wedge.md`
- Existing patch intents: `docs/patch-intents/`
- In-driver recovery target design (sibling): `docs/missions/mission-1-egpu-hot-plug-hot-power/design/in-driver-recovery-target-2026-05-29.md`
- Open-arm forensics ledger (#282): `docs/missions/mission-1-egpu-hot-plug-hot-power/open-arm-forensics-ledger.md`
