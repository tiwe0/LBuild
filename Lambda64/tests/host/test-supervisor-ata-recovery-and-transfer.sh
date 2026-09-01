#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${ATA_SOURCE:-"$repo_root/supervisor/ata.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-supervisor-ata.XXXXXX.lisp")
mutation_file=
trap 'rm -f "$test_file"; if [[ -n "$mutation_file" ]]; then rm -f "$mutation_file"; fi' EXIT

python3 - "$source_file" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")

required_forms = [
    "(defun ata-timeout-deadline",
    "(defun ata-timeout-expired-p",
    "(defun ata-sector-word-count",
    "(defun ata-copy-memory",
    "(defun ata-reset-controller",
    "(defun ata-complete-dma",
    "(defun ata-read-dma",
]
for form in required_forms:
    if form not in source:
        raise SystemExit(f"Missing ATA recovery/transfer form: {form}")

if re.search(r"TODO|FIXME", source):
    raise SystemExit("ATA source still contains TODO/FIXME markers")

# Timeout loops must use a monotonic absolute deadline rather than subtracting
# an assumed sleep duration.
for name in ("ata-wait-for-controller", "ata-check-status"):
    match = re.search(rf"\(defun {name}\b.*?(?=\n\(defun |\Z)", source, re.S)
    if not match or "ata-timeout-deadline" not in match.group(0):
        raise SystemExit(f"{name} does not use an absolute deadline")
    if "(decf timeout" in match.group(0):
        raise SystemExit(f"{name} still decrements a nominal timeout")

# All protocol waits must observe timeout failure instead of continuing into
# status/data processing.
if source.count("(unless (ata-intrq-wait controller)") < 5:
    raise SystemExit("ATA protocol paths do not propagate IRQ timeout failure")

# PIO and DMA transfer sizes must derive from IDENTIFY logical-sector size.
if source.count("(ata-sector-word-count device)") < 2:
    raise SystemExit("PIO transfer loops are not sector-size aware")
if source.count("(* count (ata-device-block-size device))") < 3:
    raise SystemExit("DMA/bounce byte counts are not sector-size aware")

# Starting the bus master after issuing a DMA command is part of the same
# command helper, so no Lisp call boundary can fall between those writes.
if "bus-master-command" not in source:
    raise SystemExit("LBA command helpers cannot start DMA immediately")
for name in ("ata-read-dma", "ata-write-dma"):
    match = re.search(rf"\(defun {name}\b.*?(?=\n\(defun |\Z)", source, re.S)
    if not match or "+ata-bmr-command-start+" not in match.group(0):
        raise SystemExit(f"{name} does not request immediate DMA start")

# Bounce paths copy exactly the requested byte count and only copy read data
# after a successful DMA operation.
if source.count("(ata-copy-memory") < 3:
    raise SystemExit("Bounce paths do not use exact-length memory copies")
if "%fast-page-copy" in source:
    raise SystemExit("ATA source still performs unconditional whole-page copies")

# Every command-protocol failure marker is replaced by an actual reset call,
# and ATAPI DMA executes Check_Status_B after bus-master completion.
if source.count("(ata-reset-controller controller)") < 8:
    raise SystemExit("ATA failure paths do not consistently reset the channel")
dma_packet = re.search(
    r"\(defun ata-issue-dma-packet-command\b.*?(?=\n\(defun |\Z)", source, re.S
)
if not dma_packet or "ata-complete-dma" not in dma_packet.group(0):
    raise SystemExit("ATAPI DMA does not execute completion status checks")

print("ATA recovery and transfer source contract passed")
PY

python3 - "$source_file" "$test_file" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
output = Path(sys.argv[2])


def extract_form(marker):
    start = source.find(marker)
    if start < 0:
        raise SystemExit(f"Missing ATA host-test form: {marker}")
    depth = 0
    in_string = False
    escaped = False
    in_comment = False
    index = start
    while index < len(source):
        char = source[index]
        if in_comment:
            if char == "\n":
                in_comment = False
        elif in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif char == ";":
            in_comment = True
        elif char == '"':
            in_string = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
        index += 1
    raise SystemExit(f"Unterminated ATA host-test form: {marker}")


