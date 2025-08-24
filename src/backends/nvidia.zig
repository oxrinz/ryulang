const std = @import("std");
const Allocator = std.mem.Allocator;

const rllvm = @import("rllvm");
const cuda = rllvm.cuda;
const target = rllvm.llvm.target;
const target_machine_mod = rllvm.llvm.target_machine;
const types = rllvm.llvm.types;
const core = rllvm.llvm.core;
const execution = rllvm.llvm.engine;
const debug = rllvm.llvm.debug;

const rir = @import("../rir/rir.zig");

const ptxast = @import("nvidia/ast.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const CudaStorage = struct {
    device: types.LLVMValueRef,
    context: types.LLVMValueRef,
};

pub const PTXConstructor = struct {
    module: types.LLVMModuleRef,
    builder: types.LLVMBuilderRef,
    device: types.LLVMValueRef,
    context: types.LLVMValueRef,

    pub fn init(module: types.LLVMModuleRef, builder: types.LLVMBuilderRef) PTXConstructor {
        try cuda.init(module, builder);
        const cuda_device = try cuda.deviceGet(module, builder);

        return .{
            .module = module,
            .builder = builder,
            .device = cuda_device,
            .context = try cuda.contextCreate(module, builder, cuda_device),
        };
    }

    pub fn compileKernel(self: *@This(), kernel: rir.Sequential) ![]types.LLVMValueRef {
        const metadata = try calculateMetadata(kernel);

        var d_params = std.ArrayList(types.LLVMValueRef).init(arena.allocator());

        const d_output = try self.alloc(4);
        try d_params.append(d_output);

        // launch kernel
        const ptx = try buildKernel(kernel);
        const kernel_len = ptx.len;
        const global_ptx_str = core.LLVMAddGlobal(self.module, core.LLVMArrayType(core.LLVMInt8Type(), @intCast(kernel_len)), "ptx_str");
        const kernel_constant = core.LLVMConstString(@ptrCast(ptx), @intCast(kernel_len), 1);
        core.LLVMSetInitializer(global_ptx_str, kernel_constant);

        const cuda_module = try cuda.moduleLoadData(self.module, self.builder, global_ptx_str);
        const cuda_function = try cuda.moduleGetFunction(self.module, self.builder, cuda_module);

        const int_type = core.LLVMInt32Type();
        const grid_dim_x = core.LLVMConstInt(int_type, 1, 0);
        const grid_dim_y = core.LLVMConstInt(int_type, 1, 0);
        const grid_dim_z = core.LLVMConstInt(int_type, 1, 0);
        const block_dim_x = metadata.dims.block.x;
        const block_dim_y = metadata.dims.block.y;
        const block_dim_z = core.LLVMConstInt(int_type, 1, 0);
        const shared_mem_bytes = core.LLVMConstInt(int_type, 0, 0);
        try cuda.launchKernel(
            self.module,
            self.builder,
            cuda_function,
            grid_dim_x,
            grid_dim_y,
            grid_dim_z,
            block_dim_x,
            block_dim_y,
            block_dim_z,
            shared_mem_bytes,
            d_params.items,
        );

        return d_params.toOwnedSlice();
    }

    pub fn alloc(self: *@This(), size_bytes: usize) !types.LLVMValueRef {
        const size_ref = core.LLVMConstInt(core.LLVMInt64Type(), size_bytes, 0);
        const pointer = core.LLVMBuildAlloca(self.builder, core.LLVMInt64Type(), "d_ptr");
        try cuda.memAlloc(self.module, self.builder, pointer, size_ref);
        return pointer;
    }

    pub fn copyToH(self: *@This(), from: types.LLVMValueRef, size_bytes: usize) !types.LLVMValueRef {
        const size_ref = core.LLVMConstInt(core.LLVMInt64Type(), size_bytes, 0);
        const host_ptr = core.LLVMBuildAlloca(self.builder, core.LLVMFloatType(), "h_ptr");
        try cuda.copyDToH(self.module, self.builder, from, host_ptr, size_ref);
        return host_ptr;
    }
};

const KernelData = struct {
    dims: struct {
        block: struct {
            x: types.LLVMValueRef,
            y: types.LLVMValueRef,
            z: types.LLVMValueRef,
        },
    },
};

fn calculateMetadata(ops: []*rir.RIROP) !KernelData {
    const shape = ops[0].*.getShape();

    const int_type = core.LLVMInt32Type();
    return .{
        .dims = .{
            .block = .{
                .x = core.LLVMConstInt(int_type, shape[0], 0),
                .y = core.LLVMConstInt(int_type, if (shape.len > 1) shape[1] else 1, 0),
                .z = core.LLVMConstInt(int_type, 1, 0),
            },
        },
    };
}

