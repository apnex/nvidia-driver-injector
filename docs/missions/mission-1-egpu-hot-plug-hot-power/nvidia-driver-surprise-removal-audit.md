# nvidia.ko surprise-removal code-path audit

**Status:** v1 2026-05-26 — initial audit based on fork branch `a5-version-and-toggles` (all our patches applied) + the failure evidence from E07 Run 2
**Purpose:** Attribute the host wedge during cable-yank-with-active-session correctly (driver vs Linux PCI core), identify the specific code-path gap in our patched nvidia.ko, propose surgical patch candidates.
**Scope:** Our patches (A1-A4, C3, C4, C5) + vanilla NVIDIA driver paths they extend (osinit.c, nv-pci.c, kernel_graphics.c, gpu_user_shared_data.c, kernel_ccu.c)
**Why:** Companion to `pci-cmdline-audit.md`. That audit attributed BAR1 allocation to the Linux PCI core. This audit attributes the host-wedge failure mode to our nvidia.ko driver — different problem class, different patch landing zone.

## Attribution: who is responsible for the wedge?

**The Linux kernel did its job.** During E07 Run 2 cable yank, the kernel:
1. Detected TB unplug (TB layer event correctly delivered)
2. Tore down the PCI tunnel
3. Invoked `nv_pci_remove` callback on the GPU device (evidenced by VGA arbitration change in journalctl)
4. Continued operating normally — no kernel BUG, no soft-lockup, no AER cascade in journal

**Our nvidia.ko driver did NOT.** Before `nv_pci_remove` ran, the device-plugin's NVML probe attempts (every ~30s) and possibly persistence-engaged background work hit a GPU that was gone. The driver detected this (Xid 79 fired correctly) but its response cascaded:
- `nvAssertFailedNoLog: Assertion failed: (status == NV_OK) || (status == NV_ERR_GPU_IN_FULLCHIP_RESET) @ kernel_graphics.c:2608`
- `_kccuUnmapAndFreeMemory: CCU memdesc unmap request failed with status: 0xf`
- `nvAssertFailedNoLog: ... @ fecs_event_list.c:1623`
- `nvCheckOkFailedNoLog: ... @ gpu_user_shared_data.c:248`

These are RPC paths that didn't accept `NV_ERR_GPU_IS_LOST` as a valid status. They asserted instead of returning cleanly. The cumulative effect — partial state corruption across multiple RPC sites — eventually wedged the host.

**This is a driver-side bug class. The fix belongs in our patches.**

## Section A — current patches and their scope

| Patch | What it does | What triggers it |
|---|---|---|
| **C3** (gpu-lost-retry) | 10× retry of `NV_PMC_BOOT_0` read in `osHandleGpuLost()` with 100μs delay between attempts. Prevents a single transient PCIe read failure from falsely declaring GPU lost. | Any path that calls `osHandleGpuLost` (from RPC error → `RmReturnRmcMsg` → ... → osHandleGpuLost when registers return 0xff) |
| **C4** (err-handlers scaffold) | Registers the `pci_error_handlers` struct on `nv_pci_driver` with stub callback bodies | PCI core's AER-recovery dispatch on real AER errors (NOT triggered by TB cable yank — TB unplug bypasses AER) |
| **C5** (crash-safety) | Adds `os_pci_set_disconnected(handle)` / `os_pci_is_disconnected(handle)` primitives. Wraps the kernel's `pci_dev_is_disconnected()` / `pci_channel_io_perm_failure` markers so RM code can manipulate them. ALSO defines `NV_ASSERT_OR_GPU_LOST(status)` macro that accepts `NV_OK || NV_ERR_GPU_IN_FULLCHIP_RESET || NV_ERR_GPU_IS_LOST`. | API surface — consumed by A2 + applied at specific assertion sites |
| **A1** (pcie-primitives) | WPR2 read, AER snapshot, topology walker — pure observability primitives | Consumed by A2, A3 (for trigger evaluation) |
| **A2** (Q-watchdog) | 5Hz kthread reads `NV_PMC_BOOT_0`. On 0xFFFFFFFF detection, calls `os_pci_set_disconnected(nv->handle)` → kernel-side permanent IO failure marker | Active heartbeat (independent of any other code path) |
| **A3** (recovery state machine) | Two trigger paths: WPR2-stuck → workqueue calls `pci_reset_bus()`; runtime AER → `pci_error_handlers` callbacks return `PCI_ERS_RESULT_NEED_RESET` | (a) cold-plug post-rmInit failure detected via WPR2 read; (b) PCI core AER dispatch |
| **A4** (close-path telemetry) | Visibility into UVM open/close + RM usage_count transitions during teardown | Observational only |

