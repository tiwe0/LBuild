#!/usr/bin/env bash
# Regression coverage for DESCRIBE's SETF and CAS expander reporting.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${DESCRIBE_SOURCE:-"$repo_root/system/describe.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-describe-setf-cas.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/describe-symbol.lisp" "${DESCRIBE_SETF_CAS_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding='utf-8')
marker = '(defmethod describe-object ((object symbol)'
start = source.index(marker)
depth = 0
in_string = in_comment = escaped = False
for i in range(start, len(source)):
    c = source[i]
    if in_comment:
        if c == '\n': in_comment = False
        continue
    if in_string:
        if escaped: escaped = False
        elif c == '\\': escaped = True
        elif c == '"': in_string = False
        continue
    if c == ';': in_comment = True
    elif c == '"': in_string = True
    elif c == '(': depth += 1
    elif c == ')':
        depth -= 1
        if depth == 0:
            form = source[start:i+1]
            break
else:
    raise SystemExit('unterminated symbol describe method')
if "(finfo 'setf)" not in form or "(finfo 'cas)" not in form:
    raise SystemExit('DESCRIBE symbol method does not report SETF and CAS expanders')
if sys.argv[3]:
    form = form.replace("(finfo 'setf)", '(values)', 1)
Path(sys.argv[2]).write_text(form + '\n', encoding='utf-8')
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.compiler.backend.arm64 (:use :cl) (:export #:*builtins*))
(defpackage :mezzano.compiler.backend.x86-64 (:use :cl) (:export #:*builtins*))
(in-package :mezzano.compiler.backend.arm64)
(defparameter *builtins* (make-hash-table :test #'equal))
(in-package :mezzano.compiler.backend.x86-64)
(defparameter *builtins* (make-hash-table :test #'equal))

(defpackage :mezzano.internals (:use :cl) (:shadow #:describe-object #:fboundp #:fdefinition #:compiler-macro-function))
(in-package :mezzano.internals)
(defgeneric describe-object (object stream))
(defmacro lwhen ((var expression) &body body)
  `(let ((,var ,expression)) (when ,var ,@body)))
(defun function-info-for (name &optional createp) (declare (ignore name createp)) nil)
(defun fboundp (name)
  (or (and (consp name) (member (first name) '(setf cas)))
      (cl:fboundp name)))
(defun fdefinition (name)
  (if (consp name) (lambda (&rest arguments) (declare (ignore arguments)) :expander)
      (cl:fdefinition name)))
(defun compiler-macro-function (name &optional environment)
  (declare (ignore name environment)) nil)
EOF_LISP
cat >> "$tmp_dir/run.lisp" <<'EOF_LISP'
(defun symbol-mode (symbol) (declare (ignore symbol)) nil)
(defun lisp-object-address (object) (declare (ignore object)) #x1234)
(load (or (sb-ext:posix-getenv "DESCRIBE_SYMBOL_FORM")
          (error "DESCRIBE_SYMBOL_FORM is not set")))
(defun check (value control &rest arguments)
  (unless value (apply #'error control arguments)))
(let ((name (gensym "DESCRIBE-")))
  (let ((output (with-output-to-string (stream) (describe-object name stream))))
    (check (search "SETF" output) "DESCRIBE output omitted SETF expander: ~S" output)
    (check (search "CAS" output) "DESCRIBE output omitted CAS expander: ~S" output)))
(format t "describe SETF/CAS expander reporting passed~%")
EOF_LISP
DESCRIBE_SYMBOL_FORM="$tmp_dir/describe-symbol.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${DESCRIBE_SETF_CAS_MUTATION_RUN:-}" ]]; then
  if DESCRIBE_SETF_CAS_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "describe SETF/CAS mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "describe SETF/CAS mutation rejected"
fi
