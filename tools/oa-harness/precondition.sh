#!/usr/bin/env bash
# tools/oa-harness/precondition.sh — establish the F40 "userspace-recovered" substrate.
#
# Canonical recipe (fake-5090/failure-modes/F40-...md §Reproduction recipe, n=4):
#   prior bind+persistence (the running injector) -> graceful uninstall (rmmod)
#   -> TB deauth/reauth (-> broken-BAR1) -> fix-bar1 (-> 32 GiB) -> modprobe NO
#   persistence -> [Rung 3.5: pin D0 + assert A6]. Leaves the chip ready for the
#   cycle-1 / cycle-2 trigger.
#
# Teardown uses the injector's OWN graceful path (kubectl exec ... uninstall) so
# nvidia.ko is unloaded BEFORE the TB deauth — avoiding the surprise-removal
# wedge (a different failure that would contaminate the experiment). We do NOT
# delete the DaemonSet pod (OnDelete strategy would recreate it and RELOAD).
#
# Usage: source lib.sh first, then call oa_precondition; or run standalone:
#   sudo tools/oa-harness/precondition.sh [--dry-run]
set -uo pipefail
_OA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_OA_DIR/lib.sh"

OA_DRYRUN=0
oa_do() { if [[ "$OA_DRYRUN" == 1 ]]; then printf '  [DRY] %s\n' "$*"; else eval "$*"; fi; }

oa_precondition() {
    oa_discover
    [[ $EUID -eq 0 ]] || oa_die "must run as root"

    oa_mark "PRECOND start (dryrun=$OA_DRYRUN)"
    oa_passive_snapshot "precond-00-baseline"

    # 1. refuse if a real GPU consumer holds /dev/nvidia* (would EBUSY the rmmod
    #    AND a TB deauth with a holder = surprise-removal wedge).
    if command -v fuser >/dev/null 2>&1; then
        local holders; holders="$(fuser /dev/nvidia* 2>/dev/null | tr -d ' ')"
        [[ -z "$holders" ]] || oa_die "GPU consumers hold /dev/nvidia* ($holders) — drain first"
    fi
    oa_log "no /dev/nvidia* holders ✓"

    # 2. graceful uninstall (rmmod) via the injector's own path. nvidia.ko OFF
    #    the host BEFORE any TB deauth.
    oa_mark "PRECOND uninstall (kubectl exec)"
    if [[ "$OA_DRYRUN" == 1 ]]; then
        oa_do "kubectl -n $OA_INJECTOR_NS exec ds/$OA_INJECTOR_DS -- /entrypoint.sh uninstall"
    else
        if grep -q '^nvidia ' /proc/modules; then
            kubectl -n "$OA_INJECTOR_NS" exec "ds/$OA_INJECTOR_DS" -- /entrypoint.sh uninstall 2>&1 | sed 's/^/    /' \
                || oa_warn "uninstall exec returned non-zero (check holders / refcnt)"
        else
            oa_log "nvidia already unloaded"
        fi
        # verify
        if grep -q '^nvidia ' /proc/modules; then
            oa_die "nvidia STILL loaded after uninstall — refcnt? (try: nvidia-smi -pm 0 then retry). NOT proceeding to TB deauth with driver loaded."
        fi
        oa_log "nvidia.ko unloaded ✓"
    fi

    # 3. TB deauth/reauth -> broken-BAR1 (driver is OFF, so no surprise-removal)
    [[ -n "$OA_TB" ]] || oa_die "no TB device discovered"
    local authp="/sys/bus/thunderbolt/devices/$OA_TB/authorized"
    oa_mark "PRECOND tb-deauth $OA_TB"
    oa_do "echo 0 > $authp"; sleep 2
    oa_mark "PRECOND tb-reauth $OA_TB"
    oa_do "echo 1 > $authp"; sleep 4
    if [[ "$OA_DRYRUN" == 0 ]]; then
        [[ -e "/sys/bus/pci/devices/$OA_GPU" ]] || oa_die "GPU gone after TB reauth"
        oa_log "post-reauth BAR1=$(oa_bar1_mib) MiB (expect ~256 broken)"
    fi

    # 4. restore BAR1 to 32 GiB
    oa_mark "PRECOND fix-bar1"
    oa_do "setpci -s $OA_GPU_SHORT COMMAND=0:3"
    oa_do "$OA_REPO_ROOT/tools/fix-bar1.sh"
    if [[ "$OA_DRYRUN" == 0 ]]; then
        oa_bar1_ok || oa_die "fix-bar1 did not restore 32 GiB (BAR1=$(oa_bar1_mib) MiB)"
        oa_log "BAR1 restored: $(oa_bar1_mib) MiB ✓"
    fi

    # 5. modprobe WITHOUT persistence (the no-persistence is load-bearing)
    oa_mark "PRECOND modprobe (no-persistence)"
    oa_do "echo '' > /sys/bus/pci/devices/$OA_GPU/driver_override"
    oa_do "modprobe --ignore-install nvidia"
    if [[ "$OA_DRYRUN" == 0 ]]; then
        sleep 2
        local drv; drv="$(basename "$(readlink /sys/bus/pci/devices/$OA_GPU/driver 2>/dev/null || echo none)")"
        [[ "$drv" == nvidia ]] || oa_die "nvidia did not bind ($drv) — check driver_override / modprobe.blacklist"
        oa_log "nvidia bound (no persistence) ✓ version=$(cat /sys/module/nvidia/version)"
    fi

    # 6. Rung 3.5 entry gate: A6 present + pin D0 (so a wedge lands at A6's site,
    #    not the A6-uncovered pre-nv_open_device site — see ledger Lane 1).
    oa_mark "PRECOND rung3.5 assert-A6 + pin-D0"
    if [[ "$OA_DRYRUN" == 0 ]]; then
        oa_assert_a6
        oa_pin_d0
    fi
    oa_passive_snapshot "precond-99-ready"
    oa_mark "PRECOND complete — chip ready for cycle-1/cycle-2"
}

# standalone entry
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "${1:-}" == "--dry-run" ]] && OA_DRYRUN=1
    oa_discover
    oa_init_run "oa-precond"
    oa_precondition
fi
