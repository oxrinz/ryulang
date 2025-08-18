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
    Matmul,
};

pub const Operation = struct {
    kind: OperationKind,
    input_ids: []const usize,
    output_ids: []const usize,
};

pub const Parameter = struct {
    id: usize,
    input: bool = false,
    output: bool = false,
};

pub const Program = struct {
    tensor_store: std.ArrayList(Tensor),
    ops: std.ArrayList(Operation),
    params: std.ArrayList(Parameter),

    pub fn init(allocator: std.mem.Allocator) !Program {
        return .{
            .tensor_store = std.ArrayList(Tensor).init(allocator),
            .ops = std.ArrayList(Operation).init(allocator),
            .params = std.ArrayList(Parameter).init(allocator),
        };
    }
};
