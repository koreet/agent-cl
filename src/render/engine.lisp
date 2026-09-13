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

;;; ---------------------------------------------------------------------------
;;; heading classifier (pure)
;;; ---------------------------------------------------------------------------
;;; Why: the line classifier only tells callers :normal / :code / :blank. Heading
;;; depth (#.. ######) is a purely syntactic property of a line, so it belongs in
;;; this pure core too — callers get (values level text) and decide the colour.
;;; level = 0 when the line is not a heading; 1..6 for "# " .. "###### ".
;;; A '#' that is not followed by space (e.g. "#tag") is NOT a heading.

(defun classify-heading (line)
  "Return (values LEVEL TEXT) for a markdown ATX heading LINE, else (values 0 LINE).
  LEVEL counts leading '#' chars (1..6); requires a following space or EOL.
  Pure; no IO, no global state."
  (let* ((trim (string-trim '(#\Space #\Tab #\Return) line))
         (n (length trim)))
    (if (or (zerop n) (char/= (char trim 0) #\#))
        (values 0 line)
        ;; count leading '#' up to 6; a 7th '#' belongs to the heading text
        (let ((hashes 0))
          (loop while (and (< hashes 6) (< hashes n)
                           (char= (char trim hashes) #\#))
                do (incf hashes))
          (cond
            ((= hashes n) (values hashes ""))
            ((char= (char trim hashes) #\Space)
             (values hashes (string-left-trim '(#\Space)
                                              (subseq trim hashes))))
            ((and (= hashes 6) (char= (char trim hashes) #\#))
             ;; "####### x": exactly six count, the 7th is part of the text
             (values 6 (subseq trim 6)))
            (t (values 0 line)))))))

;;; ---------------------------------------------------------------------------
;;; inline span renderer (pure): markdown inline -> string, with a theme plist
;;; ---------------------------------------------------------------------------
;;; Why: repl.lisp had an ad-hoc render-inline with a global *color* switch and
;;; two latent bugs: "**bold**" toggled a flag that could leak, and single '*'
;;; (italic / bullet) was conflated with the bold pair. Here the ANSI codes are
;;; passed in explicitly (a plist of role->code) so the function is a pure
;;; string->string map testable with codes like (:bold "1" :code "32"), and with
;;; an empty theme it degrades to "strip markers" (plain text), which is exactly
;;; the NO_COLOR fallback.

(defun %ansi (code text)
  (if (or (null code) (string= code ""))
      text
      (format nil "~c[~am~a~c[0m" #\Escape code text #\Escape)))

(defparameter *osc8-links* nil
  "When true, render-inline* wraps links in an OSC 8 hyperlink sequence. Default
  OFF: in practice terminals vary and several do not react, so we instead show
  the URL inline (see the link branch) which works everywhere and is copyable.")

(defun osc8-wrap (url text)
  "Wrap TEXT as a clickable OSC 8 hyperlink to URL. Pure string->string.
  Sequence: ESC ] 8 ; ; URL ESC \\ TEXT ESC ] 8 ; ; ESC \\"
  (if (or (null *osc8-links*) (null url) (string= url ""))
      text
      (format nil "~c]8;;~a~c\\~a~c]8;;~c\\"
              #\Escape url #\Escape text #\Escape #\Escape)))

(defun render-inline* (text theme)
  "Render markdown inline spans in TEXT using THEME (plist :bold/:code/:link
  each an ANSI code string, or NIL to strip markers). Pure: string + plist ->
  string. Recognises **bold**, `code`, [label](url); everything else verbatim.
  Unclosed ** / ` / [ are emitted literally (no state leaks past the call)."
  (let* ((bold (getf theme :bold))
         (code (getf theme :code))
         (out (make-string-output-stream))
         (i 0) (n (length text)))
    (labels ((c (k) (if (< k n) (char text k) nil)))
      (loop while (< i n) do
        (let ((ch (char text i)))
          (cond
            ((and (char= ch #\*) (char= (or (c (1+ i)) #\Nul) #\*))
             (let ((end (search "**" text :start2 (+ i 2))))
               (if end
                   (progn (write-string (%ansi bold (subseq text (+ i 2) end)) out)
                          (setf i (+ end 2)))
                   (progn (write-char #\* out) (incf i)))))
            ((char= ch #\`)
             (let ((end (position #\` text :start (1+ i))))
               (if end
                   (progn (write-string (%ansi code (subseq text (1+ i) end)) out)
                          (setf i (1+ end)))
                   (progn (write-char #\` out) (incf i)))))
            ((char= ch #\[)
             (let ((close (position #\] text :start (1+ i))))
               (if (and close (< (1+ close) n) (char= (char text (1+ close)) #\())
                   (let ((url-end (position #\) text :start (+ close 2))))
                     (if url-end
                         (let ((label (subseq text (1+ i) close))
                               (url   (subseq text (+ close 2) url-end)))
                           ;; show "label (url)": the URL is always visible so it
                           ;; is clickable/copyable in ANY terminal. If the theme
                           ;; explicitly enables OSC 8, also wrap the label.
                           (write-string
                            (let ((lab (%ansi (getf theme :link) label)))
                              (if (and *osc8-links* url (plusp (length url)))
                                  (osc8-wrap url lab)
                                  lab))
                            out)
                           (when (and url (plusp (length url)))
                             (format out " (~a)" url))
                           (setf i (1+ url-end)))
                         (progn (write-char #\[ out) (incf i))))
                   (progn (write-char #\[ out) (incf i)))))
            (t (write-char ch out) (incf i))))))
    (get-output-stream-string out)))

;;; ---------------------------------------------------------------------------
;;; heading decoration (pure)
;;; ---------------------------------------------------------------------------
;;; Terminals have no font size, so heading level is conveyed by SGR code and a
;;; fixed-width underline (H1 heavy, H2 light). Kept here (pure, testable) so
;;; repl.lisp only does the printing.

(defparameter *heading-rule-width* 40
  "Fixed width (chars) of heading underlines. Fixed — not terminal-derived — so
  rendering stays deterministic and unit-testable across terminals.")

(defun heading-rule (level)
  "The decorative underline string for heading LEVEL (H1 heavy, H2 light, else
  empty). Pure: no ANSI, no IO."
  (cond ((= level 1) (make-string *heading-rule-width* :initial-element #\=))
        ((= level 2) (make-string *heading-rule-width* :initial-element #\-))
        (t "")))

(defun heading-ansi (level)
  "Combined SGR code for heading LEVEL: H1 bold+yellow, H2 bold+cyan, H3 bold,
  H4+ dim. Pure."
  (case level
    (1 "1;33")
    (2 "1;36")
    (3 "1")
    (t "2")))

(defun heading-rule-color (level)
  "SGR colour code for a heading LEVEL's underline/text, or NIL. Pure."
  (case level
    (1 "33")
    (2 "36")
    (t "37")))

;;; ---------------------------------------------------------------------------
;;; list-item classifier (pure)
;;; ---------------------------------------------------------------------------
;;; Why: repl previously treated ANY line starting with -/*/+ as a "list item"
;;; and printed it verbatim, which (a) showed a raw "- " marker and (b) also
;;; mis-classified horizontal rules (---) and stray "-" prose. Here we require
;;; the marker be followed by a space, separate bullets from ordered items, and
;;; report the leading indent so nesting can be preserved. Pure.

(defun classify-list-item (line)
  "Classify a markdown list LINE.
  Returns (values KIND INDENT TEXT):
    KIND   = nil (not a list) | :bullet | :ordered
    INDENT = number of leading spaces/tabs (nesting depth proxy)
    TEXT   = the item's content with the marker removed.
  Bullets: '- ' '* ' '+ '. Ordered: '<digits>. ' . A lone '---' is NOT a list
  item (that is a horizontal rule) — it returns KIND nil."
  (let* ((indent 0)
         (n (length line)))
    ;; measure leading whitespace (tabs count as one column here)
    (loop while (and (< indent n)
                     (member (char line indent) '(#\Space #\Tab)))
          do (incf indent))
    (let* ((rest (subseq line indent))
           (rn (length rest)))
      (cond
        ;; need at least "x " (marker + space)
        ((< rn 2) (values nil indent line))
        ;; bullet: -/*/+ followed by space
        ((and (member (char rest 0) '(#\- #\* #\+))
              (char= (char rest 1) #\Space))
         (values :bullet indent (subseq rest 2)))
        ;; ordered: digits then ". " — keep the whole "N. body" as TEXT so the
        ;; number is preserved verbatim (callers render it as-is).
        ((digit-char-p (char rest 0))
         (let ((dot (position #\. rest)))
           (if (and dot (< (1+ dot) rn) (char= (char rest (1+ dot)) #\Space)
                    (every #'digit-char-p (subseq rest 0 dot)))
               (values :ordered indent rest)
               (values nil indent line))))
        (t (values nil indent line))))))

;;; ---------------------------------------------------------------------------
;;; table support (pure): display width, row parsing, aligned formatting
;;; ---------------------------------------------------------------------------
;;; Why: the old renderer only detected "this line has >=2 pipes" and coloured
;;; it whole. Real alignment needs column widths, and aligning CJK text needs a
;;; DISPLAY width (a Han char occupies 2 terminal cells, not 1), which we must
;;; compute ourselves. All three helpers below are pure and unit-tested; the
;;; repl buffers a table block and calls FORMAT-TABLE-BLOCK once.

(defun wide-char-p (ch)
  "True when CH occupies two terminal cells (CJK / fullwidth ranges). A small,
  pragmatic subset: CJK unified, kana, fullwidth forms, CJK punctuation."
  (let ((c (char-code ch)))
    (or (<= #x1100 c #x115F)    ; Hangul Jamo
        (<= #x2E80 c #x303E)    ; CJK radicals / Kangxi / CJK punctuation
        (<= #x3041 c #x33FF)    ; Hiragana / Katakana / CJK compat
        (<= #x3400 c #x4DBF)    ; CJK ext A
        (<= #x4E00 c #x9FFF)    ; CJK unified
        (<= #xA000 c #xA4CF)    ; Yi
        (<= #xAC00 c #xD7A3)    ; Hangul syllables
        (<= #xF900 c #xFAFF)    ; CJK compat ideographs
        (<= #xFF00 c #xFF60)    ; Fullwidth forms
        (<= #xFFE0 c #xFFE6)))) ; Fullwidth signs

(defun string-display-width (s)
  "Terminal cell width of S: wide chars count 2, others 1. Pure."
  (loop for ch across s sum (if (wide-char-p ch) 2 1)))

(defun pad-to-width (s width)
  "Right-pad S with spaces so its DISPLAY width reaches WIDTH (never truncates)."
  (let ((w (string-display-width s)))
    (concatenate 'string s (make-string (max 0 (- width w)) :initial-element #\Space))))

(defun parse-table-row (line)
  "Split a markdown table LINE into a list of cell strings (trimmed).
  Leading/trailing pipes are optional; '| a | b |' -> (\"a\" \"b\"). Pure."
  (let* ((trim (string-trim '(#\Space #\Tab #\Return) line))
         (n (length trim)))
    ;; drop one leading and one trailing pipe if present
    (let* ((body (if (and (plusp n) (char= (char trim 0) #\|))
                     (subseq trim 1) trim))
           (bn (length body))
           (body (if (and (plusp bn) (char= (char body (1- bn)) #\|))
                     (subseq body 0 (1- bn)) body)))
      (mapcar (lambda (c) (string-trim '(#\Space #\Tab) c))
              (loop with out = '() with start = 0
                    for bar = (position #\| body :start start)
                    do (if bar
                           (progn (push (subseq body start bar) out)
                                  (setf start (1+ bar)))
                           (progn (push (subseq body start) out)
                                  (return (nreverse out)))))))))

(defun separator-row-p (cells)
  "True when CELLS look like a markdown alignment row: every cell is dashes
  (optionally ':---:', '---', etc.)."
  (and cells
       (every (lambda (c)
                (let ((c (string-trim '(#\: #\Space) c)))
                  (and (plusp (length c))
                       (every (lambda (ch) (char= ch #\-)) c))))
              cells)))

(defun format-table-block (rows &key (head-p t) (bar "|" ))
  "Format ROWS (list of cell-lists) as an aligned table. Column widths are the
  max DISPLAY width per column; cells are left-aligned and space-padded. If
  HEAD-P, the first row is the header (caller may bold it). A markdown
  separator row (---) is dropped. Returns a list of formatted lines. Pure."
  (let* ((rows (remove-if #'separator-row-p rows))
         (ncol (loop for r in rows maximize (length r)))
         (widths (make-list ncol :initial-element 0)))
    ;; column widths
    (dolist (r rows)
      (loop for cell in r for i from 0
            do (setf (nth i widths)
                     (max (nth i widths) (string-display-width cell)))))
    ;; render each row: bar SPACE cell SPACE bar SPACE ...
    (loop for r in rows
          for ri from 0
          collect
          (with-output-to-string (o)
            (write-string bar o)
            (loop for i from 0 below ncol
                  do (write-char #\Space o)
                     (write-string (pad-to-width (or (nth i r) "") (nth i widths)) o)
                     (write-char #\Space o)
                     (write-string bar o)))
          into out
          finally (return out))))
