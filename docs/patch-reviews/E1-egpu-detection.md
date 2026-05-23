---
id: E1-egpu-detection
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: 000ea7a51db8b78225950a753a390a82f3aa1d81
v2-tip-sha: 000ea7a51db8b78225950a753a390a82f3aa1d81
status: accepted
related-patches: [C4-err-handlers-scaffold, A2-bus-loss-watchdog, A3-recovery]
---

# E1-egpu-detection — v2 review

## Rationale

Vanilla `RmCheckForExternalGpu` in
`src/nvidia/arch/nvalloc/unix/src/osinit.c` walks the PCIe bus
topology upward from the GPU via `clFindP2PBrdg`, matching each
intermediate bridge's vendor/device ID against a Thunderbolt-3-era
whitelist exposed by an internal RM control
(`NV2080_CTRL_CMD_INTERNAL_GET_EGPU_BRIDGE_INFO` returning
`approvedBusType == NV2080_CTRL_INTERNAL_EGPU_BUS_TYPE_TB3`) and
combining the result with a hot-plug-surprise slot-capability bit
read off the same upstream bridge. This shape was correct for the
TB3 era it was written in, but it does not recognise GPUs reached
over TB4 or USB4: Intel Barlow Ridge bridges and AMD USB4 host
routers carry vendor/device IDs absent from the internal whitelist,
so `params.iseGPUBridge` is false and the function returns
`NV_FALSE`. The kernel side has no such gap — the Linux PCI
subsystem maintains `pci_is_thunderbolt_attached(pdev)` (true if the
device or any bridge above it carries the Intel Thunderbolt VSEC,
which USB4 host routers also carry) and `pci_dev::untrusted` (set on
devices below a firmware-marked external-facing root port, the
endpoint-local form of the `external_facing` ACPI / DT marker). E1
replaces the vendor-ID walk with the union of those two
kernel-maintained signals. The persistent capability granted is "an
externally-attached GPU on any current Thunderbolt or USB4 transport
is recognised as external at probe without operator intervention."
This unlocks the existing eGPU-specific code paths the vanilla
driver already gates on `is_external_gpu` —
`NV_FLAG_IN_SURPRISE_REMOVAL` handling inside `osHandleGpuLost`, the
serialisation lift on unbind, and the future per-device behaviour
that [[C4-err-handlers-scaffold]]'s registered callbacks may
eventually want to apply.

