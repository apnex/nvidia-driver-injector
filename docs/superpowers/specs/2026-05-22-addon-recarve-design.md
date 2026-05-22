# Addon layer re-carve (A1–A5) — design

**Status:** approved design — 2026-05-22. Defines the addon-layer carve; the
implementation plan is produced separately (writing-plans).

## Context

The dynamic patch composition mechanism is merged to `main` — manifest-driven
`patches/base/` + `patches/addon/`, with the base layer (`C1`–`C5` + `E1`) live
and compiling. The base layer alone is **not** a production driver: it lacks
the project's bus-loss watchdog, self-triggered recovery, and observability. An
image built off `main` today is a reliability regression versus the running
`595.71.05-aorus.13` container.

This design covers the **addon layer** — producing `patches/addon/` so the
composed `C+E+A` driver is a full replacement for the running P1–P7 container.

The addon content is re-carved from the legacy P-clusters preserved in
`patches/legacy/`. `production-migration.md` §3 anticipated this as deep design
work — "re-express `A1`/`A2` against the de-branded `C5` bridge". Exploration
**falsified that**: the legacy patches `0003`/`0004` were already rewritten
during the P1–P7 refactor and already call `C5`'s de-branded `os_pci_*` API.
The re-carve is therefore a careful *extraction*, not a redesign — with two
genuinely non-mechanical operations (below).

## Scope

**In scope:** carve the addon layer as five patches on top of `C/E`; extend
`regen` / `manifest` / `manifest_lint` to cover addon; audit observability
across every addon patch; verify the composed `C+E+A` driver.

**Out of scope:** image rebuild (`aorus.14`), the ≥14-day soak, cutover —
`production-migration.md` steps 5–7. `regen`'s tag-bump rebase path remains a
deferred follow-on.

## The five addon patches

A **foundation** patch plus four features, carved as a fork branch stack on top
of `C5`. The addon `A`-numbers are project-local stack-order ids with no
external meaning; this design renumbers them.

