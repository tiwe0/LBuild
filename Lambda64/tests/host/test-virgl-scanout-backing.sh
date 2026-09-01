#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${VIRGL_SOURCE:-"$repo_root/gui/virgl/virgl.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-virgl-scanout-backing.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

python3 - "$source_file" "$test_file" <<'PY'
from pathlib import Path
import re
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
    extract_form("(defconstant +virtio-gpu-memory-entry-size+", "memory entry size"),
    extract_form("(defconstant +virtio-gpu-max-memory-entry-length+", "memory entry length limit"),
    extract_form("(defun virgl-dma-buffer-backing-entry-count ", "backing entry count"),
    extract_form("(defun virgl-attach-dma-buffer-backing-1 ", "SG backing helper"),
    extract_form("(defun update-virgl-scanout-1 ", "scanout update helper"),
    extract_form("(defun virgl-reset-1 ", "virgl-reset-1"),
]

buffer_form = extract_form("(defun make-buffer-1 ", "make-buffer-1")
texture_form = extract_form("(defun make-texture ", "make-texture")
buffer_uses_helper = bool(re.search(
    r"\(virgl-attach-dma-buffer-backing-1\s+virgl\s+id\s+dma-buffer\)",
    buffer_form,
    re.DOTALL,
))
texture_uses_helper = bool(re.search(
    r"\(virgl-attach-dma-buffer-backing-1\s+virgl\s+id\s+dma-buffer\)",
    texture_form,
    re.DOTALL,
))
texture_allows_sg = ":contiguous t" not in texture_form.lower()
reset_uses_update = "(update-virgl-scanout-1 virgl gpu)" in forms[-1]

