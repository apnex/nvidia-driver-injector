# nvidia-driver-injector

A containerised kernel-module injector that patches NVIDIA's open driver to keep Thunderbolt-attached eGPUs from hard-locking Linux hosts.

**Status:** in production.\
Tested on Fedora 43–44, kernels 6.19–7.0.

## Install

Two supported paths share `Layer 1` host bring-up and diverge at `Layer 2` (how the driver container is scheduled).

`Layer 1` is the same on both paths:
```bash
sudo git clone https://github.com/apnex/nvidia-driver-injector /root/nvidia-driver-injector
cd /root/nvidia-driver-injector
sudo ./scripts/apply.sh
```

`apply.sh` is idempotent and prompts to reboot if the kernel cmdline changes.

### Path A — docker-compose (dev / single-host)

```bash
docker compose up -d
```

Cold build takes ~3-5 min against the host's `/lib/modules/$(uname -r)/build`; subsequent builds reuse cached layers.

### Path B — k3s DaemonSet (recommended for production)

Build the image and import it into k3s's containerd (replace `<your-tag>` with the `image:` tag from `docker-compose.yml`):
```bash
docker build -t apnex/nvidia-driver-injector:<your-tag> .
docker save apnex/nvidia-driver-injector:<your-tag> | sudo k3s ctr images import -
kubectl apply -f k8s/daemonset.yaml
kubectl rollout status -n kube-system ds/nvidia-driver-injector
```

After the rollout, the entrypoint publishes a node label `nvidia.driver/state=ready` that GPU consumers gate `nodeSelector` on.\
The full producer / consumer contract is in [`docs/consumer-contract.md`](docs/consumer-contract.md).

Full step-by-step for both paths (Thunderbolt authorisation, what `apply.sh` does, all flags, migration from `aorus-5090-egpu`) is in [`docs/install-workflow.md`](docs/install-workflow.md).

---

## Use

The injector is infrastructure — you don't interact with it directly.\
Once installed, your workload uses the GPU as normal.\
Day-2 operations (logs, graceful unload, driver upgrade) live in [`docs/teardown-workflow.md`](docs/teardown-workflow.md).

### Path A — docker-compose

`/dev/nvidia*` is available on the host.\
Container workloads consume the GPU via the standard `nvidia-container-toolkit` injection (already configured by `apply.sh`).

### Path B — k3s DaemonSet

Workload Deployments gate on the producer/consumer contract — see [`docs/consumer-contract.md`](docs/consumer-contract.md) for the required `nodeSelector`, `runtimeClassName`, and env settings.

---

## Test

Three distinct things called "test":

| What | Doc | One-liner |
|---|---|---|
| **Verify install** | [`docs/install-workflow.md`](docs/install-workflow.md#step-6--verify) | Did the module load? Are the in-driver levers armed? |
| **Measure bandwidth + capability** | [`diag/README.md`](diag/README.md) | `sudo docker compose -f diag/docker-compose.yml run --rm diag suite` |
| **Repo gates (for contributors)** | [`docs/testing.md`](docs/testing.md) | `bash tests/run.sh` + `tools/validate-patchset.sh` |

The diag container is a **separate** image (`apnex/nvidia-driver-diag`) with its own lifecycle.\
Isolated by design so its CUDA-devel surface cannot bloat or destabilise the injector.

---

## Remove

Reverse the install order: `Layer 3` (workload) → `Layer 2` (this container) → `Layer 1` (host).\
Stop your GPU consumers first (anything holding `/dev/nvidia*`) using their own teardown — the commands below tear down only the injector.

### Path A — docker-compose

```bash
cd /root/nvidia-driver-injector
docker compose run --rm driver-injector uninstall
docker compose down
```

### Path B — k3s DaemonSet

```bash
kubectl exec -n kube-system daemonset/nvidia-driver-injector -- /entrypoint.sh uninstall
kubectl delete -f k8s/daemonset.yaml
```

### `Layer 1` (both paths)

```bash
sudo ./scripts/remove.sh
```

`remove.sh` flags:

- `--revert-cmdline` — strip the kernel cmdline args this repo added.
  Reboot required.
- `--purge` — deep clean for fresh-host testing (implies `--revert-cmdline`, removes the on-disk `.ko`, restores legacy ICDs).
  Reboot required.
- `--skip-k3s` — leave the cluster-side `RuntimeClass nvidia` and containerd config alone.

The no-reboot "really gone" variant uses the container's `purge` subcommand instead.\
Full teardown reference (every flag, every file removed, what's left behind on purpose, the two-tool model): [`docs/teardown-workflow.md`](docs/teardown-workflow.md).

---

## Architecture

