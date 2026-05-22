# Dynamic patch composition for the injector — design

**Status:** approved design — 2026-05-22. Defines the mechanism; the
implementation plan is produced separately (writing-plans).

## Context

Today the injector applies a flat, hand-curated set `patches/0001-0007` to a
pinned NVIDIA upstream tag (`595.71.05`) at **image-build time** — the patched
source tree is baked into the image; `entrypoint.sh` only compiles it against
the host kernel at runtime.

The C/E/A geometry (`docs/upstream-plan.md`) is explicitly designed for the
**base layer to shrink monotonically** as the `C1–C5`/`E1` patches land
upstream. The flat hardcoded list does not survive that evolution: the day the
injector builds against a NVIDIA release that already contains, say, `C3`,
re-applying `C3.patch` is a hard failure. This design replaces the flat list
with a layered, manifest-driven composition that the injector assembles,
validates, and applies — and that shrinks cleanly as base patches are absorbed
upstream.

This is the **blend** of two approaches evaluated in brainstorming: a
declarative manifest as the source of truth (auditable, build-time verified)
plus a regeneration tool that refreshes the base patches from the fork against
a moving upstream tag.

## Scope

**In scope:** the composition mechanism — the manifest, the `patches/` layout,
the regen tool, the compose tool, the validation tooling, and the Dockerfile
integration.

**Out of scope (implementation work that *populates* this mechanism, tracked by
`docs/production-migration.md`):** the content of the `A1–A5` re-carve against
the de-branded `C5` bridge; upstream PR submission.

**Deliberately excluded (YAGNI):**

- Runtime / host-environment patch selection — the injector targets one
  hardware project; there is no heterogeneous fleet.
- Per-kernel patch variants — runtime compilation already absorbs kernel
  variation, and the 6.19→7.0 source review found the patch set kernel-agnostic.
- A fork submodule as the base delivery mechanism — a provenance regression
  (the injector would stop building from stock NVIDIA) and it buries the delta
  in fork history instead of keeping it readable as patch files.
- `make modules` inside the image build — fights the Approach-B design (the
  image deliberately carries no kernel-devel; it builds against the host's
  bind-mounted kernel at runtime).

## Key finding — the base is a stacked series

The six fork base branches on `apnex/open-gpu-kernel-modules` are **one stacked
series** off the `595.71.05` tag, each branch a checkpoint:

```
595.71.05 ─ C1 ─ C2 ─ C3 ─ C4 ─ E1 ─ C5a ─ C5b
            │    │    │    │    │          └── c5-crash-safety  (tip = whole stack)
            │    │    │    │    └── e1-egpu-detection
            │    │    │    └── c4-err-handlers-scaffold
            │    │    └── c3-gpu-lost-retry
            │    └── c2-aer-internal-unmask
            └── c1-kbuild-version-mk
```

Two consequences shape the design:

1. **Apply order is fixed by the stack: `C1 → C2 → C3 → C4 → E1 → C5`.** `E1`
   sits *before* `C5` — this is the validated stack order, and it differs from
   the upstream *submission* order (`C1–C5` then `E1`). The injector uses stack
   order; submission order is a fork/PR concern only.
2. **Each logical patch = the diff between consecutive checkpoints**
   (`C1 = diff(595.71.05..c1)`, `C2 = diff(c1..c2)`, … `C5 = diff(e1..c5)`,
   where `C5` combines its two commits into one patch file). Extraction and
   regeneration are therefore mechanical.

Note: `docs/upstream-plan.md` describes these as "one branch each" /
"independent PRs." They are logically independent *as PRs* but physically a
stack. This design relies on the stack reality; the `upstream-plan.md` phrasing
should be reconciled to say so.

## Architecture & layout

