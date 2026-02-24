# nix-linux-builder — Open-source Linux VM builder for nix on macOS
# Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
# Apache License 2.0

# ─── Configuration ────────────────────────────────────────────────────────────

# Use system SDK for Virtualization.framework (macOS 13+ headers).
# SDKROOT should be set by the nix devShell or export manually.
SDKROOT  ?= $(shell xcrun --show-sdk-path)

CC       ?= clang
OBJC     ?= clang

# Strict warning flags for project code. Catches common bugs, implicit
# conversions, format-string issues, and missing prototypes.
# Note: -Wpedantic omitted — it flags __VA_OPT__ (used in log.h) as a C23
# extension under -std=c11, producing noise without catching real bugs.
WARN_FLAGS := -Wall -Wextra -Wstrict-prototypes -Wmissing-prototypes \
              -Wformat=2 -Wformat-security -Wconversion -Wsign-conversion \
              -Wundef -Wshadow -Wdouble-promotion -Wnull-dereference \
              -Wimplicit-fallthrough -Werror=return-type \
              -Werror=implicit-function-declaration

# Hardening flags: stack canaries and compile-time buffer overflow detection.
# PIE is the default on macOS so -fPIE is not needed.
HARDEN_FLAGS := -fstack-protector-strong -D_FORTIFY_SOURCE=2

# -MMD -MP: generate .d dependency files for header tracking so that
# changes to .h files trigger recompilation of dependent .o files.
DEPFLAGS  := -MMD -MP

CFLAGS    := $(WARN_FLAGS) $(HARDEN_FLAGS) $(DEPFLAGS) -O2 -std=c11
OBJCFLAGS := $(WARN_FLAGS) $(HARDEN_FLAGS) $(DEPFLAGS) -O2 -fobjc-arc -isysroot $(SDKROOT) -mmacosx-version-min=13.0
LDFLAGS   := -isysroot $(SDKROOT) -mmacosx-version-min=13.0 -framework Foundation -framework Virtualization

SRCDIR   := src
TESTDIR  := tests
BUILDDIR := .build
BINARY   := $(BUILDDIR)/nix-linux-builder

# cJSON: vendored single-file library — build with minimal warnings only.
CJSON_CFLAGS := -Wall -O2 -std=c11 -DCJSON_HIDE_SYMBOLS $(DEPFLAGS)

# Unity: vendored test framework — build with minimal warnings.
UNITY_CFLAGS := -Wall -O2 -std=c11 $(DEPFLAGS)

# Source files — project code (strict warnings)
PROJ_C_SRCS := $(SRCDIR)/cli.c $(SRCDIR)/build_json.c $(SRCDIR)/exitcode.c
OBJ_SRCS    := $(SRCDIR)/vm_config.m $(SRCDIR)/vm_lifecycle.m $(SRCDIR)/main.m

# Vendored code (relaxed warnings)
VENDOR_C_SRCS := $(SRCDIR)/cjson/cJSON.c

PROJ_C_OBJS   := $(patsubst $(SRCDIR)/%.c,$(BUILDDIR)/%.o,$(PROJ_C_SRCS))
VENDOR_C_OBJS := $(patsubst $(SRCDIR)/%.c,$(BUILDDIR)/%.o,$(VENDOR_C_SRCS))
OBJ_OBJS      := $(patsubst $(SRCDIR)/%.m,$(BUILDDIR)/%.o,$(OBJ_SRCS))
ALL_OBJS       := $(PROJ_C_OBJS) $(VENDOR_C_OBJS) $(OBJ_OBJS)

# ─── Test Configuration ──────────────────────────────────────────────────────

# Test binaries link against project .o files (no ObjC/framework deps).
# Each test_*.c links with unity.o + the relevant source .o files.
TEST_BINARIES := $(BUILDDIR)/test_cli $(BUILDDIR)/test_build_json $(BUILDDIR)/test_exitcode
UNITY_OBJ     := $(BUILDDIR)/unity.o

# ─── Colours ──────────────────────────────────────────────────────────────────

