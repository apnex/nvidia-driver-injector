#!/usr/bin/env bash
# get-pci-stats.sh — capture + diff PCI / TB / BAR state for MISSION-1 Phase 2.
#
# Every experiment in docs/phase-2-archaeology-matrix.md uses this:
#   ./tools/get-pci-stats.sh --baseline <experiment-id>     # pre-experiment
#   ./tools/get-pci-stats.sh --snapshot <experiment-id>     # post-experiment
#   ./tools/get-pci-stats.sh --diff <experiment-id>         # before vs after
#
# Captures:
#   - All bridge windows on the TB subtree (00:07.0, 02:00.0, 03:00.0, 03:01-03.0)
#   - GPU device state: BAR0/BAR1/BAR3 sizes + ReBAR current/supported
#   - TB layer state: boltctl + sysfs authorized
#   - Driver state: /sys/module/nvidia/version + /dev/nvidia*
#   - AER counts on bridges + GPU (delta is the noise signal)
#   - PCI tree shape (lspci -tnn) for hierarchical context
#   - dmesg ring tail (last 50 PCIe/TB/nvidia lines)
#
# Output: structured text (one file per capture) at:
#   /var/log/mission-1-archaeology/<experiment-id>.{baseline,snapshot}.txt
# Diff output is colorized stdout.

set -euo pipefail

OUT_DIR="${MISSION1_ARCHAEOLOGY_DIR:-/var/log/mission-1-archaeology}"
mkdir -p "$OUT_DIR"

# GPU PCI BDF — current AORUS 5090 location on this host
GPU_BDF=0000:04:00.0
# shellcheck disable=SC2034  # documented for experiments referencing the audio function (E12)
GPU_AUDIO_BDF=0000:04:00.1
# Bridge hierarchy: root port → TB upstream → TB downstream → GPU
BRIDGES=(0000:00:07.0 0000:02:00.0 0000:03:00.0 0000:03:01.0 0000:03:02.0 0000:03:03.0)
# TB device (AORUS UUID — stable across boots)
# shellcheck disable=SC2034  # documented for any future experiment using boltctl forget/enroll
TB_UUID=c4148780-00a9-7ce8-ffff-ffffffffffff
TB_SYSFS=/sys/bus/thunderbolt/devices/0-1

usage() {
    cat <<EOF
Usage: $0 [--baseline|--snapshot|--diff] <experiment-id>

  --baseline EID    Capture pre-experiment state; writes to ${OUT_DIR}/EID.baseline.txt
  --snapshot EID    Capture post-experiment state; writes to ${OUT_DIR}/EID.snapshot.txt
  --diff EID        Compare baseline vs snapshot for the experiment
  --list            List all captured experiments

Environment:
  MISSION1_ARCHAEOLOGY_DIR    Override output dir (default: /var/log/mission-1-archaeology)
EOF
}

