# Final ResNet tests

## Shared Conv1–Conv5 chunk overlap (2026-09-16)

The accepted Conv3 scheduling changes are now shared by all five convolution
tests. `isa/rv64uv/vmvm_resnet_transition.c` selects
`vmvm_resnet_b8.h` and `vmvm_resnet_chunk_overlap.h`: precomputed TCDM work
records, earlier feature/configuration preparation, carried peeled-group
stores, kernel staging during E32 partial sums, and next-chunk bootstrap before
loop bookkeeping. Completed-output DMA retains its store-completion barrier.

Conv1/Conv2 preserve resident inputs and their original tile sizes, using
16-byte work records and kernel-load cursors for 256/640-byte row strides.
Conv4/Conv5 carry exactly four/one tail result pairs into the next bootstrap;
the tails never compute or store padded positions. Full B8 groups still collect
16 output registers before E32 addition. The hardware stays at 4 IPUs, 1 FPU,
VLEN=1024. FinalFC keeps its existing single-position path.

The current frozen suite is `results/resnet_chunk_overlap_20260916`. Its
[validation record and run instructions](../../../results/resnet_chunk_overlap_20260916/README.md)
distinguish software correctness, numerical RTL prefixes and full RTL timing.
The cycle tables below describe earlier source revisions.

To run full RTL timing from the prepared, validated convolution executables:

```sh
source sourceme.sh
python3 spatz/hw/system/spatz_cluster/script/run_resnet_b8.py \
  --out results/resnet_chunk_overlap_20260916 \
  --layers Conv1,Conv2,Conv3,Conv4,Conv5 \
  --mode rtl --workers 3 --timeout 7200
```

Use `--workers 2` for two simultaneous layer simulations. To rebuild current
source and perform software checks, numerical RTL prefixes and full RTL in one
command, use `--mode all` with a fresh output directory.

Each full run writes `<out>/ConvN/rtl/activity.vcd`, `ConvN/rtl.log` and
`ConvN/rtl.json`; combined results are in `<out>/results.csv`. These VCDs cover
the complete execution with the selected DIMC/IPU/writeback/group signals,
not every RTL net. Numerical-prefix VCDs are under `ConvN/rtl_prefix/`.
The updated prefixes cover 168, 64, 224, 44 and 41 positions respectively,
including Conv1/Conv2's actual final-tile shapes and Conv4/Conv5's short tails.

## Conv3: overlap the first B8 group stores (2026-09-16)

Conv3 now carries six output pairs from the peeled B8 group into the next group's
DIMC execution, with an early next-feature load and four early result-register
stores during the E32 IPU phase. Two next-input/kernel DMA setup calls become one
inline instruction block. Store completion, buffer-reuse ordering, complete B8
phases and E32 additions remain intact. Other layers retain their previous paths.

The full RTL total is **1,240,889 cycles**, down from 1,251,013 by **10,124 (0.81%)**.
DIMC busy is **1,058,029**; actual state-4 arithmetic remains **903,168**.
Elapsed compute-region timing is **1,232,478**. The matching marked window improves
757 → 623 cycles; its post-IPU restart gap improves 91 → 2 cycles. Remaining
state-0 intervals are explicitly accounted for in the linked audit.

Full software validation passes all 100,352 outputs. Numerical RTL-prefix
validation passes 28,672 outputs in **367,603 cycles**. Full-layer RTL is timing-only
and passes every activity/phase check with the same 4-IPU/1-FPU simulator.

[Cycle audit, selected sources, full results and marked waveform](../../../results/conv3_marked_idle_20260916/README.md).

## Conv3: launch the next chunk before loop bookkeeping (2026-09-16)

The preceding Conv3 schedule keeps the final complete-B8 E32 additions, next-kernel prefetch and
next-chunk launch together. Feature/store addresses are prepared early; remaining
result stores and loop bookkeeping execute after new DIMC instructions are queued.
The output-DMA completion barrier and all sixteen E32 additions remain present.

Full-layer RTL improves from **1,252,439 to 1,251,013 cycles** (1,426 fewer,
**0.1139%**). The previously identified 109-cycle post-IPU gap is **14 cycles**
in the matching full-layer group. Its complete transition interval improves from
752 to 728 cycles; the local gap reduction is not the net layer speedup.
DIMC busy is **1,058,237**, including setup/waits; actual state-4 arithmetic remains
**903,168**. Elapsed compute-region timing is **1,240,412** cycles.

Full software validation passes all 100,352 outputs. The numerical RTL prefix
passes 28,672 outputs in 370,845 cycles. Full-layer RTL is timing-only and passes
all B8, width and phase checks with the same 4-IPU/1-FPU simulator as before.
The source change is Conv3-only; the other layers retain their preceding results.

[Cycle-by-cycle audit, measured comparison, waveforms and frozen sources](../../../results/conv3_gap109_20260916/README.md).

## Conv3 kernel-chunk overlap (2026-09-16)

