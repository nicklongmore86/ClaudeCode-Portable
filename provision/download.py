#!/usr/bin/env python3
"""Prep-machine downloader. No installers are executed on target hosts.
Python 3.12+, GnuPG, cosign (Linux Codex signatures), 7z (Windows Git), npm
(dashboard dependencies), and a trusted Node release keyring are prep tools.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = json.loads((ROOT / 'provision/assets.json').read_text())


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def download(url, path, expected=None):
    if not url.startswith('https://'):
        raise ValueError('Only HTTPS release URLs are permitted')
    if not path.exists() or not expected or sha256(path) != expected:
        partial = path.with_name(path.name + '.partial')
        with urllib.request.urlopen(url) as response, partial.open('wb') as stream:
            shutil.copyfileobj(response, stream)
        if expected and sha256(partial) != expected:
            partial.unlink()
            raise ValueError(f'SHA256 mismatch: {path.name}')
        partial.replace(path)
    return path


def checksums(path):
    return {line.split()[1].lstrip('*'): line.split()[0] for line in path.read_text().splitlines() if line.strip()}


def extract(archive, destination):
    destination.mkdir(parents=True, exist_ok=True)
    if archive.name.endswith('.zip'):
        with zipfile.ZipFile(archive) as package:
            for item in package.infolist():
                path = (destination / item.filename).resolve()
                if not path.is_relative_to(destination.resolve()):
                    raise ValueError('Unsafe ZIP path')
            package.extractall(destination)
    else:
        with tarfile.open(archive, 'r:gz') as package:
            # Python's data filter rejects absolute/escaping paths and links/devices.
            package.extractall(destination, filter='data')


def normalize(directory, executable):
    if (directory / executable).is_file():
        return
    children = list(directory.iterdir())
    if len(children) == 1 and children[0].is_dir() and (children[0] / executable).is_file():
        inner = children[0]
        for item in inner.iterdir():
            item.rename(directory / item.name)
        inner.rmdir()
    if not (directory / executable).is_file():
        raise ValueError(f'Archive missing {executable}')


def record_files(native, shared, target):
    rows = []
    for base in [native / 'bin' / target, native / 'tools']:
        for path in sorted(base.rglob('*')):
            if path.is_file():
                rows.append(f'{sha256(path)}  {path.relative_to(native).as_posix()}\n')
    (shared / 'checksums' / f'{target}-SHA256SUMS').write_text(''.join(rows))


def prepare(args):
    shared, native = args.shared.resolve(), args.native.resolve()
    if shared == native or shared in native.parents or native in shared.parents:
        raise ValueError('Shared and native roots must be separate partitions/directories')
    target = args.target
    osname = target.split('-')[0]
    for directory in ['credentials', 'checksums', 'logs']:
        (shared / directory).mkdir(parents=True, exist_ok=True)
    for directory in ['bin', 'tools', 'state/claude', 'state/codex', 'state/xdg/config',
                      'state/xdg/cache', 'state/xdg/data', 'state/xdg/state', 'tmp']:
        (native / directory).mkdir(parents=True, exist_ok=True)
    # Keep cache and verification keyrings on the drive, including prep temp files.
    cache = native / 'tools/download-cache'
    cache.mkdir(parents=True, exist_ok=True)
    os.environ['TMPDIR'] = str(native / 'tmp')
    tempfile.tempdir = str(native / 'tmp')
    sums = download(MANIFEST['claude_sums'], cache / 'SHASUMS256.txt')
    sig = download(MANIFEST['claude_sums'] + '.sig', cache / 'SHASUMS256.txt.sig')
    keyhome = cache / 'gnupg'
    keyhome.mkdir(mode=0o700, exist_ok=True)
    gpg = ['gpg', '--batch', '--homedir', str(keyhome)]
    key = ROOT / 'provision/keys/claude-code.asc'
    listing = subprocess.check_output(gpg + ['--with-colons', '--show-keys', str(key)], text=True)
    if MANIFEST['claude_signer'] not in listing:
        raise ValueError('Claude signing-key fingerprint mismatch')
    subprocess.run(gpg + ['--import', str(key)], check=True)
    status = subprocess.check_output(gpg + ['--status-fd', '1', '--verify', str(sig), str(sums)], text=True)
    if f'[GNUPG:] VALIDSIG {MANIFEST["claude_signer"]} ' not in status:
        raise ValueError('Unexpected Claude manifest signer')
    assets = MANIFEST['targets'][target]
    if checksums(sums).get(Path(assets['claude']['url']).name) != assets['claude']['sha256']:
        raise ValueError('Signed Claude checksum differs from pinned checksum')
    bindir = native / 'bin' / target
    if bindir.exists():
        raise ValueError(f'{bindir} already exists; close all sessions and move it aside before reprovisioning')
    stage = Path(tempfile.mkdtemp(prefix='provision-', dir=native / 'tmp'))
    try:
        for tool in ['claude', 'codex', 'node']:
            asset = assets[tool]
            archive = download(asset['url'], cache / Path(asset['url']).name, asset['sha256'])
            if tool == 'codex' and osname == 'linux':
                bundle = download(asset['url'] + '.sigstore', cache / (archive.name + '.sigstore'))
                subprocess.run(['cosign', 'verify-blob', '--bundle', str(bundle),
                                '--certificate-identity', 'https://github.com/openai/codex/.github/workflows/rust-release.yml@refs/tags/' + MANIFEST['codex_version'],
                                '--certificate-oidc-issuer', 'https://token.actions.githubusercontent.com', str(archive)], check=True)
            if tool == 'node':
                base = f'https://nodejs.org/dist/v{MANIFEST["node_version"]}/'
                ns = download(base + 'SHASUMS256.txt', cache / 'node-SHASUMS256.txt')
                signature = download(base + 'SHASUMS256.txt.sig', cache / 'node-SHASUMS256.txt.sig')
                subprocess.run(['gpgv', '--keyring', str(args.node_keyring.resolve()), str(signature), str(ns)], check=True)
                if checksums(ns).get(archive.name) != asset['sha256']:
                    raise ValueError('Signed Node checksum differs from pin')
            destination = stage if tool == 'claude' else stage / tool
            extract(archive, destination)
            executable = ('claude.exe' if osname == 'win32' else 'claude') if tool == 'claude' else ('bin/codex.exe' if osname == 'win32' else 'bin/codex') if tool == 'codex' else ('node.exe' if osname == 'win32' else 'bin/node')
            normalize(destination, executable)
            if osname != 'win32':
                (destination / executable).chmod(0o755)
        stage.rename(bindir)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    if osname == 'win32':
        git = MANIFEST['git']
        archive = download(git['url'], cache / Path(git['url']).name, git['sha256'])
        subprocess.run(['7z', 'x', '-y', '-o' + str(native / 'tools/portable-git'), str(archive)], check=True)
        if not (native / 'tools/portable-git/bin/bash.exe').is_file():
            raise ValueError('Portable Git archive missing Bash')
    for folder in ['launch', 'tools/audit']:
        shutil.copytree(ROOT / folder, shared / folder, dirs_exist_ok=True)
    (shared / 'docs').mkdir(exist_ok=True)
    shutil.copy2(ROOT / 'docs/DRIVE-SPEC.md', shared / 'docs/DRIVE-SPEC.md')
    for name in ['START-HERE.md', 'README.md', 'LICENSE']:
        shutil.copy2(ROOT / name, shared / name)
    shutil.copy2(ROOT / 'provision/assets.json', shared / 'checksums/assets.json')
    shutil.copy2(sums, shared / 'checksums/claude-SHASUMS256.txt')
    shutil.copy2(sig, shared / 'checksums/claude-SHASUMS256.txt.sig')
    dashboard = native / 'tools/dashboard'
    for folder in ['lib', 'tools', 'dashboard']:
        shutil.copytree(ROOT / folder, dashboard / folder, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('download-cache', '__pycache__'))
    shutil.copy2(ROOT / 'package.json', dashboard / 'package.json')
    deps = native / 'tools/dashboard-runtime'
    deps.mkdir(exist_ok=True)
    shutil.copy2(ROOT / 'tools/runtime-manifest.json', deps / 'package.json')
    # Invoke npm's JS entry directly: Windows npm.cmd is not an executable
    # accepted by CreateProcess, and shell interpolation would misquote paths.
    node = shutil.which('node')
    npm = shutil.which('npm')
    if not node or not npm:
        raise ValueError('Prep-machine Node/npm are required for dashboard dependencies')
    npm_path = Path(npm).resolve()
    npm_cli = npm_path if npm_path.suffix == '.js' else Path(node).parent / 'node_modules/npm/bin/npm-cli.js'
    if not npm_cli.is_file():
        raise ValueError('Cannot locate prep-machine npm-cli.js')
    subprocess.run([node, str(npm_cli), 'install', '--prefix', str(deps), '--ignore-scripts', '--omit=optional',
                    '--no-audit', '--no-fund', '--cache', str(native / 'state/npm-cache')], check=True,
                   env={**os.environ, 'npm_config_update_notifier': 'false'})
    record_files(native, shared, target)
    if osname == 'win32':
        print('On a Windows prep machine run provision/windows-supervisor.ps1 -Native <AI-WIN root>, then refresh checksums with --checksums-only.')
    if osname == 'linux':
        print('Linux state ownership is private to the provisioning UID. Transfer state/ and tmp/ ownership to the target UID before use; see START-HERE.md.')
    print(f'Prepared {target} in {native}; shared launchers in {shared}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shared', type=Path, required=True)
    parser.add_argument('--native', type=Path, required=True)
    parser.add_argument('--target', choices=MANIFEST['targets'], required=True)
    parser.add_argument('--node-keyring', type=Path)
    parser.add_argument('--checksums-only', action='store_true')
    args = parser.parse_args()
    if args.checksums_only:
        record_files(args.native, args.shared, args.target)
    else:
        if not args.node_keyring or not args.node_keyring.is_file():
            parser.error('--node-keyring must be a trusted Node release GPG keyring (see START-HERE.md)')
        prepare(args)


if __name__ == '__main__':
    main()
