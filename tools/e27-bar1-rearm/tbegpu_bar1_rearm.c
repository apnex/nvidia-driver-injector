// SPDX-License-Identifier: GPL-2.0
/*
 * tbegpu_bar1_rearm.c -- EXPERIMENT module for E27 half-(b) determinism.
 *
 * Goal: deterministically recover a TB-hot-add broken/misaligned BAR1 from
 * kernel context using EXPORTED PCI primitives, reproducing tools/fix-bar1.sh
 * WITHOUT a pciehp slot power-cycle -- and in one sequence that also restores
 * the chip's Physical ReBAR CTRL (half (a) subsumed).
 *
 * Root cause (see finding-2026-06-13-E27-halfb-determinism-verdict.md): on an
 * aged tree the root hotplug port's OWN prefetch window freezes at a
 * 32G-MISALIGNED base; setup-bus.c's resource_assigned() skip then refuses to
 * re-size it, so the only 32G-aligned interior slot is high with no room.
 *
 * Sequence (GPU on-bus, nvidia UNBOUND, before any driver binds):
 *   1. decode-off: clear PCI_COMMAND_MEMORY on the GPU.
 *   2. release the prefetch window of each EMPTY downstream-port sibling on the
 *      GPU's parent bus -- their assigned windows are children of the
 *      grandparent bridge window and stop the !res->child release walk, so a
 *      naive single resize dies before reaching the root port.
 *   3. pci_resize_resource(gpu, 1 [BAR1], size, 0): cascades release
 *      GPU->root, re-sizes the root hotplug port WITH the hpmmioprefsize
 *      reserve, re-places it bottom-up first-fit at the firmware-constant base,
 *      and calls pci_rebar_set_size() = chip CTRL 0x8 -> 0xF restore.
 *   4. pci_reset_function() [FLR]: the resize only re-fences the chip's internal
 *      aperture across a reset; FLR's save/restore rewrites ReBAR CTRL=0xF for the
 *      resized size. (Pin reset_method=flr first so this cannot escalate to a
 *      link-down slot/bus reset.)
 *   5. verify-before-bind (verify=Y): poll the chip's MMIO (PMC_BOOT_0 gate +
 *      BAR2[0] diagnostic) until it re-fences, up to settle_ms, and gate RESULT=OK
 *      on that -- not on the resource struct (which is a confirmed false-positive).
 *      verify=N reverts to a blind msleep(settle_ms) control arm.
 *
 * Params: gpu=<BDF> (default 0000:04:00.0), size=<rebar enc> (default 15=32G),
 *         dry_run=<bool> (default Y -- survey + plan only, NO writes),
 *         flr=<bool> (default Y), verify=<bool> (default Y),
 *         settle_ms=<uint> (default 2000 -- verify poll budget / blind sleep).
 *
 * SAFETY: live PCI resource surgery. Run ONLY with nvidia fully rmmod'd (not
 * merely sysfs-unbound -- closes the bind TOCTOU), GPU quiesced, operator at
 * console, capture armed, NO cable touch during the run. Steps 1-3 are
 * bracketed in pci_lock_rescan_remove() so the sibling walk + resize are
 * serialized against pciehp add/remove (a concurrent TB teardown cannot free a
 * sibling mid-walk). The harness asserts cmdline preconditions
 * (pci=hpmmioprefsize=32G,realloc=on) the way fix-bar1 does; this module logs
 * the root-port window size as realloc evidence and emits a grep-able
 * RESULT=OK|FAIL|DRYRUN line (its exit code is always 0 by the stay-loaded
 * design, so harnesses MUST key on RESULT=, not modprobe rc).
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/pci.h>
#include <linux/ioport.h>
#include <linux/sizes.h>
#include <linux/delay.h>
#include <linux/io.h>

#define TAG "tbegpu-rearm: "

/* NV_PMC_BOOT_0 lives at BAR0 offset 0 and reads the chip's
 * arch/impl/revision id — the cheap liveness/decode probe fix-bar1 + A3 use.
 * BAR1 is the 64-bit framebuffer aperture (resource[1]+resource[2]); BAR2's low
 * half is therefore resource[3] (the 32 MiB aperture whose MMU readback is what
 * RM's kbusVerifyBar2 exercises). */