| New | id | Duty | Boundary / files | Source | Telemetry |
|---|---|---|---|---|---|
| **A1** | `pcie-primitives` | The shared PCIe/AER/WPR2 register-read substrate — `read_wpr2`, `walk_to_root_port`, `read_dpc_state`, `read_aer_full`, `dump_aer_trigger_event` | New `kernel-open/nvidia/nv-tb-egpu-pcie.{c,h}` + one `nvidia-sources.Kbuild` line | extracted from legacy `0004` (P2) | none — a primitive library; its callers log |
| **A2** | `bus-loss-watchdog` | Per-eGPU kthread polling `NV_PMC_BOOT_0`; on the dead-bus signature marks the GPU disconnected via the `C5` bridge | `nv-tb-egpu-qwd.{c,h}`, thin `nv-pci.c` probe/remove wire-in, `nv-linux.h` field, one Kbuild line | legacy `0003` (P3) | log on detection; `tb_egpu_qwd_*` sysfs |
| **A3** | `recovery` | The recovery state machine + H1/H2/H3 policy — post-`rm_init_adapter`-FAIL trigger, bridge `pci_reset_bus`, `slot_reset`/`resume` dispatch, re-init, kill-switch, uevent. Fills `C4`'s `pci_error_handlers` callbacks with real bodies | `nv-tb-egpu-recover.{c,h}` (state machine only), `nv-pci.c` callback bodies, `nv-linux.h` field, `nv.c` hooks, one Kbuild line | legacy `0004` (P2), minus the foundation primitives, minus `C4`'s registration | log every fire / gate / outcome (**mandatory** — recovery is invisible otherwise); `tb_egpu_recover_*` sysfs |
| **A4** | `close-path-telemetry` | Event-triggered nominal telemetry at close-path transitions (RM close callbacks + UVM open/release) | own RM-side file, `nv-tb-egpu-uvm.{c,h}`, `nv.c` / `uvm.c` sites, one Kbuild line | legacy `0005` (P4), held to the nominal bar | IS telemetry — audited to nominal (§ Observability audit) |
| **A5** | `version-and-toggles` | `NVIDIA_VERSION` value (`595.71.05-aorus.14`) + `CONFIG_NV_TB_EGPU` master toggle | `version.mk`, `kernel-open/Kbuild` (on top of `C1`'s include mechanism) | legacy `0007` (P7) addon-half, minus `CONFIG_NV_TB_EGPU_DIAG` | none — build metadata |

### Dissolved — old A4 / cluster P6

The concentrated `[DIAG]` surface (old `A4`, cluster P6, `patches/legacy/0006`)
is **dissolved — not carved**. Its job is covered by per-patch nominal
telemetry (below); a centralised, compiled-out, investigation-grade dump is
redundant once every runtime patch carries its own operational telemetry.
`patches/legacy/0006` stays in `legacy/` as the documented resurrection source
if an investigation reopens. `CONFIG_NV_TB_EGPU_DIAG` — which existed only to
gate it — is removed from `A5`.

### Old → new map

| Old (upstream-plan.md / patches.md) | New |
|---|---|
| — | **A1** `pcie-primitives` — *new*, carved out of cluster P2 |
| A1 watchdog | **A2** `bus-loss-watchdog` |
| A2 recovery | **A3** `recovery` |
| A3 close-path | **A4** `close-path-telemetry` |
| A4 DIAG | *dissolved* |
| A5 version | **A5** `version-and-toggles` (minus the DIAG toggle) |

Cluster carve, restated: P3 → `A2`; **P2 → `C4` + `A1` + `A3`** (a three-way
split — the foundation primitives are extracted into `A1`); P4 → `A4`;
**P6 → dissolved**; P7 → `C1` + `A5`.

## Carve approach

The decision (brainstorming): the addon layer is carved as a fork branch
**stack**, like the base layer — not hand-authored files. The fork's stack tip
`c5-crash-safety` is `vanilla + C1–C5 + E1`. Five commits are carved on top —
branches `a1-pcie-primitives` … `a5-version-and-toggles` — content sourced from
the legacy patches, in a fork worktree. `regen` then exports each checkpoint to
`patches/addon/`.

Two operations are non-mechanical; the rest is near-straight extraction:

1. **Split legacy `0004` into `A1` + `A3`.** P2's `nv-tb-egpu-recover.c` bundles
   the shared register-read primitives and the recovery state machine. Carve
   the primitives into `A1`'s new `nv-tb-egpu-pcie.{c,h}`; the state machine
   stays in `A3`'s `nv-tb-egpu-recover.c`. This is pure code-motion — no
   behaviour change — so it adds no behavioural-equivalence risk.
2. **Re-express `A3`'s `nv-pci.c` hunk as a delta over `C4`.** P2 patched
   *vanilla* `nv-pci.c` to add the `pci_error_handlers` struct **and** the real
   callbacks at once. `C4` (already in base) added that struct plus four *stub*
   callbacks. `A3`'s `nv-pci.c` hunk must therefore *replace `C4`'s four stub
   bodies* and add `cor_error_detected` — not re-add the struct.

With `A1` extracted, every cross-patch dependency collapses to a clean star:
`A2`, `A3`, `A4` each depend only on the foundation `A1`, not on each other's
internals. Stack order: `A1 → A2 → A3 → A4 → A5`.

## Observability audit

Every runtime addon patch carries a stated **Telemetry contract** — the same
standard validated on the `C/E` patches: a log line on the *rare, meaningful
event* and its *outcome*, at kernel-appropriate levels; sysfs counters where
they already exist. The carve audits each patch against this bar and **trims
anything investigation-grade** that the legacy P-clusters carried.

- **A2 `bus-loss-watchdog`** — log a detection event; keep `tb_egpu_qwd_*`
  sysfs. Verify no per-poll (5 Hz) logging.
- **A3 `recovery`** — log every fire, gate decision, and outcome (mandatory —
  same rationale as `C3`: a silent recovery can never be shown to have
  mattered); keep `tb_egpu_recover_*` sysfs.
- **A4 `close-path-telemetry`** — re-scope P4 to *event-triggered* telemetry: a
  line on the meaningful last-close transition. Trim any creeping full-state
  dump that drifts toward investigation-grade.
- **A1 `pcie-primitives` / A5 `version-and-toggles`** — none expected; confirm.

Outcome: a documented per-patch telemetry contract, and the assurance that the
addon layer carries no concentrated `[DIAG]` surface yet enough operational
telemetry for the soak gate to interpret (`tb_egpu_qwd_detections`,
`tb_egpu_recover_*`, host hard-lock correlation).

## `regen` / manifest / `manifest_lint` changes

- **`regen-base-patches.sh`** extended to also walk `addon` rows and export
  `patches/addon/*.patch`. Its extraction path already does exactly this for
  base — addon checkpoints are just more checkpoints in the same fork stack.
- **`patches/manifest`** gains five `addon` rows, in stack order, `source:
  fork:a*`.
- **`manifest_lint`** — the `addon → injector` source rule relaxes to `fork:*`.
  All rows now originate from the fork stack; the `base` / `addon` distinction
  stays meaningful (base is de-branded, upstream-bound, may carry
  `upstreamed_in`; addon is branded, project-local, permanent).
- **`validate-patchset.sh`** needs no change — it composes the whole manifest,
  so it covers addon automatically once the rows exist.

## Verification

1. **Compile.** `validate-patchset.sh`: the full `vanilla + C1–C5 + E1 + A1–A5`
   composed set must `make modules` clean against kernel `7.0.9-204.fc44`.
2. **Behavioural equivalence vs `aorus.13`.** Build the composed `C+E+A` source
   tree and the legacy P1–P7 source tree; diff them. Every difference must fall
   into an **explainable bucket**: base de-branding, `E1`'s detection rewrite,
   the `A1` foundation code-motion, the P6/`[DIAG]` dissolution (absent), and
   any nominal-telemetry trim. An unexplained hunk is a carve bug. (This is not
   byte-equivalence — it is "every difference is accounted for".)
3. **Telemetry sign-off.** Each runtime patch's Telemetry contract verified
   against the Observability audit section.

## Doc reconciliation

The following existing docs become stale once this design lands; reconciling
them is **implementation work — tracked as tasks in the plan**, reconciled
against the final spec:

- `docs/upstream-plan.md` — the "Addon layer — A" section: renumber to the new
  `A1`–`A5`, add the `A1` foundation, mark old `A4`/P6 dissolved, add the
  per-patch nominal-telemetry duty.
- `docs/patches.md` — the per-cluster "Upstream geometry" blocks (P2/P3/P4/P6/P7)
  and the final C/E/A table: P3 → `A2`; P2 → `C4` + `A1` + `A3`; P4 → `A4`;
  P6 → dissolved; P7 → `C1` + `A5`.
- `docs/production-migration.md` — §3 now points at this design; foundation
  extraction and P6 dissolution noted.
- `docs/superpowers/specs/2026-05-22-dynamic-patch-composition-design.md` — the
  "addon = hand-authored, `source: injector`" statement and the `manifest_lint`
  note revised to "addon = fork-carved, `source: fork:a*`".

## Out of scope / deferred

- Image rebuild → `595.71.05-aorus.14`, the ≥14-day soak, cutover —
  `production-migration.md` steps 5–7.
- `regen`'s tag-bump rebase path — still a separate deferred follow-on.
- Upstream PRs — the addon layer is never upstreamed, by definition.

## Relationship to prior docs

This design **supersedes** the `A1`–`A5` definitions in `upstream-plan.md`
(which had DIAG as `A4` and no foundation) and **revises** the
dynamic-patch-composition design's addon-delivery decision (`addon` is
fork-carved, not hand-authored). The implementation plan sequences the carve,
the tooling changes, the verification, and the doc reconciliation above.
