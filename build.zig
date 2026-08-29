const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info and symbols from the installed hexe binary") orelse false;
    const runtime_epoch = computeRuntimeEpoch(b);
    const version = manifestVersion(b);

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
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "runtime_epoch", runtime_epoch);
    build_options.addOption([]const u8, "version", version);
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
    // The frontend binds its own Lua accessors (src/frontends/terminal/lua_api.zig),
    // which needs the Lua C API directly rather than through core.
    if (ziglua_dep) |dep| {
        terminal_module.addImport("zlua", dep.module("zlua"));
    }

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
    if (strip) {
        // Zig's per-module strip flag would leave dependency debug info in
        // the link, and `zig objcopy --strip-*` is unimplemented in 0.15, so
        // run the system `strip` on the finished binary (~78MB -> ~22MB).
        // Fine for native builds (`make build`, CI); build without -Dstrip if
        // no `strip` is available for the target.
        const strip_cmd = b.addSystemCommand(&.{ "strip", "-o" });
        const stripped_bin = strip_cmd.addOutputFileArg("hexe");
        strip_cmd.addFileArg(cli_exe.getEmittedBin());
        const install_stripped = b.addInstallBinFile(stripped_bin, "hexe");
        b.getInstallStep().dependOn(&install_stripped.step);
    } else {
        b.installArtifact(cli_exe);
    }

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

    // Non-blocking (async) command cache used by the render path.
    const async_cmd_test_module = b.createModule(.{
        .root_source_file = b.path("src/core/async_cmd.zig"),
        .target = target,
        .optimize = optimize,
    });
    const async_cmd_tests = b.addTest(.{
        .root_module = async_cmd_test_module,
    });
    const run_async_cmd_tests = b.addRunArtifact(async_cmd_tests);

    // Unix-socket transport: connect() must be bounded, never park forever.
    const ipc_test_module = b.createModule(.{
        .root_source_file = b.path("src/core/ipc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ipc_tests = b.addTest(.{
        .root_module = ipc_test_module,
    });
    const run_ipc_tests = b.addRunArtifact(ipc_tests);

    // Frontend mux-VT write queue: reconnect must not drop complete keystrokes.
    const vtwq_test_module = b.createModule(.{
        .root_source_file = b.path("src/frontends/terminal/vt_write_queue.zig"),
        .target = target,
        .optimize = optimize,
    });
    vtwq_test_module.addImport("core", core_module);
    const vtwq_tests = b.addTest(.{
        .root_module = vtwq_test_module,
    });
    const run_vtwq_tests = b.addRunArtifact(vtwq_tests);

    // Core VT behavior tests.
    const vt_test_module = b.createModule(.{
        .root_source_file = b.path("src/core/vt_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    vt_test_module.addImport("core", core_module);

    // Encoding an image file as a Kitty placement, which is how hexe's own
    // surfaces (drawings, status zones, sprites) show a picture.
    const image_encode_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/image_encode.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_image_encode_tests = b.addRunArtifact(image_encode_tests);

    // The sixel decoder: bytes in, RGBA out, no terminal involved.
    const sixel_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/sixel.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_sixel_tests = b.addRunArtifact(sixel_tests);

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
    if (ghostty_vt_mod) |vt| {
        fast_path_test_module.addImport("ghostty-vt", vt);
    }

    const fast_path_tests = b.addTest(.{
        .root_module = fast_path_test_module,
    });
    const run_fast_path_tests = b.addRunArtifact(fast_path_tests);

    // Terminal frontend key-decoding regression tests.
    const input_test_module = b.createModule(.{
        .root_source_file = b.path("src/frontends/terminal/input_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_test_module.addImport("core", core_module);
    input_test_module.addImport("vaxis", vaxis_mod);
    input_test_module.addImport("pop", pop_module);
    if (ghostty_vt_mod) |vt| {
        input_test_module.addImport("ghostty-vt", vt);
    }

    const input_tests = b.addTest(.{
        .root_module = input_test_module,
    });
    const run_input_tests = b.addRunArtifact(input_tests);

    const mouse_protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frontends/terminal/mouse_protocol.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_mouse_protocol_tests = b.addRunArtifact(mouse_protocol_tests);

    // Half-block image fallback: sampling and transparency, which is what
    // decides whether an image is legible on a terminal with no graphics.
    const image_fallback_test_module = b.createModule(.{
        .root_source_file = b.path("src/frontends/terminal/image_fallback.zig"),
        .target = target,
        .optimize = optimize,
    });
    image_fallback_test_module.addImport("core", core_module);
    image_fallback_test_module.addImport("vaxis", vaxis_mod);
    if (ghostty_vt_mod) |vt| {
        image_fallback_test_module.addImport("ghostty-vt", vt);
    }
    const image_fallback_tests = b.addTest(.{
        .root_module = image_fallback_test_module,
    });
    const run_image_fallback_tests = b.addRunArtifact(image_fallback_tests);

    // Image occlusion geometry: what a float leaves of an image, and which
    // part of the picture belongs in the strip that survives.
    const vt_bridge_test_module = b.createModule(.{
        .root_source_file = b.path("src/frontends/terminal/vt_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    vt_bridge_test_module.addImport("core", core_module);
    vt_bridge_test_module.addImport("vaxis", vaxis_mod);
    if (ghostty_vt_mod) |vt| {
        vt_bridge_test_module.addImport("ghostty-vt", vt);
    }
    const vt_bridge_tests = b.addTest(.{
        .root_module = vt_bridge_test_module,
    });
    const run_vt_bridge_tests = b.addRunArtifact(vt_bridge_tests);

    const pane_osc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frontends/terminal/pane_osc.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_pane_osc_tests = b.addRunArtifact(pane_osc_tests);

    // Lua event dispatch. These tests existed but were in no test target, so
    // they never ran — and they cover exactly the two bugs that shipped: a
    // stack underflow after a handler call, and a dropped second handler.
    const lua_events_test_module = b.createModule(.{
        .root_source_file = b.path("src/frontends/terminal/lua_events.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lua_events_test_module.addImport("core", core_module);
    lua_events_test_module.addImport("vaxis", vaxis_mod);
    if (ziglua_dep) |dep| {
        lua_events_test_module.addImport("zlua", dep.module("zlua"));
    }
    const lua_events_tests = b.addTest(.{ .root_module = lua_events_test_module });
    const run_lua_events_tests = b.addRunArtifact(lua_events_tests);

    // Lua<->JSON conversion for the control socket. The live API's shape is
    // decided by Lua, so the encoder's edge cases (records that also carry
    // [1], empty tables, cycles) are what decide whether a client sees the
    // truth or a plausible-looking lie.
    const api_json_test_module = b.createModule(.{
        .root_source_file = b.path("src/frontends/terminal/api_json.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    api_json_test_module.addImport("core", core_module);
    if (ziglua_dep) |dep| {
        api_json_test_module.addImport("zlua", dep.module("zlua"));
    }
    const api_json_tests = b.addTest(.{ .root_module = api_json_test_module });
    const run_api_json_tests = b.addRunArtifact(api_json_tests);

    // Float position arithmetic: a percent<->cell round trip that silently
    // made float.nudge("right") a no-op, and a u16 multiply that overflowed
    // above 655 columns.
    const float_geometry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frontends/terminal/float_geometry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_float_geometry_tests = b.addRunArtifact(float_geometry_tests);

    // A keypad key has three wire forms; two of them never reached a pane.
    const palette_cli_test_module = b.createModule(.{
        .root_source_file = b.path("src/cli/commands/palette.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    palette_cli_test_module.addImport("core", core_module);
    const palette_cli_tests = b.addTest(.{ .root_module = palette_cli_test_module });
    const run_palette_cli_tests = b.addRunArtifact(palette_cli_tests);

    const statusbar_layout_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frontends/terminal/statusbar_layout.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_statusbar_layout_tests = b.addRunArtifact(statusbar_layout_tests);

    const keypad_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frontends/terminal/keypad.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_keypad_tests = b.addRunArtifact(keypad_tests);

    const prompt_navigation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frontends/terminal/prompt_navigation.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    prompt_navigation_tests.root_module.addImport("core", core_module);
    if (ghostty_vt_mod) |vt| {
        prompt_navigation_tests.root_module.addImport("ghostty-vt", vt);
    }
    const run_prompt_navigation_tests = b.addRunArtifact(prompt_navigation_tests);

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

    // Reattach reconciliation (PLAN 1.8) tests.
    const reattach_reconcile_test_module = b.createModule(.{
        .root_source_file = b.path("src/frontends/terminal/reattach_reconcile.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    reattach_reconcile_test_module.addIncludePath(b.path("src/frontends/terminal"));
    reattach_reconcile_test_module.addImport("core", core_module);
    reattach_reconcile_test_module.addImport("pop", pop_module);
    if (ghostty_vt_mod) |vt| {
        reattach_reconcile_test_module.addImport("ghostty-vt", vt);
    }

    const reattach_reconcile_tests = b.addTest(.{
        .root_module = reattach_reconcile_test_module,
    });
    const run_reattach_reconcile_tests = b.addRunArtifact(reattach_reconcile_tests);

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

    // Exactly-once input dedup (std-only, roots directly at the module file).
    const pod_input_dedup_test_module = b.createModule(.{
        .root_source_file = b.path("src/modules/pod/input_dedup.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pod_input_dedup_tests = b.addTest(.{
        .root_module = pod_input_dedup_test_module,
    });
    const run_pod_input_dedup_tests = b.addRunArtifact(pod_input_dedup_tests);

    const test_step = b.step("test", "Run hexe test suites");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_pod_buffering_tests.step);
    test_step.dependOn(&run_pod_input_dedup_tests.step);
    test_step.dependOn(&run_ses_tests.step);
    test_step.dependOn(&run_ses_server_tests.step);
    test_step.dependOn(&run_wire_tests.step);
    test_step.dependOn(&run_async_cmd_tests.step);
    test_step.dependOn(&run_ipc_tests.step);
    test_step.dependOn(&run_vtwq_tests.step);
    test_step.dependOn(&run_vt_tests.step);
    test_step.dependOn(&run_fast_path_tests.step);
    test_step.dependOn(&run_input_tests.step);
    test_step.dependOn(&run_mouse_protocol_tests.step);
    test_step.dependOn(&run_image_fallback_tests.step);
    test_step.dependOn(&run_vt_bridge_tests.step);
    test_step.dependOn(&run_image_encode_tests.step);
    test_step.dependOn(&run_sixel_tests.step);
    test_step.dependOn(&run_pane_osc_tests.step);
    test_step.dependOn(&run_lua_events_tests.step);
    test_step.dependOn(&run_api_json_tests.step);
    test_step.dependOn(&run_float_geometry_tests.step);
    test_step.dependOn(&run_keypad_tests.step);
    test_step.dependOn(&run_statusbar_layout_tests.step);
    test_step.dependOn(&run_palette_cli_tests.step);
    test_step.dependOn(&run_prompt_navigation_tests.step);
    test_step.dependOn(&run_pane_output_tests.step);
    test_step.dependOn(&run_pane_search_tests.step);
    test_step.dependOn(&run_reattach_reconcile_tests.step);
    test_step.dependOn(&run_frontend_core_tests.step);
    test_step.dependOn(&run_web_host_tests.step);
    test_step.dependOn(&run_syslink_host_tests.step);
}

fn manifestVersion(b: *std.Build) []const u8 {
    const source = std.fs.cwd().readFileAllocOptions(
        b.allocator,
        "build.zig.zon",
        1024 * 1024,
        null,
        .of(u8),
        0,
    ) catch @panic("failed to read build.zig.zon");
    defer b.allocator.free(source);

    const Manifest = struct { version: []const u8 };
    const manifest = std.zon.parse.fromSlice(
        Manifest,
        b.allocator,
        source,
        null,
        .{ .ignore_unknown_fields = true },
    ) catch @panic("failed to parse build.zig.zon version");
    _ = std.SemanticVersion.parse(manifest.version) catch @panic("invalid build.zig.zon version");
    return manifest.version;
}

/// The files that decide whether two hexe processes can talk to each other:
/// message ids and structs, framing and handshake, the payloads that cross the
/// socket, and the snapshot shape a frontend parses.
///
/// Deliberately not "all of src". The epoch used to hash the whole tree, so a
/// comment in a rendering file made a running daemon unreachable to the very
/// next build -- which is every build, for anyone working on hexe. Real
/// incompatibility is what PROTOCOL_VERSION/MIN_PROTOCOL_VERSION are for; this
/// catches the narrower case of a daemon whose wire types differ.
const PROTOCOL_SOURCES = [_][]const u8{
    "src/core/wire.zig",
    "src/core/ipc.zig",
    "src/frontends/core/ctl_payloads.zig",
    "src/frontends/core/ctl_events.zig",
    "src/frontends/core/ses_events.zig",
    "src/frontends/core/host_protocol.zig",
    "src/frontends/core/view_model.zig",
};

fn computeRuntimeEpoch(b: *std.Build) []const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    for (PROTOCOL_SOURCES) |path| {
        // Loudly, not silently: `hashFile` ignores a file it cannot read, so a
        // renamed or mistyped path here would quietly stop contributing and
        // weaken the check with nothing to show for it.
        const data = std.fs.cwd().readFileAlloc(b.allocator, path, 64 * 1024 * 1024) catch
            std.debug.panic("runtime epoch: cannot read protocol source '{s}'", .{path});
        defer b.allocator.free(data);
        hasher.update(path);
        hasher.update(&[_]u8{0});
        hasher.update(data);
        hasher.update(&[_]u8{0});
    }

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
