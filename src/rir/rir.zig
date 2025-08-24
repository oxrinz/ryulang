// TODO: this file is commonly used across the whole compiler, might be good to have it as a package in build.zig

const std = @import("std");

const nvidia = @import("../backends/nvidia.zig");

const rllvm = @import("rllvm");
const cuda = rllvm.cuda;
const target = rllvm.llvm.target;
const target_machine_mod = rllvm.llvm.target_machine;
const types = rllvm.llvm.types;
const core = rllvm.llvm.core;
const execution = rllvm.llvm.engine;
const debug = rllvm.llvm.debug;

pub const DType = enum {
    i64,
    f32,
    f64,
    usize,

    pub fn getSizeInBytes(self: DType) usize {
        return switch (self) {
            .i64 => 8,
            .f32 => 4,
            .f64 => 8,
            .usize => 8,
        };
    }

    pub fn toType(self: DType) type {
        return switch (self) {
            .i64 => i64,
            .f32 => f32,
            .f64 => f64,
            .usize => usize,
        };
    }

    pub fn DataUnion(self: DType) type {
        return switch (self) {
            .i64 => union(enum) { i64: []const i64 },
            .f32 => union(enum) { f32: []const f32 },
            .f64 => union(enum) { f64: []const f64 },
            .usize => union(enum) { usize: []const usize },
        };
    }
};

pub fn Buffer(comptime T: type) type {
    return struct {
        buffer: []T,
    };
}

pub const DataUnion = union(DType) {
    i64: []const i64,
    f32: []const f32,
    f64: []const f64,
    usize: []const usize,
};

pub const Constant = struct {
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

    pub fn getConstant(self: @This()) DataUnion {
        var total: usize = 1;
        for (self.shape) |s| total *= s;

        return switch (self.dtype) {
            .i64 => .{ .i64 = @as([*]const i64, @alignCast(@ptrCast(self.ptr)))[0..total] },
            .f32 => .{ .f32 = @as([*]const f32, @alignCast(@ptrCast(self.ptr)))[0..total] },
            .f64 => .{ .f64 = @as([*]const f64, @alignCast(@ptrCast(self.ptr)))[0..total] },
            .usize => .{ .usize = @as([*]const usize, @alignCast(@ptrCast(self.ptr)))[0..total] },
        };
    }

    pub fn getConstantAs(self: @This(), comptime T: type) []T {
        // TODO: figure out getconstantas safety
        // const expected_dtype = switch (T) {
        //     i64 => DType.i64,
        //     f32 => DType.f32,
        //     f64 => DType.f64,
        //     usize => DType.usize,
        //     else => @panic("getConstantAs: Unsupported type requested"),
        // };

        // if (self.dtype != expected_dtype) {
        //     @panic("getConstantAs type mismatch");
        // }

        var total: usize = 1;
        for (self.shape) |s| total *= s;
        return @as([*]T, @alignCast(@ptrCast(self.ptr)))[0..total];
    }

    pub fn convertTo(self: @This(), target_dtype: DType, allocator: std.mem.Allocator) !Constant {
        if (self.dtype == target_dtype) {
            const new_data = try allocator.dupe(u8, self.asBytes());
            return Constant{
                .ptr = new_data.ptr,
                .dtype = target_dtype,
                .shape = try allocator.dupe(usize, self.shape),
            };
        }

        const total = self.getSize();
        const target_size = total * target_dtype.getSizeInBytes();
        const new_data = try allocator.alloc(u8, target_size);

        switch (self.dtype) {
            .i64 => convertFromType(i64, self.ptr, target_dtype, new_data.ptr, total),
            .f32 => convertFromType(f32, self.ptr, target_dtype, new_data.ptr, total),
            .f64 => convertFromType(f64, self.ptr, target_dtype, new_data.ptr, total),
            .usize => convertFromType(usize, self.ptr, target_dtype, new_data.ptr, total),
        }

        return Constant{
            .ptr = new_data.ptr,
            .dtype = target_dtype,
            .shape = try allocator.dupe(usize, self.shape),
        };
    }

    fn convertFromType(comptime T: type, src_ptr: *anyopaque, target_dtype: DType, dst_ptr: *anyopaque, count: usize) void {
        const src = @as([*]const T, @alignCast(@ptrCast(src_ptr)))[0..count];

        switch (target_dtype) {
            .i64 => convertSlice(T, i64, src, @as([*]i64, @alignCast(@ptrCast(dst_ptr)))[0..count]),
            .f32 => convertSlice(T, f32, src, @as([*]f32, @alignCast(@ptrCast(dst_ptr)))[0..count]),
            .f64 => convertSlice(T, f64, src, @as([*]f64, @alignCast(@ptrCast(dst_ptr)))[0..count]),
            .usize => convertSlice(T, usize, src, @as([*]usize, @alignCast(@ptrCast(dst_ptr)))[0..count]),
        }
    }

    fn convertSlice(comptime From: type, comptime To: type, src: []const From, dst: []To) void {
        for (src, dst) |s, *d| {
            if (From == To) {
                d.* = s;
            } else if (@typeInfo(From) == .int and @typeInfo(To) == .float) {
                d.* = @floatFromInt(s);
            } else if (@typeInfo(From) == .float and @typeInfo(To) == .int) {
                d.* = @intFromFloat(s);
            } else if (@typeInfo(From) == .float and @typeInfo(To) == .float) {
                d.* = @floatCast(s);
            } else if (@typeInfo(From) == .int and @typeInfo(To) == .int) {
                d.* = @intCast(s);
            }
        }
    }

    pub fn processData(self: @This(), processor: anytype) void {
        const total = self.getSize();

        switch (self.dtype) {
            .i64 => {
                const data = @as([*]const i64, @alignCast(@ptrCast(self.ptr)))[0..total];
                processor(data);
            },
            .f64 => {
                const data = @as([*]const f64, @alignCast(@ptrCast(self.ptr)))[0..total];
                processor(data);
            },
            .usize => {
                const data = @as([*]const usize, @alignCast(@ptrCast(self.ptr)))[0..total];
                processor(data);
            },
        }
    }

    pub fn asBytes(self: @This()) []const u8 {
        const ptr_as_bytes: [*]const u8 = @ptrCast(self.ptr);
        return ptr_as_bytes[0..self.getSizeInBytes()];
    }

    pub fn print(self: @This()) void {
        const PrintFormatter = struct {
            pub fn format(data: anytype) void {
                std.debug.print("Constant: {any}\n", .{data});
            }
        };

        self.processData(PrintFormatter.format);
    }
};

pub const Sequential = []*RIROP;

pub const RIROP = union(enum) {
    add: struct { a: *RIROP, b: *RIROP },
    divide: struct { a: *RIROP, b: *RIROP },

    store: struct { source: *RIROP },
    copy: struct { from_device: usize, to_device: usize, from_addr: usize, to_addr: usize },

    sequential: Sequential,

    constant: Constant,

    pub fn getShape(self: RIROP) []const usize {
        return switch (self) {
            .add => |add| add.a.getShape(),
            .constant => |constant| return constant.shape,
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
            .constant => {
                var slice = allocator.alloc(*RIROP, 1) catch unreachable;
                slice[0] = self;
                return slice;
            },
            .store => |store| {
                return store.source.findInputs(allocator);
            },
            else => unreachable,
        };
    }
};