markers = [
    "(defconstant +ata-register-count+",
    "(defconstant +ata-register-data+",
    "(defconstant +ata-register-error+",
    "(defconstant +ata-register-features+",
    "(defconstant +ata-register-lba-low+",
    "(defconstant +ata-register-lba-mid+",
    "(defconstant +ata-register-lba-high+",
    "(defconstant +ata-register-device+",
    "(defconstant +ata-register-command+",
    "(defconstant +ata-register-alt-status+",
    "(defconstant +ata-register-device-control+",
    "(defconstant +ata-bmr-command+",
    "(defconstant +ata-bmr-status+",
    "(defconstant +ata-bmr-prdt-address+",
    "(defconstant +ata-bmr-command-start+",
    "(defconstant +ata-bmr-direction-read/write+",
    "(defconstant +ata-bmr-status-error+",
    "(defconstant +ata-bmr-status-interrupt+",
    "(defconstant +ata-dev+",
    "(defconstant +ata-lba+",
    "(defconstant +ata-err+",
    "(defconstant +ata-drq+",
    "(defconstant +ata-df+",
    "(defconstant +ata-bsy+",
    "(defconstant +ata-nien+",
    "(defconstant +ata-srst+",
    "(defconstant +ata-command-read-sectors+",
    "(defconstant +ata-command-read-sectors-ext+",
    "(defconstant +ata-command-read-dma+",
    "(defconstant +ata-command-read-dma-ext+",
    "(defconstant +ata-command-write-sectors+",
    "(defconstant +ata-command-write-sectors-ext+",
    "(defconstant +ata-command-write-dma+",
    "(defconstant +ata-command-write-dma-ext+",
    "(defconstant +ata-command-flush-cache+",
    "(defconstant +ata-command-flush-cache-ext+",
    "(defconstant +ata-command-packet+",
    "(defconstant +ata-prdt-max-entries+",
    "(defparameter *ata-command-timeout*",
    "(defparameter *ata-flush-timeout*",
    "(defstruct (ata-controller",
    "(defstruct (ata-device",
    "(defstruct (atapi-device",
    "(defun ata-error",
    "(defun ata-alt-status",
    "(defun ata-timeout-deadline",
    "(defun ata-timeout-expired-p",
    "(defun ata-timeout-sleep",
    "(defun ata-identify-logical-sector-size",
    "(defun ata-select-device",
    "(defun ata-issue-lba28-command",
    "(defun ata-issue-lba48-command",
    "(defun ata-check-status",
    "(defun ata-intrq-wait",
    "(defun ata-reset-controller",
    "(defun ata-sector-word-count",
    "(defun ata-copy-memory",
    "(defun ata-pio-data-in",
    "(defun ata-pio-data-out",
    "(defun ata-configure-prdt",
    "(defun ata-read-write",
    "(defun ata-issue-lba-command",
    "(defun ata-complete-dma",
    "(defun ata-read-dma",
    "(defun ata-flush",
    "(defun ata-submit-packet-command",
    "(defun ata-issue-pio-packet-command",
    "(defun ata-issue-dma-packet-command",
    "(defun ata-issue-packet-command",
]
forms = [extract_form(marker).replace("\n             (:area :wired)", "")
         for marker in markers]

