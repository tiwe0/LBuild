;;;; Supervisor level support for various partitioning schemes

(in-package :mezzano.supervisor)

(declaim (inline memref-ub16/le memref-ub16/be))
(defun memref-ub16/le (base &optional (index 0))
  (let ((address (+ base (* index 2))))
    (logior (sys.int::memref-unsigned-byte-8 address)
            (ash (sys.int::memref-unsigned-byte-8 (+ address 1)) 8))))

(defun memref-ub16/be (base)
  (logior (ash (sys.int::memref-unsigned-byte-8 base) 8)
          (sys.int::memref-unsigned-byte-8 (+ base 1))))

(declaim (inline memref-ub32/le memref-ub32/be))
(defun memref-ub32/le (base &optional (index 0))
  (let ((address (+ base (* index 4))))
    (logior (sys.int::memref-unsigned-byte-8 address)
            (ash (sys.int::memref-unsigned-byte-8 (+ address 1)) 8)
            (ash (sys.int::memref-unsigned-byte-8 (+ address 2)) 16)
            (ash (sys.int::memref-unsigned-byte-8 (+ address 3)) 24))))

(defun memref-ub32/be (base)
  (logior (ash (sys.int::memref-unsigned-byte-8 base) 24)
          (ash (sys.int::memref-unsigned-byte-8 (+ base 1)) 16)
          (ash (sys.int::memref-unsigned-byte-8 (+ base 2)) 8)
          (sys.int::memref-unsigned-byte-8 (+ base 3))))

(declaim (inline memref-ub64/le memref-ub64/be))
(defun memref-ub64/le (base &optional (index 0))
  (let ((address (+ base (* index 8))))
    (logior (sys.int::memref-unsigned-byte-8 address)
            (ash (sys.int::memref-unsigned-byte-8 (+ address 1)) 8)
            (ash (sys.int::memref-unsigned-byte-8 (+ address 2)) 16)
            (ash (sys.int::memref-unsigned-byte-8 (+ address 3)) 24)
            (ash (sys.int::memref-unsigned-byte-8 (+ address 4)) 32)
            (ash (sys.int::memref-unsigned-byte-8 (+ address 5)) 40)
            (ash (sys.int::memref-unsigned-byte-8 (+ address 6)) 48)
            (ash (sys.int::memref-unsigned-byte-8 (+ address 7)) 56))))

(defun memref-ub64/be (base)
  (logior (ash (sys.int::memref-unsigned-byte-8 base) 56)
          (ash (sys.int::memref-unsigned-byte-8 (+ base 1)) 48)
          (ash (sys.int::memref-unsigned-byte-8 (+ base 2)) 40)
          (ash (sys.int::memref-unsigned-byte-8 (+ base 3)) 32)
          (ash (sys.int::memref-unsigned-byte-8 (+ base 4)) 24)
          (ash (sys.int::memref-unsigned-byte-8 (+ base 5)) 16)
          (ash (sys.int::memref-unsigned-byte-8 (+ base 6)) 8)
          (sys.int::memref-unsigned-byte-8 (+ base 7))))

