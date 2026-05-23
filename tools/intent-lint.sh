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

    # Rule 5: upstream-candidacy: n/a iff layer: addon.
    cand_val="$(intent_field "$file" upstream-candidacy)"
    if [ "$layer_val" = "addon" ] && [ "$cand_val" != "n/a" ]; then
        err "$file" "rule 5: addon layer requires upstream-candidacy 'n/a' (got '$cand_val')"
    fi
    if [ "$layer_val" = "base" ] && [ "$cand_val" = "n/a" ]; then
        err "$file" "rule 5: base layer must have upstream-candidacy in {high,medium,low} (got 'n/a')"
    fi

    # Rule 6: every related-patches id resolves to another intent file.
    while read -r rel_id; do
        [ -z "$rel_id" ] && continue
        if [ ! -f "$intents_dir/$rel_id.md" ]; then
            err "$file" "rule 6: related-patches entry '$rel_id' has no file at $intents_dir/$rel_id.md"
        fi
    done < <(intent_related_patches "$file")

    # Rule 7: required ## sections appear in the exact order:
    #   Purpose, Requirements, Scope boundary, Telemetry contract, Provenance.
    expected_sections="Purpose Requirements Scope boundary Telemetry contract Provenance"
    actual_sections="$(intent_sections "$file" | tr '\n' '|')"
    expected_pattern='Purpose|Requirements|Scope boundary|Telemetry contract|Provenance|'
    if [ "$actual_sections" != "$expected_pattern" ]; then
        err "$file" "rule 7: ## sections must be exactly (in order): $expected_sections; got: $(echo "$actual_sections" | tr '|' ',')"
    fi

    # Rule 8: at least one ### Requirement: block exists.
    req_count="$(intent_requirements "$file" | grep -c . || true)"
    if [ "${req_count:-0}" -eq 0 ]; then
        err "$file" "rule 8: ## Requirements has no ### Requirement: block"
    fi

    # Rule 9: each Requirement block contains >= 1 UPPERCASE RFC 2119 keyword.
    while read -r req_name; do
        [ -z "$req_name" ] && continue
        body="$(intent_requirement_body "$file" "$req_name")"
        if ! echo "$body" | grep -qE "\\b($INTENT_RFC2119)\\b"; then
            err "$file" "rule 9: Requirement '$req_name' has no UPPERCASE RFC 2119 keyword"
        fi
    done < <(intent_requirements "$file")

    # Rule 10: each Requirement has >= 1 #### Scenario: block.
    while read -r req_name; do
        [ -z "$req_name" ] && continue
        scenarios_n="$(intent_scenarios_for "$file" "$req_name" | grep -c . || true)"
        if [ "${scenarios_n:-0}" -eq 0 ]; then
            err "$file" "rule 10: Requirement '$req_name' has no #### Scenario: block"
        fi
    done < <(intent_requirements "$file")

    # Rule 11: top-level "# <id> — <title>" heading's id prefix matches frontmatter id.
    top="$(intent_top_heading "$file")"
    top_id="${top%% —*}"
    top_id="${top_id%% *}"
    if [ -n "$id_val" ] && [ -n "$top" ] && [ "$top_id" != "$id_val" ]; then
        err "$file" "rule 11: top heading id '$top_id' does not match frontmatter id '$id_val'"
    fi
done

[ "$errors" -eq 0 ] || exit 1
exit 0
