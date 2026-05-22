# Dynamic Patch Composition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the injector's flat, hand-curated `patches/0001-0007` list with a manifest-driven `base/`+`addon/` patch set that the build composes, verifies, and applies — and that can shrink as base patches land upstream.

**Architecture:** A line-oriented `patches/manifest` is the declared contract. `tools/regen-base-patches.sh` generates `patches/base/*.patch` from the fork's stacked base series. `tools/compose-patchset.sh` verifies the patch set against the manifest and emits the ordered apply list, which the Dockerfile applies. `tools/validate-patchset.sh` compiles the composed set as a gate. This plan delivers the mechanism and populates the base layer; the addon layer (the `A1–A5` re-carve) is a follow-on.

**Tech Stack:** Bash, git, GNU make, Docker, the NVIDIA `open-gpu-kernel-modules` build.

---

## Context & scope

This plan implements `docs/superpowers/specs/2026-05-22-dynamic-patch-composition-design.md`. Read that spec first.

**Delivered here:** the test harness, the manifest, the three tools, the `patches/` restructure, and the Dockerfile rewire — validated end to end against the **base layer**.

**Explicitly deferred (a follow-on plan):**

- **The addon layer.** `patches/addon/` and the `A1–A5` re-carve (re-expressing `A1`/`A2` against the de-branded `C5` bridge) are genuine design work; `production-migration.md` §3 owns them. The manifest in this plan therefore lists only the six base rows; `compose-patchset.sh` handles a manifest gaining addon rows later with no change.
- **The tag-bump rebase path of `regen-base-patches.sh`.** Rebasing the fork stack onto a *new* upstream tag cannot be developed or tested until a real new tag exists. `regen` here implements the extraction path (export the stack at its current tag) and fails loudly with guidance if asked to operate on a stack not based on the target tag.
- **Image rebuild → soak → cutover → upstream PRs:** `production-migration.md` steps 5–8.

**Working state:** all work is on branch `migration/dynamic-patch-composition`. The injector's running production driver is unaffected until `production-migration.md` step 7 (cutover).

## File structure

| File | Responsibility |
|---|---|
| `tests/lib.sh` | Minimal shell assertion harness |
| `tests/run.sh` | Runs every `tests/test-*.sh` |
| `tests/test-manifest-lib.sh` | Tests for `tools/lib/manifest.sh` |
| `tests/test-compose.sh` | Tests for `tools/compose-patchset.sh` |
| `tools/lib/manifest.sh` | Manifest parsing + lint — shared by the tools |
| `tools/compose-patchset.sh` | Verify patch set vs manifest; emit ordered apply list (build-time) |
| `tools/regen-base-patches.sh` | Generate `patches/base/*.patch` from the fork stack (offline) |
| `tools/validate-patchset.sh` | Apply composed set to a clean tree + `make modules` (compile gate) |
| `patches/manifest` | The declared contract — six base rows |
| `patches/base/*.patch` | Generated base patches (produced by `regen`, committed) |
| `patches/legacy/` | Today's `0001-0007` move here (alongside the older legacy set) |
| `Dockerfile` | Rewired to apply the composed set instead of `ls patches/*.patch` |

---

## Task 1: Test harness

**Files:**
- Create: `tests/lib.sh`
- Create: `tests/run.sh`

- [ ] **Step 1: Write the harness library**

Create `tests/lib.sh`:

```bash
#!/usr/bin/env bash
# Minimal shell test harness for the patch-composition tooling.
# Each tests/test-*.sh sources this, calls assert_*, and ends with finish_tests.

_tests_run=0
_tests_failed=0

assert_eq() {  # actual expected message
    _tests_run=$((_tests_run + 1))
    if [ "$1" = "$2" ]; then
        printf '  ok   %s\n' "$3"
    else
        _tests_failed=$((_tests_failed + 1))
        printf '  FAIL %s\n' "$3"
        printf '       expected: [%s]\n' "$2"
        printf '       actual:   [%s]\n' "$1"
    fi
}

assert_exit() {  # expected-code message -- command...
    local expected="$1" msg="$2"; shift 2
    _tests_run=$((_tests_run + 1))
    "$@" >/dev/null 2>&1
    local got=$?
    if [ "$got" -eq "$expected" ]; then
        printf '  ok   %s\n' "$msg"
    else
        _tests_failed=$((_tests_failed + 1))
        printf '  FAIL %s (exit %s, expected %s)\n' "$msg" "$got" "$expected"
    fi
}

finish_tests() {
    printf '%s: %d run, %d failed\n' "${0##*/}" "$_tests_run" "$_tests_failed"
    [ "$_tests_failed" -eq 0 ]
}
```

