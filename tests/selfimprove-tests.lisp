;;;; tests/selfimprove-tests.lisp — guarded self-improvement primitive.
;;;;
;;;; These tests exercise the *gate contract* of agent-cl.selfimprove:improve-file
;;;; using mock test-runners. They prove the mechanism can adopt a good patch and
;;;; roll a bad one back, without ever touching real source files (a throwaway
;;;; file under .tools/ is used). Real-source patching is deliberately NOT tested
;;;; here — that is a manual, audited operation.
(in-package #:agent-cl.tests)

(defparameter *si-test-file* ".tools/si-test-target.txt")

(defmacro with-writable-fixture (&body body)
  "Run BODY with the protected-path list minus the .tools/ prefix.

  The fixtures at .tools/si-test-target.txt are the throwaway target of the GATE
  contract tests; .tools/ is protected in production because it holds the vendored
  dependencies and the ASDF cache. The protection behaviour itself is covered by
  SELFIMPROVE-REFUSES-TO-PATCH-THE-GATE-ITSELF and
  SELFIMPROVE-REFUSES-PATHS-OUTSIDE-THE-REPO, which use the real list."
  `(let ((agent-cl.selfimprove::*protected-paths*
           (remove ".tools/" agent-cl.selfimprove::*protected-paths*
                   :test #'string=)))
     ,@body))

(defun write-si-old ()
  (write-file-string *si-test-file* "OLD-CONTENT"))

(defun read-si ()
  (read-file-string *si-test-file*))

;; --- adopt: a patch whose gate passes is kept ---------------------------------
(deftest selfimprove-adopts-passing-patch
  (with-writable-fixture
     (write-si-old)
  (let ((res (agent-cl.selfimprove:improve-file
              *si-test-file* "NEW-CONTENT"
              (lambda () (values t "ok")))))
    (is-equal :adopted (getf res :status))
    (is-equal "NEW-CONTENT" (read-si)))))


;; --- rollback: a patch whose gate fails restores the original bytes -----------
(deftest selfimprove-rolls-back-failing-patch
  (with-writable-fixture
     (write-si-old)
  (let ((res (agent-cl.selfimprove:improve-file
              *si-test-file* "BROKEN-CONTENT"
              (lambda () (values nil "build failed")))))
    (is-equal :rolled-back (getf res :status))
    (is-equal "OLD-CONTENT" (read-si) "file must be byte-restored after a bad patch"))))


;; --- no-op: identical content changes nothing --------------------------------
(deftest selfimprove-nochange-on-identical-content
  (with-writable-fixture
     (write-si-old)
  (let ((res (agent-cl.selfimprove:improve-file
              *si-test-file* "OLD-CONTENT"
              (lambda () (values t nil)))))
    (is-equal :no-change (getf res :status))
    (is-equal "OLD-CONTENT" (read-si)))))


;; --- reject: absent / unreadable path ----------------------------------------
(deftest selfimprove-rejects-absent-path
  (with-writable-fixture
     (let ((res (agent-cl.selfimprove:improve-file
              ".tools/definitely-not-here-si.txt" "x"
              (lambda () (values t nil)))))
    (is-equal :rejected (getf res :status)))))


;; --- reject: blank content ----------------------------------------------------
(deftest selfimprove-rejects-blank-content
  (with-writable-fixture
     (write-si-old)
  (let ((res (agent-cl.selfimprove:improve-file
              *si-test-file* "   " (lambda () (values t nil)))))
    (is-equal :rejected (getf res :status))
    (is-equal "OLD-CONTENT" (read-si) "file untouched when new content blank"))))


;; --- audit: adopting with keep-backup-on-pass leaves a trace ------------------
(deftest selfimprove-keep-backup-on-pass
  (with-writable-fixture
     (write-si-old)
  (let* ((bkdir ".tools/si-bk-test/")
         (res (agent-cl.selfimprove:improve-file
               *si-test-file* "AUDITED-CONTENT"
               (lambda () (values t "audit ok"))
               :backup-dir bkdir
               :keep-backup-on-pass t)))
    (is-equal :adopted (getf res :status))
    (is-equal "AUDITED-CONTENT" (read-si))
    ;; a .bak file must now exist under bkdir
    (ok (probe-file bkdir))
    (ok (plusp (length (directory bkdir))))
    ;; tidy: revert and remove backup dir so later runs stay deterministic
    (agent-cl.core:write-file-string *si-test-file* "OLD-CONTENT" :if-exists :supersede)
    (dolist (f (directory bkdir)) (ignore-errors (delete-file f)))
    (ignore-errors ; whole-session --script leaves the tree; fine under harness
      ))
  (ignore-errors (delete-file ".tools/si-test-target.txt"))))



;; --- gate raises an exception -> treated as a failed gate, rolls back --------
(deftest selfimprove-gate-throws-rolls-back
  (with-writable-fixture
     ;; A gate that signals (rather than returning nil) must NOT leave a partial
  ;; patch: the file has to be rolled back to its original bytes.
  (write-si-old)
  (let* ((bkdir ".tools/si-throw-bk/")
         (res (agent-cl.selfimprove:improve-file
               *si-test-file* "SHOULD-NOT-STICK"
               (lambda () (error "runner exploded"))   ; gate raises
               :backup-dir bkdir)))
    (is-equal :rolled-back (getf res :status)
              "a raising gate is a failed gate, so we roll back")
    (is-equal "OLD-CONTENT" (read-si)
              "file must be restored even when the gate raises")
    (ok (search "gate raised" (or (getf res :detail) ""))
        "detail should mention the gate exception")
    ;; tidy
    (agent-cl.core:write-file-string *si-test-file* "OLD-CONTENT" :if-exists :supersede)
    (when (probe-file bkdir)
      (dolist (f (directory bkdir)) (ignore-errors (delete-file f)))))
  (ignore-errors (delete-file ".tools/si-test-target.txt"))))



;; --- confinement: the primitive must not rewrite files outside the repo -------
(deftest selfimprove-refuses-paths-outside-the-repo
  "IMPROVE-FILE rewrites a file and then gates the result, so an unrestricted
  path would let a patch touch anything on the machine (C:\\Windows, ~/.ssh)."
  (dolist (evil (list "../../../../Windows/win.ini"
                      "../outside.txt"
                      "C:/Windows/win.ini"))
    (let ((res (agent-cl.selfimprove:improve-file
                evil "PWNED" (lambda () (values t "ok")))))
      (is-equal :rejected (getf res :status) (format nil "~a must be refused" evil))
      (ok (search "仓库外" (or (getf res :detail) ""))
          "the refusal should say it is outside the repository")))
  ;; and no stray file was created next to the attempted target
  (is-equal nil (probe-file "../outside.txt")))

(deftest selfimprove-refuses-to-patch-the-gate-itself
  "scripts/run-tests.lisp, tests/ and agent-cl.asd define the gate; a patch that
  edits them would make the gate meaningless (a two-step bypass)."
  (dolist (guarded '("scripts/run-tests.lisp"
                     "tests/selfimprove-tests.lisp"
                     "agent-cl.asd"))
    (let ((before (read-file-string guarded))
          (res (agent-cl.selfimprove:improve-file
                guarded ";;;; pwned" (lambda () (values t "ok")))))
      (is-equal :rejected (getf res :status)
                (format nil "~a must be protected" guarded))
      (ok (search "受保护" (or (getf res :detail) "")))
      ;; the real file is intact
      (is-equal before (read-file-string guarded)
                (format nil "~a must be unchanged" guarded)))))

(deftest selfimprove-rejects-non-string-content-without-signalling
  "CHECK-TYPE used to sit OUTSIDE the handler-case, so a bad argument signalled
  instead of returning the documented state plist."
  (let ((res (agent-cl.selfimprove:improve-file
              *si-test-file* 42 (lambda () (values t "ok")))))
    (is-equal :rejected (getf res :status))
    (ok (getf res :detail))))

(deftest selfimprove-repo-root-is-the-actual-repo
  "REPO-ROOT-PATH used to walk up only one level (src/ instead of the repo root,
  and the fasl cache dir under ASDF), so the real gate would never find
  scripts/run-tests.lisp. It must now locate agent-cl.asd."
  (let ((root (agent-cl.selfimprove::repo-root-path)))
    (ok (probe-file (uiop:subpathname root "agent-cl.asd"))
        (format nil "~a should hold agent-cl.asd" root))
    (ok (probe-file (uiop:subpathname root "scripts/run-tests.lisp"))
        "the gate script must be reachable from the repo root")))

(deftest selfimprove-confinement-works-inside-the-repo
  (with-writable-fixture
     "The confinement must not break the normal case: a path inside the repo (the
  throwaway .tools/ target used by these tests) is accepted."
  (write-si-old)
  (is-equal ".tools/si-test-target.txt"
            (agent-cl.selfimprove::repo-relative *si-test-file*))
  (let ((res (agent-cl.selfimprove:improve-file
              *si-test-file* "CONFINED-OK" (lambda () (values t "ok")))))
    (is-equal :adopted (getf res :status))
    (is-equal "CONFINED-OK" (read-si)))
  (ignore-errors (delete-file ".tools/si-test-target.txt"))))

