const std = @import("std");

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

pub const ValueType = enum {
    Integer,
    Float,
    String,
    Array,
};

pub const Value = union(ValueType) {
    Integer: i32,
    Float: f32,
    String: []const u8,
    Array: []Value,
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

pub const RuntimeCall = struct {
    function: fn (args: []Value) Expression,
    args: []*Expression,
};

pub const Expression = union(enum) {
    constant: Value,
    binary: Binary,
    variable: Variable,
    call: Call,
    runtime_call: RuntimeCall,
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
