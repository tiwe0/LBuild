#!/usr/bin/env bash
# Regression coverage for the conservative runtime CONSTANTP folders.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${RUNTIME_SUPPORT_SOURCE:-"$repo_root/system/runtime-support.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-runtime-support-constantp.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT
python3 - "$source_file" "$tmp_dir/forms.lisp" "${RUNTIME_SUPPORT_CONSTANTP_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding='utf-8')
def extract(marker):
    start=source.index(marker); depth=0; string=False; comment=False; esc=False
    for i,c in enumerate(source[start:],start):
        if comment:
            if c=='\n': comment=False
            continue
        if string:
            if esc: esc=False
            elif c=='\\': esc=True
            elif c=='"': string=False
            continue
        if c==';': comment=True
        elif c=='"': string=True
        elif c=='(': depth+=1
        elif c==')':
            depth-=1
            if depth==0: return source[start:i+1]
    raise SystemExit('unterminated form')
text=extract('(defparameter *constantp-foldable-functions*')+'\n\n'+extract('(defun constantp')
if sys.argv[3]:
    text=text.replace("(every (lambda (arg) (constant-form-p arg env))", "(every (lambda (arg) t)", 1)
Path(sys.argv[2]).write_text(text+'\n')
PY
cat > "$tmp_dir/run.lisp" <<'LISP'
(defpackage :mezzano.compiler (:use :cl))
(defpackage :mezzano.internals (:use :cl) (:shadow #:constantp #:macroexpand-1))
(in-package :mezzano.compiler)
(defclass top-level-function () ())
(defun lookup-function-in-environment (name env) (declare (ignore name env)) (make-instance 'top-level-function))
(in-package :mezzano.internals)
(defun symbol-mode (symbol) (declare (ignore symbol)) nil)
(defun macroexpand-1 (form &optional env) (declare (ignore env)) (values form nil))
(load (or (sb-ext:posix-getenv "RUNTIME_SUPPORT_CONSTANTP_FORMS") (error "forms missing")))
(defun check (x message) (unless x (error message)))
(check (constantp 42) "self-evaluating integer rejected")
(check (constantp '(+ 1 (* 2 3))) "pure arithmetic rejected")
(check (constantp '(logand 7 3)) "pure logand rejected")
(check (not (constantp '(cons 1 2))) "arbitrary function accepted")
(check (not (constantp '(+ x 1))) "nonconstant argument accepted")
(format t "runtime-support constantp folders passed~%")
LISP
RUNTIME_SUPPORT_CONSTANTP_FORMS="$tmp_dir/forms.lisp" sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"
if [[ -z "${RUNTIME_SUPPORT_CONSTANTP_MUTATION_RUN:-}" ]]; then
  if RUNTIME_SUPPORT_CONSTANTP_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "runtime-support constantp mutation unexpectedly survived" >&2; exit 1
  fi
  echo "runtime-support constantp mutation rejected"
fi
