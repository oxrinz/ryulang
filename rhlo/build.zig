const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const llvm_module = b.addModule("llvm", .{
        .root_source_file = b.path("src/llvm/llvm.zig"),
        .target = target,
        .optimize = optimize,
    });

    llvm_module.addCMacro("_FILE_OFFSET_BITS", "64");
    llvm_module.addCMacro("__STDC_CONSTANT_MACROS", "");
    llvm_module.addCMacro("__STDC_FORMAT_MACROS", "");
    llvm_module.addCMacro("__STDC_LIMIT_MACROS", "");
    llvm_module.linkSystemLibrary("z", .{});

    if (target.result.abi != .msvc)
        llvm_module.link_libc = true
    else
        llvm_module.link_libcpp = true;

    llvm_module.linkSystemLibrary("LLVM", .{});

    const clang_module = b.addModule("clang", .{
        .root_source_file = b.path("src/llvm/clang.zig"),
        .target = target,
        .optimize = optimize,
    });
    clang_module.linkSystemLibrary("clang-18", .{});

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    main_module.addImport("llvm", b.modules.get("llvm").?);

    const lib = b.addSharedLibrary(.{
        .name = "rhlo",
        .root_module = main_module,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_module = main_module,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
