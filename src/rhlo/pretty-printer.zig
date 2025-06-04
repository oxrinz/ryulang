const std = @import("std");
const nodes = @import("nodes.zig");

pub fn prettyPrint(program: nodes.RHLOProgram, file_path: []const u8) !void {
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    const writer = file.writer();

    try writer.writeAll("Tensors:\n");
    for (program.tensor_store.items, 0..) |tensor, i| {
        try writer.print("  {}. [", .{i});
        for (tensor.dimensions, 0..) |dim, j| {
            try writer.print("{}", .{dim});
            if (j < tensor.dimensions.len - 1) try writer.writeAll(", ");
        }
        try writer.print("], {s}\n", .{@tagName(tensor.dtype)});
    }

    try writer.writeAll("Operations:\n");
    for (program.ops.items, 0..) |op, i| {
        try writer.print("  {}. {s}, inputs: [", .{ i, @tagName(op.kind) });
        for (op.input_ids, 0..) |id, j| {
            try writer.print("{}", .{id});
            if (j < op.input_ids.len - 1) try writer.writeAll(", ");
        }
        try writer.print("], outputs: [", .{});
        for (op.output_ids, 0..) |id, j| {
            try writer.print("{}", .{id});
            if (j < op.output_ids.len - 1) try writer.writeAll(", ");
        }
        try writer.writeAll("]\n");
    }

    try writer.writeAll("Parameters:\n");
    for (program.params.items, 0..) |param, i| {
        try writer.print("  {}. id: {}, input: {}, output: {}\n", .{ i, param.id, param.input, param.output });
    }
}
