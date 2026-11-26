//! Unified tab-less vaxis session chooser.
//!
//! Serves both bare `hexe` (startup chooser) and interactive `hexe attach`
//! (no args, `attach .` with multiple matches, or ambiguous `attach <prefix>`).
//!
//! The session deliberately has NO tab while a question is on screen: creating
//! one up front would spawn a shell (and a pod, and a SES pane record) that
//! answering "attach" or cancelling immediately throws away. `State.startup_choice_pending`
//! tells the loop to hold off on its fallback tab and the renderer to draw only
//! the popup.

const std = @import("std");
const core = @import("core");
const pop = @import("pop");
const c = @cImport({
    @cInclude("stdlib.h");
});

const State = @import("state.zig").State;
const ChooserMode = @import("state_types.zig").ChooserMode;
const FrontendRuntime = core.FrontendRuntime;
const DetachedSessionInfo = core.FrontendDetachedSessionInfo;

pub const MAX_CANDIDATES = 64;

/// A session offered as an attach target.
pub const Candidate = struct {
    id: [8]u8,
    name_buf: [64]u8,
    name_len: usize,
    root_buf: [256]u8,
    root_len: usize,
    pane_count: usize,
    attached: bool,
    in_cwd: bool,

    pub fn name(self: *const Candidate) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn root(self: *const Candidate) []const u8 {
        return self.root_buf[0..self.root_len];
    }
};

/// Collect sessions from SES, excluding our own freshly registered empty frontend.
/// Same-CWD sessions are sorted first, detached before attached within each group.
pub fn collectSessions(
    allocator: std.mem.Allocator,
    runtime: *FrontendRuntime,
    only_cwd: bool,
    out: *[MAX_CANDIDATES]Candidate,
) usize {
    const cwd_opt = std.fs.cwd().realpathAlloc(allocator, ".") catch null;
    defer if (cwd_opt) |cwd| allocator.free(cwd);

    var sessions: [64]DetachedSessionInfo = undefined;
    const count = runtime.listSessions(&sessions) catch return 0;
    const own_uuid: [32]u8 = runtime.sessionUuid();

    var n: usize = 0;
    for (sessions[0..count]) |session| {
        if (n >= MAX_CANDIDATES) break;
        if (std.mem.eql(u8, &session.session_id, &own_uuid)) continue;
        // Zero-pane sessions are frontends still booting or leftovers of an
        // aborted attach — never a meaningful target.
        if (session.pane_count == 0) continue;

        const base_root = session.base_root[0..session.base_root_len];
        const in_cwd = if (cwd_opt) |cwd|
            (base_root.len > 0 and std.mem.eql(u8, base_root, cwd))
        else
            false;
        if (only_cwd and !in_cwd) continue;

        var duplicate = false;
        for (out[0..n]) |*existing| {
            if (!std.mem.eql(u8, &existing.id, session.session_id[0..8])) continue;
            if (existing.attached and !session.attached) {
                existing.attached = false;
                existing.pane_count = session.pane_count;
            }
            duplicate = true;
            break;
        }
        if (duplicate) continue;

        const raw_name = session.session_name[0..session.session_name_len];
        const name_len = @min(raw_name.len, out[n].name_buf.len);
        const root_len = @min(base_root.len, out[n].root_buf.len);
        out[n] = .{
            .id = session.session_id[0..8].*,
            .name_buf = undefined,
            .name_len = name_len,
            .root_buf = undefined,
            .root_len = root_len,
            .pane_count = session.pane_count,
            .attached = session.attached,
            .in_cwd = in_cwd,
        };
        @memcpy(out[n].name_buf[0..name_len], raw_name[0..name_len]);
        @memcpy(out[n].root_buf[0..root_len], base_root[0..root_len]);
        n += 1;
    }

    // Sort: same-CWD first, then detached before attached, then by name.
    std.mem.sort(Candidate, out[0..n], {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            if (a.in_cwd != b.in_cwd) return a.in_cwd;
            if (a.attached != b.attached) return !a.attached;
            return std.ascii.lessThanIgnoreCase(a.name(), b.name());
        }
    }.lessThan);

    return n;
}

