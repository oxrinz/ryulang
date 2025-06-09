const std = @import("std");
const llvm = @import("rllvm").llvm;
const target = llvm.target;
const types = llvm.types;
const core = llvm.core;
const process = std.process;
const mem = std.mem;
const Allocator = std.mem.Allocator;

const diagnostics = @import("diagnostics.zig");
const Lexer = @import("frontend/lexer.zig").Lexer;
const Parser = @import("frontend/parser.zig").Parser;
const Generator = @import("rir/rir-gen.zig").Generator;
const rir = @import("rir/rir.zig");

const prettyprinter = @import("pretty-printer.zig");

const c = @cImport({
    @cInclude("string.h");
});

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

    if (mem.eql(u8, cmd, "run")) {
        build(arena, cmd_args) catch {
            diagnostics.printAll();
            std.process.exit(0);
        };
    }
}

fn sendToDashboard(allocator: Allocator, op_json: []const u8) anyerror!void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var buf: [4096]u8 = undefined;

    const uri = try std.Uri.parse("http://localhost:5173/");
    var req = try client.open(.POST, uri, .{ .server_header_buffer = &buf });
    defer req.deinit();

    const payload = op_json;
    req.transfer_encoding = .{ .content_length = payload.len };
    req.headers.content_type = .{ .override = "application/json" };

    try req.send();
    try req.writeAll(payload);
    try req.finish();
    try req.wait();
}

const Node = struct { title: []const u8 };
const Edge = struct { source: usize, target: usize };

fn traverse(
    op: rir.RIROP,
    nodes: *std.AutoHashMap(usize, Node),
    edges: *std.ArrayList(Edge),
    id_counter: *usize,
    alloc: Allocator,
) anyerror!usize {
    const current_id = id_counter.*;
    id_counter.* += 1;

    const title: []const u8 = switch (op) {
        .add => try std.fmt.allocPrint(alloc, "Add", .{}),
        .divide => try std.fmt.allocPrint(alloc, "Divide", .{}),
        .sqrt => try std.fmt.allocPrint(alloc, "Sqrt", .{}),
        .call => |call_op| try std.fmt.allocPrint(alloc, "Call: {s}", .{call_op.identifier}),
        .random => try std.fmt.allocPrint(alloc, "Random", .{}),
        .constant => |const_op| switch (const_op) {
            .int => |val| try std.fmt.allocPrint(alloc, "Const: {}", .{val}),
            .float => |val| try std.fmt.allocPrint(alloc, "Const: {}", .{val}),
            .string => |val| try std.fmt.allocPrint(alloc, "Const: {s}", .{val}),
            .array_int => try std.fmt.allocPrint(alloc, "Const: [int array]", .{}),
            .array_float => try std.fmt.allocPrint(alloc, "Const: [float array]", .{}),
        },
        .ret => try std.fmt.allocPrint(alloc, "Return", .{}),
    };

    try nodes.put(current_id, .{ .title = title });

    switch (op) {
        .add => |add_op| {
            const a_id = try traverse(add_op.a.*, nodes, edges, id_counter, alloc);
            const b_id = try traverse(add_op.b.*, nodes, edges, id_counter, alloc);
            try edges.append(.{ .source = current_id, .target = a_id });
            try edges.append(.{ .source = current_id, .target = b_id });
        },
        .divide => |div_op| {
            const a_id = try traverse(div_op.a.*, nodes, edges, id_counter, alloc);
            const b_id = try traverse(div_op.b.*, nodes, edges, id_counter, alloc);
            try edges.append(.{ .source = current_id, .target = a_id });
            try edges.append(.{ .source = current_id, .target = b_id });
        },
        .sqrt => |sqrt_op| {
            const a_id = try traverse(sqrt_op.a.*, nodes, edges, id_counter, alloc);
            try edges.append(.{ .source = current_id, .target = a_id });
        },
        .call => |call_op| {
            for (call_op.args.*) |arg| {
                const arg_id = try traverse(arg.*, nodes, edges, id_counter, alloc);
                try edges.append(.{ .source = current_id, .target = arg_id });
            }
        },
        .random => |rand_op| {
            const shape_id = try traverse(rand_op.shape.*, nodes, edges, id_counter, alloc);
            try edges.append(.{ .source = current_id, .target = shape_id });
        },
        .ret => |ret_op| {
            const op_id = try traverse(ret_op.op.*, nodes, edges, id_counter, alloc);
            try edges.append(.{ .source = current_id, .target = op_id });
        },
        .constant => {},
    }

    return current_id;
}