fixture = r'''
(defpackage :mezzano.supervisor
  (:use :cl)
  (:export #:dma-buffer-length
           #:dma-buffer-n-sg-entries
           #:dma-buffer-sg-entry
           #:make-dma-buffer
           #:mutex-held-p
           #:release-dma-buffer
           #:with-mutex))

(defpackage :mezzano.supervisor.virtio-gpu
  (:use :cl)
  (:export #:+virtio-gpu-cmd-resource-attach-backing+
           #:+virtio-gpu-ctrl-hdr-ctx-id+
           #:+virtio-gpu-ctrl-hdr-fence-id+
           #:+virtio-gpu-ctrl-hdr-flags+
           #:+virtio-gpu-ctrl-hdr-type+
           #:+virtio-gpu-framebuffer-resource-id+
           #:virtio-gpu-attach-resource
           #:virtio-gpu-ctx-create
           #:virtio-gpu-ctx-destroy
           #:virtio-gpu-framebuffer
           #:virtio-gpu-framebuffer-format
           #:virtio-gpu-height
           #:virtio-gpu-width))

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

(defstruct host-dma length bytes entries expired-p)
(defvar *released-dma-buffers* '())

(defmacro with-mutex ((mutex &key wait-p resignal-errors) &body body)
  (declare (ignore wait-p resignal-errors))
  `(progn ,mutex ,@body))

(defun mutex-held-p (mutex)
  (declare (ignore mutex))
  t)

(defun make-dma-buffer (length &key name &allow-other-keys)
  (declare (ignore name))
  (make-host-dma
   :length length
   :bytes (cl:make-array length
                         :element-type '(unsigned-byte 8)
                         :initial-element 0)
   :entries (list (cons #xD000 length))
   :expired-p nil))

(defun dma-buffer-length (buffer)
  (host-dma-length buffer))

(defun dma-buffer-n-sg-entries (buffer)
  (length (host-dma-entries buffer)))

(defun dma-buffer-sg-entry (buffer index)
  (let ((entry (nth index (host-dma-entries buffer))))
    (values (car entry) (cdr entry))))

(defun release-dma-buffer (buffer)
  (setf (host-dma-expired-p buffer) t)
  (push buffer *released-dma-buffers*)
  (values))

(in-package :mezzano.extensions)

(defvar *ub32-write-error-p* nil)

(defun ub32ref/le (vector offset)
  (loop for shift from 0 by 8 below 32
        for index from offset
        sum (ash (aref vector index) shift)))

(defun (setf ub32ref/le) (value vector offset)
  (when *ub32-write-error-p*
    (setf *ub32-write-error-p* nil)
    (error "Injected ub32 encoding failure"))
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

(in-package :mezzano.supervisor.virtio-gpu)

(defconstant +virtio-gpu-cmd-resource-attach-backing+ #x0106)
(defconstant +virtio-gpu-ctrl-hdr-type+ 0)
(defconstant +virtio-gpu-ctrl-hdr-flags+ 4)
(defconstant +virtio-gpu-ctrl-hdr-fence-id+ 8)
(defconstant +virtio-gpu-ctrl-hdr-ctx-id+ 16)
(defconstant +virtio-gpu-framebuffer-resource-id+ 123)

(defstruct mock-gpu width height framebuffer framebuffer-format)
(defvar *gpu-calls* '())

(defun virtio-gpu-ctx-destroy (gpu &key context)
  (declare (ignore gpu))
  (push (list :ctx-destroy context) *gpu-calls*)
  (values t nil))

(defun virtio-gpu-ctx-create (gpu name &key context)
  (declare (ignore gpu name))
  (push (list :ctx-create context) *gpu-calls*)
  (values t nil))

(defun virtio-gpu-attach-resource (gpu id &key context)
  (declare (ignore gpu))
  (push (list :attach-resource id context) *gpu-calls*)
  (values t nil))

(defun virtio-gpu-width (gpu) (mock-gpu-width gpu))
(defun virtio-gpu-height (gpu) (mock-gpu-height gpu))
(defun virtio-gpu-framebuffer (gpu) (mock-gpu-framebuffer gpu))
(defun virtio-gpu-framebuffer-format (gpu) (mock-gpu-framebuffer-format gpu))

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

(defclass virgl ()
  ((%gpu :initarg :gpu :reader virgl-gpu)
   (%caps :initarg :caps :reader virgl-caps)
   (%lock :initform :virgl-lock :reader virgl-lock)
   (%error-state :initform nil :accessor virgl-error-state)
   (%scanout :reader virgl-%scanout)
   (%contexts :initform (make-hash-table) :reader virgl-contexts)
   (%resources :initform (make-hash-table) :reader virgl-resources)))

(defclass scanout ()
  ((%virgl :initarg :virgl :reader virgl)
   (%context :initarg :context :reader context)
   (%name :initarg :name :accessor name)
   (%id :initarg :id :reader resource-id)
   (%dma-buffer :initarg :dma-buffer :reader resource-dma-buffer)
   (%format :initarg :format :reader texture-format)
   (%render-target :initarg :render-target :reader texture-render-target-p)
   (%width :initarg :width :reader width)
   (%height :initarg :height :reader height)))

(defvar *raw-submissions* '())
(defvar *raw-submit-result* '(t nil))
(defvar *capset-generation* 0)

(defun virgl-submit-dma-command-buffer-1 (virgl dma-buffer request-length)
  (declare (ignore virgl))
  (push (list dma-buffer request-length) *raw-submissions*)
  (values-list *raw-submit-result*))

(defun read-virgl-capset (gpu)
  (declare (ignore gpu))
  (incf *capset-generation*))

(defun simple-virgl-error (virgl context control &rest arguments)
  (declare (ignore virgl context))
  (error "~A" (apply #'format nil control arguments)))
'''

