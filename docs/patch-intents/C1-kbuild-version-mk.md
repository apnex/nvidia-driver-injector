---
id: C1-kbuild-version-mk
layer: base
source-branch: c1-kbuild-version-mk
upstream-candidacy: high
telemetry-tier: none
status: reviewed
related-patches: []
---

# C1-kbuild-version-mk — Single Source of Truth for NV_VERSION_STRING

## Purpose

The vanilla `kernel-open/Kbuild` hardcodes the literal `595.71.05` in a
`-DNV_VERSION_STRING=\"595.71.05\"` ccflag, duplicating the
`NVIDIA_VERSION` value already defined in the repo-root `version.mk`. The
two strings can drift independently — historically observed in the
legacy patch stack, where Kbuild remained pinned at `aorus.5` while
`version.mk` advanced to `aorus.10`, so `modinfo`'s `version:` field
silently reported a stale build identifier. This patch makes Kbuild
include `../version.mk` and derive `NV_VERSION_STRING` from
`$(NVIDIA_VERSION)`, so `version.mk` becomes the single source of truth
for the module version string and downstream consumers (`modinfo`,
`nvidia-smi --version`, kernel log banners) cannot drift from it.

## Requirements

### Requirement: Module version string equals version.mk's NVIDIA_VERSION

After a successful build, the compiled module SHALL embed the exact
string assigned to `NVIDIA_VERSION` in the repo-root `version.mk`, with
no transformation. The `modinfo` `version:` field MUST equal that
string. The hardcoded literal `595.71.05` MUST NOT appear in
`kernel-open/Kbuild`.

#### Scenario: Default build matches version.mk
- **GIVEN** `version.mk` defines `NVIDIA_VERSION = 595.71.05`
- **WHEN** `make modules` runs against an unmodified `kernel-open/`
- **THEN** the resulting `nvidia.ko` MUST report
  `version: 595.71.05` under `modinfo`
- **AND** the string `-DNV_VERSION_STRING=\"595.71.05\"` MUST NOT
  appear in the recorded `nv.o.cmd` (no hardcoded literal)

#### Scenario: Version bump in version.mk propagates without manual edits
- **GIVEN** a developer edits `version.mk` to
  `NVIDIA_VERSION = 595.71.05-aorus.14`
- **WHEN** they run `make modules` in the same build tree (no
  `make clean`)
- **THEN** kbuild's `.cmd` hashing MUST detect the expanded `-D` value
  changed
- **AND** `nv.o` MUST be rebuilt
- **AND** the resulting module's `modinfo version:` MUST equal
  `595.71.05-aorus.14`
- **AND** no edit to `kernel-open/Kbuild` SHALL be required to achieve
  this

### Requirement: version.mk include is purely additive

The patch SHALL touch only `kernel-open/Kbuild`. It MUST NOT modify
`version.mk` itself, MUST NOT add new build-system files, and MUST NOT
change any other ccflag, define, include path, or conditional. The
include of `../version.mk` MUST be guarded by `$(src)`-relative pathing
so the build works regardless of the caller's cwd.

#### Scenario: Patch surface is one file, additive only
- **GIVEN** the patch is applied to a clean `595.71.05` tree
- **WHEN** `git diff 595.71.05 -- kernel-open/` runs
- **THEN** exactly one file (`kernel-open/Kbuild`) MUST appear in the
  diff
- **AND** the diff MUST replace exactly the one hardcoded
  `-DNV_VERSION_STRING` line with an `include $(src)/../version.mk`
  plus a `-DNV_VERSION_STRING=\"$(NVIDIA_VERSION)\"` substitution
- **AND** no other line in `kernel-open/Kbuild` MUST be modified

## Scope boundary

- This patch does NOT introduce or modify any project-specific suffix
  (e.g. `-aorus.N`). Setting such a suffix is the responsibility of
  the addon patch [[A5-version-and-toggles]], which edits
  `version.mk`'s `NVIDIA_VERSION` directly.
- Out-of-scope: deriving any OTHER version-related macro (e.g.
  `NV_BUILD_BRANCH_VERSION`, `NV_BUILD_DATE`) from `version.mk`. This
  patch covers only `NV_VERSION_STRING`.
- Out-of-scope: rewriting `version.mk`'s schema or adding new
  variables to it.

## Telemetry contract

_No runtime telemetry — build-time metadata only._

## Provenance

- **Source cluster:** Distilled from the legacy patch stack as the
  clean deduplication-only carve-out. The legacy origin of the
  hardcoded-literal pattern is
  `patches/legacy/0005-version-mark-aorus-build.patch` and
  `patches/legacy/0007-tb-egpu-version-mark-and-kbuild.patch`; the
  drift-fix that this C1 patch directly continues is
  `patches/legacy/0025-Kbuild-version-from-version-mk.patch`.
- **Vanilla baseline:** `kernel-open/Kbuild` (the
  `-DNV_VERSION_STRING` ccflag near line 82 of the vanilla 595.71.05
  file).
- **Fork branch:** `c1-kbuild-version-mk` on
  `apnex/open-gpu-kernel-modules`.
- **Upstream issue:** n/a (standalone build-system cleanup; candidate
  for upstream as an independent PR).
