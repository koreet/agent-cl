;;;; src/tools/builtin.lisp — builtin tools: shell / file / time.
(in-package #:agent-cl.tools)

(defmacro make-builtin-params (&rest specs)
  "SPECS literal: (name type &key description required). Expands to a schema."
  (let ((props nil)
        (required nil))
    (dolist (s specs)
      (let* ((name (first s))
             (type (second s))
             (rest (cddr s))
             (name-str (if (stringp name) name
                           (string-downcase (symbol-name name)))))
        (push `(cons ,name-str
                     (list :type ,type
                           :description ,(getf rest :description)))
              props)
        (when (getf rest :required)
          (push name-str required))))
    `(agent-cl.schema:make-schema
      :kind :object
      :properties (list ,@(nreverse props))
      :required (list ,@(nreverse required)))))

;; ---------------------------------------------------------------------------
;; file tools workspace confinement
;; ---------------------------------------------------------------------------

(defparameter *file-workspace-root* (uiop:getcwd)
  "Root directory file.read/file.write may touch. Defaults to the current
  working directory (the repo root when launched via start.ps1); set to NIL to
  disable confinement (agent then reads/writes anywhere the process may).")

(defun set-file-workspace-root (path)
  (setf *file-workspace-root*
        (and path (uiop:ensure-directory-pathname path))))

(defun native->slashed (path)
  "Best-effort normalize a filesystem path string for prefix comparison."
  (let* ((s (if (pathnamep path) (namestring path)
                (if (stringp path) path (princ-to-string path))))
         (slashed (string-downcase (substitute #\/ #\\ s))))
    ;; collapse duplicate separators so agent-cl//.tools == agent-cl/.tools
    (let ((out (make-string-output-stream))
          (prev #\Space))
      (loop for ch across slashed
            do (unless (and (char= ch #\/) (char= prev #\/))
                 (write-char ch out))
               (setf prev ch))
      (get-output-stream-string out))))

(defun strip-trailing-slashes (s)
  (string-right-trim '(#\/) s))

(defun workspace-check (path)
  "Return an error string if PATH is not inside the workspace, else NIL.
  Both absolute and relative forms are confined."
  (when (null *file-workspace-root*)
    (return-from workspace-check nil))
  (let* ((root (strip-trailing-slashes (native->slashed *file-workspace-root*)))
         (raw (if (stringp path) path (princ-to-string path)))
         (merged (if (uiop:absolute-pathname-p (pathname raw))
                     raw
                     (namestring (merge-pathnames raw *file-workspace-root*))))
         (cand (native->slashed merged)))
    (unless (or (string= cand root)
                (and (> (length cand) (length root))
                     (string= cand root
                              :end1 (length root) :end2 (length root))
                     (char= (char cand (length root)) #\/)))
      (format nil "拒绝访问工作区外路径 ~a（允许范围 ~a；如需放开请 set-file-workspace-root nil）"
              path root))))

;;; ---------------------------------------------------------------------------
;;; shell.run
;;; ---------------------------------------------------------------------------

(defun run-shell (args ctx)
  (declare (ignore ctx))
  (let ((cmd (getf args :CMD))
        (cwd (getf args :CWD)))
    (unless cmd
      (return-from run-shell (values "missing :cmd" :error)))
    (let ((argv (if (uiop:os-windows-p)
                    (list "cmd" "/c" cmd)
                    (list "/bin/sh" "-c" cmd))))
      (multiple-value-bind (out err exit)
          (agent-cl.core:run-program-with-timeout
           argv
           :timeout (or (getf args :TIMEOUT) 60)
           :directory (or cwd (namestring (uiop:getcwd))))
        (if (and (integerp exit) (zerop exit)
                 (or (null err) (string= err "")))
            (values (string-right-trim '(#\Newline #\Return) out) :ok)
            (values (format nil "exit ~a~%stdout: ~a~%stderr: ~a" exit out err)
                    :error))))))

;;; ---------------------------------------------------------------------------
;;; file.read / file.write
;;; ---------------------------------------------------------------------------

(defun read-file (args ctx)
  (declare (ignore ctx))
  (let ((path (getf args :PATH)))
    (unless path
      (return-from read-file (values "missing :path" :error)))
    (let ((escape (workspace-check path)))
      (if escape
          (values escape :error)
          (handler-case
              (values (agent-cl.core:read-file-string path) :ok)
            (error (e) (values (format nil "cannot read ~a: ~a" path e) :error)))))))

(defun write-file (args ctx)
  (declare (ignore ctx))
  (let ((path (getf args :PATH))
        (content (getf args :CONTENT)))
    (unless (and path content)
      (return-from write-file (values "missing :path/:content" :error)))
    (let ((escape (workspace-check path)))
      (if escape
          (values escape :error)
          (handler-case
              (progn
                (agent-cl.core:write-file-string path content)
                (values (format nil "wrote ~a bytes to ~a"
                                (agent-cl.core:utf8-byte-length content) path)
                        :ok))
            (error (e) (values (format nil "cannot write ~a: ~a" path e) :error)))))))

;;; ---------------------------------------------------------------------------
;;; time.now
;;; ---------------------------------------------------------------------------

(defun now-time (args ctx)
  (declare (ignore args ctx))
  (values (agent-cl.core:now-iso8601) :ok))

;;; ---------------------------------------------------------------------------
;;; code.exec — let the model write code and execute it (self-hosting loop)
;;; ---------------------------------------------------------------------------

(defun interpreter-command (language code file)
  "Return (values argv ext env-patch?) for LANGUAGE and the temp source FILE."
  (let ((lang (string-downcase (or language "python"))))
    (cond
      ((string= lang "python") (values (list "python" file) ".py"))
      ((string= lang "py")     (values (list "python" file) ".py"))
      ((string= lang "sbcl")
       (let* ((home (uiop:getenv "SBCL_HOME"))
              (sep (if (uiop:os-windows-p) "\\" "/"))
              (home-exe (and home
                             (let ((cand (format nil "~a~asbcl.exe"
                                                  (string-right-trim '(#\\ #\/) home) sep)))
                               (and (uiop:file-exists-p cand) cand))))
              ;; running SBCL's own executable is the most reliable source
              (self (and (find-package "SB-EXT")
                         (symbol-value (find-symbol "*RUNTIME-PATHNAME*" "SB-EXT"))))
              (exe (or home-exe
                       (and self (namestring self))
                       "sbcl")))
         (values (list exe "--noinform" "--disable-debugger" "--script" file)
                 ".lisp")))
      ((string= lang "sh")
       (values (if (uiop:os-windows-p) (list "cmd" "/c" file)
                   (list "/bin/sh" file))
               ".sh"))
      (t (values nil nil)))))

(defun code-exec (args ctx)
  "Write CODE to a temp file and run it under LANGUAGE (python|sbcl|sh)."
  (declare (ignore ctx))
  (let* ((language (getf args :LANGUAGE))
         (code (getf args :CODE))
         (timeout (or (getf args :TIMEOUT) 60)))
    (unless code
      (return-from code-exec (values "missing :code" :error)))
    (multiple-value-bind (argv ext)
        (interpreter-command language code "unused")
      (declare (ignore ext))
      (unless argv
        (return-from code-exec
          (values (format nil "unsupported language ~s (use python|sbcl|sh)"
                          language)
                  :error))))
    (let* ((dir (uiop:ensure-directory-pathname
                 (merge-pathnames ".tools/tmp/code-exec/"
                                  (uiop:getcwd))))
           (file (namestring
                  (merge-pathnames
                   (format nil "run-~a~a" (agent-cl.core:uuid-string) ".tmp")
                   dir))))
      (ensure-directories-exist dir)
      (unwind-protect
           (progn
             (agent-cl.core:write-file-string file code)
             (multiple-value-bind (argv ext)
                 (interpreter-command language code file)
               (declare (ignore ext))
               (multiple-value-bind (out err exit)
                   (handler-case
                       (agent-cl.core:run-program-with-timeout argv
                                                        :timeout timeout)
                     (error (e)
                       (return-from code-exec
                         (values (format nil "cannot run ~a: ~a" (or language "python") e)
                                 :error))))
                 (let* ((clean-err (string-trim '(#\Space #\Tab #\Newline #\Return)
                                                (or err "")))
                        (timed-out (eq exit :timeout))
                        (exit-label (if timed-out "timeout"
                                        (princ-to-string exit)))
                        (text (format nil "~a~@[~%--- stderr ---~%~a~]~%[exit ~a]"
                                      out (and (plusp (length clean-err)) clean-err)
                                      exit-label)))
                   (if (and (integerp exit) (zerop exit)
                            (zerop (length clean-err)))
                       (values text :ok)
                       (values text :error))))))
        (ignore-errors (delete-file file))))))

;;; ---------------------------------------------------------------------------
;;; registration
;;; ---------------------------------------------------------------------------

;;; ---------------------------------------------------------------------------
;;; task.delegate — 父 agent 把子任务委派给独立子 agent 实例
;;; ---------------------------------------------------------------------------

(defun delegate-task (args parent)
  "Run TASK inside a fresh child agent (independent short session) and return
  only the final conclusion - keeps the parent transcript small. The child
  never inherits task.delegate itself (no nesting)."
  (unless (typep parent 'agent-cl.loop:agent)
    (return-from delegate-task
      (values "task.delegate requires an agent context" :error)))
  (let* ((task (getf args :TASK))
         (explicit (getf args :TOOLS))
         (max-steps (or (getf args :MAX-STEPS) 6))
         (model (or (getf args :MODEL)
                    (agent-cl.loop:agent-model parent))))
    (unless task
      (return-from delegate-task (values "missing :task" :error)))
    (flet ((norm (n) (if (stringp n) n (string-downcase (string n)))))
      (let* ((inherited (agent-cl.loop:agent-tools parent))
             ;; remove BOTH the DSL name (task.delegate) and the wire name
             ;; (task_delegate) — the model sees the sanitized wire name, so a
             ;; literal-name filter alone would let nesting slip through.
             (child-tools
               (remove-if (lambda (n)
                            (member (norm n) '("task.delegate" "task_delegate")
                                    :test #'string=))
                          (if explicit
                              (mapcar #'norm explicit)
                              (if (eq inherited :all)
                                  (agent-cl.tools:list-tools)
                                  (mapcar #'norm inherited))))))
        (let* ((child (agent-cl.loop:make-agent
                       :transport (agent-cl.loop:agent-transport parent)
                       :model model
                       :tools child-tools
                       :system "你是被父 agent 委派的子 agent。专注完成交给你的任务，只输出最终结论，不要复述中间过程。"
                       :policy (agent-cl.loop:make-policy :max-steps max-steps)))
               (r (agent-cl.loop:ask child task))
               (final (agent-cl.loop:final-content r)))
          (if (agent-cl.loop:done-p r)
              (values (format nil "[child done steps=~a]~%~a"
                              (agent-cl.loop:steps r)
                              (or final "(no output)"))
                      :ok)
              (values (format nil "[child incomplete guard=~a]"
                              (agent-cl.loop:guard-reason r))
                      :error)))))))

;;; ---------------------------------------------------------------------------
;;; memory.set / memory.recall — 跨会话持久记忆（~/.agent-cl/memory/*.json）
;;; ---------------------------------------------------------------------------

(defun memory-dir ()
  (let ((d (uiop:ensure-directory-pathname
            (merge-pathnames ".agent-cl/memory/"
                             (uiop:ensure-directory-pathname
                              (or (uiop:getenv "USERPROFILE") (uiop:getenv "HOME")))))))
    (ensure-directories-exist d)
    d))

(defun memory-key-file (key)
  "Map KEY to a file path under the memory dir. The filename is an injective
  (reversible) encoding: [A-Za-z0-9._-] stay literal, any other char becomes
  its lowercase 2-digit hex code — so 'a-b', 'a b', 'a/b' never collide (they
  previously all collapsed to a_b.json and silently overwrote each other)."
  (let* ((s (if (stringp key) key (princ-to-string key)))
         (safe (with-output-to-string (out)
                 (loop for ch across s
                       do (if (or (alphanumericp ch)
                                  (member ch '(#\- #\_ #\.)))
                              (write-char ch out)
                              (format out "~2,'0x" (char-code ch)))))))
    (merge-pathnames (format nil "~a.json" safe) (memory-dir))))

(defun memory-store (args ctx)
  (declare (ignore ctx))
  (let ((key (getf args :KEY))
        (value (getf args :VALUE)))
    (unless (and key value)
      (return-from memory-store (values "missing :key/:value" :error)))
    (handler-case
        (let ((target (memory-key-file key))
              (tmp (merge-pathnames
                    (format nil "~a.tmp" (agent-cl.core:uuid-string))
                    (memory-dir))))
          ;; atomic write: write temp then rename, so concurrent readers never
          ;; observe a truncated / half-written file
          (unwind-protect
               (progn
                 (agent-cl.core:write-file-string tmp value)
                 (uiop:rename-file-overwriting-target tmp target)
                 (values (format nil "saved ~a" key) :ok))
            (ignore-errors (delete-file tmp))))
      (error (e) (values (format nil "memory write failed: ~a" e) :error)))))

(defun memory-recall (args ctx)
  (declare (ignore ctx))
  (let ((key (getf args :KEY)))
    (unless key (return-from memory-recall (values "missing :key" :error)))
    (let ((f (memory-key-file key)))
      (if (uiop:file-exists-p f)
          (values (agent-cl.core:read-file-string f) :ok)
          (values (format nil "no memory for ~a" key) :error)))))

(defun register-builtin-tools (&optional (registry *tool-registry*))
  "Register shell/file/time tools into REGISTRY. Returns the list of names."
  (let ((tools
          (list
           (make-tool "shell.run" #'run-shell
                      :description "Run a command on the host and return stdout/stderr. DANGEROUS: may modify or delete files. Use carefully."
                      :parameters (make-builtin-params
                                   ("cmd" :string :description "command to run" :required t)
                                   ("cwd" :string :description "working directory (default current)")
                                   ("timeout" :number :description "seconds before timeout (default 60)"))
                      :dangerous-p t)
           (make-tool "file.read" #'read-file
                      :description "Read a UTF-8 text file and return its content."
                      :parameters (make-builtin-params
                                   ("path" :string :description "file path" :required t)))
           (make-tool "file.write" #'write-file
                      :description "Write text content to a UTF-8 file (confined to the workspace root unless set-file-workspace-root nil), creating parent directories. DANGEROUS: can overwrite existing files."
                      :parameters (make-builtin-params
                                   ("path" :string :description "file path" :required t)
                                   ("content" :string :description "content to write" :required t))
                      :dangerous-p t)
           (make-tool "time.now" #'now-time
                      :description "Return the current UTC time as an ISO-8601 string."
                      :parameters (make-builtin-params))
           (make-tool "code.exec" #'code-exec
                      :description "Write and run a short program. LANGUAGE is python|sbcl|sh (default python); CODE is the source. stdout/stderr and the exit code are returned. DANGEROUS: executes arbitrary code."
                      :parameters (make-builtin-params
                                   ("code" :string :description "program source" :required t)
                                   ("language" :string :description "python|sbcl|sh")
                                   ("timeout" :number :description "seconds (default 60)"))
                       :dangerous-p t)
           (make-tool "task.delegate" #'delegate-task
                      :description "Delegate a subtask to an independent child agent (fresh short session; only its final conclusion returns, keeping the parent transcript small). Child runs with a limited tool set and step budget and cannot delegate further. Good for computations, writing+running code, focused research."
                      :parameters (make-builtin-params
                                   ("task" :string :description "subtask for the child agent" :required t)
                                   ("tools" :array :description "child allowed tool names (default: inherit parent, minus task.delegate)")
                                   ("max_steps" :number :description "child max steps (default 6)")
                                   ("model" :string :description "child model (default: same as parent)"))
                      :dangerous-p t)
            (make-tool "memory.set" #'memory-store
                       :description "Remember a key-value fact across sessions (stored under ~/.agent-cl/memory)."
                       :parameters (make-builtin-params
                                    ("key" :string :description "memory key" :required t)
                                    ("value" :string :description "content to remember" :required t)))
            (make-tool "memory.recall" #'memory-recall
                       :description "Recall a fact stored earlier with memory.set."
                       :parameters (make-builtin-params
                                    ("key" :string :description "memory key" :required t)))
            (make-tool "web.search" #'agent-cl.web:web-search
                       :description "Search the web (DuckDuckGo, no key). Query terms; returns top result titles + URLs for the agent to read/fetch."
                       :parameters (make-builtin-params
                                    ("query" :string :description "search keywords" :required t)
                                    ("max_results" :number :description "max results (default 5)")))
)))

    (dolist (t1 tools)
      (setf (gethash (tool-name t1) registry) t1))
    (mapcar #'tool-name tools)))

(defun shell-tool ()
  (find-tool "shell.run"))

(defun file-tool ()
  (find-tool "file.read"))

(defun time-tool ()
  (find-tool "time.now"))
