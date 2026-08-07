.PHONY: build build-gnu test smoke smoke-protocol smoke-clean smoke-heavy install release

# Static musl by default. Zig links its bundled musl STATICALLY for any
# *-linux-musl target, so this needs no extra linkage flag — the result has no
# dynamic loader and no glibc dependency, and runs on any x86_64 Linux.
#
# CPU stays at the target default (baseline) rather than `native`: a static
# binary exists to be portable, and the SIMD-heavy VT paths dispatch on the CPU
# at runtime anyway, so baseline costs nothing that matters here.
TARGET ?= x86_64-linux-musl

build:
	zig build -Doptimize=ReleaseFast -Dstrip=true -Dtarget=$(TARGET)

# Escape hatch: link against the host's glibc instead.
build-gnu:
	zig build -Doptimize=ReleaseFast -Dstrip=true

test:
	zig build test -Doptimize=ReleaseFast

# Live end-to-end smokes: real frontend under a pty, isolated HEXE_INSTANCE.
# Requires a debug build in zig-out (zig build) and python3.
# Kill anything the suite leaked and clear its scratch state.
#
# Each script's cleanup() only ran on the success path and inside fail(), so an
# unhandled exception or a `timeout` kill left the daemon, its pods and their
# shells running. That is fixed with atexit handlers now, but a machine that
# already accumulated leaks (or a hard SIGKILL) still needs this: leaked
# processes slow everything down until later smokes fail in ways that look
# exactly like product bugs. Measured directly -- smoke_heavy2 failed 2/2 on
# untouched develop with 39 leaked processes present, and passed once they
# were cleared, with no code change in between.
smoke-clean:
	@# Bracket the first char so the pattern cannot match this shell itself.
	-@pkill -9 -f '[z]ig-out/bin/hexe' 2>/dev/null || true
	-rm -rf "$${HEXE_SMOKE_TMP:-/tmp/hexe-smoke}" 2>/dev/null || true
	-rm -rf "$${XDG_RUNTIME_DIR:-/tmp}"/hexe/smk* 2>/dev/null || true

smoke: smoke-clean
	zig build
	python3 -u scripts/smoke_reconnect.py
	python3 -u scripts/smoke_detach_reattach.py
	python3 -u scripts/smoke_fullscreen_reattach.py
	python3 -u scripts/smoke_paste.py
	python3 -u scripts/smoke_input_batch.py
	python3 -u scripts/smoke_terminal_protocol.py
	python3 -u scripts/smoke_kill.py
	python3 -u scripts/smoke_cli_waiter_release.py
	python3 -u scripts/smoke_stalled_peer.py
	python3 -u scripts/smoke_stalled_pod_peer.py
	python3 -u scripts/smoke_rate_limit_attach.py
	python3 -u scripts/smoke_log_not_in_tmp.py
	python3 -u scripts/smoke_pod_attach.py
	python3 -u scripts/smoke_wedged_ctl_reader.py
	python3 -u scripts/smoke_bighistory.py
	python3 -u scripts/smoke_dot_attach.py
	python3 -u scripts/smoke_attach_stress.py
	python3 -u scripts/smoke_attach_chaos.py
	python3 -u scripts/smoke_slow_segments.py
	python3 -u scripts/smoke_startup_chooser.py
	python3 -u scripts/smoke_bad_config.py
	python3 -u scripts/smoke_session_env.py

smoke-protocol:
	zig build
	python3 -u scripts/smoke_terminal_protocol.py

# Heavy-load scenario: splits + floats + fullscreen apps + huge buffers +
# pastes, then chaos rounds. Needs a ReleaseFast build (Debug VT parsing is
# ~50x slower and cannot keep up with a 5-pod session).
smoke-heavy: smoke-clean
	zig build -Doptimize=ReleaseFast
	python3 -u scripts/smoke_heavy.py
	python3 -u scripts/smoke_heavy2.py
	python3 -u scripts/smoke_multi_bighistory.py
	python3 -u scripts/smoke_input_flood.py
	python3 -u scripts/smoke_wedged.py
	python3 -u scripts/smoke_input_exactly_once.py
	python3 -u scripts/smoke_float.py
	python3 -u scripts/smoke_float_session.py
	python3 -u scripts/smoke_float_content.py
	python3 -u scripts/smoke_float_tui.py
	python3 -u scripts/smoke_input_after_float.py
	python3 -u scripts/smoke_float_toggle.py

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
