;;;; src/llm/sse.lisp — Server-Sent Events parsing for chat.completions streams.
;;;;
;;;; The provider sends one JSON object per "data: ..." line. Tool-call
;;;; arguments arrive as JSON string *fragments* across many chunks, keyed by
;;;; tool_calls[i].index; we must concatenate fragments per index and only
;;;; parse the whole string once the stream finishes (docs/architecture.md
;;;; §5.3).
(in-package #:agent-cl.llm)

(defstruct (tool-call-accum (:constructor make-tool-call-accum (index)))
  index
  (id nil)
  (name nil)
  (arguments (make-string-output-stream)))

(defclass streaming-turn ()
  ((text        :initform (make-array 32 :element-type 'character
                                      :adjustable t :fill-pointer 0))
   (tool-accs   :initform (make-hash-table)
                :reader stream-tool-accs)
   (line-source :initarg :line-source :initform nil)   ; supplier function (transport)
   (usage       :initarg :usage :initform nil :accessor stream-usage)
   (finish      :initarg :finish :initform nil :accessor stream-finish)
   (finished    :initarg :finished :initform nil :accessor stream-finished-p)
   (done-seen   :initform nil :accessor stream-done-seen)))

(defun stream-append-text (turn text)
  (let ((v (slot-value turn 'text)))
    (loop for ch across text do (vector-push-extend ch v))))

(defun stream-text (turn)
  "Accumulated assistant text so far (non-destructive copy)."
  (let ((v (slot-value turn 'text)))
    (let ((s (make-string (length v))))
      (replace s v)
      s)))

(defun acc-arguments-string (acc)
  (get-output-stream-string (tool-call-accum-arguments acc)))

(defun sse-data-of-line (line)
  "Return the data payload of an SSE line, or :DONE / :IGNORE."
  (let ((l (string-trim '(#\Return #\Newline #\Space #\Tab) line)))
    (cond ((zerop (length l)) :ignore)
          ((string= l "[DONE]") :done)
          ((string= l "data: [DONE]") :done)
          ((string-prefix-p "data:" l)
           (string-trim '(#\Space) (subseq l 5)))
          (t :ignore))))

(defun stream-feed (turn line)
  "Feed one SSE line into TURN. Returns :done after [DONE], else :ok."
  (let ((payload (sse-data-of-line line)))
    (case payload
      (:ignore :ok)
      (:done (setf (stream-finished-p turn) t
                   (stream-done-seen turn) t)
             :done)
      (otherwise
       (let* ((obj (agent-cl.core:decode-to-plist payload))
              (usage (getf obj :USAGE)))
         (when usage (setf (stream-usage turn) (normalize-usage usage)))
         (let ((choices (getf obj :CHOICES)))
           (dolist (ch choices)
             (let ((finish (getf ch :FINISH-REASON)))
               (when finish (setf (stream-finish turn) finish)))
             (let ((delta (getf ch :DELTA)))
               (when delta
                 (let ((content (getf delta :CONTENT)))
                   (when (and content (not (eq content :null)))
                     (stream-append-text turn content)))
                 (dolist (tc (getf delta :TOOL-CALLS))
                   (let* ((idx (or (getf tc :INDEX) 0))
                          (acc (or (gethash idx (stream-tool-accs turn))
                                   (setf (gethash idx (stream-tool-accs turn))
                                         (make-tool-call-accum idx)))))
                     (let ((id (getf tc :ID)))
                       (when id (setf (tool-call-accum-id acc) id)))
                     (let ((fn (getf tc :FUNCTION)))
                       (when fn
                         (let ((nm (getf fn :NAME)))
                           (when nm (setf (tool-call-accum-name acc) nm)))
                         (let ((args (getf fn :ARGUMENTS)))
                           (when (and args (not (eq args :null)))
                             (write-string args
                                           (tool-call-accum-arguments acc))))))))))))
         :ok)))))

(defun stream-finalize (turn)
  "Build the final turn-result from the accumulated stream state."
  (let ((tcs
          (loop for idx from 0
                for acc = (gethash idx (stream-tool-accs turn))
                while acc
                collect (agent-cl.messages:make-tool-call
                         (tool-call-accum-id acc)
                         (tool-call-accum-name acc)
                         (acc-arguments-string acc)))))
    (make-instance 'turn-result
                   :content (let ((s (stream-text turn)))
                              (and (plusp (length s)) s))
                   :tool-calls tcs
                   :finish-reason (stream-finish turn)
                   :usage (stream-usage turn))))

(defun string-prefix-p (prefix string)
  (and (>= (length string) (length prefix))
       (string= prefix string :end2 (length prefix))))
