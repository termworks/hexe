const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const log = std.log.scoped(.ipc);

fn setCloexec(fd: posix.fd_t) void {
    const flags = posix.fcntl(fd, posix.F.GETFD, 0) catch |err| {
        log.warn("failed to read fd flags for fd={d}: {}", .{ fd, err });
        return;
    };
    _ = posix.fcntl(fd, posix.F.SETFD, flags | 1) catch |err| {
        log.warn("failed to set cloexec for fd={d}: {}", .{ fd, err });
    };
}

/// Linux O_NONBLOCK. Kept in one place so the octal literal doesn't drift
/// across the several fd-setup sites that need it.
pub const O_NONBLOCK: usize = 0o4000;

/// Set a file descriptor non-blocking. Canonical helper; callers that prefer
/// log-and-continue wrap it with `catch`.
pub fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | O_NONBLOCK);
}

/// Clear O_NONBLOCK. `connect()` must hand back a blocking fd — that is what
/// every caller has always got, and the ones that want otherwise call
/// setNonBlocking themselves right after.
pub fn setBlocking(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(fd, posix.F.SETFL, flags & ~O_NONBLOCK);
}

/// How long a connect() may take before we give up.
///
/// A blocking connect() to a unix socket whose listen backlog is FULL parks in
/// the kernel forever — there is no timeout on it. The backlog here is 16, and a
/// peer that is wedged (or SIGSTOPped) stops calling accept(), so the backlog
/// fills. Both event loops connect: SES dials pods from its 1s tick
/// (connectPodVt, retried forever) and each POD dials SES from its own tick.
/// So one stuck process could hang the daemon — and every session with it —
/// with no way out. This is the bound that makes that impossible.
pub const CONNECT_TIMEOUT_MS: i32 = 2000;

/// Unix peer credentials returned by SO_PEERCRED.
pub const PeerCredentials = extern struct {
    pid: i32,
    uid: u32,
    gid: u32,
};

const SO_PEERCRED: u32 = 17;

/// Read the peer credentials for a connected Unix domain socket. Returns
/// null if the kernel call fails (non-Linux, unconnected socket, etc.).
pub fn getPeerCredentials(fd: posix.fd_t) ?PeerCredentials {
    var cred: PeerCredentials = undefined;
    var len: linux.socklen_t = @sizeOf(PeerCredentials);
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, SO_PEERCRED, @ptrCast(&cred), &len);
    if (rc != 0) return null;
    return cred;
}

/// Reject a connected peer unless it runs as the same UID as this process.
/// Set HEXE_ALLOW_CROSS_UID=1 in the environment to allow cross-UID access
/// (intended for test setups that legitimately need it).
pub fn verifyPeerUid(fd: posix.fd_t) bool {
    if (std.posix.getenv("HEXE_ALLOW_CROSS_UID")) |v| {
        if (std.mem.eql(u8, v, "1")) return true;
    }
    const cred = getPeerCredentials(fd) orelse return false;
    return cred.uid == linux.getuid();
}

