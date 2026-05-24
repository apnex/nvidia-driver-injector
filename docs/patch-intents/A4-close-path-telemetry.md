---
id: A4-close-path-telemetry
layer: addon
source-branch: a4-close-path-telemetry
upstream-candidacy: n/a
telemetry-tier: mandatory
status: reviewed
related-patches: [A1-pcie-primitives, A3-recovery]
---

# A4-close-path-telemetry — Event-Triggered Nominal Telemetry on the RM / UVM Close Path

## Purpose

The driver SHALL emit a one-line `[CLOSE]` telemetry marker at every
RM-side and UVM-side close-path lifecycle site so that close-path
wedges — historically silent and the bug class that triggered patch
0029 (`project_close_path_mitigated_2026_05_08`) — are observable in
the kernel log without any further instrumentation. On the
last-close transition (the open that brings the fd count up from
zero OR the close that brings `nvl->usage_count` / the UVM fd count
back to zero), the driver SHALL additionally capture a minimal
hardware-health snapshot — PMC_BOOT_0 (via a `ioremap`+`ioread32` on
BAR0) and WPR2 (via [[A1-pcie-primitives]]'s
`tb_egpu_pcie_read_wpr2`) — plus a one-word `wpr2_up:` health
verdict, so an operator can answer "was the GPU alive and clean at
last-close?" by reading dmesg alone. The persistent capability A4
grants the driver is "every close-path event leaves evidence — a
silent close-path wedge becomes impossible by construction." The
telemetry is held to the nominal bar per the 2026-05-22
addon-recarve design's observability audit
(`docs/superpowers/specs/2026-05-22-addon-recarve-design.md`): one
line per site, hardware snapshot only on last-close, no full
AER/LnkSta walk. Instrumentation is passive — `ioremap`+`ioread32`
plus PCI config-space reads only; no register writes, no DMA, no
recovery side-effects.

## Requirements

### Requirement: Driver SHALL emit a one-line `[CLOSE]` marker at every RM-side close-path site

The driver SHALL invoke `tb_egpu_close_diag(nvl, site, usage_count,
is_last_close)` at each of four RM-side call sites in
`kernel-open/nvidia/nv.c`:

- **`close-entry`** — at the top of `nvidia_close_callback` after
  the `nvl` resolution, with `usage_count` read from
  `atomic64_read(&nvl->usage_count)` and `is_last_close = (uc == 1)`.
- **`pre-stop`** — inside `nvidia_close_callback`, under
  `ldata_lock`, immediately before `nv_close_device`, with the same
  `usage_count` / `is_last_close = (uc == 1)` derivation.
- **`post-shutdown`** — inside `nv_stop_device` after
  `nv_shutdown_adapter`, with `usage_count = 0` and
  `is_last_close = true` (the function is only entered when the
  count has reached zero).
- **`close-exit`** — at the end of `nvidia_close_callback` after
  `nv_close_device`, with `usage_count` re-read and
  `is_last_close = (uc == 0)`.

`tb_egpu_close_diag` SHALL emit one `NV_DEV_PRINTF(NV_DBG_ERRORS,
nv, ...)` line of the form
`"tb_egpu [CLOSE]: site=%-15s usage_count=%ld%s\n"` where the
trailing `%s` is `" (LAST-CLOSE)"` when `is_last_close` is true and
empty otherwise. The function MUST be a no-op when `nvl` is `NULL`.
On the last-close branch (`is_last_close && nvl->pci_dev`) the
function MUST additionally call `tb_egpu_close_diag_pdev(nvl->pci_dev,
site)` to capture the hardware-health snapshot defined by the
second Requirement.

#### Scenario: Non-last-close transition emits the marker only
- **GIVEN** a probed eGPU with `nvl->usage_count == 2` (a second
  fd holder still open)
- **WHEN** `nvidia_close_callback` runs and reaches the
  `close-entry` site
