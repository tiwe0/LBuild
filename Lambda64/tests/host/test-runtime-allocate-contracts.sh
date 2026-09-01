#!/usr/bin/env bash
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${ALLOCATOR_SOURCE:-"$repo_root/runtime/allocate.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-runtime-allocate.XXXXXX.lisp")
mutation_dir=""
trap 'rm -f "$test_file"; if [[ -n "$mutation_dir" ]]; then rm -rf "$mutation_dir"; fi' EXIT
python3 - "$source_file" <<'PY'
from pathlib import Path
import re, sys
s=Path(sys.argv[1]).read_text()
required=[
 '(defun update-freelist-card-offsets',
 '(defvar *maximum-young-generation-size*',
 '(defun allocation-area-growth-permitted-p',
 '(defun copy-symbol-name-to-wired-area',
 '(defun finish-expand-wired-function-area',
 '(defun valid-funcallable-instance-layout-p',
 '(defun funcallable-instance-entry-point',
 '(defun allocate-stack-virtual-region',
 '(defun atomic-update-card-table-dirty-gen',
]
for form in required:
 if form not in s: raise SystemExit(f'Missing allocator contract form: {form}')
if re.search(r'(?i)todo|fixme',s): raise SystemExit('allocate.lisp still has TODO/FIXME markers')
contracts={
 'make-symbol':'copy-symbol-name-to-wired-area',
 'expand-function-area':'finish-expand-wired-function-area',
 '%allocate-stack':'allocate-stack-virtual-region',
}
for name, call in contracts.items():
 m=re.search(rf'\(defun {name}\b.*?(?=\n\(defun |\Z)',s,re.S)
 if not m or call not in m.group(0):
  raise SystemExit(f'{name} does not route through {call}')
setter=re.search(r'\(defun \(setf card-table-dirty-gen\).*?(?=\n\(defun |\Z)',s,re.S)
if not setter or 'atomic-update-card-table-dirty-gen' not in setter.group(0):
 raise SystemExit('card-table-dirty-gen setter does not route through atomic helper')
allocate_function=re.search(r'\(defun %allocate-function \(.*?(?=\n\(defun |\Z)',s,re.S)
if not allocate_function:
 raise SystemExit('Missing exact %allocate-function production form')
if '(not wiredp)' in allocate_function.group(0):
 raise SystemExit('wired post-GC function expansion is still excluded')
release=re.search(r'\(defun release-stack-virtual-region\b.*?(?=\n\(defun |\Z)',s,re.S)
if not release or re.search(r'\((?:cons|push)\b', release.group(0), re.I):
 raise SystemExit('stack virtual-region release allocates while linking')
atomic=re.search(r'\(defun atomic-update-card-table-dirty-gen\b.*?(?=\n\(defun |\Z)',s,re.S)
if not atomic or '(cas ' not in atomic.group(0).lower():
 raise SystemExit('card dirty-generation update is not guarded by CAS')
stack=re.search(r'\(defun %allocate-stack\b.*?(?=\n\(defun |\Z)',s,re.S)
if not stack or '(setf stack-address nil)' not in stack.group(0):
 raise SystemExit('stack finalizer does not claim the reservation exactly once')
print('runtime allocator source contract passed')
PY

python3 - "$source_file" "$test_file" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()

def form(marker):
 start=s.index(marker); depth=0; string=False; escape=False; comment=False
 for i in range(start,len(s)):
  c=s[i]
  if comment:
   if c=='\n': comment=False
  elif string:
   if escape: escape=False
   elif c=='\\': escape=True
   elif c=='"': string=False
  elif c==';': comment=True
  elif c=='"': string=True
  elif c=='(': depth+=1
  elif c==')':
   depth-=1
   if depth==0:return s[start:i+1]
 raise RuntimeError(marker)

runtime=[form(x) for x in (
 '(defun update-freelist-card-offsets',
 '(defvar *maximum-young-generation-size*',
 '(defun allocation-area-growth-permitted-p',
 '(defun young-generation-size',
 '(defun expand-allocation-area',
 '(defun copy-symbol-name-to-wired-area',
 '(defun make-symbol',
 '(defun finish-expand-wired-function-area',
 '(defun expand-function-area',
 '(defun %allocate-function (',
 '(defun valid-funcallable-instance-layout-p',
 '(defun funcallable-instance-entry-point',
 '(defun sys.int::%allocate-funcallable-instance',
)]
supervisor=[form('(defun allocate-stack-virtual-region'),
            form('(defun release-stack-virtual-region'),
            form('(defun %allocate-stack')]
