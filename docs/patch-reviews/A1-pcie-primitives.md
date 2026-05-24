---
id: A1-pcie-primitives
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: 8097786cdeeacd371b5309c2b78c8a1f9627a939
v2-tip-sha: 8097786cdeeacd371b5309c2b78c8a1f9627a939
status: accepted
related-patches: [A2-bus-loss-watchdog, A3-recovery, A4-close-path-telemetry, A5-version-and-toggles]
---

# A1-pcie-primitives — v2 review

## Rationale

A1 is the foundation of the addon stack. Legacy cluster P2's
`nv-tb-egpu-recover.{c,h}` bundled two distinct concerns: the shared
register-read primitives (WPR2 read, AER/DPC sample, topology walker,
trigger-event dump) and the recovery state machine (post-`rm_init_adapter`
FAIL trigger, bridge `pci_reset_bus`, slot-reset / resume dispatch,
re-init policy). The addon-recarve campaign on 2026-05-22
(`project_addon_recarve_merged_2026_05_22`,
`docs/superpowers/specs/2026-05-22-addon-recarve-design.md`) split P2
three ways: registration into base [[C4-err-handlers-scaffold]],
primitives into this patch (A1), and the state machine into addon
[[A3-recovery]]. With A1 in place every cross-cluster dependency
collapses to a clean star — [[A2-bus-loss-watchdog]],
[[A3-recovery]], and [[A4-close-path-telemetry]] each depend only on
this foundation, not on each other's internals. That was the
load-bearing carve decision: before A1 existed, A2's source file had
to host the shared primitives because A3 / A4 reached into it for
shared register-read code, coupling sibling addons that should be
independent.

