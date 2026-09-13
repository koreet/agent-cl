;;;; src/dsl/macros.lisp — the DSL layer (docs/architecture.md §6).
;;;;
;;;; L1 agent-instruction DSL:   defagent / defpolicy / defguard / defschema
;;;; L2 domain-tool DSL:         defdsl-tool / defcommand / defdsl-package
;;;;
;;;; These macros are the *user surface*: they expand into ordinary calls of
;;;; the tools/registry and loop/engine APIs, so every capability is usable
;;;; without the DSL too. Declarations are the single source for the schema,
;;;; the wire description and the validator (§6.6).
(in-package #:agent-cl.dsl)

(defun tool-name-string (name)
  (if (stringp name) name (string-downcase (symbol-name name))))

(defun strip-optional-lambda-list (clauses)
  "Drop the conventional empty lambda-list placeholder from CLAUSES.

  Several DSL macros take the shape (defX name () clauses...). The () is
  decorative, and treating whatever sits in that position as a lambda list meant a
  MISSING () silently ate the FIRST CLAUSE:

      (defprinciple p (:priority 100) (:statement \"x\"))
      => priority NIL, i.e. the principle quietly stopped being constitutional
      (defintrospect i (:based-on ((f))) ...)  => no signals at all

  A clause is recognizable by its keyword head, so dispatch on that instead of
  assuming: () -> drop, a clause -> keep, a real lambda list -> drop (and it is
  still ignored, as documented)."
  (let ((first (first clauses)))
    (cond ((null first) (rest clauses))                            ; ()
          ((and (consp first) (keywordp (first first))) clauses)   ; a clause
          ((consp first) (rest clauses))                           ; a lambda list
          (t clauses))))

;;; ---------------------------------------------------------------------------
;;; L2: domain tool DSL
;;; ---------------------------------------------------------------------------

(defmacro defdsl-tool (name doc params &body body)
  "Define a tool the model may call.
    (defdsl-tool \"calc.add\" \"Add two numbers\"
        ((a :number :description \"first\" :required t)
         (b :number :description \"second\" :required t))
      (format nil \"~a\" (+ (getf args :A) (getf args :B))))
  BODY runs with ARGS (keyword-keyed plist of the JSON arguments the model
  sent) and CTX bound. Return (values payload :ok) or (values \"msg\" :error)."
  (let ((tool-name (tool-name-string name)))
    (let ((args-sym (intern "ARGS" *package*))
          (ctx-sym (intern "CTX" *package*)))
      `(agent-cl.tools:register-tool
        (agent-cl.tools:make-tool
         ,tool-name
         (lambda (,args-sym ,ctx-sym) ,@body)
         :description ,doc
         :parameters (dsl-params->schema ',params))))))

(defmacro defcommand (name doc params &body body)
  "Alias of DEFDSL-TOOL for command-style DSLs."
  `(defdsl-tool ,name ,doc ,params ,@body))

(defmacro defdsl-package (name &body body)
  "Documentation/grouping form: runs BODY (usually many DEFDSL-TOOL forms).
  In a real namespaced deployment this could generate a package; for now the
  '.' prefix in tool names plays that role."
  (declare (ignore name))
  `(progn ,@body))

;;; ---------------------------------------------------------------------------
;;; structured output schema DSL
;;; ---------------------------------------------------------------------------

(defmacro defschema (name decl)
  "Register a named schema declaration.
    (defschema invoice (:object (amount :number :required t)
                               (memo  :string)))"
  `(register-schema ',name (parse-schema-decl ',decl)))

;;; ---------------------------------------------------------------------------
;;; L1: agent instruction DSL
;;; ---------------------------------------------------------------------------

(defvar *policies* (make-hash-table :test 'equal)
  "name-string -> policy instance, filled by DEFPOLICY.

  DEFPOLICY used to define only a VARIABLE, so a policy was reachable solely by
  symbol in the defining package: (:policy chatty) in another file/package could
  not resolve it, and there was no way to enumerate or look up a policy by name.")

(defun policy-key (name)
  "Normalized registry key for a policy designator: names are case-insensitive,
  so 'CHATTY, \"chatty\" and chatty all denote the same policy."
  (string-downcase (tool-name-string name)))

(defun register-policy (name policy)
  (setf (gethash (policy-key name) *policies*) policy)
  policy)

(defun find-policy (name)
  "Policy registered under NAME (symbol, string or keyword), or NIL."
  (gethash (policy-key name) *policies*))

(defun list-policy-names ()
  (sort (loop for k being the hash-keys of *policies* collect k) #'string<))

(defun clear-policies ()
  (clrhash *policies*))

(defmacro defpolicy (name options)
  "Define a named policy for reuse across agents.
    (defpolicy chatty (:max-steps 30 :temperature 0.7 :parallel-tools t))
  The policy object is bound to NAME *and* registered by name, so
  (:policy chatty) resolves from any package."
  `(progn
     (defparameter ,name (agent-cl.loop:make-policy ,@options))
     (register-policy ,(policy-key name) ,name)
     ',name))

(defmacro defguard (name (agent-var) &body body)
  "Define and register an extra guard rule. BODY receives the agent and
  returns a reason string (guard trips) or NIL (passes).
    (defguard few-steps (a) (when (> (agent-steps-count a) 5) \"too many\"))"
  `(progn
     (defun ,name (,agent-var) ,@body)
     (agent-cl.loop:register-guard ,(tool-name-string name) #',name)
     ',name))

(defun resolve-policy-option (value)
  "Turn a :policy option value into a policy instance (or NIL).
  Accepts an instance, a name (symbol/string/keyword looked up in *POLICIES*), or
  a literal option plist."
  (cond
    ((null value) nil)
    ((typep value 'agent-cl.loop:policy) value)
    ((or (stringp value) (symbolp value))
     (or (find-policy value)
         (error "defagent: no policy named ~s (known: ~{~a~^, ~})"
                value (list-policy-names))))
    ((listp value) (apply #'agent-cl.loop:make-policy value))
    (t (error "defagent: cannot use ~s as :policy" value))))

(defun build-agent-from-options (options)
  "Runtime half of defagent. OPTIONS is the keyword plist the user wrote."
  (let* ((transport (getf options :transport))
         (base-url (getf options :base-url))
         (api-key (getf options :api-key))
         (tools (getf options :tools))
         (tools-given (loop for (k) on options by #'cddr thereis (eq k :tools)))
         (policy (getf options :policy))
         (model (getf options :model))
         (system (getf options :system))
         (messages (getf options :messages))
         (memory (getf options :memory))
         (guard (getf options :guard))
         (max-steps (getf options :max-steps)))
    (let ((tr (or transport
                  (and (or base-url api-key)
                       (agent-cl.llm:make-http-transport
                        :base-url base-url :api-key api-key))
                  (agent-cl.llm:make-http-transport))))
      (let ((normalized-tools
              (when tools-given
                (mapcar (lambda (t1)
                          (cond ((stringp t1) t1)
                                ((symbolp t1) (tool-name-string t1))
                                (t t1)))
                        tools))))
        (agent-cl.loop:make-agent
         :transport tr
         :model model
         ;; :tools NIL (or ()) means NO tools — it must not silently become
         ;; :all, which is what happened when an empty literal list was treated
         ;; as "no option given".
         :tools (if tools-given (or normalized-tools nil) :all)
         :policy (resolve-policy-option policy)
         :messages messages
         :memory memory
         :system system
         :guard guard
         :max-steps max-steps)))))

(defun call-form-p (form)
  "True when FORM looks like a function call: a cons whose head is a symbol that
  is FBOUNDP right now (LIST, APPEND, MAKE-POLICY, ...). Used to decide whether a
  DSL option value is data to quote or an expression to evaluate."
  (and (consp form)
       (or (eq (first form) 'quote)
           (and (symbolp (first form)) (fboundp (first form))))))

(defun literal-name-list-p (form)
  "True when FORM is a literal list of tool/policy names — data, not code.
  Requires a non-empty proper list of plain symbols/strings: the old test
  (LISTP + EVERY symbolp) accepted NIL and call-shaped lists such as
  (list \"a\" \"b\"), which were then QUOTED as literal data instead of being
  evaluated — a silent wrong tool set."
  (and (consp form)
       (null (cdr (last form)))          ; proper list
       (not (call-form-p form))
       (every (lambda (x) (and (or (symbolp x) (stringp x))
                               (not (keywordp x))))
              form)))

(defun quote-name-list (v)
  (if (literal-name-list-p v) (list 'quote v) v))

(defun expand-agent-options (options)
  "Walk an option plist, quoting option values that are literal name lists
  (:tools) or policy names (:policy) so they are passed as data. Used by
  DEFAGENT — previously this helper existed but DEFAGENT duplicated its logic
  inline, so a fix to one was silently missing from the other.

  NB: the plist is rebuilt with APPEND, not (LIST* ... (NREVERSE ...)): reversing
  a plist cons chain reverses ELEMENTS, not just pairs, which silently rotated
  every key onto the wrong value (:system got the system string as its KEY)."
  (let (out)
    (loop for (k v) on options by #'cddr
          do (setf out (append out
                               (list k
                                     (cond ((eq k :tools) (quote-name-list v))
                                           ;; a bare name (:policy chatty) must
                                           ;; survive evaluation in a package
                                           ;; where the policy variable is unbound
                                           ((eq k :policy)
                                            (if (and (or (symbolp v) (stringp v))
                                                     (not (eq v t))
                                                     (not (keywordp v)))
                                                (list 'quote v)
                                                v))
                                           (t v))))))
    out))

(defmacro defagent (name options)
  "Define a named agent from a keyword option list.
    (defagent my-bot
      (:model my-model :base-url my-base-url
       :system my-system-text
       :tools (shell.run file.read time.now)
       :policy chatty))
  Tool-name lists and :policy names are taken literally; any other value, or a
  call-shaped form such as (list \"a\" \"b\"), is evaluated when the definition
  loads."
  (let ((pairs (expand-agent-options options)))
    `(defparameter ,name (build-agent-from-options (list ,@pairs)))))
