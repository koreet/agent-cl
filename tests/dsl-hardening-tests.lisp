;;;; tests/dsl-hardening-tests.lisp — regression tests for the DSL audit.
;;;;
;;;; Every test here corresponds to a defect that was reproduced on the real
;;;; machine first. They are grouped by the module they protect:
;;;;   * DSL macros   — option expansion, policy registry, literal-vs-code
;;;;   * guards       — re-registration, fail-closed behaviour, agent :guard
;;;;   * tool guards  — the PREVENTIVE half of an audit rule
;;;;   * principles   — the constitution (including the two-step bypass)
;;;;   * goals        — () lambda-list, predicate diagnostics, blocked subgoals
;;;;   * introspect   — single-signal confidence
;;;;   * sandbox      — compute caps and the per-call step reset
(in-package #:agent-cl.tests)

(defmacro with-fresh-dsl-state (&body body)
  "Isolated declarations + guards + tool guards, so a rule registered here can
  never leak into another test's engine run."
  `(let ((agent-cl.dsl::*declarations* (make-hash-table :test 'equal))
         (agent-cl.loop:*extra-guards* nil)
         (agent-cl.loop:*tool-guards* nil))
     ,@body))

;;; ---------------------------------------------------------------------------
;;; DSL macros: option expansion + policy registry
;;; ---------------------------------------------------------------------------

(deftest dsl-defagent-tools-nil-means-no-tools
  "(:tools ()) / (:tools nil) must mean NO tools. The old literal test accepted
  NIL as a 'literal tool list', and BUILD-AGENT-FROM-OPTIONS then fell back to
  :all — asking for no tools silently granted every tool."
  (let ((a (agent-cl.dsl::build-agent-from-options '(:tools nil))))
    (is-equal nil (agent-cl.loop:agent-tools a)))
  (let ((b (agent-cl.dsl::build-agent-from-options (list :tools
                                                          (agent-cl.dsl::quote-name-list nil)))))
    (is-equal nil (agent-cl.loop:agent-tools b)))
  ;; and no :tools option at all still means :all
  (is-equal :all (agent-cl.loop:agent-tools
                  (agent-cl.dsl::build-agent-from-options '(:system "x")))))

(deftest dsl-defagent-evaluates-call-shaped-tool-lists
  "(:tools (list \"a\" \"b\")) is CODE. Quoting it as data produced the literal
  three-element list (list \"a\" \"b\") as the tool set."
  (is-equal nil (agent-cl.dsl::literal-name-list-p '(list "a" "b")))
  (ok (agent-cl.dsl::literal-name-list-p '(shell.run file.read)))
  ;; the form is left alone by the quote-decision ...
  (is-equal '(list "a" "b") (agent-cl.dsl::quote-name-list '(list "a" "b")))
  ;; ... so DEFAGENT evaluates it and the agent gets the two names
  (eval '(agent-cl.dsl:defagent harden-list-bot (:tools (list "a" "b"))))
  ;; SYMBOL-VALUE: the defparameter comes from EVAL, so a compiled reference
  ;; would warn about an undefined variable
  (is-equal '("a" "b") (agent-cl.loop:agent-tools (symbol-value 'harden-list-bot))))

(deftest dsl-defagent-options-keep-their-pairing
  "EXPAND-AGENT-OPTIONS used (list* .. (nreverse ..)), which reverses plist
  ELEMENTS: :system received the system string as its key and every value shifted
  onto the next key."
  (let ((pairs (agent-cl.dsl::expand-agent-options
                '(:system "S" :tools (dsl.add) :policy chatty))))
    (is-equal :system (first pairs))
    (is-equal "S" (second pairs))
    (is-equal :tools (third pairs))
    (is-equal :policy (fifth pairs))))

(deftest dsl-defpolicy-registers-by-name
  "A policy was reachable only through the defining package's variable; it is now
  also addressable by name, and an unknown name reports the known ones instead of
  building a broken agent."
  (let ((agent-cl.dsl::*policies* (make-hash-table :test 'equal)))
    (eval '(agent-cl.dsl:defpolicy harden-chatty (:max-steps 12 :temperature 0.25)))
    (ok (member "harden-chatty" (agent-cl.dsl:list-policy-names) :test #'string=))
    (ok (agent-cl.dsl:find-policy 'harden-chatty))
    (ok (agent-cl.dsl:find-policy "HARDEN-CHATTY"))
    (let ((a (agent-cl.dsl::build-agent-from-options '(:policy harden-chatty))))
      (is-equal 12 (agent-cl.loop:policy-max-steps (agent-cl.loop:agent-policy a))))
    (signals-error error
      (agent-cl.dsl::build-agent-from-options '(:policy no-such-policy)))))

;;; ---------------------------------------------------------------------------
;;; guards: re-registration, fail-closed, agent-level :guard
;;; ---------------------------------------------------------------------------

(deftest dsl-guard-re-registration-replaces-the-function
  "REGISTER-GUARD used PUSHNEW: re-registering a name kept the OLD function, so
  defguard-edit + reload silently kept running the previous rule."
  (with-fresh-dsl-state
    (agent-cl.loop:register-guard "g1" (lambda (a) (declare (ignore a)) "old"))
    (let ((agent (make-agent :transport (make-mock-transport) :tools nil)))
      (is-equal "old" (agent-cl.loop:check-extra-guards agent)))
    (agent-cl.loop:register-guard "g1" (lambda (a) (declare (ignore a)) nil))
    (let ((agent (make-agent :transport (make-mock-transport) :tools nil)))
      (is-equal nil (agent-cl.loop:check-extra-guards agent)))
    (is-equal 1 (length agent-cl.loop:*extra-guards*))
    (ok (agent-cl.loop:unregister-guard "g1"))
    (is-equal nil agent-cl.loop:*extra-guards*)))

(deftest dsl-raising-guard-fails-closed
  "A guard that signals used to abort the run through an unhandled error path.
  It must be treated as a TRIP (fail closed), never as a pass."
  (with-fresh-dsl-state
    (agent-cl.loop:register-guard "boom" (lambda (a) (declare (ignore a))
                                     (error "kaboom")))
    (let* ((agent (make-agent :transport (make-mock-transport) :tools nil))
           (reason (agent-cl.loop:check-extra-guards agent)))
      (ok reason "a raising guard must produce a reason, not a pass")
      (ok (search "boom" reason)))))

(deftest dsl-agent-guard-slot-is-consulted
  "The agent's own :guard slot was stored and never read, so (defagent x
  (:guard f)) silently did nothing."
  (with-fresh-dsl-state
    (let ((agent (make-agent :transport (make-mock-transport) :tools nil
                             :guard (lambda (a) (declare (ignore a)) "own"))))
      (is-equal "own" (agent-cl.loop:check-extra-guards agent)))
    ;; a list of designators is accepted too
    (let ((agent (make-agent :transport (make-mock-transport) :tools nil
                             :guard (list (lambda (a) (declare (ignore a)) nil)
                                          (lambda (a) (declare (ignore a)) "second")))))
      (is-equal "second" (agent-cl.loop:check-extra-guards agent)))))

;;; ---------------------------------------------------------------------------
;;; preventive tool guards (the half that can actually refuse a call)
;;; ---------------------------------------------------------------------------

(deftest tool-guard-blocks-before-the-tool-runs
  "An audit that only registers a global guard is consulted at the top of a step,
  i.e. AFTER the offending tool already ran. A :block tool guard must refuse the
  call so the side effect never happens."
  (with-fresh-dsl-state
    (let ((ran nil))
      (register-tool
       (make-tool "harden.effect" (lambda (a c) (declare (ignore a c))
                                    (setf ran t) (values "did it" :ok))
                  :description "side effect"))
      (unwind-protect
           (progn
             (agent-cl.loop:register-tool-guard
              "harden.effect" (lambda (a tool args)
                                (declare (ignore a tool args))
                                "not allowed here")
              :name "no-effect")
             (let* ((agent (make-agent :transport (make-mock-transport) :tools nil))
                    (tc (make-tool-call "c1" "harden.effect" "{}")))
               (multiple-value-bind (content status)
                   (agent-cl.loop::dispatch-tool-call
                    agent tc (agent-cl.loop:make-policy))
                 (is-equal :error status)
                 (ok (search "no-effect" content) "the refusal names the rule")
                 (is-equal nil ran "the tool must NOT have run"))))
        (unregister-tool "harden.effect")))))

(deftest tool-guard-warn-runs-and-annotates
  "(:on-violation :warn) runs the tool but annotates the result, so the model sees
  the rule was violated without the work being lost."
  (with-fresh-dsl-state
    (register-tool
     (make-tool "harden.warned" (lambda (a c) (declare (ignore a c))
                                  (values "payload" :ok))
                :description "tool"))
    (unwind-protect
         (progn
           (agent-cl.loop:register-tool-guard
            "harden.warned" (lambda (a tool args) (declare (ignore a tool args)) "careful")
            :on-violation :warn :name "warn-rule")
           (let* ((agent (make-agent :transport (make-mock-transport) :tools nil))
                  (tc (make-tool-call "c1" "harden.warned" "{}")))
             (multiple-value-bind (content status)
                 (agent-cl.loop::dispatch-tool-call agent tc (agent-cl.loop:make-policy))
               (is-equal :ok status)
               (ok (search "payload" content))
               (ok (search "warn-rule" content)))))
      (unregister-tool "harden.warned"))))

(deftest tool-guard-wildcard-and-fail-closed
  "The wildcard applies to every tool, and a rule that raises BLOCKS."
  (with-fresh-dsl-state
    (register-tool
     (make-tool "harden.any" (lambda (a c) (declare (ignore a c)) (values "x" :ok))
                :description "tool"))
    (unwind-protect
         (progn
           (agent-cl.loop:register-tool-guard
            "any" (lambda (a tool args) (declare (ignore a tool args)) (error "broken rule"))
            :name "broken")
           (let* ((agent (make-agent :transport (make-mock-transport) :tools nil))
                  (tc (make-tool-call "c1" "harden.any" "{}")))
             (multiple-value-bind (content status)
                 (agent-cl.loop::dispatch-tool-call agent tc (agent-cl.loop:make-policy))
               (is-equal :error status)
               (ok (search "broken" content)))))
      (unregister-tool "harden.any"))))

(deftest defaudit-registers-a-preventive-tool-guard
  "DEFWAUDIT with :applies-to must register BOTH the global guard and a
  pre-execution rule for the named tools — the metadata alone changed nothing
  about when the rule ran."
  (with-fresh-dsl-state
    (eval '(agent-cl.dsl:defaudit harden-audit
             (:applies-to harden.audited)
             (:check (declare (ignore agent)) "audit says no")
             (:on-violation :block)
             (:intent "documentation only")
             (:evidence (:kind :path-prefix :source "workspace-root"))))
    (ok (agent-cl.dsl:audit-preventive-p 'harden-audit))
    (is-equal '(harden.audited) (agent-cl.dsl:audit-applies-to 'harden-audit))
    (is-equal :block (agent-cl.dsl:audit-on-violation 'harden-audit))
    (is-equal "documentation only" (agent-cl.dsl:audit-intent 'harden-audit))
    (ok (agent-cl.dsl:audit-evidence 'harden-audit))
    ;; a rule really is installed for the tool
    (ok (agent-cl.loop:tool-guard-rules-for "harden.audited"))
    ;; ... and it is enforced: the tool never runs
    (let ((ran nil))
      (register-tool
       (make-tool "harden.audited" (lambda (a c) (declare (ignore a c))
                                     (setf ran t) (values "ran" :ok))
                  :description "tool"))
      (unwind-protect
           (let* ((agent (make-agent :transport (make-mock-transport) :tools nil))
                  (tc (make-tool-call "c1" "harden.audited" "{}")))
             (multiple-value-bind (content status)
                 (agent-cl.loop::dispatch-tool-call agent tc (agent-cl.loop:make-policy))
               (is-equal :error status)
               (ok (search "audit says no" content))
               (is-equal nil ran)))
        (unregister-tool "harden.audited")))))

(deftest defaudit-rejects-malformed-clauses
  "A mistyped :on-violation used to be accepted and then treated as :block
  silently; a malformed clause polluted the spec instead of failing."
  (with-fresh-dsl-state
    (signals-error error
      (eval '(agent-cl.dsl:defaudit bad-audit
               (:applies-to some.tool)
               (:check nil)
               (:on-violation :explode))))
    (signals-error error
      (eval '(agent-cl.dsl:defaudit bad-audit-2
               (:applies-to some.tool)
               (:check nil)
               bad-clause)))))

(deftest defaudit-intent-is-data-not-code
  "(:intent ...) was spliced into the declaration UNQUOTED, so a list-shaped
  intent was evaluated at load time."
  (with-fresh-dsl-state
    (eval '(agent-cl.dsl:defaudit intent-audit
             (:check (declare (ignore agent)) nil)
             (:intent (this-is not a call))))
    (is-equal '(this-is not a call) (agent-cl.dsl:audit-intent 'intent-audit))))

;;; ---------------------------------------------------------------------------
;;; principles: the constitution cannot be talked out of the top slot
;;; ---------------------------------------------------------------------------

(deftest dsl-constitution-two-step-bypass-refused
  "Raise another principle above the constitution, THEN demote it: with
  constitutionality recomputed from live priorities this destroyed the
  human-owned layer without a single :refused."
  (with-fresh-dsl-state
    (eval '(agent-cl.dsl:defprinciple hb-const () (:priority 100)))
    (eval '(agent-cl.dsl:defprinciple hb-other () (:priority 10)))
    (ok (agent-cl.dsl:constitution-p 'hb-const))
    (is-equal :ok (agent-cl.dsl:change-principle-priority 'hb-other 500))
    (ok (agent-cl.dsl:constitution-p 'hb-const)
        "raising a peer must not un-freeze the constitution")
    (is-equal :refused (agent-cl.dsl:change-principle-priority 'hb-const 0))
    (is-equal 100 (agent-cl.dsl:principle-priority 'hb-const))))

(deftest dsl-principle-rejects-non-integer-priority
  "(:priority \"high\") registered a string, and CONSTITUTION-P then compared it
  with EQL and reported 'not constitutional'."
  (with-fresh-dsl-state
    (signals-error error
      (eval '(agent-cl.dsl:defprinciple bad-prio () (:priority "high"))))
    (signals-error error
      (eval '(agent-cl.dsl:defprinciple bad-prio2 () (:priority 1.5))))))

(deftest dsl-unknown-declaration-queries-return-nil
  "Querying a name that was never declared must be a NIL result, not an error:
  DECL-SPEC was called on NIL and signalled."
  (with-fresh-dsl-state
    (is-equal nil (agent-cl.dsl:constitution-p 'never-declared))
    (is-equal nil (agent-cl.dsl:principle-priority 'never-declared))
    (is-equal nil (agent-cl.dsl:principle-statement 'never-declared))
    (is-equal nil (agent-cl.dsl:audit-applies-to 'never-declared))
    (is-equal :block (agent-cl.dsl:audit-on-violation 'never-declared)
              "documented default action for an absent rule")
    (is-equal nil (agent-cl.dsl:goal-intent 'never-declared))
    (is-equal nil (agent-cl.dsl:memory-salience 'never-declared))
    (is-equal nil (agent-cl.dsl:identity-anchor 'never-declared))))

(deftest dsl-declarations-are-package-qualified-and-resettable
  "DECL-KEY dropped the package, so PKG-A::RULE and PKG-B::RULE shared one slot
  and the second silently replaced the first. There was also no way to reset the
  global table."
  (with-fresh-dsl-state
    (let ((pa (make-package "AGENT-CL-HARDEN-A" :use '(:cl)))
          (pb (make-package "AGENT-CL-HARDEN-B" :use '(:cl))))
      (unwind-protect
           (progn
             (let ((da (agent-cl.dsl:make-declaration
                        (intern "RULE" pa) :principle :spec (list :priority 100)))
                   (db (agent-cl.dsl:make-declaration
                        (intern "RULE" pb) :principle :spec (list :priority 10))))
               (agent-cl.dsl:register-declaration da)
               (agent-cl.dsl:register-declaration db)
               (is-equal 2 (length (agent-cl.dsl:all-principles)))
               (is-equal 100 (agent-cl.dsl:principle-priority (intern "RULE" pa)))
               (is-equal 10 (agent-cl.dsl:principle-priority (intern "RULE" pb))))
             ;; reset API
             (is-equal 2 (agent-cl.dsl:clear-declarations))
             (is-equal nil (agent-cl.dsl:all-principles)))
        (delete-package pa)
        (delete-package pb)))))

;;; ---------------------------------------------------------------------------
;;; goals
;;; ---------------------------------------------------------------------------

(deftest dsl-defgoal-strips-the-empty-lambda-list
  "The documented (defgoal name () ...) form was NOT stripped: CONSP is false for
  (), so the empty list was parsed as a clause and injected (NIL NIL) into the
  spec."
  (with-fresh-dsl-state
    (eval '(agent-cl.dsl:defgoal harden-goal () (:intent "x") (:subgoals a b)))
    (is-equal "x" (agent-cl.dsl:goal-intent 'harden-goal))
    (is-equal '(a b) (agent-cl.dsl:goal-subgoals 'harden-goal))
    (is-equal nil (getf (agent-cl.dsl:goal-spec 'harden-goal) nil)
              "no NIL key may leak into the spec")
    ;; the same form without the () is unchanged
    (eval '(agent-cl.dsl:defgoal harden-goal-2 (:intent "y") (:subgoals c)))
    (is-equal "y" (agent-cl.dsl:goal-intent 'harden-goal-2))))

(deftest dsl-predicate-errors-are-recorded
  "EVAL-LOCAL-PREDICATE swallowed every error, so a typo'd :done-when looked
  exactly like 'not satisfied yet' and the goal silently never completed."
  (agent-cl.dsl:clear-goal-predicate-error)
  (is-equal nil (agent-cl.dsl:eval-local-predicate '(no-such-function-xyz)))
  (ok (agent-cl.dsl:last-goal-predicate-error)
      "the failure must be retrievable for diagnosis")
  (ok (search "NO-SUCH-FUNCTION-XYZ" (agent-cl.dsl:last-goal-predicate-error)))
  (agent-cl.dsl:clear-goal-predicate-error)
  (is-equal nil (agent-cl.dsl:last-goal-predicate-error))
  (is-equal t (agent-cl.dsl:eval-local-predicate '(zerop 0))))

(deftest dsl-run-goal-reports-a-blocked-subgoal
  "RUN-GOAL ignored the engine's guard reason: a subgoal blocked by a guard (or a
  failed model call) was reported as ordinary progress and the walk continued."
  (with-fresh-dsl-state
    (eval '(agent-cl.dsl:defgoal blocked-goal ()
             (:subgoals one two)
             (:done-when (zerop 1))))
    ;; a guard trips on the very first step, so subgoal ONE never completes
    (agent-cl.loop:register-guard "always" (lambda (a) (declare (ignore a)) "blocked!"))
    (let* ((agent (make-agent :transport (make-mock-transport) :tools nil
                              :policy (make-policy :max-steps 3)))
           (result (agent-cl.dsl:run-goal 'blocked-goal agent)))
      (is-equal 'one (getf result :blocked-at))
      (is-equal "blocked!" (getf result :guard-reason))
      (is-equal 1 (getf result :subgoals-run)
                "a blocked subgoal must stop the walk, not fall through")
      (is-equal nil (getf result :completed-p)))))

;;; ---------------------------------------------------------------------------
;;; end-to-end: a preventive audit stops a REAL write inside one engine step
;;; ---------------------------------------------------------------------------

(defvar *audit-flag* nil
  "Stand-in for observed world state that an audit rule reads.")

(deftest defaudit-blocks-a-real-write-in-the-same-step
  "The global guard only runs at the TOP of a step. When one model reply asks for
  two tools — one that creates the violating condition and one that acts on it —
  a global-only audit lets the write happen and only complains on the next step.
  The pre-execution rule must refuse the write itself."
  (with-fresh-dsl-state
    (setf *audit-flag* nil)
    (let ((target ".tools/tmp-audit-blocked.txt"))
      (ignore-errors (delete-file target))
      (register-tool
       (make-tool "harden.sentinel"
                  (lambda (a c) (declare (ignore a c))
                    (setf *audit-flag* t) (values "sentinel set" :ok))
                  :description "flips the observed condition"))
      (register-tool
       (make-tool "harden.write"
                  (lambda (a c) (declare (ignore a c))
                    (write-file-string target "PWNED") (values "wrote" :ok))
                  :description "writes a file"))
      (unwind-protect
           (progn
             (eval '(agent-cl.dsl:defaudit same-step-audit
                      (:applies-to harden.write)
                      (:check (when *audit-flag* "same-step-audit tripped"))
                      (:on-violation :block)))
             (let* ((tr (make-mock-transport
                         :script (list
                                  (script-reply
                                   (reply-json "" (list (tc-json "c1" "harden.sentinel" "{}")
                                                        (tc-json "c2" "harden.write" "{}"))))
                                  (script-reply (reply-json "done" nil)))))
                    (agent (make-agent :transport tr :tools '("harden.sentinel" "harden.write")
                                       :policy (make-policy :max-steps 3)))
                    (summary (run agent "先设置标志再写文件")))
               (ok *audit-flag* "the sentinel ran first")
               (is-equal nil (probe-file target)
                         "the audited write must NOT have happened")
               (ok (not (done-p summary)) "the rule also stops the turn")
               (ok (search "same-step-audit" (or (guard-reason summary) "")))
               ;; and the refusal is visible in the transcript the model sees
               (let ((tool-texts (loop for m in (agent-messages agent)
                                       when (eq (agent-cl.messages:msg-role m) :tool)
                                         collect (or (agent-cl.messages:msg-content m) ""))))
                 (ok (some (lambda (s) (search "same-step-audit" s)) tool-texts)
                     "the tool result must report the refusal"))))
        (unregister-tool "harden.sentinel")
        (unregister-tool "harden.write")
        (ignore-errors (delete-file target))))))

;;; ---------------------------------------------------------------------------
;;; introspect + sandbox
;;; ---------------------------------------------------------------------------

(deftest dsl-introspect-single-signal
  "(:based-on (form)) unwrapped to the bare SYMBOL form, so LENGTH was called on
  a symbol and INTROSPECT-CONFIDENCE errored for any one-signal declaration."
  (with-fresh-dsl-state
    (eval '(agent-cl.dsl:defintrospect one-signal ()
             (:based-on ((zerop 0)))
             (:threshold 0.5)))
    (is-equal '((zerop 0)) (agent-cl.dsl:introspect-signals 'one-signal))
    (is-equal 1.0 (agent-cl.dsl:introspect-confidence 'one-signal))
    ;; the explicit wrapped-list form still means 'two signals'
    (eval '(agent-cl.dsl:defintrospect two-signals ()
             (:based-on ((zerop 0) (plusp 1)))))
    (is-equal '((zerop 0) (plusp 1)) (agent-cl.dsl:introspect-signals 'two-signals))
    (is-equal 1.0 (agent-cl.dsl:introspect-confidence 'two-signals))))

(deftest dsl-sandbox-caps-compute
  "Step counting does not bound a single form: (make-string 100000000) is one
  step and 100MB."
  (agent-cl.dsl:with-dsl-sandbox (:mode :interpreter)
    (is-equal "3" (agent-cl.dsl:dsl-eval-safe '(+ 1 2)))
    (signals-error agent-cl.core:dsl-error
      (agent-cl.dsl:dsl-eval-safe '(make-string 100000000)))
    (signals-error agent-cl.core:dsl-error
      (agent-cl.dsl:dsl-eval-safe '(append (make-string 90000) (make-string 90000))))
    ;; a legitimately large-but-bounded string still works
    (ok (agent-cl.dsl:dsl-eval-safe '(length (make-string 5000))))))

(deftest dsl-sandbox-resets-steps-per-call
  "LET (parallel) computed RESULT while *DSL-STEPS* still held the caller's value,
  so the step counter was never reset: the limit leaked across calls."
  (agent-cl.dsl:with-dsl-sandbox (:mode :interpreter :max-steps 3)
    (dotimes (i 4)
      (is-equal "1" (agent-cl.dsl:dsl-eval-safe '(+ 0 1))
                "each call gets its own step budget"))))

(deftest dsl-sandbox-still-denies
  "The caps must not have loosened the whitelist gate."
  (agent-cl.dsl:with-dsl-sandbox (:mode :interpreter)
    (signals-error agent-cl.core:dsl-error
      (agent-cl.dsl:dsl-eval-safe '(open "x")))
    (signals-error agent-cl.core:dsl-error
      (agent-cl.dsl:dsl-eval-safe '(eval '(+ 1 2))))
    (signals-error agent-cl.core:dsl-error
      (agent-cl.dsl:dsl-eval-safe '(symbol-value 'x)))))
