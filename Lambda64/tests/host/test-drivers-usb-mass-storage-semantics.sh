#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${MASS_STORAGE_SOURCE:-"$repo_root/drivers/usb/mass-storage.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-mass-storage.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

python3 - "$source_file" "$test_file" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
output = Path(sys.argv[2])


def extract_form(marker):
    start = source.find(marker)
    if start < 0:
        raise SystemExit(f"Missing mass-storage production form: {marker}")
    depth = 0
    in_string = False
    escaped = False
    in_comment = False
    for index in range(start, len(source)):
        char = source[index]
        if in_comment:
            if char == "\n":
                in_comment = False
            continue
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == ";":
            in_comment = True
        elif char == '"':
            in_string = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise SystemExit(f"Unterminated mass-storage production form: {marker}")

markers = [
    "(defconstant +cbw-cb-length+",
    "(defconstant +cbw-control-block+",
    "(defconstant +cs2-status+",
    "(defconstant +csw-status-success+",
    "(defconstant +csw-status-cmd-failed+",
    "(defconstant +csw-phase-error+",
    "(defconstant +scsi-code-inquiry+",
    "(defconstant +scsi-code-mode-sense/6+",
    "(defconstant +scsi-control-naca+",
    "(defconstant +scsi-mode-sense-dbd+",
    "(defconstant +scsi-mode-page-all+",
    "(defconstant +scsi-mode-device-write-protected+",
    "(defstruct mass-storage",
    "(define-condition mass-storage-transfer-timeout",
    "(defun encode-scsi-inquiry",
    "(defun encode-scsi-mode-sense/6",
    "(defun probe-transfer",
    "(defun parse-inquiry",
    "(defun parse-read-capacity",
    "(defun probe-writable-p",
]
forms = [extract_form(marker) for marker in markers]

contracts = {
    "inquiry command timeout": r"probe-transfer usbd device mass-storage :inquiry :command",
    "inquiry data timeout": r"probe-transfer usbd device mass-storage :inquiry :data-in",
    "inquiry status timeout": r"probe-transfer usbd device mass-storage :inquiry :status",
    "capacity command timeout": r"probe-transfer usbd device mass-storage :read-capacity :command",
    "capacity data timeout": r"probe-transfer usbd device mass-storage :read-capacity :data-in",
    "capacity status timeout": r"probe-transfer usbd device mass-storage :read-capacity :status",
    "writable probe registration": r":writable-p\s+\(probe-writable-p usbd device mass-storage\)",
}
for description, pattern in contracts.items():
    if not re.search(pattern, source, re.S):
        raise SystemExit(f"Mass-storage source does not wire {description}")
if re.search(r"TODO|FIXME", source):
    raise SystemExit("Mass-storage source retains TODO/FIXME markers")