const RegisterManager = struct {
    allocator: Allocator,
    f32_count: usize = 0,
    f64_count: usize = 0,
    i64_count: usize = 0,
    b64_count: usize = 0,
    param_count: usize = 0,

    pub fn init(allocator: Allocator) @This() {
        return .{ .allocator = allocator };
    }

    pub fn getRegister(self: *RegisterManager, dtype: enum { f32, b64 }) ![]const u8 {
        switch (dtype) {
            .f32 => {
                self.f32_count += 1;
                return try std.fmt.allocPrint(self.allocator, "%f32_{d}", .{self.f32_count - 1});
            },
            .b64 => {
                self.b64_count += 1;
                return try std.fmt.allocPrint(self.allocator, "%rd_{d}", .{self.b64_count - 1});
            },
        }
    }

    pub fn generateDirectives(self: *RegisterManager) ![]ptxast.Directive {
        var list = std.ArrayList(ptxast.Directive).init(self.allocator);
        try list.appendSlice(&[_]ptxast.Directive{
            .{ .reg = .{ .name = "%rd_", .count = @intCast(self.b64_count), .type = .b64 } },
            .{ .reg = .{ .name = "%f32_", .count = @intCast(self.f32_count), .type = .f32 } },
        });
        return list.toOwnedSlice();
    }

    pub fn getParam(self: *RegisterManager) ![]const u8 {
        self.param_count += 1;
        return try std.fmt.allocPrint(self.allocator, "%param_{d}", .{self.param_count - 1});
    }
};

fn buildKernel(kernel_ops: rir.Sequential) ![]const u8 {
    const allocator = arena.allocator();

    const appendInstr = struct {
        fn perform(fmt: []const u8, args: anytype) anyerror![]u8 {
            return try std.fmt.allocPrint(allocator, fmt, args);
        }
    }.perform;
    _ = appendInstr;

    var register_manager = RegisterManager.init(allocator);

    var instructions = std.ArrayList(ptxast.Instruction).init(allocator);
    var params = std.ArrayList([]const u8).init(allocator);

    var dest_map = std.AutoHashMap(*rir.RIROP, []const u8).init(allocator);

    for (kernel_ops) |op| {
        switch (op.*) {
            .add => |add| {
                const a = dest_map.get(add.a);
                const b = dest_map.get(add.b);

                const dest = try register_manager.getRegister(.f32);

                try instructions.append(.{
                    .add = .{
                        .src1 = .{ .register = a.? },
                        .src2 = .{ .register = b.? },
                        .dest = .{ .register = dest },
                        .type = .f32,
                        .wide = false,
                    },
                });

                try dest_map.put(op, dest);
            },
            .divide => {},
            .constant => {
                const dest = try register_manager.getRegister(.f32);
                const src = op.constant.getConstant();
                if (src != .f32) @panic("Wrong datatype");
                try instructions.append(.{ .mov = .{
                    .src = .{ .immediate = .{ .float = @floatCast(src.f32[0]) } },
                    .dest = .{ .register = dest },
                    .type = .f32,
                } });
                try dest_map.put(op, dest);
            },
            .sequential => @panic("Nested sequential"),

            // TODO: currently store assumes that the stored value is an output. fix this
            .store => |store| {
                const output_param = try register_manager.getParam();
                const output_reg = try register_manager.getRegister(.b64);
                try params.append(output_param);
                try instructions.append(.{ .ld = .{ .space = .param, .type = .u64, .src = .{ .parameter = output_param }, .dest = .{ .register = output_reg } } });

                try instructions.append(.{
                    .st = .{
                        .space = .global,
                        .type = .f32,
                        .dest = .{ .register = output_reg },
                        .src = .{ .register = dest_map.get(store.source).? },
                    },
                });
            },
            .copy => {},
        }
    }

    try instructions.append(.ret);

    const kernel = ptxast.Kernel{
        .name = "main",
        .body = try instructions.toOwnedSlice(),
        .directives = try register_manager.generateDirectives(),
        .params = try params.toOwnedSlice(),
    };

    const globals = &[_]ptxast.GlobalDecl{};
    var kernels = [_]ptxast.Kernel{kernel};
    const ast = ptxast.PTXAst{ .allocator = allocator, .globals = globals, .kernels = &kernels };
    const ptx = try @import("nvidia/emission.zig").emit(allocator, ast);

    return ptx;
}

