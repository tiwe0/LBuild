#!/usr/bin/env bash
# Executable semantics coverage for RESTART-CASE / WITH-SIMPLE-RESTART.
#
# The sibling test test-system-restarts-fast-path.sh only greps the source text
# for required tokens.  A macro whose expansion is structurally broken -- for
# example one whose expansion-building LET* sits inside the collecting DOLIST
# and therefore returns NIL -- passes that check while silently compiling every
# protected form in the system to a literal NIL.  This test macroexpands the
# real definition and runs it.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${RESTARTS_SOURCE:-"$repo_root/system/restarts.lisp"}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 - "$source_file" "$work/harness.lisp" "${RESTARTS_SEMANTICS_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
out, mutation = Path(sys.argv[2]), sys.argv[3]

hstart = source.index("(defun handle-restart-case-clause")
hend = source.index("\n)\n", hstart)
helper = source[hstart:hend]

mstart = source.index("(defmacro restart-case")
mend = source.index("\n\n(defmacro with-simple-restart", mstart)
macro = source[mstart:mend].replace("defmacro restart-case", "defmacro my-restart-case", 1)

if mutation:
    # Re-introduce the historical defect: return the DOLIST instead of the
    # expansion.  The suite must reject this.
    macro = macro.replace("(second restart-result)", "(rest restart-result)", 1)

out.write_text(f"""
(defpackage :restart-semantics (:use :cl))
(in-package :restart-semantics)
(defvar *active-restarts* nil)
(defstruct (xrestart
             (:constructor make-restart (name function &key interactive-function
                                                            report-function
                                                            test-function)))
  name function interactive-function report-function test-function)
(defun %restart-bind (clauses thunk)
  (let ((*active-restarts* (cons clauses *active-restarts*))) (funcall thunk)))
(defun r (name)
  (dolist (c *active-restarts*)
    (dolist (x c)
      (when (eq name (xrestart-name x)) (return-from r (xrestart-function x))))))
{helper}
{macro}
(defmacro my-wsr ((name fc &rest fa) &body forms)
  `(my-restart-case (progn ,@forms)
     (,name () :report (lambda (s) (format s ,fc ,@fa)) (values nil t))))

(defvar *failures* 0)
(defmacro expect (label expected form)
  `(let ((got (handler-case ,form (error (c) (list :error (type-of c))))))
     (cond ((equal got ,expected) (format t "~&ok   ~A => ~S~%" ,label got))
           (t (incf *failures*)
              (format t "~&FAIL ~A: expected ~S got ~S~%" ,label ,expected got)))))

;; The expansion must not be NIL: a NIL expansion silently discards the body.
(expect "expansion-non-nil" t
        (not (null (macroexpand-1 '(my-restart-case (progn :b) (abort () nil))))))
;; Normal return, including multiple values.
(expect "normal-values" '(1 2)
        (multiple-value-list (my-restart-case (values 1 2) (abort () :no))))
;; The protected form must actually be evaluated for effect.
(expect "body-evaluated" :ran
        (let ((flag nil)) (my-restart-case (setf flag :ran) (abort () :no)) flag))
;; Invoking a restart transfers control to its clause.
(expect "invoked" '(:aborted t)
        (multiple-value-list
         (my-restart-case (progn (funcall (r 'abort)) :not-reached)
           (abort () (values :aborted t)))))
;; Restart arguments arrive unwrapped.
(expect "restart-arguments" '(:stored 42)
        (my-restart-case (progn (funcall (r 'store-value) 42) :not-reached)
          (store-value (v) (list :stored v))))
(expect "restart-two-arguments" '(:two 1 2)
        (my-restart-case (progn (funcall (r 'take) 1 2) :not-reached)
          (take (a b) (list :two a b))))
;; Multiple clauses dispatch to the right one.
(expect "clause-dispatch" :got-b
        (my-restart-case (progn (funcall (r 'b)) :no)
          (a () :got-a) (b () :got-b)))
;; Nested RESTART-CASE unwinds to the correct level.
(expect "nested" :outer
        (my-restart-case (my-restart-case (funcall (r 'outer)) (inner () :inner))
          (outer () :outer)))
;; WITH-SIMPLE-RESTART runs its body and returns (NIL T) when aborted.
(expect "wsr-normal" '(:body-ran) (multiple-value-list (my-wsr (abort "c ~S" 7) :body-ran)))
(expect "wsr-aborted" '(nil t)
        (multiple-value-list (my-wsr (abort "c ~S" 7) (funcall (r 'abort)) :no)))

(if (zerop *failures*)
    (format t "~&restarts semantics passed~%")
    (progn (format t "~&restarts semantics FAILED (~D)~%" *failures*)
           (sb-ext:exit :code 1)))
""", encoding="utf-8")
PY

sbcl --noinform --disable-debugger --load "$work/harness.lisp" --quit

if [[ -z "${RESTARTS_SEMANTICS_MUTATION_RUN:-}" ]]; then
  if RESTARTS_SEMANTICS_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "restarts semantics mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "restarts semantics mutation rejected"
fi
