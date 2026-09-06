;;;; src/messages.lisp — conversation message envelope (docs/architecture.md §5.1).
(in-package #:agent-cl.messages)

(defclass message ()
  ((role        :initarg :role        :initform :user :accessor msg-role)
   (content     :initarg :content     :initform ""  :accessor msg-content)
   (tool-calls  :initarg :tool-calls  :initform nil :accessor msg-tool-calls)
   (tool-call-id :initarg :tool-call-id :initform nil :accessor msg-tool-call-id)
   (name        :initarg :name        :initform nil :accessor msg-name)
   (meta        :initarg :meta        :initform nil :accessor msg-meta)))

(defun messagep (x) (typep x 'message))

(defun make-message (role &key (content "") tool-calls tool-call-id name meta)
  (make-instance 'message
                 :role role :content content :tool-calls tool-calls
                 :tool-call-id tool-call-id :name name :meta meta))

;; A tool call requested by the assistant (wire shape function.arguments is a
;; JSON string; TOOL-CALL-ARGUMENTS-PLIST lazily parses it).
(defstruct (tool-call (:constructor make-tool-call (id name arguments)))
  id
  name
  arguments                 ; raw JSON string
  (parsed nil))             ; lazy cache for the parsed arguments plist

(defun tool-call-arguments-plist (tc)
  (or (tool-call-parsed tc)
      (setf (tool-call-parsed tc)
            (agent-cl.core:decode-to-plist (tool-call-arguments tc)))))

(defparameter +role-system    :system)
(defparameter +role-user      :user)
(defparameter +role-assistant :assistant)
(defparameter +role-tool      :tool)

(defun system-message (content &key (name nil))
  (make-message +role-system :content content :name name))

(defun user-message (content &key (name nil))
  (make-message +role-user :content content :name name))

(defun assistant-message (content &key tool-calls (name nil))
  (make-message +role-assistant :content content :tool-calls tool-calls :name name))

(defun tool-result-message (tool-call-id content &key (name nil))
  (make-message +role-tool :content content :tool-call-id tool-call-id :name name))
