"""Packaging failures that must not be published as a self-sign IPA."""
import importlib.util
from pathlib import Path
import plistlib
import stat
import struct
import tempfile
import unittest
import warnings
import zipfile

spec = importlib.util.spec_from_file_location('ipa_validator', Path(__file__).parents[1] / 'validate-ipa.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class IPAValidationTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.path = Path(self.folder.name) / 'test.ipa'
        self.root = 'Payload/Test.app/'
        info = dict(CFBundleIdentifier='test.local', CFBundleExecutable='Test',
                    CFBundleShortVersionString='0.1.2', CFBundleVersion='6',
                    CFBundlePackageType='APPL', CFBundleSupportedPlatforms=['iPhoneOS'],
                    UIDeviceFamily=[1, 2])
        # One complete LC_BUILD_VERSION, targeting an arm64 iOS device.
        binary = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, 24, 0, 0)
        binary += struct.pack('<6I', 0x32, 24, 2, 0, 0, 0)
        self.files = {self.root + 'Info.plist': plistlib.dumps(info), self.root + 'Test': binary}
        for name in ['Assets.car', 'LICENSE.txt', 'BiliKit-LICENSE.txt', 'THIRD_PARTY.md']:
            self.files[self.root + name] = b'fixture'

    def pack(self, executable=True):
        with zipfile.ZipFile(self.path, 'w') as archive:
            for name, data in self.files.items():
                item = zipfile.ZipInfo(name)
                item.create_system = 3
                mode = 0o755 if name == self.root + 'Test' and executable else 0o644
                item.external_attr = (stat.S_IFREG | mode) << 16
                archive.writestr(item, data)

    def check(self):
        return validator.validate(self.path, allow_unsigned=True)

    def test_complete_old_unsigned_package(self):
        self.pack()
        result = self.check()
        self.assertEqual(result['build'], '6')
        self.assertFalse(result['signatureStructure'])
        with self.assertRaisesRegex(AssertionError, 'signature structure'):
            validator.validate(self.path)

    def test_portable_bundle_is_accepted(self):
        self.pack()
        result = validator.validate(self.path, allow_unsigned=True, portable=True)
        self.assertEqual(result['bundleID'], 'test.local')

    def test_portable_import_rejects_spaces_and_binary_plist(self):
        self.files = {name.replace('Test.app', 'Test App.app'): data for name, data in self.files.items()}
        self.pack()
        with self.assertRaisesRegex(AssertionError, 'Nonportable app directory'):
            validator.validate(self.path, allow_unsigned=True, portable=True)
        self.files = {name.replace('Test App.app', 'Test.app'): data for name, data in self.files.items()}
        name = self.root + 'Info.plist'
        self.files[name] = plistlib.dumps(plistlib.loads(self.files[name]), fmt=plistlib.FMT_BINARY)
        self.pack()
        with self.assertRaisesRegex(AssertionError, 'XML Info.plist'):
            validator.validate(self.path, allow_unsigned=True, portable=True)

    def test_truncated_executable(self):
        self.files[self.root + 'Test'] = b'not a complete Mach-O'
        self.pack()
        with self.assertRaisesRegex(AssertionError, 'Truncated main binary'):
            self.check()

    def test_missing_executable(self):
        del self.files[self.root + 'Test']
        self.pack()
        with self.assertRaises(KeyError):
            self.check()

    def test_non_executable_mode(self):
        self.pack(executable=False)
        with self.assertRaisesRegex(AssertionError, 'not executable'):
            self.check()

    def test_path_traversal(self):
        self.files['Payload/../../escape'] = b'bad'
        self.pack()
        with self.assertRaisesRegex(AssertionError, 'Invalid archive path'):
            self.check()

    def test_private_signing_material(self):
        self.files[self.root + 'embedded.mobileprovision'] = b'private fixture'
        self.pack()
        with self.assertRaisesRegex(AssertionError, 'Private signing material'):
            self.check()

    def test_simulator_binary(self):
        binary = bytearray(self.files[self.root + 'Test'])
        struct.pack_into('<I', binary, 40, 7)
        self.files[self.root + 'Test'] = binary
        self.pack()
        with self.assertRaisesRegex(AssertionError, 'iOS device executable'):
            self.check()

    def test_duplicate_entry(self):
        self.pack()
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(self.path, 'a') as archive:
                archive.writestr(self.root + 'Assets.car', b'duplicate')
        with self.assertRaisesRegex(AssertionError, 'Duplicate archive entries'):
            self.check()

    def test_corrupt_archive(self):
        self.pack()
        self.path.write_bytes(self.path.read_bytes()[:-40])
        with self.assertRaises(zipfile.BadZipFile):
            self.check()


if __name__ == '__main__':
    unittest.main()
