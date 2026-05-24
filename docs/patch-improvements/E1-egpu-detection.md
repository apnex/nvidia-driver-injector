---
id: E1-egpu-detection
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: 000ea7a51db8b78225950a753a390a82f3aa1d81
v2-tip-sha: 000ea7a51db8b78225950a753a390a82f3aa1d81
status: accepted
intent-updates: []
---

# E1-egpu-detection — improvement triage

## Triangulation sources

- **Vanilla NVIDIA 595.71.05:**
  `src/nvidia/arch/nvalloc/unix/src/osinit.c:RmCheckForExternalGpu` —
  vanilla `git show 595.71.05:src/nvidia/arch/nvalloc/unix/src/osinit.c`
  has `RmCheckForExternalGpu(OBJGPU *pGpu, OBJCL *pCl)` walking the
  bus topology via `clFindP2PBrdg`, dispatching the RM-internal control
  `NV2080_CTRL_CMD_INTERNAL_GET_EGPU_BRIDGE_INFO` with
  `rmGpuLocksAcquire`/`Release` around the lookup, requiring
  `approvedBusType == NV2080_CTRL_INTERNAL_EGPU_BUS_TYPE_TB3` AND
  `(CL_PCIE_SLOT_CAP_HOTPLUG_CAPABLE & CL_PCIE_SLOT_CAP_HOTPLUG_SURPRISE)`
  on the same upstream bridge, looping until `CL_IS_ROOT_PORT(portCaps)`
  (~95 lines). Companion vanilla files E1 touches:
  `kernel-open/nvidia/os-pci.c` (vanilla function `os_pci_remove` is
  the insertion-point anchor at lines 145-149),
  `kernel-open/common/inc/os-interface.h` lines 108-110 (vanilla
  declarations adjacent to `os_pci_remove`), and the core-RM-side
  `src/nvidia/arch/nvalloc/unix/include/os-interface.h` lines 108-110
  (same shape).
- **Kernel reference (linux-v6.19):**
  `/root/linux-v6.19/include/linux/pci.h:2798-2817` — definition of
  `pci_is_thunderbolt_attached(struct pci_dev *pdev)`: a static inline
  that returns `true` if `pdev->is_thunderbolt` is set OR if any
  upstream bridge (walked via `pci_upstream_bridge`) has it set. The
  docstring says: "Walk upwards from @pdev and check for each
  encountered bridge if it's part of a Thunderbolt controller. Reaching
  the host bridge means @pdev is not Thunderbolt-attached."
- **Kernel reference (linux-v6.19):**
  `/root/linux-v6.19/include/linux/pci.h:465-479` — `is_thunderbolt:1`
  bit alongside `untrusted:1` and `external_facing:1`. The kernel's
  own comment on `untrusted` states: "Devices marked being untrusted
  are the ones that can potentially execute DMA attacks and similar.
  They are typically connected through external ports such as
  Thunderbolt but not limited to that." The `external_facing:1` field
  is on the bridge (the parent); `untrusted:1` is set on devices
  downstream of such bridges — "the endpoint-local form of the
  external_facing marker" is the v2 intent/review's accurate framing.
- **Kernel reference (linux-v6.19):**
  `/root/linux-v6.19/drivers/pci/probe.c:1738-1757` —
  `set_pcie_untrusted()` shows the two paths by which `pdev->untrusted`
  becomes set: (1) propagation from an already-untrusted upstream
  bridge (`parent->untrusted` → child inherits), (2) the device
  itself returning true from `arch_pci_dev_is_removable(dev)` (which
  on x86 reads the ACPI external-facing marker). Confirms the v2
  intent's claim that `untrusted` is the endpoint-local form of the
  firmware external-facing marker.
- **v2 intent:** `/root/nvidia-driver-injector/docs/patch-intents/E1-egpu-detection.md`
  (three Requirements: classify-external-when-TB-attached,
  classify-external-when-untrusted, emit-one-log-line-at-detection;
  five Scenarios across the three Requirements covering TB4/USB4-VSEC,
  TB3-preserved, non-TB external-facing-port, purely-internal silent,
  and one-log-per-probe; Scope boundary explicitly excludes module
  parameter, OBJCL-callers-globally signature change, internal RM
  control removal, and downstream `is_external_gpu` consumer changes;
  Telemetry contract names `pci_info` format string verbatim).
- **v2 review:** `/root/nvidia-driver-injector/docs/patch-reviews/E1-egpu-detection.md`
  (single nice-to-have delta `E1-egpu-detection-D1` on the wrapper
  name being narrower than its behaviour — **deferred** for
  kernel-symbol-name mirroring and review-surface-minimality; `D2`
  no-must-fix; the Design choices section enumerates rejected
  alternatives — fresh vendor-ID table vs kernel-classification, OR
  vs either-signal-alone, kernel-open vs core-RM consultation site,
  rename vs keep, NULL-guard placement, `pci_info` vs `pci_warn` vs
  `pci_notice`, false-path log line emission, removing-legacy-TB3-table,
  C4 frontmatter cross-ref).
- **Fork branch tip (v1 == v2):** `000ea7a51db8b78225950a753a390a82f3aa1d81`
  on `apnex/open-gpu-kernel-modules` branch `e1-egpu-detection`. The
  branch is **built on top of `c4-err-handlers-scaffold`** (so the
  cumulative diff carries C1-C4 + E1).
