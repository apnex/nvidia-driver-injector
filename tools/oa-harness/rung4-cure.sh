#!/usr/bin/env bash
# rung4-cure.sh — R4 cure-vs-contain: does any runtime reset CLEAR the F40-open
#                 GSP-lockdown divergence, or only leave it CONTAINED (= #979)?
#                 (deterministic-recovery validation; HARD-BLOCKED on R0+A9; KFENCE-watched)
#
# This is the SAFE re-incarnation of reset-ladder.sh (which is marked DO-NOT-RUN
# because it hard-wedged the host 2026-05-31). The wedge root cause — A6 bypassed
# on the post-rebind FIRST open because is_external_gpu was set lazily — is now
# closed by A9 (probe-time is_external_gpu) and made ENFORCEABLE by the load-bearing
# gate below: assert tb_egpu_is_external==1 AFTER reset+rebind, ABORT the fire if 0.
# Design + adversarial safety review: workflow r4-cure-vs-contain-design (2026-06-01).
#
# Per iteration (one --reset variant per invocation, "one variable per run"):
#   1. PRECOND   — no-persistence F40 substrate (drain-first, rung2 pattern) +
#                  assert tb_egpu_is_external==1 (A9 armed on this bind).
#   2. CYCLE-1   — nvidia-smi -L : destructive LAST-CLOSE -> chip divergent.
#   3. RESET     — the cure point: none | rebind | flr | sbr | slot (unbind->reset->rebind).
#   4. BAR1-FIX  — flr/sbr reset ReBAR CTRL -> BAR1 256MB; light rewrite, else slot-recover
#                  (record NEEDED_SLOT — a needed slot-cycle => cure is no-shallower-than-slot).
#   5. GATES     — HARD: tb_egpu_is_external==1 (else REFUSE fire), D0-pin+active, BAR1>=32768.
#   6. CYCLE-2   — exec open /dev/nvidia0 (NO PMU sampler — it perturbs the AER race).
#   7. CLASSIFY  — CURED (rc=0, healthy, A6 silent) | CONTAINED (A6 fired/-EIO) |
#                  INCONCLUSIVE (is_external==0 / BAR1 broken). BREACH (KFENCE UAF /
#                  rc=124 hang / unmatched-scheduled) HALTS the run.
#   8. RECOVER   — fix-bar1 --bind + UVM + CUDA workload back to clean.
#
# ⚠️ REBOOT-RISK: flr/sbr/slot can DROP the device off the bus (DEVICE GONE ->
# reboot, gated by oa_dev_present but unrecoverable in-session). gap PINNED 2s
# (<5s; a longer gap reaches the A6-uncovered H-OA2 D3 site). oa_mark fsyncs every
# wedge-capable step; on a wedge REBOOT then read $OA_RUNDIR/markers.log +
# RESTORE-CMD.txt (DS drained). USER MUST BE AT THE CONSOLE.
#
# Usage: sudo tools/oa-harness/rung4-cure.sh --reset {none|rebind|flr|sbr|slot} [N]
#   Run N=1 SMOKE first per variant; only go N>=3 after the smoke proves
#   tb_egpu_is_external held across that variant's reset AND the fire was contained.
#   Safe-first order: none -> rebind -> flr -> sbr -> slot.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RESET=""; N=1
while [[ $# -gt 0 ]]; do case "$1" in
    --reset) RESET="$2"; shift 2;;
    [0-9]*) N="$1"; shift;;
    *) oa_die "unknown arg $1 (usage: --reset {none|rebind|flr|sbr|slot} [N])";; esac; done
case "$RESET" in none|rebind|flr|sbr|slot) ;; *) oa_die "need --reset {none|rebind|flr|sbr|slot}";; esac

