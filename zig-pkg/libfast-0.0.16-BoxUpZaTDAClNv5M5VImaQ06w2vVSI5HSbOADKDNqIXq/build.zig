const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const libsafe_dep = b.dependency("libsafe", .{
        .target = target,
        .optimize = optimize,
    });
    const libsafe_module = libsafe_dep.module("libsafe");

    // Create the libfast module
    const libfast_module = b.createModule(.{
        .root_source_file = b.path("lib/libfast.zig"),
        .target = target,
        .optimize = optimize,
    });
    libfast_module.addImport("libsafe", libsafe_module);

    // Export the module so it can be used by other projects
    const exported = b.addModule("libfast", .{
        .root_source_file = b.path("lib/libfast.zig"),
        .target = target,
        .optimize = optimize,
    });
    exported.addImport("libsafe", libsafe_module);

    // Build the library
    const lib = b.addLibrary(.{
        .name = "fast",
        .root_module = libfast_module,
        .linkage = .static,
    });

    b.installArtifact(lib);

    // Unit tests
    const lib_unit_tests = b.addTest(.{
        .root_module = libfast_module,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Dual-mode regression subset
    const dual_mode_module = b.createModule(.{
        .root_source_file = b.path("lib/dual_mode_regression_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    dual_mode_module.addImport("libfast", libfast_module);

    const dual_mode_tests = b.addTest(.{
        .root_module = dual_mode_module,
    });
    const run_dual_mode_tests = b.addRunArtifact(dual_mode_tests);

    const dual_mode_step = b.step("test-dual-mode-regression", "Run paired TLS/SSH regression tests");
    dual_mode_step.dependOn(&run_dual_mode_tests.step);

    // Examples

    // SSH echo server
    const ssh_server_module = b.createModule(.{
        .root_source_file = b.path("examples/ssh_echo_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    ssh_server_module.addImport("libfast", libfast_module);

    const ssh_server = b.addExecutable(.{
        .name = "ssh_echo_server",
        .root_module = ssh_server_module,
    });
    b.installArtifact(ssh_server);

    const run_ssh_server = b.addRunArtifact(ssh_server);
    const ssh_server_step = b.step("run-ssh-server", "Run SSH/QUIC echo server example");
    ssh_server_step.dependOn(&run_ssh_server.step);

    // SSH echo client
    const ssh_client_module = b.createModule(.{
        .root_source_file = b.path("examples/ssh_echo_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    ssh_client_module.addImport("libfast", libfast_module);

    const ssh_client = b.addExecutable(.{
        .name = "ssh_echo_client",
        .root_module = ssh_client_module,
    });
    b.installArtifact(ssh_client);

    const run_ssh_client = b.addRunArtifact(ssh_client);
    const ssh_client_step = b.step("run-ssh-client", "Run SSH/QUIC echo client example");
    ssh_client_step.dependOn(&run_ssh_client.step);

    // TLS echo server
    const tls_server_module = b.createModule(.{
        .root_source_file = b.path("examples/tls_echo_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    tls_server_module.addImport("libfast", libfast_module);

    const tls_server = b.addExecutable(.{
        .name = "tls_echo_server",
        .root_module = tls_server_module,
    });
    b.installArtifact(tls_server);

    const run_tls_server = b.addRunArtifact(tls_server);
    const tls_server_step = b.step("run-tls-server", "Run TLS/QUIC echo server example");
    tls_server_step.dependOn(&run_tls_server.step);

    // TLS echo client
    const tls_client_module = b.createModule(.{
        .root_source_file = b.path("examples/tls_echo_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    tls_client_module.addImport("libfast", libfast_module);

    const tls_client = b.addExecutable(.{
        .name = "tls_echo_client",
        .root_module = tls_client_module,
    });
    b.installArtifact(tls_client);

    const run_tls_client = b.addRunArtifact(tls_client);
    const tls_client_step = b.step("run-tls-client", "Run TLS/QUIC echo client example");
    tls_client_step.dependOn(&run_tls_client.step);
}
