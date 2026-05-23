---
id: A5-version-and-toggles
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: 420fcaedf5ec72897f23206df9b663f18690ccd8
v2-tip-sha: 420fcaedf5ec72897f23206df9b663f18690ccd8
status: accepted
related-patches: []
---

# A5-version-and-toggles — v2 review

## Rationale

A5 stamps the running driver with two pieces of project-local
metadata: a `-aorus.NN` branding suffix on the version string and a
`CONFIG_NV_TB_EGPU` Kconfig-style master toggle. Both are pure
build-time metadata; neither has runtime behaviour. The branding
suffix is the project's identity in `modinfo` and the kernel-log
banner — without it, a deployed module is indistinguishable from
vanilla NVIDIA 595.71.05 in any observable surface, which would make
incident attribution and version-drift detection impossible. The
master toggle is forward-looking infrastructure: it reserves the name
`CONFIG_NV_TB_EGPU`, defines its default (`y`), and emits the
corresponding `-D` macro to every translation unit so that any future
in-source `#ifdef CONFIG_NV_TB_EGPU` can be added without further
Kbuild work. The toggle is deliberately NOT a source-list gate today
— v1's in-source comment block states this explicitly ("Currently
reserved as a documentation-only symbol — gating P1-P5 out would
require wrapping all eGPU additions across multiple clusters in
`#ifdef`, out of scope for the refactor"). This is the **last
per-patch review** in sub-cycle 2; Task 14's cross-patch audit
follows.

A5 is the last sub-cycle-2 patch to review and inherits two cross-patch
contract questions from earlier reviews:

- **A1-D2** ("gate A1's source-list line on `CONFIG_NV_TB_EGPU`?")
  was deferred to A5's review with severity `out-of-scope`.
- **A4-D3** documented a lockstep RM+UVM gate requirement for A4's
  two source-list rows if A5 ever gates anything, and A4's review
  prose stated A5's toggle "gates A4's source-list rows" — a v2
  forward-looking claim that does NOT match v1 reality.

A5's review (this file) adjudicates both: **the toggle is
documentation-only in v1; no source-list rows are gated; A1-D2
collapses; A4-D3's lockstep requirement is preserved as
future-design context but not exercised**. The fork branch is
left at its v1 tip — zero-delta sentinel applies.

## v1 audit

The v1 fork branch tip (`420fcaedf5ec72897f23206df9b663f18690ccd8`
— "tb-egpu: version value + CONFIG_NV_TB_EGPU toggle (A5)") makes
exactly two file edits, 14 net lines added:

**`version.mk`** — one assignment:

```
-NVIDIA_VERSION = 595.71.05
+NVIDIA_VERSION = 595.71.05-aorus.14
```

The `NVIDIA_NVID_VERSION` and `NVIDIA_NVID_EXTRA` fields are
untouched — the project's branding is attached only to the
user-visible `NVIDIA_VERSION` string, not to the NVID-tracker fields.
The `$(OUTPUTDIR)/version.h` recipe at the bottom of `version.mk`
will produce a `version.h` with
`#define NVIDIA_VERSION "595.71.05-aorus.14"` automatically, and the
RM's `nv-firmware.c` / banner-emit paths consume it without
modification.

**`kernel-open/Kbuild`** — one additive 13-line block inserted
immediately after [[C1-kbuild-version-mk]]'s `include
$(src)/../version.mk` + `-DNV_VERSION_STRING=\"$(NVIDIA_VERSION)\"`
pair:

```
+# tb-egpu (cluster A5): Kconfig-style master toggle.
+#
+# CONFIG_NV_TB_EGPU      master gate. Default y. Currently reserved as
+#                        a documentation-only symbol — gating P1-P5 out
+#                        would require wrapping all eGPU additions
+#                        across multiple clusters in #ifdef, out of
+#                        scope for the refactor. Build is "always y"
+#                        today; the symbol is defined for future use.
+CONFIG_NV_TB_EGPU       ?= y
+ifeq ($(CONFIG_NV_TB_EGPU),y)
+ccflags-y += -DCONFIG_NV_TB_EGPU
+endif
```

