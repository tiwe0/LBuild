;;;; Whole-system transparent persistence support.

(in-package :mezzano.supervisor)


(sys.int::defglobal *snapshot-in-progress* nil)
(sys.int::defglobal *snapshot-state*)
(sys.int::defglobal *snapshot-inhibit*)

(sys.int::defglobal *snapshot-disk-request*)
(sys.int::defglobal *snapshot-bounce-buffer-page*)
(sys.int::defglobal *snapshot-pending-writeback-pages-count*)
(sys.int::defglobal *snapshot-pending-writeback-pages*)

(sys.int::defglobal *enable-snapshot-cow-fast-path* nil)

(sys.int::defglobal *snapshot-epoch*)
(sys.int::defglobal *snapshot-next-epoch*)

(defconstant +snapshot-minimum-wired-free-bytes+ (* 64 1024))
(defconstant +snapshot-large-backing-page-count+ 512)

(declaim (inline %fast-page-copy))
(defun %fast-page-copy (destination source)
  (sys.int::%copy-words destination source 512))

(defun snapshot-add-to-writeback-list (frame)
  ;; Link frame into writeback list.
  (cond (*snapshot-pending-writeback-pages*
         (setf (physical-page-frame-prev *snapshot-pending-writeback-pages*) frame
               (physical-page-frame-next frame) *snapshot-pending-writeback-pages*
               (physical-page-frame-prev frame) nil
               *snapshot-pending-writeback-pages* frame))
        (t
         (setf *snapshot-pending-writeback-pages* frame
               (physical-page-frame-next frame) nil
               (physical-page-frame-prev frame) nil)))
  (incf *snapshot-pending-writeback-pages-count*))

