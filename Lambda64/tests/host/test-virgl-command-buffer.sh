#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${VIRGL_SOURCE:-"$repo_root/gui/virgl/virgl.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-virgl-command-buffer.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

python3 - "$source_file" "$test_file" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
output = Path(sys.argv[2])


def extract_form(marker, description):
    start = source.find(marker)
    if start < 0:
        raise SystemExit(f"Missing {description}: {marker}")
    depth = 0
    in_string = False
    escaped = False
    in_comment = False
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
        if character == ";":
            in_comment = True
        elif character == '"':
            in_string = True
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise SystemExit(f"Unterminated {description}: {marker}")


forms = [
    extract_form("(defconstant +virtio-gpu-submit-3d-request-prefix-size+", "request prefix constant"),
    extract_form("(defclass command-buffer ()", "command-buffer class"),
    extract_form("(defun make-command-buffer ", "make-command-buffer"),
    extract_form("(defun check-command-buffer-not-finalized ", "finalization guard"),
    extract_form("(defun command-buffer-finalize ", "command-buffer-finalize"),
    extract_form("(defun virgl-submit-dma-command-buffer-1 ", "DMA submit helper"),
    extract_form("(defun command-buffer-submit ", "command-buffer-submit"),
    extract_form("(defun command-buffer-reset ", "command-buffer-reset"),
    extract_form("(defmethod destroy ((command-buffer command-buffer))", "command-buffer destroy method"),
]

