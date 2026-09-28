// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Matheus Cavalcante, ETH Zurich
//
// The Vector Functional Unit (VFU) executes all arithmetic and logical
// vector instructions. It can be configured with a parameterizable amount
// of IPUs that work in parallel.

module spatz_vfu
  import spatz_pkg::*;
  import rvv_pkg::*;
  import cf_math_pkg::idx_width;
  import fpnew_pkg::*; #(
    /// FPU configuration.
    parameter fpu_implementation_t FPUImplementation = fpu_implementation_t'(0)
  ) (
    input  logic             clk_i,
    input  logic             rst_ni,
    input  logic [31:0]      hart_id_i,
    // Spatz req
    input  spatz_req_t       spatz_req_i,
    input  logic             spatz_req_valid_i,
    output logic             spatz_req_ready_o,
    // VFU response
    output logic             vfu_rsp_valid_o,
    input  logic             vfu_rsp_ready_i,
    output vfu_rsp_t         vfu_rsp_o,
    // VRF
    output vrf_addr_t        vrf_waddr_o,
    output vrf_data_t        vrf_wdata_o,
    output logic             vrf_we_o,
    output vrf_be_t          vrf_wbe_o,
    input  logic             vrf_wvalid_i,
    output spatz_id_t  [3:0] vrf_id_o,
    output vrf_addr_t  [2:0] vrf_raddr_o,
    output logic       [2:0] vrf_re_o,
    input  vrf_data_t  [2:0] vrf_rdata_i,
    input  logic       [2:0] vrf_rvalid_i,
    // FPU side channel
    output status_t          fpu_status_o
  );

