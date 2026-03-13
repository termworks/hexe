const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;

pub fn handleBlockingFloatCompletion(state: *State, pane: *Pane) void {
    const entry = state.pending_float_requests.fetchRemove(pane.uuid) orelse return;

    if (entry.value.cursor_snapshot) |snapshot| {
        state.cursor_restore_snapshot = snapshot;
        state.cursor_needs_restore = false;
    }

    // If closed via exit key, return error exit code (130 = terminated by signal)
    const exit_code: i32 = if (state.paneClosedByExitKey(pane.uuid)) 130 else state.paneExitCode(pane.uuid);
    var stdout: ?[]u8 = null;
    defer if (stdout) |out| state.allocator.free(out);

    if (entry.value.result_path) |path| {
        const content = std.fs.cwd().readFileAlloc(state.allocator, path, 1024 * 1024) catch null;
        if (content) |buf| {
            const trimmed = std.mem.trimRight(u8, buf, " \n\r\t");
            if (trimmed.len > 0) {
                stdout = state.allocator.dupe(u8, trimmed) catch null;
            }
            state.allocator.free(buf);
        }
        std.fs.cwd().deleteFile(path) catch {};
        state.allocator.free(path);
    }

    // Send FloatResult to SES on the ctl channel.
    const ctl_fd = state.runtime.getCtlFd() orelse return;
    const output = stdout orelse "";
    const result = wire.FloatResult{
        .uuid = pane.uuid,
        .exit_code = exit_code,
        .output_len = @intCast(output.len),
    };
    wire.writeControlWithTrail(ctl_fd, .float_result, std.mem.asBytes(&result), output) catch {};
}
