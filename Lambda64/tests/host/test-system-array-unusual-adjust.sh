#!/usr/bin/env bash
# Regression coverage for ADJUST-ARRAY on displaced and memory-backed arrays.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${ARRAY_SOURCE:-"$repo_root/system/array.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-array-unusual-adjust.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/adjust-array.lisp" "${ARRAY_UNUSUAL_ADJUST_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()

def extract(start_marker):
    start = source.index(start_marker)
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
                return source[start:index + 1]
    raise SystemExit(f'unterminated form starting at {start_marker!r}')

forms = []
if '(defun %copy-array-prefix' in source:
    forms.append(extract('(defun %copy-array-prefix'))
forms.append(extract('(defun adjust-array'))
text = '\n\n'.join(forms)

if sys.argv[3]:
    old = '(array-total-size source)'
    if old not in text:
        raise SystemExit('array-prefix mutation anchor missing')
    text = text.replace(old, '0', 1)

Path(sys.argv[2]).write_text(text)
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals
  (:use :cl)
  (:shadow #:adjust-array
           #:array
           #:array-element-type
           #:array-has-fill-pointer-p
           #:array-rank
           #:array-total-size
           #:character-array-p
           #:fill-pointer
           #:make-array
           #:vectorp))
(in-package :mezzano.internals)

(defstruct (test-array (:constructor make-test-array
                                      (&key dimensions element-type kind storage info values fill-pointer)))
  dimensions
  (element-type t)
  (kind :normal)
  storage
  info
  values
  fill-pointer)

(deftype array () 'test-array)

(defun array-rank (array)
  (length (test-array-dimensions array)))

(defun array-element-type (array)
  (test-array-element-type array))

(defun array-total-size (array)
  (reduce #'* (test-array-dimensions array)))

(defun object-allocation-area (array)
  (declare (ignore array))
  :test-area)

(defun vectorp (array)
  (= (array-rank array) 1))

(defun character-array-p (array)
  (eq (array-element-type array) 'character))

(defun array-has-fill-pointer-p (array)
  (and (vectorp array) (test-array-fill-pointer array)))

(defun fill-pointer (array)
  (test-array-fill-pointer array))

(defun (setf fill-pointer) (value array)
  (setf (test-array-fill-pointer array) value))

(defun %simple-1d-array-p (array)
  (eq (test-array-kind array) :simple))

(defun %complex-array-info (array)
  (test-array-info array))

(defun (setf %complex-array-info) (value array)
  (setf (test-array-info array) value))

(defun %complex-array-storage (array)
  (test-array-storage array))

(defun (setf %complex-array-storage) (value array)
  (setf (test-array-storage array) value))

(defun %complex-array-dimension (array axis)
  (nth axis (test-array-dimensions array)))

(defun (setf %complex-array-dimension) (value array axis)
  (setf (nth axis (test-array-dimensions array)) value))

(defun %row-major-aref (array index)
  (case (test-array-kind array)
    (:displaced (%row-major-aref (test-array-storage array)
                                  (+ index (test-array-info array))))
    (otherwise (cl:aref (test-array-values array) index))))

(defun (setf %row-major-aref) (value array index)
  (case (test-array-kind array)
    (:displaced (setf (%row-major-aref (test-array-storage array)
                                       (+ index (test-array-info array)))
                      value))
    (otherwise (setf (cl:aref (test-array-values array) index) value)))
  value)

(defun make-array (dimensions &key
                              (element-type t)
                              (initial-element nil initial-element-p)
                              adjustable
                              fill-pointer
                              area)
  (declare (ignore adjustable area))
  (let* ((dimensions (if (listp dimensions) dimensions (list dimensions)))
         (total-size (reduce #'* dimensions))
         (values (cl:make-array total-size
                                :initial-element (if initial-element-p initial-element nil))))
    (make-test-array :dimensions (copy-list dimensions)
                     :element-type element-type
                     :kind :normal
                     :values values
                     :fill-pointer fill-pointer)))

(defun make-simple-array-1 (&rest arguments)
  (declare (ignore arguments))
  (error "unexpected simple-array branch"))

(defun initialize-from-initial-contents (array contents)
  (dotimes (index (min (array-total-size array) (length contents)) array)
    (setf (%row-major-aref array index) (elt contents index))))

(load (or (sb-ext:posix-getenv "ARRAY_ADJUST_FORM")
          (error "ARRAY_ADJUST_FORM is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(defun values-of (array)
  (loop for index below (array-total-size array)
        collect (%row-major-aref array index)))

(defun make-simple (values &key (element-type 'integer))
  (make-test-array :dimensions (list (length values))
                   :element-type element-type
                   :kind :simple
                   :values (coerce values 'vector)))

(let* ((storage (make-simple '(0 1 2 3 4 5)))
       (displaced (make-test-array :dimensions '(2 2)
                                   :element-type 'integer
                                   :kind :displaced
                                   :storage storage
                                   :info 1))
       (adjusted (adjust-array displaced '(1 3) :initial-element 99)))
  (check (not (eq adjusted displaced))
         "displaced adjustment reused the old header")
  (check (null (test-array-info adjusted))
         "displaced adjustment retained the old displacement")
  (check (equal (test-array-dimensions adjusted) '(1 3))
         "displaced dimensions were not updated: ~S" (test-array-dimensions adjusted))
  (check (equal (values-of adjusted) '(1 2 3))
         "displaced row-major prefix was not retained: ~S" (values-of adjusted))
  (check (equal (values-of storage) '(0 1 2 3 4 5))
         "displaced adjustment mutated the former storage: ~S" (values-of storage)))

(let* ((storage (make-simple '(0 1 2 3 4 5)))
       (displaced (make-test-array :dimensions '(2)
                                   :element-type 'integer
                                   :kind :displaced
                                   :storage storage
                                   :info 2
                                   :fill-pointer 1))
       (adjusted (adjust-array displaced 4 :initial-element 99)))
  (check (equal (values-of adjusted) '(2 3 99 99))
         "new displaced slots did not use INITIAL-ELEMENT: ~S" (values-of adjusted))
  (check (= (fill-pointer adjusted) 1)
         "displaced vector fill pointer was not retained: ~S" (fill-pointer adjusted)))

(let* ((storage (make-simple '(0 1 2 3 4)))
       (displaced (make-test-array :dimensions '(3)
                                   :element-type 'integer
                                   :kind :displaced
                                   :storage storage
                                   :info 1))
       (adjusted (adjust-array displaced 3 :initial-contents #(9 8 7))))
  (check (equal (values-of adjusted) '(9 8 7))
         "INITIAL-CONTENTS did not replace displaced contents: ~S" (values-of adjusted)))

(let* ((memory (make-test-array :dimensions '(1 3)
                                :element-type 'integer
                                :kind :memory
                                :storage 4096
                                :info :unsigned-byte-32
                                :values #(7 8 9)))
       (adjusted (adjust-array memory '(2 2) :initial-element 0)))
  (check (not (eq adjusted memory))
         "memory-backed adjustment reused the memory header")
  (check (null (test-array-info adjusted))
         "memory-backed adjustment retained memory metadata")
  (check (equal (values-of adjusted) '(7 8 9 0))
         "memory-backed row-major prefix was not retained: ~S" (values-of adjusted)))

(format t "unusual-array adjustment semantics passed~%")
EOF_LISP

ARRAY_ADJUST_FORM="$tmp_dir/adjust-array.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${ARRAY_UNUSUAL_ADJUST_MUTATION_RUN:-}" ]]; then
  if ARRAY_UNUSUAL_ADJUST_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "unusual-array prefix-copy mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "unusual-array prefix-copy mutation rejected"
fi
