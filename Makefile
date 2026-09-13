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

EMACS_BATCH = $(EMACS) -Q --batch -L . -L $(ECSS_DIR) -L $(TP_DIR) $(LOAD_EXTRA) --eval '(setq load-prefer-newer t)'
EMACS_TEST = $(EMACS_BATCH) -L tests -l tests/ebox-fixtures.el
NATIVE_MANIFEST = native/Cargo.toml
NATIVE_TARGET ?= $(shell $(EMACS_BATCH) -l ebox-native-reflow.el --eval '(princ (ebox-native-reflow--rust-target))')
NATIVE_RELEASE_DIR = native/target/$(NATIVE_TARGET)/release

.PHONY: all check ci load compile test checkdoc runtime-index-tests source-tests font-tests core-tests child-range-tests grid-tests ebox-commit-tests surface-tests visual-check-tests package-tests selector-tests dsl-tests flex-tests viewport-topology-tests vertical-materialization-tests box-line-flow-tests state-contract-tests layout-boundary-tests layout-boundary-performance patch-plan-tests patch-plan-performance style-schema-tests style-schema-performance spi-tests spi-performance c1b-contract-tests docs-contract-tests ci-contract-tests performance-evaluator visual-check native-rust-tests native-build diff-check clean package-lint package-lint-install

.PHONY: node-memo-generation-tests
.PHONY: interaction-tests
.PHONY: display-tests release-deps release-build release-check release-tool-tests native-integration release-native-check

all: check

.PHONY: layer-tests
layer-tests:
	$(EMACS_TEST) -l tests/ebox-composite-tests.el -l tests/ebox-layer-style-tests.el -l tests/ebox-layer-tests.el -l tests/ebox-layer-publication-tests.el -l tests/ebox-layer-scroll-tests.el -f ert-run-tests-batch-and-exit

test: layer-tests file-tests

.PHONY: file-tests
file-tests:
	$(EMACS_TEST) -l tests/ebox-file-tests.el -f ert-run-tests-batch-and-exit

interaction-tests:
	$(EMACS_TEST) -l tests/ebox-interaction-tests.el -f ert-run-tests-batch-and-exit

test: interaction-tests

.PHONY: nested-scroll-tests
nested-scroll-tests:
	$(EMACS_TEST) -l tests/ebox-nested-scroll-tests.el -f ert-run-tests-batch-and-exit

test: nested-scroll-tests

.PHONY: scroll-slice-tests
scroll-slice-tests:
	$(EMACS_TEST) -l tests/ebox-scroll-slice-tests.el -f ert-run-tests-batch-and-exit

test: scroll-slice-tests

.PHONY: scroll-cold-tests
scroll-cold-tests:
	$(EMACS_TEST) -l tests/ebox-scroll-cold-tests.el -f ert-run-tests-batch-and-exit

test: scroll-cold-tests

display-tests:
	$(EMACS_TEST) -l tests/ebox-display-tests.el -f ert-run-tests-batch-and-exit

test: display-tests release-tool-tests

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
	$(PYTHON) -m unittest discover -s scripts -p 'test_ebox_release.py'

check: ci

ci: checkdoc load compile test visual-check diff-check

load:
	$(EMACS_BATCH) -l ebox.el --eval '(princ "ebox load OK\n")'

