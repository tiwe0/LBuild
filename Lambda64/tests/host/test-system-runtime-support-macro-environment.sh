#!/usr/bin/env bash
# Regression coverage for global-only macro definition setters.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${RUNTIME_SUPPORT_SOURCE:-"$repo_root/system/runtime-support.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-runtime-support-macro-environment.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/runtime-support.lisp" "${RUNTIME_SUPPORT_MACRO_ENV_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")

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
    raise SystemExit(f'unterminated form starting at {start_marker!r}')

forms = []
if '(defun %require-global-macro-definition-environment' in source:
    forms.append(extract('(defun %require-global-macro-definition-environment'))
forms.extend([
    extract('(defun (setf macro-function)'),
    extract('(defun (setf compiler-macro-function)'),
])
text = '\n\n'.join(forms)

if sys.argv[3]:
    old = '''(error 'simple-program-error
           :format-control "~S only supports definitions in the global environment."
           :format-arguments (list operator))'''
    if old not in text:
        raise SystemExit('macro environment mutation anchor missing')
    text = text.replace(old, '(error "mutated macro environment policy")', 1)

Path(sys.argv[2]).write_text(text + '\n', encoding='utf-8')
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals
  (:use :cl)
  (:shadow #:macro-function #:compiler-macro-function))
(in-package :mezzano.internals)

(define-condition simple-program-error (program-error simple-error) ())

(defstruct macro-definition function lambda-list)
(defvar *macros* (make-hash-table :test #'eq))
(defun get-macro-definition (symbol &optional (createp t))
  (or (gethash symbol *macros*)
      (when createp
        (setf (gethash symbol *macros*) (make-macro-definition)))))

(defstruct function-info compiler-macro)
(defvar *function-info* (make-hash-table :test #'equal))
(defun function-info-for (name &optional (createp t))
  (or (gethash name *function-info*)
      (when createp
        (setf (gethash name *function-info*) (make-function-info)))))

(load (or (sb-ext:posix-getenv "RUNTIME_SUPPORT_MACRO_FORMS")
          (error "RUNTIME_SUPPORT_MACRO_FORMS is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(defun signals-program-error-p (thunk)
  (handler-case (progn (funcall thunk) nil)
    (program-error () t)
    (error () nil)))

(let* ((name (gensym "MACRO-"))
       (old (lambda (form environment)
              (declare (ignore form environment))
              :old))
       (new (lambda (form environment)
              (declare (ignore form environment))
              :new))
       (environment (list :lexical)))
  (setf (macro-function name) old)
  (check (eq (macro-definition-function (get-macro-definition name)) old)
         "global macro definition was not installed")
  (check (signals-program-error-p
          (lambda () (setf (macro-function name environment) new)))
         "non-global macro definition did not signal PROGRAM-ERROR")
  (check (eq (macro-definition-function (get-macro-definition name)) old)
         "non-global macro definition changed the global binding")
  (setf (macro-function name) nil)
  (check (null (macro-definition-function (get-macro-definition name nil)))
         "global macro definition was not cleared"))

(let* ((name (gensym "COMPILER-MACRO-"))
       (old (lambda (form environment)
              (declare (ignore form environment))
              :old))
       (new (lambda (form environment)
              (declare (ignore form environment))
              :new))
       (environment (list :lexical)))
  (setf (compiler-macro-function name) old)
  (check (eq (function-info-compiler-macro (function-info-for name nil)) old)
         "global compiler macro definition was not installed")
  (check (signals-program-error-p
          (lambda () (setf (compiler-macro-function name environment) new)))
         "non-global compiler macro definition did not signal PROGRAM-ERROR")
  (check (eq (function-info-compiler-macro (function-info-for name nil)) old)
         "non-global compiler macro definition changed the global binding")
  (setf (compiler-macro-function name) nil)
  (check (null (function-info-compiler-macro (function-info-for name nil)))
         "global compiler macro definition was not cleared"))

(format t "runtime-support macro environment policy passed~%")
EOF_LISP

RUNTIME_SUPPORT_MACRO_FORMS="$tmp_dir/runtime-support.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${RUNTIME_SUPPORT_MACRO_ENV_MUTATION_RUN:-}" ]]; then
  if RUNTIME_SUPPORT_MACRO_ENV_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "runtime-support macro environment mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "runtime-support macro environment mutation rejected"
fi
