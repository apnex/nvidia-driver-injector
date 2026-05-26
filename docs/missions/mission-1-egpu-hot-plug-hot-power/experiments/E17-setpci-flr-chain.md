# E17 — Combined setpci widen + RBAR Control + FLR chain

**Status:** PENDING
**Phase:** 2.4
**Risk:** HIGH (compounds risks of E05 + E16; ordering matters)
**Cost:** ~2 hr
**Reversibility:** difficult; reboot likely required if anything fails
**Last updated:** 2026-05-26

## Hypothesis

Neither E05 (bridge widen) alone nor E16 (RBAR Control) alone is likely to PASS:
- E05 widens upstream window but kernel doesn't re-negotiate downstream BAR sizes
- E16 writes new BAR size but the upstream window is too narrow

Hypothesis: doing both in sequence — widen the bridge window THEN write RBAR Control THEN trigger BAR re-read via remove+rescan — could allow the kernel to see a wider window AND a device requesting a larger BAR, producing the correct end state.

Order matters: bridge widen MUST precede RBAR Control write (otherwise the device requests a BAR that won't fit). FLR or remove+rescan MUST follow both (so kernel sees the new state).

## Falsification gates

**PASS:** BAR1=32G after the full chain, device functional.

**FAIL:** BAR1=256M after the chain — kernel ignored manual register writes during its re-enumeration path.

**INCONCLUSIVE:** any step in the chain fails (bus hang, AER, device disappears).

## Prerequisites

- Cluster in "broken-BAR1" state per `_STARTING-STATE-RECIPE.md`
- E05 and E16 individually understood and tested (FAIL on their own → motivates this combined experiment)
- RBAR_OFFSET known (captured during E16)
- BRIDGE BDF known (0000:02:00.0)

## Method

### Step 1 — Pre-experiment state capture

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E17
```

### Step 2 — Drain workload

```bash
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s
```

### Step 3 — Widen bridge prefetchable window (from E05)

```bash
BRIDGE=0000:02:00.0
sudo setpci -s $BRIDGE 0x24.l=0x80FF1001
sudo setpci -s $BRIDGE 0x28.l=0x00000000
sudo setpci -s $BRIDGE 0x2c.l=0x00000008

# Verify
sudo setpci -s $BRIDGE 0x24.l 0x28.l 0x2c.l
```

### Step 4 — Write RBAR Control to 32GB (from E16)

```bash
GPU=0000:03:00.0
RBAR_OFFSET=0xbb0  # adjust from E16 result
BAR1_CTRL_OFFSET=$((RBAR_OFFSET + 0x10))

CURRENT_CTRL=$(sudo setpci -s $GPU $(printf '0x%x' $BAR1_CTRL_OFFSET).l)
NEW_CTRL=$(printf '0x%08x' $(((0x$CURRENT_CTRL & 0xFFFFFFC0) | 0x15)))
sudo setpci -s $GPU $(printf '0x%x' $BAR1_CTRL_OFFSET).l=$NEW_CTRL

# Verify
sudo setpci -s $GPU $(printf '0x%x' $BAR1_CTRL_OFFSET).l
```

### Step 5 — Trigger BAR re-read via remove+rescan

```bash
echo 1 | sudo tee /sys/bus/pci/devices/$GPU/remove
sleep 2

# Verify gone
lspci -s $GPU 2>&1 || echo "expected: empty"

echo 1 | sudo tee /sys/bus/pci/rescan
sleep 15
```

### Step 6 — Post-experiment state capture + diff

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E17
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E17
```

### Step 7 — Scale workload back up (only if PASS)

```bash
kubectl scale -n vllm deployment/vllm --replicas=1
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

## Predicted PASS signature

```
Bridge 02:00.0 pref: 288M → 32G (from setpci)
RBAR Control[BAR1]: 0x08 → 0x15 (from setpci)
BAR1: 256M → 32G (after rescan, kernel sees larger size)
Device functional
```

## Predicted FAIL signature (most likely)

```
Bridge 02:00.0 pref: written but kernel resets during rescan
RBAR Control[BAR1]: written but kernel resets during rescan
BAR1: still 256M
→ confirms kernel actively overrides manual config-space writes
→ motivates E26/E27 kernel-side patches
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Bridge widen succeeds but rescan reverts it | kernel re-programs bridge window per its budget calculation | confirms `__pci_setup_bus()` is authoritative; transitions to E26/E27 |
| RBAR write succeeds but rescan reverts it | kernel manages RBAR via `pci_rebar_set_size`, ignoring config-space override | same conclusion |
| GPU enumerates with BAR1=8G or 16G (partial up-size) | bridge window only 32G, GPU picks largest fitting power of 2 ≤ window/2 | interesting partial result; log INCONCLUSIVE with details |
| Bus hang during rescan | reboot required | reboot |

## Per-run records

> One subsection per execution. Body-of-evidence builds across runs.

### Run 1 — pending

(Filled in when run. Conditions / Protocol deviations / Result / Diff highlights / Forensic bundle / Anomalies / Conclusion.)

## Patch coverage analysis

(Filled in if a run surfaces driver-level behavior.)

## Patch design implications

(Filled in once body-of-evidence supports a design decision.)

## Open follow-ups

- [ ] (Populated based on run results.)

## Forensic bundles

| Run | Bundle path | Size | Notes |
|---|---|---|---|
|     |             |      |       |

## Cross-references

- E05 (bridge widen alone)
- E16 (RBAR Control alone)
- E26 (custom kernel module — needed if E17 FAILs)
- E27 (PCI core patch — needed if both manual and module approaches FAIL)