- **THEN** exactly one `NV_DBG_ERRORS` log line MUST be emitted of
  the form `"tb_egpu [CLOSE]: site=close-entry     usage_count=2\n"`
- **AND** no `tb_egpu_close_diag_pdev` snapshot MUST fire (the
  `is_last_close` branch is not taken)
- **AND** the existing close-path execution MUST proceed unchanged

#### Scenario: Last-close transition at `close-entry` triggers the hardware snapshot
- **GIVEN** a probed eGPU with `nvl->usage_count == 1` (the last
  remaining fd is closing) and `nvl->pci_dev != NULL`
- **WHEN** `nvidia_close_callback` runs and reaches the
  `close-entry` site
- **THEN** exactly one `NV_DBG_ERRORS` log line MUST be emitted of
  the form `"tb_egpu [CLOSE]: site=close-entry     usage_count=1 (LAST-CLOSE)\n"`
- **AND** `tb_egpu_close_diag_pdev(nvl->pci_dev, "close-entry")` MUST
  be called to capture the PMC_BOOT_0 + WPR2 hardware-health
  snapshot per the second Requirement
- **AND** the existing close-path execution MUST proceed unchanged

#### Scenario: `post-shutdown` always fires the snapshot
- **GIVEN** `nv_stop_device` is entered after the last-close path
  drives `usage_count` to zero
- **WHEN** the call site reaches `tb_egpu_close_diag(nvl,
  "post-shutdown", 0, true)`
- **THEN** the marker line MUST be emitted
- **AND** the hardware snapshot MUST fire (`is_last_close` is
  hard-coded `true` because `nv_stop_device` is only entered on the
  last-close path)
- **AND** the snapshot MUST capture state immediately AFTER
  `nv_shutdown_adapter` — the most diagnostic site in the
  close-path sequence for the patch-0029 bug class

#### Scenario: `nvl == NULL` is a clean no-op
- **GIVEN** a caller invokes `tb_egpu_close_diag(NULL, "close-entry",
  0, false)` (defensive — should not happen on the real call paths
  but the contract holds)
- **WHEN** the function executes
- **THEN** the function MUST return without emitting any log line
- **AND** the function MUST NOT dereference `nvl`

### Requirement: Driver SHALL capture a minimal PMC_BOOT_0 + WPR2 hardware-health snapshot on last-close

The driver SHALL provide `void tb_egpu_close_diag_pdev(struct
pci_dev *pdev, const char *site)` declared in
`kernel-open/nvidia/nv-tb-egpu-close.h` and exported via
`EXPORT_SYMBOL_GPL` so it is reachable from `nvidia-uvm.ko` (the UVM
side of A4). The function SHALL:

1. Emit an error-level log line and return early when `pdev == NULL`
   (defensive — should not happen on the real call paths).
2. Read `pci_resource_start(pdev, 0)` as `bar0_phys`; if zero, emit
   an error-level log line and return.
3. `ioremap(bar0_phys, PAGE_SIZE)` and `ioread32` PMC_BOOT_0 (BAR0
   offset `0`); `iounmap` the temporary mapping before any further
   action; record `pmc_ok = true` if the mapping succeeded and
   `pmc_ok = false` otherwise (with `pmc_boot_0` left at its
   initial `0xdeadbeef` sentinel).
4. Call [[A1-pcie-primitives]]'s
   `tb_egpu_pcie_read_wpr2(bar0_phys, &wpr2_raw)` to capture
   WPR2 via A1's own self-contained `ioremap`+`ioread32`+`iounmap`
   helper; record the return code in `wpr2_rc`.
5. Emit exactly one `NV_DBG_ERRORS` log line of the form
   `"tb_egpu [CLOSE]: site=%-15s pdev=%s bar0=0x%llx PMC_BOOT_0=%s%08x WPR2=%s%08x wpr2_up:%s\n"`
   with the PMC and WPR2 value placeholders preceded by either
   `"0x"` (success) or `"MAPFAIL:"` (the respective read failed)
   and the trailing `wpr2_up:` reading `"YES"` when
   `(wpr2_raw & TB_EGPU_PCIE_WPR2_VAL_MASK) != 0` and `"no"`
   otherwise.

