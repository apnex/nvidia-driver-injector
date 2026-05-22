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
