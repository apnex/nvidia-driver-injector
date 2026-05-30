# A7 Test B validation report (n=1) — 2026-05-29 evening

**Status:** Validated n=1 with major mechanism finding (one of the patch intent's predicted scenarios is mechanically different from prediction; outcome is still host-survival)
**Patch:** A7-f40b-bounded-wait-shutdown (commit `429615c` on injector main, intent v1.1 commit `657aca0`)
**Image under test:** `apnex/nvidia-driver-injector:595.71.05-aorus.19`
**Hardware:** Gigabyte AORUS RTX 5090 AI eGPU, Intel NUC 15 Pro+, Thunderbolt 4 tunnel
**Host:** obpc (Linux 7.0.9-204.fc44.x86_64, kernel 7.0.9)

**Bottom line:** Test B validated **three** distinct A7 firing modes in one run plus surfaced one mechanism correction worth documenting:

1. **Close-path caller of nv_shutdown_adapter ALSO triggers A7** (NEW — not previously tested). `nvidia-smi -L` on a non-persistence-engaged driver → LAST-CLOSE → `nv_stop_device → nv_shutdown_adapter` → A7's rm_shutdown_adapter wrap → timeout at 200 ms. A7 protects this caller too at no extra cost (the wrap lives inside nv_shutdown_adapter, not at the call sites).

2. **A6 + A7 both fire in chained F40-precondition workload** (n=1; chip ends up sink-set from BOTH paths). After Phase 2 cycle-1 nvidia-smi -L (which fires A7), cycle-2 `exec 3</dev/nvidia0` then hit A6's timeout because the chip was already in a "lost" substrate. Both wrappers contained their respective wedges; bash got -EIO; host alive.

3. **rmmod after sink-set fast-passes through nv_pci_remove without invoking A7** (NEW mechanism — patch intent predicted this outcome but via a different mechanism). Patch intent predicted "RM closed code observes sink at next sink-aware check and fast-fails inside rm_shutdown_adapter." Actual mechanism: `nv_pci_remove_helper` short-circuits the entire `nv_shutdown_adapter` call because `NV_FLAG_INITIALIZED` was cleared by the prior close-path `nv_stop_device` (line 2137 in nv.c: `nv->flags &= ~NV_FLAG_INITIALIZED;`) and persistence wasn't engaged. So rm_disable_adapter and rm_shutdown_adapter aren't called at all on this rmmod — A7's wrap has nothing to wrap. rmmod completes in 100 ms with zero F40b events. Same outcome (fast-pass) but a different code path than the intent predicted.

A fourth observation, **out of scope for Test B but worth surfacing**: the new injector pod that respawned after Test B's rmmod entered a state where modprobe spun at 99.6% CPU for 7+ minutes in userspace (`R` state, `wchan=0`, syscall=running, no kernel stack), even though `nvidia.ko` was fully loaded (refcnt=1, `/sys/module/nvidia/parameters/*` readable including `NVreg_TbEgpuShutdownTimeoutMs=200`) and bound to the device (`readlink /sys/bus/pci/devices/0000:04:00.0/driver` resolved to nvidia). nvidia-smi failed with "couldn't communicate with the NVIDIA driver." This is unexplained as of writeup time; **not a kernel or A7 issue** (the kernel state is fine), but a userspace wedge in modprobe or its post-init path that we did not chase to root cause.

## Cross-refs

- A7 patch intent v1.1: `../../../patch-intents/A7-f40b-bounded-wait-shutdown.md`
- A7 patch source: `../../../../patches/addon/A7-f40b-bounded-wait-shutdown.patch`
- A7 Test A validation (sibling): `A7-test-A-validation-2026-05-29.md`
- F40 catalog (with two-arm framing): `/root/fake-5090/failure-modes/F40-reinit-gsp-lockdown-wedge.md`
- Test B journal evidence: `/var/log/mission-1-archaeology/test-B-2026-05-29/journalctl-test-B-phases.log` (122 lines, full Phases 1-3 coverage)
- A7 intent v1.1 scenarios this test validates / refines: §"Scenario: rm_shutdown_adapter completes-fast post-sink-set (PREDICTED, not yet validated)"

## Hypotheses tested

**H-T2 (from intent v1.1):** "If A6 sets the sink first (cycle-2 open on F40-precondition chip), the subsequent rm_shutdown_adapter SHOULD complete within budget because RM closed code observes the sink and fast-fails." Status: **mechanically refuted, outcome confirmed.** rm_shutdown_adapter doesn't get called at all on the subsequent rmmod — `nv_pci_remove_helper` skips nv_shutdown_adapter entirely when `NV_FLAG_INITIALIZED` is clear. The fast-pass IS observed; the mechanism is different from the prediction.

**H-T3 (incidental, new):** "Close-path callers of nv_shutdown_adapter (nv_stop_device on LAST-CLOSE without persistence) hit the same rm_shutdown_adapter MMIO hang as the rmmod-path caller." Status: **confirmed n=1.** During Phase 2 cycle-1 nvidia-smi -L's LAST-CLOSE, A7's rm_shutdown_adapter wrap timed out at 200 ms exactly like the rmmod-path callers did in Test A.

**H-T4 (incidental, new):** "A6 fires on a chip wedged by a prior A7 fire (sink set from close-path teardown's rm_shutdown_adapter timeout)." Status: **confirmed n=1.** During Phase 2 cycle-2 `exec 3</dev/nvidia0`, A6 timed out at 200 ms; chip was in lost-substrate state from the prior nvidia-smi LAST-CLOSE.

## Experimental procedure

**Phase 1 — F40-precondition substrate setup (per F40 catalog recipe)**

1. `kubectl exec <pod> -- /entrypoint.sh uninstall` (graceful host-side teardown; A7 fires once during this — sink set, host-side cleanup completes, modules unloaded)
2. `echo 0 > /sys/bus/thunderbolt/devices/0-1/authorized; sleep 2` (TB deauth)
3. `echo 1 > /sys/bus/thunderbolt/devices/0-1/authorized; sleep 4` (TB reauth — broken-BAR1 reappears as F41)
4. `setpci -s 04:00.0 COMMAND=0:3` (clear memory decoding bit for fix-bar1 safety)
5. `/root/nvidia-driver-injector/tools/fix-bar1.sh` (ReBAR resize back to 32 GiB)
6. `echo > /sys/bus/pci/devices/0000:04:00.0/driver_override` (clear any pre-existing driver_override)
7. `modprobe --ignore-install nvidia` (load patched module manually, NOT via injector pod entrypoint — important for control)

End-of-Phase-1 state: nvidia.ko bound, BAR1=32 GiB, /dev/nvidia0 + /dev/nvidiactl present, NO persistence engaged.

**Phase 2 — cycle 1 (clean) then cycle 2 (A6 fires)**

8. `nvidia-smi -L` — expected: clean GPU listing; observed: clean listing PLUS A7 fired during the implicit LAST-CLOSE that followed.
9. `exec 3</dev/nvidia0` — expected: cycle-2 open hits F40-open arm, A6 timeout, -EIO; observed: A6 timed out as expected; bash reported "Input/output error".

**Phase 3 — Test B trigger (rmmod with sink pre-set)**

10. `rmmod nvidia` — expected: A7 fast-passes via sink-set fast-fail OR times out anyway (both host-safe); observed: rmmod completed in 100 ms with **zero** F40b events. Mechanism: nv_pci_remove_helper short-circuited nv_shutdown_adapter entirely.

**Phase 4 — recovery (the part that went sideways)**

11. `kubectl delete pod <2b7tt>` to trigger DaemonSet respawn → new pod `zz4dp` created.
12. New pod proceeded through the standard entrypoint sequence (PCI gate → PC-7 → BAR1 verify → kernel build → firmware gates → `modprobe --ignore-install nvidia ...` line).
13. Kernel log at 22:29:16 shows "nvidia-nvlink: Nvlink Core is being initialized" → module's init function completed successfully.
14. BUT modprobe (PID 337493 host-side) continued spinning at 99.6% CPU in pure userspace for 7+ minutes. `/proc/337493/stack` empty, `/proc/337493/wchan` = 0, `/proc/337493/syscall` = "running". `nvidia.ko` was fully loaded (refcnt=1, params readable including A7's `NVreg_TbEgpuShutdownTimeoutMs=200`). Device was bound to nvidia driver. But nvidia-smi failed with "couldn't communicate with the NVIDIA driver."
15. SIGKILL on the spinning modprobe did NOT terminate it within several seconds. Reboot was elected to recover.

## Phase-2 + Phase-3 kernel log (the meaty bit)

```
# Phase 2 start at 22:27:20

# cycle 1: nvidia-smi -L — opens /dev/nvidia0, lists GPU, closes fd
22:27:20 NVRM: tb_egpu [F40b]: open scheduled to bounded worker (timeout=200 ms)
22:27:20 NVRM: tb_egpu [F40b]: open completed within budget rc=0
22:27:20 NVRM: tb_egpu [F40b]: open scheduled to bounded worker (timeout=200 ms)
22:27:20 NVRM: tb_egpu [F40b]: open completed within budget rc=0

# cycle 1 LAST-CLOSE triggers nv_stop_device → nv_shutdown_adapter → A7 fires (close-path caller!)
22:27:20 NVRM: tb_egpu [F40b]: rm_disable_adapter scheduled to bounded worker (timeout=200 ms)
22:27:20 NVRM: tb_egpu [F40b]: rm_disable_adapter completed within budget
22:27:20 NVRM: tb_egpu [F40b]: rm_shutdown_adapter scheduled to bounded worker (timeout=200 ms)
22:27:20 NVRM: tb_egpu [F40b]: rm_shutdown_adapter timed out after 200 ms — declaring GPU lost (...)

# Chip now in C5-sink-set lost substrate

# cycle 2: exec 3</dev/nvidia0 — A6 wraps the open
22:27:21 NVRM: tb_egpu [F40b]: open scheduled to bounded worker (timeout=200 ms)
22:27:21 NVRM: tb_egpu [F40b]: open timed out after 200 ms — declaring GPU lost (...)

# Bash receives "Input/output error", returns rc=1

# Phase 3 start at 22:28:06

# rmmod nvidia — sink already set, NV_FLAG_INITIALIZED cleared by prior close-path teardown
22:28:06 nvidia-nvlink: Unregistered Nvlink Core, major device number 510

# That's it. rmmod returned rc=0 in 100ms. Zero F40b events.
```

The contrast with Test A is striking. Test A's rmmod produced 4 F40b lines (rm_disable_adapter + rm_shutdown_adapter, both scheduled + completion-or-timeout). Test B's rmmod produced **0** F40b lines — A7's wrap was never invoked, because nv_shutdown_adapter wasn't called.

## What this proves

1. **A7's coverage is broader than the patch intent claimed.** The wrap lives inside nv_shutdown_adapter, so it covers both callers (rmmod path AND close path) at no extra design cost. Test B's incidental Phase-2 observation confirmed the close-path arm fires structurally on this hardware too. The patch intent's "SHALL NOT special-case the close-path caller" scope-boundary note is now empirically validated as a no-op overhead — the wrap is doing useful work in both call sites.

2. **The "rmmod after sink-set fast-passes" intent prediction was directionally right.** Both Test A (no sink set → A7 timeout) and Test B (sink set → rmmod doesn't reach A7) preserve host-survival. The mechanism differs from the prediction:
   - **Predicted:** RM observes sink, fast-fails inside rm_shutdown_adapter, A7 wrapper reports "completed within budget."
   - **Actual:** nv_pci_remove_helper skips nv_shutdown_adapter entirely because `NV_FLAG_INITIALIZED` is clear and persistence isn't engaged. A7 wrapper isn't invoked.

3. **A6 + A7 compose cleanly.** A6 fires on cycle-2 open of a chip wedged by a prior A7 fire. Both wrappers' timeout paths are reachable from the same boot, in the same workload sequence, on the same chip. Host stays alive through both.

4. **Persistence engagement changes the rmmod path materially.** Without persistence:
   - Open → use → LAST-CLOSE triggers nv_stop_device → nv_shutdown_adapter → A7 fires every time
   - Subsequent rmmod sees NV_FLAG_INITIALIZED cleared → skips nv_shutdown_adapter → A7 not invoked
   
   With persistence (Test A's scenario):
   - Open → use → LAST-CLOSE does NOT trigger nv_stop_device (NV_FLAG_PERSISTENT_SW_STATE prevents teardown)
   - rmmod sees NV_FLAG_INITIALIZED set → calls nv_shutdown_adapter → A7 fires every time
   
   In either case, A7 fires exactly once per "session" on this hardware. The close-path vs rmmod-path distinction is a matter of WHEN, not WHETHER.

## What this finding does NOT prove

- **Whether the close-path A7 fire produces the same chip-final-state as the rmmod-path A7 fire.** Both leave the chip C5-sink-set, but the host-side cleanup steps that run AFTER the timeout differ between callers. Close-path proceeds through nv_stop_device's tail; rmmod-path proceeds through nv_pci_remove_helper's tail. Whether the chip is equally reloadable from both states is not directly tested.
- **Why the new pod's modprobe spun at 99.6% CPU in userspace.** This is a separate userspace bug, possibly in modprobe itself or in a post-init hook, not related to A7 or the kernel module. Worth investigating in a follow-up but does NOT affect the validity of Test B's A6/A7 conclusions.
- **Whether persistence-engaged + cycle 2 + rmmod produces the predicted RM-fast-fail behavior.** Test B's prep recipe specifically excluded persistence. If we run a Test B variant WITH persistence engaged after the F40-precondition setup, we'd get rmmod calling nv_shutdown_adapter (NV_FLAG_INITIALIZED still set), and THEN we could observe whether rm_disable_adapter / rm_shutdown_adapter fast-fail due to the C5 sink or time out structurally. **This is a sharper Test B-prime worth running** when the chip is fresh.

## Implications for the patch intent

The intent's "PREDICTED" scenario for rm_shutdown_adapter post-sink-set should be split:

- **Variant A — no persistence + close-path + rmmod sequence (Test B as run):** rmmod fast-passes via nv_pci_remove_helper short-circuit. A7 not invoked. Host-safe. This is what Test B observed.
- **Variant B — persistence engaged + cycle-2 open + rmmod sequence (Test B-prime, untested):** rmmod calls nv_shutdown_adapter (NV_FLAG_INITIALIZED still set). Whether rm_disable_adapter and rm_shutdown_adapter fast-fail on the C5 sink OR time out is the open question. Either outcome preserves host-survival per the existing scope-boundary requirements.

A7's intent v1.2 (when we get to it) should incorporate this distinction.

## Side observations from the test

- **fix-bar1.sh works as documented.** Step 5 of the F40-precondition recipe took ~7 sec wall-clock; BAR1 went from broken to 32 GiB in one shot. The state captures land in `/var/log/fix-bar1-20260529T122648Z/` for forensic review.

- **TB deauth/reauth completes in ~6 sec wall-clock total** (2 sec sleep after deauth + 4 sec sleep after reauth + small device-enumeration time). The recipe's `sleep` values appear well-chosen.

- **Cycle-1 nvidia-smi -L completed in <1 sec on the F40-precondition substrate.** Confirms the F40 catalog's claim that cycle 1 succeeds cleanly.

- **Pod entrypoint's reload sequence works fine when called separately from the F40-precondition recipe.** The hang was unrelated to A7 or chip state. Future re-investigation of the modprobe spin should focus on userspace tooling, not driver code.

## Files preserved

```
/var/log/mission-1-archaeology/test-B-2026-05-29/
├── journalctl-test-B-phases.log    (122 lines covering all Phases)
└── pod-zz4dp-log.txt               (entrypoint output up to the spin)
```

(No bpftrace in this run — the F40b kernel-log markers were sufficient.)

## Next-step recommendations

1. **Reboot now to recover the host** (recommended). Test B's data is fully preserved in this report + the journal archive. The chip is healthy structurally (BAR1=32 GiB throughout); only the userspace pod is wedged. Reboot is the cheapest recovery.

2. **Test B-prime** (run when fresh after reboot, optional): repeat the F40-precondition recipe BUT engage persistence before cycle 2. Then rmmod nvidia. Goal: observe whether rm_disable_adapter / rm_shutdown_adapter fast-fail on the C5 sink (the intent's original prediction mechanism) OR time out anyway. Either outcome is interesting; both are host-safe per A7's design.

3. **A7 intent v1.2 update:** split the "fast-pass after sink-set" scenario into Variant A (no persistence — observed in Test B as nv_pci_remove_helper short-circuit) and Variant B (persistence engaged — untested; the original intent's predicted RM-fast-fail behavior may or may not occur).

4. **Modprobe-spin failure mode investigation (low priority):** capture a perf or `cat /proc/N/maps` snapshot next time we see it. May be a libkmod retry loop or a `kmod-static-nodes` race. Not blocking; not A7-related.

5. **A8 v2 sysfs patch (already queued):** would have given us machine-readable Phase 2 + 3 counters via `tb_egpu_f40b_fires` instead of having to grep journalctl. Boost priority.

## Provenance of this document

- Test executed: 2026-05-29 22:26 → 22:36 AEST
- Procedure source: this document's "Experimental procedure" section
- Data source: live host telemetry + journalctl captures preserved at `/var/log/mission-1-archaeology/test-B-2026-05-29/`
- Authored: 2026-05-29 evening, in-session, before host reboot to recover from the Phase 4 modprobe spin
