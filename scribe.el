;;; scribe.el --- Enhanced Logging Framework -*- lexical-binding: t; -*-
;;
;; Author: Christian White <christiantwhite@protonmail.com>
;; Version: 0.1.0
;; Keywords: logging, tools, development, emacs
;; Package-Requires: ((emacs "26.1")
;;                    (cacheus "0.4.2")
;;                    (ring "1.2")
;;                    (s "1.12.0")
;;                    (f "0.20.0")
;;                    (dash "2.19.0")
;;                    (json "2.5.0")
;;                    (ts "0.1.0"))
;; URL: https://github.com/your-repo/scribe.el
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
;; See each module’s documentation for advanced configuration options.
;;
;;; Code:

(require 'scribe-context nil t)
(require 'scribe-log nil t)

(provide 'scribe)
;;; scribe.el ends here