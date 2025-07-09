const std = @import("std");

const rllvm = @import("rllvm");
const cuda = rllvm.cuda;
const target = rllvm.llvm.target;
const target_machine_mod = rllvm.llvm.target_machine;
const types = rllvm.llvm.types;
const core = rllvm.llvm.core;
const execution = rllvm.llvm.engine;

const ptxast = @import("./ast.zig");
const nodes = @import("../../nodes.zig");

pub fn genTemp(module: types.LLVMModuleRef) !types.LLVMValueRef {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const kernel = ptxast.Kernel{
        .name = "main",
        .body = std.ArrayList(ptxast.Instruction).init(allocator).items,
        .directives = std.ArrayList(ptxast.Directive).init(allocator).items,
        .params = std.ArrayList([]const u8).init(allocator).items,
    };

    const globals = &[_]ptxast.GlobalDecl{};
    var kernels = [_]ptxast.Kernel{kernel};
    const ast = ptxast.PTXAst{ .allocator = allocator, .globals = globals, .kernels = &kernels };
    const ptx = try @import("./emission.zig").emit(allocator, ast);

    const kernel_len = ptx.len; // Length includes the null terminator
    // Define global as an array of i8, not a pointer
    const global_ptx_str = core.LLVMAddGlobal(module, core.LLVMArrayType(core.LLVMInt8Type(), @intCast(kernel_len)), "ptx_str");

    // Create constant string, assuming ptx includes \00, so no extra null is added
    const kernel_constant = core.LLVMConstString(@ptrCast(ptx), @intCast(kernel_len), 1);
    core.LLVMSetInitializer(global_ptx_str, kernel_constant);

    return global_ptx_str;
}

pub fn generatePTX(module: types.LLVMModuleRef, program: nodes.RHLOProgram) !types.LLVMValueRef {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var generator = try Generator.init(allocator, module, program);

    const kernel = try generator.generatePTX();

    const globals = &[_]ptxast.GlobalDecl{};
    var kernels = [_]ptxast.Kernel{kernel};
    const ast = ptxast.PTXAst{ .allocator = allocator, .globals = globals, .kernels = &kernels };
    const ptx = try @import("./emission.zig").emit(allocator, ast);

    const file = try std.fs.cwd().createFile("rhlo.ptx", .{});
    defer file.close();

    try file.writeAll(ptx);

    const kernel_len = ptx.len;
    const global_ptx_str = core.LLVMAddGlobal(module, core.LLVMPointerType(core.LLVMInt8Type(), 0), "ptx_str");
    const kernel_constant = core.LLVMConstString(@ptrCast(ptx), @intCast(kernel_len), 0);
    core.LLVMSetInitializer(global_ptx_str, kernel_constant);
    return global_ptx_str;
}

const RegisterManager = struct {
    allocator: std.mem.Allocator,
    reg_r_count: usize = 0,
    reg_rd_count: usize = 0,
    reg_f_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) RegisterManager {
        return .{
            .allocator = allocator,
        };
    }

    pub fn getRegister(self: *RegisterManager, reg_type: enum { r, rd, f }) ![]const u8 {
        switch (reg_type) {
            .r => {
                self.reg_r_count += 1;
                return try std.fmt.allocPrint(self.allocator, "%r{d}", .{self.reg_r_count - 1});
            },
            .rd => {
                self.reg_rd_count += 1;
                return try std.fmt.allocPrint(self.allocator, "%rd{d}", .{self.reg_rd_count - 1});
            },
            .f => {
                self.reg_f_count += 1;
                return try std.fmt.allocPrint(self.allocator, "%f{d}", .{self.reg_f_count - 1});
            },
        }
    }
};

