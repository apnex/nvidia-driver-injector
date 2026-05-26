# E07 — Cable replug WITH drain-first protocol

**Status:** RE-EXECUTED 2026-05-26 (wedge, n=2 of 2 different outcomes)
**Sub-mission:** A (cable hot-plug/unplug) — also informant for Sub-mission C (unexpected disconnect)
**Phase:** Mission-level (not Phase 2 archaeology, but referenced from Phase 2 docs)
**Risk:** **HIGH — verified wedge mode under sub-cycle-5 conditions**
**Cost:** ~2 min for cable cycle + forced reboot to recover (~5 min) if wedge fires
**Reversibility:** **REBOOT REQUIRED** (forced reboot empirically necessary)
**Last updated:** 2026-05-26

## Hypothesis (mission-level)

H1 (mission doc): Cable replug at the NUC side, with workload drained, will produce a clean transition into broken-BAR1 state (BAR1=256M instead of 32G) without driver wedge. Recovery requires reboot.

**Status after 2 runs: H1 PARTIALLY FALSIFIED.**

- Cable replug *does* produce broken-BAR1 state on the PCI bus
- Cable replug does NOT cleanly leave the driver in a recoverable state — under sub-cycle-5 conditions (NVIDIA device plugin running + persistence engaged), surprise-removal fires Xid 79 + Xid 154 and the driver wedges silently within ~3 minutes
- "Drain-first" needs sharper definition: drained vLLM is necessary but not sufficient

## Falsification gates (mission-level)

**PASS (mission perspective):** GPU returns to 32GiB BAR1 on cable replug. Would indicate hot-plug allocation works correctly.

**FAIL (mission perspective):** GPU returns at 256M BAR1 → confirms Linux hot-plug allocation falls back to default (this is the MISSION-1 problem class).

**WEDGE (a third outcome we did not predict, but observed):** Driver enters terminal state (Xid 154), kernel deadlocks within minutes, requires forced power-cycle to recover.

## Run 1 — 2026-05-25 (original; "clean FAIL")

**Conditions:**
- Driver: aorus.14
- Device plugin: not yet deployed (this was BEFORE sub-cycle 5)
- Persistence: nvidia-smi -pm 1 engaged
- Workload: drained (no vLLM)

**Protocol:**
1. Drain vLLM
2. Cable yank at NUC side, 5s, replug
3. Wait for TB tunnel + boltd auto-authorize

**Result: FAIL — broken-BAR1 state achieved cleanly**
- BAR1: 32G → 256M
- Bridge 03:00.0 prefetchable: 33089M → 288M
- Recovery: host reboot (cold-plug at boot restored 32G)
- Driver did NOT wedge — system remained responsive throughout

**Memory reference:** `project_e7_cable_replug_h1_falsified_2026_05_25.md`
**Archive:** `archive/cable-replug-test-E7-20260525T084717Z/post-test-finding.txt`

## Run 2 — 2026-05-26 (re-execution; SILENT WEDGE)

**Conditions:**
- Driver: aorus.14 (image was aorus.15 with cosmetic-only bump; module reported .14)
- Device plugin: **DEPLOYED** (sub-cycle 5 added nvidia-device-plugin-daemonset NVML-probing every ~30s)
- Persistence: nvidia-smi -pm 1 engaged
- PC-3 heartbeat: active (reads /sys/module/nvidia/version every 30s)
- Workload: drained (no vLLM)

**Protocol (identical to Run 1):**
1. Drain vLLM (already drained)
2. Cable yank at NUC side at 18:08:45
3. boltd auto-authorize did NOT fire; cable was replugged but device stayed in `connected` not `authorized`
4. Manual `sudo boltctl authorize <uuid>` at 18:09:28 to bring device back

**Observed outcome: WEDGE**

Forensic timeline (verbatim from journalctl):

