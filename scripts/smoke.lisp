;;;; scripts/smoke.lisp — M6 real-API smoke test (DeepSeek, OpenAI-compatible).
;;;;
;;;; The sandbox has no in-Lisp TLS, so the *http-fetch-hook* delegates the HTTP
;;;; call to scripts/http-request.js (node/OpenSSL). Everything else — request
;;;; assembly, response parsing, the ReAct loop, tool dispatch, structured
;;;; summaries — runs through the real agent-cl pipeline.
;;;;
;;;; Run (repo root, with a key exported):
;;;;   $env:AGENT_CL_API_KEY = "sk-..."
;;;;   SBCL_HOME=.tools/sbcl XDG_CACHE_HOME=.tools/cache ^
;;;;     .tools/sbcl/sbcl.exe --script scripts/smoke.lisp
(in-package #:cl-user)

(require :asdf)

;; Optional: if a Quicklisp install exists, load it so dependencies resolve on
;; standard networked machines (vendored .tools/deps is only used otherwise).
(handler-case
    (let* ((home (or (uiop:getenv "USERPROFILE") (uiop:getenv "HOME")))
           (setup (and home (merge-pathnames "quicklisp/setup.lisp"
                                  (uiop:ensure-directory-pathname home)))))
      (when (and setup (uiop:file-exists-p setup))
        (load setup)
        (format t "~&[bootstrap] quicklisp loaded from ~a~%" setup)))
  (error (e)
    (format t "~&[bootstrap] quicklisp unavailable: ~a~%" e)))

(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname *load-truename*)))
(asdf:initialize-source-registry
 `(:source-registry
   (:tree ,(uiop:subpathname *root* ".tools/deps/"))
   (:tree ,(uiop:subpathname *root* ".tools/sbcl/contrib/"))
   :ignore-inherited-configuration))
(pushnew *root* asdf:*central-registry* :test #'equal)

;; Quicklisp dist systems only become visible to ASDF after a ql:quickload,
;; so prime the four project dependencies first (runtime-resolved symbols).
(handler-case
    (let ((q (find-package "QL")))
      (when q
        (let ((quickload (find-symbol "QUICKLOAD" q)))
          (when quickload
            (funcall quickload '(:alexandria :yason :split-sequence :bordeaux-threads)
                     :silent t)
            (format t "~&[bootstrap] deps quickloaded~%")))))
  (error (e)
    (format t "~&[bootstrap] deps quickload failed: ~a~%" e)))

(asdf:load-system :agent-cl)
(agent-cl.tools:register-builtin-tools)

(defparameter *api-base* "https://api.deepseek.com/v1")
(defparameter *tmp* (uiop:ensure-directory-pathname
                     (uiop:subpathname *root* ".tools/tmp/")))

(defun node-request (request-json &key base-url api-key timeout stream)
  "Node-based *http-fetch-hook* implementation (non-streaming)."
  (declare (ignore api-key timeout))
  (when stream
    (error "node hook is non-streaming"))
  (let* ((n (format nil "~d" (get-universal-time)))
         (req (merge-pathnames (format nil "smoke-~a-req.json" n) *tmp*))
         (res (merge-pathnames (format nil "smoke-~a-res.json" n) *tmp*))
         (meta (merge-pathnames (format nil "smoke-~a-meta.txt" n) *tmp*)))
    (ensure-directories-exist *tmp*)
    (agent-cl.core:write-file-string req request-json)
    (let ((node (namestring (uiop:subpathname *root* "scripts/http-request.js"))))
      (multiple-value-bind (out err exit)
          (uiop:run-program
           (list "node" node
                 "--url" (concatenate 'string base-url "/chat/completions")
                 "--in" (namestring req)
                 "--out" (namestring res)
                 "--meta" (namestring meta))
           :output :string
           :error-output :string
           :ignore-error-status t)
        (declare (ignore out err exit))
        (let ((status (ignore-errors
                        (parse-integer
                         (string-trim '(#\Space #\Return #\Newline)
                                      (agent-cl.core:read-file-string meta))))))
          (unless (and status (<= 200 status 299))
            (error 'agent-cl.core:transport-error
                   :message (format nil "deepseek http ~a: ~a" status
                                     (agent-cl.core:read-file-string res))
                   :status status :retryable t))
          (agent-cl.core:read-file-string res))))))

(handler-case
    (progn
      (load (merge-pathnames "dev-http.lisp"
                             (uiop:pathname-directory-pathname *load-truename*)))
      (let ((enable (find-symbol "ENABLE-HOOK" "AGENT-CL.DEXADOR-DEV")))
        (unless (and enable (funcall enable))
          (error "dexador hook failed to enable"))))
  (error (e)
    (format t "~&[smoke] dexador direct unavailable (~a); falling back to node helper~%" e)
    (setf agent-cl.llm:*http-fetch-hook* #'node-request)))

(defun run-smoke ()
  (let* ((agent (agent-cl.loop:make-agent
                 :transport (agent-cl.llm:make-http-transport
                             :base-url *api-base*
                             :api-key (uiop:getenv "AGENT_CL_API_KEY"))
                 :model "deepseek-chat"
                 :system "你是 Agent-CL 冒烟测试助手。需要当前时间时，必须调用 time.now 工具并把返回的 UTC 时间转述给用户。"
                 :tools '("time.now")
                 :policy (agent-cl.loop:make-policy :max-steps 6)))
         (summary (agent-cl.loop:ask agent "现在 UTC 时间是什么？请用工具查询。"))
         (roles (mapcar (lambda (m) (agent-cl.messages:msg-role m))
                        (agent-cl.loop:agent-messages agent))))
    (format t "~&[smoke] done=~a steps=~a tools=~a reason=~a~%"
            (agent-cl.loop:done-p summary)
            (agent-cl.loop:steps summary)
            (agent-cl.loop:turn-summary-tool-count summary)
            (agent-cl.loop:guard-reason summary))
    (format t "[smoke] roles: ~s~%" roles)
    (format t "[smoke] usage: total=~a~%" (agent-cl.loop:agent-usage-total agent))
    (format t "[smoke] final: ~a~%" (agent-cl.loop:final-content summary))
    (let ((ok (and (agent-cl.loop:done-p summary)
                   (> (agent-cl.loop:turn-summary-tool-count summary) 0)
                   (member :tool roles)
                   (agent-cl.loop:final-content summary))))
      (format t "~&[SMOKE-~a]~%" (if ok "OK" "FAIL"))
      ok)))

(handler-case
    (let ((ok (run-smoke)))
      (uiop:quit (if ok 0 1)))
  (error (e)
    (format t "~&[SMOKE-ERROR] ~a~%" e)
    (uiop:quit 1)))
