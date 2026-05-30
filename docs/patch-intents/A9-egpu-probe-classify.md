---
id: A9-egpu-probe-classify
layer: addon
source-branch: a9-egpu-probe-classify
upstream-candidacy: n/a
telemetry-tier: none
status: draft
related-patches: [E1-egpu-detection, A6-f40b-bounded-wait-open, A7-f40b-bounded-wait-shutdown, A8-f40b-sysfs-observability]
---

# A9-egpu-probe-classify — Probe-Time eGPU Classification for the A6/A7 Bounded-Wait Gates

## Purpose

Close the A6/A7 **first-open coverage hole**. A6 (open path) and A7 (shutdown path) gate their bounded-wait wrappers on `nv->is_external_gpu`. The closed RM sets that flag in exactly one place — `osinit.c:1301`, inside `RmInitNvDevice`, which runs **during the first open's `RmInitAdapter`**. A fresh `nv_state_t` is zeroed at probe, so the flag is FALSE on the **first** open of any bind → A6/A7 fall through to the synchronous path → on a userspace-recovered chip the first open runs the GSP-lockdown busy-poll on the syscall thread holding the GPU lock → host hard-wedge (reproduced 2026-05-31; forensics `docs/missions/mission-1-egpu-hot-plug-hot-power/experiments/OA-reset-ladder-wedge-forensics-2026-05-31.md`). Any re-probe onto a bad chip (manual rebind, PCI-error recovery, A3 `slot_reset`, hot-plug) hits the same unguarded first open.

A9 sets `nv->is_external_gpu` at **probe**, in `nv_pci_probe` immediately after `nv->handle = pci_dev`, via E1's probe-safe detector `os_pci_is_thunderbolt_attached(nv->handle)` (pure PCI topology — no chip MMIO, no GPU lock). The value is byte-identical to the blob's lazy set (E1 made `RmCheckForExternalGpu`'s entire body that one call), so the classification is simply made authoritative *before* the first open. A6/A7 gates are unchanged. Carved in the **addon** layer so E1 (the upstream-bound detector) stays untouched; A9 changes only the set-*timing*, a project-local workaround.

## Requirements

### Requirement: Driver SHALL establish nv->is_external_gpu at PCI probe time

The driver MUST, inside `nv_pci_probe`, immediately after the `nv->handle = pci_dev` assignment, set `nv->is_external_gpu = os_pci_is_thunderbolt_attached(nv->handle)`. This makes the E1 eGPU classification authoritative before the first `/dev/nvidia*` open, so the A6 open-path and A7 shutdown-path bounded-wait gates engage on the **first** open/close of a bind — not only the 2nd+. The set MUST occur on the synchronous probe thread holding no GPU lock, and MUST NOT issue any chip MMIO.

#### Scenario: Probe-time classification arms A6 on the first open of a Thunderbolt eGPU

```
GIVEN nvidia.ko is loaded with NVreg_TbEgpuOpenTimeoutMs=200 (A6 enabled)
AND   nv_pci_probe runs for a Thunderbolt/USB4-attached GPU
WHEN  probe reaches the point immediately after nv->handle = pci_dev
THEN  os_pci_is_thunderbolt_attached(nv->handle) SHALL return NV_TRUE (pure PCI topology, no chip touch)
AND   nv->is_external_gpu SHALL be NV_TRUE before nv_pci_probe returns
AND   the FIRST subsequent open of /dev/nvidia0 SHALL take A6's bounded-wait path, emitting "tb_egpu [F40b]: open scheduled to bounded worker (timeout=200 ms)"
```

#### Scenario: No behaviour change for a non-eGPU device

```
GIVEN nv_pci_probe runs for a non-Thunderbolt (internal) NVIDIA GPU
WHEN  the probe-time classification runs
THEN  os_pci_is_thunderbolt_attached(nv->handle) SHALL return NV_FALSE
AND   nv->is_external_gpu SHALL remain NV_FALSE
AND   A6/A7 SHALL fall through to the original synchronous path with zero behaviour change
```

### Requirement: The probe-set SHALL be correctly placed and monotonic

The probe-set MUST be placed **after** the `nv->handle = pci_dev` assignment — placing it before yields `os_pci_is_thunderbolt_attached(NULL) == NV_FALSE`, a silent no-op that re-introduces the wedge with no compile error. The driver MUST NOT write `nv->is_external_gpu = FALSE` anywhere: the only two writers SHALL be this probe-set and the blob's TRUE-only set at `osinit.c:1301`, making the flag strictly monotonic (probe-set can only ADD arming; the blob's redundant set is self-healing). A future FALSE-writer would silently disarm A6/A7 — this invariant is load-bearing.

#### Scenario: Re-probe keeps the flag correct (the reset-ladder wedge, now closed)