- **aorus-5090 ancestor patch:** **NONE — no direct ancestor exists.**
  The aorus geometry never carried an in-driver detection patch.
  Instead, the project relied on the **modprobe.d cmdline workaround**
  `NVreg_RegistryDwords="RmForceExternalGpu=1"`, which is currently
  active in
  `/root/nvidia-driver-injector/scripts/host-files/etc/modprobe.d/nvidia-driver-injector.conf:54-55`
  (the file's banner comment annotates it as "Lever A — force the
  driver to treat this GPU as external (eGPU), bypassing TB-bridge
  whitelist that doesn't include TB4/TB5 hubs"). The C+E+A geometry
  classifies E1 as an `E` patch precisely because it is a *bug fix
  to NVIDIA's own code* (vanilla `RmCheckForExternalGpu`) that retires
  the cmdline workaround once it ships. Pivoted to design-doc
  archaeology per the task brief's "no direct ancestor exists" branch.
- **aorus-5090 docs (binding M1+M2 verification — actually consulted):**
  - `/root/aorus-5090-egpu/docs/freeze-investigation-plan.md:120-128`
    — original Lever A negative-result writeup (2026-05-02): applied
    `pci=realloc=off` and `RmForceExternalGpu=1` on the unpatched
    build, confirmed cmdline persistence in `/proc/cmdline` and
    `/proc/driver/nvidia/params`; lite test still froze within ~1
    minute (the cmdline override alone was insufficient to fix the
    instability but did flip `is_external_gpu` to true — proving the
    knob's mechanism). **Relevant; kept as evidence the workaround
    was applied as Lever A.**
  - `/root/aorus-5090-egpu/docs/freeze-investigation-plan.md:270-280`
    — original Lever E source-review pointer: "`RmCheckForExternalGpu()`
    and the bridge-detection logic (PR #984 rewrites this; understand
    what it changes)" — the project's first awareness that the
    detection logic was the upstream concern. **Relevant; kept as
    the original "in-driver fix is the target" framing source.**
  - `/root/aorus-5090-egpu/docs/source-review-notes.md:23-33`
    + `:1400-1405` — Pass 1 finding "eGPU detection has shallow
    penetration — *not* the bug": the analysis that `is_external_gpu`
    only changes behaviour at 5 sites
    (`osinit.c:400`/`osinit.c:1335`/`kern_perf.c`/`subdevice_ctrl_gpu_kernel.c`/`nv-pci.c:2324`)
    and concluded "the eGPU property doesn't change much. The bug is
    not in 'different code path on eGPU.'" Plus `:1400-1405` flagging
    `osinit.c:425-528` as the canonical detection-logic surface.
    **Relevant; kept — establishes that E1 fixes the classification
    correctness without changing the bug surface itself (the bug
    surface is what other patches address; E1 unlocks
    `is_external_gpu`-gated paths on modern hardware so they apply
    at all).**
  - `/root/aorus-5090-egpu/docs/source-review-notes.md:160-170`
    + `:245-255` + `:700-710` — RmForceExternalGpu usage rationale
    + the dependency chain (Lever A applied the
    `pci/RmForceExternalGpu` slice). **Relevant; kept — documents
    the production-deployed workaround that E1 retires.**
  - `/root/aorus-5090-egpu/docs/tb4-pcie-topology.md:1-50`
    + `:51-67` — the empirically-validated TB4 topology diagram
    (Intel TB4 controller → Barlow Ridge upstream hub → Barlow
    Ridge downstream hub → RTX 5090) plus the key insight that
    `lspci` LnkCap on TB-tunnelled bridges is virtualised. Critical
    archaeology for E1: this document is the project's hardware
    record showing the Barlow Ridge bridges carry the Intel
    Thunderbolt VSEC (so `pci_is_thunderbolt_attached()` returns
    true on the production hardware), which is exactly the
    hardware-verified claim referenced in `docs/upstream-plan.md §E1`
    (lines 288-291). **Relevant; kept.**
  - `/root/aorus-5090-egpu/docs/tb-pcie-cap-architecture.md:62-67`
    + `:90-100` — the layer-comparison table puts "Vendor GPU
    driver (NVIDIA) | Via `pci_is_thunderbolt_attached()`" as a
    valid layer for TB-aware policy, with the framing "no kernel
    layer currently USES that to drive PCIe link cap policy" (the
    table calls out that consumers exist but underuse the helper).
    **Relevant; kept as evidence the helper is a known
    upstream-friendly entry point.**
  - `/root/aorus-5090-egpu/docs/iommu-gsp-lockdown-analysis.md:65-75`
    + `:255-265` — documents `pci_dev->untrusted = 1` as the kernel
    security signal on TB-attached devices and the H10 mechanism
    (untrusted → IOMMU full DMA translation → GSP DMA rejection).
    **Relevant; kept — confirms `untrusted` is reliably set on this
    project's hardware by the kernel TB driver, which is the
    second-signal evidence the v2 intent's Requirement-2 relies on.**
  - `/root/aorus-5090-egpu/docs/lever-catalog.md:485-510`
    (Lever T — IOMMU disable cmdline workaround) — confirms the
    project's production posture relies on `untrusted=1` being set
    on the eGPU (the IOMMU workaround would not be needed otherwise).
    Cross-reference for the kernel's `untrusted` field semantics on
    the production hardware. **Relevant; kept.**
  - `/root/aorus-5090-egpu/docs/lever-catalog.md:755-810`
    + `:835-845` — Lever U mechanism (TB-link-speed cap) uses
    `pci_is_thunderbolt_attached(pci_dev)` as the gate condition in
    a hypothetical `nv_pci_probe` insertion: "**HIGH** —
    `pci_is_thunderbolt_attached()` is upstream kernel API. Cap to
    TB-version max is a reasonable default for a TB-aware GPU
    driver." Documents the project's pre-existing assessment that
    the kernel helper is the right substrate for TB-aware NVIDIA
    driver behaviour. **Relevant; kept — this is the canonical
    project-internal justification for the kernel-helper-based
    detection approach E1 implements.**
  - `/root/aorus-5090-egpu/docs/reliability-hypothesis-ledger.md:155-170`
    (H10 — IOMMU-untrusted-causes-DMA-failure entry) —
    empirical signal that `untrusted=1` is set on this exact
    hardware (otherwise `iommu=pt` would have worked without
    Lever T). **Relevant; kept — direct empirical evidence the
    second-signal of E1's union fires on the production hardware.**
  - `/root/aorus-5090-egpu/docs/architecture-and-modularity.md:62-100`
    (L1 — NVIDIA open KMD fork) — sovereignty-lens grounding for
    placing detection logic inside the fork. The justification "hot
    path inside NV-internal code; touches RM-side state that isn't
    exported" applies cleanly to E1 (the detection sets the
    `PDB_PROP_GPU_IS_EXTERNAL_GPU` property that downstream
    eGPU-aware code paths read). Added per M1+M2 — binding did not
    list it but it is the canonical sovereignty-lens reference for
    this kind of L1 patch. **Added; kept.**
  - `/root/nvidia-driver-injector/docs/upstream-plan.md:268-303`
    (E1 — Modernise eGPU detection) — the project's canonical
    target-state document explicitly describes E1's mechanism,
    rationale, hardware-verification, and retirement-of-workaround.
    Strictly not aorus-side but is the cross-reference between
    aorus archaeology and the upstream-bound posture. **Added; kept.**
  - **Verified actually-consulted (M1+M2):** kept
    `freeze-investigation-plan.md:120-128, 270-280` (Lever A origin
    + first awareness of in-driver detection as the fix target),
    `source-review-notes.md:23-33, 160-170, 245-255, 700-710,
    1400-1405` (penetration analysis + Lever-A usage + canonical
    code surface), `tb4-pcie-topology.md:1-50, 51-67` (hardware
    topology), `tb-pcie-cap-architecture.md:62-67, 90-100`
    (helper-as-canonical-layer evidence),
    `iommu-gsp-lockdown-analysis.md:65-75, 255-265` (untrusted=1
    empirical signal), `lever-catalog.md:485-510, 755-810, 835-845`
    (Lever T cross-reference + Lever U canonical
    `pci_is_thunderbolt_attached` use),
    `reliability-hypothesis-ledger.md:155-170` (H10 empirical
    signal for second-signal), `architecture-and-modularity.md:62-100`
    (L1 sovereignty grounding, **added by M1+M2 — not in binding**),
    `docs/upstream-plan.md:268-303` (project canonical target,
    **added by M1+M2 — not in binding**). **Dropped — none from
    binding**: the binding's three suggestions (`tb4-pcie-topology.md`,
    `source-review-notes.md`, `pcie-kernel-cmdline-options.md`)
    were all consulted but only the first two had load-bearing
    content; `pcie-kernel-cmdline-options.md` had no E1-relevant
    content (it documents kernel cmdline options, not in-driver
    detection — that document feeds into Lever T archaeology, not
    E1). Effectively dropped per M1+M2.
