#!/usr/bin/env python3
"""Compare an eval results JSON array against a baseline.json ratchet file.

Exit codes:
  0 — suite meets baseline (or baseline empty / soft mode)
  1 — regression vs baseline or strict failure
  2 — usage / IO error

Baseline schema (schema: 1):
{
  "schema": 1,
  "backend": "mock",
  "model": "mock-worker",
  "tasks": { "000-harness-alive": "pass", ... },
  "pass_rate": 1.0,
  "max_drop_pp": 5,
  "require_all_pass": true
}

Results format: array of { "task", "status", "duration_s", ... }

Notes:
  - Filtered runs only enforce per-task baseline for tasks that appear in
    results. Missing baseline tasks do not soft-pass when *zero* tasks ran.
  - Pass-rate drop is computed on the intersection of baseline tasks that
    were actually run (avoids false-red when filtering a hard subset).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def load_json(path: Path):
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def results_map(results) -> dict[str, str]:
    out: dict[str, str] = {}
    if not isinstance(results, list):
        raise ValueError("results must be a JSON array")
    for row in results:
        if not isinstance(row, dict):
            continue
        task = row.get("task")
        status = row.get("status")
        if isinstance(task, str) and isinstance(status, str):
            out[task] = status
    return out


def pass_rate(status_by_task: dict[str, str]) -> float:
    if not status_by_task:
        return 0.0
    passes = sum(1 for s in status_by_task.values() if s == "pass")
    return passes / len(status_by_task)


def write_baseline(
    path: Path,
    status_by_task: dict[str, str],
    backend: str,
    model: str,
    max_drop_pp: float,
    require_all_pass: bool,
) -> None:
    rate = pass_rate(status_by_task)
    payload = {
        "schema": 1,
        "backend": backend,
        "model": model,
        "captured_at": __import__("datetime").date.today().isoformat(),
        "tasks": dict(sorted(status_by_task.items())),
        "pass_rate": round(rate, 6),
        "max_drop_pp": max_drop_pp,
        "require_all_pass": require_all_pass,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def compare(baseline: dict, status_by_task: dict[str, str]) -> list[str]:
    errors: list[str] = []
    base_tasks = baseline.get("tasks") or {}
    if not isinstance(base_tasks, dict):
        return ["baseline.tasks must be an object"]

    max_drop_pp = float(baseline.get("max_drop_pp", 5))
    require_all_pass = bool(baseline.get("require_all_pass", False))

    # Empty run against a non-empty baseline is always a ratchet failure
    # (prevents false green when no tasks matched the filter).
    if base_tasks and not status_by_task:
        errors.append(
            "no tasks ran but baseline lists "
            + ", ".join(sorted(str(k) for k in base_tasks.keys()))
        )
        return errors

    # Per-task: baseline "pass" must not become "fail" when task was run.
    # Track which baseline tasks were exercised for intersection pass-rate.
    exercised: dict[str, str] = {}
    for task, expected in base_tasks.items():
        expected_s = str(expected)
        actual = status_by_task.get(str(task))
        if actual is None:
            # Filtered out of this run — skip per-task (not a free pass overall
            # when zero tasks ran; handled above).
            continue
        exercised[str(task)] = actual
        if expected_s == "pass" and actual != "pass":
            errors.append(f"task {task}: baseline pass → {actual}")

    # Pass-rate drop on intersection of baseline tasks that ran.
    # "Expected" rate = fraction of exercised baseline entries that required pass.
    # "Current" rate = fraction of those same tasks that actually passed.
    if exercised:
        expected_pass_count = 0
        for t in exercised:
            exp_val = None
            for k, v in base_tasks.items():
                if str(k) == t:
                    exp_val = v
                    break
            if str(exp_val) == "pass":
                expected_pass_count += 1
        base_rate_on_run = expected_pass_count / len(exercised)
        cur_rate = pass_rate(exercised)
        drop_pp = (base_rate_on_run - cur_rate) * 100.0
        if drop_pp > max_drop_pp + 1e-9:
            errors.append(
                f"pass_rate drop {drop_pp:.2f}pp on run intersection "
                f"(expected {base_rate_on_run:.4f} → current {cur_rate:.4f}, "
                f"max_drop_pp={max_drop_pp})"
            )

    if require_all_pass and status_by_task:
        fails = [t for t, s in status_by_task.items() if s != "pass"]
        if fails:
            errors.append("require_all_pass: failed tasks: " + ", ".join(fails))

    return errors


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("results", type=Path, help="results JSON array from eval.sh")
    p.add_argument(
        "--baseline",
        type=Path,
        help="baseline.json to compare against",
    )
    p.add_argument(
        "--write-baseline",
        type=Path,
        help="write a new baseline from results and exit 0",
    )
    p.add_argument("--backend", default="unknown")
    p.add_argument("--model", default="unknown")
    p.add_argument("--max-drop-pp", type=float, default=5.0)
    p.add_argument(
        "--require-all-pass",
        action="store_true",
        default=False,
        help="when writing baseline, set require_all_pass true",
    )
    p.add_argument(
        "--no-require-all-pass",
        action="store_true",
        help="when writing baseline, set require_all_pass false",
    )
    p.add_argument(
        "--strict",
        action="store_true",
        help="fail if any result status is not pass (even without baseline)",
    )
    args = p.parse_args()

    try:
        results = load_json(args.results)
        status = results_map(results)
    except Exception as e:
        print(f"compare_baseline: failed to load results: {e}", file=sys.stderr)
        return 2

    if args.write_baseline:
        # Refuse to wipe a baseline with zero tasks (filter miss / empty run).
        if not status:
            print(
                "compare_baseline: refusing --write-baseline with zero tasks "
                "(would wipe baseline). Run a real suite first.",
                file=sys.stderr,
            )
            return 2
        require = True
        if args.no_require_all_pass:
            require = False
        elif args.require_all_pass:
            require = True
        write_baseline(
            args.write_baseline,
            status,
            backend=args.backend,
            model=args.model,
            max_drop_pp=args.max_drop_pp,
            require_all_pass=require,
        )
        print(f"wrote baseline: {args.write_baseline} ({len(status)} tasks)")
        return 0

    errors: list[str] = []
    if args.strict:
        fails = [t for t, s in status.items() if s != "pass"]
        if not status:
            errors.append("strict: no tasks ran")
        elif fails:
            errors.append("strict: failed tasks: " + ", ".join(fails))

    if args.baseline:
        try:
            baseline = load_json(args.baseline)
        except Exception as e:
            print(f"compare_baseline: failed to load baseline: {e}", file=sys.stderr)
            return 2
        if not isinstance(baseline, dict):
            print("compare_baseline: baseline must be a JSON object", file=sys.stderr)
            return 2
        errors.extend(compare(baseline, status))

    if errors:
        print("RATCHET FAIL:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1

    print("RATCHET OK")
    if status:
        print(f"  tasks={len(status)} pass_rate={pass_rate(status):.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
