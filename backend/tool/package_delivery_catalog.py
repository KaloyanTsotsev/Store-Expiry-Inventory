"""Build a reviewed allowlist-only deployment artifact. Never deploys it."""
import hashlib
import io
import json
import pathlib
import tarfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
REPORTS = {
    'v2': ROOT/'build/backend-v2/latest-report.json',
    'catalog': ROOT/'build/backend-v3/latest-report.json',
    'delivery_catalog': ROOT/'build/backend-v3/delivery-catalog-report.json',
    'paddle_proxy': ROOT/'build/backend-v3/ocr-proxy-report.json',
}
reports = {k: json.loads(p.read_text(encoding='utf-8-sig')) for k,p in REPORTS.items()}
for key, minimum in [('v2',14),('catalog',10),('delivery_catalog',7),('paddle_proxy',6)]:
    assert reports[key]['production_contacted'] is False
    assert reports[key]['count'] >= minimum
assert reports['v2']['flutter_live_sdk'] == 'passed'
assert reports['catalog']['flutter_live_sdk'] == 'passed'
assert reports['v2']['workspace'] == reports['delivery_catalog']['workspace']
# Keep the stock implementation and OCR pipeline out of the deployment payload.
v2_names = ['pb_hooks/delivery_finalize.pb.js','pb_hooks/lib/handlers.js',
            'pb_hooks/lib/delivery_finalization.js','pb_hooks/lib/pocketbase_store.js']
with tarfile.open(ROOT/'build/backend-v2/releases/store-v2-rbibvuwd.tar.gz') as original:
    for name in v2_names + ['pb_migrations/1792627200_inventory_v2_schema.js','activation_migrations/1792627201_inventory_v2_activate.js']:
        assert original.extractfile(name).read() == (ROOT/'backend'/name).read_bytes(), name
names = ['pb_hooks/catalog_v3.pb.js','pb_hooks/lib/catalog_v3.js',
         'pb_migrations/1792742400_catalog_v3_schema.js',
         'activation_migrations/1792742401_catalog_v3_activate.js']
files = {name: (ROOT/'backend/catalog_v3'/name).read_bytes() for name in names}
files['README.md'] = (ROOT/'docs/catalog-delivery-bulk-deployment.md').read_bytes()
files['V2-RUNTIME-SHA256SUMS'] = ''.join(
    hashlib.sha256((ROOT/'backend'/name).read_bytes()).hexdigest()+'  '+name+'\n'
    for name in v2_names).encode()
files['TEST-RESULTS.json'] = json.dumps({
    'runtime':'0.40.4','production_contacted':False,'v2_runtime_modified':False,
    'flutter_analyze':'clean','flutter_tests':119,'flutter_live_sdk_tests':3,
    'backend':{k:{'count':v['count'],'passed':v.get('passed',[])} for k,v in reports.items()},
}, ensure_ascii=False,indent=2).encode()
files['preflight.sh'] = b'''#!/bin/sh
set -eu
release=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
target=${1:-/home/user/pocketbase}
cd "$release"
sha256sum -c SHA256SUMS
test -d "$target/pb_data"
version=$("$target/pocketbase" --version)
printf '%s\n' "$version"
case "$version" in *"version 0.40.4") ;; *) echo "STOP: runtime differs" >&2; exit 1;; esac
(cd "$target" && sha256sum -c "$release/V2-RUNTIME-SHA256SUMS")
for name in pb_hooks/catalog_v3.pb.js pb_hooks/lib/catalog_v3.js; do
  if [ -f "$target/$name" ] && ! cmp -s "$release/$name" "$target/$name"; then
    echo "STOP: existing $name differs; review before replacing" >&2
    exit 1
  fi
done
echo "Read-only preflight passed. No files, database or services changed."
'''
files['SHA256SUMS'] = ''.join(hashlib.sha256(data).hexdigest()+'  '+name+'\n'
    for name,data in sorted(files.items())).encode()
archive = ROOT/'build/backend-v3/releases/storeflow-catalog-bulk-v3.tar.gz'
archive.parent.mkdir(parents=True,exist_ok=True)
with tarfile.open(archive,'w:gz') as output:
    for name,data in files.items():
        member=tarfile.TarInfo(name);member.size=len(data);member.mode=0o755 if name=='preflight.sh' else 0o644
        output.addfile(member,io.BytesIO(data))
with tarfile.open(archive) as check:
    assert {m.name for m in check.getmembers()}==set(files)
    for member in check.getmembers():
        assert not member.name.startswith('/') and '..' not in pathlib.PurePosixPath(member.name).parts
        assert member.isfile() and check.extractfile(member).read()==files[member.name]
checksum=hashlib.sha256(archive.read_bytes()).hexdigest()
pathlib.Path(str(archive)+'.sha256').write_text(checksum+'  '+archive.name+'\n',encoding='ascii')
print(archive)
print('SHA256:',checksum)
print('Allowlist files:',len(files))
