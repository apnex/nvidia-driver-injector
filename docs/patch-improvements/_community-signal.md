---
generated: 2026-05-23
scope: NVIDIA/open-gpu-kernel-modules issues #979 + #981 + related; upstream commits 2026-05-02 → 2026-05-23
reviewer: Claude Opus 4.7
---

# Community signal — sub-cycle 3 pre-pilot reconnaissance

## #979 activity since 2026-05-02

Issue: <https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979>
State: **OPEN**, labels: `bug`, last updated `2026-05-22T01:16:04Z` (the apnex outreach itself).

Four comments in window (one of them ours):

### 1. TOSUKUi, 2026-05-02 — engineering signal
- Comment: <https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979#issuecomment-IC_kwDOHRZU288AAAABBBJ35w>
- Hardware: RTX PRO 6000 Blackwell via MINISFORUM DEG2 (USB4), AMD-host (GMKTEC NucBox M6), `8086:5786` Barlow Ridge bridges.
- Reproducer: minimal PyTorch `torch.empty(...)` → host hard-lock/reboot on **first** real CUDA allocation. `nvidia-smi` works at idle.
- Logs: `AER: Uncorrectable (Non-Fatal)` from GPU `0000:07:00.0`, then `AER: can't recover (no error_detected callback)` on both GPU functions, `pcieport ... device recovery failed`.
- **Engineering signal**: independent confirmation that (a) the failure trigger is the first CUDA memory-allocation path (DMA setup), not driver probe or NVML; (b) the open driver registers **no** `pci_error_handlers` — same gap our patches close; (c) the AER-recovery-fails path applies on AMD-host USB4 too, not just Intel TB4.
- **Tags**: `C4` (err_handlers scaffold — directly evidenced by "no error_detected callback"), `C2` (AER unmask — TLP errors visible here), `C5` (crash-safety — the hard-lock is the GPU-lost crash class), `A2/A3` (silent-DMA-path freeze + recovery).