const MemoryLoader = struct {
    allocator: std.mem.Allocator,

    generator: *Generator,

    raw_tidx_reg: ?[]const u8 = null,
    raw_tidy_reg: ?[]const u8 = null,
    tidx_reg: ?[]const u8 = null,
    tidy_reg: ?[]const u8 = null,

    raw_params: std.ArrayList([]const u8),
    param_address_regs: std.AutoHashMap(usize, []const u8),

    local_offset: ?[]const u8 = null,
    local_tensor_regs: std.AutoHashMap(usize, []const u8),

    local_row_regs: std.AutoHashMap(usize, [][]const u8),
    local_col_regs: std.AutoHashMap(usize, [][]const u8),

    pub fn init(generator: *Generator, allocator: std.mem.Allocator) !MemoryLoader {
        var memory_loader = MemoryLoader{
            .generator = generator,
            .allocator = allocator,
            .raw_params = std.ArrayList([]const u8).init(allocator),
            .local_tensor_regs = std.AutoHashMap(usize, []const u8).init(allocator),
            .param_address_regs = std.AutoHashMap(usize, []const u8).init(allocator),
            .local_row_regs = std.AutoHashMap(usize, [][]const u8).init(allocator),
            .local_col_regs = std.AutoHashMap(usize, [][]const u8).init(allocator),
        };

        for (generator.program.params.items, 0..) |param, idx| {
            const name = try std.fmt.allocPrint(allocator, "param_{d}", .{idx});
            try memory_loader.raw_params.append(name);

            const reg = try memory_loader.generator.reg_manager.getRegister(.rd);
            try memory_loader.param_address_regs.put(param.id, reg);
            try memory_loader.generator.body.append(.{ .ld = .{ .space = .param, .type = .u64, .src = .{ .parameter = name }, .dest = .{ .register = reg } } });
        }

        for (generator.program.params.items) |param| {
            try memory_loader.generator.body.append(.{
                .cvta = .{
                    .to_generic = true,
                    .space = .global,
                    .type = .u64,
                    .src = .{ .register = memory_loader.param_address_regs.get(param.id).? },
                    .dest = .{ .register = memory_loader.param_address_regs.get(param.id).? },
                },
            });
        }

        return memory_loader;
    }

    fn loadLocalMatrixValue(self: *MemoryLoader, tensor_id: usize) ![]const u8 {
        const address = try self.generator.reg_manager.getRegister(.rd);
        try self.generator.body.append(.{ .add = .{
            .type = .u64,
            .dest = .{ .register = address },
            .src1 = .{ .register = self.local_offset.? },
            .src2 = .{ .register = self.local_tensor_regs.get(tensor_id).? },
        } });

        const dest = try self.generator.reg_manager.getRegister(.f);
        try self.generator.body.append(.{
            .ld = .{
                .type = .f32,
                .space = .global,
                .dest = .{ .register = dest },
                .src = .{
                    .register = address,
                },
            },
        });

        return dest;
    }

    fn storeLocalMatrixValue(self: *MemoryLoader, tensor_id: usize, value_reg: []const u8) !void {
        const address = try self.generator.reg_manager.getRegister(.rd);
        try self.generator.body.append(.{ .add = .{
            .type = .u64,
            .dest = .{ .register = address },
            .src1 = .{ .register = self.local_offset.? },
            .src2 = .{ .register = self.param_address_regs.get(tensor_id).? },
        } });
        try self.generator.body.append(.{
            .st = .{
                .space = .global,
                .type = .f32,
                .dest = .{ .register = address },
                .src = .{ .register = value_reg },
            },
        });
    }

    fn calculateLocalData(self: *MemoryLoader) !void {
        self.raw_tidx_reg = try self.generator.reg_manager.getRegister(.r);
        self.raw_tidy_reg = try self.generator.reg_manager.getRegister(.r);
        self.tidx_reg = try self.generator.reg_manager.getRegister(.rd);
        self.tidy_reg = try self.generator.reg_manager.getRegister(.rd);
        try self.generator.body.append(.{
            .mov = .{
                .dest = .{ .register = self.raw_tidx_reg.? },
                .src = .{ .register = "%tid.x" },
                .type = .u32,
            },
        });
        try self.generator.body.append(.{
            .mov = .{
                .dest = .{ .register = self.raw_tidy_reg.? },
                .src = .{ .register = "%tid.y" },
                .type = .u32,
            },
        });
        try self.generator.body.append(.{
            .mul = .{
                .dest = .{ .register = self.tidx_reg.? },
                .modifier = .wide,
                .src1 = .{ .register = self.raw_tidx_reg.? },
                .src2 = .{
                    .immediate = .{ .integer = 4 },
                },
                .type = .s32,
            },
        });
        try self.generator.body.append(.{
            .mul = .{
                .dest = .{ .register = self.tidy_reg.? },
                .modifier = .wide,
                .src1 = .{ .register = self.raw_tidy_reg.? },
                .src2 = .{
                    .immediate = .{ .integer = 4 },
                },
                .type = .s32,
            },
        });

        self.local_offset = try self.generator.reg_manager.getRegister(.rd);
        try self.generator.body.append(.{
            .shl = .{
                .type = .b64,
                .dest = .{ .register = self.local_offset.? },
                .src1 = .{ .register = self.tidy_reg.? },
                .src2 = .{ .immediate = .{ .integer = @intCast(self.generator.program.tensor_store.items[0].dimensions[0] / 2) } },
            },
        });
        try self.generator.body.append(.{ .add = .{
            .type = .u64,
            .dest = .{ .register = self.local_offset.? },
            .src1 = .{ .register = self.local_offset.? },
            .src2 = .{ .register = self.tidx_reg.? },
        } });
    }

    fn getLocalMatrixRegister(self: *MemoryLoader, tensor_id: usize) ![]const u8 {
        if (self.tidx_reg == null or self.tidy_reg == null) {
            try self.calculateLocalData();
        }

        if (self.local_tensor_regs.get(tensor_id) == null) {
            var reg: ?[]const u8 = null;
            if (try self.checkIfInputParam(tensor_id) == true) {
                try self.local_tensor_regs.put(tensor_id, self.param_address_regs.get(tensor_id).?);
                reg = try self.loadLocalMatrixValue(tensor_id);
            }
            if (reg == null) reg = try self.generator.reg_manager.getRegister(.f);
            try self.local_tensor_regs.put(tensor_id, reg.?);
        }
        return self.local_tensor_regs.get(tensor_id).?;
    }

    fn getLocalAxisParamRegisters(self: *MemoryLoader, tensor_id: usize, axis: enum { row, col }) ![][]const u8 {
        const dims = self.generator.program.tensor_store.items[tensor_id].dimensions;
        var regs = std.ArrayList([]const u8).init(self.allocator);

        for (0..dims[if (axis == .row) 1 else 0]) |x| {
            const address = try self.generator.reg_manager.getRegister(.rd);
            const dim_reg = try self.generator.reg_manager.getRegister(.r);
            const dest = try self.generator.reg_manager.getRegister(.f);

            const intermediate = try self.generator.reg_manager.getRegister(.r);

            try self.generator.body.append(.{ .mov = .{
                .type = .u32,
                .dest = .{ .register = dim_reg },
                .src = .{ .immediate = .{ .integer = if (axis == .row) @intCast(dims[1] * 4) else @intCast(dims[1] * (x)) } },
            } });
            if (axis == .col) {
                try self.generator.body.append(.{ .add = .{
                    .type = .u32,
                    .dest = .{ .register = intermediate },
                    .src1 = .{ .register = dim_reg },
                    .src2 = .{ .register = self.raw_tidx_reg.? },
                } });
            }
            try self.generator.body.append(.{ .mul = .{
                .type = .u32,
                .dest = .{ .register = address },
                .src1 = .{ .register = if (axis == .row) dim_reg else intermediate },
                .src2 = if (axis == .row) .{ .register = self.raw_tidy_reg.? } else .{ .immediate = .{ .integer = 4 } },
                .modifier = .wide,
            } });
            if (axis == .row) {
                try self.generator.body.append(.{ .add = .{
                    .type = .u64,
                    .dest = .{ .register = address },
                    .src1 = .{ .register = address },
                    .src2 = .{ .immediate = .{ .integer = @intCast(4 * x) } },
                } });
            }
            try self.generator.body.append(.{ .add = .{
                .type = .u64,
                .dest = .{ .register = address },
                .src1 = .{ .register = address },
                .src2 = .{ .register = self.param_address_regs.get(tensor_id).? },
            } });

            try self.generator.body.append(.{
                .ld = .{
                    .type = .f32,
                    .space = .global,
                    .dest = .{ .register = dest },
                    .src = .{
                        .register = address,
                    },
                },
            });

            try regs.append(dest);
        }

        const slice = try regs.toOwnedSlice();
        if (axis == .row) try self.local_row_regs.put(tensor_id, slice) else try self.local_col_regs.put(tensor_id, slice);

        return slice;
    }

    fn getLocalAxisRegisters(self: *MemoryLoader, tensor_id: usize, axis: enum { row, col }) ![][]const u8 {
        const dims = self.generator.program.tensor_store.items[tensor_id].dimensions;
        const loaded_regs = if (axis == .row) self.local_row_regs.get(tensor_id) else self.local_col_regs.get(tensor_id);
        if (loaded_regs == null) {
            if (try self.checkIfInputParam(tensor_id) == true) {
                return try self.getLocalAxisParamRegisters(tensor_id, if (axis == .row) .row else .col);
            } else {
                const input_dest = try self.getLocalMatrixRegister(tensor_id);
                var regs = std.ArrayList([]const u8).init(self.allocator);

                for (0..dims[if (axis == .row) 0 else 1]) |x| {
                    const dest = try self.generator.reg_manager.getRegister(.f);

                    const reg = try self.generator.reg_manager.getRegister(.r);

                    if (axis == .row) {
                        try self.generator.body.append(.{ .mul = .{
                            .type = .u32,
                            .modifier = .lo,
                            .dest = .{ .register = reg },
                            .src1 = .{ .register = self.raw_tidy_reg.? },
                            .src2 = .{ .immediate = .{ .integer = @intCast(dims[0]) } },
                        } });
                    }
                    try self.generator.body.append(.{ .add = .{
                        .type = .u32,
                        .dest = .{ .register = reg },
                        .src1 = .{ .register = if (axis == .row) reg else self.raw_tidx_reg.? },
                        .src2 = .{ .immediate = .{ .integer = @intCast(if (axis == .row) x else x * dims[1]) } },
                    } });

                    try self.generator.body.append(.{ .shfl = .{
                        .dest = .{ .register = dest },
                        .src = .{ .register = input_dest },
                        .offset_or_source = .{ .register = reg },
                        .lane_mask = .{ .register = reg },
                        .mask = .{ .immediate = .{ .integer = 0xffffffff } },
                        .type = .b32,
                        .mode = .idx,
                    } });

                    try regs.append(dest);
                }

                return try regs.toOwnedSlice();
            }
        } else return loaded_regs.?;
    }

    fn getLocalRowRegisters(self: *MemoryLoader, tensor_id: usize) ![][]const u8 {
        return try self.getLocalAxisRegisters(tensor_id, .row);
    }

    fn getLocalColRegisters(self: *MemoryLoader, tensor_id: usize) ![][]const u8 {
        return try self.getLocalAxisRegisters(tensor_id, .col);
    }

    fn checkIfInputParam(self: *MemoryLoader, tensor_id: usize) !bool {
        for (self.generator.program.params.items) |param| {
            if (param.id == tensor_id and param.input == true) {
                return true;
            }
        }
        return false;
    }
};

