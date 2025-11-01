const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const llvm = b.option(bool, "llvm", "Use LLVM backend") orelse true;

    const zluajit = b.dependency("zluajit", .{
        .target = target,
        .optimize = optimize,
        .llvm = llvm,
    });
    const zev = b.dependency("libzev", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("ljaio", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("zluajit", zluajit.module("zluajit"));
    mod.addImport("zev", zev.module("zev"));

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .use_llvm = llvm,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const install_mod_tests = b.addInstallArtifact(mod_tests, .{});

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&install_mod_tests.step);
}
