#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-disk-stream-bounds.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

cat >"$test_file" <<'LISP'
(defpackage :mezzano.gray
  (:use :cl)
  (:shadow
   #:stream-element-type
   #:stream-file-position
   #:stream-file-length
   #:stream-read-sequence
   #:stream-write-sequence)
  (:export
   #:fundamental-binary-input-stream
   #:fundamental-binary-output-stream
   #:stream-element-type
   #:stream-file-position
   #:stream-file-length
   #:stream-read-sequence
   #:stream-write-sequence))

(in-package :mezzano.gray)

(defclass fundamental-binary-input-stream () ())
(defclass fundamental-binary-output-stream () ())
(defgeneric stream-element-type (stream))
(defgeneric stream-file-position (stream &optional position-spec))
(defgeneric stream-file-length (stream))
(defgeneric stream-read-sequence (stream sequence &optional start end))
(defgeneric stream-write-sequence (stream sequence &optional start end))

(defpackage :mezzano.supervisor
  (:use :cl)
  (:export #:disk-n-sectors #:disk-sector-size #:disk-read #:disk-write))

(in-package :mezzano.supervisor)

(defgeneric disk-n-sectors (disk))
(defgeneric disk-sector-size (disk))
(defgeneric disk-read (disk sector count buffer))
(defgeneric disk-write (disk sector count buffer))

(defpackage :mezzano.internals
  (:use :cl)
  (:shadow #:file-position #:file-stream #:make-array #:stream-file-length))

(in-package :mezzano.internals)

(defclass file-stream () ())

(defun make-array (dimensions &rest arguments &key area &allow-other-keys)
  (declare (ignore area))
  (remf arguments :area)
  (apply #'cl:make-array dimensions arguments))

(defun file-position (stream &optional (position-spec nil position-specp))
  (if position-specp
      (mezzano.gray:stream-file-position stream position-spec)
      (mezzano.gray:stream-file-position stream)))

(defun stream-file-length (stream)
  (mezzano.gray:stream-file-length stream))

(load (or (sb-ext:posix-getenv "DISK_STREAM_SOURCE")
          (error "DISK_STREAM_SOURCE is not set")))

(defclass mock-disk ()
  ((sector-size :initarg :sector-size :reader mock-sector-size)
   (sectors :initarg :sectors :reader mock-sectors)
   (read-count :initform 0 :accessor mock-read-count)
   (write-count :initform 0 :accessor mock-write-count)))

(defmethod mezzano.supervisor:disk-sector-size ((disk mock-disk))
  (mock-sector-size disk))

(defmethod mezzano.supervisor:disk-n-sectors ((disk mock-disk))
  (mock-sectors disk))

(defmethod mezzano.supervisor:disk-read ((disk mock-disk) sector count buffer)
  (when (> (+ sector count) (mock-sectors disk))
    (error "Mock disk read escaped its bounds"))
  (incf (mock-read-count disk) count)
  (fill buffer #x5a)
  (values t nil))

(defmethod mezzano.supervisor:disk-write ((disk mock-disk) sector count buffer)
  (declare (ignore buffer))
  (when (> (+ sector count) (mock-sectors disk))
    (error "Mock disk write escaped its bounds"))
  (incf (mock-write-count disk) count)
  (values t nil))

(defun assert-true (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(defun expect-bounds-error (thunk operation position length disk-size)
  (handler-case
      (progn
        (funcall thunk)
        (error "Expected a disk-stream bounds error"))
    (disk-stream-bounds-error (condition)
      (assert-true (eq (disk-stream-bounds-error-operation condition) operation)
                   "Wrong operation in bounds error")
      (assert-true (= (disk-stream-bounds-error-position condition) position)
                   "Wrong position in bounds error")
      (assert-true (= (disk-stream-bounds-error-length condition) length)
                   "Wrong length in bounds error")
      (assert-true (= (disk-stream-bounds-error-disk-size condition) disk-size)
                   "Wrong disk size in bounds error"))))

(let* ((disk (make-instance 'mock-disk :sector-size 4 :sectors 2))
       (stream (make-instance 'disk-stream :disk disk :position 4))
       (read-buffer (make-array 8 :element-type '(unsigned-byte 8)
                                :initial-element 0))
       (write-buffer (make-array 8 :element-type '(unsigned-byte 8)
                                 :initial-element #xa5)))
  ;; A rejected operation is atomic: it performs no partial I/O and does not
  ;; advance the stream position.
  (expect-bounds-error
   (lambda () (mezzano.gray:stream-read-sequence stream read-buffer 0 8))
   :read 4 8 8)
  (assert-true (zerop (mock-read-count disk)) "Out-of-bounds read reached disk I/O")
  (assert-true (= (file-position stream) 4) "Rejected read changed position")
  (assert-true (every #'zerop read-buffer) "Rejected read changed its destination")

  (expect-bounds-error
   (lambda () (mezzano.gray:stream-write-sequence stream write-buffer 0 8))
   :write 4 8 8)
  (assert-true (zerop (mock-write-count disk)) "Out-of-bounds write reached disk I/O")
  (assert-true (= (file-position stream) 4) "Rejected write changed position")

  ;; Access ending exactly at disk capacity remains valid.
  (file-position stream 0)
  (let ((result (mezzano.gray:stream-read-sequence stream read-buffer 0 8)))
    (assert-true (= result 8) "Exact-capacity read returned ~S, expected 8" result))
  (assert-true (= (mock-read-count disk) 2) "Exact-capacity read did not complete")
  (assert-true (= (file-position stream) 8) "Exact-capacity read position is wrong")

  ;; A zero-length access at EOF is valid and performs no disk I/O.
  (let ((result (mezzano.gray:stream-write-sequence stream write-buffer 0 0)))
    (assert-true (eq result write-buffer) "WRITE-SEQUENCE did not return its sequence"))
  (assert-true (zerop (mock-write-count disk)) "Zero-length EOF write reached disk I/O"))

(format t "disk-stream bounds contract passed~%")
LISP

DISK_STREAM_SOURCE="$repo_root/tools/disk-stream.lisp" \
  "$sbcl" --noinform --disable-debugger --script "$test_file"
