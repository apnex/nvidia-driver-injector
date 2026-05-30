# Shutdown-Hang Investigation Ledger (SH-series)

**Purpose:** Root-cause why `rm_shutdown_adapter`'s chip-touching MMIO hangs on every TB-attached eGPU teardown — the disease that A7 *contains* but does not *cure*. A6/A7 are bounded-wait containment; A8 is observability; this ledger is the investigation into WHY the teardown MMIO does not complete gracefully, toward an actual fix (per `feedback_native_in_driver_hardening` — teardown should *work*, not just be *survived*) and an upstream-report-grade characterization.

**Status:** OPEN. Created 2026-05-30. Live driver: aorus.21 (A8 v2.1).

**This ledger is the single source of truth for the shutdown-hang investigation's numbering, hypotheses, metric inventory, and experiment status.** Per-experiment operational detail (exact commands, predicted signatures per branch, actual results, recovery) lives in `experiments/SH-<n>-*.md` once written. Distinct from `matrix.md` (Phase-2 BAR1/bridge-window archaeology, E-series — a different investigation).

## Methodology (binding)

- **One variable per experiment.** Written hypothesis before running. (`feedback_reliability_methodology`, `feedback_one_variable_per_test_perf`.)
- **Additive capture.** Each experiment captures the *maximum observable with the tooling it uses*; later experiments *add* deeper metrics, they do not re-run to grab something the earlier one could have captured. The Metric Inventory below is the contract that guarantees this — an experiment may not "skip" an observable-now metric and defer it.
- **Cheapest-first.** Existing-code experiments before instrumented-build experiments before invasive ones. (`feedback_reliability_methodology`.)
- **n ≥ 3 to resolve** a claim; n=1 is a lead, not a conclusion.
- **Observability perturbs the bug** (`feedback_observability_perturbs_bug`): prefer passive reads; when active observation is unavoidable, note it as a variable and read the *bridge*, not the hung device.
- **Recovery = reboot** on any wedge; the chip substrate stays structurally fine (BAR1 32 GiB) so a clean reboot restores baseline. Passive reads only on a suspected-wedged chip (`feedback_no_rpc_observability_on_broken_bar1`).
- **Thermal budget:** the hung worker pegs one CPU core; the NUC spikes package temp on single-P-core load (`project_h21_cpu_thermals_2026_05_11`). Cap shutdown-timeout experiments at **10 s** (not 30 s). Workqueue workers float across cores; we can't easily E-core-pin them, so the timeout cap is the mitigation.

## The phenomenon (what we already know — foundational, not yet root-caused)

1. `rm_shutdown_adapter` times out at the A7 budget (200 ms) on **every healthy teardown** on this hardware. Observed n≥4: A7 Test A 21:56:55, 22:06:35 (2026-05-29); aorus.20 deploy uninstall 10:11:45; aorus.20→21 redeploy uninstall 13:00 (2026-05-30); plus the close-path fire on every aorus.20/21 bring-up. **Extremely reproducible.**
2. `rm_disable_adapter` — the teardown step *immediately before* — **completes within budget** every time. So the hang is specific to the final GSP-shutdown step, not teardown generally. **This asymmetry is the sharpest existing lead.**
3. No D-state zombie accumulation after ~5 rmmods (checked 2026-05-30): the leaked worker *does* exit post-sink-set. (But the worker runs on the **shared** `system_long_wq` calling closed RM code — its lifecycle vs module-unload has never been *proven* safe, only not-yet-crashed. Tracked as a risk, see H-SH5.)
4. The worker **pegs one CPU core** during the hang (user-empirical, drives NUC thermal). A single blocked MMIO read would not — PCIe Completion Timeout (~50 ms) returns 0xFFFFFFFF and moves on. Sustained single-core load ⇒ **busy-poll loop**, not a blocked read. Leading interpretation: `rm_shutdown_adapter` polls a chip-state/handshake register waiting for a transition that never arrives during TB-eGPU teardown — meaning **the chip is likely alive and answering MMIO**, just never reaching the expected shutdown state. (Hypothesis, not yet confirmed — SH-1 tests it.)
5. **Unreconciled tension:** the F40 catalog's A4 close-path telemetry historically recorded `nv_shutdown_adapter` *completing* with WPR2 → 0 on a clean close, yet A7 shows `rm_shutdown_adapter` timing out every time. We do not have a single coherent model. SH-1's WPR2 before/during/after capture is designed to reconcile this.

## Hypotheses

