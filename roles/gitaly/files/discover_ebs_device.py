#!/usr/bin/env python3
"""Read-only discovery of an AWS Nitro EBS disk by its EC2 attachment name."""
import json
import re
import subprocess
import sys
from pathlib import Path


def command(*args):
    return subprocess.check_output(args)


def attachment_name(value):
    name = value.removeprefix('/dev/')
    if not re.fullmatch(r'sd[b-z]', name):
        raise ValueError('Use a dedicated AWS data attachment name such as /dev/sdf.')
    return name


def discover(requested, mountpoint, filesystem, format_allowed):
    requested = attachment_name(requested)
    if filesystem != 'ext4':
        raise ValueError('This storage workflow supports whole-disk ext4 only.')
    if not mountpoint.startswith('/') or mountpoint in ('/', '/boot', '/boot/efi'):
        raise ValueError('A dedicated absolute data mountpoint is required.')
    disks = json.loads(command('lsblk', '--json', '--paths', '--output',
                               'NAME,TYPE,FSTYPE,MOUNTPOINTS,RO'))['blockdevices']
    matches = []
    for disk in disks:
        device = disk['name']
        if disk['type'] != 'disk' or not re.fullmatch(r'/dev/nvme\d+n\d+', device):
            continue
        # AWS stores the attachment name in the first 32 vendor-specific bytes.
        controller = command('nvme', 'id-ctrl', device, '--raw-binary')
        if len(controller) < 4096:
            raise ValueError('Incomplete NVMe controller identity for ' + device)
        model = controller[24:64].decode('ascii').strip(' \x00')
        if model != 'Amazon Elastic Block Store':
            continue
        mapping = controller[3072:3104].decode('ascii').strip(' \x00')
        if mapping.removeprefix('/dev/') == requested:
            matches.append(disk)
    if len(matches) != 1:
        raise ValueError('Expected exactly one EBS disk attached as /dev/' + requested
                         + '; found ' + str(len(matches)) + '. No disk was changed.')
    disk = matches[0]
    device = disk['name']
    # Reject partitions, device-mapper/LVM children, boot disks, and other uses.
    if disk.get('children') or disk.get('ro'):
        raise ValueError('Refusing a partitioned, layered, or read-only disk: ' + device)
    mounts = [m for m in disk.get('mountpoints', []) if m]
    if any(m != mountpoint for m in mounts):
        raise ValueError('Selected disk is already used at another mountpoint: ' + device)
    signatures = json.loads(command('wipefs', '--json', '--no-act', device))['signatures']
    types = {s['type'] for s in signatures}
    fs = disk.get('fstype')
    if (fs not in (None, '', filesystem) or types - {filesystem}
            or (types and not fs)):
        raise ValueError('Refusing disk with unexpected filesystem or signatures: ' + device)
    blank = not fs and not types
    if blank and (mounts or not format_allowed):
        raise ValueError('Blank disk requires gitaly_format_data_disk: true.')
    # Never cover another mounted volume, or hide existing unmounted repositories.
    target = Path(mountpoint)
    if target.is_symlink():
        raise ValueError('Data mountpoint must not be a symlink.')
    if not mounts and target.exists():
        if target.is_mount() or not target.is_dir() or any(target.iterdir()):
            raise ValueError('Mountpoint is occupied; refusing to hide existing data.')
    return {'device': device, 'blank': blank, 'attachment_name': '/dev/' + requested}


if __name__ == '__main__':
    try:
        print(json.dumps(discover(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == 'true')))
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
