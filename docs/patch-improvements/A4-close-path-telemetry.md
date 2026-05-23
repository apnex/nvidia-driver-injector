---
id: A4-close-path-telemetry
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: 8d85e1db85675b6bec81dd63f4f63a950c258123
v2-tip-sha: 8d85e1db85675b6bec81dd63f4f63a950c258123
status: accepted
intent-updates: []
---

# A4-close-path-telemetry — improvement triage

## Triangulation sources

- **Vanilla NVIDIA 595.71.05** — A4 introduces four wholly-new files
  (`kernel-open/nvidia/nv-tb-egpu-close.{c,h}`, 152 + 88 lines; and
  `kernel-open/nvidia-uvm/nv-tb-egpu-uvm.{c,h}`, 129 + 38 lines) plus
  four additive hunks against vanilla files: `kernel-open/nvidia/nv.c`
  (one `#include` + four call sites in `nvidia_close_callback` and
  `nv_stop_device`), `kernel-open/nvidia/nvidia-sources.Kbuild` (one
  `NVIDIA_SOURCES +=` line), `kernel-open/nvidia-uvm/uvm.c` (one
  `#include` + five call sites in `uvm_open` and `uvm_release`), and
  `kernel-open/nvidia-uvm/nvidia-uvm-sources.Kbuild` (one
  `NVIDIA_UVM_SOURCES +=` line). Vanilla baselines verified via
  `git show 595.71.05:`:
  - `kernel-open/nvidia/nv.c:nv_stop_device` (line 2071-2099) — calls
    `nv_shutdown_adapter` in the non-persistent branch; A4 splices one
    `tb_egpu_close_diag(nvl, "post-shutdown", 0L, true)` call
    immediately after.
  - `kernel-open/nvidia/nv.c:nvidia_close_callback` (line 2157-2200,
    spanning `nv_close_device`) — vanilla resolves `nvl`, takes
    `ldata_lock`, runs `nv_close_device` (which atomically
    decrements `usage_count` via `atomic64_dec_and_test`), releases
    the lock, then `nv_free_file_private`. A4 splices three scoped
    blocks (close-entry / pre-stop / close-exit) at the natural site
    boundaries.
  - `kernel-open/nvidia/nv.c:nv_close_device` (line 2127-2148) —
    confirms the load-bearing predicate: `usage_count==1` pre-call
    means `dec_and_test` returns true → `nv_stop_device` runs. A4's
    `_tb_uc == 1` derivation at `close-entry` / `pre-stop` correctly
    predicts LAST-CLOSE.
  - `kernel-open/nvidia-uvm/uvm.c:uvm_open` (line 144-184) — vanilla
    initialises filp's private data on the success path before
    returning `NV_OK`; A4 inserts
    `tb_egpu_uvm_close_diag_at_open()` after that initialisation.
  - `kernel-open/nvidia-uvm/uvm.c:uvm_release` (line 250-277) —
    vanilla resolves `fd_type` and switches on it; the
    `UVM_FD_VA_SPACE` branch calls `uvm_release_va_space`. A4
    inserts four helper calls (release-entry top, pre-destroy and
    post-destroy bracketing `uvm_release_va_space`, release-exit
    bottom).
  - `<linux/atomic.h>`: `atomic_inc_return(&v)` returns the new
    value; `atomic_dec_return(&v)` returns the new value;
    `atomic_read(&v)` is the lockless read. Used by A4's UVM-side
    `tb_egpu_uvm_fd_count` mechanism per
    `Documentation/atomic_t.txt`.
  - `<linux/pci.h>`: `pci_resource_start(pdev, 0)` returns BAR0
    physical base; `pci_dev_get(pdev)` increments refcount;
    `pci_dev_put(pdev)` decrements. `pci_name(pdev)` returns the
    BDF string. A4 uses these in the cross-module pdev lookup and
    snapshot helper.
  - `<linux/io.h>`: `ioremap(phys, size)` + `ioread32(vaddr)` +
    `iounmap(vaddr)` is the transient-mapping primitive A4 uses
    for PMC_BOOT_0 read in `tb_egpu_close_diag_pdev`.
  - `LOCK_NV_LINUX_DEVICES()` / `UNLOCK_NV_LINUX_DEVICES()` (from
    `nv-linux.h`) — the global lock around `nv_linux_devices` list
    iteration. A4's `tb_egpu_get_gpu_pdev` walks under this lock
    and takes `pci_dev_get` on the matched entry before releasing.
- **v2 intent:** `docs/patch-intents/A4-close-path-telemetry.md`
  (status `reviewed`; reconciled at commit `e8fb311` for the
  CONFIG_NV_TB_EGPU prose drift — see §"Re-examination" I11).
- **v2 review:** `docs/patch-reviews/A4-close-path-telemetry.md`
  (status `accepted`; documents 4 deltas — D1 nice-to-have
  single-pdev `tb_egpu_get_gpu_pdev` semantics, D2 nice-to-have
  global UVM fd_count, D3 out-of-scope confirming A1's `out=NULL`
  future-proofing, D4 explicit no-must-fix sentinel). v1-tip-sha
  and v2-tip-sha both `8d85e1db` in the review frontmatter; the
  current fork-branch tip post the addon-recarve cascade is
  `8d85e1db…` (the SHA advanced when the A1 I8 / addon-recarve
  cascade rebased the addon stack). The review frontmatter SHA
  is stale relative to the current fork-branch tip — surfaced as
  context note in I11 (no v3 doc edit required; the
  2026-05-22 cascade remap at `e389814` propagated tip SHAs for
  patches with material I-commits, and A4's frontmatter remap
  was folded into that cascade-remap commit).
