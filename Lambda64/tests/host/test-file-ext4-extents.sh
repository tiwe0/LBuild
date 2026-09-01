#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${EXT4_SOURCE:-"$repo_root/file/ext4.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-file-ext4-extents.XXXXXX.lisp")
trap 'python3 - "$test_file" <<'"'"'PY'"'"'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink(missing_ok=True)
PY' EXIT

python3 - "$source_file" "$test_file" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
output_path = Path(sys.argv[2])


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
    extract_form("(defstruct extent-header", "extent header structure"),
    extract_form("(defun read-extent-header", "extent header reader"),
    extract_form("(defstruct extent\n", "extent structure"),
    extract_form("(defun read-extent (", "extent reader"),
    extract_form("(defstruct extent-index", "extent index structure"),
    extract_form("(defun read-extent-index", "extent index reader"),
    extract_form("(defun walk-extent-node", "extent tree traversal"),
    extract_form("(defun do-file", "file block traversal"),
]

# The three 64-bit block counters concatenate a 32-bit high word and a 32-bit
# low word. A 64-bit shift leaves an erroneous 32-bit hole in the value.
for offset, description in ((336, "blocks-count"),
                            (340, "reserved-blocks-count"),
                            (344, "free-blocks-count")):
    expression = f"(ash (sys.int::ub32ref/le superblock {offset}) 32)"
    if expression not in source:
        raise SystemExit(
            f"ext4 {description} does not shift its high 32-bit word by 32"
        )

