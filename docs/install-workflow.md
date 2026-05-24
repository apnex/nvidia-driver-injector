# Install workflow

Step-by-step install for the nvidia-driver-injector deployment geometry.
The condensed version lives in the top-level [`README.md`](../README.md);
this doc is the reference.

For the underlying three-layer design, see [`architecture.md`](architecture.md).
For teardown / uninstall, see [`teardown-workflow.md`](teardown-workflow.md).

## Prerequisites

- **Hardware:** AORUS RTX 5090 eGPU, Thunderbolt-4-capable host (reference
  hardware: NUC 15 Pro+), TB4 cable.
- **OS:** Linux, kernel 6.18+ (tested on Fedora 43 + kernel `6.19.14-200.fc43`
  and Fedora 44 + kernel `7.0.9-204.fc44`). The host scripts handle Fedora and
  Debian/Ubuntu package paths.
- **Docker:** installed and running (`systemctl is-active docker`).
- **No active `aorus-5090-egpu` install on this host** — the two are
  alternative geometries. `apply.sh` refuses to install on top of one (override
  with `--force-coexist`; see [Migration](#migration-from-aorus-5090-egpu)).
- **No BIOS tuning needed** on NUC 15 Pro+ (BIOS exposes nothing
  user-configurable for TB / PCIe; see project memory
  `feedback_no_bios_options_nuc15`).

## Fresh-host install

### Step 0 — Connect + authorise the eGPU

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

### Step 1 — Clone the repo

```bash
sudo git clone https://github.com/apnex/nvidia-driver-injector \
    /root/nvidia-driver-injector
cd /root/nvidia-driver-injector
```

### Step 2 — Run Layer 1 host bring-up

```bash
sudo ./scripts/apply.sh
```

Idempotent. Refuses to install on a host with `apnex/aorus-5090-egpu`
artifacts (override: `--force-coexist`). The nine numbered steps in
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
| 8 | Summary + reboot guidance | Flags reboot-needed if cmdline was modified |
| 9 | Apply bridge-link-cap immediately | Skipped if reboot pending or eGPU not enumerated; lets `docker compose up` work without rebooting |

Flags:

- `--no-act` — dry-run; print actions without making changes.
- `--force-coexist` — skip the aorus-5090-egpu conflict check. Do not use
  unless you understand why the two cannot share a host.
- `--skip-cmdline` — leave the kernel cmdline alone.
- `--skip-icd` — leave Vulkan / EGL / OpenCL ICDs alone.

### Step 3 — Reboot if instructed

If `apply.sh` changed the kernel cmdline, its summary will say so:

```bash
sudo reboot
```

Why reboot rather than try to apply at runtime: BAR1 sizing is fixed at
boot on TB-tunneled hardware, the `bridge-link-cap.service` needs to run
`Before=docker.service`, and the `install /bin/false` modprobe.d guards
need to be in place before any auto-load attempt.

### Step 4 — Build + start the injector container

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

### Step 5 — Verify

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

ps -ef | grep -E '\[tb-egpu-qwd-' | grep -v grep
# [tb-egpu-qwd-0400]   ← bus-loss watchdog kthread, GPU at BDF 04:00

ls /sys/bus/pci/devices/0000:04:00.0/ | grep ^tb_egpu_
# tb_egpu_qwd_*  +  tb_egpu_recover_*   ← in-driver lever sysfs surface

nvidia-smi --query-gpu=persistence_mode,power.draw --format=csv,noheader
# Enabled, ~17-22 W     ← engaged P8 (not "Disabled, ~63 W" lazy state)

readlink /sys/bus/pci/devices/0000:04:00.1/driver
# empty                 ← HDMI audio function unbound (compute-only)
```

For the comprehensive 40-check verification, run:

```bash
sudo ./scripts/status.sh
# Expect: 38 OK, 2 WARN, 0 FAIL (or better)
```

The two standing WARNs are benign and documented in the script — they cover
the `/dev/nvidia-uvm` perm drift (Gap #8 in
[`architecture.md`](architecture.md)) and one cosmetic detection edge case.

### Step 6 — Bring up your workload (Layer 3, optional)

```bash
cd /path/to/your/workload          # e.g. /root/vllm
docker compose up -d
```

The workload's compose ideally includes
`depends_on: { driver-injector: { condition: service_healthy } }` to avoid
crash-looping while the injector warms up. This pattern is **Gap #7** in
[`architecture.md`](architecture.md) — open until the injector grows a
healthcheck.

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

# 4. Install + start the injector.
cd /root/nvidia-driver-injector
sudo ./scripts/apply.sh
docker compose up -d
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
- Cluster / Kubernetes — `k8s/daemonset.yaml` exists; treat the k8s
  path as experimental until Layer 1 is also DaemonSet-ised.
