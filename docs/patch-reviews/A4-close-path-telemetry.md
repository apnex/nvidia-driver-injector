---
id: A4-close-path-telemetry
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: f356c3b3782036307ac25e2f9100cfc9238aef05
v2-tip-sha: f356c3b3782036307ac25e2f9100cfc9238aef05
status: accepted
related-patches: [A1-pcie-primitives, A3-recovery]
---

# A4-close-path-telemetry — v2 review

## Rationale

A4 instruments the RM and UVM close paths so that close-path wedges
are no longer silent. The bug class — characterised in project memory
as the "close-path wedge" — was specifically discovered by adding
instrumentation to the close path; the production driver before patch
0029 (the close-path mitigation landed 2026-05-08, recorded in
`project_close_path_mitigated_2026_05_08`) committed silently to a
wedged state when nvidia-smi or a similar fd-holder closed during a
disconnect window. The fix was patch 0029, but the FINDING required
adding visibility to the close path; without that visibility,
operators saw "the GPU is hard-locked" with no kernel trace of WHY.
A4 makes that visibility permanent — every close-path lifecycle site
emits a `[CLOSE]` marker, and every last-close transition captures a
PMC_BOOT_0 + WPR2 hardware-health snapshot. The persistent capability
A4 grants the driver is: "every close-path event leaves evidence;
a silent close-path wedge becomes impossible by construction."

The historical context (belongs here per M3, not in the intent's
Purpose) is layered. The original instrumentation was authored as
legacy cluster P4 (`patches/legacy/0005-close-path-telemetry.patch`)
during the 2026-05-08 close-path investigation. The legacy file went
deeper than nominal telemetry — it dumped full LnkSta plus AER
multi-register state at each close-path site, which was the right
shape during investigation but produces noise in production soak.
The 2026-05-22 addon-recarve campaign
(`project_addon_recarve_merged_2026_05_22`) audited every addon's
telemetry surface against an explicit nominal-bar policy
(`docs/superpowers/specs/2026-05-22-addon-recarve-design.md`
§ "Observability audit") and trimmed A4 to the nominal-tier: one
marker line per site, hardware snapshot only on last-close, just the
two registers (PMC_BOOT_0 + WPR2) that distinguish "GPU alive and
clean" from "GPU off-the-bus or WPR2-stuck", plus a single
human-readable `wpr2_up:` verdict for fast triage. The
investigation-grade dump (cluster P6, the old `[DIAG]` concentrated
surface) was dissolved in the same campaign; if a future investigation
needs the deeper walk, the legacy `0006` patch is preserved in
`patches/legacy/` as the documented resurrection source. A4 is the
nominal-tier successor.

The persistent capability A4 grants the driver is, restated:
"the close path — historically the silent half of the bus-loss bug
class — is now observable end-to-end. Every fd close on
`/dev/nvidia<N>` and `/dev/nvidia-uvm` leaves a marker; the
last-close transition leaves a hardware-state snapshot. Reading
dmesg is sufficient to answer 'did the close path complete
healthily?' without further instrumentation."

## v1 audit

The v1 fork branch tip (`f356c3b3782036307ac25e2f9100cfc9238aef05` —
"tb-egpu: close-path nominal telemetry (A4)") sits on top of
`a3-recovery` (`f5216ee2`) and adds one commit's worth of changes:
468 insertions across 8 files (two new files in `nvidia/`, two new
files in `nvidia-uvm/`, and four additive hunks into vanilla or
earlier-patch files).

**Hunk-by-hunk audit (against the immediately-prior `a3` tip
`f5216ee20bcc803a265a6cb99bc0b246a10b6338`):**

1. **`kernel-open/nvidia/nv-tb-egpu-close.c`** — NEW FILE (152
   lines). MIT-licensed (SPDX `nvidia-driver-injector
   contributors`). File-level comment explicitly:
   (a) names the four nv.c call sites (close-entry, pre-stop,
   post-shutdown, close-exit); (b) describes the nominal-tier
   contract — one marker line per site, PMC_BOOT_0 + WPR2 snapshot
   only on last-close; (c) cites the addon-recarve design's
   observability audit as the rationale for excluding LnkSta + AER
   + the full `tb_egpu_dump_aer_trigger_event` walk; (d) calls out
   the dissolved P6 DIAG surface as the documented home for the
   investigation-grade dump if needed; (e) names the cross-module
   surface (`tb_egpu_get_gpu_pdev` and `tb_egpu_close_diag_pdev`)
   exported for `nvidia-uvm.ko`; (f) declares the passive
   instrumentation invariant (ioremap+ioread32 + PCI config-space
   reads only; no DMA, no register writes).

   The file contains three functions:

   - `tb_egpu_get_gpu_pdev(void)` — cross-module pdev lookup. Walks
     `nv_linux_devices` under `LOCK_NV_LINUX_DEVICES()` /
     `UNLOCK_NV_LINUX_DEVICES()`. Takes `pci_dev_get` on the first
     entry's `pci_dev`. Returns the refcounted pointer; caller MUST
     `pci_dev_put`. Returns `NULL` if no entry is bound.
     `EXPORT_SYMBOL_GPL`'d.
   - `tb_egpu_close_diag_pdev(pdev, site)` — pdev-based passive
     hardware-health snapshot. Defensive `pdev == NULL` and
     `bar0_phys == 0` early-returns each emit an error log line.
     `ioremap(bar0_phys, PAGE_SIZE)` + `ioread32` PMC_BOOT_0 +
     `iounmap`; `tb_egpu_recover_read_wpr2(bar0_phys, &wpr2_raw)`
     via A1; one `NV_DBG_ERRORS` log line of the form `"tb_egpu
     [CLOSE]: site=%-15s pdev=%s bar0=0x%llx PMC_BOOT_0=%s%08x
     WPR2=%s%08x wpr2_up:%s\n"` with the MAPFAIL: sentinel on read
     failure. `EXPORT_SYMBOL_GPL`'d.
   - `tb_egpu_close_diag(nvl, site, usage_count, is_last_close)` —
     RM-side marker + last-close snapshot dispatcher. `NULL nvl`
     no-op. `NV_DEV_PRINTF(NV_DBG_ERRORS, nv, "tb_egpu [CLOSE]:
     site=%-15s usage_count=%ld%s\n", site, usage_count,
     is_last_close ? " (LAST-CLOSE)" : "")`. On `is_last_close &&
     nvl->pci_dev`, calls `tb_egpu_close_diag_pdev(nvl->pci_dev,
     site)` for the snapshot. NOT exported (consumed only inside
     `nvidia.ko`).