/// Unix domain socket server for IPC
// All ipc fds are CLOEXEC: daemons fork+exec long-lived children (SES spawns
// pods, pods spawn the user's shell), and any inherited socket fd outlives its
// owner — a dead daemon's lock/listen/client fds held by pods break restart
// and half-open detection. Inherit nothing by default.
pub const Server = struct {
    fd: posix.fd_t,
    path: []const u8,
    allocator: std.mem.Allocator,

    fn accessSocketPath(path: []const u8) !void {
        if (std.fs.path.isAbsolute(path)) {
            return std.fs.accessAbsolute(path, .{});
        }
        return std.fs.cwd().access(path, .{});
    }

    fn deleteSocketPath(path: []const u8) !void {
        if (std.fs.path.isAbsolute(path)) {
            return std.fs.deleteFileAbsolute(path);
        }
        return std.fs.cwd().deleteFile(path);
    }

    fn makeSocketParentPath(path: []const u8) !void {
        const dir = std.fs.path.dirname(path) orelse return;
        // Same hazard as the log directory: with no XDG_RUNTIME_DIR the socket
        // dir lands under world-writable /tmp, where anyone can pre-create or
        // symlink it (PLAN.md A-6). Bind only into a directory we own.
        return ensurePrivateDir(dir);
    }

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Server {
        // Validate path length to avoid silent truncation
        if (path.len >= 108) return error.NameTooLong; // sockaddr_un.path max

        // Check if socket file exists and if something is listening
        if (accessSocketPath(path)) |_| {
            // Socket file exists - try to connect to see if something is listening
            const test_fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch {
                // Can't create socket, just try to delete the file
                deleteSocketPath(path) catch |err| {
                    if (err != error.FileNotFound) log.warn("failed to remove stale socket '{s}': {}", .{ path, err });
                };
                return initSocket(allocator, path);
            };
            defer posix.close(test_fd);

            var addr: posix.sockaddr.un = .{
                .family = posix.AF.UNIX,
                .path = undefined,
            };
            @memset(&addr.path, 0);
            const path_len = @min(path.len, addr.path.len - 1);
            @memcpy(addr.path[0..path_len], path[0..path_len]);

            if (posix.connect(test_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un))) |_| {
                // Connect succeeded - something is actually listening
                return error.AddressInUse;
            } else |_| {
                // Connect failed - stale socket, safe to remove
                deleteSocketPath(path) catch |err| {
                    if (err != error.FileNotFound) return err;
                };
            }
        } else |_| {
            // Socket file doesn't exist - nothing to clean up
        }

        return initSocket(allocator, path);
    }

    fn initSocket(allocator: std.mem.Allocator, path: []const u8) !Server {
        // Create socket
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(fd);
        setCloexec(fd);

        // Ensure parent directory exists
        try makeSocketParentPath(path);

        // Remove socket file if it still exists (race condition protection)
        deleteSocketPath(path) catch |err| {
            if (err != error.FileNotFound) return err;
        };

        // Bind to path
        var addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = undefined,
        };
        @memset(&addr.path, 0);
        const path_len = @min(path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], path[0..path_len]);

        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

        // Listen for connections
        try posix.listen(fd, 16);

        // Store path for cleanup
        const owned_path = try allocator.dupe(u8, path);

        return Server{
            .fd = fd,
            .path = owned_path,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Server) void {
        posix.close(self.fd);
        deleteSocketPath(self.path) catch |err| {
            if (err != error.FileNotFound) log.warn("failed to delete server socket '{s}': {}", .{ self.path, err });
        };
        self.allocator.free(self.path);
    }

    pub fn accept(self: *Server) !Connection {
        const client_fd = try posix.accept(self.fd, null, null, posix.SOCK.CLOEXEC);
        setCloexec(client_fd);
        return Connection{ .fd = client_fd };
    }

    /// Non-blocking accept, returns null if no connection pending
    pub fn tryAccept(self: *Server) !?Connection {
        // Set server socket to non-blocking temporarily for the accept check.
        const flags = posix.fcntl(self.fd, posix.F.GETFL, 0) catch |err| {
            log.warn("failed to read server fd flags for fd={d}: {}", .{ self.fd, err });
            return null;
        };
        _ = posix.fcntl(self.fd, posix.F.SETFL, flags | O_NONBLOCK) catch |err| {
            log.warn("failed to set server fd nonblocking for fd={d}: {}", .{ self.fd, err });
            return null;
        };
        defer _ = posix.fcntl(self.fd, posix.F.SETFL, flags) catch |err| {
            log.warn("failed to restore server fd flags for fd={d}: {}", .{ self.fd, err });
        };

        // Accept WITHOUT SOCK_NONBLOCK so the client fd is blocking.
        // This allows wire.readExact to work correctly without busy-spinning.
        const client_fd = posix.accept(self.fd, null, null, posix.SOCK.CLOEXEC) catch |err| {
            if (err == error.WouldBlock) return null;
            return err;
        };
        setCloexec(client_fd);
        return Connection{ .fd = client_fd };
    }

    pub fn getFd(self: Server) posix.fd_t {
        return self.fd;
    }
};

