(in-package :mezzano.supervisor)

(sys.int::define-lap-function ensure-on-wired-stack ()
  (:gc :no-frame :layout #*)
  (mezzano.lap.arm64:stp :x29 :x30 (:pre :sp -16))
  (:gc :no-frame :layout #*00)
  (mezzano.lap.arm64:add :x29 :sp :xzr)
  (:gc :frame)
  (mezzano.lap.arm64:add :x9 :sp 0)
  (mezzano.lap.arm64:orr :x5 :xzr #x200000000000)
  (mezzano.lap.arm64:sub :x9 :x9 :x5)
  (mezzano.lap.arm64:orr :x5 :xzr #x8000000000)
  (mezzano.lap.arm64:subs :xzr :x9 :x5)
  (mezzano.lap.arm64:b.hs BAD)
  (mezzano.lap.arm64:orr :x5 :xzr :xzr)
  (mezzano.lap.arm64:ldp :x29 :x30 (:post :sp 16))
  (:gc :no-frame :layout #*)
  (mezzano.lap.arm64:ret)
  BAD
  (mezzano.lap.arm64:ldr :x0 (:constant "Not on wired stack."))
  (mezzano.lap.arm64:movz :x5 #.(ash 1 sys.int::+n-fixnum-bits+))
  (mezzano.lap.arm64:named-call panic)
  (mezzano.lap.arm64:brk 42))

(sys.int::define-lap-function sys.int::%interrupt-state (())
  (:gc :no-frame :layout #*)
  (mezzano.lap.arm64:mrs :x9 :daif)
  (mezzano.lap.arm64:ldr :x0 (:constant t))
  (mezzano.lap.arm64:ands :xzr :x9 :x9)
  (mezzano.lap.arm64:csel.ne :x0 :x26 :x0)
  (mezzano.lap.arm64:movz :x5 #.(ash 1 sys.int::+n-fixnum-bits+))
  (mezzano.lap.arm64:ret))

(sys.int::define-lap-function %disable-interrupts (())
  (:gc :no-frame :layout #*)
  (mezzano.lap.arm64:msr :daifset #b1111)
  (mezzano.lap.arm64:ret))

(sys.int::define-lap-function %enable-interrupts (())
  (:gc :no-frame :layout #*)
  (mezzano.lap.arm64:msr :daifclr #b1111)
  (mezzano.lap.arm64:ret))

(sys.int::define-lap-function %wait-for-interrupt (())
  (:gc :no-frame :layout #*)
  (mezzano.lap.arm64:wfi)
  (mezzano.lap.arm64:msr :daifclr #b1111)
  (mezzano.lap.arm64:ret))

;; Keep CPU-RELAX as YIELD rather than WFE: callers do not publish a matching
;; SEV event on every state transition, so WFE could sleep indefinitely.
(sys.int::define-lap-function sys.int::cpu-relax (())
  (:gc :no-frame :layout #*)
  (mezzano.lap.arm64:yield)
  (mezzano.lap.arm64:ret))

(sys.int::define-lap-function %arch-panic-stop (())
  (:gc :no-frame :layout #*)
  (mezzano.lap.arm64:wfi)
  (mezzano.lap.arm64:ret))

(defun sys.int::%save-irq-state ()
  (sys.int::%interrupt-state))

(defun sys.int::%restore-irq-state (state)
  (when state
    (%enable-interrupts)))

(sys.int::define-lap-function %call-on-wired-stack-without-interrupts ((function unused &optional arg1 arg2 arg3))
  (:gc :no-frame :layout #*)
  ;; Argument setup for the frame pointer.
  (mezzano.lap.arm64:orr :x1 :xzr :x29) ; fp
  ;; Build a frame and save the old stack pointer.
  (mezzano.lap.arm64:stp :x29 :x30 (:pre :sp -16))
  (:gc :no-frame :layout #*00)
  (mezzano.lap.arm64:add :x29 :sp :xzr)
  (:gc :frame)
  ;; Save the callee-save registers too.
  (mezzano.lap.arm64:stp :x13 :x14 (:pre :sp -16))
  (:gc :frame :layout #*11)
  ;; Argument setup.
  (mezzano.lap.arm64:orr :x6 :xzr :x0) ; function
  (mezzano.lap.arm64:add :x0 :sp 0) ; sp
  ;; Test if interrupts are enabled.
  (mezzano.lap.arm64:mrs :x9 :daif)
  (mezzano.lap.arm64:cbnz :x9 INTERRUPTS-DISABLED)
  ;; Disable interrupts after setting up the frame, not before.
  ;; Modifying the normal stack may cause page-faults which can't
  ;; occur with interrupts disabled.
  (mezzano.lap.arm64:msr :daifset #b1111)
  ;; Switch over to the wired stack.
  (mezzano.lap.arm64:msr :spsel 1)
  ;; Call function, arguments were setup above.
  (mezzano.lap.arm64:ldr :x9 (:object :x6 0))
  (mezzano.lap.arm64:blr :x9)
  (:gc :frame :layout #*11 :multiple-values 0)
  ;; Switch back to the old stack.
  ;; Do not restore frame & stack pointer here, that would touch the old stack with
  ;; interrupts disabled.
  (mezzano.lap.arm64:msr :spsel 0)
  ;; Reenable interrupts, must not be done when on the wired stack.
  (mezzano.lap.arm64:msr :daifclr #b1111)
  ;; Pop callee-save registers.
  (mezzano.lap.arm64:ldp :x13 :x14 (:post :sp 16))
  (:gc :frame :layout #* :multiple-values 0)
  ;; Now safe to restore the frame pointer.
  (mezzano.lap.arm64:ldp :x29 :x30 (:post :sp 16))
  (:gc :no-frame :layout #* :multiple-values 0)
  ;; Done, return.
  (mezzano.lap.arm64:ret)
  INTERRUPTS-DISABLED
  (:gc :frame :layout #*11)
  ;; Call function, arguments were setup above.
  (mezzano.lap.arm64:ldr :x9 (:object :x6 0))
  (mezzano.lap.arm64:blr :x9)
  ;; Restore frame and return.
  (mezzano.lap.arm64:ldp :x13 :x14 (:post :sp 16))
  (:gc :frame :layout #*)
  (mezzano.lap.arm64:ldp :x29 :x30 (:post :sp 16))
  (:gc :no-frame :layout #* :multiple-values 0)
  (mezzano.lap.arm64:ret))

;;; The ARM64 entry stub reuses the generic x86-64 interrupt-frame slots, so
;;; every ARM64 register is reached through an x86 register name.  The mapping
;;; is fixed by the push order in %EL0-COMMON, which stores pairs downwards
;;; from the frame pointer:
;;;
;;;   stp x5,x9 / x6,x10 / x12,x11 / x1,x0 / x3,x2 / x7,x4 / x14,x13
;;;
;;; and INTERRUPT-FRAME-REGISTER-OFFSET numbers those words -1, -2, ... from
;;; the frame pointer.  That yields:
;;;
;;;   x0=:r8   x1=:r9   x2=:r10  x3=:r11  x4=:r12  x5=:rcx  x6=:rbx
;;;   x7=:r13  x9=:rax  x10=:rdx x11=:rsi x12=:rdi x13=:r14 x14=:r15
;;;
;;; Keep these accessors derived from the stub, never guessed: a mislabeled
;;; register turns every panic report into misleading evidence.
(macrolet ((define-arm64-frame-registers (&rest pairs)
             `(progn
                ,@(loop for (name slot) in pairs
                        collect `(defun ,name (interrupt-frame)
                                   (interrupt-frame-raw-register
                                    interrupt-frame ,slot))))))
  (define-arm64-frame-registers
    (interrupt-frame-x0 :r8)
    (interrupt-frame-x1 :r9)
    (interrupt-frame-x2 :r10)
    (interrupt-frame-x3 :r11)
    (interrupt-frame-x4 :r12)
    (interrupt-frame-x5 :rcx)
    (interrupt-frame-x6 :rbx)
    (interrupt-frame-x7 :r13)
    (interrupt-frame-x9 :rax)
    (interrupt-frame-x10 :rdx)
    (interrupt-frame-x11 :rsi)
    (interrupt-frame-x12 :rdi)
    (interrupt-frame-x13 :r14)
    (interrupt-frame-x14 :r15)))

(defun unhandled-interrupt (interrupt-frame name)
  ;; Report the essentials on the raw UART before calling PANIC.  PANIC builds
  ;; a long argument list, stops the world and then walks every thread's stack;
  ;; if any of that faults in this context the whole report is lost and the
  ;; machine simply halts in WFI with nothing on the serial line.  These writes
  ;; allocate nothing and touch only the already-mapped UART, so they survive
  ;; contexts where the normal debug path cannot run.
  (debug-uart-boot-line "UNHANDLED-INTERRUPT")
  (debug-uart-boot-hex-line "  esr " (%esr-el1))
  (debug-uart-boot-hex-line "  far " (%far-el1))
  (debug-uart-boot-hex-line "  pc  " (interrupt-frame-raw-register interrupt-frame :rip))
  (debug-uart-boot-hex-line "  x30 " (interrupt-frame-raw-register interrupt-frame :cs))
  (debug-uart-boot-hex-line "  sp  " (interrupt-frame-raw-register interrupt-frame :rsp))
  (debug-uart-boot-hex-line "  spsr" (interrupt-frame-raw-register interrupt-frame :rflags))
  ;; Do not dereference the faulting PC here, even when it carries the Lisp
  ;; object tag.  This handler runs with IRQs masked, so a read of an unmapped
  ;; address raises page-fault-no-irqs and replaces the original panic with a
  ;; nested one, destroying the evidence.  Report registers only.
  (panic "Unhandled " name " interrupt."
         " SPSR: " (interrupt-frame-raw-register interrupt-frame :rflags)
         " PC: " (interrupt-frame-raw-register interrupt-frame :rip)
         " x30: " (interrupt-frame-raw-register interrupt-frame :cs)
         " SP: " (interrupt-frame-raw-register interrupt-frame :rsp)
         " x0: " (interrupt-frame-x0 interrupt-frame)
         " x1: " (interrupt-frame-x1 interrupt-frame)
         " x2: " (interrupt-frame-x2 interrupt-frame)
         " x3: " (interrupt-frame-x3 interrupt-frame)
         " x4: " (interrupt-frame-x4 interrupt-frame)
         " x5: " (interrupt-frame-x5 interrupt-frame)
         " x6: " (interrupt-frame-x6 interrupt-frame)
         " x7: " (interrupt-frame-x7 interrupt-frame)
         " x9: " (interrupt-frame-x9 interrupt-frame)
         " x10: " (interrupt-frame-x10 interrupt-frame)
         " x11: " (interrupt-frame-x11 interrupt-frame)
         " x12: " (interrupt-frame-x12 interrupt-frame)
         " x13: " (interrupt-frame-x13 interrupt-frame)
         " x14: " (interrupt-frame-x14 interrupt-frame)
         " ESR: " (%esr-el1)
         " FAR: " (%far-el1)))

(defun local-cpu-page-fault-hook ()
  (arm64-cpu-page-fault-hook (local-cpu-info)))

(defun (setf local-cpu-page-fault-hook) (value)
  (setf (arm64-cpu-page-fault-hook (local-cpu-info)) value))

;; Fault tracing is invaluable while bringing the port up, but once the Lisp
;; warm boot starts every allocation can fault and the trace buries the panic
;; report it exists to support.  Bound it the same way the timer and GIC traces
;; are bounded: keep the early boot detail, then go quiet.
(sys.int::defglobal *fault-trace-budget*)
(defconstant +fault-trace-budget+ 4000)

(defun fault-trace-allowed-p ()
  (when (not (boundp '*fault-trace-budget*))
    (setf *fault-trace-budget* +fault-trace-budget+))
  (and (> *fault-trace-budget* 0)
       (progn (decf *fault-trace-budget*) t)))

(defun %page-fault-handler (interrupt-frame fault-addr reason)
  (when (fault-trace-allowed-p)
    (debug-uart-boot-line "TRACE page-fault-handler"))
  (let ((hook (local-cpu-page-fault-hook)))
    (when hook
      ;; Hooks run on the exception's SP_EL1 stack. A hook that was bound in
      ;; SP_EL0 must not be invoked until an exception-return trampoline can
      ;; switch stacks and restore the original SP_EL1; this handler currently
      ;; provides no such trampoline, so callers must bind supervisor-safe hooks.
      (funcall hook interrupt-frame reason fault-addr nil)))
  (cond ((not *paging-disk*)
         (unhandled-interrupt interrupt-frame "early-page-fault"))
        ((logtest #x3C0 (interrupt-frame-raw-register interrupt-frame :rflags))
         ;; IRQs must be enabled when a page fault occurs.
         (unhandled-interrupt interrupt-frame "page-fault-no-irqs"))
        ((and (eql (thread-priority (current-thread)) :supervisor)
              (address-in-non-faulting-range-p fault-addr))
         (unhandled-interrupt interrupt-frame "wired-page-fault"))
        (t ;; Defer to the pager.
         ;; Might not return.
         (wait-for-page-via-interrupt interrupt-frame
                                      fault-addr
                                      (eql reason :write-to-ro)
                                      nil))))

(defun %instruction-abort-handler (interrupt-frame fault-addr esr)
  ;; Keep the raw fault address/status visible while bringing up the ARM64
  ;; cold image.  A translation fault should be recoverable through the pager;
  ;; an address-size/permission fault indicates an address-layout or PTE
  ;; contract violation and must not be mistaken for a missing page.
  (when (fault-trace-allowed-p)
    (debug-uart-boot-line "TRACE instruction-abort-handler")
    (debug-uart-boot-hex-line "TRACE instruction-abort-far" fault-addr)
    (debug-uart-boot-hex-line "TRACE instruction-abort-esr" esr))
  (let ((status (ldb (byte 5 0) esr)))
    (case status
      ((#x04 #x05 #x06 #x07) ;; Translation fault (page not mapped).
       (%page-fault-handler interrupt-frame fault-addr :not-present))
      (t
       (unhandled-interrupt interrupt-frame "instruction-abort")))))

(defun %data-abort-handler (interrupt-frame fault-addr esr)
  (when (fault-trace-allowed-p)
    (debug-uart-boot-line "TRACE data-abort-handler")
    (debug-uart-boot-hex-line "TRACE data-abort-pc"
                              (interrupt-frame-raw-register interrupt-frame :rip))
    (debug-uart-boot-hex-line "TRACE data-abort-far" fault-addr)
    (debug-uart-boot-hex-line "TRACE data-abort-esr" esr))
  (when (eql fault-addr #x400000000020)
    ;; Keep this diagnostic pointer-only.  The fault is often caused by the
    ;; pager touching a not-yet-mapped thread object, so reading thread slots
    ;; here would recurse before we can identify the active allocator path.
    (let ((thread (current-thread))
          (pager (sys.int::symbol-global-value 'sys.int::*pager-thread*)))
      (debug-uart-boot-hex-line "TRACE fault-thread"
                                (sys.int::lisp-object-address thread))
      (debug-uart-boot-hex-line "TRACE fault-pager"
                                (sys.int::lisp-object-address pager))))
  (let ((status (ldb (byte 5 0) esr)))
    (case status
      ((#x04 #x05 #x06 #x07) ;; Translation fault (page not mapped).
       (%page-fault-handler interrupt-frame fault-addr :not-present))
      ((#x0C #x0D #x0E #x0F) ;; Permission fault.
       (let* ((pte (get-pte-for-address fault-addr nil))
              (current (and pte (page-table-entry pte))))
         (cond ((and (logtest esr #x40)
                     pte
                     (logtest current +arm64-tte-writable+)
                     (eql (ldb +arm64-tte-ap+ current)
                          +arm64-tte-ap-pro-una+))
                ;; Dirty bit emulation.
                ;; Set the dirty bit and make the page writable again.
                #+(or)
                (debug-print-line "Dirty emulation for address " fault-addr)
                (let ((new (dpb +arm64-tte-ap-prw-una+
                                +arm64-tte-ap+
                                (logior current +arm64-tte-dirty+))))
                  ;; We don't bother trying to retry the result of this.
                  ;; No matter if it passes or fails we return from the
                  ;; fault and retry the access. We'll either succeed,
                  ;; end up back here, or trigger another fault.
                  (ext:cas (page-table-entry pte) current new))
                (flush-tlb-single fault-addr))
               ((logtest esr #x40)
                (%page-fault-handler interrupt-frame fault-addr :write-to-ro))
               (t
                (unhandled-interrupt interrupt-frame "data-abort")))))
      (t
       (unhandled-interrupt interrupt-frame "data-abort")))))

(defun %synchronous-el0-handler (interrupt-frame)
  (let* ((esr (%esr-el1))
         (class (ldb (byte 6 26) esr)))
    (case class
      (#x21
       (%instruction-abort-handler interrupt-frame (%far-el1) esr))
      (#x25
       (%data-abort-handler interrupt-frame (%far-el1) esr))
      (#x3C ; BRK instruction
       (let ((comment (ldb (byte 16 0) esr)))
         (case comment
           (28 ; %%partial-save-return-thunk
            (partial-save-return-helper interrupt-frame))
           (42 ; %%unreachable
            (pager-invoke-via-interrupt
             #'mezzano.runtime::%raise-unreachable interrupt-frame nil))
           (43
            (unhandled-interrupt interrupt-frame "invalid-apply-call-target"))
           (44
            (unhandled-interrupt interrupt-frame "invalid-apply-tail-target"))
           (45
            (unhandled-interrupt interrupt-frame "invalid-named-call-target"))
           (46
            (unhandled-interrupt interrupt-frame "invalid-named-tail-target"))
           (t
            (unhandled-interrupt interrupt-frame "brk")))))
      (#x33 ; Software Step exception taken without a change in Exception level
       (stop-thread-for-single-step interrupt-frame))
      (t
       (unhandled-interrupt interrupt-frame "synchronous-el0")))))

(defun %irq-el0-handler (interrupt-frame)
  ;; GIC handling may switch threads through a no-return path, but it also
  ;; legitimately returns when the current supervisor thread keeps running.
  ;; Keep an explicit continuation here so the ARM64 compiler does not treat
  ;; this wrapper as an unconditional tail/no-return call and emit the
  ;; invalid-named-call-target trap at the normal IRQ return site.
  (gic-handle-interrupt interrupt-frame)
  nil)

(defun %fiq-el0-handler (interrupt-frame)
  (unhandled-interrupt interrupt-frame "fiq-el0"))

(defun %serror-el0-handler (interrupt-frame)
  (unhandled-interrupt interrupt-frame "serror-el0"))

(defun %synchronous-elx-handler (interrupt-frame)
  (let* ((esr (%esr-el1))
         (class (ldb (byte 6 26) esr)))
    (case class
      (#x21
       (%instruction-abort-handler interrupt-frame (%far-el1) esr))
      (#x25
       (%data-abort-handler interrupt-frame (%far-el1) esr))
      (t
       (unhandled-interrupt interrupt-frame "synchronous-elx")))))

(defun %irq-elx-handler (interrupt-frame)
  (unhandled-interrupt interrupt-frame "irq-elx"))

(defun %fiq-elx-handler (interrupt-frame)
  (unhandled-interrupt interrupt-frame "fiq-elx"))

(defun %serror-elx-handler (interrupt-frame)
  (unhandled-interrupt interrupt-frame "serror-elx"))
