---
id: A1-pcie-primitives
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: be1b56cf8ecc6d34bdfb8175d9ab184ef21d37bf
v2-tip-sha: fccf6a8588c0753c009e1fd3e6468be8d460b31d
status: accepted
intent-updates: [Requirement-2-DPC-offsets]
---

# A1-pcie-primitives — improvement triage

## Triangulation sources

- **Vanilla NVIDIA 595.71.05** — A1 introduces two wholly-new files
  (`kernel-open/nvidia/nv-tb-egpu-pcie.c` and `.h`) and a single
  additive line in `kernel-open/nvidia/nvidia-sources.Kbuild`. No
  vanilla translation unit is modified. The triangulation pivots to
  the kernel PCI helpers A1 wraps:
  - `<linux/pci.h>`: `pci_find_ext_capability`,
    `pci_read_config_dword`, `pci_read_config_word`,
    `pcie_capability_read_word`, `pci_upstream_bridge`,
    `pci_pcie_type`.
  - `<linux/pci_regs.h>` (kernel 7.0,
    `/usr/src/kernels/7.0.9-104.fc43.x86_64/include/uapi/linux/pci_regs.h`
    lines 1080-1097): the canonical DPC extended-capability layout
    — `PCI_EXP_DPC_CAP = 0x04`, `PCI_EXP_DPC_CTL = 0x06`,
    `PCI_EXP_DPC_STATUS = 0x08`. Load-bearing for the I8 finding
    below.
  - `<linux/io.h>`: `ioremap`, `ioread32`, `iounmap` — used by the
    WPR2 read primitive.
- **v2 intent:** `docs/patch-intents/A1-pcie-primitives.md` (status
  `reviewed`).
- **v2 review:** `docs/patch-reviews/A1-pcie-primitives.md` (status
  `accepted`; documents 4 deltas D1-D4 — D1 `_recover_` infix
  nice-to-have deferred, D2 `CONFIG_NV_TB_EGPU` source-list gate
  out-of-scope deferred to A5, D3 `pr_info` level rejected,
  D4 no must-fix sentinel).
- **aorus-5090 ancestor patches** (verified via grep against
  `tb_egpu_recover_*|wpr2|aer_trigger|0x88a828|walk_to_root_port`
  per M1+M2 — the plan binding's `patches/0010-0012` listing
  was misleading; those patches were correctly attributed to
  [[C5-crash-safety]] per Task 8). A1's actual ancestors are:
  - `patches/0017-Lever-M-recover-probe-time-WPR2-detection.patch`
    — introduced `tb_egpu_lever_m_check_wpr2_at_probe()` with the
    `ioremap`/`ioread32`/`iounmap` page-bounded WPR2 read pattern,
    the `0x88a828` offset constant, and the `0xfffffff0` `_VAL`
    mask (lines 31-43 macro definitions; lines 79-118
    function body). The renamed-and-extracted descendant in A1 is
    `tb_egpu_recover_read_wpr2()`.
  - `patches/0023-mode-b-telemetry-S1-S2-S3.patch` — the
    canonical ancestor for A1's PCIe-topology surface. This patch
    introduced the **exact** `walk_to_root_port` walker (lines
    236-247), `aorus_read_dpc_state` (lines 250-269),
    `aorus_read_aer_full` (lines 271-303),
    `tb_egpu_dump_aer_trigger_event` (lines 305-388), and the
    `struct tb_egpu_qwatchdog_aer_snapshot` 9-field layout (lines
    37-49). The de-brand from `aorus_*` to `tb_egpu_recover_*`
    and the struct rename `tb_egpu_qwatchdog_aer_snapshot` →
    `tb_egpu_qwd_aer_snapshot` happened in the 2026-05-12 P1-P6
    refactor (`project_patch_refactor_2026_05_12`).
  - `patches/0018-Lever-M-recover-diagnostic-telemetry.patch`
    (lines 61-94) — introduced the
    `tb_egpu_lever_m_diag_dump()` site-tagged dual-ioremap
    pattern (PMC_BOOT_0 + WPR2 reads at named DIAG sites). The
    parts that survived into A1 are the page-bounded ioremap
    pattern and the site-name conventions; the dump function
    itself was retired during the addon-recarve campaign.
  - `patches/0024-Lever-M-recover-Commit3-hardening.patch`
    (lines 1-40 header) — documents the post-storm sharpening of
    the WPR2 trigger from probe-time to post-`rm_init_adapter`-FAIL.
    A1 inherits the WPR2 read primitive; the trigger-site decision
    lives in [[A3-recovery]]. The 0024 header is the canonical
    reference for "what does the WPR2 value mean".