prelude = r'''
(defpackage :sup
  (:use :cl)
  (:export #:make-event #:event-state #:debug-print-line))
(in-package :sup)
(defstruct (event (:constructor make-event (&key name (state nil)))) name state)
(defun debug-print-line (&rest values) (declare (ignore values)) nil)

(defpackage :sys.int (:use :cl))
(in-package :sys.int)
(defvar *cold-stream* *error-output*)

(defpackage :mezzano.driver.usb.mass (:use :cl))
(in-package :mezzano.driver.usb.mass)
(defvar *io-log* nil)
(defvar *wait-result* :complete)
(defvar *mode-byte* 0)
(defvar *csw-status* 0)
(defvar *recovery-count* 0)
(defvar *transfer-count* 0)
(defvar *timeout-on-transfer* nil)
(defmacro with-trace-level ((level) &body body)
  (declare (ignore level body)) nil)
(defun enter-function (name) (declare (ignore name)) nil)
(defun print-buffer (&rest arguments) (declare (ignore arguments)) nil)
(defun get-ascii-string (&rest arguments) (declare (ignore arguments)) "")
(defun get-be-unsigned-word/32 (&rest arguments) (declare (ignore arguments)) 0)
(defun get-be-unsigned-word/64 (&rest arguments) (declare (ignore arguments)) 0)
(defun encode-scsi-read-capacity/10 (&rest arguments)
  (declare (ignore arguments)) nil)
(defun encode-scsi-read-capacity/16 (&rest arguments)
  (declare (ignore arguments)) nil)
(defun (setf get-unsigned-word/16) (value buffer offset)
  (setf (aref buffer offset) (ldb (byte 8 0) value)
        (aref buffer (1+ offset)) (ldb (byte 8 8) value))
  value)
(defmacro with-buffers ((pool bindings) &body body)
  (declare (ignore pool))
  `(let ,(mapcar (lambda (binding)
                   `(,(first binding)
                     (make-array ,(third binding)
                                 :element-type '(unsigned-byte 8)
                                 :initial-element 0)))
                 bindings)
     ,@body))
(defun buf-pool (usbd) (declare (ignore usbd)) nil)
(defun encode-cbw (&rest arguments) (declare (ignore arguments)) nil)
(defun bulk-enqueue-buf (usbd device endpoint buffer length)
  (declare (ignore usbd device))
  (incf *transfer-count*)
  (push (list :enqueue endpoint buffer length) *io-log*))
(defun bulk-dequeue-buf (usbd device endpoint buffer)
  (declare (ignore usbd device))
  (push (list :dequeue endpoint buffer) *io-log*)
  t)
(defun timed-wait (event timeout)
  (declare (ignore event))
  (push (list :wait timeout) *io-log*)
  (if (and *timeout-on-transfer*
           (= *transfer-count* *timeout-on-transfer*))
      :timeout
      *wait-result*))
(defun reset-recovery (&rest arguments)
  (declare (ignore arguments))
  (incf *recovery-count*))
(defun check (condition description)
  (unless condition (error "Check failed: ~A" description)))
(defun check-equal (expected actual description)
  (unless (equal expected actual)
    (error "~A: expected ~S, got ~S" description expected actual)))
'''

