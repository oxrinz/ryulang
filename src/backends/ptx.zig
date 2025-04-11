const std = @import("std");

const Generator = @import("../gen.zig").Generator;

const llvm = @import("llvm");
const target = llvm.target;
const target_machine_mod = llvm.target_machine;
const types = llvm.types;
const core = llvm.core;
const process = std.process;
const execution = llvm.engine;

const ast = @import("../ast.zig");

pub const PTXBackend = struct {
    allocator: std.mem.Allocator,
    llvm_module: types.LLVMModuleRef,
    builder: types.LLVMBuilderRef,

    // declare the cuda api functions
    pub fn init(allocator: std.mem.Allocator, gen: *Generator) PTXBackend {
        return .{
            .allocator = allocator,
            .llvm_module = gen.*.llvm_module,
            .builder = gen.*.builder,
        };
    }

    pub fn generateKernel(self: *PTXBackend, function_definition: ast.FunctionDefinition) ![]const u8 {
        _ = self;
        _ = function_definition;
        const ptx =
            \\//
            \\.version 8.4
            \\.target sm_52
            \\.address_size 64
            \\
            \\.visible .entry main(
            \\  .param .u64 input_ptr,
            \\  .param .u64 output_ptr
            \\)
            \\{
            \\  .reg .b32 %r<2>;
            \\  .reg .b64 %rd<3>;
            \\
            \\  ld.param.u64 %rd1, [input_ptr];
            \\  ld.param.u64 %rd2, [output_ptr];
            \\
            \\  cvta.to.global.u64 %rd1, %rd1;
            \\  cvta.to.global.u64 %rd2, %rd2;
            \\
            \\  ld.global.u32 %r1, [%rd1];
            \\
            \\  st.global.u32 [%rd2], %r1;
            \\
            \\  ret;
            \\}
        ;

        return ptx;
    }
};
