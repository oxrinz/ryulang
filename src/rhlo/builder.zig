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

    pub fn createParameterFromRef(self: *Builder, ref: nodes.TensorRef) !void {
        try self.program.params.append(.{ .id = ref, .output = true });
    }

    pub fn createParameter(self: *Builder, dtype: nodes.DataType, shape: nodes.Shape) !nodes.TensorRef {
        const param_id = self.program.tensor_store.items.len;
        try self.program.tensor_store.append(.{
            .dtype = dtype,
            .dimensions = shape,
        });
        try self.program.params.append(.{ .id = param_id, .input = true });

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

        const input_ids = try self.allocator.alloc(usize, 2);
        input_ids[0] = a;
        input_ids[1] = b;

        const output_ids = try self.allocator.alloc(usize, 1);
        output_ids[0] = output_id;

        try self.program.ops.append(.{
            .input_ids = input_ids,
            .output_ids = output_ids,
            .kind = .Add,
        });

        return output_id;
    }

    pub fn opMatmul(self: *Builder, a: nodes.TensorRef, b: nodes.TensorRef) !nodes.TensorRef {
        const tensor_store = self.program.tensor_store.items;
        const a_tensor = tensor_store[a];
        const b_tensor = tensor_store[b];

        if (a_tensor.dimensions.len < 2 or b_tensor.dimensions.len < 2) {
            return error.InvalidTensorDimensions;
        }

        const m = a_tensor.dimensions[0];
        const n_a = a_tensor.dimensions[1];
        const n_b = b_tensor.dimensions[0];
        const p = b_tensor.dimensions[1];

        if (n_a != n_b) {
            return error.IncompatibleDimensions;
        }

        const max_leading_dims = @max(a_tensor.dimensions.len, b_tensor.dimensions.len) - 2;
        var output_dims = try self.allocator.alloc(usize, max_leading_dims + 2);

        if (max_leading_dims > 0) {
            @memcpy(output_dims[0..max_leading_dims], a_tensor.dimensions[0..max_leading_dims]);
        }

        output_dims[max_leading_dims] = m;
        output_dims[max_leading_dims + 1] = p;

        const output_id = tensor_store.len;
        try self.program.tensor_store.append(.{
            .dimensions = output_dims,
            .dtype = a_tensor.dtype,
        });

        const input_ids = try self.allocator.alloc(usize, 2);
        input_ids[0] = a;
        input_ids[1] = b;

        const output_ids = try self.allocator.alloc(usize, 1);
        output_ids[0] = output_id;

        try self.program.ops.append(.{
            .input_ids = input_ids,
            .output_ids = output_ids,
            .kind = .Matmul,
        });

        return output_id;
    }
};
