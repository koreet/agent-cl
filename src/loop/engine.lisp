;;;; src/loop/engine.lisp — ReAct engine (docs/architecture.md §5.4).
;;;;
;;;; The engine is deliberately small: step -> LLM round trip -> if tool calls
;;;; arrived, validate+dispatch them -> feed observations back -> repeat until
;;;; the model answers with text or a guard fires. Every extension point the
;;;; DSL layer (M3) and users need is a CLOS generic function with a default
;;;; no-op method, so behavior is customized by subclassing AGENT, never by
;;;; editing the loop (docs/architecture.md §6.4).
(in-package #:agent-cl.loop)

;;; ---------------------------------------------------------------------------
;;; memory (M5 fleshes compaction out; here it is an ordered transcript store)
;;; ---------------------------------------------------------------------------

(defclass memory ()
  ((entries :initarg :entries :initform nil :accessor memory-entries)))

(defun memory-add (memory msg)
  (setf (memory-entries memory)
        (append (memory-entries memory) (list msg)))
  msg)

(defun memory-window (memory &optional (n nil))
  "Last N entries (nil = all)."
  (let ((all (memory-entries memory)))
    (if n (last all n) all)))

(defun memory-compact (memory)
  "Compaction hook — M5. Returns nil by default."
  (declare (ignore memory))
  nil)

;;; ---------------------------------------------------------------------------
;;; policy
;;; ---------------------------------------------------------------------------

(defclass policy ()
  ;; max-steps defaults to NIL = unlimited (the agent runs until it answers,
  ;; a guard fires, or the user stops it). Callers who want a hard cap pass an
  ;; explicit :max-steps (defpolicy / defagent / delegate child budgets).
  ((max-steps        :initarg :max-steps :initform nil :accessor policy-max-steps)
   (temperature      :initarg :temperature :initform nil :accessor policy-temperature)
   (max-tool-results :initarg :max-tool-results :initform 4000
                     :accessor policy-max-tool-results)
   (parallel-tools   :initarg :parallel-tools :initform t :accessor policy-parallel-tools)
   (allow-model-retry :initarg :allow-model-retry :initform t
                      :accessor policy-allow-model-retry)
   (max-tokens       :initarg :max-tokens :initform nil :accessor policy-max-tokens)))

(defun make-policy (&key max-steps temperature max-tool-results
                         (parallel-tools nil parallel-tools-p)
                         (allow-model-retry nil allow-model-retry-p)
                         max-tokens)
  ;; NB: two-step defaults. Booleans default to T; a *supplied* NIL is honored
  ;; (callers pass :parallel-tools nil to disable), whereas an unsupplied
  ;; keyword (also NIL) means "use the default T". max-steps nil = unlimited.
  (make-instance 'policy
                 :max-steps max-steps
                 :temperature temperature
                 :max-tool-results (or max-tool-results 4000)
                 :parallel-tools (if parallel-tools-p parallel-tools t)
                 :allow-model-retry (if allow-model-retry-p allow-model-retry t)
                 :max-tokens max-tokens))

;;; ---------------------------------------------------------------------------
;;; agent
;;; ---------------------------------------------------------------------------

(defclass agent ()
  ((transport  :initarg :transport :accessor agent-transport)
   (model      :initarg :model :initform agent-cl.llm:*default-model*
               :accessor agent-model)
   (tools      :initarg :tools :initform :all :accessor agent-tools)
   (policy     :initarg :policy :initform (make-policy) :accessor agent-policy)
   (messages   :initarg :messages :initform nil :accessor agent-messages)
   (memory     :initarg :memory :initform (make-instance 'memory) :accessor agent-memory)
   (system     :initarg :system :initform nil :accessor agent-system)
   (guard      :initarg :guard :initform nil :accessor agent-guard)
   (max-steps  :initarg :max-steps :initform nil :accessor agent-max-steps)
   ;; memory budget knobs (M5)
   (max-history     :initarg :max-history :initform nil :accessor agent-max-history)
   (context-budget  :initarg :context-budget :initform nil :accessor agent-context-budget)
   (compactor       :initarg :compactor :initform nil :accessor agent-compactor)
   (stopped    :initform nil :accessor agent-stopped-p)
   (usage-total :initform 0 :accessor agent-usage-total)
   ;; prompt/completion split so the UI can show "↑in ↓out =total"
   (usage-prompt     :initform 0 :accessor agent-usage-prompt)
   (usage-completion :initform 0 :accessor agent-usage-completion)
   ;; prompt-cache hit/miss (NIL until a provider reports cache fields)
   (cache-hit        :initform 0 :accessor agent-cache-hit)
   (cache-miss       :initform 0 :accessor agent-cache-miss)
   (cache-seen       :initform nil :accessor agent-cache-seen)
    ;; nesting: 0 = top-level agent; +1 for each task.delegate sub-agent, so a
    ;; display layer can indent/mark delegated activity distinctly from its parent.
    (depth            :initarg :depth :initform 0 :accessor agent-depth)))

(defun make-agent (&key transport model (tools :all) policy messages memory system guard
                       max-steps max-history context-budget compactor
                       (class 'agent) (depth 0))
  ;; CLASS lets a caller build a subclass (e.g. a display-aware REPL agent,
  ;; or a sub-agent that inherits its parent's class so the same hooks fire).
  (make-instance class
                 :depth depth
                 :transport transport
                 :model (or model agent-cl.llm:*default-model*)
                 :tools tools
                 :policy (or policy (make-policy))
                 :messages messages
                 :memory (or memory (make-instance 'memory))
                 :system system
                 :guard guard
                 :max-steps max-steps
                 :max-history max-history
                 :context-budget context-budget
                 :compactor compactor))

;;; ---------------------------------------------------------------------------
;;; turn summary
;;; ---------------------------------------------------------------------------

(defstruct (turn-summary (:constructor %make-turn-summary))
  done-p final-content steps guard-reason usage tool-count)

(defun make-turn-summary (&key done-p final-content steps guard-reason usage tool-count)
  (%make-turn-summary :done-p done-p :final-content final-content
                      :steps steps :guard-reason guard-reason
                      :usage usage :tool-count tool-count))

(defun done-p (s) (turn-summary-done-p s))
(defun final-content (s) (turn-summary-final-content s))
(defun steps (s) (turn-summary-steps s))
(defun guard-reason (s) (turn-summary-guard-reason s))

;;; ---------------------------------------------------------------------------
;;; extension hooks (defaults: no-ops)
;;; ---------------------------------------------------------------------------

(defgeneric on-step-start (agent step-ctx)
  (:documentation "Called once per engine step before the LLM request."))
(defgeneric before-llm-call (agent request-params)
  (:documentation "Called right before each LLM request with the params plist."))
(defgeneric on-tool-result (agent tool-name result-plist)
  (:documentation "Called after each tool execution with (:content .. :status ..)"))
(defgeneric on-turn-done (agent summary)
  (:documentation "Called when the agent finishes with a final answer."))
(defgeneric choose-messages (agent)
  (:documentation "Which messages to send this step. Default: system + transcript.
  Memory/compaction strategies override this."))

(defmethod on-step-start ((a agent) step-ctx) (declare (ignore a step-ctx)) nil)
(defmethod before-llm-call ((a agent) request-params)
  (declare (ignore a request-params)) nil)
(defmethod on-tool-result ((a agent) tool-name result-plist)
  (declare (ignore a tool-name result-plist)) nil)
(defmethod on-turn-done ((a agent) summary)
  (declare (ignore a summary)) nil)
(defun msgs-tokens (msgs)
  (loop for m in msgs
        sum (agent-cl.core:approx-tokens (agent-cl.messages:msg-content m))))

(defmethod choose-messages ((a agent))
  "Default context policy (M5): system + transcript, bounded by MAX-HISTORY
  (last N turns) and CONTEXT-BUDGET (approx tokens). Trimming is done on whole
  *turns* (a user message plus everything up to the next user message) so an
  assistant tool-call and its tool results are never split apart — splitting
  them would send the provider an illegal message sequence (400). Long
  conversations are windowed automatically; subclass/override for compaction
  strategies."
  (let* ((sys-text (agent-system a))
         (transcript (copy-list (agent-messages a)))
         (msgs (if sys-text
                   (cons (agent-cl.messages:system-message sys-text) transcript)
                   transcript)))
    (let ((max-hist (agent-max-history a)))
      (when (and max-hist (> (length transcript) max-hist))
        ;; Keep newest whole turns while their total stays <= MAX-HIST. If even
        ;; the newest turn alone exceeds MAX-HIST, keep that turn intact anyway
        ;; (a split tool-call pair is worse than exceeding the soft cap).
        (let ((turns (split-turns transcript))
              (kept nil) (total 0))
          (dolist (turn (reverse turns))
            (when (or (null kept)
                      (<= (+ total (length turn)) max-hist))
              (push turn kept)
              (incf total (length turn))))
          (setf transcript (apply #'append kept))
          (setf msgs (append (when sys-text (list (first msgs)))
                             transcript)))))
    (let ((budget (agent-context-budget a)))
      (when (and budget (> (msgs-tokens msgs) budget))
        ;; Drop oldest whole turns until within budget. Always keep system plus
        ;; at least one complete turn — never trim down to nothing, and never
        ;; split a tool-call/tool-result pair.
        (let ((turns (split-turns (cdr msgs))))
          (loop while (and (> (length turns) 1)
                           (> (msgs-tokens
                               (cons (first msgs) (apply #'append turns)))
                              budget))
                do (pop turns))
          (setf msgs (cons (first msgs) (apply #'append turns))))))
    msgs))

(defun split-turns (transcript)
  "Split a transcript (without system message) into whole turns. A turn starts
  at a :user message and runs until the next :user message (exclusive). Leading
  non-user messages (rare) form their own opening turn."
  (let ((turns nil) (cur nil))
    (dolist (m transcript)
      (cond ((and cur (eq (agent-cl.messages:msg-role m) :user))
             (push (nreverse cur) turns)
             (setf cur (list m)))
            (t (push m cur))))
    (when cur (push (nreverse cur) turns))
    (nreverse turns)))

;;; ---------------------------------------------------------------------------
;;; internals
;;; ---------------------------------------------------------------------------

(defun agent-available-tools (agent)
  (let ((names (agent-tools agent)))
    (if (eq names :all) (agent-cl.tools:list-tools) names)))

(defun build-request-params (agent &key stream)
  (let ((names (agent-available-tools agent))
        (params (list :model (agent-model agent)
                      :messages (choose-messages agent))))
    (when names
      (setf params (append params
                           (list :tools
                                 (loop for n in names
                                       for tool = (agent-cl.tools:find-tool n)
                                       when tool
                                         collect (agent-cl.tools:tool-schema tool))
                                 :tool-choice "auto"))))
    (when stream (setf params (append params (list :stream t))))
    (let ((temp (policy-temperature (agent-policy agent))))
      (when temp (setf params (append params (list :temperature temp)))))
    params))

(defun truncate-content (content limit)
  (if (and limit (> (length content) limit))
      (format nil "~a~%...[结果过长已截断，共 ~a 字符]" (subseq content 0 limit)
              (length content))
      content))

(defun add-usage (agent usage)
  "Accumulate USAGE onto the agent: total, plus the prompt/completion split.
  Missing components count as 0; total is derived from the provider when given."
  (when usage
    (let ((p (or (agent-cl.llm:usage-prompt-tokens usage) 0))
          (c (or (agent-cl.llm:usage-completion-tokens usage) 0))
          (h (agent-cl.llm:usage-cache-hit-tokens usage))
          (m (agent-cl.llm:usage-cache-miss-tokens usage)))
      (incf (agent-usage-prompt agent) p)
      (incf (agent-usage-completion agent) c)
      (incf (agent-usage-total agent)
            (or (agent-cl.llm:usage-total-tokens usage) (+ p c)))
      ;; cache accounting is only meaningful once a provider reports it
      (when (and h m)
        (setf (agent-cache-seen agent) t)
        (incf (agent-cache-hit agent) h)
        (incf (agent-cache-miss agent) m)))))

(defvar *extra-guards* nil
  "Alist (name . function) of user guard rules registered by defguard. Each
  function receives the agent and returns a reason string (trip) or NIL (pass).")

(defun register-guard (name fn)
  "Register (or REPLACE) an extra guard rule NAME -> FN.
  Re-registration must take effect: DEFGUARD redefines the Lisp function, and a
  stale entry kept by PUSHNEW would silently keep running the PREVIOUS
  definition — the guard would appear to accept a fix that never loaded."
  (let ((key (if (stringp name) name (string-downcase (string name))))
        (entry (assoc (if (stringp name) name (string-downcase (string name)))
                      *extra-guards* :test #'equal)))
    (if entry
        (setf (cdr entry) fn)
        (push (cons key fn) *extra-guards*))
    key))

(defun unregister-guard (name)
  "Drop the guard rule called NAME. Returns T when something was removed."
  (let* ((key (if (stringp name) name (string-downcase (string name))))
         (before (length *extra-guards*)))
    (setf *extra-guards* (remove key *extra-guards*
                                 :key #'car :test #'equal))
    (> before (length *extra-guards*))))

(defun clear-guards ()
  "Remove every registered extra guard rule."
  (setf *extra-guards* nil))

(defun guard-rule-names ()
  (mapcar #'car *extra-guards*))

(defun run-guard-rule (rule-fn agent label)
  "Call RULE-FN on AGENT, returning a reason string or NIL.
  A rule that RAISES is treated as a TRIP, not as a pass and not as a crash:
  a broken guard must fail closed, and an exception escaping here would abort
  the whole run through a path the caller cannot interpret."
  (handler-case
      (let ((reason (funcall rule-fn agent)))
        (when reason
          (if (stringp reason) reason (princ-to-string reason))))
    (error (e)
      (format nil "guard ~a 抛错（按阻断处理）: ~a" label e))))

(defun check-extra-guards (agent)
  "Run the agent's own :guard rules plus every registered extra guard rule;
  returns the first reason string or NIL."
  (let ((own (agent-guard agent)))
    (when own
      (let ((fns (cond ((functionp own) (list own))
                       ((and (symbolp own) (fboundp own)) (list own))
                       ((listp own) own)
                       (t nil))))
        (dolist (fn fns)
          (let ((reason (run-guard-rule fn agent "agent :guard")))
            (when reason (return-from check-extra-guards reason))))))
    (dolist (entry *extra-guards*)
      (let ((reason (run-guard-rule (cdr entry) agent (car entry))))
        (when reason (return reason))))))

;; ---------------------------------------------------------------------------
;; pre-execution tool guards (audit rules that must fire BEFORE a tool runs)
;; ---------------------------------------------------------------------------

(defvar *tool-guards* nil
  "Alist (TOOL-NAME . (FN . PLIST)) of rules consulted BEFORE a tool executes.
  TOOL-NAME is a registry name, or the wildcard \"any\"/\"*\" for every tool.
  This is the preventive half of the audit layer: a global guard is only
  consulted at the top of a step, i.e. after the offending tool has already
  run, which is too late to refuse a write.")

(defun tool-guard-wildcard-p (name)
  (member (string-downcase (string name)) '("any" "*" "all") :test #'string=))

(defun register-tool-guard (tool-name fn &key (on-violation :block) name)
  "Register FN as a pre-execution rule for TOOL-NAME. FN is called as
  (FN AGENT TOOL-NAME ARGS-PLIST) and returns a reason string or NIL.
  ON-VIOLATION is :block (refuse the call) or :warn/:report (run it, but
  annotate the result). Returns the normalized tool name."
  (let* ((key (if (tool-guard-wildcard-p tool-name)
                  "any"
                  (string-downcase (string tool-name))))
         (entry (assoc key *tool-guards* :test #'string=)))
    (if entry
        (setf (cdr entry) (list fn :on-violation on-violation :name name))
        (push (cons key (list fn :on-violation on-violation :name name))
              *tool-guards*))
    key))

(defun unregister-tool-guard (tool-name)
  (let* ((key (if (tool-guard-wildcard-p tool-name)
                  "any"
                  (string-downcase (string tool-name))))
         (before (length *tool-guards*)))
    (setf *tool-guards* (remove key *tool-guards* :key #'car :test #'string=))
    (> before (length *tool-guards*))))

(defun clear-tool-guards ()
  (setf *tool-guards* nil))

(defun tool-guard-rules-for (tool-name)
  "Every rule that applies to TOOL-NAME: exact matches first, then wildcards."
  (let ((key (string-downcase (string tool-name))))
    (append (remove-if-not (lambda (e) (string= (car e) key)) *tool-guards*)
            (remove-if-not (lambda (e) (string= (car e) "any")) *tool-guards*))))

(defun tool-guard-decision (agent tool-name args)
  "Consult the pre-execution rules for TOOL-NAME.
  Returns (values ACTION REASON RULE-NAME) where ACTION is :allow, :warn or
  :block. A rule that raises blocks (fail closed)."
  (let ((worst :allow) (worst-reason nil) (worst-name nil))
    (dolist (entry (tool-guard-rules-for tool-name))
      (let* ((fn (second entry))
             (opts (cddr entry))
             (rule-name (or (getf opts :name) (car entry)))
             (reason (handler-case (funcall fn agent tool-name args)
                       (error (e)
                         (format nil "规则抛错（按阻断处理）: ~a" e)))))
        (when reason
          (let* ((reason (if (stringp reason) reason (princ-to-string reason)))
                 (action (if (member (getf opts :on-violation) '(:warn :report))
                             :warn
                             :block)))
            ;; :block outranks :warn regardless of registration order
            (when (or (eq action :block) (eq worst :allow))
              (setf worst action worst-reason reason worst-name rule-name))))))
    (values worst worst-reason worst-name)))

(defun guard-violation-p (agent)
  "Return a guard reason string if any configured limit is hit, else NIL."
  (or (let ((mt (policy-max-tokens (agent-policy agent))))
        (when (and mt (> (agent-usage-total agent) mt))
          (format nil "max-tokens (~a)" mt)))
      (check-extra-guards agent)))

(defun dispatch-tool-call (agent tc policy)
  "Validate + execute one tool call; returns (values content status).
  AGENT is passed as the tool context so tools (task.delegate etc.) can spawn
  child agents that inherit the same transport/credentials.
  Pre-execution audit rules (*TOOL-GUARDS*) run BEFORE the tool: a blocking
  rule refuses the call outright, which is the only way an audit can prevent a
  write rather than report it afterwards."
  (let* ((name (agent-cl.messages:tool-call-name tc)))
    (handler-case
        (let ((args (agent-cl.messages:tool-call-arguments-plist tc)))
          (multiple-value-bind (action reason rule) (tool-guard-decision agent name args)
            (cond
              ((eq action :block)
               (values (format nil "[审计规则 ~a 拒绝执行 ~a] ~a" rule name reason)
                       :error))
              (t
               (multiple-value-bind (content status)
                   (agent-cl.tools:call-tool name args agent)
                 (let ((content (truncate-content content
                                                  (policy-max-tool-results policy))))
                   (values (if (eq action :warn)
                               (format nil "[审计规则 ~a 告警] ~a~%~a"
                                       rule reason content)
                               content)
                           status)))))))
      (error (e)
        ;; A malformed arguments JSON (truncated stream, model hallucination)
        ;; must not crash the whole run; surface it as a tool error result so
        ;; the transcript stays consistent and the model can retry.
        (values (format nil "[tool arguments 解析失败: ~a]" e) :error)))))

(defun drain-stream-turn (agent params on-token)
  "Run a streaming request and accumulate the turn, calling ON-TOKEN with text
  deltas as they arrive."
  (let ((turn (agent-cl.llm:perform-request (agent-transport agent) params)))
    (typecase turn
      (agent-cl.llm:turn-result turn)
      (t (let ((prev 0))
           (loop while (not (agent-cl.llm:stream-finished-p turn))
                 for status = (agent-cl.llm:stream-advance turn)
                 until (eq status :eof)
                 do (when on-token
                      (let ((text (agent-cl.llm:stream-text turn)))
                        (when (> (length text) prev)
                          (funcall on-token (subseq text prev))
                          (setf prev (length text))))))
           ;; EOF without [DONE] and without a finish_reason means the stream
           ;; was cut short (network drop / provider error): surface it instead
           ;; of silently returning truncated text or half-parsed tool args.
           (when (and (not (agent-cl.llm:stream-done-seen turn))
                      (null (agent-cl.llm:stream-finish turn)))
             (error 'agent-cl.core:transport-error
                    :message "stream ended before [DONE] (connection dropped?)"
                    :retryable t))
           (agent-cl.llm:stream-finalize turn))))))

;;; ---------------------------------------------------------------------------
;;; public API
;;; ---------------------------------------------------------------------------

(defun stop (agent)
  (setf (agent-stopped-p agent) t))

(defun run (agent task &key (max-steps nil) (stream nil) (on-token nil))
  "Drive AGENT on TASK until the model answers, a guard fires, or the step
  budget is exhausted (a NIL budget = no step limit; the agent runs until it
  answers or is stopped). Returns a turn-summary; the conversation transcript
  remains in (agent-messages agent)."
  (setf (agent-stopped-p agent) nil)
  (setf (agent-messages agent)
        (append (agent-messages agent)
                (list (agent-cl.messages:user-message task))))
  (let* ((policy (agent-policy agent))
         (budget (or max-steps (agent-max-steps agent) (policy-max-steps policy)))
         (step 0)
         (guard-reason nil)
         (final nil)
         (tool-count 0))
    (loop while (and (or (null budget) (< step budget))
                     (null final)
                     (not (agent-stopped-p agent)))
          do (incf step)
             (on-step-start agent (list :step step))
             (let ((gr (guard-violation-p agent)))
               (when gr (setf guard-reason gr) (return)))
             (let* ((params (build-request-params agent :stream stream))
                    (before (progn (before-llm-call agent params) nil))
                    (outcome (call-model agent params stream on-token)))
               (declare (ignore before))
               (cond
                 ((eq (first outcome) :error)
                  (setf guard-reason (second outcome))
                  (setf final (make-turn-summary :done-p nil
                                                 :guard-reason guard-reason
                                                 :steps step :tool-count tool-count)))
                 (t
                  (let ((result (second outcome)))
                    (add-usage agent (agent-cl.llm:result-usage result))
                    (if (agent-cl.llm:result-tool-calls result)
                        (let* ((tcs (agent-cl.llm:result-tool-calls result))
                               ;; In serial mode only the first call runs; record
                               ;; only what we actually execute so the transcript
                               ;; never holds a tool_call without its tool result
                               ;; (an illegal sequence for OpenAI/DeepSeek -> 400).
                               (to-run (if (policy-parallel-tools policy)
                                           tcs
                                           (subseq tcs 0 (min 1 (length tcs))))))
                          (setf (agent-messages agent)
                                (append (agent-messages agent)
                                        (list (agent-cl.messages:assistant-message
                                               (or (agent-cl.llm:result-content result) "")
                                               :tool-calls to-run))))
                          (incf tool-count (length to-run))
                          (dolist (tc to-run)
                            (multiple-value-bind (content status)
                                (dispatch-tool-call agent tc policy)
                              (on-tool-result agent
                                              (agent-cl.messages:tool-call-name tc)
                                              (list :content content :status status))
                              (setf (agent-messages agent)
                                    (append (agent-messages agent)
                                            (list (agent-cl.messages:tool-result-message
                                                   (agent-cl.messages:tool-call-id tc)
                                                   content)))))))
                        (let ((content (or (agent-cl.llm:result-content result) "")))
                          (setf (agent-messages agent)
                                (append (agent-messages agent)
                                        (list (agent-cl.messages:assistant-message content))))
                          (setf final (make-turn-summary
                                       :done-p t :final-content content
                                       :steps step :tool-count tool-count
                                       :usage (agent-cl.llm:result-usage result))))))))))
    (let ((summary
            (or final
                (make-turn-summary :done-p nil
                                   :guard-reason (or guard-reason
                                                      (if (agent-stopped-p agent)
                                                          :paused
                                                          :max-steps))
                                   :steps step :tool-count tool-count))))
      ;; Fire the completion hook on the finished turn. This is the only place a
      ;; caller learns the agent is done, so a display layer can print e.g. a
      ;; sub-agent's conclusion the moment that (child) agent finishes.
      (on-turn-done agent summary)
      summary)))
(defun call-model (agent params stream on-token)
  "One LLM round trip with automatic retry of transient transport failures
  (5xx/429, i.e. transport-error with RETRYABLE-P). Retry count is bounded by
  AGENT-CL.LLM:*MAX-RETRIES* and gated by the policy's ALLOW-MODEL-RETRY flag.
  Returns (:ok turn-result) or (:error readable-reason)."
  (let* ((policy (agent-policy agent))
         (budget (if (policy-allow-model-retry policy)
                     (or agent-cl.llm:*max-retries* 0)
                     0))
         (attempt 0))
    (loop
      (handler-case
          (return
            (list :ok
                  (if stream
                      (drain-stream-turn agent params on-token)
                      (agent-cl.llm:complete-turn (agent-transport agent) params))))
        (agent-cl.core:agent-pause (p)
          (return (list :error
                        (format nil "paused: ~a"
                                (agent-cl.core:agent-pause-reason p)))))
        (agent-cl.core:transport-error (e)
          (let ((msg (agent-cl.core:agent-error-message e)))
            (if (and (agent-cl.core:transport-error-retryable-p e)
                     (< attempt budget))
                (progn
                  (incf attempt)
                  (let ((backoff (min 8.0 (* 0.25 (expt 2 (1- attempt))))))
                    (format t "~&[retry ~a/~a after ~,1fs] ~a~%"
                            attempt budget backoff msg)
                    (finish-output)
                    (sleep backoff)))
                (return (list :error (or msg (princ-to-string e)))))))
        (agent-cl.core:agent-error (e)
          (return (list :error (agent-cl.core:agent-error-message e))))
        (error (e)
          (return (list :error (format nil "unexpected: ~a" e))))))))

(defun ask (agent text &key (stream nil) (on-token nil))
  "Single user utterance convenience wrapper around RUN."
  (run agent text :stream stream :on-token on-token))

(defun guard-failed (agent reason)
  "Report a guard trip — used by the DSL defguard layer (M3)."
  (declare (ignore agent))
  (make-turn-summary :done-p nil :guard-reason reason :steps 0 :tool-count 0))
