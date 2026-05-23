---
id: C1-kbuild-version-mk
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: dce2a1148b0986205d74db7a10ebf9c6d01f83b7
v2-tip-sha: 6d118726fb1aa31386e812ac9fcd535ca4e21bb2
status: accepted
intent-updates: []
---

# C1-kbuild-version-mk — improvement triage

## Triangulation sources

- **Vanilla NVIDIA 595.71.05:** `kernel-open/Kbuild:82` — single line `ccflags-y += -DNV_VERSION_STRING=\"595.71.05\"`. Repo-root `version.mk:1` defines `NVIDIA_VERSION = 595.71.05` independently. The two are decoupled.
- **v2 intent:** `/root/nvidia-driver-injector/docs/patch-intents/C1-kbuild-version-mk.md` (two Requirements: module version string equals `version.mk`'s `NVIDIA_VERSION` + version.mk include is purely additive; two Scenarios on Requirement 1, one Scenario on Requirement 2).
- **v2 review:** `/root/nvidia-driver-injector/docs/patch-reviews/C1-kbuild-version-mk.md` (zero must-fix deltas; **no deferrals at all** — review notes "no weaknesses surfaced").
- **Fork branch tips:** v1 = `dce2a1148b0986205d74db7a10ebf9c6d01f83b7`; v2 = `6d118726fb1aa31386e812ac9fcd535ca4e21bb2` (advances by 1 v3 commit `C1-kbuild-version-mk-I1`); both on `apnex/open-gpu-kernel-modules` branch `c1-kbuild-version-mk`.
- **aorus-5090 ancestor patch:** `/root/aorus-5090-egpu/patches/0025-Kbuild-version-from-version-mk.patch` — the direct mechanism ancestor (the drift-fix that this C1 patch continues). The earlier `patches/0005-version-mark-aorus-build.patch` is the **drift-introducing** ancestor (it edits both Kbuild and `version.mk` to the same literal `595.71.05-aorus.5`, which set up the drift trap that 0025 later closed).
- **aorus-5090 docs:**
  - `/root/aorus-5090-egpu/docs/lever-catalog.md:353-373` (Lever M-recover patch list — entry for Patch 0025 + the upstream-readiness note flagging 0025 as "the cleanest standalone candidate for upstreaming").
  - `/root/aorus-5090-egpu/docs/architecture-and-modularity.md:84-100` (L1 currently-hosts table — line 88 entry for Patch 0005: "string only, no logic — necessary in fork to track which patches are present"; corroborates C1's sovereignty posture).
  - `/root/aorus-5090-egpu/docs/patched-driver-runbook.md:40-118` (build-time identity check via `modinfo`'s `version:` + `srcversion:` fields — anchors the runtime consumer C1's intent names).
  - **Binding M1+M2 verification:** the task header named `patched-driver-runbook.md` and `recommended-install-path.md` as candidate docs. `patched-driver-runbook.md` is relevant (operator-side consumer of the version string). `recommended-install-path.md` is NOT relevant (BIOS + kernel cmdline + boot sequencing; never touches Kbuild or version handling) — dropped per M1+M2. Added `lever-catalog.md:353-373` and `architecture-and-modularity.md:84-100` as omitted-but-relevant context.
- **Community-signal entries:** `/root/nvidia-driver-injector/docs/patch-improvements/_community-signal.md:135` — "No findings tagged for: `C1` (Kbuild/version.mk)". The only adjacent signal is line 34 (rvn2p cross-distro success on Debian sid) which weakly validates that the `$(src)/../version.mk` include path is portable across distros. Per M5: this is **upstream-PR-rationale strengthening** (the patch ports cleanly) rather than evidence of a patched-code-path bug.

## v1 archaeology

What the aorus-5090 mining surfaced about C1's mechanism ancestor (Patch 0025):

- **Original design intent — why 0025 exists.** `docs/lever-catalog.md:355` and the 0025 commit-message body itself (`patches/0025-Kbuild-version-from-version-mk.patch:5-15`) document the genesis: "Prior to this, patch 0005 hardcoded the literal '595.71.05-aorus.5' as -DNV_VERSION_STRING in kernel-open/Kbuild AND set NVIDIA_VERSION = 595.71.05-aorus.5 in version.mk. Subsequent patches (0016/0017/0018/0020) bumped only version.mk and the strings drifted: Kbuild stayed at aorus.5 while version.mk reached aorus.10, so modinfo's version: field reported aorus.5 even after multiple aorus.N bumps." 0025 was discovered as a **drift-bug fix during Patch 0024 verification**, not as forward design.
- **Constraint discovered — the `.cmd`-hashing rebuild guarantee is load-bearing.** `patches/0025-Kbuild-version-from-version-mk.patch:33-41` (the **in-file comment** the aorus author chose to commit alongside the mechanism) explicitly captures: "kbuild's .cmd hashing detects the expanded -D value changing and rebuilds nv.o accordingly, so a bare `make modules` after a version.mk bump produces the correct modinfo without `make clean`." This is the **non-obvious dynamic correctness invariant** of the patch — without it a future maintainer cannot tell whether a bare `make modules` after a `version.mk` bump will pick up the new version, or whether `make clean` is required first. The aorus author judged this load-bearing enough to bake into the in-file comment block, not just the commit message.
- **Constraint discovered — the include path must use `$(src)/...`.** `patches/0025-Kbuild-version-from-version-mk.patch:42` uses `include $(src)/../version.mk` exactly. The C1 v2 review (review file lines 56-60) names the rationale: "For out-of-tree NVIDIA builds, `$(src)` resolves to `<source-root>/kernel-open`, which makes `$(src)/..` the repo root — the correct location of `version.mk`." A bare relative include `../version.mk` would break `O=...` out-of-tree builds. The intent already captures this as "MUST be guarded by `$(src)`-relative pathing so the build works regardless of the caller's cwd" (intent Requirement 2). Cross-checked by rvn2p's Debian-sid cross-distro success (`_community-signal.md` entry 3 lines 30-34) — the include resolves correctly on a different distro's build layout.
- **Alternatives considered + rejected — read with `$(shell grep)` instead of `include`.** The v2 review (review lines 85-91) records this alternative explicitly: "`$(shell grep)` would bypass make's dependency tracking and be more brittle. Chose `include` (matches v1)." The aorus 0025 patch and v1 both arrive at `include`. The dependency tracking is what produces the `.cmd`-hashing rebuild guarantee — bypassing it would silently re-introduce the very drift-trap C1 is designed to eliminate.
- **Alternatives considered + rejected — derive other version macros (`NV_BUILD_BRANCH_VERSION`, `NV_BUILD_DATE`) at the same time.** `docs/patch-reviews/C1-kbuild-version-mk.md:99-105` records this consideration: "The other macros are set by NVIDIA's release tooling and do not have a `version.mk` counterpart today, so there is nothing to dedupe." The aorus 0025 ancestor also derived only `NV_VERSION_STRING`. Scope is pinned in C1's intent Scope boundary.
- **Forgotten / latent invariant — sovereignty of the change.** `docs/architecture-and-modularity.md:88` documents the L1 home for the version-mark family: "string only, no logic — necessary in fork to track which patches are present." The version string mechanism MUST live inside the fork because no upper layer (L2 companion module, L3 udev, L4 helpers) has access to the kbuild compilation step. This invariant is implicit in the intent ("This patch SHALL touch only `kernel-open/Kbuild`") but the *reason* — kbuild compilation has no L2+ surface — is in the architecture doc only. Not material for a v3 lift; the intent's "exactly one file" constraint already pins the surface.
- **Forgotten / latent invariant — Kconfig-toggle carve-out.** `/root/nvidia-driver-injector/patches/legacy/0007-tb-egpu-version-mark-and-kbuild.patch` (the P7 refactor cluster) combined `version.mk` dedup with Kconfig toggle wiring (`CONFIG_NV_TB_EGPU`, `CONFIG_NV_TB_EGPU_DIAG`). The current C1 carves away **just** the dedup. The Kconfig toggles live in addon A5 (verified: `grep CONFIG_NV_TB_EGPU patches/addon/A5-version-and-toggles.patch` hits four lines). This carve is correct — C1 must stay upstream-clean (no project-specific Kconfig), and the toggles are project-specific. The C1 intent does not explicitly document the carve relationship to A5; that's fine because the intent's Scope boundary already names A5 as the home for project-specific version suffixes. No v3 lift needed.

## Improvements considered

### C1-kbuild-version-mk-I1 — Lift the `.cmd`-hashing rebuild guarantee from the commit message into the in-file comment

- **Lens:** invariant clarity / quality
- **Current state:** v1's in-file comment in `kernel-open/Kbuild` is 3 lines:
  ```
  # Derive NV_VERSION_STRING from the repo-root version.mk so the module
  # version string has a single source of truth and cannot drift from a
  # hardcoded Kbuild literal.
  ```
  This captures the **static** invariant (single source of truth) but omits the **dynamic** invariant: that `make modules` after a `version.mk` bump correctly picks up the new value without `make clean`. The dynamic guarantee is documented in the v1 commit message (commit `dce2a114` body lines 12-15), in intent Scenario 2 (lines 45-56), and in the v2 review (review lines 64-68) — but not in the file the maintainer reads when staring at the Kbuild include.
- **Proposed state:** Extend the in-file comment by two lines to lift the rebuild guarantee (matching the aorus 0025 ancestor's in-file comment verbatim in spirit):
  ```
  # Derive NV_VERSION_STRING from the repo-root version.mk so the module
  # version string has a single source of truth and cannot drift from a
  # hardcoded Kbuild literal. kbuild's .cmd hashing detects the expanded
  # -D value changing, so `make modules` after a NVIDIA_VERSION bump
  # rebuilds nv.o and produces correct modinfo without `make clean`.
  ```
- **Value:** A future maintainer reading the in-file comment alone can answer the only non-obvious operational question about this mechanism ("if I bump `version.mk`, do I need `make clean`?") without consulting the commit message, the intent, or the review. The aorus ancestor (`patches/0025-Kbuild-version-from-version-mk.patch:33-41`) judged this load-bearing enough to embed in-file; v1 currently understates the in-file documentation relative to the proven ancestor.
- **Cost:** +2 comment lines in one file. No semantic diff against vanilla beyond comment surface (the include + the substitution are identical). All intent Scenarios still pass — Scenario "Patch surface is one file, additive only" specifically constrains the include + substitution lines, not the surrounding comment block (intent lines 67-74). The intent's Requirement 2 ("the patch SHALL touch only `kernel-open/Kbuild`") is satisfied.
- **Verification mode:** A (code-reading — confirm by re-reading the updated Kbuild file and the regenerated `patches/base/C1-kbuild-version-mk.patch`).
- **Intent impact:** none (Scenario 2 already names the rebuild guarantee normatively; the change is purely lifting it from the commit message into the in-file comment so the on-disk artifact stands alone).
- **Triage decision:** land.
- **Resolution:** applied as `6d118726fb1aa31386e812ac9fcd535ca4e21bb2` on fork branch `c1-kbuild-version-mk` (commit subject: `C1-kbuild-version-mk-I1: lift .cmd-rebuild guarantee into in-file comment`). v2-tip-sha advances from `dce2a114` to `6d118726`; +3 / -1 LoC in `kernel-open/Kbuild`; regenerated `patches/base/C1-kbuild-version-mk.patch`.

### C1-kbuild-version-mk-I2 — Add an explicit Scenario for out-of-tree (`O=...`) builds

- **Lens:** invariant clarity (community-signal-adjacent)
- **Current state:** Intent Requirement 2 says the include "MUST be guarded by `$(src)`-relative pathing so the build works regardless of the caller's cwd" but there is no explicit Scenario exercising the `O=<build-dir>` out-of-tree case. The portability invariant is asserted but not scenario-tested in the intent.
- **Proposed state:** Add a Scenario "Out-of-tree build via `O=<dir>` still resolves version.mk" under Requirement 2.
- **Value:** Tests a constraint the rvn2p cross-distro signal (`_community-signal.md:30-34`, Debian sid build via the aorus repo) weakly validates. Belt-and-braces for portability.
- **Cost:** Adds one Scenario to the intent — re-opens its `reviewed` lint state, requires lint re-run. The Scenario also tests **kbuild's intrinsic behaviour** (kbuild's own contract is that `$(src)` resolves correctly under `O=...`), not a behaviour C1 introduces. Over-tests the surface.
- **Verification mode:** B (would require an actual `O=...` build, which the test harness doesn't exercise).
- **Intent impact:** add Scenario "Out-of-tree build via `O=...`".
- **Triage decision:** reject.
- **Resolution:** rejected — tests kbuild's intrinsic portability contract rather than a C1-specific invariant; the aorus 0025 ancestor does not assert this in its intent; rvn2p's success is empirical proof that no scenario-test is needed; the intent's existing `$(src)`-relative-pathing Requirement is sufficient. Default-reject (low value, moderate cost via intent re-lint).

### C1-kbuild-version-mk-I3 — Name the `MODULE_VERSION(NV_VERSION_STRING)` consumer chain in the in-file comment

- **Lens:** quality
- **Current state:** The in-file comment names the producer side (`version.mk` → `NV_VERSION_STRING`) but not the consumer side. The chain is `version.mk` → `-DNV_VERSION_STRING` → `MODULE_VERSION(NV_VERSION_STRING)` (in `kernel-open/nvidia/nv-frontend.c`) → `modinfo`'s `version:` field. This consumer chain is captured in intent Scenario 1 (modinfo equality assertion) + the v2 review's Rationale section.
- **Proposed state:** Append the consumer chain to the in-file comment (~3 extra lines: cite the `MODULE_VERSION()` site + the `modinfo` consumer).
- **Value:** Future maintainer sees full producer-consumer chain in-file.
- **Cost:** +3 comment lines for content already in intent Scenario 1 + commit message. The in-file comment grows beyond the aorus ancestor's. The `MODULE_VERSION(NV_VERSION_STRING)` site lives in `nv-frontend.c` — cross-file in-comment citation is brittle (would need re-citing if NVIDIA refactors). The intent + review already cover this chain.
- **Verification mode:** A.
- **Intent impact:** none (already covered).
- **Triage decision:** reject.
- **Resolution:** rejected — the consumer chain is durably captured in intent Scenario 1 and the v2 review's Rationale; lifting it into an in-file comment would inflate the comment beyond the proven aorus ancestor's shape for derivable information; cross-file citations from comments are brittle under refactor. Default-reject.

### C1-kbuild-version-mk-I4 — Document the carve relationship to addon A5 in the intent's Scope boundary

- **Lens:** invariant clarity / sovereignty
- **Current state:** The intent's Scope boundary clause 1 (lines 78-81) says: "This patch does NOT introduce or modify any project-specific suffix (e.g. `-aorus.N`). Setting such a suffix is the responsibility of the addon patch [[A5-version-and-toggles]], which edits `version.mk`'s `NVIDIA_VERSION` directly." This is correct but understates the carve: the legacy cluster `patches/legacy/0007-tb-egpu-version-mark-and-kbuild.patch` combined the version-mk dedup mechanism (now C1) with the Kconfig toggles (`CONFIG_NV_TB_EGPU`, `CONFIG_NV_TB_EGPU_DIAG`, now A5). C1 carved away just the dedup; the toggles live in A5 (verified: `grep CONFIG_NV_TB_EGPU patches/addon/A5-version-and-toggles.patch` returns 4 lines).
- **Proposed state:** Add a one-line note to the Scope boundary citing that the Kconfig toggles are also in A5 (not just the version suffix).
- **Value:** Clarifies what got carved where for future C-set/A-set boundary maintenance. Helps a reviewer understand why C1 is upstream-bound but A5 is not.
- **Cost:** ~1 sentence added to intent Scope boundary. Re-opens intent `reviewed` lint state. The relationship is already implicit in the manifest's layer column (C1=base/upstream-bound, A5=addon/project-local) and in the v2 review's Design choices section.
- **Verification mode:** A.
- **Intent impact:** refine Scope boundary.
- **Triage decision:** defer.
- **Resolution:** deferred — the carve relationship is structurally captured by the manifest layer column and the patch-id prefix convention (C-set = upstream-bound, A-set = project-local). Lifting it into the C1 intent's Scope boundary risks duplicating cross-patch context that lives more durably in the manifest + the C/E/A geometry memory entry (`project_cea_patch_geometry_2026_05_22`). **Disposition for follow-up:** if a future maintainer needs to understand the C1/A5 boundary independently of the manifest, lift this clause then. Tracked here so a future maintainer doesn't re-derive the relationship.

## Re-examination of sub-cycle 2 deferrals

(no sub-cycle 2 deferrals for this patch — v2 review's "v1 → v2 deltas" section reads "(no v1→v2 deltas — v1 already meets the v2 intent)" and has zero D-entries)

## Improvements landed

- **C1-kbuild-version-mk-I1** — `6d118726` on `c1-kbuild-version-mk`: lifted the `.cmd`-hashing rebuild guarantee into the in-file Kbuild comment so a maintainer reading the stanza alone can answer "do I need `make clean` after a `NVIDIA_VERSION` bump?" without consulting commit message, intent, or review. +3 / -1 LoC; no semantic change vs vanilla beyond comment surface.

## Intent updates landed

(none — I1 has Intent impact `none`; intent stays at sub-cycle 2's `reviewed` status with no re-lint required)

## Done gate

- [x] Every candidate improvement has explicit `Resolution:` (no `pending`).
- [x] All "land" improvements applied as fork-branch commits citing their `<id>-I<N>` IDs. _(I1 → `6d118726`.)_
- [x] Substantive intent updates landed as precursor commits. _(N/A — zero substantive intent updates.)_
- [x] `tools/intent-lint.sh` passes _(no intent change; lint re-verified, exit 0)._
- [x] `tools/validate-patchset.sh` passes (compile gate; composed C1-A5 patchset against kernel 7.0.9-204.fc44.x86_64, exit 0).
- [x] `bash tests/run.sh` green (8/16/10 across compose/intent-lint/manifest-lib = 34 ok, 0 failed, exit 0).
- [x] Audit-reviewer subagent approved (sub-cycle 3 audit-reviewer, ✅ APPROVED WITH NOTES — all citations verbatim-verified, all 4 triages concurred, all gates re-ran green, zero audit deltas required).

## Cross-references

- Intent file: `docs/patch-intents/C1-kbuild-version-mk.md`
- Review file: `docs/patch-reviews/C1-kbuild-version-mk.md`
- Manifest row: `patches/manifest` line for `C1-kbuild-version-mk` (layer `base`, source `fork:c1-kbuild-version-mk`)
- Vanilla baseline: `kernel-open/Kbuild:82` (vanilla 595.71.05 hardcoded `-DNV_VERSION_STRING=\"595.71.05\"`); `version.mk:1` defines `NVIDIA_VERSION = 595.71.05`
- Fork branch: `c1-kbuild-version-mk` on `apnex/open-gpu-kernel-modules` (v1 tip `dce2a1148b0986205d74db7a10ebf9c6d01f83b7`; v2 tip `6d118726fb1aa31386e812ac9fcd535ca4e21bb2` after I1)
- aorus-5090 ancestor: `/root/aorus-5090-egpu/patches/0025-Kbuild-version-from-version-mk.patch` (the drift-fix predecessor); `/root/aorus-5090-egpu/patches/0005-version-mark-aorus-build.patch` (the drift-introducing predecessor)
- aorus-5090 design + investigation: `/root/aorus-5090-egpu/docs/lever-catalog.md:353-373` (Patch 0025 listing + upstream-readiness flag); `/root/aorus-5090-egpu/docs/architecture-and-modularity.md:84-100` (L1 sovereignty justification for version-mark family); `/root/aorus-5090-egpu/docs/patched-driver-runbook.md:40-118` (operator-side `modinfo` consumer).
- Upstream issue: n/a (standalone build-system cleanup; candidate for upstream as an independent PR)
- Community signal: `docs/patch-improvements/_community-signal.md:135` ("no findings tagged for C1"); `_community-signal.md:30-34` (rvn2p Debian-sid cross-distro success — weak portability validation for the `$(src)/../version.mk` mechanism)
