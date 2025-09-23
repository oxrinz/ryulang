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
const kir = @import("../rir/kernel-ir.zig");
const DType = @import("../rir/dtype.zig").DType;

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

    pub fn compileKernel(self: *@This(), kernel_op: kir.LinearKernel) ![]types.LLVMValueRef {
        const ptx = try buildKernel(kernel_op);
        const metadata = try calculateMetadata(kernel_op.params);

        var d_params = std.array_list.Managed(types.LLVMValueRef).init(arena.allocator());
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
    var params = std.array_list.Managed(usize).init(arena.allocator());

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

fn buildKernel(kernel: kir.LinearKernel) ![]const u8 {
    const KernelBuilder = struct {
        allocator: std.mem.Allocator,
        register_manager: RegisterManager,
        lk: kir.LinearKernel,
        instructions: std.array_list.Managed(ptxast.Instruction),

        fn init(lk: kir.LinearKernel, allocator: std.mem.Allocator) !@This() {
            return .{
                .allocator = allocator,
                .register_manager = try RegisterManager.init(allocator),
                .lk = lk,
                .instructions = std.array_list.Managed(ptxast.Instruction).init(allocator),
            };
        }

        const RegisterManager = struct {
            allocator: Allocator,
            counters: std.AutoHashMap(DType, usize),
            param_counter: usize = 0,

            reg_map: std.AutoHashMap(kir.Operand, []const u8),

            pub fn init(allocator: Allocator) !RegisterManager {
                return .{
                    .allocator = allocator,
                    .counters = std.AutoHashMap(DType, usize).init(allocator),
                    .reg_map = std.AutoHashMap(kir.Operand, []const u8).init(allocator),
                };
            }

            /// Returns a register string that is associated with the passed op.
            /// If op is not associated with any register, it creates a new register.
            pub fn getRegister(self: *RegisterManager, op: kir.Operand) ![]const u8 {
                if (self.reg_map.get(op)) |reg| return reg;

                const createReg = struct {
                    fn createReg(inner_self: *RegisterManager, reg_type: DType, inner_op: kir.Operand) ![]const u8 {
                        const count = inner_self.counters.get(reg_type) orelse 0;
                        try inner_self.counters.put(reg_type, count + 1);
                        const reg = try std.fmt.allocPrint(inner_self.allocator, "%{s}_{d}", .{ @tagName(reg_type), count });
                        try inner_self.reg_map.put(inner_op, reg);
                        return reg;
                    }
                }.createReg;

                switch (op) {
                    .kirop => |kirop| {
                        switch (kirop.*) {
                            .add => {
                                return try createReg(self, .f32, op);
                            },
                            .load => {
                                return try createReg(self, .usize, op);
                            },
                            .special => {
                                return try createReg(self, .u32, op);
                            },
                            else => std.debug.panic("unsupported op in getRegister: {any}\n", .{kirop.*}),
                        }
                    },
                    .param => {
                        const reg = try std.fmt.allocPrint(self.allocator, "%param_{d}", .{self.param_counter});
                        try self.reg_map.put(op, reg);
                        self.param_counter += 1;
                        return reg;
                    },
                }
            }

            pub fn generateDirectives(self: *RegisterManager) ![]ptxast.Directive {
                var list = std.array_list.Managed(ptxast.Directive).init(self.allocator);
                var iterator = self.counters.iterator();
                while (iterator.next()) |entry| {
                    try list.append(.{
                        .reg = .{
                            .name = @tagName(entry.key_ptr.*),
                            .count = @intCast(entry.value_ptr.*),
                            .type = entry.key_ptr.*,
                        },
                    });
                }

                return try list.toOwnedSlice();
            }

            pub fn generateParams(self: *RegisterManager) ![][]const u8 {
                var param_list = std.array_list.Aligned([]const u8, null).empty;
                for (0..self.param_counter) |i| {
                    try param_list.append(self.allocator, try std.fmt.allocPrint(self.allocator, "%param_{d}", .{i}));
                }
                return try param_list.toOwnedSlice(self.allocator);
            }
        };

        // TODO: better system for these 3 functions below
        fn getDTypeFromOp(op: *kir.KIROP) DType {
            switch (op.*) {
                .add => |add| {
                    if (add.src1 == .param or add.src2 == .param) return .u64;

                    const a_dtype = add.src1.getDType();
                    const b_dtype = add.src2.getDType();

                    if (a_dtype != b_dtype) {
                        return a_dtype;
                    } else {
                        return a_dtype;
                    }
                },
                else => @panic("fuck"),
            }
        }

        fn getWideFromOp(op: *kir.KIROP) bool {
            return switch (op.*) {
                .add => |add| {
                    const a_dtype = add.src1.getDType();
                    const b_dtype = add.src2.getDType();

                    if (a_dtype != b_dtype) return true else return false;
                },
                else => @panic("getting wide in an op that can't have wide"),
            };
        }

        fn build(self: *@This()) ![]const u8 {
            for (self.lk.ops) |op| {
                std.debug.print("{any}\n", .{op.*});
                switch (op.*) {
                    .add => |add| {
                        const a = try self.register_manager.getRegister(add.src1);
                        const b = try self.register_manager.getRegister(add.src2);

                        const dest = try self.register_manager.getRegister(.{ .kirop = op });
                        try self.instructions.append(.{
                            .add = .{
                                .src1 = .{ .register = a },
                                .src2 = .{ .register = b },
                                .dest = .{ .register = dest },
                                .type = getDTypeFromOp(op),
                                .wide = getWideFromOp(op),
                            },
                        });
                    },
                    .load => |load| {
                        const dest = try self.register_manager.getRegister(.{ .kirop = op });
                        const addr = try self.register_manager.getRegister(load.addr);

                        try self.instructions.append(.{
                            .ld = .{
                                .dest = .{
                                    .register = dest,
                                },
                                .space = if (load.addr == .param) .param else .global,
                                .src = .{
                                    .register = addr,
                                },
                                .type = op.getDType(),
                            },
                        });
                    },
                    .store => |store| {
                        const src = try self.register_manager.getRegister(.{ .kirop = store.src.kirop });
                        const dest = try self.register_manager.getRegister(.{ .param = store.addr.param });
                        try self.instructions.append(.{
                            .st = .{
                                .space = .param,
                                .dest = .{ .parameter = dest },
                                .src = .{ .register = src },
                                .type = op.getDType(),
                            },
                        });
                    },
                    .special => |special| {
                        const special_reg = switch (special) {
                            .global => |global| switch (global) {
                                .x => "%bid.x",
                                .y => "%bid.y",
                                .z => "%bid.z",
                            },
                            .local => |local| switch (local) {
                                .x => "%tid.x",
                                .y => "%tid.y",
                                .z => "%tid.z",
                            },
                        };
                        const dest = try self.register_manager.getRegister(.{ .kirop = op });
                        try self.instructions.append(.{ .mov = .{
                            .dest = .{ .register = dest },
                            .src = .{ .register = special_reg },
                            .type = op.getDType(),
                        } });
                    },
                    // else => {
                    //     std.debug.panic("Unsupported op: {any}\n", .{op});
                    // },
                }
            }

            try self.instructions.append(.{ .label = .{ .name = "end" } });
            try self.instructions.append(.{ .ret = {} });

            const directives = try self.register_manager.generateDirectives();

            const ptx_kernel = ptxast.Kernel{
                .name = "main",
                .body = try self.instructions.toOwnedSlice(),
                .directives = directives,
                .params = try self.register_manager.generateParams(),
            };
            const globals = &[_]ptxast.GlobalDecl{};
            var kernels = [_]ptxast.Kernel{ptx_kernel};
            const ast = ptxast.PTXAst{ .allocator = self.allocator, .globals = globals, .kernels = &kernels };

            const ptx = try @import("nvidia/emission.zig").emit(self.allocator, ast);
            return ptx;
        }
    };

    var kernel_builder = try KernelBuilder.init(kernel, arena.allocator());

    return try kernel_builder.build();
}
