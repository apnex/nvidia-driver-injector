# Production migration — Step 3

**Status:** in progress — drafted 2026-05-22. The plan for moving the
injector's production driver onto the C/E/A geometry. Phase-3 steps 1–2 (carve
the base set; adopt C/E/A in the docs) are done; this doc is **Step 3**. The
dynamic-patch-composition mechanism and the addon re-carve are implemented
(see the design specs under `docs/superpowers/specs/`); sequence step 4 onward
(image rebuild, soak, cutover) remains.

## Goal

Today the production driver is the flat seven-cluster set `patches/legacy/0001-0007`
(`P1`–`P7`), version `595.71.05-aorus.13`. Step 3 restructures it into the
C/E/A geometry defined in [`upstream-plan.md`](upstream-plan.md):

> production driver = **base** (`C1`–`C5` + `E1`, de-branded) + **additive**
> (`A1`–`A5`, branded, project-local)

End state: the fork reads "stock NVIDIA driver + a known, sorted delta"; the
base layer shrinks as its PRs land upstream; the additive layer is the
project's permanent floor.

## Durable inputs

- **Fork `apnex/open-gpu-kernel-modules`** — the carved, compiled, de-branded
  base layer, one branch each (all `make modules`-validated vs kernel
  `7.0.9-204.fc44`):
  `c1-kbuild-version-mk`, `c2-aer-internal-unmask`, `c3-gpu-lost-retry`,
  `c4-err-handlers-scaffold`, `c5-crash-safety` (2 commits: bridge + guards),
  `e1-egpu-detection`.
- **Injector `patches/legacy/0001-0007`** — today's `P1`–`P7` clusters: the pre-carve
  set, and the source for the additive layer.
- **[`upstream-plan.md`](upstream-plan.md)** — the C/E/A geometry, the
  cluster → C/E/A map (Execution section), and the Gate (soak criteria).

## Sequence

1. **Extract the base patches.** `git format-patch` each fork base branch
   against its parent → `C1.patch` … `C5.patch`, `E1.patch`. These are
   de-branded and upstream-shaped.

2. **Re-carve the additive layer `A1`–`A5`** from `P1`–`P7`. Authoritative
   design:
   [`docs/superpowers/specs/2026-05-22-addon-recarve-design.md`](superpowers/specs/2026-05-22-addon-recarve-design.md).
   The addon is carved as a fork branch stack on top of `C5` (foundation
   `A1` extracted out of cluster P2; cluster P6 dissolved):
   - `A1` ← P2's shared register-read primitives (`read_wpr2`,
     `walk_to_root_port`, `read_dpc_state`, `read_aer_full`,
     `dump_aer_trigger_event`) — **new** foundation module
     (`nv-tb-egpu-pcie.{c,h}`), consumed by `A2`/`A3`/`A4`.
   - `A2` ← P3 (Q-watchdog, renamed `bus-loss-watchdog`).
   - `A3` ← P2 minus the `pci_error_handlers` registration (→ `C4`) and minus
     the foundation primitives (→ `A1`): the recovery state machine + the
     H1/H2/H3 gate policy; fills `C4`'s stub callbacks with real bodies.
   - `A4` ← P4 (close-path), re-scoped to nominal event-triggered telemetry
     (renamed `close-path-telemetry`).
   - `A5` ← P7 minus the Kbuild/version.mk mechanism (→ `C1`) and minus the
     `CONFIG_NV_TB_EGPU_DIAG` toggle: the `NVIDIA_VERSION` value + the
     `CONFIG_NV_TB_EGPU` master toggle.
   - `P1` → wholly `C3`+`C5`; `P5` → wholly `C2`; `P6` → **dissolved** (the
     concentrated `[DIAG]` surface is replaced by per-patch nominal telemetry
     across `C`/`E`/`A`; `patches/legacy/0006` preserved as resurrection
     source) — no `A` residue from any of those.