- **aorus-5090 ancestor patches** (verified per M1+M2 against grep
  `close.?path|destroy_marker|uvm_release|tb_egpu_close_diag|fd_count`
  on `/root/aorus-5090-egpu/patches/`):
  - `patches/0029-Lever-M-recover-close-path-diag-and-AER-surface-completion.patch`
    (lines 1-100, ~309 lines total) — **canonical RM-side
    close-path DIAG ancestor.** Patch-body lines 1-32 establish the
    "Extends our open-side DIAG infrastructure ... into the close
    path" rationale plus the four-site cluster naming
    (close-entry / pre-stop / post-shutdown / close-exit) verbatim;
    lines 33-65 explain the LAST-CLOSE gating and the diff-driven
    "what does the close path mutate" investigation goal; lines
    73-103 introduce the
    `tb_egpu_lever_m_close_path_diag(nvl, site, usage_count,
    is_last_close)` helper signature that A4's
    `tb_egpu_close_diag(nvl, site, usage_count, is_last_close)`
    inherits 1:1 (renamed `lever_m_close_path_diag` → `close_diag`
    in the addon-recarve carve). The legacy patch also included
    Part B (`pci_error_handlers` `mmio_enabled` +
    `cor_error_detected` callbacks) and Part C (version.mk
    aorus.11 bump); A4 carries only Part A — the err_handler
    callbacks moved to C4 (registration) + A3 (body fill-in),
    and the version bump moved to C1.
  - `patches/0030-Lever-M-recover-UVM-close-path-DIAG.patch`
    (lines 1-100, ~332 lines total) — **canonical UVM-side
    close-path DIAG ancestor.** Patch-body lines 1-62 establish
    the companion-to-0029 framing for UVM and name the five
    UVM-side site cluster (uvm-open-entry / uvm-release-entry /
    uvm-pre-destroy / uvm-post-destroy / uvm-release-exit)
    verbatim. Lines 21-32 introduce
    `tb_egpu_lever_m_diag_dump_pdev(struct pci_dev *, const char
    *)` EXPORT_SYMBOL — A4's `tb_egpu_close_diag_pdev(struct
    pci_dev *pdev, const char *site)` is the recarve descendant
    (renamed `lever_m_diag_dump_pdev` → `close_diag_pdev`;
    `EXPORT_SYMBOL` → `EXPORT_SYMBOL_GPL` per the standard
    kernel-module licensing convention). Lines 29-31 establish
    the `aorus_uvm_fd_count` atomic mechanism A4's
    `tb_egpu_uvm_fd_count` preserves verbatim. Lines 29-31 also
    document the legacy hardcoded pdev lookup
    `pci_get_domain_bus_and_slot(0, 0x04, PCI_DEVFN(0,0))` that
    A4 replaces with the generalised `tb_egpu_get_gpu_pdev` walk
    of `nv_linux_devices`.
  - `patches/0009-uvm-destroy-diagnostic-markers-Lever-P-probe.patch`
    (lines 1-60, ~172 lines total) — **canonical UVM
    `uvm_va_space_destroy` markers ancestor**, the historical
    Lever P-probe that localised the deadlock locus inside
    `uvm_va_space_destroy`. Patch-body lines 5-29 establish the
    "diagnostic-only" framing for instrumenting
    `uvm_va_space_destroy`. Lever P-probe was **intentionally
    transient** (per `docs/lever-catalog.md` lines 454-467 —
    quoted: "P-probe is the one lever in this catalog that is
    INTENTIONALLY transient. It exists to identify the precise
    locus inside `uvm_va_space_destroy` that deadlocks; once
    located, P-comprehensive will be a single fail-fast patch
    covering all identified sites"). A4 inherits the
    pre-destroy / post-destroy bracketing pattern but at the
    `uvm_release` switch's `UVM_FD_VA_SPACE` branch (one level
    above `uvm_va_space_destroy` itself) — sufficient to
    distinguish "wedge inside VA_SPACE branch" from "wedge
    elsewhere in `uvm_release`" without instrumenting the
    `va_space_destroy` internals. The 0009 internal-site
    markers were not carved into A4 (the deeper UVM
    instrumentation is investigation-grade and lives in the
    dissolved P6 DIAG surface — see addon-recarve design
    spec § "Observability audit").
  - `patches/0020-Phase-A-PCIe-LnkSta-AER-telemetry.patch`
    (lines 1-50, ~114 lines total) — **context-only ancestor.**
    Introduced the LnkSta + AER multi-register dump surface that
    the legacy P4 cluster's close-path telemetry rolled into. A4
    does NOT call this surface in v1 — the addon-recarve audit
    trimmed the full LnkSta + AER walk from A4 to the nominal
    bar (PMC_BOOT_0 + WPR2 + verdict). The Phase-A surface lives
    in A1's `tb_egpu_dump_aer_trigger_event` primitive (reserved
    for A3's recovery dispatch and the watchdog detection latch).
    Cited as the documented home for the investigation-grade
    walk if a future incident class proves it's needed at
    close-path.
  - `patches/0021-G3-G-AER-Header-Log-capture.patch` (lines 1-50,
    ~171 lines total) — **context-only ancestor.** Companion to
    0020, adds AER Header Log capture. Same disposition as 0020 —
    A4 does NOT call this surface; reserved for A1's dump
    primitive. The two together (0020 + 0021) constitute the
    investigation-grade observability surface that the
    addon-recarve audit dissolved from the production telemetry
    bar.
- **aorus-5090 docs consulted (M1+M2 verification):**
  - `docs/lever-catalog.md` lines 353-360 (Lever M-recover code
    surface enumeration). **Highly relevant.** Line 353 cites
    "plus Patch 0029 close-path instrumentation" as a load-bearing
    component of the M-recover stack. Line 359 details Patch 0029
    ("Adds 4 close-path DIAG sites (close-entry, pre-stop,
    post-shutdown, close-exit) gated on LAST-CLOSE") plus the
    `tools/close-path-probe.sh` companion script and the
    2026-05-08 n=3 empirical demonstration that the close-path
    bug class is mitigated on the current driver stack.
  - `docs/lever-catalog.md` lines 454-467 (Lever P-probe /
    P-comprehensive entry). **Highly relevant.** Lines 454-456
    cite Patch 0009 (P-probe LANDED 2026-05-04, transient
    diagnostic) and the P-comprehensive TODO. Lines 459-467
    establish the "INTENTIONALLY transient" framing — A4's
    bracketing of `uvm_va_space_destroy` at the
    `UVM_FD_VA_SPACE` switch branch (rather than at the
    internal site markers 0009 used) is the architectural
    choice the addon-recarve design endorses.
  - `docs/event-capture-methodology.md` lines 180-237 (Close-path
    probe + UVM close-path probe sections). **Highly relevant.**
    Lines 183-207 document the `close-path-probe.sh` tool that
    consumes A4's RM-side surface; lines 203-207 specify the
    expected dmesg delta ("4 close-path DIAG entries
    (`close-entry`, `pre-stop`, `post-shutdown`, `close-exit`)
    on the LAST-CLOSE path"). Lines 209-237 document
    `uvm-close-path-probe.sh` consuming A4's UVM-side surface;
    lines 224-230 specify "dmesg delta will include
    `[CLOSE]: site=uvm-open-entry`, `uvm-release-entry`,
    `uvm-pre-destroy`, `uvm-post-destroy`, `uvm-release-exit`
    markers. On LAST-CLOSE, full [UVM-DIAG] state snapshot fires
    at each site" — the legacy `[UVM-DIAG]` tag was the
    investigation-grade [DIAG] dump; A4's nominal-tier successor
    uses `[CLOSE]` (RM) and `UVM [CLOSE]` (UVM) tags.
  - `docs/recovery-mechanism-findings.md` lines 1-30 — **dropped
    per M1** (covers Lever M FLR-vs-bus-reset for A3's recovery
    primitive, not A4's close-path telemetry; A3's catalog cites
    this doc explicitly as context for the FLR rejection).
  - `docs/state-capture-methodology.md` (`wc -l` 264) —
    **checked per binding; cited for the passive-capture pattern.**
    Grep `pmc_boot_0|ioremap.*BAR0|bar0_phys|tb_egpu_lever_m_diag_dump_pdev`
    returns content; the doc establishes the pattern A4's
    `tb_egpu_close_diag_pdev` follows: ioremap a single page at
    `pci_resource_start(pdev, 0)`, `ioread32` the offset of
    interest, `iounmap` immediately, no DMA, no register writes.
    The 2026-05-08 non-perturbing verification result cited in
    memory `project_close_path_mitigated_2026_05_08` rests on
    this passive-capture invariant.
- **Community-signal entries** (per
  `docs/patch-improvements/_community-signal.md` line 135): **none
  tagged.** A4 is one of five patches (C1, E1, A1, A4, A5) with no
  community-signal cross-references. **Per M5 framing: this is
  expected** — A4 is addon-layer telemetry, project-local; the
  underlying close-path bug class is documented in
  `project_close_path_mitigated_2026_05_08` and is mitigated by
  C5 (`osHandleGpuLost` crash-safety) + A3 (recovery dispatch).
  A4 is the visibility surface; the bug class itself is not a
  surface upstream-bug reports tag. No external signal applies.

## v1 archaeology

The A4 surface consolidates **5 aorus-5090 ancestor patches** (per
binding grep — the binding suggested 3 starting recommendations:
0009 + 0020 + 0021; grep surfaced 5 actual ancestors when including
0029 + 0030, the canonical RM-side and UVM-side close-path DIAG
patches) plus 4 design / methodology docs into two new translation
units (the RM-side `nv-tb-egpu-close.{c,h}` and the UVM-side
`nv-tb-egpu-uvm.{c,h}`). The carve was applied 2026-05-22 in the
addon-recarve campaign (`project_addon_recarve_merged_2026_05_22`)
reshaping the legacy P4 cluster (close-path DIAG plus
investigation-grade dump) into A4's nominal-tier successor (dump
trimmed; `[DIAG]` tag retired in favour of `[CLOSE]` tag; the
dissolved P6 DIAG surface preserved in `patches/legacy/` as the
documented resurrection source).

- **Original design intent (close-path observability as a stand-alone
  capability layer):**
  `patches/0029-Lever-M-recover-close-path-diag-and-AER-surface-completion.patch`
  patch-body lines 4-32 (the rationale block) — establishes the
  "diff state across the open->work->close->reopen lifecycle" goal
  as the load-bearing justification: the close-path was the silent
  half of the bus-loss bug class, and without per-site markers an
  operator could not localise the wedge. Lines 13-25 enumerate the
  four RM-side sites (close-entry, pre-stop, post-shutdown,
  close-exit) by function-anchor. A4 v1 preserves the four-site
  cluster + naming verbatim; source `nv-tb-egpu-close.c` lines
  4-34 (the file-level comment block) cites the rationale.
- **Original design intent (UVM as a separate observation point
  with its own lifecycle):**
  `patches/0030-Lever-M-recover-UVM-close-path-DIAG.patch`
  patch-body lines 4-50 — establishes the "answer 'is the
  close-path bug class still load-bearing on the current driver
  stack?' with empirical evidence" goal as the UVM-side
  justification. UVM has its own fd lifecycle (open/release on
  `/dev/nvidia-uvm`) that does NOT participate in `nvl->usage_count`;
  the UVM-side instrumentation has to maintain its own fd_count.
  Lines 21-32 specify the global `atomic_t aorus_uvm_fd_count` plus
  the LAST-CLOSE prediction semantics. A4 v1 preserves the
  global-atomic fd_count verbatim (renamed `aorus_uvm_fd_count` →
  `tb_egpu_uvm_fd_count`); source `nv-tb-egpu-uvm.c` lines 60-67
  (the static declaration + comment) cites the kernel-guarantee
  invariant ("release matches a prior successful open").
- **Constraints discovered (passive instrumentation invariant —
  ioremap + ioread32 + iounmap; no DMA, no register writes):**
  `patches/0029-Lever-M-recover-close-path-diag-and-AER-surface-completion.patch`
  lines 57-69 (the "Risk per feedback_observability_perturbs_bug"
  block) — establishes the passive-capture invariant explicitly:
  "Our DIAG dump uses ioremap+ioread32+iounmap (passive MMIO) and
  tb_egpu_dump_aer_trigger_event uses PCI config-space reads only
  (passive). Both helpers have been live since 2026-05-06 in 4
  open-side DIAG sites without observable perturbation." The
  invariant is preserved by A4 v1 verbatim — source
  `nv-tb-egpu-close.c` lines 25-29 cite it in the file-level
  comment ("Passive instrumentation only — ioremap+ioread32 +
  PCI config-space reads. No DMA, no register writes."). The
  memory `project_close_path_mitigated_2026_05_08` documents the
  n=3 close-path-probe runs that demonstrated A4's passive
  capture is non-perturbing (the bug-class mitigation result was
  measured WITH A4's instrumentation enabled — the instrumentation
  did not perturb the failure mode).
- **Constraints discovered (LAST-CLOSE prediction at each site is
  caller-determined, not function-internal):**
  `patches/0029-Lever-M-recover-close-path-diag-and-AER-surface-completion.patch`
  patch-body lines 13-25 (the per-site descriptions) — at
  `close-entry` and `pre-stop` the predicate is `usage_count ==
  1` (pre-decrement); at `post-shutdown` it's hard-coded `true`
  (because `nv_stop_device` is only entered on the last-close
  path); at `close-exit` it's `usage_count == 0` (post-decrement).
  Each call site computes its own predicate from the local
  `atomic64_read(&nvl->usage_count)` and passes the result to
  `tb_egpu_close_diag(nvl, site, usage_count, is_last_close)`.
  A4 v1 source `nv.c` (visible in the v1 diff at the four
  call-site blocks) preserves this verbatim. The function itself
  does not interpret `usage_count`; the caller's predicate is
  authoritative.
- **Constraints discovered (UVM fd_count atomic operations select
  the correct race-free LAST-CLOSE moment):**
  `patches/0030-Lever-M-recover-UVM-close-path-DIAG.patch`
  patch-body lines 33-48 — establishes the per-site atomic
  contract: `uvm_open` success path uses
  `atomic_inc_return(...)` (post-increment value); `uvm_release`
  exit path uses `atomic_dec_return(...)` (post-decrement value);
  the three middle sites (release-entry, pre-destroy,
  post-destroy) use `atomic_read(...)` and do not mutate. Lines
  45-48 cite the kernel-guarantee invariant: "fd count tracking
  is at uvm_open success path (only count opens that returned
  NV_OK — kernel only calls release for those) and at uvm_release
  exit path (kernel guarantees release matches a prior successful
  open). Mismatched counts impossible by construction." A4 v1
  source `nv-tb-egpu-uvm.c` lines 74-126 preserves the contract
  verbatim — the open's pre-increment-was-zero predicate (`prev
  == 0` after `atomic_inc_return - 1`) identifies the
  first-after-LAST-CLOSE open; the release-exit's
  post-decrement-is-zero predicate identifies the canonical
  LAST-CLOSE release.
- **Alternatives considered + rejected (preserve investigation-grade
  LnkSta + AER multi-register walk):**
  `docs/superpowers/specs/2026-05-22-addon-recarve-design.md` §
  "Observability audit" — the audit considered preserving the
  legacy P4 cluster's full LnkSta + AER walk per close-path site.
  Rejected because (1) production soak generates noise from
  per-site multi-register dumps — operationally the soak gate
  reads "did the close path complete healthily?" not "what was
  the full LnkSta/AER state at four sites?"; (2) the
  investigation-grade dump surface was concentrated in the old P6
  [DIAG] cluster, which the addon-recarve design dissolved in
  favour of per-patch nominal telemetry; (3) if a future
  investigation needs the deeper walk, the legacy `0005` (and
  `0006`) patches are preserved in `patches/legacy/` as
  resurrection sources. v1 carries the trimmed nominal-tier
  scope; v2 review's Design choices § documents the rejection
  explicitly.
- **Alternatives considered + rejected (hardcoded BDF pdev lookup
  vs `nv_linux_devices` walk):**
  `patches/0030-Lever-M-recover-UVM-close-path-DIAG.patch` lines
  29-31 (the "GPU pdev lookup" block) — the legacy patch used
  `pci_get_domain_bus_and_slot(0, 0x04, PCI_DEVFN(0,0))` —
  hardcoded to the project's eGPU topology. A4 v1 replaces this
  with `tb_egpu_get_gpu_pdev` walking `nv_linux_devices` under
  the global lock. **Generalisation rationale:** the BDF
  `0000:04:00.0` is project-specific; any deployment that moves
  the eGPU to a different slot (or runs on different hardware)
  would break the hardcoded lookup. The walk approach works on
  any PCI topology where `nvidia.ko` has bound a device. The
  single-pdev semantics are preserved (first entry in
  `nv_linux_devices`) — this is correct for the project's
  single-eGPU deployment shape (per
  `project_aorus_egpu_setup`) but would conflate in a
  hypothetical multi-device deployment (see v2-D1 +
  re-examination I2 below).
- **Alternatives considered + rejected (include-based vs
  EXPORT_SYMBOL_GPL cross-module surface):**
  v2 review's Design choices § documents the alternative:
  routing the UVM-side helpers through a shared header included
  by both modules' Kbuild. Rejected because the existing UVM
  Kbuild only adds `-I$(src)/nvidia-uvm`, and modifying it to
  include `-I$(src)/nvidia` would couple the build topology more
  tightly than necessary. `EXPORT_SYMBOL_GPL` + `extern` forward
  declarations is the standard kernel pattern for cross-module
  surfaces; A4 follows it. A4 v1 source `nv-tb-egpu-uvm.c` lines
  53-59 carries the forward declarations explicitly with a
  comment citing the build-topology rationale.
- **Forgotten / latent invariants surfaced (single-eGPU deployment
  shape is load-bearing for `tb_egpu_get_gpu_pdev` semantics):**
  v2 review's D1 § documents this as `nice-to-have` (multi-eGPU
  refactor deferred pending hardware reality — project ships
  single-eGPU). The aorus-5090 archaeology corroborates: every
  reliability investigation (P1-P6 phases, M-recover Phases 1-7,
  the H-test ledger) runs on the single-eGPU geometry per
  `project_aorus_egpu_setup`. The constraint is documented in
  A4's intent's fourth Requirement and Scope boundary; the
  deferred refactor is bounded by hardware availability.
- **Forgotten / latent invariants surfaced (UVM fd_count is global,
  not per-pdev — same architectural boundary as
  `tb_egpu_get_gpu_pdev`):**
  v2 review's D2 § documents this. UVM does not maintain a
  per-pdev fd table natively — UVM fds are global to the module.
  Adding per-pdev partitioning would be a substantial UVM refactor
  outside A4's scope. A4 v1 source `nv-tb-egpu-uvm.c` lines 60-67
  carries the single-atomic declaration explicitly. The
  architectural boundary mirrors D1's single-eGPU posture.
- **Forgotten / latent invariants surfaced (A4 holds the future
  option to call A1's `tb_egpu_dump_aer_trigger_event` with
  `out=NULL`):**
  A1 review's contract documentation (cited in A4's intent's
  Scope boundary § and v2-D3) — the discipline applies if A4
  were calling A1's full AER dump primitive. v1 does not exercise
  the option (the addon-recarve audit explicitly trimmed the dump
  call from A4); the option is preserved as future-proofing for
  a hypothetical close-path incident class that proves the AER
  walk is needed. The contract is forward-looking — no v1 code
  change.

## Improvements considered

### A4-close-path-telemetry-I1 — A4 vs A2-latch guardrail status (the audit pre-warn from A3 Task 11)

- **Lens:** sovereignty (cross-cluster coupling) / duty
- **Current state:** A3's audit-reviewer for Task 11 flagged a
  pre-warn for A4's Task 12 review: "A4's reviewer should NOT add
  cross-cluster edits at A2's detection latch; if A4 needs
  telemetry there, hoist BOTH A3's qwd-detect call AND A4's new
  call into A2 in ONE cascade-triggering change — this would fire
  I1's first revisit trigger." Per A3 catalog I1's resolution: if
  a third addon needs to write at A2's detection latch site,
  hoist BOTH A3's `qwd-detect` call AND any new addon call INTO
  A2 (option (a) from A3's I1 survey) — invalidating A2's
  zero-delta sentinel and cascading rebases through A3-A5. A4 v1
  **must be verified against this guardrail.**
- **Proposed state:** verify by inspection of A4 v1's
  fork-branch diff whether A4 patches into A2's TU
  (`kernel-open/nvidia/nv-tb-egpu-qwd.c`).
- **Value:** confirms (or denies) the guardrail's status. If
  held, A4 v1 is in the clear and the cross-cluster invariant
  flagged by the recarve campaign is preserved. If tripped, the
  revisit-trigger condition fires and a cascade-triggering hoist
  is required.
- **Cost:** zero (verification only — single grep + diff).
- **Verification mode:** B (`git diff 595.71.05..a4-close-path-telemetry
  --name-only` and `git diff f57a38b2..a4-close-path-telemetry
  --name-only` to surface A4-specific deltas).
- **Intent impact:** none.
- **Triage decision:** **reject** (verification passes — guardrail
  HELD)
- **Resolution:** **rejected — guardrail HELD.** Evidence:
  - `git diff 595.71.05..a4-close-path-telemetry --name-only`
    enumerates 28 files (the cumulative C+E+A stack). Of these,
    `kernel-open/nvidia/nv-tb-egpu-qwd.c` is the A2 TU — A4
    inherits A2's patch (A4 sits on top of A3 on top of A2) but
    does NOT add its own delta to the file.
  - `git diff f57a38b2..a4-close-path-telemetry --name-only`
    (the A4-specific delta over A3's tip) enumerates exactly 8
    files: `nv.c`, `nv-tb-egpu-close.c`, `nv-tb-egpu-close.h`,
    `nvidia-sources.Kbuild`, `nvidia-uvm/uvm.c`,
    `nv-tb-egpu-uvm.c`, `nv-tb-egpu-uvm.h`,
    `nvidia-uvm-sources.Kbuild`. **None of these is A2's TU.**
    A4's incremental hunks touch four files (the four new files)
    + four additive hunks against vanilla (`nv.c` close-path
    blocks; `nvidia-sources.Kbuild` source-list row;
    `uvm.c` UVM-lifecycle blocks; `nvidia-uvm-sources.Kbuild`
    source-list row). **Zero cross-cluster edits at A2's
    detection latch.**
  - **Architectural state after A4 v1:** A2 owns the AER snapshot
    storage struct. A3 patches the
    `tb_egpu_dump_aer_trigger_event(..., "qwd-detect", ...)` call
    INTO A2's TU (cross-cluster regression deferred — A3 I1's
    option (d)). A4 does NOT touch A2's TU. The "third addon
    needs to write at A2's detection latch" revisit-trigger
    condition is **NOT fired** by A4 v1. A3's I1 deferral stands;
    A2's zero-delta sentinel stands; the cascade-triggering hoist
    is NOT required.
  - **Implication for A5 (Task 13):** the guardrail remains held
    going into A5's review. If A5 needs telemetry at A2's
    detection latch, the trigger condition fires there. As of A4,
    the state of the addon stack vs A2's TU is:
    - A3 patches in 1 line at the qwd-detect latch (the
      deferred cross-cluster regression).
    - A4 adds 0 lines to A2's TU.
    - A5 expected by the recarve design to add 0 lines to A2's
      TU (A5 is version + reserved-symbol declaration; no
      observability surface at A2's latch).
  - **No catalog file delta required beyond this documentation
    entry.** A3 catalog I1's revisit trigger is preserved
    unchanged; A4 v1's clean architectural posture is the
    documented evidence that the trigger has not been fired.

### A4-close-path-telemetry-I2 — Re-examine D1: `tb_egpu_get_gpu_pdev` single-pdev semantics (multi-eGPU deferred)

- **Lens:** robustness (multi-device deployment posture) / sovereignty
  (single-eGPU deployment-shape invariant)
- **Current state:** v2 review's D1 documents `tb_egpu_get_gpu_pdev`
  as walking `nv_linux_devices` under the global lock and returning
  the first entry's pdev refcounted. In a hypothetical multi-eGPU
  deployment, the UVM helper would attribute every UVM close-path
  snapshot to whichever pdev happens to be first in the list — not
  to the pdev whose fd is actually closing. The project ships
  single-eGPU only (per `project_aorus_egpu_setup`); v2-D1
  classified this as `nice-to-have` (multi-eGPU deferred pending
  hardware reality).
- **Proposed state:** confirm via aorus archaeology that the
  single-eGPU deployment shape is the documented design constraint
  (not a missed in-driver lever); confirm the deferral disposition.
- **Value:** confirms v2-D1's resolution unchanged. A reader asking
  "why does `tb_egpu_get_gpu_pdev` not partition by fd?" can answer
  "because UVM does not maintain a per-pdev fd table natively, and
  the project ships single-eGPU per
  `project_aorus_egpu_setup`."
- **Cost:** zero (verification only).
- **Verification mode:** A (aorus archaeology + project memory
  cross-check).
- **Intent impact:** none — already documented in v2 intent's
  fourth Requirement and Scope boundary.
- **Triage decision:** **reject** (verification passes — v2-D1
  upheld as deferred)
- **Resolution:** **upheld (deferred)** per v2-D1. **M6
  re-examination via aorus archaeology:**
  - `patches/0030-Lever-M-recover-UVM-close-path-DIAG.patch` lines
    29-31 (the legacy hardcoded `pci_get_domain_bus_and_slot(0,
    0x04, PCI_DEVFN(0,0))` lookup) — the LEGACY ancestor was
    even MORE single-eGPU-locked than A4 v1. A4's generalisation
    to `nv_linux_devices` walk works on any topology where
    `nvidia.ko` has bound a device; it preserves the single-pdev
    semantics (first entry) but no longer hardcodes the BDF. The
    refactor from BDF-hardcoded to list-walk is itself a step
    toward multi-device generalisation — future work would
    partition by fd (which requires UVM-internal refactor).
  - The project geometry memory
    `project_aorus_egpu_setup` documents the single-eGPU
    deployment shape as the project's invariant. Multi-eGPU is
    explicitly out of scope.
  - **Default-reject discipline applied** per the plan's
    bloat-budget guidance for A4 (telemetry-only, addon-layer):
    no current-deployment value; per-fd pdev lookup would require
    UVM-internal refactor outside A4's scope. **Explicit revisit
    trigger:** if the project ever supports multi-device
    deployments (currently out of scope), revisit. **No v3 code
    change; no intent edit.**

### A4-close-path-telemetry-I3 — Re-examine D2: UVM fd_count global vs per-pdev (multi-eGPU deferred)

- **Lens:** robustness (multi-device deployment posture)
- **Current state:** v2-D2 documents `tb_egpu_uvm_fd_count` as a
  module-private `static atomic_t` initialised to 0. The LAST-CLOSE
  predicate fires when the global count crosses zero, not when any
  specific pdev's UVM fds reach zero. In single-eGPU deployment
  this is correct (one pdev ↔ one fd_count); in multi-eGPU it
  would conflate across devices. v2-D2 classified this as
  `nice-to-have` (same architectural boundary as D1).
- **Proposed state:** confirm via aorus archaeology + UVM source
  inspection that per-pdev fd partitioning is not natively
  available in UVM; confirm the deferral disposition.
- **Value:** confirms v2-D2's resolution unchanged. A reader
  asking "why is the fd_count global?" can answer "because UVM
  does not maintain a per-pdev fd table natively, and the project
  ships single-eGPU."
- **Cost:** zero (verification only).
- **Verification mode:** A (aorus archaeology + UVM source
  inspection).
- **Intent impact:** none — already documented in v2 intent's third
  Requirement and Scope boundary.
- **Triage decision:** **reject** (verification passes — v2-D2
  upheld as deferred)
- **Resolution:** **upheld (deferred)** per v2-D2. **M6
  re-examination via aorus archaeology:**
  - `patches/0030-Lever-M-recover-UVM-close-path-DIAG.patch` lines
    23-24 ("Global atomic_t aorus_uvm_fd_count tracks
    /dev/nvidia-uvm fd count") — the legacy ancestor used the
    same single-global-atomic mechanism. A4 v1 preserves this
    verbatim (renamed only).
  - UVM source `kernel-open/nvidia-uvm/uvm.c:uvm_open` (vanilla
    lines 144-184) — vanilla UVM does not partition fds by pdev
    at open. The fd is a `/dev/nvidia-uvm` file descriptor;
    the per-pdev association is established later via ioctl
    (UVM_INITIALIZE), not at open. The "right" multi-pdev
    refactor would need UVM-internal restructuring (per-fd ptr
    to an `nv_linux_state_t`, plus per-nvl fd_count) — outside
    A4's telemetry scope.
  - **Default-reject discipline applied** per the plan's
    bloat-budget guidance for A4. **Explicit revisit trigger:**
    same as I2 — if the project ever supports multi-device
    deployments, revisit (probably as a single combined
    refactor with I2's pdev lookup). **No v3 code change; no
    intent edit.**

### A4-close-path-telemetry-I4 — Re-examine D3: A1 `out=NULL` discipline preserved as future-proofing

- **Lens:** invariant clarity (post-A1-I8 cascade verification)
- **Current state:** v2-D3 documented A1's `tb_egpu_dump_aer_trigger_event`
  contract: "A3's err_handler callbacks and A4's close-path events
  MUST pass `out=NULL` because they have no per-device snapshot to
  persist into". A4 v1 does NOT call A1's dump primitive at all;
  the discipline is moot for v1. The intent's Scope boundary
  explicitly notes the deferred capability.
- **Proposed state:** verify A4 v1 source carries zero references
  to `tb_egpu_dump_aer_trigger_event` (the dump primitive); confirm
  the contract is preserved as documented future-proofing for a
  hypothetical close-path incident class.
- **Value:** confirms v2-D3's resolution unchanged. The future-
  proofing contract is preserved without imposing v3 surface
  cost.
- **Cost:** zero (verification only).
- **Verification mode:** B (`grep -n 'tb_egpu_dump_aer_trigger_event'
  /root/open-gpu-kernel-modules/kernel-open/nvidia/nv-tb-egpu-close.{c,h}
  /root/open-gpu-kernel-modules/kernel-open/nvidia-uvm/nv-tb-egpu-uvm.{c,h}`
  returns zero matches).
- **Intent impact:** none — already documented in v2 intent's Scope
  boundary § ("A4 holds the option to call A1's dump with `out =
  NULL` if a future incident class proves the AER walk is needed
  at close-path; v1 does not exercise that option").
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected — verification passes.** Evidence:
  - Grep across A4's four source files for
    `tb_egpu_dump_aer_trigger_event` returns zero matches. A4 v1
    does NOT call A1's full AER dump primitive. The single A1
    surface A4 consumes is `tb_egpu_recover_read_wpr2(bar0_phys,
    &raw)` plus the `TB_EGPU_RECOVER_WPR2_VAL_MASK` constant
    (source `nv-tb-egpu-pcie.h` lines 56-57, consumed in
    `nv-tb-egpu-close.c` lines 105 and 117).
  - A1 catalog I8's DPC offset correction (the
    `PCI_EXP_DPC_CTL → PCI_EXP_DPC_STATUS` rename) does not
    propagate to A4 — A4 does not directly read DPC bits.
  - The contract is forward-looking: if A4 v4 or later adds a
    `tb_egpu_dump_aer_trigger_event` call for a specific
    close-path scenario, that call MUST pass `out=NULL` per A1's
    documented contract. **No v3 code change; the intent's Scope
    boundary already documents the deferred capability.**

### A4-close-path-telemetry-I5 — Re-examine D4: explicit no-must-fix sentinel + zero-delta confirmation

- **Lens:** invariant clarity (zero-delta sentinel verification)
- **Current state:** v2-D4 declared "v1's behaviour, telemetry, and
  surface match the v2 intent's normative shape" with all four
  intent Requirements satisfied and no must-fix or should-fix
  deltas. The frontmatter `v1-tip-sha == v2-tip-sha == 8d85e1db` in
  the review file is the machine-checkable signal.
- **Proposed state:** verify v1 source against the four intent
  Requirements and confirm the zero-delta sentinel holds across
  the post-recarve fork-branch tip remap from `8d85e1db` to
  `8d85e1db`.
- **Value:** confirms v2-D4's sentinel unchanged: A4 v1 satisfies
  the four Requirements with no v3-side defects. The fork-branch
  tip advance from `8d85e1db` to `8d85e1db` is a cascade-rebase
  artefact (the A1 I8 / addon-recarve cascade), not a v3
  improvement; the v3 sentinel
  `v1-tip-sha == v2-tip-sha == 8d85e1db` holds because v3 lands
  no code change on A4's fork branch.
- **Cost:** zero (verification only).
- **Verification mode:** A (Requirement-by-Requirement spot-check
  of v1 source against the intent's normative shape).
- **Intent impact:** none.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected — verification passes.** Evidence
  (Requirement-by-Requirement):
  - **Requirement 1** (one-line `[CLOSE]` marker at every RM-side
    site): v1 source `nv-tb-egpu-close.c` lines 134-140
    (`tb_egpu_close_diag`) emits `NV_DEV_PRINTF(NV_DBG_ERRORS,
    nv, "tb_egpu [CLOSE]: site=%-15s usage_count=%ld%s\n", ...)`.
    Four call sites in `nv.c` (close-entry, pre-stop,
    post-shutdown, close-exit) invoke the function with the
    documented `is_last_close` derivations. Satisfied.
  - **Requirement 2** (minimal PMC_BOOT_0 + WPR2 snapshot on
    last-close): v1 source `nv-tb-egpu-close.c` lines 73-119
    (`tb_egpu_close_diag_pdev`) emits the documented format
    string `"tb_egpu [CLOSE]: site=%-15s pdev=%s bar0=0x%llx
    PMC_BOOT_0=%s%08x WPR2=%s%08x wpr2_up:%s\n"` with the
    MAPFAIL sentinel for `ioremap`-failure / WPR2-rc-non-zero
    branches. `EXPORT_SYMBOL_GPL`'d. Satisfied.
  - **Requirement 3** (five UVM-side helpers + module-private
    fd_count): v1 source `nv-tb-egpu-uvm.c` lines 67 (the
    `static atomic_t tb_egpu_uvm_fd_count`), 74-78
    (`tb_egpu_uvm_emit` shared body), 80-126 (five public
    helpers each invoking `tb_egpu_uvm_emit` with the
    site-specific atomic operation). Satisfied.
  - **Requirement 4** (cross-module pdev lookup): v1 source
    `nv-tb-egpu-close.c` lines 36-51 (`tb_egpu_get_gpu_pdev`)
    walks `nv_linux_devices` under
    `LOCK_NV_LINUX_DEVICES()` / `UNLOCK_NV_LINUX_DEVICES()`,
    takes `pci_dev_get` on the first entry's `pci_dev`,
    releases the lock, returns the refcounted pointer.
    `EXPORT_SYMBOL_GPL`'d. Caller MUST `pci_dev_put`. Satisfied.
  - **Zero-delta sentinel:** the post-recarve fork-branch tip
    is `8d85e1db85675b6bec81dd63f4f63a950c258123`; v3 lands no
    code change; `v1-tip-sha == v2-tip-sha == 8d85e1db` holds.
    **No fork-branch follow-up commits are required for A4 v3.**

