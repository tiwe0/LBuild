#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
target=${1:-"$repo_root/compiler/backend/arm64/target.lisp"}

python3 - "$target" <<'PY'
import pathlib
import re
import sys

target = pathlib.Path(sys.argv[1])
source = target.read_text(encoding="utf-8")
match = re.search(
    r"\(defmethod ra:valid-physical-registers-for-kind "
    r"\(\(kind \(eql :value\)\) \(architecture c:arm64-target\)\)"
    r".*?'\((?P<body>[^)]*)\)\)",
    source,
    re.DOTALL,
)
if match is None:
    raise SystemExit("ARM64 :value register method was not found")

registers = re.findall(r":x\d+", match.group("body"))
expected = [":x0", ":x1", ":x2", ":x3", ":x4", ":x6", ":x7"]
if registers != expected:
    raise SystemExit(
        "unsafe ARM64 :value register set: "
        f"expected {expected}, found {registers}; "
        "x13/x14 must stay reserved until callee-saved CFG merge handling is fixed"
    )

print("ARM64 value-register contract passed")
PY
