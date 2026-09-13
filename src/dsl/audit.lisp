;;;; src/dsl/audit.lisp — executable audit rules (plan §B, milestone i).
;;;;
;;;; DEFAUDIT is a semantics+metadata layer over the existing DEFGUARD path:
;;;; an audit rule is a locally-decidable predicate over the agent; when it
;;;; returns a non-NIL reason the engine's guard machinery blocks the turn.
;;;;
;;;; Two enforcement points, both reusing existing engine hooks (no new engine
;;;; execution path):
;;;;   * GLOBAL guard — registered through *EXTRA-GUARDS*, consulted at the top
;;;;     of every engine step. Good for a rule that reads world state.
;;;;   * PRE-EXECUTION tool guard — for each name in :applies-to, registered
;;;;     through *TOOL-GUARDS* so the rule is consulted BEFORE that tool runs.
;;;;     This is what makes an audit *preventive*: a global guard can only fire
;;;;     on the next step, i.e. after the write it was meant to stop.
;;;; :on-violation decides what a pre-execution trip does: :block refuses the
;;;; call, :warn runs it and annotates the result.
(in-package #:agent-cl.dsl)

(defparameter *audit-on-violation-values* '(:block :warn :report)
  "Permitted :on-violation values. :block refuses the tool call; :warn/:report
  run it and annotate the result.")

(defun normalize-audit-target (target)
  "Tool name string for an :applies-to entry (symbol, string or keyword)."
  (if (stringp target) (string-downcase target) (string-downcase (string target))))

(defun parse-audit-clauses (clauses)
  "Parse DEFAUDIT clauses -> (values check-body applies-to refs spec).
  Signals on a malformed clause instead of silently registering a rule that can
  never fire."
  (let ((check nil) (applies nil) (refs nil) (spec nil))
    (dolist (cl clauses)
      (unless (and (consp cl) (keywordp (first cl)))
        (error "defaudit: malformed clause ~s (expected (:key value...))" cl))
      (let ((key (first cl)) (val (rest cl)))
        (case key
          (:check (setf check val))                     ; body forms, agent bound
          ((:applies-to :governed-by)
           (setf applies (append applies (copy-list val)))
           (setf refs (append refs (copy-list val))))
          ((:on-violation :evidence)
           (when (and (eq key :on-violation)
                      (not (member (first val) *audit-on-violation-values*)))
             (error "defaudit: :on-violation must be one of ~s; got ~s"
                    *audit-on-violation-values* (first val)))
           (setf spec (append spec (list key (if (= (length val) 1) (first val) val)))))
          (:intent
           ;; stored as DATA (quoted at expansion): an intent is documentation,
           ;; so it must never be evaluated as code.
           (setf spec (append spec (list key (if (= (length val) 1) (first val) val)))))
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
    2. register-guard \"NAME\" #'NAME           ; global, checked each step
    3. register-tool-guard per :applies-to     ; preventive, checked before the tool
    4. register-declaration :audit with :applies-to / :on-violation / :evidence
  The rule blocks the turn iff CHECK-BODY returns a non-NIL reason string; a
  rule that raises also blocks (fail closed)."
  (let ((agent-sym (intern "AGENT" *package*))
        (rule-name (string-downcase (symbol-name name))))
    (multiple-value-bind (check applies refs spec) (parse-audit-clauses clauses)
      (unless check (error "defaudit ~a: missing (:check ...) clause" name))
      (let ((on-violation (or (getf spec :on-violation) :block)))
        `(progn
           (defun ,name (,agent-sym) ,@check)
           (agent-cl.loop:register-guard ,rule-name #',name)
           ,@(mapcar (lambda (target)
                       ;; adapter: the rule predicate takes (agent); the tool
                       ;; guard protocol passes (agent tool args)
                       `(agent-cl.loop:register-tool-guard
                         ,(normalize-audit-target target)
                         (lambda (a tool args)
                           (declare (ignore tool args))
                           (,name a))
                         :on-violation ,on-violation
                         :name ,rule-name))
                     applies)
           (register-declaration
            (make-declaration ',name :audit
                              :spec (list :applies-to ',applies
                                          :on-violation ',on-violation
                                          ,@(when (getf spec :evidence)
                                              `(:evidence ',(getf spec :evidence)))
                                          ,@(when (getf spec :intent)
                                              `(:intent ',(getf spec :intent))))
                              :refs ',refs
                              :source ,(or *load-pathname* *compile-file-pathname*)))
           ',name)))))

;;; --------------------------------------------------------------------------
;;; reflection over audit declarations
;;; --------------------------------------------------------------------------

(defun audit-spec (name)
  (declaration-spec name :audit))

(defun audit-applies-to (name)
  (getf (audit-spec name) :applies-to))

(defun audit-on-violation (name)
  (or (getf (audit-spec name) :on-violation) :block))

(defun audit-evidence (name)
  (getf (audit-spec name) :evidence))

(defun audit-intent (name)
  (getf (audit-spec name) :intent))

(defun audit-preventive-p (name)
  "True when the rule is enforced BEFORE its tools run (it declares :applies-to)."
  (not (null (audit-applies-to name))))

(defun describe-audit (name)
  "Human-readable audit summary (structure projection): scope + action + evidence."
  (let ((d (find-declaration name :audit)))
    (if (null d)
        (format nil "(no audit ~a)" name)
        (format nil "~&AUDIT ~a~%  applies-to: ~{~a~^, ~}~%  on-violation: ~a~@[~%  evidence: ~s~]~@[~%  intent: ~a~]~%"
                (decl-name d)
                (audit-applies-to name)
                (audit-on-violation name)
                (audit-evidence name)
                (audit-intent name)))))
