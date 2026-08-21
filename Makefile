.PHONY: build build-gnu test smoke smoke-protocol smoke-clean smoke-heavy install release \
        demos demo-fixture demo-record demo-publish demo-embed demo-clean \
        ghostty ghostty-check

# Static musl by default. Zig links its bundled musl STATICALLY for any
# *-linux-musl target, so this needs no extra linkage flag — the result has no
# dynamic loader and no glibc dependency, and runs on any x86_64 Linux.
#
# CPU stays at the target default (baseline) rather than `native`: a static
# binary exists to be portable, and the SIMD-heavy VT paths dispatch on the CPU
# at runtime anyway, so baseline costs nothing that matters here.
TARGET ?= x86_64-linux-musl

# ghostty-vt, patched.
#
# hexe needs one field ghostty does not have: an opaque per-cell tag recording
# which palette namespace wrote each cell. Rather than maintain a fork, the
# upstream revision is pinned here and the diff lives in patches/ as a file, so
# following ghostty is: bump GHOSTTY_REV, re-run `make ghostty`, fix the patch
# if it drifted. vendor/ is generated and not committed, so a fresh clone runs
# this once before building.
GHOSTTY_REV ?= 4e17eee5dea3d67aa9b0fec56be7f461c496ffe4
GHOSTTY_URL ?= https://github.com/ghostty-org/ghostty
GHOSTTY_DIR := vendor/ghostty

ghostty:
	@rm -rf $(GHOSTTY_DIR)
	@mkdir -p $(GHOSTTY_DIR)
	@cd $(GHOSTTY_DIR) && git init -q . && git remote add origin $(GHOSTTY_URL) && \
	  git fetch -q --depth 1 origin $(GHOSTTY_REV) && git checkout -q FETCH_HEAD
	@cd $(GHOSTTY_DIR) && git apply --whitespace=nowarn $(CURDIR)/patches/ghostty-vt-ns.patch
	@echo "ghostty $(GHOSTTY_REV) + patches/ghostty-vt-ns.patch -> $(GHOSTTY_DIR)"

# Fail with an instruction rather than a compile error a reader cannot place.
#
# The .git check is not cosmetic. ghostty's build derives its version from git,
# and $(GHOSTTY_DIR) lives inside this repo -- without a repo of its own, git
# walks up and finds OUR tags. That is fine until this repo is tagged, and then
# ghostty's build panics with "tagged releases must be in vX.Y.Z format",
# forty lines deep in a build runner and nowhere near the cause.
ghostty-check:
	@test -f $(GHOSTTY_DIR)/src/terminal/style.zig || { \
	  echo "$(GHOSTTY_DIR) is missing. Run: make ghostty"; exit 1; }
	@test -d $(GHOSTTY_DIR)/.git || { \
	  echo "$(GHOSTTY_DIR) has no .git, so ghostty's build will read THIS repo's"; \
	  echo "tags and panic. Run: make ghostty   (or: git -C $(GHOSTTY_DIR) init)"; \
	  exit 1; }

build: ghostty-check
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
	@# ONLY smoke processes. The old blanket `pkill -f zig-out/bin/hexe` killed
	@# the developer's OWN running hexe too, since a dev runs the same binary
	@# from this tree -- `make smoke` silently destroyed live sessions. Every
	@# smoke tags its processes with HEXE_INSTANCE=smk<pid>, so match on that.
	-@for p in $$(pgrep -f '[z]ig-out/bin/hexe' 2>/dev/null); do \
	    if tr '\0' '\n' < /proc/$$p/environ 2>/dev/null | grep -qx 'HEXE_INSTANCE=smk[0-9]*'; then \
	      kill -9 $$p 2>/dev/null || true; \
	    fi; \
	  done
	-rm -rf "$${HEXE_SMOKE_TMP:-/tmp/hexe-smoke}" 2>/dev/null || true
	-rm -rf "$${XDG_RUNTIME_DIR:-/tmp}"/hexe/smk* 2>/dev/null || true

# One recipe line per smoke made `make` stop at the first failure, so a single
# flake hid every test after it: a 25-minute run reported one result and left
# ~20 unknown. The list runs to completion and the tally decides the exit code.
# Set SMOKE_FAILFAST=1 to stop at the first failure instead (bisecting).
define run_smokes
@set -u; fail=""; pass=0; failed=0; \
for s in $(1); do \
  printf '\n=== %s\n' "$$s"; \
  if python3 -u scripts/$$s; then \
    pass=$$((pass+1)); \
  else \
    failed=$$((failed+1)); fail="$$fail $$s"; \
    if [ -n "$${SMOKE_FAILFAST:-}" ]; then \
      printf '\nSMOKE FAILFAST after %s\n' "$$s"; exit 1; \
    fi; \
  fi; \
