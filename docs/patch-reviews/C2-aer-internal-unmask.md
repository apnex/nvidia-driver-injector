---
id: C2-aer-internal-unmask
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: 2cc240ef06fd740262a0c2532b043dd852258a83
v2-tip-sha: 2cc240ef06fd740262a0c2532b043dd852258a83
status: accepted
related-patches: []
---

# C2-aer-internal-unmask — v2 review

## Rationale

The AER Uncorrectable Internal Error bit (`PCI_ERR_UNC_INTN`, bit 22 of
`PCI_ERR_UNCOR_MASK`) is set at probe on some platforms — observed on
this project's NUC 15 Pro+ + AORUS RTX 5090 hardware on every Gen3
probe-end through May 2026. Per PCIe r6.0 §6.2.3.2 a masked
uncorrectable error is demoted to Advisory Non-Fatal: status is NOT
latched, the Header Log is NOT captured, and the device driver's
`pci_error_handlers` are NEVER invoked. The error is invisible to the
kernel's AER recovery path. Without unmasking, every transient PCIe
Internal Error fires as `Cor=0x2000` (Advisory Non-Fatal) and the
recovery state machine sleeps. C2 clears the Internal Error bits at
probe so subsequent Internal Errors fire as proper Uncorrectable
Non-Fatal events, the Header Log captures the offending TLP, and any
registered `pci_error_handlers` (introduced in [[C5-crash-safety]] and
the addon recovery patches) gets dispatched.

The historical journey to this patch is worth recording in this review
file (it does NOT belong in the intent's Purpose — M3 from C1
checkpoint). The empirical lever was originally G3-H, discovered
2026-05-07 by comparing AER register state against the Windows
`nvlddmkm` driver on the same hardware (Windows
`DEVPKEY_PciDevice_Uncorrectable_Error_Mask = 0`; Linux observed
`0x00400000`). The legacy patch
`patches/legacy/0022-G3-H-clear-AER-UncMask-match-Windows.patch`
inlined the clear inside `tb_egpu_lever_m_recover_init()` with a
comment that the coupling to Lever M-recover was "wrong but expedient".
The P1-P6 refactor on 2026-05-12 carved this out into a separate TU
(`kernel-open/nvidia/nv-tb-egpu-aer.{c,h}`,
`patches/legacy/0002-tb-egpu-aer-uncmask-clear.patch`) gated by
`NVreg_TbEgpuAerUncMaskClear`. Then the May 2026 source review surfaced
that Linux kernel 7.0+ ships `pci_aer_unmask_internal_errors()` doing
the exact same operation — but exported with
`EXPORT_SYMBOL_FOR_MODULES("cxl_core")` (per the source review
recorded in `project_kernel_6_19_to_7_0_source_review.md`), so
`nvidia.ko` can't call it. C2 is the surgical hand-roll: same effect,
narrower than the legacy clear-the-whole-mask, no separate TU, no
module parameter, ~50 lines added to `nv-pci.c`.

This is a strong upstream candidate (`upstream-candidacy: high`):
NVIDIA-bug-#979 corroborates the eGPU error path that exposed the
demotion; the kernel's own `pci_aer_unmask_internal_errors()` validates
the operation's general correctness; and C2 makes the same
device-specific decision for NVIDIA's devices that the kernel already
makes for CXL devices.

## v1 audit

The v1 fork branch tip
(`2cc240ef06fd740262a0c2532b043dd852258a83` —
"nv-pci: unmask AER Internal Errors at probe") makes two hunks against
`kernel-open/nvidia/nv-pci.c`:

**Hunk 1** — new file-scope helper inserted immediately after
`nv_pci_validate_bars`:

```c
static void
nv_pci_unmask_aer_internal_errors(struct pci_dev *pci_dev)
{
    int aer = pci_find_ext_capability(pci_dev, PCI_EXT_CAP_ID_ERR);
    u32 mask;

    if (aer == 0)
        return;

    if (pci_read_config_dword(pci_dev, aer + PCI_ERR_UNCOR_MASK, &mask) == 0 &&
        (mask & PCI_ERR_UNC_INTN) != 0)
    {
        pci_write_config_dword(pci_dev, aer + PCI_ERR_UNCOR_MASK,
                               mask & ~PCI_ERR_UNC_INTN);
        pci_info(pci_dev,
                 "AER: unmasked Uncorrectable Internal Error at probe\n");
    }

    if (pci_read_config_dword(pci_dev, aer + PCI_ERR_COR_MASK, &mask) == 0 &&
        (mask & PCI_ERR_COR_INTERNAL) != 0)
    {
        pci_write_config_dword(pci_dev, aer + PCI_ERR_COR_MASK,
                               mask & ~PCI_ERR_COR_INTERNAL);
    }
}
```

