//! Bare-`hexe` startup chooser.
//!
//! Running plain `hexe` in a directory asks two questions, in order, using the
//! normal MUX popup UI (not a line-mode prompt):
//!
//!   1. Are there other hexe sessions rooted at THIS directory? One -> confirm
//!      attaching to it; several -> pick from the list; none -> skip to (2).
//!   2. Is there a local `.hexe.lua`? -> confirm loading it.
//!
//! Declining both lands on a plain new session.
//!
//! The session deliberately has NO tab while a question is on screen: creating
//! one up front would spawn a shell (and a pod, and a SES pane record) that
//! answering "attach" immediately throws away, which is exactly how stray
//! adoptable panes get made. `State.startup_choice_pending` tells the loop to
//! hold off on its fallback tab and the renderer to draw only the popup.

const std = @import("std");
const core = @import("core");
const c = @cImport({
    @cInclude("stdlib.h");
});

const State = @import("state.zig").State;
const FrontendRuntime = core.FrontendRuntime;
const DetachedSessionInfo = core.FrontendDetachedSessionInfo;

pub const MAX_CANDIDATES = 16;


/// A same-cwd session offered as an attach target.
pub const Candidate = struct {
    id: [8]u8,
    name_buf: [64]u8,
    name_len: usize,
    pane_count: usize,
    attached: bool,

    pub fn name(self: *const Candidate) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// Collect the sessions rooted at `cwd`, excluding the caller's own.
///
/// Same filter as the `attach .` resolver: same base root, not us, at least
/// one pane, deduped by session id preferring the detached record.
pub fn collectSameDirSessions(
    allocator: std.mem.Allocator,
    runtime: *FrontendRuntime,
    out: *[MAX_CANDIDATES]Candidate,
) usize {
    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch return 0;
    defer allocator.free(cwd);

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
        if (base_root.len == 0 or !std.mem.eql(u8, base_root, cwd)) continue;

        var duplicate = false;
        for (out[0..n]) |*existing| {
            if (!std.mem.eql(u8, &existing.id, session.session_id[0..8])) continue;
            // Prefer the detached record of a session in park/steal transition.
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
        out[n] = .{
            .id = session.session_id[0..8].*,
            .name_buf = undefined,
            .name_len = name_len,
            .pane_count = session.pane_count,
            .attached = session.attached,
        };
        @memcpy(out[n].name_buf[0..name_len], raw_name[0..name_len]);
        n += 1;
    }
    return n;
}

fn hasLocalLayout() bool {
    if (std.fs.cwd().access(".hexe.lua", .{})) |_| return true else |_| return false;
}

/// Level 1: offer the same-cwd sessions. Falls through to level 2 when there
/// are none (or the popup could not be shown).
pub fn begin(state: *State) void {
    state.startup_choice_pending = true;

    var candidates: [MAX_CANDIDATES]Candidate = undefined;
    const count = collectSameDirSessions(state.allocator, state.runtime, &candidates);

    state.startup_attach_count = 0;
    for (candidates[0..count], 0..) |cand, i| {
        state.startup_attach_ids[i] = cand.id;
    }
    state.startup_attach_count = count;

    if (count == 0) {
        levelTwo(state);
        return;
    }

    if (count == 1) {
        var msg_buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Attach to session [{s}] {s} ({d} panes)?", .{
            candidates[0].id,
            candidates[0].name(),
            candidates[0].pane_count,
        }) catch "Attach to the existing session here?";
        if (!state.showConfirmOwnedOrNotify(.startup_attach_confirm, msg)) levelTwo(state);
        return;
    }

    var label_storage: [MAX_CANDIDATES][160]u8 = undefined;
    var labels: [MAX_CANDIDATES][]const u8 = undefined;
    // By pointer, not by value: the bufPrint fallback returns a slice into the
    // candidate, which must outlive this loop (it does — `candidates` lives
    // until showPickerOwned below has copied every label).
    for (candidates[0..count], 0..) |*cand, i| {
        const suffix: []const u8 = if (cand.attached) " (attached)" else "";
        labels[i] = std.fmt.bufPrint(&label_storage[i], "[{s}] {s} ({d} panes){s}", .{
            cand.id, cand.name(), cand.pane_count, suffix,
        }) catch cand.name();
    }
    // showPickerOwned copies the labels, so the stack storage above is fine.
    if (!state.showPickerOrNotify(.startup_attach_choose, labels[0..count], "Attach to session here")) {
        levelTwo(state);
    }
}

/// Level 2: offer the local `.hexe.lua`, else start plain.
pub fn levelTwo(state: *State) void {
    if (!hasLocalLayout()) {
        finishPlain(state);
        return;
    }
    if (!state.showConfirmOrNotify(.startup_layout_confirm, "Load local .hexe.lua layout?")) {
        finishPlain(state);
    }
}

/// Everything declined (or unavailable): plain new session.
pub fn finishPlain(state: *State) void {
    state.startup_choice_pending = false;
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

/// Attach to the candidate the user picked. Falls back to level 2 when the
/// session vanished between listing it and answering the popup.
pub fn attachSelected(state: *State, index: usize) void {
    if (index >= state.startup_attach_count) {
        levelTwo(state);
        return;
    }
    const prefix = state.startup_attach_ids[index];
    if (!state.reattachSession(&prefix)) {
        state.notifications.showFor("Session is gone", 1500);
        levelTwo(state);
        return;
    }

    state.startup_choice_pending = false;
    // Reattach can change the session uuid; panes spawned later must see the
    // new one (mirrors the --attach path in main.zig).
    var session_id_z: [33]u8 = undefined;
    const uuid = state.runtime.sessionUuid();
    @memcpy(session_id_z[0..32], &uuid);
    session_id_z[32] = 0;
    _ = c.setenv("HEXE_SESSION", &session_id_z, 1);

    state.notifications.show("Session reattached");
    state.needs_render = true;
    state.force_full_render = true;
}

/// The local-layout answer was yes. `load` performs the actual apply (owned by
/// loop_input, which already has the .hexe.lua parse/apply helpers).
pub fn finishLayout(state: *State, loaded: bool) void {
    state.startup_choice_pending = false;
    if (!loaded or state.view.tab_views.items.len == 0) {
        finishPlain(state);
        return;
    }
    state.adoptStickyPanes();
    state.needs_render = true;
    state.force_full_render = true;
}
