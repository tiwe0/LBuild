;;;; Virtio-block driver

(defpackage :mezzano.supervisor.virtio-block
  (:use :cl)
  (:local-nicknames (:sup :mezzano.supervisor)
                    (:virtio :mezzano.supervisor.virtio)
                    (:sys.int :mezzano.internals)))

(in-package :mezzano.supervisor.virtio-block)

(defconstant +virtio-block-capacity+ 0)
(defconstant +virtio-block-size-max+ 8)
(defconstant +virtio-block-seg-max+ 12)
(defconstant +virtio-block-blk-size+ 20)
(defconstant +virtio-block-f-blk-size+ 6)

(defconstant +virtio-block-req-type+ 0)
(defconstant +virtio-block-req-ioprio+ 4)
(defconstant +virtio-block-req-sector+ 8)
(defconstant +virtio-block-req-status+ 16)

(defconstant +virtio-block-t-in+ 0)
(defconstant +virtio-block-t-out+ 1)
(defconstant +virtio-block-t-flush+ 4)
(defconstant +virtio-block-t-flush-out+ 5)

(defconstant +virtio-block-s-ok+ 0)
(defconstant +virtio-block-s-ioerr+ 1)
(defconstant +virtio-block-s-unsup+ 2)

(defstruct (virtio-block
  (:area :wired)
  ;; Avoid the keyword-dispatch temporary vector during cold boot;
  ;; the block driver is registered before paging is available.
  (:constructor %make-virtio-block (virtio-device)))
  virtio-device
  irq-handler-function
  ;; Initialized explicitly with the positional wired constructor in
  ;; VIRTIO-BLOCK-REGISTER.  A keyword MAKE-EVENT here would allocate a
  ;; general-area argument vector during the pre-pager bootstrap.
  irq-latch
  request-phys
  request-virt
  (block-size 512))

