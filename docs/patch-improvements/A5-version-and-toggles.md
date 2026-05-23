---
id: A5-version-and-toggles
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: 9d62f2e6445a8899643f2f04ee8397e16ec6be16
v2-tip-sha: 9d62f2e6445a8899643f2f04ee8397e16ec6be16
status: accepted
intent-updates: []
---

# A5-version-and-toggles — improvement triage

## Triangulation sources

- **Vanilla NVIDIA 595.71.05:** `kernel-open/Kbuild:82` — single line
  `ccflags-y += -DNV_VERSION_STRING=\"595.71.05\"` (hardcoded literal,
  no `version.mk` include). `version.mk:1` defines
  `NVIDIA_VERSION = 595.71.05` independently. Vanilla has NO
  `CONFIG_NV_TB_EGPU` symbol, no Kconfig-style toggles in
  `kernel-open/Kbuild`, no `-D` macros derived from the kbuild
  variable namespace beyond NVIDIA's own `-D__KERNEL__ -DMODULE
  -DNVRM -DNV_VERSION_STRING=...` set.
- **v2 intent:** `/root/nvidia-driver-injector/docs/patch-intents/A5-version-and-toggles.md`
  (two Requirements: `-aorus.NN` suffix on `NVIDIA_VERSION` +
  `CONFIG_NV_TB_EGPU` reserved master toggle with `?= y` default
  and conditional `-D` emit; four Scenarios; six explicit Scope
  boundary NOTs; telemetry tier `none`).
- **v2 review:** `/root/nvidia-driver-injector/docs/patch-reviews/A5-version-and-toggles.md`
  (three D-entries — all severity `out-of-scope`: D1 adjudicates
  A1-D2 collapse, D2 corrects A4-D3 prose drift, D3 explicit
  no-must-fix; zero-delta sentinel; `status: accepted`).
- **Fork branch tips:** v1 = `9d62f2e6445a8899643f2f04ee8397e16ec6be16`;
  v2 = `9d62f2e6445a8899643f2f04ee8397e16ec6be16` (zero v3 commit
  — see §Improvements considered); both on
  `apnex/open-gpu-kernel-modules` branch `a5-version-and-toggles`.
- **aorus-5090 ancestor patches:**
  - `/root/aorus-5090-egpu/patches/0005-version-mark-aorus-build.patch`
    — the **direct ancestor** of the version suffix Requirement.
    Edits BOTH `version.mk` (assignment to `595.71.05-aorus.5`) AND
    `kernel-open/Kbuild` (`-DNV_VERSION_STRING=\"595.71.05-aorus.5\"`
    hardcoded). The "drift-introducing" predecessor that motivated
    the later 0025 dedup.
  - `/root/aorus-5090-egpu/patches/0025-Kbuild-version-from-version-mk.patch`
    — the **drift-fix predecessor** (C1's ancestor, not A5's): adds
    `include $(src)/../version.mk` + `-DNV_VERSION_STRING=\"$(NVIDIA_VERSION)\"`,
    eliminates the version-string drift. A5 piggybacks on this
    mechanism via C1.
  - **Note: no aorus-5090 ancestor for `CONFIG_NV_TB_EGPU`.** The
    aorus-5090 repo has zero references to the symbol (verified by
    `grep -rln CONFIG_NV_TB_EGPU /root/aorus-5090-egpu/` — empty).
    The toggle is a sub-cycle-2 invention in the injector repo;
    the **`tb_egpu_*` / `TB_EGPU_*` naming convention** that
    `CONFIG_NV_TB_EGPU` extends is the relevant ancestor
    (`/root/aorus-5090-egpu/CLAUDE.md:40` and
    `/root/aorus-5090-egpu/tools/lint-identifiers.sh:10-11`).