#define NV_PMC_BOOT_0   0x00000000u
#define GPU_BAR0_INDEX  0
#define GPU_BAR2_INDEX  3

static char *gpu = "0000:04:00.0";
module_param(gpu, charp, 0444);
MODULE_PARM_DESC(gpu, "GPU PCI address, domain:bus:slot.func (default 0000:04:00.0)");

static int size = 15; /* ReBAR size encoding: 15 => 2^(15+20) = 32 GiB */
module_param(size, int, 0444);
MODULE_PARM_DESC(size, "ReBAR size encoding for BAR1 (default 15 = 32 GiB)");

static bool dry_run = true;
module_param(dry_run, bool, 0444);
MODULE_PARM_DESC(dry_run, "survey + plan only, perform NO writes (default Y)");

static bool flr = true;
module_param(flr, bool, 0444);
MODULE_PARM_DESC(flr, "after a successful resize, FLR the device (pci_reset_function) so it re-fences its internal aperture to the new BAR — fixes the device-state desync that wedged a moved live BAR (default Y; set N to test resize-only)");

static unsigned int settle_ms = 2000;
module_param(settle_ms, uint, 0444);
MODULE_PARM_DESC(settle_ms, "post-FLR budget (ms): with verify=Y it bounds the verify-before-bind poll (stops at first sane read); with verify=N it is a blind msleep. The relatch is non-deterministic on wall-clock alone (cycle-1 had seconds, cycle-2 had ms and failed). Default 2000.");

static bool verify = true;
module_param(verify, bool, 0444);
MODULE_PARM_DESC(verify, "after FLR, poll the chip's MMIO (PMC_BOOT_0 + BAR2[0]) until it re-fences its aperture, and gate RESULT=OK on a sane readback rather than a blind sleep — turns the settle gamble into a deterministic readiness gate and refuses to bless a still-desynced chip. verify=N reverts to a blind msleep(settle_ms) control arm. Default Y.");

/* A resource is genuinely assigned iff it is inserted in the tree, not marked
 * UNSET, and has a non-zero size. pci_release_resource() leaves flags +size
 * intact but sets IORESOURCE_UNSET and start=0, so the naive
 * "flags && size" test would mislabel a released window as assigned (and
 * IS_ALIGNED(0, ...) would read a released BAR1 as "aligned"). */
static bool res_is_assigned(const struct resource *r)
{
	return r->parent && !(r->flags & IORESOURCE_UNSET) && resource_size(r) > 0;
}

static void log_pref_window(const char *what, struct pci_dev *bridge)
{
	struct resource *w = &bridge->resource[PCI_BRIDGE_PREF_MEM_WINDOW];

	if (res_is_assigned(w))
		pr_info(TAG "%s %s pref %pR size=%lluM aligned32G=%s\n",
			what, pci_name(bridge), w,
			(unsigned long long)(resource_size(w) >> 20),
			IS_ALIGNED((u64)w->start, SZ_32G) ? "yes" : "NO");
	else
		pr_info(TAG "%s %s pref UNASSIGNED %pR\n", what, pci_name(bridge), w);
}

/* Walk GPU -> root, logging GPU BAR1 + each parent bridge's prefetch window. */
static void log_chain(const char *what, struct pci_dev *gpu_dev)
{
	struct resource *r1 = &gpu_dev->resource[1];
	struct pci_dev *b = gpu_dev->bus ? gpu_dev->bus->self : NULL;

	if (res_is_assigned(r1))
		pr_info(TAG "%s GPU %s BAR1 %pR size=%lluM aligned32G=%s\n",
			what, pci_name(gpu_dev), r1,
			(unsigned long long)(resource_size(r1) >> 20),
			IS_ALIGNED((u64)r1->start, SZ_32G) ? "yes" : "NO");
	else
		pr_info(TAG "%s GPU %s BAR1 UNASSIGNED %pR\n", what, pci_name(gpu_dev), r1);

	while (b) {
		log_pref_window(what, b);
		b = b->bus ? b->bus->self : NULL;
	}
}