(defun virtio-block-rw (device lba count mem-addr rw)
  (let* ((req (virtio-block-request-virt device))
         (dev (virtio-block-virtio-device device))
         (vq (virtio:virtio-virtqueue dev 0))
         (block-size (virtio-block-block-size device))
         (req-desc (virtio:virtio-ring-alloc-descriptor vq))
         (buf-desc (virtio:virtio-ring-alloc-descriptor vq))
         (stat-desc (virtio:virtio-ring-alloc-descriptor vq)))
    ;; Set up the block request.
    (setf (sys.int::memref-unsigned-byte-32 (+ req +virtio-block-req-type+) 0)
          (ecase rw
            (:read +virtio-block-t-in+)
            (:write +virtio-block-t-out+)))
    (setf (sys.int::memref-unsigned-byte-32 (+ req +virtio-block-req-ioprio+) 0)
          0)
    (setf (sys.int::memref-unsigned-byte-64 (+ req +virtio-block-req-sector+) 0)
          (* lba (truncate block-size 512)))
    (setf (sys.int::memref-unsigned-byte-32 (+ req +virtio-block-req-status+) 0)
          0)
    (sup:ensure req-desc)
    (sup:ensure buf-desc)
    (sup:ensure stat-desc)
    ;; Request descriptor.
    (setf (virtio:virtio-ring-desc-address vq req-desc) (virtio-block-request-phys device)
          (virtio:virtio-ring-desc-length vq req-desc) +virtio-block-req-status+
          (virtio:virtio-ring-desc-flags vq req-desc) (ash 1 virtio:+virtio-ring-desc-f-next+)
          (virtio:virtio-ring-desc-next vq req-desc) buf-desc)
    ;; Buffer descriptor.
    (setf (virtio:virtio-ring-desc-address vq buf-desc) (- mem-addr sup::+physical-map-base+)
          (virtio:virtio-ring-desc-length vq buf-desc) (* count block-size)
          (virtio:virtio-ring-desc-flags vq buf-desc) (logior (ash 1 virtio:+virtio-ring-desc-f-next+)
                                                              (ecase rw
                                                                (:read (ash 1 virtio:+virtio-ring-desc-f-write+))
                                                                (:write 0)))
          (virtio:virtio-ring-desc-next vq buf-desc) stat-desc)
    ;; Status descriptor.
    (setf (virtio:virtio-ring-desc-address vq stat-desc) (+ (virtio-block-request-phys device)
                                                            +virtio-block-req-status+)
          (virtio:virtio-ring-desc-length vq stat-desc) 1
          (virtio:virtio-ring-desc-flags vq stat-desc) (ash 1 virtio:+virtio-ring-desc-f-write+))
    (virtio:virtio-ring-add-to-avail-ring vq req-desc)
    (virtio:virtio-kick dev 0)
    (sup:event-wait (virtio-block-irq-latch device))
    (setf (sup:event-state (virtio-block-irq-latch device)) nil)
    ;; Release the descriptors.
    (virtio:virtio-ring-free-descriptor vq req-desc)
    (virtio:virtio-ring-free-descriptor vq buf-desc)
    (virtio:virtio-ring-free-descriptor vq stat-desc)
    ;; Check status.
    (let ((status (sys.int::memref-unsigned-byte-8 (+ req +virtio-block-req-status+) 0)))
      (values (eql status +virtio-block-s-ok+)
              (case status
                (#.+virtio-block-s-ok+ :no-error)
                (#.+virtio-block-s-ioerr+ :io-error)
                (#.+virtio-block-s-unsup+ :unsupported)
                (t :unknown))))))

(defun virtio-block-read (device lba count mem-addr)
  (virtio-block-rw device lba count mem-addr :read))

(defun virtio-block-write (device lba count mem-addr)
  (virtio-block-rw device lba count mem-addr :write))

(defun virtio-block-flush (device)
  "Flush all completed writes through the virtio-block device."
  (let* ((req (virtio-block-request-virt device))
         (dev (virtio-block-virtio-device device))
         (vq (virtio:virtio-virtqueue dev 0))
         (req-desc (virtio:virtio-ring-alloc-descriptor vq))
         (stat-desc (virtio:virtio-ring-alloc-descriptor vq)))
    ;; Set up a VIRTIO_BLK_T_FLUSH request. It has no data descriptor: only
    ;; the 16-byte request header and the one-byte status are exchanged.
    (setf (sys.int::memref-unsigned-byte-32 (+ req +virtio-block-req-type+) 0)
          +virtio-block-t-flush+
          (sys.int::memref-unsigned-byte-32 (+ req +virtio-block-req-ioprio+) 0)
          0
          (sys.int::memref-unsigned-byte-64 (+ req +virtio-block-req-sector+) 0)
          0
          (sys.int::memref-unsigned-byte-32 (+ req +virtio-block-req-status+) 0)
          0)
    (sup:ensure req-desc)
    (sup:ensure stat-desc)
    ;; Request descriptor.
    (setf (virtio:virtio-ring-desc-address vq req-desc) (virtio-block-request-phys device)
          (virtio:virtio-ring-desc-length vq req-desc) +virtio-block-req-status+
          (virtio:virtio-ring-desc-flags vq req-desc) (ash 1 virtio:+virtio-ring-desc-f-next+)
          (virtio:virtio-ring-desc-next vq req-desc) stat-desc)
    ;; Status descriptor.
    (setf (virtio:virtio-ring-desc-address vq stat-desc) (+ (virtio-block-request-phys device)
                                                            +virtio-block-req-status+)
          (virtio:virtio-ring-desc-length vq stat-desc) 1
          (virtio:virtio-ring-desc-flags vq stat-desc) (ash 1 virtio:+virtio-ring-desc-f-write+))
    (virtio:virtio-ring-add-to-avail-ring vq req-desc)
    (virtio:virtio-kick dev 0)
    (sup:event-wait (virtio-block-irq-latch device))
    (setf (sup:event-state (virtio-block-irq-latch device)) nil)
    ;; Release the descriptors.
    (virtio:virtio-ring-free-descriptor vq req-desc)
    (virtio:virtio-ring-free-descriptor vq stat-desc)
    ;; Check status.
    (let ((status (sys.int::memref-unsigned-byte-8 (+ req +virtio-block-req-status+) 0)))
      (values (eql status +virtio-block-s-ok+)
              (case status
                (#.+virtio-block-s-ok+ :no-error)
                (#.+virtio-block-s-ioerr+ :io-error)
                (#.+virtio-block-s-unsup+ :unsupported)
                (t :unknown))))))

(defun virtio-block-irq-handler (blk)
  (setf (sup:event-state (virtio-block-irq-latch blk)) t))

(defun virtio::virtio-block-register (device)
  ;; Wired allocation required for the IRQ handler closure.
  (declare (mezzano.compiler::closure-allocation :wired))
  (sup:debug-print-line "Detected virtio block device " device)
  (let* ((blk (%make-virtio-block device))
         (irq-latch (sup::%make-event "Virtio-Block IRQ Notifier" nil))
         (irq-handler (lambda (interrupt-frame irq)
                        (declare (ignore interrupt-frame irq))
                        (virtio-block-irq-handler blk)))
         ;; Allocate some memory for the request header & footer.
         (frame (or (sup::allocate-physical-pages 1)
                    (sup:panic "Unable to allocate memory for virtio block request")))
         (phys (* frame sup::+4k-page-size+))
         (virt (sup::convert-to-pmap-address phys)))
    (setf (virtio-block-irq-latch blk) irq-latch)
    (sup:debug-print-line "Virtio-Block request data at " phys)
    (setf (virtio-block-request-phys blk) phys
          (virtio-block-request-virt blk) virt)
    (setf (virtio-block-irq-handler-function blk) irq-handler)
    (virtio:virtio-attach-irq device irq-handler)
    ;; Set the driver bit in the status field.
    (setf (virtio:virtio-device-status device) (logior virtio:+virtio-status-acknowledge+
                                                       virtio:+virtio-status-driver+))
    ;; Negotiate the optional logical block size feature before configuring
    ;; queues. Capacity remains expressed in 512-byte sectors.
    (when (virtio:virtio-device-feature device +virtio-block-f-blk-size+)
      (setf (virtio:virtio-driver-feature device +virtio-block-f-blk-size+) t))
    ;; Allocate virtqueue.
    (when (not (virtio:virtio-configure-virtqueues device 1))
      (setf (virtio:virtio-device-status device) virtio:+virtio-status-failed+)
      (return-from virtio::virtio-block-register nil))
    (let* ((capacity (virtio:virtio-device-specific-header/64 device +virtio-block-capacity+))
           (block-size (if (virtio:virtio-driver-feature device +virtio-block-f-blk-size+)
                           (virtio:virtio-device-specific-header/32 device +virtio-block-blk-size+)
                           512)))
      ;; A malformed device configuration must not cause divide-by-zero or
      ;; unaligned requests. Fall back to the mandatory 512-byte unit.
      (when (or (< block-size 512)
                (> block-size sup::+4k-page-size+)
                (not (zerop (logand block-size (1- block-size))))
                (not (zerop (mod block-size 512))))
        (setf block-size 512))
      (setf (virtio-block-block-size blk) block-size)
      (sup:register-disk blk
                         t
                         (truncate (* capacity 512) block-size)
                         block-size
                         256
                         #'virtio-block-read #'virtio-block-write #'virtio-block-flush
                         nil))
    ;; Configuration complete, go to OK mode.
    (setf (virtio:virtio-device-status device) (logior virtio:+virtio-status-acknowledge+
                                                       virtio:+virtio-status-driver+
                                                       virtio:+virtio-status-ok+))
    t))
