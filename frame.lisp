(in-package #:neomacs)

(defun make-echo-area ()
  (lret ((buffer (make-instance 'buffer :name " *echo-area*" :styles '(echo-area))))
    (setf (window-decoration buffer)
          (make-element
           "div" :class "minibuffer"
           :children (list (make-element "div" :class "content" :buffer (id buffer)))))))

(define-class frame-root-mode () ())

(defmethod on-buffer-loaded progn ((buffer frame-root-mode))
  (redisplay-windows))

(defmethod on-post-command progn ((buffer frame-root-mode))
  (redisplay-windows)
  (when-let (window-node (node-after (focus)))
    (when-let (buffer (window-buffer window-node))
      (evaluate-javascript
       (ps:ps (ps:chain (js-buffer buffer) web-contents (focus)))
       nil))))

(ps:defpsmacro js-frame (buffer)
  `(ps:getprop (ps:chain -ceramic frames) (ps:lisp (id ,buffer))))

(ps:defpsmacro js-buffer (buffer)
  `(ps:getprop (ps:chain -ceramic buffers) (ps:lisp (id ,buffer))))

(defmethod enable-aux ((mode (eql 'frame-root-mode)))
  (evaluate-javascript
   (ps:ps
     (let ((frame (ps:chain -ceramic (create-frame (ps:lisp (id (current-buffer))) (ps:create))))
           (root (js-buffer (current-buffer))))
       (ps:chain frame content-view (add-child-view root))
       (let ((resize
               (lambda ()
                 (let ((bounds (ps:chain frame (get-content-bounds))))
                   (ps:chain root (set-bounds
                                   (ps:create :x 0 :y 0
                                              :width (ps:chain bounds width)
                                              :height (ps:chain bounds height)))))
                 (ps:chain root web-contents
                           (execute-java-script
                            (ps:lisp
                             (ps:ps
                               (let ((result (ps:create)))
                                 (dolist (c (ps:chain document (get-elements-by-class-name "content")))
                                   (let ((rect (ps:chain c (get-bounding-client-rect)))))
                                   (setf (ps:getprop result (ps:chain c (get-attribute "buffer")))
                                         (ps:create :x (ps:chain rect :x)
                                                    :y (ps:chain rect :y)
                                                    :width (ps:chain rect :width)
                                                    :height (ps:chain rect :height))))
                                 result))))
                           (then (lambda (result)
                                   (ps:for-in
                                    (buffer result)
                                    (ps:chain (ps:getprop (ps:chain -ceramic buffers) buffer)
                                              (set-bounds (ps:getprop result buffer)))))))))))
       (ps:chain frame (on "resize" resize))))
   nil))

(defmethod on-buffer-delete progn ((buffer frame-root-mode))
  (evaluate-javascript
   (ps:ps (ps:chain -ceramic (close-frame (ps:lisp (id (current-buffer))))))
   nil))

(defmethod selectable-p-aux ((buffer frame-root-mode) pos)
  (let ((node (node-after pos)))
    (and (class-p node "buffer" "minibuffer") (attribute node "selectable"))))

(defun focused-buffer (&optional (frame-root (current-frame-root)))
  (window-buffer (node-after (focus frame-root))))

(defun current-buffer ()
  (or *current-buffer* (focused-buffer)))

(defun make-frame-root (init-buffer)
  (lret ((buffer (make-instance 'buffer :name " *frame-root*"
                                        :styles '(frame-root))))
    (with-current-buffer buffer
      (enable 'frame-root-mode)
      (let* ((echo-area (make-echo-area))
             (root (document-root buffer))
             (split (make-element "div" :class "horizontal")))
        (insert-nodes (end-pos root) split)
        (insert-nodes (end-pos split) (window-decoration echo-area))
        (insert-nodes (pos-down split) (window-decoration init-buffer))
        (setf (pos (focus buffer)) (pos-down split))))))

(defun echo-area-buffer (&optional (frame-root (current-frame-root)))
  "The buffer currently displayed in echo area window."
  (window-buffer (npos-prev-ensure (end-pos (document-root frame-root))
                                   (alex:rcurry #'class-p "minibuffer"))))

(define-command other-window ()
  (with-current-buffer (current-frame-root)
    (forward-node-cycle)))

(define-command prev-other-window ()
  (with-current-buffer (current-frame-root)
    (backward-node-cycle)))

(defmethod on-node-setup progn ((buffer frame-root-mode) node)
  (when (class-p node "content")
    (evaluate-javascript
     (ps:ps (ps:chain (js-frame (current-buffer)) content-view
                      (add-child-view (ps:getprop (ps:chain -ceramic buffers)
                                                  (ps:lisp (attribute node "buffer"))))))
     nil))
  (when (class-p node "vertical" "horizontal")
    (flet ((observer (cell)
             (declare (ignore cell))
             (when (eql (first-child node) (last-child node))
               (splice-node node))))
      (add-observer (slot-value node 'first-child) #'observer)
      (add-observer (slot-value node 'last-child) #'observer))))

(defmethod on-node-cleanup progn ((buffer frame-root-mode) node)
  (when (class-p node "content")
    (evaluate-javascript
     (ps:ps (ps:chain (js-frame (current-buffer)) content-view
                      (remove-child-view (ps:getprop (ps:chain -ceramic buffers)
                                                     (ps:lisp (attribute node "buffer"))))))
     nil)))

(defun frame-root (buffer)
  (host (window-decoration buffer)))

(defun switch-to-buffer (&optional (buffer (buffer-at-focus))
                           (victim (current-buffer)))
  (unless (frame-root victim)
    (error "~A is not displayed" victim))
  (when (typep buffer 'frame-root-mode)
    (error "Cannot switch to frame root ~A" buffer))
  (when (frame-root buffer)
    (error "~A is already displayed" buffer))
  (with-current-buffer (frame-root victim)
    (setf (previous-buffer buffer) victim)
    (let ((pos (window-decoration victim)))
      (insert-nodes pos (window-decoration buffer))
      (delete-nodes pos (pos-right pos))))
  buffer)

(defun replacement-buffer (&optional (buffer (current-buffer)))
  "Find a buffer to display in place of BUFFER.

A replacement buffer has to be alive and not already displayed."
  (let ((replacement (previous-buffer buffer)))
    (iter
      (while replacement)
      (until (and (buffer-alive-p replacement)
                  (not (frame-root replacement))
                  (not (typep replacement 'frame-root-mode))))
      (setq replacement (previous-buffer replacement)))
    ;; Try to find any buffer for replacement.
    (print replacement)
    (unless replacement
      (iter (for (_ buffer) in-hashtable *buffer-name-table*)
        (unless (or (frame-root buffer)
                    (typep buffer 'frame-root-mode))
          (setq replacement buffer)
          (return))))
    (unless replacement
      (error "TODO"))
    replacement))

(define-command bury-buffer (&optional (buffer (current-buffer)))
  "Stop displaying BUFFER."
  (switch-to-buffer (replacement-buffer buffer) buffer))

(define-command close-buffer-display (&optional (buffer (current-buffer)))
  (with-current-buffer (frame-root buffer)
    (let ((node (window-decoration buffer)))
      (delete-nodes node (pos-right node)))))

(define-command display-buffer-right (&optional (buffer (replacement-buffer)))
  (with-current-buffer (current-frame-root)
    (unless (class-p (node-containing (focus)) "vertical")
      (wrap-node (focus) (make-element "div" :class "vertical")))
    (let ((node (window-decoration buffer)))
      (insert-nodes (pos-right (focus)) node)
      (setf (pos (focus)) node))))

(define-keys global
  "C-x o" 'other-window
  "C-x 0" 'close-buffer-display
  "C-x 2" 'display-buffer-right)

(defun redisplay-windows ()
  (evaluate-javascript
   (ps:ps (ps:chain (js-frame (current-buffer)) (emit "resize")))
   nil))

(defvar *current-frame-root*)

(defun current-frame-root ()
  *current-frame-root*)

(defun content-node-buffer (node)
  (gethash (parse-integer (attribute node "buffer")) *buffer-table*))

(defun window-buffer (window-node)
  (content-node-buffer
   (only-elt
    (get-elements-by-class-name window-node "content"))))

(defvar *message-log-max* 1000)

(defun get-message-buffer ()
  (get-buffer-create "*Messages*"))

(defun truncate-node (node n)
  (iter
    (with i = 1)
    (for pos first (end-pos node)
         then (npos-left pos))
    (while pos)
    (when (line-start-p pos)
      (incf i))
    (unless (< i n)
      (delete-nodes (pos-down node) pos)
      (return))))

(defun message (control-string &rest format-arguments)
  (with-current-buffer (echo-area-buffer *current-frame-root*)
    (delete-nodes (pos-down (document-root (current-buffer))) nil)
    (when control-string
      (let ((message (apply #'format nil control-string format-arguments)))
        (insert-nodes (end-pos (document-root (current-buffer))) message)
        (when *message-log-max*
          (with-current-buffer (get-message-buffer)
            (unless (eql *message-log-max* t)
              (truncate-node (document-root (current-buffer)) *message-log-max*))
            (insert-nodes (end-pos (document-root (current-buffer)))
                          message
                          (make-new-line-node))))))))

(define-command open-dev-tools ()
  (evaluate-javascript
   (ps:ps (ps:chain (js-buffer (current-buffer)) web-contents (open-dev-tools)))
   nil))

(defstyle frame-root `((".vertical" :display "flex" :flex-flow "row" :width "100%" :height "100%")
                       (".horizontal" :display "flex" :flex-flow "column" :height "100%" :width "100%")
                       (".content" :width "100%" :height "100%")
                       (".buffer" :flex "1 0 1em" :display "flex"
                                  :flex-flow "column"
                                  :margin "8px"
                                  :backdrop-filter "blur(10px)")
                       (".minibuffer"
                        :flex "0 0 2em"
                        :margin "8px"
                        :backdrop-filter "blur(10px)")
                       (".header" :inherit header)
                       (".focus .header" :inherit header-focus)
                       ("body"
                        :padding "16px"
                        :margin 0
                        :inherit default
                        :background-size "contain"
                        :background-image "url(https://sozaino.site/wp-content/uploads/2021/08/sf35.png)")))

(defstyle echo-area `(("body" :inherit default
                              :margin-top 0
                              :margin-bottom 0)))

(defstyle header `(:padding "8px"
                   :margin-bottom "8px"
                   :background-color "rgba(169,151,160,0.2)"))

(defstyle header-focus `(:background-color "rgba(169,151,160,0.4)"))
