#!/usr/bin/env python3
"""Build deterministic package.el archives and verify clean-room installation.

Use `make release-check RELEASE_DIR=/tmp/ebox-release EMACS=/path/to/emacs`.
Only the explicit output directory is retained; subprocesses have timeouts and
temporary checkouts/installations are removed on success, error, or interruption.
No command publishes, changes a source checkout, or installs into the user profile.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(args, cwd=None, env=None, timeout=180):
    """Run a bounded subprocess; include its output on failure."""
    process = subprocess.Popen(args, cwd=cwd, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True,
                               start_new_session=(os.name != "nt"))
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           capture_output=True, timeout=20, check=False)
        else:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.communicate()
        raise
    if process.returncode:
        raise RuntimeError(f"Command failed: {args[0]}\n{stdout}{stderr}")
    return stdout


def lock_entries(lock, with_ekp=False):
    """Validate and select required dependencies and the optional KP provider."""
    if lock.get("schema") != 1 or set(lock.get("dependencies", {})) != {"tp", "ecss"}:
        raise ValueError("Expected schema 1 with pinned tp and ecss dependencies")
    entries = dict(lock["dependencies"])
    if with_ekp:
        entries["ekp"] = lock["optional"]["ekp"]
    for name, entry in entries.items():
        if not re.fullmatch(r"[0-9a-f]{40}", entry["revision"]):
            raise ValueError(f"{name}: revision must be a full commit hash")
        if not entry["url"].startswith("https://"):
            raise ValueError(f"{name}: public dependency URL must use HTTPS")
    return entries


def checkout_dependencies(directory, entries):
    """Fetch exact commits into a new directory; never replace a checkout."""
    if directory.exists():
        raise ValueError(f"Refusing to replace existing dependency directory: {directory}")
    directory.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".ebox-deps-", dir=directory.parent) as work:
        stage = Path(work) / "deps"
        stage.mkdir()
        env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
        for name, entry in entries.items():
            target = stage / name
            run(["git", "init", "-q", str(target)])
            run(["git", "fetch", "--quiet", "--depth", "1", entry["url"],
                 entry["revision"]], cwd=target, env=env)
            run(["git", "checkout", "--quiet", "--detach", "FETCH_HEAD"], cwd=target)
            if run(["git", "rev-parse", "HEAD"], cwd=target).strip() != entry["revision"]:
                raise ValueError(f"{name}: fetched revision mismatch")
        stage.rename(directory)


def validate_dependencies(directory, entries):
    """Reject stale or modified explicit dependency checkouts."""
    for name, entry in entries.items():
        target = directory / name
        revision = run(["git", "rev-parse", "HEAD"], cwd=target).strip()
        dirty = run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=target)
        if revision != entry["revision"] or dirty:
            raise ValueError(f"{name}: dependency must be clean at {entry['revision']}")


def package_metadata(root, name):
    """Read package.el metadata from the package's main Lisp header."""
    source = (root / f"{name}.el").read_text()
    version = re.search(r"^;; Version: ([0-9]+(?:\.[0-9]+)*)$", source, re.M)
    requirements = re.search(r"^;; Package-Requires: (.+)$", source, re.M)
    if not version or not requirements:
        raise ValueError(f"{name}: missing supported version or requirements header")
    return version[1], requirements[1]


def package_files(root, name):
    """Select source inputs, documentation and licenses, excluding build output."""
    result = {}
    candidates = run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root)
    for filename in sorted(set(candidates.split("\0")) - {""}):
        path = root / filename
        relative = path.relative_to(root)
        parts = relative.parts
        if (not path.is_file() or path.is_symlink()
                or any(part.startswith(".") or part in ("target", "__pycache__")
                       for part in parts)
                or path.suffix in (".elc", ".eln", ".so", ".dylib", ".dll", ".o", ".a")):
            continue
        top_file = len(parts) == 1
        include = (top_file and (path.name == f"{name}.el" or path.name.startswith(("README", "LICENSE", "COPYING", "NOTICE", "CHANGELOG"))))
        include = include or (len(parts) == 2 and parts[0] == "lisp" and path.suffix == ".el")
        include = include or (name == "ebox" and parts[0] in ("native", "docs"))
        include = include or (name == "ekp" and parts[0] in ("dictionaries", "native"))
        if include and not path.name.endswith("-pkg.el"):
            archive_path = relative.as_posix()
            result[archive_path] = path.read_bytes()
    if f"{name}.el" not in result:
        raise ValueError(f"{name}: package entry missing")
    return result


