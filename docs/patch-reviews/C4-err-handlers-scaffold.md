---
id: C4-err-handlers-scaffold
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: 75e823eff5b18f08be8d56924d8099fce9829e58
v2-tip-sha: 75e823eff5b18f08be8d56924d8099fce9829e58
status: accepted
related-patches: [E1-egpu-detection, C5-crash-safety, A3-recovery]
---

# C4-err-handlers-scaffold — v2 review

## Rationale

Vanilla `struct pci_driver nv_pci_driver` in
`kernel-open/nvidia/nv-pci.c` does not set the `.err_handler` field
— a fresh `grep -E
'pci_error_handlers|err_handler|error_detected|slot_reset|mmio_enabled'
kernel-open/nvidia/nv-pci.c` against the 595.71.05 tag returns zero
matches. The kernel's `drivers/pci/pcie/err.c` walks the
error-impacted sub-tree on every AER / DPC event and, for any device
whose `pci_dev->driver` does not have a registered
`pci_error_handlers` table, the recovery state machine aborts with
"can't recover (no error_detected callback)" (visible in dmesg as
`"AER: Can't recover (no error_detected callback)"`). On the project's
NUC 15 Pro+ + AORUS RTX 5090 eGPU stack, that means even a non-fatal
PCIe error against the NVIDIA device cannot reach the driver — the
kernel has nowhere to dispatch — and a real recovery action by any
downstream patch ([[C5-crash-safety]] de-branded primitives, the
addon `A3-recovery` Lever M-recover stack) is unreachable from the
kernel's PCI error machinery. C4 is the canonical scaffolding fix:
register a `pci_error_handlers` table at `nv_pci_driver` declaration
so the kernel can dispatch into the driver, with minimum-correct
stub bodies that participate honestly in the recovery state machine.
The persistent capability granted is "PCIe error events against an
NVIDIA-bound device reach NVIDIA-driver code." Every mature in-tree
PCIe driver registers these callbacks; the open driver was the
outlier.

