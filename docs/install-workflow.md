# Install workflow

Step-by-step install for the nvidia-driver-injector deployment geometry.
The condensed version lives in the top-level [`README.md`](../README.md);
this doc is the reference.

For the underlying three-layer design, see [`architecture.md`](architecture.md).
For teardown / uninstall, see [`teardown-workflow.md`](teardown-workflow.md).
For the producer / consumer contract used by the k3s path, see
[`consumer-contract.md`](consumer-contract.md).

## Two install paths

| Path | When | Substrate | Status |
|---|---|---|---|
| **Path A — docker-compose** | Single-host dev / test / operator ad-hoc | Docker only | Supported |
| **Path B — k3s DaemonSet** | Production; clustered orchestration | k3s (or any Kubernetes) | **Recommended** |

Both paths share Layer 1 (`scripts/apply.sh`). They diverge at Layer 2: Path A
runs the injector as a docker-compose service; Path B runs it as a DaemonSet
in k3s. Pick one. They are not meant to run side-by-side on the same node
(both would race to load `nvidia.ko`).

## Prerequisites (both paths)

- **Hardware:** AORUS RTX 5090 eGPU, Thunderbolt-4-capable host (reference
  hardware: NUC 15 Pro+), TB4 cable.
- **OS:** Linux, kernel 6.18+ (tested on Fedora 43 + kernel `6.19.14-200.fc43`
  and Fedora 44 + kernel `7.0.9-204.fc44`). The host scripts handle Fedora and
  Debian/Ubuntu package paths.
- **Container runtime:**
  - Path A: Docker installed and running (`systemctl is-active docker`).
  - Path B: k3s installed (`systemctl is-active k3s`) **and**
    `nvidia-container-toolkit` installed (provides `nvidia-ctk` +
    `nvidia-container-runtime`).
