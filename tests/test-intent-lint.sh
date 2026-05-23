#!/usr/bin/env bash
# Tests for tools/intent-lint.sh.
#
# Each test case creates a temporary directory with:
#   <tmp>/patches/manifest                  — fixture manifest
#   <tmp>/docs/patch-intents/<id>.md        — fixture intent(s)
# Then invokes intent-lint with --manifest and --intents-dir pointed at it.

set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"

INTENT_LINT="$here/../tools/intent-lint.sh"

# Temp fixture dirs created by mk() — wiped on test exit.
_intent_test_dirs=()
trap '
    for _d in "${_intent_test_dirs[@]}"; do
        [ -n "$_d" ] && rm -rf "$_d"
    done
' EXIT

# mk: create a temp fixture root with a default manifest containing X1-good (base) and X2-good (addon).
# Callers MUST register the returned dir for cleanup:  d="$(mk)"; _intent_test_dirs+=("$d")
# (Registration cannot happen inside mk() because mk is invoked under $(...), a subshell
# whose array mutations do not propagate to the parent.)
mk() {
    local d; d="$(mktemp -d)"
    mkdir -p "$d/patches" "$d/docs/patch-intents"
    cat > "$d/patches/manifest" <<'M'
# id        layer  upstreamed_in  source
  X1-good   base   -              fork:x1-good
  X2-good   addon  -              fork:x2-good
M
    echo "$d"
}

# write_valid_intent: write a fully lint-conformant intent for X1-good into the fixture dir.
write_valid_intent() {
    local dir="$1"
    cat > "$dir/docs/patch-intents/X1-good.md" <<'INTENT'
---
id: X1-good
layer: base
source-branch: x1-good
upstream-candidacy: high
telemetry-tier: nominal
status: draft
related-patches: []
---

# X1-good — Example Valid Patch

## Purpose

A test fixture demonstrating a fully lint-conformant intent file.

## Requirements

### Requirement: Example normative requirement

The driver SHALL emit a log line whenever the example event fires.

#### Scenario: The event fires
- **GIVEN** the relevant precondition holds
- **WHEN** the event occurs
- **THEN** the driver MUST emit the log line

## Scope boundary

- This is a test fixture; it does not correspond to any real patch.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| example | `dev_warn` | `"example event fired"` |

## Provenance

- **Source cluster:** P0 (fixture; not real).
- **Vanilla baseline:** `kernel-open/example.c:example_fn`.
- **Fork branch:** `x1-good`.
- **Upstream issue:** n/a.
INTENT
}

# Lint helper: invokes intent-lint against a fixture dir.
lint_fixture() {
    local dir="$1"
    "$INTENT_LINT" --manifest "$dir/patches/manifest" --intents-dir "$dir/docs/patch-intents"
}

# Case 0: valid-case fixture passes lint.
d="$(mk)"; _intent_test_dirs+=("$d")
write_valid_intent "$d"
assert_exit 0 "valid intent passes lint" lint_fixture "$d"

# Case: missing a required frontmatter field (no `status` line).
d="$(mk)"; _intent_test_dirs+=("$d")
cat > "$d/docs/patch-intents/X1-good.md" <<'INTENT'
---
id: X1-good
layer: base
source-branch: x1-good
upstream-candidacy: high
telemetry-tier: nominal
related-patches: []
---

# X1-good — Missing Status Field

## Purpose

Fixture missing the `status` frontmatter field.

## Requirements

### Requirement: Stub
The driver MUST exist.
#### Scenario: Stub
- **GIVEN** a stub
- **WHEN** stubbed
- **THEN** MUST stub

## Scope boundary
- Stub.

## Telemetry contract
| Event | Level | Format |
|---|---|---|
| e | `dev_warn` | `"e"` |

## Provenance
- **Source cluster:** stub.
- **Vanilla baseline:** stub.
- **Fork branch:** stub.
- **Upstream issue:** n/a.
INTENT
assert_exit 1 "missing frontmatter field fails lint" lint_fixture "$d"

# Case: quoted-empty frontmatter field (`status: ""`) — Rule 1 must reject it.
d="$(mk)"; _intent_test_dirs+=("$d")
cat > "$d/docs/patch-intents/X1-good.md" <<'INTENT'
---
id: X1-good
layer: base
source-branch: x1-good
upstream-candidacy: high
telemetry-tier: nominal
status: ""
related-patches: []
---

