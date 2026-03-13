const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    terminal_module.addImport("xev", xev_mod);
    terminal_module.addImport("shp", shp_module);
    terminal_module.addImport("pop", pop_module);
    if (ghostty_vt_mod) |vt| {
        terminal_module.addImport("ghostty-vt", vt);
    }
    terminal_module.addImport("vaxis", vaxis_mod);

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
    cli_root.addImport("terminal", terminal_module);
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
    const test_step = b.step("test", "Run SES error handling tests");
    test_step.dependOn(&run_ses_tests.step);
}
