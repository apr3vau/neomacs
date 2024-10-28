(in-package #:neomacs)

(define-mode minibuffer-find-file-mode
    (minibuffer-completion-mode)
  ())

(define-keymap minibuffer-find-file-mode ()
  "/" 'split-node)

(defmethod update-completion-buffer ((buffer minibuffer-find-file-mode))
  (let ((path (path-before (focus))))
    (setf (file-path (completion-buffer buffer))
          (make-pathname :name nil :type nil :defaults path)
          (occur-query (completion-buffer buffer))
          (file-namestring path))))

(defmethod selectable-p-aux ((buffer minibuffer-find-file-mode) pos)
  (class-p (node-containing pos) "path-component"))

(defmethod revert-buffer-aux ((buffer minibuffer-find-file-mode))
  (call-next-method)
  (let ((last (make-element "span" :class "path-component"))
        (input (minibuffer-input-element buffer)))
    (iter (for n in (cdr (pathname-directory *default-pathname-defaults*)))
      (insert-nodes
       (end-pos input)
       (make-element "span" :class "path-component" :children (list n))))
    (insert-nodes (end-pos input) last)
    (setf (pos (focus)) (end-pos last))))

(defun path-before (&optional (pos (focus)))
  (let* ((component (node-containing pos))
         (dir (make-pathname
               :directory
               (cons ':absolute
                     (iter (for c in (child-nodes (parent component)))
                       (until (eql c component))
                       (if-let (c (text-content c))
                         (collect c into result)
                         (setq result nil))
                       (finally (return result)))))))
    (if-let (file (text-content component))
      (merge-pathnames file dir)
      dir)))

(defmethod minibuffer-input ((buffer minibuffer-find-file-mode))
  (path-before (end-pos (last-child (minibuffer-input-element buffer)))))

(defmethod complete-minibuffer-aux ((buffer minibuffer-find-file-mode))
  (let ((selection (node-after (focus (completion-buffer (current-buffer)))))
        (path-component (node-containing (focus))))
    (unless (class-p selection "dummy-row")
      (delete-nodes (pos-right path-component) nil)
      (delete-nodes (pos-down path-component) nil)
      (insert-nodes (pos-down path-component)
                    (text-content (first-child selection)))
      (when (class-p (first-child selection) "directory")
        (let ((new (make-element "span" :class "path-component")))
          (insert-nodes (pos-right path-component) new)
          (setf (pos (focus)) (end-pos new)))))))

(defstyle minibuffer-find-file-mode
    `((".path-component::before"
       :content "/")))

(defun set-auto-mode ()
  (let ((type (pathname-type (file-path (current-buffer)))))
    (cond ((uiop:directory-pathname-p (file-path (current-buffer)))
           (enable 'file-list-mode))
          ((equal type "lisp")
           (enable 'lisp-mode))
          ((equal type "html")
           (enable 'html-doc-mode))
          (t (enable 'text-mode)))))

(define-command find-file
    (&optional (path
                (read-from-minibuffer
                 "Find file: "
                 :modes 'minibuffer-find-file-mode
                 :completion-buffer
                 (make-completion-buffer
                  '(file-list-mode completion-buffer-mode)
                  :header-p nil
                  :require-match nil))))
  ;; If PATH points to a directory, ensure it is a directory
  ;; pathname (with NIL name and type fields).
  (when-let (dir (uiop:directory-exists-p path))
    (setq path dir))
  (ensure-directories-exist path)
  (switch-to-buffer
   (with-current-buffer
       (make-buffer
        (if (uiop:directory-pathname-p path)
            (lastcar (pathname-directory path))
            (file-namestring path))
        :modes 'file-mode)
     (setf (file-path (current-buffer)) path)
     (set-auto-mode)
     (revert-buffer)
     (current-buffer))))

(define-mode file-mode ()
  ((file-path))
  (:documentation
   "Generic mode for buffer backed by files."))

(defgeneric write-file (file-mode))

(defmethod revert-buffer-aux ((buffer file-mode))
  (erase-buffer)
  (let ((doc-node (make-element "div" :class "doc")))
    (insert-nodes (end-pos (document-root buffer)) doc-node)
    (apply #'insert-nodes (end-pos doc-node)
           (read-from-file (file-path buffer)))
    (setf (restriction buffer) doc-node
          (pos (focus buffer)) (pos-down doc-node))))

(defmethod write-file ((buffer file-mode))
  (with-open-file (s (file-path buffer)
                     :direction :output :if-exists :supersede)
    (with-standard-io-syntax
      (dolist (c (child-nodes
                  (only-elt (get-elements-by-class-name
                             (document-root buffer)
                             "doc"))))
        (write-dom-aux buffer c s))
      nil)))

(define-command save-buffer (&optional (buffer (current-buffer)))
  (write-file buffer)
  (message "Wrote ~a" (file-path buffer)))

(define-keys global
  "C-x C-f" 'find-file
  "C-x C-s" 'save-buffer)
