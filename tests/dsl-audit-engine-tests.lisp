;;;; tests/dsl-audit-engine-tests.lisp — DEFWAUDIT blocks the real engine run.
;;;;
;;;; Milestone (A): prove an audit rule actually blocks a turn in AGENT-CL.LOOP:RUN
;;;; (not just that it registers). Guards are consulted at the TOP of each engine
;;;; step, so a tripping audit stops the run before any LLM call — which we also
;;;; assert by checking the mock transport's script is not consumed.
;;;;
;;;; Isolation: audit rules register into the GLOBAL *EXTRA-GUARDS* table, so
;;;; every test runs under (let ((*extra-guards* nil)) ...) and registers at test
;;;; time via EVAL. No leakage into other engine tests.
(in-package #:agent-cl.tests)

(deftest dsl-audit-blocks-real-engine-run
  (let ((agent-cl.loop:*extra-guards* nil))
    (eval '(defaudit engine-blocker
             (:applies-to "any")
             (:check (declare (ignore agent)) "audit: operation refused")))
    (let* ((mk (agent-cl.llm:make-mock-transport
                :script (list (agent-cl.llm:script-reply "{\"x\":1}"))))
           (before (length (agent-cl.llm:mock-script mk)))
           (agent (agent-cl.loop:make-agent :transport mk :tools nil
                                            :policy (agent-cl.loop:make-policy :max-steps 5)))
           (summary (agent-cl.loop:run agent "do something")))
      (ok (not (agent-cl.loop:done-p summary)) "a tripping audit must not finish")
      (is-equal "audit: operation refused" (agent-cl.loop:guard-reason summary))
      (is-equal before (length (agent-cl.llm:mock-script mk))
                "blocked before any LLM call => transport script untouched"))))

(deftest dsl-audit-passing-rule-does-not-block
  (let ((agent-cl.loop:*extra-guards* nil))
    (eval '(defaudit engine-allower
             (:check (declare (ignore agent)) nil)))
    (let* ((mk (agent-cl.llm:make-mock-transport
                :script (list (agent-cl.llm:script-reply
                               "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"done!\"},\"finish_reason\":\"stop\"}],\"usage\":{\"total_tokens\":1}}"))))
           (agent (agent-cl.loop:make-agent :transport mk :tools nil
                                            :policy (agent-cl.loop:make-policy :max-steps 5)))
           (summary (agent-cl.loop:run agent "hello")))
      (ok (agent-cl.loop:done-p summary) "a passing audit must let the run finish")
      (ok (search "done!" (or (agent-cl.loop:final-content summary) ""))))))

(deftest dsl-audit-absent-does-not-block
  (let ((agent-cl.loop:*extra-guards* nil))
    (let* ((mk (agent-cl.llm:make-mock-transport
                :script (list (agent-cl.llm:script-reply
                               "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}],\"usage\":{\"total_tokens\":1}}"))))
           (agent (agent-cl.loop:make-agent :transport mk :tools nil
                                            :policy (agent-cl.loop:make-policy :max-steps 5)))
           (summary (agent-cl.loop:run agent "hi")))
      (ok (agent-cl.loop:done-p summary)))))
