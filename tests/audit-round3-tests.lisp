;;;; tests/audit-round3-tests.lisp — regression tests for the third audit round.
;;;;
;;;; Each test locks down a defect that was REPRODUCED before the fix:
;;;;   * NTFS junctions/symlinks bypassed the workspace confinement
;;;;   * memory-key escapes were not self-delimiting (real collisions)
;;;;   * the sandbox sequence cap could never fire; a circular list hung it
;;;;   * the sandbox resolved whitelisted names through the CALLER's binding
;;;;   * a second audit rule for one tool replaced the first
;;;;   * :on-violation :warn could not do what it documents
;;;;   * defaudit accepted unknown/multi-valued clauses
;;;;   * norm-property-key signalled on a non-string key (escaping validation)
;;;;   * session ids became path components unchecked
;;;;   * web cache keys ignored the backend's case; provider text was unescaped
(in-package #:agent-cl.tests)

(defmacro with-isolated-dsl (&body body)
  `(let ((agent-cl.loop:*extra-guards* nil)
         (agent-cl.loop::*tool-guards* nil)
         (agent-cl.dsl::*declarations* (make-hash-table :test 'equal)))
     ,@body))

(defun list-length-safe-p (list &optional (limit 1000))
  "True when LIST is a proper list shorter than LIMIT (i.e. not circular)."
  (loop with n = 0 with slow = list with fast = list
        while (and (consp fast) (< n limit))
        do (incf n)
           (setf fast (cdr fast))
           (when (evenp n) (setf slow (cdr slow)))
           (when (eq fast slow) (return nil))
        finally (return (and (null fast) t))))

;;; ---------------------------------------------------------------------------
;;; workspace confinement: links are refused (verified on the real filesystem)
;;; ---------------------------------------------------------------------------

(deftest workspace-refuses-a-junction-inside-the-root
  "Confinement was purely lexical: a junction inside the workspace resolves to
  wherever it points, so file.read through it returned C:\\Windows\\win.ini while
  the direct path was refused (reproduced with `mklink /J`). The check now walks
  the existing components below the root and refuses a link."
  (if (not (uiop:os-windows-p))
      (ok t "junction check is Windows-specific; POSIX symlinks are covered by the same code path")
      (let* ((jail (merge-pathnames (format nil ".tools/tmp/jail-~a/"
                                            (agent-cl.core:uuid-string))
                                    (uiop:getcwd)))
             (jlink (merge-pathnames "jlink" jail))
             (win-link (substitute #\\ #\/ (namestring jlink)))
             (saved agent-cl.tools:*file-workspace-root*))
        (ensure-directories-exist jail)
        (uiop:run-program (list "cmd" "/c" "mklink" "/J" win-link "C:\\Windows")
                          :ignore-error-status t :output nil :error-output nil)
        (unwind-protect
             (progn
               ;; the fixture must really be a link, or this test proves nothing
               (ok (agent-cl.core:reparse-point-p (namestring jlink))
                   "the fixture must be a real junction")
               (agent-cl.tools:set-file-workspace-root (namestring jail))
               (multiple-value-bind (content status)
                   (agent-cl.tools:call-tool "file.read" (list :PATH "jlink/win.ini"))
                 (is-equal :error status "reading through the junction must be refused")
                 (ok (search "链接" content) "the refusal names the reason"))
               (multiple-value-bind (content status)
                   (agent-cl.tools:call-tool "file.write"
                                             (list :PATH "jlink/escaped.txt" :CONTENT "x"))
                 (declare (ignore content))
                 (is-equal :error status "writing through the junction must be refused"))
               ;; an ordinary path in the same root still works
               (multiple-value-bind (content status)
                   (agent-cl.tools:call-tool "file.write" (list :PATH "plain.txt" :CONTENT "ok"))
                 (declare (ignore content))
                 (is-equal :ok status "a normal path must still work"))
               (multiple-value-bind (content status)
                   (agent-cl.tools:call-tool "file.read" (list :PATH "plain.txt"))
                 (is-equal :ok status)
                 (is-equal "ok" content)))
          (setf agent-cl.tools:*file-workspace-root* saved)
          (uiop:run-program (list "cmd" "/c" "rmdir" win-link)
                            :ignore-error-status t :output nil :error-output nil)
          (ignore-errors (uiop:delete-directory-tree jail :validate t
                                                          :if-does-not-exist :ignore))))))

(deftest path-exists-p-covers-directories
  "UIOP:FILE-EXISTS-P is NIL for a directory, so the link walk skipped junction
  DIRECTORIES entirely — the reason the first version of the fix did nothing."
  (let ((dir (merge-pathnames (format nil ".tools/tmp/dircheck-~a/"
                                      (agent-cl.core:uuid-string))
                              (uiop:getcwd))))
    (ensure-directories-exist dir)
    (unwind-protect
         (progn
           (ok (agent-cl.core:path-exists-p (namestring dir))
               "a directory exists for the walk")
           (is-equal nil (uiop:file-exists-p (namestring dir))
                     "while UIOP:FILE-EXISTS-P says otherwise"))
      (ignore-errors (uiop:delete-directory-tree dir :validate t
                                                     :if-does-not-exist :ignore)))))

;;; ---------------------------------------------------------------------------
;;; self-improvement: protected gate files cannot be reached through an alias
;;; ---------------------------------------------------------------------------

(deftest selfimprove-protected-paths-resist-aliases
  "The protected-path test compared raw strings, so on Windows `TESTS/X.LISP` and
  `agent-cl.asd.` (trailing dot stripped by Win32) opened the protected files while
  no longer matching the entry — a patch could rewrite the gate itself."
  (flet ((refused-p (rel)
           (let ((full (merge-pathnames rel
                                        (agent-cl.selfimprove::repo-root-path))))
             (and (agent-cl.selfimprove::path-confinement-error full) t))))
    (ok (refused-p "tests/x.lisp") "the plain path is protected")
    (ok (refused-p "TESTS/X.LISP") "case variations must not slip through")
    (ok (refused-p "agent-cl.asd.") "a trailing dot must not slip through")
    (ok (refused-p "agent-cl.asd ") "a trailing space must not slip through")
    (ok (refused-p ".git/config") "the git directory is protected")
    (ok (refused-p ".tools/anything") "the vendored toolchain is protected")
    (ok (not (refused-p "src/core/util.lisp")) "an ordinary source file stays patchable")))

;;; ---------------------------------------------------------------------------
;;; sandbox: the caps must be reachable and circular structures refused
;;; ---------------------------------------------------------------------------

(deftest sandbox-refuses-circular-arguments
  "Walking a circular list never terminates and no deadline can break it: a
  circular argument hung the process for >120 s. The list is built programmatically
  because a reader label cannot appear twice in one top-level form."
  (agent-cl.dsl:with-dsl-sandbox (:mode :interpreter)
    (let ((circ (list 'a)))
      (setf (cdr circ) circ)                    ; #1=(a . #1#) without a label
      (ok (not (list-length-safe-p circ)) "the fixture really is circular")
      (signals-error agent-cl.core:dsl-error
        (agent-cl.dsl:dsl-eval-safe (list 'length (list 'quote circ))))
      (signals-error agent-cl.core:dsl-error
        (agent-cl.dsl:dsl-eval-safe (list 'reverse (list 'quote circ)))))
    ;; an ordinary list is still fine (and still bounded by the cap)
    (is-equal "3" (agent-cl.dsl:dsl-eval-safe '(length (list 1 2 3))))))

(deftest sandbox-sequence-cap-actually-fires
  "DSL-VALUE-SIZE saturated at LIMIT, so the > comparison in CHECK-OP-LIMITS could
  never be true — the argument cap was dead code."
  (agent-cl.dsl:with-dsl-sandbox (:mode :interpreter :max-sequence 10)
    (signals-error agent-cl.core:dsl-error
      (agent-cl.dsl:dsl-eval-safe '(length (list 1 2 3 4 5 6 7 8 9 10 11 12))))
    (is-equal "3" (agent-cl.dsl:dsl-eval-safe '(length (list 1 2 3)))))
  ;; the measuring helper reports "more than the limit" distinctly
  (is-equal 11 (agent-cl.dsl::dsl-value-size (loop repeat 50 collect 1) 10)))

(deftest sandbox-keyword-arguments-are-allowed
  "Bare symbols were all denied, so every whitelisted function with keyword
  parameters was unusable: (make-string 3 :initial-element #\\x) was rejected and
  make-string could only produce NUL characters."
  (agent-cl.dsl:with-dsl-sandbox (:mode :interpreter)
    (is-equal "xxx" (agent-cl.dsl:dsl-eval-safe
                     '(make-string 3 :initial-element #\x)))))

(deftest sandbox-resolves-whitelisted-names-in-cl-only
  "Whitelisted names were resolved through the CALLER's binding, so a package that
  shadows one (say EVIL::LIST) reached its own function — reproduced: it ran and
  wrote a file."
  (let ((pkg (make-package "AGENT-CL-EVIL-SANDBOX" :use '())))
    (unwind-protect
         (progn
           ;; a host function with a whitelisted NAME that proves it ran
           (let ((sym (intern "LIST" pkg)))
             (setf (symbol-function sym) (lambda (&rest args)
                                           (declare (ignore args))
                                           :escaped-host-function)))
           (agent-cl.dsl:with-dsl-sandbox (:mode :interpreter)
             (let ((got (agent-cl.dsl:dsl-eval-safe
                         (list (intern "LIST" pkg) 1 2))))
               (ok (not (search "escaped" got))
                   (format nil "the shadowing function must not run (~a)" got)))))
      (delete-package pkg))))

;;; ---------------------------------------------------------------------------
;;; audit rules: accumulate per tool, and :warn must not block
;;; ---------------------------------------------------------------------------

(deftest two-audit-rules-on-one-tool-both-apply
  "REGISTER-TOOL-GUARD kept ONE entry per tool name, so a second rule for the same
  tool silently REPLACED the first and the earlier rule stopped being preventive."
  (with-isolated-dsl
    (agent-cl.loop:register-tool-guard "probe.two"
                                       (lambda (a t1 args)
                                         (declare (ignore a t1 args))
                                         "first says no")
                                       :name "rule-one")
    (agent-cl.loop:register-tool-guard "probe.two"
                                       (lambda (a t1 args)
                                         (declare (ignore a t1 args))
                                         nil)
                                       :name "rule-two")
    (is-equal 2 (length (agent-cl.loop:tool-guard-rules-for "probe.two"))
              "both rules must be kept")
    (multiple-value-bind (action reason rule)
        (agent-cl.loop:tool-guard-decision nil "probe.two" nil)
      (is-equal :block action)
      (is-equal "first says no" reason)
      (is-equal "rule-one" rule))))

(deftest warn-audit-runs-the-tool-and-annotates
  "(:on-violation :warn) is documented as 'run it and annotate the result', but the
  rule was ALSO installed as a blocking global guard, so the turn stopped instead."
  (with-isolated-dsl
    (let ((ran nil))
      (register-tool
       (make-tool "probe.warned" (lambda (a c)
                                   (declare (ignore a c))
                                   (setf ran t)
                                   (values "payload" :ok))
                  :description "tool"))
      (unwind-protect
           (progn
             (eval '(agent-cl.dsl:defaudit warn-audit
                      (:applies-to probe.warned)
                      (:check (declare (ignore agent)) "beware")
                      (:on-violation :warn)))
             ;; a :warn rule must not become a global (turn-stopping) guard
             (ok (not (assoc "warn-audit" agent-cl.loop:*extra-guards*
                             :test #'string=))
                 ":warn must not register a blocking global guard")
             (let* ((agent (make-agent :transport (make-mock-transport) :tools nil))
                    (tc (make-tool-call "c1" "probe.warned" "{}")))
               (multiple-value-bind (content status)
                   (agent-cl.loop::dispatch-tool-call
                    agent tc (agent-cl.loop:make-policy))
                 (is-equal :ok status "the tool runs")
                 (is-equal t ran)
                 (ok (search "payload" content))
                 (ok (search "beware" content) "and the result is annotated"))))
        (unregister-tool "probe.warned")))))

(deftest defaudit-rejects-unknown-and-multi-valued-clauses
  "An unknown clause was accepted and silently dropped, and (:on-violation :block
  :extra) passed validation then expanded into a call of the keyword :BLOCK."
  (with-isolated-dsl
    (signals-error error
      (eval '(agent-cl.dsl:defaudit unknown-clause-audit
               (:check (declare (ignore agent)) nil)
               (:severity :high))))
    (signals-error error
      (eval '(agent-cl.dsl:defaudit multi-value-audit
               (:check (declare (ignore agent)) nil)
               (:on-violation :block :extra))))
    ;; :governed-by is a REFERENCE, not a tool scope
    (eval '(agent-cl.dsl:defaudit governed-audit
             (:governed-by some-principle)
             (:check (declare (ignore agent)) nil)))
    (is-equal nil (agent-cl.dsl:audit-applies-to 'governed-audit))
    (is-equal nil (agent-cl.loop:tool-guard-rules-for "some-principle"))))

;;; ---------------------------------------------------------------------------
;;; schema / session / web robustness
;;; ---------------------------------------------------------------------------

(deftest schema-validation-survives-non-string-keys
  "A decoded JSON key can be a number or a cons ('arguments': \"[1,2]\"), and
  NORM-PROPERTY-KEY signalled a type error — validation runs BEFORE call-tool's
  handler-case, so the whole turn aborted."
  (let ((schema (make-schema :kind :object
                             :properties (list (list "a" :type :string)))))
    ;; the defect was a TYPE ERROR escaping validation (and the engine), so the
    ;; contract being tested is "returns a problem list, never signals"
    (ok (listp (validate-json schema '(1 2))) "a non-plist value must not raise")
    (ok (listp (validate-json schema (list (list :a 1)))) "nested lists too")
    (ok (listp (validate-json schema '(1))) "a bare number too")
    (ok (validate-json schema '(:a 5)) "a genuinely bad scalar is still reported")
    ;; and the low-level helper is total now
    (ok (agent-cl.schema::norm-property-key 42) "numbers are accepted")
    (ok (agent-cl.schema::norm-property-key '(:a 1)) "conses are accepted")))

(deftest session-ids-are-validated-as-path-components
  "The id becomes a directory name that MAKE-SESSION creates and SESSION-APPEND
  writes through, so a traversal id computed a path outside the sessions root."
  (ok (agent-cl.session::valid-session-id-p "8bc1f85-abc_123"))
  (dolist (bad '("../../escapee" "..\\..\\escapee" "C:/Windows/Temp/x" "a/b" ""
                 "con?" "x y"))
    (ok (not (agent-cl.session::valid-session-id-p bad))
        (format nil "~s must be rejected" bad)))
  (signals-error error
    (agent-cl.session:make-session :id "../../escapee"
                                   :directory (uiop:getcwd))))

(deftest web-cache-key-ignores-the-backend-case
  "\"tavily\", \"Tavily\" and \"TAVILY\" were three separate cache entries AND three
  separate billable requests."
  (is-equal (agent-cl.web::cache-key "tavily" "q" 5)
            (agent-cl.web::cache-key "TAVILY" " q " 5)))

(deftest web-provider-text-is-made-safe
  "A non-string provider field raised inside the caller's handler, so a SUCCESSFUL
  search was reported as a failure; control characters reached the terminal."
  (is-equal "42" (agent-cl.web::safe-text 42))
  (is-equal "a b" (agent-cl.web::safe-text (concatenate 'string "a"
                                                        (string (code-char 27))
                                                        " b")))
  (let* ((results (list (list :title (concatenate 'string "bad"
                                                  (string (code-char 27))
                                                  "title")
                              :url "http://x"
                              :content "c")))
         (text (agent-cl.web::format-results results)))
    (is-equal nil (find (code-char 27) text) "no ESC in the rendered text")
    (ok (search "badtitle" text))))