FIXBAR1="$OA_REPO_ROOT/tools/fix-bar1.sh"
DIAG_COMPOSE="$OA_REPO_ROOT/diag/docker-compose.yml"
KF_PARAM=/sys/module/kfence/parameters/sample_interval
KF_SAVED=""
GAP=2                         # PINNED <5s (H-OA2 autosuspend threshold); never expose >5s
REBAR_CTRL=0x13c              # ReBAR cap 0x134 + 8
REBAR_VAL=0x00000f21          # BAR_IDX=1 NBAR=1 BAR_SIZE=15 (32 GiB)

oa_discover
oa_init_run "r4-cure-${RESET}"
oa_assert_r0                  # HARD: R0 flush->join + KFENCE live + bounded lane (>0)
[[ -x "$FIXBAR1" ]] || oa_die "fix-bar1.sh not executable at $FIXBAR1"
[[ $EUID -eq 0 ]] || oa_die "must run as root"
BRIDGE="$(basename "$(readlink -f "/sys/bus/pci/devices/$OA_GPU/.." 2>/dev/null)")"   # 0000:03:00.0
SLOT=12

IS_EXT() { cat "/sys/bus/pci/devices/$OA_GPU/tb_egpu_is_external" 2>/dev/null || echo '?'; }
DEV_PRESENT() { [[ -e "/sys/bus/pci/devices/$OA_GPU" ]]; }

workload_h2d() {
    local i="$1" out gbps
    out="$OA_RUNDIR/i${i}-nvbandwidth.log"
    timeout 120 docker compose -f "$DIAG_COMPOSE" run --rm diag \
        nvbandwidth -t host_to_device_memcpy_ce > "$out" 2>&1
    gbps="$(grep -oiE 'SUM[^0-9]*[0-9]+\.[0-9]+' "$out" | grep -oE '[0-9]+\.[0-9]+' | tail -1)"
    [[ -z "$gbps" ]] && gbps="$(grep -oE '[0-9]+\.[0-9]+' "$out" | tail -1)"
    echo "$gbps"
}

host_unload() {
    local tag="$1" m
    timeout 30 nvidia-smi -pm 0 >/dev/null 2>&1 || true
    sync
    for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
        [[ -d /sys/module/$m ]] && timeout 30 rmmod "$m" >>"$OA_RUNDIR/${tag}-unload.log" 2>&1
    done
    [[ ! -d /sys/module/nvidia ]]
}

# slot power-cycle + ReBAR restore (last-resort BAR1 recovery; no rebind). 0 ok / 1 device-gone.
slot_recover() {
    local i="$1"
    oa_mark "i$i: slot-recover (BAR1 restore via slot power-cycle)"
    echo 0 > "/sys/bus/pci/slots/$SLOT/power" 2>/dev/null; sleep 3
    echo 1 > "/sys/bus/pci/slots/$SLOT/power" 2>/dev/null; sleep 5
    DEV_PRESENT || { oa_mark "i$i: DEVICE GONE after slot-recover — REBOOT NEEDED"; return 1; }
    setpci -s "$OA_GPU_SHORT" COMMAND=0:3 2>/dev/null
    setpci -s "$OA_GPU_SHORT" "${REBAR_CTRL}.l=${REBAR_VAL}" 2>/dev/null
    return 0
}

