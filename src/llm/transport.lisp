;;;; src/llm/transport.lisp — endpoint transport protocol.
;;;;
;;;; Design (docs/architecture.md §5.2): the engine talks to a TRANSPORT object
;;;; through GENERIC-FUNCTION PERFORM-REQUEST. Two implementations:
;;;;   * mock-transport — scripted, in-image, fully deterministic (all tests);
;;;;   * http-transport  — real HTTP(S). This sandbox has no in-Lisp TLS and no
;;;;     vendored dexador closure, so the actual network call is delegated to the
;;;;     *http-fetch-hook* that deployments can inject (or dexador can be loaded
;;;;     on a normal machine and the hook wired in scripts/). Interface stays.
(in-package #:agent-cl.llm)

(defclass transport ()
  ((name :initarg :name :initform "transport" :reader transport-name)))

;;; ---------------------------------------------------------------------------
;;; real HTTP transport (hook-based)
;;; ---------------------------------------------------------------------------

(defparameter *http-fetch-hook* nil
  "When bound to (lambda (request-json &key base-url api-key timeout stream))
  returns: a JSON response string for STREAM=NIL, or a zero-arg supplier
  function yielding successive raw SSE lines (NIL when done) for STREAM=T.
  Wire it in scripts/dev.lisp with dexador on a networked machine.")

(defclass http-transport (transport)
  ((base-url :initarg :base-url :initform *default-base-url*)
   (api-key  :initarg :api-key  :initform nil)
   (timeout  :initarg :timeout  :initform *request-timeout-seconds*)))

(defun make-http-transport (&key base-url api-key timeout (name "http"))
  (make-instance 'http-transport
                 :name name
                 :base-url (or base-url *default-base-url*)
                 :api-key (or api-key (uiop:getenv "AGENT_CL_API_KEY"))
                 :timeout (or timeout *request-timeout-seconds*)))

;;; ---------------------------------------------------------------------------
;;; mock transport
;;; ---------------------------------------------------------------------------

(defclass mock-transport (transport)
  ((script :initarg :script :initform nil :accessor mock-script))
  (:documentation "Scripted transport. Each script item is
    (:reply <json-response-string>)                     for non-stream turns
    (:stream (<raw-sse-line> ...))                      for stream turns"))

(defun make-mock-transport (&key script (name "mock"))
  (make-instance 'mock-transport :name name :script (copy-list script)))

(defun mock-push (transport scenario)
  (push scenario (mock-script transport)))

(defun mock-reset (transport)
  (setf (mock-script transport) nil))

(defun script-reply (json-string) (list :reply json-string))
(defun script-stream (lines) (list :stream lines))
(defun script-error (&key (status 500) (message "mock http error") (retryable t))
  "Scenario that signals a TRANSPORT-ERROR; used to exercise engine retry."
  (list :error status message retryable))

;;; ---------------------------------------------------------------------------
;;; perform-request
;;; ---------------------------------------------------------------------------

(defgeneric perform-request (transport params)
  (:documentation "PARAMS plist like ENCODE-REQUEST-JSON accepts (:model :messages
  :tools :tool-choice :temperature :max-tokens :stream :response-format).
  Non-stream params return a TURN-RESULT; :stream T params return a
  STREAMING-TURN whose lines must be advanced with STREAM-ADVANCE."))

(defmethod perform-request ((tr http-transport) params)
  (let ((request-json (encode-request-json params)))
    (unless *http-fetch-hook*
      (error 'agent-cl.core:transport-error
             :message "no *http-fetch-hook* wired for the http transport (offline build); use a mock transport or inject a hook"
             :retryable nil))
    (let ((result (funcall *http-fetch-hook* request-json
                           :base-url (slot-value tr 'base-url)
                           :api-key (slot-value tr 'api-key)
                           :timeout (slot-value tr 'timeout)
                           :stream (getf params :stream))))
      (if (not (getf params :stream))
          (parse-chat-json result)
          ;; streaming: the hook returned either a character stream of SSE lines
          ;; or a supplier function; wrap both as the turn's line-source.
          (let ((src (if (functionp result)
                         result
                         (let ((st result))
                           (lambda ()
                             (let ((line (read-line st nil nil)))
                               (when (null line)
                                 (ignore-errors (close st)))
                               line))))))
            (make-instance 'streaming-turn :line-source src))))))

(defmethod perform-request ((tr mock-transport) params)
  (let* ((script (mock-script tr))
         (scenario (pop script)))
    (setf (mock-script tr) script)
    (unless scenario
      (error 'agent-cl.core:transport-error
             :message "mock transport script exhausted"
             :retryable nil))
    (if (eq (first scenario) :error)
        ;; (:error status message retryable) — signals so the engine can retry
        (destructuring-bind (_ status message retryable) scenario
          (declare (ignore _))
          (error 'agent-cl.core:transport-error
                 :message message :status status :retryable retryable))
        (destructuring-bind (kind payload) scenario
          (ecase kind
            (:reply
             (when (getf params :stream)
               (error 'agent-cl.core:transport-error
                      :message "mock scenario :reply used with :stream t"
                      :retryable nil))
             (parse-chat-json payload))
            (:stream
             (unless (getf params :stream)
               (error 'agent-cl.core:transport-error
                      :message "mock scenario :stream used without :stream t"
                      :retryable nil))
             (let ((turn (make-instance 'streaming-turn)))
               (setf (slot-value turn 'line-source)
                     (let ((lines payload)) (lambda () (pop lines))))
               turn)))))))

;;; ---------------------------------------------------------------------------
;;; streaming driver
;;; ---------------------------------------------------------------------------

(defun stream-advance (turn)
  "Pull one line from TURN's source and feed it. Returns the status keyword
  (:ok / :done / :eof)."
  (let ((src (slot-value turn 'line-source)))
    (if (null src)
        :eof
        (let ((line (funcall src)))
          (if (null line)
              :eof
              (stream-feed turn line))))))

(defun stream-drain (turn)
  "Advance until [DONE] or the source is exhausted."
  (loop while (not (stream-finished-p turn))
        for status = (stream-advance turn)
        until (eq status :eof))
  turn)

(defun complete-turn (transport params)
  "Convenience: run PERFORM-REQUEST and always return a finished TURN-RESULT
  (streaming turns are drained synchronously)."
  (let ((result (perform-request transport params)))
    (typecase result
      (turn-result result)
      (streaming-turn (stream-finalize (stream-drain result)))
      (t result))))
