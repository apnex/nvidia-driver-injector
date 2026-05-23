---
id: PATCH-ID-HERE
review-date: 2026-05-DD
reviewer: Claude Opus 4.7
v1-tip-sha: SHA-BEFORE-V3-COMMITS
v2-tip-sha: pending
status: in-progress
intent-updates: []
---

# PATCH-ID-HERE — improvement triage

## Triangulation sources

- **Vanilla NVIDIA 595.71.05:** `kernel-open/<file>:<symbol>` (and other touched files).
- **v2 intent:** `docs/patch-intents/PATCH-ID-HERE.md`.
- **v2 review:** `docs/patch-reviews/PATCH-ID-HERE.md`.
- **aorus-5090 ancestor patch:** `/root/aorus-5090-egpu/patches/<filename>.patch`.
- **aorus-5090 docs:** `<paths + section anchors>`.
- **Community-signal entries:** `<section in _community-signal.md>` (or "none tagged"). When citing community-signal evidence: **distinguish error-code commonality from code-path commonality.** A reported issue may share the same symptom (`NV_ERR_GPU_IS_LOST`) without exercising the same patched code path. Frame supporting evidence as "upstream-PR-rationale strengthening" unless the reported failure demonstrably runs through the patched site.

## v1 archaeology

(What the aorus-5090 mining surfaced. Every claim MUST cite a specific
aorus-5090 source path + **line range** — 5-line windows are audit-friendly.)

- **Original design intent:** <citation>
- **Constraints discovered:** <citation>
- **Alternatives considered + rejected:** <citation>
- **Forgotten / latent invariants:** <citation>

## Improvements considered

### PATCH-ID-HERE-I1 — Example improvement title

- **Lens:** sovereignty | robustness | dedup | duty | naming | performance | quality | invariant clarity
- **Current state:** <code excerpt or intent reference>
- **Proposed state:** <what changes>
- **Value:** <concrete: correctness / robustness / clarity / perf gain>
- **Cost:** <LoC delta, complexity delta, risk delta>
- **Verification mode:** A (code-reading) | B (observable assertion)
- **Intent impact:** none | refine Scenario <name> | add Requirement <name>
- **Triage decision:** land | defer | reject
- **Resolution:** pending

(repeat for each improvement; if no improvements surface, replace this
section with "(no improvements surfaced — v2 already meets v3 quality bar)")

## Re-examination of sub-cycle 2 deferrals

(If the patch's sub-cycle 2 review file deferred any nice-to-have or
should-fix items, list them here with the v3 disposition. Aorus
archaeology may strengthen the deferral, surface new evidence that
flips it to "land", or leave the disposition unchanged. Each entry
cites the sub-cycle 2 deferral ID + the v3 disposition + the
archaeological evidence that informed it.)

- **`<v2-D-id>`:** <one-line description> → v3 disposition: **upheld** | **flipped to land** | **reframed**. Evidence: <aorus path + line range>.

(or "(no sub-cycle 2 deferrals for this patch)")

## Improvements landed

(populate in step 11 — one line per landed improvement with SHAs)

## Intent updates landed

(populate in step 11 — one line per intent edit with precursor commit SHAs)

## Done gate

- [ ] Every candidate improvement has explicit `Resolution:` (no `pending`).
- [ ] All "land" improvements applied as fork-branch commits citing their `<id>-I<N>` IDs.
- [ ] Substantive intent updates landed as precursor commits.
- [ ] `tools/intent-lint.sh` passes.
- [ ] `tools/validate-patchset.sh` passes.
- [ ] `bash tests/run.sh` green.
- [ ] Audit-reviewer subagent approved.

## Cross-references

- Intent file: `docs/patch-intents/PATCH-ID-HERE.md`
- Review file: `docs/patch-reviews/PATCH-ID-HERE.md`
- Manifest row: `patches/manifest` line for `PATCH-ID-HERE`
- Vanilla baseline: `kernel-open/<dir>/<file>:<symbol>`
- Fork branch: `BRANCH-NAME-HERE` on `apnex/open-gpu-kernel-modules`
- aorus-5090 ancestor: `/root/aorus-5090-egpu/patches/<filename>.patch`
- Upstream issue: URL or "n/a"
- Community signal: `docs/patch-improvements/_community-signal.md` <section>
