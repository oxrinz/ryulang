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

const CuFunctionRef = struct {
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
    global_ptx_str: ?types.LLVMValueRef = null,

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

        self.global_ptx_str = core.LLVMAddGlobal(self.llvm_module, core.LLVMPointerType(core.LLVMInt8Type(), 0), "ptx_str");
        try self.initializeCuda();

        for (self.module.block.items) |stmt| {
            try self.generateStatement(stmt);
        }

        const zero = core.LLVMConstInt(core.LLVMInt32Type(), 0, 0);

        const kernel = try self.kernel.toOwnedSlice();
        const kernel_len = kernel.len;
        const kernel_constant = core.LLVMConstString(@ptrCast(kernel), @intCast(kernel_len), 0);

        core.LLVMSetInitializer(self.global_ptx_str.?, kernel_constant);

        _ = core.LLVMBuildRet(self.builder, zero);
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

                    var inputs = [_]NumericArrayRef{.{ .Float = gen_res.FloatArray }};
                    const result = try self.runCudaKernel(&inputs);

                    return .{ .FloatArray = result.Float };
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

    fn runCudaKernel(self: *Generator, inputs: []NumericArrayRef) !void {
        const int_type = core.LLVMInt32Type();

        const input = inputs[0];
        const result_ptr = FloatArrayRef{
            .value_ref = core.LLVMBuildArrayMalloc(self.builder, core.LLVMFloatType(), input.getMetadata().length, "result_ptr"),
            .metadata = input.getMetadata(),
        };

        const function = try self.callCuModuleGetFunction();

        const d_input = DevicePointerRef{ .value_ref = core.LLVMBuildAlloca(self.builder, core.LLVMInt64Type(), "d_input") };
        try self.callCuMemAlloc(d_input, .{ .value_ref = core.LLVMConstInt(core.LLVMInt64Type(), 6, 0) });

        const d_output = DevicePointerRef{ .value_ref = core.LLVMBuildAlloca(self.builder, core.LLVMInt64Type(), "d_output") };
        try self.callCuMemAlloc(d_output, .{ .value_ref = core.LLVMConstInt(core.LLVMInt64Type(), 6, 0) });

        try self.callCuCopyHToD(d_input, .{ .Float = input.Float });

        const grid_dim_x: IntegerRef = .{ .value_ref = core.LLVMConstInt(int_type, 1, 0) };
        const grid_dim_y: IntegerRef = .{ .value_ref = core.LLVMConstInt(int_type, 1, 0) };
        const grid_dim_z: IntegerRef = .{ .value_ref = core.LLVMConstInt(int_type, 1, 0) };
        const block_dim_x: IntegerRef = .{ .value_ref = core.LLVMConstInt(int_type, 6, 0) };
        const block_dim_y: IntegerRef = .{ .value_ref = core.LLVMConstInt(int_type, 1, 0) };
        const block_dim_z: IntegerRef = .{ .value_ref = core.LLVMConstInt(int_type, 1, 0) };
        const shared_mem_bytes: IntegerRef = .{ .value_ref = core.LLVMConstInt(int_type, 0, 0) };
        var kernel_params = [_]DevicePointerRef{ d_input, d_output };
        try self.callCuLaunchKernel(function, grid_dim_x, grid_dim_y, grid_dim_z, block_dim_x, block_dim_y, block_dim_z, shared_mem_bytes, &kernel_params);

        try self.callCuCopyDToH(d_output, .{ .Float = result_ptr });

        const yea = try self.callArrayToString(.{ .Float = result_ptr });
        try self.callPrint(yea);
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
        self.cuda_context = ContextRef{ .value_ref = core.LLVMBuildAlloca(self.builder, core.LLVMInt32Type(), "context") };

        const device_val = core.LLVMBuildLoad2(self.builder, core.LLVMInt32Type(), self.cuda_device.?.value_ref, "load_device");
        var param_types = [_]types.LLVMTypeRef{ core.LLVMPointerType(core.LLVMInt32Type(), 0), core.LLVMInt32Type(), core.LLVMInt32Type() };
        var final_args = [_]types.LLVMValueRef{ self.cuda_context.?.value_ref, core.LLVMConstInt(core.LLVMInt32Type(), 0, 0), device_val };

        const ret = try self.callExternalFunction("cuCtxCreate_v2", core.LLVMInt32Type(), &param_types, &final_args);
        try self.cudaCheckError(ret, 2);
    }

    fn callCuModuleLoadData(self: *Generator) !void {
        self.cuda_module = ModuleRef{ .value_ref = core.LLVMBuildAlloca(self.builder, core.LLVMInt32Type(), "module") };

        var param_types = [_]types.LLVMTypeRef{ core.LLVMPointerType(core.LLVMInt32Type(), 0), core.LLVMPointerType(core.LLVMInt32Type(), 0) };
        var final_args = [_]types.LLVMValueRef{ self.cuda_module.?.value_ref, self.global_ptx_str.? };

        const ret = try self.callExternalFunction("cuModuleLoadData", core.LLVMInt32Type(), &param_types, &final_args);
        try self.cudaCheckError(ret, 3);
    }

    fn callCuModuleGetFunction(self: *Generator) !CuFunctionRef {
        const kernel = CuFunctionRef{ .value_ref = core.LLVMBuildAlloca(self.builder, core.LLVMInt32Type(), "kernel") };
        const module = core.LLVMBuildLoad2(self.builder, core.LLVMInt32Type(), self.cuda_module.?.value_ref, "load_module");
        const kernel_name = core.LLVMBuildGlobalStringPtr(self.builder, "main", "kernel_name");

        var param_types = [_]types.LLVMTypeRef{ core.LLVMPointerType(core.LLVMInt32Type(), 0), core.LLVMInt32Type(), core.LLVMPointerType(core.LLVMInt8Type(), 0) };
        var final_args = [_]types.LLVMValueRef{ kernel.value_ref, module, kernel_name };

        const ret = try self.callExternalFunction("cuModuleGetFunction", core.LLVMInt32Type(), &param_types, &final_args);
        try self.cudaCheckError(ret, 8);

        return kernel;
    }

    fn callCuMemAlloc(self: *Generator, device_ptr: DevicePointerRef, bytesize: IntegerRef) !void {
        const void_ptr_type = core.LLVMPointerType(core.LLVMVoidType(), 0);
        var param_types = [_]types.LLVMTypeRef{ void_ptr_type, core.LLVMInt64Type() };
        const length = bytesize.value_ref;
        const four = core.LLVMConstInt(core.LLVMInt64Type(), 4, 0);
        const size_in_bytes = core.LLVMBuildMul(self.builder, length, four, "size_in_bytes");
        var final_args = [_]types.LLVMValueRef{ device_ptr.value_ref, size_in_bytes };
        const ret = try self.callExternalFunction("cuMemAlloc_v2", core.LLVMInt32Type(), &param_types, &final_args);
        try self.cudaCheckError(ret, 4);
    }

    fn callCuCopyHToD(self: *Generator, device_ptr: DevicePointerRef, host_ptr: NumericArrayRef) !void {
        const void_ptr_type = core.LLVMPointerType(core.LLVMVoidType(), 0);
        const length = host_ptr.getMetadata().length;
        const four = core.LLVMConstInt(core.LLVMInt64Type(), 4, 0);
        const size_in_bytes = core.LLVMBuildMul(self.builder, length, four, "size_in_bytes");
        var param_types = [_]types.LLVMTypeRef{ core.LLVMInt64Type(), void_ptr_type, core.LLVMInt64Type() };
        const dereferenced_value = core.LLVMBuildLoad2(self.builder, core.LLVMInt64Type(), device_ptr.value_ref, "dereferenced_device_ptr");
        var final_args = [_]types.LLVMValueRef{ dereferenced_value, host_ptr.getValueRef(), size_in_bytes };
        const ret = try self.callExternalFunction("cuMemcpyHtoD_v2", core.LLVMInt32Type(), &param_types, &final_args);
        try self.cudaCheckError(ret, 5);
    }

    fn callCuCopyDToH(self: *Generator, device_ptr: DevicePointerRef, host_ptr: NumericArrayRef) !void {
        const void_ptr_type = core.LLVMPointerType(core.LLVMVoidType(), 0);
        var param_types = [_]types.LLVMTypeRef{ void_ptr_type, core.LLVMInt64Type(), core.LLVMInt64Type() };
        const length = host_ptr.getMetadata().length;
        const four = core.LLVMConstInt(core.LLVMInt64Type(), 4, 0);
        const size_in_bytes = core.LLVMBuildMul(self.builder, length, four, "size_in_bytes");
        const dereferenced_value = core.LLVMBuildLoad2(self.builder, core.LLVMInt64Type(), device_ptr.value_ref, "dereferenced_device_ptr");
        var final_args = [_]types.LLVMValueRef{ host_ptr.getValueRef(), dereferenced_value, size_in_bytes };
        const ret_val = try self.callExternalFunction("cuMemcpyDtoH_v2", core.LLVMInt32Type(), &param_types, &final_args);
        try self.cudaCheckError(ret_val, 6);
    }

    // fn callCuFree(self: *Generator, device_ptr: DevicePointerRef) !void {
    //     var param_types = [_]types.LLVMTypeRef{types.LLVMInt64Type()};
    //     var final_args = [_]types.LLVMValueRef{device_ptr.value_ref};
    //     _ = try self.callExternalFunction("cuMemFree", core.LLVMInt32Type(), &param_types, &final_args);
    // }

    fn callCuLaunchKernel(
        self: *Generator,
        function: CuFunctionRef,
        grid_dim_x: IntegerRef,
        grid_dim_y: IntegerRef,
        grid_dim_z: IntegerRef,
        block_dim_x: IntegerRef,
        block_dim_y: IntegerRef,
        block_dim_z: IntegerRef,
        shared_mem_bytes: IntegerRef,
        kernel_params: []DevicePointerRef,
    ) !void {
        const void_ptr_type = core.LLVMPointerType(core.LLVMVoidType(), 0);
        const int_type = core.LLVMInt32Type();

        const function_val = core.LLVMBuildLoad2(self.builder, int_type, function.value_ref, "function_val");
        const grid_dim_x_val = grid_dim_x.value_ref;
        const grid_dim_y_val = grid_dim_y.value_ref;
        const grid_dim_z_val = grid_dim_z.value_ref;
        const block_dim_x_val = block_dim_x.value_ref;
        const block_dim_y_val = block_dim_y.value_ref;
        const block_dim_z_val = block_dim_z.value_ref;
        const shared_mem_bytes_val = shared_mem_bytes.value_ref;

        const array_type = core.LLVMArrayType(core.LLVMPointerType(core.LLVMInt64Type(), 0), @intCast(1));
        const kernel_params_ptr = core.LLVMBuildAlloca(self.builder, array_type, "kernel_params_array");

        // _ = core.LLVMBuildStore(self.builder, kernel_params[0].value_ref, kernel_params_ptr);

        for (kernel_params, 0..) |value, idx| {
            var indices = [2]types.LLVMValueRef{
                core.LLVMConstInt(core.LLVMInt64Type(), 0, 0),
                core.LLVMConstInt(core.LLVMInt64Type(), idx, 0),
            };

            const element_ptr = core.LLVMBuildGEP2(self.builder, core.LLVMArrayType(core.LLVMInt64Type(), @intCast(kernel_params.len)), kernel_params_ptr, &indices, 2, "element_ptr");

            _ = core.LLVMBuildStore(self.builder, value.value_ref, element_ptr);
        }

        var param_types = [_]types.LLVMTypeRef{
            core.LLVMInt32Type(),
            core.LLVMInt32Type(),
            core.LLVMInt32Type(),
            core.LLVMInt32Type(),
            core.LLVMInt32Type(),
            core.LLVMInt32Type(),
            core.LLVMInt32Type(),
            core.LLVMInt32Type(),
            core.LLVMInt32Type(),
            void_ptr_type,
            void_ptr_type,
        };
        var args = [_]types.LLVMValueRef{
            function_val, // function
            grid_dim_x_val, // gridDimX
            grid_dim_y_val, // gridDimY
            grid_dim_z_val, // gridDimZ
            block_dim_x_val, // blockDimX
            block_dim_y_val, // blockDimY
            block_dim_z_val, // blockDimZ
            shared_mem_bytes_val, // sharedMemBytes
            core.LLVMConstInt(core.LLVMInt32Type(), 0, 0), // stream (0)
            kernel_params_ptr, // kernelParams
            core.LLVMConstNull(void_ptr_type), // extra (null)
        };
        const ret_val = try self.callExternalFunction("cuLaunchKernel", core.LLVMInt32Type(), &param_types, &args);
        try self.cudaCheckError(ret_val, 7);
    }

    fn cudaCheckError(self: *Generator, ret_val: types.LLVMValueRef, function: i32) !void {
        try self.initCudaErrorFunction();

        var param_types = [_]types.LLVMTypeRef{ core.LLVMInt32Type(), core.LLVMInt32Type() };
        var args = [_]types.LLVMValueRef{ ret_val, core.LLVMConstInt(core.LLVMInt32Type(), @intCast(function), 0) };
        _ = try self.callExternalFunction("cudaCheckError", core.LLVMInt32Type(), param_types[0..], args[0..]);
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
