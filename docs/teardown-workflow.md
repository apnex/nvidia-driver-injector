# Teardown workflow

How to remove the injector cleanly. The condensed version lives in the
top-level [`README.md`](../README.md); this doc is the reference.

For install, see [`install-workflow.md`](install-workflow.md). For the
underlying three-layer design, see [`architecture.md`](architecture.md). For
the producer / consumer contract (Path B only), see
[`consumer-contract.md`](consumer-contract.md).

## Three teardown shapes (both paths)

| Shape | When | Touches |
|---|---|---|
| **Graceful unload** | Daily-driver pause, wedged-module recovery | Layer 2 only — module unloaded; host config intact |
| **Driver upgrade (cutover)** | New image tag (e.g. `aorus.N → N+1`) | Layer 2 only — module swapped without rebooting |
| **Full uninstall** | Decommission / "make this host look untouched" | Layer 3 → Layer 2 → Layer 1 |

The shape you want is the same regardless of deployment path; what differs is
the **commands**. Each section below splits into Path A (docker-compose) and
Path B (k3s DaemonSet).

## Graceful unload

The `uninstall` subcommand (defined in `entrypoint.sh`) does the same thing
on both paths:

1. Removes the `nvidia.driver/state` + `nvidia.driver/version` node labels
   (no-op if not running in a cluster) so consumers stop scheduling.
2. Returns immediately if no nvidia module is loaded.
3. Refuses if any process holds `/dev/nvidia*` (checked via `fuser`; falls
   back to `/sys/module/nvidia/refcnt` if `fuser` is missing).
4. `rmmod` in reverse-dependency order: `nvidia_uvm` → `nvidia_drm` →
   `nvidia_modeset` → `nvidia`.
5. Verifies each module is gone before exiting.

### Path A (docker-compose)

`docker compose down` stops the container but **leaves `nvidia.ko` loaded** —
this asymmetry is deliberate (module state is host state; pod restart loops
must not hammer the close path). To gracefully unload:

```bash
docker compose run --rm driver-injector uninstall
```

Exit 0 means the host is restored to its pre-load baseline. Re-run
`docker compose up -d` to reload.

### Path B (k3s DaemonSet)

```bash
# Exec the uninstall subcommand inside the live DaemonSet pod. This goes
# through the same safety gate (label-remove → fuser check → rmmod sequence)
# as the docker-compose path.
kubectl exec -n kube-system daemonset/nvidia-driver-injector -- \
    /entrypoint.sh uninstall

# Then take the DaemonSet down so kubelet doesn't immediately restart it.
kubectl delete -f k8s/daemonset.yaml
```

Order matters here: `kubectl delete` alone sends SIGTERM, which the entrypoint
does NOT handle as an `uninstall` trigger (deliberate — see entrypoint.sh
comment "Why this is a SUBCOMMAND, not a SIGTERM trap"). If you delete the
DaemonSet without first running `uninstall`, the pod stops but
`nvidia.ko` stays loaded in the host kernel until the next reboot or an
explicit `modprobe -r`.

If the refusal in step 3 fires (active consumers), stop those first:

```bash
# Find consumers (Path B):
kubectl get pods --all-namespaces -o json \
    | jq -r '.items[] | select(.spec.runtimeClassName=="nvidia") | "\(.metadata.namespace)/\(.metadata.name)"'

# Path A: stop vLLM / ollama / nvidia-persistenced / etc., then retry uninstall:
sudo fuser /dev/nvidia*       # list holders
```

## Driver upgrade (cutover)

Tag-bump sequence. Each step has a known failure mode and stops the chain
on non-zero exit. Validated against `aorus.13` → `aorus.14` on 2026-05-24.

### Path A (docker-compose)

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
sudo scripts/status.sh                               # expect: 40/0/0 or better
```

Keep the previous image on disk for rollback —
`docker images apnex/nvidia-driver-injector` should show both tags.

### Path B (k3s DaemonSet)

```bash
cd /root/nvidia-driver-injector

# 1. Pre-flight — no active consumers on the node.
kubectl get pods --all-namespaces -o json \
    | jq -r '.items[] | select(.spec.runtimeClassName=="nvidia") | "\(.metadata.namespace)/\(.metadata.name)"'