**Hunk 2** — one-line call site inside `nv_pci_probe`, AFTER the
`NV_PCI_SRIOV_SUPPORT` early-exit block, BEFORE the
`nv_kmem_cache_alloc_stack` call that starts the rest of probe:

```c
nv_pci_unmask_aer_internal_errors(pci_dev);
```

Block comment immediately above the call site explains the placement
(after SR-IOV early-exit so VFs are filtered out; before init so a
transient PCIe error during bring-up reaches the standard recovery
path).

**Strengths.**

- **Surgical narrowing.** v1 clears only `PCI_ERR_UNC_INTN` (bit 22)
  and `PCI_ERR_COR_INTERNAL` (bit 14), preserving every other bit in
  both mask registers via `mask & ~PCI_ERR_UNC_INTN` /
  `mask & ~PCI_ERR_COR_INTERNAL`. The legacy ancestors
  (`0022-G3-H-*` and `0002-tb-egpu-aer-uncmask-clear`) cleared the
  ENTIRE `PCI_ERR_UNCOR_MASK` register to zero — a wider blast radius
  with no empirical evidence the other bits needed clearing. v1's
  narrowing matches what kernel 7.0's `pci_aer_unmask_internal_errors()`
  does (which is the canonical operation the kernel exports to CXL).
- **No separate TU, no module parameter.** Legacy P5 introduced
  `nv-tb-egpu-aer.{c,h}` (~190 lines, gated by
  `NVreg_TbEgpuAerUncMaskClear`); v1 inlines the helper directly in
  `nv-pci.c` (~50 lines, unconditional). Less surface, less
  module-parameter surface for upstream review to argue about.
- **Correct probe-site placement.** The call sits AFTER the
  `NV_PCI_SRIOV_SUPPORT` block (so VFs are excluded by the existing
  guard — VFs return earlier and never reach the call site) and
  BEFORE the rest of probe (so any Internal Error during the rest of
  bring-up takes the visible recovery path).
- **Reads-before-writes.** The helper reads the current mask, checks
  whether the relevant bit is set, and writes only when the write
  would actually change state. Idempotent on devices already in the
  desired state — no unnecessary config-space writes, no log noise.
- **In-source comment block explains WHY.** The PCIe r6.0 §6.2.3.2
  citation and the
  `pci_aer_unmask_internal_errors()`/CXL-export-restriction note are
  in the source file, so a future maintainer reading the code sees
  the rationale without grepping commit history.
- **Single info-level log line** matches the intent's nominal
  telemetry tier — it confirms the unmask happened (prove-the-path)
  without spamming when the mask was already clear.

**Weaknesses.**

- None surfaced by this review. The narrowing-vs-clear-all decision is
  correct, the placement is correct, the telemetry tier is correct,
  the operation faithfully reproduces what
  `pci_aer_unmask_internal_errors()` does.
- The correctable-mask write is silent (no log line), but that
  matches the intent — the operationally important signal is the
  uncorrectable unmask (which is what gates the recovery path); the
  correctable clear is hygiene.
- Read/write config-space failures are silent. The legacy
  `0002-tb-egpu-aer-uncmask-clear.patch` warned on these. We
  considered adding parity warnings (see Design choices below) and
  chose NOT to for v2.

**Surprises relative to vanilla.**

- Vanilla 595.71.05 `nv_pci_probe` does NOT touch AER at all — there is
  no precedent in NVIDIA's own code for clearing or setting AER mask
  bits in this driver. The patch is purely additive against a vanilla
  no-AER-handling baseline.
- The `pci_info()` macro is exactly the kernel-canonical form used by
  `drivers/pci/pcie/aer.c` itself. No bespoke logging wrapper.

## Design choices

The main alternatives considered during the v2 review:

