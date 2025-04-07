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
            \\.version 7.5
            \\.target sm_75
            \\.address_size 64
            \\
            \\.visible .entry main(
            \\    .param .u64 input_ptr,
            \\    .param .u64 output_ptr,
            \\    .param .u32 n
            \\)
            \\{
            \\    .reg .b32       r<5>;
            \\    .reg .b64       rd<5>;
            \\    .reg .f32       f<3>;
            \\    .reg .pred      p<2>;
            \\
            \\    // Get the thread ID
            \\    ld.param.u64    rd1, [input_ptr];
            \\    ld.param.u64    rd2, [output_ptr];
            \\    ld.param.u32    r1, [n];
            \\    
            \\    // Calculate thread ID
            \\    mov.u32         r2, %tid.x;
            \\    mov.u32         r3, %ntid.x;
            \\    mov.u32         r4, %ctaid.x;
            \\    mad.lo.u32      r2, r4, r3, r2;
            \\    
            \\    // Check if thread ID is within bounds
            \\    setp.ge.u32     p1, r2, r1;
            \\    @p1 bra         EXIT;
            \\    
            \\    // Calculate input and output addresses
            \\    cvt.u64.u32     rd3, r2;
            \\    mul.wide.u32    rd3, r2, 4;      // 4 bytes per float
            \\    add.u64         rd1, rd1, rd3;   // input_ptr + offset
            \\    add.u64         rd2, rd2, rd3;   // output_ptr + offset
            \\    
            \\    // Load input value
            \\    ld.global.f32   f1, [rd1];
            \\    
            \\    // Add constant 2.0 to the value
            \\    mov.f32         f2, 0f40000000;  // 2.0 in hex floating point
            \\    add.f32         f1, f1, f2;
            \\    
            \\    // Store result to output
            \\    st.global.f32   [rd2], f1;
            \\    
            \\EXIT:
            \\    ret;
            \\}
        ;

        return ptx;
    }
};
