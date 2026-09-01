#!/usr/bin/env bash
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${CLOSETTE_SOURCE:-"$repo_root/system/clos/closette.lisp"}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-closette-behavior.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT
python3 - "$source_file" "$test_file" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
def form(marker):
 start=source.index(marker); depth=0; string=escape=comment=False
 for i in range(start,len(source)):
  c=source[i]
  if comment:
   if c=='\n': comment=False
   continue
  if string:
   if escape: escape=False
   elif c=='\\': escape=True
   elif c=='"': string=False
   continue
  if c==';': comment=True
  elif c=='"': string=True
  elif c=='(': depth+=1
  elif c==')':
   depth-=1
   if depth==0:return source[start:i+1]
 raise RuntimeError(marker)
forms=[form('(defun layout-instance-slot-pairs'),form('(defun class-layouts-compatible-p'),
       form('(defun normalize-e-g-f-args'),form('(defun standard-call-method-list'),
       form('(defun std-compute-effective-method-function-with-standard-method-combination-1'),
       form('(defun one-effective-eql-table-assoc'),
       form('(defun initarg-cache-safe-p'),form('(defun valid-initargs')]
prefix=r'''
(defpackage :sys.int (:use :cl))
(defpackage :mezzano.supervisor (:use :cl) (:export #:with-mutex))
(defpackage :mezzano.garbage-collection.weak-objects
  (:use :cl)
  (:export #:weak-alist-assoc))
(defpackage :mezzano.clos (:use :cl) (:shadow #:standard-method))
(in-package :sys.int)
(defstruct layout heap-size heap-layout area instance-slots)
(in-package :mezzano.supervisor)
(defvar *test-lock-held* nil)
(defmacro with-mutex ((lock) &body body)
  `(progn
     (unless ,lock
       (error "lookup used a missing mutex"))
     (let ((*test-lock-held* t))
       ,@body)))
(in-package :mezzano.garbage-collection.weak-objects)
(defun weak-alist-assoc (object table)
  (unless mezzano.supervisor::*test-lock-held*
    (error "weak-alist-assoc executed outside the mutex"))
  (assoc object table))
(in-package :mezzano.clos)
(defclass standard-method () ())
(defclass eql-specializer () ())
(defparameter *the-class-standard-method* (find-class 'standard-method))
(defstruct fake-method qualifiers specializers function)
(defstruct fake-gf methods)
(defparameter *gf-methods* (make-hash-table :test #'eq))
(defun safe-method-qualifiers (method) (fake-method-qualifiers method))
(defun safe-method-specializers (method) (fake-method-specializers method))
(defun safe-generic-function-methods (gf) (gethash gf *gf-methods*))
(defun around-method-p (method) (equal (safe-method-qualifiers method) '(:around)))
(defun primary-method-p (method) (null (safe-method-qualifiers method)))
(defun before-method-p (method) (equal (safe-method-qualifiers method) '(:before)))
(defun after-method-p (method) (equal (safe-method-qualifiers method) '(:after)))
(defun method-fast-function (method next-emfun next-methods)
  (funcall (fake-method-function method) next-emfun next-methods))
(defun compute-primary-emfun (methods)
  (when methods
    (method-fast-function (first methods)
                          (compute-primary-emfun (rest methods))
                          (rest methods))))
(defun class-slot-initargs (class) (declare (ignore class)) '(:slot))
(defun applicable-method-initargs (gf arguments)
  (declare (ignore gf))
  (values (if (eql (first arguments) 1) '(:one) '(:two)) nil))
'''
tests=r'''
(defun check (x message) (unless x (error "~A" message)))
(check (equal (one-effective-eql-table-assoc
               :key (cons '((:key . :value)) :test-mutex))
              '(:key . :value))
       "locked weak EQL lookup returned the wrong entry")
(let ((a (sys.int::make-layout :heap-size 2 :heap-layout t :area :dynamic
                               :instance-slots #(a 1 b 2)))
      (b (sys.int::make-layout :heap-size 2 :heap-layout t :area :dynamic
                               :instance-slots #(b 2 a 1)))
      (c (sys.int::make-layout :heap-size 2 :heap-layout t :area :dynamic
                               :instance-slots #(b 3 a 1))))
  (check (class-layouts-compatible-p a b) "pair reordering rejected")
  (check (not (class-layouts-compatible-p a c)) "location change accepted"))
(multiple-value-bind (class args)
    (normalize-e-g-f-args :generic-function-class (find-class 'standard-method)
                          :method-class (find-class 'standard-method)
                          :environment :lexical :documentation "ok")
  (check class "generic function class lost")
  (check (not (getf args :environment)) "environment leaked into initargs")
  (check (string= (getf args :documentation) "ok") "ordinary initarg lost"))
(let* ((around-1 (make-fake-method :qualifiers '(:around)))
       (before (make-fake-method :qualifiers '(:before)))
       (primary-1 (make-fake-method :qualifiers nil))
       (after (make-fake-method :qualifiers '(:after)))
       (primary-2 (make-fake-method :qualifiers nil)))
  (check (equal (standard-call-method-list
                 (list around-1 before primary-1 after primary-2))
                (list around-1 primary-1 primary-2))
         "around next-method list order/qualifiers are wrong"))
(let* ((integer-primary
         (make-fake-method :qualifiers nil
                           :function (lambda (next next-methods)
                                       (declare (ignore next next-methods))
                                       (lambda (value)
                                         (declare (ignore value))
                                         :integer))))
       (number-around
         (make-fake-method :qualifiers '(:around)
                           :function (lambda (next next-methods)
                                       (declare (ignore next-methods))
                                       (lambda (value)
                                         (list :around (funcall next value))))))
       (number-primary
         (make-fake-method :qualifiers nil
                           :function (lambda (next next-methods)
                                       (declare (ignore next next-methods))
                                       (lambda (value)
                                         (declare (ignore value))
                                         :number))))
       ;; This is the production ordering for an INTEGER primary followed by
       ;; NUMBER around and primary methods.
       (effective
         (std-compute-effective-method-function-with-standard-method-combination-1
          'g (list integer-primary number-around number-primary))))
  (check (equal (funcall effective 1) '(:around :integer))
         "more-specific primary before around method was discarded"))
(defun eql-sensitive-init (&rest args) (declare (ignore args)))
(setf (gethash (fdefinition 'eql-sensitive-init) *gf-methods*)
      (list (make-fake-method :specializers
                              (list (make-instance 'eql-specializer)))))
(let ((cache (make-hash-table))
      (class 'sample))
  (check (equal (valid-initargs class cache '((eql-sensitive-init 1)))
                '(:one :slot)) "first EQL-sensitive initargs wrong")
  (check (equal (valid-initargs class cache '((eql-sensitive-init 2)))
                '(:two :slot)) "class cache leaked across EQL values")
  (check (= (hash-table-count cache) 0) "EQL-sensitive result was cached"))
(format t "closette behavioral contracts passed~%")
'''
Path(sys.argv[2]).write_text(prefix+'\n\n'.join(forms)+tests)
PY
${SBCL:-sbcl} --noinform --disable-debugger --script "$test_file"