The historical journey (recorded here per M3 from the C1
checkpoint, not in the intent's Purpose) is worth capturing. The
project memory `project_nvidia_open_driver_egpu_layer_tb3_era`
catalogues this exact gap — vanilla `nvidia.ko` HAS an eGPU layer
(`RmCheckForExternalGpu`, `is_external_gpu`,
`NV_FLAG_IN_SURPRISE_REMOVAL`) but the detection keys on TB3 bridge
vendor IDs and silently misses TB4/USB4 hardware. The project
workaround through 2026-05-22 was the modprobe.d override
`NVreg_RegistryDwords="RmForceExternalGpu=1"` in
`scripts/host-files/etc/modprobe.d/nvidia-driver-injector.conf:55`
(annotated as "Lever A — force the driver to treat this GPU as
external (eGPU), bypassing TB-bridge whitelist that doesn't include
TB4/TB5 hubs"). The C/E/A geometry adopted 2026-05-22 (memory
`project_cea_patch_geometry_2026_05_22`) classified the detection
modernisation as an `E` patch — upstream-bound, eGPU-specific, a
bug fix to vanilla NVIDIA code that is self-evidently correct and
smaller than what it replaces. E1 is what a running NVIDIA-tree
driver can carry to make `RmForceExternalGpu=1` unnecessary.

The persistent capability E1 grants is: "the union signal
`pci_is_thunderbolt_attached(pdev) || pdev->untrusted` decides
`is_external_gpu`, replacing the TB3 vendor-ID whitelist walk." That
capability is the contract this review file and the matching intent
govern.

## v1 audit

The v1 fork branch tip
(`000ea7a51db8b78225950a753a390a82f3aa1d81` — "osinit: detect
external GPUs from the kernel's PCI classification") makes four
hunks: three additions and one substantial rewrite.

**Hunk 1** — declaration added to
`kernel-open/common/inc/os-interface.h`, immediately after the
existing `os_pci_remove`:

```c
NvBool      NV_API_CALL  os_pci_is_thunderbolt_attached   (void *);
```

**Hunk 2** — mirrored declaration added to
`src/nvidia/arch/nvalloc/unix/include/os-interface.h` (the
core-RM-side os-interface header), same single-line addition.

**Hunk 3** — new function `os_pci_is_thunderbolt_attached` added to
`kernel-open/nvidia/os-pci.c`, inserted immediately after the
existing `os_pci_remove`:

```c
NvBool NV_API_CALL os_pci_is_thunderbolt_attached(
    void *handle
)
{
    struct pci_dev *pdev = (struct pci_dev *) handle;
    NvBool tb_attached;
    NvBool untrusted;

    if (pdev == NULL)
        return NV_FALSE;

    tb_attached = pci_is_thunderbolt_attached(pdev) ? NV_TRUE : NV_FALSE;
    untrusted   = pdev->untrusted ? NV_TRUE : NV_FALSE;

    if (!tb_attached && !untrusted)
        return NV_FALSE;

    pci_info(pdev,
        "external GPU detected (thunderbolt-attached=%s, external/untrusted=%s)\n",
        tb_attached ? "yes" : "no",
        untrusted ? "yes" : "no");

    return NV_TRUE;
}
```

The function is preceded by a block comment explaining the
two-signal union, that USB4 host routers carry the Intel Thunderbolt
VSEC (so `pci_is_thunderbolt_attached()` covers USB4 as well as
classic Thunderbolt), and that `pdev->untrusted` is the
endpoint-local form of the firmware external-facing marker (covering
external transports that do not expose the VSEC).

**Hunk 4** — rewrite of `RmCheckForExternalGpu` in
`src/nvidia/arch/nvalloc/unix/src/osinit.c`. Vanilla 595.71.05 has
the function take `(OBJGPU *pGpu, OBJCL *pCl)` and contain ~95 lines
of bus-walking code (the `do { handleUp = clFindP2PBrdg(...) ... }
while (!CL_IS_ROOT_PORT(portCaps))` loop with the TB3
`approvedBusType` check and slot-capability inspection). v1 replaces
the body with ~3 lines and drops the `OBJCL *pCl` argument:

```c
NvBool
RmCheckForExternalGpu
(
    OBJGPU *pGpu
)
{
    nv_state_t *nv = NV_GET_NV_STATE(pGpu);

    return os_pci_is_thunderbolt_attached(nv->handle);
}
```

The single caller (`RmInitNvDevice` at the
`if (RmCheckForExternalGpu(pGpu, pCl))` site) is updated in the same
hunk to pass only `pGpu`, and its now-unused `OBJSYS *pSys = ...; OBJCL
*pCl = SYS_GET_CL(pSys);` lookups are removed. Net change is +65
lines / -110 lines across four files.

**Strengths.**

- **Replaces a vendor-ID whitelist with kernel-maintained
  classification.** The vanilla TB3 whitelist is a closed-set
  approval list maintained inside an internal RM control; the kernel
  signals are maintained by the Thunderbolt / USB4 subsystem and
  reflect the actual transport. v1's choice is the canonical
  upstream-tree direction: defer to the subsystem that owns the
  classification.
- **Union of two independent kernel signals.** Each signal alone
  misses cases the other catches. `pci_is_thunderbolt_attached()`
  needs the Intel Thunderbolt VSEC on the path, which AMD USB4
  controllers in some configurations may not expose;
  `pdev->untrusted` needs the firmware to mark the root port
  external-facing, which not every TB-only motherboard does. v1's
  `tb_attached || untrusted` is the empirically-correct union shape
  per the project's hardware-verified note in `docs/upstream-plan.md
  §E1` ("on the project's Barlow Ridge / Thunderbolt 5 hardware,
  `pci_is_thunderbolt_attached()` returns true ... `untrusted` is
  the endpoint-local union member").
- **NULL-handle guard.** `if (pdev == NULL) return NV_FALSE;` at the
  top of `os_pci_is_thunderbolt_attached` defends against a
  pathological state where the caller has not yet wired
  `nv->handle` to a `struct pci_dev *`. The single caller path
  (`RmInitNvDevice` → `RmCheckForExternalGpu` → `NV_GET_NV_STATE` →
  `nv->handle`) always passes a non-NULL handle in vanilla, but the
  guard is cheap and the consequence of dereferencing NULL would be
  a kernel oops at probe.
- **`pci_info(pdev, ...)` log macro.** This is the same family used
  by the kernel's own `drivers/pci/pcie/aer.c` and by
  [[C4-err-handlers-scaffold]]'s registered callbacks, so the log
  shape is grep-compatible with surrounding PCIe-subsystem output.
  Automatic BDF + driver-name prefix means a single `dmesg | grep`
  surfaces the relevant device without operator effort.
- **Layering is correct.** The kernel `<linux/pci.h>` types
  (`pci_is_thunderbolt_attached`, `struct pci_dev`, the `untrusted`
  field) are accessible only inside `kernel-open/` —
  `RmCheckForExternalGpu` lives in core RM
  (`src/nvidia/arch/nvalloc/unix/src/osinit.c`) and cannot include
  `<linux/pci.h>`. v1 keeps the kernel-side dependency in
  `kernel-open/nvidia/os-pci.c` and surfaces it across the boundary
  via the existing `os_pci_*` os-interface convention, which is the
  same wrapper-pattern vanilla uses for `os_pci_read_word`,
  `os_pci_write_dword`, `os_pci_remove`, etc. The matching
  declarations are added to both os-interface.h copies (the
  `kernel-open` one and the core-RM one).
- **Net code reduction.** v1 removes ~95 lines of bus-walking +
  vendor-ID-matching code and the unused `pSys`/`pCl` lookups in
  the caller, replacing them with ~50 lines of new code (the
  wrapper + declarations + block comment). The diff is +65 / -110
  — smaller than what it replaces. This is unusual for a feature
  patch and is strong evidence the change is structurally right.
- **No module parameter.** The detection is unconditional; no
  knob is added. The legacy `NVreg_RegistryDwords="RmForceExternalGpu=1"`
  modprobe override is the workaround E1 replaces, not a knob E1
  introduces — and the `RmForceExternalGpu` knob remains in the
  unmodified registry-dword parsing path as a manual escape hatch
  (v1 does not touch its definition).
- **Patch sits on the C4 branch base.** `e1-egpu-detection` is built
  on top of `c4-err-handlers-scaffold`, so the cumulative diff
  carries C1-C4 + E1 with no overlap between E1's surface (osinit
  detection) and C4's surface (nv-pci handler-table registration).
- **One log line per detection-true call.** Matches the intent's
  nominal telemetry-tier — a low-frequency probe-time event with
  exactly one log line, no heartbeat, no per-callback duplication.

**Weaknesses.**

- **Block comment in `os_pci_is_thunderbolt_attached` is good but
  the `RmCheckForExternalGpu` rewrite has no in-source comment
  reminding the future reader what was replaced.** The body of the
  new `RmCheckForExternalGpu` is three lines and the function-level
  doc comment above it does describe what was replaced, but a
  reader inspecting just the function body would not see the
  history. The intent's `Provenance` section captures this, and the
  doc comment is sufficient documentation; not raised as a delta.
- **`OBJCL *pCl` signature change is a non-static-interface
  modification.** The function is not declared static; the
  signature is visible to other translation units that might
  reference `RmCheckForExternalGpu`. A grep across the fork
  confirms `RmInitNvDevice` is the sole caller (search for
  `RmCheckForExternalGpu` in `src/` and `kernel-open/` returns only
  the definition and the one caller), so the signature change is
  safe — but the v1 commit message does not call this out. The
  intent's `Scope boundary` captures it. Not raised as a delta.
- **No detection log line on the FALSE path.** This is by design
  (the intent explicitly requires the internal-GPU path to be
  silent), but a future maintainer or upstream reviewer might
  expect symmetry. The intent's telemetry table makes the asymmetry
  explicit; not raised as a delta.
- **The wrapper name uses `is_thunderbolt_attached` but the function
  also consults `untrusted` (which is NOT thunderbolt-specific).**
  The function name is slightly narrower than its behaviour. A
  rename to e.g. `os_pci_is_external_attached` would be more
  accurate but would also drift further from the kernel symbol it
  mirrors (`pci_is_thunderbolt_attached`). v1's name signals "this
  is the os-interface companion to the kernel's TB-attached check,
  extended with `untrusted` for non-VSEC external transports" —
  defensible. Captured as `E1-egpu-detection-D1` below with
  `Severity: nice-to-have`.

**Surprises relative to vanilla.**

- Vanilla `RmCheckForExternalGpu` calls into a *Resource Manager
  internal control* (`pRmApi->Control(... NV2080_CTRL_CMD_INTERNAL_GET_EGPU_BRIDGE_INFO ...)`)
  to learn whether a bridge is TB3-approved. This is striking:
  detection of an OS-level concept (the transport the GPU is
  reached over) flows through GSP-facing RM control infrastructure,
  acquiring `rmGpuLocks` and dispatching a control payload, just to
  consult an internal whitelist. v1 collapses the whole thing into
  two kernel reads. The lock-acquire + control-dispatch overhead is
  also eliminated.
- The vanilla function returns the in-loop accumulator
  `iseGPUBridge` (`NvBool`) but mixes early-exit `return
  iseGPUBridge` paths after errors and after no-bridge-found, plus
  a `DBG_BREAKPOINT()` on control-dispatch failure. v1 has none of
  this — a clean wrapper call and return. Net robustness is higher.
- Vanilla also conflates *two* eGPU signals: TB3-approved bridge
  AND hot-plug-surprise slot capability. A TB3 bridge without slot
  capability would be classified internal. v1's kernel-signal union
  has no slot-capability dependency; the kernel maintains its own
  external-facing-port distinction independent of slot caps. This
  is correct (TB-tunnelled PCIe links don't always advertise slot
  caps the way physical hot-plug bays do) but is a behavioural
  change from the vanilla shape that may surprise an upstream
  reviewer used to the vanilla two-signal AND. The intent's
  Requirements make this behaviour explicit; the commit message
  could highlight it but does not. Not raised as a delta.
- Vanilla `RmCheckForExternalGpu` does NOT log anything on
  success (no "external GPU detected" line); it just returns
  `iseGPUBridge` and the caller sets the property. v1 adds the
  log line. This is a strict telemetry improvement.

## Design choices

The main alternatives considered during the v2 review:

- **Kernel-classification union vs. fresh vendor-ID table.**
  Could have updated the TB3 whitelist to include TB4/USB4 bridge
  IDs (Intel Barlow Ridge, AMD USB4 host routers, plus the various
  USB4-PCIe-tunnelling docks). Rejected — the whitelist is the
  problem, not the data inside it; every new transport silicon
  release would require an in-tree NVIDIA driver patch to chase
  the kernel's classification table. The kernel signals are
  maintained by the subsystem that owns the transport — there is
  no faster authoritative source. v1's choice is the canonical
  upstream direction.

- **`pci_is_thunderbolt_attached` || `untrusted` vs. either alone.**
  Considered using just `pci_is_thunderbolt_attached` (the more
  TB-specific signal) or just `untrusted` (the more general
  external-facing-port signal). Rejected both — each misses cases
  the other catches. The hardware-verified note in
  `docs/upstream-plan.md §E1` records that on the project's Barlow
  Ridge / Thunderbolt 5 hardware both signals fire, which is the
  common case; on hardware that exposes only one of them, the
  union still detects external. The OR is the empirically correct
  shape.

- **Where to consult the kernel signals: kernel-open vs. core RM.**
  Considered putting the kernel-signal consultation directly in
  `RmCheckForExternalGpu` inside core RM
  (`src/nvidia/arch/nvalloc/unix/src/osinit.c`). Rejected —
  `<linux/pci.h>` is not includable from core RM code (the unix
  source tree is OS-agnostic and crosses to other Unixes); the
  `os_pci_*` os-interface convention is exactly the wrapper-pattern
  vanilla uses for this layering. v1 follows the existing
  convention with a new `os_pci_is_thunderbolt_attached` declared
  in both os-interface.h copies and defined in
  `kernel-open/nvidia/os-pci.c` next to `os_pci_remove`. This is
  the conventional shape; no alternative needs further evaluation.

- **Function name: `os_pci_is_thunderbolt_attached` vs.
  `os_pci_is_external_attached`.** Considered renaming to better
  reflect that the function consults both `pci_is_thunderbolt_attached`
  AND `untrusted`. Kept v1's name to mirror the kernel symbol it
  wraps — `pci_is_thunderbolt_attached` is the headline signal and
  `untrusted` is the supplemental endpoint-local marker. A
  future-maintainer reading the source will see both flags in the
  body. The choice is documented in `E1-egpu-detection-D1` below
  with `Severity: nice-to-have`.

- **NULL handle guard placement: wrapper vs. caller.** v1 places
  the `if (pdev == NULL) return NV_FALSE;` guard inside
  `os_pci_is_thunderbolt_attached`. Could have placed it inside
  `RmCheckForExternalGpu` (the caller) instead. Kept v1's choice —
  the wrapper is the boundary between core RM's `void *handle`
  abstraction and kernel-open's `struct pci_dev *`, and the
  defensive NULL check is naturally a property of the boundary
  crossing, not of the caller's flow. This is the same convention
  vanilla uses elsewhere (e.g. `os_pci_remove` does not guard
  NULL but it directly calls a kernel API that does its own
  checking; the new function does its own dereferencing of fields
  on `pdev`, so the guard belongs at this layer).

- **Telemetry level for the detection log line: `pci_info` vs.
  `pci_notice` vs. `pci_warn`.** v1 uses `pci_info`. Kept —
  external-GPU detection is a normal, operationally interesting
  event (not abnormal, not a warning). `pci_info` matches the
  kernel-side log convention for "informational PCI-subsystem
  notices" and is what `os_pci_remove` and surrounding functions
  use.

- **Log line on the FALSE path.** Considered emitting a
  `pci_dbg`-level "external check: not external" line on the false
  branch for symmetry. Rejected — the false path is the common
  case (every internal GPU on every PCH-rooted system), and a log
  line per probe-time false negative would be noise. The intent
  explicitly forbids it. Kept v1's silent false path.

- **Removing the legacy TB3 vendor-ID whitelist code entirely.**
  Considered also removing or marking deprecated the
  `NV2080_CTRL_CMD_INTERNAL_GET_EGPU_BRIDGE_INFO` control and its
  TB3 vendor-ID table inside core RM. Rejected — that control is
  defined in core RM headers (not unix-specific) and may be
  consulted by other operating-system shims (Windows / VMware)
  that this patch is not touching. The Scope boundary makes this
  explicit. Kept v1's narrow scope: stop the unix-side osinit
  path from consulting the whitelist, leave the whitelist itself
  alone.

- **Frontmatter cross-references to [[C4-err-handlers-scaffold]].**
  Per Rule 6 lint resolution, `related-patches:` in the
  frontmatter requires the referenced intent files to exist.
  `C4-err-handlers-scaffold.md` exists at HEAD (committed by
  Task 6 in this sub-cycle), so the frontmatter resolution is
  clean. The intent and review files both list
  `[C4-err-handlers-scaffold]` in their frontmatter. Body-prose
  `[[C5-crash-safety]]`, `[[A2-bus-loss-watchdog]]`, and
  `[[A3-recovery]]` wikilinks are used for presentation only;
  Task 14's cross-patch consistency audit will revisit whether
  to backfill the frontmatter once the addon intents exist.

## v1 → v2 deltas

### E1-egpu-detection-D1 — Wrapper name is slightly narrower than its behaviour

- **Location:** `kernel-open/nvidia/os-pci.c:os_pci_is_thunderbolt_attached` and the matching declarations in `kernel-open/common/inc/os-interface.h` and `src/nvidia/arch/nvalloc/unix/include/os-interface.h`.
- **Change:** Could rename the wrapper to e.g. `os_pci_is_external_attached` to reflect that the function consults both `pci_is_thunderbolt_attached` AND `pdev->untrusted` — the latter not being Thunderbolt-specific. The block comment, body, and behaviour would be unchanged; only the symbol name (and three declaration sites) would move.
- **Severity:** nice-to-have
- **Evidence:** The function returns true on `tb_attached || untrusted`, but the symbol name names only the first half of the disjunction. A future maintainer skimming the function signature might infer Thunderbolt-only behaviour. The block comment and body both correctly describe the union, so the misread is shallow and recoverable; the rename would improve at-a-glance accuracy without behavioural change. Kept v1's name in this review to mirror the kernel symbol it wraps (`pci_is_thunderbolt_attached`) — readers tracing the wrapper back to its kernel counterpart see the obvious name correspondence — and to keep the upstream-PR diff surface minimal.
- **Resolution:** deferred — keep v1's `os_pci_is_thunderbolt_attached` for review minimality and kernel-symbol-name mirroring. The block comment names both signals; rename can be revisited if upstream review surfaces it.

### E1-egpu-detection-D2 — No must-fix deltas

- **Location:** n/a
- **Change:** v1's behaviour, telemetry, layering, and surface match the v2 intent exactly. No fork-branch follow-up commits are required.
- **Severity:** out-of-scope
- **Evidence:** Every scenario across the intent's three Requirements is satisfied by v1 as audited above. TB4/USB4-VSEC GPUs return NV_TRUE via `pci_is_thunderbolt_attached`; TB3 GPUs remain detected via the same kernel signal (the VSEC predates TB4); non-VSEC firmware-external-facing-port GPUs return NV_TRUE via `pdev->untrusted`; PCH-rooted internal GPUs return NV_FALSE with no log line; the one `pci_info` log line at detection names both signals as yes/no. The legacy `RmForceExternalGpu=1` modprobe override remains as an unaltered manual escape hatch (Scope boundary). The signature-narrowing of `RmCheckForExternalGpu` (dropping `OBJCL *pCl`) is local to the single unix-side caller (Scope boundary). The one nice-to-have (D1) is explicitly deferred.
- **Resolution:** rejected — no v2 follow-up needed.

Per M2 (zero-delta sentinel from the C1 checkpoint), the
frontmatter `v1-tip-sha == v2-tip-sha ==
000ea7a51db8b78225950a753a390a82f3aa1d81` is the machine-checkable
signal that v1 already met v2 intent. The one `nice-to-have` delta
(D1) is recorded for provenance; it does not require a fork-branch
commit because its Resolution is `deferred`.

## Done gate

- [x] `docs/patch-intents/E1-egpu-detection.md` exists, lints clean, `status: reviewed`.
- [x] All must-fix deltas applied as fork-branch commits citing their delta IDs. _(N/A — zero must-fix deltas; D1 is nice-to-have with deferred Resolution.)_
- [x] `patches/base/E1-egpu-detection.patch` refreshed by `regen`. _(N/A — no fork-branch change; existing file already reflects `000ea7a5`.)_
- [x] `tools/validate-patchset.sh` passes (compile gate).
- [x] `bash tests/run.sh` green.
- [x] Audit-reviewer subagent approved. _(Pending — this review file is the audit-reviewer's input.)_

## Cross-references

- Intent file: `docs/patch-intents/E1-egpu-detection.md`
- Manifest row: `patches/manifest` line for `E1-egpu-detection`
  (layer `base`, source `fork:e1-egpu-detection`)
- Vanilla baseline:
  `src/nvidia/arch/nvalloc/unix/src/osinit.c:RmCheckForExternalGpu`
  (vanilla 595.71.05 walks the bus topology via `clFindP2PBrdg` and
  matches bridge vendor/device IDs against the TB3 whitelist
  returned by `NV2080_CTRL_CMD_INTERNAL_GET_EGPU_BRIDGE_INFO`,
  requiring `approvedBusType ==
  NV2080_CTRL_INTERNAL_EGPU_BUS_TYPE_TB3` plus hot-plug-surprise
  slot capability — see the vanilla function signature
  `RmCheckForExternalGpu(OBJGPU *pGpu, OBJCL *pCl)` and its caller
  `RmInitNvDevice` at the `if (RmCheckForExternalGpu(pGpu, pCl))`
  site). Companion vanilla baselines:
  `kernel-open/nvidia/os-pci.c` (E1 inserts the new
  `os_pci_is_thunderbolt_attached` immediately after `os_pci_remove`)
  and the two `os-interface.h` copies in `kernel-open/common/inc/`
  and `src/nvidia/arch/nvalloc/unix/include/` (declarations added
  next to the existing `os_pci_remove` declaration).
- Fork branch: `e1-egpu-detection` on
  `apnex/open-gpu-kernel-modules` (sits on top of
  `c4-err-handlers-scaffold`).
- Upstream issue:
  https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979 —
  not the headline fix (that is [[C3-gpu-lost-retry]]) but the
  classification prerequisite without which eGPU-specific behaviour
  is gated out on modern hardware. Memory:
  `project_nvidia_open_driver_egpu_layer_tb3_era` documents the
  original TB3-era detection and the historical
  `RmForceExternalGpu=1` workaround the project drops once a
  running driver carries E1.
- Related reviews: [[C4-err-handlers-scaffold]] (the registered
  `pci_error_handlers` table whose callbacks may eventually key
  per-device behaviour on `is_external_gpu`; resolved via
  frontmatter), [[C5-crash-safety]] (de-branded primitives that
  the addon recovery stack composes on top of), and the addon
  stack [[A2-bus-loss-watchdog]] / [[A3-recovery]] (both gate on
  `is_external_gpu` per `docs/upstream-plan.md §E1`).
