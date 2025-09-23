const std = @import("std");

const rir = @import("rir.zig");
const RIROP = rir.RIROP;

const binopPat = struct {
    a: *Pattern,
    b: *Pattern,
};

pub const Pattern = union(enum) {
    add: ?binopPat,
    divide: ?binopPat,
    load: struct { source: *Pattern },
    store: struct { source: *Pattern, buffer: *Pattern },
    copy: struct { dest: *Pattern, src: *Pattern },
    view: ?struct { shape: ?[]const usize, src: *Pattern },

    graph_kernel,

    any,

    buffer: ?rir.Buffer,

    binop: ?union(enum) {
        add: ?binopPat,
        div: ?binopPat,
    },
};

pub fn match(allocator: std.mem.Allocator, pattern: *Pattern, ops: []*RIROP) ![]*RIROP {
    var matcher = PatternMatcher.init(allocator);
    return try matcher.match(pattern, ops);
}

const PatternMatcher = struct {
    allocator: std.mem.Allocator,
    captured_ops: std.array_list.Managed(*RIROP),
    matched_ops: std.array_list.Managed(*RIROP),

    fn init(allocator: std.mem.Allocator) PatternMatcher {
        return PatternMatcher{
            .allocator = allocator,
            .captured_ops = std.array_list.Managed(*RIROP).init(allocator),
            .matched_ops = std.array_list.Managed(*RIROP).init(allocator),
        };
    }

    fn match(self: *PatternMatcher, pattern: *Pattern, ops: []*RIROP) ![]*RIROP {
        defer self.captured_ops.deinit();

        for (ops) |op| {
            try self.matchRecursive(pattern, op);
        }

        return try self.matched_ops.toOwnedSlice();
    }

    fn matchRecursive(self: *PatternMatcher, pattern: *Pattern, op: *RIROP) !void {
        for (self.captured_ops.items) |captured_op| {
            if (op == captured_op) return;
        }

        try self.captured_ops.append(op);

        switch (op.*) {
            .add => |add| {
                if (pattern.* == .add) {
                    if (pattern.add == null) try self.matched_ops.append(op) else @panic("complex patterns not implemented in pm yet");
                }
                try self.matchRecursive(pattern, add.a);
                try self.matchRecursive(pattern, add.b);
            },

            .view => |view| {
                if (pattern.* == .view) {
                    if (pattern.view == null) try self.matched_ops.append(op) else @panic("complex patterns not implemented in pm yet");
                }
                try self.matchRecursive(pattern, view.src);
            },
            .buffer => {},
            .graph_kernel => |graph_kernel| {
                _ = graph_kernel;
                if (pattern.* == .graph_kernel) try self.matched_ops.append(op);
            },

            else => std.debug.panic("op {any} not implemented in pm", .{@intFromEnum(op.*)}),
        }
    }
};
