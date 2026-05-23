---
id: PATCH-ID-HERE
layer: base
source-branch: BRANCH-NAME-HERE
upstream-candidacy: high
telemetry-tier: nominal
status: draft
related-patches: []
---

# PATCH-ID-HERE — Human Title Here

## Purpose

One paragraph stating the persistent capability this patch grants the driver.
Cite the bug class, any upstream issue, and the user-visible behaviour.

## Requirements

### Requirement: Descriptive name of the requirement

A normative paragraph using RFC 2119 keywords UPPERCASE. The driver SHALL
exhibit the described behaviour under the stated conditions.

#### Scenario: Descriptive name of the scenario
- **GIVEN** the initial condition
- **WHEN** the triggering event occurs
- **THEN** the required outcome MUST hold
- **AND** any additional consequence MUST also hold

## Scope boundary

- This patch deliberately does NOT cover <non-goal 1>.
- Out-of-scope: <non-goal 2>.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| event-name | `dev_warn` | `"format string with %d"` |

## Provenance

- **Source cluster:** P<n> (`patches/legacy/000<n>-*.patch`).
- **Vanilla baseline:** `kernel-open/<dir>/<file>:<symbol>`.
- **Fork branch:** `BRANCH-NAME-HERE` on `apnex/open-gpu-kernel-modules`.
- **Upstream issue:** URL or "n/a".
