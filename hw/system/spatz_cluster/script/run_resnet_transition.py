#!/usr/bin/env python3
"""Use the frozen accepted inputs; validate new scheduling in GVSOC and time in RTL.
Run from a shell with the repository's sourceme.sh loaded. RTL runs are serial.
"""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

SPATZ_ROOT = Path(__file__).resolve().parents[4]
ROOT = Path(os.environ.get('GVSOC_ROOT', SPATZ_ROOT.parent)).resolve()
CLUSTER = SPATZ_ROOT / 'hw/system/spatz_cluster'
BUILD = CLUSTER / 'sw/build'
LAYERS = [('Conv1',12544,147,64),('Conv2',3136,576,64),('Conv3',784,1152,128),
          ('Conv4',196,2304,256),('Conv5',49,4608,512),('FinalFC',1,2048,1000)]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def command(argv, log, cwd=ROOT):
    with log.open('w') as f:
        process = subprocess.Popen(list(map(str,argv)),cwd=cwd,stdout=f,stderr=subprocess.STDOUT)
        started=time.monotonic()
        while True:
            try:
                rc=process.wait(timeout=30)
                break
            except subprocess.TimeoutExpired:
                print(f'{log.parent.name}: {log.name} running ({time.monotonic()-started:.0f}s)',flush=True)
    if rc:
        raise RuntimeError(f'Exit {rc}: {argv}; see {log}')

