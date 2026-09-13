;;;; tests/audit-round2-tests.lisp — regression tests for the second audit round.
;;;;
;;;; Every test here locks down a defect that was REPRODUCED before the fix:
;;;;   * tool-scoped audit rules never matched the WIRE tool name
;;;;   * stop() did not cancel the remaining calls of a tool round
;;;;   * a streamed call with no argument fragments kept "" as its arguments
;;;;   * an empty answer was reported as a COMPLETED turn
;;;;   * a chunk truncated mid-JSON killed the stream with "unexpected: end-of-file"
;;;;   * a "data:" heartbeat line killed the stream
;;;;   * synthesized tool-call ids collided across turns
;;;;   * ensure-tool-results counted ids by membership, not per call
;;;;   * a tool call without a function name was recorded and replayed as null
;;;;   * a pause coming from the model call was reported as a model ERROR
;;;;   * usage reported by a stream that then died was thrown away
(in-package #:agent-cl.tests)

(defmacro with-isolated-guards (&body body)
  `(let ((agent-cl.loop:*extra-guards* nil)
         (agent-cl.loop::*tool-guards* nil)
         (agent-cl.dsl::*declarations* (make-hash-table :test 'equal)))
     ,@body))

;;; ---------------------------------------------------------------------------
;;; audit rules must match the name the MODEL sends
;;; ---------------------------------------------------------------------------

(deftest tool-guard-matches-the-wire-name
  "The model is only ever told the WIRE name (time_now for the DSL tool time.now),
  so a rule declared as (:applies-to probe.effect) never fired for the model's own
  call to probe_effect — reproduced end-to-end: the tool ran despite a blocking
  audit rule. Rules must match either spelling."
  (with-isolated-guards
    (register-tool
     (make-tool "probe.effect"
                (lambda (a c) (declare (ignore a c)) (values "RAN" :ok))
                :description "side effect"))
    (unwind-protect
         (let* ((tool (agent-cl.tools:find-tool "probe.effect"))
                (wire (agent-cl.tools::tool-wire-name tool))
                (dotted (agent-cl.tools:tool-name tool)))
           ;; the registry really does publish a different name to the model
           (ok (not (string= wire dotted))
               (format nil "~a should differ from ~a" wire dotted))
           ;; a rule keyed by the DSL name is found from BOTH spellings
           (agent-cl.loop:register-tool-guard
            dotted (lambda (a tool args) (declare (ignore a tool args)) "blocked")
            :name "probe-audit")
           (is-equal 1 (length (agent-cl.loop:tool-guard-rules-for dotted)))
           (is-equal 1 (length (agent-cl.loop:tool-guard-rules-for wire)))
           (multiple-value-bind (action reason rule)
               (agent-cl.loop:tool-guard-decision nil wire nil)
             (is-equal :block action)
             (is-equal "blocked" reason)
             (is-equal "probe-audit" rule))
           ;; and the canonical name is what a display layer should print
           (is-equal dotted (agent-cl.loop::canonical-tool-name wire)))
      (unregister-tool "probe.effect"))))

(deftest defaudit-fires-for-a-dotted-tool-called-by-its-wire-name
  "The same defect through the public macro: a rule with a dotted :applies-to must
  block the tool even though the provider echoes back the mangled name."
  (with-isolated-guards
    (register-tool
     (make-tool "probe.dotted"
                (lambda (a c) (declare (ignore a c)) (values "RAN" :ok))
                :description "side effect"))
    (unwind-protect
         (progn
           (eval '(agent-cl.dsl:defaudit dotted-audit
                    (:applies-to probe.dotted)
                    (:check (declare (ignore agent)) "rules say no")
                    (:on-violation :block)))
           (let* ((wire (agent-cl.tools::tool-wire-name
                         (agent-cl.tools:find-tool "probe.dotted")))
                  (tc (make-tool-call "c1" wire "{}"))
                  (agent (agent-cl.loop:make-agent
                          :transport (make-mock-transport)
                          :tools '("probe.dotted"))))
             (multiple-value-bind (content status)
                 (agent-cl.loop::dispatch-tool-call
                  agent tc (agent-cl.loop:make-policy))
               (is-equal :error status "the call must be refused")
               (ok (search "rules say no" content)))))
      (unregister-tool "probe.dotted"))))

;;; ---------------------------------------------------------------------------
;;; stop() must cancel the remaining calls of a round
;;; ---------------------------------------------------------------------------

(deftest stop-cancels-the-remaining-tool-calls
  "Ctrl-C only cancelled the STEP loop, so the remaining calls of a multi-call
  round still ran — including destructive ones — after the user interrupted."
  (with-isolated-guards
    (let ((ran 0))
      (register-tool
       (make-tool "probe.stop"
                  (lambda (a c)
                    (declare (ignore a c))
                    (incf ran)
                    (values "ran" :ok))
                  :description "counts its invocations"))
      (unwind-protect
           (let* ((tr (make-mock-transport))
                  (agent (make-agent :transport tr :tools '("probe.stop")
                                     :policy (make-policy :max-steps 3))))
             ;; three calls in ONE round; the first one stops the agent
             (let* ((tcs (list (make-tool-call "c1" "probe.stop" "{}")
                               (make-tool-call "c2" "probe.stop" "{}")
                               (make-tool-call "c3" "probe.stop" "{}")))
                    (result (agent-cl.llm::make-instance
                             'agent-cl.llm:turn-result
                             :content "" :tool-calls tcs)))
               (agent-cl.loop:stop agent)
               (let ((executed (agent-cl.loop::execute-tool-round
                                agent result (agent-cl.loop:agent-policy agent))))
                 (is-equal 0 executed "a stopped agent must not run more calls")
                 (is-equal 0 ran)
                 ;; ... and every advertised call still has a result, or the
                 ;; NEXT request of the session is rejected with 400
                 (let ((results (remove-if-not
                                 (lambda (m) (eq (agent-cl.messages:msg-role m) :tool))
                                 (agent-messages agent))))
                   (is-equal 3 (length results)
                             "unexecuted calls must still be answered")))))
        (unregister-tool "probe.stop")))))

;;; ---------------------------------------------------------------------------
;;; wire-level: ids, empty arguments, heartbeats, truncated chunks, names
;;; ---------------------------------------------------------------------------

(deftest sse-heartbeat-line-is-ignored
  "An empty data field is an empty event: handing \"\" to the JSON decoder raised
  end-of-file and killed an otherwise healthy stream."
  (is-equal :ignore (agent-cl.llm::sse-data-of-line "data:"))
  (is-equal :ignore (agent-cl.llm::sse-data-of-line "data:   "))
  ;; still usable
  (is-equal "{\"a\":1}" (agent-cl.llm::sse-data-of-line "data: {\"a\":1}"))
  (let* ((tr (make-mock-transport
              :script (list (script-stream
                             '("data:"
                               "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}"
                               "data: [DONE]")))))
         (turn (agent-cl.llm:perform-request tr '(:stream t))))
    (agent-cl.llm:stream-drain turn)
    (is-equal "hi" (agent-cl.llm:result-content (agent-cl.llm:stream-finalize turn)))))

(deftest sse-streamed-call-without-arguments-gets-empty-object
  "A streamed tool call whose argument fragments never arrived kept \"\" — which
  is not JSON, so the tool could not run and the invalid value was replayed to the
  provider on every later request."
  (let* ((tr (make-mock-transport
              :script (list (script-stream
                             '("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_a\",\"function\":{\"name\":\"probe.noargs\"}}]}}]}"
                               "data: [DONE]")))))
         (turn (agent-cl.llm:perform-request tr '(:stream t))))
    (agent-cl.llm:stream-drain turn)
    (let ((tc (first (agent-cl.llm:result-tool-calls (agent-cl.llm:stream-finalize turn)))))
      (is-equal "{}" (agent-cl.messages:tool-call-arguments tc))
      ;; and it parses (the old value raised end-of-file inside the decoder)
      (is-equal nil (agent-cl.messages:tool-call-arguments-plist tc)))))

(deftest sse-truncated-chunk-is-a-retryable-transport-error
  "A chunk cut in half by a dropped connection raised a raw END-OF-FILE out of
  yason: reported as \"unexpected: end of file on ...\" and never retried."
  (let* ((tr (make-mock-transport
              :script (list (script-stream
                             '("data: {\"choices\":[{\"delta\":{\"content\":\"part"
                               "data: [DONE]")))))
         (turn (agent-cl.llm:perform-request tr '(:stream t))))
    (handler-case
        (progn (agent-cl.llm:stream-drain turn)
               (ok nil "a truncated chunk must signal"))
      (agent-cl.core:transport-error (e)
        (ok (agent-cl.core:transport-error-retryable-p e)
            "a dropped connection is transient, so it is retryable")))))

(deftest synthesized-tool-call-ids-are-unique-across-turns
  "Ids were numbered per response (call_0, call_1), so two id-less replies in one
  conversation produced duplicate tool_call_ids in the same transcript."
  (flet ((id-of (reply)
           (let ((r (agent-cl.llm:parse-chat-json reply)))
             (agent-cl.messages:tool-call-id
              (first (agent-cl.llm:result-tool-calls r))))))
    (let* ((reply "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"function\":{\"name\":\"a\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}")
           (first-id (id-of reply))
           (second-id (id-of reply)))
      (ok first-id)
      (ok second-id)
      (ok (not (string= first-id second-id))
          (format nil "ids must not repeat across turns (~a)" first-id)))))

(deftest tool-call-without-a-name-is-dropped
  "A tool_calls entry with no function name was recorded with name NIL, produced
  an \"unknown tool NIL\" result, and was replayed as function.name = null."
  (let* ((r (agent-cl.llm:parse-chat-json
             "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"c1\",\"function\":{\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}")))
    (is-equal nil (agent-cl.llm:result-tool-calls r)
              "a nameless call cannot be dispatched, so it is not recorded"))
  ;; a normal call still parses
  (let* ((r (agent-cl.llm:parse-chat-json
             "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"c1\",\"function\":{\"name\":\"time.now\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}")))
    (is-equal "time.now" (agent-cl.messages:tool-call-name
                          (first (agent-cl.llm:result-tool-calls r))))))

(deftest ensure-tool-results-counts-per-call-not-per-id
  "With two calls sharing one id (a repeated provider id, or colliding synthesized
  ids), one result satisfied both by membership — leaving the illegal 1-result-for
  -2-calls sequence this function exists to prevent."
  (let ((agent (make-agent :transport (make-mock-transport) :tools nil)))
    (agent-cl.loop::remember
     agent (agent-cl.messages:assistant-message
            "" :tool-calls (list (make-tool-call "dup" "t.a" "{}")
                                 (make-tool-call "dup" "t.b" "{}"))))
    (agent-cl.loop::remember agent (agent-cl.messages:tool-result-message "dup" "ran"))
    (agent-cl.loop::ensure-tool-results agent "[placeholder]")
    (let ((results (remove-if-not
                    (lambda (m) (eq (agent-cl.messages:msg-role m) :tool))
                    (agent-messages agent))))
      (is-equal 2 (length results)
                "the second call needs its own result even though the id repeats"))))

;;; ---------------------------------------------------------------------------
;;; engine: empty answers, pauses, partial usage
;;; ---------------------------------------------------------------------------

(deftest empty-answer-is-not-a-completed-turn
  "An answer with no content and no tool calls was reported as done-p T with an
  empty final-content, which a caller cannot distinguish from a real answer."
  (dolist (payload '("" "   "))
    (let* ((tr (make-mock-transport
                :script (list (script-reply
                               (format nil "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":~s},\"finish_reason\":\"stop\"}],\"usage\":{\"total_tokens\":1}}"
                                       payload)))))
           (agent (make-agent :transport tr :tools nil
                              :policy (make-policy :max-steps 2)))
           (summary (run agent "hello")))
      (ok (not (done-p summary)) (format nil "~s must not count as an answer" payload))
      (is-equal :empty-answer (stop-reason summary)))))

(deftest pause-during-the-model-call-is-a-pause
  "An agent-pause raised while the request was in flight was reported as
  stop-reason :model-error, so a caller branching on stop-reason could not
  recognise a pause (the tool path reported :paused for the same condition)."
  (let* ((pausing (make-agent :transport (make-instance 'pause-transport)
                              :tools nil
                              :policy (make-policy :max-steps 2)))
         (summary (run pausing "hello")))
    (is-equal :paused (stop-reason summary))
    (ok (not (done-p summary)))
    (ok (search "paused" (or (guard-reason summary) "")))))

(defclass pause-transport (agent-cl.llm:transport) ())

(defmethod agent-cl.llm:perform-request ((tr pause-transport) params)
  (declare (ignore params))
  (error 'agent-cl.core:agent-pause :reason :user-interrupt))

(deftest partial-stream-usage-is-charged
  "A stream that reported usage and THEN dropped was charged by the provider, but
  the usage was discarded with the failed attempt — invisible to the cost view and
  to the max-tokens guard."
  (let* ((tr (make-mock-transport
              :script (list (script-stream
                             '("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}")))))
         (agent (make-agent :transport tr :tools nil
                            :policy (make-policy :max-steps 2)))
         (summary (run agent "hello" :stream t)))
    (ok (not (done-p summary)) "the stream never finished")
    (is-equal 15 (agent-usage-total agent)
              "the provider billed this request, so it must be counted")))
