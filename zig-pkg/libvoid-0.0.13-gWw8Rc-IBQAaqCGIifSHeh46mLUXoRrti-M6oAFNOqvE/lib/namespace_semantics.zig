const config = @import("config.zig");

const IsolationOptions = config.IsolationOptions;
const NamespaceFds = config.NamespaceFds;
const SecurityOptions = config.SecurityOptions;
const JailConfig = config.JailConfig;

pub fn validate(isolation: IsolationOptions, namespace_fds: NamespaceFds, security: SecurityOptions) !void {
    if (namespace_fds.net != null and isolation.net) return error.NamespaceAttachConflict;
    if (namespace_fds.mount != null and isolation.mount) return error.NamespaceAttachConflict;
    if (namespace_fds.uts != null and isolation.uts) return error.NamespaceAttachConflict;
    if (namespace_fds.ipc != null and isolation.ipc) return error.NamespaceAttachConflict;
    if (namespace_fds.user != null and isolation.user) return error.NamespaceAttachConflict;

    if (security.assert_userns_disabled and (isolation.user or namespace_fds.user != null)) {
        return error.AssertUserNsDisabledConflict;
    }

    if (security.disable_userns and namespace_fds.user != null) {
        return error.DisableUserNsConflict;
    }
    if (security.disable_userns and namespace_fds.user2 != null) {
        return error.DisableUserNsConflict;
    }
    if (security.disable_userns and !isolation.user) {
        return error.DisableUserNsRequiresUserNs;
    }
    if (namespace_fds.user2 != null and namespace_fds.user == null) {
        return error.UserNs2RequiresUserNs;
    }
}

test "validate rejects disable_userns with attached userns" {
    const cfg: JailConfig = .{
        .name = "x",
        .rootfs_path = "/",
        .cmd = &.{"/bin/sh"},
        .isolation = .{ .user = false },
        .namespace_fds = .{ .user = 3 },
        .security = .{ .disable_userns = true },
    };

    try @import("std").testing.expectError(error.DisableUserNsConflict, validate(cfg.isolation, cfg.namespace_fds, cfg.security));
}

test "validate requires user namespace when disable_userns is set" {
    const cfg: JailConfig = .{
        .name = "x",
        .rootfs_path = "/",
        .cmd = &.{"/bin/sh"},
        .isolation = .{ .user = false },
        .security = .{ .disable_userns = true },
    };

    try @import("std").testing.expectError(error.DisableUserNsRequiresUserNs, validate(cfg.isolation, cfg.namespace_fds, cfg.security));
}

test "validate allows pidns attach without unshare pid" {
    const cfg: JailConfig = .{
        .name = "x",
        .rootfs_path = "/",
        .cmd = &.{"/bin/sh"},
        .isolation = .{ .pid = false },
        .namespace_fds = .{ .pid = 3 },
    };

    try validate(cfg.isolation, cfg.namespace_fds, cfg.security);
}

test "validate allows pidns attach with unshare pid" {
    const cfg: JailConfig = .{
        .name = "x",
        .rootfs_path = "/",
        .cmd = &.{"/bin/sh"},
        .isolation = .{ .pid = true },
        .namespace_fds = .{ .pid = 3 },
    };

    try validate(cfg.isolation, cfg.namespace_fds, cfg.security);
}

test "validate requires userns when userns2 is set" {
    const cfg: JailConfig = .{
        .name = "x",
        .rootfs_path = "/",
        .cmd = &.{"/bin/sh"},
        .namespace_fds = .{ .user2 = 9 },
    };

    try @import("std").testing.expectError(error.UserNs2RequiresUserNs, validate(cfg.isolation, cfg.namespace_fds, cfg.security));
}

test "validate allows userns2 when userns is set" {
    const cfg: JailConfig = .{
        .name = "x",
        .rootfs_path = "/",
        .cmd = &.{"/bin/sh"},
        .isolation = .{ .user = false },
        .namespace_fds = .{ .user = 3, .user2 = 9 },
    };

    try validate(cfg.isolation, cfg.namespace_fds, cfg.security);
}
