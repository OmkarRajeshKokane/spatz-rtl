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

static void load_kernel_rows(uint8_t *kernel) {
  asm volatile("vle8.v v0, (%0)" :: "r"(kernel + 0 * 128) : "v0", "memory");
  asm volatile("vle8.v v1, (%0)" :: "r"(kernel + 1 * 128) : "v1", "memory");
  asm volatile("vle8.v v2, (%0)" :: "r"(kernel + 2 * 128) : "v2", "memory");
  asm volatile("vle8.v v3, (%0)" :: "r"(kernel + 3 * 128) : "v3", "memory");
  asm volatile("vle8.v v4, (%0)" :: "r"(kernel + 4 * 128) : "v4", "memory");
  asm volatile("vle8.v v5, (%0)" :: "r"(kernel + 5 * 128) : "v5", "memory");
  asm volatile("vle8.v v6, (%0)" :: "r"(kernel + 6 * 128) : "v6", "memory");
  asm volatile("vle8.v v7, (%0)" :: "r"(kernel + 7 * 128) : "v7", "memory");
}

static void set_dimc_csrs(uint32_t kernel_load, uint32_t feature_reuse,
                          uint32_t compute_reuse) {
  asm volatile("csrw 0x7D3, %0" :: "r"(kernel_load) : "memory");
  asm volatile("csrw 0x7D4, %0" :: "r"(feature_reuse) : "memory");
  asm volatile("csrw 0x7D5, %0" :: "r"(compute_reuse) : "memory");
}

static void run_case(uint32_t case_id, uint32_t kernel_load,
                     uint32_t feature_reuse, uint32_t compute_reuse,
                     uint32_t *result) {
  uint32_t vl;
  asm volatile("vsetvli %0, %1, e8, m1, ta, ma"
               : "=r"(vl) : "r"(128));
  set_dimc_csrs(kernel_load, feature_reuse, compute_reuse);
  printf("DIMC_SCENARIO case=%u kernel_load=%u feature_load=%u "
         "feature_reuse=%u compute_reuse=%u vl=%u\n",
         case_id, kernel_load, !feature_reuse, feature_reuse,
         compute_reuse, vl);

  SF_VQMMACC(16, 0, 31, 3, 0);

  asm volatile("vsetvli %0, %1, e32, m1, ta, ma"
               : "=r"(vl) : "r"(8));
  asm volatile("vse32.v v16, (%0)" :: "r"(result + case_id * 8) : "memory");
}

void TEST_CASE1(void) {
  uint8_t *feature = (uint8_t *)snrt_l1alloc(128);
  uint8_t *kernel = (uint8_t *)snrt_l1alloc(8 * 128);
  uint32_t *result = (uint32_t *)snrt_l1alloc(8 * 8 * sizeof(uint32_t));
  if (feature == 0 || kernel == 0 || result == 0) {
    printf("sf.vqmmacc scenario allocation failed\n");
    num_failed++;
    return;
  }

  for (uint32_t col = 0; col < 128; col++) {
    feature[col] = 1;
  }
  for (uint32_t row = 0; row < 8; row++) {
    for (uint32_t col = 0; col < 128; col++) {
      kernel[row * 128 + col] = (uint8_t)(row + 1);
    }
  }

  uint32_t vl;
  asm volatile("vsetvli %0, %1, e8, m1, ta, ma"
               : "=r"(vl) : "r"(128));
  load_kernel_rows(kernel);
  asm volatile("vle8.v v31, (%0)" :: "r"(feature) : "v31", "memory");

  uint32_t case_id = 0;
  for (uint32_t compute_reuse = 0; compute_reuse <= 1; compute_reuse++) {
    run_case(case_id++, 1, 0, compute_reuse, result);
    run_case(case_id++, 1, 1, compute_reuse, result);
    run_case(case_id++, 0, 0, compute_reuse, result);
    run_case(case_id++, 0, 1, compute_reuse, result);
  }

  uint32_t errors = 0;
  for (uint32_t scenario = 0; scenario < 8; scenario++) {
    for (uint32_t row = 0; row < 8; row++) {
      uint32_t expected = 128 * (row + 1);
      uint32_t got = result[scenario * 8 + row];
      if (got != expected) {
        printf("DIMC_SCENARIO_MISMATCH case=%u row=%u got=%u expected=%u\n",
               scenario, row, got, expected);
        errors++;
      }
    }
  }

  if (errors == 0) {
    printf("DIMC_SCENARIO_PASS\n");
  } else {
    printf("DIMC_SCENARIO_FAIL errors=%u\n", errors);
    num_failed++;
  }
}

int main(void) {
  INIT_CHECK();
  enable_vec();

  TEST_CASE1();

  EXIT_CHECK();
}
