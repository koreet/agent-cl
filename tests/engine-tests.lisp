;;;; tests/engine-tests.lisp — ReAct engine integration tests over mock transport.
(in-package #:agent-cl.tests)

;;; ---------------------------------------------------------------------------
;;; helpers: craft deterministic provider replies
;;; ---------------------------------------------------------------------------

(defun tc-json (id name arguments)
  (let ((tc (make-hash-table :test 'equal))
        (fn (make-hash-table :test 'equal)))
    (setf (gethash "id" tc) id
          (gethash "type" tc) "function"
          (gethash "name" fn) name
          (gethash "arguments" fn) arguments
          (gethash "function" tc) fn)
    tc))

(defun reply-json (content tool-calls &optional (finish nil))
  (let ((root (make-hash-table :test 'equal))
        (msg (make-hash-table :test 'equal))
        (usage (make-hash-table :test 'equal)))
    (setf (gethash "role" msg) "assistant"
          (gethash "content" msg) (or content ""))
    (when tool-calls (setf (gethash "tool_calls" msg) tool-calls))
    (let ((ch (make-hash-table :test 'equal)))
      (setf (gethash "index" ch) 0
            (gethash "message" ch) msg
            (gethash "finish_reason" ch) (or finish
                                             (if tool-calls "tool_calls" "stop")))
      (setf (gethash "choices" root) (list ch)))
    (setf (gethash "usage" root) usage)
    (setf (gethash "prompt_tokens" usage) 10
          (gethash "completion_tokens" usage) 5
          (gethash "total_tokens" usage) 15)
    (json-encode root)))

(defun register-test-tool (name fn schema)
  (agent-cl.tools:register-tool
   (agent-cl.tools:make-tool name fn :description "test tool" :parameters schema)))

(defun make-square-schema ()
  (agent-cl.schema:make-schema
   :kind :object
   :properties '(("x" (:type :number :description "数值")))
   :required '("x")))

(deftest engine-single-tool-roundtrip
  (register-test-tool "test.square"
                      (lambda (args ctx)
                        (declare (ignore ctx))
                        (values (format nil "~a" (* (getf args :X) (getf args :X))) :ok))
                      (make-square-schema))
  (let* ((tr (make-mock-transport
              :script (list (script-reply (reply-json ""
                                                    (list (tc-json "c1" "test.square" "{\"x\":4}"))))
                            (script-reply (reply-json "4 的平方是 16" nil)))))
         (agent (make-agent :transport tr :tools '("test.square")
                            :policy (make-policy :max-steps 6)))
         (summary (run agent "4 的平方是多少？")))
    (ok (done-p summary))
    (is-equal 2 (steps summary))
    (is-equal 1 (turn-summary-tool-count summary))
    (ok (search "16" (final-content summary)))
    ;; transcript roles: user, assistant(tool_calls), tool, assistant(final)
    (is-equal '(:user :assistant :tool :assistant)
              (mapcar (lambda (m) (agent-cl.messages:msg-role m))
                      (agent-messages agent))))
  (unregister-tool "test.square"))

(deftest engine-parallel-tool-calls
  (register-test-tool "test.square"
                      (lambda (args ctx)
                        (declare (ignore ctx))
                        (values (format nil "~a" (* (getf args :X) (getf args :X))) :ok))
                      (make-square-schema))
  (let* ((tr (make-mock-transport
              :script (list (script-reply
                             (reply-json ""
                                         (list (tc-json "c1" "test.square" "{\"x\":2}")
                                               (tc-json "c2" "test.square" "{\"x\":3}"))))
                            (script-reply (reply-json "结果是 4 和 9" nil)))))
         (agent (make-agent :transport tr :tools '("test.square")
                            :policy (make-policy :max-steps 6 :parallel-tools t)))
         (summary (run agent "算 2 和 3 的平方")))
    (ok (done-p summary))
    (is-equal 2 (steps summary))
    (is-equal 2 (turn-summary-tool-count summary))
    (ok (search "4 和 9" (final-content summary)))
    (is-equal '(:user :assistant :tool :tool :assistant)
              (mapcar (lambda (m) (agent-cl.messages:msg-role m))
                      (agent-messages agent))))
  (unregister-tool "test.square"))

(deftest engine-validation-error-then-model-retries
  "First model call passes invalid args (missing required x); engine replies
  with a validation error observation and the (mock) model corrects itself."
  (register-test-tool "test.square"
                      (lambda (args ctx)
                        (declare (ignore ctx))
                        (values (format nil "~a" (* (getf args :X) (getf args :X))) :ok))
                      (make-square-schema))
  (let* ((tr (make-mock-transport
              :script (list (script-reply (reply-json "" (list (tc-json "c1" "test.square" "{}"))))
                            (script-reply (reply-json "" (list (tc-json "c2" "test.square" "{\"x\":5}"))))
                            (script-reply (reply-json "25" nil)))))
         (agent (make-agent :transport tr :tools '("test.square")
                            :policy (make-policy :max-steps 8)))
         (summary (run agent "算 5 的平方")))
    (ok (done-p summary))
    (is-equal 3 (steps summary))
    ;; the first tool result message must carry the validation complaint
    (let ((tool-msgs (remove-if-not
                      (lambda (m) (eq (agent-cl.messages:msg-role m) :tool))
                      (agent-messages agent))))
      (ok (search "参数校验失败" (agent-cl.messages:msg-content (first tool-msgs))))))
  (unregister-tool "test.square"))

(deftest engine-max-steps-guard
  (register-test-tool "test.square"
                      (lambda (args ctx)
                        (declare (ignore ctx))
                        (values "1" :ok))
                      (make-square-schema))
  (let* ((always-tool (reply-json "" (list (tc-json "c1" "test.square" "{\"x\":1}"))))
         (tr (make-mock-transport :script (list (script-reply always-tool)
                                                (script-reply always-tool))))
         (agent (make-agent :transport tr :tools '("test.square")
                            :policy (make-policy :max-steps 2)))
         (summary (run agent "无限循环任务")))
    (ok (not (done-p summary)))
    (is-equal :max-steps (guard-reason summary))
    (is-equal 2 (steps summary)))
  (unregister-tool "test.square"))

(deftest engine-unknown-tool-observation
  (let* ((tr (make-mock-transport
              :script (list (script-reply (reply-json ""
                                                      (list (tc-json "c1" "no.such.tool" "{}"))))
                            (script-reply (reply-json "好的" nil)))))
         (agent (make-agent :transport tr :tools nil
                            :policy (make-policy :max-steps 5)))
         (summary (run agent "调用一个不存在的工具")))
    (ok (done-p summary))
    (let ((tool-msgs (remove-if-not
                      (lambda (m) (eq (agent-cl.messages:msg-role m) :tool))
                      (agent-messages agent))))
      (ok (search "unknown tool" (agent-cl.messages:msg-content (first tool-msgs)))))))

(deftest engine-streaming-text-and-tokens
  (let* ((lines '("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"流\"}}]}"
                  "data: {\"choices\":[{\"delta\":{\"content\":\"式\"}}]}"
                  "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"
                  "data: [DONE]"))
         (tr (make-mock-transport :script (list (script-stream lines))))
         (agent (make-agent :transport tr :tools nil
                            :policy (make-policy :max-steps 3)))
         (tokens nil)
         (summary (run agent "流式输出测试" :stream t
                       :on-token (lambda (t1) (push t1 tokens)))))
    (ok (done-p summary))
    (is-equal "流式" (final-content summary))
    (is-equal "流式" (apply #'concatenate 'string (nreverse tokens)))
    (is-equal 1 (steps summary))))

(deftest engine-memory-window
  (let ((m (make-instance 'agent-cl.loop:memory)))
    (dotimes (i 5) (memory-add m (user-message (format nil "m~a" i))))
    (is-equal 5 (length (memory-window m)))
    (is-equal "m4" (agent-cl.messages:msg-content (first (memory-window m 1))))
    (is-equal "m3" (agent-cl.messages:msg-content (first (memory-window m 2))))))

(deftest builtin-tools-register-and-call
  (let ((names (register-builtin-tools)))
    (ok (member "shell.run" names :test #'string=))
    (ok (member "file.write" names :test #'string=))
    (ok (member "time.now" names :test #'string=))
    (multiple-value-bind (content status)
        (agent-cl.tools:call-tool "time.now" nil)
      (is-equal :ok status)
      (ok (> (length content) 15)))
    (let ((p (format nil "~a/.tools/tmp-engine-file.txt" (namestring (uiop:getcwd)))))
      (multiple-value-bind (c1 s1)
          (agent-cl.tools:call-tool "file.write" (list :PATH p :CONTENT "引擎测试"))
        (is-equal :ok s1)
        (ok (search "wrote" c1)))
      (multiple-value-bind (c2 s2)
          (agent-cl.tools:call-tool "file.read" (list :PATH p))
        (is-equal :ok s2)
        (is-equal "引擎测试" c2))
      (ignore-errors (delete-file p))))
  (dolist (n '("shell.run" "file.read" "file.write" "time.now"))
    (unregister-tool n)))


;;; ---------------------------------------------------------------------------
;;; M5: memory budget — window and token trimming feed the real request
;;; ---------------------------------------------------------------------------

(defclass recording-agent (agent-cl.loop:agent)
  ((calls :initform nil :accessor rec-calls)))

(defmethod agent-cl.loop:before-llm-call ((a recording-agent) params)
  (push (length (getf params :messages)) (rec-calls a)))

(defun seed-conversation (agent n)
  (let (msgs)
    (dotimes (i n)
      (push (user-message (format nil "旧消息 ~a" i)) msgs))
    (setf (agent-messages agent) (nreverse msgs))))

(deftest memory-window-limits-context
  (let* ((tr (make-mock-transport
              :script (list (script-reply (reply-json "done" nil)))))
         (agent (make-instance 'recording-agent
                               :transport tr :tools nil
                               :system "sys"
                               :max-history 3
                               :policy (make-policy :max-steps 2))))
    (seed-conversation agent 8)
    (let ((summary (run agent "新任务")))
      (ok (done-p summary))
      (let ((first-call (first (rec-calls agent))))
        ;; system + most recent 3 messages (incl. the new task)
        (is-equal 4 first-call)))))

(deftest memory-token-budget-trims-long-history
  (let* ((tr (make-mock-transport
              :script (list (script-reply (reply-json "done" nil)))))
         (long (make-string 400 :initial-element #\a))  ; ~100 approx tokens each
         (agent (make-instance 'recording-agent
                               :transport tr :tools nil
                               :context-budget 120
                               :policy (make-policy :max-steps 2))))
    (setf (agent-messages agent)
          (loop repeat 6 collect (user-message long)))
    (run agent "简短任务")
    (let ((first-call (first (rec-calls agent))))
      (ok (< first-call 6))
      (ok (>= first-call 2)))))


;;; ---------------------------------------------------------------------------
;;; code.exec: the agent writes + runs code (self-hosting loop)
;;; ---------------------------------------------------------------------------

(deftest code-exec-python-runs-code
  (agent-cl.tools:register-builtin-tools)
  (multiple-value-bind (content status)
      (agent-cl.tools:call-tool "code.exec"
                                (list :CODE "print(6 * 7)" :LANGUAGE "python"))
    (is-equal :ok status)
    (ok (search "42" content))))

(deftest code-exec-sbcl-runs-lisp
  (multiple-value-bind (content status)
      (agent-cl.tools:call-tool "code.exec"
                                (list :CODE "(format t \"~a\" (* 6 7))"
                                      :LANGUAGE "sbcl"))
    (is-equal :ok status)
    (ok (search "42" content))))

(deftest code-exec-errors-surface
  (multiple-value-bind (content status)
      (agent-cl.tools:call-tool "code.exec"
                                (list :CODE "print(undefined_name(" :LANGUAGE "python"))
    (is-equal :error status)
    (ok (search "exit" content))))

(deftest code-exec-engine-roundtrip-mock
  ;; model asks for code, engine dispatches code.exec, result fed back to model
  (agent-cl.tools:register-builtin-tools)
  (let* ((tr (make-mock-transport
              :script (list (script-reply
                             (reply-json ""
                                         (list (tc-json "c1" "code.exec"
                                                        "{\"language\":\"python\",\"code\":\"print(2**10)\"}"))))
                            (script-reply (reply-json "结果是 1024" nil)))))
         (agent (make-agent :transport tr :tools '("code.exec")
                            :policy (make-policy :max-steps 4)))
         (summary (run agent "帮我算 2 的 10 次方，写代码执行")))
    (ok (done-p summary))
    (ok (search "1024" (final-content summary)))
    (let ((tool-msgs (remove-if-not
                      (lambda (m) (eq (agent-cl.messages:msg-role m) :tool))
                      (agent-messages agent))))
      (ok (search "1024" (agent-cl.messages:msg-content (first tool-msgs)))))))

(deftest code-exec-cleanup
  (dolist (n '("code.exec" "shell.run" "file.read" "file.write" "time.now"))
    (unregister-tool n)))




;;; ---------------------------------------------------------------------------
;;; task.delegate: parent delegates to an independent child session
;;; ---------------------------------------------------------------------------

(deftest delegate-child-returns-conclusion-only
  "Child runs a separate short session; only its conclusion lands in the
  parent transcript (token saver)."
  (agent-cl.tools:register-builtin-tools)
  (let* ((tr (make-mock-transport
              :script (list
                       ;; 1) parent asks to delegate (child needs no tools)
                       (script-reply
                        (reply-json ""
                                    (list (tc-json "c1" "task.delegate"
                                                   "{\"task\":\"请只回答 40+2 的答案\",\"tools\":[]}"))))
                       ;; 2) child answers directly
                       (script-reply (reply-json "42" nil))
                       ;; 3) parent concludes
                       (script-reply (reply-json "子agent 告诉我 42" nil)))))
         (agent (make-agent :transport tr :tools '("task.delegate")
                            :policy (make-policy :max-steps 6)))
         (summary (run agent "派个子 agent 算一下 40+2")))
    (ok (done-p summary))
    (ok (search "42" (final-content summary)))
    (let ((roles (mapcar (lambda (m) (agent-cl.messages:msg-role m))
                         (agent-messages agent))))
      (is-equal '(:user :assistant :tool :assistant) roles)))
  (unregister-tool "task.delegate"))

(deftest delegate-child-can-use-inherited-tools
  "Child explicitly inherits a compute tool; parent still only sees conclusion."
  (agent-cl.tools:register-builtin-tools)
  (agent-cl.tools:register-tool
   (agent-cl.tools:make-tool "test.square"
                             (lambda (a ctx)
                               (declare (ignore ctx))
                               (values (format nil "~a" (* (getf a :X) (getf a :X))) :ok))
                             :description "square"
                             :parameters (make-square-schema)))
  (let* ((tr (make-mock-transport
              :script (list
                       (script-reply
                        (reply-json "" (list (tc-json "c1" "task.delegate"
                                                      "{\"task\":\"算 6 的平方并报告\",\"tools\":[\"test.square\"]}"))))
                       (script-reply (reply-json "" (list (tc-json "c2" "test.square" "{\"x\":6}"))))
                       (script-reply (reply-json "36" nil))
                       (script-reply (reply-json "子agent 报告结果是 36" nil)))))
         (agent (make-agent :transport tr :tools '("task.delegate")
                            :policy (make-policy :max-steps 6)))
         (summary (run agent "派个子 agent 帮我算 6 的平方")))
    (ok (done-p summary))
    (ok (search "36" (final-content summary))))
  (unregister-tool "task.delegate")
  (unregister-tool "test.square"))

(deftest delegate-rejects-nesting-by-default
  (agent-cl.tools:register-builtin-tools)
  (let* ((tr (make-mock-transport
              :script (list (script-reply
                             (reply-json ""
                                         (list (tc-json "c1" "task.delegate"
                                                        "{\"task\":\"跑一下\",\"tools\":[\"task.delegate\"]}"))))
                            (script-reply (reply-json "child-done" nil))
                            (script-reply (reply-json "ok 完成" nil)))))
         (agent (make-agent :transport tr :tools '("task.delegate")
                            :policy (make-policy :max-steps 5)))
         (summary (run agent "委派一个子 agent 做事")))
    (ok (done-p summary))
    (ok (search "完成" (final-content summary))))
  (unregister-tool "task.delegate"))


;;; ---------------------------------------------------------------------------
;;; memory.set / memory.recall
;;; ---------------------------------------------------------------------------

(deftest memory-tools-set-and-recall
  (agent-cl.tools:register-builtin-tools)
  (multiple-value-bind (c1 s1)
      (agent-cl.tools:call-tool "memory.set" (list :KEY "utest" :VALUE "hello 42"))
    (is-equal :ok s1)
    (ok (search "utest" c1)))
  (multiple-value-bind (c2 s2)
      (agent-cl.tools:call-tool "memory.recall" (list :KEY "utest"))
    (is-equal :ok s2)
    (ok (search "hello 42" c2)))
  (multiple-value-bind (c3 s3)
      (agent-cl.tools:call-tool "memory.recall" (list :KEY "no-such-key-xyz"))
    (is-equal :error s3))
  ;; 清理测试记忆文件
  (let* ((home (or (uiop:getenv "USERPROFILE") (uiop:getenv "HOME")))
         (f (merge-pathnames ".agent-cl/memory/utest.json"
                             (uiop:ensure-directory-pathname home))))
    (ignore-errors (delete-file f)))
  (dolist (n '("memory.set" "memory.recall"))
    (unregister-tool n)))


;;; ---------------------------------------------------------------------------
;;; web.search（注册 + 无 dexador 的确定性错误路径；真实检索需可联网环境）
;;; ---------------------------------------------------------------------------

(deftest web-search-registered-and-errors-without-http
  (agent-cl.tools:register-builtin-tools)
  (ok (find-tool "web.search"))
  ;; 测试环境未加载 dexador → 明确报错而非崩溃
  (multiple-value-bind (content status)
      (agent-cl.tools:call-tool "web.search" (list :QUERY "test"))
    (is-equal :error status)
    (ok (search "dexador" content)))
  (unregister-tool "web.search"))
