pub const Node = union(enum) {
    Constant: Tensor,
    StableHLOOp: struct {
        op: StableHLOOperation,
        operands: []const *Node,
    },
};

const DType = enum {
    FLOAT32,
};

const TensorInitializer = enum {
    Ones,
};

const Tensor = struct {
    initializer: TensorInitializer,
    shape: []?usize,
    element_type: DType = .FLOAT32,
};

const StableHLOOperation = enum {
    add,
};
