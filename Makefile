CRYSTAL_CACHE_DIR ?= .crystal-cache
COVERAGE_DIR ?= coverage
COVERAGE_BIN ?= /tmp/clickhouse-coverage
KCOV_INCLUDE_PATH ?= $(CURDIR)/src
CRYSTAL_STDLIB_PATH ?= $(word 2,$(subst :, ,$(shell crystal env | sed -n 's/^CRYSTAL_PATH=//p')))
SPEC_ARGS ?= --tap

.PHONY: coverage

coverage:
	@if ! command -v kcov >/dev/null 2>&1; then \
		echo "kcov is required. Install it or run the coverage job in CI."; \
		exit 1; \
	fi
	CRYSTAL_CACHE_DIR=$(CRYSTAL_CACHE_DIR) crystal build coverage.cr --debug -o $(COVERAGE_BIN)
	CLICKHOUSE_INTEGRATION=0 kcov --clean --include-path="$(KCOV_INCLUDE_PATH)" --exclude-path="$(CRYSTAL_STDLIB_PATH)" $(COVERAGE_DIR) $(COVERAGE_BIN) $(SPEC_ARGS)
