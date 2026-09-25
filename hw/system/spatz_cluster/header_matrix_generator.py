import argparse
import numpy as np
import sys

def pad_k_dimension(feature, kernel, multiple):
    logical_k = feature.shape[1]
    if multiple <= 1:
        return feature, kernel, logical_k

    padded_k = ((logical_k + multiple - 1) // multiple) * multiple
    if padded_k == logical_k:
        return feature, kernel, logical_k

    padded_feature = np.zeros((feature.shape[0], padded_k), dtype=feature.dtype)
    padded_feature[:, :logical_k] = feature

    padded_kernel = np.zeros((padded_k, kernel.shape[1]), dtype=kernel.dtype)
    padded_kernel[:logical_k, :] = kernel

    return padded_feature, padded_kernel, logical_k


def write_c_header(feature, kernel, output, filename, arrays_only=False, bench_case=0,
                   tile_rows=0, logical_k=None, loop_profile=False):
    with open(filename, 'w') as f:

        f.write("#ifndef GENERATED_MATRICES_H\n")
        f.write("#define GENERATED_MATRICES_H\n\n")
        f.write("#include <stdint.h>\n\n")

        if logical_k is None:
            logical_k = feature.shape[1]

        f.write(f"#define VMVM_LOGICAL_K {logical_k}\n")
        f.write(f"#define VMVM_PADDED_K {feature.shape[1]}\n")
        f.write(f"#define FEAT_ROWS {feature.shape[0]}\n")
        f.write(f"#define FEAT_COLS {feature.shape[1]}\n")
        f.write(f"#define KERN_ROWS {kernel.shape[0]}\n")
        f.write(f"#define KERN_COLS {kernel.shape[1]}\n")
        f.write(f"#define OUT_ROWS {output.shape[0]}\n")
        f.write(f"#define OUT_COLS {output.shape[1]}\n")
        f.write(f"#define VMVM_BENCH_CASE {bench_case}\n")
        f.write(f"#define VMVM_TILE_ROWS_OVERRIDE {tile_rows}\n\n")
        f.write(f"#define VMVM_LOOP_PROFILE {1 if loop_profile else 0}\n\n")

        if not arrays_only:
            for r in range(feature.shape[0]):
                row = ", ".join(map(str, feature[r]))
                f.write(f"#define FEATURE_ROW_{r} {row}\n")

            f.write("\n")

            for r in range(kernel.shape[0]):
                row = ", ".join(map(str, kernel[r]))
                f.write(f"#define KERNEL_ROW_{r} {row}\n")

            f.write("\n")

            for r in range(output.shape[0]):
                row = ", ".join(map(str, output[r]))
                f.write(f"#define OUTPUT_ROW_{r} {row}\n")

        f.write('static uint8_t data_A [FEAT_ROWS][FEAT_COLS]= {\n')
        for r in range(feature.shape[0]):
            f.write('{')
            row = ", ".join(map(str, feature[r]))
            f.write(f"{row}")
            f.write('},\n')
        f.write('};\n')

        f.write('static uint8_t data_B [KERN_ROWS][KERN_COLS]= {\n')
        for r in range(kernel.shape[0]):
            f.write('{')
            row = ", ".join(map(str, kernel[r]))
            f.write(f"{row}")
            f.write('},\n')
        f.write('};\n')

        if not arrays_only:
            rows, cols = feature.shape

            f.write("static uint8_t serialized_A[] = {\n")

            for r in range(rows):

                row_vals = []
                for i in feature[r]:
                    row_vals.append(str(i))

                f.write("    " + ", ".join(row_vals) + ",\n")

            f.write("};\n")

        rows, cols = output.shape

        f.write("static uint32_t serialized_C[] = {\n")

        for col_block in range(0, cols, 16):
            for r in range(rows):
                row_vals = []

                for c in range(col_block, min(col_block + 16, cols)):
                    row_vals.append(str(output[r][c]))

                f.write("    " + ", ".join(row_vals) + ",\n")

        f.write("};\n")

        if arrays_only:
            f.write("\n#endif\n")
            return


        f.write('void load_feature_data(int f,int sel_vrf){\n')
        f.write('switch(f){\n')


        for r in range(feature.shape[0]):  # data in Matrix
            row = ", ".join(map(str, feature[r]))
            f.write(f"case {r}:\n")
            f.write('switch(sel_vrf){\n')
            for v in range(32): # 32 is no. of vectors in VRF.
                row = ", ".join(map(str, feature[r]))
                f.write(f"case {v}:VLOAD_8(v{v}, {row});\n")
                f.write(f"break;\n")
            f.write('}\n')
            f.write(f"break;\n")
        f.write('}\n')
        f.write('}\n')


        f.write('void load_kernal_data(int f,int sel_vrf_chunk){\n')
        f.write('switch(f){\n')
        for r in range(int(kernel.shape[0]/8)):
            f.write(f"case {r}:")
            f.write('switch(sel_vrf_chunk){\n')

            for v in range(4):
                f.write(f"case {v}:")
                for j in range(8) :
                    row = ", ".join(map(str, kernel[r*8+j]))
                    f.write(f"VLOAD_8(v{v*8+j}, {row});\n")
                f.write(f"break;\n")
            f.write('}\n')
            f.write(f"break;\n")
        f.write('}\n')
        f.write('}\n')




        f.write("#define LOAD_FEATURE_ROW(ROW, VREG) \\\n")
        f.write("    VLOAD_8(VREG, FEATURE_ROW_##ROW)\n\n")

        f.write("#define LOAD_KERNEL_ROW(ROW, VREG) \\\n")
        f.write("    VLOAD_8(VREG, KERNEL_ROW_##ROW)\n\n")

        f.write("#define LOAD_OUTPUT_ROW(ROW, VREG) \\\n")
        f.write("    VLOAD_8(VREG, OUTPUT_ROW_##ROW)\n\n")


        f.write("\n#endif\n")


def main():
    parser = argparse.ArgumentParser(description="Random Matrix Generator")

    parser.add_argument('-f', nargs=2, type=int,
                        metavar=('F_ROWS', 'F_COLS'),
                        required=True)

    parser.add_argument('-k', nargs=2, type=int,
                        metavar=('K_ROWS', 'K_COLS'),
                        required=True)
    parser.add_argument('--arrays-only', action='store_true',
                        help='emit only data_A, data_B, and serialized_C for tiled tests')
    parser.add_argument('--bench-case', type=int, choices=(0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21), default=0,
                        help='select instruction test: 0=sf.vqmmacc initopt, 1=outer-preload, 2=output2d, 3=outer-preload+output2d, 4=resident2k, 5=resident2k+output2d, 6=auto-best sf.vqmmacc, 7=sf.vqmmacc16 kernel-stationary fallback, 16=force sf.vqmmacc16 tiled, 17=force sf.vqmmacc16 kernel-stationary, 18=force auto-best sf.vqmmacc16, 19=force sf.vqmmacc16 resident-kernel tiled, 20=force sf.vqmmacc 16-column kernel-stationary, 21=force sf.vqmmacc 8-column register-accumulator kernel-stationary; optimization is selected at runtime')
    parser.add_argument('--tile-rows', type=int, default=0,
                        help='override vmvm tile rows for benchmark sweeps; 0 keeps auto sizing')
    parser.add_argument('--pad-k-to', type=int, default=128,
                        help='zero-pad the physical K dimension to this multiple; use 1 to disable')
    parser.add_argument('--loop-profile', action='store_true',
                        help='enable loop-level cycle counters in the generated VMVM test')

    args = parser.parse_args()

    f_rows, f_cols = args.f
    k_rows, k_cols = args.k

    if f_cols != k_rows:
        print("Error: Feature columns must match Kernel rows.")
        sys.exit(1)
    if args.pad_k_to < 1:
        print("Error: --pad-k-to must be >= 1.")
        sys.exit(1)

    # Generate int8 inputs
    feature_matrix = np.random.randint(0, 9, size=(f_rows, f_cols), dtype=np.int8)
    kernel_matrix  = np.random.randint(0, 9, size=(k_rows, k_cols), dtype=np.int8)

    # Compute output in int32 to avoid overflow
    output_matrix = np.matmul(
        feature_matrix.astype(np.int32),
        kernel_matrix.astype(np.int32)
    )
    feature_matrix, kernel_matrix, logical_k = pad_k_dimension(
        feature_matrix, kernel_matrix, args.pad_k_to
    )
    kernel_matrix=kernel_matrix.T
    header_file = "generated_matrices.h"

    write_c_header(feature_matrix, kernel_matrix, output_matrix, header_file,
                   arrays_only=args.arrays_only, bench_case=args.bench_case,
                   tile_rows=args.tile_rows, logical_k=logical_k,
                   loop_profile=args.loop_profile)

    print("Header generated successfully:")
    print(f"  -> {header_file}")
    if feature_matrix.shape[1] != logical_k:
        print(f"  -> logical K {logical_k} padded to {feature_matrix.shape[1]}")


if __name__ == "__main__":
    main()