| ID | Hypothesis | Status | Resolved by |
|---|---|---|---|
| **H-SH1** | `rm_shutdown_adapter` busy-polls a GSP/handshake register for a state transition that never occurs on TB-eGPU teardown (chip alive, answering reads, but bit never flips). | OPEN (leading) | SH-1 (CPU-burn + per-read behavior + AER address) |
| **H-SH2** | The 200 ms budget is simply too tight; the call *would* complete given more time, so A7 declares the GPU lost unnecessarily. | OPEN | SH-1 (does it complete at <10 s?) |
| **H-SH3** | Single non-returning MMIO read (CTO disabled/extended on this path), worker blocked not polling. | OPEN (counter to H-SH1) | SH-1 (D-state vs CPU-burn) |
| **H-SH4** | The hang is specific to a chip register/subsystem identifiable by the completion-timeout TLP address. | OPEN | SH-1 (bridge AER TLP address) |
| **H-SH5** | A7's leaked worker on `system_long_wq` has a use-after-free-on-module-unload race that we've survived by luck (worker exits fast enough). | OPEN (safety, not root-cause) | SH-1 close-path variant keeps module loaded; a dedicated SH later for the rmmod-unload race |
| **H-SH6** | WPR2 state at the hang point distinguishes "teardown stalled at entry" (WPR2 unchanged) from "stalled late" (WPR2 cleared mid-hang); reconciles the A4-vs-A7 tension. | OPEN | SH-1 (WPR2 before/during/after) |

## Metric inventory (the additive contract)

Every candidate metric for the shutdown-hang investigation, tagged by how it's obtainable. **SH-1 MUST capture every "observable-now" metric** (the additive guarantee); "needs-instrumentation" metrics are the *only* justification for a later SH-2 instrumented build.

| Metric | Obtainable | Captured by | Notes |
|---|---|---|---|
| `rm_disable` vs `rm_shutdown` latency (ballpark, ms) | observable-now | SH-1 | journal timestamps: "scheduled" → "completed"/"timed out" |
| Completes-at-Tms **or** never (10 s) | observable-now | SH-1 | "completed within budget" vs "timed out after 10000 ms" |
| Worker thread CPU-burn (poll vs block) | observable-now | SH-1 | sample `/proc/<tid>/stat` utime+stime + state @ 250 ms |
| Worker thread scheduling state (R/D/S) over time | observable-now | SH-1 | same sampler |
| Upstream-bridge AER status + completion-timeout TLP **address** | observable-now | SH-1 | passive `setpci`/sysfs on the **bridge** (03:00.0 / 02:00.0), NOT the hung device |
| Device AER status (if safe to read) | observable-now (cautious) | SH-1 | read only if it does not itself hang; prefer bridge |
| WPR2 (BAR0+0x88a828) before / during / after | observable-now | SH-1 | A4-style BAR0 read; the H-SH6 discriminator |
| PMC_BOOT_0 (chip identity, alive-check) before/during/after | observable-now | SH-1 | passive BAR0 read; confirms chip still answering MMIO |
| PCIe link state (speed/width/LinkActive) during hang | observable-now | SH-1 | sysfs `current_link_*` on bridge |
| `tb_egpu_f40b_fires` / `tb_egpu_state` (A8 v2.1) | observable-now | SH-1 | sysfs counter cross-check vs journal |
| Worker exits post-sink-set (no zombie) | observable-now | SH-1 | post-fire `ps -eLo` for D-state nv_f40b workers |
| **Exact per-iteration poll count / loop frequency** | needs-instrumentation | SH-2 (conditional) | requires a counter in A7's wrapper or eBPF on the RM MMIO accessor |
| **Sub-ms latency to completion** | needs-instrumentation | SH-2 (conditional) | ktime in the wrapper at rm_call entry/exit |
| **The exact register offset RM polls (vs the AER TLP addr)** | needs-instrumentation / eBPF | SH-2 (conditional) | eBPF uprobe/kprobe on os_* MMIO primitives; perturbs timing (note as variable) |
| **GSP message-queue / mailbox state during hang** | needs-deep-instrumentation | SH-3+ (conditional) | GSP RPC introspection; likely partly NVIDIA-domain |

## Experiment register