```
18:08:45  thunderbolt: bandwidth consumption changed, re-calculating
          NVRM: Xid (PCI:0000:04:00): 79, GPU has fallen off the bus.
          NVRM: GPU 0000:04:00.0: GPU has fallen off the bus.
          NVRM: _threadNodeCheckTimeout: API_GPU_ATTACHED_SANITY_CHECK failed! (x3)
          NVRM: rcdbAddRmGpuDump: GPU lost, skipping crash dump
          NVRM: Xid (PCI:0000:04:00): 154, GPU recovery action changed from 0x0 (None) to 0x1 (GPU Reset Required)
          NVRM: GPU0 rpcRmApiFree_GSP: GPU lost, returning NV_OK so resource cleanup completes
          NVRM: GPU0 _issueRpcAndWait: GPU lost, returning NV_ERR_GPU_IS_LOST without issuing RPC
          NVRM: GPU0 nvAssertFailedNoLog: Assertion failed: (status == NV_OK) || (status == NV_ERR_GPU_IN_FULLCHIP_RESET) @ kernel_graphics.c:2608
          NVRM: GPU0 _kccuUnmapAndFreeMemory: CCU memdesc unmap request failed with status: 0xf
          NVRM: nvAssertFailedNoLog: Assertion failed: ... @ fecs_event_list.c:1623
          NVRM: nvCheckOkFailedNoLog: ... @ gpu_user_shared_data.c:248
          i915 0000:00:02.0: vgaarb: VGA decodes changed (iGP takes over)

18:08:55  thunderbolt: tb_port_do_update_credits — cable reconnect, TB layer recovering
          boltd: device changed: connected -> connected

18:09:08  get-pci-stats.sh --snapshot ran; system still superficially responsive
          BAR1=256M observed (broken-BAR1 state of FAIL outcome reached)
          Driver state: Xid 154, "Reset Required" — terminal

18:09:28  sudo boltctl authorize <uuid> — GPU placed back into PCI tree
          GPU re-appeared at 04:00.0 with BAR1=256M
          Driver was in "Reset Required" state; could not actually use device

18:09:30  [journalctl stops recording. System silently wedged within ~3 min.]

~18:13    User forced power-cycle reboot.
```

**Critical observation:** There is **no kernel panic, no soft-lockup detection, no hung_task warning, no AER cascade** in the journal. The kernel simply stopped logging. This is the "silent wedge" failure mode characteristic of GPU-state deadlock in driver code paths.

## Patch coverage analysis

| Existing patch | Should have helped? | What actually happened |
|---|---|---|
| C2 (AER internal unmask) | Visibility | ✓ Xid 79 + AER bits surfaced — visibility worked |
| C3 (gpu-lost-retry) | Return errors cleanly | Partial — some RPC sites returned NV_ERR_GPU_IS_LOST (visible in journal); others hit `nvAssertFailedNoLog` (kernel_graphics.c:2608, fecs_event_list.c:1623, gpu_user_shared_data.c:248) instead |
| C4 (err-handlers scaffold) | PCIe error callbacks | NOT invoked — surprise-removal of TB device doesn't fire `pci_error_handlers`; it fires `pci_remove` (different callback path) |
| C5 (crash safety) | No kernel BUG | ✓ Likely prevented hard panic. Silent wedge instead. |
| A2 (Q-watchdog, Mode B detector) | DMA-path freeze | Wrong trigger class — this is surprise-removal, not DMA hang |
| A3 (recovery state machine) | Auto-recover | **NOT triggered.** A3 fires on post-rmInit-FAIL (cold-plug failure). Today's case was Xid 154 mid-session — A3 has no hook for this. |
| A4 (close-path telemetry) | Visibility into fd lifecycle | ✓ Telemetry showed `tb_egpu UVM [CLOSE]: ... fd_count=N` cycling between 1-2 every ~30s — that's the device plugin's NVML probe loop. Confirmed fd holders. |

**Summary: detection worked, recovery did not exist for this class.**

## Driver kernel sites that need patch coverage

Specific call sites observed failing in journalctl (these are the patch landing zones a future fix would need to address):

```
kernel-open/.../kernel_graphics.c:2608           — nvAssertFailedNoLog after GPU lost
kernel-open/.../fecs_event_list.c:1623           — Same
kernel-open/.../gpu_user_shared_data.c:248       — nvCheckOkFailedNoLog after GPU lost
kernel-open/nvidia/nv-pci.c                       — where pci_remove callback would dispatch
kernel-open/nvidia/nv-tb-egpu-recover.c (A3)     — recovery state machine, no Xid 154 hook
kernel-open/nvidia-uvm/*.c                       — NVML/UVM probe paths the device plugin uses
```

What a corrective patch would need to do (early sketch — not a design yet):

1. **Detect** TB unplug at the right layer. Likely insertion: `pci_remove` callback in `nv-pci.c` OR a new hook tied to the existing `is_external_gpu` detection (E1 cluster — see candidate fold below).
2. **Pre-empt the wedge:** before Xid 154 fires terminal-state, mark device dead in driver state. Set a `device_lost_during_active_session` flag.
3. **Short-circuit RPC paths:** the four call sites above currently assert when GPU is lost; under the new flag they should return -ENODEV immediately without RPC attempts.
4. **Force-close all open handles:** all RM/UVM clients holding fds need to be notified; their next syscall returns -ENODEV.
5. **Allow safe re-probe:** on cable reconnect + `boltctl authorize`, the driver should be able to re-init from a clean state without conflicts.

**Patch geometry — early consideration (TBD):**

