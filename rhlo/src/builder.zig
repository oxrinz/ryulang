const std = @import("std");

const nodes = @import("nodes.zig");

pub const Builder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
        };
    }

    pub fn compile() nodes.RHLOProgram {}
};
