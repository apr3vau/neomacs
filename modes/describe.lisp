(in-package #:neomacs)

(sera:export-always
    '(inspect-object))

(define-mode describe-mode () ())

(push 'read-only-mode (hooks 'describe-mode))

(define-keys describe-mode
  "q" 'quit-buffer)

(defun read-key-sequence (prompt)
  (message "~a" prompt)
  (recursive-edit
   (constantly t) nil
   (lambda (cmd)
     (declare (ignore cmd))
     (message nil)
     (return-from read-key-sequence *this-command-keys*))))

(define-mode describe-key-mode
    (describe-mode)
  ((for-key :initform (alex:required-argument :key)
            :initarg :key)
   (for-buffer :initform (alex:required-argument :buffer)
               :initarg :buffer)))

(define-command describe-key
  :interactive
  (lambda ()
    (list (read-key-sequence "Describe the following key: ")))
  (keyseq)
  "Describe function bound to KEYSEQ in current buffer."
  (when keyseq
    (pop-to-buffer
     (make-buffer
      "*describe-key*" :mode 'describe-key-mode
      :key keyseq
      :buffer (current-buffer)
      :revert t))))

(defun lookup-keybind-trace (key buffer)
  (let (cmd trace)
    (iter (for keymap in (reverse (keymaps buffer)))
      (unless keymap (next-iteration))
      (multiple-value-bind (next bind-type)
          (keymap-find-keybind keymap key cmd)
        (when bind-type
          (push (list next (keymap-name keymap) bind-type) trace))
        (setq cmd next)))
    (values cmd trace)))

(defmethod revert-buffer-aux ((buffer describe-key-mode))
  (erase-buffer)
  (multiple-value-bind (cmd trace)
      (lookup-keybind-trace (for-key buffer)
                            (for-buffer buffer))
    (if cmd
        (progn
          (insert-nodes
           (end-pos (document-root buffer))
           (dom `(:div
                  (:code ,(key-description (for-key buffer)))
                  " is bound to "
                  ,(print-dom cmd)
                  " in "
                  ,(print-dom (for-buffer buffer)))))
          (insert-nodes
           (end-pos (document-root buffer))
           (make-element "h1" :children (list "Bindings:"))
           (dom
            (cons :div (iter (for (cmd name bind-type) in trace)
                        (ecase bind-type
                          ((:key)
                           (collect
                               `(:p
                                 "bound to "
                                 ,(print-dom cmd)
                                 " by "
                                 ,(print-dom name))))
                          ((:function)
                           (collect
                               `(:p
                                 "translated to "
                                 ,(print-dom cmd)
                                 " by "
                                 ,(print-dom name)))))))))
          (insert-nodes
           (end-pos (document-root buffer))
           (make-element "h1" :children (list "Definitions:"))
           (dom `(:table
                  (:tbody
                   ,@(iter
                       (for
                        (type def) in
                        (find-definitions
                         cmd '(:function :generic-function :method)))
                       (collect (render-xref-definition cmd type def))))))
           (make-element "h1" :children (list "Documentation:")))
          (if-let (doc (documentation cmd 'function))
            (let ((paragraphs (str:split "

"
                                         doc)))
              (iter (for p in paragraphs)
                (collect
                    (insert-nodes
                     (end-pos (document-root buffer))
                     (make-element
                      "p" :children
                      (render-doc-string-paragraph p))))))
            (insert-nodes
             (end-pos (document-root buffer))
             (make-element
              "p" :children
              (list "No docstring avaliable.")))))
        (progn
          (insert-nodes
           (end-pos (document-root buffer))
           (dom `(:div
                  (:code ,(key-description (for-key buffer)))
                  " is unbound in "
                  ,(print-dom (for-buffer buffer)))))))))

(defsheet describe-mode
    `(("p" :margin-top 0 :margin-bottom 0)
      ("h1" :margin-top 0 :margin-bottom 0
            :font-size "1.2rem")))

(define-mode inspector-mode (describe-mode lisp-mode)
  ((for-object
    :initform (alex:required-argument :object)
    :initarg :object)))

(defmethod revert-buffer-aux ((buffer inspector-mode))
  (erase-buffer)
  (let ((object (for-object buffer)) *print-pretty*)
    (multiple-value-bind (text label parts) (sb-impl::inspected-parts object)
      (unless label
        (setq parts (mapcar #'cons (alex:iota (length parts)) parts)))
      (let ((tbody (dom `(:tbody
                          ,@ (iter (for (l . v) in parts)
                               (collect `(:tr (:td :class "component-name"
                                                   ,(princ-to-string l))
                                              (:td ,(print-dom v)))))))))
        (insert-nodes
         (end-pos (document-root buffer))
         (dom `(:div ,text))
         (make-element "table" :children (list tbody)))
        (setf (pos (focus)) (pos-down tbody))))))

(defun inspect-object (object)
  (pop-to-buffer (make-buffer
                  "*inspector*" :mode 'inspector-mode
                  :object object :revert t)))

(define-command eval-expression-inspect ()
  "Evaluate a Lisp expression from minibuffer inspect the result."
  (let ((*package* (current-package)))
    (inspect-object
     (eval (read-from-minibuffer
            (format nil "Eval (~a): " (package-name *package*))
            :mode 'lisp-minibuffer-mode)))))

(define-command inspect-presentation ()
  "Inspect object presentation under focus."
  (inspect-object (presentation-at (focus))))

(defsheet inspector-mode
    `(("table" :width "100vw"
               :border-collapse "collapse")
      ("td" :padding-right "1em"
            :white-space "nowrap"
            :vertical-align "top")))
