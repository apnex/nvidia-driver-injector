# MISSION-1 v4 — Architecture decision record: Core-wide vs eGPU-localized

**Status:** v1 2026-05-26 — written after E07 Run 3 rewedge confirmed C5 v3 incomplete; SUPERSEDES the muddled "hybrid" framing in `architectural-funnel-redirection-design.md`
**Decision under consideration:** which architectural layer hosts the surprise-removal cascade prevention — Core (all GPUs) or Addon (TB eGPU only)
**Owner:** apnex (user)
**Status of decision:** PENDING — source audit + (optional) cross-hardware empirical test required before commitment

## Premise

The driver-side host wedge during TB cable surprise removal is a real, reproducible failure class. C5 v1 + v3 covered SOME of the assertion sites that fire in the cascade, but Run 3 (2026-05-26) proved structurally incomplete:
- 2 of v3's 8 converted sites fired correctly (kgraphicsFreeContextBuffers, fecsBufferDisableHw)
- 3 OTHER sites fired uncovered (osinit.c:2462, kern_fsp_gh100.c:649, gpu_user_shared_data.c:248)
- Patterns include: narrow `NV_ASSERT(status == NV_OK)`, arithmetic invariants on dead-bus reads, `NV_CHECK_OK` family

**Per-site patching is converging too slowly. The fix is architectural, not site-by-site.** [[feedback_funnel_vs_per_site_patching_2026_05_26]]

## The architectural question

Where does the load-bearing fix live?

- **Option 1 (Core / C-series):** ALL hardening in transport-agnostic Core code. Fix covers any GPU experiencing PCIe surprise removal.
- **Option 2 (Addon / E + A-series):** ALL hardening in eGPU-specific code. Fix covers only TB/USB4-attached GPUs. Core remains untouched.

Both can be "production quality upstream" depending on what the audit reveals about the failure-class scope.

The decision is BINARY by construction. A muddled middle (Core funnels + Addon TB hook + scattered legacy per-site patches) sacrifices the clarity of either commitment and produces worse upstream-PR fitness, worse testing isolation, and worse correctness reasoning.

## Option 1 — Core / C-series

### Premise

The failure class (cascade through assertion sites when GPU is unreachable) is reachable for ANY GPU experiencing PCIe surprise removal, not just TB-attached eGPUs. Discrete-x16 GPUs CAN experience PCIe link drop from signal-integrity faults, thermal trips, server-backplane hot-swap, BIOS quirks. The Core driver code paths fire the same cascade in those scenarios.

### What the patches look like

- **Detection layer:** register `pci_remove` callback (already invoked by Linux PCI core for any disappearing PCI device — transport-agnostic)
- **Sink-state marker:** `atomic_t nvl->device_dead` in `nv_state_t` (Core struct; no eGPU gate)
- **Funnel guards:** ~10 well-known entry points, all in Core paths:
  - `osDevReadReg{08,16,32}` — already done in C5 v1
  - `NV_PRIV_REG_RD32` raw MMIO macro — NEW guard
  - `_issueRpcAndWait` — already done in C5 v1
  - `rpcRmApi{Alloc,Control,Free}_GSP` — partially done; complete it
  - `nvidia_{open,mmap,ioctl}` IOCTL entry — NEW guards
- **Per-site assertion conversions:** retired (or kept as defense-in-depth)

All files in `kernel-open/nvidia/` and `src/nvidia/...` Core paths. No `nv-tb-egpu-*.c` files touched.

### Source audit required to confirm Option 1

