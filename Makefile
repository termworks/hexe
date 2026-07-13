.PHONY: build test smoke install release

build:
	zig build -Doptimize=ReleaseFast

test:
	zig build test -Doptimize=ReleaseFast

# Live end-to-end smokes: real frontend under a pty, isolated HEXE_INSTANCE.
# Requires a debug build in zig-out (zig build) and python3.
smoke:
	zig build
	python3 -u scripts/smoke_reconnect.py
	python3 -u scripts/smoke_detach_reattach.py
	python3 -u scripts/smoke_fullscreen_reattach.py
	python3 -u scripts/smoke_paste.py
	python3 -u scripts/smoke_kill.py
	python3 -u scripts/smoke_bighistory.py
	python3 -u scripts/smoke_dot_attach.py
	python3 -u scripts/smoke_attach_stress.py

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
