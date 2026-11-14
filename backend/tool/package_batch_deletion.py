"""Create the two-file permanent batch-deletion release. No network access and no production mutation."""
import hashlib
import io
import json
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[2]
FILES = {
    'pb_hooks/lib/handle_expiry.js': ROOT/'backend/pb_hooks/lib/handle_expiry.js',
    'pb_hooks/lib/handlers.js': ROOT/'backend/pb_hooks/lib/handlers.js',
    'install-after-approval.sh': ROOT/'backend/batch_deletion/install-after-approval.sh',
    'DEPLOYMENT.md': ROOT/'docs/permanent-batch-deletion.md',
}
output = ROOT/'build/backend-repair/releases/storeflow-permanent-batch-deletion.tar.gz'
output.parent.mkdir(parents=True, exist_ok=True)
contents = {name: path.read_bytes().replace(b'\r\n', b'\n') for name, path in FILES.items()}
contents['SHA256SUMS'] = ''.join(
    hashlib.sha256(data).hexdigest()+'  '+name+'\n' for name, data in contents.items()
).encode()
with tarfile.open(output, 'w:gz') as archive:
    for name, data in contents.items():
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mode = 0o700 if name.endswith('.sh') else 0o600
        archive.addfile(info, io.BytesIO(data))
digest = hashlib.sha256(output.read_bytes()).hexdigest()
output.with_name(output.name+'.sha256').write_text(digest+'  '+output.name+'\n', encoding='utf-8')
print(json.dumps({'package': str(output), 'sha256': digest, 'files': list(contents), 'production_changed': False}, indent=2))
