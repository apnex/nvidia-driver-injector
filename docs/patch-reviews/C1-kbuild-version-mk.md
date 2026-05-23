---
id: C1-kbuild-version-mk
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: dce2a1148b0986205d74db7a10ebf9c6d01f83b7
v2-tip-sha: dce2a1148b0986205d74db7a10ebf9c6d01f83b7
status: accepted
related-patches: []
---

# C1-kbuild-version-mk — v2 review

## Rationale

Vanilla `kernel-open/Kbuild` defines the module version string twice in
two different files (`-DNV_VERSION_STRING=\"595.71.05\"` in Kbuild;
`NVIDIA_VERSION = 595.71.05` in repo-root `version.mk`). On a vanilla
NVIDIA release this is harmless because their release tooling rewrites
both together, but in any downstream stack that bumps `version.mk` to
add a build-suffix (as the project's addon
[[A5-version-and-toggles]] does), the duplication is a drift trap.
The legacy stack actually hit this trap — Kbuild stayed at `aorus.5`
while `version.mk` advanced to `aorus.10`, and `modinfo`'s `version:`
field silently misreported the build for several releases. C1 removes
the duplication by making Kbuild read `NVIDIA_VERSION` from `version.mk`
at compile time, so `version.mk` becomes the single source of truth.

This is the simplest C-set patch by far — a five-line additive change to
one file, no runtime behaviour, no telemetry. It is a candidate for
upstreaming as a standalone build-system cleanup PR independent of the
rest of the eGPU stack. No upstream issue tracks it today; the v2
intent flags this as upstream-bound (`upstream-candidacy: high`)
without speculation about NVIDIA's likely response.

## v1 audit

The v1 fork branch tip
(`dce2a1148b0986205d74db7a10ebf9c6d01f83b7` —
"Kbuild: derive NV_VERSION_STRING from version.mk") makes a single
five-line hunk against `kernel-open/Kbuild` at the
`-DNV_VERSION_STRING` site:

```
-ccflags-y += -DNV_VERSION_STRING=\"595.71.05\"
+# Derive NV_VERSION_STRING from the repo-root version.mk so the module
+# version string has a single source of truth and cannot drift from a
+# hardcoded Kbuild literal.
+include $(src)/../version.mk
+ccflags-y += -DNV_VERSION_STRING=\"$(NVIDIA_VERSION)\"
```

**Strengths.**

- One file, one site, additive only. Matches the "minimal blast radius"
  policy of the C-set.
- The `$(src)/../version.mk` form uses kbuild's `$(src)` so the include
  resolves correctly regardless of where `make` is invoked from. (For
  out-of-tree NVIDIA builds, `$(src)` resolves to
  `<source-root>/kernel-open`, which makes `$(src)/..` the repo root —
  the correct location of `version.mk`.)
- Three lines of in-source comments explain WHY the include is here
  before the change is read, so future maintainers see the rationale
  without having to dig out the commit message.
- The commit message correctly anticipates the kbuild `.cmd` rebuild
  question: it states that kbuild's `.cmd` hashing detects the expanded
  `-D` value changing and rebuilds `nv.o` after a bare `make modules`
  — no `make clean` required. This is the non-obvious correctness
  point of the patch and it's documented.

**Weaknesses.**

- None surfaced by this review. The patch does exactly what the
  intent specifies and nothing more.

**Surprises relative to vanilla.**

- None. Vanilla 595.71.05 simply hardcodes the literal at line 82 of
  `kernel-open/Kbuild`; the patch replaces that one line and inserts
  the include immediately above it. No surrounding code is touched.

## Design choices

The main alternatives considered during the v2 review:

- **Include `version.mk` vs. read it with `$(shell grep ...)`.**
  `include` is the idiomatic kbuild way to share variables between
  make-fragments and is what NVIDIA's own non-Kbuild build system
  already does (`version.mk` is written as an includable fragment with
  bare assignments and a rule for `version.h`). Using `$(shell grep)`
  would bypass make's dependency tracking and be more brittle. Chose
  `include` (matches v1).

- **Pin the include path with `$(src)` vs. a relative `../version.mk`
  literal.** `$(src)` is the canonical kbuild variable for the module
  source directory; a relative literal would break when the build
  runs from `O=...` out-of-tree directories. Chose `$(src)/...`
  (matches v1).

- **Derive ONLY `NV_VERSION_STRING` vs. derive other macros (e.g.
  `NV_BUILD_BRANCH_VERSION`) at the same time.** The other macros are
  set by NVIDIA's release tooling and do not have a `version.mk`
  counterpart today, so there is nothing to dedupe. Adding them would
  expand the patch surface for no gain. Scoped C1 to just
  `NV_VERSION_STRING` (matches v1; pinned in the intent's Scope
  boundary).

- **Telemetry tier `none` vs. `nominal`.** This patch has no runtime
  behaviour at all — the only observable is `modinfo`'s `version:`
  field, which is intrinsic to the kernel module format and not
  something the patch logs. `none` is the correct tier (intent
  frontmatter pinned).

- **Whether to bundle the matching `version.mk` edit (the
  `-aorus.N` suffix) into C1.** No — that's a project-specific
  decision that doesn't belong upstream. The intent's Scope boundary
  defers it to addon [[A5-version-and-toggles]] explicitly.

## v1 → v2 deltas

(no v1→v2 deltas — v1 already meets the v2 intent)

## Done gate

- [x] `docs/patch-intents/C1-kbuild-version-mk.md` exists, lints clean, `status: reviewed`.
- [x] All must-fix deltas applied as fork-branch commits citing their delta IDs. _(N/A — zero deltas.)_
- [x] `patches/base/C1-kbuild-version-mk.patch` refreshed by `regen`. _(N/A — no fork-branch change.)_
- [x] `tools/validate-patchset.sh` passes (compile gate).
- [x] `bash tests/run.sh` green.
- [ ] Audit-reviewer subagent approved.

## Cross-references

- Intent file: `docs/patch-intents/C1-kbuild-version-mk.md`
- Manifest row: `patches/manifest` line for `C1-kbuild-version-mk`
- Vanilla baseline: `kernel-open/Kbuild` (line ~82, the
  `-DNV_VERSION_STRING` ccflag)
- Fork branch: `c1-kbuild-version-mk` on
  `apnex/open-gpu-kernel-modules`
- Upstream issue: n/a (standalone build-system cleanup)
- Related reviews: none — C1 is independent of the rest of the
  patch set