# no-persistence F40 substrate (drain-first; rung2 establish_precond + is_external assert).
establish_precond() {
    local i="$1"
    oa_mark "i$i: PRECOND — host rmmod"
    host_unload "i${i}-precond" || { oa_mark "i$i: PRECOND FAIL — module still loaded"; return 1; }
    oa_mark "i$i: PRECOND — TB deauth/reauth"
    echo 0 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 2
    echo 1 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 4
    oa_discover
    oa_mark "i$i: PRECOND — post-replug BAR1=$(oa_bar1_mib)MiB (expect ~256)"
    setpci -s "$OA_GPU_SHORT" COMMAND=0000 2>/dev/null
    oa_mark "i$i: PRECOND — fix-bar1 (bare, NO persistence)"
    timeout 180 "$FIXBAR1" > "$OA_RUNDIR/i${i}-precond-fixbar1.log" 2>&1
    oa_bar1_ok || { oa_mark "i$i: PRECOND FAIL — BAR1 not 32GiB ($(oa_bar1_mib)MiB)"; return 1; }
    oa_mark "i$i: PRECOND — modprobe nvidia (NO persistence)"
    echo '' > "/sys/bus/pci/devices/$OA_GPU/driver_override" 2>/dev/null
    modprobe --ignore-install nvidia >>"$OA_RUNDIR/i${i}-precond.log" 2>&1
    sleep 2
    local drv; drv="$(basename "$(readlink "/sys/bus/pci/devices/$OA_GPU/driver" 2>/dev/null || echo none)")"
    [[ "$drv" == nvidia ]] || { oa_mark "i$i: PRECOND FAIL — nvidia did not bind ($drv)"; return 1; }
    oa_assert_a6
    oa_pin_d0
    [[ "$(IS_EXT)" == 1 ]] || { oa_mark "i$i: PRECOND FAIL — tb_egpu_is_external=$(IS_EXT) (A9 not armed on this bind)"; return 1; }
    oa_mark "i$i: PRECOND ready — no-persistence, A6 armed, D0-pinned, is_external=1"
    return 0
}

# apply the reset variant (unbind->reset->rebind) + BAR1 coupling handling.
# echoes nothing; sets NEEDED_SLOT; returns 0 ok / 3 device-gone-reboot.
NEEDED_SLOT=0
apply_reset() {
    local i="$1"
    NEEDED_SLOT=0
    oa_passive_snapshot "i${i}-pre-reset"
    if [[ "$RESET" == none ]]; then
        oa_mark "i$i: RESET=none (2nd-open of same bind; no unbind/reset/rebind)"
        return 0
    fi
    oa_mark "i$i: RESET=$RESET — unbind nvidia"
    echo "$OA_GPU" > /sys/bus/pci/drivers/nvidia/unbind 2>/dev/null || oa_mark "i$i: WARN unbind failed"
    sleep 1
    case "$RESET" in
        rebind) : ;;
        flr)
            oa_mark "i$i: FLR on $OA_GPU"
            echo flr > "/sys/bus/pci/devices/$OA_GPU/reset_method" 2>/dev/null
            setpci -s "$OA_GPU_SHORT" COMMAND=0:3 2>/dev/null
            echo 1 > "/sys/bus/pci/devices/$OA_GPU/reset" 2>/dev/null || oa_mark "i$i: WARN FLR write failed"
            sleep 2 ;;
        sbr)
            oa_mark "i$i: SBR via bridge $BRIDGE (== A3 pci_reset_bus)"
            setpci -s "$OA_GPU_SHORT" COMMAND=0:3 2>/dev/null
            echo 1 > "/sys/bus/pci/devices/$BRIDGE/reset" 2>/dev/null || oa_mark "i$i: WARN bridge reset write failed"
            sleep 2 ;;
        slot)
            oa_mark "i$i: pciehp slot-cycle (cold-plug-equiv)"
            echo 0 > "/sys/bus/pci/slots/$SLOT/power" 2>/dev/null; sleep 3
            echo 1 > "/sys/bus/pci/slots/$SLOT/power" 2>/dev/null; sleep 5 ;;
    esac
    if ! DEV_PRESENT; then
        oa_mark "i$i: DEVICE GONE after $RESET — attempting slot-recover"
        slot_recover "$i" || { oa_mark "i$i: ABORT — device lost, reboot needed"; oa_passive_snapshot "i${i}-device-gone"; return 3; }
    fi
    # BAR1 coupling: flr/sbr reset ReBAR CTRL -> 256MB. Light rewrite, else slot-recover.
    local b1; b1="$(oa_bar1_mib)"
    oa_mark "i$i: post-reset BAR1=${b1}MiB"
    if [[ "$b1" -lt "$OA_BAR1_MIN_MIB" ]]; then
        oa_mark "i$i: BAR1 broke — light ReBAR rewrite"
        setpci -s "$OA_GPU_SHORT" COMMAND=0:3 2>/dev/null
        setpci -s "$OA_GPU_SHORT" "${REBAR_CTRL}.l=${REBAR_VAL}" 2>/dev/null
        sleep 1
        if [[ "$(oa_bar1_mib)" -lt "$OA_BAR1_MIN_MIB" ]]; then
            oa_mark "i$i: light rewrite INSUFFICIENT — escalating to slot-recover (NEEDED_SLOT)"
            slot_recover "$i" || { oa_passive_snapshot "i${i}-device-gone"; return 3; }
            NEEDED_SLOT=1
        fi
    fi
    oa_mark "i$i: rebind nvidia"
    echo '' > "/sys/bus/pci/devices/$OA_GPU/driver_override" 2>/dev/null
    echo "$OA_GPU" > /sys/bus/pci/drivers/nvidia/bind 2>/dev/null || oa_mark "i$i: WARN rebind failed"
    sleep 2
    return 0
}

