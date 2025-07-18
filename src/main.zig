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
    const op_json = try dashboard.prepareOps(arena, ops);

    dashboard.sendToDashboard(arena, op_json) catch |err| {
        if (err == error.ConnectionRefused) {
            std.debug.print("Connection to dashboard refused... Continuing without dashboard\n", .{});
        } else return err;
    };

    const module = try @import("codegen/nvidia.zig").compile(ops);

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

    if (analysis.LLVMVerifyModule(module, .LLVMReturnStatusAction, &error_msg) != 0) {
        if (error_msg != null) {
            std.debug.print("Module verification failed: {s}\n", .{error_msg});
            core.LLVMDisposeMessage(error_msg);
        }
        return error.InvalidModule;
    }

    const debug_version = debug.LLVMDebugMetadataVersion();
    const debug_val = core.LLVMValueAsMetadata(core.LLVMConstInt(core.LLVMInt32Type(), debug_version, 0));
    const key = "Debug Info Version";
    core.LLVMAddModuleFlag(module, .LLVMModuleFlagBehaviorWarning, key, key.len, debug_val);
    std.debug.print("ended\n", .{});

    const output_filename = "output.o";
    if (target_machine.LLVMTargetMachineEmitToFile(tm, module, output_filename, .LLVMObjectFile, &error_msg) != 0) {
        std.debug.print("Error emitting to file: {s}\n", .{error_msg});
        core.LLVMDisposeMessage(error_msg);
        return error.EmitError;
    }
    std.debug.print("ended\n", .{});

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

// fn execute(module: types.LLVMModuleRef) !void {
//     // Declare printf in the module
//     const context = core.LLVMGetModuleContext(module);
//     const i8_ptr_ty = core.LLVMPointerType(core.LLVMInt8TypeInContext(context), 0);
//     var param_types = [_]types.LLVMTypeRef{i8_ptr_ty};
//     const printf_ty = core.LLVMFunctionType(core.LLVMInt32TypeInContext(context), &param_types, 1, 1 // Vararg
//     );
//     const printf_func = core.LLVMAddFunction(module, "printf", printf_ty);

//     // Create a new function to call printf
//     const fn_ty = core.LLVMFunctionType(core.LLVMVoidTypeInContext(context), null, 0, 0);
//     const wrapper_fn = core.LLVMAddFunction(module, "print_hello", fn_ty);
//     const entry = core.LLVMAppendBasicBlockInContext(context, wrapper_fn, "entry");
//     const builder = core.LLVMCreateBuilderInContext(context);
//     defer core.LLVMDisposeBuilder(builder);
//     core.LLVMPositionBuilderAtEnd(builder, entry);

//     // Create format string and call printf
//     const fmt_str = core.LLVMBuildGlobalStringPtr(builder, "Hello from JIT!\n", "fmt");
//     var args = [_]types.LLVMValueRef{fmt_str};
//     _ = core.LLVMBuildCall2(builder, printf_ty, printf_func, &args, 1, "call_printf");
//     _ = core.LLVMBuildRetVoid(builder);

//     // Create execution engine
//     var error_msg: [*c]u8 = null;
//     var engine: types.LLVMExecutionEngineRef = undefined;
//     if (execution.LLVMCreateExecutionEngineForModule(&engine, module, &error_msg) != 0) {
//         std.debug.print("Execution engine creation failed: {s}\n", .{error_msg});
//         core.LLVMDisposeMessage(error_msg);
//         @panic("failed to create exec engine");
//     }
//     defer execution.LLVMDisposeExecutionEngine(engine);

//     std.debug.print("executing\n", .{});

//     // Execute the printf wrapper function
//     const print_addr = execution.LLVMGetFunctionAddress(engine, "print_hello");
//     const PrintFn = fn () callconv(.C) void;
//     const print_fn: *const PrintFn = @ptrFromInt(print_addr);
//     print_fn();

//     // Execute the main function
//     const main_addr = execution.LLVMGetFunctionAddress(engine, "main");
//     const MainFn = fn () callconv(.C) f32;
//     const main_fn: *const MainFn = @ptrFromInt(main_addr);
//     _ = main_fn();
// }

fn execute(module: types.LLVMModuleRef) !void {
    var error_msg: [*c]u8 = null;
    var engine: types.LLVMExecutionEngineRef = undefined;
    if (execution.LLVMCreateExecutionEngineForModule(&engine, module, &error_msg) != 0) {
        std.debug.print("Execution engine creation failed: {s}\n", .{error_msg});
        core.LLVMDisposeMessage(error_msg);
        @panic("failed to create exec engine");
    }
    defer execution.LLVMDisposeExecutionEngine(engine);

    // _ = core.LLVMDumpModule(module);

    const main_addr = execution.LLVMGetFunctionAddress(engine, "main");
    const MainFn = fn () callconv(.C) f32;
    const main_fn: *const MainFn = @ptrFromInt(main_addr);

    _ = main_fn();
}
