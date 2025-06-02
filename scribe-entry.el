;;; scribe-entry.el --- Structured log entry representation for Scribe -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This library defines a structured representation of a "log entry" used by the
;; Scribe system for project-aware note-taking, journaling, or changelog management
;; in Emacs. Each `scribe-entry' instance encapsulates timestamp, location,
;; project association, tags, and a text payload. The data is designed to be
;; serialized or displayed in multiple formats (plain text, Org, Markdown, etc.).
;;
;; It provides constructors, accessors, and helper functions for working with
;; entries, as well as integration points for collecting and filtering logs
;; by project, tag, or time range.
;;
;;; Code:

(require 'cl-lib)
(require 'f)          
(require 'project)    
(require 'scribe-context)
(require 'ts)         

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                 Log Entry Structure                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(cl-defstruct (scribe-log-entry (:constructor scribe--make-log-entry))
  "A structured log entry object with metadata.

Fields:

`level`     (symbol): Log level like 'error, 'info, etc.
`message`   (string): Main log message.
`timestamp` (ts object): Timestamp as a `ts` n-tuple `(SECONDS MICROSECONDS)`. ; CLARIFIED
`trace`     (list): Optional list of strings representing a trace block.
`file`      (string): Full path to the origin file, potentially project-relative.
`fn`        (symbol): Function name where the log was generated.
`line`      (number): Line number in the file.
`namespace` (symbol): Tag used to group logs by context, often derived from project.
`data`      (plist or alist): Optional structured payload.
`tags`      (list): Optional list of symbols for arbitrary categorization."

  level
  message
  timestamp
  trace
  file
  fn
  line
  namespace
  data
  tags)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                         Customization Variables                            ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defcustom scribe-entry-timestamp-format "[%Y-%m-%d %H:%M:%S]"
  "Timestamp format string used in log entries.
This string is passed to `ts-format`.
NOTE: This variable is primarily for documentation; the actual formatting
is handled by `scribe-format.el` using `ts-format` on a `ts` object."
  :type 'string
  :group 'scribe)

(defcustom scribe-entry-namespace nil
  "Fixed namespace (symbol) for all log entries.

If non-nil, this overrides `scribe-entry-namespace-function`, providing
a consistent namespace across all logs from this Emacs instance."
  :type '(choice (const :tag "None" nil)
                 (symbol :tag "Fixed symbol"))
  :group 'scribe)

(defcustom scribe-entry-namespace-function #'scribe-entry--project-namespace
  "Function to derive a dynamic namespace from a file path.

Used only if `scribe-entry-namespace` is nil. By default, it uses the
`scribe-entry--project-namespace` function to derive the namespace
from the current file's project or directory name."
  :type 'function
  :group 'scribe)

(defcustom scribe-source-root-mapping nil
  "Alist mapping installed package root directories to their source root directories.
This is used to correctly derive source file paths for files that are part of
an Emacs package installed in a different location than their original source.
This mapping is applied *before* `project.el` is consulted.

Each element is `(INSTALLED-ROOT . SOURCE-ROOT)`.
INSTALLED-ROOT should be the canonical path to the root of the installed package.
SOURCE-ROOT should be the canonical path to the root of the original source.

Example: `((\"~/.emacs.d/elpa/my-package-1.0/\" . \"~/dev/emacs/my-package/\"))`"
  :type '(repeat (cons (directory :tag "Installed Root")
                       (directory :tag "Source Root")))
  :group 'scribe)

(defcustom scribe-entry-fallback-project-detection-depth 3
  "Maximum directory depth to search upwards for project markers if `project-known-project-roots`
matching fails.
This is used as a fallback to identify a project root when `project.el`'s
direct methods do not immediately recognize the project for a given file.
A value of 0 or nil disables this fallback."
  :type 'integer
  :group 'scribe)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                            Internal Helpers                                ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun scribe-entry--resolve-source-path (file)
  "Resolve the given FILE path to its original source path using `scribe-source-root-mapping`.
This is crucial for correctly identifying source locations when a package is
installed (e.g., in `elpa/`) but its source is elsewhere.

FILE: The path to resolve (e.g., from `this-command-file`).

Returns: The resolved source path as a canonical string, or the original FILE
         if no mapping applies or an error occurs."
  (unless (stringp file)
    (message "[scribe-entry] WARNING: Invalid file path for source resolution: %S" file)
    (cl-return-from scribe-entry--resolve-source-path nil))

  (let ((canonical-file (f-canonical file)))
    (condition-case err
        (dolist (mapping scribe-source-root-mapping canonical-file) ; Default to canonical-file if no match
          (let ((installed-root (f-canonical (car mapping)))
                (source-root (f-canonical (cdr mapping))))
            (when (string-prefix-p installed-root canonical-file)
              ;; If the file is within an installed root, replace the prefix
              (message "[scribe-entry] DEBUG: Resolved %S from installed root %S to source root %S."
                       canonical-file installed-root source-root)
              (cl-return-from scribe-entry--resolve-source-path
                (concat source-root (substring canonical-file (length installed-root)))))))
      (error
       (message "[scribe-entry] ERROR: Failed to resolve source path for %S: %S" file err)
       canonical-file)))) ; Fallback to canonical file on error

