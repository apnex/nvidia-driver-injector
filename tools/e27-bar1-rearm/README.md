# e27-bar1-rearm — deterministic in-kernel BAR1 recovery experiment

Experiment toward **E27**: retire `tools/fix-bar1.sh` with a deterministic,
in-kernel recovery of a TB-hot-add broken/misaligned BAR1, using **exported PCI
primitives only** (no kernel rebuild, no cmdline). Conclusive scoping:
`docs/missions/mission-1-egpu-hot-plug-hot-power/finding-2026-06-13-E27-halfb-determinism-verdict.md`.

**Mechanism** (`tbegpu_bar1_rearm.c`): GPU on-bus, nvidia *unbound*, decode off →
`pci_release_resource()` the empty downstream-port sibling prefetch windows (the
cascade-blockers) → `pci_resize_resource(gpu,1,15,0)`, which cascades release
GPU→root, re-sizes the root hotplug port with the `hpmmioprefsize` reserve,
re-places it bottom-up at the firmware-constant 32 G-aligned base, and restores
the chip ReBAR CTRL (`pci_rebar_set_size`) in the same call — both recovery
halves in one sequence. Reviewed (must-fix `pci_lock_rescan_remove` bracket
applied); `dry_run=Y` default.

## Build
```
make KDIR=/usr/src/kernels/$(uname -r)   # or just `make` against the running kernel
```

## Run (⚠ live PCI surgery — operator at console, capture armed, soak interrupted)
```
sudo CONFIRM=yes ./run-experiment.sh 0    # dry-run survey (no writes)
sudo CONFIRM=yes ./run-experiment.sh 1    # WET aligned positive control
sudo CONFIRM=yes ./run-experiment.sh 2    # WET recovery proof n>=3 (needs MISALIGNED substrate)
```
Stage 2 needs an *aged* tree where the root port's prefetch window is **not**
32 G-aligned; the harness refuses to run it otherwise (aging is uncontrolled —
do it at-console). Harnesses key on the module's `RESULT=OK|FAIL|DRYRUN` dmesg
line, not the modprobe exit code (always 0 by the stay-loaded design).
