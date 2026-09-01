#!/usr/bin/env python3
"""Bootstrap and verify the versioned Lambda64 TODO/FIXME inventory.

This scanner intentionally reads the working filesystem, not just Git's index.
It implements the bootstrap, immutable-ledger freeze, and read-only verify
phases using shared canonical-JSON and fail-closed primitives.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, NoReturn


SCHEMA_VERSION = 1
EXPECTED_COUNTS = {"raw": 484, "source": 451, "documentation": 4, "data": 29}
SOURCE_SUFFIXES = {".lisp", ".lsp", ".asd", ".sh", ".c", ".h", ".md"}
UNICODE_PATH = "Lambda64/tools/UnicodeData.txt"
GOVERNANCE_ROOT = "docs/modernization/todo-fixme"
OUTPUT_PATHS = {
    "occurrences": f"{GOVERNANCE_ROOT}/occurrences.json",
    "unicode": f"{GOVERNANCE_ROOT}/unicode-allowlist.json",
    "snapshot": f"{GOVERNANCE_ROOT}/baseline-snapshot.json",
}
BOOTSTRAP_PREREQUISITES = (
    "scripts/check-todo-fixme.py",
    "Makefile",
    f"{GOVERNANCE_ROOT}/schema/occurrence.schema.json",
    f"{GOVERNANCE_ROOT}/schema/snapshot.schema.json",
    f"{GOVERNANCE_ROOT}/schema/unicode-allowlist.schema.json",
    f"{GOVERNANCE_ROOT}/schema/product-source-manifest.schema.json",
)
VERIFY_PREREQUISITES = BOOTSTRAP_PREREQUISITES + (
    "Lambda64/tests/host/test-todo-fixme-ledger.sh",
)
FREEZE_PREREQUISITES = VERIFY_PREREQUISITES + tuple(OUTPUT_PATHS.values()) + (
    f"{GOVERNANCE_ROOT}/schema/work-item.schema.json",
    f"{GOVERNANCE_ROOT}/schema/work-item-status.schema.json",
    f"{GOVERNANCE_ROOT}/schema/mapping.schema.json",
    f"{GOVERNANCE_ROOT}/work-items.json",
    f"{GOVERNANCE_ROOT}/occurrence-work-items.json",
)
EXIT_CODES = {
    "usage": 2,
    "prerequisite": 3,
    "canonical": 4,
    "scan": 5,
    "allowlist": 6,
    "untracked": 7,
    "lease": 8,
    "evidence": 9,
}


@dataclass(frozen=True)
class ScanResult:
    occurrences: list[dict[str, Any]]
    unicode_records: list[dict[str, str]]
    unicode_file_sha256: str
    raw_scan_sha256: str
    counts: dict[str, int]


class ScannerError(Exception):
    def __init__(self, code: str, message: str, exit_code: int, phase: str):
        super().__init__(message)
        self.code = code
        self.message = message
        self.exit_code = exit_code
        self.phase = phase


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def compact_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def fail(code: str, message: str, exit_class: str, phase: str) -> NoReturn:
    raise ScannerError(code, message, EXIT_CODES[exit_class], phase)


def git(root: Path, *args: str, check: bool = True) -> bytes:
    proc = subprocess.run(
        ["git", "-C", os.fspath(root), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and proc.returncode != 0:
        fail("MISSING_AUTHORITY_FILE", proc.stderr.decode("utf-8", "replace").strip(), "prerequisite", "git")
    return proc.stdout


def repository_root() -> Path:
    proc = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
    )
    if proc.returncode != 0:
        fail("MISSING_AUTHORITY_FILE", "current directory is not inside a Git worktree", "prerequisite", "startup")
    return Path(os.fsdecode(proc.stdout).strip()).resolve()


def is_scan_input(relative: str) -> bool:
    path = Path(relative)
    if not relative.startswith("Lambda64/"):
        return False
    if relative.startswith("Lambda64/home/") or relative.startswith("Lambda64/.git/"):
        return False
    if relative == "Lambda64/tests/host/test-todo-fixme-ledger.sh":
        return False
    if relative == UNICODE_PATH:
        return True
    return path.suffix.lower() in SOURCE_SUFFIXES


def filesystem_scan_paths(root: Path) -> list[Path]:
    lambda_root = root / "Lambda64"
    if not lambda_root.is_dir():
        fail("MISSING_AUTHORITY_FILE", "Lambda64 source directory is missing", "prerequisite", "scan")
    paths: list[Path] = []
    for path in lambda_root.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        if is_scan_input(relative):
            paths.append(path)
    return sorted(paths, key=lambda item: item.relative_to(root).as_posix().encode("utf-8"))


def marker_for(line: str) -> str | None:
    upper = line.upper()
    positions = [(upper.find(marker), marker) for marker in ("TODO", "FIXME") if upper.find(marker) >= 0]
    return min(positions)[1] if positions else None


def normalize_line(line: str) -> str:
    return " ".join(line.strip().split())


def scan(root: Path) -> ScanResult:
    raw: list[dict[str, Any]] = []
    unicode_records: list[dict[str, str]] = []
    unicode_bytes = b""
    for path in filesystem_scan_paths(root):
        relative = path.relative_to(root).as_posix()
        data = path.read_bytes()
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as exc:
            fail("SCAN_LEDGER_MISMATCH", f"{relative} is not valid UTF-8: {exc}", "scan", "scan")
        lines = text.splitlines()
        if relative == UNICODE_PATH:
            unicode_bytes = data
        for index, line in enumerate(lines):
            marker = marker_for(line)
            if marker is None:
                continue
            normalized = normalize_line(line)
            context = "\n".join(lines[max(0, index - 2) : min(len(lines), index + 3)])
            if relative == UNICODE_PATH:
                codepoint = line.split(";", 1)[0]
                unicode_records.append(
                    {
                        "codepoint": codepoint,
                        "full-record": line,
                        "record-sha256": sha256_bytes(line.encode("utf-8")),
                    }
                )
                kind = "data-false-positive"
            elif path.suffix.lower() == ".md":
                kind = "documentation"
            else:
                kind = "source"
            # The normalized text and its local context are not necessarily
            # unique: mechanically repeated TODO/FIXME comments can occur in
            # the same file. Keep the source line in the immutable baseline
            # identity so every baseline occurrence has a distinct stable ID.
            identity = "\0".join(
                (
                    relative,
                    str(index + 1),
                    marker,
                    normalized,
                    sha256_bytes(context.encode("utf-8")),
                )
            )
            raw.append(
                {
                    "id": f"TF-occ-{sha256_bytes(identity.encode('utf-8'))[:24]}",
                    "path": relative,
                    "line": index + 1,
                    "marker": marker,
                    "text": line,
                    "kind": kind,
                    "content-sha256": sha256_bytes(normalized.encode("utf-8")),
                    "context-sha256": sha256_bytes(context.encode("utf-8")),
                }
            )
    ids = [item["id"] for item in raw]
    if len(ids) != len(set(ids)):
        fail("SCAN_LEDGER_MISMATCH", "stable occurrence ID collision", "scan", "scan")
    raw.sort(key=lambda item: (item["path"].encode("utf-8"), item["line"], item["marker"]))
    unicode_records.sort(key=lambda item: item["codepoint"])
    counts = {
        "raw": len(raw),
        "source": sum(item["kind"] == "source" for item in raw),
        "documentation": sum(item["kind"] == "documentation" for item in raw),
        "data": sum(item["kind"] == "data-false-positive" for item in raw),
    }
    scan_fact = [
        {key: item[key] for key in ("path", "marker", "text", "kind", "content-sha256", "context-sha256")}
        for item in raw
    ]
    return ScanResult(raw, unicode_records, sha256_bytes(unicode_bytes), sha256_bytes(canonical_bytes(scan_fact)), counts)


def tracked_paths(root: Path) -> set[str]:
    return set(os.fsdecode(item) for item in git(root, "ls-files", "-z").split(b"\0") if item)


def require_tracked_clean(root: Path, paths: Iterable[str], phase: str) -> None:
    tracked = tracked_paths(root)
    for relative in paths:
        path = root / relative
        if not path.is_file() or relative not in tracked:
            fail("UNTRACKED_PREREQUISITE", f"required tracked file is missing: {relative}", "prerequisite", phase)
        indexed = git(root, "show", f":{relative}", check=False)
        if indexed != path.read_bytes():
            fail("UNTRACKED_PREREQUISITE", f"worktree differs from index: {relative}", "prerequisite", phase)
    makefile = (root / "Makefile").read_text(encoding="utf-8")
    if "todo-fixme-check:" not in makefile or "scripts/check-todo-fixme.py --verify" not in makefile:
        fail("UNTRACKED_PREREQUISITE", "Makefile todo-fixme-check target is missing or incorrect", "prerequisite", phase)


def unknown_untracked_sources(root: Path) -> list[str]:
    output = git(root, "ls-files", "--others", "-z", "--", "Lambda64")
    return sorted(
        relative
        for relative in (os.fsdecode(item) for item in output.split(b"\0") if item)
        if is_scan_input(relative)
    )


def product_manifest(root: Path) -> tuple[list[dict[str, Any]], str]:
    candidates: set[Path] = set()
    lambda_root = root / "Lambda64"
    for path in lambda_root.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        if (
            relative.startswith("Lambda64/home/")
            or relative.startswith("Lambda64/.git/")
            or relative.startswith("Lambda64/doc/")
            or relative.startswith("Lambda64/build-arm64/")
            or relative == "Lambda64/tests/host/test-todo-fixme-ledger.sh"
            or path.suffix.lower() in {".llf", ".log"}
        ):
            continue
        candidates.add(path)
    for relative in (".gitmodules", "Makefile", "build-cold-image.lisp", "run-file-server.lisp", "local.mk"):
        path = root / relative
        if path.is_file():
            candidates.add(path)
    scripts = root / "scripts"
    if scripts.is_dir():
        for path in scripts.rglob("*"):
            if path.is_file() and not path.is_symlink() and path.name != "check-todo-fixme.py":
                candidates.add(path)
    entries: list[dict[str, Any]] = []
    for path in sorted(candidates, key=lambda item: item.relative_to(root).as_posix().encode("utf-8")):
        relative = path.relative_to(root).as_posix()
        if relative.startswith(f"{GOVERNANCE_ROOT}/") or relative == "Lambda64/tests/host/test-todo-fixme-ledger.sh":
            continue
        data = path.read_bytes()
        entries.append(
            {
                "path": relative,
                "mode": stat.S_IMODE(path.stat().st_mode),
                "size": len(data),
                "sha256": sha256_bytes(data),
            }
        )
    return entries, sha256_bytes(canonical_bytes(entries))


def commit_timestamp(root: Path, head: str) -> str:
    raw = git(root, "show", "-s", "--format=%cI", head).decode("ascii").strip()
    return datetime.fromisoformat(raw).astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def read_json_canonical(path: Path, phase: str) -> Any:
    try:
        data = path.read_bytes()
        value = json.loads(data.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail("SCHEMA_INVALID", f"cannot read {path}: {exc}", "canonical", phase)
    if data != canonical_bytes(value):
        fail("NON_CANONICAL_JSON", f"non-canonical JSON: {path}", "canonical", phase)
    return value


def read_json(path: Path, phase: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail("SCHEMA_INVALID", f"cannot read {path}: {exc}", "canonical", phase)


def schema_type_matches(value: Any, expected: str) -> bool:
    return {
        "null": value is None,
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": type(value) is int,
        "number": type(value) in {int, float},
        "boolean": type(value) is bool,
    }.get(expected, True)


def validate_schema_value(value: Any, schema: dict[str, Any], label: str, phase: str) -> None:
    expected = schema.get("type")
    if expected is not None:
        expected_types = [expected] if isinstance(expected, str) else expected
        if not any(schema_type_matches(value, item) for item in expected_types):
            fail("SCHEMA_INVALID", f"{label} has invalid type", "canonical", phase)
    if "const" in schema and value != schema["const"]:
        fail("SCHEMA_INVALID", f"{label} differs from schema constant", "canonical", phase)
    if "enum" in schema and value not in schema["enum"]:
        fail("SCHEMA_INVALID", f"{label} is not an allowed value", "canonical", phase)
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            fail("SCHEMA_INVALID", f"{label} is too short", "canonical", phase)
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            fail("SCHEMA_INVALID", f"{label} does not match its schema pattern", "canonical", phase)
    if type(value) in {int, float} and "minimum" in schema and value < schema["minimum"]:
        fail("SCHEMA_INVALID", f"{label} is below its schema minimum", "canonical", phase)
    if isinstance(value, list) and "items" in schema:
        if len(value) < schema.get("minItems", 0):
            fail("SCHEMA_INVALID", f"{label} has too few items", "canonical", phase)
        for index, item in enumerate(value):
            validate_schema_value(item, schema["items"], f"{label}[{index}]", phase)
    if isinstance(value, dict):
        properties = schema.get("properties", {})
        missing = sorted(set(schema.get("required", [])) - set(value))
        if missing:
            fail("SCHEMA_INVALID", f"{label} is missing {missing[0]}", "canonical", phase)
        if schema.get("additionalProperties") is False:
            extras = sorted(set(value) - set(properties))
            if extras:
                fail("SCHEMA_INVALID", f"{label} has unexpected field {extras[0]}", "canonical", phase)
        for key, item in value.items():
            if key in properties:
                validate_schema_value(item, properties[key], f"{label}.{key}", phase)


def validate_with_schema(root: Path, value: Any, schema_name: str, label: str, phase: str) -> Any:
    schema_path = root / GOVERNANCE_ROOT / "schema" / f"{schema_name}.schema.json"
    schema = read_json(schema_path, phase)
    validate_schema_value(value, require_object(schema, f"{schema_name} schema", phase), label, phase)
    return value


def require_object(value: Any, label: str, phase: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail("SCHEMA_INVALID", f"{label} must be a JSON object", "canonical", phase)
    return value


def validate_occurrence_ledger(value: Any, phase: str) -> dict[str, Any]:
    ledger = require_object(value, "occurrence ledger", phase)
    if set(ledger) != {"schema-version", "baseline-id", "occurrences"}:
        fail("SCHEMA_INVALID", "occurrence ledger has unexpected fields", "canonical", phase)
    if ledger.get("schema-version") != SCHEMA_VERSION or not isinstance(ledger.get("baseline-id"), str):
        fail("SCHEMA_INVALID", "occurrence ledger metadata is invalid", "canonical", phase)
    items = ledger.get("occurrences")
    if not isinstance(items, list):
        fail("SCHEMA_INVALID", "occurrences must be an array", "canonical", phase)
    allowed_keys = {"id", "path", "line", "marker", "text", "kind", "content-sha256", "context-sha256"}
    required_keys = allowed_keys - {"context-sha256"}
    seen: set[str] = set()
    for index, item in enumerate(items):
        item = require_object(item, f"occurrence {index}", phase)
        if not required_keys <= set(item) <= allowed_keys:
            fail("SCHEMA_INVALID", f"occurrence {index} fields are invalid", "canonical", phase)
        occurrence_id = item.get("id")
        hashes = (item.get("content-sha256"), item.get("context-sha256", "0" * 64))
        if (
            not isinstance(occurrence_id, str)
            or not occurrence_id.startswith("TF-")
            or occurrence_id in seen
            or not isinstance(item.get("path"), str)
            or not item["path"].startswith("Lambda64/")
            or type(item.get("line")) is not int
            or item["line"] < 1
            or item.get("marker") not in {"TODO", "FIXME"}
            or item.get("kind") not in {"source", "documentation", "data-false-positive"}
            or not isinstance(item.get("text"), str)
            or any(not isinstance(digest, str) or len(digest) != 64 or any(ch not in "0123456789abcdef" for ch in digest) for digest in hashes)
        ):
            fail("SCHEMA_INVALID", f"occurrence {index} value is invalid", "canonical", phase)
        seen.add(occurrence_id)
    return ledger


def validate_snapshot(value: Any, phase: str) -> dict[str, Any]:
    snapshot = require_object(value, "baseline snapshot", phase)
    required = {
        "schema-version", "baseline-id", "phase", "created-at", "frozen-at",
        "source-baseline-head", "source-baseline-tree", "source-baseline-index-tree",
        "baseline-product-input-manifest-sha256", "baseline-raw-occurrence-scan-sha256",
        "baseline-unicode-input-sha256", "governance-freeze-head", "governance-freeze-tree",
        "governance-freeze-index-tree", "governance-freeze-manifest-sha256",
        "scanner-bootstrap-sha256", "scanner-freeze-sha256", "occurrences-sha256",
        "work-items-identity-spec-sha256", "mapping-sha256", "unicode-allowlist-sha256", "counts",
    }
    if set(snapshot) != required or snapshot.get("schema-version") != SCHEMA_VERSION:
        fail("SCHEMA_INVALID", "baseline snapshot fields are invalid", "canonical", phase)
    counts = snapshot.get("counts")
    if not isinstance(counts, dict) or set(counts) != {"raw", "source", "documentation", "data", "logical-total"}:
        fail("SCHEMA_INVALID", "baseline snapshot counts are invalid", "canonical", phase)
    if any(type(counts[key]) is not int or counts[key] < 0 for key in ("raw", "source", "documentation", "data")):
        fail("SCHEMA_INVALID", "baseline snapshot counts must be non-negative integers", "canonical", phase)
    if snapshot.get("phase") not in {"bootstrap", "frozen"}:
        fail("BASELINE_PHASE_INVALID", "unknown baseline phase", "canonical", phase)
    return snapshot


def validate_work_items(root: Path, value: Any, baseline_id: str, phase: str) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    ledger = require_object(validate_with_schema(root, value, "work-item", "work-item ledger", phase), "work-item ledger", phase)
    if ledger.get("baseline-id") != baseline_id:
        fail("SNAPSHOT_HASH_MISMATCH", "work-item baseline ID differs from snapshot", "allowlist", phase)
    items = ledger["work-items"]
    ids = [item["id"] for item in items]
    if ids != sorted(ids) or len(ids) != len(set(ids)):
        fail("SCHEMA_INVALID", "work-item IDs must be unique and sorted", "canonical", phase)
    for item in items:
        test_levels = item["required-test-levels"]
        if len(test_levels) != len(set(test_levels)):
            fail("SCHEMA_INVALID", f"{item['id']} required-test-levels must be unique", "canonical", phase)
        resource_ids = item["required-resource-ids"]
        if resource_ids != sorted(resource_ids) or len(resource_ids) != len(set(resource_ids)):
            fail("SCHEMA_INVALID", f"{item['id']} required-resource-ids must be unique and sorted", "canonical", phase)
        spec_path = item.get("spec-path")
        if item["risk"] in {"high", "critical"} and not spec_path:
            fail("MISSING_AUTHORITY_FILE", f"{item['id']} requires a frozen spec", "prerequisite", phase)
        if spec_path:
            expected_prefix = f"{GOVERNANCE_ROOT}/specs/"
            if not spec_path.startswith(expected_prefix) or not spec_path.endswith(".md") or ".." in Path(spec_path).parts:
                fail("SCHEMA_INVALID", f"invalid spec path for {item['id']}", "canonical", phase)
    return ledger, {item["id"]: item for item in items}


def validate_mapping(
    root: Path,
    value: Any,
    baseline_id: str,
    occurrences: dict[str, dict[str, Any]],
    work_items: dict[str, dict[str, Any]],
    phase: str,
) -> dict[str, Any]:
    mapping = require_object(validate_with_schema(root, value, "mapping", "mapping ledger", phase), "mapping ledger", phase)
    if mapping.get("baseline-id") != baseline_id:
        fail("SNAPSHOT_HASH_MISMATCH", "mapping baseline ID differs from snapshot", "allowlist", phase)
    links = mapping["links"]
    sort_keys = [(item["occurrence-id"], item["work-item-id"], item["relation"]) for item in links]
    if sort_keys != sorted(sort_keys) or len(sort_keys) != len(set(sort_keys)):
        fail("SCHEMA_INVALID", "mapping links must be unique and sorted", "canonical", phase)
    linked_occurrences: set[str] = set()
    linked_work_items: set[str] = set()
    for link in links:
        occurrence_id = link["occurrence-id"]
        work_item_id = link["work-item-id"]
        if occurrence_id not in occurrences:
            fail("ORPHAN_OCCURRENCE", f"mapping references unknown occurrence {occurrence_id}", "scan", phase)
        if work_item_id not in work_items:
            fail("ORPHAN_WORK_ITEM", f"mapping references unknown work item {work_item_id}", "scan", phase)
        if occurrences[occurrence_id]["kind"] == "data-false-positive":
            fail("SCAN_LEDGER_MISMATCH", f"data false-positive {occurrence_id} must not map to work", "scan", phase)
        linked_occurrences.add(occurrence_id)
        linked_work_items.add(work_item_id)
    actionable = {key for key, item in occurrences.items() if item["kind"] != "data-false-positive"}
    missing_occurrences = sorted(actionable - linked_occurrences)
    if missing_occurrences:
        fail("ORPHAN_OCCURRENCE", f"actionable occurrence has no work item: {missing_occurrences[0]}", "scan", phase)
    missing_work_items = sorted(set(work_items) - linked_work_items)
    if missing_work_items:
        fail("ORPHAN_WORK_ITEM", f"work item has no occurrence: {missing_work_items[0]}", "scan", phase)
    return mapping


def validate_status_ledger(
    root: Path,
    value: Any,
    baseline_id: str,
    work_item_ids: set[str],
    phase: str,
) -> dict[str, Any]:
    ledger = require_object(
        validate_with_schema(root, value, "work-item-status", "work-item status ledger", phase),
        "work-item status ledger",
        phase,
    )
    if ledger.get("baseline-id") != baseline_id:
        fail("STATUS_IDENTITY_MISMATCH", "status baseline ID differs from snapshot", "scan", phase)
    statuses = ledger["statuses"]
    ids = [item["work-item-id"] for item in statuses]
    if ids != sorted(ids) or len(ids) != len(set(ids)) or set(ids) != work_item_ids:
        fail("STATUS_IDENTITY_MISMATCH", "status IDs do not exactly match frozen work-item IDs", "scan", phase)
    order = {name: index for index, name in enumerate(("inventoried", "specified", "test-locked", "implemented", "verified"))}
    for item in statuses:
        history = item["history"]
        if not history:
            fail("INVALID_STATUS_TRANSITION", f"{item['work-item-id']} has empty history", "scan", phase)
        previous = None
        for index, event in enumerate(history):
            if event["from"] != previous or event["to"] not in order:
                fail("INVALID_STATUS_TRANSITION", f"invalid history chain for {item['work-item-id']}", "scan", phase)
            if index and order[event["to"]] != order[previous] + 1:
                fail("INVALID_STATUS_TRANSITION", f"non-sequential transition for {item['work-item-id']}", "scan", phase)
            previous = event["to"]
        if previous != item["status"]:
            fail("INVALID_STATUS_TRANSITION", f"history does not end at current status for {item['work-item-id']}", "scan", phase)
        if item["evidence-ids"] != sorted(set(item["evidence-ids"])) or item["lease-ids"] != sorted(set(item["lease-ids"])):
            fail("SCHEMA_INVALID", f"status references for {item['work-item-id']} must be unique and sorted", "canonical", phase)
        if item["updated-at"] != history[-1]["at"] or item["updated-by"] != history[-1]["actor"]:
            fail("INVALID_STATUS_TRANSITION", f"update audit differs from history for {item['work-item-id']}", "scan", phase)
    return ledger


def is_governance_change(relative: str) -> bool:
    return (
        relative.startswith(f"{GOVERNANCE_ROOT}/")
        or relative == "scripts/check-todo-fixme.py"
        or relative == "Lambda64/tests/host/test-todo-fixme-ledger.sh"
    )


def nul_paths(data: bytes) -> list[str]:
    return [os.fsdecode(item) for item in data.split(b"\0") if item]


def require_freeze_change_scope(root: Path, source_baseline_index_tree: str) -> None:
    """Allow only governance changes made after the bootstrap index snapshot.

    Bootstrap intentionally records the index tree as well as ``HEAD`` so a
    caller may establish the inventory alongside already-staged project work.
    Comparing against ``HEAD`` here loses that distinction and incorrectly
    treats those baseline inputs as post-bootstrap drift.
    """
    current_index_tree = git(root, "write-tree").decode("ascii").strip()
    changed = set(
        nul_paths(
            git(
                root,
                "diff-tree",
                "--no-commit-id",
                "--name-only",
                "-r",
                "-z",
                source_baseline_index_tree,
                current_index_tree,
            )
        )
    )
    outside = sorted(path for path in changed if not is_governance_change(path))
    if outside:
        fail("GOVERNANCE_PATH_NOT_ALLOWED", f"non-governance change since bootstrap: {outside[0]}", "scan", "freeze-ledger")
    unstaged = nul_paths(git(root, "diff", "--name-only", "-z"))
    if unstaged:
        code = "UNTRACKED_PREREQUISITE" if all(is_governance_change(path) for path in unstaged) else "GOVERNANCE_PATH_NOT_ALLOWED"
        category = "prerequisite" if code == "UNTRACKED_PREREQUISITE" else "scan"
        fail(code, f"worktree differs from index: {unstaged[0]}", category, "freeze-ledger")
    untracked = nul_paths(git(root, "ls-files", "--others", "--exclude-standard", "-z"))
    if untracked:
        code = "UNTRACKED_PREREQUISITE" if all(is_governance_change(path) for path in untracked) else "GOVERNANCE_PATH_NOT_ALLOWED"
        category = "prerequisite" if code == "UNTRACKED_PREREQUISITE" else "scan"
        fail(code, f"untracked freeze input: {untracked[0]}", category, "freeze-ledger")


def index_governance_manifest(root: Path, index_tree: str) -> tuple[list[dict[str, str]], str]:
    output = git(
        root,
        "ls-tree",
        "-r",
        "-z",
        index_tree,
        "--",
        GOVERNANCE_ROOT,
        "scripts/check-todo-fixme.py",
        "Lambda64/tests/host/test-todo-fixme-ledger.sh",
    )
    entries: list[dict[str, str]] = []
    for record in output.split(b"\0"):
        if not record:
            continue
        metadata, raw_path = record.split(b"\t", 1)
        mode, object_type, object_id = metadata.decode("ascii").split()
        if object_type != "blob":
            continue
        relative = os.fsdecode(raw_path)
        blob = git(root, "cat-file", "blob", object_id)
        entries.append({"path": relative, "mode": mode, "sha256": sha256_bytes(blob)})
    entries.sort(key=lambda item: item["path"].encode("utf-8"))
    return entries, sha256_bytes(canonical_bytes(entries))


def immutable_work_item_hash(root: Path, ledger: dict[str, Any], items: dict[str, dict[str, Any]], phase: str) -> str:
    tracked = tracked_paths(root)
    specs: list[dict[str, str]] = []
    for item in items.values():
        spec_path = item.get("spec-path")
        if not spec_path:
            continue
        path = root / spec_path
        if spec_path not in tracked or not path.is_file():
            fail("MISSING_AUTHORITY_FILE", f"missing tracked spec: {spec_path}", "prerequisite", phase)
        indexed = git(root, "show", f":{spec_path}", check=False)
        if indexed != path.read_bytes():
            fail("UNTRACKED_PREREQUISITE", f"spec worktree differs from index: {spec_path}", "prerequisite", phase)
        specs.append({"path": spec_path, "sha256": sha256_bytes(path.read_bytes())})
    specs.sort(key=lambda item: item["path"].encode("utf-8"))
    identity = {"work-items-sha256": sha256_bytes(canonical_bytes(ledger)), "specs": specs}
    return sha256_bytes(canonical_bytes(identity))


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def format_utc(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_utc(value: str, label: str, phase: str) -> datetime:
    if not value.endswith("Z"):
        fail("SCHEMA_INVALID", f"{label} must be an RFC3339 UTC timestamp ending in Z", "canonical", phase)
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        fail("SCHEMA_INVALID", f"{label} is not a valid RFC3339 timestamp", "canonical", phase)
    return parsed


def target_state(root: Path, relative: str, hash_key: str) -> dict[str, Any]:
    path = root / relative
    exists = path.is_file() and not path.is_symlink()
    return {"path": relative, "exists": exists, hash_key: sha256_bytes(path.read_bytes()) if exists else None}


def lease_filesystem_manifest(root: Path) -> tuple[str, list[dict[str, Any]]]:
    excluded = f"{GOVERNANCE_ROOT}/ownership-leases.json"
    entries: list[dict[str, Any]] = []
    for path in root.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        if (
            relative == excluded
            or relative.startswith(".git/")
            or relative.startswith(".omx/")
            or relative.startswith("test-results/")
            or "/__pycache__/" in f"/{relative}"
            or relative.startswith("Lambda64/build-arm64/")
            or path.suffix.lower() in {".llf", ".log", ".pyc"}
        ):
            continue
        data = path.read_bytes()
        entries.append(
            {
                "path": relative,
                "mode": f"{stat.S_IMODE(path.stat().st_mode):o}",
                "size": len(data),
                "sha256": sha256_bytes(data),
            }
        )
    entries.sort(key=lambda item: item["path"].encode("utf-8"))
    digest = hashlib.sha256()
    for item in entries:
        for value in (item["path"], item["mode"], str(item["size"]), item["sha256"]):
            digest.update(value.encode("utf-8"))
            digest.update(b"\0")
    return digest.hexdigest(), entries


def lease_repository_state(root: Path) -> dict[str, str]:
    index_manifest = git(root, "ls-files", "-s", "-z")
    status = git(root, "status", "--porcelain=v2", "-z", "--untracked-files=all")
    filesystem_hash, _ = lease_filesystem_manifest(root)
    index_hash = sha256_bytes(index_manifest)
    status_hash = sha256_bytes(status)
    return {
        "head": git(root, "rev-parse", "HEAD").decode("ascii").strip(),
        "head-tree": git(root, "rev-parse", "HEAD^{tree}").decode("ascii").strip(),
        "index-tree": git(root, "write-tree").decode("ascii").strip(),
        "index-manifest-sha256": index_hash,
        "filesystem-manifest-sha256": filesystem_hash,
        "worktree-status-sha256": status_hash,
        "worktree-content-sha256": sha256_bytes(
            canonical_bytes(
                {
                    "filesystem-manifest-sha256": filesystem_hash,
                    "index-manifest-sha256": index_hash,
                    "worktree-status-sha256": status_hash,
                }
            )
        ),
    }


LEASE_KEYS = {
    "lease-id", "holder", "work-item-ids", "target-files", "state", "acquired-at", "expires-at",
    "base-head", "base-head-tree", "base-index-tree", "base-index-manifest-sha256",
    "base-filesystem-manifest-sha256", "base-worktree-status-sha256", "base-worktree-content-sha256",
    "target-pre-state", "post-head", "post-head-tree", "post-index-tree", "post-index-manifest-sha256",
    "post-filesystem-manifest-sha256", "post-worktree-status-sha256", "post-worktree-content-sha256",
    "target-post-state", "evidence-ids", "closed-at",
}


def validate_leases(
    root: Path,
    value: Any,
    work_item_ids: set[str],
    phase: str,
    check_active_state: bool,
) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    ledger = require_object(validate_with_schema(root, value, "lease", "ownership lease ledger", phase), "ownership lease ledger", phase)
    if set(ledger) != {"schema-version", "leases"}:
        fail("SCHEMA_INVALID", "ownership lease ledger has unexpected fields", "canonical", phase)
    leases = ledger["leases"]
    ids = [item.get("lease-id") for item in leases]
    if any(not isinstance(item, str) or not item for item in ids) or ids != sorted(ids) or len(ids) != len(set(ids)):
        fail("SCHEMA_INVALID", "lease IDs must be unique and sorted", "canonical", phase)
    active_targets: dict[str, str] = {}
    now = utc_now()
    current_state = lease_repository_state(root) if check_active_state and any(item.get("state") == "active" for item in leases) else None
    for lease in leases:
        if set(lease) != LEASE_KEYS:
            fail("SCHEMA_INVALID", f"lease {lease.get('lease-id')} fields are invalid", "canonical", phase)
        lease_id = lease["lease-id"]
        if not lease["holder"].strip():
            fail("SCHEMA_INVALID", f"lease {lease_id} holder is empty", "canonical", phase)
        for field in ("work-item-ids", "target-files", "evidence-ids"):
            values = lease[field]
            if not isinstance(values, list) or values != sorted(values) or len(values) != len(set(values)):
                fail("SCHEMA_INVALID", f"lease {lease_id} {field} must be unique and sorted", "canonical", phase)
        if not lease["work-item-ids"] or not set(lease["work-item-ids"]) <= work_item_ids:
            fail("STATUS_IDENTITY_MISMATCH", f"lease {lease_id} references unknown work item", "scan", phase)
        if not lease["target-files"]:
            fail("SCHEMA_INVALID", f"lease {lease_id} has no target files", "canonical", phase)
        pre_paths = [item.get("path") for item in lease["target-pre-state"]]
        if pre_paths != lease["target-files"]:
            fail("SCHEMA_INVALID", f"lease {lease_id} pre-state does not match targets", "canonical", phase)
        acquired = parse_utc(lease["acquired-at"], f"lease {lease_id} acquired-at", phase)
        expires = parse_utc(lease["expires-at"], f"lease {lease_id} expires-at", phase)
        if lease["state"] == "active" and expires <= now:
            fail("LEASE_EXPIRED", f"active lease expired: {lease_id}", "lease", phase)
        if expires <= acquired:
            fail("SCHEMA_INVALID", f"lease {lease_id} expiry is not after acquisition", "canonical", phase)
        if lease["state"] == "active":
            if any(lease[field] is not None for field in (
                "post-head", "post-head-tree", "post-index-tree", "post-index-manifest-sha256",
                "post-filesystem-manifest-sha256", "post-worktree-status-sha256", "post-worktree-content-sha256",
                "target-post-state", "closed-at",
            )) or lease["evidence-ids"]:
                fail("SCHEMA_INVALID", f"active lease {lease_id} contains close state", "canonical", phase)
            for target in lease["target-files"]:
                if target in active_targets:
                    fail("LEASE_OVERLAP", f"active leases overlap on {target}", "lease", phase)
                active_targets[target] = lease_id
            if check_active_state and current_state is not None:
                if current_state["head"] != lease["base-head"] or current_state["index-tree"] != lease["base-index-tree"]:
                    fail("LEASE_BASE_DRIFT", f"active lease base drift: {lease_id}", "lease", phase)
                for expected in lease["target-pre-state"]:
                    if target_state(root, expected["path"], "pre-sha256") != expected:
                        fail("LEASE_TARGET_DRIFT", f"active lease target drift: {expected['path']}", "lease", phase)
        elif lease["state"] == "closed":
            if any(lease[field] is None for field in (
                "post-head", "post-head-tree", "post-index-tree", "post-index-manifest-sha256",
                "post-filesystem-manifest-sha256", "post-worktree-status-sha256", "post-worktree-content-sha256",
                "target-post-state", "closed-at",
            )) or not lease["evidence-ids"]:
                fail("SCHEMA_INVALID", f"closed lease {lease_id} is missing close evidence", "canonical", phase)
            post_paths = [item.get("path") for item in lease["target-post-state"]]
            if post_paths != lease["target-files"]:
                fail("SCHEMA_INVALID", f"lease {lease_id} post-state does not match targets", "canonical", phase)
    return ledger, {item["lease-id"]: item for item in leases}


def write_outputs_atomically(root: Path, outputs: dict[str, Any]) -> None:
    for relative in outputs:
        if (root / relative).exists():
            fail("LEDGER_ALREADY_FROZEN", f"authority output already exists: {relative}", "allowlist", "bootstrap")
    staged: list[tuple[Path, Path]] = []
    try:
        for relative, value in outputs.items():
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            fd, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
            temp_path = Path(temporary)
            with os.fdopen(fd, "wb") as handle:
                handle.write(canonical_bytes(value))
                handle.flush()
                os.fsync(handle.fileno())
            staged.append((temp_path, destination))
        for temporary, destination in staged:
            os.replace(temporary, destination)
    finally:
        for temporary, _ in staged:
            temporary.unlink(missing_ok=True)


def replace_outputs_atomically(root: Path, outputs: dict[str, Any], must_not_exist: set[str]) -> None:
    for relative in must_not_exist:
        if (root / relative).exists():
            fail("LEDGER_ALREADY_FROZEN", f"authority output already exists: {relative}", "allowlist", "freeze-ledger")
    staged: list[tuple[Path, Path]] = []
    try:
        for relative, value in outputs.items():
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            fd, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
            temp_path = Path(temporary)
            with os.fdopen(fd, "wb") as handle:
                handle.write(canonical_bytes(value))
                handle.flush()
                os.fsync(handle.fileno())
            staged.append((temp_path, destination))
        for temporary, destination in staged:
            os.replace(temporary, destination)
    finally:
        for temporary, _ in staged:
            temporary.unlink(missing_ok=True)


def bootstrap(root: Path, expected_head: str) -> dict[str, Any]:
    phase = "bootstrap"
    require_tracked_clean(root, BOOTSTRAP_PREREQUISITES, phase)
    current_head = git(root, "rev-parse", "HEAD").decode("ascii").strip()
    if current_head != expected_head:
        fail("PRODUCT_BASELINE_DRIFT", f"expected HEAD {expected_head}, found {current_head}", "scan", phase)
    if unknown := unknown_untracked_sources(root):
        fail("UNKNOWN_UNTRACKED_SOURCE", f"untracked source input: {unknown[0]}", "untracked", phase)
    result = scan(root)
    if result.counts != EXPECTED_COUNTS:
        fail("SCAN_LEDGER_MISMATCH", f"expected counts {EXPECTED_COUNTS}, found {result.counts}", "scan", phase)
    product_entries, product_hash = product_manifest(root)
    baseline_seed = {
        "head": current_head,
        "product": product_hash,
        "raw-scan": result.raw_scan_sha256,
        "unicode": result.unicode_file_sha256,
    }
    baseline_id = f"lambda64-todo-fixme-{sha256_bytes(canonical_bytes(baseline_seed))[:20]}"
    occurrences = {"schema-version": SCHEMA_VERSION, "baseline-id": baseline_id, "occurrences": result.occurrences}
    unicode_allowlist = {
        "schema-version": SCHEMA_VERSION,
        "path": UNICODE_PATH,
        "file-sha256": result.unicode_file_sha256,
        "record-count": len(result.unicode_records),
        "records": result.unicode_records,
    }
    snapshot = {
        "schema-version": SCHEMA_VERSION,
        "baseline-id": baseline_id,
        "phase": "bootstrap",
        "created-at": commit_timestamp(root, current_head),
        "frozen-at": None,
        "source-baseline-head": current_head,
        "source-baseline-tree": git(root, "rev-parse", "HEAD^{tree}").decode("ascii").strip(),
        "source-baseline-index-tree": git(root, "write-tree").decode("ascii").strip(),
        "baseline-product-input-manifest-sha256": product_hash,
        "baseline-raw-occurrence-scan-sha256": result.raw_scan_sha256,
        "baseline-unicode-input-sha256": result.unicode_file_sha256,
        "governance-freeze-head": None,
        "governance-freeze-tree": None,
        "governance-freeze-index-tree": None,
        "governance-freeze-manifest-sha256": None,
        "scanner-bootstrap-sha256": sha256_bytes((root / "scripts/check-todo-fixme.py").read_bytes()),
        "scanner-freeze-sha256": None,
        "occurrences-sha256": sha256_bytes(canonical_bytes(occurrences)),
        "work-items-identity-spec-sha256": None,
        "mapping-sha256": None,
        "unicode-allowlist-sha256": sha256_bytes(canonical_bytes(unicode_allowlist)),
        "counts": {
            **result.counts,
            "logical-total": None,
        },
    }
    outputs = {
        OUTPUT_PATHS["occurrences"]: occurrences,
        OUTPUT_PATHS["unicode"]: unicode_allowlist,
        OUTPUT_PATHS["snapshot"]: snapshot,
    }
    write_outputs_atomically(root, outputs)
    output_hash = sha256_bytes(canonical_bytes({path: sha256_bytes(canonical_bytes(value)) for path, value in outputs.items()}))
    return {
        "status": "ok",
        "phase": phase,
        "baseline-id": baseline_id,
        "source-baseline-head": current_head,
        "source-baseline-tree": snapshot["source-baseline-tree"],
        "baseline-product-input-manifest-sha256": product_hash,
        "baseline-raw-occurrence-scan-sha256": result.raw_scan_sha256,
        "baseline-unicode-input-sha256": result.unicode_file_sha256,
        "written-files": sorted(outputs),
        **result.counts,
        "output-sha256": output_hash,
    }


def freeze_ledger(root: Path, baseline_id_argument: str) -> dict[str, Any]:
    phase = "freeze-ledger"
    snapshot_path = root / OUTPUT_PATHS["snapshot"]
    if not snapshot_path.is_file():
        fail("MISSING_AUTHORITY_FILE", "baseline snapshot is missing", "prerequisite", phase)
    snapshot = validate_snapshot(read_json_canonical(snapshot_path, phase), phase)
    if snapshot["phase"] == "frozen" or snapshot["frozen-at"] is not None:
        fail("LEDGER_ALREADY_FROZEN", "baseline ledger is already frozen", "allowlist", phase)
    if snapshot["baseline-id"] != baseline_id_argument:
        fail("SNAPSHOT_HASH_MISMATCH", "--baseline-id differs from bootstrap snapshot", "allowlist", phase)
    immutable_null_fields = (
        "governance-freeze-head", "governance-freeze-tree", "governance-freeze-index-tree",
        "governance-freeze-manifest-sha256", "scanner-freeze-sha256",
        "work-items-identity-spec-sha256", "mapping-sha256",
    )
    if any(snapshot[field] is not None for field in immutable_null_fields) or snapshot["counts"]["logical-total"] is not None:
        fail("LEDGER_ALREADY_FROZEN", "bootstrap snapshot already contains freeze fields", "allowlist", phase)
    require_tracked_clean(root, FREEZE_PREREQUISITES, phase)
    result = scan(root)
    if result.unicode_file_sha256 != snapshot["baseline-unicode-input-sha256"]:
        fail("UNICODE_INPUT_DRIFT", "Unicode input changed after bootstrap", "allowlist", phase)
    if result.raw_scan_sha256 != snapshot["baseline-raw-occurrence-scan-sha256"]:
        fail("RAW_SCAN_DRIFT", "raw occurrence scan changed after bootstrap", "scan", phase)
    _, product_hash = product_manifest(root)
    if product_hash != snapshot["baseline-product-input-manifest-sha256"]:
        fail("PRODUCT_BASELINE_DRIFT", "product input changed after bootstrap", "scan", phase)
    require_freeze_change_scope(root, snapshot["source-baseline-index-tree"])
    occurrences = validate_occurrence_ledger(read_json_canonical(root / OUTPUT_PATHS["occurrences"], phase), phase)
    validate_with_schema(root, occurrences, "occurrence", "occurrence ledger", phase)
    if occurrences["baseline-id"] != snapshot["baseline-id"]:
        fail("SNAPSHOT_HASH_MISMATCH", "occurrence baseline ID differs from snapshot", "allowlist", phase)
    if sha256_bytes(canonical_bytes(occurrences)) != snapshot["occurrences-sha256"]:
        fail("IMMUTABLE_LEDGER_DRIFT", "occurrence ledger differs from bootstrap snapshot", "scan", phase)
    unicode_allowlist = read_json_canonical(root / OUTPUT_PATHS["unicode"], phase)
    validate_with_schema(root, unicode_allowlist, "unicode-allowlist", "Unicode allowlist", phase)
    verify_unicode(result, unicode_allowlist)
    if sha256_bytes(canonical_bytes(unicode_allowlist)) != snapshot["unicode-allowlist-sha256"]:
        fail("SNAPSHOT_HASH_MISMATCH", "Unicode allowlist hash differs from snapshot", "allowlist", phase)
    work_ledger, work_items = validate_work_items(
        root,
        read_json_canonical(root / GOVERNANCE_ROOT / "work-items.json", phase),
        snapshot["baseline-id"],
        phase,
    )
    occurrence_by_id = {item["id"]: item for item in occurrences["occurrences"]}
    mapping = validate_mapping(
        root,
        read_json_canonical(root / GOVERNANCE_ROOT / "occurrence-work-items.json", phase),
        snapshot["baseline-id"],
        occurrence_by_id,
        work_items,
        phase,
    )
    actionable_count = sum(item["kind"] != "data-false-positive" for item in occurrence_by_id.values())
    if actionable_count != 455:
        fail("SCAN_LEDGER_MISMATCH", f"expected 455 actionable occurrences, found {actionable_count}", "scan", phase)
    work_items_hash = immutable_work_item_hash(root, work_ledger, work_items, phase)
    mapping_hash = sha256_bytes(canonical_bytes(mapping))
    freeze_head = git(root, "rev-parse", "HEAD").decode("ascii").strip()
    freeze_tree = git(root, "rev-parse", "HEAD^{tree}").decode("ascii").strip()
    freeze_index_tree = git(root, "write-tree").decode("ascii").strip()
    _, freeze_manifest_hash = index_governance_manifest(root, freeze_index_tree)
    frozen_at = commit_timestamp(root, freeze_head)
    statuses = {
        "schema-version": SCHEMA_VERSION,
        "baseline-id": snapshot["baseline-id"],
        "statuses": [
            {
                "work-item-id": work_item_id,
                "status": "specified",
                "history": [
                    {
                        "from": None,
                        "to": "specified",
                        "at": frozen_at,
                        "actor": "freeze-ledger",
                        "evidence-ids": [],
                    }
                ],
                "evidence-ids": [],
                "lease-ids": [],
                "updated-at": frozen_at,
                "updated-by": "freeze-ledger",
            }
            for work_item_id in sorted(work_items)
        ],
    }
    validate_status_ledger(root, statuses, snapshot["baseline-id"], set(work_items), phase)
    frozen_snapshot = dict(snapshot)
    frozen_snapshot.update(
        {
            "phase": "frozen",
            "frozen-at": frozen_at,
            "governance-freeze-head": freeze_head,
            "governance-freeze-tree": freeze_tree,
            "governance-freeze-index-tree": freeze_index_tree,
            "governance-freeze-manifest-sha256": freeze_manifest_hash,
            "scanner-freeze-sha256": sha256_bytes((root / "scripts/check-todo-fixme.py").read_bytes()),
            "work-items-identity-spec-sha256": work_items_hash,
            "mapping-sha256": mapping_hash,
            "counts": {**snapshot["counts"], "logical-total": len(work_items)},
        }
    )
    validate_with_schema(root, frozen_snapshot, "snapshot", "frozen snapshot", phase)
    status_relative = f"{GOVERNANCE_ROOT}/work-item-status.json"
    replace_outputs_atomically(
        root,
        {OUTPUT_PATHS["snapshot"]: frozen_snapshot, status_relative: statuses},
        {status_relative},
    )
    return {
        "status": "ok",
        "phase": "frozen",
        "baseline-id": snapshot["baseline-id"],
        "source-baseline-head": snapshot["source-baseline-head"],
        "governance-freeze-head": freeze_head,
        "governance-freeze-tree": freeze_tree,
        "governance-freeze-index-tree": freeze_index_tree,
        "baseline-product-input-manifest-sha256": product_hash,
        "logical-total": len(work_items),
        "actionable-occurrences": actionable_count,
        "work-items-identity-spec-sha256": work_items_hash,
        "mapping-sha256": mapping_hash,
        "work-item-status-sha256": sha256_bytes(canonical_bytes(statuses)),
        "baseline-snapshot-sha256": sha256_bytes(canonical_bytes(frozen_snapshot)),
    }


def authority_hashes(root: Path) -> dict[str, str]:
    paths = [root / relative for relative in ("Makefile", "scripts/check-todo-fixme.py", "Lambda64/tests/host/test-todo-fixme-ledger.sh")]
    governance = root / GOVERNANCE_ROOT
    if governance.is_dir():
        paths.extend(path for path in governance.rglob("*") if path.is_file() and not path.is_symlink())
    return {
        path.relative_to(root).as_posix(): sha256_bytes(path.read_bytes())
        for path in sorted(set(paths), key=lambda item: item.relative_to(root).as_posix().encode("utf-8"))
        if path.is_file()
    }


def verify_unicode(result: ScanResult, allowlist: dict[str, Any]) -> None:
    expected_keys = {"schema-version", "path", "file-sha256", "record-count", "records"}
    if set(allowlist) != expected_keys or allowlist.get("schema-version") != SCHEMA_VERSION:
        fail("SCHEMA_INVALID", "Unicode allowlist shape is invalid", "canonical", "verify")
    if allowlist.get("path") != UNICODE_PATH or allowlist.get("record-count") != 29:
        fail("UNICODE_ALLOWLIST_MISMATCH", "Unicode allowlist metadata is invalid", "allowlist", "verify")
    if allowlist.get("file-sha256") != result.unicode_file_sha256 or allowlist.get("records") != result.unicode_records:
        fail("UNICODE_ALLOWLIST_MISMATCH", "Unicode input does not exactly match the frozen records", "allowlist", "verify")


def verify(root: Path) -> dict[str, Any]:
    phase = "verify"
    require_tracked_clean(root, VERIFY_PREREQUISITES, phase)
    before = authority_hashes(root)
    tracked = tracked_paths(root)
    required_authority = tuple(OUTPUT_PATHS.values()) + (
        f"{GOVERNANCE_ROOT}/work-items.json",
        f"{GOVERNANCE_ROOT}/occurrence-work-items.json",
        f"{GOVERNANCE_ROOT}/work-item-status.json",
        f"{GOVERNANCE_ROOT}/ownership-leases.json",
        f"{GOVERNANCE_ROOT}/schema/work-item.schema.json",
        f"{GOVERNANCE_ROOT}/schema/work-item-status.schema.json",
        f"{GOVERNANCE_ROOT}/schema/mapping.schema.json",
        f"{GOVERNANCE_ROOT}/schema/lease.schema.json",
    )
    for relative in required_authority:
        if not (root / relative).is_file():
            fail("MISSING_AUTHORITY_FILE", f"missing authority file: {relative}", "prerequisite", phase)
        if relative not in tracked:
            fail("UNTRACKED_PREREQUISITE", f"authority file is not tracked: {relative}", "prerequisite", phase)
    for relative in before:
        if relative.startswith(f"{GOVERNANCE_ROOT}/") and relative not in tracked:
            fail("UNTRACKED_PREREQUISITE", f"governance authority is not tracked: {relative}", "prerequisite", phase)
    for path in (root / GOVERNANCE_ROOT).rglob("*.json"):
        if f"/{GOVERNANCE_ROOT}/schema/" in path.as_posix():
            read_json(path, phase)
        else:
            read_json_canonical(path, phase)
    occurrences = validate_occurrence_ledger(
        read_json_canonical(root / OUTPUT_PATHS["occurrences"], phase), phase
    )
    validate_with_schema(root, occurrences, "occurrence", "occurrence ledger", phase)
    allowlist = read_json_canonical(root / OUTPUT_PATHS["unicode"], phase)
    validate_with_schema(root, allowlist, "unicode-allowlist", "Unicode allowlist", phase)
    snapshot = validate_snapshot(read_json_canonical(root / OUTPUT_PATHS["snapshot"], phase), phase)
    validate_with_schema(root, snapshot, "snapshot", "baseline snapshot", phase)
    if snapshot.get("phase") != "frozen":
        fail("BASELINE_PHASE_INVALID", "baseline snapshot is not frozen", "canonical", phase)
    if unknown := unknown_untracked_sources(root):
        fail("UNKNOWN_UNTRACKED_SOURCE", f"untracked source input: {unknown[0]}", "untracked", phase)
    result = scan(root)
    verify_unicode(result, allowlist)
    baseline_id = snapshot.get("baseline-id")
    if occurrences.get("baseline-id") != baseline_id:
        fail("SNAPSHOT_HASH_MISMATCH", "occurrence ledger baseline ID differs from snapshot", "allowlist", phase)
    occurrence_hash = sha256_bytes(canonical_bytes(occurrences))
    if snapshot.get("occurrences-sha256") != occurrence_hash:
        fail("IMMUTABLE_LEDGER_DRIFT", "occurrence ledger hash differs from frozen snapshot", "scan", phase)
    baseline_id = snapshot["baseline-id"]
    work_ledger, work_items = validate_work_items(
        root,
        read_json_canonical(root / GOVERNANCE_ROOT / "work-items.json", phase),
        baseline_id,
        phase,
    )
    work_items_hash = immutable_work_item_hash(root, work_ledger, work_items, phase)
    if work_items_hash != snapshot.get("work-items-identity-spec-sha256"):
        fail("IMMUTABLE_LEDGER_DRIFT", "work-item identity/spec hash differs from frozen snapshot", "scan", phase)
    frozen_by_id = {item["id"]: item for item in occurrences.get("occurrences", [])}
    mapping = validate_mapping(
        root,
        read_json_canonical(root / GOVERNANCE_ROOT / "occurrence-work-items.json", phase),
        baseline_id,
        frozen_by_id,
        work_items,
        phase,
    )
    if sha256_bytes(canonical_bytes(mapping)) != snapshot.get("mapping-sha256"):
        fail("IMMUTABLE_LEDGER_DRIFT", "mapping hash differs from frozen snapshot", "scan", phase)
    statuses = validate_status_ledger(
        root,
        read_json_canonical(root / GOVERNANCE_ROOT / "work-item-status.json", phase),
        baseline_id,
        set(work_items),
        phase,
    )
    leases, lease_by_id = validate_leases(
        root,
        read_json_canonical(root / GOVERNANCE_ROOT / "ownership-leases.json", phase),
        set(work_items),
        phase,
        check_active_state=True,
    )
    for status_item in statuses["statuses"]:
        referenced = status_item["lease-ids"]
        if any(lease_id not in lease_by_id for lease_id in referenced):
            fail("STATUS_IDENTITY_MISMATCH", f"status references unknown lease: {status_item['work-item-id']}", "scan", phase)
        if status_item["status"] == "implemented" and not any(lease_by_id[lease_id]["state"] == "active" for lease_id in referenced):
            fail("LEASE_EXPIRED", f"implemented work item lacks an active lease: {status_item['work-item-id']}", "lease", phase)
        if status_item["status"] == "verified" and any(lease_by_id[lease_id]["state"] != "closed" for lease_id in referenced):
            fail("INVALID_STATUS_TRANSITION", f"verified work item has a non-closed lease: {status_item['work-item-id']}", "scan", phase)
    if snapshot["counts"].get("logical-total") != len(work_items):
        fail("SNAPSHOT_HASH_MISMATCH", "logical total differs from frozen work-item ledger", "allowlist", phase)
    freeze_head = snapshot.get("governance-freeze-head")
    freeze_tree = snapshot.get("governance-freeze-tree")
    freeze_index_tree = snapshot.get("governance-freeze-index-tree")
    if not all(isinstance(value, str) and value for value in (freeze_head, freeze_tree, freeze_index_tree)):
        fail("SNAPSHOT_HASH_MISMATCH", "governance freeze identity is incomplete", "allowlist", phase)
    actual_freeze_tree = git(root, "rev-parse", f"{freeze_head}^{{tree}}", check=False).decode("ascii").strip()
    if actual_freeze_tree != freeze_tree:
        fail("SNAPSHOT_HASH_MISMATCH", "governance freeze HEAD/tree cannot be reproduced", "allowlist", phase)
    freeze_entries, freeze_manifest_hash = index_governance_manifest(root, freeze_index_tree)
    if freeze_manifest_hash != snapshot.get("governance-freeze-manifest-sha256"):
        fail("SNAPSHOT_HASH_MISMATCH", "governance freeze manifest cannot be reproduced", "allowlist", phase)
    scanner_entries = [item for item in freeze_entries if item["path"] == "scripts/check-todo-fixme.py"]
    if len(scanner_entries) != 1 or scanner_entries[0]["sha256"] != snapshot.get("scanner-freeze-sha256"):
        fail("SNAPSHOT_HASH_MISMATCH", "freeze scanner hash cannot be reproduced", "allowlist", phase)
    current_by_id = {item["id"]: item for item in result.occurrences}
    added = sorted(set(current_by_id) - set(frozen_by_id))
    removed = sorted(set(frozen_by_id) - set(current_by_id))
    changed = sorted(
        occurrence_id
        for occurrence_id in set(current_by_id) & set(frozen_by_id)
        if current_by_id[occurrence_id] != frozen_by_id[occurrence_id]
    )
    if added or changed:
        fail("SCAN_LEDGER_MISMATCH", "current scan contains unknown or mutated occurrence", "scan", phase)
    status_by_id = {item["work-item-id"]: item for item in statuses["statuses"]}
    links_by_occurrence: dict[str, set[str]] = {}
    for link in mapping["links"]:
        links_by_occurrence.setdefault(link["occurrence-id"], set()).add(link["work-item-id"])
    for occurrence_id in removed:
        linked = links_by_occurrence.get(occurrence_id, set())
        if not linked or any(status_by_id[work_item_id]["status"] != "verified" for work_item_id in linked):
            fail("UNVERIFIED_REMOVAL", f"occurrence removed before all mapped work items were verified: {occurrence_id}", "scan", phase)
    _, product_hash = product_manifest(root)
    counts = snapshot.get("counts", {})
    logical_total = counts.get("logical-total") or 0
    verified_logical = sum(item["status"] == "verified" for item in statuses["statuses"])
    after = authority_hashes(root)
    if after != before:
        fail("AUTHORITY_MUTATED_DURING_VERIFY", "authority files changed during read-only verification", "scan", phase)
    authority_set_hash = sha256_bytes(canonical_bytes(before))
    return {
        "status": "ok",
        "phase": phase,
        "baseline-id": baseline_id,
        "source-baseline-head": snapshot.get("source-baseline-head"),
        "governance-freeze-head": snapshot.get("governance-freeze-head"),
        "current-product-input-manifest-sha256": product_hash,
        **result.counts,
        "actionable-occurrences": result.counts["source"] + result.counts["documentation"],
        "logical-total": logical_total,
        "verified-logical": verified_logical,
        "unknown-untracked": 0,
        "authority-set-sha256": authority_set_hash,
    }


def lease_context(root: Path, phase: str) -> tuple[str, dict[str, dict[str, Any]], dict[str, Any]]:
    authority = root / GOVERNANCE_ROOT
    snapshot = validate_snapshot(read_json_canonical(authority / "baseline-snapshot.json", phase), phase)
    validate_with_schema(root, snapshot, "snapshot", "baseline snapshot", phase)
    if snapshot["phase"] != "frozen":
        fail("BASELINE_PHASE_INVALID", "lease operations require a frozen baseline", "canonical", phase)
    baseline_id = snapshot["baseline-id"]
    work_ledger, work_items = validate_work_items(
        root, read_json_canonical(authority / "work-items.json", phase), baseline_id, phase
    )
    if immutable_work_item_hash(root, work_ledger, work_items, phase) != snapshot["work-items-identity-spec-sha256"]:
        fail("IMMUTABLE_LEDGER_DRIFT", "work-item identity/spec hash differs from frozen snapshot", "scan", phase)
    statuses = validate_status_ledger(
        root,
        read_json_canonical(authority / "work-item-status.json", phase),
        baseline_id,
        set(work_items),
        phase,
    )
    return baseline_id, work_items, statuses


def lease_acquire(
    root: Path,
    lease_id: str,
    holder: str,
    work_item_ids: list[str],
    target_files: list[str],
    expires_at: str,
) -> dict[str, Any]:
    phase = "lease-acquire"
    require_tracked_clean(root, VERIFY_PREREQUISITES, phase)
    lease_relative = f"{GOVERNANCE_ROOT}/ownership-leases.json"
    if lease_relative not in tracked_paths(root) or not (root / lease_relative).is_file():
        fail("MISSING_AUTHORITY_FILE", f"missing tracked authority file: {lease_relative}", "prerequisite", phase)
    baseline_id, work_items, statuses = lease_context(root, phase)
    normalized_work_items = sorted(set(work_item_ids))
    normalized_targets = sorted(set(target_files))
    if not lease_id.strip() or not holder.strip() or not normalized_work_items or not normalized_targets:
        fail("SCHEMA_INVALID", "lease identity, holder, work items, and targets must be non-empty", "canonical", phase)
    if len(normalized_work_items) != len(work_item_ids) or len(normalized_targets) != len(target_files):
        fail("SCHEMA_INVALID", "lease work items and targets must not contain duplicates", "canonical", phase)
    if not set(normalized_work_items) <= set(work_items):
        fail("STATUS_IDENTITY_MISMATCH", "lease references an unknown work item", "scan", phase)
    status_by_id = {item["work-item-id"]: item for item in statuses["statuses"]}
    if any(status_by_id[item_id]["status"] != "test-locked" for item_id in normalized_work_items):
        fail("INVALID_STATUS_TRANSITION", "lease acquisition requires test-locked work items", "scan", phase)
    for target in normalized_targets:
        parts = Path(target).parts
        if (
            not target.startswith("Lambda64/")
            or target.startswith("Lambda64/home/")
            or ".." in parts
            or any(character in target for character in "*?[]")
        ):
            fail("SCHEMA_INVALID", f"invalid exact lease target: {target}", "canonical", phase)
    ledger, existing = validate_leases(
        root,
        read_json_canonical(root / lease_relative, phase),
        set(work_items),
        phase,
        check_active_state=True,
    )
    if lease_id in existing:
        fail("LEASE_OVERLAP", f"lease ID already exists: {lease_id}", "lease", phase)
    occupied = {
        target
        for lease in ledger["leases"]
        if lease["state"] == "active"
        for target in lease["target-files"]
    }
    overlap = sorted(occupied & set(normalized_targets))
    if overlap:
        fail("LEASE_OVERLAP", f"active lease target overlap: {overlap[0]}", "lease", phase)
    acquired = utc_now()
    expiry = parse_utc(expires_at, "--expires-at", phase)
    if expiry <= acquired:
        fail("LEASE_EXPIRED", "new lease expiry must be in the future", "lease", phase)
    base = lease_repository_state(root)
    lease = {
        "lease-id": lease_id,
        "holder": holder,
        "work-item-ids": normalized_work_items,
        "target-files": normalized_targets,
        "state": "active",
        "acquired-at": format_utc(acquired),
        "expires-at": format_utc(expiry),
        "base-head": base["head"],
        "base-head-tree": base["head-tree"],
        "base-index-tree": base["index-tree"],
        "base-index-manifest-sha256": base["index-manifest-sha256"],
        "base-filesystem-manifest-sha256": base["filesystem-manifest-sha256"],
        "base-worktree-status-sha256": base["worktree-status-sha256"],
        "base-worktree-content-sha256": base["worktree-content-sha256"],
        "target-pre-state": [target_state(root, target, "pre-sha256") for target in normalized_targets],
        "post-head": None,
        "post-head-tree": None,
        "post-index-tree": None,
        "post-index-manifest-sha256": None,
        "post-filesystem-manifest-sha256": None,
        "post-worktree-status-sha256": None,
        "post-worktree-content-sha256": None,
        "target-post-state": None,
        "evidence-ids": [],
        "closed-at": None,
    }
    updated = {**ledger, "leases": sorted([*ledger["leases"], lease], key=lambda item: item["lease-id"])}
    validate_leases(root, updated, set(work_items), phase, check_active_state=False)
    replace_outputs_atomically(root, {lease_relative: updated}, set())
    return {
        "status": "ok",
        "phase": phase,
        "baseline-id": baseline_id,
        "lease": lease,
        "ownership-leases-sha256": sha256_bytes(canonical_bytes(updated)),
    }


def lease_close(root: Path, lease_id: str, evidence_ids: list[str]) -> dict[str, Any]:
    phase = "lease-close"
    require_tracked_clean(root, VERIFY_PREREQUISITES, phase)
    lease_relative = f"{GOVERNANCE_ROOT}/ownership-leases.json"
    baseline_id, work_items, _ = lease_context(root, phase)
    ledger, leases = validate_leases(
        root,
        read_json_canonical(root / lease_relative, phase),
        set(work_items),
        phase,
        check_active_state=False,
    )
    if lease_id not in leases or leases[lease_id]["state"] != "active":
        fail("LEASE_BASE_DRIFT", f"lease is not active: {lease_id}", "lease", phase)
    normalized_evidence = sorted(set(evidence_ids))
    if not normalized_evidence or any(not item.strip() for item in normalized_evidence):
        fail("SCHEMA_INVALID", "lease close requires non-empty evidence IDs", "canonical", phase)
    lease = leases[lease_id]
    current = lease_repository_state(root)
    if current["head"] != lease["base-head"] or current["index-tree"] != lease["base-index-tree"]:
        fail("LEASE_BASE_DRIFT", f"lease base changed before close: {lease_id}", "lease", phase)
    closed = {
        **lease,
        "state": "closed",
        "post-head": current["head"],
        "post-head-tree": current["head-tree"],
        "post-index-tree": current["index-tree"],
        "post-index-manifest-sha256": current["index-manifest-sha256"],
        "post-filesystem-manifest-sha256": current["filesystem-manifest-sha256"],
        "post-worktree-status-sha256": current["worktree-status-sha256"],
        "post-worktree-content-sha256": current["worktree-content-sha256"],
        "target-post-state": [target_state(root, target, "post-sha256") for target in lease["target-files"]],
        "evidence-ids": normalized_evidence,
        "closed-at": format_utc(utc_now()),
    }
    updated = {
        **ledger,
        "leases": [closed if item["lease-id"] == lease_id else item for item in ledger["leases"]],
    }
    validate_leases(root, updated, set(work_items), phase, check_active_state=False)
    replace_outputs_atomically(root, {lease_relative: updated}, set())
    return {
        "status": "ok",
        "phase": phase,
        "baseline-id": baseline_id,
        "lease": closed,
        "ownership-leases-sha256": sha256_bytes(canonical_bytes(updated)),
    }


def status_transition(
    root: Path,
    work_item_id: str,
    from_status: str,
    to_status: str,
    evidence_ids: list[str],
    actor: str,
) -> dict[str, Any]:
    phase = "status-transition"
    require_tracked_clean(root, VERIFY_PREREQUISITES, phase)
    authority = root / GOVERNANCE_ROOT
    required = (
        "baseline-snapshot.json",
        "work-items.json",
        "occurrence-work-items.json",
        "work-item-status.json",
    )
    tracked = tracked_paths(root)
    for name in required:
        relative = f"{GOVERNANCE_ROOT}/{name}"
        if relative not in tracked or not (authority / name).is_file():
            fail("MISSING_AUTHORITY_FILE", f"missing tracked authority file: {relative}", "prerequisite", phase)
    if not actor.strip() or any(not evidence_id.strip() for evidence_id in evidence_ids):
        fail("INVALID_STATUS_TRANSITION", "actor and evidence IDs must be non-empty", "scan", phase)
    normalized_evidence = sorted(set(evidence_ids))
    if not normalized_evidence:
        fail("INVALID_STATUS_TRANSITION", "status transition requires at least one evidence ID", "scan", phase)
    snapshot_path = authority / "baseline-snapshot.json"
    occurrences_path = authority / "occurrences.json"
    work_items_path = authority / "work-items.json"
    mapping_path = authority / "occurrence-work-items.json"
    status_path = authority / "work-item-status.json"
    immutable_before = {
        "snapshot": sha256_bytes(snapshot_path.read_bytes()),
        "occurrences": sha256_bytes(occurrences_path.read_bytes()),
        "work-items": sha256_bytes(work_items_path.read_bytes()),
        "mapping": sha256_bytes(mapping_path.read_bytes()),
    }
    snapshot = validate_snapshot(read_json_canonical(snapshot_path, phase), phase)
    validate_with_schema(root, snapshot, "snapshot", "baseline snapshot", phase)
    if snapshot["phase"] != "frozen":
        fail("BASELINE_PHASE_INVALID", "status transitions require a frozen baseline", "canonical", phase)
    baseline_id = snapshot["baseline-id"]
    work_ledger, work_items = validate_work_items(
        root, read_json_canonical(work_items_path, phase), baseline_id, phase
    )
    if immutable_work_item_hash(root, work_ledger, work_items, phase) != snapshot["work-items-identity-spec-sha256"]:
        fail("IMMUTABLE_LEDGER_DRIFT", "work-item identity/spec hash differs from frozen snapshot", "scan", phase)
    occurrences = validate_occurrence_ledger(
        read_json_canonical(occurrences_path, phase), phase
    )
    validate_with_schema(root, occurrences, "occurrence", "occurrence ledger", phase)
    if occurrences["baseline-id"] != baseline_id or sha256_bytes(canonical_bytes(occurrences)) != snapshot["occurrences-sha256"]:
        fail("IMMUTABLE_LEDGER_DRIFT", "occurrence ledger differs from frozen snapshot", "scan", phase)
    occurrence_by_id = {item["id"]: item for item in occurrences["occurrences"]}
    mapping = validate_mapping(
        root,
        read_json_canonical(mapping_path, phase),
        baseline_id,
        occurrence_by_id,
        work_items,
        phase,
    )
    if sha256_bytes(canonical_bytes(mapping)) != snapshot["mapping-sha256"]:
        fail("IMMUTABLE_LEDGER_DRIFT", "mapping hash differs from frozen snapshot", "scan", phase)
    ledger = validate_status_ledger(
        root,
        read_json_canonical(status_path, phase),
        baseline_id,
        set(work_items),
        phase,
    )
    lease_path = authority / "ownership-leases.json"
    lease_ledger, lease_by_id = validate_leases(
        root,
        read_json_canonical(lease_path, phase),
        set(work_items),
        phase,
        check_active_state=True,
    )
    by_id = {item["work-item-id"]: item for item in ledger["statuses"]}
    if work_item_id not in by_id:
        fail("STATUS_IDENTITY_MISMATCH", f"unknown work item: {work_item_id}", "scan", phase)
    current = by_id[work_item_id]
    if current["status"] != from_status:
        fail(
            "INVALID_STATUS_TRANSITION",
            f"explicit --from {from_status} differs from current status {current['status']}",
            "scan",
            phase,
        )
    legal_next = {
        "inventoried": "specified",
        "specified": "test-locked",
        "test-locked": "implemented",
        "implemented": "verified",
    }
    if legal_next.get(from_status) != to_status:
        fail("INVALID_STATUS_TRANSITION", f"illegal transition {from_status} -> {to_status}", "scan", phase)
    transition_lease_ids = list(current["lease-ids"])
    if to_status == "implemented":
        transition_lease_ids = sorted(
            lease["lease-id"]
            for lease in lease_ledger["leases"]
            if lease["state"] == "active" and work_item_id in lease["work-item-ids"]
        )
        if not transition_lease_ids:
            fail("INVALID_STATUS_TRANSITION", "transition to implemented requires an active lease", "scan", phase)
    if to_status == "verified":
        if not transition_lease_ids or any(
            lease_id not in lease_by_id or lease_by_id[lease_id]["state"] != "closed"
            for lease_id in transition_lease_ids
        ):
            fail("INVALID_STATUS_TRANSITION", "transition to verified requires closed implementation leases", "scan", phase)
    if to_status == "verified" and actor == current["updated-by"]:
        fail("INVALID_STATUS_TRANSITION", "verified transition requires an independent actor", "scan", phase)
    transitioned_at = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    updated = {
        **current,
        "status": to_status,
        "history": [
            *current["history"],
            {
                "from": from_status,
                "to": to_status,
                "at": transitioned_at,
                "actor": actor,
                "evidence-ids": normalized_evidence,
            },
        ],
        "evidence-ids": sorted(set(current["evidence-ids"]) | set(normalized_evidence)),
        "lease-ids": transition_lease_ids,
        "updated-at": transitioned_at,
        "updated-by": actor,
    }
    transitioned = {
        **ledger,
        "statuses": [updated if item["work-item-id"] == work_item_id else item for item in ledger["statuses"]],
    }
    validate_status_ledger(root, transitioned, baseline_id, set(work_items), phase)
    immutable_after_validation = {
        "snapshot": sha256_bytes(snapshot_path.read_bytes()),
        "occurrences": sha256_bytes(occurrences_path.read_bytes()),
        "work-items": sha256_bytes(work_items_path.read_bytes()),
        "mapping": sha256_bytes(mapping_path.read_bytes()),
    }
    if immutable_after_validation != immutable_before:
        fail("AUTHORITY_MUTATED_DURING_VERIFY", "immutable authority changed during transition validation", "scan", phase)
    replace_outputs_atomically(root, {f"{GOVERNANCE_ROOT}/work-item-status.json": transitioned}, set())
    return {
        "status": "ok",
        "phase": phase,
        "baseline-id": baseline_id,
        "work-item": updated,
        "work-item-status-sha256": sha256_bytes(canonical_bytes(transitioned)),
    }


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        fail("USAGE", message, "usage", "usage")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = JsonArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--verify", action="store_true", help="strictly read-only verification")
    group.add_argument(
        "command",
        nargs="?",
        choices=("bootstrap", "freeze-ledger", "status-transition", "lease-acquire", "lease-close"),
    )
    parser.add_argument("--expected-head", help="required source HEAD for bootstrap")
    parser.add_argument("--baseline-id", help="required frozen identity for freeze-ledger")
    parser.add_argument("--work-item-id", action="append", default=[], help="work item ID; may be repeated")
    parser.add_argument("--from", dest="from_status", choices=("inventoried", "specified", "test-locked", "implemented", "verified"))
    parser.add_argument("--to", dest="to_status", choices=("inventoried", "specified", "test-locked", "implemented", "verified"))
    parser.add_argument("--evidence-id", action="append", default=[], help="evidence ID; may be repeated")
    parser.add_argument("--actor", help="audited transition actor")
    parser.add_argument("--lease-id", help="lease identity")
    parser.add_argument("--holder", help="lease holder")
    parser.add_argument("--target-file", action="append", default=[], help="exact lease target; may be repeated")
    parser.add_argument("--expires-at", help="lease expiry as RFC3339 UTC")
    args = parser.parse_args(argv)
    if args.command == "bootstrap" and not args.expected_head:
        parser.error("bootstrap requires --expected-head")
    if args.command == "freeze-ledger" and not args.baseline_id:
        parser.error("freeze-ledger requires --baseline-id")
    if args.command != "bootstrap" and args.expected_head:
        parser.error("--expected-head is only valid with bootstrap")
    if args.command != "freeze-ledger" and args.baseline_id:
        parser.error("--baseline-id is only valid with freeze-ledger")
    transition_values = (args.from_status, args.to_status, args.actor)
    if args.command == "status-transition" and (
        not all(transition_values) or len(args.work_item_id) != 1 or not args.evidence_id
    ):
        parser.error("status-transition requires --work-item-id, --from, --to, --evidence-id, and --actor")
    if args.command != "status-transition" and any(transition_values):
        parser.error("status transition options are only valid with status-transition")
    if args.command == "lease-acquire" and (
        not args.lease_id or not args.holder or not args.work_item_id or not args.target_file or not args.expires_at
    ):
        parser.error("lease-acquire requires --lease-id, --holder, --work-item-id, --target-file, and --expires-at")
    if args.command == "lease-close" and (not args.lease_id or not args.evidence_id):
        parser.error("lease-close requires --lease-id and --evidence-id")
    if args.command not in {"status-transition", "lease-acquire"} and args.work_item_id:
        parser.error("--work-item-id is only valid with status-transition or lease-acquire")
    if args.command not in {"status-transition", "lease-close"} and args.evidence_id:
        parser.error("--evidence-id is only valid with status-transition or lease-close")
    if args.command != "lease-acquire" and (args.holder or args.target_file or args.expires_at):
        parser.error("lease acquisition options are only valid with lease-acquire")
    if args.command not in {"lease-acquire", "lease-close"} and args.lease_id:
        parser.error("--lease-id is only valid with lease-acquire or lease-close")
    return args


def main(argv: list[str]) -> int:
    try:
        args = parse_args(argv)
        root = repository_root()
        if args.verify:
            result = verify(root)
        elif args.command == "bootstrap":
            result = bootstrap(root, args.expected_head)
        elif args.command == "freeze-ledger":
            result = freeze_ledger(root, args.baseline_id)
        else:
            if args.command == "status-transition":
                result = status_transition(
                    root,
                    args.work_item_id[0],
                    args.from_status,
                    args.to_status,
                    args.evidence_id,
                    args.actor,
                )
            elif args.command == "lease-acquire":
                result = lease_acquire(
                    root,
                    args.lease_id,
                    args.holder,
                    args.work_item_id,
                    args.target_file,
                    args.expires_at,
                )
            else:
                result = lease_close(root, args.lease_id, args.evidence_id)
        print(compact_json(result))
        return 0
    except ScannerError as exc:
        print(
            compact_json(
                {"status": "error", "phase": exc.phase, "error-code": exc.code, "message": exc.message}
            ),
            file=sys.stderr,
        )
        return exc.exit_code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
