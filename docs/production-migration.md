# Production migration — Step 3

**Status:** not started — drafted 2026-05-22. The plan for moving the
injector's production driver onto the C/E/A geometry. Phase-3 steps 1–2 (carve
the base set; adopt C/E/A in the docs) are done; this doc is **Step 3**.

## Goal

Today the production driver is the flat seven-cluster set `patches/0001-0007`
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
- **Injector `patches/0001-0007`** — today's `P1`–`P7` clusters: the pre-carve
  set, and the source for the additive layer.
- **[`upstream-plan.md`](upstream-plan.md)** — the C/E/A geometry, the
  cluster → C/E/A map (Execution section), and the Gate (soak criteria).

## Sequence

1. **Extract the base patches.** `git format-patch` each fork base branch
   against its parent → `C1.patch` … `C5.patch`, `E1.patch`. These are
   de-branded and upstream-shaped.

2. **Re-carve the additive layer `A1`–`A5`** from `P1`–`P7`. `A` = each
   P-cluster *minus* the slice already extracted into C/E (see the
   cluster → C/E/A map in `upstream-plan.md`):
   - `A1` ← `P3` (Q-watchdog) — wholly additive.
   - `A2` ← `P2` minus the `pci_error_handlers` registration (→ `C4`): the
     recovery state machine + the H1/H2/H3 gate policy.
   - `A3` ← `P4` (close-path observability) — wholly additive.
   - `A4` ← `P6` (DIAG telemetry) — wholly additive.
   - `A5` ← `P7` minus the Kbuild/version.mk mechanism (→ `C1`): the
     `NVIDIA_VERSION` value + the `CONFIG_NV_TB_EGPU*` toggles.
   - `P1` → wholly `C3`+`C5`; `P5` → wholly `C2` — no `A` residue from those.

3. **Reconcile base ↔ additive composition.** The base C/E patches are
   *de-branded*; the A patches stay *branded* (`tb_egpu_*`). Applying C/E
   **then** A onto vanilla `595.71.05` must produce a clean tree and a clean
   `make modules`. Dependencies the A re-carve MUST honour:
   - `A1`/`A2` mark the GPU disconnected via `os_pci_set_disconnected` — that
     bridge now lives in `C5`, not in A. A1/A2 must **call the C5 bridge**, not
     carry their own copy.
   - `C5` introduces `inc/kernel/gpu/nv-gpu-lost.h` (dead-bus constants,
     log-once macro); A code touching the same paths uses the C5 header, not a
     branded duplicate.
   - This is real carve/design work, not a mechanical split — budget it as the
     main effort of Step 3.

4. **Restructure `patches/`.** Replace `0001-0007` with the new set —
   `C1`…`C5`, `E1`, `A1`…`A5` — applied base-then-additive. Keep
   `patches/legacy/` until the soak proves the new set.

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

- **Base delivery mechanism.** Apply the C/E patches as `format-patch` files in
  `patches/`, or track the fork as a pinned submodule / ref? `format-patch`
  files keep the injector self-contained; a submodule keeps the base
  authoritative on the fork. Decide before step 4.
- **The A re-carve (step 3)** is the hard part — `A1`/`A2` must be re-expressed
  against the de-branded `C5` bridge + `nv-gpu-lost.h` rather than their
  branded `P2`/`P3` originals.
- **Apply-order interaction.** `C5`'s guards and `A1`/`A2`'s watchdog/recovery
  touch overlapping paths (`osDevReadReg*`, the disconnect state); verify the
  composed result reproduces today's `aorus.13` runtime behaviour before
  cutover.

## Resumption note

Steps 1–2 are complete and durable: the base set is six branches on the fork
(above); the C/E/A geometry, the cluster map and the Gate are in
`upstream-plan.md`; `patches.md` maps each P-cluster to its C/E/A destination.
Step 3 begins at sequence step 1 above. Nothing in Step 3 has started.
