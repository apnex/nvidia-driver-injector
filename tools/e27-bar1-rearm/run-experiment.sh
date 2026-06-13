#!/usr/bin/env bash
# run-experiment.sh -- E27 BAR1 re-arm experiment harness.
#
# Drives the tbegpu_bar1_rearm module (deterministic in-kernel BAR1 recovery via
# exported PCI primitives) through staged validation:
#   stage 0  dry-run survey on the current tree (NO writes anywhere)
#   stage 1  WET run on the current tree -- "aligned positive control": does the
#            release+resize cleanly re-land the root-port window at the 32G base
#            and BAR1=32G WITHOUT breaking a healthy tree?
#   stage 2  WET run n>=3 on a MISALIGNED tree -- the actual recovery proof.
#            Requires the failure substrate (root-port prefetch window NOT
#            32G-aligned); the harness only runs it when that substrate is
#            present (it will not try to force it -- aging is uncontrolled).
#
# ⚠ REBOOT-RISK: live PCI bridge-window surgery. PRECONDITIONS the operator must
# satisfy: at the console; capture armed (tools/oa-harness/arm-wedge-capture.sh
# arm <rx>); softlockup/hardlockup_panic=1; nvidia will be rmmod'd (interrupts
# the apnex soak, resets its clock); NO cable touch during a run. The module's
# pci_lock_rescan_remove bracket makes it safe vs pciehp races, but a wrong
# substrate or a kernel surprise can still wedge -- capture is the safety net.
#
# Usage:  sudo CONFIRM=yes ./run-experiment.sh [0|1|2]    (default stage 0)
#         GPU=… ROOT_PORT=… N=… override defaults.
set -euo pipefail

GPU=${GPU:-0000:04:00.0}
ROOT_PORT=${ROOT_PORT:-0000:00:07.0}
N=${N:-3}
STAGE=${1:-0}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD=tbegpu_bar1_rearm
KO="$HERE/${MOD}.ko"
DS_NS=kube-system
DS_NAME=nvidia-driver-injector
ALIGN_32G=$((0x800000000))   # 32 GiB

log()   { printf '[e27-exp] %s\n' "$*"; }
warn()  { printf '[e27-exp] WARN: %s\n' "$*" >&2; }
fatal() { printf '[e27-exp] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fatal "run as root"
[[ "${CONFIRM:-}" == "yes" ]] || fatal "destructive live experiment; re-run with CONFIRM=yes once at-console + capture-armed.
  checklist: arm-wedge-capture.sh arm <rx> ; echo 1 > /proc/sys/kernel/{soft,hard}lockup_panic ; no cable touch."

# ---------- preflight ----------
assert_cmdline() {
	local c; c=$(cat /proc/cmdline)
	[[ "$c" == *hpmmioprefsize=32G* ]] || fatal "cmdline missing pci=hpmmioprefsize=32G (the root-port reserve the resize relies on)"
	[[ "$c" == *realloc=on*         ]] || warn  "cmdline missing pci=realloc=on"
}

capture_armed() {
	[[ "$(cat /sys/kernel/config/netconsole/*/enabled 2>/dev/null | head -1)" == "1" ]]
}

# ---------- topology reads (passive) ----------
root_pref_base() {   # hex base of the root port's prefetchable window, no 0x
	lspci -s "${ROOT_PORT#0000:}" -vv 2>/dev/null \
	  | awk '/Prefetchable memory behind bridge/ {split($5,a,"-"); print a[1]; exit}'
}
root_is_aligned() {  # 0 = aligned (substrate ABSENT), 1 = misaligned (substrate PRESENT)
	local b; b=$(root_pref_base); [[ -n "$b" ]] || return 2
	(( 0x$b % ALIGN_32G == 0 ))
}
gpu_bar1_mib() {     # integer MiB of the GPU's BAR1, 0 if unset (cf. fix-bar1 #304)
	local s e; read -r s e < <(awk 'NR==2{print $1,$2;exit}' "/sys/bus/pci/devices/$GPU/resource")
	[[ "$s" =~ ^0x[0-9a-f]+$ && "$e" =~ ^0x[0-9a-f]+$ ]] || { echo 0; return; }
	(( s==0 && e==0 )) && { echo 0; return; }
	echo $(( (e - s + 1) / 1024 / 1024 ))
}

# ---------- driver lifecycle ----------
drain_and_unload() {
	log "draining injector + unloading nvidia (interrupts the soak)"
	kubectl patch ds -n "$DS_NS" "$DS_NAME" --type merge \
	  -p '{"spec":{"template":{"spec":{"nodeSelector":{"oa.recovery-drain/excluded":"true"}}}}}' >/dev/null 2>&1 || warn "DS patch failed (injector not k8s?)"
	kubectl delete pod -n "$DS_NS" -l app.kubernetes.io/name="$DS_NAME" --wait=true --timeout=60s >/dev/null 2>&1 || true
	nvidia-smi -pm 0 >/dev/null 2>&1 || true
	rmmod nvidia_uvm 2>/dev/null || true
	rmmod nvidia 2>/dev/null || true
	lsmod | grep -q '^nvidia ' && fatal "nvidia still loaded after rmmod (consumers?)"
	[[ -L "/sys/bus/pci/devices/$GPU/driver" ]] && fatal "GPU still has a driver bound"
	log "nvidia unloaded; GPU unbound ✓"
}
restore() {
	log "restoring: BAR1=$(gpu_bar1_mib) MiB"
	if [[ "$(gpu_bar1_mib)" -lt 32768 ]]; then
		warn "BAR1 not 32G -- recovering via fix-bar1 --bind"
		"$HERE/../fix-bar1.sh" --bind || warn "fix-bar1 recovery failed -- manual recovery needed"
	fi
	kubectl patch ds -n "$DS_NS" "$DS_NAME" --type merge \
	  -p '{"spec":{"template":{"spec":{"nodeSelector":null}}}}' >/dev/null 2>&1 || true
	log "injector un-drained; it will re-adopt/reload the driver"
}

# ---------- one module run; echoes the parsed RESULT= line ----------
run_module() {   # $1 = dry_run (1|0)
	local dr="$1" since result
	since=$(dmesg | tail -1 | grep -oE '^\[[0-9. ]+\]' || true)
	insmod "$KO" gpu="$GPU" dry_run="$dr" || { warn "insmod failed"; return 1; }
	sleep 1
	dmesg | grep 'tbegpu-rearm:' | sed 's/^/    /' | tail -25
	result=$(dmesg | grep -oE 'RESULT=[A-Z]+[^\n]*' | tail -1)
	rmmod "$MOD" 2>/dev/null || warn "rmmod $MOD failed (module wedged?)"
	echo "$result"
}

# ---------- stages ----------
echo "=== E27 BAR1 re-arm experiment — stage $STAGE ==="
assert_cmdline
[[ "$(modinfo -F vermagic "$KO" 2>/dev/null)" == "$(uname -r)"* ]] || { log "building module"; make -C "$HERE" >/dev/null || fatal "module build failed"; }
capture_armed || warn "netconsole capture does NOT look armed — arm it before a WET stage"
log "root-port $ROOT_PORT pref base = 0x$(root_pref_base)  (substrate $(root_is_aligned && echo ABSENT/aligned || echo PRESENT/misaligned))"
log "GPU BAR1 = $(gpu_bar1_mib) MiB"

case "$STAGE" in
0)
	log "STAGE 0 — dry-run survey (no writes)"
	drain_and_unload
	r=$(run_module 1)
	restore
	log "STAGE 0 result: ${r:-<none>}  (expect RESULT=DRYRUN)"
	[[ "$r" == RESULT=DRYRUN* ]] && log "STAGE 0 PASS ✓" || warn "STAGE 0 unexpected"
	;;
