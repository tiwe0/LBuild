#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-supervisor-gpt.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

cat >"$test_file" <<'LISP'
(defpackage :sys.int
  (:use :cl))

(defpackage :mezzano.supervisor
  (:use :cl))

(in-package :mezzano.supervisor)

(defconstant +4k-page-size+ 4096)
(defparameter *physical-memory*
  (make-array (* 32 +4k-page-size+)
              :element-type '(unsigned-byte 8)
              :initial-element 0))
(defparameter *next-page* 0)
(defparameter *registered-disks* '())
(defparameter *disks* '())

(defun sys.int::memref-unsigned-byte-8 (base &optional (index 0))
  (aref *physical-memory* (+ base index)))

(defun (setf sys.int::memref-unsigned-byte-8) (value base &optional (index 0))
  (setf (aref *physical-memory* (+ base index)) value))

;; Deliberately make native-width reads unusable. GPT and MBR decoding must be
;; expressed in terms of explicitly ordered octets, not host byte order or
;; potentially unaligned native loads.
(defun sys.int::memref-unsigned-byte-16 (&rest arguments)
  (declare (ignore arguments))
  (error "Native-width 16-bit memref used"))

(defun sys.int::memref-unsigned-byte-32 (&rest arguments)
  (declare (ignore arguments))
  (error "Native-width 32-bit memref used"))

(defun sys.int::memref-unsigned-byte-64 (&rest arguments)
  (declare (ignore arguments))
  (error "Native-width 64-bit memref used"))

(defstruct mock-disk
  bytes
  (sector-size 512)
  (n-sectors 4096)
  (writable-p t)
  (max-transfer 1)
  (reads '()))

(defun disk-sector-size (disk) (mock-disk-sector-size disk))
(defun disk-n-sectors (disk) (mock-disk-n-sectors disk))
(defun disk-writable-p (disk) (mock-disk-writable-p disk))
(defun disk-max-transfer (disk) (mock-disk-max-transfer disk))
(defun disk-device (disk) disk)
(defun disk-read-fn (disk) (declare (ignore disk)) #'mock-read)
(defun disk-write-fn (disk) (declare (ignore disk)) #'mock-write)
(defun disk-flush-fn (disk) (declare (ignore disk)) #'mock-flush)

(defstruct partition disk offset id type)

(defun all-disks () *disks*)

(defun %allocate-physical-pages (n-pages type mandatory-p 32-bit-only)
  (declare (ignore type mandatory-p 32-bit-only))
  (when (<= (+ *next-page* n-pages) 32)
    (prog1 *next-page*
      (incf *next-page* n-pages))))

(defun allocate-physical-pages (n-pages &key mandatory-p &allow-other-keys)
  (declare (ignore mandatory-p))
  (%allocate-physical-pages n-pages :other mandatory-p nil))

(defun convert-to-pmap-address (address) address)
(defun release-physical-pages (&rest arguments) (declare (ignore arguments)))

(defun disk-read (disk lba n-sectors buffer)
  (when (or (minusp lba)
            (minusp n-sectors)
            (> (+ lba n-sectors) (disk-n-sectors disk)))
    (error "Out-of-bounds disk read: ~D + ~D" lba n-sectors))
  (when (> n-sectors (disk-max-transfer disk))
    (error "Read exceeds max transfer: ~D > ~D"
           n-sectors (disk-max-transfer disk)))
  (push (list lba n-sectors) (mock-disk-reads disk))
  (replace *physical-memory* (mock-disk-bytes disk)
           :start1 buffer
           :start2 (* lba (disk-sector-size disk))
           :end2 (* (+ lba n-sectors) (disk-sector-size disk)))
  (values t nil))

(defun mock-read (&rest arguments) (declare (ignore arguments)) t)
(defun mock-write (&rest arguments) (declare (ignore arguments)) t)
(defun mock-flush (&rest arguments) (declare (ignore arguments)) t)

(defun register-disk (&rest arguments)
  (push arguments *registered-disks*)
  t)

(defun debug-print-line (&rest arguments) (declare (ignore arguments)))
(defun panic (control &rest arguments) (apply #'error control arguments))

(load (or (sb-ext:posix-getenv "PARTITION_SOURCE")
          (error "PARTITION_SOURCE is not set")))

(defun assert-true (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(defun assert-equal (expected actual description)
  (unless (equal expected actual)
    (error "~A: expected ~S, got ~S" description expected actual)))

(defun put-u32/le (bytes offset value)
  (dotimes (i 4)
    (setf (aref bytes (+ offset i)) (ldb (byte 8 (* 8 i)) value))))

(defun put-u64/le (bytes offset value)
  (dotimes (i 8)
    (setf (aref bytes (+ offset i)) (ldb (byte 8 (* 8 i)) value))))

(defun vector-crc32 (bytes start end)
  (let ((crc #xffffffff))
    (loop for index from start below end
          do (setf crc (logxor crc (aref bytes index)))
             (dotimes (bit 8)
               (declare (ignore bit))
               (setf crc (if (logbitp 0 crc)
                             (logxor (ash crc -1) #xedb88320)
                             (ash crc -1)))))
    (logxor crc #xffffffff)))

(defun finish-gpt-header-crc (bytes header-lba)
  (let ((header-offset (* header-lba 512)))
    (put-u32/le bytes (+ header-offset 16) 0)
    (put-u32/le bytes (+ header-offset 16)
                (vector-crc32 bytes header-offset (+ header-offset 92)))))

(defun finish-gpt-table-crc (bytes header-lba entry-lba entry-bytes)
  (put-u32/le bytes (+ (* header-lba 512) 88)
              (vector-crc32 bytes (* entry-lba 512)
                            (+ (* entry-lba 512) entry-bytes)))
  (finish-gpt-header-crc bytes header-lba))

(defun write-gpt-header (bytes header-lba backup-lba entry-lba
                         entry-size num-entries entry-crc n-sectors)
  (let ((offset (* header-lba 512)))
    (replace bytes #(69 70 73 32 80 65 82 84) :start1 offset)
    (put-u32/le bytes (+ offset 8) #x00010000)
    (put-u32/le bytes (+ offset 12) 92)
    (put-u32/le bytes (+ offset 20) 0)
    (put-u64/le bytes (+ offset 24) header-lba)
    (put-u64/le bytes (+ offset 32) backup-lba)
    (put-u64/le bytes (+ offset 40) 34)
    (put-u64/le bytes (+ offset 48) (- n-sectors 34))
    (setf (aref bytes (+ offset 56)) #x11
          (aref bytes (+ offset 71)) #x22)
    (put-u64/le bytes (+ offset 72) entry-lba)
    (put-u32/le bytes (+ offset 80) num-entries)
    (put-u32/le bytes (+ offset 84) entry-size)
    (put-u32/le bytes (+ offset 88) entry-crc)
    (finish-gpt-header-crc bytes header-lba)))

(defun disable-backup-gpt (disk)
  (setf (aref (mock-disk-bytes disk)
              (* (1- (disk-n-sectors disk)) (disk-sector-size disk)))
        0))

(defun make-gpt-disk (&key (entry-size 128) (num-entries 5)
                           (entry-lba 2) (used-indices '(4)))
  (let* ((n-sectors 4096)
         (bytes (make-array (* n-sectors 512)
                            :element-type '(unsigned-byte 8)
                            :initial-element 0))
         (entry-bytes (* entry-size num-entries))
         (entry-sectors (ceiling entry-bytes 512))
         (backup-header-lba (1- n-sectors))
         (backup-entry-lba (- backup-header-lba entry-sectors)))
    (dolist (index used-indices)
      (let ((base (+ (* entry-lba 512) (* index entry-size))))
        ;; A non-zero type GUID whose first octet is retained as the legacy
        ;; supervisor partition type.
        (setf (aref bytes base) (+ #x40 index)
              (aref bytes (+ base 15)) #xa5
              (aref bytes (+ base 16)) (+ #x80 index)
              (aref bytes (+ base 31)) #x5a)
        (put-u64/le bytes (+ base 32) (+ 300 (* index 100)))
        (put-u64/le bytes (+ base 40) (+ 349 (* index 100)))))
    (replace bytes bytes
             :start1 (* backup-entry-lba 512)
             :start2 (* entry-lba 512)
             :end2 (+ (* entry-lba 512) entry-bytes))
    (let ((entry-crc (vector-crc32 bytes (* entry-lba 512)
                                   (+ (* entry-lba 512) entry-bytes))))
      (write-gpt-header bytes 1 backup-header-lba entry-lba
                        entry-size num-entries entry-crc n-sectors)
      (write-gpt-header bytes backup-header-lba 1 backup-entry-lba
                        entry-size num-entries entry-crc n-sectors))
    (make-mock-disk :bytes bytes :n-sectors n-sectors)))

(defun reset-fixture ()
  (fill *physical-memory* 0)
  (setf *next-page* 0
        *registered-disks* '()
        *disks* '()))

(defun detected-partitions ()
  (mapcar #'first (reverse *registered-disks*)))

;; Explicit little-endian decoding works even though native-width memrefs in
;; this fixture signal an error.
(reset-fixture)
(setf (aref *physical-memory* 0) #x78
      (aref *physical-memory* 1) #x56
      (aref *physical-memory* 2) #x34
      (aref *physical-memory* 3) #x12
      (aref *physical-memory* 4) #xef
      (aref *physical-memory* 5) #xcd
      (aref *physical-memory* 6) #xab
      (aref *physical-memory* 7) #x90)
(assert-equal #x12345678 (memref-ub32/le 0) "32-bit little-endian read")
(assert-equal #x1234 (memref-ub16/le 0 1) "Indexed 16-bit little-endian read")
(assert-equal #x90abcdef (memref-ub32/le 0 1)
              "Indexed 32-bit little-endian read")
(assert-equal #x90abcdef12345678 (memref-ub64/le 0) "64-bit little-endian read")

;; Entry 4 is stored in the second sector of a standards-sized entry array.
;; The disk permits one sector per transfer, so table reading must also honor
;; the existing block-device max-transfer contract.
(reset-fixture)
(let ((disk (make-gpt-disk)))
  ;; Sector padding is not part of the entry-array CRC.
  (setf (aref (mock-disk-bytes disk) 1700) #xcc)
  (assert-true (detect-gpt-partition-table disk) "Valid GPT was rejected")
  (let ((partitions (detected-partitions)))
    (assert-equal 1 (length partitions) "Wrong GPT partition count")
    (assert-equal 700 (partition-offset (first partitions))
                  "Second-sector entry start LBA")
    (assert-equal 50 (third (first *registered-disks*))
                  "Cross-sector entry size")
    (assert-equal #x44 (partition-type (first partitions))
                  "Partition type compatibility"))
  (assert-true (member '(2 1) (mock-disk-reads disk) :test #'equal)
               "First GPT entry-array sector was not read")
  (assert-true (member '(3 1) (mock-disk-reads disk) :test #'equal)
               "Second GPT entry-array sector was not read"))

;; Header CRC corruption rejects the GPT before publishing any partitions.
(reset-fixture)
(let* ((disk (make-gpt-disk :used-indices '(0 4)))
       (bytes (mock-disk-bytes disk)))
  (disable-backup-gpt disk)
  (setf (aref bytes (+ 512 40)) (logxor 1 (aref bytes (+ 512 40))))
  (assert-true (not (detect-gpt-partition-table disk))
               "Bad header CRC was accepted")
  (assert-true (null *registered-disks*)
               "Bad header CRC published a partition"))

;; Entry-array CRC corruption likewise rejects atomically, including when an
;; earlier entry itself was otherwise valid.
(reset-fixture)
(let* ((disk (make-gpt-disk :used-indices '(0 4)))
       (bytes (mock-disk-bytes disk)))
  (disable-backup-gpt disk)
  (setf (aref bytes (+ (* 2 512) 20)) #xff)
  (assert-true (not (detect-gpt-partition-table disk))
               "Bad entry-array CRC was accepted")
  (assert-true (null *registered-disks*)
               "Bad entry-array CRC published a partial result"))

;; Geometry and table bounds are validated before I/O or publication.
(dolist (mutation
         (list (lambda (bytes) (put-u32/le bytes (+ 512 12) 80))
               (lambda (bytes) (put-u32/le bytes (+ 512 20) 1))
               (lambda (bytes)
                 (setf (aref bytes (+ 512 56)) 0
                       (aref bytes (+ 512 71)) 0))
               (lambda (bytes) (put-u64/le bytes (+ 512 24) 2))
               (lambda (bytes) (put-u64/le bytes (+ 512 40) 4000))
               (lambda (bytes) (put-u64/le bytes (+ 512 72) 4095))
               (lambda (bytes) (put-u32/le bytes (+ 512 80) 100))
               (lambda (bytes) (put-u32/le bytes (+ 512 84) 127))))
  (reset-fixture)
  (let* ((disk (make-gpt-disk))
         (bytes (mock-disk-bytes disk)))
    (disable-backup-gpt disk)
    (funcall mutation bytes)
    ;; Recompute only the header CRC so each case tests field validation.
    (put-u32/le bytes (+ 512 16) 0)
    (put-u32/le bytes (+ 512 16) (vector-crc32 bytes 512 (+ 512 92)))
    (assert-true (not (detect-gpt-partition-table disk))
                 "Malformed GPT geometry was accepted")
    (assert-true (null *registered-disks*)
                 "Malformed GPT geometry published a partition")))

;; A syntactically valid entry outside the usable range invalidates the table
;; without publishing earlier valid entries.
(reset-fixture)
(let* ((disk (make-gpt-disk :used-indices '(0 4)))
       (bytes (mock-disk-bytes disk))
       (entry-size 128)
       (base (+ (* 2 512) (* 4 entry-size))))
  (disable-backup-gpt disk)
  (put-u64/le bytes (+ base 32) 20)
  (finish-gpt-table-crc bytes 1 2 (* 5 entry-size))
  (assert-true (not (detect-gpt-partition-table disk))
               "Out-of-usable-range GPT entry was accepted")
  (assert-true (null *registered-disks*)
               "Invalid GPT entry published a partial result"))

;; A used entry without its required unique GUID invalidates the whole table.
(reset-fixture)
(let* ((disk (make-gpt-disk :used-indices '(0 4)))
       (bytes (mock-disk-bytes disk))
       (base (+ (* 2 512) (* 4 128))))
  (disable-backup-gpt disk)
  (fill bytes 0 :start (+ base 16) :end (+ base 32))
  (finish-gpt-table-crc bytes 1 2 (* 5 128))
  (assert-true (not (detect-gpt-partition-table disk))
               "Used GPT entry without a unique GUID was accepted")
  (assert-true (null *registered-disks*)
               "Invalid unique GUID published a partial result"))

;; GPT 1.0 is the only supported revision; an unknown minor revision is not
;; silently interpreted using 1.0 rules.
(reset-fixture)
(let* ((disk (make-gpt-disk))
       (bytes (mock-disk-bytes disk)))
  (disable-backup-gpt disk)
  (put-u32/le bytes (+ 512 8) #x00010001)
  (finish-gpt-header-crc bytes 1)
  (assert-true (not (detect-gpt-partition-table disk))
               "Unsupported GPT minor revision was accepted"))

;; The primary header's backup pointer is fixed at the disk's final LBA.
(reset-fixture)
(let* ((disk (make-gpt-disk))
       (bytes (mock-disk-bytes disk)))
  (disable-backup-gpt disk)
  (put-u64/le bytes (+ 512 32) 4094)
  (finish-gpt-header-crc bytes 1)
  (assert-true (not (detect-gpt-partition-table disk))
               "Primary GPT backup LBA did not point to the final sector"))

;; Entry sizes are 128 * 2^n. A merely eight-byte-aligned size is invalid.
(reset-fixture)
(let ((disk (make-gpt-disk :entry-size 160 :num-entries 4
                           :used-indices '(3))))
  (assert-true (not (detect-gpt-partition-table disk))
               "Non-conforming 160-byte GPT entries were accepted")
  (assert-true (null *registered-disks*)
               "Invalid GPT entry size published a partition"))

;; Used partition ranges must be mutually disjoint.
(reset-fixture)
(let* ((disk (make-gpt-disk :used-indices '(0 1)))
       (bytes (mock-disk-bytes disk))
       (second-entry (+ (* 2 512) 128)))
  (disable-backup-gpt disk)
  (put-u64/le bytes (+ second-entry 32) 340)
  (put-u64/le bytes (+ second-entry 40) 410)
  (finish-gpt-table-crc bytes 1 2 (* 5 128))
  (assert-true (not (detect-gpt-partition-table disk))
               "Overlapping used GPT entries were accepted")
  (assert-true (null *registered-disks*)
               "Overlapping GPT entries published a partial result"))

;; A valid empty GPT is still recognized, rather than falling through and
;; treating its protective MBR as a normal partition table.
(reset-fixture)
(let ((disk (make-gpt-disk :used-indices '())))
  (assert-true (detect-gpt-partition-table disk)
               "Valid empty GPT was not recognized")
  (assert-true (null *registered-disks*)
               "Valid empty GPT published a partition"))

;; A damaged primary header is recovered through the independently validated
;; backup header and backup entry array at the end of the disk.
(reset-fixture)
(let* ((disk (make-gpt-disk))
       (bytes (mock-disk-bytes disk)))
  (setf (aref bytes (+ 512 16)) (logxor #xff (aref bytes (+ 512 16))))
  (assert-true (detect-gpt-partition-table disk)
               "Valid backup GPT did not recover a corrupt primary")
  (assert-equal 1 (length *registered-disks*)
                "Backup GPT recovery partition count")
  (assert-true (member '(4095 1) (mock-disk-reads disk) :test #'equal)
               "Backup GPT header was not read")
  (assert-true (member '(4093 1) (mock-disk-reads disk) :test #'equal)
               "First backup entry-array sector was not read")
  (assert-true (member '(4094 1) (mock-disk-reads disk) :test #'equal)
               "Second backup entry-array sector was not read"))

;; If neither GPT header validates, a protective 0xEE MBR is metadata rather
;; than a user partition and must not be registered.
(reset-fixture)
(let* ((disk (make-gpt-disk :used-indices '()))
       (bytes (mock-disk-bytes disk)))
  (disable-backup-gpt disk)
  (setf (aref bytes (+ 512 16)) (logxor #xff (aref bytes (+ 512 16)))
        (aref bytes #x1fe) #x55
        (aref bytes #x1ff) #xaa
        (aref bytes (+ #x1be 4)) #xee)
  (put-u32/le bytes (+ #x1be 8) 1)
  (put-u32/le bytes (+ #x1be 12) 4095)
  (setf *disks* (list disk))
  (detect-disk-partitions)
  (assert-true (null *registered-disks*)
               "Protective MBR was registered as a normal partition"))

;; Rejecting a corrupt GPT must leave the established MBR fallback intact.
(reset-fixture)
(let* ((disk (make-gpt-disk :used-indices '()))
       (bytes (mock-disk-bytes disk)))
  (disable-backup-gpt disk)
  (setf (aref bytes (+ 512 16)) (logxor #xff (aref bytes (+ 512 16)))
        (aref bytes #x1fe) #x55
        (aref bytes #x1ff) #xaa
        (aref bytes (+ #x1be 4)) #x83)
  (put-u32/le bytes (+ #x1be 8) 2048)
  (put-u32/le bytes (+ #x1be 12) 128)
  (setf *disks* (list disk))
  (detect-disk-partitions)
  (let ((partitions (detected-partitions)))
    (assert-equal 1 (length partitions) "MBR fallback partition count")
    (assert-equal 2048 (partition-offset (first partitions))
                  "MBR fallback start LBA")
    (assert-equal #x83 (partition-type (first partitions))
                  "MBR fallback type")))

(format t "supervisor GPT validation contract passed~%")
LISP

PARTITION_SOURCE="$repo_root/supervisor/partition.lisp" \
  "$sbcl" --noinform --disable-debugger --script "$test_file"
