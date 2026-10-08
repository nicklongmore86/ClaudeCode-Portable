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

    def test_npm_cli_lookup_fallbacks_and_failure(self):
        node = '/prep/node/bin/node'
        npm = '/prep/npm-wrapper'
        candidates = [
            Path('/prep/node/bin/node_modules/npm/bin/npm-cli.js'),
            Path('/prep/node/lib/node_modules/npm/bin/npm-cli.js'),
            Path('/usr/share/nodejs/npm/bin/npm-cli.js'),
            Path('/usr/lib/node_modules/npm/bin/npm-cli.js'),
        ]
        for expected in candidates:
            with self.subTest(expected=expected), patch.object(Path, 'is_file', lambda p: p.resolve() == expected):
                self.assertEqual(drive.find_npm_cli(node, npm).resolve(), expected)
        with patch.object(Path, 'is_file', return_value=False):
            with self.assertRaisesRegex(ValueError, 'Cannot locate'):
                drive.find_npm_cli(node, npm)
        direct = self.base / 'npm-cli.js'
        direct.write_text('// fixture')
        self.assertEqual(drive.find_npm_cli(node, str(direct)), direct)

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

    def test_unix_targets_include_pinned_python_assets(self):
        self.assertEqual(drive.MANIFEST['python_version'], '3.12.15+20261003')
        unix_targets = ['darwin-x64', 'darwin-arm64', 'linux-x64', 'linux-arm64']
        for target in unix_targets:
            with self.subTest(target=target):
                assets = drive.MANIFEST['targets'][target]
                self.assertIn('python', assets)
                python_asset = assets['python']
                self.assertRegex(python_asset['sha256'], r'^[0-9a-f]{64}$')
                self.assertTrue(python_asset['url'].startswith('https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.12.'))
                self.assertIn('install_only', python_asset['url'])

    def test_pip_cli_lookup_fallbacks_and_failure(self):
        python = '/prep/python/bin/python3'
        pip = '/prep/pip-wrapper'
        candidates = [
            Path('/prep/python/bin/pip'),
            Path('/prep/python/bin/pip3'),
            Path('/prep/python/bin/pip3.12'),
            Path('/usr/bin/pip3'),
            Path('/usr/local/bin/pip3'),
        ]
        for expected in candidates:
            with self.subTest(expected=expected), patch.object(Path, 'is_file', lambda p: p.resolve() == expected):
                self.assertEqual(drive.find_pip_cli(python).resolve(), expected)
        with patch.object(Path, 'is_file', return_value=False):
            with self.assertRaisesRegex(ValueError, 'Cannot locate prep-machine pip CLI'):
                drive.find_pip_cli(python)
        direct = self.base / 'pip'
        direct.write_text('#!/bin/sh')
        self.assertEqual(drive.find_pip_cli(python, str(direct)), direct)

    def test_safe_extraction_normalizes_python_and_preserves_terminfo(self):
        archive = self.base / 'cpython.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            for name in ['python/bin/python3', 'python/share/terminfo/t/tmux-256color', 'python/share/terminfo/x/xterm-256color']:
                entry = tarfile.TarInfo(name); entry.size = 4; entry.mode = 0o755 if 'bin' in name else 0o644
                tar.addfile(entry, io.BytesIO(b'term'))
        dest = self.base / 'python'
        drive.extract(archive, dest)
        drive.normalize(dest, 'bin/python3')
        self.assertEqual((dest / 'bin/python3').read_bytes(), b'term')
        self.assertEqual((dest / 'bin/python3').stat().st_mode & 0o777, 0o755)
        self.assertTrue((dest / 'share/terminfo/t/tmux-256color').is_file())
        self.assertTrue((dest / 'share/terminfo/x/xterm-256color').is_file())

    def test_checksums_cover_companions_and_tools(self):
        native = self.base / 'native'; shared = self.base / 'shared'
        (shared / 'checksums').mkdir(parents=True)
        for name in [
            'bin/linux-x64/claude',
            'bin/linux-x64/codex/bin/codex',
            'bin/linux-x64/codex/codex-path/rg',
            'bin/linux-x64/python/bin/python3',
            'tools/omnigent-host',
            'tools/omnigent-runtime/requirements.txt',
            'tools/DriveChild.dll'
        ]:
            path = native / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b'fixture')
        drive.record_files(native, shared, 'linux-x64')
        rows = (shared / 'checksums/linux-x64-SHA256SUMS').read_text().splitlines()
        self.assertEqual(len(rows), 7)
        self.assertTrue(any('python/bin/python3' in row for row in rows))
        self.assertTrue(any('tools/omnigent-host' in row for row in rows))
        self.assertTrue(any('tools/omnigent-runtime/requirements.txt' in row for row in rows))


if __name__ == '__main__':
    unittest.main()