- [ ] **Step 2: Write the runner**

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
# Run every tests/test-*.sh; exit non-zero if any test file fails.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in "$here"/test-*.sh; do
    [ -e "$t" ] || continue
    printf '== %s ==\n' "${t##*/}"
    bash "$t" || rc=1
done
exit "$rc"
```

- [ ] **Step 3: Make executable and verify the runner works with zero tests**

Run:
```bash
cd /root/nvidia-driver-injector
chmod +x tests/run.sh tests/lib.sh
bash tests/run.sh; echo "exit=$?"
```
Expected: prints nothing for tests (none yet), `exit=0`.

- [ ] **Step 4: Commit**

```bash
git add tests/lib.sh tests/run.sh
git commit -m "$(printf 'test: add minimal shell test harness\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"
```

---

## Task 2: Manifest parsing library

**Files:**
- Create: `tests/test-manifest-lib.sh`
- Create: `tools/lib/manifest.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test-manifest-lib.sh`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
. "$here/../tools/lib/manifest.sh"

d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT

# manifest_rows strips comments and blank lines, keeps order
cat > "$d/m" <<'M'
# a comment

  C1-a  base  -  fork:c1
  C2-b  base  -  fork:c2
M
rows="$(manifest_rows "$d/m")"
assert_eq "$rows" "  C1-a  base  -  fork:c1
  C2-b  base  -  fork:c2" "manifest_rows strips comments/blanks, keeps order"

# manifest_lint accepts a well-formed manifest
manifest_lint "$d/m" 2>/dev/null
assert_eq "$?" "0" "manifest_lint accepts a valid manifest"

# manifest_lint rejects a bad layer value
printf '  C1-a  CORE  -  fork:c1\n' > "$d/bad-layer"
manifest_lint "$d/bad-layer" 2>/dev/null
assert_eq "$?" "1" "manifest_lint rejects an invalid layer"

# manifest_lint rejects a duplicate id
printf '  C1-a  base  -  fork:c1\n  C1-a  base  -  fork:c2\n' > "$d/dup"
manifest_lint "$d/dup" 2>/dev/null
assert_eq "$?" "1" "manifest_lint rejects a duplicate id"

# manifest_lint rejects a row with the wrong field count
printf '  C1-a  base  -\n' > "$d/short"
manifest_lint "$d/short" 2>/dev/null
assert_eq "$?" "1" "manifest_lint rejects a row with too few fields"

finish_tests
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /root/nvidia-driver-injector && bash tests/test-manifest-lib.sh`
Expected: FAIL — `tools/lib/manifest.sh` does not exist, so the `source` line errors (`No such file or directory`).

- [ ] **Step 3: Write the manifest library**

Create `tools/lib/manifest.sh`:

```bash
# Shared manifest helpers for the patch-composition tools.
# Manifest format: whitespace-separated columns, one patch per row --
#   id  layer  upstreamed_in  source
# '#' comments and blank lines are ignored.  Row order = apply order.
# '-' is the empty value for upstreamed_in (still needed) and source.

# Print the data rows of a manifest file, in order, comments/blanks removed.
manifest_rows() {
    grep -vE '^[[:space:]]*(#|$)' "$1"
}

# Validate a manifest file. Prints errors to stderr; returns non-zero if invalid.
manifest_lint() {
    local file="$1" rc=0 seen="" id layer up src extra n
    while read -r id layer up src extra; do
        n=$(printf '%s %s %s %s' "$id" "$layer" "$up" "$src" | wc -w)
        if [ -n "$extra" ] || [ "$n" -ne 4 ]; then
            echo "manifest: row '$id': expected 4 fields" >&2; rc=1; continue
        fi
        case "$layer" in
            base|addon) ;;
            *) echo "manifest: row '$id': bad layer '$layer' (want base|addon)" >&2; rc=1 ;;
        esac
        case " $seen " in
            *" $id "*) echo "manifest: duplicate id '$id'" >&2; rc=1 ;;
        esac
        seen="$seen $id"
    done <<EOF
$(manifest_rows "$file")
EOF
    return $rc
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /root/nvidia-driver-injector && bash tests/test-manifest-lib.sh`
Expected: `5 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add tools/lib/manifest.sh tests/test-manifest-lib.sh
git commit -m "$(printf 'feat: add manifest parsing + lint library\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"
```

