#!/usr/bin/env python3
"""Inventory source-branch commits against the clean FNV slice boundaries."""

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
    parser.add_argument("--source-root", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()

    plan_path = args.plan.resolve()
    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    source = plan["source"]
    root = (args.source_root or pathlib.Path(source["repository"])).resolve()
    baseline = git(root, "rev-parse", plan["recovery"]["baselineCommit"])
    head = git(root, "rev-parse", source["auditedHead"])
    frozen = plan["frozenBoundaries"]
    slices = [
        row for row in plan["slices"]
        if row["order"] > 0 and row["id"] != "whole-game-crawl-release"
    ]

    commits: list[dict[str, object]] = []
    for commit in git(root, "rev-list", "--reverse", f"{baseline}..{head}").splitlines():
        metadata = git(root, "show", "-s", "--format=%aI%x09%s", commit).split("\t", 1)
        path_rows: list[dict[str, object]] = []
        common_slices: set[str] | None = None
        has_frozen = False
        has_unassigned = False
        for line in git(root, "diff-tree", "--no-commit-id", "--name-status", "-r", commit).splitlines():
            fields = line.split("\t")
            if len(fields) < 2:
                continue
            path = fields[-1].replace("\\", "/")
            frozen_path = matches(path, frozen["pathPrefixes"], frozen["exactPaths"])
            eligible = [
                row["id"] for row in slices
                if matches(path, row["allowedPathPrefixes"], row["allowedExactPaths"])
            ]
            if frozen_path:
                has_frozen = True
            if not eligible:
                has_unassigned = True
            eligible_set = set(eligible)
            common_slices = eligible_set if common_slices is None else common_slices & eligible_set
            path_rows.append(
                {
                    "status": fields[0],
                    "path": path,
                    "frozen": frozen_path,
                    "eligibleSlices": eligible,
                }
            )

        common = sorted(common_slices or set())
        commits.append(
            {
                "commit": commit,
                "authoredAt": metadata[0],
                "subject": metadata[1] if len(metadata) > 1 else "",
                "pathCount": len(path_rows),
                "touchesFrozenBoundary": has_frozen,
                "hasUnassignedPaths": has_unassigned,
                "commonEligibleSlices": common,
                "safeForDirectCherryPick": not has_frozen and not has_unassigned and len(common) == 1,
                "paths": path_rows,
            }
        )

    result = {
        "schema": "nikami-fnv-clean-transplant-candidate-inventory/v1",
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "plan": str(plan_path).replace("\\", "/"),
        "sourceRoot": str(root).replace("\\", "/"),
        "baseline": baseline,
        "head": head,
        "policy": {
            "safeForDirectCherryPick": "No frozen or unassigned path and every changed path belongs to exactly one common slice. This is only a structural preflight; tests and runtime gates are still mandatory.",
            "unsafe": "Re-derive or transplant selected hunks/files into the active clean slice. Never merge the source branch wholesale.",
        },
        "counts": {
            "commits": len(commits),
            "safeForDirectCherryPick": sum(bool(row["safeForDirectCherryPick"]) for row in commits),
            "touchFrozenBoundary": sum(bool(row["touchesFrozenBoundary"]) for row in commits),
            "hasUnassignedPaths": sum(bool(row["hasUnassignedPaths"]) for row in commits),
        },
        "commits": commits,
    }
    encoded = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        output = args.output.resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(encoded, encoding="utf-8", newline="\n")
    print(encoded, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
