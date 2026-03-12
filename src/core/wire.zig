const std = @import("std");
const posix = std.posix;
const xev = @import("xev").Dynamic;

// ─────────────────────────────────────────────────────────────────────────────
// Protocol limits
// ─────────────────────────────────────────────────────────────────────────────

/// Maximum payload size for control messages and VT frames (4MB).
/// Prevents denial-of-service via oversized allocations.
pub const MAX_PAYLOAD_LEN: usize = @import("constants.zig").Sizes.max_payload_len;

/// Current protocol version. Increment when making breaking changes.
/// Sent as second byte after handshake byte.
pub const PROTOCOL_VERSION: u8 = 1;

/// Minimum supported protocol version for backward compatibility.
/// Clients with versions >= MIN_VERSION and <= PROTOCOL_VERSION are accepted.
pub const MIN_PROTOCOL_VERSION: u8 = 1;

/// Check if a client protocol version is supported.
pub fn isProtocolVersionSupported(version: u8) bool {
    return version >= MIN_PROTOCOL_VERSION and version <= PROTOCOL_VERSION;
}

/// Check if a client protocol version is deprecated (supported but old).
pub fn isProtocolVersionDeprecated(version: u8) bool {
    return version >= MIN_PROTOCOL_VERSION and version < PROTOCOL_VERSION;
}

// ─────────────────────────────────────────────────────────────────────────────
// Handshake bytes — first byte sent on a new connection to identify channel type.
// Second byte is always PROTOCOL_VERSION.
// ─────────────────────────────────────────────────────────────────────────────

/// Sent by a frontend to SES to open the control channel (①).
pub const SES_HANDSHAKE_FRONTEND_CTL: u8 = 0x01;
/// Sent by a frontend to SES to open the VT data channel (②).
pub const SES_HANDSHAKE_FRONTEND_VT: u8 = 0x02;
/// Legacy alias kept while terminal mux call sites are being rewritten.
pub const SES_HANDSHAKE_MUX_CTL: u8 = SES_HANDSHAKE_FRONTEND_CTL;
/// Legacy alias kept while terminal mux call sites are being rewritten.
pub const SES_HANDSHAKE_MUX_VT: u8 = SES_HANDSHAKE_FRONTEND_VT;
/// Sent by POD to SES to open the pod control uplink (④).
/// Followed by 16 raw bytes of UUID (binary, not hex).
pub const SES_HANDSHAKE_POD_CTL: u8 = 0x03;

/// Sent by CLI tool to SES for one-shot requests (focus_move, exit_intent, float).
pub const SES_HANDSHAKE_CLI: u8 = 0x04;

/// Sent by SES to POD to open the VT data channel (③).
pub const POD_HANDSHAKE_SES_VT: u8 = 0x01;
/// Sent by SHP to POD to open the shell control channel (⑤).
pub const POD_HANDSHAKE_SHP_CTL: u8 = 0x02;
/// Sent by CLI tools (pod send/attach) for auxiliary input (no backlog, no replace).
pub const POD_HANDSHAKE_AUX_INPUT: u8 = 0x03;
/// Sent by CLI tools for auxiliary output tap (observe-only, no replace).
pub const POD_HANDSHAKE_AUX_OBSERVER: u8 = 0x04;

// ─────────────────────────────────────────────────────────────────────────────
// Control message types — carried inside ControlHeader on channels ①④⑤.
// ─────────────────────────────────────────────────────────────────────────────

