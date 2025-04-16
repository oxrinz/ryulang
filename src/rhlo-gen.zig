const std = @import("std");
const ast = @import("ast.zig");
const rhlo = @import("rhlo");

const RHLOGen = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RHLOGen {
        return .{
            .allocator = allocator,
        };
    }

    // pub fn generate(self: *RHLOGen, module: ast.Module) rhlo.Node {}
};
