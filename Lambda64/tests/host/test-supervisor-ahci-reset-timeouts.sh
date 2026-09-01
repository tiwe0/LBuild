#!/usr/bin/env bash
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${AHCI_SOURCE:-"$repo_root/supervisor/ahci.lisp"}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-ahci-reset.XXXXXX.lisp")
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
names=['+ahci-comreset-minimum-seconds+','+ahci-port-stop-timeout-seconds+',
 '+ahci-port-link-timeout-seconds+','+ahci-command-timeout-seconds+',
 '+ahci-register-PxCMD+','+ahci-register-PxSCTL+',
 '+ahci-register-PxSSTS+','+ahci-register-PxSERR+','+ahci-register-PxTFD+',
 '+ahci-register-PxIS+','+ahci-register-PxCI+','+ahci-register-IS+',
 '+ahci-PxCMD-ST+','+ahci-PxCMD-CR+','+ahci-PxSCTL-DET-size+',
 '+ahci-PxSCTL-DET-position+','+ahci-PxSSTS-DET-position+',
 '+ahci-PxSSTS-DET-size+','+ahci-PxSSTS-DET-ready+',
 '+ahci-PxTFD-STS-size+','+ahci-PxTFD-STS-position+','+ahci-PxIS-TFES+',
 '+ahci-ch-PRDBC+','+sata-register-fis-type+','+sata-fis-register-h2d+',
 '+sata-register-command-register-update-field+',
 '+sata-register-command-register-update-bit+','+sata-register-command+',
 '+sata-register-status+', '+ahci-PxCMD-FRE+', '+ahci-PxCMD-FR+',
 '+ahci-register-PxCLB+', '+ahci-register-PxCLBU+', '+ahci-register-PxFB+',
 '+ahci-register-PxFBU+', '+ahci-register-PxIE+', '+ahci-register-CAP+',
 '+ahci-command-header-size+', '+ahci-maximum-n-command-headers+',
 '+ahci-rfis-size+', '+ahci-PxSCTL-IPM-size+', '+ahci-PxSCTL-IPM-position+',
 '+ahci-PxSCTL-IPM-partial-and-slumber-disabled+', '+ahci-PxCMD-CPD+',
 '+ahci-PxCMD-POD+', '+ahci-CAP-SSS+', '+ahci-PxCMD-SUD+',
 '+ahci-PxCMD-ICC-size+', '+ahci-PxCMD-ICC-position+',
 '+ahci-PxCMD-ICC-active+', '+ahci-PxIS-DHRS+', '+ahci-PxIS-SDBS+',
 '+ahci-PxIS-PSS+', '+ahci-PxIS-DSS+', '+ahci-PxIS-DPS+',
 '+ahci-PxIS-UFS+', '+ahci-PxIS-IPMS+', '+ahci-PxIS-OFS+',
 '+ahci-PxIS-INFS+', '+ahci-PxIS-IFS+', '+ahci-PxIS-HBDS+',
 '+ahci-PxIS-HBFS+', '+ahci-ch-descriptor-information+',
 '+ahci-ch-di-CFL-position+', '+ahci-ch-di-PRDTL-position+',
 '+ahci-ch-di-P+', '+ahci-ch-CTBA+', '+ahci-ch-CTBAU+',
 '+sata-register-fis-size+']
constants=[form('(defconstant '+n) for n in names]
forms=[form('(defun ahci-wait-port-bits-clear'),form('(defun ahci-wait-port-field'),
       form('(defun ahci-port-reset'),form('(defun ahci-run-command'),
       form('(defun ahci-initialize-port')]
