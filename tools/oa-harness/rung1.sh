#!/usr/bin/env bash
# rung1.sh — R1 baseline recovery determinism (deterministic-recovery validation).
#
# Injector pod drained for the whole run (it would race host-side recovery).
# N consecutive: quiesce + host-side rmmod -> TB deauth/reauth (broken-BAR1) ->
# fix-bar1.sh --bind (chip ReBAR CTRL + slot-cycle + modprobe apnex.25 +
# persistence) -> complete CUDA bringup (nvidia_uvm + UVM device node, which
# fix-bar1 --bind does NOT do) -> the PRIMARY per-cycle asserts. Restore the pod
# at the end. ZERO reboots is the bar.
#
# This is the NON-adversarial path: fix-bar1 --bind engages persistence right
# after modprobe, so the destructive LAST-CLOSE never runs -> the F40-open
# precondition is never created -> A6 does NOT fire (no timeout). Recoverable
# without reboot; the only reboot-fallback is a fix-bar1 leg-b (288MB) fallback.
#
# Usage: sudo tools/oa-harness/rung1.sh [N]      (default N=5)
#   N=1 first as a single-cycle smoke-test, then N>=5 for the determinism bar.
#
# Runs ON obpc — a hard wedge kills this process; oa_mark fsyncs every
# wedge-capable step so the trigger survives. User must be at the console.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

N="${1:-5}"
FIXBAR1="$OA_REPO_ROOT/tools/fix-bar1.sh"
DIAG_COMPOSE="$OA_REPO_ROOT/diag/docker-compose.yml"

oa_discover
oa_init_run "r1-baseline-determinism"
oa_assert_r0                         # HARD: R0 build + KFENCE live + bounded lane
[[ -x "$FIXBAR1" ]] || oa_die "fix-bar1.sh not executable at $FIXBAR1"
oa_mark "R1 start: N=$N  fix-bar1=$FIXBAR1"

# Drain the injector pod for the WHOLE run: on the per-cycle TB-deauth the GPU
# disappears, the pod's GPU-presence guard exits, the kubelet restarts it, and
# that restart would RACE host-side fix-bar1 recovery. Drain once, recover
# host-side N times, restore once. Restore on ANY exit (clean / break / Ctrl-C).
oa_drain_injector || oa_die "could not drain injector pod — aborting R1 (it would race recovery)"
trap 'oa_restore_injector' EXIT

# host_unload — disengage persistence, then rmmod the module host-side (the pod
# is drained, so the host owns the module lifecycle). The host modprobe.d
# blacklist uses `install ... /bin/false`, which gates LOAD only — rmmod is
# unaffected. Returns nonzero if /sys/module/nvidia survives.
host_unload() {
    local c="$1" m
    timeout 30 nvidia-smi -pm 0 >/dev/null 2>&1 || true   # disengage persistence (clean LAST-CLOSE)
    sync
    for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
        [[ -d /sys/module/$m ]] && timeout 30 rmmod "$m" >>"$OA_RUNDIR/c${c}-unload.log" 2>&1
    done
    [[ ! -d /sys/module/nvidia ]]
}

# Workload assert (PRIMARY #5): H2D via the diag container. Hard floor >1.0 GB/s
# (a hang/regression fails); logs the actual value (TB4-saturated band 2.7-2.9).
workload_h2d() {
    local c="$1" out gbps
    out="$OA_RUNDIR/c${c}-nvbandwidth.log"
    timeout 120 docker compose -f "$DIAG_COMPOSE" run --rm diag \
        nvbandwidth -t host_to_device_memcpy_ce > "$out" 2>&1
    gbps="$(grep -oiE 'SUM[^0-9]*[0-9]+\.[0-9]+' "$out" | grep -oE '[0-9]+\.[0-9]+' | tail -1)"
    [[ -z "$gbps" ]] && gbps="$(grep -oE '[0-9]+\.[0-9]+' "$out" | tail -1)"
    echo "$gbps"
}

