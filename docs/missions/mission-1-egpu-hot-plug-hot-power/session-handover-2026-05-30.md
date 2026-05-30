# MISSION-1 session handover — 2026-05-30

**Purpose:** Complete state snapshot for a fresh session to resume without context loss. This session resolved the F40 **shutdown arm** end-to-end and is poised to open the **open arm** (#282).

## TL;DR — what to know walking in

1. **The shutdown arm (A7 / `rm_shutdown_adapter`) is fully RESOLVED.** It was never a hang — it completes in ~600 ms (a GSP RM-unload RPC). A7's old 200 ms budget was guillotining it; the "20:52 forensics" that supposedly originated A7 didn't even have A7 in the build. Fixed: budget → 1200 ms + a `flush_work` UAF guard. Both **live-validated**.
2. **Series renamed `aorus` → `apnex`. Live driver is `apnex.23`.** Driver version string now == image tag (the recurring confusion is gone). version.mk drives it (A5 patch); the entrypoint auto-derives the firmware symlink from modinfo.
3. **Fork branches PUSHED** to `github.com/apnex/open-gpu-kernel-modules` (a5 force-with-lease under the carve-out; a6/a7/a8 new). All carve-out conditions verified.
4. **A8 sysfs observability works** (v2/v2.1): the 5 `tb_egpu_*` attributes materialize (v1's `dev_groups` was clobbered by `__pci_register_driver`).
5. **The NEXT work is #282 — the OPEN arm (RmInitAdapter)**, the *genuine* wedge. We were about to run a chip-free design/scoping workflow to fully define its hypotheses + experiment ladder (the user wants experiments/hypotheses fully defined before any chip work). **That workflow was NOT run — it's the immediate next step.**
6. **Method breakthrough this session:** the closed RM (`nv-kernel.o`, 0 `endbr64`) is **NOT kprobe-able on `CONFIG_X86_KERNEL_IBT=y`** — use **PMU sampling** (`bpftrace profile:hz` capturing `kstack`), which is breakpoint-free and symbolizes RM frames via kallsyms. This is how SH-2 was solved and is the method for #282.

## Current host + cluster state

```
Driver:                 595.71.05-apnex.23  (C1-C5 + E1 + A1-A8; A7 budget=1200ms + flush guard; A8 v2.1)
                        /sys/module/nvidia/version == 595.71.05-apnex.23 == image tag == node label
GPU:                    healthy, ~33C, P8, persistence Enabled, BAR1 32 GiB
A8 sysfs:               /sys/bus/pci/devices/0000:04:00.0/tb_egpu_{state,f40b_fires,recovery_count,recovery_failures,last_recovery_ns} all present
                        state=healthy, f40b_fires=0 after a clean bring-up
Pod:                    nvidia-driver-injector-<...>, 1/1 (image apnex.23)
A7 shutdown budget:     NVreg_TbEgpuShutdownTimeoutMs=1200 (was 200)
A6 open budget:         NVreg_TbEgpuOpenTimeoutMs=200 (UNCHANGED — A6 contains the GENUINE open-arm wedge)
Fork (local==origin):   c1-c5,e1,a1-a4 unchanged; a5 (version apnex.23) force-pushed; a6/a7/a8 pushed new
```

## The big result — F40 is TWO mechanistically-OPPOSITE arms

| | **OPEN arm** (A6 / `RmInitAdapter`) | **SHUTDOWN arm** (A7 / `rm_shutdown_adapter`) |
|---|---|---|
| Chip responds to MMIO? | **NO** (dead for init) | **YES** (answers every read) |
| PCIe CTO / AER? | **YES** — `UESta=0x4000` (Test B v2 caught it 1-of-12; 11 wedged) | **NO** — AER stays 0 |
| Mechanism (SH-2 PMU) | GSP **init** RPC never replies (GSP dead): `kgspBootstrap_GH100 → kgspWaitForRmInitDone_IMPL → _kgspRpcRecvPoll → _issueRpcAndWait` | GSP **unload** RPC replies in ~600 ms: `kgspUnloadRm_IMPL → _issueRpcAndWait → _kgspRpcRecvPoll` |
| Outcome | genuine wedge, n=13 reboots | completes ~600 ms |
| Real failure? | **YES** — A6 genuinely needed | **NO** — A7's 200 ms was just too tight |
| Status | **OPEN (#282)** | **RESOLVED** |

**Same GSP-RPC-poll mechanism, opposite outcome.** That's the key insight bridging SH-2 → #282.

## What shipped this session (git log on injector `main`)

- `7abd83a` A8 v2 — sysfs via `sysfs_create_group` (v1 `dev_groups` was NULL-clobbered by `__pci_register_driver`)
- `b218a6c` A8 v2.1 — shutdown-path fire counts but does NOT strand `tb_egpu_state` (teardown variant `nv_tb_egpu_f40b_fired_teardown`)
- `4cbfa92` SH-1 — rm_shutdown completes ~600 ms (n=3); 200 ms budget was 3× too tight
- `cb8943e` A7 budget 200→1200 + series rename aorus→apnex.22
- `d52a035` A7 SH-3 UAF guard (`flush_work` in timeout branch) + apnex.23
- `7a26455` SH-3 RESOLVED — guard validated (worker joined, no zombie)
- `00901b2` SH-2 RESOLVED via PMU sampling — ~600 ms is the GSP unload RPC
- `7932226` v5-queue note: A7 leak→join lifecycle + does-A7-shutdown-need-to-exist
- daemonset.yaml → apnex.23; all SH docs in `experiments/` + `shutdown-hang-ledger.md`

## SH series — fully closed (see `shutdown-hang-ledger.md`)

- **SH-1** (close-path, n=3): rm_shutdown completes 612/600/611 ms; worker R-state CPU-pegged, AER clean (chip alive). Budget guillotine, not a hang.
- **SH-3 gate** (4-agent chip-free): real latent **double-UAF** on rmmod-path *timeout* (leaked worker on shared `system_long_wq`, no module ref, no unload-flush → `free_module` frees `.text`/`nvl` under the running worker). 1200 ms narrows not closes it. **20:52 wedge ≠ this** (A7 not in that build; +10 s timing = new pod's container setup).
- **A7 UAF guard**: `flush_work(&w->work)` after sink-set in the timeout branch. `try_module_get` ineffective (worker queued after `delete_module`'s refcount gate). Validated by a forced 100 ms close-path timeout: worker joined, no zombie.
- **SH-3 Rung-1** (n=1): rmmod-path rm_shutdown ~649 ms within budget — no timeout, no UAF.
- **SH-2** (PMU sampling): the ~600 ms = GSP unload RPC round-trip; not reducible by us; sink not consulted (the RPC-wait loop isn't sink-aware). kprobe was IBT-blocked → PMU sampling is the method.

## #282 — OPEN ARM — the immediate next step (NOT yet started)

We were about to run a **chip-free design/scoping workflow** (the script was rejected by the user to do this handover first). Its intent — re-run it or do equivalent:
- **5 mapping angles:** (1) consolidate ALL prior open-arm evidence (WPR2 mechanism, IOMMU/DMAR, Gen3 signal integrity, the AER-vs-deadlock race stats, n=13 reproductions); (2) the OPEN GSP-init source path (`kgspInitRm_IMPL/kgspBootstrap_GH100/kgspWaitForRmInitDone/_kgspRpcRecvPoll`, WPR2 setup, fw load) + where the wedge sits; (3) FULLY-DEFINED falsifiable hypotheses (H-OA1..N); (4) observability surface under IBT + the perturbation caveat; (5) trigger + safety + experiment-ladder constraints.
- **Then synthesize:** the open-arm ledger + hypotheses + experiment ladder (cheapest-first: chip-free + contained-nondestructive BEFORE uncontained-destructive) + scope.

**Leading hypothesis for #282:** the open-arm wedge is the GSP **init** RPC never completing on a userspace-recovered chip (GSP not booted/dead → `_kgspRpcRecvPoll` never gets a reply → the read CTOs → AER `0x4000`). Same path SH-2 saw for the unload, opposite outcome.

**Critical #282 constraints (must design around):**
- **Destructive:** every genuine uncontained wedge = reboot (n=13). A6 (`NVreg_TbEgpuOpenTimeoutMs=200`) CONTAINS it (→ -EIO, host survives) — so the **non-destructive lane** studies the *contained* fire (repeatable); the **destructive lane** (set `NVreg_TbEgpuOpenTimeoutMs=0` to disable A6) reproduces the genuine wedge → reboot.
- **Observability perturbs the bug:** the AER-vs-deadlock race is timing-sensitive — heavy instrumentation made AER WIN once (Test B v2's 1-of-12). PMU sampling overhead is a *variable*; passive > active; timeout the harness; fsync'd markers; sysrq armed; BAR1-via-sysfs-FIRST post-wedge (no nvidia-smi/MMIO on a suspected-wedged chip).
- **Trigger:** F40-precondition substrate (uninstall + TB deauth/reauth + fix-bar1 + modprobe no-persistence + cycle-1 + cycle-2). Recipe in the F40 catalog.
- **Method:** PMU sampling (`bpftrace profile:hz` kstack), NOT kprobe (IBT/closed-RM).

## Task list (live)

- **#282 OPEN** (in_progress) — open-arm forensics; description has the SH-2 lead + method + open Qs.
- #274 Test B-prime — DEFERRED (superseded by SH-1/SH-3 understanding; re-evaluate if ever needed).
- Done this session: #273 (A8 v2), #275 (A8 intent v2), #276 (A8 v2.1), #277 (SH-1 gate b), #278 (SH-1), #279 (budget fix), #280 (SH-2), #281 (SH-3).

## Deferred / parked

- **v5 deep review** (`architecture-v5-deep-review-queued.md`): the A7 "leak→join lifecycle + does-A7-shutdown-need-to-exist" question (SH-1 suggests A7-shutdown may be *deletable*, not just simplifiable — decide with #282 data); plus the standing F40-family consolidation items.
- **SH-2 register offsets** (genuinely minor): the exact BAR0 offsets of the GSP mailbox/heartbeat regs — fold into the upstream #979 report; `perf annotate` (perf not installed) or PMU `*(reg)` reads if ever needed.
- **a5 commit-message tidy** (cosmetic): the a5 commit *body* says "apnex.22" while version.mk is apnex.23 — fix on a future natural a5 touch (not worth a standalone rebase cascade).
- **Soak apnex.23** (production-migration ≥14 days).
- **Upstream:** #979 follow-up — the open-arm + the GSP-RPC characterization are upstream-report-grade once #282 lands.

## Key reusable method/discipline notes from this session

- **PMU sampling, not kprobe, for the closed RM on IBT kernels** (the big one). `bpftrace profile:hz:N { @[kstack]=count(); }` symbolizes RM frames; kprobe EINVALs (no endbr64 in the precompiled blob).
- **Single-datapoint inferential overreach** bit again: I declared SH-2 "blocked" from ONE failed mechanism (kprobe). The user caught it; PMU sampling was the path. Enumerate the solution space before declaring a block.
- **Premature-success discipline held** elsewhere (n≥3, live-validate fixes, deploy-and-verify caught the A8 v2.1 stale-state bug that static review missed).