- **Community-signal entries:** **NONE TAGGED FOR E1** —
  `/root/nvidia-driver-injector/docs/patch-improvements/_community-signal.md:128-131`
  explicitly states: "No findings tagged for: `C1` (Kbuild/version.mk),
  `E1` (eGPU detection), `A1` (PCIe primitives), `A4` (close-path
  telemetry), `A5` (version/toggles)." Per M5, frame this as
  silence-as-signal: the community symptom dataset (gpu-lost, AER
  recovery failure, BAR mapping, krcWatchdog, hibernate) does not
  surface eGPU-detection issues. This is *expected* because vanilla
  detection misclassifies eGPUs **silently** — the operator does not
  observe a "detection failed" symptom, they observe the
  *downstream* consequence (instability from internal-GPU power
  management). The vanilla driver's failure to classify is exactly
  the silent gap E1 closes. Community signal cannot detect this
  class of bug; only source review and hardware-verification can.
  See `/root/nvidia-driver-injector/docs/upstream-plan.md:288-291`
  (hardware-verified note: "on the project's Barlow Ridge /
  Thunderbolt 5 hardware, `pci_is_thunderbolt_attached()` returns
  true").

## v1 archaeology

What the aorus-5090 mining surfaced about E1's pre-history (the
project's `RmForceExternalGpu=1` cmdline workaround, since there is
no direct in-driver patch ancestor):

- **Original problem framing — vanilla detection is shallow but the
  property gates real behaviour.**
  `docs/source-review-notes.md:23-33` (Pass 1, 2026-05-04): the
  source-review traced the detection logic and noted "the eGPU
  property doesn't change much. The bug is not in 'different code
  path on eGPU.' It must be in code that's broken regardless, that
  just happens to manifest on Blackwell × tunneled-PCIe." The
  property reads at five sites (`osinit.c:400`, `osinit.c:1335`,
  `kern_perf.c`, `subdevice_ctrl_gpu_kernel.c`, `nv-pci.c:2324`).
  This finding is **load-bearing for E1's framing**: E1 does NOT
  introduce eGPU-specific behaviour; it only ensures the
  already-existing behaviour gates correctly on modern hardware.
  E1's framing as a *correctness fix to vanilla's classification*
  (not as an introduction of new eGPU semantics) is grounded in
  this 2026-05-04 finding.
- **Original problem framing — PR #984 was the project's first
  awareness that in-driver detection was the fix target.**
  `docs/freeze-investigation-plan.md:270-280` (Lever E definition):
  "`RmCheckForExternalGpu()` and the bridge-detection logic (PR #984
  rewrites this; understand what it changes)" — the project knew
  upstream had a contributed but-not-merged PR addressing the same
  classification gap. That PR (#981, the actual number, not #984
  per memory `project_issue_979_upstream_state_2026_05_22`) closed
  unmerged in January 2026. E1 is the project's own implementation
  of the same idea (with the OR-of-two-signals design instead of
  whatever #981 proposed; the closed PR has no maintainer review to
  triangulate against).
- **Constraint discovered — why the cmdline workaround was deployed,
  not the in-driver fix.**
  `docs/source-review-notes.md:155-170` + `:245-255` (Pass 3+,
  2026-05-04): "Lever A took the pci/RmForceExternalGpu slice" —
  the *cheapest* lever that could ship without a driver patch was
  the modprobe.d override. The project's investigation discipline
  ("cheaper experiments first" per memory
  `feedback_reliability_methodology`) chose the cmdline workaround
  before designing an in-driver fix. The in-driver fix sat in the
  backlog as Lever E (read-only source review) and was never
  carved out as its own lever because the project's focus shifted
  to the GPU-lost / DMA-path freeze investigation (Levers H, I, P,
  Q, M, T...). E1 is the in-driver fix the project never landed in
  the aorus geometry, now built as part of the upstream-bound C+E+A
  set.
- **Constraint discovered — Lever A's cmdline override was
  EMPIRICALLY APPLIED but the deeper bug was not in the detection
  path.** `docs/freeze-investigation-plan.md:120-128` (Lever A
  negative result, 2026-05-02): "applied `pci=realloc=off` and
  `NVreg_RegistryDwords='RmForceExternalGpu=1'` ... Confirmed both
  live in /proc/cmdline and /proc/driver/nvidia/params after cold
  boot. Ran the lite ollama test ... Host froze within ~1 minute."
  The cmdline mechanism *did* flip `is_external_gpu` to true; the
  freeze still happened. **This is critical context for E1's
  framing**: E1 fixes the classification correctness (the cmdline
  workaround was a correct-classification workaround) but the
  freeze class still fires — meaning the other C/E/A patches (C3,
  C4, A2, A3 etc.) are doing the rest of the work, NOT E1. E1's
  Scope boundary correctly carves this out: "This patch does NOT
  change the downstream consequences of `is_external_gpu`."
- **Constraint discovered — hardware-verified signal coverage.**
  `docs/tb4-pcie-topology.md:1-50` documents the production
  hardware topology (Intel TB4 controller → Barlow Ridge upstream
  → Barlow Ridge downstream → RTX 5090). The Barlow Ridge bridges
  carry the Intel Thunderbolt VSEC; `docs/upstream-plan.md:288-291`
  records the empirical confirmation: "on the project's Barlow
  Ridge / Thunderbolt 5 hardware, `pci_is_thunderbolt_attached()`
  returns true ... `untrusted` is the endpoint-local union member
  (it propagates down from the external-facing root port)."
  `docs/iommu-gsp-lockdown-analysis.md:65-75` confirms `untrusted=1`
  is set on the eGPU (otherwise IOMMU passthrough via `iommu=pt`
  would have worked and Lever T would be unnecessary). **Both
  union signals fire on the production hardware** — the OR-shape
  is empirically defensible, not just theoretically.
- **Alternatives considered + rejected — fresh vendor-ID table.**
  Not explicit in aorus archaeology (the project never built an
  in-driver detection patch in the aorus geometry). The v2 review's
  Design choices section enumerates this alternative and rejects it
  for the "every new transport silicon would require a patch" reason.
  E1 chooses the kernel-classification union over a vendor-ID
  refresh; the archaeology supports this indirectly via Lever U's
  use of `pci_is_thunderbolt_attached()` (`docs/lever-catalog.md:755-810`)
  — the project already treats the kernel helper as the canonical
  TB-detection substrate.