| Question | Method |
|---|---|
| Does `pci_remove` fire reliably for non-TB devices on surprise removal? | Read `drivers/pci/probe.c` + `drivers/pci/hotplug/` for the dispatch flow |
| Is the funnel set above complete — does every GPU-access path traverse one? | Source-tree audit of nvidia.ko entry points; cross-check IOCTL/MMIO/RPC trees |
| Do the observed assertion sites (osinit.c:2462, kern_fsp_gh100.c:649, etc.) get reached via paths the funnels intercept? | Trace upstream callers of each observed site |
| Are non-eGPU discrete GPUs at risk of hitting this cascade in real scenarios? | Search NVIDIA's open-driver issue tracker for Xid 79+154 + wedge on non-eGPU systems; check internal NVIDIA bug numbers if cited |
| Do the funnel checks add any regression risk on integrated/discrete code paths? | Static analysis: do the guards short-circuit ONLY when `device_dead` is set? Test on healthy GPU to confirm no perf regression |

### Pros / Cons

**Pros:**
- Single coherent hardening layer; no fragmentation
- Covers all surprise-removal scenarios across all GPU classes
- Upstream-PR-friendly: NVIDIA could accept the Core fix for any platform
- Aligns with [[feedback_native_in_driver_hardening]] long-term posture

**Cons:**
- Larger blast radius (Core changes affect all GPU users worldwide IF upstreamed)
- More rigorous regression testing required (need confidence non-eGPU GPUs unaffected)
- Audit-justification required to legitimize Core scope (NVIDIA reviewers will ask "why touch this for an eGPU issue?")

## Option 2 — Addon / E + A series

### Premise

The failure class is provably TB/USB4-transport-specific. Integrated and discrete-x16 GPUs do NOT experience this cascade under realistic operational conditions. All wedge/crash prevention concentrates in TB eGPU code paths. Core is untouched.

### What the patches look like

- **Detection layer:** TB-bus event subscription (`struct tb_service_driver` notifier on thunderbolt unplug events)
- **Sink-state marker:** `atomic_t nvl->tb_egpu_disconnected` — only meaningful when `nv->is_external_gpu` is set
- **Funnel guards:** same ~10 entry points but gated:
  ```
  if (nv->is_external_gpu && tb_egpu_disconnected_check(nv)) {
      return /* dead-bus value */;
  }
  ```
  Non-eGPU paths take an early branch that bypasses the guard logic entirely
- **All new files in addon layer:** extend E1 territory, or new E2/A6

### Source audit required to confirm Option 2

| Question | Method |
|---|---|
| Can we PROVE non-eGPU surprise removal never reaches the same cascade? | Per-failure-class trace: for each observed assertion site, are its callers gated by `is_external_gpu` or by TB-only code paths? |
| Are there documented Xid 79+154+wedge reports on non-eGPU systems? | Grep NVIDIA's open-driver issue tracker + community signals doc |
| Does the existing `is_external_gpu` flag get set reliably? | Read E1 patch — confirms `NVreg_RmForceExternalGpu=1` plus auto-detect logic |
| Are there edge cases where a non-eGPU device gets `is_external_gpu` set? | Cross-check E1's detection logic and audit `nv-pci-table.c` |

### Pros / Cons

**Pros:**
- Concentrates ALL surprise-removal handling in one logical place — easier to reason about, easier to test in isolation
- Zero regression risk on integrated/discrete GPU code paths (they take untouched-by-our-patches paths)
- Upstream-PR scope is bounded ("fixes Blackwell eGPU over Thunderbolt") — narrow, well-justified, easier review
- Could stay project-local if NVIDIA isn't ready to merge

**Cons:**
- If audit shows non-eGPU cases ALSO fire the cascade → Option 2 is WRONG (false sense of security; maintenance hazard)
- Diverges from "Core for everything" mental model; some readers find the bifurcation harder to navigate
- Existing C5 v1 patches' Core scope becomes inconsistent with Option 2's pure-addon direction → either retire them or accept the inconsistency

## The decisive empirical question

**"Is the cascade structurally reachable only via TB-disconnect, or via any PCIe surprise removal?"**

Either option is technically defensible; the audit picks the right one.

## Audit work plan

### Step 1 — Code-level source audit (4-8 hours, no hardware needed)

For each of the 11+ observed assertion sites, trace the caller chain upstream. For each path:

