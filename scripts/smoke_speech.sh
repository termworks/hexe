#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
hexe=${HEXE_BIN:-"$root/zig-out/bin/hexe"}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/hexe-speech-smoke.XXXXXX")
instance="speech-smoke-$$"
uuid=0123456789abcdef0123456789abcdef

cleanup() {
    HEXE_INSTANCE="$instance" XDG_RUNTIME_DIR="$tmp/runtime" \
        HEXE_WHISPER_MODEL="$tmp/model.bin" \
        HEXE_SPEECH_RECORDER="$tmp/recorder" \
        "$hexe" speech cancel >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

mkdir -m 700 "$tmp/runtime"
: >"$tmp/model.bin"
cat >"$tmp/recorder" <<'EOF'
#!/bin/sh
: >"$1"
exec sleep 300
EOF
chmod 755 "$tmp/recorder"

run() {
    HEXE_INSTANCE="$instance" XDG_RUNTIME_DIR="$tmp/runtime" \
        HEXE_WHISPER_MODEL="$tmp/model.bin" \
        HEXE_SPEECH_RECORDER="$tmp/recorder" \
        "$hexe" "$@"
}

run speech start --uuid "$uuid" >/dev/null 2>&1
test "$(run speech status 2>&1)" = recording
run speech cancel >/dev/null 2>&1
test "$(run speech status 2>&1)" = idle

run speech start --uuid "$uuid" >/dev/null 2>&1 &
starter=$!
if run speech stop >"$tmp/stop.out" 2>&1; then
    echo "speech stop unexpectedly accepted the dummy model" >&2
    exit 1
fi
wait "$starter"
if grep -q "Speech recording did not start" "$tmp/stop.out"; then
    echo "speech stop lost the start/release race" >&2
    cat "$tmp/stop.out" >&2
    exit 1
fi
test "$(run speech status 2>&1)" = idle

run speech start --uuid "$uuid" >/dev/null 2>&1
state_dir="$tmp/runtime/hexe/$instance/speech"
recorder_pid=$(sed -n '1s/ .*//p' "$state_dir/rec.pid")
kill -9 "$recorder_pid" 2>/dev/null || true
sleep 0.05
test "$(run speech status 2>&1)" = idle
test ! -e "$state_dir/rec.pid"

echo "speech lifecycle smoke passed"