---

## Task 3: The manifest file

**Files:**
- Create: `patches/manifest`

- [ ] **Step 1: Write the manifest**

Create `patches/manifest` (column alignment is cosmetic; rows are whitespace-separated). Row order is the fork stack order `C1 → C2 → C3 → C4 → E1 → C5` — note `E1` precedes `C5`:

```
# Patch manifest -- the declared contract for the injector's patch set.
# See docs/superpowers/specs/2026-05-22-dynamic-patch-composition-design.md
#
# Columns:  id  layer  upstreamed_in  source
#   id             logical patch id; file is patches/<layer>/<id>.patch
#   layer          base (generated by regen) | addon (hand-authored)
#   upstreamed_in  '-' = still needed; else the NVIDIA tag that absorbed it
#   source         fork:<branch> for base rows; 'injector' for addon rows
# Row order = apply order.
#
# id                        layer  upstreamed_in  source
  C1-kbuild-version-mk       base   -              fork:c1-kbuild-version-mk
  C2-aer-internal-unmask     base   -              fork:c2-aer-internal-unmask
  C3-gpu-lost-retry          base   -              fork:c3-gpu-lost-retry
  C4-err-handlers-scaffold   base   -              fork:c4-err-handlers-scaffold
  E1-egpu-detection          base   -              fork:e1-egpu-detection
  C5-crash-safety            base   -              fork:c5-crash-safety
```

- [ ] **Step 2: Verify the manifest lints clean**

Run:
```bash
cd /root/nvidia-driver-injector
bash -c '. tools/lib/manifest.sh && manifest_lint patches/manifest && echo LINT_OK'
```
Expected: `LINT_OK`.

- [ ] **Step 3: Commit**

```bash
git add patches/manifest
git commit -m "$(printf 'feat: add patch manifest with the six base rows\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"
```

---

## Task 4: Compose tool

**Files:**
- Create: `tests/test-compose.sh`
- Create: `tools/compose-patchset.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test-compose.sh`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
COMPOSE="$here/../tools/compose-patchset.sh"

mk() { local d; d="$(mktemp -d)"; mkdir -p "$d/base" "$d/addon"; echo "$d"; }

# Case 1: good manifest, all files present -> ordered apply list
d="$(mk)"
cat > "$d/manifest" <<'M'
# id    layer  upstreamed_in  source
  C1-a  base   -              fork:c1
  C2-b  base   -              fork:c2
M
: > "$d/base/C1-a.patch"
: > "$d/base/C2-b.patch"
out="$("$COMPOSE" --patches-dir "$d" 2>/dev/null)"
assert_eq "$out" "$d/base/C1-a.patch
$d/base/C2-b.patch" "good manifest emits ordered apply list"
rm -rf "$d"

# Case 2: active row, missing file -> exit 1
d="$(mk)"
printf '  C1-a  base  -  fork:c1\n' > "$d/manifest"
assert_exit 1 "missing patch file fails" "$COMPOSE" --patches-dir "$d"
rm -rf "$d"

# Case 3: orphan file with no manifest row -> exit 1
d="$(mk)"
printf '  C1-a  base  -  fork:c1\n' > "$d/manifest"
: > "$d/base/C1-a.patch"
: > "$d/base/ORPHAN.patch"
assert_exit 1 "orphan patch file fails" "$COMPOSE" --patches-dir "$d"
rm -rf "$d"

# Case 4: upstreamed row with file still present -> exit 1
d="$(mk)"
printf '  C1-a  base  596.10.00  fork:c1\n' > "$d/manifest"
: > "$d/base/C1-a.patch"
assert_exit 1 "upstreamed row with leftover file fails" "$COMPOSE" --patches-dir "$d"
rm -rf "$d"