pub const MsgType = enum(u16) {
    // Channel ① — frontend ↔ SES control
    register = 0x0100,
    registered = 0x0101,
    create_pane = 0x0102,
    pane_created = 0x0103,
    destroy_pane = 0x0104,
    detach = 0x0105,
    reattach = 0x0106,
    session_state = 0x0107,
    notify = 0x0109,
    pop_confirm = 0x010A,
    pop_choose = 0x010B,
    pop_response = 0x010C,
    disconnect = 0x010D,
    orphan_pane = 0x010F,
    list_orphaned = 0x0110,
    adopt_pane = 0x0111,
    kill_pane = 0x0112,
    set_sticky = 0x0113,
    find_sticky = 0x0114,
    pane_info = 0x0115,
    update_pane_aux = 0x0116,
    update_pane_name = 0x0117,
    update_pane_shell = 0x0118,
    get_pane_cwd = 0x0119,
    list_sessions = 0x011A,
    ping = 0x011B,
    pong = 0x011C,
    ok = 0x011D,
    @"error" = 0x011E,
    pane_found = 0x011F,
    pane_not_found = 0x0120,
    orphaned_panes = 0x0121,
    sessions_list = 0x0122,
    session_reattached = 0x0123,
    session_detached = 0x0124,
    send_keys = 0x0125,
    broadcast_notify = 0x0126,
    targeted_notify = 0x0127,
    status = 0x0128,
    focus_move = 0x0129,
    exit_intent = 0x012A,
    exit_intent_result = 0x012B,
    float_request = 0x012C,
    float_created = 0x012D,
    float_result = 0x012E,
    pane_exited = 0x012F,
    replay_backlogs = 0x0130, // frontend tells SES it's ready for backlog replay
    kill_session = 0x0131, // CLI → SES: kill a detached session
    clear_sessions = 0x0132, // CLI → SES: kill all detached sessions
    clear_orphaned_panes = 0x0133, // CLI → SES: kill all orphaned/sticky panes
    get_layout = 0x0134, // CLI → SES: get layout export JSON for layout save
    apply_layout = 0x0135, // CLI → SES → terminal frontend: apply saved layout tree
    get_session_state = 0x0136, // CLI → SES: export detached session to JSON
    session_stolen = 0x0137, // SES → MUX: this session was attached elsewhere
    session_add_tab = 0x0138,
    session_remove_tab = 0x0139,
    session_sync_float = 0x013A,
    session_remove_float = 0x013B,
    session_split_pane = 0x013D,
    session_close_split_pane = 0x013E,
    session_replace_split_pane = 0x013F,
    session_set_split_ratio = 0x0140,

    // Channel ④ — POD → SES control
    cwd_changed = 0x0400,
    fg_changed = 0x0401,
    shell_event = 0x0402,
    title_changed = 0x0403,
    bell = 0x0404,
    exited = 0x0405,
    query_state = 0x0406,
    pod_register = 0x0407,

    // Channel ⑤ — SHP → POD control
    shp_shell_event = 0x0500,
    shp_prompt_req = 0x0501,
    shp_prompt_resp = 0x0502,

    _,
};

// ─────────────────────────────────────────────────────────────────────────────
// Headers
// ─────────────────────────────────────────────────────────────────────────────

/// 6-byte control message header (all control channels).
pub const ControlHeader = extern struct {
    msg_type: u16 align(1),
    payload_len: u32 align(1),
};

/// 7-byte multiplexed VT header (channel ②: MUX↔SES, many panes on one fd).
pub const MuxVtHeader = extern struct {
    pane_id: u16 align(1),
    frame_type: u8 align(1),
    len: u32 align(1),
};

// ─────────────────────────────────────────────────────────────────────────────
// Channel ① payloads — frontend ↔ SES control
// ─────────────────────────────────────────────────────────────────────────────

pub const FrontendKind = enum(u8) {
    terminal = 1,
    web = 2,
    desktop = 3,
};

pub const FrontendTransportKind = enum(u8) {
    local_ipc = 1,
    liblink = 2,
    preconnected = 3,
};

/// Register: session_id[32] + keepalive(u8) + frontend_kind(u8) +
/// transport_kind(u8) + name_len(u16)
/// Followed by: name bytes (name_len).
pub const FrontendRegister = extern struct {
    session_id: [32]u8 align(1),
    keepalive: u8 align(1),
    frontend_kind: u8 align(1),
    transport_kind: u8 align(1),
    name_len: u16 align(1),
};
pub const Register = FrontendRegister;

/// Registered (response to Register).
/// Trailing data: resolved session_name (may differ from requested if collision).
pub const FrontendRegistered = extern struct {
    name_len: u16 align(1) = 0,
};
pub const Registered = FrontendRegistered;

/// CreatePane: lengths of variable fields.
/// Followed by: shell bytes, cwd bytes, sticky_pwd bytes, isolation_profile bytes,
/// optionally inherit_env_parent_uuid bytes (32 bytes when inherit_env_parent_uuid_len > 0),
/// then env_count entries each prefixed with u16 len.
pub const CreatePane = extern struct {
    shell_len: u16 align(1),
    cwd_len: u16 align(1),
    sticky_key: u8 align(1),
    sticky_pwd_len: u16 align(1),
    isolation_profile_len: u8 align(1),
    inherit_env_parent_uuid_len: u8 align(1) = 0,
    env_count: u16 align(1) = 0,
};

/// PaneCreated (response to CreatePane).
/// Followed by: socket_path bytes (socket_path_len).
pub const PaneCreated = extern struct {
    uuid: [32]u8 align(1),
    pid: i32 align(1),
    pane_id: u16 align(1),
    socket_path_len: u16 align(1),
};

/// DestroyPane / KillPane / OrphanPane. No trailing data.
pub const PaneUuid = extern struct {
    uuid: [32]u8 align(1),
};

/// Detach: session_id only. SES detaches using its own canonical session snapshot.
pub const Detach = extern struct {
    session_id: [32]u8 align(1),
};

/// Reattach: prefix of session_id to match.
/// Followed by: session_id bytes (id_len).
pub const Reattach = extern struct {
    id_len: u16 align(1),
};

/// SessionReattached response.
/// Followed by: canonical session snapshot bytes (state_len), then pane_count * 32 bytes of UUIDs.
pub const SessionReattached = extern struct {
    state_len: u32 align(1),
    pane_count: u16 align(1),
};