### 2. jciolek, 2026-05-03 — partial signal
- Comment: <https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979#issuecomment-IC_kwDOHRZU288AAAABBFEPrQ>
- Aorus 5090 owner who **isolates the issue to software** by dual-booting Windows 11 + WSL2 and running qwen3.6:35b through ollama with no failure. Then confirms kernel 7.0 + nvidia-open-dkms 595.71.05 on Manjaro still crashes.
- **Engineering signal**: rules out hardware-broken hypothesis (one of the user's standing constraints — `feedback_dont_conflate_stack_failure_with_hardware_broken`); confirms 7.0 + 595.71.05 still reproduces vanilla (which is the exact baseline our 595.71.05-aorus.13 patch set targets).
- **Tags**: scope-level confirmation that all 11 patches are still needed against current upstream; no specific patch implication.

### 3. rvn2p, 2026-05-12 — third-party validation
- Comment: <https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979#issuecomment-IC_kwDOHRZU288AAAABCA0pAg>
- Running the apnex/aorus-5090-egpu repo (the *frozen* geometry) on Debian sid. Adapted some paths from Fedora; reports it **runs stable**.
- **Engineering signal**: independent third-party validation of the same patch set on a different distro. Distinct host, distinct kernel package layout — patches port. Calls it "a good temporary workaround… no long-term replacement for a fixed driver" — matches our framing.
- **Tags**: cross-distro portability concern for all C/E patches. May surface paths/Kbuild assumptions in `C1` (build-metadata) when we triangulate; otherwise patch-agnostic.

### 4. apnex, 2026-05-22 — the outreach (our own)
- Comment: <https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979#issuecomment-4514103926>
- Announces patched build + both repos. No follow-on engineering content from elsewhere — this is the anchor we're watching for reactions to (see "Direct responses" section).

## #981 (closed PR) activity since 2026-05-02

PR: <https://github.com/NVIDIA/open-gpu-kernel-modules/pull/981>
Title: *Improve Thunderbolt eGPU detection and stability*
State: **CLOSED** (closed `2025-12-08T03:03:46Z`, never merged), last updated `2026-01-06T17:52:18Z`, no labels.

**No comments in window.** PR has been dormant since January. Confirms project memory `project_issue_979_upstream_state_2026_05_22.md`.

## Related open issues (2026-05-02 → today)

Filtered from Blackwell/Thunderbolt/eGPU/AER searches. Skipped clearly-unrelated (suspend regressions specific to jump_label kernel BUG, gaming Xid-109/Proton timeouts unrelated to bus-loss).

### Bus-loss / GPU-lost class

#### #916 — *GPU lost from the bus … Zotac RTX 4090* (OPEN, opened 2025-08-10, updated 2026-05-20)
- URL: <https://github.com/NVIDIA/open-gpu-kernel-modules/issues/916>
- New comment 2026-05-20 from `sebjohansen04-cpu`: Palit 3090 hitting `NV_ERR_GPU_IS_LOST 0x0000000f` even at 11W idle — **not** an eGPU, **not** Blackwell, but the same `NV_ERR_GPU_IS_LOST` symptom (Ada + Ampere generalisation).
- **Relevance**: confirms GPU-lost code path is hit on non-Blackwell, non-TB hardware too → strengthens upstream case for `C3` (gpu-lost-retry) as a general-purpose hardening, not Blackwell/eGPU-only.
- **Tags**: `C3` (gpu-lost-retry — broader applicability evidence), `C5` (crash-safety class).

#### #1151 — *RTX 5080 (GB203): Random Xid 79 … instant atomic GPU death* (OPEN, 2026-05-18)
- URL: <https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1151>
- Vanilla 595.71.05; Bazzite; not eGPU. Xid 79 = GPU off the bus.
- **Relevance**: same symptom class but unclear if same root cause (no precursor errors, "any load level"). Worth a one-liner cross-reference in `C3`/`C5` triangulation but no patch derivation.
- **Tags**: `C3`, `C5` (symptom-adjacent only).

### Mode-B / DMA-path freeze class

#### #1132 — *RTX 5070: `__nv_drm_gem_nvkms_map` BAR1→BAR3 mapping … krcWatchdog GPU lock* (OPEN, 2026-05-05)
- URL: <https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1132>
- 595.71.05 open driver; Fedora 44; kernel 6.19; Resizable BAR disabled. `mapping_reuse.c:273 NV_ERR_NO_MEMORY` then `krcWatchdog` lock.
- **Relevance**: distinct mechanism (BAR1/BAR3 boundary-spanning DMA mapping) but lands in the **same Mode-B silent-freeze symptom space** our `A2` watchdog catches. Not a root-cause for our case (we have rBAR enabled), but worth a footnote in `A2` triangulation: krcWatchdog is the in-driver watchdog NVIDIA already ships — our Q-watchdog runs at 5 Hz at the kernel-module layer above it and catches what krcWatchdog misses on TB-tunnelled paths.
- **Tags**: `A2` (bus-loss-watchdog — comparable layer evidence).

#### #1111 — *GSP firmware halt on sm_120 … sustained zero-gap llama.cpp inference — silent hard hang* (OPEN, 2026-04-17, updated 2026-05-14)
- URL: <https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1111>
- RTX PRO 6000 Blackwell, vanilla 595.71.05 (Fedora 44, kernel 6.18 stable). Sustained llama.cpp inference; silent hard hang, **no Xid, no AER, dmesg silent**.
- **Relevance**: **strongest single match** for the Mode-B class our `A2` watchdog targets — "silent freeze with nothing in dmesg" is the exact failure-mode signature.
- **Tags**: `A2` (high — same symptom signature, GSP halt suggests adjacent surface to our Q-watchdog detection).

#### #1159 — *RTX PRO 6000 Blackwell: Xid 8 / GSP watchdog timeout under sustained SGLang FP8 inference* (OPEN, 2026-05-22)
- URL: <https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1159>
- Vanilla 595.71.05 open; Ubuntu 24.04 kernel 6.17; PCIe-attached (not eGPU). Sustained FP8 LLM inference → unrecoverable GPU state.
- **Relevance**: Xid 8 + GSP watchdog timeout — adjacent to GSP-LOCKDOWN cascade our `A3` recovery handles, but on PCIe-attached card.
- **Tags**: `A3` (recovery — GSP timeout class).

### Out of scope (noted but not tagged)

- **#1117** (RTX 50-series s2idle resume hangs on kernel 7.0) — **jump_label kernel BUG**, not bus-loss. Multiple confirmations 2026-05-02 → 17 (undera, KaysonSear, willbeason). NOT our patch surface. Pointer: workaround tracked in #1095. Noted only to disambiguate from our 7.0-vs-6.19 success path (`project_kernel_6_19_to_7_0_source_review`).
- **#1064** (GSP heartbeat stuck at 0 with S0ix, RTX PRO 1000 Blackwell laptop) — S0ix-specific, laptop power management. Not our class.
- **#1160** (Lenovo LOQ S4 hibernation, `pci_pm_freeze -5`) — hibernation, not our class.

## NVIDIA upstream activity (commits touching our patched files)

All six queries returned **empty** (no commits in window).

### kernel-open/nvidia/os-mlock.c
No commits in window.

### kernel-open/nvidia/nv-pci.c
No commits in window.

### kernel-open/nvidia/os-pci.c
No commits in window.

### kernel-open/nvidia/os.c
No commits in window.

### kernel-open/Kbuild
No commits in window.

### src/nvidia/arch/nvalloc/unix/src/osinit.c
No commits in window.

**Conflict assessment**: zero upstream conflicts on patched-file surface in window. The 595.71.05 tag remains the working upstream baseline.

## Direct responses to apnex outreach (comment-4514103926, 2026-05-22)

- Reactions endpoint `/repos/NVIDIA/open-gpu-kernel-modules/issues/comments/4514103926/reactions` → `[]` (empty).
- No reply comments on #979 after `2026-05-22T01:16:04Z`.
- Issue `updatedAt = 2026-05-22T01:16:04Z` = the outreach comment's own timestamp → no subsequent activity of any kind.

**Status**: 0 reactions, 0 replies, 0 cross-references in ~24 hours. (Outreach posted very recently; absence of immediate reaction is uninformative.)

## Summary

- **Material findings**: 5 — TOSUKUi independent confirmation (high signal); rvn2p cross-distro validation; jciolek hardware-not-broken confirmation on 7.0+595.71.05; #1111 silent-hard-hang match for `A2`; #1132 BAR1/BAR3 + krcWatchdog reference for `A2`.
- **By bug-class adjacency**:
  - `C3` (gpu-lost-retry): #916 (broader applicability beyond eGPU/Blackwell).
  - `C2` (AER unmask): TOSUKUi #979 (AER signal demoted/missed).
  - `C4` (err_handlers scaffold): TOSUKUi #979 (verbatim "no error_detected callback" symptom).
  - `C5` (crash-safety): TOSUKUi #979, #916, #1151.
  - `A2` (bus-loss-watchdog): #1111 (silent hard hang signature), #1132 (krcWatchdog layer comparison).
  - `A3` (recovery): #1159 (Xid 8 + GSP watchdog timeout).
  - Patch-agnostic / scope-level: jciolek #979 (software-not-hardware), rvn2p #979 (cross-distro portability).
  - No findings tagged for: `C1` (Kbuild/version.mk), `E1` (eGPU detection), `A1` (PCIe primitives), `A4` (close-path telemetry), `A5` (version/toggles).
- **Conflict-detection**: **0** upstream commits in window touch the 6 patched files. No rebase risk introduced.
- **Notable absences (silence-as-signal)**:
  - **Zero NVIDIA maintainer presence in #979 over the last 3 weeks** (or anywhere in the 11-author comment thread). Issue is 5.5 months old, label still bare `bug`, no triage updates. Reinforces `project_issue_979_upstream_state_2026_05_22.md`: upstream is not engaged on this.
  - **#981 dormant since January 2026**; PR closed unmerged with no reopen and no maintainer follow-up.
  - **No replies/reactions to apnex outreach within ~24 h**; uninformative due to recency but flag for revisit on subsequent recon sweeps.
  - **No upstream code motion** on any of the 6 patched files in 3 weeks — surface is stable enough that improvement work won't be undermined by rebase churn.
