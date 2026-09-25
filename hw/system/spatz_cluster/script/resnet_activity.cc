// Counts pre-edge accepted operations and busy states from the passive RTL bind.
#include <array>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>
#include <cstdlib>

namespace sim { extern int TIME; }
static uint64_t cycles=0, busy_cycles=0, ipu_cycles=0, overlap=0;
static uint64_t first_busy=0, last_busy=0, writes=0, beats=0, adds=0, groups=0;
static uint64_t group_errors=0, width_errors=0, busy_errors=0, config_errors=0;
static std::array<uint64_t,8> states{};
static uint32_t ready_regs=0, add_regs=0;
static unsigned group_adds=0, expected_adds=0;
static std::vector<unsigned> group_plan;
static bool in_group=false, strict=false, reported_config=false;
static std::ofstream wave, events;
static std::array<unsigned,14> previous{};
static bool first_wave=true;
static const int widths[14]={3,1,5,1,1,7,1,1,5,3,32,5,32,5};
static const char* names[14]={"dimc_state_q","dimc_busy","dimc_row_q","ipu_busy",
    "dimc_wb_accept","dimc_write_addr","vadd_accept","vadd_last","vadd_vd","vadd_sew","completed_vregs","completed_output_registers","group_index","vadd_registers_in_group"};

void conv3_profile_init(int argc,char** argv) {
    std::string path="activity.vcd";
    for(int i=1;i<argc;i++) {
        std::string arg(argv[i]);
        if(arg.rfind("+group_plan=",0)==0) {
            std::ifstream input(arg.substr(12));
            unsigned size;
            if(!input) { fprintf(stderr,"Cannot open B8 group plan\n"); std::exit(1); }
            while(input>>size) {
                if(size<2 || size>16 || size%2) std::exit(1);
                group_plan.push_back(size);
            }
            if(group_plan.empty()) std::exit(1);
            strict=true;
        }
        if(arg.rfind("+activity_vcd=",0)==0)path=arg.substr(14);
    }
    wave.open(path);
    events.open("groups.csv");
    events<<"group,first_vadd_ps,completed_output_registers,first_vadd_vd\n";
    wave<<"$timescale 1ps $end\n$scope module ResNet $end\n";
    for(int i=0;i<14;i++)wave<<"$var wire "<<widths[i]<<" "<<char('a'+i)<<" "<<names[i]<<" $end\n";
    wave<<"$upscope $end\n$enddefinitions $end\n";
}

extern "C" void conv3_observe(unsigned hart,unsigned state,unsigned busy,unsigned row,unsigned ipu_busy,
    unsigned write,unsigned addr,unsigned accept,unsigned last,unsigned vd,unsigned sew,
    unsigned ipus,unsigned fpus,unsigned vlen) {
    if(hart!=0)return;
    if(!reported_config) {
        fprintf(stderr,"RTL_CONFIGURATION N_IPU=%u N_FPU=%u N_FU=%u ELEN=64 VLEN=%u\n",
                ipus,fpus,ipus>fpus?ipus:fpus,vlen);
        config_errors+=(ipus!=4 || fpus!=1 || vlen!=1024);
        reported_config=true;
    }
    ++cycles;
    if(state<states.size())++states[state];
    busy_errors+=(busy!=(state!=0));
    if(busy) {
        if(!first_busy)first_busy=cycles;
        last_busy=cycles;
        ++busy_cycles;
    }
    ipu_cycles+=!!ipu_busy;
    overlap+=(state==4 && ipu_busy);
    if(write) {
        ++writes;
        // Four 256-bit VRF words per register; word 1 completes its 16 results.
        if((addr%4)==1)ready_regs|=uint32_t(1)<<(addr/4);
    }
    unsigned observed_ready_regs=ready_regs;
    if(accept) {
        ++beats;
        width_errors+=(sew!=2);
        if(strict && !in_group) {
            expected_adds=groups<group_plan.size()?group_plan[groups]:16;
            if(groups>=group_plan.size()) ++group_errors;
            ++groups;in_group=true;group_adds=0;add_regs=0;
            unsigned count=__builtin_popcount(ready_regs);
            if(count!=expected_adds) {
                if(group_errors<8)fprintf(stderr,"PHASE_ERROR group=%llu time=%d ready=%08x count=%u\n",
                    (unsigned long long)groups,sim::TIME,ready_regs,count);
                ++group_errors;
            }
            events<<groups<<','<<sim::TIME<<','<<count<<','<<vd<<'\n';
            ready_regs=0;
        }
        if(last) ++adds;
        if(strict && last) {
            ++group_adds;add_regs|=uint32_t(1)<<vd;
            if(group_adds==expected_adds) {
                if(__builtin_popcount(add_regs)!=expected_adds)++group_errors;
                in_group=false;
            }
        }
    }
    { // Capture selected signals for the entire run; no time/size cutoff.
        std::array<unsigned,14> values={state,busy,row,ipu_busy,write,addr,accept,last,vd,sew,observed_ready_regs,static_cast<unsigned>(__builtin_popcount(observed_ready_regs)),static_cast<unsigned>(groups),group_adds};
        if(first_wave || values!=previous) {
            wave<<'#'<<sim::TIME<<'\n';
            for(int i=0;i<14;i++)if(first_wave || values[i]!=previous[i]) {
                if(widths[i]>1)wave<<'b';
                for(int bit=widths[i]-1;bit>=0;--bit)wave<<((values[i]>>bit)&1);
                if(widths[i]>1)wave<<' ';
                wave<<char('a'+i)<<'\n';
            }
            first_wave=false;previous=values;
        }
    }
}

void conv3_profile_finish() {
    if(strict && groups!=group_plan.size()) ++group_errors;
    fprintf(stderr,"RESNET_ACTIVITY dimc_busy_cycles=%llu state4_cycles=%llu state1_cycles=%llu state2_cycles=%llu state3_cycles=%llu dimc_window_cycles=%llu ipu_busy_cycles=%llu compute_ipu_busy_overlap=%llu dimc_write_words=%llu vadd_word_accepts=%llu vadd_instructions=%llu groups=%llu phase_errors=%llu width_errors=%llu busy_errors=%llu config_errors=%llu incomplete_group=%u\n",
        (unsigned long long)busy_cycles,(unsigned long long)states[4],
        (unsigned long long)states[1],(unsigned long long)states[2],(unsigned long long)states[3],
        (unsigned long long)(last_busy?last_busy-first_busy+1:0),
        (unsigned long long)ipu_cycles,(unsigned long long)overlap,(unsigned long long)writes,
        (unsigned long long)beats,(unsigned long long)adds,(unsigned long long)groups,
        (unsigned long long)group_errors,(unsigned long long)width_errors,
        (unsigned long long)busy_errors,(unsigned long long)config_errors,in_group);
    wave<<'#'<<sim::TIME<<'\n';
    wave.close();events.close();
}
