#!/usr/bin/env bash
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${AHCI_SOURCE:-"$repo_root/supervisor/ahci.lisp"}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-ahci.XXXXXX.lisp")
trap 'python3 - "$test_file" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink(missing_ok=True)
PY' EXIT
python3 - "$source_file" "$test_file" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
def form(marker):
 start=s.index(marker); depth=0; string=escape=comment=False
 for i in range(start,len(s)):
  c=s[i]
  if comment:
   if c=='\n': comment=False
   continue
  if string:
   if escape: escape=False
   elif c=='\\': escape=True
   elif c=='"': string=False
   continue
  if c==';': comment=True
  elif c=='"': string=True
  elif c=='(': depth+=1
  elif c==')':
   depth-=1
   if depth==0:return s[start:i+1]
 raise RuntimeError(marker)
constants=[]
for name in ['+ahci-prdt-maximum-byte-count+','+sata-register-count+','+sata-register-count-exp+',
 '+sata-register-lba-low+','+sata-register-lba-mid+','+sata-register-lba-high+',
 '+sata-register-lba-low-exp+','+sata-register-lba-mid-exp+','+sata-register-lba-high-exp+',
 '+sata-register-device+']:
 constants.append(form('(defconstant '+name))
forms=[form('(defun ahci-dma32-addressable-p'),form('(defun ahci-call-with-dma-buffer'),
 form('(defun ahci-validate-lba-transfer'),form('(defun ahci-flush'),
 form('(defun ahci-maximum-transfer-sectors'),
 form('(defun ahci-setup-lba28'),form('(defun ahci-setup-lba48')]