- **Narrow to Internal-Error bits vs. clear the whole UncMask.** The
  legacy ancestors cleared `PCI_ERR_UNCOR_MASK` to zero entirely
  (matching Windows's observed `UncMask=0`). v1's narrower
  Internal-Error-only approach has two advantages: (1) it matches what
  the kernel itself does in `pci_aer_unmask_internal_errors()`, which
  is the canonical operation for "make Internal Errors visible"; (2)
  it preserves whatever the platform/BIOS deliberately set on other
  bits (e.g. a board that masks Completion Timeout for a known-flaky
  retimer would not be silently un-masked by C2). For an
  upstream-bound patch this is strictly better than the Windows-parity
  argument, and Windows's `UncMask=0` is consistent with — but not
  evidence against — the narrower approach. Kept v1 as written.

- **In-place in `nv-pci.c` vs. separate `nv-tb-egpu-aer.{c,h}` TU.**
  Legacy P5 added a separate translation unit explicitly to make P5's
  independence from M-recover (P2) "real". For v2 the operation is so
  small (~50 lines including comments) and so tightly coupled to
  `nv_pci_probe`'s SR-IOV-early-exit shape that a separate TU adds
  more surface than it justifies. Inlining also makes the upstream PR
  smaller and less novel-shaped: it's a `static void` helper called
  once, not a new `EXPORT_SYMBOL`-shaped boundary. Kept v1's inline
  shape.

- **Unconditional vs. module-parameter-gated.** Legacy P5 had
  `NVreg_TbEgpuAerUncMaskClear` (default 1). For v2 the operation is
  surgical enough (two bits, on the probed PF, idempotent) that an
  unconditional default is correct. If a regression ever surfaces, a
  knob can be added in the addon layer ([[A5-version-and-toggles]])
  without re-touching this patch. Removing the parameter shrinks the
  upstream-PR surface and removes a configuration knob that has no
  evidence of needing to be tunable. Kept v1 unconditional.

- **Telemetry on read-/write-failure vs. silent.** Legacy P5 emitted
  `dev_warn` on config-space read or write failure. v1 is silent on
  both. The intent's telemetry contract describes only the
  unmask-happened path explicitly. We chose to keep v1 silent for two
  reasons: (1) `pci_read_config_dword` on a present device is
  extremely unlikely to fail at probe time — when it does, the device
  is already in such bad shape that other probe steps will fail
  visibly almost immediately; (2) adding warn paths grows the upstream
  diff for low-value signal. Trade-off acknowledged — if real-world
  experience surfaces a board where AER config-space reads fail
  silently, this becomes a future delta (likely
  `should-fix`-tier).

- **Correctable-mask telemetry symmetry.** The uncorrectable unmask
  emits `pci_info`; the correctable unmask is silent. We considered
  adding a symmetric info line. Chose against: the operationally
  important signal is the uncorrectable bit (it gates the recovery
  path); the correctable clear is hygiene with no recovery-path
  consequence. Two info lines per probe would be log noise without
  added diagnostic value. Kept v1's asymmetry.

- **Frontmatter cross-reference to [[C5-crash-safety]].** Plan
  guidance offered two options: eager (frontmatter `related-patches:
  [C5-crash-safety]`, accepting the temporary Rule-6 lint failure
  until C5's intent file is authored in Task 8) vs. deferred (body
  prose only, backfill frontmatter at Task 14's cross-patch audit).
  Chose deferred per plan recommendation. Lint stays green for every
  per-patch task.

## v1 → v2 deltas

(no v1→v2 deltas — v1 already meets the v2 intent)

The v1 fork branch was authored after the legacy refactor and after
the kernel-7.0 source review, with both pieces of context already
incorporated. The narrowing-to-Internal-Error-bits, the unconditional
default, and the inlined-in-`nv-pci.c` shape were all deliberate
improvements over the legacy ancestors at v1 commit time. The v2
intent reifies those decisions as the normative shape; the audit
finds no behaviour gap to close.

`v1-tip-sha == v2-tip-sha == 2cc240ef06fd740262a0c2532b043dd852258a83`
is the zero-delta sentinel per M2 from the C1 checkpoint.

## Done gate

- [x] `docs/patch-intents/C2-aer-internal-unmask.md` exists, lints clean, `status: reviewed`.
- [x] All must-fix deltas applied as fork-branch commits citing their delta IDs. _(N/A — zero deltas.)_
- [x] `patches/base/C2-aer-internal-unmask.patch` refreshed by `regen`. _(N/A — no fork-branch change; existing file already reflects `2cc240ef`.)_
- [x] `tools/validate-patchset.sh` passes (compile gate).
- [x] `bash tests/run.sh` green.
- [x] Audit-reviewer subagent approved. _(Pending — this review file is the audit-reviewer's input.)_

## Cross-references

- Intent file: `docs/patch-intents/C2-aer-internal-unmask.md`
- Manifest row: `patches/manifest` line for `C2-aer-internal-unmask`
  (layer `base`, source `fork:c2-aer-internal-unmask`)
- Vanilla baseline:
  `kernel-open/nvidia/nv-pci.c:nv_pci_probe` (vanilla 595.71.05 has no
  AER manipulation at all — the helper insertion site and call site
  are both additive)
- Fork branch: `c2-aer-internal-unmask` on
  `apnex/open-gpu-kernel-modules`
- Upstream issue: n/a (NVIDIA-bug-#979 covers the eGPU error path that
  exposed the demotion; this patch is independent hardening)
- Related reviews: [[C5-crash-safety]] (registers
  `pci_error_handlers` and performs the actual recovery when an
  Internal Error fires — C2 makes the error visible; C5 acts on it).
