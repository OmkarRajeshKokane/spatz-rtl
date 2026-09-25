// SPDX-License-Identifier: SHL-0.51
// Included after the shared transition helpers. Eight complete result registers
// precede each e32 accumulation phase; the first K chunk keeps its no-add path.
_Static_assert(OUT_ROWS == 784 && FEAT_COLS == 1152 && OUT_COLS == 128,
               "The eight-register schedule is specialized for Conv3");
_Static_assert(RESNET_RUN_ROWS % 4 == 0 && TILE_ROWS % 4 == 0,
               "Four-position groups require aligned validation and tile rows");

// Scalar loads use the existing scalar/vector LSU ordering to drain preceding
// vector stores. A store dependent on the last VADD separates arithmetic phases.
#define DRAIN_OUTPUT(p) asm volatile("lw zero, 0(%0)" :: "r"(p) : "memory")
// Snitch stalls FCSR reads while Spatz reports outstanding instructions
// (snitch.acc_stall / spatz_controller.issue_rsp_o.isfloat). This read-only
// boundary waits for all eight DIMC writebacks and old-partial loads. A RAW
// dependency alone permits word chaining and is not a whole-group barrier.
#define WAIT_SPATZ() do { \
    uint32_t ignored; \
    asm volatile("csrr %0, fcsr" : "=r"(ignored) :: "memory"); \
} while (0)
#define STORE_PAIR(L,H,P) do { \
    ST32(L,out+(P)*16); ST32(H,out+rows*16+(P)*16); \
} while (0)

// OLDL/OLDH for the final position are v30/v31. Their feature lifetime ends
// after the first instruction: the remaining three DIMCs reuse the saved feature.
#define VREG8_ROW(L,H,F,NF,OL,OH,LOOK,STORE,PL,PH,TAIL,P) do { \
    E8(); CSR(0x7d4,0); SF(L,0,F,3); \
    if (LOOK) { LD8(NF,features+(r+1)*INPUT_STRIDE); } \
    if (TAIL) { \
        if ((P)==0) { \
            if (next->valid) snrt_dma_wait_all(); \
            if (last_chunk) prepare_output(work); \
        } \
        if (next_kernel) prefetch_pair(P,next_kernel); \
    } \
    CSR(0x7d4,1); SF(L,1,F,7); SF(H,2,F,3); \
    E32(); \
    if (STORE) { STORE_PAIR(PL,PH,r-3); } \
    LD32(OL,out+r*16); LD32(OH,out+rows*16+r*16); \
    E8(); SF(H,3,F,7); \
    ++r; \
} while (0)

// WAIT_SPATZ establishes completion of all eight result registers before this
// burst; a dependency on v23 alone would still permit early word chaining.
// v16 is last so the following v16 store/drain waits for the whole IPU phase.
#define ADD_EIGHT_REGULAR() asm volatile( \
    "vadd.vv v23,v23,v31\n\t" \
    "vadd.vv v22,v22,v30\n\t" \
    "vadd.vv v21,v21,v29\n\t" \
    "vadd.vv v20,v20,v28\n\t" \
    "vadd.vv v19,v19,v27\n\t" \
    "vadd.vv v18,v18,v26\n\t" \
    "vadd.vv v17,v17,v25\n\t" \
    "vadd.vv v16,v16,v24" ::: "memory")

#define VREG8_GROUP(TAIL,P) do { \
    int group=r; \
    E8(); LD8(30,features+r*INPUT_STRIDE); \
    VREG8_ROW(16,17,30,31,24,25,1,group>4,18,19,TAIL,P); \
    VREG8_ROW(18,19,31,30,26,27,1,group>4,20,21,TAIL,(P)+1); \
    VREG8_ROW(20,21,30,31,28,29,1,group>4,22,23,TAIL,(P)+2); \
    VREG8_ROW(22,23,31,30,30,31,0,0,22,23,TAIL,(P)+3); \
    E32(); WAIT_SPATZ(); ADD_EIGHT_REGULAR(); \
    STORE_PAIR(16,17,group); \
    DRAIN_OUTPUT(out+group*16); \
} while (0)

static void compute_chunk_vreg8(const work_t *work, work_t *next, int prefetched) {
    const uint8_t *features=work->features, *kernel=work->kernel;
    uint32_t *out=work->out;
    int rows=work->rows, last_chunk=work->k+128==FEAT_COLS;
    bootstrap(kernel,features,prefetched,work,next);
    const uint8_t *next_kernel=next->valid && rows>=12 ? next->kernel : 0;

    // Bootstrap installs all kernel groups and leaves position zero in v0/v1.
    // Keep those two results live until three more positions finish. Old-partial
    // loads respect the last kernel reads through the existing VRF scoreboard.
    E32(); LD32(24,out); LD32(25,out+rows*16);
    E8(); LD8(30,features+INPUT_STRIDE);
    int r=1;
    VREG8_ROW(16,17,30,31,26,27,1,0,0,1,0,0);
    VREG8_ROW(18,19,31,30,28,29,1,0,0,1,0,0);
    VREG8_ROW(20,21,30,31,30,31,0,0,0,1,0,0);
    E32(); WAIT_SPATZ();
    asm volatile(
        "vadd.vv v21,v21,v31\n\t"
        "vadd.vv v20,v20,v30\n\t"
        "vadd.vv v19,v19,v29\n\t"
        "vadd.vv v18,v18,v28\n\t"
        "vadd.vv v17,v17,v27\n\t"
        "vadd.vv v16,v16,v26\n\t"
        "vadd.vv v1,v1,v25\n\t"
        "vadd.vv v0,v0,v24" ::: "memory");
    // The peeled group has a different destination map. Retire it completely
    // before switching to v16-v23; v0/v1 are then free for future kernel staging.
    STORE_PAIR(0,1,0); STORE_PAIR(16,17,1);
    STORE_PAIR(18,19,2); STORE_PAIR(20,21,3);
    DRAIN_OUTPUT(out);

    int tail=rows>=12 ? rows-8 : rows;
    for (;r+4<=tail;) { VREG8_GROUP(0,0); }
    if (rows>=12) { VREG8_GROUP(1,0); VREG8_GROUP(1,4); }
    else if (last_chunk) prepare_output(work);

    // Every regular group already stored its first pair. Drain the final six
    // registers before a K-chunk transition or publishing completed output DMA.
    if (rows>4) {
        E32();
        STORE_PAIR(18,19,rows-3); STORE_PAIR(20,21,rows-2);
        STORE_PAIR(22,23,rows-1);
        DRAIN_OUTPUT(out+rows*32-1);
    }
}

#undef VREG8_GROUP
#undef ADD_EIGHT_REGULAR
#undef VREG8_ROW
#undef STORE_PAIR
#undef DRAIN_OUTPUT
#undef WAIT_SPATZ