prefix=r'''
(defpackage :mezzano.supervisor (:use :cl) (:nicknames :sup)
  (:export #:ensure #:safe-sleep))
(defpackage :mezzano.supervisor.ata (:use :cl) (:nicknames :ata)
  (:export #:+ata-lba+ #:+ata-command-flush-cache+
           #:+ata-command-flush-cache-ext+))
(defpackage :mezzano.internals (:use :cl) (:nicknames :sys.int))
(defpackage :mezzano.supervisor.ahci (:use :cl))
(in-package :mezzano.supervisor)
(defconstant +physical-map-base+ #x10000000000)
(defconstant +4k-page-size+ 4096)
(defvar *allocations* 0)
(defvar *releases* 0)
(defmacro ensure (condition) `(unless ,condition (error "ensure failed")))
(defun allocate-physical-pages (count &key mandatory-p 32-bit-only)
  (declare (ignore count mandatory-p))
  (unless 32-bit-only (error "bounce allocation was not DMA32"))
  (incf *allocations*) #x20)
(defun release-physical-pages (frame count)
  (declare (ignore frame count)) (incf *releases*))
(defun convert-to-pmap-address (physical) (+ +physical-map-base+ physical))
(in-package :mezzano.supervisor.ata)
(defconstant +ata-lba+ #x40)
(defconstant +ata-command-flush-cache+ #xe7)
(defconstant +ata-command-flush-cache-ext+ #xea)
(defvar *copies* nil)
(defvar *copy-error* nil)
(defun ata-copy-memory (destination source length)
  (when *copy-error* (error "injected copy failure"))
  (push (list destination source length) *copies*))
(in-package :mezzano.supervisor.ahci)
(defstruct test-port lba48-capable sector-size sector-count atapi-p ahci id)
(defun ahci-port-lba48-capable (p) (test-port-lba48-capable p))
(defun ahci-port-sector-size (p) (test-port-sector-size p))
(defun ahci-port-sector-count (p) (test-port-sector-count p))
(defun ahci-port-atapi-p (p) (test-port-atapi-p p))
(defun ahci-port-ahci (p) (test-port-ahci p))
(defun ahci-port-id (p) (test-port-id p))
(defun ahci-64-bit-p (ahci) ahci)
(defvar *no-data-setup* nil)
(defvar *issued-command* nil)
(defun ahci-setup-no-data (ahci port atapi)
  (setf *no-data-setup* (list ahci port atapi)))
(defun ahci-run-command (ahci port command)
  (setf *issued-command* (list ahci port command))
  t)
(defvar *fis* (make-hash-table))
(defun (setf ahci-fis) (value ahci port offset)
  (declare (ignore ahci port)) (setf (gethash offset *fis*) value))
(defun check (value message) (unless value (error "~A" message)))
(defun signals-error-p (function)
  (handler-case (progn (funcall function) nil)
    (error () t)))
'''
tests=r'''
(check (ahci-dma32-addressable-p #xffffffff 1) "last DMA32 byte rejected")
(check (not (ahci-dma32-addressable-p #xffffffff 2)) "cross-4G range accepted")
(check (not (ahci-dma32-addressable-p -1 1)) "negative physical address accepted")
(let ((sup::*allocations* 0) (sup::*releases* 0) (ata::*copies* nil)
      (buffer (+ sup::+physical-map-base+ #x100000000)))
  (check (= (ahci-call-with-dma-buffer nil buffer 1024 t #'identity) #x20000)
         "bounce physical address wrong")
  (check (= sup::*allocations* 1) "DMA32 bounce was not allocated")
  (check (= sup::*releases* 1) "DMA32 bounce was not released")
  (check (= (length ata::*copies*) 1) "write data was not copied into bounce buffer"))
(let ((sup::*allocations* 0) (sup::*releases* 0) (ata::*copies* nil)
      (buffer (+ sup::+physical-map-base+ #x100000000)))
  (check (ahci-call-with-dma-buffer nil buffer 512 nil (lambda (address)
                                                          (declare (ignore address)) t))
         "bounce read callback failed")
  (check (= (length ata::*copies*) 1) "successful read was not copied back")
  (check (= sup::*releases* 1) "successful read bounce was not released"))
(let ((sup::*allocations* 0) (sup::*releases* 0) (ata::*copies* nil)
      (buffer (+ sup::+physical-map-base+ #x100000000)))
  (check (not (ahci-call-with-dma-buffer nil buffer 512 nil
                                         (lambda (address)
                                           (declare (ignore address)) nil)))
         "failed bounce read reported success")
  (check (null ata::*copies*) "failed read copied uninitialized bounce data back")
  (check (= sup::*releases* 1) "failed read bounce was not released"))
(let ((sup::*allocations* 0) (sup::*releases* 0) (ata::*copy-error* t)
      (buffer (+ sup::+physical-map-base+ #x100000000)))
  (check (signals-error-p
          (lambda ()
            (ahci-call-with-dma-buffer nil buffer 512 t #'identity)))
         "injected bounce copy failure was swallowed")
  (check (= sup::*releases* 1) "copy failure leaked the bounce allocation"))
(let ((p28 (make-test-port :lba48-capable nil :sector-size 512 :sector-count 1000000))
      (p48 (make-test-port :lba48-capable t :sector-size 512 :sector-count 1000000)))
  (check (= (ahci-maximum-transfer-sectors p28) #x100) "LBA28 maximum wrong")
  (check (= (ahci-maximum-transfer-sectors p48) #x2000) "PRDT byte limit not applied")
  (check (ahci-validate-lba-transfer p48 0 8192) "valid LBA48 transfer rejected")
  (check (signals-error-p
          (lambda () (ahci-validate-lba-transfer p28 999900 256)))
         "device-end overrun accepted"))
(let ((p (make-test-port :lba48-capable t :atapi-p nil :ahci :controller :id 3)))
  (setf *no-data-setup* nil *issued-command* nil)
  (check (ahci-flush p) "flush command failed")
  (check (equal *no-data-setup* '(:controller 3 nil)) "flush configured a data PRDT")
  (check (equal *issued-command*
                (list :controller 3 ata:+ata-command-flush-cache-ext+))
         "flush did not issue FLUSH CACHE EXT"))
(clrhash *fis*)
(ahci-setup-lba28 nil 0 (- (ash 1 28) #x100) #x100)
(check (zerop (gethash +sata-register-count+ *fis*)) "LBA28 max count not encoded as zero")
(clrhash *fis*)
(ahci-setup-lba48 nil 0 (- (ash 1 48) #x10000) #x10000)
(check (and (zerop (gethash +sata-register-count+ *fis*))
            (zerop (gethash +sata-register-count-exp+ *fis*)))
       "LBA48 max count not encoded as zero")
(check (signals-error-p (lambda () (ahci-setup-lba28 nil 0 0 257)))
       "oversize LBA28 accepted")
(check (signals-error-p (lambda () (ahci-setup-lba48 nil 0 (ash 1 48) 1)))
       "oversize LBA48 accepted")
(format t "AHCI behavioral contracts passed~%")
'''
Path(sys.argv[2]).write_text(prefix+'\n'.join(constants+forms)+tests)
PY
${SBCL:-sbcl} --noinform --disable-debugger --script "$test_file"

if [[ ${AHCI_SKIP_MUTATIONS:-0} != 1 ]]; then
  mutant_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-ahci-mutants.XXXXXX")
  trap 'rm -rf "$mutant_dir"; rm -f "$test_file"' EXIT
  python3 - "$source_file" "$mutant_dir" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
out = Path(sys.argv[2])
mutations = {
    "capacity.lisp": [(
        "(sup:ensure (<= (+ lba count) (ahci-port-sector-count port-info)))",
        "t")],
    "lba28-count.lisp": [(
        "(sup:ensure (and (integerp count) (<= 1 count #x100)))",
        "(sup:ensure (and (integerp count) (<= 1 count #x101)))")],
    "lba48-lba.lisp": [
        ("(sup:ensure (and (integerp lba) (<= 0 lba) (< lba (ash 1 48))))",
         "t"),
        ("(sup:ensure (<= (+ lba count) (ash 1 48)))", "t"),
    ],
}
for name, replacements in mutations.items():
    mutant = source
    for old, new in replacements:
        if mutant.count(old) != 1:
            raise SystemExit(f"mutation anchor not unique: {old}")
        mutant = mutant.replace(old, new, 1)
    (out / name).write_text(mutant)
PY
  for mutant in "$mutant_dir"/*.lisp; do
    if AHCI_SKIP_MUTATIONS=1 AHCI_SOURCE="$mutant" "$0" >/dev/null 2>&1; then
      echo "AHCI boundary mutation survived: $(basename "$mutant")" >&2
      exit 1
    fi
  done
  echo "AHCI boundary mutation gates passed"
fi
