#!/usr/bin/env bash
# rung-a10v2-validate.sh — validate the A10-v2 (F44) completion-state
# discriminator on the LIVE apnex.28 driver. Supersedes rung6-a10-validate.sh
# (which targeted A10-v1 / apnex.26 and conflated the A6 timeout into a single
# "lockdown-substrate" bucket). A10-v2 splits the A6 open-timeout into TWO arms
# with NEW dmesg lines; this runner classifies and gates each arm correctly.
#
# Hardened 2026-06-04 after a 4-lens adversarial review (workflow ws2kgirub):
# fixed a Ctrl-C param-strand that could disable the production GPU, replaced a
# non-discriminating next-open gate with a passive config-space sink probe,
# broadened the KFENCE detector, made the dmesg anchor honest, and removed an
# nvidia-smi touch on a sunk chip. See docs/patch-intents/A10-f40b-lockfree-sink.md.
#
# ============================ THE TWO ARMS =================================
# On the A6 open bounded-wait timeout for an external GPU, A10-v2 re-waits a
# bounded grace (NVreg_TbEgpuOpenGraceMs) then branches on whether the worker
# returned:
#   FAST-FAIL (worker returned within grace) -> dmesg "...chip NOT sunk
#     (recoverable)"; A10-v2 SKIPS both sinks. THE REGRESSION FIX: the deployed
#     pre-v2 driver permanently dead-bused the chip here (C5's own
#     os_pci_set_disconnected). PROOF it is fixed = the chip's PCI bus is NOT
#     disconnected: a passive config read still returns vendor 0x10de (a sunk
#     chip returns 0xffff), corroborated by drgn error_state==io_normal when
#     available. (next-open rc=0 alone is NOT sufficient — see "WHY config-probe".)
#   LOCKDOWN  (worker still stuck after grace) -> dmesg "...GSP lockdown poll
#     ... dead-bus marker + sink"; A10-v2 sets the lock-free marker FIRST so the
#     worker's poll self-terminates, flush_work joins in ~ms, host STAYS ALIVE.
#     Pre-v2 this HARD-WEDGED the host (2 reboots 2026-06-02). The sink here is
#     INTENTIONAL; recover via fix-bar1.
#
# ======================== SUBSTRATE != ARM (READ) =========================
# WPR2-UP at re-open  -> worker bails rm_init_adapter at the WPR2 check -> the
#                        FAST-FAIL arm. rm_init never enters the multi-second GSP
#                        bootstrap poll, so no stuck-worker wedge; worst case a
#                        wrong sink = recoverable.
# WPR2-CLEAR at re-open -> worker enters kgspBootstrap_GH100 -> gpuTimeoutCondWait
#                        on a #979-divergent chip that never releases lockdown ->
#                        the LOCKDOWN arm. RISKY: the genuine wedge bet.
#
# The fast-fail DISCRIMINATOR cannot be forced on healthy hardware via the
# divergent WPR2-up-after-failed-init state (stochastic / needs the fake-5090 F44
# model, #290). So `fastfail` mode triggers the SAME skip-sink code path
# deterministically: it lowers NVreg_TbEgpuOpenTimeoutMs below a healthy init's
# duration and raises the grace high, so a HEALTHY first-open trips the A6 timeout
# and the worker (healthy init) returns within grace -> the EXACT "chip NOT sunk"
# branch runs. The discriminator only checks completion-within-grace (not WHY the
# worker returned), so this faithfully exercises the regression fix; the pre-v2
# driver would dead-bus the healthy chip on this induced timeout, A10-v2 does not.
#
# WEDGE RISK (honest): fastfail is wedge-risk-BOUNDED, not zero. A stochastic H16
# cold-bringup transient could route a fastfail open to the LOCKDOWN arm; if it
# does, the chip is sunk RECOVERABLY (fix-bar1) — but that arm is the same
# containment still being live-validated (task #297), so until C6+A11+A10-v2 is
# signed off, run with the operator at the console. A lockdown fire in fastfail
# mode is therefore treated as a HARD ANOMALY (halt), not a contained pass.
#
# ============================== MODES =====================================
#   fastfail  (DEFAULT, deterministic, wedge-risk-bounded): induced-timeout
#             healthy re-open -> assert "chip NOT sunk" + config vendor 0x10de
#             (bus NOT disconnected) + next-open rc=0. tb_egpu_state will read
#             lost-temporary post-fire (A8 marks it on EVERY A6 fire, by design;
#             the gate only rejects lost-permanent / a disconnected bus).
#   lockdown  (RISKY, explicit): rung6 substrate — no-persist clean LAST-CLOSE
#             drives WPR2->0, then a real-timing re-open enters the bootstrap
#             poll. Assert host ALIVE + "GSP lockdown poll" line + bounded dt +
#             sink (expected) + recover via fix-bar1. *** CAN HARD-WEDGE if
#             A10-v2's lockdown arm is wrong. USER AT CONSOLE. kdump CANNOT
#             capture this; recovery=reboot. ***
#
# WHY config-probe (not next-open) is the fast-fail proof: on the fast-fail arm
# the worker COMPLETED RmInitAdapter, so NV_FLAG_INITIALIZED is set and the NEXT
# open skips nv_start_device and returns rc=0 WITHOUT touching the bus — even if
# the bus were sunk. So next-open rc=0 cannot distinguish "sink skipped" from
# "sink fired but adapter still initialised". The C5 sink sets
# pci_channel_io_perm_failure on pdev; a passive config read of a disconnected
# pdev returns 0xffff (kernel pci_dev_is_disconnected gate). That config read is
# the authoritative, drgn-free, passive-safe sink discriminator.
#
# PREREQ: loaded module == 595.71.05-apnex.28 (C6+A11+A10-v2). Injector DS is
# drained for the whole run (this runner owns the module lifecycle). Passive-only
# observability on a maybe-sunk chip (BAR1/config-via-sysfs FIRST; never
# nvidia-smi/MMIO on a suspected-wedged or broken-BAR1 chip).
#
# Usage:  sudo tools/oa-harness/rung-a10v2-validate.sh [fastfail|lockdown] [N]
#         (defaults: mode=fastfail  N=3;  N must be an integer >= 3)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

