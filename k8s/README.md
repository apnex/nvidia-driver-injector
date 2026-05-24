# Kubernetes deployment (Path B)

`daemonset.yaml` deploys the patched NVIDIA driver as a per-node DaemonSet,
plus the SA / ClusterRole / ClusterRoleBinding needed for the node-label
writes that gate GPU consumer pods.

This is the **canonical production deployment path** for this stack. The
docker-compose path at the repo root (`docker-compose.yml`) is Path A — still
supported for dev / single-host operator use. See
[`../docs/install-workflow.md`](../docs/install-workflow.md) for the Path A /
Path B split.

## Quick start

```bash
# 1. Layer 1 (host bring-up — same on both paths)
sudo /root/nvidia-driver-injector/scripts/apply.sh

# 2. Build the image + import to containerd
docker build -t apnex/nvidia-driver-injector:595.71.05-aorus.14 \
    /root/nvidia-driver-injector
docker save apnex/nvidia-driver-injector:595.71.05-aorus.14 \
    | sudo k3s ctr images import -

# 3. Apply the DaemonSet
kubectl apply -f daemonset.yaml
kubectl rollout status -n kube-system ds/nvidia-driver-injector

# 4. Verify
kubectl get nodes -L nvidia.driver/state,nvidia.driver/version
# NAME   STATE   VERSION
# obpc   ready   595.71.05-aorus.14
```

The DaemonSet pod's entrypoint runs the same five steps the docker-compose
entrypoint does (PCI gate, BAR1 verify, build, modprobe, perms +
persistence) then writes the node label.

## Architectural shape

It replaces the **kernel-driver** half of NVIDIA's GPU Operator. By
deliberate YAGNI calls we do NOT run the rest:

| GPU Operator component | Status on this stack |
|---|---|
| Driver Operator / Driver DaemonSet | **Replaced** by this DaemonSet (our patched build) |
| Container Toolkit | Use upstream `nvidia-container-toolkit` (host RPM); `scripts/apply.sh` step 9 runs `nvidia-ctk runtime configure --runtime=containerd` |
| `RuntimeClass nvidia` | Installed by `scripts/apply.sh` step 9 |
| Device Plugin | **Not used.** Single GPU + single consumer (vLLM) + no scheduler-side accounting needed. Consumer Deployments use `NVIDIA_VISIBLE_DEVICES=all` + the `nvidia` runtime class. |
| DCGM Exporter | Not deployed. Use vLLM's `/metrics` or `kubectl exec` into the injector pod for `nvidia-smi`. |
| MIG Manager | N/A — RTX 5090 doesn't do MIG. |

## Node prerequisites

`scripts/apply.sh` (Layer 1) sets all of this up. Listed here for
config-management replication on multi-node clusters:

- Kernel cmdline tuned: `iommu=off`, `intel_iommu=off`,
  `thunderbolt.host_reset=false`, `pci=resource_alignment=35@<bridge_bdf>`,
  `pcie_aspm.policy=performance`, `thunderbolt.clx=0`, `pcie_port_pm=off`
- `kernel-devel` matching the running kernel (so
  `/lib/modules/$(uname -r)/build` exists)
- `/etc/modprobe.d/nvidia-driver-injector.conf` with the production NVreg
  options
- udev rules under `scripts/host-files/etc/udev/rules.d/` (gate `/dev/nvidia*`
  permissions + unbind the HDMI audio function)
- `nvidia-driver-injector-bridge-link-cap.service` (Lever H17 cap, ordered
  `Before=docker.service` / before kubelet's containerd would bind nvidia)
- `nvidia-container-toolkit` installed + `nvidia-ctk runtime configure
  --runtime=containerd` (so containerd / k3s knows the `nvidia` runtime
  handler exists)
- `RuntimeClass nvidia` in the cluster (so consumer pods can request it)

The repo's `scripts/apply.sh` performs the full bring-up on a single host;
for cluster nodes, replicate what it does via your config-management tool
of choice (Ansible / Talos machine config / cloud-init).

## Producer / consumer contract

The DaemonSet is the **producer**. The contract it publishes to GPU consumer
pods is documented in [`../docs/consumer-contract.md`](../docs/consumer-contract.md).
Summary:

- After successful module load, the entrypoint labels the node
  `nvidia.driver/state=ready` + `nvidia.driver/version=<v>`.
- On graceful uninstall (the `uninstall` subcommand), both labels are removed
  **before** any rmmod fires, so consumers stop scheduling immediately.
- GPU consumers (vLLM etc.) set
  `spec.nodeSelector: { nvidia.driver/state: ready }` +
  `spec.runtimeClassName: nvidia` +
  `env: NVIDIA_VISIBLE_DEVICES=all` +
  `env: NVIDIA_DRIVER_CAPABILITIES=compute,utility`.

## What's NOT in this DaemonSet

Deliberate scope limits:

- **Layer 1 host bring-up** — kernel cmdline, `modprobe.d`, the
  bridge-link-cap service, udev rules, containerd nvidia handler. These are
  node prerequisites; `scripts/apply.sh` does them on a single host.
- **`nvidia-device-plugin`** — see YAGNI call above.
- **DCGM Exporter / metrics** — not in scope.

## Resource cleanup

See [`../docs/teardown-workflow.md`](../docs/teardown-workflow.md) §Path B
for the full ladder (graceful unload, driver upgrade, full uninstall). Short
version:

```bash
# Graceful unload (module unloaded, host config intact):
kubectl exec -n kube-system daemonset/nvidia-driver-injector -- /entrypoint.sh uninstall
kubectl delete -f daemonset.yaml

# Full uninstall (also reverse Layer 1):
sudo /root/nvidia-driver-injector/scripts/remove.sh
```