output.write_text(r'''
(in-package :cl-user)
(defvar *ata-io-log* nil)

(defpackage :mezzano.supervisor
  (:use :cl)
  (:export #:ensure #:safe-sleep #:debug-print-line #:event-state
           #:timer-arm #:watcher-wait #:timer-expired-p
           #:timer-disarm-absolute))
(in-package :mezzano.supervisor)
(defmacro ensure (condition &rest message)
  `(unless ,condition (error "ENSURE failed: ~S" ',message)))
(defun safe-sleep (seconds) (declare (ignore seconds)))
(defun debug-print-line (&rest arguments) (declare (ignore arguments)))
(defstruct event state)
(defstruct timer armed-p expired-p)
(defvar *interrupt-results* nil)
(defvar *active-irq-event* nil)
(defvar *active-timer* nil)
(defvar *watcher-waits* 0)
(defun timer-arm (timeout timer)
  (declare (ignore timeout))
  (setf (timer-armed-p timer) t
        (timer-expired-p timer) nil))
(defun watcher-wait (watcher)
  (declare (ignore watcher))
  (incf *watcher-waits*)
  (let ((interrupted-p (pop *interrupt-results*)))
    (setf (event-state *active-irq-event*) interrupted-p)
    (unless interrupted-p
      (setf (timer-expired-p *active-timer*) t))))
(defun timer-disarm-absolute (timer)
  (setf (timer-armed-p timer) nil))
(defconstant +physical-map-base+ 1000000)
(defconstant +4k-page-size+ 4096)
(defun convert-to-pmap-address (address) address)

(defpackage :mezzano.supervisor.pci
  (:use :cl)
  (:export #:pci-io-region/8 #:pci-io-region/32))
(in-package :mezzano.supervisor.pci)
(defvar *writes* nil)
(defvar *registers* (make-hash-table :test 'equal))
(defun pci-io-region/8 (region register)
  (push (list :bmr-read region register) cl-user::*ata-io-log*)
  (gethash (list region register) *registers* 0))
(defun (setf pci-io-region/8) (value region register)
  (push (list :bmr region register value) *writes*)
  (push (list :bmr-write region register value) cl-user::*ata-io-log*)
  (if (= register 2)
      (setf (gethash (list region register) *registers*)
            (logand (gethash (list region register) *registers* 0)
                    (lognot value)))
      (setf (gethash (list region register) *registers*) value)))
(defun pci-io-region/32 (region register)
  (gethash (list region register) *registers* 0))
(defun (setf pci-io-region/32) (value region register)
  (push (list :bmr32-write region register value) cl-user::*ata-io-log*)
  (setf (gethash (list region register) *registers*) value))

(defpackage :mezzano.internals
  (:use :cl)
  (:export #:io-port/8 #:io-port/16 #:memref-unsigned-byte-8
           #:memref-unsigned-byte-16 #:memref-unsigned-byte-32
           #:simple-vector-length))
(in-package :mezzano.internals)
(defvar *writes* nil)
(defvar *read-ports* (make-hash-table))
(defvar *read-port-queues* (make-hash-table))
(defvar *data-reads* 0)
(defvar *data-writes* 0)
(defvar *memory* (make-array 20000 :element-type '(unsigned-byte 8)
                             :initial-element 0))
(defvar *memory-32-writes* nil)
(defvar *memory-32* (make-hash-table :test 'equal))
(defun io-port/8 (port)
  (push (list :port-read port) cl-user::*ata-io-log*)
  (let ((queue (gethash port *read-port-queues*)))
    (if queue
        (prog1 (first queue)
          (setf (gethash port *read-port-queues*) (rest queue)))
        (gethash port *read-ports* 0))))
(defun (setf io-port/8) (value port)
  (push (list :port port value) *writes*)
  (push (list :port-write port value) cl-user::*ata-io-log*)
  value)
(defun io-port/16 (port)
  (declare (ignore port))
  (incf *data-reads*)
  #xA55A)
(defun (setf io-port/16) (value port)
  (declare (ignore value port))
  (incf *data-writes*))
(defun memref-unsigned-byte-8 (base &optional (index 0))
  (aref *memory* (+ base index)))
(defun (setf memref-unsigned-byte-8) (value base &optional (index 0))
  (setf (aref *memory* (+ base index)) value))
(defun memref-unsigned-byte-16 (base &optional (index 0))
  (logior (aref *memory* (+ base (* index 2)))
          (ash (aref *memory* (+ base (* index 2) 1)) 8)))
(defun (setf memref-unsigned-byte-16) (value base &optional (index 0))
  (setf (aref *memory* (+ base (* index 2))) (ldb (byte 8 0) value)
        (aref *memory* (+ base (* index 2) 1)) (ldb (byte 8 8) value))
  value)
(defun memref-unsigned-byte-32 (base &optional (index 0))
  (gethash (list base index) *memory-32* 0))
(defun (setf memref-unsigned-byte-32) (value base &optional (index 0))
  (push (list base index value) *memory-32-writes*)
  (setf (gethash (list base index) *memory-32*) value))
(defun simple-vector-length (vector) (length vector))

(defpackage :mezzano.supervisor.ata
  (:use :cl)
  (:local-nicknames (:sup :mezzano.supervisor)
                    (:pci :mezzano.supervisor.pci)
                    (:sys.int :mezzano.internals)))
(in-package :mezzano.supervisor.ata)
'''+ "\n\n".join(forms) + r'''

(defun assert-true (value description)
  (unless value (error "~A was false" description)))
(defun assert-equal (actual expected description)
  (unless (equalp actual expected)
    (error "~A produced ~S, expected ~S" description actual expected)))

(defun assert-signals-error (thunk description)
  (let ((signaled-p nil))
    (handler-case (funcall thunk)
      (error () (setf signaled-p t)))
    (unless signaled-p
      (error "~A did not signal an error" description))))

(defun make-host-controller ()
  (let* ((event (mezzano.supervisor::make-event :state nil))
         (timer (mezzano.supervisor::make-timer))
         (controller (make-ata-controller
                      :command 100 :control 200 :bus-master-register 300
                      :prdt-phys 2000 :current-channel :device-0
                      :irq-latch event :irq-timeout-timer timer
                      :irq-watcher :host-watcher :bounce-buffer 1)))
    (setf mezzano.supervisor::*active-irq-event* event
          mezzano.supervisor::*active-timer* timer)
    controller))

(defun prepare-host-io (controller interrupts alt-statuses
                        &optional (default-alt-status 0))
  (setf cl-user::*ata-io-log* nil
        mezzano.internals::*writes* nil
        mezzano.internals::*data-reads* 0
        mezzano.internals::*data-writes* 0
        mezzano.supervisor.pci::*writes* nil
        mezzano.supervisor::*interrupt-results* interrupts
        mezzano.supervisor::*watcher-waits* 0
        (ata-controller-current-channel controller) :device-0
        (mezzano.supervisor:event-state
         (ata-controller-irq-latch controller)) nil
        (gethash (+ (ata-controller-control controller)
                    +ata-register-alt-status+)
                 mezzano.internals::*read-ports*)
        default-alt-status
        (gethash (+ (ata-controller-control controller)
                    +ata-register-alt-status+)
                 mezzano.internals::*read-port-queues*)
        alt-statuses))

(defun reset-count (controller)
  (count-if (lambda (write)
              (and (eq (first write) :port)
                   (= (second write)
                      (+ (ata-controller-control controller)
                         +ata-register-device-control+))
                   (logtest (third write) +ata-srst+)))
            mezzano.internals::*writes*))

(defun make-identified-ata-device (controller)
  (let ((identify (make-array 256 :initial-element 0)))
    (setf (svref identify 106) (logior (ash 1 14) (ash 1 12))
          (svref identify 117) 2048
          (svref identify 118) 0)
    (make-ata-device :controller controller :channel :device-0
                     :block-size
                     (ata-identify-logical-sector-size identify #'svref)
                     :sector-count 10 :lba48-capable nil)))

;;; IDENTIFY logical-sector sizes drive PIO word counts and reject sizes that
;;; cannot be represented by the ATA 16-bit data register.
(let ((device (make-ata-device :block-size 4096)))
  (assert-equal (ata-sector-word-count device) 2048
                "4096-byte sector word count"))
(assert-signals-error
 (lambda () (ata-sector-word-count (make-ata-device :block-size 513)))
 "odd logical-sector size")

;;; IDENTIFY words 117/118 count 16-bit words, not bytes. Exercise the real
;;; production decoder and then feed its result to the production word-count
;;; primitive.
(let* ((device (make-identified-ata-device nil))
       (block-size (ata-device-block-size device)))
    (assert-equal block-size 4096 "IDENTIFY logical-sector byte size")
    (assert-equal (ata-sector-word-count device) 2048
                  "decoded PIO sector word count"))
(let ((identify (make-array 256 :initial-element 0)))
  (setf (svref identify 106) (ash 1 14)
        (svref identify 117) 2048)
  (assert-equal (ata-identify-logical-sector-size identify #'svref) 512
                "IDENTIFY default sector without long-sector bit"))
(dolist (word-106 (list (ash 1 12)
                        (logior (ash 1 14) (ash 1 12) (ash 1 15))))
  (let ((identify (make-array 256 :initial-element 0)))
    (setf (svref identify 106) word-106
          (svref identify 117) 2048)
    (assert-equal (ata-identify-logical-sector-size identify #'svref) 512
                  "IDENTIFY invalid validity bits")))

;;; The exact byte-copy helper never touches bytes outside the requested range.
(fill mezzano.internals::*memory* 90)
(dotimes (i 13)
  (setf (aref mezzano.internals::*memory* (+ 100 i)) i))
(ata-copy-memory 200 100 13)
(assert-equal (subseq mezzano.internals::*memory* 200 213)
              (subseq mezzano.internals::*memory* 100 113)
              "exact bounce copy contents")
(assert-equal (aref mezzano.internals::*memory* 213) 90
              "exact bounce copy boundary")

;;; Execute the production PRDT builder. An unaligned 64 KiB transfer must be
;;; split at the physical boundary, not emitted as one crossing descriptor.
(let ((controller (make-ata-controller :bus-master-register 300
                                       :prdt-phys 2000)))
  (setf mezzano.internals::*memory-32-writes* nil
        mezzano.internals::*memory-32* (make-hash-table :test 'equal))
  (ata-configure-prdt controller #x1000 #x10000 :read)
  (assert-equal (mezzano.internals:memref-unsigned-byte-32 2000 0)
                #x1000 "first unaligned PRD address")
  (assert-equal (mezzano.internals:memref-unsigned-byte-32 2000 1)
                #xF000 "first unaligned PRD length")
  (assert-equal (mezzano.internals:memref-unsigned-byte-32 2000 2)
                #x10000 "second unaligned PRD address")
  (assert-equal (mezzano.internals:memref-unsigned-byte-32 2000 3)
                (logior #x80000000 #x1000)
                "final unaligned PRD length")
  ;; Each controller owns one half-page: 2048 / 8 = 256 descriptors.
  (let ((maximum-bytes (+ #xF000 (* 255 #x10000))))
    (setf mezzano.internals::*memory-32-writes* nil)
    (ata-configure-prdt controller #x1000 maximum-bytes :write)
    (assert-equal (length mezzano.internals::*memory-32-writes*) 512
                  "half-page PRDT capacity")
    (setf mezzano.internals::*memory-32-writes* nil)
    (assert-signals-error
     (lambda ()
       (ata-configure-prdt controller #x1000 (1+ maximum-bytes) :write))
     "oversized PRDT")
    (assert-equal mezzano.internals::*memory-32-writes* nil
                  "oversized PRDT rejected before memory writes")))

;;; LBA28 and LBA48 issue the device command and bus-master start as adjacent
;;; writes inside the same helper.
(let* ((event (mezzano.supervisor::make-event :state nil))
       (controller (make-ata-controller :command 100 :control 200
                                        :bus-master-register 300
                                        :current-channel :device-0
                                        :irq-latch event))
       (device28 (make-ata-device :controller controller :channel :device-0
                                  :lba48-capable nil))
       (device48 (make-ata-device :controller controller :channel :device-0
                                  :lba48-capable t)))
  (setf mezzano.internals::*writes* nil
        mezzano.supervisor.pci::*writes* nil)
  (ata-issue-lba28-command device28 1 1 32 9)
  (assert-equal (first mezzano.supervisor.pci::*writes*)
                '(:bmr 300 0 9) "LBA28 immediate DMA start")
  (assert-equal (first mezzano.internals::*writes*)
                '(:port 107 32) "LBA28 command ordering")
  (setf mezzano.internals::*writes* nil
        mezzano.supervisor.pci::*writes* nil)
  (ata-issue-lba48-command device48 1 1 36 9)
  (assert-equal (first mezzano.supervisor.pci::*writes*)
                '(:bmr 300 0 9) "LBA48 immediate DMA start")
  (assert-equal (first mezzano.internals::*writes*)
                '(:port 107 36) "LBA48 command ordering"))

;;; Recovery aborts DMA, clears stale interrupt/error state, asserts/deasserts
;;; SRST, invalidates device selection, and re-enables interrupts after BSY=0.
(let* ((event (mezzano.supervisor::make-event :state t))
       (controller (make-ata-controller :command 100 :control 200
                                        :bus-master-register 300
                                        :current-channel :device-1
                                        :irq-latch event)))
  (setf mezzano.internals::*writes* nil
        mezzano.supervisor.pci::*writes* nil)
  (assert-true (ata-reset-controller controller 0) "controller reset")
  (assert-equal (ata-controller-current-channel controller) nil
                "reset invalidates selection")
  (assert-equal (mezzano.supervisor:event-state event) nil
                "reset clears IRQ latch")
  (assert-equal (mapcar #'third (reverse mezzano.internals::*writes*))
                (list (logior +ata-srst+ +ata-nien+) +ata-nien+ 0)
                "SRST control sequence")
  (assert-equal (mapcar #'fourth (reverse mezzano.supervisor.pci::*writes*))
                (list 0 (logior +ata-bmr-status-error+
                                +ata-bmr-status-interrupt+))
                "DMA abort and status clear")
  (setf (gethash (+ 200 +ata-register-alt-status+)
                 mezzano.internals::*read-ports*)
        +ata-bsy+)
  (assert-equal (ata-reset-controller controller 0) nil
                "controller reset timeout")
  (setf (gethash (+ 200 +ata-register-alt-status+)
                 mezzano.internals::*read-ports*)
        0))

;;; A sub-page bounced read copies only the transfer bytes after success. A
;;; failed DMA leaves the caller's destination entirely unchanged.
(let* ((controller (make-ata-controller :bounce-buffer 1))
       (device (make-ata-device :controller controller :block-size 512
                                :sector-count 100 :lba48-capable nil))
       (destination 10000))
  (fill mezzano.internals::*memory* 77 :start destination :end (+ destination 1024))
  (flet ((dma-success (controller device lba count physical)
           (declare (ignore controller device lba count))
           (fill mezzano.internals::*memory* 33 :start physical :end (+ physical 512))
           t)
         (pio-unused (&rest arguments)
           (declare (ignore arguments))
           (error "PIO fallback unexpectedly used")))
    (assert-true (ata-read-write device 0 1 destination :read
                                 #'dma-success #'pio-unused)
                 "bounced read success"))
  (assert-true (every (lambda (byte) (= byte 33))
                      (subseq mezzano.internals::*memory*
                              destination (+ destination 512)))
               "bounced read contents")
  (assert-true (every (lambda (byte) (= byte 77))
                      (subseq mezzano.internals::*memory*
                              (+ destination 512) (+ destination 1024)))
               "bounced read boundary")
  (fill mezzano.internals::*memory* 88 :start destination :end (+ destination 512))
  (flet ((dma-failure (&rest arguments)
           (declare (ignore arguments))
           (values nil :device-error))
         (pio-unused (&rest arguments)
           (declare (ignore arguments))
           (error "PIO fallback unexpectedly used")))
    (multiple-value-bind (success reason)
        (ata-read-write device 0 1 destination :read
                        #'dma-failure #'pio-unused)
      (assert-equal success nil "bounced DMA failure result")
      (assert-equal reason :device-error "bounced DMA failure reason")))
  (assert-true (every (lambda (byte) (= byte 88))
                      (subseq mezzano.internals::*memory*
                              destination (+ destination 512)))
               "failed bounced read destination preservation"))

;;; Execute the production IRQ wait. Both wake causes disarm the timer and
;;; clear the latch, while only a real device interrupt reports success.
(let ((controller (make-host-controller)))
  (prepare-host-io controller '(t) nil)
  (assert-true (ata-intrq-wait controller 1) "IRQ wake result")
  (assert-equal (mezzano.supervisor:event-state
                 (ata-controller-irq-latch controller))
                nil "IRQ latch cleanup")
  (assert-equal (mezzano.supervisor::timer-armed-p
                 (ata-controller-irq-timeout-timer controller))
                nil "IRQ timer cleanup")
  (prepare-host-io controller '(nil) nil)
  (assert-equal (ata-intrq-wait controller 1) nil "timer wake result")
  (assert-equal (mezzano.supervisor::timer-armed-p
                 (ata-controller-irq-timeout-timer controller))
                nil "timeout timer cleanup"))

;;; PIO timeout must recover exactly once without touching the data register.
(let* ((controller (make-host-controller))
       (device (make-identified-ata-device controller)))
  (prepare-host-io controller '(nil) nil)
  (assert-equal (ata-pio-data-in device 1 10000) nil
                "PIO input IRQ timeout")
  (assert-equal mezzano.internals::*data-reads* 0
                "PIO timeout data-register isolation")
  (assert-equal (reset-count controller) 1
                "PIO timeout reset count"))

;;; Exercise every pre-transfer PIO Check_Status failure through the production
;;; functions. Each case resets exactly once and performs no data-port access.
(let* ((controller (make-host-controller))
       (device (make-identified-ata-device controller)))
  (dolist (case `((:busy-timeout (,+ata-bsy+ ,+ata-bsy+) 0)
                  (:no-drq (0 0) 0)
                  (:err (,+ata-err+ ,+ata-err+) ,+ata-err+)))
    (prepare-host-io controller '(t) (second case) (third case))
    (let ((*ata-command-timeout* 0))
      (assert-equal (ata-pio-data-in device 1 10000) nil
                    (format nil "PIO input ~A result" (first case))))
    (assert-equal mezzano.internals::*data-reads* 0
                  (format nil "PIO input ~A data isolation" (first case)))
    (assert-equal (reset-count controller) 1
                  (format nil "PIO input ~A reset count" (first case))))
  (dolist (case `((:busy-timeout (,+ata-bsy+ ,+ata-bsy+) 0)
                  (:no-drq (0 0) 0)
                  (:err (,+ata-err+ ,+ata-err+) ,+ata-err+)))
    (prepare-host-io controller nil (second case) (third case))
    (let ((*ata-command-timeout* 0))
      (assert-equal (ata-pio-data-out device 1 10000) nil
                    (format nil "PIO output ~A result" (first case))))
    (assert-equal mezzano.internals::*data-writes* 0
                  (format nil "PIO output ~A data isolation" (first case)))
    (assert-equal (reset-count controller) 1
                  (format nil "PIO output ~A reset count" (first case)))))

;;; Real PIO loops transfer one complete 4096-byte burst per sector and leave
;;; the interrupt latch/timer clean after every completed burst.
(let* ((controller (make-host-controller))
       (device (make-identified-ata-device controller)))
  (prepare-host-io controller '(t t) nil +ata-drq+)
  (assert-true (ata-pio-data-in device 2 10000) "PIO input bursts")
  (assert-equal mezzano.internals::*data-reads* 4096
                "PIO input word count")
  (assert-equal (mezzano.supervisor:event-state
                 (ata-controller-irq-latch controller))
                nil "PIO input IRQ cleanup")
  (assert-equal (reset-count controller) 0 "PIO input reset count")
  (prepare-host-io controller '(t t)
                   (append (make-list 4 :initial-element +ata-drq+)
                           (make-list 2 :initial-element 0)))
  (assert-true (ata-pio-data-out device 2 10000) "PIO output bursts")
  (assert-equal mezzano.internals::*data-writes* 4096
                "PIO output word count")
  (assert-equal (mezzano.supervisor:event-state
                 (ata-controller-irq-latch controller))
                nil "PIO output IRQ cleanup")
  (assert-equal (reset-count controller) 0 "PIO output reset count"))

;;; The decoded 4096-byte block size also reaches the real DMA/PRDT path.
(let* ((controller (make-host-controller))
       (device (make-identified-ata-device controller)))
  (prepare-host-io controller '(t) (list 0 0 0 0) 0)
  (setf mezzano.internals::*memory-32-writes* nil
        (gethash (list 300 +ata-bmr-status+)
                 mezzano.supervisor.pci::*registers*) 0)
  (assert-true (ata-read-dma controller device 0 1 #x20000)
               "decoded-sector DMA read")
  (assert-equal (mezzano.internals:memref-unsigned-byte-32 2000 1)
                (logior #x80000000 4096)
                "decoded-sector DMA byte count"))

;;; DMA completion must stop the engine, clear W1C status, then sample ATA
;;; Check_Status. Exercise clean completion plus every specified negative bit.
(let ((controller (make-host-controller)))
  (prepare-host-io controller '(t) nil 0)
  (setf (gethash (list 300 +ata-bmr-status+)
                 mezzano.supervisor.pci::*registers*) 0)
  (assert-true (ata-complete-dma controller +ata-bmr-direction-read/write+)
               "clean DMA completion")
  (let* ((events (reverse cl-user::*ata-io-log*))
         (stop (position `(:bmr-write 300 ,+ata-bmr-command+
                                      ,+ata-bmr-direction-read/write+)
                         events :test #'equal))
         (clear (position-if (lambda (event)
                               (and (eq (first event) :bmr-write)
                                    (= (third event) +ata-bmr-status+)))
                             events))
         (check (position-if (lambda (event)
                               (and (eq (first event) :port-read)
                                    (= (second event)
                                       (+ (ata-controller-control controller)
                                          +ata-register-alt-status+))))
                             events)))
    (assert-true (and stop clear check (< stop clear check))
                 "DMA stop-clear-check order"))
  (dolist (case `((:bmr ,+ata-bmr-status-error+ 0)
                  (:ata 0 ,+ata-err+)
                  (:ata 0 ,+ata-df+)
                  (:ata 0 ,+ata-drq+)))
    (prepare-host-io controller '(t) nil (third case))
    (setf (gethash (list 300 +ata-bmr-status+)
                   mezzano.supervisor.pci::*registers*)
          (second case))
    (multiple-value-bind (success reason)
        (ata-complete-dma controller +ata-bmr-direction-read/write+)
      (assert-equal success nil "negative DMA completion")
      (assert-equal reason :device-error "negative DMA reason"))
    (assert-equal (reset-count controller) 1
                  "negative DMA reset count")))

;;; Flush executes its real issue/wait/status path; an IRQ timeout performs one
;;; reset and does not enter later status processing.
(let* ((controller (make-host-controller))
       (device (make-ata-device :controller controller :channel :device-0
                                :block-size 512 :sector-count 10)))
  (prepare-host-io controller '(t) nil 0)
  (assert-true (ata-flush device) "flush completion")
  (assert-equal (reset-count controller) 0 "flush success reset count")
  (prepare-host-io controller '(nil) nil 0)
  (multiple-value-bind (success reason) (ata-flush device)
    (assert-equal success nil "flush timeout result")
    (assert-equal reason :device-error "flush timeout reason"))
  (assert-equal (reset-count controller) 1 "flush timeout reset count")
  (dolist (case `((:busy-timeout (0 ,+ata-bsy+ ,+ata-bsy+) 0)
                  (:err (0 0 0 ,+ata-err+) ,+ata-err+)))
    (prepare-host-io controller '(t) (second case) (third case))
    (let ((*ata-flush-timeout* 0))
      (multiple-value-bind (success reason) (ata-flush device)
        (assert-equal success nil
                      (format nil "flush ~A result" (first case)))
        (assert-equal reason :device-error
                      (format nil "flush ~A reason" (first case)))))
    (assert-equal mezzano.internals::*data-reads* 0
                  (format nil "flush ~A data-read isolation" (first case)))
    (assert-equal mezzano.internals::*data-writes* 0
                  (format nil "flush ~A data-write isolation" (first case)))
    (assert-equal (reset-count controller) 1
                  (format nil "flush ~A reset count" (first case)))))

;;; Check_Status_A failures happen before Send_Packet. BSY timeout, plain
;;; no-DRQ, and ERR all reset exactly once without emitting a CDB word.
(let* ((controller (make-host-controller))
       (device (make-atapi-device :controller controller :channel :device-0
                                  :cdb-size 12 :initialized-p t))
       (cdb (make-array 12 :initial-element 0)))
  (dolist (case `((:busy-timeout
                    (0 ,+ata-bsy+ ,+ata-bsy+ ,+ata-bsy+) 0)
                  (:no-drq (0 0 0 0) 0)
                  (:err (0 ,+ata-err+ ,+ata-err+ ,+ata-err+) ,+ata-err+)))
    (prepare-host-io controller nil (second case) (third case))
    (let ((*ata-command-timeout* 0))
      (assert-equal (ata-submit-packet-command device cdb 0 nil nil) nil
                    (format nil "PACKET Check_Status_A ~A" (first case))))
    (assert-equal mezzano.internals::*data-writes* 0
                  (format nil "PACKET A ~A CDB isolation" (first case)))
    (assert-equal mezzano.internals::*data-reads* 0
                  (format nil "PACKET A ~A data isolation" (first case)))
    (assert-equal (reset-count controller) 1
                  (format nil "PACKET A ~A reset count" (first case)))))

;;; Check_Status_B is reached only after the mandatory six-word CDB. Its IRQ,
;;; BSY-timeout, and ERR failures must not copy result data or emit extra words.
;;; DRQ-clear without ERR is the protocol's successful no-data completion.
(let* ((controller (make-host-controller))
       (device (make-atapi-device :controller controller :channel :device-0
                                  :cdb-size 12 :initialized-p t))
       (cdb (make-array 12 :initial-element 0))
       (result-buffer 12000))
  (dolist (case `((:irq-timeout (0 ,+ata-drq+ ,+ata-drq+ ,+ata-drq+) (nil) 0)
                  (:busy-timeout
                    (0 ,+ata-drq+ ,+ata-drq+ ,+ata-drq+
                       ,+ata-bsy+ ,+ata-bsy+)
                    (t) 0)
                  (:err
                    (0 ,+ata-drq+ ,+ata-drq+ ,+ata-drq+
                       ,+ata-err+ ,+ata-err+ ,+ata-err+)
                    (t) ,+ata-err+)))
    (fill mezzano.internals::*memory* 91
          :start result-buffer :end (+ result-buffer 16))
    (prepare-host-io controller (third case) (second case) (fourth case))
    (let ((*ata-command-timeout* 0))
      (assert-equal
       (ata-issue-pio-packet-command device cdb result-buffer 16) nil
       (format nil "PACKET Check_Status_B ~A" (first case))))
    (assert-equal mezzano.internals::*data-writes* 6
                  (format nil "PACKET B ~A only writes CDB" (first case)))
    (assert-equal mezzano.internals::*data-reads* 0
                  (format nil "PACKET B ~A data isolation" (first case)))
    (assert-true (every (lambda (byte) (= byte 91))
                        (subseq mezzano.internals::*memory*
                                result-buffer (+ result-buffer 16)))
                 (format nil "PACKET B ~A result isolation" (first case)))
    (assert-equal (reset-count controller) 1
                  (format nil "PACKET B ~A reset count" (first case))))
  (prepare-host-io controller '(t)
                   (append (list 0)
                           (make-list 3 :initial-element +ata-drq+)
                           (make-list 3 :initial-element 0)))
  (assert-equal (ata-issue-pio-packet-command device cdb result-buffer 0) 0
                "PACKET Check_Status_B no-DRQ completion")
  (assert-equal mezzano.internals::*data-writes* 6
                "PACKET B no-DRQ only writes CDB")
  (assert-equal mezzano.internals::*data-reads* 0
                "PACKET B no-DRQ data isolation")
  (assert-equal (reset-count controller) 0
                "PACKET B no-DRQ reset count"))

;;; Execute both PACKET transports. PIO sends the complete CDB then performs
;;; Check_Status_B; DMA configures PRDT, sends CDB, starts the engine, and routes
;;; completion through the same stop/clear/status validator.
(let* ((controller (make-host-controller))
       (cdb (make-array 12 :initial-element 0))
       (pio-device (make-atapi-device :controller controller :channel :device-0
                                      :cdb-size 12 :initialized-p nil))
       (dma-device (make-atapi-device :controller controller :channel :device-0
                                      :cdb-size 12 :initialized-p t)))
  (prepare-host-io controller nil
                   (append (list 0)
                           (make-list 3 :initial-element +ata-drq+)
                           (make-list 3 :initial-element 0)))
  (assert-equal (ata-issue-packet-command pio-device cdb nil 0) 0
                "PIO PACKET no-data completion")
  (assert-equal mezzano.internals::*data-writes* 6 "PIO PACKET CDB burst")
  (assert-equal (reset-count controller) 0 "PIO PACKET reset count")
  (prepare-host-io controller '(t)
                   (append (list 0)
                           (make-list 3 :initial-element +ata-drq+)
                           (make-list 3 :initial-element 0)))
  (setf (gethash (list 300 +ata-bmr-status+)
                 mezzano.supervisor.pci::*registers*) 0)
  (assert-true (ata-issue-dma-packet-command dma-device cdb 4096 4)
               "DMA PACKET completion")
  (assert-equal mezzano.internals::*data-writes* 6 "DMA PACKET CDB burst")
  (assert-equal (reset-count controller) 0 "DMA PACKET reset count"))

(format t "ATA recovery and transfer behavior passed~%")
''', encoding="utf-8")
PY