/// Client connection to a Unix domain socket
pub const Client = struct {
    fd: posix.fd_t,

    pub fn connect(path: []const u8) !Client {
        return connectTimeout(path, CONNECT_TIMEOUT_MS);
    }

    /// Connect with a hard time budget. The socket is made non-blocking only for
    /// the duration of the connect and handed back BLOCKING, which is what every
    /// caller has always received.
    pub fn connectTimeout(path: []const u8, timeout_ms: i32) !Client {
        // Validate path length to avoid silent truncation
        if (path.len >= 108) return error.NameTooLong; // sockaddr_un.path max

        const fd = try posix.socket(
            posix.AF.UNIX,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
            0,
        );
        setCloexec(fd);
        errdefer posix.close(fd);

        var addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = undefined,
        };
        @memset(&addr.path, 0);
        const path_len = @min(path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], path[0..path_len]);

        const deadline = std.time.milliTimestamp() + timeout_ms;
        while (true) {
            posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| switch (err) {
                // For AF_UNIX this is EAGAIN: the listener is alive but its
                // accept backlog is FULL (a wedged peer that stopped calling
                // accept). Unlike TCP it is not an "in progress" state — there
                // is nothing to wait for writability on, the connect simply has
                // to be retried. On a blocking fd the kernel does that retrying
                // for us, forever, with no way to give up; that is the hang.
                error.WouldBlock => {
                    if (std.time.milliTimestamp() >= deadline) return error.ConnectionTimedOut;
                    std.Thread.sleep(5 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
            break;
        }

        try setBlocking(fd);

        // Verify the SERVER's uid, not just the client's (PLAN.md A-5).
        // `verifyPeerUid` was called only on the accept side, so nothing
        // checked who we had just connected TO. Combined with the `/tmp`
        // fallback for the socket directory (A-6), another local user can bind
        // `ses.sock` first; the real daemon then fails with AddressInUse and
        // every frontend and CLI hands its session traffic — keystrokes
        // included — to whoever got there first. Checking here closes that for
        // every connect path at once, before a single handshake byte is sent.
        if (!verifyPeerUid(fd)) {
            log.warn("refusing to connect to {s}: socket is owned by another uid", .{path});
            return error.PeerUidMismatch;
        }

        return Client{ .fd = fd };
    }

    pub fn close(self: *Client) void {
        posix.close(self.fd);
    }

    pub fn toConnection(self: Client) Connection {
        return Connection{ .fd = self.fd };
    }
};

/// A connection that can send/receive data and file descriptors
pub const Connection = struct {
    fd: posix.fd_t,

    pub fn close(self: *Connection) void {
        posix.close(self.fd);
    }

    pub fn getFd(self: Connection) posix.fd_t {
        return self.fd;
    }

    /// Send data without file descriptor
    pub fn send(self: *Connection, data: []const u8) !void {
        var total_sent: usize = 0;
        while (total_sent < data.len) {
            const sent = try posix.write(self.fd, data[total_sent..]);
            if (sent == 0) return error.ConnectionClosed;
            total_sent += sent;
        }
    }
};

/// SCM_RIGHTS constant for passing file descriptors
const SCM_RIGHTS: c_int = 1;

const uuid_util = @import("uuid.zig");

/// Generate a random UUID (16 bytes as hex string = 32 chars)
pub fn generateUuid() [32]u8 {
    return uuid_util.generateHex();
}

/// Greek alphabet names for session naming
const greek_alphabet_names = [_][]const u8{
    "alpha",  "beta", "gamma", "delta", "epsilon",
    "zeta",   "eta",  "theta", "iota",  "kappa",
    "lambda", "mu",   "nu",    "xi",    "omicron",
    "pi",     "rho",  "sigma", "tau",   "upsilon",
    "phi",    "chi",  "psi",   "omega",
};

// Pokemon names for pane naming (inspired by krabby - https://github.com/yannjor/krabby)
// Gen 1-5 selection for variety
const pokemon_names = [_][]const u8{
    "bulbasaur",  "ivysaur",    "venusaur",   "charmander", "charmeleon",
    "charizard",  "squirtle",   "wartortle",  "blastoise",  "caterpie",
    "metapod",    "butterfree", "weedle",     "kakuna",     "beedrill",
    "pidgey",     "pidgeotto",  "pidgeot",    "rattata",    "raticate",
    "spearow",    "fearow",     "ekans",      "arbok",      "pikachu",
    "raichu",     "sandshrew",  "sandslash",  "nidoran-f",  "nidorina",
    "nidoqueen",  "nidoran-m",  "nidorino",   "nidoking",   "clefairy",
    "clefable",   "vulpix",     "ninetales",  "jigglypuff", "wigglytuff",
    "zubat",      "golbat",     "oddish",     "gloom",      "vileplume",
    "paras",      "parasect",   "venonat",    "venomoth",   "diglett",
    "dugtrio",    "meowth",     "persian",    "psyduck",    "golduck",
    "mankey",     "primeape",   "growlithe",  "arcanine",   "poliwag",
    "poliwhirl",  "poliwrath",  "abra",       "kadabra",    "alakazam",
    "machop",     "machoke",    "machamp",    "bellsprout", "weepinbell",
    "victreebel", "tentacool",  "tentacruel", "geodude",    "graveler",
    "golem",      "ponyta",     "rapidash",   "slowpoke",   "slowbro",
    "magnemite",  "magneton",   "farfetchd",  "doduo",      "dodrio",
    "seel",       "dewgong",    "grimer",     "muk",        "shellder",
    "cloyster",   "gastly",     "haunter",    "gengar",     "onix",
    "drowzee",    "hypno",      "krabby",     "kingler",    "voltorb",
    "electrode",  "exeggcute",  "exeggutor",  "cubone",     "marowak",
    "hitmonlee",  "hitmonchan", "lickitung",  "koffing",    "weezing",
    "rhyhorn",    "rhydon",     "chansey",    "tangela",    "kangaskhan",
    "horsea",     "seadra",     "goldeen",    "seaking",    "staryu",
    "starmie",    "mrmime",     "scyther",    "jynx",       "electabuzz",
    "magmar",     "pinsir",     "tauros",     "magikarp",   "gyarados",
    "lapras",     "ditto",      "eevee",      "vaporeon",   "jolteon",
    "flareon",    "porygon",    "omanyte",    "omastar",    "kabuto",
    "kabutops",   "aerodactyl", "snorlax",    "articuno",   "zapdos",
    "moltres",    "dratini",    "dragonair",  "dragonite",  "mewtwo",
    "mew",        "chikorita",  "bayleef",    "meganium",   "cyndaquil",
    "quilava",    "typhlosion", "totodile",   "croconaw",   "feraligatr",
    "sentret",    "furret",     "hoothoot",   "noctowl",    "ledyba",
    "ledian",     "spinarak",   "ariados",    "crobat",     "chinchou",
    "lanturn",    "pichu",      "cleffa",     "igglybuff",  "togepi",
    "togetic",    "natu",       "xatu",       "mareep",     "flaaffy",
    "ampharos",   "bellossom",  "marill",     "azumarill",  "sudowoodo",
    "politoed",   "hoppip",     "skiploom",   "jumpluff",   "aipom",
    "sunkern",    "sunflora",   "yanma",      "wooper",     "quagsire",
    "espeon",     "umbreon",    "murkrow",    "slowking",   "misdreavus",
    "unown",      "wobbuffet",  "girafarig",  "pineco",     "forretress",
    "dunsparce",  "gligar",     "steelix",    "snubbull",   "granbull",
    "qwilfish",   "scizor",     "shuckle",    "heracross",  "sneasel",
    "teddiursa",  "ursaring",   "slugma",     "magcargo",   "swinub",
    "piloswine",  "corsola",    "remoraid",   "octillery",  "delibird",
};

/// Generate a random Greek alphabet name for session naming
pub fn generateSessionName() []const u8 {
    var rand_byte: [1]u8 = undefined;
    std.crypto.random.bytes(&rand_byte);
    const index = rand_byte[0] % greek_alphabet_names.len;
    return greek_alphabet_names[index];
}

/// Generate a random Pokemon name for pane naming.
pub fn generatePaneName() []const u8 {
    var rand_byte: [1]u8 = undefined;
    std.crypto.random.bytes(&rand_byte);
    const index = rand_byte[0] % pokemon_names.len;
    return pokemon_names[index];
}

/// Generate tab name in format "session-N" (e.g. "alpha-1", "beta-2")
/// Caller owns the returned memory.
pub fn generateTabName(allocator: std.mem.Allocator, session_name: []const u8, tab_number: usize) ![]u8 {
    // Tab numbers start at 1 for user-facing display
    return std.fmt.allocPrint(allocator, "{s}-{d}", .{ session_name, tab_number + 1 });
}

const strings = @import("strings.zig");

fn sanitizeInstanceName(out: []u8, raw: []const u8) []const u8 {
    // NOTE: Unix domain socket paths have tight limits; keep this short.
    const sanitized = strings.sanitize(out, raw, 24);

    // Reject names made only of dots (PLAN.md A-11). `strings.sanitize` maps
    // `/` to `_`, so a separator cannot get through — but it deliberately keeps
    // `.`, which leaves `HEXE_INSTANCE=..` free to place this instance's
    // sockets, state and logs one directory ABOVE the namespace they are
    // supposed to be confined to (and `.` to collide with the un-namespaced
    // default). Returning empty makes every caller fall back to the plain
    // non-instance path, which is the same thing an unset variable does.
    for (sanitized) |ch| {
        if (ch != '.') return sanitized;
    }
    return sanitized[0..0];
}

test "sanitizeInstanceName rejects dot-only names but keeps dots elsewhere" {
    var buf: [32]u8 = undefined;

    // Traversal / collision attempts collapse to empty (= no instance).
    try testing.expectEqual(@as(usize, 0), sanitizeInstanceName(buf[0..], ".").len);
    try testing.expectEqual(@as(usize, 0), sanitizeInstanceName(buf[0..], "..").len);
    try testing.expectEqual(@as(usize, 0), sanitizeInstanceName(buf[0..], "....").len);

    // A dot is still legal inside an otherwise ordinary name.
    try testing.expectEqualStrings("my.instance", sanitizeInstanceName(buf[0..], "my.instance"));
    try testing.expectEqualStrings("smk123", sanitizeInstanceName(buf[0..], "smk123"));

    // Separators were already neutralised; confirm that still holds.
    try testing.expectEqualStrings("_.._etc", sanitizeInstanceName(buf[0..], "/../etc"));
}

/// Get the socket directory path
/// Per-user runtime directory to use when `XDG_RUNTIME_DIR` is unset.
///
/// Prefers `/run/user/<uid>` — the same directory the variable normally points
/// at, created 0700 and owned by us on any logind system — before falling back
/// to world-writable `/tmp` (PLAN.md A-6). Writing `buf`, returning a slice of
/// it or a static string.
///
/// Note this narrows exposure rather than being the whole defence: sockets are
/// bound through `makeSocketParentPath`, which runs `ensurePrivateDir` and
/// refuses any directory we do not own. `/tmp` pre-created or symlinked by
/// another user therefore fails closed already; this just stops us reaching for
/// `/tmp` at all when a private runtime dir is right there.
pub fn fallbackRuntimeDir(buf: []u8) []const u8 {
    const candidate = std.fmt.bufPrint(buf, "/run/user/{d}", .{linux.getuid()}) catch return "/tmp";
    var dir = std.fs.cwd().openDir(candidate, .{}) catch return "/tmp";
    defer dir.close();
    const st = std.posix.fstat(dir.fd) catch return "/tmp";
    if (!std.posix.S.ISDIR(st.mode)) return "/tmp";
    if (st.uid != linux.getuid()) return "/tmp";
    return candidate;
}

test "fallbackRuntimeDir prefers a private /run/user over world-writable /tmp" {
    var buf: [64]u8 = undefined;
    const got = fallbackRuntimeDir(&buf);

    var probe: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&probe, "/run/user/{d}", .{linux.getuid()});
    const have_private_runtime = blk: {
        var d = std.fs.cwd().openDir(expected, .{}) catch break :blk false;
        d.close();
        break :blk true;
    };

    if (have_private_runtime) {
        try std.testing.expectEqualStrings(expected, got);
    } else {
        // No private runtime dir on this host: /tmp is the only option left,
        // and ensurePrivateDir still refuses one we do not own.
        try std.testing.expectEqualStrings("/tmp", got);
    }
}

