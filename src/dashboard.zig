// NOTE: AI slop, but works

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
        .call => |call_op| try std.fmt.allocPrint(alloc, "Call: {s}", .{call_op.identifier}),
        .rand => try std.fmt.allocPrint(alloc, "Random", .{}),
        .constant => |const_op| try std.fmt.allocPrint(alloc, "Constant, Shape: {any}", .{const_op.shape}),
        .ret => try std.fmt.allocPrint(alloc, "Return", .{}),
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
        .call => |call_op| {
            for (call_op.args.*) |arg_ptr| {
                const arg_id = try traverse(arg_ptr, nodes, edges, id_counter, alloc, op_map);
                try edges.append(.{ .source = current_id, .target = arg_id });
            }
        },
        .rand => |rand_op| {
            const shape_id = try traverse(rand_op.shape, nodes, edges, id_counter, alloc, op_map);
            try edges.append(.{ .source = current_id, .target = shape_id });
        },
        .ret => |ret_op| {
            const op_id = try traverse(ret_op.op, nodes, edges, id_counter, alloc, op_map);
            try edges.append(.{ .source = current_id, .target = op_id });
        },
        .constant => {},
    }

    return current_id;
}

pub fn prepareOps(allocator: Allocator, op: *rir.RIROP) anyerror![]const u8 {
    var nodes = std.AutoHashMap(usize, Node).init(allocator);
    defer nodes.deinit();

    var edges = std.ArrayList(Edge).init(allocator);
    defer edges.deinit();

    var id_counter: usize = 0;

    var op_map = std.AutoHashMap(*rir.RIROP, usize).init(allocator);
    defer op_map.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    _ = try traverse(op, &nodes, &edges, &id_counter, arena_allocator, &op_map);

    const SerializableNode = struct { id: []const u8, title: []const u8 };
    var node_array = std.ArrayList(SerializableNode).init(allocator);
    defer node_array.deinit();
    var node_iter = nodes.iterator();
    while (node_iter.next()) |entry| {
        const id_str = try std.fmt.allocPrint(arena_allocator, "{}", .{entry.key_ptr.*});
        try node_array.append(.{ .id = id_str, .title = entry.value_ptr.title });
    }

    const SerializableEdge = struct { source: []const u8, target: []const u8 };
    var edge_array = std.ArrayList(SerializableEdge).init(allocator);
    defer edge_array.deinit();
    for (edges.items) |edge| {
        const source_str = try std.fmt.allocPrint(arena_allocator, "{}", .{edge.source});
        const target_str = try std.fmt.allocPrint(arena_allocator, "{}", .{edge.target});
        try edge_array.append(.{ .source = source_str, .target = target_str });
    }

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try std.json.stringify(.{
        .nodes = node_array.items,
        .edges = edge_array.items,
    }, .{}, buffer.writer());

    return buffer.toOwnedSlice();
}
