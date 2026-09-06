;;;; scripts/run-tests.lisp — load Agent-CL and run the full test suite.
;;;;
;;;; Usage (from the repo root):
;;;;   SBCL_HOME=.tools/sbcl XDG_CACHE_HOME=.tools/cache ^
;;;;     .tools/sbcl/sbcl.exe --script scripts/run-tests.lisp
(in-package #:cl-user)

(require :asdf)

;; Optional: if a Quicklisp install exists, load it so dependencies resolve on
;; standard networked machines (vendored .tools/deps is only used otherwise).
(handler-case
    (let* ((home (or (uiop:getenv "USERPROFILE") (uiop:getenv "HOME")))
           (setup (and home (merge-pathnames "quicklisp/setup.lisp"
                                  (uiop:ensure-directory-pathname home)))))
      (when (and setup (uiop:file-exists-p setup))
        (load setup)
        (format t "~&[bootstrap] quicklisp loaded from ~a~%" setup)))
  (error (e)
    (format t "~&[bootstrap] quicklisp unavailable: ~a~%" e)))


(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname *load-truename*)))

(asdf:initialize-source-registry
 `(:source-registry
   (:tree ,(uiop:subpathname *root* ".tools/deps/"))
   :ignore-inherited-configuration))
(pushnew *root* asdf:*central-registry* :test #'equal)


;; Quicklisp dist systems only become visible to ASDF after a ql:quickload,
;; so prime the four project dependencies first (runtime-resolved symbols).
(handler-case
    (let ((q (find-package "QL")))
      (when q
        (let ((quickload (find-symbol "QUICKLOAD" q)))
          (when quickload
            (funcall quickload '(:alexandria :yason :split-sequence :bordeaux-threads)
                     :silent t)
            (format t "~&[bootstrap] deps quickloaded~%")))))
  (error (e)
    (format t "~&[bootstrap] deps quickload failed: ~a~%" e)))

(asdf:load-system :agent-cl/tests)

(let ((ok (agent-cl.tests:run-all)))
  (uiop:quit (if ok 0 1)))