fn prepareOps(allocator: Allocator, op: rir.RIROP) anyerror![]const u8 {
    var nodes = std.AutoHashMap(usize, Node).init(allocator);
    defer nodes.deinit();

    var edges = std.ArrayList(Edge).init(allocator);
    defer edges.deinit();

    var id_counter: usize = 0;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    _ = try traverse(op, &nodes, &edges, &id_counter, arena_allocator);

    const SerializableNode = struct { id: []const u8, title: []const u8 };
    var node_array = std.ArrayList(SerializableNode).init(allocator);
    defer node_array.deinit();
    var node_iter = nodes.iterator();
    while (node_iter.next()) |entry| {
        const id_str = try std.fmt.allocPrint(arena_allocator, "{}", .{entry.key_ptr.*});
        try node_array.append(.{ .id = id_str, .title = entry.value_ptr.title });
    }

    const SerializableEdge = struct { source: []const u8, target: []const u8 };
    var edge_array = std.ArrayList(SerializableEdge).init(allocator);
    defer edge_array.deinit();
    for (edges.items) |edge| {
        const source_str = try std.fmt.allocPrint(arena_allocator, "{}", .{edge.source});
        const target_str = try std.fmt.allocPrint(arena_allocator, "{}", .{edge.target});
        try edge_array.append(.{ .source = source_str, .target = target_str });
    }

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try std.json.stringify(.{
        .nodes = node_array.items,
        .edges = edge_array.items,
    }, .{}, buffer.writer());

    return buffer.toOwnedSlice();
}

fn build(allocator: Allocator, args: [][:0]u8) anyerror!void {
    var llvm_emit = false;
    var print_tokens = false;
    var print_ast = false;
    var nvidiasm = false;
    var entry_file: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.eql(u8, arg, "--llvm-emit")) {
            llvm_emit = true;
        } else if (mem.eql(u8, arg, "--print-tokens")) {
            print_tokens = true;
        } else if (mem.eql(u8, arg, "--print-ast")) {
            print_ast = true;
        } else if (mem.eql(u8, arg, "--nvidiasm")) {
            nvidiasm = true;
        } else if (entry_file == null and !mem.startsWith(u8, arg, "-")) {
            entry_file = arg;
        }
    }

    const file = try std.fs.cwd().openFile(entry_file.?, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const source = try allocator.alloc(u8, file_size);
    const bytes_read = try file.readAll(source);

    if (bytes_read != file_size) {
        std.debug.print("Error: Could not read entire file\n", .{});
        std.process.exit(1);
    }

    var lexer = Lexer.init(allocator, source);
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

    var parser = try Parser.init(lexer.tokens.items, allocator);
    const module_definition = try parser.parse();
    if (print_ast == true) {
        std.debug.print("\n======== Program ========\n", .{});
        try prettyprinter.printAst(allocator, &module_definition);
        std.debug.print("===========================\n", .{});
    }

    var generator = Generator.init(module_definition, allocator);
    const op = try generator.generate();
    const op_json = try prepareOps(allocator, op);

    try sendToDashboard(allocator, op_json);

    // if (llvm_emit == true) {
    //     std.debug.print("\n========= LLVM =========\n", .{});
    //     // core.LLVMDumpModule(output);
    //     std.debug.print("==========================\n", .{});
    // }

    // try emit(output.?);

    // core.LLVMDisposeModule(output);
    core.LLVMShutdown();
}

