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
  ((max-steps        :initarg :max-steps :initform 20 :accessor policy-max-steps)
   (temperature      :initarg :temperature :initform nil :accessor policy-temperature)
   (max-tool-results :initarg :max-tool-results :initform 4000
                     :accessor policy-max-tool-results)
   (parallel-tools   :initarg :parallel-tools :initform t :accessor policy-parallel-tools)
   (allow-model-retry :initarg :allow-model-retry :initform t
                      :accessor policy-allow-model-retry)
   (max-tokens       :initarg :max-tokens :initform nil :accessor policy-max-tokens)))

(defun make-policy (&key max-steps temperature max-tool-results parallel-tools
                         allow-model-retry max-tokens)
  ;; NB: the &key defaults are NIL — never pass NIL straight into initargs or
  ;; the class initforms (20 / 4000 / T / T) get overridden.
  (make-instance 'policy
                 :max-steps (or max-steps 20)
                 :temperature temperature
                 :max-tool-results (or max-tool-results 4000)
                 :parallel-tools (if (null parallel-tools) t parallel-tools)
                 :allow-model-retry (if (null allow-model-retry) t allow-model-retry)
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
   (usage-total :initform 0 :accessor agent-usage-total)))

(defun make-agent (&key transport model (tools :all) policy messages memory system guard
                       max-steps max-history context-budget compactor)
  (make-instance 'agent
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
  (last N turns) and CONTEXT-BUDGET (approx tokens). Long conversations are
  windowed automatically; subclass/override for compaction strategies."
  (let* ((sys-text (agent-system a))
         (transcript (copy-list (agent-messages a)))
         (msgs (if sys-text
                   (cons (agent-cl.messages:system-message sys-text) transcript)
                   transcript)))
    (let ((max-hist (agent-max-history a)))
      (when (and max-hist (> (length transcript) max-hist))
        ;; keep system + the most recent max-hist messages
        (setf msgs (append (when sys-text (list (first msgs)))
                           (last transcript max-hist)))))
    (let ((budget (agent-context-budget a)))
      (when (and budget (> (msgs-tokens msgs) budget) (> (length msgs) 2))
        ;; drop oldest non-system messages until within budget
        (loop while (and (> (msgs-tokens msgs) budget) (> (length msgs) 2))
              do (setf msgs (cons (first msgs) (cddr msgs))))))
    msgs))

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
  (when usage
    (incf (agent-usage-total agent)
          (or (agent-cl.llm:usage-total-tokens usage) 0))))

(defvar *extra-guards* nil
  "Alist (name . function) of user guard rules registered by defguard.")

(defun register-guard (name fn)
  (pushnew (cons name fn) *extra-guards* :test (lambda (a b) (equal (car a) (car b))))
  name)

(defun check-extra-guards (agent)
  "Run user guard rules; return the first reason string or NIL."
  (dolist (entry *extra-guards*)
    (let ((reason (funcall (cdr entry) agent)))
      (when reason (return reason)))))

(defun guard-violation-p (agent)
  "Return a guard reason string if any configured limit is hit, else NIL."
  (or (let ((mt (policy-max-tokens (agent-policy agent))))
        (when (and mt (> (agent-usage-total agent) mt))
          (format nil "max-tokens (~a)" mt)))
      (check-extra-guards agent)))

(defun dispatch-tool-call (agent tc policy)
  "Validate + execute one tool call; returns (values content status).
  AGENT is passed as the tool context so tools (task.delegate etc.) can spawn
  child agents that inherit the same transport/credentials."
  (let* ((name (agent-cl.messages:tool-call-name tc))
         (args (agent-cl.messages:tool-call-arguments-plist tc)))
    (multiple-value-bind (content status)
        (agent-cl.tools:call-tool name args agent)
      (values (truncate-content content (policy-max-tool-results policy))
              status))))

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
           (agent-cl.llm:stream-finalize turn))))))

;;; ---------------------------------------------------------------------------
;;; public API
;;; ---------------------------------------------------------------------------

(defun stop (agent)
  (setf (agent-stopped-p agent) t))

(defun run (agent task &key (max-steps nil) (stream nil) (on-token nil))
  "Drive AGENT on TASK until the model answers, a guard fires, or the step
  budget is exhausted. Returns a turn-summary; the conversation transcript
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
    (loop while (and (< step budget)
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
                        (let ((tcs (agent-cl.llm:result-tool-calls result)))
                          (setf (agent-messages agent)
                                (append (agent-messages agent)
                                        (list (agent-cl.messages:assistant-message
                                               (or (agent-cl.llm:result-content result) "")
                                               :tool-calls tcs))))
                          (incf tool-count (length tcs))
                          (let ((to-run (if (policy-parallel-tools policy)
                                            tcs
                                            (subseq tcs 0 (min 1 (length tcs))))))
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
                                                     content))))))))
                        (let ((content (or (agent-cl.llm:result-content result) "")))
                          (setf (agent-messages agent)
                                (append (agent-messages agent)
                                        (list (agent-cl.messages:assistant-message content))))
                          (setf final (make-turn-summary
                                       :done-p t :final-content content
                                       :steps step :tool-count tool-count
                                       :usage (agent-cl.llm:result-usage result))))))))))
    (or final
        (make-turn-summary :done-p nil
                           :guard-reason (or guard-reason
                                              (if (agent-stopped-p agent)
                                                  :paused
                                                  :max-steps))
                           :steps step :tool-count tool-count))))
(defun call-model (agent params stream on-token)
  "One LLM round trip. Returns (:ok turn-result) or (:error readable-reason)."
  (handler-case
      (list :ok
            (if stream
                (drain-stream-turn agent params on-token)
                (agent-cl.llm:complete-turn (agent-transport agent) params)))
    (agent-cl.core:agent-pause (p)
      (list :error (format nil "paused: ~a" (agent-cl.core:agent-pause-reason p))))
    (agent-cl.core:agent-error (e)
      (list :error (agent-cl.core:agent-error-message e)))
    (error (e)
      (list :error (format nil "unexpected: ~a" e)))))

(defun ask (agent text &key (stream nil) (on-token nil))
  "Single user utterance convenience wrapper around RUN."
  (run agent text :stream stream :on-token on-token))

(defun guard-failed (agent reason)
  "Report a guard trip — used by the DSL defguard layer (M3)."
  (declare (ignore agent))
  (make-turn-summary :done-p nil :guard-reason reason :steps 0 :tool-count 0))
