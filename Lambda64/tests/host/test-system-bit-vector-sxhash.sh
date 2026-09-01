#!/usr/bin/env bash
# Regression coverage for SXHASH of bit vectors.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${HASH_TABLE_SOURCE:-"$repo_root/system/hash-table.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-bit-vector-sxhash.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/forms.lisp" "${BIT_VECTOR_SXHASH_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[3]:
    old = "(bit-vector (hash-bit-vector object))"
    if old not in source:
        raise SystemExit("bit-vector sxhash mutation anchor missing")
    source = source.replace(old, "(bit-vector 0)", 1)

def extract(marker):
    start = source.index(marker)
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
    raise SystemExit(f"unterminated form starting at {marker!r}")

Path(sys.argv[2]).write_text(
    extract("(defun hash-bit-vector") + "\n" + extract("(defun sxhash-1") + "\n",
    encoding="utf-8",
)
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals
  (:use :cl))
(in-package :mezzano.internals)

(defun hash-string (string) (cl:sxhash string))
(defun symbol-hash (symbol) (cl:sxhash symbol))
(defun hash-pathname (pathname depth)
  (declare (ignore depth))
  (cl:sxhash pathname))
(defun eql-hash (object) (cl:sxhash object))

(load (or (sb-ext:posix-getenv "BIT_VECTOR_SXHASH_FORMS")
          (error "BIT_VECTOR_SXHASH_FORMS is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(let* ((left (make-array 9 :element-type 'bit :initial-contents '(1 0 1 1 0 0 1 0 1)))
       (equal-copy (copy-seq left))
       (changed (make-array 9 :element-type 'bit :initial-contents '(1 0 1 1 0 0 1 1 1)))
       (extended (make-array 10 :element-type 'bit :initial-contents '(1 0 1 1 0 0 1 0 1 0)))
       (left-hash (sxhash-1 left 10)))
  (check (= left-hash (sxhash-1 equal-copy 10))
         "equal bit vectors received different hashes")
  (check (not (= left-hash (sxhash-1 changed 10)))
         "a changed bit did not affect SXHASH")
  (check (not (= left-hash (sxhash-1 extended 10)))
         "bit-vector length did not affect SXHASH")
  (check (not (zerop left-hash))
         "non-empty bit vector retained the old constant zero hash"))

(format t "bit-vector sxhash semantics passed~%")
EOF_LISP

BIT_VECTOR_SXHASH_FORMS="$tmp_dir/forms.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${BIT_VECTOR_SXHASH_MUTATION_RUN:-}" ]]; then
  if BIT_VECTOR_SXHASH_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "bit-vector sxhash mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "bit-vector sxhash mutation rejected"
fi
