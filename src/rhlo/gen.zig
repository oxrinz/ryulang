const std = @import("std");
const ast = @import("../ast.zig");
const rhlo = @import("rhlo.zig");

const llvm = @import("llvm");
const target = llvm.target;
const target_machine_mod = llvm.target_machine;
const types = llvm.types;
const core = llvm.core;
const execution = llvm.engine;

const Generator = struct {
    allocator: std.mem.Allocator,
    llvm_module: types.LLVMModuleRef,
    ptx: []const u8,

    pub fn init(allocator: std.mem.Allocator) Generator {
        return .{
            .allocator = allocator,
            .llvm_module = core.LLVMModuleCreateWithName("main_module"),
        };
    }

    pub fn generate(self: *Generator, root_node: rhlo.Node) anyerror!struct { llvm_module: types.LLVMModuleRef, ptx: []const u8 } {
        switch (root_node) {
            .Constant => {},
        }

        return .{
            .llvm_module = self.llvm_module,
            .ptx = self.ptx,
        };
    }

    fn generateNode(self: *Generator, node: rhlo.Node) void {}
};
