const std = @import("std");

const llvm = @import("llvm");
const target = llvm.target;
const target_machine_mod = llvm.target_machine;
const types = llvm.types;
const core = llvm.core;
const execution = llvm.engine;

const nodes = @import("nodes.zig");
pub const buffers = @import("buffers.zig");
const Builder = @import("builder.zig").Builder;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub fn execute(program: nodes.RHLOProgram, input_buffer: buffers.RHLOBuffer, output_buffer: buffers.RHLOBuffer) void {
    _ = program;
    _ = input_buffer;
    _ = output_buffer;
}

pub fn createBuilder() Builder {
    return Builder.init(arena.allocator());
}

// this seems weird, but it'll make sense when we consider how the c api will work
pub fn createShape(dims: []const usize) nodes.Shape {
    return dims;
}

test "anoda one" {
    var builder = createBuilder();
    const dtype = nodes.DataType.F32;
    const shape: nodes.Shape = &[_]usize{5};
    const param0 = try builder.paramemeter(dtype, shape);
    const param1 = try builder.paramemeter(dtype, shape);

    _ = try builder.opAdd(param0, param1);
}

test "fuck" {
    _ = target.LLVMInitializeNativeTarget();
    _ = target.LLVMInitializeNativeAsmPrinter();
    _ = target.LLVMInitializeNativeAsmParser();

    const module = core.LLVMModuleCreateWithName("main");

    var param_types: [2]types.LLVMTypeRef = .{
        core.LLVMInt32Type(),
        core.LLVMInt32Type(),
    };
    const fn_type = core.LLVMFunctionType(core.LLVMInt32Type(), &param_types, 2, 0);
    const function = core.LLVMAddFunction(module, "add", fn_type);

    const entry = core.LLVMAppendBasicBlock(function, "entry");

    const builder = core.LLVMCreateBuilder();
    defer core.LLVMDisposeBuilder(builder);
    core.LLVMPositionBuilderAtEnd(builder, entry);

    const param0 = core.LLVMGetParam(function, 0);
    const param1 = core.LLVMGetParam(function, 1);
    const sum = core.LLVMBuildAdd(builder, param0, param1, "sum");
    _ = core.LLVMBuildRet(builder, sum);

    var error_msg: [*c]u8 = null;
    var engine: types.LLVMExecutionEngineRef = undefined;
    if (execution.LLVMCreateExecutionEngineForModule(&engine, module, &error_msg) != 0) {
        std.debug.print("Execution engine creation failed: {s}\n", .{error_msg});
        core.LLVMDisposeMessage(error_msg);
        return error.ExecutionEngineCreationFailed;
    }
    defer execution.LLVMDisposeExecutionEngine(engine);

    const add_addr = execution.LLVMGetFunctionAddress(engine, "add");
    const AddFn = fn (i32, i32) callconv(.C) i32;
    const add_fn: *const AddFn = @ptrFromInt(add_addr);

    const result = add_fn(3, 4);
    std.debug.print("Result of 3 + 4 = {}\n", .{result});
}