# Case 5: upstreamed row, no file -> ok, omitted from list
d="$(mk)"
cat > "$d/manifest" <<'M'
  C1-a  base  596.10.00  fork:c1
  C2-b  base  -          fork:c2
M
: > "$d/base/C2-b.patch"
out="$("$COMPOSE" --patches-dir "$d" 2>/dev/null)"
assert_eq "$out" "$d/base/C2-b.patch" "upstreamed row skipped, active row remains"
rm -rf "$d"

# Case 6: duplicate id -> exit 1 (lint failure)
d="$(mk)"
printf '  C1-a  base  -  fork:c1\n  C1-a  base  -  fork:c2\n' > "$d/manifest"
: > "$d/base/C1-a.patch"
assert_exit 1 "duplicate id fails lint" "$COMPOSE" --patches-dir "$d"
rm -rf "$d"

finish_tests
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /root/nvidia-driver-injector && bash tests/test-compose.sh`
Expected: FAIL — `tools/compose-patchset.sh` does not exist.

- [ ] **Step 3: Write the compose tool**

Create `tools/compose-patchset.sh`:

```bash
#!/usr/bin/env bash
# compose-patchset.sh -- verify the patch set against the manifest and emit
# the ordered list of patch files to apply (base stack order, then addon).
#
# Usage: compose-patchset.sh [--manifest FILE] [--patches-dir DIR]
#   --patches-dir  default: patches
#   --manifest     default: <patches-dir>/manifest
#
# stdout: one patch file path per line, in apply order.
# exit 1: the manifest and the patch files on disk disagree.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib/manifest.sh"

patches_dir="patches"
manifest=""
while [ $# -gt 0 ]; do
    case "$1" in
        --patches-dir) patches_dir="$2"; shift 2 ;;
        --manifest)    manifest="$2"; shift 2 ;;
        *) echo "compose-patchset: unknown arg '$1'" >&2; exit 2 ;;
    esac
done
[ -n "$manifest" ] || manifest="$patches_dir/manifest"

[ -f "$manifest" ] || { echo "compose-patchset: no manifest at $manifest" >&2; exit 1; }
manifest_lint "$manifest" || exit 1

errors=0
err() { echo "compose-patchset: $*" >&2; errors=$((errors + 1)); }

apply_list=""
listed=""
while read -r id layer up src; do
    file="$patches_dir/$layer/$id.patch"
    listed="$listed $layer/$id.patch"
    if [ "$up" = "-" ]; then
        if [ -f "$file" ]; then
            apply_list="$apply_list$file
"
        else
            err "row '$id' is active but $file is missing"
        fi
    else
        if [ -f "$file" ]; then
            err "row '$id' is marked upstreamed_in=$up but $file still exists"
        fi
    fi
done <<EOF
$(manifest_rows "$manifest")
EOF

for layer in base addon; do
    [ -d "$patches_dir/$layer" ] || continue
    for f in "$patches_dir/$layer"/*.patch; do
        [ -e "$f" ] || continue
        rel="$layer/${f##*/}"
        case " $listed " in
            *" $rel "*) ;;
            *) err "orphan patch file $f has no manifest row" ;;
        esac
    done
done

[ "$errors" -eq 0 ] || { echo "compose-patchset: $errors error(s); patch set does not match manifest" >&2; exit 1; }

printf '%s' "$apply_list"
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd /root/nvidia-driver-injector
chmod +x tools/compose-patchset.sh
bash tests/test-compose.sh
```
Expected: `6 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add tools/compose-patchset.sh tests/test-compose.sh
git commit -m "$(printf 'feat: add compose-patchset build-time composer\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"
```

---

## Task 5: Regen tool

**Files:**
- Create: `tools/regen-base-patches.sh`

This tool reads `patches/manifest`, walks the base rows, and for each writes `patches/base/<id>.patch` = `git diff <prev-checkpoint>..<this-checkpoint>` from the fork. The first checkpoint's previous ref is the upstream tag. It refuses to run if the fork stack is not in `C1→…→C5` order on the target tag (the tag-bump rebase path is out of scope — see Context).

- [ ] **Step 1: Write the regen tool**

Create `tools/regen-base-patches.sh`:

```bash
#!/usr/bin/env bash
# regen-base-patches.sh -- (re)generate patches/base/*.patch from the fork's
# stacked base series (checkpoints C1 -> C2 -> C3 -> C4 -> E1 -> C5).
#
# Each base patch is exported as the diff of its checkpoint against the
# previous checkpoint.  This assumes the fork stack already sits on the
# target NVIDIA tag.  Rebasing the stack onto a NEW upstream tag (the
# tag-bump path) is intentionally NOT implemented here -- see
# docs/superpowers/specs/2026-05-22-dynamic-patch-composition-design.md.
#
# Usage: regen-base-patches.sh [--fork DIR] [--tag TAG]
#   --fork  default: $FORK_REPO or /root/open-gpu-kernel-modules
#   --tag   default: NVIDIA_OPEN_TAG from the injector Dockerfile
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_root/tools/lib/manifest.sh"

