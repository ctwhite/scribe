;;; scribe-entry.el --- Structured log entry representation for Scribe -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library defines a structured representation of a "log entry" used by
;; the Scribe system. Each entry encapsulates a timestamp, location, project
;; association, tags, and a text payload, designed for serialization and
;; display in multiple formats.

;;; Code:

(require 'cl-lib)
(require 'f)
(require 'project)
(require 'scribe-context)
(require 'ts)
(require 'cacheus)


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Definitions and Variables

(cl-defstruct (scribe-log-entry (:constructor scribe--make-log-entry))
  "A structured log entry object with metadata.

  Slots:
  - `level` (symbol): Log level like 'error, 'info, etc.
  - `message` (string): Main log message.
  - `timestamp` (ts object): Timestamp of the entry.
  - `trace` (list): Optional list of strings for a trace block.
  - `file` (string): Path to the origin file, ideally project-relative.
  - `fn` (symbol): Function name where the log was generated.
  - `line` (number): Line number in the file.
  - `namespace` (symbol): Tag for grouping logs by context.
  - `data` (plist or alist): Optional structured payload.
  - `tags` (list): Optional list of symbols for categorization."
  level message timestamp trace file fn line namespace data tags)

(defvar scribe--in-log-preparation nil
  "A dynamic guard variable to prevent recursive logging calls.
This is set to `t` only within the `scribe-entry-prepare` function.
Helpers should check this variable to avoid calling back into systems
that might be in the process of logging an error.")

(defcustom scribe-entry-namespace nil
  "Fixed namespace (symbol) for all log entries.
If non-nil, this overrides `scribe-entry-namespace-function`."
  :type '(choice (const :tag "None" nil) (symbol :tag "Fixed symbol"))
  :group 'scribe)

(defcustom scribe-entry-namespace-function #'scribe-entry--project-namespace
  "Function to derive a dynamic namespace from a file path.
Used only if `scribe-entry-namespace` is nil."
  :type 'function
  :group 'scribe)


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(cacheus-memoize! scribe-entry--find-project-root (canonical-file)
  "Find the project root for a given CANONICAL-FILE.
This function is memoized by `cacheus-memoize!` to avoid expensive,
repeated filesystem lookups.

Arguments:
- `CANONICAL-FILE`: The canonical file path to find a project root for.

Returns:
The project root directory as a canonical string, or `nil`."
  :ttl 3600
  :capacity 100
  :key-fn (lambda (f) (f-canonical f))
  ;; RECURSION GUARD: This check is essential. If this function is ever called
  ;; during the process of preparing another log entry, we must immediately
  ;; return nil to prevent an infinite loop. The memoizer will correctly
  ;; cache this `nil` result for the recursive context.
  (when-not scribe--in-log-preparation
    (when (and canonical-file (stringp canonical-file) (fboundp 'project-current))
      (let ((project (project-current nil canonical-file)))
        (when project (project-root project))))))

(defun scribe-entry--project-relative-file (file)
  "Return FILE path relative to its project root, sans extension.
This function relies on the (now cached) `scribe-entry--find-project-root`.

Arguments:
- `FILE`: The file path to process.

Returns:
The project-relative or basename of the file without its extension, or
`nil` if the file is invalid."
  (when (and file (stringp file))
    (let* ((canonical-file (f-canonical file))
           (project-root (scribe-entry--find-project-root canonical-file))
           (relative-path canonical-file))
      (when (and project-root (string-prefix-p project-root canonical-file))
        (setq relative-path (substring canonical-file (length project-root))))
      (file-name-sans-extension relative-path))))

(defun scribe-entry--project-namespace (path)
  "Return a namespace symbol derived from the project name of PATH.

Arguments:
- `PATH`: The file path to find a project for.

Returns:
The project name as a symbol, or `nil`."
  (when-let ((root (scribe-entry--find-project-root path)))
    (intern (f-filename root))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

(defun scribe-entry-prepare (fmt level trace data tags &rest args)
  "Format a structured log entry from FMT string and ARGS.
This function creates a `scribe-log-entry` object by inspecting the call
site and applying namespace and file path derivation logic.

Arguments:
- `FMT`: The format string for the main log message.
- `LEVEL`: (symbol) The log level (e.g., 'info, 'error).
- `TRACE`: (list of strings or string) Optional stack trace.
- `DATA`: (plist or alist, optional) Structured payload.
- `TAGS`: (list of symbols, optional) Arbitrary categorization tags.
- `ARGS`: Arguments for `FMT`.

Returns:
A `scribe-log-entry` struct, or `nil` on failure."
  ;; Set the guard variable to `t` for the duration of this function call.
  (let ((scribe--in-log-preparation t))
    (condition-case err
        (let* ((raw-file (scribe-call-site-file scribe-context))
               (file (when raw-file (scribe-entry--project-relative-file raw-file)))
               (fn (scribe-call-site-fn scribe-context))
               (line (scribe-call-site-line scribe-context))
               (namespace (when raw-file
                            (or scribe-entry-namespace
                                (funcall scribe-entry-namespace-function raw-file))))
               (message (apply #'format fmt args))
               (timestamp (ts-now)))
          (scribe--make-log-entry
           :level level :message message :timestamp timestamp :trace trace
           :file file :fn fn :line line :namespace namespace :data data :tags tags))
      (error
       (message "[scribe-entry] ERROR: Failed to prepare log entry: %S (FMT: %S)"
                err fmt)
       nil))))

(provide 'scribe-entry)
;;; scribe-entry.el ends here