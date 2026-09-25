// SPDX-License-Identifier: SHL-0.51
// Conv1 B8: prepare block transitions and DMA while DIMC is computing.
#include <stdint.h>
#include <stdio.h>
#include <printf.h>
#include "snrt.h"
#include "team.h"
#ifndef RESNET_OVERLAP_HEADER
#error "Build with the fixed Conv1 input header"
#endif
#include RESNET_OVERLAP_HEADER
#ifndef RESNET_OVERLAP_CHECK
#define RESNET_OVERLAP_CHECK 0
#endif
_Static_assert(OUT_ROWS == 12544 && FEAT_COLS == 256 && OUT_COLS == 64 && VMVM_LOGICAL_K == 147,
               "This schedule is specialized for Conv1");
#define INPUT_STRIDE 256
#define TILE_ROWS 136
#define S_(x) #x
#define S(x) S_(x)
#define LD8(v,p) asm volatile("vle8.v v" S(v) ", (%0)" :: "r"(p) : "memory")
#define LD32(v,p) asm volatile("vle32.v v" S(v) ", (%0)" :: "r"(p) : "memory")
#define ST32(v,p) asm volatile("vse32.v v" S(v) ", (%0)" :: "r"(p) : "memory")
#define ADD(v,a) asm volatile("vadd.vv v" S(v) ", v" S(v) ", v" S(a) ::: "memory")
#define SF(v,g,f,c) asm volatile("sf.vqmmacc v" S(v) "," S(g) ",v" S(f) "," S(c) ",0" ::: "memory")
#define CSR(a,v) asm volatile("csrw " S(a) ", %0" :: "r"((uint32_t)(v)) : "memory")
#define E8() asm volatile("vsetvli zero,%0,e8,m1,ta,ma" :: "r"(128) : "memory")
#define E32() asm volatile("vsetvli zero,%0,e32,m1,ta,ma" :: "r"(16) : "memory")
static inline uint32_t cycles(void) {
    uint32_t value;
    asm volatile("rdcycle %0" : "=r"(value));
    return value;
}


typedef struct {
    const uint8_t *features, *kernel;
    uint32_t *out;
    int rb, cb, rows, ab, ob, valid;
} block_t;

typedef struct {
    uint32_t *dst[2], *src[2];
    int bytes, valid;
} output_dma_t;

static struct {
    uint8_t *a[2], *kernels;
    uint32_t *out[2], *result;
    output_dma_t pending;
} pipeline;

static void launch_output(void) {
    output_dma_t *d = &pipeline.pending;
    if (!d->valid) return;
    // Each 16-column half is contiguous at both ends: the old 2D transfer
    // (64-byte row and 64-byte strides) is exactly this 1D transfer.
    snrt_dma_start_1d(d->dst[0],d->src[0],d->bytes);
    snrt_dma_start_1d(d->dst[1],d->src[1],d->bytes);
    d->valid = 0;
}

static void launch_transfers(const block_t *block) {
    launch_output();
    if (block->cb == 0 && block->rb + block->rows < OUT_ROWS) {
        int rb = block->rb + block->rows;
        int rows = OUT_ROWS-rb; if (rows > TILE_ROWS) rows=TILE_ROWS;
        int bank = block->ab ^ 1;
        snrt_dma_start_1d(
            pipeline.a[bank],&data_A[rb][0],rows*INPUT_STRIDE);
    }
}

