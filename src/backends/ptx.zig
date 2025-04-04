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
        };
    }

    pub fn generateKernel(self: *PTXBackend, function_definition: ast.FunctionDefinition) ![]const u8 {
        _ = self;
        _ = function_definition;
        const ptx =
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

        return ptx;
    }
};
