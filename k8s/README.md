# Kubernetes deployment

`daemonset.yaml` deploys the patched NVIDIA driver as a per-node DaemonSet.
One pod per opted-in GPU node;
pod builds + loads `nvidia.ko` into the node's host kernel.

## Quick start

```bash
# 1. Opt in the GPU node(s)
kubectl label node <node-name> apnex.com.au/aorus-egpu=true

# 2. Apply the DaemonSet
kubectl apply -f daemonset.yaml

# 3. Watch the build + load
kubectl logs -n kube-system -l app.kubernetes.io/name=nvidia-driver-injector -f

# 4. Verify on the node
ssh <node> 'cat /sys/module/nvidia/version'   # should print 595.71.05-aorus.13
```

## What this DaemonSet replaces

It replaces the **kernel-driver** half of NVIDIA's GPU Operator.
The other halves (device plugin, container toolkit, DCGM exporter,
MIG manager) stay as upstream NVIDIA components.
Specifically:

| GPU Operator component | Status with this stack |
|---|---|
| Driver Operator / Driver DaemonSet | **Replaced** by this DaemonSet (our patched build) |
| Container Toolkit | Use upstream NVIDIA Container Toolkit unchanged |
| Device Plugin | Use upstream `nvidia-device-plugin` DaemonSet |
| DCGM Exporter | Use upstream `dcgm-exporter` |
| MIG Manager | Use upstream `nvidia-mig-manager` if you need MIG |

## Node prerequisites

Each labelled GPU node must already have host-side configuration in place
(this is NOT done by the DaemonSet —
it would need to be a separate one or pre-cluster-join setup):

- Kernel cmdline tuned:
  `iommu=off`,
  `thunderbolt.host_reset=false`,
  `pci=resource_alignment=35@<bridge_bdf>`,
  `pcie_aspm.policy=performance`,
  `thunderbolt.clx=0`,
  `pcie_port_pm=off`
- `kernel-devel` matching the running kernel
  (i.e. `/lib/modules/$(uname -r)/build` exists)
- udev rules to gate `/dev/nvidia*` permissions
  (this repo ships them under `scripts/host-files/etc/udev/rules.d/`)
- the bridge LnkCtl2 cap (Lever H17) applied at boot
  (this repo's `nvidia-driver-injector-bridge-link-cap.service`)

This repo's `scripts/apply.sh` performs the full host bring-up on a single
host; for cluster nodes, replicate what it does via your config-management
tool of choice (Ansible / Talos machine config / cloud-init).

## What's NOT in this DaemonSet

Deliberate scope limits:

- **Layer 1 host bring-up** —
  kernel cmdline, `modprobe.d`, the bridge-link-cap service, udev rules.
  These are node prerequisites (see above);
  `scripts/apply.sh` does them on a single host.
- **Container Toolkit** —
  use NVIDIA's upstream image (independent of this driver).
- **Device Plugin** —
  use NVIDIA's upstream image
  (`registry.k8s.io/nvidia/k8s-device-plugin`).

## Resource cleanup

```bash
kubectl delete -f daemonset.yaml
```

This stops the pod.
The kernel module **stays loaded** in the host kernel
(modules persist past container exit).
To unload manually:
`ssh <node> 'sudo modprobe -r nvidia_uvm nvidia'`.

To uninstall the patched build entirely
(restore distro stock or switch to a different driver),
remove `/lib/modules/<kver>/extra/nvidia.ko` on the node + `depmod -a`.
