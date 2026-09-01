#!/usr/bin/env bash
# Regression coverage for ATOMIC-DECF with MOST-NEGATIVE-FIXNUM.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${CAS_SOURCE:-"$repo_root/system/cas.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-atomic-decf-minimum.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/cas.lisp" "${ATOMIC_DECF_MINIMUM_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[3]:
    old = "(if (eql delta most-negative-fixnum)\n             delta\n             (- delta))"
    if old not in source:
        raise SystemExit("ATOMIC-DECF mutation anchor missing")
    source = source.replace(old, "(- delta)", 1)

def extract(start_marker):
    start = source.index(start_marker)
    depth = 0
    in_string = False
    in_comment = False
    escaped = False
    for index in range(start, len(source)):
        character = source[index]
        if in_comment:
            if character == "\n":
                in_comment = False
            continue
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == ';':
            in_comment = True
        elif character == '"':
            in_string = True
        elif character == '(':
            depth += 1
        elif character == ')':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise SystemExit(f"unterminated form starting at {start_marker!r}")

Path(sys.argv[2]).write_text(extract("(defmacro atomic-decf") + "\n", encoding="utf-8")
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals
  (:use :cl)
  (:shadow #:atomic-incf #:atomic-decf))
(in-package :mezzano.internals)

(defmacro atomic-incf (place &optional (delta 1))
  `(list ',place ,delta))

(load (or (sb-ext:posix-getenv "ATOMIC_DECF_MINIMUM_FORMS")
          (error "ATOMIC_DECF_MINIMUM_FORMS is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(let ((evaluations 0))
  (check (equal (atomic-decf slot (progn (incf evaluations) most-negative-fixnum))
                (list 'slot most-negative-fixnum))
         "ATOMIC-DECF did not preserve MOST-NEGATIVE-FIXNUM's wrapping delta")
  (check (= evaluations 1)
         "ATOMIC-DECF evaluated DELTA ~D times" evaluations))
(check (equal (atomic-decf slot -7) '(slot 7))
       "ATOMIC-DECF changed ordinary negation semantics")

(format t "atomic-decf minimum-fixnum semantics passed~%")
EOF_LISP

ATOMIC_DECF_MINIMUM_FORMS="$tmp_dir/cas.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${ATOMIC_DECF_MINIMUM_MUTATION_RUN:-}" ]]; then
  if ATOMIC_DECF_MINIMUM_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "atomic-decf minimum-fixnum mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "atomic-decf minimum-fixnum mutation rejected"
fi
