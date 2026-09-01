#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${OHCI_SOURCE:-"$repo_root/drivers/usb/ohci.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-ohci-semantics.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

python3 - "$source_file" "$test_file" <<'PY'
from pathlib import Path
import re
import sys

source_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
source = source_path.read_text(encoding="utf-8")


def extract_form(marker):
    start = source.find(marker)
    if start < 0:
        raise SystemExit(f"Missing OHCI form: {marker}")
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
    raise SystemExit(f"Unterminated OHCI form: {marker}")

markers = [
    "(defmacro validate-address/16",
    "(defconstant +interrupt-done-head+",
    "(defconstant +interrupt-start-of-frame+",
    "(defconstant +endpt-header+",
    "(defconstant +endpt-tdq-tail+",
    "(defconstant +endpt-tdq-head+",
    "(defconstant +endpt-next-ed+",
    "(defconstant +endpt-speed+",
    "(defconstant +endpt-skip+",
    "(defconstant +endpt-full-speed+",
    "(defconstant +endpt-low-speed+",
    "(defconstant +endpt-active+",
    "(defconstant +endpt-inactive+",
    "(defconstant +endpt-halted+",
    "(defconstant +endpt-toggle-carry+",
    "(defconstant +td-header+",
    "(defconstant +td-buffer-pointer+",
    "(defconstant +td-next-td+",
    "(defconstant +td-buffer-end+",
    "(defconstant +ohci-page-size+",
    "(defconstant +td-condition-code+",
    "(defconstant +condition-codes+",
    "(defun ed-header",
    "(defun (setf ed-header)",
    "(defun ed-tdq-tail",
    "(defun (setf ed-tdq-tail)",
    "(defun ed-tdq-head",
    "(defun ed-tdq-head-tdq-addr",
    "(defun (setf ed-tdq-head)",
    "(defun ed-next-ed",
    "(defun (setf ed-next-ed)",
    "(defun td-header",
    "(defun (setf td-header)",
    "(defun td-buffer-pointer",
    "(defun (setf td-buffer-pointer)",
    "(defun td-next-td",
    "(defun (setf td-next-td)",
    "(defun td-buffer-end",
    "(defun (setf td-buffer-end)",
    "(defun td-condition-code",
    "(defun td-buffer-remaining-bytes",
    "(defun td-xfer-bytes",
    "(defun td-buf-info",
    "(defun wait-for-next-sof",
    "(defun clear-ed-halted",
    "(defun recover-completed-ed",
    "(defun advance-ed-head",
    "(defun dequeue-bulk-td",
    "(defun handle-interrupt-endpt",
    "(defun handle-bulk-endpt",
    "(defconstant +control-transfer-timeout+",
    "(defstruct (control-completion",
    "(defun make-control-completion",
    "(defun control-completion-wait",
    "(defun disown-control-buffer",
    "(defun reclaim-control-completion",
    "(defun complete-control-td",
    "(defun reset-dummy-td",
    "(defun cancel-control-stage",
    "(defun wait-for-control-stage",
    "(defvar *done-heads*",
    "(defvar *done-errors*",
    "(defun collect-done-tds",
    "(defun process-done-td",
    "(defun process-done-tds",
    "(defun record-done-error",
    "(defun service-done-list",
    "(defmethod handle-interrupt-event\n    ((type (eql :writeback-done))",
    "(defun find-minimum-int-node",
    "(defun propagate-bandwidth-to-previous",
    "(defun propagate-bandwidth-to-next",
    "(defconstant +interval->int-level+",
    "(defun interrupt-bandwidth",
    "(defun %add-interrupt-ed",
    "(defun add-interrupt-ed",
    "(defun %remove-interrupt-ed",
    "(defun remove-interrupt-ed",
]
forms = [extract_form(marker) for marker in markers]

# These checks only prove the tested cores remain wired into both public paths.
integration_contracts = {
    "receive setup timeout": r"defmethod control-receive-data.*wait-for-control-stage\s+ohci ed msg-td dummy-td completion :setup",
    "receive data timeout": r"defmethod control-receive-data.*wait-for-control-stage\s+ohci ed msg-td dummy-td completion :data-in",
    "send setup timeout": r"defmethod control-send-data.*wait-for-control-stage\s+ohci ed msg-td dummy-td completion :setup",
    "send data timeout": r"defmethod control-send-data.*wait-for-control-stage\s+ohci ed msg-td dummy-td completion :data-out",
    "interrupt recovery": r"defun handle-interrupt-endpt.*recover-completed-ed ed condition-code",
    "bulk recovery": r"defun handle-bulk-endpt.*recover-completed-ed \(ohci-endpoint-ed endpoint\) condition-code",
    "bulk dequeue core": r"defmethod bulk-dequeue-buf.*dequeue-bulk-td ohci ed buf",
    "WDH service boundary": r"\(service-done-list\s+done-head",
}
for description, pattern in integration_contracts.items():
    if not re.search(pattern, source, re.S):
        raise SystemExit(f"OHCI source does not wire {description}")

