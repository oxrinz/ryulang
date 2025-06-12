const std = @import("std");

pub const DType = enum {
    I32,
    F32,

    pub fn toCPUType(self: DType) type {
        return switch (self) {
            .I32 => i32,
            .F32 => f32,
        };
    }

    pub fn fromCPUType(comptime T: type) DType {
        return switch (T) {
            i32 => .I32,
            f32 => .F32,
            else => unreachable,
        };
    }
};

pub fn Buffer(comptime T: type) type {
    return struct {
        buffer: []T,
    };
}

pub const Constant = struct {
    ptr: *anyopaque,
    dtype: DType,
    shape: []const usize,

    pub fn getConstant(self: @This(), comptime T: type) *Constant(T) {
        return @ptrCast(@alignCast(self.ptr));
    }
};

pub const RIROP = union(enum) {
    add: struct {
        a: *RIROP,
        b: *RIROP,
    },
    divide: struct {
        a: *RIROP,
        b: *RIROP,
    },

    call: struct {
        identifier: []const u8,
        args: *[]*RIROP,
    },

    rand: struct {
        dtype: DType,
        shape: *RIROP,
    },

    constant: Constant,

    ret: struct {
        op: *RIROP,
    },
};
