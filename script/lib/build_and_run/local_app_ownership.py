#!/usr/bin/env python3
"""Recognize local packager output using the existing provenance format."""
import pathlib
import plistlib
import re
import subprocess
import sys


def is_packaged_app(app, name, identifier, root):
    contents = app / 'Contents'
    resources = contents / 'Resources'
    info_path = contents / 'Info.plist'
    provenance_path = resources / 'PackagingProvenance.plist'
    if any(path.is_symlink() for path in (app, contents, resources, info_path, provenance_path)):
        return False
    with info_path.open('rb') as stream:
        info = plistlib.load(stream)
    with provenance_path.open('rb') as stream:
        provenance = plistlib.load(stream)
    if not isinstance(info, dict) or not isinstance(provenance, dict):
        return False
    if (info.get('CFBundleExecutable') != name or provenance.get('Application') != name
            or info.get('CFBundleIdentifier') != identifier
            or provenance.get('SigningIdentity') != 'adhoc'):
        return False
    for key, field in (('BundleIdentifier', 'CFBundleIdentifier'),
                       ('Version', 'CFBundleShortVersionString'),
                       ('BuildNumber', 'CFBundleVersion'),
                       ('MinimumSystemVersion', 'LSMinimumSystemVersion')):
        if not isinstance(provenance.get(key), str) or provenance[key] != info.get(field):
            return False
    revision = provenance.get('GitRevision')
    if not isinstance(revision, str) or not re.fullmatch(r'[0-9a-f]{40,64}', revision):
        return False
    return subprocess.run(['git', '-C', str(root), 'cat-file', '-e', revision + '^{commit}'],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


if __name__ == '__main__':
    try:
        app, name, identifier, root = sys.argv[1:]
        accepted = is_packaged_app(pathlib.Path(app), name, identifier, pathlib.Path(root))
    except (OSError, ValueError, plistlib.InvalidFileException):
        accepted = False
    raise SystemExit(0 if accepted else 1)
