const std = @import("std");

const ast = @import("../frontend/ast.zig");
const rir = @import("rir.zig");
const program = @import("../program.zig");

const rllvm = @import("rllvm");
const target = rllvm.llvm.target;
const target_machine_mod = rllvm.llvm.target_machine;
const types = rllvm.llvm.types;
const core = rllvm.llvm.core;
const execution = rllvm.llvm.engine;

pub fn generateProgram(module: ast.Module, allocator: std.mem.Allocator) !program.Program {
    var variables = std.StringArrayHashMap(*rir.RIROP).init(allocator);
    var used = std.StringHashMap(void).init(allocator);
    defer used.deinit();

    var graph = std.ArrayList(*rir.RIROP).init(allocator);

    const collectUsedVariables = struct {
        pub fn collectUsedVariables(expr: ast.Expression, in_used: *std.StringHashMap(void)) !void {
            switch (expr) {
                .variable => |variable| {
                    try in_used.put(variable.identifier, {});
                },
                .binary => |bin| {
                    try collectUsedVariables(bin.left.*, in_used);
                    try collectUsedVariables(bin.right.*, in_used);
                },
                .constant => {},
                .call => |call| {
                    for (call.args) |arg| {
                        try collectUsedVariables(arg.*, in_used);
                    }
                },
                .builtin_call => |builtin| {
                    for (builtin.args) |arg| {
                        try collectUsedVariables(arg.*, in_used);
                    }
                },
            }
        }
    }.collectUsedVariables;

    const Generator = struct {
        allocator: std.mem.Allocator,
        effects: std.ArrayList(program.Effect),
        variables: *std.StringArrayHashMap(*rir.RIROP),

        pub fn init(alloc: std.mem.Allocator, vars: *std.StringArrayHashMap(*rir.RIROP)) @This() {
            return .{
                .allocator = alloc,
                .effects = std.ArrayList(program.Effect).init(alloc),
                .variables = vars,
            };
        }

        pub fn generateExpression(self: *@This(), expr: ast.Expression) !?*rir.RIROP {
            const result = try self.allocator.create(rir.RIROP);
            switch (expr) {
                .binary => |binary| {
                    switch (binary.operator) {
                        .Add => {
                            const a = try self.generateExpression(binary.left.*);
                            const b = try self.generateExpression(binary.right.*);
                            result.* = .{ .add = .{
                                .a = a.?,
                                .b = b.?,
                            } };
                        },
                        else => unreachable,
                    }
                },
                // TODO: cast to the correct default dtype
                .constant => |constant| {
                    var size: usize = 1;
                    for (constant.shape) |dim| {
                        size *= dim;
                    }
                    const float_array = @as([*]f32, @alignCast(@ptrCast(constant.ptr)))[0..size];
                    var llvm_vals = try self.allocator.alloc(types.LLVMValueRef, size);
                    defer self.allocator.free(llvm_vals);

                    for (float_array, 0..) |val, i| {
                        llvm_vals[i] = core.LLVMConstReal(core.LLVMFloatType(), val);
                    }
                    const array = core.LLVMConstArray(core.LLVMFloatType(), llvm_vals.ptr, @intCast(size));
                    const buffer = try self.allocator.create(rir.RIROP);
                    buffer.* = .{
                        .buffer = .{
                            .device = .host,
                            .dtype = constant.dtype,
                            .ref = array,
                            .size = size,
                        },
                    };

                    const view = try self.allocator.create(rir.RIROP);
                    view.* = .{
                        .view = .{
                            .shape = constant.shape,
                            .src = buffer,
                        },
                    };

                    result.* = view.*;
                },
                .call => |call| {
                    _ = call;
                    unreachable;
                },
                .builtin_call => |builtin_call| {
                    if (std.mem.eql(u8, builtin_call.identifier, "rand")) {
                        unreachable;
                    } else if (std.mem.eql(u8, builtin_call.identifier, "print")) {
                        var operands = std.ArrayList(*rir.RIROP).init(self.allocator);
                        for (builtin_call.args) |arg| {
                            const op = try self.generateExpression(arg.*);
                            try operands.append(op.?);
                        }

                        const ops = try operands.toOwnedSlice();

                        const effect = program.Effect{
                            .effect_type = .print,
                            .targets = ops,
                        };

                        try self.effects.append(effect);

                        return ops[0];
                    } else if (std.mem.eql(u8, builtin_call.identifier, "Tensor")) {
                        const copy = try self.generateExpression(builtin_call.args[0].*);
                        result.* = copy.?.*;
                    } else unreachable;
                },
                .variable => |variable| {
                    std.debug.print("VAR: {any}\n", .{variable.identifier});
                    return self.variables.get(variable.identifier).?;
                },
            }
            return result;
        }
    };

    var genFns = Generator.init(allocator, &variables);

    for (module.block.items) |stmt| {
        switch (stmt) {
            .assign => |assign| {
                const value = try genFns.generateExpression(assign.value);

                try variables.put(assign.target, value.?);
                try collectUsedVariables(assign.value, &used);
            },
            .expr => |expr| {
                const op = try genFns.generateExpression(expr);
                try graph.append(op.?);
                try collectUsedVariables(expr, &used);
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

    return .{ .effects = try genFns.effects.toOwnedSlice(), .graph = try graph.toOwnedSlice() };
}
