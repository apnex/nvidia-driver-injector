# SH-2 — eBPF/kprobe register identity for the rm_shutdown_adapter poll

**Status:** CLOSED — BLOCKED by IBT + precompiled RM (2026-05-30). Register identity deferred to upstream / an IBT-off session if ever specifically needed. Actionable conclusions already established (do not re-run for the actionable answers).
**Series:** Shutdown-Hang (SH)
**Goal:** Name the exact BAR0 register `rm_shutdown_adapter` busy-polls for ~600 ms (and the poll cadence) via `kprobe:osDevReadReg032` (arg2 = `thisAddress` = BAR0 offset).

## Outcome: the kprobe path is structurally blocked

`osDevReadReg032` (and `rm_shutdown_adapter`, all of `nv-kernel.o`) are **not kprobe-able on this kernel**. Verified empirically (2026-05-30, apnex.23):

| Target | Layer | kprobe attaches? |
|---|---|---|
| `__x64_sys_openat` | core kernel | ✅ yes |
| `nv_f40b_shutdown_bounded` | open `kernel-open/nvidia/nv.c` (compiled locally) | ✅ yes |
| `osDevReadReg032`, `rm_shutdown_adapter` | precompiled `nv-kernel.o` RM blob | ❌ **EINVAL** (name *and* raw address) |

**Root cause:** `CONFIG_X86_KERNEL_IBT=y` + the RM is shipped as a **precompiled binary** (`kernel-open/nvidia/nv-kernel.o_binary -> src/nvidia/_out/Linux_x86_64/nv-kernel.o`) compiled **without** IBT prologues — `objdump -d nv-kernel.o | grep -c endbr64` = **0**. On an IBT kernel, the kprobe subsystem rejects a probe at a function entry that lacks `endbr64`. The open `kernel-open/` layer *is* compiled locally with the kernel's IBT flags (has `endbr64`), which is why open functions probe fine and RM functions don't. bpftrace fails the same way (and additionally the RM isn't in ftrace's `available_filter_functions`).

## What it would have taken (not pursued — characterization only)

- **`ibt=off` (or `nokaslr ibt=off`) cmdline + reboot** — disables Indirect Branch Tracking kernel-wide, a real security reduction, not worth it for a characterization datum.
- **`+offset` kprobe** (probe a few bytes past the entry to dodge the entry-IBT check, with `thisAddress`=`rdx` still live through the bounds-check prologue) — fragile (arg-liveness unverified without a clean prologue disassembly of the relocatable blob) and noise-prone on a chip-touching path. Tried briefly; not worth hardening for characterization.
- **NVIDIA RM source** — NVIDIA has the `os.c`/RM source and the GSP-side handshake; the register identity is naturally a question for the upstream report, not local observability.

## What we DO know (sufficient for every actionable conclusion)

From SH-1 (n=3) + the SH-3 guard validation — no register-identity needed:
1. `rm_shutdown_adapter` **busy-polls** (worker R-state, CPU pegged — SH-1) a **chip-alive** register (kernel AER Δ = 0, no completion timeout — the chip answers every read) for **~600 ms** (612/600/611 close, ~649 rmmod) then **completes**. It is a slow-but-completing GSP shutdown handshake, not a hang.
2. The poll does **NOT consult the C5 sink** — the SH-3 guard validation forced a timeout and the `flush_work` ran to the worker's **~natural completion** (not a fast-fail), evidence the polled MMIO loop does not check `PDB_PROP_GPU_IS_LOST`. (This is why the guard's flush is bounded by the ~600 ms natural completion, not by the sink.)

The only thing SH-2 would have added is the **exact register offset + cadence** — a "nice to know" for the upstream report, not load-bearing for the budget fix, the guard, or the v5 decision.

## Disposition

Register identity is **parked** (not abandoned): fold it into the upstream NVIDIA report (#979 follow-up) where the RM source makes it trivial, or revisit in a dedicated `ibt=off` session if a specific need arises (e.g., proving the handshake register is reducible). The shutdown-arm investigation is otherwise complete.

## Cross-refs

Ledger: `../shutdown-hang-ledger.md` · SH-1: `SH-1-rm-shutdown-latency-poll-vs-block.md` · SH-3 gate/guard: ledger + `../.workflow-sh3-gate-raw-2026-05-30.json`
