"""OCR proxy only; never packages a server, model, fixture, migration or database."""
import hashlib
import io
import json
import pathlib
import tarfile

root=pathlib.Path(__file__).resolve().parents[2]
report=json.loads((root/'build/backend-v3/ocr-proxy-report.json').read_text())
assert report['proxy']=='passed' and report['count']>=6 and report['production_contacted'] is False
v2=json.loads((root/'build/backend-v2/latest-report.json').read_text())
assert v2['count']>=13 and v2['flutter_live_sdk']=='passed'
files={
    'pb_hooks/ocr_v3.pb.js':(root/'backend/catalog_v3/pb_hooks/ocr_v3.pb.js').read_bytes(),
    'pb_hooks/lib/paddle_proxy.js':(root/'backend/catalog_v3/pb_hooks/lib/paddle_proxy.js').read_bytes(),
    'README.md':(root/'docs/paddleocr-integration.md').read_bytes(),
}
files['SHA256SUMS']=''.join(hashlib.sha256(data).hexdigest()+'  '+name+'\n' for name,data in sorted(files.items())).encode()
archive=root/'build/backend-v3/releases/store-paddle-proxy.tar.gz'
archive.parent.mkdir(parents=True,exist_ok=True)
with tarfile.open(archive,'w:gz') as output:
    for name,data in files.items():
        info=tarfile.TarInfo(name);info.size=len(data);info.mode=0o644
        output.addfile(info,io.BytesIO(data))
with tarfile.open(archive) as bundle:
    for member in bundle.getmembers():assert bundle.extractfile(member).read()==files[member.name]
checksum=hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_suffix('.tar.gz.sha256').write_text(checksum+'  '+archive.name+'\n',encoding='ascii')
print(archive);print('SHA256:',checksum)