output_path.write_text(
    r'''(defpackage :mezzano.internals
  (:use :cl))

(in-package :mezzano.internals)

(defun ub16ref/le (vector offset)
  (logior (aref vector offset)
          (ash (aref vector (+ offset 1)) 8)))

(defun ub32ref/le (vector offset)
  (logior (ub16ref/le vector offset)
          (ash (ub16ref/le vector (+ offset 2)) 16)))

(defpackage :mezzano.ext4-file-system
  (:use :cl)
  (:local-nicknames (:sys.int :mezzano.internals)))

(in-package :mezzano.ext4-file-system)

;; DO-FILE's legacy indirect-block branch still uses ITERATE. This focused
;; facade never enters that branch, so a rejecting macro keeps the extracted
;; production form executable without adding a host dependency.
(defmacro iter (&rest clauses)
  (declare (ignore clauses))
  '(error "Legacy ITERATE branch unexpectedly used"))

(defconstant +incompat-extents+ 6)
(defconstant +extents-flag+ 19)
(defconstant +inline-data-flag+ 28)

(defstruct test-superblock
  (feature-incompat 0)
  (block-size 64)
  (blocks-count 2000))

(defun superblock-feature-incompat (superblock)
  (test-superblock-feature-incompat superblock))

(defun bytes-per-block (superblock)
  (test-superblock-block-size superblock))

(defun superblock-blocks-count (superblock)
  (test-superblock-blocks-count superblock))

(defstruct inode
  (size 0)
  (flags 0)
  (block (make-array 60 :element-type '(unsigned-byte 8))))

(defvar *disk-blocks* (make-hash-table))
(defvar *disk-reads* '())

(defun read-block (disk superblock block-n &optional (n-blocks 1))
  (declare (ignore disk superblock))
  (assert (= n-blocks 1))
  (push block-n *disk-reads*)
  (or (gethash block-n *disk-blocks*)
      (make-array 64 :element-type '(unsigned-byte 8)
                     :initial-element (mod (1+ block-n) 256))))

(defun follow-pointer (&rest arguments)
  (declare (ignore arguments))
  (error "Legacy pointer traversal unexpectedly used"))

'''
    + "\n\n".join(forms)
    + r'''

(defun put-u16 (vector offset value)
  (setf (aref vector offset) (ldb (byte 8 0) value)
        (aref vector (+ offset 1)) (ldb (byte 8 8) value))
  vector)

(defun put-u32 (vector offset value)
  (put-u16 vector offset (ldb (byte 16 0) value))
  (put-u16 vector (+ offset 2) (ldb (byte 16 16) value))
  vector)

(defun make-node (depth entries &optional (size 64))
  (let ((node (make-array size :element-type '(unsigned-byte 8)
                               :initial-element 0)))
    (put-u16 node 0 #xf30a)
    (put-u16 node 2 entries)
    (put-u16 node 4 (floor (- size 12) 12))
    (put-u16 node 6 depth)
    node))

(defun put-index (node offset logical-block leaf-block)
  (put-u32 node offset logical-block)
  (put-u32 node (+ offset 4) (ldb (byte 32 0) leaf-block))
  (put-u16 node (+ offset 8) (ldb (byte 16 32) leaf-block))
  node)

(defun put-extent (node offset logical-block raw-length physical-block)
  (put-u32 node offset logical-block)
  (put-u16 node (+ offset 4) raw-length)
  (put-u16 node (+ offset 6) (ldb (byte 16 32) physical-block))
  (put-u32 node (+ offset 8) (ldb (byte 32 0) physical-block))
  node)

(defun assert-true (condition control &rest arguments)
  (unless condition
    (apply #'error control arguments)))

(defun assert-signals-error (thunk control &rest arguments)
  (unless (handler-case (progn (funcall thunk) nil)
            (error () t))
    (apply #'error control arguments)))

(defun assert-signals-error-containing (thunk expected control &rest arguments)
  (let ((condition (handler-case (progn (funcall thunk) nil)
                     (error (condition) condition))))
    (unless condition
      (apply #'error control arguments))
    (unless (search expected (princ-to-string condition) :test #'char-equal)
      (error "~?; got different error: ~A" control arguments condition))))

;; The on-disk logical block number is 32 bits, and the high length bit marks
;; an unwritten extent whose logical length excludes that marker bit.
(let* ((bytes (make-array 12 :element-type '(unsigned-byte 8)
                             :initial-element 0)))
  (put-extent bytes 0 #x12345678 #x8003 #x123456789abc)
  (let ((extent (read-extent bytes 0)))
    (assert-true (= (extent-n-block extent) #x12345678)
                 "Extent logical block was truncated: ~X" (extent-n-block extent))
    (assert-true (= (extent-length extent) 3)
                 "Unwritten extent length retained its marker bit")
    (assert-true (not (extent-initialized-p extent))
                 "Unwritten extent was reported initialized")
    (assert-true (= (extent-start-block extent) #x123456789abc)
                 "48-bit extent physical address was decoded incorrectly"))
  (put-u16 bytes 4 #x8000)
  (let ((extent (read-extent bytes 0)))
    (assert-true (= (extent-length extent) #x8000)
                 "Maximum initialized extent length was decoded incorrectly")
    (assert-true (extent-initialized-p extent)
                 "Length #x8000 must remain initialized"))
  (put-u16 bytes 4 0)
  (assert-signals-error (lambda () (read-extent bytes 0))
                        "A zero-length extent was accepted"))

;; Traverse a two-level tree. Logical block zero is sparse, blocks one and two
;; are initialized, and blocks three and four are unwritten. Neither sparse nor
;; unwritten blocks may trigger reads of their physical placeholder address.
(let* ((superblock (make-test-superblock :feature-incompat (ash 1 +incompat-extents+)
                                         :block-size 64))
       (root (make-node 2 1 60))
       (branch (make-node 1 1))
       (leaf (make-node 0 2))
       (inode (make-inode :size (* 5 64)
                          :flags (ash 1 +extents-flag+)
                          :block root))
       (result '()))
  (put-index root 12 1 10)
  (put-index branch 12 1 20)
  (put-extent leaf 12 1 2 100)
  (put-extent leaf 24 3 #x8002 999)
  (setf *disk-blocks* (make-hash-table)
        *disk-reads* '()
        (gethash 10 *disk-blocks*) branch
        (gethash 20 *disk-blocks*) leaf)
  (do-file (lambda (block) (push (aref block 0) result))
           :mock-disk superblock inode)
  (assert-true (equal (nreverse result) '(0 101 102 0 0))
               "Extent traversal returned wrong logical blocks: ~S"
               (nreverse result))
  (assert-true (equal (nreverse *disk-reads*) '(10 20 100 101))
               "Extent traversal performed wrong disk reads: ~S"
               (nreverse *disk-reads*)))

;; Every child must decrease the advertised depth exactly; accepting a corrupt
;; tree can reinterpret an index record as a data extent.
(let* ((superblock (make-test-superblock :feature-incompat (ash 1 +incompat-extents+)))
       (root (make-node 2 1 60))
       (bad-child (make-node 0 0))
       (inode (make-inode :size 0
                          :flags (ash 1 +extents-flag+)
                          :block root)))
  (put-index root 12 0 30)
  (setf *disk-blocks* (make-hash-table)
        *disk-reads* '()
        (gethash 30 *disk-blocks*) bad-child)
  (assert-signals-error
   (lambda () (do-file (lambda (block) (declare (ignore block)))
                       :mock-disk superblock inode))
   "A child with an invalid extent-tree depth was accepted"))

;; Header entry counts must fit both eh_max and the containing node, and index
;; keys must be strictly increasing.
(let ((bad-header (make-node 0 2)))
  (put-u16 bad-header 4 1)
  (assert-signals-error (lambda () (read-extent-header bad-header))
                        "An extent header with entries above eh_max was accepted"))

(let ((zero-capacity-header (make-node 0 0)))
  (put-u16 zero-capacity-header 4 0)
  (assert-signals-error-containing
   (lambda () (read-extent-header zero-capacity-header))
   "zero-capacity"
   "An extent header with zero eh_max was accepted"))

(dolist (root (list (make-node 6 0 60)
                    (make-node 1 0 60)))
  (let ((superblock (make-test-superblock
                     :feature-incompat (ash 1 +incompat-extents+)))
        (inode (make-inode :size 0
                           :flags (ash 1 +extents-flag+)
                           :block root)))
    (assert-signals-error-containing
     (lambda () (do-file (lambda (block) (declare (ignore block)))
                         :mock-disk superblock inode))
     (if (= (sys.int::ub16ref/le root 6) 6)
         "depth 6"
         "empty non-leaf")
     (if (= (sys.int::ub16ref/le root 6) 6)
         "An extent root deeper than five levels was accepted"
         "A non-leaf extent root with no entries was accepted"))))

(let* ((superblock (make-test-superblock :feature-incompat (ash 1 +incompat-extents+)))
       (root (make-node 1 2 60))
       (leaf (make-node 0 1))
       (inode (make-inode :size 0
                          :flags (ash 1 +extents-flag+)
                          :block root)))
  (put-index root 12 8 31)
  (put-index root 24 7 32)
  (put-extent leaf 12 8 1 100)
  (setf *disk-blocks* (make-hash-table)
        *disk-reads* '()
        (gethash 31 *disk-blocks*) leaf
        (gethash 32 *disk-blocks*) leaf)
  (assert-signals-error-containing
   (lambda () (do-file (lambda (block) (declare (ignore block)))
                       :mock-disk superblock inode))
   "Unordered ext4 extent index"
   "Unordered extent-index keys were accepted"))

;; An index key is the first logical block in its child. Child subtrees must
;; remain inside the half-open range bounded by that key and the next sibling,
;; even when inode-size prevents DO-FILE from emitting any data blocks.
(let* ((superblock (make-test-superblock :feature-incompat (ash 1 +incompat-extents+)))
       (root (make-node 1 1 60))
       (leaf (make-node 0 1))
       (inode (make-inode :size 0
                          :flags (ash 1 +extents-flag+)
                          :block root)))
  (put-index root 12 5 40)
  (put-extent leaf 12 6 1 100)
  (setf *disk-blocks* (make-hash-table)
        *disk-reads* '()
        (gethash 40 *disk-blocks*) leaf)
  (assert-signals-error-containing
   (lambda () (do-file (lambda (block) (declare (ignore block)))
                       :mock-disk superblock inode))
   "does not begin at index key"
   "A child whose first key differs from its parent index was accepted"))

(let* ((superblock (make-test-superblock :feature-incompat (ash 1 +incompat-extents+)))
       (root (make-node 1 2 60))
       (first-leaf (make-node 0 1))
       (second-leaf (make-node 0 1))
       (inode (make-inode :size 0
                          :flags (ash 1 +extents-flag+)
                          :block root)))
  (put-index root 12 5 41)
  (put-index root 24 10 42)
  (put-extent first-leaf 12 5 6 100)
  (put-extent second-leaf 12 10 1 200)
  (setf *disk-blocks* (make-hash-table)
        *disk-reads* '()
        (gethash 41 *disk-blocks*) first-leaf
        (gethash 42 *disk-blocks*) second-leaf)
  (assert-signals-error-containing
   (lambda () (do-file (lambda (block) (declare (ignore block)))
                       :mock-disk superblock inode))
   "crosses index boundary"
   "An extent crossing into its sibling index range was accepted"))

;; Leaf validation is metadata validation, not a side effect of emitting file
;; blocks. Overlap and descending keys must fail even for a zero-sized inode.
(dolist (starts '((5 7) (6 5)))
  (let* ((superblock (make-test-superblock
                      :feature-incompat (ash 1 +incompat-extents+)))
         (root (make-node 0 2 60))
         (inode (make-inode :size 0
                            :flags (ash 1 +extents-flag+)
                            :block root)))
    (put-extent root 12 (first starts) 3 100)
    (put-extent root 24 (second starts) 1 200)
    (assert-signals-error-containing
     (lambda () (do-file (lambda (block) (declare (ignore block)))
                         :mock-disk superblock inode))
     "Overlapping ext4 extent"
     "Invalid leaf extent order ~S was accepted" starts)))

;; Extent metadata may not name a tree block outside the filesystem. Reject it
;; before READ-BLOCK is called so a different invalid child cannot mask the
;; missing range check.
(let* ((superblock (make-test-superblock
                    :feature-incompat (ash 1 +incompat-extents+)
                    :blocks-count 100))
       (root (make-node 1 1 60))
       (inode (make-inode :size 0
                          :flags (ash 1 +extents-flag+)
                          :block root)))
  (put-index root 12 0 100)
  (setf *disk-blocks* (make-hash-table)
        *disk-reads* '())
  (assert-signals-error-containing
   (lambda () (do-file (lambda (block) (declare (ignore block)))
                       :mock-disk superblock inode))
   "index block exceeds filesystem"
   "An out-of-range extent-index child block was accepted")
  (assert-true (null *disk-reads*)
               "Out-of-range extent-index block was read before validation"))

;; Every physical range is checked in full even if inode-size is zero. This
;; includes unwritten extents: they return logical zeros but still describe
;; allocated filesystem blocks. A range ending exactly at blocks-count is valid.
(let* ((superblock (make-test-superblock
                    :feature-incompat (ash 1 +incompat-extents+)
                    :blocks-count 100))
       (bad-root (make-node 0 1 60))
       (boundary-root (make-node 0 1 60))
       (unwritten-root (make-node 0 1 60))
       (logical-boundary-root (make-node 0 1 60))
       (logical-overflow-root (make-node 0 1 60)))
  (put-extent bad-root 12 0 2 99)
  (put-extent boundary-root 12 0 2 98)
  (put-extent unwritten-root 12 0 #x8001 999)
  (put-extent logical-boundary-root 12 #xffffffff 1 10)
  (put-extent logical-overflow-root 12 #xffffffff 2 10)
  (assert-signals-error-containing
   (lambda ()
     (do-file (lambda (block) (declare (ignore block)))
              :mock-disk superblock
              (make-inode :size 0
                          :flags (ash 1 +extents-flag+)
                          :block bad-root)))
   "physical range exceeds filesystem"
   "An initialized extent crossing blocks-count was accepted")
  (setf *disk-reads* '())
  (do-file (lambda (block) (declare (ignore block)))
           :mock-disk superblock
           (make-inode :size 0
                       :flags (ash 1 +extents-flag+)
                       :block boundary-root))
  (assert-true (null *disk-reads*)
               "A boundary-only validation unexpectedly read file data")
  (assert-signals-error-containing
   (lambda ()
     (do-file (lambda (block) (declare (ignore block)))
              :mock-disk superblock
              (make-inode :size 64
                          :flags (ash 1 +extents-flag+)
                          :block unwritten-root)))
   "physical range exceeds filesystem"
   "An unwritten extent crossing blocks-count was accepted")
  (do-file (lambda (block) (declare (ignore block)))
           :mock-disk superblock
           (make-inode :size 0
                       :flags (ash 1 +extents-flag+)
                       :block logical-boundary-root))
  (assert-signals-error-containing
   (lambda ()
     (do-file (lambda (block) (declare (ignore block)))
              :mock-disk superblock
              (make-inode :size 0
                          :flags (ash 1 +extents-flag+)
                          :block logical-overflow-root)))
   "logical range exceeds 32-bit address space"
   "An extent whose logical end exceeds 2^32 was accepted"))

;; Inline data is exposed through the block cache, so it must have exactly the
;; filesystem block size while retaining all 60 inode bytes and zero padding.
(let* ((superblock (make-test-superblock :block-size 128))
       (payload (make-array 60 :element-type '(unsigned-byte 8)))
       (result nil))
  (dotimes (index 60)
    (setf (aref payload index) index))
  (do-file (lambda (block) (setf result block))
           :mock-disk superblock
           (make-inode :size 60
                       :flags (ash 1 +inline-data-flag+)
                       :block payload))
  (assert-true (= (length result) 128)
               "Inline data returned a ~D-byte buffer instead of one block"
               (length result))
  (assert-true (equalp (subseq result 0 60) payload)
               "Inline data payload changed")
  (assert-true (every #'zerop (subseq result 60))
               "Inline data block padding was not zero-filled")
  (assert-signals-error
   (lambda ()
     (do-file (lambda (block) (declare (ignore block)))
              :mock-disk
              (make-test-superblock :block-size 32)
              (make-inode :size 60
                          :flags (ash 1 +inline-data-flag+)
                          :block payload)))
   "An undersized inline-data block silently truncated the payload"))

(format t "ext4 extent-tree, unwritten-extent, and inline-data contracts passed~%")
''',
    encoding="utf-8",
)
PY

"$sbcl" --noinform --disable-debugger --script "$test_file"