// fn buildKernel(kernel: rir.Sequential) ![]const u8 {
//     const allocator = arena.allocator();

//     const appendInstr = struct {
//         fn perform(fmt: []const u8, args: anytype) anyerror![]u8 {
//             return try std.fmt.allocPrint(allocator, fmt, args);
//         }
//     }.perform;
//     _ = appendInstr;

//     var instructions = std.ArrayList(ptxast.Instruction).init(allocator);
//     var directives = std.ArrayList(ptxast.Directive).init(allocator);
//     var params = std.ArrayList([]const u8).init(allocator);

//     const total_params = input_count + 1;
//     const reg_count = total_params + 1;

//     try directives.append(.{
//         .reg = .{
//             .name = "%rd",
//             .count = @intCast(reg_count),
//             .type = .b64,
//         },
//     });

//     try directives.append(.{
//         .reg = .{
//             .name = "%f",
//             .count = @intCast(reg_count),
//             .type = .f32,
//         },
//     });

//     for (0..total_params) |i| {
//         const param_name = try std.fmt.allocPrint(allocator, "param_{d}", .{i});
//         const rd_reg = try std.fmt.allocPrint(allocator, "%rd{d}", .{i});

//         try params.append(param_name);
//         try instructions.append(.{ .ld = .{ .space = .param, .type = .u64, .src = .{ .parameter = param_name }, .dest = .{ .register = rd_reg } } });
//     }

//     for (0..total_params) |i| {
//         const rd_reg = try std.fmt.allocPrint(allocator, "%rd{d}", .{i});
//         try instructions.append(.{ .cvta = .{ .to_generic = true, .space = .global, .type = .u64, .src = .{ .register = rd_reg }, .dest = .{ .register = rd_reg } } });
//     }

//     for (0..input_count) |i| {
//         const rd_reg = try std.fmt.allocPrint(allocator, "%rd{d}", .{i});
//         const f_reg = try std.fmt.allocPrint(allocator, "%f{d}", .{i});

//         try instructions.append(.{ .ld = .{ .space = .global, .type = .f32, .src = .{ .register = rd_reg }, .dest = .{ .register = f_reg } } });
//     }

//     const result_reg = try std.fmt.allocPrint(allocator, "%f{d}", .{input_count});
//     if (input_count == 1) {
//         const f0_reg = try std.fmt.allocPrint(allocator, "%f{d}", .{0});
//         try instructions.append(.{ .mov = .{ .type = .f32, .src = .{ .register = f0_reg }, .dest = .{ .register = result_reg } } });
//     } else if (input_count == 2) {
//         const f0_reg = try std.fmt.allocPrint(allocator, "%f{d}", .{0});
//         const f1_reg = try std.fmt.allocPrint(allocator, "%f{d}", .{1});
//         try instructions.append(.{ .add = .{ .type = .f32, .src1 = .{ .register = f0_reg }, .src2 = .{ .register = f1_reg }, .dest = .{ .register = result_reg } } });
//     } else {
//         var current_reg = try std.fmt.allocPrint(allocator, "%f{d}", .{0});
//         for (1..input_count) |i| {
//             const next_input_reg = try std.fmt.allocPrint(allocator, "%f{d}", .{i});
//             const temp_reg = if (i == input_count - 1) result_reg else try std.fmt.allocPrint(allocator, "%f{d}", .{input_count + i});

//             try instructions.append(.{ .add = .{ .type = .f32, .src1 = .{ .register = current_reg }, .src2 = .{ .register = next_input_reg }, .dest = .{ .register = temp_reg } } });
//             current_reg = temp_reg;
//         }
//     }

//     const output_rd_reg = try std.fmt.allocPrint(allocator, "%rd{d}", .{input_count});
//     try instructions.append(.{ .st = .{ .space = .global, .type = .f32, .dest = .{ .register = output_rd_reg }, .src = .{ .register = result_reg } } });

//     try instructions.append(.ret);

//     const kernel = ptxast.Kernel{
//         .name = "main",
//         .body = try instructions.toOwnedSlice(),
//         .directives = try directives.toOwnedSlice(),
//         .params = try params.toOwnedSlice(),
//     };

//     const globals = &[_]ptxast.GlobalDecl{};
//     var kernels = [_]ptxast.Kernel{kernel};
//     const ast = ptxast.PTXAst{ .allocator = allocator, .globals = globals, .kernels = &kernels };
//     const ptx = try @import("nvidia/emission.zig").emit(allocator, ast);

//     return ptx;
// }
