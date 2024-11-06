(in-package #:neomacs)

(defun %quote-js (js-code)
  "Replace each backlash with 2, unless a \" follows it."
  (ppcre:regex-replace-all "\\\\(?!\")" js-code "\\\\\\\\"))

(defvar *force-sync-evaluate* nil)

(defun evaluate-javascript (code buffer)
  "Evaluate JavaScript CODE asynchronously.

Evaluate CODE in BUFFER's webContents, or main Electron process if
BUFFER is NIL. Returns NIL."
  (if *force-sync-evaluate*
      (evaluate-javascript-sync code buffer)
      (if buffer
          (cera.d:js
           cera.d:*driver*
           (ps:ps (ps:chain (js-buffer buffer) web-contents
                            (execute-java-script (ps:lisp code) t))))
          (cera.d:js cera.d:*driver* code)))
  nil)

(defun evaluate-javascript-sync (code buffer)
  "Evaluate JavaScript CODE synchronously and return the result.

Evaluate CODE in BUFFER's webContents, or main Electron process if
BUFFER is NIL."
  (let* ((message-id
           (uuid:format-as-urn nil (uuid:make-v4-uuid)))
         (full-js
           (if buffer
               (ps:ps
                 (ps:chain
                  -ceramic
                  (sync-eval
                   (ps:lisp message-id)
                   (lambda ()
                     (ps:chain (js-buffer buffer) web-contents
                               (execute-java-script (ps:lisp code) t))))))
               (ps:ps
                 (ps:chain
                  -ceramic
                  (sync-eval
                   (ps:lisp message-id)
                   (lambda () (eval (ps:lisp code)))))))))
    (with-slots (threads responses cera.d::js-lock)
        cera.d:*driver*
      (unless (gethash (bt:current-thread) threads)
        (setf (gethash (bt:current-thread) threads)
              (sb-concurrency:make-mailbox)))
      (let ((mailbox (gethash (bt:current-thread) threads)))
        (setf (gethash message-id responses) mailbox)
        (cera.d:js cera.d:*driver* full-js)
        (sb-concurrency:receive-message mailbox)))))

(defclass driver (ceramic.driver:driver)
  ((responses :initform (make-hash-table :test 'equal))
   (threads :initform (make-hash-table :weakness :key))))

(setq cera.d:*driver* (make-instance 'driver)
      trivial-ws:+default-timeout+ 1000000
      ceramic.setup::+main-javascript+ (asdf:system-relative-pathname :neomacs #p"main.js")
      ceramic.setup::*electron-version* "33.0.2")

(defmethod ceramic.driver::on-message ((driver driver) message)
  (declare (type string message))
  (let ((data (cl-json:decode-json-from-string message)))
    (with-slots (responses cera.d::js-lock) driver
      (if-let (id (assoc-value data :id))
        (bt:with-lock-held (cera.d::js-lock)
          (sb-concurrency:send-message
           (gethash id responses)
           (assoc-value data :result))
          (remhash id responses))
        (sb-concurrency:send-message *event-queue* data)))))

(define-command kill-neomacs ()
  "Exit Neomacs."
  ;; Mark all buffer as non-alive to suppress post-command operations
  (clrhash *buffer-table*)
  (sb-concurrency:send-message *event-queue* 'quit)
  (ceramic:quit))

(define-keys global
  "C-x C-c" 'kill-neomacs)
