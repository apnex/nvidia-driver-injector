# SH-1 — rm_shutdown_adapter latency + poll-vs-block + stuck-register proxy @ 10 s, close-path

**Status:** READY (exhaustiveness gate (b) passed 2026-05-30 — see `shutdown-hang-ledger.md`)
**Series:** Shutdown-Hang (SH); first root-cause experiment
**Risk:** MEDIUM (during-hang GPU-targeted MMIO reads can stall the reader; host-wedge → reboot)
**Cost:** ~10 s active hang/pass × n≥3, + setup; thermal-bounded
**Reversibility:** the leaked worker self-exits post-sink-set (close path keeps module loaded — no rmmod-unload UAF). Host wedge → reboot.
**Single variable:** `NVreg_TbEgpuShutdownTimeoutMs = 10000` (vs prod 200 ms). Nothing else changes.

## Hypothesis

Primary **H-SH1** (leading): `rm_shutdown_adapter` busy-polls a GSP handshake register for a state transition that never occurs on TB-eGPU teardown — chip alive and answering MMIO, but the awaited bit never flips. Also resolves **H-SH2** (budget-too-tight), **H-SH3** (blocked-read/MMIO-dead), **H-SH4** (which register, via TLP-address proxy), **H-SH6** (WPR2 timeline).

## The model discrimination (observable-now; corrected 2026-05-30)

A4-vs-A7 reconciled: A4's `post-shutdown` WPR2=0 is a **post-timeout after-sample** (fires after A7's bounded return), NOT proof of graceful completion. WPR2 clears **early** in `rm_shutdown_adapter`, before the stuck MMIO ⇒ the hang is a **late-stage stall**.

> **TOOLING CORRECTION (pre-fire, 2026-05-30):** the during-hang BAR0 reads (PMC_BOOT_0, WPR2) that (b) billed as the centerpiece are **NOT observable-now**. `resource0` mmap → EINVAL (driver holds BAR0, `IORESOURCE_BUSY` in /proc/iomem: `80000000-83ffffff : nvidia`); `/dev/mem` → EPERM (`CONFIG_IO_STRICT_DEVMEM=y`). No userspace BAR0 path exists while the driver holds the BAR. The during-WPR2 was **confirmatory, not load-bearing** — the three models separate on metrics we CAN capture, with the **kernel AER counter delta as the chip-alive proxy** replacing the blocked PMC read:

| Model | latency | worker CPU/state | **kernel AER Δ (CmpltTO)** | ⇒ Mechanism |
|---|---|---|---|---|
| **A — late-stall (H-SH1, leading)** | never (10 s) | **pegged** (R, utime↑) | **0** | busy-poll a LIVE chip — reads succeed ⇒ no completion-timeout ⇒ no AER |
| **B — slow-but-progressing (H-SH2)** | **completes ~1–3 s** | pegged → exits | 0 | budget too tight; teardown progresses |
| **C — MMIO-dead (H-SH3)** | never (10 s) | **D-state** (~0 CPU) | **>0** + TLP addr | blocked on a non-returning MMIO ⇒ CTO latches |

Alive-proxy logic: a busy-poll of a live chip issues MMIO reads that SUCCEED → no CTO → AER stays 0 (Model A); a dead chip's reads time out → CmpltTO latches + Header Log gives the TLP address (Model C). `{latency, worker-CPU-state, AER-Δ}` — all capturable from journal + /proc + setpci/sysfs — discriminate A/B/C.

The bridge **AER Header Log TLP address** (latched on CmpltTO) is the passive proxy for *which* register stalled (Model C only). The during-hang WPR2 and the exact polled offset move to **SH-2 (eBPF on `osDevReadReg032`)** — which we'd run anyway for register identity. The open layer knows only BAR0 offsets `0`=PMC_BOOT_0, `0x88a828`=WPR2; the polled register is invisible to it.

## Trigger (close-path, not rmmod)

