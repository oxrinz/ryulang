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

    pub fn compileKernel(self: *@This(), kernel_op: *rir.RIROP) ![]types.LLVMValueRef {
        // TODO: remove this check
        if (kernel_op.* != .kernel) return error.NotAKernelOp;
        const kernel = kernel_op.kernel.ops;

        std.debug.print("kernel: {any}\n", .{kernel_op.kernel.ops});

        const ptx = try buildKernel(kernel);
        const metadata = try calculateMetadata(kernel_op.kernel.params);

        var d_params = std.ArrayList(types.LLVMValueRef).init(arena.allocator());
        const d_output = try self.alloc(4);
        try d_params.append(d_output);

        // launch kernel
        const kernel_len = ptx.len;
        const global_ptx_str = core.LLVMAddGlobal(self.module, core.LLVMArrayType(core.LLVMInt8Type(), @intCast(kernel_len)), "ptx_str");
        const kernel_constant = core.LLVMConstString(@ptrCast(ptx), @intCast(kernel_len), 1);
        core.LLVMSetInitializer(global_ptx_str, kernel_constant);

        const cuda_module = try cuda.moduleLoadData(self.module, self.builder, global_ptx_str);
        const cuda_function = try cuda.moduleGetFunction(self.module, self.builder, cuda_module);

        const int_type = core.LLVMInt32Type();
        const grid_dim_x = metadata.dims.grid.x;
        const grid_dim_y = metadata.dims.grid.y;
        const grid_dim_z = metadata.dims.grid.z;
        const block_dim_x = metadata.dims.block.x;
        const block_dim_y = metadata.dims.block.y;
        const block_dim_z = metadata.dims.block.z;
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
    params: []usize,
    dims: struct {
        block: struct {
            x: types.LLVMValueRef,
            y: types.LLVMValueRef,
            z: types.LLVMValueRef,
        },
        grid: struct {
            x: types.LLVMValueRef,
            y: types.LLVMValueRef,
            z: types.LLVMValueRef,
        },
    },
};

fn calculateMetadata(ops: []*rir.RIROP) !KernelData {
    var params = std.ArrayList(usize).init(arena.allocator());

    for (ops) |op| {
        switch (op.*) {
            .buffer => |buffer| try params.append(buffer.getSizeInBytes()),
            .store => |store| try params.append(store.source.getSizeInBytes(arena.allocator())),
            else => {},
        }
    }

    const shape = ops[0].*.getShape();
    const int_type = core.LLVMInt32Type();

    var total_elements: u64 = 1;
    for (shape) |dim| {
        total_elements *= dim;
    }

    const block_size_x = 16;
    const block_size_y = 16;
    const threads_per_block = block_size_x * block_size_y;

    const grid_x = (total_elements + threads_per_block - 1) / threads_per_block;

    return .{
        .params = try params.toOwnedSlice(),
        .dims = .{
            .block = .{
                .x = core.LLVMConstInt(int_type, block_size_x, 0),
                .y = core.LLVMConstInt(int_type, block_size_y, 0),
                .z = core.LLVMConstInt(int_type, 1, 0),
            },
            .grid = .{
                .x = core.LLVMConstInt(int_type, @min(grid_x, 2147483647), 0), // respect sm_52 x-limit TODO: remove
                .y = core.LLVMConstInt(int_type, 1, 0),
                .z = core.LLVMConstInt(int_type, 1, 0),
            },
        },
    };
}

