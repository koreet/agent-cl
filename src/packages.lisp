;;;; src/packages.lisp — package definitions for Agent-CL.
;;;;
;;;; Convention: every package :uses only CL. Cross-package access is always
;;;; package-qualified (agent-cl.llm:complete-turn). This removes the entire
;;;; class of import/use bookkeeping bugs and makes each file's dependencies
;;;; explicit. Symbols referenced from other packages must be exported here.

(defpackage #:agent-cl.core
  (:use #:cl)
  (:export
   ;; --- json (wrapper over yason) ---
   #:json-encode            ; object -> JSON string
   #:json-decode            ; JSON string -> decoded structure
   #:encode-plist-object    ; plist -> JSON object string
   #:object-to-plist        ; decoded JSON object -> plist (keyword keys, recursive)
   #:decode-to-plist        ; JSON string -> plist
   ;; --- logging ---
   #:*log-level*
   #:*log-output*
   #:log-trace #:log-debug #:log-info #:log-warn #:log-error
   ;; --- conditions ---
   #:agent-error
   #:agent-error-message
   #:transport-error        #:transport-error-status #:transport-error-retryable-p
   #:tool-error             #:tool-error-tool #:tool-error-code
   #:dsl-error              #:dsl-error-kind
   #:schema-error           #:schema-error-path #:schema-error-expected #:schema-error-actual
   #:guard-triggered        #:guard-triggered-rule #:guard-triggered-limit
   #:agent-pause            #:agent-pause-reason
   ;; --- util ---
   #:uuid-string
   #:now-iso8601
   #:approx-tokens
   #:utf8-byte-length
   #:ensure-list
   #:plist-get
   #:string-empty-p
   #:alist->plist
   #:read-file-string
   #:write-file-string
   #:shell-command
   #:read-file-lenient
   #:run-program-with-timeout
   #:path-segments
   #:canonical-path-string
   #:path-inside-p
   #:format-token-count))

(defpackage #:agent-cl.messages
  (:use #:cl)
  (:export
   #:message              ; class + constructor
   #:make-message
   #:msg-role #:msg-content #:msg-tool-calls #:msg-tool-call-id #:msg-name
   #:tool-call            ; struct
   #:make-tool-call
   #:tool-call-id #:tool-call-name #:tool-call-arguments #:tool-call-arguments-plist
   #:messagep
   #:role-system #:role-user #:role-assistant #:role-tool
   #:system-message #:user-message #:assistant-message #:tool-result-message))

(defpackage #:agent-cl.llm
  (:use #:cl)
  (:export
   ;; --- configuration ---
   #:*default-model* #:*default-base-url* #:*request-timeout-seconds* #:*max-retries*
   #:*http-fetch-hook*
   ;; --- endpoint/transport protocol ---
   #:transport #:transport-name
   #:make-http-transport #:make-mock-transport
   #:perform-request
   #:mock-script #:mock-push #:mock-reset #:script-reply #:script-stream
   #:script-error
   ;; --- chat result ---
   #:turn-result
   #:result-content #:result-tool-calls #:result-finish-reason #:result-usage
   #:result-truncated-p
   #:complete-turn
   ;; --- streaming ---
   #:streaming-turn
   #:stream-feed #:stream-advance #:stream-drain #:stream-text
   #:stream-finished-p #:stream-finalize #:stream-usage #:stream-finish
   #:stream-done-seen
   ;; --- wire codec ---
   #:encode-request-json #:encode-message-wire #:parse-chat-json
   #:usage-prompt-tokens #:usage-completion-tokens #:usage-total-tokens
   #:usage-cache-hit-tokens #:usage-cache-miss-tokens
   #:parse-models-response))

(defpackage #:agent-cl.schema
  (:use #:cl)
  (:export
   #:schema                   ; class
   #:make-schema
   #:schema-name #:schema-kind #:schema-properties #:schema-required #:schema-items
   #:schema-description
   #:schema->json             ; Lisp schema -> LLM-facing JSON Schema object (plist)
   #:schema->json-string
   #:schema-property
   #:validate-json            ; validate decoded JSON against schema; returns problems
   #:json-valid-p
   #:coerce-schema-types))

(defpackage #:agent-cl.tools
  (:use #:cl)
  (:export
   #:tool
   #:make-tool #:tool-name #:tool-description #:tool-parameters #:tool-fn #:tool-dangerous-p
   #:tool-schema              ; tool -> {type function ...} plist for the wire
   #:register-tool #:unregister-tool #:find-tool #:list-tools #:call-tool
   #:*tool-registry*
   #:with-tools
   ;; file workspace confinement
   #:*file-workspace-root* #:set-file-workspace-root #:workspace-check
   ;; builtin tools
   #:register-builtin-tools
   #:shell-tool #:file-tool #:time-tool))

(defpackage #:agent-cl.loop
  (:use #:cl)
  (:export
   #:agent
   #:make-agent
   #:agent-transport #:agent-model #:agent-tools #:agent-policy #:agent-messages #:agent-system
   #:agent-memory #:agent-max-steps #:agent-guard #:agent-usage-total #:agent-max-history #:agent-context-budget #:agent-compactor
   #:agent-usage-prompt #:agent-usage-completion
    #:agent-cache-hit #:agent-cache-miss #:agent-cache-seen
    #:agent-depth
   #:policy
   #:make-policy #:policy-max-steps #:policy-temperature #:policy-max-tool-results
   #:policy-parallel-tools #:policy-allow-model-retry #:policy-max-tokens
   #:run #:ask #:stop
   #:add-usage
   #:guard-failed
   #:register-guard #:check-extra-guards #:*extra-guards*
   #:unregister-guard #:clear-guards #:guard-rule-names
   ;; pre-execution tool guards (preventive audit rules)
   #:*tool-guards* #:register-tool-guard #:unregister-tool-guard
   #:clear-tool-guards #:tool-guard-decision #:tool-guard-rules-for
   ;; CLOS extension hooks
   #:on-step-start #:on-tool-result #:on-turn-done #:before-llm-call #:choose-messages
   ;; results
   #:turn-summary #:done-p #:final-content #:steps #:guard-reason
   #:stop-reason #:truncated-p
    #:turn-summary-tool-count
   ;; memory
   #:memory #:memory-add #:memory-window #:memory-compact))

(defpackage #:agent-cl.dsl
  (:use #:cl)
  (:export
   ;; domain-DSL tool macros (L2)
   #:defdsl-tool #:defcommand #:defdsl-package #:defschema
   ;; agent instruction DSL (L1)
   #:defagent #:defpolicy #:defguard
   #:find-policy #:register-policy #:list-policy-names #:clear-policies
   ;; schema generation bridge
   #:schema->json-schema #:dsl-tool-schema #:find-schema #:parse-schema-decl
   ;; safe evaluation (D2: disabled by default)
   #:*dsl-execution-mode* #:*dsl-command-whitelist* #:*dsl-max-steps* #:*dsl-max-result-chars*
   #:*dsl-max-integer* #:*dsl-max-sequence*
   #:dsl-eval-safe
   #:with-dsl-sandbox
   ;; declaration metadata + reflection (dsl-contract-plan §B1)
   #:dsl-declaration
   #:decl-name #:decl-kind #:decl-spec #:decl-refs #:decl-source #:decl-version
   #:make-declaration #:register-declaration #:find-declaration
   #:unregister-declaration #:all-declarations #:describe-declaration
   #:clear-declarations #:declaration-spec #:declaration-refs
   ;; executable goal contract (dsl-contract-plan §B2)
   #:defgoal
   #:goal-spec #:goal-intent #:goal-subgoals #:goal-budget
   #:goal-preconditions #:goal-done-when-form #:goal-retry-limit
   #:goal-done-p #:goal-preconditions-met-p
   #:eval-local-predicate
   #:last-goal-predicate-error #:clear-goal-predicate-error
   #:run-goal #:subgoal-task-text #:goal-completed-p   ; goal-driven execution
   ;; executable audit rules (dsl-contract-plan milestone i)
   #:defaudit
   #:audit-applies-to #:audit-on-violation #:audit-evidence #:describe-audit
   #:audit-spec #:audit-intent #:audit-preventive-p
   ;; principles + constitution (dsl-contract-plan milestone ii)
   #:defprinciple
   #:principle-priority #:principle-statement #:principle-constrains
   #:principle-resolves-conflict-form #:all-principles
   #:max-principle-priority #:constitution-p #:change-principle-priority
   #:principle-constitutional-p #:note-principle-registered
   #:resolve-principles #:describe-principle
   ;; dependency graph (reuse decl-refs)
   #:decl-references #:decl-referenced-by #:decl-dependents #:impact-of
   #:decl-internal-refs #:decl-external-refs #:dangling-refs
   #:declared-name-p #:decl-any #:describe-impact
   ;; persistent identity (defidentity)
   #:defidentity
   #:identity-spec #:identity-traits #:identity-anchor #:identity-memory-policy
   #:identity-trait #:identity-trait>= #:describe-identity
   ;; narrative memory (defmemory)
   #:defmemory
   #:memory-spec #:memory-content #:memory-salience #:memory-linked-to
   #:memory-recall-when-form #:*default-decay-rate* #:decay-salience
   #:memory-applicable-p #:recall-memories #:describe-memory
   ;; metacognition (defintrospect)
   #:defintrospect
   #:introspect-spec #:introspect-signals #:introspect-threshold
   #:introspect-on-low #:introspect-failure-patterns
   #:introspect-confidence #:introspect-confident-p #:introspect-failure-kind
   #:describe-introspect))

(defpackage #:agent-cl.session
  (:use #:cl)
  (:export
   #:session #:make-session #:session-id #:session-path
   #:session-append #:session-replay #:open-session #:save-checkpoint
   #:persist-message #:replayed-messages #:message->event #:event->message
   #:session-ids #:load-session #:session-first-user-text
   #:session-message-count #:session-empty-p #:session-last-ts
   #:resolve-session-choice
   #:conversation-entries #:last-conversation-turns))

(defpackage #:agent-cl
  (:use #:cl)
  (:import-from #:agent-cl.dsl #:defagent #:defpolicy #:defguard #:defdsl-tool
                #:defcommand #:defdsl-package #:defschema #:defgoal #:defaudit #:defprinciple #:defidentity #:defmemory #:defintrospect)
  (:import-from #:agent-cl.loop #:make-agent #:run #:ask #:stop #:agent)
  (:export #:defagent #:defpolicy #:defguard #:defdsl-tool #:defcommand
           #:defdsl-package #:defschema #:defgoal #:defaudit #:defprinciple #:defidentity
           #:defmemory #:defintrospect
           #:make-agent #:run #:ask #:stop #:agent
           #:*default-model* #:*default-base-url*))

(defpackage #:agent-cl.selfimprove
  (:use #:cl)
  (:export
   ;; safe, gate-guarded single-file self-improvement (repo docs/architecture)
   #:improve-file
   #:state-plist
   #:make-git-style-backup-dir
   ;; optional production gate: run the real repo test suite in a subprocess
   #:real-gate-runner))

(defpackage #:agent-cl.render
  (:use #:cl)
  (:export
   ;; pure, IO-free markdown -> logical-line classifier (fenced-code aware)
   #:md-line                            ; struct type + accessors
   #:make-md-line #:md-line-kind #:md-line-text
   #:fence-open-p #:fence-close-p
   ;; deterministic state-classification (pure)
   #:classify-block #:classify-lines #:classify-one
   #:+fence-out+ #:+fence-in+
   ;; pure heading + inline-span core (ANSI codes passed in as a theme plist)
   #:classify-heading #:render-inline* #:osc8-wrap #:*osc8-links*
   #:classify-list-item
   ;; table alignment (pure)
   #:string-display-width #:wide-char-p #:pad-to-width
   #:parse-table-row #:separator-row-p #:format-table-block
   ;; heading decoration (pure): underline + SGR selection
   #:*heading-rule-width* #:heading-rule #:heading-ansi #:heading-rule-color
   ;; agent activity nesting (pure): indent + marked line for sub-agents
   #:*agent-indent-step* #:agent-indent #:agent-activity-line
   ;; pinned bottom footer: escape sequences + geometry (pure)
   #:csi #:set-scroll-region #:reset-scroll-region #:cursor-to #:erase-line
   #:save-cursor #:restore-cursor
   #:strip-ansi #:fit-to-width #:pad-ansi-line
   #:*footer-height* #:footer-layout
   ;; console capability probe (impure, fails soft: NIL = do not pin)
   #:probe-console #:console-vt-enabled-p #:console-enable-vt))

