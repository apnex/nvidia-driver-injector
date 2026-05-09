# nvidia-driver-injector

A containerised kernel-injector for the **patched NVIDIA open kernel module**
([`595.71.05-aorus.12`](https://github.com/apnex/aorus-5090-egpu))
that mitigates the silent host-freeze bug at
[NVIDIA/open-gpu-kernel-modules#979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979)
and adds in-driver Mode B detection (Lever Q-watchdog) +
recovery state machine (Lever M-recover).
Deployable via Docker on a single host or as a DaemonSet in Kubernetes.

**Status:** MVP, 2026-05-09. Tested on Fedora 43 + 6.19.14-200.fc43.x86_64.
Single-image, distro-neutral approach (Approach B —
host bind-mounts `/lib/modules` for the kernel build dir).

## What it does

A privileged container that runs five steps on each pod start
(matching the responsibilities historically owned by
`aorus-egpu-compute-load-nvidia.service` on the host):

1. **PCI gate** —
   verify the eGPU is enumerated;
   exit cleanly if not.
2. **BAR1 verify** —
   confirm BAR1 = 32 GiB;
   refuse to load if smaller (catches missing kernel cmdline tuning).
3. **Build** —
   compile the patched module against the host's running kernel
   using `/lib/modules/$(uname -r)/build` bind-mounted from the host.
4. **Load** —
   `insmod nvidia.ko` + `insmod nvidia-uvm.ko` directly into the host kernel.
5. **UVM device files** —
   `nvidia-modprobe -u -c 0` materialises `/dev/nvidia-uvm-tools`.

Then `sleep infinity` as a "container of intent" —
exit triggers the pod restart policy.

## Companion repo (host-side prerequisites)

This image only handles the kernel module.
The host-side configuration
(kernel cmdline, udev rules, modprobe.d, Lever H17 LnkCtl2 cap)
lives in
[`apnex/aorus-5090-egpu`](https://github.com/apnex/aorus-5090-egpu).
Apply the host-side bring-up there before running this container.

| Concern | Where it lives |
|---|---|
| Kernel cmdline (`iommu=off`, etc.) | host (`grubby`, set per `aorus-5090-egpu` apply.sh) |
| udev rules (`/dev/nvidia*` permissions, autoload guard) | host (`aorus-5090-egpu` udev rules) |
| `/etc/modprobe.d/` blacklists + options | host |
| Lever H17 LnkCtl2 cap (`bridge-link-cap` service) | host (must run BEFORE this container) |
| `nvidia-persistenced` (warmup-latency optimisation) | host |
| **Kernel module build + load** | **this container** |
| **`nvidia-modprobe -u -c 0`** | **this container** |

## Quick start — single-host Docker

```bash
git clone https://github.com/apnex/nvidia-driver-injector.git
cd nvidia-driver-injector

# Build the image (one-time; ~5 min on first run, ~30s with cached layers)
docker compose build

# Run — builds + loads nvidia.ko on this host's kernel
docker compose up

# Watch the build + load output
docker compose logs -f
```

After successful load:

```bash
nvidia-smi -L                            # GPU 0: NVIDIA GeForce RTX 5090
cat /sys/module/nvidia/version           # 595.71.05-aorus.12
```

To stop:

```bash
docker compose down                      # stops container; module STAYS LOADED
                                         # (kernel modules outlive containers
                                         # by design — module state is host
                                         # state, not container state)
```

To gracefully unload the module
(driver upgrade, node decommission, recovery from a wedged module),
use the explicit `uninstall` subcommand:

```bash
docker compose run --rm driver-injector uninstall
```

This is **not** triggered by `docker compose down` — that asymmetry is
deliberate.
The `uninstall` path:

- Refuses if any process holds `/dev/nvidia*`
  (fail loud rather than rmmod with active users).
- `rmmod nvidia_uvm` → `nvidia_drm` → `nvidia_modeset` → `nvidia`
  in dependency order.
- Verifies all modules gone before exiting.
- Exit 0 → host restored to pre-injector baseline;
  re-run `docker compose up` to reload.

## Quick start — Kubernetes

```bash
kubectl label node <gpu-node> apnex.com.au/aorus-egpu=true
kubectl apply -f k8s/daemonset.yaml
kubectl logs -n kube-system -l app.kubernetes.io/name=nvidia-driver-injector -f
```

See [`k8s/README.md`](k8s/README.md) for full k8s notes including:

- Companion deployments
  (NVIDIA Device Plugin, Container Toolkit)
- Node prerequisites
- Cleanup procedure

## Image variants

Currently a single `apnex/nvidia-driver-injector:595.71.05-aorus.12` image
on Docker Hub
(planned).
The image works on any Linux distro that has `kernel-devel` installed
(Ubuntu, Fedora, RHEL family, Debian).
For container-optimised OSes that lack `kernel-devel`
(Talos, Bottlerocket, CoreOS),
a multi-image precompiled-per-kernel variant would be a future addition.

## Build inputs

| Input | Source | When |
|---|---|---|
| NVIDIA upstream | https://github.com/NVIDIA/open-gpu-kernel-modules tag `595.71.05` | Fetched at image-build time via `git clone --depth 1` |
| Project patches | Vendored at `patches/` (29 active) | Image-build time |
| Host kernel + headers | `/lib/modules/$(uname -r)/build` on the host | Bind-mounted at runtime |

The `Dockerfile` validates that all 29 patches apply cleanly to the upstream
tag at image-build time —
patch drift fails the image build, not the pod start.

## Why this exists

The eGPU stack at
[`apnex/aorus-5090-egpu`](https://github.com/apnex/aorus-5090-egpu)
runs a 30-patch fork of the NVIDIA open driver
to fix the documented host-freeze bug
on Thunderbolt-attached Blackwell GPUs.
Running that fork in Kubernetes
requires either:

1. Manually installing the patched driver on each GPU node
   (DKMS or one-shot install),
   then babysitting kernel upgrades, OR
2. **This image**:
   declarative DaemonSet that owns the driver lifecycle.

The injector pattern
(privileged container builds + loads kernel module)
is identical to NVIDIA's own
[GPU Operator](https://github.com/NVIDIA/gpu-operator)
Driver DaemonSet —
this is the same architecture, sized for our specific patched build.

## License

GPL-2.0
(matches the NVIDIA open driver's GPL-2.0 leg of its dual MIT/GPL-2.0
license,
plus the GPL-2.0 of the companion `aorus-5090-egpu` repo).
