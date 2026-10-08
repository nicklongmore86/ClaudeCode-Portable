#!/usr/bin/env python3
"""Destructive prep-machine helper. Tests must use --dry-run with mocked probes."""
import argparse
import json
import os
import re
import subprocess
import sys
import stat


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def plan(device, rows, root_source):
    if not re.fullmatch(r'/dev/[A-Za-z0-9._/-]+', device):
        raise ValueError('Provide an absolute /dev/ whole-disk path')
    nodes = []

    def walk(items, parents=()):
        for node in items:
            nodes.append((node, parents))
            walk(node.get('children', []), parents + (node['path'],))
    walk(rows)
    root_nodes = [(n, p) for n, p in nodes if n['path'] == root_source]
    if not root_nodes:
        raise ValueError('Cannot prove system disk topology; refusing (containers/network/ZFS roots require a physical prep host)')
    if any(n['path'] == device or device in p for n, p in root_nodes):
        raise ValueError('Refusing system disk')
    candidates = [(n, p) for n, p in nodes if n['path'] == device]
    if len(candidates) != 1 or candidates[0][0]['type'] != 'disk':
        raise ValueError('Device must identify exactly one whole disk (not a partition, loop or mapper)')
    disk = candidates[0][0]
    # Reject all mounted descendants, not only /. This also protects /boot, /home,
    # swap, and mounted LVM/RAID graphs whose physical ancestors include this disk.
    for node, parents in nodes:
        if node['path'] == device or device in parents:
            if any(node.get('mountpoints') or []) or node.get('ro'):
                raise ValueError('Refusing mounted/system/read-only disk; unmount all non-system volumes first')
    size = int(disk['size'])
    gib = 1024 ** 3
    if size < 48 * gib:
        raise ValueError('At least 48 GiB required')
    model, serial = (str(disk.get(k) or '').strip() for k in ('model', 'serial'))
    if not model or not serial:
        raise ValueError('Refusing device without both model and serial identity')
    rest = (size // gib - 9) // 3
    suffix = 'p' if device[-1].isdigit() else ''
    part = lambda n: f'{device}{suffix}{n}'
    commands = [
        ['sgdisk', '--zap-all', device],
        ['sgdisk', '-n', '1:1MiB:+8GiB', '-t', '1:0700', '-c', '1:AI-SHARED',
         '-n', f'2:0:+{rest}GiB', '-t', '2:0700', '-c', '2:AI-WIN',
         '-n', f'3:0:+{rest}GiB', '-t', '3:af0a', '-c', '3:AI-MAC',
         '-n', '4:0:0', '-t', '4:8300', '-c', '4:AI-LINUX', device],
        ['partprobe', device], ['udevadm', 'settle'],
        ['mkfs.exfat', '-n', 'AI-SHARED', part(1)],
        ['mkfs.ntfs', '-Q', '-L', 'AI-WIN', part(2)],
        ['mkfs.ext4', '-L', 'AI-LINUX', part(4)],
    ]
    return f'{model} / {serial}', commands


def probe():
    return json.loads(command('lsblk', '--json', '--bytes', '--paths', '--output',
                              'PATH,TYPE,SIZE,MODEL,SERIAL,MOUNTPOINTS,RO'))['blockdevices']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    device = os.path.realpath(args.device)
    root_source = os.path.realpath(command('findmnt', '-rn', '-o', 'SOURCE', '/').split('[')[0])
    identity, commands = plan(device, probe(), root_source)
    # lsblk reports active swap as [SWAP], but verify the kernel list as well.
    swap = command('swapon', '--show', '--noheadings', '--raw', '--output', 'NAME')
    if swap:
        # Conservatively refuse any active swap during partitioning preparations.
        raise ValueError('Active swap exists; refusing until swap topology is cleared on the prep machine')
    print(f'Device: {device}; identity: {identity}')
    for cmd in commands:
        print(' '.join(cmd))
    print('Partition 3 is an APFS placeholder: format it on a Mac; see START-HERE.md.')
    if args.dry_run:
        print('DRY RUN: no writes and no confirmation requested.')
        return
    if not stat.S_ISBLK(os.stat(device).st_mode):
        raise ValueError('Device is not a block device')
    if not sys.stdin.isatty():
        raise ValueError('Interactive typed confirmation required')
    if os.geteuid() != 0:
        raise ValueError('Run explicitly as root on the prep machine; never elevates itself')
    if input(f'ERASE ALL DATA. Type exactly {identity}: ') != identity:
        raise ValueError('Confirmation did not match; nothing changed')
    # Detect replacement/mounting between inspection and confirmation.
    if plan(device, probe(), root_source) != (identity, commands):
        raise ValueError('Device changed during confirmation; nothing changed')
    if command('swapon', '--show', '--noheadings', '--raw', '--output', 'NAME'):
        raise ValueError('Swap changed during confirmation; nothing changed')
    for cmd in commands:
        subprocess.run(cmd, check=True)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
