# nvidia-driver-injector

A containerised kernel-injector for the **patched NVIDIA open kernel module**
([`595.71.05-aorus.12`](https://github.com/apnex/aorus-5090-egpu)) that
mitigates the silent host-freeze bug at
[NVIDIA/open-gpu-kernel-modules#979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979)
and adds in-driver Mode B detection (Lever Q-watchdog) + recovery state machine
(Lever M-recover).
Deployable via Docker on a single host or as a DaemonSet in Kubernetes.

**Status:** MVP, 2026-05-09.
Tested on Fedora 43 + 6.19.14-200.fc43.x86_64.
Single-image, distro-neutral approach (Approach B — host bind-mounts
`/lib/modules` for the kernel build dir).

## What it does

A privileged container that runs these steps on each pod start (matching the
responsibilities historically owned by `aorus-egpu-compute-load-nvidia.service`
on the host):

1. **PCI gate** — verify the eGPU is enumerated; exit cleanly if not.
2. **driver_override clear** — if the host had a teardown applied (e.g.
   `aorus-5090-egpu`'s `remove.sh` sets a sentinel to block auto-bind), clear it
   so nvidia can bind on insmod.
   Skipped when override is empty or already `nvidia`.
3. **BAR1 verify** — confirm BAR1 = 32 GiB; refuse to load if smaller (catches
   missing kernel cmdline tuning).
4. **Build** — compile the patched module against the host's running kernel
   using `/lib/modules/$(uname -r)/build` bind-mounted from the host.
5. **Load** — `insmod nvidia.ko` + `insmod nvidia-uvm.ko` directly into the host
   kernel.
6. **UVM device files** — `nvidia-modprobe -u -c 0` materialises
   `/dev/nvidia-uvm-tools`.

Then `sleep infinity` as a "container of intent" — exit triggers the pod restart
policy.

## Architecture

This container is **Layer 2 of three**.
A correctly-deployed system has:

- **Layer 1 — Host bring-up**
  (set once at install; must be in place before docker starts):
  kernel cmdline,
  bridge LnkCtl2 cap (Lever H17, runs `Before=docker.service`),
  modprobe.d production NVreg options
  (including `NVreg_TbEgpuLeverMRecoverEnable=1`),
  Vulkan/EGL/OpenCL ICD disable.
- **Layer 2 — Driver injector container** (this repo):
  builds patched `nvidia.ko` against host kernel-devel,
  loads it via `modprobe` so production modprobe.d options apply,
  fixes `/dev/nvidia*` permissions,
  runs `nvidia-smi -pm 1` to trigger full GPU bringup
  (GSP firmware load, PMU init, AORUS waterblock thermal subsystem)
  and enable the driver's persistence-mode flag.
- **Layer 3 — Workload container**
  (vLLM, OpenCode runtime, etc.):
  pure userspace, depends on `/dev/nvidia*` working.

Layer 1 setup is automated by `sudo ./scripts/apply.sh`
(refuses to install if `apnex/aorus-5090-egpu` artifacts are present —
the two are alternative geometries, not stackable);
`sudo ./scripts/remove.sh` reverses it.

See [`docs/architecture.md`](docs/architecture.md) for the full layered diagram,
component-ownership table,
install / uninstall / reboot-survival workflows,
and the gap-status table tracking the current implementation against the target.

> **Different geometry from
> [`apnex/aorus-5090-egpu`](https://github.com/apnex/aorus-5090-egpu).**
> That repo deploys the same patched driver via host systemd services
> (no container).
> Pick **one** of the two patterns —
> they are not meant to coexist on the same host.

## Component ownership

| Concern | Layer | Owner |
|---|---|---|
| Kernel cmdline (`iommu=off`, etc.) | 1 | `scripts/apply.sh` (auto-detects bridge BDF for `pci=resource_alignment`) |
| `/etc/modprobe.d/nvidia-driver-injector.conf` (blacklists + NVreg options including LeverMRecoverEnable=1) | 1 | `scripts/apply.sh` |
| Lever H17 LnkCtl2 cap (`nvidia-driver-injector-bridge-link-cap.service`, ordered `Before=docker.service`) | 1 | `scripts/apply.sh` |
| `/etc/udev/rules.d/79-nvidia-driver-injector.rules` (`/dev/nvidia*` group) | 1 | `scripts/apply.sh` |
| `/etc/udev/rules.d/80-nvidia-driver-injector-disable-audio.rules` (unbind HDMI audio function) | 1 | `scripts/apply.sh` |
| Vulkan/EGL/OpenCL ICD disable | 1 | `scripts/apply.sh` |
| `kernel-devel` for `$(uname -r)` | 1 | `scripts/apply.sh` (dnf or apt) |
| **Kernel module build + load** (`modprobe --ignore-install nvidia` against the patched .ko) | **2** | **this container's entrypoint** ✓ |
| **`nvidia-modprobe -u -c 0`** (UVM device files) | **2** | **this container's entrypoint** ✓ |
| `/dev/nvidia*` chown/chmod (belt-and-suspenders to udev rule) | 2 | this container's entrypoint ✓ |
| `NVreg_TbEgpuLeverMRecoverEnable=1` post-load verification | 2 | this container's entrypoint ✓ |
| **`nvidia-smi -pm 1`** (persistence + GPU thermal engagement) | **2** | **this container's entrypoint** ✓ |
| Workload `depends_on` healthcheck | 3 | TODO (Gap #6; documented in workload-side compose) |

## Prerequisites

The container needs three things in place on the host before it can build and
load a working driver.
The companion repo's `apply.sh` does all of these and more — this section lists
the minimum the injector container itself depends on.

### 1. Kernel cmdline tuning

The Aorus 5090 eGPU on Thunderbolt requires several boot parameters to bring the
GPU up reliably and size BAR1 to 32 GiB:

```bash
sudo grubby --update-kernel=ALL --args=\
"thunderbolt.host_reset=false \
 pci=resource_alignment=35@0000:03:00.0 \
 iommu=off intel_iommu=off \
 pcie_aspm.policy=performance \
 thunderbolt.clx=0 \
 pcie_port_pm=off"
sudo reboot
```

The `pci=resource_alignment` BDF (`0000:03:00.0` here) is the bridge directly
above the GPU and may differ on your hardware — find it with `lspci -tnn` or
`readlink /sys/bus/pci/devices/<gpu_bdf>/..`.
See the companion repo's docs for what each flag does and how to adapt the BDF.

### 2. kernel-devel matching the running kernel

The container builds the module against `/lib/modules/$(uname -r)/build`,
bind-mounted from the host — so the host needs that build tree present:

| Distro | Install command |
|---|---|
| Fedora / RHEL | `sudo dnf install kernel-devel-$(uname -r)` |
| Debian / Ubuntu | `sudo apt install linux-headers-$(uname -r)` |
| Arch | `sudo pacman -S linux-headers` |

Verify with `ls /lib/modules/$(uname -r)/build/Makefile` — the file should
exist.

### 3. udev rules + access group (optional, for non-root use)

Compute workloads typically run as a non-root user; copy the udev rule from the
companion repo to permission `/dev/nvidia*` for an access group:

```bash
sudo groupadd -r gpu 2>/dev/null || true
sudo curl -fLo /etc/udev/rules.d/79-aorus-egpu-nvidia-permissions.rules \
  https://raw.githubusercontent.com/apnex/aorus-5090-egpu/main/etc/udev/rules.d/79-aorus-egpu-nvidia-permissions.rules
sudo udevadm control --reload-rules
sudo usermod -aG gpu "$USER"   # log out + back in for this to take effect
```

If your workloads run as root, skip this step.

## Quick start — single-host Docker

For the full step-by-step including Thunderbolt authorization,
host-side bring-up, and the post-install verification suite,
see [`docs/install-workflow.md`](docs/install-workflow.md).
The condensed version:

```bash
# 0. Connect AORUS over TB; verify boltctl shows authorized
boltctl list                          # status: authorized
# (if status: connected but NOT authorized → sudo boltctl authorize <uuid>)

# 1. Clone + Layer 1 host bring-up
sudo git clone https://github.com/apnex/nvidia-driver-injector \
    /root/nvidia-driver-injector
cd /root/nvidia-driver-injector
sudo ./scripts/apply.sh        # idempotent; refuses on aorus-5090-egpu hosts

# 2. Reboot if apply.sh prompts (kernel cmdline change)
sudo reboot

# 3. Build + start the injector container (Layer 2)
docker compose build                  # ~3-5 min cold
docker compose up -d
docker compose logs -f                # watch the entrypoint
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

To gracefully unload the module (driver upgrade, node decommission, recovery
from a wedged module), use the explicit `uninstall` subcommand:

```bash
docker compose run --rm driver-injector uninstall
```

This is **not** triggered by `docker compose down` — that asymmetry is
deliberate.
The `uninstall` path:

- Refuses if any process holds `/dev/nvidia*` (fail loud rather than rmmod with
  active users).
- `rmmod nvidia_uvm` → `nvidia_drm` → `nvidia_modeset` → `nvidia` in dependency
  order.
- Verifies all modules gone before exiting.
- Exit 0 → host restored to pre-injector baseline; re-run `docker compose up` to
  reload.

## Verifying the install

After `docker compose up -d`, let the build finish (1-2 min on first run, ~30s
on rebuild) then verify on the host:

```bash
# 1. Module loaded
grep -E "^nvidia " /proc/modules
# nvidia          16424960  1 nvidia_uvm, Live ...

# 2. Patched build (-aorus.<n> suffix is the project marker)
cat /sys/module/nvidia/version
# 595.71.05-aorus.12

# 3. GPU bound to nvidia
ls -la /sys/bus/pci/devices/0000:04:00.0/driver
# .../bus/pci/drivers/nvidia

# 4. In-driver levers compiled in (Lever M-recover + Q-watchdog)
ls /sys/module/nvidia/parameters/ | grep TbEgpu
ls /sys/bus/pci/devices/0000:04:00.0/ | grep tb_egpu_qwatchdog
ps -ef | grep -E "\[aorus-qwd-" | grep -v grep
# the qwatchdog kthread should be present, e.g. [aorus-qwd-0400]

# 5. nvidia-smi reports the GPU
nvidia-smi -L
# GPU 0: NVIDIA GeForce RTX 5090 (UUID: GPU-...)
nvidia-smi --query-gpu=name,driver_version,pcie.link.gen.current,pcie.link.width.current,memory.total --format=csv
# NVIDIA GeForce RTX 5090, 595.71.05, 3, 4, 32607 MiB
```

If all five pass, the patched module is loaded and bound, and the in-driver
Lever M-recover (recovery state machine) plus Q-watchdog (Mode B detection) are
armed.

## Quick start — Kubernetes

```bash
kubectl label node <gpu-node> apnex.com.au/aorus-egpu=true
kubectl apply -f k8s/daemonset.yaml
kubectl logs -n kube-system -l app.kubernetes.io/name=nvidia-driver-injector -f
```

See [`k8s/README.md`](k8s/README.md) for full k8s notes including:

- Companion deployments (NVIDIA Device Plugin, Container Toolkit)
- Node prerequisites
- Cleanup procedure

## Image variants

Currently a single `apnex/nvidia-driver-injector:595.71.05-aorus.12` image on
Docker Hub (planned).
The image works on any Linux distro that has `kernel-devel` installed (Ubuntu,
Fedora, RHEL family, Debian).
For container-optimised OSes that lack `kernel-devel` (Talos, Bottlerocket,
CoreOS), a multi-image precompiled-per-kernel variant would be a future
addition.

## Troubleshooting

### `NVRM: probe routine was not called for 1 device(s)`

Container exits with `insmod nvidia.ko failed` and dmesg shows:

```
NVRM: The NVIDIA probe routine was not called for 1 device(s).
NVRM: No NVIDIA devices probed.
```

**Cause:** `driver_override` is set on the GPU's PCI device, which blocks
auto-bind even when `nvidia.ko`'s `pci_register_driver` runs at insmod time.
The companion repo's `remove.sh` deliberately sets `driver_override =
aorus_egpu_manual` to gate auto-bind while the host stack is uninstalled.

**Fix:** the entrypoint clears any non-`nvidia` override automatically since
commit `fe2dcc5` — upgrade your image.
For older images, clear it manually:

```bash
echo > /sys/bus/pci/devices/0000:04:00.0/driver_override
docker compose restart
```

### `BAR1 too small`

Container exits at step 3 with:

```
[nvidia-driver-injector] FAIL: BAR1 too small: <N> bytes
                                (need ≥ 34359738368 = 32 GiB).
```

**Cause:** kernel cmdline missing `thunderbolt.host_reset=false` or
`pci=resource_alignment=35@<bridge_bdf>`, so the kernel allocated a smaller BAR1
at boot.

**Fix:** apply the cmdline tuning from
[Prerequisites](#1-kernel-cmdline-tuning), reboot.
BAR1 sizing happens once at boot and cannot be resized at runtime on TB-tunneled
hardware.

### `gcc: error: unrecognized command-line option '-fmin-function-alignment=16'`

Build fails with this gcc error during module compile.

**Cause:** the container's gcc is older than the gcc the host kernel was built
with (e.g. host kernel built with gcc 13+ but container ships gcc 12).

**Fix:** the upstream image runs on `debian:13-slim` (gcc 14.2), which is
sufficient for kernels built with gcc 13/14/15.
If you've forked the Dockerfile onto an older base, upgrade to `debian:13-slim`
or newer.

### `objtool: error while loading shared libraries: libelf.so.1`

Build fails when the kernel's prebuilt `objtool` (at
`/usr/src/kernels/<kver>/tools/objtool/objtool`) runs and can't find libelf.

**Cause:** the container is missing the runtime library that the host's
`objtool` was linked against.

**Fix:** the upstream image installs `libelf1t64` and `libssl3t64`.
If you've forked the Dockerfile and dropped them, re-add them.

### `insmod: ERROR: ... -1 Operation not permitted`

**Cause:** Secure Boot is enabled and module signing enforcement is rejecting
the unsigned container-built module.

**Fix:** disable Secure Boot in firmware, or sign the module post-build with a
MOK enrolled key (open follow-up — the injector's build path doesn't sign yet).

### Container exits cleanly with "no GPU matching ... found on PCI"

**Cause:** the eGPU isn't enumerated on the PCI bus — either the Thunderbolt
cable is disconnected, the eGPU is powered off, or the host hasn't completed
Thunderbolt authorisation (`boltctl list` should show it).

**Fix:** plug in / power on / authorise the eGPU, then `docker compose up -d`
again.
The container is designed to exit cleanly here so it can be left as a `restart:
unless-stopped` workload that picks up the GPU when it appears.

## Build inputs

| Input | Source | When |
|---|---|---|
| NVIDIA upstream | https://github.com/NVIDIA/open-gpu-kernel-modules tag `595.71.05` | Fetched at image-build time via `git clone --depth 1` |
| Project patches | Vendored at `patches/` (29 active) | Image-build time |
| Host kernel + headers | `/lib/modules/$(uname -r)/build` on the host | Bind-mounted at runtime |

The `Dockerfile` validates that all 29 patches apply cleanly to the upstream tag
at image-build time — patch drift fails the image build, not the pod start.

## Why this exists

The eGPU stack at
[`apnex/aorus-5090-egpu`](https://github.com/apnex/aorus-5090-egpu) runs a
30-patch fork of the NVIDIA open driver to fix the documented host-freeze bug on
Thunderbolt-attached Blackwell GPUs.
Running that fork in Kubernetes requires either:

1. Manually installing the patched driver on each GPU node (DKMS or one-shot
   install), then babysitting kernel upgrades, OR
2. **This image**:
   declarative DaemonSet that owns the driver lifecycle.

The injector pattern (privileged container builds + loads kernel module) is
identical to NVIDIA's own [GPU Operator](https://github.com/NVIDIA/gpu-operator)
Driver DaemonSet — this is the same architecture, sized for our specific patched
build.

## License

GPL-2.0 (matches the NVIDIA open driver's GPL-2.0 leg of its dual MIT/GPL-2.0
license, plus the GPL-2.0 of the companion `aorus-5090-egpu` repo).
