---
id: A5-version-and-toggles
layer: addon
source-branch: a5-version-and-toggles
upstream-candidacy: n/a
telemetry-tier: none
status: reviewed
related-patches: []
---

# A5-version-and-toggles — Project Branding Suffix and Reserved `CONFIG_NV_TB_EGPU` Master Toggle

## Purpose

A5 SHALL stamp the running driver with the project's `-aorus.NN`
branding suffix on `NV_VERSION_STRING` (consumed by
[[C1-kbuild-version-mk]]'s `version.mk`-as-single-source-of-truth
plumbing and surfaced verbatim by `modinfo`, `nvidia-smi --version`,
and the kernel log banner) AND SHALL declare the project's
`CONFIG_NV_TB_EGPU` Kconfig-style master toggle in `kernel-open/Kbuild`
as a reserved-for-future-use documentation symbol with a `-D` macro
visible to every translation unit in `nvidia.ko`. The persistent
capability A5 grants the driver is "every running build carries
an unambiguous project identity in `modinfo`, and every translation
unit observes a single canonical macro that future addon-stack work
can `#ifdef` against without re-litigating the toggle's name or
default". A5 does NOT gate any source-list row today — the addon
source files ([[A1-pcie-primitives]], [[A2-bus-loss-watchdog]],
[[A3-recovery]], [[A4-close-path-telemetry]]) compile unconditionally
in v1; the master toggle is forward-looking infrastructure whose
in-source documentation explicitly records "Currently reserved as
a documentation-only symbol — gating P1-P5 out would require
wrapping all eGPU additions across multiple clusters in #ifdef,
out of scope for the refactor". A5's truthful "symbol-only, not
gating" stance supersedes any aspirational gate-A4 / gate-A1
prose that earlier reviews (A1-D2, A4-D3) deferred to A5's
adjudication.

## Requirements

### Requirement: Driver SHALL stamp `NVIDIA_VERSION` with the project's `-aorus.NN` branding suffix

The driver SHALL define `NVIDIA_VERSION` in `version.mk` as
`595.71.05-aorus.NN` where `NN` is the project's running build
counter (currently `14` per
`project_addon_recarve_merged_2026_05_22`). The version string
MUST consist of the upstream NVIDIA release number
(`595.71.05`) verbatim, followed by `-aorus.` followed by a
zero-padded or unpadded decimal counter. The `NVIDIA_NVID_VERSION`
and `NVIDIA_NVID_EXTRA` fields MUST remain at their vanilla
values (`595.71.05` and empty) — the project's branding is
attached only to the user-visible `NVIDIA_VERSION` string, not to
the NVID-tracker fields. This Requirement is satisfied by edits
to `version.mk` only; no other build-system file participates in
the suffix application. The Kbuild plumbing that propagates
`$(NVIDIA_VERSION)` to `-DNV_VERSION_STRING` is owned by
[[C1-kbuild-version-mk]] — A5 piggybacks on it without modifying
it.

#### Scenario: Built module carries the `-aorus.NN` suffix in modinfo
- **GIVEN** `version.mk` defines `NVIDIA_VERSION = 595.71.05-aorus.14`
- **AND** the C-set and addon stack are composed against the kernel
- **WHEN** the build completes and the operator runs
  `modinfo nvidia.ko | grep '^version:'`
- **THEN** the output line MUST read exactly
  `version:        595.71.05-aorus.14` (the suffix MUST appear
  verbatim, no truncation, no rewriting)
- **AND** `dmesg | grep 'NVRM: loading'` MUST emit the same
  suffix in the kernel-log banner at module load
- **AND** the `NVIDIA_NVID_VERSION` field in `version.mk` MUST
  still read `595.71.05` (suffix MUST NOT bleed into the NVID
  tracker fields)

#### Scenario: Version bump increments the counter only
- **GIVEN** the project is preparing the next aorus build (the
  fork branch reaches a new C+E+A composition tip)
- **WHEN** the engineer edits `version.mk` to bump the suffix
  from `-aorus.14` to `-aorus.15`
