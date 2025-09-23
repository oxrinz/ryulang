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
const kir = @import("./kernel-ir.zig");
const DType = @import("./dtype.zig").DType;

pub const Device = union(enum) {
    host: ?types.LLVMValueRef,
    device: usize,
};

pub const Buffer = struct {
    device: Device,
    dtype: DType,
    size: usize,

    pub fn asBytes(self: @This()) []const u8 {
        const ptr_as_bytes: [*]const u8 = @ptrCast(self.ptr);
        return ptr_as_bytes[0..self.getSizeInBytes()];
    }

    pub fn getSizeInBytes(self: @This()) usize {
        return self.size * self.dtype.getSizeInBytes();
    }
};

pub const KernelDims = struct {
    local: struct { x: usize = 0, y: usize = 0, z: usize = 0 },
    global: struct { x: usize = 0, y: usize = 0, z: usize = 0 },
};

pub const RIROP = union(enum) {
    add: struct { a: *RIROP, b: *RIROP },
    divide: struct { a: *RIROP, b: *RIROP },

    load: struct { source: *RIROP },
    store: struct { source: *RIROP, buffer: *RIROP },
    copy: struct { dest: *RIROP, src: *RIROP },
    buffer: Buffer,
    view: struct { shape: []const usize, src: *RIROP },

    graph_kernel: kir.GraphKernel,
    linear_kernel: kir.LinearKernel,

    // bad, you have to load every single node to get the shape, TODO: figure out better way
    pub fn getShape(self: RIROP) []const usize {
        return switch (self) {
            .add => |add| add.a.getShape(),
            .copy => |copy| copy.src.getShape(),
            .store => |store| store.source.getShape(),
            .view => |view| view.shape,
            else => std.debug.panic("can't get shape through op: {any}\n", .{self}),
        };
    }

    // same thing here
    pub fn getDType(self: *RIROP) DType {
        return switch (self.*) {
            .add => |add| add.a.getDType(),
            .copy => |copy| copy.src.getDType(),
            .store => |store| store.source.getDType(),
            .view => |view| view.src.getDType(),
            .buffer => |buffer| buffer.dtype,
            else => std.debug.panic("can't get dtype through op: {any}\n", .{self}),
        };
    }

    pub fn getSizeInBytes(self: *RIROP, allocator: std.mem.Allocator) usize {
        const input = self.findInputs(allocator);
        return input[0].buffer.getSizeInBytes();
    }

    pub fn findInputs(self: *RIROP, allocator: std.mem.Allocator) []*RIROP {
        return switch (self.*) {
            .add => {
                const a_inputs = self.add.a.findInputs(allocator);
                const b_inputs = self.add.b.findInputs(allocator);
                var result = std.array_list.Managed(*RIROP).init(allocator);
                result.appendSlice(a_inputs) catch unreachable;
                result.appendSlice(b_inputs) catch unreachable;
                return result.toOwnedSlice() catch unreachable;
            },
            .buffer => {
                var slice = allocator.alloc(*RIROP, 1) catch unreachable;
                slice[0] = self;
                return slice;
            },
            .store => |store| {
                return store.source.findInputs(allocator);
            },
            .view => |view| {
                return view.src.findInputs(allocator);
            },
            else => std.debug.panic("can't find input through op: {any}\n", .{self.*}),
        };
    }

    pub fn cloneWithRefs(self: *RIROP, allocator: std.mem.Allocator, clone_map: *std.AutoHashMap(*RIROP, *RIROP)) !*RIROP {
        if (clone_map.get(self)) |existing_clone| {
            return existing_clone;
        }

        const cloned = try allocator.create(RIROP);
        try clone_map.put(self, cloned);

        switch (self.*) {
            .add => |add| {
                const a_clone = try add.a.cloneWithRefs(allocator, clone_map);
                const b_clone = try add.b.cloneWithRefs(allocator, clone_map);
                cloned.* = RIROP{ .add = .{ .a = a_clone, .b = b_clone } };
            },
            .divide => |divide| {
                const a_clone = try divide.a.cloneWithRefs(allocator, clone_map);
                const b_clone = try divide.b.cloneWithRefs(allocator, clone_map);
                cloned.* = RIROP{ .divide = .{ .a = a_clone, .b = b_clone } };
            },
            .load => |load| {
                const source_clone = try load.source.cloneWithRefs(allocator, clone_map);
                cloned.* = RIROP{ .load = .{ .source = source_clone } };
            },
            .store => |store| {
                const source_clone = try store.source.cloneWithRefs(allocator, clone_map);
                const buffer_clone = try store.buffer.cloneWithRefs(allocator, clone_map);
                cloned.* = RIROP{ .store = .{ .source = source_clone, .buffer = buffer_clone } };
            },
            .copy => |copy| {
                const src_clone = try copy.src.cloneWithRefs(allocator, clone_map);
                const dest_clone = try copy.dest.cloneWithRefs(allocator, clone_map);
                cloned.* = RIROP{ .copy = .{ .dest = dest_clone, .src = src_clone } };
            },
            .buffer => |buffer| {
                cloned.* = RIROP{ .buffer = buffer };
            },
            .view => |view| {
                const src_clone = try view.src.cloneWithRefs(allocator, clone_map);
                const shape_clone = try allocator.dupe(usize, view.shape);
                cloned.* = RIROP{ .view = .{ .shape = shape_clone, .src = src_clone } };
            },
            .graph_kernel => |gk| {
                cloned.* = RIROP{ .graph_kernel = gk };
            },
            .linear_kernel => |lk| {
                cloned.* = RIROP{ .linear_kernel = lk };
            },
        }

        return cloned;
    }
};