1)
	log "STAGE 1 — WET run on current tree (aligned positive control)"
	capture_armed || fatal "arm capture before a WET stage"
	drain_and_unload
	r=$(run_module 0)
	log "host ALIVE; STAGE 1 result: ${r:-<none>}"
	restore
	[[ "$r" == RESULT=OK* ]] && log "STAGE 1 PASS ✓ (mechanism re-landed 32G@aligned, healthy tree intact)" \
	                         || warn "STAGE 1 result not OK — inspect dmesg + $r"
	;;
2)
	log "STAGE 2 — WET recovery proof, n=$N (needs MISALIGNED substrate)"
	capture_armed || fatal "arm capture before a WET stage"
	if root_is_aligned; then
		fatal "substrate ABSENT: root-port window is 32G-aligned (0x$(root_pref_base)). Stage 2 needs an AGED/misaligned tree.
  To attempt aging: repeated TB deauth/reauth + fix-bar1 cycles until '$ROOT_PORT' base is NOT 32G-aligned, then re-run stage 2.
  (Aging is uncontrolled; do it at-console with capture armed.)"
	fi
	pass=0
	for i in $(seq 1 "$N"); do
		log "--- cycle $i/$N (substrate base 0x$(root_pref_base)) ---"
		drain_and_unload
		r=$(run_module 0)
		log "host ALIVE; cycle $i result: ${r:-<none>}"
		[[ "$r" == RESULT=OK* ]] && pass=$((pass+1))
		restore
		# re-age for the next cycle is operator-driven; stop if substrate gone
		if [[ $i -lt $N ]] && root_is_aligned; then
			warn "substrate consumed (tree now aligned) — re-age before continuing; stopping at $i/$N"; break
		fi
	done
	log "STAGE 2: $pass/$N RESULT=OK"
	[[ "$pass" -ge "$N" ]] && log "STAGE 2 PASS ✓ — half-(b) deterministic recovery confirmed" \
	                       || warn "STAGE 2 not yet n>=$N — see dmesg"
	;;
*) fatal "unknown stage '$STAGE' (use 0|1|2)";;
esac
log "done."
