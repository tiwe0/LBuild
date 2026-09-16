#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${SNAPSHOT_SOURCE:-"$repo_root/supervisor/snapshot.lisp"}
sbcl=${SBCL:-sbcl}
forms_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-snapshot-forms.XXXXXX.lisp")
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-snapshot-semantics.XXXXXX.lisp")
trap 'rm -f "$forms_file" "$test_file"' EXIT

python3 - "$source_file" "$forms_file" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text()

markers = list(re.finditer(r"(?im)^\s*;.*\b(?:TODO|FIXME)\b", source))
if markers:
    lines = ", ".join(str(source.count("\n", 0, marker.start()) + 1)
                      for marker in markers)
    raise SystemExit(f"snapshot TODO/FIXME markers remain at lines: {lines}")

required_forms = [
    "snapshot-wired-page-needs-copy-p",
    "snapshot-allocate-backing-for-pages",
    "ensure-snapshot-wired-reserve",
    "call-with-snapshot-vm-stable",
    "snapshot-release-old-block-map",
    "snapshot-release-old-freelist",
    "snapshot-claim-request",
    "snapshot-prepare-thread-for-sleep",
    "snapshot-adjust-inhibit",
]
for name in required_forms:
    if not re.search(rf"\(defun\s+{re.escape(name)}\b", source, re.I):
        raise SystemExit(f"missing snapshot semantic helper: {name}")

required_fragments = [
    "(page-dirty-p pte)",
    "(world-stopped-p)",
    "(%allocate-physical-pages +snapshot-large-backing-page-count+",
    "(rw-lock-write-acquire *vm-lock*)",
    "(store-free block-id 1)",
    "(sys.int::cas",
    "(sys.int::%atomic-fixnum-add-symbol '*snapshot-inhibit* delta)",
]
# The card-table range must still be walked sparsely.  MAP-SNAPSHOT-WIRED-PAGES
# calls the positional MAP-PTES-1 rather than the keyword wrapper: the keyword
# form materialises its argument vector in the general area, and this runs with
# the world stopped and *VM-LOCK* held, where a fault cannot be serviced.  Match
# the sparse argument in either spelling so the contract survives that change.
if not (re.search(r":sparse\s+t", source)
        or re.search(r"\(map-ptes-1\s+sys\.int::\+card-table-base\+.*?\n\s+t\)",
                     source, re.S)):
    raise SystemExit("the card table range is no longer walked sparsely")

for fragment in required_fragments:
    if fragment.lower() not in source.lower():
        raise SystemExit(f"missing snapshot contract fragment: {fragment}")

sleep_state = source.find("(thread-state sys.int::*snapshot-thread*) :sleeping")
clear_in_progress = source.find("*snapshot-in-progress* nil", sleep_state)
if sleep_state < 0 or clear_in_progress < sleep_state:
    raise SystemExit("snapshot thread publishes idle before entering sleeping state")

print("supervisor snapshot semantic contract passed")


def extract_form(prefix):
    start = source.find(prefix)
    if start < 0:
        raise SystemExit(f"missing source form: {prefix}")
    depth = 0
    string = False
    escaped = False
    comment = False
    i = start
    while i < len(source):
        ch = source[i]
        if comment:
            if ch == "\n":
                comment = False
        elif string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                string = False
        elif ch == ";":
            comment = True
        elif ch == '"':
            string = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return source[start:i + 1]
        i += 1
    raise SystemExit(f"unterminated source form: {prefix}")


