const std = @import("std");

const Generator = @import("../gen.zig").Generator;
const ast = @import("../ast.zig");

const llvm = @import("llvm");
const target = llvm.target;
const target_machine_mod = llvm.target_machine;
const types = llvm.types;
const core = llvm.core;
const process = std.process;
const execution = llvm.engine;

pub const HostBackend = struct {
    allocator: std.mem.Allocator,
    llvm_module: types.LLVMModuleRef = undefined,
    builder: types.LLVMBuilderRef,
    gen: *Generator,

    pub fn init(gen: *Generator, allocator: std.mem.Allocator) HostBackend {
        return .{
            .allocator = allocator,
            .builder = core.LLVMCreateBuilder().?,
            .llvm_module = core.LLVMModuleCreateWithName("main_module"),
            .gen = gen,
        };
    }

    pub fn generate(self: *HostBackend, module: ast.Module) anyerror!types.LLVMModuleRef {
        _ = target.LLVMInitializeNativeTarget();
        _ = target.LLVMInitializeNativeAsmPrinter();
        _ = target.LLVMInitializeNativeAsmParser();

        const main_type: types.LLVMTypeRef = core.LLVMFunctionType(core.LLVMInt32Type(), null, 0, 0);
        const main_func: types.LLVMValueRef = core.LLVMAddFunction(self.llvm_module, "main", main_type);

        const main_entry: types.LLVMBasicBlockRef = core.LLVMAppendBasicBlock(main_func, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, main_entry);

        for (module.block.items) |stmt| {
            try self.gen.generateStatement(stmt);
        }

        const zero = core.LLVMConstInt(core.LLVMInt32Type(), 0, 0);
        _ = core.LLVMBuildRet(self.builder, zero);

        core.LLVMDisposeBuilder(self.builder);

        return self.llvm_module;
    }

    pub fn generateConstant(self: *HostBackend, constant: ast.Value) !types.LLVMValueRef {
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
        }
    }

    pub fn generateCall(self: *HostBackend, call: ast.Call) !types.LLVMValueRef {
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
                arg_values[i] = try self.gen.generateExpression(arg_expr.*, .Host);
            }

            const return_type = core.LLVMInt32Type();
            const fn_type = core.LLVMFunctionType(return_type, null, 0, 0);

            return core.LLVMBuildCall2(self.builder, fn_type, func, &arg_values[0], @intCast(arg_values.len), "");
        }
    }
};