tests = f'''

(defparameter *buffer-uses-sg-helper-p* {'t' if buffer_uses_helper else 'nil'})
(defparameter *texture-uses-sg-helper-p* {'t' if texture_uses_helper else 'nil'})
(defparameter *texture-allows-sg-p* {'t' if texture_allows_sg else 'nil'})
(defparameter *reset-uses-scanout-update-p* {'t' if reset_uses_update else 'nil'})

(defun assert-equal (expected actual description)
  (unless (equalp expected actual)
    (error "~A: expected ~S, got ~S" description expected actual)))

(defun assert-true (condition description)
  (unless condition
    (error "~A" description)))

(assert-true *buffer-uses-sg-helper-p*
             "Buffer construction bypasses the SG backing helper")
(assert-true *texture-uses-sg-helper-p*
             "Texture construction bypasses the SG backing helper")
(assert-true *texture-allows-sg-p*
             "Texture DMA allocation is still forced contiguous")
(assert-true *reset-uses-scanout-update-p*
             "virgl-reset-1 does not update the stable scanout")

;; One ordinary extent plus an extent larger than the protocol's 32-bit length
;; field must become three memory entries without losing address continuity.
(let* ((target
         (mezzano.supervisor::make-host-dma
          :length (+ #x1000 #x100000010)
          :bytes #()
          :entries (list (cons #x1000 #x1000)
                         (cons #x9000 #x100000010))
          :expired-p nil))
       (gpu (mezzano.supervisor.virtio-gpu::make-mock-gpu))
       (virgl (make-instance 'virgl :gpu gpu)))
  (multiple-value-bind (successp error)
      (virgl-attach-dma-buffer-backing-1 virgl 77 target)
    (assert-true successp "SG backing submit failed")
    (assert-equal nil error "SG backing success error value"))
  (let* ((submission (first *raw-submissions*))
         (request-dma (first submission))
         (request-length (second submission))
         (bytes (mezzano.supervisor::host-dma-bytes request-dma)))
    (assert-equal 80 request-length "SG backing request length")
    (assert-equal gpu:+virtio-gpu-cmd-resource-attach-backing+
                  (ext:ub32ref/le bytes gpu:+virtio-gpu-ctrl-hdr-type+)
                  "SG backing request type")
    (assert-equal 0 (ext:ub32ref/le bytes gpu:+virtio-gpu-ctrl-hdr-flags+)
                  "SG backing flags")
    (assert-equal 0 (ext:ub64ref/le bytes gpu:+virtio-gpu-ctrl-hdr-fence-id+)
                  "SG backing fence")
    (assert-equal 0 (ext:ub32ref/le bytes gpu:+virtio-gpu-ctrl-hdr-ctx-id+)
                  "SG backing context")
    (assert-equal 0 (ext:ub32ref/le bytes 20) "control header padding")
    (assert-equal 77 (ext:ub32ref/le bytes 24) "backing resource id")
    (assert-equal 3 (ext:ub32ref/le bytes 28) "backing entry count")
    (assert-equal #x1000 (ext:ub64ref/le bytes 32) "entry 0 address")
    (assert-equal #x1000 (ext:ub32ref/le bytes 40) "entry 0 length")
    (assert-equal 0 (ext:ub32ref/le bytes 44) "entry 0 padding")
    (assert-equal #x9000 (ext:ub64ref/le bytes 48) "entry 1 address")
    (assert-equal #xFFFFFFFF (ext:ub32ref/le bytes 56) "entry 1 length")
    (assert-equal 0 (ext:ub32ref/le bytes 60) "entry 1 padding")
    (assert-equal #x100008FFF (ext:ub64ref/le bytes 64)
                  "entry 2 address")
    (assert-equal #x11 (ext:ub32ref/le bytes 72) "entry 2 length")
    (assert-equal 0 (ext:ub32ref/le bytes 76) "entry 2 padding")
    (assert-true (member request-dma sup::*released-dma-buffers*)
                 "Temporary backing request DMA was not released")))

;; Device failures are returned after releasing the temporary request buffer.
(let* ((*raw-submit-result* '(nil #x1205))
       (*raw-submissions* '())
       (target
         (mezzano.supervisor::make-host-dma
          :length 0 :bytes #() :entries (list (cons #x5000 0))))
       (virgl
         (make-instance
          'virgl :gpu (mezzano.supervisor.virtio-gpu::make-mock-gpu))))
  (multiple-value-bind (successp error)
      (virgl-attach-dma-buffer-backing-1 virgl 88 target)
    (assert-true (not successp) "Backing device error was ignored")
    (assert-equal #x1205 error "Backing device error code"))
  (assert-equal 1
                (ext:ub32ref/le
                 (mezzano.supervisor::host-dma-bytes
                  (first (first *raw-submissions*)))
                28)
                "Zero-length compatibility entry count"))

;; Once the request DMA exists, mapping or encoding failures must release it
;; exactly once and must never reach the virtqueue submission path.
(let* ((released-before (length sup::*released-dma-buffers*))
       (*raw-submissions* '())
       (ext::*ub32-write-error-p* t)
       (target
         (mezzano.supervisor::make-host-dma
          :length 8 :bytes #() :entries (list (cons #x6000 8))))
       (virgl
         (make-instance
          'virgl :gpu (mezzano.supervisor.virtio-gpu::make-mock-gpu))))
  (handler-case
      (progn
        (virgl-attach-dma-buffer-backing-1 virgl 89 target)
        (error "Injected backing encoding failure was ignored"))
    (error (condition)
      (unless (search "Injected ub32 encoding failure"
                      (princ-to-string condition))
        (error condition))))
  (assert-equal (1+ released-before)
                (length sup::*released-dma-buffers*)
                "Encoding-failure request DMA release count")
  (assert-equal nil *raw-submissions*
                "Encoding failure reached raw submission"))

;; Reset creates the wrapper once, then mutates that same object when the GPU's
;; framebuffer storage and dimensions change.
(let* ((framebuffer-a
         (mezzano.supervisor::make-host-dma
          :length 1200 :bytes #() :entries (list (cons #x1000 1200))))
       (framebuffer-b
         (mezzano.supervisor::make-host-dma
          :length 3200 :bytes #() :entries (list (cons #x9000 3200))))
       (gpu
         (mezzano.supervisor.virtio-gpu::make-mock-gpu
          :width 20 :height 15 :framebuffer framebuffer-a
          :framebuffer-format :b8g8r8a8-unorm))
       (virgl (make-instance 'virgl :gpu gpu)))
  (virgl-reset-1 virgl)
  (let ((scanout (virgl-%scanout virgl)))
    (assert-equal 20 (width scanout) "initial scanout width")
    (assert-equal 15 (height scanout) "initial scanout height")
    (assert-true (eq framebuffer-a (resource-dma-buffer scanout))
                 "initial scanout backing")
    (setf (mezzano.supervisor.virtio-gpu::mock-gpu-width gpu) 40
          (mezzano.supervisor.virtio-gpu::mock-gpu-height gpu) 20
          (mezzano.supervisor.virtio-gpu::mock-gpu-framebuffer gpu)
          framebuffer-b
          (mezzano.supervisor.virtio-gpu::mock-gpu-framebuffer-format gpu)
          :r8g8b8a8-unorm)
    (virgl-reset-1 virgl)
    (assert-true (eq scanout (virgl-%scanout virgl))
                 "Scanout identity changed during resize")
    (assert-equal 40 (width scanout) "resized scanout width")
    (assert-equal 20 (height scanout) "resized scanout height")
    (assert-equal :r8g8b8a8-unorm (texture-format scanout)
                  "resized scanout format")
    (assert-equal t (texture-render-target-p scanout)
                  "resized scanout render-target state")
    (assert-true (eq framebuffer-b (resource-dma-buffer scanout))
                 "resized scanout backing")
    (assert-equal 123 (resource-id scanout) "scanout resource id")
    (assert-equal 2 *capset-generation* "capset refresh count")))

(format t "virgl scanout resize and SG backing tests passed~%")
'''

output.write_text(fixture + "\n" + "\n\n".join(forms) + tests,
                  encoding="utf-8")
PY

"$sbcl" --noinform --disable-debugger --script "$test_file"
