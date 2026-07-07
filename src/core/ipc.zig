const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
});

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
        if (std.fs.path.isAbsolute(dir)) {
            var root = try std.fs.openDirAbsolute("/", .{});
            defer root.close();
            return root.makePath(dir[1..]);
        }
        return std.fs.cwd().makePath(dir);
    }

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Server {
        // Validate path length to avoid silent truncation
        if (path.len >= 108) return error.NameTooLong; // sockaddr_un.path max

        // Check if socket file exists and if something is listening
        if (accessSocketPath(path)) |_| {
            // Socket file exists - try to connect to see if something is listening
            const test_fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch {
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
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
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
        const client_fd = try posix.accept(self.fd, null, null, 0);
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
        const client_fd = posix.accept(self.fd, null, null, 0) catch |err| {
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
        // Validate path length to avoid silent truncation
        if (path.len >= 108) return error.NameTooLong; // sockaddr_un.path max

        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        setCloexec(fd);
        errdefer posix.close(fd);

        var addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = undefined,
        };
        @memset(&addr.path, 0);
        const path_len = @min(path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], path[0..path_len]);

        try posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

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

    /// Send data along with a file descriptor using SCM_RIGHTS
    pub fn sendWithFd(self: *Connection, data: []const u8, fd_to_send: posix.fd_t) !void {
        var iov: c.struct_iovec = .{
            .iov_base = @constCast(data.ptr),
            .iov_len = data.len,
        };

        // Control message buffer for SCM_RIGHTS - use CMSG_SPACE macro equivalent
        const cmsg_align = comptime @alignOf(c.struct_cmsghdr);
        const cmsg_hdr_size = comptime @sizeOf(c.struct_cmsghdr);
        const cmsg_data_size = comptime @sizeOf(c_int);
        const cmsg_space = comptime std.mem.alignForward(usize, cmsg_hdr_size + cmsg_data_size, cmsg_align);
        var cmsg_buf: [cmsg_space]u8 align(cmsg_align) = undefined;

        // Set up control message header
        const cmsg: *c.struct_cmsghdr = @ptrCast(&cmsg_buf);
        cmsg.cmsg_len = cmsg_hdr_size + cmsg_data_size;
        cmsg.cmsg_level = c.SOL_SOCKET;
        cmsg.cmsg_type = c.SCM_RIGHTS;

        // Copy fd into control message data area (after the header)
        const cmsg_data: *c_int = @ptrCast(@alignCast(&cmsg_buf[cmsg_hdr_size]));
        cmsg_data.* = fd_to_send;

        var msg: c.struct_msghdr = .{
            .msg_name = null,
            .msg_namelen = 0,
            .msg_iov = &iov,
            .msg_iovlen = 1,
            .msg_control = &cmsg_buf,
            .msg_controllen = cmsg_space,
            .msg_flags = 0,
        };

        const result = c.sendmsg(self.fd, &msg, 0);
        if (result < 0) {
            return error.SendFailed;
        }
        if (result == 0) return error.ConnectionClosed;
    }

    /// Receive data along with a file descriptor using SCM_RIGHTS
    pub fn recvWithFd(self: *Connection, buf: []u8) !struct { len: usize, fd: ?posix.fd_t } {
        var iov: c.struct_iovec = .{
            .iov_base = buf.ptr,
            .iov_len = buf.len,
        };

        // Control message buffer for SCM_RIGHTS - use CMSG_SPACE macro equivalent
        const cmsg_align = comptime @alignOf(c.struct_cmsghdr);
        const cmsg_hdr_size = comptime @sizeOf(c.struct_cmsghdr);
        const cmsg_data_size = comptime @sizeOf(c_int);
        const cmsg_space = comptime std.mem.alignForward(usize, cmsg_hdr_size + cmsg_data_size, cmsg_align);
        var cmsg_buf: [cmsg_space]u8 align(cmsg_align) = undefined;

        var msg: c.struct_msghdr = .{
            .msg_name = null,
            .msg_namelen = 0,
            .msg_iov = &iov,
            .msg_iovlen = 1,
            .msg_control = &cmsg_buf,
            .msg_controllen = cmsg_space,
            .msg_flags = 0,
        };

        const result = c.recvmsg(self.fd, &msg, 0);
        if (result < 0) {
            return error.RecvFailed;
        }
        const len: usize = @intCast(result);
        if (len == 0) return .{ .len = 0, .fd = null };

        // Check if we received a file descriptor
        var received_fd: ?posix.fd_t = null;
        if (msg.msg_controllen >= cmsg_hdr_size) {
            const cmsg: *c.struct_cmsghdr = @ptrCast(@alignCast(msg.msg_control));
            if (cmsg.cmsg_level == c.SOL_SOCKET and cmsg.cmsg_type == c.SCM_RIGHTS) {
                const fd_ptr: *const c_int = @ptrCast(@alignCast(&cmsg_buf[cmsg_hdr_size]));
                received_fd = fd_ptr.*;
            }
        }

        return .{ .len = len, .fd = received_fd };
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
    return strings.sanitize(out, raw, 24);
}

/// Get the socket directory path
pub fn getSocketDir(allocator: std.mem.Allocator) ![]const u8 {
    // Use XDG_RUNTIME_DIR if available, otherwise /tmp
    const runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";

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

/// Check if ses is running by trying to connect.
/// If socket file exists but connection fails, removes the stale socket.
pub fn isSesRunning(allocator: std.mem.Allocator) bool {
    const path = getSesSocketPath(allocator) catch |err| {
        log.warn("failed to build ses socket path: {}", .{err});
        return false;
    };
    defer allocator.free(path);

    // First check if socket file exists
    std.fs.cwd().access(path, .{}) catch |err| {
        if (err != error.FileNotFound) log.warn("failed to access ses socket '{s}': {}", .{ path, err });
        return false;
    };

    // Try to connect
    var client = Client.connect(path) catch |err| {
        log.warn("failed to connect to ses socket '{s}', treating as stale: {}", .{ path, err });
        // Socket file exists but can't connect = stale socket
        // Remove it so the new SES can bind
        std.fs.cwd().deleteFile(path) catch |delete_err| {
            if (delete_err != error.FileNotFound) log.warn("failed to remove stale ses socket '{s}': {}", .{ path, delete_err });
        };
        return false;
    };
    client.close();
    return true;
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

/// Get the debug log file path.
/// Returns /tmp/hexe/<instance>/log where instance defaults to "default".
pub fn getLogPath(allocator: std.mem.Allocator) ![]const u8 {
    const instance_raw = posix.getenv("HEXE_INSTANCE");
    const instance = if (instance_raw) |inst| (if (inst.len > 0) inst else "default") else "default";

    var sanitized_buf: [32]u8 = undefined;
    const sanitized = sanitizeInstanceName(sanitized_buf[0..], instance);
    const final_instance = if (sanitized.len > 0) sanitized else "default";

    const dir = try std.fmt.allocPrint(allocator, "/tmp/hexe/{s}", .{final_instance});
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);

    return std.fmt.allocPrint(allocator, "/tmp/hexe/{s}/log", .{final_instance});
}

/// Get the layout storage directory path (~/.config/hexe/layouts/).
pub fn getLayoutDir(allocator: std.mem.Allocator) ![]const u8 {
    if (posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/hexe/layouts", .{xdg});
    }
    const home = posix.getenv("HOME") orelse "/tmp";
    return std.fmt.allocPrint(allocator, "{s}/.config/hexe/layouts", .{home});
}

// ============================================================================
// Pop IPC types - for CLI popup commands
// ============================================================================

/// Pop request kind
pub const PopKind = enum {
    notify,
    confirm,
    choose,
};

/// Pop request - sent from CLI to mux via ses
pub const PopRequest = struct {
    kind: PopKind,
    target_uuid: [32]u8,
    message: []const u8,
    items: ?[]const []const u8 = null, // for choose
    duration_ms: ?i64 = null, // for notify

    /// Serialize to JSON for IPC
    pub fn toJson(self: PopRequest, allocator: std.mem.Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        const writer = buf.writer(allocator);

        try writer.writeAll("{\"type\":\"pop_request\",");
        try writer.print("\"kind\":\"{s}\",", .{@tagName(self.kind)});
        try writer.print("\"uuid\":\"{s}\",", .{self.target_uuid});
        try writer.print("\"message\":\"{s}\"", .{self.message});
        if (self.duration_ms) |dur| {
            try writer.print(",\"duration_ms\":{d}", .{dur});
        }
        if (self.items) |items| {
            try writer.writeAll(",\"items\":[");
            for (items, 0..) |item, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("\"{s}\"", .{item});
            }
            try writer.writeAll("]");
        }
        try writer.writeAll("}");

        return buf.toOwnedSlice(allocator);
    }
};

/// Pop response - sent from mux back to CLI via ses
pub const PopResponse = struct {
    success: bool = true,
    confirmed: ?bool = null, // for confirm
    selected: ?usize = null, // for choose
    error_msg: ?[]const u8 = null,

    /// Serialize to JSON for IPC
    pub fn toJson(self: PopResponse, allocator: std.mem.Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        const writer = buf.writer(allocator);

        try writer.writeAll("{\"type\":\"pop_response\",");
        try writer.print("\"success\":{}", .{self.success});
        if (self.confirmed) |conf| {
            try writer.print(",\"confirmed\":{}", .{conf});
        }
        if (self.selected) |sel| {
            try writer.print(",\"selected\":{d}", .{sel});
        }
        if (self.error_msg) |msg| {
            try writer.print(",\"error\":\"{s}\"", .{msg});
        }
        try writer.writeAll("}");

        return buf.toOwnedSlice(allocator);
    }
};
