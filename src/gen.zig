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

const DeviceRef = struct {
    value_ref: types.LLVMValueRef,
};

const DevicePointerRef = struct {
    value_ref: types.LLVMValueRef,
};

const ContextRef = struct {
    value_ref: types.LLVMValueRef,
};

const ModuleRef = struct {
    value_ref: types.LLVMValueRef,
};

const IntegerRef = struct {
    value_ref: types.LLVMValueRef,
};

const FloatRef = struct {
    value_ref: types.LLVMValueRef,
};

const StringRef = struct {
    value_ref: types.LLVMValueRef,
};

const NumericRef = union(enum) {
    Integer: IntegerRef,
    Float: FloatRef,
};

const ArrayMetadata = struct {
    length: types.LLVMValueRef,
    capacity: types.LLVMValueRef,
};

const IntegerArrayRef = struct {
    value_ref: types.LLVMValueRef,
    metadata: ArrayMetadata,
};

const FloatArrayRef = struct {
    value_ref: types.LLVMValueRef,
    metadata: ArrayMetadata,
};

const StringArrayRef = struct {
    value_ref: types.LLVMValueRef,
    metadata: ArrayMetadata,
};

fn createArrayMethodsForUnion(comptime T: type) type {
    return struct {
        pub fn getValueRef(self: *const T) types.LLVMValueRef {
            return switch (self.*) {
                inline else => |val| val.value_ref,
            };
        }

        pub fn getMetadata(self: *const T) ArrayMetadata {
            return switch (self.*) {
                inline else => |val| val.metadata,
            };
        }
    };
}

const NumericArrayRef = union(enum) {
    Integer: IntegerArrayRef,
    Float: FloatArrayRef,

    pub usingnamespace createArrayMethodsForUnion(@This());
};

// arrays are currently always expected to be pointers
const GenericArrayRef = union(enum) {
    Integer: IntegerArrayRef,
    Float: FloatArrayRef,
    String: StringArrayRef,

    pub usingnamespace createArrayMethodsForUnion(@This());
};

const IntegerPointerRef = struct {
    value_ref: types.LLVMValueRef,
};

const FloatPointerRef = struct {
    value_ref: types.LLVMValueRef,
};

const StringPointerRef = struct {
    value_ref: types.LLVMValueRef,
};

const GenericRef = union(enum) {
    Integer: IntegerRef,
    Float: FloatRef,
    String: StringRef,
    IntegerArray: IntegerArrayRef,
    FloatArray: FloatArrayRef,
    StringArray: StringArrayRef,
    IntegerPointer: IntegerPointerRef,
    FloatPointer: FloatPointerRef,
    StringPointer: StringPointerRef,
};

