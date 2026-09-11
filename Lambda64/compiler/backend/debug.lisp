;;;; Debug instruction related functions.

(in-package :mezzano.compiler.backend)

(defun debug-variable-value-meet (a b)
  "Conservative meet of two debug-variable stacks.
ACTIVE-DEBUG-VALUES is maintained as a stack with the innermost binding first,
so the bindings both paths agree on are exactly the longest common tail.
Anything above that differs between predecessors and must not be reported."
  (let ((la (length a))
        (lb (length b)))
    (cond ((> la lb) (setf a (nthcdr (- la lb) a)))
          ((> lb la) (setf b (nthcdr (- lb la) b)))))
  (loop
     (when (equal a b)
       (return a))
     (when (endp a)
       (return '()))
     (pop a)
     (pop b)))

(defun build-debug-variable-value-map (backend-function)
  ;; A dataflow fixpoint rather than a single pass: a basic block can be
  ;; reached both by ordinary control flow and by a non-local exit, and those
  ;; predecessors legitimately carry different binding stacks.  Requiring them
  ;; to agree only held while REMOVE-UNREACHABLE-BASIC-BLOCKS was deleting
  ;; every NLX thunk, which corrupted the NLX dispatch tables.  Meet on
  ;; disagreement instead; the stored value only ever shrinks, so this
  ;; terminates.
  (let ((result (make-hash-table))
        (worklist (list (list (first-instruction backend-function) '()))))
    (loop
       (when (endp worklist)
         (return))
       (destructuring-bind (bb incoming)
           (pop worklist)
         (multiple-value-bind (existing seenp)
             (gethash bb result)
           (let ((active-debug-values (if seenp
                                          (debug-variable-value-meet existing
                                                                     incoming)
                                          incoming)))
             (when (or (not seenp)
                       (not (equal active-debug-values existing)))
               ;; First visit, or a predecessor weakened the result: propagate.
               ;; A backend function may end in an unlinked label while it is
               ;; still being normalized.  Stop at the end of the list rather
               ;; than assuming every path already has a terminator.
               (do ((inst bb (next-instruction backend-function inst)))
                   ((null inst))
                 (setf (gethash inst result) active-debug-values)
                 ;; Track changed & bound values.
                 (typecase inst
                   (debug-bind-variable-instruction
                    (push (list (debug-variable inst) (debug-value inst) (debug-representation inst)) active-debug-values))
                   (debug-update-variable-instruction
                    (setf active-debug-values
                          (loop
                             for entry in active-debug-values
                             collect (cond ((eql (first entry) (debug-variable inst))
                                            (list (first entry) (debug-value inst) (debug-representation inst)))
                                           (t
                                            entry)))))
                   (debug-unbind-variable-instruction
                    ;; The unbind may refer to a binding that the meet above
                    ;; already dropped, so only pop when it is actually on top.
                    (when (eql (first (first active-debug-values)) (debug-variable inst))
                      (pop active-debug-values))))
                 (when (typep inst 'begin-nlx-instruction)
                   (dolist (succ (begin-nlx-targets inst))
                     (push (list succ active-debug-values) worklist)))
                 (when (typep inst 'terminator-instruction)
                   ;; Traverse successors.
                   (dolist (succ (successors backend-function inst))
                     (push (list succ active-debug-values) worklist))
                   (return))))))))
    result))

(defun remove-debug-variable-instructions (backend-function)
  (let ((remove-me '()))
    (do-instructions (inst backend-function)
      (when (typep inst '(or
                          debug-bind-variable-instruction
                          debug-update-variable-instruction
                          debug-unbind-variable-instruction))
        (push inst remove-me)))
    (dolist (inst remove-me)
      (remove-instruction backend-function inst))
    (length remove-me)))

(defun unbox-debug-values (backend-function)
  "Replace (debug-bind var (box type value)) with (debug-bind var value type)"
  (multiple-value-bind (uses defs)
      (build-use/def-maps backend-function)
    (declare (ignore uses))
    (let ((total 0))
      (do-instructions (inst backend-function)
        (when (and (typep inst '(or
                                 debug-bind-variable-instruction
                                 debug-update-variable-instruction))
                   (typep (first (gethash (debug-value inst) defs)) 'box-instruction))
          (let ((box (first (gethash (debug-value inst) defs))))
            (incf total)
            (setf (debug-value inst) (box-source box)
                  (debug-representation inst) (box-type box)))))
      total)))