compile:
	rm -f *.elc tests/*.elc scripts/*.elc
	$(EMACS_BATCH) --eval '(setq byte-compile-error-on-warn t byte-compile-warnings (quote (not obsolete)))' -l ebox.el --eval '(ebox-byte-compile)'

test: size-tests runtime-index-tests source-tests font-tests core-tests child-range-tests grid-tests ebox-commit-tests surface-tests visual-check-tests package-tests selector-tests dsl-tests flex-tests viewport-topology-tests vertical-materialization-tests box-line-flow-tests node-memo-generation-tests state-contract-tests layout-boundary-tests patch-plan-tests style-schema-tests spi-tests docs-contract-tests ci-contract-tests

.PHONY: size-tests size-migration-tests
size-tests: size-migration-tests
	$(EMACS_BATCH) -L tests -l tests/ebox-size-tests.el -l tests/ebox-size-style-tests.el -l tests/ebox-css-layout-tests.el -l tests/ebox-css-flex-grid-tests.el -l tests/ebox-css-viewport-tests.el -l tests/ebox-size-native-tests.el -l tests/ebox-zero-height-tests.el -f ert-run-tests-batch-and-exit

size-migration-tests:
	python3 -m unittest discover -s scripts -p 'test_migrate_css_sizes.py'

runtime-index-tests:
	$(EMACS_BATCH) -l tests/ebox-runtime-index-tests.el -f ert-run-tests-batch-and-exit

source-tests:
	$(EMACS_BATCH) -l tests/ebox-source-tests.el -f ert-run-tests-batch-and-exit

font-tests:
	$(EMACS_BATCH) -l tests/ebox-font-tests.el -f ert-run-tests-batch-and-exit

core-tests:
	$(EMACS_TEST) -l tests/ebox-core-render-tests.el -f ert-run-tests-batch-and-exit

child-range-tests:
	$(EMACS_TEST) -l tests/ebox-child-range-tests.el -f ert-run-tests-batch-and-exit

grid-tests:
	$(EMACS_TEST) -l tests/ebox-grid-tests.el -f ert-run-tests-batch-and-exit

ebox-commit-tests:
	$(EMACS_TEST) -l tests/ebox-commit-tests.el -f ert-run-tests-batch-and-exit

surface-tests:
	$(EMACS_TEST) -l tests/ebox-surface-tests.el -f ert-run-tests-batch-and-exit

visual-check-tests:
	$(EMACS_TEST) -l tests/ebox-visual-check-tests.el -f ert-run-tests-batch-and-exit

package-tests:
	$(EMACS_BATCH) -l tests/ebox-package-tests.el -f ert-run-tests-batch-and-exit

selector-tests:
	$(EMACS_TEST) -l tests/ebox-selector-tests.el -f ert-run-tests-batch-and-exit

dsl-tests:
	$(EMACS_BATCH) -l tests/ebox-dsl-tests.el -f ert-run-tests-batch-and-exit

flex-tests:
	$(EMACS_TEST) -l tests/ebox-flex-tests.el -f ert-run-tests-batch-and-exit

viewport-topology-tests:
	$(EMACS_TEST) -l tests/ebox-viewport-topology-tests.el -f ert-run-tests-batch-and-exit

vertical-materialization-tests:
	$(EMACS_TEST) -l tests/ebox-vertical-materialization-tests.el -f ert-run-tests-batch-and-exit

box-line-flow-tests:
	$(EMACS_TEST) -l tests/ebox-box-line-flow-tests.el -f ert-run-tests-batch-and-exit

node-memo-generation-tests:
	$(EMACS_TEST) -l tests/ebox-node-memo-generation-tests.el -f ert-run-tests-batch-and-exit

state-contract-tests:
	$(EMACS_TEST) -l tests/ebox-state-contract-tests.el -f ert-run-tests-batch-and-exit

layout-boundary-tests:
	$(EMACS_TEST) -l tests/ebox-layout-boundary-tests.el -f ert-run-tests-batch-and-exit

layout-boundary-performance:
	$(EMACS_BATCH) -l scripts/ebox-performance-evaluator.el -f ebox-performance-evaluator-layout-boundary-batch

patch-plan-tests:
	$(EMACS_TEST) -l tests/ebox-patch-plan-tests.el -f ert-run-tests-batch-and-exit

patch-plan-performance:
	$(EMACS_TEST) -l tests/ebox-patch-plan-tests.el --eval "(ert-run-tests-batch-and-exit 'ebox-patch-plan-performance-bounds-parent-walks)"

style-schema-tests:
	$(EMACS_TEST) -l tests/ebox-style-schema-tests.el -f ert-run-tests-batch-and-exit

style-schema-performance:
	$(EMACS_TEST) -l tests/ebox-style-schema-tests.el --eval "(ert-run-tests-batch-and-exit 'ebox-style-schema-performance-uses-one-lookup-per-property)"

spi-tests:
	$(EMACS_TEST) -l tests/ebox-spi-tests.el -f ert-run-tests-batch-and-exit

c1b-contract-tests: ebox-commit-tests spi-tests package-tests docs-contract-tests

spi-performance:
	$(EMACS_TEST) -l tests/ebox-spi-tests.el --eval "(ert-run-tests-batch-and-exit 'ebox-spi-performance-builds-bounded-provider-snapshots)"

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
