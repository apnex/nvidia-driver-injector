# Architectural funnel redirection — design for C5 v4

**Status:** v1 design proposal 2026-05-26 — written after E07 Run 3 revealed C5 v3 is incomplete
**Purpose:** Propose pivoting from per-site assertion patching (C5 v3's approach) to architectural redirection: catch the GPU crash earlier in the kernel layer flow, propagate state via a single sink-state marker, funnel ALL downstream paths through a small number of guard points instead of patching N assertion sites individually.
**Goal:** patch surface shrinks from ~50 sites (and growing as each test reveals new ones) to ~10 fixed-shape touch points; correctness scales with detection coverage, not with site-discovery completeness.

## Why pivot now

C5 v3's site-patching approach has hit its limit:

- v1 caught 2 sites empirically observed firing (`rs_client.c:855`, `rs_server.c:272`)
- v3 expanded to 8 via grep sweep using `NV_ASSERT.*== NV_OK.*NV_ERR_GPU_IN_FULLCHIP_RESET`
- E07 Run 3 found 3 MORE sites the regex missed:
  - `osinit.c:2462` — narrow `NV_ASSERT(status == NV_OK)` (sweep regex too narrow)
  - `kern_fsp_gh100.c:649` — arithmetic invariant on dead-bus reads (different failure class, structurally outside the macro-relaxation approach)
  - `gpu_user_shared_data.c:248` — `NV_CHECK_OK` (different macro family)

**The empirical pattern**: each iteration of the sweep finds more sites. The failure-mode surface is unbounded — the open NVIDIA driver has ~1M lines of code, and any line that operates on dead hardware is a potential assertion site. Continuing to patch per-site will eventually catch every site, but it's the wrong tool: the rate of finding new sites isn't decreasing fast enough to converge.

**The architectural alternative**: don't try to make every assertion site tolerant of dead-bus state. Instead, **prevent every assertion site from ever being reached when the GPU is dead** — by intercepting at the very top of the call stack and short-circuiting all subsequent driver paths.

This is the v4 direction.

## Current architecture (the problem shape)

```
        (cable yank — earliest possible signal)
                       │
                       ▼
      ┌────────────────────────────────────┐
      │ TB layer (drivers/thunderbolt)     │  (no driver hook)
      └─────────────────┬──────────────────┘
                        │
                        ▼
      ┌────────────────────────────────────┐
      │ PCI core: pci_remove callback      │  ← nvidia.ko hooks here for graceful path
      └─────────────────┬──────────────────┘
                        │
                        ▼
      ┌────────────────────────────────────┐
      │ nvidia.ko nv_pci_remove            │
      │  — entered, processes teardown     │
      └────────────────────────────────────┘

   (parallel detection paths, all retroactive)
                        │
       ┌────────────────┼────────────────┬──────────────────┐
       ▼                ▼                ▼                  ▼
  osHandleGpu       osDevRead       A2 Q-watchdog         RPC timeouts
   Lost (osinit)    Reg032 (os.c)   (5Hz heartbeat)       (GSP_RPC_TIMEOUT)
   ─ retry then     ─ MMIO returns  ─ active probe        ─ delayed bubble-up
     declare lost     0xFFFFFFFF
       │                │                │                  │
       └────────────────┴────────────────┴──────────────────┘
                        │
                        ▼
              (sets PDB_PROP_GPU_IS_LOST  +/-  os_pci_set_disconnected)
                        │
              (markers inconsistent — propagation gap C5 v3 partially fixed)
                        │
                        ▼
        ┌─────────────────────────────────┐
        │  ALL DOWNSTREAM CODE PATHS      │
        │  ──────────────────────────────  │
        │  must check the markers themselves│
        │  and return / tolerate GPU_IS_LOST │
        │                                  │
        │   ~50+ assertion sites in:      │
        │   - kernel_graphics.c            │
        │   - fecs_event_list.c            │
        │   - kernel_falcon_tu102.c        │
        │   - kernel_gsp_tu102.c           │
        │   - vaspace_api.c                │
        │   - mem.c                        │
        │   - rs_server.c                  │
        │   - osinit.c                     │  ← Run 3 found this
        │   - kern_fsp_gh100.c             │  ← Run 3 found this (different class)
        │   - gpu_user_shared_data.c       │
        │   - (and many more not yet found)│
        └─────────────────────────────────┘
                        │
                        ▼
        ((any site that misses the check → assertion fires → wedge cascade))
```

The fundamental problem: **detection happens late, propagation is uneven, and the contract that every site must respect the dead-state is enforced site-by-site.** N grows; coverage is incomplete; each new failure class needs a new patch round.

## Proposed v4 architecture (funnel-based)

```
        (cable yank — earliest possible signal)
                       │
                       ▼
      ┌────────────────────────────────────┐
      │ TB layer event subscription (NEW)  │  ← v4 hook #1: subscribe
      │ struct tb_service_driver           │      to thunderbolt unplug events
      │  .remove callback                  │      for our device
      └─────────────────┬──────────────────┘
                        │
                        ▼ IMMEDIATELY on TB unplug:
              ┌─────────────────────────────────────┐
              │ atomic_set(&nvl->device_dead, 1)    │  ← single sink-state flag
              │ os_pci_set_disconnected(nv->handle) │     (in addition to existing
              │ smp_wmb()                           │      Linux marker)
              └─────────────────────────────────────┘
                        │
                        ▼
      ┌────────────────────────────────────┐
      │ PCI core: pci_remove callback      │  ← v4 hook #2: backup detection
      │ nv_pci_remove (already implemented)│     (if TB hook missed for some reason)
      │ ALSO sets device_dead              │
      └────────────────────────────────────┘

   (existing parallel detection paths kept as belt+braces; all also set device_dead)

                        │
                        ▼
              osIsGpuBusDead(pGpu) ← UNCHANGED — already checks both markers
                                     PLUS the new device_dead flag (additive)
                        │
                        ▼
   ┌────────────────────────────────────────────────────────┐
   │           SMALL SET OF FUNNEL POINTS                   │
   │           ──────────────────────────                   │
   │  Every GPU access path in the driver MUST              │
   │  enter through one of these guarded funnels:           │
   │                                                         │
   │  1. osDevReadReg{08,16,32}    (MMIO — guarded by C5 v1)│
   │  2. NV_PRIV_REG_RD32          (raw MMIO — NEW guard)   │
   │  3. _issueRpcAndWait          (GSP RPC — guarded by C5)│
   │  4. rpcRmApiAlloc_GSP         (NEW guard)              │
   │  5. rpcRmApiControl_GSP       (NEW guard)              │
   │  6. rpcRmApiFree_GSP          (guarded by C5)          │
   │  7. nvkms_*                   (KMS — minor, NEW guard) │
   │  8. nvidia_open / nvidia_release (IOCTL — NEW guard)   │
   │                                                         │
   │  Each guard: if osIsGpuBusDead(pGpu) → return          │
   │  NV_ERR_GPU_IS_LOST (or 0xFF for MMIO reads).          │
   │  ~10 total funnel points.                              │
   └────────────────────────────────────────────────────────┘
                        │
                        ▼ (everything downstream sees consistent dead state)
                        │
   ┌────────────────────────────────────────────────────────┐
   │  Downstream assertion sites NEVER REACHED on dead-GPU  │
   │  because every path to them passes through a funnel    │
   │  that fast-fails first.                                │
   │                                                         │
   │  → Per-site assertion patching is no longer needed     │
   │  → New failure-mode discovery doesn't trigger new      │
   │    patches; the funnel already covers it               │
   └────────────────────────────────────────────────────────┘
```

## Key design decisions

### Detection layer: TB-bus hook for earliest possible signal

The Linux thunderbolt subsystem exposes `struct tb_service_driver` and bus-level event subscription. By registering a tb_service or a notifier on the thunderbolt bus, nvidia.ko can be notified of unplug BEFORE `pci_remove` fires.

This is "Sub-mission C critical path" from `experiments/E07-cable-replug-drain-first.md`: catch the unplug at the TB layer, not at the PCI layer. The TB layer typically fires its event ~10-50 ms before the kernel's PCI core processes pci_remove.

**Implementation**: a thin TB-bus notifier in nv-tb-egpu-recover.c or a new nv-tb-egpu-detector.c file. On receiving unplug event for our GPU's parent TB device, set device_dead atomically + propagate to both existing markers.

Alternative: `BUS_NOTIFY_REMOVED_DEVICE` notifier on the PCI bus. Less optimal (later signal) but more portable. Could be used as belt-and-braces alongside the TB hook.

### State marker simplification: single sink-state atomic

Currently three markers being reconciled imperfectly:
- `pci_dev_is_disconnected(pdev)` (Linux PCI core)
- `pGpu->getProperty(PDB_PROP_GPU_IS_LOST)` (RM RmFlags)
- `nv->flags & NV_FLAG_IN_SURPRISE_REMOVAL` (nv_state_t flag)

Plus the implied state from refcounts.

**v4 introduces**: `atomic_t nvl->device_dead` — a single sink-state (set, never cleared during a module lifetime) atomic. Setting it propagates to the others via the existing `os_pci_set_disconnected` and `gpuSetDisconnectedProperties` calls. Reading it is what `osIsGpuBusDead` does (with `atomic_read`).

This **doesn't replace** the existing markers — it adds a unified entry point that callers prefer, with the existing markers as transitive consistency for code that reads them directly.

Why sink-state: GPU loss is monotonic during a module lifetime (until reboot or rmmod). No need for a state machine — just a flag that goes 0→1 once.

### Funnel-point enumeration: small, fixed, and reviewable

The current driver has many entry points but a TRACTABLE NUMBER (~10) of GPU-access funnels:

| Funnel | Location | Already guarded? |
|---|---|---|
| `osDevReadReg08` | os.c | ✓ C5 v1 |
| `osDevReadReg16` | os.c | ✓ C5 v1 |
| `osDevReadReg32` | os.c | ✓ C5 v1 |
| `NV_PRIV_REG_RD32` | nv-priv.h macro | ✗ NEW guard needed (this is the raw direct-MMIO macro that bypasses osDevReadReg32; used in osHandleGpuLost itself) |
| `_issueRpcAndWait` | vgpu/rpc.c | ✓ C5 v1 |
| `rpcRmApiAlloc_GSP` | vgpu/rpc.c | ✗ NEW guard needed |
| `rpcRmApiControl_GSP` | vgpu/rpc.c | ✗ NEW guard needed |
| `rpcRmApiFree_GSP` | vgpu/rpc.c | ✓ C5 v1 (returns NV_OK on dead) |
| `nvidia_open` (IOCTL entry) | nv-frontend.c | ✗ NEW guard — returns -ENODEV on dead |
| `nvidia_mmap` / `nvidia_ioctl` | nv-frontend.c | ✗ NEW guard — returns -ENODEV on dead |
| `nv_state_t access` (RM-side) | various | partially via osIsGpuBusDead callers |

**~10 funnels total**, not 50 assertion sites. And these are STABLE entry points — they don't shift with each driver version like assertion sites do.

### What this DOES NOT replace

- C5 v1's `os_pci_set_disconnected` / `os_pci_is_disconnected` primitives — still valid, still used by the funnels
- A2 Q-watchdog — still valuable as a backup detection path for cases where TB hook + pci_remove both miss (e.g., GPU firmware hang without bus disconnect)
- A3 recovery state machine — still valid for the post-rmInit-FAIL recovery path (different failure class, different recovery mechanism)
- C3 gpu-lost-retry — still valid; the preflight retry is unchanged
- E1 eGPU detection — still valid; the new TB-layer hook would go in E1's neighborhood architecturally

The v4 architectural refactor is ADDITIVE to existing primitives — it ADDS the unifying funnel layer + earlier detection hook on top of what's already there.

### What this RETIRES (or makes optional)

- Per-site `NV_ASSERT_OR_GPU_LOST*` conversions — the assertion sites won't be REACHED when GPU is dead because funnels short-circuit upstream. C5 v3's 8 conversions can stay (defense-in-depth) but new sites discovered in v4-and-beyond testing don't need to be added.
- The site-sweep methodology — replaced by funnel-completeness review (a much smaller and more bounded effort).
- The "expand the regex" loop — converges in v4 instead of going on indefinitely.

## Migration path from v3 → v4

### Phase 1 — investigate the funnel points (no code yet)

1. Identify EVERY entry path from userspace / kernel to RM code that touches GPU state. The 10 funnels above are a first-pass enumeration; verify by source reading.
2. For each, confirm where the dead-state check would go (some funnels already have it from C5 v1).
3. Identify the TB-bus event subscription mechanism in current kernel (thunderbolt driver API stability across versions matters for upstream-PR fitness).

### Phase 2 — add the TB-bus event subscription (new code, isolated)

1. New file: `kernel-open/nvidia/nv-tb-egpu-detector.c` (sibling to nv-tb-egpu-recover.c). Or extend E1's `nv-tb-egpu-detector.c` (TBD naming).
2. Registers a `struct tb_service_driver` or notifier for our GPU's parent TB device.
3. On unplug event: `atomic_set(&nvl->device_dead, 1) + os_pci_set_disconnected + gpuSetDisconnectedProperties + smp_wmb()` — atomic group.
4. Test: cable yank should fire this hook ~10ms BEFORE Xid 79 detection in osHandleGpuLost.

### Phase 3 — add funnel guards at the 5 unguarded entry points

1. `NV_PRIV_REG_RD32` raw MMIO macro — add a `osIsGpuBusDead` check at the top of the macro (or convert it to a function that checks then RDs).
2. `rpcRmApiAlloc_GSP`, `rpcRmApiControl_GSP` — same shape as the existing `_issueRpcAndWait` guard.
3. `nvidia_open`, `nvidia_mmap`, `nvidia_ioctl` — return `-ENODEV` early if `osIsGpuBusDead`.

### Phase 4 — test cable yank under aorus.17

Expected outcome: NO assertion sites fire (because funnels intercept upstream), NO wedge, BAR1=256M observable cleanly post-replug.

### Phase 5 — retire (or downgrade) the C5 v3 per-site conversions

If Phase 4 PASSES cleanly, the per-site conversions become defense-in-depth rather than load-bearing. Could:
- Keep them (no harm, slight code clarity)
- Remove them (smaller diff against vanilla NVIDIA driver for upstream PR)
- Status: TBD based on upstream-PR reviewer preferences

## Patch geometry implications

This v4 work doesn't fit neatly into C5. It's structurally different — adding a new detection hook + new funnel guards. Candidate decompositions:

**Option A**: extend C5 again (v4 amendments) — keeps the patches-named-by-domain pattern.
**Option B**: new cluster — `C6-funnel-guards` (the new entry-point guards) + new addon — `A6-tb-event-detector` (the TB-bus hook).
**Option C**: extend E1 (eGPU detection) with the TB hook + new cluster for the funnels.

My current lean: **B**. The TB hook is an addon (project-specific, transport-aware). The funnel guards are core driver primitives (upstream-friendly, transport-agnostic). Splitting them along the C/A line matches the geometry pattern.

To be decided in the v4 design session with the user.

## Estimated work scope

| Phase | Effort | Risk |
|---|---|---|
| 1 (investigation) | 2-4 hours | Low |
| 2 (TB hook code) | 4-8 hours | Medium (thunderbolt API understanding) |
| 3 (5 funnel guards) | 2-4 hours | Low (pattern is well-established) |
| 4 (test cycle) | 1 hour test + 1 reboot | Medium (validation gate) |
| 5 (retire v3 conversions if desired) | 1-2 hours | Low |
| **Total** | **~10-19 hours** | Medium |

Compared to "expand v3 sweep → catch a few more sites → test → repeat" which we've now done once and would likely need 3-5 more cycles to converge.

## Open questions for the v4 design session

1. **TB-bus event subscription API**: does Linux kernel 7.0.9 expose a stable thunderbolt notifier? If not, PCI bus `BUS_NOTIFY_REMOVED_DEVICE` notifier as fallback.
2. **Funnel completeness**: is the 10-funnel list above actually complete? Need source-tree audit to verify every GPU access path goes through one of these.
3. **Patch geometry**: Option A vs B vs C from above.
4. **Backwards compatibility**: does device_dead atomic need any migration story for in-flight clients holding fds at unplug time?
5. **Verification methodology**: how do we PROVE the funnel approach catches everything? A run that wedges would falsify it; a clean run only confirms the specific failure modes exercised.
6. **Upstream PR posture**: is the funnel-based approach upstream-friendly? Or does NVIDIA's open driver maintainer prefer the per-site approach? (Discussion with maintainer may be worth having before committing.)

## Relationship to Phase 2 mission work

Once v4 lands:
- Cable yank becomes safe (the wedge cascade is intercepted at the funnel)
- Phase 2.1/2.2 experiments unblock (broken-BAR1 can be safely produced)
- E27 bpftrace work unblocks (need to instrument runtime hot-plug allocation, which requires safe broken-BAR1)
- The whole MISSION-1 corrective stack (BAR1 fix + wedge fix) can land together

v4 architectural success is therefore the gating dependency for the rest of MISSION-1's experimental work. Worth doing right.

## Cross-references

- `experiments/E07-cable-replug-drain-first.md` Run 3 — the empirical evidence that motivated this redirection
- `nvidia-driver-surprise-removal-audit.md` — earlier audit (its conclusions about C5 extension are now outdated; this design supersedes the C5 v3 framing)
- `c3-c5-integration-audit.md` — the C5 v3 integration work (now status: partial-v3-needs-v4-architectural)
- `consumer-holders-and-teardown-future-work.md` — companion future-work tracker (the quiesce tools complement v4 architectural work; both make cable-yank-testing safer)
- C5 docs: `docs/patch-intents/C5-crash-safety.md`, `docs/patch-reviews/C5-crash-safety.md` — v3 status flipped to `partial-v3-needs-v4-architectural`
- Memory: `feedback_premature_success_overreach_pattern_2026_05_26` — the discipline lesson that motivated framing this as an architectural redirect rather than yet another sweep iteration
- Memory: `feedback_native_in_driver_hardening` — the long-term posture this v4 work aligns with
