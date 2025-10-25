const std = @import("std");

const rir = @import("rir.zig");
const DType = @import("dtype.zig").DType;

pub const Operand = union(enum) {
    kirop: *KIROP,
    param: *rir.RIROP,

    pub fn getDType(self: *const Operand) DType {
        return switch (self.*) {
            .kirop => |kirop| kirop.getDType(),
            .param => |param| param.getDType(),
        };
    }
};

pub const KIROP = union(enum) {
    add: struct {
        src1: Operand,
        src2: Operand,
    },
    multiply: struct {
        a: Operand,
        b: Operand,
    },
    load: struct { addr: Operand },
    store: struct { src: Operand, addr: Operand },

    convert: struct {
        src: Operand,
        to_type: DType,
    },

    constant: u64,

    special: union(enum) {
        global: enum { x, y, z },
        local: enum { x, y, z },
    },

    pub fn getDType(self: *const KIROP) DType {
        return switch (self.*) {
            .add => |*add| {
                const a_dtype = add.src1.getDType();
                return a_dtype;
            },
            .multiply => |*multiply| {
                return multiply.a.getDType();
            },
            .load => |*load| {
                const dtype = load.addr.getDType();
                return dtype;
            },
            .store => |*store| {
                return store.src.getDType();
            },
            .convert => |*convert| {
                return convert.src.getDType();
            },
            .constant => return .u64,
            // TODO: this system currently assumes that every param is a f32
            .special => return .f32,
        };
    }
};

// TODO: there has to be a better way to do this
pub const LinearKernel = struct { ops: []*KIROP, params: []*rir.RIROP };
pub const GraphKernel = struct { ops: []*KIROP, params: []*rir.RIROP };
