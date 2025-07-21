const std = @import("std");

const rllvm = @import("rllvm");
const cuda = rllvm.cuda;
const target = rllvm.llvm.target;
const target_machine_mod = rllvm.llvm.target_machine;
const types = rllvm.llvm.types;
const core = rllvm.llvm.core;
const execution = rllvm.llvm.engine;
const debug = rllvm.llvm.debug;

const rir = @import("rir/rir.zig");

const nvidia = @import("./codegen/nvidia.zig");

pub fn compile(ops: []*rir.RIROP) !types.LLVMModuleRef {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    const allocator = arena.allocator();

    _ = target.LLVMInitializeNativeTarget();
    _ = target.LLVMInitializeNativeAsmPrinter();
    _ = target.LLVMInitializeNativeAsmParser();

    const libcuda_path = try std.process.getEnvVarOwned(allocator, "LIBCUDA");
    _ = rllvm.llvm.support.LLVMLoadLibraryPermanently(@as([*c]const u8, libcuda_path.ptr));

    const module = core.LLVMModuleCreateWithName("main");
    const builder = core.LLVMCreateBuilder();

    var params = std.ArrayList(*rir.RIROP).init(allocator);
    for (ops) |op| {
        try params.appendSlice(op.findInputs(allocator));
        try params.append(op);
    }

    const fn_type = core.LLVMFunctionType(core.LLVMInt32Type(), null, 0, 0);
    const function = core.LLVMAddFunction(module, "main", fn_type);

    const entry = core.LLVMAppendBasicBlock(function, "entry");

    defer core.LLVMDisposeBuilder(builder);
    core.LLVMPositionBuilderAtEnd(builder, entry);

    for (ops) |op| {
        switch (op.*) {
            .add => {},
            .constant => {},
            .print => {},
            .rand => {},
            else => unreachable,
        }
    }

    const result = @import("codegen/nvidia.zig").compile(module, builder, params.items);

    const zero = core.LLVMConstInt(core.LLVMInt32Type(), 0, 0);

    _ = core.LLVMBuildRet(builder, zero);

    return result;
}

fn generateRIROP(op: rir.RIROP) !void {
    switch (op) {
        .add => {},
        .constant => {},
        .print => {},
        .rand => {},
    }
}

fn generateAdd(op: rir.RIROP) !types.LLVMValueRef {
    return nvidia.compile(.{op});
}
