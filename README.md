# Scribe.el - Context-Aware Structured Logging for Emacs

`scribe.el` provides a suite of composable, context-aware, and structured logging primitives for Emacs Lisp. It is inspired by modern logging frameworks and aims to simplify debugging, introspection, and auditability across Emacs projects and user-defined scopes.

## Key Features

* **Structured Logging**: Log entries are rich data structures (`scribe-entry.el`) capturing timestamp, level, message, caller context, and arbitrary key-value data.
* **Context Awareness**: Automatically captures call-site information including project-relative path, function name, source file, line number, buffer, and point (`scribe-context.el`).
* **Hierarchical Log Levels**: Supports standard levels (`:error`, `:warn`, `:info`, `:debug`, `:trace`) with runtime filtering based on `scribe-log-level`.
* **Multiple Output Targets**: Route logs to various destinations simultaneously:
  * Emacs buffer (`*scribe-debug*`).
  * Log files with automatic rotation and backup management.
  * Emacs `message` area.
  * Custom user-defined handler functions.
* **Asynchronous Queueing & Batching (`scribe-queue.el`)**:
  * Efficient in-memory ring buffer for log entries.
  * Configurable flush strategies (`immediate`, `burst`, `idle`, `hybrid`).
  * Deduplication of consecutive identical log entries.
  * Optional entry expiration and purging.
  * Configurable overflow handling (`drop-oldest`, `drop-newest`, `block`, `delegate`).
  * Dispatch retries for transient output failures.
* **Advanced Log Control**:
  * `:important` flag for visually emphasized log messages.
  * `:once <id>` flag to log a specific message only once per Emacs session.
  * `:throttle <seconds> :once <id>` flag to rate-limit specific messages.
  * `:tags <list>` for arbitrary categorization and filtering.
* **Flexible Filtering**:
  * Global filtering by `scribe-log-level`.
  * Per-target filtering based on level, namespace, tags, message regex, or custom predicates.
  * Interactive filtering commands for the log buffer (`scribe/log-filter`, `scribe/log-filter-by-level`, etc.).
* **Formatting**: Customizable log entry formatting via `scribe-format.el`.

## Core Components

The Scribe logging system is modular:

* **`scribe-log.el`**: The core logging engine. Manages log levels, output targets, filtering, and provides the main `log!` macro.
* **`scribe-entry.el`**: Defines the structure of a log entry (`scribe-log-entry`) and functions for preparing it.
* **`scribe-context.el`**: Handles the capture of call-site context (function name, file, line, buffer, point).
* **`scribe-queue.el`**: Implements the asynchronous, batched queueing mechanism for log entries.
* **`scribe-format.el`**: Provides functions for formatting log entries into human-readable strings.

## Basic Usage

After installation, you can start logging using the `log!` macro. It's recommended to `(require 'scribe-log)` or your main `scribe.el` package file.

```emacs-lisp
(require 'scribe-log) ; Or your main package file, e.g., (require 'scribe)

;; Simple informational message
(log! :info "Application started successfully.")

;; Warning message
(log! :warn "User input validation failed: %S" user-input)

;; Error message with a backtrace
(condition-case err
    (do-something-risky)
  (error (log! :error "A critical error occurred: %S" err :trace)))

;; Debug message with structured data
(log! :debug "Processing item" :data `(:item-id ,id :item-value ,value))

;; Important message
(log! :info :important "User preferences saved!")

;; Log once per session
(log! :info :once 'my-package-initialization "MyPackage initialized for the first time this session.")

;; Throttle a frequent message (logs at most once every 5 seconds)
(log! :debug :throttle 5 :once 'my-package-poll "Polling for updates...")

;; Logging with tags
(log! :info :tags '(:network :user-action) "User %s initiated download from %s" user-id url)
```

## Configuration

Scribe offers several customization options via `M-x customize-group RET scribe RET`.

### Log Level

Set the global minimum log level.

```emacs-lisp
(setq scribe-log-level :info) ; Log :info, :warn, :error, :fatal
;; (setq scribe-log-level 'debug) ; Log everything
```

### Output Targets

Configure where logs go and how they are filtered/formatted per target.

```emacs-lisp
(setq scribe-log-output-targets
      '(;; Log to *scribe-debug* buffer, only info and higher
        (buffer . (:filter :info)) 

        ;; Log errors and warnings to a file
        (file . (:filter (:level (error warn))
                   :formatter my-custom-file-formatter-fn))

        ;; Log important debug messages to the *Messages* buffer
        (messages . (:filter (:level debug :predicate (lambda (entry) (plist-get (scribe-log-entry-data entry) :important)))))))
```

### File Logging

If using the `file` target:

```emacs-lisp
(setq scribe-log-file-path "~/.emacs.d/logs/scribe.log")
(setq scribe-log-file-max-size (* 1024 1024)) ; 1 MB
(setq scribe-log-file-backups 5)
```

### Queue Configuration

Customize the behavior of the asynchronous logging queue (from `scribe-queue.el`):

```emacs-lisp
(setq scribe-queue-size 500) ; Max entries in memory
(setq scribe-queue-flush-method 'hybrid) ; Default: burst and idle
(setq scribe-queue-burst-flush-threshold 20)
(setq scribe-queue-idle-timeout 1.5) ; seconds
(setq scribe-queue-max-batch-latency 10.0) ; seconds
;; (setq scribe-queue-silenced-predicates '(...))
;; (setq scribe-queue-overflow-strategy 'drop-oldest)
```

## Interactive Commands

Scribe provides several interactive commands for managing and viewing logs:

* `scribe/set-log-level`: Interactively set the global log level.
* `scribe/log-open`: Open the `*scribe-debug*` buffer (and load from file if applicable).
* `scribe/log-clear`: Clear the log buffer and/or log file.
* `scribe/log-filter`: Apply a generic filter string (e.g., `level=warn,tags=ui`) to the log buffer.
* `scribe/log-filter-by-level`: Interactively filter the log buffer by severity level.
* `scribe/log-filter-by-namespace`: Filter by namespace.
* `scribe/log-filter-by-tag`: Filter by tags.
* `scribe/log-filter-by-message-regex`: Filter messages using a regular expression.
* `scribe/log-clear-buffer-filter`: Clear all interactive filters on the log buffer.
* `scribe/log-reset-once-flags`: Reset all `:once` flags, allowing those messages to log again.
* `scribe/log-reset-throttles`: Reset all throttled messages, allowing them to log immediately.

## Advanced Usage & Extension

* **Custom Output Targets**: Define your own function that takes a `scribe-log-entry` object and add it to `scribe-log-output-targets`.
* **Custom Formatters**: Provide a custom formatting function via the `:formatter` key in `scribe-log-output-targets`.
* **Manual Context Management**: Use `(with-scribe-context! ...)` from `scribe-context.el` if you need to manually set or override logging context for a block of code.

## Dependencies

* Emacs 27.1+
* `cl-lib`
* `dash`
* `s` (string manipulation)
* `f` (file/path manipulation)
* `ht` (hash tables, for `scribe-cancel.el` and potentially `scribe-queue.el`)
* `ts` (timestamps, for `scribe-queue.el`)
* `ring` (ring buffer, for `scribe-queue.el`)
* `ansi-color` (optional, for colorized output if not filtered)
* `scribe` (itself, for sub-modules like `scribe-context`, `scribe-entry`, `scribe-format`, `scribe-queue`) - *Note: This implies a main `scribe.el` loads these. For individual file dependencies, see their headers.*