fork="${FORK_REPO:-/root/open-gpu-kernel-modules}"
tag=""
while [ $# -gt 0 ]; do
    case "$1" in
        --fork) fork="$2"; shift 2 ;;
        --tag)  tag="$2"; shift 2 ;;
        *) echo "regen: unknown arg '$1'" >&2; exit 2 ;;
    esac
done
[ -n "$tag" ] || tag="$(awk -F= '/^ARG NVIDIA_OPEN_TAG=/{print $2}' "$repo_root/Dockerfile")"
[ -n "$tag" ] || { echo "regen: could not determine target tag" >&2; exit 1; }
[ -d "$fork/.git" ] || { echo "regen: fork repo not found at $fork" >&2; exit 1; }

manifest="$repo_root/patches/manifest"
base_dir="$repo_root/patches/base"
mkdir -p "$base_dir"

tag_sha="$(git -C "$fork" rev-parse --verify "refs/tags/$tag^{commit}" 2>/dev/null)" \
    || { echo "regen: tag '$tag' not found in $fork" >&2; exit 1; }

state="$base_dir/.regen-state"
{
    echo "# regen-base-patches.sh state -- generated $(date -u +%FT%TZ)"
    echo "# base tag: $tag ($tag_sha)"
} > "$state"

prev_ref="$tag_sha"
prev_name="$tag"
count=0
while read -r id layer up src; do
    [ "$layer" = "base" ] || continue
    [ "$up" = "-" ] || continue          # upstreamed: nothing to generate
    case "$src" in
        fork:*) branch="${src#fork:}" ;;
        *) echo "regen: row '$id' has non-fork source '$src'" >&2; exit 1 ;;
    esac
    sha="$(git -C "$fork" rev-parse --verify "$branch^{commit}" 2>/dev/null)" \
        || { echo "regen: branch '$branch' not found in $fork" >&2; exit 1; }
    if ! git -C "$fork" merge-base --is-ancestor "$prev_ref" "$sha"; then
        echo "regen: '$branch' is not a descendant of '$prev_name'." >&2
        echo "       The fork stack is not in C1->...->C5 order on $tag, or it" >&2
        echo "       has not been rebased onto $tag. Rebase the fork stack" >&2
        echo "       manually first -- tag-bump rebasing is out of scope for" >&2
        echo "       this tool (see the design doc)." >&2
        exit 1
    fi
    out="$base_dir/$id.patch"
    {
        echo "# GENERATED by tools/regen-base-patches.sh -- DO NOT EDIT."
        echo "# Patch:  $id"
        echo "# Source: fork branch $branch @ $sha"
        echo "# Base:   $prev_name @ $prev_ref"
        echo "# Regenerate with: tools/regen-base-patches.sh"
        echo "#"
        git -C "$fork" diff "$prev_ref" "$sha"
    } > "$out"
    echo "$id  $branch  $sha" >> "$state"
    shortstat="$(git -C "$fork" diff --shortstat "$prev_ref" "$sha" | sed 's/^ *//')"
    echo "regen: wrote ${out#$repo_root/}  ($branch -- $shortstat)"
    prev_ref="$sha"
    prev_name="$branch"
    count=$((count + 1))
done <<EOF
$(manifest_rows "$manifest")
EOF

echo "regen: generated $count base patch(es) into ${base_dir#$repo_root/}/"

validate="$repo_root/tools/validate-patchset.sh"
if [ -x "$validate" ]; then
    echo "regen: validating composed set ..."
    "$validate"