fixture = r'''
(defpackage :mezzano.supervisor
  (:use :cl)
  (:export #:dma-buffer-cache-flush
           #:dma-buffer-expired-p
           #:dma-buffer-length
           #:dma-buffer-n-sg-entries
           #:dma-buffer-sg-entry
           #:ensure
           #:make-dma-buffer
           #:mutex-held-p
           #:release-dma-buffer
           #:with-mutex))

(defpackage :mezzano.supervisor.virtio
  (:use :cl)
  (:export #:+virtio-ring-desc-f-next+
           #:+virtio-ring-desc-f-write+
           #:virtio-kick
           #:virtio-ring-add-to-avail-ring
           #:virtio-ring-alloc-descriptor
           #:virtio-ring-desc-address
           #:virtio-ring-desc-flags
           #:virtio-ring-desc-length
           #:virtio-ring-desc-next
           #:virtio-ring-free-descriptor
           #:virtio-ring-used-idx
           #:virtio-virtqueue))

(defpackage :mezzano.supervisor.virtio-gpu
  (:use :cl)
  (:export #:+virtio-gpu-cmd-submit-3d+
           #:+virtio-gpu-ctrl-hdr-ctx-id+
           #:+virtio-gpu-ctrl-hdr-fence-id+
           #:+virtio-gpu-ctrl-hdr-flags+
           #:+virtio-gpu-ctrl-hdr-type+
           #:+virtio-gpu-resp-err-unspec+
           #:+virtio-gpu-resp-ok-nodata+))

(defpackage :mezzano.extensions
  (:use :cl)
  (:export #:ub32ref/le #:ub64ref/le))

(defpackage :mezzano.gui.virgl
  (:use :cl)
  (:shadow #:make-array)
  (:local-nicknames (:gpu :mezzano.supervisor.virtio-gpu)
                    (:ext :mezzano.extensions)
                    (:sup :mezzano.supervisor)))

(in-package :mezzano.supervisor)

(defstruct host-dma
  length
  bytes
  entries
  expired-p)

(defvar *dma-allocations* '())
(defvar *dma-releases* '())
(defvar *dma-flushes* '())
(defvar *dma-fail-next-allocation* nil)

(defmacro with-mutex ((mutex &key wait-p resignal-errors) &body body)
  (declare (ignore wait-p resignal-errors))
  `(progn ,mutex ,@body))

(defun mutex-held-p (mutex)
  (declare (ignore mutex))
  t)

(defmacro ensure (value)
  `(unless ,value
     (error "Mock descriptor allocation failed")))

(defun make-dma-buffer (length &key name persistent contiguous 32-bit cache-mode errorp)
  (declare (ignore name persistent 32-bit cache-mode errorp))
  (when *dma-fail-next-allocation*
    (setf *dma-fail-next-allocation* nil)
    (error "Injected DMA allocation failure"))
  (let ((entries '())
        (remaining length)
        (address #x1000))
    ;; Deliberately return physically discontiguous short extents. This proves
    ;; the submission path consumes the DMA API's SG entries instead of merely
    ;; accepting a non-contiguous allocation and then taking one address.
    (loop while (plusp remaining)
          for extent = (min remaining 16)
          do (push (cons address extent) entries)
             (decf remaining extent)
             (incf address #x4000))
    (let ((buffer (make-host-dma
                   :length length
                   :bytes (cl:make-array length
                                         :element-type '(unsigned-byte 8)
                                         :initial-element 0)
                   :entries (nreverse entries)
                   :expired-p nil)))
      (push (list buffer length contiguous) *dma-allocations*)
      buffer)))

(defun dma-buffer-length (buffer)
  (host-dma-length buffer))

(defun dma-buffer-expired-p (buffer)
  (host-dma-expired-p buffer))

(defun dma-buffer-n-sg-entries (buffer)
  (length (host-dma-entries buffer)))

(defun dma-buffer-sg-entry (buffer index)
  (let ((entry (nth index (host-dma-entries buffer))))
    (values (car entry) (cdr entry))))

(defun dma-buffer-cache-flush (buffer &optional (start 0) end)
  (push (list buffer start end) *dma-flushes*)
  (values))

(defun release-dma-buffer (buffer)
  (unless (host-dma-expired-p buffer)
    (setf (host-dma-expired-p buffer) t)
    (push buffer *dma-releases*))
  (values))

(in-package :mezzano.extensions)

(defun ub32ref/le (vector offset)
  (loop for shift from 0 by 8 below 32
        for index from offset
        sum (ash (aref vector index) shift)))

(defun (setf ub32ref/le) (value vector offset)
  (dotimes (index 4 value)
    (setf (aref vector (+ offset index))
          (ldb (byte 8 (* index 8)) value))))

(defun ub64ref/le (vector offset)
  (loop for shift from 0 by 8 below 64
        for index from offset
        sum (ash (aref vector index) shift)))

(defun (setf ub64ref/le) (value vector offset)
  (dotimes (index 8 value)
    (setf (aref vector (+ offset index))
          (ldb (byte 8 (* index 8)) value))))

(in-package :mezzano.supervisor.virtio)

(defconstant +virtio-ring-desc-f-next+ 0)
(defconstant +virtio-ring-desc-f-write+ 1)

(defstruct descriptor address length flags next freed-p)
(defstruct queue (used-idx 0) (allocated '()) avail-head alloc-limit)
(defstruct device (queue (make-queue)) (kick-count 0))

(defun virtio-virtqueue (device index)
  (assert (zerop index))
  (device-queue device))

(defun virtio-ring-alloc-descriptor (queue)
  (when (and (queue-alloc-limit queue)
             (>= (length (queue-allocated queue))
                 (queue-alloc-limit queue)))
    (return-from virtio-ring-alloc-descriptor nil))
  (let ((descriptor (make-descriptor)))
    (setf (queue-allocated queue)
          (append (queue-allocated queue) (list descriptor)))
    descriptor))

(defun virtio-ring-desc-address (queue descriptor)
  (declare (ignore queue))
  (descriptor-address descriptor))
(defun (setf virtio-ring-desc-address) (value queue descriptor)
  (declare (ignore queue))
  (setf (descriptor-address descriptor) value))

(defun virtio-ring-desc-length (queue descriptor)
  (declare (ignore queue))
  (descriptor-length descriptor))
(defun (setf virtio-ring-desc-length) (value queue descriptor)
  (declare (ignore queue))
  (setf (descriptor-length descriptor) value))

(defun virtio-ring-desc-flags (queue descriptor)
  (declare (ignore queue))
  (descriptor-flags descriptor))
(defun (setf virtio-ring-desc-flags) (value queue descriptor)
  (declare (ignore queue))
  (setf (descriptor-flags descriptor) value))

(defun virtio-ring-desc-next (queue descriptor)
  (declare (ignore queue))
  (descriptor-next descriptor))
(defun (setf virtio-ring-desc-next) (value queue descriptor)
  (declare (ignore queue))
  (setf (descriptor-next descriptor) value))

(defun virtio-ring-used-idx (queue)
  (queue-used-idx queue))

(defun virtio-ring-add-to-avail-ring (queue descriptor)
  (setf (queue-avail-head queue) descriptor))

(defun virtio-kick (device index)
  (assert (zerop index))
  (incf (device-kick-count device))
  (incf (queue-used-idx (device-queue device))))

(defun virtio-ring-free-descriptor (queue descriptor)
  (declare (ignore queue))
  (setf (descriptor-freed-p descriptor) t))

(in-package :mezzano.supervisor.virtio-gpu)

(defconstant +virtio-gpu-cmd-submit-3d+ #x0207)
(defconstant +virtio-gpu-resp-ok-nodata+ #x1100)
(defconstant +virtio-gpu-resp-err-unspec+ #x1200)
(defconstant +virtio-gpu-ctrl-hdr-type+ 0)
(defconstant +virtio-gpu-ctrl-hdr-flags+ 4)
(defconstant +virtio-gpu-ctrl-hdr-fence-id+ 8)
(defconstant +virtio-gpu-ctrl-hdr-ctx-id+ 16)

(defstruct mock-gpu
  command-lock
  virtio-device
  (request-phys #x800000))

(defvar *response-type* +virtio-gpu-resp-ok-nodata+)

(defun virtio-gpu-command-lock (gpu)
  (mock-gpu-command-lock gpu))
(defun virtio-gpu-virtio-device (gpu)
  (mock-gpu-virtio-device gpu))
(defun virtio-gpu-request-phys (gpu)
  (mock-gpu-request-phys gpu))

(in-package :mezzano.supervisor)

(defun physical-memref-unsigned-byte-32 (address)
  (declare (ignore address))
  mezzano.supervisor.virtio-gpu::*response-type*)

(in-package :mezzano.gui.virgl)

(defconstant +virgl-gpu-context+ 1)

(defun make-array (dimensions &rest arguments &key memory &allow-other-keys)
  (if memory
      (progn
        (assert (= dimensions (sup:dma-buffer-length memory)))
        (mezzano.supervisor::host-dma-bytes memory))
      (let ((filtered '()))
        (loop for (key value) on arguments by #'cddr
              unless (eq key :memory)
                do (setf filtered (append filtered (list key value))))
        (apply #'cl:make-array dimensions filtered))))

(defclass host-virgl ()
  ((gpu :initarg :gpu :reader virgl-gpu)
   (lock :initform :virgl-lock :reader virgl-lock)))

(defclass host-context ()
  ((virgl :initarg :virgl :reader virgl)
   (id :initarg :id :reader context-id)))

(defgeneric destroy (object))

(defvar *simple-submissions* '())
(defvar *virgl-errors* '())

(defun encode-set-sub-ctx (vector id)
  (dotimes (index 8)
    (vector-push-extend (if (zerop index) id 0) vector)))

(defun virgl-submit-simple-command-buffer-1 (virgl data)
  (declare (ignore virgl))
  (push (coerce data 'list) *simple-submissions*)
  (values))

(defun simple-virgl-error (virgl context control &rest arguments)
  (declare (ignore virgl context))
  (push (apply #'format nil control arguments) *virgl-errors*)
  (error "~A" (first *virgl-errors*)))
'''