- **Legacy injector ancestor (project-local):**
  `/root/nvidia-driver-injector/patches/legacy/0007-tb-egpu-version-mark-and-kbuild.patch`
  — the P7 cluster from the 2026-05-12 refactor. Combined the
  version suffix bump, the version.mk-include mechanism, AND TWO
  Kconfig-style toggles (`CONFIG_NV_TB_EGPU` master gate +
  `CONFIG_NV_TB_EGPU_DIAG` diag-TU gate). The 2026-05-22 addon
  recarve carved this into C1 (mechanism) + A5 (value + master
  toggle), and **deliberately dropped** the `CONFIG_NV_TB_EGPU_DIAG`
  toggle along with its `nv-tb-egpu-diag.c` translation unit
  (replaced by A4's log-based telemetry). See §v1 archaeology for
  the dropped-DIAG context.
- **aorus-5090 docs:**
  - `/root/aorus-5090-egpu/docs/architecture-and-modularity.md:84-100`
    — L1 currently-hosts table. Line 88 is the canonical
    justification for the version-mark family living in the fork:
    "string only, no logic — necessary in fork to track which
    patches are present". A5's sovereignty posture cites this.
  - `/root/aorus-5090-egpu/CLAUDE.md:40` — the project's
    identifier-prefix convention: `tb_egpu_*` / `NVreg_TbEgpu*` /
    `TB_EGPU_*`. `CONFIG_NV_TB_EGPU` extends this convention with
    the Kconfig `CONFIG_NV_` prefix.
  - `/root/aorus-5090-egpu/tools/lint-identifiers.sh:10-11` — the
    enforced naming-drift policy that pins `tb_egpu_*` /
    `TB_EGPU_*` as the canonical project sub-prefix.
  - **Binding M1+M2 verification:** the task header named
    `architecture-and-modularity.md` (CONFIG_NV_TB_EGPU toggle
    role) and `recommended-install-path.md` (version handling).
    `architecture-and-modularity.md:84-100` is relevant (L1 home
    justification — kept). `recommended-install-path.md` is NOT
    relevant (BIOS + kernel cmdline + boot sequencing; never
    touches Kbuild or version handling — dropped per M1+M2).
    Added `CLAUDE.md:40` and `tools/lint-identifiers.sh:10-11`
    as omitted-but-relevant naming-convention context.
- **Community-signal entries:**
  `/root/nvidia-driver-injector/docs/patch-improvements/_community-signal.md:135`
  — "No findings tagged for: `C1` (Kbuild/version.mk), `E1` (eGPU
  detection), `A1` (PCIe primitives), `A4` (close-path telemetry),
  `A5` (version/toggles)." A5 is build-system metadata with no
  runtime surface, so neither error-code commonality nor code-path
  commonality applies — there is no upstream/community signal that
  could meaningfully validate or contest A5. Per M5: **explicit
  no-evidence**, not weak evidence — there is nothing for A5 to
  share a symptom with because A5 has no symptom.

## v1 archaeology

What the aorus-5090 mining (and the legacy P7 injector patch) surfaced
about A5's mechanism ancestors:

- **Original design intent — why a project-local version stamp exists at all.**
  `/root/aorus-5090-egpu/docs/architecture-and-modularity.md:84-100`,
  specifically line 88, documents the L1 home for the version-mark
  family: `| 0005 | version mark | string only, no logic — necessary
  in fork to track which patches are present |`. The version stamp
  is a **sovereignty artifact**, not a functional one: without it, a
  deployed module is indistinguishable from vanilla NVIDIA
  `595.71.05` in any observable surface (`modinfo`, kernel-log
  banner), and incident attribution + version-drift detection
  become impossible. The aorus archaeology pins the version suffix
  as the **minimum-viable identity surface** for any fork that ships
  a patched binary alongside vanilla.
