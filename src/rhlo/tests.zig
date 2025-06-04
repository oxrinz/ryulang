const std = @import("std");

const pretty_printer = @import("pretty-printer.zig");
const nodes = @import("nodes.zig");
const Builder = @import("builder.zig").Builder;

const execute = @import("root.zig").execute;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

test "add" {
    var builder = Builder.init(arena.allocator());
    const dtype = nodes.DataType.F32;
    const shape: nodes.Shape = &[_]usize{ 2, 2 };
    const param0 = try builder.createParameter(dtype, shape);
    const param1 = try builder.createParameter(dtype, shape);

    const result = try builder.opAdd(param0, param1);
    try builder.createParameterFromRef(result);

    var input1 = try arena.allocator().alloc(f32, 4);
    input1[0] = 3.0;
    input1[1] = 2.0;
    input1[2] = 3.0;
    input1[3] = 4.0;
    var input2 = try arena.allocator().alloc(f32, 4);
    input2[0] = 9.5;
    input2[1] = 2.0;
    input2[2] = 3.0;
    input2[3] = 4.0;
    const output = try arena.allocator().alloc(f32, 4);

    var params = [_]*void{ @ptrCast(input1.ptr), @ptrCast(input2.ptr), @ptrCast(output.ptr) };

    try execute(
        builder.program,
        &params,
    );

    try std.testing.expect(output[0] == 12.5);
    try std.testing.expect(output[1] == 4);
    try std.testing.expect(output[2] == 6);
    try std.testing.expect(output[3] == 8);
}

test "chained add" {
    var builder = Builder.init(arena.allocator());
    const dtype = nodes.DataType.F32;
    const shape: nodes.Shape = &[_]usize{ 2, 2 };
    const param0 = try builder.createParameter(dtype, shape);
    const param1 = try builder.createParameter(dtype, shape);

    const intermediate_result = try builder.opAdd(param0, param1);
    const result = try builder.opAdd(intermediate_result, param1);
    try builder.createParameterFromRef(result);

    var input1 = try arena.allocator().alloc(f32, 4);
    input1[0] = 3.0;
    input1[1] = 2.0;
    input1[2] = 3.0;
    input1[3] = 4.0;
    var input2 = try arena.allocator().alloc(f32, 4);
    input2[0] = 9.5;
    input2[1] = 2.0;
    input2[2] = 3.0;
    input2[3] = 4.0;
    const output = try arena.allocator().alloc(f32, 4);

    var params = [_]*void{ @ptrCast(input1.ptr), @ptrCast(input2.ptr), @ptrCast(output.ptr) };

    try execute(
        builder.program,
        &params,
    );

    try std.testing.expect(output[0] == 22);
    try std.testing.expect(output[1] == 6);
    try std.testing.expect(output[2] == 9);
    try std.testing.expect(output[3] == 12);
}

// TODO: fix numerical inaccuracy in these tests
test "chained 2x2 gemm" {
    var builder = Builder.init(arena.allocator());
    const dtype = nodes.DataType.F32;
    const shape: nodes.Shape = &[_]usize{ 2, 2 };
    const param0 = try builder.createParameter(dtype, shape);
    const param1 = try builder.createParameter(dtype, shape);

    const intermediate_result = try builder.opMatmul(param0, param1);
    const result = try builder.opMatmul(intermediate_result, param1);
    try builder.createParameterFromRef(result);

    var input1 = try arena.allocator().alloc(f32, 4);
    input1[0] = 0.5;
    input1[1] = 2.0;
    input1[2] = 3.0;
    input1[3] = 2.0;
    var input2 = try arena.allocator().alloc(f32, 4);
    input2[0] = 1.5;
    input2[1] = 2.0;
    input2[2] = 0.3;
    input2[3] = 0.2;
    const output = try arena.allocator().alloc(f32, 4);

    var params = [_]*void{ @ptrCast(input1.ptr), @ptrCast(input2.ptr), @ptrCast(output.ptr) };

    try execute(
        builder.program,
        &params,
    );

    const rounded_output = [_]f32{
        roundTo3DecimalPlaces(output[0]),
        roundTo3DecimalPlaces(output[1]),
        roundTo3DecimalPlaces(output[2]),
        roundTo3DecimalPlaces(output[3]),
    };

    try std.testing.expect(rounded_output[0] == 2.445);
    try std.testing.expect(rounded_output[1] == 2.98);
    try std.testing.expect(rounded_output[2] == 9.57);
    try std.testing.expect(rounded_output[3] == 11.48);
}