### A4-close-path-telemetry-I6 — Duty-boundary verification: telemetry-only invariant (no behavioural surface modification)

- **Lens:** duty (single-responsibility — telemetry only, no recovery /
  no watchdog / no err_handlers)
- **Current state:** A4's intent (Purpose + Scope boundary) declares
  the patch is telemetry-only: no recovery action triggered, no bus
  loss polling cadence, no PCIe/AER/WPR2 read primitive introduced,
  no sysfs counter, no `pci_error_handlers` callback, no module
  parameter, no `tb_egpu_dump_aer_trigger_event` call, no non-
  close-path lifecycle event instrumented, no UVM site below the
  five-site set. Verify v1 source against each of the eight non-goals.
- **Proposed state:** confirm v1 source carries zero behavioural
  surface modifications — i.e. no `schedule_work`, no register
  writes, no DMA, no `atomic_xchg` recovery latches, no sysfs
  surface, no err_handler dispatch.
- **Value:** confirms the telemetry-only invariant — the central
  duty claim A4 makes. If v1 inadvertently introduced any
  behavioural change, the duty would be violated.
- **Cost:** zero (verification only).
- **Verification mode:** B (multiple greps across A4's four source
  files for forbidden patterns).
- **Intent impact:** none.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected — verification passes.** Evidence
  (forbidden-pattern grep on A4's four source files —
  `nv-tb-egpu-close.{c,h}` + `nv-tb-egpu-uvm.{c,h}`):
  - **No register writes:** `grep -n 'iowrite\|pci_write_config\|writel\|writeb\|writew\|writeq'`
    returns zero matches. Only `ioread32` (read) is used.
  - **No DMA:** `grep -n 'dma_map\|dma_unmap\|dma_alloc\|dma_pool'`
    returns zero matches.
  - **No schedule_work / workqueue / kthread:**
    `grep -n 'schedule_work\|INIT_WORK\|queue_work\|kthread_create\|kthread_run\|kthread_stop'`
    returns zero matches. A4 has no work handler, no kthread,
    no deferred-execution surface.
  - **No `atomic_xchg` (recovery latch primitive):**
    `grep -n 'atomic_xchg'` returns zero matches. The atomic
    operations A4 uses are `atomic_inc_return` (uvm_open path),
    `atomic_dec_return` (uvm_release_exit path), and
    `atomic_read` (the three middle UVM sites) — all read-with-
    side-effect-or-read-only, no compare-and-swap latching.
  - **No sysfs surface:** `grep -n 'sysfs_create\|device_create_file\|DEVICE_ATTR\|kobj_attribute\|class_attribute'`
    returns zero matches. A4 has no sysfs counter, no module-
    parameter file, no device attribute.
  - **No `pci_error_handlers` callback registration or body:**
    `grep -n 'error_detected\|slot_reset\|resume\|mmio_enabled\|cor_error_detected\|pci_ers_result_t\|nv_pci_err_handlers'`
    returns zero matches. A4 does not register or fill any
    err_handler callback (those live in C4 + A3).
  - **No `tb_egpu_dump_aer_trigger_event` call:**
    `grep -n 'tb_egpu_dump_aer_trigger_event'` returns zero
    matches (per I4 above).
  - **No module parameter:**
    `grep -n 'module_param\|MODULE_PARM_DESC\|NVreg_'` returns
    zero matches. A4 has no runtime-disable knob.
  - **No `pci_reset_bus` or any reset primitive:**
    `grep -n 'pci_reset\|pcie_reset\|FLR\|secondary_bus_reset'`
    returns zero matches. A4 does not invoke any reset.
  - **No `kobject_uevent_env` or `uevent` surface:**
    `grep -n 'kobject_uevent\|uevent\|KOBJ_'` returns zero matches.
  - **Eight non-goals satisfied.** A4 v1 is telemetry-only by
    construction; the duty invariant holds. **No v3 code change.**

