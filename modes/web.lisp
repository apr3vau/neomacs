(in-package #:neomacs)

(define-command find-url
    (&optional (url
                (read-from-minibuffer
                 "Find URL: ")))
  (let ((parsed (quri:uri url)))
    (if (quri:uri-scheme parsed)
        (setq url parsed)
        (setq url (quri:uri (str:concat "https://duckduckgo.com/?q=" url)))))
  (switch-to-buffer
   (make-buffer "Web" :modes 'web-mode :url url
                :styles nil)))

(define-mode web-mode (read-only-mode)
  ((scroll-multiplier :default 16 :type (integer 1))
   (hints-selector :default "a, button, input, textarea, details, select"
                   :type string)))

(defmethod render-focus-aux ((buffer web-mode) (pos t)))

(define-keys global
  "C-x C-l" 'find-url)

(define-keys web-mode
  'next-line 'web-next-line
  'previous-line 'web-previous-line
  'backward-node 'web-go-backward
  'forward-node 'web-go-forward
  'scroll-up-command 'web-scroll-up
  'scroll-down-command 'web-scroll-down
  'beginning-of-buffer 'web-scroll-to-top
  'end-of-buffer 'web-scroll-to-bottom
  'self-insert-command 'web-forward-key
  'backward-delete 'web-forward-key)

(define-command web-next-line
  :mode web-mode ()
  (evaluate-javascript
   (ps:ps (ps:chain
           window (scroll-by
                   0 (ps:lisp
                      (scroll-multiplier (current-buffer))))))
   (current-buffer)))

(define-command web-previous-line
  :mode web-mode ()
  (evaluate-javascript
   (ps:ps (ps:chain
           window (scroll-by
                   0 (ps:lisp
                      (- (scroll-multiplier (current-buffer)))))))
   (current-buffer)))

(define-command web-scroll-up
  :mode web-mode ()
  (evaluate-javascript
   (ps:ps (ps:chain
           window (scroll-by
                   0 (ps:lisp
                      (* (- (scroll-lines (current-buffer)))
                         (scroll-multiplier (current-buffer)))))))
   (current-buffer)))

(define-command web-scroll-down
  :mode web-mode ()
  (evaluate-javascript
   (ps:ps (ps:chain
           window (scroll-by
                   0 (ps:lisp
                      (* (scroll-lines (current-buffer))
                         (scroll-multiplier (current-buffer)))))))
   (current-buffer)))

(define-command web-scroll-to-top
  :mode web-mode ()
  (evaluate-javascript
   (ps:ps (ps:chain
           window (scroll-by
                   0 (- (ps:chain document document-element
                                  scroll-height)))))
   (current-buffer)))

(define-command web-scroll-to-bottom
  :mode web-mode ()
  (evaluate-javascript
   (ps:ps (ps:chain
           window (scroll-by
                   0 (ps:chain document document-element
                               scroll-height))))
   (current-buffer)))

(defmethod on-buffer-title-updated progn ((buffer web-mode) title)
  (rename-buffer title))

(define-command web-go-backward
  :mode web-mode ()
  (unless
      (evaluate-javascript-sync
       (ps:ps
         (let ((h (ps:chain (js-buffer (current-buffer))
                            web-contents navigation-history)))
           (when (ps:chain h (can-go-back))
             (ps:chain h (go-back))
             t)))
       nil)
    (error "Can not go backward.")))

(define-command web-go-forward
  :mode web-mode ()
  (unless
      (evaluate-javascript-sync
       (ps:ps
         (let ((h (ps:chain (js-buffer (current-buffer))
                            web-contents navigation-history)))
           (when (ps:chain h (can-go-forward))
             (ps:chain h (go-forward))
             t)))
       nil)
    (error "Can not go forward.")))

(defun key-sym-to-electron (sym)
  (if-let (translation (gethash (cons sym nil) *event-to-char*))
    (string translation)
    sym))

(define-command web-forward-key ()
  (let ((key (lastcar *this-command-keys*)))
    (evaluate-javascript
     (ps:ps
       (let ((buf (js-buffer (current-buffer)))
             (code (ps:lisp (key-sym-to-electron (key-sym key)))))
         (ps:chain buf ignore-keys
                   (push (ps:create type "keyDown"
                                    key (ps:lisp (key-sym key)))))
         (ps:chain
          buf web-contents
          (send-input-event
           (ps:create type "keyDown"
                      key-code code)))
         (ps:chain
          buf web-contents
          (send-input-event
           (ps:create type "char"
                      key-code code)))
         (ps:chain
          buf web-contents
          (send-input-event
           (ps:create type "keyUp"
                      key-code code)))))
     nil)))
