#!/usr/bin/env python3
"""Unit tests for compare_baseline.py (no network / no Swift)."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
COMPARE = HERE / "compare_baseline.py"


def run_compare(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(COMPARE), *args],
        capture_output=True,
        text=True,
    )


class CompareBaselineTests(unittest.TestCase):
    def _write(self, path: Path, obj) -> None:
        path.write_text(json.dumps(obj), encoding="utf-8")

    def test_strict_pass(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            results = td_path / "r.json"
            self._write(results, [
                {"task": "000-harness-alive", "status": "pass"},
            ])
            cp = run_compare(str(results), "--strict")
            self.assertEqual(cp.returncode, 0, cp.stderr)

    def test_strict_fail(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            results = td_path / "r.json"
            self._write(results, [
                {"task": "000-harness-alive", "status": "fail"},
            ])
            cp = run_compare(str(results), "--strict")
            self.assertEqual(cp.returncode, 1, cp.stdout + cp.stderr)

    def test_baseline_pass_to_fail(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            results = td_path / "r.json"
            baseline = td_path / "b.json"
            self._write(results, [
                {"task": "000-harness-alive", "status": "fail"},
            ])
            self._write(baseline, {
                "schema": 1,
                "tasks": {"000-harness-alive": "pass"},
                "pass_rate": 1.0,
                "max_drop_pp": 5,
                "require_all_pass": False,
            })
            cp = run_compare(str(results), "--baseline", str(baseline))
            self.assertEqual(cp.returncode, 1)
            self.assertIn("pass → fail", cp.stderr)

    def test_baseline_ok(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            results = td_path / "r.json"
            baseline = td_path / "b.json"
            self._write(results, [
                {"task": "000-harness-alive", "status": "pass"},
            ])
            self._write(baseline, {
                "schema": 1,
                "tasks": {"000-harness-alive": "pass"},
                "pass_rate": 1.0,
                "max_drop_pp": 5,
                "require_all_pass": True,
            })
            cp = run_compare(str(results), "--baseline", str(baseline), "--strict")
            self.assertEqual(cp.returncode, 0, cp.stderr)

    def test_write_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            results = td_path / "r.json"
            out = td_path / "new-baseline.json"
            self._write(results, [
                {"task": "000-harness-alive", "status": "pass"},
            ])
            cp = run_compare(
                str(results),
                "--write-baseline", str(out),
                "--backend", "mock",
                "--model", "mock-worker",
            )
            self.assertEqual(cp.returncode, 0, cp.stderr)
            data = json.loads(out.read_text())
            self.assertEqual(data["tasks"]["000-harness-alive"], "pass")
            self.assertEqual(data["pass_rate"], 1.0)

    def test_empty_results_vs_baseline_is_fail(self) -> None:
        """Wave C: empty suite must not false-green against a non-empty baseline."""
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            results = td_path / "r.json"
            baseline = td_path / "b.json"
            self._write(results, [])
            self._write(baseline, {
                "schema": 1,
                "tasks": {"000-harness-alive": "pass"},
                "pass_rate": 1.0,
                "max_drop_pp": 5,
                "require_all_pass": True,
            })
            cp = run_compare(str(results), "--baseline", str(baseline))
            self.assertEqual(cp.returncode, 1, cp.stdout + cp.stderr)
            self.assertIn("no tasks ran", cp.stderr)

    def test_write_baseline_no_require_all_pass(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            results = td_path / "r.json"
            out = td_path / "b.json"
            self._write(results, [
                {"task": "000-harness-alive", "status": "pass"},
            ])
            cp = run_compare(
                str(results),
                "--write-baseline", str(out),
                "--no-require-all-pass",
            )
            self.assertEqual(cp.returncode, 0, cp.stderr)
            data = json.loads(out.read_text())
            self.assertFalse(data["require_all_pass"])

    def test_write_baseline_refuses_empty(self) -> None:
        """Wave C2: empty results must not wipe baseline.json."""
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            results = td_path / "r.json"
            out = td_path / "b.json"
            self._write(results, [])
            out.write_text('{"tasks":{"000-harness-alive":"pass"}}\n')
            cp = run_compare(str(results), "--write-baseline", str(out))
            self.assertEqual(cp.returncode, 2, cp.stdout + cp.stderr)
            self.assertIn("refusing", cp.stderr)
            # File must not be overwritten with empty tasks
            data = json.loads(out.read_text())
            self.assertIn("000-harness-alive", data.get("tasks", {}))


if __name__ == "__main__":
    unittest.main()