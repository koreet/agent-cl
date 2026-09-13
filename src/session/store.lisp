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
   (events   :initarg :events   :initform nil :accessor session-events)
   ;; Tail CONS of EVENTS, so appending is O(1). APPEND-ing the whole list on
   ;; every event made a long session quadratic (and copied the transcript each
   ;; time).
   (tail     :initarg :tail     :initform nil :accessor session-tail)))

(defvar *session-lock* (bt:make-lock "agent-cl-session")
  "Serializes event appends: two threads writing the same session file could
  otherwise interleave partial lines and corrupt the JSONL log.")

(defun session-set-events (session events)
  "Install EVENTS as the session's in-memory log, fixing up the tail pointer."
  (setf (session-events session) events
        (session-tail session) (last events))
  events)

(defun session-record-event (session decoded)
  "Append DECODED to the in-memory log in O(1)."
  (let ((cell (list decoded)))
    (if (session-tail session)
        (progn (setf (cdr (session-tail session)) cell)
               (setf (session-tail session) cell))
        (setf (session-events session) cell
              (session-tail session) cell))
    decoded))

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
      (session-set-events s (session-replay s)))
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
    (bt:with-lock-held (*session-lock*)
      (agent-cl.core:write-file-string
       (session-path session)
       (concatenate 'string json (string #\Newline))
       :if-exists :append)
      (session-record-event session (agent-cl.core:decode-to-plist json)))
    event))

