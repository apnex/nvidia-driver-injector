#!/usr/bin/env bash
# fix-bar1.sh — userspace recovery from H1 broken-BAR1.
#
# When a Blackwell GPU is hot-added via Thunderbolt (cable replug, chassis power
# cycle, or thunderbolt-sysfs deauth/reauth), the chip's ReBAR Control register
# resets from 0xF (32GB BAR1 advertisement) to 0x8 (256MB). Linux's TB hot-add
# code path does not restore it. Result: BAR1 comes up at 256MB instead of 32GB
# ("broken-BAR1" / H1 failure mode), making the GPU unusable.
#
# This script:
#   1. Discovers GPU BDF, TB device, pciehp slot, ReBAR cap offset
#   2. Verifies kernel cmdline preconditions (pci=hpmmioprefsize=32G, pci=realloc=on)
#   3. Verifies host state (no GPU consumers, nvidia.ko unbound)
#   4. Writes chip CTRL register to advertise the maximum supported BAR1 size
#   5. Triggers pciehp slot power cycle to widen the bridge window
#   6. Re-applies driver_override (slot cycle wipes it)
#   7. Verifies BAR1 size in sysfs matches the chip's advertisement
#   8. (optional, with --bind) modprobes nvidia to bind the recovered GPU,
#      then immediately engages persistence so the first LAST-CLOSE does
#      not trigger the close-path wedge described under "Known hazards"
#      below.
#
# THIS IS A USERSPACE WORKAROUND. The proper fix is a small kernel patch (E27)
# to call pci_rebar_set_size() on the TB hot-add code path in either
# drivers/thunderbolt/tunnel.c or drivers/pci/probe.c. Once that lands upstream,
# this script becomes obsolete. Track in docs/upstream-plan.md.
#
# Known hazards:
#
#   1. CLOSE-PATH WEDGE without persistence engagement.
#      After our PCI-layer recovery, the chip's PCIe equalization status
#      bits (Phy16Sta.EquComplete) are clear vs cold-plug, even though the
#      link is at Gen3 x4. The closed-source NVIDIA RM treats this as a
#      removal candidate; on first LAST-CLOSE after a fresh probe,
#      nv_shutdown_adapter tears down GSP and the kernel then calls
#      pci_stop_and_remove_bus_device, which hangs on the chip and
#      wedges the host system-wide (silent freeze, reboot needed).
#
#      Mitigation: --bind engages persistence (nvidia-smi -pm 1) right
#      after modprobe. Persistence routes the close-path through
#      rm_disable_adapter instead — GSP stays loaded, no
#      pci_stop_and_remove, no wedge. Verified n=2 on this host
#      2026-05-28. Production binds via the injector container already
#      do this; the hazard only surfaced when --bind was first introduced.
#
# VERIFIED n=2 across full deauth→recover→bind→workload cycle on this host
# (NUC 15 Pro+ + AORUS RTX5090 AI BOX) on 2026-05-28, including CUDA
# workload (nvbandwidth H2D ~2.71 GB/s, TB4-saturated baseline). Long-term
# stability + IOMMU=on + other silicon revisions still untested.
#
# Full experimental record:
#   docs/missions/mission-1-egpu-hot-plug-hot-power/experiments/h1-userspace-recovery-2026-05-28.md
#
# Usage:
#   sudo tools/fix-bar1.sh                # recover only (leave GPU unbound)
#   sudo tools/fix-bar1.sh --bind         # recover + modprobe nvidia
#   sudo tools/fix-bar1.sh --dry-run      # discovery + preflight checks only, no writes
#   sudo tools/fix-bar1.sh --gpu BDF      # specify GPU BDF (skip auto-discovery)
#
# Output: logged to stdout + state captures in /var/log/fix-bar1-<UTC-ts>/

set -euo pipefail

# ---------- CLI parsing ----------
DRY_RUN=0
DO_BIND=0
GPU_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=1; shift ;;
        --bind)     DO_BIND=1; shift ;;
        --gpu)      GPU_OVERRIDE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown arg: $1" >&2
            echo "see --help" >&2
            exit 2
            ;;
    esac
done

