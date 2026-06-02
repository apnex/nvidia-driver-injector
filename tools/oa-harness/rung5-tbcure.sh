#!/usr/bin/env bash
# rung5-tbcure.sh — TB-tunnel recovery ISOLATION matrix: which userspace recovery
#                   operation CURES the F40-open GSP-lockdown divergence?
#   (deterministic-recovery validation #2; specs the in-driver E27/A9 recovery design)
#
# !!! BLOCKED — DO NOT RUN LIVE until task #292 lands. !!!
# 2026-06-02: `--variant tb-only 1` HARD-WEDGED the host (2 reboots). Root cause:
# cycle-1's clean close drives WPR2->0; apply_recovery's host_unload re-opens the
# chip (nvidia-smi -pm 0, line ~85) -> GSP boot from WPR2=0 on a #979-divergent chip
# -> gpuTimeoutCondWait lockdown poll -> rm_cleanup's BLOCKING rmapiLockAcquire +
# H-OA6 lock-inversion -> instant total wedge. A6/R0/C5 do NOT contain this (they
# were validated only on the WPR2-fast-fail twin). The experiment's re-open IS the
# trigger and can't be tweaked away -> blocked on the in-driver fix (#292).
# Forensics: docs/missions/.../wedge-2026-06-02-lockdown-reopen-forensics.md.
#
# Refined rmmod-based 2x2 factorial (TB-reauth × persist) on an identical base, so
# every differential changes exactly ONE operation (R4's tb-slot-vs-unbind-slot
# confounded teardown-method WITH TB-reauth; this does not). All variants:
#   rmmod (full nv_shutdown_adapter) -> [TB deauth/reauth] -> {BAR1 restore} ->
#   modprobe -> [persist] -> cycle-2 open -> classify cure|contain|inconclusive.
#
#   --variant base            : rmmod + fix-bar1(ReBAR+slot)            (no TB, no persist)
#                               *** does the proper shutdown+fix-bar1 itself cure? ***
#   --variant tb              : base + TB-reauth                        *** THE CRUX vs base ***
#   --variant persist         : base + persist (nvidia-smi -pm 1)
#   --variant tb-persist      : base + TB-reauth + persist              (== R1 bundle; should cure)
#   --variant tb-only         : rmmod + TB-reauth, NO ReBAR, NO slot    (INCONCLUSIVE-BAR1 by construction)
#   --variant tb-rebar-noslot : rmmod + TB-reauth + ReBAR write, NO slot(INCONCLUSIVE-BAR1 by construction)
#
# Anchors (established R4, CONTAIN-ONLY, do NOT re-run): none/rebind/flr/sbr(=A9's
# pci_reset_bus, recover.c:410)/slot. sbr CONTAIN-ONLY => A9-as-coded does not cure.
#
# Differentials: base-vs-tb isolates TB-reauth; base-vs-persist isolates persist;
# tb-only/tb-rebar-noslot isolate the BAR1-restore mechanism (slot re-enum) from the
# GSP cure (their GATE-3 BAR1-broken refusal IS the datapoint).
#
# ⚠️ REBOOT-RISK + A6-net (TB-reauth+fix-bar1 is the known-safe recovery op; lower
# than R4's flr/sbr hw-resets). A6 ENABLED, D0-pin, gap<5s, is_external==1 gate,
# KFENCE 1ms, injector drained. oa_mark fsyncs every wedge-capable step. CONSOLE.
#
# Usage: sudo tools/oa-harness/rung5-tbcure.sh --variant <v> [N]
#   N=1 smoke first per variant; n>=3 after the smoke is clean. Order:
#   tb-only -> tb-rebar-noslot (guard-smokes) -> base -> tb (crux) -> persist -> tb-persist.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

VARIANT=""; N=1
while [[ $# -gt 0 ]]; do case "$1" in
    --variant) VARIANT="$2"; shift 2;;
    [0-9]*) N="$1"; shift;;
    *) oa_die "unknown arg $1";; esac; done
case "$VARIANT" in base|tb|persist|tb-persist|tb-only|tb-rebar-noslot) ;; *) oa_die "need --variant {base|tb|persist|tb-persist|tb-only|tb-rebar-noslot}";; esac

# decompose the variant into the 3 composable knobs
WANT_TB=0; BAR1_METHOD=fixbar1; WANT_PERSIST=0
case "$VARIANT" in
    base)            WANT_TB=0; BAR1_METHOD=fixbar1; WANT_PERSIST=0;;
    tb)              WANT_TB=1; BAR1_METHOD=fixbar1; WANT_PERSIST=0;;
    persist)         WANT_TB=0; BAR1_METHOD=fixbar1; WANT_PERSIST=1;;
    tb-persist)      WANT_TB=1; BAR1_METHOD=fixbar1; WANT_PERSIST=1;;
    tb-only)         WANT_TB=1; BAR1_METHOD=none;    WANT_PERSIST=0;;
    tb-rebar-noslot) WANT_TB=1; BAR1_METHOD=rebar;   WANT_PERSIST=0;;