The function MUST be passive — no register writes, no DMA, no state
mutation outside the local variables and the temporary `ioremap`
mapping. The function MUST tolerate any read failure
(`ioremap` returning `NULL`, A1's helper returning a non-zero
code) by emitting the line with the `MAPFAIL:` sentinel rather
than crashing or returning early.

#### Scenario: Healthy last-close emits a "wpr2_up:no" snapshot line
- **GIVEN** a probed eGPU with a valid BAR0 and the GPU responding
  to MMIO
- **AND** WPR2 is clear (raw value masked with
  `TB_EGPU_PCIE_WPR2_VAL_MASK` is zero)
- **WHEN** `tb_egpu_close_diag_pdev(pdev, "post-shutdown")` runs
- **THEN** exactly one `NV_DBG_ERRORS` line MUST be emitted of the
  form
  `"tb_egpu [CLOSE]: site=post-shutdown   pdev=0000:08:00.0 bar0=0x... PMC_BOOT_0=0x... WPR2=0x00000000 wpr2_up:no\n"`
- **AND** the temporary `ioremap` mapping for PMC_BOOT_0 MUST be
  released via `iounmap` before the function returns
- **AND** A1's `tb_egpu_pcie_read_wpr2` SHALL be the only WPR2
  reader (A4 MUST NOT duplicate the WPR2 ioremap logic)

#### Scenario: WPR2-stuck last-close emits a "wpr2_up:YES" snapshot line
- **GIVEN** a probed eGPU close-path fires during a
  WPR2-stuck failure mode (post-rmInit-FAIL recovery in flight via
  [[A3-recovery]])
- **AND** `(wpr2_raw & TB_EGPU_PCIE_WPR2_VAL_MASK) != 0`
- **WHEN** `tb_egpu_close_diag_pdev(pdev, "close-entry")` runs
- **THEN** the snapshot line MUST emit `wpr2_up:YES`
- **AND** the line MUST be unambiguously attributable to the close
  path (the `site=` field) rather than to A3's recovery dump (which
  uses different format strings)

#### Scenario: `ioremap` failure on PMC_BOOT_0 produces a MAPFAIL snapshot line, not a crash
- **GIVEN** an unusual condition where `ioremap(bar0_phys,
  PAGE_SIZE)` returns `NULL` (e.g. transient kernel resource
  pressure)
- **WHEN** `tb_egpu_close_diag_pdev(pdev, "close-entry")` runs
- **THEN** the snapshot line MUST emit `PMC_BOOT_0=MAPFAIL:deadbeef`
  with the leading sentinel marking the read failure
- **AND** the function MUST still attempt the WPR2 read via A1's
  helper (whose ioremap is independent and may or may not also
  fail)
- **AND** the function MUST NOT panic or `BUG_ON` — close-path
  telemetry MUST never destabilise the close path itself

### Requirement: Driver SHALL emit a one-line `[CLOSE]` marker at every UVM-side lifecycle site and track UVM-local fd count

The driver SHALL provide five UVM-side helpers declared in
`kernel-open/nvidia-uvm/nv-tb-egpu-uvm.h` and called from
`kernel-open/nvidia-uvm/uvm.c`:

- `tb_egpu_uvm_close_diag_at_open()` — called at the end of
  `uvm_open` on the `NV_OK` success path; pre-increment fd_count
  reads zero iff this open is the first after a LAST-CLOSE.
- `tb_egpu_uvm_close_diag_at_release_entry()` — called at the top
  of `uvm_release` before any switch on `fd_type`; pre-decrement
  fd_count reads one iff this release will be the LAST-CLOSE.