internals=[form('(defun atomic-update-card-table-dirty-gen'),
           form('(defun (setf card-table-dirty-gen)')]
Path(sys.argv[2]).write_text(r'''
(defpackage :mezzano.internals (:use :cl) (:nicknames :sys.int))
(in-package :mezzano.internals)
(defconstant +card-size+ 64)
(defconstant +card-table-entry-offset+ (byte 5 0))
(defconstant +card-table-base+ 0)
(defconstant +card-table-entry-dirty-gen+ (byte 2 8))
(defconstant +object-tag-function+ 60)
(defconstant +object-tag-funcallable-instance+ 61)
(defconstant +function-entry-point+ 0)
(defconstant +funcallable-instance-function+ 1)
(defconstant +object-tag-freelist-entry+ 1)
(defconstant +object-type-shift+ 2)
(defconstant +object-data-shift+ 8)
(defconstant +address-tag-stack+ 4)
(defconstant +address-tag-shift+ 44)
(defconstant +address-tag-general+ 1)
(defconstant +block-map-present+ 1)
(defconstant +block-map-writable+ 2)
(defconstant +block-map-zero-fill+ 4)
(defconstant +block-map-track-dirty+ 8)
(defconstant +block-map-wired+ 16)
(defconstant +allocation-minimum-alignment+ 256)
(defconstant +symbol-name+ 0)
(defconstant +symbol-value+ 1)
(defconstant +symbol-function+ 2)
(defconstant +symbol-type+ 3)
(defconstant +symbol-header-hash+ (byte 8 0))
(defconstant +object-tag-symbol+ 62)
(defstruct layout heap-size heap-layout area)
(defvar *wired-function-area-limit* 1000)
(defvar *wired-function-area-free-bins* (make-array 65 :initial-element nil))
(defvar *wired-stack-area-bump* 0)
(defvar *stack-area-bump* 0)
(defvar *wired-stack-free-regions* nil)
(defvar *stack-free-regions* nil)
(defvar *funcallable-instance-trampoline* :trampoline)
(defvar *general-area-young-gen-limit* 0)
(defvar *cons-area-young-gen-limit* 0)
(defvar *young-gen-newspace-bit* 0)
(defvar *gc-enable-logging* nil)
(defvar *function-area-limit* 2000)
(defvar *function-area-base* 1500)
(defvar *function-area-free-bins* (make-array 65 :initial-element nil))
(defvar *wired-function-area-usage* 0)
(defvar *function-area-usage* 0)
(defvar *memory* (make-hash-table :test 'equal))
(defvar *tags* (make-hash-table :test 'eq))
(defvar *entry-points* (make-hash-table :test 'eq))
(defvar *captured-finalizer* nil)
(defvar *cas-conflict-word* nil)
(defvar *cas-attempts* 0)
(defun memref-unsigned-byte-32 (base index) (gethash (list base index) *memory* 0))
(defun (setf memref-unsigned-byte-32) (v base index) (setf (gethash (list base index) *memory*) v))
(defun memref-unsigned-byte-64 (base index) (gethash (list :u64 base index) *memory* 0))
(defun (setf memref-unsigned-byte-64) (v base index) (setf (gethash (list :u64 base index) *memory*) v))
(defun memref-t (base index) (gethash (list :t base index) *memory*))
(defun (setf memref-t) (v base index) (setf (gethash (list :t base index) *memory*) v))
(defmacro cas (place old new)
  `(let ((expected ,old)
         (replacement ,new))
     (incf *cas-attempts*)
     ;; Deterministically model a competing CPU winning immediately before
     ;; the first compare/exchange.
     (when *cas-conflict-word*
       (setf ,place *cas-conflict-word*
             *cas-conflict-word* nil))
     (let ((current ,place))
       (when (eql current expected) (setf ,place replacement))
       current)))
(defun make-freelist-header (len) len)
(defun card-table-offset (address) (gethash (list :card address) *memory*))
(defun (setf card-table-offset) (value address) (setf (gethash (list :card address) *memory*) value))
(defun %object-tag (object) (gethash object *tags*))
(defun %object-ref-unsigned-byte-64 (object slot) (declare (ignore slot)) (gethash object *entry-points*))
(defun (setf %object-ref-unsigned-byte-64) (value object slot)
  (declare (ignore slot)) (setf (gethash object *entry-points*) value))
(defun lisp-object-address (object) (declare (ignore object)) 123)
(defun symbol-global-value (symbol) (symbol-value symbol))
(defun (setf symbol-global-value) (value symbol) (setf (symbol-value symbol) value))
(defun %atomic-fixnum-add-symbol (symbol delta)
  (prog1 (symbol-value symbol) (incf (symbol-value symbol) delta)))
(defun align-up (value alignment)
  (logand (+ value (1- alignment)) (lognot (1- alignment))))
(defun align-down (value alignment)
  (logand value (lognot (1- alignment))))
(defun hash-string (string) (sxhash string))
(defvar *gc-calls* nil)
(defun %gc (&rest arguments) (push arguments *gc-calls*))
(defun %object-ref-t (object slot) (gethash (list object slot) *memory*))
(defun (setf %object-ref-t) (v object slot) (setf (gethash (list object slot) *memory*) v))
(defun %object-header-data (object) (gethash (list :header object) *memory* 0))
(defun (setf %object-header-data) (v object) (setf (gethash (list :header object) *memory*) v))
(defun make-weak-pointer (key &key value finalizer area weakness)
  (declare (ignore value area weakness))
  (setf *captured-finalizer* finalizer)
  key)

(defpackage :mezzano.compiler (:use :cl))
(declaim (declaration mezzano.compiler::closure-allocation))
(defpackage :mezzano.supervisor
 (:use :cl)
 (:shadow #:cons)
 (:export #:with-mutex #:without-footholds
          #:inhibit-thread-pool-blocking-hijack #:with-pseudo-atomic
          #:allocate-memory-range #:get-high-precision-timer
          #:current-thread #:thread-bytes-consed #:debug-print-line))
(in-package :mezzano.supervisor)
(defvar *lock-depth* 0)
(defvar *mapping-results* nil)
(defvar *mapping-calls* nil)
(defvar *released-ranges* nil)
(defvar *world-stopper* nil)
(defvar *thread* :thread)
(defvar *cpu-bytes* 0)
(defvar *thread-bytes* 0)
(defvar *bytes-remaining* 1000000000)
(defvar *cons-fail* nil)
(defvar *cons-calls* nil)
(defun cons (car cdr)
  ;; Model the allocator's slow-cons boundary: allocation is permitted before
  ;; taking the allocator lock and forbidden while the lock is held.
  (push *lock-depth* *cons-calls*)
  (when (plusp *lock-depth*) (error "recursive slow-cons under allocator lock"))
  (when *cons-fail* (error "injected slow-cons OOM"))
  (cl:cons car cdr))
(defmacro with-mutex ((lock) &body body)
  `(progn (unless ,lock (error "missing lock"))
          (unless (zerop *lock-depth*) (error "recursive allocator lock"))
          (incf *lock-depth*)
          (unwind-protect (progn ,@body) (decf *lock-depth*))))
(defmacro without-footholds (&body body) `(progn ,@body))
(defmacro inhibit-thread-pool-blocking-hijack (&body body) `(progn ,@body))
(defmacro with-pseudo-atomic (&body body) `(progn ,@body))
(defun allocate-memory-range (base size flags)
  (push (list base size flags *lock-depth*) *mapping-calls*)
  (let ((result (if *mapping-results* (pop *mapping-results*) t)))
    (if (eq result :error) (error "injected mapping exception") result)))
(defun release-memory-range (base size) (push (list base size) *released-ranges*))
(defun debug-print-line (&rest things) (declare (ignore things)))
(defun get-high-precision-timer () 0)
(defun current-thread () *thread*)
(defun local-cpu () :cpu)
(defun cpu-bytes-consed (cpu) (declare (ignore cpu)) *cpu-bytes*)
(defun (setf cpu-bytes-consed) (v cpu) (declare (ignore cpu)) (setf *cpu-bytes* v))
(defun thread-bytes-consed (thread) (declare (ignore thread)) *thread-bytes*)
(defun (setf thread-bytes-consed) (v thread) (declare (ignore thread)) (setf *thread-bytes* v))
(defun acquire-mutex (lock)
  (unless lock (error "missing lock"))
  (unless (zerop *lock-depth*) (error "recursive allocator lock"))
  (incf *lock-depth*))
(defun release-mutex (lock) (declare (ignore lock)) (decf *lock-depth*))
(defun mutex-held-p (lock) (declare (ignore lock)) (plusp *lock-depth*))
(defun align-up (v a) (logand (+ v (1- a)) (lognot (1- a))))
(defun align-down (v a) (logand v (lognot (1- a))))
(defconstant +stack-guard-size+ #x200000)
(defconstant +stack-region-alignment+ #x200000)
(defstruct (stack (:constructor %make-stack (base size))) base size)

(defpackage :mezzano.runtime
 (:use :cl)
 (:shadow #:make-symbol #:symbol-name #:symbol-value #:symbol-function
          #:symbol-plist #:symbol-package)
 (:local-nicknames (:sys.int :mezzano.internals)))
(in-package :mezzano.runtime)
(defvar *allocator-lock* t)
(defvar *copied-area* nil)
(defvar *copy-inputs* nil)
(defvar *next-object* 0)
(defvar *general-area-expansion-granularity* 256)
(defvar *cons-area-expansion-granularity* 256)
(defvar *allocation-fudge* 0)
(defvar *maximum-allocation-attempts* 5)
(defvar *function-results* nil)
(defvar *normal-finish-count* 0)
(defun copy-string-in-area (s area)
  (push (copy-seq s) *copy-inputs*)
  (setf *copied-area* area)
  (copy-seq s))
(defun %allocate-object (&rest args)
  (declare (ignore args))
  (intern (format nil "OBJECT-~D" (incf *next-object*)) :keyword))
(defun symbol-name (object) (sys.int::%object-ref-t object sys.int::+symbol-name+))
(defun symbol-value (object) (sys.int::%object-ref-t object sys.int::+symbol-value+))
(defun (setf symbol-value) (v object) (setf (sys.int::%object-ref-t object sys.int::+symbol-value+) v))
(defun symbol-function (object) (sys.int::%object-ref-t object sys.int::+symbol-function+))
(defun (setf symbol-function) (v object) (setf (sys.int::%object-ref-t object sys.int::+symbol-function+) v))
(defun symbol-plist (object) (sys.int::%object-ref-t object 10))
(defun (setf symbol-plist) (v object) (setf (sys.int::%object-ref-t object 10) v))
(defun symbol-package (object) (sys.int::%object-ref-t object 11))
(defun (setf symbol-package) (v object) (setf (sys.int::%object-ref-t object 11) v))
(defun bytes-remaining () mezzano.supervisor::*bytes-remaining*)
(defun additional-memory-required-for-gc () 0)
(defun finish-expand-freelist-area (&rest args) (declare (ignore args)) (incf *normal-finish-count*))
(defun %allocate-function-1 (&rest args) (declare (ignore args)) (pop *function-results*))
(defun update-allocation-time (start) (declare (ignore start)))
'''+"\n\n".join(runtime)+r'''

(defun check (value description) (unless value (error "~A" description)))
(defun equal-check (actual expected description)
  (unless (equalp actual expected) (error "~A: ~S /= ~S" description actual expected)))

(setf sys.int::*memory* (make-hash-table :test 'equal))
(update-freelist-card-offsets 10 210)
(equal-check (sys.int::card-table-offset 64) -54 "first card offset")
(equal-check (sys.int::card-table-offset 128) -118 "second card offset")
(equal-check (sys.int::card-table-offset 192) -182 "third card offset")

(let ((*maximum-young-generation-size* 1000))
  (check (allocation-area-growth-permitted-p 800 200 400)
         "growth at GC boundary rejected")
  (check (not (allocation-area-growth-permitted-p 801 200 10000))
         "growth beyond GC boundary accepted")
  (check (not (allocation-area-growth-permitted-p 0 200 399))
         "growth without copy reserve accepted"))

(let* ((source (copy-seq "alpha")) (copy (copy-symbol-name-to-wired-area source)))
  (check (not (eq source copy)) "symbol name was not copied")
  (equal-check copy source "symbol name content")
  (equal-check *copied-area* :wired "symbol name area"))

;; Exercise the production MAKE-SYMBOL path with canonically equivalent but
;; byte-for-byte distinct Unicode names. Neither may be normalized or replaced
;; with a fixture constant.
(let* ((precomposed (coerce (list (code-char #xE9)) 'string))
       (decomposed (coerce (list #\e (code-char #x301)) 'string))
       (first (make-symbol precomposed))
       (second (make-symbol decomposed))
       (first-copy (sys.int::%object-ref-t first sys.int::+symbol-name+))
       (second-copy (sys.int::%object-ref-t second sys.int::+symbol-name+)))
  (check (and (not (eq first-copy precomposed))
              (not (eq second-copy decomposed)))
         "MAKE-SYMBOL published an aliased name")
  (equal-check first-copy precomposed "precomposed symbol name")
  (equal-check second-copy decomposed "decomposed symbol name")
  (check (not (string= first-copy second-copy))
         "MAKE-SYMBOL normalized canonically distinct names")
  (check (and (find precomposed *copy-inputs* :test #'string=)
              (find decomposed *copy-inputs* :test #'string=))
         "MAKE-SYMBOL did not copy both complete inputs"))

;; Execute production dynamic-area expansion. A failed or exceptional mapping
;; must not publish either the limit or the next growth granularity.
(let ((*maximum-young-generation-size* 4096)
      (*general-area-expansion-granularity* 256))
  (setf sys.int::*general-area-young-gen-limit* 0
        sys.int::*cons-area-young-gen-limit* 0
        mezzano.supervisor::*bytes-remaining* 4096
        mezzano.supervisor::*mapping-calls* nil
        mezzano.supervisor::*mapping-results* '(nil))
  (check (not (expand-allocation-area
               :general 256 '*general-area-expansion-granularity*
               'sys.int::*general-area-young-gen-limit*
               sys.int::+address-tag-general+))
         "failed dynamic mapping reported success")
  (equal-check sys.int::*general-area-young-gen-limit* 0
               "failed dynamic mapping published limit")
  (equal-check *general-area-expansion-granularity* 256
               "failed dynamic mapping published granularity")
  (setf mezzano.supervisor::*mapping-results* '(:error))
  (let ((signaled nil))
    (handler-case
        (expand-allocation-area
         :general 256 '*general-area-expansion-granularity*
         'sys.int::*general-area-young-gen-limit*
         sys.int::+address-tag-general+)
      (error () (setf signaled t)))
    (check signaled "dynamic mapping exception was swallowed"))
  (equal-check sys.int::*general-area-young-gen-limit* 0
               "exceptional dynamic mapping published limit")
  (setf mezzano.supervisor::*mapping-results* '(t))
  (check (expand-allocation-area
          :general 256 '*general-area-expansion-granularity*
          'sys.int::*general-area-young-gen-limit*
          sys.int::+address-tag-general+)
         "successful dynamic mapping rejected")
  (equal-check sys.int::*general-area-young-gen-limit* 256
               "successful dynamic mapping did not publish limit"))

;; The young-generation ceiling is checked before invoking the pager.
(let ((*maximum-young-generation-size* 1000)
      (*general-area-expansion-granularity* 256))
  (setf sys.int::*general-area-young-gen-limit* 800
        sys.int::*cons-area-young-gen-limit* 0
        mezzano.supervisor::*bytes-remaining* 10000
        mezzano.supervisor::*mapping-calls* nil
        mezzano.supervisor::*mapping-results* '(t))
  (check (not (expand-allocation-area
               :general 256 '*general-area-expansion-granularity*
               'sys.int::*general-area-young-gen-limit*
               sys.int::+address-tag-general+))
         "dynamic area exceeded the young-generation ceiling")
  (check (null mezzano.supervisor::*mapping-calls*)
         "pager called after young-generation ceiling rejection"))

(setf sys.int::*wired-function-area-limit* 1000
      sys.int::*wired-function-area-free-bins* (make-array 65 :initial-element nil))
(finish-expand-wired-function-area 488 512)
(equal-check sys.int::*wired-function-area-limit* 488 "wired function limit")
(equal-check (svref sys.int::*wired-function-area-free-bins* 7) 488 "wired function bin")

;; Execute production wired expansion and prove failed/exceptional mappings do
;; not publish the downward limit or a freelist entry.
(dolist (mapping-result '(nil :error))
  (setf sys.int::*wired-function-area-limit* 1000
        sys.int::*wired-function-area-free-bins* (make-array 65 :initial-element nil)
        mezzano.supervisor::*mapping-results* (list mapping-result))
  (let ((signaled nil) (result nil))
    (handler-case (setf result (expand-function-area 64 t))
      (error () (setf signaled t)))
    (if (eq mapping-result :error)
        (check signaled "wired mapping exception was swallowed")
        (check (not result) "failed wired mapping reported success")))
  (equal-check sys.int::*wired-function-area-limit* 1000
               "failed wired mapping published limit")
  (check (every #'null sys.int::*wired-function-area-free-bins*)
         "failed wired mapping published freelist entry"))
(setf sys.int::*wired-function-area-limit* 1000
      sys.int::*wired-function-area-free-bins* (make-array 65 :initial-element nil)
      mezzano.supervisor::*mapping-results* '(t))
(check (expand-function-area 64 t) "successful wired mapping rejected")
(equal-check sys.int::*wired-function-area-limit* 488
             "successful wired mapping did not publish limit")

;; Execute the production allocation loop's immediate-success path.
(setf *function-results* '(123)
      mezzano.supervisor::*cpu-bytes* 0
      mezzano.supervisor::*thread-bytes* 0)
(equal-check (%allocate-function 7 9 3 nil) 123
             "production function allocation result")
(equal-check mezzano.supervisor::*cpu-bytes* 32
             "production function allocation CPU accounting")
(equal-check mezzano.supervisor::*thread-bytes* 32
             "production function allocation thread accounting")

(let ((good (sys.int::make-layout :heap-size 3 :heap-layout #*010 :area :wired))
      (short (sys.int::make-layout :heap-size 3 :heap-layout #*01 :area :wired)))
  (check (valid-funcallable-instance-layout-p good) "valid layout rejected")
  (check (not (valid-funcallable-instance-layout-p short)) "short bitmap accepted"))
(let ((compiled #'identity)
      (closure (let ((x 1)) (lambda () x)))
      (layout (sys.int::make-layout :heap-size 3 :heap-layout #*010 :area :wired)))
  (setf (gethash compiled sys.int::*tags*) sys.int::+object-tag-function+
        (gethash compiled sys.int::*entry-points*) 111
        (gethash closure sys.int::*tags*) 59
        (gethash sys.int::*funcallable-instance-trampoline* sys.int::*entry-points*) 222)
  (equal-check (funcallable-instance-entry-point compiled) 111 "direct entry")
  (equal-check (funcallable-instance-entry-point closure) 222 "trampoline entry")
  (let ((object (sys.int::%allocate-funcallable-instance compiled layout)))
    (check object "funcallable allocation")
    (equal-check (gethash object sys.int::*entry-points*) 111
                 "allocated direct entry")
    (equal-check (sys.int::%object-ref-t object
                                        sys.int::+funcallable-instance-function+)
                 compiled "allocated function slot")))

(in-package :mezzano.supervisor)
'''+"\n\n".join(supervisor)+r'''
(setf sys.int::*stack-area-bump* 0 sys.int::*stack-free-regions* nil)
(let ((fresh-node (cons (cons nil nil) nil)))
 (multiple-value-bind (address region-node)
     (allocate-stack-virtual-region #x1000 nil fresh-node)
  (declare (ignore address))
  (let ((base (car (car region-node)))
        (span (cdr (car region-node))))
    (unless (= span #x400000) (error "stack reservation omitted guard span"))
    (release-stack-virtual-region region-node nil)
    (release-stack-virtual-region region-node nil)
    (unless (and (eq sys.int::*stack-free-regions* region-node)
                 (null (cdr region-node)))
      (error "stack region returned more than once"))
    (multiple-value-bind (address-2 region-node-2)
        (allocate-stack-virtual-region #x1000 nil (cons (cons nil nil) nil))
    (declare (ignore address-2))
      (unless (and (eq region-node region-node-2)
                   (= base (car (car region-node-2)))
                   (= span (cdr (car region-node-2))))
        (error "stack slot not reused"))))))

;; Execute production %ALLOCATE-STACK through a failed commit and retry. The
;; rollback is performed while the outer allocator lock is held, but release
;; itself must neither allocate nor recursively acquire the lock.
(setf sys.int::*stack-area-bump* 0
      sys.int::*stack-free-regions* nil
      sys.int::*captured-finalizer* nil
      *mapping-calls* nil
      *mapping-results* '(nil t)
      *released-ranges* nil
      *lock-depth* 0
      *cons-fail* nil
      *cons-calls* nil
      sys.int::*gc-calls* nil
      mezzano.runtime::*maximum-allocation-attempts* 3
      mezzano.supervisor::*bytes-remaining* 1000000000)
(let ((stack (%allocate-stack #x1000 nil)))
  (unless (typep stack 'stack) (error "%ALLOCATE-STACK did not return a stack"))
  (unless (= sys.int::*stack-area-bump* #x400000)
    (error "failed stack commit leaked its virtual reservation"))
  (unless (= (length *mapping-calls*) 2)
    (error "stack commit retry count mismatch"))
  (unless (every #'plusp (mapcar #'fourth *mapping-calls*))
    (error "stack mapping escaped allocator lock"))
  (unless (null sys.int::*stack-free-regions*)
    (error "successfully committed stack remained on free list"))
  (unless (= (length sys.int::*gc-calls*) 1)
    (error "failed stack commit did not trigger one retry GC"))
  (unless (and (= (length *cons-calls*) 2)
               (every #'zerop *cons-calls*))
    (error "stack region node was not fully preallocated outside the lock"))
  (unless sys.int::*captured-finalizer* (error "stack finalizer missing"))
  (funcall sys.int::*captured-finalizer*)
  (funcall sys.int::*captured-finalizer*)
  (unless (= (length *released-ranges*) 1)
    (error "stack finalizer released backing memory more than once"))
  (unless (and sys.int::*stack-free-regions*
               (null (cdr sys.int::*stack-free-regions*)))
    (error "stack finalizer returned virtual region more than once")))

;; An exceptional commit must unwind the lock and return the reservation too.
(setf sys.int::*stack-area-bump* 0
      sys.int::*stack-free-regions* nil
      sys.int::*captured-finalizer* nil
      *mapping-results* '(:error)
      *mapping-calls* nil
      *lock-depth* 0)
(let ((signaled nil))
  (handler-case (%allocate-stack #x1000 nil)
    (error () (setf signaled t)))
  (unless signaled (error "stack mapping exception was swallowed")))
(unless (zerop *lock-depth*)
  (error "stack mapping exception leaked allocator lock"))
(unless (and sys.int::*stack-free-regions*
             (null (cdr sys.int::*stack-free-regions*)))
  (error "stack mapping exception did not roll back reservation"))
(unless (= sys.int::*stack-area-bump* #x400000)
  (error "stack mapping exception advanced bump more than once"))

;; Forced slow-cons OOM happens before the allocator lock or virtual bump is
;; touched; no rollback allocation can therefore recurse into the lock.
(setf sys.int::*stack-area-bump* 0
      sys.int::*stack-free-regions* nil
      *mapping-calls* nil
      *lock-depth* 0
      *cons-fail* t
      *cons-calls* nil)
(let ((signaled nil))
  (handler-case (%allocate-stack #x1000 nil)
    (error () (setf signaled t)))
  (unless signaled (error "forced stack-node slow-cons OOM was swallowed")))
(setf *cons-fail* nil)
(unless (and (= (length *cons-calls*) 1)
             (zerop (first *cons-calls*))
             (zerop *lock-depth*)
             (zerop sys.int::*stack-area-bump*)
             (null sys.int::*stack-free-regions*)
             (null *mapping-calls*))
  (error "slow-cons OOM crossed the allocator-lock/publication boundary"))

(in-package :mezzano.internals)
'''+"\n\n".join(internals)+r'''
(setf *memory* (make-hash-table :test 'equal)
      (memref-unsigned-byte-32 +card-table-base+ 1) #xA5A50000)
(setf (card-table-dirty-gen 64) 2)
(let ((updated (memref-unsigned-byte-32 +card-table-base+ 1)))
 (unless (= (ldb +card-table-entry-dirty-gen+ updated) 3)
  (error "dirty generation not stored"))
 (unless (= (ldb (byte 8 16) updated) #xA5)
  (error "dirty generation damaged unrelated card bits")))
(let ((before (memref-unsigned-byte-32 +card-table-base+ 1)))
  (setf (card-table-dirty-gen 64) 2)
  (unless (= before (memref-unsigned-byte-32 +card-table-base+ 1))
    (error "idempotent dirty generation changed card")))

;; First CAS loses to a competing complete-word update. Production must reread
;; that word, retry, install the requested generation, and retain every field
;; outside the dirty-generation byte.
(let* ((initial #x11220000)
       (competitor #xDA7B0105)
       (dirty-mask (dpb 3 +card-table-entry-dirty-gen+ 0)))
  (setf (memref-unsigned-byte-32 +card-table-base+ 2) initial
        *cas-conflict-word* competitor
        *cas-attempts* 0)
  (atomic-update-card-table-dirty-gen 128 3)
  (let ((updated (memref-unsigned-byte-32 +card-table-base+ 2)))
    (unless (= *cas-attempts* 2)
      (error "card update did not retry after deterministic CAS conflict"))
    (unless (= (ldb +card-table-entry-dirty-gen+ updated) 3)
      (error "CAS retry did not install requested dirty generation"))
    (unless (= (logandc2 updated dirty-mask)
               (logandc2 competitor dirty-mask))
      (error "CAS retry lost a competitor-owned unrelated card bit"))))
(format t "runtime allocator behavior passed~%")
''')
PY

