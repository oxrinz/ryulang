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

const nvidia = @import("backends/nvidia.zig");

const linearize = @import("engine/linearize.zig").linealize;

pub const Effect = struct {
    effect_type: enum { print },
    targets: []*rir.RIROP,
};

pub const Program = struct {
    graph: []*rir.RIROP,
    effects: []Effect,

    pub fn compile(self: *Program) !types.LLVMModuleRef {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const allocator = arena.allocator();

        // init llvm stuff
        _ = target.LLVMInitializeNativeTarget();
        _ = target.LLVMInitializeNativeAsmPrinter();
        _ = target.LLVMInitializeNativeAsmParser();

        const libcuda_path = try std.process.getEnvVarOwned(allocator, "LIBCUDA");
        _ = rllvm.llvm.support.LLVMLoadLibraryPermanently(@as([*c]const u8, libcuda_path.ptr));

        const module = core.LLVMModuleCreateWithName("main");
        const builder = core.LLVMCreateBuilder();

        const fn_type = core.LLVMFunctionType(core.LLVMInt32Type(), null, 0, 0);
        const function = core.LLVMAddFunction(module, "main", fn_type);

        const entry = core.LLVMAppendBasicBlock(function, "entry");

        defer core.LLVMDisposeBuilder(builder);
        core.LLVMPositionBuilderAtEnd(builder, entry);

        // construct ptx
        var ptx_constructor = nvidia.PTXConstructor.init(module, builder);

        for (self.effects) |effect| {
            var params = std.ArrayList(*rir.RIROP).init(allocator);
            for (effect.targets) |op| {
                try params.appendSlice(op.findInputs(allocator));
                try params.append(op);
            }

            const kernel = try linearize(params.items, allocator);

            const d_results = try ptx_constructor.compileKernel(kernel);

            const result = try ptx_constructor.copyToH(d_results[0], 4);

            switch (effect.effect_type) {
                .print => {
                    const loaded_float = core.LLVMBuildLoad2(builder, core.LLVMFloatType(), result, "loaded_float");
                    const loaded_value = core.LLVMBuildFPToSI(builder, loaded_float, core.LLVMInt32Type(), "loaded_value");
                    try rllvm.utils.printInt(module, builder, loaded_value);
                },
            }
        }

        const zero = core.LLVMConstInt(core.LLVMInt32Type(), 0, 0);
        _ = core.LLVMBuildRet(builder, zero);

        return module;
    }
};
