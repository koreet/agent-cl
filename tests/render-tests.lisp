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

;;;; heading classifier (pure) -----------------------------------------
(deftest render-heading-levels
  (multiple-value-bind (lvl txt) (agent-cl.render:classify-heading "# Title")
    (is-equal 1 lvl) (is-equal "Title" txt))
  (multiple-value-bind (lvl txt) (agent-cl.render:classify-heading "### Deep")
    (is-equal 3 lvl) (is-equal "Deep" txt)))

(deftest render-heading-not-a-heading
  ;; a '#' glued to text is a tag, not a heading
  (multiple-value-bind (lvl _) (agent-cl.render:classify-heading "#tag")
    (declare (ignore _)) (is-equal 0 lvl))
  ;; plain text is level 0
  (multiple-value-bind (lvl _) (agent-cl.render:classify-heading "hello")
    (declare (ignore _)) (is-equal 0 lvl))
  ;; empty line is level 0
  (multiple-value-bind (lvl _) (agent-cl.render:classify-heading "")
    (declare (ignore _)) (is-equal 0 lvl)))

(deftest render-heading-max-six
  ;; more than six hashes: only the first six count as level, rest is text
  (multiple-value-bind (lvl txt) (agent-cl.render:classify-heading "####### seven")
    (is-equal 6 lvl) (is-equal "# seven" txt)))

(deftest render-heading-bare-hashes
  (multiple-value-bind (lvl txt) (agent-cl.render:classify-heading "###")
    (is-equal 3 lvl) (is-equal "" txt)))