### A4-close-path-telemetry-I7 — Robustness verification: race-free LAST-CLOSE prediction in UVM helpers

- **Lens:** robustness (concurrent open/release race-freeness) /
  invariant clarity
- **Current state:** v1 source `nv-tb-egpu-uvm.c` lines 80-126 — the
  five UVM-side helpers compute their `is_last_close` predicate
  differently per site:
  - `tb_egpu_uvm_close_diag_at_open` (line 80) uses `prev =
    atomic_inc_return(&tb_egpu_uvm_fd_count) - 1; emit(...,
    prev+1, prev == 0)`. The pre-increment-was-zero predicate
    identifies the first-after-LAST-CLOSE open.
  - `tb_egpu_uvm_close_diag_at_release_entry` (line 92), `_at_pre_destroy`
    (line 99), `_at_post_destroy` (line 105) use
    `pre = atomic_read(&tb_egpu_uvm_fd_count); emit(..., pre,
    pre == 1)`. The pre-release-count-is-one predicate
    *predicts* this release will be LAST-CLOSE (pre-decrement
    view).
  - `tb_egpu_uvm_close_diag_at_release_exit` (line 111) uses
    `post = atomic_dec_return(&tb_egpu_uvm_fd_count); emit(...,
    post, post == 0)`. The post-decrement-is-zero predicate
    identifies the canonical LAST-CLOSE release (the
    authoritative one).
  Verify: in the presence of a concurrent open + release (e.g.
  another process opens `/dev/nvidia-uvm` while this one closes),
  do the three middle-site predicates remain accurate?
