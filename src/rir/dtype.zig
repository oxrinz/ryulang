pub const DType = enum {
    u32,
    u64,
    i32,
    i64,
    f32,
    f64,
    usize,

    pub fn getSizeInBytes(self: DType) usize {
        return switch (self) {
            .f32, .i32, .u32 => 4,
            .f64, .i64, .u64 => 8,
            .usize => 8,
        };
    }

    pub fn toType(self: DType) type {
        return switch (self) {
            .i32 => i32,
            .i64 => i64,
            .f32 => f32,
            .f64 => f64,
            .usize => usize,
        };
    }
};
