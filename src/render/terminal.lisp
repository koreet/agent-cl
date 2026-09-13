;;;; src/render/terminal.lisp — pinned bottom footer for a console REPL.
;;;;
;;;; Why this exists:
;;;;   The REPL wants its status bar (model | tokens | cwd) and its input line to
;;;;   stay *pinned* at the bottom of the terminal while ordinary output scrolls
;;;;   above them. The portable way to do that is a DECSTBM scroll region:
;;;;   reserve the bottom N rows as a footer, restrict scrolling to the rows
;;;;   above it, and let every print() fall inside the region.
;;;;
;;;;   The layout/escape logic below is *pure* (strings in, strings out), so the
;;;;   exact byte sequences and the row arithmetic are unit-testable without a
;;;;   terminal. Querying the console size is the one impure part; it is isolated
;;;;   in PROBE-CONSOLE and fails soft (NIL = "no pinned footer") on any platform
;;;;   or redirection where it cannot answer.
;;;;
;;;; Deliberate scope: this file only *describes* the footer and emits the
;;;; escapes. It never reads input and never decides policy — the REPL does.

(in-package #:agent-cl.render)

;;; ---------------------------------------------------------------------------
;;; escape-sequence constructors (pure)
;;; ---------------------------------------------------------------------------

(defun csi (params final)
  "A Control Sequence Introducer: ESC [ PARAMS FINAL. PARAMS is an integer, a
  list of them, or NIL for none. Pure."
  (with-output-to-string (o)
    (write-char #\Escape o)
    (write-char #\[ o)
    (when params
      (write-string (if (listp params)
                        (format nil "~{~a~^;~}" params)
                        (princ-to-string params))
                    o))
    (write-char final o)))

(defun set-scroll-region (top bottom)
  "DECSTBM: restrict scrolling to rows TOP..BOTTOM (1-based, inclusive).
  Rows outside the region are untouched by newline scrolling — that is what
  keeps a pinned footer pinned. Pure."
  (csi (list top bottom) #\r))

(defun reset-scroll-region ()
  "DECSTBM with no parameters: restore scrolling to the whole screen. Pure."
  (csi nil #\r))

(defun cursor-to (row col)
  "CUP: absolute cursor position (1-based). Pure."
  (csi (list row col) #\H))

(defun erase-line ()
  "EL(2): clear the entire current line. Pure."
  (csi 2 #\K))

(defun save-cursor () (format nil "~c7" #\Escape))
(defun restore-cursor () (format nil "~c8" #\Escape))

;;; ---------------------------------------------------------------------------
;;; display-width helpers (pure) — ANSI-aware, CJK-aware
;;; ---------------------------------------------------------------------------

(defun strip-ansi (s)
  "Remove ANSI/VT escape sequences from S so its *display* width can be measured.
  Handles CSI (ESC [ ... final-byte) and two-character escapes (e.g. ESC 7).
  Pure; SBCL's own printer never needs this, only width accounting does."
  (with-output-to-string (o)
    (loop with i = 0 with n = (length s)
          while (< i n)
          for ch = (char s i)
          do (cond
               ((char= ch #\Escape)
                (incf i)
                (when (< i n)
                  (if (char= (char s i) #\[)
                      (progn
                        (incf i)
                        ;; parameter bytes, then one final byte ending the CSI
                        (loop while (and (< i n)
                                         (let ((c (char s i)))
                                           (or (digit-char-p c)
                                               (member c '(#\; #\? #\> #\= #\Space)))))
                              do (incf i))
                        (when (< i n) (incf i)))
                      (incf i))))          ; two-char escape: skip the second byte
               (t (write-char ch o) (incf i))))))

(defun fit-to-width (s cols)
  "Return (values prefix width) where PREFIX is the longest leading slice of the
  PLAIN string S whose display width is <= COLS. Wide (CJK) chars count as 2, so
  a truncation never splits a full-width glyph. Pure."
  (let ((out (make-string-output-stream))
        (w 0))
    (loop for ch across s
          for cw = (if (wide-char-p ch) 2 1)
          do (if (<= (+ w cw) cols)
                 (progn (write-char ch out) (incf w cw))   ; accumulate CELLS, not chars
                 (return)))
    (values (get-output-stream-string out) w)))

(defun pad-ansi-line (s cols)
  "Fit S to exactly COLS display columns for a full-width footer row.
  Colour is preserved when S already fits; when it must be truncated the plain
  text is used (a partial escape sequence would corrupt the terminal). Pure."
  (let* ((plain (strip-ansi s))
         (w (string-display-width plain)))
    (if (> w cols)
        (nth-value 0 (fit-to-width plain cols))
        (concatenate 'string s
                     (make-string (- cols w) :initial-element #\Space)))))

;;; ---------------------------------------------------------------------------
;;; footer geometry (pure)
;;; ---------------------------------------------------------------------------

(defparameter *footer-height* 2
  "Rows reserved at the bottom: one status row plus one input row.")

(defun footer-layout (rows &key (footer-height *footer-height*))
  "Geometry for a bottom-pinned footer on a terminal ROWS high, or NIL when the
  screen is too short to both scroll and pin (a silly footer is worse than none).
  Returns a plist:
    :scroll-top     first row of the scrolling output region (always 1, so
                    content still leaves into the terminal's scrollback)
    :scroll-bottom  last row of that region
    :status-row     row the status bar is drawn on (just above the input)
    :input-row      bottom row, where the prompt and typed text live
  Pure: no terminal access."
  (when (and (integerp rows) (>= rows (+ footer-height 3)))
    (let ((scroll-bottom (- rows footer-height)))
      (list :scroll-top 1
            :scroll-bottom scroll-bottom
            :status-row (1+ scroll-bottom)
            :input-row rows))))

;;; ---------------------------------------------------------------------------
;;; console capability probe (impure, fails soft)
;;; ---------------------------------------------------------------------------

#+win32
(progn
  (sb-alien:load-shared-object "kernel32.dll")
  (sb-alien:define-alien-type %coord (sb-alien:struct %coord
    (x (sb-alien:signed 16)) (y (sb-alien:signed 16))))
  (sb-alien:define-alien-type %small-rect (sb-alien:struct %small-rect
    (left (sb-alien:signed 16)) (top (sb-alien:signed 16))
    (right (sb-alien:signed 16)) (bottom (sb-alien:signed 16))))
  (sb-alien:define-alien-type %csbi (sb-alien:struct %csbi
    (size (sb-alien:struct %coord))
    (cursor (sb-alien:struct %coord))
    (attributes (sb-alien:unsigned 16))
    (window (sb-alien:struct %small-rect))
    (maxwindow (sb-alien:struct %coord))))
  (sb-alien:define-alien-routine ("GetStdHandle" %get-std-handle) (sb-alien:unsigned 64)
    (which (sb-alien:signed 32)))
  (sb-alien:define-alien-routine ("GetConsoleScreenBufferInfo" %get-csbi)
      (sb-alien:signed 32)
    (handle (sb-alien:unsigned 64)) (info (* (sb-alien:struct %csbi))))
  (sb-alien:define-alien-routine ("GetConsoleMode" %get-console-mode)
      (sb-alien:signed 32)
    (handle (sb-alien:unsigned 64)) (mode (* (sb-alien:unsigned 32))))
  (sb-alien:define-alien-routine ("SetConsoleMode" %set-console-mode)
      (sb-alien:signed 32)
    (handle (sb-alien:unsigned 64)) (mode (sb-alien:unsigned 32))))

(defconstant +enable-virtual-terminal-processing+ #x4
  "ENABLE_VIRTUAL_TERMINAL_PROCESSING — required before a Windows console
  interprets the ANSI escapes this file emits.")

#+win32
(defun %invalid-handle-p (h)
  (or (eql h #xFFFFFFFFFFFFFFFF) (eql h #xFFFFFFFF) (zerop h)))

#+win32
(defun %console-size (handle)
  "Return (values cols rows) for HANDLE, or NIL when it is not a console."
  (let ((info (sb-alien:make-alien (sb-alien:struct %csbi))))
    (unwind-protect
         (when (not (eql 0 (%get-csbi handle info)))
           (let* ((win (sb-alien:slot info 'window))
                  (l (sb-alien:slot win 'left)) (t2 (sb-alien:slot win 'top))
                  (r (sb-alien:slot win 'right)) (b (sb-alien:slot win 'bottom)))
             (values (1+ (- r l)) (1+ (- b t2)))))
      (sb-alien:free-alien info))))

#+win32
(defun console-vt-enabled-p (handle)
  "True when HANDLE is a console with virtual-terminal (ANSI) processing on."
  (let ((m (sb-alien:make-alien (sb-alien:unsigned 32))))
    (unwind-protect
         (and (not (eql 0 (%get-console-mode handle m)))
              (logtest (sb-alien:deref m) +enable-virtual-terminal-processing+))
      (sb-alien:free-alien m))))

#+win32
(defun console-enable-vt (handle)
  "Turn on virtual-terminal processing for HANDLE when it is missing.
  Returns T when ANSI output is (now) usable on that console, else NIL."
  (let ((m (sb-alien:make-alien (sb-alien:unsigned 32))))
    (unwind-protect
         (cond
           ((eql 0 (%get-console-mode handle m)) nil)
           ((logtest (sb-alien:deref m) +enable-virtual-terminal-processing+) t)
           (t (not (eql 0 (%set-console-mode
                           handle
                           (logior (sb-alien:deref m)
                                   +enable-virtual-terminal-processing+))))))
      (sb-alien:free-alien m))))

(defun probe-console ()
  "Best-effort description of the console *standard-output* is attached to:
    (:cols C :rows R :vt BOOLEAN :handle H)
  or NIL when there is no console, the output is redirected, or the platform API
  is unavailable. This is the single impure entry point of the module; every
  caller treats NIL as 'do not pin a footer'."
  #+win32
  (handler-case
      (let ((h (%get-std-handle -11)))          ; STD_OUTPUT_HANDLE
        (when (and h (not (%invalid-handle-p h)))
          (multiple-value-bind (cols rows) (%console-size h)
            (when (and cols rows)
              (list :cols cols :rows rows
                    :vt (console-vt-enabled-p h)
                    :handle h)))))
    (error () nil))
  #-win32
  (let ((cols (uiop:getenv "COLUMNS"))
        (rows (uiop:getenv "LINES")))
    (when (and cols rows)
      (let ((c (parse-integer cols :junk-allowed t))
            (r (parse-integer rows :junk-allowed t)))
        (when (and c r (plusp c) (plusp r))
          (list :cols c :rows r :vt t :handle nil))))))
