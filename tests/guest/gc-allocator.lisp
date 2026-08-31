(in-package :lambda64.tests)

(define-test "gc.repeated-major" ()
  (let ((objects (make-array 1024))
        (major-cycles sys.int::*gc-major-cycles*))
    (dotimes (i (length objects))
      (setf (aref objects i) (list i (+ i 1) (+ i 2))))
    (dotimes (cycle 3)
      (declare (ignore cycle))
      (mezzano.extensions:gc :full t)
      (dotimes (i (length objects))
        (let ((object (aref objects i)))
          (is (= (first object) i))
          (is (= (second object) (+ i 1)))
          (is (= (third object) (+ i 2))))))
    (is (>= sys.int::*gc-major-cycles* (+ major-cycles 3)))))

(define-test "gc.minor-then-major" ()
  ;; Establish an old generation, then keep a newly allocated graph alive
  ;; through a forced minor collection followed by a forced major collection.
  (mezzano.extensions:gc :full t)
  (let ((objects (make-array 2048))
        (minor-cycles sys.int::*gc-minor-cycles*)
        (major-cycles sys.int::*gc-major-cycles*)
        (old-major-threshold sys.int::*gc-major-heap-low-threshold*)
        (old-force-major sys.int::*gc-force-major-cycle*))
    (dotimes (i (length objects))
      (setf (aref objects i) (cons i (- i))))
    ;; A plain GC may legitimately upgrade to major when memory is low.  Hold
    ;; the upgrade threshold at zero for this one request and restore both
    ;; globals even if the collection fails.
    (unwind-protect
         (progn
           (setf sys.int::*gc-major-heap-low-threshold* 0
                 sys.int::*gc-force-major-cycle* nil)
           (mezzano.extensions:gc))
      (setf sys.int::*gc-major-heap-low-threshold* old-major-threshold
            sys.int::*gc-force-major-cycle* old-force-major))
    (is (> sys.int::*gc-minor-cycles* minor-cycles))
    (dotimes (i (length objects))
      (is (= (car (aref objects i)) i))
      (is (= (cdr (aref objects i)) (- i))))
    (mezzano.extensions:gc :full t)
    (is (> sys.int::*gc-major-cycles* major-cycles))
    (dotimes (i (length objects))
      (is (= (car (aref objects i)) i))
      (is (= (cdr (aref objects i)) (- i))))))

(define-test "gc.intergenerational-write-barrier" ()
  ;; Promote HOLDER, then store a young object graph into it.  A minor GC must
  ;; find that graph through the old-to-young card-table entry.
  (let ((holder (make-array 1 :initial-element nil))
        (old-major-threshold sys.int::*gc-major-heap-low-threshold*)
        (old-force-major sys.int::*gc-force-major-cycle*))
    (mezzano.extensions:gc :full t)
    (let ((young (make-array 4096)))
      (dotimes (i (length young))
        (setf (aref young i) (vector i (+ i 1))))
      (setf (aref holder 0) young)
      (unwind-protect
           (progn
             (setf sys.int::*gc-major-heap-low-threshold* 0
                   sys.int::*gc-force-major-cycle* nil)
             (mezzano.extensions:gc))
        (setf sys.int::*gc-major-heap-low-threshold* old-major-threshold
              sys.int::*gc-force-major-cycle* old-force-major))
      (is (= (length (aref holder 0)) 4096))
      (dotimes (i 4096)
        (is (= (aref (aref (aref holder 0) i) 0) i))
        (is (= (aref (aref (aref holder 0) i) 1) (+ i 1)))))))

(define-test "allocator.after-major" ()
  (mezzano.extensions:gc :full t)
  ;; Exercise both general-object and cons TLAB refills after fixup-tlabs.
  (let ((objects (make-array 32768)))
    (dotimes (i (length objects))
      (setf (aref objects i) (list i (* i i) (vector i (- i)))))
    (dotimes (i (length objects))
      (let ((object (aref objects i)))
        (is (= (first object) i))
        (is (= (second object) (* i i)))
        (is (= (aref (third object) 0) i))
        (is (= (aref (third object) 1) (- i)))))))

(define-test "gc.pinned-objects" ()
  (let* ((vector (make-array 256 :area :pinned))
         (pair (sys.int::cons-in-area vector :pinned-marker :pinned)))
    (dotimes (i (length vector))
      (setf (aref vector i) (+ #x1000 i)))
    (dotimes (cycle 2)
      (declare (ignore cycle))
      (mezzano.extensions:gc :full t)
      (is (eq (car pair) vector))
      (is (eq (cdr pair) :pinned-marker))
      (dotimes (i (length vector))
        (is (= (aref vector i) (+ #x1000 i)))))))

(define-test "gc.verify-and-state-restore" ()
  (let ((old-verify sys.int::*gc-debug-validate-intergenerational-pointers*)
        (major-cycles sys.int::*gc-major-cycles*)
        (root (make-array 4096)))
    (dotimes (i (length root))
      (setf (aref root i) (cons i (vector (+ i 1)))))
    (unwind-protect
         (progn
           ;; GC-MAJOR-CYCLE invokes the intergenerational pointer verifier
           ;; when this switch is enabled.
           (setf sys.int::*gc-debug-validate-intergenerational-pointers* t)
           (mezzano.extensions:gc :full t))
      (setf sys.int::*gc-debug-validate-intergenerational-pointers* old-verify))
    (is (> sys.int::*gc-major-cycles* major-cycles))
    (is (not sys.int::*gc-in-progress*))
    (dotimes (i (length root))
      (is (= (car (aref root i)) i))
      (is (= (aref (cdr (aref root i)) 0) (+ i 1))))))

(define-test "alloc.smp-major" ()
  (let ((threads (make-array 4)))
    (dotimes (thread-index (length threads))
      (let ((seed thread-index))
        (setf (aref threads thread-index)
              (mezzano.supervisor:make-thread
               (lambda ()
                 (let ((objects (make-array 8192)))
                   (dotimes (i (length objects))
                     (setf (aref objects i)
                           (list seed i (+ (* seed 8192) i))))
                   (let ((last (aref objects (1- (length objects)))))
                     (+ (first last) (second last) (third last)))))
               :name "Lambda64 CI allocator"))))
    (dotimes (thread-index (length threads))
      (multiple-value-bind (return-values stoppedp)
          (mezzano.supervisor:thread-join (aref threads thread-index))
        (is stoppedp)
        (is (= (first return-values)
               (+ thread-index 8191 (+ (* thread-index 8192) 8191))))))
    (mezzano.extensions:gc :full t)
    (is (not sys.int::*gc-in-progress*))
    ;; Confirm all per-thread TLAB state was fixed up by allocating again on
    ;; the main thread after the SMP collection.
    (let ((post-gc (loop repeat 16384 collect (cons :live :after-gc))))
      (is (= (length post-gc) 16384)))))
