pub const RHLOBuffer = struct {
    data_ptr: *void,
    size: usize,
};

pub fn create_buffer(data_ptr: *void, size: usize) RHLOBuffer {
    return .{
        .data_ptr = data_ptr,
        .size = size,
    };
}