# cycle-1 destructive close + the pre-fire gates + cycle-2 fire + classify.
# Sets R4_VERDICT. Returns 0 ok-classified, 2 = containment BREACH (halt).
R4_VERDICT=""
fire_and_classify() {
    local i="$1"
    oa_mark "i$i: cycle-1 (nvidia-smi -L — destructive close)"
    timeout 20 nvidia-smi -L > "$OA_RUNDIR/i${i}-cycle1.txt" 2>&1
    apply_reset "$i"; local arc=$?
    if (( arc == 3 )); then R4_VERDICT="ABORT(device-gone)"; oa_mark "i$i: $R4_VERDICT"; return 2; fi
    # --- PRE-FIRE GATES (the load-bearing set) ---
    oa_assert_a6
    oa_pin_d0
    local active; active="$(cat /sys/bus/pci/devices/$OA_GPU/power/runtime_status 2>/dev/null)"
    local isext; isext="$(IS_EXT)"
    local b1f; b1f="$(oa_bar1_mib)"
    oa_mark "i$i: pre-fire gates: is_external=$isext runtime_status=$active BAR1=${b1f}MiB needed_slot=$NEEDED_SLOT"
    oa_passive_snapshot "i${i}-post-reset-pre-cycle2"
    # GATE 1 (LOAD-BEARING): refuse the unguarded first-open that wedged 2026-05-31
    if [[ "$isext" != 1 ]]; then
        R4_VERDICT="INCONCLUSIVE(a9-regressed: is_external=$isext)"; oa_mark "i$i: REFUSE FIRE — $R4_VERDICT"; return 0
    fi
    # GATE 2: D0/active — else the wedge reaches the A6-uncovered H-OA2 site
    if [[ "$active" != active ]]; then
        R4_VERDICT="INCONCLUSIVE(not-D0: runtime_status=$active)"; oa_mark "i$i: REFUSE FIRE — $R4_VERDICT"; return 0
    fi
    # GATE 3: BAR1 — else a -EIO is unattributable (BAR1 not GSP)
    if [[ "$b1f" -lt "$OA_BAR1_MIN_MIB" ]]; then
        R4_VERDICT="INCONCLUSIVE(BAR1-broken: ${b1f}MiB)"; oa_mark "i$i: REFUSE FIRE — $R4_VERDICT"; return 0
    fi
    # --- CYCLE-2 FIRE (no sampler) ---
    sleep "$GAP"
    local fires_b; fires_b="$(cat /sys/bus/pci/devices/$OA_GPU/tb_egpu_f40b_fires 2>/dev/null || echo -1)"
    oa_mark "i$i: cycle-2 FIRE (exec open /dev/nvidia0) <<< cure point"
    local t0 t1 c2
    t0=$(date +%s.%N)
    timeout 10 bash -c 'exec 3</dev/nvidia0'; c2=$?
    t1=$(date +%s.%N)
    oa_mark "i$i: cycle-2 RETURNED rc=$c2 dt=$(awk "BEGIN{printf \"%.0f\",($t1-$t0)*1000}")ms — host SURVIVED"
    # --- POST-FIRE OBSERVE (BAR1-first) ---
    oa_mark "i$i: post-fire BAR1=$(oa_bar1_mib)MiB"
    local fires_a; fires_a="$(cat /sys/bus/pci/devices/$OA_GPU/tb_egpu_f40b_fires 2>/dev/null || echo -1)"
    dmesg | awk -v m="i${i}: cycle-2 FIRE" 'index($0,m){f=1} f' > "$OA_RUNDIR/i${i}-cycle2-dmesg.txt"; sync
    local sched compl timed kf st
    sched=$(grep -ac 'open scheduled to bounded worker' "$OA_RUNDIR/i${i}-cycle2-dmesg.txt")
    compl=$(grep -ac 'open completed within budget'     "$OA_RUNDIR/i${i}-cycle2-dmesg.txt")
    timed=$(grep -ac 'open timed out after'             "$OA_RUNDIR/i${i}-cycle2-dmesg.txt")
    kf=$(grep -acE 'KFENCE: (use-after-free|memory corruption|out-of-bounds)' "$OA_RUNDIR/i${i}-cycle2-dmesg.txt")
    st="$(cat /sys/bus/pci/devices/$OA_GPU/tb_egpu_state 2>/dev/null || echo '?')"
    oa_mark "i$i: dmesg sched=$sched compl=$compl timed=$timed kfence=$kf state=$st f40b_fires:${fires_b}->${fires_a}"
    oa_passive_snapshot "i${i}-post-fire"
    # --- CONTAINMENT BREACH dominates (the safety net itself failed) ---
    if (( kf > 0 ));        then R4_VERDICT="BREACH(KFENCE-UAF)";        oa_mark "i$i: *** $R4_VERDICT ***"; return 2; fi
    if (( c2 == 124 ));     then R4_VERDICT="BREACH(hang)";              oa_mark "i$i: *** $R4_VERDICT ***"; return 2; fi
    if (( sched > compl + timed )); then R4_VERDICT="BREACH(unmatched-scheduled $sched>$((compl+timed)))"; oa_mark "i$i: *** $R4_VERDICT ***"; return 2; fi
    # --- CURE vs CONTAIN ---
    if (( c2 == 0 )) && [[ "$st" == healthy ]] && (( timed == 0 )); then
        R4_VERDICT="CURED"
    elif (( timed >= 1 )) || [[ "$st" == lost-temporary ]]; then
        R4_VERDICT="CONTAINED"
    else
        R4_VERDICT="AMBIGUOUS(rc=$c2 state=$st)"
    fi
    [[ "$NEEDED_SLOT" == 1 && "$R4_VERDICT" == CURED ]] && R4_VERDICT="CURED(no-shallower-than-slot; NEEDED_SLOT)"
    oa_mark "i$i: VERDICT = $R4_VERDICT"
    { echo "iter=$i reset=$RESET verdict=$R4_VERDICT"; echo "c2=$c2 state=$st sched=$sched compl=$compl timed=$timed kfence=$kf needed_slot=$NEEDED_SLOT bar1_pre=$b1f"; } > "$OA_RUNDIR/i${i}-VERDICT.txt"; sync
    return 0
}

