"""No release downloads or devices: fixtures, plus optional sgdisk on a regular file."""
import importlib.util
import io
import json
import re
import runpy
import shutil
import stat
import subprocess
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

    def test_checksums_cover_companions_and_tools(self):
        native = self.base / 'native'; shared = self.base / 'shared'
        (shared / 'checksums').mkdir(parents=True)
        for name in ['bin/linux-x64/claude', 'bin/linux-x64/codex/bin/codex', 'bin/linux-x64/codex/codex-path/rg', 'tools/DriveChild.dll']:
            path = native / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b'fixture')
        drive.record_files(native, shared, 'linux-x64')
        rows = (shared / 'checksums/linux-x64-SHA256SUMS').read_text().splitlines()
        self.assertEqual(len(rows), 4)
        self.assertTrue(any('codex-path/rg' in row for row in rows))


spec = importlib.util.spec_from_file_location('partition_linux', ROOT / 'provision/partition-linux.py')
partition = importlib.util.module_from_spec(spec)
spec.loader.exec_module(partition)


class PartitionTests(unittest.TestCase):
    SIZE = 512_110_190_592
    SHARED = 99_791_929_344
    GIB = 1024 ** 3

    def rows(self, size=SIZE, sector=512):
        return [dict(path='/dev/mockdrive', type='disk', size=size,
                     model='Test SSD', serial='MOCK123', mountpoints=[None],
                     ro=False, **{'log-sec': sector}),
                dict(path='/dev/system', type='disk', children=[
                    dict(path='/dev/system1', type='part', mountpoints=['/'])])]

    def plan(self, native_size=None, size=SIZE, sector=512):
        return partition.plan('/dev/mockdrive', self.rows(size, sector),
                              '/dev/system1', native_size)[1]

    def test_native_sizes_and_shared_remainder(self):
        for sector in (512, 4096):
            with self.subTest(sector=sector):
                args = self.plan(128, sector=sector)[1]
                self.assertEqual([args[i + 1] for i, arg in enumerate(args) if arg == '-n'],
                                 ['1:1MiB:+95169MiB', '2:0:+128GiB',
                                  '3:0:+128GiB', '4:0:+128GiB'])
                end = 1024 ** 2 + self.SHARED + 3 * 128 * self.GIB
                self.assertEqual(self.SIZE - end, 352256)
                self.assertGreaterEqual(self.SIZE - end, 16384 + sector)
                self.assertLess(self.SIZE - end, 1024 ** 2 + 16384 + sector)

    def test_shared_floor(self):
        with self.assertRaisesRegex(ValueError, 'smaller than 8 GiB'):
            self.plan(157)
        # Exactly 8 GiB is allowed; one MiB less is refused.
        boundary = (3 * 128 + 8) * self.GIB + 2 * 1024 ** 2
        self.assertIn('1:1MiB:+8192MiB', self.plan(128, size=boundary)[1])
        with self.assertRaisesRegex(ValueError, 'smaller than 8 GiB'):
            self.plan(128, size=boundary - 1024 ** 2)

    def test_invalid_native_sizes(self):
        for value in (0, -1, 1.5, 128.0, '128', 'bad', True):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'positive integer'):
                self.plan(value)

    def test_invalid_sector_sizes_refused_cleanly(self):
        message = 'Refusing invalid logical sector size (log-sec); expected positive integer bytes'
        for label, value in [('null', None), ('missing', None), ('zero', '0'),
                             ('garbage', 'bad'), ('negative', -512)]:
            with self.subTest(sector=label):
                rows = self.rows(sector=value)
                if label == 'missing':
                    del rows[0]['log-sec']
                with self.assertRaises(ValueError) as error:
                    partition.plan('/dev/mockdrive', rows, '/dev/system1', 128)
                self.assertEqual(str(error.exception), message)
                # Exercise the script's refusal handler with every probe mocked.
                with patch.object(partition.sys, 'argv',
                                  ['partition-linux.py', '--device', '/dev/mockdrive',
                                   '--native-size', '128', '--dry-run']), \
                        patch.object(subprocess, 'check_output', side_effect=[
                            '/dev/system1', json.dumps({'blockdevices': rows})]), \
                        patch.object(subprocess, 'run') as run, \
                        patch.object(partition.sys, 'stdout', io.StringIO()) as output:
                    with self.assertRaises(SystemExit) as refusal:
                        runpy.run_path(str(ROOT / 'provision/partition-linux.py'), run_name='__main__')
                    self.assertEqual(refusal.exception.code, message)
                    self.assertEqual(output.getvalue(), '')
                    run.assert_not_called()

    def test_invalid_cli_sizes_write_nothing(self):
        for value in ('0', '-1', '1.5', 'abc'):
            with self.subTest(value=value), patch.object(partition.sys, 'argv',
                    ['partition-linux.py', '--device', '/dev/mockdrive', '--native-size', value]), \
                    patch.object(partition, 'command') as probe, \
                    patch.object(partition.subprocess, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'positive integer'):
                    partition.main()
                probe.assert_not_called()
                run.assert_not_called()

    def test_default_printed_plan_unchanged(self):
        expected = """Device: /dev/mockdrive; identity: Test SSD / MOCK123
sgdisk --zap-all /dev/mockdrive
sgdisk -n 1:1MiB:+8GiB -t 1:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 -c 1:AI-SHARED -n 2:0:+155GiB -t 2:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 -c 2:AI-WIN -n 3:0:+155GiB -t 3:7C3457EF-0000-11AA-AA11-00306543ECAC -c 3:AI-MAC -n 4:0:0 -t 4:0FC63DAF-8483-4772-8E79-3D69D8477DE4 -c 4:AI-LINUX --attributes=3:set:63 --attributes=4:set:63 /dev/mockdrive
partprobe /dev/mockdrive
udevadm settle
mkfs.exfat -n AI-SHARED /dev/mockdrive1
mkfs.ntfs -Q -L AI-WIN /dev/mockdrive2
mkfs.ext4 -L AI-LINUX /dev/mockdrive4
Partition 3 is an APFS placeholder: format it on a Mac; see START-HERE.md.
DRY RUN: no writes and no confirmation requested.
"""
        output = io.StringIO()
        with patch.object(partition.sys, 'argv',
                          ['partition-linux.py', '--device', '/dev/mockdrive', '--dry-run']), \
                patch.object(partition, 'probe', return_value=self.rows()), \
                patch.object(partition, 'command', side_effect=['/dev/system1', '']), \
                patch.object(partition.sys, 'stdout', output), \
                patch.object(partition.subprocess, 'run') as run:
            partition.main()
        self.assertEqual(output.getvalue().encode(), expected.encode())
        run.assert_not_called()

    def test_native_cli_replans_after_confirmation_without_writes(self):
        changed = self.rows(size=self.SIZE - 1024 ** 2)
        with patch.object(partition.sys, 'argv',
                          ['partition-linux.py', '--device', '/dev/mockdrive', '--native-size', '128']), \
                patch.object(partition, 'probe', side_effect=[self.rows(), changed]), \
                patch.object(partition, 'command', side_effect=['/dev/system1', '']), \
                patch.object(partition.os, 'stat') as device_stat, \
                patch.object(partition.sys.stdin, 'isatty', return_value=True), \
                patch.object(partition.os, 'geteuid', return_value=0), \
                patch('builtins.input', return_value='Test SSD / MOCK123'), \
                patch.object(partition.sys, 'stdout', io.StringIO()), \
                patch.object(partition, 'plan', wraps=partition.plan) as planner, \
                patch.object(partition.subprocess, 'run') as run:
            device_stat.return_value.st_mode = stat.S_IFBLK
            with self.assertRaisesRegex(ValueError, 'Device changed during confirmation'):
                partition.main()
            self.assertEqual(planner.call_count, 2)
            self.assertTrue(all(call.args[3] == 128 for call in planner.call_args_list))
            run.assert_not_called()

    @unittest.skipUnless(shutil.which('sgdisk'), 'sgdisk is not installed')
    def test_sgdisk_sparse_regular_file(self):
        with tempfile.TemporaryDirectory(prefix='.partition-file-') as directory:
            disk = Path(directory) / 'disk.img'
            with disk.open('xb') as stream:
                # Check a small hole first: non-sparse filesystems must never
                # attempt to allocate the full 512 GB image.
                for size in (1024 ** 2, self.SIZE):
                    stream.truncate(size)
                    metadata = disk.stat()
                    self.assertTrue(stat.S_ISREG(metadata.st_mode))
                    blocks = getattr(metadata, 'st_blocks', None)
                    if blocks is None or blocks * 512 >= metadata.st_size // 100:
                        self.skipTest('System temp filesystem does not provide verifiable sparse files')
            # Execute ONLY the partition-table command, targeting our new file.
            args = self.plan(128)[1][:-1] + [str(disk)]
            subprocess.run(args, check=True, capture_output=True, text=True)
            table = subprocess.check_output(['sgdisk', '--print', str(disk)], text=True)
            types = ['EBD0A0A2-B9E5-4433-87C0-68B6B72699C7'] * 2 + [
                '7C3457EF-0000-11AA-AA11-00306543ECAC',
                '0FC63DAF-8483-4772-8E79-3D69D8477DE4']
            next_start = 2048
            for number, label in enumerate(['AI-SHARED', 'AI-WIN', 'AI-MAC', 'AI-LINUX'], 1):
                info = subprocess.check_output(['sgdisk', f'--info={number}', str(disk)], text=True)
                start = int(re.search(r'First sector: (\d+)', info)[1])
                end = int(re.search(r'Last sector: (\d+)', info)[1])
                self.assertEqual(start, next_start)
                self.assertEqual(start % 2048, 0)
                self.assertEqual((end - start + 1) * 512,
                                 self.SHARED if number == 1 else 128 * self.GIB)
                self.assertIn(f'Partition GUID code: {types[number - 1]}', info)
                self.assertIn(f"Partition name: '{label}'", info)
                self.assertIn(label, table)
                bits = '8000000000000000' if number in (3, 4) else '0000000000000000'
                self.assertIn(f'Attribute flags: {bits}', info)
                next_start = end + 1
            self.assertLessEqual(next_start, self.SIZE // 512 - 33)
            verify = subprocess.check_output(['sgdisk', '--verify', str(disk)], text=True)
            self.assertIn('No problems found.', verify)


if __name__ == '__main__':
    unittest.main()