- `tb_egpu_uvm_close_diag_at_pre_destroy()` — called in the
  `UVM_FD_VA_SPACE` branch just before `uvm_release_va_space`.
- `tb_egpu_uvm_close_diag_at_post_destroy()` — called immediately
  after `uvm_release_va_space` returns.
- `tb_egpu_uvm_close_diag_at_release_exit()` — called at the
  bottom of `uvm_release` after the switch; post-decrement fd_count
  reads zero iff this release brought the count back to zero.

The five helpers SHALL share a module-private `static atomic_t
tb_egpu_uvm_fd_count` initialised to `0`. The open and
release-exit helpers SHALL mutate the counter
(`atomic_inc_return` / `atomic_dec_return`); the other three SHALL
read it via `atomic_read` only. Each helper SHALL invoke a single
private `tb_egpu_uvm_emit(site, fd_count, is_last_close)` body that
emits one `pr_info` line of the form
`"tb_egpu UVM [CLOSE]: site=%-18s fd_count=%d%s\n"` (trailing
`(LAST-CLOSE)` on the last-close transition) and, when
`is_last_close` is true, calls `tb_egpu_get_gpu_pdev()` to acquire
a refcounted `pci_dev` and then `tb_egpu_close_diag_pdev(pdev,
site)` for the snapshot, releasing the refcount via `pci_dev_put`
afterwards. If no NVIDIA pdev is bound the helper MUST emit a
second `pr_info` line citing the site and the missing pdev and
skip the snapshot.

#### Scenario: First UVM open after LAST-CLOSE triggers the snapshot
- **GIVEN** `tb_egpu_uvm_fd_count == 0` (no UVM fds are currently
  open)
- **AND** a probed NVIDIA pdev is bound
- **WHEN** `uvm_open` reaches its success path and calls
  `tb_egpu_uvm_close_diag_at_open()`
- **THEN** `atomic_inc_return(&tb_egpu_uvm_fd_count)` MUST yield
  `1`
- **AND** the helper MUST emit
  `"tb_egpu UVM [CLOSE]: site=uvm-open-entry    fd_count=1 (LAST-CLOSE)\n"`
- **AND** the helper MUST call `tb_egpu_get_gpu_pdev()` and then
  `tb_egpu_close_diag_pdev(pdev, "uvm-open-entry")`
- **AND** the helper MUST `pci_dev_put(pdev)` before returning

#### Scenario: UVM release that brings fd_count to zero triggers the snapshot
- **GIVEN** `tb_egpu_uvm_fd_count == 1` (one UVM fd remains)
- **WHEN** `uvm_release` runs end-to-end and reaches
  `tb_egpu_uvm_close_diag_at_release_exit()`
- **THEN** `atomic_dec_return(&tb_egpu_uvm_fd_count)` MUST yield
  `0`
- **AND** the helper MUST emit a `(LAST-CLOSE)` marker line and
  fire the hardware snapshot exactly as the open path does on
  count==0 → count==1

#### Scenario: UVM lifecycle site with no NVIDIA pdev bound emits a clean fallback line
- **GIVEN** an unusual condition where the UVM module is loaded
  but no NVIDIA pdev is currently bound (early load / late
  unbind race)
- **WHEN** a last-close transition fires
- **THEN** `tb_egpu_get_gpu_pdev()` MUST return `NULL`
- **AND** the helper MUST emit
  `"tb_egpu UVM [CLOSE]: site=<site> — no NVIDIA pdev bound; skipping snapshot\n"`
- **AND** the helper MUST NOT call `tb_egpu_close_diag_pdev` or
  attempt any PCI access

### Requirement: Driver SHALL expose a cross-module pdev lookup so UVM can reach the snapshot helper

