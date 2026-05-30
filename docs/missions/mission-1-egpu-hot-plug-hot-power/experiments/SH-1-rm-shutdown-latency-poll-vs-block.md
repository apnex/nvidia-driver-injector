# SH-1 — rm_shutdown_adapter latency + poll-vs-block + stuck-register proxy @ 10 s, close-path

**Status:** READY (exhaustiveness gate (b) passed 2026-05-30 — see `shutdown-hang-ledger.md`)
**Series:** Shutdown-Hang (SH); first root-cause experiment
**Risk:** MEDIUM (during-hang GPU-targeted MMIO reads can stall the reader; host-wedge → reboot)
**Cost:** ~10 s active hang/pass × n≥3, + setup; thermal-bounded
**Reversibility:** the leaked worker self-exits post-sink-set (close path keeps module loaded — no rmmod-unload UAF). Host wedge → reboot.
**Single variable:** `NVreg_TbEgpuShutdownTimeoutMs = 10000` (vs prod 200 ms). Nothing else changes.

## Hypothesis

Primary **H-SH1** (leading): `rm_shutdown_adapter` busy-polls a GSP handshake register for a state transition that never occurs on TB-eGPU teardown — chip alive and answering MMIO, but the awaited bit never flips. Also resolves **H-SH2** (budget-too-tight), **H-SH3** (blocked-read/MMIO-dead), **H-SH4** (which register, via TLP-address proxy), **H-SH6** (WPR2 timeline).

## The model the during-hang WPR2 read selects (centerpiece)

A4-vs-A7 reconciled: A4's `post-shutdown` WPR2=0 is a **post-timeout after-sample** (fires after A7's bounded return), NOT proof of graceful completion. WPR2 clears **early** in `rm_shutdown_adapter`, before the stuck MMIO ⇒ the hang is a **late-stage stall**. The `before(UP)→after(0)` WPR2 transition is identical under Models A and B; **only the during-hang value discriminates:**

| Model | during-hang WPR2 | during-hang PMC_BOOT_0 | worker CPU | kernel AER delta | ⇒ Mechanism |
|---|---|---|---|---|---|
| **A — late-stall (H-SH1, leading)** | `0` (cleared) | `0x1b2000a1` (alive) | pegged (R, utime↑) | zero | post-WPR2 GSP handshake bit never flips; chip alive, busy-poll |
| **B — slow-but-progressing (H-SH2)** | `UP` (0x07f4a000) | `0x1b2000a1` | pegged | zero | worker clears WPR2 in the timeout→A4 gap; 200 ms budget merely too tight |
| **C — MMIO-dead (H-SH3)** | unreadable | `0xFFFFFFFF` | D-state (~0 CPU) | nonzero (CmpltTO) | chip went dark; **already unlikely** (live A4 post-shutdown PMC=0x1b2000a1) |

The bridge **AER Header Log TLP address** (latched on CmpltTO at root 00:07.0 / bridge 03:00.0) is the passive proxy for *which* register stalled — mapped against GPU BAR0 phys `0x80000000`. The *direct* polled offset is unknown to the entire open layer (only known BAR0 offsets: `0`=PMC_BOOT_0, `0x88a828`=WPR2) → that's the SH-2 eBPF item (`osDevReadReg032`), not an SH-1 miss.

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
14. **GATED on prior-clean PMC_BOOT_0 this pass** (caution — traverses TB chain to possibly-wedged endpoint): PMC_BOOT_0 via userspace `mmap(resource0)` off 0; then WPR2 off `0x88a828`; then GPU-side AER `setpci -s 04:00.0 0x1bc.l 0x1d4.l`. If PMC=`0xFFFFFFFF`/stalls → **STOP all GPU reads** (that *is* the Model-C answer).

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

Ledger: `../shutdown-hang-ledger.md` · (b) raw map: `../.workflow-b-observable-surface-raw-2026-05-30.json` · A4-vs-A7 model: this doc §centerpiece · F40 catalog: `/root/fake-5090/failure-modes/F40-rmshutdownadapter-incomplete-init-wedge.md`