postlude = r'''
;; INQUIRY encodes the normal ACA bit explicitly without changing the legacy
;; default. Both paths execute the production encoder.
(let ((buffer (make-array 64 :element-type '(unsigned-byte 8)
                            :initial-element #xAA)))
  (encode-scsi-inquiry buffer 0 nil 0 36)
  (check-equal 0 (aref buffer (+ +cbw-control-block+ 5))
               "INQUIRY defaults NACA off")
  (encode-scsi-inquiry buffer 0 nil 0 36 :naca-p t)
  (check-equal +scsi-control-naca+
               (aref buffer (+ +cbw-control-block+ 5))
               "INQUIRY encodes NACA"))

;; MODE SENSE(6) requests only the four-byte mode header, suppresses block
;; descriptors, and asks for all pages so byte 2 carries the device WP bit.
(let ((buffer (make-array 64 :element-type '(unsigned-byte 8)
                            :initial-element #xAA)))
  (encode-scsi-mode-sense/6 buffer 0 4)
  (check-equal 6 (aref buffer +cbw-cb-length+) "MODE SENSE CDB length")
  (check-equal (list +scsi-code-mode-sense/6+
                     +scsi-mode-sense-dbd+
                     +scsi-mode-page-all+ 0 4 0)
               (loop for index from +cbw-control-block+
                       below (+ +cbw-control-block+ 6)
                     collect (aref buffer index))
               "MODE SENSE CDB bytes"))

;; The production probe transfer clears the event, enqueues, waits, and returns
;; the callback status on success.
(let* ((event (sup:make-event :state t))
       (driver (make-mass-storage :event event :status :usb-success))
       (buffer (make-array 8)))
  (setf *io-log* nil *wait-result* :complete
        *transfer-count* 0 *timeout-on-transfer* nil)
  (check-equal :usb-success
               (probe-transfer :hcd :device driver :inquiry :data-in
                               3 buffer 8 0.25)
               "successful probe transfer status")
  (check (not (sup:event-state event)) "probe event cleared before enqueue")
  (check-equal '((:enqueue 3) (:wait 0.25))
               (mapcar (lambda (entry) (list (first entry) (second entry)))
                       (reverse *io-log*))
               "probe enqueue/wait order"))

;; Timeout removes the dynamic-extent buffer from the controller queue before
;; signalling a structured diagnostic containing operation, stage, endpoint,
;; length, and duration.
(let* ((event (sup:make-event :state t))
       (driver (make-mass-storage :event event))
       (buffer (make-array 31))
       (caught nil))
  (setf *io-log* nil *wait-result* :timeout
        *transfer-count* 0 *timeout-on-transfer* nil)
  (handler-case
      (probe-transfer :hcd :device driver :read-capacity :command
                      7 buffer 31 1.0)
    (mass-storage-transfer-timeout (condition)
      (setf caught condition)))
  (check caught "structured timeout signalled")
  (check-equal :read-capacity (timeout-operation caught) "timeout operation")
  (check-equal :command (timeout-stage caught) "timeout stage")
  (check-equal 7 (timeout-endpoint caught) "timeout endpoint")
  (check-equal 31 (timeout-length caught) "timeout length")
  (check-equal 1.0 (timeout-seconds caught) "timeout duration")
  (let ((message (princ-to-string caught)))
    (dolist (fragment '("READ-CAPACITY" "COMMAND" "7" "31" "1.000"))
      (check (search fragment message) "timeout report context")))
  (check-equal '(:enqueue :wait :dequeue)
               (mapcar #'first (reverse *io-log*))
               "timeout dequeues after wait"))

;; Exercise the same production failure path with every inquiry and capacity
;; phase wired by the driver, rather than treating source matching as coverage.
(dolist (scenario '((:inquiry :command 2 31)
                    (:inquiry :data-in 1 36)
                    (:inquiry :status 1 13)
                    (:read-capacity :command 2 31)
                    (:read-capacity :data-in 1 32)
                    (:read-capacity :status 1 13)))
  (destructuring-bind (operation stage endpoint length) scenario
    (let* ((driver (make-mass-storage :event (sup:make-event)))
           (buffer (make-array length))
           (caught nil))
      (setf *io-log* nil *wait-result* :timeout)
      (handler-case
          (probe-transfer :hcd :device driver operation stage
                          endpoint buffer length)
        (mass-storage-transfer-timeout (condition)
          (setf caught condition)))
      (check caught "phase timeout condition")
      (check-equal operation (timeout-operation caught)
                   "phase timeout operation")
      (check-equal stage (timeout-stage caught) "phase timeout stage")
      (check-equal '(:enqueue :wait :dequeue)
                   (mapcar #'first (reverse *io-log*))
                   "phase timeout cleanup order"))))

;; Execute the two affected production probe routines themselves and inject a
;; timeout at each of their three BOT phases. This proves all six former TODO
;; sites route through the structured condition and dequeue cleanup.
(dolist (scenario '((parse-inquiry :inquiry 1 :command)
                    (parse-inquiry :inquiry 2 :data-in)
                    (parse-inquiry :inquiry 3 :status)
                    (parse-read-capacity :read-capacity 1 :command)
                    (parse-read-capacity :read-capacity 2 :data-in)
                    (parse-read-capacity :read-capacity 3 :status)))
  (destructuring-bind (function operation transfer-index stage) scenario
    (let ((driver (make-mass-storage :event (sup:make-event)
                                     :bulk-in-endpt-num 1
                                     :bulk-out-endpt-num 2))
          (caught nil))
      (setf *io-log* nil *wait-result* :complete *transfer-count* 0
            *timeout-on-transfer* transfer-index)
      (handler-case
          (if (eq function 'parse-inquiry)
              (parse-inquiry :hcd :device driver)
              (parse-read-capacity :hcd :device driver t))
        (mass-storage-transfer-timeout (condition)
          (setf caught condition)))
      (check caught "production probe phase timeout")
      (check-equal operation (timeout-operation caught)
                   "production probe timeout operation")
      (check-equal stage (timeout-stage caught)
                   "production probe timeout stage")
      (check-equal :dequeue (first (first *io-log*))
                   "production probe timeout dequeued buffer"))))
(setf *timeout-on-transfer* nil)

;; Execute the production writable probe while replacing only its transport
;; boundary. The returned MODE SENSE header controls disk writability; CSW
;; failures fail closed, and a phase error also invokes reset recovery.
(let ((original (symbol-function 'probe-transfer)))
  (unwind-protect
       (progn
         (setf (symbol-function 'probe-transfer)
               (lambda (usbd device driver operation stage endpoint buffer length
                        &optional timeout)
                 (declare (ignore usbd device driver operation endpoint length timeout))
                 (case stage
                   (:data-in (setf (aref buffer 2) *mode-byte*))
                   (:status (setf (aref buffer +cs2-status+) *csw-status*)))
                 :success))
         (let ((driver (make-mass-storage :bulk-in-endpt-num 1
                                          :bulk-out-endpt-num 2)))
           (setf *mode-byte* 0 *csw-status* +csw-status-success+)
           (check (probe-writable-p :hcd :device driver)
                  "clear WP bit registers writable")
           (setf *mode-byte* +scsi-mode-device-write-protected+)
           (check (not (probe-writable-p :hcd :device driver))
                  "set WP bit registers read-only")
           (setf *mode-byte* 0 *csw-status* +csw-status-cmd-failed+)
           (check (not (probe-writable-p :hcd :device driver))
                  "failed MODE SENSE fails closed")
           (setf *csw-status* #xFF)
           (check (not (probe-writable-p :hcd :device driver))
                  "invalid CSW fails closed")
           (setf *csw-status* +csw-phase-error+ *recovery-count* 0)
           (check (not (probe-writable-p :hcd :device driver))
                  "phase-error MODE SENSE fails closed")
           (check-equal 1 *recovery-count* "phase error reset recovery")))
    (setf (symbol-function 'probe-transfer) original)))

(format t "USB mass-storage production semantics passed~%")
'''
output.write_text(prelude + "\n" + "\n".join(forms) + "\n" + postlude,
                  encoding="utf-8")