/// Convenience wrapper for callers that only want same-CWD sessions.
pub fn collectSameDirSessions(
    allocator: std.mem.Allocator,
    runtime: *FrontendRuntime,
    out: *[MAX_CANDIDATES]Candidate,
) usize {
    return collectSessions(allocator, runtime, true, out);
}

fn hasLocalLayout() bool {
    if (std.fs.cwd().access(".hexe.lua", .{})) |_| return true else |_| return false;
}

fn storeCandidates(state: *State, candidates: []const Candidate) void {
    state.startup_attach_count = 0;
    for (candidates, 0..) |cand, i| {
        if (i >= state.startup_attach_ids.len) break;
        state.startup_attach_ids[i] = cand.id;
        const nlen = @min(cand.name_len, state.startup_attach_names[i].len);
        @memcpy(state.startup_attach_names[i][0..nlen], cand.name_buf[0..nlen]);
        state.startup_attach_name_lens[i] = nlen;
        state.startup_attach_count = i + 1;
    }
}

fn openSessionPicker(state: *State, candidates: []const Candidate, is_attach_mode: bool) void {
    storeCandidates(state, candidates);

    var label_storage: [MAX_CANDIDATES][128]u8 = undefined;
    var badge_storage: [MAX_CANDIDATES][32]u8 = undefined;
    var detail_storage: [MAX_CANDIDATES][320]u8 = undefined;
    var labels: [MAX_CANDIDATES][]const u8 = undefined;
    var badges: [MAX_CANDIDATES][]const u8 = undefined;
    var details: [MAX_CANDIDATES][]const u8 = undefined;

    for (candidates, 0..) |*cand, i| {
        const display_name = if (cand.name_len > 0) cand.name() else cand.id[0..];
        const pane_word: []const u8 = if (cand.pane_count == 1) "pane" else "panes";
        labels[i] = std.fmt.bufPrint(&label_storage[i], "{s:<14} [{s}]", .{
            display_name, cand.id,
        }) catch display_name;

        badges[i] = if (cand.in_cwd and cand.attached)
            std.fmt.bufPrint(&badge_storage[i], "here · attached", .{}) catch "attached"
        else if (cand.in_cwd)
            std.fmt.bufPrint(&badge_storage[i], "here · detached", .{}) catch "here"
        else if (cand.attached)
            std.fmt.bufPrint(&badge_storage[i], "attached", .{}) catch "attached"
        else
            std.fmt.bufPrint(&badge_storage[i], "detached", .{}) catch "detached";

        var home_buf: [256]u8 = undefined;
        const root_disp: []const u8 = if (cand.root_len > 0)
            core.cli_ui.compactHome(cand.root(), &home_buf)
        else
            "-";
        const steal_note: []const u8 = if (cand.attached) " · steals active client" else "";
        details[i] = std.fmt.bufPrint(&detail_storage[i], "root: {s} · {d} {s}{s}", .{
            root_disp, cand.pane_count, pane_word, steal_note,
        }) catch root_disp;
    }

    const title: []const u8 = if (is_attach_mode) blk: {
        break :blk switch (state.startup_chooser_mode) {
            .attach_cwd => if (state.startup_show_all) "Attach to session (all)" else "Attach to session (this dir)",
            .attach_filter => "Attach to matching session",
            else => "Attach to session",
        };
    } else if (state.startup_show_all)
        "Sessions (all directories)"
    else
        "Sessions rooted here";

    const hint: []const u8 = if (is_attach_mode)
        "↑↓/jk move · / filter · l layouts · Enter attach · x kill · n new · r refresh · Esc cancel"
    else if (state.startup_show_all)
        "↑↓/jk move · / filter · l layouts · a here · n new · x kill · Enter attach · q quit"
    else
        "↑↓/jk move · / filter · l layouts · a all · n new · x kill · Enter attach · Esc skip";

    const initial_filter: ?[]const u8 = if (state.startup_initial_filter_len > 0)
        state.startup_initial_filter[0..state.startup_initial_filter_len]
    else
        null;

    const pending: @import("state_types.zig").PendingAction = if (is_attach_mode)
        .attach_choose
    else
        .startup_attach_choose;

    const ok = state.showPickerWithOptions(pending, labels[0..candidates.len], .{
        .title = title,
        .details = details[0..candidates.len],
        .badges = badges[0..candidates.len],
        .hint = hint,
        .filterable = true,
        .initial_filter = initial_filter,
        .action_keys = "anxrl",
    });

    if (!ok) {
        if (is_attach_mode) {
            state.startup_choice_pending = false;
            state.running = false;
        } else {
            levelTwo(state);
        }
    }
}

