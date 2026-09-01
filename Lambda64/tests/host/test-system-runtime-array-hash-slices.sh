#!/usr/bin/env bash
# Regression coverage for hash-simple-numeric-1d-array slice boundaries.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${RUNTIME_ARRAY_SOURCE:-"$repo_root/system/runtime-array.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-runtime-array-hash.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/hash-simple-numeric-1d-array.lisp" \
  "${RUNTIME_ARRAY_HASH_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.index('(defun hash-simple-numeric-1d-array')
depth = 0
in_string = False
in_comment = False
escaped = False
for index in range(start, len(source)):
    character = source[index]
    if in_comment:
        if character == '\n':
            in_comment = False
        continue
    if in_string:
        if escaped:
            escaped = False
        elif character == '\\':
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
            form = source[start:index + 1]
            break
else:
    raise SystemExit('unterminated HASH-SIMPLE-NUMERIC-1D-ARRAY form')

if sys.argv[3]:
    old = '(* start element-bits)'
    if old not in form:
        raise SystemExit('slice-start mutation anchor missing')
    form = form.replace(old, '0', 1)

Path(sys.argv[2]).write_text(form)
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals (:use :cl))
(in-package :mezzano.internals)

(defconstant +object-tag-array-bit+ 1)
(defconstant +object-tag-array-signed-byte-1+ 2)
(defconstant +object-tag-array-unsigned-byte-2+ 3)
(defconstant +object-tag-array-signed-byte-2+ 4)
(defconstant +object-tag-array-unsigned-byte-4+ 5)
(defconstant +object-tag-array-signed-byte-4+ 6)
(defconstant +object-tag-array-unsigned-byte-8+ 7)
(defconstant +object-tag-array-signed-byte-8+ 8)
(defconstant +object-tag-array-unsigned-byte-16+ 9)
(defconstant +object-tag-array-signed-byte-16+ 10)
(defconstant +object-tag-array-short-float+ 11)
(defconstant +object-tag-array-unsigned-byte-32+ 12)
(defconstant +object-tag-array-signed-byte-32+ 13)
(defconstant +object-tag-array-single-float+ 14)
(defconstant +object-tag-array-complex-short-float+ 15)
(defconstant +object-tag-array-fixnum+ 16)
(defconstant +object-tag-array-unsigned-byte-64+ 17)
(defconstant +object-tag-array-signed-byte-64+ 18)
(defconstant +object-tag-array-double-float+ 19)
(defconstant +object-tag-array-complex-single-float+ 20)
(defconstant +object-tag-array-complex-double-float+ 21)

(defstruct test-array tag length words)
(defun %object-tag (array) (test-array-tag array))
(defun %object-header-data (array) (test-array-length array))
(defun %object-ref-unsigned-byte-32 (array index)
  (aref (test-array-words array) index))

