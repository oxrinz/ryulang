const std = @import("std");

const rllvm = @import("rllvm");
const llvm = rllvm.llvm;
const target = llvm.target;
const target_machine = llvm.target_machine;
const types = llvm.types;
const core = llvm.core;
const process = std.process;
const mem = std.mem;
const execution = llvm.engine;
const debug = llvm.debug;
const analysis = llvm.analysis;

const Allocator = std.mem.Allocator;

const diagnostics = @import("diagnostics.zig");
const Lexer = @import("frontend/lexer.zig").Lexer;
const Parser = @import("frontend/parser.zig").Parser;
const Generator = @import("rir/rir-gen.zig").Generator;
const rir = @import("rir/rir.zig");
const dashboard = @import("dashboard.zig");

const prettyprinter = @import("pretty-printer.zig");

const CompilerArgs = struct {
    var llvm_emit = false;
    var print_tokens = false;
    var print_ast = false;
    var nvidiasm = false;
    var entry_file: ?[]const u8 = null;
};

pub fn main() anyerror!void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    var arena_instance = std.heap.ArenaAllocator.init(debug_allocator.allocator());
    defer diagnostics.arena.deinit();
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try process.argsAlloc(arena);
    const cmd = args[1];
    const cmd_args = args[2..];

    var print_tokens = false;
    var print_ast = false;
    var dump_llvm = false;
    var entry_file: ?[]const u8 = null;

    var i: usize = 0;
    while (i < cmd_args.len) : (i += 1) {
        const arg = cmd_args[i];
        if (mem.eql(u8, arg, "--print-tokens")) {
            print_tokens = true;
        } else if (mem.eql(u8, arg, "--print-ast")) {
            print_ast = true;
        } else if (mem.eql(u8, arg, "--dump-llvm")) {
            dump_llvm = true;
        } else if (mem.eql(u8, arg, "--debug")) {
            // TODO: enable / disable debugging
        } else if (entry_file == null and !mem.startsWith(u8, arg, "-")) {
            entry_file = arg;
        }
    }

    const file = try std.fs.cwd().openFile(entry_file.?, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const source = try arena.alloc(u8, file_size);
    const bytes_read = try file.readAll(source);

    if (bytes_read != file_size) {
        std.debug.print("Error: Could not read entire file\n", .{});
        std.process.exit(1);
    }

    var lexer = Lexer.init(arena, source);
    lexer.scan();

    if (print_tokens == true) {
        std.debug.print("\n======== Tokens ========\n", .{});
        for (lexer.tokens.items) |token| {
            std.debug.print("{s} '{?}' at line {d}\n", .{
                @tagName(token.type),
                token.literal,
                token.line,
            });
        }
        std.debug.print("========================\n", .{});
    }

    var parser = try Parser.init(lexer.tokens.items, arena);
    const module_definition = try parser.parse();
    if (print_ast == true) {
        std.debug.print("\n======== Program ========\n", .{});
        try prettyprinter.printAst(arena, &module_definition);
        std.debug.print("===========================\n", .{});
    }

    var generator = Generator.init(module_definition, arena);
    const ops = try generator.generate();

    const base_graph_stage = dashboard.Stage{
        .title = "Base Graph",
        .ops = ops,
    };
    const stages = [_]dashboard.Stage{base_graph_stage};
    const op_json = try dashboard.prepareStages(arena, &stages);

    dashboard.sendToDashboard(arena, op_json) catch |err| {
        if (err == error.ConnectionRefused) {
            std.debug.print("Connection to dashboard refused... Continuing without dashboard\n", .{});
        } else return err;
    };

    const module = try @import("codegen.zig").compile(ops);

    if (dump_llvm == true) {
        std.debug.print("\n========= LLVM =========\n", .{});
        var err: [*c]u8 = null;
        const filename = "module.ll";
        if (core.LLVMPrintModuleToFile(module, filename, &err) != 0) {
            std.debug.print("Error writing module to file: {s}\n", .{err});
            core.LLVMDisposeMessage(err);
            return error.DumpError;
        }
        std.debug.print("Module dumped to {s}\n", .{filename});
        std.debug.print("===========================\n", .{});
    }

    var error_msg: [*c]u8 = null;
    if (analysis.LLVMVerifyModule(module, .LLVMReturnStatusAction, &error_msg) != 0) {
        if (error_msg != null) {
            std.debug.print("Module verification failed: {s}\n", .{error_msg});
            core.LLVMDisposeMessage(error_msg);
        }
        return error.InvalidModule;
    }

    if (mem.eql(u8, cmd, "run")) {
        execute(module) catch |err| {
            std.debug.print("{}", .{err});
            diagnostics.printAll();
            std.process.exit(0);
        };
    } else if (mem.eql(u8, cmd, "build")) {
        build(arena, module) catch |err| {
            std.debug.print("{}", .{err});
            diagnostics.printAll();
            std.process.exit(0);
        };
    }
}