/// Bare `hexe` entry: level 1 offers same-cwd sessions, then falls through to `.hexe.lua` / plain new.
pub fn begin(state: *State) void {
    state.startup_choice_pending = true;
    state.startup_chooser_mode = .startup;
    state.startup_show_all = false;
    state.startup_initial_filter_len = 0;

    var candidates: [MAX_CANDIDATES]Candidate = undefined;
    const count = collectSessions(state.allocator, state.runtime, true, &candidates);
    storeCandidates(state, candidates[0..count]);

    if (count == 0) {
        levelTwo(state);
        return;
    }

    if (count == 1) {
        const cand = &candidates[0];
        var msg_buf: [160]u8 = undefined;
        var sub_buf: [256]u8 = undefined;
        var home_buf: [256]u8 = undefined;
        const pane_word: []const u8 = if (cand.pane_count == 1) "pane" else "panes";
        const status_str: []const u8 = if (cand.attached) "attached (will steal)" else "detached";
        const root_disp = if (cand.root_len > 0) core.cli_ui.compactHome(cand.root(), &home_buf) else ".";

        const msg = std.fmt.bufPrint(&msg_buf, "Attach to session '{s}'?", .{cand.name()}) catch "Attach to existing session here?";
        const sub = std.fmt.bufPrint(&sub_buf, "[{s}] · {d} {s} · {s} · {s}", .{
            cand.id, cand.pane_count, pane_word, status_str, root_disp,
        }) catch "";

        if (!state.showConfirmWithOptions(.startup_attach_confirm, msg, .{
            .default = .yes,
            .yes_label = "Attach",
            .no_label = "New",
            .subtitle = if (sub.len > 0) sub else null,
            .hint = "←/→/Tab toggle · Enter confirm · y attach · n new · q quit",
        })) {
            levelTwo(state);
        }
        return;
    }

    openSessionPicker(state, candidates[0..count], false);
}

/// Interactive `hexe attach` entry (no args, `attach .`, or ambiguous prefix).
pub fn beginAttach(state: *State, mode: ChooserMode, initial_filter: ?[]const u8) void {
    state.startup_choice_pending = true;
    state.startup_chooser_mode = mode;
    state.startup_show_all = (mode != .attach_cwd);
    state.startup_initial_filter_len = 0;
    if (initial_filter) |f| {
        const n = @min(f.len, state.startup_initial_filter.len);
        @memcpy(state.startup_initial_filter[0..n], f[0..n]);
        state.startup_initial_filter_len = n;
    }
    refreshPicker(state);
}

