#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-gui-bitblt-overlap.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

cat >"$test_file" <<'LISP'
(defpackage :mezzano.internals
  (:use :cl)
  (:export #:%simple-1d-array-p #:%complex-array-storage))

(in-package :mezzano.internals)

(defun %simple-1d-array-p (array)
  (typep array '(simple-array * (*))))

(defun %complex-array-storage (array)
  (declare (ignore array))
  (error "The host fixture only uses displaced arrays with simple vector storage"))

(defpackage :mezzano.gui
  (:use :cl)
  (:export #:colour))

(in-package :mezzano.gui)

(deftype colour () '(unsigned-byte 32))
(deftype matrix4 () '(simple-array single-float (4 4)))
(deftype colour-matrix () 't)

(handler-bind ((warning (lambda (condition)
                          (declare (ignore condition))
                          (muffle-warning))))
  (load (or (sb-ext:posix-getenv "BLIT_GENERIC_SOURCE")
            (error "BLIT_GENERIC_SOURCE is not set")))
  (load (or (sb-ext:posix-getenv "BLIT_SOURCE")
            (error "BLIT_SOURCE is not set"))))

(defun assert-array= (expected actual description)
  (unless (equalp expected actual)
    (error "~A failed:~%  expected ~S~%  actual   ~S"
           description expected actual)))

(defun make-grid (&optional (height 4) (width 5))
  (let ((storage (make-array (* height width)
                             :element-type '(unsigned-byte 32))))
    (dotimes (index (length storage))
      (setf (aref storage index) index))
    (values storage
            (make-array (list height width)
                        :element-type '(unsigned-byte 32)
                        :displaced-to storage))))

(defun copy-rectangle-through-snapshot (array nrows ncols from-row from-col to-row to-col)
  (let ((snapshot (make-array (list nrows ncols)
                              :element-type '(unsigned-byte 32))))
    (dotimes (row nrows)
      (dotimes (col ncols)
        (setf (aref snapshot row col)
              (aref array (+ from-row row) (+ from-col col)))))
    (dotimes (row nrows)
      (dotimes (col ncols)
        (setf (aref array (+ to-row row) (+ to-col col))
              (aref snapshot row col))))))

(defun check-copy (description nrows ncols from-row from-col to-row to-col)
  (multiple-value-bind (actual-storage actual)
      (make-grid)
    (declare (ignore actual-storage))
    (multiple-value-bind (expected-storage expected)
        (make-grid)
      (copy-rectangle-through-snapshot
       expected nrows ncols from-row from-col to-row to-col)
      (2d-array-bitblt
       nrows ncols actual from-row from-col actual to-row to-col)
      (assert-array= expected-storage actual-storage description))))

(defun check-distinct-shared-storage-views ()
  (let* ((actual-storage (make-array 25 :element-type '(unsigned-byte 32)))
         (expected-storage (make-array 25 :element-type '(unsigned-byte 32)))
         (actual-source (make-array '(4 5) :element-type '(unsigned-byte 32)
                                           :displaced-to actual-storage))
         (actual-target (make-array '(4 5) :element-type '(unsigned-byte 32)
                                           :displaced-to actual-storage
                                           :displaced-index-offset 5))
         (expected-source (make-array '(4 5) :element-type '(unsigned-byte 32)
                                             :displaced-to expected-storage))
         (expected-target (make-array '(4 5) :element-type '(unsigned-byte 32)
                                             :displaced-to expected-storage
                                             :displaced-index-offset 5)))
    (dotimes (index 25)
      (setf (aref actual-storage index) index
            (aref expected-storage index) index))
    (let ((snapshot (make-array '(3 4) :element-type '(unsigned-byte 32))))
      (dotimes (row 3)
        (dotimes (col 4)
          (setf (aref snapshot row col) (aref expected-source row col))))
      (dotimes (row 3)
        (dotimes (col 4)
          (setf (aref expected-target row col) (aref snapshot row col)))))
    (2d-array-bitblt 3 4 actual-source 0 0 actual-target 0 0)
    (assert-array= expected-storage actual-storage
                   "distinct views sharing one backing vector")))

;; Both unsafe forward-copy directions and their reverse directions must behave
;; as if the complete source rectangle were sampled before any destination write.
(check-copy "vertical overlap moving down" 3 4 0 0 1 0)
(check-copy "vertical overlap moving up" 3 4 1 0 0 0)
(check-copy "horizontal overlap moving right" 4 4 0 0 0 1)
(check-copy "horizontal overlap moving left" 4 4 0 1 0 0)
(check-distinct-shared-storage-views)

;; A same-storage but disjoint copy retains the ordinary copy result.
(check-copy "non-overlapping rectangles" 1 5 0 0 3 0)

;; Boundary clamping still adjusts both rectangles before overlap handling.
(multiple-value-bind (actual-storage actual)
    (make-grid)
  (declare (ignore actual-storage))
  (multiple-value-bind (expected-storage expected)
      (make-grid)
    (copy-rectangle-through-snapshot expected 3 4 1 0 0 0)
    (2d-array-bitblt 4 4 actual 0 0 actual -1 0)
    (assert-array= expected-storage actual-storage "clamped overlapping copy")))

(format t "GUI overlapping BITBLT contract passed~%")
LISP

BLIT_GENERIC_SOURCE="$repo_root/gui/blit-generic.lisp" \
BLIT_SOURCE="$repo_root/gui/blit.lisp" \
  "$sbcl" --noinform --disable-debugger --script "$test_file"
