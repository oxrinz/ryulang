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
    var input_count: usize = 0;

    // Count inputs first to determine kernel parameters
    for (params) |param| {
        switch (param.*) {
            .constant => input_count += 1,
            else => {},
        }
    }

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

    // Generate PTX kernel based on actual parameter count and operation
    const ptx = try generateKernel(module, input_count);

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
        const loaded_value = core.LLVMBuildFPToSI(builder, loaded_float, core.LLVMInt32Type(), "loaded_value");
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

fn generateKernel(module: types.LLVMModuleRef, input_count: usize) !types.LLVMValueRef {
    const allocator = arena.allocator();

    var instructions = std.ArrayList(ptxast.Instruction).init(allocator);
    var directives = std.ArrayList(ptxast.Directive).init(allocator);
    var params = std.ArrayList([]const u8).init(allocator);

    // Calculate total parameters (inputs + 1 output)
    const total_params = input_count + 1;
    const reg_count = total_params + 1; // Extra registers for computation

    try directives.append(.{
        .reg = .{
            .name = "%rd",
            .count = @intCast(reg_count),
            .type = .b64,
        },
    });

    try directives.append(.{
        .reg = .{
            .name = "%f",
            .count = @intCast(reg_count),
            .type = .f32,
        },
    });

    // Load all parameters
    for (0..total_params) |i| {
        const param_name = try std.fmt.allocPrint(allocator, "param_{d}", .{i});
        const rd_reg = try std.fmt.allocPrint(allocator, "%rd{d}", .{i});

        try params.append(param_name);
        try instructions.append(.{ .ld = .{ .space = .param, .type = .u64, .src = .{ .parameter = param_name }, .dest = .{ .register = rd_reg } } });
    }

    // Convert to global addresses
    for (0..total_params) |i| {
        const rd_reg = try std.fmt.allocPrint(allocator, "%rd{d}", .{i});
        try instructions.append(.{ .cvta = .{ .to_generic = true, .space = .global, .type = .u64, .src = .{ .register = rd_reg }, .dest = .{ .register = rd_reg } } });
    }

    // Load input values
    for (0..input_count) |i| {
        const rd_reg = try std.fmt.allocPrint(allocator, "%rd{d}", .{i});
        const f_reg = try std.fmt.allocPrint(allocator, "%f{d}", .{i});

        try instructions.append(.{ .ld = .{ .space = .global, .type = .f32, .src = .{ .register = rd_reg }, .dest = .{ .register = f_reg } } });
    }

    // Perform computation based on number of inputs
    const result_reg = try std.fmt.allocPrint(allocator, "%f{d}", .{input_count});
    if (input_count == 1) {
        // Just copy the input to output (identity operation)
        const f0_reg = try std.fmt.allocPrint(allocator, "%f{d}", .{0});
        try instructions.append(.{ .mov = .{ .type = .f32, .src = .{ .register = f0_reg }, .dest = .{ .register = result_reg } } });
    } else if (input_count == 2) {
        // Add two inputs
        const f0_reg = try std.fmt.allocPrint(allocator, "%f{d}", .{0});
        const f1_reg = try std.fmt.allocPrint(allocator, "%f{d}", .{1});
        try instructions.append(.{ .add = .{ .type = .f32, .src1 = .{ .register = f0_reg }, .src2 = .{ .register = f1_reg }, .dest = .{ .register = result_reg } } });
    } else {
        // For more inputs, chain additions
        var current_reg = try std.fmt.allocPrint(allocator, "%f{d}", .{0});
        for (1..input_count) |i| {
            const next_input_reg = try std.fmt.allocPrint(allocator, "%f{d}", .{i});
            const temp_reg = if (i == input_count - 1) result_reg else try std.fmt.allocPrint(allocator, "%f{d}", .{input_count + i});

            try instructions.append(.{ .add = .{ .type = .f32, .src1 = .{ .register = current_reg }, .src2 = .{ .register = next_input_reg }, .dest = .{ .register = temp_reg } } });
            current_reg = temp_reg;
        }
    }

    // Store result to output
    const output_rd_reg = try std.fmt.allocPrint(allocator, "%rd{d}", .{input_count});
    try instructions.append(.{ .st = .{ .space = .global, .type = .f32, .dest = .{ .register = output_rd_reg }, .src = .{ .register = result_reg } } });

    try instructions.append(.ret);

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

// Keep the old function for backward compatibility, but mark it as deprecated
pub fn genReturnFirstParam(module: types.LLVMModuleRef) !types.LLVMValueRef {
    return generateKernel(module, 2); // Default to 2 inputs for the old hardcoded kernel
}
