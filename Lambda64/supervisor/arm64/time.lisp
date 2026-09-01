(in-package :mezzano.supervisor)

(sys.int::defglobal *generic-timer-rate*)
(sys.int::defglobal *generic-timer-reset-value*)
(sys.int::defglobal *run-time-advance*)

(sys.int::defglobal *rtc-adjust*)

;; The generated SETF accessors for system registers are represented by a
;; function-reference cell.  That cell is not guaranteed to be published
;; while the cold image is still bootstrapping, so timer setup must use direct
;; LAP entry points instead of (SETF (%CNTV-...)).
(sys.int::define-lap-function %write-cntv-tval-el0 ((value))
  (:gc :no-frame :layout #*)
  (mezzano.lap.arm64:add :x9 :xzr :x0 :asr #.sys.int::+n-fixnum-bits+)
  (mezzano.lap.arm64:msr :cntv-tval-el0 :x9)
  (mezzano.lap.arm64:ret))

(sys.int::define-lap-function %write-cntv-ctl-el0 ((value))
  (:gc :no-frame :layout #*)
  (mezzano.lap.arm64:add :x9 :xzr :x0 :asr #.sys.int::+n-fixnum-bits+)
  (mezzano.lap.arm64:msr :cntv-ctl-el0 :x9)
  (mezzano.lap.arm64:ret))

(defun generic-timer-irq-handler (interrupt-frame irq)
  (declare (ignore irq))
  (%write-cntv-tval-el0 *generic-timer-reset-value*)
  (%isb)
  (beat-heartbeat *run-time-advance*)
  (profile-sample interrupt-frame)
  :completed)

(defun initialize-platform-time (fdt-node)
  (let* ((fdt-interrupt (fdt-get-property fdt-node "interrupts"))
         ;; The ARM architected timer's virtual-timer interrupt is a PPI;
         ;; translate its FDT interrupt ID into the GIC global IRQ namespace.
         ;; (SPI routing is handled by device-specific FDT consumers.)
         (irq (+ 16 (fdt-read-u32 fdt-interrupt 7)))
         (timer-rate (%cntfrq-el0))
         (tick-rate 100))
    (debug-print-line "Timer irq: " irq)
    (debug-print-line "Timer frequency: " timer-rate " Hz")
    (setf *generic-timer-rate* timer-rate)
    (setf *generic-timer-reset-value* (truncate timer-rate tick-rate))
    (setf *run-time-advance* (truncate internal-time-units-per-second tick-rate))
    (debug-print-line "Timer reset: " *generic-timer-reset-value*)
    (debug-print-line "Timer advance: " *run-time-advance*)
    (when (not (boundp '*rtc-adjust*))
      (setf *rtc-adjust* 0))
    (irq-attach (platform-irq irq)
                #'generic-timer-irq-handler
                fdt-node
                t)
    ;; Set countdown value.
    ;; ### why is this 0 and not *generic-timer-reset-value*?
    (%write-cntv-tval-el0 0)
    (%isb)
    ;; Enable the timer.
    (%write-cntv-ctl-el0 1)
    (%isb)))

(sys.int::defglobal *pl031-rtc-base*)

(defconstant +pl031-rtcdr+ #x00) ; Data register (RO)
(defconstant +pl031-rtcmr+ #x04) ; Match register (RW)
(defconstant +pl031-rtclr+ #x08) ; Load register (RW)
(defconstant +pl031-rtccr+ #x0C) ; Control reigster (RW)
(defconstant +pl031-rtcimsc+ #x10) ; Interrupt Mask Set or Clear register (RW)
(defconstant +pl031-rtcris+ #x14) ; Raw Interrupt Status (RO)
(defconstant +pl031-rtcmis+ #x18) ; Masked Interrupt Status (RO)
(defconstant +pl031-rtcicr+ #x1C) ; Interrupt Clear Register (WO)

(defconstant +pl031-conversion-value+ 2208988800)

(defun pl031-reg (index)
  (physical-memref-unsigned-byte-32 (+ *pl031-rtc-base* index)))

(defun initialize-arm-rtc (fdt-node address-cells size-cells)
  (let* ((reg (fdt-get-property fdt-node "reg"))
         (address (fdt-read-integer reg address-cells 0)))
    (setf *pl031-rtc-base* address)
    (setf *rtc-adjust* (+ +pl031-conversion-value+ (pl031-reg +pl031-rtcdr+)))))

(defun get-universal-time ()
  (+ *rtc-adjust* (truncate (%cntvct-el0) *generic-timer-rate*)))

(defun sys.int::tsc ()
  ;; This isn't the cycle counter, but it's close enough for now.
  (prog1
      (%cntvct-el0)
    (%isb)))

(defun get-high-precision-timer ()
  "Returns the current value of the platform's 'high precision' timer.
This timer will generally run at a faster rate the the standard internal-run-time
timer. However, this timer is non-monotonic. It may wrap at any time and can
warp backwards and forwards over a snapshot.
Returns the current value in high-precision time units.
They can be converted to internal time units using
HIGH-PRECISION-TIME-UNITS-TO-INTERNAL-TIME-UNITS."
  ;; CNTVCT_EL0 is the architectural counter used for high-precision timing;
  ;; ISB ensures the read is observed in program order.
  (prog1
      (%cntvct-el0)
    (%isb)))

(defun high-precision-time-units-to-internal-time-units (hp-time)
  (if (boundp '*generic-timer-rate*)
      ;; Do this to avoid producing intermediate bignum or ratio results.
      ;; This loses a bit of precision...
      (truncate hp-time (truncate *generic-timer-rate* internal-time-units-per-second))
      0))
