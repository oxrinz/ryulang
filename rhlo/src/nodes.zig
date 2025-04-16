const DataType = enum {
    F32,
    I32,
};

const Tensor = struct {
    dimensions: []const usize,
    dtype: DataType,
};

const OperationKind = enum {
    Add,
    Dot,
};

const Operation = struct {
    kind: OperationKind,
    input_ids: []const usize,
    output_ids: []const usize,
};

const RHLOProgram = struct {
    tensor_store: []const Tensor,
    ops: []const Operation,
    input_ids: []const usize,
    output_ids: []const usize,
};
