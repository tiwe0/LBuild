#!/usr/bin/env bash
# Regression coverage for the virtio-block FLUSH request path.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${VIRTIO_BLOCK_SOURCE:-"$repo_root/supervisor/virtio-block.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-virtio-block-flush.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/flush.lisp" "${VIRTIO_BLOCK_FLUSH_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[3]:
    old = "+virtio-block-t-flush+"
    marker = "(defun virtio-block-flush"
    start = source.index(marker)
    offset = source.index(old, start)
    source = source[:offset] + source[offset:].replace(old, "+virtio-block-t-in+", 1)

def extract(marker):
    start = source.index(marker)
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
    raise SystemExit(f"unterminated form starting at {marker!r}")

form = extract("(defun virtio-block-flush")
if "virtio-ring-add-to-avail-ring" not in form:
    raise SystemExit("virtio-block-flush still does not submit a request")
if "+virtio-block-t-flush+" not in form:
    raise SystemExit("virtio-block-flush does not use the FLUSH request type")
Path(sys.argv[2]).write_text(form + "\n", encoding="utf-8")
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals
  (:use :cl)
  (:export #:memref-unsigned-byte-8 #:memref-unsigned-byte-32
           #:memref-unsigned-byte-64))
(in-package :mezzano.internals)

(defvar *memory* (make-hash-table :test #'equal))
(defun memory-key (address width) (list address width))
(defun memref-unsigned-byte-8 (address area)
  (declare (ignore area))
  (gethash (memory-key address 8) *memory* 0))
(defun (setf memref-unsigned-byte-8) (value address area)
  (declare (ignore area))
  (setf (gethash (memory-key address 8) *memory*) value))
(defun memref-unsigned-byte-32 (address area)
  (declare (ignore area))
  (gethash (memory-key address 32) *memory* 0))
(defun (setf memref-unsigned-byte-32) (value address area)
  (declare (ignore area))
  (setf (gethash (memory-key address 32) *memory*) value))
(defun memref-unsigned-byte-64 (address area)
  (declare (ignore area))
  (gethash (memory-key address 64) *memory* 0))
(defun (setf memref-unsigned-byte-64) (value address area)
  (declare (ignore area))
  (setf (gethash (memory-key address 64) *memory*) value))

(defpackage :mezzano.supervisor
  (:use :cl)
  (:export #:ensure #:event-state #:event #:make-event #:event-wait))
(in-package :mezzano.supervisor)
(defun ensure (value) (unless value (error "ENSURE failed")) value)
;; Boot tracing is a no-op on the host; the driver under test emits it.
(defun debug-uart-boot-line (string) (declare (ignore string)) nil)
(defun debug-uart-boot-hex-line (label value)
  (declare (ignore label value)) nil)
(defstruct event (state nil))

(defpackage :mezzano.supervisor.virtio
  (:use :cl)
  (:export #:virtio-virtqueue #:virtio-ring-alloc-descriptor
           #:virtio-ring-free-descriptor #:virtio-ring-add-to-avail-ring
           #:virtio-ring-desc-address #:virtio-ring-desc-length
           #:virtio-ring-desc-flags #:virtio-ring-desc-next
           #:virtio-kick #:+virtio-ring-desc-f-next+ #:+virtio-ring-desc-f-write+))
(in-package :mezzano.supervisor.virtio)

(defconstant +virtio-ring-desc-f-next+ 1)
(defconstant +virtio-ring-desc-f-write+ 2)
(defstruct descriptor address length flags next)
(defstruct (virtqueue (:constructor make-virtqueue ()))
  (descriptors (make-hash-table))
  (next-id 0)
  (freed nil))
(defstruct device virtqueue)
(defun desc (vq id)
  (or (gethash id (virtqueue-descriptors vq))
      (setf (gethash id (virtqueue-descriptors vq)) (make-descriptor))))
(defun virtio-ring-desc-address (vq id) (descriptor-address (desc vq id)))
(defun (setf virtio-ring-desc-address) (value vq id)
  (setf (descriptor-address (desc vq id)) value))
(defun virtio-ring-desc-length (vq id) (descriptor-length (desc vq id)))
(defun (setf virtio-ring-desc-length) (value vq id)
  (setf (descriptor-length (desc vq id)) value))
(defun virtio-ring-desc-flags (vq id) (descriptor-flags (desc vq id)))
(defun (setf virtio-ring-desc-flags) (value vq id)
  (setf (descriptor-flags (desc vq id)) value))
(defun virtio-ring-desc-next (vq id) (descriptor-next (desc vq id)))
(defun (setf virtio-ring-desc-next) (value vq id)
  (setf (descriptor-next (desc vq id)) value))
(defun virtio-virtqueue (device index)
  (declare (ignore index))
  (device-virtqueue device))
(defvar *submitted* nil)
(defvar *kicked* nil)
(defun virtio-ring-alloc-descriptor (vq)
  (let ((id (virtqueue-next-id vq)))
    (incf (virtqueue-next-id vq))
    (setf (gethash id (virtqueue-descriptors vq)) (make-descriptor))
    id))
(defun virtio-ring-free-descriptor (vq id)
  (push id (virtqueue-freed vq)))
(defun virtio-ring-add-to-avail-ring (vq id)
  (declare (ignore vq))
  (push id *submitted*))
(defun virtio-kick (device queue)
  (declare (ignore device))
  (setf *kicked* queue))

(defpackage :mezzano.supervisor.virtio-block
  (:use :cl)
  (:local-nicknames (:sup :mezzano.supervisor)
                    (:virtio :mezzano.supervisor.virtio)
                    (:sys.int :mezzano.internals)))
(in-package :mezzano.supervisor.virtio-block)

(defconstant +virtio-block-req-type+ 0)
(defconstant +virtio-block-req-ioprio+ 4)
(defconstant +virtio-block-req-sector+ 8)
(defconstant +virtio-block-req-status+ 16)
(defconstant +virtio-block-t-in+ 0)
(defconstant +virtio-block-t-flush+ 4)
(defconstant +virtio-block-s-ok+ 0)
(defconstant +virtio-block-s-ioerr+ 1)
(defconstant +virtio-block-s-unsup+ 2)
(defstruct virtio-block virtio-device irq-latch request-phys request-virt)
(defvar *device-status* 0)
(defvar *current-block*)
(defun sup:event-wait (event)
  ;; The fake device writes completion status before waking the driver.
  (setf (sys.int:memref-unsigned-byte-8
         (+ (virtio-block-request-virt *current-block*) +virtio-block-req-status+) 0)
        *device-status*)
  event)
(load (or (sb-ext:posix-getenv "VIRTIO_BLOCK_FLUSH_FORMS")
          (error "VIRTIO_BLOCK_FLUSH_FORMS is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(let* ((vq (mezzano.supervisor.virtio::make-virtqueue))
       (device (mezzano.supervisor.virtio::make-device :virtqueue vq))
       (event (sup:make-event :state t))
       (block (make-virtio-block :virtio-device device
                                  :irq-latch event
                                  :request-phys #x9000
                                  :request-virt #xA000)))
  (setf *current-block* block
        mezzano.supervisor.virtio::*submitted* nil
        mezzano.supervisor.virtio::*kicked* nil
        *device-status* +virtio-block-s-ok+)
  (multiple-value-bind (ok reason) (virtio-block-flush block)
    (check (and ok (eql reason :no-error))
           "successful FLUSH returned ~S/~S" ok reason))
  (let* ((request (first mezzano.supervisor.virtio::*submitted*))
         (status (mezzano.supervisor.virtio::descriptor-next
                  (mezzano.supervisor.virtio::desc vq request))))
    (check (= (sys.int:memref-unsigned-byte-32 #xA000 +virtio-block-req-type+) +virtio-block-t-flush+)
           "request type was not VIRTIO_BLK_T_FLUSH")
    (check (= status 1) "FLUSH did not chain directly to its status descriptor")
    (check (= (length (mezzano.supervisor.virtio::virtqueue-freed vq)) 2)
           "FLUSH did not release exactly two descriptors")
    (check (eql mezzano.supervisor.virtio::*kicked* 0)
           "FLUSH kicked the wrong queue")
    (check (null (sup:event-state event))
           "FLUSH did not clear the IRQ latch")))

(let* ((vq (mezzano.supervisor.virtio::make-virtqueue))
       (device (mezzano.supervisor.virtio::make-device :virtqueue vq))
       (block (make-virtio-block :virtio-device device
                                  :irq-latch (sup:make-event)
                                  :request-phys #xB000
                                  :request-virt #xC000)))
  (setf *current-block* block *device-status* +virtio-block-s-unsup+)
  (multiple-value-bind (ok reason) (virtio-block-flush block)
    (check (and (null ok) (eql reason :unsupported))
           "unsupported FLUSH status was not propagated: ~S/~S" ok reason)))

(format t "virtio-block FLUSH semantics passed~%")
EOF_LISP

VIRTIO_BLOCK_FLUSH_FORMS="$tmp_dir/flush.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${VIRTIO_BLOCK_FLUSH_MUTATION_RUN:-}" ]]; then
  if VIRTIO_BLOCK_FLUSH_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "virtio-block FLUSH mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "virtio-block FLUSH mutation rejected"
fi
