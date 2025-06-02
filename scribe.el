;;; scribe.el --- Enhanced Logging Framework -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; Scribe is a modular, context-aware logging framework for Emacs. It provides
;; structured logging primitives that are project-aware, filterable by level,
;; and extensible across various Emacs workflows.
;;
;; This entry point aggregates and loads all core modules:
;;
;; - `scribe-log`     : Logging engine with levels, filters, and routing.
;; - `scribe-context` : Metadata injection (e.g., project, buffer, function).
;; - `scribe-entry`   : Structured log entry definitions.
;; - `scribe-queue`   : Asynchronous/in-memory log batching and flushing.
;;
;; Key Features:
;; - Multiple log levels (`info`, `warn`, `debug`, `error`, etc.)
;; - Automatic context capture (project, file, function, line)
;; - Pluggable backends and log sinks (files, buffers, etc.)
;; - Extensible log entry structure
;; - Supports deferred logging for performance
;;
;; Log entries are automatically enriched with contextual information and
;; can be formatted or flushed using the appropriate Scribe components.
;;
;; See each module’s documentation for advanced configuration options.
;;
;;; Code:

(require 'scribe-context)
(require 'scribe-log)

(provide 'scribe)
;;; scribe.el ends here