(defun session-replay (session)
  "Read all events back from disk as plists. A corrupt line (crash residue,
  partial write, external edit) is skipped with a warning instead of aborting
  the whole session replay.

  The file is read LENIENTLY: a strict UTF-8 read raised on a single stray byte
  (e.g. ANSI text captured from a subprocess), which defeated the whole
  skip-the-corrupt-line design by failing the entire replay."
  (let ((path (session-path session)))
    (when (uiop:file-exists-p path)
      (let ((bad 0)
            (events nil))
        (dolist (line (uiop:split-string
                       (or (agent-cl.core:read-file-lenient path) "")
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
  "MSG as an appendable wire hash with a \"type\": \"message\" discriminator and
  a TS timestamp. Without TS, SESSION-LAST-TS was NIL for every message event, so
  a session's age/order was invisible."
  (let ((h (agent-cl.llm:encode-message-wire msg)))
    (setf (gethash "type" h) "message")
    (setf (gethash "ts" h) (agent-cl.core:now-iso8601))
    h))

(defun event-role (event)
  "Keyword role of a message EVENT, or NIL when the role is missing/unknown."
  (let ((r (getf event :ROLE)))
    (and (stringp r)
         (let ((k (intern (string-upcase r) :keyword)))
           (and (member k '(:system :user :assistant :tool)) k)))))

(defun event->message (event)
  "Rebuild a message from a replay event plist, or NIL when the event carries no
  usable role. An unknown role used to hit ECASE and abort the whole replay, so a
  single unexpected line made the entire session unloadable."
  (let ((role (event-role event)))
    (when role
      (cond
        ((eq role :tool)
         (agent-cl.messages:tool-result-message
          (getf event :TOOL-CALL-ID)
          (or (getf event :CONTENT) "")
          :name (getf event :NAME)))
        ((and (eq role :assistant) (getf event :TOOL-CALLS))
         (agent-cl.messages:assistant-message
          (or (getf event :CONTENT) "")
          :name (getf event :NAME)
          :tool-calls
          (loop for tc in (getf event :TOOL-CALLS)
                for i from 0
                for fn = (getf tc :FUNCTION)
                collect (agent-cl.messages:make-tool-call
                         ;; keep the pairing valid even if the log lost an id
                         (or (getf tc :ID) (format nil "call_~a" i))
                         (getf fn :NAME)
                         (or (getf fn :ARGUMENTS) "{}")))))
        (t
         (agent-cl.messages:make-message
          role :content (or (getf event :CONTENT) "")
          :name (getf event :NAME)))))))

(defun persist-message (session msg)
  "Append MSG to SESSION; returns the event."
  (let ((event (message->event msg)))
    (session-append session event)
    event))

(defun replayed-messages (session)
  "All message events reconstructed in order (events with an unusable role are
  dropped)."
  (loop for e in (session-events session)
        when (string= (getf e :TYPE) "message")
          append (let ((m (event->message e))) (when m (list m)))))

;; ---------------------------------------------------------------------------
;; session discovery / summaries (REPL multi-session switching)
;; ---------------------------------------------------------------------------

(defun session-ids (directory)
  "All existing session ids under DIRECTORY (alphabetical)."
  (let ((root (uiop:ensure-directory-pathname
               (or directory *default-session-root*))))
    (when (uiop:directory-exists-p root)
      (loop for sub in (uiop:subdirectories root)
            when (uiop:file-exists-p
                  (merge-pathnames "events.jsonl" sub))
              ;; sub is ".../sessions/<id>/": take the <id> directory name
              collect (let* ((dn (directory-namestring sub))
                             (trimmed (string-right-trim '(#\/ #\\) dn))
                             (last-sep (position-if
                                        (lambda (c) (or (char= c #\/)
                                                        (char= c #\\)))
                                        trimmed :from-end t)))
                        (subseq trimmed (1+ (or last-sep -1))))))))

(defun load-session (id &key (directory *default-session-root*))
  "Open (creating if needed) and return the session object for ID."
  (open-session id :directory directory))

(defun session-first-user-text (session)
  "Preview text for SESSION: the first USER message that has content, collapsed
  to a single line. NIL when the session has no user message yet.

  It used to look only at the FIRST message event, so a session whose log starts
  with a checkpoint (or an assistant message) showed no preview at all."
  (let ((c (loop for e in (session-events session)
                 when (and (string= (getf e :TYPE) "message")
                           (let ((r (getf e :ROLE)))
                             (and (stringp r) (string-equal r "user")))
                           (getf e :CONTENT))
                   return (getf e :CONTENT))))
    (when c
      (let* ((flat (substitute #\Space #\Newline
                               (substitute #\Space #\Return
                                           (substitute #\Space #\Tab c))))
             (trimmed (string-trim '(#\Space #\") flat)))
        (when (plusp (length trimmed))
          (if (> (length trimmed) 60)
              (concatenate 'string (subseq trimmed 0 60) "…")
              trimmed))))))

(defun session-message-count (session)
  (count-if (lambda (e) (string= (getf e :TYPE) "message"))
            (session-events session)))

(defun session-last-ts (session)
  "Timestamp of the last event, or NIL."
  (let ((last (first (last (session-events session)))))
    (and last (getf last :TS))))

;;; ---------------------------------------------------------------------------
;;; interactive session selection (pure)
;;; ---------------------------------------------------------------------------

(defun resolve-session-choice (choice ids)
  "Resolve a user CHOICE against the ordered list of session IDS.
  Returns (values ID STATUS):
    CHOICE may be a 1-based index (\"3\"), a full id, or a unique id prefix.
    STATUS = :ok          -> ID is the pick
             :none        -> blank / no match
             :ambiguous   -> prefix matched more than one id (ID = nil)
             :out-of-range-> numeric pick out of [1, N]
  Pure: no IO, no printing — the caller drives any prompt."
  (let* ((raw (string-trim '(#\Space #\Tab #\Return) (or choice ""))))
    (cond
      ((zerop (length raw)) (values nil :none))
      ;; numeric pick: all digits
      ((every #'digit-char-p raw)
       (let ((n (parse-integer raw)))
         (if (and (>= n 1) (<= n (length ids)))
             (values (nth (1- n) ids) :ok)
             (values nil :out-of-range))))
      (t
       ;; exact match first
       (let ((exact (find raw ids :test #'string-equal)))
         (if exact
             (values exact :ok)
             ;; unique prefix match
             (let ((hits (remove-if-not
                          (lambda (id) (and (>= (length id) (length raw))
                                            (string-equal raw id
                                                          :end1 (length raw)
                                                          :end2 (length raw))))
                          ids)))
               (cond ((= (length hits) 1) (values (first hits) :ok))
                     ((> (length hits) 1)  (values nil :ambiguous))
                     (t                    (values nil :none))))))))))

;;; ---------------------------------------------------------------------------
;;; conversation replay for the UI (pure)
;;; ---------------------------------------------------------------------------

(defun conversation-entries (messages)
  "Reduce replayed MESSAGES to displayable (role . content) pairs: keep only
  :user / :assistant messages that have non-blank text (drop tool traffic and
  assistant messages that carried only tool_calls). Pure."
  (let ((out '()))
    (dolist (m messages)
      (let ((role (agent-cl.messages:msg-role m))
            (text (agent-cl.messages:msg-content m)))
        (when (and (member role '(:user :assistant))
                   text
                   (plusp (length (string-trim '(#\Space #\Tab #\Newline #\Return)
                                               text))))
          (push (cons role text) out))))
    (nreverse out)))

(defun last-conversation-turns (messages n)
  "The last N displayable (role . content) entries from MESSAGES (see
  CONVERSATION-ENTRIES). N NIL means all. Pure."
  (let ((all (conversation-entries messages)))
    (if (and n (< n (length all)))
        (subseq all (- (length all) n))
        all)))