test "pod socket paths stay inside the sockaddr_un limit" {
    // The reason relocating the socket directory is risky at all: AF_UNIX paths
    // are capped at 108 bytes and Server.init rejects anything longer, so a
    // deeper base directory can break pane creation rather than merely move it.
    var buf: [64]u8 = undefined;
    const base = fallbackRuntimeDir(&buf);

    // Worst case the sanitiser permits: a 24-char instance name, plus the
    // longest thing we ever put in that directory (a 32-hex pod socket).
    const longest = base.len + "/hexe/".len + 24 + "/pod-".len + 32 + ".sock".len;
    try std.testing.expect(longest < 108);
}

pub fn getSocketDir(allocator: std.mem.Allocator) ![]const u8 {
    var fallback_buf: [64]u8 = undefined;
    const runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse fallbackRuntimeDir(&fallback_buf);

    const instance_raw = std.posix.getenv("HEXE_INSTANCE");
    if (instance_raw) |inst| {
        if (inst.len > 0) {
            var buf: [32]u8 = undefined;
            const sanitized = sanitizeInstanceName(buf[0..], inst);
            if (sanitized.len > 0) {
                return std.fmt.allocPrint(allocator, "{s}/hexe/{s}", .{ runtime_dir, sanitized });
            }
        }
    }

    return std.fmt.allocPrint(allocator, "{s}/hexe", .{runtime_dir});
}

