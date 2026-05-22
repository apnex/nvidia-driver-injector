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