def write_package(output, root, name):
    """Write a deterministic uncompressed package.el tar archive."""
    version, requirements = package_metadata(root, name)
    files = package_files(root, name)
    files[f"{name}-pkg.el"] = (
        f';;; {name}-pkg.el --- Package metadata -*- lexical-binding: t; -*-\n'
        f'(define-package "{name}" "{version}" "{name} source package" '
        f"'{requirements})\n").encode()
    archive = output / f"{name}-{version}.tar"
    with tarfile.open(archive, "w", format=tarfile.USTAR_FORMAT) as stream:
        for relative, content in sorted(files.items()):
            info = tarfile.TarInfo(f"{name}-{version}/{relative}")
            info.size, info.mode, info.mtime = len(content), 0o644, 0
            info.uid = info.gid = 0
            stream.addfile(info, io.BytesIO(content))
    return {"name": name, "version": version, "requirements": requirements,
            "file": archive.name, "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}


def build(output, root, dependencies, entries):
    """Atomically publish a local archive directory after all packages build."""
    if output.exists():
        raise ValueError(f"Refusing to replace existing release directory: {output}")
    validate_dependencies(dependencies, entries)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".ebox-release-", dir=output.parent) as work:
        stage = Path(work) / "archive"
        stage.mkdir()
        packages = [write_package(stage, dependencies / name, name) for name in entries]
        packages.append(write_package(stage, root, "ebox"))
        manifest = {"schema": 1, "dependencies": entries, "packages": packages,
                    "source_revision": run(["git", "rev-parse", "HEAD"], cwd=root).strip(),
                    "source_dirty": bool(run(["git", "status", "--porcelain"], cwd=root))}
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        records = []
        for package in packages:
            version_list = "(" + package["version"].replace(".", " ") + ")"
            requirements = re.sub(r'"([0-9]+(?:\.[0-9]+)*)"',
                                  lambda match: "(" + match[1].replace(".", " ") + ")",
                                  package["requirements"])
            records.append(f' ({package["name"]} . [{version_list} '
                           f'{requirements} "{package["name"]} source package" tar])')
        (stage / "archive-contents").write_text("(1\n" + "\n".join(records) + "\n)\n")
        stage.rename(output)
    return manifest


def verify(directory, emacs, native_module=None, build_native=False):
    """Install source archives in a disposable package-user-dir and exercise Ebox."""
    manifest = json.loads((directory / "manifest.json").read_text())
    if native_module and not native_module.is_file():
        raise ValueError(f"Native module does not exist: {native_module}")
    for package in manifest["packages"]:
        file = directory / package["file"]
        if file.parent != directory or not file.is_file():
            raise ValueError("Invalid archive filename")
        if hashlib.sha256(file.read_bytes()).hexdigest() != package["sha256"]:
            raise ValueError(f"Archive checksum mismatch: {file.name}")
    with tempfile.TemporaryDirectory(prefix="ebox-install-") as work:
        env = dict(os.environ, EBOX_RELEASE_ARCHIVE=str(directory),
                   EBOX_RELEASE_PROFILE=work, EBOX_RELEASE_NATIVE=str(native_module or ""),
                   EBOX_RELEASE_BUILD_NATIVE="1" if build_native else "")
        # No repository or sibling load paths, HOME changes, network archive refresh,
        # or user package installation.  package.el compiles only this temp profile.
        result = run([emacs, "-Q", "--batch", "-l", str(ROOT / "scripts/ebox-release-smoke.el")],
                     cwd=work, env=env, timeout=600)
        print(result.strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("deps", "build", "verify"))
    parser.add_argument("--directory", type=Path, required=True,
                        help="New deps/build output directory, or archive to verify")
    parser.add_argument("--dependencies", type=Path, help="Explicit pinned dependency checkout directory")
    parser.add_argument("--with-ekp", action="store_true", help="Include optional Knuth-Plass provider")
    parser.add_argument("--emacs", default="emacs", help="Emacs executable for verify")
    parser.add_argument("--native-module", type=Path, help="Require loading and executing this native module")
    parser.add_argument("--build-native", action="store_true",
                        help="Build, install and execute bundled native source in the temporary profile")
    args = parser.parse_args()
    directory = args.directory.resolve()
    entries = lock_entries(json.loads((ROOT / "release-dependencies.json").read_text()), args.with_ekp)
    if args.command == "deps":
        checkout_dependencies(directory, entries)
        print(f"Pinned dependencies ready: {directory}")
    elif args.command == "build":
        if args.dependencies:
            manifest = build(directory, ROOT, args.dependencies.resolve(), entries)
        else:
            with tempfile.TemporaryDirectory(prefix="ebox-release-deps-") as work:
                dependencies = Path(work) / "deps"
                checkout_dependencies(dependencies, entries)
                manifest = build(directory, ROOT, dependencies, entries)
        print(json.dumps({"archive": str(directory), "packages": manifest["packages"]}, indent=2))
    else:
        if args.native_module and args.build_native:
            parser.error("Choose --native-module or --build-native, not both")
        verify(directory, args.emacs, args.native_module.resolve() if args.native_module else None,
               args.build_native)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(f"release verification failed: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("release operation interrupted; temporary resources removed", file=sys.stderr)
        sys.exit(130)
