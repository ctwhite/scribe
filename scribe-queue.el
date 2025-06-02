;;; scribe-queue.el --- Queueing and Batching for Scribe Logging -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This library provides an asynchronous, batched queueing mechanism for Scribe
;; log entries. It aims to decouple the act of logging from the actual dispatch
;; of log messages, improving performance and responsiveness of applications
;; that generate high volumes of logs.
;;
;; Features:
;; - **Ring Buffer:** Uses an efficient ring buffer for in-memory storage of log entries.
;; - **Batching:** Collects log entries into batches before dispatching, reducing I/O overhead.
;; - **Flush Strategies:** Supports various flush methods:
;;   - `immediate`: Each entry is flushed as it arrives.
;;   - `burst`: Flushes when a configurable threshold of entries is reached.
;;   - `idle`: Flushes after a period of inactivity.
;;   - `hybrid`: Combines burst and idle flushing for optimal responsiveness and efficiency.
;; - **Deduplication:** Collapses consecutive identical log entries to save space and reduce redundant output.
;; - **Entry Expiration:** Periodically purges old entries to manage memory usage.
;; - **Overflow Handling:** Configurable strategies for when the queue reaches its maximum size:
;;   - `drop-oldest`: FIFO behavior.
;;   - `drop-newest`: Drops the incoming entry.
;;   - `block`: Pauses execution until space is available (use with caution).
;;   - `delegate`: Calls a user-defined function to handle overflow.
;; - **Dispatch Retries:** Attempts to re-dispatch failed entries up to a configurable limit.
;; - **Metrics:** Tracks various queue operations (enqueued, dispatched, dropped, failures).
;; - **Entry Pooling:** Reuses `scribe-queue-entry` objects to minimize garbage collection.

;;; Code:

(require 'cl-lib) ; For cl-defstruct, cl-incf, cl-loop, cl-return-from, cl-delete, cl-remf
(require 'dash)   ; For --each, --filter, --map, --any?, --remove, --separate
(require 'ring)   ; For ring buffer operations (make-ring, ring-insert, ring-remove, ring-length, ring-elements, ring-ref)
(require 'ts)     ; For timestamp objects and operations (ts-now, ts-p, ts-unix)

;; Ensure native-compiler knows about these functions/macros during compilation
(eval-when-compile (require 'cl-lib))
(eval-when-compile (require 'dash))
(eval-when-compile (require 'ring))
(eval-when-compile (require 'ts))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                       Customization Variables                              ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defgroup scribe nil
  "Group for Scribe logging library customizations."
  :group 'tools)

(defcustom scribe-queue-size 100
  "Maximum number of log entries retained in memory within the queue buffer."
  :type 'integer
  :group 'scribe)

(defcustom scribe-queue-burst-flush-threshold 10
  "Number of batched entries that, when exceeded, triggers an immediate burst flush."
  :type 'integer
  :group 'scribe)

(defcustom scribe-queue-idle-timeout 2.0
  "Idle duration in seconds after which an idle flush is triggered if no new entries arrive."
  :type 'float
  :group 'scribe)

(defcustom scribe-queue-max-batch-latency 5
  "Maximum time in seconds an entry may remain in the queue before being flushed,
regardless of the burst threshold. Prevents entries from getting stuck."
  :type 'float
  :group 'scribe)

(defcustom scribe-queue-flush-method 'hybrid
  "Flush strategy for entries.
- `immediate`: Flush every entry as it arrives.
- `burst`: Flush when `scribe-queue-burst-flush-threshold` is met.
- `idle`: Flush after `scribe-queue-idle-timeout` of inactivity.
- `hybrid`: Combines `burst` and `idle` flushing."
  :type '(choice
          (const :tag "Immediate flush" immediate)
          (const :tag "Burst flush" burst)
          (const :tag "Idle flush" idle)
          (const :tag "Hybrid (burst + idle)" hybrid))
  :group 'scribe)

(defcustom scribe-queue-silenced-predicates nil
  "List of predicate functions to silence (drop) entries.
Each predicate function receives a `scribe-queue-entry` object and should
return non-nil if the entry should be suppressed."
  :type '(repeat function)
  :group 'scribe)

(defcustom scribe-queue-use-entry-expiration t
  "If non-nil, expired entries are periodically purged from the queue."
  :type 'boolean
  :group 'scribe)

(defcustom scribe-queue-max-entry-age-seconds 300
  "Maximum time (in seconds) to retain a log entry in memory before it's considered expired."
  :type 'integer
  :group 'scribe)

(defcustom scribe-queue-stale-flush-fn #'ignore
  "Function called with values of expired entries during expiration.
This function is invoked with a single value (as returned by `scribe-queue-entry-val`)
extracted from stale queue entries. Useful for secondary archival or notification."
  :type 'function
  :group 'scribe)

(defcustom scribe-overflow-strategy 'drop-oldest
  "Overflow strategy when the internal ring buffer reaches its `scribe-queue-size` limit.
- `drop-oldest`: Removes the oldest entry to make space for the new one (FIFO).
- `drop-newest`: Drops the incoming new entry if the buffer is full.
- `block`: Pauses execution until space is available (can block UI).
- `delegate`: Calls `scribe-queue-overflow-delegate` to handle the overflow."
  :type '(choice
          (const :tag "Drop Oldest" drop-oldest)
          (const :tag "Drop Newest" drop-newest)
          (const :tag "Block" block)
          (const :tag "Delegate" delegate))
  :group 'scribe)

(defcustom scribe-queue-overflow-delegate nil
  "Optional delegate function for overflow behavior when
  `scribe-overflow-strategy` is `delegate`.
  It receives the value of the overflowing entry."
  :type 'function
  :group 'scribe)

(defcustom scribe-queue-max-dispatch-retries 3
  "Maximum number of times an entry will be re-queued for dispatch after failure.
Entries exceeding this limit will be dropped."
  :type 'integer
  :group 'scribe)

(defcustom scribe-queue-debug-verbose nil
  "If non-nil, enable verbose debugging messages for the Scribe queue's internal operations.
These messages are primarily for debugging the queue itself and can be noisy."
  :type 'boolean
  :group 'scribe)

(defcustom scribe-queue-min-flush-interval 0.1
  "Minimum interval (in seconds) between consecutive burst flushes.
This prevents the queue from continuously triggering flushes under very high load,
allowing the UI to remain responsive. A value of 0 means no backoff."
  :type 'float
  :group 'scribe)

(defcustom scribe-queue-expiration-check-interval 60
  "Interval (in seconds) at which to periodically check for and purge expired entries.
This ensures that old entries are removed even if the queue is idle."
  :type 'integer
  :group 'scribe)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                           Internal Variables                               ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar scribe-queue--buffer nil
  "The internal ring buffer holding the entries in the queue.")

(defvar scribe-queue--idle-timer nil
  "Timer used to trigger idle flushes.")

(defvar scribe-queue--expiration-timer nil
  "Timer used to periodically trigger expiration checks.")

(defvar scribe-queue--last-expiration-check (ts-now)
  "Timestamp of the last entry expiration check (ts object).")

(defvar scribe-queue--entry-pool nil
  "A pool of recycled `scribe-queue-entry` objects to reduce memory allocations
and garbage collection overhead.")

(defvar scribe-queue--entry-pool-limit 2048
  "Maximum size of the entry pool. Prevents the pool itself from consuming too much memory.")

(defvar scribe-queue--flushing-in-progress nil
  "Flag to indicate if a flush operation is currently in progress.
Used to prevent re-entrant calls to `scribe-queue--flush-now`.")

(defvar scribe-queue--active-dispatch-fn nil
  "The dispatch function currently used by the queue. Stored for persistent timers.")

(defvar scribe-queue--last-burst-flush-time (ts-now)
  "Timestamp of the last time a burst flush was actually triggered.
Used to implement `scribe-queue-min-flush-interval` backoff.")

;; --- Metrics Counters ---
(defvar scribe-queue-metrics-enqueued 0
  "Total number of entries enqueued.")
(defvar scribe-queue-metrics-dispatched 0
  "Total number of entries successfully dispatched.")
(defvar scribe-queue-metrics-dropped-overflow 0
  "Total number of entries dropped due to queue overflow.")
(defvar scribe-queue-metrics-dropped-silenced 0
  "Total number of entries dropped because they were silenced.")
(defvar scribe-queue-metrics-dropped-expired 0
  "Total number of entries dropped due to expiration.")
(defvar scribe-queue-metrics-dropped-retries 0
  "Total number of entries dropped due to exceeding dispatch retry limit.")
(defvar scribe-queue-metrics-dispatch-failures 0
  "Total number of dispatch attempts that failed.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                             Entry Structure                                ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(cl-defstruct (scribe-queue-entry
               (:constructor make-scribe-queue-entry))
  "Structure representing an entry in the Scribe queue.

Fields:
- VAL: The log entry payload (typically a `scribe-log-entry` or equivalent).
- TS: Timestamp of when the entry was enqueued (ts object).
- COUNT: Number of consecutive duplicate entries this represents.
- METADATA: Optional extra context or metadata (can be an alist or plist).
- RETRY-COUNT: Number of times dispatching this entry has been attempted and failed."
  val
  ts
  count
  metadata
  (retry-count 0))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                             Internal Helpers                               ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun scribe--now ()
  "Return the current timestamp as a `ts` object."
  (ts-now))

(defun scribe-queue--initialize ()
  "Initialize the internal queue (ring buffer) if it hasn't been set up yet.
Ensures the buffer is ready before operations."
  (unless scribe-queue--buffer
    (setq scribe-queue--buffer (make-ring scribe-queue-size))))

(defun scribe-queue--make-queue-entry (val)
  "Create a new `scribe-queue-entry` with the given value.
Attempts to reuse an entry from the pool if available, otherwise creates a new one.
Initializes the entry's fields, resetting `retry-count` to 0."
  (let ((entry (or (pop scribe-queue--entry-pool)
                   (make-scribe-queue-entry :val nil :ts nil :count 1 :metadata nil :retry-count 0))))
    (setf (scribe-queue-entry-val entry) val
          (scribe-queue-entry-ts entry) (scribe--now)
          (scribe-queue-entry-count entry) 1
          (scribe-queue-entry-metadata entry) nil
          (scribe-queue-entry-retry-count entry) 0)
    entry))

(defun scribe-queue--recycle-entries (entries)
  "Recycle a list of `scribe-queue-entry` objects back to the pool.
Ensures the pool limit is respected and entry contents are cleared for safety
before recycling to prevent data leaks or unexpected state."
  (dolist (entry entries)
    (when (scribe-queue-entry-p entry)
      ;; Clear sensitive data to prevent accidental reuse or memory leaks
      (setf (scribe-queue-entry-val entry) nil
            (scribe-queue-entry-ts entry) nil
            (scribe-queue-entry-count entry) 1
            (scribe-queue-entry-metadata entry) nil
            (scribe-queue-entry-retry-count entry) 0)
      ;; Add to pool only if limit is not exceeded
      (when (< (length scribe-queue--entry-pool) scribe-queue--entry-pool-limit)
        (push entry scribe-queue--entry-pool)))))

(defun scribe-queue--valid-entry-p (entry)
  "Return non-nil if ENTRY is a valid `scribe-queue-entry` object and its `val` is non-nil."
  (and (scribe-queue-entry-p entry)
       (scribe-queue-entry-val entry)))

(defun scribe-queue--call-stale-flush (entries)
  "Call `scribe-queue-stale-flush-fn` for each valid entry's value in ENTRIES.
Logs a message indicating the call and handles errors in the stale flush function."
  (when scribe-queue-debug-verbose
    (message "[scribe] Calling stale flush for %d entries." (length entries)))
  (when (functionp scribe-queue-stale-flush-fn)
    (--each entries
      (when (scribe-queue--valid-entry-p it)
        (condition-case err
            (funcall scribe-queue-stale-flush-fn (scribe-queue-entry-val it))
          (error
           (message "[scribe] ERROR: Stale flush function failed for entry %S: %S"
                    (scribe-queue-entry-val it) err)))))))

(defun scribe-queue--queue-entry-expired? (entry now-ts)
  "Check if ENTRY is expired by comparing its timestamp to NOW-TS.
An entry is expired if its timestamp is older than `scribe-queue-max-entry-age-seconds`
relative to `NOW-TS`. Both `(scribe-queue-entry-ts entry)` and `NOW-TS` are `ts` objects.
Uses `ts-unix` for comparison."
  (and (scribe-queue-entry-p entry)
       (ts-p (scribe-queue-entry-ts entry))
       (ts-p now-ts)
       ;; Calculate difference using ts-unix of absolute timestamps
       (> (- (ts-unix now-ts)
             (ts-unix (scribe-queue-entry-ts entry)))
          scribe-queue-max-entry-age-seconds)))

(defun scribe-queue--purge-expired (now-ts)
  "Remove expired entries from the queue (ring buffer) and recycle them.
Calls `scribe-queue-stale-flush-fn` for all expired entries.
This function ensures memory is reclaimed for old entries.
It operates directly on `scribe-queue--buffer`."
  (when scribe-queue-use-entry-expiration
    (when scribe-queue-debug-verbose
      (message "[scribe] Initiating expiration check for old entries."))

    (let ((entries-to-keep nil)
          (expired-entries nil)
          (original-length (ring-length scribe-queue--buffer)))

      ;; Iterate through the current buffer elements
      (dotimes (i original-length)
        (let ((entry (ring-ref scribe-queue--buffer i)))
          (when (scribe-queue--valid-entry-p entry)
            (if (scribe-queue--queue-entry-expired? entry now-ts)
                (progn
                  (push entry expired-entries)
                  (cl-incf scribe-queue-metrics-dropped-expired))
              (push entry entries-to-keep)))))

      (when expired-entries
        (when scribe-queue-debug-verbose
          (message "[scribe] Recycling %d expired entries." (length expired-entries)))
        (scribe-queue--call-stale-flush expired-entries)
        (scribe-queue--recycle-entries expired-entries))

      ;; Rebuild the ring buffer with only non-expired entries
      ;; This is necessary because `ring` library doesn't support arbitrary removal.
      (when (< (length entries-to-keep) original-length) ; Only rebuild if something was removed
        (when scribe-queue-debug-verbose
          (message "[scribe] Rebuilding ring buffer with %d active entries."
                   (length entries-to-keep)))
        (setq scribe-queue--buffer (make-ring scribe-queue-size))
        (--each (nreverse entries-to-keep) ; Re-add in original order
          (ring-insert scribe-queue--buffer it))))))

(defun scribe-queue--overflow-behavior (entry)
  "Handle the overflow behavior when the queue's ring buffer reaches its size limit.
The strategy is determined by `scribe-overflow-strategy`.
Increments `scribe-queue-metrics-dropped-overflow` for dropped entries.

Returns: Non-nil if the entry was successfully handled (i.e., space was made or it was blocked),
         nil if the entry was dropped (e.g., `drop-newest` or `delegate` without re-queue)."
  (when scribe-queue-debug-verbose
    (message "[scribe] Queue overflow detected. Strategy: %S." scribe-overflow-strategy))
  (cond
   ;; Drop the oldest entry (FIFO) and recycle it
   ((eq scribe-overflow-strategy 'drop-oldest)
    (let ((removed-entry (ring-remove scribe-queue--buffer 0)))
      (when scribe-queue-debug-verbose
        (message "[scribe] Dropping oldest entry due to overflow: %S"
                 (scribe-queue-entry-val removed-entry)))
      (cl-incf scribe-queue-metrics-dropped-overflow)
      ;; Recycle the removed entry
      (scribe-queue--recycle-entries (list removed-entry))
      t)) ; Indicate that space was made for the new entry

   ;; Drop the newest entry (the incoming one)
   ((eq scribe-overflow-strategy 'drop-newest)
    (when scribe-queue-debug-verbose
      (message "[scribe] Dropping newest entry due to overflow: %S"
               (scribe-queue-entry-val entry)))
    (cl-incf scribe-queue-metrics-dropped-overflow)
    ;; Recycle the incoming entry
    (scribe-queue--recycle-entries (list entry))
    nil) ; Indicate that the new entry was dropped

   ;; Block until space becomes available (wait for a flush or removal)
   ((eq scribe-overflow-strategy 'block)
    (when scribe-queue-debug-verbose
      (message "[scribe] Blocking due to queue overflow. Waiting for space..."))
    (while (>= (ring-length scribe-queue--buffer) scribe-queue-size)
      (sit-for 0.1)) ; Check every 100ms
    (when scribe-queue-debug-verbose
      (message "[scribe] Space available. Inserting entry after block."))
    t) ; Indicate that space was made for the new entry

   ;; Delegate to an external handler
   ((eq scribe-overflow-strategy 'delegate)
    (when scribe-queue-debug-verbose
      (message "[scribe] Delegating overflow handling for entry: %S"
               (scribe-queue-entry-val entry)))
    (let ((overflow-fn scribe-queue-overflow-delegate))
      (if (functionp overflow-fn)
          (condition-case err
              (funcall overflow-fn (scribe-queue-entry-val entry))
            (error
             (message "[scribe] ERROR: Overflow delegate function failed for entry %S: %S"
                      (scribe-queue-entry-val entry) err)))
        (message "[scribe] WARNING: No valid overflow delegate function defined for 'delegate' strategy. Entry dropped: %S"
                 (scribe-queue-entry-val entry))))
    (cl-incf scribe-queue-metrics-dropped-overflow)
    ;; Recycle the delegated/dropped entry
    (scribe-queue--recycle-entries (list entry))
    nil) ; Indicate that the new entry was dropped

   (t
    ;; Fallback for unknown strategy (should not happen with `defcustom` choice)
    (message "[scribe] ERROR: Unknown overflow strategy '%S'. Dropping entry: %S"
             scribe-overflow-strategy (scribe-queue-entry-val entry))
    (cl-incf scribe-queue-metrics-dropped-overflow)
    ;; Recycle the dropped entry
    (scribe-queue--recycle-entries (list entry))
    nil))) ; Indicate that the new entry was dropped

(defun scribe-queue--deduplicate-batch (entries)
  "Collapse consecutive entries with the same value into a single entry.
Consecutive entries with identical `val` fields are merged by summing their counts.
Recycles the merged (discarded) entries back to the `scribe-queue--entry-pool`.

ENTRIES: A list of `scribe-queue-entry` objects.

Returns: A new list of `scribe-queue-entry` objects, with duplicates collapsed.
         The returned entries are the original ones, with `count` potentially modified."
  (let ((result nil)
        (last-entry nil)
        (recycled-entries nil))
    (cl-loop for entry in entries do
      (let ((val (scribe-queue-entry-val entry))
            (cnt (or (scribe-queue-entry-count entry) 1)))
        (unless (numberp cnt)
          (when scribe-queue-debug-verbose
            (message "[scribe] WARNING: Invalid count in log entry: %S. Defaulting to 1." entry))
          ;; Default to 1 for safety
          (setq cnt 1))

        (if (and last-entry
                 (equal val (scribe-queue-entry-val last-entry)))
            ;; If current entry is a duplicate of the last one, merge it.
            (progn
              (setf (scribe-queue-entry-count last-entry)
                    (+ (scribe-queue-entry-count last-entry) cnt))
              ;; Add the current (duplicate) entry to recycle list
              (push entry recycled-entries))
          ;; If it's a new unique entry, add it to the result list.
          (progn
            (push entry result)
            (setq last-entry entry)))))

    ;; Recycle all entries that were merged (i.e., not kept in `result`).
    (scribe-queue--recycle-entries recycled-entries)
    ;; `push` builds the list in reverse order, so `nreverse` to restore original order.
    (nreverse result)))

(defun scribe-queue--flush-now (dispatch-fn &optional count)
  "Flush accumulated entries with deduplication and dispatching.
Pulls entries from `scribe-queue--buffer`.
Recycles entries back to the pool after successful dispatch.
Handles dispatch errors by re-queuing failed entries (up to `scribe-queue-max-dispatch-retries`).
Prevents re-entrant flushes using `scribe-queue--flushing-in-progress` flag.
COUNT (integer, optional): The maximum number of entries to flush. If nil, flushes all."
  ;; Check for re-entrancy first.
  (if scribe-queue--flushing-in-progress
      (progn
        (when scribe-queue-debug-verbose
          (message "[scribe] WARNING: Flush already in progress. Skipping re-entrant flush call."))
        nil) ; Return nil and exit the function.
    (setq scribe-queue--flushing-in-progress t)
    (unwind-protect
        (progn
          (let ((entries-to-flush nil)
                (num-to-pull (or count (ring-length scribe-queue--buffer)))) ; Pull all if count is nil

            ;; Pull entries from the ring buffer into a temporary list
            (dotimes (_ (min num-to-pull (ring-length scribe-queue--buffer)))
              (push (ring-remove scribe-queue--buffer) entries-to-flush))
            (setq entries-to-flush (nreverse entries-to-flush)) ; Restore order

            (when scribe-queue-debug-verbose
              (message "[scribe] Initiating flush of %d entries pulled from buffer." (length entries-to-flush)))

            (let ((deduped-entries (scribe-queue--deduplicate-batch entries-to-flush)) ; Deduplicate and recycle merged
                  (failed-to-dispatch nil)
                  (dropped-due-to-retries nil))

              ;; Dispatch each deduplicated entry
              (cl-loop for it in deduped-entries do
                (condition-case err
                    (progn
                      (funcall dispatch-fn it)
                      (cl-incf scribe-queue-metrics-dispatched))
                  (error
                   (message "[scribe] ERROR: Dispatch failed for entry %S: %S"
                            (scribe-queue-entry-val it) err)
                   (cl-incf scribe-queue-metrics-dispatch-failures)
                   (cl-incf (scribe-queue-entry-retry-count it))
                   (if (<= (scribe-queue-entry-retry-count it) scribe-queue-max-dispatch-retries)
                       ;; Re-queue if within retry limit (push back to the ring buffer)
                       (ring-insert scribe-queue--buffer it)
                     (progn
                       (message "[scribe] Dropping entry %S: exceeded max dispatch retries (%d)."
                                (scribe-queue-entry-val it) scribe-queue-max-dispatch-retries)
                       (cl-incf scribe-queue-metrics-dropped-retries)
                       (push it dropped-due-to-retries))))))

              ;; Recycle successfully dispatched entries and those dropped due to retries
              (let ((successfully-processed (--remove (lambda (entry)
                                                        (or (--any? (eq entry it) failed-to-dispatch)
                                                            (--any? (eq entry it) (ring-elements scribe-queue--buffer)))) ; Don't recycle if re-queued
                                                      deduped-entries)))
                (setq successfully-processed (append successfully-processed dropped-due-to-retries))
                (when successfully-processed
                  (when scribe-queue-debug-verbose
                    (message "[scribe] Recycling %d processed entries."
                             (length successfully-processed)))
                  (scribe-queue--recycle-entries successfully-processed)))))
          ;; Update last burst flush time if this was a burst-driven flush
          (when (or (eq scribe-queue-flush-method 'burst) (eq scribe-queue-flush-method 'hybrid))
            (setq scribe-queue--last-burst-flush-time (scribe--now))))
      (setq scribe-queue--flushing-in-progress nil))))

(defun scribe-queue--batch-oldest-ts ()
  "Return the timestamp (ts object) of the oldest entry in the ring buffer, or nil if buffer is empty."
  (when (> (ring-length scribe-queue--buffer) 0)
    (scribe-queue-entry-ts (ring-ref scribe-queue--buffer 0)))) ; Oldest is at index 0

(defun scribe-queue--flush-if-stale (dispatch-fn)
  "Flush entries if the oldest entry in the ring buffer has exceeded `scribe-queue-max-batch-latency`.
This is primarily for the idle timer in hybrid/idle modes."
  (when-let* ((now-ts (scribe--now))
              (oldest-ts (scribe-queue--batch-oldest-ts)))
    (when scribe-queue-debug-verbose
      (message "[scribe] DEBUG: flush-if-stale called. Buffer length: %d."
               (ring-length scribe-queue--buffer)))
    (when scribe-queue-debug-verbose
      (message "[scribe] DEBUG: oldest-ts: %S, now-ts: %S." oldest-ts now-ts))

    (let* ((diff-seconds (and oldest-ts (ts-p oldest-ts) (ts-p now-ts)
                               (- (ts-unix now-ts)
                                  (ts-unix oldest-ts))))
           (latency-condition (and diff-seconds (> diff-seconds scribe-queue-max-batch-latency))))
      (when scribe-queue-debug-verbose
        (message "[scribe] DEBUG: Calculated time diff (float seconds): %f, Max batch latency: %f."
                 (or diff-seconds 0.0)
                 scribe-queue-max-batch-latency))
      (when scribe-queue-debug-verbose
        (message "[scribe] DEBUG: Latency condition met: %S." latency-condition))

      (when latency-condition
        (when scribe-queue-debug-verbose
          (message "[scribe] Triggering flush (latency condition met)."))
        (scribe-queue--flush-now dispatch-fn)))))

(defun scribe-queue--start-idle-flush-timer ()
  "Start or restart a persistent timer for flushing entries when the system is idle.
The timer will run periodically after `scribe-queue-idle-timeout`. It will
continuously check for stale entries in the queue and flush them using
`scribe-queue--active-dispatch-fn`. This timer reschedules itself."
  ;; Cancel any existing timer to ensure only one is active at a time.
  (when (timerp scribe-queue--idle-timer)
    (cancel-timer scribe-queue--idle-timer))
  (setq scribe-queue--idle-timer
        (run-with-idle-timer scribe-queue-idle-timeout t ; `t` for repeat
          (lambda ()
            (when scribe-queue-debug-verbose
              (message "[scribe] Persistent idle flush timer triggered."))
            ;; The idle timer should only check for staleness.
            (when scribe-queue--active-dispatch-fn
              (scribe-queue--flush-if-stale scribe-queue--active-dispatch-fn))))))

(defun scribe-queue--start-expiration-timer ()
  "Start or restart a persistent timer for periodically purging expired entries.
This ensures that old entries are removed even if the queue is idle and no new
entries are being enqueued."
  (when (timerp scribe-queue--expiration-timer)
    (cancel-timer scribe-queue--expiration-timer))
  (setq scribe-queue--expiration-timer
        (run-with-timer scribe-queue-expiration-check-interval t ; `t` for repeat
          (lambda ()
            (when scribe-queue-debug-verbose
              (message "[scribe] Persistent expiration timer triggered."))
            (scribe-queue--purge-expired (scribe--now))))))

(defun scribe-queue--silenced? (entry)
  "Return non-nil if the entry matches any of the silencing predicates.
An entry is silenced if any predicate in `scribe-queue-silenced-predicates`
returns non-nil when called with the entry.
Increments `scribe-queue-metrics-dropped-silenced` if silenced."
  (let ((silenced (when scribe-queue-silenced-predicates
                    (--any? (funcall it entry) scribe-queue-silenced-predicates))))
    (when silenced
      (cl-incf scribe-queue-metrics-dropped-silenced)
      (when scribe-queue-debug-verbose
        (message "[scribe] Entry silenced: %S" (scribe-queue-entry-val entry))))
    silenced))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                 Public API                                 ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defsubst scribe-queue-current-size ()
  "Return the current number of entries in the internal ring buffer."
  (ring-length scribe-queue--buffer))

;;;###autoload
(defun scribe-queue-clear ()
  "Clear the queue, including the ring buffer, and recycle all entries.
This function should be called to release all memory held by the queue.
It also cancels the persistent idle flush timer and expiration timer."
  (interactive)
  (when scribe-queue-debug-verbose
    (message "[scribe] Clearing scribe queue and recycling all entries."))

  ;; Cancel timers
  (when (timerp scribe-queue--idle-timer)
    (cancel-timer scribe-queue--idle-timer)
    (setq scribe-queue--idle-timer nil))
  (when (timerp scribe-queue--expiration-timer)
    (cancel-timer scribe-queue--expiration-timer)
    (setq scribe-queue--expiration-timer nil))

  ;; Recycle entries from the ring buffer
  (when scribe-queue--buffer
    (let ((removed-entries nil))
      ;; Remove all elements from the ring buffer and collect them
      (dotimes (_ (ring-length scribe-queue--buffer))
        (push (ring-remove scribe-queue--buffer) removed-entries))
      ;; Recycle the collected entries
      (scribe-queue--recycle-entries removed-entries))
    ;; Re-initialize the buffer to ensure it's empty and clean
    (setq scribe-queue--buffer (make-ring scribe-queue-size))))

;;;###autoload
(defun scribe-queue-flush-all ()
  "Immediately flush all pending entries in the queue.
This function is useful for ensuring all logs are processed, especially before exit."
  (interactive)
  (when scribe-queue-debug-verbose
    (message "[scribe] Forcing flush of all pending entries."))
  ;; Cancel the idle timer when forcing a flush
  (when (timerp scribe-queue--idle-timer)
    (cancel-timer scribe-queue--idle-timer)
    (setq scribe-queue--idle-timer nil))
  ;; No need to cancel expiration timer here, it operates independently.

  ;; Flush all entries currently in the ring buffer.
  ;; `scribe-queue--flush-now` will pull them, deduplicate, dispatch, and recycle.
  (scribe-queue--flush-now scribe-queue--active-dispatch-fn nil))

;;;###autoload
(defun scribe-delegate-overflow (entry-value)
  "Delegate the overflow handling to an external function.
This function is called when `scribe-overflow-strategy` is set to `delegate`.
It receives the `entry-value` (the payload of the `scribe-queue-entry`).
If `scribe-queue-overflow-delegate` is not a valid function, a warning is logged
and the entry is effectively dropped."
  (when scribe-queue-debug-verbose
    (message "[scribe] Handling overflow via delegation for entry: %S" entry-value))
  (let ((overflow-fn scribe-queue-overflow-delegate))
    (if (functionp overflow-fn)
        (condition-case err
            (funcall overflow-fn entry-value)
          (error
           (message "[scribe] ERROR: Overflow delegate function failed for entry %S: %S"
                    entry-value err)))
      (message "[scribe] WARNING: No valid overflow delegate function defined for 'delegate' strategy. Entry dropped: %S"
               entry-value))
    (cl-incf scribe-queue-metrics-dropped-overflow)
    ;; This function itself should not be responsible for recycling,
    ;; as `scribe-queue--overflow-behavior` already handles it.
    ))

;;;###autoload
(defun scribe-queue-enqueue-and-dispatch (entry dispatch-fn)
  "Enqueue ENTRY into the queue and trigger flush logic based on the configured strategy.
This is the primary entry point for adding new log entries to the queue.
Increments `scribe-queue-metrics-enqueued`."
  (cl-incf scribe-queue-metrics-enqueued)
  (unless (scribe-queue--silenced? entry)
    (let ((now-ts (scribe--now))
          (wrapped (scribe-queue--make-queue-entry entry)))

      (scribe-queue--initialize)
      (setq scribe-queue--active-dispatch-fn dispatch-fn) ; Store the dispatch function

      ;; Ensure expiration timer is running
      (unless (timerp scribe-queue--expiration-timer)
        (scribe-queue--start-expiration-timer))

      ;; Handle overflow *before* inserting. If 'drop-newest', the entry might be recycled here.
      (when (>= (ring-length scribe-queue--buffer) scribe-queue-size)
        (unless (scribe-queue--overflow-behavior wrapped) ; if overflow-behavior returns nil, entry was dropped
          (cl-return-from scribe-queue-enqueue-and-dispatch nil)))

      ;; If the entry was not dropped by overflow-behavior, insert it
      (when (scribe-queue--valid-entry-p wrapped)
        (ring-insert scribe-queue--buffer wrapped)
        (when scribe-queue-debug-verbose
          (message "[scribe] Enqueued entry: %S. Queue size: %d."
                   (scribe-queue-entry-val wrapped) (ring-length scribe-queue--buffer))))

      ;; Apply flush strategy
      (pcase scribe-queue-flush-method
        ('immediate
         (when scribe-queue-debug-verbose
           (message "[scribe] Flush method: immediate. Flushing now."))
         (scribe-queue--flush-now dispatch-fn))
        ('burst
         (when (and (>= (ring-length scribe-queue--buffer) scribe-queue-burst-flush-threshold)
                    (or (zerop scribe-queue-min-flush-interval)
                        (> (- (ts-unix now-ts) (ts-unix scribe-queue--last-burst-flush-time))
                           scribe-queue-min-flush-interval)))
           (when scribe-queue-debug-verbose
             (message "[scribe] Flush method: burst. Threshold met or interval passed. Flushing now."))
           (scribe-queue--flush-now dispatch-fn)
           (setq scribe-queue--last-burst-flush-time now-ts)))
        ('idle
         (when scribe-queue-debug-verbose
           (message "[scribe] Flush method: idle. Starting/restarting idle timer."))
         (scribe-queue--start-idle-flush-timer))
        ('hybrid
         (when (and (>= (ring-length scribe-queue--buffer) scribe-queue-burst-flush-threshold)
                    (or (zerop scribe-queue-min-flush-interval)
                        (> (- (ts-unix now-ts) (ts-unix scribe-queue--last-burst-flush-time))
                           scribe-queue-min-flush-interval)))
           (when scribe-queue-debug-verbose
             (message "[scribe] Flush method: hybrid. Burst condition met. Flushing now."))
           (scribe-queue--flush-now dispatch-fn)
           (setq scribe-queue--last-burst-flush-time now-ts))
         ;; Always ensure idle timer is running for hybrid mode
         (when scribe-queue-debug-verbose
           (message "[scribe] Flush method: hybrid. Ensuring idle timer is running."))
         (scribe-queue--start-idle-flush-timer))
        (_
         (message "[scribe] WARNING: Unknown flush method: %S. Enqueued but no flush triggered." scribe-queue-flush-method))))))

;; Initialize the queue when the file is loaded.
(scribe-queue--initialize)

(provide 'scribe-queue)
;;; scribe-queue.el ends here