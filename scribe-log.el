;;; scribe-log.el --- Context-aware structured logging for Emacs -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This library provides context-aware, structured logging for Emacs, tailored to
;; support richer debugging, introspection, and auditability across projects and
;; user-defined scopes.
;;
;; Logs are represented as structured entries (see `scribe-entry.el`) which
;; capture metadata such as:
;; - Timestamp
;; - Log level (e.g., info, warn, error, debug)
;; - Project-relative path
;; - Caller context (function, file, point)
;; - Arbitrary key-value data
;;
;; Features:
;; - Hierarchical log levels with runtime filtering
;; - In-memory queueing and deferred flushing (see `scribe-queue.el`)
;; - Output formatting via `scribe-format.el` with enhanced visual clarity
;; - Context injection from `scribe-context.el` (e.g., current project, VC root)
;; - Optional log file rotation and retention
;; - `:important` flag for emphasized log messages.
;; - `:once` flag to log a message only once per session.
;; - `:throttle <seconds>` flag to rate-limit messages.
;; - `:tags <list-of-symbols>` for arbitrary categorization and filtering.
;; - Interactive filtering commands for the log buffer.
;; - **New: `scribe/log-filter-generic` for flexible, string-based filtering.**
;; - Robust error handling and target validation.
;;
;; Intended Use Cases:
;; - Debugging Emacs packages and workflows
;; - Recording structured traces for reproducibility
;; - Emacs-based tools that need runtime introspection or telemetry
;;
;; Integration:
;; - Output can be routed to files, buffers, or custom handlers
;; - Plays well with project-scoped behavior using `project.el`
;;
;; This module is the core engine behind the Scribe logging system.
;;
;;; Code:

