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

const ptxast = @import("nvidia/ast.zig");
const nodes = @import("nvidia/nodes.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub fn compile(module: types.LLVMModuleRef, builder: types.LLVMBuilderRef, params: []*rir.RIROP) !types.LLVMModuleRef {
    const metadata = try calculateMetadata(params);

    try cuda.init(module, builder);
    const cuda_device = try cuda.deviceGet(module, builder);
    const cuda_context = try cuda.contextCreate(module, builder, cuda_device);
    _ = cuda_context;

    var h_params = std.ArrayList(types.LLVMValueRef).init(arena.allocator());
    var d_params = std.ArrayList(types.LLVMValueRef).init(arena.allocator());
    var output_indices = std.ArrayList(usize).init(arena.allocator());

    for (params, 0..) |param, idx| {
        const size_bytes = core.LLVMConstInt(core.LLVMInt64Type(), 4, 0);

        switch (param.*) {
            .constant => |constant| {
                const h_input_memory = core.LLVMBuildAlloca(builder, core.LLVMFloatType(), "h_input_memory");
                const input_value = core.LLVMConstReal(core.LLVMFloatType(), @floatFromInt(constant.getConstant().i64[0]));
                _ = core.LLVMBuildStore(builder, input_value, h_input_memory);
                try h_params.append(h_input_memory);

                const d_input = core.LLVMBuildAlloca(builder, core.LLVMInt64Type(), "d_input");
                try d_params.append(d_input);

                try cuda.memAlloc(module, builder, d_input, size_bytes);
                try cuda.copyHToD(module, builder, d_input, h_input_memory, size_bytes);
            },
            else => {
                const h_output_memory = core.LLVMBuildAlloca(builder, core.LLVMFloatType(), "h_output_memory");
                const zero_value = core.LLVMConstReal(core.LLVMFloatType(), 0.0);
                _ = core.LLVMBuildStore(builder, zero_value, h_output_memory);
                try h_params.append(h_output_memory);
                try output_indices.append(idx);

                const d_output = core.LLVMBuildAlloca(builder, core.LLVMInt64Type(), "d_output");
                try d_params.append(d_output);

                try cuda.memAlloc(module, builder, d_output, size_bytes);
            },
        }
    }

    const ptx = try genReturnFirstParam(module);

    const cuda_module = try cuda.moduleLoadData(module, builder, ptx);
    const cuda_function = try cuda.moduleGetFunction(module, builder, cuda_module);

    const int_type = core.LLVMInt32Type();
    const grid_dim_x = core.LLVMConstInt(int_type, 1, 0);
    const grid_dim_y = core.LLVMConstInt(int_type, 1, 0);
    const grid_dim_z = core.LLVMConstInt(int_type, 1, 0);
    const block_dim_x = metadata.dims.block.x;
    const block_dim_y = metadata.dims.block.y;
    const block_dim_z = core.LLVMConstInt(int_type, 1, 0);
    const shared_mem_bytes = core.LLVMConstInt(int_type, 0, 0);
    try cuda.launchKernel(module, builder, cuda_function, grid_dim_x, grid_dim_y, grid_dim_z, block_dim_x, block_dim_y, block_dim_z, shared_mem_bytes, d_params.items);

    for (output_indices.items) |idx| {
        const size_bytes = core.LLVMConstInt(core.LLVMInt64Type(), 4, 0);

        try cuda.copyDToH(module, builder, d_params.items[idx], h_params.items[idx], size_bytes);

        const loaded_float = core.LLVMBuildLoad2(builder, core.LLVMFloatType(), h_params.items[idx], "loaded_float");
        const loaded_value = core.LLVMBuildFPToSI(builder, loaded_float, core.LLVMInt64Type(), "loaded_value");
        try rllvm.utils.printInt(module, builder, loaded_value);
    }

    return module;
}

const KernelData = struct {
    dims: struct {
        block: struct {
            x: types.LLVMValueRef,
            y: types.LLVMValueRef,
            z: types.LLVMValueRef,
        },
    },
};