(defun snapshot-add-writeback-frame (frame)
  (ensure (eql (physical-page-frame-type frame) :active)
          "Tried to writeback non-active frame of type " (physical-page-frame-type frame))
  (let* ((address (physical-page-virtual-address frame))
         (bme-addr (or (block-info-for-virtual-address-1 address nil)
                       (panic "No block map entry for page " address)))
         (bme (sys.int::memref-unsigned-byte-64 bme-addr 0)))
    #+(or)(debug-print-line "Add writeback frame " frame ":" address " " bme)
    ;; Commit if needed.
    (when (not (logtest bme sys.int::+block-map-committed+))
      (let ((new-block (or (store-alloc 1)
                           (panic "Aiiee, out of store during writeback page commit.")))
            (old-block (ash bme (- sys.int::+block-map-id-shift+))))
        #+(or)(debug-print-line "  committing " old-block " " new-block)
        (setf bme (logior (ash new-block sys.int::+block-map-id-shift+)
                          sys.int::+block-map-committed+
                          (logand bme #xFF))
              (sys.int::memref-unsigned-byte-64 bme-addr 0) bme)
        #+(or)(debug-print-line "Replace old block " old-block " with " new-block " vaddr " candidate-virtual)
        (decf *store-fudge-factor*)
        (store-deferred-free old-block 1)
        #+(or)(debug-print-line "Old block: " old-block "  new-block: " new-block)))
    ;; Set block number.
    (setf (physical-page-frame-block-id frame) (ash bme (- sys.int::+block-map-id-shift+)))
    (setf (physical-page-frame-type frame) :active-writeback)
    (remove-from-page-replacement-list frame)
    (snapshot-add-to-writeback-list frame)))

(defun map-snapshot-wired-pages (function)
  "Call FUNCTION for each mapped page that is persisted in a snapshot."
  (map-ptes sys.int::*wired-area-base* sys.int::*wired-area-bump* function)
  (map-ptes sys.int::+card-table-base+
            (+ sys.int::+card-table-base+ sys.int::+card-table-size+)
            function
            :sparse t)
  (map-ptes sys.int::*wired-function-area-limit*
            sys.int::*function-area-base*
            function))

(defun snapshot-wired-dirty-tracking-p ()
  ;; ARM64 maps wired pages writable and does not yet emulate subsequent dirty
  ;; transitions, so conservatively copy them on every snapshot there.
  #-arm64 t
  #+arm64 nil)

(defun snapshot-wired-page-needs-copy-p (pte
                                         &optional
                                           (dirty-tracking-p
                                             (snapshot-wired-dirty-tracking-p)))
  (and (page-present-p pte 0)
       (or (not dirty-tracking-p)
           (page-dirty-p pte))))

(defun snapshot-copy-wired-area ()
  ;; Walk through each wired page and allocate a new block for it.
  (ensure (world-stopped-p)
          "SNAPSHOT-COPY-WIRED-AREA requires all other CPUs quiesced.")
  (map-snapshot-wired-pages
   (dx-lambda (wired-page pte)
     (when (not pte)
       (panic "No page table entry for wired-page " wired-page))
     (when (snapshot-wired-page-needs-copy-p pte)
       (let* ((page-frame
                (ash (pte-physical-address
                      (sys.int::memref-unsigned-byte-64 pte 0))
                     -12))
              (backing-frame (physical-page-frame-next page-frame))
              (bme-addr (or (block-info-for-virtual-address-1 wired-page nil)
                            (panic "No block map entry for wired-page " wired-page)))
              (bme (sys.int::memref-unsigned-byte-64 bme-addr 0))
              (new-block (or (store-alloc 1)
                             (panic "Aiiee, out of store when copying wired area!")))
              (old-block (ash bme (- sys.int::+block-map-id-shift+))))
         (setf (physical-page-frame-block-id backing-frame) new-block
               (physical-page-frame-type backing-frame) :wired-backing-writeback
               bme (logior (ash new-block sys.int::+block-map-id-shift+)
                           sys.int::+block-map-committed+
                           (logand bme #xFF))
               (sys.int::memref-unsigned-byte-64 bme-addr 0) bme)
         (decf *store-fudge-factor*)
         (store-deferred-free old-block 1)))))
  ;; Copy without interrupts to avoid smearing.
  (without-interrupts
    (when (snapshot-wired-dirty-tracking-p)
      (begin-tlb-shootdown))
    (map-snapshot-wired-pages
     (dx-lambda (wired-page pte)
       (when (not pte)
         (panic "No page table entry for " wired-page))
       (when (page-present-p pte)
         (let* ((page-frame
                  (ash (pte-physical-address
                        (sys.int::memref-unsigned-byte-64 pte 0))
                       -12))
                (other-frame (physical-page-frame-next page-frame)))
           (when (eql (physical-page-frame-type other-frame)
                      :wired-backing-writeback)
             (%fast-page-copy (convert-to-pmap-address (ash other-frame 12))
                              wired-page)
             (snapshot-add-to-writeback-list other-frame)
             (when (snapshot-wired-dirty-tracking-p)
               (%update-pte pte nil nil nil t)))))))
    (when (snapshot-wired-dirty-tracking-p)
      (flush-tlb)
      (tlb-shootdown-all)
      (finish-tlb-shootdown))))

(defun snapshot-clone-cow-page (new-frame fault-addr)
  (let* ((pte (or (get-pte-for-address fault-addr nil)
                  (panic "No PTE for CoW address?" fault-addr)))
         (block-info (or (block-info-for-virtual-address fault-addr)
                         (panic "No block info for CoW address?" fault-addr)))
         (old-frame (ash (pte-physical-address (sys.int::memref-unsigned-byte-64 pte 0)) -12)))
    (ensure (page-copy-on-write-p pte)
            "Copying non-CoW page?")
    (%fast-page-copy (convert-to-pmap-address (ash new-frame 12))
                     (logand fault-addr (lognot #xFFF)))
    (setf (physical-page-frame-block-id new-frame) (physical-page-frame-block-id old-frame)
          (physical-page-virtual-address new-frame) (physical-page-virtual-address old-frame))
    (setf (physical-page-frame-type new-frame) :active
          (physical-page-frame-type old-frame) :inactive-writeback)
    (append-to-page-replacement-list new-frame)
    ;; Point the PTE at the new page, disable copy on write and reenable write access.
    (begin-tlb-shootdown)
    (setf (sys.int::memref-unsigned-byte-64 pte 0)
          (%make-pte new-frame
                     (and (block-info-writable-p block-info)
                          (not (block-info-track-dirty-p block-info)))
                     t nil nil nil nil :normal))
    (flush-tlb-single fault-addr)
    (tlb-shootdown-single fault-addr)
    (finish-tlb-shootdown)
    #+(or)(debug-print-line "Copied page " fault-addr)))

(defun snapshot-clone-cow-page-via-page-fault (interrupt-frame fault-addr)
  (cond (*enable-snapshot-cow-fast-path*
         ;; Doesn't work on SMP, due to issues with TLB shootdown.
         (let ((new-frame (allocate-physical-pages 1)))
           (when (not new-frame)
             ;; No memory. Punt to the pager, does not return.
             (wait-for-page-via-interrupt interrupt-frame fault-addr))
           (snapshot-clone-cow-page new-frame fault-addr)))
        (t
         (wait-for-page-via-interrupt interrupt-frame fault-addr))))

(defun pop-pending-snapshot-page ()
  "Pop the next pending snapshot page.
Returns 4 values:
  FRAME - the frame id of the page. This frame is not in-use, and will either be
          a copied CoW frame, a wired backing frame, or the snapshot bounce buffer page.
  FREEP - True if FRAME should be freed after it has been written back.
  BLOCK-ID - ID of the block to write to. This will always be a valid block, not a deferred block.
  ADDRESS - Virtual address of the page to write back."
  (with-rw-lock-write (*vm-lock*)
    (begin-tlb-shootdown)
    (multiple-value-bind (frame freep block-id address)
        (pop-pending-snapshot-page-1)
      (tlb-shootdown-single address)
      (finish-tlb-shootdown)
      (values frame freep block-id address))))

(defun pop-pending-snapshot-page-1 ()
  (without-interrupts
    (let* ((frame *snapshot-pending-writeback-pages*)
           (address (physical-page-virtual-address frame))
           (block-id (physical-page-frame-block-id frame)))
      ;; Remove frame from list.
      (setf *snapshot-pending-writeback-pages* (physical-page-frame-next frame))
      (when *snapshot-pending-writeback-pages*
        (setf (physical-page-frame-prev *snapshot-pending-writeback-pages*) nil))
      (decf *snapshot-pending-writeback-pages-count*)
      (case (physical-page-frame-type frame)
        (:active-writeback
         ;; Page is mapped in memory.
         ;; Copy to the bounce buffer.
         (%fast-page-copy (convert-to-pmap-address (ash *snapshot-bounce-buffer-page* 12))
                          (convert-to-pmap-address (ash frame 12)))
         ;; Allow access to the page again.
         (let* ((pte (or (get-pte-for-address address nil)
                         (panic "No PTE for CoW address?")))
                (frame (ash (pte-physical-address (sys.int::memref-unsigned-byte-64 pte 0)) -12))
                ;; The block map should only be consulted for active pages.
                ;; Other kinds of pages indicate that the virtual memory was modified
                ;; and the page may no longer exist in the most recent block map.
                (block-info (or (block-info-for-virtual-address address)
                                (panic "No block info for CoW address?" address))))
           ;; Update PTE bits. Clear CoW bit, make writable.
           (setf (sys.int::memref-unsigned-byte-64 pte 0)
                 (%make-pte frame
                            (and (block-info-writable-p block-info)
                                 (not (block-info-track-dirty-p block-info)))
                            t nil nil (page-dirty-p pte) nil :normal))
           (flush-tlb-single address))
         ;; Return page to normal use.
         (setf (physical-page-frame-type frame) :active)
         (append-to-page-replacement-list frame)
         (values *snapshot-bounce-buffer-page*
                 ;; Don't free the bounce page.
                 nil
                 block-id
                 address))
        (:inactive-writeback
         ;; Page was copied.
         (values frame
                 t
                 block-id
                 address))
        (:wired-backing-writeback
         ;; Page is a wired backing page.
         ;; Copy to the bounce buffer.
         ;; Page may be freed during writeback if VM is modified.
         (%fast-page-copy (convert-to-pmap-address (ash *snapshot-bounce-buffer-page* 12))
                          (convert-to-pmap-address (ash frame 12)))
         ;; Return page to normal use.
         (setf (physical-page-frame-type frame) :wired-backing)
         (values *snapshot-bounce-buffer-page*
                 nil
                 block-id
                 address))
        (t (panic "Frame " frame " for address " address " has non-writeback type "
                  (physical-page-frame-type frame)))))))

(defun snapshot-write-back-pages ()
  ;; Write dirty/copied pages back.
  (let ((n 0))
    (loop
       (when (eql n 0)
         (setf n 100)
         (debug-print-line *snapshot-pending-writeback-pages-count* " dirty pages to write back"))
       (decf n)
       (when (not *snapshot-pending-writeback-pages*) (return))
       (multiple-value-bind (frame freep block-id address)
           (pop-pending-snapshot-page)
         (declare (ignorable address))
         #+(or)(debug-print-line "Writing back page " frame "/" block-id "/" address)
         (or (snapshot-write-disk block-id (convert-to-pmap-address (ash frame 12)))
             (panic "Unable to write page to disk!"))
         (when freep
           (release-physical-pages frame 1))))))

(defun snapshot-write-disk (block data)
  (disk-submit-request *snapshot-disk-request*
                       *paging-disk*
                       :write
                       (* block
                          (ceiling +4k-page-size+ (disk-sector-size *paging-disk*)))
                       (ceiling +4k-page-size+ (disk-sector-size *paging-disk*))
                       data)
  (unless (disk-await-request *snapshot-disk-request*)
    (panic "Unable to write snapshot block " block))
  t)

(defun snapshot-freelist ()
  (values (regenerate-store-freelist)
          (prog1 *store-deferred-freelist-head*
            (setf *store-deferred-freelist-head* '()))))

(defun snapshot-bml1 (bml1 address-part)
  (let ((bml1-disk (or (store-alloc 1)
                       (panic "Unable to allocate disk space for new block map.")))
        ;; Update the bottom level of the block map in-place.
        (bml1-memory bml1)
        (bml1-count 0)
        (next-address-part (ash address-part 9)))
    (dotimes (i 512)
      (let ((entry (sys.int::memref-unsigned-byte-64 bml1 i))
            (address (* (logior next-address-part i) +4k-page-size+)))
        (when (not (zerop entry))
          ;; Allocate any lazy blocks.
          (when (block-info-lazy-block-p entry)
            (ensure (block-info-committed-p entry) "Uncommitted lazy block.")
            (let ((new-block (or (store-alloc 1)
                                 (panic "Unable to allocate lazy block!"))))
              (decf *store-fudge-factor*)
              (let ((pte (get-pte-for-address address nil)))
                (when (and pte
                           (page-present-p pte 0))
                  (setf (physical-page-frame-block-id (ash (pte-physical-address (page-table-entry pte 0)) -12)) new-block)))
              (setf entry (logior (ash new-block sys.int::+block-map-id-shift+)
                                  (logand entry sys.int::+block-map-flag-mask+))
                    (sys.int::memref-unsigned-byte-64 bml1 i) entry)))
          ;; Uncommit any committed pages.
          (when (block-info-committed-p entry)
            (setf (sys.int::memref-unsigned-byte-64 bml1 i) (logand entry (lognot sys.int::+block-map-committed+)))
            (incf *store-fudge-factor*))
          (incf bml1-count))))
    (cond ((zerop bml1-count)
           ;; No entries, don't bother with this level.
           (store-free bml1-disk 1)
           nil)
          (t (snapshot-write-disk bml1-disk bml1-memory)
             (ash bml1-disk sys.int::+block-map-id-shift+)))))

(defun snapshot-block-map-outer-level (bml next-fn address-part)
  (let ((bml-disk (or (store-alloc 1)
                      (panic "Unable to allocate disk space for new block map.")))
        (bml-memory (convert-to-pmap-address (* (%pager-allocate-page :other) +4k-page-size+)))
        (bml-count 0)
        (next-address-part (ash address-part 9)))
    (dotimes (i 512)
      (let* ((entry (sys.int::memref-signed-byte-64 bml i))
             (disk-entry (if (zerop entry)
                             nil
                             (funcall next-fn entry (logior next-address-part i)))))
        (cond (disk-entry
               (setf (sys.int::memref-signed-byte-64 bml-memory i) disk-entry)
               (incf bml-count))
              (t
               (setf (sys.int::memref-signed-byte-64 bml-memory i) 0)))))
    (prog1
        (cond ((zerop bml-count)
               ;; No entries, don't bother with this level.
               (store-free bml-disk 1)
               nil)
              (t (snapshot-write-disk bml-disk bml-memory)
                 (ash bml-disk sys.int::+block-map-id-shift+)))
      (free-page bml-memory))))

(defun snapshot-bml2 (bml2 address-part)
  (snapshot-block-map-outer-level bml2 #'snapshot-bml1 address-part))

(defun snapshot-bml3 (bml3 address-part)
  (snapshot-block-map-outer-level bml3 #'snapshot-bml2 address-part))

(defun snapshot-bml4 (bml4)
  (snapshot-block-map-outer-level bml4 #'snapshot-bml3 0))

(defun snapshot-block-map ()
  (ash (snapshot-bml4 *bml4*) (- sys.int::+block-map-id-shift+)))

(defun snapshot-largest-wired-free-region ()
  "Return the size in bytes of the largest contiguous wired free region."
  (loop for bin across sys.int::*wired-area-free-bins*
        maximize
           (loop for entry = bin then (mezzano.runtime::freelist-entry-next entry)
                 while entry
                 maximize (* 8 (mezzano.runtime::freelist-entry-size entry))
                   into largest
                 finally (return largest))))

(defun ensure-snapshot-wired-reserve ()
  (let ((available (snapshot-largest-wired-free-region)))
    (ensure (>= available +snapshot-minimum-wired-free-bytes+)
            "Snapshot requires a contiguous 64KB wired boot reserve; largest region is "
            available " bytes.")))

(defun call-with-snapshot-vm-stable (critical-function stable-function)
  "Run both functions with the world stopped and *VM-LOCK* held for write.

STABLE-FUNCTION used to run after the world resumed, still holding *VM-LOCK*,
so that VM mutations stayed blocked while the on-disk block map and freelist
were written.  That deadlocks: CRITICAL-FUNCTION ends by marking every
non-wired page read-only and copy-on-write, so the first thing any resumed
thread does -- writing to its own stack -- takes a copy-on-write fault, and
the pager cannot service it while this thread holds *VM-LOCK*.  The snapshot
thread then blocks in turn on *ALLOCATOR-LOCK*, held by a thread already
waiting on the VM lock, and every thread ends up asleep.

Keeping STABLE-FUNCTION inside the world-stop preserves the property it was
written for -- no VM mutations while the block map and freelist are written --
and closes the fault window instead of opening it."
  (call-with-world-stopped
   (dx-lambda ()
     (rw-lock-write-acquire *vm-lock*)
     (unwind-protect
          (progn
            (funcall critical-function)
            ;; STORE-ALLOC asserts *VM-LOCK* is held, so STABLE-FUNCTION runs
            ;; under it.  Anything it touches must therefore already be
            ;; resident: a fault here cannot be serviced, because the pager
            ;; needs this very lock.  WAIT-FOR-PAGE-VIA-INTERRUPT panics on
            ;; that case rather than parking forever.
            (funcall stable-function))
       (rw-lock-write-release *vm-lock*)))))

(defun call-with-snapshot-disk-block (block-id function)
  (let ((page nil))
    (unwind-protect
         (progn
           (setf page
                 (convert-to-pmap-address
                  (* (with-rw-lock-write (*vm-lock*)
                       (%pager-allocate-page :other))
                     +4k-page-size+)))
           (disk-submit-request
            *snapshot-disk-request*
            *paging-disk*
            :read
            (* block-id
               (ceiling +4k-page-size+ (disk-sector-size *paging-disk*)))
            (ceiling +4k-page-size+ (disk-sector-size *paging-disk*))
            page)
           (unless (disk-await-request *snapshot-disk-request*)
             (panic "Unable to read old snapshot metadata block " block-id))
           (funcall function page))
      (when page
        (free-page page)))))

(defun snapshot-free-metadata-block (block-id)
  (with-rw-lock-write (*vm-lock*)
    (store-free block-id 1)))

(defun snapshot-release-old-block-map (block-id level)
  "Release an obsolete on-disk block-map tree without freeing data blocks."
  (when (not (zerop block-id))
    (when (> level 1)
      (call-with-snapshot-disk-block
       block-id
       (dx-lambda (page)
         (dotimes (i 512)
           (let ((entry (sys.int::memref-unsigned-byte-64 page i)))
             (when (not (zerop entry))
               (snapshot-release-old-block-map
                (ash entry (- sys.int::+block-map-id-shift+))
                (1- level))))))))
    (snapshot-free-metadata-block block-id)))

(defun snapshot-release-old-freelist (block-id)
  "Release the obsolete on-disk freelist chain."
  (loop while (not (zerop block-id))
        do
           (let ((next-block nil))
             (call-with-snapshot-disk-block
              block-id
              (dx-lambda (page)
                (setf next-block
                      (sys.int::memref-unsigned-byte-64 page 511))))
             (snapshot-free-metadata-block block-id)
             (setf block-id next-block))))

(defun take-snapshot ()
  (when *paging-read-only*
    (debug-print-line "Not taking snapshot, running read-only.")
    (return-from take-snapshot))
  (set-snapshot-light t)
  (setf *snapshot-pending-writeback-pages* nil
        *snapshot-pending-writeback-pages-count* 0)
  (let ((freelist-block nil)
        (bml4-block nil)
        (old-freelist-block nil)
        (old-bml4-block nil)
        (header-committed-p nil)
        (previously-deferred-free-blocks nil))
    ;; Stop the world before taking *VM-LOCK*: PA threads may be waiting for
    ;; pages. Keep the VM lock after CPUs resume so slow disk I/O does not keep
    ;; unrelated threads stopped while the snapshot metadata remains stable.
    (call-with-snapshot-vm-stable
     (dx-lambda ()
       (when (not (zerop *snapshot-inhibit*))
         (set-snapshot-light nil)
         (return-from take-snapshot :retry))
       (ensure-snapshot-wired-reserve)
       ;; Raw UART inside the *VM-LOCK* region: DEBUG-PRINT-LINE formats
       ;; through the general allocator, and a fault taken there cannot be
       ;; serviced because the pager needs this same lock.
       (debug-uart-boot-line "Begin snapshot.")
       (debug-uart-boot-hex-line "deferred blocks"
                                 *store-freelist-n-deferred-free-blocks*)
       (debug-uart-boot-line "Copying wired area.")
       (snapshot-copy-wired-area)
       (debug-uart-boot-line "Marking dirty pages copy-on-write.")
       (snapshot-mark-cow-dirty-pages))
     (dx-lambda ()
       (debug-uart-boot-line "Updating block map.")
       (setf bml4-block (snapshot-block-map))
       (debug-uart-boot-line "Updating freelist.")
       (setf (values freelist-block previously-deferred-free-blocks)
             (snapshot-freelist))))
    (snapshot-write-back-pages)
    ;; Update the block map & freelist entries in the header.
    (debug-print-line "Updating disk header.")
    (let ((header nil))
      (unwind-protect
           (progn
             (setf header
                   (convert-to-pmap-address
                    (* (with-rw-lock-write (*vm-lock*)
                         (%pager-allocate-page :other))
                       +4k-page-size+)))
             (disk-submit-request
              *snapshot-disk-request*
              *paging-disk*
              :read
              0
              (ceiling +4k-page-size+ (disk-sector-size *paging-disk*))
              header)
             (unless (disk-await-request *snapshot-disk-request*)
               (panic "Unable to read header from disk"))
             (setf old-bml4-block
                   (sys.int::memref-unsigned-byte-64
                    (+ header +image-header-block-map+)
                    0)
                   old-freelist-block
                   (sys.int::memref-unsigned-byte-64
                    (+ header +image-header-freelist+)
                    0)
                   (sys.int::memref-unsigned-byte-64
                    (+ header +image-header-block-map+)
                    0)
                   bml4-block
                   (sys.int::memref-unsigned-byte-64
                    (+ header +image-header-freelist+)
                    0)
                   freelist-block)
             (snapshot-write-disk 0 header)
             (setf header-committed-p t))
        (when header
          (free-page header))))
    ;; The new header is durable before old metadata becomes reusable. The
    ;; released blocks are persisted in the next regenerated freelist.
    (when header-committed-p
      (unless (eql old-bml4-block bml4-block)
        (snapshot-release-old-block-map old-bml4-block 4))
      (unless (eql old-freelist-block freelist-block)
        (snapshot-release-old-freelist old-freelist-block)))
    (with-rw-lock-write (*vm-lock*)
      (store-release-deferred-blocks previously-deferred-free-blocks)))
  (set-snapshot-light nil)
  (debug-print-line "End snapshot."))

(defun current-snapshot-epoch ()
  "Return an event that identifies the current snapshot epoch.
This event will be signalled when the epoch changes."
  *snapshot-epoch*)

(defun snapshot-prepare-thread-for-sleep ()
  "Publish the snapshot thread's sleeping state before accepting new work."
  (setf (thread-state sys.int::*snapshot-thread*) :sleeping
        (thread-wait-item sys.int::*snapshot-thread*) "Snapshot"
        ;; This must be last: a successful request CAS may immediately try to
        ;; wake the thread on another CPU.
        *snapshot-in-progress* nil))

(defun snapshot-thread ()
  ;; A preallocated timer is required here because the snapshot thread
  ;; runs at :supervisor priority and must not cons outside of boot.
  (with-timer (snapshot-retry-timer)
    (loop
       ;; Retry occurs when *SNAPSHOT-INHIBIT* is non-zero.
       (loop
          while (or (not (eql *snapshot-inhibit* 0))
                    (eql (take-snapshot) :retry))
          do (timer-sleep snapshot-retry-timer 0.1))
       ;; Signal completion before publishing the sleeping state. A new request
       ;; cannot claim *SNAPSHOT-IN-PROGRESS* until the thread is already marked
       ;; sleeping under the global thread lock below.
       (setf (event-state *snapshot-state*) t)
       ;; Move to the next epoch.
       (setf (event-state *snapshot-epoch*) t)
       (setf *snapshot-epoch* *snapshot-next-epoch*)
       (%disable-interrupts)
       (acquire-global-thread-lock)
       (snapshot-prepare-thread-for-sleep)
       (%run-on-wired-stack-without-interrupts (sp fp)
         (%reschedule-via-wired-stack sp fp)))))

(defun snapshot-install-wired-backing-page (physical-frame virtual-page backing-frame)
  (setf (physical-page-frame-type backing-frame) :wired-backing
        (physical-page-frame-next physical-frame) backing-frame
        (physical-page-virtual-address backing-frame) virtual-page))

(defun snapshot-allocate-backing-for-pages (pages)
  "Allocate backing frames for a list of (PHYSICAL-FRAME . VIRTUAL-PAGE) pairs.
A complete, 2MB-aligned run is backed by one contiguous physical allocation so
the snapshot copy walks a single extent instead of 512 scattered frames.  The
dense attempt is not mandatory: a fragmented physical heap simply degrades to
per-page frames rather than failing the snapshot."
  (let ((large-frame
          (and (eql (length pages) +snapshot-large-backing-page-count+)
               (zerop (logand (cdr (first pages)) (1- (* 2 1024 1024))))
               ;; Positional entry point; the keyword one materializes an
               ;; argument vector, which is not safe this early in boot.
               (%allocate-physical-pages +snapshot-large-backing-page-count+
                                         :wired-backing nil nil))))
    (cond (large-frame
           (loop for page in pages
                 for frame from large-frame
                 do (snapshot-install-wired-backing-page
                     (car page) (cdr page) frame)))
          (t
           (dolist (page pages)
             (snapshot-install-wired-backing-page
              (car page)
              (cdr page)
              (%allocate-physical-pages 1 :wired-backing
                                        "wired backing pages" nil)))))))

(defun allocate-snapshot-wired-backing-pages-1 (start end sparse)
  ;; Same dense-first policy as SNAPSHOT-ALLOCATE-BACKING-FOR-PAGES, but driven
  ;; straight off the page tables instead of a materialized page list.
  ;;
  ;; Walk in 2MB chunks and make two passes over each: count the present pages,
  ;; then install their backing frames.  Counting needs no storage, so the whole
  ;; traversal allocates nothing but the backing frames themselves.  Building a
  ;; per-chunk list here instead stalls cold boot -- INITIALIZE-SNAPSHOT covers
  ;; the entire wired area, and consing through the general allocator at that
  ;; point re-enters the paging/GC machinery that is still coming up.
  (let ((chunk-size (* 2 1024 1024))
        (chunk-index 0))
    (loop for chunk-start from (align-down start chunk-size)
          below end by chunk-size
          for chunk-end = (min end (+ chunk-start chunk-size))
          do (incf chunk-index)
             (let ((range-start (max start chunk-start))
                   (page-count 0)
                   (large-frame nil)
                   (large-index 0)
                   (trace-chunk-p (or (= chunk-index 1)
                                      (zerop (logand chunk-index 31)))))
               (when trace-chunk-p
                 nil)
               ;; Pass 1: how many pages are present in this chunk?
               (map-ptes-1
                range-start chunk-end
                (dx-lambda (wired-page pte)
                  (when (not pte)
                    (panic "No page table entry for wired page " wired-page))
                  (when (page-present-p pte)
                    (incf page-count)))
                sparse)
               (when (plusp page-count)
                 ;; A complete, aligned chunk takes one contiguous run.  Not
                 ;; mandatory: a fragmented physical heap falls back below.
                 (setf large-frame
                       (and (eql page-count +snapshot-large-backing-page-count+)
                            (zerop (logand range-start (1- chunk-size)))
                            (%allocate-physical-pages
                             +snapshot-large-backing-page-count+
                             :wired-backing nil nil)))
                 (when trace-chunk-p
                   (if large-frame
                       nil))
                 ;; Pass 2: install a backing frame for each present page.
                 (map-ptes-1
                  range-start chunk-end
                  (dx-lambda (wired-page pte)
                    (when (page-present-p pte)
                      (snapshot-install-wired-backing-page
                       (ash (pte-physical-address
                             (sys.int::memref-unsigned-byte-64 pte 0))
                            -12)
                       wired-page
                       (cond (large-frame
                              (prog1 (+ large-frame large-index)
                                (incf large-index)))
                             (t
                              (%allocate-physical-pages
                               1 :wired-backing "wired backing pages" nil))))))
                  sparse))
               (when trace-chunk-p
                 nil)))))

;; Keep the early bootstrap path positional.  The keyword entry point can
;; allocate an argument vector before the normal allocator is live.
(defun allocate-snapshot-wired-backing-pages (start end &key sparse)
  (allocate-snapshot-wired-backing-pages-1 start end sparse))

(defun initialize-snapshot ()
  (when (not (boundp '*snapshot-state*))
    (setf *snapshot-state* (%make-event 'snapshot-not-in-progress nil)))
  (setf (event-state *snapshot-state*) nil)
  (cond ((boundp '*snapshot-epoch*)
         (setf (event-state *snapshot-epoch*) t)
         (setf *snapshot-epoch* *snapshot-next-epoch*))
  (t
         (setf *snapshot-epoch* (%make-event 'snapshot-epoch nil))))
  (setf *snapshot-disk-request* (make-disk-request t)
        (disk-request-latch *snapshot-disk-request*)
        (%make-event "Snapshot disk request notifier" nil))
  (setf *snapshot-in-progress* nil)
  (setf *snapshot-inhibit* 1)
  (setf *enable-snapshot-cow-fast-path* nil)
  ;; Allocate pages to copy the wired area into.
  (allocate-snapshot-wired-backing-pages-1
   sys.int::*wired-area-base* sys.int::*wired-area-bump* nil)
  (allocate-snapshot-wired-backing-pages-1
   sys.int::*wired-function-area-limit* sys.int::*function-area-base* nil)
  ;; MAP-PTES skips absent page-table branches for the mostly sparse card table.
  (allocate-snapshot-wired-backing-pages-1
   sys.int::+card-table-base+
   (+ sys.int::+card-table-base+ sys.int::+card-table-size+)
   t)
  ;; ### same here.
  (setf *snapshot-bounce-buffer-page*
        (%allocate-physical-pages 1 :other "snapshot bounce page" nil)))

(defun snapshot ()
  ;; Run a GC before snapshotting to reduce the amount of space required.
  (sys.int::gc :full t)
  (let* ((next-epoch (make-event :name 'snapshot-epoch))
         (did-wake (safe-without-interrupts (next-epoch)
                     (snapshot-claim-request next-epoch))))
    (when did-wake
      (thread-yield))))

(defun snapshot-claim-request (next-epoch)
  "Atomically claim the single pending snapshot slot across all CPUs."
  (let ((was-in-progress
          (sys.int::cas
           (sys.int::symbol-global-value '*snapshot-in-progress*)
           nil
           t)))
    (when (eql was-in-progress nil)
      (setf (event-state *snapshot-state*) nil
            *snapshot-next-epoch* next-epoch)
      (wake-thread sys.int::*snapshot-thread*)
      t)))

(defun wait-for-snapshot-completion ()
  "If a snapshot is currently being take, then wait for it to complete."
  (event-wait *snapshot-state*))

(defmacro with-snapshot-inhibited (options &body body)
  `(call-with-snapshot-inhibited (dx-lambda () ,@body) ,@options))

(defun snapshot-adjust-inhibit (delta)
  "Atomically adjust the SMP-wide snapshot inhibition nesting count."
  (let* ((old (sys.int::%atomic-fixnum-add-symbol '*snapshot-inhibit* delta))
         (new (+ old delta)))
    (when (minusp new)
      ;; Restore the count before reporting an unbalanced release.
      (sys.int::%atomic-fixnum-add-symbol '*snapshot-inhibit* (- delta))
      (panic "Unbalanced snapshot inhibition release."))
    new))

(defun call-with-snapshot-inhibited (fn)
  (snapshot-adjust-inhibit 1)
  (unwind-protect
       (funcall fn)
    (snapshot-adjust-inhibit -1)))