else
    echo "regen: next -- run tools/validate-patchset.sh to compile-check the set."
fi
```

- [ ] **Step 2: Verify the tool parses and rejects a missing fork cleanly**

Run:
```bash
cd /root/nvidia-driver-injector
chmod +x tools/regen-base-patches.sh
tools/regen-base-patches.sh --fork /nonexistent; echo "exit=$?"
```
Expected: `regen: fork repo not found at /nonexistent` and `exit=1`.

- [ ] **Step 3: Commit**

```bash
git add tools/regen-base-patches.sh
git commit -m "$(printf 'feat: add regen-base-patches fork-stack extractor\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"
```

---

## Task 6: Generate the base patches

**Files:**
- Create (generated): `patches/base/C1-kbuild-version-mk.patch` … `C5-crash-safety.patch`, `patches/base/.regen-state`

- [ ] **Step 1: Run regen against the fork**

Run:
```bash
cd /root/nvidia-driver-injector
tools/regen-base-patches.sh
```
Expected: six `regen: wrote patches/base/...` lines (`C1-kbuild-version-mk`, `C2-aer-internal-unmask`, `C3-gpu-lost-retry`, `C4-err-handlers-scaffold`, `E1-egpu-detection`, `C5-crash-safety`), then `regen: generated 6 base patch(es)`.

If regen prints the "not a descendant" error: the fork at `/root/open-gpu-kernel-modules` is not on its expected stacked state — check out `c5-crash-safety` and confirm the branch topology before retrying. Do not edit the tool.

- [ ] **Step 2: Verify compose accepts the generated set**

Run:
```bash
cd /root/nvidia-driver-injector
tools/compose-patchset.sh --patches-dir patches
```
Expected: six lines, the absolute paths of the six `patches/base/*.patch` files in manifest order (`C1, C2, C3, C4, E1, C5`), exit 0.

- [ ] **Step 3: Verify regen is idempotent (round-trip)**

Run:
```bash
cd /root/nvidia-driver-injector
sha256sum patches/base/*.patch | sort > /tmp/base-before
tools/regen-base-patches.sh >/dev/null
sha256sum patches/base/*.patch | sort > /tmp/base-after
diff /tmp/base-before /tmp/base-after && echo "IDEMPOTENT"
```
Expected: `IDEMPOTENT` — re-running regen reproduces the six `*.patch` files byte-for-byte. (`.regen-state` carries a timestamp and is intentionally not checksummed.)

- [ ] **Step 4: Commit the generated base patches**

```bash
cd /root/nvidia-driver-injector
git add patches/base/
git commit -m "$(printf 'feat: generate patches/base from the fork base stack\n\nSix base patches exported from apnex/open-gpu-kernel-modules:\nC1-C5 + E1, against the 595.71.05 tag.\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"
```

---

## Task 7: Validate tool (compile gate)

**Files:**
- Create: `tools/validate-patchset.sh`

- [ ] **Step 1: Write the validate tool**

Create `tools/validate-patchset.sh`:

```bash
#!/usr/bin/env bash
# validate-patchset.sh -- compile gate. Checks out a clean NVIDIA
# open-gpu-kernel-modules tree at the target tag, applies the composed
# patch set, and runs `make modules`.
#
# Usage: validate-patchset.sh [--fork DIR] [--tag TAG] [--kernel KVER]
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fork="${FORK_REPO:-/root/open-gpu-kernel-modules}"
tag=""
kver="$(uname -r)"
while [ $# -gt 0 ]; do
    case "$1" in
        --fork)   fork="$2"; shift 2 ;;
        --tag)    tag="$2"; shift 2 ;;
        --kernel) kver="$2"; shift 2 ;;
        *) echo "validate: unknown arg '$1'" >&2; exit 2 ;;
    esac
done
[ -n "$tag" ] || tag="$(awk -F= '/^ARG NVIDIA_OPEN_TAG=/{print $2}' "$repo_root/Dockerfile")"

ksrc="/lib/modules/$kver/build"
[ -d "$ksrc" ]      || { echo "validate: kernel build dir $ksrc not found" >&2; exit 1; }
[ -d "$fork/.git" ] || { echo "validate: fork repo not found at $fork" >&2; exit 1; }

work="$(mktemp -d)"
src="$work/src"
cleanup() {
    git -C "$fork" worktree remove --force "$src" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

echo "validate: checking out vanilla $tag ..."
git -C "$fork" worktree add --detach "$src" "refs/tags/$tag" >/dev/null 2>&1 \
    || { echo "validate: could not check out tag $tag from $fork" >&2; exit 1; }

echo "validate: composing patch set ..."
apply_list="$("$repo_root/tools/compose-patchset.sh" --patches-dir "$repo_root/patches")"

echo "validate: applying patches ..."
while read -r p; do
    [ -n "$p" ] || continue
    echo "  apply ${p##*/}"
    git -C "$src" apply --check "$p"
    git -C "$src" apply "$p"