prelude = r'''
(defpackage :sync
  (:use :cl)
  (:export #:make-semaphore #:wait-for-objects-with-timeout
           #:semaphore-down #:semaphore-up))
(in-package :sync)
(defstruct (semaphore (:constructor %make-semaphore ())) (value 0))
(defun make-semaphore (&key name) (declare (ignore name)) (%make-semaphore))
(defun wait-for-objects-with-timeout (timeout semaphore)
  (declare (ignore timeout))
  (plusp (semaphore-value semaphore)))
(defun semaphore-down (semaphore &key wait-p)
  (declare (ignore wait-p))
  (when (plusp (semaphore-value semaphore))
    (decf (semaphore-value semaphore))
    t))
(defun semaphore-up (semaphore) (incf (semaphore-value semaphore)) t)

(defpackage :sup (:use :cl) (:export #:make-mutex #:with-mutex #:debug-print-line))
(in-package :sup)
(defun make-mutex (name) (declare (ignore name)) nil)
(defmacro with-mutex ((mutex) &body body) `(progn (progn ,mutex) ,@body))
(defun debug-print-line (&rest args) (declare (ignore args)) nil)

(defpackage :sys.int (:use :cl))
(in-package :sys.int)
(defvar *cold-stream* *error-output*)
(defvar *dma-log* nil)
(defun dma-write-barrier () (push :barrier *dma-log*) nil)

(defpackage :mezzano.driver.usb.ohci (:use :cl))
(in-package :mezzano.driver.usb.ohci)
(defmacro with-hcd-access ((ohci) &body body) `(progn (progn ,ohci) ,@body))
(defmacro with-trace-level ((level) &body body) `(progn (progn ,level) ,@body))
(defstruct ohci (status 0) (status-reads 0) (done-head 0) (interrupt-enable 0)
                (td->xfer-info (make-hash-table :test #'eq)) buf-pool levels)
(defstruct xfer-info event-type endpoint buf-size buf)
(defstruct ohci-endpoint type driver num device ed buf-size event-type header interval)
(defstruct int-node ed (bandwidth 0) prev1 prev2 next)
(defvar *physical->array* (make-hash-table))
(defvar *array->physical* (make-hash-table :test #'eq))
(defvar *next-physical-address* #x1000)
(defvar *events* nil)
(defvar *sequence* nil)
(defvar *freed* nil)
(defvar *transfer-failures* nil)
(defun array->phys-addr (array)
  (or (gethash array *array->physical*)
      (let ((address (prog1 *next-physical-address*
                       (incf *next-physical-address* #x10))))
        (setf (gethash array *array->physical*) address
              (gethash address *physical->array*) array)
        address)))
(defun phys-addr->array (address) (gethash address *physical->array*))
(defun free-buffer (buffer) (push (list :free-buffer buffer) *freed*))
(defun free-td (ohci td)
  (remhash td (ohci-td->xfer-info ohci))
  (push (list :free-td td) *freed*))
(defun td->xfer-info (ohci) (ohci-td->xfer-info ohci))
(defun buf-pool (ohci) (ohci-buf-pool ohci))
(defun alloc-buffer/8 (pool size)
  (declare (ignore pool))
  (let ((buffer (make-array size :element-type '(unsigned-byte 8)
                                 :initial-element 0)))
    (array->phys-addr buffer)
    buffer))
(defun array-total-bytes (array) (length array))
(defun get-interrupt-status (ohci)
  (incf (ohci-status-reads ohci))
  (if (plusp (ohci-status-reads ohci))
      (dpb 1 (byte 1 2) (ohci-status ohci))
      (ohci-status ohci)))
(defun (setf get-interrupt-status) (value ohci)
  (when (= value (dpb 1 (byte 1 2) 0))
    (push :sof-clear sys.int::*dma-log*))
  (when (= value (dpb 1 (byte 1 1) 0)) (push :ack *sequence*))
  (setf (ohci-status ohci) 0
        (ohci-status-reads ohci) 0))
(defun hcca-done-head (ohci) (ohci-done-head ohci))
(defun get-interrupt-enable (ohci) (ohci-interrupt-enable ohci))
(defun (setf get-interrupt-enable) (value ohci)
  (setf (ohci-interrupt-enable ohci) value)
  (push :enable *sequence*)
  value)
(defgeneric handle-interrupt-event (type ohci event))
(defun transfer-complete (driver event-type endpoint-number device status length buffer)
  (declare (ignore driver endpoint-number device status length buffer))
  (push (list :callback event-type) *events*)
  (push (list :callback event-type) *sequence*)
  (when (member event-type *transfer-failures*)
    (error "injected callback failure")))
(defun level (ohci index) (aref (ohci-levels ohci) index))
(defun 32ms-interrupts (ohci) (level ohci 0))
(defun 16ms-interrupts (ohci) (level ohci 1))
(defun 8ms-interrupts (ohci) (level ohci 2))
(defun 4ms-interrupts (ohci) (level ohci 3))
(defun 2ms-interrupts (ohci) (level ohci 4))
(defun 1ms-interrupts (ohci) (level ohci 5))
(defun check (condition description)
  (unless condition (error "Check failed: ~A" description)))
(defun check-equal (expected actual description)
  (unless (equal expected actual)
    (error "~A: expected ~S, got ~S" description expected actual)))
'''

