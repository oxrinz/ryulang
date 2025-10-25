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

        try linealizeKernels(effect.targets, allocator);
        const linearize_kernels_stage = dashboard.Stage{
            .title = "Linearize Kernels",
            .ops = program.graph,
        };
        try dashboard.addStage(linearize_kernels_stage);

        effect.targets = program.graph;
    }

    return program;
}

// IMPORTANT: this is a fake function, it lies, it actually outputs linear kernel
// IMPORTANT: i don't actually know if the statement above is true anymore
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
    const CreateOpStruct = struct {
        inner_allocator: std.mem.Allocator,

        pub fn init(inner_allocator: std.mem.Allocator) @This() {
            return .{ .inner_allocator = inner_allocator };
        }

        fn createOp(self: *@This(), op: kir.KIROP) !*kir.KIROP {
            const op_ptr = try self.inner_allocator.create(kir.KIROP);
            op_ptr.* = op;
            return op_ptr;
        }
    };

    for (binops) |binop| {
        var kernel_ops = std.array_list.Managed(*kir.KIROP).init(allocator);
        var kernel_params = std.array_list.Managed(*rir.RIROP).init(allocator);

        var create_op_struct = CreateOpStruct.init(allocator);

        // generate params
        switch (binop.*) {
            .add => |add| {
                if (add.a.* == .view and add.b.* == .view) {
                    const a_buffer = try allocator.create(rir.RIROP);
                    a_buffer.* = .{ .buffer = .{ .device = 0 } };
                    const a_copy = try allocator.create(rir.RIROP);
                    a_copy = .{ .copy = .{ .dest = a_buffer, .src = add.a } };
                    try kernel_params.append(a_buffer);
                    const b_buffer = try allocator.create(rir.RIROP);
                    b_buffer.* = .{ .buffer = .{ .device = 0 } };
                    const b_copy = try allocator.create(rir.RIROP);
                    b_copy = .{ .copy = .{ .dest = b_buffer, .src = add.b } };
                    try kernel_params.append(b_buffer);
                }
            },
            else => std.debug.panic("op {any} not implemented in createKernel", .{@intFromEnum(binop.*)}),
        }
        try kernel_params.append(output_buffer_view);

        // generate ops
        switch (binop.*) {
            .add => |add| {
                const local_x = try create_op_struct.createOp(.{
                    .special = .{ .local = .x },
                });
                const const_4 = try create_op_struct.createOp(.{ .constant = 4 });
                const local_x_scaled = try create_op_struct.createOp(.{
                    .multiply = .{ .a = .{ .kirop = local_x }, .b = .{ .kirop = const_4 } },
                });
                const load_param_addr_a = try create_op_struct.createOp(.{
                    .load = .{ .addr = .{ .param = add.a } },
                });
                const load_param_addr_b = try create_op_struct.createOp(.{
                    .load = .{ .addr = .{ .param = add.b } },
                });
                const addr_a = try create_op_struct.createOp(.{
                    .add = .{ .src1 = .{ .kirop = local_x_scaled }, .src2 = .{ .kirop = load_param_addr_a } },
                });
                const addr_b = try create_op_struct.createOp(.{
                    .add = .{ .src1 = .{ .kirop = local_x_scaled }, .src2 = .{ .kirop = load_param_addr_b } },
                });
                const load_val_a = try create_op_struct.createOp(.{
                    .load = .{ .addr = .{ .kirop = addr_a } },
                });
                const load_val_b = try create_op_struct.createOp(.{
                    .load = .{ .addr = .{ .kirop = addr_b } },
                });
                const result = try create_op_struct.createOp(.{
                    .add = .{ .src1 = .{ .kirop = load_val_a }, .src2 = .{ .kirop = load_val_b } },
                });
                const store_param_addr = try create_op_struct.createOp(.{
                    .load = .{ .addr = .{ .param = kernel_params.items[2] } },
                });
                const store_addr = try create_op_struct.createOp(.{
                    .add = .{ .src1 = .{ .kirop = store_param_addr }, .src2 = .{ .kirop = local_x_scaled } },
                });
                const store = try create_op_struct.createOp(.{
                    .store = .{ .addr = .{ .kirop = store_addr }, .src = .{ .kirop = result } },
                });
                try kernel_ops.append(store);
            },
            else => std.debug.panic("op {any} not implemented in createKernel", .{@intFromEnum(binop.*)}),
        }

        // replace binop with kernel op
        binop.* = .{ .graph_kernel = .{
            .ops = try kernel_ops.toOwnedSlice(),
            .params = try kernel_params.toOwnedSlice(),
        } };
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
                .multiply => |multiply| {
                    if (multiply.a == .kirop) try linearize_op(multiply.a.kirop, list);
                    if (multiply.b == .kirop) try linearize_op(multiply.b.kirop, list);
                    try list.append(op);
                },
                .store => |store| {
                    try linearize_op(store.addr.kirop, list);
                    try linearize_op(store.src.kirop, list);
                    try list.append(op);
                },
                .load => |load| {
                    if (load.addr == .kirop) try linearize_op(load.addr.kirop, list);
                    try list.append(op);
                },
                .convert => |convert| {
                    try linearize_op(convert.src.kirop, list);
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

    for (kernels) |kernel| {
        kernel.* = .{
            .linear_kernel = .{
                .ops = try linearized.toOwnedSlice(),
                .params = kernel.linear_kernel.params,
            },
        };
    }
}