/// Re-query SES and re-open the current session picker (after refresh, toggle all/here, or kill).
pub fn refreshPicker(state: *State) void {
    const is_attach_mode = state.startup_chooser_mode != .startup;
    const only_cwd = !state.startup_show_all;

    var candidates: [MAX_CANDIDATES]Candidate = undefined;
    const count = collectSessions(state.allocator, state.runtime, only_cwd, &candidates);

    if (count == 0 and !state.startup_show_all and is_attach_mode) {
        // Fallback to all sessions if cwd became empty after killing the last one.
        state.startup_show_all = true;
        const all_count = collectSessions(state.allocator, state.runtime, false, &candidates);
        openSessionPicker(state, candidates[0..all_count], true);
        return;
    }

    openSessionPicker(state, candidates[0..count], is_attach_mode);
}

/// Handle a picker action hotkey ('a' toggle all/here, 'n' new session, 'x' kill, 'r' refresh).
pub fn handlePickerAction(state: *State, act: pop.PickerAction) void {
    switch (act.key) {
        'a' => {
            state.startup_show_all = !state.startup_show_all;
            state.startup_initial_filter_len = 0;
            refreshPicker(state);
        },
        'l' => {
            @import("layout_picker.zig").openStartupPicker(state);
        },
        'r' => {
            refreshPicker(state);
        },
        'n' => {
            state.startup_initial_filter_len = 0;
            if (state.startup_chooser_mode == .startup) {
                levelTwo(state);
            } else {
                finishPlain(state);
            }
        },
        'x' => {
            const idx = act.selected orelse {
                refreshPicker(state);
                return;
            };
            if (idx >= state.startup_attach_count) {
                refreshPicker(state);
                return;
            }
            state.startup_kill_target = state.startup_attach_ids[idx];
            const nlen = state.startup_attach_name_lens[idx];
            @memcpy(state.startup_kill_name[0..nlen], state.startup_attach_names[idx][0..nlen]);
            state.startup_kill_name_len = nlen;

            const sname = if (nlen > 0) state.startup_kill_name[0..nlen] else state.startup_kill_target[0..];
            var msg_buf: [160]u8 = undefined;
            var sub_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Kill session '{s}'?", .{sname}) catch "Kill selected session?";
            const sub = std.fmt.bufPrint(&sub_buf, "Session [{s}] and all its panes will be terminated", .{state.startup_kill_target}) catch "";
            if (!state.showConfirmWithOptions(.chooser_kill_confirm, msg, .{
                .default = .no,
                .yes_label = "Kill",
                .no_label = "Cancel",
                .subtitle = if (sub.len > 0) sub else null,
            })) {
                refreshPicker(state);
            }
        },
        else => refreshPicker(state),
    }
}

/// Execute confirmed kill of the selected candidate via SES CLI channel, then refresh picker.
pub fn confirmKillSelected(state: *State, confirmed: bool) void {
    if (confirmed) {
        if (killSessionViaCli(state.allocator, &state.startup_kill_target)) {
            state.notifications.showFor("Session killed", 1800);
        } else {
            state.notifications.showFor("Failed to kill session", 2000);
        }
    }
    refreshPicker(state);
}

fn killSessionViaCli(allocator: std.mem.Allocator, id_prefix: []const u8) bool {
    const wire = core.wire;
    const socket_path = core.ipc.getSesSocketPath(allocator) catch return false;
    defer allocator.free(socket_path);
    var client = core.ipc.Client.connect(socket_path) catch return false;
    defer client.close();
    const fd = client.fd;

    const timeout = std.posix.timeval{ .sec = 3, .usec = 0 };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};

    wire.sendCliHandshake(fd) catch return false;
    const kt = wire.KillTarget{ .id_len = @intCast(id_prefix.len) };
    wire.writeControlWithTrail(fd, .kill_target, std.mem.asBytes(&kt), id_prefix) catch return false;

    const hdr = wire.readControlHeader(fd) catch return false;
    if (@as(wire.MsgType, @enumFromInt(hdr.msg_type)) != .kill_target) return false;
    if (hdr.payload_len < @sizeOf(wire.KillTargetResult)) return false;
    const res = wire.readStruct(wire.KillTargetResult, fd) catch return false;
    return res.success != 0;
}

