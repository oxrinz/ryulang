const std = @import("std");
const Allocator = std.mem.Allocator;
const rir = @import("rir/rir.zig");

pub const Stage = struct {
    title: []const u8,
    ops: []*rir.RIROP,
};

var debug_allocator = std.heap.DebugAllocator(.{}){};
var arena_instance = std.heap.ArenaAllocator.init(debug_allocator.allocator());
const allocator = arena_instance.allocator();

var stages = std.ArrayList(Stage).init(allocator);

const Node = struct { title: []const u8 };
const Edge = struct { source: usize, target: usize };

fn findAndLinkExternalDeps(
    op_ptr: *rir.RIROP,
    kernel_id: usize,
    nodes: *std.AutoHashMap(usize, Node),
    edges: *std.ArrayList(Edge),
    id_counter: *usize,
    alloc: Allocator,
    op_map: *std.AutoHashMap(*rir.RIROP, usize),
) anyerror!void {
    const op = op_ptr.*;
    switch (op) {
        .add => |add_op| {
            try findAndLinkExternalDeps(add_op.a, kernel_id, nodes, edges, id_counter, alloc, op_map);
            try findAndLinkExternalDeps(add_op.b, kernel_id, nodes, edges, id_counter, alloc, op_map);
        },
        .divide => |div_op| {
            try findAndLinkExternalDeps(div_op.a, kernel_id, nodes, edges, id_counter, alloc, op_map);
            try findAndLinkExternalDeps(div_op.b, kernel_id, nodes, edges, id_counter, alloc, op_map);
        },
        .load => |load_op| {
            try findAndLinkExternalDeps(load_op.source, kernel_id, nodes, edges, id_counter, alloc, op_map);
        },
        .store => |store_op| {
            try findAndLinkExternalDeps(store_op.source, kernel_id, nodes, edges, id_counter, alloc, op_map);
        },
        .buffer, .position => {
            const dep_id = try traverse(op_ptr, nodes, edges, id_counter, alloc, op_map);
            try edges.append(.{ .source = kernel_id, .target = dep_id });
        },
        .kernel => |kernel| {
            std.debug.print("WOAH: {any}\n", .{kernel.params});
            for (kernel.params) |param| {
                try findAndLinkExternalDeps(param, kernel_id, nodes, edges, id_counter, alloc, op_map);
            }
            const dep_id = try traverse(op_ptr, nodes, edges, id_counter, alloc, op_map);
            try edges.append(.{ .source = kernel_id, .target = dep_id });
        },
        .copy => |copy_op| {
            try findAndLinkExternalDeps(copy_op.src, kernel_id, nodes, edges, id_counter, alloc, op_map);
        },
        .view => |view_op| {
            try findAndLinkExternalDeps(view_op.src, kernel_id, nodes, edges, id_counter, alloc, op_map);
        },
        .draft_kernel => {
            const dep_id = try traverse(op_ptr, nodes, edges, id_counter, alloc, op_map);
            try edges.append(.{ .source = kernel_id, .target = dep_id });
        },
        else => {},
    }
}

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
        .load => try std.fmt.allocPrint(alloc, "Load", .{}),
        .store => try std.fmt.allocPrint(alloc, "Store", .{}),
        .copy => try std.fmt.allocPrint(alloc, "Copy", .{}),
        .buffer => try std.fmt.allocPrint(alloc, "Buffer, DType: {any}, Size: {d}", .{ op.buffer.dtype, op.buffer.size }),
        .view => try std.fmt.allocPrint(alloc, "View, Shape: {any}", .{op.view.shape}),
        .kernel => try std.fmt.allocPrint(alloc, "Kernel ({d} ops)", .{op.kernel.ops.len}),
        .position => |pos| switch (pos) {
            .local => |l| try std.fmt.allocPrint(alloc, "Position, Local: {s}", .{@tagName(l)}),
            .global => |g| try std.fmt.allocPrint(alloc, "Position, Global: {s}", .{@tagName(g)}),
        },
        else => "unimplemented op",
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
        .load => |load_op| {
            const source_id = try traverse(load_op.source, nodes, edges, id_counter, alloc, op_map);
            try edges.append(.{ .source = current_id, .target = source_id });
        },
        .store => |store_op| {
            const source_id = try traverse(store_op.source, nodes, edges, id_counter, alloc, op_map);
            try edges.append(.{ .source = current_id, .target = source_id });
        },
        .copy => |copy_op| {
            const source_id = try traverse(copy_op.src, nodes, edges, id_counter, alloc, op_map);
            try edges.append(.{ .source = current_id, .target = source_id });
        },
        .buffer => {},
        .view => |view_op| {
            const src_id = try traverse(view_op.src, nodes, edges, id_counter, alloc, op_map);
            try edges.append(.{ .source = current_id, .target = src_id });
        },
        .kernel => |kernel_op| {
            for (kernel_op.params) |param| {
                try findAndLinkExternalDeps(param, current_id, nodes, edges, id_counter, alloc, op_map);
            }
        },
        .position => {},
        else => {},
    }
    return current_id;
}

// TODO: fix !!
pub fn addStage(stage: Stage) !void {
    var mutable_stage = stage;
    var clone_map = std.AutoHashMap(*rir.RIROP, *rir.RIROP).init(allocator);
    defer clone_map.deinit();

    var cloned = std.ArrayList(*rir.RIROP).init(allocator);
    for (mutable_stage.ops) |op| {
        const cloned_op = try op.cloneWithRefs(allocator, &clone_map);
        try cloned.append(cloned_op);
    }
    mutable_stage.ops = try cloned.toOwnedSlice();
    try stages.append(mutable_stage);
}

fn prepareStages() anyerror![]const u8 {
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
    for (stages.items, 0..) |stage, stage_index| {
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
pub fn sendToDashboard() anyerror!void {
    const op_json = try prepareStages();
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