The driver SHALL provide `struct pci_dev *tb_egpu_get_gpu_pdev(void)`
declared in `kernel-open/nvidia/nv-tb-egpu-close.h` and exported via
`EXPORT_SYMBOL_GPL`. The function SHALL walk `nv_linux_devices`
under `LOCK_NV_LINUX_DEVICES()` / `UNLOCK_NV_LINUX_DEVICES()`, take
`pci_dev_get` on the first entry's `pci_dev`, release the lock, and
return the refcounted pointer. The caller MUST `pci_dev_put` the
returned pointer when done. The function SHALL return `NULL` if
no entry is bound. The single-pdev semantics match the project's
deployment shape (one eGPU per host per `project_aorus_egpu_setup`)
and supersede the legacy hardcoded `pci_get_domain_bus_and_slot(0,
0x04, PCI_DEVFN(0,0))` that the pre-recarve close-path code used.

#### Scenario: Cross-module pdev lookup returns the bound device with a refcount
- **GIVEN** one NVIDIA pdev has been successfully probed by
  `nvidia.ko`
- **AND** the UVM helper calls `tb_egpu_get_gpu_pdev()` from
  `nvidia-uvm.ko`
- **WHEN** the function executes under the global lock
- **THEN** the function MUST return a non-NULL `struct pci_dev *`
- **AND** the returned pdev's refcount MUST have been incremented
  by exactly one `pci_dev_get` call
- **AND** the lock MUST be released before return

#### Scenario: Cross-module pdev lookup returns NULL when no device is bound
- **GIVEN** `nvidia.ko` has been loaded but no eGPU is yet bound
  (early-probe race)
- **WHEN** the UVM helper calls `tb_egpu_get_gpu_pdev()`
- **THEN** the function MUST return `NULL`
- **AND** the function MUST NOT panic or `BUG_ON`
- **AND** no refcount MUST have been taken

## Scope boundary

- This patch deliberately does NOT trigger any recovery action.
  The recovery state machine — `pci_reset_bus`, `slot_reset` /
  `resume` dispatch, H1/H2/H3 hardening — lives in
  [[A3-recovery]]. A4 is pure-observability; it never schedules
  work, never resets a bus, never mutates any device state.
- This patch does NOT poll for bus loss at any cadence. The
  per-device heartbeat that polls `NV_PMC_BOOT_0` for the dead-bus
  signature is [[A2-bus-loss-watchdog]]'s responsibility. A4 only
  reads PMC_BOOT_0 on the close-path last-close transition (an
  event, not a heartbeat).
- This patch does NOT introduce any new PCIe / AER / WPR2 read
  primitive. WPR2 is read exclusively via
  [[A1-pcie-primitives]]'s `tb_egpu_pcie_read_wpr2`; A4 only
  adds the small PMC_BOOT_0 `ioremap`+`ioread32` block local to
  the close-path callsite. The full AER / LnkSta / DPC dump
  primitive (`tb_egpu_dump_aer_trigger_event`) is intentionally
  NOT called from A4 — that dump is investigation-grade and lived
  in the dissolved P6 DIAG surface; the addon-recarve design's
  observability audit explicitly trims it from A4 to the nominal
  bar (per `docs/superpowers/specs/2026-05-22-addon-recarve-design.md`
  § "Observability audit").
- This patch does NOT expose any sysfs counter. A4 is
  log-based observability — sysfs lives in
  [[A2-bus-loss-watchdog]] (`tb_egpu_qwd_*`) and
  [[A3-recovery]] (`tb_egpu_recover_*`). The close-path bug class
  is operationally rare enough that the log line is the right
  surface; a counter would require an episode definition A4
  deliberately does not own.
- This patch does NOT register any `pci_error_handlers` callback
  or any module parameter. The err_handlers table is registered
  by `C4-err-handlers-scaffold` and filled in by
  [[A3-recovery]]. Module-parameter surfaces (master enable,
  tuning knobs) for A4 are NOT introduced — the close-path
  telemetry is unconditional once compiled in. The reserved
  `CONFIG_NV_TB_EGPU` symbol declared by [[A5-version-and-toggles]]
  is documentation-only in v1 and does NOT gate A4's
  source-list rows or any A4-internal code path; any future
  per-file gate would be a deliberate later step, not a
  consequence of A4's current shape.
