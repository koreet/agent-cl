;;;; src/dsl/goals.lisp — minimal executable goal contract (plan §B2).
;;;;
;;;; DEFGOAL registers a :goal declaration whose :done-when / :preconditions
;;;; predicates are ordinary Lisp forms evaluated LOCALLY (no LLM). Subgoals are
;;;; a symbol tree; :on-failure currently supports (retry :max N) as a local
;;;; retry budget. We deliberately do NOT build a dependency graph, version
;;;; evolution, or a condition-system restart bridge yet (plan §C), and we only
;;;; accept predicates that are locally decidable — a predicate that itself
;;;; needs inference would just move the LLM call, not remove it.
(in-package #:agent-cl.dsl)

;;; --------------------------------------------------------------------------
;;; spec accessors over the goal declaration
;;; --------------------------------------------------------------------------

(defun goal-spec (name)
  (let ((d (find-declaration name :goal)))
    (and d (decl-spec d))))

(defun goal-intent (name) (getf (goal-spec name) :intent))
(defun goal-subgoals (name)
  "The declared subgoal symbols (order preserved)."
  (copy-list (getf (goal-spec name) :subgoals)))
(defun goal-budget (name) (getf (goal-spec name) :budget))
(defun goal-preconditions (name) (getf (goal-spec name) :preconditions))
(defun goal-done-when-form (name) (getf (goal-spec name) :done-when))

(defun goal-retry-limit (name)
  "If :on-failure is (retry :max N) return N (default 0 = no retry)."
  (let ((of (getf (goal-spec name) :on-failure)))
    (if (and (consp of)
             (symbolp (first of))
             (string-equal (symbol-name (first of)) "RETRY"))
        (or (getf (rest of) :max) 0)
        0)))

;;; --------------------------------------------------------------------------
;;; local predicate evaluation — never signals, never calls the LLM
;;; --------------------------------------------------------------------------

(defun eval-local-predicate (form)
  "Evaluate a locally-decidable predicate FORM. Any error -> NIL (a predicate
  that cannot be decided locally is treated as 'not satisfied', never as a
  reason to call out). Returns T/NIL."
  (handler-case (let ((v (eval form))) (and v t))
    (error () nil)))

(defun goal-done-p (name)
  "True iff NAME's :done-when predicate holds, evaluated locally."
  (let ((form (goal-done-when-form name)))
    (and form (eval-local-predicate form))))

(defun goal-preconditions-met-p (name)
  "True iff all declared :preconditions hold locally (T when none declared)."
  (let ((forms (goal-preconditions name)))
    (if (null forms)
        t
        (every #'eval-local-predicate
               (if (and (consp forms) (eq (first forms) 'and))
                   (rest forms)
                   (list forms))))))

;;; --------------------------------------------------------------------------
;;; the macro
;;; --------------------------------------------------------------------------

(defun parse-goal-clauses (clauses)
  "CLUASES: ((:intent \"...\") (:subgoals a b) (:budget ...) (:preconditions f)
             (:done-when form) (:on-failure (retry :max N)) (:governed-by x y) ...)
  -> (values spec-plist refs)  where REFS collects symbols from :governed-by /
  :audit-rules (collected, not yet used to build a graph)."
  (let ((spec nil) (refs nil))
    (dolist (cl clauses)
      (let ((key (first cl)) (val (rest cl)))
        (case key
          ((:intent :budget) (setf spec (append spec (list key (if (= (length val) 1) (first val) val)))))
          ((:subgoals) (setf spec (append spec (list :subgoals (copy-list val)))))
          ((:preconditions :done-when)
           (setf spec (append spec (list key (if (= (length val) 1) (first val) val)))))
          ((:on-failure) (setf spec (append spec (list :on-failure (first val)))))
          ((:governed-by :audit-rules) (setf refs (append refs (copy-list val))))
          (otherwise (setf spec (append spec (list key (if (= (length val) 1) (first val) val))))))))
    (values spec refs)))

(defmacro defgoal (name &body clauses)
  "Define a goal contract. See docs/dsl-contract-plan.md §B2.
    (defgoal fix-bug ()
      (:intent \"fix the failing test\")
      (:subgoals reproduce diagnose fix verify)
      (:done-when (and (probe-tests-pass) t))
      (:on-failure (retry :max 2)))"
  (declare (ignore clauses))
  (let ((cl (if (and (consp (first clauses)) (null (rest (first clauses))))
                (rest clauses)          ; the empty () lambda-list of defgoal name ()
                clauses)))
    (multiple-value-bind (spec refs) (parse-goal-clauses cl)
      `(register-declaration
        (make-declaration ',name :goal
                          :spec ',spec
                          :refs ',refs
                          :source ,(or *load-pathname* *compile-file-pathname*))))))