- **Forgotten / latent invariant — `is_external_gpu` reads are
  cached at probe.** The five consumer sites
  (`docs/source-review-notes.md:23-33`) all read
  `pGpu->getProperty(pGpu, PDB_PROP_GPU_IS_EXTERNAL_GPU)` or
  `nv->is_external_gpu` rather than re-running
  `RmCheckForExternalGpu`. E1's contract is therefore "set the
  property correctly at probe time"; runtime changes to TB
  state (cable unplugged, etc.) are NOT re-checked by the existing
  vanilla code. E1 inherits this caching invariant; the cached
  read is sufficient because PCIe enumeration of an unplugged TB
  device leads to surprise-removal handling (a separate path
  C4/A2/A3 own), not a re-classification. **Not a refinement
  candidate** — the invariant is already implicit in the intent's
  "at probe" framing.
- **Forgotten / latent invariant — no conftest needed for
  `pci_is_thunderbolt_attached` / `pdev->untrusted` on the build
  target.** Both kernel APIs have been present since well before
  the NVIDIA driver's minimum-supported kernel version
  (`pci_is_thunderbolt_attached` since v4.18,
  `pdev->untrusted` since v4.20). The build target is
  `7.0.9-204.fc44.x86_64` — far newer than either floor. Direct
  references without conftest shims are correct for this target.
  Confirmed by inspection: `grep 'NV_PCI_IS_THUNDERBOLT\|pci_is_thunderbolt'
  kernel-open/conftest.sh` returns no compat-shim hits. **Not a
  refinement candidate for this sub-cycle** — see I4 for the
  upstream-PR-time consideration.

## Improvements considered

### E1-egpu-detection-I1 — Rename `os_pci_is_thunderbolt_attached` to reflect the union behaviour

- **Lens:** naming (re-examination of v2 deferral D1)
- **Current state:** The wrapper is named
  `os_pci_is_thunderbolt_attached` in three files
  (`kernel-open/common/inc/os-interface.h:111`,
  `src/nvidia/arch/nvalloc/unix/include/os-interface.h:111`,
  `kernel-open/nvidia/os-pci.c:169`) but consults BOTH
  `pci_is_thunderbolt_attached(pdev)` AND `pdev->untrusted`. The
  function returns true on the OR of the two, but the name names
  only the first half.
- **Proposed state:** Rename to one of:
  (a) `os_pci_is_external_attached` (most accurate to the union),
  (b) `os_pci_is_external_gpu_capable` (most aligned to caller
  intent — `RmCheckForExternalGpu`),
  (c) `os_pci_is_thunderbolt_or_untrusted` (most pedantic).
- **Value:** Surface-readability for an upstream reviewer skimming
  the os-interface header who would otherwise infer Thunderbolt-only
  behaviour from the name alone. Caller `RmCheckForExternalGpu`'s
  doc comment names both signals but the wrapper-side name does
  not.
