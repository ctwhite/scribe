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
(require 'cacheus-memoize) ; NEW: Required for cacheus-memoize!

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Log Entry Structure ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(cl-defstruct (scribe-log-entry (:constructor scribe--make-log-entry))
  "A structured log entry object with metadata.

  Fields:

  `level` (symbol): Log level like 'error, 'info, etc.
  `message` (string): Main log message.
  `timestamp` (ts object): Timestamp as a `ts` n-tuple `(SECONDS MICROSECONDS)`.
  `trace` (list): Optional list of strings representing a trace block.
  `file` (string): Full path to the origin file, potentially project-relative.
  `fn` (symbol): Function name where the log was generated.
  `line` (number): Line number in the file.
  `namespace` (symbol): Tag used to group logs by context, often derived from project.
  `data` (plist or alist): Optional structured payload.
  `tags` (list): Optional list of symbols for arbitrary categorization."

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
;; Customization Variables ;;
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
;; Internal Helpers ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun scribe-entry--resolve-source-path (file)
  "Resolve the given FILE path to its original source path using `scribe-source-root-mapping`.
  This is crucial for correctly identifying source locations when a package is
  installed (e.g., in `elpa/`) but its source is elsewhere.

  FILE: The path to resolve (e.g., from `this-command-file`).

  Returns: The resolved source path as a canonical string, or the original FILE
  if no mapping applies or an error occurs."
  (cl-block scribe-entry--resolve-source-path
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
         canonical-file))))) ; Fallback to canonical file on error

;; Replaced cl-defmemo with cacheus-memoize! for advanced caching features
(cacheus-memoize! scribe-entry--find-project-root (canonical-file)
  "Find the most specific project root for CANONICAL-FILE.
  Prioritizes:
  1. `project-current` for the file's directory.
  2. Upward search for project markers (controlled by `scribe-entry-fallback-project-detection-depth`).

  CANONICAL-FILE: The canonical path to the file (already resolved to its source location).

  Returns: The canonical path of the project root (string), or `nil` if no unique,
  clear match is found or if `project.el` is not loaded."
  ;; Cacheus-memoize! options for scribe-entry--find-project-root
  :capacity 100 ; Store up to 100 project roots
  :ttl 3600    ; Cache results for 1 hour (3600 seconds)
  :eviction-strategy :lru ; Use Least Recently Used eviction
  :key-fn (lambda (f) (f-canonical f)) ; Ensure the key is the canonical file path
  (cl-block scribe-entry--find-project-root
    (unless (stringp canonical-file) (cl-return-from scribe-entry--find-project-root nil))

    ;; Ensure project.el is loaded before attempting any project-related functions
    (unless (fboundp 'project-current) ; Check for a core project.el function
      (message "[scribe-entry] DEBUG: project.el not loaded. Cannot use project detection features.")
      (cl-return-from scribe-entry--find-project-root nil))

    ;; 1. Try to get the project directly using `project-current` for the file's directory
    (let* ((file-dir (f-dirname canonical-file))
           (current-project (condition-case err
                                (project-current file-dir)
                              (error
                               ;; Log the error but don't prevent fallback
                               (message "[scribe-entry] ERROR: project-current failed for %S: %S" file-dir err)
                               nil))))
      (when current-project
        (let ((root (project-root current-project)))
          (message "[scribe-entry] DEBUG: project-current found root for %S: %S."
                   canonical-file root)
          ;; Ensure the root is canonical before returning
          (cl-return-from scribe-entry--find-project-root (f-canonical root)))))

    ;; 2. If `project-current` didn't find a project, perform upward search for project markers
    (when (and (numberp scribe-entry-fallback-project-detection-depth)
               (> scribe-entry-fallback-project-detection-depth 0)
               (fboundp 'project-project-p))
      (message "[scribe-entry] DEBUG: project-current did not find a project. Attempting fallback upward detection for %S (depth: %d)."
               canonical-file scribe-entry-fallback-project-detection-depth)
      (let ((current-dir (f-dirname canonical-file))
            (depth 0))
        ;; Loop upwards until root is found or max depth is reached
        (while (and current-dir (<= depth scribe-entry-fallback-project-detection-depth))
          (condition-case err
              (when (project-project-p current-dir)
                (let ((root (f-canonical current-dir)))
                  (message "[scribe-entry] DEBUG: Fallback upward project root found for %S: %S."
                           canonical-file root)
                  (cl-return-from scribe-entry--find-project-root root)))
            (error
             ;; Log the error but continue moving up
             (message "[scribe-entry] ERROR: Fallback project detection failed for directory %S: %S"
                      current-dir err)))
          (setq current-dir (f-dirname current-dir)) ; Move up one directory
          (cl-incf depth))))

    ;; 3. Final fallback if no project root found by any method
    (message "[scribe-entry] DEBUG: No project root found for %S after all attempts."
             canonical-file)
    nil))

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
  (cl-block scribe-entry--project-relative-file
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
  )

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API ;;
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
             (fn (scribe-call-site-fn scribe-context))
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
