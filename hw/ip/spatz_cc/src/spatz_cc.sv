// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Matheus Cavalcante <matheusd@iis.ee.ethz.ch>

`include "common_cells/assertions.svh"
`include "common_cells/registers.svh"
`include "snitch_vm/typedef.svh"

/// Spatz Core Complex (CC)
/// Contains the Snitch Integer Core + Spatz Vector Unit
module spatz_cc
  import snitch_pkg::interrupts_t;
  import snitch_pkg::core_events_t;
  import fpnew_pkg::fpu_implementation_t; #(
    /// Address width of the buses
    parameter int                          unsigned        AddrWidth                = 0,
    /// Data width of the buses.
    parameter int                          unsigned        DataWidth                = 0,
    /// User width of the buses.
    parameter int                          unsigned        UserWidth                = 0,
    /// Data width of the AXI DMA buses.
    parameter int                          unsigned        DMADataWidth             = 0,
    /// Id width of the AXI DMA bus.
    parameter int                          unsigned        DMAIdWidth               = 0,
    parameter int                          unsigned        DMAAxiReqFifoDepth       = 0,
    parameter int                          unsigned        DMAReqFifoDepth          = 0,
    /// Data port request type.
    parameter type                                         dreq_t                   = logic,
    /// Data port response type.
    parameter type                                         drsp_t                   = logic,
    // TCDM port types
    parameter type                                         tcdm_req_t               = logic,
    parameter type                                         tcdm_req_chan_t          = logic,
    parameter type                                         tcdm_rsp_t               = logic,
    parameter type                                         tcdm_rsp_chan_t          = logic,
    /// TCDM Address Width
    parameter int                          unsigned        TCDMAddrWidth            = 0,
    /// TCDM User Payload
    parameter type                                         axi_req_t                = logic,
    parameter type                                         axi_ar_chan_t            = logic,
    parameter type                                         axi_aw_chan_t            = logic,
    parameter type                                         axi_rsp_t                = logic,
    parameter type                                         hive_req_t               = logic,
    parameter type                                         hive_rsp_t               = logic,
    parameter type                                         acc_issue_req_t          = logic,
    parameter type                                         acc_issue_rsp_t          = logic,
    parameter type                                         acc_rsp_t                = logic,
    parameter type                                         dma_events_t             = logic,
    parameter type                                         dma_perf_t               = logic,
    /// FPU configuration.
    parameter fpu_implementation_t                         FPUImplementation        = fpu_implementation_t'(0),
    /// Boot address of core.
    parameter logic                                 [31:0] BootAddr                 = 32'h0000_1000,
    /// Reduced-register extension
    parameter bit                                          RVE                      = 0,
    /// Enable F and D Extension
    parameter bit                                          RVF                      = 1,
    parameter bit                                          RVD                      = 1,
    parameter bit                                          XDivSqrt                 = 0,
    parameter bit                                          XF8                      = 0,
    parameter bit                                          XF16                     = 0,
    parameter bit                                          XF16ALT                  = 0,
    parameter bit                                          XF8ALT                   = 0,
    /// Enable Snitch DMA
    parameter bit                                          Xdma                     = 0,
    parameter int                          unsigned        NumIntOutstandingLoads   = 0,
    parameter int                          unsigned        NumIntOutstandingMem     = 0,
    parameter int                          unsigned        NumSpatzOutstandingLoads = 0,
    // Enable V Extension
    parameter bit                                          RVV                      = 1,
    // Spatz parameters
    parameter int                          unsigned        NumSpatzFPUs             = 4,
    parameter int                          unsigned        NumSpatzIPUs             = 1,
    /// Add isochronous clock-domain crossings e.g., make it possible to operate
    /// the core in a slower clock domain.
    parameter bit                                          IsoCrossing              = 0,
    /// Timing Parameters
    /// Insert Pipeline registers into off-loading path (response)
    parameter bit                                          RegisterOffloadRsp       = 0,
    /// Insert Pipeline registers into data memory path (request)
    parameter bit                                          RegisterCoreReq          = 0,
    /// Insert Pipeline registers into data memory path (response)
    parameter bit                                          RegisterCoreRsp          = 0,
    parameter snitch_pma_pkg::snitch_pma_t                 SnitchPMACfg             = '{default: 0},
    /// Derived parameter *Do not override*
    parameter int                          unsigned        NumSpatzFUs              = (NumSpatzFPUs > NumSpatzIPUs) ? NumSpatzFPUs : NumSpatzIPUs,
    parameter int                          unsigned        NumMemPortsPerSpatz      = NumSpatzFUs,
    parameter int                          unsigned        TCDMPorts                = RVV ? NumMemPortsPerSpatz + 1 : 1,
    parameter type                                         addr_t                   = logic [AddrWidth-1:0]
  ) (
    input  logic                         clk_i,
    input  logic                         clk_d2_i,
    input  logic                         rst_ni,
    input  logic                         testmode_i,
    input  logic         [31:0]          hart_id_i,
    input  interrupts_t                  irq_i,
    output hive_req_t                    hive_req_o,
    input  hive_rsp_t                    hive_rsp_i,
    // Core data ports
    output dreq_t                        data_req_o,
    input  drsp_t                        data_rsp_i,
    // TCDM Streamer Ports
    output tcdm_req_t    [TCDMPorts-1:0] tcdm_req_o,
    input  tcdm_rsp_t    [TCDMPorts-1:0] tcdm_rsp_i,
    // Accelerator Offload port
    // DMA ports
    output axi_req_t                     axi_dma_req_o,
    input  axi_rsp_t                     axi_dma_res_i,
    output logic                         axi_dma_busy_o,
    output dma_perf_t                    axi_dma_perf_o,
    output dma_events_t                  axi_dma_events_o,
    // Core event strobes
    output core_events_t                 core_events_o,
    input  addr_t                        tcdm_addr_base_i
  );

  // FMA architecture is "merged" -> mulexp and macexp instructions are supported
  localparam bit FPEn = RVF | RVD | XF16 | XF8;
  localparam int unsigned FLEN =
  RVD ? 64  : // D ext.
  RVF ? 32  : // F ext.
  XF16 ? 16 : // Xf16 ext.
  XF8 ? 8   : // Xf8 ext.
  0;          // Unused in case of no FP

  acc_issue_req_t acc_snitch_req;
  acc_issue_req_t acc_snitch_demux;
  acc_issue_rsp_t acc_snitch_resp;

  acc_rsp_t acc_demux_snitch;
  acc_rsp_t acc_resp;
  acc_rsp_t dma_resp;

  logic acc_snitch_demux_qvalid, acc_snitch_demux_qready;
  logic acc_qvalid, acc_qready;
  logic dma_qvalid, dma_qready;

  logic acc_pvalid, acc_pready;
  logic dma_pvalid, dma_pready;
  logic acc_demux_snitch_valid, acc_demux_snitch_ready;

  fpnew_pkg::roundmode_e fpu_rnd_mode;
  fpnew_pkg::fmt_mode_t fpu_fmt_mode;
  fpnew_pkg::status_t fpu_status;

  core_events_t snitch_events;

  // Snitch Integer Core
  dreq_t snitch_dreq_d, snitch_dreq_q, merged_dreq;
  drsp_t snitch_drsp_d, snitch_drsp_q, merged_drsp;

  // Spatz Memory consistency signals
  logic [1:0] spatz_mem_finished;
  logic [1:0] spatz_mem_str_finished;

  `SNITCH_VM_TYPEDEF(AddrWidth)

  snitch #(
    .AddrWidth              (AddrWidth             ),
    .DataWidth              (DataWidth             ),
    .acc_issue_req_t        (acc_issue_req_t       ),
    .acc_issue_rsp_t        (acc_issue_rsp_t       ),
    .acc_rsp_t              (acc_rsp_t             ),
    .dreq_t                 (dreq_t                ),
    .drsp_t                 (drsp_t                ),
    .pa_t                   (pa_t                  ),
    .l0_pte_t               (l0_pte_t              ),
    .BootAddr               (BootAddr              ),
    .SnitchPMACfg           (SnitchPMACfg          ),
    .NumIntOutstandingLoads (NumIntOutstandingLoads),
    .NumIntOutstandingMem   (NumIntOutstandingMem  ),
    .VMSupport              (1'b0                  ),
    .RVE                    (RVE                   ),
    .FP_EN                  (FPEn                  ),
    .Xdma                   (Xdma                  ),
    .RVF                    (RVF                   ),
    .RVD                    (RVD                   ),
    .RVV                    (RVV                   ),
    .XDivSqrt               (XDivSqrt              ),
    .XF16                   (XF16                  ),
    .XF16ALT                (XF16ALT               ),
    .XF8                    (XF8                   ),
    .XF8ALT                 (XF8ALT                ),
    .FLEN                   (FLEN                  )
  ) i_snitch (
    .clk_i                 (clk_d2_i                 ), // if necessary operate on half the frequency
    .rst_i                 (!rst_ni                  ),
    .hart_id_i             (hart_id_i                ),
    .irq_i                 (irq_i                    ),
    .flush_i_valid_o       (hive_req_o.flush_i_valid ),
    .flush_i_ready_i       (hive_rsp_i.flush_i_ready ),
    .inst_addr_o           (hive_req_o.inst_addr     ),
    .inst_cacheable_o      (hive_req_o.inst_cacheable),
    .inst_data_i           (hive_rsp_i.inst_data     ),
    .inst_valid_o          (hive_req_o.inst_valid    ),
    .inst_ready_i          (hive_rsp_i.inst_ready    ),
    .acc_qreq_o            (acc_snitch_demux         ),
    .acc_qrsp_i            (acc_snitch_resp          ),
    .acc_qvalid_o          (acc_snitch_demux_qvalid  ),
    .acc_qready_i          (acc_snitch_demux_qready  ),
    .acc_prsp_i            (acc_demux_snitch         ),
    .acc_pvalid_i          (acc_demux_snitch_valid   ),
    .acc_pready_o          (acc_demux_snitch_ready   ),
    .acc_mem_finished_i    (spatz_mem_finished       ),
    .acc_mem_str_finished_i(spatz_mem_str_finished   ),
    .data_req_o            (snitch_dreq_d            ),
    .data_rsp_i            (snitch_drsp_d            ),
    .ptw_valid_o           (hive_req_o.ptw_valid     ),
    .ptw_ready_i           (hive_rsp_i.ptw_ready     ),
    .ptw_va_o              (hive_req_o.ptw_va        ),
    .ptw_ppn_o             (hive_req_o.ptw_ppn       ),
    .ptw_pte_i             (hive_rsp_i.ptw_pte       ),
    .ptw_is_4mega_i        (hive_rsp_i.ptw_is_4mega  ),
    .fpu_rnd_mode_o        (fpu_rnd_mode             ),
    .fpu_fmt_mode_o        (fpu_fmt_mode             ),
    .fpu_status_i          (fpu_status               ),
    .core_events_o         (snitch_events            )
  );

  reqrsp_iso #(
    .AddrWidth (AddrWidth                       ),
    .DataWidth (DataWidth                       ),
    .req_t     (dreq_t                          ),
    .rsp_t     (drsp_t                          ),
    .BypassReq (!RegisterCoreReq                ),
    .BypassRsp (!IsoCrossing && !RegisterCoreRsp)
  ) i_reqrsp_iso (
    .src_clk_i  (clk_d2_i     ),
    .src_rst_ni (rst_ni       ),
    .src_req_i  (snitch_dreq_d),
    .src_rsp_o  (snitch_drsp_d),
    .dst_clk_i  (clk_i        ),
    .dst_rst_ni (rst_ni       ),
    .dst_req_o  (snitch_dreq_q),
    .dst_rsp_i  (snitch_drsp_q)
  );

  // Accelerator Demux Port
  stream_demux #(
    .N_OUP ( 2 )
  ) i_stream_demux_offload (
    .inp_valid_i (acc_snitch_demux_qvalid             ),
    .inp_ready_o (acc_snitch_demux_qready             ),
    .oup_sel_i   (acc_snitch_demux.addr[$clog2(2)-1:0]),
    .oup_valid_o ({dma_qvalid, acc_qvalid}            ),
    .oup_ready_i ({dma_qready, acc_qready}            )
  );

  // There is no shared muldiv in this configuration
  assign hive_req_o.acc_qvalid = 1'b0;
  assign hive_req_o.acc_pready = 1'b0;
  assign hive_req_o.acc_req    = '0;
  assign acc_snitch_req        = acc_snitch_demux;

  stream_arbiter #(
    .DATA_T ( acc_rsp_t ),
    .N_INP  ( 2         )
  ) i_stream_arbiter_offload (
    .clk_i       ( clk_i                     ),
    .rst_ni      ( rst_ni                    ),
    .inp_data_i  ( {dma_resp, acc_resp }     ),
    .inp_valid_i ( {dma_pvalid, acc_pvalid } ),
    .inp_ready_o ( {dma_pready, acc_pready } ),
    .oup_data_o  ( acc_demux_snitch          ),
    .oup_valid_o ( acc_demux_snitch_valid    ),
    .oup_ready_i ( acc_demux_snitch_ready    )
  );

  dreq_t fp_lsu_mem_req;
  drsp_t fp_lsu_mem_rsp;

  tcdm_req_chan_t [NumMemPortsPerSpatz-1:0] spatz_mem_req;
  logic           [NumMemPortsPerSpatz-1:0] spatz_mem_req_valid;
  logic           [NumMemPortsPerSpatz-1:0] spatz_mem_req_ready;
  tcdm_rsp_chan_t [NumMemPortsPerSpatz-1:0] spatz_mem_rsp;
  logic           [NumMemPortsPerSpatz-1:0] spatz_mem_rsp_valid;

  spatz #(
    .NrMemPorts         (NumMemPortsPerSpatz     ),
    .NumOutstandingLoads(NumSpatzOutstandingLoads),
    .FPUImplementation  (FPUImplementation       ),
    .RegisterRsp        (RegisterOffloadRsp      ),
    .dreq_t             (dreq_t                  ),
    .drsp_t             (drsp_t                  ),
    .spatz_mem_req_t    (tcdm_req_chan_t         ),
    .spatz_mem_rsp_t    (tcdm_rsp_chan_t         ),
    .spatz_issue_req_t  (acc_issue_req_t         ),
    .spatz_issue_rsp_t  (acc_issue_rsp_t         ),
    .spatz_rsp_t        (acc_rsp_t               )
  ) i_spatz (
    .clk_i                   (clk_i                 ),
    .rst_ni                  (rst_ni                ),
    .testmode_i              (testmode_i            ),
    .hart_id_i               (hart_id_i             ),
    .issue_valid_i           (acc_qvalid            ),
    .issue_ready_o           (acc_qready            ),
    .issue_req_i             (acc_snitch_req        ),
    .issue_rsp_o             (acc_snitch_resp       ),
    .rsp_valid_o             (acc_pvalid            ),
    .rsp_ready_i             (acc_pready            ),
    .rsp_o                   (acc_resp              ),
    .spatz_mem_req_o         (spatz_mem_req         ),
    .spatz_mem_req_valid_o   (spatz_mem_req_valid   ),
    .spatz_mem_req_ready_i   (spatz_mem_req_ready   ),
    .spatz_mem_rsp_i         (spatz_mem_rsp         ),
    .spatz_mem_rsp_valid_i   (spatz_mem_rsp_valid   ),
    .spatz_mem_finished_o    (spatz_mem_finished    ),
    .spatz_mem_str_finished_o(spatz_mem_str_finished),
    .fp_lsu_mem_req_o        (fp_lsu_mem_req        ),
    .fp_lsu_mem_rsp_i        (fp_lsu_mem_rsp        ),
    .fpu_rnd_mode_i          (fpu_rnd_mode          ),
    .fpu_fmt_mode_i          (fpu_fmt_mode          ),
    .fpu_status_o            (fpu_status            )
  );

  for (genvar p = 0; p < NumMemPortsPerSpatz; p++) begin: gen_tcdm_assignment
    assign tcdm_req_o[p] = '{
         q      : spatz_mem_req[p],
         q_valid: spatz_mem_req_valid[p]
       };
    assign spatz_mem_req_ready[p] = tcdm_rsp_i[p].q_ready;

    assign spatz_mem_rsp[p]       = tcdm_rsp_i[p].p;
    assign spatz_mem_rsp_valid[p] = tcdm_rsp_i[p].p_valid;
  end

  reqrsp_mux #(
    .NrPorts     (2           ),
    .AddrWidth   (AddrWidth   ),
    .DataWidth   (DataWidth   ),
    .req_t       (dreq_t      ),
    .rsp_t       (drsp_t      ),
    // TODO(zarubaf): Wire-up to top-level.
    .RespDepth   (4           ),
    .RegisterReq ({1'b1, 1'b0})
  ) i_reqrsp_mux (
    .clk_i     (clk_i                          ),
    .rst_ni    (rst_ni                         ),
    .slv_req_i ({fp_lsu_mem_req, snitch_dreq_q}),
    .slv_rsp_o ({fp_lsu_mem_rsp, snitch_drsp_q}),
    .mst_req_o (merged_dreq                    ),
    .mst_rsp_i (merged_drsp                    ),
    .idx_o     (/*not connected*/              )
  );

  if (Xdma) begin : gen_dma
    axi_dma_tc_snitch_fe #(
      .AddrWidth          (AddrWidth         ),
      .DataWidth          (DataWidth         ),
      .DMADataWidth       (DMADataWidth      ),
      .IdWidth            (DMAIdWidth        ),
      .UserWidth          (UserWidth         ),
      .DMAAxiReqFifoDepth (DMAAxiReqFifoDepth),
      .DMAReqFifoDepth    (DMAReqFifoDepth   ),
      .axi_req_t          (axi_req_t         ),
      .axi_ar_chan_t      (axi_ar_chan_t     ),
      .axi_aw_chan_t      (axi_aw_chan_t     ),
      .axi_res_t          (axi_rsp_t         ),
      .acc_resp_t         (acc_rsp_t         ),
      .dma_events_t       (dma_events_t      )
    ) i_axi_dma_tc_snitch_fe (
      .clk_i            ( clk_i                    ),
      .rst_ni           ( rst_ni                   ),
      .axi_dma_req_o    ( axi_dma_req_o            ),
      .axi_dma_res_i    ( axi_dma_res_i            ),
      .dma_busy_o       ( axi_dma_busy_o           ),
      .acc_qaddr_i      ( acc_snitch_req.addr      ),
      .acc_qid_i        ( acc_snitch_req.id        ),
      .acc_qdata_op_i   ( acc_snitch_req.data_op   ),
      .acc_qdata_arga_i ( acc_snitch_req.data_arga ),
      .acc_qdata_argb_i ( acc_snitch_req.data_argb ),
      .acc_qdata_argc_i ( acc_snitch_req.data_argc ),
      .acc_qvalid_i     ( dma_qvalid               ),
      .acc_qready_o     ( dma_qready               ),
      .acc_pdata_o      ( dma_resp.data            ),
      .acc_pid_o        ( dma_resp.id              ),
      .acc_perror_o     ( dma_resp.error           ),
      .acc_pvalid_o     ( dma_pvalid               ),
      .acc_pready_i     ( dma_pready               ),
      .hart_id_i        ( hart_id_i                ),
      .dma_perf_o       ( axi_dma_perf_o           ),
      .dma_events_o     ( axi_dma_events_o         )
    );

  // no DMA instanciated
  end else begin : gen_no_dma
    // tie-off unused signals
    assign axi_dma_req_o  = '0;
    assign axi_dma_busy_o = 1'b0;

    assign dma_qready = '0;
    assign dma_pvalid = '0;

    assign dma_resp       = '0;
    assign axi_dma_perf_o = '0;
  end

  // Decide whether to go to SoC or TCDM
  dreq_t                  data_tcdm_req;
  drsp_t                  data_tcdm_rsp;
  localparam int unsigned SelectWidth   = cf_math_pkg::idx_width(2);
  typedef logic [SelectWidth-1:0] select_t;
  select_t slave_select;
  reqrsp_demux #(
    .NrPorts   (2     ),
    .req_t     (dreq_t),
    .rsp_t     (drsp_t),
    .RespDepth (4     )
  ) i_reqrsp_demux (
    .clk_i        (clk_i                      ),
    .rst_ni       (rst_ni                     ),
    .slv_select_i (slave_select               ),
    .slv_req_i    (merged_dreq                ),
    .slv_rsp_o    (merged_drsp                ),
    .mst_req_o    ({data_tcdm_req, data_req_o}),
    .mst_rsp_i    ({data_tcdm_rsp, data_rsp_i})
  );

  typedef struct packed {
    int unsigned idx;
    logic [AddrWidth-1:0] base;
    logic [AddrWidth-1:0] mask;
  } reqrsp_rule_t;

  reqrsp_rule_t addr_map;
  assign addr_map = '{
    idx : 1,
    base: tcdm_addr_base_i,
    mask: ({AddrWidth{1'b1}} << TCDMAddrWidth)
  };

  addr_decode_napot #(
    .NoIndices (2                    ),
    .NoRules   (1                    ),
    .addr_t    (logic [AddrWidth-1:0]),
    .rule_t    (reqrsp_rule_t        )
  ) i_addr_decode_napot (
    .addr_i           (merged_dreq.q.addr),
    .addr_map_i       (addr_map          ),
    .idx_o            (slave_select      ),
    .dec_valid_o      (/* Unused */      ),
    .dec_error_o      (/* Unused */      ),
    .en_default_idx_i (1'b1              ),
    .default_idx_i    ('0                )
  );

  reqrsp_to_tcdm #(
    .AddrWidth    (AddrWidth ),
    .DataWidth    (DataWidth ),
    .BufDepth     (4         ),
    .reqrsp_req_t (dreq_t    ),
    .reqrsp_rsp_t (drsp_t    ),
    .tcdm_req_t   (tcdm_req_t),
    .tcdm_rsp_t   (tcdm_rsp_t)
  ) i_reqrsp_to_tcdm (
    .clk_i        (clk_i                          ),
    .rst_ni       (rst_ni                         ),
    .reqrsp_req_i (data_tcdm_req                  ),
    .reqrsp_rsp_o (data_tcdm_rsp                  ),
    .tcdm_req_o   (tcdm_req_o[NumMemPortsPerSpatz]),
    .tcdm_rsp_i   (tcdm_rsp_i[NumMemPortsPerSpatz])
  );

  // Core events for performance counters
  assign core_events_o.retired_instr     = snitch_events.retired_instr;
  assign core_events_o.retired_load      = snitch_events.retired_load;
  assign core_events_o.retired_i         = snitch_events.retired_i;
  assign core_events_o.retired_acc       = snitch_events.retired_acc;
  assign core_events_o.issue_fpu         = '0;
  assign core_events_o.issue_core_to_fpu = '0;
  assign core_events_o.issue_fpu_seq     = '0;

  // --------------------------
  // Tracer
  // --------------------------
`ifndef SPATZ_DISABLE_TRACER
  // pragma translate_off
  int           f;
  string        fn;
  logic  [63:0] cycle;
  bit           vmvm_profile_trace;
  bit           vmvm_profile_activity_only;
  bit           vmvm_profile_first_body_only;
  int unsigned  vmvm_profile_sample_body;
  bit           vmvm_boundary_trace_active;
  bit           vmvm_body_trace_active;
  bit           vmvm_trace_next_issue;
  logic  [31:0] vmvm_profile_start_pc;
  logic  [31:0] vmvm_profile_end_pc;
  logic  [31:0] vmvm_profile_header_pc;
  logic  [31:0] vmvm_profile_latch_pc;
  logic  [31:0] vmvm_profile_dynamic_pc0;
  logic  [31:0] vmvm_profile_dynamic_pc1;
  logic  [31:0] vmvm_profile_dynamic_pc2;
  logic  [31:0] vmvm_profile_body_start_pc;
  logic  [31:0] vmvm_profile_body_end_pc;
  logic  [63:0] vmvm_body_start_cycle;
  logic  [63:0] vmvm_body_count;
  logic  [63:0] vmvm_body_insn_full_start;
  logic  [63:0] vmvm_body_insn_tail_start;
  logic  [63:0] vmvm_body_compute_full_start;
  logic  [63:0] vmvm_body_compute_tail_start;
  logic  [63:0] vmvm_body_service_union_start;
  logic  [63:0] vmvm_body_tail_capture_start;
  logic  [63:0] vmvm_body_writeback_start;
  logic  [63:0] vmvm_b15_dimc_insn_full;
  logic  [63:0] vmvm_b15_dimc_insn_tail;
  logic  [63:0] vmvm_b15_dimc_compute_full;
  logic  [63:0] vmvm_b15_dimc_compute_tail;
  logic  [63:0] vmvm_b15_dimc_service_union;
  logic  [63:0] vmvm_b15_dimc_tail_capture;
  logic  [63:0] vmvm_b15_dimc_writeback;

  localparam int unsigned VmvmLatencyDimc = 0;
  localparam int unsigned VmvmLatencyVle8 = 1;
  localparam int unsigned VmvmLatencyVle32 = 2;
  localparam int unsigned VmvmLatencyVse32 = 3;
  localparam int unsigned VmvmLatencyVadd = 4;
  localparam int unsigned VmvmLatencyOther = 5;
  localparam int unsigned VmvmLatencyBuckets = 6;
  bit [spatz_pkg::NrParallelInstructions-1:0] vmvm_latency_valid;
  logic [63:0] vmvm_latency_start [spatz_pkg::NrParallelInstructions-1:0];
  int unsigned vmvm_latency_bucket_by_id [spatz_pkg::NrParallelInstructions-1:0];
  logic [63:0] vmvm_latency_issues [VmvmLatencyBuckets-1:0];
  logic [63:0] vmvm_latency_completions [VmvmLatencyBuckets-1:0];
  logic [63:0] vmvm_latency_sum [VmvmLatencyBuckets-1:0];
  logic [63:0] vmvm_latency_min [VmvmLatencyBuckets-1:0];
  logic [63:0] vmvm_latency_max [VmvmLatencyBuckets-1:0];
  bit          dimc_scenario_profile;
  bit [spatz_pkg::NrParallelInstructions-1:0] dimc_scenario_valid;
  logic [63:0] dimc_scenario_start [spatz_pkg::NrParallelInstructions-1:0];
  logic        dimc_scenario_kernel_load [spatz_pkg::NrParallelInstructions-1:0];
  logic        dimc_scenario_feature_reuse [spatz_pkg::NrParallelInstructions-1:0];
  logic        dimc_scenario_compute_reuse [spatz_pkg::NrParallelInstructions-1:0];
  spatz_pkg::vlen_t dimc_scenario_vl [spatz_pkg::NrParallelInstructions-1:0];

  function automatic int unsigned vmvm_latency_bucket(
    input spatz_pkg::spatz_req_t req
  );
    unique case (req.op)
      spatz_pkg::DIMC_OP: return VmvmLatencyDimc;
      spatz_pkg::VLE: begin
        unique case (req.vtype.vsew)
          rvv_pkg::EW_8: return VmvmLatencyVle8;
          rvv_pkg::EW_32: return VmvmLatencyVle32;
          default: return VmvmLatencyOther;
        endcase
      end
      spatz_pkg::VSE: begin
        if (req.vtype.vsew == rvv_pkg::EW_32)
          return VmvmLatencyVse32;
        return VmvmLatencyOther;
      end
      spatz_pkg::VADD: return VmvmLatencyVadd;
      default: return VmvmLatencyOther;
    endcase
  endfunction

  function automatic string vmvm_latency_name(input int unsigned bucket);
    unique case (bucket)
      VmvmLatencyDimc: return "sf_vqmmacc";
      VmvmLatencyVle8: return "vle8.v";
      VmvmLatencyVle32: return "vle32.v";
      VmvmLatencyVse32: return "vse32.v";
      VmvmLatencyVadd: return "vadd.vv";
      default: return "other_spatz";
    endcase
  endfunction

  function automatic bit vmvm_dynamic_pc_match(input logic [31:0] pc);
    return (vmvm_profile_dynamic_pc0 != '0 && pc == vmvm_profile_dynamic_pc0) ||
           (vmvm_profile_dynamic_pc1 != '0 && pc == vmvm_profile_dynamic_pc1) ||
           (vmvm_profile_dynamic_pc2 != '0 && pc == vmvm_profile_dynamic_pc2);
  endfunction

  initial begin
    // We need to schedule the assignment into a safe region, otherwise
    // `hart_id_i` won't have a value assigned at the beginning of the first
    // delta cycle.
    /* verilator lint_off STMTDLY */
    @(posedge clk_i);
    /* verilator lint_on STMTDLY */
    $system("mkdir logs -p");
    $sformat(fn, "logs/trace_hart_%05x.dasm", hart_id_i);
    f = $fopen(fn, "w");
    $display("[Tracer] Logging Hart %d to %s", hart_id_i, fn);
    vmvm_profile_trace = $test$plusargs("vmvm_profile_trace");
    dimc_scenario_profile = $test$plusargs("dimc_scenario_profile");
    vmvm_profile_activity_only = $test$plusargs("vmvm_profile_activity_only");
    vmvm_profile_first_body_only = $test$plusargs("vmvm_profile_first_body_only");
    vmvm_profile_sample_body = 0;
    void'($value$plusargs("vmvm_profile_sample_body=%d", vmvm_profile_sample_body));
    vmvm_profile_start_pc = '0;
    vmvm_profile_end_pc = '0;
    vmvm_profile_header_pc = '0;
    vmvm_profile_latch_pc = '0;
    vmvm_profile_dynamic_pc0 = '0;
    vmvm_profile_dynamic_pc1 = '0;
    vmvm_profile_dynamic_pc2 = '0;
    vmvm_profile_body_start_pc = '0;
    vmvm_profile_body_end_pc = '0;
    void'($value$plusargs("vmvm_profile_start=%h", vmvm_profile_start_pc));
    void'($value$plusargs("vmvm_profile_end=%h", vmvm_profile_end_pc));
    void'($value$plusargs("vmvm_profile_header=%h", vmvm_profile_header_pc));
    void'($value$plusargs("vmvm_profile_latch=%h", vmvm_profile_latch_pc));
    void'($value$plusargs("vmvm_profile_dynamic0=%h", vmvm_profile_dynamic_pc0));
    void'($value$plusargs("vmvm_profile_dynamic1=%h", vmvm_profile_dynamic_pc1));
    void'($value$plusargs("vmvm_profile_dynamic2=%h", vmvm_profile_dynamic_pc2));
    void'($value$plusargs("vmvm_profile_body_start=%h", vmvm_profile_body_start_pc));
    void'($value$plusargs("vmvm_profile_body_end=%h", vmvm_profile_body_end_pc));
    if (vmvm_profile_trace) begin
      $display("[Tracer] VMVM boundary-only trace start=%08x end=%08x header=%08x latch=%08x",
               vmvm_profile_start_pc, vmvm_profile_end_pc,
               vmvm_profile_header_pc, vmvm_profile_latch_pc);
      if (vmvm_profile_body_start_pc != '0) begin
        $display("[Tracer] VMVM body trace start=%08x end=%08x",
                 vmvm_profile_body_start_pc, vmvm_profile_body_end_pc);
      end
    end
  end

  // verilog_lint: waive-start always-ff-non-blocking
  always_ff @(posedge clk_i) begin
    automatic string trace_entry;
    automatic string extras_str;
    automatic bit trace_snitch;
    automatic bit dynamic_pc;
    automatic snitch_pkg::snitch_trace_port_t extras_snitch;
    automatic snitch_pkg::fpu_trace_port_t extras_fpu;
    automatic snitch_pkg::fpu_sequencer_trace_port_t extras_fpu_seq_out;

    if (rst_ni) begin
      extras_snitch = '{
        // State
        source      : snitch_pkg::SrcSnitch,
        stall       : i_snitch.stall,
        exception   : i_snitch.exception,
        // Decoding
        rs1         : i_snitch.rs1,
        rs2         : i_snitch.rs2,
        rd          : i_snitch.rd,
        is_load     : i_snitch.is_load,
        is_store    : i_snitch.is_store,
        is_branch   : i_snitch.is_branch,
        pc_d        : i_snitch.pc_d,
        // Operands
        opa         : i_snitch.opa,
        opb         : i_snitch.opb,
        opa_select  : i_snitch.opa_select,
        opb_select  : i_snitch.opb_select,
        write_rd    : i_snitch.write_rd,
        csr_addr    : i_snitch.inst_data_i[31:20],
        // Pipeline writeback
        writeback   : i_snitch.alu_writeback,
        // Load/Store
        gpr_rdata_1 : i_snitch.gpr_rdata[1],
        ls_size     : i_snitch.ls_size,
        ld_result_32: i_snitch.ld_result[31:0],
        lsu_rd      : i_snitch.lsu_rd,
        retire_load : i_snitch.retire_load,
        alu_result  : i_snitch.alu_result,
        // Atomics
        ls_amo      : i_snitch.ls_amo,
        // Accelerator
        retire_acc  : i_snitch.retire_acc,
        acc_pid     : i_snitch.acc_prsp_i.id,
        acc_pdata_32: i_snitch.acc_prsp_i.data[31:0],
        // FPU offload
        fpu_offload : (i_snitch.acc_qready_i && i_snitch.acc_qvalid_o && i_snitch.acc_qreq_o.addr == 0),
        is_seq_insn : '0
      };

      cycle++;
      if (dimc_scenario_profile) begin
        if (i_spatz.spatz_req_valid && i_spatz.vfu_req_ready &&
            i_spatz.spatz_req.op == spatz_pkg::DIMC_OP) begin
          automatic int unsigned issue_id = int'(i_spatz.spatz_req.id);
          dimc_scenario_valid[issue_id] = 1'b1;
          dimc_scenario_start[issue_id] = cycle;
          dimc_scenario_kernel_load[issue_id] =
              i_spatz.spatz_req.op_cfg.dimc.kernel_load;
          dimc_scenario_feature_reuse[issue_id] =
              i_spatz.spatz_req.op_cfg.dimc.feature_reuse;
          dimc_scenario_compute_reuse[issue_id] =
              i_spatz.spatz_req.op_cfg.dimc.compute_reuse;
          dimc_scenario_vl[issue_id] = i_spatz.spatz_req.vl;
          $display("RTL_DIMC_ISSUE id=%0d cycle=%0d kernel_load=%0d feature_load=%0d feature_reuse=%0d compute_reuse=%0d vl=%0d",
                   issue_id, cycle,
                   i_spatz.spatz_req.op_cfg.dimc.kernel_load,
                   !i_spatz.spatz_req.op_cfg.dimc.feature_reuse,
                   i_spatz.spatz_req.op_cfg.dimc.feature_reuse,
                   i_spatz.spatz_req.op_cfg.dimc.compute_reuse,
                   i_spatz.spatz_req.vl);
        end

        if (i_spatz.i_vfu.dimc_start) begin
          $display("RTL_DIMC_PHASE event=start id=%0d cycle=%0d",
                   i_spatz.spatz_req.id, cycle);
        end
        if (i_spatz.i_vfu.dimc_compute_fire &&
            (i_spatz.i_vfu.dimc_row_q == 0 || i_spatz.i_vfu.dimc_row_q == 7)) begin
          $display("RTL_DIMC_PHASE event=compute id=%0d row=%0d cycle=%0d",
                   i_spatz.i_vfu.dimc_active_id_q,
                   i_spatz.i_vfu.dimc_row_q, cycle);
        end
        if (i_spatz.i_vfu.dimc_capture_valid &&
            (i_spatz.i_vfu.dimc_capture_row == 0 ||
             i_spatz.i_vfu.dimc_capture_row == 7)) begin
          $display("RTL_DIMC_PHASE event=capture id=%0d row=%0d cycle=%0d",
                   i_spatz.i_vfu.dimc_capture_id,
                   i_spatz.i_vfu.dimc_capture_row, cycle);
        end
        if (i_spatz.i_vfu.dimc_wb_accept) begin
          $display("RTL_DIMC_PHASE event=writeback id=%0d word=%0d last=%0d cycle=%0d",
                   i_spatz.i_vfu.dimc_write_id,
                   i_spatz.i_vfu.dimc_write_word,
                   i_spatz.i_vfu.dimc_write_last_word, cycle);
        end

        if (i_spatz.i_vfu.dimc_rsp_done) begin
          automatic int unsigned done_id = int'(i_spatz.i_vfu.dimc_write_id);
          if (dimc_scenario_valid[done_id]) begin
            $display("RTL_DIMC_COMPLETE id=%0d issue_cycle=%0d done_cycle=%0d cycles=%0d kernel_load=%0d feature_load=%0d feature_reuse=%0d compute_reuse=%0d vl=%0d",
                     done_id, dimc_scenario_start[done_id], cycle,
                     cycle - dimc_scenario_start[done_id],
                     dimc_scenario_kernel_load[done_id],
                     !dimc_scenario_feature_reuse[done_id],
                     dimc_scenario_feature_reuse[done_id],
                     dimc_scenario_compute_reuse[done_id],
                     dimc_scenario_vl[done_id]);
            dimc_scenario_valid[done_id] = 1'b0;
          end
        end
      end
      if (vmvm_profile_trace && vmvm_body_trace_active) begin
        if (i_spatz.spatz_req_valid && i_spatz.spatz_req.ex_unit != spatz_pkg::CON) begin
          automatic int unsigned issue_id = int'(i_spatz.spatz_req.id);
          automatic int unsigned issue_bucket = vmvm_latency_bucket(i_spatz.spatz_req);
          vmvm_latency_valid[issue_id] = 1'b1;
          vmvm_latency_start[issue_id] = cycle;
          vmvm_latency_bucket_by_id[issue_id] = issue_bucket;
          vmvm_latency_issues[issue_bucket]++;
        end

        if (i_spatz.vfu_rsp_valid) begin
          automatic int unsigned completed_id = int'(i_spatz.vfu_rsp.id);
          if (vmvm_latency_valid[completed_id]) begin
            automatic int unsigned completed_bucket = vmvm_latency_bucket_by_id[completed_id];
            automatic logic [63:0] latency = cycle - vmvm_latency_start[completed_id];
            vmvm_latency_valid[completed_id] = 1'b0;
            vmvm_latency_completions[completed_bucket]++;
            vmvm_latency_sum[completed_bucket] += latency;
            if (latency < vmvm_latency_min[completed_bucket])
              vmvm_latency_min[completed_bucket] = latency;
            if (latency > vmvm_latency_max[completed_bucket])
              vmvm_latency_max[completed_bucket] = latency;
          end
        end

        if (i_spatz.vlsu_rsp_valid) begin
          automatic int unsigned completed_id = int'(i_spatz.vlsu_rsp.id);
          if (vmvm_latency_valid[completed_id]) begin
            automatic int unsigned completed_bucket = vmvm_latency_bucket_by_id[completed_id];
            automatic logic [63:0] latency = cycle - vmvm_latency_start[completed_id];
            vmvm_latency_valid[completed_id] = 1'b0;
            vmvm_latency_completions[completed_bucket]++;
            vmvm_latency_sum[completed_bucket] += latency;
            if (latency < vmvm_latency_min[completed_bucket])
              vmvm_latency_min[completed_bucket] = latency;
            if (latency > vmvm_latency_max[completed_bucket])
              vmvm_latency_max[completed_bucket] = latency;
          end
        end

        if (i_spatz.vsldu_rsp_valid) begin
          automatic int unsigned completed_id = int'(i_spatz.vsldu_rsp.id);
          if (vmvm_latency_valid[completed_id]) begin
            automatic int unsigned completed_bucket = vmvm_latency_bucket_by_id[completed_id];
            automatic logic [63:0] latency = cycle - vmvm_latency_start[completed_id];
            vmvm_latency_valid[completed_id] = 1'b0;
            vmvm_latency_completions[completed_bucket]++;
            vmvm_latency_sum[completed_bucket] += latency;
            if (latency < vmvm_latency_min[completed_bucket])
              vmvm_latency_min[completed_bucket] = latency;
            if (latency > vmvm_latency_max[completed_bucket])
              vmvm_latency_max[completed_bucket] = latency;
          end
        end

        if (i_spatz.i_vfu.dimc_compute_fire) begin
          if (i_spatz.i_vfu.dimc_row_q == '0) begin
            // This distinguishes physical VL only. A zero-padded logical K tail
            // still executes at VL=128 and is counted as full here.
            if (i_spatz.i_vfu.dimc_active_vl_q == 128)
              vmvm_b15_dimc_insn_full++;
            else
              vmvm_b15_dimc_insn_tail++;
          end
          if (i_spatz.i_vfu.dimc_active_vl_q == 128)
            vmvm_b15_dimc_compute_full++;
          else
            vmvm_b15_dimc_compute_tail++;
        end
        if (i_spatz.i_vfu.dimc_busy || i_spatz.i_vfu.dimc_tail_pending_q ||
            i_spatz.i_vfu.dimc_tail_done_pending_q || i_spatz.i_vfu.dimc_wb_pending_q)
          vmvm_b15_dimc_service_union++;
        if (i_spatz.i_vfu.dimc_tail_pending_q)
          vmvm_b15_dimc_tail_capture++;
        if (i_spatz.i_vfu.dimc_wb_pending_q)
          vmvm_b15_dimc_writeback++;
      end
      // Trace snitch iff:
      // we are not stalled <==> we have issued and processed an instruction (including offloads)
      // OR we are retiring (issuing a writeback from) a load or accelerator instruction
      if (!i_snitch.stall || i_snitch.retire_load || i_snitch.retire_acc) begin
        trace_snitch = !vmvm_profile_trace;
        if (vmvm_profile_trace && !i_snitch.stall) begin
          dynamic_pc = vmvm_dynamic_pc_match(i_snitch.pc_q);
          trace_snitch = vmvm_boundary_trace_active ||
                          (vmvm_body_trace_active && !vmvm_profile_activity_only) ||
                          vmvm_trace_next_issue ||
                          i_snitch.pc_q == vmvm_profile_start_pc ||
                          i_snitch.pc_q == vmvm_profile_end_pc ||
                          i_snitch.pc_q == vmvm_profile_header_pc ||
                          i_snitch.pc_q == vmvm_profile_latch_pc || dynamic_pc;
          trace_snitch = trace_snitch ||
                          i_snitch.pc_q == vmvm_profile_body_start_pc ||
                          i_snitch.pc_q == vmvm_profile_body_end_pc;
          vmvm_trace_next_issue = dynamic_pc;
          if (i_snitch.pc_q == vmvm_profile_latch_pc) begin
            vmvm_boundary_trace_active = 1'b1;
          end
          if (i_snitch.pc_q == vmvm_profile_header_pc) begin
            vmvm_boundary_trace_active = 1'b0;
          end
          if (i_snitch.pc_q == vmvm_profile_end_pc) begin
            vmvm_boundary_trace_active = 1'b0;
          end
          if (i_snitch.pc_q == vmvm_profile_body_start_pc) begin
            vmvm_body_trace_active = 1'b1;
            vmvm_body_start_cycle = cycle;
            vmvm_body_count++;
            vmvm_body_insn_full_start = vmvm_b15_dimc_insn_full;
            vmvm_body_insn_tail_start = vmvm_b15_dimc_insn_tail;
            vmvm_body_compute_full_start = vmvm_b15_dimc_compute_full;
            vmvm_body_compute_tail_start = vmvm_b15_dimc_compute_tail;
            vmvm_body_service_union_start = vmvm_b15_dimc_service_union;
            vmvm_body_tail_capture_start = vmvm_b15_dimc_tail_capture;
            vmvm_body_writeback_start = vmvm_b15_dimc_writeback;
          end
          if (i_snitch.pc_q == vmvm_profile_body_end_pc) begin
            vmvm_body_trace_active = 1'b0;
            if (vmvm_profile_first_body_only ||
                (vmvm_profile_sample_body != 0 &&
                 vmvm_body_count == vmvm_profile_sample_body)) begin
              $display("RTL_B15_BODY_SAMPLE body=%0d body_cycles=%0d insn_full=%0d insn_tail=%0d compute_full=%0d compute_tail=%0d service_union=%0d tail_capture=%0d writeback=%0d",
                       vmvm_body_count, cycle - vmvm_body_start_cycle,
                       vmvm_b15_dimc_insn_full - vmvm_body_insn_full_start,
                       vmvm_b15_dimc_insn_tail - vmvm_body_insn_tail_start,
                       vmvm_b15_dimc_compute_full - vmvm_body_compute_full_start,
                       vmvm_b15_dimc_compute_tail - vmvm_body_compute_tail_start,
                       vmvm_b15_dimc_service_union - vmvm_body_service_union_start,
                       vmvm_b15_dimc_tail_capture - vmvm_body_tail_capture_start,
                       vmvm_b15_dimc_writeback - vmvm_body_writeback_start);
              $finish;
            end
          end
        end
        if (trace_snitch) begin
          $sformat(trace_entry, "%t %1d %8d 0x%h DASM(%h) #; %s\n",
            $time, cycle, i_snitch.priv_lvl_q, i_snitch.pc_q, i_snitch.inst_data_i,
            snitch_pkg::print_snitch_trace(extras_snitch));
          $fwrite(f, trace_entry);
        end
          if (vmvm_profile_trace && !i_snitch.stall &&
              i_snitch.pc_q == vmvm_profile_end_pc) begin
            $display("RTL_BOUNDARY_PROFILE_COMPLETE cycles=%0d", cycle);
            $display("RTL_B15_DIMC_ACTIVITY insn_full=%0d insn_tail=%0d compute_full=%0d compute_tail=%0d service_union=%0d tail_capture=%0d writeback=%0d",
                     vmvm_b15_dimc_insn_full, vmvm_b15_dimc_insn_tail,
                     vmvm_b15_dimc_compute_full, vmvm_b15_dimc_compute_tail,
                     vmvm_b15_dimc_service_union, vmvm_b15_dimc_tail_capture,
                     vmvm_b15_dimc_writeback);
            for (int unsigned bucket = 0; bucket < VmvmLatencyBuckets; bucket++) begin
              if (vmvm_latency_issues[bucket] != 0) begin
                $display("RTL_SPATZ_LATENCY instruction=%s issues=%0d completions=%0d latency_sum=%0d latency_min=%0d latency_max=%0d",
                         vmvm_latency_name(bucket), vmvm_latency_issues[bucket],
                         vmvm_latency_completions[bucket], vmvm_latency_sum[bucket],
                         vmvm_latency_completions[bucket] == 0 ? 0 : vmvm_latency_min[bucket],
                         vmvm_latency_max[bucket]);
              end
            end
            $finish;
        end
      end
      if (FPEn && !vmvm_profile_trace) begin
        // Trace FPU iff:
        // an incoming handshake on the accelerator bus occurs <==> an instruction was issued
        // OR an FPU result is ready to be written back to an FPR register or the bus
        // OR an LSU result is ready to be written back to an FPR register or the bus
        // OR an FPU result, LSU result or bus value is ready to be written back to an FPR register
        if (extras_fpu.acc_q_hs || extras_fpu.fpu_out_hs
            || extras_fpu.lsu_q_hs || extras_fpu.fpr_we) begin
          $sformat(trace_entry, "%t %1d %8d 0x%h DASM(%h) #; %s\n",
            $time, cycle, i_snitch.priv_lvl_q, 32'hz, extras_fpu.op_in,
            snitch_pkg::print_fpu_trace(extras_fpu));
          $fwrite(f, trace_entry);
        end
      end
    end else begin
      cycle <= '0;
      vmvm_boundary_trace_active = 1'b0;
      vmvm_body_trace_active = 1'b0;
      vmvm_trace_next_issue = 1'b0;
      vmvm_body_start_cycle <= '0;
      vmvm_body_count <= '0;
      vmvm_body_insn_full_start <= '0;
      vmvm_body_insn_tail_start <= '0;
      vmvm_body_compute_full_start <= '0;
      vmvm_body_compute_tail_start <= '0;
      vmvm_body_service_union_start <= '0;
      vmvm_body_tail_capture_start <= '0;
      vmvm_body_writeback_start <= '0;
      vmvm_b15_dimc_insn_full <= '0;
      vmvm_b15_dimc_insn_tail <= '0;
      vmvm_b15_dimc_compute_full <= '0;
      vmvm_b15_dimc_compute_tail <= '0;
      vmvm_b15_dimc_service_union <= '0;
      vmvm_b15_dimc_tail_capture <= '0;
      vmvm_b15_dimc_writeback <= '0;
      vmvm_latency_valid <= '0;
      dimc_scenario_valid <= '0;
      for (int unsigned id = 0; id < spatz_pkg::NrParallelInstructions; id++) begin
        vmvm_latency_start[id] <= '0;
        vmvm_latency_bucket_by_id[id] <= VmvmLatencyOther;
        dimc_scenario_start[id] <= '0;
        dimc_scenario_kernel_load[id] <= 1'b0;
        dimc_scenario_feature_reuse[id] <= 1'b0;
        dimc_scenario_compute_reuse[id] <= 1'b0;
        dimc_scenario_vl[id] <= '0;
      end
      for (int unsigned bucket = 0; bucket < VmvmLatencyBuckets; bucket++) begin
        vmvm_latency_issues[bucket] <= '0;
        vmvm_latency_completions[bucket] <= '0;
        vmvm_latency_sum[bucket] <= '0;
        vmvm_latency_min[bucket] <= '1;
        vmvm_latency_max[bucket] <= '0;
      end
    end
  end

  final begin
    $fclose(f);
  end
  // verilog_lint: waive-stop always-ff-non-blocking
  // pragma translate_on
`endif

  `ASSERT_INIT(BootAddrAligned, BootAddr[1:0] == 2'b00)

endmodule
