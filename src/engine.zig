const std = @import("std");
const ast = @import("frontend/ast.zig");
const rir = @import("rir/rir.zig");
const rir_gen = @import("rir/rir-gen.zig");
const Program = @import("program.zig").Program;
const dashboard = @import("dashboard.zig");
const pm = @import("rir/pattern-matcher.zig");

/// Converts an ast module into an optimized and finalized ryu program
pub fn generateProgram(module: ast.Module, allocator: std.mem.Allocator) !Program {
    var program = try rir_gen.generateProgram(module, allocator);
    const base_graph_stage = dashboard.Stage{
        .title = "Base Graph",
        .ops = program.graph,
    };
    try dashboard.addStage(base_graph_stage);

    for (program.effects) |*effect| {
        const draft_kernel = try kernelize(effect.targets, allocator);
        var new_graph = try allocator.alloc(*rir.RIROP, 1);
        new_graph[0] = draft_kernel;
        program.graph = new_graph;
        const create_kernels_stage = dashboard.Stage{
            .title = "Create Kernels",
            .ops = program.graph,
        };
        try dashboard.addStage(create_kernels_stage);

        const linearized_kernel = try linealizeKernel(draft_kernel, allocator);
        new_graph[0] = linearized_kernel;
        program.graph = new_graph;
        const linearize_kernels_stage = dashboard.Stage{
            .title = "Linearize Kernels",
            .ops = program.graph,
        };
        try dashboard.addStage(linearize_kernels_stage);

        effect.targets = program.graph;
    }

    return program;
}

const DimRegs = struct {
    local_x: *rir.RIROP,
    local_y: *rir.RIROP,
    fn init(allocator: std.mem.Allocator, kernel_ops: std.ArrayList(*rir.RIROP)) DimRegs {
        const local_x = try allocator.create(rir.RIROP);
        const local_y = try allocator.create(rir.RIROP);
        local_x.* = .{ .position = .{ .local = .x } };
        local_y.* = .{ .position = .{ .local = .y } };
        try kernel_ops.append(local_x);
        try kernel_ops.append(local_y);
        return .{
            .local_x = local_x,
            .local_y = local_y,
        };
    }
};

fn kernelize(ops: []*rir.RIROP, allocator: std.mem.Allocator) !*rir.RIROP {
    // step 1: eat ops up until we hit a non-eatable and collect input parameters
    var inputs = std.ArrayList(*rir.RIROP).init(allocator);
    for (ops) |op| {
        try inputs.appendSlice(try eatInputs(op, allocator));
    }

    // step 2: collect output parameters
    var outputs = std.ArrayList(*rir.RIROP).init(allocator);
    for (ops) |op| {
        switch (op.*) {
            .store => {
                try outputs.append(op);
            },
            else => {},
        }
    }

    // step 3: iterate over inputs, add loading logic
    for (inputs.items) |input| {
        _ = input;
        var any = pm.Pattern{ .any = {} };
        var pattern = pm.Pattern{ .add = .{ .a = &any, .b = &any } };
        const fuck = try pm.match(allocator, &pattern, ops[0]);
        std.debug.print("input: {any}\n", .{fuck.captured});
    }

    var params = std.ArrayList(*rir.RIROP).init(allocator);
    try params.appendSlice(try inputs.toOwnedSlice());
    try params.appendSlice(try outputs.toOwnedSlice());
    const kernel = try allocator.create(rir.RIROP);
    kernel.* = .{
        .draft_kernel = .{
            .params = try params.toOwnedSlice(),
            .ops = ops,
        },
    };
    return kernel;
}

// replace non eatable with param_addr and loading logic
fn eatInputs(op: *rir.RIROP, allocator: std.mem.Allocator) ![]*rir.RIROP {
    var inputs = std.ArrayList(*rir.RIROP).init(allocator);
    switch (op.*) {
        .add => |*add| {
            if (shouldEat(add.a)) {
                try inputs.appendSlice(try eatInputs(add.a, allocator));
            } else {
                try inputs.append(add.a);
                const param_addr_op = try allocator.create(rir.RIROP);
                param_addr_op.* = .param_addr;
                add.a = param_addr_op;
            }
            if (shouldEat(add.b)) {
                try inputs.appendSlice(try eatInputs(add.b, allocator));
            } else {
                try inputs.append(add.b);
                const param_addr_op = try allocator.create(rir.RIROP);
                param_addr_op.* = .param_addr;
                add.b = param_addr_op;
            }
        },
        .store => |store| {
            if (shouldEat(store.source)) {
                try inputs.appendSlice(try eatInputs(store.source, allocator));
            }
        },
        else => {},
    }
    return try inputs.toOwnedSlice();
}

fn shouldEat(op: *rir.RIROP) bool {
    return switch (op.*) {
        .add, .store => true,
        else => false,
    };
}

fn linealizeKernel(kernel_op: *rir.RIROP, allocator: std.mem.Allocator) !*rir.RIROP {
    std.debug.assert(kernel_op.* == .draft_kernel);

    const linearize_op = struct {
        fn linearize_op(op: *rir.RIROP, list: *std.ArrayList(*rir.RIROP)) !void {
            switch (op.*) {
                .add => |add| {
                    try linearize_op(add.a, list);
                    try linearize_op(add.b, list);
                    try list.append(op);
                },
                .store => |store| {
                    try linearize_op(store.source, list);
                    try list.append(op);
                },
                else => {
                    try list.append(op);
                },
            }
        }
    }.linearize_op;

    var linearized = std.ArrayList(*rir.RIROP).init(allocator);
    for (kernel_op.draft_kernel.ops) |op| {
        try linearize_op(op, &linearized);
    }

    const shape = kernel_op.draft_kernel.params[0].getShape();

    var total_elements: u64 = 1;
    for (shape) |dim| {
        total_elements *= dim;
    }

    const block_size_x = 16;
    const block_size_y = 16;
    const threads_per_block = block_size_x * block_size_y;

    const grid_x = (total_elements + threads_per_block - 1) / threads_per_block;

    const kernel = try allocator.create(rir.RIROP);
    kernel.* = .{
        .kernel = .{
            .params = kernel_op.draft_kernel.params,
            .ops = try linearized.toOwnedSlice(),
            .dims = .{
                .local = .{
                    .x = block_size_x,
                    .y = block_size_y,
                    .z = 1,
                },
                .global = .{
                    .x = grid_x,
                    .y = 1,
                    .z = 1,
                },
            },
        },
    };
    return kernel;
}

fn calculateDims(op: *rir.RIROP) !rir.KernelDims {
    const shape = op.getShape();
    return .{
        .local = .{
            .x = shape[0],
            .y = shape[1],
        },
    };
}