esac

FIXBAR1="$OA_REPO_ROOT/tools/fix-bar1.sh"
DIAG_COMPOSE="$OA_REPO_ROOT/diag/docker-compose.yml"
KF_PARAM=/sys/module/kfence/parameters/sample_interval
KF_SAVED=""
GAP=2
REBAR_CTRL=0x13c
REBAR_VAL=0x00000f21

oa_discover
oa_init_run "r5-tbcure-${VARIANT}"
oa_assert_r0
[[ -x "$FIXBAR1" ]] || oa_die "fix-bar1.sh not executable"
[[ $EUID -eq 0 ]] || oa_die "must run as root"

IS_EXT() { cat "/sys/bus/pci/devices/$OA_GPU/tb_egpu_is_external" 2>/dev/null || echo '?'; }

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

# healthy no-persistence divergent-ready substrate (identical to rung4 establish_precond)
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
    oa_assert_a6; oa_pin_d0
    [[ "$(IS_EXT)" == 1 ]] || { oa_mark "i$i: PRECOND FAIL — is_external=$(IS_EXT)"; return 1; }
    oa_mark "i$i: PRECOND ready — no-persist, A6 armed, D0-pinned, is_external=1"
    return 0
}

# the composable recovery: rmmod -> [TB] -> {BAR1} -> modprobe -> [persist].
# returns 0 ok / 3 device-gone-reboot.
apply_recovery() {
    local i="$1"
    oa_passive_snapshot "i${i}-pre-recovery"
    oa_mark "i$i: RECOVERY[$VARIANT] — host rmmod (full nv_shutdown_adapter)"
    host_unload "i${i}-recovery" || { oa_mark "i$i: RECOVERY FAIL — module still loaded"; return 1; }
    if (( WANT_TB )); then
        oa_mark "i$i: RECOVERY — TB deauth/reauth"
        echo 0 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 2
        echo 1 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 4
        oa_discover
    fi
    if ! [[ -e "/sys/bus/pci/devices/$OA_GPU" ]]; then oa_mark "i$i: DEVICE GONE — reboot"; oa_passive_snapshot "i${i}-device-gone"; return 3; fi
    setpci -s "$OA_GPU_SHORT" COMMAND=0000 2>/dev/null
    case "$BAR1_METHOD" in
        fixbar1)
            oa_mark "i$i: RECOVERY — fix-bar1 (bare: ReBAR + slot-cycle)"
            timeout 180 "$FIXBAR1" > "$OA_RUNDIR/i${i}-recovery-fixbar1.log" 2>&1 ;;
        rebar)
            oa_mark "i$i: RECOVERY — ReBAR CTRL write ONLY (no slot-cycle; expect ENOSPC/BAR1-broken)"
            setpci -s "$OA_GPU_SHORT" "${REBAR_CTRL}.l=${REBAR_VAL}" 2>/dev/null; sleep 1 ;;
        none)
            oa_mark "i$i: RECOVERY — no BAR1 restore (bare TB-reauth; expect BAR1-broken)" ;;
    esac
    oa_mark "i$i: RECOVERY — modprobe nvidia (NO persistence)"
    echo '' > "/sys/bus/pci/devices/$OA_GPU/driver_override" 2>/dev/null
    modprobe --ignore-install nvidia >>"$OA_RUNDIR/i${i}-recovery.log" 2>&1
    sleep 2
    local drv; drv="$(basename "$(readlink "/sys/bus/pci/devices/$OA_GPU/driver" 2>/dev/null || echo none)")"
    [[ "$drv" == nvidia ]] || oa_mark "i$i: RECOVERY WARN — nvidia did not bind ($drv) [may be expected on broken BAR1]"
    if (( WANT_PERSIST )); then
        oa_mark "i$i: RECOVERY — persist (nvidia-smi -pm 1) before cycle-2"
        timeout 15 nvidia-smi -pm 1 >"$OA_RUNDIR/i${i}-persist.log" 2>&1 || oa_mark "i$i: persist rc=$? (may fail on divergent chip)"
    fi
    return 0
}