prefix=r'''
(defpackage :mezzano.supervisor (:use :cl) (:nicknames :sup)
 (:export #:timer-arm #:timer-expired-p #:timer-disarm-absolute
          #:safe-sleep #:debug-print-line))
(defpackage :mezzano.supervisor.ata (:use :cl) (:nicknames :ata)
 (:export #:+ata-bsy+ #:+ata-drq+ #:+ata-err+))
(defpackage :mezzano.internals (:use :cl) (:nicknames :sys.int))
(defpackage :mezzano.supervisor.ahci (:use :cl))
(in-package :mezzano.supervisor)
(defconstant +4k-page-size+ 4096)
(defvar *expire* t)
(defvar *sleeps* nil)
(defvar *disarms* 0)
(defun timer-arm (seconds timer) (declare (ignore seconds timer)))
(defun timer-expired-p (timer) (declare (ignore timer)) *expire*)
(defun timer-disarm-absolute (timer) (declare (ignore timer)) (incf *disarms*))
(defun safe-sleep (seconds) (push seconds *sleeps*))
(defun debug-print-line (&rest values) (declare (ignore values)))
(defun physical-memref-unsigned-byte-32 (base index)
  (declare (ignore base index)) 0)
(defun (setf physical-memref-unsigned-byte-32) (value base index)
  (declare (ignore base index)) value)
(defun allocate-physical-pages (count &key mandatory-p 32-bit-only)
  (declare (ignore count mandatory-p 32-bit-only)) 1)
(defun zeroize-physical-page (address) (declare (ignore address)))
(in-package :mezzano.supervisor.ata)
(defconstant +ata-bsy+ #x80)
(defconstant +ata-drq+ #x08)
(defconstant +ata-err+ #x01)
(in-package :mezzano.supervisor.ahci)
(defvar *registers* (make-hash-table :test #'equal))
(defvar *global-registers* (make-hash-table :test #'equal))
(defvar *reset-det-writes* 0)
(defstruct fake-port irq-timeout-timer command-list received-fis command-table)
(defvar *port* (make-fake-port :irq-timeout-timer :timer))
(defvar *ports* (vector *port*))
(defvar *pxcmd-writes* 0)
(defvar *base-writes* 0)
(defun ahci-port (ahci port) (declare (ignore ahci port)) *port*)
(defun ahci-ports (ahci) (declare (ignore ahci)) *ports*)
(defun ahci-64-bit-p (ahci) (declare (ignore ahci)) t)
(defun ahci-port-irq-timeout-timer (port)
  (fake-port-irq-timeout-timer port))
(defun ahci-port-command-list (port) (fake-port-command-list port))
(defun (setf ahci-port-command-list) (value port)
  (setf (fake-port-command-list port) value))
(defun (setf ahci-port-received-fis) (value port)
  (setf (fake-port-received-fis port) value))
(defun (setf ahci-port-command-table) (value port)
  (setf (fake-port-command-table port) value))
(defun ahci-port-register (ahci port register)
 (declare (ignore ahci port)) (gethash register *registers* 0))
(defun (setf ahci-port-register) (value ahci port register)
 (declare (ignore ahci port))
 (when (= register #x2c) (incf *reset-det-writes*))
 (when (= register #x18)
   (incf *pxcmd-writes*)
   ;; On the reset's stop write, emulate hardware acknowledging CR/FR stop.
   (when (= *pxcmd-writes* 2)
     (setf value (logandc2 value (logior (ash 1 14) (ash 1 15))))))
 (when (member register '(#x00 #x08))
   (check (zerop (logand (gethash #x18 *registers* 0)
                         (logior (ash 1 0) (ash 1 4)
                                 (ash 1 14) (ash 1 15))))
          "CLB/FB programmed while an engine was running")
   (incf *base-writes*))
 (setf (gethash register *registers*) value))
(defun ahci-global-register (ahci register)
  (declare (ignore ahci)) (gethash register *global-registers* 0))
(defun (setf ahci-global-register) (value ahci register)
  (declare (ignore ahci)) (setf (gethash register *global-registers*) value))
(defun (setf ahci-fis) (value ahci port offset)
  (declare (ignore ahci port offset)) value)
(defun ahci-clear-irq-state-buffer (port) (declare (ignore port)))
(defun ahci-pop-irq-state (port) (declare (ignore port)) (values 0 nil))
(defun ahci-rfis (ahci port offset) (declare (ignore ahci port offset)) 0)
(defun check (value message) (unless value (error "~A" message)))
'''
tests=r'''
(clrhash *registers*)
(setf (gethash +ahci-register-PxCMD+ *registers*) 0
      (gethash +ahci-register-PxSSTS+ *registers*) +ahci-PxSSTS-DET-ready+
      (gethash +ahci-register-PxTFD+ *registers*) 0
      sup::*sleeps* nil)
(check (ahci-port-reset :controller 0) "healthy reset failed")
(check (member +ahci-comreset-minimum-seconds+ sup::*sleeps*)
       "COMRESET minimum assertion was not observed")
(clrhash *registers*)
(setf (gethash +ahci-register-PxCMD+ *registers*) (ash 1 +ahci-PxCMD-CR+)
      sup::*expire* t)
(check (not (ahci-port-reset :controller 0)) "stuck command engine did not time out")
(check (plusp sup::*disarms*) "timeout timer was not disarmed")
(clrhash *registers*)
(clrhash *global-registers*)
(setf (gethash +ahci-register-PxCMD+ *registers*) 0
      (gethash +ahci-register-PxSSTS+ *registers*) +ahci-PxSSTS-DET-ready+
      (gethash +ahci-register-PxTFD+ *registers*) 0
      *reset-det-writes* 0
      sup::*expire* t)
(check (not (ahci-run-command :controller 0 #xec))
       "timed-out command reported success")
(check (>= *reset-det-writes* 2)
       "timed-out command did not execute COMRESET assertion/deassertion")
(clrhash *registers*)
(setf *port* (make-fake-port :irq-timeout-timer :timer)
      *ports* (vector *port*)
      *pxcmd-writes* 0
      *base-writes* 0
      (gethash +ahci-register-PxCMD+ *registers*)
      (logior (ash 1 +ahci-PxCMD-ST+) (ash 1 +ahci-PxCMD-FRE+)
              (ash 1 +ahci-PxCMD-CR+) (ash 1 +ahci-PxCMD-FR+))
      (gethash +ahci-register-PxSSTS+ *registers*) +ahci-PxSSTS-DET-ready+
      (gethash +ahci-register-PxTFD+ *registers*) 0
      sup::*expire* t)
(ahci-initialize-port :controller 0)
(check (svref *ports* 0) "recoverable initialize disabled the port")
(check (= *base-writes* 2) "initialize did not safely program CLB and FB")
(format t "AHCI reset timeout contracts passed~%")
'''
Path(sys.argv[2]).write_text(prefix+'\n'.join(constants+forms)+tests)
PY
${SBCL:-sbcl} --noinform --disable-debugger --script "$test_file"

