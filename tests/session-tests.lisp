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
    (is-equal :paused (stop-reason summary))
    (ok (search "中断" (guard-reason summary)))
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


;;;; resolve-session-choice (pure picker logic) --------------------------
(deftest session-choose-by-index
  (let ((ids '("aaaa-1111" "bbbb-2222" "cccc-3333")))
    (multiple-value-bind (id st) (agent-cl.session:resolve-session-choice "2" ids)
      (is-equal "bbbb-2222" id) (is-equal :ok st))
    (multiple-value-bind (id st) (agent-cl.session:resolve-session-choice "1" ids)
      (is-equal "aaaa-1111" id) (is-equal :ok st))))

(deftest session-choose-out-of-range
  (let ((ids '("aaaa-1111" "bbbb-2222")))
    (multiple-value-bind (id st) (agent-cl.session:resolve-session-choice "5" ids)
      (is-equal nil id) (is-equal :out-of-range st))
    (multiple-value-bind (id st) (agent-cl.session:resolve-session-choice "0" ids)
      (is-equal nil id) (is-equal :out-of-range st))))

(deftest session-choose-by-full-id
  (let ((ids '("aaaa-1111" "bbbb-2222")))
    (multiple-value-bind (id st) (agent-cl.session:resolve-session-choice "aaaa-1111" ids)
      (is-equal "aaaa-1111" id) (is-equal :ok st))))

(deftest session-choose-by-prefix
  (let ((ids '("aaaa-1111" "bbbb-2222" "ab99-0000")))
    (multiple-value-bind (id st) (agent-cl.session:resolve-session-choice "bbbb" ids)
      (is-equal "bbbb-2222" id) (is-equal :ok st))))

(deftest session-choose-ambiguous-prefix
  (let ((ids '("aaaa-1111" "aabb-2222")))
    (multiple-value-bind (id st) (agent-cl.session:resolve-session-choice "aa" ids)
      (is-equal nil id) (is-equal :ambiguous st))))

(deftest session-choose-blank-and-nomatch
  (let ((ids '("aaaa-1111")))
    (multiple-value-bind (id st) (agent-cl.session:resolve-session-choice "" ids)
      (is-equal nil id) (is-equal :none st))
    (multiple-value-bind (id st) (agent-cl.session:resolve-session-choice "zzz" ids)
      (is-equal nil id) (is-equal :none st))))


;;;; conversation replay helpers (pure) ----------------------------------
(deftest session-conversation-entries-filters-tools
  (let ((msgs (list (agent-cl.messages:user-message "hi")
                    (agent-cl.messages:assistant-message "hello")
                    (agent-cl.messages:tool-result-message "c1" "tool out")
                    (agent-cl.messages:user-message "again"))))
    (let ((e (agent-cl.session:conversation-entries msgs)))
      ;; tool message dropped -> 3 entries, roles preserved in order
      (is-equal 3 (length e))
      (is-equal '(:user :assistant :user) (mapcar #'car e))
      (is-equal "hi" (cdr (first e))))))

(deftest session-conversation-entries-drops-empty-assistant
  ;; an assistant message that carried only tool_calls (blank text) is dropped
  (let ((msgs (list (agent-cl.messages:user-message "q")
                    (agent-cl.messages:assistant-message ""))))   ; no content
    (is-equal 1 (length (agent-cl.session:conversation-entries msgs)))))

(deftest session-last-turns-takes-tail
  (let ((msgs (loop for i from 1 to 10
                    collect (agent-cl.messages:user-message (format nil "m~a" i)))))
    (let ((tail (agent-cl.session:last-conversation-turns msgs 3)))
      (is-equal 3 (length tail))
      (is-equal "m8"  (cdr (first tail)))
      (is-equal "m10" (cdr (third tail))))))

(deftest session-last-turns-nil-means-all
  (let ((msgs (list (agent-cl.messages:user-message "a")
                    (agent-cl.messages:user-message "b"))))
    (is-equal 2 (length (agent-cl.session:last-conversation-turns msgs nil)))))
