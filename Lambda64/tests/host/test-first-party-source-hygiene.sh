#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)

python3 - "$repo_root" <<'PY'
from pathlib import Path
import re
import subprocess
import sys

repo_root = Path(sys.argv[1])
project_root = repo_root.parent
lambda64_tracked = subprocess.check_output(
    ["git", "-C", str(repo_root), "ls-files", "-z", "--", "."],
    text=True,
)
root_tracked = subprocess.check_output(
    [
        "git",
        "-C",
        str(project_root),
        "ls-files",
        "-z",
        "--",
        "build-cold-image.lisp",
        "run-file-server.lisp",
    ],
    text=True,
)
extensions = {".lisp", ".lsp", ".asd", ".sh"}
issues = []
filename = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*$")

paths = [(repo_root / relative, f"Lambda64/{relative}")
         for relative in filter(None, lambda64_tracked.split("\0"))]
paths.extend((project_root / relative, relative)
             for relative in filter(None, root_tracked.split("\0")))

for path, display_path in paths:
    if path.suffix.lower() not in extensions:
        continue
    data = path.read_bytes()
    try:
        data.decode("utf-8")
    except UnicodeDecodeError as error:
        issues.append(f"{display_path}:1: not valid UTF-8 ({error})")
    if b"\r" in data:
        issues.append(f"{display_path}:1: CR byte found; source files use LF line endings")
    if data and not data.endswith(b"\n"):
        issues.append(f"{display_path}:1: missing final newline")
    if not filename.fullmatch(path.stem):
        issues.append(f"{display_path}:1: filename must use lowercase kebab-case")

if issues:
    print("First-party source hygiene failed:", file=sys.stderr)
    print("\n".join(f"- {issue}" for issue in issues), file=sys.stderr)
    raise SystemExit(1)

print("first-party source hygiene passed")
PY
