const std = @import("std");
const ast = @import("frontend/ast.zig");
const rir = @import("rir/rir.zig");
const rir_gen = @import("rir/rir-gen.zig");
const Program = @import("program.zig").Program;
const dashboard = @import("dashboard.zig");
const pm = @import("rir/pattern-matcher.zig");
const kir = @import("rir/kernel-ir.zig");

/// Converts an ast module into an optimized and finalized ryu program
pub fn generateProgram(module: ast.Module, allocator: std.mem.Allocator) !Program {
    const program = try rir_gen.generateProgram(module, allocator);
    const base_graph_stage = dashboard.Stage{
        .title = "Base Graph",
        .ops = program.graph,
    };
    try dashboard.addStage(base_graph_stage);

    for (program.effects) |*effect| {
        try createKernels(effect.targets, allocator);
        const create_kernels_stage = dashboard.Stage{
            .title = "Create Kernels",
            .ops = program.graph,
        };
        try dashboard.addStage(create_kernels_stage);

        // try linealizeKernels(effect.targets, allocator);
        // const linearize_kernels_stage = dashboard.Stage{
        //     .title = "Linearize Kernels",
        //     .ops = program.graph,
        // };
        // try dashboard.addStage(linearize_kernels_stage);

        effect.targets = program.graph;
    }

    return program;
}

// IMPORTANT: this is a fake function, it lies, it actually outputs linear kernel
fn createKernels(ops: []*rir.RIROP, allocator: std.mem.Allocator) !void {
    // step 1: find all binary ops and store them
    var pattern = pm.Pattern{ .add = null };
    const binops = try pm.match(allocator, &pattern, ops);

    // step 2: create output buffer
    const output_buffer = try allocator.create(rir.RIROP);
    output_buffer.* = .{ .buffer = .{
        .device = .{ .device = 0 },
        .dtype = .f32,
        .size = binops[0].getSizeInBytes(allocator),
    } };
    const output_buffer_view = try allocator.create(rir.RIROP);
    output_buffer_view.* = .{
        .view = .{ .shape = binops[0].getShape(), .src = output_buffer },
    };

    // step 3: replace binops with kernels
    const OpContainer = struct {
        inner_allocator: std.mem.Allocator,
        kernel_ops: std.array_list.Managed(*kir.KIROP),
        kernel_params: std.array_list.Managed(*rir.RIROP),

        pub fn init(inner_allocator: std.mem.Allocator) !@This() {
            return .{
                .inner_allocator = inner_allocator,
                .kernel_ops = std.array_list.Managed(*kir.KIROP).init(inner_allocator),
                .kernel_params = std.array_list.Managed(*rir.RIROP).init(inner_allocator),
            };
        }

        pub fn appendInstruction(self: *@This(), op: kir.KIROP) !*kir.KIROP {
            const op_ptr = try self.inner_allocator.create(kir.KIROP);
            op_ptr.* = op;
            try self.kernel_ops.append(op_ptr);
            return op_ptr;
        }

        pub fn getGraphKernel(self: *@This()) !kir.LinearKernel {
            return .{
                .ops = try self.kernel_ops.toOwnedSlice(),
                .params = try self.kernel_params.toOwnedSlice(),
            };
        }
    };

    for (binops) |binop| {
        var op_container = try OpContainer.init(allocator);

        // generate params
        switch (binop.*) {
            .add => |add| {
                if (add.a.* == .view and add.b.* == .view) {
                    try op_container.kernel_params.append(add.a);
                    try op_container.kernel_params.append(add.b);
                }
            },
            else => std.debug.panic("op {any} not implemented in createKernel", .{@intFromEnum(binop.*)}),
        }
        try op_container.kernel_params.append(output_buffer_view);

        // generate ops
        switch (binop.*) {
            .add => |add| {
                const local_x = try op_container.appendInstruction(.{
                    .special = .{ .local = .x },
                });
                const load_param_addr_a = try op_container.appendInstruction(.{
                    .load = .{ .addr = .{ .param = add.a } },
                });
                const load_param_addr_b = try op_container.appendInstruction(.{
                    .load = .{ .addr = .{ .param = add.b } },
                });
                const addr_a = try op_container.appendInstruction(.{
                    .add = .{
                        .src1 = .{ .kirop = local_x },
                        .src2 = .{ .kirop = load_param_addr_a },
                    },
                });
                _ = addr_a;
                _ = load_param_addr_b;
            },
            else => std.debug.panic("op {any} not implemented in createKernel", .{@intFromEnum(binop.*)}),
        }

        // replace binop with kernel op
        binop.* = .{
            .linear_kernel = try op_container.getGraphKernel(),
        };
    }
}

fn linealizeKernels(ops: []*rir.RIROP, allocator: std.mem.Allocator) !void {
    // step 1: find all kernel ops and store them
    const pattern = try allocator.create(pm.Pattern);
    pattern.* = .graph_kernel;
    const kernels = try pm.match(allocator, pattern, ops);

    const linearize_op = struct {
        fn linearize_op(op: *kir.KIROP, list: *std.array_list.Managed(*kir.KIROP)) !void {
            switch (op.*) {
                .add => |add| {
                    if (add.src1 == .kirop) try linearize_op(add.src1.kirop, list);
                    if (add.src2 == .kirop) try linearize_op(add.src2.kirop, list);
                    try list.append(op);
                },
                .store => |store| {
                    try linearize_op(store.src.kirop, list);
                    try list.append(op);
                },
                else => {
                    try list.append(op);
                },
            }
        }
    }.linearize_op;

    var linearized = std.array_list.Managed(*kir.KIROP).init(allocator);
    for (kernels) |kernel| {
        for (kernel.graph_kernel.ops) |op| {
            try linearize_op(op, &linearized);
        }
    }

    std.debug.print("ahh: {any}\n", .{linearized.items});

    for (kernels) |kernel| {
        kernel.* = .{
            .linear_kernel = .{
                .ops = try linearized.toOwnedSlice(),
                .params = kernel.linear_kernel.params,
            },
        };
    }

    // const shape = kernel_op.draft_kernel.params[0].getShape();

    // var total_elements: u64 = 1;
    // for (shape) |dim| {
    //     total_elements *= dim;
    // }

    // const block_size_x = 16;
    // const block_size_y = 16;
    // const threads_per_block = block_size_x * block_size_y;

    // const grid_x = (total_elements + threads_per_block - 1) / threads_per_block;
}