# ---------- preflight ----------
if [[ $EUID -ne 0 ]]; then
    echo "must run as root (need /sys/bus/pci write access + setpci)" >&2
    exit 1
fi

ts=$(date -u +%Y%m%dT%H%M%SZ)
workdir="/var/log/fix-bar1-${ts}"
mkdir -p "$workdir"

log()   { printf '[fix-bar1] %s\n' "$*"; }
warn()  { printf '[fix-bar1] WARN: %s\n' "$*" >&2; }
fatal() { printf '[fix-bar1] ERROR: %s\n' "$*" >&2; exit 1; }

for tool in setpci lspci awk readlink; do
    command -v "$tool" >/dev/null || fatal "required tool '$tool' not found"
done

log "logging to $workdir"
log "dry-run: $DRY_RUN; bind-after-recover: $DO_BIND"

# ---------- discovery ----------
discover_gpu_bdf() {
    if [[ -n "$GPU_OVERRIDE" ]]; then
        echo "$GPU_OVERRIDE"
        return
    fi
    # NVIDIA GPUs (vendor 10de, class VGA or 3D controller)
    local candidates
    candidates=$(lspci -nn -d 10de: | awk '/VGA compatible|3D controller/ {print $1}')
    if [[ -z "$candidates" ]]; then
        fatal "no NVIDIA GPU found in lspci. Pass --gpu BDF if needed."
    fi
    # Prefer a GPU whose direct parent bridge has pciehp slot capability
    # (TB-tunneled devices sit behind a pciehp-capable upstream port).
    local tb_gpu=""
    for bdf in $candidates; do
        local parent
        parent=$(basename "$(readlink -f "/sys/bus/pci/devices/0000:$bdf/..")")
        # Walk up looking for any ancestor with a pciehp slot
        local cur="$parent"
        while [[ "$cur" != "pci0000:00" && "$cur" != "/" ]]; do
            local cur_bdf="${cur#0000:}"
            cur_bdf="${cur_bdf%.*}"
            for s in /sys/bus/pci/slots/*/; do
                [[ -f "$s/address" ]] || continue
                if [[ "$(cat "$s/address")" == "0000:$cur_bdf" ]]; then
                    tb_gpu="0000:$bdf"
                    break 3
                fi
            done
            cur=$(basename "$(readlink -f "/sys/bus/pci/devices/$cur/.." 2>/dev/null)")
        done
    done
    if [[ -z "$tb_gpu" ]]; then
        tb_gpu="0000:$(echo "$candidates" | head -1)"
        warn "no pciehp-tunneled NVIDIA GPU detected; defaulting to first: $tb_gpu"
    fi
    echo "$tb_gpu"
}

discover_audio_bdf() {
    # The HDA audio function of an NVIDIA GPU is at GPU_BDF with the last .N
    # incremented to .1 (PCIe multi-function device).
    local gpu="$1"
    local aud="${gpu%.*}.1"
    if [[ -e "/sys/bus/pci/devices/$aud" ]]; then
        echo "$aud"
    fi
}

discover_tb_device() {
    # Find a non-controller TB device. The TB protocol path lives under the TB
    # domain controller (e.g., 00:0d.2 on Intel TB4 hosts), separate from the
    # PCIe tunnel path the GPU uses. So we can't do a substring match on
    # realpath. Instead we use the convention that controllers are `N-0` and
    # downstream devices are `N-1`, `N-2`, etc.
    #
    # NOTE: this is heuristic. If you have multiple TB peripherals enrolled,
    # this picks the first non-controller — set TB_DEVICE_OVERRIDE env var to
    # constrain.
    if [[ -n "${TB_DEVICE_OVERRIDE:-}" ]]; then
        echo "$TB_DEVICE_OVERRIDE"
        return
    fi
    local tb=""
    for d in /sys/bus/thunderbolt/devices/[0-9]-[0-9]/; do
        [[ -f "$d/device_name" ]] || continue
        local base
        base=$(basename "$d")
        [[ "$base" == *-0 ]] && continue
        tb="$base"
        break
    done
    if [[ -z "$tb" ]]; then
        fatal "no non-controller TB device found. Set TB_DEVICE_OVERRIDE if your topology differs."
    fi
    echo "$tb"
}

discover_pciehp_slot() {
    # The pciehp slot we want is the one whose `address` matches the
    # bridge directly downstream of the TB host controller (i.e., the
    # PCIe upstream port at the TB tunnel root). Walk up from GPU to find it.
    local gpu="$1"
    local cur="$gpu"
    while [[ "$cur" != "0000:00:00.0" && -e "/sys/bus/pci/devices/$cur" ]]; do
        # Try each slot — look for one whose address (BB:DD format) matches
        # the parent bridge of the current device
        local parent_real
        parent_real=$(readlink -f "/sys/bus/pci/devices/$cur/..")
        local parent
        parent=$(basename "$parent_real")
        if [[ "$parent" =~ ^0000:[0-9a-f]+:[0-9a-f]+\.[0-9]+$ ]]; then
            local parent_addr="${parent#0000:}"
            parent_addr="${parent_addr%.*}"
            for s in /sys/bus/pci/slots/*/; do
                [[ -f "$s/address" ]] || continue
                local slot_addr
                slot_addr=$(cat "$s/address")
                if [[ "$slot_addr" == "0000:$parent_addr" ]]; then
                    basename "$s"
                    return
                fi
            done
            cur="$parent"
        else
            break
        fi
    done
    fatal "could not find pciehp slot for $gpu"
}