/// Get the default ses socket path
pub fn getSesSocketPath(allocator: std.mem.Allocator) ![]const u8 {
    const dir = try getSocketDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/ses.sock", .{dir});
}

/// Get path to transaction log file for crash recovery.
pub fn getTxLogPath(allocator: std.mem.Allocator) ![]const u8 {
    const dir = try getSocketDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/ses.txlog", .{dir});
}

/// Get a pod socket path for a given pane UUID
pub fn getPodSocketPath(allocator: std.mem.Allocator, uuid: []const u8) ![]const u8 {
    const dir = try getSocketDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/pod-{s}.sock", .{ dir, uuid });
}

/// Path for ses persisted state (atomic overwrite)
pub fn getSesStatePath(allocator: std.mem.Allocator) ![]const u8 {
    const state_home_env = posix.getenv("XDG_STATE_HOME");
    const state_home = state_home_env orelse blk: {
        const home = posix.getenv("HOME") orelse "/tmp";
        break :blk try std.fmt.allocPrint(allocator, "{s}/.local/state", .{home});
    };
    defer if (state_home_env == null) allocator.free(state_home);

    const instance_raw = posix.getenv("HEXE_INSTANCE");
    if (instance_raw) |inst| {
        if (inst.len > 0) {
            var buf: [32]u8 = undefined;
            const sanitized = sanitizeInstanceName(buf[0..], inst);
            if (sanitized.len > 0) {
                const dir = try std.fmt.allocPrint(allocator, "{s}/hexe/{s}", .{ state_home, sanitized });
                defer allocator.free(dir);
                try std.fs.cwd().makePath(dir);
                return std.fmt.allocPrint(allocator, "{s}/hexe/{s}/ses_state.json", .{ state_home, sanitized });
            }
        }
    }

    const dir = try std.fmt.allocPrint(allocator, "{s}/hexe", .{state_home});
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);

    return std.fmt.allocPrint(allocator, "{s}/hexe/ses_state.json", .{state_home});
}