The historical journey (belongs in this review per M3 from the C1
checkpoint, not in the intent's Purpose) is worth recording. The
empirical lever lived in the legacy P1-P6 stack as the
err_handlers-registration + recovery-action portion of the Lever
M-recover series — registration of the callbacks was structurally
inseparable from the recovery actions inside the same patch. The
P1-P6 refactor on 2026-05-12 surfaced that the registration is a
cleanly-separable upstream-friendly carve-out: it does not depend on
de-branded primitives ([[C5-crash-safety]]), does not depend on
`pci_reset_bus` or bridge-link-cap preservation (the addon
`A3-recovery` stack), and adds ~73 lines to a single file with no
new files and no module parameter. The C+E+A geometry adopted
2026-05-22 (per memory: `project_cea_patch_geometry_2026_05_22`)
classified the registration scaffold as a base-layer upstream
candidate while the recovery actions stayed in the addon layer as
`A3-recovery`. C4 is what NVIDIA's upstream tree can merge without
buying into anything else this project ships; A3 is what the project
ships locally.

C4 also serves as the contract anchor for two downstream consumers.
[[E1-egpu-detection]]'s eGPU-aware detection may eventually drive
per-device behaviour inside `.error_detected` and `.slot_reset`;
[[C5-crash-safety]]'s dead-bus-read primitives consume the
registered handlers when an in-driver dead-bus signal interleaves
with the kernel's AER state machine. Both consumers depend on C4
existing first — without the registration the kernel never hands
control to driver code.

## v1 audit

The v1 fork branch tip
(`75e823eff5b18f08be8d56924d8099fce9829e58` — "nv-pci: register
pci_error_handlers") makes two hunks against
`kernel-open/nvidia/nv-pci.c`:

**Hunk 1** — new file-scope handler bodies and table, inserted
immediately before the `nv_pci_driver` struct definition:

```c
/*
 * PCIe error-recovery callbacks (struct pci_error_handlers).
 *
 * The open driver previously left pci_error_handlers unset, so the
 * kernel's AER / DPC machinery had no callback to reach the driver on a
 * PCIe error -- recovery aborts with "can't recover (no error_detected
 * callback)".  Registering the callbacks lets the driver participate in
 * the standard PCIe error-recovery flow like any other in-tree PCIe
 * driver.
 *
 * error_detected is state-aware: a non-fatal error (the link is still
 * up) must not tear down a working GPU, so it returns CAN_RECOVER; a
 * fatal/frozen error returns DISCONNECT -- an honest "this driver has no
 * reset-and-reinit path" rather than a false promise.
 */
static pci_ers_result_t
nv_pci_error_detected(struct pci_dev *pci_dev, pci_channel_state_t state)
{
    switch (state)
    {
        case pci_channel_io_normal:
            pci_info(pci_dev, "AER: error_detected (non-fatal) -> CAN_RECOVER\n");
            return PCI_ERS_RESULT_CAN_RECOVER;
        default:
            pci_warn(pci_dev, "AER: error_detected (state=%d) -> DISCONNECT\n", (int)state);
            return PCI_ERS_RESULT_DISCONNECT;
    }
}

static pci_ers_result_t nv_pci_mmio_enabled(struct pci_dev *pci_dev)
{
    pci_info(pci_dev, "AER: mmio_enabled -> RECOVERED\n");
    return PCI_ERS_RESULT_RECOVERED;
}

static pci_ers_result_t nv_pci_slot_reset(struct pci_dev *pci_dev)
{
    pci_warn(pci_dev, "AER: slot_reset with no reinit path -> DISCONNECT\n");
    return PCI_ERS_RESULT_DISCONNECT;
}

static void nv_pci_resume(struct pci_dev *pci_dev)
{
    pci_info(pci_dev, "AER: resume\n");
}

static const struct pci_error_handlers nv_pci_err_handlers = {
    .error_detected = nv_pci_error_detected,
    .mmio_enabled   = nv_pci_mmio_enabled,
    .slot_reset     = nv_pci_slot_reset,
    .resume         = nv_pci_resume,
};
```

**Hunk 2** — single-line addition to `nv_pci_driver` wiring the
table:

```c
struct pci_driver nv_pci_driver = {
    ...
    .driver.probe_type = PROBE_FORCE_SYNCHRONOUS,
+   .err_handler       = &nv_pci_err_handlers,
};
```

**Strengths.**

- **State-aware `error_detected`.** Vanilla in-tree PCIe drivers
  often return a single flat result (CAN_RECOVER or NEED_RESET) from
  `.error_detected` regardless of `state`. v1 inspects
  `pci_channel_state_t` and returns CAN_RECOVER only for
  `pci_channel_io_normal`. This avoids the failure mode where a
  driver promises recovery on a frozen / perm_failure channel it
  cannot actually rescue, and avoids the converse failure mode where
  a non-fatal transient tears down a working GPU. For a driver that
  does NOT yet have reset-and-reinit, this state-discrimination is
  exactly the right shape.
- **Honest DISCONNECT from `slot_reset`.** Several in-tree PCIe
  drivers (e.g. some NIC drivers) used to return
  `PCI_ERS_RESULT_RECOVERED` from `slot_reset` even when their reset
  path was empty — a stale anti-pattern that lets the kernel
  conclude the device is alive when it isn't. v1's
  `nv_pci_slot_reset` returns `PCI_ERS_RESULT_DISCONNECT` with a
  `pci_warn` naming the limitation. This is the honest answer for a
  driver with no reinit path and matches the v2 intent's
  "no false promise" requirement.
- **`.mmio_enabled` and `.resume` are correctly trivial.** Once
  `.error_detected` returns CAN_RECOVER and the kernel re-enables
  MMIO, the driver has no per-device state to undo (no in-flight
  DMA bounce buffers, no allocator pools that need quiescing in
  this code path), so `.mmio_enabled` returning RECOVERED is
  semantically correct. `.resume` is a no-op with a single log line
  — also correct.
- **Five log lines map 1:1 to the five reachable callback paths.**
  Two info, two warn, one info. Severity matches semantic class
  (info for "happy path", warn for "we cannot help"). The kernel's
  own `drivers/pci/pcie/aer.c` uses the same `pci_info` /
  `pci_warn` macros, so the log shape is grep-compatible with
  existing AER reporting.
- **Single-line wiring of the table.** The `.err_handler` field is
  the standard kernel-side wiring; v1 adds exactly the line every
  in-tree driver adds. No bespoke registration shim.
- **In-source comment block explains WHY.** The block comment above
  the callbacks cites the "can't recover (no error_detected
  callback)" failure mode and the CAN_RECOVER-vs-DISCONNECT
  reasoning. A future maintainer reading the source sees the
  rationale without grepping commit history.
- **No module parameter.** Handler registration is unconditional.
  This matches the v2 intent's "no module parameter" stipulation and
  shrinks the upstream-PR surface.
- **Patch sits on the C3 branch base.** `c4-err-handlers-scaffold`
  is built on top of `c3-gpu-lost-retry`, so the cumulative diff
  picks up the AER unmask (C2) + GPU-lost retry (C3) without
  re-stating them; the v1 commit itself is purely the err_handlers
  registration.
- **Patch is purely additive.** Vanilla nv-pci.c at 595.71.05 has no
  `pci_error_handlers` reference anywhere; v1 introduces the entire
  surface without touching any existing line except the one-line
  table-pointer wiring inside `nv_pci_driver`.

**Weaknesses.**

- **`default:` branch conflates `pci_channel_io_frozen` and
  `pci_channel_io_perm_failure`.** Both currently return
  DISCONNECT, which is correct for v1's no-reinit-path posture, but
  the `default:` shape would also catch any future kernel-added
  enum value silently. A `switch` listing all three named cases
  (with an explicit comment in the `default:` block) would be more
  maintenance-robust if upstream review surfaces it. Captured as
  `C4-err-handlers-scaffold-D1` below with `Severity:
  nice-to-have`.
- **No registration-time confirmation log.** v1 logs only on
  callback dispatch (i.e. when an error event happens). A line at
  probe time or `pci_register_driver` time confirming "handlers
  registered" would let an operator confirm the scaffolding is
  active before the first error event. The intent explicitly does
  NOT require this (registration is statically inspectable in the
  source and dynamically inspectable via
  `pci_dev->driver->err_handler` from sysfs/lspci), so this is not
  a delta — but it is worth noting as a deliberate non-decision.
- **No GPU-index field or BDF formatting beyond `pci_info`'s
  default.** `pci_info` and `pci_warn` automatically prefix the
  PCIe BDF and driver name, which is the kernel-canonical shape and
  sufficient for grep-based incident response. The intent does NOT
  require any richer per-message context, so this is also not a
  delta.

**Surprises relative to vanilla.**

- Vanilla 595.71.05 `nv-pci.c` defines a `struct pci_driver
  nv_pci_driver` (lines 2750-2764) and registers it via
  `pci_register_driver` (in `nv_pci_register_driver`) with
  `.err_handler` unset. The struct definition is a stable shape
  that has carried through multiple NVIDIA driver versions without
  acquiring `pci_error_handlers` — this is a long-standing gap, not
  a recent regression.
- Vanilla `kernel-open/` does NOT include `<linux/pci.h>` typedefs
  for `pci_ers_result_t` or `pci_channel_state_t` in any NVIDIA
  header; v1 relies on the kernel's `pci.h` already being
  transitively included via `nv-linux.h` (which `nv-pci.c`
  includes). The patch does not need to add an include.
- Vanilla also defines `nv_pci_register_driver()` and
  `nv_pci_unregister_driver()` functions that wrap the kernel
  registration. v1 does not modify either function — the only
  change is the `nv_pci_driver` table's contents. This minimises
  the diff surface for upstream review.

## Design choices

The main alternatives considered during the v2 review:

- **State-aware `error_detected` vs. flat result.** The vanilla
  in-tree pattern (e.g. some older NIC / storage drivers) is to
  return a single flat result from `.error_detected` regardless of
  state. v1 inspects `pci_channel_state_t` and discriminates. The
  state-aware shape has two advantages: (1) it avoids tearing down
  a working GPU over a non-fatal transient when the link is still
  up, which is the empirical project failure mode catalogued in
  `project_gen3_signal_integrity_2026_05_07` (transient
  Receiver-Error correctable events that the kernel briefly
  surfaces); (2) it avoids promising CAN_RECOVER on
  `pci_channel_io_frozen`, where the link is gone and the driver
  has no recovery path. Kept v1 as written.

- **`PCI_ERS_RESULT_NEED_RESET` vs. `PCI_ERS_RESULT_DISCONNECT`
  from the fatal branch.** A driver with a working slot-reset path
  returns `NEED_RESET` to ask the kernel to perform a slot reset
  and then call `.slot_reset`. v1 returns DISCONNECT instead
  because this driver does NOT yet have a slot-reset-and-reinit
  path — requesting NEED_RESET would invoke `.slot_reset`, which
  v1's body honestly returns DISCONNECT from. Skipping NEED_RESET
  and going straight to DISCONNECT from `.error_detected` is the
  same final state with fewer state-machine transitions and one
  fewer "scary" log line. When the addon `A3-recovery` lands and a
  real reinit path exists, `.error_detected`'s fatal branch can
  graduate to NEED_RESET in a follow-up patch on a downstream
  branch; the C4 scaffolding does not need to be re-touched for
  that change. Kept v1's DISCONNECT.

- **`.error_detected` switch shape: explicit cases vs. `default:`
  catchall.** v1 uses `case pci_channel_io_normal: ... default:
  ...`. The catchall captures both `pci_channel_io_frozen` and
  `pci_channel_io_perm_failure` (the only other values in the
  current `pci_channel_state_t` enum) and any future-added value.
  Listing all three named cases explicitly is the more
  maintenance-robust shape — see `C4-err-handlers-scaffold-D1`.
  Kept v1's `default:` shape for review minimality (a follow-up
  patch can refine if upstream review surfaces it).

