const std = @import("std");
const tokens_script = @import("tokens.zig");
const Token = tokens_script.Token;
const TokenType = tokens_script.TokenType;
const ast = @import("ast.zig");
const rir = @import("../rir/rir.zig");
const DType = @import("../rir/dtype.zig").DType;

pub const Parser = struct {
    tokens: []const Token,
    cursor: usize,
    allocator: std.mem.Allocator,

    pub fn init(tokens: []const Token, allocator: std.mem.Allocator) !Parser {
        return Parser{
            .tokens = tokens,
            .cursor = 0,
            .allocator = allocator,
        };
    }

    pub fn parse(self: *Parser) !ast.Module {
        var stmt_array = std.array_list.Managed(ast.Statement).init(self.allocator);
        while (self.cursor < self.tokens.len - 1 and self.curr().type != .RIGHT_BRACE) {
            try stmt_array.append(try self.parseStatement());
        }
        return ast.Module{ .block = .{ .items = try stmt_array.toOwnedSlice() } };
    }

    fn parseBlock(self: *Parser) !ast.Block {
        var stmt_array = std.array_list.Managed(ast.Statement).init(self.allocator);
        while (self.curr().type != .RIGHT_BRACE) {
            try stmt_array.append(try self.parseStatement());
        }
        return ast.Block{ .items = try stmt_array.toOwnedSlice() };
    }

    fn parseStatement(self: *Parser) anyerror!ast.Statement {
        switch (self.curr().type) {
            .NUMBER, .LEFT_BRACKET => {
                const expr = try self.parseExpression(0);
                return .{ .expr = expr.* };
            },
            .IDENTIFIER => {
                if (self.peek(1).?.type == .LEFT_PAREN) {
                    const expr = try self.parseExpression(0);
                    return .{ .expr = expr.* };
                }
                const target = self.curr().literal.?.string;
                self.cursor += 1;
                try self.expect(.EQUAL);
                self.cursor += 1;
                const expr = try self.parseExpression(0);
                return ast.Statement{ .assign = ast.Assign{
                    .target = target,
                    .value = expr.*,
                } };
            },
            .FN => {
                self.cursor += 1;
                if (self.curr().type != .IDENTIFIER) @panic("fn must preceed an identifier");
                const identifier = self.curr().literal.?.string;
                self.cursor += 2;
                const args = try self.parseFunctionArgs();
                self.cursor += 1;
                const body = try self.parseBlock();
                self.cursor += 1;
                return ast.Statement{
                    .function_definition = .{
                        .identifier = identifier,
                        .args = args,
                        .body = body,
                    },
                };
            },
            .AT => {
                const expr = try self.parseExpression(0);
                return .{ .expr = expr.* };
            },
            else => unreachable,
        }
    }

    fn parseExpression(self: *Parser, min_prec: i16) anyerror!*ast.Expression {
        var left = try self.parseFactor();
        while (self.cursor < self.tokens.len and
            tokens_script.is_binary_operator(self.curr().type) and
            self.precedence(self.curr()) >= min_prec)
        {
            const curr_prec = self.precedence(self.curr());
            const operator = self.parseBinop();
            self.cursor += 1;
            const right = try self.parseExpression(curr_prec + 1);
            const new_expr = try self.allocator.create(ast.Expression);
            new_expr.* = .{
                .binary = .{
                    .operator = operator,
                    .left = left,
                    .right = right,
                },
            };
            left = new_expr;
        }
        return left;
    }

    fn parseFactor(self: *Parser) !*ast.Expression {
        var expr = try self.allocator.create(ast.Expression);
        switch (self.curr().type) {
            .NUMBER => {
                const literal = self.curr().literal.?;
                const dtype: DType = switch (literal) {
                    .integer => .i32,
                    .float => .f32,
                    else => unreachable,
                };
                const number: *anyopaque = switch (literal) {
                    .integer => blk: {
                        const ptr = try self.allocator.create(i32);
                        ptr.* = @intCast(literal.integer);
                        break :blk @ptrCast(ptr);
                    },
                    .float => blk: {
                        const ptr = try self.allocator.create(f32);
                        ptr.* = @floatCast(literal.float);
                        break :blk @ptrCast(ptr);
                    },
                    else => unreachable,
                };
                const shape = try self.allocator.create([1]usize);
                shape.* = [_]usize{1};
                const constant = ast.Constant{
                    .ptr = number,
                    .shape = shape,
                    .dtype = dtype,
                };
                expr.* = .{
                    .constant = constant,
                };
                self.cursor += 1;
            },
            .LEFT_PAREN => {
                self.cursor += 1;
                const inner_expr = try self.parseExpression(0);
                try self.expect(.RIGHT_PAREN);
                self.cursor += 1;
                expr = inner_expr;
            },
            .IDENTIFIER => {
                if (self.peek(1) != null and self.peek(1).?.type == .LEFT_PAREN) {
                    self.cursor += 2;
                    expr.* = .{
                        .call = ast.Call{
                            .identifier = self.peek(-2).?.literal.?.string,
                            .args = try self.parseFunctionArgs(),
                        },
                    };
                } else {
                    expr.* = .{
                        .variable = .{
                            .identifier = self.curr().literal.?.string,
                        },
                    };
                    self.cursor += 1;
                }
            },
            .AT => {
                if (self.peek(2) != null and self.peek(2).?.type == .LEFT_PAREN) {
                    self.cursor += 3;
                    expr.* = .{
                        .builtin_call = ast.BuiltinCall{
                            .identifier = self.peek(-2).?.literal.?.string,
                            .args = try self.parseFunctionArgs(),
                        },
                    };
                } else unreachable;
            },
            .LEFT_BRACKET => {
                var value_array = std.array_list.Managed(u8).init(self.allocator);
                var shape_array = std.array_list.Managed(usize).init(self.allocator);
                self.cursor += 1;

                if (self.curr().type == .RIGHT_BRACKET) {
                    self.cursor += 1;
                    try shape_array.append(0);
                    const shape = try shape_array.toOwnedSlice();
                    const data = try value_array.toOwnedSlice();
                    const constant = ast.Constant{
                        .ptr = data.ptr,
                        .dtype = .f32,
                        .shape = shape,
                    };
                    expr.* = .{ .constant = constant };
                    return expr;
                }

                var dtype: DType = undefined;
                var nested_shape: ?[]const usize = null;
                var count: usize = 0;

                var result = try self.parseFactor();
                switch (result.*) {
                    .constant => |constant| {
                        dtype = constant.dtype;
                        try value_array.appendSlice(constant.asBytes());
                        nested_shape = constant.shape;
                    },
                    else => unreachable,
                }
                count += 1;
                try shape_array.append(1);

                while (self.curr().type != .RIGHT_BRACKET) {
                    try self.expect(.COMMA);
                    self.cursor += 1;
                    result = try self.parseFactor();
                    switch (result.*) {
                        .constant => |constant| {
                            if (constant.dtype != dtype) unreachable;
                            if (nested_shape) |ns| {
                                if (!std.mem.eql(usize, ns, constant.shape)) unreachable;
                            } else {
                                nested_shape = constant.shape;
                            }
                            try value_array.appendSlice(constant.asBytes());
                            count += 1;
                        },
                        else => unreachable,
                    }
                }
                self.cursor += 1;

                try shape_array.appendSlice(nested_shape orelse &[_]usize{});
                shape_array.items[0] = count;

                const data = try value_array.toOwnedSlice();
                const shape = try shape_array.toOwnedSlice();
                const constant = ast.Constant{
                    .ptr = data.ptr,
                    .dtype = dtype,
                    .shape = shape,
                };
                expr.* = .{ .constant = constant };
                return expr;
            },
            else => {
                return error.SyntaxError;
            },
        }
        return expr;
    }

    fn parseBinop(self: *Parser) ast.BinaryOperator {
        switch (self.curr().type) {
            .PLUS => return .Add,
            .MINUS => return .Subtract,
            .STAR => return .Multiply,
            .SLASH => return .Divide,
            .PERCENTAGE => return .Remainder,
            .AMPERSAND => return .Bitwise_AND,
            .PIPE => return .Bitwise_OR,
            .CARET => return .Bitwise_XOR,
            .LEFT_SHIFT => return .Left_Shift,
            .RIGHT_SHIFT => return .Right_Shift,
            .LESS => return .Less,
            .LESS_EQUAL => return .Less_Or_Equal,
            .GREATER => return .Greater,
            .GREATER_EQUAL => return .Greater_Or_Equal,
            .EQUAL_EQUAL => return .Equal,
            .BANG_EQUAL => return .Not_Equal,
            .AMPERSAND_AMPERSAND => return .And,
            .PIPE_PIPE => return .Or,
            else => unreachable,
        }
    }

    fn parseFunctionArgs(self: *Parser) ![]*ast.Expression {
        if (self.curr().type == .RIGHT_PAREN) {
            self.cursor += 1;
            return &[_]*ast.Expression{};
        }
        var param_list = std.array_list.Managed(*ast.Expression).init(self.allocator);
        try param_list.append(try self.parseExpression(0));
        while (self.curr().type != .RIGHT_PAREN) {
            try self.expect(.COMMA);
            self.cursor += 1;
            try param_list.append(try self.parseExpression(0));
        }
        try self.expect(.RIGHT_PAREN);
        self.cursor += 1;
        return try param_list.toOwnedSlice();
    }

    fn precedence(self: *Parser, token: Token) i16 {
        _ = self;
        switch (token.type) {
            .EQUAL => return 1,
            .PIPE_PIPE => return 5,
            .AMPERSAND_AMPERSAND => return 10,
            .EQUAL_EQUAL, .BANG_EQUAL => return 30,
            .LESS, .LESS_EQUAL, .GREATER, .GREATER_EQUAL => return 35,
            .LEFT_SHIFT, .RIGHT_SHIFT => return 48,
            .AMPERSAND => return 47,
            .CARET => return 46,
            .PIPE => return 45,
            .PLUS, .MINUS => return 45,
            .STAR, .SLASH, .PERCENTAGE => return 50,
            else => unreachable,
        }
    }

    fn expect(self: *Parser, token_type: TokenType) !void {
        if (self.curr().type != token_type) {
            return error.SyntaxError;
        }
    }

    fn curr(self: *Parser) Token {
        return self.tokens[self.cursor];
    }

    fn peek(self: *Parser, offset: i32) ?Token {
        if (@as(i32, @intCast(self.cursor)) + offset < self.tokens.len - 1) return self.tokens[@intCast(@as(i32, @intCast(self.cursor)) + offset)] else return null;
    }

    fn printCurr(self: *Parser) void {
        std.debug.print("Current token: {}\n", .{self.curr()});
    }
};
