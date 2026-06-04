# A12 — Complete GSP-bootstrap funnel: design-of-record (2026-06-04)

**Status:** DESIGN-OF-RECORD — approved 2026-06-04, **pending implementation** (next session).
No code yet. Nothing upstream (held behind the deliberate upstream gate).

**One line:** Extend the *proven* A6 bounded-wait + A10-v2 completion-state discriminator
from the single H-OA1 site to a **complete funnel** over the **provably-closed** set of
GSP-bootstrap entry paths, so a stuck chip-init can never wedge the host from *any* entry —
closing the H-OA2 gap (the last clearly-ours in-driver wedge gap, #282).

---

## 1. The problem (H-OA2 + the full entry set)

Lazy init (`NVreg_GpuInitOnProbe=0`) defers the ~1.3–1.9 s cold `RmInitAdapter`/GSP bootstrap to
the first device open. On a #979-divergent chip that init can stall indefinitely holding
`nvl->ldata_lock` → silent host wedge (the F40/F44/F45 class). **A6 bounds only ONE of the entry
paths** (H-OA1, the `/dev/nvidia0` foreground open). The injector's own persistence-engage open and
several kernel-internal paths run the same init **un-bounded** (the H-OA2 gap).

## 2. The provably-closed entry set (VERIFY gate, source-confirmed)

`kgspBootstrap_HAL` — the single RM GSP-bootstrap primitive — has **exactly two call sites in all of
RM**: `kernel_gsp.c:4798` (cold init, via `kgspInitRm`) and `gpu_suspend.c:250` (resume, via
`gpuPowerManagementResume`). So there are **two disjoint bootstrap families**, and the entry set is
**closed — no hidden 7th/8th path**:

**FAMILY 1 — cold init** (`rm_init_adapter`, the sole non-Tegra OS caller of `RmInitAdapter`,
`osapi.c:1772`), funneled at **`nv_start_device` (nv.c:1380, calls `rm_init_adapter` @ nv.c:1527)**.
Five limbs reach it:
- **1a** H-OA1 foreground — `nvidia_open` (nv.c:1877) → `nv_open_device_for_nvlfp` → `nv_open_device`
  (nv.c:1666) → `nv_start_device`. Holds `ldata_lock`. **[A6 bounds only this.]**
- **1b** O_NONBLOCK deferred — `nvidia_open_deferred` (nv.c:1792) on the per-device `nvl->open_q`
  kthread. Holds `ldata_lock` (nv.c:1812).
- **1c** in-kernel `nvidia_dev_get` (nv.c:5416) — modeset (`.open_gpu`, nv-modeset-interface.c:156),
  dmabuf (nv-dmabuf.c:1514), P2P. Holds `ldata_lock`. **[H-OA2]**
- **1d** in-kernel `nvidia_dev_get_uuid` (nv.c:5530) — UVM (nv_uvm_interface.c:151), P2P. **[H-OA2]**
- **1e** `nv_pci_probe` (nv-pci.c:2239) — latent under `NVreg_GpuInitOnProbe=1` (live config `=0`).

**FAMILY 2 — power resume** (a *separate* RM bootstrap that does NOT transit `nv_start_device`):
- `rm_power_management(RESUME)` via `nv_power_management` (nv.c:~4550) — system resume.
- `rm_transition_dynamic_power` via `nvidia_transition_dynamic_power` — runtime-PM / RTD3 / GC6-exit
  (also reachable via `subdeviceCtrlCmdGc6Exit → gpuResumeFromStandby → gpuPowerManagementResume`).

**Completeness:** bounding `{nv_start_device}` + `{the two Family-2 resume sites}` covers the entire
closed set (1 funnel + 2 site-wraps = 3 bound points). This is the funnel discipline applied with a
*provable* completeness proof — the property all prior per-site attempts lacked.

## 3. What four adversarial design passes proved (the load-bearing conclusions)

The pursuit of *instant* structural perfection (fast-return, no flush, no held lock) ran four
design→red-team iterations (~70 agents). It **proved instant in-driver perfection is impossible**,
and pinned exactly why — three fundamental, all closed-RM / NVIDIA-owned:

- **① Closed-RM abort latency.** A10-v2's lock-free `os_pci_set_disconnected` dead-bus marker
  self-terminates *only* the cold-init lockdown-release poll
  (`gpuTimeoutCondWait(_kgspLockdownReleasedOrFmcError)`, reads MMIO → `0xFFFFFFFF`). A stall at any
  *other* RM wait bounds only to a finite RM `gpuTimeout` (~4 s graphics / ~30 s compute).
- **② Resume holds the global RM API lock across its GSP poll.** Cold init *releases* the API lock
  before the poll (relaxed GSP init locking, `kernel_gsp.c:4783-4785`) — which is why A10-v2's
  marker-based self-termination works there. Resume (`rm_power_management`, dynamic-power.c:2568)
  does **not** release it, so a *detached* resume worker would leak the API lock → unbounded hang.
  You cannot fast-return-and-detach the resume family.
- **③ A timeout is not proof of loss (the deepest).** A detached worker can run to *success* after
  the caller declared the GPU lost — false-dead-busing a *healthy* chip and orphaning `usage_count`.
  The only way to know the real outcome is to **wait for the worker**.

**Therefore A6's `flush_work` + A10-v2's grace-discriminator are structurally load-bearing, not a
stopgap.** Waiting is *how you distinguish a slow-but-healthy init from a genuinely-stuck one*
without bricking a healthy chip. The apnex.29 mechanism (3000 ms budget + 2000 ms grace) is
**near-optimal**, and the four-pass pursuit *vindicated* it.

### The crucial reframe
- **The host WEDGE (the failure mode) is perfectly, structurally closeable** by the complete funnel:
  every GSP-bootstrap entry bounded to a finite, host-alive outcome; healthy inits succeed within
  budget; the host never wedges from any path.
- **The sole residual is a bounded recovery *latency*** (up to RM `gpuTimeout` on a genuinely-stuck
  non-lockdown stall, holding a lock) — **closed-RM, NVIDIA's to make instant**. *It is a latency,
  not a wedge.*

## 4. The design (A12)

**`nv_bootstrap_bounded(nv, sp, fn)`** — one reusable bounded-wait primitive, reusing A6's validated
shape (dedicated **global `system_long_wq`** worker — NOT the per-device `open_q`, which caused the
AB-BA inversions in passes 2–3) + A10-v2's grace-discriminator + the C5 dead-bus marker, applied at
the 3 bound points of §2. The `flush_work` join is **kept** (it is load-bearing per ③).

- **Family 1:** refactor `nv_start_device` body verbatim into `__nv_start_device_locked`; make
  `nv_start_device` the bounded shim (gated `NVreg_TbEgpuOpenTimeoutMs==0 || !nv->is_external_gpu` →
  byte-identical passthrough). This single cut subsumes A6 and extends the bound to limbs 1b–1e.
- **Family 2:** wrap the two resume call sites the same way (same `system_long_wq` shape). For the
  resume API-lock (②), the bound is the finite-RM-timeout hold (accepted residual), NOT a detach.
- **In-kernel limbs (1c/1d):** stay **synchronous-but-bounded** — the bound runs the init off the
  lock-holding caller's thread; the caller blocks in `wait_for_completion_timeout` and returns a
  synchronous `rc` exactly as today (no `ldata_lock` drop/reacquire — that was a pass-2/3 break).
- **Optional `worker-owned-sp`:** VERIFY confirmed the worker may allocate its own `nvidia_stack_t`
  (`nv_kmem_cache_alloc_stack`, the driver's own idiom) and the `nvlfp` result write may move
  caller-side (post-completion, success-only). This *trims* the UAF surface but is **not required**
  once the flush is kept (the flush already prevents the `nvlfp`/`sp` UAF). Treat as a simplification
  to evaluate at implementation, not a load-bearing element.

## 5. Sole residual (upstream-RM, gated)

Instant termination of the genuinely-stuck non-lockdown case needs two NVIDIA-RM changes:
(a) make every GSP-bootstrap poll consult the dead-bus sentinel (so `①` self-terminates everywhere);
(b) release the API lock on the resume path (so `②` can self-terminate). Both are closed-RM, parked
behind the deliberate upstream gate. **Until then, the bounded-latency residual is correct + safe
(host always alive).**

## 6. Implementation plan (next session)

1. **Carve A12** on a fork branch (addon, L1; A-prefix). Refactor `nv_start_device` (verbatim body
   move — keep the `failed:`/`failed_release_irq:` goto labels intact; range-diff). Add the two
   Family-2 resume wraps. Re-derive the join/lifecycle proof at the new sites.
2. **Honor the red-team constraints** (avoid re-introducing the prior breaks): no `open_q` for the
   foreground/in-kernel bound (use `system_long_wq`); a **sound join across `nv_pci_remove`/stop**
   (arm the dead-bus marker FIRST, then `cancel_work_sync`/`flush_work` on a per-`nvl`-tracked slot,
   BEFORE `down(&ldata_lock)` at nv-pci.c:2426); cover the A3-recovery re-init interaction (the
   bounded worker must not become an A3 AB-BA); keep `nv_system_pm_lock` ordering correct.
3. **Subsume A6/A10-open** — the funnel *replaces* A6's per-open wrapper (net simplification); A10-v2
   discriminator + budget/grace move to the funnel.
4. **Validate** — compile (full composition `make modules`); then the `rung-a10v2` fastfail suite
   (n≥3) at the production defaults, confirming all 5 cold-init limbs + a resume path bound correctly;
   passive-only on a suspect chip. Then apnex.NN + soak.
5. **Carry the upstream-RM residual note** into the upstream-plan (gated).

## 7. Cross-refs
- Finding: `finding-2026-06-04-a6-open-budget-vs-healthy-cold-init.md` (the H-OA2 gap + budget).
- A6/A10/A9 intents: `docs/patch-intents/{A6,A10,A9}-*.md`.
- Failure modes: `fake-5090/failure-modes/F46-hoa2-unbounded-init-wedge.md` (new), `F40` (updated).
- Tasks: #282 (open-arm), #301 (catalog reconciliation).
- The 4 design workflows (transcripts in this session): per-site/funnel/eager/async (wf 1);
  perfection pass (wf 2, all broke); constraint-driven (wf 3, all broke); final worker-owned-sp +
  entry-enumeration (wf 4 — VERIFY passed both gates, designs broke on ②③ → proved instant-perfection
  impossible).