/// Disconnect.
pub const Disconnect = extern struct {
    mode: u8 align(1), // 0=shutdown, 1=crash
    preserve_sticky: u8 align(1),
};

/// SessionAddTab: add a new tab with a single split pane to the canonical snapshot.
/// Followed by: tab name bytes (name_len).
pub const SessionAddTab = extern struct {
    tab_uuid: [32]u8 align(1),
    pane_uuid: [32]u8 align(1),
    tab_index: u16 align(1),
    name_len: u16 align(1),
};

/// SessionRemoveTab: remove a tab from the canonical snapshot.
pub const SessionRemoveTab = extern struct {
    tab_uuid: [32]u8 align(1),
    active_tab: u16 align(1),
    has_active_tab: u8 align(1),
};

/// SessionSyncFloat: upsert a float record in the canonical snapshot.
pub const SessionSyncFloat = extern struct {
    pane_uuid: [32]u8 align(1),
    active_tab: u16 align(1),
    parent_tab: u16 align(1),
    tab_visible: u64 align(1),
    has_active_tab: u8 align(1),
    has_parent_tab: u8 align(1),
    visible: u8 align(1),
    sticky: u8 align(1),
    is_pwd: u8 align(1),
    float_key: u8 align(1),
    width_pct: u8 align(1),
    height_pct: u8 align(1),
    pos_x_pct: u8 align(1),
    pos_y_pct: u8 align(1),
    pad_x: u8 align(1),
    pad_y: u8 align(1),
    active: u8 align(1),
};

/// SessionRemoveFloat: remove a float record from the canonical snapshot.
pub const SessionRemoveFloat = extern struct {
    pane_uuid: [32]u8 align(1),
};

/// SessionSplitPane: split one canonical split pane into a 50/50 split.
pub const SessionSplitPane = extern struct {
    tab_uuid: [32]u8 align(1),
    source_pane_uuid: [32]u8 align(1),
    new_pane_uuid: [32]u8 align(1),
    focused_pane_uuid: [32]u8 align(1),
    active_tab: u16 align(1),
    dir: u8 align(1),
    has_focused_pane: u8 align(1),
};

/// SessionCloseSplitPane: remove one split pane from the canonical split tree.
pub const SessionCloseSplitPane = extern struct {
    tab_uuid: [32]u8 align(1),
    pane_uuid: [32]u8 align(1),
    focused_pane_uuid: [32]u8 align(1),
    active_tab: u16 align(1),
    has_focused_pane: u8 align(1),
};

/// SessionReplaceSplitPane: replace one split pane UUID in the canonical split tree.
pub const SessionReplaceSplitPane = extern struct {
    tab_uuid: [32]u8 align(1),
    old_pane_uuid: [32]u8 align(1),
    new_pane_uuid: [32]u8 align(1),
    focused_pane_uuid: [32]u8 align(1),
    active_tab: u16 align(1),
    has_focused_pane: u8 align(1),
};

/// SessionSetSplitRatio: update one split divider by child anchor panes.
pub const SessionSetSplitRatio = extern struct {
    tab_uuid: [32]u8 align(1),
    first_anchor_uuid: [32]u8 align(1),
    second_anchor_uuid: [32]u8 align(1),
    active_tab: u16 align(1),
    ratio: f32 align(1),
};

/// Notify: message for the owning MUX.
/// Followed by: message bytes (msg_len).
pub const Notify = extern struct {
    msg_len: u16 align(1),
};

/// TargetedNotify: notification targeted at a specific UUID.
/// Followed by: message bytes (msg_len).
pub const TargetedNotify = extern struct {
    uuid: [32]u8 align(1),
    timeout_ms: i32 align(1), // 0 = use default duration
    msg_len: u16 align(1),
};

/// SendKeys: input to send to a pane.
/// uuid all-zeros = broadcast to all panes.
/// Followed by: key data bytes (data_len).
pub const SendKeys = extern struct {
    uuid: [32]u8 align(1),
    data_len: u16 align(1),
};

/// SetSticky: mark a pane as sticky for a pwd+key.
/// Followed by: pwd bytes (pwd_len).
pub const SetSticky = extern struct {
    uuid: [32]u8 align(1),
    key: u8 align(1),
    pwd_len: u16 align(1),
};

/// FindSticky: look up a sticky pane by pwd+key.
/// Followed by: pwd bytes (pwd_len).
pub const FindSticky = extern struct {
    key: u8 align(1),
    pwd_len: u16 align(1),
};

/// PaneFound (response to FindSticky/AdoptPane).
/// Followed by: socket_path bytes (socket_path_len).
pub const PaneFound = extern struct {
    uuid: [32]u8 align(1),
    pid: i32 align(1),
    pane_id: u16 align(1),
    socket_path_len: u16 align(1),
};

