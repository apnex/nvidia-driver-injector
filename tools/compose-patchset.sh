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
    [ -z "$id" ] && continue
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
