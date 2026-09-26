#!/usr/bin/env python3
"""Hold packaging locks across exec; the kernel releases them even after SIGKILL."""
import fcntl
import os
import pathlib
import stat
import sys


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError(f'unsafe packaging lock directory: {path}')
    path.chmod(0o700)


def lock_paths(cache, distribution, create):
    # All checkouts share destination locks. Tests can isolate this root too;
    # no coordination files are written into a user-selected output folder.
    user_cache = pathlib.Path(f'/private/tmp/com.parallax.Parallax-SwiftPM-{os.getuid()}')
    override = os.environ.get('PARALLAX_PACKAGING_LOCK_ROOT')
    if override:
        lock_root = pathlib.Path(override)
    else:
        if create:
            private_directory(user_cache)
        lock_root = user_cache / 'locks'
    if create:
        private_directory(lock_root)
    paths = [pathlib.Path(cache) / '.packaging.flock']
    destinations = [distribution]
    legacy = os.environ.get('PARALLAX_PACKAGING_DEFAULT_DIST')
    if legacy and pathlib.Path(legacy).is_dir():
        destinations.append(legacy)
    for destination in destinations:
        info = os.stat(destination)
        path = lock_root / f'distribution-{info.st_dev}-{info.st_ino}.flock'
        if path not in paths:
            paths.append(path)
    return paths


def owns_inherited_locks(cache, distribution):
    if os.environ.get('PARALLAX_PACKAGING_LOCK_PID') != str(os.getppid()):
        return False
    descriptors = os.environ.get('PARALLAX_PACKAGING_LOCK_FDS', '').split(',')
    paths = lock_paths(cache, distribution, create=False)
    if len(descriptors) != len(paths):
        return False
    for value, path in zip(descriptors, paths):
        if not value.isdecimal() or int(value) < 3:
            return False
        descriptor = int(value)
        info, expected = os.fstat(descriptor), path.lstat()
        if ((info.st_dev, info.st_ino) != (expected.st_dev, expected.st_ino)
                or not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1):
            return False
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    return True


def main():
    cache, distribution, command, *arguments = sys.argv[1:]
    descriptors = []
    for path in lock_paths(cache, distribution, create=True):
        descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise ValueError(f'unsafe packaging lock: {path}')
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError(f'another packaging invocation is active: {path}') from None
        os.set_inheritable(descriptor, True)
        descriptors.append(descriptor)
    environment = dict(os.environ, PARALLAX_PACKAGING_LOCK_PID=str(os.getpid()),
                       PARALLAX_PACKAGING_LOCK_FDS=','.join(map(str, descriptors)))
    os.execvpe(command, [command, *arguments], environment)


if __name__ == '__main__':
    if sys.argv[1:2] == ['--check-owner']:
        try:
            accepted = owns_inherited_locks(*sys.argv[2:])
        except (OSError, ValueError):
            accepted = False
        sys.exit(0 if accepted else 1)
    try:
        main()
    except (OSError, ValueError) as error:
        sys.exit(f'Error: {error}')
