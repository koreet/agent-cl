;;;; tests/sse-tests.lisp — SSE line parsing and stream accumulation.
(in-package #:agent-cl.tests)

(deftest sse-content-stream
  (let ((turn (make-instance 'streaming-turn)))
    (is-equal :ok (stream-feed turn "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"你好\"}}]}\n"))
    (is-equal :ok (stream-feed turn "data: {\"choices\":[{\"delta\":{\"content\":\"世界\"}}]}\n"))
    (is-equal :done (stream-feed turn "data: [DONE]"))
    (ok (stream-finished-p turn))
    (is-equal "你好世界" (stream-text turn))))

(deftest sse-split-tool-call-arguments
  "Tool-call arguments arrive split across chunks: accumulate per index and
  parse only at the end."
  (let ((turn (make-instance 'streaming-turn))
        (chunks
          (list
           "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":null}}]}"
           "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_7\",\"type\":\"function\",\"function\":{\"name\":\"shell.run\",\"arguments\":\"\"}}]}}]}"
           "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"cmd\\\":\\\"ls\"}}]}}]}"
           "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\" -la\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}"
           "data: [DONE]")))
    (dolist (c chunks) (stream-feed turn c))
    (ok (stream-finished-p turn))
    (let* ((final (stream-finalize turn))
           (tcs (result-tool-calls final))
           (tc (first tcs)))
      (is-equal 1 (length tcs))
      (is-equal "call_7" (tool-call-id tc))
      (is-equal "shell.run" (tool-call-name tc))
      (is-equal "{\"cmd\":\"ls -la\"}" (tool-call-arguments tc))
      ;; parsed plist via lazy accessor
      (is-equal "ls -la" (getf (tool-call-arguments-plist tc) :CMD))
      (is-equal "tool_calls" (result-finish-reason final)))))

(deftest sse-usage-collected
  (let ((turn (make-instance 'streaming-turn)))
    (stream-feed turn "data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":1,\"total_tokens\":6}}")
    (is-equal 5 (usage-prompt-tokens (stream-usage turn)))))

(deftest mock-transport-stream-scenario
  (let* ((lines '("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"流\"}}]}"
                  "data: {\"choices\":[{\"delta\":{\"content\":\"式\"}}]}"
                  "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"
                  "data: [DONE]"))
         (tr (make-mock-transport :script (list (script-stream lines))))
         (result (complete-turn tr (list :model "m" :messages nil :stream t))))
    (is-equal "流式" (result-content result))
    (is-equal "stop" (result-finish-reason result))))

(deftest sse-parallel-tool-calls-two-indexes
  (let ((turn (make-instance 'streaming-turn))
        (chunks
          (list
           "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a1\",\"function\":{\"name\":\"t1\",\"arguments\":\"{\\\"x\\\":1}\"}},{\"index\":1,\"id\":\"a2\",\"function\":{\"name\":\"t2\",\"arguments\":\"{\\\"y\\\":2}\"}}]}}]}"
           "data: [DONE]")))
    (dolist (c chunks) (stream-feed turn c))
    (let* ((final (stream-finalize turn))
           (tcs (result-tool-calls final)))
      (is-equal 2 (length tcs))
      (is-equal "t1" (tool-call-name (first tcs)))
      (is-equal "t2" (tool-call-name (second tcs)))
      (is-equal 2 (getf (tool-call-arguments-plist (second tcs)) :Y)))))