# 2. Build the new image and import to containerd.
sudo docker build -t apnex/nvidia-driver-injector:595.71.05-aorus.<N+1> .
sudo docker save apnex/nvidia-driver-injector:595.71.05-aorus.<N+1> \
    | sudo k3s ctr images import -

# 3. Graceful Layer 2 teardown (in the live pod).
kubectl exec -n kube-system daemonset/nvidia-driver-injector -- \
    /entrypoint.sh uninstall

# 4. Tear down the old DaemonSet. The entrypoint we just ran already wrote
#    the labels off; the pod exits and kubelet won't restart it.
kubectl delete -f k8s/daemonset.yaml

# 5. Bump the image tag in the DaemonSet.
sudo sed -i 's|nvidia-driver-injector:595.71.05-aorus.<N>|nvidia-driver-injector:595.71.05-aorus.<N+1>|' k8s/daemonset.yaml

# 6. Apply the new DaemonSet (entrypoint rebuilds + modprobes new modules
#    and writes the version label to match).
kubectl apply -f k8s/daemonset.yaml
kubectl rollout status -n kube-system ds/nvidia-driver-injector

# 7. Verify.
kubectl get nodes -L nvidia.driver/version
# expect: VERSION = 595.71.05-aorus.<N+1>
sudo scripts/status.sh                               # expect: 39/0/0 or better
                                                     # (Path B is one fewer than Path A's 40)
```

**Why delete-and-apply rather than rolling update:** the DaemonSet's image
change DOES trigger a normal rolling update — but the pod is a "container of
intent" that sleeps forever once the module is loaded, so kubelet sees no
reason to terminate it on its own. The safe pattern is: explicit `uninstall`
(which removes labels first → unloads modules), then delete the DaemonSet,
then apply with the new tag. Skipping the `uninstall` step leaves the OLD
module loaded in the host kernel while the NEW pod tries to insert
freshly-built modules with the same name.

### Rollback (both paths)

Path A:

```bash
sudo docker compose run --rm driver-injector uninstall
sudo docker compose down
sudo sed -i 's|nvidia-driver-injector:595.71.05-aorus.<N+1>|nvidia-driver-injector:595.71.05-aorus.<N>|' docker-compose.yml
sudo docker compose up -d
```

Path B:

```bash
kubectl exec -n kube-system daemonset/nvidia-driver-injector -- \
    /entrypoint.sh uninstall
kubectl delete -f k8s/daemonset.yaml
sudo sed -i 's|nvidia-driver-injector:595.71.05-aorus.<N+1>|nvidia-driver-injector:595.71.05-aorus.<N>|' k8s/daemonset.yaml
kubectl apply -f k8s/daemonset.yaml
```

### What NOT to use during a tag bump (both paths)

- `scripts/remove.sh` — reverses Layer 1. Layer 1 does not change between
  injector tags, so re-running it is unnecessary churn.
- `scripts/remove.sh --purge` — implies `--revert-cmdline`, requires a
  reboot. Far too disruptive for a tag bump within the same geometry.
- Raw `modprobe -r nvidia_uvm nvidia` — skips the active-consumer check
  the `uninstall` subcommand enforces. Works, but loses the safety gate.
- Path B: `kubectl rollout restart ds/nvidia-driver-injector` — does NOT
  unload the existing kernel module before the new pod starts. See "Why
  delete-and-apply" above.

## Full uninstall

Reverse the install order: workload → injector → host config.

### Path A (docker-compose)

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

### Path B (k3s DaemonSet)

```bash
# Layer 3 — your GPU consumer(s). Use --ignore-not-found so the step
# is a no-op if no consumer is currently running.
kubectl delete deploy/vllm -n default --ignore-not-found

# Layer 2 — graceful unload then delete the DaemonSet.
cd /root/nvidia-driver-injector
kubectl exec -n kube-system daemonset/nvidia-driver-injector -- /entrypoint.sh uninstall
kubectl delete -f k8s/daemonset.yaml