MODE="${1:-fastfail}"
N="${2:-3}"
case "$MODE" in fastfail|lockdown) ;; *) oa_die "mode must be 'fastfail' or 'lockdown' (got '$MODE')";; esac
[[ "$N" =~ ^[0-9]+$ && "$N" -ge 3 ]] || oa_die "N must be an integer >= 3 (got '$N'); the regression gate needs n>=3"

A10_VER="${A10_VER:-595.71.05-apnex.29}"   # expected current ship version (env-overridable; for the start banner). The precond gate accepts any apnex.28+ A10-v2 build.
FIXBAR1="$OA_REPO_ROOT/tools/fix-bar1.sh"
DRGN_HELPER="$HERE/drgn-error-state.py"
KF_PARAM=/sys/module/kfence/parameters/sample_interval
KF_SAVED=""
TO_PARAM=/sys/module/nvidia/parameters/NVreg_TbEgpuOpenTimeoutMs
GR_PARAM=/sys/module/nvidia/parameters/NVreg_TbEgpuOpenGraceMs
TO_SAVED=""; GR_SAVED=""
FF_TO="${FF_TO:-1}"     # fastfail induced timeout (ms): default 1 = any real init >1ms trips A6.
                        # Env-overridable for a BUDGET-VERIFY run: set FF_TO to a production-
                        # candidate budget (e.g. 3000) so a healthy ~1.3s init completes
                        # WITHIN budget -> "open completed within budget rc=0" (the inbudget
                        # branch), proving the open succeeds instead of tripping+sinking.
FF_GR="${FF_GR:-30000}" # fastfail grace (ms): default 30000 so a slow-but-healthy init is NOT
                        # wrongly sunk; only a genuinely-stuck worker reaches the lockdown arm.
                        # Env-overridable (e.g. FF_GR=2000) to verify a candidate grace.
REOPEN_TIMEOUT=45   # > FF_GR + headroom and >> any contained lockdown self-terminate
FIRE_PID=""         # tracked so the INT/TERM trap can reap an in-flight fire
CLEANED=""

oa_discover
oa_init_run "ra10v2-${MODE}"
oa_assert_r0
[[ -x "$FIXBAR1" ]] || oa_die "fix-bar1.sh not executable"
[[ $EUID -eq 0 ]] || oa_die "must run as root"

