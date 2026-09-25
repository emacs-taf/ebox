;;; ebox-property.el --- Ebox-owned native property policies -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; This is the small native-property kernel needed by Ebox.  It deliberately
;; does not provide Ebox's search, surface, or reactive APIs.  Ebox uses it for
;; identity-preserving keymap comparison and explicit computed style values.

;;; Code:

(require 'cl-lib)

(define-error 'ebox-property-error "Ebox property error")
(define-error 'ebox-invalid-property-policy
  "Invalid Ebox property policy" 'ebox-property-error)

(cl-defstruct (ebox-property-policy
               (:constructor ebox-property--make-policy))
  "Policy governing one namespaced Ebox direct property."
  id normalizer validator equality merge projector)

(cl-defstruct (ebox-property--computed-source
               (:constructor ebox-property--make-computed-source))
  "Explicit computed value source used by Ebox style evaluation."
  function)

(defvar ebox-property--policies (make-hash-table :test #'eq)
  "Registered Ebox native property policies by namespaced id.")

(defvar ebox-property--text-policies (make-hash-table :test #'eq)
  "Direct text-property policies by Emacs property symbol.
This caches `ebox-register-text-property' lookups; defining a policy
clears it so a replaced `text/' policy is observed.")

(defun ebox-property--canonical-id-p (id)
  "Return non-nil when ID is a namespaced property symbol."
  (and (symbolp id)
       (let ((name (symbol-name id)))
         (and (string-match-p "/" name)
              (not (string-prefix-p "/" name))
              (not (string-suffix-p "/" name))))))

(defun ebox-property--option (options key fallback)
  "Return KEY from OPTIONS when present, otherwise FALLBACK."
  (if (plist-member options key) (plist-get options key) fallback))

(defun ebox-property--policy-options-valid-p (options)
  "Return non-nil when OPTIONS is a supported property policy plist."
  (and (listp options)
       (zerop (% (length options) 2))
       (cl-loop for key in options by #'cddr
                always (memq key '(:normalizer :validator :equality
                                   :merge :projector)))))

(defun ebox-property--build-policy (id options)
  "Build and validate a policy for ID from OPTIONS."
  (unless (and (ebox-property--canonical-id-p id)
               (ebox-property--policy-options-valid-p options))
    (signal 'ebox-invalid-property-policy (list :property id options)))
  (dolist (key '(:normalizer :validator :equality :merge :projector))
    (let ((value (plist-get options key)))
      (unless (or (null value) (functionp value))
        (signal 'ebox-invalid-property-policy (list key value)))))
  (ebox-property--make-policy
   :id id
   :normalizer (ebox-property--option options :normalizer #'identity)
   :validator (ebox-property--option options :validator (lambda (_value) t))
   :equality (ebox-property--option options :equality #'equal)
   :merge (ebox-property--option options :merge (lambda (_old new) new))
   :projector (plist-get options :projector)))

(defun ebox-define-property-policy (id &rest options)
  "Register namespaced property ID using policy OPTIONS and return its policy."
  (let ((policy (ebox-property--build-policy id options)))
    (puthash id policy ebox-property--policies)
    (clrhash ebox-property--text-policies)
    policy))

(defun ebox-property-policy (id)
  "Return the registered property policy for ID, or nil."
  (gethash id ebox-property--policies))

(defun ebox-text-property-id (property)
  "Return the canonical `text/' policy id for Emacs PROPERTY."
  (unless (symbolp property)
    (signal 'wrong-type-argument (list 'symbolp property)))
  (intern (format "text/%s" property)))

(defun ebox-property--native-keymap-equal-p (left right)
  "Compare native snapshots LEFT and RIGHT, retaining command identity."
  (let ((seen (make-hash-table :test #'eq)))
    (cl-labels
        ((bindings (map)
           (let ((local (copy-sequence (if (symbolp map)
                                           (indirect-function map) map)))
                 entries)
             (set-keymap-parent local nil)
             (map-keymap (lambda (key value) (push (cons key value) entries)) local)
             entries))
         (same (old new)
           (cond
            ((eq old new) t)
            ((memq new (gethash old seen)) t)
            ((and (keymapp old) (keymapp new))
             (puthash old (cons new (gethash old seen)) seen)
             (and (equal-including-properties (keymap-prompt old)
                                               (keymap-prompt new))
                  (same (bindings old) (bindings new))
                  (same (keymap-parent old) (keymap-parent new))))
            ((or (functionp old) (functionp new)) nil)
            ((and (consp old) (consp new))
             (puthash old (cons new (gethash old seen)) seen)
             (and (same (car old) (car new)) (same (cdr old) (cdr new))))
            ((and (vectorp old) (vectorp new) (= (length old) (length new)))
             (puthash old (cons new (gethash old seen)) seen)
             (cl-loop for index below (length old)
                      always (same (aref old index) (aref new index))))
            (t (equal old new)))))
      (same left right))))

(defun ebox-property--native-value-equal-p (left right)
  "Compare native values LEFT and RIGHT while preserving callable identity.
Keymaps compare by bindings, so this equality serves properties whose
values are keymaps."
  (cond
   ((and (keymapp left) (keymapp right))
    (ebox-property--native-keymap-equal-p left right))
   ((or (functionp left) (functionp right)) (eq left right))
   (t (equal left right))))

(defun ebox-property--native-plain-value-equal-p (left right)
  "Compare native values LEFT and RIGHT of a property that never holds a keymap.
Callables keep identity and every other value compares structurally.  A list
such as `(keymap)' stored in `rear-nonsticky' satisfies `keymapp', so keymap
comparison is reserved for the properties that actually bind keys."
  (cond
   ((or (functionp left) (functionp right)) (eq left right))
   (t (equal left right))))

(defconst ebox-property--keymap-text-properties '(keymap local-map)
  "Emacs text properties whose values are keymaps.")

(defun ebox-register-text-property (property)
  "Register and return a direct policy for Emacs PROPERTY."
  (or (gethash property ebox-property--text-policies)
      (let* ((id (ebox-text-property-id property))
             (policy
              (or (ebox-property-policy id)
                  (ebox-define-property-policy
                   id :equality
                   (if (memq property ebox-property--keymap-text-properties)
                       #'ebox-property--native-value-equal-p
                     #'ebox-property--native-plain-value-equal-p)
                   :merge (if (memq property '(face font-lock-face mouse-face))
                              #'ebox-property--merge-face-values
                            (lambda (_old new) new))
                   :projector (lambda (value) (list property value))))))
        (puthash property policy ebox-property--text-policies)
        policy)))

(defun ebox-computed (function)
  "Return an explicit computed value source wrapping FUNCTION."
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (ebox-property--make-computed-source :function function))

(defun ebox-computed-p (value)
  "Return non-nil when VALUE is an explicit Ebox computed source."
  (ebox-property--computed-source-p value))

(defun ebox-resolve-value (value &optional _property _subject)
  "Resolve VALUE only when it is an explicit `ebox-computed' source."
  (if (ebox-property--computed-source-p value)
      (funcall (ebox-property--computed-source-function value))
    value))

(defun ebox-property--deep-merge-plist (base new)
  "Deep merge NEW plist into BASE plist.  For nested plists (starting with
keyword), recursively merge.  NEW values override BASE values."
  (let ((result (copy-sequence base)))
    (cl-loop
     for (key val) on new by #'cddr
     do (let ((base-val (plist-get result key)))
          (setq result
                (plist-put
                 result key
                 (cond
                  ;; Both are plists - recursively merge
                  ((and (listp val) (keywordp (car-safe val))
                        (listp base-val) (keywordp (car-safe base-val)))
                   (ebox-property--deep-merge-plist base-val val))
                  ;; Otherwise use new value
                  (t val))))))
    result))


(defun ebox-property--parse-face-list (face-list)
  "Parse a mixed face list into symbols and a plist.  FACE-LIST can be a mix
of: - Face symbols (like bold, italic) - Face plists (like (:foreground
\"red\")) - Inline plist keys and values (like bold :foreground \"green\")

Returns (SYMBOLS . PLIST) where SYMBOLS is a list of face symbols and PLIST
is the merged plist of all face attributes."
  (let ((symbols nil)
        (plist nil)
        (i 0)
        (len (length face-list)))
    (while (< i len)
      (let ((elem (nth i face-list)))
        (cond
         ;; Nested plist like (:foreground "red")
         ((and (listp elem) (keywordp (car-safe elem)))
          (setq plist (if plist (ebox-property--deep-merge-plist plist elem) elem))
          (setq i (1+ i)))
         ;; Inline keyword - consume key and value
         ((keywordp elem)
          (if (< (1+ i) len)
              (let ((key elem)
                    (val (nth (1+ i) face-list)))
                (setq plist (if plist
                                (plist-put plist key val)
                              (list key val)))
                (setq i (+ i 2)))
            ;; Trailing bare keyword with no value: malformed input.
            ;; Ignore it rather than inventing a bogus (KEY nil) pair.
            (setq i (1+ i))))
         ;; Face symbol
         ((symbolp elem)
          (push elem symbols)
          (setq i (1+ i)))
         ;; Something else - skip
         (t (setq i (1+ i))))))
    (cons (nreverse symbols) plist)))


(defun ebox-property--merge-face-values (face1 face2)
  "Merge two face values into one.  FACE1 is the earlier value, FACE2 is the
later value.  For face plists (like (:foreground \"red\")), merge with later
overriding.  For symbol faces, create a list with FACE2 taking precedence.
Returns the merged face value.

Face contributions arrive in paint order; later values take precedence."
  (cond
   ;; No earlier face - just use later face
   ((null face1) face2)
   ;; No later face - just use earlier face
   ((null face2) face1)
   ;; Both are plists - merge with later overriding earlier
   ((and (listp face1) (keywordp (car-safe face1))
         (listp face2) (keywordp (car-safe face2)))
    (ebox-property--deep-merge-plist face1 face2))
   ;; Later is a plist, earlier is a symbol or list of faces
   ((and (listp face2) (keywordp (car-safe face2)))
    (cond
     ((symbolp face1)
      (list face2 face1))
     ((listp face1)
      (cons face2 face1))
     (t face2)))
   ;; Earlier is a plist, later is a symbol
   ((and (listp face1) (keywordp (car-safe face1))
         (symbolp face2))
    (list face2 face1))
   ;; Later is a symbol - prepend to earlier
   ((symbolp face2)
    (cond
     ((symbolp face1)
      (if (eq face1 face2)
          face2
        (list face2 face1)))
     ((listp face1)
      (if (member face2 face1)
          (cons face2 (remove face2 face1))  ; Move to front
        (cons face2 face1)))
     (t face2)))
   ;; Later is a list of faces - prepend to earlier
   ((listp face2)
    (cond
     ((symbolp face1)
      (if (member face1 face2)
          face2
        (append face2 (list face1))))
     ;; face1 is a plist - need to merge any plist in face2 with face1
     ((and (listp face1) (keywordp (car-safe face1)))
      ;; Use ebox-property--parse-face-list to handle mixed formats like (bold :foreground "green")
      (let* ((parsed (ebox-property--parse-face-list face2))
             (symbols (car parsed))
             (plist (cdr parsed)))
        ;; Merge face2's plist with face1, then prepend symbols
        (let ((merged-plist (if plist (ebox-property--deep-merge-plist face1 plist) face1)))
          (if symbols
              (append symbols (list merged-plist))
            merged-plist))))
     ;; Both are lists - parse both, merge plists, combine symbols
     ((listp face1)
      (let* ((parsed1 (ebox-property--parse-face-list face1))
             (symbols1 (car parsed1))
             (plist1 (cdr parsed1))
             (parsed2 (ebox-property--parse-face-list face2))
             (symbols2 (car parsed2))
             (plist2 (cdr parsed2))
             ;; Merge plists with face2's plist taking precedence
             (merged-plist (cond
                            ((and plist1 plist2) (ebox-property--deep-merge-plist plist1 plist2))
                            (plist2 plist2)
                            (plist1 plist1)
                            (t nil)))
             ;; Combine symbols: face2 symbols first, then face1 symbols not in face2
             (merged-symbols (append symbols2
                                     (cl-remove-if (lambda (s) (member s symbols2)) symbols1))))
        ;; Build result: symbols first, then merged plist if any
        (if merged-plist
            (append merged-symbols (list merged-plist))
          merged-symbols)))
     (t face2)))
   (t face2)))


(provide 'ebox-property)
;;; ebox-property.el ends here
