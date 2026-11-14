"""Package only the tested delivery runtime. Never contacts a server."""
import hashlib
import io
import json
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[2]
report = json.loads((ROOT / 'build/backend-v2/latest-report.json').read_text())
assert report['runtime'] == '0.40.4'
assert report['production_contacted'] is False
assert report['flutter_live_sdk'] == 'passed'
files = {
    'pb_hooks/' + name: (ROOT / 'backend/pb_hooks' / name).read_bytes()
    for name in [
        'delivery_finalize.pb.js', 'lib/handlers.js',
        'lib/delivery_finalization.js', 'lib/pocketbase_store.js',
    ]
}
files['README.md'] = (ROOT / 'docs/delivery-saving-automatic-validation.md').read_bytes()
files['SHA256SUMS'] = ''.join(
    hashlib.sha256(data).hexdigest() + '  ' + name + '\n'
    for name, data in sorted(files.items())
).encode('ascii')
archive = ROOT / 'build/backend-repair/releases/storeflow-delivery-saving.tar.gz'
archive.parent.mkdir(parents=True, exist_ok=True)
with tarfile.open(archive, 'w:gz') as output:
    for name, data in sorted(files.items()):
        info = tarfile.TarInfo(name)
        info.size, info.mode = len(data), 0o644
        output.addfile(info, io.BytesIO(data))
with tarfile.open(archive) as check:
    assert set(check.getnames()) == set(files)
    for member in check:
        assert check.extractfile(member).read() == files[member.name]
checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_suffix('.gz.sha256').write_text(
    checksum + '  ' + archive.name + '\n', encoding='ascii'
)
print(archive)
print('SHA256:', checksum)
