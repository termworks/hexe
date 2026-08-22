const std = @import("std");

pub fn printInit(stdout: std.fs.File, no_comms: bool) !void {
    if (no_comms) return;

    try stdout.writeAll(
        \\# Hexe shell->mux communication hooks (Bash)
        \\__hexe_last_cmd=""
        \\__hexe_start=""
        \\
        \\__hexe_refresh_env_snapshot() {
        \\    [[ -n "$HEXE_ENV_FD" ]] || return 0
        \\    "${HEXE_BIN:-hexe}" shell env-save 2>/dev/null || true
        \\}
        \\
        \\__hexe_exit_intent() {
        \\    [[ -n "$HEXE_MUX_SOCKET" && -n "$HEXE_PANE_UUID" ]] || return 0
        \\    hexe shell exit-intent >/dev/null 2>/dev/null
        \\    return $?
        \\}
        \\
        \\__hexe_preexec() {
        \\    # DEBUG trap can fire multiple times per command (pipelines, traps, etc).
        \\    # Capture only the first event as the "command".
        \\    [[ -n "$__hexe_start" ]] && return 0
        \\    local cmd="$BASH_COMMAND"
        \\    case "$cmd" in
        \\        __shp_precmd|__shp_preexec|__hexe_precmd|__hexe_preexec) return 0 ;;
        \\        hexe\ shell\ shell-event*|hexe\ shell\ exit-intent*) return 0 ;;
        \\    esac
        \\    __hexe_last_cmd="$cmd"
        \\    __hexe_start=$(date +%s%3N)
        \\    __hexe_refresh_env_snapshot
        \\    hexe shell shell-event --phase=start --running --started-at=$__hexe_start --cmd="$__hexe_last_cmd" --cwd="$PWD" --jobs=$(jobs -p 2>/dev/null | wc -l) >/dev/null 2>/dev/null
        \\}
        \\
        \\__hexe_precmd() {
        \\    local exit_status=$?
        \\    [[ -n "$HEXE_MUX_SOCKET" && -n "$HEXE_PANE_UUID" ]] || { unset __hexe_start; unset __hexe_last_cmd; return 0; }
        \\
        \\    # OSC 7 cwd sync
        \\    printf '\033]7;file://%s%s\007' "${HOSTNAME:-localhost}" "$PWD" 2>/dev/null
        \\    __hexe_refresh_env_snapshot
        \\
        \\    local cmd="$__hexe_last_cmd"
        \\    if [[ -z "$cmd" ]]; then
        \\        # Fallback: use history when DEBUG capture isn't reliable.
        \\        local hist="$(history 1 2>/dev/null)"
        \\        cmd="$hist"
        \\        if [[ $hist =~ ^[[:space:]]*[0-9]+[[:space:]]*(.*)$ ]]; then
        \\            cmd="${BASH_REMATCH[1]}"
        \\        fi
        \\    fi
        \\
        \\    local jobs_count=$(jobs -p 2>/dev/null | wc -l)
        \\    hexe shell shell-event --phase=end --cmd="$cmd" --status=$exit_status --cwd="$PWD" --jobs=$jobs_count >/dev/null 2>/dev/null
        \\    unset __hexe_start
        \\    unset __hexe_last_cmd
        \\}
        \\
        \\exit() {
        \\    case $- in *i*) ;; *) builtin exit "$@" ;; esac
        \\    __hexe_exit_intent || return 0
        \\    builtin exit "$@"
        \\}
        \\
        \\logout() {
        \\    case $- in *i*) ;; *) builtin logout "$@" ;; esac
        \\    __hexe_exit_intent || return 0
        \\    builtin logout "$@"
        \\}
        \\
        \\__hexe_ctrl_d() {
        \\    if [[ -z "$READLINE_LINE" ]]; then
        \\        __hexe_exit_intent || { READLINE_LINE=""; READLINE_POINT=0; return; }
        \\        builtin exit
        \\    fi
        \\}
        \\
        \\bind -x '"\\C-d":__hexe_ctrl_d'
        \\
        \\# Extend existing timing hooks with comms.
        \\PROMPT_COMMAND="__shp_precmd;__hexe_precmd"
        \\trap '__shp_preexec;__hexe_preexec' DEBUG
        \\
    );
}