"$sbcl" --noinform --non-interactive --load "$test_file"

if [[ ${ALLOCATOR_SKIP_MUTATION_CHECK:-0} != 1 ]]; then
  mutation_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-runtime-allocate-mutants.XXXXXX")
  for mutation in delete-rollback remove-cas single-attempt-cas constant-alpha unconditional-mapping; do
    mutant="$mutation_dir/$mutation.lisp"
    python3 - "$source_file" "$mutant" "$mutation" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
mutation = sys.argv[3]

def replace_once(old, new):
    global source
    if source.count(old) != 1:
        raise SystemExit(f"mutation anchor count for {mutation}: {source.count(old)}")
    source = source.replace(old, new, 1)

def form_end(start):
    depth = 0
    string = escape = comment = False
    for i in range(start, len(source)):
        c = source[i]
        if comment:
            if c == '\n': comment = False
        elif string:
            if escape: escape = False
            elif c == '\\': escape = True
            elif c == '"': string = False
        elif c == ';': comment = True
        elif c == '"': string = True
        elif c == '(': depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0: return i + 1
    raise SystemExit(f"unterminated form for {mutation}")

if mutation == 'delete-rollback':
    replace_once('(release-stack-virtual-region region-node wired t)', 'nil')
elif mutation == 'remove-cas':
    start = source.index('(defun atomic-update-card-table-dirty-gen')
    end = form_end(start)
    if '(cas ' not in source[start:end].lower():
        raise SystemExit('CAS mutation anchor missing')
    unsafe = '''(defun atomic-update-card-table-dirty-gen (address entry)
  (let* ((index (truncate address +card-size+))
         (word (memref-unsigned-byte-32 +card-table-base+ index))
         (new-word (dpb entry +card-table-entry-dirty-gen+ word)))
    (setf (memref-unsigned-byte-32 +card-table-base+ index) new-word)
    new-word))'''
    source = source[:start] + unsafe + source[end:]