// Called during the last eight rows of the final K chunk. Resolve addresses,
// tile bounds, buffer ownership and output DMA parameters before the boundary.
static void prepare_transition(const block_t *block, block_t *next) {
    int rb=block->rb, cb=block->cb+32, ab=block->ab;
    if (cb == OUT_COLS) { cb=0; rb+=block->rows; ab^=1; }
    next->valid = rb < OUT_ROWS;
    if (next->valid) {
        int rows=OUT_ROWS-rb; if (rows > TILE_ROWS) rows=TILE_ROWS;
        int ob=block->ob ^ 1;
        // Retire previously issued input/output transfers before buffer reuse.
        // This poll happens eight rows early. The current output is not queued
        // yet, so it remains available for the current DIMC result stores.
        // Use busy polling, whose semantics agree in RTL and GVSOC.
        snrt_dma_wait_all();
        *next=(block_t){pipeline.a[ab],pipeline.kernels+cb*INPUT_STRIDE,
                        pipeline.out[ob],rb,cb,rows,ab,ob,1};
    }
    output_dma_t *d=&pipeline.pending;
    d->dst[0]=pipeline.result+block->cb*OUT_ROWS+block->rb*16;
    d->dst[1]=d->dst[0]+16*OUT_ROWS;
    d->src[0]=block->out;
    d->src[1]=block->out+block->rows*16;
    d->bytes=block->rows*64;
    // The descriptor becomes runnable only after final vector stores drain.
    d->valid=0;
}

// v0-v15: next kernel first half, only after bootstrap output is stored.
// v16/v17 and v18/v19: alternate current/previous row results.
// v20/v21: old partial sums; v30/v31: alternating lookahead features.
// Kernel bootstrap temporarily uses all registers; no live result crosses it.
static __attribute__((always_inline)) inline void bootstrap(
    const uint8_t *kernel, const uint8_t *feature, int prefetched, const block_t *block, int chunk) {
    E8(); CSR(0x7d4,0); CSR(0x7d3,1);
    if (!prefetched) {
        LD8(0,kernel+0*INPUT_STRIDE);
        LD8(1,kernel+1*INPUT_STRIDE);
        LD8(2,kernel+2*INPUT_STRIDE);
        LD8(3,kernel+3*INPUT_STRIDE);
        LD8(4,kernel+4*INPUT_STRIDE);
        LD8(5,kernel+5*INPUT_STRIDE);
        LD8(6,kernel+6*INPUT_STRIDE);
        LD8(7,kernel+7*INPUT_STRIDE);
        LD8(8,kernel+8*INPUT_STRIDE);
        LD8(9,kernel+9*INPUT_STRIDE);
        LD8(10,kernel+10*INPUT_STRIDE);
        LD8(11,kernel+11*INPUT_STRIDE);
        LD8(12,kernel+12*INPUT_STRIDE);
        LD8(13,kernel+13*INPUT_STRIDE);
        LD8(14,kernel+14*INPUT_STRIDE);
        LD8(15,kernel+15*INPUT_STRIDE);
    }
    LD8(31,feature); SF(0,0,31,3);
    // The previous block's final vector stores have drained before this call.
    // DMA issue and next-tile staging now run after current DIMC work is issued.
    if (!chunk) launch_transfers(block);
    CSR(0x7d4,1); SF(0,1,31,7);
    CSR(0x7d4,0); CSR(0x7d3,1);
    LD8(16,kernel+16*INPUT_STRIDE);
    LD8(17,kernel+17*INPUT_STRIDE);
    LD8(18,kernel+18*INPUT_STRIDE);
    LD8(19,kernel+19*INPUT_STRIDE);
    LD8(20,kernel+20*INPUT_STRIDE);
    LD8(21,kernel+21*INPUT_STRIDE);
    LD8(22,kernel+22*INPUT_STRIDE);
    LD8(23,kernel+23*INPUT_STRIDE);
    LD8(24,kernel+24*INPUT_STRIDE);
    LD8(25,kernel+25*INPUT_STRIDE);
    LD8(26,kernel+26*INPUT_STRIDE);
    LD8(27,kernel+27*INPUT_STRIDE);
    LD8(28,kernel+28*INPUT_STRIDE);
    LD8(29,kernel+29*INPUT_STRIDE);
    LD8(30,kernel+30*INPUT_STRIDE);
    LD8(31,kernel+31*INPUT_STRIDE);
    LD8(2,feature); SF(1,2,2,3); CSR(0x7d4,1); SF(1,3,2,7);
    CSR(0x7d3,0); CSR(0x7d4,0);
}

