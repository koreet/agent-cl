;;;; src/selfimprove/engine.lisp — safe single-file self-improvement primitives.
;;;;
;;;; What this is: a small, conservative mechanism that lets Agent-CL propose a
;;;; change to one source file, gate it by tests, then adopt or roll it back.
;;;; Built to the "备份 -> 写补丁 -> 守门测试 -> 择优 -> 回滚" contract. Success is
;;;; defined as "a guarded, revertible change", NOT "unfettered self-editing".
;;;;
;;;; Design notes:
;;;;  * We touch *source files on disk* only; we never redefine the executing
;;;;    process's functions in place (no implicit eval of the running image).
;;;;  * The gate is an injected test-runner THUNK :-> (values okp detail), so the
;;;;    same primitive works under a mock gate in tests AND a real
;;;;    scripts/run-tests.lisp subprocess in production.
;;;;  * Backup and rollback are the only side effects besides the patch write.
;;
(in-package #:agent-cl.selfimprove)

;; ---------------------------------------------------------------------------
;; backup naming helpers
;; ---------------------------------------------------------------------------

(defun backup-filename (path)
  "Unique backup path for PATH under the configured backup root. Uses the leaf
  basename plus a random suffix so proposals never collide."
  (format nil "~a_~a.bak"
          (or (pathname-name path) "file")
          (agent-cl.core:uuid-string)))

;; ---------------------------------------------------------------------------
;; outcome normalization
;; ---------------------------------------------------------------------------

(defun state-plist (&key status detail retained)
  "Normalize the outcome of IMPROVE-FILE. STATUS is one of
  :adopted | :rolled-back | :rejected | :no-change. DETAIL carries extra info;
  RETAINED says whether a backup was kept for audit."
  (let ((out nil))
    (when status   (setf out (nconc out (list :status status))))
    (when detail   (setf out (nconc out (list :detail detail))))
    (when retained (setf out (nconc out (list :retained retained))))
    out))

;; ---------------------------------------------------------------------------
;; default backup root
;; ---------------------------------------------------------------------------

(defun make-git-style-backup-dir ()
  "Default backup root for IMPROVE-FILE: <repo>/_improve-backups/. Called each
  time so paths stay anchored to the caller's current working directory.
  (The '_improve-backups' tree is outside src/ and intended to be git-ignored.)"
  (uiop:ensure-directory-pathname
   (merge-pathnames "_improve-backups/" (uiop:getcwd))))

;; ---------------------------------------------------------------------------
;; repo location, path confinement, and the real production gate runner
;; ---------------------------------------------------------------------------

(defun directory-holds-file-p (dir name)
  (let ((p (ignore-errors
            (probe-file (uiop:subpathname (uiop:ensure-directory-pathname dir)
                                          name)))))
    (and p t)))

(defun repo-root-path ()
  "Repository root: the nearest ancestor directory holding agent-cl.asd. Derived
  from the ASDF system location first (correct even when this file was loaded
  from a compiled fasl), then by walking up from *LOAD-TRUENAME*, then from the
  cwd. Never hard-codes an absolute path."
  (labels ((walk (start)
             (when start
               (loop for dir = (ignore-errors (uiop:ensure-directory-pathname start))
                       then (ignore-errors
                             (uiop:pathname-parent-directory-pathname dir))
                     for guard from 0 below 16
                     while dir
                     when (directory-holds-file-p dir "agent-cl.asd") return dir
                     when (equal dir (ignore-errors
                                      (uiop:pathname-parent-directory-pathname dir)))
                       return nil))))
    (let ((asdf-dir
            (let ((pkg (find-package "ASDF")))
              (when pkg
                (let ((fn (find-symbol "SYSTEM-SOURCE-DIRECTORY" pkg)))
                  (when (and fn (fboundp fn))
                    (ignore-errors (funcall fn :agent-cl))))))))
      (or (walk asdf-dir)
          (walk *load-truename*)
          (walk (uiop:getcwd))
          (uiop:getcwd)))))

(defparameter *protected-paths*
  '("scripts/run-tests.lisp" "tests/" "agent-cl.asd")
  "Repo-relative paths (or directory prefixes, trailing /) that IMPROVE-FILE
  refuses to patch: they *define* the gate, so letting a patch edit them would
  make the gate meaningless.")

(defun repo-relative (path &key (root (repo-root-path)))
  "Return PATH made relative to ROOT when it is inside it, else NIL. Both sides
  are canonicalised lexically first, so '..' cannot smuggle a path out."
  (let* ((canon-root (agent-cl.core:canonical-path-string root))
         (canon (agent-cl.core:canonical-path-string path canon-root)))
    (when (agent-cl.core:path-inside-p canon canon-root)
      (let ((prefix (if (char= (char canon-root (1- (length canon-root))) #\/)
                        canon-root
                        (concatenate 'string canon-root "/"))))
        (subseq canon (length prefix))))))

(defun path-confinement-error (path)
  "Reason string when IMPROVE-FILE must refuse PATH, else NIL. Confined to the
  repository: this primitive rewrites files and runs a gate on the result, so an
  unrestricted path would let a patch touch any file on the machine."
  (let ((rel (repo-relative path)))
    (cond
      ((null rel)
       (format nil "拒绝修改仓库外的文件 ~a（允许范围 ~a）" path (repo-root-path)))
      ((some (lambda (p)
               (if (char= (char p (1- (length p))) #\/)
                   (and (>= (length rel) (length p))
                        (string= rel p :end1 (length p) :end2 (length p)))
                   (string-equal rel p)))
             *protected-paths*)
       (format nil "拒绝修改受保护的测试/门禁文件 ~a（它们定义了 gate 本身）" rel))
      (t nil))))

;; ---------------------------------------------------------------------------
;; main primitive
;; ---------------------------------------------------------------------------

(defun improve-file (path new-content test-runner
                    &key (backup-dir nil) (keep-backup-on-pass nil))
  "Propose NEW-CONTENT for source file PATH, gated by TEST-RUNNER.

  Contract (strict / safe):
   1. Validate PATH is readable, inside the repository (see
      PATH-CONFINEMENT-ERROR), and NEW-CONTENT is non-empty and differs from the
      file's current content. If identical -> (:status :no-change).
   2. Backup: write the *old* content verbatim to BACKUP-DIR before patching.
   3. Patch: write NEW-CONTENT to PATH.
   4. Gate: call (TEST-RUNNER), which returns (values OKP DETAIL).
            OKP -> (:status :adopted)
            not  -> restore old content from the backup, return
                    (:status :rolled-back :detail DETAIL).
   5. By default (KEEP-BACKUP-ON-PASS nil) the backup is deleted on adopt.

  Every failure path returns (:status :rejected ...) instead of signalling; the
  caller may pass non-string NEW-CONTENT and still get a state plist back.

  TEST-RUNNER runs once while the patched file is live on disk, so a real
  runner can load/re-test that exact content."
  (handler-case
      (progn
        (check-type new-content string)
        (let* ((pathname (or (ignore-errors (pathname path))
                             (return-from improve-file
                               (state-plist :status :rejected
                                            :detail "could not parse path"))))
               (refusal (path-confinement-error pathname)))
          ;; Refuse BEFORE touching the filesystem. Checking confinement as just
          ;; another COND clause used to read the file first, and a missing file
          ;; raised there — masking the real reason with an OS error.
          (if refusal
              (state-plist :status :rejected :detail refusal)
              (let* ((old-content (agent-cl.core:read-file-string pathname))
                     (bk-dir (uiop:ensure-directory-pathname
                              (or backup-dir (make-git-style-backup-dir))))
                     (clean-new (string-trim '(#\Newline #\Return #\Space)
                                             new-content)))
                (ensure-directories-exist bk-dir)
                (cond
                  ((null old-content)
                   (state-plist :status :rejected
                                :detail "path unreadable or absent"))
                  ((string= clean-new "")
                   (state-plist :status :rejected :detail "empty new content"))
                  ((string= old-content new-content)
                   (state-plist :status :no-change))
                  (t
                   (let ((bak (uiop:subpathname bk-dir (backup-filename pathname))))
                     ;; 1 backup old content
                     (agent-cl.core:write-file-string bak old-content)
                     (format t "~&[selfimprove] backup   ~a~%" (namestring bak))
                     ;; 2 patch
                     (agent-cl.core:write-file-string pathname new-content
                                                      :if-exists :supersede)
                     ;; 3 gate — if TEST-RUNNER RAISES (rather than returning) it is
                     ;;       still a FAILED gate: we must roll back, never leave a
                     ;;       half-applied patch. Errors from prior steps (backup/
                     ;;       write) still fall through to the outer handler.
                     (multiple-value-bind (okp detail)
                         (handler-case (funcall test-runner)
                           (error (e) (values nil (format nil "gate raised: ~a" e))))
                       (cond
                         (okp
                          (unless keep-backup-on-pass
                            (when (probe-file bak) (delete-file bak)))
                          (state-plist :status :adopted
                                       :detail (or detail "gate passed")))
                         (t
                          ;; 4 rollback from backup. A FAILED rollback must be
                          ;; reported as such: folding it into the generic
                          ;; :rejected path left a half-patched file with no way
                          ;; to tell that the ROLLBACK (not the patch) failed.
                          (handler-case
                              (progn
                                (agent-cl.core:write-file-string
                                 pathname old-content :if-exists :supersede)
                                (when (probe-file bak) (delete-file bak))
                                (state-plist :status :rolled-back
                                             :detail (or detail "gate failed")))
                            (error (e)
                              (state-plist
                               :status :rollback-failed
                               :retained t
                               :detail
                               (format nil "gate 失败，且回滚写回也失败（文件可能仍是补丁内容）: ~a；备份保留在 ~a"
                                       e (namestring bak)))))))))))))))
    (error (e)
      (state-plist :status :rejected :detail (format nil "~a" e)))))

(defun find-sbcl-exec ()
  "Return a pathname of an sbcl executable, or NIL. Lookup order: the
  AGENT_CL_SBCL env override, then the PATH list.

  POSIX-aware: the PATH separator is ':' and the executable is 'sbcl' there —
  hard-coding ';' and 'sbcl.exe' made the real gate report 'no sbcl executable
  found' on every non-Windows host."
  (let ((exe (if (uiop:os-windows-p) "sbcl.exe" "sbcl"))
        (sep (if (uiop:os-windows-p) ";" ":")))
    (or (let ((env (uiop:getenv "AGENT_CL_SBCL")))
          (and env (probe-file env)))
        (block search
          (dolist (d (uiop:split-string (or (uiop:getenv "PATH") "") :separator sep))
            (when (and d (plusp (length (string-trim '(#\Space) d))))
              (let ((cand (ignore-errors
                           (probe-file (merge-pathnames
                                        exe (uiop:ensure-directory-pathname d))))))
                (when cand (return-from search cand)))))
          nil)
        ;; last resort: the usual Windows install location
        (and (uiop:os-windows-p)
             (probe-file "C:\\Program Files\\Steel Bank Common Lisp\\sbcl.exe")))))

(defun tail-string (s n)
  "Return up to the last N characters of S, trim whitespace, as one string."
  (let* ((txt (or s ""))
         (txt (string-trim '(#\Newline #\Return #\Space) txt))
         (m (min n (length txt))))
    (subseq txt (- (length txt) m))))

(defun real-gate-runner (&key (root nil) (timeout 900))
  "Run the real repository test suite (scripts/run-tests.lisp) in a fresh
  subprocess as the gate for IMPROVE-FILE. Returns (values OKP DETAIL); OKP is
  T only when the suite exits 0 and reports '0 failed'. Safe to pass as
  TEST-RUNNER: any compile/load error in the patched file makes the subprocess
  fail, so a bad patch is seen and rolled back.

  The run is bounded by TIMEOUT seconds through AGENT-CL.CORE:RUN-PROGRAM-WITH-
  TIMEOUT. UIOP's own :TIMEOUT is a no-op on Windows, and an unbounded gate would
  otherwise hang the whole agent on a patched file that deadlocks the suite."
  (let* ((repo (uiop:ensure-directory-pathname (or root (repo-root-path))))
         (run-tests (probe-file (uiop:subpathname repo "scripts/run-tests.lisp")))
         (sbcl (find-sbcl-exec)))
    (cond
      ((null run-tests) (values nil "scripts/run-tests.lisp not found"))
      ((null sbcl)      (values nil "no sbcl executable found"))
      (t
       (multiple-value-bind (out err exit)
           (agent-cl.core:run-program-with-timeout
            (list (namestring sbcl) "--script" (namestring run-tests))
            :timeout timeout
            :directory repo)
         (declare (ignore err))
         (let ((txt (or out "")))
           (values (and (integerp exit) (zerop exit)
                        (not (null (search "0 failed" txt))))
                   (format nil "exit=~a (~a) tail=[~a]"
                           exit
                           (if (eq exit :timeout)
                               (format nil "超时 ~as 后终止" timeout)
                               "完成")
                           (tail-string txt 400)))))))))