# X1-good — Quoted-Empty Status Field

## Purpose

Fixture with a syntactically-present but semantically-empty `status` field.

## Requirements

### Requirement: Stub
The driver MUST exist.
#### Scenario: Stub
- **GIVEN** a stub
- **WHEN** stubbed
- **THEN** MUST stub

## Scope boundary
- Stub.

## Telemetry contract
| Event | Level | Format |
|---|---|---|
| e | `dev_warn` | `"e"` |

## Provenance
- **Source cluster:** stub.
- **Vanilla baseline:** stub.
- **Fork branch:** stub.
- **Upstream issue:** n/a.
INTENT
assert_exit 1 "quoted-empty field fails lint" lint_fixture "$d"

# Case: frontmatter id does not match filename stem.
d="$(mk)"
_intent_test_dirs+=("$d")
cat > "$d/docs/patch-intents/X1-good.md" <<'INTENT'
---
id: WRONG-NAME
layer: base
source-branch: x1-good
upstream-candidacy: high
telemetry-tier: nominal
status: draft
related-patches: []
---

# WRONG-NAME — Mismatched Id

## Purpose
Stub.
## Requirements
### Requirement: Stub
The driver MUST exist.
#### Scenario: Stub
- **GIVEN** a stub
- **WHEN** stubbed
- **THEN** MUST stub
## Scope boundary
- Stub.
## Telemetry contract
| Event | Level | Format |
|---|---|---|
| e | `dev_warn` | `"e"` |
## Provenance
- **Source cluster:** stub.
- **Vanilla baseline:** stub.
- **Fork branch:** stub.
- **Upstream issue:** n/a.
INTENT
assert_exit 1 "id != filename stem fails lint" lint_fixture "$d"

# Case: layer field disagrees with manifest row.
d="$(mk)"
_intent_test_dirs+=("$d")
cat > "$d/docs/patch-intents/X1-good.md" <<'INTENT'
---
id: X1-good
layer: addon
source-branch: x1-good
upstream-candidacy: n/a
telemetry-tier: nominal
status: draft
related-patches: []
---

# X1-good — Layer Mismatch

## Purpose
Stub.
## Requirements
### Requirement: Stub
The driver MUST exist.
#### Scenario: Stub
- **GIVEN** stub
- **WHEN** stub
- **THEN** MUST stub
## Scope boundary
- Stub.
## Telemetry contract
| Event | Level | Format |
|---|---|---|
| e | `dev_warn` | `"e"` |
## Provenance
- **Source cluster:** stub.
- **Vanilla baseline:** stub.
- **Fork branch:** stub.
- **Upstream issue:** n/a.
INTENT
assert_exit 1 "layer != manifest fails lint" lint_fixture "$d"

# Case: source-branch disagrees with manifest fork:<branch>.
d="$(mk)"
_intent_test_dirs+=("$d")
cat > "$d/docs/patch-intents/X1-good.md" <<'INTENT'
---
id: X1-good
layer: base
source-branch: wrong-branch-name
upstream-candidacy: high
telemetry-tier: nominal
status: draft
related-patches: []
---

# X1-good — Wrong Source Branch

## Purpose
Stub.
## Requirements
### Requirement: Stub
The driver MUST exist.
#### Scenario: Stub
- **GIVEN** stub
- **WHEN** stub
- **THEN** MUST stub
## Scope boundary
- Stub.
## Telemetry contract
| Event | Level | Format |
|---|---|---|
| e | `dev_warn` | `"e"` |
## Provenance
- **Source cluster:** stub.
- **Vanilla baseline:** stub.
- **Fork branch:** stub.
- **Upstream issue:** n/a.
INTENT
assert_exit 1 "source-branch != manifest fails lint" lint_fixture "$d"

# Case: base row with upstream-candidacy: n/a (disallowed; n/a only valid for addon).
d="$(mk)"
_intent_test_dirs+=("$d")
cat > "$d/docs/patch-intents/X1-good.md" <<'INTENT'
---
id: X1-good
layer: base
source-branch: x1-good
upstream-candidacy: n/a
telemetry-tier: nominal
status: draft
related-patches: []
---

# X1-good — Base With NA

