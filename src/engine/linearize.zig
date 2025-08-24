const std = @import("std");

const rir = @import("../rir/rir.zig");

pub fn linealize(ops_list: []*rir.RIROP, allocator: std.mem.Allocator) !rir.Sequential {
    var seq = std.ArrayList(*rir.RIROP).init(allocator);
    var visited = std.AutoHashMap(*rir.RIROP, void).init(allocator);
    defer visited.deinit();

    for (ops_list) |ops| {
        try linealize_recursive(ops, &seq, &visited, allocator);
    }

    return seq.toOwnedSlice();
}

fn linealize_recursive(ops: *rir.RIROP, seq: *std.ArrayList(*rir.RIROP), visited: *std.AutoHashMap(*rir.RIROP, void), allocator: std.mem.Allocator) !void {
    if (visited.contains(ops)) return;

    switch (ops.*) {
        .add => |add| {
            try linealize_recursive(add.a, seq, visited, allocator);
            try linealize_recursive(add.b, seq, visited, allocator);
            try seq.append(ops);
        },
        .divide => |divide| {
            try linealize_recursive(divide.a, seq, visited, allocator);
            try linealize_recursive(divide.b, seq, visited, allocator);
            try seq.append(ops);
        },
        .constant => {
            try seq.append(ops);
        },
        .sequential => |sequential| {
            for (sequential) |sub_op| {
                try linealize_recursive(sub_op, seq, visited, allocator);
            }
            try visited.put(ops, {});
            return;
        },
        .store => {
            try seq.append(ops);
        },
        else => @panic("Op not implemented in linearizer"),
    }

    try visited.put(ops, {});
}