;;;; inline span renderer (pure) ---------------------------------------
(defparameter +theme+ '(:bold "1" :code "32" :link "4"))

(deftest render-inline-bold
  (is-equal (format nil "a~c[1mB~c[0mz" #\Escape #\Escape)
            (agent-cl.render:render-inline* "a**B**z" +theme+)))

(deftest render-inline-code
  (is-equal (format nil "~c[32mx~c[0m" #\Escape #\Escape)
            (agent-cl.render:render-inline* "`x`" +theme+)))

(deftest render-inline-link
  ;; links render as "label (url)": label underlined, url shown so it is
  ;; clickable/copyable in any terminal. OSC 8 stays off by default.
  (let ((agent-cl.render:*osc8-links* nil))
    (is-equal (format nil "~c[4mlabel~c[0m (http://e.com)" #\Escape #\Escape)
              (agent-cl.render:render-inline* "[label](http://e.com)" +theme+))))

(deftest render-inline-unclosed-bold-is-literal
  ;; no closing ** -> the stray star is emitted verbatim, nothing leaks
  (is-equal "a*b" (agent-cl.render:render-inline* "a*b" +theme+)))

(deftest render-inline-empty-theme-strips-markers
  ;; NO_COLOR fallback: markers removed, text kept plain
  (is-equal "abc" (agent-cl.render:render-inline* "a**b**c" nil)))

(deftest render-inline-plain-passthrough
  (is-equal "just text" (agent-cl.render:render-inline* "just text" +theme+)))


;;;; heading decoration (pure) ------------------------------------------
(deftest render-heading-rule
  (is-equal 40 (length (agent-cl.render:heading-rule 1)))
  (is-equal 40 (length (agent-cl.render:heading-rule 2)))
  (is-equal "" (agent-cl.render:heading-rule 3))
  ;; H1 uses '=', H2 uses '-'
  (ok (every (lambda (c) (char= c #\=)) (agent-cl.render:heading-rule 1)))
  (ok (every (lambda (c) (char= c #\-)) (agent-cl.render:heading-rule 2))))

(deftest render-heading-ansi-codes
  (is-equal "1;33" (agent-cl.render:heading-ansi 1))   ; bold yellow
  (is-equal "1;36" (agent-cl.render:heading-ansi 2))   ; bold cyan
  (is-equal "1"    (agent-cl.render:heading-ansi 3))   ; bold
  (is-equal "2"    (agent-cl.render:heading-ansi 6)))  ; dim (H4+)

(deftest render-heading-rule-color
  (is-equal "33" (agent-cl.render:heading-rule-color 1))
  (is-equal "36" (agent-cl.render:heading-rule-color 2))
  (is-equal "37" (agent-cl.render:heading-rule-color 5)))


;;;; OSC 8 hyperlinks (pure) --------------------------------------------
(deftest render-osc8-wrap-basic
  (let ((agent-cl.render:*osc8-links* t))
    (is-equal (format nil "~c]8;;http://x~c\\label~c]8;;~c\\"
                      #\Escape #\Escape #\Escape #\Escape)
              (agent-cl.render:osc8-wrap "http://x" "label"))))

(deftest render-osc8-wrap-disabled
  (let ((agent-cl.render:*osc8-links* nil))
    (is-equal "label" (agent-cl.render:osc8-wrap "http://x" "label"))))

(deftest render-osc8-wrap-empty-url
  (let ((agent-cl.render:*osc8-links* t))
    (is-equal "label" (agent-cl.render:osc8-wrap "" "label"))))

(deftest render-inline-link-shows-url
  ;; url is present in the output regardless of OSC 8
  (let ((agent-cl.render:*osc8-links* nil))
    (let ((out (agent-cl.render:render-inline* "[t](http://e)" '(:link "4"))))
      (ok (search "http://e" out)))))

(deftest render-inline-link-osc8-optional
  ;; when explicitly enabled, the OSC 8 intro is emitted too
  (let ((agent-cl.render:*osc8-links* t))
    (let ((out (agent-cl.render:render-inline* "[t](http://e)" '(:link "4"))))
      (ok (search (format nil "~c]8;;http://e" #\Escape) out))
      (ok (search "http://e" out)))))


;;;; list-item classifier (pure) ----------------------------------------
(deftest render-list-bullet
  (multiple-value-bind (k ind txt) (agent-cl.render:classify-list-item "- foo")
    (is-equal :bullet k) (is-equal 0 ind) (is-equal "foo" txt))
  (multiple-value-bind (k ind txt) (agent-cl.render:classify-list-item "* bar")
    (is-equal :bullet k) (is-equal 0 ind) (is-equal "bar" txt)))

(deftest render-list-indent-preserved
  (multiple-value-bind (k ind txt) (agent-cl.render:classify-list-item "    - deep")
    (is-equal :bullet k) (is-equal 4 ind) (is-equal "deep" txt)))

(deftest render-list-ordered-keeps-number
  (multiple-value-bind (k ind txt) (agent-cl.render:classify-list-item "3. third")
    (is-equal :ordered k) (is-equal 0 ind) (is-equal "3. third" txt)))

(deftest render-list-hr-is-not-a-list
  ;; '---' must be a horizontal rule, not a bullet
  (multiple-value-bind (k _ _2) (agent-cl.render:classify-list-item "---")
    (declare (ignore _ _2)) (is-equal nil k)))

(deftest render-list-plain-text-not-a-list
  ;; "-x" (no space) is not a list item
  (multiple-value-bind (k _ _2) (agent-cl.render:classify-list-item "-x")
    (declare (ignore _ _2)) (is-equal nil k))
  (multiple-value-bind (k _ _2) (agent-cl.render:classify-list-item "just text")
    (declare (ignore _ _2)) (is-equal nil k)))


;;;; table width / parsing / alignment (pure) ---------------------------
(deftest render-display-width-ascii
  (is-equal 3 (agent-cl.render:string-display-width "abc"))
  (is-equal 0 (agent-cl.render:string-display-width "")))

(deftest render-display-width-cjk
  ;; a Han char occupies two cells
  (is-equal 2 (agent-cl.render:string-display-width "中"))
  (is-equal 4 (agent-cl.render:string-display-width "中文"))     ; 2+2
  (is-equal 5 (agent-cl.render:string-display-width "中a文"))    ; 2+1+2
  (is-equal 4 (agent-cl.render:string-display-width "日本"))     ; two wide chars
  (is-equal 3 (agent-cl.render:string-display-width "a日")))     ; 1+2

(deftest render-wide-char-p
  (ok (agent-cl.render:wide-char-p #\中))
  (ok (not (agent-cl.render:wide-char-p #\a)))
  (ok (not (agent-cl.render:wide-char-p #\Space))))

(deftest render-pad-to-width
  ;; pad by DISPLAY width, not char count
  (is-equal "ab  " (agent-cl.render:pad-to-width "ab" 4))
  ;; "中" is width 2, needs 2 more to reach 4
  (let ((r (agent-cl.render:pad-to-width "中" 4)))
    (is-equal 4 (agent-cl.render:string-display-width r))))

(deftest render-parse-table-row
  (is-equal '("a" "b" "c") (agent-cl.render:parse-table-row "| a | b | c |"))
  ;; trailing pipe optional
  (is-equal '("a" "b") (agent-cl.render:parse-table-row "| a | b"))
  ;; trims each cell
  (is-equal '("x" "y") (agent-cl.render:parse-table-row "|  x  |  y  |")))

(deftest render-separator-row-p
  (ok (agent-cl.render:separator-row-p '("---" "---" "---")))
  (ok (agent-cl.render:separator-row-p '(":--" "---:" ":--:")))
  (ok (not (agent-cl.render:separator-row-p '("a" "b")))))

(deftest render-format-table-aligns-columns
  (let ((rows (list '("名称" "用量")
                    '("read" "12")
                    '("parser.lisp" "340"))))
    (let ((lines (agent-cl.render:format-table-block rows)))
      (is-equal 3 (length lines))
      ;; every rendered line must have the SAME display width (that is alignment)
      (let ((w0 (agent-cl.render:string-display-width (first lines))))
        (ok (every (lambda (l) (= w0 (agent-cl.render:string-display-width l))) lines)
            "all rows equal display width")))))

(deftest render-format-table-drops-separator
  (let ((rows (list '("A" "B") '("---" "---") '("1" "2"))))
    (let ((lines (agent-cl.render:format-table-block rows)))
      (is-equal 2 (length lines)))))