The preceding Conv3 schedule selects `isa/rv64uv/vmvm_conv3_transition.h` through the shared B8
source. It prepares DMA work records in TCDM during initial input staging,
prefetches the next kernel and feature as registers become free, and carries
final B8 stores into the next chunk's DIMC execution. Output DMA retains its
store-completion barrier and alternate output buffers. B8 remains eight
positions / sixteen result registers, with E32 partial-sum addition.

That 4-IPU/1-FPU RTL baseline measures **1,252,439 cycles**, down from
1,282,295 (**2.33%**). DIMC busy is **1,057,329** and state-4 arithmetic remains
**903,168**. Full software validation (100,352 outputs), numerical RTL prefix
validation (28,672 outputs), and the small transfer-overlap RTL probe all pass.
Full-layer RTL is timing-only. The extra TCDM descriptor allocation is 7,544
bytes and its preparation is included in layer timing. Other layers retain
the previous schedule; the table below records that earlier suite.

[Exact results, frozen sources, waveforms and reproduction](../../../results/conv3_chunk_overlap_20260916/README.md).

## Shared B8 tests with concurrent RTL runs

The latest Conv1-Conv5 schedule is `isa/rv64uv/vmvm_resnet_b8.h`, selected by
`vmvm_resnet_transition.c`. It prepares addresses early, issues memory transfers
while the first two DIMC instructions compute, then queues instructions 3 and 4
together. Full B8 groups collect sixteen output registers before e32 addition.
The shared control-overlap path carries the next group's pointers and loop
condition while DIMC finishes. It adds the registers that release feature
storage first, loads the next feature and stores the first completed output
pair during the remaining IPU additions, and programs E8 after the last E32
VADD is submitted. Accepted instructions retain their own configuration. A
completion check immediately before the next DIMC instruction preserves the
separate complete-B8 and E32-addition phases.
Conv4's final four positions use eight registers; Conv5's final position uses two.
No extra output positions are computed for those tails. FinalFC retains its
single-position schedule. All six tests use 4 IPUs, 1 FPU and VLEN=1024.

The targets are `test-riscvTests-vmvm_resnet_b8`, `_check`, and `_prefix`.
The runner freezes separate inputs and executables for each layer. Builds are
serial because they share the CMake build directory. `--workers 2` or
`--workers 3` runs that many independent layer simulations, each in its own
working directory. These workers do not change the simulated hardware.

From the repository root, prepare and validate a fresh suite:

```sh
source sourceme.sh
python3 spatz/hw/system/spatz_cluster/script/run_resnet_b8.py \
  --out results/resnet_b8_control_overlap_20260915 --mode check --workers 3
```

Then run all six full-layer RTL timing tests:

```sh
python3 spatz/hw/system/spatz_cluster/script/run_resnet_b8.py \
  --out results/resnet_b8_control_overlap_20260915 --mode rtl --workers 3
```

`--mode all` performs preparation, software validation, RTL prefix validation,
and full RTL timing in that order. `--layers Conv4,Conv5` selects a subset.
`--mode rtl_check` runs the full numerical checker in RTL as well.
The timing-only RTL mode requires matching software and RTL-prefix PASS records.
The numerical RTL prefixes cover 144, 56, 224, 44 and 41 positions for Conv1
through Conv5, respectively, and the full one-position FinalFC. They exercise
buffer transitions, repeated ordinary-group loop backedges and incomplete tails.
All outputs go under the chosen directory: per-layer logs, JSON results, frozen
ELFs, and selected-signal VCDs. `results.csv` includes total cycles, elapsed compute
region cycles, DIMC busy cycles and state-4 arithmetic cycles, with simulator
provenance and software/RTL modes kept separate. A full-layer result is valid
only after its JSON status is `TIMING_ONLY_SUCCESS` and the RTL log reports SUCCESS.

Measured control-overlap RTL results (4 IPUs, 1 FPU), compared with the previous
shared B8 schedule:

| Layer | Previous RTL | New RTL | Reduction | DIMC busy | State 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Conv1 | 2,398,617 | 2,332,611 | 2.75% | 1,890,664 | 1,605,632 |
| Conv2 | 1,882,456 | 1,839,343 | 2.29% | 1,217,636 | 1,003,520 |
| Conv3 | 1,343,273 | 1,282,295 | 4.54% | 1,057,893 | 903,168 |
| Conv4 | 1,420,054 | 1,353,743 | 4.67% | 1,056,802 | 903,168 |
| Conv5 | 1,932,962 | 1,846,297 | 4.48% | 1,097,447 | 903,168 |
| FinalFC | 176,541 | 176,541 | 0.00% | 72,608 | 16,384 |

All six full software checks and numerical RTL prefix checks pass. Full-layer
RTL timing omits numerical checking and uses the same simulator as the baseline.
The total is 8,830,830 cycles, a 3.53% reduction; every state-4 arithmetic count is
unchanged. [Frozen results and provenance](../../../results/resnet_b8_control_overlap_20260915/README.md)
include the complete selected-signal waveforms and elapsed compute-region counts.