PY

"$sbcl" --noinform --disable-debugger --script "$test_file"
echo "USB mass-storage integration contract passed"

if [[ ${MASS_STORAGE_MUTATION_RUN:-0} != 1 ]]; then
  mutant=$(mktemp "${TMPDIR:-/tmp}/lambda64-mass-storage-mutant.XXXXXX.lisp")
  python3 - "$source_file" "$mutant" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding="utf-8")
old = "      (bulk-dequeue-buf usbd device endpoint buf)\n"
if old not in source:
    raise SystemExit("Unable to construct timeout-cleanup mutant")
Path(sys.argv[2]).write_text(source.replace(old, "", 1), encoding="utf-8")
PY
  if MASS_STORAGE_SOURCE="$mutant" MASS_STORAGE_MUTATION_RUN=1 \
       "$0" >/dev/null 2>&1; then
    rm -f "$mutant"
    echo "Mass-storage timeout-cleanup mutation unexpectedly passed" >&2
    exit 1
  fi
  rm -f "$mutant"
  echo "USB mass-storage mutation-negative rejected missing timeout cleanup"

  invalid_mutant=$(mktemp "${TMPDIR:-/tmp}/lambda64-mass-storage-invalid-csw-mutant.XXXXXX.lisp")
  python3 - "$source_file" "$invalid_mutant" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding="utf-8")
old = '''        (otherwise
         (sup:debug-print-line
          "Mass Storage MODE SENSE returned invalid CSW status "
          (aref status-buf +cs2-status+)
          "; registering read-only")
         nil)))))'''
new = old.replace("         nil)))))", "         t)))))")
if old not in source:
    raise SystemExit("Unable to construct invalid-CSW fail-open mutant")
Path(sys.argv[2]).write_text(source.replace(old, new, 1), encoding="utf-8")
PY
  if MASS_STORAGE_SOURCE="$invalid_mutant" MASS_STORAGE_MUTATION_RUN=1 \
       "$0" >/dev/null 2>&1; then
    rm -f "$invalid_mutant"
    echo "Mass-storage invalid-CSW fail-open mutation unexpectedly passed" >&2
    exit 1
  fi
  rm -f "$invalid_mutant"
  echo "USB mass-storage mutation-negative rejected invalid-CSW fail-open"
fi