def prepare(layer, out):
    name,m,k,n=layer
    dst=out/name
    dst.mkdir(parents=True,exist_ok=True)
    baseline=ROOT/'results/resnet_overlap_20260914/release'/name
    old=json.loads((baseline/'manifest.json').read_text())
    header=dst/'generated_matrices.h'
    if sha(baseline/'generated_matrices.h')!=old['header_sha256']:
        raise RuntimeError(f'Frozen baseline header changed: {baseline}')
    shutil.copy2(baseline/'generated_matrices.h',header)
    command(['cmake','-S',CLUSTER/'sw','-B',BUILD,f'-DRESNET_OVERLAP_HEADER={header}'],dst/'configure.log')
    target='vmvm_resnet_overlap' if name=='FinalFC' else 'vmvm_resnet_transition'
    command(['cmake','--build',BUILD,'-j','2','--target','test-riscvTests-'+target,
             'test-riscvTests-'+target+'_check'],dst/'build.log')
    artifacts={}
    source=SPATZ_ROOT/f'sw/riscvTests/isa/rv64uv/{target}.c'
    shutil.copy2(source,dst/source.name)
    artifacts['source_sha256']=sha(source)
    for suffix,variant in [('', 'timing'),('_check','check')]:
        elf=dst/f'{variant}.elf'
        shutil.copy2(BUILD/f'riscvTests/test-riscvTests-{target}{suffix}',elf)
        artifacts[variant+'_sha256']=sha(elf)
    manifest=dict(layer=name,M=m,logical_K=k,padded_K=old["padded_K"],N=n,seed=20260914,
                  header_sha256=sha(header),source_file=source.name,
                  schedule='resnet_b8_overlap' if name=='FinalFC' else 'resnet_transition',
                  baseline_manifest=str(baseline/"manifest.json"),
                  runtime_allocator_sha256=sha(SPATZ_ROOT/"sw/snRuntime/src/alloc.c"),**artifacts)
    (dst/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(f'{name}: built and frozen',flush=True)

def run(layer,out,mode,sim):
    name,m,k,n=layer
    dst=out/name
    work=dst/mode
    work.mkdir(exist_ok=True)
    log=dst/f'{mode}.log'
    if mode=='software':
        argv=[ROOT/'install/bin/gvrun','--target','spatz_v2','--work-dir',work,
              '--param',f'chip/soc/binary={dst / "check.elf"}','run']
    else:
        argv=[sim,dst/('timing.elf' if mode=='rtl' else 'check.elf'),'+vmvm_profile_trace','+progress=100000']
    simulator_hash=sha(sim) if mode!='software' else None
    manifest=json.loads((dst/'manifest.json').read_text())
    variant='timing' if mode=='rtl' else 'check'
    if sha(dst/f'{variant}.elf') != manifest[f'{variant}_sha256']:
        raise RuntimeError(f'ELF differs from manifest: {dst}')
    if mode!='software':
        software=json.loads((dst/'software.json').read_text())
        if software['status']!='PASS' or software['source_sha256']!=manifest['source_sha256'] or software['header_sha256']!=manifest['header_sha256']:
            raise RuntimeError(f'Matching software validation missing: {dst}')
    (work/'logs').mkdir(exist_ok=True)
    print(f'{name}: starting {mode}',flush=True)
    begin=time.time();command(argv,log,work);wall=time.time()-begin
    text=log.read_text()
    match=re.search(r'VMVM_BENCH (?:resnet_transition|resnet_b8_overlap) total_cycles=(\d+) compute_cycles=(\d+)',text)
    if not match: raise RuntimeError(f'Missing timing: {log}')
    if mode!='rtl':
        check=re.search(r'SOFTWARE_CHECK checked=(\d+) mismatches=0',text)
        if not check or int(check[1])!=m*n or not re.search(r'^PASS$',text,re.M):
            raise RuntimeError(f'Numerical check failed: {log}')
    if mode=='rtl' and 'RTL_TIMING_ONLY numeric_check=external_software' not in text:
        raise RuntimeError(f'Missing timing-only marker: {log}')
    if mode!='software' and '[SUCCESS] Program finished successfully' not in text:
        raise RuntimeError(f'Incomplete RTL: {log}')
    row=dict(layer=name,mode=mode,total_cycles=int(match[1]),compute_cycles=int(match[2]),
             logical_macs=m*k*n,k_padded_macs=m*((k+127)//128*128)*n,
             status='TIMING_ONLY_SUCCESS' if mode=='rtl' else 'PASS',wall_seconds=round(wall,2))
    if mode!='software': row['simulator_sha256']=simulator_hash
    row['elf_sha256']=sha(dst/f'{variant}.elf')
    row['source_sha256']=manifest['source_sha256']
    row['header_sha256']=manifest['header_sha256']
    row['schedule']=manifest.get('schedule','resnet_transition')
    row['padded_macs']=m*((k+127)//128*128)*((n+31)//32*32)
    (dst/f'{mode}.json').write_text(json.dumps(row,indent=2)+'\n')
    print(f'{name}: {row}',flush=True)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--mode',choices=['prepare','software','rtl','rtl_check','all'],required=True)
    ap.add_argument('--layers',default='Conv2,Conv3,Conv4,Conv5,FinalFC',help='Comma-separated layer names; default: Conv2 through FinalFC')
    ap.add_argument('--rtl-bin',type=Path,default=ROOT/'results/conv1_transition_overlap_20260914/rtl_early_done/artifacts/spatz_cluster.early_done.vlt')
    args=ap.parse_args();args.out=args.out.resolve();args.rtl_bin=args.rtl_bin.resolve()
    layers=LAYERS
    if args.layers:
        selected={name.strip() for name in args.layers.split(',')}
        unknown=selected-{layer[0] for layer in LAYERS}
        if unknown: ap.error('Unknown layers: '+', '.join(sorted(unknown)))
        layers=[layer for layer in LAYERS if layer[0] in selected]
    os.environ['VMVM_DIMC_OPTIMIZED']='1'
    args.out.mkdir(parents=True,exist_ok=True)
    for layer in layers:
        if args.mode in ['prepare','all']: prepare(layer,args.out)
        if args.mode in ['software','all']: run(layer,args.out,'software',args.rtl_bin)
        if args.mode in ['rtl','all']: run(layer,args.out,'rtl',args.rtl_bin)
        if args.mode=='rtl_check': run(layer,args.out,'rtl_check',args.rtl_bin)
    rows=[]
    for layer in LAYERS:
        for mode in ['software','rtl','rtl_check']:
            p=args.out/layer[0]/f'{mode}.json'
            if p.exists():rows.append(json.loads(p.read_text()))
    if rows:
        fields=list(dict.fromkeys(k for row in rows for k in row))
        with (args.out/'results.csv').open('w') as f:
            writer=csv.DictWriter(f,fields);writer.writeheader();writer.writerows(rows)
if __name__=='__main__': main()