IS_EXT()    { cat "/sys/bus/pci/devices/$OA_GPU/tb_egpu_is_external" 2>/dev/null || echo '?'; }
TB_STATE()  { cat "/sys/bus/pci/devices/$OA_GPU/tb_egpu_state"       2>/dev/null || echo '?'; }
# chip_vendor — PASSIVE config-space read (config TLP only; safe on a sunk chip).
# 0x10de = bus alive (NOT disconnected); ffff = sunk/disconnected; other = unknown.
chip_vendor() { setpci -s "$OA_GPU_SHORT" 0x00.w 2>/dev/null | tr 'A-F' 'a-f'; }

# dmesg_since <needle> — print only dmesg lines AFTER the LAST line containing
# <needle>. Empty if the needle is absent (caller treats empty as anchor-lost and
# classifies INCONCLUSIVE rather than fabricating a verdict from stale lines).
dmesg_since() {
    local needle="$1"
    dmesg 2>/dev/null | awk -v n="$needle" 'index($0,n){buf=""; seen=1; next} {if(seen)buf=buf $0 "\n"} END{printf "%s", buf}'
}

# best-effort authoritative error_state (drgn). Echoes the state name or n/a.
drgn_error_state() {
    local out
    out="$(timeout 30 drgn "$DRGN_HELPER" "$OA_GPU" 2>/dev/null | grep '^ERROR_STATE' | head -1)"
    if [[ -n "$out" ]]; then echo "${out##*name=}"; else echo "n/a(drgn-unavailable)"; fi
}

host_unload() {
    local tag="$1" m
    # PASSIVE-FIRST: NO nvidia-smi here. This runner never engages persistence, so
    # `nvidia-smi -pm 0` is vestigial — and host_unload is also called by
    # recover_clean AFTER a lockdown sink, where issuing MMIO/RPC on a just-sunk
    # chip violates the no-rpc-on-broken-bar1 rule. rmmod alone unloads.
    sync
    for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
        [[ -d /sys/module/$m ]] && timeout 30 rmmod "$m" >>"$OA_RUNDIR/${tag}-unload.log" 2>&1
    done
    [[ ! -d /sys/module/nvidia ]]
}

# establish_precond — leave a healthy, NO-persistence, A10-v2 chip with the
# adapter NOT yet initialized (so the FIRST open triggers the lazy RmInitAdapter
# through the A6 bounded worker). Heavy TB-reauth+fix-bar1 ONLY if BAR1 is broken.
establish_precond() {
    local i="$1"
    oa_mark "i$i: PRECOND — host rmmod"
    host_unload "i${i}-precond" || { oa_mark "i$i: PRECOND FAIL — module still loaded"; return 1; }
    if ! oa_bar1_ok; then
        oa_mark "i$i: PRECOND — BAR1=$(oa_bar1_mib)MiB broken -> TB deauth/reauth + fix-bar1"
        echo 0 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 2
        echo 1 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 4
        oa_discover
        setpci -s "$OA_GPU_SHORT" COMMAND=0000 2>/dev/null
        timeout 180 "$FIXBAR1" > "$OA_RUNDIR/i${i}-precond-fixbar1.log" 2>&1
        oa_bar1_ok || { oa_mark "i$i: PRECOND FAIL — BAR1 not 32GiB ($(oa_bar1_mib)MiB)"; return 1; }
    else
        oa_mark "i$i: PRECOND — BAR1 already 32GiB, skip TB-reauth (no thrash on a healthy chip)"
    fi
    oa_mark "i$i: PRECOND — modprobe nvidia (NO persistence)"
    echo '' > "/sys/bus/pci/devices/$OA_GPU/driver_override" 2>/dev/null
    modprobe --ignore-install nvidia >>"$OA_RUNDIR/i${i}-precond.log" 2>&1
    sleep 2
    local ver; ver="$(cat /sys/module/nvidia/version 2>/dev/null)"
    [[ "$ver" =~ ^595\.71\.05-apnex\.(2[89]|[3-9][0-9])$ ]] || { oa_mark "i$i: PRECOND FAIL — loaded '$ver' is not an A10-v2 build (need apnex.28+; expected ~$A10_VER)"; return 1; }
    local drv; drv="$(basename "$(readlink "/sys/bus/pci/devices/$OA_GPU/driver" 2>/dev/null || echo none)")"
    [[ "$drv" == nvidia ]] || { oa_mark "i$i: PRECOND FAIL — nvidia did not bind ($drv)"; return 1; }
    oa_assert_a6; oa_pin_d0
    [[ "$(IS_EXT)" == 1 ]] || { oa_mark "i$i: PRECOND FAIL — is_external=$(IS_EXT)"; return 1; }
    [[ -r "$TO_PARAM" && -w "$TO_PARAM" && -r "$GR_PARAM" && -w "$GR_PARAM" ]] \
        || { oa_mark "i$i: PRECOND FAIL — timeout/grace params not writable (A10-v2 absent?)"; return 1; }
    # Ensure /dev/nvidia0 exists WITHOUT initialising the adapter. A pure `mknod`
    # (from the registered major) creates the node with NO open/probe, so the
    # RmInitAdapter still happens on OUR timed open — unlike nvidia-modprobe.
    if [[ ! -e /dev/nvidia0 ]]; then
        local maj; maj="$(awk '$2=="nvidia"{print $1; exit}' /proc/devices)"
        if [[ -n "$maj" ]]; then
            mknod /dev/nvidia0 c "$maj" 0 >>"$OA_RUNDIR/i${i}-precond.log" 2>&1
        else
            nvidia-modprobe -c 0 >>"$OA_RUNDIR/i${i}-precond.log" 2>&1
        fi
    fi
    [[ -e /dev/nvidia0 ]] || { oa_mark "i$i: PRECOND FAIL — /dev/nvidia0 absent (node creation failed)"; return 1; }
    oa_mark "i$i: PRECOND ready — A10-v2 ($ver), no-persist, A6 armed, D0-pinned, is_external=1, tb_state=$(TB_STATE), adapter-uninit, /dev/nvidia0 present"
    return 0
}

