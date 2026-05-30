# SH-2 — characterize the rm_shutdown_adapter ~600 ms poll

**Status:** RESOLVED 2026-05-30 — via **PMU/timer sampling** (bpftrace `profile`), after the kprobe path proved IBT-blocked. The ~600 ms is a **GSP firmware RM-unload RPC round-trip**, not a stuck register.
**Series:** Shutdown-Hang (SH)
**Goal:** Explain why `rm_shutdown_adapter` takes ~600 ms and what it polls.

## Method correction (a recorded lesson)

The initial plan was `kprobe:osDevReadReg032`. That is **structurally blocked**: the closed RM (`nv-kernel.o`, precompiled, **0 `endbr64`**) is not kprobe-able on `CONFIG_X86_KERNEL_IBT=y` — verified: kprobes attach to the kernel (`__x64_sys_openat`) and to *open* nvidia functions (`nv_f40b_shutdown_bounded`) but EINVAL on the RM blob (name and raw address). I initially closed SH-2 as "blocked" — that was a **single-datapoint inferential overreach** (one failed mechanism ≠ no path). The correct read: **kprobe places a breakpoint (IBT-gated); PMU sampling does not** — it samples the instruction pointer / stack on a timer interrupt, so the closed-RM/IBT obstacle does not apply. bpftrace `profile:hz:N` is that path and was available the whole time.

## Result — the ~600 ms is the GSP unload RPC

`profile:hz:4999` over a close-path teardown (apnex.23) captured the busy-poll worker's stacks. The dominant chain (by sample count: `_issueRpcAndWait` ×33, `osDevReadReg032` ×29+, `_kgspRpcRecvPoll` ×50+):

```
rm_shutdown_adapter
  → kgspUnloadRm_IMPL                 (issue "unload RM" command to GSP)
    → _issueRpcAndWait                (send RPC, then busy-wait for reply)
      → _kgspRpcRecvPoll              (poll the GSP message queue) ← the ~600 ms loop
        → _kgspRpcDrainEvents → GspMsgQueueReceiveStatus  (read GSP mailbox status)
        → _kgspIsHeartbeatTimedOut → osDevReadReg032       (read GSP heartbeat reg)
        → kgspHealthCheck_TU102    → osDevReadReg032       (read health reg)
```

**Interpretation:** `rm_shutdown_adapter` asks the GSP (GPU System Processor firmware) to unload the RM, then **busy-polls the GSP mailbox/heartbeat** until the GSP finishes and replies. The `osDevReadReg032` reads we could not kprobe are the **GSP message-queue status + heartbeat registers** (the GSP RPC doorbell/status, not a single "handshake bit"). The ~600 ms is the **GSP firmware's processing time for the unload RPC over the TB4 tunnel** — a legitimate (if slow) firmware round-trip.

## What this resolves

1. **Why ~600 ms** — GSP unload-RPC latency. **Not reducible by us** (GSP firmware timing); the 1200 ms budget (2× the RPC latency) is appropriately sized, and the value is structural, not a "register never flips".
2. **Why the C5 sink isn't consulted** (the SH-3 guard finding that `flush_work` ran to natural completion) — `_kgspRpcRecvPoll` waits on the GSP RPC reply; it is not a sink-aware loop. Confirmed mechanistically.
3. **Direct lead for the OPEN arm (#282)** — the *init* stacks in the SAME capture show `kgspBootstrap_GH100 → kgspWaitForRmInitDone_IMPL → _kgspRpcRecvPoll → _issueRpcAndWait`: **`RmInitAdapter` uses the identical GSP-RPC-poll mechanism.** So the open-arm wedge is very likely the GSP **init** RPC never completing (GSP not booted/dead → poll never gets a reply → the read eventually CTOs → AER `UESta=0x4000`), versus the shutdown arm's unload RPC that *does* reply in ~600 ms. **Same mechanism (`_issueRpcAndWait`/`_kgspRpcRecvPoll`), opposite outcome.** The open-arm forensics should target this RPC-wait path with the same PMU-sampling method (kprobe-free).

## Residual (genuinely minor)

The exact BAR0 offset of the heartbeat/mailbox status registers is in the `osDevReadReg032` operands; `perf annotate` (perf not installed; `dnf install perf`) or `bpftrace`'s `*(reg)` reads at a `profile` sample could extract them if ever needed. Not pursued — the *function-level* answer (GSP unload RPC) is the characterization that matters; the numeric offsets are an upstream-report detail.

## Method note for the toolbox

**For the closed RM on IBT kernels: use PMU sampling (`bpftrace profile:hz:N` capturing `kstack`), not kprobe.** Sampling is breakpoint-free (no IBT/endbr requirement) and symbolizes RM frames via kallsyms. This is the standard observability path for `nv-kernel.o` and applies directly to #282.

## Cross-refs

Ledger: `../shutdown-hang-ledger.md` · raw profile: `/var/log/mission-1-archaeology/SH-1-2026-05-30/sh2-pmu-profile.out` · SH-1 / SH-3: ledger
