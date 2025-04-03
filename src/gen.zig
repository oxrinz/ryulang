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

pub const Generator = struct {
    allocator: std.mem.Allocator,
    module: ast.Module,
    llvm_module: types.LLVMModuleRef,
    llvm_context: types.LLVMContextRef,
    builder: types.LLVMBuilderRef,
    named_values: std.StringHashMap(types.LLVMValueRef),
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
            .named_values = std.StringHashMap(types.LLVMValueRef).init(allocator),
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

    fn generateExpression(self: *Generator, expr: ast.Expression) !types.LLVMValueRef {
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

                    const array_type = core.LLVMTypeOf(array);
                    const array_element_count = core.LLVMGetArrayLength(array_type);

                    const input_length = call.args.len;
                    const float_type = core.LLVMFloatType();
                    const float_array_type = core.LLVMArrayType(float_type, array_element_count);
                    const void_ptr_type = core.LLVMPointerType(core.LLVMVoidType(), 0);
                    const void_ptr_ptr_type = core.LLVMPointerType(void_ptr_type, 0);
                    const ptr_array_type = core.LLVMArrayType(void_ptr_type, @intCast(input_length));
                    const a_array_ptr = core.LLVMBuildAlloca(self.builder, float_array_type, "a_data_local".ptr);
                    _ = core.LLVMBuildStore(self.builder, array, a_array_ptr);
                    const input_ptrs_array_ptr = core.LLVMBuildAlloca(self.builder, ptr_array_type, "input_ptrs_local".ptr);
                    const zero = core.LLVMConstInt(core.LLVMInt32Type(), 0, 0);
                    var indices = [_]types.LLVMValueRef{ zero, zero };
                    const ptr0 = core.LLVMBuildGEP2(self.builder, ptr_array_type, input_ptrs_array_ptr, &indices, 2, "ptr0".ptr);
                    const a_ptr = core.LLVMBuildBitCast(self.builder, a_array_ptr, void_ptr_type, "a_ptr".ptr);
                    _ = core.LLVMBuildStore(self.builder, a_ptr, ptr0);
                    const inputs_ptr = core.LLVMBuildBitCast(self.builder, input_ptrs_array_ptr, void_ptr_ptr_type, "inputs_ptr".ptr);
                    return try self.ptx_backend.launchKernel("simple_add", inputs_ptr);
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
                            return core.LLVMBuildCall2(self.builder, fn_type, func, null, 0, "");
                        } else {
                            var arg_values = try self.allocator.alloc(types.LLVMValueRef, call.args.len);
                            defer self.allocator.free(arg_values);

                            for (call.args, 0..) |arg_expr, i| {
                                arg_values[i] = try self.generateExpression(arg_expr.*);
                            }

                            const return_type = core.LLVMInt32Type();
                            const fn_type = core.LLVMFunctionType(return_type, null, 0, 0);

                            return core.LLVMBuildCall2(self.builder, fn_type, func, &arg_values[0], @intCast(arg_values.len), "");
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

    fn generateConstant(self: *Generator, constant: ast.Value) !types.LLVMValueRef {
        switch (constant) {
            .Integer => {
                const i32Type = core.LLVMInt32Type();
                return core.LLVMConstInt(i32Type, @intCast(constant.Integer), 0);
            },
            .Float => {
                const f32Type = core.LLVMFloatType();
                return core.LLVMConstReal(f32Type, constant.Float);
            },
            .String => {
                const string_val = constant.String;
                const null_terminated = try std.fmt.allocPrint(self.allocator, "{s}\x00", .{string_val});
                defer self.allocator.free(null_terminated);
                return core.LLVMBuildGlobalStringPtr(self.builder, @ptrCast(null_terminated), "str_const");
            },
            .Array => {
                if (constant.Array.len == 0) {
                    const default_type = core.LLVMInt32Type();
                    return core.LLVMConstArray(default_type, null, 0);
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
                    element_values[i] = try self.generateConstant(elem);
                }

                return core.LLVMConstArray(element_type, @ptrCast(element_values), @intCast(constant.Array.len));
            },
        }
    }

    fn generateBuiltInFunction(self: *Generator, call: ast.Call) anyerror!types.LLVMValueRef {
        var char_ptr_type = core.LLVMPointerType(core.LLVMInt8Type(), 0);

        // declare runtime functions. find a better way to do this
        var print_fn = core.LLVMGetNamedFunction(self.llvm_module, "print");
        if (print_fn == null) {
            var param_types = [_]types.LLVMTypeRef{char_ptr_type};
            const fn_type = core.LLVMFunctionType(core.LLVMVoidType(), if (param_types.len == 0) null else @ptrCast(&param_types[0]), param_types.len, 0);
            print_fn = core.LLVMAddFunction(self.llvm_module, "print", fn_type);
            core.LLVMSetLinkage(print_fn, .LLVMExternalLinkage);
        }

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

        const arg_value = try self.generateExpression(call.args[0].*);

        const arg_type = core.LLVMTypeOf(arg_value);
        const type_kind = core.LLVMGetTypeKind(arg_type);

        var str_value: types.LLVMValueRef = undefined;

        switch (type_kind) {
            .LLVMIntegerTypeKind => {
                if (core.LLVMGetIntTypeWidth(arg_type) == 1) {
                    var args = [_]types.LLVMValueRef{arg_value};
                    var param_type = core.LLVMInt1Type();
                    const fn_type = core.LLVMFunctionType(char_ptr_type, &param_type, 1, 0);
                    str_value = core.LLVMBuildCall2(self.builder, fn_type, bool_to_string_fn, &args[0], 1, "bool_str");
                } else {
                    var int_value = arg_value;
                    if (core.LLVMGetIntTypeWidth(arg_type) != 32) {
                        int_value = core.LLVMBuildSExt(self.builder, arg_value, core.LLVMInt32Type(), "int_cast");
                    }

                    var args = [_]types.LLVMValueRef{int_value};
                    var param_type = core.LLVMInt1Type();
                    const fn_type = core.LLVMFunctionType(char_ptr_type, &param_type, 1, 0);
                    str_value = core.LLVMBuildCall2(self.builder, fn_type, int_to_string_fn, &args[0], 1, "int_str");
                }
            },
            .LLVMFloatTypeKind, .LLVMDoubleTypeKind => {
                var float_value = arg_value;
                if (type_kind == .LLVMDoubleTypeKind) {
                    float_value = core.LLVMBuildFPTrunc(self.builder, arg_value, core.LLVMFloatType(), "float_cast");
                }

                var args = [_]types.LLVMValueRef{float_value};
                var param_type = core.LLVMInt1Type();
                const fn_type = core.LLVMFunctionType(char_ptr_type, &param_type, 1, 0);
                str_value = core.LLVMBuildCall2(self.builder, fn_type, float_to_string_fn, &args[0], 1, "float_str");
            },
            .LLVMPointerTypeKind => {
                str_value = arg_value;
            },
            else => {
                str_value = core.LLVMBuildGlobalStringPtr(self.builder, "[unsupported type]", "default_str");
            },
        }

        var args = [_]types.LLVMValueRef{str_value};
        const fn_type = core.LLVMFunctionType(core.LLVMVoidType(), &char_ptr_type, 1, 0);
        return core.LLVMBuildCall2(self.builder, fn_type, print_fn, &args[0], 1, "");
    }

    fn generateBinary(self: *Generator, binary: ast.Binary) anyerror!types.LLVMValueRef {
        const left = try self.generateExpression(binary.left.*);
        const right = try self.generateExpression(binary.right.*);

        const left_type = core.LLVMTypeOf(left);
        const left_kind = core.LLVMGetTypeKind(left_type);

        switch (binary.operator) {
            .Add => {
                if (left_kind == .LLVMFloatTypeKind or left_kind == .LLVMDoubleTypeKind) {
                    return core.LLVMBuildFAdd(self.builder, left, right, "");
                } else {
                    return core.LLVMBuildAdd(self.builder, left, right, "");
                }
            },
            .Subtract => {
                if (left_kind == .LLVMFloatTypeKind or left_kind == .LLVMDoubleTypeKind) {
                    return core.LLVMBuildFSub(self.builder, left, right, "");
                } else {
                    return core.LLVMBuildSub(self.builder, left, right, "");
                }
            },
            .Multiply => {
                if (left_kind == .LLVMFloatTypeKind or left_kind == .LLVMDoubleTypeKind) {
                    return core.LLVMBuildFMul(self.builder, left, right, "");
                } else {
                    return core.LLVMBuildMul(self.builder, left, right, "");
                }
            },
            .Divide => {
                if (left_kind == .LLVMFloatTypeKind or left_kind == .LLVMDoubleTypeKind) {
                    return core.LLVMBuildFDiv(self.builder, left, right, "");
                } else {
                    return core.LLVMBuildSDiv(self.builder, left, right, "");
                }
            },
            else => @panic("Operator not implemented yet"),
        }
    }
};
