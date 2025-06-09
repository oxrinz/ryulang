const std = @import("std");

const rllvm = @import("rllvm");
const cuda = rllvm.cuda;
const target = rllvm.llvm.target;
const target_machine_mod = rllvm.llvm.target_machine;
const types = rllvm.llvm.types;
const core = rllvm.llvm.core;
const execution = rllvm.llvm.engine;

const nodes = @import("nodes.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub fn execute(program: nodes.RHLOProgram, params: []*void) !void {
    // quick checks
    for (program.tensor_store.items) |tensor| {
        if (tensor.dimensions[0] > 25) @panic("Tensors only of any dim smaller than 5 supported");
    }

    var output_count: i8 = 0;
    for (program.params.items) |param| {
        if (param.output == true) {
            output_count += 1;
        }
        if (output_count >= 2) @panic("Only one output supported");
    }

    // init code
    _ = target.LLVMInitializeNativeTarget();
    _ = target.LLVMInitializeNativeAsmPrinter();
    _ = target.LLVMInitializeNativeAsmParser();

    _ = rllvm.llvm.support.LLVMLoadLibraryPermanently("/run/opengl-driver/lib/libcuda.so");

    const module = core.LLVMModuleCreateWithName("main");

    var param_types: [2]types.LLVMTypeRef = .{
        core.LLVMPointerType(core.LLVMVoidType(), 0),
        core.LLVMPointerType(core.LLVMVoidType(), 0),
    };
    const fn_type = core.LLVMFunctionType(core.LLVMInt32Type(), &param_types, 2, 0);
    const function = core.LLVMAddFunction(module, "main", fn_type);

    const entry = core.LLVMAppendBasicBlock(function, "entry");

    const builder = core.LLVMCreateBuilder();
    defer core.LLVMDisposeBuilder(builder);
    core.LLVMPositionBuilderAtEnd(builder, entry);

    try cuda.init(module, builder);
    const cuda_device = try cuda.deviceGet(module, builder);
    const cuda_context = try cuda.contextCreate(module, builder, cuda_device);
    _ = cuda_context;

    // allocate d and h memory
    var h_inputs = std.ArrayList(rllvm.types.OpaqueRef).init(arena.allocator());
    var d_inputs = std.ArrayList(rllvm.types.CudaValueRef).init(arena.allocator());
    var h_outputs = std.ArrayList(rllvm.types.OpaqueRef).init(arena.allocator());
    var d_outputs = std.ArrayList(rllvm.types.CudaValueRef).init(arena.allocator());
    var output_sizes = std.ArrayList(rllvm.types.IntegerRef).init(arena.allocator());

    for (program.params.items, 0..) |param, idx| {
        var size_elements: usize = 1;
        for (program.tensor_store.items[param.id].dimensions) |dim| {
            size_elements *= dim;
        }
        const size_bytes = rllvm.types.IntegerRef{ .ref = core.LLVMConstInt(core.LLVMInt64Type(), 4 * size_elements, 0) }; // TODO: only works with 32 bit vars, make it work with any

        if (param.input == true) {
            const input = params[idx];
            const h_input = rllvm.types.OpaqueRef{ .ref = core.LLVMConstIntToPtr(core.LLVMConstInt(core.LLVMInt64Type(), @intFromPtr(input), 0), core.LLVMPointerType(core.LLVMInt8Type(), 0)) };
            try h_inputs.append(h_input);

            const d_input = rllvm.types.CudaValueRef.create(builder);
            try d_inputs.append(d_input);

            try cuda.memAlloc(module, builder, d_input, size_bytes);
            try cuda.copyHToD(module, builder, d_input, h_input, size_bytes);
        }

        if (param.output == true) {
            const output = params[idx];
            const h_output = rllvm.types.OpaqueRef{ .ref = core.LLVMConstIntToPtr(core.LLVMConstInt(core.LLVMInt64Type(), @intFromPtr(output), 0), core.LLVMPointerType(core.LLVMInt8Type(), 0)) };
            try h_outputs.append(h_output);

            const d_output = rllvm.types.CudaValueRef.create(builder);
            try d_outputs.append(d_output);

            try output_sizes.append(size_bytes);

            try cuda.memAlloc(module, builder, d_output, size_bytes);
        }
    }

    const output_dims = program.tensor_store.items[program.params.items[program.params.items.len - 1].id].dimensions;

    // gen
    const ptx = try @import("backends/cuda/cuda.zig").generatePTX(module, program);

    const cuda_module = try cuda.moduleLoadData(module, builder, .{ .ref = ptx });
    const cuda_function = try cuda.moduleGetFunction(module, builder, cuda_module);

    const int_type = core.LLVMInt32Type();
    const grid_dim_x: rllvm.types.IntegerRef = .{ .ref = core.LLVMConstInt(int_type, 1, 0) };
    const grid_dim_y: rllvm.types.IntegerRef = .{ .ref = core.LLVMConstInt(int_type, 1, 0) };
    const grid_dim_z: rllvm.types.IntegerRef = .{ .ref = core.LLVMConstInt(int_type, 1, 0) };
    const block_dim_x: rllvm.types.IntegerRef = .{ .ref = core.LLVMConstInt(int_type, output_dims[0], 0) };
    const block_dim_y: rllvm.types.IntegerRef = .{ .ref = core.LLVMConstInt(int_type, output_dims[1], 0) };
    const block_dim_z: rllvm.types.IntegerRef = .{ .ref = core.LLVMConstInt(int_type, 1, 0) };
    const shared_mem_bytes: rllvm.types.IntegerRef = .{ .ref = core.LLVMConstInt(int_type, 0, 0) };
    const kernel_params = try std.mem.concat(arena.allocator(), rllvm.types.CudaValueRef, &[_][]rllvm.types.CudaValueRef{ d_inputs.items, d_outputs.items });
    try cuda.launchKernel(module, builder, cuda_function, grid_dim_x, grid_dim_y, grid_dim_z, block_dim_x, block_dim_y, block_dim_z, shared_mem_bytes, kernel_params);

    // copy results to h
    for (d_outputs.items, 0..) |d_output, idx| {
        try cuda.copyDToH(module, builder, d_output, h_outputs.items[idx], output_sizes.items[idx]);
    }

    const zero = core.LLVMConstInt(core.LLVMInt64Type(), 0, 0);

    _ = core.LLVMBuildRet(builder, zero);

    // execution
    var error_msg: [*c]u8 = null;
    var engine: types.LLVMExecutionEngineRef = undefined;
    if (execution.LLVMCreateExecutionEngineForModule(&engine, module, &error_msg) != 0) {
        std.debug.print("Execution engine creation failed: {s}\n", .{error_msg});
        core.LLVMDisposeMessage(error_msg);
        @panic("failed to create exec engine");
    }
    defer execution.LLVMDisposeExecutionEngine(engine);

    // _ = core.LLVMDumpModule(module);

    const main_addr = execution.LLVMGetFunctionAddress(engine, "main");
    const MainFn = fn () callconv(.C) f32;
    const main_fn: *const MainFn = @ptrFromInt(main_addr);

    _ = main_fn();
}
