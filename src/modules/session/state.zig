const std = @import("std");
const core = @import("core");
const session_model = core.session_model;
const locks_mod = @import("locks.zig");
const persistence_mod = @import("persistence.zig");
const polling_mod = @import("polling.zig");
const store_mod = @import("store.zig");
const api = @import("api.zig");

pub const SessionSnapshot = session_model.SessionSnapshot;
pub const PaneState = store_mod.PaneState;
pub const PaneType = store_mod.PaneType;
pub const Pane = store_mod.Pane;
pub const Client = store_mod.Client;
pub const DetachedSession = store_mod.DetachedSession;
pub const DetachedSessionState = store_mod.DetachedSessionState;
pub const SessionStore = store_mod.SessionStore;
pub const SessionLockState = locks_mod.SessionLockState;
pub const SessionLock = locks_mod.SessionLock;
pub const SessionLocks = locks_mod.SessionLocks;
pub const Persistence = persistence_mod.Persistence;
pub const PollingState = polling_mod.PollingState;

/// Top-level SES state — a thin composition over the four concerns above.
/// External API (public methods) is preserved: methods forward into the
/// appropriate substruct. Callers that previously reached fields directly
/// (e.g. `ses_state.panes`) now go through `ses_state.store.panes`.
///
/// Uses page_allocator internally to avoid GPA issues after fork/daemonization.
pub const SesState = struct {
    allocator: std.mem.Allocator,
    store: SessionStore,
    persistence: Persistence,
    polling: PollingState,
    locks: SessionLocks,

    /// The allocator argument is ignored: SES daemonizes by `fork()` + `exec()`-less
    /// continuation, and any heap-allocating bookkeeping that lives across the
    /// fork must be on `page_allocator` so the child doesn't inherit a broken
    /// GPA arena. The parameter is kept in the signature for call-site symmetry
    /// with other modules (and so tests can still pass `testing.allocator`
    /// without the callsite looking wrong).
    pub fn init(_: std.mem.Allocator) SesState {
        const page_alloc = std.heap.page_allocator;
        return .{
            .allocator = page_alloc,
            .store = SessionStore.init(page_alloc),
            .persistence = Persistence.init(page_alloc),
            .polling = .{},
            .locks = SessionLocks.init(page_alloc),
        };
    }

    pub const removePaneFromSessionSnapshot = api.removePaneFromSessionSnapshot;
    pub const ReattachResult = api.ReattachResult;

    pub const allocPaneId = api.allocPaneId;
    pub const updateClientSessionFocus = api.updateClientSessionFocus;
    pub const addClientSessionTab = api.addClientSessionTab;
    pub const removeClientSessionTab = api.removeClientSessionTab;
    pub const renameClientSessionTab = api.renameClientSessionTab;
    pub const splitClientSessionPane = api.splitClientSessionPane;
    pub const replaceClientSessionSplitPane = api.replaceClientSessionSplitPane;
    pub const setClientSessionSplitRatio = api.setClientSessionSplitRatio;
    pub const syncClientSessionFloat = api.syncClientSessionFloat;
    pub const removeClientSessionFloat = api.removeClientSessionFloat;
    pub const applyClientSessionLayoutTemplate = api.applyClientSessionLayoutTemplate;
    pub const resolveSessionName = api.resolveSessionName;
    pub const connectPodVt = api.connectPodVt;
    pub const markDirty = api.markDirty;
    pub const acquireSessionLock = api.acquireSessionLock;
    pub const releaseSessionLock = api.releaseSessionLock;
    pub const releaseClientLocks = api.releaseClientLocks;
    pub const isSessionLocked = api.isSessionLocked;
    pub const cancelPendingReattach = api.cancelPendingReattach;
    pub const deinit = api.deinit;
    pub const addClient = api.addClient;
    pub const removeClient = api.removeClient;
    pub const removeClientGraceful = api.removeClientGraceful;
    pub const shutdownClient = api.shutdownClient;
    pub const detachSession = api.detachSession;
    pub const reattachSession = api.reattachSession;
    pub const forceDetachAttachedSession = api.forceDetachAttachedSession;
    pub const removeDetachedSession = api.removeDetachedSession;
    pub const removePaneFromDetachedSessions = api.removePaneFromDetachedSessions;
    pub const isPaneParked = api.isPaneParked;
    pub const listDetachedSessions = api.listDetachedSessions;
    pub const getClient = api.getClient;
    pub const paneAttachedToClient = api.paneAttachedToClient;
    pub const createPane = api.createPane;
    pub const findStickyPane = api.findStickyPane;
    pub const findStickyPaneWithAffinity = api.findStickyPaneWithAffinity;
    pub const stealAttachedPane = api.stealAttachedPane;
    pub const attachPane = api.attachPane;
    pub const processBacklogReplays = api.processBacklogReplays;
    pub const suspendPane = api.suspendPane;
    pub const killPane = api.killPane;
    pub const getOrphanedPanes = api.getOrphanedPanes;
    pub const cleanupOrphanedPanes = api.cleanupOrphanedPanes;
    pub const cleanupExpiredDetachedSessions = api.cleanupExpiredDetachedSessions;
    pub const cleanupDetachedSessions = api.cleanupDetachedSessions;
    pub const checkPaneAlive = api.checkPaneAlive;
    pub const getPane = api.getPane;
    pub const killDetachedSession = api.killDetachedSession;
    pub const killAllDetachedSessions = api.killAllDetachedSessions;
    pub const killAllOrphanedPanes = api.killAllOrphanedPanes;
    pub const findDetachedSessionByNameOrPrefix = api.findDetachedSessionByNameOrPrefix;
};
