;;;; tests/render-tests.lisp — pure fenced-code markdown classifier.
;;;;
;;;; Pure, offline, deterministic tests of agent-cl.render (no key / terminal /
;;;; network). They lock in the fence-state contract: state is threaded as a
;;;; value, a fence opens/closes on explicit ``` lines, inside a fence every
;;;; non-marker line is code; an unterminated block is honestly reported as
;;;; still-open rather than leaking stale global state past the turn boundary.
(in-package #:agent-cl.tests)

;;;; helpers -----------------------------------------------------------
(defun rkinds (text)
  (mapcar #'agent-cl.render:md-line-kind
          (nth-value 1 (agent-cl.render:classify-block text))))

(defun rcodes (text)
  (loop for m in (nth-value 1 (agent-cl.render:classify-block text))
        when (eq (agent-cl.render:md-line-kind m) :code)
          collect (agent-cl.render:md-line-text m)))

(defun join-nl (&rest parts) "join PARTS with a single newline, but no trailing one"
  (format nil "~{~a~^~%~}" parts))

;;;; plain block -------------------------------------------------------
(deftest render-plain-lines-are-normal
  (is-equal '(:normal :normal) (rkinds (join-nl "hello world" "second line"))))

(deftest render-blank-lines-are-blank
  (is-equal '(:normal :blank :normal) (rkinds (join-nl "a" "" "b"))))

;;;; fenced block ------------------------------------------------------
(deftest render-fenced-code-is-coded
  (let ((m (join-nl "preamble" "```common-lisp" "(defun f (x) x)" "```" "epilogue")))
    (is-equal '(:normal :fence-start :code :fence-end :normal) (rkinds m))
    (is-equal (list "(defun f (x) x)") (rcodes m))))

(deftest render-fence-language-syntax-opens
  (is-equal '(:fence-start :code) (rkinds (join-nl "```cl" "(+ 1 2)"))))

;;;; unterminated fence must not leak a stale global --------------------
(deftest render-unterminated-fence-is-honest-open-final
  ;; stream/truncated output: a code block opened but never closed.
  (let ((m (join-nl "intro" "```python" "x = 1")))
    (multiple-value-bind (final lines) (agent-cl.render:classify-block m)
      (is-equal :fence-in final)                 ; still open at end
      (is-equal '(:normal :fence-start :code) (mapcar #'agent-cl.render:md-line-kind lines)))))

;;;; blank line inside a fence stays inside -----------------------------
(deftest render-blank-inside-fence-keeps-fence
  (is-equal '(:fence-start :blank :code :code :fence-end)
            (rkinds (join-nl "```" "" "def f():" "  pass" "```"))))

;;;; trailing non-newline fragment still classifies ----------------------
(deftest render-fragment-end-is-a-total-answer
  (is-equal '(:normal :normal) (rkinds (join-nl "ok" "tail-no-nl"))))

;;;; classify-lines purity: state is returned, not globalled -------------
(deftest render-state-threading-is-pure-per-batch
  ;; feeding the same block twice from a clean start gives identical answers
  (let ((m (join-nl "```python" "x=1")))
    (multiple-value-bind (f1 l1) (agent-cl.render:classify-block m)
      (multiple-value-bind (f2 l2) (agent-cl.render:classify-block m)
        (is-equal f1 f2)
        (is-equal (mapcar #'agent-cl.render:md-line-kind l1)
                  (mapcar #'agent-cl.render:md-line-kind l2))))))
