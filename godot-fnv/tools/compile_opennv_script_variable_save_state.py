#!/usr/bin/env python3
"""Compile Save330 per-reference SCPT locals required by GetScriptVariable."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compile_state(index_path: Path, overlay_path: Path, output_path: Path) -> dict:
    index = json.loads(index_path.read_text(encoding="utf-8"))
    overlay = json.loads(overlay_path.read_text(encoding="utf-8"))
    if index.get("schema") != "opennv-script-variable-index/v1":
        raise RuntimeError("unexpected script-variable index schema")
    if overlay.get("schema") != "opennv-fos-changeform-index/v1":
        raise RuntimeError("unexpected save overlay schema")
    changeforms = {}
    duplicate_changeforms = []
    for row in overlay.get("changeForms", []):
        ref = str((row.get("refId") or {}).get("resolvedFormId") or "").lower()
        if not ref:
            continue
        if ref in changeforms:
            duplicate_changeforms.append(ref)
        changeforms[ref] = row
    requested = {}
    for row in index.get("function53", []):
        if row.get("targetMode") != "reference" or not row.get("definitionResolved"):
            continue
        key = f"{row['targetReference']}:{int(row['localIndex'])}"
        request = {
            "reference": row["targetReference"],
            "index": int(row["localIndex"]),
            "script": row["script"],
            "name": row.get("localName", ""),
        }
        if key in requested and requested[key] != request:
            raise RuntimeError(f"conflicting condition definitions for {key}")
        requested[key] = request

    values = {}
    failures = []
    unresolved = []
    saved_numeric = 0
    inferred_zero_no_changeform = 0
    inferred_zero_event_list_omission = 0
    for key, request in sorted(requested.items()):
        entry = changeforms.get(request["reference"])
        value = 0.0  # Native ScriptEventList creation/reset initializes every local to zero.
        source = "inferred-zero-no-changeform"
        if entry is not None:
            state = entry.get("scriptState")
            flags = int(entry.get("changeFlags", "0"), 16)
            extra_mask = 0xA4061840 if entry.get("type") in ("ACHR", "ACRE") else 0xA4021C40
            extra_summary = entry.get("changedExtraState")
            if state is None and flags & extra_mask and (not extra_summary or not extra_summary.get("fullyDecoded")):
                unresolved.append({"key": key, "reason": "changed-extra-list-not-fully-decoded"})
                continue
            if state is not None:
                saved_script = str((state.get("script") or {}).get("resolvedFormId") or "").lower()
                if saved_script != str(request["script"]).lower():
                    failures.append({"key": key, "reason": "saved-script-mismatch", "saved": saved_script})
                    continue
                for variable in state.get("variables", []):
                    if int(variable.get("index", -1)) != request["index"]:
                        continue
                    if variable.get("kind") != "numeric":
                        failures.append({"key": key, "reason": "requested-local-is-reference"})
                        break
                    value = float(variable["value"])
                    source = "saved-event-list"
                    saved_numeric += 1
                    break
                if failures and failures[-1].get("key") == key:
                    continue
                if source != "saved-event-list":
                    source = "inferred-zero-fully-decoded-event-list-omission"
        if source == "inferred-zero-no-changeform":
            inferred_zero_no_changeform += 1
        elif source == "inferred-zero-fully-decoded-event-list-omission":
            inferred_zero_event_list_omission += 1
        values[key] = {**request, "value": value, "source": source}

    live_rows = sum(
        1 for row in index.get("function53", [])
        if row.get("targetMode") == "reference"
        and f"{row['targetReference']}:{int(row['localIndex'])}" in values
    )
    expected_rows = int(index["counts"]["function53ExplicitReferenceRows"])
    explicit_saved_rows = sum(
        1 for row in index.get("function53", [])
        if row.get("targetMode") == "reference"
        and values.get(f"{row['targetReference']}:{int(row['localIndex'])}", {}).get("source") == "saved-event-list"
    )
    inferred_zero_rows = live_rows - explicit_saved_rows
    if duplicate_changeforms:
        failures.append({"reason": "duplicate-changeforms", "references": sorted(set(duplicate_changeforms))})
    result = {
        "schema": "opennv-script-variable-save-state/v1",
        "status": "fail" if failures else ("pass" if live_rows == expected_rows else "partial"),
        "provenance": {
            "scriptVariableIndexSha256": sha(index_path),
            "saveOverlaySha256": sha(overlay_path),
            "saveSha256": overlay["source"]["sha256"],
        },
        "counts": {
            "requestedUniqueLocals": len(requested),
            "resolvedUniqueLocals": len(values),
            "inferredZeroNoChangeformLocals": inferred_zero_no_changeform,
            "inferredZeroEventListOmissionLocals": inferred_zero_event_list_omission,
            "savedNumericLocals": saved_numeric,
            "function53ExplicitRows": expected_rows,
            "operationalResolvedExplicitRows": live_rows,
            "explicitSavedValueRows": explicit_saved_rows,
            "inferredZeroRows": inferred_zero_rows,
            "unresolvedExplicitRows": expected_rows - live_rows,
            "failures": len(failures),
        },
        "values": values,
        "failures": failures,
        "unresolved": unresolved,
        "policy": "Explicit saved values are counted separately. No-changeform and fully decoded matching event-list omissions are inferred native-zero values; active but not fully decoded changed-extra lists remain unresolved.",
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("OPENNV_SCRIPT_VARIABLE_SAVE_STATE " + json.dumps(result["counts"], sort_keys=True))
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--save-overlay", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = compile_state(args.index.resolve(), args.save_overlay.resolve(), args.output.resolve())
    return 0 if result["status"] in ("pass", "partial") else 1


if __name__ == "__main__":
    raise SystemExit(main())
