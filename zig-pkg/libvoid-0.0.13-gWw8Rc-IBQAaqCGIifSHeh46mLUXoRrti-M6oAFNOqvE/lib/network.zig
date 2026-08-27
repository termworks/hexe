const std = @import("std");
const log = std.log;
const linux = std.os.linux;
const utils = @import("utils.zig");
const ip = @import("ip.zig");

const NetLink = @import("rtnetlink/rtnetlink.zig");
const MAX_IFNAME_LEN = 32;

var default_ifname_mutex: std.Thread.Mutex = .{};
var default_ifname_cache: [MAX_IFNAME_LEN]u8 = [_]u8{0} ** MAX_IFNAME_LEN;
var default_ifname_cache_len: usize = 0;

var nat_state_mutex: std.Thread.Mutex = .{};
var nat_ifname_cache: [MAX_IFNAME_LEN]u8 = [_]u8{0} ** MAX_IFNAME_LEN;
var nat_ifname_cache_len: usize = 0;
var nat_configured: bool = false;

cid: []const u8,
nl: NetLink,
allocator: std.mem.Allocator,
const Net = @This();

pub fn init(allocator: std.mem.Allocator, cid: []const u8) !Net {
    return .{
        .cid = cid,
        .nl = try NetLink.init(allocator),
        .allocator = allocator,
    };
}

pub fn setUpBridge(self: *Net) !void {
    if (self.linkExists(utils.BRIDGE_NAME)) return;
    try self.nl.linkAdd(.{ .bridge = utils.BRIDGE_NAME });

    var bridge = try self.nl.linkGet(.{ .name = utils.BRIDGE_NAME });
    defer bridge.deinit();
    try self.nl.linkSet(.{ .index = bridge.msg.header.index, .up = true });
    try self.nl.addrAdd(.{ .index = bridge.msg.header.index, .addr = .{ 10, 0, 0, 1 }, .prefix_len = 24 }); //
}

/// enables snat on default interface
/// this allows containers to access the internet
pub fn enableNat(self: *Net) !void {
    const default_ifname = try self.getDefaultGatewayIfNameCached();

    nat_state_mutex.lock();
    defer nat_state_mutex.unlock();

    if (!natNeedsReconfigure(nat_configured, nat_ifname_cache[0..nat_ifname_cache_len], default_ifname)) {
        return;
    }

    try self.if_enable_snat(default_ifname);
    @memcpy(nat_ifname_cache[0..default_ifname.len], default_ifname);
    nat_ifname_cache_len = default_ifname.len;
    nat_configured = true;
}

fn natNeedsReconfigure(is_configured: bool, configured_ifname: []const u8, target_ifname: []const u8) bool {
    if (!is_configured) return true;
    if (configured_ifname.len != target_ifname.len) return true;
    return !std.mem.eql(u8, configured_ifname, target_ifname);
}

fn getDefaultGatewayIfNameCached(self: *Net) ![]const u8 {
    default_ifname_mutex.lock();
    defer default_ifname_mutex.unlock();

    if (default_ifname_cache_len != 0) {
        const cached = default_ifname_cache[0..default_ifname_cache_len];
        if (self.linkExists(cached)) {
            return cached;
        }
        log.warn("cached default interface {s} no longer exists; refreshing route lookup", .{cached});
        default_ifname_cache_len = 0;
    }

    const default_ifname = try self.getDefaultGatewayIfName();
    defer self.allocator.free(default_ifname);
    if (default_ifname.len > MAX_IFNAME_LEN) return error.InterfaceNameTooLong;
    @memcpy(default_ifname_cache[0..default_ifname.len], default_ifname);
    default_ifname_cache_len = default_ifname.len;
    return default_ifname_cache[0..default_ifname_cache_len];
}