pub const Generator = struct {
    allocator: std.mem.Allocator,
    module: ast.Module,
    llvm_module: types.LLVMModuleRef,
    llvm_context: types.LLVMContextRef,
    builder: types.LLVMBuilderRef,
    named_values: std.StringHashMap(GenericRef),
    ptx_backend: PTXBackend,
    kernel: std.ArrayList(u8),
    cuda_error_block: ?types.LLVMBasicBlockRef = null,
    cuda_device: ?DeviceRef = null,
    cuda_context: ?ContextRef = null,
    cuda_module: ?ModuleRef = null,

    pub fn init(module: ast.Module, allocator: std.mem.Allocator) Generator {
        _ = target.LLVMInitializeNativeTarget();
        _ = target.LLVMInitializeNativeAsmPrinter();
        _ = target.LLVMInitializeNativeAsmParser();

        const llvm_module: types.LLVMModuleRef = core.LLVMModuleCreateWithName("main_module");
        const builder = core.LLVMCreateBuilder().?;

        var gen = Generator{
            .allocator = allocator,
            .module = module,
            .builder = builder,
            .named_values = std.StringHashMap(GenericRef).init(allocator),
            .ptx_backend = undefined,
            .llvm_module = llvm_module,
            .llvm_context = core.LLVMContextCreate(),
            .kernel = std.ArrayList(u8).init(allocator),
        };
        gen.ptx_backend = PTXBackend.init(allocator, &gen);

        return gen;
    }

    pub fn generate(self: *Generator) anyerror!struct { llvm_module: types.LLVMModuleRef, ptx: []const u8 } {
        const main_type: types.LLVMTypeRef = core.LLVMFunctionType(core.LLVMInt32Type(), null, 0, 0);
        const main_func: types.LLVMValueRef = core.LLVMAddFunction(self.llvm_module, "main", main_type);

        const main_entry: types.LLVMBasicBlockRef = core.LLVMAppendBasicBlock(main_func, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, main_entry);

        for (self.module.block.items) |stmt| {
            try self.generateStatement(stmt);
        }

        const zero = core.LLVMConstInt(core.LLVMInt32Type(), 0, 0);
        _ = core.LLVMBuildRet(self.builder, zero);

        const main_fn = core.LLVMGetNamedFunction(self.llvm_module, "main");
        const entry_block = core.LLVMGetEntryBasicBlock(main_fn);
        const first_instr = core.LLVMGetFirstInstruction(entry_block);

        core.LLVMPositionBuilderBefore(self.builder, first_instr);

        try self.initializeCuda();
        // _ = try self.callLoadCudaKernel(StringRef{ .value_ref = global_ptx_str });

        core.LLVMDisposeBuilder(self.builder);

        return .{ .llvm_module = self.llvm_module, .ptx = try self.kernel.toOwnedSlice() };
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

    // TODO: would be nice to split functions that have known return value and unknown into separate scripts
    fn generateExpression(self: *Generator, expr: ast.Expression) !GenericRef {
        switch (expr) {
            .binary => |binary| {
                const result = try self.generateBinary(binary);
                return switch (result) {
                    .Integer => GenericRef{ .Integer = result.Integer },
                    .Float => GenericRef{ .Float = result.Float },
                };
            },
            .constant => |constant| {
                return try self.generateConstant(constant);
            },
            .call => |call| {
                if (call.type == .Device) {
                    const gen_res = try self.generateExpression(call.args[0].*);
                    const array = gen_res.FloatArray;
                    const array_element_count = array.metadata.length;
                    const float_type = core.LLVMFloatType();
                    const result_ptr = FloatArrayRef{
                        .value_ref = core.LLVMBuildArrayMalloc(self.builder, float_type, array_element_count, "result_ptr"),
                        .metadata = array.metadata,
                    };
                    const d_output = DevicePointerRef{ .value_ref = core.LLVMBuildAlloca(self.builder, core.LLVMInt64Type(), "device_ptr") };
                    const uint_type = core.LLVMInt32Type();
                    const grid_dims_type = core.LLVMArrayType(uint_type, 3);
                    const grid_dims_ptr = core.LLVMBuildAlloca(self.builder, grid_dims_type, "grid_dims_ptr");

                    const one = core.LLVMConstInt(uint_type, 1, 0);
                    for (0..3) |i| {
                        const idx = core.LLVMConstInt(core.LLVMInt32Type(), i, 0);
                        var indices = [_]types.LLVMValueRef{
                            core.LLVMConstInt(core.LLVMInt32Type(), 0, 0),
                            idx,
                        };
                        const element_ptr = core.LLVMBuildGEP2(self.builder, grid_dims_type, grid_dims_ptr, &indices, 2, "");
                        _ = core.LLVMBuildStore(self.builder, one, element_ptr);
                    }

                    const block_dims_type = core.LLVMArrayType(uint_type, 3);
                    const block_dims_ptr = core.LLVMBuildAlloca(self.builder, block_dims_type, "block_dims_ptr");

                    const block_dims = [_]u32{ 6, 1, 1 };
                    for (0..3) |i| {
                        const val = core.LLVMConstInt(uint_type, block_dims[i], 0);
                        const idx = core.LLVMConstInt(core.LLVMInt32Type(), i, 0);
                        var indices = [_]types.LLVMValueRef{
                            core.LLVMConstInt(core.LLVMInt32Type(), 0, 0),
                            idx,
                        };
                        const element_ptr = core.LLVMBuildGEP2(self.builder, block_dims_type, block_dims_ptr, &indices, 2, "");
                        _ = core.LLVMBuildStore(self.builder, val, element_ptr);
                    }

                    const three = core.LLVMConstInt(core.LLVMInt32Type(), 3, 0);

                    _ = try self.callRunCudaKernel(
                        .{ .float = FloatArrayRef{ .value_ref = array.value_ref, .metadata = array.metadata } },
                        IntegerRef{ .value_ref = core.LLVMConstInt(core.LLVMInt32Type(), 1, 0) },
                        d_output,
                        IntegerArrayRef{
                            .value_ref = grid_dims_ptr,
                            .metadata = .{
                                .capacity = three,
                                .length = three,
                            },
                        },
                        IntegerArrayRef{
                            .value_ref = block_dims_ptr,
                            .metadata = .{
                                .capacity = three,
                                .length = three,
                            },
                        },
                    );
                    _ = try self.callCuCopyDToH(d_output, .{ .Float = result_ptr });
                    return GenericRef{ .FloatArray = result_ptr };
                } else {
                    if (call.builtin == true) {
                        try self.generateBuiltInFunction(call);
                        const zero = core.LLVMConstInt(core.LLVMInt32Type(), 0, 0);
                        return GenericRef{
                            .Integer = .{
                                .value_ref = zero,
                            },
                        };
                    } else {
                        // TODO: implement host function calls
                        unreachable;
                        // const c_name = try self.allocator.dupeZ(u8, call.identifier);
                        // defer self.allocator.free(c_name);

                        // const func = core.LLVMGetNamedFunction(self.llvm_module, c_name);

                        // const return_type = core.LLVMInt32Type();

                        // const return_value_ref: types.LLVMValueRef = undefined;
                        // if (call.args.len == 0) {
                        //     const fn_type = core.LLVMFunctionType(return_type, null, 0, 0);

                        //     return_value_ref = core.LLVMBuildCall2(self.builder, fn_type, func, null, 0, "");
                        // } else {
                        //     var arg_values = try self.allocator.alloc(types.LLVMValueRef, call.args.len);
                        //     defer self.allocator.free(arg_values);

                        //     for (call.args, 0..) |arg_expr, i| {
                        //         const arg_expr_res = try self.generateExpression(arg_expr.*);
                        //         arg_values[i] = arg_expr_res.value_ref;
                        //     }

                        //     const fn_type = core.LLVMFunctionType(return_type, null, 0, 0);

                        //     return_value_ref = core.LLVMBuildCall2(self.builder, fn_type, func, &arg_values[0], @intCast(arg_values.len), "");
                        // }

                        // return switch(call.)
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
                core.LLVMSetInitializer(str_global, core.LLVMConstStringInContext(self.llvm_context, @ptrCast(null_terminated), @intCast(null_terminated.len), 0 // Don't null-terminate again; already done
                ));

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
                    .value_ref = float_fn(self.builder, left.Float.value_ref, right.Float.value_ref, ""),
                } };
            },
            .Integer => {
                return NumericRef{ .Integer = .{
                    .value_ref = int_fn(self.builder, left.Integer.value_ref, right.Integer.value_ref, ""),
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

    fn initializeCuda(self: *Generator) !void {
        try self.callCuInit();
        try self.callCuDeviceGet();
        try self.callCuContextCreate();
        try self.callCuModuleLoadData();
    }

    fn runCudaKernel(self: *Generator) !void {
        self.callCuModuleGetFunction();
    }

    fn callPrint(self: *Generator, string: StringRef) !void {
        var param_types = [_]types.LLVMTypeRef{core.LLVMPointerType(core.LLVMInt8Type(), 0)};
        var final_args = [_]types.LLVMValueRef{string.value_ref};

        _ = try self.callExternalFunction("print", core.LLVMVoidType(), &param_types, &final_args);
    }

    fn callPrintCudaError(self: *Generator, error_code: IntegerRef, function: IntegerRef) !void {
        var param_types = [_]types.LLVMTypeRef{ core.LLVMInt32Type(), core.LLVMInt32Type() };
        var final_args = [_]types.LLVMValueRef{ error_code.value_ref, function.value_ref };

        _ = try self.callExternalFunction("print_cuda_error", core.LLVMVoidType(), &param_types, &final_args);
    }

    fn callIntToString(self: *Generator, integer: IntegerRef) !StringRef {
        var param_types = [_]types.LLVMTypeRef{core.LLVMInt32Type()};
        var final_args = [_]types.LLVMValueRef{integer.value_ref};

        return StringRef{
            .value_ref = try self.callExternalFunction("int_to_string", core.LLVMPointerType(core.LLVMInt8Type(), 0), &param_types, &final_args),
        };
    }

    fn callFloatToString(self: *Generator, float: FloatRef) !StringRef {
        var param_types = [_]types.LLVMTypeRef{core.LLVMInt32Type()};
        var final_args = [_]types.LLVMValueRef{float.value_ref};

        return StringRef{
            .value_ref = try self.callExternalFunction("float_to_string", core.LLVMPointerType(core.LLVMInt8Type(), 0), &param_types, &final_args),
        };
    }

    fn callArrayToString(self: *Generator, array_ref: GenericArrayRef) !StringRef {
        var param_types = [_]types.LLVMTypeRef{ core.LLVMPointerType(core.LLVMVoidType(), 0), core.LLVMInt32Type(), core.LLVMInt32Type() };

        const elem_type_int: usize = switch (array_ref) {
            .Float => 1,
            .Integer => 0,
            .String => 2,
        };

        var final_args = [_]types.LLVMValueRef{
            array_ref.getValueRef(),
            array_ref.getMetadata().length,
            core.LLVMConstInt(core.LLVMInt32Type(), @intCast(elem_type_int), 0),
        };

        return StringRef{
            .value_ref = try self.callExternalFunction("array_to_string", core.LLVMPointerType(core.LLVMInt8Type(), 0), &param_types, &final_args),
        };
    }

    fn callRunCudaKernel(
        self: *Generator,
        inputs: union(enum) { float: FloatArrayRef, integer: IntegerArrayRef },
        num_inputs: IntegerRef,
        d_output: DevicePointerRef,
        grid_dims: IntegerArrayRef,
        block_dims: IntegerArrayRef,
    ) !void {
        const void_ptr_type = core.LLVMPointerType(core.LLVMVoidType(), 0);
        var param_types = [_]types.LLVMTypeRef{ void_ptr_type, core.LLVMInt32Type(), void_ptr_type, void_ptr_type, void_ptr_type };
        const inputs_value_ref = switch (inputs) {
            .float => |f| f.value_ref,
            .integer => |i| i.value_ref,
        };

        const input_ptrs_ptr = core.LLVMBuildAlloca(self.builder, core.LLVMPointerType(core.LLVMFloatType(), 0), "input_ptrs_ptr");
        _ = core.LLVMBuildStore(self.builder, inputs_value_ref, input_ptrs_ptr);

        var final_args = [_]types.LLVMValueRef{ input_ptrs_ptr, num_inputs.value_ref, d_output.value_ref, grid_dims.value_ref, block_dims.value_ref };

        _ = try self.callExternalFunction("run_cuda_kernel", core.LLVMInt32Type(), &param_types, &final_args);
    }

    fn callLoadCudaKernel(self: *Generator, ptx_code: StringRef) !void {
        var param_types = [_]types.LLVMTypeRef{core.LLVMPointerType(core.LLVMInt8Type(), 0)};
        var final_args = [_]types.LLVMValueRef{ptx_code.value_ref};

        _ = try self.callExternalFunction("load_cuda_kernel", core.LLVMVoidType(), &param_types, &final_args);
    }

    fn callCuInit(self: *Generator) !void {
        var param_types = [_]types.LLVMTypeRef{core.LLVMInt32Type()};
        var final_args = [_]types.LLVMValueRef{core.LLVMConstInt(core.LLVMInt32Type(), 0, 0)};

        const ret = try self.callExternalFunction("cuInit", core.LLVMInt32Type(), &param_types, &final_args);
        try self.cudaCheckError(ret, 0);
    }

    fn callCuDeviceGet(self: *Generator) !void {
        self.cuda_device = DeviceRef{ .value_ref = core.LLVMBuildAlloca(self.builder, core.LLVMInt32Type(), "device") };
        var param_types = [_]types.LLVMTypeRef{ core.LLVMPointerType(core.LLVMInt32Type(), 0), core.LLVMInt32Type() };
        var final_args = [_]types.LLVMValueRef{ self.cuda_device.?.value_ref, core.LLVMConstInt(core.LLVMInt32Type(), 0, 0) };

        const ret = try self.callExternalFunction("cuDeviceGet", core.LLVMInt32Type(), &param_types, &final_args);
        try self.cudaCheckError(ret, 1);
    }

    fn callCuContextCreate(self: *Generator) !void {
        self.cuda_context = ContextRef{ .value_ref = core.LLVMBuildAlloca(self.builder, core.LLVMInt64Type(), "context") };

        const device_val = core.LLVMBuildLoad2(self.builder, core.LLVMInt32Type(), self.cuda_device.?.value_ref, "load_device");
        var param_types = [_]types.LLVMTypeRef{ core.LLVMPointerType(core.LLVMInt64Type(), 0), core.LLVMInt32Type(), core.LLVMInt32Type() };
        var final_args = [_]types.LLVMValueRef{ self.cuda_context.?.value_ref, core.LLVMConstInt(core.LLVMInt32Type(), 0, 0), device_val };

        const ret = try self.callExternalFunction("cuCtxCreate", core.LLVMInt32Type(), &param_types, &final_args);
        try self.cudaCheckError(ret, 2);
    }

    fn callCuModuleLoadData(self: *Generator) !void {
        self.cuda_module = ModuleRef{ .value_ref = core.LLVMBuildAlloca(self.builder, core.LLVMInt32Type(), "context") };

        const kernel = try self.kernel.toOwnedSlice();
        const kernel_len = kernel.len;
        const kernel_type = core.LLVMArrayType(core.LLVMInt8Type(), @intCast(kernel_len + 1));
        const kernel_constant = core.LLVMConstString(@ptrCast(kernel), @intCast(kernel_len), 0);

        const name_z = try self.allocator.dupeZ(u8, "main");
        defer self.allocator.free(name_z);

        const global_ptx_str = core.LLVMAddGlobal(self.llvm_module, kernel_type, name_z.ptr);
        core.LLVMSetInitializer(global_ptx_str, kernel_constant);

        var param_types = [_]types.LLVMTypeRef{ core.LLVMPointerType(core.LLVMInt32Type(), 0), core.LLVMPointerType(core.LLVMInt32Type(), 0) };
        var final_args = [_]types.LLVMValueRef{ self.cuda_module.?.value_ref, global_ptx_str };

        const ret = try self.callExternalFunction("cuModuleLoadData", core.LLVMInt32Type(), &param_types, &final_args);
        try self.cudaCheckError(ret, 3);
    }

    fn callCuModuleGetFunction(self: *Generator) !void {
        const kernel = ModuleRef{ .value_ref = core.LLVMBuildAlloca(self.builder, core.LLVMInt32Type(), "kernel") };
        // const device_val = core.LLVMBuildLoad2(self.builder, core.LLVMInt32Type(), self.cuda_device.?.value_ref, "load_device");

        var param_types = [_]types.LLVMTypeRef{ core.LLVMPointerType(core.LLVMInt32Type(), 0), core.LLVMInt32Type(), core.LLVMPointerType(core.LLVMInt8Type(), 0) };
        var final_args = [_]types.LLVMValueRef{kernel.value_ref};

        _ = try self.callExternalFunction("cuModuleGetFunction", core.LLVMInt32Type(), &param_types, &final_args);
    }

    // fn callCuMemAlloc(self: *Generator, device_ptr: DevicePointerRef, bytesize: IntegerRef) !void {
    //     const void_ptr_type = core.LLVMPointerType(core.LLVMVoidType(), 0);
    //     var param_types = [_]types.LLVMTypeRef{ void_ptr_type, types.LLVMInt64Type() };
    //     var final_args = [_]types.LLVMValueRef{ device_ptr.value_ref, bytesize.value_ref };
    //     _ = try self.callExternalFunction("cuMemAlloc", core.LLVMInt32Type(), &param_types, &final_args);
    // }

    // fn callCuCopyHToD(self: *Generator, device_ptr: DevicePointerRef, value: NumericArrayRef) !void {
    //     const void_ptr_type = core.LLVMPointerType(core.LLVMVoidType(), 0);
    //     var param_types = [_]types.LLVMTypeRef{ types.LLVMInt64Type(), void_ptr_type, types.LLVMInt64Type() };
    //     var final_args = [_]types.LLVMValueRef{ device_ptr.value_ref, value.getValueRef(), value.getMetadata().length };
    //     _ = try self.callExternalFunction("cuMemcpyHtoD", core.LLVMInt32Type(), &param_types, &final_args);
    // }

    fn callCuCopyDToH(self: *Generator, device_ptr: DevicePointerRef, host_ptr: NumericArrayRef) !void {
        const void_ptr_type = core.LLVMPointerType(core.LLVMVoidType(), 0);
        var param_types = [_]types.LLVMTypeRef{ void_ptr_type, core.LLVMInt64Type(), core.LLVMInt64Type() };
        const length = host_ptr.getMetadata().length;
        const four = core.LLVMConstInt(core.LLVMInt64Type(), 4, 0);
        const size_in_bytes = core.LLVMBuildMul(self.builder, length, four, "size_in_bytes");
        const dereferenced_value = core.LLVMBuildLoad2(self.builder, core.LLVMInt64Type(), device_ptr.value_ref, "dereferenced_device_ptr");
        var final_args = [_]types.LLVMValueRef{ host_ptr.getValueRef(), dereferenced_value, size_in_bytes };
        const ret_val = try self.callExternalFunction("cuMemcpyDtoH", core.LLVMInt32Type(), &param_types, &final_args);
        try self.cudaCheckError(ret_val, 5);
    }

    // fn callCuFree(self: *Generator, device_ptr: DevicePointerRef) !void {
    //     var param_types = [_]types.LLVMTypeRef{types.LLVMInt64Type()};
    //     var final_args = [_]types.LLVMValueRef{device_ptr.value_ref};
    //     _ = try self.callExternalFunction("cuMemFree", core.LLVMInt32Type(), &param_types, &final_args);
    // }

    fn cudaCheckError(self: *Generator, ret_val: types.LLVMValueRef, function: i32) !void {
        try self.initCudaErrorFunction();

        var param_types = [_]types.LLVMTypeRef{ core.LLVMInt32Type(), core.LLVMInt32Type() };
        var args = [_]types.LLVMValueRef{ ret_val, core.LLVMConstInt(core.LLVMInt32Type(), @intCast(function), 0) };
        _ = try self.callExternalFunction("cudaCheckError", core.LLVMInt32Type(), param_types[0..], args[0..] // Arguments
        );
    }

    fn callExternalFunction(self: *Generator, name: []const u8, return_type: types.LLVMTypeRef, param_types: []types.LLVMTypeRef, args: []types.LLVMTypeRef) !types.LLVMValueRef {
        const fn_type = core.LLVMFunctionType(return_type, @ptrCast(@constCast(param_types)), @intCast(param_types.len), 0);
        var fn_val = core.LLVMGetNamedFunction(self.llvm_module, @ptrCast(name));
        if (fn_val == null) {
            fn_val = core.LLVMAddFunction(self.llvm_module, @ptrCast(name), fn_type);
            core.LLVMSetLinkage(fn_val, .LLVMExternalLinkage);
        }

        return core.LLVMBuildCall2(self.builder, fn_type, fn_val, @ptrCast(@constCast(args)), @intCast(args.len), "");
    }

    fn initCudaErrorFunction(self: *Generator) !void {
        if (core.LLVMGetNamedFunction(self.llvm_module, "cudaCheckError") != null) {
            return;
        }

        const saved_block = core.LLVMGetInsertBlock(self.builder);

        var param_types = [_]types.LLVMTypeRef{ core.LLVMInt32Type(), core.LLVMInt32Type() };
        const fn_type = core.LLVMFunctionType(core.LLVMInt32Type(), &param_types, 2, 0);
        const error_fn = core.LLVMAddFunction(self.llvm_module, "cudaCheckError", fn_type);

        const entry = core.LLVMAppendBasicBlock(error_fn, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const ret_val = core.LLVMGetParam(error_fn, 0);
        const fn_val = core.LLVMGetParam(error_fn, 1);
        const zero = core.LLVMConstInt(core.LLVMInt32Type(), 0, 0);
        const cmp = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, ret_val, zero, "cmp");

        const success_block = core.LLVMAppendBasicBlock(error_fn, "success");
        const error_block = core.LLVMAppendBasicBlock(error_fn, "error");
        _ = core.LLVMBuildCondBr(self.builder, cmp, success_block, error_block);

        core.LLVMPositionBuilderAtEnd(self.builder, error_block);
        try self.callPrintCudaError(.{ .value_ref = ret_val }, .{ .value_ref = fn_val });

        const exit_fn_type = core.LLVMFunctionType(core.LLVMVoidType(), @constCast(&[_]types.LLVMTypeRef{core.LLVMInt32Type()}), 1, 0);
        const exit_fn = core.LLVMGetNamedFunction(self.llvm_module, "exit") orelse
            core.LLVMAddFunction(self.llvm_module, "exit", exit_fn_type);

        const exit_code = core.LLVMConstInt(core.LLVMInt32Type(), 1, 0);
        var args = [_]types.LLVMValueRef{exit_code};
        _ = core.LLVMBuildCall2(self.builder, exit_fn_type, exit_fn, &args, 1, "");
        _ = core.LLVMBuildUnreachable(self.builder);

        core.LLVMPositionBuilderAtEnd(self.builder, success_block);
        _ = core.LLVMBuildRet(self.builder, core.LLVMConstInt(core.LLVMInt32Type(), 0, 0));

        core.LLVMPositionBuilderAtEnd(self.builder, saved_block);
    }

    fn addKernel(self: *Generator, ptx: []const u8) !void {
        try self.kernel.appendSlice(ptx);
    }
};
