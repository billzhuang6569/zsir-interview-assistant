#!/usr/bin/env python3
"""Publish only after six-package validation and GitHub asset hash verification."""
import argparse, hashlib, json, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
version = (ROOT / 'VERSION').read_text().strip()
options = argparse.ArgumentParser()
options.add_argument('--previous', type=Path)
args = options.parse_args()
repo = 'billzhuang6569/zsir-interview-assistant'
with tempfile.TemporaryDirectory() as temp:
    previous = args.previous
    if previous is None:
        latest = json.loads(subprocess.check_output(['gh', 'api', f'repos/{repo}/releases/latest']))
        if any(a['name'] == 'updates.json' for a in latest['assets']):
            subprocess.run(['gh', 'release', 'download', latest['tag_name'], '--repo', repo, '--pattern', 'updates.json', '--dir', temp], check=True)
            previous = Path(temp) / 'updates.json'
        elif version != '0.3.0':
            raise SystemExit('Previous manifest missing; provide --previous rather than dropping compatibility history')
    command = ['python3', str(ROOT / 'script/generate-updates.py')]
    if previous: command += ['--previous', str(previous)]
    subprocess.run(command, check=True)
if subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT).strip():
    raise SystemExit('Commit reviewed release sources before publishing')
tag = 'v' + version
if subprocess.check_output(['git', 'rev-parse', tag + '^{commit}'], cwd=ROOT).strip() != subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).strip():
    raise SystemExit('Release tag must point to the reviewed HEAD')
folder = ROOT / 'dist/release'
assets = sorted(folder.glob(f'ZSirCapture-{version}-*.zip'))
assert len(assets) == 6
assets += [folder / name for name in ['recording-tools-source.tar.gz', 'updates.json', 'SHA256SUMS.txt']]
repo = 'billzhuang6569/zsir-interview-assistant'
subprocess.run(['gh', 'release', 'create', tag, *map(str, assets), '--repo', repo, '--verify-tag', '--draft',
                '--title', f'庄Sir采访录制助手 {tag} · Mac / Windows 六包',
                '--notes-file', str(ROOT / f'docs/releases/{version}.md')], check=True)
# Draft releases may return 404 from the by-tag endpoint; the authenticated list includes them.
pages = json.loads(subprocess.check_output(['gh', 'api', '--paginate', '--slurp', f'repos/{repo}/releases']))
release = next(r for page in pages for r in page if r['tag_name'] == tag and r['draft'])
remote = {asset['name']: asset for asset in release['assets']}
assert set(remote) == {p.name for p in assets}, 'Uploaded asset set differs; release stays draft'
for path in assets:
    actual = remote[path.name]
    assert actual['size'] == path.stat().st_size
    assert actual['digest'] == 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest(), path.name
subprocess.run(['gh', 'release', 'edit', tag, '--repo', repo, '--draft=false', '--latest'], check=True)
print(f'https://github.com/{repo}/releases/tag/{tag}')