prefixes = [
    "(defconstant +snapshot-minimum-wired-free-bytes+",
    "(defconstant +snapshot-large-backing-page-count+",
    "(defun snapshot-wired-dirty-tracking-p",
    "(defun snapshot-wired-page-needs-copy-p",
    "(defun map-snapshot-wired-pages",
    "(defun snapshot-copy-wired-area",
    "(defun snapshot-install-wired-backing-page",
    "(defun snapshot-allocate-backing-for-pages",
    "(defun allocate-snapshot-wired-backing-pages-1",
    "(defun allocate-snapshot-wired-backing-pages (start",
    "(defun snapshot-largest-wired-free-region",
    "(defun ensure-snapshot-wired-reserve",
    "(defun call-with-snapshot-vm-stable",
    # Anchored: "(defun snapshot-write-disk" is now also a prefix of
    # SNAPSHOT-WRITE-DISK-RANGE, and FIND would stop at whichever comes first.
    "(defun snapshot-write-disk (block data)",
    "(defun snapshot-write-disk-range",
    "(defun snapshot-release-old-block-map",
    "(defun snapshot-release-old-freelist",
    "(defun take-snapshot",
    "(defun snapshot-prepare-thread-for-sleep",
    "(defun snapshot-claim-request",
    "(defun snapshot-adjust-inhibit",
    "(defun call-with-snapshot-inhibited",
]
Path(sys.argv[2]).write_text("\n\n".join(extract_form(p) for p in prefixes) + "\n")
PY