if [[ ${AHCI_SKIP_MUTATIONS:-0} != 1 ]]; then
  mutant=$(mktemp "${TMPDIR:-/tmp}/lambda64-ahci-reset-mutant.XXXXXX.lisp")
  mutant_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-ahci-reset-run.XXXXXX")
  trap 'python3 - "$mutant" "$mutant_tmpdir" "$test_file" <<'"'"'PY'"'"'
from pathlib import Path
import shutil
import sys
Path(sys.argv[1]).unlink(missing_ok=True)
shutil.rmtree(sys.argv[2], ignore_errors=True)
Path(sys.argv[3]).unlink(missing_ok=True)
PY' EXIT
  python3 - "$source_file" "$mutant" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
old = """  (when restart
    (setf (ldb (byte 1 +ahci-PxCMD-ST+)
               (ahci-port-register ahci port +ahci-register-PxCMD+))
          1))"""
new = """  (setf (ldb (byte 1 +ahci-PxCMD-ST+)
             (ahci-port-register ahci port +ahci-register-PxCMD+))
        1)"""
if source.count(old) != 1:
    raise SystemExit("reset restart mutation anchor not unique")
Path(sys.argv[2]).write_text(source.replace(old, new, 1))
PY
  if mutant_output=$(TMPDIR="$mutant_tmpdir" AHCI_SKIP_MUTATIONS=1 \
      AHCI_SOURCE="$mutant" "$0" 2>&1); then
    echo "AHCI reset restart mutation survived" >&2
    exit 1
  fi
  if ! grep -Fq "recoverable initialize disabled the port" <<<"$mutant_output"; then
    echo "AHCI reset restart mutation failed for an unexpected reason" >&2
    printf '%s\n' "$mutant_output" >&2
    exit 1
  fi
  echo "AHCI initialize reset mutation gate passed"
fi
