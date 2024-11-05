(in-package #:neomacs)

(define-mode minibuffer-find-file-mode
    (minibuffer-completion-mode)
  ((file-path :initarg :file-path)))

(define-keys minibuffer-find-file-mode
  "/" 'split-node)

(defmethod update-completion-buffer ((buffer minibuffer-find-file-mode))
  (let ((path (path-before (focus))))
    (setf (file-path (completion-buffer buffer))
          (make-pathname :name nil :type nil :defaults path)
          (occur-query (completion-buffer buffer))
          (file-namestring path))))

(defmethod selectable-p-aux ((buffer minibuffer-find-file-mode) pos)
  (class-p (node-containing pos) "path-component"))

(defmethod check-read-only ((buffer minibuffer-find-file-mode) pos)
  (unless (class-p (node-containing pos)
                   "path-component" "input")
    (error 'element-read-only-error :element (node-containing pos))))

(defmethod revert-buffer-aux ((buffer minibuffer-find-file-mode))
  (call-next-method)
  (let ((last (make-element "span" :class "path-component"))
        (input (minibuffer-input-element buffer)))
    (iter (for n in (cdr (pathname-directory
                          (or (file-path (current-buffer))
                              *default-pathname-defaults*))))
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

(defun find-file-buffer (path)
  "Find a buffer already opening PATH, if any."
  (when path
    (setq path (translate-logical-pathname path))
    (bt:with-recursive-lock-held (*buffer-table-lock*)
      (iter (for (_ b) in-hashtable *buffer-table*)
        (when (equal path (file-path b))
          (return b))))))

(defun find-file-no-select (path)
  (setq path (translate-logical-pathname path))
  ;; If PATH points to a directory, ensure it is a directory
  ;; pathname (with NIL name and type fields).
  (when-let (dir (uiop:directory-exists-p path))
    (setq path dir))
  (ensure-directories-exist path)
  (with-current-buffer
      (or (find-file-buffer path)
          (make-buffer
           (if (uiop:directory-pathname-p path)
               (lastcar (pathname-directory path))
               (file-namestring path))
           :modes 'file-mode
           :disambiguate
           (if (uiop:directory-pathname-p path)
               (car (last (pathname-directory path) 2))
               (lastcar (pathname-directory path)))
           :file-path path))
    (set-auto-mode)
    (when (or (not (modtime (current-buffer)))
              (not (eql (modtime (current-buffer))
                        (osicat-posix:stat-mtime
                         (osicat-posix:stat path))))
              (modified (current-buffer)))
      (revert-buffer))
    (current-buffer)))

(define-command find-file
    (&optional (path
                (read-from-minibuffer
                 "Find file: "
                 :modes 'minibuffer-find-file-mode
                 :completion-buffer
                 (make-completion-buffer
                  '(file-list-mode completion-buffer-mode)
                  :header-p nil
                  :require-match nil)
                 :file-path (file-path (current-buffer)))))
  (switch-to-buffer (find-file-no-select path)))

(define-mode file-mode ()
  ((file-path
    :initform (alex:required-argument :file-path)
    :initarg :file-path
    :documentation
    "Pathname of the file visited by this buffer.")
   (modified
    :initform nil
    :documentation
    "Whether this buffer has been modified since last revert or save.")
   (saved-undo-entry
    :initform nil
    :documentation
    "Undo entry (if applicable) of last revert or save.

This overrides `modified' test in `undo-mode' buffers.")
   (modtime
    :initform nil
    :documentation
    "Timestamp of last revert or save Neomacs knows of.

Used to detect modification from other processes before saving."))
  (:documentation
   "Generic mode for buffer backed by files."))

(defmethod file-path ((buffer buffer)) nil)

(defgeneric save-buffer-aux (buffer)
  (:method ((buffer buffer))
    (not-supported buffer 'save-buffer)))

(defmethod revert-buffer-aux ((buffer file-mode))
  (erase-buffer)
  ;; Static HTML optimization:

  ;; Rather than using `insert-nodes' primitive editing primitives, we
  ;; just updates Lisp side DOM, and serialize it as a static HTML
  ;; then serve to renderer. This is much better than renderer-side
  ;; DOM manipulation for larger files.
  (append-children
   (document-root buffer)
   (read-from-file (file-path buffer)))
  (dolist (c (child-nodes (document-root buffer)))
    (do-dom (alex:rcurry #'node-setup buffer) c))
  (let ((internal-url (format nil "neomacs:~a" (id buffer))))
    (evaluate-javascript
     (ps:ps
       (setf (ps:getprop -contents (ps:lisp internal-url))
             (ps:lisp (serialize (document-root buffer) nil))))
     nil)
    (load-url buffer internal-url))
  (setf (modified buffer) nil
        (modtime buffer)
        (osicat-posix:stat-mtime
         (osicat-posix:stat (file-path buffer))))
  (setf (restriction buffer) (document-root buffer)
        (pos (focus buffer)) (pos-down (document-root buffer))))

(defmethod save-buffer-aux ((buffer file-mode))
  (with-open-file (s (file-path buffer)
                     :direction :output :if-exists :supersede)
    (with-standard-io-syntax
      (dolist (c (child-nodes (document-root buffer)))
        (write-dom-aux buffer c s))
      nil)))

(defmethod check-read-only :after ((buffer file-mode) (pos t))
  (setf (modified buffer) t))

(defmethod save-buffer-aux :around ((buffer file-mode))
  (if (modified buffer)
      (progn
        (when (and (modtime buffer)
                   (not (eql (modtime buffer)
                             (osicat-posix:stat-mtime
                              (osicat-posix:stat (file-path buffer))))))
          (unless (read-yes-or-no
                   (format nil "~a has changed since visited. Save anyway? "
                           (name buffer)))
            (user-error "Save not confirmed")))
        (call-next-method)
        (setf (modified buffer) nil
              (modtime buffer)
              (osicat-posix:stat-mtime
               (osicat-posix:stat (file-path buffer))))
        (message "Wrote ~a" (file-path buffer)))
      (message "No changes need to be saved")))

(defun normalize-undo-entry (undo-entry)
  (if (undo-boundary-p undo-entry)
      (parent undo-entry)
      undo-entry))

(defmethod modified ((buffer undo-mode))
  (not (eql (saved-undo-entry buffer)
            (normalize-undo-entry (undo-entry buffer)))))

(defmethod save-buffer-aux :after ((buffer undo-mode))
  (when (typep buffer 'file-mode)
    (setf (saved-undo-entry buffer)
          (normalize-undo-entry (undo-entry buffer)))))

(defmethod revert-buffer-aux :after ((buffer undo-mode))
  (when (typep buffer 'file-mode)
    (setf (saved-undo-entry buffer)
          (normalize-undo-entry (undo-entry buffer)))))

(define-command save-buffer ()
  (save-buffer-aux (current-buffer)))

(define-keys global
  "C-x C-f" 'find-file
  "C-x C-s" 'save-buffer)
