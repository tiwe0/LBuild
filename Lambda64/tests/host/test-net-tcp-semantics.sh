#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
src=${TCP_SOURCE:-"$root/net/tcp.lisp"}; sbcl=${SBCL:-sbcl}
forms=$(mktemp); test=$(mktemp); trap 'rm -f "$forms" "$test"' EXIT

python3 - "$src" "$forms" <<'PY'
from pathlib import Path
import re, sys
s=Path(sys.argv[1]).read_text()
if re.search(r'(?im)^\s*;.*\b(?:TODO|FIXME)\b',s): raise SystemExit('TCP markers remain')
for x in ['(tcp-listener-accepts-passive-open-p listener)',
          '(tcp-update-send-window connection seq ack window)',
          '(tcp-connection-abort-pending-p connection)',
          '(tcp-close-stream-connection connection abort)']:
    if x.lower() not in s.lower(): raise SystemExit('missing contract: '+x)
def form(p):
    a=s.find(p)
    if a<0: raise SystemExit('missing form: '+p)
    d=0; string=comment=esc=False
    for i,c in enumerate(s[a:],a):
        if comment:
            if c=='\n': comment=False
        elif string:
            if esc: esc=False
            elif c=='\\': esc=True
            elif c=='"': string=False
        elif c==';': comment=True
        elif c=='"': string=True
        elif c=='(': d+=1
        elif c==')':
            d-=1
            if d==0:return s[a:i+1]
    raise SystemExit('unterminated form: '+p)
ps=['(defparameter *tcp-syn-received-timeout*','(defun +u32','(defun -u32',
'(defun tcp-sequence<','(defun tcp-sequence<=','(defun tcp-accept',
'(defun tcp-listener-complete-accept','(defun close-tcp-listener',
'(defun tcp-listener-remove-pending','(defun tcp-listener-accepts-passive-open-p',
'(defun arm-retransmit-timer','(defun disarm-retransmit-timer',
'(defun retransmit-timer-handler','(defun arm-timeout-timer',
'(defun disarm-timeout-timer','(defun timeout-timer-handler','(defun tcp4-open-passive',
'(defun acceptable-segment-p','(defun tcp-reset-acceptable-p',
'(defun tcp-update-send-window','(defun tcp-flight-size','(defun tcp-note-new-ack',
'(defun tcp-note-duplicate-ack','(defun update-timeout-timer',
'(defun tcp4-connection-receive','(defun tcp4-send-packet','(defun subseq-ub8','(defun tcp-queue-send-data',
'(defun tcp-flush-send-buffer','(defun tcp-send-1','(defun tcp-send (','(defun close-connection',
'(defun abort-stream-connection','(defun tcp-close-stream-connection',
'(defmethod close ((stream tcp-octet-stream)']
Path(sys.argv[2]).write_text('(in-package :mezzano.network.tcp)\n'+'\n'.join(map(form,ps)))
print('TCP semantic contract passed')
PY