/// Create `path` if needed and refuse to use it unless WE own it (PLAN.md A-6).
///
/// hexe's runtime and log directories used to be created with a bare
/// `makePath` under world-writable `/tmp`, with no ownership or type check. A
/// local attacker who pre-creates `/tmp/hexe/<instance>` — or symlinks it at
/// one of the victim's files — gets hexe to write there, and the debug log
/// carries cwds, command lines and pane metadata.
///
/// The check is deliberately asymmetric: a directory we do not own is an
/// attack and hard-fails, while merely loose permissions on a directory we DO
/// own are tightened where possible and warned about otherwise. That avoids
/// bricking a daemon over a umask quirk while still refusing the real hazard.
pub fn ensurePrivateDir(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Open the directory and verify the fd, rather than stat-ing the name:
    // checking the path and then using it is a TOCTOU window.
    var dir = std.fs.cwd().openDir(path, .{}) catch |err| {
        log.warn("refusing to use {s}: cannot open it ({s})", .{ path, @errorName(err) });
        return error.PrivateDirUnusable;
    };
    defer dir.close();

    const st = std.posix.fstat(dir.fd) catch |err| {
        log.warn("refusing to use {s}: cannot stat it ({s})", .{ path, @errorName(err) });
        return error.PrivateDirUnusable;
    };

    if (!std.posix.S.ISDIR(st.mode)) {
        log.warn("refusing to use {s}: not a directory", .{path});
        return error.PrivateDirUnusable;
    }
    if (st.uid != linux.getuid()) {
        log.warn("refusing to use {s}: owned by uid {d}, not {d}", .{ path, st.uid, linux.getuid() });
        return error.PrivateDirUnusable;
    }
    if (st.mode & 0o022 != 0) {
        // Ours, but group/world writable. Tighten it; warn if we cannot.
        std.posix.fchmod(dir.fd, 0o700) catch {
            log.warn("{s} is group/world writable and could not be tightened", .{path});
        };
    }
}

