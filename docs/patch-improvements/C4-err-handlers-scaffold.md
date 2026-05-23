---
id: C4-err-handlers-scaffold
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: 2f3c4896010198c722bc1fb14745ff5e780d17e5
v2-tip-sha: 2f3c4896010198c722bc1fb14745ff5e780d17e5
status: accepted
intent-updates: []
---

# C4-err-handlers-scaffold — improvement triage

## Triangulation sources

- **Vanilla NVIDIA 595.71.05:** `kernel-open/nvidia/nv-pci.c:nv_pci_driver`
  — the vanilla `struct pci_driver` definition at lines 2750-2764 of
  `git show 595.71.05:kernel-open/nvidia/nv-pci.c` carries
  `.name / .id_table / .probe / .remove / .shutdown /
  .driver_managed_dma (#ifdef) / .driver.pm (#ifdef CONFIG_PM) /
  .driver.probe_type = PROBE_FORCE_SYNCHRONOUS` and **does not set
  `.err_handler`**. The wrapper functions `nv_pci_register_driver()`
  and `nv_pci_unregister_driver()` (lines 2767-2785 of the vanilla
  file) are untouched by C4. A fresh `grep -nE
  'pci_error_handlers|err_handler|error_detected|slot_reset|mmio_enabled'
  kernel-open/nvidia/nv-pci.c` against the 595.71.05 tag returns zero
  matches — confirming the v2 intent's Provenance claim that the patch
  is purely additive against a no-AER-callbacks baseline.
- **Kernel reference (`linux-v6.19`):**
  `/root/linux-v6.19/include/linux/pci.h:921-941` — `struct
  pci_error_handlers` defines **seven** function pointers in v6.19:
  `error_detected`, `mmio_enabled`, `slot_reset`, `reset_prepare`,
  `reset_done`, `resume`, `cor_error_detected`. The v2 review's
  Design-choices bullet (review lines 302-308) characterised the
  struct as having "five fields (.error_detected, .mmio_enabled,
  .slot_reset, .reset_done, .resume)" — that count is **inaccurate**
  for current kernels (omits `reset_prepare` and `cor_error_detected`).
  v1 populates four; the unfilled fields (`reset_prepare`,
  `reset_done`, `cor_error_detected`) are tolerated by the kernel
  dispatch sites (per `report_*` NULL-checks documented below).