static __attribute__((always_inline)) inline void prefetch_pair(
    int pair, const uint8_t *kernel) {
    switch (pair) {
    case 0: LD8(0,kernel+0*INPUT_STRIDE); LD8(1,kernel+1*INPUT_STRIDE); break;
    case 1: LD8(2,kernel+2*INPUT_STRIDE); LD8(3,kernel+3*INPUT_STRIDE); break;
    case 2: LD8(4,kernel+4*INPUT_STRIDE); LD8(5,kernel+5*INPUT_STRIDE); break;
    case 3: LD8(6,kernel+6*INPUT_STRIDE); LD8(7,kernel+7*INPUT_STRIDE); break;
    case 4: LD8(8,kernel+8*INPUT_STRIDE); LD8(9,kernel+9*INPUT_STRIDE); break;
    case 5: LD8(10,kernel+10*INPUT_STRIDE); LD8(11,kernel+11*INPUT_STRIDE); break;
    case 6: LD8(12,kernel+12*INPUT_STRIDE); LD8(13,kernel+13*INPUT_STRIDE); break;
    case 7: LD8(14,kernel+14*INPUT_STRIDE); LD8(15,kernel+15*INPUT_STRIDE); break;
    }
}


// A row uses the installed DIMC kernel. v0-v15 can therefore stage the next
// kernel while v16-v21 and v30/v31 retain live results/partial sums/features.
#define ROW(LOW,HIGH,FEATURE,NEXTFEATURE,PREVLOW,PREVHIGH,TAIL,PAIR) do { \
    E8(); CSR(0x7d4,0); \
    SF(LOW,0,FEATURE,3); \
    if (r+1 < rows) { LD8(NEXTFEATURE,features+(r+1)*INPUT_STRIDE); } \
    if (TAIL) { \
        if ((PAIR)==0 && chunk) { \
            prepare_transition(block,next); \
            next_kernel=next->valid ? next->kernel : 0; \
        } \
        if (next_kernel) prefetch_pair(PAIR,next_kernel); \
    } \
    CSR(0x7d4,1); SF(LOW,1,FEATURE,7); \
    SF(HIGH,2,FEATURE,3); \
    if (chunk) { \
        E32(); LD32(20,out+r*16); LD32(21,out+rows*16+r*16); E8(); \
    } \
    SF(HIGH,3,FEATURE,7); \
    E32(); \
    ST32(PREVLOW,out+(r-1)*16); ST32(PREVHIGH,out+rows*16+(r-1)*16); \
    if (chunk) { ADD(LOW,20); ADD(HIGH,21); } \
    ++r; \
} while (0)
#define PAIR(TAIL,P) do { \
    ROW(18,19,31,30,16,17,TAIL,P); \
    ROW(16,17,30,31,18,19,TAIL,(P)+1); \
} while (0)

static void compute_chunk(const block_t *block, block_t *next,
                          int chunk, int prefetched) {
    const uint8_t *features=block->features+chunk*128;
    const uint8_t *kernel=block->kernel+chunk*128;
    const uint8_t *next_kernel=chunk ? 0 : kernel+128;
    uint32_t *out=block->out;
    int rows=block->rows;
    bootstrap(kernel,features,prefetched,block,chunk);
    E32();
    if (chunk) { LD32(20,out); LD32(21,out+rows*16); ADD(0,20); ADD(1,21); }
    E8(); LD8(30,features+INPUT_STRIDE);
    int r=1;
    ROW(16,17,30,31,0,1,0,0);
    // Four row pairs per B8 group. Constant register selection and unrolling
    // remove the nested batch-end bookkeeping from the steady row loop.
    for (; r+8 <= rows-8;) {
        PAIR(0,0); PAIR(0,0); PAIR(0,0); PAIR(0,0);
    }
    for (; r < rows-8;) { PAIR(0,0); }
    // Conv1 tiles (136 rows and the final 32 rows) are multiples of eight.
    PAIR(1,0); PAIR(1,2); PAIR(1,4); PAIR(1,6);
    E32(); ST32(16,out+(rows-1)*16); ST32(17,out+rows*16+(rows-1)*16);
}