fn buildKernel(kernel_ops: []*rir.RIROP) ![]const u8 {
    const KernelBuilder = struct {
        allocator: std.mem.Allocator,
        register_manager: RegisterManager,
        ops: []*rir.RIROP,
        instructions: std.ArrayList(ptxast.Instruction),
        params: std.ArrayList([]const u8),
        dest_map: std.AutoHashMap(*rir.RIROP, []const u8),

        fn init(ops: []*rir.RIROP, allocator: std.mem.Allocator) !@This() {
            return .{
                .allocator = allocator,
                .register_manager = RegisterManager.init(allocator),
                .ops = ops,
                .instructions = std.ArrayList(ptxast.Instruction).init(allocator),
                .params = std.ArrayList([]const u8).init(allocator),
                .dest_map = std.AutoHashMap(*rir.RIROP, []const u8).init(allocator),
            };
        }

        const RegisterManager = struct {
            allocator: Allocator,
            f32_count: usize = 0,
            f64_count: usize = 0,
            i64_count: usize = 0,
            b64_count: usize = 0,
            u32_count: usize = 0,
            param_count: usize = 0,

            pub fn init(allocator: Allocator) @This() {
                return .{ .allocator = allocator };
            }

            pub fn getRegister(self: *RegisterManager, dtype: enum { f32, b64, u32 }) ![]const u8 {
                switch (dtype) {
                    .f32 => {
                        self.f32_count += 1;
                        return try std.fmt.allocPrint(self.allocator, "%f32_{d}", .{self.f32_count - 1});
                    },
                    .b64 => {
                        self.b64_count += 1;
                        return try std.fmt.allocPrint(self.allocator, "%rd_{d}", .{self.b64_count - 1});
                    },
                    .u32 => {
                        self.u32_count += 1;
                        return try std.fmt.allocPrint(self.allocator, "%r_{d}", .{self.u32_count - 1});
                    },
                }
            }

            pub fn generateDirectives(self: *RegisterManager) ![]ptxast.Directive {
                var list = std.ArrayList(ptxast.Directive).init(self.allocator);
                try list.appendSlice(&[_]ptxast.Directive{
                    .{ .reg = .{ .name = "%rd_", .count = @intCast(self.b64_count), .type = .b64 } },
                    .{ .reg = .{ .name = "%f32_", .count = @intCast(self.f32_count), .type = .f32 } },
                    .{ .reg = .{ .name = "%r_", .count = @intCast(self.u32_count), .type = .u32 } },
                });
                return list.toOwnedSlice();
            }

            pub fn getParam(self: *RegisterManager) ![]const u8 {
                self.param_count += 1;
                return try std.fmt.allocPrint(self.allocator, "%param_{d}", .{self.param_count - 1});
            }
        };

        fn build(self: *@This()) ![]const u8 {
            for (self.ops) |op| {
                switch (op.*) {
                    .add => |add| {
                        const a = self.dest_map.get(add.a) orelse {
                            std.debug.panic("Missing operand: {any}\n", .{add.a});
                        };
                        const b = self.dest_map.get(add.b) orelse {
                            std.debug.panic("Missing operand: {any}\n", .{add.b});
                        };
                        const dest = try self.register_manager.getRegister(.f32);
                        try self.instructions.append(.{
                            .add = .{
                                .src1 = .{ .register = a },
                                .src2 = .{ .register = b },
                                .dest = .{ .register = dest },
                                .type = .f32,
                                .wide = false,
                            },
                        });
                        try self.dest_map.put(op, dest);
                    },
                    .divide => {},
                    .kernel => @panic("Nested Kernel"),
                    .store => |store| {
                        const output_param = try self.register_manager.getParam();
                        const output_reg = try self.register_manager.getRegister(.b64);
                        try self.params.append(output_param);
                        try self.instructions.append(.{
                            .ld = .{
                                .space = .param,
                                .type = .u64,
                                .src = .{ .parameter = output_param },
                                .dest = .{ .register = output_reg },
                            },
                        });
                        try self.instructions.append(.{
                            .add = .{
                                .src1 = .{ .register = output_reg },
                                .src2 = .{ .register = "%rd_2" },
                                .dest = .{ .register = "%rd_4" },
                                .type = .b64,
                                .wide = false,
                            },
                        });
                        try self.instructions.append(.{
                            .st = .{
                                .space = .global,
                                .type = .f32,
                                .dest = .{ .register = "%rd_4" },
                                .src = .{ .register = self.dest_map.get(store.source) orelse @panic("Missing store source") },
                            },
                        });
                    },
                    .param_addr => {
                        const dest = try self.register_manager.getRegister(.u32);
                        try self.instructions.append(.{
                            .mov = .{
                                .dest = .{ .register = dest },
                                .src = .{ .register = "%tid.x" },
                                .type = .u32,
                            },
                        });
                        try self.dest_map.put(op, dest);
                    },
                    else => {
                        std.debug.print("Unsupported op: {any}\n", .{op});
                    },
                }
            }

            try self.instructions.append(.{ .label = .{ .name = "end" } });
            try self.instructions.append(.{ .ret = {} });

            const directives = try self.register_manager.generateDirectives();

            const kernel = ptxast.Kernel{
                .name = "main",
                .body = try self.instructions.toOwnedSlice(),
                .directives = directives,
                .params = try self.params.toOwnedSlice(),
            };
            const globals = &[_]ptxast.GlobalDecl{};
            var kernels = [_]ptxast.Kernel{kernel};
            const ast = ptxast.PTXAst{ .allocator = self.allocator, .globals = globals, .kernels = &kernels };

            const ptx = try @import("nvidia/emission.zig").emit(self.allocator, ast);
            return ptx;
        }
    };

    var kernel_builder = try KernelBuilder.init(kernel_ops, arena.allocator());

    return try kernel_builder.build();
}
