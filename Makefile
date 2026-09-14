.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
CARGO ?= cargo
PYTHON ?= python3
TP_DIR ?= ../tp
ECSS_DIR ?= ../ecss
LOAD_EXTRA ?=
RELEASE_DIR ?= /tmp/ebox-release
RELEASE_DEPS_DIR ?= /tmp/ebox-release-deps
RELEASE_OPTIONS ?=
NATIVE_MODULE ?=

EMACS_BATCH = $(EMACS) -Q --batch -L . -L lisp -L benchmarks -L $(ECSS_DIR) -L $(TP_DIR) $(LOAD_EXTRA) --eval '(setq load-prefer-newer t)'
EMACS_TEST = $(EMACS_BATCH) -L tests
NATIVE_MANIFEST = native/Cargo.toml
NATIVE_TARGET ?= $(shell $(EMACS_BATCH) -l lisp/ebox-native-reflow.el --eval '(princ (ebox-native-reflow--rust-target))')
NATIVE_RELEASE_DIR = native/target/$(NATIVE_TARGET)/release

.PHONY: all check ci load compile checkdoc layout-boundary-performance performance-evaluator update-effects-performance visual-check native-build diff-check clean package-lint package-lint-install

.PHONY: release-deps release-build release-check release-tool-tests native-integration release-native-check

all: check

release-deps:
	$(PYTHON) scripts/ebox-release.py deps --directory "$(RELEASE_DEPS_DIR)" $(RELEASE_OPTIONS)

release-build:
	$(PYTHON) scripts/ebox-release.py build --directory "$(RELEASE_DIR)" $(RELEASE_OPTIONS)

release-check: release-build
	$(PYTHON) scripts/ebox-release.py verify --directory "$(RELEASE_DIR)" --emacs "$(EMACS)"

native-integration:
	$(PYTHON) scripts/ebox-release.py verify --directory "$(RELEASE_DIR)" --emacs "$(EMACS)" --native-module "$(NATIVE_MODULE)"

release-native-check:
	$(PYTHON) scripts/ebox-release.py verify --directory "$(RELEASE_DIR)" --emacs "$(EMACS)" --build-native

release-tool-tests:
	$(PYTHON) -m unittest discover -s tests/tools -p 'test_ebox_release.py'

check: structure-check compile acceptance api-check release-tool-tests update-effects-tool-tests

ci: check checkdoc load visual-check diff-check

load:
	$(EMACS_BATCH) -l ebox.el --eval '(princ "ebox load OK\n")'

compile:
	rm -f *.elc lisp/*.elc tests/*.elc scripts/*.elc benchmarks/*.elc
	$(EMACS_BATCH) --eval '(setq byte-compile-error-on-warn t byte-compile-warnings (quote (not obsolete)))' -l ebox.el --eval '(ebox-byte-compile)'

layout-boundary-performance:
	$(EMACS_BATCH) -l benchmarks/ebox-performance-evaluator.el -f ebox-performance-evaluator-layout-boundary-batch

performance-evaluator:
	$(EMACS_BATCH) -l benchmarks/ebox-performance-evaluator.el -f ebox-performance-evaluator-batch

update-effects-performance:
	$(EMACS_BATCH) -l benchmarks/benchmark-update-effects.el -f ebox-update-effects-batch

visual-check:
	$(EMACS_BATCH) -l scripts/ebox-visual-check.el -f ebox-visual-check-batch

native-build:
	$(CARGO) build --locked --manifest-path $(NATIVE_MANIFEST) --release --target $(NATIVE_TARGET)

package-lint:
	$(EMACS_BATCH) -l scripts/ebox-package-lint.el -f ebox-package-lint-batch

package-lint-install:
	EBOX_PACKAGE_LINT_INSTALL=1 $(MAKE) package-lint EMACS="$(EMACS)"

checkdoc:
	$(EMACS) -Q --batch --eval '(progn (require (quote checkdoc)) (dolist (file (directory-files "lisp" t)) (when (string-suffix-p ".el" file) (checkdoc-file file))))'

diff-check:
	git diff --check

clean:
	rm -f *.elc lisp/*.elc tests/*.elc scripts/*.elc benchmarks/*.elc
	rm -rf native/target

.PHONY: structure-check setup-hooks
structure-check:
	python3 scripts/check-repository.py
setup-hooks:
	git config --local core.hooksPath .githooks

.PHONY: acceptance
acceptance:
	python3 scripts/run-acceptance.py --emacs "$(EMACS)"

.PHONY: api-check
api-check:
	$(EMACS) -Q --batch -L . $(API_PROVIDER_PATH) --eval '(setq load-prefer-newer t)' -l scripts/check-api.el
API_PROVIDER_PATH = -L ../ecss -L ../tp -L ../ekp -L ../etaf -L ../etaf-ui -L ../etaf-db -L ../ebox-playground -L ../etaf-playground

.PHONY: test
test: acceptance

.PHONY: update-effects-tool-tests
update-effects-tool-tests:
	EBOX_TOOL_TEST_EMACS="$(EMACS)" $(PYTHON) -m unittest discover -s tests/tools -p 'test_update_effects.py'
