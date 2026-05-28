#!/bin/bash
#
# fix-bar1.sh — Recover from H1 broken-BAR1 via pciehp slot power cycle
#
# Linux's runtime TB hot-plug code path doesn't size bridge windows correctly
# on this hardware: a hot-attached TB GPU gets BAR1=256MB instead of the
# 32GB it should have. The pciehp slot-power-on code path DOES size bridges
# correctly. So we use it as a userspace workaround: power-cycle the GPU's
# parent TB tunnel slot via /sys/bus/pci/slots/<N>/power.
#
# See docs/missions/mission-1-egpu-hot-plug-hot-power/experiments/
# slot12-poweroff-Exp3a-2026-05-28.md for the experimental discovery.
#
# CAVEAT: the slot cycle tears down EVERY device downstream of the GPU's
# TB tunnel parent. On a NUC 15 Pro+ with AORUS eGPU chassis, this means
# the chassis's Realtek USB LAN, USB hubs, AORUS DMC, and HID devices all
# disconnect briefly (~5-10s) and re-enumerate. If your SSH session routes
# through the TB-tunneled LAN you will be cut off. The script checks for
# this and refuses to proceed unless --force is given.
#
# Other TB ports on the host (different slot) are unaffected.
#
# REQUIREMENTS:
# - root (writes /sys/bus/pci/slots/<N>/power)
# - lspci (pciutils package)
# - kubectl optional: if present and nvidia DaemonSets exist, the script
#   quiesces them via nodeSelector patch before slot cycling.
#
# USAGE:
#   fix-bar1.sh                   # default: auto-detect first NVIDIA GPU
#   fix-bar1.sh --gpu 0000:04:00.0 # specify GPU BDF explicitly
#   fix-bar1.sh --dry-run          # show what would be done; touch nothing
#   fix-bar1.sh --force            # skip safety checks (SSH-route warning)
#   fix-bar1.sh --no-quiesce       # don't touch k8s DaemonSets
#
# EXIT STATUS:
#   0 — success (BAR1 now 32GiB)
#   1 — broken-BAR1 still present after recovery
#   2 — slot not found / hierarchy walk failed
#   3 — safety check failed (SSH on TB LAN, etc.)
#   4 — quiesce timed out
#

set -euo pipefail

# Defaults
DRY_RUN=0
FORCE=0
NO_QUIESCE=0
GPU_BDF=""
QUIESCE_LABEL="fix-bar1-quiesced"
OFF_SLEEP=5      # seconds between power off and on
POST_WAIT=10     # seconds to wait for re-enumeration

usage() {
    sed -n '/^# USAGE:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --gpu) GPU_BDF="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --force) FORCE=1; shift ;;
        --no-quiesce) NO_QUIESCE=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
done

log() { echo "[fix-bar1] $*"; }
die() { echo "[fix-bar1] ERROR: $*" >&2; exit "${2:-1}"; }

# Step 1 — root check
[ "$(id -u)" -eq 0 ] || die "must run as root" 64

# Step 2 — auto-detect GPU BDF if not specified
if [ -z "$GPU_BDF" ]; then
    # First NVIDIA VGA controller in lspci output
    GPU_BDF=$(lspci -nn | awk '/10de:/ && /VGA/ {print "0000:"$1; exit}')
    [ -n "$GPU_BDF" ] || die "no NVIDIA VGA device found; specify with --gpu <BDF>" 2
    log "auto-detected GPU: $GPU_BDF"
else
    # Validate BDF format
    [[ "$GPU_BDF" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$ ]] \
        || die "invalid BDF format: $GPU_BDF (expected 0000:bb:dd.f)" 64
    log "using GPU: $GPU_BDF"
fi

[ -d "/sys/bus/pci/devices/$GPU_BDF" ] || die "GPU $GPU_BDF not on PCI bus" 2

# Step 3 — current BAR1 size (passive read; safe even on broken-BAR1)
BAR1_BYTES=$(awk 'NR==2 {print strtonum($2)-strtonum($1)+1; exit}' \
    "/sys/bus/pci/devices/$GPU_BDF/resource")
BAR1_MB=$((BAR1_BYTES / 1024 / 1024))
log "current BAR1: ${BAR1_MB} MiB"

if [ "$BAR1_MB" -ge 32768 ]; then
    log "BAR1 is already >= 32GiB — nothing to fix"
    log "(use --force to slot-cycle anyway, e.g. for testing)"
    [ "$FORCE" -eq 1 ] || exit 0
fi

# Step 4 — walk parent bridges, find TB tunnel parent with a slot file
log "walking PCI parent hierarchy for $GPU_BDF..."
PARENTS=$(lspci -PP -s "${GPU_BDF#0000:}" 2>/dev/null | awk '{print $1}' | tr '/' ' ')
[ -n "$PARENTS" ] || die "lspci -PP returned no parent chain for $GPU_BDF" 2