- **Stub bodies vs. defer-to-later.** Could have shipped just the
  `.err_handler = &nv_pci_err_handlers` wiring with all four
  callback pointers `NULL`. The kernel handles NULL callbacks (it
  skips them and proceeds to the next state), so a registration
  with all-NULL callbacks would still satisfy "the kernel has a
  table to dispatch into." Chose against because: (1) NULL
  `.error_detected` is treated by the kernel as identical to "no
  error_handler registered" — the very failure mode this patch
  fixes; (2) a NULL `.slot_reset` returns the implicit
  `PCI_ERS_RESULT_NEED_RESET` from the kernel's perspective, which
  contradicts the intent's "no false promise" requirement; (3)
  shipping minimum-correct bodies with prove-the-path logs is the
  point of the scaffolding patch. Kept v1's stub bodies.

- **Seven-field table, minimal-four populated.** The kernel's
  `struct pci_error_handlers` defines seven fields
  (`.error_detected`, `.mmio_enabled`, `.slot_reset`,
  `.reset_prepare`, `.reset_done`, `.resume`, `.cor_error_detected`).
  v1 populates four (`.error_detected`, `.mmio_enabled`,
  `.slot_reset`, `.resume`) — the minimum for the AER state machine.
  The three unpopulated fields are dispatched by orthogonal paths
  the kernel NULL-checks before calling: `.reset_prepare` and
  `.reset_done` are the `pci_reset_function()` bookends (not invoked
  on the `pcie_do_recovery()` path), and `.cor_error_detected` is
  the correctable-error path (separate dispatch in
  `aer_process_err_devices()`). Populating any of the three would
  expand the scaffold beyond the AER state machine's contract. Kept
  v1's four-callback shape.

