# Issue #979 — OPEN-arm root-cause characterization (DRAFT — NOT POSTED)

**Status:** DRAFT. Banked 2026-05-30 from #282 Lane 1 (chip-free). **Not posted to GitHub.** Posting/filing remains gated by the project rule (no upstream filing without a tested fix; this is *forensic characterization*, and the site is not yet pinned — Lane 2 Rung 4 firms it up). This doc is the open-arm forensic record + the seed for a future #979 comment.

**Relation to existing #979 outreach:** an outreach comment was already posted 2026-05-22 (apnex, announcing the patched build + repos). This would be a *follow-up forensics* comment once the site is confirmed.

---

## TL;DR (the postable core, pending Lane 2 site-confirmation)

On a **userspace-recovered** Blackwell eGPU over Thunderbolt 4 (RTX 5090 / GB202, driver 595.71.05 open) — i.e. after a destructive driver uninstall + TB re-enumeration + BAR1 restore, then a fresh `modprobe` and a second open — the **second `RmInitAdapter` loses the GPU inside GSP init and the host frequently hard-locks**:

1. cycle-2 `RmInitAdapter → kgspInitRm → kgspBootstrap_GH100 → kgspWaitForRmInitDone → rpcRecvPoll(GSP_INIT_DONE)` returns **`NV_ERR_GPU_IS_LOST`** — the chip stops completing the polled MMIO read of the GSP mailbox/heartbeat.
2. that polled read **PCIe-Completion-Timeouts** → AER **`UESta=0x00004000`** (Completion Timeout, bit 14) on the device.
3. the host **usually hard-locks** before AER/recovery can run (an AER-vs-kernel-deadlock race the CPU loses ~11/12 of the time), requiring a reboot.
4. on any **retry**, `_kgspBootGspRm` finds **WPR2 already up** (`unexpected WPR2 already up, cannot proceed`) and `rm_init_adapter failed` — a *downstream* symptom of the cycle-2 GPU-loss, not an independent fault.

**Same RPC-poll mechanism as the (healthy) unload path, opposite outcome.** The driver's *RM-unload* RPC over the identical `_issueRpcAndWait → _kgspRpcRecvPoll` path completes in ~600 ms on the same chip (see SH-2 below). The *init* RPC on a recovered chip never gets its reply. This strongly localizes the root cause to **GSP-firmware-side init non-completion on a re-enumerated chip**, not a host driver defect.

**The ask for NVIDIA:** the GSP init handshake (`kgspWaitForRmInitDone` / `_kgspRpcRecvPoll`) should **fail-fast / bound** when the chip is not completing, and surface a clean error — rather than leave the driver polling a chip-touching MMIO that the host then Completion-Timeouts and hard-locks on. (Host-side, we bound it ourselves — see "host-side vs NVIDIA-side" — but the firmware/RM owns the actual init-completion path.)

---

## Ground-truth evidence (directly observed, chip-free)

### 1. The `verify-wedge` journal — the one capture that survived the trigger
Of the 2026-05-29 open-arm wedge reproductions, **5 of 6 froze before journald flushed** (host hard-locked mid-trigger). `verify-wedge-2026-05-29` is the **sole** boot whose kernel journal captured the wedge sequence, and it shows, in order:
- cycle-2 **`NV_ERR_GPU_IS_LOST`** surfacing at the **`GSP_INIT_DONE`** RPC;
- retry → **`unexpected WPR2 already up, cannot proceed with booting GSP`** → `the GPU is likely in a bad state and may need to be reset` → `Cannot initialize GSP firmware RM` → **`rm_init_adapter failed`** (×2 cycles).

This is the strongest single piece of open-arm evidence and is what reclassifies WPR2-stuck as a **sequela** of the init-RPC GPU-loss (it refines our earlier 2026-05-06 WPR2 model: the "unrelated reason GSP boot fails first" **is** the init-RPC loss).

### 2. SH-2 PMU mechanism (kprobe-free, on the closed RM under IBT)
The closed RM (`nv-kernel.o`, 0 `endbr64`) is **not kprobe-able** on `CONFIG_X86_KERNEL_IBT=y`; **PMU sampling** (`bpftrace profile:hz`) is. SH-2 captured both arms in one trace:
- **unload (healthy):** `rm_shutdown_adapter → kgspUnloadRm_IMPL → _issueRpcAndWait → _kgspRpcRecvPoll` — GSP replies in ~600 ms.
- **init (same trace):** `kgspBootstrap_GH100 → kgspWaitForRmInitDone_IMPL → _kgspRpcRecvPoll → _issueRpcAndWait` — **identical poll mechanism.**

