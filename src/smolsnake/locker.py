# Copyright Contributors to the smolsnake project.
#
# SPDX-License-Identifier: 0BSD


from __future__ import annotations
from typing import (
    List,
    Optional,
    Tuple,
    TYPE_CHECKING,
)

import os
import pathlib
import sys
import tempfile

from cleo.io import io as cleo_io
from cleo.io.inputs import argv_input as cleo_input
from cleo.io.outputs import stream_output as cleo_output

from poetry.core.constraints import version as poetry_ver
from poetry.core.packages import dependency as poetry_dep
from poetry.core.packages import package as poetry_pkg
from poetry.core.packages import project_package as poetry_proj
from poetry.installation.operations import operation as poetry_op
from poetry.installation.operations import install as poetry_install_op
from poetry.packages import locker as poetry_locker
from poetry import puzzle as poetry_puzzle
from poetry import repositories as poetry_repo
from poetry.repositories import lockfile_repository as poetry_lockrepo
from poetry.repositories import pypi_repository as poetry_pypi

import requirements

if TYPE_CHECKING:
    from smolsnake import VersionInfo


def lock_deps(
    project_path: pathlib.Path,
    lockfile: Optional[pathlib.Path],
    python_version: VersionInfo,
) -> None:
    deps = _load_deps(project_path)
    root, ops = _resolve_deps(project_path, deps, python_version)
    lockfile_repo = poetry_lockrepo.LockfileRepository()
    for op in ops:
        if not isinstance(op, poetry_install_op.Install):
            raise RuntimeError(f"unexpected op: {op}")

        if not lockfile_repo.has_package(op.package):
            lockfile_repo.add_package(op.package)

    if lockfile is None:
        try:
            fd, tmpf = tempfile.mkstemp()
            os.close(fd)

            lockfile = pathlib.Path(tmpf)

            locker = poetry_locker.Locker(lockfile, {})
            locker.set_lock_data(root, lockfile_repo.packages)

            print(lockfile.read_text())
        finally:
            os.unlink(tmpf)
    else:
        locker = poetry_locker.Locker(lockfile, {})
        locker.set_lock_data(root, lockfile_repo.packages)


def _load_deps(
    project_path: pathlib.Path,
) -> List[poetry_dep.Dependency]:
    frozen_reqs_txt = project_path / "requirements.frozen.txt"
    if frozen_reqs_txt.exists():
        return _load_requirements_txt(frozen_reqs_txt)

    reqs_txt = project_path / "requirements.txt"
    if reqs_txt.exists():
        return _load_requirements_txt(reqs_txt)

    return []


def _load_requirements_txt(path: pathlib.Path) -> List[poetry_dep.Dependency]:
    with path.open() as rf:
        parsed_reqs = list(requirements.parse(rf))
    reqs: List[poetry_dep.Dependency] = []
    for parsed_req in parsed_reqs:
        assert parsed_req.name is not None
        req = poetry_dep.Dependency(
            name=parsed_req.name,
            constraint=poetry_ver.parse_constraint(
                ",".join(f"{op}{v}" for op, v in parsed_req.specs),
            ),
            extras=parsed_req.extras,
        )
        reqs.append(req)

    return reqs


def _resolve_deps(
    source_root: pathlib.Path,
    deps: List[poetry_dep.Dependency],
    python_version: VersionInfo,
) -> Tuple[poetry_pkg.Package, List[poetry_op.Operation]]:
    inp = cleo_input.ArgvInput()
    inp.set_stream(sys.stdin)
    io = cleo_io.IO(
        inp,
        cleo_output.StreamOutput(sys.stderr),
        cleo_output.StreamOutput(sys.stderr),
    )
    pool = poetry_repo.RepositoryPool()
    pool.add_repository(poetry_pypi.PyPiRepository())
    root = poetry_proj.ProjectPackage("__lambda__", "1")
    root.python_versions = ".".join(str(p) for p in python_version)
    for dep in deps:
        root.add_dependency(dep)

    solver = poetry_puzzle.Solver(
        package=root,
        pool=pool,
        io=io,
        installed=[],
        locked=[],
    )

    with solver.provider.use_source_root(source_root=source_root):
        ops = solver.solve().calculate_operations()

    return root, ops
