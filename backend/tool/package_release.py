"""Package reviewed production files only; never connects to a server."""
import datetime
import hashlib
import json
import pathlib
import tarfile
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
BACKEND = ROOT / 'backend'
report = json.loads((ROOT / 'build/backend-v2/latest-report.json').read_text())
assert report['runtime'] == '0.40.4' and report['count'] >= 13
assert report.get('flutter_live_sdk') == 'passed'
destination = ROOT / 'build/backend-v2/releases'
destination.mkdir(parents=True, exist_ok=True)
stage = pathlib.Path(tempfile.mkdtemp(prefix='store-v2-', dir=destination))
files = {}
for folder in ['pb_hooks', 'pb_migrations', 'activation_migrations']:
    for path in sorted((BACKEND / folder).rglob('*.js')):
        relative = path.relative_to(BACKEND).as_posix()
        files[relative] = path.read_bytes()
for name in ['pocketbase-v2-deployment.md', 'pocketbase-v2-validation.md']:
    files['docs/' + name] = (ROOT / 'docs' / name).read_bytes()
files['README.md'] = (BACKEND / 'README.md').read_text(encoding='utf-8').replace('../docs/', 'docs/').encode()
files['RELEASE.json'] = json.dumps({
    'pocketbase': '0.40.4', 'prepared_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'tested_platform': 'windows_amd64', 'backend_scenarios': report['count'],
    'flutter_live_sdk': report['flutter_live_sdk'], 'production_contacted': False,
    'activation_is_separate': True,
}, indent=2).encode()
assert len([name for name in files if name.endswith('.js')]) == 6
for name, content in files.items():
    target = stage / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(content)
manifest = ''.join(hashlib.sha256(content).hexdigest() + '  ' + name + '\n' for name, content in sorted(files.items()))
(stage / 'SHA256SUMS').write_text(manifest, encoding='ascii', newline='\n')
archive = stage.with_suffix('.tar.gz')
with tarfile.open(archive, 'w:gz') as bundle:
    for path in sorted(stage.rglob('*')):
        if path.is_file():
            bundle.add(path, arcname=path.relative_to(stage).as_posix())
checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_suffix(archive.suffix + '.sha256').write_text(checksum + '  ' + archive.name + '\n', encoding='ascii')
print('Release:', archive)
print('SHA256:', checksum)
