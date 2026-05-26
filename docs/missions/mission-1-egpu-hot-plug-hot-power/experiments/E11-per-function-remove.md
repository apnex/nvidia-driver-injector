# E11 — Per-function remove (GPU + audio) + global rescan

**Status:** Run 1 DONE 2026-05-26 — FAIL-but-SAFE (no broken-BAR1 produced from healthy state, no wedge); pending run from broken-BAR1 state
**Sub-mission:** n/a (Phase 2.1 archaeology; also doubles as Recipe B safety probe)
**Phase:** 2.1
**Risk:** LOW (confirmed safe — no wedge)
**Cost:** ~3 min
**Reversibility:** manual (rescan) — confirmed automatic on this hardware
**Last updated:** 2026-05-26

## Hypothesis

The RTX 5090 device exposes two PCI functions: `0000:04:00.0` (GPU/VGA) and `0000:04:00.1` (HDMI audio). Removing these device-leaves (not the parent bridge) and then rescanning narrows the experiment to function-level re-enumeration without re-running bridge-window allocation. **Primary hypothesis (recovery):** function-level remove+rescan from broken-BAR1 starting state reuses the (broken) bridge windows — confirming that bridge-window allocation is the failure point, not the device probe. **Secondary hypothesis (Recipe B safety):** software-initiated remove (graceful `pci_remove` callback to driver) is safe — no Xid 79/154 cascade, no wedge — even with the device plugin actively NVML-probing and persistence engaged.

This is a **control experiment** for E10 (root-port-level): if E11 FAILs and E10 PASSes, the failure point is bridge-level; if both FAIL, it's a more fundamental issue. Today's Run 1 added the second hypothesis after E07 Run 2 raised concerns about safe-entry to broken-BAR1.

## Falsification gates

**PASS:** post-experiment BAR1=32G, bridge 03:00.0 prefetchable ≥32G. Function-level reload alone was sufficient (would be a surprise).

**FAIL:** post-experiment BAR1=256M, bridge prefetchable=288M. Device re-enumerated but bridge windows unchanged. **This is the expected outcome.**

**INCONCLUSIVE:** GPU function reloads but audio function fails to rescan back (or vice versa).

## Prerequisites

- Cluster in "broken-BAR1" state per `_STARTING-STATE-RECIPE.md`
- Both 0000:03:00.0 (GPU) and 0000:03:00.1 (audio) present in lspci

## Method

### Step 1 — Pre-experiment state capture

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E11
```

### Step 2 — Drain workload

```bash
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s
```

### Step 3 — Remove both functions

```bash
# Remove audio function first (less critical)
echo 1 | sudo tee /sys/bus/pci/devices/0000:03:00.1/remove
sleep 1

# Remove GPU function
echo 1 | sudo tee /sys/bus/pci/devices/0000:03:00.0/remove
sleep 2

# Verify both gone
lspci -s 0000:03:00 || echo "expected: no devices on 03:00.x"
```

### Step 4 — Global rescan

```bash
echo 1 | sudo tee /sys/bus/pci/rescan
```

### Step 5 — Wait for re-enumeration

```bash
sleep 10  # rationale: only function-level probe; faster than E10
```

### Step 6 — Post-experiment state capture + diff

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E11
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E11
```

### Step 7 — Scale workload back up (only if PASS)

```bash
kubectl scale -n vllm deployment/vllm --replicas=1
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

## Predicted PASS signature

```
BAR1: 256M → 32G
Bridge 03:00.0 pref: 288M → 33089M
```

## Predicted FAIL signature (expected)

```
BAR1: 256M → 256M
Bridge 03:00.0 pref: 288M → 288M (windows intact, just narrow)
/dev/nvidia0: re-created
nvidia.ko: re-probed
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Audio function fails to rescan | `lspci -s 0000:03:00.1` empty after 30s | `echo 1 | sudo tee /sys/bus/pci/rescan` again; check `dmesg` for probe error |
| nvidia.ko probe fails | `dmesg | grep -i nvidia` shows `rm_init_adapter failed` | check injector state; in broken-BAR1, this may surface as new failure mode |
| BAR1 enumerates at different small size (e.g., 64M) | suggests the BAR-size-truncation logic depends on current bridge window | log as INCONCLUSIVE; informs E16 design |

## Per-run records

> One subsection per execution. Body-of-evidence builds across runs.

### Run 1 — 2026-05-26 — FROM HEALTHY STATE (safety probe, not from broken-BAR1)

