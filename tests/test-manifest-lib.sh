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

# manifest_lint accepts an empty / comments-only manifest (zero rows is valid)
printf '# only a comment\n\n' > "$d/empty"
manifest_lint "$d/empty" 2>/dev/null
assert_eq "$?" "0" "manifest_lint accepts a comments-only manifest"

# manifest_lint rejects a row with too many fields
printf '  C1-a  base  -  fork:c1  EXTRA\n' > "$d/long"
manifest_lint "$d/long" 2>/dev/null
assert_eq "$?" "1" "manifest_lint rejects a row with too many fields"

# manifest_lint rejects a base row whose source is not fork:<branch>
printf '  C1-a  base  -  injector\n' > "$d/base-bad-src"
manifest_lint "$d/base-bad-src" 2>/dev/null
assert_eq "$?" "1" "manifest_lint rejects a base row with a non-fork source"

# manifest_lint rejects an addon row whose source is not 'injector'
printf '  A1-a  addon  -  fork:a1\n' > "$d/addon-bad-src"
manifest_lint "$d/addon-bad-src" 2>/dev/null
assert_eq "$?" "1" "manifest_lint rejects an addon row with a fork source"

# manifest_lint accepts a well-formed addon row
printf '  A1-a  addon  -  injector\n' > "$d/addon-ok"
manifest_lint "$d/addon-ok" 2>/dev/null
assert_eq "$?" "0" "manifest_lint accepts a well-formed addon row"

finish_tests