cat >"$test_file" <<'LISP'
(defpackage :sys.int
  (:use :cl)
  (:shadow #:cas)
  (:export #:*wired-area-free-bins*))

(in-package :sys.int)

(defvar *wired-area-free-bins* #())
(defparameter +block-map-id-shift+ 8)
(defparameter +block-map-committed+ 4)
(defparameter *wired-area-base* 0)
(defparameter *wired-area-bump* #x1000)
(defparameter +card-table-base+ #x100000)
(defparameter +card-table-size+ #x1000)
(defparameter *wired-function-area-limit* #x200000)
(defparameter *function-area-base* #x201000)
(defvar *memory64* (make-hash-table :test #'equal))

(defun memref-unsigned-byte-64 (page index)
  (if (arrayp page)
      (aref page index)
      (gethash (cons page index) *memory64* 0)))

(defun (setf memref-unsigned-byte-64) (value page index)
  (if (arrayp page)
      (setf (aref page index) value)
      (setf (gethash (cons page index) *memory64*) value)))

(defun symbol-global-value (symbol)
  (symbol-value symbol))

(defun (setf symbol-global-value) (value symbol)
  (setf (symbol-value symbol) value))

(defmacro cas (place old new)
  `(let ((previous ,place))
     (when (eql previous ,old)
       (setf ,place ,new))
     previous))

(defun %atomic-fixnum-add-symbol (symbol delta)
  (prog1 (symbol-value symbol)
    (incf (symbol-value symbol) delta)))

(defpackage :mezzano.runtime
  (:use :cl)
  (:export #:freelist-entry-next #:freelist-entry-size))

(in-package :mezzano.runtime)

(defvar *free-next* (make-hash-table))
(defvar *free-size* (make-hash-table))

(defun freelist-entry-next (entry) (gethash entry *free-next*))
(defun freelist-entry-size (entry) (gethash entry *free-size* 0))

(defpackage :mezzano.supervisor
  (:use :cl)
  (:shadow #:ensure)
  (:export))

(in-package :mezzano.supervisor)

(defconstant +4k-page-size+ 4096)

(defmacro ensure (test &rest message-parts)
  `(unless ,test
     (error "Snapshot invariant failed: ~{~A~}" (list ,@message-parts))))

(defmacro dx-lambda (lambda-list &body body)
  `(lambda ,lambda-list ,@body))

(defmacro without-interrupts (&body body)
  `(progn ,@body))

(defmacro with-rw-lock-write ((lock) &body body)
  `(progn
     (rw-lock-write-acquire ,lock)
     (unwind-protect (progn ,@body)
       (rw-lock-write-release ,lock))))

(defvar *frame-type* (make-hash-table))
(defvar *frame-next* (make-hash-table))
(defvar *frame-address* (make-hash-table))
(defvar *frame-block-id* (make-hash-table))
(defvar *allocations* '())
(defvar *next-single-frame* 3000)
(defvar *fail-large-allocation* nil)

(defun physical-page-frame-type (frame) (gethash frame *frame-type*))
(defun (setf physical-page-frame-type) (value frame)
  (setf (gethash frame *frame-type*) value))
(defun physical-page-frame-next (frame) (gethash frame *frame-next*))
(defun (setf physical-page-frame-next) (value frame)
  (setf (gethash frame *frame-next*) value))
(defun physical-page-virtual-address (frame) (gethash frame *frame-address*))
(defun (setf physical-page-virtual-address) (value frame)
  (setf (gethash frame *frame-address*) value))
(defun physical-page-frame-block-id (frame) (gethash frame *frame-block-id*))
(defun (setf physical-page-frame-block-id) (value frame)
  (setf (gethash frame *frame-block-id*) value))

(defun %allocate-physical-pages (count type mandatory-p 32-bit-only)
  (declare (ignore mandatory-p 32-bit-only))
  (push (list count type) *allocations*)
  (cond ((and (= count 512) *fail-large-allocation*) nil)
        ((= count 512) 1000)
        (t (prog1 *next-single-frame* (incf *next-single-frame*)))))

(defun allocate-physical-pages (count &key type mandatory-p 32-bit-only)
  (%allocate-physical-pages count type mandatory-p 32-bit-only))

(defun page-present-p (pte &optional index)
  (declare (ignore index))
  (if (arrayp pte)
      (logbitp 0 (aref pte 0))
      (getf pte :present)))

(defun page-dirty-p (pte &optional index)
  (declare (ignore index))
  (if (arrayp pte)
      (logbitp 1 (aref pte 0))
      (getf pte :dirty)))

(defun pte-physical-address (value)
  (logand value (lognot #xfff)))

(defun %make-pte (frame writable present block wired dirty copy-on-write cache-mode)
  (declare (ignore writable block wired cache-mode))
  (vector (logior (ash frame 12)
                  (if present 1 0)
                  (if dirty 2 0)
                  (if copy-on-write 4 0))))

(defun %update-pte (pte writable writablep dirty dirtyp)
  (declare (ignore writable writablep))
  (setf (aref pte 0)
        (if (and dirtyp dirty)
            (logior (aref pte 0) 2)
            (logandc2 (aref pte 0) 2))))

(defun update-pte (pte &key (dirty nil dirtyp))
  (%update-pte pte nil nil dirty dirtyp))

(defun make-test-pte (frame &key (dirty nil))
  (vector (logior (ash frame 12) 1 (if dirty 2 0))))

(defvar *mapped-ptes* '())
(defvar *map-log* '())

(defun map-ptes-1 (start end function sparse)
  (push (list start end sparse) *map-log*)
  (dolist (entry *mapped-ptes*)
    (when (<= start (car entry) (1- end))
      (funcall function (car entry) (cdr entry)))))

(defun map-ptes (start end function &key sparse)
  (map-ptes-1 start end function sparse))

;; Boot tracing is a no-op on the host.
(defun debug-uart-boot-line (string) (declare (ignore string)) nil)
(defun debug-uart-boot-hex-line (label value)
  (declare (ignore label value)) nil)

(defun align-down (value alignment)
  (- value (mod value alignment)))

(defvar *execution-log* '())
(defvar *take-log* '())
(defvar *vm-lock* :vm-lock)
(defvar *lock-held* nil)
(defvar *world-stopped* nil)

(defun call-with-world-stopped (function)
  (push :world-enter *execution-log*)
  (let ((*world-stopped* t))
    (funcall function))
  (push :world-exit *execution-log*))

(defun world-stopped-p () *world-stopped*)

(defun begin-tlb-shootdown () (push :tlb-begin *execution-log*))
(defun flush-tlb () (push :tlb-flush *execution-log*))
(defun tlb-shootdown-all () (push :tlb-all *execution-log*))
(defun finish-tlb-shootdown () (push :tlb-finish *execution-log*))

(defun rw-lock-write-acquire (lock)
  (declare (ignore lock))
  (setf *lock-held* t)
  (push :lock-acquire *execution-log*)
  t)

(defun rw-lock-write-release (lock)
  (declare (ignore lock))
  (setf *lock-held* nil)
  (push :lock-release *execution-log*))

(defvar *disk-pages* (make-hash-table))
(defvar *freed-blocks* '())
(defvar *disk-await-results* '())
(defvar *disk-operations* '())
(defvar *snapshot-disk-request* :snapshot-request)
(defvar *paging-disk* :paging-disk)
(defvar *last-disk-operation* nil)

(defun disk-sector-size (disk)
  (declare (ignore disk))
  512)

(defun disk-submit-request (request disk operation start count data)
  (declare (ignore request disk data))
  (setf *last-disk-operation* operation)
  (push (list operation start count) *disk-operations*)
  (push (list :disk operation start) *take-log*))

(defun disk-await-request (request)
  (declare (ignore request))
  (let ((result (pop *disk-await-results*)))
    (push (list :disk-complete *last-disk-operation* result) *take-log*)
    result))

(defvar *block-info* (make-array 1 :initial-element 0))
(defvar *store-fudge-factor* 0)
(defvar *store-next-block* 99)
(defvar *copied-pages* '())
(defvar *writeback-pages* '())
(defvar *deferred-frees* '())

(defun block-info-for-virtual-address-1 (address createp)
  (declare (ignore address createp))
  *block-info*)

(defun store-alloc (count)
  (declare (ignore count))
  (prog1 *store-next-block* (incf *store-next-block*)))

(defun store-deferred-free (block count)
  (push (list block count) *deferred-frees*))

(defun %fast-page-copy (destination source)
  (push (list destination source) *copied-pages*))

(defvar *header-address* #x900000)
(defvar *header-frame* (/ *header-address* 4096))

(defun convert-to-pmap-address (address)
  address)

(defun snapshot-add-to-writeback-list (frame)
  (push frame *writeback-pages*))

(defun call-with-snapshot-disk-block (block-id function)
  (funcall function (gethash block-id *disk-pages*)))

(defun snapshot-free-metadata-block (block-id)
  (push block-id *freed-blocks*))

(defvar *snapshot-in-progress* nil)
(defvar *snapshot-next-epoch* nil)
(defvar *snapshot-state* nil)
(defvar *snapshot-inhibit* 0)
(defvar *wake-count* 0)
(defvar *paging-read-only* nil)
(defvar *snapshot-pending-writeback-pages* nil)
(defvar *snapshot-pending-writeback-pages-count* 0)
(defvar *store-freelist-n-deferred-free-blocks* 0)
(defparameter +image-header-block-map+ 8)
(defparameter +image-header-freelist+ 16)
(defvar *new-block-map* 51)
(defvar *new-freelist* 52)
(defvar *freed-pages* '())

(defstruct event state)
(defstruct thread state wait-item)
(defvar sys.int::*snapshot-thread* (make-thread :state :active))

(defun wake-thread (thread)
  (declare (ignore thread))
  (incf *wake-count*))

(defun panic (&rest arguments)
  (error "~{~A~}" arguments))

(defun debug-print-line (&rest arguments)
  (declare (ignore arguments)))

(defun set-snapshot-light (state)
  (push (list :light state) *take-log*))

(defun snapshot-copy-wired-area () nil)
(defun snapshot-mark-cow-dirty-pages () nil)
(defun snapshot-block-map () *new-block-map*)
(defun snapshot-freelist () (values *new-freelist* '(:deferred)))
(defun snapshot-write-back-pages () nil)
(defun %pager-allocate-page (new-type)
  (declare (ignore new-type))
  *header-frame*)

(defun pager-allocate-page (&key new-type)
  (%pager-allocate-page new-type))
(defun free-page (page)
  (push page *freed-pages*)
  (push (list :free-page page) *take-log*))
(defun store-release-deferred-blocks (blocks)
  (push (list :release-deferred blocks) *take-log*))

(load (or (sb-ext:posix-getenv "SNAPSHOT_FORMS")
          (error "SNAPSHOT_FORMS is not set")))

(defun assert-equal (expected actual message)
  (unless (equal expected actual)
    (error "~A (expected ~S, got ~S)" message expected actual)))

(defun assert-true (value message)
  (unless value (error "~A" message)))

;; Every metadata write must turn an I/O failure into a non-local abort.
(setf *disk-await-results* '(nil)
      *disk-operations* '())
(assert-true
 (handler-case (progn (snapshot-write-disk 9 :buffer) nil)
   (error () t))
 "SNAPSHOT-WRITE-DISK silently accepted an injected write failure")

;; Dirty filtering remains explicit while ARM64 conservatively copies wired pages.
(assert-true (snapshot-wired-page-needs-copy-p '(:present t :dirty t) t)
             "Dirty wired page was skipped")
(assert-true (not (snapshot-wired-page-needs-copy-p
                   '(:present t :dirty nil) t))
             "Clean wired page was copied")
(assert-true (snapshot-wired-page-needs-copy-p '(:present t :dirty nil) nil)
             "Conservative architecture mode skipped a mapped page")

;; Execute the production mapper and wired-copy path, including sparse card
;; traversal, dirty-bit clearing, and the complete TLB shootdown sequence.
(setf (symbol-function 'snapshot-wired-dirty-tracking-p) (lambda () t))
(let ((pte (make-test-pte 10 :dirty t)))
  (setf *mapped-ptes* (list (cons 0 pte))
        (gethash 10 *frame-next*) 20
        (aref *block-info* 0) (logior (ash 7 8) 1)
        *store-next-block* 99
        *store-fudge-factor* 1
        *copied-pages* '()
        *writeback-pages* '()
        *deferred-frees* '()
        *execution-log* '()
        *map-log* '())
  (let ((*world-stopped* t))
    (snapshot-copy-wired-area))
  (assert-true (not (page-dirty-p pte))
               "Production wired copy did not clear the dirty bit")
  (assert-equal '(:tlb-begin :tlb-flush :tlb-all :tlb-finish)
                (reverse *execution-log*)
                "Production wired copy omitted or reordered TLB maintenance")
  (assert-equal '((81920 0)) *copied-pages*
                "Production wired copy did not copy to its backing frame")
  (assert-equal '(20) *writeback-pages*
                "Production wired copy did not enqueue its backing frame")
  (assert-true
   (member (list sys.int::+card-table-base+
                 (+ sys.int::+card-table-base+ sys.int::+card-table-size+)
                 t)
           *map-log*
           :test #'equal)
   "Production mapper did not traverse the card table sparsely"))

;; A complete aligned 2MB virtual run gets one contiguous physical allocation.
(let ((pages (loop for i below 512
                   collect (cons (+ 10 i) (* i 4096)))))
  (setf *allocations* '())
  (snapshot-allocate-backing-for-pages pages)
  (assert-equal '((512 :wired-backing)) *allocations*
                "Aligned 2MB backing did not use one large allocation")
  (assert-equal 1000 (physical-page-frame-next 10)
                "First backing frame was not installed")
  (assert-equal 1511 (physical-page-frame-next 521)
                "Last backing frame was not installed"))
(setf *allocations* '())
(snapshot-allocate-backing-for-pages '((700 . 4096) (701 . 8192)))
(assert-equal '((1 :wired-backing) (1 :wired-backing))
              (reverse *allocations*)
              "Partial backing run did not fall back to single pages")

;; Execute the top-level allocator. A rejected dense allocation must degrade to
;; mandatory single pages instead of leaving the wired range without backing.
(setf *mapped-ptes*
      (loop for i below 512
            collect (cons (* i 4096) (make-test-pte (+ 10000 i))))
      *allocations* '()
      *next-single-frame* 20000
      *fail-large-allocation* t)
(allocate-snapshot-wired-backing-pages 0 (* 512 4096))
(let ((allocations (reverse *allocations*)))
  (assert-equal 513 (length allocations)
                "Dense-allocation failure did not perform 512 fallbacks")
  (assert-equal '(512 :wired-backing) (first allocations)
                "Top-level allocator did not try the dense 512-page run first")
  (assert-true (every (lambda (allocation)
                        (equal allocation '(1 :wired-backing)))
                      (rest allocations))
               "Dense-allocation fallback used a non-single allocation"))
(setf *fail-large-allocation* nil)

;; The wired reserve check uses the largest contiguous free entry, not totals.
(let ((sys.int::*wired-area-free-bins* (vector 1 nil 3)))
  (setf (gethash 1 mezzano.runtime::*free-size*) 1024
        (gethash 1 mezzano.runtime::*free-next*) 2
        (gethash 2 mezzano.runtime::*free-size*) 9000
        (gethash 3 mezzano.runtime::*free-size*) 2048)
  (assert-equal 72000 (snapshot-largest-wired-free-region)
                "Largest wired free region was miscomputed")
  (ensure-snapshot-wired-reserve))
(let ((sys.int::*wired-area-free-bins* (vector 4)))
  (setf (gethash 4 mezzano.runtime::*free-size*) 4096)
  (assert-true
   (handler-case (progn (ensure-snapshot-wired-reserve) nil)
     (error () t))
   "A fragmented sub-64KiB wired reserve was accepted"))

;; Slow metadata serialization runs after CPUs resume but before VM unlock.
(setf *execution-log* '())
(call-with-snapshot-vm-stable
 (lambda ()
   (assert-true *lock-held* "Critical phase ran without VM lock")
   (push :critical *execution-log*))
 (lambda ()
   (assert-true *lock-held* "Stable phase released VM lock too early")
   (push :stable *execution-log*)))
;; The stable phase must run before the world resumes.  The critical phase
;; ends by marking every non-wired page read-only and copy-on-write, so once
;; other threads run again the first write to any stack takes a copy-on-write
;; fault -- and the pager cannot service it while this thread holds *VM-LOCK*.
;; Letting the world out first (:critical :world-exit :stable) deadlocks with
;; every thread asleep.  *VM-LOCK* itself cannot simply be dropped either:
;; STORE-ALLOC, reached from the stable phase, asserts that it is held.
(assert-equal '(:world-enter :lock-acquire :critical :stable
                :lock-release :world-exit)
              (reverse *execution-log*)
              "World-stop/VM-lock ordering is incorrect")
(handler-case
    (call-with-snapshot-vm-stable (lambda () nil)
                                  (lambda () (error "disk failure")))
  (error () nil))
(assert-true (not *lock-held*) "VM lock leaked after stable-phase failure")
(handler-case
    (call-with-snapshot-vm-stable (lambda () (error "critical failure"))
                                  (lambda () nil))
  (error () nil))
(assert-true (not *lock-held*) "VM lock leaked after critical-phase failure")

;; Reclaim only metadata nodes from the old four-level block-map tree.
(flet ((page (&rest entries)
         (let ((v (make-array 512 :initial-element 0)))
           (loop for (index value) on entries by #'cddr
                 do (setf (aref v index) value))
           v)))
  (setf (gethash 10 *disk-pages*) (page 0 (ash 20 8))
        (gethash 20 *disk-pages*) (page 1 (ash 30 8))
        (gethash 30 *disk-pages*) (page 2 (ash 40 8))
        *freed-blocks* '())
  (snapshot-release-old-block-map 10 4)
  (assert-equal '(40 30 20 10) (reverse *freed-blocks*)
                "Old block-map metadata traversal was incomplete"))

(let ((first (make-array 512 :initial-element 0))
      (second (make-array 512 :initial-element 0)))
  (setf (aref first 511) 60
        (gethash 50 *disk-pages*) first
        (gethash 60 *disk-pages*) second
        *freed-blocks* '())
  (snapshot-release-old-freelist 50)
  (assert-equal '(50 60) (reverse *freed-blocks*)
                "Old freelist chain was not reclaimed"))

;; Execute TAKE-SNAPSHOT itself. Failed durable header publication aborts,
;; frees the temporary header page, and leaves both old metadata roots intact.
(setf (symbol-function 'ensure-snapshot-wired-reserve) (lambda () t)
      (symbol-function 'snapshot-copy-wired-area) (lambda () nil)
      (symbol-function 'snapshot-release-old-block-map)
      (lambda (block level)
        (push (list :release-block-map block level) *take-log*))
      (symbol-function 'snapshot-release-old-freelist)
      (lambda (block)
        (push (list :release-freelist block) *take-log*)))
(setf (gethash (cons (+ *header-address* +image-header-block-map+) 0)
               sys.int::*memory64*)
      41
      (gethash (cons (+ *header-address* +image-header-freelist+) 0)
               sys.int::*memory64*)
      42
      *disk-await-results* '(t nil)
      *take-log* '()
      *freed-pages* '())
(assert-true
 (handler-case (progn (take-snapshot) nil)
   (error () t))
 "TAKE-SNAPSHOT accepted an injected durable header-write failure")
(assert-equal (list *header-address*) *freed-pages*
              "Header page leaked after failed publication")
(assert-true
 (notany (lambda (event)
           (member (first event) '(:release-block-map :release-freelist)))
         *take-log*)
 "Failed header publication reclaimed old snapshot metadata")

;; On success, completion of the header write strictly precedes reclamation.
(setf (gethash (cons (+ *header-address* +image-header-block-map+) 0)
               sys.int::*memory64*)
      41
      (gethash (cons (+ *header-address* +image-header-freelist+) 0)
               sys.int::*memory64*)
      42
      *disk-await-results* '(t t)
      *take-log* '()
      *freed-pages* '())
(take-snapshot)
(let* ((events (reverse *take-log*))
       (commit (position '(:disk-complete :write t) events :test #'equal))
       (release-map (position '(:release-block-map 41 4)
                              events :test #'equal))
       (release-free (position '(:release-freelist 42)
                               events :test #'equal)))
  (assert-true commit "TAKE-SNAPSHOT omitted durable header completion")
  (assert-true (and release-map (< commit release-map))
               "Old block-map root was reclaimed before header commit")
  (assert-true (and release-free (< commit release-free))
               "Old freelist root was reclaimed before header commit"))
(assert-equal (list *header-address*) *freed-pages*
              "Header page was not freed after successful publication")

;; Only one CPU claims a pending request, and sleeping is published first.
(setf *snapshot-state* (make-event :state t)
      *snapshot-in-progress* nil
      *snapshot-next-epoch* nil
      *wake-count* 0)
(assert-true (snapshot-claim-request :epoch-1) "First request was not claimed")
(assert-true (not (snapshot-claim-request :epoch-2))
             "Concurrent request bypassed the CAS claim")
(assert-equal 1 *wake-count* "Snapshot thread was woken more than once")
(assert-equal :epoch-1 *snapshot-next-epoch*
              "Losing request overwrote the claimed epoch")
(snapshot-prepare-thread-for-sleep)
(assert-equal :sleeping (thread-state sys.int::*snapshot-thread*)
              "Snapshot thread was not marked sleeping")
(assert-true (not *snapshot-in-progress*) "Idle state was not published")

;; Atomic nesting remains balanced even when the callback unwinds.
(setf *snapshot-inhibit* 0)
(assert-equal 1 (snapshot-adjust-inhibit 1) "Atomic inhibit increment failed")
(assert-equal 0 (snapshot-adjust-inhibit -1) "Atomic inhibit decrement failed")
(handler-case (snapshot-adjust-inhibit -1)
  (error () nil))
(assert-equal 0 *snapshot-inhibit* "Underflow recovery corrupted inhibit count")
(handler-case
    (call-with-snapshot-inhibited (lambda () (error "unwind")))
  (error () nil))
(assert-equal 0 *snapshot-inhibit* "Non-local exit leaked snapshot inhibition")

(format t "supervisor snapshot executable semantics passed~%")
LISP

SNAPSHOT_FORMS="$forms_file" "$sbcl" --noinform --disable-debugger --script "$test_file"