## Section B — what fires (or doesn't) under cable-yank-with-active-session

Per E07 Run 2 evidence:

| Patch | Fired during E07 Run 2? | Evidence / why |
|---|---|---|
| C3 (gpu-lost-retry) | **YES** — 10× retry completed, then Xid 79 emitted | osHandleGpuLost path executed (visible: "GPU has fallen off the bus" message) |
| C4 (err-handlers) | NO | TB unplug doesn't generate AER; PCI core doesn't invoke our error handlers for surprise-removal |
| C5 (`os_pci_set_disconnected`) | **NO from osHandleGpuLost path** (it's not called there); ONLY if A2 ran first | See Section C — the gap |
| C5 (`NV_ASSERT_OR_GPU_LOST` macro) | DEFINED but not applied at the failing sites | See Section C — the gap |
| A1 (pcie-primitives) | Consumed indirectly by A2 (if it fired) | passive |
| A2 (Q-watchdog) | Likely fired but cadence too slow to prevent assertion cascade | 5Hz = 200ms window; cascade fired faster |
| A3 (recovery) | **NO** | Neither trigger condition met: WPR2 wasn't stuck (GPU operating normally pre-yank), no AER (TB unplug doesn't fire it) |
| A4 (close-path telemetry) | **YES** — visible in journalctl (`tb_egpu UVM [CLOSE]: ... fd_count=N`) | Telemetry-only; doesn't prevent wedge |

## Section C — the specific gap

Two distinct sub-gaps surfaced by the source audit:

### Gap 1: `osHandleGpuLost` doesn't propagate to the Linux-level disconnect marker

In `src/nvidia/arch/nvalloc/unix/src/osinit.c` (line ~405-411), when Xid 79 fires:

```c
if (bEmitXid)
{
    nvErrorLog_va((void *)pGpu, ROBUST_CHANNEL_GPU_HAS_FALLEN_OFF_THE_BUS,
                  "GPU has fallen off the bus.");
}

gpuNotifySubDeviceEvent(...);
NV_DEV_PRINTF(NV_DBG_ERRORS, nv, "GPU has fallen off the bus.\n");
... boardInfo logging ...

gpuSetDisconnectedProperties(pGpu);   // ← sets RM-level PDB_PROP_GPU_IS_CONNECTED = FALSE
```

**Missing:** No call to `os_pci_set_disconnected(nv->handle)`. So while the RM internally knows the GPU is disconnected, the Linux-level marker (`pci_dev_is_disconnected`, used by some MMIO short-circuit paths) is NOT set.

The two markers are independent. RPC paths check one or the other depending on the path. The split state means some paths continue attempting GPU communication while others correctly fast-fail.

A2 (Q-watchdog) DOES call `os_pci_set_disconnected` — but only after its 5Hz heartbeat next ticks (up to 200ms later) AND detects the dead bus independently. By that time the assertion cascade has already fired.

### Gap 2: `NV_ASSERT_OR_GPU_LOST` macro defined but not applied at the failing sites

`src/nvidia/inc/kernel/gpu/nv-gpu-lost.h` defines:

```c
#define NV_ASSERT_OR_GPU_LOST(status)                                          \
    NV_ASSERT(((status) == NV_OK) ||                                           \
              ((status) == NV_ERR_GPU_IN_FULLCHIP_RESET) ||                    \
              ((status) == NV_ERR_GPU_IS_LOST))
```

**Current usage** (verified by grep across the entire source tree):

```
src/nvidia/inc/kernel/gpu/nv-gpu-lost.h:74        ← definition
src/nvidia/src/libraries/resserv/src/rs_client.c:855    ← used here
src/nvidia/src/libraries/resserv/src/rs_server.c:272    ← used here
```

**Just two call sites consume it.** The failing sites from E07 Run 2 do NOT use it:

```c
// kernel_graphics.c:2608 — the assertion that fired:
NV_ASSERT((status == NV_OK) || (status == NV_ERR_GPU_IN_FULLCHIP_RESET));

// gpu_user_shared_data.c:248 — similar pattern (NV_CHECK_OK)

// kernel_ccu.c:230+ — `_kccuUnmapAndFreeMemory` whose log line we saw
// ("CCU memdesc unmap request failed with status: 0xf"):
// status 0xf = NV_ERR_GPU_IS_LOST; the log fired, the cleanup ran
// but the assertion-style check below it would have failed
```

These sites are RPC cleanup paths — they run during teardown when the GPU may be gone. They were designed assuming RM-level disconnect marker prevents them from being reached with a dead GPU. But the actual code paths CAN be reached (the device-plugin's NVML probes go through paths that don't all gate on the RM marker), so the assertion fires when `status == NV_ERR_GPU_IS_LOST`.

The macro exists for exactly this case (`((status) == NV_ERR_GPU_IS_LOST)` is the relaxation). It just hasn't been applied where needed.

## Section D — proposed patch shapes (surgical, well-scoped)

### Patch P-DISC-1 — propagate disconnect to Linux-level marker

**File:** `src/nvidia/arch/nvalloc/unix/src/osinit.c`
**Change:** add `os_pci_set_disconnected` call alongside `gpuSetDisconnectedProperties` in `osHandleGpuLost`

```c
if (pmc_boot_0 != nvp->pmc_boot_0)
{
    /* ... existing Xid emit, notify, log ... */

    gpuSetDisconnectedProperties(pGpu);
+
+   /*
+    * tb_egpu (addon Aᴺ): also propagate the disconnect to the Linux-
+    * level pci_dev_is_disconnected marker. The RM-level
+    * PDB_PROP_GPU_IS_CONNECTED set just above is consulted by some
+    * code paths; pci_dev_is_disconnected is consulted by others
+    * (notably os-mediated config-space reads). Setting both
+    * simultaneously closes the propagation window between Xid 79
+    * detection and the Q-watchdog's next 5Hz tick (up to 200ms
+    * later), which is enough time for the device plugin's NVML
+    * probes to enter assertion paths that don't accept GPU_IS_LOST.
+    */
+   os_pci_set_disconnected(nv->handle);

    if (IS_GSP_CLIENT(pGpu)) { ... }
}
```

**Effect:** the disconnect-state marker becomes consistent across both RM and Linux layers at the moment of Xid 79 emission. Subsequent code paths that fast-fail on `pci_dev_is_disconnected()` short-circuit immediately instead of attempting RPCs.

**Blast radius:** narrow — one line added; the called function (`os_pci_set_disconnected`) is our own primitive added by C5.

**Folds into:** C3 (gpu-lost-retry) is the natural home — same logical class as that patch's contents. Alternatively could go into a new addon.

### Patch P-DISC-2 — apply `NV_ASSERT_OR_GPU_LOST` at the observed failing sites

**Files:**
- `src/nvidia/src/kernel/gpu/gr/kernel_graphics.c:2608`
- `src/nvidia/src/kernel/gpu/gpu_user_shared_data.c:248`
- `src/nvidia/src/kernel/gpu/ccu/kernel_ccu.c:~255` (in `_kccuUnmapAndFreeMemory`)
- (and `fecs_event_list.c:1623` if path exists in our open-source tree)

**Change pattern:** Convert each `NV_ASSERT((status == NV_OK) || (status == NV_ERR_GPU_IN_FULLCHIP_RESET))` to `NV_ASSERT_OR_GPU_LOST(status)`.

```c
// kernel_graphics.c — before:
NV_ASSERT((status == NV_OK) || (status == NV_ERR_GPU_IN_FULLCHIP_RESET));
// after:
NV_ASSERT_OR_GPU_LOST(status);
```

**Effect:** these teardown paths now correctly accept `NV_ERR_GPU_IS_LOST` as a valid status (the GPU IS lost — the cleanup is host-side bookkeeping; an assertion is the wrong response). The cascade fails to fire; the wedge precursor is eliminated.

**Blast radius:** very narrow — 3-4 single-line conversions in well-defined sites. The macro `NV_ASSERT_OR_GPU_LOST` already exists (C5 added it); we're just expanding its application.