# fire a bounded open in the BACKGROUND and `wait` on it IN THE PARENT SHELL, so
# an INT/TERM during the fire interrupts `wait` and runs the cleanup trap (a
# foreground child defers the signal and would strand the lowered params; a
# process-substitution subshell would hide FIRE_PID from the parent's trap). The
# function runs in the parent shell and returns via globals FIRE_RC / FIRE_DT.
FIRE_RC=""; FIRE_DT=""
timed_open() {
    local fd="$1" t0 t1
    t0=$(date +%s.%N)
    timeout "$REOPEN_TIMEOUT" bash -c "exec ${fd}</dev/nvidia0" & FIRE_PID=$!
    wait "$FIRE_PID"; FIRE_RC=$?
    FIRE_PID=""
    t1=$(date +%s.%N)
    FIRE_DT=$(awk "BEGIN{printf \"%.0f\",($t1-$t0)*1000}")
}

# count KFENCE/KASAN breach reports in a file (ALL classes, not just UAF — a
# double-free of nvlfp surfaces as 'invalid free', a recycled-object write as
# 'invalid access'; both are the F42 shapes the flush_work guard exists to stop).
kfence_count() { grep -acE 'BUG: (KFENCE|KASAN):' "$1" 2>/dev/null; }

RESULT=""
# ---------------- fast-fail arm (deterministic, wedge-risk-bounded) --------
fire_fastfail() {
    local i="$1"
    TO_SAVED="$(cat "$TO_PARAM")"; GR_SAVED="$(cat "$GR_PARAM")"
    # breadcrumb: if any uncaught exit strands the params, this is the un-strand cmd
    { echo "# oa: restore stranded open timeout/grace (run if the GPU returns -EIO on every open):";
      echo "echo $TO_SAVED > $TO_PARAM"; echo "echo $GR_SAVED > $GR_PARAM"; } > "$OA_RUNDIR/RESTORE-PARAMS.txt"; sync
    echo "$FF_TO" > "$TO_PARAM"; echo "$FF_GR" > "$GR_PARAM"
    oa_mark "i$i: ff mode bits set timeout=${FF_TO}ms grace=${FF_GR}ms (healthy open trips A6, worker returns within grace)"
    local sentinel="oa-mark: i$i: FF-FIRE-SENTINEL"
    oa_mark "i$i: FF-FIRE-SENTINEL"
    dmesg 2>/dev/null | grep -q "i$i: FF-FIRE-SENTINEL" || oa_mark "i$i: WARN — FF sentinel did not mirror to kmsg; will classify anchor-lost INCONCLUSIVE"
    oa_mark "i$i: FAST-FAIL FIRE (lazy first-open /dev/nvidia0, timeout ${REOPEN_TIMEOUT}s) — induced A6 timeout"
    timed_open 3; local rc="$FIRE_RC" dt="$FIRE_DT"
    local st_after; st_after="$(TB_STATE)"
    oa_mark "i$i: FAST-FAIL FIRE returned rc=$rc dt=${dt}ms tb_state=$st_after — HOST SURVIVED"
    # restore production timing BEFORE the next-open gate; drop the breadcrumb
    echo "$TO_SAVED" > "$TO_PARAM"; echo "$GR_SAVED" > "$GR_PARAM"; TO_SAVED=""; GR_SAVED=""
    rm -f "$OA_RUNDIR/RESTORE-PARAMS.txt" 2>/dev/null
    local slice="$OA_RUNDIR/i${i}-ff-dmesg.txt"
    dmesg_since "$sentinel" > "$slice"; sync
    local anchor_lost=0; grep -q . "$slice" || anchor_lost=1
    local notsunk lockdown inbudget timed kf
    notsunk=$(grep -ac 'chip NOT sunk'             "$slice")
    lockdown=$(grep -ac 'GSP lockdown poll'        "$slice")
    inbudget=$(grep -ac 'open completed within budget' "$slice")
    timed=$(grep -ac 'open timed out after'        "$slice")
    kf=$(kfence_count "$slice")
    (( anchor_lost )) && kf=$(( kf + $(dmesg 2>/dev/null | tail -400 | grep -acE 'BUG: (KFENCE|KASAN):') ))   # backstop
    oa_mark "i$i: ff dmesg notsunk=$notsunk lockdown=$lockdown inbudget=$inbudget timed=$timed kfence=$kf rc=$rc dt=${dt}ms anchor_lost=$anchor_lost"
    oa_passive_snapshot "i${i}-ff-postfire"
    if (( kf > 0 )); then RESULT="BREACH(KFENCE/KASAN)"; oa_mark "i$i: *** $RESULT ***"; return 2; fi
    if (( rc == 124 )); then RESULT="FAIL(bounded-open did not return in ${REOPEN_TIMEOUT}s — sink path wedged)"; oa_mark "i$i: *** $RESULT ***"; return 2; fi
    if (( anchor_lost )); then RESULT="inconclusive(anchor-lost)"; oa_mark "i$i: ff anchor lost — cannot classify this fire"; return 0; fi
    if (( lockdown >= 1 )); then
        # A healthy induced open should NEVER reach the lockdown arm. If it did,
        # A10-v2 just SANK a healthy chip — a hard anomaly, NOT a contained pass.
        RESULT="fastfail-ANOMALY(SAFE-mode sank a healthy chip; tb_state=$st_after dt=${dt}ms)"
        oa_mark "i$i: *** $RESULT *** — ff fire took the LOCKDOWN arm; recover via fix-bar1. Halting."
        return 2
    fi
    if (( notsunk >= 1 )); then
        # the discriminator ran the skip-sink path. PROVE the bus was NOT disconnected.
        local vend es; vend="$(chip_vendor)"; es="$(drgn_error_state)"
        oa_mark "i$i: SINK-PROBE (passive) config-vendor=0x${vend:-??} drgn-error_state=$es"
        local sunk=unknown
        case "$vend" in 10de) sunk=no;; ffff) sunk=yes;; esac
        case "$es" in *io_perm_failure*|*io_frozen*) sunk=yes;; *io_normal*) [[ "$sunk" != yes ]] && sunk=no;; esac
        timed_open 4; local rc2="$FIRE_RC" dt2="$FIRE_DT"   # secondary liveness only
        oa_mark "i$i: NEXT-OPEN (secondary) rc=$rc2 dt=${dt2}ms; sink-determination=$sunk"
        if [[ "$sunk" == yes ]]; then
            RESULT="fastfail-FAIL(sink fired: vendor=0x$vend es=$es — the C5 dead-bus regression SURVIVED)"
            oa_mark "i$i: *** $RESULT ***"; return 2
        elif [[ "$sunk" == no ]] && (( rc2 == 0 )); then
            RESULT="fastfail-PASS"
            oa_mark "i$i: *** A10-v2 FAST-FAIL VALIDATED *** chip NOT sunk on induced timeout: config-vendor=0x$vend (bus alive), es=$es, next-open rc=0, tb_state=$st_after (lost-temporary expected; gate rejects only lost-permanent/disconnected). Pre-v2 would have dead-bused here."
        elif [[ "$sunk" == unknown ]]; then
            RESULT="fastfail-INCONCLUSIVE(no authoritative sink read: vendor=0x$vend es=$es rc2=$rc2; install kernel-core debuginfo for drgn)"
            oa_mark "i$i: $RESULT"; return 0
        else
            RESULT="fastfail-FAIL(bus alive but next-open rc=$rc2: vendor=0x$vend es=$es)"
            oa_mark "i$i: *** $RESULT ***"; return 2
        fi
    elif (( inbudget >= 1 && timed == 0 )); then
        RESULT="inbudget(discriminator-not-exercised: init <${FF_TO}ms)"
        oa_mark "i$i: ff fire completed within ${FF_TO}ms budget — A6 not tripped; not a regression datapoint"
    else
        RESULT="ambiguous(rc=$rc notsunk=$notsunk timed=$timed)"
        oa_mark "i$i: ff ambiguous — no chip-NOT-sunk / lockdown / in-budget marker"
    fi
    return 0
}