- **Proposed state:** confirm the prediction is conservative —
  i.e. that a "predicted LAST-CLOSE" at the three middle sites
  always matches the "actual LAST-CLOSE" at release-exit when no
  concurrent open/release occurs, and that concurrent opens
  cannot drive the predicate to a false positive (predicting
  LAST-CLOSE when none happens) or false negative (failing to
  predict LAST-CLOSE when one happens).
- **Value:** confirms the load-bearing race-freeness of the
  UVM-side prediction. A reader can reason about the predicate's
  correctness from the source alone.
- **Cost:** zero (verification only).
- **Verification mode:** A (atomics-semantics reasoning + source
  comment cross-check).
- **Intent impact:** none — v2 intent's third Requirement
  documents the per-site atomic operation choice.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected — verification passes.** Evidence:
  - **Authoritative LAST-CLOSE** is at `release-exit` (post-
    decrement count is 0). This is the only site whose predicate
    is unambiguously authoritative for the current release.
  - **At `release-entry` / `pre-destroy` / `post-destroy`,** the
    predicate `pre == 1` (where `pre = atomic_read(&fd_count)`)
    can be a false negative iff a concurrent
    `atomic_inc_return` from another open completes between
    `release_entry` and `release_exit` (the concurrent open
    bumps the count from 1 to 2; the release then decrements 2
    to 1; the post-decrement is NOT zero; the release is NOT
    LAST-CLOSE). This is the **correct outcome** — the release
    truly isn't LAST-CLOSE because another open intervened.
    The middle-site prediction was correctly conservative (it
    said "this might be LAST-CLOSE" based on the pre-decrement
    view, and the world changed before release-exit).
  - **A concurrent close** (another fd in another process
    racing this release) cannot race because the kernel
    serialises `release` per-fd: the open whose release is being
    counted is unique to this `uvm_release` invocation, so
    `pre == 1` at the middle sites means "one fd open and it's
    this one" iff no concurrent open happens.
  - **False-positive analysis:** the middle-site predicate `pre
    == 1` could fire at LAST-CLOSE moments that turn out not to
    be LAST-CLOSE (a concurrent open bumps the count before
    release-exit). The emitted log line carries the marker
    `(LAST-CLOSE)` but the authoritative release-exit will emit
    its own line WITHOUT the marker. Operators reading dmesg
    can disambiguate by the trailing site's `(LAST-CLOSE)`
    presence. **The asymmetry is documented in v2 intent's
    Telemetry contract** (the middle-site predicate is
    pre-decrement, the release-exit predicate is post-
    decrement); the asymmetry is intentional and
    operationally useful (capturing the "intent to be LAST-
    CLOSE" snapshot even if the world races).
  - **Hardware snapshot timing on false-positive:** if the
    middle-site predicate fires the snapshot at a moment that
    turns out not to be LAST-CLOSE, the snapshot captures the
    pre-decrement state (which is the "interesting" state for
    the close-path bug class). The snapshot is not wasted; it's
    captured per-site, and the operator gets multiple
    snapshots if multiple sites fire. **The intent's race
    semantics are correct as documented.**
  - **No v3 code change; the documentation is in v2 intent's
    Telemetry contract and the source comments at lines 60-67
    + 84-86 + 116-118 already cite the contract.**

### A4-close-path-telemetry-I8 — Robustness verification: MAPFAIL sentinel format alignment

- **Lens:** robustness (sentinel-vs-data ambiguity) / quality
  (operator-readability of the snapshot line)
- **Current state:** v1 source `nv-tb-egpu-close.c` line 90 declares
  `u32 pmc_boot_0 = 0xdeadbeefu;` (and `wpr2_raw = 0xdeadbeefu;`)
  as the initial sentinel values. On `ioremap` success, `pmc_ok =
  true` and `pmc_boot_0` is overwritten by `ioread32(map_pmc)`. On
  failure, `pmc_ok = false` and `pmc_boot_0` retains the
  `0xdeadbeefu` sentinel. The snapshot line at lines 111-118 uses
  `pmc_ok ? "0x" : "MAPFAIL:"` as the prefix for the value field.
  Same pattern for WPR2 (`wpr2_rc == 0` predicate). On failure
  the printed format is `"MAPFAIL:deadbeef"` (the literal
  `0xdeadbeef` hex of the unchanged sentinel) — verify this is
  the intentional sentinel and not an inadvertent collision with
  a plausible hardware value.
- **Proposed state:** confirm `0xdeadbeefu` is the documented
  sentinel for "this read did not happen"; confirm the operator
  can unambiguously distinguish the sentinel from a real
  PMC_BOOT_0 value (Blackwell GB202 PMC_BOOT_0 = `0x2a2_0_0_0_0`
  or similar GPU-ID pattern — NOT `0xdeadbeef`).
- **Value:** confirms the sentinel is unambiguous (the operator
  can read `MAPFAIL:deadbeef` and know the read failed even
  without the `MAPFAIL:` prefix). The `MAPFAIL:` prefix is
  belt-and-braces clarity.
- **Cost:** zero (verification only).
- **Verification mode:** A (sentinel-value documentation + GPU
  PMC_BOOT_0 known-value cross-check).
- **Intent impact:** none — v2 intent's second Requirement and
  Telemetry contract document the MAPFAIL format string explicitly.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected — verification passes.** Evidence:
  - `0xdeadbeef` is the long-standing kernel convention for
    "uninitialised / dead memory" sentinel. Blackwell PMC_BOOT_0
    values follow the NVIDIA GPU-architecture-ID pattern (high
    bits encode arch + chip ID); the GB202 family PMC_BOOT_0 is
    `0x2a02_xxxx` per the project's diagnostic dossiers. The
    sentinel `0xdeadbeef` is unambiguous against any plausible
    real value.
  - WPR2 raw values on the project's hardware (per
    `project_wpr2_mechanism_2026_05_06`) span `0x00000000`
    (cleared) and `0x07f4_a000` (normal-running). `0xdeadbeef`
    is unambiguous against either.
  - The `MAPFAIL:` prefix is the primary signal; the sentinel
    is the fallback. Defense-in-depth.
  - **No v3 code change.**

