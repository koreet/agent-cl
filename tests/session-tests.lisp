;;;; tests/session-tests.lisp — session event log & pause/resume semantics.
(in-package #:agent-cl.tests)

(defun tmp-session-dir ()
  (format nil "~a/.tools/sessions-test"
          (string-right-trim '(#\/) (namestring (uiop:getcwd)))))

(deftest session-persist-and-replay-messages
  (let* ((dir (tmp-session-dir))
         (s (make-session :directory dir))
         (msgs (list (system-message "sys")
                     (user-message "你好")
                     (assistant-message "思考中"
                                        :tool-calls
                                        (list (make-tool-call "c1" "math.add" "{\"x\":1}")))))
         (sid (session-id s)))
    (dolist (m msgs) (persist-message s m))
    (save-checkpoint s "after-3")
    ;; reopen under the same id
    (let ((s2 (open-session sid :directory dir)))
      (is-equal sid (session-id s2))
      (let ((replayed (replayed-messages s2)))
        (is-equal 3 (length replayed))
        (is-equal :system (agent-cl.messages:msg-role (first replayed)))
        (is-equal "你好" (agent-cl.messages:msg-content (second replayed)))
        (let ((tc (first (agent-cl.messages:msg-tool-calls (third replayed)))))
          (is-equal "c1" (agent-cl.messages:tool-call-id tc))
          (is-equal "math.add" (agent-cl.messages:tool-call-name tc))))
      ;; events on disk are JSONL
      (let ((text (read-file-string (session-path s2))))
        (is-equal 4 (count #\Newline text))
        (ok (search "\"type\":\"message\"" text)))))
  ;; cleanup
  (uiop:delete-directory-tree (uiop:ensure-directory-pathname (tmp-session-dir)) :validate t :if-does-not-exist :ignore))

;;; a subclass that stops itself after the first tool result — simulating an
;;; interactive interrupt while the model keeps calling tools
(defclass pausable-agent (agent-cl.loop:agent) ())

(defmethod agent-cl.loop:on-tool-result ((a pausable-agent) tool-name result-plist)
  (declare (ignore result-plist))
  (when (string= tool-name "test.square")
    (agent-cl.loop:stop a)))

(deftest engine-pause-via-stop-hook
  (register-test-tool "test.square"
                      (lambda (args ctx)
                        (declare (ignore ctx))
                        (values "1" :ok))
                      (make-square-schema))
  (let* ((more-tools (reply-json "" (list (tc-json "c1" "test.square" "{\"x\":1}"))))
         (final (reply-json "done" nil))
         (tr (make-mock-transport :script (list (script-reply more-tools)
                                                (script-reply more-tools)
                                                (script-reply final))))
         (agent (make-instance 'pausable-agent
                               :transport tr
                               :tools '("test.square")
                               :policy (make-policy :max-steps 6)))
         (summary (run agent "跑起来然后我打断你")))
    (ok (not (done-p summary)))
    (is-equal :paused (guard-reason summary))
    ;; transcript already contains the executed tool round
    (ok (find :tool (mapcar (lambda (m) (agent-cl.messages:msg-role m))
                            (agent-messages agent)))))
  (unregister-tool "test.square"))

(deftest session-roundtrip-preserves-paused-transcript
  ;; persist a real run's transcript, reload, and continue with a fresh agent
  (register-test-tool "test.square"
                      (lambda (args ctx)
                        (declare (ignore ctx))
                        (values "16" :ok))
                      (make-square-schema))
  (let* ((dir (tmp-session-dir))
         (s (make-session :directory dir))
         (tr (make-mock-transport
              :script (list (script-reply
                             (reply-json "" (list (tc-json "c1" "test.square" "{\"x\":4}"))))
                            (script-reply (reply-json "16 的平方" nil)))))
         (agent (make-agent :transport tr :tools '("test.square")
                            :policy (make-policy :max-steps 4)))
         (summary (run agent "算 4 的平方")))
    (ok (done-p summary))
    (dolist (m (agent-messages agent)) (persist-message s m))
    ;; continue in a fresh session over the same id with the replayed history
    (let* ((s2 (open-session (session-id s) :directory dir))
           (history (replayed-messages s2))
           (tr2 (make-mock-transport
                 :script (list (script-reply (reply-json "好的，已经知道了" nil)))))
           (agent2 (make-agent :transport tr2 :tools '("test.square")
                               :policy (make-policy :max-steps 4)
                               :messages history))
           (summary2 (run agent2 "继续")))
      (ok (done-p summary2))
      (ok (search "已经知道了" (final-content summary2)))
      ;; the resumed conversation carries the full prior transcript
      (is-equal (+ (length history) 2) (length (agent-messages agent2)))))
  (unregister-tool "test.square")
  (uiop:delete-directory-tree (uiop:ensure-directory-pathname (tmp-session-dir)) :validate t :if-does-not-exist :ignore))
