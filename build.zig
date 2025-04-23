const std = @import("std");
const llvm = @import("wrappers/llvm.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = llvm.setupLLVMInBuild(b, target, optimize);
    const rhlo_module = b.createModule(.{
        .root_source_file = b.path("rhlo/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    main_module.addImport("llvm", b.modules.get("llvm").?);
    main_module.addImport("rhlo", rhlo_module);

    const exe = b.addExecutable(.{
        .name = "ryulang",
        .root_module = main_module,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = main_module,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
