// SPDX-License-Identifier: SHL-0.51
// Conv3 K-chunk handoff. v0-v15 hold the prefetched kernel, v31 the next
// feature. Previous results v16-v29 survive until the stores below read them.
// v30/v31 were already stored in the preceding B8 addition phase.
#define C3_STORE_PAIR(L,H) \
    "vse32.v v" S(L) ", (%[low])\n" \
    "vse32.v v" S(H) ", (%[high])\n" \
    "addi %[low], %[low], 64\n" \
    "addi %[high], %[high], 64\n"
#define C3_KERNEL(V,OFF) \
    "addi %[addr], %[kernel], " S(OFF) "\n" \
    "vle8.v v" S(V) ", (%[addr])\n"
#define C3_E8 "li %[width], 128\n" "vsetvli zero, %[width], e8, m1, ta, ma\n"
#define C3_E32 "li %[width], 16\n" "vsetvli zero, %[width], e32, m1, ta, ma\n"

#define C3_BOOTSTRAP_BODY \
"sf.vqmmacc v0,0,v31,3,0\n" \
"csrw 0x7d4, %[one]\n" \
"sf.vqmmacc v0,1,v31,7,0\n" \
"beqz %[low], 1f\n" \
C3_E32 \
C3_STORE_PAIR(16,17) C3_STORE_PAIR(18,19) \
C3_STORE_PAIR(20,21) C3_STORE_PAIR(22,23) \
"1:\n" \
C3_E8 \
C3_KERNEL(16,0) C3_KERNEL(17,128) C3_KERNEL(18,256) C3_KERNEL(19,384) \
C3_KERNEL(20,512) C3_KERNEL(21,640) C3_KERNEL(22,768) C3_KERNEL(23,896) \
"vle8.v v2, (%[feature])\n" \
/* Kernel-load CSR auto-clears after each pair of instructions. */ \
"csrw 0x7d3, %[one]\n" \
"csrw 0x7d4, zero\n" \
"sf.vqmmacc v1,2,v2,3,0\n" \
"beqz %[low], 2f\n" \
C3_E32 \
C3_STORE_PAIR(24,25) C3_STORE_PAIR(26,27) C3_STORE_PAIR(28,29) \
"2:\n" \
C3_E8 \
C3_KERNEL(24,1024) C3_KERNEL(25,1152) C3_KERNEL(26,1280) C3_KERNEL(27,1408) \
C3_KERNEL(28,1536) C3_KERNEL(29,1664) C3_KERNEL(30,1792) C3_KERNEL(31,1920) \
"csrw 0x7d4, %[one]\n" \
"sf.vqmmacc v1,3,v2,7,0\n" \
"csrw 0x7d3, zero\n" \
"csrw 0x7d4, zero\n"

static __attribute__((always_inline)) inline void conv3_bootstrap_prepared(
    const uint8_t *kernel, const uint8_t *feature, int prefetched,
    uint32_t *low, uint32_t *high, int feature_ready) {
    uint32_t *drain=low;
    E8(); CSR(0x7d4,0); CSR(0x7d3,1);
    if (!prefetched) {
        LD8(0,kernel+0*128); LD8(1,kernel+1*128);
        LD8(2,kernel+2*128); LD8(3,kernel+3*128);
        LD8(4,kernel+4*128); LD8(5,kernel+5*128);
        LD8(6,kernel+6*128); LD8(7,kernel+7*128);
        LD8(8,kernel+8*128); LD8(9,kernel+9*128);
        LD8(10,kernel+10*128); LD8(11,kernel+11*128);
        LD8(12,kernel+12*128); LD8(13,kernel+13*128);
        LD8(14,kernel+14*128); LD8(15,kernel+15*128);
    }
    if (!feature_ready) LD8(31,feature);
    uint32_t addr, width;
    // Keep the handoff in one assembly block: scalar stack loads between
    // vector stores would force Snitch's global vector-store drain interlock.
    // VLSU and DIMC scoreboards retain each instruction's E8/E32 configuration
    // and protect result-store -> kernel-load WAR dependencies.
    asm volatile(
        C3_BOOTSTRAP_BODY
        : [low] "+&r"(low), [high] "+&r"(high),
          [addr] "=&r"(addr), [width] "=&r"(width)
        : [kernel] "r"(kernel+16*128), [feature] "r"(feature), [one] "r"(1)
        : "memory");
    // A completed output block may now be published to output DMA. This
    // barrier is after new DIMC work was queued, not before its first launch.
    if (drain) asm volatile("lw zero, 0(%0)" :: "r"(drain) : "memory");
}

