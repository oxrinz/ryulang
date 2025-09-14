const std = @import("std");

// Assuming your RIROP and related types are imported/available
const rir = @import("rir.zig");
const RIROP = rir.RIROP;

pub const Pattern = union(enum) {
    // Exact matches
    add: struct { a: *Pattern, b: *Pattern },
    divide: struct { a: *Pattern, b: *Pattern },
    load: struct { source: *Pattern },
    store: struct { source: *Pattern, buffer: *Pattern },
    copy: struct { dest: *Pattern, src: *Pattern },
    view: struct { shape: ?[]const usize, src: *Pattern },

    // Wildcards
    any, // matches any single node

    // Specific value matches
    buffer: ?rir.Buffer,
    position: ?union(enum) {
        local: enum { x, y, z },
        global: enum { x, y, z },
    },
    param_addr,
};

pub const MatchResult = struct {
    matched: bool,
    captured: []const *RIROP, // All the ops that matched

    pub fn deinit(self: *MatchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.captured);
    }
};

pub fn match(allocator: std.mem.Allocator, pattern: *Pattern, target: *RIROP) !MatchResult {
    var matcher = PatternMatcher.init(allocator);
    return try matcher.match(pattern, target);
}

const PatternMatcher = struct {
    allocator: std.mem.Allocator,
    captured_ops: std.ArrayList(*RIROP),

    fn init(allocator: std.mem.Allocator) PatternMatcher {
        return PatternMatcher{
            .allocator = allocator,
            .captured_ops = std.ArrayList(*RIROP).init(allocator),
        };
    }

    fn match(self: *PatternMatcher, pattern: *Pattern, target: *RIROP) !MatchResult {
        defer self.captured_ops.deinit();

        const matched = try self.matchRecursive(pattern, target);

        return MatchResult{
            .matched = matched,
            .captured = if (matched) try self.captured_ops.toOwnedSlice() else &[_]*RIROP{},
        };
    }

    fn matchRecursive(self: *PatternMatcher, pattern: *Pattern, target: *RIROP) !bool {
        // Capture every op that gets matched
        try self.captured_ops.append(target);

        switch (pattern.*) {
            .any => return true,

            .add => |padd| {
                if (target.* != .add) return false;
                const tadd = target.add;
                return (try self.matchRecursive(padd.a, tadd.a)) and
                    (try self.matchRecursive(padd.b, tadd.b));
            },

            .divide => |pdiv| {
                if (target.* != .divide) return false;
                const tdiv = target.divide;
                return (try self.matchRecursive(pdiv.a, tdiv.a)) and
                    (try self.matchRecursive(pdiv.b, tdiv.b));
            },

            .load => |pload| {
                if (target.* != .load) return false;
                return try self.matchRecursive(pload.source, target.load.source);
            },

            .store => |pstore| {
                if (target.* != .store) return false;
                const tstore = target.store;
                return (try self.matchRecursive(pstore.source, tstore.source)) and
                    (try self.matchRecursive(pstore.buffer, tstore.buffer));
            },

            .copy => |pcopy| {
                if (target.* != .copy) return false;
                const tcopy = target.copy;
                return (try self.matchRecursive(pcopy.dest, tcopy.dest)) and
                    (try self.matchRecursive(pcopy.src, tcopy.src));
            },

            .view => |pview| {
                if (target.* != .view) return false;
                const tview = target.view;

                if (pview.shape) |shape| {
                    if (tview.shape.len != shape.len) return false;
                    for (shape, 0..) |dim, i| {
                        if (tview.shape[i] != dim) return false;
                    }
                }

                return try self.matchRecursive(pview.src, tview.src);
            },

            .buffer => |pbuf| {
                if (target.* != .buffer) return false;
                return pbuf == null; // wildcard or exact match
            },

            .position => |ppos| {
                if (target.* != .position) return false;
                if (ppos == null) return true;

                switch (ppos.?) {
                    .local => |local_val| {
                        return target.position == .local and
                            @intFromEnum(target.position.local) == @intFromEnum(local_val);
                    },
                    .global => |global_val| {
                        return target.position == .global and
                            @intFromEnum(target.position.global) == @intFromEnum(global_val);
                    },
                }
            },

            .param_addr => {
                return target.* == .param_addr;
            },
        }
    }
};