### SH-0 — Foundational observations (retroactive; the phenomenon)
- **A7 Test A** (`design/A7-test-A-validation-2026-05-29.md`): n=2 + 2 deploy uninstalls — `rm_shutdown_adapter` times out 200 ms every healthy teardown; `rm_disable` completes; host survives. **Containment validated; root cause NOT investigated.**
- **A7 Test B** (`design/A7-test-B-validation-2026-05-29.md`): n=1 — rmmod short-circuits `nv_shutdown_adapter` when `NV_FLAG_INITIALIZED` cleared (no-persistence path); close-path caller also fires A7. Context for choosing the close-path trigger in SH-1.
- Status: **DONE** (foundational). These establish the phenomenon; SH-1+ investigate the cause.

### SH-1 — Latency + poll-vs-block + AER-address @ 10 s, close-path, existing code  *(UPCOMING — next)*
- **Hypothesis:** primarily H-SH1 (busy-poll, chip alive); also resolves H-SH2/H-SH3/H-SH4/H-SH6.
- **Trigger:** CLOSE path (load no-persistence → `open()+close()` `/dev/nvidia0` → `nv_stop_device → nv_shutdown_adapter` → A7 `rm_shutdown_adapter` wrap). Module stays loaded ⇒ no rmmod-unload UAF risk (H-SH5 deferred), repeatable n≥3 in one boot.
- **Variable:** `NVreg_TbEgpuShutdownTimeoutMs = 10000` (only change vs production 200 ms).
- **Capture:** every "observable-now" metric in the inventory (the additive guarantee).
- **Cheapest-first:** existing A7 code, journal-timestamp latency resolution. An instrumented SH-2 is justified ONLY if SH-1 leaves a "needs-instrumentation" metric load-bearing for the conclusion.
- **Predicted branches → inference:** see the outcome→inference table (to be written into `experiments/SH-1-*.md`); each of {completes-fast / completes-slow / never} × {pegged / D-state} × {WPR2 cleared / not} maps to a distinct cause.
- **Precondition gate:** observable-surface mapping (task (b)) MUST complete first, to certify the capture list is exhaustive (so SH-1 doesn't miss an observable-now metric and force a re-run — the additive contract).
- Status: **BLOCKED on (b)**, then ready.

### SH-2 — Instrumented latency + poll-counter + register identity  *(CONDITIONAL)*
- Justified only if SH-1 shows non-completion (or sub-ms / per-iteration metrics become load-bearing). Adds a ktime + poll-counter to A7's wrapper and/or eBPF on the MMIO accessor. ADDITIVE to SH-1 — does not re-capture SH-1's observable-now metrics.
- Status: **CONDITIONAL on SH-1**.

## Status board

| Exp | One-liner | Status |
|---|---|---|
| SH-0 | Foundational: rm_shutdown_adapter hangs every teardown (A7 Test A/B) | DONE |
| **(b)** | Observable-surface mapping + A4/A7 WPR2 reconciliation (exhaustiveness gate for SH-1) | **NEXT** |
| SH-1 | Latency + poll-vs-block + AER address @ 10 s, close-path, existing code | BLOCKED on (b) |
| SH-2 | Instrumented latency + poll-counter + register identity | CONDITIONAL on SH-1 |

## Cross-refs

- A7 Test A / Test B / Test B-prime plan: `design/A7-test-A-validation-2026-05-29.md`, `design/A7-test-B-validation-2026-05-29.md`, `design/test-B-prime-plan-2026-05-30.md`
- F40 catalog (two-arm, shutdown-arm mechanism): `/root/fake-5090/failure-modes/F40-rmshutdownadapter-incomplete-init-wedge.md`
- A7 intent: `../../patch-intents/A7-f40b-bounded-wait-shutdown.md`
- A8 v2.1 (the observability surface SH-1 reads): `../../patch-intents/A8-f40b-sysfs-observability.md`
- Phase-2 BAR1 archaeology registry (distinct investigation): `matrix.md`
- Methodology memories: `feedback_reliability_methodology`, `feedback_one_variable_per_test_perf`, `feedback_observability_perturbs_bug`, `feedback_freeze_risk_methodology`, `feedback_no_rpc_observability_on_broken_bar1`, `project_h21_cpu_thermals_2026_05_11`

## Note on Test B-prime

Test B-prime (`design/test-B-prime-plan-2026-05-30.md`) is **deferred**, not cancelled. It refines A7's *containment* behavior (does a pre-set C5 sink change the timeout). If SH-1 shows `rm_shutdown_adapter` completes at a measurable latency (H-SH2), Test B-prime's premise changes materially — so SH-1 comes first. Re-evaluate Test B-prime after SH-1 resolves.
