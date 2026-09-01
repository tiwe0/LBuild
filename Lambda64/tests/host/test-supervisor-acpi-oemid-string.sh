#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${ACPI_SOURCE:-"$repo_root/supervisor/acpi.lisp"}
python3 - "$source_file" "${ACPI_OEMID_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(encoding='utf-8')
start=s.index('(defun acpi-parse-rsdp'); end=s.index('\n\n(defun ensure-acpi-table-accessible',start); f=s[start:end]
if sys.argv[2]: f=f.replace('(mezzano.runtime::make-wired-string 6)', '(sys.int::make-simple-vector 6 :wired)')
required=['(mezzano.runtime::make-wired-string 6)','(code-char (physical-memref-unsigned-byte-8','(char oemid i)']
for t in required:
 if t not in f: raise SystemExit('ACPI OEMID string contract missing: '+t)
if 'make-simple-vector' in f: raise SystemExit('OEMID is still represented as a byte vector')
print('ACPI OEMID wired-string contract passed')
PY
if [[ -z "${ACPI_OEMID_MUTATION_RUN:-}" ]]; then
 if ACPI_OEMID_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then echo 'ACPI OEMID mutation unexpectedly survived' >&2; exit 1; fi
 echo 'ACPI OEMID mutation rejected'
fi
