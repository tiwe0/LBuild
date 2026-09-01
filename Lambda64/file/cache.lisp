;;;; Copyright (c) 2019 Bruno Cichon <ebrasca@librepanther.com>
;;;; This code is licensed under the MIT license.

(defpackage :mezzano.file-system-cache
  (:use :cl)
  (:export #:file-cache-stream
           #:file-cache-character-stream
           #:allocate-new-block
           #:read-file-block
           #:write-file-block))

(in-package :mezzano.file-system-cache)

(defclass file-cache-stream (file-stream
                             mezzano.gray:fundamental-binary-input-stream
                             mezzano.gray:fundamental-binary-output-stream)
  ((%direction :initarg :direction :reader file-%direction)
   (%buffer :initarg :buffer :accessor file-%buffer)
   (%block-n :initarg :block-n :accessor file-%block-n)
   (%block-size :initarg :block-size :accessor file-%block-size)
   (%dirty-bit :initarg :dirty-bit :accessor file-%dirty-bit)
   (%position :initarg :position :accessor file-%position)
   (%length :initarg :length :accessor file-%length))
  (:default-initargs :buffer nil :block-n -1 :dirty-bit nil :position 0 :length 0))

(defclass file-cache-character-stream (mezzano.internals::external-format-mixin
                                       file-cache-stream
                                       mezzano.gray:fundamental-character-input-stream
                                       mezzano.gray:fundamental-character-output-stream
                                       mezzano.gray:unread-char-mixin)
  ())

(defgeneric allocate-new-block (stream block-n))

(defgeneric read-file-block (stream block-n))

(defgeneric write-file-block (stream buffer block-n))

(defmethod mezzano.gray:stream-element-type ((stream file-cache-stream))
  (declare (ignore stream))
  '(unsigned-byte 8))

(defmethod mezzano.gray:stream-element-type ((stream file-cache-character-stream))
  (declare (ignore stream))
  'character)

(defmethod mezzano.gray:stream-external-format ((stream file-cache-stream))
  (declare (ignore stream))
  :default)

(defmethod input-stream-p ((stream file-cache-stream))
  (member (file-%direction stream) '(:input :io)))

(defmethod output-stream-p ((stream file-cache-stream))
  (member (file-%direction stream) '(:output :io)))

(defmethod mezzano.gray:stream-finish-output ((stream file-cache-stream))
  (when (file-%dirty-bit stream)
    (write-file-block stream (file-%buffer stream) (file-%block-n stream))
    (setf (file-%dirty-bit stream) nil)))

(defmethod mezzano.gray:stream-write-byte ((stream file-cache-stream) byte)
  (assert (output-stream-p stream))
  (multiple-value-bind (block-n block-offset)
      (floor (file-%position stream) (file-%block-size stream))
    (when (/= block-n (file-%block-n stream))
      (finish-output stream)
      (setf (file-%buffer stream) (or (read-file-block stream block-n)
                                      (allocate-new-block stream block-n))
            (file-%block-n stream) block-n))
    (when (>= (file-%position stream) (file-%length stream))
      (setf (file-%length stream) (1+ (file-%position stream))))
    (setf (aref (file-%buffer stream) block-offset) byte
          (file-%dirty-bit stream) t)
    (incf (file-%position stream))))

(defmethod mezzano.gray:stream-read-byte ((stream file-cache-stream))
  (assert (input-stream-p stream))
  (if (>= (file-%position stream) (file-%length stream))
      :eof
      (multiple-value-bind (block-n block-offset)
          (floor (file-%position stream) (file-%block-size stream))
        (when (/= block-n (file-%block-n stream))
          (finish-output stream)
          (setf (file-%block-n stream) block-n
                (file-%buffer stream) (read-file-block stream block-n)))
        (prog1 (aref (file-%buffer stream) block-offset)
          (incf (file-%position stream))))))

(defun checked-sequence-end (sequence start end)
  (let ((end (or end (length sequence))))
    (unless (and (integerp start)
                 (integerp end)
                 (<= 0 start end)
                 (<= end (length sequence)))
      (error "Invalid sequence bounds: start ~S, end ~S, length ~D."
             start end (length sequence)))
    end))

(defmethod mezzano.gray:stream-write-sequence ((stream file-cache-stream) sequence
                                               &optional (start 0) end)
  (assert (output-stream-p stream))
  (let ((end (checked-sequence-end sequence start end))
        (source-position start))
    (loop
      (when (>= source-position end)
        (return))
      (multiple-value-bind (block-n block-offset)
          (floor (file-%position stream) (file-%block-size stream))
        (when (/= block-n (file-%block-n stream))
          (finish-output stream)
          (setf (file-%buffer stream) (or (read-file-block stream block-n)
                                          (allocate-new-block stream block-n))
                (file-%block-n stream) block-n))
        (let ((count (min (- end source-position)
                          (- (file-%block-size stream) block-offset))))
          (replace (file-%buffer stream) sequence
                   :start1 block-offset
                   :end1 (+ block-offset count)
                   :start2 source-position
                   :end2 (+ source-position count))
          (incf (file-%position stream) count)
          (setf (file-%length stream) (max (file-%length stream)
                                           (file-%position stream))
                (file-%dirty-bit stream) t)
          (incf source-position count))))
    sequence))

(defmethod mezzano.gray:stream-read-sequence ((stream file-cache-stream) sequence
                                              &optional (start 0) end)
  (assert (input-stream-p stream))
  (let* ((end (checked-sequence-end sequence start end))
         (count (max 0 (min (- end start)
                            (- (file-%length stream)
                               (file-%position stream)))))
         (destination-position start)
         (destination-end (+ start count)))
    (loop
      (when (>= destination-position destination-end)
        (return destination-position))
      (multiple-value-bind (block-n block-offset)
          (floor (file-%position stream) (file-%block-size stream))
        (when (/= block-n (file-%block-n stream))
          (finish-output stream)
          (setf (file-%buffer stream) (read-file-block stream block-n)
                (file-%block-n stream) block-n))
        (let ((block-count (min (- destination-end destination-position)
                                (- (file-%block-size stream) block-offset))))
          (replace sequence (file-%buffer stream)
                   :start1 destination-position
                   :end1 (+ destination-position block-count)
                   :start2 block-offset
                   :end2 (+ block-offset block-count))
          (incf (file-%position stream) block-count)
          (incf destination-position block-count))))))

(defmethod mezzano.gray:stream-file-position ((stream file-cache-stream) &optional (position-spec nil position-specp))
  (if position-specp
      (setf (file-%position stream) (case position-spec
                                      (:start 0)
                                      (:end (file-%length stream))
                                      (t position-spec)))
      (file-%position stream)))

(defmethod mezzano.gray:stream-file-length ((stream file-cache-stream))
  (file-%length stream))
