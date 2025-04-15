const TensorElementType = enum {
    FLOAT32,
};

const TensorType = struct {
    shape: []?usize,
    element_type: TensorElementType = .FLOAT32,
};

const Type = union(enum) {
    tensor: u32,
};

const Op = union(enum) {
    add: fn () void,
};