fn build(allocator: std.mem.Allocator, module: types.LLVMModuleRef) anyerror!void {
    const triple = target_machine.LLVMGetDefaultTargetTriple();
    defer core.LLVMDisposeMessage(triple);

    var error_msg: [*c]u8 = null;
    var target_ref: types.LLVMTargetRef = undefined;
    if (target_machine.LLVMGetTargetFromTriple(triple, &target_ref, &error_msg) != 0) {
        std.debug.print("Error getting target: {s}\n", .{error_msg});
        core.LLVMDisposeMessage(error_msg);
        return error.TargetError;
    }

    const cpu = "generic";
    const features = "";
    const tm = target_machine.LLVMCreateTargetMachine(target_ref, triple, cpu, features, .LLVMCodeGenLevelDefault, .LLVMRelocDefault, .LLVMCodeModelDefault);
    if (tm == null) {
        return error.TargetMachineCreationFailed;
    }
    defer target_machine.LLVMDisposeTargetMachine(tm);

    const debug_version = debug.LLVMDebugMetadataVersion();
    const debug_val = core.LLVMValueAsMetadata(core.LLVMConstInt(core.LLVMInt32Type(), debug_version, 0));
    const key = "Debug Info Version";
    core.LLVMAddModuleFlag(module, .LLVMModuleFlagBehaviorWarning, key, key.len, debug_val);

    const output_filename = "output.o";
    if (target_machine.LLVMTargetMachineEmitToFile(tm, module, output_filename, .LLVMObjectFile, &error_msg) != 0) {
        std.debug.print("Error emitting to file: {s}\n", .{error_msg});
        core.LLVMDisposeMessage(error_msg);
        return error.EmitError;
    }

    const libcuda_path = try std.process.getEnvVarOwned(allocator, "LIBCUDA");
    var child = std.process.Child.init(&[_][]const u8{
        "cc",
        "output.o",
        "-o",
        "program",
        "-g",
        libcuda_path,
        "-lcuda",
    }, allocator);
    child.stdout = std.io.getStdOut();
    child.stderr = std.io.getStdErr();
    const term = try child.spawnAndWait();
    if (term.Exited != 0) {
        return error.LinkError;
    }

    try std.fs.cwd().deleteFile(output_filename);
}

fn execute(module: types.LLVMModuleRef) !void {
    var error_msg: [*c]u8 = null;
    var engine: types.LLVMExecutionEngineRef = undefined;
    if (execution.LLVMCreateExecutionEngineForModule(&engine, module, &error_msg) != 0) {
        std.debug.print("Execution engine creation failed: {s}\n", .{error_msg});
        core.LLVMDisposeMessage(error_msg);
        @panic("failed to create exec engine");
    }
    defer execution.LLVMDisposeExecutionEngine(engine);

    const main_addr = execution.LLVMGetFunctionAddress(engine, "main");
    const MainFn = fn () callconv(.C) f32;
    const main_fn: *const MainFn = @ptrFromInt(main_addr);

    _ = main_fn();
}