test "chained 2x2 gemm 2" {
    var builder = Builder.init(arena.allocator());
    const dtype = nodes.DataType.F32;
    const shape: nodes.Shape = &[_]usize{ 2, 2 };
    const param0 = try builder.createParameter(dtype, shape);
    const param1 = try builder.createParameter(dtype, shape);

    const intermediate_result = try builder.opMatmul(param0, param1);
    const result = try builder.opMatmul(param1, intermediate_result);
    try builder.createParameterFromRef(result);

    var input1 = try arena.allocator().alloc(f32, 4);
    input1[0] = 0.5;
    input1[1] = 2.0;
    input1[2] = 3.0;
    input1[3] = 2.0;
    var input2 = try arena.allocator().alloc(f32, 4);
    input2[0] = 1.5;
    input2[1] = 2.0;
    input2[2] = 0.3;
    input2[3] = 0.2;
    const output = try arena.allocator().alloc(f32, 4);

    var params = [_]*void{ @ptrCast(input1.ptr), @ptrCast(input2.ptr), @ptrCast(output.ptr) };

    try execute(
        builder.program,
        &params,
    );

    const rounded_output = [_]f32{
        roundTo3DecimalPlaces(output[0]),
        roundTo3DecimalPlaces(output[1]),
        roundTo3DecimalPlaces(output[2]),
        roundTo3DecimalPlaces(output[3]),
    };

    try std.testing.expect(rounded_output[0] == 12.225);
    try std.testing.expect(rounded_output[1] == 14.9);
    try std.testing.expect(rounded_output[2] == 1.425);
    try std.testing.expect(rounded_output[3] == 1.7);
}

test "2x3 gemm " {
    var builder = Builder.init(arena.allocator());
    const dtype = nodes.DataType.F32;
    const shape0: nodes.Shape = &[_]usize{ 2, 3 };
    const shape1: nodes.Shape = &[_]usize{ 3, 2 };
    const param0 = try builder.createParameter(dtype, shape0);
    const param1 = try builder.createParameter(dtype, shape1);

    const result = try builder.opMatmul(param0, param1);
    try builder.createParameterFromRef(result);

    var input1 = try arena.allocator().alloc(f32, 6);
    input1[0] = 0.5;
    input1[1] = 2.0;
    input1[2] = 3.0;
    input1[3] = 3.5;
    input1[4] = 1.5;
    input1[5] = 2.5;
    var input2 = try arena.allocator().alloc(f32, 6);
    input2[0] = 1.5;
    input2[1] = 2.0;
    input2[2] = 0.3;
    input2[3] = 0.2;
    input2[4] = 0.8;
    input2[5] = 1.2;
    const output = try arena.allocator().alloc(f32, 4);

    var params = [_]*void{ @ptrCast(input1.ptr), @ptrCast(input2.ptr), @ptrCast(output.ptr) };

    try execute(
        builder.program,
        &params,
    );

    // try pretty_printer.prettyPrint(builder.program, "hi.rhlo");

    const rounded_output = [_]f32{
        roundTo3DecimalPlaces(output[0]),
        roundTo3DecimalPlaces(output[1]),
        roundTo3DecimalPlaces(output[2]),
        roundTo3DecimalPlaces(output[3]),
    };

    // std.debug.print("fuck!\nfirst: {d}\n", .{output[0]});
    // std.debug.print("second: {d}\n", .{output[1]});
    // std.debug.print("third: {d}\n", .{output[2]});
    // std.debug.print("fourth: {d}\n", .{output[3]});

    try std.testing.expect(rounded_output[0] == 3.75);
    try std.testing.expect(rounded_output[1] == 5.0);
    try std.testing.expect(rounded_output[2] == 7.7);
    try std.testing.expect(rounded_output[3] == 10.3);
}

fn roundTo3DecimalPlaces(value: f32) f32 {
    return @floatCast(@round(@as(f32, @floatCast(value)) * 1000.0) / 1000.0);
}
