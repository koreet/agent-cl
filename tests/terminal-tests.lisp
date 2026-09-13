;;;; tests/terminal-tests.lisp — pinned-footer geometry and escape sequences.
;;;;
;;;; The footer that keeps the status bar + input line at the bottom of the REPL
;;;; is built from two things that must be exactly right, so both are pinned
;;;; here: (1) the byte sequences sent to the terminal, and (2) the row
;;;; arithmetic that decides which rows scroll and which stay pinned. Everything
;;;; tested is pure — no terminal, no ANSI-dependent assertions on the host.
(in-package #:agent-cl.tests)

;;;; CSI constructor ---------------------------------------------------
(deftest terminal-csi-forms
  (is-equal (format nil "~c[2K" #\Escape) (agent-cl.render:csi 2 #\K))
  (is-equal (format nil "~c[1;22r" #\Escape) (agent-cl.render:csi '(1 22) #\r))
  (is-equal (format nil "~c[r" #\Escape) (agent-cl.render:csi nil #\r))
  (is-equal (format nil "~c[?25h" #\Escape) (agent-cl.render:csi "?25" #\h)))

;;;; the four sequences the footer actually relies on ------------------
(deftest terminal-scroll-region-sequences
  ;; DECSTBM pinning rows 1..22 of a 24-row screen
  (is-equal (format nil "~c[1;22r" #\Escape)
            (agent-cl.render:set-scroll-region 1 22))
  ;; no-parameter DECSTBM restores full-screen scrolling on teardown
  (is-equal (format nil "~c[r" #\Escape)
            (agent-cl.render:reset-scroll-region)))

(deftest terminal-cursor-and-erase-sequences
  (is-equal (format nil "~c[24;1H" #\Escape) (agent-cl.render:cursor-to 24 1))
  (is-equal (format nil "~c[2K" #\Escape) (agent-cl.render:erase-line))
  (is-equal (format nil "~c7" #\Escape) (agent-cl.render:save-cursor))
  (is-equal (format nil "~c8" #\Escape) (agent-cl.render:restore-cursor)))

;;;; ANSI stripping (needed to measure display width, not to print) ----
(deftest terminal-strip-ansi
  (is-equal "hi!" (agent-cl.render:strip-ansi
                  (format nil "~c[36mhi~c[0m!" #\Escape #\Escape)))
  (is-equal "plain" (agent-cl.render:strip-ansi "plain"))
  (is-equal "" (agent-cl.render:strip-ansi ""))
  ;; a two-character escape (save cursor) disappears too
  (is-equal "ab" (agent-cl.render:strip-ansi (format nil "a~c7b" #\Escape)))
  ;; a bare trailing ESC must not blow up
  (is-equal "" (agent-cl.render:strip-ansi (format nil "~c" #\Escape))))

;;;; footer geometry ---------------------------------------------------
(deftest terminal-footer-layout-reserves-bottom-two-rows
  (let ((l (agent-cl.render:footer-layout 24)))
    ;; a 24-row screen: rows 1..22 scroll, row 23 = status, row 24 = input
    (is-equal 1 (getf l :scroll-top))
    (is-equal 22 (getf l :scroll-bottom))
    (is-equal 23 (getf l :status-row))
    (is-equal 24 (getf l :input-row))))

(deftest terminal-footer-layout-honours-height
  (let ((l (agent-cl.render:footer-layout 30 :footer-height 3)))
    (is-equal 27 (getf l :scroll-bottom))
    (is-equal 28 (getf l :status-row))
    (is-equal 30 (getf l :input-row))))

(deftest terminal-footer-layout-refuses-tiny-screens
  ;; no room to both scroll and pin -> honesty (NIL) beats a silly footer
  (is-equal nil (agent-cl.render:footer-layout 4))
  (is-equal nil (agent-cl.render:footer-layout 1))
  (is-equal nil (agent-cl.render:footer-layout nil)))

;;;; width handling ----------------------------------------------------
(deftest terminal-fit-to-width-ascii
  (multiple-value-bind (s w) (agent-cl.render:fit-to-width "hello" 3)
    (is-equal "hel" s) (is-equal 3 w))
  (multiple-value-bind (s w) (agent-cl.render:fit-to-width "hi" 10)
    (is-equal "hi" s) (is-equal 2 w)))

(deftest terminal-fit-to-width-counts-cells-not-chars
  ;; regression: W must accumulate DISPLAY CELLS. Counting characters made a
  ;; two-column glyph cost one, so a 3-column budget wrongly kept both of them.
  (multiple-value-bind (s w) (agent-cl.render:fit-to-width "中文" 3)
    (is-equal "中" s) (is-equal 2 w))
  (multiple-value-bind (s w) (agent-cl.render:fit-to-width "中文" 4)
    (is-equal "中文" s) (is-equal 4 w))
  ;; mixed widths: ascii (1 cell) packs twice as densely as CJK (2 cells)
  (multiple-value-bind (s w) (agent-cl.render:fit-to-width "ab中文" 4)
    (is-equal "ab中" s) (is-equal 4 w)))

(deftest terminal-pad-ansi-line-pads
  (is-equal "abc   " (agent-cl.render:pad-ansi-line "abc" 6))
  ;; already exact width -> untouched
  (is-equal "abcd" (agent-cl.render:pad-ansi-line "abcd" 4))
  ;; empty line -> a full row of spaces (footer rows must be opaque)
  (is-equal "    " (agent-cl.render:pad-ansi-line "" 4)))

(deftest terminal-pad-ansi-line-keeps-colour-when-it-fits
  (let* ((coloured (format nil "~c[36mabc~c[0m" #\Escape #\Escape))
         (padded (agent-cl.render:pad-ansi-line coloured 6)))
    ;; colour survives...
    (ok (search (format nil "~c[36m" #\Escape) padded))
    ;; ...and the row still occupies exactly 6 display cells
    (is-equal 6 (agent-cl.render:string-display-width
                 (agent-cl.render:strip-ansi padded)))))

(deftest terminal-pad-ansi-line-falls-back-to-plain-when-truncating
  ;; truncating coloured text must drop the escapes, never emit half a sequence
  (let* ((coloured (format nil "~c[36mabcdef~c[0m" #\Escape #\Escape))
         (padded (agent-cl.render:pad-ansi-line coloured 3)))
    (is-equal "abc" padded)
    ;; a dangling ESC would colourise everything printed after it
    (is-equal nil (find #\Escape padded))))

;;;; capability probe must fail soft on any host ----------------------
(deftest terminal-probe-console-never-throws
  ;; The test runner's stdout is usually redirected (no console) -> NIL. Either
  ;; way the probe must not signal, and any answer it does give must be sane.
  (let ((info (agent-cl.render:probe-console)))
    (when info
      (ok (integerp (getf info :cols)) "cols is an integer")
      (ok (integerp (getf info :rows)) "rows is an integer")
      (ok (plusp (getf info :cols)) "cols is positive")
      (ok (plusp (getf info :rows)) "rows is positive"))))