The block does three things: (1) declares the variable as
overridable via the conventional Kconfig idiom `?=` defaulting to
`y`; (2) emits `-DCONFIG_NV_TB_EGPU` to `ccflags-y` when the variable
evaluates to `y`; (3) documents the toggle's reserved/forward-looking
status in-source so a future reviewer sees the rationale without
having to dig out the commit message or this review file.

**Strengths.**

- **Truthful in-source documentation.** The comment block accurately
  describes what the toggle does and does NOT do. A reader who
  expects gates is disabused by the second comment line; a reader
  who notices no gates anywhere in the patchset finds the answer in
  the same block. Self-documenting at the right scope.
- **Minimal patch surface.** Two files, 14 lines net. The branding
  edit is one assignment in `version.mk`; the Kbuild edit is one
  contiguous additive block immediately after [[C1-kbuild-version-mk]]'s
  block. No surrounding code is touched. Matches the "minimal blast
  radius" policy.
- **Cleanly piggybacks on [[C1-kbuild-version-mk]].** The branding
  suffix would be silently discarded if Kbuild still hardcoded
  `595.71.05`; C1's `include $(src)/../version.mk` + derived `-D`
  ensures A5's suffix propagates. The two patches compose without
  either knowing about the other's internals — C1 owns the
  plumbing, A5 owns the value.
- **`?=` rather than `:=`.** Using `?=` allows the build orchestrator
  (e.g. an out-of-tree distributor) to override the default without
  patching `kernel-open/Kbuild`. This is the conventional Kconfig
  idiom and the right shape for a reserved toggle.
- **`-DCONFIG_NV_TB_EGPU` is observable to every nvidia.ko
  translation unit.** The `ccflags-y +=` form is global to the
  module. Any future `#ifdef CONFIG_NV_TB_EGPU` in any addon source
  file will work without further Kbuild work — the macro is
  forward-compatible with the most likely consumer pattern.
- **`-D` emit is conditional on the variable's value.** If a
  developer overrides `CONFIG_NV_TB_EGPU=n` on the make command line,
  the macro is dropped (no fake `=0` emission). This matches the
  semantics of true Kconfig and matches what a future
  `#ifdef CONFIG_NV_TB_EGPU` consumer would expect.

**Weaknesses.**

- **The toggle does not actually gate anything in v1.** This is
  acknowledged in-source ("Currently reserved as a documentation-only
  symbol") but means earlier reviews' aspirational claims about A5
  gating source files are unsatisfied. The cleanest fix is NOT to
  add gates (which would surface lockstep / link-error fragility per
  [[A4-close-path-telemetry]]'s D3 discussion) but to correct the
  earlier reviews' prose. Surfaced as `A5-version-and-toggles-D1`
  below (with severity `out-of-scope` — A5's behaviour is correct,
  the prose drift is in upstream reviews).
- **No A5-side `#ifdef CONFIG_NV_TB_EGPU` consumer exists.** A
  defensible posture for a reserved toggle is to ship at least one
  trivial consumer (e.g. a `#ifdef CONFIG_NV_TB_EGPU` guard around
  the `tb_egpu_*` symbol exports in [[A1-pcie-primitives]]) so the
  toggle's plumbing is exercised end-to-end. v1 ships none. This
  matches the in-source documentation's "reserved" stance and is the
  right call for v1 — adding a consumer would require coordinating
  across addons; reserving the toggle for a future cycle is the
  honest minimal step. No delta.
- **Static counter in `version.mk` requires manual bump.** The
  `-aorus.NN` counter is a literal in `version.mk`; bumping it for a
  new build requires editing the file by hand. A future cycle could
  derive the counter from git tags or CI metadata, but for the
  current sub-cycle the manual edit is fine — the version is
  load-bearing enough that the project wants explicit human
  acknowledgement on each bump. No delta.

**Surprises relative to vanilla.**

- None. Vanilla `version.mk` already exists with the same schema;
  A5 changes one value. Vanilla `kernel-open/Kbuild` has the
  `ccflags-y += -D...` pattern already; A5 adds one more `-D` via
  the same mechanism. The Kconfig-style comment block is novel for
  the file but harmless — `make` ignores `#` comment lines. Both
  edits compose with vanilla NVIDIA's build system without any
  out-of-tree adaptation.

## Design choices

The main alternatives considered during the v2 review:

- **Gate the addon source-list rows on `CONFIG_NV_TB_EGPU=y` vs.
  keep v1's documentation-only stance.** Considered (a) wrapping
  the four `NVIDIA_SOURCES += nvidia/nv-tb-egpu-*.c` rows and the
  one `NVIDIA_UVM_SOURCES += nvidia-uvm/nv-tb-egpu-uvm.c` row in
  `ifeq ($(CONFIG_NV_TB_EGPU),y) ... endif` blocks so a `=n` build
  excludes the addon files cleanly. Rejected for three reasons:
  (1) The in-source comment block explicitly documents the
  documentation-only stance and states gating "is out of scope for
  the refactor"; changing v1 to gate would contradict the comment
  and require coordinated updates to the prose. (2) [[A4-close-path-telemetry]]'s
  D3 documented that A4's two rows (RM `nv-tb-egpu-close.c` defining
  `EXPORT_SYMBOL_GPL` symbols + UVM `nv-tb-egpu-uvm.c` consuming
  them via `extern`) must move in lockstep or link errors surface.
  The same risk exists across the broader A1/A2/A3/A4 subset:
  e.g. A2's watchdog reaches for A1's primitives, A3's recovery
  reaches for A1's primitives, A4's close-path reaches for A1's
  WPR2 helper. Gating any addon row without its dependencies would
  break the build; gating the whole stack as one block would work
  but converts the toggle's semantics from "fine-grained per-addon
  enable" to "all-addons-or-none", which has a different design
  intent. (3) The use-case for a `=n` build is unclear today — the
  project's deployment shape (the live host runs the patched
  driver with all addons enabled, per
  `project_dynamic_patch_composition_merged_2026_05_22`) does not
  exercise a `=n` build. Adding fragile gating for an unused
  configuration would be premature complexity. **Kept v1's
  documentation-only stance.** If a future cycle materialises a
  use-case (e.g. a base-only build for upstream PR validation),
  the gate can be designed properly then, including the lockstep
  bundling.
