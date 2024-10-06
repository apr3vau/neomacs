(in-package :neomacs)

;;; Syntax table

(defun get-syntax-table (char table)
  (gethash char table))

(defun (setf get-syntax-table) (new-val char table)
  (setf (gethash char table) new-val))

(defun set-syntax-range (table beg end syntax-class)
  (setq beg (if (characterp beg) (char-code beg) beg))
  (setq end (if (characterp end) (char-code end) end))
  (iter (for i from beg to end)
    (setf (gethash (code-char i) table)
          syntax-class)))

(defun make-syntax-table (&rest bindings)
  (lret ((table (make-hash-table)))
    (iter (for (k v) on bindings by #'cddr)
      (setf (get-syntax-table k table) v))))

(defvar *syntax-table* nil)

;;; Read to DOM

(defun read-dom (stream &optional recursive-p)
  (if recursive-p (read-dispatch *syntax-table* stream)
      (call-with-dom-output
       (lambda () (read-dispatch *syntax-table* stream)))))

(defun read-dispatch (table stream)
  (let* ((c (peek-char nil stream))
         (syntax-class (get-syntax-table c table)))
    (etypecase syntax-class
      (function
       (funcall syntax-class stream (read-char stream)))
      (hash-table
       (read-char stream)
       (read-dispatch syntax-class stream))
      (null
       (if-let (default (get-syntax-table t table))
         (funcall default stream c)
         (error "Invalid character ~a." c)))
      (symbol
       (if (fboundp syntax-class)
           (funcall syntax-class stream (read-char stream))
           (read-constituent
            stream syntax-class
            (or (get syntax-class 'read-filter)
                (lambda (result)
                  (append-child
                   *dom-output*
                   (make-atom-node
                    (string-downcase (symbol-name syntax-class))
                    result))))))))))

(defun read-from-file (file)
  (with-open-file (s file :direction :input)
    (call-with-dom-output
     (lambda ()
       (handler-case
           (loop (read-dom s t))
         (end-of-file ()))))))

(defun append-text (parent string)
  (if (text-node-p (last-child parent))
      (setf (text (last-child parent))
            (append (text (last-child parent)) string))
      (append-child parent (make-instance 'text-node :text string))))

(defnclo read-delimited (delimiter) (stream c)
  (declare (ignore c))
  (append-child
   *dom-output*
   (lret ((*dom-output* (make-list-node nil)))
     (iter (for c = (peek-char nil stream))
       (until (when (eql c delimiter)
                (read-char stream)
                t))
       (read-dom stream t)))))

(defun read-constituent (stream syntax-class filter)
  (iter (for c = (read-char stream nil nil t))
    (when (eql (get-syntax-table c *syntax-table*) 'single-escape)
      (collect c result-type string into result)
      (collect (read-char stream nil nil t) result-type string into result)
      (setq c (read-char stream nil nil t)))
    (while c)
    (until
     (unless (eql (get-syntax-table c *syntax-table*) syntax-class)
       (unread-char c stream)
       t))
    (collect c result-type string into result)
    (finally
     (funcall filter result))))

(defun whitespace-filter (result)
  (let ((line-count (count #\Newline result)))
    (if (plusp line-count)
        (dotimes (_ line-count)
          (append-child *dom-output* (make-new-line-node)))
        (append-text *dom-output* " "))))

(defun read-string (stream c)
  (declare (ignore c))
  (append-child
   *dom-output*
   (make-atom-node
    "string"
    (iter (for c = (read-char stream))
      (until (eql c #\"))
      (if (eql c #\\)
          (collect (read-char stream) result-type string)
          (collect c result-type string))))))

(defun read-line-comment (stream c)
  (declare (ignore c))
  (let ((n 1))
    (iter (for c = (peek-char t stream nil nil t))
      (while (eql c #\;))
      (incf n)
      (read-char stream))
    (bind (((:values line eof-p) (read-line stream))
           (node (make-atom-node "comment" line)))
      (setf (attribute node "comment-level") (prin1-to-string n))
      (append-child *dom-output* node)
      (unless eof-p (unread-char #\Newline stream)))))

(let ((table (make-syntax-table)))
  (set-syntax-range table 33 127 'symbol)
  (setf (get-syntax-table #\( table) (make-read-delimited #\)))
  (setf (get-syntax-table #\) table) nil)
  (setf (get-syntax-table #\  table) 'whitespace)
  (setf (get-syntax-table #\Newline table) 'whitespace)
  (setf (get-syntax-table #\Tab table) 'whitespace)
  (setf (get-syntax-table #\" table) 'read-string)
  (setf (get-syntax-table #\\ table) 'single-escape)
  (setf (get-syntax-table #\; table) 'read-line-comment)
  (setq *syntax-table* table))

(setf (get 'whitespace 'read-filter) 'whitespace-filter)

;;; Pretty printer

(defun symbol-indentation (symbol)
  (case symbol
    ((lambda) 1)
    ((block catch return-from throw eval-when
            multiple-value-call multiple-value-prog1
            unwind-protect)
     1)
    ((locally progn) 0)
    ((progv) 1)
    ((flet labels macrolet)
     '((&whole 4 &rest (&whole 1 4 4 &rest 2)) &rest 2))
    ((let let* symbol-macrolet dx-let)
     '((&whole 4 &rest (&whole 1 1 2)) &rest 2))
    ((case ccase ecase)
     '(4 &rest (&whole 2 &rest 1)))
    ((handler-case handler-bind) 1)
    (t (when-let (mf (macro-function symbol))
         (or (sb-pretty::macro-indentation mf)
             (when (sera:string-prefix-p "DEF" (symbol-name symbol))
               1))))))

(defun normalize-indent-spec (indent-spec)
  (when indent-spec
    (when (numberp indent-spec)
      (setq indent-spec
            (nconc (make-list indent-spec :initial-element 4)
                   (list '&rest 2))))
    (push nil indent-spec)
    indent-spec))

(defun pprint-form (list-node stream indent-spec)
  (pprint-logical-block (stream nil :prefix "(" :suffix ")")
    (if indent-spec
        (iter
          (for c in (child-nodes list-node))
          (if (sexp-node-p c)
              (let* ((this-indent-spec
                       (if (eql (car indent-spec) '&rest)
                           (cadr indent-spec)
                           (pop indent-spec)))
                     (next-indent-spec
                       (if (eql (car indent-spec) '&rest)
                           (cadr indent-spec)
                           (car indent-spec)))
                     (indent-number
                       (or (when (numberp next-indent-spec)
                             next-indent-spec)
                           (getf next-indent-spec '&whole)
                           1)))
                (pprint-indent :block (1- indent-number) stream)
                (if (and (listp this-indent-spec) (list-node-p c))
                    (progn
                      (setq this-indent-spec (copy-tree this-indent-spec))
                      (remf this-indent-spec '&whole)
                      (pprint-form c stream this-indent-spec))
                    (write c :stream stream)))
              (write c :stream stream)))
        ;; Print function call form
        (iter
          (with i = 0)
          (for c in (child-nodes list-node))
          (when (and (sexp-node-p c) (<= i 1))
            (pprint-indent :current 0 stream))
          (write c :stream stream)
          (when (sexp-node-p c)
            (incf i))))))

(defvar *lisp-pprint-dispatch*
  (lret ((*print-pprint-dispatch*
          (copy-pprint-dispatch *print-pprint-dispatch*)))
    (set-pprint-dispatch
     'element
     (lambda (stream self &rest noise)
       (declare (ignore noise))
       (cond ((list-node-p self)
              (pprint-form self stream
                           (normalize-indent-spec
                            (symbol-indentation
                             (compute-symbol (first-child self))))))
             ((new-line-node-p self)
              (pprint-newline :mandatory stream))
             ((symbol-node-p self)
              (write-string (atom-node-text self) stream))
             ((equal (attribute self "class") "string")
              (write
               (with-output-to-string (s)
                 (iter (for c in (child-nodes self))
                   (write c :stream s)))
               :stream stream))
             ((equal (attribute self "class") "comment")
              (dotimes (_ (parse-number:parse-number (attribute self "comment-level")))
                (write-char #\; stream))
              (write-char #\  stream)
              (iter (for c in (child-nodes self))
                (write c :stream stream)))
             (t (error "TODO")))))

    (set-pprint-dispatch
     'text-node
     (lambda (stream self &rest noise)
       (declare (ignore noise))
       (write-string (text self) stream)))))

;;; File mode

(define-class lisp-file-mode (file-mode)
  () (:documentation "Lisp source files."))

(defmethod revert-buffer-aux ((buffer lisp-file-mode))
  (erase-buffer buffer)
  (let ((doc-node (make-element "div" :class "doc")))
    (insert-nodes (end-pos (document-root buffer)) doc-node)
    (setf (restriction buffer) doc-node
          (pos (focus buffer)) (end-pos doc-node))
    (apply #'insert-nodes (end-pos doc-node)
           (read-from-file (filename buffer)))))

(defmethod write-file ((buffer lisp-file-mode))
  (with-open-file (s (filename buffer)
                     :direction :output :if-exists :supersede)
    (with-standard-io-syntax
      (let ((*print-pretty* t)
            (*print-pprint-dispatch* *lisp-pprint-dispatch*)
            (*package* (find-package "NEOMACS")))
        (dolist (c (child-nodes
                    (only-elt (get-elements-by-class-name
                               (document-root buffer)
                               "doc"))))
          (prin1 c s))
        nil))))

(define-command find-file ()
  (let ((filename (read-from-minibuffer "Find file: ")))
    (with-current-buffer
        (switch-to-buffer
         (make-instance
          (dynamic-mixins:mix 'lisp-mode 'lisp-file-mode 'buffer)
          :name filename))
      (setf (filename (current-buffer)) filename)
      (revert-buffer))))

#+nil (define-auto-rule '(match-regex ".*lisp")
  :included '(lisp-file-mode lisp-mode))
