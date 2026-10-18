#!/usr/bin/env python3
"""Build an allowlisted ARM64 overlay package; inputs are explicit, no router data."""
from pathlib import Path
import argparse, hashlib, json, shutil, tarfile, subprocess, tempfile

def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
    return h.hexdigest()

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--assets',type=Path,required=True,help='Directory containing verified official downloads and UPX core')
    ap.add_argument('--output',type=Path,required=True)
    args=ap.parse_args(); src=Path(__file__).resolve().parent; repo=src.parents[1]; assets=args.assets.resolve()
    args.output.mkdir(parents=True,exist_ok=True)
    expected={'official-sce.tar.gz':'4c1695f6d8070455a65bfcd385f05455d13eeec28b8051a1cfe27b193405a706',
              'official-upx.tar.xz':'a72d112c5970a904a31da0b9c84f919bc16b9a311787c12245508544a78c7d36',
              'mihomo-linux-arm64-v1.19.32.upx':'4fc611aa8de8c87248d157b77bb43a23c5de0f69b2b2e040455f8cfb94653dfe'}
    for name,digest in expected.items():
        if sha(assets/name)!=digest: raise SystemExit('Asset SHA-256 mismatch: '+name)
    for manifest in ['sources.json','geodata-sources.json']:
        for item in json.loads((src/'resources'/manifest).read_text(encoding='utf-8'))['resources']:
            rel=item['path'].removeprefix('base/') if manifest=='sources.json' else 'geodata/'+item['path']
            if sha(src/'resources'/rel)!=item['sha256']: raise SystemExit('Resource mismatch: '+rel)
    with tempfile.TemporaryDirectory(prefix='sc-build-',dir=args.output) as temp:
        root=Path(temp)/'shellcrash-local'; root.mkdir()
        def copy(a,b):
            b.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(a,b)
        for f in ['deploy.sh','README.md']: copy(src/f,root/f)
        custom=['libs/core_upx.sh','libs/subconv.sh','local/apply.sh','local/manager.sh','local/README.md','local/MAINTENANCE.md']
        custom += ['local/modules/'+n+'.sh' for n in ['common','status','maintenance','update']]
        for f in custom: copy(repo/'scripts'/f,root/'overlay'/f)
        copy(assets/'mihomo-linux-arm64-v1.19.32.upx',root/'core/CrashCore.upx')
        for archive,dirname in [('official-sce.tar.gz','sce-extract'),('official-upx.tar.xz','upx-extract')]:
            with tarfile.open(assets/archive) as tf: tf.extractall(Path(temp)/dirname,filter='data')
        engine=Path(temp)/'sce-extract/SubConverter-Extended'
        for f in engine.rglob('*'):
            if f.is_file() and f.name not in ['subconverter-update','update.sh','UPDATE-README.txt','pref.ini']:
                copy(f,root/'subconverter-arm64'/f.relative_to(engine))
        tool=Path(temp)/'upx-extract/upx-5.2.1-arm64_linux/upx'
        if sha(tool)!='871d65c543cfda923d8502b92a58d4934c434aead8746d7b4a7f6dad66eb3dad': raise SystemExit('UPX tool mismatch')
        copy(tool,root/'overlay/tools/upx-linux-arm64')
        for name in ['rules','templates','geodata']:
            shutil.copytree(src/'resources'/name,root/name)
        for name in ['rule-map.tsv','sources.json','geodata-sources.json']: copy(src/'resources'/name,root/name)
        for name in ['build.py','deploy.sh','README.md']: copy(src/name,root/'source/packaging'/name)
        # Source for changed base scripts is a diff against a recorded upstream commit.
        git=['git','-C',str(repo)]
        patch=subprocess.check_output(git+['diff','--binary','HEAD','--','scripts'])
        (root/'source/changes.patch').write_bytes(patch)
        commit=subprocess.check_output(git+['rev-parse','HEAD'],text=True).strip()
        (root/'source/base-commit.txt').write_text(commit+'\n',encoding='utf-8')
        for f in custom: copy(repo/'scripts'/f,root/'source/scripts'/f)
        copy(repo/'LICENSE.txt',root/'licenses/ShellCrash-GPL-3.0.txt')
        copy(assets/'subconverter-upstream/LICENSE',root/'licenses/SubConverter-Extended-GPL-3.0.txt')
        for name in ['COPYING','LICENSE']:
            p=Path(temp)/'upx-extract/upx-5.2.1-arm64_linux'/name
            if p.is_file(): copy(p,root/'licenses'/('UPX-'+name+'.txt'))
        sources='''Bundled software source references (custom source in source/):
ShellCrash: https://github.com/juewuy/ShellCrash (base commit in source/base-commit.txt)
Mihomo v1.19.32: https://github.com/MetaCubeX/mihomo/tree/v1.19.32 (GPL-3.0)
SubConverter-Extended v1.10.1: https://github.com/Aethersailor/SubConverter-Extended/tree/v1.10.1 (GPL-3.0)
UPX v5.2.1: https://github.com/upx/upx/tree/v5.2.1 (GPL with special exception; see licenses)
Public rule source URLs and individual digests are recorded in sources.json and geodata-sources.json.
This bundle contains only public resource snapshots and allowlisted custom source, never router credentials.
'''
        (root/'SOURCES.md').write_text(sources,encoding='utf-8')
        copy(assets/'mihomo-LICENSE',root/'licenses/Mihomo-GPL-3.0.txt')
        files=sorted(p for p in root.rglob('*') if p.is_file())
        (root/'SHA256SUMS').write_text(''.join(f'{sha(p)}  {p.relative_to(root).as_posix()}\n' for p in files),encoding='utf-8',newline='\n')
        archive=args.output/'ShellCrash-arm64-v1.19.32-local-20261018.tar.gz'
        def metadata(info):
            info.uid=info.gid=0; info.uname=info.gname='root'; info.mtime=1792252800
            name=Path(info.name).name
            info.mode=0o755 if info.isdir() or name.endswith('.sh') or name in ['CrashCore.upx','subconverter','upx-linux-arm64'] or name.startswith('ld-') else 0o644
            return info
        with tarfile.open(archive,'w:gz',compresslevel=6) as tf: tf.add(root,arcname='shellcrash-local',filter=metadata)
        digest=sha(archive)
        archive.with_suffix(archive.suffix+'.sha256').write_text(f'{digest}  {archive.name}\n',encoding='utf-8')
        copy(src/'README.md',args.output/'ShellCrash-部署说明.md')
        # Independently verify archive contents and payload digests.
        with tarfile.open(archive) as tf:
            members={m.name:m for m in tf.getmembers() if m.isfile()}
            sums=tf.extractfile('shellcrash-local/SHA256SUMS').read().decode()
            for line in sums.splitlines():
                digest,rel=line.split('  ',1)
                if hashlib.sha256(tf.extractfile('shellcrash-local/'+rel).read()).hexdigest()!=digest: raise SystemExit('Archive verification failed: '+rel)
            if len(members)!=len(sums.splitlines())+1: raise SystemExit('Unmanifested file in package')
        print(json.dumps({'package':str(archive),'sha256':sha(archive),'bytes':archive.stat().st_size,'manifest_files':len(files),'templates':19,'rules':83,'geodata':5},ensure_ascii=False))

if __name__=='__main__': main()
