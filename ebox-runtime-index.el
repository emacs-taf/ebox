;;; ebox-runtime-index.el --- Immutable runtime indexes for Ebox -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Compressed persistent radix maps used by runtime state.  Branches retain
;; only nibble positions where codes diverge; leaves hold exact equal-key
;; collision buckets.  Adapters continue to accept legacy hash tables.

;;; Code:

(require 'cl-lib)

(cl-defstruct (ebox-runtime-index
               (:constructor ebox-runtime-index--create
                             (root count key-set-token)))
  "Immutable compressed radix index."
  root
  count
  key-set-token)

(defun ebox-runtime-index-empty ()
  "Return an empty immutable runtime index."
  (ebox-runtime-index--create nil 0 nil))

(defun ebox-runtime-index-like-p (object)
  "Return non-nil when OBJECT is a supported runtime index."
  (or (ebox-runtime-index-p object) (hash-table-p object)))

(defun ebox-runtime-index--code (key)
  "Return a stable 64-bit radix code for KEY."
  (logand (if (and (integerp key) (>= key 0)) key (sxhash-equal key))
          #xffffffffffffffff))

(defun ebox-runtime-index--branch (shift code &optional original)
  "Return a fresh branch for nibble SHIFT and representative CODE.
Copy ORIGINAL when supplied; its metadata already carries SHIFT and CODE.
All branch allocations, including path copies, pass through this function."
  (if original
      (copy-sequence original)
    (let ((branch (make-vector 18 nil)))
      (aset branch 0 shift)
      (aset branch 1 code)
      branch)))

(defun ebox-runtime-index--join (left left-code right right-code)
  "Join LEFT and RIGHT above the first differing nibble of their codes.
LEFT-CODE and RIGHT-CODE are distinct 64-bit representative codes."
  (let* ((difference (logxor left-code right-code))
         (shift (logand (logcount (1- (logand difference (- difference))))
                        -4))
         (branch (ebox-runtime-index--branch shift left-code)))
    (aset branch (+ 2 (logand (ash left-code (- shift)) 15)) left)
    (aset branch (+ 2 (logand (ash right-code (- shift)) 15)) right)
    branch))

(defun ebox-runtime-index--root-get (root key missing)
  "Return KEY from persistent ROOT, or MISSING."
  (let ((node root)
        (code (ebox-runtime-index--code key)))
    (while (vectorp node)
      (setq node (aref node (+ 2 (logand (ash code (- (aref node 0))) 15)))))
    (if (and node (= code (car node)))
        (let ((pair (assoc key (cdr node))))
          (if pair (cdr pair) missing))
      missing)))

(defun ebox-runtime-index-get (key index &optional missing)
  "Return KEY's value from INDEX, or MISSING.
INDEX may be an immutable runtime index or a legacy hash table."
  (cond
   ((ebox-runtime-index-p index)
    (ebox-runtime-index--root-get (ebox-runtime-index-root index) key missing))
   ((hash-table-p index) (gethash key index missing))
   (t missing)))

(defun ebox-runtime-index-contains-p (key index)
  "Return non-nil when INDEX contains KEY, including a nil value."
  (let ((missing (make-symbol "ebox-runtime-index-missing")))
    (not (eq (ebox-runtime-index-get key index missing) missing))))

(defun ebox-runtime-index--root-put (root key value code)
  "Return `(ROOT . ADDED)' after mapping KEY to VALUE using CODE."
  (cond
   ((null root) (cons (cons code (list (cons key value))) t))
   ((vectorp root)
    (let ((shift (aref root 0))
          (representative (aref root 1)))
      (if (/= (logand (logxor code representative) (1- (ash 1 shift))) 0)
          (cons (ebox-runtime-index--join
                 root representative (cons code (list (cons key value))) code)
                t)
        (let* ((slot (+ 2 (logand (ash code (- shift)) 15)))
               (result (ebox-runtime-index--root-put
                        (aref root slot) key value code))
               (copy (ebox-runtime-index--branch shift representative root)))
          (aset copy slot (car result))
          (cons copy (cdr result))))))
   ((= code (car root))
    (let* ((bucket (cdr root))
           (present (assoc key bucket)))
      (cons (cons code
                  (cons (cons key value)
                        (if present
                            (cl-remove key bucket :key #'car :test #'equal)
                          bucket)))
            (not present))))
   (t (cons (ebox-runtime-index--join
             root (car root) (cons code (list (cons key value))) code)
            t))))

(defun ebox-runtime-index-put (key value index)
  "Return INDEX with KEY mapped to VALUE.
Immutable indexes return a new value.  Legacy hash tables are mutated and
returned for compatibility."
  (cond
   ((ebox-runtime-index-p index)
    (let ((result
           (ebox-runtime-index--root-put
            (ebox-runtime-index-root index) key value
            (ebox-runtime-index--code key))))
      (ebox-runtime-index--create
       (car result)
       (+ (ebox-runtime-index-count index) (if (cdr result) 1 0))
       (if (cdr result)
           (make-symbol "ebox-runtime-index-key-set")
         (ebox-runtime-index-key-set-token index)))))
   ((hash-table-p index) (puthash key value index) index)
   (t (signal 'wrong-type-argument (list 'ebox-runtime-index-like-p index)))))

(defun ebox-runtime-index--root-delete (root key code)
  "Return `(ROOT . REMOVED)' after deleting KEY using CODE."
  (cond
   ((null root) (cons nil nil))
   ((vectorp root)
    (let* ((shift (aref root 0))
           (slot (+ 2 (logand (ash code (- shift)) 15)))
           (result (ebox-runtime-index--root-delete (aref root slot) key code)))
      (if (not (cdr result))
          (cons root nil)
        (let ((children 0) survivor)
          (unless (car result)
            (dotimes (offset 16)
              (let ((position (+ offset 2)))
                (when (and (/= position slot) (aref root position))
                  (cl-incf children)
                  (setq survivor (aref root position))))))
          (if (= children 1)
              (cons survivor t)
            (let ((copy (ebox-runtime-index--branch shift (aref root 1) root)))
              (aset copy slot (car result))
              (cons copy t)))))))
   ((and (= code (car root)) (assoc key (cdr root)))
    (let ((bucket (cl-remove key (cdr root) :key #'car :test #'equal)))
      (cons (and bucket (cons code bucket)) t)))
   (t (cons root nil))))

(defun ebox-runtime-index-delete (key index)
  "Return INDEX without KEY.
Immutable indexes return a new value.  Legacy hash tables are mutated and
returned for compatibility."
  (cond
   ((ebox-runtime-index-p index)
    (let ((result
           (ebox-runtime-index--root-delete
            (ebox-runtime-index-root index) key
            (ebox-runtime-index--code key))))
      (if (cdr result)
          (let ((count (1- (ebox-runtime-index-count index))))
            (ebox-runtime-index--create
             (car result) count
             (and (> count 0)
                  (make-symbol "ebox-runtime-index-key-set"))))
        index)))
   ((hash-table-p index) (remhash key index) index)
   (t (signal 'wrong-type-argument (list 'ebox-runtime-index-like-p index)))))

(defun ebox-runtime-index-size (index)
  "Return the number of entries in INDEX."
  (cond
   ((ebox-runtime-index-p index) (ebox-runtime-index-count index))
   ((hash-table-p index) (hash-table-count index))
   (t 0)))

(defun ebox-runtime-index-key-set-equal-p (left right)
  "Return non-nil when supported indexes LEFT and RIGHT have equal keys."
  (let ((persistent-shared-keys-p
         (and (ebox-runtime-index-p left)
              (ebox-runtime-index-p right)
              (= (ebox-runtime-index-count left)
                 (ebox-runtime-index-count right))
              (eq (ebox-runtime-index-key-set-token left)
                  (ebox-runtime-index-key-set-token right)))))
    (cond
     (persistent-shared-keys-p t)
     ((and (ebox-runtime-index-like-p left)
           (ebox-runtime-index-like-p right)
           (= (ebox-runtime-index-size left) (ebox-runtime-index-size right)))
      (let ((equal-p t)
            (missing (make-symbol "ebox-runtime-index-missing")))
        (ebox-runtime-index-map
         (lambda (key _value)
           (when (eq (ebox-runtime-index-get key right missing) missing)
             (setq equal-p nil)))
         left)
        equal-p))
     (t nil))))

(defun ebox-runtime-index--map-root (function root)
  "Call FUNCTION for entries below ROOT, visiting only live trie nodes."
  (when root
    (if (vectorp root)
        (dotimes (branch 16)
          (let ((child (aref root (+ 2 branch))))
            (when child (ebox-runtime-index--map-root function child))))
      (dolist (pair (cdr root)) (funcall function (car pair) (cdr pair))))))

(defun ebox-runtime-index-map (function index)
  "Call FUNCTION with every key and value in INDEX."
  (cond
   ((ebox-runtime-index-p index)
    (ebox-runtime-index--map-root
     function (ebox-runtime-index-root index)))
   ((hash-table-p index) (maphash function index))
   (t (signal 'wrong-type-argument (list 'ebox-runtime-index-like-p index))))
  nil)

(defun ebox-runtime-index-keys (index)
  "Return a list of keys in INDEX."
  (let (keys)
    (ebox-runtime-index-map (lambda (key _value) (push key keys)) index)
    keys))

(provide 'ebox-runtime-index)

;;; ebox-runtime-index.el ends here
