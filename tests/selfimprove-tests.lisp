;;;; tests/selfimprove-tests.lisp — guarded self-improvement primitive.
;;;;
;;;; These tests exercise the *gate contract* of agent-cl.selfimprove:improve-file
;;;; using mock test-runners. They prove the mechanism can adopt a good patch and
;;;; roll a bad one back, without ever touching real source files (a throwaway
;;;; file under .tools/ is used). Real-source patching is deliberately NOT tested
;;;; here — that is a manual, audited operation.
(in-package #:agent-cl.tests)

(defparameter *si-test-file* ".tools/si-test-target.txt")

(defun write-si-old ()
  (write-file-string *si-test-file* "OLD-CONTENT"))

(defun read-si ()
  (read-file-string *si-test-file*))

;; --- adopt: a patch whose gate passes is kept ---------------------------------
(deftest selfimprove-adopts-passing-patch
  (write-si-old)
  (let ((res (agent-cl.selfimprove:improve-file
              *si-test-file* "NEW-CONTENT"
              (lambda () (values t "ok")))))
    (is-equal :adopted (getf res :status))
    (is-equal "NEW-CONTENT" (read-si))))

;; --- rollback: a patch whose gate fails restores the original bytes -----------
(deftest selfimprove-rolls-back-failing-patch
  (write-si-old)
  (let ((res (agent-cl.selfimprove:improve-file
              *si-test-file* "BROKEN-CONTENT"
              (lambda () (values nil "build failed")))))
    (is-equal :rolled-back (getf res :status))
    (is-equal "OLD-CONTENT" (read-si) "file must be byte-restored after a bad patch")))

;; --- no-op: identical content changes nothing --------------------------------
(deftest selfimprove-nochange-on-identical-content
  (write-si-old)
  (let ((res (agent-cl.selfimprove:improve-file
              *si-test-file* "OLD-CONTENT"
              (lambda () (values t nil)))))
    (is-equal :no-change (getf res :status))
    (is-equal "OLD-CONTENT" (read-si))))

;; --- reject: absent / unreadable path ----------------------------------------
(deftest selfimprove-rejects-absent-path
  (let ((res (agent-cl.selfimprove:improve-file
              ".tools/definitely-not-here-si.txt" "x"
              (lambda () (values t nil)))))
    (is-equal :rejected (getf res :status))))

;; --- reject: blank content ----------------------------------------------------
(deftest selfimprove-rejects-blank-content
  (write-si-old)
  (let ((res (agent-cl.selfimprove:improve-file
              *si-test-file* "   " (lambda () (values t nil)))))
    (is-equal :rejected (getf res :status))
    (is-equal "OLD-CONTENT" (read-si) "file untouched when new content blank")))

;; --- audit: adopting with keep-backup-on-pass leaves a trace ------------------
(deftest selfimprove-keep-backup-on-pass
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
  (ignore-errors (delete-file ".tools/si-test-target.txt")))


;; --- gate raises an exception -> treated as a failed gate, rolls back --------
(deftest selfimprove-gate-throws-rolls-back
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
  (ignore-errors (delete-file ".tools/si-test-target.txt")))
