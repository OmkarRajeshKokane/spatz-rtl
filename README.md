# Prebuilt SFVQMMACC RTL smoke test

This branch holds a prebuilt Ubuntu 22.04 x86-64 Spatz RTL simulator and one
RISC-V SFVQMMACC test executable. It lets a server run the basic test without
building LLVM, GCC, Verilator, or Bender.

The simulator was built in the local DIMC development checkout on 2026-09-02.
The exact source revision used for that binary was not recorded. This archive
was unpacked and run on Ubuntu 22.04 on 2026-09-29; it printed `PASSED.` and
`[SUCCESS] Program finished successfully` and exited with status 0. It does
not validate a fresh build of the current `dimc-sfvqmmacc` source branch.

```sh
tar -xzf sfvqmmacc-rtl-ubuntu22-x86_64.tar.gz
mkdir -p logs
./bin/spatz_cluster.vlt ./tests/test-riscvTests-sfvqmmacc
```

Archive SHA-256:

```
96a9fc9af628161427d8de01131ac39fa49e90bcbe68a09ec0a349dbb16e2207  sfvqmmacc-rtl-ubuntu22-x86_64.tar.gz
```

The source and build guide are on the `dimc-sfvqmmacc` branch of this
repository.