### A4-close-path-telemetry-I9 — Dedup verification: A4 vs A3 telemetry surface non-overlap

- **Lens:** dedup (cross-patch surface comparison)
- **Current state:** A3's recovery logs use the prefix
  `tb_egpu recover: ...` and the AER-dump primitive emits
  `tb_egpu_dump_aer_trigger_event` lines (per A1's surface). A4's
  close-path logs use the prefixes `tb_egpu [CLOSE]: site=...`
  (RM) and `tb_egpu UVM [CLOSE]: site=...` (UVM). A2's watchdog
  logs use the prefix `tb_egpu qwd: ...`. Verify no log-prefix
  collision and that the `site=` field disambiguates A4's
  surface from A3's recovery dumps (which use `tag=` per A1's
  AER-trigger-event API).
- **Proposed state:** confirm A4 v1 introduces no log-prefix
  collision with A2 / A3 / A1.
- **Value:** confirms the observability-tier surfaces are clean
  and operator-distinguishable.
- **Cost:** zero (verification only).
- **Verification mode:** B (grep across A4's source files for
  prefix conflicts).
- **Intent impact:** none.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected — verification passes.** Evidence:
  - A4's RM-side prefix: `"tb_egpu [CLOSE]: site=..."` —
    unique. The `site=` field distinguishes A4's close-path
    sites (close-entry, pre-stop, post-shutdown, close-exit)
    from A3's AER-trigger tags (error-handler, mmio-enabled,
    cor-error, qwd-detect) which use `tag=` not `site=` in A1's
    dump format.
  - A4's UVM-side prefix: `"tb_egpu UVM [CLOSE]: site=..."` —
    unique. The `UVM` discriminator separates A4's UVM-side
    surface from any RM-side surface.
  - A3's recovery prefix: `"tb_egpu recover: ..."` — no
    collision with A4. A2's watchdog prefix: `"tb_egpu qwd:
    ..."` — no collision with A4.
  - The hardware-snapshot line (RM-side last-close branch of
    `tb_egpu_close_diag_pdev`) also uses the
    `"tb_egpu [CLOSE]:"` prefix — same A4 surface, single
    semantic. No cross-contamination.
  - **No v3 code change; the surfaces are clean by construction.**

