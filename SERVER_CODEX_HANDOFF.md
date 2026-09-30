# Handoff for Codex on the server

## Goal

Get the user's `sfvqmmacc` correctness test running on this server, report the
actual output and exit status, and then identify a practical way to build and
run the DIMC RTL source there without sudo. Do not report a prebuilt binary as
a fresh validation of current source.

## Repositories and paths

- Source: `https://github.com/OmkarRajeshKokane/spatz-rtl`, branch
  `dimc-sfvqmmacc` (current handoff base `5fcdf5a`), server checkout
  `/srv/home/omkar.kokane2/Desktop/DIMC/spatz-rtl-dimc`.
- Prebuilt smoke test: same repository, branch `dimc-sfvqmmacc-prebuilt`
  (current `bbeae2a`), server checkout
  `/srv/home/omkar.kokane2/Desktop/DIMC/spatz-rtl-test-prebuilt`.
- GVSoC checkout: `/srv/home/omkar.kokane2/Desktop/DIMC/gvsoc`.
- User has a Python environment at `/srv/home/omkar.kokane2/dimc/env` and no
  sudo access.

The source branch contains `hw/ip/spatz/src/spatz_DIMC.sv`, DIMC edits to the
Spatz RTL, and `sw/riscvTests/isa/rv64uv/sfvqmmacc*.c`. It is based on older
Spatz commit `04a9859`; GitHub `main` is newer upstream and does not have the
DIMC RTL. See `DIMC_SFVQMMACC.md` for source build commands.

## Immediate test to run

The prebuilt simulator and test ELF were run together successfully on the
local Ubuntu 22.04 machine. On this server, direct execution failed because
its system `glibc` and `libstdc++` are older. A runtime library archive was
added to the prebuilt branch but has not yet been tested on this server. Run:

```sh
cd /srv/home/omkar.kokane2/Desktop/DIMC/spatz-rtl-test-prebuilt
git pull --ff-only
tar -xzf sfvqmmacc-rtl-ubuntu22-x86_64.tar.gz
tar -xzf sfvqmmacc-ubuntu22-runtime-libs.tar.gz
mkdir -p logs
./lib/ld-linux-x86-64.so.2 --library-path "$PWD/lib" ./bin/spatz_cluster.vlt ./tests/test-riscvTests-sfvqmmacc
printf 'exit=%s\n' "$?"
```

Success prints `PASSED.` and `[SUCCESS] Program finished successfully` and
exits 0. If the bundled loader fails, inspect the actual OS and kernel and
resolve that incompatibility; do not assume the smoke test passed on server.
The prebuilt simulator was made on 2026-09-02 from a local development checkout
whose exact source revision was not recorded. Later RTL edits exist in the
source branch, so this only verifies the older prebuilt snapshot.

## Current source build state on server

The user interrupted `make bender toolchain` while it was cloning the enormous
LLVM repository (over six million objects). Therefore
`sw/toolchain/riscv-opcodes` and `install/riscv-gcc` are missing. Subsequent
`make sw/toolchain/riscv-opcodes/encoding.h` and `make sw.vlt` failed for those
missing prerequisites; the RTL simulator is not built there. The user did
successfully run `util/clustergen.py` and `util/generate_bootrom.py`, creating
`hw/system/spatz_cluster/src/generated/bootrom.sv` and related files. Bender
`E31` messages were emitted before generation because `util/Makefrag` invokes
Bender while parsing the Makefile.

For a fresh source build, first inspect available compiler and simulator
modules or existing toolchain installations on this server. Avoid another
full LLVM history clone unless it is truly necessary. Never use the root
`make all` target on this DIMC branch: its `update_opcodes` prerequisite
regenerates `hw/ip/snitch/src/riscv_instr.sv` and would erase the custom DIMC
opcode and CSR definitions. Preserve the user's local work and do not use
sudo.

## Custom LLVM source transfer

The local custom LLVM changes are now published on
`OmkarRajeshKokane/LLVM_toolchain_full` branch `dimc-llvm-v0.2`, commit
`e08b4fa4472205326227bc5ec719ff580c8c3e3f`. This Spatz branch also has
`patches/llvm-xdimc-v0.2.patch`, a small complete diff from its pinned upstream
LLVM revision `b494f2d8dde88723026db8ec16ac6c7ee1e140ca`, plus application
instructions in `LLVM_SERVER.md`. `llvm-tblgen -gen-instr-info` completed
successfully with both `SF_VQMMACC` and `SF_VQMMACC16` generated. The patch
moves LLVM **source** to the server via `git pull`; it does not provide a
rebuilt compiler. Check the state of any existing server LLVM checkout before
applying it, and avoid applying it twice over the fork's prior DIMC commit.
