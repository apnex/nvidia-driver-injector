# E23 — Each cmdline × cold-boot-off path

**Status:** PENDING
**Phase:** 2.3
**Risk:** LOW
**Cost:** ~10 min per cmdline variant × 5 = ~1 hr
**Reversibility:** revert grub + reboot
**Last updated:** 2026-05-26

## Hypothesis

E18-E22 tested cmdline parameters in the **boot-with-GPU-plugged-in** path, then runtime cable-cycled. An orthogonal axis is the **boot-with-GPU-disconnected** path: boot to a fully-up system with no GPU, then plug it in afterwards. This tests whether the cmdline affects:
- Initial cold-plug allocation (boot path) — already covered by E18-E22 Phase A
- **Runtime hot-plug allocation after a fully-quiet boot** — this experiment

Hypothesis: cmdline parameters that pre-budget bridge windows (E19's hpmmioprefsize) may behave **differently** when the bridge has been initialized at boot without any downstream device claiming the window. The window is already reserved at the target size, so when the device hot-plugs in, it has a fitting window waiting.

## Falsification gates

**PASS (any variant):** GPU plugged in after boot produces BAR1=32G.

**FAIL (all variants):** GPU plugged in after boot still produces BAR1=256M.

## Prerequisites

- E18-E22 completed (this experiment reuses each cmdline variant)
- Physical access to disconnect/reconnect GPU between boots

## Method

For each of the 5 cmdline variants (E18, E19, E20, E21, E22), repeat:

### Step 1 — Set cmdline (or confirm from prev experiment)

Per `_SECTION-3-CMDLINE-WORKFLOW.md`, set GRUB to the chosen variant.

### Step 2 — Shut down with GPU PHYSICALLY DISCONNECTED

```bash
# Drain workload
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s

sudo systemctl shutdown
```

User action: physically disconnect TB cable (NUC-side or chassis-side).

### Step 3 — Boot with GPU disconnected

Boot into the OS. Confirm GPU absent:

```bash
lspci | grep -i nvidia || echo "expected: no nvidia device"
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E23-variant-cold-off
```

### Step 4 — Plug GPU back in

User action: reconnect TB cable.

```bash
sleep 10  # allow TB tunnel + boltd auto-authorize
# Verify GPU appears
lspci | grep -i nvidia
```

### Step 5 — Capture state + diff

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E23-variant-cold-off
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E23-variant-cold-off
```

### Step 6 — Note result; if PASS, scale vLLM

```bash
kubectl scale -n vllm deployment/vllm --replicas=1
```

### Step 7 — Repeat for next variant

## Per-variant results matrix

| Variant | Cold-off baseline | Post-plugin | Status |
|---|---|---|---|
| E18 cmdline (realloc=on alone) | | | |
| E19 cmdline (+hpmmioprefsize) | | | |
| E20 cmdline (+hpmmiosize) | | | |
| E21 cmdline (hpmemsize) | | | |
| E22 cmdline (+pcie_aspm=off) | | | |

## Predicted PASS signature

```
For at least one variant: BAR1: absent → 32G after plug-in
```

## Predicted FAIL signature (likely)

```
All variants: BAR1: absent → 256M after plug-in
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| GPU doesn't appear after plug-in | TB tunnel not authorizing | `boltctl list`; `boltctl authorize <uuid>` |
| Allocation differs at cold-off boot vs cold-on | informational | document the difference |

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

- E18-E22 (paired Phase A/B versions)
- This is the orthogonal "cold boot without GPU" axis