/// OrphanedPanes response.
/// Followed by: pane_count entries of OrphanedPaneEntry.
pub const OrphanedPanes = extern struct {
    pane_count: u16 align(1),
};

pub const OrphanedPaneEntry = extern struct {
    uuid: [32]u8 align(1),
    pid: i32 align(1),
};

/// SessionsList response.
/// Followed by: session_count entries of SessionEntry.
pub const SessionsList = extern struct {
    session_count: u16 align(1),
};

pub const SessionEntry = extern struct {
    session_id: [32]u8 align(1),
    pane_count: u16 align(1),
    name_len: u16 align(1),
    // Followed by: name bytes (name_len).
};

/// Error response.
/// Followed by: message bytes (msg_len).
pub const Error = extern struct {
    msg_len: u16 align(1),
};

/// UpdatePaneName: MUX syncs pane name to SES.
/// Followed by: name bytes (name_len). name_len=0 means clear.
pub const UpdatePaneName = extern struct {
    uuid: [32]u8 align(1),
    name_len: u16 align(1),
};

/// UpdatePaneAux: MUX syncs auxiliary pane info to SES.
/// Used for focus tracking (created_from, focused_from).
pub const UpdatePaneAux = extern struct {
    uuid: [32]u8 align(1),
    created_from: [32]u8 align(1),
    focused_from: [32]u8 align(1),
    active_tab: u16 align(1),
    has_created_from: u8 align(1),
    has_focused_from: u8 align(1),
    has_active_tab: u8 align(1),
    is_focused: u8 align(1),
};

/// UpdatePaneShell: MUX syncs shell metadata to SES.
/// Followed by: cmd bytes (cmd_len), then cwd bytes (cwd_len).
pub const UpdatePaneShell = extern struct {
    uuid: [32]u8 align(1),
    status: i32 align(1),
    has_status: u8 align(1),
    duration_ms: i64 align(1),
    has_duration: u8 align(1),
    jobs: u16 align(1),
    has_jobs: u8 align(1),
    cmd_len: u16 align(1),
    cwd_len: u16 align(1),
};

/// GetPaneCwd: request CWD for a pane.
pub const GetPaneCwd = extern struct {
    uuid: [32]u8 align(1),
};

/// PopConfirm: SES → MUX — show confirm dialog.
/// Followed by: message bytes (msg_len).
pub const PopConfirm = extern struct {
    uuid: [32]u8 align(1), // target UUID (all zeros = mux level)
    timeout_ms: i32 align(1), // 0 = no timeout
    msg_len: u16 align(1),
};

/// PopChoose: SES → MUX — show picker dialog.
/// Followed by: title bytes (title_len), then item_count items.
/// Each item is: u16 len + text bytes.
pub const PopChoose = extern struct {
    uuid: [32]u8 align(1), // target pane (all-zeros = mux level)
    timeout_ms: i32 align(1), // 0 = no timeout
    title_len: u16 align(1),
    item_count: u16 align(1),
};

/// PopResponse: MUX → SES — user's response to a popup.
pub const PopResponse = extern struct {
    response_type: u8 align(1), // 0=cancelled, 1=confirmed, 2=selected
    selected_idx: u16 align(1), // For picker: which item was selected
};

// ─────────────────────────────────────────────────────────────────────────────
// CLI → SES request payloads
// ─────────────────────────────────────────────────────────────────────────────

/// FocusMove: move focus in the given direction.
pub const FocusMove = extern struct {
    uuid: [32]u8 align(1), // pane UUID to identify which MUX
    dir: u8 align(1), // 0=left, 1=right, 2=up, 3=down
};

/// ExitIntent: shell asks mux permission before exiting.
pub const ExitIntent = extern struct {
    uuid: [32]u8 align(1),
};

/// ExitIntentResult: mux responds to exit_intent.
pub const ExitIntentResult = extern struct {
    allow: u8 align(1), // 0=deny, 1=allow
};

/// FloatRequest: create a floating pane.
/// Followed by: cmd (cmd_len), title (title_len), cwd (cwd_len),
/// result_path (result_path_len), exit_key (exit_key_len), then env_count entries each prefixed with u16 len.
pub const FloatRequest = extern struct {
    flags: u8 align(1), // bit 0: wait_for_exit, bit 1: isolated, bit 2: focus (dim background)
    cmd_len: u16 align(1),
    title_len: u16 align(1),
    cwd_len: u16 align(1),
    result_path_len: u16 align(1),
    exit_key_len: u8 align(1), // length of exit key string (e.g., "Esc", "q")
    isolation_profile_len: u8 align(1), // length of isolation profile string (e.g., "sandbox", "full")
    env_count: u16 align(1),
    // Size parameters (0 = use default)
    size_width: u16 align(1), // width percentage (0 = default)
    size_height: u16 align(1), // height percentage (0 = default)
    shift_x: i16 align(1), // horizontal shift from center (-50 to 50)
    shift_y: i16 align(1), // vertical shift from center (-50 to 50)
    // Source session ID as 32-char hex (zeroed if not called from within a mux session)
    source_session_id: [32]u8 align(1),
};