# ---------------- lockdown arm (RISKY, explicit) ---------------------------
fire_lockdown() {
    local i="$1"
    local sentinel="oa-mark: i$i: LD-CYCLE1-SENTINEL"
    oa_mark "i$i: LD-CYCLE1-SENTINEL"
    oa_mark "i$i: cycle-1 (nvidia-smi -L — clean no-persist LAST-CLOSE drives WPR2->0 = lockdown substrate)"
    timeout 25 nvidia-smi -L > "$OA_RUNDIR/i${i}-cycle1.txt" 2>&1
    sleep 1
    local wpr2; wpr2="$(dmesg_since "$sentinel" | grep 'site=post-shutdown' | tail -1 | grep -oE 'WPR2=0x[0-9a-f]+' | tail -1)"
    oa_mark "i$i: post-cycle1 ${wpr2:-WPR2=?} (0x0 = lockdown substrate; up = fast-fail twin)"
    oa_assert_a6; oa_pin_d0
    [[ "$(IS_EXT)" == 1 ]] || { RESULT="inconclusive(is_external)"; oa_mark "i$i: SKIP — $RESULT"; return 0; }
    oa_bar1_ok          || { RESULT="inconclusive(bar1)";        oa_mark "i$i: SKIP — $RESULT"; return 0; }
    sleep 2
    local fsent="oa-mark: i$i: LD-FIRE-SENTINEL"
    oa_mark "i$i: LD-FIRE-SENTINEL"
    dmesg 2>/dev/null | grep -q "i$i: LD-FIRE-SENTINEL" || oa_mark "i$i: WARN — LD sentinel did not mirror to kmsg; will classify anchor-lost"
    oa_mark "i$i: RE-OPEN FIRE (exec open /dev/nvidia0, timeout ${REOPEN_TIMEOUT}s) <<< pre-v2 WEDGE point"
    timed_open 3; local rc="$FIRE_RC" dt="$FIRE_DT"
    local st_after; st_after="$(TB_STATE)"
    oa_mark "i$i: RE-OPEN RETURNED rc=$rc dt=${dt}ms tb_state=$st_after — HOST SURVIVED"
    local slice="$OA_RUNDIR/i${i}-ld-dmesg.txt"
    dmesg_since "$fsent" > "$slice"; sync
    local anchor_lost=0; grep -q . "$slice" || anchor_lost=1
    local notsunk lockdown inbudget timed kf
    notsunk=$(grep -ac 'chip NOT sunk'             "$slice")
    lockdown=$(grep -ac 'GSP lockdown poll'        "$slice")
    inbudget=$(grep -ac 'open completed within budget' "$slice")
    timed=$(grep -ac 'open timed out after'        "$slice")
    kf=$(kfence_count "$slice")
    (( anchor_lost )) && kf=$(( kf + $(dmesg 2>/dev/null | tail -400 | grep -acE 'BUG: (KFENCE|KASAN):') ))
    oa_mark "i$i: ld dmesg notsunk=$notsunk lockdown=$lockdown inbudget=$inbudget timed=$timed kfence=$kf rc=$rc dt=${dt}ms wpr2=${wpr2#WPR2=} anchor_lost=$anchor_lost"
    oa_passive_snapshot "i${i}-ld-postfire"
    if (( kf > 0 )); then RESULT="BREACH(KFENCE/KASAN)"; oa_mark "i$i: *** $RESULT ***"; return 2; fi
    if (( rc == 124 )); then RESULT="FAIL(soft-block ${dt}ms — lockdown arm did NOT self-terminate)"; oa_mark "i$i: *** $RESULT ***"; return 2; fi
    if (( anchor_lost )); then RESULT="inconclusive(anchor-lost)"; oa_mark "i$i: ld anchor lost — cannot classify"; return 0; fi
    if (( lockdown >= 1 )); then
        if (( dt < 1500 )); then
            RESULT="lockdown-contained"
            oa_mark "i$i: *** A10-v2 LOCKDOWN VALIDATED *** lockdown re-open CONTAINED: bounded -EIO(rc=$rc) dt=${dt}ms, worker self-terminated, host alive, tb_state=$st_after, KFENCE clean (pre-v2 this WEDGED)"
        else
            RESULT="lockdown-slow(${dt}ms)"
            oa_mark "i$i: WARN — lockdown arm reached + contained but dt=${dt}ms >1.5s (self-terminated SLOWLY)"
        fi
    elif (( notsunk >= 1 )); then
        RESULT="fastfail-on-lockdown-substrate"
        oa_mark "i$i: fire hit the FAST-FAIL arm (WPR2 was up, not 0) — re-roll for the lockdown substrate"
    elif (( inbudget >= 1 )); then
        RESULT="inbudget(no-divergence)"
        oa_mark "i$i: open completed within budget — chip was not divergent this cycle"
    else
        RESULT="ambiguous(rc=$rc)"
        oa_mark "i$i: ambiguous — no lockdown/notsunk/inbudget marker (rc=$rc)"
    fi
    return 0
}