static volatile int failed;
int main(void) {
    snrt_cluster_hw_barrier();
    if (snrt_cluster_core_idx()==0) {
        pipeline.result=snrt_l3alloc(OUT_ROWS*OUT_COLS*4);
        pipeline.a[0]=snrt_l1alloc(TILE_ROWS*INPUT_STRIDE);
        pipeline.a[1]=snrt_l1alloc(TILE_ROWS*INPUT_STRIDE);
        pipeline.kernels=snrt_l1alloc(64*INPUT_STRIDE);
        pipeline.out[0]=snrt_l1alloc(TILE_ROWS*32*4);
        pipeline.out[1]=snrt_l1alloc(TILE_ROWS*32*4);
        printf("CONV1_TRANSITION M=%d logical_K=%d padded_K=%d N=%d tile_rows=%d batch_rows=8 numeric_check=%d\n",
               OUT_ROWS,VMVM_LOGICAL_K,FEAT_COLS,OUT_COLS,TILE_ROWS,RESNET_OVERLAP_CHECK);
        if (!pipeline.result || !pipeline.a[0] || !pipeline.a[1] ||
            !pipeline.kernels || !pipeline.out[0] || !pipeline.out[1]) {
            printf("FAIL allocation\n"); failed=1;
        } else {
            CSR(0x7d5,1);
            uint64_t compute_cycles=0;
            uint32_t start=cycles();
            snrt_dma_start_1d(pipeline.a[0],data_A,TILE_ROWS*INPUT_STRIDE);
            snrt_dma_start_1d(pipeline.kernels,data_B,64*INPUT_STRIDE);
            snrt_dma_wait_all();
            block_t work[2];
            work[0]=(block_t){pipeline.a[0],pipeline.kernels,pipeline.out[0],0,0,TILE_ROWS,0,0,1};
            int slot=0, prefetched=0;
            while (work[slot].valid) {
                block_t *block=&work[slot], *next=&work[slot^1];
                uint32_t cs=cycles();
                compute_chunk(block,next,0,prefetched);
                compute_chunk(block,next,1,1);
                compute_cycles+=(uint32_t)(cycles()-cs);
                // Scalar LSU loads wait for outstanding vector stores. Do not
                // publish this output to DMA before its last row reaches TCDM.
                asm volatile("lw zero, 0(%0)" :: "r"(block->out+block->rows*32-1) : "memory");
                pipeline.pending.valid=1;
                prefetched=1;
                slot^=1;
            }
            launch_output();
            snrt_dma_wait_all();
            uint32_t elapsed=cycles()-start;
            printf("VMVM_BENCH conv1_transition total_cycles=%u compute_cycles=%llu\n",
                   elapsed,(unsigned long long)compute_cycles);
#if RESNET_OVERLAP_CHECK
            int checked=0;
            for (int base=0;base<OUT_ROWS*OUT_COLS;base+=TILE_ROWS*32) {
                int words=OUT_ROWS*OUT_COLS-base;
                if (words>TILE_ROWS*32) words=TILE_ROWS*32;
                snrt_dma_start_1d(pipeline.out[0],pipeline.result+base,words*4);
                snrt_dma_start_1d(pipeline.out[1],serialized_C+base,words*4);
                snrt_dma_wait_all();
                for (int i=0;i<words;++i) {
                    if (pipeline.out[0][i]!=pipeline.out[1][i]) {
                        if (failed<8) printf("Mismatch idx=%d got=%u expected=%u\n",
                            base+i,pipeline.out[0][i],pipeline.out[1][i]);
                        ++failed;
                    }
                    ++checked;
                }
            }
            printf("SOFTWARE_CHECK checked=%d mismatches=%d\n",checked,failed);
            printf(failed ? "FAIL\n" : "PASS\n");
#else
            printf("RTL_TIMING_ONLY numeric_check=external_software\n");
#endif
            CSR(0x7d3,0); CSR(0x7d4,0); CSR(0x7d5,0);
        }
    }
    snrt_cluster_hw_barrier();
    return failed ? 1 : 0;
}