capture() {
    local kind="$1"  # baseline or snapshot
    local eid="$2"
    local out="${OUT_DIR}/${eid}.${kind}.txt"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    {
        echo "=== mission-1 archaeology capture: ${eid} ${kind} @ ${ts} ==="
        echo "uptime: $(uptime -p)"
        echo "kernel: $(uname -r)"
        echo "cmdline: $(cat /proc/cmdline)"
        echo ""

        echo "## TB layer"
        echo "--- boltctl list ---"
        boltctl list 2>&1 | grep -E '^ o|uuid:|status:|authorized:|connected:' || echo "(boltctl unavailable)"
        echo "--- sysfs authorized ---"
        if [ -d "${TB_SYSFS}" ]; then
            echo "  authorized=$(cat ${TB_SYSFS}/authorized 2>/dev/null || echo absent)"
            echo "  vendor_name=$(cat ${TB_SYSFS}/vendor_name 2>/dev/null || echo absent)"
            echo "  device_name=$(cat ${TB_SYSFS}/device_name 2>/dev/null || echo absent)"
        else
            echo "  (${TB_SYSFS} absent — TB device not enumerated)"
        fi
        echo ""

        echo "## PCI tree shape"
        echo "--- lspci -tnn (TB subtree) ---"
        lspci -tnn 2>&1 | grep -E '00:07|^.* \[' | grep -A99 '00:07' || echo "(no TB subtree visible)"
        echo ""

        echo "## GPU device state"
        echo "--- ${GPU_BDF} regions ---"
        if lspci -s "${GPU_BDF}" >/dev/null 2>&1; then
            lspci -vs "${GPU_BDF}" 2>&1 | grep -E '^[[:space:]]*(Memory at|I/O ports|Expansion ROM)' || true
            echo "--- ReBAR capability ---"
            lspci -vvs "${GPU_BDF}" 2>&1 | grep -A2 -E '(Physical|Virtual) Resizable BAR' | head -20 || true
            echo "--- driver bound ---"
            if [ -L "/sys/bus/pci/devices/${GPU_BDF}/driver" ]; then
                readlink "/sys/bus/pci/devices/${GPU_BDF}/driver" | sed 's|.*/||'
            else
                echo "  (no driver bound)"
            fi
        else
            echo "  (${GPU_BDF} NOT enumerated on PCI bus)"
        fi
        echo ""

        echo "## Bridge windows (the critical state)"
        for br in "${BRIDGES[@]}"; do
            if lspci -s "${br}" >/dev/null 2>&1; then
                echo "--- ${br} ---"
                lspci -vs "${br}" 2>&1 | grep -E 'Memory behind|Prefetchable memory|I/O behind|Bus:' || true
            else
                echo "--- ${br} (NOT enumerated) ---"
            fi
        done
        echo ""

        echo "## AER counters (delta is the failure-signal of interest)"
        for bdf in "${GPU_BDF}" "${BRIDGES[@]}"; do
            local dev_dir="/sys/bus/pci/devices/${bdf}"
            if [ -d "${dev_dir}" ]; then
                echo "--- ${bdf} ---"
                for f in aer_dev_correctable aer_dev_fatal aer_dev_nonfatal aer_rootport_total_err_cor aer_rootport_total_err_fatal aer_rootport_total_err_nonfatal; do
                    if [ -f "${dev_dir}/${f}" ]; then
                        echo "  ${f}:"
                        head -10 "${dev_dir}/${f}" 2>/dev/null | sed 's/^/    /'
                    fi
                done
            fi
        done
        echo ""

        echo "## NVIDIA driver state"
        echo "--- /sys/module/nvidia/version ---"
        cat /sys/module/nvidia/version 2>&1 || echo "  (driver not loaded)"
        echo "--- /dev/nvidia* ---"
        # shellcheck disable=SC2012  # ls -la for human-readable device-node listing; find is uglier here
        ls -la /dev/nvidia* 2>&1 | head -5 || echo "  (no /dev/nvidia*)"
        echo "--- nvidia-smi -L ---"
        nvidia-smi -L 2>&1 | head -3 || echo "  (nvidia-smi failed)"
        echo ""

        echo "## Kubernetes state (one-line summary)"
        if command -v kubectl >/dev/null 2>&1; then
            kubectl get pods -A 2>&1 | grep -iE 'nvidia|vllm' | head -5 || echo "  (no relevant pods)"
            echo "  nvidia.com/gpu allocatable: $(kubectl get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo 'absent')"
        fi
        echo ""

        echo "## dmesg ring (last 50 PCIe/TB/nvidia lines)"
        dmesg 2>/dev/null | grep -iE 'nvidia|pcie|thunderbolt|aer|xid|gsp' | tail -50 || echo "  (no relevant lines)"
        echo ""

        echo "=== end capture ==="
    } > "$out"

    echo "captured to: $out ($(stat -c %s "$out") bytes)"
}

do_diff() {
    local eid="$1"
    local base="${OUT_DIR}/${eid}.baseline.txt"
    local snap="${OUT_DIR}/${eid}.snapshot.txt"

    if [ ! -f "$base" ]; then
        echo "no baseline at $base — run --baseline first" >&2
        exit 1
    fi
    if [ ! -f "$snap" ]; then
        echo "no snapshot at $snap — run --snapshot first" >&2
        exit 1
    fi

    echo "=== diff ${eid}: baseline → snapshot ==="
    echo "(filtered to MEANINGFUL state changes — timestamps and 'uptime' suppressed)"
    diff -u \
        <(grep -vE '^uptime:|@ 2026' "$base") \
        <(grep -vE '^uptime:|@ 2026' "$snap") || true
    echo "=== end diff ==="
}

do_list() {
    echo "=== captured experiments in ${OUT_DIR} ==="
    if [ -d "${OUT_DIR}" ]; then
        find "${OUT_DIR}" -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM  %f\n' 2>/dev/null | sort
    else
        echo "  (no captures yet — ${OUT_DIR} doesn't exist)"
    fi
}

main() {
    if [ $# -lt 1 ]; then
        usage
        exit 1
    fi
    case "$1" in
        --baseline)
            [ -z "${2:-}" ] && { echo "EID required" >&2; exit 1; }
            capture baseline "$2"
            ;;
        --snapshot)
            [ -z "${2:-}" ] && { echo "EID required" >&2; exit 1; }
            capture snapshot "$2"
            ;;
        --diff)
            [ -z "${2:-}" ] && { echo "EID required" >&2; exit 1; }
            do_diff "$2"
            ;;
        --list)
            do_list
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "unknown command: $1" >&2
            usage
            exit 1
            ;;
    esac
}

main "$@"
