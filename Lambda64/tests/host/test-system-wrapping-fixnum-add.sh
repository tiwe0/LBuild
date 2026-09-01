#!/usr/bin/env bash
# Regression coverage for WRAPPING-FIXNUM-+ overflow semantics.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
cas_source=${CAS_SOURCE:-"$repo_root/system/cas.lisp"}
arm64_source=${ARM64_NUMBER_SOURCE:-"$repo_root/compiler/backend/arm64/number.lisp"}
x86_source=${X86_NUMBER_SOURCE:-"$repo_root/compiler/backend/x86-64/number.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-wrapping-fixnum-add.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$cas_source" "$arm64_source" "$x86_source" "$tmp_dir/wrapping.lisp" "${WRAPPING_FIXNUM_ADD_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

cas = Path(sys.argv[1]).read_text(encoding="utf-8")
arm64 = Path(sys.argv[2]).read_text(encoding="utf-8")
x86 = Path(sys.argv[3]).read_text(encoding="utf-8")
mutation = sys.argv[5]

if mutation:
    old = "mezzano.compiler::%wrapping-fixnum-+ x y"
    if old not in cas:
        raise SystemExit("wrapping-fixnum mutation anchor missing")
    cas = cas.replace(old, "mezzano.compiler::%fast-fixnum-+ x y", 1)

def extract(source, marker):
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

wrapper = extract(cas, "(defun wrapping-fixnum-+")
Path(sys.argv[4]).write_text(wrapper + "\n", encoding="utf-8")

for source, marker, opcode, forbidden in (
    (arm64, "(define-builtin mezzano.compiler::%wrapping-fixnum-+", ":opcode 'lap:add", "lap:b.vs"),
    (x86, "(define-builtin mezzano.compiler::%wrapping-fixnum-+", ":opcode 'lap:add64", "lap:jo"),
):
    implementation = extract(source, marker)
    if opcode not in implementation:
        raise SystemExit(f"{marker} does not emit {opcode}")
    if forbidden in implementation:
        raise SystemExit(f"{marker} must not take an overflow path")
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.compiler
  (:use :cl))
(in-package :mezzano.compiler)

(defconstant +fixnum-width+ 63)
(defconstant +fixnum-modulus+ (ash 1 +fixnum-width+))
(defconstant +test-most-positive-fixnum+ (1- (ash 1 (1- +fixnum-width+))))
(defconstant +test-most-negative-fixnum+ (- (ash 1 (1- +fixnum-width+))))

(defun %wrapping-fixnum-+ (x y)
  (let ((unsigned (mod (+ x y) +fixnum-modulus+)))
    (if (>= unsigned (ash 1 (1- +fixnum-width+)))
        (- unsigned +fixnum-modulus+)
        unsigned)))

(defun %fast-fixnum-+ (x y)
  (declare (ignore x y))
  (error "WRAPPING-FIXNUM-+ used the undefined-overflow fast primitive"))

(defpackage :mezzano.internals
  (:use :cl))
(in-package :mezzano.internals)

(defun fixnump (value)
  (typep value `(integer ,mezzano.compiler::+test-most-negative-fixnum+
                         ,mezzano.compiler::+test-most-positive-fixnum+)))

(defun raise-type-error (value expected-type)
  (error 'type-error :datum value :expected-type expected-type))

(defun %%unreachable ()
  (error "unexpected unreachable path"))

(load (or (sb-ext:posix-getenv "WRAPPING_FIXNUM_ADD_FORMS")
          (error "WRAPPING_FIXNUM_ADD_FORMS is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(check (= (wrapping-fixnum-+ mezzano.compiler::+test-most-positive-fixnum+ 1)
          mezzano.compiler::+test-most-negative-fixnum+)
       "positive overflow did not wrap")
(check (= (wrapping-fixnum-+ mezzano.compiler::+test-most-negative-fixnum+ -1)
          mezzano.compiler::+test-most-positive-fixnum+)
       "negative overflow did not wrap")
(check (= (wrapping-fixnum-+ 21 -8) 13)
       "ordinary fixnum addition changed")
(handler-case
    (progn
      (wrapping-fixnum-+ (1+ mezzano.compiler::+test-most-positive-fixnum+) 0)
      (error "non-fixnum input was accepted"))
  (type-error () nil))

(format t "wrapping-fixnum addition semantics passed~%")
EOF_LISP

WRAPPING_FIXNUM_ADD_FORMS="$tmp_dir/wrapping.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${WRAPPING_FIXNUM_ADD_MUTATION_RUN:-}" ]]; then
  if WRAPPING_FIXNUM_ADD_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "wrapping-fixnum mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "wrapping-fixnum mutation rejected"
fi