- This patch does NOT use [[A1-pcie-primitives]]'s
  `tb_egpu_dump_aer_trigger_event(gpu_pdev, trigger, out)` API.
  The full AER multi-hop snapshot dump is reserved for
  [[A3-recovery]]'s err_handler callbacks and watchdog detection
  (where the AER state at the moment of recovery is load-bearing
  for incident analysis). The close-path bug class — which A4
  exists to make visible — does not require an AER walk; the
  PMC_BOOT_0 + WPR2 pair plus the `wpr2_up:` verdict are the
  minimal evidence the soak gate and incident postmortems need.
  Per A1's documented contract this means A4 holds the option to
  call A1's dump with `out = NULL` if a future incident class
  proves the AER walk is needed at close-path; v1 does not
  exercise that option and the intent does not require it.
- This patch does NOT instrument any non-close-path lifecycle
  event. Probe, `nv_start_device`, `rm_init_adapter`,
  `pci_reset_bus`, slot_reset / resume — none of these are
  A4's scope. The four RM-side sites are all within the close
  path (`nvidia_close_callback`, `nv_stop_device`), and the
  five UVM-side sites are all within `uvm_open` / `uvm_release`.
- This patch does NOT trim the UVM lifecycle below the five-site
  set documented above. The five sites are load-bearing for the
  close-path bug class: open-entry and release-exit straddle the
  fd-count transition, release-entry catches the pre-decrement
  state for race analysis, and pre-destroy / post-destroy
  bracket the destabilising `uvm_va_space_destroy` call which is
  the specific UVM teardown step that has historically wedged.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| RM close-path marker (any site, non-last-close) | `NV_DBG_ERRORS` (err) | `"tb_egpu [CLOSE]: site=%-15s usage_count=%ld\n"` |
| RM close-path marker (any site, LAST-CLOSE transition) | `NV_DBG_ERRORS` (err) | `"tb_egpu [CLOSE]: site=%-15s usage_count=%ld (LAST-CLOSE)\n"` |
| RM close-path hardware snapshot (on LAST-CLOSE) | `NV_DBG_ERRORS` (err) | `"tb_egpu [CLOSE]: site=%-15s pdev=%s bar0=0x%llx PMC_BOOT_0=%s%08x WPR2=%s%08x wpr2_up:%s\n"` (the PMC and WPR2 placeholders are preceded by `"0x"` on success or `"MAPFAIL:"` on ioremap / A1-helper failure; the trailing `wpr2_up:` is `"YES"` or `"no"`) |
| RM close-path snapshot with `pdev = NULL` (defensive) | `NV_DBG_ERRORS` (err) | `"tb_egpu [CLOSE]: site=%s pdev=NULL — cannot read\n"` |
| RM close-path snapshot with `bar0 = 0` (defensive) | `NV_DBG_ERRORS` (err) | `"tb_egpu [CLOSE]: site=%s bar0=0 — skipping\n"` |
| UVM close-path marker (any site, non-last-close) | `pr_info` | `"tb_egpu UVM [CLOSE]: site=%-18s fd_count=%d\n"` |
| UVM close-path marker (any site, LAST-CLOSE transition) | `pr_info` | `"tb_egpu UVM [CLOSE]: site=%-18s fd_count=%d (LAST-CLOSE)\n"` |
| UVM close-path snapshot when no NVIDIA pdev is bound | `pr_info` | `"tb_egpu UVM [CLOSE]: site=%s — no NVIDIA pdev bound; skipping snapshot\n"` |

