;;;; src/dsl/audit.lisp — executable audit rules (plan §B, milestone i).
;;;;
;;;; DEFAUDIT is a semantics+metadata layer over the existing DEFGUARD path:
;;;; an audit rule is a locally-decidable predicate over the agent; when it
;;;; returns a non-NIL reason the engine's guard machinery blocks the turn.
;;;; Crucially it reuses *EXTRA-GUARDS* / CHECK-EXTRA-GUARDS unchanged — no new
;;;; engine hook, no new execution path. It additionally registers an :audit
;;;; declaration so DESCRIBE-DECLARATION and a future structured audit report
;;;; can enumerate rules, their :applies-to scope and :evidence source.
(in-package #:agent-cl.dsl)

(defun parse-audit-clauses (clauses)
  "Parse DEFWAUDIT clauses -> (values check-body applies-to refs spec)."
  (let ((check nil) (applies nil) (refs nil) (spec nil))
    (dolist (cl clauses)
      (let ((key (first cl)) (val (rest cl)))
        (case key
          (:check (setf check val))                     ; body forms, agent bound
          ((:applies-to :governed-by)
           (setf applies (append applies (copy-list val)))
           (setf refs (append refs (copy-list val))))
          ((:on-violation :evidence)
           (setf spec (append spec (list key (if (= (length val) 1) (first val) val)))))
          (:intent (setf spec (append spec (list key (first val)))))
          (otherwise (setf spec (append spec (list key (if (= (length val) 1) (first val) val))))))))
    (values check applies refs spec)))

(defmacro defaudit (name &body clauses)
  "Define an executable audit rule.
    (defaudit no-outside-writes
      (:applies-to file.write)
      (:check (when (agent-uses-outside-path-p agent) \"wrote outside workspace\"))
      (:on-violation :block)
      (:evidence (:kind :path-prefix :source \"*file-workspace-root*\")))
  Expansion:
    1. defun NAME (agent) CHECK-BODY           ; guard predicate (local, no LLM)
    2. register-guard \"NAME\" #'NAME           ; reuse the existing guard path
    3. register-declaration :audit with :applies-to / :on-violation / :evidence
  The rule blocks the turn iff CHECK-BODY returns a non-NIL reason string."
  (let ((agent-sym (intern "AGENT" *package*)))
    (multiple-value-bind (check applies refs spec) (parse-audit-clauses clauses)
      (unless check (error "defaudit ~a: missing (:check ...) clause" name))
      `(progn
         (defun ,name (,agent-sym) ,@check)
         (agent-cl.loop:register-guard ,(string-downcase (symbol-name name)) #',name)
         (register-declaration
          (make-declaration ',name :audit
                            :spec (list :applies-to ',applies
                                        ,@(when (getf spec :on-violation)
                                            `(:on-violation ',(getf spec :on-violation)))
                                        ,@(when (getf spec :evidence)
                                            `(:evidence ',(getf spec :evidence)))
                                        ,@(when (getf spec :intent)
                                            `(:intent ,(getf spec :intent))))
                            :refs ',refs
                            :source ,(or *load-pathname* *compile-file-pathname*)))
         ',name))))

;;; --------------------------------------------------------------------------
;;; reflection over audit declarations
;;; --------------------------------------------------------------------------

(defun audit-applies-to (name)
  (getf (decl-spec (find-declaration name :audit)) :applies-to))

(defun audit-on-violation (name)
  (or (getf (decl-spec (find-declaration name :audit)) :on-violation) :block))

(defun audit-evidence (name)
  (getf (decl-spec (find-declaration name :audit)) :evidence))

(defun describe-audit (name)
  "Human-readable audit summary (structure projection): scope + action + evidence."
  (let ((d (find-declaration name :audit)))
    (if (null d)
        (format nil "(no audit ~a)" name)
        (format nil "~&AUDIT ~a~%  applies-to: ~{~a~^, ~}~%  on-violation: ~a~@[~%  evidence: ~s~]~%"
                (decl-name d)
                (audit-applies-to name)
                (audit-on-violation name)
                (audit-evidence name)))))