/// FloatCreated: response when float is created (no wait).
pub const FloatCreated = extern struct {
    uuid: [32]u8 align(1),
};

/// FloatResult: response when waited float exits.
pub const FloatResult = extern struct {
    uuid: [32]u8 align(1),
    exit_code: i32 align(1),
    output_len: u32 align(1),
};

/// KillSession: kill a specific detached session by name or UUID prefix.
/// Followed by: id bytes (id_len).
pub const KillSession = extern struct {
    id_len: u16 align(1),
};

/// KillSessionResult: response to kill_session.
/// If success=0, followed by error message bytes (error_len).
pub const KillSessionResult = extern struct {
    success: u8 align(1),
    killed_panes: u16 align(1),
    error_len: u16 align(1),
};

/// ClearSessionsResult: response to clear_sessions.
pub const ClearSessionsResult = extern struct {
    killed_sessions: u16 align(1),
    killed_panes: u16 align(1),
};

/// ClearOrphanedPanesResult: response to clear_orphaned_panes.
pub const ClearOrphanedPanesResult = extern struct {
    killed_panes: u16 align(1),
};

/// ApplyLayout: CLI → SES: apply a saved layout tree to the session owning uuid.
/// SES mutates canonical session state, then pushes a session snapshot event.
/// Followed by: tree_json bytes (tree_json_len).
pub const ApplyLayout = extern struct {
    uuid: [32]u8 align(1),
    tree_json_len: u32 align(1),
};

// ─────────────────────────────────────────────────────────────────────────────
// Channel ④ payloads — POD → SES control
// ─────────────────────────────────────────────────────────────────────────────

/// PodRegister: first message after handshake byte 0x03.
/// The 16-byte binary UUID is sent as part of the handshake, not in this struct.
/// This is a no-payload ack placeholder.
pub const PodRegister = extern struct {
    _pad: u8 align(1) = 0,
};

/// CwdChanged: pod detected cwd change.
/// Followed by: cwd bytes (cwd_len).
pub const CwdChanged = extern struct {
    uuid: [32]u8 align(1),
    cwd_len: u16 align(1),
};

/// FgChanged: pod detected foreground process change.
/// Followed by: process name bytes (name_len).
pub const FgChanged = extern struct {
    uuid: [32]u8 align(1),
    pid: i32 align(1),
    name_len: u16 align(1),
};

/// Exited: child process exited.
pub const Exited = extern struct {
    uuid: [32]u8 align(1),
    status: i32 align(1),
};

// ─────────────────────────────────────────────────────────────────────────────
// Channel ⑤ payloads — SHP ↔ POD control
// ─────────────────────────────────────────────────────────────────────────────

/// ShpShellEvent: shell integration metadata.
/// Followed by: cmd bytes (cmd_len), then cwd bytes (cwd_len).
pub const ShpShellEvent = extern struct {
    phase: u8 align(1), // 0=end, 1=start
    status: i32 align(1),
    duration_ms: i64 align(1),
    started_at: i64 align(1),
    jobs: u16 align(1),
    running: u8 align(1),
    cmd_len: u16 align(1),
    cwd_len: u16 align(1),
};

// ─────────────────────────────────────────────────────────────────────────────
// Channel ① — SES → MUX forwarded events
// ─────────────────────────────────────────────────────────────────────────────

/// ForwardedShellEvent: SES forwards shell event from POD to MUX.
/// Uses MsgType.shell_event on the MUX ctl channel.
/// Followed by: cmd bytes (cmd_len), then cwd bytes (cwd_len).
pub const ForwardedShellEvent = extern struct {
    uuid: [32]u8 align(1),
    phase: u8 align(1), // 0=end, 1=start
    status: i32 align(1),
    duration_ms: i64 align(1),
    started_at: i64 align(1),
    jobs: u16 align(1),
    running: u8 align(1),
    cmd_len: u16 align(1),
    cwd_len: u16 align(1),
};

/// PaneCwd response.
/// Followed by: cwd bytes (cwd_len).
pub const PaneCwd = extern struct {
    cwd_len: u16 align(1),
};