### A4-close-path-telemetry-I10 — Naming + sovereignty verification: `EXPORT_SYMBOL_GPL` semantics

- **Lens:** naming + sovereignty (cross-module ABI surface)
- **Current state:** A4 introduces exactly two `EXPORT_SYMBOL_GPL`
  symbols: `tb_egpu_get_gpu_pdev` (`nv-tb-egpu-close.c` line 51) and
  `tb_egpu_close_diag_pdev` (`nv-tb-egpu-close.c` line 119). These
  are the only `EXPORT_SYMBOL_GPL`s in the entire addon stack
  (A1-A5). Reason: the UVM-side helpers in `nvidia-uvm.ko` need
  to reach these symbols via the kernel symbol resolver; the UVM
  Kbuild only adds `-I$(src)/nvidia-uvm` so the nvidia/ header
  can't be included. Verify the export choice + the `_GPL` variant
  is correct (not `EXPORT_SYMBOL`).
- **Proposed state:** confirm the kernel convention for
  cross-module symbols in GPL-compatible modules; verify the
  `_GPL` variant is appropriate for the project's MIT-licensed
  source plus the kernel's GPL-only ABI policy.
- **Value:** confirms the export choice. A reader can verify
  that A4's cross-module surface follows kernel convention.
- **Cost:** zero (verification only).
- **Verification mode:** A (kernel-API documentation + project
  licensing cross-check).
- **Intent impact:** none — v2 intent's fourth Requirement
  documents the `EXPORT_SYMBOL_GPL` choice explicitly.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected — verification passes.** Evidence:
  - The kernel symbol-resolution path for cross-module calls is
    `EXPORT_SYMBOL(_GPL)` + `extern` forward declaration in the
    consumer. A4 uses both: `EXPORT_SYMBOL_GPL(tb_egpu_get_gpu_pdev)`
    and `EXPORT_SYMBOL_GPL(tb_egpu_close_diag_pdev)` on the
    producer side (`nv-tb-egpu-close.c`); `extern struct pci_dev
    *tb_egpu_get_gpu_pdev(void);` and `extern void
    tb_egpu_close_diag_pdev(struct pci_dev *pdev, const char
    *site);` on the consumer side (`nv-tb-egpu-uvm.c` lines
    58-59).
  - The `_GPL` variant restricts the symbol to GPL-compatible
    consumer modules. The project's source is MIT-licensed
    (compatible with kernel's GPL-only API expectations because
    MIT is GPL-compatible). The `_GPL` variant is the
    conservative correct choice; using plain `EXPORT_SYMBOL`
    would expose the symbol to non-GPL modules, which is not
    desirable for cross-module surfaces internal to one
    upstream project.
  - **No v3 code change; the convention is correct.**

### A4-close-path-telemetry-I11 — Prose-drift correction propagation (sub-cycle 2 self-confirmation pre-warn reconciliation)

- **Lens:** invariant clarity (cross-patch documentation
  consistency)
