# DIMC ResNet VMVM tests

This repository contains the Spatz RTL and the ResNet VMVM software sources. The
current test kernels are in `isa/rv64uv/vmvm_resnet_overlap.c`,
`vmvm_resnet_transition.c`, and their headers. The default matrix header is
`../../hw/system/spatz_cluster/generated_matrices.h`; a different layer input
can be supplied through the `RESNET_OVERLAP_HEADER` CMake option. Generated
results, simulation traces, and toolchains are intentionally excluded.

The Spatz software build follows the current upstream LLVM toolchain setup.
Use `hw/system/spatz_cluster/Makefile` to configure it. The updated GVSoC
simulation model is in the companion `OmkarRajeshKokane/gvsoc` repository, with
its `core` and `pulp` submodules. Set `GVSOC_ROOT` to that checkout when
running the helper scripts from a separate Spatz checkout:

```sh
export GVSOC_ROOT=/path/to/gvsoc
python3 hw/system/spatz_cluster/script/run_resnet_overlap.py \
  --out /path/to/results --mode prepare --layers Conv1
python3 hw/system/spatz_cluster/script/run_resnet_overlap.py \
  --out /path/to/results --mode software --layers Conv1
```

`run_resnet_overlap.py` generates layer inputs and builds the timing and
numerical-check executables. The `software` mode runs the numerical check on
Spatz v2 in GVSoC. `rtl` mode requires a built RTL simulator; pass its path
with `--rtl-bin`.

`run_resnet_transition.py` and `run_resnet_b8.py` reproduce later scheduling
experiments. They expect the frozen per-layer inputs in
`$GVSOC_ROOT/results/resnet_overlap_20260914/release` and will report an error
if those local experiment files are absent. Their outputs are not part of this
source repository.
