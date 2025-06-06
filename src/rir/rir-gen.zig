const std = @import("std");

const ast = @import("../frontend/ast.zig");
const rir = @import("rir.zig");

const builder_script = @import("builder.zig");
const Builder = builder_script.Builder;

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
    builder: Builder,

    pub fn init(module: ast.Module, allocator: std.mem.Allocator) Generator {
        _ = target.LLVMInitializeNativeTarget();
        _ = target.LLVMInitializeNativeAsmPrinter();
        _ = target.LLVMInitializeNativeAsmParser();

        const gen = Generator{
            .allocator = allocator,
            .module = module,
            .builder = Builder.init(allocator),
        };

        return gen;
    }

    pub fn generate(self: *Generator) anyerror!types.LLVMModuleRef {
        for (self.module.block.items) |stmt| {
            try self.generateStatement(stmt);
        }

        const zero = core.LLVMConstInt(core.LLVMInt32Type(), 0, 0);

        _ = core.LLVMBuildRet(self.llvmBuilder, zero);
        core.LLVMDisposeBuilder(self.llvmBuilder);

        return self.llvm_module;
    }

    fn generateStatement(self: *Generator, statement: ast.Statement) anyerror!void {
        switch (statement) {
            .expr => |expr| {
                _ = expr;
                unreachable;
            },
            .assign => |assign| {
                try self.generateExpression(assign.value);
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
    fn generateExpression(self: *Generator, expr: ast.Expression) ![]const u8 {
        _ = self;
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
                _ = call;
                unreachable;
                // TODO: implement host function calls
                // const c_name = try self.allocator.dupeZ(u8, call.identifier);
                // defer self.allocator.free(c_name);

                // const func = core.LLVMGetNamedFunction(self.llvm_module, c_name);

                // const return_type = core.LLVMInt32Type();

                // const return_value_ref: types.LLVMValueRef = undefined;
                // if (call.args.len == 0) {
                //     const fn_type = core.LLVMFunctionType(return_type, null, 0, 0);

                //     return_value_ref = core.LLVMBuildCall2(self.llvmBuilder, fn_type, func, null, 0, "");
                // } else {
                //     var arg_values = try self.allocator.alloc(types.LLVMValueRef, call.args.len);
                //     defer self.allocator.free(arg_values);

                //     for (call.args, 0..) |arg_expr, i| {
                //         const arg_expr_res = try self.generateExpression(arg_expr.*);
                //         arg_values[i] = arg_expr_res.value_ref;
                //     }

                //     const fn_type = core.LLVMFunctionType(return_type, null, 0, 0);

                //     return_value_ref = core.LLVMBuildCall2(self.llvmBuilder, fn_type, func, &arg_values[0], @intCast(arg_values.len), "");
                // }

                // return switch(call.)

            },
            .variable => |variable| {
                return variable.identifier;
            },
        }
    }

    fn generateConstant(self: *Generator, constant: ast.Value) !GenericRef {
        switch (constant) {
            .Integer => {
                const i32Type = core.LLVMInt32Type();
                return .{ .Integer = .{
                    .value_ref = core.LLVMConstInt(i32Type, @intCast(constant.Integer), 0),
                } };
            },
            .Float => {
                const f32Type = core.LLVMFloatType();
                return .{ .Float = .{
                    .value_ref = core.LLVMConstReal(f32Type, constant.Float),
                } };
            },
            .String => {
                const string_val = constant.String;
                const null_terminated = try std.fmt.allocPrint(self.allocator, "{s}\x00", .{string_val});
                defer self.allocator.free(null_terminated);

                const str_type = core.LLVMArrayType(core.LLVMInt8Type(), @intCast(null_terminated.len));
                const str_name = "string";
                const str_global = core.LLVMAddGlobal(self.llvm_module, str_type, str_name.ptr);
                core.LLVMSetGlobalConstant(str_global, 1);
                core.LLVMSetLinkage(str_global, .LLVMInternalLinkage);
                core.LLVMSetInitializer(str_global, core.LLVMConstStringInContext(self.llvm_context, @ptrCast(null_terminated), @intCast(null_terminated.len), 0));

                return .{ .String = .{
                    .value_ref = str_global,
                } };
            },
            .Array => {
                const first_elem = constant.Array[0];
                const element_type = switch (first_elem) {
                    .Integer => core.LLVMInt32Type(),
                    .Float => core.LLVMFloatType(),
                    .String => core.LLVMPointerType(core.LLVMInt8Type(), 0),
                    else => unreachable,
                };

                var element_values = try self.allocator.alloc(types.LLVMValueRef, constant.Array.len);
                defer self.allocator.free(element_values);
                for (constant.Array, 0..) |elem, i| {
                    const res = try self.generateConstant(elem);
                    element_values[i] = switch (res) {
                        .Integer => res.Integer.value_ref,
                        .Float => res.Float.value_ref,
                        else => unreachable,
                    };
                }

                const array_data = core.LLVMConstArray(element_type, @ptrCast(element_values), @intCast(constant.Array.len));

                const array_data_global = core.LLVMAddGlobal(self.llvm_module, core.LLVMTypeOf(array_data), "array_data");
                core.LLVMSetInitializer(array_data_global, array_data);
                core.LLVMSetGlobalConstant(array_data_global, 1);

                const len = core.LLVMConstInt(core.LLVMInt64Type(), constant.Array.len, 0);

                return GenericRef{
                    .FloatArray = FloatArrayRef{
                        .value_ref = array_data_global,
                        .metadata = .{
                            .length = len,
                            .capacity = len,
                        },
                    },
                };
            },
        }
    }

    // this is for print only for now
    fn generateBuiltInFunction(self: *Generator, call: ast.Call) anyerror!void {
        const arg_value = try self.generateExpression(call.args[0].*);

        var print_char_pointer: StringRef = undefined;

        switch (arg_value) {
            .Integer => {
                print_char_pointer = try self.callIntToString(.{ .value_ref = arg_value.Integer.value_ref });
            },
            .Float => {
                print_char_pointer = try self.callFloatToString(.{ .value_ref = arg_value.Float.value_ref });
            },
            .String => {
                print_char_pointer = .{ .value_ref = arg_value.String.value_ref };
            },
            .IntegerArray, .FloatArray => {
                print_char_pointer = try self.callArrayToString(
                    switch (arg_value) {
                        .IntegerArray => .{ .Integer = arg_value.IntegerArray },
                        .FloatArray => .{ .Float = arg_value.FloatArray },
                        else => unreachable,
                    },
                );
            },
            else => unreachable,
        }

        return try self.callPrint(print_char_pointer);
    }

    const BuildFn = fn (types.LLVMBuilderRef, types.LLVMValueRef, types.LLVMValueRef, [*:0]const u8) callconv(.C) types.LLVMValueRef;
    fn dispatchOp(self: *Generator, left: GenericRef, right: GenericRef, float_fn: BuildFn, int_fn: BuildFn) NumericRef {
        if (@intFromEnum(left) != @intFromEnum(right)) @panic("both operands must be same type");
        switch (left) {
            .Float => {
                return NumericRef{ .Float = .{
                    .value_ref = float_fn(self.llvmBuilder, left.Float.value_ref, right.Float.value_ref, ""),
                } };
            },
            .Integer => {
                return NumericRef{ .Integer = .{
                    .value_ref = int_fn(self.llvmBuilder, left.Integer.value_ref, right.Integer.value_ref, ""),
                } };
            },
            else => @panic("unsupported binary operation"),
        }
    }

    // TODO: could split into two functions for integer and float or move this into generateconstant
    fn generateBinary(self: *Generator, binary: ast.Binary) anyerror!NumericRef {
        const left = try self.generateExpression(binary.left.*);
        const right = try self.generateExpression(binary.right.*);

        return switch (binary.operator) {
            .Add => dispatchOp(self, left, right, core.LLVMBuildFAdd, core.LLVMBuildAdd),
            .Subtract => dispatchOp(self, left, right, core.LLVMBuildFSub, core.LLVMBuildSub),
            .Multiply => dispatchOp(self, left, right, core.LLVMBuildFMul, core.LLVMBuildMul),
            .Divide => dispatchOp(self, left, right, core.LLVMBuildFDiv, core.LLVMBuildSDiv),
            else => @panic("Operator not implemented yet"),
        };
    }
};
