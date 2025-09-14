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

pub const Device = union(enum) { host, device: usize };

pub const DType = enum {
    i32,
    i64,
    f32,
    f64,
    usize,

    pub fn getSizeInBytes(self: DType) usize {
        return switch (self) {
            .f32, .i32 => 4,
            .f64, .i64 => 8,
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

pub const Buffer = struct {
    ref: types.LLVMValueRef,
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

    position: union(enum) {
        local: enum { x, y, z },
        global: enum { x, y, z },
    },

    // need better names for these.
    // kernel is the finalized, linearized kernel that can be directly translated into backends
    // draft_kernel is simply a wrapper for grouping. it will be later transformed into a kernel
    draft_kernel: struct { ops: []*RIROP, params: []*RIROP },
    kernel: struct { ops: []*RIROP, dims: KernelDims, params: []*RIROP },
    param_addr,

    // bad, you have to load every single node to get the shape, TODO: figure out better way
    pub fn getShape(self: RIROP) []const usize {
        return switch (self) {
            .add => |add| add.a.getShape(),
            .copy => |copy| copy.src.getShape(),
            .store => |store| store.source.getShape(),
            .view => |view| view.shape,
            else => unreachable,
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
                var result = std.ArrayList(*RIROP).init(allocator);
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
            else => unreachable,
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
            .position => |pos| {
                cloned.* = RIROP{ .position = pos };
            },
            .draft_kernel => |draft| {
                const ops_clone = try allocator.alloc(*RIROP, draft.ops.len);
                for (draft.ops, 0..) |op, i| {
                    ops_clone[i] = try op.cloneWithRefs(allocator, clone_map);
                }

                const params_clone = try allocator.alloc(*RIROP, draft.params.len);
                for (draft.params, 0..) |param, i| {
                    params_clone[i] = try param.cloneWithRefs(allocator, clone_map);
                }

                cloned.* = RIROP{ .draft_kernel = .{ .ops = ops_clone, .params = params_clone } };
            },
            .kernel => |kernel| {
                const ops_clone = try allocator.alloc(*RIROP, kernel.ops.len);
                for (kernel.ops, 0..) |op, i| {
                    ops_clone[i] = try op.cloneWithRefs(allocator, clone_map);
                }

                const params_clone = try allocator.alloc(*RIROP, kernel.params.len);
                for (kernel.params, 0..) |param, i| {
                    params_clone[i] = try param.cloneWithRefs(allocator, clone_map);
                }

                cloned.* = RIROP{ .kernel = .{ .ops = ops_clone, .dims = kernel.dims, .params = params_clone } };
            },
            .param_addr => {
                cloned.* = RIROP{ .param_addr = {} };
            },
        }

        return cloned;
    }
};