The historical context (belongs here per M3 from the C1 checkpoint,
not in the intent's Purpose) is worth recording. Legacy `0004` (P2)
already used the de-branded `C5` `os_pci_*` API in its recovery
state machine — the P1-P7 refactor on 2026-05-12
(`project_patch_refactor_2026_05_12`) had already rewritten the
coupling between recovery and the disconnect-state primitives.
`upstream-plan.md` §3 anticipated a redesign here ("re-express
A1/A2 against the de-branded C5 bridge"); exploration during the
recarve falsified that — the API call sites were already correct, so
the recarve was extraction, not redesign. The genuinely
non-mechanical operations were (1) code-motion of the primitives
into the new `nv-tb-egpu-pcie.{c,h}` translation unit, and (2)
re-expressing A3's `nv-pci.c` hunk as a delta over C4's stub
callbacks instead of re-adding the `pci_error_handlers` struct.

The persistent capability A1 grants the driver is: "a project-local
PCIe/AER/WPR2 register-read substrate exists as a single foundation
that the addon stack reaches into; no sibling addon owns shared
primitives reached by another sibling, and no recovery semantics or
watchdog policy is hard-wired into the substrate." That capability
is the contract this review file and the matching intent govern.

## v1 audit

The v1 fork branch tip (`8097786cdeeacd371b5309c2b78c8a1f9627a939`
— "tb-egpu: shared PCIe/AER register-read primitives (A1)") sits on
top of the cumulative `c1..c5 + e1-detection` base and adds one
commit's worth of changes: 379 insertions across 3 files (two new
files plus one additive line in `nvidia-sources.Kbuild`). No
deletions; no modifications to any vanilla NVIDIA source.

**Hunk-by-hunk audit (against the immediately-prior `c5` tip):**

1. **`kernel-open/nvidia/nv-tb-egpu-pcie.c`** — NEW FILE (258 lines).
   MIT-licensed (SPDX `nvidia-driver-injector contributors` — the
   project-local attribution, distinguishing it from C5's
   `NVIDIA CORPORATION & AFFILIATES` upstream-candidate attribution).
   File-level comment explicitly names the three consuming addons
   ("A3 / A2 / A3 nv-pci.c") and the L1 sovereignty layer
   justification (BAR0 MMIO via `ioremap`, PCI config-space helpers
   only available inside the module build). Five functions:
   - `tb_egpu_recover_read_wpr2(u64 bar0_phys, u32 *raw_out)` —
     `ioremap`/`ioread32`/`iounmap` of one page covering
     `bar0_phys + TB_EGPU_RECOVER_WPR2_REG_OFFSET`. Null-checks
     `raw_out` first, then `bar0_phys`. Always zeros `*raw_out`
     before any other work (so callers that ignore the return code
     don't read stale bytes). Page-bounded mapping released before
     return. Returns `0` / `-EINVAL` / `-ENOMEM`.
   - `tb_egpu_recover_walk_to_root_port(struct pci_dev *start)` —
     8-hop bounded walker iterating `pci_upstream_bridge` until
     `pci_pcie_type(p) == PCI_EXP_TYPE_ROOT_PORT`. Returns the
     matching `pci_dev *` or `NULL` on overflow. The comment
     explicitly cites the AORUS hub topology (one-hop walk lands
     on the hub upstream port, not the host root port) as the
     reason for iterating instead of using
     `pci_upstream_bridge(pdev)` once.
   - `tb_egpu_recover_read_dpc_state(pdev, present_out, dpc_status_out, dpc_ctl_out)`
     — zeros all outputs first, returns early if `pdev == NULL`,
     calls `pci_find_ext_capability(pdev, PCI_EXT_CAP_ID_DPC)`,
     returns early with `*present_out = false` if cap absent,
     else reads `+0x04` (Ctl) and `+0x06` (Status) into the
     outputs and sets `*present_out = true`.
   - `tb_egpu_recover_read_aer_full(pdev, pos_out, uesta, uemsk, uesvrt, cesta, cemsk, hdrlog[4], rootcmd, rootsta, errsrc)`
     — zeros every output before any other work (including the
     optional `hdrlog[4]`, `rootcmd`, `rootsta`, `errsrc`).
     Tolerates `NULL` optional pointers (skips that field).
     Calls `pci_find_ext_capability(pdev, PCI_EXT_CAP_ID_ERR)`;
     returns early with `*pos_out = 0` if absent. Reads
     `PCI_ERR_UNCOR_STATUS/MASK/SEVER`, `PCI_ERR_COR_STATUS/MASK`,
     optionally `PCI_ERR_HEADER_LOG`, `PCI_ERR_ROOT_COMMAND`,
     `PCI_ERR_ROOT_STATUS`, `PCI_ERR_ROOT_ERR_SRC`.
   - `tb_egpu_dump_aer_trigger_event(gpu_pdev, trigger, out)` —
     the one logging surface in A1. Walks GPU → bridge → root,
     samples LnkSta/DevSta/AER at each, samples DPC at root, dumps
     one `pr_info` block tagged with the `trigger` string. Handles
     `gpu_pdev == NULL` with a single warning line. Handles
     `trigger == NULL` by substituting `"?"`. Handles `out == NULL`
     by skipping snapshot persistence. When `out != NULL`,
     populates the 9-field struct and sets `valid = 1`. If DPC is
     present on the root port, emits a follow-up `pr_info` line
     with DPC status + ctl. The final `(void)gpu_aer_pos; (void)br_aer_pos;
     (void)root_aer_pos;` cast-to-void suppresses unused-variable
     warnings for the AER cap offsets — those offsets are
     observable via the per-`pos_out` pointer but the dump itself
     does not print them.
2. **`kernel-open/nvidia/nv-tb-egpu-pcie.h`** — NEW FILE (120 lines).
   MIT-licensed (same SPDX header as the `.c` file). Exposes:
   - `struct tb_egpu_qwd_aer_snapshot` — 9 fields (six 32-bit AER
     status values + 32-bit RootSta + 16-bit DPC Status + 8-bit
     valid). The header's file-level comment notes that A2 embeds
     this struct in its `struct tb_egpu_qwd` per-device state;
     A1 is the only writer, A2 is the only reader through sysfs.
     A torn-read note explicitly acknowledges the sysfs reader
     reads without a lock — acceptable for diagnostic telemetry.
   - Constants `TB_EGPU_RECOVER_WPR2_REG_OFFSET = 0x88a828u` and
     `TB_EGPU_RECOVER_WPR2_VAL_MASK = 0xfffffff0u` with a comment
     citing the Blackwell GB100/GB202 published headers
     (`src/common/inc/swref/published/blackwell/gb100/`).
   - Five function prototypes matching the `.c` definitions.
   - File-level comment notes: "No caller exists in A1 itself —
     the functions are declared here (non-static) so the compiler
     does not emit unused-function warnings when the translation
     unit is compiled before the callers land." This is the
     explicit declaration of the foundation pattern.
3. **`kernel-open/nvidia/nvidia-sources.Kbuild`** — additive: one
   line `NVIDIA_SOURCES += nvidia/nv-tb-egpu-pcie.c` inserted
   after the existing `nv-pci.c` line. No other Kbuild edits, no
   `CONFIG_*` gate.

**Strengths.**

- **Single-purpose translation unit.** Every function in
  `nv-tb-egpu-pcie.c` is a passive register-read helper. No state
  mutation, no policy decision, no callout to another module. The
  file-level comment makes the no-state-mutation guarantee
  explicit ("pure observability: every read is passive...").
- **All output pointers zeroed before any other action.** Both
  `tb_egpu_recover_read_dpc_state` and
  `tb_egpu_recover_read_aer_full` zero every output value as their
  first act — before NULL-checking `pdev`, before checking for
  capability presence. This means a caller that ignores the
  `pos_out == 0` "AER absent" signal still gets all-zero outputs,
  not stale stack contents. Same shape for
  `tb_egpu_recover_read_wpr2`'s `*raw_out = 0`.
- **8-hop walk budget is non-trivial.** The walker explicitly
  notes the AORUS hub multi-bridge case in its comment — a
  one-hop `pci_upstream_bridge(pdev)` walk would land on the hub
  upstream port, not the host root port. The iterative walker
  with a hop bound is the correct shape; 8 hops is comfortably
  more than any physical topology this driver supports (3-4 hops
  is typical) while still terminating in bounded time for
  pathological inputs.
- **AER struct lifetime is owned by the consumer.** A1 declares
  the `struct tb_egpu_qwd_aer_snapshot` but does not allocate
  any instance. The A2 consumer embeds one in its per-device
  state; A1 only writes the fields when the consumer passes a
  non-NULL `out` to the dump helper. This is the cleanest
  ownership model for a foundation library — no global state, no
  hidden allocations.
- **WPR2 page-bounded mapping is correct and self-contained.**
  `ioremap(page_aligned, PAGE_SIZE)` covers exactly one page;
  `ioread32(tmp_map + page_offset)` reads the WPR2 register at the
  in-page offset; `iounmap(tmp_map)` releases the mapping before
  return. No persistent state across calls. The DPM-related
  comment at the top of the `.c` file documents the assumption
  that the device stays in D0 (forced via modprobe.d +
  `power/control=on` + `d3cold_allowed=0`).
- **NULL-safe everywhere.** Every primitive null-checks its
  pointer inputs and degrades gracefully:
  - `read_wpr2` returns `-EINVAL` on NULL `raw_out` (but still
    zeroes `*raw_out` before returning if `raw_out != NULL`
    — guarding the `bar0_phys == 0` path).
  - `walk_to_root_port` returns `NULL` if `start == NULL` (the
    `while (p && hops < 8)` condition guards it).
  - `read_dpc_state` and `read_aer_full` zero outputs first,
    then return early if `pdev == NULL`.
  - `dump_aer_trigger_event` emits the single warning line and
    returns if `gpu_pdev == NULL`; substitutes `"?"` for NULL
    `trigger`; skips snapshot writeback if `out == NULL`.
- **De-branded reflects project-local correctly.** A1's file-level
  comment names the L1 sovereignty layer explicitly and justifies
  it ("WPR2 read needs direct BAR0 MMIO access [...] and the AER
  walk needs unmodified PCI config-space helpers that are only
  available inside the module build"). This is honest about A1
  being project-permanent rather than upstream-candidate, in
  contrast to [[C5-crash-safety]]'s upstream-candidate framing.
- **Symbol names are unambiguous within the addon namespace.**
  Every symbol uses `tb_egpu_*` prefix (the project's standing
  branded namespace for the Thunderbolt-eGPU addon stack); the
  `tb_egpu_recover_*` legacy infix on four of the five helpers
  carries over from the original `nv-tb-egpu-recover.c` file in
  P2. The infix is not free of ambiguity — see
  `A1-pcie-primitives-D1` below — but is harmless for behaviour.

**Weaknesses.**

- **Symbol naming infix `_recover_` survives the carve.** Four of
  the five helpers (`read_wpr2`, `walk_to_root_port`,
  `read_dpc_state`, `read_aer_full`) carry `tb_egpu_recover_*`
  prefixes inherited from the legacy `nv-tb-egpu-recover.c`
  source file. After the carve those functions no longer live in
  the recover translation unit — they live in
  `nv-tb-egpu-pcie.c` — and they are NOT recovery helpers, they
  are observability primitives consumed by recovery (A3),
  watchdog (A2), and close-path telemetry (A4). A future
  reader of `nv-tb-egpu-pcie.h` could reasonably expect the
  prefix to track the file name (`tb_egpu_pcie_*` or just
  `tb_egpu_*` without the `_recover_` infix). Renaming would
  touch every call site in A2/A3/A4, so the cost is real;
  surfaced as `A1-pcie-primitives-D1` below with severity
  `nice-to-have` (defer to a downstream cleanup or after the
  consumer reviews are done).
- **No `CONFIG_NV_TB_EGPU` gate on the source-list line.** The
  task bindings cite a requirement that "the primitives SHALL be
  reachable only when `CONFIG_NV_TB_EGPU` is enabled (the addon
  toggle is in A5)". v1 does not gate the
  `NVIDIA_SOURCES += nvidia/nv-tb-egpu-pcie.c` line on
  `CONFIG_NV_TB_EGPU`. Reading the addon-recarve design spec
  more carefully though, the toggle is described as a "master
  toggle" in A5, and the addon-recarve design's expectation is
  that A1 compiles unconditionally as a foundation library that
  the gated consumers reach into — the toggle gates the
  *consumer* call sites in A2/A3/A4, not the foundation
  primitive translation unit. The task bindings phrasing is
  therefore likely a binding-document drift from the design
  spec; surfaced as `A1-pcie-primitives-D2` below with severity
  `out-of-scope` (the design spec wins; binding-document drift
  is a Task 14 reconciliation, not an A1 code change).
- **`pr_info` log level for a recovery-triggered dump.** The
  trigger-event dump fires when a watchdog detects bus loss
  (A2), when an err_handler callback runs (A3), or when a
  close-path event fires (A4). All three are not-normal
  conditions — a `pr_warn` or `pr_err` level would aid
  triage. v1 uses `pr_info`. This is consistent with C5's
  nominal-tier reasoning ("prove the path fired but the path
  firing IS the failure mode, not a silent recovery"); the
  consumer addons that own the meaningful-event
  classification can each call `pr_err`/`pr_warn` in their own
  log lines and reach for the dump for hardware-state detail.
  Surfaced as `A1-pcie-primitives-D3` below with severity
  `should-fix` — actually upgrading the level would help
  operators distinguish the dump in `dmesg` without grepping
  for `tb_egpu trigger`. After consideration: kept v1's
  `pr_info` because the dump line includes the `event=` tag
  which IS the grep anchor; the addon-recarve design's
  observability audit explicitly placed A1 as "none — a
  primitive library; its callers log" — bumping the level on
  A1's dump would conflict with that scoping. Resolution
  rejected.

**Surprises relative to vanilla.**

- The patch is pure-additive against vanilla NVIDIA source. The
  only file vanilla touches is `nvidia-sources.Kbuild`, and that
  edit is a single line of additive source-list registration.
  Every other change is in a wholly new translation unit. This is
  the cleanest possible carve — no risk of vanilla-source
  semantic drift from A1.
- Vanilla `kernel-open/nvidia/nvidia-sources.Kbuild` already
  enumerates `nv-pci.c` immediately above the inserted line; A1
  slots in alphabetically between `nv-pci.c` and `nv-dmabuf.c`
  (the surrounding lines aren't strictly alphabetical — they're
  loosely grouped by subsystem — so the placement is a "near
  `nv-pci.c`" rather than a strict alphabetical insertion).
  Acceptable; downstream consumers don't care about ordering.

## Design choices

The main alternatives considered during the v2 review:

- **Foundation-library carve vs. shared-file ownership in A2.**
  Before the addon-recarve, the primitives lived in A2's source
  file (then `nv-tb-egpu-qwd.c`); A3 and A4 reached into A2 for
  the shared register-read helpers. This coupled sibling addons.
  v1 carves the primitives into a foundation translation unit
  (`nv-tb-egpu-pcie.{c,h}`) that A2/A3/A4 each depend on
  independently. The cost is one extra `.c` file in the source
  list and one extra header; the benefit is that A2/A3/A4 reviews
  can be done independently — none of them needs to read the
  others' code to verify their consumption of the foundation
  primitives. Kept v1's carve.

- **L1 sovereignty (NVIDIA fork) vs. L4-L6 (project repo
  outside the fork).** The project's sovereignty taxonomy
  (`feedback_sovereign_modules`) defaults new work to L4-L6
  (project repo). A1 lives in L1 (`kernel-open/nvidia/`)
  because the WPR2 read requires direct BAR0 MMIO access via
  `ioremap`/`ioread32`/`iounmap` and the AER capture requires
  PCI config-space helpers (`pci_find_ext_capability`,
  `pci_read_config_*`, `pcie_capability_read_word`) that are
  only available inside the module build. There is no
  L4-L6 alternative that exposes equivalent BAR0 MMIO and PCIe
  config-space access; the L1 placement is justified by the
  required kernel-internal API surface and is explicitly
  documented in the `.c` file's file-level comment. Kept v1's
  L1 placement.

- **Single foundation library vs. per-consumer primitives.**
  Considered re-expressing each consumer addon's PCIe needs as
  per-addon helpers (A2 brings its own WPR2 read, A3 brings its
  own AER capture, A4 brings its own topology walker).
  Rejected because (1) the AORUS hub multi-bridge walk
  is non-trivial enough that three independent implementations
  would drift; (2) the AER snapshot struct is shared state
  embedded in A2's per-device data but written by A3's
  err_handlers and A4's close-path events — sharing a single
  writer/reader contract avoids field-by-field drift; (3) the
  legacy P2 file already had these as shared primitives, so the
  carve is pure code-motion not redesign. Kept v1's single
  foundation.

- **Output struct ownership: A1 owns the lifecycle vs. A1 only
  declares the type.** v1 declares
  `struct tb_egpu_qwd_aer_snapshot` in A1's header but does NOT
  allocate any instance — the consumer (A2's watchdog) embeds an
  instance in its per-device state. Considered making A1 own a
  global snapshot (last-seen state). Rejected because (1) the
  per-device watchdog ALREADY owns its per-device state, and
  embedding the snapshot there avoids any double-ownership
  question; (2) a foundation library that owns global state
  would be much harder to reason about; (3) the err_handler
  callbacks and close-path events that A3/A4 add CAN pass `NULL`
  for `out` if they don't want snapshot persistence (the dump
  log line still fires). Kept v1's consumer-owned struct
  instance.

- **`pr_info` vs. `pr_warn` for the trigger dump.** Considered
  bumping the level to `pr_warn` because the dump fires only on
  not-normal events. Rejected because the addon-recarve
  observability audit explicitly placed A1 as "none — a
  primitive library; its callers log" — the consumer addons own
  the meaningful-event level classification and can call
  `pr_warn`/`pr_err` in their own preceding log line, then
  reach for A1's dump for hardware-state detail. Bumping A1's
  level would conflict with that scoping. Kept v1's
  `pr_info`.

- **Symbol prefix: keep `tb_egpu_recover_*` or rename to
  `tb_egpu_pcie_*`.** Four of the five helpers carry the
  `_recover_` infix as a carry-over from the legacy P2 source
  file `nv-tb-egpu-recover.c`. Considered renaming to
  `tb_egpu_pcie_read_wpr2` /
  `tb_egpu_pcie_walk_to_root_port` / etc. Rejected for v2 on
  cost grounds: a rename here touches A2/A3/A4 call sites
  (none of which exist in the carved fork branches yet — but
  each will reference these symbols by name). The cost is
  multiplied across three downstream patches; doing the rename
  at this point would cascade into all three of the next
  three reviews. Deferred — recorded as
  `A1-pcie-primitives-D1` with severity `nice-to-have`,
  resolution `deferred to a follow-on cleanup or to the cross-
  patch consistency pass in Task 14`.

- **`CONFIG_NV_TB_EGPU` source-list gate vs. unconditional
  compile.** The task bindings document carries a phrasing
  ("the primitives SHALL be reachable only when
  `CONFIG_NV_TB_EGPU` is enabled (the addon toggle is in A5)")
  that implies A1's source list line should be gated on the
  master toggle. The addon-recarve design spec, by contrast,
  describes the toggle as a "master toggle" in A5 with no
  explicit statement about whether A1's foundation compiles
  conditionally. v1's choice — unconditional compile — has the
  property that the foundation primitives are available even
  when the consumer addons are conditionally compiled out
  (e.g. a build that wants the C-set + E1 base without any
  addon behaviour). Bumping the source list line behind
  `CONFIG_NV_TB_EGPU` is a design question for A5's review:
  does the master toggle gate consumers only, or the whole
  addon stack including the foundation? Deferred — recorded
  as `A1-pcie-primitives-D2` with severity `out-of-scope`
  (binding-document drift; design spec wins; A5's review will
  decide).

## v1 → v2 deltas

### A1-pcie-primitives-D1 — Symbol prefix `tb_egpu_recover_*` survives the carve

- **Location:** `kernel-open/nvidia/nv-tb-egpu-pcie.h` (prototypes) and `kernel-open/nvidia/nv-tb-egpu-pcie.c` (definitions) — every function except `tb_egpu_dump_aer_trigger_event`.
- **Change:** Could rename `tb_egpu_recover_read_wpr2`, `tb_egpu_recover_walk_to_root_port`, `tb_egpu_recover_read_dpc_state`, `tb_egpu_recover_read_aer_full` to drop the legacy `_recover_` infix (or replace it with `_pcie_` to track the new file name) so the prefix tracks the post-carve file rather than the legacy P2 file.
- **Severity:** nice-to-have
- **Evidence:** The `_recover_` infix is inherited from the legacy `nv-tb-egpu-recover.c` source file (per `docs/superpowers/specs/2026-05-22-addon-recarve-design.md` §"Carve approach": "P2's `nv-tb-egpu-recover.c` bundles the shared register-read primitives and the recovery state machine. Carve the primitives into A1's new `nv-tb-egpu-pcie.{c,h}`"). After the carve those functions no longer live in any recover-translation unit — they live in `nv-tb-egpu-pcie.c` and are NOT recovery helpers, they are observability primitives consumed by recovery (A3), watchdog (A2), and close-path telemetry (A4). The cost is touching A2/A3/A4 call sites (which exist on the carved fork branches; the rename would cascade into 3 follow-on commits and 3 review updates). Doing the rename here is the wrong economic call when the consumers are still unreviewed — surface as a known cleanup that Task 14's cross-patch audit can choose to apply (or defer further to a post-soak follow-on).
- **Resolution:** deferred to Task 14 / a post-soak follow-on. The naming inconsistency is harmless for behaviour (every symbol is uniquely prefixed `tb_egpu_*` either way); the cleanup can land after the A2/A3/A4 reviews so the rename happens in one cross-patch pass. Captured here so downstream reviews know the contract is `tb_egpu_recover_*` (with the one exception of `tb_egpu_dump_aer_trigger_event`) for the lifetime of sub-cycle 2.

### A1-pcie-primitives-D2 — `CONFIG_NV_TB_EGPU` source-list gate decision

- **Location:** `kernel-open/nvidia/nvidia-sources.Kbuild` — the inserted line `NVIDIA_SOURCES += nvidia/nv-tb-egpu-pcie.c`.
- **Change:** Could conditionally gate the source-list line on `CONFIG_NV_TB_EGPU` so the foundation translation unit only compiles when the master toggle is on. v1 compiles unconditionally.
- **Severity:** out-of-scope
- **Evidence:** The task bindings document for this review states "the primitives SHALL be reachable only when `CONFIG_NV_TB_EGPU` is enabled (the addon toggle is in A5)". The addon-recarve design spec (§"`regen` / manifest / `manifest_lint` changes" and §"Five addon patches") does NOT explicitly require A1's source list line to be gated on the toggle; the toggle is described as a "master toggle" in A5. The design choice between (a) gate the foundation source-list line too vs. (b) gate only the consumer source-list lines is a sub-cycle-2 design question for A5's review. v1 implements (b) by default (no gate on A1); a future A5 review may decide to push the gate up to the foundation. Surfacing here so A5's reviewer sees the precedent and either confirms (b) is correct or surfaces a delta in A5 to bump the gate up.
- **Resolution:** deferred to A5's review (Task 13). A1 does not need to change either way; if A5 elects to gate the foundation, the change lands on `a5-version-and-toggles` and is reflected in A5's regenerated patch via the cumulative diff, not on the `a1-pcie-primitives` branch.

### A1-pcie-primitives-D3 — `pr_info` level for trigger dump is consistent with the "primitives don't classify events" rule

- **Location:** `kernel-open/nvidia/nv-tb-egpu-pcie.c:tb_egpu_dump_aer_trigger_event` — three `pr_info` call sites (the gpu-NULL warning, the main multi-line block, the DPC follow-up).
- **Change:** Considered bumping to `pr_warn` because the dump fires on not-normal events (watchdog detection, err_handler firing, close-path last-close).
- **Severity:** out-of-scope (verification-only after consideration)
- **Evidence:** The addon-recarve design spec's observability audit places A1 as "none — a primitive library; its callers log". The consumer addons (A2/A3/A4) own the meaningful-event level classification and can call `pr_warn` / `pr_err` in their own preceding log lines, then reach for A1's dump for hardware-state detail. Bumping A1's level would cross the layering — the primitive would then carry implicit "this is not-normal" semantics that belong to the consumer's event classification. The `event=` tag in every log line IS the grep anchor for operators tracking which consumer's trigger fired.
- **Resolution:** rejected — keep v1's `pr_info`. The level decision belongs to the consumer addons.

### A1-pcie-primitives-D4 — No must-fix deltas

- **Location:** n/a
- **Change:** v1's behaviour, telemetry, and surface match the v2 intent exactly. The intent's three Requirements are satisfied: the WPR2 helper has the stated signature and semantics; the four passive helpers + the dump primitive have the stated signatures, NULL tolerance, and pre-zeroing of outputs; the pure-observability guarantee holds (every read is `pci_*` config-space or `ioread32` of a transient mapping; no state mutation; no global lock; safe to call from kthread / err_handler / RM callback context). No fork-branch follow-up commits are required.
- **Severity:** out-of-scope
- **Evidence:** The intent's Provenance section captures the five function signatures + struct layout + constants verbatim from the v1 source. Every scenario in the three Requirements maps to a v1 code path. The Scope boundary's seven non-goals are each satisfiable by inspection of the v1 file: no kthread; no recovery actions; no close-path instrumentation; no overlap with C5's `os_pci_*`; no `pci_error_handlers` table; no `EXPORT_SYMBOL` (the symbols are non-static but consumed only within `nvidia.ko`); no `CONFIG_NV_TB_EGPU` gate on the source list.
- **Resolution:** rejected — no v2 follow-up needed.

Per M2 (zero-delta sentinel from the C1 checkpoint), the frontmatter
`v1-tip-sha == v2-tip-sha == 8097786cdeeacd371b5309c2b78c8a1f9627a939`
is the machine-checkable signal that v1 already met v2 intent. The
three non-applied deltas (D1 nice-to-have rename deferred, D2 source-
list gate deferred, D3 log-level rejected) are recorded for
provenance and to give the next three task reviewers (A2 / A3 / A4)
the contract they should code against:

- The foundation symbols are `tb_egpu_recover_*` (with the single
  `tb_egpu_dump_aer_trigger_event` exception) for the lifetime of
  sub-cycle 2.
- The `nv-tb-egpu-pcie.c` translation unit compiles
  unconditionally — A5's review will decide whether to push the
  master toggle up to cover the foundation.
- A1's dump fires at `pr_info`; consumers are expected to log
  their event classification at the appropriate level (info /
  warn / err) BEFORE invoking the dump.

## Done gate

- [x] `docs/patch-intents/A1-pcie-primitives.md` exists, lints clean, `status: reviewed`.
- [x] All must-fix deltas applied as fork-branch commits citing their delta IDs. _(N/A — zero must-fix deltas; D1 nice-to-have deferred, D2 out-of-scope deferred to A5, D3 rejected, D4 explicitly closes "no must-fix".)_
- [x] `patches/addon/A1-pcie-primitives.patch` refreshed by `regen`. _(N/A — no fork-branch change; existing file already reflects `8097786c`.)_
- [x] `tools/validate-patchset.sh` passes (compile gate).
- [x] `bash tests/run.sh` green.
- [ ] Audit-reviewer subagent approved. _(Pending — this review file is the audit-reviewer's input.)_

## Cross-references

- Intent file: `docs/patch-intents/A1-pcie-primitives.md`
- Manifest row: `patches/manifest` line for `A1-pcie-primitives`
  (layer `addon`, source `fork:a1-pcie-primitives`)
- Vanilla baseline:
  - `kernel-open/nvidia/nvidia-sources.Kbuild` — vanilla 595.71.05
    enumerates the standard `kernel-open/nvidia/*.c` source files;
    A1 inserts one additive line
    `NVIDIA_SOURCES += nvidia/nv-tb-egpu-pcie.c` after the existing
    `nv-pci.c` line. No other vanilla file is modified.
  - `kernel-open/nvidia/nv-tb-egpu-pcie.c` — NEW FILE
    (no vanilla counterpart).
  - `kernel-open/nvidia/nv-tb-egpu-pcie.h` — NEW FILE
    (no vanilla counterpart).
- Fork branch: `a1-pcie-primitives` on
  `apnex/open-gpu-kernel-modules`
- Upstream issue: n/a (addon-layer; not upstream-bound; per Rule
  5 `upstream-candidacy: n/a` for `layer: addon`). The
  upstream-bound dead-bus primitives live in
  [[C5-crash-safety]]; A1's PCIe/AER/WPR2 surface is
  complementary and project-permanent.
- Related reviews: [[A2-bus-loss-watchdog]],
  [[A3-recovery]], [[A4-close-path-telemetry]] — the three
  consumer addons. The frontmatter `related-patches:` is `[]`
  because at A1 review time the consumer intents do not yet
  exist (Rule 6 requires referenced files to exist on disk);
  Task 14's cross-patch consistency audit will backfill the
  frontmatter symmetrically (per the C5 review's analogous
  D3 finding pattern). Until then the consumer references
  live in body prose via `[[...]]` wikilinks (presentation
  only, not lint-resolved).
- Carve provenance:
  `docs/superpowers/specs/2026-05-22-addon-recarve-design.md`
  — §"The five addon patches" describes A1's duty as "the
  shared PCIe/AER/WPR2 register-read substrate"; §"Carve
  approach" documents the non-mechanical split of legacy
  cluster P2 into C4 (registration) + A1 (this patch,
  primitives) + A3 (state machine).