/// PaneInfo response (for get_pane_info queries).
/// Followed by: name (name_len), fg_process (fg_len), cwd (cwd_len),
///   tty (tty_len), socket_path (socket_path_len), session_name (session_name_len),
///   layout_path (layout_path_len), last_cmd (last_cmd_len),
///   base_process (base_process_len), sticky_pwd (sticky_pwd_len).
pub const PaneInfoResp = extern struct {
    uuid: [32]u8 align(1),
    pid: i32 align(1),
    fg_pid: i32 align(1),
    base_pid: i32 align(1),
    pane_id: u16 align(1),
    cols: u16 align(1),
    rows: u16 align(1),
    cursor_x: u16 align(1),
    cursor_y: u16 align(1),
    cursor_style: u8 align(1),
    cursor_visible: u8 align(1),
    alt_screen: u8 align(1),
    is_focused: u8 align(1),
    pane_type: u8 align(1), // 0=split, 1=float
    state: u8 align(1), // 0=attached, 1=detached, 2=sticky, 3=orphaned
    last_status: i32 align(1),
    has_last_status: u8 align(1),
    last_duration_ms: i64 align(1),
    has_last_duration: u8 align(1),
    last_jobs: u16 align(1),
    has_last_jobs: u8 align(1),
    created_at: i64 align(1),
    sticky_key: u8 align(1),
    has_sticky_key: u8 align(1),
    created_from: [32]u8 align(1),
    focused_from: [32]u8 align(1),
    has_created_from: u8 align(1),
    has_focused_from: u8 align(1),
    // Variable-length field lengths
    name_len: u16 align(1),
    fg_len: u16 align(1),
    cwd_len: u16 align(1),
    tty_len: u16 align(1),
    socket_path_len: u16 align(1),
    session_name_len: u16 align(1),
    layout_path_len: u16 align(1),
    last_cmd_len: u16 align(1),
    base_process_len: u16 align(1),
    sticky_pwd_len: u16 align(1),
};

/// StatusResp header for the status/list response.
/// Followed by: client_count StatusClient entries, detached_count DetachedSessionEntry,
///   orphaned_count StatusPaneEntry, sticky_count StickyPaneEntry.
pub const StatusResp = extern struct {
    client_count: u16 align(1),
    detached_count: u16 align(1),
    orphaned_count: u16 align(1),
    sticky_count: u16 align(1),
    full_mode: u8 align(1),
};

/// StatusClient entry (connected mux).
/// Followed by: name bytes (name_len), session snapshot bytes (session_state_len),
///   then pane_count StatusPaneEntry entries.
pub const StatusClient = extern struct {
    id: u16 align(1),
    session_id: [32]u8 align(1),
    has_session_id: u8 align(1),
    name_len: u16 align(1),
    pane_count: u16 align(1),
    session_state_len: u32 align(1),
};

/// StatusPaneEntry (pane within a client or orphaned pane).
/// Followed by: name bytes (name_len), sticky_pwd bytes (sticky_pwd_len).
pub const StatusPaneEntry = extern struct {
    uuid: [32]u8 align(1),
    pid: i32 align(1),
    name_len: u16 align(1),
    sticky_pwd_len: u16 align(1),
};

/// DetachedSessionEntry.
/// Followed by: name bytes (name_len), session snapshot bytes (session_state_len).
pub const DetachedSessionEntry = extern struct {
    session_id: [32]u8 align(1),
    name_len: u16 align(1),
    pane_count: u16 align(1),
    session_state_len: u32 align(1),
};

/// StickyPaneEntry.
/// Followed by: name bytes (name_len), pwd bytes (pwd_len).
pub const StickyPaneEntry = extern struct {
    uuid: [32]u8 align(1),
    pid: i32 align(1),
    key: u8 align(1),
    name_len: u16 align(1),
    pwd_len: u16 align(1),
};

// ─────────────────────────────────────────────────────────────────────────────
// I/O helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Write a control message (header + struct payload + optional trailing bytes).
pub fn writeControl(fd: posix.fd_t, msg_type: MsgType, payload: []const u8) !void {
    var hdr: ControlHeader = .{
        .msg_type = @intFromEnum(msg_type),
        .payload_len = @intCast(payload.len),
    };
    const hdr_bytes = std.mem.asBytes(&hdr);
    try writeAll(fd, hdr_bytes);
    if (payload.len > 0) {
        try writeAll(fd, payload);
    }
}

/// Write a control message with a fixed struct followed by trailing variable data.
pub fn writeControlWithTrail(fd: posix.fd_t, msg_type: MsgType, fixed: []const u8, trail: []const u8) !void {
    var hdr: ControlHeader = .{
        .msg_type = @intFromEnum(msg_type),
        .payload_len = @intCast(fixed.len + trail.len),
    };
    const hdr_bytes = std.mem.asBytes(&hdr);
    try writeAll(fd, hdr_bytes);
    if (fixed.len > 0) {
        try writeAll(fd, fixed);
    }
    if (trail.len > 0) {
        try writeAll(fd, trail);
    }
}

/// Write a control message composed of a fixed struct + up to 3 trailing slices.
pub fn writeControlMsg(fd: posix.fd_t, msg_type: MsgType, fixed: []const u8, trails: []const []const u8) !void {
    var total: usize = fixed.len;
    for (trails) |t| total += t.len;

    var hdr: ControlHeader = .{
        .msg_type = @intFromEnum(msg_type),
        .payload_len = @intCast(total),
    };
    const hdr_bytes = std.mem.asBytes(&hdr);
    try writeAll(fd, hdr_bytes);
    if (fixed.len > 0) {
        try writeAll(fd, fixed);
    }
    for (trails) |t| {
        if (t.len > 0) try writeAll(fd, t);
    }
}