**Folds into:** C5 (crash-safety) is the natural home — same logical class as the patches that introduced the macro. C5's stated purpose is "crash safety" and these conversions ARE crash-safety. Alternative: a new addon if we want clear staging.

### Two patches together — combined effect

P-DISC-1 + P-DISC-2 together address the wedge by:
1. Setting both disconnect markers simultaneously at Xid 79 emission (P-DISC-1)
2. Making the remaining RPC paths gracefully accept GPU-lost as a valid status (P-DISC-2)

Together they convert the cable-yank-with-active-session scenario from "wedge requiring forced reboot" to "graceful tear-down with informational Xid 79 message, no cascade."

Critically: these patches do NOT change WHAT happens (the GPU is still gone, the driver still tears down) — they change HOW IT HAPPENS (graceful instead of cascading-assertion-wedge).

## Section E — implications for the BAR1 problem

The wedge fix is **completely separable** from the BAR1 allocation fix. They are two patches, two layers, with no architectural overlap:

| Problem | Patch type | Patch home | Touches |
|---|---|---|---|
| Wedge | Driver crash-safety extensions | nvidia.ko fork (our C3/C5 expansions) | osinit.c + 3-4 RPC sites + add macro applications |
| BAR1 | Linux PCI core retry asymmetry | Upstream Linux | drivers/pci/setup-bus.c::pci_assign_unassigned_bridge_resources |

The wedge fix is also a **prerequisite for safe BAR1 testing.** Today we can't safely produce broken-BAR1 state because cable yank wedges. With the wedge fix:
- Cable yank → orderly tear-down → broken-BAR1 state visible cleanly → tests of E02/E10/E12/etc. become possible

This UNLOCKS Phase 2.1 + 2.2 experimentation, which has been BLOCKED since E07 Run 2 / E11 Run 1.

## Section F — open follow-ups (audit findings to validate empirically)

1. **Build a test image with P-DISC-1 + P-DISC-2 applied** — needs careful fork branching strategy (which cluster do they go in? new addon? extension of C3+C5?)
2. **Confirm `_kccuUnmapAndFreeMemory` line numbers** in the actual file (audit referenced via grep; specific line varies)
3. **Identify other sites that may need NV_ASSERT_OR_GPU_LOST conversion** — broader sweep of `NV_ASSERT((status == NV_OK) || (status == NV_ERR_GPU_IN_FULLCHIP_RESET))` patterns
4. **Determine if `gpuSetDisconnectedProperties` is the only "RM declares GPU disconnected" site** or if there are others where P-DISC-1's `os_pci_set_disconnected` call should be co-located
5. **bpftrace at the next E07 Run** — kprobe `os_pci_set_disconnected`, `nv_pci_remove`, the failing assertions — confirm execution order matches the audit's model
6. **Validate the patches don't break the existing AER recovery path** (A3) — they shouldn't (different code paths) but worth a regression test
7. **Test sequencing:** rebuild image with patches → produce broken-BAR1 via cable yank → confirm host stays responsive → cable replug → confirm graceful recovery → unblocks Phase 2.1 experiments

## Cross-references

- `experiments/E07-cable-replug-drain-first.md` — Run 2 wedge that motivated this audit
- `experiments/E11-per-function-remove.md` — Run 1 graceful path (proven reference implementation)
- `pci-cmdline-audit.md` — companion BAR1 audit (different problem class)
- Memory: `feedback_surprise_removal_wedge_class_2026_05_26` — original wedge-class description, now grounded in code
- Memory: `feedback_native_in_driver_hardening` — "perfect end state is zero workaround services with all recovery in-driver" — this audit identifies what "all" means in our case
- Source files audited: `kernel-open/nvidia/nv-pci.c`, `kernel-open/nvidia/nv-tb-egpu-{qwd,recover,close,pcie}.c`, `src/nvidia/arch/nvalloc/unix/src/osinit.c`, `src/nvidia/inc/kernel/gpu/nv-gpu-lost.h`, `src/nvidia/src/kernel/gpu/gr/kernel_graphics.c`, `src/nvidia/src/kernel/gpu/gpu_user_shared_data.c`, `src/nvidia/src/kernel/gpu/ccu/kernel_ccu.c`
- Our patches read: C3, C4, C5 (base/); A1, A2, A3, A4 (addon/)
