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

    pub fn add(self: *Builder, a: nodes.TensorRef, b: nodes.TensorRef) void {
        const tensor_store = self.program.tensor_store.items;
        const a_tensor = tensor_store.items[a];
        const b_tensor = tensor_store.items[b];

        if (a_tensor.dimensions != b_tensor.dimensions) unreachable;

        const output_tensor = self.program.tensor_store = 

        self.program.ops.append(.{ 
            .input_ids = .{a_tensor, b_tensor},
        .output_ids = output_id,
        .kind = ,
         })
    }
};