(require 'cl-lib) ; Provides cl-incf
(require 'dash)
(require 'f)
(require 'scribe-context)
(require 'scribe-entry)
(require 'scribe-format)
(require 'scribe-queue)
(require 's); For string splitting and manipulation

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                       Global Variables & Group                             ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defconst *scribe-debug-p*
  "Non-nil if Scribe is in debug mode.
This is true when either the EMACS_DEBUG environment variable is set,
or Emacs is started with `init-file-debug` enabled. This flag
controls whether `log!` macro calls are processed at all."
  (or (getenv "EMACS_DEBUG") init-file-debug))

(defgroup scribe nil
  "Context-aware structured logger."
  :group 'tools)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                         Customization Options                              ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defcustom scribe-log-level
  (let ((level (or (getenv "EMACS_MSG_LEVEL") "")))
    (cond
     (*scribe-debug-p* 'debug) ; If debug mode, default to debug level
     ((string-match-p "^[1-4]$" level) ; Numeric level from environment
      (pcase (string-to-number level)
        (1 'error)
        (2 'warn)
        (3 'info)
        (4 'debug)
        (_ 'error))) ; Fallback for invalid numbers
     ((stringp level) ; String level from environment
      (intern (downcase level)))
     (t 'error))) ; Default if no environment variable or invalid
  "Log level as a symbol: 'error, 'warn, 'info, or 'debug.
Only messages with a level equal to or higher than this setting will be processed.
For example, if set to 'warn, 'error and 'warn messages will be logged,
but 'info and 'debug will be filtered out.

Accepts string, number, or symbol and normalizes to a symbol.
Numeric mappings: 1 -> error, 2 -> warn, 3 -> info, 4 -> debug."
  :group 'scribe
  :type '(choice
          (const :tag "Error (least verbose)" error)
          (const :tag "Warn"  warn)
          (const :tag "Info"  info)
          (const :tag "Debug (most verbose)" debug))
  :set (lambda (symbol value)
         (set symbol
              (pcase value
                ((pred symbolp) value) ; Already a symbol
                ((pred numberp) ; Numeric input
                 (pcase value
                   (1 'error)
                   (2 'warn)
                   (3 'info)
                   (4 'debug)
                   (_ 'error))) ; Invalid number defaults to error
                ((pred stringp) ; String input (e.g., from custom.el or env)
                 (pcase (downcase value)
                   ("1" 'error) ("error" 'error)
                   ("2" 'warn)  ("warn"  'warn)
                   ("3" 'info)  ("info"  'info)
                   ("4" 'debug) ("debug" 'debug)
                   (_ 'error)))
                (_ 'error))))) ; Any other type defaults to error

(defcustom scribe-log-buffer-name "*scribe-debug*"
  "Name of the Emacs buffer to which log entries are written when 'buffer target is active."
  :type 'string
  :group 'scribe)

(defcustom scribe-log-file-path nil
  "Path to file for optional file-based logging.
If nil, file logging is disabled."
  :type 'string
  :group 'scribe)

(defcustom scribe-log-file-max-size (* 1024 100)
  "Maximum size (in bytes) before log file rotation is triggered.
Rotation renames the current log file and starts a new one."
  :type 'integer
  :group 'scribe)

(defcustom scribe-log-file-backups 3
  "Number of log file backups to keep after rotation.
E.g., if 3, `log.1`, `log.2`, `log.3` will be kept."
  :type 'integer
  :group 'scribe)

(defcustom scribe-log-output-targets
  '((buffer . nil)) ; Default to logging to buffer with no specific filter
  "List of log output targets and their configuration.

Each entry is a cons cell of the form `(TARGET . PLIST)`, where:
- TARGET is one of:
  - 'buffer: log to `*scribe-debug*` buffer.
  - 'file: log to `scribe-log-file-path`.
  - 'messages: log via `message` (minibuffer).
  - function: A custom handler function taking a `scribe-log-entry` object.

The PLIST may contain:
- `:filter` — (Optional) A severity symbol ('error, 'warn, 'info, 'debug),
               a list of severity symbols, or a plist of filtering criteria.
               If a plist, it can contain:
                 - `:level` (symbol or list of symbols): Filters by log level.
                 - `:namespace` (symbol): Filters by exact namespace match.
                 - `:tags` (list of symbols): Filters if *any* entry tag matches *any* filter tag.
                 - `:message-regex` (string): Filters by regex match against the log message.
                 - `:predicate` (function): A custom predicate `(lambda (entry) ...)`
                                            that returns non-nil to log.
               If nil, all levels/entries are logged to this target.
- `:formatter` — (Optional) A function `(lambda (entry) ...)` to format
                  the entry specifically for this target. Defaults to `scribe-format`.
- Other keys for future extensions."
  :type
  '(alist
    :key-type (choice
               (const buffer)
               (const file)
               (const messages)
               (function :tag "Custom function"))
    :value-type (plist
                 :key-type (choice
                            (const :filter)
                            (const :formatter))
                 :value-type
                 (choice
                  (function :tag "Predicate") ; Old style direct predicate
                  (symbol :tag "Severity (e.g., error)") ; Old style direct level
                  (repeat symbol) ; Old style list of levels
                  (plist :tag "Filter Criteria" ; New plist filter
                         :key-type (choice (const :level) (const :namespace)
                                           (const :tags) (const :message-regex)
                                           (const :predicate))
                         :value-type (choice
                                      (function :tag "Predicate")
                                      (symbol :tag "Severity")
                                      (repeat symbol)
                                      string))) ; For message-regex
                  (function :tag "Formatter function")))
  :group 'scribe)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                   Internal Variables (Trackers & Filters)                  ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar scribe-log--once-tracker (make-hash-table :test 'equal)
  "Hash table to store IDs of messages logged with `:once` to ensure they are logged only once.
Keys are the unique IDs, values are `t` once logged.")

(defvar scribe-log--throttle-tracker (make-hash-table :test 'equal)
  "Hash table to store timestamps of last log for messages with `:throttle` to rate-limit them.
Keys are the unique IDs, values are float timestamps.")

(defvar scribe-log--current-buffer-filter nil
  "Plist containing the active filter criteria for the `*scribe-debug*` buffer.
This filter is applied interactively by user commands.
Structure is similar to the `:filter` plist in `scribe-log-output-targets`.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                             Internal Helpers                               ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun scribe-log--should-log? (entry filter)
  "Return non-nil if ENTRY passes the given FILTER.

FILTER can be:
- nil: log unconditionally (no filtering).
- function: a predicate `(lambda (entry) ...)` called with `ENTRY`.
- symbol: matches entry's severity exactly.
- list: contains entry's severity.
- plist: a filter plist containing `:level`, `:namespace`, `:tags`, `:message-regex`, `:predicate`.
  All specified criteria in the plist must match for the entry to pass.

Ensures robust and flexible filtering logic."
  (let ((severity (scribe-log-entry-level entry))
        (entry-namespace (scribe-log-entry-namespace entry))
        (entry-tags (scribe-log-entry-tags entry))
        (entry-message (scribe-log-entry-message entry))) ; Get message for regex filtering
    (cond
     ((null filter) t) ; No filter specified, always log

     ;; Handle old-style direct function/symbol/list filters
     ((functionp filter)
      (condition-case err
          (funcall filter entry)
        (error (message "[scribe] ERROR: Filter function failed for entry %S: %S" entry err) nil)))
     ((symbolp filter) (eq severity filter))
     ((and (listp filter) (memq severity filter)))

     ;; Handle new-style plist filters
     ((plistp filter)
      (let ((level-filter (plist-get filter :level))
            (namespace-filter (plist-get filter :namespace))
            (tags-filter (plist-get filter :tags))
            (predicate-filter (plist-get filter :predicate))
            (message-regex-filter (plist-get filter :message-regex))) ; New regex filter
        (and
         ;; Level filter check
         (or (null level-filter)
             (and (symbolp level-filter) (eq severity level-filter))
             (and (listp level-filter) (memq severity level-filter)))
         ;; Namespace filter check
         (or (null namespace-filter)
             (and entry-namespace (eq entry-namespace namespace-filter)))
         ;; Tags filter check (match if any entry tag is in filter tags)
         (or (null tags-filter)
             (and entry-tags tags-filter (--any? (memq it tags-filter) entry-tags)))
         ;; Message regex filter check
         (or (null message-regex-filter)
             (and (stringp entry-message) (string-match-p message-regex-filter entry-message)))
         ;; Predicate filter check
         (or (null predicate-filter)
             (and (functionp predicate-filter)
                  (condition-case err
                      (funcall predicate-filter entry)
                    (error
                     (message "[scribe] ERROR: Predicate filter function failed for entry %S: %S" entry err)
                     nil)))))))
     (t nil)))) ; Unknown filter type, do not log

(defun scribe-log--filter? (level)
  "Return non-nil if LEVEL is allowed by `scribe-log-level`.
This implements the hierarchical filtering based on the configured `scribe-log-level`."
  (let* ((level-map '((error . 1)
                      (warn  . 2)
                      (info  . 3)
                      (debug . 4)))
         (lvl-val (or (cdr (assoc level level-map)) 0)) ; Value of current message's level
         (cur-val (or (cdr (assoc scribe-log-level level-map)) 0))) ; Value of configured log level
    (>= cur-val lvl-val))) ; Log if current level is higher or equal to message level

(defun scribe-log--rotate ()
  "Rotate the log file if it exceeds `scribe-log-file-max-size`.
This function renames existing log files to create backups and starts a new,
empty log file. Handles potential file operation errors gracefully."
  (when (and scribe-log-file-path
             (file-exists-p scribe-log-file-path)
             (> (f-size scribe-log-file-path) scribe-log-file-max-size))
    (message "[scribe] Rotating log file: %S" scribe-log-file-path)
    (condition-case err
        (let ((base scribe-log-file-path))
          ;; Shift existing backups (e.g., .1 -> .2, .2 -> .3)
          (dotimes (i scribe-log-file-backups)
            (let* ((n (- scribe-log-file-backups i))
                   (src (format "%s.%d" base (1- n)))
                   (dst (format "%s.%d" base n)))
              (when (file-exists-p src)
                (f-move src dst))))
          ;; Move current log file to .1
          (f-move base (format "%s.1" base))
          ;; Create a new empty log file
          (f-touch base))
      (error
       (message "[scribe] ERROR: Log file rotation failed for %S: %S"
                scribe-log-file-path err)))))

(defun scribe-log--refresh-buffer-display ()
  "Clears the `*scribe-debug*` buffer and re-populates it with filtered log entries.
This function is called after interactive filter changes."
  (when-let ((buf (get-buffer-create scribe-log-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer))
      (goto-char (point-min))) ; Go to beginning for re-insertion

    ;; Iterate through entries in the queue buffer and re-insert if they pass the filter
    (let ((all-queued-entries (ring-elements scribe-queue--buffer)))
      (--each all-queued-entries
        (let* ((entry (scribe-queue-entry-val it))
               (count (scribe-queue-entry-count it))
               (is-important (plist-get (scribe-log-entry-data entry) :important))
               (count-prefix (if (and count (> count 1)) (format "[x%d] " count) "")))
          (when (scribe-log--should-log? entry scribe-log--current-buffer-filter)
            (let* ((formatted-output (scribe-format entry)) ; Use default formatter for refresh
                   (final-output (concat count-prefix formatted-output)))
              (when is-important
                (setq final-output (propertize final-output 'face 'bold)))
              (with-current-buffer (get-buffer-create scribe-log-buffer-name)
                (goto-char (point-max))
                (insert final-output "\n")))))))))

(defun scribe-log--dispatch (queue-entry)
  "Dispatch QUEUE-ENTRY to all appropriate logging targets.

Extracts the wrapped `scribe-log-entry` from QUEUE-ENTRY and dispatches
to the logging targets based on their configuration and filters.
Applies additional highlighting for `:important` entries.

Supported targets:
- 'buffer    -> `*scribe-debug*` buffer
- 'file      -> file logging with rotation
- 'messages  -> minibuffer
- function   -> custom handler (receives `scribe-log-entry`)"
  (let* ((entry (scribe-queue-entry-val queue-entry))
         (count (scribe-queue-entry-count queue-entry))
         (is-important (plist-get (scribe-log-entry-data entry) :important))
         (count-prefix (if (and count (> count 1)) (format "[x%d] " count) "")))

    (--each scribe-log-output-targets
      (-let [(target . config-plist) it]
        ;; Apply both target-specific filter AND the interactive buffer filter for 'buffer target
        (when (and (scribe-log--should-log? entry (plist-get config-plist :filter))
                   (or (not (eq target 'buffer)) ; Always dispatch if not buffer, or if buffer and passes interactive filter
                       (scribe-log--should-log? entry scribe-log--current-buffer-filter)))
          (let* ((formatter (or (plist-get config-plist :formatter) #'scribe-format))
                 (formatted-output (condition-case err
                                       (funcall formatter entry) ; Use the specified formatter
                                     (error
                                      (message "[scribe] ERROR: Formatter %S failed for entry %S: %S"
                                               formatter (scribe-log-entry-message entry) err)
                                      (format "[FORMAT_ERROR] %S" (scribe-log-entry-message entry)))))
                 (final-output (concat count-prefix formatted-output)))

            ;; Apply bolding/highlighting for :important flag
            (when is-important
              ;; Use `face 'bold` property for maximum emphasis
              (setq final-output (propertize final-output 'face 'bold)))

            (pcase target
              ('buffer
               (with-current-buffer (get-buffer-create scribe-log-buffer-name)
                 (goto-char (point-max))
                 (insert final-output "\n")))
              ('file
               (scribe-log--rotate) ; Rotate file before appending
               (when scribe-log-file-path
                 (condition-case err
                     (f-append-text (concat final-output "\n") 'utf-8 scribe-log-file-path)
                   (error
                    (message "[scribe] ERROR: Failed to write to log file %S: %S"
                             scribe-log-file-path err)))))
              ('messages
               (message "%s" final-output)) ; `message` handles its own newline
              ((pred functionp)
               (condition-case err
                   (funcall target entry) ; Custom handler receives the raw entry
                 (error
                  (message "[scribe] ERROR: Custom log target function %S failed for entry %S: %S"
                           target (scribe-log-entry-message entry) err))))
              (_
               (message "[scribe] WARNING: Unknown log output target '%S'. Entry %S not dispatched."
                        target (scribe-log-entry-message entry))))))))))

(defun scribe-log--enqueue (fmt level trace data tags once-id throttle-seconds namespace &rest args)
  "Format a log message and enqueue it for dispatch.
This function prepares the `scribe-log-entry` and passes it to the queue
for asynchronous processing. It also handles `:once` and `:throttle` logic.

FMT: The format string for the main log message.
LEVEL: The log level symbol (e.g., 'info, 'warn).
TRACE: The trace information (string or list of strings).
DATA: An alist or plist of additional structured data for the entry.
TAGS: (list of symbols, optional) Arbitrary categorization tags.
ONCE-ID: (any, optional) A unique ID for `:once` logging.
THROTTLE-SECONDS: (number, optional) Seconds for `:throttle` logging.
NAMESPACE: (symbol, optional) An explicitly provided namespace to override auto-detection.
ARGS: Arguments for `FMT`."
  
  ;; Handle :once logic
  (when once-id
    (when (gethash once-id scribe-log--once-tracker)
      (message "[scribe] Skipping log (once-id '%S' already logged)." once-id)
      (cl-return-from scribe-log--enqueue nil))
    (puthash once-id t scribe-log--once-tracker))

  ;; Handle :throttle logic
  (when (and throttle-seconds once-id) ; Throttle requires an ID
    (let ((now (float-time))
          (last-log-ts (gethash once-id scribe-log--throttle-tracker)))
      (when (and last-log-ts (< (- now last-log-ts) throttle-seconds))
        (message "[scribe] Skipping log (throttled for '%S')." once-id)
        (cl-return-from scribe-log--enqueue nil))
      (puthash once-id now scribe-log--throttle-tracker)))

  ;; Dynamically bind `scribe-entry-namespace` if provided
  (let ((scribe-entry-namespace (or namespace scribe-entry-namespace))) ; Prioritize explicit namespace
    (let ((entry (apply #'scribe-entry-prepare fmt level trace data tags args))) ; Pass tags to prepare
      (when entry ; Only enqueue if entry preparation was successful
        (scribe-queue-enqueue-and-dispatch entry #'scribe-log--dispatch)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                              Public API                                    ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defmacro log! (&rest args)
  "Structured logging macro with support for level, trace, and format.

This macro wraps `scribe--log!`, providing a concise and flexible
interface for logging messages with optional metadata.

Supported arguments (can be mixed order, but format string and its args
must appear consecutively at the end):
  - `:level <symbol>`     — Explicit log level (e.g., :level 'warn)
  - `:<level>`            — Shorthand for log level (e.g., :warn, :debug, :error)
  - `:trace`              — If present, includes a backtrace in the log.
  - `:important`          — If present, highlights the log message for emphasis.
  - `:data <plist>`       — Additional structured data (plist or alist) for the entry.
  - `:tags <list-of-symbols>` — Arbitrary categorization tags (e.g., '(:ui :network)).
  - `:once <id>`          — Log this message only once per Emacs session. `id` can be any unique value.
  - `:throttle <seconds>` — Log this message at most once every `seconds`. Requires `:once <id>`
                             to identify the throttled message.
  - Format string and arguments — The first non-keyword argument is the
                                 format string, followed by `format` args.

Examples:
  (log! :warn \"Something went wrong: %s\" err)
  (log! :info :trace \"Starting step: %s\" step-name)
  (log! :error :important \"Critical failure in %s!\" component)
  (log! :debug :data '(:user \"john\" :id 123) \"User action: %s\" action)
  (log! :info :once 'startup-message \"Scribe initialized.\")
  (log! :debug :throttle 5 :once 'network-poll \"Polling network...\")
  (log! :info :tags '(:ui :event) \"Button clicked: %s\" button-name)"
  (declare (indent 0)
           (debug t))
  (let ((level 'debug)        
        (trace nil)           
        (important-p nil)     
        (additional-data nil) 
        (tags nil)            
        (once-id nil)         
        (throttle-seconds nil)
        (clean-args '())      
        (level-keywords '(:debug :info :warn :error :fatal)))

    ;; Parse keyword args
    (while args
      (let ((x (pop args)))
        (cond
         ((eq x :trace) (setq trace t))
         ((eq x :important) (setq important-p t))
         ((eq x :data)
          (when (consp args) (setq additional-data (pop args))))
         ((eq x :tags)
          (when (consp args) (setq tags (pop args))))
         ((eq x :once)
          (when (consp args) (setq once-id (pop args))))
         ((eq x :throttle)
          (when (consp args) (setq throttle-seconds (pop args))))
         ((eq x :level)
          (when (consp args)
            (let ((val (pop args)))
              (setq level (if (and (consp val) (eq (car val) 'quote))
                              (cadr val)
                            val)))))
         ((memq x level-keywords)
          (setq level (intern (substring (symbol-name x) 1))))
         ;; Remaining are treated as format string and arguments
         (t 
          (push x clean-args)))))
    
    ;; Restore original order for format args          
    (setq clean-args (nreverse clean-args)) 

    ;; Normalize `additional-data` to plist before mutating
    (let* ((fmt (car clean-args))
           (fmt-args (cdr clean-args))
           (backtrace-string (when trace (with-output-to-string (backtrace))))
           (data-plist
            (cond
             ((null additional-data) nil)
             ((and (listp additional-data)
                   (keywordp (car additional-data))) additional-data) ; already a plist
             ((and (listp additional-data)) (--mapcat (list (car it) (cdr it)) additional-data)) ; alist -> plist
             (t nil)))
           (final-data (if important-p
                           (plist-put (copy-sequence data-plist) :important t)
                         data-plist)))

      `(when (and *scribe-debug-p*
                  (scribe-log--filter? ',level))
         (with-scribe-context!
           (scribe-log--enqueue
            ,fmt
            ',level
            ,backtrace-string
            ',final-data 
            ,tags
            ,once-id
            ,throttle-seconds
            nil 
            ,@fmt-args))))))

;;;###autoload
(defun scribe/set-log-level ()
  "Interactively set the `scribe-log-level` variable.

Prompts the user to select a log level from the following options:
Error, Warn, Info, Debug. The selected log level is then applied to
the `scribe-log-level` variable, which determines the verbosity of log
output."
  (interactive)
  (let* ((choices '(("Error" . error)
                    ("Warn"  . warn)
                    ("Info"  . info)
                    ("Debug" . debug)))
         (choice (completing-read "Set Scribe log level: " (mapcar #'car choices) nil t)))
    (when-let* ((sym (cdr (assoc choice choices))))
      (setq scribe-log-level sym)
      (message "Scribe log level set to `%s`" sym))))

;;;###autoload
(defun scribe/log-open ()
  "Open the debug log buffer, loading content from a file if file logging is active.

If 'buffer is an active output target, it opens `scribe-log-buffer-name`.
If 'file is an active output target and `scribe-log-file-path` is set,
it loads the file content into the buffer.
If both are enabled, it prefers the buffer. For other output types, it shows a warning."
  (interactive)
  (let ((buffer-target-active (assoc 'buffer scribe-log-output-targets))
        (file-target-active (assoc 'file scribe-log-output-targets)))
    (cond
     (buffer-target-active
      (pop-to-buffer scribe-log-buffer-name)
      (goto-char (point-max)))

     (file-target-active
      (if (and scribe-log-file-path (file-readable-p scribe-log-file-path))
          (let ((file-content (f-read-text scribe-log-file-path 'utf-8)))
            (pop-to-buffer scribe-log-buffer-name)
            (erase-buffer)
            (insert file-content)
            (goto-char (point-max)))
        (user-error "Scribe log file not found or not readable: %s" scribe-log-file-path)))

     (t
      (message "Scribe log output is not directed to a buffer or file; nothing to display.")))))

;;;###autoload
(defun scribe/log-clear ()
  "Clear all log output targets: buffer and/or file.

If 'buffer is an active output target, the log buffer is cleared.
If 'file is an active output target, the file contents are erased.
Other targets (e.g., 'messages or custom functions) are non-persistent and ignored."
  (interactive)
  (let ((cleared nil))
    (when (assoc 'buffer scribe-log-output-targets)
      (when-let* ((buf (get-buffer scribe-log-buffer-name)))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (setq cleared t)))))

    (when (assoc 'file scribe-log-output-targets)
      (when scribe-log-file-path
        (condition-case err
            (f-write "" 'utf-8 scribe-log-file-path)
          (error
           (message "[scribe] ERROR: Failed to clear log file %S: %S"
                    scribe-log-file-path err)))
        (setq cleared t)))

    (unless cleared
      (message "Scribe log output is not directed to a buffer or file; nothing to clear."))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                         Interactive Filtering                              ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun scribe-log--parse-filter-string (filter-string)
  "Parse a filter string into a plist of filter criteria.
Format: `key=value,key2=value2,...`
Supported keys: `level`, `namespace`, `tags`, `message-regex`.
`level` can be a single symbol (e.g., `info`) or comma-separated (e.g., `warn,error`).
`tags` can be comma-separated symbols (e.g., `ui,network`).
`namespace` is a single symbol.
`message-regex` is a string.

Returns: A plist of filter criteria, or nil if the string is empty or invalid."
  (let ((filter-plist nil))
    (when (stringp filter-string)
      (dolist (part (s-split "," filter-string t))
        (let* ((key-value (s-split "=" part))
               (key-str (car key-value))
               (value-str (cadr key-value)))
          (cond
           ((s-blank? key-str)
            (message "[scribe] WARNING: Empty filter key in '%s'." part))
           ((s-blank? value-str)
            (message "[scribe] WARNING: Empty filter value for key '%s'." key-str))
           (t
            (pcase (intern (downcase key-str))
              ('level
               (let ((levels (mapcar #'intern (s-split "," value-str t))))
                 (setq filter-plist (plist-put filter-plist :level (if (= (length levels) 1) (car levels) levels)))))
              ('namespace
               (setq filter-plist (plist-put filter-plist :namespace (intern (downcase value-str)))))
              ('tags
               (setq filter-plist (plist-put filter-plist :tags (mapcar #'intern (s-split "," value-str t)))))
              ('message-regex
               (setq filter-plist (plist-put filter-plist :message-regex value-str)))
              (_
               (message "[scribe] WARNING: Unknown filter key '%s'." key-str)))))))
    filter-plist)))

;;;###autoload
(defun scribe/log-filter ()
  "Interactively filter the `*scribe-debug*` buffer using a generic filter string.
The filter string should be a comma-separated list of key-value pairs.
Example: `level=warn,tags=ui,namespace=my-app,message-regex=.*error.*`

Supported keys:
- `level`: Log level (e.g., `info`, `warn`, `error`, `debug`). Can be comma-separated for multiple levels (e.g., `warn,error`).
- `namespace`: Exact namespace symbol (e.g., `my-package`).
- `tags`: Comma-separated list of tag symbols (e.g., `ui,network`). Matches if *any* entry tag is in this list.
- `message-regex`: A regular expression string to match against the log message.

Entering an empty string will clear the filter.
This function *replaces* the current buffer filter."
  (interactive)
  (let* ((filter-input (read-from-minibuffer "Enter generic log filter (key=value,key2=value2,... or ENTER to clear): "))
         (new-filter (scribe-log--parse-filter-string filter-input)))
    (setq scribe-log--current-buffer-filter new-filter)
    (message "Scribe log buffer filter: %S" (or new-filter "Cleared"))
    (scribe-log--refresh-buffer-display)))

;;;###autoload
(defun scribe/log-filter-by-level ()
  "Interactively filter the `*scribe-debug*` buffer by log level.
Only entries with the selected level or higher will be displayed."
  (interactive)
  (let* ((choices '(("Error" . error) ("Warn" . warn) ("Info" . info) ("Debug" . debug)))
         (choice (completing-read "Filter log by level (or ENTER to clear): "
                                  (mapcar #'car choices) nil t)))
    (setq scribe-log--current-buffer-filter
          (plist-put scribe-log--current-buffer-filter
                     :level (when (not (s-blank? choice)) (cdr (assoc choice choices)))))
    (message "Scribe log buffer filter: Level %s" 
          (or (plist-get scribe-log--current-buffer-filter :level) "None"))
    (scribe-log--refresh-buffer-display)))

;;;###autoload
(defun scribe/log-filter-by-namespace ()
  "Interactively filter the `*scribe-debug*` buffer by namespace.
Only entries matching the exact namespace will be displayed."
  (interactive)
  (let ((namespace-str (read-from-minibuffer "Filter log by namespace (or ENTER to clear): ")))
    (setq scribe-log--current-buffer-filter
          (plist-put scribe-log--current-buffer-filter
                     :namespace (when (not (s-blank? namespace-str)) (intern namespace-str))))
    (message "Scribe log buffer filter: Namespace %s" 
          (or (plist-get scribe-log--current-buffer-filter :namespace) "None"))
    (scribe-log--refresh-buffer-display)))

;;;###autoload
(defun scribe/log-filter-by-tag ()
  "Interactively filter the `*scribe-debug*` buffer by tags.
Only entries that have at least one of the specified tags will be displayed.
Enter tags as space-separated symbols (e.g., `ui network`)."
  (interactive)
  (let* ((tags-input (read-from-minibuffer "Filter log by tags (space-separated symbols, or ENTER to clear): "))
         (tags-list (when (not (s-blank? tags-input))
                      (mapcar #'intern (s-split " " tags-input t)))))
    (setq scribe-log--current-buffer-filter
          (plist-put scribe-log--current-buffer-filter
                     :tags tags-list))
    (message "Scribe log buffer filter: Tags %S" (or tags-list "None"))
    (scribe-log--refresh-buffer-display)))

;;;###autoload
(defun scribe/log-filter-by-message-regex ()
  "Interactively filter the `*scribe-debug*` buffer by a message regex.
Only entries whose message matches the regular expression will be displayed."
  (interactive)
  (let ((regex-str (read-from-minibuffer "Filter log by message regex (or ENTER to clear): ")))
    (setq scribe-log--current-buffer-filter
          (plist-put scribe-log--current-buffer-filter
                     :message-regex (when (not (s-blank? regex-str)) regex-str)))
    (message "Scribe log buffer filter: Message Regex %s" 
          (or (plist-get scribe-log--current-buffer-filter :message-regex) "None"))
    (scribe-log--refresh-buffer-display)))

;;;###autoload
(defun scribe/log-clear-buffer-filter ()
  "Clears all active interactive filters for the `*scribe-debug*` buffer."
  (interactive)
  (setq scribe-log--current-buffer-filter nil)
  (message "Scribe log buffer filter cleared.")
  (scribe-log--refresh-buffer-display))

;;;###autoload
(defun scribe/log-reset-once-flags ()
  "Resets all 'log once' flags, allowing messages marked with `:once` to be logged again.
This clears the internal `scribe-log--once-tracker`."
  (interactive)
  (clrhash scribe-log--once-tracker)
  (message "Scribe 'log once' flags reset."))

;;;###autoload
(defun scribe/log-reset-throttles ()
  "Resets all throttled log messages, allowing them to be logged immediately.
This clears the internal `scribe-log--throttle-tracker`."
  (interactive)
  (clrhash scribe-log--throttle-tracker)
  (message "Scribe throttles reset."))

;; Add a hook to flush all pending logs on Emacs exit
(add-hook 'kill-emacs-hook #'scribe-queue-flush-all)

(provide 'scribe-log)
;;; scribe-log.el ends here