// Copyright 2026 University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "vector_macros.h"

#include <stdint.h>

#define DIMC_INSN(vd, vs1, ci, kernel_group, imm, funct3) \
  (((0x2e) << 26) | ((imm) << 25) | ((kernel_group) << 23) | \
   ((ci) << 20) | ((vs1) << 15) | ((funct3) << 12) | ((vd) << 7) | 0x77)

#define STR_HELPER(x) #x
#define STR(x) STR_HELPER(x)

#define SF_VQMMACC(vd, kernel_group, vs1, ci, imm) \
  asm volatile(".word " STR(DIMC_INSN(vd, vs1, ci, kernel_group, imm, 0)) \
               ::: "v16", "memory")

static inline uint64_t read_cycle(void) {
  uint64_t cycles;
  asm volatile("rdcycle %0" : "=r"(cycles));
  return cycles;
}

static void load_kernel_rows(uint8_t *kernel) {
  asm volatile("vle8.v v0, (%0)" :: "r"(kernel + 0 * 64) : "memory");
  asm volatile("vle8.v v1, (%0)" :: "r"(kernel + 1 * 64) : "memory");
  asm volatile("vle8.v v2, (%0)" :: "r"(kernel + 2 * 64) : "memory");
  asm volatile("vle8.v v3, (%0)" :: "r"(kernel + 3 * 64) : "memory");
  asm volatile("vle8.v v4, (%0)" :: "r"(kernel + 4 * 64) : "memory");
  asm volatile("vle8.v v5, (%0)" :: "r"(kernel + 5 * 64) : "memory");
  asm volatile("vle8.v v6, (%0)" :: "r"(kernel + 6 * 64) : "memory");
  asm volatile("vle8.v v7, (%0)" :: "r"(kernel + 7 * 64) : "memory");
  asm volatile("vle8.v v8, (%0)" :: "r"(kernel + 8 * 64) : "memory");
  asm volatile("vle8.v v9, (%0)" :: "r"(kernel + 9 * 64) : "memory");
  asm volatile("vle8.v v10, (%0)" :: "r"(kernel + 10 * 64) : "memory");
  asm volatile("vle8.v v11, (%0)" :: "r"(kernel + 11 * 64) : "memory");
  asm volatile("vle8.v v12, (%0)" :: "r"(kernel + 12 * 64) : "memory");
  asm volatile("vle8.v v13, (%0)" :: "r"(kernel + 13 * 64) : "memory");
  asm volatile("vle8.v v14, (%0)" :: "r"(kernel + 14 * 64) : "memory");
  asm volatile("vle8.v v15, (%0)" :: "r"(kernel + 15 * 64) : "memory");
}

static void set_dimc_csrs(uint32_t kernel_load, uint32_t feature_reuse,
                          uint32_t compute_reuse) {
  asm volatile("csrw 0x7D3, %0" :: "r"(kernel_load) : "memory");
  asm volatile("csrw 0x7D4, %0" :: "r"(feature_reuse) : "memory");
  asm volatile("csrw 0x7D5, %0" :: "r"(compute_reuse) : "memory");
}

static void run_case(const char *name, uint32_t kernel_load, uint32_t feature_reuse,
                     uint32_t compute_reuse) {
  uint32_t vl;
  set_dimc_csrs(kernel_load, feature_reuse, compute_reuse);
  asm volatile("vsetvli %0, %1, e32, m1, ta, ma" : "=r"(vl) : "r"(16));
  printf("DIMC_CASE_BEGIN %s type=sf.vqmmacc kernel=%u feature_reuse=%u compute_reuse=%u\n",
         name, kernel_load, feature_reuse, compute_reuse);

  uint64_t start = read_cycle();
  SF_VQMMACC(16, 0, 31, 3, 0);
  uint64_t end = read_cycle();

  printf("DIMC_CASE_END %s rdcycle=%lu\n", name, (unsigned long)(end - start));
}

void TEST_CASE1(void) {
  uint8_t *feature = (uint8_t *)snrt_l1alloc(64);
  uint8_t *kernel = (uint8_t *)snrt_l1alloc(16 * 64);
  if (feature == 0 || kernel == 0) {
    printf("sf.vqmmacc profile allocation failed\n");
    num_failed++;
    return;
  }

  for (uint32_t i = 0; i < 64; i++) {
    feature[i] = (uint8_t)(i + 1);
  }
  for (uint32_t row = 0; row < 16; row++) {
    for (uint32_t col = 0; col < 64; col++) {
      kernel[row * 64 + col] = (uint8_t)(row + 1 + (col & 1));
    }
  }

  uint32_t vl;
  asm volatile("vsetvli %0, %1, e8, m1, ta, ma" : "=r"(vl) : "r"(64));
  load_kernel_rows(kernel);
  asm volatile("vle8.v v31, (%0)" :: "r"(feature) : "v31", "memory");

  run_case("vqmmacc_full_no_reuse", 1, 0, 0);
  run_case("vqmmacc_kernel_reuse_only", 0, 0, 0);
  run_case("vqmmacc_kernel_compute_reuse", 0, 0, 1);
  run_case("vqmmacc_kernel_feature_reuse", 0, 1, 0);
  run_case("vqmmacc_all_reuse_csrs", 0, 1, 1);

  printf("PASSED.\n");
}

int main(void) {
  INIT_CHECK();
  enable_vec();

  TEST_CASE1();

  EXIT_CHECK();
}
