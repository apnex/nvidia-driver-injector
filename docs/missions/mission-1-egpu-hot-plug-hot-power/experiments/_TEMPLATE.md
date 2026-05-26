# E?? — <short-title>

**Status:** PENDING
**Sub-mission:** A (cable hot-plug) | B (chassis power-cycle) | C (active-compute disconnect) | n/a (Phase 2 archaeology)
**Phase:** 2.1 | 2.2 | 2.3 | 2.4 | 2.5 | Mission-level
**Risk:** LOW | MEDIUM | HIGH
**Cost:** ~N min
**Reversibility:** auto | manual | reboot required
**Last updated:** YYYY-MM-DD

## Hypothesis

<One paragraph. The specific prediction this experiment tests. Reference H-numbers from `../mission.md` if extending an existing hypothesis. Be specific about which Linux kernel mechanism or driver code path is exercised and what behavior is predicted.>

## Falsification gates

**PASS:** <Specific state-change signature in `get-pci-stats.sh --diff` output that demonstrates the targeted recovery path works. Usually: BAR1 size transitions from `256M` → `32G`, bridge `03:00.0` prefetchable window from `288M` → `≥32G`.>

**FAIL:** <Specific state-change signature indicating the experiment ran but did NOT achieve the targeted recovery. Usually: BAR1 stays at `256M`, bridge stays at `288M`, but the device DID re-enumerate.>

**INCONCLUSIVE:** <State-change signature that's ambiguous. Usually: enumeration didn't complete, AER cascade fired, or a new failure mode replaced the targeted one.>

**WEDGE:** (cable/power experiments only) <Symptoms of host wedge: journalctl stops, system unresponsive, requires forced reboot. Document any Xid cascade observed.>

## Prerequisites

- <Starting cluster state (e.g., "broken-BAR1 state per `_STARTING-STATE-RECIPE.md` Recipe B" or "healthy cold-plug state with BAR1=32GB")>
- <Other experiments that must precede>
- <Tooling required beyond `get-pci-stats.sh` + `must-gather.sh`>

## Method

### Step 1 — Pre-experiment state capture

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E??
```

### Step 2 — Drain workload if not already drained

```bash
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s
```

### Step 3 — Execute experiment

```bash
<EXACT commands here — no placeholders>
```

### Step 4 — Wait period

`sleep <N>` — <rationale for the wait time>

### Step 5 — Post-experiment state capture + diff

```bash
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E??
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E??
```

### Step 6 — If WEDGE-class outcome, immediately capture must-gather bundle

```bash
sudo /root/nvidia-driver-injector/tools/must-gather.sh
# Preserve under runtime archive area before any further reboots:
mkdir -p /var/log/mission-1-archaeology/E??-Run<N>-<tag>/
cp /tmp/nvidia-injector-must-gather-*.tar.gz /var/log/mission-1-archaeology/E??-Run<N>-<tag>/
```

### Step 7 — Scale workload back up (only if PASS)

```bash
kubectl scale -n vllm deployment/vllm --replicas=1
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

## Predicted PASS signature

```
<example diff snippet showing the expected before/after state if the targeted recovery works>
```

## Predicted FAIL signature

```
<example diff snippet showing the expected before/after state if the targeted recovery does NOT work>
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| <specific failure mode> | <observable symptom> | <recovery command(s); or "reboot required"> |

## Per-run records

> One subsection per execution. Body-of-evidence builds across runs. Don't delete prior runs when adding new ones.

### Run 1 — YYYY-MM-DD <pending>

**Conditions:**
- Driver version (e.g., 595.71.05-aorus.15):
- nvidia-device-plugin: running / drained
- Persistence mode (`nvidia-smi -pm`): engaged / off
- PC-3 heartbeat: active / off
- Workload: drained / running
- Cluster cordoned: yes / no
- /dev/nvidia* open fd count at start:

**Protocol deviations:** <any departures from Method>

**Result:** PASS / FAIL / INCONCLUSIVE / WEDGE

**Diff highlights:**

```
<key state changes from get-pci-stats.sh --diff output>
```

**Forensic bundle:** `<path to preserved must-gather tarball, or N/A if no anomaly>`

**Anomalies / unexpected observations:** <anything not predicted by the hypothesis>

**Conclusion:** <1-paragraph interpretation. State whether the hypothesis was confirmed, falsified, or remains open via this path. Note observations that inform other experiments or patch design.>

## Patch coverage analysis

> Consolidated across runs once driver-level behavior is observed. What patches detected / did not detect the failure; what fired vs. what should have fired.

(Filled in when relevant.)

| Existing patch | Should have helped? | What actually happened |
|---|---|---|
|  |  |  |

**Driver kernel sites observed at failure / interaction points:**

```
<file:line references, e.g., kernel-open/.../kernel_graphics.c:2608>
```

## Patch design implications

> Forward-looking. Filled in once body-of-evidence is sufficient to inform a corrective patch's geometry.

(Filled in when sufficient data exists.)

- Trigger detection layer: <where should the corrective logic listen>
- State management: <what state needs to be tracked>
- Failure-path short-circuit: <what call sites need to return ENODEV / fast-fail>
- Patch geometry candidates: <extend existing patch / new addon / new Core / userspace mitigation>
- Body-of-evidence sufficiency: <can we design a patch from this data alone, or do we need more runs / instrumentation>

## Open follow-ups

> Things to do that add data points toward eventual patch design. Each item should produce a new Run sub-section OR a new experiment file.

- [ ] <e.g., n≥2 reproductions of this run to confirm determinism>
- [ ] <e.g., variant with bpftrace instrumentation>
- [ ] <e.g., compare with E?? control experiment>

## Forensic bundles

> List of preserved must-gather tarballs from runs where they were collected.

| Run | Bundle path | Size | Notes |
|---|---|---|---|
|  |  |  |  |

## Cross-references

- <Links to related experiments, matrix doc entries, mission doc hypotheses, kernel source, patch intent files>
