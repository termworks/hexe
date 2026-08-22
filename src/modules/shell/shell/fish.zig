const std = @import("std");

pub fn printInit(stdout: std.fs.File, no_comms: bool) !void {
    if (no_comms) return;

    try stdout.writeAll(
        \\# Hexe shell->mux communication hooks (Fish)
        \\set -g __hexe_last_cmd ""
        \\
        \\function __hexe_refresh_env_snapshot
        \\    if not set -q HEXE_ENV_FD
        \\        return
        \\    end
        \\    if set -q HEXE_BIN; $HEXE_BIN shell env-save 2>/dev/null; else; hexe shell env-save 2>/dev/null; end
        \\end
        \\
        \\function __hexe_exit_intent
        \\    if not status is-interactive
        \\        return 0
        \\    end
        \\    if not set -q HEXE_MUX_SOCKET
        \\        return 0
        \\    end
        \\    if not set -q HEXE_PANE_UUID
        \\        return 0
        \\    end
        \\    hexe shell exit-intent >/dev/null 2>/dev/null
        \\    return $status
        \\end
        \\
        \\function exit
        \\    __hexe_exit_intent; or return 0
        \\    builtin exit $argv
        \\end
        \\
        \\function logout
        \\    exit $argv
        \\end
        \\
        \\function __hexe_ctrl_d
        \\    set -l line (commandline)
        \\    if test -z "$line"
        \\        __hexe_exit_intent; or begin
        \\            commandline ""
        \\            commandline -f repaint
        \\            return
        \\        end
        \\        exit
        \\    end
        \\    commandline -f delete-char
        \\end
        \\bind \\cd __hexe_ctrl_d
        \\
        \\function __hexe_fish_preexec --on-event fish_preexec
        \\    set -g __hexe_last_cmd (string join " " -- $argv)
        \\    set -g __hexe_start (date +%s%3N)
        \\    __hexe_refresh_env_snapshot
        \\    set -l jobs_count (count (jobs -p))
        \\    hexe shell shell-event --phase=start --running --started-at=$__hexe_start --cmd="$__hexe_last_cmd" --cwd="$PWD" --jobs=$jobs_count >/dev/null 2>/dev/null
        \\end
        \\
        \\function __hexe_fish_postexec --on-event fish_postexec
        \\    if not status is-interactive
        \\        return
        \\    end
        \\    if not set -q HEXE_MUX_SOCKET
        \\        return
        \\    end
        \\    if not set -q HEXE_PANE_UUID
        \\        return
        \\    end
        \\    set -l cmdline $__hexe_last_cmd
        \\    if test -z "$cmdline"
        \\        set cmdline (string join " " -- $argv)
        \\    end
        \\    # OSC 7 cwd sync
        \\    printf '\033]7;file://%s%s\007' "$hostname" "$PWD" 2>/dev/null
        \\    __hexe_refresh_env_snapshot
        \\    set -l jobs_count (count (jobs -p))
        \\    hexe shell shell-event --phase=end --cmd="$cmdline" --status=$status --cwd="$PWD" --jobs=$jobs_count >/dev/null 2>/dev/null
        \\end
        \\
    );
}