- **Drop the `CONFIG_NV_TB_EGPU` declaration entirely vs. keep it
  reserved.** Considered removing the `?=` declaration and the
  `-D` emit since neither has any consumer in v1. Rejected because
  (1) the declaration carries forward-design value — it establishes
  the canonical name and default for a future gate, removing the
  bikeshed question; (2) the `-D` macro is the cheapest possible
  forward-compatible interface — any addon file that later adopts
  `#ifdef CONFIG_NV_TB_EGPU` works without further Kbuild changes;
  (3) the comment block IS the documentation, and dropping the
  declaration would leave the project's "addon-stack master toggle"
  concept undocumented anywhere in the source tree. Kept v1's
  reservation.
- **Inline the `-aorus.NN` suffix into `kernel-open/Kbuild` vs.
  edit `version.mk`.** Considered keeping the branding in
  `kernel-open/Kbuild` (e.g. as a `-DNV_VERSION_STRING_SUFFIX=...`
  flag concatenated with the base version). Rejected because
  (1) [[C1-kbuild-version-mk]] establishes `version.mk` as the
  single source of truth for the version string — splitting the
  branding into a second file would re-introduce the very drift
  C1 eliminates; (2) NVIDIA's release tooling treats `version.mk`
  as the canonical edit site for version bumps; an out-of-tree
  consumer that follows the same convention will find the suffix
  where it expects to. Kept v1's `version.mk`-edit shape.
- **Use a strict `?=` default of `y` vs. `n`.** Considered making
  the default `n` so a build that imports the addon source files
  without setting `CONFIG_NV_TB_EGPU=y` would get a "clean base"
  build. Rejected because (1) the default IS the project's
  expected runtime stance — the live host has all addons enabled;
  (2) defaulting to `n` would mislead a reader into thinking a `=y`
  override is required to get the project's deployed behaviour,
  when in v1 the override has zero effect on what compiles. The
  default matches the deployed reality. Kept v1's `?= y` shape.
