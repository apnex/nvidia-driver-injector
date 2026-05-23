#!/usr/bin/env bash
# intent-lint.sh — validate patch-intent files against the schema.
#
# Usage: intent-lint.sh [--manifest FILE] [--intents-dir DIR] [file...]
#   Defaults: --manifest patches/manifest (repo-relative)
#             --intents-dir docs/patch-intents
#   With no file arguments, lints every <intents-dir>/*.md except _template.md.
#   With explicit file arguments, lints exactly those.
#
# Exits 0 on success, 1 on validation failure, 2 on bad invocation.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib/intent.sh"

repo_root="$(cd "$here/.." && pwd)"
manifest="$repo_root/patches/manifest"
intents_dir="$repo_root/docs/patch-intents"
explicit_files=()

while [ $# -gt 0 ]; do
    case "$1" in
        --manifest)    manifest="$2"; shift 2 ;;
        --intents-dir) intents_dir="$2"; shift 2 ;;
        -*) echo "intent-lint: unknown flag '$1'" >&2; exit 2 ;;
        *) explicit_files+=("$1"); shift ;;
    esac
done

# Build the file list.
files=()
if [ "${#explicit_files[@]}" -gt 0 ]; then
    files=("${explicit_files[@]}")
else
    [ -d "$intents_dir" ] || { echo "intent-lint: intents dir not found: $intents_dir" >&2; exit 1; }
    for f in "$intents_dir"/*.md; do
        [ -e "$f" ] || continue
        [ "$(basename "$f")" = "_template.md" ] && continue
        files+=("$f")
    done
fi

errors=0
err() { echo "intent-lint: $1: $2" >&2; errors=$((errors + 1)); }

for file in "${files[@]}"; do
    [ -f "$file" ] || { err "$file" "file does not exist"; continue; }

    # Rule 1: frontmatter is well-formed AND has all 7 required fields.
    if ! intent_has_frontmatter "$file"; then
        err "$file" "rule 1: missing or unclosed frontmatter (need opening and closing --- on their own lines, opener at line 1)"
        continue
    fi
    for field in id layer source-branch upstream-candidacy telemetry-tier status related-patches; do
        val="$(intent_field "$file" "$field")"
        if [ -z "$val" ]; then
            err "$file" "rule 1: frontmatter missing required field '$field'"
        fi
    done

    # Rule 2: id field equals filename stem.
    stem="$(basename "$file" .md)"
    id_val="$(intent_field "$file" id)"
    if [ -n "$id_val" ] && [ "$id_val" != "$stem" ]; then
        err "$file" "rule 2: frontmatter id '$id_val' does not match filename stem '$stem'"
    fi

    # Rule 3: layer matches the corresponding manifest row's layer.
    layer_val="$(intent_field "$file" layer)"
    manifest_row="$(grep -E "^[[:space:]]*${stem}[[:space:]]" "$manifest" || true)"
    if [ -z "$manifest_row" ]; then
        err "$file" "rule 3: id '$stem' not found in manifest $manifest"
    else
        manifest_layer="$(echo "$manifest_row" | awk '{print $2}')"
        if [ "$layer_val" != "$manifest_layer" ]; then
            err "$file" "rule 3: layer '$layer_val' disagrees with manifest layer '$manifest_layer' for '$stem'"
        fi
    fi

    # Rule 4: source-branch matches manifest's fork:<branch> for this id (manifest_row from Rule 3).
    if [ -n "$manifest_row" ]; then
        sb_val="$(intent_field "$file" source-branch)"
        manifest_src="$(echo "$manifest_row" | awk '{print $4}')"
        manifest_branch="${manifest_src#fork:}"
        if [ "$sb_val" != "$manifest_branch" ]; then
            err "$file" "rule 4: source-branch '$sb_val' disagrees with manifest 'fork:$manifest_branch' for '$stem'"
        fi
    fi
done

[ "$errors" -eq 0 ] || exit 1
exit 0
