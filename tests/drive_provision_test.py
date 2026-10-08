"""No release binaries/network access: all downloads and subprocesses are fixtures."""
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('drive_download', ROOT / 'provision/download.py')
drive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(drive)


class ProvisionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='.provision-test-', dir=ROOT)
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)

    def test_all_six_targets_use_pinned_official_packages(self):
        self.assertEqual(set(drive.MANIFEST['targets']), {f'{osname}-{arch}' for osname in ['linux', 'darwin', 'win32'] for arch in ['x64', 'arm64']})
        for target, assets in drive.MANIFEST['targets'].items():
            with self.subTest(target=target):
                for name, asset in assets.items():
                    self.assertRegex(asset['sha256'], r'^[0-9a-f]{64}$')
                    self.assertTrue(asset['url'].startswith('https://'))
                self.assertIn('/anthropics/claude-code/releases/download/v2.1.247/', assets['claude']['url'])
                self.assertIn('/openai/codex/releases/download/rust-v0.161.0/codex-package-', assets['codex']['url'])
                if target.startswith('linux'):
                    self.assertIn('musl', assets['claude']['url'])
                    self.assertIn('musl', assets['codex']['url'])

    def test_downloader_rejects_mismatch_before_install(self):
        target = self.base / 'asset'
        with patch.object(drive.urllib.request, 'urlopen', return_value=io.BytesIO(b'corrupt')):
            with self.assertRaisesRegex(ValueError, 'SHA256 mismatch'):
                drive.download('https://example.test/release', target, '0' * 64)
        self.assertFalse(target.exists())
        self.assertFalse(target.with_name('asset.partial').exists())

    def test_verified_cache_is_reused_without_network(self):
        target = self.base / 'asset'
        target.write_bytes(b'verified')
        with patch.object(drive.urllib.request, 'urlopen', side_effect=AssertionError('network')):
            self.assertEqual(drive.download('https://example.test/release', target, drive.sha256(target)), target)

    def test_safe_extraction_retains_package_layout_and_symlink(self):
        archive = self.base / 'package.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            for name in ['bin/codex', 'codex-path/rg', 'codex-resources/resource']:
                entry = tarfile.TarInfo(name); entry.size = 4; entry.mode = 0o755
                tar.addfile(entry, io.BytesIO(b'fake'))
            link = tarfile.TarInfo('bin/companion'); link.type = tarfile.SYMTYPE; link.linkname = 'codex'; tar.addfile(link)
        dest = self.base / 'out'
        drive.extract(archive, dest)
        drive.normalize(dest, 'bin/codex')
        self.assertEqual((dest / 'codex-path/rg').read_bytes(), b'fake')
        self.assertTrue((dest / 'bin/companion').is_symlink())
        self.assertEqual((dest / 'bin/codex').stat().st_mode & 0o777, 0o755)

    def test_traversal_is_rejected(self):
        archive = self.base / 'bad.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            entry = tarfile.TarInfo('../escape'); entry.size = 1; tar.addfile(entry, io.BytesIO(b'x'))
        with self.assertRaises(tarfile.FilterError):
            drive.extract(archive, self.base / 'out')
        self.assertFalse((self.base / 'escape').exists())

    def test_checksums_cover_companions_and_tools(self):
        native = self.base / 'native'; shared = self.base / 'shared'
        (shared / 'checksums').mkdir(parents=True)
        for name in ['bin/linux-x64/claude', 'bin/linux-x64/codex/bin/codex', 'bin/linux-x64/codex/codex-path/rg', 'tools/DriveChild.dll']:
            path = native / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b'fixture')
        drive.record_files(native, shared, 'linux-x64')
        rows = (shared / 'checksums/linux-x64-SHA256SUMS').read_text().splitlines()
        self.assertEqual(len(rows), 4)
        self.assertTrue(any('codex-path/rg' in row for row in rows))


if __name__ == '__main__':
    unittest.main()
