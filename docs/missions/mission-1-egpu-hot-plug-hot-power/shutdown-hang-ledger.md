# Shutdown-Hang Investigation Ledger (SH-series)

**Purpose:** Root-cause why `rm_shutdown_adapter`'s chip-touching MMIO hangs on every TB-attached eGPU teardown — the disease that A7 *contains* but does not *cure*. A6/A7 are bounded-wait containment; A8 is observability; this ledger is the investigation into WHY the teardown MMIO does not complete gracefully, toward an actual fix (per `feedback_native_in_driver_hardening` — teardown should *work*, not just be *survived*) and an upstream-report-grade characterization.

**Status:** SH-1 RESOLVED 2026-05-30 — **`rm_shutdown_adapter` does NOT hang; it completes in ~600 ms (n=3).** The "hangs every teardown" premise was an artifact of A7's 200 ms budget (~3× too tight). See SH-1 results. Live driver: aorus.21 (A8 v2.1).

> **HEADLINE (2026-05-30):** The F40 shutdown-arm was substantially **iatrogenic**. `rm_shutdown_adapter` busy-runs ~600 ms on `system_long_wq` (R-state, CPU pegged, AER clean = chip answering) then **completes successfully**. A7's 200 ms guillotine cut it off, declaring the GPU lost prematurely on every teardown. Immediate fix: bump the budget to ~1500–2000 ms → teardown completes normally. OPEN: why ~600 ms (SH-2 eBPF), and whether the rmmod-path (module-unload-vs-running-worker, H-SH5) is a separate real wedge.

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
5. ~~**Unreconciled tension:** A4 telemetry records `nv_shutdown_adapter` completing with WPR2 → 0; A7 shows `rm_shutdown_adapter` timing out every time.~~ **RECONCILED by (b) 2026-05-30 — no contradiction.** A4's `tb_egpu_close_diag(post-shutdown)` (nv.c:2402) fires *strictly after* `nv_shutdown_adapter` returns, which on the non-persistent path is *after* A7's bounded-timeout return — so A4's WPR2=0 is a **post-timeout after-sample, NOT proof of graceful completion**. The leaked `system_long_wq` worker is what stays stuck; the caller thread returns and runs A4 downstream. Mechanistic payoff: **WPR2 clears early in `rm_shutdown_adapter`, before the stuck MMIO ⇒ the hang is a late-stage stall (post-WPR2-clear)**. The persistent path (nv.c:2388) skips `nv_shutdown_adapter` entirely (GSP stays resident, WPR2 stays up) — that was the other historical reading. SH-1 triggers the non-persistent close path.

## Teardown model (reconciled — the during-hang WPR2 read selects among three)