fn getDefaultGatewayIfName(self: *Net) ![]const u8 {
    const res = try self.nl.routeGet();
    defer {
        for (res) |*msg| {
            msg.deinit();
        }
        self.allocator.free(res);
    }

    var if_index: ?u32 = null;
    for (res) |*msg| {
        var msg_has_gateway = false;
        var msg_if_index: ?u32 = null;
        for (msg.msg.attrs.items) |attr| {
            switch (attr) {
                .gateway => msg_has_gateway = true,
                .output_if => |val| msg_if_index = val,
                else => {},
            }
        }
        if (msg_has_gateway and msg_if_index != null) {
            if_index = msg_if_index;
            break;
        }
    }
    const idx = if_index orelse return error.NotFound;
    var if_info = try self.nl.linkGet(.{ .index = idx });
    defer if_info.deinit();
    var name: ?[]const u8 = null;
    for (if_info.msg.attrs.items) |attr| {
        switch (attr) {
            .name => |val| {
                name = val;
                break;
            },
            .name_owned => |val| {
                name = val;
                break;
            },
            else => {},
        }
    }

    const resolved_name = name orelse return error.NotFound;
    return try self.allocator.dupe(u8, resolved_name);
}

fn if_enable_snat(self: *Net, if_name: []const u8) !void {
    var check_rule = std.process.Child.init(&.{ "iptables", "-t", "nat", "-C", "POSTROUTING", "-o", if_name, "-j", "MASQUERADE" }, self.allocator);
    check_rule.stdout_behavior = .Ignore;
    check_rule.stderr_behavior = .Ignore;
    const check_rule_res = try check_rule.spawnAndWait();
    if (termExitedZero(check_rule_res)) return;

    // add rule if it doesn't exist
    var ch = std.process.Child.init(&.{ "iptables", "-t", "nat", "-A", "POSTROUTING", "-o", if_name, "-j", "MASQUERADE" }, self.allocator);
    ch.stdout_behavior = .Ignore;
    ch.stderr_behavior = .Ignore;
    const term = try ch.spawnAndWait();
    if (!termExitedZero(term)) {
        return error.CmdFailed;
    }
}

