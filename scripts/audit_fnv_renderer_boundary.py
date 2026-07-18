#!/usr/bin/env python3
"""Fail-closed audit of engine changes that can alter FNV set-piece rendering.

The audit deliberately separates actor/creature animation candidates from direct
world-render and reference-lifecycle changes.  It does not decide that a change is
correct merely because it is outside a shader file; every direct renderer change
since the pinned visual baseline remains a suspect until a paired visual invariant
closes it.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import subprocess
import sys
from collections.abc import Iterable


DEFAULT_BASELINE = "6a5576dea5668624c1a720e9d64bf400f750ca97"

DIRECT_RENDER_PREFIXES = (
    "apps/openmw/mwrender/",
    "apps/openmw/mwvr/",
    "components/nif/",
    "components/nifosg/",
    "components/resource/",
    "components/sceneutil/",
    "components/vr/",
    "files/shaders/",
)

WORLD_LIFECYCLE_PATHS = {
    "apps/openmw/mwworld/cellref.cpp",
    "apps/openmw/mwworld/cellref.hpp",
    "apps/openmw/mwworld/cellstore.cpp",
    "apps/openmw/mwworld/cellstore.hpp",
    "apps/openmw/mwworld/livecellref.cpp",
    "apps/openmw/mwworld/livecellref.hpp",
    "apps/openmw/mwworld/scene.cpp",
    "apps/openmw/mwworld/scene.hpp",
    "apps/openmw/mwworld/weather.cpp",
    "apps/openmw/mwworld/weather.hpp",
    "apps/openmw/mwworld/worldimp.cpp",
    "apps/openmw/mwworld/worldimp.hpp",
}

ACTOR_CANDIDATE_PATHS = {
    "apps/openmw/mwrender/animation.cpp",
    "apps/openmw/mwrender/animation.hpp",
    "apps/openmw/mwrender/creatureanimation.cpp",
    "apps/openmw/mwrender/creatureanimation.hpp",
    "apps/openmw/mwrender/esm4npcanimation.cpp",
    "apps/openmw/mwrender/esm4npcanimation.hpp",
    "apps/openmw/mwrender/falloutanimationtargets.hpp",
    "apps/openmw/mwrender/fallouthitreaction.hpp",
    "apps/openmw/mwrender/falloutweaponanimation.hpp",
    "files/shaders/compatibility/bs/skin.frag",
}


def run_git(root: pathlib.Path, *arguments: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=root,
        check=False,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(arguments)} failed ({result.returncode}): {result.stderr.strip()}"
        )
    return result.stdout


def changed_paths(root: pathlib.Path, baseline: str, head: str) -> dict[str, str]:
    statuses: dict[str, str] = {}
    output = run_git(root, "diff", "--name-status", f"{baseline}..{head}")
    for line in output.splitlines():
        fields = line.split("\t")
        if len(fields) < 2:
            continue
        status = fields[0]
        path = fields[-1].replace("\\", "/")
        statuses[path] = status
    return statuses


def working_paths(root: pathlib.Path) -> set[str]:
    paths: set[str] = set()
    for args in (("diff", "--name-only"), ("diff", "--cached", "--name-only")):
        paths.update(
            line.strip().replace("\\", "/")
            for line in run_git(root, *args).splitlines()
            if line.strip()
        )
    return paths


def commit_rows(root: pathlib.Path, baseline: str, head: str, path: str) -> list[dict[str, str]]:
    output = run_git(
        root,
        "log",
        "--format=%H%x09%aI%x09%s",
        f"{baseline}..{head}",
        "--",
        path,
    )
    rows: list[dict[str, str]] = []
    for line in output.splitlines():
        fields = line.split("\t", 2)
        if len(fields) == 3:
            rows.append({"commit": fields[0], "authoredAt": fields[1], "subject": fields[2]})
    return rows


def classify(path: str) -> str:
    if path in ACTOR_CANDIDATE_PATHS:
        return "actor-or-creature-candidate"
    if path in WORLD_LIFECYCLE_PATHS:
        return "world-reference-lifecycle-risk"
    if path.startswith(DIRECT_RENDER_PREFIXES):
        return "direct-world-render-suspect"
    return "outside-render-boundary"


def count_by(rows: Iterable[dict[str, object]], key: str) -> dict[str, int]:
    result: dict[str, int] = {}
    for row in rows:
        value = str(row[key])
        result[value] = result.get(value, 0) + 1
    return dict(sorted(result.items()))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine-root", type=pathlib.Path, required=True)
    parser.add_argument("--baseline", default=DEFAULT_BASELINE)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--fail-on-suspects", action="store_true")
    args = parser.parse_args()

    root = args.engine_root.resolve()
    if not (root / ".git").exists():
        raise SystemExit(f"Not an engine git worktree: {root}")

    baseline = run_git(root, "rev-parse", args.baseline).strip()
    head = run_git(root, "rev-parse", args.head).strip()
    statuses = changed_paths(root, baseline, head)
    dirty = working_paths(root)

    paths = sorted(set(statuses) | dirty)
    rows: list[dict[str, object]] = []
    for path in paths:
        category = classify(path)
        if category == "outside-render-boundary":
            continue
        rows.append(
            {
                "path": path,
                "category": category,
                "baselineToHeadStatus": statuses.get(path),
                "workingTreeModified": path in dirty,
                "commits": commit_rows(root, baseline, head, path),
            }
        )

    direct = [row for row in rows if row["category"] == "direct-world-render-suspect"]
    lifecycle = [row for row in rows if row["category"] == "world-reference-lifecycle-risk"]
    result = {
        "schema": "nikami-fnv-renderer-boundary-audit/v1",
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "engineRoot": str(root).replace("\\", "/"),
        "baseline": baseline,
        "head": head,
        "workingTreeClean": not dirty,
        "policy": {
            "directWorldRender": "fail until paired baseline/current visual and render-state invariants pass",
            "worldReferenceLifecycle": "fail until reference presence, visibility, transform, cell transition, and save-load invariants pass",
            "actorOrCreatureCandidate": "eligible for transplantation only after actor differential and renderer invariants both pass",
        },
        "counts": {
            "rows": len(rows),
            "byCategory": count_by(rows, "category"),
            "directWorldRenderSuspects": len(direct),
            "worldReferenceLifecycleRisks": len(lifecycle),
            "workingTreeModifiedRows": sum(bool(row["workingTreeModified"]) for row in rows),
        },
        "pass": not direct and not lifecycle,
        "rows": rows,
    }

    encoded = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        output = args.output.resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(encoded, encoding="utf-8", newline="\n")
    print(encoded, end="")

    if args.fail_on_suspects and not result["pass"]:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