elif mutation == 'single-attempt-cas':
    start = source.index('(defun atomic-update-card-table-dirty-gen')
    end = form_end(start)
    if '(cas ' not in source[start:end].lower():
        raise SystemExit('single-attempt CAS mutation anchor missing')
    single_attempt = '''(defun atomic-update-card-table-dirty-gen (address entry)
  (let* ((index (truncate address +card-size+))
         (word (memref-unsigned-byte-32 +card-table-base+ index))
         (new-word (dpb entry +card-table-entry-dirty-gen+ word)))
    (if (= (ldb +card-table-entry-dirty-gen+ word) entry)
        word
        (when (eq (cas (memref-unsigned-byte-32 +card-table-base+ index)
                       word
                       new-word)
                  word)
          new-word))))'''
    source = source[:start] + single_attempt + source[end:]
elif mutation == 'constant-alpha':
    replace_once('(copy-string-in-area name :wired)',
                 '(copy-string-in-area "alpha" :wired)')
elif mutation == 'unconditional-mapping':
    fn_start = source.index('(defun expand-function-area')
    fn_end = form_end(fn_start)
    call_start = source.index('(mezzano.supervisor:allocate-memory-range',
                              fn_start, fn_end)
    call_end = form_end(call_start)
    call = source[call_start:call_end]
    source = source[:call_start] + f'(progn {call} t)' + source[call_end:]
else:
    raise SystemExit(f'unknown mutation {mutation}')

Path(sys.argv[2]).write_text(source)
PY
    if ALLOCATOR_SOURCE="$mutant" ALLOCATOR_SKIP_MUTATION_CHECK=1 \
         bash "$0" >/dev/null 2>&1; then
      echo "allocator mutation unexpectedly survived: $mutation" >&2
      exit 1
    fi
    echo "allocator mutation rejected: $mutation"
  done
fi
