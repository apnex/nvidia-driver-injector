#!/usr/bin/env bash
# rung1.sh — R1 baseline recovery determinism (deterministic-recovery validation).
#
# N consecutive: quiesce+uninstall -> TB deauth/reauth (broken-BAR1) ->
# fix-bar1.sh --bind (chip ReBAR CTRL + slot-cycle + modprobe apnex.25 +
# persistence) -> the 6 PRIMARY per-cycle asserts. ZERO reboots is the bar.
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

POD() { kubectl get pods -n "$OA_INJECTOR_NS" -o name 2>/dev/null | grep "$OA_INJECTOR_DS" | head -1 | cut -d/ -f2; }

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

    # --- 1. quiesce + uninstall (chip must be driver-free for TB deauth+slot-cycle) ---
    oa_mark "c$c: disable persistence + uninstall apnex.25"
    timeout 30 nvidia-smi -pm 0 >/dev/null 2>&1
    timeout 60 kubectl exec -n "$OA_INJECTOR_NS" "$(POD)" -- /entrypoint.sh uninstall \
        > "$OA_RUNDIR/c${c}-uninstall.log" 2>&1
    if [[ -d /sys/module/nvidia ]]; then
        oa_mark "c$c: FAIL — module still loaded after uninstall"; oa_passive_snapshot "c$c-uninstall-fail"
        FAIL=$((FAIL+1)); HALT="uninstall-fail"; break
    fi

    # --- 2. TB deauth/reauth -> broken-BAR1 (driver unloaded, so no surprise-removal wedge) ---
    oa_mark "c$c: TB deauth ($OA_TB)"
    echo 0 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 2
    oa_mark "c$c: TB reauth"
    echo 1 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 4
    oa_discover   # GPU BDF can change across re-enum
    oa_mark "c$c: post-replug BAR1=$(oa_bar1_mib)MiB (expect ~256 broken)"

    # --- 3. fix-bar1.sh --bind (restore 32GB + bind apnex.25 + engage persistence) ---
    oa_mark "c$c: setpci COMMAND mem-decode OFF + fix-bar1 --bind"
    setpci -s "$OA_GPU_SHORT" COMMAND=0:3 2>/dev/null
    timeout 180 "$FIXBAR1" --bind > "$OA_RUNDIR/c${c}-fixbar1.log" 2>&1
    oa_mark "c$c: fix-bar1 rc=$?"

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