The telemetry tier is `mandatory` — the close-path bug class was
discovered specifically because close-path wedges were silent (per
`project_close_path_mitigated_2026_05_08`: patch 0029 mitigated the
class but the discovery required adding instrumentation that the
production driver previously lacked). The marker line is the
proof-the-path-ran observability; the LAST-CLOSE hardware snapshot
is the additional evidence that distinguishes "GPU was alive and
clean at close" from "GPU was already in WPR2-stuck or off-the-bus
at close". The two lines together let an operator (or the standing
soak gate) read dmesg and conclude whether the close path completed
healthily without needing any further instrumentation. The RM-side
log level is `NV_DBG_ERRORS` (the project's convention for "rare,
meaningful event" lines) rather than `NV_DBG_INFO` so the lines
appear in the default dmesg verbosity without operator
configuration; the UVM-side uses `pr_info` because
`nvidia-uvm.ko` does not link the `NV_DBG_*` family. The format
strings include fixed-width `%-15s` / `%-18s` site fields so the
lines align in dmesg and post-mortem grep is straightforward.

## Provenance

- **Source cluster:** Carved from legacy cluster P4
  (`patches/legacy/0005-close-path-telemetry.patch`) during the
  2026-05-22 addon-recarve campaign
  (`project_addon_recarve_merged_2026_05_22`). The recarve trimmed
  the legacy file from "investigation-grade close-path dump
  (including full LnkSta + AER multi-register walk)" to the
  nominal bar — PMC_BOOT_0 + WPR2 + verdict — per the design
  spec's observability audit
  (`docs/superpowers/specs/2026-05-22-addon-recarve-design.md`
  § "Observability audit"). The legacy investigation-grade dump
  surface (cluster P6, the old `[DIAG]` concentration) was
  dissolved in the same campaign; A4 is the surviving nominal-tier
  successor.
- **Vanilla baseline:** Two new RM-side files
  (`kernel-open/nvidia/nv-tb-egpu-close.{c,h}`, 152 + 88 lines)
  and two new UVM-side files
  (`kernel-open/nvidia-uvm/nv-tb-egpu-uvm.{c,h}`, 129 + 38 lines)
  with no vanilla counterparts. Four vanilla files modified
  additively:
  - `kernel-open/nvidia/nv.c` — one `#include "nv-tb-egpu-close.h"`
    (after A3's `nv-tb-egpu-recover.h` include) and four call
    sites: `tb_egpu_close_diag(nvl, "close-entry", ...)` at the
    top of `nvidia_close_callback` after `nvl` resolution;
    `tb_egpu_close_diag(nvl, "pre-stop", ...)` under
    `ldata_lock` immediately before `nv_close_device`;
    `tb_egpu_close_diag(nvl, "post-shutdown", 0L, true)` in
    `nv_stop_device` after `nv_shutdown_adapter`;
    `tb_egpu_close_diag(nvl, "close-exit", ...)` at the end of
    `nvidia_close_callback` after `nv_close_device`.
  - `kernel-open/nvidia/nvidia-sources.Kbuild` — one additive
    line `NVIDIA_SOURCES += nvidia/nv-tb-egpu-close.c` after
    A3's `nv-tb-egpu-recover.c` line.
  - `kernel-open/nvidia-uvm/uvm.c` — one
    `#include "nv-tb-egpu-uvm.h"` and five call sites: the
    open success path, the release entry, the VA_SPACE branch
    pre-destroy and post-destroy, and the release exit.
  - `kernel-open/nvidia-uvm/nvidia-uvm-sources.Kbuild` — one
    additive line
    `NVIDIA_UVM_SOURCES += nvidia-uvm/nv-tb-egpu-uvm.c` after
    `uvm_linux.c`.
- **A1 ABI consumed:** A4 calls A1's
  `tb_egpu_pcie_read_wpr2(bar0_phys, &raw)` once from
  `tb_egpu_close_diag_pdev` to capture WPR2; uses A1's
  `TB_EGPU_PCIE_WPR2_VAL_MASK` constant to derive the
  `wpr2_up:` verdict. A4 does NOT call A1's
  `tb_egpu_dump_aer_trigger_event` — that primitive is reserved
  for [[A3-recovery]] and the watchdog (per A1's documented
  contract A4 holds the option to call with `out = NULL` but v1
  exercises only the small WPR2 helper). A4 does NOT call A1's
  topology walker (`tb_egpu_pcie_walk_to_root_port`), DPC
  reader, or full AER reader — those primitives are reserved for
  the investigation-grade dump surface that the
  addon-recarve audit trimmed out of A4.
- **A3 ABI consumed:** None directly. A4 sits alongside A3 in
  the addon stack but does not call any A3 symbol. The two
  patches are independent consumers of A1's foundation; A4 is
  observability-only, A3 is recovery. A4's snapshot line
  on LAST-CLOSE may coincide with an A3 recovery cycle in
  flight; the site=... attribution disambiguates the two log
  surfaces (A4's `"tb_egpu [CLOSE]: site=..."` vs A3's
  `"tb_egpu recover: ..."`).
- **Function signatures (load-bearing for downstream consumers):**
  - `void tb_egpu_close_diag(nv_linux_state_t *nvl, const char *site, long usage_count, bool is_last_close)` —
    RM-side marker + last-close snapshot dispatcher. NOT
    `EXPORT_SYMBOL_GPL`'d; consumed only inside `nvidia.ko`.
  - `void tb_egpu_close_diag_pdev(struct pci_dev *pdev, const char *site)` —
    pdev-based hardware-health snapshot. `EXPORT_SYMBOL_GPL`'d
    so `nvidia-uvm.ko` can reach it.
  - `struct pci_dev *tb_egpu_get_gpu_pdev(void)` —
    cross-module pdev lookup. `EXPORT_SYMBOL_GPL`'d so
    `nvidia-uvm.ko` can reach it. Caller MUST `pci_dev_put`.
  - `void tb_egpu_uvm_close_diag_at_open(void)` and the four
    sibling UVM helpers (`_at_release_entry`,
    `_at_pre_destroy`, `_at_post_destroy`, `_at_release_exit`)
    — UVM-local; not exported.
- **Fork branch:** `a4-close-path-telemetry` on
  `apnex/open-gpu-kernel-modules` (sits on top of `a3-recovery`;
  the cumulative diff carries C1-C5 + E1 + A1 + A2 + A3 + A4 at
  tip `cddf8b9ad3cc999ae3ede135d46b0c7258985cdc` (sub-cycle 4
  paired cascade; previously
  `8d85e1db85675b6bec81dd63f4f63a950c258123`)).
- **Cross-module surface:** A4 introduces two
  `EXPORT_SYMBOL_GPL` symbols (`tb_egpu_close_diag_pdev`,
  `tb_egpu_get_gpu_pdev`) — these are the only
  `EXPORT_SYMBOL_GPL`s in the addon stack. The reason is that
  A4's UVM side runs in a separate `nvidia-uvm.ko` translation
  unit that does not link against the `nvidia.ko` source tree
  directly; the UVM Kbuild only adds `-I$(src)/nvidia-uvm` to
  the include path. Forward declarations of the exported
  symbols in `nv-tb-egpu-uvm.c` (`extern struct pci_dev
  *tb_egpu_get_gpu_pdev(void);` and `extern void
  tb_egpu_close_diag_pdev(struct pci_dev *pdev, const char
  *site);`) are sufficient at compile time; the runtime link
  is via the standard kernel symbol resolution. This is
  intentional and documented in the source.
- **Upstream issue:** n/a. Addon-layer close-path telemetry is
  project-local and never upstream-bound (per Rule 5:
  `upstream-candidacy: n/a` is the only allowed value for
  `layer: addon`). The underlying close-path bug class is the
  project's local response to the historical instrumentation
  gap surfaced by `project_close_path_mitigated_2026_05_08`;
  upstream NVIDIA bug #979 covers the bus-loss failure mode
  itself but does not cover instrumentation policy.
