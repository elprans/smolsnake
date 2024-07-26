# Copyright Contributors to the smolsnake project.
#
# SPDX-License-Identifier: 0BSD


from __future__ import annotations
from typing import (
    Optional,
    TYPE_CHECKING,
)

import pathlib
import sys
import tempfile

from poetry.packages import locker as poetry_locker

if TYPE_CHECKING:
    from smolsnake import VersionInfo


def injectsyspath(
    destpath: Optional[pathlib.Path],
    lockfile: Optional[pathlib.Path],
    python_version: VersionInfo,
) -> None:
    if lockfile is None:
        with tempfile.NamedTemporaryFile("w+t") as f:
            f.write(sys.stdin.read())
            locker = poetry_locker.Locker(pathlib.Path(f.name), {})
            lockfile_repo = locker.locked_repository()
    else:
        locker = poetry_locker.Locker(lockfile, {})
        lockfile_repo = locker.locked_repository()

    interp = "cp" + "".join(str(p) for p in python_version[:2])
    paths = [
        str(
            pathlib.Path("/mnt/efs")
            / interp
            / pkg.name
            / str(pkg.version)
            / "lib"
        )
        for pkg in lockfile_repo.packages
    ]

    code = f"import sys\nsys.path = {paths!r} + sys.path\n"

    if destpath is None:
        print(code)
    else:
        destpath.write_text(code)