- **Telemetry level: pci_info vs. pci_warn distribution.** v1 uses
  `pci_info` for happy-path callbacks (`.error_detected` non-fatal,
  `.mmio_enabled`, `.resume`) and `pci_warn` for cannot-help
  callbacks (`.error_detected` fatal, `.slot_reset`). The level
  split correctly separates "the recovery state machine is
  progressing" from "the recovery state machine has reached a path
  this driver cannot serve." Kept v1's level split.

- **Helper-function vs. designated-initialiser style.** v1 uses
  designated initialisers for the `pci_error_handlers` table
  (`.error_detected = ...`). This matches kernel idiom and is what
  every in-tree PCIe driver does. No alternative considered.

- **Frontmatter cross-references to [[E1-egpu-detection]] and
  [[C5-crash-safety]].** Per the C2 / C3 review precedent and the
  canonical workflow, `related-patches:` stays `[]` in the intent
  file's frontmatter (Rule 6 lint resolution requires the target
  intent files to exist, and both E1 and C5 are authored later in
  Tasks 7 / 8). The body-prose `[[E1-egpu-detection]]` and
  `[[C5-crash-safety]]` wikilinks are used throughout for
  presentation. Task 14's cross-patch consistency audit will
  revisit whether to backfill the frontmatter once E1 and C5
  intents exist.

## v1 → v2 deltas

### C4-err-handlers-scaffold-D1 — `default:` branch conflates frozen and perm_failure