3. **Reconcile base ↔ additive composition.** The base C/E patches are
   *de-branded*; the A patches stay *branded* (`tb_egpu_*`). Applying C/E
   **then** A onto vanilla `595.71.05` must produce a clean tree and a clean
   `make modules`. Dependencies the A re-carve MUST honour:
   - `A2`/`A3` mark the GPU disconnected via `os_pci_set_disconnected` — that
     bridge now lives in `C5`, not in A. A2/A3 must **call the C5 bridge**, not
     carry their own copy.
   - `C5` introduces `inc/kernel/gpu/nv-gpu-lost.h` (dead-bus constants,
     log-once macro); A code touching the same paths uses the C5 header, not a
     branded duplicate.
   - `A3`'s `nv-pci.c` hunk must *replace* `C4`'s four stub callback bodies and
     add `cor_error_detected` — not re-add the `pci_error_handlers` struct
     (which `C4` already registers).
   - `A2`/`A3`/`A4` each consume `A1`'s foundation primitives — they must not
     each carry their own copy of `read_wpr2` / `walk_to_root_port` /
     `read_aer_full` / `dump_aer_trigger_event` / `read_dpc_state`.
   - This is real carve/design work, not a mechanical split — see the addon
     re-carve design for the operational detail.

4. **Restructure `patches/`.** Replace `0001-0007` with the manifest-driven
   `patches/base/` + `patches/addon/` layout — `C1`…`C5` + `E1` in `base/`,
   `A1`…`A5` in `addon/`, applied base-then-addon in manifest row order. Keep
   `patches/legacy/` until the soak proves the new set. (Implemented per
   `docs/superpowers/specs/2026-05-22-dynamic-patch-composition-design.md` +
   `docs/superpowers/specs/2026-05-22-addon-recarve-design.md`.)

5. **Rebuild the container image.** New patch set; bump `NVIDIA_VERSION`
   (→ `595.71.05-aorus.14`); container build + GSP-firmware step unchanged.

6. **Soak — the Gate.** Per `upstream-plan.md` Gate, soaked tier: vLLM as the
   daily compute path, **≥ 14 days**, all criteria green — `status.sh` 38/2/0
   or better, `tb_egpu_recover_surrenders` = 0, every `tb_egpu_qwd_detections`
   increment 0-or-explained, no unexplained host hard-lock.

7. **Cut over.** New image → production once the soak is green.

8. *(Separate, still gated.)* The upstream PRs — only after the soak, only on
   explicit go-ahead, per the standing no-premature-upstream policy.

## Open design questions — decide during Step 3

- **Base delivery mechanism.** *Resolved* (2026-05-22) by the dynamic-patch
  composition design — manifest-driven `patches/base/` + `patches/addon/`,
  both regen-generated from the fork stack. See
  `docs/superpowers/specs/2026-05-22-dynamic-patch-composition-design.md`.
- **The A re-carve (step 3).** *Resolved* (2026-05-22) by the addon-recarve
  design — see
  `docs/superpowers/specs/2026-05-22-addon-recarve-design.md`. A foundation
  patch (`A1`) was extracted out of cluster P2 so `A2`/`A3`/`A4` share one
  copy of the PCIe primitives; cluster P6 dissolved (the `[DIAG]` surface is
  replaced by per-patch nominal telemetry). The addon re-carve plan is fully
  implemented.
- **Apply-order interaction.** `C5`'s guards and `A2`/`A3`'s watchdog/recovery
  touch overlapping paths (`osDevReadReg*`, the disconnect state); the
  behavioural-equivalence verification step in the addon-recarve design
  (task 12, complete) covers this — every diff vs the `aorus.13` source tree
  falls into an explainable bucket.

## Resumption note

Steps 1–2 are complete and durable: the base set is six branches on the fork
(above); the C/E/A geometry, the cluster map and the Gate are in
`upstream-plan.md`; `patches.md` maps each P-cluster to its C/E/A destination.
The dynamic patch composition mechanism is merged to `main` and the addon
re-carve (Sequence steps 1–3 above) is implemented per
`docs/superpowers/specs/2026-05-22-addon-recarve-design.md` — `patches/base/`
and `patches/addon/` are populated, the composed `C+E+A` driver compiles, and
behavioural equivalence vs `aorus.13` is verified. Sequence step 4 onward
(`patches/` restructure formalised, image rebuild, soak, cutover) is the
remaining work.