discover_parent_bridge() {
    # The bridge directly above the GPU function (its parent in the PCI tree).
    local gpu="$1"
    local parent_real
    parent_real=$(readlink -f "/sys/bus/pci/devices/$gpu/..")
    basename "$parent_real"
}

discover_rebar_cap_offset() {
    # Find the Physical Resizable BAR cap offset on the GPU via lspci.
    # CTRL register lives at this offset + 0x08.
    # Capture lspci output first to avoid SIGPIPE from awk-exit under pipefail.
    local gpu="$1"
    local lspci_out
    lspci_out=$(lspci -s "${gpu#0000:}" -vv 2>/dev/null || true)
    local cap_offset
    cap_offset=$(awk '/Capabilities: \[[0-9a-f]+ v[0-9]+\] Physical Resizable BAR/ {
                       match($0, /\[([0-9a-f]+)/, m); print m[1]
                     }' <<< "$lspci_out" | head -1)
    if [[ -z "$cap_offset" ]]; then
        fatal "no Physical Resizable BAR capability found on $gpu (chip doesn't support ReBAR?)"
    fi
    printf '0x%s' "$cap_offset"
}

discover_max_size_encoded() {
    # Find max supported BAR1 size, encoded for the CTRL register.
    # PCI_REBAR_CAP register (cap_offset + 0x04, bits[31:4]) is a bitmap of
    # supported sizes. The highest set bit is the encoded max size.
    local gpu="$1" cap_offset="$2"
    local cap_reg_offset
    cap_reg_offset=$(printf '0x%x' $(( cap_offset + 4 )))
    local cap_val
    cap_val=$(setpci -s "${gpu#0000:}" "${cap_reg_offset}.l")
    # bits[31:4] of cap_val are the size bitmap; bits[0:3] are reserved/sub-fields
    local sizes_mask=$(( 0x$cap_val >> 4 ))
    if [[ $sizes_mask -eq 0 ]]; then
        fatal "ReBAR cap reports zero supported sizes on $gpu"
    fi
    # Find highest set bit
    local max_bit=0 tmp=$sizes_mask
    while (( tmp > 0 )); do max_bit=$((max_bit+1)); tmp=$((tmp>>1)); done
    max_bit=$((max_bit - 1))
    echo "$max_bit"
}

# ---------- run discovery ----------
log "=== discovery ==="
GPU=$(discover_gpu_bdf)
log "GPU BDF:       $GPU"
AUD=$(discover_audio_bdf "$GPU" || true)
log "audio BDF:     ${AUD:-<none>}"
TB=$(discover_tb_device "$GPU")
log "TB device:     $TB"
SLOT=$(discover_pciehp_slot "$GPU")
log "pciehp slot:   $SLOT"
BRIDGE=$(discover_parent_bridge "$GPU")
log "parent bridge: $BRIDGE"
REBAR_CAP=$(discover_rebar_cap_offset "$GPU")
REBAR_CTRL_OFF=$(printf '0x%x' $(( REBAR_CAP + 8 )))
log "ReBAR cap:     $REBAR_CAP (CTRL at $REBAR_CTRL_OFF)"
MAX_SIZE=$(discover_max_size_encoded "$GPU" "$REBAR_CAP")
MAX_BYTES=$(( 1 << (MAX_SIZE + 20) ))
MAX_GIB=$(( MAX_BYTES / 1024 / 1024 / 1024 ))
log "max BAR1 size: encoded=$MAX_SIZE → ${MAX_GIB} GiB"

# Compose CTRL value: BAR_IDX=1 (BAR1), NBAR=1, BAR_SIZE=MAX_SIZE
CTRL_VAL=$(( (MAX_SIZE << 8) | (1 << 5) | 1 ))
CTRL_HEX=$(printf '0x%08x' $CTRL_VAL)
log "CTRL value to write: $CTRL_HEX (decode: BAR_IDX=1, NBAR=1, BAR_SIZE=$MAX_SIZE)"

# ---------- snapshot helper ----------
snapshot() {
    local label="$1"
    local out="$workdir/${label}.txt"
    {
        echo "=== STATE: $label ==="
        echo "Timestamp: $(date -Iseconds)"
        if [[ -e "/sys/bus/pci/devices/$GPU/resource" ]]; then
            echo "--- BAR sizes ---"
            awk 'NR<=7 {s=strtonum($1); e=strtonum($2);
                       if (s==0) printf "  BAR%d: (unused)\n", NR-1;
                       else printf "  BAR%d: 0x%x..0x%x = %d MiB\n", NR-1, s, e, (e-s+1)/1024/1024}' \
                /sys/bus/pci/devices/$GPU/resource
            echo "--- chip ReBAR CTRL ($REBAR_CTRL_OFF) ---"
            echo "  $(setpci -s "${GPU#0000:}" "${REBAR_CTRL_OFF}.l" 2>&1)"
            echo "--- COMMAND ---"
            echo "  $(setpci -s "${GPU#0000:}" COMMAND 2>&1)"
            echo "--- driver state ---"
            echo "  driver_override: $(cat /sys/bus/pci/devices/$GPU/driver_override 2>&1)"
            echo "  driver bound:    $(readlink /sys/bus/pci/devices/$GPU/driver 2>&1 || echo '(none)')"
        else
            echo "  GPU $GPU not present in PCI tree"
        fi
        echo "--- bridge $BRIDGE prefetch window ---"
        if [[ -e "/sys/bus/pci/devices/$BRIDGE" ]]; then
            echo "  PREF_BASE/LIMIT (0x24.w/0x26.w): $(setpci -s "${BRIDGE#0000:}" 0x24.w 0x26.w 2>&1 | tr '\n' ' ')"
            echo "  PREF_*_UPPER (0x28.l/0x2c.l):    $(setpci -s "${BRIDGE#0000:}" 0x28.l 0x2c.l 2>&1 | tr '\n' ' ')"
        else
            echo "  bridge $BRIDGE not present"
        fi
    } > "$out"
    log "snapshot: $out"
}

# ---------- preconditions ----------
log "=== preflight ==="

CMDLINE=$(cat /proc/cmdline)
# pure-bash pattern matching to avoid pipefail+SIGPIPE on grep -q with piped input
if [[ "$CMDLINE" != *hpmmioprefsize=32G* ]]; then
    fatal "kernel cmdline missing 'pci=hpmmioprefsize=32G' — slot cycle will fail to widen bridge"
fi
if [[ "$CMDLINE" != *realloc=on* ]]; then
    warn "kernel cmdline missing 'pci=realloc=on' — bridge resize may not work"
fi
log "cmdline OK: pci=hpmmioprefsize=32G present"

# Check nvidia module loaded. Capture lsmod output first to avoid SIGPIPE
# from awk-exit while lsmod is still writing (pipefail catches that as 141).
lsmod_out=$(lsmod)
nvidia_loaded=$(awk '/^nvidia[[:space:]]/ {print $1}' <<< "$lsmod_out" | head -1)
if [[ -n "$nvidia_loaded" ]]; then
    fatal "nvidia module is loaded — unload it first: rmmod nvidia_uvm nvidia 2>&1"
fi
log "nvidia.ko unloaded ✓"

if [[ -L "/sys/bus/pci/devices/$GPU/driver" ]]; then
    fatal "GPU $GPU has a driver bound — unbind first"
fi
log "GPU $GPU has no driver bound ✓"

CURRENT_CMD=$(setpci -s "${GPU#0000:}" COMMAND)
if [[ "$CURRENT_CMD" != "0000" ]]; then
    fatal "GPU COMMAND=$CURRENT_CMD (memory decoding still on); ReBAR CTRL write would violate kernel safety contract"
fi
log "COMMAND=0x0000 (memory decoding off) ✓"

snapshot "A-baseline"

# ---------- read pre-state ----------
log "=== pre-recovery state ==="
PRE_CTRL=$(setpci -s "${GPU#0000:}" "${REBAR_CTRL_OFF}.l")
PRE_BAR1_MIB=$(awk 'NR==2 {s=strtonum($1); e=strtonum($2); print (e-s+1)/1024/1024; exit}' \
                  /sys/bus/pci/devices/$GPU/resource)
log "current chip CTRL: 0x$PRE_CTRL"
log "current BAR1:      $PRE_BAR1_MIB MiB"

PRE_BAR_SIZE=$(( (0x$PRE_CTRL >> 8) & 0x3F ))
PRE_GIB_ADVERTISED=$(( (1 << (PRE_BAR_SIZE + 20)) / 1024 / 1024 / 1024 ))
log "current chip advertises: ${PRE_GIB_ADVERTISED} GiB BAR1"

if [[ "$PRE_BAR1_MIB" -ge $(( MAX_GIB * 1024 )) ]]; then
    log "BAR1 already at ${PRE_BAR1_MIB} MiB — looks healthy. Nothing to do."
    if [[ $DO_BIND -eq 1 ]]; then
        log "(--bind passed; skipping recovery, proceeding to bind step)"
    else
        log "Exit 0 (no recovery needed)."
        exit 0
    fi
fi

if [[ $DRY_RUN -eq 1 ]]; then
    log "=== DRY RUN — would now: ==="
    log "  1. echo none > /sys/bus/pci/devices/$GPU/driver_override"
    [[ -n "$AUD" ]] && log "  2. echo none > /sys/bus/pci/devices/$AUD/driver_override"
    log "  3. setpci -s ${GPU#0000:} ${REBAR_CTRL_OFF}.l=$CTRL_HEX"
    log "  4. echo 0 > /sys/bus/pci/slots/$SLOT/power"
    log "  5. echo 1 > /sys/bus/pci/slots/$SLOT/power"
    log "  6. re-apply driver_override"
    log "Use without --dry-run to execute."
    exit 0
fi

# ---------- recovery sequence ----------
log "=== recovery sequence ==="

log "step 1: driver_override=none on GPU + audio"
echo none > /sys/bus/pci/devices/$GPU/driver_override
[[ -n "$AUD" ]] && echo none > /sys/bus/pci/devices/$AUD/driver_override

log "step 2: write chip ReBAR CTRL to $CTRL_HEX (${MAX_GIB} GiB advertised)"
setpci -s "${GPU#0000:}" "${REBAR_CTRL_OFF}.l=$CTRL_HEX"
POST_CTRL=$(setpci -s "${GPU#0000:}" "${REBAR_CTRL_OFF}.l")
if [[ "$POST_CTRL" != "$(printf '%08x' $CTRL_VAL)" ]]; then
    fatal "CTRL write didn't stick: read back 0x$POST_CTRL, expected $CTRL_HEX"
fi
log "  CTRL read-back: 0x$POST_CTRL ✓"
snapshot "B-after-chip-write"

log "step 3: pciehp slot $SLOT power cycle"
echo 0 > /sys/bus/pci/slots/$SLOT/power
sleep 3
if [[ -e "/sys/bus/pci/devices/$GPU" ]]; then
    warn "GPU still in PCI tree after slot power-off; this is unexpected but not fatal"
fi
echo 1 > /sys/bus/pci/slots/$SLOT/power
sleep 5

if [[ ! -e "/sys/bus/pci/devices/$GPU" ]]; then
    snapshot "C-after-slot-cycle-FAIL"
    fatal "GPU did not return after slot power-on. Check journalctl. State captured in $workdir"
fi

log "step 4: re-apply driver_override (slot cycle wipes it)"
echo none > /sys/bus/pci/devices/$GPU/driver_override
[[ -n "$AUD" && -e "/sys/bus/pci/devices/$AUD" ]] && echo none > /sys/bus/pci/devices/$AUD/driver_override

snapshot "D-after-recovery"

# ---------- verify ----------
log "=== verification ==="

POST_BAR1_MIB=$(awk 'NR==2 {s=strtonum($1); e=strtonum($2); print (e-s+1)/1024/1024; exit}' \
                   /sys/bus/pci/devices/$GPU/resource)
POST_CTRL2=$(setpci -s "${GPU#0000:}" "${REBAR_CTRL_OFF}.l")
log "post-recovery BAR1: $POST_BAR1_MIB MiB"
log "post-recovery CTRL: 0x$POST_CTRL2"

if [[ "$POST_BAR1_MIB" -lt $(( MAX_GIB * 1024 )) ]]; then
    fatal "RECOVERY FAILED: BAR1 is $POST_BAR1_MIB MiB, expected ≥ $(( MAX_GIB * 1024 )) MiB. Check $workdir/D-after-recovery.txt + journalctl."
fi

log "✓ BAR1 recovered to $POST_BAR1_MIB MiB (chip advertising ${MAX_GIB} GiB)"

# ---------- optional bind ----------
if [[ $DO_BIND -eq 1 ]]; then
    log "=== nvidia.ko bind (--bind specified) ==="
    if ! [[ -e "/lib/modules/$(uname -r)/extra/nvidia.ko" ]]; then
        fatal "nvidia.ko not found at /lib/modules/$(uname -r)/extra/nvidia.ko. Cannot bind."
    fi

    log "clearing GPU driver_override (nvidia.ko self-unloads if no device probed)"
    echo "" > /sys/bus/pci/devices/$GPU/driver_override

    log "modprobe --ignore-install nvidia"
    if ! modprobe --ignore-install nvidia; then
        fatal "modprobe failed. State captured in $workdir; check journalctl for probe wedge symptoms (Xid 154, hung_task)."
    fi
    sleep 2

    BOUND=$(readlink "/sys/bus/pci/devices/$GPU/driver" 2>/dev/null || echo "")
    if [[ "$BOUND" != *"/nvidia" ]]; then
        fatal "nvidia.ko loaded but did not bind to $GPU. Bound to: '$BOUND'"
    fi
    log "✓ nvidia.ko bound to $GPU"

    # CRITICAL: engage persistence BEFORE any nvidia-smi query that would
    # open + close /dev/nvidiactl. Without persistence, the first LAST-CLOSE
    # takes the nv_shutdown_adapter path, GSP is torn down, then
    # pci_stop_and_remove_bus_device runs and wedges the host on our
    # userspace-recovered chip. With persistence, close-path takes
    # rm_disable_adapter and GSP stays loaded — no wedge.
    if command -v nvidia-smi >/dev/null; then
        log "engaging persistence (nvidia-smi -pm 1) — wedge prevention"
        if ! timeout 15 nvidia-smi -pm 1 2>&1 | sed 's/^/  /'; then
            warn "persistence engagement failed; subsequent LAST-CLOSE may wedge the host."
            warn "If you intend to use the GPU, engage persistence manually before any close:"
            warn "  nvidia-smi -pm 1"
        fi
    else
        warn "nvidia-smi not found — cannot engage persistence."
        warn "First LAST-CLOSE on the recovered chip will likely wedge the host."
        warn "Install nvidia-smi or run via the injector container before opening /dev/nvidia*."
    fi

    snapshot "E-after-bind-persist-on"

    if command -v nvidia-smi >/dev/null; then
        log "nvidia-smi -L (now safe — persistence engaged):"
        timeout 10 nvidia-smi -L 2>&1 | sed 's/^/  /' || warn "nvidia-smi -L timed out or failed"
    fi
fi

log "=== done ==="
log "state captures: $workdir"
log "remember: this is a userspace workaround pending the E27 kernel patch"