/// Level 2: offer the local `.hexe.lua`, else start plain.
pub fn levelTwo(state: *State) void {
    if (!hasLocalLayout()) {
        finishPlain(state);
        return;
    }
    var sub_buf: [160]u8 = undefined;
    const sub: ?[]const u8 = blk: {
        const needs = declaredNeeds(state.allocator) orelse break :blk "./.hexe.lua in current directory";
        if (!needs.any()) break :blk "./.hexe.lua in current directory";
        break :blk std.fmt.bufPrint(
            &sub_buf,
            "Also requests access to call your other tools (hexe.needs)",
            .{},
        ) catch "Also wants to call your other tools";
    };
    const question: []const u8 = blk: {
        const needs = declaredNeeds(state.allocator) orelse break :blk "Load local .hexe.lua layout?";
        if (!needs.any()) break :blk "Load local .hexe.lua layout?";
        break :blk "Load local .hexe.lua layout? (wants tool access)";
    };
    if (!state.showConfirmWithOptions(.startup_layout_confirm, question, .{
        .default = .yes,
        .yes_label = "Load",
        .no_label = "Plain",
        .subtitle = sub,
        .hint = "←/→/Tab toggle · Enter confirm · y load · n plain · q quit",
    })) {
        finishPlain(state);
    }
}

/// What `./.hexe.lua` declared, or null if it cannot be read.
fn declaredNeeds(allocator: std.mem.Allocator) ?core.lua_runtime.Needs {
    const bytes = std.fs.cwd().readFileAlloc(allocator, ".hexe.lua", 1 << 20) catch return null;
    defer allocator.free(bytes);
    return core.lua_runtime.Needs.parse(bytes);
}

/// Everything declined (or unavailable): plain new session.
pub fn finishPlain(state: *State) void {
    state.startup_choice_pending = false;
    state.startup_chooser_mode = .none;
    if (state.view.tab_views.items.len == 0) {
        state.createTab() catch |err| {
            core.logging.logError("terminal", "startup chooser: failed to create tab", err);
            state.running = false;
            return;
        };
    }
    state.adoptStickyPanes();
    state.needs_render = true;
    state.force_full_render = true;
}

/// Abort the chooser cleanly without creating a session or spawning stray pods.
pub fn abortChooser(state: *State) void {
    state.startup_choice_pending = false;
    state.startup_chooser_mode = .none;
    state.running = false;
}

/// Attach to the candidate the user picked.
pub fn attachSelected(state: *State, index: usize) void {
    if (index >= state.startup_attach_count) {
        if (state.startup_chooser_mode == .startup) {
            levelTwo(state);
        } else {
            refreshPicker(state);
        }
        return;
    }
    const prefix = state.startup_attach_ids[index];
    if (!state.reattachSession(&prefix)) {
        state.notifications.showFor("Session is no longer available", 1800);
        if (state.startup_chooser_mode == .startup) {
            levelTwo(state);
        } else {
            refreshPicker(state);
        }
        return;
    }

    state.startup_choice_pending = false;
    state.startup_chooser_mode = .none;
    var session_id_z: [33]u8 = undefined;
    const uuid = state.runtime.sessionUuid();
    @memcpy(session_id_z[0..32], &uuid);
    session_id_z[32] = 0;
    _ = c.setenv("HEXE_SESSION", &session_id_z, 1);

    state.notifications.show("Session attached");
    state.needs_render = true;
    state.force_full_render = true;
}

/// The local-layout answer was yes.
pub fn finishLayout(state: *State, loaded: bool) void {
    state.startup_choice_pending = false;
    state.startup_chooser_mode = .none;
    if (!loaded or state.view.tab_views.items.len == 0) {
        finishPlain(state);
        return;
    }
    state.adoptStickyPanes();
    state.needs_render = true;
    state.force_full_render = true;
}