- **No active `aorus-5090-egpu` install on this host** — the two are
  alternative geometries. `apply.sh` refuses to install on top of one (override
  with `--force-coexist`; see [Migration](#migration-from-aorus-5090-egpu)).
- **No BIOS tuning needed** on NUC 15 Pro+ (BIOS exposes nothing
  user-configurable for TB / PCIe; see project memory
  `feedback_no_bios_options_nuc15`).

## Step 0 — Connect + authorise the eGPU (both paths)

```bash
boltctl list
```

Expect `status: authorized`. On headless / server installs, the first plug
shows `connected` but not authorised; run:

```bash
sudo boltctl authorize <uuid>
```

Authorisation is persistent across reboots and replugs. If `status: auth-error`
or the device does not appear, fix Thunderbolt fundamentals first
(`bolt.service` running, cable seated, eGPU powered, port working).

## Step 1 — Clone the repo (both paths)

```bash
sudo git clone https://github.com/apnex/nvidia-driver-injector \
    /root/nvidia-driver-injector
cd /root/nvidia-driver-injector
```

## Step 2 — Layer 1 host bring-up (both paths)

```bash
sudo ./scripts/apply.sh
```

Idempotent. Refuses to install on a host with `apnex/aorus-5090-egpu`
artifacts (override: `--force-coexist`). The ten numbered steps in
`apply.sh` are:

| # | What | Notes |
|---|---|---|
| 0 | Conflict check (aorus-5090-egpu artifacts) | Refuses unless `--force-coexist` |
| 1 | Kernel cmdline via `grubby` | `iommu=off`, `intel_iommu=off`, `thunderbolt.host_reset=false`, `thunderbolt.clx=0`, `pcie_aspm.policy=performance`, `pcie_port_pm=off`, `pci=resource_alignment=35@<auto-detected bridge BDF>` |
| 2 | `kernel-devel` for `$(uname -r)` | `dnf` or `apt-get`; skipped if `/lib/modules/$(uname -r)/build/Makefile` exists |
| 3 | `gpu` UNIX group + GID-rewrite in modprobe.d | Creates the group if absent; rewrites `NVreg_DeviceFileGID` to the actual GID |
| 4 | `/etc/modprobe.d/nvidia-driver-injector.conf` | Blacklists + production NVreg options (`NVreg_TbEgpuRecoverEnable=1`, `DeviceFileMode=0660`, …). Also removes the `aorus-5090-egpu` transition stub (`zz-aorus-egpu-blacklist.conf`) if present |
| 5 | `nvidia-driver-injector-bridge-link-cap` binary + `.service` | Systemd unit ordered `Before=docker.service`; enabled |
| 6 | udev rules | `79-…rules` (`/dev/nvidia*` group perms) + `80-…disable-audio.rules` (unbind eGPU HDMI audio function) |
| 7 | Disable Vulkan / EGL / OpenCL ICDs | Compute-only posture; rename → `*.nvidia-driver-injector-disabled` |
| 8 | Apply bridge-link-cap immediately | Skipped if reboot pending or eGPU not enumerated; lets the injector start without rebooting |
| 9 | **k3s integration** (Path B only) | If k3s is present: `nvidia-ctk runtime configure --runtime=containerd` + install cluster-side `RuntimeClass nvidia`. Skipped automatically on docker-only hosts; skip explicitly with `--skip-k3s`. **Note:** `nvidia-ctk` prints `It is recommended that containerd daemon be restarted` — this targets the system containerd at `/etc/containerd/`, which k3s does not read; k3s uses its own containerd config under `/var/lib/rancher/k3s/agent/etc/containerd/` and step 9 verifies the nvidia handler is already present there. Benign for k3s. |
| 10 | Summary + reboot guidance | Flags reboot-needed if cmdline was modified |

Flags:

- `--no-act` — dry-run; print actions without making changes.
- `--force-coexist` — skip the aorus-5090-egpu conflict check. Do not use
  unless you understand why the two cannot share a host.
- `--skip-cmdline` — leave the kernel cmdline alone.
- `--skip-icd` — leave Vulkan / EGL / OpenCL ICDs alone.
- `--skip-k3s` — leave containerd / RuntimeClass alone (Path A-only hosts).

## Step 3 — Reboot if instructed (both paths)

If `apply.sh` changed the kernel cmdline, its summary will say so:

```bash
sudo reboot
```

Why reboot rather than try to apply at runtime: BAR1 sizing is fixed at
boot on TB-tunneled hardware, the `bridge-link-cap.service` needs to run
`Before=docker.service`, and the `install /bin/false` modprobe.d guards
need to be in place before any auto-load attempt.

---

## Path A — docker-compose (dev / test / single-host)

Continue here if you picked Path A. Production deployments should prefer
[Path B](#path-b--k3s-daemonset-recommended-for-production) below.

### Step 4A — Build + start the injector container

```bash
docker compose build              # ~3-5 min cold, ~30s with cached layers
docker compose up -d
docker compose logs -f            # watch the entrypoint, ~45s
```

Expected log markers, in order:

```
PCI gate ✓ — GPU at 0000:04:00.0
BAR1 verify ✓ — 32 GiB
host modprobe.d detected — production NVreg options will apply
modprobe --ignore-install nvidia ...
load ✓ — nvidia version: 595.71.05-aorus.14
tb_egpu recover ✓ — NVreg_TbEgpuRecoverEnable=1
bind ✓ — 0000:04:00.0 bound to nvidia
nvidia-modprobe -u -c 0 ...
perms ✓ — /dev/nvidia0: 0660 root:gpu
perms ✓ — /dev/nvidiactl: 0660 root:gpu
perms ✓ — /dev/nvidia-uvm: 0660 root:gpu
perms ✓ — /dev/nvidia-uvm-tools: 0660 root:gpu
engaging GPU (nvidia-smi -pm 1) ...
engage ✓ — persistence_mode + thermal subsystem engaged
==========================================
  nvidia driver loaded successfully
  patches applied: 11
  upstream tag:    595.71.05
==========================================
sleeping as container of intent — exit triggers restart policy
```

### Step 5A — Verify

Spot checks (each should print the expected one-liner):

```bash
nvidia-smi -L
# GPU 0: NVIDIA GeForce RTX 5090 (UUID: GPU-...)

cat /sys/module/nvidia/version
# 595.71.05-aorus.14

ls -la /dev/nvidia0
# crw-rw---- 1 root gpu ...

cat /sys/module/nvidia/parameters/NVreg_TbEgpuRecoverEnable
# 1
```

For the comprehensive 40-check verification, run:

```bash
sudo ./scripts/status.sh
# Expect: 38 OK, 2 WARN, 0 FAIL (or better)
```

### Step 6A — Bring up your workload (Layer 3)

```bash
cd /path/to/your/workload          # e.g. /root/vllm
docker compose up -d
```

The workload's compose ideally includes
`depends_on: { driver-injector: { condition: service_healthy } }` to avoid
crash-looping while the injector warms up.

---

## Path B — k3s DaemonSet (recommended for production)

Continue here if you picked Path B. Path B leans on the producer / consumer
contract documented in [`consumer-contract.md`](consumer-contract.md).

### Step 4B — Build the injector image and import it to containerd

```bash
docker build -t apnex/nvidia-driver-injector:595.71.05-aorus.14 .
docker save apnex/nvidia-driver-injector:595.71.05-aorus.14 \
    | sudo k3s ctr images import -
```

Why the `ctr images import` step: `docker build` produces images in the docker
daemon's cache; k3s reads from containerd's own cache. The DaemonSet's
`imagePullPolicy: IfNotPresent` means a missing image fails the pod with
`ErrImageNeverPull`, not a registry pull — so the image must be in
containerd's cache.

(Alternative: build directly with `nerdctl --namespace=k8s.io build`. Less
moving parts but requires nerdctl on the host.)

### Step 5B — Apply the DaemonSet

```bash
kubectl apply -f k8s/daemonset.yaml
kubectl rollout status -n kube-system ds/nvidia-driver-injector
```

**First rollout takes 1-2 minutes.** The entrypoint builds the `.ko` from
source against the host kernel-devel, modprobes it, then writes the node
label. If `kubectl rollout status` hasn't returned after 3 minutes,
`kubectl logs -n kube-system ds/nvidia-driver-injector` will show where
it's stuck.

The DaemonSet creates:

- `ServiceAccount/nvidia-driver-injector` (kube-system).
- `ClusterRole/nvidia-driver-injector` — `get,patch` on `nodes` (for label
  writes only; no broader cluster permissions).
- `ClusterRoleBinding/nvidia-driver-injector`.
- `DaemonSet/nvidia-driver-injector` — one pod per node, `privileged: true`,
  `hostPID: true`, with the same bind mounts as the docker-compose path.

### Step 6B — Verify

```bash
# Pod is up + READY (this just means the module loaded — same liveness
# probe as Path A's docker healthcheck would be).
kubectl get pods -n kube-system -l app.kubernetes.io/name=nvidia-driver-injector

# Node label written by the entrypoint after successful load.
kubectl get nodes -L nvidia.driver/state,nvidia.driver/version
# NAME   STATUS   ROLES           STATE   VERSION
# obpc   Ready    control-plane   ready   595.71.05-aorus.14

# Module is loaded (same checks as Path A).
cat /sys/module/nvidia/version
# 595.71.05-aorus.14

sudo ./scripts/status.sh
# Expect: 37 OK, 2 WARN, 0 FAIL (or better)
# (Path A reports 38; Path B is one fewer because the
#  "docker-compose container running" check naturally drops out.)
```

If the node label says anything other than `state=ready` after the rollout
completes, check `kubectl logs daemonset/nvidia-driver-injector -n
kube-system` for the entrypoint's failure point.

### Step 7B — Bring up your GPU consumer

The producer side is now done. Consumer Deployments (vLLM, kate, anything new)
read the contract in [`consumer-contract.md`](consumer-contract.md) and set
four things:

```yaml
spec:
  nodeSelector:        { nvidia.driver/state: ready }
  runtimeClassName:    nvidia
  containers:
    - env:
        - { name: NVIDIA_VISIBLE_DEVICES,     value: "all" }
        - { name: NVIDIA_DRIVER_CAPABILITIES, value: "compute,utility" }
```

The vLLM and kate repos each own their own Deployment + Service manifests.
This repo does not ship those — see the consumer contract for what the
DaemonSet guarantees and what consumer YAML needs.

---

## Migration from `apnex/aorus-5090-egpu`

```bash
# 1. Stop any workload first
cd /path/to/your/workload && docker compose down

# 2. Tear down the aorus-5090-egpu host stack. It leaves
#    /etc/modprobe.d/zz-aorus-egpu-blacklist.conf as a transition stub;
#    apply.sh recognises and replaces it.
cd /root/aorus-5090-egpu && sudo ./remove.sh

# 3. Reboot to clean state (nvidia stays unloaded thanks to the stub).
sudo reboot

# 4. Install + start the injector (pick Path A or Path B as above).
cd /root/nvidia-driver-injector
sudo ./scripts/apply.sh
# then either:
docker compose up -d                        # Path A
# or:
kubectl apply -f k8s/daemonset.yaml         # Path B
```

The second reboot inside step 4 is almost never needed: `aorus-5090-egpu`
applies equivalent kernel cmdline, so `apply.sh` reports "all required
cmdline args already present" and skips the reboot prompt.

## Out of scope here

- BIOS / firmware tuning — not needed on NUC 15 Pro+.
- HuggingFace credentials, model downloads, OpenCode config — belong in
  the workload repo.
- Multi-GPU setups — single-GPU only.
- Automatic kernel-upgrade handling — after a kernel upgrade re-run
  `docker compose build` (cached patch layer reuses; only the conftest +
  module compile re-run). Not yet automated.
- Multi-cluster federation — out of scope for the single-host hardware.