// Only the last complete B8 group carries stores across a chunk boundary.
// A final layer chunk and an eight-row bootstrap-only tile flush normally.
#define C3_PREPARE_CARRY(TAIL) \
    const uint8_t *c3_next_feature=(TAIL) && next_kernel ? next->features : 0; \
    asm volatile("" :: "r"(c3_next_feature), "r"(store_low), "r"(store_high))
#define C3_FREE_FEATURE_REGISTER() do { \
    if (next_kernel) { \
        uint32_t width; \
        asm volatile( \
            "vse32.v v30, (%[low])\n" \
            "vse32.v v31, (%[high])\n" \
            C3_E8 \
            "vle8.v v31, (%[feature])\n" \
            C3_E32 \
            : [width] "=&r"(width) \
            : [low] "r"(out+(rows-1)*16), \
              [high] "r"(out+(2*rows-1)*16), [feature] "r"(c3_next_feature) \
            : "memory"); \
    } \
} while (0)

// Keep the last additions, kernel prefetch, and next launch together. All
// operands are prepared before the B8 completion wait, so no scalar metadata
// reload or loop branch can interrupt this handoff.
#define C3_LOW_KERNEL(V,OFF) \
    "addi %[addr], %[kernel_low], " S(OFF) "\n" \
    "vle8.v v" S(V) ", (%[addr])\n"
#define C3_ADD_PREFETCH(L,H,OL,OH,LOFF,HOFF) \
    C3_E32 \
    "vadd.vv v" S(H) ", v" S(H) ", v" S(OH) "\n" \
    "vadd.vv v" S(L) ", v" S(L) ", v" S(OL) "\n" \
    C3_E8 C3_LOW_KERNEL(OL,LOFF) C3_LOW_KERNEL(OH,HOFF)

static __attribute__((always_inline)) inline void conv3_finish_b8(
    const uint8_t *kernel, const uint8_t *feature,
    uint32_t *low, uint32_t *high) {
    uint32_t *drain=low;
    uint32_t addr,width;
    asm volatile(
        C3_ADD_PREFETCH(30,31,14,15,1792,1920)
        C3_E32
        "addi %[addr], %[low], 448\n"
        "vse32.v v30, (%[addr])\n"
        "addi %[addr], %[high], 448\n"
        "vse32.v v31, (%[addr])\n"
        C3_E8
        "vle8.v v31, (%[feature])\n"
        C3_ADD_PREFETCH(28,29,12,13,1536,1664)
        C3_ADD_PREFETCH(26,27,10,11,1280,1408)
        C3_ADD_PREFETCH(24,25,8,9,1024,1152)
        C3_ADD_PREFETCH(22,23,6,7,768,896)
        C3_ADD_PREFETCH(20,21,4,5,512,640)
        C3_ADD_PREFETCH(18,19,2,3,256,384)
        C3_ADD_PREFETCH(16,17,0,1,0,128)
        "csrw 0x7d4, zero\n"
        "csrw 0x7d3, %[one]\n"
        C3_BOOTSTRAP_BODY
        : [low] "+&r"(low), [high] "+&r"(high),
          [addr] "=&r"(addr), [width] "=&r"(width)
        : [kernel] "r"(kernel+16*128), [kernel_low] "r"(kernel),
          [feature] "r"(feature), [one] "r"(1)
        : "memory");
    asm volatile("lw zero, 0(%0)" :: "r"(drain) : "memory");
}
#define C3_TRY_FINISH(TAIL) ((TAIL) && next_kernel ? \
    (conv3_finish_b8(next_kernel,c3_next_feature,store_low,store_high), \
     pipeline.feature_ready=2, 1) : 0)