test "ensurePrivateDir accepts a directory we own and rejects a non-directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    // Fresh path: created and accepted.
    const good = try std.fmt.allocPrint(std.testing.allocator, "{s}/nested/dir", .{base});
    defer std.testing.allocator.free(good);
    try ensurePrivateDir(good);
    // Idempotent: an existing directory we own stays acceptable.
    try ensurePrivateDir(good);

    // A regular file where a directory is expected must be REFUSED, not used.
    // The contract is "fails", not a specific error: `makePath` rejects this
    // with NotDir before the ownership check is even reached, and pinning the
    // exact error would make the test brittle against that ordering.
    const file_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/afile", .{base});
    defer std.testing.allocator.free(file_path);
    (try std.fs.createFileAbsolute(file_path, .{})).close();
    try std.testing.expect(if (ensurePrivateDir(file_path)) |_| false else |_| true);
}

/// Get the debug log file path.
///
/// Follows XDG_STATE_HOME (then `~/.local/state`), NOT a hardcoded `/tmp`
/// (PLAN.md A-6): this file records cwds, command lines and pane metadata, so
/// it belongs in the user's private state directory, not a world-writable one.
/// `/tmp` remains only as a last resort when there is no HOME at all, and even
/// then the directory must pass `ensurePrivateDir`.
pub fn getLogPath(allocator: std.mem.Allocator) ![]const u8 {
    const instance_raw = posix.getenv("HEXE_INSTANCE");
    const instance = if (instance_raw) |inst| (if (inst.len > 0) inst else "default") else "default";

    var sanitized_buf: [32]u8 = undefined;
    const sanitized = sanitizeInstanceName(sanitized_buf[0..], instance);
    const final_instance = if (sanitized.len > 0) sanitized else "default";

    const state_home_env = posix.getenv("XDG_STATE_HOME");
    const state_home: []const u8 = state_home_env orelse blk: {
        const home = posix.getenv("HOME") orelse break :blk "/tmp";
        break :blk try std.fmt.allocPrint(allocator, "{s}/.local/state", .{home});
    };
    const owned_state_home = state_home_env == null and !std.mem.eql(u8, state_home, "/tmp");
    defer if (owned_state_home) allocator.free(state_home);

    const dir = try std.fmt.allocPrint(allocator, "{s}/hexe/{s}", .{ state_home, final_instance });
    defer allocator.free(dir);
    try ensurePrivateDir(dir);

    return std.fmt.allocPrint(allocator, "{s}/hexe/{s}/log", .{ state_home, final_instance });
}

