;;;; tests/dsl-goal-engine-tests.lisp — goal-driven execution saves LLM calls.
;;;;
;;;; Milestone (B): RUN-GOAL walks :subgoals by CODE and stops as soon as the
;;;; LOCAL :done-when predicate holds — the model is never asked "are we done?"
;;;; or "which step next?". We prove this with the mock transport, whose script
;;;; is consumed one reply per LLM call (pop). Expected: a 3-subgoal goal whose
;;;; done-when becomes true after subgoal #2 runs only 2 model calls.
(in-package #:agent-cl.tests)

(defparameter *reached* 0 "world-progress counter advanced by AFTER-SUBGOAL")
(defun progress-reached-p () (>= *reached* 2))

(defgoal three-step-goal ()
  (:intent "stop after two subgoals")
  (:subgoals step-a step-b step-c)
  (:done-when (progress-reached-p)))

(defun reply-ok ()
  (agent-cl.llm:script-reply
   "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}],\"usage\":{\"total_tokens\":1}}"))

(deftest dsl-run-goal-stops-early-and-saves-calls
  (setf *reached* 0)
  (let* ((mk (agent-cl.llm:make-mock-transport
              ;; five replies available; we assert only TWO are consumed
              :script (list (reply-ok) (reply-ok) (reply-ok) (reply-ok) (reply-ok))))
         (before (length (agent-cl.llm:mock-script mk)))
         (agent (agent-cl.loop:make-agent :transport mk :tools nil
                                          :policy (agent-cl.loop:make-policy :max-steps 3)))
         (result (run-goal 'three-step-goal agent
                           :after-subgoal (lambda (sub) (declare (ignore sub))
                                            (incf *reached*)))))
    (is-equal t (getf result :completed-p))
    (is-equal 2 (getf result :subgoals-run)
              "must stop after subgoal #2 (done-when satisfied), not run step-c")
    (is-equal 'step-b (getf result :stopped-at))
    (let ((consumed (- before (length (agent-cl.llm:mock-script mk)))))
      (is-equal 2 consumed
                "exactly 2 model calls: one per subgoal, no 'am I done?' round"))))

(deftest dsl-run-goal-runs-all-when-never-done
  (setf *reached* 0)
  (let* ((mk (agent-cl.llm:make-mock-transport
              :script (list (reply-ok) (reply-ok) (reply-ok) (reply-ok))))
         ;; subgoals step-a/b/c but done-when needs >=2 — force never-done by
         ;; leaving the counter at 0 (no after-subgoal hook)
         (before (length (agent-cl.llm:mock-script mk)))
         (agent (agent-cl.loop:make-agent :transport mk :tools nil
                                          :policy (agent-cl.loop:make-policy :max-steps 3)))
         (result (run-goal 'three-step-goal agent)))   ; no after-subgoal -> counter stays 0
    (is-equal nil (getf result :completed-p))
    (is-equal 3 (getf result :subgoals-run)
              "with done-when never satisfied, all subgoals run")
    (is-equal 3 (- before (length (agent-cl.llm:mock-script mk))))))

(deftest dsl-run-goal-local-orchestration-no-extra-calls
  ;; done-when already true: the loop runs subgoal #1 once, then the LOCAL gate
  ;; stops immediately — no "am I done?" round, no run of the remaining subgoals.
  (setf *reached* 99)
  (let* ((mk (agent-cl.llm:make-mock-transport :script (list (reply-ok))))
         (before (length (agent-cl.llm:mock-script mk)))
         (agent (agent-cl.loop:make-agent :transport mk :tools nil
                                          :policy (agent-cl.loop:make-policy :max-steps 3)))
         (result (run-goal 'three-step-goal agent)))
    ;; the loop runs subgoal #1 once, then the local done-when gate ends it.
    (ok (getf result :completed-p))
    (ok (<= (- before (length (agent-cl.llm:mock-script mk))) 1))))
