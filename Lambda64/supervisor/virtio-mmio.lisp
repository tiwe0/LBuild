;;;; MMIO transport for virtio devices.

(defpackage :mezzano.supervisor.virtio-mmio-transport
  (:use :cl)
  (:local-nicknames (:sup :mezzano.supervisor)
                    (:virtio :mezzano.supervisor.virtio)
                    (:sys.int :mezzano.internals)))

(in-package :mezzano.supervisor.virtio-mmio-transport)

(virtio:define-virtio-transport virtio-legacy-mmio-transport)

(defstruct (virtio-legacy-mmio-device
             (:include virtio:virtio-device)
             (:area :wired)
             ;; The keyword constructor allocates a temporary argument vector
             ;; in the general area. MMIO discovery runs before the paging
             ;; backend is published, so use a positional bootstrap constructor
             ;; and fill inherited slots explicitly below. Included slots
             ;; precede the MMIO fields in the positional argument order.
             (:constructor %make-virtio-legacy-mmio-device
                 (transport virtqueues did claimed boot-id mmio mmio-irq)))
  mmio
  mmio-irq)

(defun %allocate-virtio-legacy-mmio-device (mmio mmio-irq)
  "Allocate an MMIO device without relying on inherited constructor order."
  (let ((dev (sys.int::%allocate-struct 'virtio-legacy-mmio-device)))
    ;; %ALLOCATE-STRUCT hands back raw storage: every slot must be written
    ;; here, including the ones this transport does not care about.  VIRTQUEUES
    ;; and CLAIMED were left holding the unbound marker, which is not NIL, so
    ;; (VIRTIO-DEVICE-CLAIMED dev) was true for every device the moment it was
    ;; allocated.  REGISTER-VIRTIO-DRIVER and VIRTIO-LATE-PROBE both skip
    ;; claimed devices, so no driver could ever attach to an MMIO transport --
    ;; the net, GPU and input devices were all invisible.  Only virtio-block
    ;; worked, because VIRTIO-DEVICE-REGISTER special-cases it and attaches
    ;; without consulting CLAIMED.  DID is written by VIRTIO-MMIO-REGISTER
    ;; immediately after this returns.
    (setf (virtio::virtio-device-transport dev) #'virtio-legacy-mmio-transport
          (virtio::virtio-device-virtqueues dev) nil
          (virtio::virtio-device-did dev) nil
          (virtio::virtio-device-claimed dev) nil
          (virtio::virtio-device-boot-id dev) (sup:current-boot-id)
          (virtio-legacy-mmio-device-mmio dev) mmio
          (virtio-legacy-mmio-device-mmio-irq dev) mmio-irq)
    dev))

(defmacro define-virtio-mmio-register (name index)
  (let ((accessor (intern (format nil "VIRTIO-MMIO-~A" name)
                          (symbol-package name))))
    `(progn
       (defun ,accessor (device)
         (sup::physical-memref-unsigned-byte-32 (+ (virtio-legacy-mmio-device-mmio device)
                                                   ',index)))
       (defun (setf ,accessor) (value device)
         (setf (sup::physical-memref-unsigned-byte-32 (+ (virtio-legacy-mmio-device-mmio device)
                                                         ',index))
               value)))))

;;; Registers in the MMIO virtio header.
(define-virtio-mmio-register magic              #x00)
(define-virtio-mmio-register version            #x04)
(define-virtio-mmio-register device-id          #x08)
(define-virtio-mmio-register vendor-id          #x0C)
(define-virtio-mmio-register host-features      #x10)
(define-virtio-mmio-register host-features-sel  #x14)
(define-virtio-mmio-register guest-features     #x20)
(define-virtio-mmio-register guest-features-sel #x24)
(define-virtio-mmio-register guest-page-size    #x28)
(define-virtio-mmio-register queue-sel          #x30)
(define-virtio-mmio-register queue-num-max      #x34)
(define-virtio-mmio-register queue-num          #x38)
(define-virtio-mmio-register queue-align        #x3C)
(define-virtio-mmio-register queue-pfn          #x40)
(define-virtio-mmio-register queue-notify       #x50)
(define-virtio-mmio-register interrupt-status   #x60)
(define-virtio-mmio-register interrupt-ack      #x64)
(define-virtio-mmio-register status             #x70)
(defconstant +virtio-mmio-config0+            #x100)

(defconstant +virtio-mmio-magic-value+ #x74726976)

(defun virtio-legacy-mmio-transport-device-feature (device bit)
  (setf (virtio-mmio-host-features-sel device) (truncate bit 32))
  (logbitp (rem bit 32) (virtio-mmio-host-features device)))

(defun virtio-legacy-mmio-transport-driver-feature (device bit)
  (setf (virtio-mmio-guest-features-sel device) (truncate bit 32))
  (logbitp (rem bit 32) (virtio-mmio-guest-features device)))

(defun (setf virtio-legacy-mmio-transport-driver-feature) (value device bit)
  (setf (virtio-mmio-guest-features-sel device) (truncate bit 32))
  ;; LDB/DPB may materialize a temporary general-area integer.  Feature
  ;; negotiation runs before the paging backend is published, so that
  ;; allocation immediately becomes an early page fault.  Keep the update
  ;; within fixnum arithmetic and write the complete 32-bit register instead.
  (let* ((mask (ash 1 (rem bit 32)))
         (old (virtio-mmio-guest-features device))
         (new (if value
                  (logior old mask)
                  (logand old (lognot mask)))))
    (setf (virtio-mmio-guest-features device) new))
  value)

(defun virtio-legacy-mmio-transport-device-specific-header/8 (device offset)
  (sup::physical-memref-unsigned-byte-8 (+ (virtio-legacy-mmio-device-mmio device)
                                           +virtio-mmio-config0+
                                           offset)))

(defun (setf virtio-legacy-mmio-transport-device-specific-header/8) (value device offset)
  (setf (sup::physical-memref-unsigned-byte-8 (+ (virtio-legacy-mmio-device-mmio device)
                                                 +virtio-mmio-config0+
                                                 offset))
        value))

(defun virtio-legacy-mmio-transport-device-specific-header/16 (device offset)
  (sup::physical-memref-unsigned-byte-16 (+ (virtio-legacy-mmio-device-mmio device)
                                            +virtio-mmio-config0+
                                            offset)))

(defun (setf virtio-legacy-mmio-transport-device-specific-header/16) (value device offset)
  (setf (sup::physical-memref-unsigned-byte-16 (+ (virtio-legacy-mmio-device-mmio device)
                                                  +virtio-mmio-config0+
                                                  offset))
        value))

(defun virtio-legacy-mmio-transport-device-specific-header/32 (device offset)
  (sup::physical-memref-unsigned-byte-32 (+ (virtio-legacy-mmio-device-mmio device)
                                            +virtio-mmio-config0+
                                            offset)))

(defun (setf virtio-legacy-mmio-transport-device-specific-header/32) (value device offset)
  (setf (sup::physical-memref-unsigned-byte-32 (+ (virtio-legacy-mmio-device-mmio device)
                                                  +virtio-mmio-config0+
                                                  offset))
        value))

(defun virtio-legacy-mmio-transport-isr-status (device)
  (virtio-mmio-interrupt-status device))

(defun virtio-legacy-mmio-transport-ack-irq (device status)
  (setf (virtio-mmio-interrupt-ack device) status))

(defun virtio-legacy-mmio-transport-device-status (device)
  (virtio-mmio-status device))

(defun (setf virtio-legacy-mmio-transport-device-status) (value device)
  (setf (virtio-mmio-status device) value))

(defun virtio-legacy-mmio-transport-device-irq (device)
  (virtio-legacy-mmio-device-mmio-irq device))

(defun virtio-mmio-register (address irq)
  ;; Probe the fixed MMIO header before allocating a wired Lisp object.  QEMU
  ;; exposes several reserved/legacy slots in the FDT; allocating each one
  ;; first exhausts the cold wired area and falls into PAGER-RPC before the
  ;; paging backend exists.
  (let* ((magic (sup::physical-memref-unsigned-byte-32 address))
         (version (sup::physical-memref-unsigned-byte-32 (+ address #x04)))
         (did (sup::physical-memref-unsigned-byte-32 (+ address #x08))))
    (when (not (and (eql magic +virtio-mmio-magic-value+)
                    (eql version 1)
                    (not (eql did virtio:+virtio-dev-id-invalid+))))
      (return-from virtio-mmio-register nil))
    (let* ((dev (%allocate-virtio-legacy-mmio-device address irq)))
      (let ((vid (virtio-mmio-vendor-id dev)))
        (setf (virtio:virtio-device-did dev) did)
        (sup:debug-print-line "mmio virtio device at " address " did: " did " vid: " vid)
        (virtio:virtio-device-register dev)))))

(defun sup::virtio-mmio-fdt-register (fdt-node address-cells size-cells)
  (declare (ignore size-cells))
  (let* ((reg (sup::fdt-get-property fdt-node "reg"))
         (address (sup::fdt-read-integer reg address-cells 0))
         (interrupts (sup::fdt-get-property fdt-node "interrupts"))
         ;; GIC interrupt specifiers encode the type in cell 0 (0 = SPI,
         ;; 1 = PPI) and the interrupt ID in cell 1.  Convert to the global
         ;; IRQ namespace used by PLATFORM-IRQ instead of assuming every
         ;; device interrupt is an SPI.
         (irq-type (sup::fdt-read-u32 interrupts 0))
         (irq-id (sup::fdt-read-u32 interrupts 1))
         (irq-base (case irq-type (0 32) (1 16) (otherwise nil))))
    (when (null irq-base)
      (sup:debug-print-line "virtio-mmio: unsupported FDT IRQ type " irq-type)
      ;; The function is interned in the SUP package; qualify the block name
      ;; so RETURN-FROM targets the actual DEFUN name from this transport
      ;; package (an unqualified symbol would be a different block).
      (return-from sup::virtio-mmio-fdt-register nil))
    (virtio-mmio-register address (+ irq-base irq-id))))

(defun virtio-legacy-mmio-transport-kick (dev vq-id)
  "Notify the device that new buffers have been added to VQ-ID."
  (setf (virtio-mmio-queue-notify dev) vq-id)
  (sys.int::dma-write-barrier))

(defun virtio-legacy-mmio-transport-queue-select (device)
  (virtio-mmio-queue-sel device))

(defun (setf virtio-legacy-mmio-transport-queue-select) (queue device)
  (setf (virtio-mmio-queue-sel device) queue))

(defun virtio-legacy-mmio-transport-queue-size (device)
  (let ((size (virtio-mmio-queue-num-max device)))
    ;; Sigh...
    (setf (virtio-mmio-queue-num device) size)
    size))

(defun virtio-legacy-mmio-transport-queue-address (device)
  (* (virtio-mmio-queue-pfn device) sup::+4k-page-size+))

(defun (setf virtio-legacy-mmio-transport-queue-address) (address device)
  ;; This is a page number, not an actual address.
  (setf (virtio-mmio-guest-page-size device) sup::+4k-page-size+)
  (setf (virtio-mmio-queue-pfn device) (truncate address sup::+4k-page-size+)))

(defun virtio-legacy-mmio-transport-enable-queue (device queue)
  (declare (ignore device queue))
  nil)

(defun virtio-mmio-device-irq (device)
  (virtio-legacy-mmio-device-mmio-irq device))
