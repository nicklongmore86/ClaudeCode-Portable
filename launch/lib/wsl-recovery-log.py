#!/usr/bin/env python3
"""Executed only after dropping to the invoking UID/GID, under timeout."""
import os
import stat
import sys

path, message = sys.argv[1:]
# Refuse all existing entries, including FIFOs, devices and symlinks. O_EXCL
# closes the lstat/open race; O_NOFOLLOW and O_NONBLOCK add defense in depth.
try:
    os.lstat(path)
except FileNotFoundError:
    pass
else:
    raise SystemExit("Recovery log already exists; refusing to overwrite it")
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
try:
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        raise SystemExit("Recovery log is not a regular file")
    with os.fdopen(fd, "w", closefd=False) as output:
        output.write(message + "\n")
finally:
    os.close(fd)
