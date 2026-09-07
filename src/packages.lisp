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
   #:shell-command))

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
   ;; --- chat result ---
   #:turn-result
   #:result-content #:result-tool-calls #:result-finish-reason #:result-usage
   #:complete-turn
   ;; --- streaming ---
   #:streaming-turn
   #:stream-feed #:stream-advance #:stream-drain #:stream-text
   #:stream-finished-p #:stream-finalize #:stream-usage #:stream-finish
   #:stream-done-seen
   ;; --- wire codec ---
   #:encode-request-json #:encode-message-wire #:parse-chat-json
   #:usage-prompt-tokens #:usage-completion-tokens #:usage-total-tokens))

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
   #:policy
   #:make-policy #:policy-max-steps #:policy-temperature #:policy-max-tool-results
   #:policy-parallel-tools #:policy-allow-model-retry #:policy-max-tokens
   #:run #:ask #:stop
   #:guard-failed
   #:register-guard #:check-extra-guards #:*extra-guards*
   ;; CLOS extension hooks
   #:on-step-start #:on-tool-result #:on-turn-done #:before-llm-call #:choose-messages
   ;; results
   #:turn-summary #:done-p #:final-content #:steps #:guard-reason
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
   ;; schema generation bridge
   #:schema->json-schema #:dsl-tool-schema #:find-schema #:parse-schema-decl
   ;; safe evaluation (D2: disabled by default)
   #:*dsl-execution-mode* #:*dsl-command-whitelist* #:*dsl-max-steps* #:*dsl-max-result-chars*
   #:dsl-eval-safe
   #:with-dsl-sandbox))

(defpackage #:agent-cl.session
  (:use #:cl)
  (:export
   #:session #:make-session #:session-id #:session-path
   #:session-append #:session-replay #:open-session #:save-checkpoint
   #:persist-message #:replayed-messages #:message->event #:event->message))

(defpackage #:agent-cl
  (:use #:cl)
  (:import-from #:agent-cl.dsl #:defagent #:defpolicy #:defguard #:defdsl-tool
                #:defcommand #:defdsl-package #:defschema)
  (:import-from #:agent-cl.loop #:make-agent #:run #:ask #:stop #:agent)
  (:export #:defagent #:defpolicy #:defguard #:defdsl-tool #:defcommand
           #:defdsl-package #:defschema
           #:make-agent #:run #:ask #:stop #:agent
           #:*default-model* #:*default-base-url*))
