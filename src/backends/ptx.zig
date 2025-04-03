const std = @import("std");

const Generator = @import("../gen.zig").Generator;

const llvm = @import("llvm");
const target = llvm.target;
const target_machine_mod = llvm.target_machine;
const types = llvm.types;
const core = llvm.core;
const process = std.process;
const execution = llvm.engine;

const ast = @import("../ast.zig");

pub const PTXBackend = struct {
    allocator: std.mem.Allocator,
    llvm_module: types.LLVMModuleRef,
    builder: types.LLVMBuilderRef,
    kernels: std.StringHashMap(types.LLVMValueRef),

    // declare the cuda api functions
    pub fn init(allocator: std.mem.Allocator, gen: *Generator) PTXBackend {
        const i8Type = core.LLVMInt8Type();
        const i32Type = core.LLVMInt32Type();
        const i64Type = core.LLVMInt64Type();
        const i8PtrType = core.LLVMPointerType(i8Type, 0);

        // cuInit
        var cuInitParamTypes = [_]types.LLVMTypeRef{i32Type};
        const cuInitFnType = core.LLVMFunctionType(i32Type, &cuInitParamTypes, 1, 0);
        const cuInit = core.LLVMAddFunction(gen.*.llvm_module, "cuInit", cuInitFnType);
        core.LLVMSetLinkage(cuInit, .LLVMExternalLinkage);

        // cuDeviceGet
        const i32PtrType = core.LLVMPointerType(i32Type, 0);
        var cuDeviceGetParamTypes = [_]types.LLVMTypeRef{ i32PtrType, i32Type };
        const cuDeviceGetFnType = core.LLVMFunctionType(i32Type, &cuDeviceGetParamTypes, 2, 0);
        const cuDeviceGet = core.LLVMAddFunction(gen.*.llvm_module, "cuDeviceGet", cuDeviceGetFnType);
        core.LLVMSetLinkage(cuDeviceGet, .LLVMExternalLinkage);

        // cuCtxCreate
        const i64PtrType = core.LLVMPointerType(i64Type, 0);
        var cuCtxCreateParamTypes = [_]types.LLVMTypeRef{ i64PtrType, i32Type, i32Type };
        const cuCtxCreateFnType = core.LLVMFunctionType(i32Type, &cuCtxCreateParamTypes, 3, 0);
        const cuCtxCreate = core.LLVMAddFunction(gen.*.llvm_module, "cuCtxCreate_v2", cuCtxCreateFnType);
        core.LLVMSetLinkage(cuCtxCreate, .LLVMExternalLinkage);

        // cuModuleLoadData
        var cuModuleLoadDataParamTypes = [_]types.LLVMTypeRef{ i64PtrType, i8PtrType };
        const cuModuleLoadDataFnType = core.LLVMFunctionType(i32Type, &cuModuleLoadDataParamTypes, 2, 0);
        const cuModuleLoadData = core.LLVMAddFunction(gen.*.llvm_module, "cuModuleLoadData", cuModuleLoadDataFnType);
        core.LLVMSetLinkage(cuModuleLoadData, .LLVMExternalLinkage);

        // cuModuleGetFunction
        var cuModuleGetFunctionParamTypes = [_]types.LLVMTypeRef{ i64PtrType, i64Type, i8PtrType };
        const cuModuleGetFunctionFnType = core.LLVMFunctionType(i32Type, &cuModuleGetFunctionParamTypes, 3, 0);
        const cuModuleGetFunction = core.LLVMAddFunction(gen.*.llvm_module, "cuModuleGetFunction", cuModuleGetFunctionFnType);
        core.LLVMSetLinkage(cuModuleGetFunction, .LLVMExternalLinkage);

        // cuLaunchKernel
        var cuLaunchKernelParamTypes = [_]types.LLVMTypeRef{ i64Type, i32Type, i32Type, i32Type, i32Type, i32Type, i32Type, i32Type, i64Type, i8PtrType, i8PtrType };
        const cuLaunchKernelFnType = core.LLVMFunctionType(i32Type, &cuLaunchKernelParamTypes, 11, 0);
        const cuLaunchKernel = core.LLVMAddFunction(gen.*.llvm_module, "cuLaunchKernel", cuLaunchKernelFnType);
        core.LLVMSetLinkage(cuLaunchKernel, .LLVMExternalLinkage);

        const deviceGlobal = core.LLVMAddGlobal(gen.*.llvm_module, i32Type, "cuda_device");
        const contextGlobal = core.LLVMAddGlobal(gen.*.llvm_module, i64Type, "cuda_context");
        const moduleGlobal = core.LLVMAddGlobal(gen.*.llvm_module, i64Type, "cuda_module");

        const zeroI32 = core.LLVMConstInt(i32Type, 0, 0);
        const zeroI64 = core.LLVMConstInt(i64Type, 0, 0);
        core.LLVMSetInitializer(deviceGlobal, zeroI32);
        core.LLVMSetInitializer(contextGlobal, zeroI64);
        core.LLVMSetInitializer(moduleGlobal, zeroI64);

        return .{
            .allocator = allocator,
            .llvm_module = gen.*.llvm_module,
            .builder = gen.*.builder,
            .kernels = std.StringHashMap(types.LLVMValueRef).init(allocator),
        };
    }

    pub fn addKernel(self: *PTXBackend, name: []const u8, ptx: []const u8) !void {
        const kernel_name = ptx;
        const kernel_name_len = kernel_name.len;
        const kernel_name_type = core.LLVMArrayType(core.LLVMInt8Type(), @intCast(kernel_name_len + 1));
        const kernel_name_constant = core.LLVMConstString(@ptrCast(kernel_name), @intCast(kernel_name_len), 0);

        const name_z = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(name_z);

        const global_ptx_str = core.LLVMAddGlobal(self.llvm_module, kernel_name_type, name_z.ptr);
        try self.kernels.put(name, global_ptx_str);
        core.LLVMSetInitializer(global_ptx_str, kernel_name_constant);
    }

    pub fn launchKernel(self: *PTXBackend, name: []const u8, inputs: types.LLVMValueRef) !types.LLVMValueRef {
        const global_ptx_str = self.kernels.get(name).?;

        const char_type = core.LLVMInt8Type();
        const char_ptr_type = core.LLVMPointerType(char_type, 0);
        const void_ptr_type = core.LLVMPointerType(core.LLVMVoidType(), 0);

        const return_type = core.LLVMInt32Type();
        var param_types = [_]types.LLVMTypeRef{
            char_ptr_type,
            char_ptr_type,
            void_ptr_type,
            void_ptr_type,
            void_ptr_type,
            core.LLVMInt32Type(),
        };

        const fn_type = core.LLVMFunctionType(return_type, &param_types, param_types.len, 0);

        var run_cuda_kernel_fn = core.LLVMGetNamedFunction(self.llvm_module, "run_cuda_kernel");
        if (run_cuda_kernel_fn == null) {
            run_cuda_kernel_fn = core.LLVMAddFunction(self.llvm_module, "run_cuda_kernel", fn_type);
        }

        const int_type = core.LLVMInt32Type();
        const float_type = core.LLVMFloatType();
        const float_array_type = core.LLVMArrayType(float_type, 4);

        const result_array = core.LLVMAddGlobal(self.llvm_module, float_array_type, "result_data".ptr);
        var result_values: [4]types.LLVMValueRef = undefined;

        const n_val = core.LLVMConstInt(int_type, 4, 0);

        for (0..4) |i| {
            result_values[i] = core.LLVMConstReal(float_type, 0.0);
        }

        const result_constant_array = core.LLVMConstArray(float_type, &result_values, 4);
        core.LLVMSetInitializer(result_array, result_constant_array);

        const result_ptr = core.LLVMBuildBitCast(self.builder, result_array, void_ptr_type, "result_ptr".ptr);

        var args = [_]types.LLVMValueRef{
            core.LLVMBuildBitCast(self.builder, global_ptx_str, char_ptr_type, "ptx_code_ptr".ptr),
            inputs,
            result_ptr,
            n_val,
        };

        return core.LLVMBuildCall2(self.builder, fn_type, run_cuda_kernel_fn, &args, args.len, "cuda_call".ptr);
    }
};