PASS=0; FAIL=0; HALT=""
for c in $(seq 1 "$N"); do
    oa_mark "===== R1 cycle $c/$N START ====="

    # --- 1. quiesce + host-side unload (pod drained; host owns the module) ---
    oa_mark "c$c: disable persistence + host-side rmmod"
    if ! host_unload "$c"; then
        oa_mark "c$c: FAIL — module still loaded after host unload"
        { echo "--- holders ---"; lsmod | grep -E '^nvidia'; lsof /dev/nvidia* 2>/dev/null; } >> "$OA_RUNDIR/c${c}-unload.log" 2>&1
        oa_passive_snapshot "c$c-unload-fail"
        FAIL=$((FAIL+1)); HALT="unload-fail"; break
    fi

    # --- 2. TB deauth/reauth -> broken-BAR1 (driver unloaded, so no surprise-removal wedge) ---
    oa_mark "c$c: TB deauth ($OA_TB)"
    echo 0 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 2
    oa_mark "c$c: TB reauth"
    echo 1 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 4
    oa_discover   # GPU BDF can change across re-enum
    oa_mark "c$c: post-replug BAR1=$(oa_bar1_mib)MiB (expect ~256 broken)"

    # --- 3. fix-bar1.sh --bind (restore 32GB + bind apnex.25 + engage persistence) ---
    # full-clear COMMAND (not the partial 0:3 mask) — fix-bar1 fatals unless it
    # reads EXACTLY 0000; the device is unbound + about to be slot-cycled.
    oa_mark "c$c: setpci COMMAND=0000 (mem-decode OFF, fix-bar1 contract) + fix-bar1 --bind"
    setpci -s "$OA_GPU_SHORT" COMMAND=0000 2>/dev/null
    timeout 180 "$FIXBAR1" --bind > "$OA_RUNDIR/c${c}-fixbar1.log" 2>&1
    oa_mark "c$c: fix-bar1 rc=$?"

    # --- 3b. complete the CUDA bringup. fix-bar1 --bind loads `nvidia` + engages
    #     persistence but NOT nvidia_uvm or the UVM device node; CUDA cuInit needs
    #     /dev/nvidia-uvm (a fix-bar1-only recovery is graphics/nvidia-smi-ready but
    #     NOT CUDA-ready -> nvbandwidth/vLLM fail). Mirror the injector entrypoint:
    #     load_module nvidia_uvm + nvidia-modprobe -u -c 0. This is part of the
    #     complete deterministic userspace recovery recipe R1 validates. ---
    oa_mark "c$c: complete CUDA bringup (modprobe nvidia_uvm + nvidia-modprobe -u -c 0)"
    modprobe --ignore-install nvidia_uvm >>"$OA_RUNDIR/c${c}-uvm.log" 2>&1
    nvidia-modprobe -u -c 0 >>"$OA_RUNDIR/c${c}-uvm.log" 2>&1
    [[ -e /dev/nvidia-uvm ]] || oa_mark "c$c: WARN — /dev/nvidia-uvm absent after bringup (workload will fail)"

    # --- 4. PRIMARY asserts (BAR1-first, passive before any nvidia-smi) ---
    if ! oa_bar1_recovered; then
        verdict="$(oa_bar1_leg_diagnose)"
        oa_mark "c$c: FAIL — BAR1 not recovered (verdict=$verdict)"; oa_passive_snapshot "c$c-bar1-fail"
        FAIL=$((FAIL+1)); HALT="bar1-$verdict"; break
    fi
    oa_mark "c$c: BAR1==32768 + bridge window full ✓ (window=$(oa_bridge_pref_window_mib)MiB)"

    pm="$(timeout 10 nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>&1)"
    link="$(cat /sys/bus/pci/devices/$OA_GPU/current_link_speed 2>/dev/null)/$(cat /sys/bus/pci/devices/$OA_GPU/current_link_width 2>/dev/null)"
    oa_mark "c$c: persistence=$pm link=$link"
    if [[ "$pm" != "Enabled" ]]; then oa_mark "c$c: FAIL — persistence not engaged"; FAIL=$((FAIL+1)); HALT="persist"; break; fi

    oa_mark "c$c: workload (nvbandwidth H2D)"
    h2d="$(workload_h2d "$c")"
    oa_mark "c$c: H2D=${h2d:-<none>} GB/s (band 2.7-2.9; floor >1.0)"
    if [[ -z "$h2d" ]] || ! awk "BEGIN{exit !($h2d>1.0)}"; then
        oa_mark "c$c: FAIL — workload regression/hang (H2D=${h2d:-none})"; FAIL=$((FAIL+1)); HALT="workload"; break
    fi

    oa_passive_snapshot "c$c-recovered"   # AER + state, post-workload
    PASS=$((PASS+1))
    oa_mark "===== R1 cycle $c/$N PASS (BAR1 32768, persist, H2D=${h2d}) ====="
done

oa_mark "===== R1 COMPLETE: PASS=$PASS FAIL=$FAIL of $N${HALT:+ (halted: $HALT)} ====="
oa_log "verdict: $([[ $PASS -eq $N && $FAIL -eq 0 ]] && echo "DETERMINISTIC (n=$N clean)" || echo "NOT clean — see $OA_RUNDIR")"
oa_log "forensics: $OA_RUNDIR"

oa_restore_injector   # bring the bystander pod back (trap EXIT is the idempotent backstop)