done <<EOF
$apply_list
EOF

echo "validate: make modules (kernel $kver) ..."
if make -C "$src" modules SYSSRC="$ksrc" -j"$(nproc)" IGNORE_CC_MISMATCH=1 \
        > "$work/build.log" 2>&1; then
    echo "validate: OK -- composed patch set compiles against kernel $kver"
else
    echo "validate: BUILD FAILED -- tail of build log:" >&2
    tail -40 "$work/build.log" >&2
    exit 1
fi
```

- [ ] **Step 2: Run validate against the generated base set**

Run:
```bash
cd /root/nvidia-driver-injector
chmod +x tools/validate-patchset.sh
tools/validate-patchset.sh
```
Expected: `validate: OK -- composed patch set compiles against kernel 7.0.9-204.fc44`. (This is a real `make modules`; allow a few minutes.)

If it fails: the failure is in the base patches, not the tool — capture the build-log tail and stop; do not proceed.

- [ ] **Step 3: Commit**

```bash
git add tools/validate-patchset.sh
git commit -m "$(printf 'feat: add validate-patchset compile gate\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"
```

---

## Task 8: Restructure `patches/`

Move today's production set `0001-0007` into `patches/legacy/` (which already holds the older pre-P1-P7 generation — `legacy/` is the graveyard; multiple generations coexisting is fine). The build no longer references them.

**Files:**
- Move: `patches/0001-*.patch` … `patches/0007-*.patch` → `patches/legacy/`

- [ ] **Step 1: Move the files**

Run:
```bash
cd /root/nvidia-driver-injector
git mv patches/0001-tb-egpu-gpu-lost-crash-safety.patch        patches/legacy/
git mv patches/0002-tb-egpu-aer-uncmask-clear.patch            patches/legacy/
git mv patches/0003-tb-egpu-qwatchdog.patch                    patches/legacy/
git mv patches/0004-tb-egpu-pcie-error-handlers-recover.patch  patches/legacy/
git mv patches/0005-tb-egpu-close-path-safety.patch            patches/legacy/
git mv patches/0006-tb-egpu-diag-telemetry.patch               patches/legacy/
git mv patches/0007-tb-egpu-version-mark-and-kbuild.patch      patches/legacy/
```

- [ ] **Step 2: Verify the new `patches/` shape**

Run: `cd /root/nvidia-driver-injector && ls patches/ && echo '---' && ls patches/base/`
Expected: `patches/` top level contains `base`, `legacy`, `manifest` (no `0001-0007`); `patches/base/` contains the six `*.patch` files plus `.regen-state`.

- [ ] **Step 3: Commit**

```bash
git add -A patches/
git commit -m "$(printf 'refactor: retire flat patches/0001-0007 into patches/legacy\n\nThe build now composes patches/base + manifest. The P1-P7 set is\nkept in legacy/ until the production soak proves the new set.\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"
```

---

## Task 9: Rewire the Dockerfile

Replace the `ls patches/*.patch` apply loop with a `compose-patchset.sh`-driven apply. The composer needs the `tools/` tree in the build context.

**Files:**
- Modify: `Dockerfile` (the patch-vendor + apply block, currently lines 106–117)

- [ ] **Step 1: Replace the patch-apply block**

In `Dockerfile`, replace this exact block:

```dockerfile
# Vendor project patches.
COPY patches/ /src/patches/

# Validate patches apply cleanly at image-build time (early failure beats
# discovering the problem on every pod start).
RUN cd /src/nvidia-open-gpu-kernel-modules && \
    for p in $(ls /src/patches/*.patch | sort); do \
        echo "checking $p"; \
        git apply --check "$p" || { echo "PATCH CHECK FAILED: $p"; exit 1; } ; \
        git apply "$p"; \
    done && \
    echo "all patches applied cleanly to ${NVIDIA_OPEN_TAG} source"
```

with:

```dockerfile
# Vendor project patches + the composition tools.
COPY patches/ /src/patches/
COPY tools/   /src/tools/

# Compose and apply the patch set at image-build time. compose-patchset.sh
# verifies patches/ against patches/manifest and emits the ordered apply
# list; drift fails the image build, not the pod start.
RUN cd /src/nvidia-open-gpu-kernel-modules && \
    /src/tools/compose-patchset.sh --patches-dir /src/patches > /tmp/apply-list && \
    while read -r p; do \
        [ -n "$p" ] || continue; \
        echo "applying ${p##*/}"; \
        git apply --check "$p" && git apply "$p" || exit 1; \
    done < /tmp/apply-list && \
    echo "composed patch set applied cleanly to ${NVIDIA_OPEN_TAG} source"
