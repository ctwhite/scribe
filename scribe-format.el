;;; scribe-format.el --- Formatting helpers for Scribe -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This module provides robust and visually appealing formatting utilities
;; for rendering `scribe-log-entry` objects into human-readable output.
;; It includes functions for:
;; - Pretty-printing log entries with colored faces for different levels.
;; - Formatting timestamps, file paths, function names, and line numbers.
;; - Handling and displaying stack traces.
;; - Providing flexible output customization.
;;
;; These helpers are designed to be used by higher-level Scribe commands,
;; UI components, or export tools, ensuring consistent and clear log presentation.
;;
;;; Code:

(require 'f)          
(require 's)          
(require 'project)    
(require 'scribe-entry) 
(require 'ts)        

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                       Customization Variables                              ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defcustom scribe-format-path-style 'project
  "How to display file paths in formatted log output.

Choices are:
- 'project:    Relative to the current project root (if detected).
- 'abbreviate: Abbreviates the user's home directory to `~`.
- 'full:       Displays the full absolute path.
- 'short:      Displays only the basename of the file (default fallback)."
  :type '(choice
          (const :tag "Project-relative" project)
          (const :tag "Home abbreviated (~)" abbreviate)
          (const :tag "Full path" full)
          (const :tag "Short (basename only)" short))
  :group 'scribe)

(defcustom scribe-format-timestamp-format "%H:%M:%S"
  "Format string for timestamps in log output.
Uses `format-time-string` specifiers (e.g., \"%Y-%m-%d %H:%M:%S\").
This string is passed to `ts-format`."
  :type 'string
  :group 'scribe)

(defcustom scribe-format-call-site-template "[%s in %s%s]"
  "Format string for the call site (file, function, line).
Placeholders: %s for file, %s for function, %s for line (e.g., \":123\")."
  :type 'string
  :group 'scribe)

(defcustom scribe-format-trace-prefix "\n  > "
  "Prefix for each line of a formatted stack trace."
  :type 'string
  :group 'scribe)

(defface scribe-format-error-face
  '((((class color) (min-colors 89)) (:foreground "#E06C75" :weight bold)) ; Muted red
    (t (:foreground "#ff5f5f" :weight bold)))
  "Face for log messages with 'error' level. Uses a muted red for clarity on dark backgrounds."
  :group 'scribe)

(defface scribe-format-warn-face
  '((((class color) (min-colors 89)) (:foreground "#E5C07B" :weight bold)) ; Muted yellow/orange
    (t (:foreground "#e6c384" :weight bold)))
  "Face for log messages with 'warn' level. Uses a muted yellow/orange for clarity on dark backgrounds."
  :group 'scribe)

(defface scribe-format-info-face
  '((((class color) (min-colors 89)) (:foreground "#61AFEF")) ; Muted blue
    (t (:foreground "#83b8ff")))
  "Face for log messages with 'info' level. Uses a muted blue for clarity on dark backgrounds."
  :group 'scribe)

(defface scribe-format-debug-face
  '((((class color) (min-colors 89)) (:foreground "#98C379" :slant italic)) ; Muted green
    (t (:foreground "#a5c577" :slant italic)))
  "Face for log messages with 'debug' level. Uses a muted green and italic for clarity on dark backgrounds."
  :group 'scribe)

(defface scribe-format-timestamp-face
  '((((class color) (min-colors 89)) (:foreground "#5C6370" :slant italic)) ; Dark gray/blue-gray
    (t (:foreground "#727169" :slant italic)))
  "Face for timestamps in log output. Uses a dark gray for subtle presence."
  :group 'scribe)

(defface scribe-format-file-face
  '((((class color) (min-colors 89)) (:foreground "#C678DD" :slant italic)) ; Muted purple
    (t (:foreground "#957fb8" :slant italic)))
  "Face for file names in logger output. Uses a muted purple for distinctiveness."
  :group 'scribe)

(defface scribe-format-line-face
  '((((class color) (min-colors 89)) (:foreground "#D19A66")) ; Muted orange/brown
    (t (:foreground "#dca561")))
  "Face for line numbers in logger output. Uses a muted orange/brown for clarity."
  :group 'scribe)

(defface scribe-format-function-face
  '((((class color) (min-colors 89)) (:foreground "#61AFEF" :weight semi-bold)) ; Reusing muted blue, but bold
    (t (:foreground "#7fb4ca" :weight semi-bold)))
  "Face for function names in logger output. Uses a muted blue with semi-bold weight."
  :group 'scribe)

(defface scribe-format-namespace-face
  '((((class color) (min-colors 89)) (:foreground "#ABB2BF")) ; Light gray, good for general text
    (t (:foreground "#b5a777")))
  "Face for namespace tags in logger output. Uses a light gray for general readability."
  :group 'scribe)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                            Internal Helpers                                ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar scribe-format--log-level-faces
  '(("error" . scribe-format-error-face)
    ("warn"  . scribe-format-warn-face)
    ("info"  . scribe-format-info-face)
    ("debug" . scribe-format-debug-face))
  "Alist mapping log level strings to display faces.")

(defun scribe-format--log-face (level)
  "Return face symbol associated with LEVEL (a symbol).
If LEVEL is not recognized or is not a symbol, returns `default` face.
This ensures robustness against unexpected `level` inputs."
  (if (symbolp level)
      (alist-get (symbol-name level) scribe-format--log-level-faces 'default nil #'string=)
    'default)) ; Fallback to default face for invalid level type

(defun scribe-format--fmt (text face)
  "Propertize TEXT with FACE if FACE is non-nil and TEXT is a string.
Returns TEXT as is if FACE is nil or TEXT is not a string.
Ensures propertization is only applied to valid string input, preventing errors."
  (if (and text (stringp text) face)
      (propertize text 'face face)
    text))

(defun scribe-format--fmt-level (level)
  "Format LEVEL symbol (e.g., 'info) as an uppercase string with its associated face.
Returns an empty string if level is nil or cannot be converted to a string."
  (when (symbolp level) ; Ensure it's a symbol before processing
    (condition-case nil
        (scribe-format--fmt (upcase (symbol-name level))
                            (scribe-format--log-face level))
      (error
       ;; Fallback if symbol-name or upcase fails (unlikely but robust)
       (message "[scribe-format] ERROR: Failed to format log level %S: %S" level error)
       (scribe-format--fmt (format "[%S]" level) 'scribe-format-error-face)))))

(defun scribe-format--fmt-namespace (namespace)
  "Format NAMESPACE (a symbol) as a bracketed tag with `scribe-format-namespace-face`.
Returns an empty string if namespace is nil or not a symbol."
  (when (symbolp namespace) ; Ensure it's a symbol
    (let ((ns-str (symbol-name namespace)))
      (unless (s-blank? ns-str)
        (scribe-format--fmt (format "[%s]" ns-str) 'scribe-format-namespace-face)))))

(defun scribe-format--fmt-timestamp (ts)
  "Format TS (a timestamp float) with the `scribe-format-timestamp-face`.
Uses `scribe-format-timestamp-format` for formatting via `ts-format`.
If TS is nil or invalid, returns a placeholder string with an error face."
  (when (numberp ts) ; Ensure it's a number (float)
    (condition-case err
        (scribe-format--fmt (ts-format scribe-format-timestamp-format ts) ; Use ts-format here
                            'scribe-format-timestamp-face)
      (error
       ;; Log an internal error if timestamp formatting fails, but provide a clear placeholder
       (message "[scribe-format] ERROR: Failed to format timestamp %S: %S" ts err)
       (scribe-format--fmt "[INVALID_TIMESTAMP]" 'scribe-format-error-face)))))

(defun scribe-format--fmt-call-site (file fn line)
  "Format the call-site with file, function FN, and LINE number.
Uses `scribe-format-call-site-template` for the overall structure.
Handles nil or invalid values for file, fn, or line gracefully by substituting '?'.
Applies specific faces for file, function, and line number components."
  (let* ((formatted-file (scribe-format--fmt
                          (or (and (stringp file) (scribe-format--relative-file-name file)) "?")
                          'scribe-format-file-face))
         (formatted-fn (scribe-format--fmt
                        (or fn "?") 
                        'scribe-format-function-face))
         (formatted-line (if (numberp line)
                             (scribe-format--fmt (format ":%d" line) 'scribe-format-line-face)
                           "")))
    ;; Use `format` to assemble the parts according to the template
    (format scribe-format-call-site-template
            formatted-file formatted-fn formatted-line)))

(defun scribe-format--fmt-trace (trace)
  "Format multi-line TRACE block (list of strings or single string).
Each line is prefixed with `scribe-format-trace-prefix`.
Returns an empty string if trace is nil or empty.
Ensures robust handling of various `trace` input types."
  (when trace
    (let ((lines (cond
                   ((stringp trace) (s-split "\n" trace t)) 
                   ((listp trace) (cl-remove-if #'s-blank? trace)) 
                   (t (message "[scribe-format] WARNING: Invalid trace format %S. Expected string or list of strings." trace)
                      nil)))) 
      (when lines
        (concat scribe-format-trace-prefix
                (s-join scribe-format-trace-prefix lines))))))

(defun scribe-format--relative-file-name (file)
  "Return a path for FILE formatted according to `scribe-format-path-style`.
Provides robust handling for various path styles and project detection.
Returns the short file name as a fallback if other methods fail or error out."
  (unless (stringp file)
    (message "[scribe-format] WARNING: Invalid file path input %S. Expected string." file)
    (cl-return-from scribe-format--relative-file-name "?")) ; Return placeholder for invalid input

  (condition-case err
      (pcase scribe-format-path-style
        ('project
         (if-let ((root (scribe-format--project-root file)))
             (f-relative file root)
           (f-short file))) 
        ('abbreviate (f-abbrev file))
        ('full       (f-expand file))
        ('short      (f-short file))
        (_           (f-short file))) 
    (error
     ;; Log an internal error if path formatting fails, but return a fallback
     (message "[scribe-format] ERROR: Failed to format file path %S with style %S: %S"
              file scribe-format-path-style err)
      ;; Always return a short path on error              
     (f-short file))))

(defun scribe-format--project-root (file)
  "Return the canonical project root of FILE, if found.
Handles potential errors during project detection gracefully."
  (condition-case err
      (when-let ((proj (and file (project-current nil (f-dirname file)))))
        (f-canonical (project-root proj)))
    (error
     ;; Log internal error but return nil to allow fallback path formatting
     (message "[scribe-format] ERROR: Failed to detect project root for %S: %S" file err)
     nil)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                 Public API                                 ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defun scribe-format (entry &optional format-str &rest args)
  "Convert `scribe-log-entry` ENTRY to a formatted string.
This is the primary function for rendering log entries.

The default output format is: `LEVEL [NAMESPACE] [FILE in FUNCTION:LINE] TIMESTAMP MESSAGE [ADDITIONAL_FORMATTED_ARGS] [TRACE]`
Each component is propertized with a specific face for visual clarity.

ENTRY: A `scribe-log-entry` struct containing log details. Must be a valid entry.
FORMAT-STR: Optional format string (like in `format`) to append to the main message.
ARGS: Arguments for `FORMAT-STR`.

Returns: A propertized string representing the formatted log entry.
         Returns an error message string if `ENTRY` is invalid."
  (unless (scribe-log-entry-p entry)
    (message "[scribe-format] ERROR: Invalid log entry provided for formatting: %S" entry)
    (cl-return-from scribe-format (scribe-format--fmt "[INVALID_ENTRY]" 'scribe-format-error-face)))

  (let* ((level     (scribe-log-entry-level entry))
         (timestamp (scribe-log-entry-timestamp entry)) 
         (message   (scribe-log-entry-message entry))
         (file      (scribe-log-entry-file entry))
         (fn        (scribe-log-entry-fn entry))
         (line      (scribe-log-entry-line entry))
         (namespace (scribe-log-entry-namespace entry))
         (trace     (scribe-log-entry-trace entry))

         ;; Format individual components
         (formatted-level (scribe-format--fmt-level level))
         (formatted-namespace (scribe-format--fmt-namespace namespace))
         (formatted-call-site (scribe-format--fmt-call-site file fn line))
         (formatted-timestamp (scribe-format--fmt-timestamp timestamp))
         ;; Message itself is formatted with the log level's face
         (formatted-message (scribe-format--fmt message (scribe-format--log-face level)))
         (formatted-trace (scribe-format--fmt-trace trace))

         ;; Assemble the main log line components, filtering out empty strings
         (main-components (cl-remove-if #'s-blank?
                                        (list formatted-level
                                              formatted-namespace
                                              formatted-call-site
                                              formatted-timestamp
                                              formatted-message)))
         (additional-formatted-args ""))

    ;; Apply additional format string and arguments if provided
    (when format-str
      (condition-case err
          (setq additional-formatted-args (apply #'format format-str args))
        (error
         (message "[scribe-format] ERROR: Failed to apply additional format string '%S' with args %S: %S"
                  format-str args err)
         (setq additional-formatted-args (scribe-format--fmt "[FORMAT_ERROR]" 'scribe-format-error-face)))))

    ;; Concatenate all parts to form the final log string
    (concat
     (s-join " " main-components)
     ;; Add a space before additional args only if they exist
     (if (s-blank? additional-formatted-args) "" (concat " " additional-formatted-args))
     formatted-trace)))

(provide 'scribe-format)
;;; scribe-format.el ends here