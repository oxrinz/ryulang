const std = @import("std");

const nodes = @import("nodes.zig");

pub const Builder = struct {
    allocator: std.mem.Allocator,
    program: nodes.RHLOProgram,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .program = try nodes.RHLOProgram.init(allocator),
        };
    }

    pub fn paramemeter(self: *Builder, dtype: nodes.DataType, shape: nodes.Shape) !nodes.TensorRef {
        const param_id = self.program.tensor_store.items.len;
        try self.program.tensor_store.append(.{
            .dtype = dtype,
            .dimensions = shape,
        });

        return param_id;
    }

    pub fn opAdd(self: *Builder, a: nodes.TensorRef, b: nodes.TensorRef) !nodes.TensorRef {
        const tensor_store = self.program.tensor_store.items;
        const a_tensor = tensor_store[a];
        const b_tensor = tensor_store[b];

        if (!std.mem.eql(usize, a_tensor.dimensions, b_tensor.dimensions)) unreachable;

        const output_id = tensor_store.len;
        try self.program.tensor_store.append(.{
            .dimensions = a_tensor.dimensions,
            .dtype = a_tensor.dtype,
        });

        try self.program.ops.append(.{
            .input_ids = &[_]usize{ a, b },
            .output_ids = &[_]usize{output_id},
            .kind = .Add,
        });

        return output_id;
    }
};
