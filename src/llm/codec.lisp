;;;; src/llm/codec.lisp — OpenAI-compatible wire codec.
;;;;
;;;; Maps our internal message envelope (agent-cl.messages) and tool registry
;;;; entries onto the OpenAI/DeepSeek chat.completions line format, and parses
;;;; provider responses into turn-result objects. Endpoint dialect differences
;;;; are confined to this file (docs/architecture.md §5.2).
(in-package #:agent-cl.llm)

(defparameter *default-base-url* "https://api.deepseek.com/v1")
(defparameter *default-model* "deepseek-chat")
(defparameter *request-timeout-seconds* 120)
(defparameter *max-retries* 3)

;;; ---------------------------------------------------------------------------
;;; turn-result: normalized outcome of one model round-trip
;;; ---------------------------------------------------------------------------

(defclass turn-result ()
  ((content       :initarg :content :initform nil :accessor result-content)
   (tool-calls    :initarg :tool-calls :initform nil :accessor result-tool-calls)
   (finish-reason :initarg :finish-reason :initform nil :accessor result-finish-reason)
   (usage         :initarg :usage :initform nil :accessor result-usage))
  (:documentation "One completion: either final text, or a set of tool calls the
  assistant wants executed (or both, some models emit both)."))

;;; ---------------------------------------------------------------------------
;;; encoding: message envelope -> wire hash
;;; ---------------------------------------------------------------------------

(defun role->string (role)
  (ecase role
    (:system "system") (:user "user") (:assistant "assistant") (:tool "tool")))

(defun json-bool (x) (if x yason:true yason:false))

(defun put-content (h msg)
  (setf (gethash "content" h) (or (agent-cl.messages:msg-content msg) "")))

(defun put-name (h msg)
  (let ((name (agent-cl.messages:msg-name msg)))
    (when name (setf (gethash "name" h) name))))

(defun put-tool-call (tc)
  (let ((tc-h (make-hash-table :test 'equal))
        (fn-h (make-hash-table :test 'equal)))
    (setf (gethash "id" tc-h) (agent-cl.messages:tool-call-id tc)
          (gethash "type" tc-h) "function"
          (gethash "name" fn-h) (agent-cl.messages:tool-call-name tc)
          (gethash "arguments" fn-h) (agent-cl.messages:tool-call-arguments tc)
          (gethash "function" tc-h) fn-h)
    tc-h))

(defun encode-message-wire (msg)
  "MSG (agent-cl.messages:message) -> wire hash-table."
  (let ((h (make-hash-table :test 'equal))
        (role (agent-cl.messages:msg-role msg)))
    (setf (gethash "role" h) (role->string role))
    (put-name h msg)
    (cond ((eq role :tool)
           (setf (gethash "tool_call_id" h) (agent-cl.messages:msg-tool-call-id msg))
           (put-content h msg))
          ((eq role :assistant)
           ;; "" instead of JSON null for empty content — some compatible
           ;; endpoints are picky about explicit null; "" is universal.
           (put-content h msg)
           (let ((tcs (agent-cl.messages:msg-tool-calls msg)))
             (when tcs
               (setf (gethash "tool_calls" h) (mapcar #'put-tool-call tcs)))))
          (t (put-content h msg)))
    h))

(defun encode-request-json (params)
  "PARAMS plist: :model :messages :tools :tool-choice :temperature :max-tokens
  :stream :response-format. Returns the JSON request body string."
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash "model" h)
          (or (getf params :model) *default-model*))
    (setf (gethash "messages" h)
          (mapcar #'encode-message-wire (getf params :messages)))
    (let ((tools (getf params :tools)))
      (when tools (setf (gethash "tools" h) tools)))
    (let ((choice (getf params :tool-choice)))
      (when choice (setf (gethash "tool_choice" h) choice)))
    (let ((temp (getf params :temperature)))
      (when temp (setf (gethash "temperature" h) temp)))
    (let ((mt (getf params :max-tokens)))
      (when mt (setf (gethash "max_tokens" h) mt)))
    (when (getf params :stream)
      (setf (gethash "stream" h) yason:true
            (gethash "stream_options" h)
            (let ((so (make-hash-table :test 'equal)))
              (setf (gethash "include_usage" so) yason:true)
              so)))
    (let ((rf (getf params :response-format)))
      (when rf (setf (gethash "response_format" h) rf)))
    (agent-cl.core:json-encode h)))

;;; ---------------------------------------------------------------------------
;;; decoding: provider response -> turn-result
;;; ---------------------------------------------------------------------------

(defun usage-prompt-tokens (usage) (getf usage :prompt-tokens))
(defun usage-completion-tokens (usage) (getf usage :completion-tokens))
(defun usage-total-tokens (usage) (getf usage :total-tokens))
(defun usage-cache-hit-tokens (usage) (getf usage :cache-hit))
(defun usage-cache-miss-tokens (usage) (getf usage :cache-miss))

(defun normalize-usage (wire-usage)
  "Wire usage plist -> normalized plist. Always carries :prompt-tokens /
  :completion-tokens / :total-tokens. Cache fields are BEST-EFFORT: providers
  that expose prompt caching (e.g. DeepSeek) report prompt_cache_hit_tokens /
  prompt_cache_miss_tokens; we accept a couple of spellings and store
  :cache-hit / :cache-miss as NIL when absent, so callers can simply omit the
  hit-rate display rather than show a fabricated number."
  (when wire-usage
    (list :prompt-tokens (getf wire-usage :PROMPT-TOKENS)
          :completion-tokens (getf wire-usage :COMPLETION-TOKENS)
          :total-tokens (getf wire-usage :TOTAL-TOKENS)
          :cache-hit (or (getf wire-usage :PROMPT-CACHE-HIT-TOKENS)
                         (getf wire-usage :CACHE-HIT-TOKENS))
          :cache-miss (or (getf wire-usage :PROMPT-CACHE-MISS-TOKENS)
                          (getf wire-usage :CACHE-MISS-TOKENS)))))

(defun parse-tool-calls (wire-tool-calls)
  "Wire tool_calls array (list of plists) -> list of message:tool-call.
  Ids are synthesized when the provider omits them: the wire contract requires
  every tool result to name the call it answers, and NIL is not a usable id."
  (loop for tc in wire-tool-calls
        for i from 0
        for fn = (getf tc :FUNCTION)
        collect (agent-cl.messages:make-tool-call
                 (or (getf tc :ID) (format nil "call_~a" i))
                 (getf fn :NAME)
                 (or (getf fn :ARGUMENTS) "{}"))))

(defun parse-chat-json (json-string)
  "Parse a non-streaming chat.completions response into a turn-result."
  (let ((wire (agent-cl.core:decode-to-plist json-string)))
    (let* ((choices (getf wire :CHOICES))
           (first (first choices))
           (msg (and first (getf first :MESSAGE))))
      (unless first
        ;; 2xx with zero choices is a provider anomaly, not a successful empty
        ;; answer — report it so the engine never treats "nothing" as done.
        (error 'agent-cl.core:transport-error
               :message "provider returned no choices"
               :retryable t))
      (unless msg
        ;; A choice without a message would decode to a turn with no content and
        ;; no tool calls, which the engine reports as a COMPLETED turn with an
        ;; empty answer. Treat it as a transport fault instead.
        (error 'agent-cl.core:transport-error
               :message "provider returned a choice without a message object"
               :retryable t))
      (let ((content (getf msg :CONTENT)))
        (make-instance 'turn-result
                       :content (and content (not (eq content :null)) content)
                       :tool-calls (parse-tool-calls (getf msg :TOOL-CALLS))
                       :finish-reason (getf first :FINISH-REASON)
                       :usage (normalize-usage (getf wire :USAGE)))))))

(defun result-truncated-p (result)
  "True when RESULT was cut off by the provider's token limit (finish_reason
  \"length\"). Such a completion is NOT a complete answer, and callers that
  present it as one silently drop the rest of the response."
  (let ((fr (result-finish-reason result)))
    (and (stringp fr) (string-equal fr "length"))))

(defun parse-models-response (json-string)
  "Parse a GET /models response into a list of model-id strings, in order.
  Shape: {\"object\":\"list\",\"data\":[{\"id\":\"deepseek-chat\",...},...]}.
  Tolerant: skips entries without a string :id. Pure."
  (let* ((wire (agent-cl.core:decode-to-plist json-string))
         (data (getf wire :DATA)))
    (loop for entry in data
          for id = (and (listp entry) (getf entry :ID))
          when (and id (stringp id)) collect id)))