(defmacro with-pages ((virtual-address n-pages &rest options) &body body)
  (let ((n-pages-sym (gensym "N-PAGES"))
        (page (gensym "PAGE"))
        (type (getf options :type :other))
        (mandatory-p (getf options :mandatory-p nil))
        (32-bit-only (getf options :32-bit-only nil)))
    `(let* ((,n-pages-sym ,n-pages)
            ;; Use the positional entry point so partition probing can
            ;; allocate its temporary wired page before PAGER-RPC exists.
            (,page (%allocate-physical-pages ,n-pages-sym ,type
                                             ,mandatory-p ,32-bit-only))
            (,virtual-address (when ,page
                                (convert-to-pmap-address (* ,page +4k-page-size+)))))
       (unwind-protect
            (progn ,@body)
         (when ,page
           (release-physical-pages ,page ,n-pages-sym))))))

(defun read-disk-partition (device lba n-sectors buffer)
  (funcall (disk-read-fn (partition-disk device))
           (disk-device (partition-disk device))
           (+ (partition-offset device) lba)
           n-sectors
           buffer))

(defun write-disk-partition (device lba n-sectors buffer)
  (funcall (disk-write-fn (partition-disk device))
           (disk-device (partition-disk device))
           (+ (partition-offset device) lba)
           n-sectors
           buffer))

(defun flush-disk-partition (device)
  (funcall (disk-flush-fn (partition-disk device))
           (disk-device (partition-disk device))))

(defun detect-disk-partitions ()
  (dolist (disk (all-disks))
    (debug-uart-boot-line "TRACE partition-disk")
    ;; Search for a GPT, then a PC MBR.
    (or (detect-gpt-partition-table disk)
        (detect-mbr-partition-table disk)
        (detect-iso9660-partition-table disk))))

(defun check-gpt-header-signature (page-addr)
  (loop
     for i from 0
     for m in '(#x45 #x46 #x49 #x20 #x50 #x41 #x52 #x54)
     when (not (eql (sys.int::memref-unsigned-byte-8 (+ page-addr i) 0) m))
     do (return nil)
     finally (return t)))

(defun gpt-crc32 (base n-bytes &optional zero-offset zero-length)
  (let ((crc #xffffffff)
        (zero-end (and zero-offset (+ zero-offset zero-length))))
    (dotimes (i n-bytes (logxor crc #xffffffff))
      (let ((octet (if (and zero-offset (<= zero-offset i) (< i zero-end))
                       0
                       (sys.int::memref-unsigned-byte-8 (+ base i)))))
        (setf crc (logxor crc octet))
        (dotimes (bit 8)
          (declare (ignore bit))
          (setf crc (if (logbitp 0 crc)
                        (logxor (ash crc -1) #xedb88320)
                        (ash crc -1))))))))

(defun read-gpt-sectors (disk lba n-sectors buffer)
  (let* ((sector-size (disk-sector-size disk))
         (max-transfer (disk-max-transfer disk))
         (transfer-limit (if (and max-transfer (plusp max-transfer))
                             max-transfer
                             n-sectors)))
    (loop with remaining = n-sectors
          with sector = lba
          with address = buffer
          while (plusp remaining)
          for count = (min remaining transfer-limit)
          do (when (not (disk-read disk sector count address))
               (return nil))
             (incf sector count)
             (incf address (* count sector-size))
             (decf remaining count)
          finally (return t))))

(defun gpt-guid-present-p (base)
  (dotimes (i 16 nil)
    (when (not (zerop (sys.int::memref-unsigned-byte-8 (+ base i))))
      (return t))))

(defun gpt-entry-system-id (base)
  (dotimes (i 16 nil)
    (let ((system-id (sys.int::memref-unsigned-byte-8 (+ base i))))
      (when (not (zerop system-id))
        (return system-id)))))

(defun valid-gpt-entry-size-p (entry-size)
  (when (and (>= entry-size 128)
             (zerop (mod entry-size 128)))
    (let ((multiple (truncate entry-size 128)))
      (zerop (logand multiple (1- multiple))))))

(defun gpt-partition-overlap-p (first-lba last-lba partitions)
  (some (lambda (partition)
          (let ((other-first (third partition))
                (other-last (fourth partition)))
            (not (or (< last-lba other-first)
                     (> first-lba other-last)))))
        partitions))

(defun collect-gpt-partitions (buffer num-entries entry-size first-usable last-usable)
  (let ((partitions '()))
    (dotimes (i num-entries (values (nreverse partitions) t))
      (let* ((base (+ buffer (* i entry-size)))
             (system-id (gpt-entry-system-id base)))
        (when system-id
          (let ((first-lba (memref-ub64/le (+ base #x20)))
                (last-lba (memref-ub64/le (+ base #x28))))
            (when (or (not (gpt-guid-present-p (+ base #x10)))
                      (< first-lba first-usable)
                      (> first-lba last-lba)
                      (> last-lba last-usable)
                      (gpt-partition-overlap-p
                       first-lba last-lba partitions))
              (return-from collect-gpt-partitions (values nil nil)))
            (push (list i system-id first-lba last-lba) partitions)))))))

(defun process-gpt-partition-table-entry (disk descriptor)
  (destructuring-bind (i system-id first-lba last-lba) descriptor
    (let ((size (1+ (- last-lba first-lba))))
      (debug-print-line "Detected partition " i " on disk " disk
                        ". Start: " first-lba " size: " size)
      (register-disk (%make-partition disk first-lba i system-id)
                     (disk-writable-p disk)
                     size
                     (disk-sector-size disk)
                     (disk-max-transfer disk)
                     #'read-disk-partition
                     #'write-disk-partition
                     #'flush-disk-partition
                     nil))))

(defun process-gpt-header (disk header-buffer header-lba)
  (when (not (check-gpt-header-signature header-buffer))
    (return-from process-gpt-header nil))
  (let* ((sector-size (disk-sector-size disk))
         (n-sectors (disk-n-sectors disk))
         (primaryp (eql header-lba 1))
         (revision (memref-ub32/le (+ header-buffer #x08)))
         (header-size (memref-ub32/le (+ header-buffer #x0c)))
         (header-crc (memref-ub32/le (+ header-buffer #x10)))
         (reserved (memref-ub32/le (+ header-buffer #x14)))
         (current-lba (memref-ub64/le (+ header-buffer #x18)))
         (backup-lba (memref-ub64/le (+ header-buffer #x20)))
         (first-usable (memref-ub64/le (+ header-buffer #x28)))
         (last-usable (memref-ub64/le (+ header-buffer #x30)))
         (table-lba (memref-ub64/le (+ header-buffer #x48)))
         (num-entries (memref-ub32/le (+ header-buffer #x50)))
         (entry-size (memref-ub32/le (+ header-buffer #x54)))
         (table-crc (memref-ub32/le (+ header-buffer #x58)))
         (table-bytes (* num-entries entry-size))
         (table-sectors (ceiling table-bytes sector-size))
         (table-end (+ table-lba table-sectors)))
    (when (or (not (eql revision #x00010000))
              (< header-size 92)
              (> header-size sector-size)
              (not (zerop reserved))
              (not (gpt-guid-present-p (+ header-buffer #x38)))
              (not (eql current-lba header-lba))
              (not (eql backup-lba (if primaryp (1- n-sectors) 1)))
              (> first-usable last-usable)
              (>= last-usable (1- n-sectors))
              (zerop num-entries)
              (not (valid-gpt-entry-size-p entry-size))
              (not (typep table-bytes 'fixnum))
              (zerop table-sectors)
              (>= table-lba n-sectors)
              (> table-end n-sectors)
              (if primaryp
                  (or (< table-lba 2)
                      (> table-end first-usable))
                  (or (<= table-lba last-usable)
                      (> table-end header-lba)))
              (not (eql header-crc
                        (gpt-crc32 header-buffer header-size #x10 4))))
      (return-from process-gpt-header nil))
    (with-pages (table-buffer (ceiling table-bytes +4k-page-size+))
      (when (not table-buffer)
        (return-from process-gpt-header nil))
      (when (not (read-gpt-sectors disk table-lba table-sectors table-buffer))
        (return-from process-gpt-header nil))
      (when (not (eql table-crc (gpt-crc32 table-buffer table-bytes)))
        (return-from process-gpt-header nil))
      (multiple-value-bind (partitions validp)
          (collect-gpt-partitions table-buffer num-entries entry-size
                                  first-usable last-usable)
        (when (not validp)
          (return-from process-gpt-header nil))
        (debug-print-line "Detected " (if primaryp "primary" "backup")
                          " GPT on disk " disk)
        (dolist (partition partitions)
          (process-gpt-partition-table-entry disk partition))
        t))))

(defun detect-gpt-partition-table (disk)
  (debug-uart-boot-line "TRACE gpt-enter")
  (let* ((sector-size (disk-sector-size disk))
         (pages-per-sector (ceiling sector-size +4k-page-size+))
         (n-sectors (disk-n-sectors disk)))
    (when (or (< sector-size 512) (< n-sectors 2))
      (return-from detect-gpt-partition-table nil))
    (with-pages (header-buffer pages-per-sector
                               :mandatory-p "DETECT-DISK disk buffer")
      ;; The primary header is at LBA 1. If it or its entry array fails
      ;; validation, retry using the standard backup header at the final LBA.
      (debug-uart-boot-line "TRACE gpt-read-primary")
      (when (not (disk-read disk 1 1 header-buffer))
        (panic "Unable to read second block on disk " disk))
      (debug-uart-boot-line "TRACE gpt-read-primary-done")
      (or (progn
            (debug-uart-boot-line "TRACE gpt-process-primary")
            (process-gpt-header disk header-buffer 1))
          (let ((backup-lba (1- n-sectors)))
            (debug-uart-boot-line "TRACE gpt-read-backup")
            ;; Keep the trace out of the AND chain.  DEBUG-UART-BOOT-LINE
            ;; returns NIL, so as a conjunct it made backup-GPT recovery
            ;; always fail.
            (and (disk-read disk backup-lba 1 header-buffer)
                 (progn
                   (debug-uart-boot-line "TRACE gpt-read-backup-done")
                   (process-gpt-header disk header-buffer backup-lba))))))))

(defun decode-ebr (page-addr)
  (if (and (eql (sys.int::memref-unsigned-byte-8 page-addr #x1FE) #x55)
           (eql (sys.int::memref-unsigned-byte-8 page-addr #x1FF) #xAA))
    (values (sys.int::memref-unsigned-byte-8 (+ page-addr #x1BE) 4)
            (memref-ub32/le (+ page-addr #x1BE 8))
            (memref-ub32/le (+ page-addr #x1BE 12))
            (memref-ub32/le (+ page-addr #x1CE 8)))
    (values 0 0 0 0)))

(defun detect-mbr-partition-table (disk)
  (debug-uart-boot-line "TRACE mbr-enter")
  (let* ((sector-size (disk-sector-size disk))
         (pages-per-sector (ceiling sector-size +4k-page-size+))
         (found-table-p nil)
         (ebr-lba nil))
    (with-pages (page-addr pages-per-sector
                           :mandatory-p "DETECT-DISK disk buffer")
      (when (not (disk-read disk 0 1 page-addr))
        (panic "Unable to read first block on disk " disk))
      (when (and (>= sector-size 512)
                 (eql (sys.int::memref-unsigned-byte-8 page-addr #x1FE) #x55)
                 (eql (sys.int::memref-unsigned-byte-8 page-addr #x1FF) #xAA))
        ;; Found, scan partitions.
        (setf found-table-p t)
        (debug-print-line "Detected MBR style parition table on disk " disk)
        (dotimes (i 4)
          (let ((part-type (sys.int::memref-unsigned-byte-8 (+ page-addr #x1BE (* 16 i) 4)))
                (start-lba (memref-ub32/le (+ page-addr #x1BE (* 16 i) 8)))
                (size (memref-ub32/le (+ page-addr #x1BE (* 16 i) 12))))
            (when (and (not (eql part-type 0))
                       (not (eql size 0))
                       (not (eql part-type #xee)))
              (debug-print-line "Detected partition " i " on disk " disk ". Start: " start-lba " size: " size)
              (register-disk (%make-partition disk start-lba i part-type)
                             (disk-writable-p disk)
                             size
                             sector-size
                             (disk-max-transfer disk)
                             #'read-disk-partition
                             #'write-disk-partition
                             #'flush-disk-partition
                             nil)
              (when (or (eql part-type #x05) (eql part-type #x0F))
                (setf ebr-lba start-lba)))))
        ;; Handle extended partition documentation at:
        ;; https://thestarman.pcministry.com/asm/mbr/PartTables.htm
        (when ebr-lba
          (when (not (disk-read disk ebr-lba 1 page-addr))
            ;; What do to with this error?
            )
          (loop with part-type and data-offset and size and ebr-offset
             with part-num = 4
             do (setf (values part-type data-offset size ebr-offset)
                      (decode-ebr page-addr))
             unless (or (eql data-offset 0)
                        (eql size 0))
             do
               (progn
                 (debug-print-line "Extended partition " part-num
                                   " on disk " disk
                                   ". Type: " part-type
                                   " start: " (+ ebr-lba data-offset)
                                   " size: " size)
                 (register-disk (%make-partition disk (+ ebr-lba data-offset)
                                                 part-num part-type)
                                (disk-writable-p disk)
                                size
                                sector-size
                                (disk-max-transfer disk)
                                #'read-disk-partition
                                #'write-disk-partition
                                #'flush-disk-partition
                                nil)
                 (incf part-num))
             if (eql ebr-offset 0)
             do (return nil)
             else do
               (progn
                 (setf ebr-lba (+ ebr-lba ebr-offset))
                 (when (not (disk-read disk ebr-lba 1 page-addr))
                   ;; what to do with this error?
                   )))))
      found-table-p)))

(defun find-iso9660-primary-volume-descriptor (disk buffer)
  (loop
     ;; The Volume Descriptor Set starts on sector 16/offset 32kb.
     ;; Limit to searching the first 128 entries.
     for sector from #x10 below (+ #x10 128)
     do
       (when (not (disk-read disk sector 1 buffer))
         (return nil))
       ;; Check identifier 'CD001' and version
       (when (not (and (eql (sys.int::memref-unsigned-byte-8 buffer 1) #x43)
                       (eql (sys.int::memref-unsigned-byte-8 buffer 2) #x44)
                       (eql (sys.int::memref-unsigned-byte-8 buffer 3) #x30)
                       (eql (sys.int::memref-unsigned-byte-8 buffer 4) #x30)
                       (eql (sys.int::memref-unsigned-byte-8 buffer 5) #x31)
                       (eql (sys.int::memref-unsigned-byte-8 buffer 6) #x01)))
         (return nil))
       ;; Check type.
       (case (sys.int::memref-unsigned-byte-8 buffer 0)
         (#x01 ; Primary Volume Descriptor.
          (return sector))
         (#xFF ; Volume Descriptor Set Terminator.
          (return nil)))))

(defun detect-iso9660-partition-table (disk)
  (debug-uart-boot-line "TRACE iso-enter")
  (let* ((sector-size (disk-sector-size disk))
         (pages-per-sector (ceiling sector-size +4k-page-size+)))
    (when (not (eql sector-size 2048))
      (return-from detect-iso9660-partition-table nil))
    (with-pages (page-addr pages-per-sector
                           :mandatory-p "DETECT-DISK disk buffer")
      ;; Search for a primary volume descriptor.
      (let ((primary-volume (find-iso9660-primary-volume-descriptor disk page-addr)))
        (when (not primary-volume)
          (return-from detect-iso9660-partition-table nil))
        (debug-print-line "Detected ISO9660 primary volume descriptor at sector " primary-volume " on disk " disk)
        ;; Treat every file in the root directory as a partition.
        (let ((root-extent (memref-ub32/le (+ page-addr 156 2)))
              (root-length (memref-ub32/le (+ page-addr 156 10)))
              (n-entries 0))
          (debug-print-line "Root directory at " root-extent "/" root-length)
          (loop
             for sector from 0 below (ceiling root-length 2048)
             do
               (when (not (disk-read disk (+ root-extent sector) 1 page-addr))
                 (return nil))
               (do ((offset 0))
                   ((>= offset 2048))
                 (let ((rec-len (sys.int::memref-unsigned-byte-8 (+ page-addr offset 0)))
                       (extent (memref-ub32/le (+ page-addr offset 2)))
                       (length (memref-ub32/le (+ page-addr offset 10)))
                       (flags (sys.int::memref-unsigned-byte-8 (+ page-addr offset 25))))
                   (when (zerop rec-len)
                     ;; Reached last record.
                     (return))
                   (debug-print-line "Root entry at " extent "/" length " flags: " flags)
                   (when (eql (logand flags #b11101111) #b00000000) ; Ignore the protection bit.
                     ;; Valid file.
                     (register-disk (%make-partition disk extent (incf n-entries) nil)
                                    nil
                                    (ceiling length 2048)
                                    2048
                                    (disk-max-transfer disk)
                                    #'read-disk-partition
                                    #'write-disk-partition
                                    #'flush-disk-partition
                                    nil))
                   (incf offset rec-len)))))))))