The following sections document earlier measured schedules and remain as
historical baselines; their cycle tables do not describe the new B8 suite.

The retained schedule is `isa/rv64uv/vmvm_resnet_overlap.c`. One source covers
Conv1–Conv5 and FinalFC. The runner selects each layer's dimensions and inputs.

| Layer | Accepted RTL total cycles |
|---|---:|
| Conv1 | 3,048,265 |
| Conv2 | 2,192,227 |
| Conv3 | 1,867,720 |
| Conv4 | 1,868,037 |
| Conv5 | 2,083,766 |
| FinalFC | 177,533 |

`test-riscvTests-vmvm_resnet_overlap` measures the complete layer, including
input/kernel transfers and final output DMA. It omits numerical checking.
`test-riscvTests-vmvm_resnet_overlap_check` validates every output in GVSOC against
an independent NumPy int32 reference after computation. All six checks passed:
1,180,136 outputs, zero mismatches. GVSOC cycles are separate from RTL cycles.

The accepted [results and provenance](../../../results/resnet_overlap_20260914/README.md)
include per-layer headers, timing/check ELFs, hashes, and successful run logs in
`results/resnet_overlap_20260914/release/`. These files preserve the measured runs.

From the GVSOC repository root:

```sh
source sourceme.sh
python3 spatz/hw/system/spatz_cluster/script/run_resnet_overlap.py --out results/resnet_new_run --mode prepare
python3 spatz/hw/system/spatz_cluster/script/run_resnet_overlap.py --out results/resnet_new_run --mode software
python3 spatz/hw/system/spatz_cluster/script/run_resnet_overlap.py --out results/resnet_new_run --mode rtl
```

Use a new output directory for reruns. `--layers Conv1,Conv2` selects a subset;
omitting it runs all six in order. RTL runs are serial. The default RTL simulator
is the retained `spatz_cluster.threaded.vlt` that produced the accepted table;
`--rtl-bin` selects another build.

Direct CMake builds select inputs with `RESNET_OVERLAP_HEADER` and default to the
accepted Conv1 header. Both targets disable compiler vectorization because the
assembly manages vector registers explicitly. The VFU writeback fix and runtime
allocator fix are required by this schedule.

Superseded VMVM variants, sample/profile targets, and their runners have been
removed from the active test tree. Historical results and requested VCDs remain
available in their existing results directories.

## Conv1 transition experiment

`vmvm_conv1_transition` and `vmvm_conv1_transition_check` are an isolated Conv1
update requested after finalizing the six-layer baseline. They precompute block
transitions, carry kernel prefetch across block/tile boundaries, and launch
completed-output DMA during the next block's computation. They use the fixed
accepted Conv1 header, independently of `RESNET_OVERLAP_HEADER`.
See [measurements and reproduction](../../../results/conv1_transition_overlap_20260914/README.md).
The accompanying DIMC queue-release change is under `tests/spatz-rtl`; accepted
cycle counts above refer to the prior RTL and are preserved as comparison data.

## Transition overlap for the remaining layers

`isa/rv64uv/vmvm_resnet_transition.c` extends the Conv1 scheduling work to
Conv2–Conv5 and FinalFC. Conv2 keeps the kernels resident. Conv3–Conv5 stage the
next K chunk or output-channel block into alternate TCDM buffers, and prefetch
its first 16 kernel registers during the current chunk's final eight rows.
Completed-output DMA starts during the next block. The odd 49-row Conv5 tile
uses the matching alternate result-register bank for its final eight rows.

FinalFC retains the accepted software schedule and uses the new early-done RTL.
Its 16-column overlap variants passed correctness but were slower in RTL.
The selected full timing is 177,021 cycles, compared with the accepted 177,533.
The runner selects `vmvm_resnet_overlap` for this one-row layer. Direct one-row
builds of `vmvm_resnet_transition` also reuse the accepted source.

The `vmvm_resnet_transition` and `vmvm_resnet_transition_check` targets use the
same frozen headers as the accepted baseline. Numerical checking remains outside
the measured layer interval. The runner defaults to the early queue-done RTL
simulator that was validated with the Conv1 change; architectural completion
still waits for the accepted VRF result write.

```sh
source sourceme.sh
python3 spatz/hw/system/spatz_cluster/script/run_resnet_transition.py --out results/resnet_transition_rerun --mode prepare
python3 spatz/hw/system/spatz_cluster/script/run_resnet_transition.py --out results/resnet_transition_rerun --mode software
python3 spatz/hw/system/spatz_cluster/script/run_resnet_transition.py --out results/resnet_transition_rerun --mode rtl
```

These commands select Conv2–Conv5 and FinalFC. Use `--layers` to select a subset;
`--mode rtl_check --layers FinalFC` additionally runs FinalFC's numerical checker
in RTL. Full-layer timing uses the timing ELF, with software validation recorded
separately. Per-layer sources, headers, ELF hashes, validation and RTL logs are
in [the transition results](../../../results/resnet_transition_20260915/README.md).
The accepted baseline and the separately measured Conv1 source remain preserved.
