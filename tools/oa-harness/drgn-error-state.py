#!/usr/bin/env drgn
# drgn-error-state.py — BEST-EFFORT authoritative read of a pci_dev->error_state
# (and, if NVIDIA module symbols are loadable, the OBJGPU PDB_PROP_GPU_IS_LOST)
# for the A10-v2 (F44) live validation.
#
# WHY best-effort: on this host drgn runs with kernel BTF only (no vmlinux
# debuginfo, no module debuginfo). BTF gives TYPES but NOT global-variable
# addresses, so symbol lookups (pci_bus_type / for_each_pci_dev) FAIL. This
# script therefore DEGRADES GRACEFULLY: it prints one line and exits.
#   - "ERROR_STATE bdf=<bdf> state=<n> name=<io_normal|io_perm_failure|...>"  on success
#   - "DRGN_UNAVAILABLE: <reason>"                                            on failure
# The runner treats any non-"ERROR_STATE" output as "drgn unavailable" and
# falls back to the drgn-FREE load-bearing gate (tb_egpu_state sysfs proxy +
# the deterministic next-open rc=0). To make this script authoritative, install
# matching debuginfo:  sudo dnf debuginfo-install -y kernel-core-$(uname -r)
#
# Usage:  sudo drgn tools/oa-harness/drgn-error-state.py <bdf>   (default 0000:04:00.0)

import sys

# pci_channel_state_t: io_normal=1, io_frozen=2, io_perm_failure=3 (0 also = normal)
_STATE = {0: "io_normal(0)", 1: "io_normal", 2: "io_frozen", 3: "io_perm_failure"}


def main():
    bdf = sys.argv[1] if len(sys.argv) > 1 else "0000:04:00.0"
    try:
        import drgn
        from drgn.helpers.linux.pci import for_each_pci_dev, pci_name
    except Exception as e:  # pragma: no cover
        print(f"DRGN_UNAVAILABLE: import failed: {e}")
        return 2

    prog = drgn.get_default_prog()

    try:
        for dev in for_each_pci_dev(prog):
            try:
                name = pci_name(dev)
            except Exception:
                name = None
            if name == bdf:
                st = int(dev.error_state.value_())
                print(f"ERROR_STATE bdf={bdf} state={st} name={_STATE.get(st, f'unknown({st})')}")
                # Module-symbol territory (needs nvidia.ko debuginfo) — best-effort only.
                try:
                    _try_gpu_lost(prog, dev, bdf)
                except Exception as e:
                    print(f"GPU_LOST_UNAVAILABLE: {e}")
                return 0
        print(f"DRGN_UNAVAILABLE: pci_dev {bdf} not found in for_each_pci_dev")
        return 3
    except Exception as e:
        # The expected path under BTF-only: globals unresolvable.
        print(f"DRGN_UNAVAILABLE: pci walk failed ({type(e).__name__}: {e}); "
              f"install kernel-core debuginfo for authoritative reads")
        return 2


def _try_gpu_lost(prog, dev, bdf):
    # Reaching OBJGPU.PDB_PROP_GPU_IS_LOST from a pci_dev requires NVIDIA module
    # symbols (nv_linux_state -> nv_state -> OBJGPU). Not available without
    # nvidia.ko debuginfo; left as a clearly-flagged stub so it lights up if
    # symbols are ever loaded.
    raise NotImplementedError("OBJGPU traversal needs nvidia.ko debuginfo (not loaded)")


if __name__ == "__main__":
    sys.exit(main())