1. Is the trigger event TB-specific (cable unplug, TB tunnel teardown) or general PCIe (any pci_remove, any AER fatal)?
2. Is the code path gated on `is_external_gpu` anywhere?
3. Would a discrete-x16 GPU experiencing PCIe link drop reach the same call site?

Output: `docs/missions/mission-1-egpu-hot-plug-hot-power/cascade-scope-audit.md`. Per-site analysis + class summary.

### Step 2 — Issue-tracker survey (1-2 hours)

Grep NVIDIA/open-gpu-kernel-modules issue tracker for:
- "Xid 79" / "fallen off the bus" + non-eGPU keywords (e.g., "RTX 3090", "server", "rack")
- "GPU Reset Required" + non-eGPU mentions
- Reports of similar cascade behavior without TB involvement

Append findings to the audit doc.

### Step 3 (OPTIONAL but valuable) — Cross-hardware empirical test (varies)

**Per user's offer**: if another system with a non-TB-attached RTX 5090 (direct PCIe x16) is available, run a controlled test that triggers PCIe surprise removal on that system using the same patched driver:

- Same `apnex/nvidia-driver-injector:595.71.05-aorus.16` image
- Same kernel + cmdline (or equivalent)
- Trigger options:
  - Software remove + rescan (E11 mechanism) — graceful path, baseline
  - PCIe slot hot-eject if backplane supports — non-TB surprise removal
  - Power-cycle the discrete GPU's external power if hot-swap-capable
  - bpftrace-induced pci_remove call (synthetic, but exact same callback path)

**Forensic methodology**:
1. Baseline cold-plug, capture get-pci-stats + must-gather
2. Run trigger
3. Watch journalctl for Xid 79/154 + assertion site list
4. Compare to E07 Run 3 forensic record on the TB system

**Predicted outcomes:**
- If non-TB surprise removal ALSO produces the cascade → Option 1 confirmed
- If non-TB surprise removal does NOT produce the cascade (driver tears down cleanly) → Option 2 has empirical support
- If a NEW cascade appears with different assertion sites → both options need refinement

This empirical test would resolve the binary decision with hardware evidence, not just source reading. Estimated effort: 2-3 hours on the alternate system + setup.

### Step 4 — Decision + plan

Audit + (optional) empirical test produce a clear recommendation. Then:
- Pick Option 1 or Option 2
- Write the implementation plan for the chosen option
- Begin Phase 1 (TB-bus hook investigation or pci_remove callback work, depending on choice)

## What's PARKED until the audit lands

- C5 v3 source patches: STAY LANDED at fork branch `c5-crash-safety` tip `1a7f39ab` and downstream rebases. Status = `partial-v3-needs-v4-architectural`. They work for the 2 sites they covered; harmless beyond that.
- aorus.16 container: STAYS DEPLOYED. The patches don't make things worse; they just don't cover the full failure class.
- Phase 2.1/2.2 experiments: REMAIN BLOCKED on safe broken-BAR1 production. The architectural decision gates progress here.
- Recipe A in `_STARTING-STATE-RECIPE.md`: still hazardous; cable yank still wedges. Use Recipe B (software remove) for any Phase 2.1 work that can use it.

## Cross-references

- `architectural-funnel-redirection-design.md` — SUPERSEDED by this doc for the Option 1 vs Option 2 framing. The funnel mechanics described there are still useful as Option 1 implementation reference.
- `experiments/E07-cable-replug-drain-first.md` — Run 1/2/3 empirical record
- `c3-c5-integration-audit.md` — patch placement audit (now applies only to Option 1 implementation)
- `pci-cmdline-audit.md` — companion BAR1 work, separable but related
- `consumer-holders-and-teardown-future-work.md` — quiesce tooling, complementary regardless of Option chosen
- Memory: [[feedback_funnel_vs_per_site_patching_2026_05_26]] — the architectural-vs-site lesson
- Memory: [[feedback_premature_success_overreach_pattern_2026_05_26]] — discipline lesson for the next iteration