static int parse_bdf(const char *s, int *domain, unsigned int *busn, unsigned int *devfn)
{
	unsigned int b, d, f;

	if (sscanf(s, "%x:%x:%x.%x", domain, &b, &d, &f) != 4)
		return -EINVAL;
	if (b > 0xff || d > 0x1f || f > 0x7)
		return -EINVAL;
	*busn = b;
	*devfn = PCI_DEVFN(d, f);
	return 0;
}

static bool bridge_is_empty(struct pci_dev *b)
{
	return b->subordinate && list_empty(&b->subordinate->devices);
}

/*
 * Release the prefetch window of every EMPTY sibling downstream port on the
 * GPU's parent bus. MUST be called under pci_lock_rescan_remove() so the
 * bus->devices walk is stable against a concurrent TB teardown. Returns the
 * count released (dry_run: would-release), or <0 on error. Sets *failed to the
 * number of wet releases that returned non-zero.
 */
static int release_empty_siblings(struct pci_dev *gpu_dev, int *failed)
{
	struct pci_dev *gpu_bridge = gpu_dev->bus ? gpu_dev->bus->self : NULL;
	struct pci_dev *dev;
	int released = 0;

	*failed = 0;
	if (!gpu_bridge || !gpu_bridge->bus) {
		pr_err(TAG "no parent bridge for GPU; cannot find siblings\n");
		return -ENODEV;
	}

	list_for_each_entry(dev, &gpu_bridge->bus->devices, bus_list) {
		struct resource *w;

		if (dev == gpu_bridge || !pci_is_bridge(dev) || !bridge_is_empty(dev))
			continue;
		w = &dev->resource[PCI_BRIDGE_PREF_MEM_WINDOW];
		if (!res_is_assigned(w))
			continue;

		if (dry_run) {
			pr_info(TAG "[dry] would release %s pref %pR\n", pci_name(dev), w);
			released++;
		} else {
			int rc = pci_release_resource(dev, PCI_BRIDGE_PREF_MEM_WINDOW);

			pr_info(TAG "release %s pref -> rc=%d\n", pci_name(dev), rc);
			if (rc == 0)
				released++;
			else
				(*failed)++;
		}
	}
	return released;
}

static bool reg_sane(u32 v)
{
	return v != 0xffffffffu && v != 0;
}

/*
 * verify_aperture_refenced -- after the FLR, poll the chip's MMIO until its
 * internal aperture is re-fenced to the resized BAR, instead of blindly sleeping.
 *
 * Why MMIO and not a config read: the desync that wedged E1/cycle-2 is
 * config-says-32G / chip-aperture-stale. A ReBAR-CTRL config readback is useless
 * here -- pci_resize_resource + pci_restore_rebar_state already wrote CTRL=0xF, so
 * it reads 0xF whether or not the chip re-fenced. The desync is visible ONLY via
 * MMIO.
 *
 * Decode: memory decode is OFF on entry (pci_reset_function restored the module's
 * decode-off PCI_COMMAND), so we MUST set PCI_COMMAND_MEMORY before any read or
 * every readl() returns 0xffffffff because the BAR does not decode. We restore the
 * saved (decode-off) COMMAND on exit to preserve the module's audited
 * "leaves decode off" invariant; nvidia re-enables decode at bind.
 *
 * Signals:
 *  - PMC_BOOT_0 (BAR0[0]) sane = the GATE. BAR0 is the register aperture (distinct
 *    from the framebuffer BAR1 / BAR2), so this reliably catches the Stage-1-class
 *    "BOOT_0 garbage" desync and a dead/decode-failed chip. NOTE it does NOT by
 *    itself discriminate the cycle-2 BAR2-MMU desync (BAR0 can read sane while BAR2
 *    is stale) -- the true oracle for that remains RmInitAdapter/kbusVerifyBar2 at
 *    bind, backstopped by the runbook fail-safe (immediate rmmod, no retry).
 *  - BAR2[0] raw is read + LOGGED as a diagnostic. A raw read without RM's MMU
 *    setup is only a proxy for kbusVerifyBar2, so we do not hard-gate on it yet; we
 *    collect it to learn empirically whether 0xffffffff here predicts the bind FAIL.
 *
 * Returns true iff PMC_BOOT_0 read sane within budget_ms; *t_sane_ms = elapsed ms
 * to first sane read (budget_ms on failure); *bar2_at_sane = BAR2[0] at that point.
 */