Load **no-persistence** → `open()+close()` `/dev/nvidia0` → `nv_stop_device` (non-persistent branch, nv.c:2393) → `nv_shutdown_adapter` → A7 wraps `rm_disable_adapter` (completes) then `rm_shutdown_adapter` (hangs). Module stays loaded ⇒ no rmmod-unload UAF (H-SH5 deferred), repeatable n≥3 in one boot. (Persistent branch nv.c:2388 would skip `nv_shutdown_adapter` entirely — that's why no-persistence.)

## Capture plan (the additive contract — every observable-now metric)

**Pre-hang baseline (all passive, bridge/sysfs):**
1. `cat /sys/module/nvidia/version` (confirm aorus.21 + re-confirm kallsyms addrs shift per build); A8 `tb_egpu_f40b_fires`/`tb_egpu_state`.
2. DPC absent chain-wide — record dead-metric (cap 0x001d absent on 04:00.0/03:00.0/02:00.0/00:07.0).
3. `04:00.0` DevCtl2 CTO window (`50us–50ms`; A7 200 ms = 4× ceiling) + DevSta/UESta/CESta.
4. Bridge+root AER baseline: `setpci -s 00:07.0 0x104.l 0x110.l 0x130.l 0x134.l 0x12c.l`; `setpci -s 03:00.0 0x104.l 0x110.l`.
5. Kernel AER counters (monotonic before): `cat /sys/bus/pci/devices/0000:0{0:07,3:00,4:00}.0/aer_dev_{fatal,nonfatal,correctable}` *(NEW metric, folded from (b))*.
6. Link baseline: `current_link_speed`/`current_link_width` on chain.
7. WPR2+PMC_BOOT_0 before (A4 `close-entry`/`pre-stop` journal lines auto-emit).

**Continuous sampler during hang (fsync'd, `/tmp/sh1_sampler.sh` → `/var/log/sh1-poll-vs-block.<epoch>.log`, 250 ms × 40):**
8. Worker TID: two-phase — `ps -eLo tid,stat,comm | awk '/kworker/&&($2~/R|D/||$3~/events_long/){print $1}'` then `grep -q nv_f40b_shutdown_worker /proc/$t/stack`. **Lock TID once** (full kworker stack-scan/pass = 239 ms, self-perturbs).
9. Per-pass: `/proc/<tid>/stat` state(R/D) + utime/stime(14/15) + cpu(39) + `/proc/<tid>/wchan` + `head -1 /proc/<tid>/stack`.
10. **Load-bearing:** root+bridge AER UESta CmpltTO bit14: `setpci -s 00:07.0 0x104.l`, `setpci -s 03:00.0 0x104.l`.
11. On CmpltTO set → AER Header Log TLP addr: `setpci -s 00:07.0 0x11c.l 0x120.l 0x124.l 0x128.l` (and 03:00.0).
12. Root Error Status + Source ID: `setpci -s 00:07.0 0x130.l 0x134.l` *(NEW metric, folded from (b))*.
13. Link state during hang (catch transient drop).
14. ~~during-hang BAR0 reads (PMC_BOOT_0, WPR2) via userspace mmap~~ **BLOCKED → SH-2.** `resource0` mmap=EINVAL (driver holds BAR0), `/dev/mem`=EPERM (`CONFIG_IO_STRICT_DEVMEM`). Chip-alive is instead inferred from the **kernel AER Δ** (item 5+18: zero Δ ⇒ chip answered every poll ⇒ alive/Model A; nonzero CmpltTO ⇒ dead/Model C). GPU-side config-space AER `setpci -s 04:00.0 0x1bc.l 0x1d4.l` is still attempted post-hang only (config space, not BAR0 — but still traverses to 04:00.0, so post-hang not during).

**Post-hang:**
15. Completes-at-T (1–3 s ⇒ Model B) or `timed out after 10000 ms` (Model A) — journal `rm_shutdown_adapter` line.
16. rm_disable vs rm_shutdown latency pair (call_name disambiguates; nv.c:2298 vs :2348).
17. WPR2+PMC_BOOT_0 after (A4 `post-shutdown`/`close-exit`).
18. Kernel AER counter delta vs pre.
19. A8: `tb_egpu_f40b_fires` delta, `tb_egpu_state`, `tb_egpu_qwd_last_aer_summary`.
20. Worker-exit watch: post-fire `ps` for lingering D-state nv_f40b workers; sampler logs `NO_WORKER` sentinel timestamping actual exit (timeout-declared→worker-exited gap is a datum).

## Outcome → inference

- **Completes ~280 ms** → 200 ms budget marginally too tight; A7 declaring lost slightly early; trivial budget fix.
- **Completes 1–3 s, pegged, WPR2 during=UP** → Model B: slow GSP shutdown; budget should bracket it; characterize the slow step.
- **Never (10 s), pegged, WPR2 during=0, PMC alive, AER-delta=0** → **Model A / H-SH1**: post-WPR2 handshake bit never flips, chip alive → genuine late-stall deadlock → SH-2 (eBPF `osDevReadReg032`) to name the register → upstream-report-grade.
- **Never, D-state, PMC=0xFFFFFFFF, CmpltTO latched + TLP addr** → Model C / H-SH3: single non-returning MMIO; the TLP address names the register directly.

## Safety

- **Bridge/root config + all sysfs + /proc reads: unconditionally passive-safe** (healthy, answer instantly even if GPU wedged). **GPU-targeted reads (04:00.0 config + BAR0 MMIO) are the only risky ones** — gate EVERY one on a prior-clean PMC_BOOT_0 this pass; use an **independently-killable** userspace `mmap(resource0)` helper (not in-driver, not worker-thread). `resource0` over `/dev/mem` (STRICT_DEVMEM).
- **fsync'd sampler** (`sync -d` per record) survives a wedge; TID locked once; never stack-scan all kworkers per pass.
- **10 s thermal cap** (single variable); pkg temp can hit 105 °C on single-core peg (`project_h21`); E-core cpuset pin mitigates exposure.
- **Recovery = reboot.** First post-wedge check MUST be BAR1 size via sysfs (`feedback_no_rpc_observability_on_broken_bar1`) — no active observability before BAR1 confirmed.
- Never write `tb_egpu_recover_force_trigger` (only writable tb_egpu_* file; triggers active recovery). `tb_egpu_qwd_last_pmc_boot_0` is a zero-init cache, NOT a live read.

## SH-2 hook (if Model A/C confirmed, additive)

eBPF on the symbolized closed accessor `osDevReadReg032` (os.c:2026): arg2 = polled BAR0 offset, kretprobe = value, fire-frequency = poll cadence — names the stuck register without modifying RM. Companion `osDevWriteReg032` (os.c:1851). Bracket `rm_shutdown_adapter`/`rm_disable_adapter` kprobes. Template exists: `tools/bpftrace-wedge-watch.bt`; minimal delta = add the two accessor probes. Use hist/count aggregation, not per-event printf (Heisenbug).

## Cross-refs

Ledger: `../shutdown-hang-ledger.md` · (b) raw map: `../.workflow-b-observable-surface-raw-2026-05-30.json` · A4-vs-A7 model: this doc §centerpiece · F40 catalog: `/root/fake-5090/failure-modes/F40-reinit-gsp-lockdown-wedge.md`

---

## RESULTS (n=3, 2026-05-30) — RESOLVED

**`rm_shutdown_adapter` does NOT hang. It completes successfully in ~600 ms.** The A7 200 ms budget was ~3× too tight and has been declaring the GPU lost *prematurely* on every teardown.

| rep | trigger | rm_disable | rm_shutdown latency | outcome |
|---|---|---|---|---|
| 1a | `nvidia-smi -pm 0` close | completed | completed (sec-resolution) | within 10 s budget |
| 1b | `nvidia-smi -L` close | ~12 ms | **~612 ms** | completed within budget |
| 2 | `nvidia-smi -L` close | — | **~600 ms** | completed within budget |
| 3 | `nvidia-smi -L` close | — | **~611 ms** | completed within budget |

**Evidence triangulated:**
- **Latency** (n=3): 600–612 ms, rock-solid. `rm_disable_adapter` ~12 ms (the asymmetry holds — only the final GSP-shutdown step is slow).
- **Worker state:** caught as `kworker/14:0+events_long` in **R-state on CPU 14** — `events_long` = `system_long_wq` (where A7 schedules). Busy-running, pegs a core for ~600 ms (the prior stack-catchers' 0-hits were because a *running* task's `/proc/<tid>/stack` is unreadable — itself evidence of R-state). This is the busy-poll the thermal signature predicted (H-SH1 mechanism).
- **kernel AER Δ = 0** across all reps (no `CmpltTO`, no fatal/nonfatal) ⇒ the chip **answered every access** during the 600 ms — alive, no completion timeout. Rules out Model C.
- **f40b_fires stayed 1** (zero timeout fires across 3 reps), `state=healthy`, GPU functional throughout (37 °C, P0, nvidia-smi OK). No GPU-lost, no sink-set, no leaked worker — because the teardown *completed*.

**Model: hybrid B+A1.** Outcome is **Model B** (completes; 200 ms budget too tight, H-SH2). Mechanism is the **H-SH1 busy-poll** — the worker busy-polls a GSP shutdown-handshake register for ~600 ms until the chip sets it, then completes. **There is no deadlock.** The "F40 shutdown-arm wedge / rm_shutdown_adapter hangs every teardown" premise (Test A n=4) was an **artifact of the 200 ms guillotine**, not a real hang.

## Implications (carefully bounded)

1. **A7's shutdown-arm containment was largely treating a non-problem on the close path.** rm_shutdown_adapter completes at ~600 ms; A7 cut it off at 200 ms, declaring the GPU lost ~400 ms early on every teardown.
2. **Immediate fix:** raise `NVreg_TbEgpuShutdownTimeoutMs` default from 200 ms to comfortably above 600 ms (e.g. **1500–2000 ms**). Then teardown completes normally — no premature GPU-lost, no sink-set, no leaked worker. Teardown *works* instead of being *survived*. One-line code change → aorus.22.
3. **OPEN — do NOT overclaim:**
   - **Why ~600 ms?** SH-2 (eBPF on `osDevReadReg032`) to see the polled register + cadence — is it a GSP handshake? Is the 600 ms reducible, or inherent to TB-tunneled GSP shutdown?
   - **Rmmod path untested here.** SH-1 used the *close* path (module stays loaded). The rmmod path unloads the module — if the ~600 ms worker is still running when the module unloads, that's the use-after-free race (H-SH5). The original 20:52 "wedge" was rmmod-path; was it this 600 ms cut off, a genuine UAF-on-unload, or something else? **Unknown — needs a dedicated rmmod-path SH.**
   - **The OPEN-arm (A6) wedges remain genuine** (n=13 reboots, RmInitAdapter). This finding is specific to the SHUTDOWN arm.
