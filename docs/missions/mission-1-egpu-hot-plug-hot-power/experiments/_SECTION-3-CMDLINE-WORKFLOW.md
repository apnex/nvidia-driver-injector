# Section 3 (cmdline tuning) — shared workflow

Section 3 experiments (E18-E24) test whether kernel cmdline parameters tweak the PCIe hotplug bridge-window allocation behavior. Each iteration requires editing GRUB cmdline + reboot. This file carries the shared procedure; each E18-E24 file references back here and only documents the **specific cmdline addition** + **expected effect**.

## Per-iteration workflow

### 1. Edit GRUB cmdline

```bash
sudo cp /etc/default/grub /etc/default/grub.bak.E<NN>
sudo vi /etc/default/grub
```

Find the `GRUB_CMDLINE_LINUX` line. Current state (post-aorus.14 production):

```
GRUB_CMDLINE_LINUX="rhgb quiet module_blacklist=nouveau,nova_core,nova_core modprobe.blacklist=nouveau,nova_core thunderbolt.dyndbg=+pflm iommu=off intel_iommu=off thunderbolt.host_reset=false pcie_aspm.policy=performance thunderbolt.clx=0 pcie_port_pm=off pci=resource_alignment=35@0000:03:00.0"
```

Add the experiment's specific parameter(s) to the end of the line (or modify existing params per the experiment file).

### 2. Regenerate GRUB config

```bash
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

Expected: rebuilds the active boot entry. Saves output to stderr — confirm no errors.

### 3. Capture pre-reboot state

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E<NN>
```

### 4. Drain workload

```bash
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s
```

### 5. Reboot

```bash
sudo systemctl reboot
```

### 6. After reboot — verify new cmdline took effect

```bash
cat /proc/cmdline
# Confirm the experiment's parameter is present
```

### 7. Capture post-reboot state + diff

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E<NN>
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E<NN>
```

### 8. Scale vLLM back up (regardless of PASS/FAIL — workload should resume)

```bash
kubectl scale -n vllm deployment/vllm --replicas=1
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

### 9. Rollback the cmdline if FAIL (don't accumulate dead parameters)

```bash
sudo cp /etc/default/grub.bak.E<NN> /etc/default/grub
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

Leave for next reboot to take effect (or reboot immediately if accumulating cmdline state would skew the next experiment).

## What constitutes PASS vs FAIL for Section 3

**PASS:** post-reboot BAR1 = 32G AND bridge 03:00.0 prefetchable = ≥32G. The cmdline parameter tweaked the boot-time hotplug bridge window allocation enough that runtime cable cycles will now produce the correct allocation.

Note: Section 3 tests are subtle because the cmdline parameter affects BOOT-time enumeration. If the GPU was present at boot (default cold-plug path), bridge windows would be 32GB anyway (independent of cmdline). The real test is whether the cmdline affects **runtime hot-plug** allocation. So Section 3 experiments need a 2-phase test:

1. Boot with the cmdline parameter AND GPU plugged in → confirm 32GB baseline (control)
2. Drain + cable cycle → does runtime allocation now produce 32GB? (test)

This 2-phase structure is captured in each E18-E24 file's `Method` section.

**FAIL:** post-runtime-cable-cycle BAR1 stays at 256M (same as without the cmdline parameter).

**INCONCLUSIVE:** boot-time allocation also broke (e.g., 64M instead of 32G) — the parameter changed boot allocation in an unexpected way; needs careful diff against pre-cmdline boot state.

## Cumulative cmdline state across experiments

Each E18-E24 experiment ADDS a parameter to the prior baseline OR REPLACES it. The relationship:

- E18: + `pci=realloc=on`
- E19: E18 + `hpmmioprefsize=32G`
- E20: E19 + `hpmmiosize=256M`
- E21: REPLACES E18+ with `pci=realloc=on hpmemsize=33G`
- E22: E19 + `pcie_aspm=off` (drops existing `pcie_aspm.policy=performance`)
- E23: ALL E18-E22 × cold-boot-off path (orthogonal axis)
- E24: REPLACES `pci=resource_alignment=35@<bridge>` with size variants

After all E18-E24 complete, the cmdline should be reverted to the production baseline.

## Cross-references

- LF forum analysis of pci=realloc combinations: M1 research (`audit/tb-pcie/CONSOLIDATED.md` Q3)
- Current cmdline rationale: per-parameter memory entries (`feedback_bridge_cap_needs_both_knobs.md`, etc.)