static bool verify_aperture_refenced(struct pci_dev *gpu_dev, unsigned int budget_ms,
				     unsigned int *t_sane_ms, u32 *bar2_at_sane)
{
	resource_size_t b0 = pci_resource_start(gpu_dev, GPU_BAR0_INDEX);
	resource_size_t b2 = pci_resource_start(gpu_dev, GPU_BAR2_INDEX);
	const unsigned int step_ms = 150;
	unsigned int elapsed = 0;
	void __iomem *bar0, *bar2 = NULL;
	u16 saved_cmd;
	bool sane = false;
	u32 boot0, bar2_0 = 0xffffffffu;

	/* clamp so `elapsed += step_ms` cannot wrap a pathological near-UINT_MAX budget */
	if (budget_ms > 600000u)
		budget_ms = 600000u;
	*t_sane_ms = budget_ms;
	*bar2_at_sane = 0xffffffffu;

	if (!b0) {
		pr_warn(TAG "verify: GPU BAR0 has no base; cannot MMIO-verify\n");
		return false;
	}

	/* decode ON for the reads (restored to the saved value on exit) */
	pci_read_config_word(gpu_dev, PCI_COMMAND, &saved_cmd);
	pci_write_config_word(gpu_dev, PCI_COMMAND, saved_cmd | PCI_COMMAND_MEMORY);

	bar0 = ioremap(b0, 0x1000);
	if (!bar0) {
		pr_warn(TAG "verify: ioremap BAR0 @%pa failed\n", &b0);
		pci_write_config_word(gpu_dev, PCI_COMMAND, saved_cmd);
		return false;
	}
	if (b2) {
		bar2 = ioremap(b2, 0x1000);
		if (!bar2)
			pr_warn(TAG "verify: ioremap BAR2 @%pa failed; bar2[0] diagnostic unavailable\n", &b2);
	}

	for (;;) {
		boot0  = readl(bar0 + NV_PMC_BOOT_0);
		bar2_0 = bar2 ? readl(bar2) : 0xffffffffu;
		pr_info(TAG "verify: t=%ums boot0=0x%08x bar2[0]=0x%08x%s\n",
			elapsed, boot0, bar2_0,
			reg_sane(boot0) ? " (boot0 SANE)" : "");
		if (reg_sane(boot0)) {
			sane = true;
			*t_sane_ms = elapsed;
			*bar2_at_sane = bar2_0;
			break;
		}
		if (elapsed >= budget_ms)
			break;
		msleep(step_ms);
		elapsed += step_ms;
	}

	iounmap(bar0);
	if (bar2)
		iounmap(bar2);
	pci_write_config_word(gpu_dev, PCI_COMMAND, saved_cmd); /* decode back off */

	if (sane)
		pr_info(TAG "verify: boot0 re-fenced at t=%ums, bar2[0]=0x%08x%s\n",
			*t_sane_ms, *bar2_at_sane,
			reg_sane(*bar2_at_sane) ? "" :
			" — BAR2 raw still 0xffffffff (boot0 gate only; expect kbusVerifyBar2 risk at bind)");
	else
		pr_warn(TAG "verify: boot0 NOT sane within %ums — chip aperture not re-fenced; do NOT bind\n",
			budget_ms);
	return sane;
}

