# SFVQMMACC on Spatz RTL

This branch contains the DIMC hardware and the three SFVQMMACC C tests. It is
based on Spatz commit `04a9859`; the repository's `main` branch is a newer
upstream snapshot and does not yet include this hardware.

From the repository root, install the project tools as described in `README.md`
(`make all`), then build the cluster simulator and software:

```sh
python3 -m pip install --user hjson jstyleson
cd hw/system/spatz_cluster
make sw.vlt CMAKE=cmake PYTHON=python3 CC=gcc CXX=g++ VLT_JOBS=4
```

Run the basic correctness test directly:

```sh
./bin/spatz_cluster.vlt sw/build/riscvTests/test-riscvTests-sfvqmmacc
```

The test succeeds when it prints `PASSED.` and `[SUCCESS] Program finished
successfully`, and the simulator exits with code 0. It checks the 16 result
rows against integer dot products and checks that the DIMC kernel CSR clears.

The other two test programs are:

```sh
./bin/spatz_cluster.vlt sw/build/riscvTests/test-riscvTests-sfvqmmacc_profile
./bin/spatz_cluster.vlt sw/build/riscvTests/test-riscvTests-sfvqmmacc_scenario_latency
```

The profile test reports labeled `DIMC_CASE_*` records; the scenario test
reports `DIMC_SCENARIO_PASS` on success. These take longer than the basic test.