```

- [ ] **Step 2: Sanity-check the compose invocation locally**

The Dockerfile calls `compose-patchset.sh` exactly as below. Verify it emits the six base paths and exits 0:
```bash
cd /root/nvidia-driver-injector
tools/compose-patchset.sh --patches-dir patches > /tmp/apply-list && wc -l < /tmp/apply-list
```
Expected: `6`.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "$(printf 'feat: apply the composed patch set in the image build\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"
```

---

## Task 10: End-to-end image build

Prove the rewired Dockerfile builds. This is a full image build (clones NVIDIA source, downloads the `.run` bundle — needs network, allow time). It builds the image only; it does **not** run the container or load the module.

**Files:** none (verification only)

- [ ] **Step 1: Build the image**

Run:
```bash
cd /root/nvidia-driver-injector
docker build -t nvidia-driver-injector:compose-test . 2>&1 | tee /tmp/compose-build.log
```
Expected: the build completes; the log contains `applying C1-kbuild-version-mk.patch` … `applying C5-crash-safety.patch` (six lines, manifest order) and `composed patch set applied cleanly to 595.71.05 source`.

- [ ] **Step 2: Confirm no patch-apply failure**

Run: `grep -E 'PATCH CHECK FAILED|error: patch failed' /tmp/compose-build.log; echo "grep-exit=$?"`
Expected: no matching lines, `grep-exit=1`.

- [ ] **Step 3: Run the full test suite once more**

Run: `cd /root/nvidia-driver-injector && bash tests/run.sh; echo "exit=$?"`
Expected: both `test-manifest-lib.sh` and `test-compose.sh` report `0 failed`, `exit=0`.

- [ ] **Step 4: Final commit (cleanup, if any)**

If Steps 1–3 produced no file changes, there is nothing to commit. If `docker build` left stray artifacts, remove them and:
```bash
cd /root/nvidia-driver-injector
docker rmi nvidia-driver-injector:compose-test >/dev/null 2>&1 || true
git status --short
```
Expected: `git status --short` clean.

---

## Done — definition of complete

- `tests/run.sh` passes (manifest-lib + compose tests green).
- `patches/manifest` + `patches/base/` (six generated patches) committed; `regen` is idempotent.
- `tools/validate-patchset.sh` compiles the composed base set against kernel `7.0.9-204.fc44`.
- `patches/0001-0007` retired to `patches/legacy/`.
- `docker build` succeeds via `compose-patchset.sh`.

## Follow-on work (not this plan)

1. **Addon layer + the `A1–A5` re-carve** — populate `patches/addon/`, add the five addon rows to the manifest; re-express `A1`/`A2` against the de-branded `C5` bridge. Own brainstorm + plan; `production-migration.md` §3.
2. **`regen` tag-bump path** — stack rebasing onto a new upstream tag, with empty-commit (upstreamed) detection. Plan it when the first real tag bump lands.
3. **Doc reconciliation** — update `production-migration.md` Step 3 to point at this mechanism; fix `upstream-plan.md`'s "one branch each" phrasing to note the stacked series.
4. **`production-migration.md` steps 5–8** — image rebuild → soak → cutover → upstream PRs.
