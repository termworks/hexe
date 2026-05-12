.PHONY: build test install release

build:
	zig build -Doptimize=ReleaseFast

test:
	zig build test -Doptimize=ReleaseFast

install: build
	install -Dm755 "./zig-out/bin/hexe" "$(HOME)/.local/bin/hexe"

# ==================================================================================================
# Release
# ==================================================================================================
TYPE ?= patch
HAS_REL := $(shell command -v git-rel 2>/dev/null)

release:
	@if [ -z "$(HAS_REL)" ]; then \
		echo "git-rel is not installed. Please install it first."; \
		exit 1; \
	fi
	@if [ -z "$(TYPE)" ]; then \
		echo "Release type not specified. Use 'make release TYPE=[patch|minor|major|m.m.p]'"; \
		exit 1; \
	fi
	@git rel $(TYPE)