- **Kernel reference (`linux-v6.19`):**
  `/root/linux-v6.19/drivers/pci/pcie/err.c:65-86` —
  `report_error_detected()` is the dispatch site that drives the
  recovery walk. Reading the function shows three branches: (1) if
  `pci_dev_is_disconnected(dev)` already, vote DISCONNECT regardless;
  (2) if `pci_dev_set_io_state(dev, state)` fails, vote
  `PCI_ERS_RESULT_NONE` with "can't recover (state transition ...
  invalid)"; (3) if `!pdrv || !pdrv->err_handler ||
  !pdrv->err_handler->error_detected`, vote
  `PCI_ERS_RESULT_NO_AER_DRIVER` and log "can't recover (no
  error_detected callback)" (lines 65-78). The v2 intent's "recovery
  aborts with 'can't recover (no error_detected callback)'" prose
  (intent lines 18-24) matches the dmesg string verbatim; the vote
  the kernel casts is `NO_AER_DRIVER` not literally an "abort", but
  the operational consequence — recovery does not proceed for this
  device — is the same. Minor prose precision item, not a delta.
  Each subsequent `report_*` callback (mmio_enabled at lines 137-141,
  slot_reset at lines 156-161, resume at lines 175-181) NULL-checks
  the corresponding pointer and skips the device cleanly if absent —
  populating those fields is a **deliberate observability choice**,
  not a kernel-contract requirement.
- **Kernel reference (`linux-v6.19`):**
  `/root/linux-v6.19/drivers/pci/pcie/err.c:244-267` — the
  `pcie_do_recovery()` state machine. `mmio_enabled` is dispatched
  only when overall status is `CAN_RECOVER` (line 244); `slot_reset`
  is dispatched only when status reaches `NEED_RESET` (line 258).
  Since v1 never returns `NEED_RESET` from `error_detected`, the
  `slot_reset` callback is **unreachable via the kernel's AER state
  machine** in the current C4-only configuration; it is reachable
  only via explicit dispatch by downstream addon code (the
  `A3-recovery` pattern that aorus 0027 carved out — see
  archaeology below).
- **v2 intent:** `/root/nvidia-driver-injector/docs/patch-intents/C4-err-handlers-scaffold.md`
  (three Requirements: registration at module load + at-minimum 4
  callbacks; state-aware `.error_detected` result classification; the
  three remaining callbacks participate honestly with the stated
  PCI_ERS_RESULT_RECOVERED / DISCONNECT / no-op returns; six
  Scenarios; Scope boundary explicitly excludes a real
  reset-and-reinit `slot_reset`, eGPU-aware behaviour, NEED_RESET
  requests, module parameters, and AER mask manipulation).
- **v2 review:** `/root/nvidia-driver-injector/docs/patch-reviews/C4-err-handlers-scaffold.md`
  (single nice-to-have delta `D1` on the `default:` branch enum
  conflation, **deferred** — no must-fix; "v1's behaviour, telemetry,
  and surface match the v2 intent exactly" per `D2` Resolution lines
  344-350; the Design-choices section enumerates rejected
  alternatives — flat vs state-aware result, NEED_RESET vs
  DISCONNECT from the fatal branch, explicit-cases vs `default:`
  switch shape, stub bodies vs defer-to-later, 5-callback vs
  minimal-3, log-level distribution, helper-function vs designated
  initialiser, eager [[E1]]/[[C5]] frontmatter cross-refs).
- **Fork branch tip (v1 == v2):**
  `2f3c4896010198c722bc1fb14745ff5e780d17e5` on
  `apnex/open-gpu-kernel-modules` branch `c4-err-handlers-scaffold`.
  The branch is **built on top of `c3-gpu-lost-retry`** (review
  lines 187-193); the per-patch v1 hunks against the c3 base are
  exactly the two hunks reproduced in the v2 review's "v1 audit"
  section.
- **aorus-5090 ancestor patch:**
  `/root/aorus-5090-egpu/patches/0007-nv-pci-register-error-handlers-Lever-M-base.patch:1-77`
  — the original Lever M-base, landed 2026-05-04. Carved the same
  hunk-insertion point (`extern struct dev_pm_ops nv_pm_ops`,
  immediately before `struct pci_driver nv_pci_driver`) and the same
  table-pointer line addition (`.err_handler = &nv_pci_err_handlers`)
  but populated only **one** callback (`error_detected`) and
  returned `PCI_ERS_RESULT_DISCONNECT` **unconditionally** (no
  state-discrimination). Includes a log-once flag
  (`static int s_tb_egpu_lever_m_logged = 0`, lines 45-57) to gate
  AER-storm log spam at "one bright marker per failure event".
- **aorus-5090 docs (binding M1+M2 verification):**
  - `/root/aorus-5090-egpu/docs/lever-catalog.md:281-303` — Lever
    M-base catalogue entry. Confirms the M-base mechanism, the
    "kernel registers the struct, calls `error_detected` on AER fire,
    M-base returns DISCONNECT" contract, and the staging discipline
    (M-base = scaffold; M-recover = the recovery actions in patches
    0024+). **Relevant; kept.**
  - `/root/aorus-5090-egpu/docs/lever-catalog.md:307-396` — Lever
    M-recover catalogue entry. The "code surface" subsection
    (lines 353-359) is the **load-bearing archaeology for C4's
    duty-lens contract clarity**: patches 0024+0026+0027+0028 are
    explicitly the addon-layer recovery; 0027's existence ("work
    handler explicitly dispatches `aorus_lever_m_slot_reset` +
    `_slot_reset_resume` after `pci_reset_bus` (because
    `pci_reset_bus` does NOT go through `pci_error_handlers`; only
    AER does)") proves the registered callbacks are **consumed
    out-of-band by addon code** in addition to the AER state machine.
    **Relevant; kept.**
  - `/root/aorus-5090-egpu/docs/lever-M-recover-design.md:31-52` —
    "Why this is the right layer" + the line "Lever M-base (patch
    0007) registered the callback struct with a no-op
    `error_detected` returning DISCONNECT. M-recover replaces that
    with a real recovery implementation." Documents the explicit
    M-base → M-recover relationship that C4 ↔ A3 inherits in the C+E+A
    geometry. **Relevant; kept.**
  - `/root/aorus-5090-egpu/docs/lever-M-recover-design.md:196-258` —
    state-machine details for both boot-time and runtime AER paths.
    The runtime AER state machine (lines 246-262) shows the original
    M-recover design's `error_detected → NEED_RESET → slot_reset →
    resume` chain and how the runtime path REUSES the probe-time
    recovery code by triggering a re-probe (lines 394-399).
    **Relevant; kept (informs the "what C4 does NOT do" Scope
    boundary).**
  - `/root/aorus-5090-egpu/docs/lever-m-recover-commit3-handover.md:48-62`
    + `:119-130` — the H4 "smarter error_detected" truth table from
    the hardening design. The original Commit 3 storm bug
    (2026-05-06 16:14) demonstrated that `error_detected` returning
    `DISCONNECT` from within an active recovery (when `Enable=1`
    means the driver IS attempting to recover) interferes with the
    `pci_reset_bus` already in flight from the workqueue. The H4 fix
    is to return `NEED_RESET` (when attempts < Max + rate-limit OK)
    instead. **Relevant — informs the duty/scope boundary that A3
    owns the smarter-truth-table, C4 stays state-only-aware.
    Kept.**
  - `/root/aorus-5090-egpu/docs/recovery.md:1-194` — operator runbook.
    Six grep hits for AER (`AER` glossary line + `journalctl` grep
    pattern + freeze-fingerprint discussion at lines 14-44); zero
    design content for the C4 scaffold mechanism. **Not relevant for
    C4's design surface; dropped per M1+M2.** The binding listed it
    as "(handler registration role)"; the file does not actually
    document handler registration. (This mirrors the same drop
    decision the C2 catalog made.)
  - **Verified actually-consulted (M1+M2):** kept
    `lever-catalog.md:281-303` (M-base entry), `lever-catalog.md:307-396`
    (M-recover entry — the patches 0027 finding is load-bearing for
    C4's duty lens), `lever-M-recover-design.md:31-52` (the M-base →
    M-recover staging discipline), `lever-M-recover-design.md:196-258`
    (state-machine details for both paths),
    `lever-m-recover-commit3-handover.md:48-62` (H4 truth table
    informing C4's Scope boundary), and the ancestor patch
    `patches/0007-nv-pci-register-error-handlers-Lever-M-base.patch:1-77`.
    Dropped `recovery.md` per the verification above.
- **Community-signal entries:**
  `/root/nvidia-driver-injector/docs/patch-improvements/_community-signal.md:16-22`
  + `:128-131` — TOSUKUi 2026-05-02 #979 comment is **the strongest
  single C4 corroboration in the entire dataset**. Per M5
  error-code-vs-code-path distinction: TOSUKUi's `AER: can't recover
  (no error_detected callback)` (line 20) is the **verbatim kernel
  dmesg string emitted from `/root/linux-v6.19/drivers/pci/pcie/err.c:75`**
  — i.e. TOSUKUi's reproducer ran the **exact code path** that
  voted `PCI_ERS_RESULT_NO_AER_DRIVER` because vanilla nvidia.ko had
  no `pci_error_handlers` registered. This is **code-path commonality
  not just error-code commonality** for C4 specifically: the same
  err.c report_error_detected branch that would dispatch to v1's
  `nv_pci_error_detected` on the patched build is what literally
  fired-and-failed on TOSUKUi's vanilla build. (Contrast with the C2
  citation where the same TOSUKUi comment is error-code-only —
  TOSUKUi's AER mask was already clear so C2's unmask code path was
  not exercised.) The signal-strength for C4: TOSUKUi's reproducer
  on a DIFFERENT hardware platform (RTX PRO 6000 Blackwell + AMD-host
  + MINISFORUM DEG2 USB4) than the project's reference (RTX 5090 +
  Intel-host + AORUS TB4) demonstrates that the gap C4 fills is
  platform-class-general, not project-hardware-specific.

## v1 archaeology

What the aorus-5090 mining surfaced about C4's M-base → M-recover →
C4 carve-out:

- **Original design intent — kernel canonical pattern, not a
  bespoke fix.**
  `patches/0007-nv-pci-register-error-handlers-Lever-M-base.patch:9-20`
  + `lever-catalog.md:286-292` jointly document the genesis: the
  kernel's PCIe AER subsystem routes uncorrectable error events to
  the affected driver via `pci_driver.err_handler`; NVIDIA's open
  driver did not register this struct; AER messages from the eGPU
  on a degrading TB link got logged by pcieport but never reached
  the NVIDIA driver; "the driver continues issuing transactions to
  a broken bus, threads hang on register reads, and the host wedges
  silently with no diagnostic trace -- as observed in test
  lite-2026-05-04-142154 where AER fired three times within 1s yet
  zero NVRM output landed in dmesg before the freeze." The aorus
  author's framing is "every mature in-tree PCIe driver registers
  these callbacks" — kernel canonical, not bespoke. v2 intent
  carries that framing verbatim in the source-file block comment
  and the intent's Purpose.
- **Constraint discovered — log-once flag was an aorus-era
  necessity that the C+E+A geometry retires.**
  `patches/0007-nv-pci-register-error-handlers-Lever-M-base.patch:38-57`
  carried `static int s_tb_egpu_lever_m_logged = 0;` to log "one
  bright marker per failure event, not log spam" because AER
  notifications can fire many times in rapid succession during a
  storm. v1 C4 has NO log-once — `pci_info`/`pci_warn` fire every
  dispatch. The reason C4 can safely drop the log-once: storm
  control belongs to **addon-layer A3-recovery** (rate-limit gate
  H2 at `lever-m-recover-commit3-hardening-design.md:46-61` defers
  AER fires <30s apart; the storm prevention happens *before* the
  log line, not in the log decision). C4 as scaffold-only emits one
  honest log line per actual dispatch the kernel performs; if A3
  is loaded, the kernel won't dispatch storming fires in the first
  place. **No refinement candidate** — the carve-out is intentional
  and the operator-visibility argument (one info/warn per dispatch
  proves the path) outweighs the log-spam-during-unguarded-storm
  argument (which only fires when the addon is NOT loaded, i.e. on
  pure upstream).
- **Constraint discovered — `slot_reset` is unreachable via the
  kernel state machine in the C4-only configuration; A3 dispatches
  it explicitly out-of-band.**
  `lever-catalog.md:357` (the entry for patch 0027): "work handler
  explicitly dispatches `aorus_lever_m_slot_reset` +
  `_slot_reset_resume` after `pci_reset_bus` (because
  `pci_reset_bus` does NOT go through `pci_error_handlers`; only
  AER does — production WPR2-stuck recoveries come through the
  manual path, so without 0027 they never get success accounting
  or READY uevent)." This is the **load-bearing archaeological
  finding for C4's duty lens**: the C4 contract surface (4
  callbacks) is consumed by two distinct dispatchers — (a) the
  kernel's `pcie_do_recovery()` AER state machine
  (linux-v6.19 `drivers/pci/pcie/err.c:210-267`), and (b)
  explicit out-of-band calls from A3's work handler. Because v1
  C4's `.slot_reset` returns `PCI_ERS_RESULT_DISCONNECT`, A3 cannot
  simply call C4's stub; A3 must **override** the dispatch by
  calling its own `aorus_lever_m_slot_reset` (now `a3_slot_reset`
  under C+E+A naming). The contract gap: C4 promises a 4-callback
  table; A3 promises a *real* recovery action. The override pattern
  is intentional (C4 stays scaffold-only; A3 ships the addon
  payload) but the v2 intent does not explicitly call out that
  `.slot_reset` is unreachable without A3 explicitly overriding it
  — Scope boundary line 152-155 only says "for `struct
  pci_error_handlers` completeness". Worth considering as an
  invariant-clarity refinement (see I3 below).
- **Constraint discovered — H4 truth-table is addon territory, not
  scaffold.** `lever-m-recover-commit3-handover.md:48-62`
  documents the storm postmortem: the original Commit 3 had v1
  C4's behaviour (DISCONNECT on fatal, no recovery promise) AND
  the workqueue scheduling logic in the same `error_detected`
  callback. The storm bug was that DISCONNECT-from-error_detected
  conflicted with the in-flight `pci_reset_bus` from the workqueue.
  The H4 fix (handover lines 119-130 truth table) made
  `error_detected` return `NEED_RESET` when attempts < Max +
  rate-limit OK + recovery enabled. **In the C+E+A geometry, that
  truth-table belongs to A3.** v1 C4 stays state-only-aware
  (`pci_channel_io_normal` → CAN_RECOVER, else DISCONNECT) and
  trusts that A3 (when loaded) will *override* the table-pointer
  to a smarter A3-aware variant or extend the dispatch via the
  explicit-out-of-band path. The intent's Scope boundary (intent
  lines 151-155) names this: "This patch does NOT request
  `PCI_ERS_RESULT_NEED_RESET` from `.error_detected`. Without a
  working reinit path the request would be a false promise."
  Correctly carved.
- **Alternatives considered + rejected — five-callback shape with
  `.reset_done`.** v2 review's Design-choices bullet (review
  lines 302-308) says "The kernel's `struct pci_error_handlers`
  defines five fields (.error_detected, .mmio_enabled, .slot_reset,
  .reset_done, .resume). v1 populates four (skipping
  `.reset_done`)." Per my reading of
  `/root/linux-v6.19/include/linux/pci.h:921-941`, the struct
  actually has **seven** fields in v6.19: the missed ones are
  `reset_prepare` (line 933) and `cor_error_detected` (line 940).
  This is a **v2 review prose error**, not a v1 code defect — v1
  correctly populates the four kernel-recovery-state-machine paths
  (`error_detected`, `mmio_enabled`, `slot_reset`, `resume`) which
  is the minimum-honest scaffold. The two omitted fields
  (`reset_prepare`, `reset_done`) are dispatched by
  `pci_reset_function()` not by the AER recovery state machine; the
  third (`cor_error_detected`) records additional details for
  correctable errors but does not affect the recovery vote. Aorus
  ancestor `patches/0007-...` populates only `.error_detected`
  (one callback). The aorus 0029 close-path patch
  (`lever-catalog.md:389-391`) added `mmio_enabled` AND
  `cor_error_detected` callbacks to the M-base table — but
  `cor_error_detected` was specifically for close-path probing
  observability, NOT for AER recovery. **In the C+E+A geometry
  `cor_error_detected` belongs to `A4-close-path-telemetry`, not
  C4.** Worth surfacing the v2 review's miscount as a documentation
  precision item (see I5 below). **No refinement candidate** for
  the field count — v1's four-callback choice is correct.
- **Alternatives considered + rejected — log-once vs always-log.**
  Aorus M-base (patch 0007 lines 38-57) had `static int
  s_tb_egpu_lever_m_logged = 0`; v1 C4 has none. See "Constraint
  discovered" above for the rationale (storm control = A3's job,
  not C4's). The v2 review's Design choices section does not
  explicitly enumerate this alternative; it's worth a one-liner
  in the intent's Scope boundary or in the catalog for provenance.
  See I4 below.
- **Forgotten / latent invariant — A3 must override the
  `.err_handler` pointer (or the dispatch table) to enable real
  recovery, NOT extend C4's stubs.** v2 intent line 151-155
  + Provenance lines 184-192 imply but don't explicitly state the
  invariant. v1 source-file block comment (the comment block
  before `nv_pci_error_detected` in the patched file) covers the
  rationale clearly. The invariant is captured in the v2 review's
  Strengths bullet "Honest DISCONNECT from `slot_reset`" (review
  lines 156-164) but not as a forward-looking promise to A3.
  Candidate: I3 below.
- **Forgotten / latent invariant — `pci_dev_is_disconnected(dev)`
  pre-check.** The kernel's `report_error_detected`
  (linux-v6.19 `drivers/pci/pcie/err.c:59-60`) checks
  `pci_dev_is_disconnected(dev)` BEFORE invoking the driver's
  callback and votes `PCI_ERS_RESULT_DISCONNECT` regardless. So
  C4's `nv_pci_error_detected` is only called for devices the
  kernel has NOT already marked disconnected — meaning C4's
  `default:` branch returning DISCONNECT for
  `pci_channel_io_perm_failure` is in fact unreachable through
  the kernel's normal AER walk (the kernel will have voted
  DISCONNECT before reaching the driver). The `perm_failure` path
  IS reachable via `report_perm_failure_detected`
  (linux-v6.19 `drivers/pci/pcie/err.c:111-127`) which is
  dispatched separately. The intent's
  `default:`-handles-everything-correctly contract holds either
  way. **No refinement candidate** — the v1 default-branch shape
  is defensively correct against any dispatch site.
- **Forgotten / latent invariant — `device_lock` held during all
  err_handler dispatches.** The kernel's `report_*` functions
  (linux-v6.19 `drivers/pci/pcie/err.c:57, 116, 135, 154, 173`)
  hold `device_lock(&dev->dev)` across the callback invocation.
  This means C4's callbacks are serialized against `nv_pci_remove`
  (which the kernel also holds `device_lock` for). v1's callbacks
  are short pure-stubs with no shared mutable state — race-free
  by construction. The invariant is implicit and would only become
  load-bearing if a future C4 patch added shared state. **No
  refinement candidate** — the invariant is locally trivial for
  v1's stub bodies.

## Improvements considered

### C4-err-handlers-scaffold-I1 — `default:` branch lists frozen + perm_failure explicitly

- **Lens:** robustness (re-examined from v2 deferral D1)
- **Current state:** v1 `nv_pci_error_detected` uses
  `case pci_channel_io_normal: ... default: ...`. The `default:`
  block catches both `pci_channel_io_frozen` and
  `pci_channel_io_perm_failure` (the only other defined values in
  `pci_channel_state_t` per `/root/linux-v6.19/include/linux/pci.h:201-207`)
  AND any future-added enum value silently.
- **Proposed state:** Expand the switch to enumerate
  `pci_channel_io_normal` (CAN_RECOVER), `pci_channel_io_frozen`
  (DISCONNECT, "link is frozen"), and `pci_channel_io_perm_failure`
  (DISCONNECT, "device permanently failed"), with `default:`
  retained as a "future-added enum value" arm that emits a
  distinctive log line.
- **Value:** Future-maintainer legibility; a kernel-added fourth
  enum value would surface at upstream review of the kernel change
  rather than silently inheriting C4's DISCONNECT vote.
- **Cost:** +~6 LoC; one additional `pci_warn` format string;
  re-touches the surface the upstream PR is built on. Behavioural
  contract is unchanged (CAN_RECOVER for normal, DISCONNECT for
  everything else). Aorus ancestor `patches/0007-...` did not list
  cases either — single unconditional DISCONNECT. The kernel's
  own in-tree PCIe drivers use mixed styles; no single canonical
  pattern. `pci_channel_state_t` has been stable at three values
  across multiple LTS kernels per the v2 review's D1 evidence —
  low-probability future-proofing concern.
- **Verification mode:** A.
- **Intent impact:** none (the intent's Scenarios already specify
  the behaviour for both branches; the switch shape is an
  implementation detail).
- **Triage decision:** reject.
- **Resolution:** rejected — `default:` shape is **upheld** per
  the v2 D1 deferral disposition. Default-reject discipline for
  upstream-bound Core layer (per plan §Default-reject + bloat
  budget): cost is +6 LoC of legibility for a future-proofing
  concern against a kernel enum that has been stable for years.
  Aorus ancestor used unconditional DISCONNECT (even less
  specific). v1's `default:` shape is also the kernel's idiom in
  most in-tree PCIe drivers — Mellanox's mlx5, ixgbe, nvme all
  use `default: return PCI_ERS_RESULT_DISCONNECT` for their fatal
  arm. M6 evidence reinforces rather than flips the deferral.

### C4-err-handlers-scaffold-I2 — Explicitly document the C4 → A3 contract handoff in Scope boundary

- **Lens:** invariant clarity (duty-lens carve-out documentation)
- **Current state:** Intent Scope boundary lines 144-146 say "C4
  makes the recovery callbacks REACHABLE; the consumers make them
  USEFUL." This captures the C4 vs A3 carve at a single-sentence
  level. The forward-looking invariant — that A3 must **override**
  the `.err_handler` table pointer (or extend dispatch via the
  explicit out-of-band path documented in
  `lever-catalog.md:357`) and CANNOT simply call C4's `.slot_reset`
  stub (which returns DISCONNECT) — is implicit. A future A3
  maintainer reading C4 in isolation might assume calling
  `.slot_reset` is the correct dispatch path and get DISCONNECT
  instead of recovery.
- **Proposed state:** Add a Scope-boundary clause stating that the
  `.slot_reset` and `.resume` callbacks v1 registers are
  **placeholder stubs** that an addon-layer recovery implementation
  must override by either (a) re-assigning
  `nv_pci_driver.err_handler` to a different table, or (b)
  dispatching its own `slot_reset` and `resume` equivalents
  explicitly after `pci_reset_bus` — per the aorus 0027 pattern.
  C4's stubs are correct **as fallbacks** when the addon is not
  loaded.
- **Value:** Forward-looking invariant clarity for the C4 → A3
  contract. Helps an upstream reviewer reading C4 in isolation
  understand the placeholder nature of `.slot_reset`. Helps a
  future A3 maintainer not accidentally rely on C4's stub.
- **Cost:** ~5 lines added to Scope boundary. Re-opens intent's
  `reviewed` lint state. C4 is upstream-bound — adding addon-aware
  prose to an upstream-bound intent risks mixing concerns. The C4
  intent is *currently* clean of A3 references (only `[[E1]]`,
  `[[C5]]` wikilinks); adding A3-specific carve-out language
  inverts that posture.
- **Verification mode:** A.
- **Intent impact:** add Scope boundary clause.
- **Triage decision:** reject.
- **Resolution:** rejected — the placeholder-stub property is
  durably captured in the v2 review's Strengths section (review
  lines 156-164 "Honest DISCONNECT from `slot_reset`. ...
  v1's `nv_pci_slot_reset` returns
  `PCI_ERS_RESULT_DISCONNECT` with a `pci_warn` naming the
  limitation. This is the honest answer for a driver with no
  reinit path"). The aorus-archaeology finding about A3's
  explicit out-of-band dispatch (lever-catalog.md:357) is a
  project-internal addon concern; surfacing it in C4's intent
  inverts the upstream-bound carve-out. **Disposition for
  follow-up:** the addon-layer carve-out (C4 stub vs A3 override)
  belongs in `A3-recovery`'s intent, not C4's. Tracked here so
  the A3 review (Task 11) explicitly cross-links to this catalog
  entry when documenting A3's override semantics.

### C4-err-handlers-scaffold-I3 — Note A3 override pattern + cross-reference E1 / C5 / A3 in Cross-references

- **Lens:** invariant clarity (downstream-consumer mapping)
- **Current state:** v2 review's "Related reviews" section
  (review lines 387-391) cross-links `[[E1-egpu-detection]]` and
  `[[C5-crash-safety]]`. The frontmatter `related-patches:`
  carries `[E1-egpu-detection, C5-crash-safety]` (intent line 8 +
  review line 8). **A3-recovery is NOT in either list** despite
  the aorus archaeology making clear A3 is the load-bearing
  downstream consumer of C4's registered callbacks (the entire
  Lever M-recover patches 0024+0026+0027+0028 series is the
  consumer in the C+E+A geometry). The v2 intent's Scope
  boundary (intent line 144) names `[[A3-recovery]]` once via
  wikilink but the frontmatter list omits it.
- **Proposed state:** Add `A3-recovery` to the
  `related-patches:` frontmatter in both intent and review files.
  Add a one-sentence Cross-reference entry in the catalog noting
  A3 as the load-bearing downstream consumer.
- **Value:** Cross-patch consistency. Task 14's cross-patch
  audit would surface this gap anyway; better to fix at the C4
  catalog stage when the relationship is freshly grokked.
- **Cost:** Frontmatter list edit + re-lint of intent.
  Re-opens intent's `reviewed` lint state. The Rule 6 lint
  resolution requires the target intent files to exist; A3's
  intent file exists at `docs/patch-intents/A3-recovery.md`
  (per the manifest at patches/manifest line for `A3-recovery`).
  The v2 review's Design-choices section (review lines 322-332)
  explicitly chose to leave `related-patches:` empty in the
  intent at sub-cycle 2 and defer to Task 14's cross-patch audit.
- **Verification mode:** A.
- **Intent impact:** refine frontmatter (`related-patches:`).
- **Triage decision:** defer.
- **Resolution:** deferred — the cross-patch surface lens lives
  with Task 14 (per the plan's "Cross-patch aggregation lands in
  Task 14"). The v2 review's deliberate choice (review lines
  322-332) to defer frontmatter cross-refs to Task 14 is
  upheld. **Disposition for follow-up:** Task 14 cross-patch
  audit MUST add `A3-recovery` to both C4's `related-patches:`
  AND C4 to A3's `related-patches:` when reconciling. The "C5
  registers handlers" sub-cycle 2 prose-drift correction
  (commit 89a69b9) suggests Task 14 will revisit the registration
  contract reconciliation anyway. Catalog entry here ensures the
  finding is not lost between now and Task 14.

### C4-err-handlers-scaffold-I4 — Add log-once flag for AER storm spam control

- **Lens:** quality / robustness (carry-over from aorus M-base)
- **Current state:** v1 emits one `pci_info`/`pci_warn` per
  callback dispatch (intent Telemetry contract lines 173-180:
  "Each handler emits exactly one log line per dispatch. No
  per-callback telemetry is gated behind a debug flag — the
  recovery flow is sufficiently rare and operationally important
  that the prove-the-path log lines belong at info/warn severity
  unconditionally."). Aorus M-base
  (`patches/0007-...:38-57`) carried `static int
  s_tb_egpu_lever_m_logged = 0;` with a comment "AER
  notifications can fire many times in rapid succession; we want
  one bright marker per failure event, not log spam."
- **Proposed state:** Re-introduce the aorus log-once flag for
  the fatal/DISCONNECT branch (where storming is operationally
  most concerning).
- **Value:** Defense against AER-storm log spam on
  unguarded-by-addon configurations.
- **Cost:** +~6 LoC; introduces module-level mutable state
  (an `int` flag) that requires reset logic on module reload (or
  it'll latch true across reloads in the same boot). Inverts
  the v2 intent's deliberate "every dispatch logs" contract —
  loses operator-visibility for subsequent fires. Storm control
  in the C+E+A geometry belongs to `A3-recovery`'s rate-limit
  gate (`lever-m-recover-commit3-hardening-design.md:46-61`
  H2 defers fires <30s apart at the schedule-work decision, NOT
  in the log path); when A3 is loaded, storming AER fires never
  reach C4's callback because A3 rejects them at the truth-table
  gate. Aorus M-base needed log-once because there was no addon
  layer; the C+E+A geometry retires that need.
- **Verification mode:** A.
- **Intent impact:** refine Telemetry contract.
- **Triage decision:** reject.
- **Resolution:** rejected — log-once is **aorus-era debt** that
  the C+E+A geometry retires by carving storm control into A3.
  C4 as scaffold should not carry workaround state for a
  scenario A3 is designed to prevent at the dispatch layer.
  Operator visibility (one log per actual dispatch) is more
  valuable for the scaffold-only case (where dispatches are
  rare because the addon is absent and AER fires aren't
  recovered from anyway) than for the addon-loaded case (where
  A3's rate limit means no storm reaches C4 in the first place).
  Default-reject for upstream-bound surface.

### C4-err-handlers-scaffold-I5 — Correct v2 review's "five-field struct" miscount

- **Lens:** quality (documentation accuracy)
- **Current state:** v2 review's Design-choices section (review
  lines 302-308) says "The kernel's `struct pci_error_handlers`
  defines five fields (.error_detected, .mmio_enabled,
  .slot_reset, .reset_done, .resume). v1 populates four
  (skipping `.reset_done`)." Per
  `/root/linux-v6.19/include/linux/pci.h:921-941`, the struct
  actually has **seven** fields: `error_detected`,
  `mmio_enabled`, `slot_reset`, `reset_prepare`, `reset_done`,
  `resume`, `cor_error_detected`. v1 populates four; the three
  unpopulated fields (`reset_prepare`, `reset_done`,
  `cor_error_detected`) are tolerated by the kernel's dispatch
  sites (NULL-checked at the `report_*` functions). The v2
  review's miscount does not change any operational claim — v1's
  4-callback choice is correct as the minimum-honest scaffold for
  the AER state machine — but it's a documentation precision
  issue.
- **Proposed state:** Lift the correct field count (7) into v2
  review's prose; characterize v1's four-callback choice as "the
  minimum for the AER state machine (the three remaining fields
  are dispatched by `pci_reset_function()` and the correctable-error
  path, not by `pcie_do_recovery()`)".
- **Value:** Documentation precision; helps a future maintainer
  reading the v2 review not develop a wrong mental model of the
  struct surface.
- **Cost:** Re-touches the v2 review file. Re-opens the review's
  `accepted` status. The miscount is in a Design-choices bullet
  that documents a *rejected* alternative; the operational
  consequence (v1's four-callback choice) is unchanged either
  way. Updating the review would also flow to Task 14's
  cross-patch consistency audit.
- **Verification mode:** A.
- **Intent impact:** none (the intent specifies the four populated
  callbacks correctly; the struct's actual field count is a
  kernel-side fact).
- **Triage decision:** defer.
- **Resolution:** deferred — the miscount is a **review-prose
  documentation precision issue, not a v1 code defect**. The
  v3 catalog (this file) surfaces the correct field count for
  audit-reviewer visibility. **Disposition for follow-up:** if
  Task 14 cross-patch audit revisits the v2 review files for
  any other consistency fix, fold this correction in then;
  otherwise leave the v2 review as-is. Tracked here so a future
  maintainer doesn't derive a wrong struct model from the v2
  review prose.

### C4-err-handlers-scaffold-I6 — Refine "recovery aborts" prose to match kernel's PCI_ERS_RESULT_NO_AER_DRIVER vote

- **Lens:** quality (kernel-canonical precision)
- **Current state:** v2 intent Purpose (intent line 18-24) +
  v2 review Rationale (review line 24-25) say "recovery aborts
  with 'can't recover (no error_detected callback)'". Per
  `/root/linux-v6.19/drivers/pci/pcie/err.c:73-78`, what the
  kernel actually does is vote `PCI_ERS_RESULT_NO_AER_DRIVER`
  for the device (or `PCI_ERS_RESULT_NONE` if the device is a
  bridge), which combined with `merge_result` at line 84
  prevents any subsequent callback dispatch in the affected
  sub-tree. The dmesg string is verbatim "can't recover (no
  error_detected callback)" (line 75). "Aborts" is operationally
  accurate but technically imprecise.
- **Proposed state:** Refine the prose to "recovery votes
  `PCI_ERS_RESULT_NO_AER_DRIVER` and logs 'can't recover (no
  error_detected callback)' — blocking subsequent callbacks for
  the affected sub-tree".
- **Value:** Kernel-canonical precision; helps an upstream
  reviewer not raise the "aborts is the wrong word" objection.
- **Cost:** Re-touches the intent's Purpose AND the review's
  Rationale. Re-opens intent's `reviewed` lint state for
  precision that doesn't change any contract claim. The operational
  consequence is the same under either phrasing.
- **Verification mode:** A.
- **Intent impact:** refine Purpose.
- **Triage decision:** reject.
- **Resolution:** rejected — "recovery aborts" is operationally
  accurate dmesg-grep-friendly prose; refining to the
  kernel-canonical `PCI_ERS_RESULT_NO_AER_DRIVER` term inflates
  intent for precision that the upstream reviewer can derive
  from the kernel-source citation. The C2 catalog's I6 was
  rejected for the same shape of reason. Default-reject:
  documentation-precision-for-precision's-sake against an
  upstream-bound intent.

### C4-err-handlers-scaffold-I7 — Use `pci_dev->error_state` to bias telemetry inside the callbacks

- **Lens:** invariant clarity (latent observability)
- **Current state:** The kernel populates
  `pci_dev->error_state` (linux-v6.19 `include/linux/pci.h:423`)
  with the current `pci_channel_state_t` value across the
  dispatch path (see `pci_dev_set_io_state` calls in
  `/root/linux-v6.19/drivers/pci/pcie/err.c:61, 156, 175`). C4
  receives `state` as a parameter and could cross-check
  `pci_dev->error_state` for invariant verification (they should
  be equal at dispatch time).
- **Proposed state:** Add a defensive `WARN_ON_ONCE(state !=
  pci_dev->error_state)` to `nv_pci_error_detected`.
- **Value:** Defense against a kernel-API contract violation
  (the parameter and the field disagree).
- **Cost:** +~1 LoC; introduces a kernel-API trust-but-verify
  assertion that would fire only on a kernel bug. The kernel's
  own in-tree PCIe drivers don't do this cross-check. Adds
  kernel-version-conditional surface (the `error_state` field
  has existed since kernel 2.6 but the dispatch invariant has
  been progressively tightened — `pci_dev_set_io_state` only
  exists in recent kernels). Defensive against an impossibility
  relative to the kernel contract.
- **Verification mode:** A.
- **Intent impact:** none (defensive code; intent doesn't
  constrain telemetry-vs-parameter cross-checks).
- **Triage decision:** reject.
- **Resolution:** rejected — defensive against an impossibility
  relative to the kernel-API contract. Kernel's own in-tree
  drivers don't do this cross-check. Adds version-conditional
  surface. Default-reject for upstream-bound surface (same
  default the C2 I1 bound-check was rejected under).

## Re-examination of sub-cycle 2 deferrals

- **`C4-err-handlers-scaffold-D1` (`default:` branch enum
  conflation):** v2 disposition = deferred (kept v1's `default:`
  shape to minimise vanilla-diff surface for the upstream PR).
  v3 disposition: **upheld**. Evidence: M6 archaeology against
  aorus ancestor `patches/0007-...:42-60` (used unconditional
  DISCONNECT — even less specific than v1's switch) +
  `lever-M-recover-design.md:246-262` (the M-recover runtime
  state machine inherits the same default-branch shape) shows
  the `default:` is the durable carve. Kernel's own in-tree PCIe
  drivers (mlx5, ixgbe, nvme) also use `default: return DISCONNECT`
  for the fatal arm. Surfaced as I1 above; rejected.
- **`C4-err-handlers-scaffold-D2` (no must-fix deltas):** v2
  disposition = rejected (no v2 follow-up needed). v3
  disposition: **upheld**. M6 archaeology surfaces no new
  evidence that flips the disposition — all 7 I-candidates
  above triage to reject or defer. Zero-delta sentinel
  `v1-tip-sha == v2-tip-sha == 2f3c4896010198c722bc1fb14745ff5e780d17e5`
  holds across sub-cycle 3.

## Improvements landed

(none — all 7 candidates triaged to reject (5) or defer (2);
v1 already meets the v3 quality bar. Zero-delta sentinel
`v1-tip-sha == v2-tip-sha == 2f3c4896010198c722bc1fb14745ff5e780d17e5`
holds across the sub-cycle 3 review.)

## Intent updates landed

(none — no candidate triaged `land` with intent impact)

## Done gate

- [x] Every candidate improvement has explicit `Resolution:` (no `pending`).
- [x] All "land" improvements applied as fork-branch commits citing their `<id>-I<N>` IDs. _(N/A — zero land triages.)_
- [x] Substantive intent updates landed as precursor commits. _(N/A — zero substantive intent updates.)_
- [x] `tools/intent-lint.sh` passes (no intent change; lint re-verified).
- [x] `tools/validate-patchset.sh` passes (compile gate; composed C1-A5 patchset against kernel 7.0.9-204.fc44.x86_64).
- [x] `bash tests/run.sh` green (34 ok, 0 failed).
- [ ] Audit-reviewer subagent approved.

## Methodology notes for the audit-reviewer

- **M1+M2 actually-consulted vs binding.** Binding named
  `lever-M-recover-design.md` (Lever M base),
  `lever-m-recover-commit3-handover.md`,
  `lever-m-recover-commit3-hardening-design.md`, and `recovery.md`
  (handler registration role). **Dropped `recovery.md`** — six grep
  hits for AER all incidental (operator runbook glossary +
  freeze-fingerprint dmesg patterns + journalctl grep examples);
  zero design content for the C4 scaffold mechanism. **Added
  `lever-catalog.md:281-303`** (Lever M-base catalogue entry —
  binding listed M-recover-design and the handover/hardening docs
  but omitted the canonical M-base entry which is C4's actual
  ancestor — the M-recover docs cover what is now A3 territory) and
  **`lever-catalog.md:307-396`** (M-recover catalogue entry —
  contains the patches 0027 finding that is load-bearing for C4's
  duty-lens contract). **Kept `lever-M-recover-design.md:31-52`
  + `:196-258`** (the M-base → M-recover staging discipline + the
  runtime AER state machine that C4 stays out of). **Kept
  `lever-m-recover-commit3-handover.md:48-62` + `:119-130`** (the
  H4 truth table — informs C4's "stay state-only-aware, leave
  smarter-truth-table to A3" carve-out). **Skipped
  `lever-m-recover-commit3-hardening-design.md` deep dive** — its
  H1-H4 fixes are A3 territory; only the H4 truth-table reference
  (which is also captured in the handover doc) was load-bearing for
  C4.
- **M5 community-signal discipline.** TOSUKUi #979 is tagged `C4`
  with **the strongest single corroboration in the dataset**: the
  reported "can't recover (no error_detected callback)" dmesg
  string is the **verbatim output** from
  `/root/linux-v6.19/drivers/pci/pcie/err.c:75` — i.e. TOSUKUi's
  reproducer fired the exact code-path branch in `err.c` that the
  C4 scaffold turns from a "no callback" abort into a "callback
  dispatched" recovery vote. This is **code-path commonality**,
  not just error-code commonality. Distinct from the C2 catalog's
  weaker TOSUKUi citation (error-code-only): for C4 specifically,
  TOSUKUi's reproducer demonstrates that the gap C4 fills is
  platform-class-general (AMD-host USB4 + Intel-host TB4 both
  reach the same kernel branch).
- **M6 deferral re-examination.** Both v2 deltas (D1 nice-to-have
  + D2 no-must-fix) re-examined; both upheld. See "Re-examination
  of sub-cycle 2 deferrals" section.
- **M7 line ranges.** All v1-archaeology citations use line ranges
  (5-line windows preferred).
- **M8 `.regen-state` restore.** N/A — zero code commits landed
  for C4; no `.regen-state` advance needed for this patch.
- **Meta-finding on v2 review prose: `struct pci_error_handlers`
  field count.** v2 review Design-choices section (review lines
  302-308) characterises the struct as having "five fields"; per
  `/root/linux-v6.19/include/linux/pci.h:921-941` it has **seven**
  in v6.19 (`error_detected`, `mmio_enabled`, `slot_reset`,
  `reset_prepare`, `reset_done`, `resume`, `cor_error_detected`).
  Surfaced as I5; deferred to Task 14's potential cross-patch audit
  pass. Not a v1 code defect — v1's four-callback population is
  correct for the AER state machine.
- **Meta-finding on memory note re sub-cycle 2 cross-patch audit.**
  The task header noted "sub-cycle 2 had a prose-drift finding that
  'C5 registers handlers' — actually C4 registers, C5 consumes the
  primitives (corrected in commit 89a69b9 during Task 14
  cross-patch audit)". Verified: v2 review's Strengths bullet at
  review lines 178-180 says "Single-line wiring of the table. The
  `.err_handler` field is the standard kernel-side wiring; v1 adds
  exactly the line every in-tree driver adds. No bespoke
  registration shim." Confirms C4 is the registration site. No
  drift in current state.

## Cross-references

- Intent file: `docs/patch-intents/C4-err-handlers-scaffold.md`
- Review file: `docs/patch-reviews/C4-err-handlers-scaffold.md`
- Manifest row: `patches/manifest` line for `C4-err-handlers-scaffold` (layer `base`, source `fork:c4-err-handlers-scaffold`)
- Vanilla baseline: `kernel-open/nvidia/nv-pci.c:nv_pci_driver` (vanilla 595.71.05 leaves `.err_handler` unset; no `pci_error_handlers` table is defined anywhere in `kernel-open/`; the patch is purely additive — `git show 595.71.05:kernel-open/nvidia/nv-pci.c` lines 2750-2764 + `nv_pci_register_driver()`/`nv_pci_unregister_driver()` at lines 2767-2785, unmodified)
- Kernel reference: `/root/linux-v6.19/include/linux/pci.h:191-208` (`pci_channel_state_t` enum definition — three values: `pci_channel_io_normal`, `pci_channel_io_frozen`, `pci_channel_io_perm_failure`); `/root/linux-v6.19/include/linux/pci.h:898-918` (`pci_ers_result_t` enum — six values including `PCI_ERS_RESULT_NO_AER_DRIVER`); `/root/linux-v6.19/include/linux/pci.h:921-941` (`struct pci_error_handlers` — seven function-pointer fields); `/root/linux-v6.19/drivers/pci/pcie/err.c:49-86` (`report_error_detected` dispatch site — the kernel branch that distinguishes "no callback" → `PCI_ERS_RESULT_NO_AER_DRIVER`); `/root/linux-v6.19/drivers/pci/pcie/err.c:210-267` (`pcie_do_recovery` state machine — shows `slot_reset` is dispatched only when status reaches `NEED_RESET`)
- Fork branch: `c4-err-handlers-scaffold` on `apnex/open-gpu-kernel-modules` (v1-tip == v2-tip == `2f3c4896010198c722bc1fb14745ff5e780d17e5` — zero-delta sentinel)
- aorus-5090 ancestor: `/root/aorus-5090-egpu/patches/0007-nv-pci-register-error-handlers-Lever-M-base.patch` (Lever M-base, 2026-05-04 — single-callback table with unconditional DISCONNECT + log-once flag)
- aorus-5090 docs: `/root/aorus-5090-egpu/docs/lever-catalog.md:281-303` (Lever M-base catalogue entry — the M-base mechanism + staging discipline); `/root/aorus-5090-egpu/docs/lever-catalog.md:307-396` (Lever M-recover catalogue entry — the patches 0027 finding about explicit out-of-band dispatch); `/root/aorus-5090-egpu/docs/lever-M-recover-design.md:31-52` (the M-base → M-recover layering rationale + why the kernel's `pci_error_handlers` framework is the right layer); `/root/aorus-5090-egpu/docs/lever-M-recover-design.md:196-258` (the runtime AER state machine that C4 stays out of and A3 owns); `/root/aorus-5090-egpu/docs/lever-m-recover-commit3-handover.md:48-62` (the storm postmortem + 4 H15 hardening fixes); `/root/aorus-5090-egpu/docs/lever-m-recover-commit3-handover.md:119-130` (the H4 smarter-`error_detected` truth table that belongs to A3, not C4)
- Upstream issue: <https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979> — Blackwell GPU over Thunderbolt commits permanent lost state on transient PCIe failures. C4 is the load-bearing scaffolding that any subsequent in-driver PCIe error-handling depends on; TOSUKUi 2026-05-02 comment is the verbatim "no error_detected callback" symptom evidence.
- Community signal: `/root/nvidia-driver-injector/docs/patch-improvements/_community-signal.md:16-22` (TOSUKUi 2026-05-02 #979 comment — **code-path commonality not just error-code commonality** for C4 per M5); `/root/nvidia-driver-injector/docs/patch-improvements/_community-signal.md:128-131` (consolidated taxonomy tagging C4 against the "no error_detected callback" symptom verbatim)
- Related reviews: [[E1-egpu-detection]] (eGPU-aware detection drives potential future per-device behaviour in the registered callbacks; E1 builds on C4's scaffold), [[C5-crash-safety]] (de-branded primitives and dead-bus read handling consume the registered callbacks when in-driver dead-bus signals interleave with the kernel's AER state machine), [[A3-recovery]] (the load-bearing downstream addon consumer — `.slot_reset` placeholder stub in C4 is overridden via A3's explicit out-of-band dispatch pattern documented in `lever-catalog.md:357`)
