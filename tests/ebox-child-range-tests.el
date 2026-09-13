;;; ebox-child-range-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

;; This suite locks child-range and Elisp projection semantics.  Native frame
;; execution is verified separately and must not replace the named fallback
;; strategies merely because a developer has built the optional module.
(defvar ebox-native-reflow-module-path)

(provide 'ebox-child-range-tests)
;;; ebox-child-range-tests.el ends here
