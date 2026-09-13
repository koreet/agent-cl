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

(defun canonical-path-string (path &optional base)
  "Workspace-aware wrapper over AGENT-CL.CORE:CANONICAL-PATH-STRING. Relative
  paths resolve against BASE, then the workspace root, then the cwd. '..' is
  folded here, which is what makes the workspace check meaningful: the string we
  validate is the same string we hand to OPEN."
  (agent-cl.core:canonical-path-string
   path (or base *file-workspace-root*)))

(defun workspace-resolve (path)
  "Resolve PATH for the file tools. Returns (values CANONICAL-PATH NIL) when it
  is inside the workspace, else (values NIL REASON). Callers must OPEN the
  returned canonical path, so that what was validated is what gets used."
  (if (null *file-workspace-root*)
      (values (agent-cl.core:canonical-path-string path (uiop:getcwd)) nil)
      (let ((root (canonical-path-string *file-workspace-root*))
            (cand (canonical-path-string path)))
        (if (agent-cl.core:path-inside-p cand root)
            (values cand nil)
            (values nil
                    (format nil "拒绝访问工作区外路径 ~a（允许范围 ~a；如需放开请 set-file-workspace-root nil）"
                            path root))))))

(defun workspace-check (path)
  "Compatibility wrapper: an error string when PATH leaves the workspace, else
  NIL. Prefer WORKSPACE-RESOLVE, which also returns the path to use."
  (nth-value 1 (workspace-resolve path)))

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
    (multiple-value-bind (resolved escape) (workspace-resolve path)
      (if escape
          (values escape :error)
          (handler-case
              ;; open the RESOLVED path: what we validated is what we read
              (let ((text (agent-cl.core:read-file-string resolved)))
                (if (null text)
                    ;; READ-FILE-STRING returns NIL for an absent file; reporting
                    ;; that as :ok would look like an empty file
                    (values (format nil "文件不存在或不可读: ~a" resolved) :error)
                    (values text :ok)))
            (error (e) (values (format nil "cannot read ~a: ~a" path e) :error)))))))