tests = r'''

(defun assert-equal (expected actual description)
  (unless (equal expected actual)
    (error "~A: expected ~S, got ~S" description expected actual)))

(defun assert-true (condition description)
  (unless condition
    (error "~A" description)))

(defun expected-dma-request-extents (dma request-length)
  (let ((remaining request-length)
        (result '()))
    (dotimes (index (sup:dma-buffer-n-sg-entries dma))
      (when (plusp remaining)
        (multiple-value-bind (address extent-length)
            (sup:dma-buffer-sg-entry dma index)
          (let ((descriptor-length (min remaining extent-length)))
            (push (cons address descriptor-length) result)
            (decf remaining descriptor-length)))))
    (assert-true (zerop remaining)
                 "DMA SG extents did not cover the request")
    (nreverse result)))

(defun assert-dma-submit-descriptor-chain
    (gpu dma request-length descriptors description)
  (let* ((expected-extents
           (expected-dma-request-extents dma request-length))
         (request-descriptors (butlast descriptors))
         (response (car (last descriptors)))
         (next-flag
           (ash 1 mezzano.supervisor.virtio:+virtio-ring-desc-f-next+))
         (write-flag
           (ash 1 mezzano.supervisor.virtio:+virtio-ring-desc-f-write+)))
    (assert-equal (1+ (length expected-extents))
                  (length descriptors)
                  (format nil "~A descriptor count" description))
    (loop for descriptor in request-descriptors
          for expected in expected-extents
          for next in (rest descriptors)
          for index from 0
          do (assert-equal
              (car expected)
              (mezzano.supervisor.virtio::descriptor-address descriptor)
              (format nil "~A request descriptor ~D address"
                      description index))
             (assert-equal
              (cdr expected)
              (mezzano.supervisor.virtio::descriptor-length descriptor)
              (format nil "~A request descriptor ~D clipped length"
                      description index))
             (assert-equal
              next-flag
              (mezzano.supervisor.virtio::descriptor-flags descriptor)
              (format nil "~A request descriptor ~D flags"
                      description index))
             (assert-equal
              next
              (mezzano.supervisor.virtio::descriptor-next descriptor)
              (format nil "~A request descriptor ~D next link"
                      description index)))
    (assert-equal
     (+ (mezzano.supervisor.virtio-gpu::virtio-gpu-request-phys gpu)
        2048)
     (mezzano.supervisor.virtio::descriptor-address response)
     (format nil "~A response address" description))
    (assert-equal 24
                  (mezzano.supervisor.virtio::descriptor-length response)
                  (format nil "~A response length" description))
    (assert-equal write-flag
                  (mezzano.supervisor.virtio::descriptor-flags response)
                  (format nil "~A response flags" description))
    (assert-equal 0
                  (mezzano.supervisor.virtio::descriptor-next response)
                  (format nil "~A response next" description))))

(defun append-test-command (command-buffer &rest bytes)
  (dolist (byte bytes)
    (vector-push-extend byte (command-buffer-data-array command-buffer))))

(defun make-fixture ()
  (let* ((device (mezzano.supervisor.virtio::make-device))
         (gpu (mezzano.supervisor.virtio-gpu::make-mock-gpu
               :command-lock :gpu-lock
               :virtio-device device))
         (virgl (make-instance 'host-virgl :gpu gpu))
         (context (make-instance 'host-context :virgl virgl :id 7)))
    (values gpu device context)))

(setf mezzano.supervisor::*dma-allocations* '()
      mezzano.supervisor::*dma-releases* '()
      mezzano.supervisor::*dma-flushes* '()
      *simple-submissions* '()
      *virgl-errors* '())

;; Small, non-optimized buffers preserve the existing copying submission path.
(multiple-value-bind (gpu device context) (make-fixture)
  (declare (ignore gpu device))
  (let ((command-buffer (make-command-buffer context)))
    (append-test-command command-buffer 10 20 30 40)
    (command-buffer-finalize command-buffer)
    (assert-true (null (command-buffer-dma-buffer command-buffer))
                 "Small unoptimized command unexpectedly allocated DMA")
    (command-buffer-submit command-buffer)
    (assert-equal 1 (length *simple-submissions*)
                  "Small command did not use copying submit")))

;; Optimized submission must lay out the complete virtio request in DMA and
;; chain every physical extent into the queue.
(multiple-value-bind (gpu device context) (make-fixture)
  (let ((command-buffer (make-command-buffer context :name "optimized")))
    (append-test-command command-buffer #xAA #xBB #xCC #xDD)
    (let ((payload-before (coerce (command-buffer-data-array command-buffer)
                                  '(simple-array (unsigned-byte 8) (*)))))
      (command-buffer-finalize command-buffer :optimize t)
      (let* ((dma (command-buffer-dma-buffer command-buffer))
             (bytes (mezzano.supervisor::host-dma-bytes dma))
             (request-length (+ +virtio-gpu-submit-3d-request-prefix-size+
                                (length payload-before))))
        (assert-equal request-length (sup:dma-buffer-length dma)
                      "DMA request length")
        (assert-true (null (third (first sup::*dma-allocations*)))
                     "Command DMA allocation was forced contiguous")
        (assert-equal gpu:+virtio-gpu-cmd-submit-3d+
                      (ext:ub32ref/le bytes gpu:+virtio-gpu-ctrl-hdr-type+)
                      "request type")
        (assert-equal +virgl-gpu-context+
                      (ext:ub32ref/le bytes gpu:+virtio-gpu-ctrl-hdr-ctx-id+)
                      "request context")
        (assert-equal (length payload-before) (ext:ub32ref/le bytes 24)
                      "command size")
        (assert-equal 0 (ext:ub32ref/le bytes 28) "request padding")
        (assert-equal (coerce payload-before 'list)
                      (coerce (subseq bytes 32) 'list)
                      "DMA payload")
        (let* ((queue (mezzano.supervisor.virtio::device-queue device))
               (descriptor-start
                 (length (mezzano.supervisor.virtio::queue-allocated queue))))
          (command-buffer-submit command-buffer)
          (let ((descriptors
                  (nthcdr descriptor-start
                          (mezzano.supervisor.virtio::queue-allocated queue))))
            (assert-dma-submit-descriptor-chain
             gpu dma request-length descriptors "initial DMA submit")
          (assert-equal request-length
                        (reduce #'+ (butlast descriptors)
                                :key #'mezzano.supervisor.virtio::descriptor-length)
                        "request SG descriptor lengths")
          (assert-true (every #'mezzano.supervisor.virtio::descriptor-freed-p
                              descriptors)
                       "Submission leaked virtqueue descriptors")
          (assert-equal 1 (mezzano.supervisor.virtio::device-kick-count device)
                        "virtqueue kick count")
          (assert-equal (list dma 0 request-length)
                        (first sup::*dma-flushes*)
                        "DMA cache flush range")))

        ;; A finalized optimized buffer can be submitted repeatedly without
        ;; replacing or mutating its DMA storage.
        (command-buffer-submit command-buffer)
        (assert-true (eq dma (command-buffer-dma-buffer command-buffer))
                     "Repeated submit replaced DMA storage")
        (assert-equal 2 (mezzano.supervisor.virtio::device-kick-count device)
                      "Repeated submit kick count"))

      ;; Resetting and rebuilding the same-sized command reuses the DMA object.
      (let ((first-dma (command-buffer-dma-buffer command-buffer)))
        (command-buffer-reset command-buffer)
        (append-test-command command-buffer #x11 #x22 #x33 #x44)
        (command-buffer-finalize command-buffer)
        (assert-true (eq first-dma (command-buffer-dma-buffer command-buffer))
                     "Same-sized command did not reuse its DMA buffer")
        (assert-equal 1 (length sup::*dma-allocations*)
                      "Same-sized command allocated another DMA buffer")

        ;; Capacity, not exact equality, controls reuse. A shorter request
        ;; keeps the allocation but submits only the new request bytes.
        (command-buffer-reset command-buffer)
        (append-test-command command-buffer #x31 #x32 #x33)
        (command-buffer-finalize command-buffer)
        (assert-true (eq first-dma (command-buffer-dma-buffer command-buffer))
                     "Shorter command did not reuse DMA capacity")
        (assert-equal
         (+ +virtio-gpu-submit-3d-request-prefix-size+
            (length (command-buffer-data-array command-buffer)))
         (command-buffer-dma-request-length command-buffer)
         "Shorter DMA request length")
        (let* ((queue (mezzano.supervisor.virtio::device-queue device))
               (descriptor-start
                 (length (mezzano.supervisor.virtio::queue-allocated queue)))
               (short-request-length
                 (command-buffer-dma-request-length command-buffer)))
          (command-buffer-submit command-buffer)
          (let ((descriptors
                  (nthcdr descriptor-start
                          (mezzano.supervisor.virtio::queue-allocated queue))))
            (assert-dma-submit-descriptor-chain
             gpu first-dma short-request-length descriptors
             "shorter reused DMA submit")
            (assert-equal
             short-request-length
             (reduce #'+ (butlast descriptors)
                     :key #'mezzano.supervisor.virtio::descriptor-length)
             "Shorter reused SG chain length")))
        (assert-equal
         (list first-dma 0 (command-buffer-dma-request-length command-buffer))
         (first sup::*dma-flushes*)
         "Shorter DMA submit range")
        (assert-equal 3 (mezzano.supervisor.virtio::device-kick-count device)
                      "Shorter reused submit kick count")

        ;; Growth beyond capacity allocates first, then safely retires the old
        ;; buffer.
        (command-buffer-reset command-buffer)
        (append-test-command command-buffer 1 2 3 4 5)
        (setf sup::*dma-fail-next-allocation* t)
        (let ((signaled-p nil))
          (handler-case
              (command-buffer-finalize command-buffer)
            (error () (setf signaled-p t)))
          (assert-true signaled-p "Injected replacement failure was ignored"))
        (assert-true (eq first-dma (command-buffer-dma-buffer command-buffer))
                     "Failed replacement discarded existing DMA storage")
        (assert-true (not (sup:dma-buffer-expired-p first-dma))
                     "Failed replacement released existing DMA storage")
        (command-buffer-finalize command-buffer)
        (let ((replacement (command-buffer-dma-buffer command-buffer)))
          (assert-true (not (eq first-dma replacement))
                     "Wrong-sized DMA buffer was reused")
          (assert-true (member first-dma sup::*dma-releases*)
                       "Replaced DMA buffer was not released")
          (assert-equal
           (coerce (command-buffer-data-array command-buffer) 'list)
           (coerce
            (subseq (mezzano.supervisor::host-dma-bytes replacement)
                    +virtio-gpu-submit-3d-request-prefix-size+)
            'list)
           "Replacement DMA payload")

          ;; An expired equal-sized buffer is never reused.
          (command-buffer-reset command-buffer)
          (append-test-command command-buffer 9 8 7 6 5)
          (setf (mezzano.supervisor::host-dma-expired-p replacement) t)
          (command-buffer-finalize command-buffer)
          (assert-true
           (not (eq replacement
                    (command-buffer-dma-buffer command-buffer)))
           "Expired DMA buffer was reused"))))))

;; Large command buffers automatically take the DMA path even without OPTIMIZE.
(multiple-value-bind (gpu device context) (make-fixture)
  (declare (ignore gpu device))
  (let ((command-buffer (make-command-buffer context)))
    (dotimes (index 1025)
      (vector-push-extend (logand index #xFF)
                          (command-buffer-data-array command-buffer)))
    (command-buffer-finalize command-buffer)
    (assert-true (command-buffer-dma-buffer command-buffer)
                 "Large command did not use DMA")))

;; Device errors use the same virgl error path as copying submissions, and all
;; allocated descriptors are still released by unwind cleanup.
(multiple-value-bind (gpu device context) (make-fixture)
  (declare (ignore gpu))
  (let ((command-buffer (make-command-buffer context)))
    (append-test-command command-buffer 1 2 3 4)
    (command-buffer-finalize command-buffer :optimize t)
    (let ((mezzano.supervisor.virtio-gpu::*response-type* #x1205)
          (signaled-p nil))
      (handler-case
          (command-buffer-submit command-buffer)
        (error () (setf signaled-p t)))
      (assert-true signaled-p "DMA submission error was ignored"))
    (assert-true *virgl-errors* "DMA submission did not report virgl error")
    (assert-true
     (every #'mezzano.supervisor.virtio::descriptor-freed-p
            (mezzano.supervisor.virtio::queue-allocated
             (mezzano.supervisor.virtio::device-queue device)))
     "Error submission leaked virtqueue descriptors")
    (let ((dma (command-buffer-dma-buffer command-buffer)))
      (destroy command-buffer)
      (assert-true (member dma sup::*dma-releases*)
                   "Destroy did not release command DMA")
      (assert-true (null (command-buffer-dma-buffer command-buffer))
                   "Destroy retained a released DMA buffer"))))

;; Descriptor exhaustion fails before publishing the partial chain and frees
;; every descriptor that was reserved successfully.
(multiple-value-bind (gpu device context) (make-fixture)
  (declare (ignore gpu))
  (let ((command-buffer (make-command-buffer context))
        (queue (mezzano.supervisor.virtio::device-queue device)))
    (append-test-command command-buffer 1 2 3 4)
    (command-buffer-finalize command-buffer :optimize t)
    (setf (mezzano.supervisor.virtio::queue-alloc-limit queue) 2)
    (let ((signaled-p nil))
      (handler-case
          (command-buffer-submit command-buffer)
        (error () (setf signaled-p t)))
      (assert-true signaled-p "Descriptor exhaustion was ignored"))
    (assert-equal 0 (mezzano.supervisor.virtio::device-kick-count device)
                  "Partial descriptor chain was published")
    (assert-true
     (every #'mezzano.supervisor.virtio::descriptor-freed-p
            (mezzano.supervisor.virtio::queue-allocated queue))
     "Descriptor exhaustion leaked reserved descriptors")))

(format t "virgl command-buffer DMA/SG/reuse tests passed~%")
'''

output.write_text(fixture + "\n" + "\n\n".join(forms) + "\n" + tests,
                  encoding="utf-8")
PY

"$sbcl" --noinform --disable-debugger --script "$test_file"
