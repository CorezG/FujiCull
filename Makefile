# FujiCull build commands (DESIGN §7, CONSTRAINTS.md).
# Command Line Tools only: Swift Testing needs the CLT framework path passed explicitly (ADR-001).

CLT        := /Library/Developer/CommandLineTools
TESTING    := $(CLT)/Library/Developer/Frameworks
TESTLIB    := $(CLT)/Library/Developer/usr/lib
TESTFLAGS  := -Xswiftc -F -Xswiftc $(TESTING) -Xlinker -F -Xlinker $(TESTING) \
              -Xlinker -rpath -Xlinker $(TESTING) -Xlinker -rpath -Xlinker $(TESTLIB)
STRICT     := -Xswiftc -warnings-as-errors
APP        := build/FujiCull.app
CHECK_BUDGET := 90

.PHONY: build test app run format lint check check-full clean

build:
	swift build -c release

test:
	swift test --enable-code-coverage $(TESTFLAGS)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/FujiCull $(APP)/Contents/MacOS/FujiCull
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)
	@echo "Built $(APP)"

run: app
	open $(APP)

format:
	swift format --in-place --recursive Sources Tests Package.swift

lint:
	swift format lint --strict --recursive Sources Tests Package.swift

# Every task-end check from CONSTRAINTS.md, in order, failing on the first problem.
check:
	@start=$$(date +%s); \
	set -e; \
	echo "== format";      $(MAKE) --no-print-directory lint; \
	echo "== compiler";    swift build $(STRICT); \
	echo "== floor";       python3 -I scripts/floor-guard.py; \
	echo "== boundaries";  sh scripts/check-boundaries.sh; \
	echo "== tests";       swift test --enable-code-coverage $(STRICT) $(TESTFLAGS); \
	echo "== coverage";    python3 -I scripts/check-coverage.py; \
	took=$$(( $$(date +%s) - start )); \
	echo "make check: passed in $${took}s (budget $(CHECK_BUDGET)s)"; \
	if [ $$took -gt $(CHECK_BUDGET) ]; then \
	  echo "make check: over the $(CHECK_BUDGET)s budget. Move slow tests behind FUJICULL_SLOW_TESTS (CONSTRAINTS.md)."; exit 1; \
	fi

# Checkpoint run: everything in check, plus tests gated behind FUJICULL_SLOW_TESTS. No time budget.
check-full:
	@set -e; \
	$(MAKE) --no-print-directory lint; \
	swift build $(STRICT); \
	python3 -I scripts/floor-guard.py; \
	sh scripts/check-boundaries.sh; \
	FUJICULL_SLOW_TESTS=1 swift test --enable-code-coverage $(STRICT) $(TESTFLAGS); \
	python3 -I scripts/check-coverage.py; \
	echo "make check-full: passed"

clean:
	swift package clean
	rm -rf build
