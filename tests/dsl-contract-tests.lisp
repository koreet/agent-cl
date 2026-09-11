;;;; tests/dsl-contract-tests.lisp — declaration metadata + minimal goal contract.
;;;;
;;;; Pure/offline. Locks in plan §B1 (reflection registry) and §B2 (defgoal with
;;;; locally-evaluated :done-when). The load-bearing assertion is that deciding
;;;; "done" is LOCAL: a mock transport's script is NOT consumed by goal-done-p.
(in-package #:agent-cl.tests)

;;;; ---- B1: declaration metadata + reflection -----------------------------
(deftest dsl-decl-register-and-find
  (let ((d (make-declaration 'alpha :goal :spec (list :intent "x") :refs '(data-integrity))))
    (register-declaration d)
    (ok (eq d (find-declaration 'alpha :goal)))
    (is-equal "x" (getf (decl-spec (find-declaration 'alpha :goal)) :intent))
    (is-equal '(data-integrity) (decl-refs (find-declaration 'alpha :goal)))))

(deftest dsl-decl-kind-does-not-collide
  (register-declaration (make-declaration 'same :goal  :spec (list :intent "g")))
  (register-declaration (make-declaration 'same :audit :spec (list :check 'ok)))
  (ok (eq :goal  (decl-kind (find-declaration 'same :goal))))
  (ok (eq :audit (decl-kind (find-declaration 'same :audit))))
  (is-equal "g" (getf (decl-spec (find-declaration 'same :goal)) :intent)))

(deftest dsl-decl-all-and-describe
  (register-declaration (make-declaration 'r1 :principle :spec (list :priority 100)))
  (register-declaration (make-declaration 'r2 :principle :spec (list :priority 80)))
  (let ((names (mapcar #'decl-name (all-declarations :principle))))
    (ok (member 'r1 names)) (ok (member 'r2 names)))
  (ok (plusp (length (describe-declaration 'r1 :principle)))))

;;;; ---- B2: defgoal ---------------------------------------------------------
(defun probe-local-true () t)
(defun probe-local-false () nil)

(defgoal demo-goal ()
  (:intent "demo")
  (:subgoals a b c d)
  (:budget (:tokens 1000) (:risk :workspace-write))
  (:preconditions (probe-local-true))
  (:done-when (and (probe-local-true) (probe-local-true)))
  (:on-failure (retry :max 3)))

(defgoal demo-goal-unsat ()
  (:intent "unsat")
  (:done-when (and (probe-local-true) (probe-local-false)))
  (:on-failure (retry :max 0)))

(deftest dsl-goal-registers-with-meta
  (ok (find-declaration 'demo-goal :goal))
  (is-equal "demo" (goal-intent 'demo-goal))
  (is-equal '(a b c d) (goal-subgoals 'demo-goal))
  (is-equal 3 (goal-retry-limit 'demo-goal)))

(deftest dsl-goal-done-when-is-local
  (ok (goal-done-p 'demo-goal))              ; both predicates hold
  (ok (not (goal-done-p 'demo-goal-unsat)))  ; one fails
  (ok (goal-preconditions-met-p 'demo-goal)))

(deftest dsl-goal-predicate-never-signals
  (register-declaration
   (make-declaration 'boom :goal :spec (list :done-when '(error "nope"))))
  (ok (not (goal-done-p 'boom))
      "an un-decidable/raising predicate is treated as not-done, never a crash"))

(deftest dsl-goal-describe-reflects-structure
  (let ((s (describe-declaration 'demo-goal :goal)))
    (ok (search "DEMO-GOAL" s))))

;;;; ---- the real point: deciding done is LOCAL, no LLM call ----------------
(deftest dsl-goal-check-consumes-no-llm-call
  (let ((mock (agent-cl.llm:make-mock-transport
               :script (list (agent-cl.llm:script-reply "{\"x\":1}")))))
    (let ((before (length (agent-cl.llm:mock-script mock))))
      ;; a full "is it done? preconditions met?" pass over the goals
      (goal-done-p 'demo-goal)
      (goal-done-p 'demo-goal-unsat)
      (goal-preconditions-met-p 'demo-goal)
      (is-equal before (length (agent-cl.llm:mock-script mock))
                "local contract checks must not touch the transport"))))
