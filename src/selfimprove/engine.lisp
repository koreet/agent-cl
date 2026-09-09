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
;; main primitive
;; ---------------------------------------------------------------------------

(defun improve-file (path new-content test-runner
                    &key (backup-dir nil) (keep-backup-on-pass nil))
  "Propose NEW-CONTENT for source file PATH, gated by TEST-RUNNER.

  Contract (strict / safe):
   1. Validate PATH is readable and NEW-CONTENT is non-empty and differs from
      the file's current content. If identical -> (:status :no-change).
   2. Backup: write the *old* content verbatim to BACKUP-DIR before patching.
   3. Patch: write NEW-CONTENT to PATH.
   4. Gate: call (TEST-RUNNER), which returns (values OKP DETAIL).
            OKP -> (:status :adopted)
            not  -> restore old content from the backup, return
                    (:status :rolled-back :detail DETAIL).
   5. By default (KEEP-BACKUP-ON-PASS nil) the backup is deleted on adopt.

  TEST-RUNNER runs once while the patched file is live on disk, so a real
  runner can load/re-test that exact content."
  (check-type new-content string)
  (handler-case
      (let* ((pathname (or (ignore-errors (pathname path))
                           (return-from improve-file
                             (state-plist :status :rejected
                                          :detail "could not parse path"))))
             (old-content (agent-cl.core:read-file-string pathname))
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
             ;; 3 gate — if TEST-RUNNER RAISES (rather than returning) it is still
             ;;       a FAILED gate: we must roll back, never leave a half-applied
             ;;       patch. Errors from prior steps (backup/write) still fall
             ;;       through to the outer handler as :rejected.
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
                  ;; 4 rollback from backup
                  (agent-cl.core:write-file-string pathname old-content
                                                   :if-exists :supersede)
                  (when (probe-file bak) (delete-file bak))
                  (state-plist :status :rolled-back
                               :detail (or detail "gate failed")))))))))
    (error (e)
      (state-plist :status :rejected :detail (format nil "~a" e)))))
;; ---------------------------------------------------------------------------
;; real production gate runner (adopted via improve-file self-edit)
;; ---------------------------------------------------------------------------

(defun repo-root-path ()
  "Repository root: the directory containing scripts/run-tests.lisp. Derived
  from the location of this source file so no absolute path is hard-coded."
  (uiop:ensure-directory-pathname
   (uiop:pathname-parent-directory-pathname
    (uiop:pathname-directory-pathname
     (or *load-pathname*
         (uiop:getcwd))))))

(defun find-sbcl-exec ()
  "Return a pathname of an sbcl executable, or NIL. Lookup order: the
  AGENT_CL_SBCL env override, the PATH list, then the Windows install dir."
  (or (and (uiop:getenv "AGENT_CL_SBCL")
           (probe-file (uiop:getenv "AGENT_CL_SBCL")))
      (block search
        (dolist (d (uiop:split-string (or (uiop:getenv "PATH") "") :separator ";"))
          (when (and d (plusp (length (string-trim '(#\Space) d))))
            (let ((cand (probe-file
                         (merge-pathnames
                          "sbcl.exe" (uiop:ensure-directory-pathname d)))))
              (when cand (return-from search cand)))))
        nil)
      (and (uiop:os-windows-p)
           (probe-file "C:\\Program Files\\Steel Bank Common Lisp\\sbcl.exe"))))

(defun tail-string (s n)
  "Return up to the last N characters of S, trim whitespace, as one string."
  (let* ((txt (or s ""))
         (txt (string-trim '(#\Newline #\Return #\Space) txt))
         (m (min n (length txt))))
    (subseq txt (- (length txt) m))))

(defun real-gate-runner (&key (root nil))
  "Run the real repository test suite (scripts/run-tests.lisp) in a fresh
  subprocess as the gate for IMPROVE-FILE. Returns (values OKP DETAIL); OKP is
  T only when the suite exits 0 and reports '0 failed'. Safe to pass as
  TEST-RUNNER: any compile/load error in the patched file makes the subprocess
  fail, so a bad patch is seen and rolled back."
  (let* ((repo (uiop:ensure-directory-pathname (or root (repo-root-path))))
         (run-tests (probe-file (uiop:subpathname repo "scripts/run-tests.lisp")))
         (sbcl (find-sbcl-exec)))
    (cond
      ((null run-tests) (values nil "scripts/run-tests.lisp not found"))
      ((null sbcl)      (values nil "no sbcl executable found"))
      (t
       (multiple-value-bind (out err exit)
           (uiop:run-program (list (namestring sbcl) "--script"
                                   (namestring run-tests))
                             :output :string :error-output :string
                             :directory (namestring repo)
                             :ignore-error-status t)
         (declare (ignore err))
         (let ((txt (or out "")))
           (values (and (integerp exit) (zerop exit)
                        (not (null (search "0 failed" txt))))
                   (format nil "exit=~a tail=[~a]" exit (tail-string txt 400)))))))))
