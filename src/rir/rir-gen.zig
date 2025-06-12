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
    variables: std.StringArrayHashMap(*rir.RIROP),

    pub fn init(module: ast.Module, allocator: std.mem.Allocator) Generator {
        _ = target.LLVMInitializeNativeTarget();
        _ = target.LLVMInitializeNativeAsmPrinter();
        _ = target.LLVMInitializeNativeAsmParser();

        const gen = Generator{
            .allocator = allocator,
            .module = module,
            .variables = std.StringArrayHashMap(*rir.RIROP).init(allocator),
        };

        return gen;
    }

    pub fn generate(self: *Generator) anyerror!rir.RIROP {
        var res: *rir.RIROP = undefined;
        for (self.module.block.items) |stmt| {
            res = try self.generateStatement(stmt);
        }
        return res.*;
    }

    fn generateStatement(self: *Generator, statement: ast.Statement) anyerror!*rir.RIROP {
        switch (statement) {
            .expr => |expr| {
                return try self.generateExpression(expr);
            },
            .assign => |assign| {
                const value = try self.generateExpression(assign.value);
                try self.variables.put(assign.target, value);
                return value;
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

    fn generateExpression(self: *Generator, expr: ast.Expression) !*rir.RIROP {
        const result = try self.allocator.create(rir.RIROP);
        switch (expr) {
            .binary => |binary| {
                switch (binary.operator) {
                    .Add => {
                        const a = try self.generateExpression(binary.left.*);
                        const b = try self.generateExpression(binary.right.*);
                        result.* = .{ .add = .{
                            .a = a,
                            .b = b,
                        } };
                    },
                    else => unreachable,
                }
            },
            .constant => |constant| {
                std.debug.print("fuck: {any}\n", .{constant.shape});
                result.* = .{ .constant = constant };
            },

            .call => |call| {
                _ = call;
                unreachable;
            },
            .builtin_call => |builtin_call| {
                if (std.mem.eql(u8, builtin_call.identifier, "rand") == true) {
                    const shape = try self.generateExpression(builtin_call.args[0].*);
                    result.* = .{ .rand = .{
                        .dtype = .F32,
                        .shape = shape,
                    } };
                } else unreachable;
            },
            .variable => |variable| {
                return self.variables.get(variable.identifier).?;
            },
        }
        return result;
    }
};
