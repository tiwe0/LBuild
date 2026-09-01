#!/usr/bin/env bash
# Regression coverage for copying displaced strings into a requested area.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${RUNTIME_STRING_SOURCE:-"$repo_root/runtime/string.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-runtime-string-copy.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/copy-string-in-area.lisp" "${RUNTIME_STRING_COPY_MUTATION_RUN:-}" <<'PY'
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
if '(defun copy-non-character-array-string-in-area' in source:
    forms.append(extract('(defun copy-non-character-array-string-in-area'))
forms.append(extract('(defun copy-string-in-area'))
text = '\n\n'.join(forms)

if sys.argv[3]:
    old = '(char string i)'
    if old not in text:
        raise SystemExit('displaced-string copy mutation anchor missing')
    text = text.replace(old, '#\\?', 1)

Path(sys.argv[2]).write_text(text)
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :sys.int
  (:use :cl))

(in-package :sys.int)
(defconstant +object-tag-array-unsigned-byte-8+ 8)
(defconstant +object-tag-array-unsigned-byte-16+ 16)
(defconstant +object-tag-array-unsigned-byte-32+ 32)
(defconstant +object-tag-simple-string+ 64)

(defpackage :mezzano.runtime
  (:use :cl)
  (:shadow #:char #:copy-string-in-area #:string))

(in-package :mezzano.runtime)

(defstruct (fake-string (:constructor make-fake-string
                                      (&key kind characters dimensions fill-pointer storage info area tag)))
  kind
  characters
  dimensions
  fill-pointer
  storage
  info
  area
  tag)

(deftype string () 'fake-string)

(defun %allocate-object (tag length words area)
  (declare (ignore words))
  (if (= tag sys.int::+object-tag-simple-string+)
      (make-fake-string :kind :header :area area :tag tag)
      (make-fake-string :kind :storage
                        :characters (cl:make-array length :initial-element nil)
                        :area area
                        :tag tag)))

(defun char (string index)
  (let ((characters (if (eq (fake-string-kind string) :header)
                        (fake-string-characters (fake-string-storage string))
                        (fake-string-characters string))))
    (cl:aref characters index)))

(defun (setf char) (value string index)
  (let ((characters (if (eq (fake-string-kind string) :header)
                        (fake-string-characters (fake-string-storage string))
                        (fake-string-characters string))))
    (setf (cl:aref characters index) value))
  value)

(in-package :sys.int)

(defun character-array-p (object)
  (eq (mezzano.runtime::fake-string-kind object) :direct))

(defun %complex-array-storage (object)
  (mezzano.runtime::fake-string-storage object))

(defun (setf %complex-array-storage) (value object)
  (setf (mezzano.runtime::fake-string-storage object) value))

(defun %complex-array-fill-pointer (object)
  (mezzano.runtime::fake-string-fill-pointer object))

(defun (setf %complex-array-fill-pointer) (value object)
  (setf (mezzano.runtime::fake-string-fill-pointer object) value))

(defun %complex-array-info (object)
  (mezzano.runtime::fake-string-info object))

(defun (setf %complex-array-info) (value object)
  (setf (mezzano.runtime::fake-string-info object) value))

(defun %complex-array-dimension (object axis)
  (nth axis (mezzano.runtime::fake-string-dimensions object)))

(defun (setf %complex-array-dimension) (value object axis)
  (let ((dimensions (copy-list (or (mezzano.runtime::fake-string-dimensions object) '()))))
    (loop while (<= (length dimensions) axis)
          do (setf dimensions (append dimensions (list nil))))
    (setf (nth axis dimensions) value
          (mezzano.runtime::fake-string-dimensions object) dimensions)))

(defun %object-tag (object)
  (mezzano.runtime::fake-string-tag object))

(defun %object-header-data (object)
  (length (mezzano.runtime::fake-string-characters object)))

(defun %object-ref-unsigned-byte-8 (object index)
  (char-code (cl:aref (mezzano.runtime::fake-string-characters object) index)))

(defun %object-ref-unsigned-byte-16 (object index)
  (%object-ref-unsigned-byte-8 object index))

(defun %object-ref-unsigned-byte-32 (object index)
  (%object-ref-unsigned-byte-8 object index))

(defun (setf %object-ref-unsigned-byte-8) (value object index)
  (setf (cl:aref (mezzano.runtime::fake-string-characters object) index)
        (code-char value)))

(defun (setf %object-ref-unsigned-byte-16) (value object index)
  (setf (%object-ref-unsigned-byte-8 object index) value))

(defun (setf %object-ref-unsigned-byte-32) (value object index)
  (setf (%object-ref-unsigned-byte-8 object index) value))

(in-package :mezzano.runtime)

(load (or (sb-ext:posix-getenv "RUNTIME_STRING_COPY_FORM")
          (error "RUNTIME_STRING_COPY_FORM is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(defun copied-characters (string)
  (coerce (fake-string-characters (fake-string-storage string)) 'list))

(let* ((source (make-fake-string :kind :displaced
                                 :characters #(#\A #\λ #\中 #\Z)
                                 :dimensions '(4)
                                 :fill-pointer 3
                                 :info 1))
       (copy (copy-string-in-area source :wired)))
  (check (not (eq copy source)) "displaced string was not copied")
  (check (eq (fake-string-area copy) :wired)
         "copy header did not use requested area: ~S" (fake-string-area copy))
  (check (eq (fake-string-area (fake-string-storage copy)) :wired)
         "copy storage did not use requested area: ~S"
         (fake-string-area (fake-string-storage copy)))
  (check (equal (fake-string-dimensions copy) '(3))
         "copy did not honor the source fill pointer: ~S" (fake-string-dimensions copy))
  (check (equal (copied-characters copy) '(#\A #\λ #\中))
         "copy did not preserve displaced characters: ~S" (copied-characters copy))
  (check (equal (coerce (fake-string-characters source) 'list) '(#\A #\λ #\中 #\Z))
         "copy mutated the displaced source: ~S" (fake-string-characters source)))

(format t "runtime displaced-string copy semantics passed~%")
EOF_LISP

RUNTIME_STRING_COPY_FORM="$tmp_dir/copy-string-in-area.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${RUNTIME_STRING_COPY_MUTATION_RUN:-}" ]]; then
  if RUNTIME_STRING_COPY_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "displaced-string copy mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "displaced-string copy mutation rejected"
fi
