const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libsafe_module = b.createModule(.{
        .root_source_file = b.path("src/libsafe.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exported_module = b.addModule("libsafe", .{
        .root_source_file = b.path("src/libsafe.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = exported_module;

    const lib = b.addLibrary(.{
        .name = "safe",
        .root_module = libsafe_module,
        .linkage = .static,
    });
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{
        .root_module = libsafe_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run libsafe unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