### 3. AER signature
Test B v2 directly observed device **`UESta=0x00004000`** (PCIe Completion Timeout) at the cycle-2 `nv_open_device_for_nvlfp` / RmInitAdapter MMIO site (the D0/sub-5s-gap site).

### 4. Alternatives eliminated chip-free (so the above is not a confound)
| Ruled out as sole cause | Evidence |
|---|---|
| GSP firmware missing/mismatched | both `gsp_*.bin` are real, version-matched files; no `firmware load error`; `nvidia-kmod-common` regression absent |
| IOMMU/DMAR DMA rejection | `iommu=off` confirmed live; **zero** DMAR faults in any wedge journal; wedge reproduced anyway |
| Gen3 signal-integrity link fault | Gen2+bit5 cap live; wedge reproduced n=13; the single real AER is a *consequence*, not a precursor |
| Surprise-removal / Xid cascade | **Xid == 0** in every wedge journal (no Xid 79/154); a clean, Xid-free deadlock class, distinct from cable-yank removal |

---

## Host-side vs NVIDIA-side (the two layers)

- **NVIDIA-side (root cause, this report):** *why* the GSP fails to boot/reply on a userspace-recovered chip — owned by GSP firmware / the TB-tunnel / silicon state. The init RPC's unbounded chip-touching poll is the surface the host hard-locks on.
- **Host-side (already fixed in this project, the #979 *symptom*):** the driver turning that chip silence into a permanent host hard-lock. Addressed by `C3` (retry a transient bus read before declaring the GPU lost), `C4` (register `pci_error_handlers`), `C5` (crash-safety — don't operate on an already-lost GPU), and the project-local `A6` bounded-wait around the open path (deterministic `-EIO`, host survives). These bound the *over-reaction*; they do not, and cannot, fix the firmware-side init-completion.

---

## Confidence & caveats (do not overclaim — these gate posting)

- **n=1 surviving journal** for the `GPU_IS_LOST`-at-`GSP_INIT_DONE` line (the other 5 froze pre-flush). It is corroborated by the SH-2 mechanism + the Test-B-v2 AER, but the *direct* journal evidence is a single boot.
- **The exact wedge SITE is not yet pinned.** Three candidates remain (the GSP init RPC poll; an *early* RmInitAdapter sanity-check MMIO — the `0x110094 == 0xbadf2100` sentinel seen in 4/5 boots, *before* any GSP RPC; and a BAR-mapping CTO). They share the same AER signature; **Lane 2 Rung 4 (PMU stack of the contained fire) resolves which.** Hold the "init RPC poll" claim as *supported*, not *confirmed*, until then.
- **Two distinct sites by idle-gap regime.** A >5 s idle gap (chip → D3hot) produces a *second*, currently-**uncharacterized** wedge **before** `nv_open_device` is even entered (and runtime-PM-resume as its cause was *falsified* by a `power/control=on` differential). The TL;DR above describes the **D0 / sub-5s-gap** site only.
- **BAR0 mailbox/heartbeat register offsets** (the exact regs the poll reads) are not yet extracted — deferred; `PMU *(reg)` at a sample would yield them.
- AER-win rate (~1/12) is **confounded by instrumentation** (heavy bpftrace gave the scheduler the slack that let AER win once); the unperturbed rate is unmeasured.

---

## What firms this up before posting
- **Lane 2 Rung 4** — confirm the pinned PMU frame is `_kgspRpcRecvPoll`-via-`kgspWaitForRmInitDone` (vs the early sanity-check frame) on the D0 site.
- **Lane 2 Rung 6** — extract the BAR0 poll-register offset for a concrete upstream pointer.
- **Lane 3 Rung 8** — characterize the second (>5s-gap) site and the deadlock-vs-CTO question.

## Cross-refs
`open-arm-forensics-ledger.md` (full design + Lane 1 results) · `experiments/SH-2-eBPF-register-identity.md` (PMU mechanism) · `docs/upstream-plan.md` (the C/E/A patch-PR plan; this doc is the *forensic* companion) · NVIDIA issue #979.