- **Constraint discovered — the drift trap that 0005 fell into.**
  `/root/aorus-5090-egpu/patches/0025-Kbuild-version-from-version-mk.patch:5-15`
  documents how `patches/0005-version-mark-aorus-build.patch:5-23`
  set up the drift trap by editing **both** `kernel-open/Kbuild`
  (hardcoded `-DNV_VERSION_STRING=\"595.71.05-aorus.5\"`) AND
  `version.mk` (`NVIDIA_VERSION = 595.71.05-aorus.5`). Subsequent
  aorus patches (0016/0017/0018/0020) bumped only `version.mk` and
  the strings drifted: Kbuild stayed at `aorus.5` while `version.mk`
  reached `aorus.10`. The drift surfaced via `modinfo` reporting
  `aorus.5` even after multiple `version.mk` bumps. This is the
  **load-bearing operational pre-history** of why A5 cooperates
  with [[C1-kbuild-version-mk]] rather than redoing the legacy 0005
  pattern: A5 edits **only** `version.mk`'s value, never the Kbuild
  literal. C1's `include $(src)/../version.mk` +
  `$(NVIDIA_VERSION)` derivation prevents A5 from re-introducing
  the drift trap.
- **Alternatives considered + rejected — inline the suffix into
  Kbuild vs. edit `version.mk`.** A5 review file lines 217-227
  (`docs/patch-reviews/A5-version-and-toggles.md:217-227`) records
  this alternative explicitly: "Considered keeping the branding in
  `kernel-open/Kbuild` (e.g. as a `-DNV_VERSION_STRING_SUFFIX=...`
  flag concatenated with the base version). Rejected because (1)
  [[C1-kbuild-version-mk]] establishes `version.mk` as the single
  source of truth for the version string — splitting the branding
  into a second file would re-introduce the very drift C1
  eliminates". The legacy 0005 ancestor inlined the suffix into
  Kbuild and paid the drift tax; A5's v1 design correctly avoids
  this. No v3 lift needed — the alternative is fully captured in
  the review.
- **Alternatives considered + rejected — keep the `CONFIG_NV_TB_EGPU`
  declaration vs. drop it as unused.** A5 review file lines 205-216
  (`docs/patch-reviews/A5-version-and-toggles.md:205-216`) records:
  "Considered removing the `?=` declaration and the `-D` emit since
  neither has any consumer in v1. Rejected because (1) the
  declaration carries forward-design value — it establishes the
  canonical name and default for a future gate, removing the
  bikeshed question; (2) the `-D` macro is the cheapest possible
  forward-compatible interface". This is the "reserved-symbol" /
  "future-design carrier" stance; the in-source comment block
  encodes the same rationale.