**Conditions:**
- Driver version: 595.71.05-aorus.15 (v15-aligned post-2026-05-26 forced reboot)
- nvidia-device-plugin: running (`nvidia-device-plugin-daemonset-szwbn` 1/1; advertising `nvidia.com/gpu: 1`)
- Persistence mode: engaged (`nvidia-smi -pm 1` from injector entrypoint)
- PC-3 heartbeat: active (state file mtime advancing on 30s cadence)
- Workload: drained (no vLLM in `vllm` namespace)
- Cluster cordoned: no (intentionally — Run 1 tests safety under realistic operational conditions)
- /dev/nvidia* open fd holders (informational; lsof returned empty but driver refcount non-zero due to module load + persistence)

**Starting state:** HEALTHY (BAR1=32 GiB, bridge 03:00.0 prefetchable=33089M)

> Run 1 deviated from the Method's documented prerequisite ("broken-BAR1 state") on purpose: today's question was whether Recipe B is safe (no wedge under sub-cycle-5 conditions). Running from healthy state lets us answer that without first incurring cable-yank wedge risk. A separate "Run 2 from broken-BAR1 state" remains in the open follow-ups list.

**Protocol:** as documented in Method section. No deviations.

**Result: FAIL-but-SAFE** (relative to BOTH stated hypotheses):
- Recovery hypothesis (PASS criteria): N/A — didn't start from broken state
- "Bridge windows preserved through remove+rescan from healthy" sub-finding: **CONFIRMED.** Bridge windows on 02:00.0 and 03:00.0 were unchanged across the remove (33089M / 65856M before and after — visible in stage 4d intermediate capture before rescan)
- Recipe B safety hypothesis (no-wedge): **CONFIRMED.** No Xid 79/154 cascade. No AER errors. Host fully responsive. Driver re-bound automatically. Device plugin maintained `nvidia.com/gpu: 1` advertisement.

**Diff highlights** (from `get-pci-stats.sh --diff E11-Run1`):

```
BAR1 size:                            32G → 32G (preserved)
Bridge 03:00.0 prefetchable:          33089M → 33089M (preserved)
Bridge 02:00.0 prefetchable:          65856M → 65856M (preserved)
Driver bound to GPU:                  nvidia → nvidia (re-bound automatically)
Device plugin nvidia.com/gpu count:   1 → 1 (preserved)
PC-3 state file driver_version:       595.71.05-aorus.15 → 595.71.05-aorus.15
PC-3 state file bar1_size_gib:        32 → 32
```

**Kernel messages observed during remove+rescan event** (from dmesg ring, post-experiment):

```
[ 2512.634425] pci 0000:04:00.0: [10de:2b85] type 00 class 0x030000 PCIe Legacy Endpoint
[ 2512.636044] pci 0000:04:00.0: 8.000 Gb/s available PCIe bandwidth, limited by 2.5 GT/s
               PCIe x4 link at 0000:00:07.0 (capable of 504.112 Gb/s with 32.0 GT/s PCIe x16 link)
[ 2512.636506] pci 0000:04:00.1: [10de:22e8] type 00 class 0x040300 PCIe Endpoint
[ 2512.637469] pcieport 0000:03:01.0: bridge window [io  size 0x1000]: can't assign; no space
[ 2512.637470] pcieport 0000:03:01.0: bridge window [io  size 0x1000]: failed to assign
[ 2512.637473] pcieport 0000:03:02.0: bridge window [io  size 0x1000]: can't assign; no space
[ 2512.637474] pcieport 0000:03:02.0: bridge window [io  size 0x1000]: failed to assign
[ 2512.637474] pcieport 0000:03:03.0: bridge window [io  size 0x1000]: can't assign; no space
[ 2512.637475] pcieport 0000:03:03.0: bridge window [io  size 0x1000]: failed to assign
(repeated 3x — IO windows for the TB-tunneled sub-bridges 03:01-03)
[ 2512.638195] nvidia 0000:04:00.0: vgaarb: VGA decodes changed:
               olddecodes=io+mem,decodes=none:owns=none
[ 2539.584228] nvidia 0000:04:00.0: external GPU detected (thunderbolt-attached=yes,
               external/untrusted=yes)
```

**Forensic bundles:**
- `/var/log/mission-1-archaeology/E11-Run1-software-remove/pre.tar.gz` (309101 bytes — full state pre-experiment)
- `/var/log/mission-1-archaeology/E11-Run1-software-remove/post.tar.gz` (311333 bytes — full state post-experiment)
- `/var/log/mission-1-archaeology/E11-Run1-software-remove/E11-Run1.baseline.txt` + `.snapshot.txt` (focused state delta)

**Anomalies / unexpected observations:**

