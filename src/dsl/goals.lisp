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

(defvar *goal-predicate-error* nil
  "Diagnostic for the last predicate that could not be evaluated locally:
  (values path condition). A swallowed error used to make a typo'd :done-when
  look exactly like 'not satisfied yet', so the goal silently never completed.")

(defun note-predicate-error (form e)
  (setf *goal-predicate-error* (cons form e))
  nil)

(defun last-goal-predicate-error ()
  "The (FORM . CONDITION) of the last predicate failure, or NIL."
  (when *goal-predicate-error*
    (format nil "~s -> ~a" (car *goal-predicate-error*)
            (cdr *goal-predicate-error*))))

(defun clear-goal-predicate-error ()
  (setf *goal-predicate-error* nil))

(defun eval-local-predicate (form)
  "Evaluate a locally-decidable predicate FORM. Any error -> NIL (a predicate
  that cannot be decided locally is treated as 'not satisfied', never as a
  reason to call out), but the failure is RECORDED so it can be reported:
  LAST-GOAL-PREDICATE-ERROR returns it and RUN-GOAL surfaces it. Returns T/NIL."
  (handler-case (let ((v (eval form))) (and v t))
    (error (e) (note-predicate-error form e))))

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
  (let ((cl (if (and (listp (first clauses)) (null (rest (first clauses))))
                (rest clauses)          ; the conventional () lambda-list of
                                        ; (defgoal name () ...): LISTP, not CONSP,
                                        ; so the empty list is actually stripped
                                        ; instead of being parsed as a clause
                                        ; and injecting (NIL NIL) into the spec
                clauses)))
    (multiple-value-bind (spec refs) (parse-goal-clauses cl)
      `(register-declaration
        (make-declaration ',name :goal
                          :spec ',spec
                          :refs ',refs
                          :source ,(or *load-pathname* *compile-file-pathname*))))))

;;; --------------------------------------------------------------------------
;;; goal-driven execution (plan milestone B)
;;; --------------------------------------------------------------------------
;;; RUN-GOAL walks the :subgoals by CODE (never asking the model "which step is
;;; next?"), runs each subgoal through the engine, and after every subgoal asks
;;; the LOCAL :done-when predicate whether the goal is reached. The moment it
;;; holds we STOP — the model is never consulted about "am I done?" or "should I
;;; retry?". :on-failure (retry :max N) is a local retry budget around a
;;; subgoal. This is the concrete form of "move deterministic decisions out of
;;; the LLM": the orchestration decisions cost zero model calls.

(defun subgoal-task-text (sub)
  "The task string handed to the engine for SUBGOAL symbol SUB."
  (string-downcase (symbol-name sub)))

(defun goal-completed-p (goal-name)
  "Alias of GOAL-DONE-P used by RUN-GOAL (kept distinct for readability)."
  (goal-done-p goal-name))

(defun run-goal (goal-name agent &key after-subgoal)
  "Drive AGENT through GOAL-NAME's :subgoals by code. AFTER-SUBGOAL, if given,
  is called with each subgoal symbol after it runs (to advance world state).
  Returns a plist:
    :completed-p     whether a fresh goal-done-p holds at the end
    :subgoals-run    how many subgoals were attempted (<= declared count)
    :steps           total engine steps across all subgoal runs
    :stopped-at      the subgoal after which we stopped (or NIL)
    :guard-reason    why a subgoal run did not complete (guard trip, model
                     error, pause or step budget), when it did not
    :blocked-at      the subgoal whose run was blocked (then we stop: retrying a
                     blocked subgoal cannot help, and marching on would report
                     success for work that never ran)
    :predicate-error diagnostic when a local predicate could not be evaluated"
  (let* ((subs (goal-subgoals goal-name))
         (retry-limit (goal-retry-limit goal-name))
         (steps 0) (ran 0) (stopped-at nil) (completed nil)
         (blocked-at nil) (blocked-reason nil))
    (clear-goal-predicate-error)
    (block walk
      (dolist (sub subs)
        (incf ran)
        (let ((attempts 0))
          (loop
            (let* ((summary (agent-cl.loop:run agent (subgoal-task-text sub)))
                   (gr (agent-cl.loop:guard-reason summary)))
              (incf steps (or (agent-cl.loop:steps summary) 0))
              (when after-subgoal (funcall after-subgoal sub))
              ;; The engine reports why a turn did not finish. A guard trip, a
              ;; failed model call, a pause or an exhausted step budget all mean
              ;; this subgoal did NOT run to completion — surface it instead of
              ;; treating the subgoal as done.
              (when gr
                (setf blocked-at sub blocked-reason gr)
                (return-from walk)))
            ;; local gate: is the whole goal done now?
            (when (goal-completed-p goal-name)
              (setf completed t stopped-at sub)
              (return-from walk))
            ;; local retry policy for this subgoal
            (incf attempts)
            (when (>= attempts (1+ retry-limit))
              (return))))))
    (list :completed-p completed
          :subgoals-run ran
          :steps steps
          :stopped-at stopped-at
          :blocked-at blocked-at
          :guard-reason blocked-reason
          :predicate-error (last-goal-predicate-error))))
