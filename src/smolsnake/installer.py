# Copyright Contributors to the smolsnake project.
#
# SPDX-License-Identifier: 0BSD


from __future__ import annotations
from typing import (
    BinaryIO,
    Optional,
    TYPE_CHECKING,
)

import os.path
import pathlib
import platform
import sys
import tempfile


from cleo.io import io as cleo_io
from cleo.io.inputs import argv_input as cleo_input
from cleo.io.outputs import stream_output as cleo_output

import installer
from installer import destinations as installer_destinations
from installer import scripts as installer_scripts
from installer import sources as installer_sources
from installer import records as installer_records
from installer import utils as installer_utils

from packaging import tags

from poetry.config import config as poetry_config
from poetry.core.packages import package as poetry_pkg
from poetry.core.packages import project_package as poetry_proj
from poetry.core.packages.utils import link as poetry_link
from poetry.installation import executor as poetry_exec
from poetry.installation.operations import install as poetry_install_op
from poetry.packages import locker as poetry_locker
from poetry import repositories as poetry_repo
from poetry.repositories import installed_repository as poetry_installed
from poetry.repositories import pypi_repository as poetry_pypi
from poetry.utils import env as poetry_env

if TYPE_CHECKING:
    from smolsnake import VersionInfo


class WheelDestination(installer_destinations.SchemeDictionaryDestination):
    def write_to_fs(
        self,
        scheme: installer.Scheme,
        path: str,
        stream: BinaryIO,
        is_executable: bool,
    ) -> installer_records.RecordEntry:
        target_path = self._path_with_destdir(scheme, path)
        parent_folder = os.path.dirname(target_path)
        if not os.path.exists(parent_folder):
            os.makedirs(parent_folder)

        with open(target_path, "wb") as f:
            hash_, size = installer_utils.copyfileobj_with_hashing(
                stream, f, self.hash_algorithm
            )

        if is_executable:
            installer_utils.make_file_executable(target_path)

        return installer_records.RecordEntry(
            path,
            installer_records.Hash(self.hash_algorithm, hash_),
            size,
        )


def install(
    destdir: pathlib.Path,
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

    executor = _make_executor(python_version)
    cleanup_archive = False

    interp = _get_interpreter_version(python_version)
    destdir /= interp

    installed = _load_installed(destdir, python_version)

    for package in lockfile_repo.packages:
        if installed.has_package(package):
            print(f"{package.unique_name} already in cache")
            continue

        operation = poetry_install_op.Install(package)

        if package.source_type == "git":
            archive = executor._prepare_git_archive(operation)
            cleanup_archive = operation.package.develop
        elif package.source_type == "file":
            archive = executor._prepare_archive(operation)
        elif package.source_type == "directory":
            archive = executor._prepare_archive(operation)
            cleanup_archive = True
        elif package.source_type == "url":
            assert package.source_url is not None
            archive = executor._download_link(
                operation, poetry_link.Link(package.source_url)
            )
        else:
            archive = executor._download(operation)

        try:
            print(f"installing {package.unique_name}")
            _install_package(package, archive, destdir)
        finally:
            if cleanup_archive:
                archive.unlink()


def _load_installed(
    destdir: pathlib.Path,
    python_version: VersionInfo,
) -> poetry_installed.InstalledRepository:
    paths = []
    for pkg in destdir.iterdir():
        if pkg.is_dir():
            for ver in pkg.iterdir():
                if ver.is_dir():
                    paths.append(str(ver / "lib"))

    env = MockEnv(
        version_info=python_version,
        sys_path=paths,
    )
    return poetry_installed.InstalledRepository.load(env)


def _install_package(
    package: poetry_pkg.Package,
    wheel: pathlib.Path,
    destdir: pathlib.Path,
) -> None:
    prefix = pathlib.Path(package.name) / str(package.version)

    scheme_dict = {
        "purelib": str(prefix / "lib"),
        "platlib": str(prefix / "lib"),
        "include": str(prefix / "include"),
        "headers": str(prefix / "include"),
        "scripts": str(prefix / "bin"),
        "data": str(prefix / "data"),
    }

    script_kind: installer_scripts.LauncherKind
    if sys.platform != "win32":
        script_kind = "posix"
    else:
        if platform.uname()[4].startswith("arm"):
            script_kind = "win-arm64" if sys.maxsize > 2**32 else "win-arm"
        else:
            script_kind = "win-amd64" if sys.maxsize > 2**32 else "win-ia32"

    destination = WheelDestination(
        scheme_dict=scheme_dict,
        interpreter=sys.executable,
        script_kind=script_kind,
        destdir=str(destdir),
    )

    with installer_sources.WheelFile.open(wheel) as source:
        source.validate_record(validate_contents=False)
        installer.install(
            source=source,
            destination=destination,
            additional_metadata={
                "INSTALLER": "smolsnake".encode(),
            },
        )


class MockEnv(poetry_env.MockEnv):
    def get_supported_tags(self) -> list[tags.Tag]:
        interp = _get_interpreter_version(self._version_info)
        # Per https://docs.aws.amazon.com/lambda/latest/dg/python-package.html
        platforms = [
            "manylinux_2_17_x86_64",
            "manylinux2014_x86_64",
            "manylinux2010_x86_64",
            "manylinux1_x86_64",
        ]
        tt = list(
            tags.cpython_tags(
                self._version_info[:2],
                abis=[interp],
                platforms=platforms,
            )
        )
        tt.extend(tags.compatible_tags(interpreter=interp))
        return tt


def _make_executor(python_version: VersionInfo) -> poetry_exec.Executor:
    inp = cleo_input.ArgvInput()
    inp.set_stream(sys.stdin)
    exec_io = cleo_io.IO(
        inp,
        cleo_output.StreamOutput(sys.stdout),
        cleo_output.StreamOutput(sys.stderr),
    )
    pool = poetry_repo.RepositoryPool()
    pool.add_repository(poetry_pypi.PyPiRepository())
    root = poetry_proj.ProjectPackage("__lambda__", "1")
    root.python_versions = ".".join(str(p) for p in python_version)
    env = MockEnv(version_info=python_version)
    config = poetry_config.Config.create()
    executor = poetry_exec.Executor(
        env=env, pool=pool, config=config, io=exec_io
    )
    executor._decorated_output = False
    return executor


def _get_interpreter_version(python_version: VersionInfo) -> str:
    return "cp" + "".join(str(v) for v in python_version[:2])
