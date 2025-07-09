const std = @import("std");

const rllvm = @import("rllvm");
const cuda = rllvm.cuda;
const target = rllvm.llvm.target;
const target_machine_mod = rllvm.llvm.target_machine;
const types = rllvm.llvm.types;
const core = rllvm.llvm.core;
const execution = rllvm.llvm.engine;
const debug = rllvm.llvm.debug;

const rir = @import("../rir/rir.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub fn compile(ops: []*rir.RIROP) !types.LLVMModuleRef {
    _ = target.LLVMInitializeNativeTarget();
    _ = target.LLVMInitializeNativeAsmPrinter();
    _ = target.LLVMInitializeNativeAsmParser();

    _ = rllvm.llvm.support.LLVMLoadLibraryPermanently("/run/opengl-driver/lib/libcuda.so");

    const module = core.LLVMModuleCreateWithName("main");

    const di_builder = debug.LLVMCreateDIBuilder(module);
    const di_file = debug.LLVMDIBuilderCreateFile(di_builder, "sb.ryu", 6, ".", 1);
    _ = debug.LLVMDIBuilderCreateCompileUnit(
        di_builder,
        .LLVMDWARFSourceLanguageC,
        di_file,
        "TestCompiler",
        11,
        0,
        "",
        0,
        0,
        "",
        0,
        .LLVMDWARFEmissionFull,
        0,
        0,
        0,
        "",
        0,
        "",
        0,
    );

    const metadata = try calculateMetadata(ops);

    var params = std.ArrayList(*rir.RIROP).init(arena.allocator());
    for (ops) |op| {
        try params.appendSlice(op.findInputs(arena.allocator()));
    }

    var param_types = try arena.allocator().alloc(types.LLVMTypeRef, params.items.len);
    for (0..params.items.len) |i| {
        param_types[i] = core.LLVMPointerType(core.LLVMVoidType(), 0);
    }
    const fn_type = core.LLVMFunctionType(core.LLVMInt32Type(), param_types.ptr, 2, 0);
    const function = core.LLVMAddFunction(module, "main", fn_type);

    const di_subprogram = debug.LLVMDIBuilderCreateFunction(
        di_builder,
        di_file,
        "main",
        4,
        "main",
        4,
        di_file,
        1,
        debug.LLVMDIBuilderCreateSubroutineType(di_builder, null, 0, 0, .LLVMDIFlagZero),
        0,
        1,
        0,
        .LLVMDIFlagZero,
        0,
    );
    debug.LLVMSetSubprogram(function, di_subprogram);

    const entry = core.LLVMAppendBasicBlock(function, "entry");

    const builder = core.LLVMCreateBuilder();
    defer core.LLVMDisposeBuilder(builder);
    core.LLVMPositionBuilderAtEnd(builder, entry);

    try cuda.init(module, builder);
    const cuda_device = try cuda.deviceGet(module, builder);
    const cuda_context = try cuda.contextCreate(module, builder, cuda_device);
    _ = cuda_context;

    // Get the module's context for debug location
    const context = core.LLVMGetModuleContext(module);
    const debug_loc = debug.LLVMDIBuilderCreateDebugLocation(context, 20, 5, di_subprogram, null);
    core.LLVMSetCurrentDebugLocation2(builder, debug_loc);

    var h_params = std.ArrayList(rllvm.types.OpaqueRef).init(arena.allocator());
    var d_params = std.ArrayList(rllvm.types.CudaValueRef).init(arena.allocator());

    for (params.items) |param| {
        const size_bytes = rllvm.types.IntegerRef{ .ref = core.LLVMConstInt(core.LLVMInt64Type(), param.getSizeInBytes(arena.allocator()), 0) };

        switch (param.*) {
            .constant => |constant| {
                const h_input = rllvm.types.OpaqueRef{ .ref = core.LLVMConstIntToPtr(core.LLVMConstInt(core.LLVMInt64Type(), @intFromPtr(&constant.getConstant().i64), 0), core.LLVMPointerType(core.LLVMInt8Type(), 0)) };
                try h_params.append(h_input);

                const d_input = rllvm.types.CudaValueRef.create(builder);
                try d_params.append(d_input);

                try cuda.memAlloc(module, builder, d_input, size_bytes);
                try cuda.copyHToD(module, builder, d_input, h_input, size_bytes);
            },
            else => {
                const h_output = rllvm.types.OpaqueRef{ .ref = core.LLVMConstIntToPtr(core.LLVMConstInt(core.LLVMInt64Type(), 0, 0), core.LLVMPointerType(core.LLVMInt8Type(), 0)) };
                try h_params.append(h_output);

                const d_output = rllvm.types.CudaValueRef.create(builder);
                try d_params.append(d_output);

                try cuda.memAlloc(module, builder, d_output, size_bytes);
            },
        }
    }

    const ptx = try @import("./rhlo/backends/cuda/cuda.zig").genTemp(module);

    // Attach debug metadata to the PTX global
    core.LLVMGlobalSetMetadata(ptx, 0, debug_loc);

    const cuda_module = try cuda.moduleLoadData(module, builder, .{ .ref = ptx });
    const cuda_function = try cuda.moduleGetFunction(module, builder, cuda_module);

    const int_type = core.LLVMInt32Type();
    const grid_dim_x: rllvm.types.IntegerRef = .{ .ref = core.LLVMConstInt(int_type, 1, 0) };
    const grid_dim_y: rllvm.types.IntegerRef = .{ .ref = core.LLVMConstInt(int_type, 1, 0) };
    const grid_dim_z: rllvm.types.IntegerRef = .{ .ref = core.LLVMConstInt(int_type, 1, 0) };
    const block_dim_x: rllvm.types.IntegerRef = metadata.dims.block.x;
    const block_dim_y: rllvm.types.IntegerRef = metadata.dims.block.y;
    const block_dim_z: rllvm.types.IntegerRef = .{ .ref = core.LLVMConstInt(int_type, 1, 0) };
    const shared_mem_bytes: rllvm.types.IntegerRef = .{ .ref = core.LLVMConstInt(int_type, 0, 0) };
    try cuda.launchKernel(module, builder, cuda_function, grid_dim_x, grid_dim_y, grid_dim_z, block_dim_x, block_dim_y, block_dim_z, shared_mem_bytes, d_params.items);

    for (params.items, 0..) |param, idx| {
        switch (param.*) {
            .constant => {},
            else => {
                const size_bytes = rllvm.types.IntegerRef{ .ref = core.LLVMConstInt(core.LLVMInt64Type(), param.getSizeInBytes(arena.allocator()), 0) };
                try cuda.copyDToH(module, builder, d_params.items[idx], h_params.items[idx], size_bytes);
            },
        }
    }

    const zero = core.LLVMConstInt(core.LLVMInt32Type(), 0, 0);

    _ = core.LLVMBuildRet(builder, zero);

    debug.LLVMDIBuilderFinalize(di_builder);
    return module;
}

const KernelData = struct {
    dims: struct {
        block: struct {
            x: rllvm.types.IntegerRef,
            y: rllvm.types.IntegerRef,
            z: rllvm.types.IntegerRef,
        },
    },
};

fn calculateMetadata(ops: []*rir.RIROP) !KernelData {
    const shape = ops[0].*.getShape();

    const int_type = core.LLVMInt32Type();
    return .{
        .dims = .{
            .block = .{
                .x = .{ .ref = core.LLVMConstInt(int_type, shape[0], 0) },
                .y = .{ .ref = core.LLVMConstInt(int_type, if (shape.len > 1) shape[1] else 1, 0) },
                .z = .{ .ref = core.LLVMConstInt(int_type, 1, 0) },
            },
        },
    };
}
