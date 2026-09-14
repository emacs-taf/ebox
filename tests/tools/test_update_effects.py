"""Exercise the update-effect evaluator's command and report contract."""

import hashlib
import itertools
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
EVALUATOR = ROOT / "benchmarks/benchmark-update-effects.el"


class UpdateEffectsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)
        self.output = self.work / "report.json"
        self.lock = self.work / "host.lock"

    def run_evaluator(self, **options):
        environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith("EBOX_UPDATE_EFFECTS_")
        }
        environment.update({
            "EBOX_UPDATE_EFFECTS_OUTPUT": str(self.output),
            "EBOX_UPDATE_EFFECTS_SIZES": "2",
            "EBOX_UPDATE_EFFECTS_SAMPLES": "2",
            "EBOX_UPDATE_EFFECTS_WARMUPS": "0",
            "ETAF_PERF_LOCK_DIR": str(self.lock),
        })
        environment.update(options)
        return subprocess.run(
            [os.environ.get("EBOX_TOOL_TEST_EMACS", "emacs"), "-Q", "--batch",
             "-L", str(ROOT), "-L", str(ROOT.parent / "ecss"),
             "-L", str(ROOT.parent / "tp"),
             "--eval", "(setq load-prefer-newer t)",
             "-l", str(EVALUATOR), "-f", "ebox-update-effects-batch"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=60,
        )

    def test_invalid_options_fail_before_creating_output_or_lock(self):
        for name, value in (
            ("SIZES", ""), ("SIZES", "2,no"), ("SIZES", "1001"),
            ("SIZES", "1,2,3,4,5,6"), ("SAMPLES", "0"),
            ("SAMPLES", "101"), ("WARMUPS", "-1"),
        ):
            with self.subTest(name=name, value=value):
                result = self.run_evaluator(**{f"EBOX_UPDATE_EFFECTS_{name}": value})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ERROR", result.stdout)
                self.assertFalse(self.output.exists())
                self.assertFalse(self.lock.exists())

    def test_existing_output_is_preserved(self):
        self.output.write_text("keep")
        result = self.run_evaluator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Output already exists", result.stdout)
        self.assertEqual(self.output.read_text(), "keep")
        self.assertFalse(self.lock.exists())

    def test_occupied_host_slot_is_preserved(self):
        self.lock.mkdir()
        owner = self.lock / "pid"
        owner.write_text("existing-owner")
        result = self.run_evaluator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("host slot is occupied", result.stdout)
        self.assertEqual(owner.read_text(), "existing-owner")
        self.assertFalse(self.output.exists())

    def test_complete_matrix_checks_both_directions_and_records_provenance(self):
        result = self.run_evaluator()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.lock.exists())
        report = json.loads(self.output.read_text())
        self.assertEqual(report["status"], "completed")
        self.assertIsNone(report["error"])
        self.assertEqual(report["evaluator_sha256"], hashlib.sha256(EVALUATOR.read_bytes()).hexdigest())
        self.assertEqual({source["package"] for source in report["sources"]}, {"ebox", "ecss", "tp"})
        expected = {
            (style, subset)
            for style in ("inline", "scoped")
            for count in range(1, 5)
            for subset in itertools.combinations(("content", "paint", "interaction", "geometry"), count)
        }
        self.assertEqual(len(report["cases"]), 30)
        self.assertEqual({(case["styles"], tuple(case["effects"])) for case in report["cases"]}, expected)
        for case in report["cases"]:
            self.assertEqual(case["correctness"], "passed")
            self.assertEqual(len(case["samples_ms"]), 2)
            self.assertEqual(sum(case["projection_counts"].values()), 2)
            self.assertIsInstance(case["rejection_counts"], dict)
            self.assertEqual(case["diagnostic_updates"], 2)
            for boundary, count in case["rejection_counts"].items():
                self.assertEqual(len(boundary.split("/")), 2)
                self.assertIsInstance(count, int)
                self.assertGreater(count, 0)
                self.assertLessEqual(count, 2)
            self.assertGreaterEqual(case["p50_ms"], 0)
            self.assertGreaterEqual(case["p95_ms"], case["p50_ms"])
            self.assertEqual(case["max_ms"], max(case["samples_ms"]))
        native_rejections = [
            case for case in report["cases"]
            if "mixed-owner-reflow/native-property-composition" in case["rejection_counts"]
        ]
        self.assertTrue(native_rejections)
        for case in native_rejections:
            self.assertIn("interaction", case["effects"])


if __name__ == "__main__":
    unittest.main()
