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

const GenArrayType = struct {
    type: *GenType,
    length: usize,
};

const GenType = union(ast.ValueType) {
    Integer,
    Float,
    String,
    Array: GenArrayType,
};

const TypedValueRef = struct {
    value_ref: types.LLVMValueRef,
    type: GenType,
};

pub const Generator = struct {
    allocator: std.mem.Allocator,
    module: ast.Module,
    llvm_module: types.LLVMModuleRef,
    llvm_context: types.LLVMContextRef,
    builder: types.LLVMBuilderRef,
    named_values: std.StringHashMap(TypedValueRef),
    ptx_backend: PTXBackend,

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
        };

        gen.ptx_backend = PTXBackend.init(allocator, &gen);

        return gen;
    }

    pub fn generate(self: *Generator) anyerror!types.LLVMModuleRef {
        for (self.module.block.items) |stmt| {
            try self.generateStatement(stmt);
        }

        const zero = core.LLVMConstInt(core.LLVMInt32Type(), 0, 0);
        _ = core.LLVMBuildRet(self.builder, zero);

        core.LLVMDisposeBuilder(self.builder);

        return self.llvm_module;
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
                    const sample_ptx =
                        \\//
                        \\.version 7.5
                        \\.target sm_75
                        \\.address_size 64
                        \\
                        \\.visible .entry main(
                        \\    .param .u64 input_ptr,
                        \\    .param .u64 output_ptr,
                        \\    .param .u32 n
                        \\)
                        \\{
                        \\    .reg .b32       r<5>;
                        \\    .reg .b64       rd<5>;
                        \\    .reg .f32       f<3>;
                        \\    .reg .pred      p<2>;
                        \\
                        \\    // Get the thread ID
                        \\    ld.param.u64    rd1, [input_ptr];
                        \\    ld.param.u64    rd2, [output_ptr];
                        \\    ld.param.u32    r1, [n];
                        \\    
                        \\    // Calculate thread ID
                        \\    mov.u32         r2, %tid.x;
                        \\    mov.u32         r3, %ntid.x;
                        \\    mov.u32         r4, %ctaid.x;
                        \\    mad.lo.u32      r2, r4, r3, r2;
                        \\    
                        \\    // Check if thread ID is within bounds
                        \\    setp.ge.u32     p1, r2, r1;
                        \\    @p1 bra         EXIT;
                        \\    
                        \\    // Calculate input and output addresses
                        \\    cvt.u64.u32     rd3, r2;
                        \\    mul.wide.u32    rd3, r2, 4;      // 4 bytes per float
                        \\    add.u64         rd1, rd1, rd3;   // input_ptr + offset
                        \\    add.u64         rd2, rd2, rd3;   // output_ptr + offset
                        \\    
                        \\    // Load input value
                        \\    ld.global.f32   f1, [rd1];
                        \\    
                        \\    // Add constant 2.0 to the value
                        \\    mov.f32         f2, 0f40000000;  // 2.0 in hex floating point
                        \\    add.f32         f1, f1, f2;
                        \\    
                        \\    // Store result to output
                        \\    st.global.f32   [rd2], f1;
                        \\    
                        \\EXIT:
                        \\    ret;
                        \\}
                    ;

                    try self.ptx_backend.addKernel("simple_add", sample_ptx);
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

                    const array_element_count = array.type.Array.length;

                    const input_length = call.args.len;

                    const float_type = core.LLVMFloatType();
                    const float_array_type = core.LLVMArrayType(float_type, @intCast(array_element_count));
                    const void_ptr_type = core.LLVMPointerType(core.LLVMVoidType(), 0);
                    const void_ptr_ptr_type = core.LLVMPointerType(void_ptr_type, 0);
                    const ptr_array_type = core.LLVMArrayType(void_ptr_type, @intCast(input_length));

                    const a_array_ptr = core.LLVMBuildAlloca(self.builder, float_array_type, "a_data_local".ptr);
                    _ = core.LLVMBuildStore(self.builder, array.value_ref, a_array_ptr);
                    const input_ptrs_array_ptr = core.LLVMBuildAlloca(self.builder, ptr_array_type, "input_ptrs_local".ptr);
                    const zero = core.LLVMConstInt(core.LLVMInt32Type(), 0, 0);
                    var indices = [_]types.LLVMValueRef{ zero, zero };
                    const ptr0 = core.LLVMBuildGEP2(self.builder, ptr_array_type, input_ptrs_array_ptr, &indices, 2, "ptr0".ptr);
                    const a_ptr = core.LLVMBuildBitCast(self.builder, a_array_ptr, void_ptr_type, "a_ptr".ptr);
                    _ = core.LLVMBuildStore(self.builder, a_ptr, ptr0);
                    const inputs_ptr = core.LLVMBuildBitCast(self.builder, input_ptrs_array_ptr, void_ptr_ptr_type, "inputs_ptr".ptr);

                    const result_array = core.LLVMBuildAlloca(self.builder, float_array_type, "result_data".ptr);
                    const zero_initializer = core.LLVMConstNull(float_array_type);
                    core.LLVMSetInitializer(result_array, zero_initializer);
                    const result_ptr = core.LLVMBuildBitCast(self.builder, result_array, void_ptr_type, "result_ptr".ptr);

                    _ = try self.ptx_backend.launchKernel("simple_add", inputs_ptr, result_ptr);

                    var gen_type: GenType = .Float;

                    const gen_array_type = GenArrayType{
                        .type = &gen_type,
                        .length = array_element_count,
                    };

                    return TypedValueRef{
                        .type = .{ .Array = gen_array_type },
                        .value_ref = result_array,
                    };
                } else {
                    if (call.builtin == true) {
                        return try self.generateBuiltInFunction(call);
                    } else {
                        const c_name = try self.allocator.dupeZ(u8, call.identifier);
                        defer self.allocator.free(c_name);

                        const func = core.LLVMGetNamedFunction(self.llvm_module, c_name);
                        if (func == null) {
                            @panic("Undefined function");
                        }

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
                return TypedValueRef{
                    .type = .String,
                    .value_ref = core.LLVMConstString(@ptrCast(null_terminated), @intCast(null_terminated.len), 1),
                };
            },
            .Array => {
                if (constant.Array.len == 0) {
                    @panic("empty array");
                }

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

                var gen_type: GenType = switch (first_elem) {
                    .Float => .Float,
                    .Integer => .Integer,
                    .String => .String,
                    else => unreachable,
                };
                const array_type = GenArrayType{
                    .type = &gen_type,
                    .length = constant.Array.len,
                };

                return TypedValueRef{
                    .type = .{
                        .Array = array_type,
                    },
                    .value_ref = core.LLVMConstArray(element_type, @ptrCast(element_values), @intCast(constant.Array.len)),
                };
            },
        }
    }

    fn getOrCreateExternalFunction(self: *Generator, name: []const u8, fn_type: types.LLVMTypeRef) types.LLVMValueRef {
        var fn_val = core.LLVMGetNamedFunction(self.llvm_module, @ptrCast(name));
        if (fn_val == null) {
            fn_val = core.LLVMAddFunction(self.llvm_module, @ptrCast(name), fn_type);
            core.LLVMSetLinkage(fn_val, .LLVMExternalLinkage);
        }
        return fn_val;
    }

    fn getLLVMTypeForGenType(self: *Generator, gen_type: GenType) types.LLVMTypeRef {
        return switch (gen_type) {
            .Integer => core.LLVMInt32Type(),
            .Float => core.LLVMFloatType(),
            .String => core.LLVMPointerType(core.LLVMInt8Type(), 0),
            .Array => |array_type| {
                const elem_type = self.getLLVMTypeForGenType(array_type.type.*);
                return core.LLVMArrayType(elem_type, @intCast(array_type.length));
            },
        };
    }

    fn generateBuiltInFunction(self: *Generator, call: ast.Call) anyerror!TypedValueRef {
        var char_ptr_type = core.LLVMPointerType(core.LLVMInt8Type(), 0);

        var print_param_types = [_]types.LLVMTypeRef{char_ptr_type};
        const print_fn_type = core.LLVMFunctionType(core.LLVMVoidType(), @ptrCast(&print_param_types[0]), print_param_types.len, 0);
        const print_fn = self.getOrCreateExternalFunction("print", print_fn_type);

        var int_to_string_fn = core.LLVMGetNamedFunction(self.llvm_module, "int_to_string");
        if (int_to_string_fn == null) {
            var param_types = [_]types.LLVMTypeRef{core.LLVMInt32Type()};
            const fn_type = core.LLVMFunctionType(char_ptr_type, if (param_types.len == 0) null else @ptrCast(&param_types[0]), param_types.len, 0);
            int_to_string_fn = core.LLVMAddFunction(self.llvm_module, "int_to_string", fn_type);
            core.LLVMSetLinkage(int_to_string_fn, .LLVMExternalLinkage);
        }

        var float_to_string_fn = core.LLVMGetNamedFunction(self.llvm_module, "float_to_string");
        if (float_to_string_fn == null) {
            var param_types = [_]types.LLVMTypeRef{core.LLVMFloatType()};
            const fn_type = core.LLVMFunctionType(char_ptr_type, if (param_types.len == 0) null else @ptrCast(&param_types[0]), param_types.len, 0);
            float_to_string_fn = core.LLVMAddFunction(self.llvm_module, "float_to_string", fn_type);
            core.LLVMSetLinkage(float_to_string_fn, .LLVMExternalLinkage);
        }

        var bool_to_string_fn = core.LLVMGetNamedFunction(self.llvm_module, "bool_to_string");
        if (bool_to_string_fn == null) {
            var param_types = [_]types.LLVMTypeRef{core.LLVMInt1Type()};
            const fn_type = core.LLVMFunctionType(char_ptr_type, if (param_types.len == 0) null else @ptrCast(&param_types[0]), param_types.len, 0);
            bool_to_string_fn = core.LLVMAddFunction(self.llvm_module, "bool_to_string", fn_type);
            core.LLVMSetLinkage(bool_to_string_fn, .LLVMExternalLinkage);
        }

        var arr_to_string_param_types = [_]types.LLVMTypeRef{
            core.LLVMPointerType(core.LLVMVoidType(), 0),
            core.LLVMInt32Type(),
            core.LLVMInt32Type(),
        };
        const arr_to_string_fn_type = core.LLVMFunctionType(char_ptr_type, @ptrCast(&arr_to_string_param_types[0]), arr_to_string_param_types.len, 0);
        const arr_to_string_fn = self.getOrCreateExternalFunction("array_to_string", arr_to_string_fn_type);

        const arg_value = try self.generateExpression(call.args[0].*);

        var str_value: types.LLVMValueRef = undefined;

        switch (arg_value.type) {
            .Integer => {
                const int_value = arg_value.value_ref;

                var args = [_]types.LLVMValueRef{int_value};
                var param_type = core.LLVMInt1Type();
                const fn_type = core.LLVMFunctionType(char_ptr_type, &param_type, 1, 0);
                str_value = core.LLVMBuildCall2(self.builder, fn_type, int_to_string_fn, &args[0], 1, "int_str");
            },
            .Float => {
                const float_value = arg_value.value_ref;

                var args = [_]types.LLVMValueRef{float_value};
                var param_type = core.LLVMInt1Type();
                const fn_type = core.LLVMFunctionType(char_ptr_type, &param_type, 1, 0);
                str_value = core.LLVMBuildCall2(self.builder, fn_type, float_to_string_fn, &args[0], 1, "float_str");
            },
            .Array => {
                const length_val = core.LLVMConstInt(core.LLVMInt32Type(), arg_value.type.Array.length, 0);
                const type_val = core.LLVMConstInt(core.LLVMInt32Type(), 1, 0); // 1 represents Float type

                var args = [_]types.LLVMValueRef{ arg_value.value_ref, length_val, type_val };
                str_value = core.LLVMBuildCall2(self.builder, arr_to_string_fn_type, arr_to_string_fn, &args, 3, "float_str");
            },
            else => unreachable,
        }

        var args = [_]types.LLVMValueRef{str_value};
        const fn_type = core.LLVMFunctionType(core.LLVMVoidType(), &char_ptr_type, 1, 0);
        return TypedValueRef{
            .type = .Float,
            .value_ref = core.LLVMBuildCall2(self.builder, fn_type, print_fn, &args[0], 1, ""),
        };
    }

    const BuildFn = fn (types.LLVMBuilderRef, types.LLVMValueRef, types.LLVMValueRef, [*:0]const u8) callconv(.C) types.LLVMValueRef;
    fn dispatchOp(self: *Generator, left: TypedValueRef, right: TypedValueRef, float_fn: BuildFn, int_fn: BuildFn) TypedValueRef {
        if (@intFromEnum(left.type) != @intFromEnum(right.type)) @panic("both operands must be same type");
        const is_float = left.type == .Float;
        if (is_float) {
            return TypedValueRef{
                .type = .Float,
                .value_ref = float_fn(self.builder, left.value_ref, right.value_ref, ""),
            };
        } else {
            return TypedValueRef{
                .type = .Integer,
                .value_ref = int_fn(self.builder, left.value_ref, right.value_ref, ""),
            };
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
};
