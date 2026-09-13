;;;; tests/wire-hardening-tests.lisp — regression tests for the engine/transport audit.
;;;;
;;;; Scope: SSE parsing, the wire codec, dispatch pairing, retry policy, context
;;;; trimming, schema enforcement and log stream resolution. Each test names the
;;;; defect it locks down.
(in-package #:agent-cl.tests)

;;; ---------------------------------------------------------------------------
;;; SSE parsing
;;; ---------------------------------------------------------------------------

(deftest sse-done-variants
  "Only \"data: [DONE]\" was recognized. \"data:[DONE]\" (no space) fell through
  to the JSON decoder and killed the stream with a parse error."
  (dolist (line '("[DONE]" "data: [DONE]" "data:[DONE]" " data: [DONE] "
                  "data:  [DONE]" "DATA: [DONE]"))
    (is-equal :done (agent-cl.llm::sse-data-of-line line)
              (format nil "~s must mean done" line)))
  (is-equal :ignore (agent-cl.llm::sse-data-of-line ""))
  (is-equal :ignore (agent-cl.llm::sse-data-of-line "event: ping"))
  (is-equal "{\"a\":1}" (agent-cl.llm::sse-data-of-line "data: {\"a\":1}")))

(deftest sse-finalize-is-idempotent
  "STREAM-FINALIZE drains each tool-call argument output stream, so a second call
  used to return the same turn with EMPTY tool arguments."
  (let* ((tr (make-mock-transport
              :script (list (script-stream
                             '("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"t.a\",\"arguments\":\"{\\\"x\\\"\"}}]}}]}"
                               "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\":1}\"}}]}}]}"
                               "data: [DONE]")))))
         (turn (agent-cl.llm:perform-request tr '(:stream t))))
    (agent-cl.llm:stream-drain turn)
    (let* ((r1 (agent-cl.llm:stream-finalize turn))
           (r2 (agent-cl.llm:stream-finalize turn)))
      (is-equal "{\"x\":1}" (agent-cl.messages:tool-call-arguments
                             (first (agent-cl.llm:result-tool-calls r1))))
      (is-equal "{\"x\":1}" (agent-cl.messages:tool-call-arguments
                             (first (agent-cl.llm:result-tool-calls r2))))
      (ok (eq r1 r2) "the cached result is returned")))
  ;; a tool call that arrives at index 1 (gap at 0) must not be lost
  (let* ((tr (make-mock-transport
              :script (list (script-stream
                             '("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"c9\",\"function\":{\"name\":\"t.b\",\"arguments\":\"{}\"}}]}}]}"
                               "data: [DONE]")))))
         (turn (agent-cl.llm:perform-request tr '(:stream t))))
    (agent-cl.llm:stream-drain turn)
    (let ((r (agent-cl.llm:stream-finalize turn)))
      (is-equal 1 (length (agent-cl.llm:result-tool-calls r)))
      (is-equal "t.b" (agent-cl.messages:tool-call-name
                       (first (agent-cl.llm:result-tool-calls r)))))))

(deftest sse-synthesizes-a-missing-tool-call-id
  "An id of NIL breaks the wire contract: the tool result cannot reference its
  call and the provider rejects the follow-up request."
  (let* ((tr (make-mock-transport
              :script (list (script-stream
                             '("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"t.a\",\"arguments\":\"{}\"}}]}}]}"
                               "data: [DONE]")))))
         (turn (agent-cl.llm:perform-request tr '(:stream t))))
    (agent-cl.llm:stream-drain turn)
    (let ((tc (first (agent-cl.llm:result-tool-calls (agent-cl.llm:stream-finalize turn)))))
      (ok (agent-cl.messages:tool-call-id tc) "an id must be present"))))

;;; ---------------------------------------------------------------------------
;;; codec
;;; ---------------------------------------------------------------------------

(deftest codec-choice-without-message-is-an-error
  "A 2xx whose choice has no message object decoded to a turn with no content and
  no tool calls — i.e. a COMPLETED turn with an empty answer."
  (signals-error agent-cl.core:transport-error
    (agent-cl.llm:parse-chat-json
     "{\"choices\":[{\"finish_reason\":\"stop\"}]}"))
  (signals-error agent-cl.core:transport-error
    (agent-cl.llm:parse-chat-json "{\"choices\":[]}"))
  ;; a normal empty-content answer is still accepted (tool-call-only turns)
  (let ((r (agent-cl.llm:parse-chat-json
            "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":\"stop\"}]}")))
    (ok (typep r 'agent-cl.llm:turn-result))))

(deftest codec-detects-truncation
  "finish_reason \"length\" means the provider cut the answer off; presenting that
  as a complete answer silently drops the rest."
  (ok (agent-cl.llm:result-truncated-p
       (agent-cl.llm:parse-chat-json
        "{\"choices\":[{\"message\":{\"content\":\"half an ans\"},\"finish_reason\":\"length\"}]}")))
  (ok (not (agent-cl.llm:result-truncated-p
            (agent-cl.llm:parse-chat-json
             "{\"choices\":[{\"message\":{\"content\":\"done\"},\"finish_reason\":\"stop\"}]}")))))

;;; ---------------------------------------------------------------------------
;;; dispatch pairing + serial mode
;;; ---------------------------------------------------------------------------

(deftest dispatch-interrupt-keeps-tool-calls-paired
  "The assistant message is recorded before its tools run. If the dispatch loop
  unwinds (interrupt), the transcript keeps a tool_calls message with fewer
  results than calls — an illegal sequence that breaks every LATER request."
  (register-test-tool "test.pair" (lambda (args ctx)
                                    (declare (ignore args ctx))
                                    (values "ok" :ok))
                      nil)
  (unwind-protect
       (let* ((tr (make-mock-transport
                   :script (list (script-reply
                                  (reply-json "" (list (tc-json "c1" "test.pair" "{}")
                                                       (tc-json "c2" "test.pair" "{}")))))))
              (agent (make-agent :transport tr :tools '("test.pair")
                                 :policy (make-policy :max-steps 2))))
         ;; simulate "recorded the assistant message, then got interrupted"
         (agent-cl.loop::remember
          agent
          (agent-cl.messages:assistant-message
           "" :tool-calls (list (make-tool-call "c1" "test.pair" "{}")
                                (make-tool-call "c2" "test.pair" "{}"))))
         (agent-cl.loop::remember
          agent (agent-cl.messages:tool-result-message "c1" "ran"))
         (agent-cl.loop::ensure-tool-results agent "[中断]")
         (let* ((msgs (agent-messages agent))
                (calls (agent-cl.messages:msg-tool-calls
                        (find-if (lambda (m) (eq (agent-cl.messages:msg-role m) :assistant))
                                 msgs)))
                (results (remove-if-not
                          (lambda (m) (eq (agent-cl.messages:msg-role m) :tool))
                          msgs)))
           (dolist (tc calls)
             (ok (find (agent-cl.messages:tool-call-id tc) results
                       :key #'agent-cl.messages:msg-tool-call-id :test #'equal)
                 "every tool_call must have a matching tool result")))
         ;; idempotent: a second call adds nothing
         (let ((n (length (agent-messages agent))))
           (agent-cl.loop::ensure-tool-results agent "[中断]")
           (is-equal n (length (agent-messages agent)))))
    (unregister-tool "test.pair")))

(deftest serial-mode-does-not-silently-drop-tool-calls
  "With parallel-tools NIL only the first call ran, and the rest vanished from the
  transcript — the model's own decision disappeared without explanation."
  (register-test-tool "test.serial" (lambda (args ctx)
                                      (declare (ignore args ctx))
                                      (values "ran" :ok))
                      nil)
  (unwind-protect
       (let* ((tr (make-mock-transport
                   :script (list (script-reply
                                  (reply-json "" (list (tc-json "c1" "test.serial" "{}")
                                                       (tc-json "c2" "test.serial" "{}"))))
                                 (script-reply (reply-json "done" nil)))))
              (agent (make-agent :transport tr :tools '("test.serial")
                                 :policy (make-policy :max-steps 3
                                                      :parallel-tools nil)))
              (summary (run agent "两个工具")))
         (ok (done-p summary))
         (let* ((results (remove-if-not
                          (lambda (m) (eq (agent-cl.messages:msg-role m) :tool))
                          (agent-messages agent)))
                (ids (mapcar #'agent-cl.messages:msg-tool-call-id results)))
           (is-equal '("c1" "c2") (sort ids #'string<))
           (ok (search "串行" (or (agent-cl.messages:msg-content
                                   (second results)) ""))
               "the skipped call must say why it did not run")))
    (unregister-tool "test.serial")))

;;; ---------------------------------------------------------------------------
;;; retry policy
;;; ---------------------------------------------------------------------------

(deftest streaming-retry-does-not-replay-printed-tokens
  "A retry after tokens were already handed to the display would print the same
  text twice; the failure must be surfaced instead."
  (let* ((lines '("data: {\"choices\":[{\"delta\":{\"content\":\"部分\"}}]}"))
         (tr (make-mock-transport
              :script (list (script-stream lines)          ; dies mid-stream
                            (script-reply
                             (reply-json "SHOULD-NOT-BE-USED" nil)))))
         (seen nil)
         (agent (make-agent :transport tr :tools nil
                            :policy (make-policy :max-steps 3))))
    (let ((summary (run agent "stream" :stream t
                        :on-token (lambda (s) (push s seen)))))
      (ok (not (done-p summary)))
      (ok seen "the partial text reached the display")
      (is-equal 1 (length (agent-cl.llm:mock-script tr))
                "the retry script entry must NOT have been consumed"))))

(deftest retries-stop-when-the-agent-is-stopped
  "The backoff SLEPT through a stop: interrupting during a retry made the user
  wait out the whole delay (up to 8s)."
  (let* ((tr (make-mock-transport
              :script (list (script-error :status 503 :message "unavailable" :retryable t)
                            (script-reply (reply-json "never" nil)))))
         (agent (make-agent :transport tr :tools nil
                            :policy (make-policy :max-steps 2))))
    ;; a guard that stops the agent the moment it is consulted
    (let ((agent-cl.loop:*extra-guards* nil))
      (agent-cl.loop:register-guard "stopper"
                                    (lambda (a) (agent-cl.loop:stop a) nil))
      (let ((start (get-internal-real-time))
            (summary (run agent "retry me")))
        (ok (not (done-p summary)))
        (let ((elapsed (/ (- (get-internal-real-time) start)
                          (float internal-time-units-per-second 1.0))))
          (ok (< elapsed 1.5)
              (format nil "must not sleep out the backoff (took ~,1fs)" elapsed)))
        (ok (search "停止" (or (guard-reason summary) "")))))))

;;; ---------------------------------------------------------------------------
;;; context trimming
;;; ---------------------------------------------------------------------------

(deftest trim-does-not-pin-the-oldest-user-message
  "Trimming always kept (FIRST MSGS), which is the OLDEST USER MESSAGE when the
  agent has no system prompt — the exact message that should go first."
  (let* ((agent (make-agent :transport (make-mock-transport) :tools nil))
         (long (make-string 4000 :initial-element #\x)))
    (setf (agent-messages agent)
          (list (user-message (concatenate 'string "OLDEST-" long))
                (assistant-message "a1")
                (user-message (concatenate 'string "MIDDLE-" long))
                (assistant-message "a2")
                (user-message "NEWEST")))
    (setf (agent-context-budget agent) 1200)
    (let* ((msgs (choose-messages agent))
           (text (format nil "~{~a~}" (mapcar #'msg-content msgs))))
      (ok (search "NEWEST" text) "the newest turn survives")
      (ok (not (search "OLDEST-" text))
          "the oldest user message must be trimmed first when there is no system prompt")
      ;; whole turns only: no assistant message without its user message
      (is-equal :user (msg-role (first msgs))))))

(deftest trim-keeps-the-system-message
  (let* ((agent (make-agent :transport (make-mock-transport) :tools nil
                            :system "SYSTEM-PROMPT"))
         (long (make-string 4000 :initial-element #\y)))
    (setf (agent-messages agent)
          (list (user-message (concatenate 'string "OLD-" long))
                (user-message "NEW")))
    (setf (agent-context-budget agent) 1200)
    (let ((msgs (choose-messages agent)))
      (is-equal :system (msg-role (first msgs)))
      (is-equal "SYSTEM-PROMPT" (msg-content (first msgs)))
      (ok (search "NEW" (format nil "~{~a~}" (mapcar #'msg-content msgs)))))))

;;; ---------------------------------------------------------------------------
;;; schema enforcement
;;; ---------------------------------------------------------------------------

(deftest schema-array-items-are-validated
  "A property declared as an array of numbers accepted ANY element: :items was
  never consulted during property validation."
  (let* ((schema (make-schema :kind :object
                              :properties
                              (list (list "nums" :type :array
                                          :items (list :type :number))))))
    (is-equal nil (validate-json schema '(:nums (1 2 3))))
    (let ((problems (validate-json schema '(:nums (1 "two" 3)))))
      (ok problems "a string inside an array of numbers must be reported")
      (ok (some (lambda (p) (search "[1]" p)) problems)
          "the problem names the offending index"))
    (ok (validate-json schema '(:nums "not-an-array")))))

(deftest schema-required-works-with-string-keys
  "Required presence was checked with MEMBER :TEST EQ, so a decoded object with
  STRING keys reported every required property as missing."
  (let ((schema (make-schema :kind :object
                             :properties (list (list "task" :type :string))
                             :required '("task"))))
    (is-equal nil (validate-json schema '(:task "x")))
    ;; string keys: the same object, decoded with :string-keys t
    (is-equal nil (agent-cl.schema::validate-object
                   schema (list "task" "x") "" nil))
    (ok (agent-cl.schema::validate-object schema (list "other" "x") "" nil)
        "a genuinely missing required property is still reported")))

;;; ---------------------------------------------------------------------------
;;; tool dispatch error reporting
;;; ---------------------------------------------------------------------------

(deftest call-tool-lets-agent-pause-through
  "CALL-TOOL caught every condition, so a tool that pauses the agent (asking the
  user, hitting an interrupt) was converted into a meaningless :error string and
  the pause was lost. A pause is control flow, not a tool failure."
  (register-tool
   (make-tool "test.pause" (lambda (a c) (declare (ignore a c))
                             (error 'agent-cl.core:agent-pause :reason :needs-user))
              :description "pauses"))
  (unwind-protect
       (signals-error agent-cl.core:agent-pause
         (agent-cl.tools:call-tool "test.pause" nil))
    (unregister-tool "test.pause"))
  ;; an ordinary tool error is still converted into content + :error
  (register-tool
   (make-tool "test.boom" (lambda (a c) (declare (ignore a c))
                            (error "kaboom"))
              :description "raises"))
  (unwind-protect
       (multiple-value-bind (content status)
           (agent-cl.tools:call-tool "test.boom" nil)
         (is-equal :error status)
         (ok (search "kaboom" content)))
    (unregister-tool "test.boom")))

(deftest dispatch-does-not-misreport-tool-failures-as-argument-errors
  "One (error ...) clause wrapped argument parsing AND tool execution AND the
  audit check, so any failure inside was reported to the model as
  \"[tool arguments 解析失败]\" — a misleading diagnosis."
  (register-tool
   (make-tool "test.blame" (lambda (a c) (declare (ignore a c))
                             (error "inner failure"))
              :description "raises"))
  (unwind-protect
       (let* ((agent (make-agent :transport (make-mock-transport) :tools nil))
              (tc (make-tool-call "c1" "test.blame" "{}")))
         (multiple-value-bind (content status)
             (agent-cl.loop::dispatch-tool-call agent tc (agent-cl.loop:make-policy))
           (is-equal :error status)
           (ok (search "inner failure" content))
           (ok (not (search "arguments 解析失败" content))
               "a tool failure is not an argument-parse failure")))
    (unregister-tool "test.blame"))
  ;; a genuinely unparseable argument payload still reports as such
  (let* ((agent (make-agent :transport (make-mock-transport) :tools nil))
         (tc (make-tool-call "c1" "test.blame" "{not json")))
    (multiple-value-bind (content status)
        (agent-cl.loop::dispatch-tool-call agent tc (agent-cl.loop:make-policy))
      (is-equal :error status)
      (ok (search "arguments 解析失败" content)))))

;;; ---------------------------------------------------------------------------
;;; logging
;;; ---------------------------------------------------------------------------

(deftest log-output-follows-a-rebinding
  "*LOG-OUTPUT* captured *ERROR-OUTPUT* at LOAD time, so a caller who rebound
  *ERROR-OUTPUT* (the REPL does) still had logs written to the original stream."
  (let ((captured (make-string-output-stream)))
    (let ((agent-cl.core:*log-output* nil)
          (*error-output* captured))
      (agent-cl.core:log-info "hello ~a" "world"))
    (ok (search "hello world" (get-output-stream-string captured))))
  ;; an explicit stream still wins
  (let ((pinned (make-string-output-stream))
        (other (make-string-output-stream)))
    (let ((agent-cl.core:*log-output* pinned)
          (*error-output* other))
      (agent-cl.core:log-info "pinned"))
    (ok (search "pinned" (get-output-stream-string pinned)))
    (is-equal "" (get-output-stream-string other))))