- **Telemetry tier `none` vs. `nominal`.** A5 has no runtime
  behaviour at all — the only observables are (1) the
  `NV_VERSION_STRING` value emitted by vanilla NVIDIA's existing
  module-load banner (which A5 doesn't add), and (2) the
  `version:` field in `modinfo` (intrinsic to the kernel module
  format). Neither is a log event A5 introduces. `none` is the
  correct tier (intent frontmatter pinned).
- **Whether to add a Kconfig file (`drivers/.../Kconfig`).**
  Considered adding a tiny Kconfig fragment to make the toggle
  participate in the kernel's standard configuration system.
  Rejected because (1) NVIDIA's out-of-tree build system does NOT
  participate in the kernel's Kconfig — the `make modules`
  invocation is driven by `kernel-open/Kbuild` plus the kernel's
  module-build harness, not by `oldconfig` / `menuconfig`; (2)
  inventing a fragmentary Kconfig file would mislead readers into
  thinking the toggle is selectable via `menuconfig`, which it is
  not; (3) the kbuild-make-variable form (`?=` + `ifeq`) IS the
  conventional shape for out-of-tree module toggles. Kept v1's
  kbuild-variable shape.

## v1 → v2 deltas

### A5-version-and-toggles-D1 — A1-D2 collapses: no source-list gate, A1 stays unconditional

- **Location:** [[A1-pcie-primitives]] review, delta `A1-pcie-primitives-D2`
  (line 397 of `docs/patch-reviews/A1-pcie-primitives.md`).
  Adjudicated here in A5's review.
- **Change:** No code change. A1-D2 was deferred to A5's review with
  the question "should A1's source-list line
  (`NVIDIA_SOURCES += nvidia/nv-tb-egpu-pcie.c`) be gated on
  `CONFIG_NV_TB_EGPU` so the foundation translation unit only
  compiles when the master toggle is on?". The adjudication is
  **no gate**: A1's row stays unconditional, consistent with A2,
  A3, A4, and the UVM-side row. The question collapses because v1's
  `CONFIG_NV_TB_EGPU` is documentation-only — there is no
  source-list-row gate anywhere in the stack, so the question of
  whether A1 is "also" gated is moot.
- **Severity:** out-of-scope
- **Evidence:** v1's in-source comment block in `kernel-open/Kbuild`
  states "Currently reserved as a documentation-only symbol — gating
  P1-P5 out would require wrapping all eGPU additions across multiple
  clusters in `#ifdef`, out of scope for the refactor". Inspection
  of the `nvidia-sources.Kbuild` file on the `a5-version-and-toggles`
  branch confirms all four `NVIDIA_SOURCES += nvidia/nv-tb-egpu-*.c`
  rows are unconditional; `nvidia-uvm-sources.Kbuild` confirms the
  UVM row is unconditional. Adding a gate to A1 alone would
  produce a build that compiles A1's foundation but excludes A2/A3/A4
  (if their rows are also gated identically) — which would surface
  the link-error cascade documented in
  [[A4-close-path-telemetry]]'s D3 for the RM/UVM pair, and the
  analogous foundation-consumer link errors for A2/A3 dropping A1.
- **Resolution:** adjudicated — A1's row stays unconditional in v1.
  A1's review remains accurate (D2 noted "v1 implements (b) by
  default (no gate on A1); a future A5 review may decide to push
  the gate up to the foundation"). A5's decision: no foundation
  gate, no consumer gates either. The question is preserved for
  any future sub-cycle that decides to ship a real source-list
  gate; at that point the right design is "all addon files gated
  in lockstep" rather than "A1 gated, A2-A4 unconditional" or any
  other partial split.

### A5-version-and-toggles-D2 — A4-D3 prose drift: A4 review's "gates A4's source-list rows" claim is corrected

- **Location:** [[A4-close-path-telemetry]] review, lines 673-677 of
  `docs/patch-reviews/A4-close-path-telemetry.md`.
- **Change:** No code change. A4's review prose stated "A4's
  interaction with A5 is build-only — A5's `CONFIG_NV_TB_EGPU`
  master toggle gates A4's source-list rows
  (`nvidia/nv-tb-egpu-close.c` and `nvidia-uvm/nv-tb-egpu-uvm.c`) at
  compile time". This is **aspirational** — v1's A5 patch does NOT
  gate any source-list row. A5's intent (this review's intent file)
  is the canonical contract: the toggle is reserved /
  documentation-only. The A4 prose is corrected by A5's intent text
  and by this delta record; the A4 file itself is left untouched
  per the no-retroactive-prose-edit policy (the truth lives in A5's
  intent + this review).
