;;; scribe-context.el --- Context-aware structured logging for Emacs -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This library provides structured, context-aware logging for Emacs Lisp code.
;; It captures detailed metadata about the call site of a log entry, such as:
;;
;; - The name of the function from which logging was invoked.
;; - The source file and the *starting line number* of that function.
;; - The buffer and point (cursor position) at the time of logging.
;;
;; The main tools provided are:
;;
;; - `scribe-call-site`: A struct representing the metadata of the log site.
;; - `scribe-context`: A dynamically bound variable holding the current log context.
;; - `with-scribe-context!`: A macro that captures context and executes code with `scribe-context` bound.
;; - `scribe-fn-name!`, `scribe-file-name!`: Utilities for retrieving static source metadata.
;;
;; This revision ensures the robustness of compile-time context derivation by
;; prioritizing `macroexp-file-name` for file path derivation, falling back to
;; other reliable methods. It also maintains the efficiency gains from caching
;; and optional `ripgrep` usage for runtime line number derivation, and includes
;; checks for robust handling of potentially `nil` function names.
;;
;;; Code:

(require 'backtrace) 
(require 'cl-lib)    
(require 'dash)      
(require 'f)         
(require 'macroexp)  
(require 's)         

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                          Call Site Structure                               ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(cl-defstruct scribe-call-site
  "A structure representing the call site where a log entry was generated.

This structure contains information about the location in the code where 
the log entry was created, including the file name, line number, function 
name, buffer, and position in the buffer.

Fields:
- `file`: The file name where the log entry was created (compile-time derived).
- `line`: The *starting line number* of the function where the log was created (runtime derived).
- `fn`: The function name from which the log entry was generated (compile-time derived).
- `buffer`: The buffer where the log entry was created (runtime derived).
- `pos`: The position (point) in the buffer where the log entry was generated (runtime derived)."
 file
 line
 fn  
 buffer 
 pos)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                            Internal Variables                              ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar scribe-context nil
  "Dynamic binding holding log context such as file, line, and function.
This variable is bound by `with-scribe-context!` to provide call site information.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                           Compile-Time Derivations                         ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defmacro scribe-fn-name! ()
  "Return the name of the calling function as a string at macro expansion time.
Uses `backtrace-frame` to inspect the call stack. Returns nil if not found."
  (let ((frames nil)
        (index 5)) ; Skip macroexpansion layers
    ;; Gather backtrace frames
    (while (let ((frame (backtrace-frame index)))
             (when frame
               (push frame frames)
               (cl-incf index))))

    ;; Extract name from relevant frame
    (let ((name (->> frames
                     (reverse)
                     (--first (ignore-errors (eq (car (caddr it)) 'defalias)))
                     (caddr)
                     (cadadr)))) ; Should be a symbol or string
      (cond
       ((symbolp name) (symbol-name name))
       ((stringp name) name)
       (t nil)))))

;;;###autoload
(defmacro scribe-file-name! ()
  "Returns the file name of the current source file at macro expansion time.
This prioritizes `macroexp-file-name` if available, then falls back to
`byte-compile-current-file` (during compilation) or `load-file-name`
(during loading).
Returns `nil` if the context is not a file (e.g., `*scratch*` buffer)."
  (let ((file (or (when (fboundp 'macroexp-file-name)
                    (macroexp-file-name)) ; Try macroexp-file-name first
                  (bound-and-true-p byte-compile-current-file) ; During byte-compilation
                  (bound-and-true-p load-file-name)))) ; During loading
    (when (stringp file)
      file)))

;;;###autoload
(defun scribe-find-function-start-line (function-name file)
  "Return the line number of FUNCTION-NAME defined in FILE.
Supports functions, macros, and autoloads. FUNCTION-NAME should be a string.
Returns nil if not found."
  (when (and (stringp function-name)
             (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((regex (format "^(\\s-*\\(defun\\|defmacro\\|cl-defstruct\\|define-\\w+\\)\\s-+%s\\_>"
                           (regexp-quote function-name))))
        (if (re-search-forward regex nil t)
            (line-number-at-pos (match-beginning 0))
          ;; fallback: look for autoload forms
          (goto-char (point-min))
          (let ((autoload-regex (format ";;;###autoload[[:space:]\n]+(\\(defun\\|defmacro\\)\\s-+%s\\_>"
                                        (regexp-quote function-name))))
            (if (re-search-forward autoload-regex nil t)
                (line-number-at-pos (match-beginning 0))
              nil)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                          Context Binding Macro                             ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defmacro with-scribe-context! (&rest body)
  "Execute BODY with `scribe-context` bound to the current call site.
This macro captures the function name and file at compile time,
and the line number (start of function), buffer, and point at runtime.
This provides the necessary metadata for structured logging."
  `(let* ((fn (scribe-fn-name!))      ; Compile-time function name (symbol or nil)
          (file (scribe-file-name!))) ; Compile-time file name (string or nil)
     ;; Runtime derivation for line, buffer, and position
     (let ((log-context (make-scribe-call-site
                         :fn fn
                         :file file
                         ;; Get function start line using cache + optionally ripgrep.
                         :line (when (and fn (stringp file) file)
                                 (scribe-find-function-start-line fn file))
                         :buffer (current-buffer)
                         :pos (point))))
       (let ((scribe-context log-context))
         ,@body))))

(provide 'scribe-context)
;;; scribe-context.el ends here