1. **PCIe link degraded to Gen1 x4 (8 Gb/s) post-rescan.** Pre-rescan the TB-tunneled GPU was on a Gen3 link (TB4-saturated, ~24 Gb/s per `feedback_lspci_lnkcap_tb_virtual`). After remove+rescan, dmesg reports "8.000 Gb/s available PCIe bandwidth, limited by 2.5 GT/s PCIe x4 link at 0000:00:07.0". Note: `lspci` LnkSta on TB-tunneled bridges is virtualized — the reported 2.5 GT/s may not reflect actual tunnel bandwidth (need `nvbandwidth` test from diag container to verify real throughput). But this is a different post-rescan state than cold-boot's reported link.

2. **Three sub-bridge IO window allocations failed.** `pcieport 0000:03:01.0` / `03:02.0` / `03:03.0` (sub-bridges within the TB downstream hub for additional ports) each tried to assign a 4K IO window and failed with "no space". These are NOT the prefetchable memory window (which stayed at 33089M); they are the IO windows for unused ports. Cosmetic — those ports have no devices attached. But informative: even on graceful re-enumeration, the kernel attempts re-allocation for some sub-bridges and fails.

3. **E1 eGPU detection logic fired correctly** post-rescan: `external GPU detected (thunderbolt-attached=yes, external/untrusted=yes)`. The E1 patch is participating in the re-enumeration path.

4. **No Xid messages, no AER errors, no GPU crash dump.** Surprise-removal cascade did not fire. This is the SAFE-by-design outcome.

**Conclusion:**

E11 Run 1 confirms **two important things, partially answers a third, and surfaces a fourth as a new question:**

1. ✓ **Recipe B is safe** — software-initiated remove + rescan does NOT fire Xid 79/154, does NOT wedge the host, and survives under realistic sub-cycle-5 operational conditions (device plugin + persistence + heartbeat all running). The graceful `pci_remove` callback path used by the kernel correctly notifies the driver, which releases resources cleanly without entering Xid 154's "GPU Reset Required" terminal state.

2. ✓ **Bridge windows are preserved across software-initiated remove+rescan from healthy state.** This means E11 (used as Recipe B) does NOT produce broken-BAR1 from healthy starting state — the bridge allocation is sticky. The kernel doesn't re-attempt allocation when the bridge windows are already assigned and only downstream devices have been removed.

3. ⏸ **Original E11 hypothesis** (does function-level remove+rescan recover from broken-BAR1?) is now BLOCKED: we cannot safely produce the broken-BAR1 starting state on this hardware without the Sub-mission C wedge risk (see E07 Run 2). Phase 2.1 / 2.2 experiments depending on broken-BAR1 are similarly blocked.

4. **NEW open question**: PCIe link bandwidth post-rescan reports degraded (2.5 GT/s × x4 ≈ 8 Gb/s vs cold-boot ~24 Gb/s on TB4). Worth measuring actual throughput via `nvbandwidth` (diag container) to determine if this is virtual-register noise (per `feedback_lspci_lnkcap_tb_virtual`) or a real degradation that would affect compute workloads. NOT a wedge issue, but a Phase 2.1 informant.

## Patch coverage analysis

Run 1 was a SAFE-path test, so no patches were stressed in the way E07 Run 2 stressed them. But this is itself informative for patch design:

| Existing patch | Should have helped? | What actually happened |
|---|---|---|
| E1 (eGPU detection) | YES — re-detect on rescan | ✓ Fired: `external GPU detected (thunderbolt-attached=yes, external/untrusted=yes)` post-rescan. E1's TB4 awareness IS working on graceful re-enumeration. |
| C4 (PCI err_handlers scaffold) | No — graceful path doesn't fire error handlers | ✓ Correctly NOT invoked. The `pci_remove` callback path is separate from `pci_error_handlers`. |
| A2 (Q-watchdog Mode B) | No — no DMA wedge | ✓ Correctly silent. |
| A3 (recovery state machine) | No — no rmInit failure | ✓ Correctly silent. Confirms A3's scope is post-rmInit-FAIL, not graceful remove. |
| A4 (close-path telemetry) | Visibility | Should show UVM `(LAST-CLOSE)` events during remove. (Filtered out of diff capture today; visible if needed for n>1 runs.) |

**Driver kernel sites exercised on the graceful path:**

```
kernel-open/nvidia/nv-pci.c::nv_pci_remove         (received during remove)
kernel-open/nvidia/nv-pci.c::nv_pci_probe          (received during rescan)
drivers/pci/remove.c::pci_stop_and_remove_bus_device_locked  (kernel-side initiator)
drivers/pci/probe.c::pci_scan_slot                  (kernel-side rescan)
```

