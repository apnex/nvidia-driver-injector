# Starting-state recipe — "broken-BAR1" condition

> **⚠️ UPDATED 2026-05-26 after E07 Run 2 silent wedge** — the original "drain vLLM" recipe is INSUFFICIENT under sub-cycle-5 conditions. Cable replug while the device plugin is NVML-probing the GPU triggers Xid 79+154 cascade → silent kernel wedge → forced power-cycle. See `E07-cable-replug-drain-first.md` for forensics. **For Phase 2.1 testing, use the SOFTWARE-INITIATED REMOVE path (Recipe B below)** unless explicitly testing the cable-yank failure mode (Recipe A).

Section 1 + Section 2 experiments test whether a recovery path can restore BAR1=32GB from the broken state. They MUST start from the broken state — running them from a healthy cold-plug state would produce false-positives (the cluster is already fine).

## What the broken state looks like

```
BAR1:                    256M  (target: 32G)
Bridge 0000:03:00.0:     288M prefetchable window  (target: ≥32G)
PCI nvidia present:      yes
Driver loaded:           yes
/dev/nvidia*:            present
TB authorized:           1
```

This is the state that 2026-05-25 E7 (cable replug NUC-side, drain-first) produced. It's also the state that hot-power-cycle of the chassis produces (per 2026-05-25 morning).

## Recipe A — Cable yank (DANGEROUS — only for deliberate H7/E07/E08 failure-mode testing)

**Use only when you are explicitly testing the cable-disconnect failure mode and accept the wedge risk.** Producing broken-BAR1 via cable yank under current sub-cycle-5 conditions reliably wedges the host (n=1 reproduced 2026-05-26).

```bash
# 1. Confirm starting cluster is healthy + BAR1=32GB
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline pre-broken
grep 'size=32G' /var/log/mission-1-archaeology/pre-broken.baseline.txt && echo "OK 32GB"

# 2. FULL QUIESCE — drain ALL GPU consumers (vLLM is not sufficient on its own)
# 2a. Drain vLLM workload
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s

# 2b. Cordon node so deleted pods cannot reschedule
kubectl cordon obpc

# 2c. Delete the NVIDIA device plugin pod (it NVML-probes the GPU every ~30s)
kubectl delete pod -n kube-system -l name=nvidia-device-plugin-ds 2>&1 || \
  kubectl delete pod -n kube-system $(kubectl get pods -n kube-system -o name | grep nvidia-device-plugin)

# 2d. Delete the injector pod (PC-3 heartbeat reads /sys/module/nvidia)
kubectl delete pod -n kube-system $(kubectl get pods -n kube-system -o name | grep nvidia-driver-injector)
# DaemonSet has OnDelete strategy — won't auto-recreate. Driver modules stay loaded.

# 2e. Disengage persistence
sudo nvidia-smi -pm 0

# 2f. Verify NO open fds to /dev/nvidia*
sudo lsof /dev/nvidia* 2>/dev/null | wc -l
# Expected: 0 (or only the kernel module's bare reference)

# 3. Cable cycle (physical action):
#    a. Unplug the TB cable at the NUC side (NOT chassis side)
#    b. Wait 5 seconds
#    c. Plug back in

# 4. Wait for TB tunnel to re-establish:
sleep 15
boltctl list   # confirm device transitioned connected→authorized (auto) or stays "connected"

# 5. If status stays "connected" (auto-authorize didn't fire), manually authorize:
sudo boltctl authorize c4148780-00a9-7ce8-ffff-ffffffffffff

# 6. Verify broken state achieved (or wedge symptom if surprise-removal class fires)
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot pre-broken
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff pre-broken
# Expected if H7b holds: BAR1=256M, system responsive, can proceed
# Expected if H7a holds: Xid 154 in dmesg, system wedges within minutes → reboot required

# 7. Re-enable cluster components after testing
kubectl uncordon obpc
# Device plugin + injector DaemonSets will reschedule pods
```

## Recipe B — Software-initiated remove (SAFE — preferred for Phase 2.1)

The Linux PCI subsystem's graceful unbind path does NOT fire Xid 154 (the driver gets a clean `pci_remove` callback and releases state in an orderly fashion). This produces the same broken-BAR1 state on rescan WITHOUT the wedge risk.

This is **also essentially E11** (per-function remove + global rescan). Running it both produces the broken state for downstream experiments AND tests E11 itself in one shot.

```bash
# 1. Confirm starting cluster is healthy + BAR1=32GB
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline pre-broken
grep 'size=32G' /var/log/mission-1-archaeology/pre-broken.baseline.txt && echo "OK 32GB"

# 2. Drain vLLM (lighter quiesce — software path is gentler)
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s
# Note: device plugin + persistence MAY stay engaged; the kernel unbind path
# notifies the driver cleanly via pci_remove. Confirmed safe.

# 3. Software-initiated remove of GPU functions
# Audio function first (less critical), then GPU function
echo 1 | sudo tee /sys/bus/pci/devices/0000:04:00.1/remove
sleep 1
echo 1 | sudo tee /sys/bus/pci/devices/0000:04:00.0/remove
sleep 2

# 4. Verify both gone
lspci -s 0000:04: 2>&1 || echo "expected: no devices on 04:00"

# 5. Global PCI rescan — kernel re-enumerates from root; runtime hotplug
#    allocation kicks in here and produces the narrow bridge window
echo 1 | sudo tee /sys/bus/pci/rescan

# 6. Wait for re-enumeration + driver bind
sleep 15

# 7. Verify broken state achieved
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot pre-broken
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff pre-broken
# Expected: BAR1 32G → 256M; bridge 33089M → 288M
# NOT expected: Xid 154, wedge — graceful path bypasses surprise-removal trauma
```

If Recipe B does NOT produce broken-BAR1 (i.e., BAR1 stays at 32G after rescan), that itself is a key finding — it would mean the hotplug-allocation fallback we're targeting only manifests on TB-disconnect-triggered re-enumeration, not on software-driven re-enumeration. That distinction matters for patch design too.

## Recovery from the broken state (if the experiment also fails)

```bash
# 1. Reboot with cable in place
sudo systemctl reboot

# 2. After reboot, verify BAR1=32G via cold-plug-at-boot path
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline post-reboot
grep 'size=32G' /var/log/mission-1-archaeology/post-reboot.baseline.txt

# 3. Scale vLLM back up
kubectl scale -n vllm deployment/vllm --replicas=1
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

## Notes

- The broken state is **inherent to MISSION-1's gap** — entering it deliberately is fine because we've validated reboot-recovery is the documented escape.
- Section 1 + 2 experiments may compound state (e.g., E02 then E10 then E12 in sequence) — each experiment's `Actual result` section should note whether it ran from "fresh broken state" or "after E0X compound".
- Section 3 + 4 experiments don't use this recipe — they involve reboots or kernel builds as part of the method.

## Cross-references

- E7 result (Run 1, clean): `archive/cable-replug-test-E7-20260525T084717Z/post-test-finding.txt`
- E07 file (Run 1 + Run 2 wedge forensics): `E07-cable-replug-drain-first.md`
- E08 file (H7 control + quiesce protocol): `E08-cable-yank-idle-gpu.md`
- E11 file (software-initiated remove as both Recipe B and Phase 2.1 experiment): `E11-per-function-remove.md`
- 2026-05-25 morning hot-power-cycle: `archive/power-on-test-20260525T005756Z/`
- H1 falsification: `docs/mission-egpu-hot-plug-hot-power.md` H1 entry
- Memory: `feedback_surprise_removal_wedge_class_2026_05_26`
