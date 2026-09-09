;;;; src/render/engine.lisp — pure, fenced-code-aware markdown line classifier.
;;;;
;;;; Why this exists:
;;;;   repl.lisp historically kept *md-state* as a shared special variable with a
;;;;   line-based toggle, and flushed partial fragments through the same code
;;;;   path as complete lines. That design made "am I inside a ``` fence right
;;;;   now" a piece of *global mutable* state that could leak across turns or
;;;;   partial-chunk flushes — and it could not be regression-tested without a
;;;;   real LLM round trip.
;;;;
;;;; This file distills that behaviour into a deterministic, IO-free core: a
;;;; pure classifier that takes a *fence state* + one logical line and returns
;;;; the next state plus a classified line (fence-start / fence-end / normal /
;;;; code / blank). Fence state is threaded as an explicit value, never a
;;;; special variable — so cross-turn or cross-chunk leakage is impossible *by
;;;; construction*, and every branch is unit-testable with no network/terminal.
;;;;
;;;; The *terminal theme* (choosing ANSI codes) is intentionally kept out of
;;;; this core; callers (e.g. repl.lisp) map the returned kinds to the colour
;;;; they want. This file only answers "what kind of line is this, and where is
;;;; the fence boundary".

(in-package #:agent-cl.render)

;;; ---------------------------------------------------------------------------
;;; fence state constants & logical line
;;; ---------------------------------------------------------------------------

(defconstant +fence-out+ :fence-out "Not currently inside a ``` code block.")
(defconstant +fence-in+  :fence-in  "Currently inside a ``` code block.")

(defstruct (md-line (:constructor make-md-line%))
  kind            ; :fence-start | :fence-end | :normal | :code | :blank
  text)           ; content; for :code lines this is the code (marker separate)

(defun fence-open-p (line) (eq (md-line-kind line) :fence-start))
(defun fence-close-p (line) (eq (md-line-kind line) :fence-end))

;;; ---------------------------------------------------------------------------
;;; predicates
;;; ---------------------------------------------------------------------------

(defun fence-markerp (s)
  "True when S (trimmed) starts with exactly three backticks."
  (and (>= (length s) 3) (string= (subseq s 0 3) "```")))

(defun classify-one (state line)
  "Classify one logical LINE (no trailing newline) given fence STATE.
  Pure: returns (values new-state md-line)."
  (let ((trim (string-trim '(#\Space #\Tab #\Return) line)))
    (cond
      ((zerop (length trim))
       ;; blank/whitespace-only: keep state, mark :blank
       (values state (make-md-line% :kind :blank :text line)))
      ((eq state +fence-in+)
       ;; inside a fence: a marker closes it, anything else is a code line
       (if (fence-markerp trim)
           (values +fence-out+ (make-md-line% :kind :fence-end :text line))
           (values +fence-in+  (make-md-line% :kind :code    :text line))))
      ((fence-markerp trim)   ; any ```-starting trimmed line toggles the fence
       (values +fence-in+ (make-md-line% :kind :fence-start :text line)))
      (t
       (values +fence-out+ (make-md-line% :kind :normal :text line))))))

;;; ---------------------------------------------------------------------------
;;; whole-block classifiers (pure; state threaded, never mutated globally)
;;; ---------------------------------------------------------------------------

(defun classify-lines (state lines)
  "Feed LINES (no trailing newlines) through the state machine.
  Returns (values final-state classified-lines). Pure."
  (let ((out nil) (cur state))
    (dolist (l lines)
      (multiple-value-bind (st m) (classify-one cur l)
        (setf cur st)
        (push m out)))
    (values cur (nreverse out))))

(defun classify-block (text)
  "Split TEXT across newlines into logical lines (empty lines included) and
  classify the whole block. Returns (values final-state list-of-md-line).

  A trailing fragment that did not end with a newline is kept as one more
  logical line, so callers (e.g. a streaming flush) always get a total answer
  and can decide for themselves whether that final open line is truncated.
  Deterministic for every input."
  (let ((parts '()) (start 0) (n (length text)))
    (loop for nl = (position #\Newline text :start start)
          while nl
          do (progn (push (subseq text start nl) parts)
                    (setf start (1+ nl)))
          finally (when (< start n) (push (subseq text start) parts)))
    (classify-lines +fence-out+ (nreverse parts))))