The graceful path's success here is informative for the corrective patch design: a future "TB-unplug-aware teardown" (the patch class motivated by E07 Run 2) could MIMIC the same code path the graceful remove uses — set `device_lost` flag → release resources via the same teardown sequence → short-circuit RPCs. The fact that the graceful path works cleanly means we have a working reference implementation in `nv_pci_remove` to model from.

## Patch design implications

E11 Run 1 strengthens the patch design hypothesis from E07:

- **Detection layer:** the graceful path goes through `nv_pci_remove`. A surprise-removal patch should ensure ALL paths (cable yank, programmatic remove, FLR) converge on the SAME teardown sequence that `nv_pci_remove` uses. Today's Run 1 demonstrates `nv_pci_remove` IS reachable from `pci_stop_and_remove_bus_device_locked` cleanly.
- **State management:** during the graceful remove today, the driver released state cleanly (no in-memory leaks observable, persistence re-engaged on probe). Replicating this teardown on TB-unplug instead of relying on the wedge-inducing Xid 154 path is the goal.
- **Failure-path short-circuit:** not yet exercised. Would need a wedge-class run (E07 Run 3 perhaps, with bpftrace) to identify exactly where the wedge-inducing path diverges from the graceful path.
- **Patch geometry candidates** (updated):
  - **Extending E1 (eGPU detection cluster)** remains the leading candidate — E1 IS firing on the graceful path today. Adding a `pci_remove`-like handler that engages on TB disconnect events would be a natural extension.
  - **New addon (A6)** still possible if E1 extension proves too invasive.
  - **Userspace mitigation** (device plugin subscribes to boltctl events) still possible as a defensive layer regardless of driver-side patch.

**Body-of-evidence sufficiency:** today's data + E07 Run 2's data is sufficient to **sketch** a patch (the graceful path is the reference implementation; the wedge-path diverges somewhere identifiable). Not yet sufficient to **finalize** the patch — would benefit from at least one more data point: either a controlled run that fires Xid 154 with bpftrace tracing the divergence, OR a Sub-mission B test (chassis power-cycle while cable connected) to see if a different trigger reaches the same wedge path.

## Open follow-ups

- [ ] **E11 Run 2 from BROKEN-BAR1 state** (the original E11 hypothesis) — BLOCKED on safely producing broken-BAR1, which depends on either: A6/E1-extension patch (so cable yank is safe), OR an alternative production mechanism not yet identified
- [ ] **Re-link-speed investigation** — measure actual H2D/D2H bandwidth via `apnex/nvidia-driver-diag` container after E11-style remove+rescan, compare to cold-plug baseline. Determines if the dmesg "2.5 GT/s PCIe x4" is virtual-register-noise (per `feedback_lspci_lnkcap_tb_virtual`) or real degradation.
- [ ] **bpftrace-instrumented Run from healthy state** — kprobe on `nv_pci_remove`, `nv_pci_probe`, `pci_stop_and_remove_bus_device_locked` to capture exact code path that worked today (will be the reference for designing the surprise-removal recovery patch)
- [ ] **n≥2 reproductions of Run 1** (per `feedback_reliability_methodology`) — confirm Run 1's safe-graceful outcome is deterministic and not coincidental
- [ ] **Compare to Sub-mission B trigger** (chassis power-cycle while cable connected) — does that fire the wedge path or the graceful path?

## Forensic bundles

| Run | Bundle | Size | Notes |
|---|---|---|---|
| Run 1 pre | `/var/log/mission-1-archaeology/E11-Run1-software-remove/pre.tar.gz` | 309 KB | Full state immediately before remove+rescan |
| Run 1 post | `/var/log/mission-1-archaeology/E11-Run1-software-remove/post.tar.gz` | 311 KB | Full state immediately after re-enumeration completed |

The pre→post diff at bundle-level (extracting both and `diff -r`) will show every kernel/k8s/PCI state change in detail beyond what `get-pci-stats.sh --diff` summarizes.

## Cross-references

- Linux source: `drivers/pci/remove.c::pci_stop_and_remove_bus_device_locked`
- Linux source: `drivers/pci/probe.c::pci_scan_slot`
- Driver source: `kernel-open/nvidia/nv-pci.c::nv_pci_remove` (the graceful-path reference for future patch design)
- E07 Run 2 (cable yank wedge) — failure-mode counterpart; together with E11 Run 1, defines the "graceful path works / surprise-removal path wedges" dichotomy
- E10 (root-port-level remove) — broader scope variant
- `_STARTING-STATE-RECIPE.md` Recipe B — uses E11's mechanism; today validated as SAFE
- `feedback_surprise_removal_wedge_class_2026_05_26` — patch design context
