#!/usr/bin/env bash
# must-gather.sh — single-command diagnostic bundle for the nvidia-driver-injector.
#
# Run as root on the host. Produces a tar.gz under /tmp that operators
# can attach to bug reports. Mirrors NVIDIA gpu-operator's hack/must-gather.sh
# pattern (referenced from every "share more details" issue comment per
# G4 audit).
#
# Usage:
#   sudo /root/nvidia-driver-injector/tools/must-gather.sh
#
# Output: /tmp/nvidia-injector-must-gather-<UTC-ts>.tar.gz
#
# PRIVACY NOTICE — REVIEW BEFORE SHARING.
# The bundle includes node metadata, pod logs, full kernel journal, and
# systemd unit output. These may contain credentials (HF auth headers in
# vLLM logs, bearer tokens in API errors, Environment= secrets in unit
# files, cloud-provider IDs / account names in node annotations). Operators
# should grep the bundle for sensitive substrings before attaching to
# external bug reports.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "must run as root (need /sys/kernel access)" >&2
    exit 1
fi

ts=$(date -u +%Y%m%dT%H%M%SZ)
kver=$(uname -r)
workdir="/tmp/nvidia-injector-must-gather-${ts}"
mkdir -p "$workdir"
trap 'rm -rf "$workdir"' EXIT

log() { echo "[must-gather] $*"; }

log "collecting to $workdir"

# Host state
log "host kernel + cmdline"
echo "$kver" > "$workdir/uname-r.txt"
cat /proc/cmdline > "$workdir/cmdline.txt"

log "dmesg (full + filtered)"
dmesg > "$workdir/dmesg-full.txt" 2>&1 || true
dmesg 2>/dev/null | grep -iE 'nvidia|pcie|thunderbolt|aer|xid|gsp' > "$workdir/dmesg-relevant.txt" || true

log "journalctl current boot"
journalctl -k -b > "$workdir/journalctl-kernel.txt" 2>&1 || true
journalctl -u nvidia-driver-injector-bridge-link-cap.service > "$workdir/journalctl-bridge-link-cap.txt" 2>&1 || true
journalctl -u 'vllm-soak-*' > "$workdir/journalctl-vllm-soak.txt" 2>&1 || true

log "PCI topology"
lspci -nn > "$workdir/lspci-all.txt" 2>&1 || true
lspci -vvv > "$workdir/lspci-vvv.txt" 2>&1 || true
lspci -t -nn > "$workdir/lspci-tree.txt" 2>&1 || true

log "thunderbolt state"
boltctl list > "$workdir/boltctl.txt" 2>&1 || true
for d in /sys/bus/thunderbolt/devices/*/; do
    if [ -f "$d/unique_id" ]; then
        name=$(basename "$d")
        {
            echo "--- $name ---"
            for f in unique_id vendor_name device_name authorized; do
                printf '%s=%s\n' "$f" "$(cat "$d/$f" 2>/dev/null || echo '(absent)')"
            done
        } >> "$workdir/thunderbolt-sysfs.txt"
    fi
done

log "nvidia module + devices"
cat /sys/module/nvidia/version > "$workdir/nvidia-version.txt" 2>&1 || echo "(driver not loaded)" > "$workdir/nvidia-version.txt"
ls -la /dev/nvidia* > "$workdir/dev-nvidia.txt" 2>&1 || echo "(no /dev/nvidia*)" > "$workdir/dev-nvidia.txt"
ls -la "/lib/modules/${kver}/extra/nvidia"* > "$workdir/modules-extra.txt" 2>&1 || true

log "nvidia-smi if available"
nvidia-smi -q > "$workdir/nvidia-smi-q.txt" 2>&1 || echo "(nvidia-smi failed)" > "$workdir/nvidia-smi-q.txt"
nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total,temperature.gpu,power.draw --format=csv > "$workdir/nvidia-smi-csv.txt" 2>&1 || true

log "PC-3 readiness file (the canonical injector state)"
cat /run/nvidia/injector/state > "$workdir/pc3-state.json" 2>&1 || echo "(file absent — injector may not have completed startup)" > "$workdir/pc3-state.json"

log "kubernetes state"
if command -v kubectl >/dev/null 2>&1; then
    kubectl get pods -A -o wide > "$workdir/k8s-pods-all.txt" 2>&1 || true
    kubectl get nodes -o wide > "$workdir/k8s-nodes-wide.txt" 2>&1 || true
    kubectl describe nodes > "$workdir/k8s-nodes-describe.txt" 2>&1 || true
    kubectl get events -A --sort-by=.lastTimestamp > "$workdir/k8s-events.txt" 2>&1 || true
    kubectl logs -n kube-system -l app=nvidia-driver-injector --tail=200 > "$workdir/k8s-injector-logs.txt" 2>&1 || true
    kubectl logs -n kube-system -l name=nvidia-device-plugin-ds --tail=200 > "$workdir/k8s-device-plugin-logs.txt" 2>&1 || true
    kubectl logs -n vllm -l app=vllm --tail=200 > "$workdir/k8s-vllm-logs.txt" 2>&1 || true
else
    echo "(kubectl not available)" > "$workdir/k8s-skipped.txt"
fi

log "soak observability snapshot"
ls -la /var/log/vllm-soak/ > "$workdir/soak-dir-listing.txt" 2>&1 || true
cp /var/log/vllm-soak/metrics.csv "$workdir/soak-metrics.csv" 2>/dev/null || true
# shellcheck disable=SC2012  # ls -t for mtime sort; find -printf | sort is uglier and the dir is operator-owned
ls -t /var/log/vllm-soak/pods-*.txt 2>/dev/null | head -3 | xargs -I{} cp {} "$workdir/" 2>/dev/null || true

log "tar"
out="/tmp/nvidia-injector-must-gather-${ts}.tar.gz"
tar -czf "$out" -C /tmp "$(basename "$workdir")"
# workdir cleanup handled by EXIT trap

log "done: $out ($(stat -c %s "$out") bytes)"
log "attach this file to issues; share via: cp $out <destination>"