(defun scribe-entry--find-project-root (canonical-file)
  "Find the most specific project root for CANONICAL-FILE.
Prioritizes:
1. Longest, unambiguous match from `project-known-project-roots`.
2. Upward search for project markers (controlled by `scribe-entry-fallback-project-detection-depth`).

CANONICAL-FILE: The canonical path to the file (already resolved to its source location).

Returns: The canonical path of the project root (string), or `nil` if no unique,
         clear match is found or if `project.el` is not loaded."
  (unless (stringp canonical-file) (cl-return-from scribe-entry--find-project-root nil))

  ;; Ensure project.el is loaded before attempting any project-related functions
  (unless (fboundp 'project-known-project-roots)
    (message "[scribe-entry] DEBUG: project.el not loaded. Cannot use project detection features.")
    (cl-return-from scribe-entry--find-project-root nil))

  ;; 1. Search through `project-known-project-roots` for the longest, unambiguous prefix
  (let ((matching-roots nil))
    (dolist (root (project-known-project-roots))
      (let ((canonical-root (f-canonical root)))
        ;; Check if the file (or its directory) is within this known project root
        (when (string-prefix-p canonical-root canonical-file)
          (push canonical-root matching-roots))))

    (cond
     ;; No known project root contains this file
     ((null matching-roots) nil)
     ((= (length matching-roots) 1)
      ;; Single unique match from known roots
      (let ((root (car matching-roots)))
        (message "[scribe-entry] DEBUG: Single known project.el root found for %S: %S."
                 canonical-file root)
        (cl-return-from scribe-entry--find-project-root root)))
     (t
      ;; Multiple matches, find the most specific (longest path)
      (let* ((sorted-roots (sort matching-roots (lambda (a b) (> (length a) (length b)))))
             (most-specific (car sorted-roots)))
        (if (and most-specific
                 ;; Check if there's another root of the same length, indicating ambiguity
                 (or (= (length sorted-roots) 1) ; Only one match after sorting (most specific is unique)
                     (> (length most-specific) (length (cadr sorted-roots))))) ; Most specific is strictly longer
            (progn
              (message "[scribe-entry] DEBUG: Most specific known project.el root found for %S: %S."
                       canonical-file most-specific)
              (cl-return-from scribe-entry--find-project-root most-specific))
          ;; Ambiguous or equally specific multiple roots
          (message "[scribe-entry] WARNING: Multiple equally specific known project.el roots found for %S. Falling back to upward search."
                   canonical-file)
          nil)))))

  ;; 2. If still no project root from known roots, perform upward search for project markers
  (when (and (numberp scribe-entry-fallback-project-detection-depth)
             (> scribe-entry-fallback-project-detection-depth 0)
             (fboundp 'project-project-p)) 
    (message "[scribe-entry] DEBUG: No project.el root found from known roots. Attempting fallback upward detection for %S (depth: %d)."
             canonical-file scribe-entry-fallback-project-detection-depth)
    (let ((current-dir (f-dirname canonical-file))
          (depth 0))
      (while (and current-dir (<= depth scribe-entry-fallback-project-detection-depth))
        (condition-case err
            (when (project-project-p current-dir)
              (let ((root (f-canonical current-dir)))
                (message "[scribe-entry] DEBUG: Fallback upward project root found for %S: %S."
                         canonical-file root)
                (cl-return-from scribe-entry--find-project-root root)))
          (error
           (message "[scribe-entry] ERROR: Fallback project detection failed for directory %S: %S"
                    current-dir err)))
        (setq current-dir (f-dirname current-dir)) ; Move up one directory
        (cl-incf depth))))

  ;; 3. Final fallback if no project root found by any method
  (message "[scribe-entry] DEBUG: No project root found for %S after all attempts."
           canonical-file)
  nil)

(defun scribe-entry--resolve-namespace (path)
  "Determine the log namespace for PATH.

Returns a symbol either from:
1. `scribe-entry-namespace` if non-nil (fixed namespace).
2. `scribe-entry-namespace-function` applied to the resolved source PATH.
If neither is available or an error occurs, returns `nil` (no namespace)."
  (or scribe-entry-namespace
      (when (functionp scribe-entry-namespace-function)
        (let ((resolved-path (scribe-entry--resolve-source-path path)))
          (when resolved-path
            (condition-case err
                (funcall scribe-entry-namespace-function resolved-path)
              (error
               (message "[scribe-entry] ERROR: Namespace function failed for path %S: %S"
                        resolved-path err)
               nil)))))))

(defun scribe-entry--project-namespace (&optional file)
  "Derive a namespace symbol from FILE's project or directory.
This function is the default for `scribe-entry-namespace-function`.

- First, it resolves `file` to its canonical source path.
- If a project root is found for the resolved file (via `scribe-entry--find-project-root`),
  it returns the project's root directory name as the namespace.
- Otherwise, it falls back to deriving the namespace from the directory name
  of the resolved file.
- As a last resort, if `file` is nil or invalid, it uses `default-directory`.

FILE: The file path to derive the namespace from. Defaults to `default-directory` if nil.

Returns: A symbol representing the directory name, or `nil` if no meaningful
         name can be derived or on error."
  (unless (stringp file)
    (setq file default-directory))

  (let* ((resolved-file (scribe-entry--resolve-source-path file))
         (canonical-file (f-canonical resolved-file))
         ;; Find the most specific project root
         (project-root (scribe-entry--find-project-root canonical-file))
         ;; Use project root's directory name, or fallback to file's directory name
         (dir-to-name (or project-root (f-dirname canonical-file)))
         (name (when dir-to-name (file-name-nondirectory dir-to-name))))
    (if (and name (not (s-blank? name)))
        (intern name)
      (message "[scribe-entry] WARNING: Could not derive project namespace for %S." file)
      nil)))

(defun scribe-entry--project-relative-file (file)
  "Return FILE path relative to its resolved source root or project root, sans extension.
First resolves the `file` to its source path using `scribe-source-root-mapping`.
Then, it attempts to make the resolved path relative to a `project.el` project root
found via `scribe-entry--find-project-root`.
If no project is found, it falls back to the basename of the resolved file.
Finally, it removes the file extension and leading slashes.

FILE: The file path to process.

Returns: The project-relative or basename of the file without its extension,
         or `nil` if the file is invalid or cannot be processed."
  (unless (stringp file)
    (message "[scribe-entry] WARNING: Invalid file path for relative path derivation: %S" file)
    (cl-return-from scribe-entry--project-relative-file nil))

  (let* ((resolved-file (scribe-entry--resolve-source-path file))
         (canonical-file (f-canonical resolved-file))
         ;; Find the most specific project root
         (project-root (scribe-entry--find-project-root canonical-file))
         (relative-path canonical-file)) 

    (when (and project-root (string-prefix-p project-root canonical-file))
      ;; If within a project, make path relative to project root
      (setq relative-path (substring canonical-file (length project-root))))

    ;; Remove file extension and strip any leading slashes
    (let ((no-ext (file-name-sans-extension relative-path)))
      (replace-regexp-in-string "^/+" "" no-ext))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                Public API                                  ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun scribe-entry-prepare (fmt level trace data tags &rest args)
  "Format a structured log entry from FMT string and ARGS.

This function creates a `scribe-log-entry` object, populating its fields
by inspecting the call site via `scribe-context` and applying namespace
and file path derivation logic.

FMT: The format string for the main log message (like in `format`).
LEVEL: (symbol) The log level (e.g., 'info, 'error).
TRACE: (list of strings or string) Optional stack trace or additional details.
DATA: (plist or alist, optional) Structured payload for the log entry.
TAGS: (list of symbols, optional) Arbitrary categorization tags.
ARGS: Arguments for `FMT`.

Returns: A `scribe-log-entry` struct, or `nil` if essential information
         (like message formatting) fails."
  (condition-case err
      (let* ((raw-file (scribe-call-site-file scribe-context))
             ;; Resolve file to its source path and then get its project-relative path
             (file (when raw-file (scribe-entry--project-relative-file raw-file)))
             (fn   (scribe-call-site-fn scribe-context))
             (line (scribe-call-site-line scribe-context))
             ;; Resolve namespace using the potentially resolved source file path
             (namespace (when raw-file (scribe-entry--resolve-namespace raw-file)))
             (message (apply #'format fmt args))
             (timestamp (ts-now))) 
        (scribe--make-log-entry
         :level level
         :message message
         :timestamp timestamp
         :trace trace
         :file file
         :fn fn
         :line line
         :namespace namespace
         :data data
         :tags tags))
    (error
     (message "[scribe-entry] ERROR: Failed to prepare log entry: %S (FMT: %S, LEVEL: %S)"
              err fmt level)
     nil))) 

(provide 'scribe-entry)
;;; scribe-entry.el ends here