;;;; src/session/store.lisp — event-sourced session persistence (JSONL).
;;;;
;;;; A session is an append-only event log (docs/architecture.md §5.5):
;;;;   <root>/<id>/events.jsonl
;;;; Every event is one JSON object per line. Message events store the full
;;;; wire representation so replay restores the transcript exactly. Sessions
;;;; support audit (who called what), debugging, resume and test fixtures.
(in-package #:agent-cl.session)

(defclass session ()
  ((id       :initarg :id       :initform (agent-cl.core:uuid-string)
             :accessor session-id)
   (path     :initarg :path     :accessor session-path)
   (events   :initarg :events   :initform nil :accessor session-events)))

(defvar *default-session-root*
  ;; writable even in the offline sandbox; override via make-session :directory
  (merge-pathnames ".tools/sessions/"
                   (uiop:getcwd)))

(defun session-dir (sid directory)
  (merge-pathnames (format nil "~a/" sid)
                   (uiop:ensure-directory-pathname
                    (or directory *default-session-root*))))

(defun make-session (&key id (directory *default-session-root*))
  (let* ((sid (or id (agent-cl.core:uuid-string)))
         (dir (session-dir sid directory)))
    (ensure-directories-exist dir)
    (make-instance 'session :id sid
                   :path (merge-pathnames "events.jsonl" dir))))

(defun open-session (id &key (directory *default-session-root*))
  "Reopen an existing session (creating it if absent) and replay events."
  (let ((dir (session-dir id directory))
        (s (make-session :id id :directory directory)))
    (when (and (uiop:directory-exists-p dir)
               (uiop:file-exists-p (merge-pathnames "events.jsonl" dir)))
      (setf (session-events s) (session-replay s)))
    s))

(defun event-json (event)
  "JSON text for EVENT: a wire hash-table or a simple plist."
  (if (hash-table-p event)
      (agent-cl.core:json-encode event)
      (agent-cl.core:encode-plist-object event)))

(defun session-append (session event)
  "Append EVENT (wire hash-table or simple plist) as one JSONL line and keep
  the decoded tail in memory."
  (let ((json (event-json event)))
    (agent-cl.core:write-file-string
     (session-path session)
     (concatenate 'string json (string #\Newline))
     :if-exists :append)
    (setf (session-events session)
          (append (session-events session)
                  (list (agent-cl.core:decode-to-plist json))))
    event))

(defun session-replay (session)
  "Read all events back from disk as plists. A corrupt line (crash residue,
  partial write, external edit) is skipped with a warning instead of aborting
  the whole session replay."
  (let ((path (session-path session)))
    (when (uiop:file-exists-p path)
      (let ((bad 0)
            (events nil))
        (dolist (line (uiop:split-string
                       (agent-cl.core:read-file-string path)
                       :separator '(#\Newline)))
          (let ((trimmed (string-trim '(#\Return #\Space) line)))
            (unless (string= trimmed "")
              (handler-case
                  (push (agent-cl.core:decode-to-plist trimmed) events)
                (error (e)
                  (incf bad)
                  (format t "~&[session] 跳过损坏事件行 (~a): ~a~%"
                          bad (subseq trimmed 0 (min 80 (length trimmed)))))))))
        (when (plusp bad)
          (format t "~&[session] ~a 行损坏被跳过~%" bad))
        (nreverse events)))))

(defun save-checkpoint (session &optional note)
  "Record a checkpoint event (used by interrupt/resume flows)."
  (session-append session (list :type "checkpoint"
                                :ts (agent-cl.core:now-iso8601)
                                :note (or note "agent state"))))

;;; ---------------------------------------------------------------------------
;;; message <-> event conversion (reuses the llm wire codec)
;;; ---------------------------------------------------------------------------

(defun message->event (msg)
  "MSG as an appendable wire hash with a \"type\": \"message\" discriminator."
  (let ((h (agent-cl.llm:encode-message-wire msg)))
    (setf (gethash "type" h) "message")
    h))

(defun event->message (event)
  "Rebuild a message from a replay event plist."
  (let ((role (ecase (intern (string-upcase (getf event :ROLE)) :keyword)
                (:SYSTEM :system) (:USER :user) (:ASSISTANT :assistant)
                (:TOOL :tool))))
    (cond
      ((eq role :tool)
       (agent-cl.messages:tool-result-message
        (getf event :TOOL-CALL-ID)
        (or (getf event :CONTENT) "")
        :name (getf event :NAME)))
      ((and (eq role :assistant) (getf event :TOOL-CALLS))
       (agent-cl.messages:assistant-message
        (or (getf event :CONTENT) "")
        :tool-calls
        (loop for tc in (getf event :TOOL-CALLS)
              for fn = (getf tc :FUNCTION)
              collect (agent-cl.messages:make-tool-call
                       (getf tc :ID)
                       (getf fn :NAME)
                       (or (getf fn :ARGUMENTS) "{}")))))
      (t
       (agent-cl.messages:make-message
        role :content (or (getf event :CONTENT) "")
        :name (getf event :NAME))))))

(defun persist-message (session msg)
  "Append MSG to SESSION; returns the event."
  (let ((event (message->event msg)))
    (session-append session event)
    event))

(defun replayed-messages (session)
  "All message events reconstructed in order."
  (loop for e in (session-events session)
        when (string= (getf e :TYPE) "message")
          collect (event->message e)))
