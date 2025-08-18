const std = @import("std");

const rllvm = @import("rllvm");
const llvm = rllvm.llvm;
const core = llvm.core;
const types = llvm.types;
const target = llvm.target;

pub const MOP = union(enum) {};

pub const MizuProgram = struct {
    ops: []const MOP,

    pub fn execute() !types.LLVMModuleRef {}
};
