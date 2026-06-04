---
id: A12-init-funnel
layer: addon
source-branch: a12-init-funnel
upstream-candidacy: medium
telemetry-tier: nominal
status: implemented-compiled-validated
related-patches: [A6-f40b-bounded-wait-open, A10-f40b-lockfree-sink, A9-egpu-probe-classify, A8-f40b-sysfs-observability, A3-recovery, C5-crash-safety]
---

# A12-init-funnel — Bound EVERY GSP-bootstrap entry, not just the H-OA1 open

## Purpose

The driver SHALL bound the chip-touching GSP bootstrap on a #979-divergent eGPU
at EVERY entry point, so a stuck init can never wedge the host — not only the
H-OA1 `/dev/nvidia0` foreground open (which A6 already bounded), but also the
H-OA2 entries the deployed driver runs UN-bounded: `nvidia_dev_get` /
`nvidia_dev_get_uuid` (modeset/UVM/P2P), the deferred-open path, `nv_pci_probe`,
and the power-resume RM bootstrap. The persistent capability granted:
**"a stuck chip-init returns a finite, host-alive `-EIO` from any entry, instead
of an unbounded host wedge — by construction, over a provably-closed entry set."**
Closes H-OA2 (#282), the last clearly-ours in-driver wedge gap.

## Mechanism

A12 relocates the PROVEN A6 bounded-wait + A10-v2 grace-discriminator from the
single per-open site DOWN to a reusable funnel primitive, and applies it at the
two RM bootstrap families.

- **`nv_bootstrap_bounded(nv, sp, fn)`** — A6's `system_long_wq` worker +
  `wait_for_completion_timeout(NVreg_TbEgpuOpenTimeoutMs)` + A10-v2 grace re-wait
  (`NVreg_TbEgpuOpenGraceMs`) + lock-free `os_pci_set_disconnected` dead-bus
  marker + C5 sink + **`flush_work` join (KEPT)**, generalized to a function
  pointer. The worker struct carries `{nv, sp, fn}` and **never `nvlfp`**.
- **Family-1 cold init:** `nv_start_device` body moved verbatim into
  `__nv_start_device_locked`; `nv_start_device` becomes the bounded shim
  (`nv_bootstrap_bounded(nv, sp, __nv_start_device_locked)`). Because
  `rm_init_adapter` has exactly one caller (`nv_start_device`) and all 5 cold-init
  limbs reach it through `nv_open_device`/`nv_pci_probe`, this one cut bounds the
  whole family. **Subsumes A6** (the per-open `nv_open_device_for_nvlfp_bounded`
  is deleted; its call site reverts to the plain call; A10-v2's open-arm logic
  re-homes into the primitive).
- **Family-2 system-resume:** `rm_power_management(RESUME)` bounded via
  `__nv_pm_resume_locked`. (`kgspBootstrap` has exactly 2 RM call sites — cold
  init + resume — so the entry set is provably closed; no hidden 3rd family.)
- **Family-2 runtime-PM:** `rm_transition_dynamic_power` on the GC6/RTD3-exit
  (`enter==NV_FALSE`) path bounded via `nv_dynpower_bounded` (a dedicated wrapper —
  the generic fn-pointer funnel can't carry its `bTryAgain` out-param). Holds no
  `ldata_lock` (PM-core runtime callback, lower severity), bounded for completeness.

### Provably-closed entry set
`kgspBootstrap_HAL`: `kernel_gsp.c:4798` (cold) + `gpu_suspend.c:250` (resume).
Bounding `{nv_start_device}` (Family-1, all 5 cold-init limbs) + `{rm_power_management
RESUME, rm_transition_dynamic_power exit}` (Family-2, both sites) covers EVERY
GSP-bootstrap entry. No hidden 3rd family.

### Why `flush_work` is KEPT (load-bearing, not a stopgap)
The four-pass adversarial design (design-of-record §3) proved instant in-driver
termination impossible: (①) the dead-bus marker self-terminates only the lockdown
poll; (②) resume holds the RM API lock across its poll; (③) **a timeout is not
proof of loss** — a detached worker can run to success after the caller declared
the GPU lost, bricking a healthy chip. So the worker MUST be joined to learn its
real outcome. Keeping the synchronous join also means the worker never outlives
its caller → no detached worker for `nv_pci_remove` to race (teardown soundness by
construction), and the worker touches only the caller's `sp` (no `nvlfp` → A6's
F42 UAF surface is gone).

## Requirements

### Requirement: Every GSP-bootstrap entry is bounded by construction
On an E1/A9-classified external GPU with `NVreg_TbEgpuOpenTimeoutMs > 0`, a
chip-touching init reached via ANY of {foreground open, deferred open,
`nvidia_dev_get`, `nvidia_dev_get_uuid`, `nv_pci_probe`, system-resume,
runtime-PM GC6/RTD3-exit} SHALL run off the lock-holding caller thread and return a
finite error on timeout, never an unbounded wedge. Non-eGPU / `timeout==0` paths
SHALL fall through byte-identically.

### Requirement: A slow-but-healthy init must not be sunk
The grace discriminator (`NVreg_TbEgpuOpenGraceMs`) SHALL distinguish a worker that
RETURNED within grace (fast-fail — chip NOT sunk, recoverable) from one still stuck
(lockdown — dead-bus marker + C5 sink). The budget (`NVreg_TbEgpuOpenTimeoutMs`,
3000ms composed) SHALL exceed a healthy full cold init (~1.3–1.9s) so healthy inits
complete within budget (apnex.29 fix, #299/#300).

### Requirement: No new lock inversion or UAF
The funnel SHALL use the global `system_long_wq` (NOT the per-device `open_q`), keep
the `flush_work` join (no detached worker), and carry no caller-frame `nvlfp`. The
A3 post-rminit grafts (now on the worker thread) SHALL remain async-only
(`schedule_work`, no self-join, no blocking lock) — verified.

## Residual (carried, upstream-RM)
A genuinely-stuck non-lockdown stall holds the `flush_work` up to RM `gpuTimeout`
(~4–30s) with `ldata_lock` held — finite, host-alive (the ① closed-RM residual).
Making it instant needs two NVIDIA-RM changes (sentinel-aware bootstrap polls +
release the API lock on resume); parked behind the deliberate upstream gate.

## Validation
- **Compile:** full composition (19 patches, A12 after A10) builds `make modules`
  against kernel 7.0.9-204.fc44. PASS.
- **Verbatim move:** range-diff confirms no `__nv_start_device_locked` body
  statement changed.
- **Live fastfail** (`rung-a10v2-validate.sh fastfail`, all 5 cold-init limbs + both
  Family-2 sites) + apnex.30 cutover: DEFERRED to post-apnex.29-soak, operator-present.

## Cross-refs
Design-of-record `docs/missions/mission-1-egpu-hot-plug-hot-power/design/A12-init-funnel-design-of-record-2026-06-04.md`;
plan `docs/superpowers/plans/2026-06-04-a12-init-funnel.md`;
failure modes fake-5090 `F46` (new) / `F40` (updated); tasks #282, #302.
