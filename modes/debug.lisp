(in-package #:neomacs)

(define-mode debugger-mode (read-only-mode)
  ((for-condition
    :initform (alex:required-argument :condition)
    :initarg :condition)
   (restarts
    :initform (alex:required-argument :restarts)
    :initarg :restarts)
   (stack
    :initform (alex:required-argument :stack)
    :initarg :stack)))

(define-keys debugger-mode
  "a" 'debugger-invoke-abort
  "c" 'debugger-invoke-continue
  "enter" 'debugger-invoke-restart)

(defmethod revert-buffer-aux ((buffer debugger-mode))
  (erase-buffer)
  (insert-nodes
   (end-pos (document-root buffer))
   (make-element
    "p" :children
    (list (princ-to-string (for-condition buffer)))))
  (let ((tbody (make-element "tbody")))
    (insert-nodes
     (end-pos (document-root buffer))
     (make-element
      "table" :class "restart-table" :children (list tbody)))
    (iter (for r in (restarts buffer))
      (for i from 0)
      (insert-nodes
       (end-pos tbody)
       (lret ((el (make-element
                   "tr" :children
                   (list
                    (make-element
                     "td" :class "restart-name" :children
                     (list (format nil "~a. ~a" i (dissect:name r))))
                    (make-element
                     "td" :children
                     (list (dissect:report r)))))))
         (setf (attribute el 'restart) r))))
    (setf (pos (focus)) (pos-down tbody)))
  (let ((ol (make-element "ol" :start "0"))
        (*print-case* :downcase))
    (insert-nodes
     (end-pos (document-root buffer)) ol)
    (iter (for frame in (stack buffer))
      (for i from 0)
      (insert-nodes
       (end-pos ol)
       (make-element
        "li" :children
        (list (format nil "(~{~s~^ ~})"
                      (cons (dissect:call frame)
                            (dissect:args frame)))))))))

(defun find-restart-by-name (name)
  (iter (for r in (restarts (current-buffer)))
    (when (equal (symbol-name (dissect:name r)) name)
      (return r))))

(define-command debugger-invoke-abort
  :mode debugger-mode ()
  (if-let (r (find-restart-by-name "ABORT"))
    (dissect:invoke r)
    (message "No restart named abort")))

(define-command debugger-invoke-continue
  :mode debugger-mode ()
  (if-let (r (find-restart-by-name "CONTINUE"))
    (dissect:invoke r)
    (message "No restart named continue")))

(define-command debugger-invoke-restart
  :mode debugger-mode ()
  (if-let (restart
           (when-let (row (pos-up-ensure (focus) (alex:rcurry #'tag-name-p "tr")))
             (attribute row 'restart)))
    (dissect:invoke restart)
    (message "No restart under focus")))

(defun debug-for-condition (c)
  (let ((debugger
          (with-current-buffer
              (make-buffer
               "*debugger*"
               :modes '(debugger-mode)
               :condition c
               :restarts (dissect:restarts c)
               :stack (dissect:stack))
            (revert-buffer)
            (current-buffer))))
    (focus-buffer
     (display-buffer-right
      debugger))
    (unwind-protect
         (recursive-edit)
      (quit-buffer debugger))))

(defstyle debugger-mode
    `(("table" :width "100%"
               :border-collapse "collapse")
      ("td" :padding-right "1em")
      (".restart-name" :white-space "nowrap")))