```
Layer 3  Workload                     - vLLM / OpenCode / … (separate compose stack)
Layer 2  Driver injector container    - this repo
Layer 1  Host config                  - cmdline / modprobe.d / udev / bridge cap
Layer 0  Hardware                     - AORUS 5090 over TB, NUC 15 Pro+
```

`Layer 0` is the hardware.

- Out of scope for this repo.

`Layer 1` is the host config.

- Set up once by `scripts/apply.sh`.

`Layer 2` is the driver-injector container at this repo's root.

- Builds the patched `nvidia.ko` against the host's `/lib/modules/$(uname -r)/build`.
- Loads it via `modprobe`.
- Materialises `/dev/nvidia*`.
- Engages persistence mode.

`Layer 3` is the workload.

- Consumes `/dev/nvidia*`.

Full layered design with component-ownership table: [`docs/architecture.md`](docs/architecture.md).

> **`apnex/aorus-5090-egpu`** is the frozen predecessor — same patches, deployed via host systemd services instead of a container.\
> Alternative geometries; pick one, do not stack.

---

## Troubleshooting

### `NVRM: probe routine was not called for 1 device(s)`

`driver_override` on the GPU's PCI device is blocking auto-bind — typically left over from a `scripts/remove.sh` run or an earlier `aorus-5090-egpu` install.

The entrypoint clears any non-`nvidia` override automatically; upgrade your image, or manually:
```bash
echo > /sys/bus/pci/devices/0000:04:00.0/driver_override
docker compose restart
```

### `BAR1 too small`

The container exits at the BAR1-verify step with `BAR1 too small: <N> bytes (need ≥ 34359738368 = 32 GiB)`.\
The kernel cmdline is missing `thunderbolt.host_reset=false` or `pci=resource_alignment=35@<bridge_bdf>`.\
BAR1 sizing happens once at boot and cannot be changed at runtime on TB-tunneled hardware.

Re-run `Layer 1` host bring-up, then reboot:
```bash
sudo ./scripts/apply.sh
```

### `gcc: error: unrecognized command-line option '-fmin-function-alignment=16'`

The container's gcc is older than the gcc the host kernel was built with.\
The upstream image uses a recent Debian-slim base providing a modern gcc, covering kernels built with gcc 13/14/15 (see `Dockerfile` for specifics).\
If you forked onto an older base, bump it.

### `objtool: ... cannot open shared object file: libelf.so.1`

The container is missing `libelf1t64` / `libssl3t64` (used by the host kernel's prebuilt `objtool`).\
The upstream image installs both; re-add them if you stripped them in a fork.

### `insmod: ... Operation not permitted`

Secure Boot is rejecting the unsigned, container-built module.\
Disable Secure Boot, or sign post-build with a MOK key (the injector's build path does not sign — open follow-up).

### Container exits cleanly with `no GPU matching ... found on PCI`

The eGPU is not enumerated on the PCI bus.\
Check the TB cable, eGPU power, and `boltctl list` for authorisation.\
The clean exit is by design — the container is meant to be left as `restart: unless-stopped` and pick the GPU up when it appears.

---

## Building the image

```bash
docker compose build
```

Cold ~3-5 min, ~30s with cached layers.\
No pre-built image is published yet.\
The image is distro-neutral — it builds the module against the host's `/lib/modules/$(uname -r)/build`, so it works on any Linux that has the matching `kernel-devel` / `linux-headers` package installed.\
For container-optimised OSes without that package (Talos, Bottlerocket, CoreOS), a multi-image precompiled-per-kernel variant is a future addition.

Build inputs:

| Input | Source | When |
|---|---|---|
| NVIDIA upstream | github.com/NVIDIA/open-gpu-kernel-modules tag `595.71.05` | Image build (`git clone --depth 1`) |
| Project patches | `patches/base/` + `patches/addon/` (11 patches; `patches/legacy/` for provenance) | Image build (gated by `--check` and `make modules`) |
| Host kernel + headers | `/lib/modules/$(uname -r)/build` | Bind-mount at runtime |

Patch drift fails the image build, not the pod start.

---

## Why this exists

NVIDIA's open kernel module, unmodified, commits a Thunderbolt-attached Blackwell GPU to a permanent lost state on a single transient PCIe read — and the resulting failure cascade hard-locks the host.\
The patched build here mitigates it; the upstream-bound subset is being prepared as PRs (see [`docs/upstream-plan.md`](docs/upstream-plan.md)).

Shipping the driver as a container makes its lifecycle declarative: the image rebuilds + loads the module against whatever kernel the host is running, so kernel upgrades don't mean a hand rebuild.\
Same pattern as NVIDIA's [GPU Operator](https://github.com/NVIDIA/gpu-operator) driver DaemonSet.

---

## License

GPL-2.0 (matches the NVIDIA open driver's GPL-2.0 leg of its dual MIT / GPL-2.0 licence).