- **THEN** the diff MUST touch only the `NVIDIA_VERSION` line of
  `version.mk`
- **AND** no edit to `kernel-open/Kbuild` SHALL be required (the
  `-D` macro derives the value via [[C1-kbuild-version-mk]]'s
  `$(NVIDIA_VERSION)` expansion)
- **AND** the rebuilt module MUST report
  `version: 595.71.05-aorus.15` under `modinfo`

### Requirement: Driver build SHALL declare the `CONFIG_NV_TB_EGPU` reserved master toggle and emit the corresponding `-D` macro

The driver build SHALL declare `CONFIG_NV_TB_EGPU` in
`kernel-open/Kbuild` as a make variable defaulting to `y` (via
`CONFIG_NV_TB_EGPU ?= y` so the developer or build orchestrator
can override on the make command line) and SHALL emit
`-DCONFIG_NV_TB_EGPU` to `ccflags-y` when (and only when) the
variable evaluates to `y`. The declaration MUST sit immediately
after the `ccflags-y += -DNV_VERSION_STRING=\"$(NVIDIA_VERSION)\"`
block (after [[C1-kbuild-version-mk]]'s `include
$(src)/../version.mk` line) and MUST be wrapped in a Kconfig-style
in-source comment block stating that the symbol is "Currently
reserved as a documentation-only symbol" and that "gating P1-P5
out would require wrapping all eGPU additions across multiple
clusters in #ifdef, out of scope for the refactor". The toggle
SHALL NOT gate any `NVIDIA_SOURCES += ...` row or any
`NVIDIA_UVM_SOURCES += ...` row in v1 — the addon source-list
rows compile unconditionally. The `-D` macro IS observable to
every C translation unit in `nvidia.ko` so that future
addon-stack work MAY `#ifdef CONFIG_NV_TB_EGPU` an individual
function body or call site without further build-system work.

#### Scenario: Default build emits `-DCONFIG_NV_TB_EGPU` to every nvidia.ko object
- **GIVEN** the developer does not override `CONFIG_NV_TB_EGPU`
  on the make command line
- **WHEN** `make modules` runs
- **THEN** the recorded `.cmd` files for `nvidia.ko`'s object
  files (e.g. `nv.o.cmd`, `nv-tb-egpu-pcie.o.cmd`,
  `nv-tb-egpu-recover.o.cmd`) MUST contain `-DCONFIG_NV_TB_EGPU`
- **AND** the addon source files MUST compile successfully whether
  or not they actually use the macro (v1 source files do NOT
  reference the macro; the `-D` is forward infrastructure only)
- **AND** the build MUST succeed regardless

#### Scenario: Override-to-empty drops the `-D` macro but does not exclude any source file
- **GIVEN** the developer runs
  `make modules CONFIG_NV_TB_EGPU=n` (or `CONFIG_NV_TB_EGPU=`)
- **WHEN** the build executes
- **THEN** the `-DCONFIG_NV_TB_EGPU` macro MUST NOT appear in any
  `.cmd` file
- **AND** the `NVIDIA_SOURCES += nvidia/nv-tb-egpu-pcie.c`,
  `nv-tb-egpu-qwd.c`, `nv-tb-egpu-recover.c`, `nv-tb-egpu-close.c`,
  and `NVIDIA_UVM_SOURCES += nvidia-uvm/nv-tb-egpu-uvm.c` rows
  MUST still be in effect (all five files MUST still compile and
  link)
- **AND** the resulting `nvidia.ko` MUST be functionally
  equivalent to a `CONFIG_NV_TB_EGPU=y` build because no v1 code
  path conditionalises on the macro
- **AND** the in-source comment block describing the symbol as
  "reserved as a documentation-only symbol" MUST accurately
  describe this property — the build outcome MUST match the
  documented stance

#### Scenario: In-source comment block accurately describes the toggle's actual behaviour
- **GIVEN** a reviewer reads `kernel-open/Kbuild` around the
  `CONFIG_NV_TB_EGPU` declaration
- **WHEN** the reviewer compares the comment block's claims
  against the actual Kbuild and source-list behaviour
- **THEN** the comment MUST state that the symbol is currently
  documentation-only / reserved
- **AND** the comment MUST state that real gating of P1-P5
  source files is out of scope for the refactor
- **AND** the comment's stance MUST NOT be contradicted by any
  conditional source-list row anywhere in the patchset (i.e. no
  `NVIDIA_SOURCES += ...` row is wrapped in
  `ifeq ($(CONFIG_NV_TB_EGPU),y) ... endif`)
- **AND** the toggle's existence MUST NOT prevent a future
  in-source `#ifdef CONFIG_NV_TB_EGPU` from working when a
  consumer addon adopts it

## Scope boundary

- This patch deliberately does NOT gate any
  `NVIDIA_SOURCES += ...` or `NVIDIA_UVM_SOURCES += ...` row on
  `CONFIG_NV_TB_EGPU`. The addon source files
  ([[A1-pcie-primitives]], [[A2-bus-loss-watchdog]],
  [[A3-recovery]], [[A4-close-path-telemetry]]) compile
  unconditionally in v1. The aspirational claim in
  [[A4-close-path-telemetry]]'s review prose that "A5's
  `CONFIG_NV_TB_EGPU` master toggle gates A4's source-list rows"
  is a v2-review-time misreading of v1 reality; A5's truthful
  stance (this intent) is the canonical contract. Pushing the
  gate down to the source-list rows would require either (a)
  wrapping individual rows in `ifeq` blocks AND ensuring no
  cross-row link dependency surfaces (A4-D3 documented the lockstep
  requirement for A4's RM + UVM rows because of the
  `EXPORT_SYMBOL_GPL` / `extern` pair; the same risk exists for any
  partial-addon subset), or (b) wrapping every addon source file
  body in `#ifdef CONFIG_NV_TB_EGPU ... #endif`. Neither is in
  scope for sub-cycle 2.
- This patch does NOT modify the `version.mk` mechanics — the file's
  schema (`NVIDIA_VERSION`, `NVIDIA_NVID_VERSION`,
  `NVIDIA_NVID_EXTRA`, the `version.h` recipe) is vanilla NVIDIA
  shape. A5 edits only the `NVIDIA_VERSION` value.
- This patch does NOT modify the kbuild include of
  `$(src)/../version.mk` or the `-DNV_VERSION_STRING=\"...\"`
  derivation. Those changes are owned by [[C1-kbuild-version-mk]]
  and pre-date A5 in the fork-branch sequence (C1 is base, A5 is
  addon-stack tip). A5 cooperates with C1 by editing the value
  that C1's plumbing reads.
- This patch does NOT introduce any module parameter
  (`NVreg_*`). The runtime-disable knobs for individual addons
  live in [[A2-bus-loss-watchdog]] (`NVreg_TbEgpuQwdEnable`) and
  [[A3-recovery]] (`NVreg_TbEgpuRecoverEnable`); A5 is build-time
  metadata only.
- This patch does NOT introduce any runtime log line or telemetry
  surface. The `NV_VERSION_STRING` value is printed at module
  load by existing vanilla NVIDIA infrastructure (the kernel-log
  banner emitted from `nv.c`'s module init); A5 only changes the
  value being printed. The `CONFIG_NV_TB_EGPU` macro is
  build-only and emits nothing at runtime.
- This patch does NOT introduce a Kconfig file
  (`drivers/.../Kconfig`). The toggle is a make variable in
  `kernel-open/Kbuild` only; out-of-tree NVIDIA builds do not
  participate in the kernel's Kconfig system, and inventing a
  fragmentary Kconfig would mislead readers about the toggle's
  actual integration.
- This patch does NOT alter the semantics of any A1-A4 surface.
  The addon stack's runtime behaviour is identical with or
  without `CONFIG_NV_TB_EGPU=y` because no v1 code path
  conditionalises on the macro. A5 is purely additive metadata.

## Telemetry contract

_No runtime telemetry — version metadata and reserved build-time
toggle only. The `NV_VERSION_STRING` value surfaces in vanilla
NVIDIA's existing module-load banner and in `modinfo`, neither
of which A5 modifies; the `CONFIG_NV_TB_EGPU` symbol is a
`ccflags-y` `-D` macro with no source-file consumer in v1._

## Provenance

- **Source cluster:** Distilled from the legacy patches that
  established the project's branding (`patches/legacy/0005-version-mark-aorus-build.patch`,
  `patches/legacy/0007-tb-egpu-version-mark-and-kbuild.patch`)
  and the original `CONFIG_NV_TB_EGPU` toggle stub introduced in
  the same legacy generation. The 2026-05-12 patch refactor
  (`project_patch_refactor_2026_05_12`) consolidated the
  branding edits into a single addon patch, and the 2026-05-22
  addon-recarve campaign (`project_addon_recarve_merged_2026_05_22`)
  finalised A5's geometry as the master toggle plus version
  suffix — explicitly NOT a real source-list gate, matching the
  in-source comment block's "reserved as a documentation-only
  symbol" language.
- **Vanilla baseline:**
  - `version.mk` — vanilla 595.71.05 sets `NVIDIA_VERSION =
    595.71.05`; A5 changes this one assignment to
    `NVIDIA_VERSION = 595.71.05-aorus.14`. No other line in
    `version.mk` is touched.
  - `kernel-open/Kbuild` — vanilla 595.71.05 hardcodes
    `ccflags-y += -DNV_VERSION_STRING=\"595.71.05\"`;
    [[C1-kbuild-version-mk]] replaces this with an `include
    $(src)/../version.mk` + `-DNV_VERSION_STRING=\"$(NVIDIA_VERSION)\"`
    pair. A5 inserts a new block immediately after that pair: a
    Kconfig-style comment block plus the `CONFIG_NV_TB_EGPU ?= y`
    declaration plus an `ifeq ($(CONFIG_NV_TB_EGPU),y) ccflags-y
    += -DCONFIG_NV_TB_EGPU endif` conditional. No other line in
    `kernel-open/Kbuild` is touched.
- **Patch surface:** Exactly two files modified, 14 net lines
  added (1 line on `version.mk` for the suffix; 13 lines on
  `kernel-open/Kbuild` for the comment block + declaration +
  conditional `-D` emit).
- **Fork branch:** `a5-version-and-toggles` on
  `apnex/open-gpu-kernel-modules` (sits on top of
  `a4-close-path-telemetry`; the cumulative diff at A5's tip
  carries C1-C5 + E1 + A1 + A2 + A3 + A4 + A5).
- **Adjudication of upstream contracts (sub-cycle 2):**
  - **A1-D2 collapses.** [[A1-pcie-primitives]]'s D2 ("gate
    A1's source-list line on `CONFIG_NV_TB_EGPU`?") was
    deferred to A5's review. The adjudication is "no gate" —
    A1's source-list row stays unconditional, consistent with
    A2/A3/A4. The collapse is because v1's `CONFIG_NV_TB_EGPU`
    is documentation-only; there is no source-list-row gate
    anywhere in the stack, so the question of whether A1 is
    "also" gated is moot. If a future sub-cycle adopts
    real source-list gating, the A1 question can be re-litigated
    then.
  - **A4-D3 is honoured by accurate description, not by code
    change.** A4's review prose stated that A5's toggle "gates
    A4's source-list rows in lockstep". v1 does NOT do this; the
    prose is corrected here. A5's intent and review honestly
    describe the toggle as reserved/documentation-only, so
    A4-D3's lockstep concern about RM vs UVM source-list rows
    is preserved as future-design context (the right way to gate
    A4 if a future cycle decides to is to wrap BOTH rows
    together) but is not exercised in v1.
- **Upstream issue:** n/a. Addon-layer branding and project-local
  toggles are never upstream-bound (per Rule 5:
  `upstream-candidacy: n/a` is the only allowed value for
  `layer: addon`). The `-aorus.NN` suffix is by definition
  project-local; the `CONFIG_NV_TB_EGPU` macro is project-local
  infrastructure for the addon stack and would not exist in any
  upstream consumer.