```
patches/
  manifest                       # declared contract — hand-curated + regen-updated
  base/                          # GENERATED from the fork stack — never hand-edited
    C1-kbuild-version-mk.patch
    C2-aer-internal-unmask.patch
    C3-gpu-lost-retry.patch
    C4-err-handlers-scaffold.patch
    E1-egpu-detection.patch
    C5-crash-safety.patch
    .regen-state                 # fork SHAs the patches were exported from
  addon/                         # hand-authored, project-local — the A layer
    A1-qwatchdog.patch
    A2-recovery.patch
    A3-close-path.patch
    A4-diag-telemetry.patch
    A5-version-and-toggles.patch
  legacy/                        # today's 0001-0007, kept until the soak passes
tools/
  regen-base-patches.sh          # fork stack → patches/base/   (offline; on tag bumps)
  compose-patchset.sh            # manifest   → ordered apply list (build-time)
  validate-patchset.sh           # real `make modules` compile gate (regen + CI)
```

The `base/` vs `addon/` split is load-bearing: it makes the
**generated-vs-authored boundary physical**. Every file in `base/` is a
derivative of the fork stack and carries a provenance header
(`# GENERATED by tools/regen-base-patches.sh … do not hand-edit`); every file
in `addon/` is authored in this repo. The split also matches authoring homes —
the base layer is authoritative on the fork, the addon layer is authoritative
in the injector.

## The manifest — the declared contract