The `before(UP)→after(0)` WPR2 transition is identical under Models A and B; **only the during-hang value discriminates** (this is why SH-1's gated during-hang BAR0 read is the centerpiece):

| Model | during WPR2 | during PMC_BOOT_0 | worker CPU | kernel AER Δ | Mechanism |
|---|---|---|---|---|---|
| **A — late-stall (H-SH1, leading)** | `0` | `0x1b2000a1` (alive) | pegged (R) | 0 | post-WPR2 GSP handshake bit never flips; busy-poll, chip alive |
| **B — slow-but-progressing (H-SH2)** | `UP` | `0x1b2000a1` | pegged | 0 | worker clears WPR2 in timeout→A4 gap; 200 ms budget too tight |
| **C — MMIO-dead (H-SH3)** | unreadable | `0xFFFFFFFF` | D-state | ≠0 (CmpltTO) | chip dark — **already unlikely** (live A4 PMC=0x1b2000a1) |

Leading interpretation pre-SH-1: **Model A** (corroborated by the single-core CPU peg + live chip-alive PMC_BOOT_0). The bridge **AER Header Log TLP address** (latched on CmpltTO) is the passive proxy for *which* register; the **direct polled offset is unknown to the entire open layer** (only known BAR0 offsets: `0`=PMC_BOOT_0, `0x88a828`=WPR2) → SH-2 eBPF item, not an SH-1 miss.

## Hypotheses

| ID | Hypothesis | Status | Resolved by |
|---|---|---|---|
| **H-SH1** | busy-poll mechanism — worker busy-runs polling a GSP register, chip alive/answering. | **CONFIRMED (mechanism)** 2026-05-30 — worker R-state on `system_long_wq` CPU14, AER clean. But the bit DOES flip ~600 ms (not "never"). | SH-1 |
| **H-SH2** | 200 ms budget too tight; call *would* complete given more time → A7 premature. | **CONFIRMED (outcome)** — completes ~600 ms (n=3); 200 ms ~3× too tight. | SH-1 |
| **H-SH3** | single non-returning MMIO, worker blocked (D-state), CTO fires. | **REFUTED** — worker R not D; AER Δ=0 (no CTO); completes. | SH-1 |
| **H-SH4** | hang identifiable by CTO TLP address. | N/A — no CTO fires (chip answers). Register identity → SH-2 eBPF. | SH-2 |
| **H-SH5** | A7's leaked worker on `system_long_wq` has a UAF-on-module-unload race. | **OPEN — now sharper.** Close-path completes in 600 ms (no leak). But rmmod unloads the module; if a real teardown is mid-flight when rmmod completes, the ~600 ms worker races the unload. The original 20:52 rmmod "wedge" may be THIS, not a hang. | dedicated rmmod-path SH (SH-3) |
| **H-SH6** | WPR2 timeline distinguishes stall-at-entry vs late. | RECONCILED (no contradiction); during-WPR2 unreadable from userspace (STRICT_DEVMEM) → SH-2 if needed. | (b) + SH-2 |

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
| **Kernel-decoded AER counters** `aer_dev_{fatal,nonfatal,correctable}` on 00:07.0/03:00.0/04:00.0 | observable-now | SH-1 | *(NEW from (b))* before/after **delta** ⇒ "kernel AER IRQ actually fired (real PCIe error)" vs "zero delta = busy-poll, H-SH1". Passive bridge/root-side. |
| **Root Error Status + Error Source ID** on root 00:07.0 (AER+0x30/+0x34) | observable-now | SH-1 | *(NEW from (b))* latches originating requester BDF; confirms GPU-as-source + RC AER reporting fired. Passive `setpci`. |
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
| SH-0 | Foundational: rm_shutdown_adapter "hangs" every teardown (A7 Test A/B) — **REINTERPRETED**: ~600 ms completion cut off by 200 ms budget | DONE (superseded reading) |
| (b) | Observable-surface mapping + A4/A7 WPR2 reconciliation (exhaustiveness gate) | DONE 2026-05-30 |
| **SH-1** | close-path latency + poll-vs-block @ 10 s | **RESOLVED 2026-05-30** — completes ~600 ms (n=3); busy-poll; 200 ms too tight; no hang |
| **FIX** | Bump `NVreg_TbEgpuShutdownTimeoutMs` default 200 → ~1500–2000 ms → teardown completes normally (no premature GPU-lost) | **READY to implement** (aorus.22) |
| SH-2 | eBPF on `osDevReadReg032` → exact polled register + poll cadence (why ~600 ms?) | NEXT (optional — characterization, not blocking the fix) |
| SH-3 | rmmod-path: does the ~600 ms worker race module-unload (H-SH5 UAF)? Is the 20:52 wedge this? | OPEN (the remaining real-risk question) |

## Cross-refs

- A7 Test A / Test B / Test B-prime plan: `design/A7-test-A-validation-2026-05-29.md`, `design/A7-test-B-validation-2026-05-29.md`, `design/test-B-prime-plan-2026-05-30.md`
- F40 catalog (two-arm, shutdown-arm mechanism): `/root/fake-5090/failure-modes/F40-rmshutdownadapter-incomplete-init-wedge.md`
- A7 intent: `../../patch-intents/A7-f40b-bounded-wait-shutdown.md`
- A8 v2.1 (the observability surface SH-1 reads): `../../patch-intents/A8-f40b-sysfs-observability.md`
- Phase-2 BAR1 archaeology registry (distinct investigation): `matrix.md`
- Methodology memories: `feedback_reliability_methodology`, `feedback_one_variable_per_test_perf`, `feedback_observability_perturbs_bug`, `feedback_freeze_risk_methodology`, `feedback_no_rpc_observability_on_broken_bar1`, `project_h21_cpu_thermals_2026_05_11`

## Note on Test B-prime

Test B-prime (`design/test-B-prime-plan-2026-05-30.md`) is **deferred**, not cancelled. It refines A7's *containment* behavior (does a pre-set C5 sink change the timeout). If SH-1 shows `rm_shutdown_adapter` completes at a measurable latency (H-SH2), Test B-prime's premise changes materially — so SH-1 comes first. Re-evaluate Test B-prime after SH-1 resolves.
