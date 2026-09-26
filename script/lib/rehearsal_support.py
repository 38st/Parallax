#!/usr/bin/env python3
"""Validate upgrade direction and fingerprint the preserved bundle's structure."""
import hashlib
import os
import pathlib
import plistlib
import re
import stat
import subprocess
import sys


def release_identity(app):
    with (app / 'Contents/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    version = info['CFBundleShortVersionString']
    build = info['CFBundleVersion']
    identifier = info['CFBundleIdentifier']
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('invalid semantic bundle version')
    if not re.fullmatch(r'[1-9][0-9]*', build) or not identifier:
        raise ValueError('invalid bundle build or identifier')
    return identifier, (*map(int, version.split('.')), int(build))


def validate_upgrade(previous, candidate):
    previous_id, previous_version = release_identity(previous)
    candidate_id, candidate_version = release_identity(candidate)
    if previous_id != candidate_id:
        raise ValueError('previous and candidate bundle identifiers differ')
    if candidate_version <= previous_version:
        raise ValueError('candidate must be newer than the previous version/build')


def tree_hash(root):
    digest = hashlib.sha256()

    def record(value):
        digest.update(len(value).to_bytes(8, 'big'))
        digest.update(value)

    def visit(path):
        info = path.lstat()
        record(os.fsencode(path.relative_to(root)))
        record(str(info.st_mode).encode())
        # macOS Python does not expose os.listxattr/getxattr. xattr's hex
        # representation preserves arbitrary attribute bytes without decoding.
        attributes = subprocess.check_output(['/usr/bin/xattr', '-s', str(path)]).splitlines()
        for attribute in sorted(attributes):
            record(attribute)
            record(subprocess.check_output([
                '/usr/bin/xattr', '-s', '-p', '-x', os.fsdecode(attribute), str(path)
            ]))
        record(b'')
        if stat.S_ISLNK(info.st_mode):
            record(os.fsencode(os.readlink(path)))
        elif stat.S_ISREG(info.st_mode):
            content = hashlib.sha256()
            with path.open('rb') as file:
                for chunk in iter(lambda: file.read(1024 * 1024), b''):
                    content.update(chunk)
            record(content.digest())
        elif stat.S_ISDIR(info.st_mode):
            for child in sorted(path.iterdir()):
                visit(child)
        else:
            raise ValueError(f'unsupported bundle entry: {path}')

    visit(root)
    return digest.hexdigest()


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'upgrade':
            validate_upgrade(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
        elif sys.argv[1] == 'hash':
            print(tree_hash(pathlib.Path(sys.argv[2])))
        else:
            raise ValueError('expected upgrade or hash')
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        sys.exit(f'Error: {error}')
