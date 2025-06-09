const std = @import("std");

const ast = @import("../frontend/ast.zig");
const rir = @import("rir.zig");

const rhlo = @import("rhlo");
const rllvm = @import("rllvm");
const target = rllvm.llvm.target;
const target_machine_mod = rllvm.llvm.target_machine;
const types = rllvm.llvm.types;
const core = rllvm.llvm.core;
const execution = rllvm.llvm.engine;

pub const Generator = struct {
    allocator: std.mem.Allocator,
    module: ast.Module,

    pub fn init(module: ast.Module, allocator: std.mem.Allocator) Generator {
        _ = target.LLVMInitializeNativeTarget();
        _ = target.LLVMInitializeNativeAsmPrinter();
        _ = target.LLVMInitializeNativeAsmParser();

        const gen = Generator{
            .allocator = allocator,
            .module = module,
        };

        return gen;
    }

    pub fn generate(self: *Generator) anyerror!void {
        for (self.module.block.items) |stmt| {
            try self.generateStatement(stmt);
        }

        return;
    }

    fn generateStatement(self: *Generator, statement: ast.Statement) anyerror!void {
        switch (statement) {
            .expr => |expr| {
                _ = expr;
                unreachable;
            },
            .assign => |assign| {
                const res = try self.generateExpression(assign.value);
                _ = res;
                unreachable;
            },
            .function_definition => |function_definition| {
                _ = function_definition;
                unreachable;
            },
            .compound => |compound| {
                _ = compound;
            },
        }
    }

    // TODO: would be nice to split functions that have known return value and unknown into separate scripts
    fn generateExpression(self: *Generator, expr: ast.Expression) !*rir.RIROP {
        switch (expr) {
            .binary => |binary| {
                _ = binary;
                unreachable;
            },
            .constant => |constant| {
                _ = constant;
                unreachable;
            },
            .call => |call| {
                if (std.mem.eql(u8, call.identifier, "rand") == true) {
                    const shape = try self.generateExpression(call.args[0].*);
                    const result = try self.allocator.create(rir.RIROP);
                    result.* = .{ .random = .{
                        .shape = shape,
                    } };
                    return result;
                } else unreachable;
            },
            .variable => |variable| {
                _ = variable;
                unreachable;
            },
        }
    }
};
