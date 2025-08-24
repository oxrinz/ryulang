const std = @import("std");
const Allocator = std.mem.Allocator;

const rir = @import("rir/rir.zig");

pub fn sendToDashboard(allocator: Allocator, op_json: []const u8) anyerror!void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var buf: [4096]u8 = undefined;

    const uri = try std.Uri.parse("http://localhost:5173/");
    var req = try client.open(.POST, uri, .{ .server_header_buffer = &buf });
    defer req.deinit();

    const payload = op_json;
    req.transfer_encoding = .{ .content_length = payload.len };
    req.headers.content_type = .{ .override = "application/json" };

    try req.send();
    try req.writeAll(payload);
    try req.finish();
    try req.wait();
}

const Node = struct { title: []const u8 };
const Edge = struct { source: usize, target: usize };

fn traverse(
    op_ptr: *rir.RIROP,
    nodes: *std.AutoHashMap(usize, Node),
    edges: *std.ArrayList(Edge),
    id_counter: *usize,
    alloc: Allocator,
    op_map: *std.AutoHashMap(*rir.RIROP, usize),
) anyerror!usize {
    if (op_map.get(op_ptr)) |existing_id| {
        return existing_id;
    }

    const current_id = id_counter.*;
    id_counter.* += 1;

    try op_map.put(op_ptr, current_id);

    const op = op_ptr.*;

    const title: []const u8 = switch (op) {
        .add => try std.fmt.allocPrint(alloc, "Add", .{}),
        .divide => try std.fmt.allocPrint(alloc, "Divide", .{}),
        .constant => |const_op| try std.fmt.allocPrint(alloc, "Constant, Shape: {any}", .{const_op.shape}),
        else => {
            return 0;
        },
    };

    try nodes.put(current_id, .{ .title = title });

    switch (op) {
        .add => |add_op| {
            const a_id = try traverse(add_op.a, nodes, edges, id_counter, alloc, op_map);
            const b_id = try traverse(add_op.b, nodes, edges, id_counter, alloc, op_map);
            try edges.append(.{ .source = current_id, .target = a_id });
            try edges.append(.{ .source = current_id, .target = b_id });
        },
        .divide => |div_op| {
            const a_id = try traverse(div_op.a, nodes, edges, id_counter, alloc, op_map);
            const b_id = try traverse(div_op.b, nodes, edges, id_counter, alloc, op_map);
            try edges.append(.{ .source = current_id, .target = a_id });
            try edges.append(.{ .source = current_id, .target = b_id });
        },
        else => {},
    }

    return current_id;
}

pub const Stage = struct {
    title: []const u8,
    ops: []*rir.RIROP,
};

pub fn prepareStages(allocator: Allocator, stages: []const Stage) anyerror![]const u8 {
    const SerializableNode = struct { id: usize, title: []const u8 };
    const SerializableEdge = struct { source: usize, target: usize };

    const Config = struct {
        id: []const u8,
        title: []const u8,
        data: struct {
            nodes: []const SerializableNode,
            edges: []const SerializableEdge,
        },
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var configs = std.ArrayList(Config).init(allocator);
    defer configs.deinit();

    for (stages, 0..) |stage, stage_index| {
        var nodes = std.AutoHashMap(usize, Node).init(arena_allocator);
        defer nodes.deinit();

        var edges = std.ArrayList(Edge).init(arena_allocator);
        defer edges.deinit();

        var id_counter: usize = 0;
        var op_map = std.AutoHashMap(*rir.RIROP, usize).init(arena_allocator);
        defer op_map.deinit();

        for (stage.ops) |op| {
            _ = try traverse(op, &nodes, &edges, &id_counter, arena_allocator, &op_map);
        }

        var node_array = std.ArrayList(SerializableNode).init(allocator);
        defer node_array.deinit();
        var node_iter = nodes.iterator();
        while (node_iter.next()) |entry| {
            try node_array.append(.{ .id = entry.key_ptr.*, .title = entry.value_ptr.title });
        }

        var edge_array = std.ArrayList(SerializableEdge).init(allocator);
        defer edge_array.deinit();
        for (edges.items) |edge| {
            try edge_array.append(.{ .source = edge.source, .target = edge.target });
        }

        const stage_id = try std.fmt.allocPrint(allocator, "stage{d}", .{stage_index});

        try configs.append(Config{
            .id = stage_id,
            .title = stage.title,
            .data = .{
                .nodes = try node_array.toOwnedSlice(),
                .edges = try edge_array.toOwnedSlice(),
            },
        });
    }

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try std.json.stringify(configs.items, .{}, buffer.writer());
    return buffer.toOwnedSlice();
}