recover_clean() {
    local i="$1"
    oa_mark "i$i: RECOVER — host rmmod + (TB reenum + fix-bar1 if BAR1 broken)"
    host_unload "i${i}-recover" || oa_mark "i$i: RECOVER WARN — unload non-clean"
    if ! oa_bar1_ok; then
        echo 0 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 2
        echo 1 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 4
        oa_discover
        setpci -s "$OA_GPU_SHORT" COMMAND=0000 2>/dev/null
        timeout 180 "$FIXBAR1" --bind > "$OA_RUNDIR/i${i}-recover-fixbar1.log" 2>&1
        oa_bar1_recovered || { oa_mark "i$i: RECOVER INCOMPLETE — BAR1=$(oa_bar1_mib)"; return 1; }
        oa_mark "i$i: RECOVER OK — BAR1 32768 (post-sink recovery)"
    else
        oa_mark "i$i: RECOVER OK — BAR1 already 32768 (no sink to undo)"
    fi
    return 0
}

# ============================ run =========================================
# Install cleanup + traps BEFORE any persistent host-state mutation (KFENCE /
# params / drain), so an oa_die or a Ctrl-C during ANY of them restores state.
cleanup() {
    [[ -n "$CLEANED" ]] && return 0; CLEANED=1
    [[ -n "$FIRE_PID" ]] && kill "$FIRE_PID" 2>/dev/null
    [[ -n "$TO_SAVED" && -w "$TO_PARAM" ]] && echo "$TO_SAVED" > "$TO_PARAM" 2>/dev/null   # restore params FIRST...
    [[ -n "$GR_SAVED" && -w "$GR_PARAM" ]] && echo "$GR_SAVED" > "$GR_PARAM" 2>/dev/null
    [[ -n "$KF_SAVED" && -w "$KF_PARAM" ]] && echo "$KF_SAVED" > "$KF_PARAM" 2>/dev/null
    oa_restore_injector                                                                    # ...THEN restore the DS (so it never re-opens at timeout=1ms)
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

oa_mark "RA10v2 ($MODE) start: N=$N reopen_timeout=${REOPEN_TIMEOUT}s ver-gate=$A10_VER ff_grace=${FF_GR}ms"
if [[ "$MODE" == lockdown ]]; then
    oa_log "*** LOCKDOWN MODE — RISKY: a fire can HARD-WEDGE the host (the exact F44 failure). USER MUST BE AT CONSOLE. kdump CANNOT capture this; recovery=reboot. ***"
fi
[[ -w "$KF_PARAM" ]] && { KF_SAVED="$(cat "$KF_PARAM")"; echo 1 > "$KF_PARAM" 2>/dev/null && oa_mark "KFENCE sample_interval -> 1ms (restore: echo $KF_SAVED > $KF_PARAM)"; }
oa_log "capture prereqs: hardlockup_panic=$(cat /proc/sys/kernel/hardlockup_panic 2>/dev/null) softlockup_panic=$(cat /proc/sys/kernel/softlockup_panic 2>/dev/null) sysrq=$(cat /proc/sys/kernel/sysrq 2>/dev/null)"
oa_drain_injector || oa_die "could not drain injector — aborting"

PASS=0; CONTAINED=0; OTHER=0; HALT=""
for i in $(seq 1 "$N"); do
    oa_mark "===== RA10v2/$MODE iter $i/$N START ====="
    if ! establish_precond "$i"; then HALT="precond"; oa_passive_snapshot "i${i}-precond-fail"; break; fi
    if [[ "$MODE" == fastfail ]]; then fire_fastfail "$i"; else fire_lockdown "$i"; fi
    frc=$?
    if (( frc == 2 )); then HALT="$RESULT"; break; fi
    case "$RESULT" in
        fastfail-PASS)                  PASS=$((PASS+1));;
        lockdown-contained|lockdown-slow*) CONTAINED=$((CONTAINED+1));;
        *)                              OTHER=$((OTHER+1));;
    esac
    recover_clean "$i" || { HALT="recover"; break; }
    oa_mark "===== RA10v2/$MODE iter $i/$N DONE ($RESULT) ====="
    [[ "$MODE" == lockdown ]] && (( CONTAINED >= 1 )) && { oa_mark "lockdown arm proven contained (n=$CONTAINED) — stopping early"; break; }
