# DIMC LLVM changes for the server

The complete custom LLVM source is published in
`OmkarRajeshKokane/LLVM_toolchain_full`, branch `dimc-llvm-v0.2`, commit
`e08b4fa4472205326227bc5ec719ff580c8c3e3f`. It contains the prior DIMC
instruction definitions plus the later `xdimc` version 0.2 and
`sf.vqmmacc16` additions. The fork's `main` branch remains at the earlier
DIMC commit `f3f2c73aa366640dd74f92fc0b24da25a1df5a29`.

For a small transfer without cloning LLVM, `patches/llvm-xdimc-v0.2.patch`
contains all DIMC changes relative to the Spatz-pinned upstream LLVM commit
`b494f2d8dde88723026db8ec16ac6c7ee1e140ca`. The patch was checked with
`git apply --check` against that clean commit. SHA-256 of the patch is
`4a5d21e79dd362233f431f8dc5e202f295b102b30e826ffa3227419cee022cf6`.

On the server, update this Spatz checkout to receive the patch:

```sh
cd /srv/home/omkar.kokane2/Desktop/DIMC/spatz-rtl-dimc
git pull --ff-only
sha256sum patches/llvm-xdimc-v0.2.patch
```

If a **clean, complete** LLVM source checkout at the exact upstream commit
`b494f2d8dde88723026db8ec16ac6c7ee1e140ca` is available, apply it there:

```sh
llvm_src=/path/to/llvm-project
git -C "$llvm_src" rev-parse HEAD
git -C "$llvm_src" apply --check /srv/home/omkar.kokane2/Desktop/DIMC/spatz-rtl-dimc/patches/llvm-xdimc-v0.2.patch
git -C "$llvm_src" apply /srv/home/omkar.kokane2/Desktop/DIMC/spatz-rtl-dimc/patches/llvm-xdimc-v0.2.patch
```

If LLVM is already at the fork's `f3f2c73a` commit, use the fork's
`dimc-llvm-v0.2` branch or apply only the later two-file diff; do not apply
the full patch twice. If the interrupted clone on the server is incomplete,
inspect it before using it as a patch target.

This transfers **source changes**. It does not install a rebuilt `clang` or
`lld` binary. The DIMC C tests that encode `sf.vqmmacc` with `.word` do not
need assembler recognition of that mnemonic, but building new RISC-V test
ELFs still needs an appropriate cross compiler and runtime. The previously
published prebuilt test and Conv3 ELF bundles can be run without LLVM.
