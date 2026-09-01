;;;; Raw memory related primitives.

(in-package :mezzano.compiler.backend.arm64)

(defmacro with-memory-effective-address ((effective-address additional-inputs base-address index scale &key ldp/stp-address) &body body)
  "Generate an effective address that deals properly with scaling and constant indices."
  (check-type scale (member 1 2 4 8))
  (let ((unboxed-address (gensym "UNBOXED-ADDRESS"))
        (scaled-index (gensym "SCALED-INDEX")))
    `(let ((,unboxed-address (make-instance 'ir:virtual-register :kind :integer)))
       (emit (make-instance 'ir:unbox-fixnum-instruction
                            :source ,base-address
                            :destination ,unboxed-address))
       ;; LDR/STR accept an unsigned, transfer-size-scaled 12-bit offset in
       ;; addition to the signed 9-bit unscaled form.  Keep scale 1 on the
       ;; register path: the integer accessors use it for *unscaled* accesses
       ;; whose transfer width may be 2, 4, or 8 bytes, so alignment cannot be
       ;; inferred from SCALE alone.
       (cond ((and (constant-value-p ,index 'fixnum)
                   (let ((offset (* (fetch-constant-value ,index) ,scale)))
                     (if ,ldp/stp-address
                         ;; LDP/STP use a signed 7-bit immediate scaled by
                         ;; the pair width (8 bytes here).
                         (and (<= -512 offset 504)
                              (zerop (mod offset 8)))
                         (or (<= -256 offset 255)
                             (and (> ,scale 1)
                                  (<= 0 offset (* 4095 ,scale))
                                  (zerop (mod offset ,scale)))))))
              (let ((,effective-address (list ,unboxed-address (* (fetch-constant-value ,index) ,scale)))
                    (,additional-inputs (list ,unboxed-address)))
                ,@body))
             (t
              (with-scaled-fixnum-index (,scaled-index ,index ,scale)
                ,(if ldp/stp-address
                     ;; Need to add the base & index together for ldp/stp.
                     (let ((final-address (gensym "ADDRESS")))
                       `(let ((,final-address (make-instance 'ir:virtual-register :kind :integer)))
                          (emit (make-instance 'arm64-instruction
                                               :opcode 'lap:add
                                               :operands (list ,final-address ,unboxed-address ,scaled-index)
                                               :inputs (list ,unboxed-address ,scaled-index)
                                               :outputs (list ,final-address)))
                          (let ((,effective-address (list ,final-address))
                                (,additional-inputs (list ,final-address)))
                            ,@body)))
                     `(let ((,effective-address (list ,unboxed-address ,scaled-index))
                            (,additional-inputs (list ,unboxed-address ,scaled-index)))
                        ,@body))))))))

(define-builtin sys.int::%memref-t ((address index) result)
  (with-memory-effective-address (ea ea-inputs address index 8)
    (emit (make-instance 'arm64-instruction
                         :opcode 'lap:ldr
                         :operands (list result ea)
                         :inputs ea-inputs
                         :outputs (list result)))))

(define-builtin (setf sys.int::%memref-t) ((value address index) result)
  (with-memory-effective-address (ea ea-inputs address index 8)
    (emit (make-instance 'arm64-instruction
                         :opcode 'lap:str
                         :operands (list value ea)
                         :inputs (list* value ea-inputs)
                         :outputs (list))))
  (emit (make-instance 'ir:move-instruction
                       :source value
                       :destination result)))

(define-builtin sys.int::%memref-t-pair ((address index) (result-1 result-2))
  (with-memory-effective-address (ea ea-inputs address index 8 :ldp/stp-address t)
    (emit (make-instance 'arm64-instruction
                         :opcode 'lap:ldp
                         :operands (list result-1 result-2 ea)
                         :inputs ea-inputs
                         :outputs (list result-1 result-2)))))

(define-builtin sys.int::%set-memref-t-pair ((value-1 value-2 address index) (result-1 result-2))
  (with-memory-effective-address (ea ea-inputs address index 8 :ldp/stp-address t)
    (emit (make-instance 'arm64-instruction
                         :opcode 'lap:stp
                         :operands (list value-1 value-2 ea)
                         :inputs (list* value-1 value-2 ea-inputs)
                         :outputs (list))))
  (emit (make-instance 'ir:move-instruction
                       :source value-1
                       :destination result-1))
  (emit (make-instance 'ir:move-instruction
                       :source value-2
                       :destination result-2)))

;; CAS/DCAS for memref-t remain intentionally unsupported: the generic
;; compare-exchange IR models object-relative slots, while memref addresses are
;; raw effective addresses. Adding these operations requires dedicated IR/codegen
;; forms that carry arbitrary addresses and specify their memory-order contract
;; (including a 16-byte form for DCAS).
;;
;; Integer memref CAS below already lowers through ARM64 CASL instructions. The
;; lowering keeps old/new/current values in distinct virtual registers, so it is
;; SSA-safe and does not require the object-relative compare-exchange IR form.
(defmacro define-memref-integer-accessor (name read-op write-op cas-op scale box-op unbox-op)
  `(progn
     (define-builtin ,name ((address index) result)
       (let ((temp (make-instance 'ir:virtual-register :kind :integer)))
         (with-memory-effective-address (ea ea-inputs address index ,scale)
           (emit (make-instance 'arm64-instruction
                                :opcode ',read-op
                                :operands (list temp ea)
                                :inputs ea-inputs
                                :outputs (list temp))))
         (emit (make-instance ',box-op
                              :source temp
                              :destination result))))
     (define-builtin (setf ,name) ((value address index) result)
       (let ((temp (make-instance 'ir:virtual-register :kind :integer)))
         (emit (make-instance ',unbox-op
                              :source value
                              :destination temp))
         (with-memory-effective-address (ea ea-inputs address index ,scale)
           (emit (make-instance 'arm64-instruction
                                :opcode ',write-op
                                :operands (list temp ea)
                                :inputs (list* temp ea-inputs)
                                :outputs (list))))
         (emit (make-instance 'ir:move-instruction
                              :source value
                              :destination result))))
     (define-builtin (sys.int::cas ,name) ((old new address index) result)
       (let ((old-unboxed (make-instance 'ir:virtual-register :kind :integer))
             (new-unboxed (make-instance 'ir:virtual-register :kind :integer))
             (current-unboxed (make-instance 'ir:virtual-register :kind :integer))
             (address-unboxed (make-instance 'ir:virtual-register :kind :integer))
             (generated-address (make-instance 'ir:virtual-register :kind :integer)))
         (emit (make-instance ',unbox-op
                              :source old
                              :destination old-unboxed))
         (emit (make-instance ',unbox-op
                              :source new
                              :destination new-unboxed))
         (emit (make-instance 'ir:unbox-fixnum-instruction
                              :source address
                              :destination address-unboxed))
         (with-scaled-fixnum-index (scaled-index index ,scale)
           (emit (make-instance 'arm64-instruction
                                :opcode 'lap:add
                                :operands (list generated-address address-unboxed scaled-index)
                                :inputs (list address-unboxed scaled-index)
                                :outputs (list generated-address))))
         (emit (make-instance 'arm64-cas-mem-instruction
                              :opcode ',cas-op
                              :address generated-address
                              :old-value old-unboxed
                              :new-value new-unboxed
                              :current-value current-unboxed))
         (emit (make-instance ',box-op
                              :source current-unboxed
                              :destination result))))))

(define-memref-integer-accessor sys.int::%memref-unsigned-byte-8  lap:ldrb  lap:strb lap:casalb 1 ir:box-fixnum-instruction ir:unbox-fixnum-instruction)
(define-memref-integer-accessor sys.int::%memref-unsigned-byte-16 lap:ldrh  lap:strh lap:casalh 2 ir:box-fixnum-instruction ir:unbox-fixnum-instruction)
(define-memref-integer-accessor sys.int::%memref-unsigned-byte-32 lap:ldrw  lap:strw lap:casalw 4 ir:box-fixnum-instruction ir:unbox-fixnum-instruction)
(define-memref-integer-accessor sys.int::%memref-unsigned-byte-64 lap:ldr   lap:str  lap:casal  8 ir:box-unsigned-byte-64-instruction ir:unbox-unsigned-byte-64-instruction)

(define-memref-integer-accessor sys.int::%memref-signed-byte-8    lap:ldrsb lap:strb lap:casalb 1 ir:box-fixnum-instruction ir:unbox-fixnum-instruction)
(define-memref-integer-accessor sys.int::%memref-signed-byte-16   lap:ldrsh lap:strh lap:casalh 2 ir:box-fixnum-instruction ir:unbox-fixnum-instruction)
(define-memref-integer-accessor sys.int::%memref-signed-byte-32   lap:ldrsw lap:strw lap:casalw 4 ir:box-fixnum-instruction ir:unbox-fixnum-instruction)
(define-memref-integer-accessor sys.int::%memref-signed-byte-64   lap:ldr   lap:str  lap:casal   8 ir:box-signed-byte-64-instruction ir:unbox-signed-byte-64-instruction)

(define-memref-integer-accessor sys.int::%memref-unsigned-byte-8-unscaled  lap:ldrb  lap:strb lap:casalb 1 ir:box-fixnum-instruction ir:unbox-fixnum-instruction)
(define-memref-integer-accessor sys.int::%memref-unsigned-byte-16-unscaled lap:ldrh  lap:strh lap:casalh 1 ir:box-fixnum-instruction ir:unbox-fixnum-instruction)
(define-memref-integer-accessor sys.int::%memref-unsigned-byte-32-unscaled lap:ldrw  lap:strw lap:casalw 1 ir:box-fixnum-instruction ir:unbox-fixnum-instruction)
(define-memref-integer-accessor sys.int::%memref-unsigned-byte-64-unscaled lap:ldr   lap:str  lap:casal   1 ir:box-unsigned-byte-64-instruction ir:unbox-unsigned-byte-64-instruction)

(define-memref-integer-accessor sys.int::%memref-signed-byte-8-unscaled    lap:ldrsb lap:strb lap:casalb 1 ir:box-fixnum-instruction ir:unbox-fixnum-instruction)
(define-memref-integer-accessor sys.int::%memref-signed-byte-16-unscaled   lap:ldrsh lap:strh lap:casalh 1 ir:box-fixnum-instruction ir:unbox-fixnum-instruction)
(define-memref-integer-accessor sys.int::%memref-signed-byte-32-unscaled   lap:ldrsw lap:strw lap:casalw 1 ir:box-fixnum-instruction ir:unbox-fixnum-instruction)
(define-memref-integer-accessor sys.int::%memref-signed-byte-64-unscaled   lap:ldr   lap:str  lap:casal   1 ir:box-signed-byte-64-instruction ir:unbox-signed-byte-64-instruction)