# re-establish clean 32GiB CUDA-functional substrate (rung3 recover_clean).
recover_clean() {
    local i="$1"
    oa_mark "i$i: RECOVER — host rmmod"
    host_unload "i${i}-recover" || oa_mark "i$i: RECOVER WARN — unload non-clean"
    oa_mark "i$i: RECOVER — TB deauth/reauth"
    echo 0 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 2
    echo 1 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 4
    oa_discover
    setpci -s "$OA_GPU_SHORT" COMMAND=0000 2>/dev/null
    oa_mark "i$i: RECOVER — fix-bar1 --bind + UVM bringup"
    timeout 180 "$FIXBAR1" --bind > "$OA_RUNDIR/i${i}-recover-fixbar1.log" 2>&1
    modprobe --ignore-install nvidia_uvm >>"$OA_RUNDIR/i${i}-recover.log" 2>&1
    nvidia-modprobe -u -c 0          >>"$OA_RUNDIR/i${i}-recover.log" 2>&1
    if ! oa_bar1_recovered; then oa_mark "i$i: RECOVER INCOMPLETE — BAR1=$(oa_bar1_mib) (verdict=$(oa_bar1_leg_diagnose))"; return 1; fi
    local h2d; h2d="$(workload_h2d "$i")"
    oa_mark "i$i: RECOVER H2D=${h2d:-<none>} GB/s"
    if [[ -z "$h2d" ]] || ! awk "BEGIN{exit !($h2d>1.0)}"; then oa_mark "i$i: RECOVER FAIL — CUDA (H2D=${h2d:-none})"; return 1; fi
    oa_mark "i$i: RECOVER OK — BAR1 32768, CUDA-functional (H2D=${h2d})"
    return 0
}