SLOT=""
TUNNEL_PARENT=""
for parent in $PARENTS; do
    # parent format: bb:dd.f — strip function for slot address match
    parent_short="${parent%.*}"   # 02:00.0 -> 02:00
    parent_short="${parent_short}"
    for slot_addr_file in /sys/bus/pci/slots/*/address; do
        [ -f "$slot_addr_file" ] || continue
        if [ "$(cat "$slot_addr_file")" = "0000:$parent_short" ]; then
            SLOT=$(basename "$(dirname "$slot_addr_file")")
            TUNNEL_PARENT="$parent"
            break 2
        fi
    done
done

[ -n "$SLOT" ] || die "no pciehp slot found in parent chain of $GPU_BDF (parents: $PARENTS)" 2

log "GPU parent chain: $PARENTS"
log "TB tunnel parent with slot: $TUNNEL_PARENT → slot $SLOT"

SLOT_DIR="/sys/bus/pci/slots/$SLOT"
[ -w "$SLOT_DIR/power" ] || die "slot $SLOT power file not writable" 2

# Step 5 — safety: enumerate downstream devices that will be affected
log "downstream devices that will be cycled (everything under bridge $TUNNEL_PARENT):"
TUNNEL_PATH=$(readlink -f "/sys/bus/pci/devices/0000:$TUNNEL_PARENT" 2>/dev/null || true)
if [ -n "$TUNNEL_PATH" ]; then
    for dev_link in /sys/bus/pci/devices/0000:*; do
        [ -L "$dev_link" ] || continue
        dev_path=$(readlink -f "$dev_link")
        # device path passes through tunnel parent → it's downstream
        case "$dev_path" in
            "$TUNNEL_PATH"/*)
                bdf=$(basename "$dev_link")
                desc=$(lspci -s "${bdf#0000:}" 2>/dev/null | sed 's/^[^ ]* //')
                log "  $bdf : $desc"
                ;;
        esac
    done
fi

# Step 6 — safety: refuse if SSH appears routed through TB-tunneled LAN
if [ "$FORCE" -ne 1 ] && [ -n "${SSH_CONNECTION:-}" ]; then
    ssh_iface=$(ip -o route get "${SSH_CONNECTION%% *}" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}')
    if [ -n "$ssh_iface" ]; then
        ssh_pci_path=$(readlink -f "/sys/class/net/$ssh_iface/device" 2>/dev/null || true)
        if [ -n "$ssh_pci_path" ] && echo "$ssh_pci_path" | grep -q "0000:${TUNNEL_PARENT%.*}"; then
            die "SSH connection routes through interface $ssh_iface which is downstream of the TB tunnel about to be cycled. Pass --force to override (will likely cut your connection)." 3
        fi
    fi
fi

# Step 7 — dry run exit point
if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would write 0 then 1 to $SLOT_DIR/power with ${OFF_SLEEP}s between"
    log "DRY-RUN: would quiesce k8s DaemonSets via nodeSelector patch (if present)"
    log "DRY-RUN: exiting without modification"
    exit 0
fi

# Step 8 — quiesce k8s consumers if kubectl is available
quiesce_k8s() {
    [ "$NO_QUIESCE" -eq 1 ] && return 0
    command -v kubectl >/dev/null 2>&1 || return 0

    for ds in nvidia-driver-injector nvidia-device-plugin-daemonset; do
        if kubectl get ds -n kube-system "$ds" >/dev/null 2>&1; then
            log "quiescing DaemonSet $ds via nodeSelector patch"
            kubectl patch ds -n kube-system "$ds" \
                -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"$QUIESCE_LABEL\":\"true\"}}}}}" \
                >/dev/null
        fi
    done

    # Wait up to 30s for pods to disappear
    local deadline=$(($(date +%s) + 30))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local count=$(kubectl get pods -n kube-system 2>/dev/null | grep -c "^nvidia-" || true)
        [ "$count" -eq 0 ] && return 0
        sleep 2
    done
    die "k8s consumer quiesce timed out (30s)" 4
}

unquiesce_k8s() {
    [ "$NO_QUIESCE" -eq 1 ] && return 0
    command -v kubectl >/dev/null 2>&1 || return 0

    for ds in nvidia-driver-injector nvidia-device-plugin-daemonset; do
        if kubectl get ds -n kube-system "$ds" >/dev/null 2>&1; then
            log "restoring DaemonSet $ds"
            kubectl patch ds -n kube-system "$ds" \
                --type='json' -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]' \
                >/dev/null 2>&1 || true
        fi
    done
}

quiesce_k8s

# Step 9 — power-off / sleep / power-on
log "powering OFF slot $SLOT"
echo 0 > "$SLOT_DIR/power"
sleep "$OFF_SLEEP"

log "powering ON slot $SLOT"
echo 1 > "$SLOT_DIR/power"

log "waiting ${POST_WAIT}s for re-enumeration..."
sleep "$POST_WAIT"

# Step 10 — verify BAR1 is now healthy
if [ ! -d "/sys/bus/pci/devices/$GPU_BDF" ]; then
    log "GPU $GPU_BDF did not re-enumerate after slot power-on"
    unquiesce_k8s
    die "GPU not back on PCI bus" 1
fi

NEW_BAR1_BYTES=$(awk 'NR==2 {print strtonum($2)-strtonum($1)+1; exit}' \
    "/sys/bus/pci/devices/$GPU_BDF/resource")
NEW_BAR1_MB=$((NEW_BAR1_BYTES / 1024 / 1024))
log "post-recovery BAR1: ${NEW_BAR1_MB} MiB"

unquiesce_k8s

if [ "$NEW_BAR1_MB" -ge 32768 ]; then
    log "SUCCESS: BAR1 recovered to 32GiB"
    exit 0
else
    log "FAILURE: BAR1 still under 32GiB (${NEW_BAR1_MB} MiB)"
    exit 1
fi
