# Install workflow

Step-by-step, end-to-end install for the
nvidia-driver-injector deployment geometry.

For the architecture this implements, see
[`architecture.md`](./architecture.md).

---

## Prerequisites

- **Hardware:**
  AORUS RTX 5090 eGPU,
  NUC 15 Pro+ (or similar Thunderbolt-4-capable host),
  TB4 cable.
- **OS:**
  Linux with kernel 6.18+ (this stack was tested against
  `6.19.14-200.fc43.x86_64`).
  Fedora is the reference distro;
  the scripts handle Fedora and Debian/Ubuntu package paths.
- **No active aorus-5090-egpu install on this host.**
  The two are alternative geometries —
  apply.sh refuses to install on top of an existing
  aorus-egpu setup
  (see the [migration](#migration-from-aorus-5090-egpu)
  section if you want to switch).
- **Docker:**
  installed and running (`systemctl is-active docker`).
- **No exotic BIOS settings required**
  on NUC 15 Pro+
  (per project history, the BIOS exposes nothing user-configurable
  for TB / PCIe).

---

## Fresh-host install

### Step 0 — Connect + authorize the eGPU

Plug the AORUS into a Thunderbolt port and power it on,
then verify Linux sees it as authorized:

```bash
boltctl list
```

Expected output looks like:

```
 ● AORUS RTX 5090 (or similar)
   ├─ type:          peripheral
   ├─ name:          AORUS ...
   ├─ vendor:        Intel
   ├─ uuid:          <some-uuid>
   ├─ status:        authorized       ← what we want
   ├─ authflags:     none
   ├─ connected:     2026-...
   └─ stored:        2026-...
```

If `status:` is `connected` but **not** `authorized`
(typical on headless / Server installs without a GUI):

```bash
sudo boltctl authorize <uuid>
```

Authorization is persistent —
once authorized,
boltd remembers the decision
across reboots and replugs.
On desktop Linux,
the first plug usually shows a GNOME / KDE
"trust this Thunderbolt device?" prompt that does this for you.

If `status:` is `auth-error` or the device doesn't appear at all,
fix Thunderbolt fundamentals before continuing
(`bolt.service` running, cable seated, eGPU powered, port working).

### Step 1 — Install Docker (if not already)

```bash
sudo dnf install -y docker          # or: apt install -y docker.io
sudo systemctl enable --now docker
```

### Step 2 — Clone this repo

```bash
sudo git clone https://github.com/apnex/nvidia-driver-injector \
    /root/nvidia-driver-injector
cd /root/nvidia-driver-injector
```

### Step 3 — Run Layer 1 host bring-up

```bash
sudo ./scripts/apply.sh
```

Idempotent. Refuses to install if `apnex/aorus-5090-egpu`
artifacts are detected
(override with `--force-coexist`; not recommended).
Does:

| # | What | Notes |
|---|---|---|
| 0 | Conflict check | Refuses on aorus-5090-egpu host (see migration below) |
| 1 | Set kernel cmdline via `grubby` | `iommu=off`, `thunderbolt.host_reset=false`, `pci=resource_alignment=35@<auto-detected bridge BDF>`, etc. |
| 2 | Install `kernel-devel` for `$(uname -r)` | `dnf` or `apt`-aware; skipped if already present |
| 3 | Create `gpu` UNIX group if absent | Used as the `/dev/nvidia*` access group |
| 4 | Install `/etc/modprobe.d/nvidia-driver-injector.conf` | Production NVreg options inc. `LeverMRecoverEnable=1`, `DeviceFileMode=0660` |
| 5 | Install `nvidia-driver-injector-bridge-link-cap` binary + `.service` | Systemd unit `Before=docker.service`; enabled |
| 6 | Install udev rules | `79-nvidia-driver-injector.rules` (`/dev/nvidia*` group perms) + `80-nvidia-driver-injector-disable-audio.rules` (unbind eGPU HDMI audio function — compute-only posture) |
| 7 | Disable Vulkan / EGL / OpenCL ICDs | Compute-only posture (rename → `*.nvidia-driver-injector-disabled`) |
| 8 | Summary | Reports what changed; flags reboot-needed if cmdline was modified |
| 9 | Apply bridge-link-cap immediately if eGPU enumerated | So `docker compose up` can run without rebooting if cmdline already had everything |

Useful flags:

- `--no-act` — print every action without making changes (dry-run).
- `--force-coexist` — skip the aorus-5090-egpu conflict check.
  Don't use this unless you understand why.
- `--skip-cmdline` — leave the kernel cmdline alone.
- `--skip-icd` — leave Vulkan / EGL / OpenCL ICDs alone.

### Step 4 — Reboot if instructed

If `apply.sh` changed the kernel cmdline,
its summary tells you to reboot:

```bash
sudo reboot
```

Why reboot before bringing up the container —
not just to apply the cmdline:

- `bridge-link-cap.service` runs `Before=docker.service`,
  so the link is capped before any container can race the bind.
- modprobe.d's `install /bin/false` guards take effect at boot,
  preventing stock-nvidia auto-load races.
- Cleaner state for first-run.

### Step 5 — Build + start the injector container

```bash
cd /root/nvidia-driver-injector
docker compose build              # ~3-5 min cold; ~30s with cached layers
docker compose up -d
docker compose logs -f            # watch the entrypoint (~45s)
```

Expected log markers, in order:

```
PCI gate ✓ — GPU at 0000:04:00.0
BAR1 verify ✓ — 32 GiB
host modprobe.d detected — production NVreg options will apply
modprobe --ignore-install nvidia ...
load ✓ — nvidia version: 595.71.05-aorus.13
tb_egpu recover ✓ — NVreg_TbEgpuRecoverEnable=1
bind ✓ — 0000:04:00.0 bound to nvidia
nvidia-modprobe -u -c 0 ...
perms ✓ — /dev/nvidia0: 0660 root:gpu
perms ✓ — /dev/nvidiactl: 0660 root:gpu
perms ✓ — /dev/nvidia-uvm: 0660 root:gpu
perms ✓ — /dev/nvidia-uvm-tools: 0660 root:gpu
==========================================
  nvidia driver loaded successfully
  patches applied: 7
  upstream tag:    595.71.05
==========================================
sleeping as container of intent — exit triggers restart policy
```

### Step 6 — Verify

```bash
nvidia-smi -L
# → "GPU 0: NVIDIA GeForce RTX 5090 (UUID: ...)"

cat /sys/module/nvidia/version
# → "595.71.05-aorus.13"

ls -la /dev/nvidia0
# → "crw-rw---- 1 root gpu"

cat /sys/module/nvidia/parameters/NVreg_TbEgpuRecoverEnable
# → "1"

ps -ef | grep -E '\[tb-egpu-qwd-' | grep -v grep
# → "[tb-egpu-qwd-0400]" — Q-watchdog kthread running

nvidia-smi --query-gpu=persistence_mode,power.draw,temperature.gpu --format=csv
# → "Enabled, ~22 W, ~33 °C" — engaged. (NOT "Disabled, ~63 W, ~40 °C" — lazy)
# Set by the injector container's entrypoint (`nvidia-smi -pm 1` after bind).

readlink /sys/bus/pci/devices/0000:04:00.1/driver
# → empty / no output — HDMI audio function unbound (compute-only posture).
cat /sys/bus/pci/devices/0000:04:00.1/driver_override
# → "nvidia-driver-injector-disabled" (set by 80-...rules at PCI enumeration)
```

For the comprehensive 40-check verification, run:

```bash
sudo ./scripts/status.sh
```

### Step 7 — Bring up your workload (Layer 3, optional)

```bash
cd /path/to/your/workload          # e.g. /root/vllm
docker compose up -d
```

The workload's compose should ideally include
`depends_on: { driver-injector: { condition: service_healthy } }`
to avoid crash-looping while the injector is still warming up.
This pattern is OPEN as Gap #6 in
[`architecture.md`](./architecture.md);
to be documented here when the injector grows a healthcheck.

---

## Migration from `apnex/aorus-5090-egpu`

If you already have the aorus-5090-egpu deployment running
and want to switch to this geometry:

```bash
# 1. Stop any workload first
cd /path/to/your/workload && docker compose down

# 2. Tear down aorus-5090-egpu's host stack.
#    It leaves /etc/modprobe.d/zz-aorus-egpu-blacklist.conf as a
#    transition stub to keep nvidia from auto-loading. apply.sh
#    recognises and replaces this stub — no manual cleanup needed.
cd /root/aorus-5090-egpu && sudo ./remove.sh

# 3. Reboot to clean state. nvidia stays unloaded thanks to the stub.
sudo reboot

# 4. After reboot, install + start the injector.
cd /root/nvidia-driver-injector
sudo ./scripts/apply.sh
sudo reboot                        # only if cmdline changed; usually
                                   # not needed in the migration case
                                   # since aorus-egpu's apply.sh sets
                                   # equivalent cmdline args
docker compose up -d
```

In practice, since aorus-5090-egpu and this repo apply equivalent
kernel cmdline tuning, the second reboot in step 4 is rare —
`apply.sh` will report "all required cmdline args already present"
and skip the reboot prompt.

---

## Uninstall workflow

```bash
# Layer 3 → Layer 2 → Layer 1, in reverse order.

# 3. Stop your workload
cd /path/to/your/workload && docker compose down

# 2. Unload modules + stop the injector container
cd /root/nvidia-driver-injector
docker compose run --rm driver-injector uninstall   # rmmod nvidia_uvm + nvidia
docker compose down

# 1. Remove host-side install
sudo ./scripts/remove.sh
# Add --revert-cmdline if you want kernel args reverted too.
# Default leaves cmdline alone (the iommu=off etc. tuning is
# generally useful, not specific to this deployment).
```

---

## What this workflow does NOT cover

- BIOS / firmware tuning — not needed on NUC 15 Pro+
  (project memory: `feedback_no_bios_options_nuc15.md`).
- HuggingFace credentials, model downloads, OpenCode config —
  those belong in your workload repo,
  not in the driver layer.
- Multi-GPU setups — single-GPU only.
- Automatic kernel-upgrade handling —
  after a kernel upgrade you'd re-run
  `docker compose build`
  (the cached patch layer reuses, only the conftest + module compile re-runs).
  Could be automated;
  not in scope today.
- Cluster / Kubernetes deployment —
  `k8s/daemonset.yaml` exists but doesn't yet include the
  Layer 1 install as an init container or DaemonSet.
  Treat the k8s path as experimental.
