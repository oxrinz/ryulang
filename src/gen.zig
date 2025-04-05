const std = @import("std");
const ast = @import("ast.zig");

const PTXBackend = @import("backends/ptx.zig").PTXBackend;

const llvm = @import("llvm");
const target = llvm.target;
const target_machine_mod = llvm.target_machine;
const types = llvm.types;
const core = llvm.core;
const process = std.process;
const execution = llvm.engine;

const GenType = union(enum) {
    Integer,
    Float,
    String,
    Array,
    Pointer: *GenType,
};

const TypedValueRef = struct {
    value_ref: types.LLVMValueRef,
    type: GenType,
};

const RuntimeFunction = enum {
    print,
    int_to_string,
    float_to_string,
    bool_to_string,
    array_to_string,
    print_results,
    string_length,
    run_cuda_kernel,
    load_cuda_kernel,
};

pub const Generator = struct {
    allocator: std.mem.Allocator,
    module: ast.Module,
    llvm_module: types.LLVMModuleRef,
    llvm_context: types.LLVMContextRef,
    builder: types.LLVMBuilderRef,
    named_values: std.StringHashMap(TypedValueRef),
    ptx_backend: PTXBackend,
    kernel: std.ArrayList(u8),

    pub fn init(module: ast.Module, allocator: std.mem.Allocator) Generator {
        _ = target.LLVMInitializeNativeTarget();
        _ = target.LLVMInitializeNativeAsmPrinter();
        _ = target.LLVMInitializeNativeAsmParser();

        const llvm_module: types.LLVMModuleRef = core.LLVMModuleCreateWithName("main_module");
        const builder = core.LLVMCreateBuilder().?;

        const main_type: types.LLVMTypeRef = core.LLVMFunctionType(core.LLVMInt32Type(), null, 0, 0);
        const main_func: types.LLVMValueRef = core.LLVMAddFunction(llvm_module, "main", main_type);

        const main_entry: types.LLVMBasicBlockRef = core.LLVMAppendBasicBlock(main_func, "entry");
        core.LLVMPositionBuilderAtEnd(builder, main_entry);

        var gen = Generator{
            .allocator = allocator,
            .module = module,
            .builder = builder,
            .named_values = std.StringHashMap(TypedValueRef).init(allocator),
            .ptx_backend = undefined,
            .llvm_module = llvm_module,
            .llvm_context = core.LLVMContextCreate(),
            .kernel = std.ArrayList(u8).init(allocator),
        };
        gen.ptx_backend = PTXBackend.init(allocator, &gen);

        return gen;
    }

    pub fn generate(self: *Generator) anyerror!struct { llvm_module: types.LLVMModuleRef, ptx: []const u8 } {
        for (self.module.block.items) |stmt| {
            try self.generateStatement(stmt);
        }

        const zero = core.LLVMConstInt(core.LLVMInt32Type(), 0, 0);
        _ = core.LLVMBuildRet(self.builder, zero);

        const kernel = try self.kernel.toOwnedSlice();
        const kernel_len = kernel.len;
        const kernel_type = core.LLVMArrayType(core.LLVMInt8Type(), @intCast(kernel_len + 1));
        const kernel_constant = core.LLVMConstString(@ptrCast(kernel), @intCast(kernel_len), 0);

        const name_z = try self.allocator.dupeZ(u8, "main");
        defer self.allocator.free(name_z);

        const global_ptx_str = core.LLVMAddGlobal(self.llvm_module, kernel_type, name_z.ptr);
        core.LLVMSetInitializer(global_ptx_str, kernel_constant);

        const main_fn = core.LLVMGetNamedFunction(self.llvm_module, "main");
        const entry_block = core.LLVMGetEntryBasicBlock(main_fn);
        const first_instr = core.LLVMGetFirstInstruction(entry_block);
        core.LLVMPositionBuilderBefore(self.builder, first_instr);

        var args = [_]TypedValueRef{
            .{
                .type = .Array,
                .value_ref = global_ptx_str,
            },
        };

        _ = try self.callRuntimeFunction(.load_cuda_kernel, &args);

        core.LLVMDisposeBuilder(self.builder);

        return .{ .llvm_module = self.llvm_module, .ptx = kernel };
    }

    fn generateStatement(self: *Generator, statement: ast.Statement) anyerror!void {
        switch (statement) {
            .expr => |expr| {
                _ = try self.generateExpression(expr);
            },
            .assign => |assign| {
                const value = try self.generateExpression(assign.value);

                try self.named_values.put(assign.target, value);
            },
            .function_definition => |function_definition| {
                if (function_definition.type == .Device) {
                    const ptx = try self.ptx_backend.generateKernel(function_definition);
                    try self.addKernel(ptx);
                } else {
                    const func_type: types.LLVMTypeRef = core.LLVMFunctionType(core.LLVMInt32Type(), null, 0, 0);
                    const c_name = try self.allocator.dupeZ(u8, function_definition.identifier);
                    defer self.allocator.free(c_name);
                    const func: types.LLVMValueRef = core.LLVMAddFunction(self.llvm_module, c_name, func_type);

                    const current_block = core.LLVMGetInsertBlock(self.builder);

                    const entry: types.LLVMBasicBlockRef = core.LLVMAppendBasicBlock(func, "entry");
                    core.LLVMPositionBuilderAtEnd(self.builder, entry);

                    for (function_definition.body.items) |stmt| {
                        try self.generateStatement(stmt);
                    }

                    const zero = core.LLVMConstInt(core.LLVMInt32Type(), 0, 0);
                    _ = core.LLVMBuildRet(self.builder, zero);

                    core.LLVMPositionBuilderAtEnd(self.builder, current_block);
                }
            },
            .compound => |compound| {
                _ = compound;
            },
        }
    }

    fn generateExpression(self: *Generator, expr: ast.Expression) !TypedValueRef {
        switch (expr) {
            .binary => |binary| {
                return try self.generateBinary(binary);
            },
            .constant => |constant| {
                return try self.generateConstant(constant);
            },
            .call => |call| {
                if (call.type == .Device) {
                    const array = try self.generateExpression(call.args[0].*);
                    const array_metadata = self.getArrayMetadata(array);
                    const array_element_count = array_metadata.length.value_ref;
                    const float_type = core.LLVMFloatType();
                    const result_ptr = core.LLVMBuildArrayMalloc(self.builder, float_type, array_element_count, "result_ptr");

                    const input_ptr = array_metadata.data_ptr.value_ref;
                    const input_ptrs_ptr = core.LLVMBuildAlloca(self.builder, core.LLVMPointerType(float_type, 0), "input_ptrs_ptr");
                    _ = core.LLVMBuildStore(self.builder, input_ptr, input_ptrs_ptr);

                    var args = [_]TypedValueRef{
                        .{
                            .type = .Array,
                            .value_ref = input_ptrs_ptr,
                        },
                        .{
                            .type = .Array,
                            .value_ref = result_ptr,
                        },
                    };

                    _ = try self.callRuntimeFunction(.run_cuda_kernel, &args);

                    var gen_type: GenType = .Float;
                    return self.createArrayStruct(array_metadata.length, .{
                        .type = .{ .Pointer = &gen_type },
                        .value_ref = result_ptr,
                    });
                } else {
                    if (call.builtin == true) {
                        _ = try self.generateBuiltInFunction(call);
                        const zero = core.LLVMConstInt(core.LLVMInt32Type(), 0, 0);
                        return TypedValueRef{
                            .value_ref = zero,
                            .type = .Integer,
                        };
                    } else {
                        const c_name = try self.allocator.dupeZ(u8, call.identifier);
                        defer self.allocator.free(c_name);

                        const func = core.LLVMGetNamedFunction(self.llvm_module, c_name);

                        if (call.args.len == 0) {
                            const return_type = core.LLVMInt32Type();
                            const fn_type = core.LLVMFunctionType(return_type, null, 0, 0);

                            return TypedValueRef{
                                .type = .Float,
                                .value_ref = core.LLVMBuildCall2(self.builder, fn_type, func, null, 0, ""),
                            };
                        } else {
                            var arg_values = try self.allocator.alloc(types.LLVMValueRef, call.args.len);
                            defer self.allocator.free(arg_values);

                            for (call.args, 0..) |arg_expr, i| {
                                const arg_expr_res = try self.generateExpression(arg_expr.*);
                                arg_values[i] = arg_expr_res.value_ref;
                            }

                            const return_type = core.LLVMInt32Type();
                            const fn_type = core.LLVMFunctionType(return_type, null, 0, 0);

                            return TypedValueRef{
                                .type = .Float,
                                .value_ref = core.LLVMBuildCall2(self.builder, fn_type, func, &arg_values[0], @intCast(arg_values.len), ""),
                            };
                        }
                    }
                }
            },
            .variable => |variable| {
                const value = self.named_values.get(variable.identifier) orelse {
                    @panic("Use of undefined variable");
                };
                return value;
            },
        }
    }

    fn generateConstant(self: *Generator, constant: ast.Value) !TypedValueRef {
        switch (constant) {
            .Integer => {
                const i32Type = core.LLVMInt32Type();
                return TypedValueRef{
                    .type = .Integer,
                    .value_ref = core.LLVMConstInt(i32Type, @intCast(constant.Integer), 0),
                };
            },
            .Float => {
                const f32Type = core.LLVMFloatType();
                return TypedValueRef{
                    .type = .Float,
                    .value_ref = core.LLVMConstReal(f32Type, constant.Float),
                };
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
                core.LLVMSetInitializer(str_global, core.LLVMConstStringInContext(self.llvm_context, @ptrCast(null_terminated), @intCast(null_terminated.len), 0 // Don't null-terminate again; already done
                ));

                return TypedValueRef{
                    .type = .String,
                    .value_ref = str_global,
                };
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
                    element_values[i] = res.value_ref;
                }

                const array_data = core.LLVMConstArray(element_type, @ptrCast(element_values), @intCast(constant.Array.len));

                const array_data_global = core.LLVMAddGlobal(self.llvm_module, core.LLVMTypeOf(array_data), "array_data");
                core.LLVMSetInitializer(array_data_global, array_data);
                core.LLVMSetGlobalConstant(array_data_global, 1);

                const i32_type = core.LLVMInt32Type();

                var pointer_type: GenType = .Float;
                return self.createArrayStruct(
                    .{ .type = .Integer, .value_ref = core.LLVMConstInt(i32_type, constant.Array.len, 0) },
                    .{ .type = .{ .Pointer = &pointer_type }, .value_ref = array_data_global },
                );
            },
        }
    }

    fn getExternalFunction(self: *Generator, name: []const u8, fn_type: types.LLVMTypeRef) types.LLVMValueRef {
        var fn_val = core.LLVMGetNamedFunction(self.llvm_module, @ptrCast(name));
        if (fn_val == null) {
            fn_val = core.LLVMAddFunction(self.llvm_module, @ptrCast(name), fn_type);
            core.LLVMSetLinkage(fn_val, .LLVMExternalLinkage);
        }
        return fn_val;
    }

    fn generateBuiltInFunction(self: *Generator, call: ast.Call) anyerror!?TypedValueRef {
        const arg_value = try self.generateExpression(call.args[0].*);

        var print_args = std.ArrayList(TypedValueRef).init(self.allocator);

        switch (arg_value.type) {
            .Integer => {
                const int_value = arg_value.value_ref;

                var args = [_]TypedValueRef{.{
                    .type = .Integer,
                    .value_ref = int_value,
                }};

                const res = try self.callRuntimeFunction(.int_to_string, &args);

                try print_args.append(TypedValueRef{
                    .type = .Integer,
                    .value_ref = res.?.value_ref,
                });
            },
            .Float => {
                const float_value = arg_value.value_ref;

                var args = [_]TypedValueRef{.{
                    .type = .Float,
                    .value_ref = float_value,
                }};

                const res = try self.callRuntimeFunction(.float_to_string, &args);

                try print_args.append(TypedValueRef{
                    .type = .Float,
                    .value_ref = res.?.value_ref,
                });
            },
            .String => {
                const str_global = arg_value.value_ref;

                try print_args.append(TypedValueRef{
                    .type = .String,
                    .value_ref = str_global,
                });
            },
            .Array => {
                const array_metadata = self.getArrayMetadata(arg_value);

                const length_val = array_metadata.length.value_ref;
                const type_val = core.LLVMConstInt(core.LLVMInt32Type(), 1, 0);

                var args = [_]TypedValueRef{
                    array_metadata.data_ptr,
                    .{
                        .type = .Float,
                        .value_ref = length_val,
                    },
                    .{
                        .type = .Float,
                        .value_ref = type_val,
                    },
                };

                const res = try self.callRuntimeFunction(.array_to_string, &args);

                try print_args.append(TypedValueRef{
                    .type = .String,
                    .value_ref = res.?.value_ref,
                });
            },
            else => unreachable,
        }

        return try self.callRuntimeFunction(.print, try print_args.toOwnedSlice());
    }

    const BuildFn = fn (types.LLVMBuilderRef, types.LLVMValueRef, types.LLVMValueRef, [*:0]const u8) callconv(.C) types.LLVMValueRef;
    fn dispatchOp(self: *Generator, left: TypedValueRef, right: TypedValueRef, float_fn: BuildFn, int_fn: BuildFn) TypedValueRef {
        if (@intFromEnum(left.type) != @intFromEnum(right.type)) @panic("both operands must be same type");
        switch (left.type) {
            .Float => {
                return TypedValueRef{
                    .type = .Float,
                    .value_ref = float_fn(self.builder, left.value_ref, right.value_ref, ""),
                };
            },
            .Integer => {
                return TypedValueRef{
                    .type = .Integer,
                    .value_ref = int_fn(self.builder, left.value_ref, right.value_ref, ""),
                };
            },
            else => @panic("unsupported binary operation"),
        }
    }

    fn generateBinary(self: *Generator, binary: ast.Binary) anyerror!TypedValueRef {
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

    fn callRuntimeFunction(self: *Generator, function: RuntimeFunction, args: []TypedValueRef) anyerror!?TypedValueRef {
        const char_ptr_type = core.LLVMPointerType(core.LLVMInt8Type(), 0);
        const void_ptr_type = core.LLVMPointerType(core.LLVMVoidType(), 0);

        switch (function) {
            .print => {
                const name = "print";

                var param_types = [_]types.LLVMTypeRef{char_ptr_type};
                const fn_type = core.LLVMFunctionType(core.LLVMVoidType(), @ptrCast(&param_types[0]), param_types.len, 0);
                const fn_val = try self.getRuntimeFunction(name, fn_type);

                const final_args = [_]types.LLVMValueRef{args[0].value_ref};

                _ = core.LLVMBuildCall2(self.builder, fn_type, fn_val, @ptrCast(@constCast(&final_args)), 1, "");
            },
            .int_to_string => {
                const name = "int_to_string";
                var param_types = [_]types.LLVMTypeRef{core.LLVMInt32Type()};
                const fn_type = core.LLVMFunctionType(char_ptr_type, @ptrCast(&param_types[0]), param_types.len, 0);
                const fn_val = try self.getRuntimeFunction(name, fn_type);
                const final_args = [_]types.LLVMValueRef{args[0].value_ref};

                const str_ptr = core.LLVMBuildCall2(self.builder, fn_type, fn_val, @ptrCast(@constCast(&final_args)), 1, "");

                return TypedValueRef{
                    .type = .String,
                    .value_ref = str_ptr,
                };
            },
            .float_to_string => {
                const name = "float_to_string";
                var param_types = [_]types.LLVMTypeRef{core.LLVMInt32Type()};
                const fn_type = core.LLVMFunctionType(char_ptr_type, @ptrCast(&param_types[0]), param_types.len, 0);
                const fn_val = try self.getRuntimeFunction(name, fn_type);
                const final_args = [_]types.LLVMValueRef{args[0].value_ref};

                const str_ptr = core.LLVMBuildCall2(self.builder, fn_type, fn_val, @ptrCast(@constCast(&final_args)), 1, "");

                return TypedValueRef{
                    .type = .String,
                    .value_ref = str_ptr,
                };
            },
            .array_to_string => {
                const name = "array_to_string";
                var param_types = [_]types.LLVMTypeRef{
                    core.LLVMPointerType(core.LLVMVoidType(), 0),
                    core.LLVMInt32Type(),
                    core.LLVMInt32Type(),
                };
                const fn_type = core.LLVMFunctionType(char_ptr_type, @ptrCast(&param_types[0]), param_types.len, 0);
                const fn_val = try self.getRuntimeFunction(name, fn_type);
                const final_args = [_]types.LLVMValueRef{ args[0].value_ref, args[1].value_ref, args[2].value_ref };

                const str_ptr = core.LLVMBuildCall2(self.builder, fn_type, fn_val, @ptrCast(@constCast(&final_args)), 3, "");

                return TypedValueRef{
                    .type = .String,
                    .value_ref = str_ptr,
                };
            },
            .string_length => {
                const name = "string_length";
                var param_types = [_]types.LLVMTypeRef{char_ptr_type};
                const fn_type = core.LLVMFunctionType(core.LLVMInt32Type(), @ptrCast(&param_types[0]), param_types.len, 0);
                const fn_val = try self.getRuntimeFunction(name, fn_type);
                const final_args = [_]types.LLVMValueRef{args[0].value_ref};
                return TypedValueRef{
                    .type = .Integer,
                    .value_ref = core.LLVMBuildCall2(self.builder, fn_type, fn_val, @ptrCast(@constCast(&final_args)), 1, "strlen_result"),
                };
            },
            .run_cuda_kernel => {
                const name = "run_cuda_kernel";
                var param_types = [_]types.LLVMTypeRef{
                    void_ptr_type,
                    void_ptr_type,
                };
                const fn_type = core.LLVMFunctionType(core.LLVMInt32Type(), @ptrCast(&param_types[0]), param_types.len, 0);
                const fn_val = try self.getRuntimeFunction(name, fn_type);

                const final_args = [_]types.LLVMValueRef{
                    args[0].value_ref,
                    args[1].value_ref,
                };

                _ = core.LLVMBuildCall2(self.builder, fn_type, fn_val, @ptrCast(@constCast(&final_args)), 2, "");
            },
            .load_cuda_kernel => {
                const name = "load_cuda_kernel";
                var param_types = [_]types.LLVMTypeRef{char_ptr_type};
                const fn_type = core.LLVMFunctionType(core.LLVMVoidType(), @ptrCast(&param_types[0]), param_types.len, 0);
                const fn_val = try self.getRuntimeFunction(name, fn_type);
                const final_args = [_]types.LLVMValueRef{args[0].value_ref};

                _ = core.LLVMBuildCall2(self.builder, fn_type, fn_val, @ptrCast(@constCast(&final_args)), 1, "");
            },
            else => unreachable,
        }

        return null;
    }

    fn getRuntimeFunction(self: *Generator, name: []const u8, fn_type: types.LLVMTypeRef) !types.LLVMValueRef {
        var fn_val = core.LLVMGetNamedFunction(self.llvm_module, @ptrCast(name));
        if (fn_val == null) {
            fn_val = core.LLVMAddFunction(self.llvm_module, @ptrCast(name), fn_type);
            core.LLVMSetLinkage(fn_val, .LLVMExternalLinkage);
        }

        return fn_val;
    }

    fn getArrayMetadata(self: *Generator, array: TypedValueRef) struct { length: TypedValueRef, capacity: TypedValueRef, data_ptr: TypedValueRef } {
        if (array.type != .Array) @panic("trying to get metadata from a value that is not array");
        var ptr_type: GenType = .Integer;
        return .{
            .length = .{
                .type = .Integer,
                .value_ref = core.LLVMBuildExtractValue(self.builder, array.value_ref.?, 0, "array_len"),
            },
            .capacity = .{
                .type = .Integer,
                .value_ref = core.LLVMBuildExtractValue(self.builder, array.value_ref.?, 1, "array_capacity"),
            },
            .data_ptr = .{
                .type = .{ .Pointer = &ptr_type },
                .value_ref = core.LLVMBuildExtractValue(self.builder, array.value_ref.?, 2, "array_data_ptr"),
            },
        };
    }

    fn createArrayStruct(self: *Generator, length: TypedValueRef, data_ptr: TypedValueRef) !TypedValueRef {
        var header_values = try self.allocator.alloc(types.LLVMValueRef, 3);
        defer self.allocator.free(header_values);
        header_values[0] = length.value_ref;
        header_values[1] = length.value_ref;
        header_values[2] = data_ptr.value_ref;

        return TypedValueRef{
            .type = .Array,
            .value_ref = core.LLVMConstStruct(@ptrCast(header_values), 3, 0),
        };
    }

    fn addKernel(self: *Generator, ptx: []const u8) !void {
        try self.kernel.appendSlice(ptx);
    }
};
