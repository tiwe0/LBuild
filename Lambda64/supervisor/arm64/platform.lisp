(in-package :mezzano.supervisor)

(defun initialize-fdt-dw-apb-uart-console (fdt-node address-cells size-cells)
  (let* ((reg (fdt-get-property fdt-node "reg"))
         (base-address (fdt-read-integer reg address-cells 0))
         (reg-shift-prop (fdt-get-property fdt-node "reg-shift"))
         (reg-shift (if reg-shift-prop
                        (fdt-read-u32 reg-shift-prop)
                        0)))
    (debug-print-line "DW-APB-UART at " base-address " reg-shift " reg-shift)
    (initialize-debug-serial base-address reg-shift
                             #'physical-memref-unsigned-byte-32
                             #'(setf physical-memref-unsigned-byte-32)
                             0 ; UART IRQ is not used by the early console.
                             115200 ; FDT stdout-path does not expose baud parsing yet.
                             nil))) ; Reinitialization is intentionally disabled during early boot.

(defun initialize-fdt-pl011 (fdt-node address-cells size-cells)
  (let* ((reg (fdt-get-property fdt-node "reg"))
         (base-address (fdt-read-integer reg address-cells 0)))
    (initialize-debug-uart base-address)
    (debug-print-line "BOOT-MARK uart-ready")))

(defun initialize-platform-early-console (boot-information-page)
  (declare (ignore boot-information-page))
  (let* ((chosen (fdt-get-named-child-node (fdt-root) "chosen"))
         (stdout-path-prop (if chosen
                               (fdt-get-property chosen "stdout-path")
                               nil))
         (stdout-node (if stdout-path-prop
                          (fdt-resolve-prop-path stdout-path-prop)
                          nil)))
    (debug-print-line "stdout node is " stdout-node)
    (cond ((not stdout-node))
          ((fdt-compatible-p stdout-node "snps,dw-apb-uart")
           (initialize-fdt-dw-apb-uart-console stdout-node
                                               ;; Root-level QEMU FDT uses one cell.
                                               1 1))
          ((fdt-compatible-p stdout-node "arm,pl011")
           (initialize-fdt-pl011 stdout-node
                                 ;; Root-level QEMU FDT uses two cells.
                                 2 2))
          (t
           (debug-print-line "stdout node is an unsupported device")))))

(defun initialize-early-platform ()
  (when (not (fdt-present-p))
    (panic "No FDT provided"))
  (debug-print-line "Performing early FDT scan")
  (arm64-fdt-scan t))

(defun initialize-platform ()
  (initialize-cpu)
  (initialize-psci)
  (debug-print-line "Performing FDT scan")
  (setf *pl031-rtc-base* nil)
  (arm64-fdt-scan nil))

(defun arm64-fdt-scan (earlyp)
  ;; qemu puts all devices in the root node, instead of under a simple-bus.
  ;; Treat the root node as a simple-bus to deal with this.
  (register-fdt-simple-bus (fdt-root) earlyp t))

(defun register-fdt-simple-bus (node earlyp &optional ignore-ranges)
  (let ((address-cells (fdt-address-cells node))
        (size-cells (fdt-size-cells node))
        (ranges (fdt-get-property node "ranges")))
    (when (not ignore-ranges)
      (when (not ranges)
        (debug-print-line "invalid simple-bus. missing ranges")
        (return-from register-fdt-simple-bus))
      (when (not (eql (fdt-property-length ranges) 0))
        ;; Non-empty ranges require translating child bus addresses into the
        ;; parent address space before probing MMIO.  This walker has no
        ;; translation context/API, so ignoring such buses is safer than
        ;; registering devices at the untranslated address.
        (debug-print-line "simple-bus with non-simple parent-child mapping, ignoring.")
        (return-from register-fdt-simple-bus)))
    ;; Walk children, looking for thing.
    (do-fdt-child-nodes (child node)
      (cond ((fdt-compatible-p child "simple-bus")
             (debug-print-line "simple-bus at " child)
             (register-fdt-simple-bus child earlyp))
            ((fdt-compatible-p child "arm,armv8-timer")
             (when (not earlyp)
               (initialize-platform-time child)))
            ((or (fdt-compatible-p child "arm,gic-400")
                 (fdt-compatible-p child "arm,cortex-a15-gic"))
             (when earlyp
               (initialize-fdt-gic-400 child address-cells size-cells)))
            ((fdt-compatible-p child "virtio,mmio")
             (when (not earlyp)
               (virtio-mmio-fdt-register child address-cells size-cells)))
            #+(or) ; not implemented yet!
            ((fdt-compatible-p child "allwinner,sun4i-a10-timer")
             (when (not earlyp)
               (initialize-fdt-sun4i-a10-timer node address-cells size-cells)))
            ((fdt-compatible-p child "arm,psci-1.0")
             (when (not earlyp)
               (psci-register child)))
            ((fdt-compatible-p child "arm,pl031")
             (when (not earlyp)
               (initialize-arm-rtc child address-cells size-cells)))
            (t
             (debug-print-line "unknown fdt node at " child " on simple-bus"))))))

(sys.int::define-lap-function %semihosting-exit ((reason code))
  ;; Set up parameter block at [sp]
  (mezzano.lap.arm64:add :x0 :xzr :x0 :asr #.sys.int::+n-fixnum-bits+)
  (mezzano.lap.arm64:add :x1 :xzr :x1 :asr #.sys.int::+n-fixnum-bits+)
  (mezzano.lap.arm64:stp :x0 :x1 (:pre :sp -16))
  ;; Do semihosting call
  (mezzano.lap.arm64:mov :x0 #x18) ; SYS_EXIT
  (mezzano.lap.arm64:add :x1 :sp 0)
  (mezzano.lap.arm64:hlt #xF000)
  ;; Drop parameter block and return
  (mezzano.lap.arm64:add :sp :sp 16)
  (mezzano.lap.arm64:ret))

(defun ci-exit (&optional errorp)
  (when (running-in-ci-p)
    (%semihosting-exit #x20026 ; ADP_Stopped_ApplicationExit
                       (if errorp #x01 #x00)))) ; error code