## Purpose
Stub.
## Requirements
### Requirement: Stub
The driver MUST exist.
#### Scenario: Stub
- **GIVEN** stub
- **WHEN** stub
- **THEN** MUST stub
## Scope boundary
- Stub.
## Telemetry contract
| Event | Level | Format |
|---|---|---|
| e | `dev_warn` | `"e"` |
## Provenance
- **Source cluster:** stub.
- **Vanilla baseline:** stub.
- **Fork branch:** stub.
- **Upstream issue:** n/a.
INTENT
assert_exit 1 "base + n/a candidacy fails lint" lint_fixture "$d"

# Case: related-patches references an id with no intent file.
d="$(mk)"
_intent_test_dirs+=("$d")
cat > "$d/docs/patch-intents/X1-good.md" <<'INTENT'
---
id: X1-good
layer: base
source-branch: x1-good
upstream-candidacy: high
telemetry-tier: nominal
status: draft
related-patches: [NONEXISTENT-PATCH]
---

# X1-good — Dangling Related

## Purpose
Stub.
## Requirements
### Requirement: Stub
The driver MUST exist.
#### Scenario: Stub
- **GIVEN** stub
- **WHEN** stub
- **THEN** MUST stub
## Scope boundary
- Stub.
## Telemetry contract
| Event | Level | Format |
|---|---|---|
| e | `dev_warn` | `"e"` |
## Provenance
- **Source cluster:** stub.
- **Vanilla baseline:** stub.
- **Fork branch:** stub.
- **Upstream issue:** n/a.
INTENT
assert_exit 1 "dangling related-patches fails lint" lint_fixture "$d"

# Case: section order violated — Telemetry contract appears before Scope boundary.
d="$(mk)"
_intent_test_dirs+=("$d")
cat > "$d/docs/patch-intents/X1-good.md" <<'INTENT'
---
id: X1-good
layer: base
source-branch: x1-good
upstream-candidacy: high
telemetry-tier: nominal
status: draft
related-patches: []
---

# X1-good — Out of Order

## Purpose
Stub.
## Requirements
### Requirement: Stub
The driver MUST exist.
#### Scenario: Stub
- **GIVEN** stub
- **WHEN** stub
- **THEN** MUST stub
## Telemetry contract
| Event | Level | Format |
|---|---|---|
| e | `dev_warn` | `"e"` |
## Scope boundary
- Stub.
## Provenance
- **Source cluster:** stub.
- **Vanilla baseline:** stub.
- **Fork branch:** stub.
- **Upstream issue:** n/a.
INTENT
assert_exit 1 "section order violation fails lint" lint_fixture "$d"

# Case: ## Requirements section present but has no ### Requirement: blocks.
d="$(mk)"
_intent_test_dirs+=("$d")
cat > "$d/docs/patch-intents/X1-good.md" <<'INTENT'
---
id: X1-good
layer: base
source-branch: x1-good
upstream-candidacy: high
telemetry-tier: nominal
status: draft
related-patches: []
---

# X1-good — No Requirements

## Purpose
Stub.

## Requirements

(intentionally empty)

## Scope boundary
- Stub.
## Telemetry contract
| Event | Level | Format |
|---|---|---|
| e | `dev_warn` | `"e"` |
## Provenance
- **Source cluster:** stub.
- **Vanilla baseline:** stub.
- **Fork branch:** stub.
- **Upstream issue:** n/a.
INTENT
assert_exit 1 "no Requirement blocks fails lint" lint_fixture "$d"

# Case: a Requirement block contains no UPPERCASE RFC 2119 keyword.
d="$(mk)"
_intent_test_dirs+=("$d")
cat > "$d/docs/patch-intents/X1-good.md" <<'INTENT'
---
id: X1-good
layer: base
source-branch: x1-good
upstream-candidacy: high
telemetry-tier: nominal
status: draft
related-patches: []
---

# X1-good — No RFC 2119

## Purpose
Stub.

## Requirements

### Requirement: Descriptive but not normative

The driver should probably handle the case (lowercase, not normative).

#### Scenario: Stub
- **GIVEN** stub
- **WHEN** stub
- **THEN** stub happens

## Scope boundary
- Stub.
## Telemetry contract
| Event | Level | Format |
|---|---|---|
| e | `dev_warn` | `"e"` |
## Provenance
- **Source cluster:** stub.
- **Vanilla baseline:** stub.
- **Fork branch:** stub.
- **Upstream issue:** n/a.
INTENT
assert_exit 1 "Requirement without RFC 2119 fails lint" lint_fixture "$d"

finish_tests
