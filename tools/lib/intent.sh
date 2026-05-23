# Shared parsing for patch-intent files.
#
# Format: YAML-ish frontmatter delimited by --- markers, then Markdown body.
# Only flat `key: value` pairs supported. The `related-patches` field is a
# small inline YAML list: [], [item], or [item1, item2, ...].
#
# Sourced by tools/intent-lint.sh and tools/render-patch-index.sh.

# RFC 2119 normative keywords (UPPERCASE forms).
INTENT_RFC2119='MUST NOT|MUST|SHALL NOT|SHALL|SHOULD NOT|SHOULD|REQUIRED|RECOMMENDED|MAY|OPTIONAL'

# Print the body of the frontmatter (lines between the first two --- markers).
# Empty output if the file has no frontmatter.
intent_frontmatter() {
    awk '
        /^---$/ { count++; next }
        count == 1 { print }
        count == 2 { exit }
    ' "$1"
}

# Return 0 if the file has a well-formed (opened-and-closed) frontmatter block.
intent_has_frontmatter() {
    awk '
        NR == 1 && /^---$/ { opened = 1; next }
        opened && /^---$/  { closed = 1; exit }
        END { exit !(opened && closed) }
    ' "$1"
}

# Print a single frontmatter field's value (trimmed; empty if missing).
intent_field() {
    local file="$1" key="$2"
    intent_frontmatter "$file" \
      | awk -v k="$key" -F': *' '$1 == k { sub(/^[^:]*: */, ""); print; exit }' \
      | sed 's/[[:space:]]*$//'
}

# Print the `related-patches` list as one id per line; empty if [].
intent_related_patches() {
    local file="$1" v
    v="$(intent_field "$file" related-patches)"
    v="${v#\[}"
    v="${v%\]}"
    [ -z "$v" ] && return 0
    echo "$v" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true
}

# Print `## ` section headings (heading text without the `## ` prefix), in document order.
intent_sections() {
    awk '/^## / { sub(/^## /, ""); print }' "$1"
}

# Print `### Requirement: ` block names, in document order.
intent_requirements() {
    awk '/^### Requirement: / { sub(/^### Requirement: */, ""); print }' "$1"
}

# Print `#### Scenario: ` block names that appear inside a specific `### Requirement: NAME` block.
intent_scenarios_for() {
    local file="$1" req="$2"
    awk -v target="$req" '
        /^### Requirement: / {
            n = $0; sub(/^### Requirement: */, "", n)
            inblock = (n == target); next
        }
        /^## / || /^### / { inblock = 0 }
        inblock && /^#### Scenario: / { sub(/^#### Scenario: */, ""); print }
    ' "$file"
}

# Print the body of a specific Requirement block (lines after its heading up to the next ## / ### heading).
intent_requirement_body() {
    local file="$1" req="$2"
    awk -v target="$req" '
        /^### Requirement: / {
            n = $0; sub(/^### Requirement: */, "", n)
            inblock = (n == target); next
        }
        /^## / || /^### / { inblock = 0 }
        inblock { print }
    ' "$file"
}

# Print the top-level `# <id>` heading text (without the `# ` prefix), empty if none.
intent_top_heading() {
    awk '/^# / { sub(/^# /, ""); print; exit }' "$1"
}
