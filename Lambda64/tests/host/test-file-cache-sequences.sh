#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-file-cache-sequences.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

cat >"$test_file" <<'LISP'
(defpackage :mezzano.gray
  (:use :cl)
  (:shadow
   #:stream-element-type
   #:stream-external-format
   #:stream-finish-output
   #:stream-write-byte
   #:stream-read-byte
   #:stream-write-sequence
   #:stream-read-sequence
   #:stream-file-position
   #:stream-file-length)
  (:export
   #:fundamental-binary-input-stream
   #:fundamental-binary-output-stream
   #:fundamental-character-input-stream
   #:fundamental-character-output-stream
   #:unread-char-mixin
   #:stream-element-type
   #:stream-external-format
   #:stream-finish-output
   #:stream-write-byte
   #:stream-read-byte
   #:stream-write-sequence
   #:stream-read-sequence
   #:stream-file-position
   #:stream-file-length))

(in-package :mezzano.gray)

(defclass fundamental-binary-input-stream () ())
(defclass fundamental-binary-output-stream () ())
(defclass fundamental-character-input-stream () ())
(defclass fundamental-character-output-stream () ())
(defclass unread-char-mixin () ())
(defgeneric stream-element-type (stream))
(defgeneric stream-external-format (stream))
(defgeneric stream-finish-output (stream))
(defgeneric stream-write-byte (stream byte))
(defgeneric stream-read-byte (stream))
(defgeneric stream-write-sequence (stream sequence &optional start end))
(defgeneric stream-read-sequence (stream sequence &optional start end))
(defgeneric stream-file-position (stream &optional position-spec))
(defgeneric stream-file-length (stream))

(defpackage :mezzano.internals
  (:use :cl)
  (:export #:external-format-mixin))

(in-package :mezzano.internals)

(defclass external-format-mixin () ())

(defpackage :mezzano.file-system-cache
  (:use :cl)
  (:shadow #:file-stream #:input-stream-p #:output-stream-p #:finish-output))

(in-package :mezzano.file-system-cache)

(defclass file-stream () ())
(defgeneric input-stream-p (stream))
(defgeneric output-stream-p (stream))
(defun finish-output (stream)
  (mezzano.gray:stream-finish-output stream))

(handler-bind ((warning (lambda (condition)
                          (when (search "also shadows" (princ-to-string condition))
                            (muffle-warning condition)))))
  (load (or (sb-ext:posix-getenv "FILE_CACHE_SOURCE")
            (error "FILE_CACHE_SOURCE is not set"))))

(defclass mock-cache-stream (file-cache-stream)
  ((blocks :initarg :blocks :accessor mock-blocks)
   (reads :initform 0 :accessor mock-reads)
   (writes :initform 0 :accessor mock-writes)
   (allocations :initform 0 :accessor mock-allocations)))

(defmethod read-file-block ((stream mock-cache-stream) block-n)
  (incf (mock-reads stream))
  (let ((block (gethash block-n (mock-blocks stream))))
    (and block (copy-seq block))))

(defmethod allocate-new-block ((stream mock-cache-stream) block-n)
  (incf (mock-allocations stream))
  (when (gethash block-n (mock-blocks stream))
    (error "Attempted to allocate an existing block"))
  (make-array (file-%block-size stream)
              :element-type '(unsigned-byte 8)
              :initial-element 0))

(defmethod write-file-block ((stream mock-cache-stream) buffer block-n)
  (incf (mock-writes stream))
  (setf (gethash block-n (mock-blocks stream)) (copy-seq buffer)))

(defun assert-true (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(defun expect-error (thunk control &rest arguments)
  (unless (handler-case
              (progn
                (funcall thunk)
                nil)
            (error () t))
    (apply #'error control arguments)))

(defun make-blocks (&rest bytes)
  (let ((blocks (make-hash-table)))
    (loop :for block-n :from 0
          :for block-bytes :in bytes
          :do (setf (gethash block-n blocks)
                    (make-array (length block-bytes)
                                :element-type '(unsigned-byte 8)
                                :initial-contents block-bytes)))
    blocks))

(defun stored-bytes (stream count)
  (let ((result (make-array count :element-type '(unsigned-byte 8))))
    (dotimes (position count result)
      (multiple-value-bind (block-n block-offset)
          (floor position (file-%block-size stream))
        (setf (aref result position)
              (aref (gethash block-n (mock-blocks stream)) block-offset))))))

;; READ-SEQUENCE honors destination bounds, crosses cache blocks, advances the
;; file position, and returns the first destination index that was not filled.
(let* ((stream (make-instance 'mock-cache-stream
                              :direction :input
                              :block-size 4
                              :length 12
                              :blocks (make-blocks '(0 1 2 3)
                                                   '(4 5 6 7)
                                                   '(8 9 10 11))))
       (destination (make-array 11 :element-type '(unsigned-byte 8)
                                :initial-element #xee)))
  (setf (file-%position stream) 2)
  (let ((result (mezzano.gray:stream-read-sequence stream destination 2 9)))
    (assert-true (= result 9) "Cross-block read returned ~S, expected 9" result)
    (assert-true (= (file-%position stream) 9) "Cross-block read position is wrong")
    (assert-true (equalp destination #(#xee #xee 2 3 4 5 6 7 8 #xee #xee))
                 "Cross-block read ignored START/END: ~S" destination)
    (assert-true (= (mock-reads stream) 3) "Cross-block read did not load 3 blocks"))

  ;; A short read at EOF returns START + bytes-read and leaves the rest alone.
  (setf (file-%position stream) 10)
  (fill destination #xee)
  (let ((result (mezzano.gray:stream-read-sequence stream destination 1 6)))
    (assert-true (= result 3) "Short EOF read returned ~S, expected 3" result)
    (assert-true (= (file-%position stream) 12) "Short EOF read position is wrong")
    (assert-true (equalp destination #(#xee 10 11 #xee #xee #xee #xee #xee #xee #xee #xee))
                 "Short EOF read changed the wrong destination elements"))

  ;; At EOF no data is touched and the return value is exactly START.
  (fill destination #xee)
  (let ((reads (mock-reads stream))
        (result (mezzano.gray:stream-read-sequence stream destination 4 8)))
    (assert-true (= result 4) "EOF read returned ~S, expected START" result)
    (assert-true (= reads (mock-reads stream)) "EOF read loaded a block")
    (assert-true (every (lambda (byte) (= byte #xee)) destination)
                 "EOF read changed its destination"))

  ;; An empty interval is a no-op even before EOF.
  (setf (file-%position stream) 4)
  (fill destination #xee)
  (let ((reads (mock-reads stream))
        (result (mezzano.gray:stream-read-sequence stream destination 5 5)))
    (assert-true (= result 5) "Empty read returned ~S, expected START" result)
    (assert-true (= (file-%position stream) 4) "Empty read changed position")
    (assert-true (= reads (mock-reads stream)) "Empty read loaded a block")
    (assert-true (every (lambda (byte) (= byte #xee)) destination)
                 "Empty read changed its destination")))

;; WRITE-SEQUENCE honors source bounds, crosses blocks, grows the logical file,
;; preserves bytes outside the written range, and returns the source sequence.
(let* ((stream (make-instance 'mock-cache-stream
                              :direction :output
                              :block-size 4
                              :length 6
                              :position 3
                              :blocks (make-blocks '(0 1 2 3)
                                                   '(4 5 6 7))))
       (source (make-array 8 :element-type '(unsigned-byte 8)
                           :initial-contents '(100 101 102 103 104 105 106 107))))
  (let ((result (mezzano.gray:stream-write-sequence stream source 1 7)))
    (assert-true (eq result source) "WRITE-SEQUENCE did not return its sequence")
    (assert-true (= (file-%position stream) 9) "Cross-block write position is wrong")
    (assert-true (= (file-%length stream) 9) "Cross-block write length is wrong")
    (mezzano.gray:stream-finish-output stream)
    (assert-true (equalp (stored-bytes stream 9) #(0 1 2 101 102 103 104 105 106))
                 "Cross-block write stored the wrong bytes: ~S"
                 (stored-bytes stream 9))
    (assert-true (= (mock-allocations stream) 1) "Write did not allocate one new block")
    (assert-true (= (mock-writes stream) 3) "Write did not flush all three changed blocks"))

  ;; Empty ranges are no-ops, including their return value and I/O counters.
  (let ((position (file-%position stream))
        (length (file-%length stream))
        (reads (mock-reads stream))
        (writes (mock-writes stream))
        (result (mezzano.gray:stream-write-sequence stream source 5 5)))
    (assert-true (eq result source) "Empty write did not return its sequence")
    (assert-true (= position (file-%position stream)) "Empty write changed position")
    (assert-true (= length (file-%length stream)) "Empty write changed length")
    (assert-true (= reads (mock-reads stream)) "Empty write read a block")
    (assert-true (= writes (mock-writes stream)) "Empty write flushed a block")))

;; Invalid sequence intervals must fail before changing stream state or issuing
;; I/O; treating START > END as an empty operation hides caller errors.
(let* ((stream (make-instance 'mock-cache-stream
                              :direction :io
                              :block-size 4
                              :length 4
                              :blocks (make-blocks '(0 1 2 3))))
       (buffer (make-array 4 :element-type '(unsigned-byte 8)
                            :initial-element #xee)))
  (let ((position (file-%position stream))
        (reads (mock-reads stream))
        (writes (mock-writes stream)))
    (expect-error
     (lambda () (mezzano.gray:stream-read-sequence stream buffer 3 1))
     "Invalid read bounds did not signal an error")
    (expect-error
     (lambda () (mezzano.gray:stream-write-sequence stream buffer 3 1))
     "Invalid write bounds did not signal an error")
    (assert-true (= position (file-%position stream)) "Invalid bounds changed position")
    (assert-true (= reads (mock-reads stream)) "Invalid bounds read a block")
    (assert-true (= writes (mock-writes stream)) "Invalid bounds flushed a block")))

(format t "file-cache sequence contract passed~%")
LISP

FILE_CACHE_SOURCE="$repo_root/file/cache.lisp" \
  "$sbcl" --noinform --disable-debugger --script "$test_file"
