(in-package :lambda64.tests)

(defun call-with-temporary-text-file (path contents function)
  (unwind-protect
       (progn
         (with-open-file (stream path
                                 :direction :output
                                 :if-exists :supersede
                                 :if-does-not-exist :create)
           (write-string contents stream)
           (finish-output stream))
         (funcall function path))
    (when (probe-file path)
      (delete-file path))))

(define-test "os.repl-read-eval-compile" ()
  ;; Serial is the deterministic result channel.  Exercise the reader,
  ;; evaluator, compiler, and printer that back an interactive Lisp session.
  (multiple-value-bind (form end)
      (read-from-string "(+ 19 23)")
    (is (= end 9))
    (is (= (eval form) 42)))
  (let ((function (compile nil '(lambda (value) (+ value 1)))))
    (is (= (funcall function 41) 42)))
  (is (string= (write-to-string '(:lambda64 :interactive))
               "(:LAMBDA64 :INTERACTIVE)")))

(define-test "os.swank-listener" ()
  ;; IPL starts Swank before this suite.  A loopback connection proves that an
  ;; external Lisp interaction endpoint is accepting TCP connections.
  (with-open-stream
      (stream (mezzano.network.tcp:tcp-stream-connect
               "127.0.0.1" 4005 :element-type '(unsigned-byte 8) :timeout 5))
    (is (open-stream-p stream))))

(define-test "os.virtio-net-ping-host" ()
  ;; The QEMU user-network gateway is also the configured source file server.
  ;; Reaching it requires the virtio-net interface, DHCP route, ARP, IPv4, and
  ;; ICMP paths rather than only the guest loopback stack.
  (is (mezzano.network.ip:ping-host sys.int::*file-server-host-ip*
                                    :count 1
                                    :quiet t)))

(define-test "os.virtio-block-read-write" ()
  ;; All test boots use QEMU -snapshot.  Write the final sector, read it back,
  ;; and restore it in an unwind-protect.  The host oracle independently
  ;; verifies that the base image SHA did not change.
  (let ((disk (find-if #'mezzano.supervisor:disk-writable-p
                       (mezzano.supervisor:all-disks))))
    (is disk)
    (let* ((sector-size (mezzano.supervisor:disk-sector-size disk))
           (lba (1- (mezzano.supervisor:disk-n-sectors disk)))
           (original (make-array sector-size
                                 :element-type '(unsigned-byte 8)
                                 :area :wired))
           (pattern (make-array sector-size
                                :element-type '(unsigned-byte 8)
                                :area :wired))
           (readback (make-array sector-size
                                 :element-type '(unsigned-byte 8)
                                 :area :wired)))
      (is (mezzano.supervisor:disk-read disk lba 1 original))
      (dotimes (i sector-size)
        (setf (aref pattern i) (mod (+ #x64 (* i 13)) 256)))
      (unwind-protect
           (progn
             (is (mezzano.supervisor:disk-write disk lba 1 pattern))
             (is (mezzano.supervisor:disk-flush disk))
             (is (mezzano.supervisor:disk-read disk lba 1 readback))
             (is (equalp pattern readback)))
        (is (mezzano.supervisor:disk-write disk lba 1 original))
        (is (mezzano.supervisor:disk-flush disk))))))

(define-test "os.local-filesystem-read-write" ()
  (call-with-temporary-text-file
   "LOCAL:>Lambda64-Test.tmp"
   "Lambda64 local filesystem round trip"
   (lambda (path)
     (with-open-file (stream path :direction :input)
       (is (string= (read-line stream)
                    "Lambda64 local filesystem round trip"))))))

(define-test "os.file-server-read-write" ()
  ;; This goes through virtio-net and the remote file protocol to the host
  ;; fixture directory, then removes the fixture on every exit path.
  (call-with-temporary-text-file
   "SYS:HOME;LAMBDA64-LOCAL-TEST.TMP"
   "Lambda64 remote file-server round trip"
   (lambda (path)
     (with-open-file (stream path :direction :input)
       (is (string= (read-line stream)
                    "Lambda64 remote file-server round trip"))))))

(define-test "app.http-demo" ()
  (is (fboundp 'mezzano.http-demo:start-server))
  (is (boundp 'mezzano.http-demo::*demo-server*))
  (multiple-value-bind (request path parameters extra)
      (mezzano.http-demo::parse-http-request "GET /status?full=yes HTTP/1.0")
    (is (string= request "GET"))
    (is (equal path '("status")))
    (is (string= parameters "full=yes"))
    (is (string= extra "HTTP/1.0")))
  ;; Verify response generation independently of the TCP dispatch path so a
  ;; server-side rendering regression produces a useful local failure.
  (let ((response (with-output-to-string (stream)
                    (mezzano.http-demo::demo-file stream))))
    (is (search "HTTP/1.0 200" response))
    (is (search "Hello, World!" response)))
  ;; Exercise the running demo server end-to-end through TCP loopback.
  (with-open-stream
      (stream (mezzano.network.tcp:tcp-stream-connect
               "127.0.0.1" 80 :element-type 'character :timeout 5))
    (format stream "GET / HTTP/1.0~%~%")
    (finish-output stream)
    (is (search "HTTP/1.0 200" (read-line stream)))))

(define-test "app.telnet" ()
  (is (fboundp 'mezzano.telnet:spawn))
  (let ((bytes (mezzano.telnet::vector-ub8 1 2 3 255)))
    (is (equalp bytes #(1 2 3 255)))))

(define-test "app.irc" ()
  (is (fboundp 'mezzano.irc-client:spawn))
  (multiple-value-bind (prefix command parameters)
      (mezzano.irc-client::decode-command
       ":nick!user@example.test PRIVMSG #lambda64 :hello world")
    (is (string= prefix "nick!user@example.test"))
    (is (string= command "PRIVMSG"))
    (is (equal parameters '("#lambda64" "hello world")))))

(define-test "app.filer" ()
  (is (fboundp 'mezzano.gui.filer:spawn))
  (is (eq (mezzano.gui.filer::canonical-type-from-pathname-type "lisp")
          :lisp-source-code))
  (is (eq (mezzano.gui.filer::canonical-type-from-pathname-type "png")
          :image)))
