const std = @import("std");
const tokens_script = @import("tokens.zig");
const Token = tokens_script.Token;
const TokenType = tokens_script.TokenType;
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

const BuiltinFnType = enum {
    PRINT,
};

var builtin_fns: std.StringHashMap(BuiltinFnType) = undefined;

pub fn initBuiltinFns(allocator: std.mem.Allocator) !void {
    builtin_fns = std.StringHashMap(BuiltinFnType).init(allocator);

    try builtin_fns.put("print", .PRINT);
}

pub const Parser = struct {
    tokens: []const Token,
    cursor: usize,
    allocator: std.mem.Allocator,

    pub fn init(tokens: []const Token, allocator: std.mem.Allocator) !Parser {
        try initBuiltinFns(allocator);
        return Parser{
            .tokens = tokens,
            .cursor = 0,
            .allocator = allocator,
        };
    }

    pub fn parse(self: *Parser) !ast.Module {
        var stmt_array = std.ArrayList(ast.Statement).init(self.allocator);
        while (self.cursor < self.tokens.len - 1 and self.curr().type != .RIGHT_BRACE) {
            try stmt_array.append(try self.parseStatement());
        }
        return ast.Module{ .block = .{ .items = try stmt_array.toOwnedSlice() } };
    }

    fn parseBlock(self: *Parser) !ast.Block {
        var stmt_array = std.ArrayList(ast.Statement).init(self.allocator);
        while (self.curr().type != .RIGHT_BRACE) {
            try stmt_array.append(try self.parseStatement());
        }
        return ast.Block{ .items = try stmt_array.toOwnedSlice() };
    }

    fn parseStatement(self: *Parser) anyerror!ast.Statement {
        switch (self.curr().type) {
            .NUMBER => {
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
            .STRING => {
                expr.* = .{
                    .constant = .{ .String = self.curr().literal.?.string },
                };
                self.cursor += 1;
            },
            .NUMBER => {
                const constant: ast.Value = switch (self.curr().literal.?) {
                    .integer => .{ .Integer = self.curr().literal.?.integer },
                    .float => .{ .Float = self.curr().literal.?.float },
                    else => unreachable,
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
            .LEFT_BRACKET => {
                var value_array = std.ArrayList(ast.Value).init(self.allocator);
                self.cursor += 1;
                var result = try self.parseFactor();
                try value_array.append(result.*.constant);
                while (self.curr().type != .RIGHT_BRACKET) {
                    try self.expect(.COMMA);
                    self.cursor += 1;
                    result = try self.parseFactor();
                    try value_array.append(result.*.constant);
                }
                self.cursor += 1;

                expr.* = ast.Expression{ .constant = .{ .Array = try value_array.toOwnedSlice() } };

                return expr;
            },
            else => {
                const msg = try std.fmt.allocPrint(diagnostics.arena.allocator(), "Syntax error at line {}. Expected one of the following: NUMBER, LEFT_PAREN, IDENTIFIER, LEFT_BRACKET. Got token type {}", .{
                    self.curr().line,
                    self.curr().type,
                });
                diagnostics.addError(msg, self.curr().line);
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
        var param_list = std.ArrayList(*ast.Expression).init(self.allocator);

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
            const msg = try std.fmt.allocPrint(diagnostics.arena.allocator(), "Syntax error. Expected token type {}. Got token type {}", .{
                token_type,
                self.curr().type,
            });
            diagnostics.addError(msg, self.curr().line);
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