done

oa_mark "===== RA10v2/$MODE COMPLETE: pass=$PASS contained=$CONTAINED other=$OTHER${HALT:+ (halt:$HALT)} ====="
if [[ "$MODE" == fastfail ]]; then
    if (( PASS >= N )); then
        oa_log "verdict: A10-v2 FAST-FAIL VALIDATED (n=$PASS/$N) — the induced-timeout chip's bus stays connected (config-vendor 0x10de, next-open rc=0) where pre-v2 dead-bused it."
    elif [[ -n "$HALT" && ( "$HALT" == fastfail-FAIL* || "$HALT" == fastfail-ANOMALY* ) ]]; then
        oa_log "verdict: A10-v2 FAST-FAIL FAILED ($HALT). See $OA_RUNDIR markers."
    else
        oa_log "verdict: INCONCLUSIVE — only $PASS/$N PASS (other=$OTHER). Re-run; ensure inits exceed ${FF_TO}ms (A6 trips) and a sink read is authoritative (config-vendor or drgn)."
    fi
else
    if (( CONTAINED >= 1 )); then
        oa_log "verdict: A10-v2 LOCKDOWN VALIDATED — the lockdown re-open is CONTAINED (bounded -EIO, host alive) where pre-v2 it hard-wedged."
    elif [[ -n "$HALT" && "$HALT" != precond && "$HALT" != recover ]]; then
        oa_log "verdict: A10-v2 LOCKDOWN FAILED ($HALT) — see $OA_RUNDIR markers (kdump cannot capture; reboot was required)."
    else
        oa_log "verdict: INCONCLUSIVE — never hit the WPR2=0 lockdown substrate in $N iters. Re-run with larger N."
    fi
fi
oa_log "forensics: $OA_RUNDIR"