"$sbcl" --noinform --non-interactive --load "$test_file"

if [[ ${ATA_SKIP_MUTATION_CHECK:-0} != 1 ]]; then
  mutation_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-supervisor-ata-mutation.XXXXXX.lisp")
  for mutation in odd-sector bit15 packet-a-reset; do
    python3 - "$source_file" "$mutation_file" "$mutation" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
mutations = {
    "odd-sector": (
        "    (sup:ensure (and (plusp block-size) (evenp block-size)))\n",
        "",
    ),
    "bit15": (
        "                      (not (logbitp 15 sector-information))\n",
        "",
    ),
    "packet-a-reset": ('''      (when timed-out
        (sup:debug-print-line "Device timeout during PACKET Check_Status_A.")
        (ata-reset-controller controller)
        (return-from ata-submit-packet-command nil))''', '''      (when timed-out
        (sup:debug-print-line "Device timeout during PACKET Check_Status_A.")
        (return-from ata-submit-packet-command nil))'''),
}
needle, replacement = mutations[sys.argv[3]]
if source.count(needle) != 1:
    raise SystemExit(f"Could not create targeted {sys.argv[3]} mutation")
Path(sys.argv[2]).write_text(source.replace(needle, replacement), encoding="utf-8")
PY
    if ATA_SOURCE="$mutation_file" ATA_SKIP_MUTATION_CHECK=1 \
        bash "$0" >/dev/null 2>&1; then
      echo "ATA mutation was not detected: $mutation" >&2
      exit 1
    fi
    echo "ATA targeted mutation check passed: $mutation"
  done
fi
