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

    fn collectUsedVariables(self: *Generator, expr: ast.Expression, used: *std.StringHashMap(void)) !void {
        switch (expr) {
            .variable => |variable| {
                try used.put(variable.identifier, {});
            },
            .binary => |bin| {
                try self.collectUsedVariables(bin.left.*, used);
                try self.collectUsedVariables(bin.right.*, used);
            },
            .constant => {},
            .call => |call| {
                for (call.args) |arg| {
                    try self.collectUsedVariables(arg.*, used);
                }
            },
            .builtin_call => |builtin| {
                for (builtin.args) |arg| {
                    try self.collectUsedVariables(arg.*, used);
                }
            },
        }
    }

    pub fn generate(self: *Generator) anyerror![]*rir.RIROP {
        var final_ops = std.ArrayList(*rir.RIROP).init(self.allocator);
        var used = std.StringHashMap(void).init(self.allocator);
        defer used.deinit();

        for (self.module.block.items) |stmt| {
            switch (stmt) {
                .assign => |assign| {
                    const value = try self.generateExpression(assign.value);
                    try self.variables.put(assign.target, value);
                    try self.collectUsedVariables(assign.value, &used);
                },
                .expr => |expr| {
                    const op = try self.generateExpression(expr);
                    try final_ops.append(op);
                    try self.collectUsedVariables(expr, &used);
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

        // Add operations for assigned variables that are not used
        var it = self.variables.iterator();
        while (it.next()) |entry| {
            if (!used.contains(entry.key_ptr.*)) {
                try final_ops.append(entry.value_ptr.*);
            }
        }

        return try final_ops.toOwnedSlice();
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
                result.* = .{ .constant = constant };
            },
            .call => |call| {
                _ = call;
                unreachable;
            },
            .builtin_call => |builtin_call| {
                if (std.mem.eql(u8, builtin_call.identifier, "rand")) {
                    unreachable;
                } else if (std.mem.eql(u8, builtin_call.identifier, "print")) {
                    result.* = .{
                        .print = .{
                            .op = try self.generateExpression(builtin_call.args[0].*),
                        },
                    };
                } else if (std.mem.eql(u8, builtin_call.identifier, "Tensor")) {
                    const shape = try self.generateExpression(builtin_call.args[0].*);
                    result.* = .{
                        .constant = .{
                            .dtype = .F64,
                            .shape = shape,
                        },
                    };
                } else unreachable;
            },
            .variable => |variable| {
                return self.variables.get(variable.identifier).?;
            },
        }
        return result;
    }
};