(defun write-file (args ctx)
  (declare (ignore ctx))
  (let ((path (getf args :PATH))
        (content (getf args :CONTENT)))
    (unless (and path content)
      (return-from write-file (values "missing :path/:content" :error)))
    (multiple-value-bind (resolved escape) (workspace-resolve path)
      (if escape
          (values escape :error)
          (handler-case
              (progn
                ;; write the RESOLVED path: what we validated is what we write
                (agent-cl.core:write-file-string resolved content)
                (values (format nil "wrote ~a bytes to ~a"
                                (agent-cl.core:utf8-byte-length content) resolved)
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

(defun find-unix-shell ()
  "Path of a POSIX shell on this host, or NIL.

  `sh` used to be run as `cmd /c <file>` on Windows, which cannot execute a shell
  script at all: the command failed (or, worse, exited 0 while doing nothing) and
  the model was told its code had run. Reporting 'no POSIX shell here' is the
  honest answer; Git for Windows usually provides one."
  (or (let ((env (or (uiop:getenv "SHELL") (uiop:getenv "AGENT_CL_SH"))))
        (and env (uiop:file-exists-p env) env))
      (when (uiop:os-windows-p)
        (some (lambda (p) (and (uiop:file-exists-p p) p))
              '("C:\\Program Files\\Git\\bin\\sh.exe"
                "C:\\Program Files\\Git\\usr\\bin\\sh.exe"
                "C:\\Program Files (x86)\\Git\\bin\\sh.exe")))
      (when (uiop:os-windows-p)
        (loop for d in (uiop:split-string (or (uiop:getenv "PATH") "")
                                          :separator ";")
              for cand = (and d (plusp (length (string-trim '(#\Space) d)))
                              (merge-pathnames
                               "sh.exe" (uiop:ensure-directory-pathname d)))
              when (and cand (uiop:file-exists-p cand))
                return (namestring cand)))
      (unless (uiop:os-windows-p)
        (some (lambda (p) (and (uiop:file-exists-p p) p))
              '("/bin/sh" "/usr/bin/sh")))))

(defun interpreter-command (language code file)
  "Return (values argv ext) for LANGUAGE and the temp source FILE. EXT is the
  file extension the interpreter expects; a NIL ARGV means 'cannot run this here'
  and the caller reports it instead of running something else."
  (declare (ignore code))
  (let ((lang (string-downcase (or language "python"))))
    (cond
      ((or (string= lang "python") (string= lang "py"))
       (values (list (if (uiop:os-windows-p) "python" "python3") file) ".py"))
      ((string= lang "sbcl")
       (let* ((home (uiop:getenv "SBCL_HOME"))
              (sep (if (uiop:os-windows-p) "\\" "/"))
              (exe-name (if (uiop:os-windows-p) "sbcl.exe" "sbcl"))
              (home-exe (and home
                             (let ((cand (format nil "~a~a~a"
                                                 (string-right-trim '(#\\ #\/) home)
                                                 sep exe-name)))
                               (and (uiop:file-exists-p cand) cand))))
              ;; running SBCL's own executable is the most reliable source
              (self (and (find-package "SB-EXT")
                         (let ((sym (find-symbol "*RUNTIME-PATHNAME*" "SB-EXT")))
                           (and sym (boundp sym) (symbol-value sym)))))
              (exe (or home-exe (and self (namestring self)) exe-name)))
         (values (list exe "--noinform" "--disable-debugger" "--script" file)
                 ".lisp")))
      ((or (string= lang "sh") (string= lang "bash") (string= lang "shell"))
       (let ((sh (find-unix-shell)))
         (if sh
             (values (list sh file) ".sh")
             ;; ARGV is deliberately NIL: see FIND-UNIX-SHELL
             (values nil nil))))
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
        (interpreter-command language code nil)
      (unless argv
        (return-from code-exec
          (values (if (member (string-downcase (or language ""))
                              '("sh" "bash" "shell") :test #'string=)
                      "本机没有可用的 POSIX shell（sh）；Windows 上请用 python/sbcl，或安装 Git for Windows（含 sh.exe）"
                      (format nil "unsupported language ~s (use python|sbcl|sh)"
                              language))
                  :error)))
      (let* ((dir (uiop:ensure-directory-pathname
                   (merge-pathnames ".tools/tmp/code-exec/"
                                    (uiop:getcwd))))
             ;; Use the extension the interpreter expects: everything used to be
             ;; written as .tmp, so a run left a file with no hint about what it
             ;; contained (and no interpreter could infer the language from it).
             (file (namestring
                    (merge-pathnames
                     (format nil "run-~a~a" (agent-cl.core:uuid-string)
                             (or ext ".txt"))
                     dir)))
             (argv (append (butlast argv) (list file))))
        (ensure-directories-exist dir)
        (unwind-protect
             (progn
               (agent-cl.core:write-file-string file code)
               (multiple-value-bind (out err exit)
                   (handler-case
                       (agent-cl.core:run-program-with-timeout argv
                                                               :timeout timeout)
                     (error (e)
                       (return-from code-exec
                         (values (format nil "cannot run ~a: ~a"
                                         (or language "python") e)
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
                       (values text :error)))))
          (ignore-errors (delete-file file)))))))

;;; ---------------------------------------------------------------------------
;;; registration
;;; ---------------------------------------------------------------------------

;;; ---------------------------------------------------------------------------
;;; task.delegate — 父 agent 把子任务委派给独立子 agent 实例
;;; ---------------------------------------------------------------------------

(defparameter *max-delegate-depth* 2
  "Deepest delegation chain allowed: a top-level agent (depth 0) may delegate to
  depth 1, which may delegate to depth 2, which may not delegate further. A
  hard depth cap means a smuggled delegation tool cannot recurse forever.")

(defun norm-tool-name (n)
  (if (stringp n) n (string-downcase (string n))))

(defun parent-tool-names (parent)
  "The tool names PARENT itself may use (a concrete list, even for :all),
  canonicalized to registry DSL names so that a parent declared with a wire-form
  name ('task_delegate') still matches its children's tool set. Unknown names
  are dropped. Returns NIL when PARENT is not an agent (fail closed)."
  (if (not (typep parent 'agent-cl.loop:agent))
      nil
      (let ((p (agent-cl.loop:agent-tools parent)))
        (if (eq p :all)
            (agent-cl.tools:list-tools)
            (loop for n in p
                  for tool = (agent-cl.tools:find-tool (norm-tool-name n))
                  when tool collect (agent-cl.tools:tool-name tool))))))

(defun resolve-child-tools (parent explicit)
  "The child's tool set, as registry DSL names.

  Two guards that a literal-name filter cannot provide:
    * DELEGATION IS REMOVED BY OBJECT IDENTITY — 'task:delegate' and
      'task/delegate' sanitize to the same wire name as 'task.delegate', so
      comparing strings would let the model smuggle delegation back in;
    * the result is INTERSECTED WITH THE PARENT'S OWN TOOLS — a restricted
      parent cannot grant a child tools it does not have itself.
  Unknown names are dropped (the caller sees them only via tool availability)."
  (let* ((delegate (agent-cl.tools:find-tool "task.delegate"))
         (parent-names (parent-tool-names parent))
         (requested (if explicit explicit parent-names))
         (resolved (loop for n in requested
                         for nm = (norm-tool-name n)
                         for tool = (agent-cl.tools:find-tool nm)
                         when (and tool (not (eq tool delegate)))
                           collect (agent-cl.tools:tool-name tool))))
    (remove-duplicates
     (remove-if-not (lambda (n)
                      (member (norm-tool-name n) parent-names :test #'string=))
                    resolved)
     :test #'string=)))

(defun roll-up-child-usage (parent child)
  "Fold a child's token accounting into the parent, so delegated work is not
  invisible to the parent's cost view or its :max-tokens guard."
  (macrolet ((fold (accessor)
               `(incf (,accessor parent) (,accessor child))))
    (when (and parent child)
      (fold agent-cl.loop:agent-usage-total)
      (fold agent-cl.loop:agent-usage-prompt)
      (fold agent-cl.loop:agent-usage-completion))))

(defun delegate-task (args parent)
  "Run TASK inside a fresh child agent (independent short session) and return
  only the final conclusion - keeps the parent transcript small. Delegation is
  depth-limited, the child cannot obtain the delegation tool, and its token
  usage rolls up into the parent."
  (unless (typep parent 'agent-cl.loop:agent)
    (return-from delegate-task
      (values "task.delegate requires an agent context" :error)))
  (let* ((task (getf args :TASK))
         (explicit (getf args :TOOLS))
         (max-steps (or (getf args :MAX-STEPS) 6))
         (depth (agent-cl.loop:agent-depth parent))
         (model (or (getf args :MODEL)
                    (agent-cl.loop:agent-model parent))))
    (unless task
      (return-from delegate-task (values "missing :task" :error)))
    (when (>= depth *max-delegate-depth*)
      (return-from delegate-task
        (values (format nil "委派层级已达上限（当前深度 ~a，最多 ~a）。请直接完成剩余工作。"
                        depth *max-delegate-depth*)
                :error)))
    (let* ((child-tools (resolve-child-tools parent explicit))
           (child (agent-cl.loop:make-agent
                   ;; A child inherits the parents class and sits one level
                   ;; deeper, so display hooks (the REPL printer) fire on it
                   ;; and can be indented/marked as delegated work.
                   :class (class-of parent)
                   :depth (1+ depth)
                   :transport (agent-cl.loop:agent-transport parent)
                   :model model
                   :tools child-tools
                   :system "你是被父 agent 委派的子 agent。专注完成交给你的任务，只输出最终结论，不要复述中间过程。"
                   :policy (agent-cl.loop:make-policy :max-steps max-steps)))
           (r (agent-cl.loop:ask child task))
           (final (agent-cl.loop:final-content r)))
      ;; the parent pays for delegated work: fold the child's usage upward
      (roll-up-child-usage parent child)
      (if (agent-cl.loop:done-p r)
          (values (format nil "[child done steps=~a tokens=~a]~%~a"
                          (agent-cl.loop:steps r)
                          (agent-cl.loop:agent-usage-total child)
                          (or final "(no output)"))
                  :ok)
          (values (format nil "[child incomplete guard=~a]"
                          (agent-cl.loop:guard-reason r))
                  :error)))))

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

(defparameter *reserved-filenames*
  '("con" "prn" "aux" "nul" "com1" "com2" "com3" "com4" "com5" "com6" "com7"
    "com8" "com9" "lpt1" "lpt2" "lpt3" "lpt4" "lpt5" "lpt6" "lpt7" "lpt8" "lpt9")
  "Windows device names: a file called con.json is unusable there, whatever the
  extension.")

(defun memory-key-stem (key)
  "Injective, filesystem-safe filename stem for KEY.

  Injectivity is the whole point: the previous scheme hex-escaped other
  characters WITHOUT escaping the escape, so the key \"a b\" produced \"a20b\" and
  collided with the literal key \"a20b\" — one memory silently overwrote the
  other. Here '_' is the escape introducer and is itself escaped:
      [a-z0-9-]  -> itself
      '_'        -> \"_5f\"
      anything   -> \"_\" + 2 lowercase hex digits
  Lowercase-only is deliberate: Windows filenames are case-insensitive, so
  \"ABC\" and \"abc\" would otherwise share one file. Reserved device names get a
  '_' prefix (a literal leading '_' is already escaped, so this adds no new
  collision)."
  (let* ((s (if (stringp key) key (princ-to-string key)))
         (stem (with-output-to-string (out)
                 (loop for ch across s
                       do (if (or (char<= #\a ch #\z)
                                  (digit-char-p ch)
                                  (char= ch #\-))
                              (write-char ch out)
                              ;; ~(...~) forces lower case: SBCL prints ~x in
                              ;; upper case, so relying on the directive's case
                              ;; made 'a_b' encode differently per implementation.
                              (format out "_~(~2,'0x~)" (char-code ch)))))))
    (cond ((zerop (length stem)) "_")
          ((member stem *reserved-filenames* :test #'string-equal)
           (concatenate 'string "_" stem))
          (t stem))))

(defun memory-key-file (key)
  "Map KEY to its memory file under the memory dir (see MEMORY-KEY-STEM)."
  (merge-pathnames (format nil "~a.json" (memory-key-stem key)) (memory-dir)))

(defun legacy-memory-key-file (key)
  "The pre-fix filename for KEY: a read-only fallback so memories written by an
  older build stay recallable. New writes always use MEMORY-KEY-FILE.

  NB: its output (including the hex CASE) must not be modernised — this exists to
  match file names that are already on disk."
  (let* ((s (if (stringp key) key (princ-to-string key)))
         (safe (with-output-to-string (out)
                 (loop for ch across s
                       do (if (or (alphanumericp ch)
                                  (member ch '(#\- #\_ #\.)))
                              (write-char ch out)
                              (format out "~2,'0x" (char-code ch)))))))
    (merge-pathnames (format nil "~a.json" safe) (memory-dir))))

(defun legacy-memory-key-candidates (key)
  "Legacy paths for KEY: the historical name plus its case-folded variant, since
  the hex case depended on the implementation's ~x behavior."
  (let* ((f (legacy-memory-key-file key))
         (dir (memory-dir))
         (name (file-namestring f))
         (lower (string-downcase name)))
    (if (string= name lower)
        (list f)
        (list f (merge-pathnames lower dir)))))

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
    (let ((f (memory-key-file key))
          (old (legacy-memory-key-candidates key)))
      (cond
        ((uiop:file-exists-p f)
         (values (agent-cl.core:read-file-string f) :ok))
        ;; memories written before the encoding was made injective
        ((find-if #'uiop:file-exists-p old)
         (values (agent-cl.core:read-file-string (find-if #'uiop:file-exists-p old))
                 :ok))
        (t (values (format nil "no memory for ~a" key) :error))))))

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
                       :description "Search the web. Query terms; returns top result titles + URLs (+ snippets) for the agent to read/fetch. Backend: Tavily (needs TAVILY_API_KEY); pass backend=\"ddg\" for the keyless DuckDuckGo fallback."
                       :parameters (make-builtin-params
                                    ("query" :string :description "search keywords" :required t)
                                    ("max_results" :number :description "max results (default 5)")
                                    ("backend" :string :description "\"tavily\" (default) or \"ddg\" (keyless)")))
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