- **Severity:** out-of-scope
- **Evidence:** v1 `kernel-open/Kbuild` adds the
  `CONFIG_NV_TB_EGPU` symbol and emits `-DCONFIG_NV_TB_EGPU` but
  does NOT wrap any `NVIDIA_SOURCES += ...` row. The in-source
  comment block confirms this explicitly. A4's review prose was
  written at A4's review time (commit `c344571`, 2026-05-23) with
  the expectation that A5's review would deliver a real gate. The
  expectation was reasonable but did not match the v1 reality of
  the A5 patch (`420fcaed`, authored at the same time the rest of
  the addon stack was being recarved). A5's adjudication (this
  delta) is **honest description over aspirational gating**: the
  reserved-toggle stance is the right design call for v1, and the
  A4 prose drift is recorded here for Task 14's cross-patch audit
  to consider. Task 14 may elect to either (a) edit A4's review
  prose to say "the symbol is reserved for future gating" or
  (b) leave A4's prose as-is and rely on A5's intent + this delta
  record. Either is acceptable; the load-bearing truth is A5's
  intent.
- **Resolution:** adjudicated — A5's intent and this review record
  the truthful stance. A4's review prose stands as-is (Task 14
  cross-patch audit may revisit); the link from A5 back to A4
  is documented in A5's intent's `## Provenance` section ("A4-D3
  is honoured by accurate description, not by code change").

### A5-version-and-toggles-D3 — No must-fix or should-fix deltas

- **Location:** n/a
- **Change:** v1's behaviour, surface, and in-source documentation
  match the v2 intent's normative shape. The intent's two
  Requirements are satisfied: the `-aorus.NN` suffix is present on
  `NVIDIA_VERSION` and propagates through [[C1-kbuild-version-mk]]'s
  plumbing to `NV_VERSION_STRING`; the `CONFIG_NV_TB_EGPU` toggle
  is declared with `?= y` default and emits `-DCONFIG_NV_TB_EGPU`
  conditionally to `ccflags-y`, with an accurate in-source comment
  block describing the reserved/documentation-only stance. The
  Scope boundary is honoured: no source-list rows are gated; no
  module parameters are introduced; no runtime log surface is
  added; no Kconfig fragment is added; no A1-A4 semantics are
  altered. No fork-branch follow-up commits are required.
- **Severity:** out-of-scope
- **Evidence:** Both intent Requirements have their scenarios
  satisfiable by inspection of v1. The Provenance section's
  description of the patch surface (2 files, 14 net lines)
  matches `git show 420fcaed --stat` (2 files changed, 14
  insertions(+), 1 deletion(-)). The toggle's "reserved /
  documentation-only" stance is corroborated by reading the
  in-source comment block alongside the unconditional
  `NVIDIA_SOURCES += ...` rows in `nvidia-sources.Kbuild`.
- **Resolution:** rejected — no v2 follow-up needed.

Per M2 (zero-delta sentinel from the C1 checkpoint), the frontmatter
`v1-tip-sha == v2-tip-sha == 420fcaedf5ec72897f23206df9b663f18690ccd8`
is the machine-checkable signal that v1 already meets v2 intent. The
three non-applied deltas (D1 adjudicating A1-D2 collapse, D2
correcting A4-D3 prose drift, D3 explicit no-must-fix) are recorded
to give Task 14's cross-patch audit and downstream consumers a
single canonical contract:

- **A5's `CONFIG_NV_TB_EGPU` toggle is documentation-only in v1.**
  No source-list rows are gated. A future sub-cycle that materialises
  a real `=n` build use-case may adopt all-addons-or-none gating;
  partial-gating (A1 only, or any other subset) is rejected by this
  review because of the link-error cascade documented in A4-D3.
- **The `-aorus.NN` branding suffix is the project's identity in
  `modinfo` and the kernel-log banner.** [[C1-kbuild-version-mk]]'s
  plumbing carries it; A5 owns the value. Future version bumps
  edit `version.mk` only.
- **A1-D2 ("gate A1's source-list line?") is adjudicated as
  no-gate** and collapses with the broader documentation-only
  stance.
- **A4-D3's prose drift is recorded** in this review but A4's
  file itself is not retroactively edited (the truthful contract
  lives in A5's intent + this review's D2).
- **No Kconfig file is added.** Out-of-tree NVIDIA builds do not
  participate in the kernel's Kconfig system; inventing a
  fragmentary Kconfig would mislead readers.

## Done gate

- [x] `docs/patch-intents/A5-version-and-toggles.md` exists, lints clean, `status: reviewed`.
- [x] All must-fix deltas applied as fork-branch commits citing their delta IDs. _(N/A — zero must-fix deltas; D1 adjudicates A1-D2 collapse, D2 corrects A4-D3 prose drift via intent + this record, D3 explicit no-must-fix.)_
- [x] `patches/addon/A5-version-and-toggles.patch` refreshed by `regen`. _(N/A — no fork-branch change; existing file already reflects `420fcaed`.)_
- [x] `tools/validate-patchset.sh` passes (compile gate).
- [x] `bash tests/run.sh` green.
- [ ] Audit-reviewer subagent approved. _(Pending — this review file is the audit-reviewer's input.)_

## Cross-references

- Intent file: `docs/patch-intents/A5-version-and-toggles.md`
- Manifest row: `patches/manifest` line for `A5-version-and-toggles`
  (layer `addon`, source `fork:a5-version-and-toggles`)
- Vanilla baseline:
  - `version.mk` — vanilla 595.71.05 sets `NVIDIA_VERSION =
    595.71.05`; A5 changes this one assignment to
    `NVIDIA_VERSION = 595.71.05-aorus.14`. No other line touched.
  - `kernel-open/Kbuild` — vanilla 595.71.05 hardcodes the
    `-DNV_VERSION_STRING` flag (line ~82); [[C1-kbuild-version-mk]]
    replaces that with an `include $(src)/../version.mk` + derived
    `-D` pair; A5 inserts a new 13-line block immediately after that
    pair (a Kconfig-style comment block + `CONFIG_NV_TB_EGPU ?= y`
    declaration + `ifeq` / `ccflags-y +=` / `endif` conditional).
    No other line in `kernel-open/Kbuild` touched.
- Fork branch: `a5-version-and-toggles` on
  `apnex/open-gpu-kernel-modules` (sits on top of
  `a4-close-path-telemetry`; the cumulative diff at A5's tip
  carries C1-C5 + E1 + A1 + A2 + A3 + A4 + A5)
- Upstream issue: n/a (addon-layer; not upstream-bound; per Rule 5
  `upstream-candidacy: n/a` for `layer: addon`). The `-aorus.NN`
  suffix is by definition project-local; the `CONFIG_NV_TB_EGPU`
  macro is project-local infrastructure
- Related reviews:
  - [[C1-kbuild-version-mk]] — owns the
    `include $(src)/../version.mk` + `-DNV_VERSION_STRING=\"$(NVIDIA_VERSION)\"`
    plumbing that A5 piggybacks on; C1's review's Scope boundary
    explicitly defers the `-aorus.N` suffix to A5
  - [[A1-pcie-primitives]] — A1-D2 ("gate A1's source-list line?")
    adjudicated here in A5-D1 as no-gate; A1's review's D2 stands
    accurately ("v1 implements (b) by default (no gate on A1); a
    future A5 review may decide to push the gate up to the
    foundation"); A5's decision is no-gate
  - [[A2-bus-loss-watchdog]] — A5's toggle does NOT gate A2's
    source-list row in v1; A2's runtime-disable knob
    `NVreg_TbEgpuQwdEnable` is the per-addon runtime gate, not A5
  - [[A3-recovery]] — same as A2; A3's runtime-disable knob is
    `NVreg_TbEgpuRecoverEnable`; A5 does not gate A3's source row
  - [[A4-close-path-telemetry]] — A4-D3 documented a lockstep
    RM+UVM gate requirement IF A5 ever gates; A5's decision is no
    gate in v1; A4's review prose at lines 673-677 saying "A5's
    `CONFIG_NV_TB_EGPU` master toggle gates A4's source-list
    rows" is corrected by A5's intent + this review's D2 (Task
    14's cross-patch audit may elect to edit A4's prose or rely
    on the A5-side correction)
  - Related-patches frontmatter is `[]` because A5 has no
    intent-file dependency on any other patch; the cross-patch
    relationships above are body-prose `[[...]]` wikilinks
    (presentation only — not lint-resolved). Task 14's cross-patch
    audit will confirm this is the right shape, given A5's
    documentation-only stance does not require any sibling
    intent file to exist on disk