# pre-fire gates + cycle-2 + classify (identical logic to rung4-cure.sh). Sets R5_VERDICT.
# returns 0 classified, 2 = containment BREACH (halt).
R5_VERDICT=""
fire_and_classify() {
    local i="$1"
    oa_mark "i$i: cycle-1 (nvidia-smi -L — destructive close)"
    timeout 20 nvidia-smi -L > "$OA_RUNDIR/i${i}-cycle1.txt" 2>&1
    apply_recovery "$i"; local arc=$?
    if (( arc == 3 )); then R5_VERDICT="ABORT(device-gone)"; return 2; fi
    if (( arc == 1 )); then R5_VERDICT="PRECOND/RECOVERY-FAIL"; return 2; fi
    oa_assert_a6; oa_pin_d0
    local active isext b1f
    active="$(cat /sys/bus/pci/devices/$OA_GPU/power/runtime_status 2>/dev/null)"
    isext="$(IS_EXT)"; b1f="$(oa_bar1_mib)"
    oa_mark "i$i: pre-fire gates: is_external=$isext runtime_status=$active BAR1=${b1f}MiB"
    oa_passive_snapshot "i${i}-pre-cycle2"
    if [[ "$isext" != 1 ]]; then R5_VERDICT="INCONCLUSIVE(a9-regressed:is_external=$isext)"; oa_mark "i$i: REFUSE FIRE — $R5_VERDICT"; return 0; fi
    if [[ "$active" != active ]]; then R5_VERDICT="INCONCLUSIVE(not-D0:$active)"; oa_mark "i$i: REFUSE FIRE — $R5_VERDICT"; return 0; fi
    if [[ "$b1f" -lt "$OA_BAR1_MIN_MIB" ]]; then R5_VERDICT="INCONCLUSIVE(BAR1-broken:${b1f}MiB)"; oa_mark "i$i: REFUSE FIRE — $R5_VERDICT (the no-slot-restore datapoint)"; return 0; fi
    # --- cycle-2 fire ---
    sleep "$GAP"
    local fb; fb="$(cat /sys/bus/pci/devices/$OA_GPU/tb_egpu_f40b_fires 2>/dev/null || echo -1)"
    oa_mark "i$i: cycle-2 FIRE (exec open /dev/nvidia0) <<< cure point"
    local t0 t1 c2; t0=$(date +%s.%N)
    timeout 10 bash -c 'exec 3</dev/nvidia0'; c2=$?
    t1=$(date +%s.%N)
    oa_mark "i$i: cycle-2 RETURNED rc=$c2 dt=$(awk "BEGIN{printf \"%.0f\",($t1-$t0)*1000}")ms — host SURVIVED"
    oa_mark "i$i: post-fire BAR1=$(oa_bar1_mib)MiB"
    local fa; fa="$(cat /sys/bus/pci/devices/$OA_GPU/tb_egpu_f40b_fires 2>/dev/null || echo -1)"
    dmesg | awk -v m="i${i}: cycle-2 FIRE" 'index($0,m){f=1} f' > "$OA_RUNDIR/i${i}-cycle2-dmesg.txt"; sync
    local sched compl timed kf st
    sched=$(grep -ac 'open scheduled to bounded worker' "$OA_RUNDIR/i${i}-cycle2-dmesg.txt")
    compl=$(grep -ac 'open completed within budget'     "$OA_RUNDIR/i${i}-cycle2-dmesg.txt")
    timed=$(grep -ac 'open timed out after'             "$OA_RUNDIR/i${i}-cycle2-dmesg.txt")
    kf=$(grep -acE 'KFENCE: (use-after-free|memory corruption|out-of-bounds)' "$OA_RUNDIR/i${i}-cycle2-dmesg.txt")
    st="$(cat /sys/bus/pci/devices/$OA_GPU/tb_egpu_state 2>/dev/null || echo '?')"
    oa_mark "i$i: dmesg sched=$sched compl=$compl timed=$timed kfence=$kf state=$st f40b_fires:${fb}->${fa}"
    oa_passive_snapshot "i${i}-post-fire"
    if (( kf > 0 )); then R5_VERDICT="BREACH(KFENCE-UAF)"; oa_mark "i$i: *** $R5_VERDICT ***"; return 2; fi
    if (( c2 == 124 )); then R5_VERDICT="BREACH(hang)"; oa_mark "i$i: *** $R5_VERDICT ***"; return 2; fi
    if (( sched > compl + timed )); then R5_VERDICT="BREACH(unmatched-scheduled $sched>$((compl+timed)))"; oa_mark "i$i: *** $R5_VERDICT ***"; return 2; fi
    if (( c2 == 0 )) && [[ "$st" == healthy ]] && (( timed == 0 )); then R5_VERDICT="CURED"
    elif (( timed >= 1 )) || [[ "$st" == lost-temporary ]]; then R5_VERDICT="CONTAINED"
    else R5_VERDICT="AMBIGUOUS(rc=$c2 state=$st)"; fi
    oa_mark "i$i: VERDICT[$VARIANT] = $R5_VERDICT"
    { echo "iter=$i variant=$VARIANT verdict=$R5_VERDICT c2=$c2 state=$st sched=$sched compl=$compl timed=$timed kfence=$kf bar1_pre=$b1f"; } > "$OA_RUNDIR/i${i}-VERDICT.txt"; sync
    return 0
}