# ---- run ----
oa_mark "R4 start: reset=$RESET N=$N gap=${GAP}s bridge=$BRIDGE slot=$SLOT"
[[ -w "$KF_PARAM" ]] && { KF_SAVED="$(cat "$KF_PARAM")"; echo 1 > "$KF_PARAM" 2>/dev/null && oa_log "KFENCE sample_interval -> 1ms (was ${KF_SAVED})"; }
oa_drain_injector || oa_die "could not drain injector — aborting R4"
cleanup() { [[ -n "$KF_SAVED" && -w "$KF_PARAM" ]] && echo "$KF_SAVED" > "$KF_PARAM" 2>/dev/null; oa_restore_injector; }
trap cleanup EXIT

CURES=0; CONTAINS=0; INCONCL=0; FAILS=0; HALT=""
for i in $(seq 1 "$N"); do
    oa_mark "===== R4[$RESET] iter $i/$N START ====="
    if ! establish_precond "$i"; then FAILS=$((FAILS+1)); HALT="precond"; oa_passive_snapshot "i${i}-precond-fail"; break; fi
    fire_and_classify "$i"; frc=$?
    if (( frc == 2 )); then FAILS=$((FAILS+1)); HALT="$R4_VERDICT"; break; fi
    case "$R4_VERDICT" in
        CURED*)        CURES=$((CURES+1));;
        CONTAINED)     CONTAINS=$((CONTAINS+1));;
        INCONCLUSIVE*) INCONCL=$((INCONCL+1));;
        *)             INCONCL=$((INCONCL+1));;
    esac
    if ! recover_clean "$i"; then FAILS=$((FAILS+1)); HALT="recover"; break; fi
    oa_mark "===== R4[$RESET] iter $i/$N DONE (verdict=$R4_VERDICT) ====="
done

oa_mark "===== R4[$RESET] COMPLETE: cured=$CURES contained=$CONTAINS inconclusive=$INCONCL fails=$FAILS of $N${HALT:+ (halt:$HALT)} ====="
if (( FAILS == 0 )); then
    if   (( CURES > 0 && CONTAINS == 0 )); then av="CURES (reset cleared the divergence)"
    elif (( CONTAINS > 0 && CURES == 0 )); then av="CONTAIN-ONLY (divergence survived reset = #979-sticky at this depth)"
    elif (( CURES > 0 && CONTAINS > 0 )); then av="MIXED (cure not deterministic)"
    else av="INCONCLUSIVE (no clean cure/contain datapoint)"; fi
    oa_log "verdict [$RESET]: $av — cured=$CURES contained=$CONTAINS inconclusive=$INCONCL of $N"
else
    oa_log "verdict [$RESET]: NOT clean — FAIL ($HALT) — see $OA_RUNDIR"
fi
oa_log "forensics: $OA_RUNDIR"
