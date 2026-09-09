"""Regression tests for deterministic packaging and dependency boundaries."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("ebox_release", Path(__file__).with_name("ebox-release.py"))
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)


class ReleaseTests(unittest.TestCase):
    def test_lock_requires_exact_revisions_and_optional_provider_is_explicit(self):
        lock = json.loads((RELEASE.ROOT / "release-dependencies.json").read_text())
        self.assertEqual(set(RELEASE.lock_entries(lock)), {"tp", "ecss"})
        self.assertEqual(set(RELEASE.lock_entries(lock, True)), {"tp", "ecss", "ekp"})
        lock["dependencies"]["tp"]["revision"] = "main"
        with self.assertRaises(ValueError):
            RELEASE.lock_entries(lock)

    def test_archives_are_reproducible_source_complete_and_exclude_local_outputs(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "source"
            root.mkdir()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "ebox.el").write_text(';;; ebox.el --- Test -*- lexical-binding: t -*-\n;; Version: 3.0.0\n;; Package-Requires: ((emacs "29.1"))\n')
            (root / "LICENSE").write_text("license")
            (root / "native/src").mkdir(parents=True)
            (root / "native/src/lib.rs").write_text("native source")
            (root / "native/target/release").mkdir(parents=True)
            (root / "native/target/release/private.log").write_text("exclude")
            (root / "ebox.elc").write_text("stale bytecode")
            first, second = Path(work) / "first", Path(work) / "second"
            first.mkdir()
            second.mkdir()
            one = RELEASE.write_package(first, root, "ebox")
            (root / "ebox.el").touch()
            two = RELEASE.write_package(second, root, "ebox")
            self.assertEqual(one["sha256"], two["sha256"])
            with tarfile.open(first / one["file"]) as archive:
                names = archive.getnames()
                self.assertIn("ebox-3.0.0/LICENSE", names)
                self.assertIn("ebox-3.0.0/native/src/lib.rs", names)
                self.assertIn("ebox-3.0.0/ebox-pkg.el", names)
                self.assertFalse(any("target/" in name or name.endswith(".elc") for name in names))
                self.assertTrue(all(member.mtime == 0 for member in archive.getmembers()))

    def test_existing_output_is_preserved(self):
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            sentinel = directory / "keep"
            sentinel.write_text("owned")
            with self.assertRaises(ValueError):
                RELEASE.checkout_dependencies(directory, {})
            with self.assertRaises(ValueError):
                RELEASE.build(directory, directory, directory, {})
            self.assertEqual(sentinel.read_text(), "owned")

    def test_modified_archive_fails_before_emacs_runs(self):
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            (directory / "bad.tar").write_bytes(b"changed")
            (directory / "manifest.json").write_text(json.dumps({"packages": [{"file": "bad.tar", "sha256": "wrong"}]}))
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                RELEASE.verify(directory, "must-not-run")

    def test_failed_fetch_removes_temporary_checkout_and_never_creates_output(self):
        with tempfile.TemporaryDirectory() as work:
            parent = Path(work)
            output = parent / "deps"
            with mock.patch.object(RELEASE, "run", side_effect=RuntimeError("fetch failed")):
                with self.assertRaisesRegex(RuntimeError, "fetch failed"):
                    RELEASE.checkout_dependencies(output, {"tp": {"url": "https://invalid", "revision": "0" * 40}})
            self.assertEqual(list(parent.iterdir()), [])

    def test_dependency_validation_rejects_modified_checkout(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            dependency = root / "tp"
            dependency.mkdir()
            subprocess.run(["git", "init", "-q", str(dependency)], check=True)
            (dependency / "tp.el").write_text("original")
            subprocess.run(["git", "add", "tp.el"], cwd=dependency, check=True)
            subprocess.run(["git", "-c", "user.name=Release Test", "-c", "user.email=release@example.invalid",
                            "commit", "-qm", "fixture"], cwd=dependency, check=True)
            revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=dependency).decode().strip()
            entries = {"tp": {"revision": revision}}
            RELEASE.validate_dependencies(root, entries)
            (dependency / "tp.el").write_text("modified")
            with self.assertRaisesRegex(ValueError, "dependency must be clean"):
                RELEASE.validate_dependencies(root, entries)


if __name__ == "__main__":
    unittest.main()