/// Read a ControlHeader from fd. Blocks until 6 bytes arrive.
pub fn readControlHeader(fd: posix.fd_t) !ControlHeader {
    var buf: [@sizeOf(ControlHeader)]u8 = undefined;
    try readExact(fd, &buf);
    return std.mem.bytesToValue(ControlHeader, &buf);
}

/// Timeout-bounded ControlHeader read.
pub fn readControlHeaderTimeout(fd: posix.fd_t, timeout_ms: i32) !ControlHeader {
    var buf: [@sizeOf(ControlHeader)]u8 = undefined;
    try readExactTimeout(fd, &buf, timeout_ms);
    return std.mem.bytesToValue(ControlHeader, &buf);
}

/// Non-blocking variant: returns WouldBlock if no data available on first byte,
/// but waits on remaining bytes (header in-flight).
pub fn tryReadControlHeader(fd: posix.fd_t) !ControlHeader {
    var buf: [@sizeOf(ControlHeader)]u8 = undefined;
    // First byte: propagate WouldBlock (no data available).
    const first = posix.read(fd, buf[0..1]) catch |err| return err;
    if (first == 0) return error.ConnectionClosed;
    // Remaining bytes: wait with yield (header in-flight).
    var off: usize = 1;
    while (off < buf.len) {
        const n = posix.read(fd, buf[off..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
    return std.mem.bytesToValue(ControlHeader, &buf);
}

/// Read exactly `T` from the fd (fixed-size struct).
pub fn readStruct(comptime T: type, fd: posix.fd_t) !T {
    var buf: [@sizeOf(T)]u8 = undefined;
    try readExact(fd, &buf);
    return std.mem.bytesToValue(T, &buf);
}

/// Write a MuxVtHeader + payload.
pub fn writeMuxVt(fd: posix.fd_t, pane_id: u16, frame_type: u8, payload: []const u8) !void {
    var hdr: MuxVtHeader = .{
        .pane_id = pane_id,
        .frame_type = frame_type,
        .len = @intCast(payload.len),
    };
    const hdr_bytes = std.mem.asBytes(&hdr);
    try writeAll(fd, hdr_bytes);
    if (payload.len > 0) {
        try writeAll(fd, payload);
    }
}

/// Read a MuxVtHeader from fd.
pub fn readMuxVtHeader(fd: posix.fd_t) !MuxVtHeader {
    var buf: [@sizeOf(MuxVtHeader)]u8 = undefined;
    try readExact(fd, &buf);
    return std.mem.bytesToValue(MuxVtHeader, &buf);
}

/// Non-blocking variant: returns error.WouldBlock if no data available.
/// Once the first byte arrives, waits for the remaining header bytes.
pub fn tryReadMuxVtHeader(fd: posix.fd_t) !MuxVtHeader {
    var buf: [@sizeOf(MuxVtHeader)]u8 = undefined;
    // First byte: propagate WouldBlock (no frame available).
    const first = posix.read(fd, buf[0..1]) catch |err| return err;
    if (first == 0) return error.ConnectionClosed;
    // Remaining bytes: wait with timeout (frame is in-flight from SES).
    var off: usize = 1;
    while (off < buf.len) {
        const n = posix.read(fd, buf[off..]) catch |err| switch (err) {
            error.WouldBlock => {
                // Wait for more data with timeout
                waitReadableTimeout(fd, DEFAULT_IO_TIMEOUT_MS) catch |wait_err| return wait_err;
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
    return std.mem.bytesToValue(MuxVtHeader, &buf);
}

// ─────────────────────────────────────────────────────────────────────────────
// Low-level I/O
// ─────────────────────────────────────────────────────────────────────────────

/// Default timeout for network I/O operations (10 seconds).
pub const DEFAULT_IO_TIMEOUT_MS: i32 = 10_000;

/// Wait for fd readability with timeout. Returns error.Timeout on expiry.
fn waitForReadable(fd: posix.fd_t, timeout_ms: i32) !void {
    try xev.detect();

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var timer = try xev.Timer.init();
    defer timer.deinit();

    const WaitContext = struct {
        ready: bool = false,
        timed_out: bool = false,
    };

    var ctx: WaitContext = .{};
    var file_completion: xev.Completion = .{};
    var timer_completion: xev.Completion = .{};

    const waitCallback = struct {
        fn call(
            cb_ctx: ?*WaitContext,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.File,
            result: xev.PollError!xev.PollEvent,
        ) xev.CallbackAction {
            const c = cb_ctx orelse return .disarm;
            _ = result catch return .disarm;
            c.ready = true;
            return .disarm;
        }
    }.call;

    const timeoutCallback = struct {
        fn call(
            cb_ctx: ?*WaitContext,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            const c = cb_ctx orelse return .disarm;
            _ = result catch return .disarm;
            c.timed_out = true;
            return .disarm;
        }
    }.call;

    const watcher = xev.File.initFd(fd);
    watcher.poll(&loop, &file_completion, .read, WaitContext, &ctx, waitCallback);
    timer.run(&loop, &timer_completion, @intCast(@max(timeout_ms, 0)), WaitContext, &ctx, timeoutCallback);

    while (!ctx.ready and !ctx.timed_out) {
        try loop.run(.once);
    }

    if (ctx.ready) return;
    return error.Timeout;
}

pub fn waitReadableTimeout(fd: posix.fd_t, timeout_ms: i32) !void {
    return waitForReadable(fd, timeout_ms);
}

pub fn waitWritableTimeout(fd: posix.fd_t, timeout_ms: i32) !void {
    _ = fd;
    if (timeout_ms <= 0) return error.Timeout;
    try waitDelayTimeout(timeout_ms);
}

fn waitDelayTimeout(timeout_ms: i32) !void {
    if (timeout_ms <= 0) return error.Timeout;

    try xev.detect();
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    var timer = try xev.Timer.init();
    defer timer.deinit();

    const DelayContext = struct {
        done: bool = false,
    };
    var ctx: DelayContext = .{};
    var completion: xev.Completion = .{};

    const cb = struct {
        fn call(
            cctx: ?*DelayContext,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            const c = cctx orelse return .disarm;
            _ = result catch return .disarm;
            c.done = true;
            return .disarm;
        }
    }.call;

    timer.run(&loop, &completion, @intCast(timeout_ms), DelayContext, &ctx, cb);
    while (!ctx.done) {
        try loop.run(.once);
    }
}

pub fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    return writeAllTimeout(fd, data, DEFAULT_IO_TIMEOUT_MS);
}

pub fn writeAllTimeout(fd: posix.fd_t, data: []const u8, timeout_ms: i32) !void {
    const deadline_ms = std.time.milliTimestamp() + timeout_ms;
    var off: usize = 0;
    while (off < data.len) {
        const n = posix.write(fd, data[off..]) catch |err| switch (err) {
            error.WouldBlock => {
                const remaining_ms = deadline_ms - std.time.milliTimestamp();
                if (remaining_ms <= 0) return error.Timeout;
                const backoff_ms: i32 = @intCast(@min(remaining_ms, 10));
                waitWritableTimeout(fd, backoff_ms) catch |wait_err| return wait_err;
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}

pub fn readExact(fd: posix.fd_t, buf: []u8) !void {
    return readExactTimeout(fd, buf, DEFAULT_IO_TIMEOUT_MS);
}

pub fn readExactTimeout(fd: posix.fd_t, buf: []u8, timeout_ms: i32) !void {
    var off: usize = 0;
    var retries: usize = 0;
    const MAX_RETRIES = @import("constants.zig").Limits.max_wire_retries;

    while (off < buf.len) {
        const n = posix.read(fd, buf[off..]) catch |err| switch (err) {
            error.WouldBlock => {
                // Wait for fd to become readable with timeout
                waitReadableTimeout(fd, timeout_ms) catch |wait_err| return wait_err;
                retries += 1;
                if (retries > MAX_RETRIES) return error.TooManyRetries;
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.ConnectionClosed;
        off += n;
        retries = 0; // Reset retry counter on successful read
    }
}

/// Safely parse a struct from a byte buffer. Returns null if buffer is too small.
/// This avoids unsafe @ptrCast/@alignCast on potentially misaligned buffers.
pub fn bytesToStruct(comptime T: type, buf: []const u8) ?T {
    if (buf.len < @sizeOf(T)) return null;
    return std.mem.bytesToValue(T, buf[0..@sizeOf(T)]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Versioned Handshake Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Send a versioned handshake: [channel_type, PROTOCOL_VERSION].
pub fn sendHandshake(fd: posix.fd_t, channel_type: u8) !void {
    const handshake = [_]u8{ channel_type, PROTOCOL_VERSION };
    try writeAll(fd, &handshake);
}

/// Read a versioned handshake. Returns the channel type and version.
/// Returns error.UnsupportedVersion if version doesn't match.
pub fn readHandshake(fd: posix.fd_t) !struct { channel: u8, version: u8 } {
    var buf: [2]u8 = undefined;
    try readExact(fd, &buf);
    return .{ .channel = buf[0], .version = buf[1] };
}

/// Read handshake and validate version is within supported range.
pub fn readAndValidateHandshake(fd: posix.fd_t) !u8 {
    const hs = try readHandshake(fd);
    if (!isProtocolVersionSupported(hs.version)) return error.UnsupportedVersion;
    return hs.channel;
}