const Generator = struct {
    allocator: std.mem.Allocator,
    program: nodes.RHLOProgram,
    module: types.LLVMModuleRef,

    body: std.ArrayList(ptxast.Instruction),
    directives: std.ArrayList(ptxast.Directive),

    reg_manager: RegisterManager,
    memory_loader: MemoryLoader,

    pub fn init(allocator: std.mem.Allocator, module: types.LLVMModuleRef, program: nodes.RHLOProgram) !*Generator {
        const generator_ptr = try allocator.create(Generator);
        generator_ptr.* = Generator{
            .allocator = allocator,
            .program = program,
            .module = module,
            .body = std.ArrayList(ptxast.Instruction).init(allocator),
            .directives = std.ArrayList(ptxast.Directive).init(allocator),
            .reg_manager = RegisterManager.init(allocator),
            .memory_loader = undefined,
        };
        generator_ptr.memory_loader = try MemoryLoader.init(generator_ptr, allocator);
        return generator_ptr;
    }

    pub fn generatePTX(self: *Generator) !ptxast.Kernel {
        for (self.program.ops.items) |op| {
            const dest = try self.memory_loader.getLocalMatrixRegister(op.output_ids[0]);

            switch (op.kind) {
                .Add => {
                    const a = try self.memory_loader.getLocalMatrixRegister(op.input_ids[0]);
                    const b = try self.memory_loader.getLocalMatrixRegister(op.input_ids[1]);
                    try self.body.append(.{
                        .add = .{
                            .type = .f32,
                            .src1 = .{ .register = a },
                            .src2 = .{ .register = b },
                            .dest = .{ .register = dest },
                        },
                    });
                },
                .Matmul => {
                    const a_row_regs = try self.memory_loader.getLocalRowRegisters(op.input_ids[0]);
                    const b_col_regs = try self.memory_loader.getLocalColRegisters(op.input_ids[1]);

                    for (a_row_regs, 0..) |x, idx| {
                        try self.body.append(.{
                            .fma = .{
                                .type = .f32,
                                .dest = .{ .register = dest },
                                .src1 = .{ .register = x },
                                .src2 = .{ .register = b_col_regs[idx] },
                                .src3 = .{ .register = dest },
                            },
                        });
                    }
                },
            }
        }

        for (self.program.params.items) |param| {
            if (param.output == true) {
                try self.memory_loader.storeLocalMatrixValue(param.id, try self.memory_loader.getLocalMatrixRegister(param.id));
            }
        }

        try self.body.append(.ret);

        const reg_r_decl = ptxast.Directive{ .reg = .{
            .name = "%r",
            .count = @intCast(self.reg_manager.reg_r_count),
            .type = .u32,
        } };
        const reg_rd_decl = ptxast.Directive{ .reg = .{
            .name = "%rd",
            .count = @intCast(self.reg_manager.reg_rd_count),
            .type = .b64,
        } };
        const reg_f_decl = ptxast.Directive{ .reg = .{
            .name = "%f",
            .count = @intCast(self.reg_manager.reg_f_count),
            .type = .f32,
        } };

        try self.directives.append(reg_r_decl);
        try self.directives.append(reg_rd_decl);
        try self.directives.append(reg_f_decl);

        return ptxast.Kernel{
            .body = try self.body.toOwnedSlice(),
            .directives = try self.directives.toOwnedSlice(),
            .name = "main",
            .params = try self.memory_loader.raw_params.toOwnedSlice(),
        };
    }
};