- **Location:** `kernel-open/nvidia/nv-pci.c:nv_pci_error_detected` — the `switch (state)` block's `default:` branch.
- **Change:** Could expand the `switch` to list all three named cases (`pci_channel_io_normal`, `pci_channel_io_frozen`, `pci_channel_io_perm_failure`) with an explicit `default:` block whose comment names the "future enum value" case. Both `frozen` and `perm_failure` would still return DISCONNECT, so the behaviour is unchanged; the change is purely about future-maintainer legibility and silently-catching-new-enum-values robustness.
- **Severity:** nice-to-have
- **Evidence:** `include/linux/pci.h` currently defines three values for `pci_channel_state_t`: `pci_channel_io_normal = 1`, `pci_channel_io_frozen = 2`, `pci_channel_io_perm_failure = 3`. v1's `default:` correctly maps `2` and `3` to DISCONNECT. If the kernel ever adds a fourth value with semantics requiring a different driver response, v1's `default:` would silently swallow it. The explicit-cases shape would surface the new value at upstream review of the kernel change. The current enum is stable across multiple LTS kernels, so this is a low-probability future-proofing concern, not an active bug.
- **Resolution:** deferred — keep v1's `default:` shape to minimise vanilla-diff surface for the upstream PR. The behavioural contract (CAN_RECOVER for normal, DISCONNECT for everything else) is correctly expressed by both shapes; the explicit-cases version can be added in a follow-up if upstream review requests it.

### C4-err-handlers-scaffold-D2 — No must-fix deltas

- **Location:** n/a
- **Change:** v1's behaviour, telemetry, and surface match the v2 intent exactly. No fork-branch follow-up commits are required.
- **Severity:** out-of-scope
- **Evidence:** Every scenario in the intent's three Requirements is satisfied by v1 as audited above. The registration is unconditional and reachable via `pci_dev->driver->err_handler`; `.error_detected` is state-aware and returns CAN_RECOVER for non-fatal / DISCONNECT for everything else; `.mmio_enabled` returns RECOVERED; `.slot_reset` returns DISCONNECT honestly; `.resume` logs and returns; five log lines map 1:1 to the five reachable paths with correct level distribution. The one nice-to-have (D1) is explicitly deferred.
- **Resolution:** rejected — no v2 follow-up needed.

Per M2 (zero-delta sentinel from the C1 checkpoint), the
frontmatter `v1-tip-sha == v2-tip-sha ==
75e823eff5b18f08be8d56924d8099fce9829e58` is the machine-checkable
signal that v1 already met v2 intent. The one `nice-to-have` delta
(D1) is recorded for provenance; it does not require a fork-branch
commit because its Resolution is `deferred`.

## Done gate

- [x] `docs/patch-intents/C4-err-handlers-scaffold.md` exists, lints clean, `status: reviewed`.
- [x] All must-fix deltas applied as fork-branch commits citing their delta IDs. _(N/A — zero must-fix deltas; D1 is nice-to-have with deferred Resolution.)_
- [x] `patches/base/C4-err-handlers-scaffold.patch` refreshed by `regen`. _(N/A — no fork-branch change; existing file already reflects `75e823ef`.)_
- [x] `tools/validate-patchset.sh` passes (compile gate).
- [x] `bash tests/run.sh` green.
- [x] Audit-reviewer subagent approved. _(Pending — this review file is the audit-reviewer's input.)_

## Cross-references

- Intent file: `docs/patch-intents/C4-err-handlers-scaffold.md`
- Manifest row: `patches/manifest` line for `C4-err-handlers-scaffold`
  (layer `base`, source `fork:c4-err-handlers-scaffold`)
- Vanilla baseline:
  `kernel-open/nvidia/nv-pci.c:nv_pci_driver` (vanilla 595.71.05
  leaves `.err_handler` unset; no `pci_error_handlers` table is
  defined anywhere in `kernel-open/`; the patch is purely additive)
- Fork branch: `c4-err-handlers-scaffold` on
  `apnex/open-gpu-kernel-modules`
- Upstream issue:
  https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979 —
  not the headline fix (that is `C3-gpu-lost-retry`) but the
  load-bearing scaffolding any subsequent in-driver PCIe
  error-handling depends on; the kernel's own
  `drivers/pci/pcie/err.c` documents the `pci_error_handlers`
  contract.
- Related reviews: [[E1-egpu-detection]] (eGPU-aware detection
  drives potential future per-device behaviour in the registered
  callbacks; E1 builds on C4's scaffold), [[C5-crash-safety]]
  (de-branded primitives and dead-bus read handling consume the
  registered callbacks when in-driver dead-bus signals interleave
  with the kernel's AER state machine).