- **Current state:** sub-cycle 2's self-confirmation pre-warn
  (memory `project_patch_v2_reviews_executed_2026_05_23`):
  "A4 review claimed `CONFIG_NV_TB_EGPU` gated source-list rows;
  reality is documentation-only." The reconciliation was applied
  at commit `e8fb311` ("docs: reconcile cross-patch prose drift
  (C2/C4/C5 + A4/A5)"). Verify the correction is reflected in v3
  catalog references and that the intent + review both align with
  A5's "documentation-only in v1" stance.
- **Proposed state:** confirm the `e8fb311` commit applied the
  correction; confirm A4's intent's Scope boundary § lines 326-332
  and A4's review's interaction-contract bullet at lines 673-685
  carry the corrected prose.
- **Value:** confirms the cross-patch documentation consistency.
  A reader of A4's intent will see "A4's source-list rows are
  unconditional, matching every other addon source row. The
  toggle is reserved for a future per-source gating step"; this
  aligns with A5's intent's "documentation-only" stance.
- **Cost:** zero (verification only; correction already landed).
- **Verification mode:** B (`git show e8fb311 --stat` confirms
  the docs-only edit; `git log --oneline | grep A4` confirms no
  subsequent A4-touching commits that would re-introduce the
  drift).
- **Intent impact:** none — already applied at `e8fb311` before
  this v3 sweep.
- **Triage decision:** **reject** (verification passes —
  correction already in place)
- **Resolution:** **rejected — verification passes.** Evidence:
  - `git show e8fb311 -- docs/patch-intents/A4-close-path-telemetry.md`
    shows the intent's Scope boundary § was updated from "A4's
    source-list rows compiled out by `CONFIG_NV_TB_EGPU`" to
    "The reserved `CONFIG_NV_TB_EGPU` symbol declared by
    [[A5-version-and-toggles]] is documentation-only in v1 and
    does NOT gate A4's source-list rows or any A4-internal code
    path".
  - `git show e8fb311 -- docs/patch-reviews/A4-close-path-telemetry.md`
    shows the review's interaction-contract bullet was updated
    from "build-only — A5's `CONFIG_NV_TB_EGPU` master toggle
    gates A4's source-list rows" to "documentation-only — A5
    declares `CONFIG_NV_TB_EGPU` as a reserved master toggle
    and emits `-DCONFIG_NV_TB_EGPU` to every nvidia.ko object,
    but in v1 the symbol does NOT gate any source-list row".
  - `git log --oneline -- docs/patch-intents/A4-close-path-telemetry.md
    docs/patch-reviews/A4-close-path-telemetry.md | head -5`
    shows no A4-touching commits after `e8fb311` — the
    correction is durable.
  - **No v3 catalog delta required for this correction itself;
    this entry records the verification that the sub-cycle 2
    self-confirmation pre-warn was correctly reconciled.**

## Re-examination of sub-cycle 2 deferrals

The v2 review documented 4 deltas (D1, D2, D3, D4). All four are
re-examined as first-class entries above; the dispositions are:

- **A4-D1** (`tb_egpu_get_gpu_pdev` single-pdev semantics — multi-eGPU
  deferred) → v3 disposition: **upheld** (deferred). Evidence: the
  legacy `patches/0030` ancestor used a hardcoded BDF lookup; A4
  generalises to a `nv_linux_devices` walk but preserves single-pdev
  semantics. The single-eGPU deployment shape is documented in
  `project_aorus_egpu_setup`; per-fd pdev partitioning requires UVM-
  internal refactor outside A4's scope. See I2 above.
- **A4-D2** (UVM `fd_count` global vs per-pdev — multi-eGPU deferred)
  → v3 disposition: **upheld** (deferred). Evidence: UVM does not
  maintain a per-pdev fd table natively (vanilla
  `kernel-open/nvidia-uvm/uvm.c:uvm_open` line 144-184 confirms
  this); the legacy `patches/0030` ancestor used the same single-
  global-atomic mechanism. Same architectural boundary as D1; same
  revisit trigger. See I3 above.
- **A4-D3** (A1 `out=NULL` discipline documented as future-proofing —
  A4 does not call the dump in v1) → v3 disposition: **upheld**
  (out-of-scope). Evidence: grep confirms zero references to
  `tb_egpu_dump_aer_trigger_event` in A4's source files; the
  contract is preserved as forward-looking. See I4 above.
- **A4-D4** (no must-fix or should-fix deltas — explicit sentinel)
  → v3 disposition: **upheld** (sentinel holds). Evidence: all four
  intent Requirements verified satisfied against v1 source per
  Requirement-by-Requirement spot-check; the post-recarve fork-
  branch tip is `8d85e1db`; v3 lands no code change; zero-delta
  sentinel `v1-tip-sha == v2-tip-sha == 8d85e1db` holds. See I5
  above.

The sub-cycle 2 pre-warn (CONFIG_NV_TB_EGPU prose drift) was
reconciled at commit `e8fb311` before this v3 sweep; v3 records
the verification in I11.

## Improvements landed

(No improvements landed at the code-change tier. A4 v3 is a
zero-delta sentinel sweep: 11 improvement candidates considered, 0
landed, 11 rejected — 4 as sub-cycle 2 deferral re-examinations
upheld (I2/I3/I4/I5), 6 as verification-only confirmations of
existing invariants (I1/I6/I7/I8/I9/I10), 1 as confirmation that
a prior cross-patch reconciliation commit (`e8fb311`) is durable
(I11). The fork-branch tip
`v1-tip-sha == v2-tip-sha == 8d85e1db85675b6bec81dd63f4f63a950c258123`
holds.)

## Intent updates landed

(No intent updates landed in this v3 sweep. The intent and review
are durable from sub-cycle 2; the only docs-tier reconciliation
(`e8fb311` — CONFIG_NV_TB_EGPU prose drift) was applied before
this v3 sweep started.)

## Done gate

- [x] Every candidate improvement has explicit `Resolution:` (no
  `pending`).
- [x] All "land" improvements applied as fork-branch commits citing
  their `<id>-I<N>` IDs. _(N/A — zero land-tier improvements; I1-I11
  all reject / defer.)_
- [x] Substantive intent updates landed as precursor commits. _(N/A
  — zero intent updates in v3 sweep.)_
- [x] `tools/intent-lint.sh` passes. _(N/A for this catalog file;
  intent unchanged in v3 sweep; lint last validated at `e8fb311`.)_
- [x] `tools/validate-patchset.sh` passes (compile gate).
- [x] `bash tests/run.sh` green (34 ok / 0 failed).
- [x] Audit-reviewer subagent approved. _(Sub-cycle 3 audit-reviewer,
  ✅ ⚠️ APPROVED WITH NOTES — headline guardrail HELD verified
  directly: `git diff f57a38b2..a4-close-path-telemetry --name-only`
  returns 8 files (`nv.c`, `nv-tb-egpu-close.{c,h}`, `nvidia-sources.Kbuild`,
  `nvidia-uvm/uvm.c`, `nv-tb-egpu-uvm.{c,h}`, `nvidia-uvm-sources.Kbuild`)
  — `nv-tb-egpu-qwd.c` (A2's TU) is NOT among them. A3's I1
  revisit-trigger condition NOT fired. All 8 spot-checked aorus
  citations verbatim (5 ancestor patches + 3 design docs); M1+M2
  drops + adds sound (binding's `recovery-mechanism-findings.md`
  correctly dropped, 0029 + 0030 correctly added); duty boundary
  18-pattern grep re-run returns zero matches across A4's 4 source
  files — telemetry-only confirmed; M6 all 4 D-entries first-class
  re-examined; all 11 triages sound; gates re-ran green. Audit
  delta surfaced + fixed: the audit identified that A4 v2 review's
  frontmatter still carried the pre-A1-cascade SHA `f356c3b3` (the
  Claude-scrub remap table only covered the last hop, not the
  earlier A1-cascade hop). The pre-A1-cascade-to-current
  remap (`f356c3b3 → 8d85e1db`, `420fcaed → 9d62f2e6`,
  `f5216ee2 → f57a38b2`, `6d5e5e71 → cd1fe088`) was applied across
  all docs files in the same closeout commit; all 11 review-file
  frontmatters now reflect current post-scrub fork tips. Zero-delta
  sentinel approved at `8d85e1db85675b6bec81dd63f4f63a950c258123`.
  **Pre-warn for Task 13 (A5):** A5's reviewer should know A4 does
  NOT touch A2's TU, A4 does NOT add `pci_error_handlers`/sysfs/
  module parameter surfaces — if A5 introduces any of those, the
  duty boundary trips. A5 is expected per recarve to be version
  stamp + reserved `CONFIG_NV_TB_EGPU` toggle declaration only.)_

## Cross-references

- Intent file: `docs/patch-intents/A4-close-path-telemetry.md`
- Review file: `docs/patch-reviews/A4-close-path-telemetry.md`
- Manifest row: `patches/manifest` line for `A4-close-path-telemetry`
  (layer `addon`, source `fork:a4-close-path-telemetry`)
- Vanilla baseline:
  - `kernel-open/nvidia/nv.c:nv_stop_device` (line 2071-2099) +
    `nvidia_close_callback` (line 2157-2200) + `nv_close_device`
    (line 2127-2148)
  - `kernel-open/nvidia/nvidia-sources.Kbuild`
  - `kernel-open/nvidia-uvm/uvm.c:uvm_open` (line 144-184) +
    `uvm_release` (line 250-277)
  - `kernel-open/nvidia-uvm/nvidia-uvm-sources.Kbuild`
  - `kernel-open/nvidia/nv-tb-egpu-close.{c,h}` — NEW FILES (152 +
    88 lines, no vanilla counterpart)
  - `kernel-open/nvidia-uvm/nv-tb-egpu-uvm.{c,h}` — NEW FILES (129 +
    38 lines, no vanilla counterpart)
- Fork branch: `a4-close-path-telemetry` on
  `apnex/open-gpu-kernel-modules`, tip
  `8d85e1db85675b6bec81dd63f4f63a950c258123` (held; v3 sweep lands
  no code change).
- aorus-5090 ancestors:
  - `/root/aorus-5090-egpu/patches/0029-Lever-M-recover-close-path-diag-and-AER-surface-completion.patch`
  - `/root/aorus-5090-egpu/patches/0030-Lever-M-recover-UVM-close-path-DIAG.patch`
  - `/root/aorus-5090-egpu/patches/0009-uvm-destroy-diagnostic-markers-Lever-P-probe.patch`
  - `/root/aorus-5090-egpu/patches/0020-Phase-A-PCIe-LnkSta-AER-telemetry.patch` (context-only)
  - `/root/aorus-5090-egpu/patches/0021-G3-G-AER-Header-Log-capture.patch` (context-only)
- aorus-5090 docs:
  - `/root/aorus-5090-egpu/docs/lever-catalog.md` (lines 353-360 +
    454-467 — Lever M-recover code surface enumeration + Lever
    P-probe / P-comprehensive entry)
  - `/root/aorus-5090-egpu/docs/event-capture-methodology.md`
    (lines 180-237 — close-path + UVM close-path probe sections)
  - `/root/aorus-5090-egpu/docs/state-capture-methodology.md`
    (the passive-capture pattern A4 follows)
- Carve provenance:
  `docs/superpowers/specs/2026-05-22-addon-recarve-design.md`
  § "A4 close-path-telemetry — held to the nominal bar" +
  § "Observability audit".
- Upstream issue: n/a (addon-layer; not upstream-bound; per Rule 5
  `upstream-candidacy: n/a` for `layer: addon`). The close-path
  instrumentation policy is project-local and never upstream-bound.
- Community signal:
  `docs/patch-improvements/_community-signal.md` line 135 — A4 is
  one of five patches with no community-signal cross-references
  (`C1`, `E1`, `A1`, `A4`, `A5`).
- Related catalogs:
  - `docs/patch-improvements/A1-pcie-primitives.md` (A1's
    `tb_egpu_recover_read_wpr2` + `TB_EGPU_RECOVER_WPR2_VAL_MASK`
    consumed by A4)
  - `docs/patch-improvements/A2-bus-loss-watchdog.md` (A4 does NOT
    touch A2's TU; the audit pre-warn guardrail held)
  - `docs/patch-improvements/A3-recovery.md` (A4 sits alongside A3
    in the addon stack as an independent consumer of A1; A4's
    log surface is operationally distinct from A3's recovery
    surface — see I9)
  - `docs/patch-improvements/C4-err-handlers-scaffold.md` (the
    err_handlers registration A4 explicitly does NOT participate
    in)
  - `docs/patch-improvements/C5-crash-safety.md` (the close-path
    bug class A4 makes visible was mitigated by patch 0029 — the
    aorus-5090 ancestor of C5's `osHandleGpuLost` plus A3's
    recovery dispatch)
- Project memories:
  - `project_close_path_mitigated_2026_05_08` (the close-path bug
    class history — patch 0029 mitigated; A4 carries the
    nominal-tier observability surface)
  - `project_aorus_egpu_setup` (single-eGPU deployment shape — the
    invariant A4's `tb_egpu_get_gpu_pdev` + `tb_egpu_uvm_fd_count`
    rely on)
  - `project_addon_recarve_merged_2026_05_22` (the campaign that
    carved A4 from legacy P4 + retired P6 [DIAG] surface)
  - `project_patch_v2_reviews_executed_2026_05_23` (the sub-cycle 2
    self-confirmation pre-warn reconciled at `e8fb311` — see I11)
