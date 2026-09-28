// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

#include <printf.h>

#include "Vtestharness.h"
#include "Vtestharness__Dpi.h"
#include "sim.hh"
#include "tb_lib.hh"
#include "verilated.h"
#include "verilated_vcd_c.h"
namespace sim {

Sim* s;

// Number of cycles between HTIF checks.
const int HTIFTimeInterval = 200;
void sim_thread_main(void *arg) { ((Sim *)arg)->main(); }

// Sim time.
int TIME = 0;

Sim::Sim(int argc, char **argv) : htif_t(argc, argv) {
    Verilated::commandArgs(argc, argv);
    for (int i = 1; i < argc; i++) {
        std::string arg(argv[i]);
        if (arg == "+vcd" || arg == "+trace") {
            vlt_vcd = true;
        } else if (arg.rfind("+vcdfile=", 0) == 0) {
            vlt_vcd = true;
            vlt_vcd_file = arg.substr(std::string("+vcdfile=").size());
        } else if (arg.rfind("+progress=", 0) == 0) {
            vlt_progress_cycles = std::stoull(arg.substr(10));
        }
    }
}

void Sim::idle() { target.switch_to(); }

/// Execute the simulation.
int Sim::run() {
    host = context_t::current();
    target.init(sim_thread_main, this);

    int exit_code = htif_t::run();
    if (exit_code > 0)
      fprintf(stderr, "[FAILURE] Finished with exit code %2d\n", exit_code);
    else
      fprintf(stderr, "[SUCCESS] Program finished successfully\n");
    return exit_code;
}

void Sim::main() {
    // Initialize verilator environment.
    Verilated::traceEverOn(vlt_vcd);

    // Create a pointer to ourselves
    s = this;

    // Allocate the simulation state.
    auto top = std::make_unique<Vtestharness>();
    std::unique_ptr<VerilatedVcdC> tfp;
    if (vlt_vcd) {
#ifndef SPATZ_NO_WAVEFORM
        tfp = std::make_unique<VerilatedVcdC>();
        top->trace(tfp.get(), 99);
        tfp->open(vlt_vcd_file.c_str());
        fprintf(stderr, "[Tracer] Writing VCD waveform to %s\n", vlt_vcd_file.c_str());
#else
        fprintf(stderr, "VCD requested from a simulator built without --trace\n");
        std::exit(1);
#endif
    }

    bool clk_i = 0, rst_ni = 0;

    while (!Verilated::gotFinish()) {
        clk_i = !clk_i;
        rst_ni = TIME >= 8;
        top->clk_i = clk_i;
        top->rst_ni = rst_ni;
        // Evaluate the DUT.
        top->eval();
        if (tfp) {
            tfp->dump(TIME);
        }
        // Increase global time.
        TIME++;
        if (vlt_progress_cycles && TIME % (2 * vlt_progress_cycles) == 0) {
            fprintf(stderr, "[PROGRESS] simulated_cycles=%d\n", TIME / 2);
        }
        // Switch to the HTIF interface in regular intervals.
        if (TIME % HTIFTimeInterval == 0) {
            host->switch_to();
        }
    }
    if (tfp) {
        tfp->close();
    }
}
}  // namespace sim

// Verilator callback to get the current time.
double sc_time_stamp() { return sim::TIME * 1e-9; }

// DPI calls.
void tb_memory_read(long long addr, int len, const svOpenArrayHandle data) {
    // std::cout << "[TB] Read " << std::hex << addr << std::dec << " (" << len
    //           << " bytes)\n";
    void *data_ptr = svGetArrayPtr(data);
    assert(data_ptr);
    sim::MEM.read(addr, len, (uint8_t *)data_ptr);
}

void tb_memory_write(long long addr, int len, const svOpenArrayHandle data,
                     const svOpenArrayHandle strb) {
    // std::cout << "[TB] Write " << std::hex << addr << std::dec << " (" << len
    //           << " bytes)\n";
    const void *data_ptr = svGetArrayPtr(data);
    const void *strb_ptr = svGetArrayPtr(strb);
    assert(data_ptr);
    assert(strb_ptr);
    sim::MEM.write(addr, len, (const uint8_t *)data_ptr,
                   (const uint8_t *)strb_ptr);
}

int get_entry_point() {
  return sim::s->entry_point();
}
