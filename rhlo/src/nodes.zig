const std = @import("std");

pub const DataType = enum {
    F32,
    I32,
};

pub const Shape = []const usize;

pub const Tensor = struct {
    dimensions: Shape,
    dtype: DataType,
};

pub const TensorRef = usize;

pub const OperationKind = enum {
    Add,
};

pub const Operation = struct {
    kind: OperationKind,
    input_ids: []const usize,
    output_ids: []const usize,
};

pub const RHLOProgram = struct {
    tensor_store: std.ArrayList(Tensor),
    ops: std.ArrayList(Operation),
    input_ids: std.ArrayList(usize),
    output_ids: std.ArrayList(usize),

    pub fn init(allocator: std.mem.Allocator) !RHLOProgram {
        return .{
            .tensor_store = std.ArrayList(Tensor).init(allocator),
            .ops = std.ArrayList(Operation).init(allocator),
            .input_ids = std.ArrayList(usize).init(allocator),
            .output_ids = std.ArrayList(usize).init(allocator),
        };
    }
};