2. **`kernel-open/nvidia/nv-tb-egpu-close.h`** — NEW FILE (88
   lines). MIT-licensed. Includes `linux/pci.h`, `linux/types.h`.
   Forward-declares `nv_linux_state_s` / `nv_linux_state_t`.
   Three function prototypes (`tb_egpu_close_diag`,
   `tb_egpu_close_diag_pdev`, `tb_egpu_get_gpu_pdev`).
   File-level comment enumerates the four nv.c call sites with
   short descriptions of each ("close-entry: top of
   nvidia_close_callback after nvl check", "pre-stop: inside
   nvidia_close_callback, under ldata_lock, just before
   nv_close_device", "post-shutdown: inside nv_stop_device after
   nv_shutdown_adapter", "close-exit: end of nvidia_close_callback,
   after nv_close_device"). Comment explicitly notes the passive
   instrumentation invariant and cites the 2026-05-08
   non-perturbing verification.

3. **`kernel-open/nvidia-uvm/nv-tb-egpu-uvm.c`** — NEW FILE (129
   lines). MIT-licensed. File-level comment explicitly:
   (a) names the five UVM lifecycle sites (uvm-open-entry,
   uvm-release-entry, uvm-pre-destroy, uvm-post-destroy,
   uvm-release-exit) with short descriptions of each;
   (b) describes the fd_count mechanism (`atomic_inc_return` on
   open, `atomic_dec_return` on release-exit, `atomic_read` on the
   three middle sites); (c) cites the design spec for the
   nominal-tier scope; (d) explains the cross-module pdev lookup
   (`tb_egpu_get_gpu_pdev` walks `nv_linux_devices` inside
   `nvidia.ko`; replaces the legacy hardcoded
   `pci_get_domain_bus_and_slot(0, 0x04, PCI_DEVFN(0,0))`);
   (e) declares the passive instrumentation invariant.

   The file contains:
   - Two `extern` forward declarations
     (`tb_egpu_get_gpu_pdev`, `tb_egpu_close_diag_pdev`) — the
     UVM Kbuild only adds `-I$(src)/nvidia-uvm` to the include
     path, so the cross-module symbols can't be reached via the
     nvidia/ tree's header; explicit `extern` declarations are
     used instead.
   - One module-private `static atomic_t tb_egpu_uvm_fd_count =
     ATOMIC_INIT(0)`.
   - One private shared body `tb_egpu_uvm_emit(site, fd_count,
     is_last_close)` that emits the `pr_info` marker line and on
     last-close calls `tb_egpu_get_gpu_pdev()` then
     `tb_egpu_close_diag_pdev(pdev, site)` then
     `pci_dev_put(pdev)`. If `tb_egpu_get_gpu_pdev()` returns
     NULL the body emits a fallback "no NVIDIA pdev bound;
     skipping snapshot" line and returns without attempting the
     snapshot.
   - Five public one-liner helpers each calling the shared body
     with the appropriate atomic operation:
     - `tb_egpu_uvm_close_diag_at_open` — `prev =
       atomic_inc_return(...) - 1; emit("uvm-open-entry",
       prev+1, prev == 0)`.
     - `tb_egpu_uvm_close_diag_at_release_entry` — `pre =
       atomic_read(...); emit("uvm-release-entry", pre, pre ==
       1)`.
     - `tb_egpu_uvm_close_diag_at_pre_destroy` — same pattern.
     - `tb_egpu_uvm_close_diag_at_post_destroy` — same pattern.
     - `tb_egpu_uvm_close_diag_at_release_exit` — `post =
       atomic_dec_return(...); emit("uvm-release-exit", post,
       post == 0)`.

4. **`kernel-open/nvidia-uvm/nv-tb-egpu-uvm.h`** — NEW FILE (38
   lines). MIT-licensed. Five function prototypes. File-level
   comment names each site and the LAST-CLOSE transition
   semantics (count==0→1 on open, count==1→0 on release-exit).

5. **`kernel-open/nvidia/nv.c`** — additive: one `#include
   "nv-tb-egpu-close.h"` after A3's `nv-tb-egpu-recover.h`
   include. Four call sites added:
   - In `nv_stop_device` after `nv_shutdown_adapter`:
     `tb_egpu_close_diag(nvl, "post-shutdown", 0L, true);` —
     `is_last_close` hard-coded `true` because `nv_stop_device`
     is only entered when the count has reached zero.
   - In `nvidia_close_callback` after `nv` is resolved (top of
     function): a `{ long _tb_uc = atomic64_read(&nvl->usage_count);
     tb_egpu_close_diag(nvl, "close-entry", _tb_uc, _tb_uc == 1); }`
     block. The `_tb_uc == 1` derivation assumes the close callback
     is called once per fd close and the pre-close count is 1 iff
     this is the last-fd-close. Each call site uses a local block
     to keep the temporary out of the surrounding scope.
   - Same callback under `ldata_lock`, immediately before
     `nv_close_device`: a `pre-stop` block, same `_tb_uc == 1`
     derivation. The `ldata_lock` is held across this site so the
     read is serialised against parallel closes.
   - Same callback at the end of the function, after
     `nv_close_device`: a `close-exit` block. Here the
     derivation is `_tb_uc == 0` because the count has been
     decremented by `nv_close_device`.

6. **`kernel-open/nvidia/nvidia-sources.Kbuild`** — additive: one
   line `NVIDIA_SOURCES += nvidia/nv-tb-egpu-close.c` inserted
   after A3's `nv-tb-egpu-recover.c` line. No `CONFIG_*` gate.

7. **`kernel-open/nvidia-uvm/uvm.c`** — additive: one `#include
   "nv-tb-egpu-uvm.h"` after `uvm_fd_type.h` and five call sites
   in `uvm_open` (one — at the end of the success path before
   `return NV_OK`) and `uvm_release` (four — at release entry,
   inside the `UVM_FD_VA_SPACE` branch's pre/post destroy, and
   at release exit).

8. **`kernel-open/nvidia-uvm/nvidia-uvm-sources.Kbuild`** —
   additive: one line `NVIDIA_UVM_SOURCES +=
   nvidia-uvm/nv-tb-egpu-uvm.c` inserted after `uvm_linux.c`.
   No `CONFIG_*` gate.

**Strengths.**

- **A1 ABI consumption is verbatim and minimal.** A4's source
  consumes `tb_egpu_recover_read_wpr2(bar0_phys, &raw)` once from
  `tb_egpu_close_diag_pdev` and uses
  `TB_EGPU_RECOVER_WPR2_VAL_MASK` to derive the `wpr2_up:`
  verdict. No other A1 symbols are called. A4 explicitly does NOT
  call `tb_egpu_dump_aer_trigger_event` (the full AER multi-hop
  dump) — that surface is reserved for A3's recovery dispatch and
  the watchdog. This is correct per the addon-recarve design
  spec's observability audit (§ "A4 close-path-telemetry — held
  to the nominal bar"). A1's contract explicitly permits A4 to
  call the dump with `out = NULL` if a future incident class
  proves the AER walk is needed at close-path; v1 does not
  exercise that option, and the intent does not require it.
- **A4 passes the right inputs and does NOT need the
  `out = NULL` discipline from A1's contract.** A1's review
  documented that "A3's err_handler callbacks and A4's close-path
  events MUST pass `out = NULL` because they have no per-device
  snapshot to persist into" — but this only applies if A4 were
  CALLING `tb_egpu_dump_aer_trigger_event`. Since A4 does NOT call
  that primitive at all in v1, the `out = NULL` discipline is
  moot. The contract is preserved as future-proofing: if A4 v3 or
  later adds a `tb_egpu_dump_aer_trigger_event` call for a
  specific close-path scenario, that call MUST pass `out = NULL`
  per A1's contract; the intent's Scope boundary documents this
  explicitly. The discovery anchor remains correct.
- **Nominal-tier discipline is enforced at the source level, not
  just in policy.** The file-level comment in
  `nv-tb-egpu-close.c` explicitly excludes LnkSta, AER Unc/Cor,
  and the full AER walk. The actual code reads PMC_BOOT_0 and
  WPR2 and emits one line. The contrast between "investigation
  grade" and "nominal" is in the source, not just in the design
  doc — a future reviewer cannot drift the file toward the
  investigation surface without noticing the comment.
- **The `is_last_close` predicate is computed by the caller.**
  Each of the four nv.c call sites computes its own
  `is_last_close` from the local `usage_count` reading
  (`uc == 1` for close-entry/pre-stop, `uc == 0` for close-exit,
  hard-coded `true` for post-shutdown). The function itself
  does not interpret `usage_count`; it just emits the marker and
  on the last-close branch dispatches the snapshot. This keeps
  the function context-agnostic — it works at any call site that
  knows when it's the last close.
- **`post-shutdown` is the right diagnostic site for the
  patch-0029 bug class.** The site is inside `nv_stop_device`
  AFTER `nv_shutdown_adapter` — i.e. after the destabilising
  teardown sequence runs. If the close-path wedge fires it
  fires here. The comment in nv.c explicitly cites this:
  "Captures PMC_BOOT_0 + WPR2 immediately after the
  destabilising teardown sequence — the most diagnostic site
  for the close-path bug class."
- **The UVM fd_count is module-private and atomic.** The
  counter is a `static atomic_t` inside `nv-tb-egpu-uvm.c`. The
  open path uses `atomic_inc_return` (taking the post-increment
  value); the release-exit path uses `atomic_dec_return` (also
  taking the post-decrement value); the three middle sites use
  `atomic_read` and do not mutate. The LAST-CLOSE predicate is
  derived from the atomic operation's return value, so a
  parallel open / release races correctly — only one fd_count
  transition can cross zero in either direction.
- **The cross-module surface is minimal: two exports
  (`tb_egpu_close_diag_pdev`, `tb_egpu_get_gpu_pdev`).** No
  other cross-module API is added; A2 / A3 do not introduce
  exports. The choice to export from `nvidia.ko` and use
  `extern` forward-declarations in `nvidia-uvm.ko` is correct
  for the kernel module loading order (nvidia.ko before
  nvidia-uvm.ko) and matches the kernel symbol resolution
  flow.
- **`tb_egpu_get_gpu_pdev` is single-pdev by design.** The
  function returns the first entry from `nv_linux_devices` with
  a refcounted pdev. Project memory `project_aorus_egpu_setup`
  documents the single-eGPU deployment shape; the function's
  semantics match. The replacement of the legacy hardcoded
  `pci_get_domain_bus_and_slot(0, 0x04, PCI_DEVFN(0,0))` is a
  generalisation — works on any PCI topology where
  `nvidia.ko` has bound a device.
- **Defensive `MAPFAIL:` sentinel rather than crashing.** When
  `ioremap` returns NULL or A1's helper returns non-zero, A4
  emits the line with the `MAPFAIL:` prefix on the failing
  field rather than panicking. Close-path telemetry MUST NEVER
  destabilise the close path itself — A4 prioritises "always
  emit a line" over "always emit a complete line". This is the
  correct trade-off for telemetry.
- **The five UVM sites bracket the destabilising `uvm_va_space_destroy`
  call.** `pre-destroy` and `post-destroy` are the
  load-bearing sites: if a UVM close wedges, it wedges in
  `uvm_va_space_destroy`, and the pre/post markers will
  unambiguously identify that. The release-entry and
  release-exit sites bracket the whole `uvm_release` function,
  so a wedge between those two without a pre/post pair
  identifies a wedge OUTSIDE the VA_SPACE branch (e.g. in the
  switch resolution or the mm_handle path).
- **No module parameters, no sysfs surfaces.** A4 is pure
  log-based observability. The marker line and the snapshot
  line are the entire userspace surface. No counters, no
  enable/disable knobs, no `CONFIG_NV_TB_EGPU_DIAG` gate. The
  master `CONFIG_NV_TB_EGPU` build toggle (A5) applies at
  file-compilation level; once compiled in, A4 is on. This
  matches the addon-recarve design's "trim the gates" policy.
- **Lifecycle is implicit — no init / stop helpers.** Unlike
  A2 (kthread spawn / stop) and A3 (state struct allocation /
  free), A4 has no per-device init or remove. The marker
  function is called inline from the nv.c call sites; the UVM
  helpers are called inline from uvm.c. The atomic counter
  initialises at module load via `ATOMIC_INIT(0)` and goes
  away at module unload. This is the right shape — A4 has no
  state worth managing.

**Weaknesses.**

- **`tb_egpu_get_gpu_pdev` returns only the first
  `nv_linux_devices` entry.** In a hypothetical multi-eGPU
  deployment, the UVM helper would attribute every UVM
  close-path snapshot to whichever pdev happens to be first in
  the list — not to the pdev whose fd is actually closing. The
  project ships single-eGPU only (per
  `project_aorus_egpu_setup`), so this is harmless in v1. A
  multi-device deployment would need a per-fd pdev lookup,
  which is significantly more complex (UVM fds don't directly
  reference an nvl). Surfaced as `A4-close-path-telemetry-D1`
  below with severity `nice-to-have`.
- **UVM fd_count is global, not per-pdev.** The
  `tb_egpu_uvm_fd_count` atomic is one number for the whole
  module; the LAST-CLOSE predicate fires when the global count
  crosses zero, not when any specific pdev's UVM fds reach
  zero. In single-eGPU deployment this is correct (one pdev
  ↔ one fd_count). In multi-eGPU it would conflate. Same
  scope as D1 above. Surfaced as
  `A4-close-path-telemetry-D2` below with severity
  `nice-to-have`.
- **The four RM-side call sites duplicate the
  `atomic64_read(&nvl->usage_count)` + scoped-block pattern.**
  Each site re-reads usage_count and computes
  `is_last_close` from the local read. This is correct
  (different sites observe different stages of the count's
  evolution) but mildly repetitive. A helper macro like
  `TB_EGPU_CLOSE_DIAG_HERE(nvl, site, last_pred)` could
  collapse the four blocks to one-liners. The current shape
  is more verbose but also more explicit — each site's
  `is_last_close` derivation is locally visible. No
  delta — verbosity here is a feature, not a bug.
- **`NV_DEV_PRINTF(NV_DBG_ERRORS, ...)` vs `nv_printf` ordering
  inside `tb_egpu_close_diag_pdev`.** The function uses
  `nv_printf(NV_DBG_ERRORS, ...)` for the defensive
  early-return branches (no `nvl` available, so the
  device-prefixed variant isn't usable) and the main snapshot
  block uses the same. The function does NOT have access to
  `nv_state_t *nv` (it takes a `struct pci_dev *` directly),
  so the per-device prefix isn't available. The pdev's BDF is
  emitted in the log line itself, so the log is still
  device-identifying. No delta — this is the right shape for
  a function exported across modules.
- **The `wpr2_up:` verdict is binary (`YES`/`no`) but the WPR2
  field is more nuanced.** WPR2 has structure beyond
  "non-zero": the `_VAL` mask captures bits 31:4, but bits 3:0
  are status flags. The verdict ignores those. For the
  close-path bug class (which presents as "WPR2 stuck
  non-zero") the binary verdict is sufficient — the soak gate
  and incident postmortems care about "is the failure mode
  active?" not "what's the precise WPR2 state?" The full raw
  value is still emitted in the line; the verdict is just a
  fast-triage aid. No delta.
- **The UVM `pr_info` log level is asymmetric with the RM-side
  `NV_DBG_ERRORS`.** RM uses `NV_DBG_ERRORS` (err-level);
  UVM uses `pr_info` (info-level). The RM-side `NV_DBG_*`
  family isn't linked from `nvidia-uvm.ko`, so the UVM side
  has to use the kernel's `printk` family directly. The
  choice of `pr_info` vs `pr_warn` / `pr_err` is a judgment
  call — UVM close-path events are not errors per se, they
  are observability. `pr_info` is appropriate at info-level
  visibility but means the UVM lines may be filtered out at
  lower-verbosity dmesg settings. The RM-side err-level lines
  will always be visible. This is a small asymmetry that the
  project's standard `loglevel=7` cmdline mitigates. No
  delta — the asymmetry is unavoidable given the module
  boundary.
- **There is no module parameter to disable A4's telemetry at
  runtime.** Unlike A2 (`NVreg_TbEgpuQwdEnable`) and A3
  (`NVreg_TbEgpuRecoverEnable`) which both have master enable
  knobs, A4 is on whenever compiled in. The rationale (per the
  intent's Scope boundary) is that close-path telemetry is
  cheap (one line per close + one snapshot on last-close) and
  the bug class A4 covers was specifically silent without it,
  so a runtime disable would defeat the purpose. The master
  `CONFIG_NV_TB_EGPU` build-time gate (A5) provides the
  compile-out path if needed. No delta — the design is
  intentional and matches the nominal-tier policy.

**Surprises relative to vanilla.**

- The patch is pure-additive against vanilla NVIDIA source for
  the new file inventory (`nv-tb-egpu-close.{c,h}` and
  `nv-tb-egpu-uvm.{c,h}`) and the two Kbuild lines. The two
  source files in `kernel-open/nvidia/` and the two in
  `kernel-open/nvidia-uvm/` have no vanilla counterparts.
- Vanilla `kernel-open/nvidia/nv.c:nv_stop_device` already
  runs `nv_shutdown_adapter`; A4 splices a single
  `tb_egpu_close_diag(nvl, "post-shutdown", 0L, true);` call
  immediately after, with no change to surrounding logic.
- Vanilla `kernel-open/nvidia/nv.c:nvidia_close_callback`
  already resolves `nvl` and runs `nv_close_device` under
  `ldata_lock`; A4 splices three local blocks (close-entry,
  pre-stop, close-exit) at the natural site boundaries. Each
  block is scoped to keep the temporary out of the
  surrounding function.
- Vanilla `kernel-open/nvidia-uvm/uvm.c:uvm_open` already has
  a success path returning `NV_OK`; A4 splices one helper call
  at the end of the success branch (immediately before
  `return NV_OK`).
- Vanilla `kernel-open/nvidia-uvm/uvm.c:uvm_release` already
  has the switch on `fd_type` and the `UVM_FD_VA_SPACE` branch
  calling `uvm_release_va_space`; A4 splices four helper calls
  at the natural site boundaries (release entry, pre/post
  destroy in the VA_SPACE branch, release exit).
- Vanilla `nvidia-sources.Kbuild` and `nvidia-uvm-sources.Kbuild`
  enumerate the standard module sources; A4 adds exactly one
  line to each.

## Design choices

The main alternatives considered during the v2 review:

- **Nominal telemetry vs. investigation-grade dump.** The legacy
  P4 file dumped full LnkSta + AER multi-register state at each
  close-path site. Considered preserving that surface in A4.
  Rejected because: (1) production soak generates noise from
  per-site multi-register dumps — operationally the soak gate
  reads "did the close path complete healthily?" not "what
  was the full LnkSta/AER state at four sites?". (2) The
  investigation-grade dump surface was concentrated in the old
  P6 [DIAG] cluster, which the addon-recarve design dissolved
  in favour of per-patch nominal telemetry. (3) If a future
  investigation needs the deeper walk, the legacy `0005` (and
  `0006`) patches are preserved in `patches/legacy/` as
  resurrection sources. Kept v1's nominal-tier scope.
- **PMC_BOOT_0 + WPR2 vs. just PMC_BOOT_0.** Considered
  trimming the snapshot to PMC_BOOT_0 alone — the simplest
  "is the GPU responding?" check. Rejected because the WPR2
  state is the specific differentiator for the project's
  characterised close-path failure mode. PMC_BOOT_0 == `0xffffffff`
  catches "off-the-bus"; WPR2 catches "GPU bus-alive but
  firmware-boot-stuck" (the A3 trigger condition). Both signals
  are operationally orthogonal and both are needed for the
  one-line triage to be unambiguous. The two-register snapshot
  + verdict is the minimum sufficient observation set. Kept
  v1's two-register snapshot.
- **`wpr2_up:` verdict word vs. raw value only.** Considered
  emitting only the raw WPR2 value and letting the operator /
  soak gate compute the verdict themselves. Rejected because
  the verdict adds zero log volume (it's a single 3-character
  field at the end of an existing line) but saves the reader
  from deriving it. The raw value is still emitted alongside
  the verdict, so a future operator who cares about the bit
  structure has both. Kept v1's verdict-plus-raw shape.
- **Four RM call sites vs. fewer.** Considered cutting to two
  (close-entry + post-shutdown — the boundary events of the
  close path). Rejected because pre-stop catches the
  pre-`nv_close_device` state (which is what the
  `ldata_lock`-held block observes), and close-exit catches
  the post-`nv_close_device` state. The four-site cluster
  brackets the close path tightly enough that any wedge sits
  between two consecutive markers — a wedge between pre-stop
  and close-exit means `nv_close_device` itself wedged; a wedge
  between pre-stop and post-shutdown means `nv_shutdown_adapter`
  wedged. With only two sites, attribution would be ambiguous
  for the most diagnostic wedge sites. Kept v1's four-site
  shape.
- **Five UVM call sites vs. fewer.** Considered cutting to
  two (uvm-open-entry + uvm-release-exit — the lifecycle
  endpoints). Rejected because the historical UVM wedge sites
  are inside `uvm_va_space_destroy`; the pre/post-destroy
  markers are load-bearing for attributing a wedge to the
  VA_SPACE branch specifically. The release-entry marker
  catches the pre-decrement state for race analysis (which
  fd_type was the closing fd? was the count already at the
  expected pre-LAST-CLOSE value?). Kept v1's five-site shape.
- **`EXPORT_SYMBOL_GPL` vs. include-based cross-module surface.**
  Considered routing the UVM-side helpers through a shared
  header included by both modules' Kbuild. Rejected because
  the existing UVM Kbuild only adds `-I$(src)/nvidia-uvm` and
  modifying it to include `-I$(src)/nvidia` would couple the
  build topology more tightly than necessary. `EXPORT_SYMBOL_GPL`
  + `extern` forward declarations is the standard pattern for
  cross-module surfaces in the kernel; A4 follows it. Kept
  v1's export-based shape.
- **`tb_egpu_get_gpu_pdev` vs. hardcoded BDF lookup.** The
  legacy close-path code used `pci_get_domain_bus_and_slot(0,
  0x04, PCI_DEVFN(0,0))` — i.e. a hardcoded BDF that matched
  the project's eGPU position. A4 replaces this with a walk
  of `nv_linux_devices` (returning the first entry's pdev
  refcounted). The walk is correct for any topology, single
  or multi-device. Rejected the hardcoded BDF because it
  breaks any future deployment that moves the eGPU to a
  different bus / slot. Kept v1's `nv_linux_devices` walk.
- **No module parameter for runtime disable.** Considered
  adding `NVreg_TbEgpuCloseDiagEnable` (matching A2's and A3's
  pattern). Rejected because: (1) the telemetry is cheap (one
  line per close + one snapshot on last-close); (2) the bug
  class A4 covers is specifically silent without
  instrumentation, so a runtime disable defeats the purpose;
  (3) the `CONFIG_NV_TB_EGPU` build-time gate (A5) provides
  the compile-out path. Kept v1's no-runtime-disable shape.
- **Calling `tb_egpu_dump_aer_trigger_event` at close sites.**
  The A3 callback bodies call A1's dump primitive at four
  event tags (`error-handler`, `mmio-enabled`, `cor-error`,
  `qwd-detect`); the close-path could plausibly add
  `close-entry` / `close-exit` tags. Considered. Rejected
  because: (1) the close path is NOT an error-recovery
  context; the AER state at close is not the load-bearing
  signal for close-path wedges (PMC_BOOT_0 + WPR2 are).
  (2) The full AER walk is investigation-grade telemetry
  that the addon-recarve design explicitly trimmed from A4
  (per the design's observability audit). (3) A1's contract
  documents that A4 holds the option to call the dump with
  `out = NULL` if a future incident class proves the need;
  v1 does not exercise that option, and the intent's Scope
  boundary documents the deferred capability. Kept v1's
  no-AER-dump shape.

## v1 → v2 deltas

### A4-close-path-telemetry-D1 — `tb_egpu_get_gpu_pdev` is single-pdev by design (multi-eGPU deferred)

- **Location:** `kernel-open/nvidia/nv-tb-egpu-close.c:tb_egpu_get_gpu_pdev`
- **Change:** No code change — documentation in the intent's
  fourth Requirement and in the Scope boundary now explicitly
  states the single-pdev semantics. The function returns the
  first entry from `nv_linux_devices` with `pci_dev_get` taken;
  the project's deployment shape (one eGPU per host per
  `project_aorus_egpu_setup`) guarantees that entry is the
  correct one.
- **Severity:** nice-to-have
- **Evidence:** The function walks the linked list and breaks on
  the first `pci_dev` it finds. In a hypothetical multi-eGPU
  deployment the UVM helper would attribute every UVM
  close-path snapshot to whichever pdev happens to be first in
  the list — not to the pdev whose fd is actually closing. The
  project doesn't currently care about multi-device. The intent
  documents the deployment shape and the constraint explicitly
  so a future multi-device deployment knows where to refactor.
- **Resolution:** documented in intent — no code change. A
  future multi-device deployment would refactor to a per-fd
  pdev lookup (which UVM doesn't currently support — UVM fds
  don't directly reference an `nv_linux_state_t`).

### A4-close-path-telemetry-D2 — UVM fd_count is global, not per-pdev (multi-eGPU deferred)

- **Location:** `kernel-open/nvidia-uvm/nv-tb-egpu-uvm.c:tb_egpu_uvm_fd_count`
- **Change:** No code change — same architectural boundary as
  D1. The UVM-side fd_count is one module-private atomic for the
  whole module; the LAST-CLOSE predicate fires when the global
  count crosses zero. In single-eGPU deployment this is correct
  (one pdev ↔ one fd_count); in multi-eGPU it would conflate
  across devices.
- **Severity:** nice-to-have
- **Evidence:** `tb_egpu_uvm_fd_count` is declared as
  `static atomic_t ... = ATOMIC_INIT(0)`. There is no per-pdev
  partitioning. UVM does not maintain a per-pdev fd table
  natively (UVM fds are global to the module); adding one
  would be a substantial refactor.
- **Resolution:** documented in intent — no code change.
  Deferred to a future multi-device generalisation. Same scope
  as D1.

### A4-close-path-telemetry-D3 — A1's `out = NULL` discipline is documented as future-proofing (A4 does not call the dump in v1)

- **Location:** Intent's Scope boundary clause referencing
  `tb_egpu_dump_aer_trigger_event`
- **Change:** No code change — confirming v1's shape. A1's
  contract documented that "A3's err_handler callbacks and A4's
  close-path events MUST pass `out = NULL` because they have no
  per-device snapshot to persist into". In v1 A4 does not call
  the dump primitive at all, so the discipline is moot for v1.
  The intent's Scope boundary explicitly notes the deferred
  capability ("A4 holds the option to call A1's dump with
  `out = NULL` if a future incident class proves the AER walk
  is needed at close-path; v1 does not exercise that option").
- **Severity:** out-of-scope
- **Evidence:** `grep -n "tb_egpu_dump_aer_trigger_event"
  patches/addon/A4-close-path-telemetry.patch` returns zero
  hits. A4's source files do not include any call to the dump
  primitive. The contract documented in A1's review is correctly
  recorded as future-proofing; if A4 v3 or later adds a dump
  call, it MUST pass `out = NULL` per A1's contract.
- **Resolution:** accepted — A1's documented contract is
  preserved as future-proofing in A4's Scope boundary. The
  discovery anchor (A1 review's mention of A4) remains correct
  and forward-looking.

### A4-close-path-telemetry-D4 — No must-fix or should-fix deltas

- **Location:** n/a
- **Change:** v1's behaviour, telemetry, and surface match the
  v2 intent's normative shape. The intent's four Requirements
  are satisfied: the four RM-side close-path call sites are
  correctly placed and parameterised; the PMC_BOOT_0 + WPR2
  snapshot is captured on last-close transitions with the
  documented format string and the `wpr2_up:` verdict; the
  five UVM-side helpers maintain the module-private atomic
  fd_count and dispatch the shared `tb_egpu_uvm_emit` body
  with the right last-close predicates; the cross-module
  `tb_egpu_get_gpu_pdev` lookup walks `nv_linux_devices` under
  the global lock and returns a refcounted pdev with the
  correct caller-puts-it contract. A1's ABI consumption is
  verbatim (`tb_egpu_recover_read_wpr2` plus
  `TB_EGPU_RECOVER_WPR2_VAL_MASK`); A1's
  `tb_egpu_dump_aer_trigger_event` is deliberately NOT called
  per the addon-recarve audit. No fork-branch follow-up
  commits are required.
- **Severity:** out-of-scope
- **Evidence:** Every scenario in the four Requirements maps to
  a v1 code path. The Scope boundary's seven non-goals are
  each satisfiable by inspection of the v1 files: no recovery
  trigger (→ A3); no PMC_BOOT_0 polling (→ A2); no new PCIe /
  AER / WPR2 primitive (→ A1); no sysfs counter; no
  `pci_error_handlers` callback or module parameter
  (→ C4 + A3 + A5); no `tb_egpu_dump_aer_trigger_event` call
  (deferred); no non-close-path lifecycle instrumentation. The
  telemetry-tier `mandatory` rating is justified by the
  close-path bug class history (`project_close_path_mitigated_2026_05_08`).
- **Resolution:** rejected — no v2 follow-up needed.

Per M2 (zero-delta sentinel from the C1 checkpoint), the
frontmatter
`v1-tip-sha == v2-tip-sha == f356c3b3782036307ac25e2f9100cfc9238aef05`
is the machine-checkable signal that v1 already met v2 intent. The
four deltas (D1 nice-to-have single-pdev deployment shape, D2
nice-to-have global fd_count, D3 out-of-scope confirming A1's
`out = NULL` future-proofing, D4 explicit no-must-fix) are recorded
for provenance and to give downstream consumers (A5 — the next
task — plus Task 14 cross-patch audit) the contract they should
code against:

- A4's RM-side log surface is `"tb_egpu [CLOSE]: site=..."`
  with `usage_count=` and optional `(LAST-CLOSE)` trailing
  marker, plus on last-close the `pdev=... bar0=... PMC_BOOT_0=...
  WPR2=... wpr2_up:YES|no` snapshot line. The format strings
  are stable and lint-targetable.
- A4's UVM-side log surface is `"tb_egpu UVM [CLOSE]: site=..."`
  with `fd_count=` and optional `(LAST-CLOSE)` trailing
  marker, plus the same snapshot line shape on last-close.
- A4's cross-module ABI is two `EXPORT_SYMBOL_GPL` symbols
  (`tb_egpu_close_diag_pdev`, `tb_egpu_get_gpu_pdev`)
  consumed by `nvidia-uvm.ko` via `extern` forward
  declarations.
- A4's interaction with A1 is unidirectional (consumer-only):
  one call to `tb_egpu_recover_read_wpr2` plus one constant
  reference (`TB_EGPU_RECOVER_WPR2_VAL_MASK`). No other A1
  symbols are exercised.
- A4's interaction with A2 / A3 is none-direct. A4 sits
  alongside them in the addon stack as an independent
  consumer of A1; the three patches share A1's foundation
  but do not call each other.
- A4's interaction with A5 is build-only — A5's
  `CONFIG_NV_TB_EGPU` master toggle gates A4's source-list
  rows (`nvidia/nv-tb-egpu-close.c` and
  `nvidia-uvm/nv-tb-egpu-uvm.c`) at compile time. There is no
  runtime A4 / A5 dependency.
- A4 holds the future-capability option to call A1's
  `tb_egpu_dump_aer_trigger_event(pdev, "<tag>", NULL)` if a
  future incident class proves the AER walk is needed at
  close-path. v1 does not exercise this option. The
  `out = NULL` discipline from A1's contract applies if the
  option is ever exercised.

## Done gate

- [x] `docs/patch-intents/A4-close-path-telemetry.md` exists, lints clean, `status: reviewed`.
- [x] All must-fix deltas applied as fork-branch commits citing their delta IDs. _(N/A — zero must-fix deltas; D1 / D2 nice-to-have deployment-shape documentation, D3 out-of-scope confirming A1's contract preservation, D4 explicitly closes "no must-fix".)_
- [x] `patches/addon/A4-close-path-telemetry.patch` refreshed by `regen`. _(N/A — no fork-branch change; existing file already reflects `f356c3b3`.)_
- [x] `tools/validate-patchset.sh` passes (compile gate).
- [x] `bash tests/run.sh` green.
- [ ] Audit-reviewer subagent approved. _(Pending — this review file is the audit-reviewer's input.)_

## Cross-references

- Intent file: `docs/patch-intents/A4-close-path-telemetry.md`
- Manifest row: `patches/manifest` line for `A4-close-path-telemetry`
  (layer `addon`, source `fork:a4-close-path-telemetry`)
- Vanilla baseline:
  - `kernel-open/nvidia/nv.c:nv_stop_device` — vanilla runs
    `nv_shutdown_adapter`; A4 adds one
    `tb_egpu_close_diag(nvl, "post-shutdown", 0L, true)` call
    immediately after.
  - `kernel-open/nvidia/nv.c:nvidia_close_callback` — vanilla
    resolves `nvl`, runs `rm_cleanup_file_private`, takes
    `ldata_lock`, runs `nv_close_device`, releases the lock,
    then `nv_free_file_private`. A4 adds three scoped blocks:
    `close-entry` at the top after `nvl` resolution; `pre-stop`
    under `ldata_lock` immediately before `nv_close_device`;
    `close-exit` at the end after `nv_close_device`.
  - `kernel-open/nvidia/nvidia-sources.Kbuild` — vanilla
    enumerates the standard module sources; A4 adds one line
    `NVIDIA_SOURCES += nvidia/nv-tb-egpu-close.c` after A3's
    `nv-tb-egpu-recover.c` line.
  - `kernel-open/nvidia-uvm/uvm.c:uvm_open` — vanilla has a
    success path returning `NV_OK`; A4 adds one
    `tb_egpu_uvm_close_diag_at_open()` call at the end of the
    success branch.
  - `kernel-open/nvidia-uvm/uvm.c:uvm_release` — vanilla has
    the switch on `fd_type` and the `UVM_FD_VA_SPACE` branch
    calling `uvm_release_va_space`; A4 adds four helper calls
    (release-entry top, pre-destroy and post-destroy inside the
    VA_SPACE branch, release-exit at the bottom).
  - `kernel-open/nvidia-uvm/nvidia-uvm-sources.Kbuild` —
    vanilla enumerates the standard UVM sources; A4 adds one
    line `NVIDIA_UVM_SOURCES += nvidia-uvm/nv-tb-egpu-uvm.c`
    after `uvm_linux.c`.
  - `kernel-open/nvidia/nv-tb-egpu-close.c` — NEW FILE (152
    lines, no vanilla counterpart).
  - `kernel-open/nvidia/nv-tb-egpu-close.h` — NEW FILE (88
    lines, no vanilla counterpart).
  - `kernel-open/nvidia-uvm/nv-tb-egpu-uvm.c` — NEW FILE (129
    lines, no vanilla counterpart).
  - `kernel-open/nvidia-uvm/nv-tb-egpu-uvm.h` — NEW FILE (38
    lines, no vanilla counterpart).
- Fork branch: `a4-close-path-telemetry` on
  `apnex/open-gpu-kernel-modules` tip `f356c3b3`.
- Upstream issue: n/a (addon-layer; not upstream-bound; per
  Rule 5 `upstream-candidacy: n/a` for `layer: addon`). The
  close-path instrumentation policy is project-local and never
  upstream-bound. The underlying bus-loss failure mode that A4
  makes observable is tracked at NVIDIA bug #979; A4's
  instrumentation is the project's local response to the
  historical close-path observability gap surfaced by
  `project_close_path_mitigated_2026_05_08`.
- Related reviews: [[A1-pcie-primitives]] (foundation that A4
  consumes via `tb_egpu_recover_read_wpr2` and
  `TB_EGPU_RECOVER_WPR2_VAL_MASK` — see "A1 ABI consumed" in
  the intent's Provenance). [[A3-recovery]] (sibling addon
  consumer of A1 that A4 sits alongside — A4 is observability
  for the close-path bug class that A3's recovery dispatch
  doesn't cover; A4's snapshot line on LAST-CLOSE may coincide
  with an A3 recovery cycle in flight, and the `site=`
  attribution disambiguates the two log surfaces).
  [[A2-bus-loss-watchdog]] (parallel addon — A2 polls
  PMC_BOOT_0 for dead-bus detection; A4 reads PMC_BOOT_0 only
  on close-path last-close transitions, an event not a
  heartbeat). [[A5-version-and-toggles]] (the build-time
  `CONFIG_NV_TB_EGPU` master toggle that gates A4's two
  source-list rows; A4 has no runtime dependency on A5).
- Carve provenance:
  `docs/superpowers/specs/2026-05-22-addon-recarve-design.md`
  — §"A4 close-path-telemetry" describes the trim from legacy
  P4's investigation-grade dump to the nominal-tier scope.
  §"Observability audit" documents the explicit policy that
  A4's telemetry is held to "a line on the meaningful
  last-close transition" with "any creeping full-state dump
  that drifts toward investigation-grade" trimmed.
  `project_close_path_mitigated_2026_05_08` — the close-path
  bug class history that justifies A4's `mandatory`
  telemetry-tier rating (patch 0029 mitigated the bug; the
  discovery required adding instrumentation that the
  production driver previously lacked).
  `project_addon_recarve_merged_2026_05_22` — the campaign
  that consolidated A4's nominal-tier surface and dissolved
  the P6 [DIAG] surface that the legacy P4 telemetry would
  otherwise have drifted toward.
