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
  (and (boundp 'sys.int::*running-in-ci*)
       sys.int::*running-in-ci*))

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
  (debug-uart-boot-line "TRACE post-worker-entry")
  (loop
     ;; Run deferred boot actions first.
     (dolist (action *deferred-boot-actions*)
       (funcall action))
     (debug-uart-boot-line "TRACE post-worker-deferred-done")
     (makunbound '*deferred-boot-actions*)
     ;; Now normal boot hooks.
     (run-boot-hooks)
     (debug-uart-boot-line "TRACE post-worker-hooks-done")
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
    ;; The bootloader does not guarantee that DAIF is masked on entry.  Keep
    ;; the initial thread on its bootstrap stack while the scheduler, pager,
    ;; and run queues are rebuilt; interrupts are enabled at the explicit
    ;; post-snapshot boundary below.
    (%disable-interrupts)
    (initialize-boot-cpu)
    (setf *cold-boot-in-progress* t)
    (setf *cold-paging-direct-stack-ops* t)
    (initialize-debug-log)
    (initialize-fdt boot-information-page)
    (initialize-platform-early-console boot-information-page)
    (debug-uart-boot-line "TRACE early-console")
    (debug-print-line "BOOT-MARK early-console")
    (initialize-initial-thread)
    (debug-uart-boot-line "TRACE initial-thread")
    (debug-print-line "BOOT-MARK initial-thread")
    (setf *boot-information-page* boot-information-page
          *cold-unread-char* nil
          mezzano.runtime::*paranoid-allocation* nil
          *deferred-boot-actions* '()
          *paging-disk* nil)
    (initialize-physical-allocator)
    (debug-uart-boot-line "TRACE physical")
    (debug-print-line "BOOT-MARK physical")
    (initialize-early-video)
    (debug-uart-boot-line "TRACE early-video")
    (debug-print-line "BOOT-MARK early-video")
    ;; A serialized cold image may leave BOOT-ID bound to a non-event object.
    ;; Treat that state as an uninitialized first boot; relying on BOUNDP alone
    ;; incorrectly selected the warm-boot path and reused stale thread queues.
    (when (or (not (boundp '*boot-id*))
              (not (event-p *boot-id*))
              ;; The cold generator supplies INITIAL-BOOT-EVENT so the first
              ;; boot can avoid dynamic allocation.  Treat that exact event
              ;; as the cold sentinel; otherwise a serialized event value is
              ;; mistaken for a warm reboot and allocator bootstrap is skipped.
              (and (boundp '*initial-boot-event*)
                   (eq *boot-id* *initial-boot-event*)))
      (setf first-run-p t)
      (debug-print-line "BOOT-MARK first-run")
      (mezzano.runtime::first-run-initialize-allocator)
      (debug-print-line "BOOT-MARK allocator")
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
            ;; DEFVAR initializers are not materialized in a cold image.
            ;; STORE-MAYBE-REFILL-METADATA reads this guard on the first
            ;; pager allocation; seed it before the freelist is populated.
            (sys.int::symbol-global-value '*store-freelist-recursive-metadata-allocation*) nil
            ;; DEFGLOBAL initializers are not materialized in a cold image.
            ;; Keep pager diagnostics disabled until the paging path is live;
            ;; PAGER-LOG-OP formats through the general allocator, so a stale
            ;; non-NIL value here would recursively issue PAGER-RPC from the
            ;; pager thread while handling its first request.
            (sys.int::symbol-global-value '*pager-noisy*) nil
            ;; DEFVAR initializers are not materialized in a cold image.  The
            ;; first allocation-area expansion reads these limits before the
            ;; normal runtime initialization path has run.
            (sys.int::symbol-global-value 'mezzano.runtime::*maximum-allocation-attempts*) 5
            (sys.int::symbol-global-value 'mezzano.runtime::*maximum-young-generation-size*) #x20000000
            *big-wait-for-objects-lock* (place-spinlock-initializer)))
    (debug-print-line "BOOT-MARK globals")
    (debug-print-line "first-run=" first-run-p " boot-id-event=" (and (boundp '*boot-id*) (event-p *boot-id*)))
    (initialize-early-platform)
    (debug-uart-boot-line "TRACE early-platform")
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
    (debug-uart-boot-line "TRACE disk")
    (initialize-pager first-run-p first-run-p first-run-p first-run-p)
    (debug-uart-boot-line "TRACE pager")
    ;; IRQs are enabled before paging discovery so the pager can make
    ;; progress.  Pseudo-atomic entry may then queue a world-stopper, so the
    ;; cold bootstrap must publish these wired wait queues before that first
    ;; interrupt; leaving them NIL makes the IRQ path dereference a bogus
    ;; queue and fault during the first general-area allocation.
    (when (or (null *pending-world-stoppers*)
              (null *pending-pseudo-atomics*))
      (setf *pending-world-stoppers* (or *pending-world-stoppers*
                                         (%make-wait-queue '*pending-world-stoppers*))
            *pending-pseudo-atomics* (or *pending-pseudo-atomics*
                                        (%make-wait-queue '*pending-pseudo-atomics*))))
    ;;(debug-set-output-pseudostream #'debug-video-stream)
    ;;(debug-set-output-pseudostream (lambda (op &optional arg) (declare (ignore op arg))))
    (initialize-efi)
    (initialize-virtio)
    (debug-uart-boot-line "TRACE virtio")
    (initialize-platform)
    (debug-uart-boot-line "TRACE platform")
    ;; The platform scan installs the architected timer and VirtIO/GIC
    ;; handlers.  Partition probing performs synchronous VirtIO reads, which
    ;; may sleep until their IRQ arrives; keeping DAIF.I masked here strands
    ;; the bootstrap thread after it switches to idle and no progress event
    ;; can be delivered.  Make this the explicit interrupt-enable boundary
    ;; before any device operation that may wait.
    (debug-uart-boot-line "TRACE interrupts-before-partitions")
    (%enable-interrupts)
    (when (not (boot-option +boot-option-no-detect+))
      (debug-uart-boot-line "TRACE partitions-start")
      (detect-disk-partitions))
    (debug-uart-boot-line "TRACE partitions-done")
    (debug-uart-boot-line "TRACE partitions")
    ;; Device probing may leave interrupts masked after its critical sections;
    ;; re-enable them at the exact point where paging discovery can block on
    ;; PAGER-RPC so the pager is guaranteed to be schedulable.
    (%enable-interrupts)
    ;; On first boot VM-LOCK is a wired bootstrap placeholder.  Store-freelist
    ;; construction uses the pager allocation core directly (the request
    ;; object is intentionally deferred), so the bootstrap thread must own
    ;; the placeholder write lock while it publishes the first metadata pages.
    ;; Do not schedule a pager RPC while holding this lock; the complete lock
    ;; with wait queues is installed immediately after this direct phase.
    (if first-run-p
        (progn
          ;; MAKE-RW-LOCK is too eager here because its wait queues allocate
          ;; through the not-yet-live pager.  Install the wired lock object
          ;; without queues and mark it held by this bootstrap thread.
          (setf *vm-lock* (%make-rw-lock '*vm-lock*))
          (setf (rw-lock-state *vm-lock*) +rw-lock-mode-write-locked+
                (rw-lock-write-owner *vm-lock*) (current-thread))
          (debug-uart-boot-line "TRACE paging-start")
          (initialize-paging-system-1)
          (debug-uart-boot-line "TRACE paging-done")
          ;; The direct bootstrap phase is complete.  Publish the normal lock
          ;; shape before any subsequent general-area operation can contend
          ;; for VM-LOCK or enqueue a waiter.
          (debug-uart-boot-line "TRACE vm-lock-publish-start")
          (setf *vm-lock* (make-rw-lock '*vm-lock*))
          ;; From this point the pager is runnable and owns all VM mutations.
          ;; Do not let bootstrap-created threads mutate stack mappings under
          ;; VM-LOCK directly while the pager can service another fault.
          (setf *cold-paging-direct-stack-ops* nil)
          (debug-uart-boot-line "TRACE vm-lock-publish-done"))
        (initialize-paging-system))
    ;; The paging disk is now published, so general-area allocation can use
    ;; the pager.  Publish queue/request and synchronization objects only
    ;; after this point; allocating them earlier recursively entered PAGER-RPC
    ;; with no paging backend and stranded the bootstrap thread in idle.
    (when (null *disk-request-queue-latch*)
      (setf *disk-request-queue-latch*
            (%make-event "Disk request queue notifier" nil)))
    (debug-uart-boot-line "TRACE queue-ready")
    (when (and (boundp '*pager-disk-request*)
               (null *pager-disk-request*))
      (setf *pager-disk-request* (make-disk-request t)
            (disk-request-latch *pager-disk-request*)
            (%make-event "Pager disk request notifier" nil)))
    (debug-uart-boot-line "TRACE pager-request-ready")
    (when first-run-p
      (wake-thread sys.int::*disk-io-thread*))
    (debug-uart-boot-line "TRACE disk-thread-woken")
    (when (and first-run-p
               (not (boundp 'mezzano.runtime::*allocator-lock*)))
      (setf mezzano.runtime::*allocator-lock*
            (make-mutex "Allocator")))
    (debug-uart-boot-line "TRACE allocator-lock-ready")
    (when (or (not (boundp '*vm-lock*))
              (null *vm-lock*))
      (setf *vm-lock* (make-rw-lock '*vm-lock*)))
    (debug-uart-boot-line "TRACE vm-lock-ready")
    ;; The pager thread must be schedulable before hosted paging discovery;
    ;; that phase can block the bootstrap thread in PAGER-RPC.  The ARM timer
    ;; handler tolerates the still-unbound time queues during this window.
    (%enable-interrupts)
    (debug-uart-boot-line "TRACE interrupts-enabled")
    ;; ACPI diagnostics allocate debug buffers.  Run ACPI discovery only after
    ;; the paging backend is ready so a missing/invalid RSDP cannot recurse
    ;; into PAGER-RPC during cold bootstrap.
    (initialize-acpi)
    (debug-uart-boot-line "TRACE acpi-done")
    ;; Framebuffer mapping takes the VM lock and therefore requires the
    ;; paging backend and its lock to exist first.
    (initialize-video)
    (debug-uart-boot-line "TRACE video-done")
    ;; INITIALIZE-TIME creates the heartbeat wait queue and timer queue.  Both
    ;; may require general-area allocation, so initialize them only after the
    ;; paging backend and bootstrap synchronization objects are available.
    (initialize-time)
    (debug-uart-boot-line "TRACE time-done")
    ;; Debug output allocates a general-area buffer.  Keep this historical
    ;; marker after the paging backend and its bootstrap objects are ready.
    (debug-uart-boot-line "TRACE hello-debug-world")
    (debug-uart-boot-line "TRACE debug-done")
    (when (boot-option +boot-option-video-console+)
      (debug-set-output-pseudostream #'debug-video-stream))
    (initialize-time-late)
    (debug-uart-boot-line "TRACE time-late-done")
    (debug-uart-boot-line "TRACE snapshot-call-start")
    (initialize-snapshot)
    (debug-uart-boot-line "TRACE snapshot-done")
    ;; The scheduler/pager bootstrap objects are now published, so device and
    ;; time initialization may safely receive their interrupts.  Keep the
    ;; original startup boundary here; leaving interrupts masked through
    ;; VirtIO/video probing can strand those waiters and drop into idle.
    (%enable-interrupts)
    ;; INITIALIZE-SYNC creates mutex-backed watcher pools.  On a cold boot,
    ;; doing that before the paging backend exists can exhaust wired space,
    ;; enter GC, and deadlock in a pager RPC.  Warm boots retain the original
    ;; no-op behavior because FIRST-RUN-P is false there.
    (initialize-sync first-run-p)
    (debug-uart-boot-line "TRACE sync-done")
    (when first-run-p
      (debug-uart-boot-line "TRACE dirty-bits-start")
      (initialize-pager-dirty-bits)
      (debug-uart-boot-line "TRACE dirty-bits-done")
      ;; The freelist allocator writes card-table entries with interrupts
      ;; masked on the wired stack, where a fault is fatal.  Make those pages
      ;; resident now, while faults can still be serviced.
      (debug-uart-boot-line "TRACE card-prime-start")
      (mezzano.runtime::prime-card-table-pages
       sys.int::*wired-area-base* sys.int::*wired-area-bump*)
      (mezzano.runtime::prime-card-table-pages
       sys.int::*wired-function-area-limit* sys.int::*function-area-base*)
      ;; The cold image's own freelists are not covered by the area bumps
      ;; above; walk the bins so every range the allocator can split is mapped.
      (mezzano.runtime::prime-freelist-card-tables)
      (debug-uart-boot-line "TRACE card-prime-done"))
    (when (not (boot-option +boot-option-no-smp+))
      (debug-uart-boot-line "TRACE smp-start")
      (boot-secondary-cpus)
      (debug-uart-boot-line "TRACE smp-done"))
    (cond (first-run-p
           (debug-uart-boot-line "TRACE post-worker-start")
           (setf *boot-hook-lock* (make-mutex "Boot Hook Lock")
                 *early-boot-hooks* '()
                 *boot-hooks* '()
                 *late-boot-hooks* '())
           (debug-uart-boot-line "TRACE main-thread-start")
           ;; :NORMAL, not :SUPERVISOR.  SCAVENGABLE-THREAD-P deliberately
           ;; refuses to scan the stacks of :SUPERVISOR threads, on the
           ;; contract that they only ever hold pointers to wired objects.
           ;; This thread runs INITIALIZE-LISP -- all of warm loading and
           ;; arbitrary user code -- so its stack is full of general-area
           ;; pointers.  Marking it :SUPERVISOR meant the collector never
           ;; scanned it, and every young-generation pointer on it dangled
           ;; after the first cycle.
           (make-thread #'sys.int::initialize-lisp :name "Main thread")
           (debug-uart-boot-line "TRACE main-thread-done")
           (setf *post-boot-worker-thread*
                 (make-thread #'post-boot-worker :name "Post-boot worker thread"))
           (debug-uart-boot-line "TRACE post-worker-done"))
          ((not first-run-p)
           (setf *post-boot-worker-thread* (make-thread #'post-boot-worker :name "Post-boot worker thread")
                 *boot-hook-lock* (make-mutex "Boot Hook Lock")
                 *early-boot-hooks* '()
                 *boot-hooks* '()
                 *late-boot-hooks* '())
           ;; See the first-run branch: this thread must be scavengable.
           (make-thread #'sys.int::initialize-lisp :name "Main thread")
           (setf *cold-boot-in-progress* nil)
           (debug-uart-boot-line "TRACE main-thread-done"))
          (t (wake-thread *post-boot-worker-thread*)))
    (debug-uart-boot-line "TRACE before-finish")
    (finish-initial-thread)))