/// Get the layout storage directory path (~/.config/hexe/layouts/).
pub fn getLayoutDir(allocator: std.mem.Allocator) ![]const u8 {
    if (posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/hexe/layouts", .{xdg});
    }
    const home = posix.getenv("HOME") orelse "/tmp";
    return std.fmt.allocPrint(allocator, "{s}/.config/hexe/layouts", .{home});
}

const testing = std.testing;

test "connect() is bounded when the peer's accept backlog is full" {
    // The wedged-peer case, exactly: a listener that is alive (so the socket
    // file exists and connect does not get refused) but never calls accept().
    // Its backlog fills, and a BLOCKING connect() then parks in the kernel with
    // no timeout — forever. That is reachable from both event loops (SES dials
    // pods on its 1s tick; every pod dials SES), so it could hang the daemon and
    // every session with it. connectTimeout must give up instead.
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/hexe-ipc-test-{d}.sock", .{std.os.linux.getpid()});
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    const lfd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(lfd);
    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    try posix.bind(lfd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    try posix.listen(lfd, 1); // tiny backlog, and we never accept

    // Fill the backlog. Some of these succeed (they sit in the accept queue).
    var held: [64]posix.fd_t = undefined;
    var held_n: usize = 0;
    defer for (held[0..held_n]) |fd| posix.close(fd);

    var timed_out = false;
    var attempts: usize = 0;
    const t0 = std.time.milliTimestamp();
    while (attempts < 64) : (attempts += 1) {
        const conn = Client.connectTimeout(path, 300) catch |err| {
            // Backlog full: the kernel makes us wait, and we refuse to.
            if (err == error.ConnectionTimedOut) {
                timed_out = true;
                break;
            }
            break;
        };
        held[held_n] = conn.fd;
        held_n += 1;
    }
    const elapsed = std.time.milliTimestamp() - t0;

    try testing.expect(timed_out); // a blocking connect() would still be parked
    try testing.expect(elapsed < 5000); // and it gave up promptly
}

test "connect() to a socket nobody is listening on fails fast, not slowly" {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/hexe-ipc-none-{d}.sock", .{std.os.linux.getpid()});
    std.fs.deleteFileAbsolute(path) catch {};

    const t0 = std.time.milliTimestamp();
    const res = Client.connectTimeout(path, 2000);
    const elapsed = std.time.milliTimestamp() - t0;

    try testing.expectError(error.FileNotFound, res);
    try testing.expect(elapsed < 500); // refused immediately; no timeout burned
}
