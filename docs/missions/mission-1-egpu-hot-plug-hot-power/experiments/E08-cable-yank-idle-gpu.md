# E08 — Cable yank on IDLE GPU (H7 control)

**Status:** PARTIAL DATA ONLY (2026-05-26 today's E07 doubles as informant)
**Sub-mission:** C — informant control for H7
**Phase:** Mission-level
**Risk:** **HIGH — verified wedge mode if "idle" definition is incomplete**
**Cost:** ~2 min for cable cycle, ~5 min for full pre-test quiesce, + forced reboot if wedge
**Reversibility:** likely REBOOT REQUIRED (per E07 Run 2 evidence)
**Last updated:** 2026-05-26

## Hypothesis

**H7 (mission doc):** "Cable yank on truly idle GPU — does surprise removal alone trigger Xid 154, or does compute participate?"

Two competing sub-hypotheses to discriminate:

- **H7a:** Xid 154 fires on ANY cable yank, regardless of whether the driver is currently doing compute. Surprise-removal is inherently unsafe at the kernel-driver level.
- **H7b:** Xid 154 only fires when there is an active driver session (open fd, in-flight RPC, NVML probe, CUDA kernel). With a *truly* idle driver — no opens, no probes — surprise-removal can be processed cleanly via `pci_remove`.

The H7a/H7b distinction is critical for patch design: if H7a, we need a defensive layer that prevents Xid 154 from terminal-state regardless of input. If H7b, we need to ensure the driver enters a "deep quiet" state that survives cable yank.

## Falsification gates

**For H7a (surprise-removal alone is sufficient):** Cable yank on FULLY quiesced driver (no device plugin, no persistence, no opens, no probes) still fires Xid 154 → recovery wedge.

**For H7b (active session is necessary):** Cable yank on FULLY quiesced driver does NOT fire Xid 154 → driver re-binds cleanly on replug.

## Run 1 — 2026-05-26 (PARTIAL — same event as E07 Run 2)

**Conditions:**
- Workload: drained (no vLLM) ✓
- nvidia-device-plugin: **RUNNING** (NVML-probing every ~30s) ✗ — not idle
- nvidia-smi -pm 1 persistence: **ENGAGED** ✗ — not idle
- PC-3 heartbeat: **ACTIVE** (reads /sys/module/nvidia/version every 30s) ✗ — not idle

This run does NOT cleanly test H7 because the GPU was NOT truly idle. The device plugin's NVML open + persistence-engaged kernel state both count as active driver session.

**Result:** WEDGE (see E07 for full forensics).

**What this run DOES inform about H7:**

- "No vLLM" alone is not "idle" — confirmed
- NVML probes from the device plugin (open + query + close every 30s) are sufficient to keep the driver in "session" mode where surprise-removal fires Xid 154
- Therefore: H7b is still viable (it's possible that a TRULY quiesced driver would survive) — but we have NOT proven it. We've only proven that the trivial drain (vLLM-only) is insufficient.

## Run 2 — PENDING (proper E8 with full quiesce)

**Required pre-conditions for a valid H7 test:**

1. **No vLLM workload** — `kubectl scale -n vllm deployment/vllm --replicas=0; kubectl wait --for=delete pod ...` (already standard)
2. **Cordon node** — `kubectl cordon obpc` (prevents new GPU-consuming pods from scheduling)
3. **Delete device plugin pod** — `kubectl delete pod -n kube-system nvidia-device-plugin-daemonset-szwbn`. With node cordoned, won't reschedule.
4. **Stop PC-3 heartbeat** — easiest: `kubectl delete pod -n kube-system nvidia-driver-injector-*` (DaemonSet has OnDelete strategy, won't auto-recreate)
5. **Disengage persistence** — `nvidia-smi -pm 0` directly on host (before container removal so we have nvidia-smi available). Alternatively: in the container before deletion.
6. **Verify NO open fds to /dev/nvidia*** — `lsof /dev/nvidia* 2>/dev/null` should be empty
7. **Optional: rmmod nvidia chain** to ensure ZERO driver session — but loses ability to observe Xid behavior (no driver to fire Xid). Trade-off: rmmod variant tests "is TB unplug clean at PCI layer alone?" — different but useful.

**Protocol after quiesce:**

```bash
# Pre-yank state capture
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E08-quiesced
# Verify quiesce
sudo lsof /dev/nvidia* 2>&1 | wc -l   # expect 0
cat /sys/module/nvidia/refcnt          # ideally 0 (no users) or just the bare nvidia/nvidia_uvm reference
```

User action: cable yank at NUC side, 5s, replug.

```bash
sleep 15
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E08-quiesced
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E08-quiesced

# Critical observations:
# 1. Did Xid 154 fire?  (journalctl --since "<yank-time>" | grep -i Xid)
# 2. Did the system survive 10+ minutes post-yank?
# 3. After replug + reauthorize, did BAR1 come back at 256M or 32G?
```

**Predicted outcome under H7a:** WEDGE again (Xid 154 unavoidable).
**Predicted outcome under H7b:** Clean broken-BAR1, no wedge, recovery via reboot.

Whichever fires tells us where the patch needs to live.

## Patch design implications (per outcome)

- **If H7a confirmed** (always wedges): the patch must intercept earlier — at `pci_remove` callback level, with a hard `device_lost` flag set BEFORE any RPC can fire, AND short-circuit at every NVML/UVM entry point. This is the bigger surgery. Likely fold into E1 (eGPU detection) cluster.
- **If H7b confirmed** (only wedges when session-active): the corrective is achievable via "quiesce-before-cable-yank" pattern. We can ship a userspace utility (e.g., `nvidia-driver-injector quiesce`) that prepares the driver for safe cable transitions. Less invasive; doesn't need a fork patch at all. Falls into the userspace mitigation lane.

The H7a/H7b answer therefore DIRECTLY scopes whether we need a Core/Addon patch or a userspace tool.

## Open follow-ups

- [ ] Execute Run 2 with full quiesce protocol above (next session, with user confirmation since it requires physical cable yank with reboot-on-wedge risk)
- [ ] In parallel: design a `nvidia-driver-injector quiesce` subcommand so the protocol is one command, not 6 manual steps (useful regardless of H7 outcome)
- [ ] Also: instrument with `bpftrace -e 'kprobe:nv_pci_remove { @[probe] = count(); }'` or similar to see exactly when the pci_remove callback fires vs Xid 154 fire (caution: per `feedback_observability_perturbs_bug`, bpftrace may perturb the bug)

## Cross-references

- `E07-cable-replug-drain-first.md` — Run 1 of today doubles as informant for E08
- Mission doc Sub-mission C — H7/H9 hypotheses
- `_STARTING-STATE-RECIPE.md` — quiesce steps source

## Actual result

**Run 1 (2026-05-26 — partial only):** Inconclusive for H7 (idle definition incomplete). Tied to E07 Run 2 wedge. Patch implications: NVML probes (device plugin) ARE sufficient to trigger Xid 154 on cable yank, confirming the failure mode reaches into the routine probing path.

**Run 2:** PENDING — proper full-quiesce test required to discriminate H7a vs H7b.
