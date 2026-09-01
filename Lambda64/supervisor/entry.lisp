;;;; Main entry point for the supervisor from the bootloader

(in-package :mezzano.supervisor)

;;; The reboot shim remains in this entry module because the bootloader calls
;;; it before supervisor subsystems are fully initialized. Moving it requires
;;; a stable platform lifecycle hook; keep this narrow compatibility boundary
;;; until that hook exists.

(defun reboot ()
  ;; Flush each currently valid disk before handing control to the platform.
  ;; A failed flush is reported but cannot be recovered synchronously here;
  ;; continue to the platform reboot path after making a best effort.
  (dolist (disk (all-disks))
    (when (disk-valid disk)
      (multiple-value-bind (successp reason) (disk-flush disk)
        (unless successp
          (debug-print-line "Disk flush failed during reboot: " reason)))))
  ;; Do not tear down memory while a snapshot writer still owns its state.
  (when (and (boundp '*snapshot-in-progress*) *snapshot-in-progress*)
    (wait-for-snapshot-completion))
  (platform-reboot)
  (values))

;;; <<<<<<

;; Cold-generator will set this to T if we build in CI.
(sys.int::defglobal sys.int::*running-in-ci*)

(defun running-in-ci-p ()
  (boundp 'sys.int::*running-in-ci*))

(sys.int::defglobal *boot-information-page*)

(defconstant +virtual-address-bits+ 48)
(defconstant +log2-4k-page+ 12)
(defconstant +n-32-bit-physical-buddy-bins+ (- 32 +log2-4k-page+)
  "Number of buddy bins for the below 4GB allocator.")
(defconstant +n-64-bit-physical-buddy-bins+ (- 39 +log2-4k-page+)
  "Number of buddy bins for the above 4GB allocator.")

(defconstant +buddy-bin-size+ 16
  "Size in bytes of one buddy bin.")

(defconstant +boot-information-boot-uuid-offset+                  0)
(defconstant +boot-information-32-bit-physical-buddy-bins-offset+ 16)
(defconstant +boot-information-64-bit-physical-buddy-bins-offset+ 336)
(defconstant +boot-information-video+                             768)
(defconstant +boot-information-framebuffer-physical-address+      (+ +boot-information-video+ 0))
(defconstant +boot-information-framebuffer-width+                 (+ +boot-information-video+ 8))
(defconstant +boot-information-framebuffer-pitch+                 (+ +boot-information-video+ 16))
(defconstant +boot-information-framebuffer-height+                (+ +boot-information-video+ 24))
(defconstant +boot-information-framebuffer-layout+                (+ +boot-information-video+ 32))
(defconstant +boot-information-acpi-rsdp+                         808)
(defconstant +boot-information-options+                           816)
(defconstant +boot-information-n-memory-map-entries+              824)
(defconstant +boot-information-memory-map+                        832)
(defconstant +boot-information-efi-system-table+                 1344)
(defconstant +boot-information-fdt-address+                      1352)
(defconstant +boot-information-block-map+                        1360)

(defconstant +boot-option-force-read-only+ #x01)
(defconstant +boot-option-freestanding+ #x02)
(defconstant +boot-option-video-console+ #x04)
(defconstant +boot-option-no-detect+ #x08)
(defconstant +boot-option-no-smp+ #x10)

(defun boot-uuid (offset)
  (check-type offset (integer 0 15))
  (sys.int::memref-unsigned-byte-8 (+ +boot-information-boot-uuid-offset+ *boot-information-page*)
                                   offset))

(defun boot-field (field)
  (sys.int::memref-t (+ *boot-information-page* field)))

(defun boot-option (option)
  (logtest (boot-field +boot-information-options+) option))

(sys.int::defglobal *boot-hook-lock*)
(sys.int::defglobal *early-boot-hooks*)
(sys.int::defglobal *boot-hooks*)
(sys.int::defglobal *late-boot-hooks*)

(defun add-boot-hook (fn &optional when)
  (check-type when (member nil :late :early))
  (with-mutex (*boot-hook-lock*)
    (case when
      (:early
       (push fn *early-boot-hooks*))
      ((nil)
       (push fn *boot-hooks*))
      (:late
       (push fn *late-boot-hooks*)))))

(defun remove-boot-hook (fn)
  (with-mutex (*boot-hook-lock*)
    (setf *early-boot-hooks* (remove fn *early-boot-hooks*))
    (setf *boot-hooks* (remove fn *boot-hooks*))
    (setf *late-boot-hooks* (remove fn *late-boot-hooks*))))

(defun run-boot-hooks ()
  (dolist (hook *early-boot-hooks*)
    (sys.int::log-and-ignore-errors
      (format t "Run early boot hook ~A~%" hook)
      (funcall hook)))
  (dolist (hook *boot-hooks*)
    (sys.int::log-and-ignore-errors
      (format t "Run boot hook ~A~%" hook)
      (funcall hook)))
  (dolist (hook *late-boot-hooks*)
    (sys.int::log-and-ignore-errors
      (format t "Run late boot hook ~A~%" hook)
      (funcall hook))))

(sys.int::defglobal *boot-id*)

;; ARM64 cold images provide a wired event for the first boot.  Creating the
;; event dynamically would require the pager before it has been initialized.
(sys.int::defglobal *initial-boot-event*)

(defun current-boot-id ()
  *boot-id*)

(sys.int::defglobal *deferred-boot-actions*)

(defun add-deferred-boot-action (action)
  (if (boundp '*deferred-boot-actions*)
      (push-wired action *deferred-boot-actions*)
      (funcall action)))

(sys.int::defglobal *post-boot-worker-thread*)

(defun post-boot-worker ()
  (loop
     ;; Run deferred boot actions first.
     (dolist (action *deferred-boot-actions*)
       (funcall action))
     (makunbound '*deferred-boot-actions*)
     ;; Now normal boot hooks.
     (run-boot-hooks)
     ;; Sleep til next boot.
     (%run-on-wired-stack-without-interrupts (sp fp)
      (let ((self (current-thread)))
        ;; *SNAPSHOT-INHIBIT* is set to 1 during boot, decrement it
        ;; and enable snapshotting now that all boot work has been done.
        (sys.int::%atomic-fixnum-add-symbol '*snapshot-inhibit* -1)
        (acquire-global-thread-lock)
        (setf (thread-wait-item self) "Next boot"
              (thread-state self) :sleeping)
        (%reschedule-via-wired-stack sp fp)))))

(defun sys.int::bootloader-entry-point (boot-information-page)
  (let ((first-run-p nil))
    (initialize-boot-cpu)
    (initialize-debug-log)
    (initialize-fdt boot-information-page)
    (initialize-platform-early-console boot-information-page)
    (initialize-initial-thread)
    (setf *boot-information-page* boot-information-page
          *cold-unread-char* nil
          mezzano.runtime::*paranoid-allocation* nil
          *deferred-boot-actions* '()
          *paging-disk* nil)
    (initialize-physical-allocator)
    (initialize-early-video)
    ;; A serialized cold image may leave BOOT-ID bound to a non-event object.
    ;; Treat that state as an uninitialized first boot; relying on BOUNDP alone
    ;; incorrectly selected the warm-boot path and reused stale thread queues.
    (when (or (not (boundp '*boot-id*))
              (not (event-p *boot-id*)))
      (setf first-run-p t)
      (mezzano.runtime::first-run-initialize-allocator)
      ;; These globals are intentionally reset at first supervisor boot. The
      ;; current cold generator does not emit their initialized values, and
      ;; moving this reset would require extending the generated-image ABI.
      (setf (sys.int::symbol-global-value 'mezzano.runtime::*active-catch-handlers*) 'nil
            (sys.int::symbol-global-value '*pseudo-atomic*) nil
            ;; Cold-image global cells are not guaranteed to retain their
            ;; DEFGLOBAL initializer across image serialization.  A stale
            ;; thread object here makes CALL-WITH-PSEUDO-ATOMIC believe the
            ;; world is already stopped during first boot.
            (sys.int::symbol-global-value '*world-stopper*) nil
            sys.int::*known-finalizers* nil
            ;; Paging setup uses WITH-SNAPSHOT-INHIBITED before
            ;; INITIALIZE-SNAPSHOT runs.  Seed the counter with the boot-time
            ;; inhibition held so its atomic fixnum updates see a valid value.
            (sys.int::symbol-global-value '*snapshot-inhibit*) 1
            ;; STORE-STATISTICS can be reached while the paging disk is being
            ;; discovered, before INITIALIZE-STORE-FREELIST publishes its
            ;; counters.  Seed them so an early read cannot signal an
            ;; unbound-variable error; the real values replace these shortly.
            ;; Keep early allocation-area growth from falling through to GC
            ;; before the normal store freelist has been discovered.  The
            ;; real counters replace this temporary upper bound below.
            (sys.int::symbol-global-value '*store-freelist-n-free-blocks*) #x1000000
            (sys.int::symbol-global-value '*store-freelist-n-deferred-free-blocks*) 0
            (sys.int::symbol-global-value '*store-freelist-total-blocks*) #x1000000
            ;; Freelist metadata allocation consults this before the hosted
            ;; paging initializer computes its image-size based value.
            (sys.int::symbol-global-value '*store-fudge-factor*) 0
            ;; DEFVAR initializers are not materialized in a cold image.  The
            ;; first allocation-area expansion reads these limits before the
            ;; normal runtime initialization path has run.
            (sys.int::symbol-global-value 'mezzano.runtime::*maximum-allocation-attempts*) 5
            (sys.int::symbol-global-value 'mezzano.runtime::*maximum-young-generation-size*) #x20000000
            *big-wait-for-objects-lock* (place-spinlock-initializer)))
    (initialize-early-platform)
    (when (boundp '*boot-id*)
      (setf (event-state *boot-id*) t))
    (setf *boot-id* (if (and first-run-p (boundp '*initial-boot-event*))
                        *initial-boot-event*
                        (make-event :name 'boot-epoch)))
    ;; The first boot has no pager yet; defer the two contention-only wait
    ;; queues until after paging is initialized.
    (initialize-threads first-run-p)
    ;; Disk queue and request events allocate general-area vectors.  Defer
    ;; those objects on the first boot until initialize-pager has established
    ;; the paging path.
    ;; The allocator can now grow during bootstrap, so publish the queue
    ;; latch before any disk worker can enter POP-DISK-REQUEST.
    (initialize-disk first-run-p)
    (initialize-pager first-run-p first-run-p first-run-p first-run-p)
    ;; Publish synchronization objects before interrupts are enabled.  Normal
    ;; allocations then have valid pseudo-atomic queues and VM/allocator locks.
    (when (null *disk-request-queue-latch*)
      (setf *disk-request-queue-latch*
            (make-event :name "Disk request queue notifier")))
    (when (and (boundp '*pager-disk-request*)
               (null *pager-disk-request*))
      (setf *pager-disk-request* (make-disk-request)))
    (when first-run-p
      (wake-thread sys.int::*disk-io-thread*))
    (when (and first-run-p
               (not (boundp 'mezzano.runtime::*allocator-lock*)))
      (setf mezzano.runtime::*allocator-lock*
            (make-mutex "Allocator")))
    (when (or (not (boundp '*vm-lock*))
              (null *vm-lock*))
      (setf *vm-lock* (make-rw-lock '*vm-lock*)))
    (when (or (null *pending-world-stoppers*)
              (null *pending-pseudo-atomics*))
      (setf *pending-world-stoppers* (or *pending-world-stoppers*
                                         (make-wait-queue :name '*pending-world-stoppers*))
            *pending-pseudo-atomics* (or *pending-pseudo-atomics*
                                         (make-wait-queue :name '*pending-pseudo-atomics*))))
    (%enable-interrupts)
    ;;(debug-set-output-pseudostream #'debug-video-stream)
    ;;(debug-set-output-pseudostream (lambda (op &optional arg) (declare (ignore op arg))))
    (debug-print-line "Hello, Debug World!")
    (initialize-time)
    (initialize-video)
    (when (boot-option +boot-option-video-console+)
      (debug-set-output-pseudostream #'debug-video-stream))
    (initialize-efi)
    (initialize-acpi)
    (initialize-virtio)
    (initialize-platform)
    (initialize-time-late)
    (when (not (boot-option +boot-option-no-detect+))
      (detect-disk-partitions))
    (initialize-paging-system)
    (initialize-snapshot)
    ;; INITIALIZE-SYNC creates mutex-backed watcher pools.  On a cold boot,
    ;; doing that before the paging backend exists can exhaust wired space,
    ;; enter GC, and deadlock in a pager RPC.  Warm boots retain the original
    ;; no-op behavior because FIRST-RUN-P is false there.
    (initialize-sync first-run-p)
    (when first-run-p
      (initialize-pager-dirty-bits))
    (when (not (boot-option +boot-option-no-smp+))
      (boot-secondary-cpus))
    (cond (first-run-p
           (setf *post-boot-worker-thread* (make-thread #'post-boot-worker :name "Post-boot worker thread")
                 *boot-hook-lock* (make-mutex "Boot Hook Lock")
                 *early-boot-hooks* '()
                 *boot-hooks* '()
                 *late-boot-hooks* '())
           (make-thread #'sys.int::initialize-lisp :name "Main thread"))
          (t (wake-thread *post-boot-worker-thread*)))
    (finish-initial-thread)))
