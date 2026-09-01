#!/usr/bin/env bash
# Regression coverage for representation-independent string hashing.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${STRING_SOURCE:-"$repo_root/system/string.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-string-hash.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/hash-string.lisp" "${STRING_HASH_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.index('(defun hash-string')
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
    raise SystemExit('unterminated HASH-STRING form')

if sys.argv[3]:
    old = '(char-int (char string i))'
    if old not in form:
        raise SystemExit('character-code mutation anchor missing')
    form = form.replace(old, '0', 1)

Path(sys.argv[2]).write_text(form)
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals
  (:use :cl)
  (:nicknames :sys.int))
(in-package :mezzano.internals)

(defvar *storage-by-string* (make-hash-table :test #'eq))
(defvar *raw-hash-calls* 0)

(defun character-array-p (string)
  (nth-value 1 (gethash string *storage-by-string*)))

(defun %complex-array-storage (string)
  (gethash string *storage-by-string*))

(defun hash-simple-numeric-1d-array (storage start end)
  (declare (ignore start end))
  (incf *raw-hash-calls*)
  (ecase storage
    (:narrow #x11111111)
    (:wide #x22222222)
    (:fullwidth #x33333333)))

(load (or (sb-ext:posix-getenv "STRING_HASH_FORM")
          (error "STRING_HASH_FORM is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(defun codepoint-hash (string)
  (let ((hash 5381))
    (dotimes (index (length string) hash)
      (setf hash
            (logand #xFFFFFFFF
                    (+ (logand #xFFFFFFFF (* hash 33))
                       (char-int (char string index))))))))

(defun copy-with-storage (string storage)
  (let ((copy (copy-seq string)))
    (setf (gethash copy *storage-by-string*) storage)
    copy))

(dolist (contents
         (list ""
               "ASCII"
               (string (code-char #x03BB))
               (coerce (list #\e (code-char #x301) #\!) 'string)))
  (let* ((narrow (copy-with-storage contents :narrow))
         (wide (copy-with-storage contents :wide))
         (fullwidth (copy-with-storage contents :fullwidth))
         (displaced (copy-seq contents))
         (expected (codepoint-hash contents))
         (hashes (mapcar #'hash-string (list narrow wide fullwidth displaced))))
    (check (every (lambda (hash) (= hash expected)) hashes)
           "encoding-dependent hash for ~S: got ~S, expected ~X"
           contents hashes expected)))

(check (zerop *raw-hash-calls*)
       "string hashes still depend on raw backing storage")
(format t "string representation-independent hashing passed~%")
EOF_LISP

STRING_HASH_FORM="$tmp_dir/hash-string.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${STRING_HASH_MUTATION_RUN:-}" ]]; then
  if STRING_HASH_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "string character-code mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "string character-code mutation rejected"
fi