A line-oriented, `awk`-parseable file (matching the project's shell idiom).
**Row order = apply order.**

```
# id                       layer  upstreamed_in  source
  C1-kbuild-version-mk      base   -              fork:c1-kbuild-version-mk
  C2-aer-internal-unmask    base   -              fork:c2-aer-internal-unmask
  C3-gpu-lost-retry         base   -              fork:c3-gpu-lost-retry
  C4-err-handlers-scaffold  base   -              fork:c4-err-handlers-scaffold
  E1-egpu-detection         base   -              fork:e1-egpu-detection
  C5-crash-safety           base   -              fork:c5-crash-safety
  A1-qwatchdog              addon  -              injector
  A2-recovery               addon  -              injector
  A3-close-path             addon  -              injector
  A4-diag-telemetry         addon  -              injector
  A5-version-and-toggles    addon  -              injector
```

Columns:

- `id` — the logical patch identity; the `C`/`E`/`A` prefix carries the
  upstream-geometry meaning. Also the `patches/<layer>/<id>.patch` filename stem.
- `layer` — `base` (regenerated from the fork) or `addon` (hand-authored). This
  is the operational distinction the build acts on.
- `upstreamed_in` — `-` means still needed; otherwise the NVIDIA tag whose
  source already contains the change. **Maintained by `regen-base-patches.sh`;**
  a hand-edit is the override/fallback path only.
- `source` — `fork:<branch>` checkpoint for base rows; `injector` for addon rows.

The manifest is the single source of truth the build reads. It is what makes
"why is `C3` no longer applied?" answerable from one declarative file rather
than from git archaeology.

## Component — `regen-base-patches.sh` (the dynamic step, offline)

Runs on a developer machine when bumping `NVIDIA_OPEN_TAG`, or to refresh the
base patches after a PR lands. **Not** part of the image build.

1. Takes a target tag (default: the current `NVIDIA_OPEN_TAG`).
2. Rebases the fork base stack onto that tag in a fork worktree, re-pointing the
   six checkpoint branches.
3. **Empty commit → absorbed upstream:** if a checkpoint's changes are already
   present in the target tag, `git rebase` drops it as empty. Regen reports
   `"C3 appears absorbed in <tag>"` and, **with explicit human confirmation**,
   sets that row's `upstreamed_in` in the manifest and removes the
   `patches/base/<id>.patch` file.
4. **Conflict → stop:** if a checkpoint conflicts (upstream churned adjacent
   code), regen halts and hands the worktree to the human. It never
   auto-resolves and never auto-skips — *declared, not inferred*. The resolution
   improves the fork branch; regen then resumes.
5. Re-exports each surviving checkpoint as `git diff <prev>..<checkpoint>` →
   `patches/base/<id>.patch`, each with a provenance header; writes
   `patches/base/.regen-state` recording the exact fork SHAs used.
6. Runs `validate-patchset.sh` before declaring success.

Regen output is **committed to the injector repo**. The image build therefore
never needs the fork — the committed `patches/` + `manifest` are the
reproducible, reviewable artifact.

## Component — `compose-patchset.sh` (the build step, deterministic)

Runs inside the Docker build, against the freshly cloned upstream tree. Pure and
deterministic — no network, no fork, no rebasing.

1. **Consistency check** — fails loud unless `patches/` matches the manifest
   exactly: every row with `upstreamed_in = -` has a file; every row with
   `upstreamed_in` set has *no* file; no orphan files; no duplicate ids; every
   `source: fork:*` row is in `base/`, every `injector` row is in `addon/`.
2. **Emits** the ordered apply list in manifest row order (base stack order,
   then addon).
3. The Dockerfile applies each in turn — `git apply --check` then `git apply` —
   failing loud and naming the patch on any mismatch, with the hint to run
   `tools/regen-base-patches.sh` if it looks like upstream-tag drift.

The dynamism is resolved at regen time and **frozen into the committed
`patches/` + manifest**; the build is deterministic and fail-fast. This is
intentional: it preserves the Dockerfile's "fail at image-build, not pod-start"
principle and keeps the build self-contained and reproducible.

## Data flow — three lifecycles

| Lifecycle | What happens | Who / where |
|---|---|---|
| Normal image build | `compose-patchset.sh` verifies + emits; Dockerfile applies `base/` then `addon/` | CI / build — automatic |
| A PR lands upstream | next regen detects the empty commit, sets `upstreamed_in`, drops the file | regen, on the next tag bump |
| Bump `NVIDIA_OPEN_TAG` | run `regen-base-patches.sh <new-tag>` → rebases stack, re-exports `base/`, updates manifest; review the diff; commit | developer, offline |

`addon/` is never regenerated. If a tag bump breaks an addon patch,
`validate-patchset.sh` catches it and the human fixes it in place — correct,
since the injector is the addon layer's authoring home.

## Validation — three tiers

Honours the project rule that `git apply --check` is not validation:

1. **Structural** — `git apply --check`, in the image build. Fast; catches
   drift. (Today's mechanism, retained.)
2. **Compile** — `validate-patchset.sh` runs a real `make modules` against a
   kernel tree (`7.0.9-204.fc44`). Invoked by `regen-base-patches.sh` and by
   CI. This is the new gate — today nothing compile-checks the composed patch
   set before runtime.
3. **Runtime compile** — `entrypoint.sh` step 3, against the actual host
   kernel. Unchanged; the ultimate gate.

`make modules` stays out of the Dockerfile by design (see Scope — the
Approach-B image carries no kernel-devel).

## Error handling

- **Manifest ↔ files mismatch** → `compose-patchset.sh` fails the image build,
  naming the discrepancy.
- **A base patch fails `git apply --check`** → build fails, names the patch,
  hints at upstream-tag drift and `regen-base-patches.sh`.
- **An addon patch fails** → build fails; the patch is hand-authored, so this is
  real drift for a human to fix in place.
- **Regen rebase conflict** → regen halts, leaves the worktree for the human; no
  auto-resolution.
- **Regen empty commit** → reported; manifest update applied only on explicit
  human confirmation.
- **Malformed / unknown tag in `upstreamed_in`** → `compose-patchset.sh` fails
  the consistency check.

## Testing

- `validate-patchset.sh` — real `make modules` compile of the composed set.
- Manifest internal-consistency check — no duplicate ids, source branches
  resolve, layer/path agreement.
- **Regen round-trip / idempotence** — running `regen-base-patches.sh` against
  the *current* pinned tag reproduces the committed `patches/base/`
  byte-for-byte; proves regen is deterministic.
- The production soak (`docs/production-migration.md` Gate) remains the runtime
  test of the composed driver.

## Relationship to `production-migration.md` Step 3

This design **answers Step 3's open design question #1** — base delivery is
generated patch files under `patches/base/`, not a submodule — and **reshapes
the Step 3 sequence**. Step 3's "extract base / re-carve A / restructure /
reconcile" becomes: build the three tools + the manifest, run
`regen-base-patches.sh` to populate `patches/base/`, re-carve `patches/addon/`,
then wire the Dockerfile to `compose-patchset.sh`. Step 3's later steps —
rebuild the image, soak, cut over, upstream PRs — are unchanged. The
implementation plan sequences this concretely.
