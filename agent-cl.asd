;;;; agent-cl.asd — system definition for Agent-CL.
;;;;
;;;; Environment note: this sandbox has no admin rights, no working winget and
;;;; no in-Lisp TLS, so Quicklisp dist downloads are unavailable. Dependencies
;;;; are vendored under <repo>/.tools/deps and registered via ASDF's source
;;;; registry in scripts/env.lisp (a (:tree ...) over .tools/deps). On a normal
;;;; machine the same systems load fine through Quicklisp.
;;;;
;;;; Dependency policy (see docs/architecture.md §3): only libs that are
;;;; strictly needed are declared. Logging/CLI/time/uuid are intentionally
;;;; self-implemented in src/core to keep the offline closure small.

(defsystem "agent-cl"
  :description "A modern agent in Common Lisp: OpenAI-compatible tool-calling loop, builtin tools, streaming, structured output and Lisp-macro DSL customization."
  :version "0.1.0"
  :author "agent-cl contributors"
  :license "MIT"
  :depends-on ("alexandria" "yason" "split-sequence" "bordeaux-threads")
  :serial t
  :pathname "src/"
  :components
  ((:file "packages")
   ;; ---- core (no cross-package deps) ----
   (:file "core/util")
   (:file "core/error")
   (:file "core/log")
   (:file "core/json")
   ;; ---- messages ----
   (:file "messages")
   ;; ---- llm / transport ----
   (:file "llm/codec")
   (:file "llm/sse")
   (:file "llm/transport")
   ;; ---- schema ----
   (:file "schema/json-schema")
   ;; ---- tools ----
   (:file "tools/registry")
   ;; ---- web ----
   (:file "web/search")
   (:file "tools/builtin")
   ;; ---- loop engine ----
   (:file "loop/engine")
   ;; ---- dsl layer ----
   (:file "dsl/sandbox")
   (:file "dsl/schema-gen")
   (:file "dsl/macros")
   ;; ---- session ----
   (:file "session/store")))

(defsystem "agent-cl/tests"
  :description "Self-contained test suite for Agent-CL (no external test framework; see docs/architecture.md adaptation note)."
  :version "0.1.0"
  :depends-on ("agent-cl")
  :serial t
  :pathname "tests/"
  :components
  ((:file "harness")
   (:file "core-tests")
   (:file "codec-tests")
   (:file "sse-tests")
   (:file "engine-tests")
   (:file "dsl-tests")
   (:file "session-tests")))
