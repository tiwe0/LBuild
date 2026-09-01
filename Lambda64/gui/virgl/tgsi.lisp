;;;; TGSI shader assembler.

(in-package :mezzano.gui.virgl.tgsi)

(defun check-swizzle (swizzle)
  ;; This checks both swizzles and writemasks.
  (when (not swizzle)
    ;; This is a writemask that writes nothing.
    (return-from check-swizzle))
  (let ((name (symbol-name swizzle)))
    ;; Swizzles are 4 elements long, anything shorter is a writemask.
    (cond ((< (length name) 4)
           ;; Writemasks must have their elements in order.
           ;; :XYZ, not :XZY
           (loop
              with order = '(#\X #\Y #\Z #\W)
              for ch across name
              do
                (loop
                   (when (not order)
                     (error "Bad writemask ~S" swizzle))
                   (when (eql ch (pop order))
                     (return)))))
          (t
           (assert (eql (length name) 4))
           ;; Swizzles consist of XYZW in any order and duplication.
           (loop
              for ch across name
              when (not (member ch '(#\X #\Y #\Z #\W)))
              do (error "Bad swizzle ~S" swizzle))))))

(defun convert-opcode-name (opcode)
  (let ((name (symbol-name opcode)))
    (cond ((find #\- name)
           (substitute #\_ #\- name))
          (t name))))

(defparameter +declaration-semantics+
  '(:position :color :bcolor :fog :psize :generic :normal :face :edgeflag
    :prim-id :instanceid :vertexid :stencil :clipdist :clipvertex :grid-size
    :block-id :block-size :thread-id :texcoord :pcoord :viewport-index :layer
    :sampleid :samplepos :samplemask :invocationid :vertexid-nobase
    :basevertex :patch :tesscoord :tessouter :tessinner :verticesin
    :helper-invocation :baseinstance :drawid :work-dim :subgroup-size
    :subgroup-invocation :subgroup-eq-mask :subgroup-ge-mask :subgroup-gt-mask
    :subgroup-le-mask :subgroup-lt-mask :cs-user-data-amd :viewport-mask))

(defparameter +declaration-interpolations+
  '(:constant :linear :perspective :color))

(defparameter +declaration-interpolation-locations+
  '(:center :centroid :sample))

(defun parameterized-declaration-qualifier-p (thing name)
  (and (consp thing)
       (eql (first thing) name)
       (consp (rest thing))
       (null (cddr thing))))

(defun parse-declaration-qualifiers (processor file things)
  (let ((remaining things)
        (dimension nil)
        (array nil)
        (semantic nil)
        (interpolation nil)
        (location nil)
        (invariant nil))
    (when (parameterized-declaration-qualifier-p
           (first remaining) :dimension)
      (setf dimension (second (pop remaining)))
      (check-type dimension (unsigned-byte 32)))
    (when (parameterized-declaration-qualifier-p (first remaining) :array)
      (setf array (second (pop remaining)))
      ;; TGSI declaration ArrayID is an unsigned 32-bit field, just like
      ;; register and dimension indices.  A signed check would accept -1 and
      ;; emit invalid ARRAY(-1) text.
      (check-type array (unsigned-byte 32)))
    (when (and remaining
               (or (member (first remaining) +declaration-semantics+)
                   (and (consp (first remaining))
                        (member (first (first remaining))
                                +declaration-semantics+))))
      (setf semantic (pop remaining))
      (when (consp semantic)
        (unless (and (consp (rest semantic)) (null (cddr semantic)))
          (error "Malformed indexed declaration semantic ~S" semantic))
        (check-type (second semantic) (unsigned-byte 32))))
    (when (member (first remaining) +declaration-interpolations+)
      (setf interpolation (pop remaining)))
    (when (member (first remaining) +declaration-interpolation-locations+)
      (unless interpolation
        (error "Interpolation location ~S requires an interpolation mode"
               (first remaining)))
      (setf location (pop remaining)))
    (when (eql (first remaining) :invariant)
      (setf invariant (pop remaining)))
    (when remaining
      (error "Invalid or misplaced declaration qualifier ~S" (first remaining)))
    (when (and (eql processor :vertex)
               (eql file :in)
               (or semantic interpolation location invariant))
      (error "Vertex input declarations cannot have semantic or interpolation qualifiers"))
    (values dimension array semantic interpolation location invariant)))

(defun write-declaration-semantic (semantic stream)
  (cond ((consp semantic)
         (format stream "~A[~D]"
                 (convert-opcode-name (first semantic))
                 (second semantic)))
        (semantic
         (format stream "~A" (convert-opcode-name semantic)))))

(defun tgsi-float-string (value)
  ;; Common Lisp prints double-float exponents with D, but Mesa's TGSI reader
  ;; delegates to the C floating-point reader and therefore requires E.
  (map 'string
       (lambda (character)
         (if (find character "dDfFsSlL") #\e character))
       (format nil "~A" value)))

(defun assemble (processor source)
  (let* ((total-size 2) ; header token + processor token
         (immediate-index 0)
         (saw-label nil)
         (text (with-output-to-string (text)
                 (write-line (ecase processor
                               (:vertex "VERT")
                               (:fragment "FRAG"))
                             text)
                 (dolist (stmt source)
                   (etypecase stmt
                     ((unsigned-byte 32) ; label
                      ;; Can't have multiple labels one after the other.
                      (when saw-label
                        (error "Unexpected label ~D after label ~D" stmt saw-label))
                      (format text "~D: " stmt)
                      (incf total-size)
                      (setf saw-label stmt))
                     ((cons (eql dcl))
                      ;; Declaration.
                      (when saw-label
                        (error "Unexpected label ~D before declaration ~S" saw-label stmt))
                      (destructuring-bind ((file index &optional (end-index index)) &rest things)
                          (rest stmt)
                        (check-type file (member :in :out :const :temp :samp))
                        (check-type index (unsigned-byte 32))
                        (check-type end-index (unsigned-byte 32))
                        (when (< end-index index)
                          (error "Declaration range ends before it starts: ~D..~D"
                                 index end-index))
                        (multiple-value-bind
                              (dimension array semantic interpolation location invariant)
                            (parse-declaration-qualifiers processor file things)
                          (incf total-size 2) ; Declaration + register range.
                          (format text "DCL ~A" file)
                          (when dimension
                            (incf total-size)
                            (format text "[~D]" dimension))
                          (cond ((eql index end-index)
                                 (format text "[~D]" index))
                                (t
                                 (format text "[~D..~D]" index end-index)))
                          (when array
                            (incf total-size)
                            (format text ", ARRAY(~D)" array))
                          (when semantic
                            (incf total-size)
                            (write-string ", " text)
                            (write-declaration-semantic semantic text))
                          (when interpolation
                            ;; The mode and optional location share one token.
                            (incf total-size)
                            (format text ", ~A" interpolation))
                          (when location
                            (format text ", ~A" location))
                          (when invariant
                            ;; INVARIANT is a bit in the declaration token.
                            (format text ", INVARIANT"))
                          (terpri text))))
                     ((cons (eql imm))
                      ;; Immediate.
                      (when saw-label
                        (error "Unexpected label ~D before immediate ~S" saw-label stmt))
                      (let ((number nil)
                            (arguments (rest stmt)))
                        (when (integerp (first arguments))
                          (setf number (pop arguments))
                          (check-type number (unsigned-byte 32))
                          (unless (= number immediate-index)
                            (error "Expected immediate number ~D, got ~D"
                                   immediate-index number)))
                        (destructuring-bind (type values) arguments
                          (when number
                            (format text "IMM[~D] " number))
                          (unless number
                            (write-string "IMM " text))
                          (ecase type
                            (:flt32
                             (destructuring-bind (x y z w) values
                               (check-type x single-float)
                               (check-type y single-float)
                               (check-type z single-float)
                               (check-type w single-float)
                               (format text "FLT32 {~A, ~A, ~A, ~A}~%"
                                       x y z w)))
                            (:uint32
                             (destructuring-bind (x y z w) values
                               (check-type x (unsigned-byte 32))
                               (check-type y (unsigned-byte 32))
                               (check-type z (unsigned-byte 32))
                               (check-type w (unsigned-byte 32))
                               (format text "UINT32 {~D, ~D, ~D, ~D}~%"
                                       x y z w)))
                            (:int32
                             (destructuring-bind (x y z w) values
                               (check-type x (signed-byte 32))
                               (check-type y (signed-byte 32))
                               (check-type z (signed-byte 32))
                               (check-type w (signed-byte 32))
                               (format text "INT32 {~D, ~D, ~D, ~D}~%"
                                       x y z w)))
                            (:flt64
                             (destructuring-bind (x y) values
                               (check-type x double-float)
                               (check-type y double-float)
                               (format text "FLT64 {~A, ~A}~%"
                                       (tgsi-float-string x)
                                       (tgsi-float-string y)))))
                          (incf total-size 5)
                          (incf immediate-index)))) ; Immediate + 4 data tokens.
                     (cons
                      ;; An instruction.
                      (setf saw-label nil)
                      (format text "~A" (convert-opcode-name (first stmt)))
                      (incf total-size)
                      (let ((first-operand-p t)
                            (texture nil))
                        (when (eql (first stmt) 'tex)
                          (assert (eql (length stmt) 5))
                          (setf texture (or (fifth stmt) :tex-missing-texture))
                          (setf stmt (butlast stmt)))
                        (dolist (operand (rest stmt))
                          (destructuring-bind (file index &optional (swizzle :xyzw))
                              operand
                            (check-type file (member :imm :in :out :const :temp :samp))
                            (check-type index (unsigned-byte 32))
                            (check-swizzle swizzle)
                            (cond (first-operand-p
                                   (setf first-operand-p nil)
                                   (write-string " " text))
                                  (t
                                   (write-string ", " text)))
                            (format text "~A[~D]" file index)
                            (when (not (eql swizzle :xyzw))
                              (format text ".~A" swizzle))
                            (incf total-size)))
                        (when texture
                          (check-type texture (member :1d :2d :3d))
                          (incf total-size)
                          (format text ", ~A" texture)))
                      (terpri text))))
                 (when saw-label
                   (error "Trailing label ~D at end of source" saw-label)))))
    (values text total-size)))