// Include FF
`include "common_cells/registers.svh"

  // Instruction tag (propagated together with the operands through the pipelines)
  typedef struct packed {
    spatz_id_t id;

    vew_e vsew;
    vlen_t vstart;

    // Encodes both the scalar RD and the VD address in the VRF
    vrf_addr_t vd_addr;
    logic wb;
    logic last;

    // Is this a narrowing instruction?
    logic narrowing;
    logic narrowing_upper;

    // Is this a reduction?
    logic reduction;
  } vfu_tag_t;

  ///////////////////////
  //  Operation queue  //
  ///////////////////////

  spatz_req_t spatz_req;
  logic       spatz_req_valid;
  logic       spatz_req_ready;

  logic operation_queue_full, operation_queue_empty;
  spatz_req_t dimc_req;
  logic dimc_req_valid;
  logic dimc_queue_full, dimc_queue_empty;
  logic exclusive_request;
  logic [NrParallelInstructions-1:0] exclusive_inflight_q, exclusive_inflight_d;
  `FF(exclusive_inflight_q, exclusive_inflight_d, '0)
  assign exclusive_request = (FPU && spatz_req_i.op inside {[VFADD:VSDOTP]}) ||
                              spatz_req_i.op_arith.is_reduction;
  always_comb begin
    exclusive_inflight_d = exclusive_inflight_q;
    if (vfu_rsp_valid_o) exclusive_inflight_d[vfu_rsp_o.id] = 1'b0;
    if (spatz_req_valid_i && spatz_req_ready_o && spatz_req_i.ex_unit == VFU && exclusive_request)
      exclusive_inflight_d[spatz_req_i.id] = 1'b1;
  end

  fifo_v3 #(
    .FALL_THROUGH(1'b1),
    .DEPTH       (2),
    .dtype       (spatz_req_t)
  ) i_operation_queue (
    .clk_i     (clk_i                                                        ),
    .rst_ni    (rst_ni                                                       ),
    .flush_i   (1'b0                                                         ),
    .testmode_i(1'b0                                                         ),
    .full_o    (operation_queue_full                                         ),
    .empty_o   (operation_queue_empty                                        ),
    .usage_o   (                                                             ),
    .data_i    (spatz_req_i                                                  ),
    .push_i    (spatz_req_valid_i && spatz_req_i.ex_unit == VFU && spatz_req_i.op != DIMC_OP &&
                spatz_req_ready_o                                            ),
    .data_o    (spatz_req                                                    ),
    .pop_i     (spatz_req_ready && !operation_queue_empty                    )
  );

  // A computing DIMC instruction must not block an independent IPU partial
  // sum. Dependencies remain enforced by the controller's VRF scoreboard.
  fifo_v3 #(
    .FALL_THROUGH(1'b1),
    .DEPTH       (2),
    .dtype       (spatz_req_t)
  ) i_dimc_operation_queue (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(1'b0), .testmode_i(1'b0),
    .full_o(dimc_queue_full), .empty_o(dimc_queue_empty), .usage_o(),
    .data_i(spatz_req_i),
    .push_i(spatz_req_valid_i && spatz_req_i.ex_unit == VFU &&
            spatz_req_i.op == DIMC_OP && spatz_req_ready_o),
    .data_o(dimc_req),
    .pop_i(dimc_instr_done && !dimc_queue_empty)
  );

  // Preserve ordering around FPU/reduction operations at dispatch. Blocking
  // them after queueing could deadlock a DIMC operand dependent on such work.
  assign spatz_req_ready_o = spatz_req_i.op == DIMC_OP ?
                              (!dimc_queue_full && !(|exclusive_inflight_q)) :
                              (!operation_queue_full &&
                               (!exclusive_request || (!dimc_req_valid && !dimc_inflight)));
  assign spatz_req_valid   = !operation_queue_empty;
  assign dimc_req_valid    = !dimc_queue_empty;

  ///////////////
  //  Control  //
  ///////////////

  // Vector length counter
  vlen_t vl_q, vl_d;
  `FF(vl_q, vl_d, '0)

  // Are we busy?
  logic busy_q, busy_d;
  `FF(busy_q, busy_d, 1'b0)

  // Number of elements in one VRF word
  logic [$clog2(N_FU*(ELEN/8)):0] nr_elem_word;
  assign nr_elem_word = (N_FU * (1 << (MAXEW - spatz_req.vtype.vsew))) >> spatz_req.op_arith.is_narrowing;

  // Are we running integer or floating-point instructions?
  typedef enum logic [1:0] {
    VFU_RunningIPU, VFU_RunningFPU
   } state_t;
   state_t state_d, state_q;
  `FF(state_q, state_d, VFU_RunningFPU)

  // Propagate the tags through the functional units
  vfu_tag_t ipu_result_tag, fpu_result_tag, result_tag;
  vfu_tag_t input_tag;

  assign result_tag = state_q == VFU_RunningIPU ? ipu_result_tag : fpu_result_tag;

  // Number of words advanced by vstart
  vlen_t vstart;
  assign vstart = ((spatz_req.vstart / N_FU) >> (MAXEW - spatz_req.vtype.vsew)) << (MAXEW - spatz_req.vtype.vsew);

  // Should we stall?
  logic stall;

  // Do we have the reduction operand?
  logic reduction_operand_ready_d, reduction_operand_ready_q;

  // Are the VFU operands ready?
  logic op1_is_ready, op2_is_ready, op3_is_ready, operands_ready;
  assign op1_is_ready   = spatz_req_valid && ((!spatz_req.op_arith.is_reduction && (!spatz_req.use_vs1 || vrf_rvalid_i[1])) || (spatz_req.op_arith.is_reduction && reduction_operand_ready_q));
  assign op2_is_ready   = spatz_req_valid && ((!spatz_req.use_vs2 || vrf_rvalid_i[0]) || spatz_req.op_arith.is_reduction);
  assign op3_is_ready   = spatz_req_valid && (!spatz_req.vd_is_src || vrf_rvalid_i[2]);
  assign operands_ready = op1_is_ready && op2_is_ready && op3_is_ready && (!spatz_req.op_arith.is_scalar || vfu_rsp_ready_i) && !stall;

  // Valid operations
  logic [N_FU*ELENB-1:0] valid_operations;
  assign valid_operations = (spatz_req.op_arith.is_scalar || spatz_req.op_arith.is_reduction) ? (spatz_req.vtype.vsew == EW_32 ? 4'hf : 8'hff) : '1;

  // Pending results
  logic [N_FU*ELENB-1:0] pending_results;
  assign pending_results = result_tag.wb ? (result_tag.vsew == EW_32 ? 4'hf : 8'hff) : '1;

  // Did we issue a microoperation?
  logic word_issued;

  // Currently running instructions
  logic [NrParallelInstructions-1:0] running_d, running_q;
  `FF(running_q, running_d, '0)

  // Is this a FPU instruction
  logic is_fpu_insn;
  assign is_fpu_insn = FPU && spatz_req.op inside {[VFADD:VSDOTP]};

  // Is the FPU busy?
  logic is_fpu_busy;

  // Is the IPU busy?
  logic is_ipu_busy;

  // DIMC control
  localparam int unsigned DimcSectionWidth    = 512;
  localparam int unsigned DimcWordsPerSection = DimcSectionWidth / VRFWordWidth;
  localparam int unsigned DimcSections        =
      (NrWordsPerVector + DimcWordsPerSection - 1) / DimcWordsPerSection;
  localparam int unsigned DimcRowWidth        = DimcSectionWidth * DimcSections;
  localparam int unsigned DimcSectionIdxWidth = DimcSections > 1 ? $clog2(DimcSections) : 1;
  localparam int unsigned DimcValidBitsWidth  = $clog2(DimcRowWidth + 1);
  localparam int unsigned DimcResultsPerWord  = VRFWordWidth / 32;
  localparam int unsigned DimcVqmmaccRows     = 8;
  localparam int unsigned DimcInitCycles      = 3;
  localparam int unsigned DimcInitCountWidth  =
      DimcInitCycles > 1 ? $clog2(DimcInitCycles) : 1;
  localparam int unsigned DimcVqmmaccWords    =
      (DimcVqmmaccRows * 32 + VRFWordWidth - 1) / VRFWordWidth;
  localparam int unsigned DimcResultWords     = 2 * DimcVqmmaccWords;
  localparam int unsigned DimcWriteIdxWidth   =
      DimcResultWords > 1 ? $clog2(DimcResultWords) : 1;
  typedef logic [DimcSectionWidth-1:0] dimc_data_t;

  typedef enum logic [2:0] {
    DimcIdle,
    DimcLoadFeature,
    DimcLoadKernel,
    DimcComputeInit,
    DimcComputeIssue,
    DimcWriteResult
  } dimc_state_t;

  dimc_state_t dimc_state_d, dimc_state_q;
  // The queue entry can retire before the last row because its operands and
  // configuration are already latched. Architectural completion is still the
  // final accepted VRF write, through dimc_rsp_done.
  logic dimc_request_released_d, dimc_request_released_q;
  logic [DimcSectionIdxWidth-1:0] dimc_section_d, dimc_section_q;
  logic [4:0]                     dimc_row_d, dimc_row_q;
  logic [DimcInitCountWidth-1:0]  dimc_init_count_d, dimc_init_count_q;
  logic [4:0]                     dimc_capture_count_d, dimc_capture_count_q;
  vrf_data_t                      dimc_result_d [DimcResultWords-1:0];
  vrf_data_t                      dimc_result_q [DimcResultWords-1:0];
  logic [4:0]                     dimc_tail_capture_count_d, dimc_tail_capture_count_q;
  vrf_data_t                      dimc_tail_result_d [DimcResultWords-1:0];
  vrf_data_t                      dimc_tail_result_q [DimcResultWords-1:0];
  logic                           dimc_wb_pending_d, dimc_wb_pending_q;
  spatz_id_t                      dimc_wb_id_d, dimc_wb_id_q;
  vrf_addr_t                      dimc_wb_base_addr_d, dimc_wb_base_addr_q;
  logic [DimcWriteIdxWidth-1:0]   dimc_wb_word_d, dimc_wb_word_q;
  logic [DimcWriteIdxWidth-1:0]   dimc_wb_last_word_d, dimc_wb_last_word_q;
  vrf_data_t                      dimc_wb_result_d [DimcResultWords-1:0];
  vrf_data_t                      dimc_wb_result_q [DimcResultWords-1:0];
  logic                           dimc_tail_pending_d, dimc_tail_pending_q;
  logic                           dimc_tail_done_pending_d, dimc_tail_done_pending_q;
  spatz_id_t                      dimc_tail_id_d, dimc_tail_id_q;
  vrf_addr_t                      dimc_tail_base_addr_d, dimc_tail_base_addr_q;
  logic [DimcWriteIdxWidth-1:0]   dimc_tail_first_word_d, dimc_tail_first_word_q;
  logic [DimcWriteIdxWidth-1:0]   dimc_tail_last_word_d, dimc_tail_last_word_q;
  logic [4:0]                     dimc_tail_row_limit_d, dimc_tail_row_limit_q;
  logic [4:0]                     dimc_tail_row_offset_d, dimc_tail_row_offset_q;
  spatz_id_t                      dimc_active_id_d, dimc_active_id_q;
  vreg_t                          dimc_active_vs1_d, dimc_active_vs1_q;
  vreg_t                          dimc_active_vs2_d, dimc_active_vs2_q;
  vreg_t                          dimc_active_vd_d, dimc_active_vd_q;
  vlen_t                          dimc_active_vl_d, dimc_active_vl_q;
  dimc_cfg_t                      dimc_active_cfg_d, dimc_active_cfg_q;

  `FF(dimc_state_q, dimc_state_d, DimcIdle)
  `FF(dimc_request_released_q, dimc_request_released_d, 1'b0)
  `FF(dimc_section_q, dimc_section_d, '0)
  `FF(dimc_row_q, dimc_row_d, '0)
  `FF(dimc_init_count_q, dimc_init_count_d, '0)
  `FF(dimc_capture_count_q, dimc_capture_count_d, '0)
  `FF(dimc_tail_capture_count_q, dimc_tail_capture_count_d, '0)
  `FF(dimc_wb_pending_q, dimc_wb_pending_d, 1'b0)
  `FF(dimc_wb_id_q, dimc_wb_id_d, '0)
  `FF(dimc_wb_base_addr_q, dimc_wb_base_addr_d, '0)
  `FF(dimc_wb_word_q, dimc_wb_word_d, '0)
  `FF(dimc_wb_last_word_q, dimc_wb_last_word_d, '0)
  `FF(dimc_tail_pending_q, dimc_tail_pending_d, 1'b0)
  `FF(dimc_tail_done_pending_q, dimc_tail_done_pending_d, 1'b0)
  `FF(dimc_tail_id_q, dimc_tail_id_d, '0)
  `FF(dimc_tail_base_addr_q, dimc_tail_base_addr_d, '0)
  `FF(dimc_tail_first_word_q, dimc_tail_first_word_d, '0)
  `FF(dimc_tail_last_word_q, dimc_tail_last_word_d, '0)
  `FF(dimc_tail_row_limit_q, dimc_tail_row_limit_d, '0)
  `FF(dimc_tail_row_offset_q, dimc_tail_row_offset_d, '0)
  `FF(dimc_active_id_q, dimc_active_id_d, '0)
  `FF(dimc_active_vs1_q, dimc_active_vs1_d, '0)
  `FF(dimc_active_vs2_q, dimc_active_vs2_d, '0)
  `FF(dimc_active_vd_q, dimc_active_vd_d, '0)
  `FF(dimc_active_vl_q, dimc_active_vl_d, '0)
  `FF(dimc_active_cfg_q, dimc_active_cfg_d, '0)
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dimc_result_q <= '{default: '0};
      dimc_tail_result_q <= '{default: '0};
      dimc_wb_result_q <= '{default: '0};
    end else begin
      dimc_result_q <= dimc_result_d;
      dimc_tail_result_q <= dimc_tail_result_d;
      dimc_wb_result_q <= dimc_wb_result_d;
    end
  end

  logic       dimc_busy;
  logic       dimc_start;
  logic       dimc_turnover;
  logic       dimc_instr_done;
  logic       dimc_rsp_done;
  logic       dimc_load_feature;
  logic       dimc_vrf_read_feature;
  logic       dimc_vrf_read_kernel;
  logic       dimc_vrf_read_upper;
  logic       dimc_read_grant;
  logic       dimc_read_turn_q, dimc_read_turn_d;
  logic       dimc_read_request, normal_read_request;
  logic       dimc_inflight;
  `FF(dimc_read_turn_q, dimc_read_turn_d, 1'b1)
  logic       dimc_write_grant, normal_write_request;
  logic       dimc_write_turn_q, dimc_write_turn_d;
  `FF(dimc_write_turn_q, dimc_write_turn_d, 1'b1)
  logic       dimc_write_valid;
  logic       dimc_wb_accept;
  logic       dimc_wb_done;
  logic       dimc_wb_can_enqueue;
  logic       dimc_capture_complete;
  logic       dimc_wb_write_through;
  logic       dimc_wb_write_through_accept;
  logic       dimc_compute_fire;
  logic       dimc_capture_valid;
  logic       dimc_handoff_tail;
  logic [4:0] dimc_row_limit;
  logic [4:0] dimc_capture_row;
  logic [4:0] dimc_capture_row_limit;
  logic [4:0] dimc_capture_row_offset;
  logic [4:0] dimc_result_row_offset;
  logic [4:0] dimc_result_index;
  spatz_id_t  dimc_capture_id;
  vrf_addr_t  dimc_capture_base_addr;
  logic [DimcWriteIdxWidth-1:0] dimc_capture_first_write_word;
  logic [DimcWriteIdxWidth-1:0] dimc_capture_last_write_word;
  vrf_addr_t  dimc_result_base_addr;
  logic [DimcWriteIdxWidth-1:0] dimc_first_write_word;
  logic [DimcWriteIdxWidth-1:0] dimc_last_write_word;
  logic [DimcWriteIdxWidth-1:0] dimc_write_word;
  logic [DimcWriteIdxWidth-1:0] dimc_write_last_word;
  spatz_id_t  dimc_write_id;
  vreg_t      dimc_kernel_vreg;
  logic [31:0] dimc_result_word;
  vrf_addr_t  dimc_feature_addr;
  vrf_addr_t  dimc_kernel_addr;
  vrf_addr_t  dimc_upper_addr;
  vrf_addr_t  dimc_write_addr;
  vrf_data_t  dimc_write_data;

  logic       dimc_readyn;
  logic       dimc_compe;
  logic       dimc_fcsn;
  logic [1:0] dimc_mode;
  logic [1:0] dimc_fa;
  dimc_data_t dimc_fd;
  logic [23:0] dimc_addin;
  logic       dimc_sout;
  logic [2:0] dimc_res_out;
  logic [23:0] dimc_psout;
  dimc_data_t dimc_q;
  dimc_data_t dimc_d;
  logic [6:0] dimc_ra;
  logic [6:0] dimc_wa;
  logic       dimc_rcsn;
  logic       dimc_rcsn0;
  logic       dimc_rcsn1;
  logic       dimc_rcsn2;
  logic       dimc_rcsn3;
  logic       dimc_wcsn;
  logic       dimc_wen;
  dimc_data_t dimc_mask;
  logic [7:0] dimc_mct;
  logic [7:0] dimc_active_mct;
  logic [8:0] dimc_tail_quads;
  logic [DimcValidBitsWidth-1:0] dimc_active_bits;
  logic [DimcValidBitsWidth-1:0] dimc_tail_bits;

  assign dimc_busy  = dimc_state_q != DimcIdle;
  // Latch the next queued instruction at the edge that finishes the current
  // last row. If capture/writeback is blocked, retain the ordinary idle path.
  assign dimc_turnover = dimc_state_q == DimcComputeIssue &&
                         dimc_row_q == DimcVqmmaccRows - 1 &&
                         dimc_request_released_q && !dimc_tail_pending_q &&
                         dimc_capture_complete && dimc_wb_can_enqueue;
  assign dimc_inflight = dimc_busy || dimc_tail_pending_q ||
                         dimc_tail_done_pending_q || dimc_wb_pending_q;
  assign dimc_start = dimc_req_valid && !is_fpu_busy &&
                      reduction_state_q == Reduction_NormalExecution &&
                      (!dimc_busy || dimc_turnover) && !dimc_tail_done_pending_q;

  // Alternate ownership when both queues need the shared read ports. In
  // particular, a DIMC operand waiting on an older IPU result must not starve
  // the IPU reads that produce that result. A stalled grant also yields.
  assign dimc_read_request = dimc_state_q inside {DimcLoadFeature, DimcLoadKernel};
  assign normal_read_request = spatz_req_valid && vl_q < spatz_req.vl &&
                               (spatz_req.use_vs1 || spatz_req.use_vs2 || spatz_req.vd_is_src);
  assign dimc_read_grant = dimc_read_request && (!normal_read_request || dimc_read_turn_q);
  assign dimc_read_turn_d = dimc_read_request && normal_read_request ?
                            !dimc_read_turn_q : 1'b1;
  assign dimc_capture_valid = !dimc_readyn;
  assign dimc_capture_row   = dimc_tail_pending_q ? dimc_tail_capture_count_q :
                                                    dimc_capture_count_q;
  assign dimc_capture_complete = dimc_capture_valid &&
                                 (dimc_state_q == DimcComputeIssue || dimc_tail_pending_q) &&
                                 (dimc_capture_row == dimc_capture_row_limit - 1'b1);
  assign dimc_wb_write_through = dimc_capture_complete && !dimc_wb_pending_q;
  assign dimc_write_valid   = dimc_wb_pending_q || dimc_wb_write_through;
  assign dimc_write_id      = dimc_wb_write_through ? dimc_capture_id : dimc_wb_id_q;
  assign dimc_write_word    = dimc_wb_write_through ? dimc_capture_first_write_word :
                                                        dimc_wb_word_q;
  assign dimc_write_last_word = dimc_wb_write_through ? dimc_capture_last_write_word :
                                                          dimc_wb_last_word_q;
  assign dimc_write_addr    = dimc_wb_write_through ?
                              vrf_addr_t'(int'(dimc_capture_base_addr) +
                                          int'(dimc_capture_first_write_word)) :
                              vrf_addr_t'(int'(dimc_wb_base_addr_q) + int'(dimc_wb_word_q));
  assign dimc_write_data    = dimc_wb_write_through ?
                              (dimc_tail_pending_q ?
                               dimc_tail_result_d[dimc_capture_first_write_word] :
                               dimc_result_d[dimc_capture_first_write_word]) :
                              dimc_wb_result_q[dimc_wb_word_q];
  // A later DIMC destination can depend on an older IPU write. Yield even
  // when the selected write is blocked by the scoreboard, to avoid deadlock.
  assign normal_write_request = &(result_valid | ~pending_results) && !result_tag.reduction;
  assign dimc_write_grant = dimc_write_valid && (!normal_write_request || dimc_write_turn_q);
  assign dimc_write_turn_d = dimc_write_valid && normal_write_request ?
                             !dimc_write_turn_q : 1'b1;
  assign dimc_wb_accept     = dimc_write_grant && vrf_wvalid_i;
  assign dimc_wb_write_through_accept = dimc_wb_write_through && dimc_wb_accept;
  assign dimc_wb_done       = dimc_wb_accept && (dimc_write_word == dimc_write_last_word);
  assign dimc_wb_can_enqueue = !dimc_wb_pending_q || dimc_wb_done;
  assign dimc_rsp_done      = dimc_wb_done;

  always_comb begin : dimc_mct_proc
    dimc_active_bits = DimcValidBitsWidth'(dimc_active_vl_q) << dimc_active_cfg_q.ci[1:0];
    dimc_tail_bits   = '0;
    dimc_tail_quads  = '0;
    dimc_active_mct  = '0;

    if (dimc_active_bits < DimcValidBitsWidth'(DimcRowWidth)) begin
      dimc_tail_bits  = DimcValidBitsWidth'(DimcRowWidth) - dimc_active_bits;
      dimc_tail_quads = 9'(dimc_tail_bits[DimcValidBitsWidth-1:2]);
      dimc_active_mct = dimc_tail_quads[8] ? 8'hff : dimc_tail_quads[7:0];
    end
  end : dimc_mct_proc

  DIMC_18_fixed #(
    .SECTION_WIDTH(DimcSectionWidth),
    .NUM_SECTIONS (DimcSections)
  ) i_dimc (
    .RCK   (clk_i        ),
    .RESETn(rst_ni       ),
    .READYN(dimc_readyn  ),
    .COMPE (dimc_compe   ),
    .FCSN  (dimc_fcsn    ),
    .MODE  (dimc_mode    ),
    .FA    (dimc_fa      ),
    .FD    (dimc_fd      ),
    .ADDIN (dimc_addin   ),
    .SOUT  (dimc_sout    ),
    .RES_OUT(dimc_res_out),
    .PSOUT (dimc_psout   ),
    .Q     (dimc_q       ),
    .D     (dimc_d       ),
    .RA    (dimc_ra      ),
    .WA    (dimc_wa      ),
    .RCSN  (dimc_rcsn    ),
    .RCSN0 (dimc_rcsn0   ),
    .RCSN1 (dimc_rcsn1   ),
    .RCSN2 (dimc_rcsn2   ),
    .RCSN3 (dimc_rcsn3   ),
    .WCK   (clk_i        ),
    .WCSN  (dimc_wcsn    ),
    .WEN   (dimc_wen     ),
    .M     (dimc_mask    ),
    .MCT   (dimc_mct     )
  );

  // Scalar results (sent back to Snitch)
  elen_t scalar_result;

  // Is this the last request?
  logic last_request;

  // Reduction state
  typedef enum logic [2:0] {
    Reduction_NormalExecution,
    Reduction_Wait,
    Reduction_Init,
    Reduction_Reduce,
    Reduction_WriteBack
   } reduction_state_t;
   reduction_state_t reduction_state_d, reduction_state_q;
  `FF(reduction_state_q, reduction_state_d, Reduction_NormalExecution)

  // Is the reduction done?
  logic reduction_done;

  // Are we producing the upper or lower part of the results of a narrowing instruction?
  logic narrowing_upper_d, narrowing_upper_q;
  `FF(narrowing_upper_q, narrowing_upper_d, 1'b0)

  // Are we reading the upper or lower part of the operands of a widening instruction?
  logic widening_upper_d, widening_upper_q;
  `FF(widening_upper_q, widening_upper_d, 1'b0)

  // Are any results valid?
  logic [N_FU*ELEN-1:0]  result;
  logic [N_FU*ELENB-1:0] result_valid;
  logic                  result_ready;

  always_comb begin: control_proc
    // Maintain state
    vl_d              = vl_q;
    busy_d            = busy_q;
    running_d         = running_q;
    state_d           = state_q;
    narrowing_upper_d = narrowing_upper_q;
    widening_upper_d  = widening_upper_q;

    // We are not stalling
    stall = 1'b0;

    // This is not the last request
    last_request = 1'b0;

    // We are handling an instruction
    spatz_req_ready = 1'b0;

    // Do not ack anything
    vfu_rsp_valid_o = 1'b0;
    vfu_rsp_o       = '0;

    // Change number of remaining elements
    if (word_issued) begin
      vl_d              = vl_q + nr_elem_word;
      // Update narrowing information
      narrowing_upper_d = narrowing_upper_q ^ spatz_req.op_arith.is_narrowing;
      widening_upper_d  = widening_upper_q ^ (spatz_req.op_arith.widen_vs1 || spatz_req.op_arith.widen_vs2);
    end

    // Current state of the VFU
    if (spatz_req_valid)
      unique case (state_q)
        VFU_RunningIPU: begin
          // Only go to the FPU state once the IPUs are no longer busy
          if (is_fpu_insn) begin
            if (is_ipu_busy || dimc_inflight || dimc_start)
              stall = 1'b1;
            else begin
              state_d = VFU_RunningFPU;
              stall   = 1'b1;
            end
          end
        end
        VFU_RunningFPU: begin
          // Only go back to the IPU state once the FPUs are no longer busy
          if (!is_fpu_insn)
            if (is_fpu_busy)
              stall = 1'b1;
            else begin
              state_d = VFU_RunningIPU;
              stall   = 1'b1;
            end
        end
        default:;
      endcase

    // Only ordinary IPU arithmetic overlaps DIMC. Reductions and FPU work
    // retain their existing exclusive execution protocol.
    if (dimc_read_grant ||
        ((is_fpu_insn || spatz_req.op_arith.is_reduction) && (dimc_inflight || dimc_start)))
      stall = 1'b1;

    // Finished the execution!
    if (spatz_req_valid &&
        ((vl_d >= spatz_req.vl && !spatz_req.op_arith.is_reduction) || reduction_done)) begin
      spatz_req_ready         = spatz_req_valid;
      busy_d                  = 1'b0;
      vl_d                    = '0;
      last_request            = 1'b1;
      running_d[spatz_req.id] = 1'b0;
      widening_upper_d        = 1'b0;
      narrowing_upper_d       = 1'b0;
    end
    // Do we have a new instruction?
    else if (spatz_req_valid && !running_d[spatz_req.id]) begin
      // Start at vstart
      vl_d                    = vstart;
      busy_d                  = 1'b1;
      running_d[spatz_req.id] = 1'b1;

      // Change number of remaining elements
      if (word_issued)
        vl_d = vl_q + nr_elem_word;
    end

    // An instruction finished execution
    if (dimc_rsp_done) begin
      vfu_rsp_o.id      = dimc_write_id;
      vfu_rsp_o.rd      = '0;
      vfu_rsp_o.wb      = 1'b0;
      vfu_rsp_o.result  = '0;
      vfu_rsp_valid_o   = 1'b1;
    end else if ((result_tag.last && result_ready && reduction_state_q inside {Reduction_NormalExecution, Reduction_Wait}) || reduction_done) begin
      vfu_rsp_o.id      = result_tag.id;
      vfu_rsp_o.rd      = result_tag.vd_addr[GPRWidth-1:0];
      vfu_rsp_o.wb      = result_tag.wb;
      vfu_rsp_o.result  = result_tag.wb ? scalar_result : '0;
      vfu_rsp_valid_o   = 1'b1;
    end
  end: control_proc

  //////////////
  // Operands //
  //////////////

  // Reduction registers
  elen_t [1:0] reduction_q, reduction_d;
  `FFL(reduction_q, reduction_d, reduction_operand_ready_d, '0)

  // IPU results
  logic [N_FU*ELEN-1:0]  ipu_result;
  logic [N_FU*ELENB-1:0] ipu_result_valid;
  logic [N_FU*ELENB-1:0] ipu_in_ready;

  // FPU results
  logic [N_FU*ELEN-1:0]  fpu_result;
  logic [N_FU*ELENB-1:0] fpu_result_valid;
  logic [N_FU*ELENB-1:0] fpu_in_ready;

  // Operands and result signals
  logic [N_FU*ELEN-1:0]  operand1, operand2, operand3;
  logic [N_FU*ELENB-1:0] in_ready;
  always_comb begin: operand_proc
    if (spatz_req.op_arith.is_scalar)
      operand1 = {1*N_FU{spatz_req.rs1}};
    else if (spatz_req.use_vs1)
      operand1 = spatz_req.op_arith.is_reduction ? $unsigned(reduction_q[1]) : vrf_rdata_i[1];
    else begin
      // Replicate scalar operands
      unique case (spatz_req.op == VSDOTP ? vew_e'(spatz_req.vtype.vsew + 1) : spatz_req.vtype.vsew)
        EW_8 : operand1   = MAXEW == EW_32 ? {4*N_FU{spatz_req.rs1[7:0]}}  : {8*N_FU{spatz_req.rs1[7:0]}};
        EW_16: operand1   = MAXEW == EW_32 ? {2*N_FU{spatz_req.rs1[15:0]}} : {4*N_FU{spatz_req.rs1[15:0]}};
        EW_32: operand1   = MAXEW == EW_32 ? {1*N_FU{spatz_req.rs1[31:0]}} : {2*N_FU{spatz_req.rs1[31:0]}};
        default: operand1 = {1*N_FU{spatz_req.rs1}};
      endcase
    end

    if ((!spatz_req.op_arith.is_scalar || spatz_req.op == VADD) && spatz_req.use_vs2)
      operand2 = spatz_req.op_arith.is_reduction ? $unsigned(reduction_q[0]) : vrf_rdata_i[0];
    else
      // Replicate scalar operands
      unique case (spatz_req.op == VSDOTP ? vew_e'(spatz_req.vtype.vsew + 1) : spatz_req.vtype.vsew)
        EW_8 : operand2   = MAXEW == EW_32 ? {4*N_FU{spatz_req.rs2[7:0]}}  : {8*N_FU{spatz_req.rs2[7:0]}};
        EW_16: operand2   = MAXEW == EW_32 ? {2*N_FU{spatz_req.rs2[15:0]}} : {4*N_FU{spatz_req.rs2[15:0]}};
        EW_32: operand2   = MAXEW == EW_32 ? {1*N_FU{spatz_req.rs2[31:0]}} : {2*N_FU{spatz_req.rs2[31:0]}};
        default: operand2 = {1*N_FU{spatz_req.rs2}};
      endcase

    operand3 = spatz_req.op_arith.is_scalar ? {1*N_FU{spatz_req.rsd}} : vrf_rdata_i[2];
  end: operand_proc

  assign in_ready     = state_q == VFU_RunningIPU ? ipu_in_ready     : fpu_in_ready;
  assign result       = state_q == VFU_RunningIPU ? ipu_result       : fpu_result;
  assign result_valid = state_q == VFU_RunningIPU ? ipu_result_valid : fpu_result_valid;

  assign scalar_result = result[ELEN-1:0];

  always_comb begin : dimc_proc
	    dimc_state_d      = dimc_state_q;
    dimc_request_released_d = dimc_request_released_q;
	    dimc_section_d    = dimc_section_q;
	    dimc_row_d        = dimc_row_q;
	    dimc_init_count_d = dimc_init_count_q;
	    dimc_capture_count_d = dimc_capture_count_q;
	    dimc_result_d     = dimc_result_q;
	    dimc_tail_capture_count_d = dimc_tail_capture_count_q;
	    dimc_tail_result_d = dimc_tail_result_q;
	    dimc_wb_pending_d = dimc_wb_pending_q;
	    dimc_wb_id_d      = dimc_wb_id_q;
	    dimc_wb_base_addr_d = dimc_wb_base_addr_q;
	    dimc_wb_word_d    = dimc_wb_word_q;
	    dimc_wb_last_word_d = dimc_wb_last_word_q;
	    dimc_wb_result_d  = dimc_wb_result_q;
	    dimc_tail_pending_d = dimc_tail_pending_q;
	    dimc_tail_done_pending_d = dimc_tail_done_pending_q;
	    dimc_tail_id_d = dimc_tail_id_q;
	    dimc_tail_base_addr_d = dimc_tail_base_addr_q;
	    dimc_tail_first_word_d = dimc_tail_first_word_q;
	    dimc_tail_last_word_d = dimc_tail_last_word_q;
	    dimc_tail_row_limit_d = dimc_tail_row_limit_q;
	    dimc_tail_row_offset_d = dimc_tail_row_offset_q;
    dimc_active_id_d = dimc_active_id_q;
    dimc_active_vs1_d = dimc_active_vs1_q;
    dimc_active_vs2_d = dimc_active_vs2_q;
    dimc_active_vd_d = dimc_active_vd_q;
    dimc_active_vl_d = dimc_active_vl_q;
    dimc_active_cfg_d = dimc_active_cfg_q;

    dimc_instr_done      = 1'b0;
    dimc_load_feature    = !dimc_active_cfg_q.feature_reuse;
    dimc_vrf_read_feature = 1'b0;
    dimc_vrf_read_kernel  = 1'b0;
    dimc_vrf_read_upper   = 1'b0;
    dimc_compute_fire     = 1'b0;
    dimc_handoff_tail     = 1'b0;

    if (dimc_wb_pending_q && dimc_wb_accept) begin
      if (dimc_wb_word_q == dimc_wb_last_word_q) begin
        dimc_wb_pending_d = 1'b0;
      end else begin
        dimc_wb_word_d = dimc_wb_word_q + 1'b1;
      end
    end

    if (dimc_tail_done_pending_q && dimc_wb_can_enqueue) begin
      dimc_wb_pending_d        = 1'b1;
      dimc_wb_id_d             = dimc_tail_id_q;
      dimc_wb_base_addr_d      = dimc_tail_base_addr_q;
      dimc_wb_word_d           = dimc_tail_first_word_q;
      dimc_wb_last_word_d      = dimc_tail_last_word_q;
      dimc_wb_result_d         = dimc_tail_result_q;
      dimc_tail_done_pending_d = 1'b0;
    end

    dimc_row_limit   = DimcVqmmaccRows;
    dimc_kernel_vreg = vreg_t'(dimc_active_vs2_q + dimc_row_q);
    dimc_result_word = {8'b0, dimc_psout};

    dimc_feature_addr = vrf_addr_t'((int'(dimc_active_vs1_q) * NrWordsPerVector) +
	                                    (int'(dimc_section_q) * DimcWordsPerSection));
    dimc_kernel_addr  = vrf_addr_t'((int'(dimc_kernel_vreg) * NrWordsPerVector) +
	                                    (int'(dimc_section_q) * DimcWordsPerSection));
    dimc_upper_addr   = '0;
    dimc_result_base_addr = vrf_addr_t'(int'(dimc_active_vd_q) * NrWordsPerVector);
    dimc_result_row_offset = dimc_active_cfg_q.ci[2] ? 5'd8 : 5'd0;
    dimc_first_write_word  = dimc_active_cfg_q.ci[2] ?
                             DimcWriteIdxWidth'(DimcVqmmaccWords) : '0;
    dimc_last_write_word   = dimc_first_write_word;
    dimc_capture_row_limit = dimc_tail_pending_q ? dimc_tail_row_limit_q : dimc_row_limit;
    dimc_capture_row_offset = dimc_tail_pending_q ? dimc_tail_row_offset_q : dimc_result_row_offset;
    dimc_capture_id = dimc_tail_pending_q ? dimc_tail_id_q : dimc_active_id_q;
    dimc_capture_base_addr = dimc_tail_pending_q ? dimc_tail_base_addr_q : dimc_result_base_addr;
    dimc_capture_first_write_word =
        dimc_tail_pending_q ? dimc_tail_first_word_q : dimc_first_write_word;
    dimc_capture_last_write_word =
        dimc_tail_pending_q ? dimc_tail_last_word_q : dimc_last_write_word;
    dimc_result_index = dimc_capture_row_offset + dimc_capture_row;

    dimc_compe = 1'b0;
    dimc_fcsn  = 1'b1;
    dimc_mode  = dimc_active_cfg_q.ci[1:0];
    dimc_fa    = 2'(dimc_section_q);
    dimc_fd    = '0;
    dimc_addin = '0;
    dimc_d     = '0;
    dimc_ra    = {dimc_kernel_vreg, 2'b00};
    dimc_wa    = {dimc_kernel_vreg, 2'(dimc_section_q)};
    dimc_rcsn  = 1'b1;
    dimc_rcsn0 = 1'b1;
    dimc_rcsn1 = 1'b1;
    dimc_rcsn2 = 1'b1;
    dimc_rcsn3 = 1'b1;
    dimc_wcsn  = 1'b1;
    dimc_wen   = 1'b1;
    dimc_mask  = '1;
    dimc_mct   = dimc_active_mct;

    unique case (dimc_state_q)
      DimcIdle: ; // Initial issue and final-row turnover share the launch below.

      DimcLoadFeature: begin
        dimc_fa = 2'(dimc_section_q);
        if (int'(dimc_section_q) < DimcSections) begin
          dimc_vrf_read_feature = dimc_read_grant;
          dimc_vrf_read_upper   = dimc_read_grant && DimcWordsPerSection > 1;
          dimc_upper_addr       = dimc_feature_addr + 1'b1;
          dimc_fd               = {vrf_rdata_i[2], vrf_rdata_i[1]};
          dimc_fcsn             = ~(dimc_read_grant && vrf_rvalid_i[1] &&
                                    (!dimc_vrf_read_upper || vrf_rvalid_i[2]));
          if (dimc_read_grant && vrf_rvalid_i[1] && (!dimc_vrf_read_upper || vrf_rvalid_i[2])) begin
            if (dimc_section_q == DimcSectionIdxWidth'(DimcSections - 1)) begin
              dimc_section_d = '0;
              dimc_state_d   = dimc_active_cfg_q.kernel_load ? DimcLoadKernel : DimcComputeInit;
            end else begin
              dimc_section_d = dimc_section_q + 1'b1;
            end
          end
        end else begin
          dimc_fd   = '0;
          dimc_fcsn = 1'b0;
          if (dimc_section_q == DimcSectionIdxWidth'(DimcSections - 1)) begin
            dimc_section_d = '0;
            dimc_state_d   = dimc_active_cfg_q.kernel_load ? DimcLoadKernel : DimcComputeInit;
          end else begin
            dimc_section_d = dimc_section_q + 1'b1;
          end
        end
      end

      DimcLoadKernel: begin
        dimc_wa = {dimc_kernel_vreg, 2'(dimc_section_q)};
        if (int'(dimc_section_q) < DimcSections) begin
          dimc_vrf_read_kernel = dimc_read_grant;
          dimc_vrf_read_upper  = dimc_read_grant && DimcWordsPerSection > 1;
          dimc_upper_addr      = dimc_kernel_addr + 1'b1;
          dimc_d               = {vrf_rdata_i[2], vrf_rdata_i[0]};
          dimc_wcsn            = ~(dimc_read_grant && vrf_rvalid_i[0] &&
                                   (!dimc_vrf_read_upper || vrf_rvalid_i[2]));
          dimc_wen             = ~(dimc_read_grant && vrf_rvalid_i[0] &&
                                   (!dimc_vrf_read_upper || vrf_rvalid_i[2]));
          if (dimc_read_grant && vrf_rvalid_i[0] && (!dimc_vrf_read_upper || vrf_rvalid_i[2])) begin
            if (dimc_section_q == DimcSectionIdxWidth'(DimcSections - 1)) begin
              dimc_section_d = '0;
              if (dimc_row_q == dimc_row_limit - 1'b1) begin
                dimc_row_d   = '0;
	                dimc_state_d = dimc_active_cfg_q.feature_reuse
	                                   ? DimcComputeIssue
	                                   : DimcComputeInit;
              end else begin
                dimc_row_d = dimc_row_q + 1'b1;
              end
            end else begin
              dimc_section_d = dimc_section_q + 1'b1;
            end
          end
        end else begin
          dimc_d    = '0;
          dimc_wcsn = 1'b0;
          dimc_wen  = 1'b0;
          if (dimc_section_q == DimcSectionIdxWidth'(DimcSections - 1)) begin
            dimc_section_d = '0;
            if (dimc_row_q == dimc_row_limit - 1'b1) begin
              dimc_row_d   = '0;
	              dimc_state_d = dimc_active_cfg_q.feature_reuse
	                                 ? DimcComputeIssue
	                                 : DimcComputeInit;
            end else begin
              dimc_row_d = dimc_row_q + 1'b1;
            end
          end else begin
            dimc_section_d = dimc_section_q + 1'b1;
          end
        end
      end

      DimcComputeInit: begin
        if (dimc_init_count_q == DimcInitCountWidth'(DimcInitCycles - 1)) begin
          dimc_init_count_d = '0;
          dimc_state_d      = DimcComputeIssue;
        end else begin
          dimc_init_count_d = dimc_init_count_q + 1'b1;
        end
      end

      DimcComputeIssue: begin
        if (dimc_row_q == '0) begin
          dimc_capture_count_d = '0;
          dimc_result_d        = '{default: '0};
        end
        dimc_compute_fire = 1'b1;
        dimc_compe = 1'b1;
        dimc_ra    = {dimc_kernel_vreg, 2'b00};
        dimc_rcsn  = 1'b0;
        dimc_rcsn0 = 1'b0;
        dimc_rcsn1 = 1'b0;
        dimc_rcsn2 = 1'b0;
        dimc_rcsn3 = 1'b0;
        if (dimc_row_q == dimc_row_limit - 2 && !dimc_request_released_q) begin
          dimc_instr_done = 1'b1;
          dimc_request_released_d = 1'b1;
        end
        if (dimc_row_q == dimc_row_limit - 1'b1) begin
          dimc_row_d                = '0;
          dimc_state_d              = DimcIdle;
          if (!dimc_capture_complete) begin
            dimc_tail_pending_d       = 1'b1;
            dimc_tail_id_d            = dimc_active_id_q;
            dimc_tail_base_addr_d     = dimc_result_base_addr;
            dimc_tail_first_word_d    = dimc_first_write_word;
            dimc_tail_last_word_d     = dimc_last_write_word;
            dimc_tail_row_limit_d     = dimc_row_limit;
            dimc_tail_row_offset_d    = dimc_result_row_offset;
            dimc_handoff_tail         = 1'b1;
            dimc_instr_done           = !dimc_request_released_q;
          end
        end else begin
          dimc_row_d = dimc_row_q + 1'b1;
        end
		      end

      DimcWriteResult: begin
	        if (dimc_wb_can_enqueue) begin
	          dimc_wb_pending_d   = 1'b1;
	          dimc_wb_id_d        = dimc_active_id_q;
	          dimc_wb_base_addr_d = dimc_result_base_addr;
	          dimc_wb_word_d      = dimc_first_write_word;
	          dimc_wb_last_word_d = dimc_last_write_word;
	          dimc_wb_result_d    = dimc_result_q;
	          dimc_state_d        = DimcIdle;
            dimc_instr_done     = !dimc_request_released_q;
	        end
	      end

      default: dimc_state_d = DimcIdle;
    endcase

    if (dimc_capture_valid && (dimc_state_q == DimcComputeIssue || dimc_tail_pending_q)) begin
      for (int unsigned word = 0; word < DimcResultWords; word++) begin
        for (int unsigned slot = 0; slot < DimcResultsPerWord; slot++) begin
          if (dimc_result_index == 5'(word * DimcResultsPerWord + slot)) begin
            if (dimc_tail_pending_q) begin
              dimc_tail_result_d[word][32*slot +: 32] = dimc_result_word;
            end else begin
              dimc_result_d[word][32*slot +: 32] = dimc_result_word;
            end
          end
        end
      end

      if (dimc_capture_row == dimc_capture_row_limit - 1'b1) begin
        if (dimc_tail_pending_q) begin
          dimc_tail_capture_count_d = '0;
        end else begin
          dimc_capture_count_d = '0;
        end
        if (dimc_wb_can_enqueue) begin
          dimc_wb_pending_d   = !dimc_wb_write_through_accept ||
                                (dimc_capture_first_write_word !=
                                 dimc_capture_last_write_word);
          dimc_wb_id_d        = dimc_capture_id;
          dimc_wb_base_addr_d = dimc_capture_base_addr;
          dimc_wb_word_d      = dimc_wb_write_through_accept &&
                                (dimc_capture_first_write_word !=
                                 dimc_capture_last_write_word)
                                  ? dimc_capture_first_write_word + 1'b1
                                  : dimc_capture_first_write_word;
          dimc_wb_last_word_d = dimc_capture_last_write_word;
          dimc_wb_result_d    = dimc_tail_pending_q ? dimc_tail_result_d : dimc_result_d;
          if (dimc_tail_pending_q) begin
            dimc_tail_pending_d = 1'b0;
          end else begin
            dimc_state_d        = DimcIdle;
            dimc_instr_done     = !dimc_request_released_q;
          end
        end else begin
          if (dimc_tail_pending_q) begin
            dimc_tail_pending_d      = 1'b0;
            dimc_tail_done_pending_d = 1'b1;
          end else begin
            dimc_state_d             = DimcWriteResult;
          end
        end
      end else begin
        if (dimc_tail_pending_q) begin
          dimc_tail_capture_count_d = dimc_tail_capture_count_q + 1'b1;
        end else begin
          dimc_capture_count_d = dimc_capture_count_q + 1'b1;
        end
      end
    end

    if (dimc_handoff_tail) begin
      dimc_tail_capture_count_d = dimc_capture_count_d;
      dimc_tail_result_d        = dimc_result_d;
    end

    if (dimc_start) begin
      dimc_section_d = '0;
      dimc_row_d = '0;
      dimc_init_count_d = '0;
      dimc_capture_count_d = '0;
      dimc_request_released_d = 1'b0;
      dimc_active_id_d  = dimc_req.id;
      dimc_active_vs1_d = dimc_req.vs1;
      dimc_active_vs2_d = dimc_req.vs2;
      dimc_active_vd_d  = dimc_req.vd;
      dimc_active_vl_d  = dimc_req.vl;
      dimc_active_cfg_d = dimc_req.op_cfg.dimc;
      // Do not clear dimc_result_d here: a turnover may be writing the old
      // instruction's final word through to VRF in this same cycle. Row zero
      // clears the accumulator when the next computation actually starts.
      if (!dimc_req.op_cfg.dimc.feature_reuse)
        dimc_state_d = DimcLoadFeature;
      else if (dimc_req.op_cfg.dimc.kernel_load)
        dimc_state_d = DimcLoadKernel;
      else
        dimc_state_d = DimcComputeIssue;
    end
  end : dimc_proc

  ///////////////////////
  //  Reduction logic  //
  ///////////////////////

  // Reduction pointer
  vlen_t reduction_pointer_d, reduction_pointer_q;
  `FF(reduction_pointer_q, reduction_pointer_d, '0)

  // Are the reduction operands ready?
  `FF(reduction_operand_ready_q, reduction_operand_ready_d, 1'b0)

  // Do we need to request reduction operands?
  logic [1:0] reduction_operand_request;

  always_comb begin: proc_reduction
    // Maintain state
    reduction_state_d   = reduction_state_q;
    reduction_pointer_d = reduction_pointer_q;

    // No operands
    reduction_d               = reduction_q;
    reduction_operand_ready_d = 1'b0;

    // Did we issue a word to the FUs?
    word_issued = 1'b0;

    // Are we ready to accept a result?
    result_ready = 1'b0;

    // Reduction did not finish
    reduction_done = 1'b0;

    // Only request when initializing the reduction register
    reduction_operand_request[0] = (reduction_state_q == Reduction_Init) || !spatz_req.op_arith.is_reduction;
    reduction_operand_request[1] = (reduction_state_q inside {Reduction_Init, Reduction_Reduce}) || !spatz_req.op_arith.is_reduction;

    unique case (reduction_state_q)
      Reduction_NormalExecution: begin
        // Did we issue a word to the FUs?
        word_issued = spatz_req_valid && &(in_ready | ~valid_operations) && operands_ready && !stall;

        // Are we ready to accept a result?
        // Retain the normal unit's result and tag while DIMC owns the port.
        result_ready = !dimc_write_grant &&
                       &(result_valid | ~pending_results) &&
                       (result_tag.wb ? vfu_rsp_ready_i : vrf_wvalid_i);

        // Initialize the pointers
        reduction_pointer_d = '0;

        // Do we have a new reduction instruction?
        if (spatz_req_valid && !stall && !running_q[spatz_req.id] && spatz_req.op_arith.is_reduction)
          reduction_state_d = is_fpu_busy ? Reduction_Wait : Reduction_Init;
      end

      Reduction_Wait: begin
        // Are we ready to accept a result?
        result_ready = !dimc_write_grant && &(result_valid | ~pending_results) &&
                       (result_tag.wb ? vfu_rsp_ready_i : vrf_wvalid_i);

        if (!is_fpu_busy)
          reduction_state_d = Reduction_Init;
      end

      Reduction_Init: begin
        // Initialize the reduction
        // verilator lint_off SELRANGE
        unique case (spatz_req.vtype.vsew)
          EW_8 : begin
            reduction_d[0] = $unsigned(vrf_rdata_i[0][7:0]);
            reduction_d[1] = $unsigned(vrf_rdata_i[1][8*reduction_pointer_q[idx_width(N_FU*ELENB)-1:0] +: 8]);
          end
          EW_16: begin
            reduction_d[0] = $unsigned(vrf_rdata_i[0][15:0]);
            reduction_d[1] = $unsigned(vrf_rdata_i[1][16*reduction_pointer_q[idx_width(N_FU*ELENB)-2:0] +: 16]);
          end
          EW_32: begin
            reduction_d[0] = $unsigned(vrf_rdata_i[0][31:0]);
            reduction_d[1] = $unsigned(vrf_rdata_i[1][32*reduction_pointer_q[idx_width(N_FU*ELENB)-3:0] +: 32]);
          end
          default: begin
          `ifdef MEMPOOL_SPATZ
            reduction_d = '0;
          `else
            if (MAXEW == EW_64) begin
              reduction_d[0] = $unsigned(vrf_rdata_i[0][63:0]);
              reduction_d[1] = $unsigned(vrf_rdata_i[1][64*reduction_pointer_q[idx_width(N_FU*ELENB)-4:0] +: 64]);
            end
          `endif
          end
        endcase
        // verilator lint_on SELRANGE

        if (vrf_rvalid_i[0] && vrf_rvalid_i[1]) begin
          automatic logic [idx_width(N_FU*ELENB)-1:0] pnt;

          reduction_operand_ready_d = 1'b1;
          reduction_pointer_d       = reduction_pointer_q + 1;
          reduction_state_d         = Reduction_Reduce;

          // Request next word
          pnt = reduction_pointer_d << int'(spatz_req.vtype.vsew);
          if (!(|pnt))
            word_issued = 1'b1;
        end
      end

      Reduction_Reduce: begin
        // Forward result
        // verilator lint_off SELRANGE
        unique case (spatz_req.vtype.vsew)
          EW_8 : begin
            reduction_d[0] = $unsigned(result[7:0]);
            reduction_d[1] = $unsigned(vrf_rdata_i[1][8*reduction_pointer_q[idx_width(N_FU*ELENB)-1:0] +: 8]);
          end
          EW_16: begin
            reduction_d[0] = $unsigned(result[15:0]);
            reduction_d[1] = $unsigned(vrf_rdata_i[1][16*reduction_pointer_q[idx_width(N_FU*ELENB)-2:0] +: 16]);
          end
          EW_32: begin
            reduction_d[0] = $unsigned(result[31:0]);
            reduction_d[1] = $unsigned(vrf_rdata_i[1][32*reduction_pointer_q[idx_width(N_FU*ELENB)-3:0] +: 32]);
          end
          default: begin
          `ifdef MEMPOOL_SPATZ
            reduction_d = '0;
          `else
            if (MAXEW == EW_64) begin
              reduction_d[0] = $unsigned(result[63:0]);
              reduction_d[1] = $unsigned(vrf_rdata_i[1][64*reduction_pointer_q[idx_width(N_FU*ELENB)-4:0] +: 64]);
            end
          `endif
          end
        endcase
        // verilator lint_on SELRANGE

        // Got a result!
        if (result_valid[0]) begin
          // Did we get an operand?
          if (vrf_rvalid_i[1]) begin
            automatic logic [idx_width(N_FU*ELENB)-1:0] pnt;

            // Bump pointer
            reduction_pointer_d = reduction_pointer_q + 1;

            // Acknowledge result
            result_ready = 1'b1;

            // Trigger a request
            reduction_operand_ready_d = 1'b1;

            // Request next word
            pnt = reduction_pointer_d << int'(spatz_req.vtype.vsew);
            if (!(|pnt))
              word_issued = 1'b1;
          end
        end

        // Are we done?
        if (reduction_pointer_q == spatz_req.vl) begin
          reduction_state_d         = Reduction_WriteBack;
          result_ready              = 1'b0;
          reduction_operand_ready_d = 1'b0;
        end
      end

      Reduction_WriteBack: begin
        // Acknowledge result
        if (vrf_wvalid_i) begin
          result_ready = 1'b1;

          // We are done with the reduction
          reduction_state_d = Reduction_NormalExecution;

          // Finish the reduction
          reduction_done = 1'b1;
        end
      end

      default;
    endcase
  end: proc_reduction

  ///////////////////////
  // Operand Requester //
  ///////////////////////

  vrf_be_t       vreg_wbe;
  logic          vreg_we;
  logic    [2:0] vreg_r_req;

  // Address register
  vrf_addr_t [2:0] vreg_addr_q, vreg_addr_d;
  `FF(vreg_addr_q, vreg_addr_d, '0)

  // Calculate new vector register address
  always_comb begin : vreg_addr_proc
    vreg_addr_d = vreg_addr_q;

    vrf_raddr_o = vreg_addr_d;
    vrf_waddr_o = dimc_write_grant ? dimc_write_addr : result_tag.vd_addr;

    // Tag (propagated with the operations)
    input_tag = '{
      id             : spatz_req.id,
      vsew           : spatz_req.vtype.vsew,
      vstart         : spatz_req.vstart,
      vd_addr        : spatz_req.op_arith.is_scalar ? vrf_addr_t'(spatz_req.rd) : vreg_addr_q[2],
      wb             : spatz_req.op_arith.is_scalar,
      last           : last_request,
      narrowing      : spatz_req.op_arith.is_narrowing,
      narrowing_upper: narrowing_upper_q,
      reduction      : spatz_req.op_arith.is_reduction
    };

    if (spatz_req_valid && vl_q == '0) begin
      vreg_addr_d[0] = (spatz_req.vs2 + vstart) << $clog2(NrWordsPerVector);
      vreg_addr_d[1] = (spatz_req.vs1 + vstart) << $clog2(NrWordsPerVector);
      vreg_addr_d[2] = (spatz_req.vd + vstart) << $clog2(NrWordsPerVector);

      // Direct feedthrough
      vrf_raddr_o = vreg_addr_d;
      if (!spatz_req.op_arith.is_scalar)
        input_tag.vd_addr = vreg_addr_d[2];

      // Did we commit a word already?
      if (word_issued) begin
        vreg_addr_d[0] = vreg_addr_d[0] + (!spatz_req.op_arith.widen_vs2 || widening_upper_q);
        vreg_addr_d[1] = vreg_addr_d[1] + (!spatz_req.op_arith.widen_vs1 || widening_upper_q);
        vreg_addr_d[2] = vreg_addr_d[2] + (!spatz_req.op_arith.is_reduction && (!spatz_req.op_arith.is_narrowing || narrowing_upper_q));
      end
    end else if (spatz_req_valid && vl_q < spatz_req.vl && word_issued) begin
      vreg_addr_d[0] = vreg_addr_q[0] + (!spatz_req.op_arith.widen_vs2 || widening_upper_q);
      vreg_addr_d[1] = vreg_addr_q[1] + (!spatz_req.op_arith.widen_vs1 || widening_upper_q);
      vreg_addr_d[2] = vreg_addr_q[2] + (!spatz_req.op_arith.is_reduction && (!spatz_req.op_arith.is_narrowing || narrowing_upper_q));
    end

    if (dimc_vrf_read_feature)
      vrf_raddr_o[1] = dimc_feature_addr;
    if (dimc_vrf_read_kernel)
      vrf_raddr_o[0] = dimc_kernel_addr;
    if (dimc_vrf_read_upper)
      vrf_raddr_o[2] = dimc_upper_addr;
  end: vreg_addr_proc

  always_comb begin : operand_req_proc
    vreg_r_req = '0;
    vreg_we    = '0;
    vreg_wbe   = '0;

    if (spatz_req_valid && vl_q < spatz_req.vl && !dimc_read_grant)
      // Request operands
      vreg_r_req = {spatz_req.vd_is_src, spatz_req.use_vs1 && reduction_operand_request[1], spatz_req.use_vs2 && reduction_operand_request[0]};

    // Got a new result
    if (&(result_valid | ~pending_results) && !result_tag.reduction) begin
      vreg_we  = !result_tag.wb;
      vreg_wbe = '1;

      if (result_tag.narrowing) begin
        // Only write half of the elements
        vreg_wbe = result_tag.narrowing_upper ? {{(N_FU*ELENB/2){1'b1}}, {(N_FU*ELENB/2){1'b0}}} : {{(N_FU*ELENB/2){1'b0}}, {(N_FU*ELENB/2){1'b1}}};
      end
    end

    // Reduction finished execution
    if (reduction_state_q == Reduction_WriteBack && result_valid[0]) begin
      vreg_we = 1'b1;
      unique case (spatz_req.vtype.vsew)
        EW_8 : vreg_wbe = 1'h1;
        EW_16: vreg_wbe = 2'h3;
        EW_32: vreg_wbe = 4'hf;
        default: if (MAXEW == EW_64) vreg_wbe = 8'hff;
      endcase
    end

    if (dimc_vrf_read_feature)
      vreg_r_req[1] = 1'b1;
    if (dimc_vrf_read_kernel)
      vreg_r_req[0] = 1'b1;
    if (dimc_vrf_read_upper)
      vreg_r_req[2] = 1'b1;

    if (dimc_write_grant) begin
      vreg_we  = 1'b1;
      vreg_wbe = '1;
    end
  end : operand_req_proc

  logic [N_FU*ELEN-1:0] vreg_wdata;
  always_comb begin: align_result
    vreg_wdata = dimc_write_grant ? dimc_write_data : result;

    // Realign results
    if (!dimc_write_grant && result_tag.narrowing) begin
      unique case (MAXEW)
        EW_64: begin
          if (RVD)
            for (int element = 0; element < N_FU; element++)
              vreg_wdata[32*element + (N_FU * ELEN * result_tag.narrowing_upper / 2) +: 32] = result[64*element +: 32];
        end
        EW_32: begin
          for (int element = 0; element < (MAXEW == EW_64 ? N_FU*2 : N_FU); element++)
            vreg_wdata[16*element + (N_FU * ELEN * result_tag.narrowing_upper / 2) +: 16] = result[32*element +: 16];
        end
        default:;
      endcase
    end
  end

  // Register file signals
  assign vrf_re_o    = vreg_r_req;
  assign vrf_we_o    = vreg_we;
  assign vrf_wbe_o   = vreg_wbe;
  assign vrf_wdata_o = vreg_wdata;
  always_comb begin
    vrf_id_o = {dimc_write_grant ? dimc_write_id : result_tag.id, {3{spatz_req.id}}};
    if (dimc_vrf_read_kernel)  vrf_id_o[0] = dimc_active_id_q;
    if (dimc_vrf_read_feature) vrf_id_o[1] = dimc_active_id_q;
    if (dimc_vrf_read_upper)   vrf_id_o[2] = dimc_active_id_q;
  end

  //////////
  // IPUs //
  //////////

  // If there are fewer IPUs than FPUs, pipeline the execution of the integer instructions
  logic     [N_IPU*ELENB-1:0] int_ipu_in_ready;
  logic     [N_IPU*ELEN-1:0]  int_ipu_operand1;
  logic     [N_IPU*ELEN-1:0]  int_ipu_operand2;
  logic     [N_IPU*ELEN-1:0]  int_ipu_operand3;
  logic     [N_IPU*ELEN-1:0]  int_ipu_result;
  vfu_tag_t [N_IPU-1:0]       int_ipu_result_tag;
  logic     [N_IPU*ELENB-1:0] int_ipu_result_valid;
  logic                       int_ipu_result_ready;
  logic     [N_IPU-1:0]       int_ipu_busy;

  // A serialized IPU can be idle while its assembled VRF word is still pending.
  assign is_ipu_busy = |int_ipu_busy || |ipu_result_valid;

  logic [N_FU*ELEN-1:0] ipu_wide_operand1, ipu_wide_operand2, ipu_wide_operand3;
  always_comb begin: gen_ipu_widening
    automatic logic [N_FU*ELEN/2-1:0] shift_operand1 = !widening_upper_q ? operand1[N_FU*ELEN/2-1:0] : operand1[N_FU*ELEN-1:N_FU*ELEN/2];
    automatic logic [N_FU*ELEN/2-1:0] shift_operand2 = !widening_upper_q ? operand2[N_FU*ELEN/2-1:0] : operand2[N_FU*ELEN-1:N_FU*ELEN/2];

    ipu_wide_operand1 = operand1;
    ipu_wide_operand2 = operand2;
    ipu_wide_operand3 = operand3;

    case (spatz_req.vtype.vsew)
      EW_32: begin
        for (int el = 0; el < N_FU; el++) begin
          if (spatz_req.op_arith.widen_vs1 && MAXEW == EW_64)
            ipu_wide_operand1[64*el +: 64] = spatz_req.op_arith.signed_vs1 ? {{32{shift_operand1[32*el+31]}}, shift_operand1[32*el +: 32]} : {32'b0, shift_operand1[32*el +: 32]};

          if (spatz_req.op_arith.widen_vs2 && MAXEW == EW_64)
            ipu_wide_operand2[64*el +: 64] = spatz_req.op_arith.signed_vs2 ? {{32{shift_operand2[32*el+31]}}, shift_operand2[32*el +: 32]} : {32'b0, shift_operand2[32*el +: 32]};
        end
      end
      EW_16: begin
        for (int el = 0; el < (MAXEW == EW_64 ? 2*N_FU : N_FU); el++) begin
          if (spatz_req.op_arith.widen_vs1)
            ipu_wide_operand1[32*el +: 32] = spatz_req.op_arith.signed_vs1 ? {{16{shift_operand1[16*el+15]}}, shift_operand1[16*el +: 16]} : {16'b0, shift_operand1[16*el +: 16]};

          if (spatz_req.op_arith.widen_vs2)
            ipu_wide_operand2[32*el +: 32] = spatz_req.op_arith.signed_vs2 ? {{16{shift_operand2[16*el+15]}}, shift_operand2[16*el +: 16]} : {16'b0, shift_operand2[16*el +: 16]};
        end
      end
      EW_8: begin
        for (int el = 0; el < (MAXEW == EW_64 ? 4*N_FU : 2*N_FU); el++) begin
          if (spatz_req.op_arith.widen_vs1)
            ipu_wide_operand1[16*el +: 16] = spatz_req.op_arith.signed_vs1 ? {{8{shift_operand1[8*el+7]}}, shift_operand1[8*el +: 8]} : {8'b0, shift_operand1[8*el +: 8]};

          if (spatz_req.op_arith.widen_vs2)
            ipu_wide_operand2[16*el +: 16] = spatz_req.op_arith.signed_vs2 ? {{8{shift_operand2[8*el+7]}}, shift_operand2[8*el +: 8]} : {8'b0, shift_operand2[8*el +: 8]};
        end
      end
      default:;
    endcase
  end: gen_ipu_widening

  if (N_IPU < N_FU) begin: gen_pipeline_ipu
    logic [N_FU*ELEN-1:0] ipu_result_d, ipu_result_q;
    logic [N_FU*ELENB-1:0] ipu_result_valid_q, ipu_result_valid_d;
    logic [idx_width(N_FU/N_IPU)-1:0] ipu_result_pnt_d, ipu_result_pnt_q;
    vfu_tag_t ipu_result_tag_d, ipu_result_tag_q;
    logic [idx_width(N_FU/N_IPU)-1:0] ipu_operand_pnt_d, ipu_operand_pnt_q;

    `FF(ipu_result_q, ipu_result_d, '0)
    `FF(ipu_result_valid_q, ipu_result_valid_d, '0)
    `FF(ipu_result_pnt_q, ipu_result_pnt_d, '0)
    `FF(ipu_result_tag_q, ipu_result_tag_d, '0)
    `FF(ipu_operand_pnt_q, ipu_operand_pnt_d, '0)

    always_comb begin
      // Maintain state
      ipu_result_d       = ipu_result_q;
      ipu_result_valid_d = ipu_result_valid_q;
      ipu_result_pnt_d   = ipu_result_pnt_q;
      ipu_operand_pnt_d  = ipu_operand_pnt_q;
      ipu_result_tag_d   = ipu_result_tag_q;

      // Send operands
      ipu_in_ready     = 1'b0;
      int_ipu_operand1 = ipu_wide_operand1[ipu_operand_pnt_q*ELEN*N_IPU +: ELEN*N_IPU];
      int_ipu_operand2 = ipu_wide_operand2[ipu_operand_pnt_q*ELEN*N_IPU +: ELEN*N_IPU];
      int_ipu_operand3 = ipu_wide_operand3[ipu_operand_pnt_q*ELEN*N_IPU +: ELEN*N_IPU];
      if (spatz_req_valid && operands_ready && &int_ipu_in_ready && !is_fpu_insn) begin
        ipu_operand_pnt_d = ipu_operand_pnt_q + 1;
        if (ipu_operand_pnt_d == '0 || !(&valid_operations[ipu_operand_pnt_d*ELENB*N_IPU +: ELENB*N_IPU]))
          ipu_operand_pnt_d = '0;

        // Issued all elements
        if (ipu_operand_pnt_d == 0)
          ipu_in_ready = '1;
      end

      // Clean-up results
      if (result_ready) begin
        ipu_result_d       = '0;
        ipu_result_valid_d = '0;
        ipu_result_tag_d   = '0;
      end

      // Store results
      int_ipu_result_ready = '0;
      // Hold a completed word when DIMC or VRF backpressure occupies the
      // write port. Do not overwrite its first slice with the next word.
      if (&int_ipu_result_valid &&
          (!(|ipu_result_valid_q[ipu_result_pnt_q*ELENB*N_IPU +: ELENB*N_IPU]) || result_ready)) begin
        ipu_result_d[ipu_result_pnt_q*ELEN*N_IPU +: ELEN*N_IPU]         = int_ipu_result;
        ipu_result_valid_d[ipu_result_pnt_q*ELENB*N_IPU +: ELENB*N_IPU] = int_ipu_result_valid;
        ipu_result_tag_d                                                = int_ipu_result_tag[0];
        ipu_result_pnt_d                                                = ipu_result_pnt_q + 1;
        int_ipu_result_ready                                            = 1'b1;

        // Scalar operation
        if (ipu_result_tag_d.wb || ipu_result_tag_d.reduction)
          ipu_result_pnt_d = '0;
      end
    end

    // Forward results
    assign ipu_result       = ipu_result_q;
    assign ipu_result_valid = ipu_result_valid_q;
    assign ipu_result_tag   = ipu_result_tag_q;
  end: gen_pipeline_ipu else begin: gen_no_pipeline_ipu
    assign ipu_in_ready         = int_ipu_in_ready;
    assign int_ipu_operand1     = ipu_wide_operand1;
    assign int_ipu_operand2     = ipu_wide_operand2;
    assign int_ipu_operand3     = ipu_wide_operand3;
    assign ipu_result           = int_ipu_result;
    assign ipu_result_valid     = int_ipu_result_valid;
    assign int_ipu_result_ready = result_ready;
    assign ipu_result_tag       = int_ipu_result_tag[0];
  end

  for (genvar ipu = 0; unsigned'(ipu) < N_IPU; ipu++) begin : gen_ipus
    logic ipu_ready;
    assign int_ipu_in_ready[ipu*ELENB +: ELENB] = {ELENB{ipu_ready}};

    logic is_widening;
    assign is_widening = spatz_req.op_arith.widen_vs1 || spatz_req.op_arith.widen_vs2;

    vew_e sew;
    assign sew = vew_e'(int'(spatz_req.vtype.vsew) + is_widening);

    spatz_ipu #(
      .tag_t(vfu_tag_t)
    ) i_ipu (
      .clk_i            (clk_i                                                                                           ),
      .rst_ni           (rst_ni                                                                                          ),
      .operation_i      (spatz_req.op                                                                                    ),
      // Only the IPU0 executes scalar instructions
      .operation_valid_i(spatz_req_valid && operands_ready && (!spatz_req.op_arith.is_scalar || ipu == 0) && !is_fpu_insn),
      .operation_ready_o(ipu_ready                                                                                       ),
      .op_s1_i          (int_ipu_operand1[ipu*ELEN +: ELEN]                                                              ),
      .op_s2_i          (int_ipu_operand2[ipu*ELEN +: ELEN]                                                              ),
      .op_d_i           (int_ipu_operand3[ipu*ELEN +: ELEN]                                                              ),
      .tag_i            (input_tag                                                                                       ),
      .carry_i          ('0                                                                                              ),
      .sew_i            (sew                                                                                             ),
      .be_o             (/* Unused */                                                                                    ),
      .result_o         (int_ipu_result[ipu*ELEN +: ELEN]                                                                ),
      .result_valid_o   (int_ipu_result_valid[ipu*ELENB +: ELENB]                                                        ),
      .result_ready_i   (int_ipu_result_ready                                                                            ),
      .tag_o            (int_ipu_result_tag[ipu]                                                                         ),
      .busy_o           (int_ipu_busy[ipu]                                                                               )
    );
  end : gen_ipus

  ////////////
  //  FPUs  //
  ////////////

  if (FPU) begin: gen_fpu
    operation_e fpu_op;
    fp_format_e fpu_src_fmt, fpu_dst_fmt;
    int_format_e fpu_int_fmt;
    logic fpu_op_mode;
    logic fpu_vectorial_op;

    // The FPU bank can be narrower than the shared VRF word (e.g. 1 FPU,
    // 4 IPUs). Serialize its input slices and gather a complete result word.
    logic [N_FPU*ELENB-1:0] lane_in_ready, lane_result_valid;
    logic [N_FPU*ELEN-1:0] lane_operand1, lane_operand2, lane_operand3, lane_result;
    vfu_tag_t [N_FPU-1:0] lane_result_tag;
    logic lane_result_ready, fpu_gather_busy;
    logic [N_FPU-1:0] fpu_stage_valid;

    logic [N_FPU-1:0] fpu_busy_d, fpu_busy_q;
    `FF(fpu_busy_q, fpu_busy_d, '0)

    status_t [N_FPU-1:0] fpu_status_d, fpu_status_q;
    `FF(fpu_status_q, fpu_status_d, '0)

    always_comb begin: gen_decoder
      fpu_op           = fpnew_pkg::FMADD;
      fpu_op_mode      = 1'b0;
      fpu_vectorial_op = 1'b0;
      is_fpu_busy      = |fpu_busy_q || |fpu_stage_valid || fpu_gather_busy;
      fpu_src_fmt      = fpnew_pkg::FP32;
      fpu_dst_fmt      = fpnew_pkg::FP32;
      fpu_int_fmt      = fpnew_pkg::INT32;

      fpu_status_o = '0;
      for (int fpu = 0; fpu < N_FPU; fpu++)
        fpu_status_o |= fpu_status_q[fpu];

      if (FPU) begin
        unique case (spatz_req.vtype.vsew)
          EW_64: begin
            if (RVD) begin
              fpu_src_fmt = fpnew_pkg::FP64;
              fpu_dst_fmt = fpnew_pkg::FP64;
              fpu_int_fmt = fpnew_pkg::INT64;
            end
          end
          EW_32: begin
            fpu_src_fmt      = spatz_req.op_arith.is_narrowing || spatz_req.op_arith.widen_vs1 || spatz_req.op_arith.widen_vs2 ? fpnew_pkg::FP64 : fpnew_pkg::FP32;
            fpu_dst_fmt      = spatz_req.op_arith.widen_vs1 || spatz_req.op_arith.widen_vs2 || spatz_req.op == VSDOTP ? fpnew_pkg::FP64          : fpnew_pkg::FP32;
            fpu_int_fmt      = spatz_req.op_arith.is_narrowing && spatz_req.op inside {VI2F, VU2F} ? fpnew_pkg::INT64                            : fpnew_pkg::INT32;
            fpu_vectorial_op = FLEN > 32;
          end
          EW_16: begin
            fpu_src_fmt      = spatz_req.op_arith.is_narrowing || spatz_req.op_arith.widen_vs1 || spatz_req.op_arith.widen_vs2 ? fpnew_pkg::FP32 : (spatz_req.fm.src ? fpnew_pkg::FP16ALT : fpnew_pkg::FP16);
            fpu_dst_fmt      = spatz_req.op_arith.widen_vs1 || spatz_req.op_arith.widen_vs2 || spatz_req.op == VSDOTP          ? fpnew_pkg::FP32 : (spatz_req.fm.dst ? fpnew_pkg::FP16ALT : fpnew_pkg::FP16);
            fpu_int_fmt      = spatz_req.op_arith.is_narrowing && spatz_req.op inside {VI2F, VU2F}                             ? fpnew_pkg::INT32 : fpnew_pkg::INT16;
            fpu_vectorial_op = 1'b1;
          end
          EW_8: begin
            fpu_src_fmt      = spatz_req.op_arith.is_narrowing || spatz_req.op_arith.widen_vs1 || spatz_req.op_arith.widen_vs2 ? (spatz_req.fm.src ? fpnew_pkg::FP16ALT : fpnew_pkg::FP16) : (spatz_req.fm.src ? fpnew_pkg::FP8ALT : fpnew_pkg::FP8);
            fpu_dst_fmt      = spatz_req.op_arith.widen_vs1 || spatz_req.op_arith.widen_vs2 || spatz_req.op == VSDOTP          ? (spatz_req.fm.dst ? fpnew_pkg::FP16ALT : fpnew_pkg::FP16) : (spatz_req.fm.dst ? fpnew_pkg::FP8ALT : fpnew_pkg::FP8);
            fpu_int_fmt      = spatz_req.op_arith.is_narrowing && spatz_req.op inside {VI2F, VU2F}                             ? fpnew_pkg::INT16 : fpnew_pkg::INT8;
            fpu_vectorial_op = 1'b1;
          end
          default:;
        endcase

        unique case (spatz_req.op)
          VFADD: fpu_op = fpnew_pkg::ADD;
          VFSUB: begin
            fpu_op      = fpnew_pkg::ADD;
            fpu_op_mode = 1'b1;
          end
          VFMUL  : fpu_op = fpnew_pkg::MUL;
          VFMADD : fpu_op = fpnew_pkg::FMADD;
          VFMSUB : begin
            fpu_op      = fpnew_pkg::FMADD;
            fpu_op_mode = 1'b1;
          end
          VFNMSUB: fpu_op = fpnew_pkg::FNMSUB;
          VFNMADD: begin
            fpu_op      = fpnew_pkg::FNMSUB;
            fpu_op_mode = 1'b1;
          end

          VFMINMAX: begin
            fpu_op = fpnew_pkg::MINMAX;
            fpu_dst_fmt = fpu_src_fmt;
          end


          VFSGNJ : begin
            fpu_op = fpnew_pkg::SGNJ;
            fpu_dst_fmt = fpu_src_fmt;
          end
          VFCLASS: begin
            fpu_op = fpnew_pkg::CLASSIFY;
            fpu_dst_fmt = fpu_src_fmt;
          end
          VFCMP  : begin
            fpu_op = fpnew_pkg::CMP;
            fpu_dst_fmt = fpu_src_fmt;
          end

          VF2F: fpu_op = fpnew_pkg::F2F;
          VF2I: fpu_op = fpnew_pkg::F2I;
          VF2U: begin
            fpu_op      = fpnew_pkg::F2I;
            fpu_op_mode = 1'b1;
          end
          VI2F: fpu_op = fpnew_pkg::I2F;
          VU2F: begin
            fpu_op      = fpnew_pkg::I2F;
            fpu_op_mode = 1'b1;
          end

          VSDOTP: fpu_op = fpnew_pkg::SDOTP;

          default:;
        endcase
      end
    end: gen_decoder

    logic [N_FU*ELEN-1:0] wide_operand1, wide_operand2, wide_operand3;
    always_comb begin: gen_widening
      automatic logic [N_FU*ELEN/2-1:0] shift_operand1 = !widening_upper_q ? operand1[N_FU*ELEN/2-1:0] : operand1[N_FU*ELEN-1:N_FU*ELEN/2];
      automatic logic [N_FU*ELEN/2-1:0] shift_operand2 = !widening_upper_q ? operand2[N_FU*ELEN/2-1:0] : operand2[N_FU*ELEN-1:N_FU*ELEN/2];

      wide_operand1 = operand1;
      wide_operand2 = operand2;
      wide_operand3 = operand3;

      case (spatz_req.vtype.vsew)
        EW_32: begin
          for (int el = 0; el < N_FU; el++) begin
            if (spatz_req.op_arith.widen_vs1 && MAXEW == EW_64)
              wide_operand1[64*el +: 64] = widen_fp32_to_fp64(shift_operand1[32*el +: 32]);

            if (spatz_req.op_arith.widen_vs2 && MAXEW == EW_64)
              wide_operand2[64*el +: 64] = widen_fp32_to_fp64(shift_operand2[32*el +: 32]);
          end
        end
        EW_16: begin
          for (int el = 0; el < (MAXEW == EW_64 ? 2*N_FU : N_FU); el++) begin
            if (spatz_req.op_arith.widen_vs1)
              wide_operand1[32*el +: 32] = widen_fp16_to_fp32(shift_operand1[16*el +: 16]);

            if (spatz_req.op_arith.widen_vs2)
              wide_operand2[32*el +: 32] = widen_fp16_to_fp32(shift_operand2[16*el +: 16]);
          end
        end
        EW_8: begin
          for (int el = 0; el < (MAXEW == EW_64 ? 4*N_FU : 2*N_FU); el++) begin
            if (spatz_req.op_arith.widen_vs1)
              wide_operand1[16*el +: 16] = widen_fp8_to_fp16(shift_operand1[8*el +: 8]);

            if (spatz_req.op_arith.widen_vs2)
              wide_operand2[16*el +: 16] = widen_fp8_to_fp16(shift_operand2[8*el +: 8]);
          end
        end
        default:;
      endcase
    end: gen_widening

    if (N_FPU < N_FU) begin: gen_pipeline_fpu
      logic [N_FU*ELEN-1:0] data_d, data_q;
      logic [N_FU*ELENB-1:0] valid_d, valid_q;
      logic [idx_width(N_FU/N_FPU)-1:0] input_pnt_d, input_pnt_q, output_pnt_d, output_pnt_q;
      vfu_tag_t tag_d, tag_q;
      `FF(data_q, data_d, '0)
      `FF(valid_q, valid_d, '0)
      `FF(input_pnt_q, input_pnt_d, '0)
      `FF(output_pnt_q, output_pnt_d, '0)
      `FF(tag_q, tag_d, '0)

      always_comb begin
        data_d = data_q;
        valid_d = valid_q;
        input_pnt_d = input_pnt_q;
        output_pnt_d = output_pnt_q;
        tag_d = tag_q;
        fpu_in_ready = '0;
        lane_operand1 = wide_operand1[input_pnt_q*N_FPU*ELEN +: N_FPU*ELEN];
        lane_operand2 = wide_operand2[input_pnt_q*N_FPU*ELEN +: N_FPU*ELEN];
        lane_operand3 = wide_operand3[input_pnt_q*N_FPU*ELEN +: N_FPU*ELEN];
        if (spatz_req_valid && operands_ready && &lane_in_ready && is_fpu_insn) begin
          input_pnt_d = input_pnt_q + 1'b1;
          if (input_pnt_d == '0 || !(&valid_operations[input_pnt_d*N_FPU*ELENB +: N_FPU*ELENB]))
            input_pnt_d = '0;
          if (input_pnt_d == '0) fpu_in_ready = '1;
        end

        if (result_ready) begin
          data_d = '0;
          valid_d = '0;
          tag_d = '0;
        end
        lane_result_ready = 1'b0;
        if (&lane_result_valid &&
            (!(|valid_q[output_pnt_q*N_FPU*ELENB +: N_FPU*ELENB]) || result_ready)) begin
          data_d[output_pnt_q*N_FPU*ELEN +: N_FPU*ELEN] = lane_result;
          valid_d[output_pnt_q*N_FPU*ELENB +: N_FPU*ELENB] = lane_result_valid;
          tag_d = lane_result_tag[0];
          output_pnt_d = output_pnt_q + 1'b1;
          lane_result_ready = 1'b1;
          if (tag_d.wb || tag_d.reduction) output_pnt_d = '0;
        end
      end
      assign fpu_result = data_q;
      assign fpu_result_valid = valid_q;
      assign fpu_result_tag = tag_q;
      assign fpu_gather_busy = |valid_q || input_pnt_q != '0;
    end else begin: gen_no_pipeline_fpu
      assign fpu_in_ready = lane_in_ready;
      assign lane_operand1 = wide_operand1;
      assign lane_operand2 = wide_operand2;
      assign lane_operand3 = wide_operand3;
      assign fpu_result = lane_result;
      assign fpu_result_valid = lane_result_valid;
      assign fpu_result_tag = lane_result_tag[0];
      assign lane_result_ready = result_ready;
      assign fpu_gather_busy = 1'b0;
    end

    for (genvar fpu = 0; unsigned'(fpu) < N_FPU; fpu++) begin : gen_fpnew
      logic int_fpu_result_valid;
      logic int_fpu_in_ready;
      vfu_tag_t tag;

      assign lane_in_ready[fpu*ELENB +: ELENB]     = {ELENB{int_fpu_in_ready}};
      assign lane_result_valid[fpu*ELENB +: ELENB] = {ELENB{int_fpu_result_valid}};
      assign lane_result_tag[fpu] = tag;

      elen_t fpu_operand1, fpu_operand2, fpu_operand3;
      assign fpu_operand1 = spatz_req.op_arith.switch_rs1_rd ? lane_operand3[fpu*ELEN +: ELEN] : lane_operand1[fpu*ELEN +: ELEN];
      assign fpu_operand2 = lane_operand2[fpu*ELEN +: ELEN];
      assign fpu_operand3 = (fpu_op == fpnew_pkg::ADD || spatz_req.op_arith.switch_rs1_rd) ? lane_operand1[fpu*ELEN +: ELEN] : lane_operand3[fpu*ELEN +: ELEN];

      logic int_fpu_in_valid;
      assign int_fpu_in_valid = spatz_req_valid && operands_ready && (!spatz_req.op_arith.is_scalar || fpu == 0) && is_fpu_insn;

      // Generate an FPU pipeline
      elen_t fpu_operand1_q, fpu_operand2_q, fpu_operand3_q;
      operation_e fpu_op_q;
      fp_format_e fpu_src_fmt_q, fpu_dst_fmt_q;
      int_format_e fpu_int_fmt_q;
      logic fpu_op_mode_q;
      logic fpu_vectorial_op_q;
      roundmode_e rm_q;
      vfu_tag_t input_tag_q;
      logic fpu_in_valid_q;
      logic fpu_in_ready_d;
      assign fpu_stage_valid[fpu] = fpu_in_valid_q;

      `FFL(fpu_operand1_q, fpu_operand1, int_fpu_in_valid && int_fpu_in_ready, '0)
      `FFL(fpu_operand2_q, fpu_operand2, int_fpu_in_valid && int_fpu_in_ready, '0)
      `FFL(fpu_operand3_q, fpu_operand3, int_fpu_in_valid && int_fpu_in_ready, '0)
      `FFL(fpu_op_q, fpu_op, int_fpu_in_valid && int_fpu_in_ready, fpnew_pkg::FMADD)
      `FFL(fpu_src_fmt_q, fpu_src_fmt, int_fpu_in_valid && int_fpu_in_ready, fpnew_pkg::FP32)
      `FFL(fpu_dst_fmt_q, fpu_dst_fmt, int_fpu_in_valid && int_fpu_in_ready, fpnew_pkg::FP32)
      `FFL(fpu_int_fmt_q, fpu_int_fmt, int_fpu_in_valid && int_fpu_in_ready, fpnew_pkg::INT8)
      `FFL(fpu_op_mode_q, fpu_op_mode, int_fpu_in_valid && int_fpu_in_ready, 1'b0)
      `FFL(fpu_vectorial_op_q, fpu_vectorial_op, int_fpu_in_valid && int_fpu_in_ready, 1'b0)
      `FFL(rm_q, spatz_req.rm, int_fpu_in_valid && int_fpu_in_ready, fpnew_pkg::RNE)
      `FFL(input_tag_q, input_tag, int_fpu_in_valid && int_fpu_in_ready, '{vsew: EW_8, default: '0})
      `FFL(fpu_in_valid_q, int_fpu_in_valid, int_fpu_in_ready, 1'b0)
      assign int_fpu_in_ready = !fpu_in_valid_q || fpu_in_valid_q && fpu_in_ready_d;

      fpnew_top #(
        .Features                   (FPUFeatures           ),
        .Implementation             (FPUImplementation     ),
        .TagType                    (vfu_tag_t             ),
        .StochasticRndImplementation(fpnew_pkg::DEFAULT_RSR)
      ) i_fpu (
        .clk_i         (clk_i                                                  ),
        .rst_ni        (rst_ni                                                 ),
        .hart_id_i     ((hart_id_i << $clog2(N_FPU)) | 32'(fpu)),
        .flush_i       (1'b0                                                   ),
        .busy_o        (fpu_busy_d[fpu]                                        ),
        .operands_i    ({fpu_operand3_q, fpu_operand2_q, fpu_operand1_q}       ),
        // Only the FPU0 executes scalar instructions
        .in_valid_i    (fpu_in_valid_q                                         ),
        .in_ready_o    (fpu_in_ready_d                                         ),
        .op_i          (fpu_op_q                                               ),
        .src_fmt_i     (fpu_src_fmt_q                                          ),
        .dst_fmt_i     (fpu_dst_fmt_q                                          ),
        .int_fmt_i     (fpu_int_fmt_q                                          ),
        .vectorial_op_i(fpu_vectorial_op_q                                     ),
        .op_mod_i      (fpu_op_mode_q                                          ),
        .tag_i         (input_tag_q                                            ),
        .simd_mask_i   ('1                                                     ),
        .rnd_mode_i    (rm_q                                                   ),
        .result_o      (lane_result[fpu*ELEN +: ELEN]                          ),
        .out_valid_o   (int_fpu_result_valid                                   ),
        .out_ready_i   (lane_result_ready                                      ),
        .status_o      (fpu_status_d[fpu]                                      ),
        .tag_o         (tag                                                    )
      );

    end : gen_fpnew
  end: gen_fpu else begin: gen_no_fpu
    assign is_fpu_busy      = 1'b0;
    assign fpu_in_ready     = '0;
    assign fpu_result       = '0;
    assign fpu_result_valid = '0;
    assign fpu_result_tag   = '0;
    assign fpu_status_o     = '0;
  end: gen_no_fpu

  if (DimcSectionWidth % VRFWordWidth != 0)
    $error("[spatz_vfu] DIMC section width must be an integer multiple of VRF word width.");

endmodule : spatz_vfu
