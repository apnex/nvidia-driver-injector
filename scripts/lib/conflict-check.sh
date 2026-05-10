#!/usr/bin/env bash
# conflict-check.sh — refuse to install if apnex/aorus-5090-egpu
# artifacts are present on the host.
#
# The two repos are alternative geometries for deploying the same
# patched driver. They are NOT meant to coexist on the same host —
# overlapping modprobe.d, systemd services, and udev rules will fight
# each other and produce confusing failures.
#
# Sourced by install-host.sh; sets exit code 0 = clear, 1 = conflict.

# shellcheck disable=SC2148

aorus_artifacts=()

# Binaries from aorus-5090-egpu's apply.sh.
for f in /usr/local/sbin/aorus-egpu-* \
         /usr/local/lib/aorus-egpu \
         /etc/aorus-egpu \
         /var/lib/aorus-egpu; do
    [[ -e "$f" ]] && aorus_artifacts+=("$f")
done

# modprobe.d files.
# Note: /etc/modprobe.d/zz-aorus-egpu-blacklist.conf is the *transition*
# stub that aorus-5090-egpu's remove.sh deliberately installs to keep
# stock nvidia from auto-loading during the gap between remove.sh and
# whatever new install runs next. It is the documented "clean teardown
# signal", NOT an active-state artifact. install-host.sh removes it as
# part of dropping in our own modprobe.d (which provides equivalent
# blacklist coverage). So we don't flag it here.
for f in /etc/modprobe.d/aorus-egpu-*.conf; do
    [[ -e "$f" ]] && aorus_artifacts+=("$f")
done
# Other zz-aorus-egpu-*.conf files (anything other than blacklist)
# would still indicate an unclean teardown.
for f in /etc/modprobe.d/zz-aorus-egpu-*.conf; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == "zz-aorus-egpu-blacklist.conf" ]] && continue
    aorus_artifacts+=("$f")
done

# systemd units.
for f in /etc/systemd/system/aorus-egpu-*.service; do
    [[ -e "$f" ]] && aorus_artifacts+=("$f")
done

# udev rules.
for f in /etc/udev/rules.d/79-aorus-egpu-*.rules \
         /etc/udev/rules.d/81-aorus-egpu-*.rules; do
    [[ -e "$f" ]] && aorus_artifacts+=("$f")
done

# Active aorus services (would conflict at runtime even if files were
# moved aside).
if command -v systemctl >/dev/null 2>&1; then
    while IFS= read -r unit; do
        [[ -n "$unit" ]] && aorus_artifacts+=("active service: $unit")
    done < <(systemctl list-units --type=service --state=active 2>/dev/null \
             | awk '/aorus-egpu/ {print $1}')
fi

if [[ ${#aorus_artifacts[@]} -gt 0 ]]; then
    cat >&2 <<EOF
$(printf '\033[31m%s\033[0m\n' \
    "ERROR: aorus-5090-egpu artifacts detected on this host.")

This repo (nvidia-driver-injector) and apnex/aorus-5090-egpu are
alternative deployment geometries for the same patched driver and are
NOT meant to coexist. Mixing them will produce confusing failures
(overlapping modprobe.d directives, conflicting systemd ordering,
duplicate udev rules).

Found:
EOF
    printf '  %s\n' "${aorus_artifacts[@]}" >&2
    cat >&2 <<EOF

Resolution paths:
  1. (Recommended) Use the aorus-5090-egpu deployment instead. It is
     the more mature path. Run its apply.sh; ignore this repo.
  2. Switch fully to nvidia-driver-injector:
       cd /path/to/aorus-5090-egpu && sudo ./remove.sh && sudo reboot
       cd /path/to/nvidia-driver-injector
       sudo ./scripts/install-host.sh
  3. Force-install anyway (not recommended; you own the consequences):
       sudo ./scripts/install-host.sh --force-coexist

EOF
    return 1
fi

return 0
