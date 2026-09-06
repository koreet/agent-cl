;;;; tests/codec-tests.lisp — message envelope <-> wire round trips.
(in-package #:agent-cl.tests)

(deftest encode-user-and-system-messages
  (let* ((wire (encode-message-wire (system-message "你是助手")))
         (json (json-encode wire)))
    (ok (search "\"role\":\"system\"" json))
    (ok (search "你是助手" json)))
  (let* ((wire (encode-message-wire (user-message "hi")))
         (json (json-encode wire)))
    (ok (search "\"role\":\"user\"" json))))

(deftest encode-assistant-with-tool-calls
  (let* ((tc (make-tool-call "call_1" "shell.run" "{\"cmd\":\"pwd\"}"))
         (wire (encode-message-wire (assistant-message "" :tool-calls (list tc))))
         (json (json-encode wire)))
    (ok (search "\"tool_calls\"" json))
    (ok (search "\"call_1\"" json))
    (ok (search "\"shell.run\"" json))
    (ok (search "{\\\"cmd\\\":\\\"pwd\\\"}" json))))

(deftest encode-tool-result-message
  (let* ((wire (encode-message-wire (tool-result-message "call_1" "drwxr-xr-x")))
         (json (json-encode wire)))
    (ok (search "\"role\":\"tool\"" json))
    (ok (search "\"tool_call_id\":\"call_1\"" json))))

(deftest request-body-assembly
  (let* ((json (encode-request-json
                (list :model "deepseek-chat"
                      :messages (list (system-message "sys") (user-message "u"))
                      :stream t)))
         (back (json-decode json)))
    (is-equal "deepseek-chat" (gethash "model" back))
    (ok (gethash "stream" back))
    (is-equal 2 (length (gethash "messages" back)))
    (ok (gethash "stream_options" back))))

(deftest parse-non-stream-completion
  (let* ((json "{\"id\":\"x\",\"object\":\"chat.completion\",\"choices\":[{\"index\":0,
             \"message\":{\"role\":\"assistant\",\"content\":null,
             \"tool_calls\":[{\"id\":\"call_9\",\"type\":\"function\",
             \"function\":{\"name\":\"time.now\",\"arguments\":\"{}\"}}]},
             \"finish_reason\":\"tool_calls\"}],
             \"usage\":{\"prompt_tokens\":12,\"completion_tokens\":3,\"total_tokens\":15}}")
         (result (parse-chat-json json)))
    (is-equal "tool_calls" (result-finish-reason result))
    (is-equal 1 (length (result-tool-calls result)))
    (let ((tc (first (result-tool-calls result))))
      (is-equal "call_9" (tool-call-id tc))
      (is-equal "time.now" (tool-call-name tc)))
    (is-equal 12 (usage-prompt-tokens (result-usage result)))
    (is-equal 15 (usage-total-tokens (result-usage result)))))

(deftest mock-transport-single-reply
  (let* ((reply "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"你好\",
                   \"tool_calls\":null},\"finish_reason\":\"stop\"}],\"usage\":{}}")
         (tr (make-mock-transport :script (list (script-reply reply))))
         (result (complete-turn tr (list :model "m" :messages (list (user-message "嗨"))))))
    (is-equal "你好" (result-content result))
    (is-equal "stop" (result-finish-reason result))))

(deftest mock-transport-exhausted-raises
  (let ((tr (make-mock-transport :script nil)))
    (signals-error transport-error
      (complete-turn tr (list :messages (list (user-message "x")))))))
