;;;; ARM64 target support

(defpackage :mezzano.cold-generator.arm64
  (:use :cl)
  (:import-from #:mezzano.cold-generator
                #:configure-system-for-target)
  (:local-nicknames (#:env #:mezzano.cold-generator.environment)
                    (#:ser #:mezzano.cold-generator.serialize)
                    (#:util #:mezzano.cold-generator.util)
                    (#:lap #:mezzano.lap.arm64)
                    (#:sup #:mezzano.supervisor)
                    (#:sys.int #:mezzano.internals)))

(in-package :mezzano.cold-generator.arm64)

(defparameter *funcallable-instance-trampoline*
  `(;; Load the real function from the funcallable-instance.
    (lap:ldr :x6 (:object :x6 ,sys.int::+funcallable-instance-function+))
    ;; Invoke the real function via the FUNCTION calling convention.
    (lap:ldr :x9 (:object :x6 ,sys.int::+function-entry-point+))
    (lap:br :x9))
  "Trampoline used for calling a closure or funcallable-instance via a funcallable-instance.")

(defconstant +exception-vector-alignment+ 2048
  "Minimum alignment for the exception vector. See definition of VBAR_EL1 in the ARM ARM.")

(defmethod configure-system-for-target (environment (target (eql :arm64)))
  (setf (env:cross-symbol-value environment 'sys.int::*funcallable-instance-trampoline*)
        (env:compile-lap environment
                         *funcallable-instance-trampoline*
                         :area :wired-function
                         :name (env:translate-symbol environment 'sys.int::%%funcallable-instance-trampoline%%)))
  (setf (env:cross-symbol-value environment 'mezzano.supervisor::*bsp-wired-stack*)
        (env:make-stack environment (* 128 1024)))
  (setf (env:cross-symbol-value environment 'mezzano.supervisor::*bsp-cpu*)
        (env:make-structure environment 'mezzano.supervisor::arm64-cpu))
  ;; BOOTLOADER-ENTRY-POINT creates the first boot event before the pager is
  ;; initialized.  Provide a wired event object up front so that transition
  ;; does not enter the dynamic allocator.
  (setf (env:cross-symbol-value environment 'mezzano.supervisor::*initial-boot-event*)
        (env:make-structure environment 'mezzano.supervisor::event
                            :name 'boot-epoch
                            :%lock :unlocked
                            :head nil
                            :tail nil
                            :%state nil
                            :monitors nil))
  ;; CONFIGURE-GIC runs before the pager is online and needs a fixed 1024-slot
  ;; IRQ table.  Materialize it in the wired image so early boot does not
  ;; attempt a dynamic-area allocation for the table itself.
  (setf (env:cross-symbol-value environment 'mezzano.supervisor::*gic-irqs*)
        (env:make-array environment 1024
                        :initial-element nil
                        :area :wired))
  ;; Early boot can fall back from the TLAB fast path into the general
  ;; allocator before FIRST-RUN-INITIALIZE-ALLOCATOR runs.  Provide the lock
  ;; object that those wired-allocation paths expect instead of leaving its
  ;; DEFGLOBAL value cell unbound.
  (setf (env:cross-symbol-value environment 'mezzano.runtime::*allocator-lock*)
        (env:make-structure environment
                            'mezzano.supervisor::mutex
                            :name "Allocator"
                            :%lock :unlocked
                            :head nil
                            :tail nil
                            :owner nil
                            :state :unlocked
                            :stack-next nil
                            :contested-count 0))
  (setf (env:cross-symbol-value environment 'mezzano.supervisor::*arm64-exception-vector*)
        (env:compile-lap environment
                         (loop repeat (/ (+ 2048 +exception-vector-alignment+) 8) ; for alignment
                               collect `(:d64/le 0))
                         :area :wired-function
                         :name 'sys.int::*arm64-exception-vector*)))

(defmethod ser:post-serialize-image-for-target (image environment (target (eql :arm64)))
  (let* ((ex-vec (env:cross-symbol-value environment 'mezzano.supervisor::*arm64-exception-vector*))
         (ex-vec-val (ser:serialize-object ex-vec image environment))
         (ex-vec-addr (+ ex-vec-val (- sys.int::+tag-object+) 8)) ; slot 0
         ;; Base address of the exception vector must be properly aligned.
         (ex-vec-base (util:align-up ex-vec-addr +exception-vector-alignment+))
         (offset (- ex-vec-base ex-vec-addr))
         (slot-offset (/ offset 8)))
    (setf (ser::image-symbol-value image environment
                                   'mezzano.supervisor::*arm64-exception-vector-base*)
          (ser::serialize-object ex-vec-base image environment))
    (labels (((setf mref32) (value base index)
               (if (evenp index)
                   (setf (ldb (byte 32 0) (ser::object-slot image ex-vec-val (+ slot-offset base (ash index -1)))) value)
                   (setf (ldb (byte 32 32) (ser::object-slot image ex-vec-val (+ slot-offset base (ash index -1)))) value)))
             (gen-vector (offset common entry)
               (setf offset (/ offset 8))
               (let* ((common-fref (env:function-reference
                                    environment
                                    (env:translate-symbol environment common)))
                      (common-fn (env:function-reference-function common-fref))
                      (common-fn-val (ser:serialize-object common-fn image environment))
                      (common-entry (ser::object-slot image common-fn-val sys.int::+function-entry-point+))
                      (entry-fref (env:function-reference
                                   environment
                                   (env:translate-symbol environment entry)))
                      (entry-fref-val (ser:serialize-object entry-fref image environment)))
                 ;; sub sp, sp, #x30. Space for the iret frame & frame pointer
                 (setf (mref32 offset 0) #xD100C3FF)
                 ;; str x29, [sp]
                 (setf (mref32 offset 1) #xF90003FD)
                 ;; ldr x29, [fn]
                 (setf (mref32 offset 2) #x5800005D)
                 ;; b common-entry
                 (let ((entry-rel (- common-entry (+ ex-vec-base (* offset 8) 12))))
                   (setf (mref32 offset 3)
                         (logior #x14000000
                                 (ldb (byte 26 2) entry-rel))))
                 ;; fn: entry-fref
                 (setf (ser::object-slot image ex-vec-val (+ slot-offset offset 2)) entry-fref-val)))
             (gen-invalid (offset)
               ;; HLT #1
               (setf offset (/ offset 8))
               (setf (mref32 offset 0) #xD4400020)))
      (gen-vector #x000 'sup::%el0-common 'sup::%synchronous-el0-handler)
      (gen-vector #x080 'sup::%el0-common 'sup::%irq-el0-handler)
      (gen-vector #x100 'sup::%el0-common 'sup::%fiq-el0-handler)
      (gen-vector #x180 'sup::%el0-common 'sup::%serror-el0-handler)
      (gen-vector #x200 'sup::%elx-common 'sup::%synchronous-elx-handler)
      (gen-vector #x280 'sup::%elx-common 'sup::%irq-elx-handler)
      (gen-vector #x300 'sup::%elx-common 'sup::%fiq-elx-handler)
      (gen-vector #x380 'sup::%elx-common 'sup::%serror-elx-handler)
      ;; These vectors are used when the CPU moves from a lower EL.
      ;; We're always running in EL1, so these are not used.
      (dotimes (i 8)
        (gen-invalid (+ #x400 (* i #x80)))))
    ;; Finalize/post-serialization can revisit already materialized symbol
    ;; cells.  Write the bootstrap allocator defaults after all image object
    ;; slots exist, otherwise an earlier snapshot may retain UNBOUND.
    (dolist (name '(sys.int::*general-area-young-gen-bump*
                    sys.int::*general-area-young-gen-limit*
                    sys.int::*cons-area-young-gen-bump*
                    sys.int::*cons-area-young-gen-limit*
                    sys.int::*young-gen-newspace-bit*
                    sys.int::*young-gen-newspace-bit-raw*))
      (setf (ser::image-symbol-value image environment name)
            (ser:serialize-object 0 image environment)))
    (dolist (name '(mezzano.runtime::*general-area-expansion-granularity*
                    mezzano.runtime::*cons-area-expansion-granularity*))
      (setf (ser::image-symbol-value image environment name)
            (ser:serialize-object sys.int::+allocation-minimum-alignment+
                                  image environment)))
    (dolist (name '(sys.int::*gc-in-progress*
                    mezzano.runtime::*enable-allocation-profiling*
                    mezzano.supervisor::*world-stopper*))
      (setf (ser::image-symbol-value image environment name)
            (ser:serialize-object nil image environment)))))

(defmethod ser:pre-serialize-image-for-target (image environment (target (eql :arm64)))
  ;; FINALIZE-AREAS freezes allocation and constructs freelists.  The ARM64
  ;; post-serializer patches the exception vector and interrupt entry points,
  ;; so make every object it will touch reachable before that freeze.
  (ser:serialize-object
   (env:cross-symbol-value environment 'mezzano.supervisor::*arm64-exception-vector*)
   image environment)
  ;; Seed the cross-environment global before its value cell is drained.  The
  ;; boot entry reads this value while installing VBAR_EL1, before the normal
  ;; post-serialization patch pass can repair a late-bound cell.
  (let* ((ex-vec (env:cross-symbol-value environment
                                         'mezzano.supervisor::*arm64-exception-vector*))
         (ex-vec-val (ser:serialize-object ex-vec image environment))
         (ex-vec-addr (+ ex-vec-val (- sys.int::+tag-object+) 8))
         (ex-vec-base (util:align-up ex-vec-addr +exception-vector-alignment+)))
    (setf (env:symbol-global-value
           environment
           (env:translate-symbol environment
                                 'mezzano.supervisor::*arm64-exception-vector-base*))
          ex-vec-base))
  ;; The allocator reads this global while the supervisor is still bringing
  ;; up the first CPU, before the regular Lisp root set is reachable.  A
  ;; DEFGLOBAL declaration alone does not guarantee that the cold environment
  ;; has a bound value cell, so seed it explicitly with NIL here.
  (let ((gc-in-progress (env:translate-symbol environment
                                               'sys.int::*gc-in-progress*)))
    (setf (env:symbol-global-value environment gc-in-progress) nil))
  ;; The fast allocation path also checks the runtime profiling switch before
  ;; it checks GC state.  DEFGLOBAL leaves an unbound cell in a fresh cold
  ;; environment, which would turn the first allocation into an unbound-symbol
  ;; panic.  Seed the switch to its disabled default as well.
  (let ((allocation-profiling (env:translate-symbol
                               environment
                               'mezzano.runtime::*enable-allocation-profiling*)))
    (setf (env:symbol-global-value environment allocation-profiling) nil))
  ;; Wired allocation checks WORLD-STOPPER while no scheduler thread exists;
  ;; the supervisor's DEFGLOBAL must therefore start out explicitly NIL.
  (let ((world-stopper (env:translate-symbol
                        environment
                        'mezzano.supervisor::*world-stopper*)))
    (setf (env:symbol-global-value environment world-stopper) nil))
  ;; Fast allocation probes these counters and limits before the first-run
  ;; allocator reset.  Give them the same zero baseline that
  ;; FIRST-RUN-INITIALIZE-ALLOCATOR installs; otherwise the first probe sees
  ;; an unbound value cell instead of taking the slow path.
  (dolist (name '(sys.int::*general-area-young-gen-bump*
                  sys.int::*general-area-young-gen-limit*
                  sys.int::*cons-area-young-gen-bump*
                  sys.int::*cons-area-young-gen-limit*
                  sys.int::*young-gen-newspace-bit*
                  sys.int::*young-gen-newspace-bit-raw*))
    (setf (env:symbol-global-value environment
                                   (env:translate-symbol environment name))
          0))
  (dolist (name '(mezzano.runtime::*general-area-expansion-granularity*
                  mezzano.runtime::*cons-area-expansion-granularity*))
    (setf (env:symbol-global-value environment
                                   (env:translate-symbol environment name))
          sys.int::+allocation-minimum-alignment+))
  (dolist (name '(mezzano.supervisor::*arm64-exception-vector-base*
                  sys.int::*gc-in-progress*
                  mezzano.runtime::*enable-allocation-profiling*
                  sys.int::*general-area-young-gen-bump*
                  sys.int::*general-area-young-gen-limit*
                  sys.int::*cons-area-young-gen-bump*
                  sys.int::*cons-area-young-gen-limit*
                  sys.int::*young-gen-newspace-bit*
                  sys.int::*young-gen-newspace-bit-raw*
                  mezzano.runtime::*general-area-expansion-granularity*
                  mezzano.runtime::*cons-area-expansion-granularity*
                  mezzano.supervisor::*world-stopper*
                  mezzano.supervisor::*bsp-cpu*
                  mezzano.supervisor::*bsp-wired-stack*
                  mezzano.supervisor::*initial-boot-event*
                  mezzano.supervisor::*gic-irqs*
                  mezzano.supervisor::*n-up-cpus*
                  mezzano.supervisor::*cpus*
                  ;; These two functions run before the normal Lisp roots are
                  ;; reachable: kboot copies %%PE-BOOTSTRAP into executable
                  ;; memory, and the bootloader entry invokes the data
                  ;; initializer first.  Keep their function bodies alive,
                  ;; not just their frefs.
                  sup::%%pe-bootstrap
                  sup::initialize-pe-bootstrap-data
                  sup::%el0-common
                  sup::%synchronous-el0-handler
                  sup::%irq-el0-handler
                  sup::%fiq-el0-handler
                  sup::%serror-el0-handler
                  sup::%elx-common
                  sup::%synchronous-elx-handler
                  sup::%irq-elx-handler
                  sup::%fiq-elx-handler
                  sup::%serror-elx-handler
                  sup::%load-cpu-bits
                  sup::initialize-boot-cpu
                  sup::arm64-cpu-self
                  (setf sup::arm64-cpu-self)
                  sup::arm64-cpu-state
                  (setf sup::arm64-cpu-state)
                  sup::arm64-cpu-idle-thread
                  (setf sup::arm64-cpu-idle-thread)
                  sup::arm64-cpu-wired-stack
                  (setf sup::arm64-cpu-wired-stack)
                  sup::arm64-cpu-sp-el1
                  (setf sup::arm64-cpu-sp-el1)
                  sys.int::memref-unsigned-byte-64
                  sys.int::bootloader-entry-point))
    (let* ((symbol (if (consp name)
                       name
                       (env:translate-symbol environment name)))
           (fref (env:function-reference environment symbol)))
      ;; Only the exception-vector-base global needs its symbol cell before
      ;; POST-SERIALIZE updates the value.  Function roots should not pull in
      ;; every symbol/string reachable from the name; serialize their fref and
      ;; concrete function body directly.
      (if (member name '(mezzano.supervisor::*arm64-exception-vector-base*
                         sys.int::*gc-in-progress*
                         mezzano.runtime::*enable-allocation-profiling*
                         sys.int::*general-area-young-gen-bump*
                         sys.int::*general-area-young-gen-limit*
                         sys.int::*cons-area-young-gen-bump*
                         sys.int::*cons-area-young-gen-limit*
                         sys.int::*young-gen-newspace-bit*
                         sys.int::*young-gen-newspace-bit-raw*
                         mezzano.runtime::*general-area-expansion-granularity*
                         mezzano.runtime::*cons-area-expansion-granularity*
                         mezzano.supervisor::*world-stopper*
                         mezzano.supervisor::*bsp-cpu*
                         mezzano.supervisor::*bsp-wired-stack*
                         mezzano.supervisor::*initial-boot-event*
                         mezzano.supervisor::*gic-irqs*
                         mezzano.supervisor::*n-up-cpus*
                         mezzano.supervisor::*cpus*))
          (progn
            (ser:serialize-object symbol image environment)
            ;; SYMBOL serialization deliberately avoids creating missing
            ;; global value cells.  These bootstrap globals are read before
            ;; normal Lisp roots become reachable, so serialize each existing
            ;; cell explicitly to make sure its initializer runs before
            ;; FINALIZE-AREAS.
            (ser:serialize-object
             (env:symbol-global-value-cell environment symbol)
             image environment)))
      (let ((fn (env:function-reference-function fref)))
        (when fn
          ;; kboot eagerly loads only wired pages before jumping to the image
          ;; entry.  Keep the first function body wired so its initial
          ;; instruction fetch cannot fault before Lisp installs VBAR_EL1.
          (when (member name '(sys.int::bootloader-entry-point
                               sup::initialize-boot-cpu
                               sup::%load-cpu-bits
                               sup::arm64-cpu-self
                               (setf sup::arm64-cpu-self)
                               sup::arm64-cpu-state
                               (setf sup::arm64-cpu-state)
                               sup::arm64-cpu-idle-thread
                               (setf sup::arm64-cpu-idle-thread)
                               sup::arm64-cpu-wired-stack
                               (setf sup::arm64-cpu-wired-stack)
                               sup::arm64-cpu-sp-el1
                               (setf sup::arm64-cpu-sp-el1)
                               sys.int::memref-unsigned-byte-64))
            (setf (slot-value fn 'env::%area) :wired-function))
          (ser:serialize-object fn image environment)))
      (ser:serialize-object fref image environment)
    )
  ;; Some bootstrap symbols may already have been serialized while traversing
  ;; earlier roots.  Updating only the cross-environment cell above would then
  ;; leave the image's copied value slot at the original unbound marker.  Patch
  ;; the serialized slots explicitly so the first allocator probe observes
  ;; the same zero/NIL defaults in the image itself.
  (dolist (name '(sys.int::*general-area-young-gen-bump*
                  sys.int::*general-area-young-gen-limit*
                  sys.int::*cons-area-young-gen-bump*
                  sys.int::*cons-area-young-gen-limit*
                  sys.int::*young-gen-newspace-bit*
                  sys.int::*young-gen-newspace-bit-raw*))
    (setf (ser::image-symbol-value image environment name)
          (ser:serialize-object 0 image environment)))
  (dolist (name '(mezzano.runtime::*general-area-expansion-granularity*
                  mezzano.runtime::*cons-area-expansion-granularity*))
    (setf (ser::image-symbol-value image environment name)
          (ser:serialize-object sys.int::+allocation-minimum-alignment+
                                image environment)))
  (dolist (name '(sys.int::*gc-in-progress*
                  mezzano.runtime::*enable-allocation-profiling*
                  mezzano.supervisor::*world-stopper*))
    (setf (ser::image-symbol-value image environment name)
          (ser:serialize-object nil image environment)))
  nil))
