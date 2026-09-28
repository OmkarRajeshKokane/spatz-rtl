# DIMC instruction turnover regression

`tb_dimc_early_done.sv` drives a VFU with a modeled VRF and compares every
accepted result word against integer dot products. It holds writeback blocked
longer than an instruction and delays operand reads. It also verifies queue
release timing, response IDs and completion only after VRF write acceptance.

From this repository root, generate the Bender file list and build the isolated
top with an installed Verilator:

```sh
install/bender/bender script flist -t rtl -t spatz -t spatz_test -t snitch_test --define COMMON_CELLS_ASSERTS_OFF > /tmp/spatz-dimc-files
install/verilator/bin/verilator_bin --binary --timing --top-module tb_dimc_early_done -Wno-fatal -Wno-BLKANDNBLK -Wno-WIDTH -Wno-WIDTHCONCAT --unroll-count 1024 -j 2 --Mdir /tmp/dimc_early_done_unit -f /tmp/spatz-dimc-files hw/ip/spatz/test/tb_dimc_early_done.sv
/tmp/dimc_early_done_unit/Vtb_dimc_early_done +expect_early
```

`+debug` logs issue, queue release and result write events. Without
`+expect_early`, the test accepts the older last row queue release timing for
comparison with the saved pre-change VFU source.
