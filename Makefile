EMACS ?= emacs
CARGO ?= cargo
TP_DIR ?= ../tp
ECSS_DIR ?= ../ecss
LOAD_EXTRA ?=

EMACS_BATCH = $(EMACS) -Q --batch -L . -L $(ECSS_DIR) -L $(TP_DIR) $(LOAD_EXTRA) --eval '(setq load-prefer-newer t)'
NATIVE_MANIFEST = native/Cargo.toml
NATIVE_TARGET ?= $(shell $(EMACS_BATCH) -l ebox-native-reflow.el --eval '(princ (ebox-native-reflow--rust-target))')
NATIVE_RELEASE_DIR = native/target/$(NATIVE_TARGET)/release

.PHONY: all check ci load compile test checkdoc core-tests child-range-tests grid-tests ebox-commit-tests surface-tests visual-check-tests package-tests selector-tests dsl-tests flex-tests docs-contract-tests ci-contract-tests performance-evaluator visual-check native-rust-tests native-build diff-check clean package-lint package-lint-install

all: check

check: ci

ci: checkdoc load compile test visual-check diff-check

load:
	$(EMACS_BATCH) -l ebox.el --eval '(princ "ebox load OK\n")'

compile:
	rm -f *.elc tests/*.elc scripts/*.elc
	$(EMACS_BATCH) --eval '(setq byte-compile-error-on-warn t)' -l ebox.el --eval '(ebox-byte-compile)'

test: core-tests child-range-tests grid-tests ebox-commit-tests surface-tests visual-check-tests package-tests selector-tests dsl-tests flex-tests docs-contract-tests ci-contract-tests

core-tests:
	$(EMACS_BATCH) -l tests/ebox-core-render-tests.el -f ert-run-tests-batch-and-exit

child-range-tests:
	$(EMACS_BATCH) -l tests/ebox-child-range-tests.el -f ert-run-tests-batch-and-exit

grid-tests:
	$(EMACS_BATCH) -l tests/ebox-grid-tests.el -f ert-run-tests-batch-and-exit

ebox-commit-tests:
	$(EMACS_BATCH) -l tests/ebox-commit-tests.el -f ert-run-tests-batch-and-exit

surface-tests:
	$(EMACS_BATCH) -l tests/ebox-surface-tests.el -f ert-run-tests-batch-and-exit

visual-check-tests:
	$(EMACS_BATCH) -l tests/ebox-visual-check-tests.el -f ert-run-tests-batch-and-exit

package-tests:
	$(EMACS_BATCH) -l tests/ebox-package-tests.el -f ert-run-tests-batch-and-exit

selector-tests:
	$(EMACS_BATCH) -l tests/ebox-selector-tests.el -f ert-run-tests-batch-and-exit

dsl-tests:
	$(EMACS_BATCH) -l tests/ebox-dsl-tests.el -f ert-run-tests-batch-and-exit

flex-tests:
	$(EMACS_BATCH) -l tests/ebox-flex-tests.el -f ert-run-tests-batch-and-exit

performance-evaluator: surface-tests ebox-commit-tests
	$(EMACS_BATCH) -l scripts/ebox-performance-evaluator.el -f ebox-performance-evaluator-batch

docs-contract-tests:
	$(EMACS_BATCH) -l tests/ebox-docs-contract-tests.el -f ert-run-tests-batch-and-exit

ci-contract-tests:
	$(EMACS_BATCH) -l tests/ebox-ci-contract-tests.el -f ert-run-tests-batch-and-exit

visual-check:
	$(EMACS_BATCH) -l scripts/ebox-visual-check.el -f ebox-visual-check-batch

native-rust-tests:
	$(CARGO) fmt --manifest-path $(NATIVE_MANIFEST) -- --check
	$(CARGO) clippy --locked --manifest-path $(NATIVE_MANIFEST) --all-targets -- -D warnings
	$(CARGO) test --locked --manifest-path $(NATIVE_MANIFEST)

native-build:
	$(CARGO) build --locked --manifest-path $(NATIVE_MANIFEST) --release --target $(NATIVE_TARGET)

package-lint:
	$(EMACS_BATCH) -l scripts/ebox-package-lint.el -f ebox-package-lint-batch

package-lint-install:
	EBOX_PACKAGE_LINT_INSTALL=1 $(MAKE) package-lint EMACS="$(EMACS)"

checkdoc:
	$(EMACS) -Q --batch --eval '(progn (require (quote checkdoc)) (dolist (file (directory-files "." t)) (when (string-suffix-p ".el" file) (checkdoc-file file))))'

diff-check:
	git diff --check

clean:
	rm -f *.elc tests/*.elc scripts/*.elc
	rm -rf native/target
