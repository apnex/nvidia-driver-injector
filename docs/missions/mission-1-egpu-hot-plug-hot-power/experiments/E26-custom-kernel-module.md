# E26 — Custom kernel module exposing trigger_bridge_resize

**Status:** BLOCKED (needs kernel build environment + module dev workflow)
**Phase:** 2.5
**Risk:** MEDIUM (out-of-tree module, narrow blast radius — can be unloaded)
**Cost:** 1-3 days (module design + build + integration)
**Reversibility:** rmmod the module
**Last updated:** 2026-05-26

## Hypothesis

If E17 (setpci + FLR chain) FAILed because the kernel actively re-programs bridge windows during rescan (overriding userspace writes), the next layer is a kernel module that calls the kernel's own internal bridge-resize functions directly. The kernel has internal symbols `pci_bus_assign_resources`, `pci_assign_unassigned_bridge_resources`, etc. that are not exposed to userspace but are callable from in-tree kernel code.

Hypothesis: a small out-of-tree module that exposes a debugfs entry `/sys/kernel/debug/bridge_resize_trigger` and, when written to, calls these internal functions on a specified bridge — would unlock the recovery path without needing a full kernel patch.

**Status:** BLOCKED until we have a kernel module dev workflow established.

## Falsification gates

**PASS:** module loaded; writing to debugfs trigger causes BAR1=32G.

**FAIL:** module loaded; debugfs write returns 0 but BAR sizes unchanged. Kernel's resource assignment treats the bus as already-assigned and short-circuits.

**INCONCLUSIVE:** module won't compile; module won't load; kernel panics on first invocation.

## Prerequisites

- BLOCKED: kernel build env (same as E25)
- Understanding of `drivers/pci/setup-bus.c` internals
- Module signing key (Fedora secure boot)

## Method (when unblocked)

### Step 1 — Identify in-kernel functions to call

```bash
# Functions of interest:
grep -rn "pci_bus_assign_resources\|pci_assign_unassigned_bridge_resources\|__pci_setup_bus" /root/kernel-src/drivers/pci/

# Specifically:
#   - pci_bus_assign_resources(struct pci_bus *bus)
#   - pci_assign_unassigned_root_bus_resources(struct pci_bus *bus)
#   - pci_assign_unassigned_bridge_resources(struct pci_dev *bridge)
#   - pci_setup_bridge(struct pci_bus *bus)
```

### Step 2 — Write the module

Create `~/bridge-resize-module/bridge_resize.c`:

```c
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/debugfs.h>

static struct dentry *dbgdir;

static ssize_t bridge_resize_write(struct file *f, const char __user *buf,
                                    size_t len, loff_t *off)
{
    char input[32];
    struct pci_dev *bridge;
    unsigned int domain, bus, slot, fn;
    int n;

    if (len >= sizeof(input)) return -EINVAL;
    if (copy_from_user(input, buf, len)) return -EFAULT;
    input[len] = 0;

    n = sscanf(input, "%x:%x:%x.%x", &domain, &bus, &slot, &fn);
    if (n != 4) return -EINVAL;

    bridge = pci_get_domain_bus_and_slot(domain, bus, PCI_DEVFN(slot, fn));
    if (!bridge) return -ENODEV;

    pr_info("bridge_resize: triggering resize on %04x:%02x:%02x.%01x\n",
            domain, bus, slot, fn);

    /* Call the internal function — this is the experiment */
    pci_assign_unassigned_bridge_resources(bridge);

    pci_dev_put(bridge);
    return len;
}

static const struct file_operations fops = {
    .owner = THIS_MODULE,
    .write = bridge_resize_write,
};

static int __init bridge_resize_init(void)
{
    dbgdir = debugfs_create_file("bridge_resize_trigger", 0200, NULL, NULL, &fops);
    if (IS_ERR(dbgdir)) return PTR_ERR(dbgdir);
    return 0;
}

static void __exit bridge_resize_exit(void)
{
    debugfs_remove(dbgdir);
}

module_init(bridge_resize_init);
module_exit(bridge_resize_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Trigger PCI bridge resource resize from userspace");
```

Create Makefile:

```makefile
obj-m += bridge_resize.o
all:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules
clean:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
```

### Step 3 — Build

```bash
cd ~/bridge-resize-module/
make
# Expected: bridge_resize.ko built
```

### Step 4 — Sign (Fedora secure boot)

```bash
sudo /usr/src/kernels/$(uname -r)/scripts/sign-file sha256 \
  /var/lib/dkms/mok.key /var/lib/dkms/mok.pub bridge_resize.ko
```

### Step 5 — Load module

```bash
sudo insmod bridge_resize.ko
dmesg | tail -5  # confirm "bridge_resize: ..." or load successful
ls -la /sys/kernel/debug/bridge_resize_trigger
```

### Step 6 — Run two-phase test

```bash
# Phase A: control (no resize trigger needed at boot)
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --baseline E26-cold-control

# Phase B: enter broken-BAR1 state via cable cycle (per recipe)
# Then trigger resize on the bridge that owns the GPU
echo "0000:02:00.0" | sudo tee /sys/kernel/debug/bridge_resize_trigger

sleep 5

sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --snapshot E26
sudo /root/nvidia-driver-injector/tools/get-pci-stats.sh --diff E26
```

### Step 7 — Unload module

```bash
sudo rmmod bridge_resize
```

## Predicted PASS signature

```
Module loaded; debugfs entry present
Phase B: BAR1: 256M → 32G after `echo <bridge> > .../bridge_resize_trigger`
         Bridge windows expanded via in-kernel resource assignment
```

## Predicted FAIL signature

```
Module loaded; debugfs write returns 0 but state unchanged
→ pci_assign_unassigned_bridge_resources short-circuits when bus already assigned
→ may need different internal entry point or explicit unassign step
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Module won't load (signing) | "Required key not available" | sign with MOK; or disable secure boot for test |
| Kernel panic on write | dmesg BUG/OOPS | rmmod won't work if panicked; reboot; revise module |
| Internal function not exported | compile error "undefined symbol" | check `EXPORT_SYMBOL` for chosen function; may need to use different entry point |
| Write succeeds but resize doesn't happen | function logged but no state change | the resize logic has internal gates; explicit unassign step likely needed first |

## Per-run records

> One subsection per execution. Body-of-evidence builds across runs.

### Run 1 — pending

(Filled in when run. Conditions / Protocol deviations / Result / Diff highlights / Forensic bundle / Anomalies / Conclusion.)

## Patch coverage analysis

(Filled in if a run surfaces driver-level behavior.)

## Patch design implications

(Filled in once body-of-evidence supports a design decision.)

## Open follow-ups

- [ ] (Populated based on run results.)

## Forensic bundles

| Run | Bundle path | Size | Notes |
|---|---|---|---|
|     |             |      |       |

## Cross-references

- Linux source: `drivers/pci/setup-bus.c::pci_assign_unassigned_bridge_resources`
- Linux source: `drivers/pci/probe.c::pci_scan_bridge`
- E25 (Miroshnichenko v9 — broader scope)
- E27 (PCI core patch — most invasive)
