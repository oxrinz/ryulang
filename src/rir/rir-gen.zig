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

    pub fn generate(self: *Generator) anyerror!rir.RIROP {
        for (self.module.block.items) |stmt| {
            const res = try self.generateStatement(stmt);
            return res.*;
        }
        unreachable;
    }

    fn generateStatement(self: *Generator, statement: ast.Statement) anyerror!*rir.RIROP {
        switch (statement) {
            .expr => |expr| {
                return try self.generateExpression(expr);
            },
            .assign => |assign| {
                _ = assign;
                unreachable;
            },
            .function_definition => |function_definition| {
                _ = function_definition;
                unreachable;
            },
            .compound => |compound| {
                _ = compound;
                unreachable;
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