BOLD    := \033[1m
GREEN   := \033[32m
CYAN    := \033[36m
YELLOW  := \033[33m
RED     := \033[31m
RESET   := \033[0m

# ─── Default Target ──────────────────────────────────────────────────────────

.DEFAULT_GOAL := help

# ─── Building ────────────────────────────────────────────────────────────────

.PHONY: help build sign clean check test lint analyze ci \
       build-asan test-asan build-ubsan test-ubsan fuzz

help: ## 📖 Show this help message
	@printf "$(BOLD)nix-linux-builder$(RESET) — Open-source Linux VM builder for nix on macOS\n\n"
	@printf "$(BOLD)Usage:$(RESET)\n"
	@printf "  nix develop -c make <target>\n\n"
	@printf "$(BOLD)Targets:$(RESET)\n"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-15s$(RESET) %s\n", $$1, $$2}'

build: $(BINARY) ## 🔨 Build the nix-linux-builder binary
	@printf "$(GREEN)$(BOLD)✓$(RESET) Built $(BINARY)\n"

sign: build ## 🔏 Codesign with virtualization entitlement
	@printf "$(YELLOW)→$(RESET) Signing $(BINARY) with entitlements...\n"
	codesign --sign - --entitlements entitlements.plist --force $(BINARY)
	@printf "$(GREEN)$(BOLD)✓$(RESET) Signed $(BINARY)\n"

clean: ## 🗑  Remove build artifacts
	@printf "$(RED)→$(RESET) Cleaning build artifacts...\n"
	rm -rf $(BUILDDIR)
	@printf "$(GREEN)$(BOLD)✓$(RESET) Clean\n"

check: build ## ✅ Run basic sanity checks
	@printf "$(YELLOW)→$(RESET) Running sanity checks...\n"
	$(BINARY) --help || true
	@printf "$(GREEN)$(BOLD)✓$(RESET) Checks passed\n"

# ─── Testing ─────────────────────────────────────────────────────────────────

test: $(TEST_BINARIES) ## 🧪 Run unit tests
	@printf "$(YELLOW)→$(RESET) Running unit tests...\n"
	@fail=0; \
	for t in $(TEST_BINARIES); do \
		printf "$(CYAN)→$(RESET) $$t\n"; \
		$$t || fail=1; \
	done; \
	if [ $$fail -eq 0 ]; then \
		printf "$(GREEN)$(BOLD)✓$(RESET) All tests passed\n"; \
	else \
		printf "$(RED)$(BOLD)✗$(RESET) Some tests failed\n"; \
		exit 1; \
	fi

# ─── Static Analysis ──────────────────────────────────────────────────────────

# Project source files for linting (excludes vendored cJSON)
LINT_SRCS := $(PROJ_C_SRCS) $(wildcard $(SRCDIR)/*.m)

lint: ## 🔍 Run clang-tidy on project sources
	@printf "$(YELLOW)→$(RESET) Running clang-tidy...\n"
	@clang-tidy $(LINT_SRCS) -- $(CFLAGS) -I$(SRCDIR) 2>&1 | tail -n +2
	@printf "$(GREEN)$(BOLD)✓$(RESET) clang-tidy clean\n"

analyze: clean ## 🔬 Run Clang static analyzer (scan-build)
	@printf "$(YELLOW)→$(RESET) Running scan-build...\n"
	scan-build --status-bugs make -B build
	@printf "$(GREEN)$(BOLD)✓$(RESET) scan-build clean\n"

# ─── CI ──────────────────────────────────────────────────────────────────────

# ─── Sanitizer Targets ────────────────────────────────────────────────────────
# These rebuild from scratch with sanitizer flags. Use target-specific
# variables to inject sanitizer flags into CFLAGS/LDFLAGS.

ASAN_FLAGS := -fsanitize=address -fno-omit-frame-pointer -g
UBSAN_FLAGS := -fsanitize=undefined -fno-omit-frame-pointer -g

build-asan: ## 🛡  Build with AddressSanitizer
	@printf "$(YELLOW)→$(RESET) Building with AddressSanitizer...\n"
	$(MAKE) clean
	$(MAKE) build \
		CFLAGS="$(CFLAGS) $(ASAN_FLAGS)" \
		OBJCFLAGS="$(OBJCFLAGS) $(ASAN_FLAGS)" \
		LDFLAGS="$(LDFLAGS) $(ASAN_FLAGS)"

test-asan: ## 🛡  Run tests with AddressSanitizer
	@printf "$(YELLOW)→$(RESET) Building tests with AddressSanitizer...\n"
	$(MAKE) clean
	$(MAKE) test \
		CFLAGS="$(CFLAGS) $(ASAN_FLAGS)" \
		UNITY_CFLAGS="$(UNITY_CFLAGS) $(ASAN_FLAGS)" \
		CJSON_CFLAGS="$(CJSON_CFLAGS) $(ASAN_FLAGS)" \
		LDFLAGS="$(LDFLAGS) $(ASAN_FLAGS)"

build-ubsan: ## 🛡  Build with UndefinedBehaviorSanitizer
	@printf "$(YELLOW)→$(RESET) Building with UBSanitizer...\n"
	$(MAKE) clean
	$(MAKE) build \
		CFLAGS="$(CFLAGS) $(UBSAN_FLAGS)" \
		OBJCFLAGS="$(OBJCFLAGS) $(UBSAN_FLAGS)" \
		LDFLAGS="$(LDFLAGS) $(UBSAN_FLAGS)"

test-ubsan: ## 🛡  Run tests with UndefinedBehaviorSanitizer
	@printf "$(YELLOW)→$(RESET) Building tests with UBSanitizer...\n"
	$(MAKE) clean
	$(MAKE) test \
		CFLAGS="$(CFLAGS) $(UBSAN_FLAGS)" \
		UNITY_CFLAGS="$(UNITY_CFLAGS) $(UBSAN_FLAGS)" \
		CJSON_CFLAGS="$(CJSON_CFLAGS) $(UBSAN_FLAGS)" \
		LDFLAGS="$(LDFLAGS) $(UBSAN_FLAGS)"

# ─── Fuzzing ─────────────────────────────────────────────────────────────────

# Fuzzing requires LLVM clang with libFuzzer runtime (not Apple clang).
# Set FUZZ_CC to the nixpkgs LLVM clang path (the devShell provides it).
# Override with: make fuzz FUZZ_CC=/path/to/llvm/clang
FUZZ_CC      ?= clang
FUZZ_BINARY  := $(BUILDDIR)/fuzz_build_json

fuzz: $(FUZZ_BINARY) ## 🔀 Build libFuzzer harness for build.json parser
	@printf "$(GREEN)$(BOLD)✓$(RESET) Built $(FUZZ_BINARY)\n"
	@printf "$(CYAN)Run:$(RESET) $(FUZZ_BINARY) tests/fixtures/ [-max_total_time=60]\n"

$(FUZZ_BINARY): $(TESTDIR)/fuzz_build_json.c $(SRCDIR)/build_json.c $(SRCDIR)/cjson/cJSON.c
	@mkdir -p $(dir $@)
	@printf "$(CYAN)→$(RESET) Building fuzzer harness (requires LLVM clang)\n"
	$(FUZZ_CC) -fsanitize=fuzzer,address -g -O1 -std=c11 -DCJSON_HIDE_SYMBOLS \
		-I$(SRCDIR) -o $@ $^

# ─── CI ──────────────────────────────────────────────────────────────────────

ci: build test ## 🚀 Run full CI pipeline (build + test)
	@printf "$(GREEN)$(BOLD)✓$(RESET) CI passed\n"

# ─── Build Rules ──────────────────────────────────────────────────────────────

$(BINARY): $(ALL_OBJS)
	@mkdir -p $(dir $@)
	@printf "$(YELLOW)→$(RESET) Linking $(BINARY)...\n"
	$(OBJC) $(LDFLAGS) -o $@ $^

# Project C source files (strict warnings)
$(PROJ_C_OBJS): $(BUILDDIR)/%.o: $(SRCDIR)/%.c
	@mkdir -p $(dir $@)
	@printf "$(CYAN)→$(RESET) Compiling $<\n"
	$(CC) $(CFLAGS) -I$(SRCDIR) -c -o $@ $<

# Vendored C source files (relaxed warnings — we don't modify these)
$(VENDOR_C_OBJS): $(BUILDDIR)/%.o: $(SRCDIR)/%.c
	@mkdir -p $(dir $@)
	@printf "$(CYAN)→$(RESET) Compiling $< (vendored)\n"
	$(CC) $(CJSON_CFLAGS) -I$(SRCDIR) -c -o $@ $<

# Objective-C source files (strict warnings)
$(BUILDDIR)/%.o: $(SRCDIR)/%.m
	@mkdir -p $(dir $@)
	@printf "$(CYAN)→$(RESET) Compiling $<\n"
	$(OBJC) $(OBJCFLAGS) -I$(SRCDIR) -c -o $@ $<

# ─── Test Build Rules ────────────────────────────────────────────────────────

# Unity test framework (vendored, relaxed warnings)
$(UNITY_OBJ): $(TESTDIR)/unity/unity.c
	@mkdir -p $(dir $@)
	$(CC) $(UNITY_CFLAGS) -I$(TESTDIR) -c -o $@ $<

# Test: CLI parsing
$(BUILDDIR)/test_cli: $(TESTDIR)/test_cli.c $(BUILDDIR)/cli.o $(UNITY_OBJ)
	@mkdir -p $(dir $@)
	@printf "$(CYAN)→$(RESET) Building test_cli\n"
	$(CC) $(CFLAGS) -I$(SRCDIR) -I$(TESTDIR) -o $@ $^

# Test: build.json parsing
$(BUILDDIR)/test_build_json: $(TESTDIR)/test_build_json.c $(BUILDDIR)/build_json.o $(BUILDDIR)/cjson/cJSON.o $(UNITY_OBJ)
	@mkdir -p $(dir $@)
	@printf "$(CYAN)→$(RESET) Building test_build_json\n"
	$(CC) $(CFLAGS) -I$(SRCDIR) -I$(TESTDIR) -o $@ $^

# Test: exit code reading
$(BUILDDIR)/test_exitcode: $(TESTDIR)/test_exitcode.c $(BUILDDIR)/exitcode.o $(UNITY_OBJ)
	@mkdir -p $(dir $@)
	@printf "$(CYAN)→$(RESET) Building test_exitcode\n"
	$(CC) $(CFLAGS) -I$(SRCDIR) -I$(TESTDIR) -o $@ $^

# ─── Auto-generated Header Dependencies ──────────────────────────────────────
# Include .d files produced by -MMD -MP. On a clean build these don't exist
# yet, so the - prefix suppresses "No such file" errors.
-include $(wildcard $(BUILDDIR)/*.d $(BUILDDIR)/**/*.d)
