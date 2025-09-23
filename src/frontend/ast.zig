const std = @import("std");
const rir = @import("../rir/rir.zig");
const DType = @import("../rir/dtype.zig").DType;

pub const BinaryOperator = enum {
    Add,
    Subtract,
    Multiply,
    Divide,
    Remainder,

    Bitwise_AND,
    Bitwise_OR,
    Bitwise_XOR,
    Left_Shift,
    Right_Shift,

    Less,
    Less_Or_Equal,
    Greater,
    Greater_Or_Equal,
    Equal,
    Not_Equal,
    And,
    Or,

    pub fn getType(op: *const BinaryOperator) enum { ARITHMETIC, BITWISE, COMPARISON, SHORT_CIRCUIT } {
        switch (op.*) {
            .Add, .Subtract, .Multiply, .Divide, .Remainder => return .ARITHMETIC,
            .Bitwise_AND, .Bitwise_OR, .Bitwise_XOR, .Left_Shift, .Right_Shift => return .BITWISE,
            .Less, .Less_Or_Equal, .Greater, .Greater_Or_Equal, .Equal, .Not_Equal => return .COMPARISON,
            .And, .Or => return .SHORT_CIRCUIT,
        }
    }
};

pub const Binary = struct {
    operator: BinaryOperator,
    left: *Expression,
    right: *Expression,
};

pub const Variable = struct {
    identifier: []const u8,
};

pub const Call = struct {
    identifier: []const u8,
    args: []*Expression,
};

pub const BuiltinCall = struct {
    identifier: []const u8,
    args: []*Expression,
};

pub const Constant = struct {
    ptr: *anyopaque,
    shape: []const usize,
    dtype: DType,

    pub fn asBytes(self: @This()) []const u8 {
        const ptr_as_bytes: [*]const u8 = @ptrCast(self.ptr);
        return ptr_as_bytes[0..self.getSizeInBytes()];
    }

    pub fn getSizeInBytes(self: @This()) usize {
        return self.getSize() * self.dtype.getSizeInBytes();
    }

    pub fn getSize(self: @This()) usize {
        var size: usize = 1;
        for (self.shape) |dim| {
            size *= dim;
        }
        return size;
    }
};

pub const Expression = union(enum) {
    constant: Constant,
    binary: Binary,
    variable: Variable,
    call: Call,
    builtin_call: BuiltinCall,
};

pub const Assign = struct {
    target: []const u8,
    value: Expression,
};

pub const FunctionDefinition = struct {
    identifier: []const u8,
    args: []*Expression,
    body: Block,
    returns: ?bool = null,
};

pub const Statement = union(enum) {
    function_definition: FunctionDefinition,
    compound: *Statement,
    expr: Expression,
    assign: Assign,
};

pub const Block = struct {
    items: []Statement,
};

pub const Module = struct {
    block: Block,
};
