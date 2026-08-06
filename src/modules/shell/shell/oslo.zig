const std = @import("std");

/// oslo's init, which is **Lua rather than shell**.
///
/// Every other shell here is sent a snippet to `eval`. oslo's configuration is Lua and it has real
/// hooks, so the same integration is written as configuration instead of generated code — the
/// output of this goes into `~/.config/oslo/conf.d/` or is pulled in with `dofile`, not `eval`ed.
///
/// It is also a *better* integration than the shell ones, not a translation of them:
///
///   * `exit` is intercepted by a hook that may refuse, where zsh has to override the `accept-line`
///     ZLE widget and fish has to wrap `fish_exit`.
///   * Ctrl-D likewise, through the keystroke hook, rather than by rebinding a key to a widget.
///   * The command duration is measured by the shell and handed over, so nothing shells out to
///     `date +%s%3N` twice per command the way the bash and zsh snippets do.
///   * OSC 7 is not printed here at all — oslo emits it, and OSC 133, on its own.
///
/// `--shell=bash` is deliberate in the prompt calls: the zsh spelling wraps escapes in `%{ %}` so
/// zsh can count columns, and oslo measures visible width itself, so those markers would be
/// printed literally.
pub fn printInit(stdout: std.fs.File, no_comms: bool) !void {
    try stdout.writeAll(
        \\-- Hexe prompt initialization for oslo. This is Lua: put it in
        \\--   ~/.config/oslo/conf.d/20-hexe.lua
        \\-- or write `dofile(...)` for it from config.lua. Do not `eval` it.
        \\
        \\oslo.prompt.left = {
        \\  command = "hexe",
        \\  args = { "shp", "prompt", "--shell=bash", "--status=$status",
        \\           "--duration=$duration_ms", "--jobs=$jobs",
        \\           "--language=$language", "--vimode=$vimode" },
        \\  timeout_ms = 400,
        \\  async = false,
        \\}
        \\
        \\oslo.prompt.right = {
        \\  command = "hexe",
        \\  args = { "shp", "prompt", "--shell=bash", "--right", "--status=$status",
        \\           "--language=$language", "--vimode=$vimode" },
        \\  timeout_ms = 400,
        \\  async = false,
        \\}
        \\
    );

    if (no_comms) return;

    try stdout.writeAll(
        \\
        \\-- Hexe shell->mux communication hooks (oslo)
        \\
        \\local function pane() return oslo.env.get("HEXE_PANE_UUID") end
        \\
        \\local function connected()
        \\  return oslo.env.get("HEXE_MUX_SOCKET") ~= nil and pane() ~= nil
        \\end
        \\
        \\local function snapshot()
        \\  local id = pane()
        \\  if id then oslo.run{ "sh", "-c", "env -0 > /tmp/hexe-env-" .. id } end
        \\end
        \\
        \\local function may_exit()
        \\  return oslo.run{ "hexe", "shp", "exit-intent", capture = true }.ok
        \\end
        \\
        \\local function tell(...)
        \\  oslo.run{ "hexe", "shp", "shell-event", ..., capture = true }
        \\end
        \\
        \\-- A command is about to run. Returning `false` cancels it, which is how `exit` is held
        \\-- back -- the job zsh needs an `accept-line` widget override for.
        \\oslo.on.pre_cmd(function(c)
        \\  if not connected() then return end
        \\  if c.text == "exit" or c.text == "logout" then
        \\    if not may_exit() then return false end
        \\  end
        \\  snapshot()
        \\  tell("--phase=start", "--running", "--cmd=" .. c.text,
        \\       "--cwd=" .. c.cwd, "--jobs=" .. #oslo.job.list())
        \\end)
        \\
        \\-- It finished. `duration_ms` is measured by the shell, so no `date` is spawned for it.
        \\oslo.on.post_cmd(function(c)
        \\  if not connected() then return end
        \\  snapshot()
        \\  tell("--phase=end", "--cmd=" .. c.text, "--status=" .. c.status,
        \\       "--duration=" .. c.duration_ms, "--cwd=" .. c.cwd,
        \\       "--jobs=" .. #oslo.job.list())
        \\end)
        \\
        \\-- Ctrl-D on an empty line never becomes a command, so `pre_cmd` cannot see it. This runs
        \\-- before the editor acts, and `false` swallows the key.
        \\oslo.on.key(function(k)
        \\  if k.name == "delete" and k.text == "" and connected() and not may_exit() then
        \\    return false
        \\  end
        \\end)
        \\
        \\-- OSC 7 is deliberately absent: oslo emits it, and OSC 133, on every prompt and every
        \\-- directory change. Printing it here would send it twice.
        \\
    );
}
