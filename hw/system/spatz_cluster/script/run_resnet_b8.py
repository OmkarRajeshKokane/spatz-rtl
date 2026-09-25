#!/usr/bin/env python3
"""Build frozen ResNet B8 tests, validate outputs, and run independent RTL jobs."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import csv
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[5]
CLUSTER = ROOT / 'spatz/hw/system/spatz_cluster'
BUILD = CLUSTER / 'sw/build'
SOURCE = ROOT / 'spatz/sw/riscvTests/isa/rv64uv'
BASE = ROOT / 'results/conv3_b8_psum_ipu4_20260915'
LAYERS = [('Conv1',12544,147,64), ('Conv2',3136,576,64),
          ('Conv3',784,1152,128), ('Conv4',196,2304,256),
          ('Conv5',49,4608,512), ('FinalFC',1,2048,1000)]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(value, indent=2) + '\n')
    tmp.replace(path)


def command(argv, log, cwd=ROOT, timeout=1800):
    start = time.monotonic()
    with log.open('w') as stream:
        proc = subprocess.Popen(list(map(str, argv)), cwd=cwd, stdout=stream,
                                stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while True:
                try:
                    rc = proc.wait(timeout=min(30, timeout))
                    break
                except subprocess.TimeoutExpired:
                    elapsed = time.monotonic() - start
                    print(f'{log.parent.name}: {log.name} running ({elapsed:.0f}s)', flush=True)
                    if elapsed >= timeout:
                        raise TimeoutError(f'Timeout: {log}')
        except BaseException:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            raise
    if rc:
        raise RuntimeError(f'Exit {rc}; see {log}')
    return round(time.monotonic() - start, 2)


def shape(layer):
    name, m, k, n = layer
    padded = (k + 127) // 128 * 128
    resident = n == 64 and padded <= 640
    tile = ((120832-64*padded)//(2*padded+256)//8)*8 if resident else min(m,216)
    prefix = min(m, tile+(m%tile or 8) if resident else (224 if m==784 else 40+m%8))
    return padded, tile, prefix


def group_plan(rows, tile, padded, n):
    plan = []
    for start in range(0, rows, tile):
        size = min(tile, rows-start)
        groups = [16]*(size//8) + ([2*(size%8)] if size%8 else [])
        if size < 8:
            groups = [2]*size
        for _ in range(n//32):
            for _ in range(padded//128-1):
                plan.extend(groups)
    return plan


def work_layout(rows, tile, padded, n):
    """Match the shared C work descriptors and existing TCDM tile buffers."""
    if rows==1:
        return {}
    resident = n==64 and padded<=640
    entries = ((rows+tile-1)//tile)*(n//32)*(padded//128)
    descriptor = 16 if resident else 52
    buffers = (2*tile*(padded if resident else 128) +
               (n*padded if resident else 2*32*128) + 2*tile*32*4)
    plan_bytes = (entries+1)*descriptor
    if buffers+plan_bytes>128256:
        raise RuntimeError('Work plan and buffers exceed available TCDM')
    return dict(work_plan_entries=entries,work_descriptor_bytes=descriptor,
                work_plan_bytes=plan_bytes,tcdm_buffer_bytes=buffers,
                tcdm_requested_bytes=buffers+plan_bytes)


def audit_vadd_phase(wave, plan):
    """Separate the B8 addition phase from scalar MULs that also use the IPU."""
    values = dict(dimc_state_q=0, vadd_accept=0, group_index=0,
                  vadd_registers_in_group=0)
    ids = {}
    last = phase_ticks = issue_ticks = 0
    for raw in wave.open():
        line = raw.strip()
        if line.startswith('$var '):
            fields = line.split()
            if fields[4] in values:
                ids[fields[3]] = fields[4]
        elif line.startswith('#'):
            now = int(line[1:])
            group = values['group_index']
            active = bool(group and (values['vadd_accept'] or
                          values['vadd_registers_in_group'] < plan[group-1]))
            if values['dimc_state_q'] == 4:
                phase_ticks += (now-last)*active
                issue_ticks += (now-last)*values['vadd_accept']
            last = now
        elif line.startswith('b'):
            bits, code = line[1:].split()
            if code in ids:
                values[ids[code]] = int(bits, 2)
        elif len(line)>1 and line[0] in '01' and line[1:] in ids:
            values[ids[line[1:]]] = int(line[0])
    if len(ids)!=len(values) or phase_ticks%2 or issue_ticks%2:
        raise RuntimeError(f'Invalid phase waveform: {wave}')
    return dict(compute_vadd_phase_overlap=phase_ticks//2,
                compute_vadd_issue_overlap=issue_ticks//2)


def build_observer(out):
    artifacts = out/'rtl_model'
    artifacts.mkdir(exist_ok=True)
    for entry in json.loads((BASE/'rtl_file_hashes.json').read_text()):
        if sha(Path(entry['path'])) != entry['sha256']:
            raise RuntimeError(f'RTL model is stale: {entry["path"]}')
    source = Path(__file__).with_name('resnet_activity.cc')
    shutil.copy2(source, artifacts/source.name)
    compile_cmd = json.loads((BASE/'monitor_compile_command.json').read_text())
    compile_cmd[compile_cmd.index('-c')+1] = str(artifacts/source.name)
    compile_cmd[compile_cmd.index('-o')+1] = str(artifacts/'activity.o')
    command(compile_cmd, artifacts/'compile.log')
    link = json.loads((BASE/'link_command.json').read_text())
    binary = artifacts/'spatz_cluster.ipu4_fpu1.vlt'
    link[link.index('-o')+1] = str(binary)
    link = [str(artifacts/'activity.o') if x == str(BASE/'artifacts/activity.o') else x for x in link]
    command(link, artifacts/'link.log')
    write_json(artifacts/'provenance.json', dict(
        simulator_sha256=sha(binary), observer_sha256=sha(source), N_IPU=4, N_FPU=1,
        VLEN=1024, dut_model_unchanged=True,
        linked_objects={x:sha(Path(x)) for x in link if x.endswith(('.o','.a'))},
        compile_command=compile_cmd, link_command=link))


def prepare(layer, out):
    from elftools.elf.elffile import ELFFile
    name,m,k,n = layer
    padded,tile,prefix = shape(layer)
    dst = out/name
    dst.mkdir(exist_ok=True)
    baseline = ROOT/'results/resnet_overlap_20260914/release'/name
    frozen = json.loads((baseline/'manifest.json').read_text())
    if sha(baseline/'generated_matrices.h') != frozen['header_sha256']:
        raise RuntimeError(f'Input differs from baseline: {name}')
    header = dst/'generated_matrices.h'
    shutil.copy2(baseline/header.name, header)
    kernel_rows = int(re.search(r'^#define KERN_ROWS (\d+)$', header.read_text(), re.M)[1])
    if kernel_rows != (n+31)//32*32:
        raise RuntimeError(f'Unexpected physical kernel padding: {name}')
    with (BUILD/'.resnet_b8_build.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        command(['cmake','-S',CLUSTER/'sw','-B',BUILD,
                 f'-DRESNET_OVERLAP_HEADER={header}','-DSNRT_NFPU_PER_CORE=1'], dst/'configure.log')
        command(['cmake','--build',BUILD,'-j','2','--target',
                 'test-riscvTests-vmvm_resnet_b8','test-riscvTests-vmvm_resnet_b8_check',
                 'test-riscvTests-vmvm_resnet_b8_prefix'], dst/'build.log')
        binaries = {}
        proof = {}
        for mode,suffix in [('timing',''),('check','_check'),('prefix','_prefix')]:
            target = 'test-riscvTests-vmvm_resnet_b8'+suffix
            elf_path = dst/(mode+'.elf')
            shutil.copy2(BUILD/'riscvTests'/target, elf_path)
            shutil.copy2(BUILD/'riscvTests/CMakeFiles'/(target+'.dir')/'flags.make', dst/(mode+'.flags.make'))
            binaries[mode+'_sha256'] = sha(elf_path)
            with elf_path.open('rb') as stream:
                elf = ELFFile(stream)
                sizes = {s.name:s['st_size'] for s in elf.get_section_by_name('.symtab').iter_symbols()
                         if s.name in ('data_A','data_B','serialized_C')}
                if sizes.get('data_A') != m*padded or sizes.get('data_B') != kernel_rows*padded:
                    raise RuntimeError(f'ELF matrix sizes differ: {elf_path}: {sizes}')
                units = [cu.get_top_DIE().attributes['DW_AT_name'].value.decode()
                         for cu in elf.get_dwarf_info().iter_CUs()]
                if not any(x.endswith('/vmvm_resnet_transition.c') for x in units):
                    raise RuntimeError(f'Wrong executable source: {elf_path}')
                proof[mode] = dict(matrix_symbol_bytes=sizes,dwarf_compile_units=units)
                if m>1:
                    layout = work_layout(prefix if mode=='prefix' else m,tile,padded,n)
                    sizes = {die.attributes['DW_AT_byte_size'].value
                             for cu in elf.get_dwarf_info().iter_CUs() for die in cu.iter_DIEs()
                             if die.tag=='DW_TAG_structure_type' and
                             die.attributes.get('DW_AT_name') and
                             die.attributes['DW_AT_name'].value==b'work' and
                             'DW_AT_byte_size' in die.attributes}
                    if sizes!={layout['work_descriptor_bytes']}:
                        raise RuntimeError(f'Unexpected work descriptor in {elf_path}: {sizes}')
                    proof[mode].update(layout)
    sources = {}
    for file in ('vmvm_resnet_transition.c','vmvm_resnet_b8.h','vmvm_resnet_overlap.c','vmvm_resnet_chunk_overlap.h'):
        shutil.copy2(SOURCE/file, dst/file)
        sources[file] = sha(dst/file)
    source_digest = hashlib.sha256(json.dumps(sources,sort_keys=True).encode()).hexdigest()
    write_json(dst/'elf_configuration_proof.json', proof)
    write_json(dst/'manifest.json', dict(layer=name,M=m,logical_K=k,padded_K=padded,N=n,
               tile_rows=tile,prefix_rows=prefix,physical_kernel_rows=kernel_rows,
               source_sha256=source_digest,sources=sources,
               header_sha256=sha(header),schedule=('single_position' if m==1 else 'b8_chunk_overlap'),
               N_IPU=4,N_FPU=1,VLEN=1024,**work_layout(m,tile,padded,n),**binaries))
    for variant,rows in [('full',m),('prefix',prefix)]:
        plan = group_plan(rows,tile,padded,n) if m>1 else []
        (dst/(variant+'_groups.txt')).write_text(''.join(f'{size}\n' for size in plan))
    print(f'{name}: frozen {m}x{k}x{n}, prefix={prefix}, tail={m%8 if m>1 else 1}',flush=True)


def run(layer, args, mode):
    name,m,k,n = layer
    dst = args.out/name
    manifest = json.loads((dst/'manifest.json').read_text())
    variant = {'software':'check','rtl':'timing','rtl_check':'check','rtl_prefix':'prefix'}[mode]
    elf = dst/(variant+'.elf')
    work = dst/mode
    work.mkdir(exist_ok=True)
    (work/'logs').mkdir(exist_ok=True)
    record_path = dst/(mode+'.json')
    rows = manifest['prefix_rows'] if mode=='rtl_prefix' else m
    padded,tile,_ = shape(layer)
    record = dict(layer=name,mode=mode,status='RUNNING',scheduled_rows=rows,started_unix=time.time(),
                  source_sha256=manifest['source_sha256'],header_sha256=manifest['header_sha256'],
                  elf_sha256=sha(elf),schedule=manifest['schedule'])
    write_json(record_path, record)
    try:
        if sha(elf) != manifest[variant+'_sha256']:
            raise RuntimeError(f'ELF differs from manifest: {elf}')
        if mode=='software':
            argv = [ROOT/'install/bin/gvrun','--target','spatz_v2','--work-dir',work,
                    '--param',f'chip/soc/binary={elf}','run']
        else:
            software = json.loads((dst/'software.json').read_text())
            if (software['status']!='PASS' or software['source_sha256']!=manifest['source_sha256']
                or software['elf_sha256']!=manifest['check_sha256']
                or software['header_sha256']!=manifest['header_sha256']):
                raise RuntimeError(f'Matching full software validation missing: {name}')
            sim = args.out/'rtl_model/spatz_cluster.ipu4_fpu1.vlt'
            provenance = json.loads((sim.parent/'provenance.json').read_text())
            if sha(sim)!=provenance['simulator_sha256']:
                raise RuntimeError('Simulator differs from provenance')
            record['simulator_sha256'] = sha(sim)
            if mode=='rtl':
                prefix = json.loads((dst/'rtl_prefix.json').read_text())
                if (prefix['status']!='PASS' or prefix['source_sha256']!=manifest['source_sha256']
                    or prefix['elf_sha256']!=manifest['prefix_sha256']
                    or prefix['simulator_sha256']!=record['simulator_sha256']):
                    raise RuntimeError(f'Matching RTL prefix validation missing: {name}')
            argv = [sim,elf,'+vmvm_profile_trace','+progress=100000']
            if m>1:
                plan = dst/('prefix_groups.txt' if mode=='rtl_prefix' else 'full_groups.txt')
                expected = group_plan(rows,tile,padded,n)
                if [int(x) for x in plan.read_text().split()] != expected:
                    raise RuntimeError(f'B8 group plan changed: {plan}')
                argv.append('+group_plan='+str(plan))
        record['command'] = list(map(str,argv))
        write_json(record_path, record)
        print(f'{name}: starting {mode}',flush=True)
        wall = command(argv,dst/(mode+'.log'),work,args.timeout)
        text = (dst/(mode+'.log')).read_text()
        marker = re.search(r'RESNET_(?:TRANSITION|B8_OVERLAP) M=(\d+) logical_K=(\d+) padded_K=(\d+) N=(\d+)',text)
        if not marker or tuple(map(int,marker.groups()))!=(m,k,padded,n):
            raise RuntimeError(f'Runtime configuration mismatch: {name}')
        if m>1 and f'scheduled_rows={rows} ' not in text:
            raise RuntimeError(f'Unexpected row count: {name}')
        bench = re.search(r'VMVM_BENCH (?:resnet_transition|resnet_b8_overlap) total_cycles=(\d+) compute_cycles=(\d+)',text)
        if not bench:
            raise RuntimeError(f'Missing timing marker: {name}')
        if mode!='rtl':
            if f'SOFTWARE_CHECK checked={rows*n} mismatches=0' not in text or not re.search(r'^PASS$',text,re.M):
                raise RuntimeError(f'Numerical check failed: {name}; see {mode}.log')
        elif 'RTL_TIMING_ONLY numeric_check=external_software' not in text:
            raise RuntimeError(f'Missing timing-only marker: {name}')
        if mode!='software':
            if '[SUCCESS] Program finished successfully' not in text:
                raise RuntimeError(f'Incomplete RTL: {name}')
            match = re.search(r'RESNET_ACTIVITY ([^\n]+)',text)
            if not match:
                raise RuntimeError(f'Missing activity counters: {name}')
            activity = {key:int(value) for key,value in re.findall(r'(\w+)=(\d+)',match[1])}
            if any(activity.get(key,1) for key in ('phase_errors','width_errors','busy_errors','config_errors','incomplete_group')):
                raise RuntimeError(f'RTL activity checks failed: {name}: {activity}')
            expected_state4 = rows*padded*((n+31)//32*32)//128
            if activity['state4_cycles']!=expected_state4:
                raise RuntimeError(f'Unexpected DIMC arithmetic coverage: {name}: {activity}')
            if m>1:
                expected = group_plan(rows,tile,padded,n)
                if (activity['groups']!=len(expected) or activity['vadd_instructions']!=sum(expected)
                    or activity['vadd_word_accepts']!=sum(expected)*2):
                    raise RuntimeError(f'B8 coverage/phase violation: {name}: {activity}')
                # Spatz also executes scalar integer multiplication in its IPU.
                # Conv2's 640-byte stride can use MUL for address generation;
                # its overlap with DIMC is independent of the e32 VADD phase.
                phase = audit_vadd_phase(work/'activity.vcd',expected)
                if any(phase.values()):
                    raise RuntimeError(f'DIMC overlaps the B8 VADD phase: {name}: {phase}')
                activity.update(phase)
            record['activity'] = activity
        record.update(status='TIMING_ONLY_SUCCESS' if mode=='rtl' else 'PASS',
                      total_cycles=int(bench[1]),compute_region_cycles=int(bench[2]),wall_seconds=wall,
                      logical_macs=rows*k*n,scheduled_macs=rows*padded*((n+31)//32*32),
                      finished_unix=time.time())
        write_json(record_path,record)
        print(f'{name}: {mode} {record["status"]}, cycles={record["total_cycles"]}',flush=True)
    except Exception as error:
        record.update(status='FAIL',error=str(error),finished_unix=time.time())
        write_json(record_path,record)
        print(f'{name}: {mode} FAIL: {error}',flush=True)
        raise


def run_phase(layers,args,mode):
    errors = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        jobs = {pool.submit(run,layer,args,mode):layer[0] for layer in layers}
        for future in as_completed(jobs):
            try:
                future.result()
            except Exception as error:
                errors.append(f'{jobs[future]}: {error}')
    if errors:
        raise RuntimeError('\n'.join(errors))


def collect(out):
    rows = []
    for name,*_ in LAYERS:
        for mode in ('software','rtl_prefix','rtl','rtl_check'):
            path=out/name/(mode+'.json')
            if path.exists():
                row=json.loads(path.read_text())
                manifest=json.loads((out/name/'manifest.json').read_text())
                variant={'software':'check','rtl':'timing','rtl_check':'check','rtl_prefix':'prefix'}[mode]
                if (row['source_sha256']!=manifest['source_sha256']
                    or row['header_sha256']!=manifest['header_sha256']
                    or row['elf_sha256']!=manifest[variant+'_sha256']):
                    continue
                activity=row.pop('activity',{})
                row.update({key:activity[key] for key in ('dimc_busy_cycles','state4_cycles') if key in activity})
                row.pop('command',None);rows.append(row)
    if rows:
        fields=list(dict.fromkeys(key for row in rows for key in row))
        with (out/'results.csv').open('w') as stream:
            writer=csv.DictWriter(stream,fields);writer.writeheader();writer.writerows(rows)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--mode',choices=('prepare','software','rtl_prefix','rtl','rtl_check','check','all'),required=True)
    parser.add_argument('--layers',default=','.join(x[0] for x in LAYERS))
    parser.add_argument('--workers',type=int,choices=(1,2,3),default=2,
                        help='Concurrent layer simulations; builds always run serially')
    parser.add_argument('--timeout',type=int,default=3600,help='Maximum seconds per process')
    args=parser.parse_args();args.out=args.out.resolve();args.out.mkdir(parents=True,exist_ok=True)
    selected={x.strip() for x in args.layers.split(',')}
    unknown=selected-{x[0] for x in LAYERS}
    if unknown:parser.error('Unknown layers: '+', '.join(sorted(unknown)))
    if args.timeout<=0:parser.error('--timeout must be positive')
    layers=[x for x in LAYERS if x[0] in selected]
    os.environ['VMVM_DIMC_OPTIMIZED']='1'
    try:
        if args.mode in ('prepare','check','all'):
            build_observer(args.out)
            for layer in layers:prepare(layer,args.out)
        if args.mode in ('software','check','all'):run_phase(layers,args,'software')
        if args.mode in ('rtl_prefix','check','all'):run_phase(layers,args,'rtl_prefix')
        if args.mode in ('rtl','all'):run_phase(layers,args,'rtl')
        if args.mode=='rtl_check':run_phase(layers,args,'rtl_check')
    finally:
        collect(args.out)

if __name__=='__main__':
    main()