```
GIVEN a Thunderbolt eGPU bound by nvidia.ko is unbound then rebound (nv_pci_remove frees nv_state_t; nv_pci_probe allocates a fresh zeroed one)
WHEN  the fresh probe runs the probe-time classification
THEN  nv->is_external_gpu SHALL be NV_TRUE again before the first open of the new bind
AND   the tb_egpu_is_external sysfs attribute (A8 v2.2) SHALL read 1 from probe onward
AND   the first open of the new bind SHALL be guarded by A6 (the 2026-05-31 reset-ladder R0.5 first-open wedge no longer recurs for this site)
```

## Scope boundary

A9 closes the **A6-coverable first-open hole (the H-OA1 site:** wedge inside `RmInitAdapter` on the worker-queued `nv_open_device_for_nvlfp`**)**. It explicitly does NOT:

- fix the co-leading **H-OA2** pre-`nv_open_device` PM-resume site (flag timing does not reach it; H-OA1/H-OA2 are equal-prior, n=1, unresolved);
- cover `NVreg_GpuInitOnProbe=1` (`nv_start_device` is called raw from probe, not via the bounded wrapper; live config is `=0`);
- **prevent the wedge.** A9 converts an immediate syscall-thread wedge into A6's bounded `-EIO` — with a worker A6 leaks. So the claim is "closes the A6-coverable first-open hole," never "fixes the open-arm wedge."

`RmForceExternalGpu` is retired (zero references tree-wide); the probe-time helper output equals the blob's classification, so there is no override to honour.

**Deferred (coupled follow-up, not A9):** arming A6 on a bad-chip first open routes the wedge into A6's leaked worker, surfacing two pre-existing A6 risks (one root — the refcount-2 leak): the worker holds the GPU lock until it exits (the open-arm sink-fail-fast assumption is unverified), and A6 has no `flush_work` UAF guard (`fake-5090` F42; A7 has the SH-3 guard). The principled fix — a provably self-terminating, then joined, A6 worker (the A6 "leak→join lifecycle" hardening, queued in `docs/architecture-v5-deep-review-queued.md`) — is driven by a destructive first-open-on-bad-chip test and is out of A9's scope.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| *(none — A9 emits no log lines of its own)* | n/a | n/a |

A9 is `telemetry-tier: none`: it sets one classification flag at probe and emits no telemetry. Its observable effect is on *existing* surfaces — A6/A7's mandatory-tier lines (`"tb_egpu [F40b]: open scheduled to bounded worker"`, the `tb_egpu_f40b_fires` counter) now fire on the **first** open/close of a bind, and A8's `tb_egpu_is_external` sysfs attribute reads `1` from probe onward (the standing pre-flight invariant whose violation caused the 2026-05-31 wedge).

## Provenance

- **Source cluster**: addon — project-local; closes the A6/A7 first-open coverage hole by making E1's eGPU classification authoritative at probe. The detector (`os_pci_is_thunderbolt_attached`) is E1's (base, upstream-bound); A9 changes only the set-*timing* — the project-local workaround. The chip-side root cause is NVIDIA bug #979 and out of scope for our fork.
- **Empirical validation**: compile-validated (the composed C1–C5 + E1 + A1–A9 set builds against kernel 7.0.9-204.fc44; `tools/regen-base-patches.sh` validate OK). Healthy-deploy verification (`tb_egpu_is_external`=1 from probe; first open emits the bounded-worker line; invariant holds across unbind→rebind) and the destructive first-open-on-bad-chip test are gated/pending — until the latter passes, the claim is "closes the hole, compile- + healthy-sysfs-validated," NOT "wedge survived."
- **Vanilla baseline files**: `kernel-open/nvidia/nv-pci.c` — one line inserted in `nv_pci_probe`, immediately after `nv->handle = pci_dev;`: `nv->is_external_gpu = os_pci_is_thunderbolt_attached(nv->handle);` (plus its comment block). No other files touched. A6/A7 gates unchanged; E1 unchanged.
- **Fork branch**: `a9-egpu-probe-classify` (in `/root/open-gpu-kernel-modules`, forked from `a8-f40b-sysfs-observability`; not yet pushed to the apnex fork).
- **Injector main commits**: pending (this intent doc + the regenerated `patches/addon/A9-egpu-probe-classify.patch` + `patches/manifest` + indices).
- **Image first deployed**: pending — `apnex/nvidia-driver-injector:595.71.05-apnex.24` (A9 + A8 v2.2), gated on a deploy window.
- **Upstream candidacy**: n/a — addon. The set-timing workaround is project-local; the upstream-relevant artifact is E1's detector and the broader observation that the RM classifies `is_external_gpu` too late for any open-driver consumer (a candidate to raise on #979 once the open-arm characterization lands).
- **Spec / forensics**: `docs/superpowers/specs/2026-05-31-a9-egpu-probe-classify-design.md`; `docs/missions/mission-1-egpu-hot-plug-hot-power/experiments/OA-reset-ladder-wedge-forensics-2026-05-31.md`; failure mode `fake-5090/failure-modes/F42-leaked-bounded-wait-worker-uaf.md`.
