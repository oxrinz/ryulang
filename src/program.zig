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
const dashboard = @import("dashboard.zig");

pub const Effect = struct {
    effect_type: enum { print },
    targets: []*rir.RIROP,
};

pub const Program = struct {
    graph: []*rir.RIROP,
    effects: []Effect,

    // codegen function, no optimization passes beyond this point
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

        var pc = ProgramCompiler.init(module, builder, allocator);

        for (self.effects) |effect| {
            for (effect.targets) |target_op| {
                try pc.compileOp(target_op);
            }

            for (pc.compiled.items) |compiled| {
                const res = pc.results.get(compiled) orelse continue;

                for (res) |val| {
                    const loaded_float = core.LLVMBuildLoad2(builder, core.LLVMFloatType(), val, "loaded_float");
                    try rllvm.utils.printFloat(module, builder, loaded_float);
                }
            }
        }

        const zero = core.LLVMConstInt(core.LLVMInt32Type(), 0, 0);
        _ = core.LLVMBuildRet(builder, zero);

        return module;
    }
};

const ProgramCompiler = struct {
    allocator: std.mem.Allocator,
    constructor: nvidia.PTXConstructor,
    results: std.AutoHashMap(*rir.RIROP, []types.LLVMValueRef),
    compiled: std.array_list.Aligned(*rir.RIROP, null),

    pub fn init(module: types.LLVMModuleRef, builder: types.LLVMBuilderRef, allocator: std.mem.Allocator) ProgramCompiler {
        return .{
            .allocator = allocator,
            .constructor = nvidia.PTXConstructor.init(module, builder),
            .results = std.AutoHashMap(*rir.RIROP, []types.LLVMValueRef).init(allocator),
            .compiled = std.array_list.Aligned(*rir.RIROP, null).empty,
        };
    }

    fn compileOp(self: *ProgramCompiler, op: *rir.RIROP) !void {
        for (self.compiled.items) |compiled| {
            if (op == compiled) return;
        }
        try self.compiled.append(self.allocator, op);

        switch (op.*) {
            .linear_kernel => |lk| {
                // compile the other kernels
                for (lk.params) |param| {
                    try self.compileOp(param);
                }

                const d_results = try self.constructor.compileKernel(lk);
                try self.results.put(op, d_results);
            },
            .view => |view| {
                try self.compileOp(view.src);
            },
            .copy => 

            // TODO: the comment above isn't implemented, so it just does nothing. this should recursively compile all kernels before the current one
            else => {},
        }
    }
};