static int __init rearm_init(void)
{
	int domain, rc, freed, failed = 0, resize_rc = 0, frc = -1;
	unsigned int busn, devfn, t_sane = 0;
	struct pci_dev *gpu_dev;
	struct resource *r1;
	u32 bar2_at_sane = 0xffffffffu;
	u16 cmd;
	bool ok, refenced = false, flr_ok;

	pr_info(TAG "load: gpu=%s size=%d dry_run=%d flr=%d verify=%d settle_ms=%u\n",
		gpu, size, dry_run, flr, verify, settle_ms);

	rc = parse_bdf(gpu, &domain, &busn, &devfn);
	if (rc) {
		pr_err(TAG "bad gpu BDF '%s'\n", gpu);
		return rc;
	}
	gpu_dev = pci_get_domain_bus_and_slot(domain, busn, devfn);
	if (!gpu_dev) {
		pr_err(TAG "GPU %s not present on the bus\n", gpu);
		return -ENODEV;
	}
	/* Must run with nvidia UNBOUND. Authoritative guarantee is `rmmod nvidia`
	 * (no driver exists to bind); this is a fail-fast pre-check. */
	if (gpu_dev->driver) {
		pr_err(TAG "GPU has driver '%s' bound; rmmod nvidia first\n",
		       gpu_dev->driver->name);
		pci_dev_put(gpu_dev);
		return -EBUSY;
	}

	log_chain("PRE ", gpu_dev);

	/* Serialize Steps 1-3 against pciehp add/remove: makes the sibling
	 * bus->devices walk UAF-safe and prevents a TB teardown from racing the
	 * resize. pci_release_resource/pci_resize_resource take only resource_lock
	 * / pci_bus_sem internally -- neither takes pci_rescan_remove_lock, so no
	 * recursion. */
	pci_lock_rescan_remove();

	/* Step 1: memory decode OFF (resize precondition; -EBUSY gate). */
	pci_read_config_word(gpu_dev, PCI_COMMAND, &cmd);
	pr_info(TAG "GPU COMMAND=0x%04x (mem-decode %s)\n", cmd,
		(cmd & PCI_COMMAND_MEMORY) ? "ON" : "off");
	if (cmd & PCI_COMMAND_MEMORY) {
		if (dry_run)
			pr_info(TAG "[dry] would clear PCI_COMMAND_MEMORY\n");
		else
			pci_write_config_word(gpu_dev, PCI_COMMAND,
					      cmd & ~PCI_COMMAND_MEMORY);
	}

	/* Step 2: release the cascade-blocking empty sibling windows. */
	freed = release_empty_siblings(gpu_dev, &failed);
	if (freed < 0) {
		pci_unlock_rescan_remove();
		pci_dev_put(gpu_dev);
		return freed;
	}
	pr_info(TAG "empty-sibling pref windows %s: %d (release-failures: %d)\n",
		dry_run ? "that would be released" : "released", freed, failed);

	/* Step 3: resize BAR1 -> cascade release+reassign + chip CTRL restore. */
	if (dry_run) {
		pr_info(TAG "[dry] would call pci_resize_resource(%s, 1, %d, 0)\n",
			pci_name(gpu_dev), size);
	} else {
		resize_rc = pci_resize_resource(gpu_dev, 1, size, 0);
		pr_info(TAG "pci_resize_resource(BAR1, size=%d) -> rc=%d%s\n",
			size, resize_rc,
			resize_rc == -ENOTSUPP ? " (preserve_config?)" :
			resize_rc == -EBUSY ? " (decode still on / in use?)" :
			resize_rc == -EINVAL ? " (size unsupported?)" : "");

		/* Recovery: a failed resize leaves the module-released sibling
		 * windows UNSET (the cascade only restores its own saved list).
		 * Re-assign them on the grandparent so the tree isn't left
		 * needlessly degraded (host stays up either way). */
		if (resize_rc && gpu_dev->bus && gpu_dev->bus->self &&
		    gpu_dev->bus->self->bus && gpu_dev->bus->self->bus->self) {
			struct pci_dev *gp = gpu_dev->bus->self->bus->self;

			pr_info(TAG "resize failed; re-assigning released siblings on %s\n",
				pci_name(gp));
			pci_assign_unassigned_bridge_resources(gp);
		}
	}

	pci_unlock_rescan_remove();

	/* Post-resize device reset (OUTSIDE the rescan lock — pci_reset_function
	 * sleeps + takes device/bridge locks). The Stage-1 wedge was device-state:
	 * moving the BAR of an already-RM-initialized chip left its internal aperture
	 * desynced from config (BOOT_0 MMIO read garbage). FLR resets internal state
	 * while PRESERVING the resized BAR — pci_dev_save_and_disable captures the new
	 * base + ReBAR CTRL, FLR resets, pci_restore_state -> pci_restore_rebar_state
	 * re-derives 32 GiB and rewrites CTRL=0xF, then restores the base. On a fresh
	 * broken-256 M chip this is defense-in-depth (nvidia's own probe resizes with
	 * no reset). flr=N skips it to isolate whether the reset is needed. */
	if (dry_run) {
		if (flr)
			pr_info(TAG "[dry] would FLR (pci_reset_function), then %s\n",
				verify ? "poll MMIO until the aperture re-fences (verify-before-bind gate)"
				       : "blind-settle (verify=N control arm)");
	} else if (flr && resize_rc == 0) {
		frc = pci_reset_function(gpu_dev);
		pr_info(TAG "pci_reset_function (FLR) -> rc=%d%s\n", frc,
			frc ? " (reset failed — device may be unusable)" : "");

		/* The Blackwell re-fences its internal aperture to the new ReBAR size
		 * only some time after the FLR; cycle-1 (PASS) had ~seconds before bind,
		 * cycle-2 (FAIL) bound within ms. verify=Y polls the chip's MMIO and
		 * gates RESULT on an observed re-fence (deterministic readiness gate);
		 * verify=N is the blind-settle control arm. Both run OUTSIDE the rescan
		 * lock, which pci_reset_function already dropped. */
		if (frc == 0 && verify) {
			refenced = verify_aperture_refenced(gpu_dev, settle_ms,
							    &t_sane, &bar2_at_sane);
		} else if (frc == 0 && settle_ms > 0) {
			pr_info(TAG "blind settle %u ms (verify=N control arm; RESULT not chip-verified)\n",
				settle_ms);
			msleep(settle_ms);
		}
	}

	log_chain("POST", gpu_dev);

	/* PASS criterion: the resource is 32 GiB/32G-aligned AND (when an FLR was
	 * requested) it succeeded AND (when verify was requested) the chip's MMIO
	 * re-fenced. The resource test alone is a CONFIRMED false-positive: it read
	 * 32G/aligned in both the cycle-1 PASS and the cycle-2 FAIL. Exit code is
	 * always 0 (stay-loaded) -- harness keys on RESULT=. */
	r1 = &gpu_dev->resource[1];
	flr_ok = (!flr || frc == 0);
	ok = flr_ok &&
	     res_is_assigned(r1) && resource_size(r1) == SZ_32G &&
	     r1->start != 0 && IS_ALIGNED((u64)r1->start, SZ_32G) &&
	     (!(flr && verify) || refenced);
	if (dry_run)
		pr_info(TAG "RESULT=DRYRUN (no writes performed)\n");
	else if (ok && flr && verify)
		pr_info(TAG "RESULT=OK BAR1=32G@%pa aligned, boot0-verified (sane @t=%ums, bar2[0]=0x%08x)%s\n",
			&r1->start, t_sane, bar2_at_sane,
			reg_sane(bar2_at_sane) ? "" :
			" [CAVEAT: BAR2 raw still 0xffffffff — boot0 gate only, expect kbusVerifyBar2 risk at bind]");
	else if (ok)
		pr_info(TAG "RESULT=OK BAR1=32G@%pa aligned (NOT chip-verified — verify=N/flr=N; the bind verdict is RmInitAdapter)\n",
			&r1->start);
	else if (flr && resize_rc == 0 && frc != 0)
		pr_info(TAG "RESULT=FAIL frc=%d (FLR ran and did not succeed; do NOT bind)\n", frc);
	else if (flr && verify && resize_rc == 0 && !refenced)
		pr_info(TAG "RESULT=FAIL aperture not re-fenced within %ums (boot0 never sane; do NOT bind)\n",
			settle_ms);
	else
		pr_info(TAG "RESULT=FAIL resize_rc=%d (BAR1 not 32G/32G-aligned)\n",
			resize_rc);

	pr_info(TAG "done (dry_run=%d). rmmod to unload (no state held).\n", dry_run);
	pci_dev_put(gpu_dev);
	return 0;
}

static void __exit rearm_exit(void)
{
	pr_info(TAG "unload\n");
}

module_init(rearm_init);
module_exit(rearm_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("apnex");
MODULE_DESCRIPTION("E27 experiment: deterministic TB-hot-add BAR1 re-arm via exported PCI primitives");