- **Could fold into E1 (eGPU detection cluster)**: E1 already owns `is_external_gpu` / `RmCheckForExternalGpu` / TB3-era surprise-removal scaffolding. A natural home for TB-disconnect-aware teardown might be extending E1 to be TB4/USB4-aware AND register a pci_remove callback that engages the teardown sequence. This keeps the eGPU concerns in one cluster.
- **OR new core patch (C6)**: If the teardown logic is GPU-generic (not eGPU-specific), it could live as a new Core patch. But the trigger (TB disconnect) IS eGPU-specific, so E1 seems more natural.
- **OR new addon (A6 or extend A3)**: A3 is already the "recovery state machine"; logically the Xid 154 handling could be an A3 extension. Tradeoff: A3 is currently scoped to post-rmInit-FAIL; folding mid-session-failure-recovery widens its scope.

Decision deferred until we have more data points (n≥2 reproductions; the proper E8 with full quiesce; software-initiated remove comparison via E11).

## Open data-collection follow-ups

Today's run produced enough forensic data to START sketching patch design. To complete the design we need:

- [ ] **n≥2 reproductions** of the wedge sequence to confirm the failure mode is deterministic (per `feedback_reliability_methodology`: n≥3 to resolve)
- [ ] **E8 with FULL quiesce** (delete device plugin pod, persistence off, cordon node) — does the wedge still happen with truly idle driver? Distinguishes "surprise-removal triggers Xid 154 inherently" vs "NVML probe race window is the trigger"
- [ ] **E11 (software-initiated remove)** — does graceful kernel-driven remove produce broken-BAR1 without firing Xid 154? Validates patch-design hypothesis that the failure is in surprise-removal-only, not in remove-itself
- [ ] **Sub-mission B test** (eGPU chassis power-cycle while connected) — same class of failure or different?
- [ ] **bpftrace instrumentation** of nv-pci.c during cable yank — exact line-level trace of which function deadlocks (if any of nvidia.ko's functions block indefinitely vs all return). Carefully — per `feedback_observability_perturbs_bug`, this may change the failure mode.

## Cross-references

- `_STARTING-STATE-RECIPE.md` — original recipe assumed drain-vLLM was sufficient; updated post-2026-05-26
- `E08-cable-yank-idle-gpu.md` — H7 control; today's run also informs E08
- `E11-per-function-remove.md` — safer alternative entry to broken-BAR1 state for Section 1+2 testing
- Mission doc Sub-mission C section — H7 status
- Memory: `project_e7_cable_replug_h1_falsified_2026_05_25.md` (Run 1)
- Memory: `feedback_surprise_removal_wedge_class_2026_05_26` (this Run 2 — new)
- Kernel function references: `nv-pci.c`, `nv-tb-egpu-recover.c` (A3), `kernel_graphics.c`, `fecs_event_list.c`, `gpu_user_shared_data.c`

## Forensic bundle

Standardised must-gather bundle preserved at:

```
/var/log/mission-1-archaeology/E07-Run2-wedge/nvidia-injector-must-gather-20260526T083709Z-WITH-WEDGE.tar.gz
(278 KB)
```

Generated via `sudo /root/nvidia-driver-injector/tools/must-gather.sh` after recovery, with the wedge-boot's `-b -1` journal added by hand (script now patched to include `-b -1` and `-b -2` automatically — see commit on apnex/nvidia-driver-injector). Bundle contents include: dmesg-full / dmesg-relevant, journalctl-kernel-prev-boot, lspci-vvv, boltctl, nvidia-smi-q, pc3-state.json, k8s pod/event state, soak metrics CSV. This is the artifact a patch designer would work from.

## Actual result — Run 2 (2026-05-26)

**Status:** FAIL (broken-BAR1 reached) + WEDGE (terminal driver state)

**Date:** 2026-05-26 18:08:45 → 18:09:30 (cable yank → silent wedge)

**Diff highlights from get-pci-stats.sh --diff phase-2-1-prebroken:**

```
GPU 04:00.0 BAR1:               32G → 256M
Bridge 03:00.0 prefetchable:    33089M → 288M
Bridge 02:00.0 prefetchable:    65856M → 288M (cascade through TB tunnel hierarchy)
Driver bound to GPU:            nvidia → (no driver bound after pci_remove)
TB status:                      authorized → connected → (manually re-authorized)
```

**Conclusion:**

The cable replug protocol DOES reach the FAIL state (broken-BAR1) the mission targeted — confirming H1's Linux PCIe hotplug fallback allocation hypothesis is reachable. HOWEVER, in our current post-sub-cycle-5 environment the path to that state is unsafe: surprise-removal during active NVML probing fires Xid 79+154 cascade that the existing patch series detects (visibility ✓) but does not recover (no hook for Xid-154-mid-session). Recovery requires forced power-cycle.

This is exactly the kind of data the mission's testing matrix is supposed to surface — an unmapped failure class with concrete kernel-site evidence pointing at where a corrective patch needs to live (likely an E1 extension covering pci_remove + RPC-path short-circuiting, scope TBD with more data points).