fn termExitedZero(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn countOpenFds() !usize {
    var dir = try std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    var count: usize = 0;
    while (try iter.next()) |_| {
        count += 1;
    }
    return count;
}

pub fn createVethPair(self: *Net) !void {
    const veth0 = try std.mem.concat(self.allocator, u8, &.{ "veth0-", self.cid });
    const veth1 = try std.mem.concat(self.allocator, u8, &.{ "veth1-", self.cid });
    defer {
        self.allocator.free(veth0);
        self.allocator.free(veth1);
    }

    if (self.linkExists(veth0)) return;
    log.info("creating veth pair: {s} -- {s}", .{ veth0, veth1 });

    try self.nl.linkAdd(.{ .veth = .{ veth0, veth1 } });

    var veth0_info = try self.nl.linkGet(.{ .name = veth0 });
    defer veth0_info.deinit();

    // attach veth0 to host bridge
    var bridge = try self.nl.linkGet(.{ .name = utils.BRIDGE_NAME });
    defer bridge.deinit();
    try self.nl.linkSet(.{ .index = veth0_info.msg.header.index, .master = bridge.msg.header.index, .up = true });

    var veth1_info = try self.nl.linkGet(.{ .name = veth1 });
    defer veth1_info.deinit();
}

// move veth1-xxx net interface to the pid's network namespace
pub fn moveVethToNs(self: *Net, pid: linux.pid_t) !void {
    const pid_netns_path = try std.fmt.allocPrint(self.allocator, "/proc/{}/ns/net", .{pid});
    defer self.allocator.free(pid_netns_path);
    const pid_netns = try std.fs.openFileAbsolute(pid_netns_path, .{});
    defer pid_netns.close();

    const veth_name = try std.fmt.allocPrint(self.allocator, "veth1-{s}", .{self.cid});
    defer self.allocator.free(veth_name);
    var veth_info = try self.nl.linkGet(.{ .name = veth_name });
    defer veth_info.deinit();
    try self.nl.linkSet(.{ .index = veth_info.msg.header.index, .netns_fd = pid_netns.handle });
}

// this must be executed in the child process
// after creating a new network namespace using clone.
pub fn setupContainerVethIf(self: *Net) !void {
    const veth_name = try std.fmt.allocPrint(self.allocator, "veth1-{s}", .{self.cid});
    defer self.allocator.free(veth_name);

    // need to create new netlink connection because
    // the existing one is tied to the parent namespace
    var nl = try NetLink.init(self.allocator);
    defer nl.deinit();
    var veth1_info = try nl.linkGet(.{ .name = veth_name });
    defer veth1_info.deinit();

    try nl.linkSet(.{ .index = veth1_info.msg.header.index, .up = true });
    var assigned = false;
    var attempt: usize = 0;
    while (attempt < 253) : (attempt += 1) {
        const container_addr = ip.getContainerIpv4AddrAttempt(self.cid, attempt);
        const add_res = nl.addrAdd(.{ .index = veth1_info.msg.header.index, .addr = container_addr, .prefix_len = 24 });
        if (add_res) {
            assigned = true;
            break;
        } else |err| {
            if (err == error.Exists) {
                if (attempt == 0) {
                    log.warn("ipv4 collision for {s} at {d}; probing next host addresses", .{ self.cid, container_addr[3] });
                }
                continue;
            }
            return err;
        }
    }
    if (!assigned) return error.AddressPoolExhausted;
    try nl.routeAdd(.{ .gateway = .{ 10, 0, 0, 1 } });

    // setup container loopback interface
    var lo = try nl.linkGet(.{ .name = "lo" });
    defer lo.deinit();

    nl.addrAdd(.{ .index = lo.msg.header.index, .addr = .{ 127, 0, 0, 1 }, .prefix_len = 8 }) catch |e| {
        if (e != error.Exists) return e;
    };
    try nl.linkSet(.{ .index = lo.msg.header.index, .up = true });
}

fn linkExists(self: *Net, name: []const u8) bool {
    var info = self.nl.linkGet(.{ .name = name }) catch return false;
    defer info.deinit();
    return true;
}

pub fn setupDnsResolverConfig(_: *Net, rootfs: []const u8) !void {
    var rootfs_dir = try std.fs.cwd().openDir(rootfs, .{});
    var etc_dir = try std.fs.cwd().openDir("/etc", .{});
    defer rootfs_dir.close();
    defer etc_dir.close();

    try etc_dir.copyFile("resolv.conf", rootfs_dir, "etc/resolv.conf", .{});
}

pub fn deinit(self: *Net) !void {
    var first_err: ?anyerror = null;

    // delete created veth pairs
    // deleting one will automatically remove the other
    const veth0_name = try std.mem.concat(self.allocator, u8, &.{ "veth0-", self.cid });
    defer self.allocator.free(veth0_name);
    if (self.nl.linkGet(.{ .name = veth0_name })) |veth0| {
        var owned_veth0 = veth0;
        defer owned_veth0.deinit();
        self.nl.linkDel(owned_veth0.msg.header.index) catch |err| {
            if (shouldRecordTeardownError(err)) {
                first_err = first_err orelse err;
            }
        };
    } else |err| {
        if (shouldRecordTeardownError(err)) {
            first_err = first_err orelse err;
        }
    }

    self.nl.deinit();

    if (first_err) |err| return err;
}

fn shouldRecordTeardownError(err: anyerror) bool {
    return err != error.NotFound;
}

test "natNeedsReconfigure returns true when not configured" {
    try std.testing.expect(natNeedsReconfigure(false, "eth0", "eth0"));
}

test "natNeedsReconfigure returns false for same ifname" {
    try std.testing.expect(!natNeedsReconfigure(true, "eth0", "eth0"));
}

test "natNeedsReconfigure returns true for changed ifname" {
    try std.testing.expect(natNeedsReconfigure(true, "eth0", "wlan0"));
}

test "termExitedZero only treats exited(0) as success" {
    try std.testing.expect(termExitedZero(.{ .Exited = 0 }));
    try std.testing.expect(!termExitedZero(.{ .Exited = 1 }));
    try std.testing.expect(!termExitedZero(.{ .Signal = 9 }));
}

test "shouldRecordTeardownError ignores not-found" {
    try std.testing.expect(!shouldRecordTeardownError(error.NotFound));
    try std.testing.expect(shouldRecordTeardownError(error.PermissionDenied));
}

test "repeated Net init/deinit keeps fd count stable" {
    const before = try countOpenFds();

    var i: usize = 0;
    while (i < 48) : (i += 1) {
        var cid_buf: [32]u8 = undefined;
        const cid = try std.fmt.bufPrint(&cid_buf, "fd-stability-{d}", .{i});

        var net = try Net.init(std.testing.allocator, cid);
        net.deinit() catch {};
    }

    const after = try countOpenFds();
    try std.testing.expectEqual(before, after);
}
