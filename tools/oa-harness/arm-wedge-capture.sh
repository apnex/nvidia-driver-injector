#!/usr/bin/env bash
# arm-wedge-capture.sh — pre-arm forensic capture for the #292 close-path wedge retest
# (finding-2026-06-05-recovery-bringup-wedge-forensics.md).
#
# The wedge is SILENT (CONFIG_DETECT_HUNG_TASK is compiled OUT, so a blocked
# deferred-work hang auto-detects nothing) but the host SOFT-hangs (keyboard alive,
# sysrq works — proven by prior captures). This arms a PERTURBATION-SAFE, output-only
# capture: full sysrq + raised console loglevel + (optional) netconsole survivor.
#
# Usage:
#   sudo tools/oa-harness/arm-wedge-capture.sh arm [RECEIVER_IP]   # RECEIVER_IP optional (netconsole)
#   sudo tools/oa-harness/arm-wedge-capture.sh test                # emit a test line (verify netconsole)
#   sudo tools/oa-harness/arm-wedge-capture.sh disarm
#
# AT THE HANG — physical keyboard (host is soft-hung): Alt+SysRq+9, then w, t, l, d
#   9=max loglevel  w=blocked tasks  t=all task stacks  l=per-CPU backtrace  d=held locks
#   (the w + d are the money shot: which kthread/workqueue is blocked, on what lock)
# If a shell still responds: echo w >/proc/sysrq-trigger; echo t>...; echo l>...; echo d>...
set -uo pipefail
DEV="${NETCON_DEV:-enp86s0}"; PORT="${NETCON_PORT:-6666}"; LOCAL_IP="${NETCON_LOCAL_IP:-192.168.1.250}"
cmd="${1:-arm}"; RX="${2:-}"
NCBASE=/sys/kernel/config/netconsole/wedge

arm_sysrq() {
    echo 1 > /proc/sys/kernel/sysrq
    echo "kernel.sysrq = 1" > /etc/sysctl.d/99-forensic-sysrq.conf   # survive the cold-boot
    echo 8 > /proc/sys/kernel/printk                                  # console_loglevel=8 → all to console
    echo "[arm] sysrq=1 (all functions), console_loglevel=8, persisted via /etc/sysctl.d/99-forensic-sysrq.conf"
}

arm_netcon() {
    local rx="$1"
    modprobe netconsole 2>/dev/null || true
    mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config 2>/dev/null || true
    [ -d "$NCBASE" ] && { echo 0 > "$NCBASE/enabled" 2>/dev/null; rmdir "$NCBASE" 2>/dev/null; }
    mkdir -p "$NCBASE" || { echo "[arm] netconsole configfs unavailable"; return 1; }
    ping -c1 -W1 "$rx" >/dev/null 2>&1 || true                        # populate ARP
    local mac; mac=$(ip neigh show "$rx" 2>/dev/null | awk '/lladdr/{print $5; exit}')
    if [ -z "$mac" ]; then echo "[arm] WARN: cannot ARP-resolve $rx (receiver up + on $DEV subnet?) — netconsole NOT enabled"; return 1; fi
    echo "$DEV"      > "$NCBASE/dev_name"
    echo "$LOCAL_IP" > "$NCBASE/local_ip"
    echo "$PORT"     > "$NCBASE/local_port"  2>/dev/null || true
    echo "$rx"       > "$NCBASE/remote_ip"
    echo "$PORT"     > "$NCBASE/remote_port"
    echo "$mac"      > "$NCBASE/remote_mac"
    echo 1           > "$NCBASE/enabled"
    echo "[arm] netconsole → $rx:$PORT (mac $mac) via $DEV"
    echo "       RECEIVER (run on $rx): nc -u -l $PORT | tee obpc-netcon-\$(date +%H%M).log   (or: socat -u UDP-RECV:$PORT -)"
}

case "$cmd" in
    arm)
        arm_sysrq
        if [ -n "$RX" ]; then arm_netcon "$RX" || echo "[arm] proceeding with screen+sysrq only";
        else echo "[arm] no RECEIVER_IP — screen+sysrq only: switch to a text VT (Ctrl+Alt+F3) before recovery, then Alt+SysRq+9/w/t/l/d at the hang"; fi
        echo "WEDGE-CAPTURE ARMED $(date -u +%FT%TZ)" > /dev/kmsg
        echo "[arm] DONE. Verify netconsole with: $0 test"
        ;;
    test) echo "WEDGE-CAPTURE TEST $(date -u +%FT%TZ) — visible on the receiver ⇒ netconsole works" > /dev/kmsg; echo "[test] emitted to /dev/kmsg" ;;
    disarm)
        [ -d "$NCBASE" ] && { echo 0 > "$NCBASE/enabled" 2>/dev/null; rmdir "$NCBASE" 2>/dev/null; }
        rm -f /etc/sysctl.d/99-forensic-sysrq.conf
        echo "[disarm] netconsole target removed; sysrq persistence file removed (runtime sysrq left as-is)"
        ;;
    *) echo "usage: $0 {arm [RECEIVER_IP]|test|disarm}"; exit 1 ;;
esac