# Layer 1 — host config. remove.sh also removes the cluster-side
# RuntimeClass/nvidia (under --skip-k3s, leave it alone).
sudo ./scripts/remove.sh
```

`scripts/remove.sh` reverses `apply.sh` idempotently. The seven numbered steps
are:

| # | What | Detail |
|---|---|---|
| 1 | Bridge-link-cap systemd unit | Stop, disable, remove `/etc/systemd/system/nvidia-driver-injector-bridge-link-cap.service` |
| 2 | Bridge-link-cap binary | Remove `/usr/local/sbin/nvidia-driver-injector-bridge-link-cap` |
| 3 | modprobe.d | Remove `/etc/modprobe.d/nvidia-driver-injector.conf` |
| 4 | udev rules | Remove `/etc/udev/rules.d/{79,80}-nvidia-driver-injector*.rules` |
| 5 | Re-enable ICDs | Rename `*.nvidia-driver-injector-disabled` back to original Vulkan / EGL / OpenCL ICD paths |
| 6 | k3s teardown | Under `--purge` only: delete cluster-side `RuntimeClass nvidia` + remove `nvidia-ctk` containerd drop-ins. Default leaves both alone (RuntimeClass may pre-exist from other tools; `apply.sh` only creates-if-missing). Skip entirely with `--skip-k3s` |
| 7 | Reload + optional cmdline revert | `systemctl daemon-reload`, `udevadm control --reload-rules`; cmdline only if `--revert-cmdline` |

It also cleans up the legacy `nvidia-driver-injector-gpu-engage.service`
artifacts if they exist (folded into the entrypoint on 2026-05-12).

### Flags

- `--no-act` — dry-run; print actions without making changes.
- `--revert-cmdline` — strip `iommu=off`, `intel_iommu=off`,
  `thunderbolt.host_reset=false`, `pcie_aspm.policy=performance`,
  `thunderbolt.clx=0`, `pcie_port_pm=off`, and `pci=resource_alignment=…`.
  **Reboot required after.** OFF by default because the cmdline tuning is
  useful for any deployment of this hardware, not just the injector.
- `--skip-k3s` — leave `RuntimeClass nvidia` and containerd config alone.
  Mirrors `apply.sh --skip-k3s`. Use on docker-compose-only hosts or when
  another tool manages the cluster-side runtime.
- `--purge` — implies `--revert-cmdline` and additionally:
  - Removes `/lib/modules/<kver>/extra/nvidia*.ko*` (patched on-disk module
    left over from prior installs; without this the vendor `softdep` line in
    `/usr/lib/modprobe.d/nvidia.conf` will auto-load the stale binary on
    next boot, without our modprobe.d guards).
  - Restores `*.aorus-disabled` ICDs (legacy from a prior `aorus-5090-egpu`
    install that was never cleaned up).
  - Removes `nvidia-ctk` containerd config drop-ins
    (`/etc/containerd/config.toml.d/{99-,}nvidia.toml`). Note: k3s also
    auto-detects nvidia-container-runtime by binary presence at
    `/usr/bin/nvidia-container-runtime`; to fully unwire the nvidia runtime
    from k3s, also uninstall `nvidia-container-toolkit`.

  Use `--purge` when you want to validate the canonical "fresh Fedora +
  `apply.sh`" install path. **Reboot required after.**

### What `remove.sh` does NOT touch

By design, so the host stays usable:

- Kernel cmdline (unless `--revert-cmdline` or `--purge`).
- `kernel-devel` package (may be in use by other modules).
- `gpu` UNIX group (may be in use by other tools).
- `nvidia-persistenced` or other NVIDIA RPMs.
- `nvidia-container-toolkit` (its drop-ins are touched only under `--purge`).
- The injector container itself (use `docker compose down` or `kubectl
  delete` separately).

### Pre-flight warning

If `nvidia` is still loaded in the host kernel, `remove.sh` prints a yellow
warning and continues — it only touches host config files. The recommended
order is to take Layer 2 down first (`uninstall` subcommand + `compose
down` / `kubectl delete`); this is just defence-in-depth so a partial state
does not block the host config cleanup.