cat >"$test" <<'LISP'
(defpackage :mezzano.supervisor (:use :cl)
 (:export #:with-mutex #:timer-expired-p #:timer-disarm #:timer-arm
          #:condition-notify #:current-boot-id #:event-state))
(in-package :mezzano.supervisor)
(defvar *depth* 0)(defvar *timer-log* nil)(defvar *timer-expired* t)(defvar *event* nil)
(defmacro with-mutex ((lock &key resignal-errors)&body body)
 (declare(ignore lock resignal-errors)) `(let ((*depth* (1+ *depth*))) ,@body))
(defun timer-expired-p(x)(declare(ignore x))*timer-expired*)
(defun timer-disarm(x)(push(list :disarm x)*timer-log*))
(defun timer-arm(s x)(push(list :arm s x)*timer-log*))
(defun condition-notify(&rest x)(declare(ignore x)))
(defun current-boot-id():boot)(defun event-state(x)(declare(ignore x))*event*)
(defun (setf event-state)(v x)(declare(ignore x))(setf *event* v))

(defpackage :mezzano.sync (:use :cl)
 (:export #:mailbox-send #:mailbox-receive #:mailbox-flush))
(in-package :mezzano.sync)
(defvar *items* nil)(defvar *sent* nil)
(defun mailbox-send(x box)(declare(ignore box))(assert(plusp mezzano.supervisor::*depth*))(push x *sent*))
(defun mailbox-receive(box &key wait-p)(declare(ignore box wait-p))(pop *items*))
(defun mailbox-flush(box)(declare(ignore box))(prog1 *items*(setf *items* nil)))

(defpackage :mezzano.sync.dispatch (:use :cl)(:export #:dispatch-async))
(in-package :mezzano.sync.dispatch)
(defvar *queue* nil)(defun dispatch-async(f q)(declare(ignore q))(setf *queue*(nconc *queue*(list f))))
(defun run-one()(let((f(pop *queue*)))(when f(funcall f))))
(defpackage :net (:use :cl))(in-package :net)(defvar *network-serial-queue* :network)
(defpackage :mezzano.network.tcp (:use :cl))
(in-package :mezzano.network.tcp)(defvar *sent* nil)
(defpackage :mezzano.network.ip (:use :cl)
 (:export #:transmit-ipv4-packet #:+ip-protocol-tcp+ #:no-route-to-host))
(in-package :mezzano.network.ip)
(defconstant +ip-protocol-tcp+ 6)
(define-condition no-route-to-host(error)())
(defun transmit-ipv4-packet(source destination protocol packet)
 (declare(ignore source destination protocol))
 (push packet mezzano.network.tcp::*sent*))

(in-package :mezzano.network.tcp)
(defconstant +tcp4-flag-fin+ 1)(defconstant +tcp4-flag-syn+ 2)
(defconstant +tcp4-flag-rst+ 4)(defconstant +tcp4-flag-ack+ 16)
(defconstant +tcp4-header-sequence-number+ 4)(defconstant +tcp4-header-window-size+ 14)
(defparameter *minimum-rto* 1)(defparameter *maximum-rto* 60)
(defparameter *initial-window-size* 8192)(defparameter *netmangler-force-local-retransmit* nil)
(defparameter *netmangler-iss* 1000)(defvar *tcp-connections* nil)
(defvar *tcp-connection-lock* :connections)(defvar *tcp-listeners* nil)(defvar *tcp-listener-lock* :listeners)
(defmacro with-tcp-listener-locked(l &body b)`(mezzano.supervisor:with-mutex((tcp-listener-lock ,l):resignal-errors t),@b))
(defmacro with-tcp-connection-locked(c &body b)`(mezzano.supervisor:with-mutex((tcp-connection-lock ,c):resignal-errors t),@b))
(defclass tcp-listener()
 ((pending :accessor tcp-listener-pending-connections :initform(make-hash-table))
  (connections :accessor tcp-listener-connections :initform :mailbox)
  (count :accessor tcp-listener-n-pending-connections :initarg :count)
  (backlog :accessor tcp-listener-backlog :initarg :backlog)
  (lock :accessor tcp-listener-lock :initform :lock)
  (closed :accessor tcp-listener-closed-p :initarg :closed)))
(defclass tcp-connection()
 ((state :accessor tcp-connection-state :initarg :state)
  (local-port :accessor tcp-connection-local-port :initarg :local-port)
  (local-ip :accessor tcp-connection-local-ip :initarg :local-ip)
  (remote-port :accessor tcp-connection-remote-port :initarg :remote-port)
  (remote-ip :accessor tcp-connection-remote-ip :initarg :remote-ip)
  (sndn :accessor tcp-connection-snd.nxt :initarg :snd.nxt)
  (snda :accessor tcp-connection-snd.una :initarg :snd.una)
  (sndw :accessor tcp-connection-snd.wnd :initarg :snd.wnd)
  (wl1 :accessor tcp-connection-snd.wl1 :initarg :snd.wl1)
  (wl2 :accessor tcp-connection-snd.wl2 :initarg :snd.wl2)
  (rcvn :accessor tcp-connection-rcv.nxt :initarg :rcv.nxt)
  (rcvw :accessor tcp-connection-rcv.wnd :initarg :rcv.wnd)
  (mss :accessor tcp-connection-max-seg-size :initarg :max-seg-size)
  (cwnd :accessor tcp-connection-congestion-window :initarg :congestion-window)
  (sst :accessor tcp-connection-slow-start-threshold :initarg :slow-start-threshold)
  (dups :accessor tcp-connection-duplicate-acks :initform 0)
  (rtxq :accessor tcp-connection-retransmit-queue :initform nil)
  (txq :accessor tcp-connection-tx-data :initform nil)
  (listener :accessor tcp-connection-listener :initarg :listener)
  (tt :accessor tcp-connection-timeout-timer :initform :timeout)
  (rt :accessor tcp-connection-retransmit-timer :initform :retransmit)
  (err :accessor tcp-connection-pending-error :initform nil)
  (abort :accessor tcp-connection-abort-pending-p :initform nil)
  (lat :accessor tcp-connection-last-ack-time :initarg :last-ack-time)
  (rto :accessor tcp-connection-rto :initarg :rto)
  (srtt :accessor tcp-connection-srtt :initform 1.0)
  (rttv :accessor tcp-connection-rttvar :initform .5)
  (lock :accessor tcp-connection-lock :initform :lock)
  (cv :accessor tcp-connection-cvar :initform :cv)
  (event :accessor tcp-connection-receive-event :initform :event)
  (timeout :accessor tcp-connection-timeout :initarg :timeout)
  (boot :accessor tcp-connection-boot-id :initarg :boot-id))
 (:default-initargs :state :established :local-port 1 :local-ip :local :remote-port 2
  :remote-ip :remote :snd.nxt 0 :snd.una 0 :snd.wnd 0 :snd.wl1 0 :snd.wl2 0
  :rcv.nxt 0 :rcv.wnd 8192 :max-seg-size 1000 :congestion-window 4000
  :slow-start-threshold 8000 :listener nil :last-ack-time nil :rto 1 :timeout nil :boot-id nil))
(defclass tcp-octet-stream()((connection :initarg :connection :reader tcp-stream-connection)))
(define-condition connection-timed-out(error)((host :initarg :host)(port :initarg :port)))
(define-condition connection-reset(error)((host :initarg :host)(port :initarg :port)))
(define-condition connection-aborted(error)((host :initarg :host)(port :initarg :port)))
(define-condition connection-closed(error)((host :initarg :host)(port :initarg :port)))
(defvar *flags* 0)(defvar *ack* 0)(defvar *seq* 0)(defvar *len* 0)(defvar *window* 0)
(defvar *sent* nil)(defvar *detached* nil)(defvar *aborted* nil)
(defun ub32ref/be(p o)(reduce(lambda(a b)(+(ash a 8)b))p :start o :end(+ o 4)))
(defun ub16ref/be(p o)(+(ash(aref p o)8)(aref p(1+ o))))
(defun tcp-packet-flags(&rest x)(declare(ignore x))*flags*)
(defun tcp-packet-acknowledgment-number(&rest x)(declare(ignore x))*ack*)
(defun tcp-packet-sequence-number(&rest x)(declare(ignore x))*seq*)
(defun tcp-packet-data-length(&rest x)(declare(ignore x))*len*)
(defun tcp-packet-window(&rest x)(declare(ignore x))*window*)
(defun tcp-packet-header-length(&rest x)(declare(ignore x))20)
(defun assemble-tcp4-packet(&rest fields) fields)
(defun tcp4-receive-data(&rest x)(declare(ignore x)))
(defun initial-rtt-measurement(c)(setf(tcp-connection-last-ack-time c)nil))
(defun subsequent-rtt-measurement(c)(setf(tcp-connection-last-ack-time c)nil))
(defun detach-tcp-connection(c)(push c *detached*)(setf(tcp-connection-state c):closed))
(defun abort-connection(c)(push c *aborted*))
(defun tcp4-accept-connection(c &key element-type external-format)(declare(ignore element-type external-format))c)
(defun check-connection-error(c)(declare(ignore c)))
(load(or(sb-ext:posix-getenv "TCP_FORMS")(error "TCP_FORMS unset")))

(defun ok(x m)(unless x(error "~A" m)))(defun eqv(e a m)(unless(equal e a)(error "~A: ~S != ~S" m e a)))
(defun conn(&rest x)(apply #'make-instance 'tcp-connection x))
(defun listener(&key(count 0)(backlog 5)(closed nil))(make-instance'tcp-listener :count count :backlog backlog :closed closed))
(defun reset-logs()(setf *sent* nil *detached* nil *aborted* nil *tcp-connections* nil
 mezzano.sync::*items* nil mezzano.sync::*sent* nil mezzano.sync.dispatch::*queue* nil mezzano.supervisor::*timer-log* nil))
(defun send-state(c)
 (list(tcp-connection-snd.nxt c)(tcp-connection-state c)
      (copy-tree(tcp-connection-tx-data c))(copy-tree(tcp-connection-retransmit-queue c))
      (copy-tree mezzano.supervisor::*timer-log*)(copy-tree *sent*)))
(defun unchanged-after(f c message)
 (let((before(send-state c)))(funcall f)(eqv before(send-state c)message)))

;; ACCEPTABLE-SEGMENT-P must accept overlap without invalid +U32 arity.
(let((c(conn :rcv.nxt 100 :rcv.wnd 100)))(setf *seq* 50 *len* 60)(ok(acceptable-segment-p c nil 0 0)"overlap rejected"))
(let((c(conn :state :syn-sent :snd.nxt 101)))
 (setf *flags* 0 *ack* 101)(ok(not(tcp-reset-acceptable-p c nil 0 0))"SYN-SENT RST without ACK")
 (setf *flags* +tcp4-flag-ack+ *ack* 100)(ok(not(tcp-reset-acceptable-p c nil 0 0))"SYN-SENT RST wrong ACK")
 (setf *ack* 101)(ok(tcp-reset-acceptable-p c nil 0 0)"SYN-SENT RST correct ACK"))

;; Production half-open timeout releases the listener reservation and detaches.
(let*((l(listener :count 1))(c(conn :state :syn-received :listener l)))
 (reset-logs)(setf(gethash c(tcp-listener-pending-connections l))c)
 (timeout-timer-handler c)
 (eqv 0(tcp-listener-n-pending-connections l)"timeout backlog")
 (eqv 0(hash-table-count(tcp-listener-pending-connections l))"timeout pending hash")
 (ok(member c *detached*)"timeout detach")
 (ok(typep(tcp-connection-pending-error c)'connection-timed-out)"timeout condition"))

;; Direct production passive open, including closed-listener mutant guard.
(let((p(make-array 20 :element-type'(unsigned-byte 8):initial-element 0))(l(listener :closed t)))
 (setf(aref p 7)9(aref p 15)20)(reset-logs)
 (ok(null(tcp4-open-passive l p 0 20 :local 80 :remote 4000))"closed passive open")
 (eqv 0(tcp-listener-n-pending-connections l)"closed backlog"))
(let*((p(make-array 20 :element-type'(unsigned-byte 8):initial-element 0))(l(listener))(c nil))
 (setf(aref p 7)9(aref p 15)20)(reset-logs)(setf c(tcp4-open-passive l p 0 20 :local 80 :remote 4000))
 (ok(typep c'tcp-connection)"passive open missing")(eqv 1(tcp-listener-n-pending-connections l)"backlog")
 (ok(gethash c(tcp-listener-pending-connections l))"pending hash")
 (ok(find '(:arm 10 :timeout) mezzano.supervisor::*timer-log* :test #'equal)"syn timeout"))

;; Direct accept/close interleavings and backlog accounting.
(let*((l(listener :closed t))(c(conn)))(reset-logs)(setf mezzano.sync::*items*(list c))
 (ok(null(tcp-accept l :wait-p nil))"closed accept returned connection")(eqv(list c)*aborted*"closed accept abort"))
(let*((l(listener :count 1))(c(conn)))(reset-logs)(setf mezzano.sync::*items*(list c))
 (ok(eq c(tcp-accept l :wait-p nil))"open accept")(eqv 0(tcp-listener-n-pending-connections l)"accept count"))
(let*((l(listener :count 2))(a(conn :listener l))(b(conn :listener l)))
 (reset-logs)(setf(gethash a(tcp-listener-pending-connections l))a mezzano.sync::*items*(list b) *tcp-listeners*(list l))
 (close-tcp-listener l)(ok(tcp-listener-closed-p l)"close flag")(eqv 0(tcp-listener-n-pending-connections l)"close count")
 (ok(and(member a *aborted*)(member b *aborted*))"close abort coverage"))

;; Direct receive path challenges invalid RST and applies ACK windows.
(let((c(conn :rcv.nxt 100 :rcv.wnd 100)))
 (reset-logs)(setf *seq* 100 *len* 0 *flags* +tcp4-flag-rst+)(tcp4-connection-receive c nil 0 20 nil)
 (ok(typep(tcp-connection-pending-error c)'connection-reset)"valid RST condition")
 (ok(member c *detached*)"valid RST detach"))
(let((c(conn :rcv.nxt #xfffffff0 :rcv.wnd 32)))
 (reset-logs)(setf *seq* 5 *len* 0 *flags* +tcp4-flag-rst+)(tcp4-connection-receive c nil 0 20 nil)
 (ok(member c *detached*)"wrapped valid RST"))
(let((c(conn :rcv.nxt 100 :rcv.wnd 100 :snd.nxt 1000 :snd.una 1000)))
 (reset-logs)(setf *seq* 500 *len* 0 *flags* +tcp4-flag-rst+)(tcp4-connection-receive c nil 0 20 nil)
 (eqv :established(tcp-connection-state c)"invalid RST state")(eqv 1(length *sent*)"RST challenge"))
(let((c(conn :rcv.nxt 100 :rcv.wnd 100 :snd.nxt 1000 :snd.una 1000 :snd.wnd 10 :snd.wl1 99 :snd.wl2 999)))
 (reset-logs)(setf *seq* 100 *ack* 1000 *len* 0 *window* 777 *flags* +tcp4-flag-ack+)
 (tcp4-connection-receive c nil 0 20 nil)(eqv 777(tcp-connection-snd.wnd c)"ACK window integration"))

;; WL1/WL2 ordering rejects stale updates and accepts serial wraparound.
(let((c(conn :snd.wnd 100 :snd.wl1 100 :snd.wl2 50)))
 (ok(tcp-update-send-window c 101 50 300)"new window rejected")
 (ok(not(tcp-update-send-window c 100 60 900))"stale WL1 accepted")
 (ok(not(tcp-update-send-window c 101 49 900))"stale WL2 accepted")
 (eqv 300(tcp-connection-snd.wnd c)"stale window rollback")
 (setf(tcp-connection-snd.wl1 c)#xfffffffe)
 (ok(tcp-update-send-window c 1 60 400)"wrapped window rejected")
 (eqv 400(tcp-connection-snd.wnd c)"wrapped window missing"))

;; Reno third duplicate ACK fast-retransmits and a new ACK exits recovery.
(let((c(conn :snd.una 1000 :snd.nxt 5000 :congestion-window 2000
              :slow-start-threshold 8000)))
 (reset-logs)(setf(tcp-connection-retransmit-queue c)'((1000 0 #(1 2 3))))
 (dotimes(i 3)(declare(ignore i))(tcp-note-duplicate-ack c))
 (eqv 1(length *sent*)"third duplicate fast retransmit")
 (eqv 2000(tcp-connection-slow-start-threshold c)"fast recovery threshold")
 (eqv 5000(tcp-connection-congestion-window c)"fast recovery window")
 (tcp-note-duplicate-ack c)
 (eqv 5000(tcp-connection-congestion-window c)"fourth duplicate inflated window")
 (eqv 3(tcp-connection-duplicate-acks c)"duplicate count exceeded recovery threshold")
 (tcp-note-new-ack c 1000 2000)
 (eqv 2000(tcp-connection-congestion-window c)"new ACK recovery exit")
 (eqv 0(tcp-connection-duplicate-acks c)"new ACK duplicate reset"))

;; MSS queue owns a copy, preserves partial data at zero window, then flushes.
(let*((c(conn :snd.nxt 0 :snd.una 0 :snd.wnd 0 :congestion-window 4000))
      (data(make-array 2500 :element-type'(unsigned-byte 8):initial-element 7)))
 (reset-logs)(tcp-queue-send-data c data 0(length data))(setf(aref data 0)9)
 (eqv 7(aref(first(first(tcp-connection-tx-data c)))0)"queue did not copy")
 (eqv '(1000 1000 500)(mapcar(lambda(e)(length(first e)))(tcp-connection-tx-data c))"MSS queue")
 (tcp-flush-send-buffer c)(eqv 0(tcp-connection-snd.nxt c)"zero-window send")
 (setf(tcp-connection-snd.wnd c)1500)(tcp-flush-send-buffer c)
 (eqv 1500(tcp-connection-snd.nxt c)"partial window flush")
 (eqv '(500 500)(mapcar(lambda(e)(length(first e)))(tcp-connection-tx-data c))"partial retention")
 (setf(tcp-connection-snd.wnd c)3000)(tcp-flush-send-buffer c)
 (ok(null(tcp-connection-tx-data c))"window reopen flush")
 (ok(getf(nthcdr 8(first *sent*)):psh-p)"final partial segment lost PSH"))
(let*((c(conn :snd.nxt 0 :snd.una 0 :snd.wnd 4000 :congestion-window 1500))
      (data(make-array 2500 :element-type'(unsigned-byte 8):initial-element 7)))
 (reset-logs)(tcp-queue-send-data c data 0(length data))(tcp-flush-send-buffer c)
 (eqv 1500(tcp-connection-snd.nxt c)"CWND did not limit flush")
 (eqv '(500 500)(mapcar(lambda(e)(length(first e)))(tcp-connection-tx-data c))"CWND partial retention"))

;; Direct retransmit handler and abort-pending suppression.
(let((c(conn :state :syn-received :snd.nxt 101 :rcv.nxt 501 :rto 1)))
 (reset-logs)(retransmit-timer-handler c)(eqv 1(length *sent*)"retransmit send")(eqv 2(tcp-connection-rto c)"RTO backoff")
 (setf *sent* nil(tcp-connection-abort-pending-p c)t)(retransmit-timer-handler c)(ok(null *sent*)"abort retransmit"))

;; Every production send-state guard is independently observable. The bottom
;; network dispatcher records real packet dispatch and contains no abort guard.
(let((c(conn :snd.nxt 10 :rcv.nxt 20)))
 (reset-logs)(setf(tcp-connection-abort-pending-p c)t
                  (tcp-connection-tx-data c)'((#(1 2) t))
                  (tcp-connection-retransmit-queue c)'((9 20 #(8))))
 (unchanged-after(lambda()(tcp4-send-packet c 10 20 #(3)))c"tcp4-send-packet abort guard"))
(let((c(conn :snd.nxt 10 :snd.una 0 :snd.wnd 100 :congestion-window 100 :rcv.nxt 20)))
 (reset-logs)(setf(tcp-connection-abort-pending-p c)t
                  (tcp-connection-tx-data c)'((#(1 2) t))
                  (tcp-connection-retransmit-queue c)'((9 20 #(8))))
 (unchanged-after(lambda()(tcp-flush-send-buffer c))c"tcp-flush-send-buffer abort guard"))
(let((c(conn :snd.nxt 10 :rcv.nxt 20)))
 (reset-logs)(setf(tcp-connection-abort-pending-p c)t
                  (tcp-connection-tx-data c)'((#(1 2) t))
                  (tcp-connection-retransmit-queue c)'((9 20 #(8))))
 (unchanged-after(lambda()(tcp-send-1 c #(3 4)0 2))c"tcp-send-1 abort guard"))
(let((c(conn :state :established :snd.nxt 10 :rcv.nxt 20)))
 (reset-logs)(setf(tcp-connection-abort-pending-p c)t
                  (tcp-connection-tx-data c)'((#(1 2) t))
                  (tcp-connection-retransmit-queue c)'((9 20 #(8))))
 (unchanged-after(lambda()(close-connection c))c"close-connection abort guard"))

;; Deferred FIFO: ACK queued first, then actual CLOSE :ABORT. The abort intent
;; and queue purge happen synchronously; ACK executes without any send, then detach.
(let*((c(conn :rcv.nxt 100 :rcv.wnd 100 :snd.nxt 1000 :snd.una 1000 :snd.wnd 0 :snd.wl1 99 :snd.wl2 999))
      (s(make-instance'tcp-octet-stream :connection c)))
 (reset-logs)(tcp-queue-send-data c #(1 2 3)0 3)(setf(tcp-connection-retransmit-queue c)'((900 100 #(9)))
 *seq* 100 *ack* 1000 *len* 0 *window* 777 *flags* +tcp4-flag-ack+)
 (mezzano.sync.dispatch:dispatch-async(lambda()(tcp4-connection-receive c nil 0 20 nil))net::*network-serial-queue*)
 (close s :abort t)(ok(tcp-connection-abort-pending-p c)"abort publication")
 (ok(null(tcp-connection-tx-data c))"tx purge")(ok(null(tcp-connection-retransmit-queue c))"rtx purge")
 (ok(find '(:disarm :retransmit) mezzano.supervisor::*timer-log* :test #'equal)"abort retransmit disarm")
 (ok(find '(:disarm :timeout) mezzano.supervisor::*timer-log* :test #'equal)"abort timeout disarm")
 (ok(handler-case(progn(tcp-send c #(4 5 6))nil)(connection-aborted()t))"application send after abort")
 (tcp-send-1 c #(7)0 1)(close-connection c)
 (eqv 2(length mezzano.sync.dispatch::*queue*)"FIFO callbacks")
 (mezzano.sync.dispatch::run-one)(ok(null *sent*)"ACK sent after abort")(ok(null *detached*)"early detach")
 (mezzano.sync.dispatch::run-one)(eqv(list c)*detached*"detach"))

;; Actual non-abort CLOSE still sends FIN.
(let*((c(conn :snd.nxt 1 :rcv.nxt 2))(s(make-instance'tcp-octet-stream :connection c)))
 (reset-logs)(close s)(eqv :fin-wait-1(tcp-connection-state c)"close state")(eqv 1(length *sent*)"close FIN"))
(format t "TCP production-direct semantics passed~%")
LISP
TCP_FORMS="$forms" "$sbcl" --noinform --disable-debugger --script "$test"