- **Forgotten / latent invariant — the dropped legacy
  `CONFIG_NV_TB_EGPU_DIAG` toggle.**
  `/root/nvidia-driver-injector/patches/legacy/0007-tb-egpu-version-mark-and-kbuild.patch:38-69`
  documents that the legacy P7 cluster shipped TWO toggles:
  `CONFIG_NV_TB_EGPU` (master gate, default y, documentation-only
  — same as A5 today) AND `CONFIG_NV_TB_EGPU_DIAG` (diagnostic
  telemetry gate, default n, **actually gated** the
  `nv-tb-egpu-diag.c` TU via `ifeq ($(CONFIG_NV_TB_EGPU_DIAG),y)`
  in `nvidia-sources.Kbuild`). The 2026-05-22 addon recarve
  deliberately dropped BOTH the `CONFIG_NV_TB_EGPU_DIAG` toggle
  AND the `nv-tb-egpu-diag.c` source file, replacing them with
  A4's log-based telemetry surface
  (`/root/nvidia-driver-injector/docs/patch-reviews/A4-close-path-telemetry.md:313-317`
  — "no counters, no enable/disable knobs, no
  `CONFIG_NV_TB_EGPU_DIAG` gate"). A5 today is the **surviving
  half** of the legacy P7 cluster's toggle pair. This invariant
  ("DIAG toggle was deliberately dropped, not forgotten") is
  load-bearing for a future maintainer who reads legacy P7 against
  current A5 and wonders "where did DIAG go?". The answer lives in
  A4's review prose, not in A5's intent. See A5-I1 below for the
  triage of whether to lift this into A5's intent.
- **Forgotten / latent invariant — the `aorus.NN` counter shape
  emerged from accidental sequence-keeping, not deliberate design.**
  Examining the legacy ancestor sequence shows `aorus.5` (legacy
  0005), through `aorus.10` (the drift-surface point per legacy
  0025), `aorus.13` (legacy P7 production tag), `aorus.14` (current
  A5 v1). The counter is **monotonically incremented per production
  binary cut**, not per patch. The intent's Scenario 2 ("Version
  bump increments the counter only") captures the bump
  mechanism but does not state the bump cadence policy
  (per-binary-cut vs per-patch vs per-PR). This is operational
  policy, not a normative correctness invariant; recording it
  here for archaeological completeness but not surfacing as an
  improvement.

## Improvements considered

### A5-version-and-toggles-I1 — Document the dropped `CONFIG_NV_TB_EGPU_DIAG` carve in A5's intent Provenance

- **Lens:** invariant clarity / dedup
- **Current state:** A5's intent Provenance section
  (`docs/patch-intents/A5-version-and-toggles.md:217-230`) cites
  legacy 0005 and legacy 0007 as source clusters but does not
  name the legacy `CONFIG_NV_TB_EGPU_DIAG` toggle (the
  diag-TU-gating sibling of the master toggle) as a deliberate
  drop. A maintainer reading
  `/root/nvidia-driver-injector/patches/legacy/0007-tb-egpu-version-mark-and-kbuild.patch:38-69`
  (which declares both toggles) against the current A5 patch
  (which declares only `CONFIG_NV_TB_EGPU`) cannot tell from A5's
  intent whether `CONFIG_NV_TB_EGPU_DIAG` was forgotten or
  deliberately dropped. A4's review prose at lines 313-317
  (`docs/patch-reviews/A4-close-path-telemetry.md:313-317`)
  partially answers the question ("no `CONFIG_NV_TB_EGPU_DIAG`
  gate") but the answer is in the wrong place for an A5-focused
  reader.
- **Proposed state:** Add a one-sentence note to A5's intent
  Provenance section's "Source cluster" bullet (or a new
  "Carve-outs from legacy P7" bullet) explicitly stating:
  "The legacy `CONFIG_NV_TB_EGPU_DIAG` toggle and its
  `nv-tb-egpu-diag.c` translation unit (which the legacy 0007
  cluster gated via `ifeq ($(CONFIG_NV_TB_EGPU_DIAG),y)` in
  `nvidia-sources.Kbuild`) were deliberately dropped during the
  2026-05-22 addon recarve; the diagnostic surface was replaced
  by [[A4-close-path-telemetry]]'s log-based emission. A5
  therefore carries only the still-meaningful master toggle."
- **Value:** A future maintainer reading legacy P7 against
  current A5 sees the carve relationship without needing to
  triangulate through A4's review prose. Strengthens the
  audit-trail between the legacy cluster and the current addon
  decomposition.
- **Cost:** ~3-4 lines added to A5's intent Provenance. Re-opens
  the intent's `reviewed` lint state — requires `intent-lint.sh`
  re-run. The carve relationship is already structurally
  captured by (a) A4's review prose explicitly negating
  `CONFIG_NV_TB_EGPU_DIAG`, (b) the absence of
  `nv-tb-egpu-diag.c` from `patches/manifest`, and (c) the
  patches/legacy/ directory being preserved for archaeological
  inspection. Lifting it into A5's intent risks duplicating
  cross-patch context.
- **Verification mode:** A (code-reading).
- **Intent impact:** refine Provenance section (cosmetic /
  clarifying, not normative — does not change any Requirement
  or Scenario).
- **Triage decision:** defer.
- **Resolution:** deferred — the carve relationship is durably
  captured by A4's review prose at lines 313-317 and by the
  absence of `nv-tb-egpu-diag.c` from `patches/manifest`. The
  legacy P7 patch in `patches/legacy/` is preserved on disk
  precisely as the archaeology source-of-truth. Lifting this
  into A5's intent would duplicate context that lives more
  durably in the legacy patch + A4's review. **Disposition for
  follow-up:** Task 14's cross-patch audit may revisit; if a
  future maintainer needs to understand the dropped-DIAG carve
  from A5's perspective alone, lift this clause then. Tracked
  here so a future maintainer doesn't re-derive the relationship.

### A5-version-and-toggles-I2 — Lift the "consumer pattern" sentence into A5's in-file Kbuild comment

- **Lens:** invariant clarity / quality (the C1-I1 analogue)
- **Current state:** A5's in-file comment block in
  `kernel-open/Kbuild` (8 comment lines + 4 declaration lines)
  documents the toggle's reserved-for-future-use stance ("the
  symbol is defined for future use") but does NOT document HOW a
  future consumer would adopt the toggle. The mechanical answer
  is: the `ccflags-y += -DCONFIG_NV_TB_EGPU` line one line below
  the comment block exposes the macro to every `nvidia.ko`
  translation unit, so any future `#ifdef CONFIG_NV_TB_EGPU` in
  any addon C file just works. This consumer-side mechanic is
  captured in A5's intent Requirement 2 (lines 87-107) and
  Scenario "Default build emits `-DCONFIG_NV_TB_EGPU` to every
  nvidia.ko object" (lines 109-119), but not in the file a
  maintainer reads when staring at the Kbuild stanza.
- **Proposed state:** Extend the in-file comment block by 1-2
  lines to lift the consumer-side mechanic in-file (matching the
  C1-I1 enhancement applied to C1's stanza per
  `docs/patch-improvements/C1-kbuild-version-mk.md:41-64`):
  ```
  # CONFIG_NV_TB_EGPU      master gate. Default y. Currently reserved as
  #                        a documentation-only symbol — gating P1-P5 out
  #                        would require wrapping all eGPU additions
  #                        across multiple clusters in #ifdef, out of
  #                        scope for the refactor. Build is "always y"
  #                        today; the symbol is defined for future use.
  #                        The ccflags-y -D below exposes the macro to
  #                        every nvidia.ko translation unit, so a future
  #                        #ifdef CONFIG_NV_TB_EGPU in any addon source
  #                        file works without further Kbuild edits.
  ```
- **Value:** A maintainer reading the Kbuild stanza alone can
  answer the only non-obvious "how would a consumer use this?"
  question without consulting commit message, intent, or review.
  Matches the C1-I1 pattern of lifting load-bearing operational
  context in-file.
- **Cost:** +4 comment lines in one file. Does not change any
  Requirement, Scenario, or behaviour. No intent re-lint needed
  (the consumer mechanic is already normative in Requirement 2).
- **Verification mode:** A (code-reading).
- **Intent impact:** none (mechanic already in Requirement 2
  + Scenario 1).
- **Triage decision:** reject.
- **Resolution:** rejected — the C1-I1 analogue lifted a
  **non-obvious dynamic invariant** (the `.cmd`-hashing rebuild
  guarantee: "do I need `make clean` after a `version.mk`
  bump?"). A5's analogue would lift a **mechanically obvious
  surface** — the `ccflags-y += -DCONFIG_NV_TB_EGPU` line is
  literally one line below the comment block, and any reader who
  can read `ccflags-y` knows that `-D` flags are visible to all
  TUs in the module. The information is already encoded in the
  file structure; lifting it into the comment block would inflate
  the comment beyond the proven legacy P7 ancestor's shape
  (`patches/legacy/0007-tb-egpu-version-mark-and-kbuild.patch:133-150`
  — the legacy in-file comment for `CONFIG_NV_TB_EGPU` is
  identical to A5's current shape, no consumer-side mechanic
  documented in-file) for content that lives durably in the
  intent. Default-reject (low value, low cost — case-by-case;
  declined because no real footgun is removed).

### A5-version-and-toggles-I3 — Sharpen "Build is 'always y' today" wording

- **Lens:** quality
- **Current state:** A5's in-file comment block contains the
  sentence "Build is 'always y' today; the symbol is defined for
  future use." Read in isolation, the "always y" phrase could be
  misread as "the toggle is hardcoded to y and cannot be
  overridden". The declaration two lines below
  (`CONFIG_NV_TB_EGPU ?= y` — the `?=` allowing override on the
  make command line) resolves the ambiguity for a careful reader,
  but the cumulative read order is comment-first / declaration-second.
- **Proposed state:** Replace "Build is 'always y' today" with
  "Default y; `?=` allows orchestrator override at the make
  command line" or similar.
- **Value:** Microscopic clarity gain — removes a one-sentence
  ambiguity that a careful reader resolves anyway by reading the
  next declaration line.
- **Cost:** One sentence rewritten in one file. The legacy P7
  ancestor's comment uses the same "Build is 'always y' today"
  language verbatim
  (`/root/nvidia-driver-injector/patches/legacy/0007-tb-egpu-version-mark-and-kbuild.patch:139`),
  so changing A5 would create a stylistic drift from the proven
  ancestor.
- **Verification mode:** A.
- **Intent impact:** none.
- **Triage decision:** reject.
- **Resolution:** rejected — the ambiguity is resolved by the
  next declaration line (`CONFIG_NV_TB_EGPU ?= y`), the proven
  legacy P7 ancestor uses the same wording verbatim
  (`patches/legacy/0007-tb-egpu-version-mark-and-kbuild.patch:139`),
  and the change would introduce stylistic drift without removing
  any real footgun. Default-reject.

### A5-version-and-toggles-I4 — Document the A5↔C1 carve relationship in A5's intent Scope boundary

- **Lens:** invariant clarity / sovereignty
- **Current state:** A5's intent already names the A5↔C1
  boundary at two locations: Purpose paragraph (lines 13-37
  citing [[C1-kbuild-version-mk]]'s `version.mk`-as-single-source-of-truth
  plumbing) and Scope boundary clause 3 (lines 181-186 — "This
  patch does NOT modify the kbuild include of
  `$(src)/../version.mk`... Those changes are owned by
  [[C1-kbuild-version-mk]] and pre-date A5 in the fork-branch
  sequence"). C1's catalog deferred its own analogous
  observation (`docs/patch-improvements/C1-kbuild-version-mk.md:90-100`
  — C1-I4 deferred: "Document the carve relationship to addon
  A5 in the intent's Scope boundary"). The A5-side coverage is
  already richer than C1-I4 proposed for C1's side.
- **Proposed state:** No change. The A5↔C1 boundary is already
  fully documented from A5's perspective.
- **Value:** N/A (no proposed change).
- **Cost:** N/A.
- **Verification mode:** A.
- **Intent impact:** none.
- **Triage decision:** reject.
- **Resolution:** rejected — already adequately documented in
  A5's intent (Purpose paragraph + Scope boundary clause 3 +
  Provenance "Vanilla baseline" sub-bullet at lines 236-244).
  The carve relationship is **symmetric**: C1 owns plumbing
  (mechanism), A5 owns value (project-local suffix). Both sides'
  intent files explicitly carve at the same boundary. No
  dedup opportunity surfaces because the patches are mechanically
  orthogonal — C1 changes the Kbuild macro derivation, A5
  changes the upstream `NVIDIA_VERSION` value. They compose
  cleanly without either knowing about the other's internals.

## Re-examination of sub-cycle 2 deferrals

A5's v2 review documented three D-entries (D1, D2, D3 at lines 259,
298, 337 of `docs/patch-reviews/A5-version-and-toggles.md`), all
severity `out-of-scope`. Re-examination:

- **A5-D1** (A1-D2 collapses: no source-list gate, A1 stays
  unconditional) → v3 disposition: **upheld** (already adjudicated
  at v2-review time; no code change, no aspirational gate added,
  v1 stance preserved). Evidence: A5's intent at lines 159-176
  (Scope boundary clause 1) explicitly documents the "no
  source-list gate" stance; the legacy P7 ancestor at
  `patches/legacy/0007-tb-egpu-version-mark-and-kbuild.patch:47-53`
  documents the same "full opt-out at this gate would require
  wrapping the eGPU additions across P1-P5 in `#ifdef`... Out of
  scope for the refactor" rationale verbatim. The aorus
  archaeology offers no new evidence to flip — the aorus repo
  has no `CONFIG_NV_TB_EGPU` ancestor at all, so the question
  of "should A1's row be gated?" has no aorus-side precedent.
  The v2 adjudication holds.
- **A5-D2** (A4-D3 prose drift: A4 review's "A5 gates A4 source-list
  rows" claim is corrected by A5's truthful stance) → v3
  disposition: **upheld and superseded by post-v2 fix**. The v2
  delta recorded the prose drift but explicitly left A4's
  review file untouched ("the A4 file itself is left untouched
  per the no-retroactive-prose-edit policy (the truth lives in
  A5's intent + this review)"). **Post-v2, the e8fb311 commit**
  (`docs: reconcile cross-patch prose drift (C2/C4/C5 + A4/A5)`,
  2026-05-23) **did** retroactively edit A4's intent + review to
  align with A5's truthful stance — see
  `git show e8fb311` for the full reconciliation. A4 intent
  Scope boundary (~lines 325-335 after e8fb311) and A4 review
  interaction-contract (~lines 673-685 after e8fb311) now match
  A5's intent. A5-D2 is therefore **upheld at v2-review-time +
  retroactively healed** — the prose drift no longer exists
  anywhere in the patchset. No v3-side action needed; the
  e8fb311 fix lives outside this catalog (it predates this v3
  review by one commit but matches the same campaign).
- **A5-D3** (explicit no-must-fix; v1 already meets v2 intent) →
  v3 disposition: **upheld**. Evidence: the v1 commit
  `git show 9d62f2e6 --stat` reports `2 files changed, 14
  insertions(+), 1 deletion(-)` — exactly matching the intent's
  Provenance section's "Exactly two files modified, 14 net
  lines added" claim (intent lines 245-248). All four Scenarios
  (intent lines 60-72, 74-85, 109-119, 121-138, 140-155) are
  satisfiable by inspection of v1. No code change required.

The three D-entries collectively cover the entire v2 delta surface
for A5. The four v3-considered improvements above are all `defer`
or `reject` — no improvement landed code-side, no Requirement /
Scenario refined intent-side. The zero-delta sentinel
`v1-tip-sha == v2-tip-sha == 9d62f2e6445a8899643f2f04ee8397e16ec6be16`
holds.

## Improvements landed

(none — all four v3-considered improvements are defer or reject;
A5 is build-system metadata where the default-reject discipline
applies strongly. Zero-delta v3 outcome; fork branch unchanged.)

## Intent updates landed

(none — zero substantive intent changes; A5-I1's Provenance
addition was deferred; A5-I2/I3/I4 have Intent impact `none`.
A5's intent stays at sub-cycle 2's `reviewed` status with no
re-lint required.)

## Done gate

- [x] Every candidate improvement has explicit `Resolution:` (no `pending`).
- [x] All "land" improvements applied as fork-branch commits citing their `<id>-I<N>` IDs. _(N/A — zero land-tier improvements; A5-I1 deferred, A5-I2/I3/I4 rejected.)_
- [x] Substantive intent updates landed as precursor commits. _(N/A — zero substantive intent updates; A5-I1 deferred without precursor.)_
- [x] `tools/intent-lint.sh` passes _(no intent change; lint re-verified, exit 0)._
- [x] `tools/validate-patchset.sh` passes (compile gate; composed C1-A5 patchset, exit 0).
- [x] `bash tests/run.sh` green (34 ok / 0 failed expected; gate re-run at catalog closeout).
- [ ] Audit-reviewer subagent approved. _(Pending — this catalog file is the audit-reviewer's input for Task 13.)_

## Cross-references

- Intent file: `docs/patch-intents/A5-version-and-toggles.md`
- Review file: `docs/patch-reviews/A5-version-and-toggles.md`
- Manifest row: `patches/manifest` line for `A5-version-and-toggles` (layer `addon`, source `fork:a5-version-and-toggles`)
- Vanilla baseline:
  - `kernel-open/Kbuild:82` (vanilla 595.71.05 hardcoded `-DNV_VERSION_STRING=\"595.71.05\"`; no `CONFIG_NV_TB_EGPU` symbol exists)
  - `version.mk:1` (vanilla defines `NVIDIA_VERSION = 595.71.05`)
- Fork branch: `a5-version-and-toggles` on `apnex/open-gpu-kernel-modules` (v1 tip `9d62f2e6445a8899643f2f04ee8397e16ec6be16`; v2 tip identical — zero-delta v3)
- aorus-5090 ancestors:
  - `/root/aorus-5090-egpu/patches/0005-version-mark-aorus-build.patch` (the drift-introducing version-stamp predecessor)
  - `/root/aorus-5090-egpu/patches/0025-Kbuild-version-from-version-mk.patch` (the drift-fix predecessor; mechanically C1's ancestor, but referenced because A5 piggybacks on the mechanism)
  - **No aorus-5090 ancestor for `CONFIG_NV_TB_EGPU`** — the symbol is a sub-cycle-2 invention; the `tb_egpu_*` / `TB_EGPU_*` naming convention is the relevant ancestor
- Legacy injector ancestor: `/root/nvidia-driver-injector/patches/legacy/0007-tb-egpu-version-mark-and-kbuild.patch` (the P7 cluster — combined C1's mechanism + A5's value + the dropped `CONFIG_NV_TB_EGPU_DIAG` toggle into one patch; the 2026-05-22 recarve split it into C1+A5 and dropped DIAG)
- aorus-5090 design + naming convention:
  - `/root/aorus-5090-egpu/docs/architecture-and-modularity.md:84-100` (L1 currently-hosts table; line 88 names version-mark as "string only, no logic — necessary in fork to track which patches are present")
  - `/root/aorus-5090-egpu/CLAUDE.md:40` (project identifier-prefix convention: `tb_egpu_*` / `NVreg_TbEgpu*` / `TB_EGPU_*`)
  - `/root/aorus-5090-egpu/tools/lint-identifiers.sh:10-11` (enforced naming-drift policy)
- Upstream issue: n/a (addon-layer; not upstream-bound; per Rule 5 `upstream-candidacy: n/a` for `layer: addon`)
- Community signal: `docs/patch-improvements/_community-signal.md:135` ("no findings tagged for A5") — explicit no-evidence; A5 has no runtime symptom to share with any community report
- Related catalogs:
  - `docs/patch-improvements/C1-kbuild-version-mk.md` (mechanically the closest analogue — both are Kbuild-metadata patches; C1-I1 lifted a load-bearing dynamic invariant in-file, A5-I2 considered the analogous move and rejected because the surface is mechanically obvious rather than non-obvious)
  - `docs/patch-improvements/A1-pcie-primitives.md` (A1-D2 "gate A1's row on `CONFIG_NV_TB_EGPU`?" was deferred to A5's review and adjudicated as no-gate per A5-D1)
  - `docs/patch-improvements/A4-close-path-telemetry.md` (A4-D3 lockstep RM+UVM gate requirement preserved as future-design context; A4 review's prose drift about A5 gating A4 source-list rows was corrected by e8fb311)