- **aorus-5090 docs consulted (M1+M2 verification):**
  - `docs/mode-b-telemetry-patch-design.md` lines 188-216
    (compile-error fix that surfaced the forward-declaration
    pattern A1 inherits) and lines 226-242 (lifetime + permanence
    table — `S1 helper aorus_dump_aer_trigger_event` flagged
    "Permanent — reactive, zero idle cost; canonical 'dump AER at
    fault time' function"). **Highly relevant** — this is the
    canonical design doc for A1's `tb_egpu_dump_aer_trigger_event`
    function, including the deliberate decision to make it the only
    logging surface among A1's primitives.
  - `docs/lever-M-recover-design.md` lines 80-98 (post-rmInit-FAIL
    trigger sharpening) and lines 119-155 (recovery-engagement
    state machine — the consumer A3, not A1 itself). Relevant for
    the WPR2 read primitive's call-site context; the read shape
    itself is A1, the policy is A3.
  - `docs/lever-Q-design.md` lines 169-340 — Q-watchdog design
    rationale. **Drop per M1 — Q-watchdog consumes A1's primitives
    but doesn't define them.** A1's surface is independent of
    Q-watchdog's polling semantics. The `last_aer` field embedded
    in the Q-watchdog struct is the only crossover and is covered
    by A1's struct-ownership documentation in `nv-tb-egpu-pcie.h`
    lines 26-46.
  - `docs/recovery-mechanism-findings.md` — covers bus-reset
    primitive evidence for Lever M-recover (the state machine).
    **Drop per M1** — not relevant to A1's pure-observability surface.
  - `docs/lever-catalog.md` lines 380-410 (entry for "Mode B
    telemetry S1/S2/S3" lever — the cross-reference to the
    `aorus_dump_aer_trigger_event` helper). **Relevant** for the
    historical lever-naming taxonomy.
- **Community-signal entries:** none tagged for A1 (per
  `_community-signal.md` line 135 "No findings tagged for: `C1`
  (Kbuild/version.mk), `E1` (eGPU detection), `A1` (PCIe primitives),
  `A4` (close-path telemetry), `A5` (version/toggles)"). Per M5,
  this is a clean "none tagged" finding: no upstream issue
  exercises A1's primitives because A1 is project-permanent addon
  infrastructure (not upstream-bound; never reaches an upstream
  reporter's code path). The community-signal absence is correct
  and load-bearing for A1's addon-layer scoping — the signals that
  motivate the Core layer's upstream filing don't bear on A1's
  internal foundation library.

## v1 archaeology

The A1 surface consolidates **2 aorus-5090 ancestor patches** into a
single foundation translation unit (with two related ancestors —
0018, 0024 — contributing context). The carve was applied 2026-05-22
in the addon-recarve campaign
(`project_addon_recarve_merged_2026_05_22`).

- **Original design intent (the walker, AER-full, DPC-state, dump
  helper):** `patches/0023-mode-b-telemetry-S1-S2-S3.patch` lines
  10-14 ("aorus_walk_to_root_port iterates pci_upstream_bridge
  until pci_pcie_type == PCI_EXP_TYPE_ROOT_PORT (bounded to 8
  hops), fixing the original 'one-hop' approach that landed on the
  AORUS hub upstream port (02:00.0) instead of the actual host
  root port (00:07.0)."). Lines 236-247 carry the exact
  8-hop-bounded walker that A1's `tb_egpu_recover_walk_to_root_port`
  ports verbatim with only the de-brand `aorus_*` →
  `tb_egpu_recover_*` and module-private `static` → file-scope
  applied. Per `docs/mode-b-telemetry-patch-design.md` lines
  226-228 the helper was flagged "Permanent — reactive, zero idle
  cost; canonical 'dump AER at fault time' function" — the
  permanence designation is what carried the function into A1
  through the addon-recarve.

- **Original design intent (WPR2 BAR0 page-bounded ioremap):**
  `patches/0017-Lever-M-recover-probe-time-WPR2-detection.patch`
  lines 79-117 (the original `tb_egpu_lever_m_check_wpr2_at_probe`
  function). The page-bounded ioremap pattern was deliberate per
  lines 99-103 ("We can't use nv->regs->map because at this point
  in nv_pci_probe (before RM init), NVIDIA's RM code hasn't yet
  ioremapped BAR0. Our own ioremap is safe and exclusive — we map
  for the duration of the read, then iounmap."). A1's
  `tb_egpu_recover_read_wpr2` preserves this design verbatim;
  the only delta from 0017 is the de-coupling of the value-mask
  + log-and-counter behavior (moved to consumer A3) from the raw
  read (kept in A1). 0017 lines 116-128 show the original mixed
  responsibility (read + mask + log + counter all in one
  function); A1's carve reduces this to read-only with raw value
  returned via `*raw_out`. The mask constant
  `TB_EGPU_RECOVER_WPR2_VAL_MASK = 0xfffffff0` is exposed in A1's
  header (lines 56-57) for consumer use without re-derivation —
  same `0xfffffff0` constant, renamed from
  `TB_EGPU_LEVER_M_WPR2_VAL_MASK` per the
  `tb_egpu_recover_*` namespace.

- **Original design intent (`tb_egpu_qwd_aer_snapshot` struct
  layout + consumer-owned lifetime):**
  `patches/0023-mode-b-telemetry-S1-S2-S3.patch` lines 37-49
  introduced the 9-field `struct tb_egpu_qwatchdog_aer_snapshot`
  embedded in `struct tb_egpu_qwatchdog` (lines 53-64). The
  consumer-owned struct lifetime — A1 only writes when the
  consumer passes a non-NULL `out` — is documented in
  `docs/mode-b-telemetry-patch-design.md` lines 195-207 (the
  forward-declaration pattern from the compile-error fix; the
  full struct definition lives in the consumer's header in
  the aorus era, moved to A1's header in the carve). A1's rename
  `qwatchdog` → `qwd` reflects the consumer renaming to
  `nv-tb-egpu-qwd.{c,h}` in the addon-recarve.

- **Constraints discovered (multi-bridge topology requires
  iterative walk):**
  `patches/0023-mode-b-telemetry-S1-S2-S3.patch` lines 13-17
  ("fixing the original 'one-hop' bug that landed on the AORUS
  hub upstream port (02:00.0) instead of the actual host root
  port (00:07.0)"). The first iteration of the walker used
  `pci_upstream_bridge(pdev)` once — landed on the AORUS hub
  upstream port instead of the host root port. The iterative
  walker with the 8-hop bound is the corrected shape. A1
  preserves this — the file-level comment in
  `nv-tb-egpu-pcie.c` lines 78-82 cites the exact constraint.

- **Constraints discovered (DPC capability layout):**
  `patches/0023-mode-b-telemetry-S1-S2-S3.patch` lines 261-265
  uses hardcoded offsets `+0x04` and `+0x06` for what the
  function names call "Ctl" and "Status". **This is incorrect
  against the kernel canonical layout** —
  `/usr/src/kernels/7.0.9-104.fc43.x86_64/include/uapi/linux/pci_regs.h`
  lines 1081-1096 declare `PCI_EXP_DPC_CAP = 0x04` (read-mostly
  hardware capability bits), `PCI_EXP_DPC_CTL = 0x06`
  (write-mostly enable bits), `PCI_EXP_DPC_STATUS = 0x08`
  (the trigger/interrupt status — the actually-interesting
  register). The aorus 0023 inheritance carries this offset
  error verbatim into A1 (`nv-tb-egpu-pcie.c` lines 122-125 +
  intent Requirement 2 lines 92-93). Surfaced as
  `A1-pcie-primitives-I8` below — **landed**, see Improvements
  landed section.

- **Constraints discovered (zero-output-first invariant):**
  `patches/0023-mode-b-telemetry-S1-S2-S3.patch` lines 256-260
  (DPC reader) and lines 280-286 (AER full reader) zero every
  output pointer **before** any NULL check, capability check, or
  early return. Rationale: callers that ignore the early-return
  signal (e.g. `*pos_out == 0` ⇒ "AER absent") still see
  all-zero outputs rather than stale stack contents. A1
  preserves this verbatim at lines 111-113 (DPC) and lines
  136-141 (AER full).

- **Alternatives considered + rejected (foundation-library
  carve vs. shared-file ownership in A2):**
  `docs/superpowers/specs/2026-05-22-addon-recarve-design.md`
  §"Carve approach" (binding context) — before the addon-recarve
  the primitives lived in A2's source file (then
  `nv-qwatchdog.c`); A3 and A4 reached into A2 for the shared
  register-read helpers. The carve into A1's own translation
  unit removes the cross-cluster coupling. v2 review §"Design
  choices" lines 282-294 captures the decision; A1's intent
  Provenance lines 287-292 records the carve geometry.

- **Alternatives considered + rejected (`pr_info` log level for
  trigger dump):**
  `docs/mode-b-telemetry-patch-design.md` lines 226-242 (lifetime
  + permanence table) implicitly places event-level
  classification in the consumer (the addon ALWAYS owns
  meaningful-event logging; A1 only owns the dump-block-on-demand
  surface). v2 review's D3 captured this scoping rule
  explicitly; v3 archaeology confirms (sub-cycle 2 deferral
  re-examination upheld below).

- **Forgotten / latent invariants surfaced (DPM = D0 forced via
  modprobe.d):** A1's file-level comment in `nv-tb-egpu-pcie.c`
  lines 22-26 documents the DPM assumption ("this driver runs
  with NVreg_DynamicPowerManagement=0 forced via etc/modprobe.d,
  plus udev keeps power/control=on and d3cold_allowed=0. The
  device stays in D0; all MMIO and PCI config reads in this
  file are safe by construction."). This is a latent invariant
  — if a future build flipped `NVreg_DynamicPowerManagement` ON
  or relaxed the udev rules, A1's `ioremap` of BAR0 would race
  against device-power transitions. The comment is the
  contract; verified preserved from the aorus ancestor 0023.

## Improvements considered

### A1-pcie-primitives-I1 — Re-examine D1: `tb_egpu_recover_*` infix rename to `tb_egpu_pcie_*` (atomic-sweep deferral)

- **Lens:** naming
- **Current state:** Four of five primitives carry the
  `tb_egpu_recover_*` infix:
  `tb_egpu_recover_read_wpr2`,
  `tb_egpu_recover_walk_to_root_port`,
  `tb_egpu_recover_read_dpc_state`,
  `tb_egpu_recover_read_aer_full`. Only
  `tb_egpu_dump_aer_trigger_event` lacks the infix.
- **Proposed state:** rename atomically to `tb_egpu_pcie_*` to
  track the new translation unit name `nv-tb-egpu-pcie.{c,h}`.
- **Value:** removes the legacy carry-over from the pre-carve
  `nv-lever-m-recover.c` file; the post-carve file is
  PCIe-primitives-not-recovery so the prefix should follow.
- **Cost:** touches every call site in A2/A3/A4 (none of which
  are reviewed yet); cascades into 3 follow-on review updates
  + 3 commits.
- **Verification mode:** A (code-reading vs. v2 review's D1
  rationale at `docs/patch-reviews/A1-pcie-primitives.md`
  lines 351-365).
- **Intent impact:** none (rename is mechanical; signature
  contracts unchanged).
- **Triage decision:** defer
- **Resolution:** deferred per spec — sub-cycle 3's task 9
  bindings explicitly state "the atomic-sweep rename is OUT OF
  SCOPE for sub-cycle 3 per the spec." Re-examined per M6;
  aorus archaeology surfaces no new evidence to flip the
  disposition. The infix is harmless for behavior (every symbol
  is uniquely prefixed `tb_egpu_*`). The rename remains
  available for Task 14's cross-patch consistency audit or a
  post-soak follow-on.

### A1-pcie-primitives-I2 — Re-examine D2: `CONFIG_NV_TB_EGPU` source-list gate on A1's foundation translation unit

- **Lens:** sovereignty (composition discipline)
- **Current state:**
  `kernel-open/nvidia/nvidia-sources.Kbuild` carries the
  unconditional line `NVIDIA_SOURCES += nvidia/nv-tb-egpu-pcie.c`
  — A1 compiles always.
- **Proposed state:** gate the line on `CONFIG_NV_TB_EGPU`.
- **Value:** would let a build with the C-series + E1 base
  but no addon behaviour elide A1's foundation entirely.
- **Cost:** the consumer addons A2/A3/A4 would need a NULL-stub
  fallback or matching gate; the foundation-elision discipline
  cascades.
- **Verification mode:** A (cross-patch consistency).
- **Intent impact:** none for A1 (gate decision lives in A5's
  toggle).
- **Triage decision:** defer
- **Resolution:** deferred per v2-D2 — out-of-scope; the
  addon-recarve design spec describes the toggle as a "master
  toggle" in A5 that gates the **consumer** call sites, not the
  foundation translation unit. A5's review (Task 13) owns the
  decision. v3 archaeology upholds: the aorus ancestors
  (`patches/0017`, `0023`) used a module-parameter
  (`NVreg_TbEgpuLeverMRecoverEnable`) gate at the **runtime**
  call site (lines 93-96 of 0017), never a source-list
  Kbuild-time gate. A1's foundation compiling unconditionally
  matches this precedent.

### A1-pcie-primitives-I3 — Re-examine D3: `pr_info` log level for trigger-event dump

- **Lens:** quality (telemetry richness)
- **Current state:** `tb_egpu_dump_aer_trigger_event` uses
  `pr_info` for all three log sites (gpu-NULL warning, main
  multi-line block, DPC follow-up).
- **Proposed state:** considered `pr_warn` because the dump
  fires only on not-normal events (watchdog detection,
  err_handler firing, close-path last-close transition).
- **Value:** would aid operator triage by making the dump
  block grep-anchored on `KERN_WARNING`.
- **Cost:** would cross the addon layering — the primitive
  would carry implicit "this is not-normal" semantics that
  belong to the consumer's event classification.
- **Verification mode:** A (code-reading vs. design doc).
- **Intent impact:** none.
- **Triage decision:** reject
- **Resolution:** rejected — re-examination upholds v2-D3.
  `docs/mode-b-telemetry-patch-design.md` lines 226-242
  (lifetime + permanence table) implicitly places event-level
  classification in the consumer. The `event=` tag in every log
  line IS the grep anchor; the consumer addons (A2/A3/A4) own
  the meaningful-event level classification and can call
  `pr_warn` / `pr_err` in their own preceding log lines, then
  reach for A1's dump for hardware-state detail.

### A1-pcie-primitives-I4 — Sovereignty re-verification: A1 lives in correct addon layer; no Core symbols re-defined

- **Lens:** sovereignty
- **Current state:** A1's primitives use the project-branded
  `tb_egpu_*` namespace (correct for addon layer per the
  bindings: "`tb_egpu_*` prefix is correct here. Unlike C5,
  A1 is NOT upstream-bound; the branding is part of its
  identity. Do NOT flag the prefix as a sovereignty issue.").
  Verification: no leak of C5/C4/C3 surface into A1's files.
- **Proposed state:** confirm no Core-symbol re-definition.
- **Value:** the addon layer is correctly project-branded;
  the foundation does not shadow Core helpers.
- **Cost:** zero (already correct in v1).
- **Verification mode:** B (grep evidence).
- **Intent impact:** none.
- **Triage decision:** reject
- **Resolution:** rejected — verification passes. Evidence:
  `grep -nE 'os_pci_is_disconnected|os_pci_set_disconnected|
  NV_GPU_BUS_DEAD|nv_pci_err_handlers' kernel-open/nvidia/
  nv-tb-egpu-pcie.{c,h}` returns zero matches at A1's v1 tip.
  A1 wraps kernel `pci_*` and `pcie_*` helpers directly
  (correct — those are the kernel's PCI helper surface, not
  C5's wrappers). C5's `os_pci_*` wrappers and `NV_GPU_*`
  macros live in `os-pci.c` + `nv-gpu-lost.h`; A1 lives in
  `nv-tb-egpu-pcie.{c,h}` — disjoint translation units, disjoint
  namespaces, complementary surfaces.

### A1-pcie-primitives-I5 — Duty boundary verification: A1 carries no watchdog logic, no recovery logic, no close-path policy

- **Lens:** duty (cross-patch dedup)
- **Current state:** A1 declares only:
  - `tb_egpu_recover_read_wpr2` (single passive register read)
  - `tb_egpu_recover_walk_to_root_port` (bounded PCIe walk)
  - `tb_egpu_recover_read_dpc_state` (single passive DPC read)
  - `tb_egpu_recover_read_aer_full` (single passive AER read)
  - `tb_egpu_dump_aer_trigger_event` (one `pr_info` block —
    the only logging surface).
- **Proposed state:** confirm no watchdog loop, no kthread, no
  policy decision, no `pci_reset_*`, no AER mask write, no
  `EXPORT_SYMBOL`.
- **Value:** confirms the duty boundary intent declares; any
  leak would force A2/A3/A4's responsibility into A1.
- **Cost:** zero (already correct in v1).
- **Verification mode:** B (`grep -E
  'kthread|EXPORT_SYMBOL|pci_reset_|pci_write_config_|
  schedule_work|workqueue' kernel-open/nvidia/
  nv-tb-egpu-pcie.{c,h}` returns zero matches).
- **Intent impact:** none.
- **Triage decision:** reject
- **Resolution:** rejected — verification passes. A1's source
  carries only `pci_*_read_*`, `pcie_capability_read_*`,
  `pci_upstream_bridge`, `pci_pcie_type`, `pci_find_ext_capability`,
  `ioremap`, `ioread32`, `iounmap`, `pr_info` — every API is
  read-side. The intent's Requirement 3 ("Driver SHALL keep the
  primitives pure-observability with no state mutation outside
  the caller's snapshot") at lines 170-185 of the intent is
  satisfied verbatim.

### A1-pcie-primitives-I6 — Robustness re-verification: NULL-tolerance on mandatory vs. optional output pointers

- **Lens:** robustness / invariant clarity
- **Current state:**
  - `tb_egpu_recover_read_wpr2(bar0_phys, raw_out)`: NULL-checks
    `raw_out` first (returns `-EINVAL`); zeroes `*raw_out` before
    further work.
  - `tb_egpu_recover_walk_to_root_port(start)`: NULL-tolerant
    via `while (p && hops < 8)`.
  - `tb_egpu_recover_read_dpc_state(pdev, present_out,
    dpc_status_out, dpc_ctl_out)`: dereferences `present_out`,
    `dpc_status_out`, `dpc_ctl_out` UNCONDITIONALLY at lines
    111-113 (no NULL check). The intent declares these as
    mandatory outputs.
  - `tb_egpu_recover_read_aer_full(pdev, pos_out, uesta, uemsk,
    uesvrt, cesta, cemsk, hdrlog, rootcmd, rootsta, errsrc)`:
    dereferences `pos_out`, `uesta`, `uemsk`, `uesvrt`, `cesta`,
    `cemsk` UNCONDITIONALLY at lines 136-137. NULL-tolerant for
    `hdrlog`, `rootcmd`, `rootsta`, `errsrc` (the four optional
    outputs per intent).
  - `tb_egpu_dump_aer_trigger_event(gpu_pdev, trigger, out)`:
    NULL-tolerant on every parameter (early-return on
    `gpu_pdev == NULL`; substitutes `"?"` for NULL `trigger`;
    skips snapshot writeback for NULL `out`).
- **Proposed state:** confirm the mandatory-vs-optional
  contract is correct and consistent across the 5 primitives.
- **Value:** mandatory outputs being NULL is a caller-contract
  violation that would crash deterministically (NULL pointer
  dereference at lines 111-113 / 136-137). The crash is the
  contract — better than silently degrading and masking the
  caller bug.
- **Cost:** zero (already correct in v1).
- **Verification mode:** A (code-reading + intent prose).
- **Intent impact:** none — the mandatory/optional distinction
  is implicit in the function signatures (mandatory outputs
  are unqualified in the prototype; optional outputs are noted
  in the intent's Requirement 2 prose at lines 96-101). Future
  audit (Task 14) may surface a refinement to make the
  mandatory-vs-optional partition explicit in the intent
  prose. For A1 v3, no change.
- **Triage decision:** reject
- **Resolution:** rejected — the contract is correct and
  consistent. A1's call sites are all internal to `nvidia.ko`
  (no public ABI), and the consumers (A2/A3/A4) pass
  pointers-to-stack-locals or pointers-into-per-device-state
  for the mandatory outputs — those are never NULL. The
  defensive NULL-check would be code bloat against a
  contract-violation that the kernel module's own internal
  callers can't reach.

### A1-pcie-primitives-I7 — Dedup re-verification: A1 vs. kernel pcie_aer_*  helpers

- **Lens:** dedup
- **Current state:** A1's `tb_egpu_recover_read_aer_full`
  manually reads the 10 AER status/mask/sever/cor/header
  registers via 10 `pci_read_config_dword` calls. Kernel
  `<linux/aer.h>` does NOT export a `pci_aer_read_full` helper;
  the kernel's AER routines are mostly write-side
  (`pci_aer_clear_*`, `pci_aer_mask_*`). The only public read
  helpers are `pci_aer_status` (kernel 6.x+, returns
  `cor_err_count`, `nonfatal_err_count`, `fatal_err_count`
  counters — different data than what A1 reads) and the
  per-register `pci_read_config_dword` calls A1 uses.
- **Proposed state:** confirm that A1's manual reads are not
  duplicating a kernel public helper.
- **Value:** if A1 were duplicating a kernel helper, replacing
  with the helper would reduce maintenance surface. Verifying
  the absence keeps the audit honest.
- **Cost:** zero.
- **Verification mode:** B (kernel header inspection).
- **Intent impact:** none.
- **Triage decision:** reject
- **Resolution:** rejected — no duplication. The kernel offers
  no per-register-read AER read helper; A1's 10
  `pci_read_config_dword` calls are the canonical pattern for
  capturing the full AER state. `<linux/aer.h>` in kernel 7.0
  enumerates `pci_aer_clear_nonfatal_status`,
  `pci_aer_clear_fatal_status`, `pci_aer_raw_clear_status`,
  `pci_enable_pcie_error_reporting` — write/clear helpers, not
  full-state read. A1's `read_aer_full` is foundation-library
  read code that doesn't have a kernel duplicate.

### A1-pcie-primitives-I8 — Robustness / correctness: DPC offset bug inherited from aorus 0023 — load CAP into ctl, CTL into status (must-fix)

- **Lens:** robustness (correctness against kernel canonical
  layout)
- **Current state:** `nv-tb-egpu-pcie.c` lines 122-125:
  ```c
  (void)pci_read_config_word(pdev, dpc_pos + 0x04, &ctl);
  (void)pci_read_config_word(pdev, dpc_pos + 0x06, &stat);
  *dpc_ctl_out = ctl;
  *dpc_status_out = stat;
  ```
  And intent Requirement 2 lines 92-93: "read `PCI_DPC_CTL`
  (`+0x04`) and `PCI_DPC_STATUS` (`+0x06`)". Per kernel
  `<linux/pci_regs.h>`
  (`/usr/src/kernels/7.0.9-104.fc43.x86_64/include/uapi/
  linux/pci_regs.h` lines 1081-1096):
  - `+0x04` = `PCI_EXP_DPC_CAP` (read-mostly hardware
    capability bits, e.g. RP_EXT, POISONED_TLP, SW_TRIGGER,
    DL_ACTIVE).
  - `+0x06` = `PCI_EXP_DPC_CTL` (write-mostly enable bits:
    EN_FATAL, EN_NONFATAL, INT_EN).
  - `+0x08` = `PCI_EXP_DPC_STATUS` (the actually-interesting
    trigger/interrupt status — TRIGGER, TRIGGER_RSN_*,
    INTERRUPT, RP_BUSY).
  A1 today reads `+0x04` (CAP) into `ctl` and `+0x06` (CTL)
  into `stat`. The dump log line at line 241 thus claims
  "DPC Status=0x... Ctl=0x..." but the values are actually
  CAP and CTL — Status (`+0x08`) is NEVER read. This is the
  aorus 0023 inheritance verbatim (0023 lines 264-265 carry
  the exact same offset error).
- **Proposed state:** replace the hardcoded offsets with the
  kernel canonical macros and read the correct registers:
  ```c
  (void)pci_read_config_word(pdev, dpc_pos + PCI_EXP_DPC_CTL,    &ctl);
  (void)pci_read_config_word(pdev, dpc_pos + PCI_EXP_DPC_STATUS, &stat);
  ```
  Update intent Requirement 2 prose to cite the correct
  offsets (`+0x06` for Ctl, `+0x08` for Status).
- **Value:** the dump's `DPC Status` field now reflects the
  actual DPC Status register — the trigger/interrupt status
  bits that incident analysis needs (TRIGGER bit, TRIGGER_RSN
  reason field, INTERRUPT bit, RP_BUSY bit). Without this fix
  the dump's labeled "DPC Status" value is the DPC Control
  register's enable bits — useful for verifying the DPC
  configuration but not for diagnosing whether DPC fired or
  why. The `out->dpc_status` field (consumed via A2's sysfs)
  is also affected: today reports CTL value; with fix reports
  STATUS value (strictly more informative for incident
  analysis).
- **Cost:** 2 changed lines in `.c`; 2 changed lines in
  intent prose; 1 changed comment line for the design intent.
  Cascade impact: A2/A3/A4 internal — none of their reviews
  are landed yet, so the value-semantics change in
  `out->dpc_status` propagates naturally as those reviews are
  done. No public ABI break.
- **Verification mode:** B (the canonical kernel
  `<linux/pci_regs.h>` lines 1081-1096 is the
  ground-truth oracle for the PCIe DPC extended-capability
  layout).
- **Intent impact:** refine Requirement #2 — the
  "`tb_egpu_recover_read_dpc_state`" bullet (lines 88-94 of
  intent) needs the offset constants and macro names
  corrected.
- **Triage decision:** land
- **Resolution:** landed as code commit `<sha-pending>` on
  fork branch `a1-pcie-primitives`. Intent precursor commit
  on injector branch updates the offsets in Requirement 2.
  See "Improvements landed" section below.

## Re-examination of sub-cycle 2 deferrals

- **v2-D1** — `tb_egpu_recover_*` infix rename → v3
  disposition: **upheld (deferred)**. Per sub-cycle 3 spec, the
  atomic-sweep rename is OUT OF SCOPE; the rename remains
  available for Task 14 or a post-soak follow-on. Aorus
  archaeology
  (`patches/0023-mode-b-telemetry-S1-S2-S3.patch` lines 245-247
  for the walker, lines 250-258 for the DPC reader, lines
  271-280 for the AER reader, lines 305-308 for the dump)
  confirms the original `aorus_*` namespace had no `_recover_`
  infix on any of these — the infix entered the namespace
  during the 2026-05-12 P1-P6 refactor's de-brand from
  `aorus_*` to `tb_egpu_*` plus the file rename to
  `nv-lever-m-recover.c`. The `_recover_` carry is therefore
  a 2-step legacy artifact (the file rename, then the
  carve out of that file). Surfaced as I1; deferred.
- **v2-D2** — `CONFIG_NV_TB_EGPU` source-list gate on A1 →
  v3 disposition: **upheld (deferred to A5)**. Aorus
  archaeology
  (`patches/0017-Lever-M-recover-probe-time-WPR2-detection.patch`
  lines 93-96, where the gate is a **runtime module parameter**
  `NVreg_TbEgpuLeverMRecoverEnable=0`, not a compile-time
  Kbuild gate) reinforces the design choice. A5 (Task 13) owns
  the master-toggle decision. Surfaced as I2; deferred.
- **v2-D3** — `pr_info` level for trigger dump → v3
  disposition: **upheld (rejected)**. Aorus archaeology
  (`docs/mode-b-telemetry-patch-design.md` lines 226-242)
  explicitly classifies the dump as "Permanent — reactive,
  zero idle cost" — the level decision belongs to the
  consumer's event classification, not to the foundation
  primitive. Surfaced as I3; rejected.
- **v2-D4** — "No must-fix deltas" → v3 disposition:
  **flipped to land (I8)**. Re-examination via the
  triangulated kernel `<linux/pci_regs.h>` v. aorus 0023
  ancestor surfaced the DPC offset bug — a real correctness
  defect (the labeled "DPC Status" field reports the DPC
  Control register's value, not Status). v2 review missed
  this because it triangulated against the aorus ancestor
  only (which carries the same bug verbatim) and did not
  cross-reference against the kernel canonical layout. v3's
  added kernel-header oracle catches it. Surfaced as I8;
  landed.

## Improvements landed

- **`A1-pcie-primitives-I8`** — DPC offset fix to kernel
  canonical layout (`PCI_EXP_DPC_CTL = +0x06`,
  `PCI_EXP_DPC_STATUS = +0x08`). Code commit on
  `a1-pcie-primitives` fork branch; intent precursor commit on
  `feature/v3-patch-improvements` injector branch.

## Intent updates landed

- **Requirement #2 DPC offset prose** — refine the
  "`tb_egpu_recover_read_dpc_state`" bullet (lines 88-94 of
  intent) to cite the correct kernel canonical offsets
  (`PCI_EXP_DPC_CTL` at `+0x06`, `PCI_EXP_DPC_STATUS` at
  `+0x08`). Precursor commit on injector branch.

## Done gate

- [x] Every candidate improvement has explicit `Resolution:`
  (no `pending`). _(8 candidates: 1 landed (I8), 2 deferred
  (I1, I2), 5 rejected (I3, I4, I5, I6, I7).)_
- [x] All "land" improvements applied as fork-branch commits
  citing their `<id>-I<N>` IDs. _(I8 landed as `fccf6a85` on
  `a1-pcie-primitives`.)_
- [x] Substantive intent updates landed as precursor commits.
  _(Requirement #2 DPC-offset prose landed as injector-branch
  commit `9339150`.)_
- [x] `tools/intent-lint.sh` passes.
- [x] `tools/validate-patchset.sh` passes.
- [x] `bash tests/run.sh` green. _(34 ok / 0 failed across
  compose / intent-lint / manifest-lib.)_
- [ ] Audit-reviewer subagent approved. _(Pending — this catalog
  is the audit-reviewer's input.)_

## Cross-references

- Intent file: `docs/patch-intents/A1-pcie-primitives.md`
- Review file: `docs/patch-reviews/A1-pcie-primitives.md`
- Manifest row: `patches/manifest` line for `A1-pcie-primitives`
  (layer `addon`, source `fork:a1-pcie-primitives`)
- Vanilla baseline:
  - `kernel-open/nvidia/nv-tb-egpu-pcie.c` — NEW FILE (no
    vanilla counterpart)
  - `kernel-open/nvidia/nv-tb-egpu-pcie.h` — NEW FILE (no
    vanilla counterpart)
  - `kernel-open/nvidia/nvidia-sources.Kbuild` — additive
    one-line source-list registration
- Fork branch: `a1-pcie-primitives` on
  `apnex/open-gpu-kernel-modules` (sits on top of
  `c5-crash-safety`)
- aorus-5090 ancestor patches (verified via grep, not the
  binding's misleading 0010-0012 listing):
  - `patches/0017-Lever-M-recover-probe-time-WPR2-detection.patch`
    (WPR2 read primitive)
  - `patches/0023-mode-b-telemetry-S1-S2-S3.patch` (walker,
    AER, DPC, dump, snapshot struct) — **canonical**
  - `patches/0018-Lever-M-recover-diagnostic-telemetry.patch`
    (page-bounded ioremap pattern + site-tagging conventions)
  - `patches/0024-Lever-M-recover-Commit3-hardening.patch`
    (WPR2 trigger-site sharpening — informs A3's call site,
    not A1's read primitive)
- aorus-5090 docs cited:
  - `docs/mode-b-telemetry-patch-design.md` lines 188-216
    (forward-declaration pattern, build notes) and lines
    226-242 (lifetime + permanence table — "Permanent" tag)
  - `docs/lever-M-recover-design.md` lines 80-98 +
    119-155 (consumer call-site context for the WPR2 read)
  - `docs/lever-catalog.md` lines 380-410 (Mode B
    telemetry lever entry)
- Upstream issue: n/a (addon-layer; not upstream-bound; per
  Rule 5 `upstream-candidacy: n/a` for `layer: addon`).
- Community signal: none tagged for A1 per
  `docs/patch-improvements/_community-signal.md` line 135.
- Related catalogs:
  `docs/patch-improvements/C5-crash-safety.md` (A1 vs. C5
  dedup verification — disjoint namespaces);
  `docs/patch-improvements/C4-err-handlers-scaffold.md` (C4
  registers err_handlers; A3 wires A1's dump into those
  callbacks — A1 itself does not).