postlude = r'''
(defun make-ed () (make-array 4 :initial-element 0))
(defun make-td () (make-array 4 :initial-element 0))

;; Transfer accounting executes the production routines, including the
;; non-contiguous two-page rule.
(let ((td (make-td)))
  (setf (td-buffer-pointer td) #x2FF0 (td-buffer-end td) #x900F)
  (check-equal 32 (td-buffer-remaining-bytes td) "non-contiguous remaining")
  (check-equal 32 (td-xfer-bytes td 64) "non-contiguous transfer")
  (multiple-value-bind (buffer count) (td-buf-info td :buffer 64)
    (check-equal :buffer buffer "buffer identity")
    (check-equal 32 count "buffer count")))

;; The real SOF waiter clears status, polls in 1ms units, and observes the mock
;; register's next-frame transition.
(let ((ohci (make-ohci)))
  (wait-for-next-sof ohci)
  (check (plusp (ohci-status-reads ohci)) "SOF register was polled"))

(defun run-control-timeout (stage late-p owned-buffer)
  (let* ((ohci (make-ohci))
         (ed (make-ed))
         (msg (make-td))
         (dummy (make-td))
         (msg-address (array->phys-addr msg))
         (dummy-address (array->phys-addr dummy))
         (completion (make-control-completion owned-buffer)))
    (setf sys.int::*dma-log* nil
          (ed-header ed) #x1234
          (ed-tdq-head ed) (if late-p dummy-address msg-address)
          (ed-tdq-tail ed) dummy-address)
    (handler-case
        (progn
          (wait-for-control-stage ohci ed msg dummy completion stage)
          (error "timeout was not raised"))
      (error (condition)
        (check (search "timed out" (princ-to-string condition))
               "stage timeout was reported")))
    (check-equal #x1234 (ed-header ed) "ED header restored")
    (check-equal dummy-address (ed-tdq-head-tdq-addr ed) "dummy head rebuilt")
    (check-equal dummy-address (ed-tdq-tail ed) "dummy tail rebuilt")
    (let ((ordering (reverse sys.int::*dma-log*)))
      (check-equal '(:barrier :sof-clear) (subseq ordering 0 2)
                   "control Skip barrier precedes SOF wait")
      (check-equal :barrier (car (last ordering))
                   "control queue publication precedes unquiesce"))
    (if late-p
        (progn
          (check-equal :cancelled (control-completion-state completion)
                       "late TD remains cancellation-owned")
          (complete-control-td ohci
                               (make-xfer-info :event-type completion)
                               msg)
          (check-equal :reclaimed (control-completion-state completion)
                       "late TD reclaimed by done handler"))
        (check-equal :reclaimed (control-completion-state completion)
                     "unretired TD reclaimed synchronously"))
    completion))

(let* ((receive-setup-buffer (vector :receive-setup))
       (send-setup-buffer (vector :send-setup))
       (receive-setup (run-control-timeout :setup nil receive-setup-buffer))
       (send-setup (run-control-timeout :setup t send-setup-buffer))
       (data-in (run-control-timeout :data-in t nil))
       (data-out (run-control-timeout :data-out nil nil))
       (fresh (make-control-completion)))
  (declare (ignore receive-setup data-out))
  (check (find (list :free-buffer receive-setup-buffer) *freed* :test #'equal)
         "receive setup buffer reclaimed")
  (check (find (list :free-buffer send-setup-buffer) *freed* :test #'equal)
         "send setup buffer reclaimed after late completion")
  (check (not (eq (control-completion-semaphore send-setup)
                  (control-completion-semaphore data-in)))
         "stages own distinct completion tokens")
  (check (not (control-completion-wait fresh 0))
         "late completion leaves no stale credit for next stage"))

;; Execute the production bulk dequeue core against a physical-address map.
(let* ((ohci (make-ohci))
       (ed (make-ed))
       (first (make-td))
       (target (make-td))
       (dummy (make-td))
       (buffer (vector :target))
       (first-address (array->phys-addr first))
       (target-address (array->phys-addr target))
       (dummy-address (array->phys-addr dummy)))
  (setf sys.int::*dma-log* nil
        (td-next-td first) target-address
        (td-next-td target) dummy-address
        (ed-header ed) #x55
        (ed-tdq-head ed) first-address
        (ed-tdq-tail ed) dummy-address
        (gethash first (td->xfer-info ohci)) (make-xfer-info :buf (vector :other))
        (gethash target (td->xfer-info ohci)) (make-xfer-info :buf buffer))
  (check (dequeue-bulk-td ohci ed buffer) "bulk transfer dequeued")
  (check-equal dummy-address (td-next-td first) "bulk predecessor relinked")
  (check-equal #x55 (ed-header ed) "bulk ED unquiesced")
  (let ((ordering (reverse sys.int::*dma-log*)))
    (check-equal '(:barrier :sof-clear) (subseq ordering 0 2)
                 "bulk Skip barrier precedes SOF wait")
    (check-equal :barrier (car (last ordering))
                 "bulk relink publication precedes unquiesce"))
  (check (find (list :free-td target) *freed* :test #'equal)
         "bulk TD reclaimed"))

;; Direct recovery coverage: success preserves the head, error clears Halted
;; while retaining toggle carry. The actual interrupt and bulk handlers below
;; exercise the same production helper through process-done-td.
(let ((ed (make-ed)))
  (setf (aref ed +endpt-tdq-head+) #x1003)
  (recover-completed-ed ed 0)
  (check-equal #x1003 (aref ed +endpt-tdq-head+) "success leaves ED unchanged")
  (recover-completed-ed ed 4)
  (check-equal #x1002 (aref ed +endpt-tdq-head+) "error clears only Halted"))

;; Hardware order is newest bulk -> iso -> interrupt callback. The service
;; reverses it, isolates both injected errors, still runs bulk recovery, and
;; ACKs only after all captured TDs have been attempted.
(let* ((ohci (make-ohci))
       (callback-td (make-td))
       (iso-td (make-td))
       (bulk-td (make-td))
       (int-msg (make-td))
       (int-ed (make-ed))
       (bulk-ed (make-ed))
       (callback-address (array->phys-addr callback-td))
       (iso-address (array->phys-addr iso-td))
       (bulk-address (array->phys-addr bulk-td))
       (int-msg-address (array->phys-addr int-msg))
       (int-endpoint (make-ohci-endpoint :type :interrupt :ed int-ed
                                         :buf-size 8 :event-type :callback
                                         :header 0 :num 1))
       (iso-endpoint (make-ohci-endpoint :type :isochronous))
       (bulk-endpoint (make-ohci-endpoint :type :bulk :ed bulk-ed
                                           :event-type :bulk :num 2)))
  (setf *events* nil *sequence* nil *done-errors* nil
        *transfer-failures* '(:callback)
        (ohci-done-head ohci) bulk-address
        (td-next-td bulk-td) iso-address
        (td-next-td iso-td) callback-address
        (td-next-td callback-td) 0
        (td-header callback-td) (dpb 4 +td-condition-code+ 0)
        (td-header bulk-td) (dpb 4 +td-condition-code+ 0)
        (td-buffer-pointer callback-td) 0
        (td-buffer-pointer bulk-td) 0
        (aref int-ed +endpt-tdq-head+) #x2003
        (ed-tdq-tail int-ed) int-msg-address
        (aref bulk-ed +endpt-tdq-head+) #x3003
        (gethash callback-td (td->xfer-info ohci))
        (make-xfer-info :event-type :callback :endpoint int-endpoint
                        :buf-size 8 :buf (make-array 8))
        (gethash int-msg (td->xfer-info ohci)) (make-xfer-info)
        (gethash iso-td (td->xfer-info ohci))
        (make-xfer-info :event-type :iso :endpoint iso-endpoint)
        (gethash bulk-td (td->xfer-info ohci))
        (make-xfer-info :event-type :bulk :endpoint bulk-endpoint
                        :buf-size 8 :buf (make-array 8)))
  (handle-interrupt-event :writeback-done ohci nil)
  (let ((chronological (reverse *sequence*)))
    (check-equal '(:callback :callback) (first chronological)
                 "callback attempted first")
    (check-equal '(:callback :bulk) (second chronological)
                 "later bulk completion still dispatched")
    (check-equal '(:ack :enable) (last chronological 2)
                 "WDH ACK and re-enable follow captured completions")
    (check-equal 2 (length *done-errors*)
                 "callback and iso errors recorded"))
  (check-equal #x2002 (aref int-ed +endpt-tdq-head+)
               "interrupt ED recovered before callback failure")
  (check-equal #x3002 (aref bulk-ed +endpt-tdq-head+)
               "bulk ED recovered after earlier errors")
  (check (find (list :free-td bulk-td) *freed* :test #'equal)
         "bulk handler reclaimed TD"))

;; A failure while capturing the hardware list is not acknowledged, preserving
;; the controller state for diagnosis/retry rather than silently losing it.
(let ((ohci (make-ohci :done-head #xDEAD)))
  (setf *sequence* nil)
  (handler-case
      (progn
        (handle-interrupt-event :writeback-done ohci nil)
        (error "invalid done list unexpectedly succeeded"))
    (error () nil))
  (check (not (member :ack *sequence*))
         "capture failure remains unacknowledged"))

;; Production periodic add/remove wrappers select the interval, link/unlink the
;; ED, and symmetrically propagate bandwidth.
(let* ((levels (make-array 6))
       (ohci (make-ohci :levels levels))
       (anchor (make-ed))
       (node (make-int-node :ed anchor))
       (ed (make-ed)))
  (dotimes (index 6)
    (setf (aref levels index) (vector (make-int-node :ed (make-ed)))))
  (setf (aref levels 5) (vector node)
        (ed-header ed) (dpb +endpt-full-speed+ +endpt-speed+ 0))
  (add-interrupt-ed ohci ed 64 1)
  (check-equal (array->phys-addr ed) (ed-next-ed anchor) "periodic ED linked")
  (check-equal 512 (int-node-bandwidth node) "periodic bandwidth charged")
  (remove-interrupt-ed ohci ed 64 1)
  (check-equal 0 (ed-next-ed anchor) "periodic ED unlinked")
  (check-equal 0 (int-node-bandwidth node) "periodic bandwidth released"))

;; Mutation-negative: the oracle must reject the former ACK-first behavior.
(let ((mutant-events nil))
  (labels ((mutant-service (items)
             (push :ack mutant-events)
             (dolist (item items) (push item mutant-events))))
    (mutant-service '(:first :second))
    (check (not (equal (reverse mutant-events) '(:first :second :ack)))
           "ordering oracle rejects ACK-first mutation")))

(format t "OHCI production semantics passed~%")
'''
output_path.write_text(prelude + "\n" + "\n".join(forms) + "\n" + postlude,
                       encoding="utf-8")
PY

"$sbcl" --noinform --disable-debugger --script "$test_file"
echo "OHCI source integration contract passed"

if [[ ${OHCI_MUTATION_RUN:-0} != 1 ]]; then
  mutant_source=$(mktemp "${TMPDIR:-/tmp}/lambda64-ohci-mutant.XXXXXX.lisp")
  python3 - "$source_file" "$mutant_source" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding="utf-8")
old = '''  (process-done-tds
   (collect-done-tds done-head resolver)
   processor
   error-recorder)
  (funcall acknowledger))'''
new = '''  (funcall acknowledger)
  (process-done-tds
   (collect-done-tds done-head resolver)
   processor
   error-recorder))'''
if old not in source:
    raise SystemExit("Unable to construct WDH ACK-order mutant")
Path(sys.argv[2]).write_text(source.replace(old, new, 1), encoding="utf-8")
PY
  if OHCI_SOURCE="$mutant_source" OHCI_MUTATION_RUN=1 \
       "$0" >/dev/null 2>&1; then
    rm -f "$mutant_source"
    echo "OHCI mutation-negative unexpectedly passed" >&2
    exit 1
  fi
  rm -f "$mutant_source"
  echo "OHCI mutation-negative rejected ACK-before-dispatch"
fi