recover_clean() {
    local i="$1"
    oa_mark "i$i: RECOVER(clean) — host rmmod"
    host_unload "i${i}-cleanrecover" || oa_mark "i$i: RECOVER WARN — unload non-clean"
    oa_mark "i$i: RECOVER(clean) — TB deauth/reauth"
    echo 0 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 2
    echo 1 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 4
    oa_discover
    setpci -s "$OA_GPU_SHORT" COMMAND=0000 2>/dev/null
    oa_mark "i$i: RECOVER(clean) — fix-bar1 --bind + UVM"
    timeout 180 "$FIXBAR1" --bind > "$OA_RUNDIR/i${i}-cleanrecover-fixbar1.log" 2>&1
    modprobe --ignore-install nvidia_uvm >>"$OA_RUNDIR/i${i}-cleanrecover.log" 2>&1
    nvidia-modprobe -u -c 0          >>"$OA_RUNDIR/i${i}-cleanrecover.log" 2>&1
    if ! oa_bar1_recovered; then oa_mark "i$i: RECOVER INCOMPLETE — BAR1=$(oa_bar1_mib) (verdict=$(oa_bar1_leg_diagnose))"; return 1; fi
    local h2d; h2d="$(workload_h2d "$i")"
    oa_mark "i$i: RECOVER H2D=${h2d:-<none>} GB/s"
    [[ -n "$h2d" ]] && awk "BEGIN{exit !($h2d>1.0)}" || { oa_mark "i$i: RECOVER FAIL — CUDA (H2D=${h2d:-none})"; return 1; }
    oa_mark "i$i: RECOVER OK — BAR1 32768, CUDA-functional (H2D=${h2d})"
    return 0
}

# ---- run ----
oa_mark "R5 start: variant=$VARIANT (TB=$WANT_TB BAR1=$BAR1_METHOD PERSIST=$WANT_PERSIST) N=$N gap=${GAP}s"
[[ -w "$KF_PARAM" ]] && { KF_SAVED="$(cat "$KF_PARAM")"; echo 1 > "$KF_PARAM" 2>/dev/null && oa_log "KFENCE -> 1ms (was ${KF_SAVED})"; }
oa_drain_injector || oa_die "could not drain injector — aborting R5"
cleanup() { [[ -n "$KF_SAVED" && -w "$KF_PARAM" ]] && echo "$KF_SAVED" > "$KF_PARAM" 2>/dev/null; oa_restore_injector; }
trap cleanup EXIT

CURES=0; CONTAINS=0; INCONCL=0; FAILS=0; HALT=""
for i in $(seq 1 "$N"); do
    oa_mark "===== R5[$VARIANT] iter $i/$N START ====="
    if ! establish_precond "$i"; then FAILS=$((FAILS+1)); HALT="precond"; oa_passive_snapshot "i${i}-precond-fail"; break; fi
    fire_and_classify "$i"; frc=$?
    if (( frc == 2 )); then FAILS=$((FAILS+1)); HALT="$R5_VERDICT"; break; fi
    case "$R5_VERDICT" in
        CURED*)        CURES=$((CURES+1));;
        CONTAINED)     CONTAINS=$((CONTAINS+1));;
        *)             INCONCL=$((INCONCL+1));;
    esac
    if ! recover_clean "$i"; then FAILS=$((FAILS+1)); HALT="recover"; break; fi
    oa_mark "===== R5[$VARIANT] iter $i/$N DONE (verdict=$R5_VERDICT) ====="
done

oa_mark "===== R5[$VARIANT] COMPLETE: cured=$CURES contained=$CONTAINS inconclusive=$INCONCL fails=$FAILS of $N${HALT:+ (halt:$HALT)} ====="
if (( FAILS == 0 )); then
    if   (( CURES > 0 && CONTAINS == 0 )); then av="CURES (this op-set clears the divergence)"
    elif (( CONTAINS > 0 && CURES == 0 )); then av="CONTAIN-ONLY (divergence survives this op-set)"
    elif (( CURES > 0 && CONTAINS > 0 )); then av="MIXED (non-deterministic)"
    else av="INCONCLUSIVE (BAR1-broken-by-construction or no clean datapoint)"; fi
    oa_log "verdict [$VARIANT]: $av — cured=$CURES contained=$CONTAINS inconclusive=$INCONCL of $N"
else
    oa_log "verdict [$VARIANT]: NOT clean — FAIL ($HALT) — see $OA_RUNDIR"
fi
oa_log "forensics: $OA_RUNDIR"
