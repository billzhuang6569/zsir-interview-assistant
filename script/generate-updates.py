#!/usr/bin/env python3
"""Validate final six ZIPs, then generate the public index and hashes."""
import argparse, datetime, hashlib, json, plistlib, re, struct, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--directory', type=Path, default=ROOT / 'dist/release')
p.add_argument('--previous', type=Path)
a = p.parse_args()
version = (ROOT / 'VERSION').read_text().strip()
assert re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', version)
base = f'https://github.com/billzhuang6569/zsir-interview-assistant/releases/download/v{version}/'
assets, sums = [], []
for platform, arch, edition, minimum in [
    ('macos', 'arm64', 'standard', '13.0'), ('macos', 'x86_64', 'standard', '13.0'),
    ('macos12', 'arm64', 'monterey', '12.3'), ('macos12', 'x86_64', 'monterey', '12.3'),
    ('windows', 'x64', 'standard', '10.0.19041'), ('windows', 'arm64', 'standard', '10.0.22000')]:
    name = f'ZSirCapture-{version}-{platform}-{arch}.zip'
    path = a.directory / name
    with zipfile.ZipFile(path, metadata_encoding='utf-8') as z:
        assert z.testzip() is None, name
        names = {n.replace('\\', '/'): n for n in z.namelist()}
        if platform.startswith('macos'):
            plists = [n for n in names if n.endswith('.app/Contents/Info.plist') and not n.startswith('__MACOSX/')]
            assert len(plists) == 1
            info = plistlib.loads(z.read(names[plists[0]]))
            assert info['CFBundleShortVersionString'] == version and info['LSMinimumSystemVersion'] == minimum
            assert info['CFBundleIdentifier'].endswith('.monterey' if edition == 'monterey' else '.dev')
            executable = plists[0].replace('Info.plist', 'MacOS/ZSirCapture')
            data = z.read(names[executable])
            magic, cpu = struct.unpack_from('<II', data)
            assert magic == 0xfeedfacf and cpu == (0x100000c if arch == 'arm64' else 0x1000007)
            # LC_BUILD_VERSION must agree with the declared deployment target.
            cursor, found = 32, False
            for _ in range(struct.unpack_from('<I', data, 16)[0]):
                cmd, size = struct.unpack_from('<II', data, cursor)
                if cmd == 0x32:
                    target = struct.unpack_from('<I', data, cursor + 12)[0]
                    expected = (12 << 16 | 3 << 8) if edition == 'monterey' else 13 << 16
                    assert target == expected, f'{name}: Mach-O minimum OS differs from manifest'
                    found = True
                cursor += size
            assert found
        else:
            prefix = f'ZSirCapture-{version}-windows-{arch}/'
            exe = z.read(names[prefix + 'ZSirCapture.Windows.exe'])
            pe = struct.unpack_from('<I', exe, 0x3c)[0]
            assert struct.unpack_from('<H', exe, pe + 4)[0] == (0xaa64 if arch == 'arm64' else 0x8664)
            deps = json.loads(z.read(names[prefix + 'ZSirCapture.Windows.deps.json']))
            assert f'ZSirCapture.Windows/{version}' in deps['libraries']
            for required in ['tools/ffmpeg.exe', 'tools/ffprobe.exe', 'tools/FFmpeg-LICENSE.txt', 'tools/x264-LICENSE.txt', 'tools/SOURCE-NOTICE.md']:
                assert prefix + required in names
            for line in z.read(names[prefix + 'TOOLS-SHA256SUMS.txt']).decode('utf-8-sig').splitlines():
                digest, entry = line.split('  ', 1)
                assert hashlib.sha256(z.read(names[prefix + entry])).hexdigest() == digest.lower()
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        sums.append(f'{digest}  {name}')
        assets.append(dict(os='macos' if platform.startswith('macos') else 'windows', arch='x86_64' if arch == 'x64' else arch,
                           edition=edition, minOS=minimum, url=base + name, size=path.stat().st_size, sha256=digest))
source = a.directory / 'recording-tools-source.tar.gz'
assert source.is_file(), 'Corresponding source missing'
sums.append(f'{hashlib.sha256(source.read_bytes()).hexdigest()}  {source.name}')
release = dict(version=version, publishedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
               summary='Mac完整版自动检测更新；macOS13兼容及12.3独立兼容包；Windows内置录制组件，解压即用。',
               releaseURL=f'https://github.com/billzhuang6569/zsir-interview-assistant/releases/tag/v{version}', assets=assets)
history = []
if a.previous:
    previous = json.loads(a.previous.read_text())
    assert previous['schemaVersion'] == 1
    history = [r for r in previous['releases'] if r['version'] != version]
payload = json.dumps(dict(schemaVersion=1, releases=[release] + history), ensure_ascii=False, indent=2).encode()
assert len(payload) <= 262144
(a.directory / 'updates.json').write_bytes(payload)
sums.append(f'{hashlib.sha256(payload).hexdigest()}  updates.json')
(a.directory / 'SHA256SUMS.txt').write_text('\n'.join(sums) + '\n')
print('PASS six packages: versions, editions, architectures, deployment targets, bundled tools, source, hashes')
