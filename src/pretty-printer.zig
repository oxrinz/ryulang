const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");

pub fn prettyPrintModule(allocator: Allocator, writer: anytype, module: *const ast.Module, indent: usize) !void {
    try writer.writeAll("Module {\n");
    try prettyPrintBlock(allocator, writer, &module.block, indent + 2);
    try writer.writeByteNTimes(' ', indent);
    try writer.writeAll("}\n");
}

pub fn prettyPrintBlock(allocator: Allocator, writer: anytype, block: *const ast.Block, indent: usize) anyerror!void {
    try writer.writeByteNTimes(' ', indent);
    try writer.writeAll("Block {\n");

    for (block.items) |statement| {
        try prettyPrintStatement(allocator, writer, statement, indent + 2);
    }

    try writer.writeByteNTimes(' ', indent);
    try writer.writeAll("}\n");
}

pub fn prettyPrintStatement(allocator: Allocator, writer: anytype, statement: ast.Statement, indent: usize) !void {
    try writer.writeByteNTimes(' ', indent);

    switch (statement) {
        .expr => |expr| {
            try writer.writeAll("Statement.expr:\n");
            try prettyPrintExpression(allocator, writer, expr, indent + 2);
        },
        .assign => |assign| {
            try writer.writeAll("Statement.assign:\n");
            try prettyPrintAssign(allocator, writer, assign, indent + 2);
        },
        .compound => |compound| {
            try writer.writeAll("Statement.compound:\n");
            try prettyPrintStatement(allocator, writer, compound.*, indent + 2);
        },
        .function_definition => |func| {
            try writer.writeAll("Statement.function_definition:\n");
            try prettyPrintFunctionDefinition(allocator, writer, func, indent + 2);
        },
    }
}

pub fn prettyPrintFunctionDefinition(allocator: Allocator, writer: anytype, func: ast.FunctionDefinition, indent: usize) !void {
    try writer.writeByteNTimes(' ', indent);
    try writer.print("FunctionDefinition.identifier: {s} (Type: {s})\n", .{ func.identifier, @tagName(func.type) });

    try writer.writeByteNTimes(' ', indent);
    try writer.print("FunctionDefinition.returns: {any}\n", .{func.returns});

    try writer.writeByteNTimes(' ', indent);
    try writer.writeAll("FunctionDefinition.args:\n");

    for (func.args, 0..) |arg, i| {
        try writer.writeByteNTimes(' ', indent + 2);
        try writer.print("Arg[{}]:\n", .{i});
        try prettyPrintExpression(allocator, writer, arg.*, indent + 4);
    }

    try writer.writeByteNTimes(' ', indent);
    try writer.writeAll("FunctionDefinition.body:\n");
    try prettyPrintBlock(allocator, writer, &func.body, indent + 2);
}

pub fn prettyPrintAssign(allocator: Allocator, writer: anytype, assign: ast.Assign, indent: usize) !void {
    try writer.writeByteNTimes(' ', indent);
    try writer.print("Assign.target: {s}\n", .{assign.target});

    try writer.writeByteNTimes(' ', indent);
    try writer.writeAll("Assign.value:\n");
    try prettyPrintExpression(allocator, writer, assign.value, indent + 2);
}

pub fn prettyPrintExpression(allocator: Allocator, writer: anytype, expression: ast.Expression, indent: usize) anyerror!void {
    try writer.writeByteNTimes(' ', indent);

    switch (expression) {
        .constant => |constant| {
            try writer.writeAll("Expression.constant: ");
            switch (constant) {
                .Integer => |i| try writer.print("Integer({})\n", .{i}),
                .Float => |f| try writer.print("Float({})\n", .{f}),
                .String => |s| try writer.print("String(\"{s}\")\n", .{s}),
            }
        },
        .binary => |binary| {
            try writer.writeAll("Expression.binary:\n");
            try prettyPrintBinary(allocator, writer, binary, indent + 2);
        },
        .variable => |variable| {
            try writer.print("Expression.variable: {s} (Type: {s})\n", .{ variable.identifier, @tagName(variable.type) });
        },
        .call => |call| {
            try writer.writeAll("Expression.call:\n");
            try prettyPrintCall(allocator, writer, call, indent + 2);
        },
    }
}

