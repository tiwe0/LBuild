;;;; PL011 UART driver

(in-package :mezzano.supervisor)

;; PL011 implementation.
(defconstant +uart-dr+ #x00)
(defconstant +uart-rsr+ #x04)
(defconstant +uart-fr+ #x18)
(defconstant +uart-ilpr+ #x20)
(defconstant +uart-ibrd+ #x24)
(defconstant +uart-fbrd+ #x28)
(defconstant +uart-lcrh+ #x2c)
(defconstant +uart-cr+ #x30)
(defconstant +uart-ifls+ #x34)
(defconstant +uart-imsc+ #x38)
(defconstant +uart-tris+ #x3c)
(defconstant +uart-tmis+ #x40)
(defconstant +uart-icr+ #x44)
(defconstant +uart-dmacr+ #x48)

(sys.int::defglobal *debug-uart-base*)
(sys.int::defglobal *debug-uart-lock*)
(sys.int::defglobal *uart-at-line-start*)

;; Low-level byte functions.

(defun uart-reg (reg)
  (physical-memref-unsigned-byte-32 (+ *debug-uart-base* reg)))

(defun (setf uart-reg) (value reg)
  (setf (physical-memref-unsigned-byte-32 (+ *debug-uart-base* reg)) value))

(defun debug-uart-write-byte (byte)
  ;; Wait for FIFO to clear.
  (loop
     ;; The TXFE bit seems to be broken on qemu.
     ;; That's fine, the TXFF bit has mostly the same effect.
     (when (not (logbitp 5 (uart-reg +uart-fr+)))
       (return)))
  (setf (uart-reg +uart-dr+) byte))

;; High-level character functions. These assume that whatever is on the other
;; end of the port uses UTF-8 with CRLF newlines.

(defun debug-uart-write-char-1 (char)
  (setf *uart-at-line-start* nil)
  (cond ((eql char #\Newline)
         (setf *uart-at-line-start* t)
         ;; Turn #\Newline into CRLF
         (debug-uart-write-byte #x0D)
         (debug-uart-write-byte #x0A))
        (t
         (with-utf-8-bytes (char byte)
           (debug-uart-write-byte byte)))))

(defun debug-uart-write-char (char)
  (safe-without-interrupts (char)
    (with-symbol-spinlock (*debug-uart-lock*)
      (debug-uart-write-char-1 char))))

(defun debug-uart-write-string (string)
  (safe-without-interrupts (string)
    (with-symbol-spinlock (*debug-uart-lock*)
      (dotimes (i (string-length string))
        (debug-uart-write-char-1 (char string i))))))

;; Boot tracing is also used immediately after a demand-paged function is
;; entered.  MASKING interrupts around STRING-LENGTH would make a fault on a
;; cold string unserviceable (the page-fault handler deliberately rejects
;; faults whose saved DAIF has IRQs masked).  The bootstrap path is single
;; threaded at this point, so write directly without taking the UART lock.
(defun debug-uart-write-string-boot-raw (string)
  (dotimes (i (string-length string))
    (debug-uart-write-char-1 (char string i))))

;; Early cold-boot tracing must not go through DEBUG-PRINT-LINE: before the
;; paging disk is published that path may recurse through the pager.  This
;; writes directly to the already initialized UART and is intentionally kept
;; until the QEMU boot oracle is green.
(defun debug-uart-boot-line (string)
  (when (and (boundp '*debug-uart-base*) *debug-uart-base*)
    (debug-uart-write-string-boot-raw string)
    (debug-uart-write-char #\Newline)))

;; Numeric companion for fault-path tracing.  Keep this allocation-free so it
;; is safe from an exception handler before the pager can service the fault.
(defun debug-uart-boot-hex-line (label value)
  (when (and (boundp '*debug-uart-base*) *debug-uart-base*)
    (debug-uart-write-string-boot-raw label)
    (debug-uart-write-char #\Space)
    (dotimes (i 16)
      (let ((digit (logand (ash value (- (* (- 15 i) 4))) #xF)))
        (debug-uart-write-byte
         (if (< digit 10)
             (+ #x30 digit)
             (+ #x41 (- digit 10))))))
    (debug-uart-write-char #\Newline)))

(defun debug-uart-flush-buffer (buf)
  (safe-without-interrupts (buf)
    (with-symbol-spinlock (*debug-uart-lock*)
      (let ((buf-data (car buf)))
        ;; To get inline wired accessors....
        (declare (type (simple-array (unsigned-byte 8) (*)) buf-data)
                 (optimize speed (safety 0)))
        (dotimes (i (cdr buf))
          (let ((byte (aref buf-data (the fixnum i))))
            (cond ((eql byte #.(char-code #\Newline))
                   (setf *uart-at-line-start* t)
                   ;; Turn #\Newline into CRLF
                   (debug-uart-write-byte #x0D)
                   (debug-uart-write-byte #x0A))
                  (t
                   (setf *uart-at-line-start* nil)
                   (debug-uart-write-byte byte)))))))))

(defun debug-uart-stream (op &optional arg)
  (ecase op
    (:read-char (panic "UART read char not implemented."))
    (:clear-input)
    (:write-char (debug-uart-write-char arg))
    (:write-string (debug-uart-write-string arg))
    (:force-output)
    (:start-line-p *uart-at-line-start*)
    (:flush-buffer (debug-uart-flush-buffer arg))))

(defun initialize-debug-uart (base)
  (setf *debug-uart-base* base
        *debug-uart-lock* :unlocked
        *uart-at-line-start* t)
  (debug-set-output-pseudostream #'debug-uart-stream))