fn emit(module: *llvm.types.LLVMOpaqueModule) !void {
    var error_msg: [*c]u8 = undefined;
    var ee: types.LLVMExecutionEngineRef = undefined;

    if (llvm.engine.LLVMCreateExecutionEngineForModule(&ee, module, &error_msg) != 0) {
        std.debug.print("Failed to create execution engine: {s}\n", .{std.mem.span(error_msg)});
        core.LLVMDisposeMessage(error_msg);
        return error.ExecutionEngineCreationFailed;
    }

    var memory_buffer: types.LLVMMemoryBufferRef = undefined;
    const target_machine = llvm.engine.LLVMGetExecutionEngineTargetMachine(ee);

    if (llvm.target_machine.LLVMTargetMachineEmitToMemoryBuffer(target_machine, module, .LLVMObjectFile, &error_msg, &memory_buffer) != 0) {
        std.debug.print("Error emitting to memory buffer: {s}\n", .{std.mem.span(error_msg)});
        core.LLVMDisposeMessage(error_msg);
        return error.MemoryBufferEmitFailed;
    }
    defer core.LLVMDisposeMemoryBuffer(memory_buffer);

    const obj_data = core.LLVMGetBufferStart(memory_buffer);
    const obj_size = core.LLVMGetBufferSize(memory_buffer);

    const allocator = std.heap.page_allocator;
    const tmp_file = "temp_obj_file.o";

    {
        var file = try std.fs.cwd().createFile(tmp_file, .{});
        defer file.close();
        try file.writeAll(obj_data[0..obj_size]);
    }

    defer {
        std.fs.cwd().deleteFile(tmp_file) catch |err| {
            std.debug.print("Failed to delete temporary file: {}\n", .{err});
        };
    }
    defer {
        std.fs.cwd().deleteFile("program") catch |err| {
            std.debug.print("Failed to delete executable: {}\n", .{err});
        };
    }

    const compile_args = [_][]const u8{
        "cc",
        "-v",
        "-fno-stack-check",
        "-o",
        "program",
        tmp_file,
        "lib/runtime/libruntime.a",
        "/run/opengl-driver/lib/libcuda.so",
        "-lcuda",
    };

    const compile_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &compile_args,
        .max_output_bytes = 100 * 1024,
    }) catch |err| {
        std.debug.print("Failed to run compiler: {}\n", .{err});
        return err;
    };
    defer {
        allocator.free(compile_result.stdout);
        allocator.free(compile_result.stderr);
    }

    const run_args = [_][]const u8{
        "./" ++ "program",
    };

    const run_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &run_args,
        .max_output_bytes = 10 * 1024,
    });
    defer {
        allocator.free(run_result.stdout);
        allocator.free(run_result.stderr);
    }

    if (run_result.stdout.len > 0) {
        std.debug.print("{s}\n", .{run_result.stdout});
    }

    if (run_result.stderr.len > 0) {
        std.debug.print("{s}\n", .{run_result.stderr});
    }

    switch (run_result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Program exited with code {}\n", .{code});
            }
        },
        .Signal => |sig| {
            const desc = c.strsignal(@intCast(sig));
            std.debug.print("Program terminated by signal {d}: {s}\n", .{ sig, std.mem.span(desc) });
        },
        else => unreachable,
    }
}

test "graphviz" {
    const allocator = std.testing.allocator;

    var const1 = rir.RIROP{ .constant = .{ .int = 1 } };
    var const2 = rir.RIROP{ .constant = .{ .int = 2 } };
    const add_op = rir.RIROP{
        .add = .{
            .a = &const1,
            .b = &const2,
        },
    };

    const json = try prepareOps(allocator, add_op);
    defer allocator.free(json);

    std.debug.print("{s}\n", .{json});

    try sendToDashboard(allocator, json);
}
