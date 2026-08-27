const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    if (target.result.os.tag != .linux) {
        return error.InvalidOS;
    }

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const libfast_dep = b.dependency("libfast", .{
        .target = target,
        .optimize = optimize,
    });
    const libfast_module = libfast_dep.module("libfast");
    const libfast_transport_module = b.createModule(.{
        .root_source_file = libfast_dep.path("lib/transport.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const liblink_module = b.createModule(.{
        .root_source_file = b.path("lib/liblink.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    liblink_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    liblink_module.addImport("libfast", libfast_module);
    liblink_module.addImport("libfast_transport", libfast_transport_module);

    const liblink_export = b.addModule("liblink", .{
        .root_source_file = b.path("lib/liblink.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    liblink_export.addImport("libfast", libfast_module);
    liblink_export.addImport("libfast_transport", libfast_transport_module);

    const lib = b.addLibrary(.{
        .name = "liblink",
        .root_module = liblink_module,
        .linkage = .static,
    });

    b.installArtifact(lib);

    const exe_unit_tests = b.addTest(.{
        .root_module = liblink_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const ex_client_module = b.createModule(.{
        .root_source_file = b.path("examples/client_demo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ex_client_module.addImport("liblink", liblink_module);

    const ex_client = b.addExecutable(.{
        .name = "client_demo",
        .root_module = ex_client_module,
    });

    const ex_server_module = b.createModule(.{
        .root_source_file = b.path("examples/server_demo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ex_server_module.addImport("liblink", liblink_module);

    const ex_server = b.addExecutable(.{
        .name = "server_demo",
        .root_module = ex_server_module,
    });

    const sl_module = b.createModule(.{
        .root_source_file = b.path("bin/sl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sl_module.addImport("liblink", liblink_module);

    const sl_unit_tests = b.addTest(.{
        .root_module = sl_module,
    });
    const run_sl_unit_tests = b.addRunArtifact(sl_unit_tests);
    test_step.dependOn(&run_sl_unit_tests.step);

    const sl = b.addExecutable(.{
        .name = "sl",
        .root_module = sl_module,
    });
    b.installArtifact(sl);

    const sl_step = b.step("sl", "Compile sl CLI binary");
    sl_step.dependOn(&sl.step);

    const examples_step = b.step("examples", "Compile example programs");
    examples_step.dependOn(&ex_client.step);
    examples_step.dependOn(&ex_server.step);
}