(load (or (sb-ext:posix-getenv "RUNTIME_ARRAY_HASH_FORM")
          (error "RUNTIME_ARRAY_HASH_FORM is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(defun make-words (count)
  (let ((words (make-array count)))
    (dotimes (index count words)
      (setf (aref words index)
            (logand #xffffffff
                    (+ #x13579bdf (* #x9e3779b9 index)))))))

(defun bit-at (array bit-index)
  (ldb (byte 1 (mod bit-index 32))
       (aref (test-array-words array) (floor bit-index 32))))

(defun reference-hash (array element-bits start end)
  (let* ((element-count (- end start))
         (total-bits (* element-count element-bits))
         (first-bit (* start element-bits))
         (word-count (ceiling total-bits 32))
         (hash (logxor (ldb (byte 32 0) element-count)
                       (ldb (byte 32 32) element-count))))
    (dotimes (word-index word-count hash)
      (let ((word 0))
        (dotimes (bit 32)
          (let ((relative-bit (+ (* word-index 32) bit)))
            (when (< relative-bit total-bits)
              (setf (ldb (byte 1 bit) word)
                    (bit-at array (+ first-bit relative-bit))))))
        (setf hash (logxor hash word))))))

(defun legacy-zero-start-hash (array element-bits end)
  ;; Preserve the established start=0 packing, including full final words for
  ;; packed 1/2/4-bit arrays. The new path is only for formerly rejected
  ;; non-zero starts.
  (let* ((count (ceiling (* end element-bits) 32))
         (end-mask (case element-bits
                     ((1 2 4 32 64 128) -1)
                     (8 (case (mod end 4)
                          (0 #xffffffff) (1 #x000000ff)
                          (2 #x0000ffff) (3 #x00ffffff)))
                     (16 (case (mod end 2)
                           (0 #xffffffff) (1 #x0000ffff)))))
         (hash (logxor (ldb (byte 32 0) end)
                       (ldb (byte 32 32) end))))
    (dotimes (index count hash)
      (setf hash
            (logxor hash
                    (logand (aref (test-array-words array) index)
                            (if (= index (1- count)) end-mask -1)))))))

(defun signals-p (thunk)
  (handler-case (progn (funcall thunk) nil)
    (error () t)))

(dolist (case `((,+object-tag-array-bit+ 1)
                (,+object-tag-array-signed-byte-1+ 1)
                (,+object-tag-array-unsigned-byte-2+ 2)
                (,+object-tag-array-signed-byte-2+ 2)
                (,+object-tag-array-unsigned-byte-4+ 4)
                (,+object-tag-array-signed-byte-4+ 4)
                (,+object-tag-array-unsigned-byte-8+ 8)
                (,+object-tag-array-signed-byte-8+ 8)
                (,+object-tag-array-unsigned-byte-16+ 16)
                (,+object-tag-array-signed-byte-16+ 16)
                (,+object-tag-array-short-float+ 16)
                (,+object-tag-array-unsigned-byte-32+ 32)
                (,+object-tag-array-signed-byte-32+ 32)
                (,+object-tag-array-single-float+ 32)
                (,+object-tag-array-complex-short-float+ 32)
                (,+object-tag-array-fixnum+ 64)
                (,+object-tag-array-unsigned-byte-64+ 64)
                (,+object-tag-array-signed-byte-64+ 64)
                (,+object-tag-array-double-float+ 64)
                (,+object-tag-array-complex-single-float+ 64)
                (,+object-tag-array-complex-double-float+ 128)))
  (destructuring-bind (tag element-bits) case
    (let* ((length 13)
           (array (make-test-array
                   :tag tag :length length
                   :words (make-words (ceiling (* length element-bits) 32)))))
      (dolist (range '((0 13) (1 12) (2 7) (3 3) (9 13)))
        (destructuring-bind (start end) range
          (let ((actual (hash-simple-numeric-1d-array array start end))
                (expected (if (zerop start)
                              (legacy-zero-start-hash array element-bits end)
                              (reference-hash array element-bits start end))))
            (check (= actual expected)
                   "tag ~S, range [~D,~D): ~X /= ~X"
                   tag start end actual expected))))
    ;; Omitted END must remain equivalent to the array length.
      (let ((actual (hash-simple-numeric-1d-array array 3))
            (expected (reference-hash array element-bits 3 length)))
        (check (= actual expected) "tag ~S omitted END mismatch" tag)))))

(let ((array (make-test-array :tag +object-tag-array-unsigned-byte-8+
                              :length 8 :words (make-words 2))))
  (check (signals-p (lambda () (hash-simple-numeric-1d-array array -1 2)))
         "negative START accepted")
  (check (signals-p (lambda () (hash-simple-numeric-1d-array array 4 3)))
         "inverted range accepted")
  (check (signals-p (lambda () (hash-simple-numeric-1d-array array 1 9)))
         "END beyond array length accepted")
  (check (signals-p (lambda () (hash-simple-numeric-1d-array array 1.0 2)))
         "non-integer START accepted")
  (check (signals-p (lambda () (hash-simple-numeric-1d-array array 1 2.0)))
         "non-integer END accepted"))

(format t "runtime-array numeric slice hashing passed~%")
EOF_LISP

RUNTIME_ARRAY_HASH_FORM="$tmp_dir/hash-simple-numeric-1d-array.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${RUNTIME_ARRAY_HASH_MUTATION_RUN:-}" ]]; then
  if RUNTIME_ARRAY_HASH_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "runtime-array non-zero-start mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "runtime-array non-zero-start mutation rejected"
fi
