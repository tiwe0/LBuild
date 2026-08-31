(in-package :lambda64.tests)

(defvar *tests* nil)
(defvar *pass-count* 0)
(defvar *fail-count* 0)

(defparameter *expected-test-names*
  '("runtime.integer-arithmetic"
    "runtime.arrays-and-strings"
    "runtime.sequences"
    "runtime.hash-tables"
    "runtime.closures-and-values"
    "runtime.conditions-and-unwind"
    "runtime.symbols-and-packages"
    "runtime.structures-and-clos"
    "runtime.weak-pointer-live-value"
    "os.repl-read-eval-compile"
    "os.swank-listener"
    "os.virtio-net-ping-host"
    "os.virtio-block-read-write"
    "os.local-filesystem-read-write"
    "os.file-server-read-write"
    "app.http-demo"
    "app.telnet"
    "app.irc"
    "app.filer"
    "gc.repeated-major"
    "gc.minor-then-major"
    "gc.intergenerational-write-barrier"
    "allocator.after-major"
    "gc.pinned-objects"
    "gc.verify-and-state-restore"
    "alloc.smp-major"))

(defun record-failure (name reason)
  (incf *fail-count*)
  (format t "LAMBDA64_TEST_FAIL ~A ~A~%" name reason))

(defun run-one-test (test)
  (handler-case
      (progn
        (funcall (cdr test))
        (incf *pass-count*)
        (format t "LAMBDA64_TEST_PASS ~A~%" (car test)))
    (error (condition)
      (format t "LAMBDA64_TEST_DIAGNOSTIC ~A ~A~%" (car test) condition)
      (record-failure (car test) (type-of condition)))))

(defun run-registered-tests ()
  (dolist (test (reverse *tests*))
    (run-one-test test)))

(defun validate-test-catalog ()
  (let ((actual (mapcar #'car *tests*)))
    (unless (= (length actual) (length (remove-duplicates actual :test #'string=)))
      (error "Duplicate guest test names: ~S" actual))
    (unless (and (= (length actual) (length *expected-test-names*))
                 (every (lambda (name) (member name actual :test #'string=))
                        *expected-test-names*))
      (error "Guest test catalog mismatch. Expected ~S, got ~S"
             *expected-test-names* actual))))

(defun injected-failure-p ()
  (not (null (probe-file "SYS:HOME;LAMBDA64-CI-INJECT-FAIL.SENTINEL"))))

(defun run-ci-tests ()
  (setf *tests* nil
        *pass-count* 0
        *fail-count* 0)
  (handler-case
      (if (injected-failure-p)
          (record-failure "harness.injected" "intentional")
          (progn
            (sys.int::cal "SYS:SOURCE;TESTS;GUEST;HARNESS.LISP")
            (sys.int::cal "SYS:SOURCE;TESTS;GUEST;CORE-RUNTIME.LISP")
            (sys.int::cal "SYS:SOURCE;TESTS;GUEST;OS-SERVICES.LISP")
            (sys.int::cal "SYS:SOURCE;TESTS;GUEST;GC-ALLOCATOR.LISP")
            (validate-test-catalog)
            (run-registered-tests)))
    (error (condition)
      (format t "LAMBDA64_TEST_DIAGNOSTIC harness.load ~A~%" condition)
      (record-failure "harness.load" "harness-load")))
  (format t "LAMBDA64_TEST_SUMMARY pass=~D fail=~D~%"
          *pass-count* *fail-count*)
  (when (zerop *fail-count*)
    (mezzano.supervisor:debug-print-line "CI build completed successfully!"))
  (finish-output)
  (mezzano.supervisor:ci-exit (not (zerop *fail-count*))))
