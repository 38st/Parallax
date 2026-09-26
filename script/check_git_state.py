#!/usr/bin/env python3
"""Fail closed on hidden build inputs and check every unpublished diff layer."""
import argparse
import pathlib
import subprocess
import sys


def git(root, *arguments):
    return subprocess.check_output(['git', '-C', str(root), *arguments])


def require_clean(root):
    git(root, 'rev-parse', '--verify', 'HEAD')
    if git(root, 'status', '--porcelain', '--untracked-files=normal'):
        raise ValueError('tracked or untracked changes')
    for entry in git(root, 'ls-files', '-v', '-z').split(b'\0'):
        if entry and (entry[:1].islower() or entry[:1] == b'S'):
            raise ValueError('skip-worktree or assume-unchanged index entries')


def check_diff(root):
    upstream = git(root, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}').strip()
    base = git(root, 'merge-base', 'HEAD', upstream.decode()).strip().decode()
    if not base:
        raise ValueError('no upstream merge base resolves')
    for arguments in ((base, 'HEAD'), ('--cached',), ()):
        if subprocess.run(['git', '-C', str(root), 'diff', '--check', *arguments]).returncode:
            raise ValueError('whitespace errors in committed, staged, or unstaged changes')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--diff-check', action='store_true')
    parser.add_argument('root', type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.diff_check:
            check_diff(args.root)
        else:
            require_clean(args.root)
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'Error: cannot verify Git state: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
