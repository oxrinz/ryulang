const std = @import("std");
const ptxast = @import("./ast.zig");

pub fn emit(allocator: std.mem.Allocator, ast: ptxast.PTXAst) ![]const u8 {
    if (ast.kernels.len == 0) {
        return error.NoKernels;
    }
    var ptx = std.ArrayList(u8).init(allocator);
    defer ptx.deinit();
    var writer = ptx.writer();
    var operand_buffer: [64]u8 = undefined;

    try writer.writeAll(
        \\.version 8.4
        \\.target sm_52
        \\.address_size 64
    );
    const kernel = ast.kernels[0];
    try writer.writeAll("\n.visible .entry main(\n");
    for (kernel.params, 0..) |param, i| {
        try writer.print(" .param .u64 {s}{s}\n", .{ param, if (i < kernel.params.len - 1) "," else "" });
    }
    try writer.writeAll(")\n{\n");
    for (kernel.directives) |directive| {
        switch (directive) {
            .reg => |reg| {
                try writer.print(" .reg .{s} {s}<{d}>;\n", .{ reg.type.toString(), reg.name, reg.count });
            },
            .global => |global| {
                try writer.print(" .global .{s} {s}[{d}];\n", .{ global.type.toString(), global.name, global.size });
            },
        }
    }
    try writer.writeAll("\n");
    for (kernel.body) |instruction| {
        switch (instruction) {
            .add => |add| {
                try writer.print(" add{s}.{s} {s}, {s}, {s};\n", .{
                    add.modifier.toString(),
                    add.type.toString(),
                    emitOperand(add.dest, &operand_buffer),
                    emitOperand(add.src1, &operand_buffer),
                    emitOperand(add.src2, &operand_buffer),
                });
            },
            .mul => |mul| {
                try writer.print(" mul{s}.{s} {s}, {s}, {s};\n", .{
                    mul.modifier.toString(),
                    mul.type.toString(),
                    emitOperand(mul.dest, &operand_buffer),
                    emitOperand(mul.src1, &operand_buffer),
                    emitOperand(mul.src2, &operand_buffer),
                });
            },
            ._and => |_and| {
                try writer.print(" and.{s} {s}, {s}, {s};\n", .{
                    _and.type.toString(),
                    emitOperand(_and.dest, &operand_buffer),
                    emitOperand(_and.src1, &operand_buffer),
                    emitOperand(_and.src2, &operand_buffer),
                });
            },
            .mov => |mov| {
                try writer.print(" mov.{s} {s}, {s};\n", .{
                    mov.type.toString(),
                    emitOperand(mov.dest, &operand_buffer),
                    emitOperand(mov.src, &operand_buffer),
                });
            },
            .shl => |shl| {
                try writer.print(" shl.{s} {s}, {s}, {s};\n", .{
                    shl.type.toString(),
                    emitOperand(shl.dest, &operand_buffer),
                    emitOperand(shl.src1, &operand_buffer),
                    emitOperand(shl.src2, &operand_buffer),
                });
            },
            .ld => |ld| {
                try writer.print(" ld.{s}.{s} {s}, [{s}];\n", .{
                    ld.space.toString(),
                    ld.type.toString(),
                    emitOperand(ld.dest, &operand_buffer),
                    emitOperand(ld.src, &operand_buffer),
                });
            },
            .st => |st| {
                try writer.print(" st.{s}.{s} [{s}], {s};\n", .{
                    st.space.toString(),
                    st.type.toString(),
                    emitOperand(st.dest, &operand_buffer),
                    emitOperand(st.src, &operand_buffer),
                });
            },
            .cvta => |cvta| {
                try writer.print(" cvta{s}.{s}.{s} {s}, {s};\n", .{
                    if (cvta.to_generic) ".to" else "",
                    cvta.space.toString(),
                    cvta.type.toString(),
                    emitOperand(cvta.dest, &operand_buffer),
                    emitOperand(cvta.src, &operand_buffer),
                });
            },
            .fma => |fma| {
                try writer.print(" mad{s}.{s} {s}, {s}, {s}, {s};\n", .{
                    fma.modifier.toString(),
                    fma.type.toString(),
                    emitOperand(fma.dest, &operand_buffer),
                    emitOperand(fma.src1, &operand_buffer),
                    emitOperand(fma.src2, &operand_buffer),
                    emitOperand(fma.src3, &operand_buffer),
                });
            },
            .shfl => |shfl| {
                try writer.print(" shfl.sync.{s}.{s} {s}, {s}, {s}, {s}, {s};\n", .{
                    shfl.mode.toString(),
                    shfl.type.toString(),
                    emitOperand(shfl.dest, &operand_buffer),
                    emitOperand(shfl.src, &operand_buffer),
                    emitOperand(shfl.offset_or_source, &operand_buffer),
                    emitOperand(shfl.lane_mask, &operand_buffer),
                    emitOperand(shfl.mask, &operand_buffer),
                });
            },
            .setp => |setp| {
                try writer.print(" setp.{s}.{s} {s}, {s}, {s};\n", .{
                    setp.cmp.toString(),
                    setp.type.toString(),
                    setp.dest,
                    emitOperand(setp.src1, &operand_buffer),
                    emitOperand(setp.src2, &operand_buffer),
                });
            },
            .label => |label| {
                try writer.print("{s}:\n", .{label.name});
            },
            .comment => |comment| {
                try writer.print(" // {s}\n", .{comment});
            },
            .ret => try writer.writeAll(" ret;\n"),
            .bra => |bra| {
                try writer.print(" bra.uni {s}, {s};\n", .{ bra.predicate.?.register, bra.label });
            },
        }
    }
    try writer.writeAll("}\n");
    return try ptx.toOwnedSlice();
}

fn emitOperand(operand: ptxast.Operand, buffer: []u8) []const u8 {
    return switch (operand) {
        .register => |reg| reg,
        .parameter => |param| param,
        .immediate => |imm| switch (imm) {
            .integer => |value| std.fmt.bufPrint(buffer, "{any}", .{value}) catch {
                @panic("Buffer too small for integer immediate");
            },
            .float => |value| std.fmt.bufPrint(buffer, "{:.6}", .{value}) catch {
                @panic("Buffer too small for float immediate");
            },
        },
        .memory => |mem| std.fmt.bufPrint(buffer, "[{any}]", .{mem.address}) catch {
            @panic("Buffer too small for memory reference");
        },
    };
}
