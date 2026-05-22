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

# Case 7: empty / comments-only manifest -> exit 0, empty apply list
d="$(mk)"
printf '# only a comment\n' > "$d/manifest"
out="$("$COMPOSE" --patches-dir "$d" 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "empty manifest composes cleanly"
assert_eq "$out" "" "empty manifest yields an empty apply list"
rm -rf "$d"

finish_tests
