#!/usr/bin/env python3
"""Validate the public self-sign IPA, without any account or signing credentials."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import struct
import subprocess
import tempfile
import zipfile


def validate(path, allow_unsigned=False, portable=False):
    path = Path(path)
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        names = [item.filename for item in entries]
        assert len(names) == len(set(names)), 'Duplicate archive entries'
        for item in entries:
            parts = PurePosixPath(item.filename).parts
            assert parts and parts[0] == 'Payload' and '..' not in parts, 'Invalid archive path'
            assert '\\' not in item.filename and not item.flag_bits & 1, 'Unsupported archive entry'
            assert not stat.S_ISLNK(item.external_attr >> 16), 'Unexpected symbolic link'
        assert archive.testzip() is None, 'Corrupt ZIP data'
        apps = {PurePosixPath(n).parts[1] for n in names if len(PurePosixPath(n).parts) > 1}
        assert len(apps) == 1 and next(iter(apps)).endswith('.app'), 'Expected one Payload app'
        root = 'Payload/' + next(iter(apps)) + '/'
        info = plistlib.loads(archive.read(root + 'Info.plist'))
        for key in ['CFBundleIdentifier', 'CFBundleExecutable', 'CFBundleShortVersionString', 'CFBundleVersion']:
            assert isinstance(info.get(key), str) and info[key] and '$(' not in info[key], 'Missing or unresolved ' + key
        executable = info['CFBundleExecutable']
        if portable:
            assert re.fullmatch(r'[A-Za-z0-9_.-]+\.app', next(iter(apps))), 'Nonportable app directory'
            assert re.fullmatch(r'[A-Za-z0-9_.-]+', executable), 'Nonportable executable name'
            assert archive.read(root + 'Info.plist').startswith(b'<?xml'), 'Portable package requires XML Info.plist'
        assert executable == PurePosixPath(executable).name and executable not in ['.', '..'], 'Invalid executable name'
        assert info.get('CFBundlePackageType') == 'APPL', 'Not an application'
        assert info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'Not an iOS device build'
        assert info.get('UIDeviceFamily') == [1, 2], 'Missing iPhone/iPad support'
        binary_entry = archive.getinfo(root + executable)
        assert (binary_entry.external_attr >> 16) & 0o111, 'Main binary is not executable'
        binary = archive.read(binary_entry)
        assert len(binary) >= 32, 'Truncated main binary'
        magic, cpu, _, kind, commands, command_bytes, _, _ = struct.unpack_from('<8I', binary)
        assert (magic, cpu, kind) == (0xfeedfacf, 0x100000c, 2), 'Expected arm64 Mach-O executable'
        assert 32 + command_bytes <= len(binary), 'Truncated load commands'
        offset, platform, signed = 32, None, False
        for _ in range(commands):
            cmd, size = struct.unpack_from('<2I', binary, offset)
            assert size >= 8 and offset + size <= 32 + command_bytes, 'Invalid load command'
            if cmd == 0x32:
                assert size >= 24, 'Truncated build version command'
                platform = struct.unpack_from('<I', binary, offset + 8)[0]
            if cmd == 0x1d:
                assert size >= 16, 'Truncated signature command'
                start, length = struct.unpack_from('<2I', binary, offset + 8)
                assert length >= 12 and start + length <= len(binary), 'Truncated code signature'
                assert struct.unpack_from('>I', binary, start)[0] == 0xfade0cc0, 'Invalid signature blob'
                signed = True
            offset += size
        assert offset == 32 + command_bytes and platform == 2, 'Not a complete iOS device executable'
        for filename in ['Assets.car', 'LICENSE.txt', 'BiliKit-LICENSE.txt', 'THIRD_PARTY.md']:
            assert archive.getinfo(root + filename).file_size > 0, 'Missing resource: ' + filename
        assert not any(n.lower().endswith(('.mobileprovision', '.p12', '.pfx', '.pem', '.key')) for n in names), 'Private signing material in public IPA'
        if not allow_unsigned:
            assert signed, 'Missing signature structure for re-signing'
            assert root + '_CodeSignature/CodeResources' in names, 'Missing resource seal'
            with tempfile.TemporaryDirectory(prefix='bilibili-ipa-check-') as folder:
                archive.extractall(folder)
                for item in entries:
                    if not item.is_dir():
                        (Path(folder) / item.filename).chmod((item.external_attr >> 16) & 0o777)
                app = Path(folder) / root
                subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
                details = subprocess.run(['codesign', '-dvv', str(app)], check=True, capture_output=True, text=True).stderr
                assert 'Signature=adhoc' in details and 'Authority=' not in details, 'Public IPA must not contain a personal signing identity'
        return {'file': path.name, 'bytes': path.stat().st_size,
                'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
                'bundleID': info['CFBundleIdentifier'], 'architecture': 'arm64',
                'signatureStructure': signed, 'needsUserSigning': True}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--allow-unsigned', action='store_true', help='Inspect older packages without a signature structure')
    parser.add_argument('--portable', action='store_true', help='Require ASCII bundle paths and XML Info.plist for third-party importers')
    args = parser.parse_args()
    try:
        print(json.dumps(validate(args.ipa, args.allow_unsigned, args.portable), indent=2, ensure_ascii=False))
    except (AssertionError, KeyError, ValueError, OSError, struct.error, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        parser.exit(1, 'IPA validation failed: ' + str(error) + '\n')