pub fn prettyPrintBinary(allocator: Allocator, writer: anytype, binary: ast.Binary, indent: usize) !void {
    const op_str = switch (binary.operator) {
        .Add => "Add",
        .Subtract => "Subtract",
        .Multiply => "Multiply",
        .Divide => "Divide",
        .Remainder => "Remainder",
        .Bitwise_AND => "Bitwise_AND",
        .Bitwise_OR => "Bitwise_OR",
        .Bitwise_XOR => "Bitwise_XOR",
        .Left_Shift => "Left_Shift",
        .Right_Shift => "Right_Shift",
        .Less => "Less",
        .Less_Or_Equal => "Less_Or_Equal",
        .Greater => "Greater",
        .Greater_Or_Equal => "Greater_Or_Equal",
        .Equal => "Equal",
        .Not_Equal => "Not_Equal",
        .And => "And",
        .Or => "Or",
    };

    const op_type = @tagName(binary.operator.getType());

    try writer.writeByteNTimes(' ', indent);
    try writer.print("Binary.operator: {s} (Type: {s})\n", .{ op_str, op_type });

    try writer.writeByteNTimes(' ', indent);
    try writer.writeAll("Binary.left:\n");
    try prettyPrintExpression(allocator, writer, binary.left.*, indent + 2);

    try writer.writeByteNTimes(' ', indent);
    try writer.writeAll("Binary.right:\n");
    try prettyPrintExpression(allocator, writer, binary.right.*, indent + 2);
}

pub fn prettyPrintCall(allocator: Allocator, writer: anytype, call: ast.Call, indent: usize) !void {
    try writer.writeByteNTimes(' ', indent);
    try writer.print("Call.identifier: {s} (Type: {s})\n", .{ call.identifier, @tagName(call.type) });

    try writer.writeByteNTimes(' ', indent);
    try writer.print("Call.builtin: {}\n", .{call.builtin});

    try writer.writeByteNTimes(' ', indent);
    try writer.writeAll("Call.args:\n");

    for (call.args, 0..) |arg, i| {
        try writer.writeByteNTimes(' ', indent + 2);
        try writer.print("Arg[{}]:\n", .{i});
        try prettyPrintExpression(allocator, writer, arg.*, indent + 4);
    }
}

pub fn printAst(allocator: Allocator, module: *const ast.Module) anyerror!void {
    const stdout = std.io.getStdOut().writer();
    try prettyPrintModule(allocator, stdout, module, 0);
}

pub fn astToString(allocator: Allocator, module: *const ast.Module) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    const writer = list.writer();
    try prettyPrintModule(allocator, writer, module, 0);

    return list.toOwnedSlice();
}

pub fn createTestAst(allocator: Allocator) !ast.Module {
    const left_expr = try allocator.create(ast.Expression);
    left_expr.* = ast.Expression{ .constant = .{ .Integer = 5 } };

    const right_expr = try allocator.create(ast.Expression);
    right_expr.* = ast.Expression{ .constant = .{ .Integer = 10 } };

    const binary = ast.Binary{
        .operator = ast.BinaryOperator.Add,
        .left = left_expr,
        .right = right_expr,
    };

    const expr = ast.Expression{ .binary = binary };

    const assign_value = ast.Expression{ .constant = .{ .Integer = 42 } };
    const assign = ast.Assign{
        .target = "x",
        .value = assign_value,
    };

    const variable_expr = ast.Expression{ .variable = .{ .identifier = "y", .type = .Host } };

    const arg1 = try allocator.create(ast.Expression);
    arg1.* = ast.Expression{ .constant = .{ .Integer = 1 } };

    const arg2 = try allocator.create(ast.Expression);
    arg2.* = ast.Expression{ .variable = .{ .identifier = "z", .type = .Host } };

    var args = try allocator.alloc(*ast.Expression, 2);
    args[0] = arg1;
    args[1] = arg2;

    const call = ast.Call{
        .identifier = "foo",
        .args = args,
        .type = .Host,
    };

    const call_expr = ast.Expression{ .call = call };

    // Create a function definition
    const func_arg = try allocator.create(ast.Expression);
    func_arg.* = ast.Expression{ .variable = .{ .identifier = "param", .type = .Host } };

    var func_args = try allocator.alloc(*ast.Expression, 1);
    func_args[0] = func_arg;

    var func_body_items = try allocator.alloc(ast.Statement, 1);
    func_body_items[0] = ast.Statement{ .expr = variable_expr };

    const func_def = ast.FunctionDefinition{
        .identifier = "myFunc",
        .args = func_args,
        .type = .Host,
        .body = ast.Block{ .items = func_body_items },
        .returns = true,
    };

    // Create a compound statement
    const compound_stmt = try allocator.create(ast.Statement);
    compound_stmt.* = ast.Statement{ .assign = assign };

    var items = try allocator.alloc(ast.Statement, 6);
    items[0] = ast.Statement{ .expr = expr };
    items[1] = ast.Statement{ .assign = assign };
    items[2] = ast.Statement{ .expr = variable_expr };
    items[3] = ast.Statement{ .expr = call_expr };
    items[4] = ast.Statement{ .function_definition = func_def };
    items[5] = ast.Statement{ .compound = compound_stmt };

    return ast.Module{
        .block = ast.Block{
            .items = items,
        },
    };
}
