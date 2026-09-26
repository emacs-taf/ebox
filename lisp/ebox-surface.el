;;; ebox-surface.el --- Retained projection and publication -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Owns the boundary from an Ebox candidate runtime to a generic Ebox publication surface
;; plan, and the atomic participant that mirrors the committed publication
;; generation into Ebox's buffer-local runtime indexes.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ebox-text)
(require 'ebox-buffer-backend)
(require 'ebox-font)
(require 'ebox-style)
(require 'ebox-tree)
(require 'ebox-layout)
(require 'ebox-incremental)
(require 'ebox-runtime-index)
(require 'ebox-publication)

(defvar ebox-region-types)
(declare-function ebox--runtime-node-ids "ebox" (node))
(defvar ebox--region-id-counter)
(defvar ebox--runtime-node-id-counter)
(defvar ebox--region-box-table)
(defvar ebox--scroll-global-state)
(defvar ebox--paint-origin-property)
(declare-function ebox--paint-origin-baseline
                  "ebox-render-context" (origin))
(defvar ebox--scroll-idle-prefetch-timers)
(defvar ebox--smooth-scroll-state-table)
(defvar ebox--buffer-render-state-table)
(defvar ebox--viewport-dependent-node-ids-cache)
(defvar ebox--viewport-dependent-subtree-cache)
(defvar ebox--viewport-height-dependent-subtree-cache)
(defvar ebox--render-runtime-revision)
(defvar ebox--render-source-index)
(defvar ebox-layer--active-p)
(defvar ebox--render-root-parent-kind)
(defvar ebox--render-cache-table)
(defvar ebox--render-cache-signature-cache)
(defvar ebox-layer--previous-composition-cache)
(defvar ebox-layer--composition-cache)
(defvar ebox-layer--composition-context)
(defvar ebox--layout-fragments-table)
(defvar ebox--layout-fragments-reuse-p)
(defvar ebox--flex-content-min-width-table)
(defvar ebox--scroll-window-initial-lookahead-lines-override)
(defvar ebox-viewport-width)
(defvar ebox-viewport-height)
(defvar ebox--render-display-signature)
(defvar ebox-incremental--allocated-slot-proof-cache)
(defvar ebox-incremental--buffer-render-state-override)
(declare-function ebox--region-ids-visible-in-buffer-p "ebox" (buffer region-ids))
(declare-function ebox--scroll-line-region-ids "ebox" (line))
(declare-function ebox--scroll-build-region-line-span-index "ebox" (lines))
(declare-function ebox-transaction-participate "ebox-reactive" (&rest args))

(defun ebox-surface--transaction-participate (key stage rollback &optional after-commit)
  "Register KEY with paired STAGE and ROLLBACK through Ebox publication v2."
  (ebox-transaction-participate
   :key key :stage stage :rollback rollback :after-commit after-commit))

(defvar ebox-surface--inline-style-value-cache nil
  "Per-projection cache for selector-free computed inline styles.")

(defvar ebox-surface--font-window nil
  "Canonical target window frozen for one Surface projection.")

(defvar ebox-surface--integral-local-output-required-p nil
  "Non-nil while a partial render must prove an integral pixel origin.")

(defun ebox-surface--check-local-pixel-output (output)
  "Decline fractional local OUTPUT before footprint or ownership proofs.
The enclosing producer catches the decline and renders the complete root."
  (when (and ebox-surface--integral-local-output-required-p
             (stringp output) (ebox--fractional-pixel-spaces-p output))
    (throw 'ebox/fractional-local-output nil))
  output)

(defun ebox-surface--mixed-range-splice-p (state)
  "Return non-nil when STATE's mixed proof contains one Range splice."
  (let ((proof (plist-get (plist-get state :mixed-owner-proof) :geometry-proof)))
    (or (plist-get proof :range-splice-p)
        (cl-some (lambda (owner-proof)
                   (plist-get owner-proof :range-splice-p))
                 (plist-get proof :owner-proofs)))))

(declare-function ebox--render-layout "ebox-layout" (node))
(declare-function ebox--maplines "ebox" (function string))
(declare-function ebox--ensure-node-id "ebox" (node))
(declare-function ebox-native-commit-render
                  "ebox-native-commit" (state node))
(declare-function ebox-native-commit-confirm-published-frame
                  "ebox-native-commit" (state published-revision))
(declare-function ebox-native-commit-attach-confirmed-base
                  "ebox-native-commit" (previous-state state))
(declare-function ebox-native-reflow-frame-fragments
                  "ebox-native-reflow" (frame))
(declare-function ebox-native-reflow-layout-ready-p
                  "ebox-native-reflow" ())
(declare-function ebox-native-reflow-release-session
                  "ebox-native-reflow" (session))
(declare-function ebox-native-commit-projection-eligible-p
                  "ebox-native-commit"
                  (previous-state state-overrides stylesheet-active-p))

(defun ebox-surface--release-native-session (session)
  "Release native SESSION when it is present."
  (when (and session (require 'ebox-native-reflow nil t))
    (ebox-native-reflow-release-session session)))

(defun ebox-surface--settle-native-session
    (old-state state-overrides surface committed-p)
  "Retire the losing native session after one candidate publication.
OLD-STATE owns the committed session before publication.  STATE-OVERRIDES
owns the isolated candidate.  When COMMITTED-P is non-nil, SURFACE identifies
the winning client state; otherwise only the candidate is disposable."
  (let ((old-session (plist-get old-state :native-sync-session))
        (candidate-session
         (plist-get state-overrides :native-sync-session))
        (committed-session
         (and committed-p surface
              (plist-get (ebox--pub-surface-client-state surface)
                         :native-sync-session)))
        diagnostics)
    (cl-labels
        ((release-loser
          (session)
          (let ((inhibit-quit t) (quit-flag nil))
            (condition-case condition
                (ebox-surface--release-native-session session)
              ((error quit)
               (push (list :phase 'native-session-retirement
                           :session-id (sxhash-eq session)
                           :condition (copy-tree condition))
                     diagnostics))))))
      (if committed-p
          (dolist (session
                   (delete-dups
                    (delq nil (list old-session candidate-session))))
            (unless (eq session committed-session)
              (release-loser session)))
        (when (and candidate-session
                   (not (eq candidate-session old-session)))
          (release-loser candidate-session))))
    (nreverse diagnostics)))
(declare-function ebox--pub-object-reuse "ebox-publication" (context object))
(declare-function ebox--pub-bind-precomputed
                  "ebox-reactive"
                  (owner key compute value dependencies &rest options))
(declare-function ebox--record-render-output-provenance
                  "ebox-render-context" (rendered))
(declare-function ebox--strip-paint-origins! "ebox-render-context" (string))
(declare-function ebox--render-owned-text-value-p
                  "ebox-render-context" (property value &optional registry))
(declare-function ebox-incremental--hash-snapshot
                  "ebox-incremental" (table keys))
(declare-function ebox-incremental--restore-hash-snapshot
                  "ebox-incremental" (table entries))
(declare-function ebox-incremental--replace-hash-entries
                  "ebox-incremental" (target keys source))
(declare-function ebox--runtime-region-id-conflict
                  "ebox-incremental" (region-id-set target-buffer))
(declare-function ebox--region-id-set
                  "ebox-incremental" (region-ids))
(declare-function ebox--flex-item-slot-sized-node
                  "ebox-incremental"
                  (buffer node-id snapshot &optional changed-keys))
(declare-function ebox--layout-snapshot-strip-details
                  "ebox-incremental" (snapshot))
(declare-function ebox--viewport-dependent-node-id-axes
                  "ebox-incremental" (node))
(declare-function ebox--update-report
                  "ebox-incremental" (region-id strategy &rest props))
(declare-function ebox-incremental--finalize-declarative-scroll-publication
                  "ebox-incremental" (scroll-keys &optional prefetch-delay))
(declare-function ebox--scroll-schedule-idle-prefetch
                  "ebox" (region-id &optional delay))
(declare-function ebox--scroll-clear-state "ebox" (region-id))
(declare-function ebox--smooth-scroll-stop "ebox" (region-id))
(declare-function ebox-put "ebox" (box property value))
(declare-function ebox-get "ebox" (box property))
(declare-function ebox-string-lines "ebox" (string))
(declare-function ebox-lines-join "ebox" (lines))
(declare-function ebox--scroll-state-rendered-visible-window
                  "ebox" (state))
(declare-function ebox--scroll-state-retained-window-ready-p
                  "ebox" (state))
(declare-function ebox--scroll-state-set-lines
                  "ebox" (state content-lines &optional rendered-lines))
(declare-function ebox--surface-nested-scroll-cached-p
                  "ebox" (scroll &optional delta))
(declare-function ebox--scroll-box-contains-grid-p
                  "ebox" (box))
(declare-function ebox--scroll-line-region-span
                  "ebox" (line region-set))
(declare-function ebox-buffer--span-slot-width
                  "ebox-buffer-backend" (span))
(declare-function ebox-pixel-space "ebox" (pixel-width))
(declare-function ebox--pub-object-mounted-p "ebox-publication" (object))
(declare-function ebox--pub-object-attach-content-ranges-owned
                  "ebox-publication" (context leaf ranges))
(declare-function ebox-text-snapshot
                  "ebox-text" (text &optional reuse-property-p))
(declare-function ebox--pub-surface-plan-create-owned
                  "ebox-publication" (&rest arguments))
(declare-function ebox--pub-surface-result-create-owned
                  "ebox-publication" (context plan &optional client-state))
(declare-function ebox--pub-surface-retained-content-result-create
                  "ebox-publication"
                  (context plan rendered ranges &optional client-state
                   full-surface-p property-contributions))
(declare-function ebox--pub-surface-report-summary "ebox-publication" (surface))
(declare-function ebox--pub-surface-add-observer
                  "ebox-publication" (surface observer))
(declare-function ebox--pub-surface-remove-observer
                  "ebox-publication" (surface observer))
(declare-function ebox-transaction-active-p "ebox-reactive" ())
(defvar gcs-done)
(defvar gc-elapsed)

(defvar-local ebox-surface--buffer-surface nil
  "Live Ebox publication content surface mounted for the current Ebox buffer.")

(defvar-local ebox-surface--buffer-observer nil
  "Optional public observer for completed Ebox buffer publications.")

(defvar-local ebox-surface--publication-observer nil
  "Stable Ebox publication observer bridge installed for the current Ebox buffer.")

(defvar-local ebox-surface--observation-contexts nil
  "Pending observed Ebox calls for the current buffer.")

(defvar ebox-surface--observation-context nil
  "Dynamically bound observation context for one public Ebox call.")

(cl-defstruct (ebox-surface--observation
               (:constructor ebox-surface--make-observation))
  "Two-phase observation of one public Ebox publication."
  buffer observer stage started gc-start transaction-before correlation-id
  publication-report ebox-report finished gc-end finished-p phase phase-start phase-times)

(cl-defstruct (ebox-surface--signals
               (:constructor ebox-surface--make-signals))
  "Ebox publication signals carrying one mounted Ebox surface's host context."
  buffer viewport-width viewport-height display scroll)

(cl-defstruct (ebox-surface--framework-participant
               (:constructor ebox-surface--make-framework-participant))
  "One Ebox-owned framework publication participant."
  publish rollback state report diagnostics runtime-state scroll-keys
  scroll-diagnostics)

(defun ebox-surface--record-native-retirement-diagnostics
    (surface participant diagnostics)
  "Record native retirement DIAGNOSTICS for SURFACE and PARTICIPANT."
  (let ((state (ebox--pub-surface-client-state surface)))
    (if diagnostics
        (progn
          (plist-put state :native-retirement-diagnostics
                     (copy-tree diagnostics))
          (when participant
            (setf (ebox-surface--framework-participant-diagnostics participant)
                  (append
                   (ebox-surface--framework-participant-diagnostics participant)
                   (copy-tree diagnostics)))))
      (cl-remf state :native-retirement-diagnostics)))
  diagnostics)

(defvar-local ebox-surface--context-signals nil
  "Buffer-scoped Ebox publication signals consumed by the mounted Ebox producer.")

(defun ebox-surface--observation-clock ()
  "Return the current observation clock in seconds."
  (float-time))

(defun ebox-surface--observation-switch-phase (context phase now)
  "Charge CONTEXT's current phase through NOW, then enter PHASE."
  (when-let* ((previous (ebox-surface--observation-phase context))
              (started (ebox-surface--observation-phase-start context)))
    (let* ((times (ebox-surface--observation-phase-times context))
           (entry (assq previous times)))
      (if entry
          (setcdr entry (+ (cdr entry) (- now started)))
        (push (cons previous (- now started)) times))
      (setf (ebox-surface--observation-phase-times context) times)))
  (setf (ebox-surface--observation-phase context) phase
        (ebox-surface--observation-phase-start context) now))

(defun ebox-surface--observe-phase (phase function)
  "Measure FUNCTION in PHASE, excluding its nested observed phases."
  (let* ((context ebox-surface--observation-context)
         (previous (ebox-surface--observation-phase context)))
    (if (ebox-surface--observation-finished-p context)
        (funcall function)
      (ebox-surface--observation-switch-phase context phase (float-time))
      (unwind-protect (funcall function)
        (ebox-surface--observation-switch-phase context previous (float-time))))))

(defun ebox-surface--observation-gc-snapshot ()
  "Return current GC count and elapsed seconds."
  (cons (if (boundp 'gcs-done) gcs-done 0)
        (if (boundp 'gc-elapsed) gc-elapsed 0.0)))

(defun ebox-surface--observation-discard (context)
  "Remove pending observation CONTEXT from its owning buffer."
  (when-let* ((buffer (ebox-surface--observation-buffer context))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (setq ebox-surface--observation-contexts
            (delq context ebox-surface--observation-contexts)))))

(defun ebox-surface--decorate-observation-report (context report)
  "Return CONTEXT metadata attached to defensive Ebox REPORT copy."
  (let* ((result (copy-tree report))
         (gc-start (ebox-surface--observation-gc-start context))
         (gc (ebox-surface--observation-gc-end context))
         (ebox--pub-report (ebox-surface--observation-publication-report context)))
    (dolist (entry
             `((:provider . ebox)
               (:stage . ,(ebox-surface--observation-stage context))
               (:correlation-id
                . ,(ebox-surface--observation-correlation-id context))
               (:duration-ms
                . ,(* 1000.0
                      (- (ebox-surface--observation-finished context)
                         (ebox-surface--observation-started context))))
               (:gc-count . ,(- (car gc) (car gc-start)))
               (:gc-duration-ms . ,(* 1000.0 (- (cdr gc) (cdr gc-start))))
               (:publication-duration-ms . ,(plist-get ebox--pub-report :duration-ms))))
      (setq result (plist-put result (car entry) (cdr entry))))
    (setq result
          (plist-put result :phase-duration-ms
                     (cl-loop for phase in '(source style plan layout projection transaction)
                              append (list phase (* 1000.0 (or (cdr (assq phase
                                                 (ebox-surface--observation-phase-times context))) 0.0))))))
    result))

(defun ebox-surface--observation-mount-report (context)
  "Build CONTEXT's transient initial-mount Ebox report."
  (let* ((buffer (ebox-surface--observation-buffer context))
         (surface (ebox-surface--live-buffer-surface buffer))
         (state (and surface (ebox--pub-surface-client-state surface)))
         (ebox--pub-report (and surface (ebox--pub-surface-report-summary surface))))
    (when (and surface state)
      (ebox-surface--commit-report
       surface state
       (ebox--update-report
        nil 'surface-mount
        :constraint-source 'declarative
        :dirty-count 1
        :patch-count
        (+ (or (plist-get ebox--pub-report :text-operations)
               0)
           (or (plist-get ebox--pub-report :property-operations)
               0)))))))

(defun ebox-surface--observation-deliver (context)
  "Deliver CONTEXT's paired reports once both phases are complete."
  (when (and (ebox-surface--observation-publication-report context)
             (ebox-surface--observation-ebox-report context)
             (not (ebox-surface--observation-finished-p context)))
    (setf (ebox-surface--observation-finished-p context) t)
    (ebox-surface--observation-discard context)
    (let ((observer (ebox-surface--observation-observer context))
          (reports
           (list
            (ebox-surface--observation-publication-report context)
            (ebox-surface--decorate-observation-report
             context (ebox-surface--observation-ebox-report context)))))
      (dolist (report reports)
        (let ((inhibit-quit t)
              (quit-flag nil))
          (condition-case nil
              (funcall observer
                       (ebox-surface--observation-buffer context)
                       (copy-tree report))
            ((error quit) nil)))))))

(defun ebox-surface--observation-finish (context)
  "Finish CONTEXT after Ebox finalization, excluding observer callbacks."
  (let ((finished (ebox-surface--observation-clock))
        (gc (ebox-surface--observation-gc-snapshot))
        (surface
         (ebox-surface--live-buffer-surface
          (ebox-surface--observation-buffer context))))
    ;; Public operations do not all return the Ebox update report: selector
    ;; updates return a summary and scroll returns a consumed distance.  The
    ;; retained client state is the single completed report authority after
    ;; the public call returns.
    (let ((report
           (unless (eq (ebox-surface--observation-stage context) 'mount)
             (and surface
                  (plist-get (ebox--pub-surface-client-state surface)
                             :last-update-report)))))
    (unless report
      (setq report (ebox-surface--observation-mount-report context)))
    (when report
      (ebox-surface--observation-switch-phase context nil finished)
      (setf (ebox-surface--observation-ebox-report context)
            report
            (ebox-surface--observation-finished context) finished
            (ebox-surface--observation-gc-end context) gc)))
    (if (ebox-surface--observation-correlation-id context)
        (ebox-surface--observation-deliver context)
      (ebox-surface--observation-discard context))))

(defun ebox-surface--capture-publication-observation (buffer report)
  "Capture accepted Ebox publication REPORT for BUFFER and complete matching
Ebox calls."
  (when (buffer-live-p buffer)
    (let ((correlation-id (plist-get report :transaction-id))
          matches)
      (with-current-buffer buffer
        (dolist (context ebox-surface--observation-contexts)
          (when (equal correlation-id
                       (ebox-surface--observation-correlation-id context))
            (push context matches))))
      (dolist (context (nreverse matches))
        (let ((ebox--pub-report (copy-tree report)))
          (setq ebox--pub-report
                (plist-put ebox--pub-report :correlation-id correlation-id))
          (setf (ebox-surface--observation-publication-report context) ebox--pub-report)
          (ebox-surface--observation-deliver context))))))

(defun ebox-surface--ensure-publication-observer (buffer)
  "Return BUFFER's stable Ebox publication observation bridge."
  (with-current-buffer buffer
    (or ebox-surface--publication-observer
        (setq ebox-surface--publication-observer
              (lambda (_surface report)
                (ebox-surface--capture-publication-observation buffer report))))))

(defun ebox-surface-set-buffer-observer (buffer observer)
  "Set BUFFER's Ebox OBSERVER, or remove it when OBSERVER is nil."
  (unless (or (null observer) (functionp observer))
    (signal 'wrong-type-argument (list 'functionp observer)))
  (let ((surface (ebox-surface--live-buffer-surface buffer)))
    (with-current-buffer buffer
      (if observer
          (let ((bridge (ebox-surface--ensure-publication-observer buffer)))
            (setq-local ebox-surface--buffer-observer observer)
            (when surface (ebox--pub-surface-add-observer surface bridge)))
        (when (and surface ebox-surface--publication-observer)
          (ebox--pub-surface-remove-observer surface ebox-surface--publication-observer))
        (setq-local ebox-surface--buffer-observer nil)
        (dolist (context ebox-surface--observation-contexts)
          (setf (ebox-surface--observation-finished-p context) t))
        (setq-local ebox-surface--observation-contexts nil))))
  observer)

(defun ebox-surface-buffer-observer (buffer)
  "Return BUFFER's current Ebox observer, or nil."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer ebox-surface--buffer-observer)))

(defun ebox-surface-call-with-observation (buffer stage function)
  "Call FUNCTION while observing BUFFER publication at STAGE."
  (let* ((current ebox-surface--observation-context)
         (observer (ebox-surface-buffer-observer buffer))
         (ebox-incremental--projection-rejections-enabled-p (and observer t)))
    (cond
     ((and current
           (not (ebox-surface--observation-finished-p current))
           (eq buffer (ebox-surface--observation-buffer current)))
      (funcall function))
     ((ebox-transaction-active-p)
      (error "Ebox public operation cannot join an outer Ebox publication transaction"))
     ((null observer)
      (funcall function))
     (t
      (let* ((surface (ebox-surface--live-buffer-surface buffer))
             (before-report (and surface (ebox--pub-surface-report-summary surface)))
             (context
              (ebox-surface--make-observation
               :buffer buffer :observer observer :stage stage
               :started (ebox-surface--observation-clock)
               :gc-start (ebox-surface--observation-gc-snapshot)
               :transaction-before (plist-get before-report :transaction-id))))
        (setf (ebox-surface--observation-phase context) 'transaction
              (ebox-surface--observation-phase-start context)
              (ebox-surface--observation-started context))
        (with-current-buffer buffer
          (push context ebox-surface--observation-contexts))
        (let ((ebox-surface--observation-context context)
              (ebox-incremental--phase-observer #'ebox-surface--observe-phase)
              result success)
          (unwind-protect
              (progn
                (setq result (funcall function)
                      success t)
                (ebox-surface--observation-finish context)
                result)
            (unless success
              (ebox-surface--observation-discard context)))))))))

(defun ebox-surface-cleanup-buffer-observer (buffer)
  "Remove BUFFER's Ebox publication bridge and all pending observation state."
  (when (buffer-live-p buffer)
    (let ((surface (ebox-surface--live-buffer-surface buffer)))
      (with-current-buffer buffer
        (when (and surface ebox-surface--publication-observer)
          (condition-case nil
              (ebox--pub-surface-remove-observer surface ebox-surface--publication-observer)
            (error nil)))
        (setq-local ebox-surface--buffer-observer nil)
        (setq-local ebox-surface--publication-observer nil)
        (setq-local ebox-surface--observation-contexts nil)))))

(defvar ebox-surface--scroll-line-fragment-cache
  (make-hash-table :test #'eq :weakness 'key)
  "Cached property-run templates for immutable rendered scroll lines.")

(defun ebox-surface--scroll-line-fragment-template (line)
  "Return a reusable fragment template for rendered LINE, or nil.
The cache is keyed by the immutable line string object retained by scroll
state.  Lines whose ownership is only implied through a neighboring line are
left on the conservative full fragment scanner path."
  (or (gethash line ebox-surface--scroll-line-fragment-cache)
      (let ((fragments (ebox-surface--rendered-fragments line)))
        (when (and fragments
                   (plist-get (car fragments) :paint-role-ids)
                   (plist-get (car (last fragments)) :paint-role-ids)
                   (cl-every (lambda (fragment)
                               (plist-get fragment :role-ids))
                             fragments))
          (puthash line fragments ebox-surface--scroll-line-fragment-cache)
          fragments))))

(defun ebox-surface--map-scroll-fragments (lines visit)
  "Call VISIT for LINES' cached fragments and intervening newline ownership.
VISIT receives a fragment, its line's absolute offset and its line index.
Return nil if a line needs the full scanner, otherwise return non-nil.
Unowned separators inherit the previous and next roles just as they do in
`ebox-surface--rendered-fragments'.  Cached line templates stay immutable."
  (cl-block ebox-surface--map-scroll-fragments
    (let ((offset 0) (line-index 0)
          (template (and lines
                         (ebox-surface--scroll-line-fragment-template
                          (car lines)))))
      (while lines
        (unless template
          (cl-return-from ebox-surface--map-scroll-fragments nil))
        (let ((length (length (car lines)))
              previous-roles)
          (dolist (fragment template)
            (funcall visit fragment offset line-index)
            (setq previous-roles (plist-get fragment :role-ids)))
          (setq lines (cdr lines))
          (when lines
            (setq template
                  (ebox-surface--scroll-line-fragment-template (car lines)))
            (unless template
              (cl-return-from ebox-surface--map-scroll-fragments nil))
            (funcall visit
                     (list :text-source-p t :start length :end (1+ length)
                           :role-ids
                           (delete-dups
                            (append (copy-sequence previous-roles)
                                    (copy-sequence
                                     (plist-get (car template) :role-ids)))))
                     offset line-index))
          (setq offset (+ offset length 1)
                line-index (1+ line-index))))
      t)))

(defun ebox-surface--scroll-fragment-data (lines rendered)
  "Return offset fragments for visible LINES in RENDERED, or nil.
Each cached line template is copied only at the plist spine and points at the
single joined RENDERED string.  The text and role values remain candidate
owned; no per-fragment substring is allocated."
  (let (result)
    (when (ebox-surface--map-scroll-fragments
           lines
           (lambda (fragment offset line-index)
             (let ((copy (copy-sequence fragment)))
               (plist-put copy :text rendered)
               (plist-put copy :start (+ offset (plist-get fragment :start)))
               (plist-put copy :end (+ offset (plist-get fragment :end)))
               (plist-put copy :line line-index)
               (push copy result))))
      (nreverse result))))

(defun ebox-surface--scroll-lines-owned-p (lines)
  "Return non-nil when every rendered line has an owned fragment template."
  (and lines
       (cl-every #'ebox-surface--scroll-line-fragment-template lines)))

(defun ebox-surface--style-state-table (previous-state)
  "Copy PREVIOUS-STATE style states for candidate binding lookup.
Complete object projection selects the new generation's owned subset."
  (let ((table (make-hash-table :test 'eq :weakness 'key)))
    (when-let* ((previous (plist-get previous-state :style-binding-states)))
      (maphash (lambda (object state) (puthash object state table)) previous))
    table))

(defun ebox-surface--project-style-states (context states node-objects)
  "Return STATES owned by CONTEXT's candidate NODE-OBJECTS and bindings.
Removed objects and omitted style bindings still exist until publication
settles their lifecycle.  Their liveness therefore cannot identify the next
generation's style graph.  Use the same selected bindings that publication
will retain, keeping the accepted table untouched if this candidate fails."
  (let ((projected (make-hash-table :test 'eq :weakness 'key))
        (bindings (ebox--pub--context-bindings context)))
    (maphash
     (lambda (_id object)
       (when-let* ((state (gethash object states))
                   (binding (plist-get state :binding))
                   ((gethash binding bindings)))
         (puthash object state projected)))
     node-objects)
    projected))

(defun ebox-surface--stylesheet-signature ()
  "Return one immutable snapshot of the active Ebox stylesheet."
  (list (ecss-stylesheet-rules ebox-style-stylesheet)
        (ecss-stylesheet-layers ebox-style-stylesheet)
        (mapcar (lambda (scope)
                  (gethash scope ebox-style--scope-source-signatures))
                ebox-style--scopes)))

(defun ebox-surface--subject-signature (subject)
  "Return SUBJECT's complete selector subtree without retaining parent cycles."
  (cl-labels
      ((subtree (node)
         (list (ebox-selector-subject-type node) (ebox-selector-subject-id node)
               (ebox-selector-subject-classes node)
               (ebox-selector-subject-attributes node)
               (ebox-selector-subject-states node)
               (mapcar #'subtree (ebox-selector-view-children node)))))
    (subtree subject)))

(defun ebox-surface--subject-local-equal-p (left right)
  "Return non-nil when LEFT and RIGHT expose equal local selector fields."
  (and left right
       (equal (ebox-selector-subject-type left) (ebox-selector-subject-type right))
       (equal (ebox-selector-subject-id left) (ebox-selector-subject-id right))
       (equal (ebox-selector-subject-classes left) (ebox-selector-subject-classes right))
       (equal (ebox-selector-subject-attributes left)
              (ebox-selector-subject-attributes right))
       (equal (ebox-selector-subject-states left) (ebox-selector-subject-states right))))

(defun ebox-surface--subject-style-context (node subject stylesheet-signature)
  "Snapshot NODE's local selector context for SUBJECT.
Use only after ECSS classifies every selector as subject-local.  Keep the
complete ancestor identity chain to prove scoped root relationships.  A scope
can only contribute declarations to its declared targets; changes to other
members do not alter this subject's ordered rule inputs.  Matching and cascade
remain ECSS-owned.  Structural selectors never use this context."
  (let ((identity (ebox-source--handle-id-view (ebox-tree-node-source-handle node)))
        (ancestor subject) ancestors scopes)
    (while ancestor
      (push (ebox-selector-subject-token ancestor) ancestors)
      (setq ancestor (ebox-selector-view-parent ancestor)))
    (dolist (signature (nth 2 stylesheet-signature))
      (let ((targets (plist-get signature :targets)))
        (when (or (eq targets t) (member identity targets))
          (push (list (plist-get signature :root) (plist-get signature :rules)) scopes))))
    (list (car stylesheet-signature) (cadr stylesheet-signature)
          ancestors (nreverse scopes))))

(defun ebox-surface--stylesheet-subject-local-p
    (stylesheet-signature &optional fixed-scope-roots-p)
  "Classify rules in STYLESHEET-SIGNATURE with FIXED-SCOPE-ROOTS-P.
Scoped reuse also requires equal topology and scope signatures at each node."
  (and (or fixed-scope-roots-p (null (nth 2 stylesheet-signature)))
       (cl-every
        (lambda (rule)
          (and (null (ecss-rule-scope rule))
               (ecss-selector-subject-local-p (ecss-rule-selector rule))))
        (car stylesheet-signature))
       (or (null (nth 2 stylesheet-signature))
           (cl-every
            (lambda (scope)
              (cl-every
               (lambda (rule)
                 (and (null (ecss-rule-scope rule))
                      (ecss-selector-subject-local-p (ecss-rule-selector rule) t)))
               (ecss-stylesheet-rules (ecss-scope-stylesheet scope))))
            ebox-style--scopes))))

(defconst ebox-surface--root-key 'ebox/surface
  "Stable Ebox publication key for an Ebox surface projection root.")

(defconst ebox-surface--nodes-key 'ebox/nodes
  "Stable Ebox publication key for the retained logical Ebox node tree.")

(defconst ebox-surface--fragments-key 'ebox/fragments
  "Stable Ebox publication key for linear rendered fragments.")

(defconst ebox-surface--text-key 'ebox/text
  "Stable Ebox publication key for the shared rendered text leaf.")

(defconst ebox-surface--inherited-style-properties
  ebox-style--inherited-properties
  "ECSS properties whose inline values can flow to descendants.")

(defun ebox-surface--style-consuming-node-p (node)
  "Return non-nil when NODE owns a paintable style surface."
  (eq (plist-get node :ebox-type) 'box))

(defun ebox-surface--inherited-style-consumer-p (node)
  "Return non-nil when NODE materializes inherited text style.
Canonical Box passes inherited facts through to descendants; canonical Text
is their final paint/typography owner.  A legacy Box without a canonical kind
continues to own its inline text directly."
  (and (eq (plist-get node :ebox-type) 'box)
       (or (eq (plist-get node :ebox-kind) 'text)
           (null (plist-get node :ebox-kind)))))

(defun ebox-surface--inline-inheritance-required-p (root source-index)
  "Return non-nil when ROOT in SOURCE-INDEX requires an ECSS cascade.
An empty stylesheet still needs a cascade when an inherited declaration can
reach a descendant that does not declare the same property, or when tagged
values and custom properties need contextual computation.  Other inline
declarations are already projected into the candidate engine fields at node
construction time and can use the static projection path."
  (let ((pending (list (cons root nil)))
        required)
    (while (and pending (not required))
      (let* ((entry (pop pending))
             (node (car entry))
             (inherited (cdr entry))
             (declarations
              (ebox-style-node-declarations source-index node)))
        (when (or (ebox-style--deferred-declarations-p declarations)
                  (cl-some (lambda (property)
                             (and (ebox-surface--inherited-style-consumer-p node)
                                  (memq property inherited)
                                  (not (plist-member declarations property))))
                           ebox-surface--inherited-style-properties))
          (setq required t))
        (unless required
          (let ((next (copy-sequence inherited)))
            (dolist (property ebox-surface--inherited-style-properties)
              (when (plist-member declarations property)
                (cl-pushnew property next)))
            (ebox-tree-for-each-direct-child
             node (lambda (child) (push (cons child next) pending)))))))
    required))

(defun ebox-surface--signals-live-p (signals)
  "Return non-nil when every signal in SIGNALS is live."
  (and (ebox-surface--signals-p signals)
       (buffer-live-p (ebox-surface--signals-buffer signals))
       (cl-every
        #'ebox--pub-signal-live-p
        (list (ebox-surface--signals-viewport-width signals)
              (ebox-surface--signals-viewport-height signals)
              (ebox-surface--signals-display signals)
              (ebox-surface--signals-scroll signals)))))

(defun ebox-surface--dispose-signals (signals)
  "Dispose live Ebox publication SIGNALS owned by an abandoned Ebox mount."
  (when (ebox-surface--signals-p signals)
    (dolist (signal
             (list (ebox-surface--signals-viewport-width signals)
                   (ebox-surface--signals-viewport-height signals)
                   (ebox-surface--signals-display signals)
                   (ebox-surface--signals-scroll signals)))
      (when (ebox--pub-signal-live-p signal)
        (ebox--pub-signal-dispose signal)))
    (when-let* ((buffer (ebox-surface--signals-buffer signals)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (eq ebox-surface--context-signals signals)
            (setq-local ebox-surface--context-signals nil)))))))

(defun ebox-surface--scroll-offsets (table)
  "Return immutable sorted scroll offsets copied from TABLE."
  (let (offsets)
    (when (hash-table-p table)
      (maphash
       (lambda (region-id state)
         (push (cons region-id (or (plist-get state :scroll-offset) 0))
               offsets))
       table))
    (sort offsets (lambda (left right) (< (car left) (car right))))))

(defun ebox-surface--buffer-display-window (buffer)
  "Return the canonical live display window for BUFFER.
Prefer the window the user is interacting with, then the selected frame, then
another visible frame.  One mounted surface owns one viewport, so all context
and resize paths must consume this same choice."
  (or (and (window-live-p (selected-window))
           (eq (window-buffer (selected-window)) buffer)
           (selected-window))
      (get-buffer-window buffer (selected-frame))
      (get-buffer-window buffer t)
      (and (not noninteractive) (selected-window))))

(defun ebox-surface--context-values
    (buffer old-state state-overrides)
  "Return BUFFER context values after OLD-STATE and STATE-OVERRIDES."
  (cl-labels
      ((value (key fallback)
         (if (plist-member state-overrides key)
             (plist-get state-overrides key)
           (if (plist-member old-state key)
               (plist-get old-state key)
             fallback))))
    (let ((scroll-table
           (value :scroll-state-table
                  (plist-get old-state :scroll-state-table)))
          (window (ebox-surface--buffer-display-window buffer)))
      (list :viewport-width
            (value :viewport-width
                   (or ebox-viewport-width
                       (and (window-live-p window)
                            (ebox-surface--window-content-width window))))
            :viewport-height
            (value :viewport-height
                   (or ebox-viewport-height
                       (and (window-live-p window)
                            (window-body-height window))))
            :display-signature
            (value :display-signature
                   (with-current-buffer buffer
                     (ebox--display-signature-for-window window)))
            :display-window window
            :scroll-offsets
            (ebox-surface--scroll-offsets scroll-table)))))

(defun ebox-surface--window-content-width (window)
  "Return a safe pixel content width for live WINDOW.
Some Emacs GUI builds return a column-like half-width even when
`window-body-width' is called with PIXELWISE non-nil.  When the result is
clearly inconsistent with the outer pixel width, prefer the outer width and
reserve two character columns for Emacs continuation/truncation display.
Headless/test windows retain the body width fallback."
  (let ((body
         (condition-case nil
             (window-body-width window t)
           (wrong-number-of-arguments nil)))
        (outer
         (condition-case nil
             (window-pixel-width window)
           (error nil))))
    (let* ((char-width
            (condition-case nil
                (frame-char-width (window-frame window))
              (error 1)))
           (reserve (max 2 (* 2 (max 1 char-width)))))
      (max 0
           (- (if (and body outer (> outer (* 1.8 body)))
                  outer
                (or body outer 0))
              reserve)))))

(defun ebox-surface--ensure-signals (buffer values)
  "Return BUFFER's context signals for VALUES and whether they were created."
  (let ((signals
         (with-current-buffer buffer ebox-surface--context-signals)))
    (if (ebox-surface--signals-live-p signals)
        (cons signals nil)
      (when signals (ebox-surface--dispose-signals signals))
      (setq signals
            (ebox-surface--make-signals
             :buffer buffer
             :viewport-width
             (ebox--pub-signal-create (plist-get values :viewport-width)
                               :scope buffer)
             :viewport-height
             (ebox--pub-signal-create (plist-get values :viewport-height)
                               :scope buffer)
             :display
             (ebox--pub-signal-create (plist-get values :display-signature)
                               :scope buffer)
             :scroll
             (ebox--pub-signal-create (plist-get values :scroll-offsets)
                               :scope buffer)))
      (with-current-buffer buffer
        (setq-local ebox-surface--context-signals signals))
      (cons signals t))))

(defun ebox-surface--stage-signal-values (signals values)
  "Stage VALUES into Ebox publication context SIGNALS in the active
transaction."
  (ebox--pub-signal-set (ebox-surface--signals-viewport-width signals)
                 (plist-get values :viewport-width))
  (ebox--pub-signal-set (ebox-surface--signals-viewport-height signals)
                 (plist-get values :viewport-height))
  (ebox--pub-signal-set (ebox-surface--signals-display signals)
                 (plist-get values :display-signature))
  (ebox--pub-signal-set (ebox-surface--signals-scroll signals)
                 (plist-get values :scroll-offsets)))

(defun ebox-surface--live-buffer-surface (buffer)
  "Return BUFFER's live Ebox Ebox publication surface, or nil."
  (when (buffer-live-p buffer)
    (let ((surface
           (with-current-buffer buffer ebox-surface--buffer-surface)))
      (and (ebox--pub-surface-live-p surface) surface))))

(defun ebox-surface--buffer-client-state (buffer)
  "Return BUFFER's live Ebox publication client state for incremental context
reads."
  (when-let* ((surface (ebox-surface--live-buffer-surface buffer)))
    (ebox--pub-surface-client-state surface)))

(defun ebox-surface-buffer-mounted-p (buffer)
  "Return non-nil when BUFFER has a live Ebox Ebox publication surface."
  (not (null (ebox-surface--live-buffer-surface buffer))))

(defun ebox-surface-buffer-revision (buffer)
  "Return BUFFER's committed Ebox publication surface revision or fail when
unmounted."
  (if-let* ((surface (ebox-surface--live-buffer-surface buffer)))
      (ebox--pub-surface-revision surface)
    (error "Ebox buffer has no committed surface revision: %S" buffer)))

(defun ebox-surface--snapshot-root (root)
  "Detach ROOT's structural and mutable input data from a live mount.  Opaque
capabilities, including functions, keymaps and source handles, keep
identity.  No runtime identity, cache or Ebox publication attachment is
exported."
  (let ((copy (ebox-tree-copy-node-structure root))
        (copies (make-hash-table :test #'eq)))
    (cl-labels
        ((data (value)
           (cond
            ((or (functionp value) (keymapp value)) value)
            ((gethash value copies))
            ((ebox-layout-config-p value)
             (let ((result (ebox-layout-config--copy value)))
               (puthash value result copies)
               result))
            ((recordp value) value)
            ((stringp value)
             (let ((result (copy-sequence value)) (position 0))
               (puthash value result copies)
               (while (< position (length value))
                 (let ((end (next-property-change position value (length value))))
                   (set-text-properties position end
                                        (data (text-properties-at position value))
                                        result)
                   (setq position end)))
               result))
            ((consp value)
             (let ((result (cons nil nil)))
               (puthash value result copies)
               (setcar result (data (car value)))
               (setcdr result (data (cdr value)))
               result))
            ((hash-table-p value)
             (let ((result (copy-hash-table value)))
               (puthash value result copies)
               (clrhash result)
               (maphash (lambda (key item) (puthash (data key) (data item) result))
                        value)
               result))
            ((char-table-p value)
             (let* ((result (copy-sequence value))
                    (default (char-table-range value nil))
                    (parent (char-table-parent value))
                    (missing (make-symbol "no-extra-slot"))
                    (index 0)
                    extra)
               (puthash value result copies)
               ;; Traverse only explicit entries; materializing inherited or
               ;; default values would change later lookup semantics.
               (set-char-table-parent result nil)
               (set-char-table-range result nil nil)
               (map-char-table
                (lambda (range item) (set-char-table-range result range (data item)))
                result)
               (set-char-table-range result nil (data default))
               (set-char-table-parent result (data parent))
               (while (not (eq missing
                               (setq extra
                                     (condition-case nil
                                         (char-table-extra-slot value index)
                                       (args-out-of-range missing)))))
                 (set-char-table-extra-slot result index (data extra))
                 (setq index (1+ index)))
               result))
            ((vectorp value)
             (let ((result (copy-sequence value)))
               (puthash value result copies)
               (dotimes (index (length result))
                 (aset result index (data (aref value index))))
               result))
            ((bool-vector-p value)
             (let ((result (copy-sequence value)))
               (puthash value result copies)
               result))
            (t value)))
         (visit (node)
           (let ((children (ebox-tree-node-children node)))
             (cl-loop for tail on node by #'cddr
                      for key = (car tail)
                      unless (and (memq key ebox-tree--child-source-keys)
                                  ;; Coordinate names also describe old
                                  ;; concat/stack child slots.  Only actual
                                  ;; child values were detached structurally.
                                  (or (not (memq key '(:left :right :top :bottom)))
                                      (memq (cadr tail) children)))
                      do (setcar (cdr tail)
                                 (unless (memq key ebox-tree--runtime-source-keys)
                                   (data (cadr tail))))))
           (ebox-tree-for-each-direct-child node #'visit)))
      (visit copy))
    copy))

(defun ebox-surface-buffer-snapshot (buffer)
  "Export BUFFER's current committed canonical input on explicit request.
Return a plist with :input, :revision and :mount-id.  The integer mount ID
distinguishes remounts whose revisions may coincide.  Query is rejected
while a Ebox publication transaction is active or BUFFER has no live Ebox
surface.

This explicit operation copies node structure and mutable input data,
freezes private prepared geometry declarations, and retains sealed immutable
source facts and opaque capabilities such as
callbacks and keymaps.  It neither renders nor publishes, and never advances
the revision.  Cost is linear in exported data plus Ebox's latest retained
diagnostic report.  The returned input survives later commits and
unmounting; it can be rendered independently.  It does not freeze external
capabilities or the display environment, and old Host references gain no
authority over another mount."
  (when (ebox-transaction-active-p)
    (error "Ebox committed snapshot is unavailable during a Ebox publication transaction"))
  (let* ((surface (or (ebox-surface--live-buffer-surface buffer)
                      (error "Ebox buffer has no committed snapshot: %S" buffer)))
         (state (ebox--pub-surface-client-state surface))
         (revision (ebox--pub-surface-revision surface))
         (root (ebox-surface--snapshot-root (plist-get state :root-node)))
         (builder (ebox-source-builder-create)))
    ;; Import detaches private prepared declaration cells; the copied node
    ;; geometry above and this source generation must both remain frozen.
    (ebox-source-builder-import builder (plist-get state :source-index))
    (list :input (ebox-canonical-input-create
                  (list root) (ebox-source-builder-finish builder))
          :revision revision
          :mount-id (plist-get (ebox--pub-surface-inspect surface) :id))))

(defun ebox-surface-region-mounts (buffer region-id &optional roles)
  "Return REGION-ID's Ebox-owned output mounts in BUFFER.  When ROLES is
non-nil, keep only direct mounts owning a listed Ebox role.  Without ROLES,
include descendant output attached to the region's object.  The returned
ranges are numeric snapshots; Ebox publication retains marker ownership."
  (when-let* ((surface (ebox-surface--live-buffer-surface buffer))
              (state (ebox--pub-surface-client-state surface))
              (table (plist-get state :region-surface-object-table))
              (object (gethash region-id table)))
    (cl-remove-if-not
     (lambda (mount)
       (let ((tags (plist-get mount :tags)))
         (if roles
             (and (equal (plist-get tags :ebox/region-id) region-id)
                  (cl-intersection roles (plist-get tags :ebox/roles)))
           (or (equal (plist-get tags :ebox/region-id) region-id)
               (plist-get tags :ebox/descendant-output)))))
     (ebox--pub-object-mounts object))))

(defun ebox-surface-region-bounds (buffer region-id &optional roles)
  "Return numeric bounds for REGION-ID's Ebox publication mounts in BUFFER.
ROLES has the same filtering meaning as in `ebox-surface-region-mounts'."
  (when-let* ((mounts (ebox-surface-region-mounts buffer region-id roles)))
    (cons (apply #'min (mapcar (lambda (mount) (plist-get mount :start)) mounts))
          (apply #'max (mapcar (lambda (mount) (plist-get mount :end)) mounts)))))

(defun ebox-surface--runtime-keys (state key)
  "Return hash keys stored under KEY in runtime STATE."
  (when-let* ((table (plist-get state key)))
    (ebox-surface--hash-keys table)))

(defun ebox-surface--bind-scroll-states-to-buffer (state buffer)
  "Bind every semantic scroll state in STATE to its owning BUFFER."
  (when-let* ((table (plist-get state :scroll-state-table)))
    (maphash
     (lambda (region-id scroll-state)
       (puthash region-id (plist-put scroll-state :buffer buffer) table))
     table)))

(defun ebox-surface--commit-report (surface state report-base)
  "Return Ebox's compact report for SURFACE, STATE, and REPORT-BASE."
  (let* ((ebox--pub-report (ebox--pub-surface-report-summary surface))
         (text-operations (or (plist-get ebox--pub-report :text-operations) 0))
         (property-operations
          (or (plist-get ebox--pub-report :property-operations) 0))
         (patch-count (+ text-operations property-operations))
         (report (copy-sequence report-base))
         (planned-projection (plist-get report-base :projection-kind))
         (native-fallback-reason
          (or (plist-get state :native-render-fallback)
              (plist-get state :native-session-setup-failure)))
         (scoped-p (and (not (plist-get ebox--pub-report :full-root))
                        (> (or (plist-get ebox--pub-report :scope-count) 0) 0)))
         (planned-publication-scope (plist-get report :publication-scope)))
    (dolist (entry
             `((:runtime-published . t)
               (:runtime-revision . ,(plist-get state :runtime-revision))
               (:projection-kind . ,(plist-get state :projection-kind))
               (:native-frame-kind . ,(plist-get state :native-frame-kind))
               (:native-declined-reason . ,(plist-get state :native-render-declined))
               (:surface-revision . ,(ebox--pub-surface-revision surface))
               (:publication-scope . ebox--pub-surface)
               (:planned-publication-scope . ,planned-publication-scope)
               (:publication-render-scope . ,(if scoped-p 'objects 'surface-plan))
               (:publication-full-root . ,(plist-get ebox--pub-report :full-root))
               (:publication-scope-count . ,(plist-get ebox--pub-report :scope-count))
               (:publication-scope-range-count
                . ,(plist-get ebox--pub-report :scope-range-count))
               (:publication-scope-fallback . ,(plist-get ebox--pub-report :scope-fallback))
               (:publication-retained-content . ,(plist-get ebox--pub-report :retained-content-p))
               (:publication-operation-count . ,patch-count)
               (:publication-transaction-id . ,(plist-get ebox--pub-report :transaction-id))
               (:publication-text-operations . ,text-operations)
               (:publication-property-operations . ,property-operations)
               (:reconciled-objects
                . ,(plist-get ebox--pub-report :reconciled-objects))
               (:created-objects . ,(plist-get ebox--pub-report :created-objects))
               (:removed-objects . ,(plist-get ebox--pub-report :removed-objects))
               (:moved-objects . ,(plist-get ebox--pub-report :moved-objects))))
      (setq report (plist-put report (car entry) (cdr entry))))
    (when (and ebox-incremental--projection-rejections-enabled-p
               (memq planned-projection
                     '(span-patch owner-scoped formatting-context-reflow
                       mixed-owner-reflow scroll-patch))
               (null (plist-get state :projection-kind)))
      (setq report
            (plist-put report :projection-rejections
                       (append (plist-get report :projection-rejections)
                               (list (list :projection planned-projection
                                           :reasons '(output-proof)))))))
    (when (and ebox-incremental--projection-rejections-enabled-p
               (plist-get state :fragment-reuse-rejection))
      (setq report (plist-put report :projection-rejections
                              (append (plist-get report :projection-rejections)
                                      (list (list :projection 'fragment-ledger
                                                  :reasons (list (plist-get state :fragment-reuse-rejection))))))))
    (when native-fallback-reason
      ;; Planner fields describe the rejected native attempt.  Replace them
      ;; with the ordinary full-surface publication that actually committed;
      ;; preserve the attempt only as report diagnostics.
      (dolist (key '(:owner-ids :owner-type
                     :constraint-owner-id :constraint-owner-type))
        (cl-remf report key))
      (setq report (plist-put report :strategy 'ordinary-fallback))
      (setq report
            (plist-put report :patch-ops
                       (and (> patch-count 0) '(ebox--pub-surface))))
      (setq report (plist-put report :patch-count patch-count))
      (setq report (plist-put report :render-scope 'surface))
      (setq report (plist-put report :publication-scope 'root))
      (setq report (plist-put report :root-rerender t))
      (setq report (plist-put report :native-attempt 'failed))
      (setq report
            (plist-put report :native-fallback-reason
                       native-fallback-reason))
      (cl-remf state :native-render-fallback)
      (cl-remf state :native-session-setup-failure))
    (cl-remf state :native-render-declined)
    (unless (plist-member report :strategy)
      (setq report
            (plist-put report :strategy
                       (if (zerop patch-count) 'no-op 'surface-commit))))
    (unless (plist-member report :constraint-source)
      (setq report (plist-put report :constraint-source 'declarative)))
    (unless (plist-member report :constraint-root-node-id)
      (setq report
            (plist-put report :constraint-root-node-id
                       (plist-get (plist-get state :root-node) :node-id))))
    (unless (plist-member report :dirty-count)
      (setq report
            (plist-put report :dirty-count
                       (if (zerop patch-count) 0 1))))
    (unless (plist-member report :patch-count)
      (setq report (plist-put report :patch-count patch-count)))
    (unless (plist-member report :patch-ops)
      (setq report
            (plist-put report :patch-ops
                       (and (> patch-count 0) '(ebox--pub-surface)))))
    report))

(defun ebox-surface--participant-report (participant report state)
  "Attach PARTICIPANT's read-only STATE and diagnostics to REPORT."
  (when participant
    (setq report (plist-put report :framework-participant-state state))
    (setq report
          (plist-put report :framework-participant-diagnostics
                     (copy-tree
                      (ebox-surface--framework-participant-diagnostics
                       participant))))
    (setq report
          (plist-put report :scroll-finalization-diagnostics
                     (copy-tree
                      (ebox-surface--framework-participant-scroll-diagnostics
                       participant))))
    (setf (ebox-surface--framework-participant-report participant) report))
  report)

(defun ebox-surface--participant-run-publish (participant report)
  "Publish PARTICIPANT with REPORT exactly once and return updated REPORT."
  (unless (eq (ebox-surface--framework-participant-state participant)
              'unpublished)
    (error "Ebox framework participant is not unpublished"))
  (setf (ebox-surface--framework-participant-state participant) 'published)
  (setq report (ebox-surface--participant-report participant report 'published))
  (when-let* ((publish (ebox-surface--framework-participant-publish participant)))
    (funcall publish report))
  report)

(defun ebox-surface--participant-run-rollback (participant)
  "Run PARTICIPANT's paired rollback once without allowing failure to escape."
  (when (and participant
             (eq (ebox-surface--framework-participant-state participant)
                 'published))
    (setf (ebox-surface--framework-participant-state participant) 'rolled-back)
    (ebox-surface--participant-report
     participant (ebox-surface--framework-participant-report participant)
     'rolled-back)
    (when-let* ((rollback
                (ebox-surface--framework-participant-rollback participant)))
      (let ((inhibit-quit t)
            (quit-flag nil))
        (condition-case failure
            (funcall rollback
                     (ebox-surface--framework-participant-report participant))
          ((error quit)
           (push (list :phase 'framework-rollback :condition failure)
                 (ebox-surface--framework-participant-diagnostics
                  participant))))))
    (ebox-surface--participant-report
     participant (ebox-surface--framework-participant-report participant)
     'rolled-back)))

(defun ebox-surface--participant-complete (participant diagnostics)
  "Complete PARTICIPANT after scroll DIAGNOSTICS are contained."
  (when participant
    (setf (ebox-surface--framework-participant-scroll-diagnostics participant)
          diagnostics)
    (let* ((state
            (ebox-surface--framework-participant-runtime-state participant))
           (report (ebox-surface--framework-participant-report participant))
           (started
            (plist-get report :framework-initial-observation-started)))
      (when started
        (let* ((surface (plist-get state :surface))
               (ebox--pub-report (ebox--pub-surface-report surface))
               (transaction-id (plist-get ebox--pub-report :transaction-id))
               (ebox-report (copy-tree report)))
          (cl-remf report :framework-initial-observation-started)
          (cl-remf ebox-report :framework-initial-observation-started)
          (dolist (entry `((:provider . ebox-publication)
                           (:stage . publication)
                           (:status . success)
                           (:correlation-id . ,transaction-id)))
            (setq ebox--pub-report (plist-put ebox--pub-report (car entry) (cdr entry))))
          (dolist (entry `((:provider . ebox)
                           (:stage . mount)
                           (:status . success)
                           (:duration-ms
                            . ,(* 1000.0 (- (float-time) started)))
                           (:correlation-id . ,transaction-id)
                           (:framework-participant-state . completed)))
            (setq ebox-report (plist-put ebox-report (car entry) (cdr entry))))
          (setq report
                (plist-put
                 report :framework-initial-observation-reports
                 (list ebox--pub-report ebox-report)))))
      (plist-put state :last-update-report
                 (ebox-surface--participant-report
                  participant report 'completed)))
    (setf (ebox-surface--framework-participant-state participant) 'completed)))

(defun ebox-surface--participant-complete-postaccept (participant diagnostics)
  "Complete PARTICIPANT with DIAGNOSTICS after accept without throwing."
  (when participant
    (let ((inhibit-quit t) (quit-flag nil) completion-condition)
      (condition-case condition
          (ebox-surface--participant-complete participant diagnostics)
        ((error quit) (setq completion-condition condition)))
      (when completion-condition
        (let* ((diagnostic
                (list :phase 'framework-report-finalization
                      :condition (copy-tree completion-condition)))
               (state
                (ebox-surface--framework-participant-runtime-state participant))
               (report
                (ebox-surface--framework-participant-report participant)))
          (push diagnostic
                (ebox-surface--framework-participant-diagnostics participant))
          (setf (ebox-surface--framework-participant-scroll-diagnostics
                 participant)
                diagnostics)
          (unwind-protect
              (condition-case secondary
                  (progn
                    (cl-remf report :framework-initial-observation-started)
                    (setq report
                          (plist-put report :framework-participant-state
                                     'completed)
                          report
                          (plist-put
                           report :framework-participant-diagnostics
                           (copy-tree
                            (ebox-surface--framework-participant-diagnostics
                             participant)))
                          report
                          (plist-put report :scroll-finalization-diagnostics
                                     (copy-tree diagnostics)))
                    (setf (ebox-surface--framework-participant-report participant)
                          report)
                    (when state
                      (plist-put state :last-update-report report)))
                ((error quit)
                 (push (list :phase 'framework-report-finalization-diagnostic
                             :condition (copy-tree secondary))
                       (ebox-surface--framework-participant-diagnostics
                        participant))))
            (setf (ebox-surface--framework-participant-state participant)
                  'completed)))))
  participant))

(defun ebox-surface--publish-runtime-state
    (buffer surface old-state report-base after-publication
            &optional framework-participant observation-context)
  "Register BUFFER runtime publication for SURFACE after OLD-STATE.
REPORT-BASE requests an Ebox commit report.  AFTER-PUBLICATION, when
non-nil, runs after Ebox publication and Ebox point at the same candidate
generation.  FRAMEWORK-PARTICIPANT owns paired framework publication when
non-nil."
  (let ((interaction-snapshot (ebox-interaction--capture buffer))
        new-state region-snapshot scroll-snapshot
        old-surface old-mirror region-keys scroll-keys)
    (ebox-surface--transaction-participate
     (list 'ebox/runtime buffer)
     (lambda ()
       (setq new-state (ebox--pub-surface-client-state surface)
             old-surface
             (with-current-buffer buffer ebox-surface--buffer-surface)
             old-mirror (gethash buffer ebox--buffer-render-state-table)
             region-keys
             (delete-dups
              (append (ebox-surface--runtime-keys old-state :region-id-set)
                      (ebox-surface--runtime-keys new-state :region-id-set)))
             scroll-keys
             (delete-dups
              (append (copy-sequence (plist-get old-state :scroll-region-ids))
                      (copy-sequence (plist-get new-state :scroll-region-ids)))))
       (setq region-snapshot
             (ebox-incremental--hash-snapshot
              ebox--region-box-table region-keys)
             scroll-snapshot
             (ebox-incremental--hash-snapshot
              ebox--scroll-global-state scroll-keys))
       (when framework-participant
         (setf (ebox-surface--framework-participant-runtime-state
                framework-participant)
               new-state
               (ebox-surface--framework-participant-scroll-keys
                framework-participant)
               scroll-keys))
       (when observation-context
         (let* ((ebox--pub-report (ebox--pub-surface-report-summary surface))
                (transaction-id (plist-get ebox--pub-report :transaction-id)))
           (if (equal transaction-id
                      (ebox-surface--observation-transaction-before
                       observation-context))
               (ebox-surface--observation-discard observation-context)
             (setf (ebox-surface--observation-correlation-id
                    observation-context)
                   transaction-id))))
       (when new-state
         (plist-put new-state :surface surface)
         (plist-put new-state :runtime-revision
                    (1- (ebox--pub-surface-revision surface)))
         ;; Ebox publication now exposes this exact candidate revision, but the surrounding
         ;; transaction can still restore both Ebox publication and Ebox state.  Confirm the
         ;; private Rust frame here so a failure aborts publication and the
         ;; old confirmed session remains untouched.
         (when (plist-get new-state :native-sync-pending)
           (ebox-native-commit-confirm-published-frame
            new-state (ebox--pub-surface-revision surface)))
         ;; A fixed-basis role-owned patch rendered against the previous
         ;; allocation.  Its installed details describe that proof render,
         ;; not the now-committed Ebox publication mounts.  Drop only those owners' derived
         ;; geometry so the next transaction lazily captures the committed
         ;; spans and cannot drift across a repeated selection round trip.
         (when-let* ((snapshots (plist-get new-state :layout-snapshots)))
           (dolist (proof (plist-get new-state :owner-scoped-proofs))
             (when (plist-get proof :role-owned-lines-p)
               (let ((owner-id (plist-get proof :owner-id)))
                 (when-let* ((snapshot (gethash owner-id snapshots)))
                   (puthash owner-id
                            (ebox--layout-snapshot-strip-details snapshot)
                            snapshots))))))
         (when (plist-get report-base :scroll-state-transaction)
           ;; Scroll changes invalidate every buffer-span coordinate.  Keep
           ;; the committed generation structurally snapshot-free so a later
           ;; hidden-owner update recaptures spans from the current buffer,
           ;; never from the pre-scroll marker positions.
           (plist-put new-state :layout-snapshots
                      (make-hash-table :test 'equal))
           (plist-put new-state :layout-snapshots-complete-p nil))
         (ebox-surface--bind-scroll-states-to-buffer new-state buffer)
         ;; Prepared ownership programs need a durable topology proof, not a
         ;; second traversal of every node after a paint/placement publication.
         ;; The accepted dirty classification and publisher identity facts are
         ;; authoritative here; an unknown or structural transition retires it.
         (let ((published (ebox--pub-surface-report-summary surface)))
           (plist-put
            new-state :geometry-topology-generation
            (if (and old-mirror
                     (plist-get old-mirror :geometry-topology-generation)
                     (plist-member report-base :dirty-kinds)
                     (not (memq 'structure (plist-get report-base :dirty-kinds)))
                     (eql 0 (plist-get published :created-objects))
                     (eql 0 (plist-get published :removed-objects))
                     (eql 0 (plist-get published :moved-objects)))
                (plist-get old-mirror :geometry-topology-generation)
              (list 'ebox/geometry-topology))))
         (when report-base
           (plist-put new-state :last-update-report
                      (ebox-surface--commit-report
                       surface new-state report-base))))
       (with-current-buffer buffer
         (setq-local ebox-surface--buffer-surface surface))
       (if new-state
           (progn
             ;; Preserve the committed layer ledger for the next candidate.
             ;; The renderer owns the fresh candidate cache; this fallback
             ;; keeps it alive across publication paths that do not render.
             (when (and old-mirror
                        (null (plist-get new-state :layer-composition-cache)))
               (plist-put new-state :layer-composition-cache
                          (plist-get old-mirror :layer-composition-cache)))
             (puthash buffer new-state ebox--buffer-render-state-table))
         (remhash buffer ebox--buffer-render-state-table))
       (ebox-incremental--replace-hash-entries
        ebox--region-box-table region-keys
        (plist-get new-state :region-box-table))
       (ebox-incremental--replace-hash-entries
        ebox--scroll-global-state scroll-keys
        (plist-get new-state :scroll-state-table))
       (ebox-interaction--publish buffer interaction-snapshot)
       (if framework-participant
           (plist-put
            new-state :last-update-report
            (ebox-surface--participant-run-publish
             framework-participant
             (plist-get new-state :last-update-report)))
         (when after-publication
           (funcall after-publication
                    (plist-get new-state :last-update-report))))
       (unless (buffer-live-p buffer)
         (error "Ebox declarative target died during publication")))
     (lambda ()
       (unwind-protect
           (progn
             (ebox-surface--participant-run-rollback framework-participant)
             (ebox-interaction--rollback buffer interaction-snapshot)
             (when observation-context
               (ebox-surface--observation-discard observation-context)))
         (if (buffer-live-p buffer)
             (progn
               (when region-snapshot
                 (ebox-incremental--restore-hash-snapshot
                  ebox--region-box-table region-snapshot))
               (when scroll-snapshot
                 (ebox-incremental--restore-hash-snapshot
                  ebox--scroll-global-state scroll-snapshot))
               (with-current-buffer buffer
                 (setq-local ebox-surface--buffer-surface old-surface))
               (if old-mirror
                   (puthash buffer old-mirror ebox--buffer-render-state-table)
                 (remhash buffer ebox--buffer-render-state-table)))
           (remhash buffer ebox--buffer-render-state-table)
           (dolist (region-id region-keys)
             (remhash region-id ebox--region-box-table))
           (dolist (region-id scroll-keys)
             (ebox--scroll-clear-state region-id)
             (ebox--smooth-scroll-stop region-id)))))
     (lambda ()
       (ebox-interaction--focus-settle buffer interaction-snapshot new-state)))))

(defun ebox-surface-mount-buffer
    (buffer source &optional report-base after-publication
            preserve-identities-p state-overrides framework-participant
            projection-kind source-isolated-p)
  "Mount or atomically update BUFFER from Ebox SOURCE and return its surface.
REPORT-BASE requests a committed Ebox report.  AFTER-PUBLICATION runs inside
the rollback-capable transaction.  PRESERVE-IDENTITIES-P retains identities
already present in a logical candidate.  STATE-OVERRIDES augments its
runtime.  FRAMEWORK-PARTICIPANT retains post-Ebox publication publication
facts when non-nil.  PROJECTION-KIND and SOURCE-ISOLATED-P preserve a
prepared candidate's projection and ownership independently of whether
publication has an object scope."
  (let* ((observation-context ebox-surface--observation-context)
         (surface (ebox-surface--live-buffer-surface buffer))
         (old-state (and surface (ebox--pub-surface-client-state surface)))
         (context-values
          (ebox-surface--context-values buffer old-state state-overrides))
         (signals-result
          (ebox-surface--ensure-signals buffer context-values))
         (signals (car signals-result))
         (signals-created-p (cdr signals-result))
         (preserve-identities-p
          (or preserve-identities-p
              (and (null old-state)
                   (ebox-surface--source-identities-available-p
                    source buffer))))
         (producer
          (ebox-surface-producer
           source old-state preserve-identities-p state-overrides signals
           projection-kind source-isolated-p
           (plist-get state-overrides :source-path-copied-p)))
         success native-settled-p)
    (unwind-protect
        (progn
          (let ((ebox-surface--font-window
                 (plist-get context-values :display-window)))
            (ebox-with-transaction
              (ebox-surface--stage-signal-values signals context-values)
              (if surface
                  (ebox--pub-surface-update surface producer)
                (setq surface
                      (ebox--pub-surface-mount
                       buffer producer
                       (append
                        '(:capability content :inhibit-read-only t
                          :coordinate-mounts t)
                        (when-let* ((bridge
                                     (with-current-buffer buffer
                                       ebox-surface--publication-observer)))
                          (list :observers (list bridge)))))))
              (ebox-surface--publish-runtime-state
               buffer surface old-state report-base after-publication
               framework-participant observation-context)))
          (setq success t)
          (let* ((scroll-keys
                  (if framework-participant
                      (ebox-surface--framework-participant-scroll-keys
                       framework-participant)
                    (let ((new-state (ebox--pub-surface-client-state surface)))
                      (delete-dups
                       (append
                        (copy-sequence
                         (plist-get old-state :scroll-region-ids))
                        (copy-sequence
                         (plist-get new-state :scroll-region-ids)))))))
                 (scroll-diagnostics
                  (ebox-incremental--finalize-declarative-scroll-publication
                   scroll-keys))
                 (native-diagnostics
                  (ebox-surface--settle-native-session
                   old-state state-overrides surface t)))
            (setq native-settled-p t)
            (ebox-surface--record-native-retirement-diagnostics
             surface framework-participant native-diagnostics)
            (ebox-surface--participant-complete-postaccept
             framework-participant scroll-diagnostics))
          surface)
      (unless native-settled-p
        ;; Candidate cleanup is post-transaction and must not hide the primary
        ;; publication condition.  The helper contains every release fault.
        (ebox-surface--settle-native-session
         old-state state-overrides surface success))
      (when (and signals-created-p (not success))
        (ebox-surface--dispose-signals signals)))))

(defun ebox-surface--viewport-report (state width height axes strategy)
  "Return a viewport report for STATE, WIDTH, HEIGHT, AXES, and STRATEGY."
  (let ((root (plist-get state :root-node)))
    (ebox--update-report
     nil strategy
     :constraint-source 'viewport
     :constraint-owner-id 'viewport
     :constraint-owner-type 'viewport
     :constraint-root-node-id (plist-get root :node-id)
     :viewport-axes axes
     :target-viewport-width width
     :target-viewport-height height
     :dirty-kinds (unless (eq axes 'none) '(geometry))
     :dirty-count (if (eq axes 'none) 0 1)
     :patch-count (if (eq axes 'none) 0 1)
     :patch-ops (unless (eq axes 'none) '(root-rerender))
     :owner-ids (unless (eq axes 'none)
                  (list (plist-get root :node-id)))
     :root-rerender (not (eq axes 'none)))))

(defun ebox-surface--publish-context-no-op
    (buffer surface state values state-overrides report)
  "Commit VALUES and no-op STATE-OVERRIDES into STATE for BUFFER and SURFACE."
  (let ((signals
         (with-current-buffer buffer ebox-surface--context-signals))
        (old-width (plist-get state :viewport-width))
        (old-height (plist-get state :viewport-height))
        (old-display (plist-get state :display-signature))
        (old-report (plist-get state :last-update-report)))
    (unless (ebox-surface--signals-live-p signals)
      (error "Ebox mounted surface has no live context signals"))
    (ebox-with-transaction
      ;; This proof covers unused viewport axes, not a new scroll intent.
      ;; Layout may have clamped or retired a scroll owner since its input
      ;; signal was staged.  Restaging that derived scroll snapshot here would
      ;; invalidate the producer and turn a viewport no-op into a publication.
      (ebox--pub-signal-set (ebox-surface--signals-viewport-width signals)
                     (plist-get values :viewport-width))
      (ebox--pub-signal-set (ebox-surface--signals-viewport-height signals)
                     (plist-get values :viewport-height))
      (ebox--pub-signal-set (ebox-surface--signals-display signals)
                     (plist-get values :display-signature))
      (ebox-surface--transaction-participate
       (list 'ebox/context-no-op buffer)
       (lambda ()
         (unless (eq state (ebox--pub-surface-client-state surface))
           (error "Ebox no-op context unexpectedly published a surface"))
         (plist-put state :viewport-width
                    (plist-get state-overrides :viewport-width))
         (plist-put state :viewport-height
                    (plist-get state-overrides :viewport-height))
         (plist-put state :display-signature
                    (plist-get state-overrides :display-signature))
         (plist-put state :last-update-report report))
       (lambda ()
         (plist-put state :viewport-width old-width)
         (plist-put state :viewport-height old-height)
         (plist-put state :display-signature old-display)
         (plist-put state :last-update-report old-report))))
    report))

(defun ebox-surface-update-buffer-viewport (buffer width &optional height)
  "Publish BUFFER for viewport WIDTH and optional HEIGHT."
  (let* ((surface (ebox-surface--live-buffer-surface buffer))
         (state (and surface (ebox--pub-surface-client-state surface))))
    (unless state
      (error "Ebox viewport update requires a mounted Ebox publication surface"))
    (let* ((old-width (plist-get state :viewport-width))
           (old-height (plist-get state :viewport-height))
           (target-height (or height old-height))
           (window (ebox-surface--buffer-display-window buffer))
           (display-signature
            (with-current-buffer buffer
              (ebox--display-signature-for-window window)))
           (display-changed
            (not (equal display-signature
                        (plist-get state :display-signature))))
           (width-changed (not (equal width old-width)))
           (height-changed (not (equal target-height old-height)))
           (style-context-stable-p
            (let ((ebox-style--scopes
                   (ebox-style-source-scopes
                    (plist-get state :source-index)
                    (plist-get state :root-node))))
              (equal (ebox-surface--stylesheet-signature)
                     (plist-get state :stylesheet-signature))))
           (axes (cond ((and width-changed height-changed) 'both)
                       (width-changed 'width)
                       (height-changed 'height)
                       (t 'none))))
      (if (and (eq axes 'none) (not display-changed)
               (not (plist-get state :computed-styles-stale-p)))
          (let ((report
                 (ebox-surface--viewport-report
                  state width target-height axes 'no-op)))
            (plist-put state :last-update-report report)
            report)
        (ebox-incremental--notify-before-runtime-mutation buffer 'viewport)
        (unless (eq state (ebox--pub-surface-client-state surface))
          (error "Ebox runtime changed during viewport update notification"))
          (let ((commit-input
               (ebox-incremental-prepare-viewport-commit
                buffer width target-height axes display-signature
                style-context-stable-p)))
          (if (plist-get commit-input :no-op)
              (let* ((state-overrides
                      (plist-get commit-input :state-overrides))
                     (values
                      (ebox-surface--context-values
                       buffer state state-overrides)))
                (ebox-surface--publish-context-no-op
                 buffer surface state values state-overrides
                 (plist-get commit-input :report-base)))
            (ebox-surface-update-buffer-scoped
             buffer
             (plist-get commit-input :root)
             (plist-get commit-input :scope-node-ids)
             (plist-get commit-input :report-base)
             (plist-get commit-input :state-overrides)
             nil nil 0
             (plist-get commit-input :projection-kind)
             ;; The incremental viewport candidate aliases the published root
             ;; while it proves the reflow shape.  Let the surface create its
             ;; own copy before layout can attach caches or Ebox publication handles.
             nil)
            (plist-get (ebox--pub-surface-client-state surface)
                       :last-update-report)))))))

(defun ebox-surface--projection-start
    (context root &optional style-required-p projection-kind previous-state
             state-overrides)
  "Create retained Ebox publication identities and optional computed styles for
ROOT.  STYLE-REQUIRED-P is non-nil when the candidate must refresh cascade
results.  When it is nil, inline declarations already projected by node
construction are sufficient for the static layout pass.  PROJECTION-KIND may
request a strict span patch or retained viewport reflow, both of which reuse
PREVIOUS-STATE's node-object table."
  (let* ((surface-root
          (ebox--pub-object-ensure context nil ebox-surface--root-key 'ebox/surface))
         (node-root
          (ebox--pub-object-ensure context surface-root
                            ebox-surface--nodes-key 'ebox/nodes))
         (source-index
          (or (plist-get state-overrides :source-index)
              (and (eq root (plist-get previous-state :root-node))
                   (plist-get previous-state :source-index))
              (ebox-tree-source-index root)))
         (range-splice-p
          (and (eq projection-kind 'mixed-owner-reflow)
               (ebox-surface--mixed-range-splice-p state-overrides)))
         (retained-span-style-p
          ;; Variable content can change its slot's text extent without
          ;; changing the already prepared cascade.  Rebuilding subjects here
          ;; discarded its validated Host index and triggered a full reindex.
          (and (eq projection-kind 'span-patch)
               (plist-get state-overrides :computed-participation-validated-p)
               (let ((proofs (plist-get state-overrides :owner-scoped-proofs)))
                 (and proofs
                      (cl-every (lambda (proof)
                                  (plist-get proof :static-cascade-p))
                                proofs)))))
         (retained-native-style-p
          (and (eq projection-kind 'native-frame)
               (plist-get state-overrides :native-topology-stable-p)))
         (objects-by-node
          (if (memq projection-kind
                    '(metadata span-patch owner-scoped scroll-patch
                      formatting-context-reflow mixed-owner-reflow
                      viewport-reflow viewport-reflow-mixed-scroll
                      native-frame))
              (if (or (eq projection-kind 'native-frame) range-splice-p)
                  (make-hash-table :test 'eq)
              (or (plist-get previous-state :surface-node-object-table)
                  (error "Ebox span projection has no retained node table")))
            (make-hash-table :test 'eq)))
         (style-state-table
          (if (eq projection-kind 'metadata)
              (plist-get previous-state :style-binding-states)
            (ebox-surface--style-state-table previous-state)))
         (ebox-surface--inline-style-value-cache
          (and style-required-p
               (not (ebox-style-cascade-active-p))
               (make-hash-table :test 'equal)))
         (stylesheet-signature
          (and style-required-p
               (unless (or retained-span-style-p
                           (and (memq projection-kind
                                      '(owner-scoped scroll-patch
                                        formatting-context-reflow mixed-owner-reflow))
                                (not range-splice-p)))
                 (ebox-surface--stylesheet-signature))))
         (stylesheet-subject-local-p
          (and stylesheet-signature
               (ebox-surface--stylesheet-subject-local-p
                stylesheet-signature t)))
         (bindings-by-subject (make-hash-table :test 'eq))
         (states-by-subject (make-hash-table :test 'eq))
         (subjects-required-p
          (and style-required-p
               (not (eq projection-kind 'metadata))
               (not retained-native-style-p)
               (not (or retained-span-style-p
                        (and (memq projection-kind
                                   '(owner-scoped scroll-patch
                                     formatting-context-reflow
                                     mixed-owner-reflow))
                             (not range-splice-p))))))
         (_materialized-source-index
          (when subjects-required-p
            (setq source-index
                  (ebox-tree-style-source-index root source-index ebox--render-root-parent-kind))))
         (ebox-selector-view--current (ebox-source--index-selector-view source-index))
         (ebox-selector-view--topology (ebox-source--index-selector-topology source-index))
         (subjects (when subjects-required-p
                     (ebox-tree-subject-index root source-index)))
         (ebox-style--scopes
          (ebox-style-source-scopes source-index))
         (selector-tree-snapshot
          (if (or retained-span-style-p
                  retained-native-style-p
                  (and (memq projection-kind
                             '(owner-scoped scroll-patch
                               formatting-context-reflow mixed-owner-reflow))
                       (not range-splice-p)))
              (plist-get previous-state :selector-tree-snapshot)
            (and subjects
                 (ebox-surface--subject-signature
                  (plist-get subjects :root-subject)))))
         (selector-tree-token
          (if (or retained-span-style-p
                  retained-native-style-p
                  (and (memq projection-kind
                             '(owner-scoped scroll-patch))
                       (not range-splice-p)))
              (plist-get previous-state :selector-tree-token)
            (and selector-tree-snapshot
                 (if (and (equal selector-tree-snapshot
                                 (plist-get previous-state
                                            :selector-tree-snapshot))
                          (plist-get previous-state :selector-tree-token))
                     (plist-get previous-state :selector-tree-token)
                   (cons 'ebox/selector-tree nil))))))
    ;; Source-path invalidation cannot prove a memoized render signature when
    ;; cascade projection can change inherited facts on untouched descendants.
    ;; Recompute these derived signatures for this style generation; the output
    ;; cache remains reusable under the resulting, current signatures.
    (when subjects-required-p
      (dolist (key '(:render-signature-cache
                     :viewport-height-dependent-subtree-cache
                     :flex-content-min-widths))
        (when (plist-member state-overrides key)
          (plist-put state-overrides key (make-hash-table :test 'eq)))))
    (cond
     ;; Retained Ebox publication identity does not certify a node's candidate style.
     ;; Topology changes with cascade work use the same complete projection as
     ;; ordinary rendering before native layout consumes the styled nodes.
     ((and (eq projection-kind 'native-frame) (not subjects-required-p))
        (ebox-surface--project-node-delta
         context root source-index previous-state state-overrides
         node-root objects-by-node
         (and subjects (plist-get subjects :node-subject-table))
         bindings-by-subject states-by-subject style-state-table
         stylesheet-signature selector-tree-token
         stylesheet-subject-local-p))
     ((eq projection-kind 'metadata)
      (ebox--pub-object-reuse-subtree context node-root)
      ;; A retained source needs no attachment walk. Copied metadata nodes
      ;; acquire their existing objects without mutating the published map.
      (unless (eq root (plist-get previous-state :root-node))
        (ebox-runtime-index-map
         (lambda (id node)
           (plist-put node :surface-object
                      (or (gethash id objects-by-node)
                          (error "Ebox metadata projection lost node %S" id))))
         (plist-get state-overrides :node-table))))
     (range-splice-p
      (ebox-surface--project-node-delta
       context root source-index previous-state state-overrides
       node-root objects-by-node
       (and subjects (plist-get subjects :node-subject-table))
       bindings-by-subject states-by-subject style-state-table
       stylesheet-signature selector-tree-token
       stylesheet-subject-local-p))
     ((memq projection-kind
              '(span-patch owner-scoped scroll-patch
                formatting-context-reflow mixed-owner-reflow
                viewport-reflow viewport-reflow-mixed-scroll))
      (ebox--pub-object-reuse-subtree context node-root))
     (t
      (ebox--pub-object-retain context node-root)
      (ebox-surface--ensure-node-tree
       context node-root root source-index objects-by-node
       (and subjects (plist-get subjects :node-subject-table))
       bindings-by-subject states-by-subject style-state-table
       stylesheet-signature
       selector-tree-token stylesheet-subject-local-p
       ebox--render-root-parent-kind)))
    (when (and subjects (> (ebox-tree-author-style-count root) 0))
      (ebox-tree-clear-author-style-pending root))
    (list :surface-root surface-root
          :node-root node-root
          :retained-topology-state
          (and (not range-splice-p)
               (memq projection-kind
                     '(metadata span-patch owner-scoped scroll-patch
                       formatting-context-reflow mixed-owner-reflow
                       viewport-reflow viewport-reflow-mixed-scroll))
               previous-state)
          :source-index source-index
          :objects-by-node objects-by-node
          :style-binding-states style-state-table
          ;; Local computation can omit style bindings, but publication must
          ;; retain the complete context for subsequent candidate validation.
          :stylesheet-signature (or stylesheet-signature
                                    (ebox-surface--stylesheet-signature))
          :selector-tree-snapshot selector-tree-snapshot
          :selector-tree-token selector-tree-token
          :previous-layer-composition-cache
          (plist-get previous-state :layer-composition-cache)
          :layer-composition-cache (make-hash-table :test 'equal)
          :layer-composition-context
          (list (plist-get state-overrides :viewport-width)
                (plist-get state-overrides :viewport-height)
                (plist-get state-overrides :display-signature)))))

(defun ebox-surface--project-stable-node-table
    (context nodes node-root old-objects objects-by-node)
  "Reuse native NODES whose object topology is proven unchanged."
  (ebox--pub-object-reuse-subtree context node-root)
  (ebox-runtime-index-map
   (lambda (node-id node)
     (let ((object (gethash node-id old-objects)))
       (unless object
         (error "Ebox native projection lost retained node %S" node-id))
       (plist-put node :surface-object object)
       (puthash node object objects-by-node)))
   nodes)
  objects-by-node)

(defun ebox-surface--project-node-delta
    (context root source-index previous-state state-overrides
             node-root objects-by-node
             subject-table bindings-by-subject states-by-subject
             style-state-table stylesheet-signature selector-tree-token
             stylesheet-subject-local-p)
  "Project ROOT objects from its exact native touched-node delta."
  (let* ((nodes (plist-get state-overrides :node-table))
         (parents (plist-get state-overrides :parent-table))
         (touched-ids (plist-get state-overrides :native-touched-node-ids))
         (old-objects (plist-get previous-state :surface-node-object-table))
         (touched (make-hash-table :test 'equal))
         (objects-by-id (make-hash-table :test 'equal)))
    (unless (and (ebox-runtime-index-like-p nodes) (ebox-runtime-index-like-p parents)
                 (hash-table-p old-objects)
                 (or (plist-get state-overrides :native-topology-stable-p)
                     touched-ids))
      (error "Ebox native projection has no candidate object delta"))
    (if (plist-get state-overrides :native-topology-stable-p)
        (ebox-surface--project-stable-node-table
         context nodes node-root old-objects objects-by-node)
      (ebox--pub-object-retain context node-root)
      (dolist (node-id touched-ids) (puthash node-id t touched))
      (ebox-runtime-index-map
       (lambda (node-id node)
         (when subject-table
           (when-let* ((subject
                        (ebox-source--subject-table-get
                         subject-table (ebox-tree-node-source-handle node)))
                       (object (gethash node-id old-objects))
                       (style-state (gethash object style-state-table))
                       (binding (plist-get style-state :binding)))
             (puthash subject binding bindings-by-subject)
             (puthash subject style-state states-by-subject)))
         (unless (gethash node-id touched)
           (let ((object (gethash node-id old-objects)))
             (unless object
               (error "Ebox native projection lost retained node %S" node-id))
             (ebox--pub-object-reuse context object)
             (puthash node object objects-by-node)
             (puthash node-id object objects-by-id))))
       nodes)
      (dolist (node-id touched-ids)
        (let* ((node (ebox-runtime-index-get node-id nodes))
               (parent-id (and node (ebox-runtime-index-get node-id parents)))
               (old-object (and node (gethash node-id old-objects)))
               (parent (if parent-id
                           (gethash parent-id objects-by-id)
                         node-root)))
          (unless (and node parent)
            (error "Ebox native projection has an unordered node delta"))
          (let ((object
                 (ebox--pub-object-ensure context parent
                                   (ebox-surface--node-key node)
                                   (ebox-surface--node-kind node))))
            (ebox--pub-object-retain context object)
            (if (eq object old-object)
                (ebox--pub-object-reuse context object)
              (when subject-table
                (ebox-surface--apply-node-style
                 source-index object node subject-table bindings-by-subject
                 states-by-subject style-state-table stylesheet-signature
                 selector-tree-token stylesheet-subject-local-p)))
            (plist-put node :surface-object object)
            (puthash node object objects-by-node)
            (puthash node-id object objects-by-id))))
      (unless (gethash (plist-get root :node-id) objects-by-id)
        (error "Ebox native projection lost its root object"))
      (when (and subject-table
                 (not (plist-get state-overrides
                                 :computed-participation-validated-p)))
        (ebox-tree-validate-indexed-participation
         nodes parents touched-ids 'computed)))
    objects-by-node))

(defun ebox-surface--complete-projection
    (context root source-index style-required-p projection &optional node-objects)
  "Complete a retained PROJECTION for ROOT after a local proof miss.
The local attempt already owns the surface and node-root identities in
CONTEXT, so full fallback must populate those same objects instead of creating
the projection roots a second time. NODE-OBJECTS, when non-nil, reuses a
complete object map for style recomputation without allocating positional
children again."
  (when style-required-p
    (setq source-index
          (ebox-tree-style-source-index root source-index ebox--render-root-parent-kind)))
  (let* ((ebox-selector-view--current (ebox-source--index-selector-view source-index))
         (ebox-selector-view--topology (ebox-source--index-selector-topology source-index))
         (node-root (plist-get projection :node-root))
         ;; The retained projection may share the published node-id table.
         ;; Full projection visits every node and writes node-keyed entries.
         (objects-by-node (make-hash-table :test 'eq))
         (style-state-table
          (plist-get projection :style-binding-states))
         (stylesheet-signature
          (or (plist-get projection :stylesheet-signature)
              (and style-required-p
                   (ebox-surface--stylesheet-signature))))
         (stylesheet-subject-local-p
          (and stylesheet-signature
               (ebox-surface--stylesheet-subject-local-p
                stylesheet-signature t)))
         (selector-tree-token
          (plist-get projection :selector-tree-token))
         (bindings-by-subject (make-hash-table :test 'eq))
         (states-by-subject (make-hash-table :test 'eq))
         (subjects (when style-required-p
                     (ebox-tree-subject-index root source-index))))
    (plist-put projection :source-index source-index)
    (plist-put projection :objects-by-node objects-by-node)
    (plist-put projection :retained-topology-state nil)
    (ebox--pub-object-retain context node-root)
    (ebox-surface--ensure-node-tree
     context node-root root source-index objects-by-node
     (and subjects (plist-get subjects :node-subject-table))
     bindings-by-subject states-by-subject style-state-table
     stylesheet-signature
     selector-tree-token stylesheet-subject-local-p
     ebox--render-root-parent-kind node-objects)
    (when (> (ebox-tree-author-style-count root) 0)
      (ebox-tree-clear-author-style-pending root))
    projection))

(defun ebox-surface--native-full-frame-p (state projection-kind)
  "Return non-nil when STATE owns a complete native surface frame."
  (and (eq projection-kind 'native-frame)
       (plist-get state :native-topology-stable-p)
       (let ((frame (plist-get state :native-render-frame)))
         (and (plist-get frame :native-frame)
              (not (plist-get frame :native-patch))))))

(defun ebox-surface--projection-result
    (context projection state output &optional projection-kind)
  "Complete CONTEXT PROJECTION for STATE from rendered OUTPUT."
  (let* ((surface-root (plist-get projection :surface-root))
         (objects-by-node (plist-get projection :objects-by-node))
         (retained-topology (plist-get projection :retained-topology-state))
         (root-node (plist-get state :root-node))
         (root-id (and root-node (plist-get root-node :node-id)))
         (owner-id (plist-get state :span-patch-owner-id))
         (scroll-fast-p (and (eq projection-kind 'scroll-patch)
                             (plist-get state :scroll-fast-window-p)))
         (native-retained-p
          (and (eq projection-kind 'native-frame)
               (plist-get state :native-topology-stable-p)
               (plist-get state :native-render-frame)
               (plist-get (plist-get state :native-render-frame)
                          :native-patch)))
         (full-surface-p
          (or (and scroll-fast-p
                   (plist-get state :retained-scroll-content-p)
                   root-id owner-id (= root-id owner-id))
              (ebox-surface--native-full-frame-p state projection-kind)))
         (previous-owned-ranges
          (plist-get state :previous-surface-owned-ranges))
         (retained-owned-ranges
          (and (or (and (eq projection-kind 'mixed-owner-reflow)
                        (eq (plist-get (plist-get state :mixed-owner-proof)
                                       :geometry-kind)
                            'span-patch)
                        (not (ebox-surface--mixed-range-splice-p state)))
                   (and (memq projection-kind '(span-patch owner-scoped))
                        (null (plist-get state :paint-property-contributions))
                        (let ((proofs (plist-get state :owner-scoped-proofs)))
                          (and (= (length proofs) 1)
                               (not (plist-get (car proofs) :range-splice-p))))))
               (plist-get state :span-patch-retained-owned-ranges)))
         (node-objects
          (or (plist-get retained-topology :surface-node-object-table)
              (and scroll-fast-p
                   (plist-get state :surface-node-object-table))
              (ebox-surface--node-object-table objects-by-node)))
         (region-objects
          (or (plist-get retained-topology :region-surface-object-table)
              (and scroll-fast-p
                   (plist-get state :region-surface-object-table))
              (ebox-surface--region-object-table state node-objects)))
         (property-contributions
          (plist-get state :paint-property-contributions))
         metadata-result)
    ;; Paint contributions belong to this one publication.  Keep them out of
    ;; the transferred client state so later paint cannot replay old layers.
    (cl-remf state :paint-property-contributions)
    (cl-remf state :span-patch-retained-owned-ranges)
    (plist-put state :surface-node-object-table node-objects)
    (plist-put state :region-surface-object-table region-objects)
    (unless retained-topology
      (plist-put state :style-binding-states
                 (ebox-surface--project-style-states
                  context (plist-get state :style-binding-states) node-objects)))
    (plist-put state :surface-object-region-table
               (or (plist-get retained-topology :surface-object-region-table)
                   (and scroll-fast-p
                        (plist-get state :surface-object-region-table))
                   (ebox-surface--object-region-table region-objects)))
    ;; Logical IDs are source metadata, independent of retained node topology.
    ;; They still receive their ordinary candidate projection.
    (unless (and scroll-fast-p (plist-get state :logical-id-region-table))
      (plist-put state :logical-id-region-table
                 (ebox-surface--logical-id-region-table state region-objects)))
    (plist-put state :ownership-cache
               (ebox-surface--ownership-cache retained-topology state))
    (when (eq projection-kind 'metadata)
      (let* ((buffer (plist-get state :metadata-buffer))
             (surface (and buffer (ebox-surface--live-buffer-surface buffer)))
             (extent (and buffer
                          (with-current-buffer buffer
                            (- (point-max) (point-min)))))
             (revision (and surface (ebox--pub-surface-revision surface))))
        (unless (and surface (integerp extent) (integerp revision))
          (error "Ebox metadata projection lost its mounted surface"))
        (cl-remf state :metadata-buffer)
        (setq metadata-result
              (ebox--pub-commit-batch-result-create
               context
               (ebox--pub-commit-batch-create
                :base-revision revision :target-revision (1+ revision)
                :base-extent extent :target-extent extent
                :patches nil :coordinate-patches nil)
               :client-state state :reuse-mount-projection t))))
    (or metadata-result
        (and native-retained-p
             (ebox-surface--native-patch-result
              context projection state output node-objects region-objects))
        (and (or (null property-contributions) retained-owned-ranges)
             (or (memq projection-kind
                       '(span-patch owner-scoped mixed-owner-reflow))
                 (and (eq projection-kind 'scroll-patch)
                      (plist-get state :nested-scroll-patch-proof)))
             (ebox-surface--span-coordinate-result
              context projection state output previous-owned-ranges
              property-contributions retained-owned-ranges))
        (let* ((range-splice-p
                (and (eq projection-kind 'mixed-owner-reflow)
                     (ebox-surface--mixed-range-splice-p state)))
               (prepared
                (ebox-surface--surface-plan
                 context surface-root output state node-objects region-objects
                 scroll-fast-p))
               (plan (car prepared))
               (rendered (cadr prepared))
               (owned-ranges (nth 2 prepared)))
          (or (and (null property-contributions)
                   (memq projection-kind
                          '(span-patch owner-scoped mixed-owner-reflow))
                   (when-let* ((batch
                                (ebox-surface--coordinate-batch
                                 state rendered previous-owned-ranges)))
                     (ebox--pub-commit-batch-result-create
                      context batch
                      :mount-specs
                      (ebox-surface--commit-mount-specs
                       (nth 3 prepared) owned-ranges)
                      :client-state state)))
              (if (and (not range-splice-p)
                       (or full-surface-p native-retained-p
                           property-contributions))
                  (ebox--pub-surface-retained-content-result-create
                   context plan rendered owned-ranges state
                   full-surface-p property-contributions)
                (ebox--pub-surface-result-create-owned context plan state)))))))

(defun ebox-surface--native-patch-result
    (context projection state rendered node-objects region-objects)
  "Return a Ebox publication batch directly from STATE's exact native patch, or
nil."
  (let ((frame (plist-get state :native-render-frame)))
    (when (and (plist-get frame :native-patch)
               (plist-get state :native-topology-stable-p)
               (stringp rendered))
      (let* ((surface-root (plist-get projection :surface-root))
             (fragment-root
              (ebox--pub-object-ensure context surface-root
                                ebox-surface--fragments-key 'ebox/fragments))
             (text-leaf
              (ebox--pub-object-ensure context fragment-root
                                ebox-surface--text-key 'ebox/text))
             (fragment-data
              (plist-get state :native-render-fragment-template))
             (reuse-mount-projection-p
              (and (plist-get state :native-reuse-mount-projection-p) t))
             (owned-ranges
              (if (or reuse-mount-projection-p
                      (plist-get state :native-reuse-ownership-p))
                  (let ((ranges
                         (plist-get state :native-committed-owned-ranges)))
                    (unless ranges
                      (error "Native retained frame has no ownership base"))
                    ranges)
                (unless (vectorp fragment-data)
                  (error "Native retained patch has no target fragments"))
                (ebox-surface--native-owned-ranges
                 context text-leaf fragment-data state node-objects
                 region-objects nil)))
             (rendered-length (length rendered))
             (mount-records
              (list (list :object text-leaf :start 0 :end rendered-length
                          :props nil :tags nil :leaf t)
                    (list :object fragment-root :start 0 :end rendered-length
                          :props nil :tags nil :leaf nil)
                    (list :object surface-root :start 0 :end rendered-length
                          :props nil :tags nil :leaf nil))))
        (plist-put state :surface-owned-ranges owned-ranges)
        (plist-put state :native-committed-rendered rendered)
        (plist-put state :native-committed-owned-ranges owned-ranges)
        (plist-put state :native-committed-fragment-template fragment-data)
        (plist-put state :surface-fragments (list :native-frame frame))
        (cl-remf state :native-reuse-ownership-p)
        (cl-remf state :native-reuse-mount-projection-p)
        (cl-remf state :native-coordinate-patches)
        (cl-remf state :native-render-output)
        (cl-remf state :native-render-fragments)
        (cl-remf state :native-render-fragment-template)
        (cl-remf state :native-render-frame)
        (cl-remf state :previous-surface-owned-ranges)
        (ebox-surface--native-commit-batch
         context state mount-records owned-ranges
         reuse-mount-projection-p)))))

(defun ebox-surface--coordinate-patches-identity-p (frame)
  "Return non-nil when FRAME preserves every character coordinate."
  (and (= (plist-get frame :base-character-count)
          (plist-get frame :target-character-count))
       (cl-every
        (lambda (patch)
          (and (= (plist-get patch :old-start)
                  (plist-get patch :new-start))
               (= (plist-get patch :old-end)
                  (plist-get patch :new-end))))
        (plist-get frame :coordinate-patches))))

(defun ebox-surface--commit-mount-specs (records owned-ranges)
  "Return exact target mount specs from RECORDS and OWNED-RANGES.  The text
record precedes logical ownership ranges, matching Ebox's normal content
projection order; fragment and surface records follow unchanged."
  (unless records
    (error "Ebox native commit has no target mount records"))
  (append (list (car records)) owned-ranges (cdr records)))

(defun ebox-surface--native-commit-batch
    (context state mount-records owned-ranges &optional retain-mount-state-p)
  "Return a strict Ebox publication batch result for STATE's stable-topology
native patch."
  (let* ((frame (or (plist-get state :native-render-frame)
                    (plist-get (plist-get state :surface-fragments)
                               :native-frame)))
         (patches (and frame (plist-get frame :patches)))
         (base (and frame (plist-get frame :base-character-count)))
         (target (and frame (plist-get frame :target-character-count))))
    (when (and (plist-get frame :native-patch)
               (plist-get state :native-topology-stable-p)
               (integerp base) (integerp target)
               (proper-list-p patches))
      (let ((batch
             (ebox--pub-commit-batch-create
              :base-revision (plist-get state :runtime-revision)
              :target-revision (1+ (plist-get state :runtime-revision))
              :base-extent base :target-extent target
              :patches patches
              :coordinate-patches (plist-get frame :coordinate-patches))))
        (if retain-mount-state-p
            (ebox--pub-commit-batch-result-create
             context batch :client-state state :reuse-mount-projection t)
          (ebox--pub-commit-batch-result-create
           context batch
           :mount-specs
           (ebox-surface--commit-mount-specs mount-records owned-ranges)
           :client-state state))))))

(defun ebox-surface--patch-property-contributions
    (patches contributions extent)
  "Return fresh PATCHES carrying completely covered CONTRIBUTIONS, or nil.
CONTRIBUTIONS use target coordinates bounded by EXTENT.  Preserve their order
inside every patch; a gap rejects the batch rather than dropping paint."
  (when (proper-list-p contributions)
    (catch 'uncovered
      (let* ((targets (vconcat (mapcar #'copy-sequence patches)))
             (count (length targets))
             (layers (make-vector count nil)))
        (dolist (contribution contributions)
          (let ((start (plist-get contribution :start))
                (end (plist-get contribution :end))
                (props (plist-get contribution :props)))
            ;; Validate the original interval before clipping.  On a proof
            ;; miss the retained-content path reports invalid inputs through
            ;; Ebox's ordinary contribution validator.
            (unless (and (integerp start) (integerp end)
                         (<= 0 start end extent)
                         (ebox-style--valid-plist-p props)
                         (cl-loop for (key _value) on props by #'cddr
                                  always (symbolp key)))
              (throw 'uncovered nil))
            (when (< start end)
              (let ((low 0) (high count) (position start))
                ;; Patches are ordered and disjoint.  Locate the first one
                ;; once per layer, then visit only its actual intersections.
                (while (< low high)
                  (let ((middle (/ (+ low high) 2)))
                    (if (<= (plist-get (aref targets middle) :new-end) start)
                        (setq low (1+ middle))
                      (setq high middle))))
                (while (< position end)
                  (when (>= low count) (throw 'uncovered nil))
                  (let* ((patch (aref targets low))
                         (patch-start (plist-get patch :new-start))
                         (next (min end (plist-get patch :new-end))))
                    (when (> patch-start position) (throw 'uncovered nil))
                    (when (< position next)
                      (push (list :start (- position patch-start)
                                  :end (- next patch-start) :props props)
                            (aref layers low)))
                    (setq position next low (1+ low))))))))
        (dotimes (index count)
          (when (aref layers index)
            (aset targets index
                  (plist-put (aref targets index) :property-contributions
                             (nreverse (aref layers index))))))
        (append targets nil)))))

(defun ebox-surface--coordinate-batch
    (state rendered previous-owned-ranges
           &optional property-contributions retained-origin)
  "Return STATE's exact proven-owner coordinate batch, or nil.  RENDERED is the
candidate text.  PREVIOUS-OWNED-RANGES identify the committed owner
intervals.  The mixed projection has already produced exact coordinate
patches and final text; this function composes those retained facts into
Ebox's standard validated commit batch without asking Ebox publication to
rediscover the same diff from a full plan.  PROPERTY-CONTRIBUTIONS add
ordered target paint.  RETAINED-ORIGIN is the live surface origin when an
exact ownership proof permits indexed owner lookup.  This proof step does
not register objects in the active prepare context.

Layer recomposition has a stronger damage proof than ordinary owner-scoped
updates: `:content-coordinate-patches' already contains every row whose text
or paint properties changed.  In that mode, keep those intervals discrete;
adding the owner's enclosing mount would turn two distant damaged rows into
one large replacement and needlessly rewrite the rows between them."
  (let* ((proof (plist-get state :mixed-owner-proof))
         (layer-damage-only-p
          (and (plist-get state :layer-recompose-p)
               (null property-contributions)))
         (owner-ids
          (or (plist-get proof :owner-ids)
              (mapcar (lambda (owner-proof)
                        (plist-get owner-proof :owner-id))
                      (plist-get state :owner-scoped-proofs))
              (and (plist-get state :span-patch-owner-id)
                   (list (plist-get state :span-patch-owner-id)))))
         (objects (plist-get state :surface-node-object-table))
         (coordinate-patches (plist-get state :content-coordinate-patches))
         (target-extent (and (stringp rendered) (length rendered)))
         (source-extent (plist-get state :content-base-extent))
         owner-set intervals)
    (when (and owner-ids (hash-table-p objects) coordinate-patches
               (integerp source-extent) (integerp target-extent)
               previous-owned-ranges)
      (setq owner-set (make-hash-table :test #'eq))
      (dolist (owner-id owner-ids)
        (when-let* ((object (gethash owner-id objects)))
          (puthash object t owner-set)))
      ;; Coordinate patches are the authoritative old-to-new mapping for
      ;; changed content.  Owner mounts supplement that mapping with
      ;; property-only intervals (for example a button whose enabled face
      ;; changes after a preceding Range grows).  Starting from owner mounts
      ;; alone loses every boundary inside a replacement by design, leaving
      ;; later intervals shifted without the patch that introduced the shift.
      (setq intervals
            (mapcar
             (lambda (patch)
               (list :old-start (plist-get patch :old-start)
                     :old-end (plist-get patch :old-end)
                     :new-start (plist-get patch :new-start)
                     :new-end (plist-get patch :new-end)))
             coordinate-patches))
      (unless layer-damage-only-p
        (if retained-origin
            ;; The strict retained-property witness preserves the complete
            ;; mount projection.  Read just the changed owners from Ebox's
            ;; existing index, including baseline-only paint removals.
            (maphash
             (lambda (object _present)
               (dolist (mount (ebox--pub-object-mounts object))
                 (let ((start (- (plist-get mount :start) retained-origin))
                       (end (- (plist-get mount :end) retained-origin)))
                   (push (list :old-start start :old-end end
                               :new-start start :new-end end)
                         intervals))))
             owner-set)
          (dolist (range previous-owned-ranges)
            (when (gethash (plist-get range :object) owner-set)
              (when-let* ((new-start
                          (ebox-surface--rebase-coordinate
                           (plist-get range :start) coordinate-patches))
                         (new-end
                          (ebox-surface--rebase-coordinate
                           (plist-get range :end) coordinate-patches)))
                (push (list :old-start (plist-get range :start)
                            :old-end (plist-get range :end)
                            :new-start (car new-start)
                            :new-end (car new-end))
                      intervals))))))
      (setq intervals
            (sort intervals
                  (lambda (left right)
                    (< (plist-get left :old-start)
                       (plist-get right :old-start)))))
      (let (coalesced)
        (dolist (interval intervals)
          (let ((previous (car coalesced)))
            (if (and previous
                     (<= (plist-get interval :old-start)
                         (plist-get previous :old-end))
                     (<= (plist-get interval :new-start)
                         (plist-get previous :new-end)))
                (progn
                  (plist-put previous :old-end
                             (max (plist-get previous :old-end)
                                  (plist-get interval :old-end)))
                  (plist-put previous :new-end
                             (max (plist-get previous :new-end)
                                  (plist-get interval :new-end))))
              (push (copy-sequence interval) coalesced))))
        (setq intervals (nreverse coalesced)))
      (when intervals
        (let* ((patches
                (mapcar
                 (lambda (interval)
                   (append
                    interval
                    (list :replacement
                          (substring rendered
                                     (plist-get interval :new-start)
                                     (plist-get interval :new-end)))))
                 intervals))
               (delta
                (cl-loop for patch in intervals
                         sum (- (- (plist-get patch :new-end)
                                   (plist-get patch :new-start))
                                (- (plist-get patch :old-end)
                                   (plist-get patch :old-start)))))
               (derived-base-extent (- target-extent delta))
               (base-revision (plist-get state :runtime-revision))
               (batch
                (and (= source-extent derived-base-extent)
                     ;; Ebox's constructor is the canonical coordinate validator.
                     ;; A composed local proof may still expose overlapping
                     ;; owner intervals after all geometry owners are united;
                     ;; that is a fast-path proof miss, so preserve the normal
                     ;; Surface plan instead of surfacing an internal batch
                     ;; construction error to the application.
                     (condition-case nil
                         (ebox--pub-commit-batch-create
                          :base-revision base-revision
                          :target-revision (1+ base-revision)
                          :base-extent source-extent
                          :target-extent target-extent
                          :patches patches
                          :coordinate-patches intervals)
                       (ebox--pub-surface-error nil)))))
          (when (and batch property-contributions)
            (setq batch
                  (when-let* ((layered
                               (ebox-surface--patch-property-contributions
                                patches property-contributions target-extent)))
                    ;; The bare batch above proves geometry.  Composition
                    ;; runs outside its proof-miss catch: a merger can signal
                    ;; any condition, including `ebox--pub-surface-error', and must
                    ;; preserve ordinary transaction failure and rollback.
                    (ebox--pub-commit-batch-create
                     :base-revision base-revision
                     :target-revision (1+ base-revision)
                     :base-extent source-extent :target-extent target-extent
                     :patches layered :coordinate-patches intervals))))
          (when batch
            (cl-remf state :content-base-extent)
            batch))))))

(defun ebox-surface--span-coordinate-result
    (context projection state rendered previous-owned-ranges
             &optional property-contributions retained-owned-ranges)
  "Return a direct span commit from retained coordinate metadata, or nil.
CONTEXT and PROJECTION supply retained object identities.  STATE and RENDERED
hold the candidate coordinates and text; PREVIOUS-OWNED-RANGES is the committed
ownership snapshot.  PROPERTY-CONTRIBUTIONS are ordered candidate paint layers.
RETAINED-OWNED-RANGES witnesses unchanged ownership when it is that snapshot."
  (let* ((patches (plist-get state :content-coordinate-patches))
         (surface-root (plist-get projection :surface-root))
         (retained-origin
          (when (and surface-root patches retained-owned-ranges
                     (eq retained-owned-ranges previous-owned-ranges)
                     (equal (plist-get state :content-base-extent)
                            (length rendered))
                     (cl-every
                      (lambda (patch)
                        (and (= (plist-get patch :old-start)
                                (plist-get patch :new-start))
                             (= (plist-get patch :old-end)
                                (plist-get patch :new-end))))
                      patches))
            (let ((mounts (ebox--pub-object-mounts surface-root)))
              (when (and (= (length mounts) 1)
                         (= (- (plist-get (car mounts) :end)
                               (plist-get (car mounts) :start))
                            (length rendered)))
                (plist-get (car mounts) :start))))))
    (when-let* ((fragments
                 (and surface-root patches
                      (or (plist-get state :mixed-owner-fragment-data)
                          (plist-get state :span-patch-fragment-data))))
                (rebased
                 ;; Layer composition can replace visible owners without
                 ;; moving a single character.  Coordinates alone cannot
                 ;; retain its mounts; rebuild them from the new role runs.
                 (and (not (plist-get state :layer-recompose-p))
                      (not (plist-get state :fragment-ownership-changed-p))
                      (if retained-origin
                          (cons t previous-owned-ranges)
                        (and (null property-contributions) previous-owned-ranges
                             (ebox-surface--rebase-owned-ranges
                              previous-owned-ranges patches (length rendered))))))
                (batch
                 (ebox-surface--coordinate-batch
                  state rendered previous-owned-ranges
                  property-contributions retained-origin))
                (fragment-root
                 (ebox--pub-object-ensure context surface-root
                                   ebox-surface--fragments-key 'ebox/fragments))
                (text-leaf
                 (ebox--pub-object-ensure context fragment-root
                                   ebox-surface--text-key 'ebox/text)))
      (let* ((owned-ranges (cdr rebased))
             (rendered-length (length rendered))
             (mount-records
              (unless retained-origin
                (list (list :object text-leaf :start 0 :end rendered-length
                            :props nil :tags nil :leaf t)
                      (list :object fragment-root :start 0 :end rendered-length
                            :props nil :tags nil :leaf nil)
                      (list :object surface-root :start 0 :end rendered-length
                            :props nil :tags nil :leaf nil))))
             (result
              (if retained-origin
                  (ebox--pub-commit-batch-result-create
                   context batch :client-state state :reuse-mount-projection t)
                (ebox--pub-commit-batch-result-create
                 context batch
                 :mount-specs
                 (ebox-surface--commit-mount-specs mount-records owned-ranges)
                 :client-state state))))
        (when result
          (plist-put state :surface-owned-ranges
                     (if retained-origin
                         owned-ranges
                       (ebox-surface--snapshot-owned-ranges owned-ranges)))
          (plist-put state :surface-fragments fragments)
          (cl-remf state :previous-surface-owned-ranges)
          (cl-remf state :mixed-owner-fragment-data)
          (cl-remf state :mixed-owner-content-p)
          (cl-remf state :span-patch-fragment-data)
          (cl-remf state :span-patch-content-p)
          result)))))

(defun ebox-surface--mounted-object-for-node (state node-id)
  "Return NODE-ID's nearest live retained object with mounts in STATE."
  (let ((objects (plist-get state :surface-node-object-table))
        (parents (plist-get state :parent-table))
        object)
    (while (and node-id
                (progn
                  (setq object (and objects (gethash node-id objects)))
                  (or (not object) (not (ebox--pub-object-mounted-p object)))))
      (setq node-id (and parents (ebox-runtime-index-get node-id parents))))
    (unless (and object (ebox--pub-object-live-p object)
                 (ebox--pub-object-mounted-p object))
      (error "Ebox scoped owner has no mounted Ebox publication object"))
    object))

(defun ebox-surface--objects-for-node-ids (state node-ids)
  "Return mounted retained objects in STATE for Ebox NODE-IDS."
  (delete-dups
   (mapcar (lambda (node-id)
             (ebox-surface--mounted-object-for-node state node-id))
           node-ids)))

(defun ebox-surface-update-buffer-scoped
    (buffer source scope-node-ids report-base state-overrides
            &optional after-publication on-mismatch scroll-prefetch-delay
            projection-kind source-isolated-p framework-participant)
  "Publish BUFFER SOURCE within SCOPE-NODE-IDS. STATE-OVERRIDES
augments the isolated candidate runtime.  REPORT-BASE and AFTER-PUBLICATION
have the same meaning as in `ebox-surface-mount-buffer'.  ON-MISMATCH is
forwarded to Ebox's scoped publication policy.  SCROLL-PREFETCH-DELAY
controls post-publication lazy scroll warming.  PROJECTION-KIND may request
a proven non-spatial candidate projection.  SOURCE-ISOLATED-P means SOURCE
is an internally copied runtime candidate and may be adopted without another
structural copy or identity reconciliation.  When SOURCE-PATH-COPIED-P is
non-nil, SOURCE shares untouched published nodes; the surface must preserve
those shared nodes while consuming the candidate.  FRAMEWORK-PARTICIPANT
retains post-Ebox publication publication facts when non-nil."
  ;; Ebox owns the complete mounted Ebox publication surface.  Caller narrowing is an editor
  ;; view and must neither constrain candidate coordinates nor become an
  ;; accidental publication scope.  Isolate it while every full-buffer fact
  ;; and Ebox publication operation runs against the complete target.
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (let* ((observation-context ebox-surface--observation-context)
             (surface (ebox-surface--live-buffer-surface buffer))
             (old-state (and surface (ebox--pub-surface-client-state surface))))
        (unless surface
          (error "Ebox scoped update requires a mounted Ebox publication surface"))
        (let ((objects
               (condition-case nil
                   (ebox-surface--objects-for-node-ids old-state scope-node-ids)
                 (error nil))))
          (if (null objects)
              (ebox-surface-mount-buffer
               buffer source
               (append report-base
                       '(:publication-scope-fallback t :empty-range-owner-fallback t))
               after-publication t state-overrides
               framework-participant projection-kind source-isolated-p)
            (let* ((context-values
                    (ebox-surface--context-values
                     buffer old-state state-overrides))
                   (signals-result
                    (ebox-surface--ensure-signals buffer context-values))
                   (signals (car signals-result))
                   (signals-created-p (cdr signals-result))
                   (producer
                    (if (plist-get state-overrides :scroll-viewport-batch)
                        (ebox-surface--scroll-viewport-producer
                         old-state state-overrides signals)
                      (ebox-surface-producer
                       source old-state t state-overrides signals projection-kind
                       source-isolated-p
                       (plist-get state-overrides :source-path-copied-p))))
                   success native-settled-p)
              (when (and (null on-mismatch)
                         (or (null projection-kind)
                             (plist-get state-overrides :owner-scoped-proofs)
                             (plist-get report-base :layer-recompose-p)
                             (plist-get state-overrides
                                        :scroll-state-transaction)
                             (> (length scope-node-ids) 1)))
                ;; A complete projection can change intrinsic ancestor sizes
                ;; outside the tentative layout owners.  Ebox publication already compares
                ;; the actual output against their ranges before publication;
                ;; let that same candidate publish the full surface when needed.
                (setq on-mismatch 'root))
              (unwind-protect
                  (progn
                    (let ((ebox-surface--font-window
                           (plist-get context-values :display-window)))
                      (ebox-with-transaction
                        (ebox-surface--stage-signal-values
                         signals context-values)
                        (ebox--pub-surface-update-scoped
                         surface objects producer
                         (list :on-mismatch on-mismatch :return-report nil))
                        (ebox-surface--publish-runtime-state
                         buffer surface old-state report-base after-publication
                         framework-participant observation-context)))
                    (setq success t)
                    (let* ((scroll-keys
                            (if framework-participant
                                (ebox-surface--framework-participant-scroll-keys
                                 framework-participant)
                              (let ((new-state
                                     (ebox--pub-surface-client-state surface)))
                                (delete-dups
                                 (append
                                  (copy-sequence
                                   (plist-get old-state :scroll-region-ids))
                                  (copy-sequence
                                   (plist-get new-state
                                              :scroll-region-ids)))))))
                           (scroll-diagnostics
                            (ebox-incremental--finalize-declarative-scroll-publication
                             scroll-keys scroll-prefetch-delay))
                           (native-diagnostics
                            (ebox-surface--settle-native-session
                             old-state state-overrides surface t)))
                      (setq native-settled-p t)
                      (ebox-surface--record-native-retirement-diagnostics
                       surface framework-participant native-diagnostics)
                      (ebox-surface--participant-complete-postaccept
                       framework-participant scroll-diagnostics))
                    surface)
                (unless native-settled-p
                  (ebox-surface--settle-native-session
                   old-state state-overrides surface success))
                (when (and signals-created-p (not success))
                  (ebox-surface--dispose-signals signals))))))))))

(defun ebox-surface--clear-runtime-attachments (root)
  "Clear Ebox publication handles and render-cache attachments below ROOT."
  (cl-labels
      ((visit (node)
         (when (and (listp node) (not (stringp node)))
           (when (plist-member node :surface-object)
             (plist-put node :surface-object nil))
           (when (plist-member node :render-cache)
             (plist-put node :render-cache nil))
           (ebox-tree-for-each-direct-child node #'visit))))
    (visit root))
  root)

(defun ebox-surface--candidate-root
    (source preserve-identities-p &optional validated-p)
  "Return an isolated runtime copy of SOURCE.  When PRESERVE-IDENTITIES-P is
non-nil, retain existing Ebox node and region identities while always
discarding Ebox publication handles and render-cache attachments.
VALIDATED-P means the caller owns a current topology certificate for SOURCE."
  (unless (and (listp source) (not (stringp source)))
    (error "Ebox surface source must be an Ebox node"))
  (ignore validated-p)
  (let ((candidate (ebox-tree-copy-node-structure source)))
    (if preserve-identities-p
        (ebox-surface--clear-runtime-attachments candidate)
      (ebox-tree-clear-runtime-identities candidate))
    candidate))

(defun ebox-surface--isolated-viewport-overrides (overrides)
  "Isolate persistent viewport caches in OVERRIDES for a reflow candidate.
Keep writes to retained output and layout fragments out of the published
generation.  Node memos follow the source-copy policy in the projector."
  (let ((copy (copy-sequence overrides)))
    (dolist (key '(:render-cache :layout-fragments))
      (when (plist-member copy key)
        (let ((value (plist-get copy key)))
          (when (hash-table-p value)
            (setq copy (plist-put copy key (copy-hash-table value)))))))
    copy))

(defun ebox-surface--reconcile-candidate
    (root source-index previous-state)
  "Reconcile ROOT identities using SOURCE-INDEX and PREVIOUS-STATE."
  (when-let* ((previous-root (plist-get previous-state :root-node)))
    (ebox-tree-reconcile-runtime
     previous-root (plist-get previous-state :source-index)
     root source-index))
  root)

(defun ebox-surface--source-region-id-set (source)
  "Return region ids already present in Ebox SOURCE without mutating it."
  (let ((ids (make-hash-table :test 'equal)))
    (cl-labels
        ((visit (node)
           (when (and (listp node) (not (stringp node)))
             (when-let* ((region-id (plist-get node :region-id)))
               (puthash region-id t ids))
             (dolist (child (ebox-tree--children-raw node))
               (visit child)))))
      (visit source))
    ids))

(defun ebox-surface--source-identities-available-p (source buffer)
  "Return non-nil when SOURCE's migration ids are available for BUFFER."
  (or (stringp source)
      (not (ebox--runtime-region-id-conflict
            (ebox-surface--source-region-id-set source) buffer))))

(defun ebox-surface--node-key (node)
  "Project NODE's reconciled Ebox identity into the Ebox publication sibling
namespace."
  (list 'ebox/node
        (or (plist-get node :node-id)
            (error "Ebox surface node has no reconciled identity"))))

(defun ebox-surface--node-kind (node)
  "Return the Ebox publication kind discriminator for Ebox NODE."
  (list 'ebox/node (plist-get node :ebox-type)))

(defvar ebox-surface--rebuilding-computed-styles-p nil
  "Non-nil while an ordinary candidate rebuilds prepared source style effects.")

(defun ebox-surface--node-style-binding
    (source-index object node subject bindings-by-subject states-by-subject
            style-state-table
            stylesheet-signature selector-tree-token
            stylesheet-subject-local-p &optional scopes)
  "Install and return NODE style binding on OBJECT for SUBJECT."
  (let* ((parent (ebox-selector-view-parent subject))
         (parent-binding (and parent (gethash parent bindings-by-subject)))
         (parent-style-state (and parent (gethash parent states-by-subject)))
         (declarations
          (ebox-tree-node-source-declarations source-index node))
         (old-state (gethash object style-state-table))
         (old-binding (and old-state (plist-get old-state :binding)))
         (subject-style-context
          (and stylesheet-subject-local-p
               (ebox-surface--subject-style-context node subject stylesheet-signature)))
         (local-context-stable-p
          (and subject-style-context old-state
               (equal subject-style-context
                      (plist-get old-state :subject-style-context))))
         (stylesheet-stable-p
          (and old-state
               (or local-context-stable-p
                   (equal stylesheet-signature
                          (plist-get old-state :stylesheet-signature)))))
         (selector-context-stable-p
          (and old-state
               (or (eq selector-tree-token
                       (plist-get old-state :selector-tree-token))
                   (and local-context-stable-p
                        (ebox-surface--subject-local-equal-p
                         subject (plist-get old-state :subject))))))
         (old-parent-style
          (and old-state
               (plist-get old-state :parent-binding)
               (ebox--pub-binding-last-value
                (plist-get old-state :parent-binding))))
         (new-parent-style
          (and parent-binding (ebox--pub-binding-last-value parent-binding)))
         (theme-explicit-delta-style
          (and (not ebox-surface--rebuilding-computed-styles-p) old-state old-binding
               selector-context-stable-p
               stylesheet-stable-p
               (ebox-style--theme-delta-computed
                (ebox--pub-binding-last-value old-binding)
                (plist-get old-state :declarations)
                declarations
                old-parent-style
                new-parent-style)))
         (theme-parent-delta-style
          (and (not ebox-surface--rebuilding-computed-styles-p) old-state old-binding
               (equal (plist-get old-state :declarations)
                      declarations)
               selector-context-stable-p
               stylesheet-stable-p
               (ebox-style--theme-parent-delta-computed
                (ebox--pub-binding-last-value old-binding)
                declarations old-parent-style new-parent-style)))
         (theme-delta-style
          (or theme-explicit-delta-style theme-parent-delta-style))
         (theme-parent-delta-p
          (and (null theme-explicit-delta-style)
               theme-parent-delta-style))
         (reused-p
         (and (not ebox-surface--rebuilding-computed-styles-p) old-state
               (not (plist-get node :ebox-candidate-computed-style-p))
               (null theme-delta-style)
               selector-context-stable-p
               (equal declarations (plist-get old-state :declarations))
               (eq parent-binding (plist-get old-state :parent-binding))
               (= (if parent-binding 1 0)
                  (or (plist-get old-state
                                 :inherited-dependency-count)
                      -1))
               stylesheet-stable-p))
         (state
          (if reused-p
              (let ((reused-state (copy-sequence old-state)))
                (plist-put reused-state :selector-tree-token
                           selector-tree-token)
                (plist-put reused-state :selector-topology
                           ebox-selector-view--topology)
                (plist-put reused-state :stylesheet-signature stylesheet-signature)
                (plist-put reused-state :subject-style-context subject-style-context)
                (plist-put reused-state :selector-view ebox-selector-view--current)
                (plist-put reused-state :subject subject)
                (plist-put reused-state :node node)
                (plist-put reused-state :parent-style-state
                           parent-style-state)
                reused-state)
            (let ((new-state
                   (list :selector-tree-token selector-tree-token
                         :subject-style-context subject-style-context
                         :declarations (copy-tree declarations)
                         :parent-binding parent-binding
                         :parent-style-state parent-style-state
                         :inherited-dependency-count
                         (if theme-parent-delta-p
                             1
                           (if theme-explicit-delta-style
                               0
                             (if parent-binding 1 0)))
                         :stylesheet-signature stylesheet-signature
                         :subject subject
                         :node node
                         :selector-view ebox-selector-view--current
                         :selector-topology ebox-selector-view--topology
                         :scopes scopes)))
              (plist-put
               new-state :compute
               (let ((captured new-state)
                     (delta-style theme-delta-style)
                     (parent-delta-p theme-parent-delta-p)
                     (last-style (and old-binding
                                      (ebox--pub-binding-last-value old-binding)))
                     (last-parent-style old-parent-style))
                 (if parent-delta-p
                     (lambda ()
                       (let ((parent-style
                              (and (plist-get captured :parent-binding)
                                   (ebox--pub-binding-read
                                    (plist-get captured :parent-binding)))))
                         (setq last-style
                               (or
                                (ebox-style--theme-parent-delta-computed
                                 last-style
                                 (plist-get captured :declarations)
                                 last-parent-style parent-style)
                                (ebox-surface--compute-node-style
                                 (plist-get captured :subject)
                                 (plist-get captured :declarations)
                                 parent-style (plist-get captured :scopes)
                                 (plist-get captured :selector-view))))
                         (setq last-parent-style parent-style)
                         last-style))
                   (lambda ()
                     (or delta-style
                         (ebox-surface--compute-node-style
                          (plist-get captured :subject)
                          (plist-get captured :declarations)
                          (and (plist-get captured :parent-binding)
                               (ebox--pub-binding-read
                                (plist-get captured :parent-binding)))
                          (plist-get captured :scopes)
                          (plist-get captured :selector-view)))))))
              new-state)))
         (precomputed-style
          (and (not reused-p)
               (or (and (null old-state)
                        (plist-get node :ebox-candidate-computed-style-p)
                        (plist-get node :ebox-computed-style))
                   (and (null old-state)
                        (hash-table-p ebox-surface--inline-style-value-cache)
                        (ebox-surface--compute-node-style
                         subject declarations new-parent-style
                         ebox-style--scopes)))))
         (binding
          (if precomputed-style
              (ebox--pub-bind-precomputed
               object 'ebox/computed-style (plist-get state :compute)
               precomputed-style (and parent-binding (list parent-binding)))
            (ebox--pub-bind
             object 'ebox/computed-style
             (plist-get state :compute)))))
    (unless reused-p
      (plist-put state :binding binding))
    (puthash object state style-state-table)
    (puthash subject binding bindings-by-subject)
    (puthash subject state states-by-subject)
    (when (plist-get node :ebox-candidate-computed-style-p)
      (cl-remf node :ebox-candidate-computed-style-p))
    binding))

(cl-defun ebox-surface--compute-node-style
    (subject declarations parent-style &optional (scopes ebox-style--scopes)
             (view ebox-selector-view--current))
  "Compute one node style, reusing selector-free immutable results."
  (let ((ebox-style--scopes scopes)
        (ebox-selector-view--current view))
  (if (or scopes (not (hash-table-p ebox-surface--inline-style-value-cache)))
      (ebox-style-compute-subject subject declarations parent-style)
    (let* ((key (list (ebox-selector-subject-type subject)
                      (ebox-selector-subject-id subject)
                      (ebox-selector-subject-classes subject)
                      (ebox-selector-subject-attributes subject)
                      (ebox-selector-subject-states subject)
                      declarations
                      (ebox-style--inherited-style-signature parent-style)))
           (missing (make-symbol "ebox-inline-style-cache-missing"))
           (cached (gethash key ebox-surface--inline-style-value-cache
                            missing)))
      (if (not (eq cached missing))
          cached
        (let ((style
               (ebox-style-compute-subject
                subject declarations parent-style)))
          (puthash key style ebox-surface--inline-style-value-cache)
          style))))))

(defun ebox-surface--project-font
    (node style &optional parent-font-fact snapshot)
  "Install NODE's font fact from STYLE, capability, and PARENT-FONT-FACT."
  (let ((snapshot (or snapshot (ebox-style--computed-snapshot style t))))
    (plist-put
     node :ebox-font-fact
     (ebox-font-project-values
      (car snapshot) (nth 2 snapshot)
      (ebox--current-display-signature)
      (or ebox-surface--font-window
          (ebox-surface--buffer-display-window (current-buffer)))
      parent-font-fact)))
  node)

(defun ebox-surface--refresh-font-projections (root)
  "Re-resolve retained computed font facts below candidate ROOT.
This is a host-capability projection only: it reuses each immutable computed
style and never re-runs selector matching or cascade."
  (cl-labels
      ((visit (node parent-font-fact)
         (when (and (listp node) (not (stringp node)))
           (when-let* ((style (plist-get node :ebox-computed-style))
                       ((ecss-computed-style-p style)))
             (ebox-surface--project-font
              node style parent-font-fact
              (ebox-style--computed-snapshot style t)))
           (let ((fact (plist-get node :ebox-font-fact)))
             (ebox-tree-for-each-direct-child
              node (lambda (child) (visit child fact)))))))
    (visit root nil))
  root)

(defun ebox-surface--closed-canonical-node-p (source-index node)
  "Return non-nil when NODE in SOURCE-INDEX needs closed inheritance."
  (let ((declarations
         (ebox-tree-node-source-declarations source-index node)))
    (and (eq (plist-get node :ebox-type) 'box)
         (memq (plist-get node :ebox-kind) '(box text))
         (not (ebox-style-cascade-active-p))
         (ebox-style--closed-declarations-p declarations)
         (cl-loop for (property _value) on declarations by #'cddr
                  never (ebox-style--custom-property-p property)))))

(defun ebox-surface-prepare-inline-candidate-styles
    (old-state candidate-index node-ids)
  "Prepare locally matched computed styles for candidate NODE-IDS.

OLD-STATE supplies published immutable computed styles.  CANDIDATE-INDEX owns
the unpublished node and parent tables.  Unchanged declaration/subject chains
reuse their exact prior style; changed nodes compute once against the prepared
candidate parent style.  Stylesheet rules deliberately disable this local
path when matching can extend outside NODE-IDS.  Local scoped rules require
unchanged mounting and membership facts; topology changes disable prior-style
reuse for visited nodes.  Return the prepared
source-handle-to-subject table when the requested local preparation completed."
  (let* ((source-index (plist-get candidate-index :source-index))
         (ebox-selector-view--current
          (ebox-source--index-selector-view source-index))
         (ebox-style--scopes
          (ebox-style-source-scopes source-index (plist-get candidate-index :root-node)))
         (stylesheet-signature (ebox-surface--stylesheet-signature)))
    (when (and node-ids
               (not (plist-get old-state :computed-styles-stale-p))
               (equal stylesheet-signature (plist-get old-state :stylesheet-signature))
               (ebox-surface--stylesheet-subject-local-p
                stylesheet-signature t))
      (let ((old-nodes (plist-get old-state :node-table))
            (new-nodes (plist-get candidate-index :node-table))
            (parents (plist-get candidate-index :parent-table))
            (old-source-index (plist-get old-state :source-index))
            (new-source-index (plist-get candidate-index :source-index))
            (resolved (make-hash-table :test 'equal))
            (visiting (make-hash-table :test 'equal))
            (subjects-by-id (make-hash-table :test 'equal))
            (subjects-by-handle (make-hash-table :test 'eq))
            (ebox-surface--inline-style-value-cache
             (make-hash-table :test 'equal)))
        (cl-labels
          ((resolve
            (node-id)
            (let ((missing (make-symbol "ebox-style-unresolved")))
              (let ((cached (gethash node-id resolved missing)))
                (if (not (eq cached missing))
                    cached
                  (when (gethash node-id visiting)
                    (error "Ebox candidate style parent cycle at %S" node-id))
                  (puthash node-id t visiting)
                  (let* ((node (ebox-runtime-index-get node-id new-nodes))
                         (old-node (ebox-runtime-index-get node-id old-nodes))
                         (parent-id (ebox-runtime-index-get node-id parents))
                         (parent-style (and parent-id (resolve parent-id)))
                         (old-parent-id
                          (and old-node
                               (ebox-runtime-index-get node-id
                                        (plist-get old-state :parent-table))))
                         (old-parent
                          (and old-parent-id
                               (ebox-runtime-index-get old-parent-id old-nodes)))
                         (old-parent-style
                          (and old-parent
                               (plist-get old-parent :ebox-computed-style)))
                         (old-style
                          (and old-node
                               (plist-get old-node :ebox-computed-style)))
                         (declarations
                          (and node
                               (ebox-tree-node-source-declarations
                                new-source-index node)))
                         (old-declarations
                          (and old-node
                               (ebox-tree-node-source-declarations
                                old-source-index old-node)))
                         (subject
                          (and node
                               (or (gethash node-id subjects-by-id)
                                   (let ((created
                                          (ebox-tree-node-subject
                                           new-source-index node)))
                                     (puthash node-id created subjects-by-id)
                                     (puthash
                                      (ebox-tree-node-source-handle node)
                                      created subjects-by-handle)
                                     created))))
                         (old-subject
                          (and old-node
                               ;; Metadata publications retain Ebox publication bindings.
                               ;; Their captured subject may predate the last
                               ;; selector transition; Source owns current facts.
                               (ebox-tree-node-subject old-source-index old-node)))
                         (source-stable-p
                          (and old-node
                               (or (null ebox-style--scopes)
                                   (eq (ebox-source--index-selector-topology new-source-index)
                                       (ebox-source--index-selector-topology old-source-index)))
                               (equal parent-id old-parent-id)
                               (eq parent-style old-parent-style)
                               (ebox-style-declarations-equal-p
                                declarations old-declarations)
                               (ebox-surface--subject-local-equal-p
                                subject old-subject)))
                         (style
                          (or (and source-stable-p old-style)
                              (and node (not source-stable-p)
                                   (or parent-style declarations
                                       (ebox-style-cascade-active-p))
                                   (ebox-surface--compute-node-style
                                    subject declarations
                                    parent-style)))))
                    ;; A local selector fact can change without changing the
                    ;; cascade result. Preserve exact immutable style identity
                    ;; so descendants do not treat an equal parent as a fresh
                    ;; inheritance generation.
                    (when (and old-style (equal style old-style))
                      (setq style old-style))
                    (when (and node style (not (eq node old-node)))
                      (let ((snapshot
                             (ebox-style--computed-snapshot style t)))
                        (ebox-surface--project-font
                         node style
                         (and parent-id
                              (plist-get (ebox-runtime-index-get parent-id new-nodes)
                                         :ebox-font-fact))
                         snapshot)
                        (cond
                         ((and source-stable-p
                               (ebox-style--computed-projection-transferable-p
                                old-node node style))
                          (ebox-style--transfer-computed-projection
                           old-node node style))
                         ((and (null (plist-get node :ebox-computed-style))
                               (ebox-surface--closed-canonical-node-p
                                new-source-index node))
                          (ebox-style-apply-closed-inheritance
                           node style snapshot))
                         (t
                          (ebox-style-apply-computed node style snapshot))))
                      (plist-put node :ebox-computed-style style)
                      (plist-put node :ebox-candidate-computed-style-p t))
                    (remhash node-id visiting)
                    (puthash node-id style resolved)
                    style))))))
          (dolist (node-id node-ids)
            (when (ebox-runtime-index-get node-id new-nodes)
              (resolve node-id))))
        subjects-by-handle))))

(defun ebox-surface-interaction-styles-unchanged-p (state source-index node-ids)
  "Prove that local interaction facts leave STATE's computed output unchanged.
SOURCE-INDEX has the same declarations and topology. Subject-local matching
limits direct effects to NODE-IDS; equal complete styles also prove unchanged
inheritance for their descendants. Relational rules require ordinary planning."
  (let* ((ebox-selector-view--current (ebox-source--index-selector-view source-index))
         (ebox-selector-view--topology (ebox-source--index-selector-topology source-index))
         (ebox-style--scopes (ebox-style-source-scopes source-index (plist-get state :root-node)))
         (signature (ebox-surface--stylesheet-signature))
         (nodes (plist-get state :node-table))
         (parents (plist-get state :parent-table)))
    (and (equal signature (plist-get state :stylesheet-signature))
         (ebox-surface--stylesheet-subject-local-p signature t)
         (cl-every
          (lambda (id)
            (let* ((node (ebox-runtime-index-get id nodes))
                   (parent (ebox-runtime-index-get (ebox-runtime-index-get id parents) nodes))
                   (style (plist-get node :ebox-computed-style)))
              (and style
                   (equal style
                          (ebox-surface--compute-node-style
                           (ebox-tree-node-subject source-index node)
                           (ebox-tree-node-source-declarations source-index node)
                           (plist-get parent :ebox-computed-style))))))
          node-ids))))

(defun ebox-surface--node-style-binding-required-p (source-index node)
  "Return non-nil when NODE in SOURCE-INDEX needs its own style binding."
  (let ((declarations
         (ebox-tree-node-source-declarations source-index node)))
    (or (ebox-surface--style-consuming-node-p node)
        (cl-some (lambda (property)
                   (plist-member declarations property))
                 ebox-surface--inherited-style-properties)
        (cl-loop for (property _value) on declarations by #'cddr
                 thereis (and (symbolp property)
                              (string-prefix-p "--" (symbol-name property)))))))

(defun ebox-surface--apply-node-style
    (source-index object node subject-table bindings-by-subject states-by-subject
            style-state-table
            stylesheet-signature selector-tree-token
            stylesheet-subject-local-p)
  "Compute and apply NODE style using retained OBJECT and SUBJECT-TABLE."
  (when-let* ((subject
               (ebox-source--subject-table-get
                subject-table (ebox-tree-node-source-handle node))))
    (let* ((parent-subject (ebox-selector-view-parent subject))
           (parent-state (and parent-subject
                              (gethash parent-subject states-by-subject)))
           (parent-node (and parent-state (plist-get parent-state :node)))
           (parent-font-fact
            (and parent-node (plist-get parent-node :ebox-font-fact)))
           (precomputed-p
            (plist-get node :ebox-candidate-computed-style-p))
           (precomputed-style
            (and precomputed-p (plist-get node :ebox-computed-style))))
      (if (and (hash-table-p ebox-surface--inline-style-value-cache)
               (not (ebox-surface--node-style-binding-required-p
                     source-index node)))
        (when-let* ((parent (ebox-selector-view-parent subject))
                    (binding (gethash parent bindings-by-subject)))
          (puthash subject binding bindings-by-subject)
          (when-let* ((state (gethash parent states-by-subject)))
            (puthash subject state states-by-subject))
          (let ((style (ebox--pub-binding-read binding)))
            (unless (and precomputed-p (equal style precomputed-style))
              (let ((snapshot (ebox-style--computed-snapshot style t)))
                (ebox-surface--project-font
                 node style parent-font-fact snapshot)
                (unless (equal style (plist-get node :ebox-computed-style))
                  (ebox-style-apply-closed-inheritance
                   node style snapshot)))))
          (when precomputed-p
            (cl-remf node :ebox-candidate-computed-style-p)))
      (let* ((style
             (ebox--pub-binding-read
              (ebox-surface--node-style-binding
               source-index object node subject
               bindings-by-subject states-by-subject
               style-state-table
               stylesheet-signature selector-tree-token
               stylesheet-subject-local-p ebox-style--scopes))))
        (unless (and precomputed-p (equal style precomputed-style))
          (let ((snapshot (ebox-style--computed-snapshot style t)))
            (ebox-surface--project-font node style parent-font-fact snapshot)
            (unless (equal style (plist-get node :ebox-computed-style))
              (if (and (null (plist-get node :ebox-computed-style))
                       (ebox-surface--closed-canonical-node-p
                        source-index node))
                  (ebox-style-apply-closed-inheritance node style snapshot)
                (ebox-style-apply-computed node style snapshot))))))))))

(defun ebox-surface--static-style-state-p (state &optional seen)
  "Return non-nil when STATE's inherited binding closure is static.  The style
compute may depend on its parent binding exactly once.  Any other dependency
is a dynamic Ebox publication source and prevents a local cascade proof."
  (let* ((binding (and state (plist-get state :binding)))
         (parent-binding (and state (plist-get state :parent-binding)))
         (parent-state (and state (plist-get state :parent-style-state)))
         (inherited-count
          (and state (plist-get state :inherited-dependency-count))))
    (and (ebox--pub-binding-live-p binding)
         (not (memq state seen))
         (integerp inherited-count)
         (= (ebox--pub-binding-dependency-count binding)
            inherited-count)
         (if parent-binding
             (and parent-state
                  (eq parent-binding (plist-get parent-state :binding))
                  (ebox-surface--static-style-state-p
                   parent-state (cons state seen)))
           (null parent-state)))))

(defun ebox-surface--cascade-local-owner-proof-p
    (state candidate-state dirty-set)
  "Return non-nil when DIRTY-SET has a static cascade closure in STATE.
CANDIDATE-STATE supplies the declarative nodes before cascade projection.
Missing binding state, changed declarations or selector metadata, dynamic
dependencies, or any malformed index conservatively preserves root planning."
  (let* ((objects (plist-get state :surface-node-object-table))
         (style-states (plist-get state :style-binding-states))
         (candidate-nodes (plist-get candidate-state :node-table))
         (candidate-source-index (plist-get candidate-state :source-index))
         (stylesheet-signature
         (let* ((cache ebox-incremental--allocated-slot-proof-cache)
                (missing (make-symbol "ebox-stylesheet-proof-missing"))
                (cached (and cache
                             (gethash 'stylesheet-signature cache missing))))
           (if (and cached (not (eq cached missing))
                    (eq (car cached) candidate-source-index))
               (cdr cached)
             (let* ((ebox-style--scopes
                     ;; Planning runs outside the surface's cascade binding.
                     ;; Compare the candidate's mounted scopes, not an empty
                     ;; ambient scope list, with the published style closure.
                     (ebox-style-source-scopes
                      candidate-source-index
                      (plist-get candidate-state :root-node)))
                    (signature (ebox-surface--stylesheet-signature)))
               (when cache
                 (puthash 'stylesheet-signature
                          (cons candidate-source-index signature) cache))
               signature)))))
    (and (hash-table-p objects)
         (hash-table-p style-states)
         (ebox-runtime-index-like-p candidate-nodes)
         dirty-set
         (cl-every
          (lambda (entry)
            ;; Paint can change selector state too.  Retaining its bindings
            ;; needs the same subject/cascade proof as a geometry owner.
            (let* ((node-id (plist-get entry :node-id))
                     (object (and node-id (gethash node-id objects)))
                     (style-state (and object (gethash object style-states)))
                     (candidate-node (and node-id
                                          (ebox-runtime-index-get
                                           node-id candidate-nodes)))
                     (subject (and style-state
                                   (plist-get style-state :subject)))
                     (candidate-declarations
                      (and candidate-node
                           (ebox-tree-node-source-declarations
                            candidate-source-index candidate-node)))
                     (locally-computed-p
                      (and candidate-node
                           (plist-get candidate-node
                                      :ebox-candidate-computed-style-p)
                           (ecss-computed-style-p
                            (plist-get candidate-node :ebox-computed-style))
                           (ebox-style--closed-declarations-p
                            candidate-declarations)))
                     (selector-stable-p
                      (and candidate-node subject
                       (equal (ebox-tree-node-id
                               candidate-source-index candidate-node)
                              (ebox-selector-subject-id subject))
                       (equal (ebox-tree-node-classes
                               candidate-source-index candidate-node)
                              (ebox-selector-subject-classes subject))
                       (equal (ebox-tree-metadata-string
                               (ebox-tree-node-selector-type candidate-node))
                              (ebox-selector-subject-type subject))
                       (equal
                        (mapcar
                         (lambda (attribute)
                           (cons (substring (symbol-name (car attribute)) 1)
                                 (cdr attribute)))
                         (ebox-tree-node-attributes
                          candidate-source-index candidate-node))
                        (ebox-selector-subject-attributes subject))
                       (equal (ebox-tree-node-state
                               candidate-source-index candidate-node)
                              (ebox-selector-subject-states subject)))))
                (and style-state candidate-node subject
                     (or selector-stable-p
                         (and locally-computed-p
                              (null (car stylesheet-signature))
                              (null (nth 2 stylesheet-signature))))
                     (or locally-computed-p
                         (and
                          (or (ebox-style-declarations-equal-p
                               candidate-declarations
                               (plist-get style-state :declarations))
                              (ebox-style--paint-declarations-equivalent-p
                               (plist-get style-state :declarations)
                               candidate-declarations))
                          selector-stable-p))
                     (equal stylesheet-signature
                            (plist-get style-state :stylesheet-signature))
                     (ebox-surface--static-style-state-p style-state))))
          dirty-set))))

(defun ebox-surface--ensure-node-tree
    (context parent node source-index table subject-table bindings-by-subject
             states-by-subject style-state-table stylesheet-signature
             selector-tree-token stylesheet-subject-local-p
             &optional parent-kind node-objects)
  "Ensure styled NODE descendants below PARENT in CONTEXT and fill TABLE.
NODE-OBJECTS reuses already ensured identities for a same-context style pass."
  (ebox--ensure-node-id node)
  (let ((object
         (if node-objects
             (or (gethash (plist-get node :node-id) node-objects)
                 (error "Ebox focus reprojection lost a retained node"))
           (ebox--pub-object-ensure context parent
                             (ebox-surface--node-key node)
                             (ebox-surface--node-kind node)))))
    (ebox--pub-object-retain context object)
    (plist-put node :surface-object object)
    (puthash node object table)
    (when subject-table
      (ebox-surface--apply-node-style
       source-index object node subject-table
       bindings-by-subject states-by-subject
       style-state-table
       stylesheet-signature selector-tree-token
       stylesheet-subject-local-p))
    (let ((child-kind (ebox-tree--child-layout-kind node parent-kind)))
      (ebox-tree-for-each-direct-child
       node
       (lambda (child)
         (ebox-surface--ensure-node-tree
          context object child source-index table subject-table
          bindings-by-subject
          states-by-subject style-state-table stylesheet-signature
          selector-tree-token stylesheet-subject-local-p
          child-kind node-objects))))
    (when subject-table
      (ebox-tree--validate-node-parent-participation
       node parent-kind 'computed))
    object))

(defun ebox-surface--node-object-table (objects-by-node)
  "Return a node-id keyed table from OBJECTS-BY-NODE."
  (let ((table (make-hash-table :test 'equal)))
    (maphash
     (lambda (node object)
       (let ((node-id (if (listp node)
                          (plist-get node :node-id)
                        node)))
         (unless node-id
           (error "Ebox rendered node has no runtime identity"))
         (puthash node-id object table)))
     objects-by-node)
    table))

(defun ebox-surface--region-object-table (state node-objects)
  "Return region-to-object table from candidate STATE and NODE-OBJECTS."
  (let ((table (make-hash-table :test 'equal)))
    (ebox-runtime-index-map
     (lambda (region-id node-id)
       (let ((object (gethash node-id node-objects)))
         (unless object
           (error "Ebox region %S has no candidate surface object" region-id))
         (puthash region-id object table)))
     (plist-get state :region-node-table))
    table))

(defun ebox-surface--object-region-table (region-objects)
  "Return an object-to-region table from REGION-OBJECTS."
  (let ((table (make-hash-table :test 'eq)))
    (maphash (lambda (region-id object)
               (puthash object region-id table))
             region-objects)
    table))

(defun ebox-surface--node-editable-region-id (node)
  "Return NODE's editable Ebox region id, or nil."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ('box (plist-get node :region-id))
    ((or 'flex 'grid)
     (plist-get (plist-get node :box) :region-id))
    (_ nil)))

(defun ebox-surface--logical-id-region-table (state region-objects)
  "Return root-scoped logical-id entries for STATE and REGION-OBJECTS."
  (let ((table (make-hash-table :test 'equal)))
    (if (or (plist-get state :selector-index-stale-p)
            (and (plist-get state :source-index)
                 (ebox-source--index-derived-stale-p
                  (plist-get state :source-index))))
        ;; A structural delta deliberately leaves selector search paths lazy.
        ;; Its old entries can point at removed region identities.  Logical
        ;; publication needs current source membership, not selector paths.
        (ebox-runtime-index-map
         (lambda (_id node)
           (when-let* ((handle (ebox-tree-node-source-handle node))
                       (record (ebox-source--index-record
                                (plist-get state :source-index) handle))
                       (logical-id (ebox-source-record-id record))
                       (region-id (ebox-surface--node-editable-region-id node))
                       (object (gethash region-id region-objects)))
             (push (cons object region-id) (gethash logical-id table))))
         (plist-get state :node-table))
      (maphash
       (lambda (logical-id entries)
         (dolist (entry entries)
           (when-let* ((region-id
                        (ebox-surface--node-editable-region-id (car entry)))
                       (object (gethash region-id region-objects)))
             (push (cons object region-id) (gethash logical-id table)))))
       (plist-get state :selector-id-table)))
    (maphash (lambda (logical-id matches)
               (puthash logical-id (nreverse matches) table))
             table)
    table))

(defun ebox-surface--hash-keys (table)
  "Return TABLE keys in unspecified order."
  (let (keys)
    (maphash (lambda (key _value) (push key keys)) table)
    keys))

(defun ebox-surface--retained-scroll-lookahead (state)
  "Return lookahead needed to retain STATE's prepared lazy prefixes."
  (when-let* ((table (plist-get state :scroll-state-table)))
    (let ((maximum 0))
      (maphash
       (lambda (_region-id scroll-state)
         (let ((retained (length (plist-get scroll-state :content-lines)))
               (offset (or (plist-get scroll-state :scroll-offset) 0))
               (height (or (plist-get scroll-state :content-height) 0)))
           (setq maximum
                 (max maximum (- retained offset height 1)))))
       table)
      (max 0 maximum))))

(defun ebox-surface--scroll-metadata-snapshot (table producer-region-ids)
  "Return reusable lazy-scroll metadata copied from TABLE.
PRODUCER-REGION-IDS names scroll-only updates whose producer closures remain
valid because their declarative layout and viewport did not change."
  (let ((snapshot (make-hash-table :test 'equal)))
    (maphash
     (lambda (region-id state)
       (let ((preserve-producer-p
              (member region-id producer-region-ids))
             (producer-keys
              '(:content-lines :rendered-content-lines
                :rendered-content-line-cells
                :content-lines-complete-p :render-content-prefix
                :materialize-content-lines :region-line-bounds-index
                :region-line-span-index :region-line-span-index-deferred
                :rendered-region-line-span-index
                :rendered-region-line-span-index-deferred
                :region-line-span-hints :cache-miss-prefetch-target-lines
                :native-reflow-target-prefix-p
                :native-reflow-prefix-reset-p :native-reflow-visible-offset
                :native-reflow-visible-lines))
             metadata)
         (dolist (key (append
                       '(:content-region-id-set :lazy-scroll-prefix-dirty
                         :lazy-scroll-window-refresh-required)
                       (and preserve-producer-p producer-keys)))
           (when (if (memq key producer-keys)
                     (plist-member state key)
                   (plist-get state key))
             (setq metadata
                   (plist-put metadata key (plist-get state key)))))
         (when metadata
           (puthash region-id metadata snapshot))))
     table)
    snapshot))

(defun ebox-surface--restore-scroll-metadata (table snapshot)
  "Restore reusable lazy-scroll SNAPSHOT fields into TABLE."
  (maphash
   (lambda (region-id metadata)
     (when-let* ((state (gethash region-id table)))
       (while metadata
         (setq state
               (plist-put state (pop metadata) (pop metadata))))
       (puthash region-id state table)))
   snapshot))

(defun ebox-surface--refresh-rendered-layout-snapshots (state)
  "Refresh stale base snapshots after rendering STATE's complete root.
Keep unchanged entries and their details.  Old published geometry remains
available during planning; replacements here belong only to the candidate."
  (let ((snapshots (plist-get state :layout-snapshots))
        (nodes (plist-get state :node-table))
        (ebox--node-region-ids-cache (make-hash-table :test 'eq))
        updated)
    (when (hash-table-p snapshots)
      (maphash
       (lambda (node-id snapshot)
         (let* ((node (ebox-runtime-index-get node-id nodes))
                (fresh (and node (ebox--node-layout-snapshot nil node nil))))
           (unless (and fresh
                        (cl-every
                         (lambda (key)
                           (equal (plist-get snapshot key) (plist-get fresh key)))
                         '(:node-id :type :display :region-ids
                           :style-signature :child-ids)))
             (unless updated (setq updated (copy-hash-table snapshots)))
             (if fresh
                 (puthash node-id fresh updated)
               (remhash node-id updated)))))
       snapshots)
      (when updated
        (plist-put state :layout-snapshots updated))))
  state)

(defun ebox-surface--render-candidate (state)
  "Render candidate STATE's complete root in isolated side tables."
  (let ((rendered
         (ebox-surface--render-candidate-node state (plist-get state :root-node))))
    ;; A complete physical line owns its pixel remainder.  Keep the raw render
    ;; and cached child strings untouched.  Retain pre-quantization output so
    ;; later owner updates can recover their original fractional allocation.
    (plist-put state :fractional-pixel-output-p
               (ebox--fractional-pixel-spaces-p rendered))
    (plist-put state :raw-layout-output
               (and (plist-get state :fractional-pixel-output-p) rendered))
    (cl-remf state :raw-layout-fragments)
    (cl-remf state :raw-layout-snapshots)
    (when (plist-get state :fractional-pixel-output-p)
      (unless (plist-get state :native-render-p)
        ;; The raw and rounded strings have identical character, role and
        ;; paint coordinates. Build their common ledger once, while creating
        ;; the full frame, instead of reparsing the page on its first edit.
        (plist-put state :raw-layout-fragments
                   (ebox-surface--rendered-fragments rendered)))
      (let ((ebox--render-owned-text-values
             (plist-get state :render-owned-text-values)))
        (setq rendered (ebox--quantize-pixel-spaces rendered))
        (ebox--record-render-output-provenance rendered)))
    ;; A retained node id can now describe a different display or subtree.
    ;; Refresh the complete lightweight snapshot, including ancestor region
    ;; membership; stripping only span details would preserve stale style facts.
    (setq state (ebox-surface--finish-runtime-state state))
    (ebox-surface--refresh-rendered-layout-snapshots state)
    rendered))

(defun ebox-surface--render-candidate-node (state node &optional complete-lines-p)
  "Render NODE from candidate STATE in isolated Ebox side tables.
COMPLETE-LINES-P requires a proven physical line origin for every output row."
  (let ((scroll-table
         (or (plist-get state :scroll-state-table)
             (make-hash-table :test 'equal)))
        (scroll-metadata
         (ebox-surface--scroll-metadata-snapshot
          (or (plist-get state :scroll-state-table)
              (make-hash-table :test 'equal))
          (plist-get state :preserve-scroll-producer-region-ids)))
        (timer-table (make-hash-table :test 'equal))
        (smooth-table (make-hash-table :test 'equal)))
    (cl-remf state :preserve-scroll-producer-region-ids)
    (cl-remf state :native-render-p)
    (cl-remf state :native-render-output)
    (cl-remf state :native-render-fragments)
    (cl-remf state :native-render-frame)
    (cl-remf state :native-render-fragment-template)
    (cl-remf state :native-render-fallback)
        (let ((ebox-viewport-width (plist-get state :viewport-width))
              (ebox-viewport-height (plist-get state :viewport-height))
              (ebox--render-display-signature
               (plist-get state :display-signature))
              (ebox--region-box-table (plist-get state :region-box-table))
          (ebox--scroll-global-state scroll-table)
          (ebox--scroll-idle-prefetch-timers timer-table)
          (ebox--smooth-scroll-state-table smooth-table)
          (ebox--render-runtime-revision
           (plist-get state :runtime-revision))
          (ebox--render-source-index (plist-get state :source-index))
          (ebox-incremental--render-portals-p
           (if (plist-member state :root-portals-p)
               (plist-get state :root-portals-p)
             'unknown))
          (ebox-layer--active-p
           (if (plist-member state :layered-p)
               (plist-get state :layered-p)
             'unknown))
          (ebox--render-cache-table (plist-get state :render-cache))
          ;; Responsive descendants are reusable under the exact containing
          ;; and viewport constraints included in their render signature.
          ;; Keeping this enabled avoids relayout of unrelated percentage-sized
          ;; branches during an interaction update.
          (ebox--render-cache-allow-viewport-dependent t)
          (ebox--layout-fragments-table
           (plist-get state :layout-fragments))
          (ebox--layout-fragments-reuse-p
           (plist-get state :layout-fragments-reuse-p))
          (ebox--render-cache-signature-cache
           (plist-get state :render-signature-cache))
          ;; Layer composition is a candidate-local ledger.  Previous rows
          ;; are read-only; the fresh table is retained only after commit.
          (ebox-layer--previous-composition-cache
           (plist-get state :previous-layer-composition-cache))
          (ebox-layer--composition-cache
           (or (plist-get state :layer-composition-cache)
               (make-hash-table :test 'equal)))
          (ebox-layer--composition-context
           (or (plist-get state :layer-composition-context)
               (list (plist-get state :viewport-width)
                     (plist-get state :viewport-height)
                     (plist-get state :display-signature))))
          (ebox--scroll-window-initial-lookahead-lines-override
           (ebox-surface--retained-scroll-lookahead state))
          (ebox--viewport-dependent-node-ids-cache
           (make-hash-table :test 'eq))
          (ebox--viewport-dependent-subtree-cache
           (make-hash-table :test 'eq))
          (ebox--viewport-height-dependent-subtree-cache
           (plist-get state :viewport-height-dependent-subtree-cache))
          (ebox--flex-content-min-width-table
           (plist-get state :flex-content-min-widths))
          (ebox--paint-origin-capture-p t)
          (ebox--render-owned-text-values
           (make-hash-table :test #'eq)))
      (cl-letf (((symbol-function 'ebox--scroll-schedule-idle-prefetch)
                 (lambda (&rest _) nil)))
        (when (and (require 'ebox-native-commit nil t)
                   (not (ebox-surface--runtime-index-ready-p state)))
          (setq state (ebox-surface--finish-runtime-state state)))
        (let ((rendered
               (ebox-incremental--with-phase 'layout
                 (or (and (require 'ebox-native-commit nil t)
                          (ebox-native-commit-render state node))
                     (let ((ebox--surface-materialization-active t))
                       (ebox--render-layout node))))))
          (when (and complete-lines-p
                     (ebox--fractional-pixel-spaces-p rendered))
            ;; Untouched buffer rows are already quantized.  Their raw
            ;; fractional evidence cannot be disproved by this local render.
            (plist-put state :fractional-pixel-output-p t)
            (setq rendered (ebox--quantize-pixel-spaces rendered)))
          (ebox-surface--check-local-pixel-output rendered)
          (unless (plist-get state :native-render-p)
            (ebox--record-render-output-provenance rendered))
          (unless (plist-get state :native-render-p)
            (ebox-surface--restore-scroll-metadata
             scroll-table scroll-metadata))
          (plist-put state :scroll-state-table scroll-table)
          (plist-put state :scroll-region-ids
                     (ebox-surface--hash-keys scroll-table))
          (plist-put state :render-owned-text-values
                     ebox--render-owned-text-values)
          (plist-put state :layer-composition-cache
                     ebox-layer--composition-cache)
          rendered)))))

(defun ebox-surface--attach-retained-node-objects (state)
  "Attach retained Ebox publication objects to candidate nodes in STATE."
  (let ((nodes (plist-get state :node-table))
        (objects (plist-get state :surface-node-object-table)))
    (when (and (ebox-runtime-index-like-p nodes) (hash-table-p objects))
      (maphash
       (lambda (node-id object)
         (when-let* ((node (ebox-runtime-index-get node-id nodes)))
           (plist-put node :surface-object object)))
       objects))
    state))

(defun ebox-surface--apply-retained-owner-styles (state)
  "Apply retained static computed styles to owner-scoped nodes in STATE."
  (let* ((proofs (plist-get state :owner-scoped-proofs))
         (owner-ids
          (or (mapcar (lambda (proof) (plist-get proof :owner-id)) proofs)
              (and (plist-get state :span-patch-owner-id)
                   (list (plist-get state :span-patch-owner-id)))))
         (nodes (plist-get state :node-table))
         (objects (plist-get state :surface-node-object-table))
         (style-states (plist-get state :style-binding-states)))
    (dolist (owner-id owner-ids)
      (when-let* ((node (and nodes (ebox-runtime-index-get owner-id nodes)))
                  (object (and objects (gethash owner-id objects)))
                  (style-state (and style-states
                                    (gethash object style-states)))
                  (binding (plist-get style-state :binding)))
        (ebox-style-apply-computed node (ebox--pub-binding-read binding))))
    (when owner-ids
      (ebox-tree-validate-indexed-participation
       nodes (plist-get state :parent-table) owner-ids 'computed))
    state))

(defun ebox-surface--rendered-role-topology-signature
    (rendered region-ids)
  "Return rendered Ebox role topology for REGION-IDS in RENDERED."
  (let ((wanted (make-hash-table :test 'equal))
        (roles-table (make-hash-table :test 'eq))
        (position 0)
        (limit (length rendered)))
    (dolist (region-id region-ids)
      (puthash region-id t wanted))
    (while (< position limit)
      (dolist (entry (ebox-surface--role-ids-at rendered position))
        (when (gethash (cdr entry) wanted)
          (puthash (car entry) t roles-table)))
      (setq position
            (max (or (next-property-change position rendered limit) limit)
                 (1+ position))))
    (let (roles)
      (maphash (lambda (role _value) (push role roles)) roles-table)
      (list :roles
            (sort roles
                  (lambda (left right)
                    (string< (symbol-name left)
                             (symbol-name right))))))))

(defun ebox-surface--span-patch-lines
    (buffer spans rendered &optional variable-content-p
            variable-content-max-width owner-set)
  "Return RENDERED shaped for BUFFER SPANS, or nil when unsafe.
When VARIABLE-CONTENT-P is non-nil, allow a stable partial slot to retain its
old allocated width while the owner changes its natural content length."
  (with-current-buffer buffer
    (if (ebox-buffer--partial-line-slots-p spans)
        (if variable-content-p
            (let ((lines (ebox-string-lines rendered)))
              (when (and (= (length spans) (length lines))
                         (or (null variable-content-max-width)
                             (cl-every
                              (lambda (line)
                                (<= (ebox--string-pixel-width line)
                                    variable-content-max-width))
                              lines)))
                rendered))
          (ebox-buffer--rendered-in-existing-slots
           spans rendered owner-set t))
      (and (= (length spans) (length (ebox-string-lines rendered)))
           rendered))))

(defun ebox-surface--projected-span-positions (spans lines)
  "Return BUFFER span positions after replacing SPANS with LINES."
  (when (= (length spans) (length lines))
    (let ((delta 0) result)
      (cl-loop for span in spans
               for line in lines
               do (let* ((start (+ (car span) delta))
                         (end (+ start (length line))))
                    (push (cons start end) result)
                    (setq delta
                          (+ delta (- (length line)
                                      (- (cdr span) (car span)))))))
      (nreverse result))))

(defun ebox-surface--replace-buffer-spans
    (source origin spans lines)
  "Return SOURCE with buffer SPANS replaced by propertized LINES."
  (catch 'invalid
    (let ((cursor origin) pieces)
      (cl-loop for span in spans
               for line in lines
               do (let ((start (car span)) (end (cdr span)))
                    (when (or (< start cursor) (< end start))
                      (throw 'invalid nil))
                    (push (substring source (- cursor origin) (- start origin))
                          pieces)
                    (push line pieces)
                    (setq cursor end)))
      (push (substring source (- cursor origin)) pieces)
      (apply #'concat (nreverse pieces)))))

(defun ebox-surface--changed-span-pairs (source origin pairs)
  "Return only changed SOURCE/replacement PAIRS.
PAIRS contains buffer-position spans paired with candidate replacement lines.
Compare both characters and text properties, so a row whose composed pixels
and ownership are unchanged is omitted from the edit set.  Keeping unchanged
rows out of the transaction is the damage-region optimization for layer moves:
the candidate may still be rendered for proof, but publication touches only
the old/new affected rows."
  (cl-remove-if
   (lambda (pair)
     (let* ((span (car pair))
            (line (cdr pair))
            (start (- (car span) origin))
            (end (- (cdr span) origin)))
       (and (<= 0 start end (length source))
            (equal-including-properties (substring source start end) line))))
   pairs))

(defun ebox-surface--span-patch-details
    (_buffer snapshot node spans rendered
             &optional variable-content-p variable-content-max-width)
  "Return validated replacement details for SNAPSHOT and RENDERED."
  (let* ((lines (ebox-string-lines rendered))
         (new-spans (ebox-surface--projected-span-positions spans lines))
         (old-footprint (plist-get snapshot :span-footprint-signature))
         (new-footprint
          (and new-spans (ebox--rendered-span-footprint-signature rendered)))
         (new-external
          (and new-footprint
               (ebox--external-footprint-signature-from-span-footprint
                new-footprint)))
         (new-parent
          (and new-footprint
               (ebox--project-parent-slot-signature
                (plist-get snapshot :parent-slot-signature)
                new-footprint)))
         (new-roles
          (and new-spans
               (ebox-surface--rendered-role-topology-signature
                rendered (plist-get snapshot :region-ids))))
         (new-overflow (ebox--overflow-signature node)))
    (when (and old-footprint new-footprint
               (if variable-content-p
                   (and (= (plist-get old-footprint :span-count)
                           (plist-get new-footprint :span-count))
                        (or (null variable-content-max-width)
                            (<= (or (plist-get new-external
                                               :max-line-pixel-width)
                                    0)
                                variable-content-max-width)))
                 (and (ebox--span-footprint-compatible-p
                       old-footprint new-footprint)
                      (ebox--external-footprint-compatible-p
                       (plist-get snapshot :external-footprint-signature)
                       new-external)
                      (ebox--parent-slot-compatible-p
                       (plist-get snapshot :parent-slot-signature)
                       new-parent)))
               (equal (plist-get snapshot :role-topology-signature)
                      new-roles)
               (equal (plist-get snapshot :overflow-signature)
                      new-overflow))
      (list :lines lines :spans new-spans :footprint new-footprint
            :external new-external :parent new-parent :roles new-roles
            :overflow new-overflow
            :variable-content-p variable-content-p))))

(defun ebox-surface--install-span-patch-snapshot
    (state owner-id snapshot details &optional generation-override)
  "Install DETAILS for OWNER-ID into candidate STATE snapshots."
  (let* ((current-generation
          (or (plist-get state :layout-snapshot-detail-generation) 0))
         (old-footprint (plist-get snapshot :span-footprint-signature))
         (new-footprint (plist-get details :footprint))
         (coordinates-stable-p
          (equal (plist-get old-footprint :char-lengths)
                 (plist-get new-footprint :char-lengths)))
         (generation (or generation-override
                         (if coordinates-stable-p
                             current-generation
                           (1+ current-generation))))
         (updated (copy-sequence snapshot))
         (spans (plist-get details :spans))
         (footprint new-footprint))
    (dolist (entry `((:buffer-span . ,(car spans))
                     (:buffer-spans . ,spans)
                     (:line-signature . ,(plist-get footprint
                                                    :line-pixel-widths))
                     (:span-footprint-signature . ,footprint)
                     (:external-footprint-signature
                      . ,(plist-get details :external))
                     (:parent-slot-signature
                      . ,(if (plist-get details :variable-content-p)
                             (plist-get snapshot :parent-slot-signature)
                           (plist-get details :parent)))
                     (:role-topology-signature . ,(plist-get details :roles))
                     (:overflow-signature . ,(plist-get details :overflow))
                     (:detail-generation . ,generation)))
      (setq updated (plist-put updated (car entry) (cdr entry))))
    (puthash owner-id updated (plist-get state :layout-snapshots))
    (plist-put state :layout-snapshot-detail-generation generation)
    (plist-put state :layout-snapshots-complete-p nil)
    (when-let* ((proof
                 (cl-find owner-id
                          (plist-get state :allocation-certificate-proofs)
                          :key (lambda (candidate)
                                 (plist-get candidate :owner-id))
                          :test #'equal))
                (signature (plist-get proof :ancestor-slot-signature)))
      (let ((certificates
             (or (plist-get state :retained-allocation-certificates)
                 (make-hash-table :test 'equal))))
        (puthash
         owner-id
         (list :root-id
               (plist-get (plist-get state :root-node) :node-id)
               :viewport-width (plist-get state :viewport-width)
               :viewport-height (plist-get state :viewport-height)
               :display-signature
               (copy-tree (plist-get state :display-signature))
               :signature (copy-tree signature))
         certificates)
        (plist-put state :retained-allocation-certificates certificates)))
    state))

(defun ebox-surface--allocation-owner-line-signature (lines region-ids)
  "Return local content-owner run signatures for propertized LINES."
  (let ((local (ebox--region-id-set region-ids)))
    (mapcar
     (lambda (line)
       (let ((position 0) (limit (length line)) previous runs)
         (while (< position limit)
           (let* ((owners
                   (copy-sequence
                    (or (get-text-property position
                                           'ebox-content-owners line)
                        nil)))
                  (owner (get-text-property position
                                            'ebox-content-owner line))
                  (stack (if (and owner (not (member owner owners)))
                             (append owners (list owner))
                           owners))
                  (local-stack
                   (cl-remove-if-not (lambda (id) (gethash id local)) stack))
                  (next (or (next-property-change position line limit)
                            limit)))
             (unless (equal local-stack previous)
               (push local-stack runs)
               (setq previous local-stack))
             (setq position (max (1+ position) next))))
         (nreverse runs)))
     lines)))

(defun ebox-surface--retained-external-owner-suffix
    (buffer spans region-ids &optional allow-empty-p)
  "Return one common retained content-owner suffix outside REGION-IDS.
ALLOW-EMPTY-P permits t to represent a proved empty suffix in a root cache."
  (let ((local (ebox--region-id-set region-ids)) common seen valid)
    (setq valid t)
    (with-current-buffer buffer
      (dolist (span spans)
        (let ((position (car span)) (limit (cdr span)))
          (while (and valid (< position limit))
            (let* ((owners
                    (copy-sequence
                     (or (get-text-property position 'ebox-content-owners)
                         nil)))
                   (owner (get-text-property position 'ebox-content-owner))
                   (stack (if (and owner (not (member owner owners)))
                              (append owners (list owner)) owners))
                   (external
                    (cl-remove-if (lambda (id) (gethash id local)) stack))
                   (next (or (next-property-change position nil limit)
                             limit)))
              (when stack
                (if seen
                    (unless (equal common external) (setq valid nil))
                  (setq common external seen t)))
              (setq position (max (1+ position) next)))))))
    (and valid seen (or common allow-empty-p))))

(defun ebox-surface--owner-needs-ancestor-paint-p (state owner-id)
  "Return non-nil if STATE's detached OWNER-ID omits enclosing effects.
Ordinary span publication does not recompose enclosing paint or surface
properties.  Its local renderer cannot prove equivalence for such an owner."
  (let ((parents (plist-get state :parent-table))
        (nodes (plist-get state :node-table))
        (node-id owner-id)
        needed)
    (while (and (not needed) (setq node-id (ebox-runtime-index-get node-id parents)))
      (when-let* ((box (ebox-fragment-style-source-node (ebox-runtime-index-get node-id nodes))))
        (setq needed
              (or (ebox-get box :surface-properties)
                  (ebox-surface--region-face-contributions box '(bt bb) t)))))
    (not (null needed))))

(defun ebox-surface--retained-property-value-equal-p (left right)
  "Return non-nil when retaining LEFT instead of RIGHT preserves its value.
Callbacks and records must keep identity.  Native keymap snapshots use
Ebox's property policy, which compares bindings while retaining callback
identity.  Render-created paint origins compare their baselines and paint
source roles."
  (let ((seen (make-hash-table :test #'eq)))
    (cl-labels
        ((same
          (old new)
          (cond
           ((eq old new) t)
           ((and (ebox--paint-origin-p old) (ebox--paint-origin-p new))
            (and (same (ebox--paint-origin-baseline old)
                       (ebox--paint-origin-baseline new))
                 (same (ebox--paint-origin-source-roles old)
                       (ebox--paint-origin-source-roles new))))
           ((and (keymapp old) (keymapp new))
            (funcall (ebox-property-policy-equality
                      (ebox-register-text-property 'keymap))
                     old new))
           ((or (functionp old) (functionp new)
                (keymapp old) (keymapp new)) nil)
           ((memq new (gethash old seen)) t)
           ((and (consp old) (consp new))
            (puthash old (cons new (gethash old seen)) seen)
            (and (same (car old) (car new)) (same (cdr old) (cdr new))))
           ((and (stringp old) (stringp new)
                 (equal-including-properties old new))
            (puthash old (cons new (gethash old seen)) seen)
            (let ((position 0) (length (length old)) (equal-p t))
              (while (and equal-p (< position length))
                (setq equal-p
                      (same (text-properties-at position old)
                            (text-properties-at position new))
                      position
                      (min (next-property-change position old length)
                           (next-property-change position new length))))
              equal-p))
           ((and (numberp old) (numberp new)) (equal old new)))))
      (same left right))))

(defun ebox-surface--unchanged-enclosing-effects-p
    (previous-state state owner-id)
  "Return non-nil when OWNER-ID keeps its enclosing effects in both states.
Compare resolved paint and surface properties, preserving opaque identities."
  (let ((old-id owner-id) (new-id owner-id) (same-p t))
    (while (and same-p old-id new-id)
      (setq old-id (ebox-runtime-index-get old-id (plist-get previous-state :parent-table))
            new-id (ebox-runtime-index-get new-id (plist-get state :parent-table))
            same-p (equal old-id new-id))
      (when (and same-p old-id)
        (let ((old (ebox-fragment-style-source-node
                    (ebox-runtime-index-get old-id (plist-get previous-state :node-table))))
              (new (ebox-fragment-style-source-node
                    (ebox-runtime-index-get new-id (plist-get state :node-table)))))
          (setq same-p
                (and (eq (null old) (null new))
                     (or (null old)
                         (and
                          (eq (ebox-get old :visibility)
                              (ebox-get new :visibility))
                          (ebox-surface--retained-property-value-equal-p
                           (ebox-get old :surface-properties)
                           (ebox-get new :surface-properties))
                          (ebox-surface--retained-property-value-equal-p
                           (ebox-surface--region-face-contributions
                            old '(bt bb) t)
                           (ebox-surface--region-face-contributions
                            new '(bt bb) t)))))))))
    same-p))

(defun ebox-surface--owner-slot-render-node
    (buffer state owner-id snapshot allocated-width variable-content-p
            role-owned-lines-p changed-keys)
  "Return STATE's OWNER-ID rendered in its proven slot, or at natural size."
  (let* ((node (ebox-runtime-index-get owner-id (plist-get state :node-table)))
         (parent-id (ebox-runtime-index-get owner-id (plist-get state :parent-table)))
         (parent (and parent-id (ebox-runtime-index-get parent-id (plist-get state :node-table)))))
    (cond
     ((and role-owned-lines-p parent
           (eq (ebox-tree-display-inner parent) 'flex))
      (when (fboundp 'ebox--flex-item-slot-sized-node)
        (let ((ebox-incremental--buffer-render-state-override (cons buffer state)))
          (ebox--flex-item-slot-sized-node buffer owner-id snapshot changed-keys))))
     ((and node (or role-owned-lines-p
                    (and allocated-width (not variable-content-p))))
      ;; The ancestor certificate proves a stable allocation, but its
      ;; capacity can include chrome outside this owner's published spans.
      ;; Recreate this owner's margin-box extent with the normal box model.
      ;; Exact content patches also need that extent: an auto-width owner
      ;; detached from a padded parent must not expand to the root viewport.
      (when-let* ((width (plist-get
                         (plist-get snapshot :external-footprint-signature)
                         :max-line-pixel-width))
                  ((numberp width)))
        (ebox--flex-copy-node-for-size node 'row width nil nil)))
     ((and node allocated-width variable-content-p)
      (if (eq (plist-get node :ebox-kind) 'text)
          (plist-put (copy-sequence node) :width allocated-width)
        (ebox--flex-copy-node-for-size node 'row allocated-width nil nil)))
     (t node))))

(defun ebox-surface--retained-slot-owner-text
    (buffer previous-state spans old-lines new-lines local old-values new-values)
  "Transport unchanged published properties across proven slot property runs.
Direct content runs may change length.  Only renderer-owned blank fillers may
change their display width.  Every other local property and the order of runs
must match, and a resized run cannot hide an external property boundary.
Return nil on a proof miss.  The caller still validates the final footprint."
  (catch 'slot-property-miss
    (unless (= (length spans) (length old-lines) (length new-lines))
      (throw 'slot-property-miss nil))
    (let ((fragments (ebox-surface--materialized-fragment-ledger previous-state))
          (origin (with-current-buffer buffer (point-min)))
          result)
      (cl-labels
          ((origin-for
            (start end published-properties)
            (while (and fragments (<= (plist-get (car fragments) :end) start))
              (setq fragments (cdr fragments)))
            (let ((remaining fragments) (position start) seen baseline source-roles)
              (while (< position end)
                (let ((fragment (car remaining)))
                  (unless (and fragment
                               (<= (plist-get fragment :start) position)
                               (< position (plist-get fragment :end)))
                    (throw 'slot-property-miss nil))
                  (let ((roles (cl-set-difference
                                (plist-get fragment :paint-role-ids)
                                (plist-get fragment :role-ids) :test #'equal))
                        (value
                         (cond
                          ((plist-get fragment :face-baseline-known-p)
                           (plist-get fragment :face-baseline))
                          ((null (ebox-surface--face-contributions
                                  previous-state (plist-get fragment :paint-role-ids)))
                           (plist-get published-properties 'face))
                          (t (throw 'slot-property-miss nil)))))
                    (when (and seen
                               (or (not (ebox-surface--retained-property-value-equal-p
                                         baseline value))
                                   (not (equal source-roles roles))))
                      (throw 'slot-property-miss nil))
                    (setq baseline value source-roles roles seen t))
                  (setq position (min end (plist-get fragment :end))
                        remaining (cdr remaining))))
              (ebox--paint-origin-create
               :baseline (copy-tree baseline)
               :source-roles (copy-tree source-roles))))
           (pixel-filler-p
            (line start end properties values)
            (let ((display (plist-get properties 'display)))
              (and (= (- end start) 1) (= (aref line start) ?\s)
                   (null (plist-get properties 'ebox-content))
                   (cl-some (lambda (id) (gethash id local))
                            (plist-get properties 'ebox-content-owners))
                   (ebox--render-owned-text-value-p 'display display values)
                   (pcase display
                     (`(space :width (,width)) (and (numberp width) (>= width 0))))))))
        (with-current-buffer buffer
          (cl-loop
           for span in spans for old in old-lines for new in new-lines
           do
           (let* ((published (buffer-substring (car span) (cdr span)))
                  (old-length (length old)) (new-length (length new))
                  (old-position 0) (new-position 0)
                  (line (substring-no-properties new)))
             (unless (equal (substring-no-properties old)
                            (substring-no-properties published))
               (throw 'slot-property-miss nil))
             (while (and (< old-position old-length) (< new-position new-length))
               (let* ((old-end (next-property-change old-position old old-length))
                      (new-end (next-property-change new-position new new-length))
                      (old-props (text-properties-at old-position old))
                      (new-props (text-properties-at new-position new))
                      (published-props (text-properties-at old-position published))
                      (old-display (plist-get old-props 'display))
                      (new-display (plist-get new-props 'display))
                      (display-changed-p
                       (not (ebox-surface--retained-property-value-equal-p
                             old-display new-display))))
                 (unless (= old-end (next-property-change old-position published old-end))
                   (throw 'slot-property-miss nil))
                 (when display-changed-p
                   (unless (and (pixel-filler-p old old-position old-end old-props old-values)
                                (pixel-filler-p new new-position new-end new-props new-values)
                                (ebox-surface--retained-property-value-equal-p
                                 old-display (plist-get published-props 'display)))
                     (throw 'slot-property-miss nil))
                   (setq old-props (copy-sequence old-props)
                         new-props (copy-sequence new-props))
                   (cl-remf old-props 'display)
                   (cl-remf new-props 'display))
                 (unless (and
                          (ebox-surface--retained-property-value-equal-p old-props new-props)
                          (or (equal (substring-no-properties old old-position old-end)
                                     (substring-no-properties new new-position new-end))
                              (and (null old-display) (null new-display)
                                   (gethash (plist-get old-props 'ebox-content) local)
                                   (not (string-match-p "[\n\r]"
                                                        (substring old old-position old-end)))
                                   (not (string-match-p "[\n\r]"
                                                        (substring new new-position new-end))))))
                   (throw 'slot-property-miss nil))
                 (set-text-properties new-position new-end published-props line)
                 (when display-changed-p
                   (put-text-property new-position new-end 'display new-display line))
                 ;; Changed extents rebuild their fragment ledger.  Carry the
                 ;; proven caller baseline to that parser instead of reusing
                 ;; old fragment coordinates or peeling a composed face.
                 (put-text-property
                  new-position new-end ebox--paint-origin-property
                  (origin-for (+ (- (car span) origin) old-position)
                              (+ (- (car span) origin) old-end)
                              published-props)
                  line)
                 (setq old-position old-end new-position new-end)))
             (unless (and (= old-position old-length) (= new-position new-length))
               (throw 'slot-property-miss nil))
             (push line result)))))
      (mapconcat #'identity (nreverse result) "\n"))))

(defun ebox-surface--retain-slot-paint-origins
    (buffer previous-state spans lines)
  "Carry known paint baselines from BUFFER's PREVIOUS-STATE into LINES.
SPANS and LINES already have identical character coordinates.  Preserve only
captured baselines; an unknown baseline remains unknown for later proofs."
  (let ((fragments (ebox-surface--materialized-fragment-ledger previous-state))
        (origin (with-current-buffer buffer (point-min))))
    (cl-loop
     for span in spans for line in lines
     do
     (let ((start (- (car span) origin))
           (end (- (cdr span) origin)))
       (while (and fragments (<= (plist-get (car fragments) :end) start))
         (setq fragments (cdr fragments)))
       (let ((remaining fragments))
         (while (and remaining (< (plist-get (car remaining) :start) end))
           (let ((fragment (pop remaining)))
             (when (plist-get fragment :face-baseline-known-p)
               (put-text-property
                (- (max start (plist-get fragment :start)) start)
                (- (min end (plist-get fragment :end)) start)
                ebox--paint-origin-property
                (ebox--paint-origin-create
                 :baseline (copy-tree (plist-get fragment :face-baseline))
                 :source-roles
                 (copy-tree
                  (cl-set-difference (plist-get fragment :paint-role-ids)
                                     (plist-get fragment :role-ids) :test #'equal)))
                line))))))))
  lines)

(defun ebox-surface--retained-owner-text
    (buffer previous-state state owner-id spans replacement allocated-width
            variable-content-p variable-content-max-width
            &optional role-owned-lines-p changed-keys snapshot)
  "Return REPLACEMENT text with proven unchanged published properties.
Only direct content characters may change.  An isolated old owner render must
match the published text and the new render's complete property topology.
Existing strict geometry validation still applies to the returned string.
Proof mismatches return nil; unexpected rendering errors propagate."
  (let* ((old-node (ebox-runtime-index-get owner-id
                            (plist-get previous-state :node-table)))
         (new-node (ebox-runtime-index-get owner-id (plist-get state :node-table)))
         (regions (ebox--node-all-region-ids old-node))
         (render-node
          (ebox-surface--owner-slot-render-node
           buffer previous-state owner-id snapshot allocated-width
           variable-content-p role-owned-lines-p changed-keys))
         (root (and render-node (ebox-surface--candidate-root render-node t)))
         (probe
          (and root (ebox--render-state-install-index
           (ebox--new-buffer-render-state root)
           (ebox--runtime-index
            root t
            (ebox-tree-source-index
             root t
             (when-let* ((parent-id (ebox-runtime-index-get owner-id (plist-get previous-state
                                                                 :parent-table)))
                         (parent (ebox-runtime-index-get parent-id (plist-get previous-state
                                                               :node-table))))
               (ebox-tree-display-inner parent))
             (plist-get previous-state :source-index) t))))))
    (when (and probe replacement
               (equal regions (ebox--node-all-region-ids new-node))
               (cl-every
                (lambda (region)
                  (let* ((old-id (ebox-runtime-index-get region (plist-get previous-state
                                                            :region-node-table)))
                         (new-id (ebox-runtime-index-get region (plist-get state :region-node-table)))
                         (old (ebox-runtime-index-get old-id (plist-get previous-state :node-table)))
                         (new (ebox-runtime-index-get new-id (plist-get state :node-table))))
                    (and (equal old-id new-id)
                         (if (or role-owned-lines-p variable-content-p)
                             ;; The canonical candidate may replace a
                             ;; source handle while retaining its
                             ;; runtime slot.  These modes rebuild fragment
                             ;; metadata; verify that slot's full identity
                             ;; topology instead of retaining the old handle.
                             (and (eq (plist-get old :ebox-type)
                                      (plist-get new :ebox-type))
                                  (equal (ebox-runtime-index-get old-id (plist-get previous-state :parent-table))
                                         (ebox-runtime-index-get new-id (plist-get state :parent-table)))
                                  (equal (ebox-tree-node-author-key
                                          (plist-get previous-state :source-index) old)
                                         (ebox-tree-node-author-key
                                          (plist-get state :source-index) new)))
                           (ebox-surface--retained-property-value-equal-p
                            (ebox-tree-node-source-identity old)
                            (ebox-tree-node-source-identity new))))))
                regions)
               (cl-every
                (lambda (key)
                  (equal (plist-get previous-state key)
                         (plist-get state key)))
                '(:viewport-width :viewport-height :display-signature)))
      (dolist (key '(:viewport-width :viewport-height :display-signature
				     :runtime-revision))
        (setq probe (plist-put probe key (plist-get previous-state key))))
      (let* ((ebox--box-content-render-cache (make-hash-table :test #'eq))
             (old-rendered (ebox-surface--render-candidate-node probe root))
             (old-rendered
              (if role-owned-lines-p
                  (ebox-buffer--rendered-owned-lines old-rendered regions (length spans))
                old-rendered))
             (old-shaped
              (and old-rendered
                   (ebox-surface--span-patch-lines
                    buffer spans old-rendered variable-content-p
                    variable-content-max-width
                    (and role-owned-lines-p (ebox--region-id-set regions)))))
             (old-lines (and old-shaped (ebox-string-lines old-shaped)))
             (new-lines (ebox-string-lines replacement))
             (local (ebox--region-id-set regions))
             (valid (and old-lines
                         (= (length spans) (length old-lines))
                         (= (length spans) (length new-lines))))
             result)
        (if (or role-owned-lines-p
                ;; Equal geometry need not have equal character counts.
                ;; The existing run transport proves changed content/filler
                ;; runs and preserves every external property boundary.
                (cl-some (lambda (pair)
                           (/= (length (car pair)) (length (cdr pair))))
                         (cl-mapcar #'cons old-lines new-lines)))
            (and valid
                 (ebox-surface--retained-slot-owner-text
                  buffer previous-state spans old-lines new-lines local
                  (plist-get probe :render-owned-text-values)
                  (plist-get state :render-owned-text-values)))
          (with-current-buffer buffer
          (cl-loop for span in spans
                   for old in old-lines for new in new-lines
                   while valid
                   do
                   (let* ((published (buffer-substring (car span) (cdr span)))
                          (length (length old)) (position 0))
                     (setq valid
                           (and (= length (length new) (length published))
                                (equal (substring-no-properties old)
                                       (substring-no-properties published))))
                     (while (and valid (< position length))
                       (let ((end (min (next-property-change position old length)
                                       (next-property-change position new length))))
                         (setq valid
                               (ebox-surface--retained-property-value-equal-p
                                (text-properties-at position old)
                                (text-properties-at position new)))
                         (while (and valid (< position end))
                           (unless (= (aref old position) (aref new position))
                             (setq valid
                                   (and (not (memq (aref old position) '(?\n ?\r)))
                                        (not (memq (aref new position) '(?\n ?\r)))
                                        (not (get-text-property position 'display old))
                                        (gethash (get-text-property position
                                                                    'ebox-content old)
                                                 local))))
                           (setq position (1+ position)))))
                     (when valid
                       (let ((line (substring-no-properties new))
                             (position 0))
                         (while (< position length)
                           (let ((end (next-property-change
                                       position published length)))
                             (set-text-properties
                              position end (text-properties-at position published)
                              line)
                             (setq position end)))
                         (push line result))))))
          (and valid (ebox-lines-join (nreverse result))))))))

(defun ebox-surface--owner-patch-candidate
    (buffer state owner-id allocated-width
            &optional variable-content-p variable-content-max-width
            role-owned-lines-p changed-keys allocation-closure-p
            retain-external-owner-suffix-p previous-state)
  "Return validated patch details for OWNER-ID, or nil."
  (let* (
         (old-snapshot
          (and owner-id (ebox--ensure-layout-snapshot-details buffer owner-id)))
         (spans (and old-snapshot (plist-get old-snapshot :buffer-spans)))
         (node (and owner-id (ebox-runtime-index-get owner-id (plist-get state :node-table))))
         (render-node
          (and owner-id
               (ebox-surface--owner-slot-render-node
                buffer state owner-id old-snapshot allocated-width
                variable-content-p role-owned-lines-p changed-keys)))
         (retain-properties-p
          (and (memq (plist-get state :projection-kind)
                     '(span-patch owner-scoped mixed-owner-reflow))
               (or (ebox-surface--owner-needs-ancestor-paint-p state owner-id)
                   ;; Ancestors also contribute content ownership when
                   ;; they have no paint.  Detached Text/Box output must
                   ;; retain that proven published stack as well.
                   (and previous-state
                        (not (or allocation-closure-p
                                 retain-external-owner-suffix-p))
                        (ebox-runtime-index-get
                         owner-id (plist-get state :parent-table)))))))
    (when (and old-snapshot spans node render-node
               ;; Detached geometry omits enclosing effects.  Mixed paint
               ;; only recomposes dirty paint owners, so unchanged ancestors
               ;; must also survive its geometry replacement.
               (or (not retain-properties-p)
                   (and previous-state
                        (not allocation-closure-p)
                        (ebox-surface--unchanged-enclosing-effects-p
                         previous-state state owner-id))))
      (let* ((rendered
              (prog1
                  (ebox-surface--render-candidate-node state render-node)
                (when (and allocation-closure-p (not (eq render-node node)))
                  (ebox--flex-recache-source-boxes node))))
             (region-ids (plist-get old-snapshot :region-ids))
             (old-allocation-signature
              (and allocation-closure-p
                   (with-current-buffer buffer
                     (ebox-surface--allocation-owner-line-signature
                      (mapcar (lambda (span)
                                (buffer-substring (car span) (cdr span)))
                              spans)
                      region-ids))))
             (new-allocation-signature
              (and allocation-closure-p
                   (ebox-surface--allocation-owner-line-signature
                    (ebox-string-lines rendered) region-ids)))
             (owned-rendered
              (if role-owned-lines-p
                  (ebox-buffer--rendered-owned-lines
                   rendered region-ids
                   (length spans))
                rendered))
             (owned-rendered
              (if allocation-closure-p
                  (and (equal old-allocation-signature
                              new-allocation-signature)
                       owned-rendered)
                owned-rendered))
             (owned-rendered
              (if (or allocation-closure-p
                      retain-external-owner-suffix-p)
                  (and owned-rendered
                       (when-let* ((owners
                                    (ebox-surface--retained-external-owner-suffix
                                    buffer spans region-ids)))
                         ;; The retained-property proof compares detached
                         ;; renders, then restores the complete published
                         ;; owner stack together with every other property.
                         (if retain-properties-p
                             owned-rendered
                           (ebox--add-content-owners owned-rendered owners))))
                owned-rendered))
             (replacement
              (and owned-rendered
                   (ebox-surface--span-patch-lines
                    buffer spans owned-rendered variable-content-p
                    variable-content-max-width
                    (and role-owned-lines-p
                         (ebox--region-id-set
                          (plist-get old-snapshot :region-ids))))))
             (replacement
              (if retain-properties-p
                  (ebox-surface--retained-owner-text
                   buffer previous-state state owner-id spans replacement
                   allocated-width variable-content-p variable-content-max-width
                   role-owned-lines-p changed-keys old-snapshot)
                replacement))
             (details
              (and replacement
                   (ebox-surface--span-patch-details
                    buffer old-snapshot node spans replacement
                    (and (not retain-properties-p) variable-content-p)
                    (and (not retain-properties-p) variable-content-max-width)))))
        (and details
             (list :owner-id owner-id :snapshot old-snapshot
                   :old-spans spans :details details
                   :retained-properties-p
                   (and retain-properties-p (not role-owned-lines-p)
                        ;; Rebuild only changed runs when character extents
                        ;; move.  Old metadata offsets are not reusable even
                        ;; though the published properties were transported.
                        (equal
                         (plist-get (plist-get old-snapshot
                                               :span-footprint-signature)
                                    :char-lengths)
                         (plist-get (plist-get details :footprint)
                                    :char-lengths)))))))))

(defun ebox-surface--layer-enclosing-paint
    (buffer state owner-id spans rendered)
  "Restore enclosing paint from BUFFER and STATE on RENDERED.
OWNER-ID's SPANS delimit the retained slots.
Only ancestor roles and their resolved face contributions are retained.
Every published property run in a slot must agree on those effects, so a
newly exposed child cannot inherit the covered child's paint or interaction.
Return nil when the enclosing effect varies inside a retained slot."
  (catch 'enclosing-paint-miss
    (let ((parents (plist-get state :parent-table))
          (nodes (plist-get state :node-table))
          (parent owner-id)
          (lines (ebox-string-lines rendered))
          (ebox--paint-origin-capture-p t)
          (ebox--render-owned-text-values
           (plist-get state :render-owned-text-values))
          ancestors result)
      (while (setq parent (ebox-runtime-index-get parent parents))
        (when-let* ((box (ebox-fragment-style-source-node
                         (ebox-runtime-index-get parent nodes))))
          (push box ancestors)))
      (setq ancestors (nreverse ancestors))
      (unless (= (length spans) (length lines))
        (throw 'enclosing-paint-miss nil))
      (with-current-buffer buffer
        (cl-loop
         for span in spans for source in lines
         do
         (let* ((published (buffer-substring (car span) (cdr span)))
                (position 0) (limit (length published))
                (line (copy-sequence source))
                seen effects)
           (while (< position limit)
             (let ((roles (ebox-surface--role-ids-at published position))
                   faces properties)
               (dolist (box ancestors)
                 (let* ((region (plist-get box :region-id))
                        (own-roles
                         (cl-loop for (role . id) in roles
                                  when (equal id region) collect role)))
                   (setq faces
                         (append faces
                                 (ebox-surface--region-face-contributions
                                  box own-roles t)))
                   (dolist (role own-roles)
                     (when-let* ((property (alist-get role ebox-region-types)))
                       (setq properties (plist-put properties property region))))))
               (let ((current (cons faces properties)))
                 (when (and seen (not (equal effects current)))
                   (throw 'enclosing-paint-miss nil))
                 (setq effects current seen t)))
             (setq position (next-property-change position published limit)))
           (when (> (length line) 0)
             (add-text-properties 0 (length line) (cdr effects) line)
             (dolist (face (car effects))
               (ebox--add-render-face! line 0 (length line) face t)))
           (push line result))))
      (ebox-lines-join (nreverse result)))))

(defun ebox-surface--range-patch-candidate (buffer state proof)
  "Return PROOF's exact equal-line Range or layer replacement candidate, or nil.
Render STATE's candidate into BUFFER's retained owner allocation."
  (let* ((owner-id (plist-get proof :owner-id))
         (old-snapshot (plist-get proof :snapshot))
         (spans (plist-get old-snapshot :buffer-spans))
         (node (ebox-runtime-index-get owner-id (plist-get state :node-table)))
         (render-node
          (cond
           ((or (plist-get proof :owner-reflow-p)
                (plist-get proof :layer-recompose-p)
                (plist-get proof :nested-scroll-patch-p))
            (ebox-surface--owner-slot-render-node
             buffer state owner-id old-snapshot
             (plist-get proof :allocated-width) nil
             (plist-get proof :owner-reflow-p) (plist-get proof :changed-keys)))
           ((and node (numberp (plist-get proof :allocated-width)))
            (plist-put (copy-sequence node)
                       :width (plist-get proof :allocated-width)))
           (t node)))
         (rendered
          (and render-node
               (ebox-surface--render-candidate-node
                state render-node (plist-get proof :complete-physical-lines-p))))
         (rendered
          (if (and rendered (plist-get proof :nested-scroll-patch-p))
              (ebox-surface--nested-scroll-owned-lines
               buffer spans rendered (plist-get node :region-id))
            rendered))
         (rendered
          (if (and rendered (plist-get proof :owner-reflow-p))
              (ebox-buffer--rendered-owned-lines
               rendered (plist-get old-snapshot :region-ids) (length spans))
            rendered))
         (root-owner-p
          (equal owner-id
                 (plist-get (plist-get state :root-node) :node-id)))
         (external-owners
          (and rendered
               ;; The root owner has no enclosing content owners, so its
               ;; retained suffix is provably empty rather than missing.
               (ebox-surface--retained-external-owner-suffix
                buffer spans (plist-get old-snapshot :region-ids)
                (or (plist-get proof :scroll-content-coordinate-p)
                    root-owner-p))))
         (rendered
          (and external-owners
               (ebox--add-content-owners rendered
                                         (unless (eq external-owners t) external-owners))))
         (rendered
          (if (and rendered (or (plist-get proof :owner-reflow-p)
                                (plist-get proof :layer-recompose-p)
                                (plist-get proof :nested-scroll-patch-p)))
              (ebox-surface--layer-enclosing-paint
               buffer state owner-id spans rendered)
            rendered))
         (replacement
          (and rendered
               (or (ebox-buffer--rendered-in-existing-slots
                    spans rendered nil t)
                   (and (or (plist-get proof :scroll-content-coordinate-p)
                            (plist-get proof :complete-physical-lines-p))
                        (= (length spans) (length (ebox-string-lines rendered)))
                        (cl-every #'ebox--span-whole-line-p spans)
                        rendered))))
         (lines (and replacement (ebox-string-lines replacement)))
         (new-spans
          (and lines (ebox-surface--projected-span-positions spans lines)))
         (new-footprint
          (and new-spans
               (ebox--rendered-span-footprint-signature replacement)))
         (new-external
          (and new-footprint
               (ebox--external-footprint-signature-from-span-footprint
                new-footprint)))
         (new-parent
          (and new-footprint
               (ebox--project-parent-slot-signature
                (plist-get old-snapshot :parent-slot-signature)
                new-footprint)))
         (new-region-ids
          (and node (if (plist-get proof :nested-scroll-patch-p)
                        (plist-get old-snapshot :region-ids)
                      (ebox--node-all-region-ids node))))
         (new-roles
          (and replacement
               (ebox-surface--rendered-role-topology-signature
                replacement new-region-ids)))
         (new-overflow (and node (ebox--overflow-signature node))))
    (when (and owner-id old-snapshot spans node replacement new-spans
               new-footprint new-region-ids new-roles
               (ebox--span-footprint-compatible-p
                (plist-get old-snapshot :span-footprint-signature)
                new-footprint)
               (ebox--external-footprint-compatible-p
                (plist-get old-snapshot :external-footprint-signature)
                new-external)
               (ebox--parent-slot-compatible-p
                (plist-get old-snapshot :parent-slot-signature)
                new-parent)
               (equal (plist-get old-snapshot :overflow-signature)
                      new-overflow))
      (let ((snapshot (copy-sequence old-snapshot)))
        (plist-put snapshot :region-ids new-region-ids)
        (plist-put snapshot :role-topology-signature new-roles)
        (list :owner-id owner-id :snapshot snapshot :old-spans spans
              :range-splice-p t
              :details
              (list :lines lines :spans new-spans :footprint new-footprint
                    :external new-external :parent new-parent :roles new-roles
                    :overflow new-overflow :variable-content-p nil))))))

(defun ebox-surface--composed-owner-patch-candidate (buffer previous-state state proof)
  "Return PROOF's composed host replacement with only newly visible roles.
Render candidate STATE against BUFFER and its PREVIOUS-STATE.
Role topology can change inside the host.  The Range footprint validator
already allows that change while requiring identical external allocation.
Enclosing effects must be unchanged; retained owner roles restore their paint
contributions without copying the previous children's hidden properties."
  (let ((owner-id (plist-get proof :owner-id)))
    (when (and (ebox-surface--unchanged-enclosing-effects-p
                previous-state state owner-id)
               ;; Arbitrary ancestor surface properties need a separate
               ;; provenance proof; retain the existing full-render fallback.
               (let ((parent (ebox-runtime-index-get
                              owner-id (plist-get state :parent-table)))
                     (valid t))
                 (while (and valid parent)
                   (when (ebox-get (ebox-runtime-index-get
                                    parent (plist-get state :node-table))
                                   :surface-properties)
                     (setq valid nil))
                   (setq parent (ebox-runtime-index-get
                                 parent (plist-get state :parent-table))))
                 valid))
      ;; Paint-only preparation normally reuses visible descendant styles.
      ;; Occluded descendants have no visible fragments to refresh, so prepare
      ;; the isolated host's complete style closure before rendering it.
      (when-let* (((not (plist-get proof :owner-reflow-p)))
                  (node (ebox-runtime-index-get
                        owner-id (plist-get state :node-table))))
        (ebox-surface-prepare-inline-candidate-styles
         previous-state state (ebox--runtime-node-ids node))
        (dolist (node-id (ebox--runtime-node-ids node))
          (when-let* ((child (ebox-runtime-index-get
                             node-id (plist-get state :node-table))))
            (remhash child (plist-get state :render-signature-cache)))))
      (ebox-surface--range-patch-candidate buffer state proof))))

(defun ebox-surface--scroll-replace-index-lines (index changes)
  "Copy INDEX and replace only entries on CHANGES' cached content lines.
Each change is (LINE-NUMBER OLD-LINE NEW-LINE).  Line counts are unchanged,
so spans on other lines remain valid even when these strings change length."
  (when index
    (let ((next (copy-hash-table index)))
      (dolist (change changes next)
        (let* ((number (nth 0 change))
               (old (nth 1 change))
               (new (nth 2 change))
               (replacement (ebox--scroll-build-region-line-span-index (list new)))
               (ids (delete-dups
                     (append (ebox--scroll-line-region-ids old)
                             (ebox-surface--hash-keys replacement)))))
          (dolist (id ids)
            (let* ((retained (cl-remove number (copy-sequence (gethash id next))
                                        :key #'car))
                   (local (gethash id replacement))
                   (entries (if local
                                (cons (cons number (cdar local)) retained)
                              retained)))
              (if entries
                  (puthash id (sort entries (lambda (a b) (< (car a) (car b)))) next)
                (remhash id next)))))))))

(defun ebox-surface--scroll-content-patch-output (buffer previous-state state)
  "Validate and stage STATE's scroll content patch and visible projection.
Cached content has no root wrapper chrome and uses its own coordinates.  Its
owner replacement therefore receives the normal span validator independently
of the mounted-buffer replacement.  Only a fully hidden owner can retain the
visible bytes without that second proof.  Every cache mutation is candidate
local; a declined visible proof leaves the committed scroll prefix untouched."
  (let* ((proof (plist-get state :scroll-content-proof))
         (region (plist-get proof :region-id))
         (old-scroll (gethash region (plist-get previous-state :scroll-state-table)))
         (next-scroll (gethash region (plist-get state :scroll-state-table)))
         (lines (plist-get proof :lines))
         (owner-proof (car (plist-get state :owner-scoped-proofs)))
         (owner-id (plist-get owner-proof :owner-id))
         (nested-scroll-p (plist-get owner-proof :nested-scroll-patch-p))
         cached-candidate cached-lines changes output)
    (when (and old-scroll next-scroll
               (eq lines (plist-get old-scroll :content-lines))
               (= (length (plist-get state :owner-scoped-proofs)) 1))
      (with-temp-buffer
        (insert (ebox-lines-join lines))
        (let* ((base (copy-sequence previous-state))
               (candidate (copy-sequence state))
               (ebox--region-line-index (plist-get proof :line-index))
               (ebox--region-line-index-buffer (current-buffer)))
          (plist-put base :surface nil)
          (plist-put base :layout-snapshots
                     (copy-hash-table (plist-get proof :snapshots)))
          (plist-put candidate :layout-snapshots
                     (make-hash-table :test 'equal))
          (let* ((snapshot (copy-sequence
                            (gethash owner-id (plist-get base :layout-snapshots))))
                 (spans (plist-get snapshot :buffer-spans))
                 (owned (mapcar (lambda (span)
                                  (buffer-substring (car span) (cdr span))) spans))
                 fragments)
            ;; This projection is a cache, so it has no Ebox publication mounts.  Derive
            ;; its role and paint evidence from the same owned output runs
            ;; used by ordinary surface publication, in cache coordinates.
            (plist-put snapshot :role-topology-signature
                       (ebox-surface--rendered-role-topology-signature
                        (ebox-lines-join owned) (plist-get snapshot :region-ids)))
            (puthash owner-id snapshot (plist-get base :layout-snapshots))
            (cl-mapc
             (lambda (span line)
               (dolist (fragment (ebox-surface--rendered-fragments line))
                 (plist-put fragment :start (+ (1- (car span)) (plist-get fragment :start)))
                 (plist-put fragment :end (+ (1- (car span)) (plist-get fragment :end)))
                 (push fragment fragments)))
             spans owned)
            (plist-put base :surface-fragments (nreverse fragments)))
          (let ((ebox-incremental--buffer-render-state-override
                 (cons (current-buffer) base))
                (ebox-incremental--candidate-base-state
                 (cons (current-buffer) base)))
            (setq cached-candidate
                  (if nested-scroll-p
                      (ebox-surface--nested-scroll-patch-candidate
                       (current-buffer) base candidate
                       (plist-put (copy-sequence owner-proof) :snapshot
                                  (gethash owner-id (plist-get base :layout-snapshots))))
                    (ebox-surface--owner-patch-candidate
                     (current-buffer) candidate owner-id
                     (plist-get owner-proof :allocated-width)
                     (plist-get owner-proof :variable-content-p)
                     (plist-get owner-proof :variable-content-max-width)
                     (plist-get owner-proof :role-owned-lines-p)
                     (plist-get owner-proof :changed-keys)
                     (plist-get owner-proof :allocation-closure-p)
                     (plist-get owner-proof :retain-external-owner-suffix-p)
                     base)))
            (when cached-candidate
              (setq cached-lines (copy-sequence lines))
              (cl-mapc
               (lambda (span replacement)
                 (goto-char (car span))
                 (let* ((number (1- (line-number-at-pos)))
                        (start (- (car span) (line-beginning-position)))
                        (end (- (cdr span) (line-beginning-position)))
                        (old (nth number lines))
                        (new (concat (substring old 0 start) replacement
                                     (substring old end))))
                   (setcar (nthcdr number cached-lines) new)
                   (push (list number old new) changes)))
               (plist-get cached-candidate :old-spans)
               (plist-get (plist-get cached-candidate :details) :lines))))))
      (when (and cached-lines (= (length cached-lines) (length lines)))
        (let* ((node (ebox-runtime-index-get owner-id
                                             (plist-get previous-state :node-table)))
               (visible (ebox--region-ids-visible-in-buffer-p
                         buffer (ebox--node-all-region-ids node))))
          (when (and nested-scroll-p visible)
            ;; The cache and the mounted window are distinct coordinate spaces.
            ;; A clipped owner must independently prove its mounted allocation.
            (when-let* ((snapshot (ebox--ensure-layout-snapshot-details buffer owner-id)))
              (plist-put state :owner-scoped-proofs
                         (list (let ((mounted (plist-put (copy-sequence owner-proof) :snapshot snapshot)))
                                 (cl-remf mounted :scroll-content-coordinate-p)
                                 mounted)))))
          (setq output
                (if visible
                    (ebox-surface--buffer-span-patch-output buffer previous-state state)
                  (with-current-buffer buffer
                    (buffer-substring (point-min) (point-max)))))
          (when output
            (unless visible
              (plist-put state :content-base-extent (length output))
              ;; A zero-width identity patch carries the unchanged visible
              ;; coordinate proof through the ordinary retained Ebox publication batch.
              (plist-put state :content-coordinate-patches
                         (list (list :old-start 0 :old-end 0 :new-start 0 :new-end 0)))
              (plist-put state :span-patch-fragment-data
                         (ebox-surface--materialized-fragment-ledger previous-state))
              (plist-put state :span-patch-content-p t)
              (plist-put state :span-patch-retained-owned-ranges
                         (plist-get previous-state :surface-owned-ranges)))
            (let* ((private (copy-sequence next-scroll))
                   (rendered (copy-sequence (plist-get next-scroll :rendered-content-lines)))
                   rendered-changes)
              ;; Lazy prefix extension mutates the bounds index in place.
              ;; Keep that future write isolated from the previous generation.
              (when-let* ((bounds (plist-get private :region-line-bounds-index)))
                (let ((copy (copy-hash-table bounds)))
                  (maphash (lambda (id range) (puthash id (cons (car range) (cdr range)) copy))
                           bounds)
                  (plist-put private :region-line-bounds-index copy)))
              (when rendered
                ;; Auto-width scroll chrome can measure its candidate children
                ;; while shaping a cached line.  Those children belong to this
                ;; input generation, even though BUFFER still holds the old one.
                (let ((ebox--render-source-index (plist-get state :source-index)))
                  (dolist (change changes)
                    (let* ((number (car change))
                           (old (nth number rendered))
                           (new (car (ebox--scroll-rendered-content-lines
                                      (plist-get private :box) (list (nth 2 change))
                                      region number))))
                      (setcar (nthcdr number rendered) new)
                      (push (list number old new) rendered-changes)))))
              (plist-put private :content-lines cached-lines)
              (plist-put private :region-line-span-index
                         (ebox-surface--scroll-replace-index-lines
                          (or (plist-get private :region-line-span-index)
                              (ebox--scroll-build-region-line-span-index lines))
                          changes))
              (plist-put private :region-line-span-index-deferred nil)
              (plist-put private :rendered-content-lines rendered)
              (plist-put private :rendered-region-line-span-index
                         (ebox-surface--scroll-replace-index-lines
                          (plist-get private :rendered-region-line-span-index)
                          rendered-changes))
              (if nested-scroll-p
                  ;; A viewport reveals different child roles.  Rebuild the
                  ;; content membership/bounds and retire the old slice index.
                  (progn
                    (plist-put private :content-lines lines)
                    (setq private (ebox--scroll-state-set-lines private cached-lines rendered))
                    (setq private (ebox--scroll-window-rebind-state-producers
                                   private (plist-get private :box)))
                    (cl-remf private :lazy-scroll-prefix-dirty)
                    (cl-remf private :lazy-scroll-window-refresh-required))
                ;; Content-only patches preserve role topology, but their
                ;; character hints must be derived from the replacement text.
                (cl-remf private :region-line-span-hints))
              (puthash region private (plist-get state :scroll-state-table)))
            (cl-remf state :scroll-content-proof))))
      output)))

(defun ebox-surface--complete-line-allocation-p (state proof)
  "Prove PROOF's detached slot preserves STATE's raw containing width.
Published pixels have already been rounded.  Restrict this proof to the root
and its ordinary flow/Column children, with the same containing viewport."
  (let* ((root (plist-get state :root-node))
         (root-id (plist-get root :node-id))
         (owner-id (plist-get proof :owner-id))
         (node (ebox-runtime-index-get owner-id (plist-get state :node-table)))
         (width (plist-get
                 (plist-get (plist-get proof :snapshot) :external-footprint-signature)
                 :max-line-pixel-width))
         (ebox-viewport-width (plist-get state :viewport-width))
         (ebox-viewport-height (plist-get state :viewport-height)))
    (and node (numberp width)
         (memq (ebox-tree-display-inner root) '(flow column))
         (or (equal owner-id root-id)
             (and (equal (ebox-runtime-index-get
                          owner-id (plist-get state :parent-table)) root-id)
                  (eq (ebox-tree-display-outer node) 'block)
                  (memq (ebox-get node :position) '(nil static))))
         (cl-every
          (lambda (box)
            (cl-every (lambda (value)
                        (or (memq value '(nil auto stretch none))
                            (numberp value) (ebox-size-value-p value)))
                      (mapcar (lambda (key) (ebox-get box key))
                              '(:width :min-width :max-width))))
          (list root node))
         (let ((root-width (ebox--wrapper-content-viewport-pixel root)))
           (and (numberp root-width) (numberp ebox-viewport-width)
                (= root-width ebox-viewport-width)
                (let ((raw-width
                       (if (equal owner-id root-id)
                           (+ root-width (ebox--side-pixel root))
                         (ebox--call-with-box-content-context
                          root
                          (lambda ()
                            (when-let* ((content (ebox--wrapper-content-viewport-pixel node)))
                              (+ content (ebox--side-pixel node))))))))
                  (and (numberp raw-width) (= raw-width width))))))))

(defun ebox-surface--span-patch-output
    (buffer previous-state state &optional complete-lines-only-p)
  "Return a proven local patch in BUFFER or its retained scroll content.
COMPLETE-LINES-ONLY-P admits layer composition only at complete physical rows;
detached horizontal owners keep the ordinary fractional-origin fallback."
  (if complete-lines-only-p
      (let ((proofs (plist-get state :owner-scoped-proofs)))
        (when (and proofs
                   (not (plist-get state :scroll-content-proof))
                   (cl-some (lambda (proof) (plist-get proof :layer-recompose-p))
                            proofs)
                   (with-current-buffer buffer
                     (save-restriction
                       (widen)
                       (cl-every
                        (lambda (proof)
                          (let ((spans (plist-get (plist-get proof :snapshot)
                                                 :buffer-spans)))
                            (and spans
                                 (ebox-surface--complete-line-allocation-p state proof)
                                 (not (plist-get proof :scroll-content-coordinate-p))
                                 (not (plist-get proof :nested-scroll-patch-p))
                                 (not (plist-get proof :range-splice-p))
                                 (cl-every #'ebox--span-whole-line-p spans))))
                        proofs))))
          (plist-put state :owner-scoped-proofs
                     (mapcar (lambda (proof)
                               (if (plist-get proof :layer-recompose-p)
                                   (plist-put (copy-sequence proof)
                                              :complete-physical-lines-p t)
                                 proof))
                             proofs))
          (let ((ebox-surface--integral-local-output-required-p t))
            (catch 'ebox/fractional-local-output
              (ebox-surface--buffer-span-patch-output buffer previous-state state)))))
    (if (plist-get state :scroll-content-proof)
        (ebox-surface--scroll-content-patch-output buffer previous-state state)
      (ebox-surface--buffer-span-patch-output buffer previous-state state))))

(defun ebox-surface--raw-owner-patch-output (buffer previous-state state)
  "Patch an allocated owner using retained pre-quantization geometry.
BUFFER stores whole-pixel output. PREVIOUS-STATE retains the exact raw layout
of those same characters, so the owner can be rendered at its original width
and the complete changed rows quantized with their original sibling remainder.
STATE receives only the resulting character patches and final fragment ledger."
  (let ((raw (plist-get previous-state :raw-layout-output))
        (proofs (plist-get state :owner-scoped-proofs)))
    (when (and (stringp raw) proofs
               (null (plist-get previous-state :scroll-region-ids))
               (cl-every (lambda (proof) (plist-get proof :owner-reflow-p)) proofs)
               (with-current-buffer buffer (= (length raw) (buffer-size))))
      (with-temp-buffer
        (insert raw)
        (let* ((base (copy-sequence previous-state))
               (candidate (copy-sequence state))
               (ebox-surface--integral-local-output-required-p nil)
               (ebox--region-line-index (ebox--build-region-line-index))
               (ebox--region-line-index-buffer (current-buffer))
               (ebox-incremental--buffer-render-state-override (cons (current-buffer) base))
               (ebox-incremental--candidate-base-state (cons (current-buffer) base)))
          (plist-put base :surface nil)
          (plist-put base :layout-snapshots
                     (if-let* ((snapshots (plist-get previous-state :raw-layout-snapshots)))
                         (copy-hash-table snapshots)
                       (make-hash-table :test #'equal)))
          (plist-put base :layout-snapshots-complete-p nil)
          (plist-put base :surface-fragments
                     (or (plist-get previous-state :raw-layout-fragments)
                         (ebox-surface--rendered-fragments (copy-sequence raw))))
          (plist-put candidate :layout-snapshots (make-hash-table :test #'equal))
          (plist-put candidate :owner-scoped-proofs
                     (mapcar
                      (lambda (proof)
                        (let* ((copy (copy-sequence proof))
                               (snapshot (ebox--ensure-layout-snapshot-details
                                          (current-buffer) (plist-get proof :owner-id))))
                          (plist-put copy :snapshot snapshot)
                          (plist-put copy :allocated-width
                                     (plist-get (plist-get snapshot :external-footprint-signature)
                                                :max-line-pixel-width))
                          copy)) proofs))
          (when-let* ((output (ebox-surface--buffer-span-patch-output (current-buffer) base candidate)))
            (when (plist-get candidate :fragment-reuse-rejection)
              (plist-put state :fragment-reuse-rejection
                         (plist-get candidate :fragment-reuse-rejection)))
            (let* ((ebox--render-owned-text-values (plist-get candidate :render-owned-text-values))
                   (fragments
                    (or (plist-get candidate :span-patch-fragment-data)
                        (ebox-surface--rendered-fragments output)))
                   (rounded (ebox--quantize-pixel-spaces output)))
              (plist-put state :raw-layout-output output)
              (plist-put state :fractional-pixel-output-p
                         (ebox--fractional-pixel-spaces-p output))
              (plist-put state :raw-layout-fragments fragments)
              (plist-put state :fragment-ownership-changed-p
                         (plist-get candidate :fragment-ownership-changed-p))
              (plist-put state :raw-layout-snapshots (plist-get candidate :layout-snapshots))
              (plist-put state :render-owned-text-values ebox--render-owned-text-values)
              (plist-put state :content-base-extent (length raw))
              (plist-put state :content-coordinate-patches (plist-get candidate :content-coordinate-patches))
              ;; Quantization changes only display widths. Character offsets,
              ;; roles, paint provenance and row dependencies are unchanged.
              (plist-put state :span-patch-fragment-data
                         (mapcar (lambda (fragment)
                                   (let ((copy (copy-sequence fragment)))
                                     (plist-put copy :text rounded)
                                     (plist-put copy :text-source-p t)))
                                 fragments))
              (plist-put state :span-patch-content-p t)
              (plist-put state :retained-allocation-certificates
                         (plist-get candidate :retained-allocation-certificates))
              ;; The local proof used raw widths. Mounted allocation details
              ;; must be recaptured from the accepted whole-pixel output.
              (plist-put state :layout-snapshots (make-hash-table :test #'equal))
              (plist-put state :layout-snapshots-complete-p nil)
              (plist-put state :layout-snapshot-detail-generation
                         (plist-get candidate :layout-snapshot-detail-generation))
              rounded)))))))

(defun ebox-surface--buffer-span-patch-output (buffer previous-state state)
  "Return a proven single- or multi-owner local patch output, or nil."
  (let* ((proofs (plist-get state :owner-scoped-proofs))
         (candidates
          (if proofs
              (mapcar
               (lambda (proof)
                 (cond
                  ((plist-get proof :nested-scroll-patch-p)
                   (ebox-surface--nested-scroll-patch-candidate
                    buffer previous-state state proof))
                  ((or (plist-get proof :layer-recompose-p)
                       (plist-get proof :owner-reflow-p))
                   (ebox-surface--composed-owner-patch-candidate
                    buffer previous-state state proof))
                  ((plist-get proof :range-splice-p)
                     (unless (ebox-surface--owner-needs-ancestor-paint-p
                              state (plist-get proof :owner-id))
                       (ebox-surface--range-patch-candidate buffer state proof)))
                  (t (ebox-surface--owner-patch-candidate
                    buffer state (plist-get proof :owner-id)
                    (plist-get proof :allocated-width)
                    (plist-get proof :variable-content-p)
                    (plist-get proof :variable-content-max-width)
                    (plist-get proof :role-owned-lines-p)
                    (plist-get proof :changed-keys)
                    (plist-get proof :allocation-closure-p)
                    (plist-get proof :retain-external-owner-suffix-p)
                    ;; Every disjoint owner is proved against the same
                    ;; committed coordinates.  Its enclosing properties
                    ;; need that baseline even in a multi-owner patch.
                    previous-state))))
               proofs)
            (list
             (ebox-surface--owner-patch-candidate
              buffer state (plist-get state :span-patch-owner-id)
              (plist-get state :owner-scoped-allocated-width)
              nil nil nil nil nil nil previous-state))))
         (retained-properties-p
          (and candidates
               (cl-every (lambda (candidate)
                           (plist-get candidate :retained-properties-p))
                         candidates)))
         (retained-fragments
          (and retained-properties-p
               (ebox-surface--materialized-fragment-ledger previous-state))))
    (when (and candidates (cl-every #'identity candidates)
               (or (not retained-properties-p) retained-fragments))
      ;; Rebuilding any owner reparses the combined replacements.  Exact
      ;; property copies need their ledger baseline on that path; batches
      ;; that retain the ledger do not put private carriers in output text.
      (unless retained-properties-p
        (dolist (candidate candidates)
          (when (plist-get candidate :retained-properties-p)
            (ebox-surface--retain-slot-paint-origins
             buffer previous-state (plist-get candidate :old-spans)
             (plist-get (plist-get candidate :details) :lines)))))
      (with-current-buffer buffer
        (save-restriction
          (widen)
          (let* ((source (buffer-substring (point-min) (point-max)))
                 (origin (point-min))
                 (coordinate-shift-p
                  (cl-some
                   (lambda (candidate)
                     (let* ((details (plist-get candidate :details))
                            (old-footprint
                             (plist-get (plist-get candidate :snapshot)
                                        :span-footprint-signature))
                            (new-footprint (plist-get details :footprint)))
                       (not (equal (plist-get old-footprint :char-lengths)
                                   (plist-get new-footprint :char-lengths)))))
                   candidates))
                 (shared-generation
                  ;; Glyph-width-only changes keep every buffer coordinate.
                  ;; Any character-count delta, regardless of which proof
                  ;; admitted the owner, shifts later snapshots and therefore
                  ;; advances the global lazy-detail generation.  Restricting
                  ;; this to variable-content proofs left fixed-slot and theme
                  ;; label updates with stale downstream coordinates.
                  (and coordinate-shift-p
                       (1+ (or (plist-get state
                                           :layout-snapshot-detail-generation)
                               0))))
                 (ordered
                  (sort (copy-sequence candidates)
                        (lambda (left right)
                          (< (car (car (plist-get left :old-spans)))
                             (car (car (plist-get right :old-spans)))))))
                 (delta 0)
                 (rebased nil)
                 pairs)
            ;; Candidate details are first computed against the committed
            ;; coordinates.  Once one owner changes length, every later
            ;; owner's new snapshot must be rebased by the accumulated delta;
            ;; installing each proof independently would leave stale spans.
            (dolist (candidate ordered)
              (let* ((details (plist-get candidate :details))
                     (old-spans (plist-get candidate :old-spans))
                     (new-spans
                      (mapcar (lambda (span)
                                (cons (+ (car span) delta)
                                      (+ (cdr span) delta)))
                              (plist-get details :spans)))
                     (updated (copy-sequence details))
                     (line-delta
                      (cl-loop for old-span in old-spans
                               for line in (plist-get details :lines)
                               sum (- (length line)
                                      (- (cdr old-span) (car old-span))))))
                (plist-put updated :spans new-spans)
                (push (cons candidate updated) rebased)
                (setq delta (+ delta line-delta))))
            (dolist (candidate candidates)
              (cl-mapc
               (lambda (span line) (push (cons span line) pairs))
               (plist-get candidate :old-spans)
               (plist-get (plist-get candidate :details) :lines)))
            (setq pairs
                  (sort pairs
                        (lambda (left right)
                          (< (car (car left)) (car (car right))))))
            ;; A layer owner is rendered as a complete set of rows so that
            ;; occlusion can be proven correctly.  Publishing that candidate
            ;; need only touch rows whose bytes or properties actually
            ;; changed; unchanged rows remain mounted in place and therefore
            ;; do not participate in the Ebox publication edit or fragment rebuild.
            (setq pairs (ebox-surface--changed-span-pairs source origin pairs))
            ;; The paint-origin ledger restores hidden provenance on retained
            ;; rows before this point.  Rows that are then byte-and-property
            ;; identical need no buffer splice or fragment reconstruction;
            ;; keep their old carriers in place for a future expose operation.
            (when-let* ((output
                        (if pairs
                            (ebox-surface--replace-buffer-spans
                             source origin (mapcar #'car pairs)
                             (mapcar #'cdr pairs))
                          source)))
              (plist-put state :content-base-extent (length source))
              (plist-put
               state :content-coordinate-patches
               (let ((coordinate-delta 0)
                     patches)
                 ;; PAIRS are the actual source replacements consumed by
                 ;; `ebox-surface--replace-buffer-spans'.  Snapshot spans
                 ;; describe semantic ownership inside those replacement
                 ;; strings and may begin after wrapper padding; using them as
                 ;; edit coordinates creates artificial gaps and an invalid
                 ;; old-to-new mapping when several owners are composed.
                 (dolist (pair pairs (nreverse patches))
                   (let* ((old-span (car pair))
                          (replacement (cdr pair))
                          (old-start (- (car old-span) origin))
                          (old-end (- (cdr old-span) origin))
                          (new-start (+ old-start coordinate-delta))
                          (new-end (+ new-start (length replacement))))
                     (push (list :old-start old-start :old-end old-end
                                 :new-start new-start :new-end new-end)
                           patches)
                     (setq coordinate-delta
                           (+ coordinate-delta
                              (- (length replacement)
                                 (- old-end old-start))))))))
              (dolist (candidate candidates)
                (ebox-surface--install-span-patch-snapshot
                 state (plist-get candidate :owner-id)
                 (plist-get candidate :snapshot)
                 (cdr (assq candidate rebased))
                 shared-generation))
              (when-let* ((old-fragments
                           (or retained-fragments
                               (ebox-surface--materialized-fragment-ledger
                                previous-state)))
                          (fragments
                           (if (null pairs)
                               ;; No visible row changed.  Keep the exact
                               ;; fragment ledger object and avoid scanning or
                               ;; rebasing any text properties.
                               old-fragments
                             (if retained-properties-p
                               (if (and (not coordinate-shift-p)
                                        (eq old-fragments
                                            (plist-get previous-state
                                                       :surface-fragments)))
                                   ;; The published ledger already contains
                                   ;; immutable offsets.  Equal-coordinate
                                   ;; property transport preserves every run,
                                   ;; so retain it without copying the page.
                                   old-fragments
                                 (ebox-surface--fragment-metadata old-fragments))
                             (ebox-surface--incremental-patched-fragments
                              output old-fragments
                              (plist-get state :content-coordinate-patches)
                              state)))))
                (plist-put state :span-patch-fragment-data fragments)
                (plist-put state :span-patch-content-p t)
                (when (and retained-properties-p (not coordinate-shift-p))
                  (plist-put state :span-patch-retained-owned-ranges
                             (plist-get previous-state :surface-owned-ranges))))
              ;; Paint origins are an internal provenance carrier used only
              ;; while rebuilding fragment baselines.  The equal-coordinate
              ;; retained-ledger path above intentionally skips fragment
              ;; reparsing, so it also skips the parser's normal carrier
              ;; cleanup.  Letting this property escape into the Ebox publication batch
              ;; makes every origin boundary look like a real content
              ;; property change even when face/display semantics are equal.
              ;; The fragment ledger already retained the baseline facts, so
              ;; remove the carrier before the candidate crosses the Surface
              ;; boundary.
              (ebox--strip-paint-origins! output)
              output)))))))

(defun ebox-surface--formatting-context-reflow-lines
    (start rendered)
  "Return absolute whole-line spans for RENDERED beginning at START."
  (let ((offset start)
        spans)
    (dolist (line (ebox-string-lines rendered)
                  (nreverse spans))
      (let ((end (+ offset (length line))))
        (push (cons offset end) spans)
        (setq offset (1+ end))))))

(defun ebox-surface--formatting-context-reflow-output (buffer state)
  "Return full BUFFER text with one variable-line context replaced, or nil.
The proof owns a complete block of whole lines.  Only that block is rendered
again; the surrounding buffer and retained node/object identities remain
untouched."
  (let* ((proof (or (plist-get state :formatting-context-reflow-proof)
                    (plist-get (plist-get state :mixed-owner-proof)
                               :geometry-proof)))
         (owner-id (and proof (plist-get proof :owner-id)))
         (snapshot (and proof (plist-get proof :snapshot)))
         (old-spans (and proof (plist-get proof :old-spans)))
         (node (and owner-id
                    (ebox-runtime-index-get owner-id (plist-get state :node-table))))
         (allocated-width (and proof
                               (plist-get proof :allocated-width))))
    (when (and proof snapshot old-spans node
               (ebox--spans-contiguous-lines-p old-spans)
               (with-current-buffer buffer
                 (ebox--line-spans-cover-whole-lines-p old-spans)))
      (let* ((rendered (ebox-surface--render-candidate-node state node))
             (parent-table (plist-get state :parent-table))
             (ancestor-owner-ids
              (let ((walk (and parent-table
                               (ebox-runtime-index-get owner-id parent-table)))
                    owners)
                (while walk
                  (when-let* ((ancestor
                               (ebox-runtime-index-get walk (plist-get state :node-table)))
                              (region-id
                               (ebox-surface--node-editable-region-id
                                ancestor)))
                    (setq owners (append owners (list region-id))))
                  (setq walk (ebox-runtime-index-get walk parent-table)))
                owners))
             (rendered
              (ebox--maplines
               (lambda (line)
                 (ebox--add-content-owners line ancestor-owner-ids))
               rendered))
             (new-footprint
              (ebox--rendered-span-footprint-signature rendered))
             (new-max (plist-get (ebox--external-footprint-signature-from-span-footprint
                                 new-footprint)
                                :max-line-pixel-width))
             (new-roles
              (ebox-surface--rendered-role-topology-signature
               rendered (plist-get snapshot :region-ids)))
             (old-roles (plist-get snapshot :role-topology-signature))
             (new-overflow (ebox--overflow-signature node))
             (old-block-span (plist-get proof :old-block-span))
             (block-start
              (and old-block-span
                   (max 0
                        (1- (car old-block-span)))))
             ;; Mount positions are buffer positions (one-based, exclusive
             ;; end); the output string is zero-based, so both boundaries
             ;; need the same conversion before splicing.
             (block-end
              (and old-block-span
                   (1- (cdr old-block-span))))
             (old-block-text
              (and (integerp block-start)
                   (integerp block-end)
                   (with-current-buffer buffer
                     (buffer-substring (1+ block-start)
                                       (1+ block-end)))))
             ;; The material context sits between two column line breaks.
             ;; They belong to the context's retained scope even though the
             ;; local node renderer quite correctly emits only its content.
             (leading-newline-p
              (and old-block-text
                   (> (length old-block-text) 0)
                   (= (aref old-block-text 0) ?\n)))
             (trailing-newline-p
              (and old-block-text
                   (> (length old-block-text) 0)
                   (= (aref old-block-text (1- (length old-block-text)))
                      ?\n)))
             (context-rendered
              (concat (if leading-newline-p
                          "\n"
                        "")
                      rendered
                      (if trailing-newline-p
                          "\n"
                        "")))
             (content-start (+ block-start (if leading-newline-p 1 0)))
             (new-spans
              (ebox-surface--formatting-context-reflow-lines
               content-start rendered)))
        (when (and (integerp block-start)
                   (integerp block-end)
                   (> block-end block-start)
                   (> (length context-rendered) 0)
                   new-spans
                   (or (null allocated-width)
                       (null new-max)
                       (<= new-max allocated-width))
                   (equal old-roles new-roles)
                   (equal (plist-get snapshot :overflow-signature)
                          new-overflow))
          (with-current-buffer buffer
            (save-restriction
              (widen)
                     (let* ((source (buffer-substring (point-min) (point-max)))
                     (output
                      (concat (substring source 0 block-start)
                              context-rendered
                              (substring source block-end)))
                     (generation
                      (1+ (or (plist-get state
                                         :layout-snapshot-detail-generation)
                              0)))
                     (updated (copy-sequence snapshot))
                     (new-external
                      (ebox--external-footprint-signature-from-span-footprint
                       new-footprint)))
                (dolist (entry `((:buffer-span . ,(car new-spans))
                                 (:buffer-spans . ,new-spans)
                                 (:line-signature
                                  . ,(plist-get new-footprint
                                                :line-pixel-widths))
                                 (:span-footprint-signature . ,new-footprint)
                                 (:external-footprint-signature
                                  . ,new-external)
                                 (:role-topology-signature . ,new-roles)
                                 (:overflow-signature . ,new-overflow)
                                 (:detail-generation . ,generation)))
                  (setq updated
                        (plist-put updated (car entry) (cdr entry))))
                (puthash owner-id updated (plist-get state :layout-snapshots))
                (plist-put state :layout-snapshot-detail-generation generation)
                (plist-put state :layout-snapshots-complete-p nil)
                (plist-put state :formatting-context-reflow-new-spans new-spans)
                (plist-put state :formatting-context-reflow-new-length
                           (length context-rendered))
                (plist-put
                 state :content-coordinate-patches
                 (list (list :old-start block-start :old-end block-end
                             :new-start block-start
                             :new-end (+ block-start
                                         (length context-rendered)))))
                output))))))))

(defvar ebox-surface--paint-node-depth-cache nil
  "Dynamically bound node-id depth cache for one mixed paint projection.")

(defvar ebox-surface--paint-node-chain-cache nil
  "Dynamically bound role-chain cache for one mixed paint projection.")

(defconst ebox-surface--paint-node-depth-missing
  (make-symbol "ebox-paint-node-depth-missing")
  "Sentinel distinguishing an uncached paint node depth.")

(defconst ebox-surface--paint-node-chain-missing
  (make-symbol "ebox-paint-node-chain-missing")
  "Sentinel distinguishing an uncached paint node chain.")

(defun ebox-surface--repaint-output-fragment!
    (output fragment old-state new-state old-face-cache new-face-cache
            old-node-face-cache new-node-face-cache)
  "Recompose FRAGMENT's face directly in mutable OUTPUT and return metadata.
FRAGMENT retains absolute offsets into OUTPUT.  Avoiding one substring, one
fragment-local copy, and a final full concat per run keeps mixed projection
work proportional to semantic face composition instead of allocation churn."
  (let* ((start (plist-get fragment :start))
         (end (plist-get fragment :end))
         (old-roles (plist-get fragment :old-paint-role-ids))
         (new-roles (plist-get fragment :paint-role-ids))
         (old-faces
          (ebox-surface--cached-face-contributions
           old-face-cache old-state old-roles old-node-face-cache))
         (new-faces
          (ebox-surface--cached-face-contributions
           new-face-cache new-state new-roles new-node-face-cache))
         (baseline
          (and (< start end)
               (if (plist-get fragment :face-baseline-known-p)
                   (copy-tree (plist-get fragment :face-baseline))
                 (ebox-surface--face-baseline
                  (get-text-property start 'face output) old-faces))))
         (unchanged (and (equal old-roles new-roles)
                         (equal old-faces new-faces)))
         (face (and (not unchanged)
                    (ebox-surface--compose-face baseline new-faces))))
    (when (and (not unchanged) (< start end))
      (if face
          (put-text-property start end 'face face output)
        (remove-text-properties start end '(face nil) output)))
    (ebox-interaction--refresh-hover! output start end nil new-state)
    (cl-remf fragment :text)
    (plist-put fragment :text-source-p t)
    (cl-remf fragment :old-paint-role-ids)
    fragment))

(defun ebox-surface--mixed-owner-output (buffer previous-state state)
  "Return one geometry-plus-paint candidate output, or nil on proof miss.
The geometry context is rendered by the existing whole-line proof.  Paint
owners are then recomposed from the committed semantic fragment ledger, never
by peeling an already-composed face suffix.  Any missing address/baseline
causes the caller to use the ordinary full projection."
  (let* ((proof (plist-get state :mixed-owner-proof))
         ;; Range splices may change the Ebox publication object set, so the retained
         ;; content result cannot carry their paint layers.  Preserve the
         ;; ordinary renderer before producing a cleaned paint baseline.
         (geometry-proof (and proof
                              (not (ebox-surface--mixed-range-splice-p state))
                              (plist-get proof :geometry-proof)))
         (geometry-kind (and proof (plist-get proof :geometry-kind)))
         (paint-owner-ids (and proof (plist-get proof :paint-owner-ids)))
         (output
          (when geometry-proof
            (if (eq geometry-kind 'span-patch)
                (ebox-surface--span-patch-output
                 buffer previous-state state)
              (plist-put state :render-cache (make-hash-table :test 'equal))
              (plist-put state :render-signature-cache
                         (make-hash-table :test 'eq))
              (let ((ebox--box-content-render-cache
                     (make-hash-table :test 'eq)))
                 (ebox-surface--formatting-context-reflow-output
                 buffer state)))))
         (old-fragments
          (ebox-surface--materialized-fragment-ledger previous-state))
         (old-by-address (make-hash-table :test #'equal))
         (old-by-local-address (make-hash-table :test #'equal))
         (ebox-surface--paint-node-depth-cache
          (make-hash-table :test #'eql))
         (ebox-surface--paint-node-chain-cache
          (make-hash-table :test #'equal)))
    (when (and output old-fragments paint-owner-ids)
      (dolist (fragment old-fragments)
        (when-let* ((address (plist-get fragment :paint-address)))
          (puthash address fragment old-by-address)
          (let* ((roles (plist-get fragment :paint-role-ids))
                 (owner (cdr (assq 'content roles)))
                 (key (and owner
                           (list owner
                                 (plist-get address :content-index)
                                 (plist-get address :ordinal)))))
            (when key
              (puthash key
                       (cons fragment (gethash key old-by-local-address))
                       old-by-local-address)))))
      (let ((new-fragments
             (or (and (eq geometry-kind 'span-patch)
                      (plist-get state :span-patch-fragment-data))
                 (ebox-surface--rendered-fragments output))))
        (catch 'mixed-owner-proof-miss
          (let (pieces)
            (dolist (fragment new-fragments)
              (let* (;; Fragment metadata is immutable below its plist spine;
                     ;; repaint replaces every mutable field it owns.
                     (copy (copy-sequence fragment))
                     (address (plist-get fragment :paint-address))
                     (roles (plist-get fragment :paint-role-ids))
                     (owner (cdr (assq 'content roles)))
                     (local-key
                      (and owner
                           (list owner
                                 (plist-get address :content-index)
                                 (plist-get address :ordinal))))
                     (matches (and local-key
                                   (gethash local-key old-by-local-address)))
                     (old-fragment
                      (or (and address (gethash address old-by-address))
                          (and (= (length matches) 1) (car matches))))
                     (old-roles (and old-fragment
                                     (plist-get old-fragment
                                                :paint-role-ids)))
                     (paint-chain
                      (if (and old-fragment (equal old-roles roles)
                               (plist-get old-fragment :paint-node-chain))
                          (copy-sequence
                           (plist-get old-fragment :paint-node-chain))
                        (ebox-surface--paint-node-chain state roles)))
                     (direct-affected-p
                      (cl-some (lambda (entry)
                                 (memq (cdr entry) paint-owner-ids))
                               roles))
                     (affected-p
                      (cl-some (lambda (node-id)
                                 (memq node-id paint-owner-ids))
                               paint-chain))
                     (paint-change-p
                      (and affected-p
                           (not
                            (equal
                             (and old-fragment
                                  (ebox-surface--face-contributions
                                   previous-state old-roles))
                             (ebox-surface--face-contributions
                              state roles))))))
                (plist-put copy :paint-node-chain paint-chain)
                (if (not affected-p)
                    (progn
                      (cl-remf copy :text)
                      (setq copy (plist-put copy :text-source-p t))
                      (push copy pieces))
                  (when (plist-get old-fragment :face-baseline-known-p)
                    (plist-put copy :face-baseline
                               (copy-tree
                                (plist-get old-fragment :face-baseline)))
                    (plist-put copy :face-baseline-known-p t))
                  ;; When Range identity changes prevent an old-address match,
                  ;; OUTPUT still contains the freshly rendered candidate
                  ;; face.  Remove the candidate's own new contributions to
                  ;; recover the semantic baseline exactly; subsequent paint
                  ;; composition can then proceed without guessing from an
                  ;; unrelated old fragment.
                  (when (and (< (plist-get copy :start)
                                (plist-get copy :end))
                             (not (plist-get copy
                                             :face-baseline-known-p)))
                    (plist-put
                     copy :face-baseline
                     (ebox-surface--face-baseline
                      (get-text-property (plist-get copy :start)
                                         'face output)
                      (ebox-surface--face-contributions state roles)))
                    (plist-put copy :face-baseline-known-p t))
                  (when (and direct-affected-p paint-change-p
                             (< (plist-get copy :start)
                                (plist-get copy :end))
                             (not (plist-get copy
                                             :face-baseline-known-p)))
                    (throw 'mixed-owner-proof-miss nil))
                  (plist-put copy :old-paint-role-ids
                             (copy-tree (or old-roles roles)))
                  (push copy pieces))))
            (let ((fragments (nreverse pieces)))
              (setq fragments
                    (ebox-surface--layer-paint-contributions
                     output fragments state))
              (plist-put state :mixed-owner-fragment-data fragments)
              (plist-put state :mixed-owner-content-p t)
              (apply #'concat
                     (mapcar (lambda (fragment) (plist-get fragment :text))
                             fragments)))))))))

(defun ebox-surface--nested-scroll-owned-lines (buffer spans rendered region)
  "Select RENDERED's exact chrome-aligned rows owned by BUFFER SPANS and REGION.
Row composition may retain an upper border in its owner spans while Column
composition leaves both border rows outside.  Match explicit vertical roles
instead of choosing which edge to trim from a numeric line-count difference."
  (let ((lines (ebox-string-lines rendered)) signatures matches)
    (cl-labels
        ((signature (text)
           (cl-loop for role in '(mt bt pt pb bb mb)
                    for property = (alist-get role ebox-region-types)
                    when (text-property-any 0 (length text) property region text)
                    collect role)))
      (with-current-buffer buffer
        (setq signatures
              (mapcar (lambda (span)
                        (signature (buffer-substring (car span) (cdr span))))
                      spans)))
      (let ((rendered-signatures (mapcar #'signature lines))
            (count (length spans)))
        (cl-loop for start from 0 to (- (length lines) count)
                 when (equal signatures (cl-subseq rendered-signatures start (+ start count)))
                 do (push start matches))
        (when (= (length matches) 1)
          (ebox-lines-join (cl-subseq lines (car matches) (+ (car matches) count))))))))

(defun ebox-surface--nested-scroll-patch-candidate (buffer previous-state state proof)
  "Return PROOF's cached nested scroll replacement without rendering siblings.
BUFFER and PREVIOUS-STATE supply the committed physical slots.  STATE owns an
isolated scroll Box.  Cached content is reshaped only through its wrapper;
changing child roles must satisfy the same exact external footprint proof as
a local composed host."
  (let* ((region (plist-get state :scroll-patch-region-id))
         (table (plist-get state :scroll-state-table))
         (scroll (gethash region table))
         (box (plist-get scroll :box))
         (owner (plist-get proof :owner-id))
         (parent (ebox-runtime-index-get owner (plist-get state :parent-table)))
         (valid t))
    (while (and valid parent)
      (when (ebox-get (ebox-runtime-index-get parent (plist-get state :node-table))
                      :surface-properties)
        (setq valid nil))
      (setq parent (ebox-runtime-index-get parent (plist-get state :parent-table))))
    (when (and valid box
               (ebox--surface-nested-scroll-cached-p scroll 0)
               (ebox-surface--unchanged-enclosing-effects-p previous-state state owner))
      (let ((ebox--scroll-window-cached-state scroll)
            (ebox--scroll-window-skip-state-rebuild-p
             (not (plist-get proof :scroll-content-coordinate-p))))
        (prog1 (ebox-surface--range-patch-candidate buffer state proof)
          ;; Slot sizing renders a temporary copy.  Future prefix producers
          ;; and imperative updates must keep the canonical candidate Box.
          (puthash region box (plist-get state :region-box-table))
          (puthash region scroll table))))))

(defun ebox-surface--nested-scroll-full-overrides (buffer root state-overrides)
  "Return private ROOT and overrides after a nested scroll slot proof misses.
BUFFER's candidate scroll caches rebind to the copied tree before any full
renderer may mutate geometry.  Published siblings stay untouched on rollback."
  (let* ((copy (ebox-tree-copy-node-structure root))
         (overrides (copy-sequence state-overrides))
         (index (ebox--runtime-index copy t (plist-get overrides :source-index)))
         (ebox--scroll-global-state (plist-get overrides :scroll-state-table))
         (table (ebox-incremental--candidate-scroll-state-table
                 buffer overrides index (plist-get index :region-box-table))))
    (setq overrides (ebox--render-state-install-index overrides index))
    (plist-put overrides :scroll-state-table table)
    (plist-put overrides :runtime-index-prepared-p t)
    (plist-put overrides :source-path-copied-p nil)
    (cl-remf overrides :nested-scroll-patch-proof)
    (list copy overrides)))

(defun ebox-surface--scroll-patch-output (_buffer state &optional complete-lines-only-p)
  "Return a staged visible scroll window without rerunning layout when safe.
Chrome-free top-aligned root scroll boxes already store fully propertized
rendered lines.  Join only the visible slice and add the scroll marker; any
box with wrapper chrome falls back to the retained wrapper renderer.
When COMPLETE-LINES-ONLY-P is non-nil, return only proven complete cached
physical lines or a complete cached root wrapper, with private pixel-normalized
copies where needed.  Detached owners keep their fractional-origin guard."
  (let* ((region-id (plist-get state :scroll-patch-region-id))
         (scroll-table (plist-get state :scroll-state-table))
         (scroll-state (and region-id scroll-table
                            (gethash region-id scroll-table)))
         (root (plist-get state :root-node))
         (root-id (and root (plist-get root :node-id)))
         (owner-id (plist-get state :span-patch-owner-id))
         (cached-box (and scroll-state (plist-get scroll-state :box))))
    (when (and scroll-state root owner-id root-id
               (= owner-id root-id)
               cached-box
               (equal (plist-get cached-box :node-id) root-id))
      (let* ((chrome-free-p
             (and (= (or (ebox-get cached-box :padding-left-pixel) 0) 0)
                  (= (or (ebox-get cached-box :padding-right-pixel) 0) 0)
                  (= (or (ebox-get cached-box :padding-top-height) 0) 0)
                  (= (or (ebox-get cached-box :padding-bottom-height) 0) 0)
                  (= (or (ebox-get cached-box :margin-left-pixel) 0) 0)
                  (= (or (ebox-get cached-box :margin-right-pixel) 0) 0)
                  (= (or (ebox-get cached-box :margin-top-height) 0) 0)
                  (= (or (ebox-get cached-box :margin-bottom-height) 0) 0)
                  (= (or (ebox-get cached-box :border-left-pixel) 0) 0)
                  (= (or (ebox-get cached-box :border-right-pixel) 0) 0)
                  (= (or (ebox-get cached-box :border-top-pixel) 0) 0)
                  (= (or (ebox-get cached-box :border-bottom-pixel) 0) 0)
                  (eq (ebox-get cached-box :vertical-align) 'top)
                  (null (ebox-get cached-box :surface-properties))))
            (visible
             (and chrome-free-p
                  (ebox--scroll-state-retained-window-ready-p
                   scroll-state))))
        (if (and visible (cadr visible))
            (let* ((lines (cadr visible))
                   (output (ebox-lines-join lines)))
              (unless complete-lines-only-p
                (ebox-surface--check-local-pixel-output output))
              (when (ebox--fractional-pixel-spaces-p output)
                ;; The root and chrome proof above establishes the physical
                ;; line origin.  Normalize only these visible line handles;
                ;; their raw cache and integral template keys stay unchanged.
                (let ((ebox--render-owned-text-values
                       (or (plist-get state :render-owned-text-values)
                           (make-hash-table :test #'eq))))
                  (setq lines (mapcar #'ebox--quantize-pixel-spaces lines)
                        output (ebox-lines-join lines))
                  (plist-put state :render-owned-text-values
                             ebox--render-owned-text-values)
                  (ebox--record-render-output-provenance output))
                ;; A later integer-only window cannot disprove fractions in
                ;; other retained rows, so scrolling only adds this raw fact.
                (plist-put state :fractional-pixel-output-p t))
              (when (and (ebox-surface--scroll-lines-owned-p lines)
                         (plist-get state :retained-scroll-content-p))
                ;; Retain immutable line handles and stream their cached role
                ;; runs directly into ownership planning.  Materializing one
                ;; fragment plist per visible property run on every wheel
                ;; event made scroll allocation O(all visible fragments).
                (plist-put state :scroll-patch-lines lines))
              (when (> (length output) 0)
                (add-text-properties
                 0 (length output)
                 (list 'ebox-scroll-window region-id)
                 output))
              output)
          (let ((root-wrapper-p
                 (and (or (plist-get state :layered-p) (not chrome-free-p))
                      (ebox-layer-cached-root-scroll-p root scroll-state))))
            ;; Ordinary chrome-free roots first rebuild physical row metadata
            ;; after content-only materialization.  Retaining that raw cache
            ;; here would prevent later scrolls from using direct row slices.
            (when (or root-wrapper-p (not complete-lines-only-p))
              (let* ((ebox--scroll-window-cached-state scroll-state)
                     (ebox--scroll-window-skip-state-rebuild-p
                      (or (plist-get scroll-state :content-lines-complete-p)
                          root-wrapper-p))
                     ;; This wrapper owns the entire physical line origin.
                     (ebox-surface--integral-local-output-required-p
                      (and (not root-wrapper-p)
                           ebox-surface--integral-local-output-required-p))
                     (output (ebox-surface--render-candidate-node state root)))
                (when root-wrapper-p
                  (plist-put state :fractional-pixel-output-p
                             (ebox--fractional-pixel-spaces-p output))
                  (when (plist-get state :fractional-pixel-output-p)
                    (let ((ebox--render-owned-text-values
                           (plist-get state :render-owned-text-values)))
                      (setq output (ebox--quantize-pixel-spaces output))
                      (ebox--record-render-output-provenance output))))
                output))))))))

(defun ebox-surface--native-scroll-full-output (state)
  "Return the complete propertized root scroll output for native scrolling."
  (let* ((region-id (plist-get state :scroll-patch-region-id))
         (table (plist-get state :scroll-state-table))
         (scroll-state (and region-id table (gethash region-id table)))
         (lines (and scroll-state
                     (plist-get scroll-state :rendered-content-lines))))
    (when (and lines
               (plist-get scroll-state :content-lines-complete-p))
      (let ((output (ebox-lines-join lines)))
        (when (> (length output) 0)
          (add-text-properties
           0 (length output) (list 'ebox-scroll-window region-id) output))
        output))))

(defun ebox-surface--prepare-scroll-viewport (buffer previous-state state)
  "Stage STATE's exact rich viewport without document or surface planning.
PREVIOUS-STATE remains the published generation in BUFFER.  Existing root
wrapper and nested allocation proofs select the output; a proof miss returns
nil before any Ebox publication publication.  The resulting ordinary Ebox
publication batch contains only the proved replacement coordinates,
including an enclosing cache's separate content-coordinate update when
present."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (let* ((nested (plist-get state :nested-scroll-patch-proof))
             (output
              (if nested
                  (when (and (not (plist-get previous-state :fractional-pixel-output-p))
                             (or (not (plist-get nested :scroll-content-region-id))
                                 (plist-get state :scroll-content-proof)))
                    (unless (plist-get state :owner-scoped-proofs)
                      (plist-put state :owner-scoped-proofs (list nested)))
                    (let ((ebox-surface--integral-local-output-required-p t))
                      (catch 'ebox/fractional-local-output
                        (ebox-surface--span-patch-output buffer previous-state state))))
                (ebox-surface--scroll-patch-output buffer state t))))
        (when (and (stringp output)
                   (not (plist-get state :paint-property-contributions)))
          (unless (plist-get state :scroll-patch-lines)
            (plist-put state :scroll-viewport-fragments
                       (or (plist-get state :span-patch-fragment-data)
                           (ebox-surface--rendered-fragments output))))
          (ebox--strip-paint-origins! output)
          (let* ((base-extent (- (point-max) (point-min)))
                 (target-extent (length output))
                 (coordinates
                  (or (plist-get state :content-coordinate-patches)
                      (list (list :old-start 0 :old-end base-extent
                                  :new-start 0 :new-end target-extent))))
                 (patches
                  (mapcar
                   (lambda (patch)
                     (append patch
                             (list :replacement
                                   (substring output (plist-get patch :new-start)
                                              (plist-get patch :new-end)))))
                   coordinates))
                 (batch
                  (condition-case nil
                      (ebox--pub-commit-batch-create
                       :base-revision (plist-get state :runtime-revision)
                       :target-revision (1+ (plist-get state :runtime-revision))
                       :base-extent base-extent :target-extent target-extent
                       :patches patches :coordinate-patches coordinates)
                    (ebox--pub-surface-error nil))))
            (when batch
              (plist-put state :scroll-viewport-batch batch)
              output)))))))

(defun ebox-surface--ownership-cache (previous-state state)
  "Return a private owner-resolution cache for STATE's unchanged topology.
PREVIOUS-STATE is supplied only by a projection retaining the node topology.
Reuse also requires its exact publication object indexes. Source parent and
region indexes may be copied while retaining the same proved relationships.
Only entries read by this candidate survive, bounding the derived cache to
the current output without modifying the accepted generation."
  (let* ((old (plist-get previous-state :ownership-cache))
         (keys '(:surface-node-object-table :region-surface-object-table))
         (valid (and old
                     (cl-every (lambda (key)
                                 (eq (plist-get old key) (plist-get previous-state key)))
                               keys)))
         (cache (list :owners (if valid (plist-get old :owners)
                               (make-hash-table :test #'equal))
                      :shared valid)))
    (dolist (key keys)
      (plist-put cache key (plist-get state key)))
    cache))

(defun ebox-surface--scroll-viewport-result (context previous-state state output batch)
  "Publish STATE's proved viewport OUTPUT and BATCH in the active CONTEXT.
Reuse PREVIOUS-STATE's keyed topology and resolve rich roles against that
unchanged topology.  Every batch supplies complete target ownership, since
equal character lengths do not imply equal visible owners or interaction."
  (let* ((surface-root (ebox--pub-object-ensure context nil ebox-surface--root-key 'ebox/surface))
         (node-root (ebox--pub-object-ensure context surface-root ebox-surface--nodes-key 'ebox/nodes))
         (fragment-root (ebox--pub-object-ensure context surface-root
                                          ebox-surface--fragments-key 'ebox/fragments))
         (text-leaf (ebox--pub-object-ensure context fragment-root ebox-surface--text-key 'ebox/text))
         (node-objects (plist-get state :surface-node-object-table))
         (region-objects (plist-get state :region-surface-object-table))
         (lines (plist-get state :scroll-patch-lines))
         (fragments
          (unless lines
            (plist-get state :scroll-viewport-fragments)))
         (_cache
          (plist-put state :ownership-cache
                     (ebox-surface--ownership-cache previous-state state)))
         (owned-ranges
          (if lines
              (ebox-surface--scroll-owned-ranges
               context text-leaf lines state node-objects region-objects nil)
            (ebox-surface--owned-ranges
             context text-leaf fragments state node-objects region-objects nil)))
         (length (length output))
         (records
          (list (list :object text-leaf :start 0 :end length :props nil :tags nil :leaf t)
                (list :object fragment-root :start 0 :end length :props nil :tags nil :leaf nil)
                (list :object surface-root :start 0 :end length :props nil :tags nil :leaf nil))))
    (ebox--pub-object-reuse-subtree context node-root)
    (plist-put state :surface-owned-ranges owned-ranges)
    (plist-put state :surface-fragments
               (if lines (list :scroll-lines (copy-sequence lines))
                 (ebox-surface--fragment-metadata fragments state)))
    (dolist (key '(:scroll-viewport-output :scroll-viewport-batch :scroll-viewport-fragments
                   :content-coordinate-patches :content-base-extent
                   :span-patch-fragment-data :span-patch-content-p
                   :span-patch-retained-owned-ranges :scroll-patch-lines
                   :nested-scroll-patch-proof :scroll-content-proof
                   :owner-scoped-proofs :scroll-state-transaction
                   :scroll-fast-window-p :scroll-patch-region-id :span-patch-owner-id
                   :preserve-scroll-producer-region-ids :previous-surface-owned-ranges))
      (cl-remf state key))
    (plist-put state :retained-scroll-content-p nil)
    (ebox--pub-commit-batch-result-create
     context batch :mount-specs (ebox-surface--commit-mount-specs records owned-ranges)
     :client-state state)))

(defun ebox-surface--scroll-viewport-producer (previous-state state signals)
  "Return a scroll-only producer using the existing scoped transaction.
STATE owns one prepared viewport batch after PREVIOUS-STATE.  Subscribe to
SIGNALS just like ordinary projection, but consume that batch only once.
A later reactive evaluation renders the then-current source normally rather
than replaying old coordinates, properties or revision authority."
  (let ((output (plist-get state :scroll-viewport-output))
        (batch (plist-get state :scroll-viewport-batch))
        (offsets (ebox-surface--scroll-offsets (plist-get state :scroll-state-table))))
    (lambda (context)
      (let* ((buffer (ebox-surface--signals-buffer signals))
             (surface (ebox-surface--live-buffer-surface buffer))
             (current (ebox--pub-surface-client-state surface))
             (prepared state)
             (base previous-state)
             (rendered output)
             (prepared-batch batch)
             (expected-offsets offsets)
             (_consume
              ;; A producer remains subscribed after this evaluation.  Keep
              ;; only current signals in that closure, on success or fallback;
              ;; later evaluations must not retain an obsolete document.
              (setq state nil previous-state nil output nil batch nil offsets nil))
             (axes (plist-get (or prepared current) :viewport-dependent-node-id-axes))
             (display (ebox--pub-signal-read (ebox-surface--signals-display signals)))
             (width (funcall (if (car axes) #'ebox--pub-signal-read #'ebox--pub-signal-peek)
                             (ebox-surface--signals-viewport-width signals)))
             (height (funcall (if (cdr axes) #'ebox--pub-signal-read #'ebox--pub-signal-peek)
                              (ebox-surface--signals-viewport-height signals)))
             (scroll (ebox--pub-signal-read (ebox-surface--signals-scroll signals))))
        (with-current-buffer buffer
          (if (and prepared (eq current base)
                   (equal display (plist-get prepared :display-signature))
                   (equal width (plist-get prepared :viewport-width))
                   (equal height (plist-get prepared :viewport-height))
                   (equal scroll expected-offsets)
                   (not (or (and ebox-interaction--focus-owner
                                 (ebox-surface--unpainted-interaction-p prepared rendered "focus"))
                            (and ebox-interaction--active-owner
                                 (ebox-surface--unpainted-interaction-p prepared rendered "active")))))
              (ebox-surface--scroll-viewport-result
               context base prepared rendered prepared-batch)
            (ebox-surface--project
             context (ebox-tree-copy-node-structure (plist-get current :root-node))
             current t (list :runtime-revision (ebox--pub-surface-revision surface)
                             :source-base-index (plist-get current :source-index))
             signals nil t nil)))))))

(defun ebox-surface--runtime-index-ready-p (state)
  "Return non-nil when STATE carries a complete prepared runtime index."
  (let* ((root (plist-get state :root-node))
         (root-id (and root (plist-get root :node-id)))
         (nodes (plist-get state :node-table)))
    (and (plist-get state :runtime-index-prepared-p)
         root-id
         (ebox-runtime-index-like-p nodes)
         (eq root (ebox-runtime-index-get root-id nodes))
         (ebox-runtime-index-like-p (plist-get state :parent-table))
         (hash-table-p (plist-get state :region-id-set))
         (ebox-runtime-index-like-p (plist-get state :region-node-table))
         (hash-table-p (plist-get state :region-box-count-table))
         (hash-table-p (plist-get state :region-box-table))
         (hash-table-p
          (and (plist-get state :source-index)
               (ebox-source--index-host-ref-table-view
                (plist-get state :source-index))))
         (hash-table-p (plist-get state :range-ref-table))
         (vectorp (plist-get state :native-node-postorder)))))

(defun ebox-surface--finish-runtime-state (state)
  "Install or retain the prepared runtime indexes in candidate STATE."
  (unless (ebox-surface--runtime-index-ready-p state)
    (setq state
          (ebox--render-state-install-index
           state
           (ebox--runtime-index
            (plist-get state :root-node) t (plist-get state :source-index))))
    (setq state (plist-put state :runtime-index-prepared-p t)))
  (setq state
        (plist-put state :selector-index-stale-p
                   (and (plist-get state :source-index)
                        (ebox-source--index-derived-stale-p
                         (plist-get state :source-index)))))
  state)

(defun ebox-surface--role-ids-from-properties (properties)
  "Return namespaced Ebox role/id pairs from PROPERTIES."
  (ebox--render-role-ids-from-properties properties))

(defun ebox-surface--role-ids-at (rendered position)
  "Return semantic role facts at POSITION without hashing native properties."
  (ebox-surface--role-ids-from-properties (text-properties-at position rendered)))

(defun ebox-surface--intern-role-ids (properties cache)
  "Intern only semantic role facts from PROPERTIES in candidate CACHE.
Faces, keymaps and callback environments are not role lookup dependencies."
  (let ((roles (ebox-surface--role-ids-from-properties properties)))
    (or (gethash roles cache) (puthash roles roles cache))))

(defun ebox-surface--paint-address (properties roles &optional paint-source-roles)
  "Return paint address facts from PROPERTIES and already resolved ROLES.
The ledger assigns occurrence ordinals after changed and retained runs merge."
  (let ((owner (plist-get properties 'ebox-content-owner))
        (index (plist-get properties 'ebox-content-idx)))
    (when (or roles owner (integerp index) paint-source-roles)
      (append (list :roles roles :content-owner owner :content-index index)
              (when paint-source-roles (list :paint-source-roles paint-source-roles))))))

(defun ebox-surface--candidate-plan-text (rendered owned-values)
  "Return a private snapshot of RENDERED for an owned Ebox publication plan.
OWNED-VALUES is the candidate-local provenance registry created by Ebox's
render helpers.  Ebox publication transfers only mutable values present in
this registry; all other values remain defensively copied."
  (ebox-text-snapshot
   rendered
   (and (hash-table-p owned-values)
        (lambda (property value)
          (and (ebox--render-owned-text-value-p
                property value owned-values)
               (not (memq property '(face font-lock-face mouse-face))))))))

(defun ebox-surface--region-role-tags (region-id role-ids)
  "Return projection tags for REGION-ID from ROLE-IDS."
  (list :ebox/region-id region-id
        :ebox/roles
        (cl-loop for (role . owner) in role-ids
                 when (equal owner region-id) collect role)))

(defun ebox-surface--fragment-owners
    (role-ids state node-objects region-objects)
  "Return ordered Ebox owner and tag pairs for ROLE-IDS.
Each owner appears at most once for one rendered fragment."
  (let ((attached (make-hash-table :test #'eq))
        (region-node-table (plist-get state :region-node-table))
        (parent-table (plist-get state :parent-table))
        owners)
    (dolist (region-id (delete-dups (mapcar #'cdr role-ids)))
      (let ((object (gethash region-id region-objects))
            (node-id (ebox-runtime-index-get region-id region-node-table)))
        (unless (and object node-id)
          (error "Ebox output references unknown region %S" region-id))
        (unless (gethash object attached)
          (push (list object
                      (ebox-surface--region-role-tags region-id role-ids))
                owners)
          (puthash object t attached))
        (setq node-id (ebox-runtime-index-get node-id parent-table))
        (while node-id
          (let ((ancestor (gethash node-id node-objects)))
            (unless ancestor
              (error "Ebox output ancestor has no Ebox publication object: %S" node-id))
            (unless (gethash ancestor attached)
              (push (list ancestor (list :ebox/descendant-output t)) owners)
              (puthash ancestor t attached)))
          (setq node-id (ebox-runtime-index-get node-id parent-table)))))
    (nreverse owners)))

(cl-defstruct (ebox-surface--geometry-mount
               (:constructor ebox-surface--make-geometry-mount))
  "Compiled ownership instructions and fixed mount capacity for one surface."
  slots descriptors full epoch properties signature signatures role-instructions
  row-values row-heads row-tails row-entries active-row row-origin
  surface topology-generation rasters raster-bank raster-capacity role-epoch
  interval-bound exhausted)

(cl-defstruct (ebox-surface--geometry-owner
               (:constructor ebox-surface--make-geometry-owner))
  "One direct or ancestor owner, with reusable interval and merge storage."
  object tags mounts epoch used end slot full-p
  free-entry row-epoch row-end row-slot binding direct-p)

(defun ebox-surface--geometry-owner-intern (table object tags)
  "Resolve OBJECT and TAGS in cold ownership TABLE."
  (let* ((entries (gethash object table))
         (entry (assoc tags entries #'equal)))
    (or (cdr entry)
        (let ((owner (ebox-surface--make-geometry-owner
                      :object object :tags (copy-tree tags))))
          (puthash object (cons (cons (ebox-surface--geometry-owner-tags owner) owner)
                               entries) table)
          owner))))

(defun ebox-surface--geometry-mount-prepare-role
    (owners instructions roles region index state node-objects region-objects)
  "Compile one REGION role at INDEX into cold ownership INSTRUCTIONS.
The role's direct tag is exact; combining it with another role later cannot
expose tags that were present only in a broader raster signature."
  (let ((program (or (gethash region instructions)
                     (puthash region (make-vector (length roles) nil) instructions))))
    (unless (aref program index)
      (let* ((role (aref roles index))
             (token (vconcat
                     (mapcar
                      (lambda (entry)
                        (ebox-surface--geometry-owner-intern
                         owners (car entry) (cadr entry)))
                      (ebox-surface--fragment-owners
                       (list (cons role region)) state node-objects region-objects)))))
        ;; The list-valued and direct content-owner properties share one
        ;; semantic role, so both execute the same exact token program.
        (dotimes (slot (length roles))
          (when (eq (aref roles slot) role) (aset program slot token)))))))

(defun ebox-surface--geometry-mount-prepare
    (surface state rasters interval-capacity &optional wrapper-region-ids rows
             layer-rasters layer-count)
  "Compile SURFACE ownership from STATE into owned raster copies RASTERS.
RASTERS must be caller-owned strings: compilation adds immutable private
owner tokens in place.  The compositor preserves those tokens while slicing
and joining pixels.  INTERVAL-CAPACITY bounds disjoint visible intervals per
owner/tag combination.  Existing authoritative mounts are retained in the
pool, including combinations absent from the current pixels.
Call the publisher's frame preparation on the returned slots before filling
them for the first time.  This is the control-plane pass; ancestor traversal,
tag interning and mount allocation never occur in the fill operation.
Optional ROWS is the fixed final row vector, excluding structural newlines;
the first RASTERS element must then be its complete joined output.  Its
row interval cache is primed here without changing the complete mount pool.
Optional LAYER-RASTERS lists the RASTERS elements holding unoccluded layer
pixels and LAYER-COUNT the number of movable layers.  An owner visible in those
pixels or in the joined ROWS then reserves twice its object's largest known
interval count plus one interval per layer: a moved layer splits at most one
interval per row.  The reservation never exceeds INTERVAL-CAPACITY plus the
row count, which objects absent from every raster keep.  A frame needing more
intervals grows the exhausted pools through
`ebox-surface--geometry-mount-grow' up to that bound."
  (unless (and (integerp interval-capacity) (> interval-capacity 0))
    (error "Invalid prepared geometry interval capacity: %S" interval-capacity))
  (let ((owners (make-hash-table :test #'eq))
        (tokens (make-hash-table :test #'equal))
        (signatures (make-hash-table :test #'equal))
        (role-instructions (make-hash-table :test #'equal))
        (properties (vconcat '(ebox-overflow-foreground-source ebox-content-owners)
                             (mapcar #'cdr ebox-region-types)))
        (role-names (vconcat '(overflow-foreground content-owner)
                             (mapcar #'car ebox-region-types)))
        (node-objects (plist-get state :surface-node-object-table))
        (region-objects (plist-get state :region-surface-object-table))
        (layer-set (and layer-rasters (make-hash-table :test #'eq)))
        (layer-intervals (make-hash-table :test #'equal))
        descriptors full all-mounts)
    (dolist (raster layer-rasters) (puthash raster t layer-set))
    ;; The joined output separately bounds its owners, one interval per row run.
    (when (and layer-set rows (car rasters)) (puthash (car rasters) 'joined layer-set))
    ;; Reuse accepted mount identities before allocating spare capacity.
    (dolist (mount (ebox--pub--surface-mounts surface))
      (let* ((object (ebox--pub--surface-mount-object mount))
             (tags (ebox--pub--surface-mount-tags mount))
             (owner (ebox-surface--geometry-owner-intern owners object tags)))
        (push mount (ebox-surface--geometry-owner-mounts owner))
        (when (and (null tags)
                   (memq (ebox--pub--surface-object-kind object)
                         '(ebox/surface ebox/fragments ebox/text)))
          (cl-pushnew owner full :test #'eq))))
    ;; The full accepted primitive also contains fixed wrapper borders and
    ;; padding.  They are regenerated around the compiled plane, so their
    ;; role signatures provide cold instructions when a new wrapper run has
    ;; no raster token.  Empty-role filler always has an empty owner program.
    (puthash (make-vector (length properties) nil) [] signatures)
    (dolist (raster (cons (ebox--pub--shadow-surface-output surface) rasters))
      (unless (stringp raster) (error "Prepared geometry raster is not a string"))
      (remove-text-properties 0 (length raster) '(ebox--prepared-owners nil) raster)
      (let ((position 0) (layer-p (and layer-set (gethash raster layer-set)))
            (previous []))
        (while (< position (length raster))
          (let* ((end (next-property-change position raster (length raster)))
                 (roles (ebox-surface--role-ids-at raster position))
                 (token (gethash roles tokens 'ebox/unknown)))
            (when (eq token 'ebox/unknown)
              (setq token
                    (vconcat
                     (mapcar
                      (lambda (entry)
                        (ebox-surface--geometry-owner-intern
                         owners (car entry) (cadr entry)))
                      (ebox-surface--fragment-owners
                       roles state node-objects region-objects))))
              (puthash roles token tokens))
            (let ((signature (make-vector (length properties) nil)))
              (dotimes (index (length properties))
                (let ((value (get-text-property position (aref properties index) raster)))
                  (aset signature index (copy-tree value))
                  (if (= index 1)
                      (dolist (region value)
                        (ebox-surface--geometry-mount-prepare-role
                         owners role-instructions role-names region index
                         state node-objects region-objects))
                    (when value
                      (ebox-surface--geometry-mount-prepare-role
                       owners role-instructions role-names value index
                       state node-objects region-objects)))))
              (puthash signature token signatures))
            (when (> (length token) 0)
              (put-text-property position end 'ebox--prepared-owners token raster))
            ;; Adjacent runs of one owner in a layer raster form one interval.
            (when layer-p
              (let ((pieces 1) (newline position))
                (while (setq newline (and (< newline end)
                                          (string-search "\n" raster newline)))
                  (when (< newline end)
                    (setq pieces (1+ pieces)))
                  (setq newline (1+ newline)))
                (dotimes (index (length token))
                  (let* ((owner (aref token index))
                         (key (if (eq layer-p 'joined) (list owner) owner)))
                    (puthash key
                             (+ (gethash key layer-intervals 0)
                                (if (cl-find owner previous :test #'eq)
                                    (1- pieces)
                                  pieces))
                             layer-intervals)))
                (setq previous
                      (if (and (> end position) (eq (aref raster (1- end)) ?\n))
                          [] token))))
            (setq position end)))))
    ;; Raw rasters compile their exact role factors even when currently
    ;; occluded.  Enclosing wrappers can add their own roles around a later
    ;; exposed child signature without discovering ownership on refresh.
    ;; Duplicate ancestor spans coalesce through the same owner instruction.
    (dolist (region-id wrapper-region-ids)
      (dotimes (index (length properties))
        (ebox-surface--geometry-mount-prepare-role
         owners role-instructions role-names region-id index
         state node-objects region-objects)))
    (maphash
     (lambda (_object entries)
       (let ((binding (vector nil nil))
             ;; Every role owner of one object shares that object's footprint.
             (known (and layer-count
                         (cl-loop for entry in entries
                                  maximize
                                  (max (length (ebox-surface--geometry-owner-mounts (cdr entry)))
                                       (gethash (list (cdr entry)) layer-intervals 0)
                                       (gethash (cdr entry) layer-intervals 0))))))
         (dolist (entry entries)
           (let* ((owner (cdr entry))
                  (existing (nreverse (ebox-surface--geometry-owner-mounts owner)))
                  (bound (+ interval-capacity (length rows)))
                  (capacity
                   (cond
                    ((memq owner full) (max 1 (length existing)))
                    ;; Objects with no visible interval (hidden layers) keep
                    ;; the full bound so revealing them stays prepared.
                    ((and known (> known 0))
                     (max (length existing)
                          (min bound (+ (* 2 known) layer-count))))
                    (t (max bound (length existing)))))
                  (mounts (make-vector capacity nil))
                  (index 0))
             (dolist (mount existing)
               (aset mounts index mount)
               (setq index (1+ index)))
             (while (< index capacity)
               (aset mounts index
                     (ebox--pub-frame-mount-create
                      (ebox-surface--geometry-owner-object owner)
                      (ebox-surface--geometry-owner-tags owner)))
               (setq index (1+ index)))
             (setf (ebox-surface--geometry-owner-mounts owner) mounts
                   (ebox-surface--geometry-owner-full-p owner) (and (memq owner full) t)
                   (ebox-surface--geometry-owner-binding owner) binding
                   (ebox-surface--geometry-owner-direct-p owner)
                   (and (plist-get (ebox-surface--geometry-owner-tags owner) :ebox/region-id) t))
             (push owner descriptors)
             (dotimes (i capacity) (push (aref mounts i) all-mounts))))))
     owners)
    (let ((slots (make-vector (* 4 (length all-mounts)) nil))
          (entries (and rows (make-vector (* 6 (length all-mounts)) nil)))
          (index 0) (entry 0))
      (dolist (mount all-mounts)
        (aset slots index mount)
        (aset slots (1+ index) 0)
        (aset slots (+ 2 index) 0)
        (aset slots (+ 3 index) (ebox--pub--surface-mount-tags mount))
        (when entries
          (let ((owner (ebox-surface--geometry-owner-intern
                        owners (ebox--pub--surface-mount-object mount)
                        (ebox--pub--surface-mount-tags mount))))
            ;; Each cache entry belongs permanently to one mount and owner.
            ;; Its link joins either one row's intervals or the owner's free pool.
            (aset entries entry mount)
            (aset entries (1+ entry) owner)
            (aset entries (+ 4 entry) (ebox-surface--geometry-owner-free-entry owner))
            (aset entries (+ 5 entry) (ebox-surface--geometry-owner-tags owner))
            (setf (ebox-surface--geometry-owner-free-entry owner) entry))
          (setq entry (+ entry 6)))
        (setq index (+ index 4)))
      (let ((projection
             (ebox-surface--make-geometry-mount
              :slots slots :descriptors (vconcat descriptors) :full (vconcat full)
              :epoch 0 :properties properties :signatures signatures
              :signature (make-vector (length properties) nil)
              :role-instructions role-instructions
              :row-values (and rows (make-vector (length rows) nil))
              :row-heads (and rows (make-vector (length rows) nil))
              :row-tails (and rows (make-vector (length rows) nil))
              :row-entries entries :surface surface
              :topology-generation (plist-get state :geometry-topology-generation)
              :rasters (vector (make-hash-table :test #'eq :size (max 1 (length rasters)))
                               (make-hash-table :test #'eq :size (max 1 (length rasters))))
              :raster-bank 0 :raster-capacity (length rasters) :role-epoch 0
              :interval-bound (+ interval-capacity (length rows)))))
        (dolist (raster rasters)
          (puthash raster t (aref (ebox-surface--geometry-mount-rasters projection) 0)))
        (when rows
          (while (not (ebox-surface--geometry-mount-update-rows
                       projection (car rasters) rows nil))
            (unless (ebox-surface--geometry-mount-grow projection)
              (error "Prepared geometry row ownership exceeds its cold capacity"))))
        projection))))

(defun ebox-surface--geometry-mount-known-roles-p (projection signature)
  "Return whether PROJECTION can execute every role in SIGNATURE.
Unknown combinations may use the existing factored raster instructions;
refresh never interns an owner or creates a combined token program."
  (let ((instructions (ebox-surface--geometry-mount-role-instructions projection))
        (index 0) (valid t))
    (while (and valid (< index (length signature)))
      (let ((value (aref signature index)))
        (if (= index 1)
            (while (and valid value)
              (let ((program (and (consp value) (gethash (car value) instructions))))
                (setq valid (and program (aref program index))
                      value (cdr-safe value))))
          (when value
            (let ((program (gethash value instructions)))
              (setq valid (and program (aref program index)))))))
      (setq index (1+ index)))
    valid))

(defun ebox-surface--geometry-mount-refresh-raster (projection raster annotate)
  "Check RASTER's compiled role instructions, optionally ANNOTATE in place.
RASTER must be an owned primitive string, immutable after this pass."
  (let ((properties (ebox-surface--geometry-mount-properties projection))
        (signature (ebox-surface--geometry-mount-signature projection))
        (signatures (ebox-surface--geometry-mount-signatures projection))
        (position 0) (size (length raster)) (valid t))
    (when annotate
      (remove-text-properties 0 size '(ebox--prepared-owners nil) raster))
    (while (and valid (< position size))
      (let ((end (next-property-change position raster size)))
        (dotimes (index (length properties))
          (aset signature index
                (get-text-property position (aref properties index) raster)))
        (let ((token (gethash signature signatures)))
          (setq valid (or token (ebox-surface--geometry-mount-known-roles-p
                                projection signature)))
          (when (and annotate token (> (length token) 0))
            (put-text-property position end 'ebox--prepared-owners token raster)))
        (setq position end)))
    valid))

(defun ebox-surface--geometry-mount-refresh (projection surface state rasters &optional rows)
  "Refresh PROJECTION's owned RASTERS after a proved ordinary publication.
STATE's topology generation is retained only by the publication authority's
accepted dirty and object facts.  Equal generation and SURFACE identity let
this pass reuse owner programs, mount records and interval capacity without
comparing node trees or following ancestors.  RASTERS supplies the complete
current inventory, beginning with the joined output; unchanged immutable
strings need no property scan.  Optional ROWS has the original fixed count.
Return non-nil on refresh, or nil when existing instructions cannot represent
the new pixels.  No surface authority is changed; frame refresh separately
adopts the current accepted generation before these slots can be published."
  (let ((generation (ebox-surface--geometry-mount-topology-generation projection)))
    (when (and generation
               (eq generation (plist-get state :geometry-topology-generation))
               (eq surface (ebox-surface--geometry-mount-surface projection))
               (<= (length rasters) (ebox-surface--geometry-mount-raster-capacity projection))
               (or (null rows)
                   (= (length rows) (length (ebox-surface--geometry-mount-row-values projection)))))
      (let* ((banks (ebox-surface--geometry-mount-rasters projection))
             (old-bank (ebox-surface--geometry-mount-raster-bank projection))
             (next-bank (- 1 old-bank))
             (known (aref banks old-bank))
             (next (aref banks next-bank))
             (valid t))
        (clrhash next)
        ;; Prove every changed primitive before altering any raster.  An
        ;; unsupported role leaves the caller free to choose cold preparation.
        (dolist (raster rasters)
          (when valid
            (setq valid
                  (and (stringp raster)
                       (or (gethash raster known)
                           (ebox-surface--geometry-mount-refresh-raster projection raster nil))))))
        (when valid
          (dolist (raster rasters)
            (unless (or (gethash raster known) (gethash raster next))
              (ebox-surface--geometry-mount-refresh-raster projection raster t))
            (puthash raster t next))
          (setq valid
                (or (null rows)
                    (cl-loop
                     (cond ((ebox-surface--geometry-mount-update-rows
                             projection (car rasters) rows nil)
                            (cl-return t))
                           ((not (ebox-surface--geometry-mount-grow projection))
                            (cl-return nil))))))
          (when valid
            (setf (ebox-surface--geometry-mount-raster-bank projection) next-bank)))
        valid))))

(defun ebox-surface--geometry-mount-append
    (projection owner start end epoch count)
  "Append or extend OWNER's START..END interval in PROJECTION.
EPOCH resets preallocated merge slots lazily.  COUNT is the active interval
count; return the new count, or nil when this owner exhausts its cold pool."
  (if (ebox-surface--geometry-mount-active-row projection)
      (ebox-surface--geometry-mount-row-append projection owner start end epoch count)
    (unless (eql (ebox-surface--geometry-owner-epoch owner) epoch)
      (setf (ebox-surface--geometry-owner-epoch owner) epoch
            (ebox-surface--geometry-owner-used owner) 0
            (ebox-surface--geometry-owner-end owner) nil
            (ebox-surface--geometry-owner-slot owner) nil))
    (let ((slots (ebox-surface--geometry-mount-slots projection))
          (last-end (ebox-surface--geometry-owner-end owner)))
      (if (and last-end (>= last-end end)
               (<= (aref slots (1+ (ebox-surface--geometry-owner-slot owner))) start))
          count
        (if (and last-end (= last-end start))
            (progn
              (aset slots (+ 2 (ebox-surface--geometry-owner-slot owner)) end)
              (setf (ebox-surface--geometry-owner-end owner) end)
              count)
          (let* ((used (ebox-surface--geometry-owner-used owner))
                 (mounts (ebox-surface--geometry-owner-mounts owner))
                 (offset (* 4 count)))
            (if (>= used (length mounts))
                (progn
                  (cl-pushnew owner (ebox-surface--geometry-mount-exhausted projection)
                              :test #'eq)
                  count)
              (aset slots offset (aref mounts used))
              (aset slots (1+ offset) start)
              (aset slots (+ 2 offset) end)
              (aset slots (+ 3 offset) (ebox-surface--geometry-owner-tags owner))
              (setf (ebox-surface--geometry-owner-used owner) (1+ used)
                    (ebox-surface--geometry-owner-end owner) end
                    (ebox-surface--geometry-owner-slot owner) offset)
              (1+ count))))))))

(defun ebox-surface--geometry-mount-role
    (projection region role start end epoch count)
  "Run a known REGION's prepared ROLE instructions for START..END."
  (if (null region) count
    (let* ((instructions (gethash region (ebox-surface--geometry-mount-role-instructions projection)))
           (token (and instructions (aref instructions role)))
           (index 0))
      (unless token (setq count nil))
      (while (and count (< index (length token)))
        (let* ((owner (aref token index))
               (binding (ebox-surface--geometry-owner-binding owner))
               (direct (ebox-surface--geometry-owner-direct-p owner))
               (role-epoch (ebox-surface--geometry-mount-role-epoch projection)))
          (unless (eql (aref binding 0) role-epoch)
            (aset binding 0 role-epoch)
            (aset binding 1 direct))
          ;; Generic ownership gives first attachment priority; later roles
          ;; cannot change a direct attachment to an ancestor or vice versa.
          ;; A first direct owner may still contribute several exact roles.
          (when (eq direct (aref binding 1))
            (setq count (ebox-surface--geometry-mount-append
                         projection owner start end epoch count))))
        (setq index (1+ index)))
      count)))

(defun ebox-surface--geometry-mount-run-roles
    (projection rendered start end epoch count)
  "Execute compiled property-role instructions for RENDERED at START..END."
  (let ((properties (ebox-surface--geometry-mount-properties projection))
        (index 0))
    (cl-incf (ebox-surface--geometry-mount-role-epoch projection))
    (while (and count (< index (length properties)))
      (let ((value (get-text-property start (aref properties index) rendered)))
        (if (= index 1)
            (while (and count value)
              (setq count (ebox-surface--geometry-mount-role
                           projection (car value) index start end epoch count)
                    value (cdr value)))
          (setq count (ebox-surface--geometry-mount-role
                       projection value index start end epoch count))))
      (setq index (1+ index)))
    count))

(defun ebox-surface--geometry-mount-row-append
    (projection owner start end epoch count)
  "Append OWNER's interval to the active cached row in PROJECTION.
All entries and their owner-specific free links belong to the cold mount pool."
  (if (ebox-surface--geometry-owner-full-p owner) count
    (unless (eql (ebox-surface--geometry-owner-row-epoch owner) epoch)
      (setf (ebox-surface--geometry-owner-row-epoch owner) epoch
            (ebox-surface--geometry-owner-row-end owner) nil
            (ebox-surface--geometry-owner-row-slot owner) nil))
    (let* ((entries (ebox-surface--geometry-mount-row-entries projection))
           (origin (ebox-surface--geometry-mount-row-origin projection))
           (start (- start origin)) (end (- end origin))
           (last-end (ebox-surface--geometry-owner-row-end owner))
           (last-slot (ebox-surface--geometry-owner-row-slot owner)))
      (cond
       ((and last-end (>= last-end end)
             (<= (aref entries (+ 2 last-slot)) start)) count)
       ((and last-end (= last-end start))
        (aset entries (+ 3 last-slot) end)
        (setf (ebox-surface--geometry-owner-row-end owner) end)
        count)
       (t
        (let ((entry (ebox-surface--geometry-owner-free-entry owner)))
          ;; An exhausted pool keeps scanning so one retry grows every owner.
          (if (null entry)
              (progn
                (cl-pushnew owner (ebox-surface--geometry-mount-exhausted projection)
                            :test #'eq)
                count)
            (setf (ebox-surface--geometry-owner-free-entry owner)
                  (aref entries (+ 4 entry)))
            (aset entries (+ 2 entry) start)
            (aset entries (+ 3 entry) end)
            (aset entries (+ 4 entry) nil)
            (let* ((row (ebox-surface--geometry-mount-active-row projection))
                   (heads (ebox-surface--geometry-mount-row-heads projection))
                   (tails (ebox-surface--geometry-mount-row-tails projection))
                   (tail (aref tails row)))
              (if tail (aset entries (+ 4 tail) entry)
                (aset heads row entry))
              (aset tails row entry))
            (setf (ebox-surface--geometry-owner-row-end owner) end
                  (ebox-surface--geometry-owner-row-slot owner) entry)
            (1+ count))))))))

(defun ebox-surface--geometry-mount-scan
    (projection rendered position limit epoch count)
  "Execute RENDERED ownership runs from POSITION to LIMIT into PROJECTION."
  (while (and count (< position limit))
    (let* ((token (get-text-property position 'ebox--prepared-owners rendered))
           (end (if token
                    (next-single-property-change
                     position 'ebox--prepared-owners rendered limit)
                  (next-property-change position rendered limit)))
           (i 0))
      (unless token
        (let ((signature (ebox-surface--geometry-mount-signature projection))
              (properties (ebox-surface--geometry-mount-properties projection)))
          (dotimes (index (length properties))
            (aset signature index
                  (get-text-property position (aref properties index) rendered)))
          (setq token (gethash signature (ebox-surface--geometry-mount-signatures projection)))
          (unless token
            (setq count (ebox-surface--geometry-mount-run-roles
                         projection rendered position end epoch count)
                  token []))))
      (while (and count (< i (length token)))
        (setq count (ebox-surface--geometry-mount-append
                     projection (aref token i) position end epoch count)
              i (1+ i)))
      (setq position end)))
  count)

(defun ebox-surface--geometry-mount-update-rows (projection rendered rows dirty)
  "Refresh only changed ROWS' cached intervals from RENDERED in PROJECTION.
DIRTY names normal damage.  Row identity additionally detects the previous
attempt's discarded pixels, so publication rollback needs no cache mutation."
  (let ((values (ebox-surface--geometry-mount-row-values projection))
        (heads (ebox-surface--geometry-mount-row-heads projection))
        (tails (ebox-surface--geometry-mount-row-tails projection))
        (entries (ebox-surface--geometry-mount-row-entries projection))
        (size (length rendered)) (offset 0) (valid t))
    (unless (= (length rows) (length values))
      (error "Prepared geometry changed its retained row count"))
    ;; Release every affected row before acquiring entries for any one row.
    ;; A vertical translation can transfer an owner's whole interval capacity.
    (dotimes (row (length rows))
      (when (or (and dirty (aref dirty row))
                (not (eq (aref rows row) (aref values row))))
        (let ((entry (aref heads row)))
          (while entry
            (let ((owner (aref entries (1+ entry)))
                  (next (aref entries (+ 4 entry))))
              (aset entries (+ 4 entry) (ebox-surface--geometry-owner-free-entry owner))
              (setf (ebox-surface--geometry-owner-free-entry owner) entry)
              (setq entry next))))
        (aset heads row nil)
        (aset tails row nil)
        (aset values row nil)))
    (unwind-protect
        (dotimes (row (length rows))
          (let* ((text (aref rows row))
                 (end (+ offset (length text)
                         (if (< (1+ row) (length rows)) 1 0))))
            (when (and valid (not (eq text (aref values row))))
              (let ((epoch (1+ (ebox-surface--geometry-mount-epoch projection))))
                (setf (ebox-surface--geometry-mount-active-row projection) row
                      (ebox-surface--geometry-mount-row-origin projection) offset
                      (ebox-surface--geometry-mount-epoch projection) epoch)
                (setq valid
                      (and (<= end size)
                           (ebox-surface--geometry-mount-scan
                            projection rendered offset end epoch 0)))
                (when (and valid (null (ebox-surface--geometry-mount-exhausted projection)))
                  (aset values row text))))
            (setq offset end)))
      (setf (ebox-surface--geometry-mount-active-row projection) nil))
    (and valid (= offset size)
         (null (ebox-surface--geometry-mount-exhausted projection)))))

(defun ebox-surface--geometry-mount-grow (projection)
  "Grow PROJECTION's pools exhausted by the last fill to their fixed bound.
New inactive mounts join each exhausted owner's free intervals and a complete
slot vector replaces the old one, so the caller must prepare a new publication
frame over those slots before retrying the fill.  Return non-nil when some
pool grew; nil means the frame needs more intervals than the bound admits."
  (let ((exhausted (ebox-surface--geometry-mount-exhausted projection))
        (bound (ebox-surface--geometry-mount-interval-bound projection))
        (entries (ebox-surface--geometry-mount-row-entries projection))
        additions)
    (setf (ebox-surface--geometry-mount-exhausted projection) nil)
    (dolist (owner exhausted)
      (let* ((mounts (ebox-surface--geometry-owner-mounts owner))
             (size (length mounts))
             (capacity (or bound 0)))
        (when (and (not (ebox-surface--geometry-owner-full-p owner))
                   (> capacity size))
          (let ((next (make-vector capacity nil)))
            (dotimes (index size) (aset next index (aref mounts index)))
            (cl-loop for index from size below capacity do
                     (let ((mount (ebox--pub-frame-mount-create
                                   (ebox-surface--geometry-owner-object owner)
                                   (ebox-surface--geometry-owner-tags owner))))
                       (aset next index mount)
                       (push (cons owner mount) additions)))
            (setf (ebox-surface--geometry-owner-mounts owner) next)))))
    (when additions
      (setq additions (nreverse additions))
      (when entries
        (let* ((entry (length entries))
               (grown (vconcat entries (make-vector (* 6 (length additions)) nil))))
          (dolist (addition additions)
            (let ((owner (car addition)))
              (aset grown entry (cdr addition))
              (aset grown (1+ entry) owner)
              (aset grown (+ 4 entry) (ebox-surface--geometry-owner-free-entry owner))
              (aset grown (+ 5 entry) (ebox-surface--geometry-owner-tags owner))
              (setf (ebox-surface--geometry-owner-free-entry owner) entry)
              (setq entry (+ entry 6))))
          (setf (ebox-surface--geometry-mount-row-entries projection) grown)))
      (let* ((descriptors (ebox-surface--geometry-mount-descriptors projection))
             (count (cl-loop for owner across descriptors
                             sum (length (ebox-surface--geometry-owner-mounts owner))))
             (slots (make-vector (* 4 count) nil))
             (index 0))
        (cl-loop for owner across descriptors do
                 (cl-loop for mount across (ebox-surface--geometry-owner-mounts owner) do
                          (aset slots index mount)
                          (aset slots (1+ index) 0)
                          (aset slots (+ 2 index) 0)
                          (aset slots (+ 3 index) (ebox--pub--surface-mount-tags mount))
                          (setq index (+ index 4))))
        (setf (ebox-surface--geometry-mount-slots projection) slots))
      t)))

(defun ebox-surface--geometry-mount-fill (projection rendered &optional rows dirty)
  "Fill PROJECTION's reusable active mount slots from RENDERED tokens.
Optional ROWS and DIRTY use the cold retained-row cache.  Only changed rows
rescan token memberships; unchanged intervals shift by current character
offsets.  Return the active count, or nil if an interval pool is insufficient.
Surface, fragment and text records span the complete primitive output.
Strip private tokens only from successful RENDERED, preserving retained rows.
No source/component traversal or temporary ownership records are constructed."
  (setf (ebox-surface--geometry-mount-exhausted projection) nil)
  (let ((epoch (1+ (ebox-surface--geometry-mount-epoch projection)))
        (full (ebox-surface--geometry-mount-full projection))
        (count 0) (size (length rendered)))
    (setf (ebox-surface--geometry-mount-epoch projection) epoch)
    (dotimes (i (length full))
      (when count
        (setq count (ebox-surface--geometry-mount-append
                     projection (aref full i) 0 size epoch count))))
    (if rows
        (if (ebox-surface--geometry-mount-update-rows projection rendered rows dirty)
            (let ((entries (ebox-surface--geometry-mount-row-entries projection))
                  (heads (ebox-surface--geometry-mount-row-heads projection))
                  (slots (ebox-surface--geometry-mount-slots projection))
                  (origin 0))
              (dotimes (row (length rows))
                (let ((entry (aref heads row)))
                  (while entry
                    (let ((slot (* 4 count)))
                      (aset slots slot (aref entries entry))
                      (aset slots (1+ slot) (+ origin (aref entries (+ 2 entry))))
                      (aset slots (+ 2 slot) (+ origin (aref entries (+ 3 entry))))
                      (aset slots (+ 3 slot) (aref entries (+ 5 entry))))
                    (setq count (1+ count) entry (aref entries (+ 4 entry)))))
                (setq origin (+ origin (length (aref rows row)) 1))))
          (setq count nil))
      (setq count (ebox-surface--geometry-mount-scan
                   projection rendered 0 size epoch count)))
    (when (ebox-surface--geometry-mount-exhausted projection)
      (setq count nil))
    (when count
      (remove-text-properties 0 size '(ebox--prepared-owners nil) rendered))
    count))

(defun ebox-surface--line-layout-dependencies (fragments rendered)
  "Record allocation dependencies for one line's FRAGMENTS from RENDERED.
A boundary display-space with only content-owner roles fills its containing
line.  Its width depends on descendant content and chrome in that container.
Interior gaps remain outside this permission.  Keep publication dependencies
separate from semantic and paint ownership."
  (let ((contributors (make-hash-table :test #'equal)))
    (dolist (fragment fragments)
      (let* ((roles (plist-get fragment :role-ids))
             (direct (delete-dups
                      (cl-loop for (role . id) in roles
                               unless (eq role 'content-owner)
                               collect id))))
        (when direct
          (dolist (owner (delete-dups (mapcar #'cdr roles)))
            (dolist (id direct)
              ;; A container's own padding/border is outside the allocation
              ;; it fills.  Descendant chrome participates in that allocation.
              (unless (equal id owner)
                (let ((entry
                       (or (gethash owner contributors)
                           (puthash
                            owner
                            (list :ids nil :seen (make-hash-table :test #'equal)
                                  :start (plist-get fragment :start)
                                  :end (plist-get fragment :end))
                            contributors))))
                  (unless (gethash id (plist-get entry :seen))
                    (plist-put entry :ids (cons id (plist-get entry :ids)))
                    (puthash id t (plist-get entry :seen)))
                  (plist-put entry :start
                             (min (plist-get entry :start)
                                  (plist-get fragment :start)))
                  (plist-put entry :end
                             (max (plist-get entry :end)
                                  (plist-get fragment :end))))))))))
    (dolist (fragment fragments)
      (let* ((roles (plist-get fragment :role-ids))
             (start (plist-get fragment :start))
             (end (plist-get fragment :end)))
        (when (and roles
                   (cl-every (lambda (role) (eq (car role) 'content-owner))
                             roles)
                   (= (- end start) 1)
                   (= (aref rendered start) ?\s)
                   (eq (car-safe (get-text-property start 'display rendered))
                       'space))
          (when-let* ((entry (gethash (cdar roles) contributors)))
            (when (or (<= end (plist-get entry :start))
                      (>= start (plist-get entry :end)))
              (plist-put fragment :layout-region-ids
                         (plist-get entry :ids)))))))))

(defun ebox-surface--finish-fragment-ledger (fragments rendered)
  "Finish derived metadata in candidate FRAGMENTS without reparsing text.
Only changed line groups recompute layout dependencies. Raw role facts and
newline counts let retained runs participate without reading their properties."
  (let ((line 0) (index 0) previous next group dirty
        (ordinals (make-hash-table :test #'equal)))
    (dolist (fragment fragments)
      (plist-put fragment :role-ids (plist-get fragment :direct-role-ids))
      (plist-put fragment :line line)
      (plist-put fragment :key (cons 'ebox/fragment index))
      (cl-incf index)
      (when-let* ((address (plist-get fragment :paint-address)))
        (let ((prefix (copy-sequence address)))
          (cl-remf prefix :ordinal)
          (let ((ordinal (gethash prefix ordinals 0)))
            (puthash prefix (1+ ordinal) ordinals)
            (plist-put fragment :paint-address (append prefix (list :ordinal ordinal))))))
      (push fragment group)
      (setq dirty (or dirty (plist-get fragment :layout-dirty-p)))
      (cl-incf line (plist-get fragment :newline-count))
      (when (> (plist-get fragment :newline-count) 0)
        (when dirty
          (dolist (item group) (plist-put item :layout-region-ids nil))
          (ebox-surface--line-layout-dependencies group rendered))
        (setq group nil dirty nil)))
    (when (and group dirty)
      (dolist (item group) (plist-put item :layout-region-ids nil))
      (ebox-surface--line-layout-dependencies group rendered))
    (dolist (fragment fragments)
      (cl-remf fragment :layout-dirty-p)
      (if-let* ((roles (plist-get fragment :direct-role-ids)))
          (setq previous roles)
        (plist-put fragment :previous-role-ids previous)))
    (dolist (fragment (reverse (copy-sequence fragments)))
      (if-let* ((roles (plist-get fragment :direct-role-ids)))
          (setq next roles)
        (plist-put fragment :role-ids
                   (delete-dups (append (copy-sequence (plist-get fragment :previous-role-ids))
                                        (copy-sequence next)))))
      (cl-remf fragment :previous-role-ids))
    fragments))

(defun ebox-surface--rendered-fragments (rendered)
  "Parse RENDERED into an offset ledger with reusable source and paint facts."
  (let ((position 0) (limit (length rendered))
        (role-cache (make-hash-table :test #'equal)) fragments)
    (while (< position limit)
      (let* ((next (or (next-property-change position rendered limit) limit))
             (properties (text-properties-at position rendered))
             (origin (plist-get properties ebox--paint-origin-property))
             (roles (ebox-surface--intern-role-ids properties role-cache))
             (paint-roles
              (if (and origin (ebox--paint-origin-source-roles origin))
                  (delete-dups (append (copy-sequence (ebox--paint-origin-source-roles origin)) roles))
                roles))
             (address (ebox-surface--paint-address
                       properties roles (cl-set-difference paint-roles roles :test #'equal)))
             (baseline (and origin (copy-tree (ebox--paint-origin-baseline origin)))))
        (push (list :text rendered :text-source-p t :start position :end next
                    :newline-count (cl-count ?\n rendered :start position :end next)
                    :direct-role-ids roles :role-ids roles :paint-role-ids paint-roles
                    :layout-dirty-p t :paint-address address
                    :paint-token (and address
                                      (list :baseline (copy-tree baseline)
                                            :roles (copy-tree paint-roles)
                                            :content-owner (plist-get address :content-owner)
                                            :content-index (plist-get address :content-index)))
                    :face-baseline baseline :face-baseline-known-p (and origin t))
              fragments)
        (when origin
          (remove-text-properties position next (list ebox--paint-origin-property nil) rendered))
        (setq position (max next (1+ position)))))
    (ebox-surface--finish-fragment-ledger (nreverse fragments) rendered)))

(defun ebox-surface--fragment-reuse-miss (state reason)
  "Decline fragment reuse for REASON, recording an observed proof boundary."
  (when (and state ebox-incremental--projection-rejections-enabled-p)
    (plist-put state :fragment-reuse-rejection reason))
  (throw 'miss nil))

(defun ebox-surface--incremental-patched-fragments
    (output old-fragments patches &optional state)
  "Splice changed fragment windows into the retained ledger for OUTPUT.
PATCHES must align with retained fragment boundaries. Role changes invalidate
ownership rebasing, not unrelated fragment parsing. STATE receives refined
coordinate evidence only when ordered roles and fragment boundaries agree."
  (when state
    (plist-put state :fragment-reuse-rejection nil)
    (plist-put state :fragment-ownership-changed-p nil))
  (when (and (stringp output) old-fragments patches)
    (catch 'miss
      (let ((remaining old-fragments) (old-cursor 0) (new-cursor 0)
            result origins coordinates changed-roles dirty-next)
        (cl-labels
            ((keep ()
               (let* ((copy (copy-sequence (pop remaining)))
                      (length (- (plist-get copy :end) (plist-get copy :start))))
                 (unless (= (plist-get copy :start) old-cursor)
                   (ebox-surface--fragment-reuse-miss state 'fragment-gap))
                 (plist-put copy :start new-cursor)
                 (plist-put copy :end (+ new-cursor length))
                 (plist-put copy :text output)
                 (plist-put copy :text-source-p t)
                 (when dirty-next (plist-put copy :layout-dirty-p t) (setq dirty-next nil))
                 (push copy result)
                 (setq old-cursor (+ old-cursor length) new-cursor (+ new-cursor length)))))
          (dolist (patch patches)
            (let ((old-start (plist-get patch :old-start)) (old-end (plist-get patch :old-end))
                  (new-start (plist-get patch :new-start)) (new-end (plist-get patch :new-end)))
              (unless (and (integerp old-start) (integerp old-end)
                           (integerp new-start) (integerp new-end)
                           (<= old-cursor old-start old-end) (<= new-cursor new-start new-end)
                           (= (- new-start new-cursor) (- old-start old-cursor))
                           (<= new-end (length output)))
                (ebox-surface--fragment-reuse-miss state 'invalid-coordinates))
              (while (and remaining (<= (plist-get (car remaining) :end) old-start)) (keep))
              (unless (= old-cursor old-start)
                (ebox-surface--fragment-reuse-miss state 'unaligned-start))
              (when result (plist-put (car result) :layout-dirty-p t))
              (let (old-window)
                (while (and remaining (< (plist-get (car remaining) :start) old-end))
                  (let ((fragment (pop remaining)))
                    (unless (and (= (plist-get fragment :start) old-cursor)
                                 (<= (plist-get fragment :end) old-end))
                      (ebox-surface--fragment-reuse-miss state 'unaligned-end))
                    (push fragment old-window)
                    (setq old-cursor (plist-get fragment :end))))
                (unless (= old-cursor old-end)
                  (ebox-surface--fragment-reuse-miss state 'unaligned-end))
                (setq old-window (nreverse old-window))
                (let* ((slice (substring output new-start new-end))
                       (new-window (ebox-surface--rendered-fragments slice))
                       (same-roles
                        (and (= (length old-window) (length new-window))
                             (cl-every (lambda (pair)
                                         (and (equal (plist-get (car pair) :paint-role-ids)
                                                     (plist-get (cdr pair) :paint-role-ids))
                                              (equal (plist-get (car pair) :direct-role-ids)
                                                     (plist-get (cdr pair) :direct-role-ids))))
                                       (cl-mapcar #'cons old-window new-window)))))
                  (unless (cl-every (lambda (fragment)
                                      (and (plist-member fragment :direct-role-ids)
                                           (integerp (plist-get fragment :newline-count))))
                                    old-window)
                    (ebox-surface--fragment-reuse-miss state 'missing-source-facts))
                  (unless (= (apply #'+ (mapcar (lambda (f) (plist-get f :newline-count)) old-window))
                             (apply #'+ (mapcar (lambda (f) (plist-get f :newline-count)) new-window)))
                    (ebox-surface--fragment-reuse-miss state 'line-topology))
                  (unless same-roles (setq changed-roles t))
                  (dolist (new new-window)
                    (let ((old (pop old-window)))
                      (plist-put new :start (+ new-start (plist-get new :start)))
                      (plist-put new :end (+ new-start (plist-get new :end)))
                      (plist-put new :text output)
                      (plist-put new :layout-dirty-p t)
                      (when same-roles
                        (when-let* ((chain (plist-get old :paint-node-chain)))
                          (plist-put new :paint-node-chain chain))
                        (push (list :old-start (plist-get old :start) :old-end (plist-get old :end)
                                    :new-start (plist-get new :start) :new-end (plist-get new :end))
                              coordinates))
                      (push new result)))
                  (push (cons new-start new-end) origins)))
              (setq old-cursor old-end new-cursor new-end dirty-next t)))
          (while remaining (keep)))
        (unless (= new-cursor (length output))
          (ebox-surface--fragment-reuse-miss state 'incomplete-coverage))
        ;; Native ledgers without raw role/newline facts use their ordinary
        ;; materialization route; never guess these facts from derived roles.
        (unless (cl-every (lambda (f) (and (plist-member f :direct-role-ids)
                                          (integerp (plist-get f :newline-count)))) result)
          (ebox-surface--fragment-reuse-miss state 'missing-source-facts))
        (dolist (range origins)
          (remove-text-properties (car range) (cdr range) (list ebox--paint-origin-property nil) output))
        (when state
          (plist-put state :fragment-ownership-changed-p changed-roles)
          (unless changed-roles (plist-put state :content-coordinate-patches (nreverse coordinates))))
        (ebox-surface--finish-fragment-ledger (nreverse result) output)))))

(defun ebox-surface--rebase-coordinate (position patches)
  "Return POSITION rebased through PATCHES, or nil inside a replacement."
  (let ((delta 0))
    (catch 'done
      (dolist (patch patches)
        (let ((old-start (plist-get patch :old-start))
              (old-end (plist-get patch :old-end))
              (new-start (plist-get patch :new-start))
              (new-end (plist-get patch :new-end)))
          (unless (= new-start (+ old-start delta))
            (throw 'done nil))
          (cond
           ((< position old-start) (throw 'done (list (+ position delta))))
           ((= position old-start) (throw 'done (list new-start)))
           ((< position old-end) (throw 'done nil))
           ((= position old-end) (throw 'done (list new-end))))
          (setq delta (+ delta (- new-end new-start)
                         (- old-start old-end)))))
      (list (+ position delta)))))

(defun ebox-surface--rebase-owned-ranges (ranges patches output-length)
  "Return fresh candidate RANGES rebased through PATCHES.
Any range boundary inside replaced text rejects reuse so ownership never
widens heuristically.  The returned cons distinguishes an exact empty result
from a failed proof."
  (catch 'miss
    (let (result)
      (dolist (range ranges)
        (let ((start (ebox-surface--rebase-coordinate
                      (plist-get range :start) patches))
              (end (ebox-surface--rebase-coordinate
                    (plist-get range :end) patches)))
          (unless (and start end (< (car start) (car end))
                       (<= (car end) output-length))
            (throw 'miss nil))
          (push (list :object (plist-get range :object)
                      :start (car start) :end (car end)
                      :tags (copy-tree (plist-get range :tags)))
                result)))
      (cons t (nreverse result)))))

(defun ebox-surface--snapshot-owned-ranges (ranges)
  "Return an immutable client-state snapshot of candidate RANGES."
  (mapcar (lambda (range)
            (list :object (plist-get range :object)
                  :start (plist-get range :start)
                  :end (plist-get range :end)
                  :tags (copy-tree (plist-get range :tags))))
          ranges))

(defun ebox-surface--fragment-metadata (fragments &optional state)
  "Return FRAGMENTS as offsets into the Ebox-owned rendered text.  The mutable
propertized text is intentionally not retained in Ebox client state; paint
projection reads a defensive snapshot from the published buffer only when it
needs the old text.  STATE additionally retains each fragment's complete
paint-owner ancestor chain."
  (let ((offset 0)
        (ebox-surface--paint-node-depth-cache
         (and state (make-hash-table :test #'eql)))
        (ebox-surface--paint-node-chain-cache
         (and state (make-hash-table :test #'equal)))
        metadata)
    (dolist (fragment fragments (nreverse metadata))
      (let* ((source-p (plist-get fragment :text-source-p))
             (text (plist-get fragment :text))
             (length (if source-p
                         (- (plist-get fragment :end)
                            (plist-get fragment :start))
                       (length text)))
             (copy
              (cl-loop for (key value) on fragment by #'cddr
                       unless (eq key :text)
                       append (list key value))))
        (unless source-p
          (plist-put copy :start offset)
          (plist-put copy :end (+ offset length)))
        (when (and state (plist-get copy :paint-role-ids)
                   (not (plist-get copy :paint-node-chain)))
          (plist-put copy :paint-node-chain
                     (copy-sequence
                      (ebox-surface--paint-node-chain
                       state (plist-get copy :paint-role-ids)))))
        (plist-put copy :text-source-p t)
        (push copy metadata)
        (setq offset (+ offset length))))))

(defun ebox-surface--owned-ranges-from-runs
    (context leaf state node-objects region-objects attach-p visit-runs)
  "Attach merged ownership produced by VISIT-RUNS to candidate LEAF.
VISIT-RUNS receives one callback accepting ROLE-IDS, START, END, and optional
layout dependency region ids.
Adjacent ranges merge only when both their owner and opaque tags match."
  (let* ((active (make-hash-table :test #'eq))
         (cache (plist-get state :ownership-cache))
         (base-owners (and (plist-get cache :shared) (plist-get cache :owners)))
         (owner-cache
          (if base-owners (make-hash-table :test #'equal)
            (or (plist-get cache :owners) (make-hash-table :test #'equal))))
         ranges)
    (when cache
      (plist-put cache :owners owner-cache)
      (plist-put cache :shared nil))
    (funcall
     visit-runs
     (lambda (role-ids start end &optional layout-region-ids)
       (let* ((cache-key (if layout-region-ids
                             (cons layout-region-ids role-ids)
                           role-ids))
              (owners (gethash cache-key owner-cache 'ebox/no-owners)))
         (when (eq owners 'ebox/no-owners)
           (setq owners (if base-owners
                            (gethash cache-key base-owners 'ebox/no-owners)
                          'ebox/no-owners))
           (when (eq owners 'ebox/no-owners)
             (setq owners
                   (ebox-surface--fragment-owners
                    role-ids state node-objects region-objects))
             (when layout-region-ids
               (let ((attached (make-hash-table :test #'eq)))
                 (dolist (owner owners) (puthash (car owner) t attached))
                 (dolist (region-id layout-region-ids)
                   (let ((node-id (ebox-runtime-index-get region-id
                                                          (plist-get state :region-node-table))))
                     (while node-id
                       (let ((object (gethash node-id node-objects)))
                         (unless object
                           (error "Ebox layout dependency has no Ebox publication object: %S"
                                  node-id))
                         (unless (gethash object attached)
                           (push (list object '(:ebox/layout-output t)) owners)
                           (puthash object t attached)))
                       (setq node-id
                             (ebox-runtime-index-get node-id (plist-get state :parent-table)))))))))
           (puthash cache-key owners owner-cache))
         (dolist (owner owners)
           (let* ((object (nth 0 owner))
                  (tags (nth 1 owner))
                  ;; One node has only its direct, descendant and layout
                  ;; roles here. Do not allocate a hash table per node.
                  (entry (assoc tags (gethash object active) #'equal))
                  (current (cdr entry)))
             (if (and current (= (plist-get current :end) start))
                 (plist-put current :end end)
               (let ((range (list :object object :start start :end end
                                  :tags tags)))
                 (push range ranges)
                 (if entry
                     (setcdr entry range)
                   (push (cons tags range) (gethash object active))))))))))
    (setq ranges (nreverse ranges))
    (when attach-p
      (ebox--pub-object-attach-content-ranges-owned context leaf ranges))
    ranges))

(defun ebox-surface--owned-ranges
    (context leaf fragments state node-objects region-objects
             &optional attach-p)
  "Attach merged owner ranges for FRAGMENTS to candidate LEAF."
  (ebox-surface--owned-ranges-from-runs
   context leaf state node-objects region-objects attach-p
   (lambda (visit)
     (let ((offset 0))
       (dolist (fragment fragments)
         (let* ((source-p (plist-get fragment :text-source-p))
                (start (if source-p
                           (plist-get fragment :start)
                         offset))
                (end (if source-p
                         (plist-get fragment :end)
                       (+ offset (length (plist-get fragment :text))))))
           (funcall visit (plist-get fragment :role-ids) start end
                    (plist-get fragment :layout-region-ids))
           (setq offset
                 (if source-p
                     end
                   (+ offset (length (plist-get fragment :text)))))))))))

(defun ebox-surface--scroll-owned-ranges
    (context leaf lines state node-objects region-objects attach-p)
  "Attach merged owner ranges for retained scroll LINES to candidate LEAF."
  (ebox-surface--owned-ranges-from-runs
   context leaf state node-objects region-objects attach-p
   (lambda (visit)
     (unless (ebox-surface--map-scroll-fragments
              lines
              (lambda (fragment offset _line-index)
                (funcall visit
                         (plist-get fragment :role-ids)
                         (+ offset (plist-get fragment :start))
                         (+ offset (plist-get fragment :end))
                         (plist-get fragment :layout-region-ids))))
       (error "Ebox retained scroll line lost fragment ownership")))))

(defun ebox-surface--native-owned-ranges
    (context leaf template state node-objects region-objects attach-p)
  "Attach owner ranges from compact native fragment TEMPLATE."
  (ebox-surface--owned-ranges-from-runs
   context leaf state node-objects region-objects attach-p
   (lambda (visit)
     (dotimes (index (length template))
       (let ((record (aref template index)))
         (funcall visit (aref record 3) (aref record 0) (aref record 1)))))))

(defun ebox-surface--materialized-fragment-ledger (state)
  "Return STATE's paint ledger, expanding a native frame only on demand."
  (let* ((ledger (plist-get state :surface-fragments))
         (frame (and (listp ledger) (plist-get ledger :native-frame)))
         (lines (and (listp ledger) (plist-get ledger :scroll-lines))))
    (cond
     (frame (ebox-native-reflow-frame-fragments frame))
     (lines
      (ebox-surface--fragment-metadata
       (or (ebox-surface--scroll-fragment-data lines "")
           (error "Ebox retained scroll lines lost fragment ownership"))
       state))
     (t ledger))))

(defun ebox-surface--formatting-context-reflow-owned-ranges
    (context leaf ranges state node-objects)
  "Replace inferred owner ranges for the reflow context with one block range.
Ancestor-output role propagation can otherwise make a variable-line context
claim the first property run of the following sibling.  The proof already
owns the complete old block, so its candidate scope is the exact new block;
all descendant ranges remain unchanged."
  (let* ((proof (plist-get state :formatting-context-reflow-proof))
         (owner-id (plist-get proof :owner-id))
         (owner (and owner-id (gethash owner-id node-objects)))
         (node (and owner-id (ebox-runtime-index-get owner-id (plist-get state :node-table))))
         (region-id (and node (plist-get node :region-id)))
         (block-start
          (max 0
               (1- (car (plist-get proof :old-block-span)))))
         (block-end (+ block-start
                       (or (plist-get state
                                     :formatting-context-reflow-new-length)
                           0)))
         (filtered
          (cl-remove-if (lambda (range)
                          (eq (plist-get range :object) owner))
                        ranges)))
    (when (and owner region-id (integerp block-start) (> block-end block-start))
      (push (list :object owner :start block-start :end block-end
                  :tags (list :ebox/region-id region-id
                               :ebox/roles '(content-owner content)))
            filtered))
    (setq filtered (nreverse filtered))
    (ebox--pub-object-attach-content-ranges-owned context leaf filtered)
    filtered))

(defun ebox-surface--surface-plan
    (context surface-root output state node-objects region-objects
             &optional transfer-text-p)
  "Return one shared-text Ebox publication plan for OUTPUT and STATE.
NODE-OBJECTS and REGION-OBJECTS supply retained ownership ranges."
  (let* ((scroll-lines
          (and transfer-text-p
               (plist-get state :retained-scroll-content-p)
               (plist-get state :scroll-patch-lines)))
         (fragment-root
          (ebox--pub-object-ensure context surface-root
                            ebox-surface--fragments-key 'ebox/fragments))
         (fragment-data
          (unless scroll-lines
            (or (and (eq output (plist-get state :native-render-output))
                     (plist-get state :native-render-fragment-template))
                (and (eq (plist-get state :projection-kind)
                         'mixed-owner-reflow)
                     (plist-get state :mixed-owner-fragment-data))
                (and (memq (plist-get state :projection-kind)
                           '(span-patch owner-scoped))
                     (plist-get state :span-patch-fragment-data))
                (and (plist-get state :raw-layout-output)
                     (plist-get state :raw-layout-fragments))
                (if (stringp output)
                    (ebox-surface--rendered-fragments output)
                  output))))
         (rendered
          (if (stringp output)
              output
            (if (and fragment-data
                     (plist-get (car fragment-data) :text-source-p))
                (plist-get (car fragment-data) :text)
              (apply #'concat
                     (mapcar (lambda (fragment)
                               (plist-get fragment :text))
                             fragment-data)))))
         (text-leaf
          (ebox--pub-object-ensure context fragment-root
                            ebox-surface--text-key 'ebox/text)))
    (let* ((attach-p
            (not (and transfer-text-p
                      (plist-get state :retained-scroll-content-p))))
           (formatting-reflow-p
            (or (eq (plist-get state :projection-kind)
                    'formatting-context-reflow)
                (and (eq (plist-get state :projection-kind)
                         'mixed-owner-reflow)
                     (eq (plist-get (plist-get state :mixed-owner-proof)
                                    :geometry-kind)
                         'formatting-context-reflow))))
           (native-template-p
            (and (vectorp fragment-data)
                 (eq output (plist-get state :native-render-output))))
           (owned-ranges
            (cond
             (scroll-lines
              (ebox-surface--scroll-owned-ranges
               context text-leaf scroll-lines state node-objects
               region-objects attach-p))
             ((and native-template-p
                   (plist-get state :native-reuse-ownership-p))
              (let ((ranges
                     (plist-get state :native-committed-owned-ranges)))
                (unless ranges
                  (error "Native retained frame has no ownership base"))
                (when attach-p
                  (ebox--pub-object-attach-content-ranges-owned
                   context text-leaf ranges))
                ranges))
             (native-template-p
              ;; Rust already supplied the exact target role template.  Map
              ;; it once to Ebox publication objects instead of guessing target ownership
              ;; by rebasing every old range through every text edit.
              (ebox-surface--native-owned-ranges
               context text-leaf fragment-data state node-objects
               region-objects (and attach-p (not formatting-reflow-p))))
             (t
              (let ((rebased
                     (and (memq (plist-get state :projection-kind)
                                '(span-patch owner-scoped
                                  mixed-owner-reflow))
                          (not formatting-reflow-p)
                          (not (plist-get state :fragment-ownership-changed-p))
                          (not (plist-get state :layer-recompose-p))
                          (plist-get state :previous-surface-owned-ranges)
                          (plist-get state :content-coordinate-patches)
                          (ebox-surface--rebase-owned-ranges
                           (plist-get state :previous-surface-owned-ranges)
                           (plist-get state :content-coordinate-patches)
                           (length rendered)))))
                (if rebased
                    (let ((ranges (cdr rebased)))
                      (when attach-p
                        (ebox--pub-object-attach-content-ranges-owned
                         context text-leaf ranges))
                      ranges)
                  (ebox-surface--owned-ranges
                   context text-leaf fragment-data state node-objects
                   region-objects
                   (and attach-p (not formatting-reflow-p)))))))))
      (when formatting-reflow-p
        (setq owned-ranges
              (ebox-surface--formatting-context-reflow-owned-ranges
               context text-leaf owned-ranges state node-objects)))
      (plist-put state :surface-owned-ranges
                 (if native-template-p
                     owned-ranges
                   (ebox-surface--snapshot-owned-ranges owned-ranges)))
      (when (plist-get state :native-render-p)
        (plist-put state :native-committed-rendered rendered)
        (plist-put state :native-committed-owned-ranges owned-ranges)
        (when native-template-p
          (plist-put state :native-committed-fragment-template fragment-data)))
      (cl-remf state :native-reuse-ownership-p)
      (cl-remf state :native-coordinate-patches)
      (cl-remf state :native-render-output)
      (cl-remf state :native-render-fragments)
      (cl-remf state :native-render-fragment-template)
      (cl-remf state :previous-surface-owned-ranges)
      (cl-remf state :fragment-ownership-changed-p)
    (let* ((plan-text
            (if (or transfer-text-p
                    (plist-get state :native-render-p)
                    (plist-get state :mixed-owner-content-p)
                    (plist-get state :span-patch-content-p))
                ;; Scroll output is a fresh renderer-owned string. The
                ;; owned-result path copies the string spine once while
                ;; rendering the plan; recursively snapshotting every
                ;; property value here duplicated the hot scroll work.
                rendered
              (ebox-surface--candidate-plan-text
               rendered (plist-get state :render-owned-text-values))))
           (plan
           (ebox--pub-surface-plan-create-owned
            :key ebox-surface--root-key :kind 'ebox/surface
            :children
            (list (ebox--pub-surface-plan-create-owned
                   :key ebox-surface--fragments-key :kind 'ebox/fragments
                   :children
                   (list (ebox--pub-surface-plan-create-owned
                          :key ebox-surface--text-key :kind 'ebox/text
                          :text plan-text
                          :capability 'content))
                   :capability 'content))
            :capability 'content)))
      (plist-put state :surface-fragments
                 (cond
                  ((plist-get state :native-render-frame)
                   (list :native-frame (plist-get state :native-render-frame)))
                  (scroll-lines
                   (list :scroll-lines (copy-sequence scroll-lines)))
                  ((or (plist-get state :mixed-owner-content-p)
                       (plist-get state :span-patch-content-p))
                   ;; Mixed projection already produced fresh offset-only
                   ;; fragment plists with retained paint chains.
                   fragment-data)
                  (t (ebox-surface--fragment-metadata fragment-data state))))
      (cl-remf state :native-render-frame)
      (cl-remf state :mixed-owner-fragment-data)
      (cl-remf state :mixed-owner-content-p)
      (cl-remf state :span-patch-fragment-data)
      (cl-remf state :span-patch-content-p)
      (cl-remf state :scroll-patch-lines)
      (let ((rendered-length (length rendered)))
        (list plan rendered owned-ranges
              (list (list :object text-leaf :start 0 :end rendered-length
                          :props nil :tags nil :leaf t)
                    (list :object fragment-root :start 0 :end rendered-length
                          :props nil :tags nil :leaf nil)
                    (list :object surface-root :start 0 :end rendered-length
                          :props nil :tags nil :leaf nil))))))))

(defconst ebox-surface--paint-base-roles
  '(content content-owner pt pb pl pr bl br)
  "Rendered roles that identify a box's painted border-box surface.")

(defun ebox-surface--node-depth (state node-id)
  "Return NODE-ID depth in Ebox runtime STATE."
  (let ((cached
         (and ebox-surface--paint-node-depth-cache
              (gethash node-id ebox-surface--paint-node-depth-cache
                       ebox-surface--paint-node-depth-missing))))
    (if (and cached
             (not (eq cached ebox-surface--paint-node-depth-missing)))
        cached
      (let ((key node-id)
            (parents (plist-get state :parent-table))
            (depth 0))
        (while (setq node-id (and node-id (ebox-runtime-index-get node-id parents)))
          (cl-incf depth))
        (when ebox-surface--paint-node-depth-cache
          (puthash key depth ebox-surface--paint-node-depth-cache))
        depth))))

(defun ebox-surface--paint-node-chain (state role-ids)
  "Return the deepest rendered node and its ancestors for ROLE-IDS."
  (let ((cached
         (and ebox-surface--paint-node-chain-cache
              (gethash role-ids ebox-surface--paint-node-chain-cache
                       ebox-surface--paint-node-chain-missing))))
    (if (and cached (not (eq cached ebox-surface--paint-node-chain-missing)))
        cached
      (let ((region-nodes (plist-get state :region-node-table))
            (parents (plist-get state :parent-table)) deepest deepest-depth)
        (dolist (entry role-ids)
          (when-let* ((node-id
                       (ebox-runtime-index-get
                        (cdr entry) region-nodes)))
            (let ((depth (ebox-surface--node-depth state node-id)))
              (when (or (null deepest-depth) (> depth deepest-depth))
                (setq deepest node-id deepest-depth depth)))))
        (let (chain)
          (while deepest
            (push deepest chain)
            (setq deepest (ebox-runtime-index-get deepest parents)))
          (setq chain (nreverse chain))
          (when ebox-surface--paint-node-chain-cache
            (puthash role-ids chain ebox-surface--paint-node-chain-cache))
          chain)))))

(defun ebox-surface--box-face-contributions (box)
  "Return BOX typography and color contributions in render order."
  (let (faces)
    (when (ebox-style--text-paint-owner-p box)
      (when-let* ((font (ebox-buffer--font-face box)))
        (push font faces))
      (when-let* ((decoration
                   (ebox-buffer--text-decoration-face box)))
        (push decoration faces))
      (when-let* ((color (plist-get box :color)))
        (push (ebox-buffer--color-face color 'foreground) faces)))
    (when-let* ((background (plist-get box :bgcolor)))
      (push (ebox-buffer--color-face background 'background) faces))
    (nreverse faces)))

(defun ebox-surface--region-face-contributions (box roles ancestor-p)
  "Return BOX face contributions for ROLES.
ANCESTOR-P means BOX wraps a more specific rendered surface."
  (let (faces)
    (cond
     ((memq 'overflow-foreground roles)
      (when-let* ((color (plist-get box :color)))
        (push (ebox-buffer--color-face color 'foreground) faces)))
     ((memq 'bl roles)
      (push (ebox-buffer-side-border-face
             (plist-get box :border-left-color)) faces))
     ((memq 'br roles)
      (push (ebox-buffer-side-border-face
             (plist-get box :border-right-color)) faces))
     ((or ancestor-p
          (cl-intersection roles '(content content-owner pt pb pl pr)))
      (setq faces (ebox-surface--box-face-contributions box))))
    (when (and (memq 'bt roles)
               (> (or (ebox-get box :border-top-pixel) 0) 0))
      (setq faces
            (append faces
                    (list (ebox-buffer--color-face
                           (plist-get box :border-top-color) 'overline)))))
    (when (and (memq 'bb roles)
               (> (or (ebox-get box :border-bottom-pixel) 0) 0))
      (setq faces
            (append
             faces
             (list (ebox-buffer--color-face
                    (plist-get box :border-bottom-color) 'underline)))))
    faces))

(defconst ebox-surface--node-face-cache-missing
  (make-symbol "ebox-node-face-cache-missing")
  "Sentinel distinguishing a cached nil node face contribution from a miss.")

(defun ebox-surface--face-contributions (state role-ids &optional node-cache)
  "Return semantic Ebox face contributions for ROLE-IDS in STATE."
  (let ((nodes (plist-get state :node-table)) result first)
    (setq first t)
    (dolist (node-id (ebox-surface--paint-node-chain state role-ids))
      (when-let* ((node (ebox-runtime-index-get node-id nodes))
                  (box (ebox-fragment-style-source-node node)))
        (let* ((region-id (plist-get box :region-id))
               (roles
                (cl-loop for (role . owner) in role-ids
                         when (equal owner region-id) collect role))
               (ancestor-p (not first))
               (key (and node-cache (list node-id ancestor-p roles)))
               (cached
                (and node-cache
                     (gethash key node-cache
                              ebox-surface--node-face-cache-missing)))
               (faces
                (if (and node-cache
                         (not (eq cached
                                  ebox-surface--node-face-cache-missing)))
                    cached
                  (let ((computed
                         (ebox-surface--region-face-contributions
                          box roles ancestor-p)))
                    (when node-cache
                      (puthash key computed node-cache))
                    computed))))
          (dolist (face faces)
            (push face result))
          (setq first nil))))
    (nreverse result)))

(defconst ebox-surface--face-cache-missing
  (make-symbol "ebox-face-cache-missing")
  "Sentinel distinguishing a cached nil face contribution from a miss.")

(defun ebox-surface--cached-face-contributions
    (cache state role-ids &optional node-cache)
  "Return CACHE's semantic face contribution for STATE and ROLE-IDS."
  (let ((value (gethash role-ids cache ebox-surface--face-cache-missing)))
    (if (eq value ebox-surface--face-cache-missing)
        (let ((computed
               (ebox-surface--face-contributions state role-ids node-cache)))
          (puthash role-ids computed cache)
          computed)
      value)))

(defun ebox-surface--face-list (face)
  "Return FACE as an ordered list of face entries."
  (cond ((null face) nil)
        ((and (listp face) (keywordp (car-safe face))) (list face))
        ((listp face) (copy-sequence face))
        (t (list face))))

(defun ebox-surface--face-value (entries)
  "Return canonical face value represented by ENTRIES."
  (pcase entries
    ('() nil)
    (`(,entry) entry)
    (_ entries)))

(defun ebox-surface--face-baseline (face contributions)
  "Remove trailing Ebox CONTRIBUTIONS from FACE and return its baseline."
  (let* ((entries (ebox-surface--face-list face))
         (count (length contributions))
         (baseline entries))
    ;; A prior paint projection may have appended the same semantic Ebox
    ;; contribution more than once.  Peel every matching suffix layer before
    ;; composing the new state; caller-provided face entries remain untouched.
    (while (and (> count 0)
                (>= (length baseline) count)
                (equal (last baseline count) contributions))
      (setq baseline
            (seq-take baseline (- (length baseline) count))))
    (ebox-surface--face-value baseline)))

(defun ebox-surface--compose-face (baseline contributions)
  "Append Ebox CONTRIBUTIONS to BASELINE using Emacs face semantics."
  (let ((sample (make-string 1 ?x)))
    (when baseline
      (put-text-property 0 1 'face baseline sample))
    (dolist (face contributions)
      (add-face-text-property 0 1 face t sample))
    (get-text-property 0 'face sample)))

(defun ebox-surface--layer-paint-contributions (output fragments state)
  "Return baseline FRAGMENTS and retain ordered paint layers in STATE.  OUTPUT
supplies source-backed fragment text.  Ebox publication receives the
resulting relative face contributions and performs the final merge during
prepare."
  (let ((face-cache (make-hash-table :test #'equal))
        (node-cache (make-hash-table :test #'equal))
        (offset 0)
        contributions result)
    (dolist (fragment fragments)
      (let* ((copy (copy-sequence fragment))
             (source-p (plist-get fragment :text-source-p))
             (text
              (if source-p
                  (substring output
                             (plist-get fragment :start)
                             (plist-get fragment :end))
                (copy-sequence (plist-get fragment :text))))
             (length (length text))
             (roles (plist-get fragment :paint-role-ids))
             (affected-p (plist-member fragment :old-paint-role-ids))
             (faces
              (and affected-p
                   (ebox-surface--cached-face-contributions
                    face-cache state roles node-cache)))
             (baseline
              (and affected-p
                   (if (plist-get fragment :face-baseline-known-p)
                       (copy-tree (plist-get fragment :face-baseline))
                     (and (> length 0)
                          (ebox-surface--face-baseline
                           (get-text-property 0 'face text) faces))))))
        (when (and affected-p (> length 0))
          (if baseline
              (put-text-property 0 length 'face baseline text)
            (remove-text-properties 0 length '(face nil) text))
          (when-let* ((face (ebox-surface--face-value faces)))
            (let ((props (list 'face (copy-tree face))))
              (if (and contributions
                       (= (plist-get (car contributions) :end) offset)
                       (equal-including-properties
                        (plist-get (car contributions) :props) props))
                  (plist-put (car contributions) :end (+ offset length))
                (push (list :start offset :end (+ offset length)
                            :props props)
                      contributions)))))
        (ebox-interaction--refresh-hover!
         text 0 length
         (and affected-p (ebox-surface--compose-face baseline faces)) state)
        (plist-put copy :text text)
        (plist-put copy :text-source-p nil)
        (plist-put copy :start offset)
        (plist-put copy :end (+ offset length))
        (when affected-p
          (plist-put copy :face-baseline (copy-tree baseline))
          (plist-put copy :face-baseline-known-p t))
        (cl-remf copy :old-paint-role-ids)
        (push copy result)
        (setq offset (+ offset length))))
    (plist-put state :paint-property-contributions
               (nreverse contributions))
    (nreverse result)))

(defun ebox-surface--fragment-has-region-role-p
    (fragment region-id roles)
  "Return non-nil when FRAGMENT carries REGION-ID under any of ROLES."
  (cl-some (lambda (entry)
             (and (equal (cdr entry) region-id)
                  (memq (car entry) roles)))
           (plist-get fragment :paint-role-ids)))

(defun ebox-surface--horizontal-border-line (fragments region-id bottom-p)
  "Return REGION-ID top or BOTTOM-P anchor line from FRAGMENTS."
  (let (lines)
    (dolist (fragment fragments)
      (when (ebox-surface--fragment-has-region-role-p
             fragment region-id ebox-surface--paint-base-roles)
        (push (plist-get fragment :line) lines)))
    (when lines (apply (if bottom-p #'max #'min) lines))))

(defun ebox-surface--set-horizontal-border-role
    (fragments region-id role enabled)
  "Set REGION-ID horizontal border ROLE to ENABLED in FRAGMENTS."
  (let ((line (ebox-surface--horizontal-border-line
               fragments region-id (eq role 'bb)))
        (property (alist-get role ebox-region-types)))
    (dolist (fragment fragments)
      (let* ((anchor-p
              (and enabled (equal (plist-get fragment :line) line)
                   (ebox-surface--fragment-has-region-role-p
                    fragment region-id ebox-surface--paint-base-roles)))
             (pair (cons role region-id))
             (previous-roles (plist-get fragment :role-ids)))
        (dolist (key '(:paint-role-ids :role-ids))
          (let* ((roles (cl-remove pair (plist-get fragment key) :test #'equal))
                 (owned-p
                  (or (eq key :paint-role-ids)
                      (cl-some
                       (lambda (entry)
                         (and (equal (cdr entry) region-id)
                              (memq (car entry) ebox-surface--paint-base-roles)))
                       roles))))
            (plist-put fragment key
                       (if (and anchor-p owned-p)
                           (append roles (list pair)) roles))))
        (unless (equal previous-roles (plist-get fragment :role-ids))
          ;; This painter changes ownership properties after parsing. Its
          ;; derived roles remain authoritative for this paint publication;
          ;; a later geometry splice must refresh the raw source facts.
          (cl-remf fragment :direct-role-ids))
        (when (> (length (plist-get fragment :text)) 0)
          (if-let* ((owner
                    (cdr (cl-find role
                                  (plist-get fragment :role-ids)
                                  :key #'car :test #'eq :from-end t))))
              (put-text-property 0 (length (plist-get fragment :text))
                                 property owner (plist-get fragment :text))
            (remove-text-properties
             0 (length (plist-get fragment :text))
             (list property nil) (plist-get fragment :text)))))))
  fragments)

(defun ebox-surface--paint-border-topology (fragments state dirty-set)
  "Return FRAGMENTS with horizontal border roles updated from STATE."
  (let ((nodes (plist-get state :node-table)))
    (dolist (dirty dirty-set fragments)
      (when-let* ((node (ebox-runtime-index-get (plist-get dirty :node-id) nodes))
                  (box (ebox-fragment-style-source-node node))
                  (region-id (plist-get box :region-id)))
        (dolist (entry '(((:border-top-width :border-top-style)
                          bt :border-top-pixel)
                         ((:border-bottom-width :border-bottom-style)
                          bb :border-bottom-pixel)))
          (when (cl-intersection (car entry)
                                 (plist-get dirty :changed-keys))
            (ebox-surface--set-horizontal-border-role
             fragments region-id (cadr entry)
             (> (or (plist-get box (caddr entry)) 0) 0))))))))

(defun ebox-surface--repaint-fragment
    (fragment old-state new-state &optional old-face-cache new-face-cache)
  "Return FRAGMENT with Ebox paint recomputed from OLD-STATE to NEW-STATE."
  (let* ((text (copy-sequence (plist-get fragment :text)))
         (old-roles (plist-get fragment :old-paint-role-ids))
         (new-roles (plist-get fragment :paint-role-ids))
         (old-faces
          (if old-face-cache
              (ebox-surface--cached-face-contributions
               old-face-cache old-state old-roles)
            (ebox-surface--face-contributions old-state old-roles)))
         (new-faces
          (if new-face-cache
              (ebox-surface--cached-face-contributions
               new-face-cache new-state new-roles)
            (ebox-surface--face-contributions new-state new-roles)))
         (baseline (and (> (length text) 0)
                        (if (plist-get fragment :face-baseline-known-p)
                            (copy-tree (plist-get fragment :face-baseline))
                          (ebox-surface--face-baseline
                           (get-text-property 0 'face text) old-faces))))
         (unchanged (and (equal old-roles new-roles)
                         (equal old-faces new-faces)))
         (face (and (not unchanged)
                    (ebox-surface--compose-face baseline new-faces))))
    (when (and (not unchanged) (> (length text) 0))
      (if face
          (put-text-property 0 (length text) 'face face text)
        (remove-text-properties 0 (length text) '(face nil) text)))
    (ebox-interaction--refresh-hover! text 0 (length text) nil new-state)
    (plist-put fragment :text text)
    (cl-remf fragment :old-paint-role-ids)
    fragment))

(defun ebox-surface--paint-fragments
    (old-state new-state dirty-set old-text)
  "Return OLD-STATE fragments repainted for NEW-STATE and DIRTY-SET.  OLD-TEXT
is a defensive snapshot of the published Ebox publication content."
  (unless (stringp old-text)
    (error "Ebox paint projection has no published Ebox publication text"))
  (let ((fragments
         (mapcar
          (lambda (fragment)
            (let* ((copy (copy-tree fragment))
                   (text (substring old-text
                                    (plist-get fragment :start)
                                    (plist-get fragment :end))))
              (plist-put copy :text text)
              (plist-put copy :start 0)
              (plist-put copy :end (length text))
              (cl-remf copy :text-source-p)
              (plist-put copy :old-paint-role-ids
                         (copy-tree (plist-get fragment :paint-role-ids)))
              copy))
          (ebox-surface--materialized-fragment-ledger old-state))))
    (unless fragments
      (error "Ebox paint projection has no published fragment topology"))
    (if (and dirty-set
             (cl-every
              (lambda (entry)
                (and (eq (plist-get entry :dirty-kind) 'metadata)
                     (null (plist-get entry :changed-keys))))
              dirty-set))
        ;; The planner admitted this route only after comparing the complete
        ;; computed style closure. Selector facts still publish, but replaying
        ;; ancestor paint contributions cannot change any fragment here.
        (mapcar (lambda (fragment)
                  (cl-remf fragment :old-paint-role-ids)
                  fragment)
                fragments)
      (ebox-surface--paint-border-topology fragments new-state dirty-set)
      (mapcar (lambda (fragment)
                (ebox-surface--repaint-fragment fragment old-state new-state))
              fragments))))

(defun ebox-surface--refresh-paint-snapshots (state dirty-set)
  "Refresh paint-significant layout snapshots in STATE for DIRTY-SET."
  (let ((nodes (plist-get state :node-table))
        (snapshots (plist-get state :layout-snapshots)))
    (when (hash-table-p snapshots)
      (dolist (dirty dirty-set)
        (when-let* ((node-id (plist-get dirty :node-id))
                    (node (ebox-runtime-index-get node-id nodes))
                    (snapshot (gethash node-id snapshots)))
          (plist-put snapshot :style-signature
                     (ebox-fragment-node-style-signature node)))))
    state))

(defun ebox-surface--apply-state-overrides (state overrides)
  "Apply plist OVERRIDES to candidate runtime STATE and return STATE."
  (while overrides
    (setq state (plist-put state (pop overrides) (pop overrides))))
  state)

(defun ebox-surface--apply-scroll-offsets (root offsets)
  "Apply surface-scoped scroll OFFSETS to matching boxes below ROOT."
  (cl-labels
      ((visit (node)
         (when (and (listp node) (not (stringp node)))
           (when (eq (plist-get node :ebox-type) 'box)
             (when-let* ((region-id (plist-get node :region-id))
                         (entry (assq region-id offsets)))
               (ebox-put node :scroll-offset (cdr entry))))
           (dolist (child (ebox-tree--children-raw node))
             (visit child)))))
    (visit root))
  root)

(defun ebox-surface--context-axes (root)
  "Return ROOT's exact viewport dependency axes without shared caches."
  (let ((ebox--viewport-dependent-node-ids-cache
         (make-hash-table :test 'eq))
        (ebox--viewport-dependent-subtree-cache
         (make-hash-table :test 'eq))
        (ebox--viewport-height-dependent-subtree-cache
         (make-hash-table :test 'eq)))
    (ebox--viewport-dependent-node-id-axes root)))

(defun ebox-surface--projection-preserves-context-axes-p
    (previous-state state-overrides projection-kind)
  "Return non-nil when a proven projection preserves viewport dependency axes.
PREVIOUS-STATE must own a completed axis index.  STATE-OVERRIDES must carry
a strict owner proof whose changes are limited to content, Ebox publication
surface properties, or paint.  Those values can change measurement or
publication, but cannot introduce or remove a viewport expression or node
identity."
  (let ((dirty-set
         (pcase projection-kind
           ('mixed-owner-reflow
            (plist-get (plist-get state-overrides :mixed-owner-proof)
                       :dirty-set))
           ((or 'span-patch 'owner-scoped)
            (and (plist-get state-overrides :owner-scoped-proofs)
                 (plist-get state-overrides :span-patch-dirty-set))))))
    (and (or dirty-set (eq projection-kind 'metadata))
         (plist-get previous-state :viewport-dependent-node-ids-ready)
         (plist-member previous-state :viewport-dependent-node-id-axes)
         (cl-every
          (lambda (entry)
            (cl-every
             (lambda (key)
               (or (memq key '(:content :surface-properties))
                   (memq key ebox--paint-style-signature-keys)))
             (plist-get entry :changed-keys)))
          dirty-set))))

(defun ebox-surface--projection-state
    (root previous-state state-overrides projection-kind
           stylesheet-active-p cascade-required-p axes viewport-width
           viewport-height display-signature scroll-offsets)
  "Build candidate STATE with the mounted context values installed."
  (let ((state
         (ebox-surface--apply-state-overrides
          (if (memq projection-kind '(paint metadata))
              (copy-sequence previous-state)
            (ebox--new-buffer-render-state root))
          (copy-sequence state-overrides))))
    (cl-remf state :paint-property-contributions)
    (cl-remf state :span-patch-retained-owned-ranges)
    (plist-put state :fractional-pixel-output-p
               (plist-get previous-state :fractional-pixel-output-p))
    (plist-put state :root-node root)
    (plist-put state :layered-p
               (if projection-kind
                   (or (plist-get previous-state :layered-p)
                       (cl-some (lambda (proof)
                                  (plist-get proof :layer-recompose-p))
                                (plist-get state :owner-scoped-proofs)))
                 (and (fboundp 'ebox-layer-subtree-p)
                      (ebox-layer-subtree-p root))))
    (plist-put state :root-portals-p
               (if projection-kind
                   (or (plist-get previous-state :root-portals-p)
                       (and (plist-get state :layer-recompose-p)
                            (ebox-layer-portals-p root)))
                 (and (fboundp 'ebox-layer-portals-p)
                      (ebox-layer-portals-p root))))
    (when (plist-get state :native-sync-confirmed-p)
      (ebox-native-commit-attach-confirmed-base previous-state state))
    (plist-put state :projection-kind projection-kind)
    (plist-put state :cascade-active-p stylesheet-active-p)
    (plist-put state :cascade-required-p cascade-required-p)
    (when (and (memq projection-kind
                     '(span-patch owner-scoped mixed-owner-reflow))
               (plist-get previous-state :surface-owned-ranges))
      (plist-put state :previous-surface-owned-ranges
                 (plist-get previous-state :surface-owned-ranges)))
    (when axes
      (plist-put state :viewport-width viewport-width)
      (plist-put state :viewport-height viewport-height)
      (plist-put state :display-signature display-signature)
      (plist-put state :viewport-dependent-node-id-axes axes)
      (plist-put state :viewport-dependent-node-ids
                 (delete-dups (copy-sequence
                               (append (car axes) (cdr axes)))))
      (plist-put state :viewport-dependent-node-ids-ready t)
      (ebox-surface--apply-scroll-offsets root scroll-offsets))
    state))

(defun ebox-surface--unpainted-interaction-p (state rendered interaction)
  "Return whether STATE projects INTERACTION without accessible painted output."
  (let ((source (plist-get state :source-index)) owner)
    (ebox-runtime-index-map
     (lambda (id node)
       (when-let* ((handle (ebox-tree-node-source-handle node))
                   (record (ebox-source--index-record source handle)))
         (when (member interaction (ebox-source-record-interaction-states record)) (setq owner id))))
     (plist-get state :node-table))
    (and owner
         (not
          (and (ebox-interaction--focus-visible-p state owner)
               (catch 'painted
                 (let ((position 0) (limit (length rendered))
                       (ebox-surface--paint-node-chain-cache nil))
                   (while (< position limit)
                     (let ((end (next-property-change position rendered limit)))
                       (while (and (< position end) (eq (aref rendered position) ?\n))
                         (setq position (1+ position)))
                       (when (and (< position end)
                                  (not (invisible-p
                                        (ensure-list (get-text-property position 'invisible rendered))))
                                  (not (equal (get-text-property position 'display rendered) ""))
                                  (member owner
                                          (ebox-surface--paint-node-chain
                                           state (ebox-surface--role-ids-at rendered position))))
                         (throw 'painted t))
                       (setq position end))))))))))

(defun ebox-surface--project
    (context source previous-state preserve-identities-p state-overrides
             signals projection-kind source-isolated-p source-path-copied-p)
  "Project SOURCE in CONTEXT using PREVIOUS-STATE and identity policy.
PRESERVE-IDENTITIES-P retains existing Ebox node and region identities.
SIGNALS, when non-nil, supplies the mounted surface's host context.
PROJECTION-KIND may select a proven non-spatial projection.
SOURCE-ISOLATED-P means SOURCE is a private candidate owned by the current
publication attempt; it is safe to clear its transient attachments in place.
SOURCE-PATH-COPIED-P means SOURCE shares untouched Ebox nodes with the
published runtime and must be consumed without clearing those shared nodes."
  (when (plist-get previous-state :computed-styles-stale-p)
    ;; A prepared source write leaves immutable computed styles and their
    ;; inherited projections as stale derived data.  This ordinary boundary
    ;; owns a complete cold rebuild; never reuse local output or old caches.
    (let ((source-index (plist-get state-overrides :source-index)))
      (setq projection-kind nil source-isolated-p nil source-path-copied-p nil
            state-overrides
            (cl-loop for (key value) on state-overrides by #'cddr
                     when (memq key '(:source-base-index
                                      :viewport-width :viewport-height
                                      :runtime-revision :display-signature
                                      :logical-candidate-p :detached-identity-history))
                     append (list key value)))
      ;; The rebuild projects a copied root.  Retain the supplied records, but
      ;; derive document-order entries and subjects from the copied nodes.
      (when source-index
        (setq state-overrides
              (plist-put state-overrides :source-base-index source-index)))))
  (if (stringp source)
      (let ((object
             (ebox--pub-object-ensure context nil ebox-surface--root-key
                               'ebox/string)))
        (ignore object)
        (ebox--pub-surface-result-create
         (ebox--pub-surface-plan-create
          :key ebox-surface--root-key :kind 'ebox/string
          :text source :capability 'content)))
      (let* ((ebox-surface--rebuilding-computed-styles-p
              (plist-get previous-state :computed-styles-stale-p))
             (scroll-patch-p (eq projection-kind 'scroll-patch))
             (scroll-input-stable-p
              (and scroll-patch-p previous-state preserve-identities-p
                   (plist-get state-overrides :scroll-state-transaction)
                   (plist-get state-overrides :runtime-index-prepared-p)
                   (equal (plist-get source :node-id)
                          (plist-get (plist-get previous-state :root-node) :node-id))
                   (equal (plist-get state-overrides :display-signature)
                          (plist-get previous-state :display-signature))))
             (initial-native-p
              (and (null previous-state)
                   (null projection-kind)
                   (require 'ebox-native-reflow nil t)
                   (ebox-native-reflow-layout-ready-p)))
             (scroll-fast-p
              (and scroll-patch-p
                   (let ((table (plist-get state-overrides
                                           :scroll-state-table))
                         (fast t))
                     (if (hash-table-p table)
                         (maphash
                         (lambda (_region-id scroll-state)
                            (unless
                                (ebox--scroll-state-retained-window-ready-p
                                 scroll-state)
                              (setq fast nil)))
                          table)
                       (setq fast nil))
                     fast)))
             (stylesheet-active-p
              (if scroll-input-stable-p
                  (plist-get previous-state :cascade-active-p)
                (ebox-style-cascade-active-p)))
             (retained-runtime-source-p
              (and previous-state
                   preserve-identities-p
                   (eq source (plist-get previous-state :root-node))
                   (or (memq projection-kind
                             '(metadata viewport-reflow
                               viewport-reflow-mixed-scroll))
                       (and (eq projection-kind 'native-frame)
                            (plist-get state-overrides
                                       :native-topology-stable-p)))
                   (plist-get state-overrides :runtime-index-prepared-p)
                   (plist-get state-overrides
                              :viewport-dependent-node-ids-ready)
                   (plist-member state-overrides
                                 :viewport-dependent-node-id-axes)))
             (retained-native-source-p
              (and retained-runtime-source-p
                   (eq projection-kind 'native-frame)))
             (root (cond
                    ((plist-get previous-state :computed-styles-stale-p)
                     (let ((copy (ebox-surface--candidate-root source preserve-identities-p)))
                       (cl-labels
                           ((clear-style (node)
                              (when (plist-member node :ebox-computed-style)
                                (plist-put node :ebox-computed-style nil))
                              (when (plist-member node :ebox-candidate-computed-style-p)
                                (plist-put node :ebox-candidate-computed-style-p nil))
                              (ebox-tree-for-each-direct-child node #'clear-style)))
                         (clear-style copy))
                       copy))
                    ;; A proven selector-only candidate shares the published
                    ;; tree.  Its new facts live in the source index; clearing
                    ;; attachments would mutate the accepted generation.
                    ((and retained-runtime-source-p
                          (eq projection-kind 'metadata)) source)
                    (source-path-copied-p source)
                    (source-isolated-p
                     (if (and (eq projection-kind 'native-frame)
                              (plist-get state-overrides
                                         :native-topology-stable-p))
                         source
                       (ebox-surface--clear-runtime-attachments source)))
                    (retained-native-source-p source)
                    (t
                     (ebox-surface--candidate-root
                      source preserve-identities-p
                      retained-runtime-source-p))))
             (state-overrides
              (if (and (memq projection-kind
                              '(viewport-reflow viewport-reflow-mixed-scroll))
                       (not source-isolated-p)
                       (not source-path-copied-p))
                  (ebox-surface--isolated-viewport-overrides state-overrides)
                state-overrides))
             (source-base-index
              (plist-get state-overrides :source-base-index))
             (source-index
              (or (plist-get state-overrides :source-index)
                  (and source-base-index
                       (ebox-tree-source-index
                        root t ebox--render-root-parent-kind
                        source-base-index))
                  (and (eq root (plist-get previous-state :root-node))
                       (plist-get previous-state :source-index))
                  (ebox-tree-source-index
                   root t ebox--render-root-parent-kind)))
             (_source-index
              (progn
                (setq state-overrides (copy-sequence state-overrides))
                ;; A copied runtime root starts a new EQ memo generation on
                ;; every producer evaluation, including ordinary fallbacks.
                ;; Already isolated or path-copied sources keep their prepared
                ;; seed/prune contract and same-candidate native handoff.
                (unless (eq root source)
                  (dolist (key '(:render-signature-cache
                                 :viewport-height-dependent-subtree-cache
                                 :flex-content-min-widths))
                    (setq state-overrides
                          (plist-put state-overrides key
                                     (make-hash-table :test 'eq)))))
                (cl-remf state-overrides :source-base-index)
                (setq state-overrides
                      (plist-put state-overrides :source-index source-index))))
             (_selector-view-index
              (progn
                (setq source-index
                      (ebox-tree-style-source-index root source-index ebox--render-root-parent-kind))
                (plist-put state-overrides :source-index source-index)))
             (ebox-selector-view--current (ebox-source--index-selector-view source-index))
         (ebox-selector-view--topology (ebox-source--index-selector-topology source-index))
             (ebox-style--scopes (ebox-style-source-scopes source-index))
             (_local-cascade
              (when ebox-style--scopes
                (setq stylesheet-active-p t)))
             (retained-inline-styles-p
              (and source-path-copied-p
                   (memq projection-kind '(span-patch owner-scoped))
                   (plist-get state-overrides
                              :computed-participation-validated-p)
                   (let ((dirty-set
                          (plist-get state-overrides :span-patch-dirty-set)))
                     (and dirty-set
                          (cl-every
                           (lambda (entry)
                             (equal (plist-get entry :changed-keys) '(:content)))
                           dirty-set)))))
             (inline-inheritance-required-p
              (unless (or scroll-input-stable-p retained-runtime-source-p
                          retained-inline-styles-p)
                (ebox-surface--inline-inheritance-required-p
                 root source-index)))
             (author-style-pending-p
              (> (ebox-tree-author-style-count root) 0))
             (cascade-required-p
              (if (or scroll-input-stable-p retained-runtime-source-p
                      retained-inline-styles-p)
                  (plist-get previous-state :cascade-required-p)
                (or stylesheet-active-p
                    inline-inheritance-required-p)))
             (style-required-p
              (if scroll-input-stable-p
                  cascade-required-p
                (or (plist-get previous-state :computed-styles-stale-p)
                    cascade-required-p
                    author-style-pending-p
                    (plist-get previous-state :cascade-active-p)
                    (plist-get previous-state :cascade-required-p))))
             (surface-display-signature
              (and signals
                   (ebox--pub-signal-read
                    (ebox-surface--signals-display signals))))
             ;; Font resolution, text measurement, and final paint must see
             ;; one immutable host capability for the whole transaction.
             (ebox--render-display-signature
              (or surface-display-signature
                  ebox--render-display-signature
                  (ebox--display-signature)))
             (ebox-surface--font-window
              (or ebox-surface--font-window
                  (ebox-surface--buffer-display-window
                   (current-buffer))))
             (_font-capability-projection
              (when (and previous-state surface-display-signature
                         (not (equal
                               surface-display-signature
                               (plist-get previous-state
                                          :display-signature))))
                (ebox-surface--refresh-font-projections root)))
             (projection
             (ebox-surface--projection-start
               context root style-required-p projection-kind previous-state
               state-overrides)))
      (setq source-index (plist-get projection :source-index)
            state-overrides
            (plist-put state-overrides :source-index source-index))
      (unless (or source-isolated-p source-path-copied-p
                  retained-runtime-source-p)
        (ebox-surface--reconcile-candidate
         root source-index previous-state))
             (let* ((context-axis-facts
                     (and
                      signals
                      (cond
                       ((and scroll-input-stable-p
                             (plist-get previous-state
                                        :viewport-dependent-node-ids-ready)
                             (plist-member
                              previous-state
                              :viewport-dependent-node-id-axes))
                        previous-state)
                       ((and (memq projection-kind
                                   '(viewport-reflow
                                     viewport-reflow-mixed-scroll))
                             (plist-get
                              state-overrides
                              :viewport-dependent-node-ids-ready)
                             (plist-member
                              state-overrides
                              :viewport-dependent-node-id-axes))
                        ;; The viewport planner owns this topology proof and
                        ;; copies its exact axis partition into the candidate
                        ;; contract.  Rewalking the same immutable tree here
                        ;; would only derive the identical fact a second time.
                        state-overrides)
                       ((and (eq projection-kind 'native-frame)
                             (plist-get state-overrides
                                        :native-topology-stable-p)
                             (plist-get state-overrides
                                        :viewport-dependent-node-ids-ready)
                             (plist-member
                              state-overrides
                              :viewport-dependent-node-id-axes))
                        state-overrides)
                       ((ebox-surface--projection-preserves-context-axes-p
                         previous-state state-overrides projection-kind)
                        previous-state))))
                    (reuse-context-axes-p (not (null context-axis-facts)))
             (axes
              (and signals
                   (if reuse-context-axes-p
                       (plist-get context-axis-facts
                                  :viewport-dependent-node-id-axes)
                     (ebox-surface--context-axes root))))
             (viewport-width
              (and signals
                   (funcall
                    (if (car axes) #'ebox--pub-signal-read #'ebox--pub-signal-peek)
                    (ebox-surface--signals-viewport-width signals))))
             (viewport-height
              (and signals
                   (funcall
                    (if (cdr axes) #'ebox--pub-signal-read #'ebox--pub-signal-peek)
                    (ebox-surface--signals-viewport-height signals))))
             (scroll-offsets
              (and signals
                   (ebox--pub-signal-peek
                    (ebox-surface--signals-scroll signals))))
             (state
             (ebox-surface--projection-state
               root previous-state state-overrides projection-kind
               stylesheet-active-p cascade-required-p axes viewport-width
               viewport-height surface-display-signature scroll-offsets)))
        (plist-put state :source-index source-index)
        ;; This is private candidate state.  A failed publication retains
        ;; the accepted state's stale bit and retries the complete cascade.
        (plist-put state :computed-styles-stale-p nil)
        (plist-put state :fragment-reuse-rejection nil)
        (plist-put state :fragment-ownership-changed-p nil)
        (when reuse-context-axes-p
          (plist-put state :viewport-dependent-node-ids
                     (plist-get context-axis-facts
                                :viewport-dependent-node-ids))
          (plist-put state :viewport-dependent-node-ids-ready t))
        (plist-put state :style-binding-states
                   (plist-get projection :style-binding-states))
        (plist-put state :selector-tree-snapshot
                   (plist-get projection :selector-tree-snapshot))
        (plist-put state :selector-tree-token
                   (plist-get projection :selector-tree-token))
        (plist-put state :stylesheet-signature
                   (plist-get projection :stylesheet-signature))
        (plist-put state :scroll-fast-window-p scroll-fast-p)
        (when (memq projection-kind
                    '(span-patch owner-scoped scroll-patch
                      formatting-context-reflow mixed-owner-reflow))
          (ebox-surface--attach-retained-node-objects state)
          (when (eq projection-kind 'owner-scoped)
            (ebox-surface--apply-retained-owner-styles state)))
        (if (eq projection-kind 'metadata)
            ;; Selector metadata changes update the Ebox runtime and selector
            ;; indexes but do not alter rendered bytes or text properties.
            ;; Feed Ebox publication an exact-coordinate empty batch so it can retain every
            ;; mounted object without re-walking the surface.
            (progn
              (plist-put state :metadata-buffer
                         (and signals (ebox-surface--signals-buffer signals)))
              (setq state (ebox-surface--finish-runtime-state state))
              (ebox-surface--projection-result
               context projection state nil projection-kind))
          (if (eq projection-kind 'paint)
            (let* ((dirty-set (plist-get state-overrides :paint-dirty-set))
                   (buffer (and signals
                                (ebox-surface--signals-buffer signals)))
                   (old-text
                   (and (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (save-restriction
                             (widen)
                           (buffer-substring (point-min) (point-max)))))))
              ;; Retaining scroll pixels still requires the producer's
              ;; reactive scroll subscription in this paint-only evaluation.
              (when (and signals
                         (hash-table-p (plist-get state :scroll-state-table))
                         (> (hash-table-count
                             (plist-get state :scroll-state-table)) 0))
                (ebox--pub-signal-read (ebox-surface--signals-scroll signals)))
              (setq state (ebox-surface--finish-runtime-state state))
              (ebox-surface--refresh-paint-snapshots state dirty-set)
              (cl-remf state :raw-layout-output)
              (cl-remf state :raw-layout-fragments)
              (cl-remf state :raw-layout-snapshots)
              (cl-remf state :paint-dirty-set)
              (ebox-surface--projection-result
               context projection state
               (ebox-surface--paint-fragments
                previous-state state dirty-set old-text)))
            (cond
           ((memq projection-kind '(span-patch owner-scoped))
            ;; A local owner render visits only its own regions.  Keep the
            ;; complete candidate registry, including disjoint retained scroll
            ;; boxes, in a private table until the transaction is accepted.
            (plist-put state :region-box-table
                       (copy-hash-table (plist-get state :region-box-table))))
           ((not (memq projection-kind
                       '(scroll-patch formatting-context-reflow
                         mixed-owner-reflow)))
            (plist-put state :region-box-table (make-hash-table :test 'equal))))
            (let* ((_initial-native
                  (when initial-native-p
                    ;; Initial mount has no incremental planner.  Surface owns
                    ;; the full candidate after style projection and runtime
                    ;; indexing, so it may explicitly request one native full
                    ;; frame; unsupported programs still fall back through
                    ;; `ebox-native-commit-render' without publishing state.
                    (plist-put state :projection-kind 'native-frame)))
                 (rendered
                 (cond
                  ((memq projection-kind
                         '(span-patch owner-scoped scroll-patch
                           formatting-context-reflow mixed-owner-reflow))
                   (if-let* ((local-output
                              (or
                               ;; Proven root scroll rows own their complete
                               ;; physical origin, including any remainder.
                               (and (eq projection-kind 'scroll-patch)
                                    (not (plist-get state :native-scroll-materialize-p))
                                    (ebox-surface--scroll-patch-output
                                     (ebox-surface--signals-buffer signals) state t))
                               (and (memq projection-kind '(span-patch owner-scoped))
                                    (ebox-surface--span-patch-output
                                     (ebox-surface--signals-buffer signals)
                                     previous-state state t))
                               (and (memq projection-kind '(span-patch owner-scoped))
                                    ;; Raw allocation preserves the remainder
                                    ;; spent by preceding siblings. An integral
                                    ;; result (for example a 100% fill) keeps
                                    ;; that evidence for its next fractional
                                    ;; update; current fractionality does not
                                    ;; determine whether the proof is valid.
                                    (plist-get previous-state :raw-layout-output)
                                    (ebox-surface--raw-owner-patch-output
                                     (ebox-surface--signals-buffer signals) previous-state state))
                               ;; A detached fractional owner cannot recover
                               ;; the remainder spent by preceding siblings.
                               (unless (plist-get previous-state
                                                  :fractional-pixel-output-p)
                                (let ((ebox-surface--integral-local-output-required-p t))
                                  (catch 'ebox/fractional-local-output
                                    (pcase projection-kind
                                      ('scroll-patch
                                       (or (and (plist-get state :native-scroll-materialize-p)
                                                (ebox-surface--native-scroll-full-output state))
                                           (ebox-surface--scroll-patch-output
                                            (ebox-surface--signals-buffer signals) state)
                                           (when-let* ((proof (plist-get state :nested-scroll-patch-proof))
                                                       ((or (not (plist-get proof :scroll-content-region-id))
                                                            (plist-get state :scroll-content-proof))))
                                             (unless (plist-get state :owner-scoped-proofs)
                                               (plist-put state :owner-scoped-proofs (list proof)))
                                             (ebox-surface--span-patch-output
                                              (ebox-surface--signals-buffer signals)
                                              previous-state state))
                                           ;; A nested scroll already owns a
                                           ;; complete candidate projection.
                                           ;; Preserve its ordinary renderer
                                           ;; fallback without recascading the
                                           ;; retained source.  The raw-output
                                           ;; guard still rejects fractions.
                                           (unless (or (plist-get state :native-scroll-materialize-p)
                                                       (plist-get state :nested-scroll-patch-proof))
                                             (ebox-surface--render-candidate state))))
                                      ('formatting-context-reflow
                                       (ebox-surface--formatting-context-reflow-output
                                        (ebox-surface--signals-buffer signals) state))
                                      ('mixed-owner-reflow
                                       (ebox-surface--mixed-owner-output
                                        (ebox-surface--signals-buffer signals)
                                        previous-state state))
                                      (_
                                       (ebox-surface--span-patch-output
                                        (ebox-surface--signals-buffer signals)
                                        previous-state state)))))))))
                       local-output
                     ;; A declined output may already have staged coordinates,
                     ;; fragments or paint layers.  Rebuild from the original
                     ;; candidate inputs before producing ordinary full output.
                     (when (plist-get state-overrides :nested-scroll-patch-proof)
                       (pcase-let ((`(,private-root ,private-overrides)
                                    (ebox-surface--nested-scroll-full-overrides
                                     (ebox-surface--signals-buffer signals)
                                     root state-overrides)))
                         (setq root private-root state-overrides private-overrides)))
                     ;; Range deltas already projected their complete object
                     ;; map, including newly registered keys in this context.
                     (unless (and (eq projection-kind 'mixed-owner-reflow)
                                  (ebox-surface--mixed-range-splice-p state))
                       (setq projection
                             (ebox-surface--complete-projection
                              context root source-index
                              style-required-p projection)))
                     (setq projection-kind nil
                           scroll-fast-p nil)
                     (setq source-index (plist-get projection :source-index))
                     (setq state
                             (ebox-surface--projection-state
                              root previous-state state-overrides nil
                              stylesheet-active-p cascade-required-p axes
                              viewport-width viewport-height
                              surface-display-signature
                              scroll-offsets))
                       (plist-put state :source-index source-index)
                       (plist-put state :style-binding-states
                                  (plist-get projection :style-binding-states))
                       (plist-put state :selector-tree-snapshot
                                  (plist-get projection
                                             :selector-tree-snapshot))
                       (plist-put state :selector-tree-token
                                  (plist-get projection
                                             :selector-tree-token))
                       (plist-put state :stylesheet-signature
                                  (plist-get projection
                                             :stylesheet-signature))
                       (plist-put state :region-box-table
                                  (make-hash-table :test 'equal))
                       (ebox-surface--render-candidate state)))
                  (t
                   (ebox-surface--render-candidate state)))))
            (dolist (interaction '("focus" "active"))
              (let* ((focus-p (equal interaction "focus"))
                     (owner (if focus-p ebox-interaction--focus-owner
                              ebox-interaction--active-owner))
                     (request (and signals
                                   (if focus-p
                                       (ebox-interaction--focus-request-for
                                        (ebox-surface--signals-buffer signals) previous-state)
                                     (ebox-interaction--active-request-for
                                      (ebox-surface--signals-buffer signals) previous-state)))))
                (when (and signals (or owner (cadr request))
                           (ebox-surface--unpainted-interaction-p state rendered interaction))
                  (when (cadr request)
                    (user-error "%s layout removed the enabled visible target" interaction))
                  ;; Resolve geometry-dependent availability before publishing
                  ;; either selector facts or paint, using the same Ebox publication objects.
                  (setq root (ebox-tree-copy-node-structure root)
                        source-index (ebox-source--with-interaction-state
                                      (plist-get state :source-index) interaction nil)
                        projection (ebox-surface--complete-projection
                                    context root source-index t projection
                                    (ebox-surface--node-object-table
                                     (plist-get projection :objects-by-node)))
                        source-index (plist-get projection :source-index)
                        projection-kind nil
                        state (ebox-surface--projection-state
                               root previous-state
                               (cl-loop for key in '(:viewport-width :viewport-height
                                                     :display-signature :runtime-revision
                                                     :scroll-state-table :detached-identity-history)
                                        append (list key (plist-get state key)))
                               nil stylesheet-active-p t axes
                               viewport-width viewport-height surface-display-signature
                               scroll-offsets))
                  (plist-put state :source-index source-index)
                  (plist-put state :style-binding-states
                             (plist-get projection :style-binding-states))
                  (plist-put state :selector-tree-snapshot
                             (plist-get projection :selector-tree-snapshot))
                  (plist-put state :selector-tree-token
                             (plist-get projection :selector-tree-token))
                  (plist-put state :stylesheet-signature
                             (plist-get projection :stylesheet-signature))
                  (plist-put state :region-box-table (make-hash-table :test 'equal))
                  (setq rendered (ebox-surface--render-candidate state)))))
            (when (and (eq projection-kind 'native-frame)
                       (not (eq (plist-get state :projection-kind)
                                'native-frame)))
              ;; Native delta projection already owns a complete object map.
              ;; The existing Elisp renderer produced RENDERED exactly once;
              ;; only its final publication semantics need to become ordinary.
              (setq projection-kind nil))
            (when (and initial-native-p
                       (not (plist-get state :native-render-p)))
              (plist-put state :projection-kind nil))
            (when (and signals
                       (hash-table-p (plist-get state :scroll-state-table))
                       (> (hash-table-count
                           (plist-get state :scroll-state-table))
                          0))
              (ebox--pub-signal-read (ebox-surface--signals-scroll signals)))
            (setq state (ebox-surface--finish-runtime-state state))
            (when (memq projection-kind
                        '(viewport-reflow viewport-reflow-mixed-scroll))
              ;; The reflow source is copied at this boundary.  Attach the
              ;; retained objects only after its candidate indexes exist;
              ;; attaching before that point would mutate the published
              ;; node table through the old state's indexes.
              (ebox-surface--attach-retained-node-objects state))
            (let ((result
                   (ebox-surface--projection-result
                    context projection state rendered projection-kind)))
              ;; These flags authenticate one producer result only.  Leaving
              ;; them in the committed client state would make a later
              ;; content/geometry update look like a scroll transaction and
              ;; bypass its scope validation.
              (plist-put state :retained-scroll-content-p nil)
              (plist-put state :native-scroll-materialize-p nil)
              (cl-remf state :native-touched-node-ids)
              (cl-remf state :native-removed-node-ids)
              (cl-remf state :computed-participation-validated-p)
              (cl-remf state :candidate-subject-table)
              (cl-remf state :nested-scroll-patch-proof)
              result))))))))

(defun ebox-surface-producer
    (source &optional previous-state preserve-identities-p state-overrides
            signals projection-kind source-isolated-p source-path-copied-p)
  "Return a Ebox publication producer for Ebox SOURCE and optional
PREVIOUS-STATE.  PRESERVE-IDENTITIES-P retains existing Ebox node and region
identities.  STATE-OVERRIDES augments the candidate Ebox runtime state.
SIGNALS carries the mounted surface context; one-shot string materialization
omits it.  PROJECTION-KIND may select a proven non-spatial projection.
SOURCE-ISOLATED-P means SOURCE is already an internally isolated runtime
candidate and must not be copied or reconciled again.  SOURCE-PATH-COPIED-P
means SOURCE shares untouched Ebox nodes with the published runtime and must
also bypass candidate copying and reconciliation without clearing those
nodes."
  (lambda (context)
    (ebox-incremental--with-phase 'projection
      (let ((buffer (and signals (ebox-surface--signals-buffer signals))))
        (if (buffer-live-p buffer)
            (with-current-buffer buffer
              (ebox-surface--project
               context source previous-state preserve-identities-p state-overrides
               signals projection-kind source-isolated-p source-path-copied-p))
          (ebox-surface--project
           context source previous-state preserve-identities-p state-overrides
           signals projection-kind source-isolated-p source-path-copied-p))))))

(defun ebox-surface-materialize-ephemeral-string (source source-index)
  "Materialize SOURCE with optional SOURCE-INDEX through one ephemeral Ebox
publication plan."
  (let ((ebox--surface-materialization-active t)
        (ebox--region-id-counter ebox--region-id-counter)
        (ebox--runtime-node-id-counter ebox--runtime-node-id-counter))
    (ebox--pub-surface-materialize-string
     (ebox-surface-producer
      source nil t
      (and source-index (list :source-base-index source-index))))))

;; Install the only upward-facing read port after every callback is defined.
;; Incremental planning owns no Surface symbol or publication capability.
(ebox-incremental-install-context-port
 (ebox-incremental-context-port-create
  :buffer-state #'ebox-surface--buffer-client-state
  :region-mounts #'ebox-surface-region-mounts
  :cascade-owner-proof-p #'ebox-surface--cascade-local-owner-proof-p
  :prepare-inline-styles #'ebox-surface-prepare-inline-candidate-styles
  :interaction-styles-unchanged-p #'ebox-surface-interaction-styles-unchanged-p))

(provide 'ebox-surface)

;;; ebox-surface.el ends here
