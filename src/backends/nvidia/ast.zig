const std = @import("std");

const DType = @import("../../rir/dtype.zig").DType;

pub const Register = []const u8;

pub const Immediate = union(enum) {
    integer: i64,
    float: f64,
};

pub const Param = []const u8;

pub const Operand = union(enum) {
    register: Register,
    immediate: Immediate,
    memory: MemoryRef,
    parameter: Param,
};

pub const MemoryRef = struct {
    address: []const u8,
    type: DType,
};

pub fn convertDType(dtype: DType) []const u8 {
    return switch (dtype) {
        .i32 => "s32",
        .i64 => "s64",
        else => return @tagName(dtype),
    };
}

pub const SpaceType = enum {
    global,
    shared,
    local,
    param,
    pub fn toString(self: SpaceType) []const u8 {
        return @tagName(self);
    }
};

pub const Instruction = union(enum) {
    add: AddInst,
    mul: MulInst,
    _and: AndInst,
    shl: ShiftLeftInst,
    mov: MoveInst,
    ld: LoadInst,
    st: StoreInst,
    bra: BranchInst,
    cvta: ConvertToAddrInst,
    fma: FusedMultiplyAddInst,
    shfl: ShuffleInst,
    setp: SetpInst,
    label: LabelInst,
    comment: []const u8,
    ret,
};

pub const AddInst = struct {
    dest: Operand,
    src1: Operand,
    src2: Operand,
    type: DType,
    wide: bool = false,
    modifier: enum {
        none,
        lo,
        hi,
        wide,
        sat,
        pub fn toString(self: @This()) []const u8 {
            return switch (self) {
                .none => "",
                .lo => ".lo",
                .hi => ".hi",
                .wide => ".wide",
                .sat => ".sat",
            };
        }
    } = .none,
};

pub const AndInst = struct {
    dest: Operand,
    src1: Operand,
    src2: Operand,
    type: DType,
};

pub const FusedMultiplyAddInst = struct {
    dest: Operand,
    src1: Operand,
    src2: Operand,
    src3: Operand,
    type: DType,
    modifier: enum {
        none,
        lo,
        hi,
        wide,
        sat,
        pub fn toString(self: @This()) []const u8 {
            return switch (self) {
                .none => "",
                .lo => ".lo",
                .hi => ".hi",
                .wide => ".wide",
                .sat => ".sat",
            };
        }
    } = .none,
};

pub const MulInst = struct {
    dest: Operand,
    src1: Operand,
    src2: Operand,
    type: DType,
    modifier: enum {
        none,
        lo,
        hi,
        wide,
        sat,
        pub fn toString(self: @This()) []const u8 {
            return switch (self) {
                .none => "",
                .lo => ".lo",
                .hi => ".hi",
                .wide => ".wide",
                .sat => ".sat",
            };
        }
    } = .none,
};

pub const ShiftLeftInst = struct {
    dest: Operand,
    src1: Operand,
    src2: Operand,
    type: DType,
};

pub const MoveInst = struct {
    dest: Operand,
    src: Operand,
    type: DType,
};

pub const LoadInst = struct {
    dest: Operand,
    src: Operand,
    type: DType,
    space: SpaceType,
};

pub const StoreInst = struct {
    dest: Operand,
    src: Operand,
    type: DType,
    space: SpaceType,
};

pub const BranchInst = struct {
    label: []const u8,
    predicate: ?Operand,
};

pub const ConvertToAddrInst = struct {
    to_generic: bool,
    space: SpaceType,
    type: DType,
    dest: Operand,
    src: Operand,
};

pub const ShuffleInst = struct {
    dest: Operand,
    src: Operand,
    offset_or_source: Operand,
    lane_mask: Operand,
    mask: Operand,
    type: DType,
    mode: Mode,
    pub const Mode = enum {
        up,
        down,
        bfly,
        idx,
        pub fn toString(self: Mode) []const u8 {
            return switch (self) {
                .up => "up",
                .down => "down",
                .bfly => "bfly",
                .idx => "idx",
            };
        }
    };
};

pub const SetpInst = struct {
    dest: []const u8,
    src1: Operand,
    src2: Operand,
    type: DType,
    cmp: CompareOp,
    pub const CompareOp = enum {
        eq,
        ne,
        lt,
        le,
        gt,
        ge,
        pub fn toString(self: CompareOp) []const u8 {
            return @tagName(self);
        }
    };
};

pub const LabelInst = struct {
    name: []const u8,
};

pub const Kernel = struct {
    name: []const u8,
    params: [][]const u8,
    body: []Instruction,
    directives: []Directive,
};

pub const Directive = union(enum) {
    reg: RegisterDecl,
    global: GlobalDecl,
};

pub const RegisterDecl = struct {
    type: DType,
    count: u32,
    name: []const u8,
};

pub const GlobalDecl = struct {
    name: []const u8,
    size: u64,
    type: DType,
};

pub const PTXAst = struct {
    kernels: []Kernel,
    globals: []GlobalDecl,
    allocator: std.mem.Allocator,
    fn deinit(self: *PTXAst) void {
        for (self.kernels) |kernel| {
            self.allocator.free(kernel.params);
            self.allocator.free(kernel.body);
            self.allocator.free(kernel.directives);
        }
        self.allocator.free(self.kernels);
        self.allocator.free(self.globals);
    }
};
