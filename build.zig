const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const runtime_epoch = computeRuntimeEpoch(b);

    // Get ghostty-vt module from dependency
    const ghostty_vt_mod = if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |ghostty_dep| ghostty_dep.module("ghostty-vt") else null;

    // Get yazap module from dependency
    const yazap_mod = if (b.lazyDependency("yazap", .{})) |yazap_dep| yazap_dep.module("yazap") else null;

    // Get ziglua dependency for embedded Lua
    const ziglua_dep = b.lazyDependency("ziglua", .{
        .target = target,
        .optimize = optimize,
    });

    // Get libvoid dependency for sandboxing
    const libvoid_mod = if (b.lazyDependency("libvoid", .{
        .target = target,
        .optimize = optimize,
    })) |libvoid_dep| libvoid_dep.module("libvoid") else null;

    // Get libxev dependency (required event loop backend)
    const xev_mod = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    }).module("xev");

    // Get logly dependency (structured logging backend)
    const logly_mod = b.dependency("logly", .{
        .target = target,
        .optimize = optimize,
    }).module("logly");

    // Get libvaxis dependency (required TUI rendering library)
    const vaxis_mod = b.dependency("libvaxis", .{
        .target = target,
        .optimize = optimize,
    }).module("vaxis");

    // Get liblink dependency (remote transport backend)
    const liblink_mod = if (b.lazyDependency("liblink", .{
        .target = target,
        .optimize = optimize,
    })) |liblink_dep| liblink_dep.module("liblink") else null;

    // Create core module
    const core_module = b.createModule(.{
        .root_source_file = b.path("src/core/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "runtime_epoch", runtime_epoch);
    core_module.addOptions("build_options", build_options);
    if (ghostty_vt_mod) |vt| {
        core_module.addImport("ghostty-vt", vt);
    }
    if (ziglua_dep) |dep| {
        const zlua_mod = dep.module("zlua");
        core_module.addImport("zlua", zlua_mod);
    }
    if (libvoid_mod) |vb| {
        core_module.addImport("libvoid", vb);
    }
    core_module.addImport("vaxis", vaxis_mod);
    core_module.addImport("xev", xev_mod);
    if (liblink_mod) |ll| {
        core_module.addImport("liblink", ll);
    }
    core_module.addImport("logly", logly_mod);

    // Create frontend-core module (host-neutral frontend event/action boundary)
    const frontend_core_module = b.createModule(.{
        .root_source_file = b.path("src/frontends/core/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    frontend_core_module.addImport("core", core_module);

    // Create shell module (shell prompt/status bar segments)
    const shp_module = b.createModule(.{
        .root_source_file = b.path("src/modules/shell/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    shp_module.addImport("core", core_module);

    // Create popup module (popup/overlay system)
    const pop_module = b.createModule(.{
        .root_source_file = b.path("src/modules/popup/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    pop_module.addImport("core", core_module);

    // Create terminal frontend module for unified CLI
    const terminal_module = b.createModule(.{
        .root_source_file = b.path("src/frontends/terminal/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    terminal_module.addIncludePath(b.path("src/frontends/terminal"));
    terminal_module.addImport("core", core_module);
    terminal_module.addImport("frontend_core", frontend_core_module);
    terminal_module.addImport("xev", xev_mod);
    terminal_module.addImport("shp", shp_module);
    terminal_module.addImport("pop", pop_module);
    if (ghostty_vt_mod) |vt| {
        terminal_module.addImport("ghostty-vt", vt);
    }
    terminal_module.addImport("vaxis", vaxis_mod);

    // Create web/syslink frontend adapter modules for CLI entrypoints.
    const web_module = b.createModule(.{
        .root_source_file = b.path("src/frontends/web/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    web_module.addImport("core", core_module);
    web_module.addImport("frontend_core", frontend_core_module);

    const syslink_module = b.createModule(.{
        .root_source_file = b.path("src/frontends/syslink/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    syslink_module.addImport("core", core_module);
    syslink_module.addImport("frontend_core", frontend_core_module);

    // Create session module for unified CLI
    const ses_module = b.createModule(.{
        .root_source_file = b.path("src/modules/session/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ses_module.addImport("core", core_module);
    ses_module.addImport("xev", xev_mod);
    if (libvoid_mod) |vb| {
        ses_module.addImport("libvoid", vb);
    }

    // Create pod module (per-pane PTY + scrollback; launched via `hexe pod daemon`)
    const pod_module = b.createModule(.{
        .root_source_file = b.path("src/modules/pod/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    pod_module.addImport("core", core_module);
    pod_module.addImport("xev", xev_mod);
    if (libvoid_mod) |vb| {
        pod_module.addImport("libvoid", vb);
    }

    // Build unified hexe CLI executable
    const cli_root = b.createModule(.{
        .root_source_file = b.path("src/cli/app.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_root.addImport("core", core_module);
    cli_root.addImport("frontend_core", frontend_core_module);
    cli_root.addImport("terminal", terminal_module);
    cli_root.addImport("web", web_module);
    cli_root.addImport("syslink", syslink_module);
    cli_root.addImport("ses", ses_module);
    cli_root.addImport("pod", pod_module);
    cli_root.addImport("shp", shp_module);
    cli_root.addImport("xev", xev_mod);
    if (yazap_mod) |yazap| {
        cli_root.addImport("yazap", yazap);
    }
    const cli_exe = b.addExecutable(.{
        .name = "hexe",
        .root_module = cli_root,
    });
    cli_exe.addIncludePath(b.path("src/frontends/terminal"));
    cli_exe.addCSourceFile(.{
        .file = b.path("src/frontends/terminal/regex_shim.c"),
    });
    b.installArtifact(cli_exe);

    // Run hexe step
    const run_hexe = b.addRunArtifact(cli_exe);
    run_hexe.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_hexe.addArgs(args);
    }
    const run_step = b.step("run", "Run hexe");
    run_step.dependOn(&run_hexe.step);

    // Optional runtime smoke: expects a SES daemon to be running for the
    // current HEXE_INSTANCE and drives register/create/detach/reattach/adopt.
    const session_protocol_smoke_module = b.createModule(.{
        .root_source_file = b.path("src/tools/session_protocol_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session_protocol_smoke_module.addImport("core", core_module);
    const session_protocol_smoke_exe = b.addExecutable(.{
        .name = "hexe-session-protocol-smoke",
        .root_module = session_protocol_smoke_module,
    });
    const run_session_protocol_smoke = b.addRunArtifact(session_protocol_smoke_exe);
    const session_protocol_smoke_step = b.step("session-protocol-smoke", "Run SES protocol detach/reattach smoke against an already-running daemon");
    session_protocol_smoke_step.dependOn(&run_session_protocol_smoke.step);

    // Test step for session module error handling tests
    const ses_test_module = b.createModule(.{
        .root_source_file = b.path("src/modules/session/state_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ses_test_module.addImport("core", core_module);

    const ses_tests = b.addTest(.{
        .root_module = ses_test_module,
    });

    const run_ses_tests = b.addRunArtifact(ses_tests);

    const ses_server_test_module = b.createModule(.{
        .root_source_file = b.path("src/modules/session/server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ses_server_test_module.addImport("core", core_module);
    ses_server_test_module.addImport("xev", xev_mod);
    if (libvoid_mod) |vb| {
        ses_server_test_module.addImport("libvoid", vb);
    }

    const ses_server_tests = b.addTest(.{
        .root_module = ses_server_test_module,
    });
    const run_ses_server_tests = b.addRunArtifact(ses_server_tests);

    // Wire protocol round-trip tests.
    const wire_test_module = b.createModule(.{
        .root_source_file = b.path("src/core/wire_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    wire_test_module.addImport("core", core_module);

    const wire_tests = b.addTest(.{
        .root_module = wire_test_module,
    });
    const run_wire_tests = b.addRunArtifact(wire_tests);

    // Core VT behavior tests.
    const vt_test_module = b.createModule(.{
        .root_source_file = b.path("src/core/vt_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    vt_test_module.addImport("core", core_module);

    const vt_tests = b.addTest(.{
        .root_module = vt_test_module,
    });
    const run_vt_tests = b.addRunArtifact(vt_tests);

    // Terminal frontend fast-path encoding regression tests.
    const fast_path_test_module = b.createModule(.{
        .root_source_file = b.path("src/frontends/terminal/fast_path_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fast_path_test_module.addImport("core", core_module);

    const fast_path_tests = b.addTest(.{
        .root_module = fast_path_test_module,
    });
    const run_fast_path_tests = b.addRunArtifact(fast_path_tests);

    // Terminal OSC passthrough/query regression tests.
    const pane_output_test_module = b.createModule(.{
        .root_source_file = b.path("src/frontends/terminal/pane_output.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    pane_output_test_module.addIncludePath(b.path("src/frontends/terminal"));
    pane_output_test_module.addImport("core", core_module);
    pane_output_test_module.addImport("pop", pop_module);
    if (ghostty_vt_mod) |vt| {
        pane_output_test_module.addImport("ghostty-vt", vt);
    }

    const pane_output_tests = b.addTest(.{
        .root_module = pane_output_test_module,
    });
    const run_pane_output_tests = b.addRunArtifact(pane_output_tests);

    // Scrollback search (PLAN 3.3) tests.
    const pane_search_test_module = b.createModule(.{
        .root_source_file = b.path("src/frontends/terminal/pane_search.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    pane_search_test_module.addIncludePath(b.path("src/frontends/terminal"));
    pane_search_test_module.addImport("core", core_module);
    pane_search_test_module.addImport("pop", pop_module);
    if (ghostty_vt_mod) |vt| {
        pane_search_test_module.addImport("ghostty-vt", vt);
    }

    const pane_search_tests = b.addTest(.{
        .root_module = pane_search_test_module,
    });
    const run_pane_search_tests = b.addRunArtifact(pane_search_tests);

    // Frontend-core host boundary tests.
    const frontend_core_test_module = b.createModule(.{
        .root_source_file = b.path("src/frontends/core/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    frontend_core_test_module.addImport("core", core_module);

    const frontend_core_tests = b.addTest(.{
        .root_module = frontend_core_test_module,
    });
    const run_frontend_core_tests = b.addRunArtifact(frontend_core_tests);

    // Web host adapter boundary tests.
    const web_host_test_module = b.createModule(.{
        .root_source_file = b.path("src/frontends/web/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    web_host_test_module.addImport("core", core_module);
    web_host_test_module.addImport("frontend_core", frontend_core_module);

    const web_host_tests = b.addTest(.{
        .root_module = web_host_test_module,
    });
    const run_web_host_tests = b.addRunArtifact(web_host_tests);

    // Syslink host adapter boundary tests.
    const syslink_host_test_module = b.createModule(.{
        .root_source_file = b.path("src/frontends/syslink/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    syslink_host_test_module.addImport("core", core_module);
    syslink_host_test_module.addImport("frontend_core", frontend_core_module);

    const syslink_host_tests = b.addTest(.{
        .root_module = syslink_host_test_module,
    });
    const run_syslink_host_tests = b.addRunArtifact(syslink_host_tests);

    // Core library tests (Lua config parsing, api_bridge, session_config,
    // wire, config_v2, etc.). Reuse `core_module` — it already carries every
    // dependency import — as the test root; the refAllDeclsRecursive shim in
    // src/core/mod.zig collects the submodule test blocks.
    const core_tests = b.addTest(.{
        .root_module = core_module,
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    // POD output-buffering tests (ring buffer + OSC7 cwd scanner). Self-
    // contained (std only), so it roots directly at the module file.
    const pod_buffering_test_module = b.createModule(.{
        .root_source_file = b.path("src/modules/pod/buffering.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pod_buffering_tests = b.addTest(.{
        .root_module = pod_buffering_test_module,
    });
    const run_pod_buffering_tests = b.addRunArtifact(pod_buffering_tests);

    const test_step = b.step("test", "Run hexe test suites");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_pod_buffering_tests.step);
    test_step.dependOn(&run_ses_tests.step);
    test_step.dependOn(&run_ses_server_tests.step);
    test_step.dependOn(&run_wire_tests.step);
    test_step.dependOn(&run_vt_tests.step);
    test_step.dependOn(&run_fast_path_tests.step);
    test_step.dependOn(&run_pane_output_tests.step);
    test_step.dependOn(&run_pane_search_tests.step);
    test_step.dependOn(&run_frontend_core_tests.step);
    test_step.dependOn(&run_web_host_tests.step);
    test_step.dependOn(&run_syslink_host_tests.step);
}

fn computeRuntimeEpoch(b: *std.Build) []const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    hashFile(b, &hasher, "build.zig");
    hashFile(b, &hasher, "build.zig.zon");
    hashFile(b, &hasher, "Makefile");
    hashDirRecursive(b, &hasher, "src");

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest[0..16].*, .lower);
    return std.fmt.allocPrint(b.allocator, "{s}", .{&hex}) catch @panic("failed to allocate runtime epoch");
}

fn hashFile(b: *std.Build, hasher: anytype, path: []const u8) void {
    const data = std.fs.cwd().readFileAlloc(b.allocator, path, 64 * 1024 * 1024) catch return;
    defer b.allocator.free(data);
    hasher.update(path);
    hasher.update(&[_]u8{0});
    hasher.update(data);
    hasher.update(&[_]u8{0});
}

fn hashDirRecursive(b: *std.Build, hasher: anytype, root_path: []const u8) void {
    var dir = std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = dir.walk(b.allocator) catch return;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!hasRuntimeEpochExtension(entry.path)) continue;

        const path = std.fs.path.join(b.allocator, &.{ root_path, entry.path }) catch continue;
        defer b.allocator.free(path);
        hashFile(b, hasher, path);
    }
}

fn hasRuntimeEpochExtension(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig") or
        std.mem.endsWith(u8, path, ".c") or
        std.mem.endsWith(u8, path, ".h");
}