fn calculateMetadata(ops: []*rir.RIROP) !KernelData {
    const shape = ops[0].*.getShape();

    const int_type = core.LLVMInt32Type();
    return .{
        .dims = .{
            .block = .{
                .x = core.LLVMConstInt(int_type, shape[0], 0),
                .y = core.LLVMConstInt(int_type, if (shape.len > 1) shape[1] else 1, 0),
                .z = core.LLVMConstInt(int_type, 1, 0),
            },
        },
    };
}

pub fn genReturnFirstParam(module: types.LLVMModuleRef) !types.LLVMValueRef {
    const allocator = arena.allocator();

    var instructions = std.ArrayList(ptxast.Instruction).init(allocator);

    var directives = std.ArrayList(ptxast.Directive).init(allocator);

    try directives.append(.{
        .reg = .{
            .name = "%rd",
            .count = 3,
            .type = .b64,
        },
    });

    try directives.append(.{
        .reg = .{
            .name = "%f",
            .count = 3,
            .type = .f32,
        },
    });

    try instructions.append(.{ .ld = .{ .space = .param, .type = .u64, .src = .{ .parameter = "param_0" }, .dest = .{ .register = "%rd0" } } });
    try instructions.append(.{ .ld = .{ .space = .param, .type = .u64, .src = .{ .parameter = "param_1" }, .dest = .{ .register = "%rd1" } } });
    try instructions.append(.{ .ld = .{ .space = .param, .type = .u64, .src = .{ .parameter = "param_2" }, .dest = .{ .register = "%rd2" } } });
    try instructions.append(.{ .cvta = .{ .to_generic = true, .space = .global, .type = .u64, .src = .{ .register = "%rd0" }, .dest = .{ .register = "%rd0" } } });
    try instructions.append(.{ .cvta = .{ .to_generic = true, .space = .global, .type = .u64, .src = .{ .register = "%rd1" }, .dest = .{ .register = "%rd1" } } });
    try instructions.append(.{ .cvta = .{ .to_generic = true, .space = .global, .type = .u64, .src = .{ .register = "%rd2" }, .dest = .{ .register = "%rd2" } } });
    try instructions.append(.{ .ld = .{ .space = .global, .type = .f32, .src = .{ .register = "%rd0" }, .dest = .{ .register = "%f0" } } });
    try instructions.append(.{ .ld = .{ .space = .global, .type = .f32, .src = .{ .register = "%rd1" }, .dest = .{ .register = "%f1" } } });
    try instructions.append(.{ .add = .{ .type = .f32, .src1 = .{ .register = "%f0" }, .src2 = .{ .register = "%f1" }, .dest = .{ .register = "%f2" } } });
    try instructions.append(.{ .st = .{ .space = .global, .type = .f32, .dest = .{ .register = "%rd2" }, .src = .{ .register = "%f2" } } });
    try instructions.append(.ret);

    var params = std.ArrayList([]const u8).init(allocator);
    try params.append("param_0");
    try params.append("param_1");
    try params.append("param_2");

    const kernel = ptxast.Kernel{
        .name = "main",
        .body = try instructions.toOwnedSlice(),
        .directives = try directives.toOwnedSlice(),
        .params = try params.toOwnedSlice(),
    };

    const globals = &[_]ptxast.GlobalDecl{};
    var kernels = [_]ptxast.Kernel{kernel};
    const ast = ptxast.PTXAst{ .allocator = allocator, .globals = globals, .kernels = &kernels };
    const ptx = try @import("nvidia/emission.zig").emit(allocator, ast);

    const kernel_len = ptx.len;
    const global_ptx_str = core.LLVMAddGlobal(module, core.LLVMArrayType(core.LLVMInt8Type(), @intCast(kernel_len)), "ptx_str");
    const kernel_constant = core.LLVMConstString(@ptrCast(ptx), @intCast(kernel_len), 1);
    core.LLVMSetInitializer(global_ptx_str, kernel_constant);

    return global_ptx_str;
}
