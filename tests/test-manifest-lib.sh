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
