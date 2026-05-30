# OPEN-ARM forensics ledger — #282 (RmInitAdapter wedge)

**Status:** DESIGN COMPLETE — chip-free. Reviewed and corrected by an adversarial red-team pass (4 must-fix + 4 should-fix items folded in). **Not yet executed. No experiment runs until the design is signed off.**
**Series:** Open-Arm (OA) — the sibling of the now-closed Shutdown-Hang (SH) series.
**Parent:** the F40 failure class. See `shutdown-hang-ledger.md` (SH, RESOLVED) and `session-handover-2026-05-30.md` (two-arm framing).

This is the umbrella design doc for the open arm — the *genuine* host wedge (n=13 reboots) that A6 contains but does not cure. It defines the hypothesis set, the cheapest-first experiment ladder, the known discrimination holes, the safety protocol, and the scope (cure-vs-contain).

---

## 0. What #282 is (and is not)

F40 is **two mechanistically-opposite arms** that share one function family:

| | **OPEN arm** (`RmInitAdapter`) | **SHUTDOWN arm** (`rm_shutdown_adapter`) |
|---|---|---|
| Chip answers MMIO? | **NO** — dead for init | YES — answers every read |
| Outcome | **genuine host wedge, n=13 reboots** | completes ~600 ms |
| Real failure? | **YES** | NO (200 ms budget was just too tight) |
| Status | **OPEN — this doc (#282)** | RESOLVED (SH series) |

#282 studies the OPEN arm. A6 (`NVreg_TbEgpuOpenTimeoutMs=200`, gated on `is_external_gpu`) **contains** it — deterministic `-EIO`, host survives — but does **not** touch the chip-side cause. The question this ladder answers: *where exactly does the wedge sit, what is the mechanism, and is the root cause host-reachable (a cure exists) or in NVIDIA's GSP-firmware/TB-tunnel/silicon substrate (contain-only, #979 territory)?*

---

## 1. Corrected framing (post-critique — read this first)

Four corrections were forced by the red-team and are now load-bearing in the design below. They overturn parts of the initial "SH-2 gives us the answer" intuition:

1. **The wedge SITE is genuinely unresolved — H-OA1 and H-OA2 are CO-LEADING, equal prior.** The open-arm evidence is a 50/50 split between two *direct, mutually-incompatible* bpftrace observations on the same failure mode:
   - **Test B v2** — cycle-2 reached `nv_open_device_for_nvlfp`, issued MMIO → `UESta=0x4000` → wedge **INSIDE** RmInitAdapter.
   - **FULLPRE** — captured **ZERO** cycle-2 events; the wedge fired **BEFORE** `nv_open_device` was ever entered (before `nvidia_open` queues work).
   The SH-2 PMU capture that pins the init path to `_kgspRpcRecvPoll` was taken on the **shutdown arm** (a healthy chip that answers every read). It supports the *mechanism* hypothesis but is **not** direct evidence of the *open-arm site*. Do not call H-OA1 "leading." (Single-datapoint-overreach scar.)

2. **The "contained" lane is only *provisionally* contained.** A6's bounded-wait engages **only if** the wedge is inside the worker-queued `nv_open_device_for_nvlfp`. If H-OA2 (PM-resume) is the site, the wedge is in the `open()` syscall path *before* `nvidia_open` queues work → A6 never fires → no `-EIO` → the "free, zero-reboot" rungs are **genuinely destructive**. ⇒ **Rung 0 must run first** and gate the contained-lane classification on observing A6's `open scheduled to bounded worker` log line on the actual fire.

3. **There may be TWO different open-arm wedges, not one.** FULLPRE wedged after a **58 s** idle gap (> 5 s autosuspend → chip went D3hot → birthed the PM-resume hypothesis). The canonical n=4 recipe uses **`sleep 2`** (< 5 s, no autosuspend) and "wedges immediately on RmInitAdapter." A 2 s-gap wedge **cannot** be PM-resume. ⇒ the **idle gap is an explicit controlled variable in every contained rung**; Rung 4 runs at *both* gaps as paired arms. If the PMU frame differs by gap, the hypothesis set splits.

4. **A whole root-cause class was missing: the early-MMIO sanity-check wedge (H-OA10).** The divergent-state sentinel `0x110094 == 0xbadf2100` (`gpuHandleSanityCheckRegReadError_GH100`) appeared in **4 of 5** wedge boots — a *first*-register-read handler that fires **before** any GSP RPC. The original set jumped straight to the GSP-init RPC poll and skipped the possibility that RmInitAdapter hangs on its very first read.

---

## 2. Hypothesis set (H-OA1 … H-OA12)

Not strictly mutually exclusive (a cascade rarely is) — treat as a *ladder* answering distinct questions. Grouped by the question each answers.

### Group A — WHERE is the wedge? (the three co-leading candidate sites)

| ID | Statement | Discriminator | Lane | Prior |
|---|---|---|---|---|
| **H-OA1** | Wedge is the GSP **init** RPC never completing: `kgspWaitForRmInitDone_IMPL → rpcRecvPoll(GSP_INIT_DONE) → _kgspRpcRecvPoll` polls a BAR0 mailbox/heartbeat read that CTOs; worker deadlocks holding the GPU group lock. Same `_issueRpcAndWait`/`_kgspRpcRecvPoll` as the ~600 ms unload, **reply never arrives / read hangs**. | PMU stack pinned at `_kgspRpcRecvPoll ← kgspWaitForRmInitDone ← kgspBootstrap_GH100`. | contained\* | co-lead |
| **H-OA2** | Wedge is **NOT** in RmInitAdapter — it's earlier: a PCI runtime-PM **D3hot→D0 resume** (`pci_pm_runtime_resume`) hangs in the kernel PM core *before* any nvidia.ko fop runs, because the recovered chip can't complete D3→D0 link retrain / GSP-state restore. | ftrace stack in `pci_pm_runtime_resume`/PM core (IBT-clean, ftrace-able); D0-pinned + no-gap run survives, idle-gap run wedges. | destructive | co-lead |
| **H-OA10** | Wedge is on the **first** RmInitAdapter MMIO — the `0x110094` sanity-check read / `PMC_BOOT_0` / pre-GSP register probe hangs **before** any `_issueRpcAndWait`. | PMU stack pinned in `gpuHandleSanityCheckRegReadError_GH100` / early `gpuState*` frame, **not** `_kgspRpcRecvPoll`. Sentinel present 4/5 boots. | contained\* | **elevated** (most-frequent signature) |

\* "contained" is provisional on Rung 0 confirming A6 engages on the fire.

### Group B — fast-fail confusables (host-ALIVE, not a wedge — rule out first)

| ID | Statement | Discriminator | Lane |
|---|---|---|---|
| **H-OA3** | WPR2-stuck blocked-retry: prior failed boot left WPR2=`0x07f4a000`; `_kgspBootGspRm` WPR2-already-up check returns `NV_ERR_INVALID_STATE`, rm_init **fast-fails** (host alive), loops until PCI reset clears it. | dmesg `unexpected WPR2 already up`; in-driver WPR2 BAR0 read non-zero; **host stays alive** (the only host-alive-on-wedge hypothesis besides H-OA7). | contained |
| **H-OA7** | GSP firmware-load failure (`-2`/WPR mismatch/image-prep): `gsp_*.bin` missing/dangling or FWSEC prep fails → `kgspInitRm_IMPL` returns early, **before any chip MMIO**. | `readlink` of `gsp_*.bin`; dmesg `firmware load error -2` / `need firmware to initialize GSP`; host fully healthy. | chip-free |

### Group C — already-mitigated upstream triggers (retained for MECE / as contributors, **not** sole cause)

| ID | Statement | Discriminator | Lane |
|---|---|---|---|
| **H-OA4** | IOMMU/DMAR fault during GSP DMA (`fault reason 0x71`). **But Lever T (`iommu=off`) is live on apnex.23** and the wedge still reproduces n=13. | dmesg `DMAR:` in the cycle-2 window. Falsified-as-**sole**-cause if absent under Lever T (expected); retained as contributor. | chip-free |
| **H-OA5** | Gen3/PCIe signal-integrity link degradation (bridge Cor=0x1 Receiver Error). **But Gen2+bit5 cap (Lever H17) is live.** | passive lspci/setpci: bridge **correctable** Receiver-Error vs H-OA1's **uncorrectable** device CTO; device-side (not virtual TB bridge) LnkSta parsed per the bitfield rule. | chip-free |

### Group D — addressing / driver-state mechanisms (newly added by red-team)

| ID | Statement | Discriminator | Lane |
|---|---|---|---|
| **H-OA11** | **BAR mis-mapping**: post-`fix-bar1`, the BAR0 ioremap targets a degraded/256 MB-windowed or unbacked region → the first MMIO CTOs because the *address* is wrong, not because the chip refuses a valid address. AER-identical to H-OA1. | compare BAR0 ioremap target vs sysfs-decoded window (`/sys/.../resource`); BAR1=256 MB sysfs flag; this is the tie-break Rung 5 alone cannot make. | chip-free (sysfs) |
| **H-OA12** | **RM software-state inconsistency** from cycle-1's *destructive* last-close teardown (`nv_shutdown_adapter`: WPR2→0, `gpuStateDestroy`, DMA teardown). cycle-2 re-inits from a half-torn-down host-side state (stale `gpumgr` registry, half-freed structs) — distinct from chip silence. | does a full PCI **reset** (remove+rescan) between cycles eliminate the wedge while a soft re-open does not? | destructive differential |

### Group E — host-lock nature & residual role

| ID | Statement | Discriminator | Lane |
|---|---|---|---|
| **H-OA6** | The kernel **deadlock is PRIMARY**, not consequent: the blocked MMIO holds locks the AER `error_detected` path needs → lock-inversion, AER can never win. The host-lock is a kernel-concurrency defect layered on chip silence. | AER-win **rate** rises with scheduling slack (CPU-isolated AER processing as the *only* change, to avoid the probe-is-the-slack artifact). | destructive |
| **H-OA8** | Surprise-removal/consumer-holder cascade (Xid 79/154) — cycle-2 races teardown state left by held device-plugin/persistence/vLLM. | dmesg Xid 79/154 + lsof holder at trigger. F40 negative assertion: **Xid count == 0** during the wedge → likely falsified. | chip-free |
| **H-OA9** | **No single host-fixable cause** (Mode-B precedent): the cause is in NVIDIA's GSP-fw/TB-tunnel/silicon substrate; the project's role is **containment (A6), not cure**; characterization is #979-report-grade. | residual by elimination — **see falsifier fix below**. | analytic |

**Confounder control (not a hypothesis):** **state-accumulation / repetition-count.** The contained lane re-fires n≥3 within one boot via the ~17 s recovery; cumulative chip degradation across repeated destructive teardowns (the Run1-survived/Run2-wedged confounder) could make the wedge *rate* drift with repetition. Every contained rung records repetition index and watches for monotonic drift.

---

## 3. Experiment ladder (corrected)

**Ordering law:** chip-free → contained → destructive. Every rung must teach on *both* outcomes (no null result). One variable per test. n≥3 to resolve (n≥5 where a *survival* claim is made). 10 s thermal cap on any timeout-bearing run (single P-core busy-poll → 105 °C, H21).

### LANE 1 — chip-free, read-only, **0 reboots, 0 thermal** (can begin immediately on approval)

| Rung | Tests | Method (all passive / archived) | Decision |
|---|---|---|---|
| **0** *(NEW, gating)* | containment boundary + recipe reconciliation | Read the **FULLPRE vs Test-B-v2 forensic archives**: did A6's `open scheduled to bounded worker` log line fire on the wedge boots? Reconcile the **2 s-canonical vs 58 s-FULLPRE** recipes. | If A6's schedule line **present** on the fire → Lane 2 is genuinely contained. If **absent** → wedge is pre-A6 → **Rungs 4-7 reclassified DESTRUCTIVE**. If the two recipes differ in signature → **two wedges**, split the set. |
| **1** | H-OA7, H-OA3 | `readlink -f …/gsp_*.bin` + `rpm -ql`; grep wedge journals for `firmware load error` / `WPR2 already up`. | **Absence-of-line ≠ elimination** (journald never flushed the trigger — flush gap). Treat a missing line as *not-confirmed*, not falsified, unless an fsync'd marker corroborates. |
| **2** | H-OA4, H-OA5 | `/proc/cmdline` (Lever T + cap present); grep `DMAR:`; passive lspci/setpci **config-space** AER CESta + device LnkSta (bitfield rule). | Falsified-as-**SOLE**-cause if mitigations present + signature absent; **retained as contributor** in H-OA9. |
| **3** | H-OA8 | grep wedge journals for Xid 79/154; inspect archived holder state. | Xid==0 + holders drained → H-OA8 falsified (clean Xid-free deadlock class). |

### LANE 2 — contained (**PROVISIONAL on Rung 0**), repeatable `-EIO`, **0 reboots**

| Rung | Tests | Method | Decision / fix-ins |
|---|---|---|---|
| **4** *(crux)* | H-OA1 vs H-OA2 vs **H-OA10** | A6 at 200 ms. Arm freeze scaffolding. Establish F40 precondition, cycle-1 clean, cycle-2 fire. PMU-sample the leaked worker: `bpftrace profile:hz:N { @[kstack]=count(); }` (**not** kprobe — closed RM has 0 `endbr64`, EINVALs under IBT). **Run at BOTH idle gaps (2 s, >58 s) as paired arms.** Require the dominant frame **stable across ≥2 probe rates (hz:997 + hz:4999), n≥3 each**, before trusting it. | Buckets: `_kgspRpcRecvPoll`-via-RmInitDone → **H-OA1**; early `gpuHandleSanityCheckRegReadError`/`gpuState*` → **H-OA10**; PM-core frame **or PMU-NULL** → **H-OA2** (PMU *can* null if the freeze precedes any symbolizable frame — route to Rung 8 ftrace); `kfspWaitForGspTargetMaskReleased`/lockdown-wait → new H-OA1-prime. If frame **moves with probe rate** → perturbation-dominated → fall back to Rung 8 ftrace (IBT-clean PM frames). If frame differs **by gap** → two wedges. |
| **5** | H-OA1 vs H-OA5 vs H-OA11 vs (H-OA6 tie) | Post-fire passive AER config-space read on device 04:00.0 (expect `UESta=0x4000`) and bridge (expect Cor=0x1). **BAR1 sysfs FIRST** (32 GiB?). Add BAR0-target-vs-decoded-window read for **H-OA11**. | device-CTO → H-OA1/H-OA10/**H-OA11** (still tied on AER alone — break with the BAR0-target read); bridge-RxErr → H-OA5; **neither AER fired → 3-way tie (H-OA6 / H-OA1a / H-OA2), not a clean H-OA6 signal** → route to Rung 8. |
| **6** | H-OA1a vs H-OA1b | Refine PMU: is `gpuCheckTimeout`/`heartbeat` adjacent to `_kgspRpcRecvPoll` in the histogram? Optional `*(reg)` for the BAR0 mailbox offset (#979 residual). | frames absent → **H-OA1a** (read instruction hangs, true CTO, A6 load-bearing); present → **H-OA1b** (graceful spin, chip answers garbage, A6 belt-and-suspenders — but gate any "A6 unneeded" claim on Rung 8 n≥3). |
| **7** | H-OA3 | **STRICTLY GATED.** Only if Rung 0/1 surfaced a WPR2 line. Prefer reading WPR2 on a **fresh clean bind (pre-cycle-2)**, never post-fire. Healthy-BAR1 sysfs gate **and** sink/worker-state check before any BAR0 ioread (A1 primitive has no in-primitive gate). **Post-fire BAR0 read is reclassified destructive.** | WPR2 non-zero + fast-fail → H-OA3; WPR2==0 + indefinite wedge → H-OA3 falsified. |

### LANE 3 — uncontained-destructive, **reboot each fire, runs LAST**

| Rung | Tests | Method | Budget |
|---|---|---|---|
| **8** | H-OA2, H-OA6, H-OA12 | A6 **disabled** (`NVreg_TbEgpuOpenTimeoutMs=0`). Full freeze scaffolding (fsync markers + `sync -f`, TTY isolate via `setsid`, `systemctl isolate multi-user.target`, sysrq armed, 10 s hard-timeout). One variable per reboot. **(A)** H-OA2 PM differential: `power/control=on` on GPU+audio + runtime-PM disabled, no-gap vs 58 s-gap; ftrace `function_graph` on open nvidia.ko + PM core. **(B)** H-OA6 slack A/B: CPU-isolated AER processing as the *only* change (not probe-count). **(C)** H-OA12: full PCI reset between cycles vs soft re-open. First post-wedge check ALWAYS passive BAR1-via-sysfs, then reboot. | **Survival arm n≥5** (1/12 baseline noise can fake a 3-cycle "survive" — the Run1/Run2 false-negative trap) + same-boot wedging control. Honest budget: **up to ~10 reboots.** |

### ANALYTIC — residual

| Rung | Tests | Decision |
|---|---|---|
| **9** | H-OA9 | Tabulate Rungs 0-8. **Falsifier (corrected):** a variable that shifts wedge-**rate** by a **pre-registered effect size over n≥5 with a stated CI** counts as a host-reachable cause — *not* the impossible "deterministically gates 0/1" bar (the failure is a known race). If the site is pinned but no variable moves the rate past threshold → H-OA9 stands → freeze at A6 containment, package the PMU RPC-wait characterization + `UESta=0x4000` + BAR0 mailbox offset into the **#979** report, close #282 as "locus pinned, cause is NVIDIA substrate, contained not cured." |

---

## 4. Known discrimination holes (documented, with mitigation)

These are ties the ladder must not paper over (red-team find):

1. **H-OA1 vs H-OA10** — both give a pinned RM stack + device CTO. Split **only** by the *frame* in Rung 4 (RPC-poll vs early sanity-check). Now an explicit Rung-4 bucket.
2. **H-OA1 vs H-OA11** — *identical* AER (device `UESta=0x4000`). AER alone cannot separate "chip refuses valid address" from "MMIO targets mis-mapped address." Broken **only** by the Rung-5 BAR0-target-vs-decoded-window read.
3. **H-OA2 vs H-OA1 on a PMU-NULL result** — if the kernel froze *below the sampling floor* (FULLPRE captured zero events), PMU yields nothing. "PMU always symbolizes, cannot null" is **FALSE** here. A null PMU routes to H-OA2/pre-syscall-freeze, resolved by the Rung-8 ftrace (IBT-clean PM frames).
4. **"Neither AER fired"** is a **3-way tie** (H-OA6 / H-OA1a / H-OA2), not an H-OA6 signal. Decision rule corrected.
5. **H-OA3 vs H-OA7 absence-of-log** — journald flush gap means a missing line ≠ absent mechanism. Treat as not-confirmed; corroborate with fsync'd markers.

---

## 5. Safety protocol (hard constraints — every lane)

- **BAR1-via-sysfs is the FIRST check after any wedge/fire** (`/sys/bus/pci/devices/0000:04:00.0/resource`). 256 MB ⇒ broken-BAR1 ⇒ **passive-only until reboot.**
- **NO `nvidia-smi` / MMIO / RPC on a suspected-wedged or broken-BAR1 chip** (cost: 2 reboots, 2026-05-28). **`get-pci-stats.sh` (line 134) and `must-gather.sh` (lines 87-88) both invoke `nvidia-smi`** — use only the passive subset; a `--passive` flag is the right hardening, not a remembered manual strip.
- **Do NOT add `noaer` / `pcie_ports=compat`** to the destructive lane — it silences the very AER signal recovery depends on (Lever L lesson).
- **PMU/instrumentation overhead is an explicit experimental VARIABLE**, never a neutral observer — heavy bpftrace flipped AER-win 1-of-12. Require frame-stability-across-rates before trusting a contained-fire stack.
- **Rung 0 gates everything contained** — never trust "contained, 0-reboot" until A6's schedule line is confirmed on the fire.
- TTY isolation, `sync -f` fsync'd progress markers, sysrq armed, harness hard-timeout (≤10 s) before any destructive run. n≥3 to resolve, n=1 is a lead.

---

## 6. Scope / role question

The realistic destination (Mode-B precedent, OA-MODEB-1; #979 open with no NVIDIA response in 5 months): the **chip-side** cause of why the GSP won't boot/reply on a userspace-recovered chip likely stays OPEN — it reaches into GSP-firmware/TB-tunnel/silicon the project cannot instrument. The project's contribution is **host-side containment (A6) + a precise upstream characterization**, mirroring how P3 contains Mode B without curing it. Rung 9 decides cure-vs-contain on the evidence rather than assuming the answer (avoiding the inverted premature-success scar of declaring "NVIDIA's territory" too early).

**Genuine open confidence gaps (cannot close chip-free):** the exact wedge SITE (Rung 4 should close it); the unperturbed AER-win rate (confounded by the instrument that measures it — Rung 8 CPU-isolation is the least-bad lever); whether the GSP would *ever* reply if waited longer (worker leaked at A6 timeout); the BAR0 mailbox/heartbeat offsets (Rung 6 `*(reg)`, #979 detail).

---

## 7. Recommended first move

**Run LANE 1 (Rungs 0-3) — it is entirely chip-free, zero-reboot, zero-thermal, reads only archived logs + sysfs + config-space, and can ELIMINATE entire hypotheses (and the recipe ambiguity) for free.** Rung 0 in particular is a prerequisite for safely entering the contained lane. Nothing in Lane 1 touches the production GPU. Lanes 2-3 are gated on Lane 1's outcomes and on a separate go.

## Cross-refs

- SH series (resolved): `shutdown-hang-ledger.md`, `experiments/SH-2-eBPF-register-identity.md` (the PMU-not-kprobe method; the init-stack lead — note it is *shutdown-arm* evidence).
- Handover: `session-handover-2026-05-30.md` (two-arm table, original #282 intent).
- F40 catalog: `fake-5090/failure-modes/F40-rmshutdownadapter-incomplete-init-wedge.md` (Test B v2 / FULLPRE / sentinel / n=4 recipe).
- A6 intent: `docs/patch-intents/A6-f40b-bounded-wait-open.md`.
- Upstream: NVIDIA bug #979 (`project_issue_979_upstream_state_2026_05_22`).
- Design provenance: 7-agent chip-free workflow (map → synthesize → adversarial critique), 2026-05-30.