done; \
printf '\n%d passed, %d failed\n' "$$pass" "$$failed"; \
if [ "$$failed" -ne 0 ]; then printf 'FAILED:%s\n' "$$fail"; exit 1; fi
endef

SMOKES := \
	smoke_reconnect.py \
	smoke_detach_reattach.py \
	smoke_fullscreen_reattach.py \
	smoke_paste.py \
	smoke_input_batch.py \
	smoke_terminal_protocol.py \
	smoke_kill.py \
	smoke_pane_info.py \
	smoke_lua_api.py \
	smoke_config_reload.py \
	smoke_recording.py \
	smoke_cli_waiter_release.py \
	smoke_stalled_peer.py \
	smoke_stalled_pod_peer.py \
	smoke_rate_limit_attach.py \
	smoke_log_not_in_tmp.py \
	smoke_pod_attach.py \
	smoke_wedged_ctl_reader.py \
	smoke_bighistory.py \
	smoke_dot_attach.py \
	smoke_attach_stress.py \
	smoke_attach_chaos.py \
	smoke_slow_exec.py \
	smoke_region_painter.py \
	smoke_startup_chooser.py \
	smoke_bad_config.py \
	smoke_session_env.py \
	smoke_float_concurrent.py \
	smoke_pod_record_input.py \
	smoke_exit_intent_concurrent.py \
	smoke_float_destroy.py \
	smoke_keypad.py \
	smoke_painter_showcase.py \
	smoke_profiles.py \
	smoke_palette.py \
	smoke_palette_persist.py \
	smoke_palette_fuzz.py \
	smoke_palette_cells.py \
	smoke_names.py \
	smoke_decor.py \
	smoke_float_state.py \
	smoke_api_socket.py \
	smoke_api_events.py \
	smoke_stale_daemon.py \
	smoke_api_geometry.py \
	smoke_status_zones.py

smoke: smoke-clean
	zig build
	$(call run_smokes,$(SMOKES))

smoke-protocol:
	zig build
	python3 -u scripts/smoke_terminal_protocol.py

# Heavy-load scenario: splits + floats + fullscreen apps + huge buffers +
# pastes, then chaos rounds. Needs a ReleaseFast build (Debug VT parsing is
# ~50x slower and cannot keep up with a 5-pod session).
HEAVY_SMOKES := \
	smoke_heavy.py \
	smoke_heavy2.py \
	smoke_multi_bighistory.py \
	smoke_input_flood.py \
	smoke_wedged.py \
	smoke_input_exactly_once.py \
	smoke_float.py \
	smoke_float_session.py \
	smoke_float_content.py \
	smoke_float_tui.py \
	smoke_input_after_float.py \
	smoke_float_toggle.py

smoke-heavy: smoke-clean
	zig build -Doptimize=ReleaseFast
	$(call run_smokes,$(HEAVY_SMOKES))

install: build
	install -Dm755 "./zig-out/bin/hexe" "$(HOME)/.local/bin/hexe"

# ==================================================================================================
# Feature demos
# ==================================================================================================
# One recording per document in docs/. Each is a script in scripts/demo,
# driven into a real frontend by record.py, so any of them can be made again
# after the code changes -- and a film that stops matching hexe is a bug in one
# or the other.
#
# The films are shot with the author's own ~/.config/hexe and ~/.config/oslo,
# copied into /tmp by fixture.sh (see the header there for the two things it
# changes on the way in), at 240x60, with oslo as the shell.
#
# Needs a ReleaseFast build: Debug VT parsing cannot keep up with a session
# being typed at.
DEMO ?=

demo-fixture:
	scripts/demo/fixture.sh

# `nice`, because a recording is seventeen hexe stacks in a row and the author
# is using the machine while it runs -- their shell prompt has a 10ms budget
# and falls back to its own the moment it is missed.
demo-record: build demo-fixture demo-clean
	@if [ -n "$(DEMO)" ]; then \
		nice -n 10 python3 -u scripts/demo/record.py scripts/demo/$(DEMO).demo; \
	else \
		for d in scripts/demo/*.demo; do nice -n 10 python3 -u scripts/demo/record.py "$$d" || exit 1; done; \
	fi
	@$(MAKE) --no-print-directory demo-clean

# Kill anything a demo left behind. A frontend whose recorder died does NOT
# exit when its pty closes -- it spins at 100% of a core -- so this is not
# tidiness, it is the difference between a usable machine and a hot one.
demo-clean:
	@# Bracketed so the pattern cannot match this shell itself.
	-@pkill -9 -f '[i]nstance dem' 2>/dev/null || true
	-@pkill -9 -f '[h]exe-demo-work' 2>/dev/null || true

demo-publish:
	scripts/demo/publish.sh $(DEMO)

demo-embed:
	scripts/demo/embed.sh

demos: demo-record demo-publish demo-embed

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
