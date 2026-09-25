// SPDX-License-Identifier: SHL-0.51
// Keep the Conv3 target tied to its validated matrix and complete B8 groups.
_Static_assert(OUT_ROWS == 784 && FEAT_COLS == 1152 && OUT_COLS == 128,
               "The Conv3 target requires the frozen Conv3 matrix");
_Static_assert(RESNET_RUN_ROWS % 8 == 0 && TILE_ROWS % 8 == 0,
               "The Conv3 target requires complete B8 groups");
#include "vmvm_resnet_b8.h"
