#!/usr/bin/env python3
"""Fail closed when the clean FNV recovery branch crosses a slice boundary."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import subprocess
import sys


def git(root: pathlib.Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def matches(path: str, prefixes: list[str], exact: list[str]) -> bool:
    return path in exact or any(path.startswith(prefix) for prefix in prefixes)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", type=pathlib.Path, required=True)
    parser.add_argument("--engine-root", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--fail-on-violation", action="store_true")
    args = parser.parse_args()

    plan_path = args.plan.resolve()
    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    recovery = plan["recovery"]
    root = (args.engine_root or pathlib.Path(recovery["repository"])).resolve()
    baseline = git(root, "rev-parse", recovery["baselineCommit"])
    head = git(root, "rev-parse", "HEAD")
    branch = git(root, "branch", "--show-current")
    active_id = recovery["activeSliceId"]
    slices = plan["slices"]
    active = next((row for row in slices if row["id"] == active_id), None)
    if active is None:
        raise SystemExit(f"Unknown active slice: {active_id}")

    eligible = [
        row
        for row in slices
        if row["status"] in {"complete", "active"} and row["order"] <= active["order"]
    ]
    allowed_prefixes = [prefix for row in eligible for prefix in row["allowedPathPrefixes"]]
    allowed_exact = [path for row in eligible for path in row["allowedExactPaths"]]
    frozen = plan["frozenBoundaries"]

    committed = {
        line.replace("\\", "/")
        for line in git(root, "diff", "--name-only", f"{baseline}..{head}").splitlines()
        if line
    }
    working = set()
    for git_args in (("diff", "--name-only"), ("diff", "--cached", "--name-only")):
        working.update(
            line.replace("\\", "/")
            for line in git(root, *git_args).splitlines()
            if line
        )
    changed = sorted(committed | working)

    violations: list[dict[str, str]] = []
    if baseline != recovery["baselineCommit"]:
        violations.append({"kind": "baseline-mismatch", "path": baseline})
    if branch != recovery["branch"]:
        violations.append({"kind": "branch-mismatch", "path": branch})
    if git(root, "merge-base", baseline, head) != baseline:
        violations.append({"kind": "non-descendant-head", "path": head})

    for path in changed:
        if matches(path, frozen["pathPrefixes"], frozen["exactPaths"]):
            violations.append({"kind": "frozen-boundary", "path": path})
        elif not matches(path, allowed_prefixes, allowed_exact):
            violations.append({"kind": "outside-active-slice", "path": path})

    result = {
        "schema": "nikami-fnv-clean-transplant-audit/v1",
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "plan": str(plan_path).replace("\\", "/"),
        "engineRoot": str(root).replace("\\", "/"),
        "branch": branch,
        "baseline": baseline,
        "head": head,
        "activeSliceId": active_id,
        "workingTreeClean": not working,
        "changedPaths": changed,
        "violations": violations,
        "pass": not violations,
    }
    encoded = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        output = args.output.resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(encoded, encoding="utf-8", newline="\n")
    print(encoded, end="")
    return 2 if args.fail_on_violation and violations else 0


if __name__ == "__main__":
    sys.exit(main())
