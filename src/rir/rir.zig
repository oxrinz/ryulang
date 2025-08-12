// TODO: this file is commonly used across the whole compiler, might be good to have it as a package in build.zig

const std = @import("std");

pub const DType = enum {
    I64,
    F64,
    USize,

    pub fn getSizeInBytes(self: DType) usize {
        return switch (self) {
            .I64 => 4,
            .F64 => 4,
            .USize => 4,
        };
    }
};

pub fn Buffer(comptime T: type) type {
    return struct {
        buffer: []T,
    };
}

pub const Constant = struct {
    const Value = struct {
        i64: i64,
        f64: f64,
        usize: usize,
    };

    ptr: *anyopaque,
    dtype: DType,
    shape: []const usize,

    pub fn getSize(self: @This()) usize {
        var size: usize = 1;
        for (self.shape) |dim| {
            size *= dim;
        }
        return size;
    }

    pub fn getSizeInBytes(self: @This()) usize {
        return self.getSize() * self.dtype.getSizeInBytes();
    }

    pub fn getConstant(self: @This()) union(enum) { i64: []const i64, f64: []const f64, usize: []const usize } {
        var total: usize = 1;
        for (self.shape) |s| total *= s;

        return switch (self.dtype) {
            .I64 => .{ .i64 = @as([*]const i64, @alignCast(@ptrCast(self.ptr)))[0..total] },
            .F64 => .{ .f64 = @as([*]const f64, @alignCast(@ptrCast(self.ptr)))[0..total] },
            .USize => .{ .usize = @as([*]const usize, @alignCast(@ptrCast(self.ptr)))[0..total] },
        };
    }

    pub fn getConstantAs(self: @This(), comptime T: type) []T {
        var total: usize = 1;
        for (self.shape) |s| total *= s;
        return @as([*]T, @alignCast(@ptrCast(self.ptr)))[0..total];
    }

    pub fn asBytes(self: @This()) []const u8 {
        return switch (self.dtype) {
            .I64 => std.mem.asBytes(@as(*const i64, @alignCast(@ptrCast(self.ptr)))),
            .F64 => std.mem.asBytes(@as(*const f64, @alignCast(@ptrCast(self.ptr)))),
            .USize => std.mem.asBytes(@as(*const usize, @alignCast(@ptrCast(self.ptr)))),
        };
    }

    pub fn print(self: @This()) void {
        const value = self.getConstant();

        std.debug.print("Constant: {any}\n", .{value});
    }
};

pub const RIROP = union(enum) {
    add: struct { a: *RIROP, b: *RIROP },
    divide: struct { a: *RIROP, b: *RIROP },

    call: struct { identifier: []const u8, args: *[]*RIROP },

    rand: struct { dtype: DType, shape: *RIROP },

    print: struct { op: *RIROP },

    constant: Constant,

    ret: struct { op: *RIROP },

    pub fn getShape(self: RIROP) []const usize {
        return switch (self) {
            .add => |add| add.a.getShape(),
            .rand => |rand| rand.shape.getShape(),
            .print => |print| print.op.getShape(),
            .constant => |constant| return constant.getConstantAs(usize),
            else => unreachable,
        };
    }

    pub fn getSizeInBytes(self: *RIROP, allocator: std.mem.Allocator) usize {
        const input = self.findInputs(allocator);
        return input[0].constant.getSizeInBytes();
    }

    pub fn findInputs(self: *RIROP, allocator: std.mem.Allocator) []*RIROP {
        return switch (self.*) {
            .add => {
                const a_inputs = self.add.a.findInputs(allocator);
                const b_inputs = self.add.b.findInputs(allocator);
                var result = std.ArrayList(*RIROP).init(allocator);
                result.appendSlice(a_inputs) catch unreachable;
                result.appendSlice(b_inputs) catch unreachable;
                return result.toOwnedSlice() catch unreachable;
            },
            .rand => {
                return self.rand.shape.findInputs(allocator);
            },
            .print => {
                return self.print.op.findInputs(allocator);
            },
            .constant => {
                var slice = allocator.alloc(*RIROP, 1) catch unreachable;
                slice[0] = self;
                return slice;
            },
            else => unreachable,
        };
    }
};
