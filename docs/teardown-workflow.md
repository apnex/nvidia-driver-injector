# Teardown workflow

How to remove the injector cleanly. The condensed version lives in the
top-level [`README.md`](../README.md); this doc is the reference.

For install, see [`install-workflow.md`](install-workflow.md). For the
underlying three-layer design, see [`architecture.md`](architecture.md).

## Three teardown shapes

| Shape | When | Touches |
|---|---|---|
| **Graceful unload** | Daily-driver pause, wedged-module recovery | Layer 2 only — module unloaded; host config intact |
| **Driver upgrade (cutover)** | New image tag (e.g. `aorus.N → N+1`) | Layer 2 only — module swapped without rebooting |
| **Full uninstall** | Decommission / "make this host look untouched" | Layer 3 → Layer 2 → Layer 1 |

## Graceful unload

`docker compose down` stops the container but **leaves `nvidia.ko` loaded** —
this asymmetry is deliberate (module state is host state; pod restart loops
must not hammer the close path). To gracefully unload:

```bash
docker compose run --rm driver-injector uninstall
```

The `uninstall` subcommand (defined in `entrypoint.sh`):

1. Returns immediately if no nvidia module is loaded.
2. Refuses if any process holds `/dev/nvidia*` (checked via `fuser`; falls
   back to `/sys/module/nvidia/refcnt` if `fuser` is missing).
3. `rmmod` in reverse-dependency order: `nvidia_uvm` → `nvidia_drm` →
   `nvidia_modeset` → `nvidia`.
4. Verifies each module is gone before exiting.

Exit 0 means the host is restored to its pre-load baseline. Re-run
`docker compose up -d` to reload.

If the refusal in (2) fires, stop the GPU consumers first:

```bash
sudo fuser /dev/nvidia*       # list holders
# stop vLLM / ollama / nvidia-persistenced / etc., then retry uninstall
```

## Driver upgrade (cutover)

Tag-bump sequence. Each step has a known failure mode and stops the chain
on non-zero exit. Validated against `aorus.13` → `aorus.14` on 2026-05-24.

```bash
cd /root/nvidia-driver-injector

# 1. Pre-flight — no active consumers.
sudo fuser /dev/nvidia*                              # expect: empty

# 2. Build the new image.
sudo docker build -t apnex/nvidia-driver-injector:595.71.05-aorus.<N+1> .

# 3. Graceful Layer 2 teardown (entrypoint's safe-path rmmod).
sudo docker compose run --rm driver-injector uninstall

# 4. Stop + remove the long-running container + its network.
sudo docker compose down

# 5. Bump the image tag in compose.
sudo sed -i 's|nvidia-driver-injector:595.71.05-aorus.<N>|nvidia-driver-injector:595.71.05-aorus.<N+1>|' docker-compose.yml

# 6. Start the new container (entrypoint rebuilds + modprobes new modules).
sudo docker compose up -d

# 7. Wait for the load to complete, then verify.
until lsmod | grep -q '^nvidia '; do sleep 5; done
sudo modinfo -F version nvidia                       # expect: 595.71.05-aorus.<N+1>
cat /sys/module/nvidia/refcnt                        # expect: 1 (just nvidia_uvm)
sudo scripts/status.sh                               # expect: 38/2/0 or better
```

Keep the previous image on disk for rollback —
`docker images apnex/nvidia-driver-injector` should show both tags.

### Rollback

```bash
sudo docker compose run --rm driver-injector uninstall
sudo docker compose down
sudo sed -i 's|nvidia-driver-injector:595.71.05-aorus.<N+1>|nvidia-driver-injector:595.71.05-aorus.<N>|' docker-compose.yml
sudo docker compose up -d
```

### What NOT to use during a tag bump

- `scripts/remove.sh` — reverses Layer 1. Layer 1 does not change between
  injector tags, so re-running it is unnecessary churn.
- `scripts/remove.sh --purge` — implies `--revert-cmdline`, requires a
  reboot. Far too disruptive for a tag bump within the same geometry.
- Raw `modprobe -r nvidia_uvm nvidia` — skips the active-consumer check
  the `uninstall` subcommand enforces. Works, but loses the safety gate.

## Full uninstall

Reverse the install order: workload → injector → host config.

```bash
# Layer 3 — your workload.
cd /path/to/your/workload && docker compose down

# Layer 2 — graceful unload then take the container down.
cd /root/nvidia-driver-injector
docker compose run --rm driver-injector uninstall
docker compose down

# Layer 1 — host config.
sudo ./scripts/remove.sh
```

`scripts/remove.sh` reverses `apply.sh` idempotently. The six numbered steps
are:

| # | What | Detail |
|---|---|---|
| 1 | Bridge-link-cap systemd unit | Stop, disable, remove `/etc/systemd/system/nvidia-driver-injector-bridge-link-cap.service` |
| 2 | Bridge-link-cap binary | Remove `/usr/local/sbin/nvidia-driver-injector-bridge-link-cap` |
| 3 | modprobe.d | Remove `/etc/modprobe.d/nvidia-driver-injector.conf` |
| 4 | udev rules | Remove `/etc/udev/rules.d/{79,80}-nvidia-driver-injector*.rules` |
| 5 | Re-enable ICDs | Rename `*.nvidia-driver-injector-disabled` back to original Vulkan / EGL / OpenCL ICD paths |
| 6 | Reload + optional cmdline revert | `systemctl daemon-reload`, `udevadm control --reload-rules`; cmdline only if `--revert-cmdline` |

It also cleans up the legacy `nvidia-driver-injector-gpu-engage.service`
artifacts if they exist (folded into the entrypoint on 2026-05-12).

### Flags

- `--no-act` — dry-run; print actions without making changes.
- `--revert-cmdline` — strip `iommu=off`, `intel_iommu=off`,
  `thunderbolt.host_reset=false`, `pcie_aspm.policy=performance`,
  `thunderbolt.clx=0`, `pcie_port_pm=off`, and `pci=resource_alignment=…`.
  **Reboot required after.** OFF by default because the cmdline tuning is
  useful for any deployment of this hardware, not just the injector.
- `--purge` — implies `--revert-cmdline` and additionally:
  - Removes `/lib/modules/<kver>/extra/nvidia*.ko*` (patched on-disk module
    left over from prior installs; without this the vendor `softdep` line in
    `/usr/lib/modprobe.d/nvidia.conf` will auto-load the stale binary on
    next boot, without our modprobe.d guards).
  - Restores `*.aorus-disabled` ICDs (legacy from a prior `aorus-5090-egpu`
    install that was never cleaned up).

  Use `--purge` when you want to validate the canonical "fresh Fedora +
  `apply.sh`" install path. **Reboot required after.**

### What `remove.sh` does NOT touch

By design, so the host stays usable:

- Kernel cmdline (unless `--revert-cmdline` or `--purge`).
- `kernel-devel` package (may be in use by other modules).
- `gpu` UNIX group (may be in use by other tools).
- `nvidia-persistenced` or other NVIDIA RPMs.
- The injector container itself (use `docker compose down` separately).

### Pre-flight warning

If `nvidia` is still loaded in the host kernel, `remove.sh` prints a yellow
warning and continues — it only touches host config files. The recommended
order is to take Layer 2 down first (`uninstall` subcommand + `compose
down`); this is just defence-in-depth so a partial state does not block the
host config cleanup.