- **Cost:** Rename touches three declaration sites + one definition
  + one call site (`osinit.c:471`). Five-site change. More
  importantly: the rename **diverges the wrapper name from the
  kernel symbol it mirrors** (`pci_is_thunderbolt_attached`).
  Currently a reader tracing the wrapper back to its kernel
  counterpart sees the obvious name correspondence; rename would
  break that. The kernel itself treats `untrusted` as a
  TB-overflow concept (linux-v6.19 `include/linux/pci.h:467-473`:
  "typically connected through external ports such as Thunderbolt
  but not limited to that"). The project's pre-existing
  Lever U design (`docs/lever-catalog.md:759`) calls the kernel
  helper directly with its narrow name — accepted naming convention.
  Block comment in the wrapper definition
  (`kernel-open/nvidia/os-pci.c:148-167`) explicitly names both
  signals; the misread is shallow and recoverable.
- **Verification mode:** A.
- **Intent impact:** none (Requirements specify behaviour, not the
  wrapper name).
- **Triage decision:** defer (re-upheld).
- **Resolution:** deferred — v2 D1 disposition upheld with
  strengthened evidence. The naming concern was the headline v2
  deferral and the task brief flagged it for triage; the v3
  triangulation surfaces **three independent strengthening
  signals** for the deferral:
  (1) The kernel's own comment on the `untrusted` field
  (linux-v6.19 `include/linux/pci.h:467-473`) explicitly treats
  external-untrusted as a TB-overflow concept ("typically
  connected through external ports such as Thunderbolt but not
  limited to that") — the kernel itself does not have a separate
  name for the union;
  (2) The project's pre-existing Lever U design
  (`docs/lever-catalog.md:759`, `:803`, `:835-845`) treats
  `pci_is_thunderbolt_attached()` as the canonical kernel helper
  for TB-aware NVIDIA driver behaviour and does not introduce a
  wider-named wrapper — consistent with E1's naming choice;
  (3) The upstream-PR review surface argument from the v2 review
  ("Mirror the kernel symbol name correspondence; the block comment
  names both signals") is the stronger argument for an
  upstream-bound patch in the Core layer's bloat budget. **Default
  reject for upstream-bound surface (rename for nuance is
  documentation-precision-for-precision's-sake; the block comment
  carries the correct precision)**. Disposition for follow-up: if
  an upstream NVIDIA reviewer surfaces the rename request during
  PR review, revisit with their guidance.

### E1-egpu-detection-I2 — Add `docs/upstream-plan.md §E1` cross-reference to the source-file block comment

- **Lens:** invariant clarity (provenance traceability)
- **Current state:** The wrapper definition at
  `kernel-open/nvidia/os-pci.c:148-167` has a block comment
  describing the two-signal union but does not cross-reference
  the project's hardware-verification source
  (`docs/upstream-plan.md:288-291` — "on the project's Barlow
  Ridge / Thunderbolt 5 hardware, `pci_is_thunderbolt_attached()`
  returns true ... `untrusted` is the endpoint-local union member").
- **Proposed state:** Append a one-line citation in the block
  comment: `// See docs/upstream-plan.md §E1 for hardware-verified
  signal coverage.`
- **Value:** Forward provenance from source to the design doc; a
  future maintainer asking "do we know both signals fire on real
  hardware?" finds the answer without grep.
- **Cost:** Cross-references an in-tree project-documentation path
  from a source file that's destined for upstream NVIDIA review.
  Upstream-side, the path `docs/upstream-plan.md` does not exist —
  the reference would be dead in any tree that picks up the patch
  upstream. The information is also derivable from the commit
  message ("RmForceExternalGpu=1 ... was the project workaround
  this patch replaces") plus the project memory
  (`project_nvidia_open_driver_egpu_layer_tb3_era`). An in-source
  cross-reference inverts the upstream-PR posture (clean
  context-free source) for marginal traceability gain.
- **Verification mode:** A.
- **Intent impact:** none.
- **Triage decision:** reject.
- **Resolution:** rejected — adds an upstream-broken path
  reference to an upstream-bound source file. The block comment
  is already precise; provenance lives in the v2 intent's
  Provenance section and the upstream-plan §E1 entry; an
  in-source path citation inverts the upstream-clean posture.
  Default-reject for upstream-bound surface.

### E1-egpu-detection-I3 — Document the cmdline-workaround retirement timeline in the v2 intent's Provenance

- **Lens:** invariant clarity (workaround retirement documentation)
- **Current state:** v2 intent Scope boundary (intent lines 146-155)
  names the `NVreg_RegistryDwords="RmForceExternalGpu=1"` modprobe
  override as the workaround E1 replaces and states "the project
  drops the modprobe knob" once a driver carries E1. The intent
  does NOT specify the retirement timeline — when the
  modprobe.d line itself should be removed from the project repo
  (`scripts/host-files/etc/modprobe.d/nvidia-driver-injector.conf:54-55`).
- **Proposed state:** Add a Scope-boundary clause clarifying that
  the modprobe.d removal is a **post-soak upstream-plan Gate
  step**, not part of E1's patch surface. E1 lands the in-driver
  fix; the modprobe.d retirement waits on `≥14-day soak +
  cutover` per `docs/upstream-plan.md` (the C+E+A
  geometry's standard cutover gate).
- **Value:** Forward-looking clarity for the operator. A future
  maintainer reading E1's intent might assume the modprobe.d line
  can be removed immediately upon landing E1; the C+E+A operating
  model requires a soak window before retiring belt-and-braces
  fallbacks.
- **Cost:** ~3 lines added to v2 intent's Scope boundary.
  Re-opens intent's `reviewed` lint state. The cross-reference
  to `docs/upstream-plan.md` couples E1's intent to
  project-operational documentation, which the upstream-bound
  Core+E layer should be agnostic of. Project-operational state
  belongs in addon-layer documentation (or in the modprobe.d
  file's own banner comment), not in E1's upstream-bound intent.
- **Verification mode:** A.
- **Intent impact:** refine Scope boundary.
- **Triage decision:** defer.
- **Resolution:** deferred — the retirement-timeline concern is
  **operational/addon**, not upstream-Core. Documenting it in E1's
  upstream-bound intent would mix concerns. The
  `upstream-plan.md` cutover gate is the right home; if
  the operator reads E1's Scope boundary and infers immediate
  removal, the modprobe.d file's own banner comment can be
  updated to add "kept until production cutover" — that's
  addon-layer state. **Disposition for follow-up:** Task 14's
  cross-patch surface audit should add a one-liner to
  `upstream-plan.md` (or the modprobe.d banner) when
  reconciling addon-layer state; the E1 catalog tracks the gap
  for posterity.

### E1-egpu-detection-I4 — Add conftest shim for `pci_is_thunderbolt_attached` for older-kernel upstream support

- **Lens:** robustness (upstream-PR compatibility surface)
- **Current state:** E1 calls `pci_is_thunderbolt_attached(pdev)`
  and reads `pdev->untrusted` directly with no kernel-version
  compat shim.
  `grep 'NV_PCI_IS_THUNDERBOLT\|pci_is_thunderbolt' kernel-open/conftest.sh`
  returns zero hits — there is no conftest entry for either API.
- **Proposed state:** Add conftest stanzas mirroring the existing
  pattern for other kernel-API tests (e.g.
  `NV_PCI_ENABLE_ATOMIC_OPS_TO_ROOT_PRESENT` per the surrounding
  `os-pci.c` code at line 162-178 of v1's patched file). The
  shims would `#ifdef`-gate the kernel-helper calls so older
  kernels build cleanly with detection silently returning
  NV_FALSE.
- **Value:** Older-kernel build compatibility for the eventual
  upstream PR. NVIDIA's driver supports a kernel range; an
  upstream submission that breaks builds on older supported
  kernels would be rejected.
- **Cost:** ~30 LoC of conftest scaffolding + two `#ifdef`
  branches in `os-pci.c`. Inflates patch surface in a domain
  (conftest infrastructure) that this sub-cycle has otherwise
  left alone. The build target this sub-cycle validates against
  (`7.0.9-204.fc44.x86_64`) is far above either floor; the gates
  pass. **Both APIs are old enough that NVIDIA's
  minimum-supported-kernel floor is above them**
  (`pci_is_thunderbolt_attached` since v4.18 = 2018-08;
  `pdev->untrusted` since v4.20 = 2018-12; NVIDIA 595 series
  driver claims kernel 3.10 minimum but in practice the modern
  open driver requires v5.0+). Investigating the actual NVIDIA
  floor is itself a research task. For this sub-cycle's gate
  (compile against 7.0.9), no shim is needed.
- **Verification mode:** A (verifying the kernel-version floor)
  + B (actually testing build on older kernels — which this
  sub-cycle does not have set up).
- **Intent impact:** none (compat-shim is implementation detail).
- **Triage decision:** defer.
- **Resolution:** deferred to upstream-PR-prep work. The
  sub-cycle 3 gate (compile against 7.0.9-204.fc44.x86_64) does
  not require the shim. If/when NVIDIA reviews the upstream PR
  and surfaces a kernel-version compatibility concern, this
  catalog entry is the carry-over to address. **Disposition for
  follow-up:** add to the upstream-PR-prep checklist (which is
  tracked in `docs/upstream-plan.md §E1`, currently silent on
  conftest requirements). Not a sub-cycle 3 deliverable.

### E1-egpu-detection-I5 — Refine `pci_info` log format separator from `external/untrusted` to a less-ambiguous form

- **Lens:** quality (log-format precision)
- **Current state:** The detection log line uses
  `"external GPU detected (thunderbolt-attached=%s, external/untrusted=%s)\n"`
  in both `kernel-open/nvidia/os-pci.c:191-194` and the v2 intent's
  Telemetry contract (intent line 174). The `external/untrusted=%s`
  slash separator inside a key name reads ambiguously — an operator
  could parse the slash as "external OR untrusted" or as "this
  composite key, where untrusted is the data type." The value is
  always `"yes"` or `"no"`.
- **Proposed state:** Change the key to a less-ambiguous form, e.g.
  `untrusted=%s` alone (drop the "external/" prefix — the kernel's
  field name is `untrusted`, that's the canonical name) or
  `external-facing-untrusted=%s` (hyphenate the disjunction).
- **Value:** Operator-grep clarity; a less-ambiguous key name eases
  log parsing.
- **Cost:** Touches the v2 intent's Telemetry contract format
  string (which is documented verbatim) AND the v1 source code,
  AND requires the v2 review's Strengths section to be updated
  if the format string is quoted there. The current format reads
  fine in context (the surrounding `thunderbolt-attached=yes/no`
  parallel makes the binary nature clear); the slash is a
  documentation convention reading "the external-facing-bridge /
  untrusted-device" pairing the kernel uses internally. v1's
  format aligns with the kernel's own
  `set_pcie_untrusted()` comment shape (linux-v6.19
  `drivers/pci/probe.c:1744-1747`: "If the upstream bridge is
  untrusted we treat this device as untrusted as well").
- **Verification mode:** A.
- **Intent impact:** refine Telemetry contract.
- **Triage decision:** reject.
- **Resolution:** rejected — log format precision-for-precision's-sake
  on an upstream-bound surface. The format string is already
  grep-compatible (both `thunderbolt-attached=` and
  `external/untrusted=` are unique strings). The slash convention
  mirrors the kernel's own external-facing / untrusted pairing.
  Default-reject for upstream-bound surface; bloat budget is high.

### E1-egpu-detection-I6 — Add `[A2-bus-loss-watchdog, A3-recovery]` to `related-patches:` frontmatter

- **Lens:** invariant clarity (downstream-consumer mapping)
- **Current state:** v2 intent + review both carry
  `related-patches: [C4-err-handlers-scaffold]`. The intent's
  Purpose (intent lines 36-39) names `[[C4-err-handlers-scaffold]]`,
  `[[A2-bus-loss-watchdog]]`, and `[[A3-recovery]]` as the
  downstream consumers of `is_external_gpu` ("the addon recovery
  stack [[A2-bus-loss-watchdog]] and [[A3-recovery]] gate on
  `is_external_gpu`"). The frontmatter list omits A2 and A3.
- **Proposed state:** Add `A2-bus-loss-watchdog` and `A3-recovery`
  to both intent and review `related-patches:` frontmatter lists.
- **Value:** Cross-patch consistency. The body-prose wikilinks
  already exist; the frontmatter list is the machine-readable
  contract.
- **Cost:** Frontmatter list edit + re-lint of intent. The Rule 6
  lint resolution requires the target intent files to exist:
  `docs/patch-intents/A2-bus-loss-watchdog.md` and
  `docs/patch-intents/A3-recovery.md` both exist at HEAD (per the
  manifest at `patches/manifest:25-26`). The v2 review's
  Design-choices section (review lines 374-385) explicitly
  deferred to Task 14: "Task 14's cross-patch consistency audit
  will revisit whether to backfill the frontmatter once the
  addon intents exist." The C4 catalog's I3
  (`/root/nvidia-driver-injector/docs/patch-improvements/C4-err-handlers-scaffold.md:448-490`)
  raised the same frontmatter gap for C4 and deferred to Task 14.
- **Verification mode:** A.
- **Intent impact:** refine frontmatter (`related-patches:`).
- **Triage decision:** defer.
- **Resolution:** deferred to Task 14's cross-patch surface audit
  (per the plan's "Cross-patch aggregation lands in Task 14" and
  the C4 catalog's identical deferral). The v2 review's
  deliberate choice (review lines 374-385) to defer
  frontmatter cross-refs to Task 14 is upheld. **Disposition for
  follow-up:** Task 14 cross-patch audit MUST add A2 and A3 to
  E1's `related-patches:` (intent + review) AND E1 to A2's and
  A3's `related-patches:` when reconciling. Catalog entry here
  ensures the finding is not lost between now and Task 14.

### E1-egpu-detection-I7 — Lift the "no community signal is itself a signal" finding into v2 review's Cross-references

- **Lens:** invariant clarity (silence-as-signal documentation, M5)
- **Current state:** v2 review's Cross-references and Rationale
  sections do not address why no community signal tags E1 — the
  TOSUKUi / rvn2p / jciolek / #916 / #1111 / #1132 / #1151 / #1159
  community-signal dataset misses eGPU-detection issues entirely.
  This silence is *itself* a finding: vanilla mis-classification
  is silent (the operator sees instability downstream, not a
  "detection failed" symptom), so community-signal recon cannot
  catch this class of bug.
- **Proposed state:** Add a one-paragraph note to v2 review's
  Cross-references (or a new "Community signal" sub-section)
  observing that the absence of community signal corroborates
  E1's status as a silent-misclassification fix not a
  symptom-driven fix.
- **Value:** Documents an audit-relevant methodological finding
  (M5 silence-as-signal) so a future reader understands why E1's
  evidence base differs from C2/C3/C4's (which all have
  TOSUKUi-citation corroboration).
- **Cost:** ~5 lines added to v2 review. Re-touches the review
  file. The finding is captured in this catalog entry (above) and
  in `_community-signal.md:128-131` — lifting it into the review
  duplicates content for marginal clarity gain. The catalog file
  IS the durable home for sub-cycle 3 triangulation findings; the
  review file is sub-cycle 2's home.
- **Verification mode:** A.
- **Intent impact:** none.
- **Triage decision:** reject.
- **Resolution:** rejected — the silence-as-signal finding is
  fully captured in **this catalog file** (Triangulation sources
  / Community-signal entries section + the framing observation
  that "vanilla detection misclassifies eGPUs silently"). The v2
  review's sub-cycle 2 scope did not require this M5 framing;
  re-touching it now to add the v3 framing duplicates content.
  Default-reject for catalog-as-durable-home discipline.

## Re-examination of sub-cycle 2 deferrals

- **`E1-egpu-detection-D1` (wrapper name is slightly narrower than
  its behaviour):** v2 disposition = deferred (kept v1's
  `os_pci_is_thunderbolt_attached` for kernel-symbol-name
  mirroring and review-surface-minimality). v3 disposition:
  **upheld with strengthened evidence**. Three new pieces of
  evidence (per I1 Resolution above) reinforce the deferral:
  (1) The kernel's own `untrusted` field comment
  (linux-v6.19 `include/linux/pci.h:467-473`) treats external-untrusted
  as a TB-overflow concept ("typically connected through external
  ports such as Thunderbolt but not limited to that") — the kernel
  itself does not have a separate name for the union;
  (2) The project's Lever U design
  (`docs/lever-catalog.md:759, :803, :835-845`) treats
  `pci_is_thunderbolt_attached()` as the canonical kernel helper for
  TB-aware NVIDIA driver behaviour and does not introduce a
  wider-named wrapper — consistent with E1's naming;
  (3) The upstream-PR review-surface argument from the v2 review
  (mirror the kernel symbol; block comment carries precision) is the
  stronger argument for an upstream-bound patch in the Core layer's
  bloat budget. Surfaced as I1; deferred (re-upheld).
- **`E1-egpu-detection-D2` (no must-fix deltas):** v2 disposition =
  rejected (no v2 follow-up needed). v3 disposition: **upheld**.
  M6 archaeology surfaces no new evidence that flips the
  disposition — all 7 I-candidates above triage to reject or
  defer. Zero-delta sentinel
  `v1-tip-sha == v2-tip-sha == 000ea7a51db8b78225950a753a390a82f3aa1d81`
  holds across sub-cycle 3.

## Improvements landed

(none — every candidate triaged `reject` or `defer`; v1 == v2 == v3
fork-branch tip.)

## Intent updates landed

(none — no candidate surfaced a substantive normative gap requiring
an intent precursor.)

## Done gate

- [x] Every candidate improvement has explicit `Resolution:` (no `pending`).
- [x] All "land" improvements applied as fork-branch commits citing their `<id>-I<N>` IDs. _(N/A — zero land-tier improvements.)_
- [x] Substantive intent updates landed as precursor commits. _(N/A — zero substantive intent updates.)_
- [x] `tools/intent-lint.sh` passes _(no intent change; lint re-verified after Step 11 catalog write)._
- [x] `tools/validate-patchset.sh` passes (compile gate against kernel 7.0.9-204.fc44.x86_64).
- [x] `bash tests/run.sh` green (34 ok, 0 failed).
- [x] Audit-reviewer subagent approved (sub-cycle 3 audit-reviewer, ✅ APPROVED WITH NOTES — all 10 spot-checked citations verbatim-verified; all 7 triages concurred; D1 naming-concern upheld with 3 strengthening signals; gates re-ran green; catalog length 899 lines justified by depth of design-doc archaeology in absence of direct aorus ancestor. Two non-blocking cosmetic nits flagged and left as-is: (a) `pci.h:467-473` is actually 467-471, (b) "five sites" in catalog vs "four places" in aorus `source-review-notes.md:23-33` reflects later Pass-3+ enumeration; both are pure-prose with zero bearing on triage outcomes or upstream-PR rationale).

## Methodology notes for the audit-reviewer

- **M1+M2 actually-consulted vs binding.** Binding named
  `tb4-pcie-topology.md`, `source-review-notes.md`, and
  `pcie-kernel-cmdline-options.md`. **Dropped
  `pcie-kernel-cmdline-options.md`** — that document feeds Lever T
  archaeology (the IOMMU kernel cmdline workaround), not E1's
  in-driver detection. No E1-relevant content. **Kept
  `tb4-pcie-topology.md:1-50, 51-67`** (hardware topology + Barlow
  Ridge VSEC evidence) and **`source-review-notes.md:23-33,
  160-170, 245-255, 700-710, 1400-1405`** (Pass 1 penetration
  analysis + Lever A usage + canonical detection-code-surface
  pointer). **Added (not in binding):**
  `freeze-investigation-plan.md:120-128, 270-280` (Lever A
  negative-result + first awareness of in-driver fix as the
  target), `tb-pcie-cap-architecture.md:62-67, 90-100`
  (helper-as-canonical-layer evidence),
  `iommu-gsp-lockdown-analysis.md:65-75, 255-265` (untrusted=1
  empirical signal), `lever-catalog.md:485-510, 755-810, 835-845`
  (Lever T + Lever U cross-references — Lever U is the canonical
  project-internal `pci_is_thunderbolt_attached` use),
  `reliability-hypothesis-ledger.md:155-170` (H10 empirical signal
  for the second-signal `untrusted`),
  `architecture-and-modularity.md:62-100` (L1 sovereignty
  grounding), and the project's own
  `docs/upstream-plan.md:268-303` (canonical E1 target-state).
- **M1+M2 ancestor finding.** **No direct aorus ancestor patch
  exists** — the aorus geometry used a cmdline workaround
  (`RmForceExternalGpu=1` in modprobe.d) instead of an in-driver
  fix. The grep
  `ls /root/aorus-5090-egpu/patches/ | xargs grep -l -iE
  'is_external_gpu|RmCheckForExternalGpu|RmForceExternalGpu|is_thunderbolt'`
  returned empty (all 30 aorus patches predate the in-driver
  detection effort). Pivoted to design-doc archaeology per the
  task brief — the project's design intent for an in-driver fix
  is documented across freeze-investigation-plan, source-review-notes,
  tb4-pcie-topology, tb-pcie-cap-architecture, iommu-gsp-lockdown-analysis,
  lever-catalog (Lever A as workaround + Lever U as canonical
  helper-use precedent), reliability-hypothesis-ledger (H10
  empirical signal), and upstream-plan §E1 (project canonical
  target-state).
- **M5 community-signal discipline (silence-as-signal).** Community
  signal recon (`_community-signal.md:128-131`) explicitly tagged
  E1 as having **NO findings**. Per M5 framing, this is
  silence-as-signal: vanilla mis-classification is silent (the
  operator observes downstream instability, not a "detection
  failed" symptom), so community-signal recon cannot detect this
  class of bug. The hardware-verification claim at
  `docs/upstream-plan.md:288-291` ("on the project's Barlow Ridge
  / Thunderbolt 5 hardware, `pci_is_thunderbolt_attached()` returns
  true; `untrusted` is the endpoint-local union member") is the
  PROJECT-INTERNAL empirical evidence that substitutes for
  community-signal corroboration on this patch. Distinct from
  C2/C3/C4's evidence pattern (all of which have TOSUKUi or #916
  symptom corroboration); E1 stands on hardware-verification +
  kernel-source-reading, not symptom-grep.
- **M6 deferral re-examination.** Both v2 deltas (D1 wrapper-name
  nice-to-have + D2 no-must-fix) re-examined explicitly. D1
  upheld with three new strengthening signals (kernel-side
  treatment of `untrusted`, project-internal Lever U precedent,
  upstream-PR review-surface argument); D2 upheld with no flips
  in the 7 v3 I-candidates.
- **M7 line ranges.** All v1-archaeology citations use line
  ranges (5-line windows preferred, larger when documenting
  multi-section design choices).
- **M8 `.regen-state` restore.** N/A — zero code commits landed
  for E1; no `.regen-state` advance needed.
- **Meta-finding on naming (cross-patch carry-over).** The naming
  decision (`os_pci_is_thunderbolt_attached` vs renaming) cascades
  to any addon patch that consumes the wrapper. **No addon
  consumes it** — A2/A3/A4 consume the *cached*
  `nv_state_t::is_external_gpu` boolean, not the wrapper. The
  call site count is one (`osinit.c:471`). The cross-patch impact
  of a rename would be minimal (5 source sites total) but the
  upstream-PR-review symmetry concern stands. Task 14 cross-patch
  audit need not revisit this decision unless the upstream
  reviewer surfaces the naming concern.
- **Meta-finding on no-conftest decision.** The two kernel APIs
  E1 uses (`pci_is_thunderbolt_attached` since v4.18,
  `pdev->untrusted` since v4.20) are well above the build target
  floor and well above the modern NVIDIA open-driver
  minimum-kernel floor (in practice v5.0+). No conftest shims
  needed for this sub-cycle's gate. I4 carries the
  upstream-PR-time concern as a follow-up; not a sub-cycle 3
  deliverable.

## Cross-references

- Intent file: `docs/patch-intents/E1-egpu-detection.md`
- Review file: `docs/patch-reviews/E1-egpu-detection.md`
- Manifest row: `patches/manifest` line for `E1-egpu-detection`
  (layer `base`, source `fork:e1-egpu-detection`)
- Vanilla baseline: `src/nvidia/arch/nvalloc/unix/src/osinit.c:RmCheckForExternalGpu`
  (vanilla 595.71.05 walks the bus topology via `clFindP2PBrdg`,
  dispatches `NV2080_CTRL_CMD_INTERNAL_GET_EGPU_BRIDGE_INFO` with
  `rmGpuLocksAcquire`/`Release` around the lookup, requires
  `approvedBusType == NV2080_CTRL_INTERNAL_EGPU_BUS_TYPE_TB3` +
  hot-plug-surprise slot capability; +~95 lines).
  Companion vanilla baselines: `kernel-open/nvidia/os-pci.c`
  (vanilla `os_pci_remove` at lines 145-149 is the insertion
  anchor) + `kernel-open/common/inc/os-interface.h:108-111` +
  `src/nvidia/arch/nvalloc/unix/include/os-interface.h:108-111`.
- Kernel reference: `/root/linux-v6.19/include/linux/pci.h:2798-2817`
  (`pci_is_thunderbolt_attached` static inline definition);
  `/root/linux-v6.19/include/linux/pci.h:465-479` (`is_thunderbolt:1`,
  `untrusted:1`, `external_facing:1` bit fields and the kernel's
  own comment on `untrusted` semantics);
  `/root/linux-v6.19/drivers/pci/probe.c:1738-1757`
  (`set_pcie_untrusted` — the kernel function that establishes the
  endpoint-local form of the external-facing marker via parent
  propagation OR `arch_pci_dev_is_removable(dev)`).
- Fork branch: `e1-egpu-detection` on
  `apnex/open-gpu-kernel-modules` (v1-tip == v2-tip ==
  `000ea7a51db8b78225950a753a390a82f3aa1d81` — zero-delta
  sentinel; built on top of `c4-err-handlers-scaffold`).
- aorus-5090 ancestor: **NONE** — no direct in-driver patch
  ancestor. The aorus geometry used the modprobe.d cmdline
  workaround
  `NVreg_RegistryDwords="RmForceExternalGpu=1"`
  (`scripts/host-files/etc/modprobe.d/nvidia-driver-injector.conf:54-55`).
- aorus-5090 docs:
  `/root/aorus-5090-egpu/docs/freeze-investigation-plan.md:120-128`
  (Lever A negative result — cmdline workaround applied 2026-05-02);
  `/root/aorus-5090-egpu/docs/freeze-investigation-plan.md:270-280`
  (Lever E first awareness — in-driver fix is the target);
  `/root/aorus-5090-egpu/docs/source-review-notes.md:23-33`
  (Pass 1 penetration analysis — `is_external_gpu` 5-site
  consumer footprint);
  `/root/aorus-5090-egpu/docs/source-review-notes.md:160-170,
  245-255, 700-710` (Lever A workaround mechanism + dependency
  chain);
  `/root/aorus-5090-egpu/docs/source-review-notes.md:1400-1405`
  (canonical detection-code-surface pointer `osinit.c:425-528`);
  `/root/aorus-5090-egpu/docs/tb4-pcie-topology.md:1-50, 51-67`
  (hardware topology — Intel TB4 → Barlow Ridge → RTX 5090; key
  insight: lspci LnkCap on TB-tunnelled bridges is virtualised);
  `/root/aorus-5090-egpu/docs/tb-pcie-cap-architecture.md:62-67,
  90-100` (helper-as-canonical-layer evidence —
  `pci_is_thunderbolt_attached` is upstream kernel API);
  `/root/aorus-5090-egpu/docs/iommu-gsp-lockdown-analysis.md:65-75,
  255-265` (untrusted=1 empirical signal on production hardware);
  `/root/aorus-5090-egpu/docs/lever-catalog.md:485-510`
  (Lever T — IOMMU disable cmdline workaround, cross-references
  the `untrusted=1` signal);
  `/root/aorus-5090-egpu/docs/lever-catalog.md:755-810, 835-845`
  (Lever U mechanism + upstream-readiness assessment — the
  canonical project-internal `pci_is_thunderbolt_attached()` use);
  `/root/aorus-5090-egpu/docs/reliability-hypothesis-ledger.md:155-170`
  (H10 empirical signal for the second-signal `untrusted`);
  `/root/aorus-5090-egpu/docs/architecture-and-modularity.md:62-100`
  (L1 sovereignty grounding — why detection logic lives in the
  fork).
- Project canonical: `/root/nvidia-driver-injector/docs/upstream-plan.md:268-303`
  (E1 — Modernise eGPU detection: mechanism, rationale,
  hardware-verification, retirement-of-workaround).
- Project workaround being retired (post-soak): `/root/nvidia-driver-injector/scripts/host-files/etc/modprobe.d/nvidia-driver-injector.conf:54-55`
  (`NVreg_RegistryDwords="RmForceExternalGpu=1"` — kept until
  production cutover gate per the C+E+A operating model).
- Upstream issue: <https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979>
  — Blackwell GPU over Thunderbolt commits permanent lost state
  on transient PCIe failures. E1 is not the headline fix (that
  is [[C3-gpu-lost-retry]]) but is the **classification
  prerequisite** without which eGPU-specific behaviour
  (`is_external_gpu`-gated paths inside `osHandleGpuLost`,
  `kern_perf.c`, `subdevice_ctrl_gpu_kernel.c`, and `nv-pci.c`)
  is gated out on modern hardware.
- Upstream PR precedent: PR #981 (closed unmerged January 2026) —
  the project's first awareness that someone else upstream was
  also working on this; the closed PR has no maintainer review
  to triangulate against. Project memory:
  `project_issue_979_upstream_state_2026_05_22`.
- Community signal: `/root/nvidia-driver-injector/docs/patch-improvements/_community-signal.md:128-131`
  ("No findings tagged for ... `E1` (eGPU detection)"). Per M5
  silence-as-signal: vanilla mis-classification is silent;
  community-signal recon cannot detect this class. E1 stands on
  hardware-verification + kernel-source-reading, not symptom-grep.
- Related reviews: [[C4-err-handlers-scaffold]] (the registered
  `pci_error_handlers` table whose callbacks may eventually key
  per-device behaviour on `is_external_gpu` — frontmatter-resolved);
  [[A2-bus-loss-watchdog]] (gates on `is_external_gpu` per
  `docs/upstream-plan.md §E1` — frontmatter deferred to Task 14
  per I6); [[A3-recovery]] (gates on `is_external_gpu` per
  `docs/upstream-plan.md §E1` — frontmatter deferred to Task 14
  per I6); [[C5-crash-safety]] (de-branded primitives, body-prose
  wikilink only).
- Project memory: `project_nvidia_open_driver_egpu_layer_tb3_era`
  (documents the original TB3-era detection and the historical
  `RmForceExternalGpu=1` workaround the project drops once a
  running driver carries E1); `project_cea_patch_geometry_2026_05_22`
  (E1 classification as `E` — upstream-bound, eGPU-specific, a
  bug fix to vanilla NVIDIA code).
