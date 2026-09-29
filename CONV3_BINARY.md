# Verified Conv3 L6 RTL binaries

`conv3-l6-rtl-ubuntu22-x86_64.tar.gz` contains the archived Conv3 L6
`timing.elf`, `check.elf`, `prefix.elf`, the exact RTL simulator used for the
accepted timing run, its group plan, and the recorded manifest, JSON, and log.
No LLVM or RISC-V compiler is needed to run these existing binaries.

The accepted archived result is **1,240,889 total RTL cycles** and
**1,237,095 first-to-last DIMC-busy cycles**. The separate reported number
1,237,141 has no matching completed local run or binary. `timing.elf` is a
full timing-only RTL test; numerical correctness was checked separately in
software and with an RTL prefix. See `conv3/rtl.json` and `conv3/rtl.log` after
extraction.

On the server, from this checkout:

```sh
tar -xzf sfvqmmacc-ubuntu22-runtime-libs.tar.gz
tar -xzf conv3-l6-rtl-ubuntu22-x86_64.tar.gz
mkdir -p logs
./lib/ld-linux-x86-64.so.2 --library-path "$PWD/lib" ./conv3/spatz_cluster.ipu4_fpu1.vlt ./conv3/timing.elf +vmvm_profile_trace +progress=100000 "+group_plan=$PWD/conv3/full_groups.txt"
```

The archived full RTL run took about eight minutes on the source machine.
Success prints `VMVM_BENCH resnet_transition total_cycles=1240889
compute_cycles=1232478` and `[SUCCESS] Program finished successfully`.
The bundled loader is needed on this server because its system `glibc` and
`libstdc++` are older than the simulator requires.

Archive SHA-256:

```
e7a12876fd0d657a0ae6e84d3aab268b858522ef622349fb4c99eebe5c9780da  conv3-l6-rtl-ubuntu22-x86_64.tar.gz
```

Within the archive, `timing.elf` has SHA-256
`7c48bd727dae4005d0baa05d1048e65e7293da0c92691e3d7f4bc681d7fcd487`
and the simulator has SHA-256
`9032dddf68914f03b1091da5f7c01d682258ab86008e7d025a394ef49cce0179`.
