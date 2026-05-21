const std = @import("std");

pub const Strictness = struct {
    error_on_missing_env: bool = false,
    error_on_arg_out_of_bounds: bool = false,
};

pub const Metadata = struct {
    exe_path: []const u8,
    exe_dir: []const u8,
    exe_filename: []const u8,
    exe_filename_noext: []const u8,
    exe_ext: []const u8,
    exe_ext_dot: []const u8,
    exe_drive: []const u8,
    exe_root: []const u8,
    exe_parent: []const u8,
    args0: []const u8,
    cwd: []const u8,
    temp_dir: []const u8,
    home_dir: []const u8,
    appdata_dir: []const u8,
    localappdata_dir: []const u8,
    programdata_dir: []const u8,
    program_files_dir: []const u8,
    program_files_x86_dir: []const u8,
    documents_dir: []const u8,
    downloads_dir: []const u8,
    desktop_dir: []const u8,
    os: []const u8,
    arch: []const u8,
    dir_sep: []const u8,
    path_sep: []const u8,
};

pub const EvalContext = struct {
    allocator: std.mem.Allocator,
    metadata: Metadata,
    env: *std.process.EnvMap,
    args: []const []const u8,
    strictness: Strictness = .{},
};

pub const Value = union(enum) {
    string: []const u8,
    integer: usize,
    list: []const []const u8,
};

pub const TokenTag = enum {
    identifier,
    integer,
    string,
    colon,
    open_paren,
    close_paren,
    eof,
};

pub const Token = struct {
    tag: TokenTag,
    lexeme: []const u8,
    offset: usize,
    integer: usize = 0,
    string: []const u8 = "",
};

pub const Source = union(enum) {
    base: []const u8,
    env: []const u8,
    args_all,
    args_index: usize,
};

pub const Argument = union(enum) {
    string: []const u8,
    integer: usize,
    expression: *Expression,
};

pub const NamedTransform = struct {
    name: []const u8,
    argument: ?Argument = null,
};

pub const Transform = union(enum) {
    index: usize,
    named: NamedTransform,
};

pub const Expression = struct {
    source: Source,
    transforms: []const Transform,

    pub fn evaluate(self: Expression, ctx: *EvalContext) anyerror!Value {
        var value = try evaluateSource(ctx, self.source);
        for (self.transforms) |transform| {
            value = try applyTransform(ctx, value, transform);
        }
        return value;
    }
};

pub fn tokenize(allocator: std.mem.Allocator, input: []const u8) ![]const Token {
    var tokenizer = Tokenizer{ .input = input };
    var tokens: std.ArrayList(Token) = .empty;
    while (true) {
        const token = try tokenizer.next(allocator);
        try tokens.append(allocator, token);
        if (token.tag == .eof) break;
    }
    return try tokens.toOwnedSlice(allocator);
}

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Expression {
    const tokens = try tokenize(allocator, input);
    var parser = Parser{
        .allocator = allocator,
        .tokens = tokens,
    };
    const expression = try parser.parseExpression();
    if (parser.current().tag != .eof) return error.ExpectedEndOfExpression;
    return expression;
}

pub fn evaluate(input: []const u8, ctx: *EvalContext) anyerror!Value {
    const expression = try parse(ctx.allocator, input);
    return expression.evaluate(ctx);
}

const Tokenizer = struct {
    input: []const u8,
    index: usize = 0,

    fn next(self: *Tokenizer, allocator: std.mem.Allocator) !Token {
        self.skipWhitespace();
        const start = self.index;
        if (self.index >= self.input.len) {
            return .{ .tag = .eof, .lexeme = self.input[self.input.len..], .offset = self.input.len };
        }

        const c = self.input[self.index];
        switch (c) {
            ':' => {
                self.index += 1;
                return .{ .tag = .colon, .lexeme = self.input[start..self.index], .offset = start };
            },
            '(' => {
                self.index += 1;
                return .{ .tag = .open_paren, .lexeme = self.input[start..self.index], .offset = start };
            },
            ')' => {
                self.index += 1;
                return .{ .tag = .close_paren, .lexeme = self.input[start..self.index], .offset = start };
            },
            '"' => return try self.readString(allocator),
            '0'...'9' => return try self.readInteger(),
            else => {
                if (!isIdentStart(c)) return error.UnexpectedCharacter;
                return self.readIdentifier();
            },
        }
    }

    fn skipWhitespace(self: *Tokenizer) void {
        while (self.index < self.input.len) : (self.index += 1) {
            switch (self.input[self.index]) {
                ' ', '\t', '\r', '\n' => {},
                else => break,
            }
        }
    }

    fn readIdentifier(self: *Tokenizer) Token {
        const start = self.index;
        self.index += 1;
        while (self.index < self.input.len and isIdentContinue(self.input[self.index])) {
            self.index += 1;
        }
        return .{
            .tag = .identifier,
            .lexeme = self.input[start..self.index],
            .offset = start,
        };
    }

    fn readInteger(self: *Tokenizer) !Token {
        const start = self.index;
        self.index += 1;
        while (self.index < self.input.len and isDigit(self.input[self.index])) {
            self.index += 1;
        }
        const lexeme = self.input[start..self.index];
        return .{
            .tag = .integer,
            .lexeme = lexeme,
            .offset = start,
            .integer = try std.fmt.parseUnsigned(usize, lexeme, 10),
        };
    }

    fn readString(self: *Tokenizer, allocator: std.mem.Allocator) !Token {
        const start = self.index;
        self.index += 1;

        var out: std.ArrayList(u8) = .empty;
        while (self.index < self.input.len) {
            const c = self.input[self.index];
            switch (c) {
                '"' => {
                    self.index += 1;
                    return .{
                        .tag = .string,
                        .lexeme = self.input[start..self.index],
                        .offset = start,
                        .string = try out.toOwnedSlice(allocator),
                    };
                },
                '\\' => {
                    self.index += 1;
                    if (self.index >= self.input.len) return error.UnterminatedString;
                    const escaped = self.input[self.index];
                    switch (escaped) {
                        '"', '\\', '/' => try out.append(allocator, escaped),
                        'b' => try out.append(allocator, 0x08),
                        'f' => try out.append(allocator, 0x0c),
                        'n' => try out.append(allocator, '\n'),
                        'r' => try out.append(allocator, '\r'),
                        't' => try out.append(allocator, '\t'),
                        'u' => {
                            if (self.index + 4 >= self.input.len) return error.InvalidString;
                            const digits = self.input[self.index + 1 .. self.index + 5];
                            const codepoint = std.fmt.parseUnsigned(u21, digits, 16) catch return error.InvalidString;
                            if (codepoint >= 0xd800 and codepoint <= 0xdfff) return error.InvalidString;
                            var buffer: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(codepoint, &buffer) catch return error.InvalidString;
                            try out.appendSlice(allocator, buffer[0..len]);
                            self.index += 4;
                        },
                        else => return error.InvalidString,
                    }
                    self.index += 1;
                },
                0x00...0x1f => return error.InvalidString,
                else => {
                    try out.append(allocator, c);
                    self.index += 1;
                },
            }
        }
        return error.UnterminatedString;
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    index: usize = 0,

    fn current(self: *const Parser) Token {
        return self.tokens[self.index];
    }

    fn advance(self: *Parser) Token {
        const token = self.current();
        if (self.index + 1 < self.tokens.len) self.index += 1;
        return token;
    }

    fn parseExpression(self: *Parser) anyerror!Expression {
        const source = try self.parseSource();
        var transforms: std.ArrayList(Transform) = .empty;

        while (self.current().tag == .colon) {
            _ = self.advance();
            try transforms.append(self.allocator, try self.parseTransform());
        }

        return .{
            .source = source,
            .transforms = try transforms.toOwnedSlice(self.allocator),
        };
    }

    fn parseSource(self: *Parser) anyerror!Source {
        const token = self.current();
        if (token.tag != .identifier) return error.ExpectedIdentifier;
        _ = self.advance();

        if (std.mem.eql(u8, token.lexeme, "env")) {
            try self.expect(.colon);
            const name = self.current();
            if (name.tag != .string) return error.ExpectedString;
            _ = self.advance();
            return .{ .env = name.string };
        }

        if (std.mem.eql(u8, token.lexeme, "args")) {
            if (self.current().tag == .colon and self.peek(1).tag == .integer) {
                _ = self.advance();
                const index = self.advance();
                return .{ .args_index = index.integer };
            }
            return .args_all;
        }

        return .{ .base = token.lexeme };
    }

    fn parseTransform(self: *Parser) anyerror!Transform {
        const token = self.current();
        switch (token.tag) {
            .integer => {
                _ = self.advance();
                return .{ .index = token.integer };
            },
            .identifier => {
                _ = self.advance();
                var argument: ?Argument = null;
                if (self.current().tag == .open_paren) {
                    _ = self.advance();
                    argument = try self.parseArgument();
                    try self.expect(.close_paren);
                }
                return .{ .named = .{ .name = token.lexeme, .argument = argument } };
            },
            else => return error.ExpectedIdentifier,
        }
    }

    fn parseArgument(self: *Parser) anyerror!Argument {
        const token = self.current();
        switch (token.tag) {
            .string => {
                _ = self.advance();
                return .{ .string = token.string };
            },
            .integer => {
                _ = self.advance();
                return .{ .integer = token.integer };
            },
            .identifier => {
                const nested = try self.allocator.create(Expression);
                nested.* = try self.parseExpression();
                return .{ .expression = nested };
            },
            else => return error.ExpectedArgument,
        }
    }

    fn expect(self: *Parser, tag: TokenTag) !void {
        if (self.current().tag != tag) {
            return switch (tag) {
                .identifier => error.ExpectedIdentifier,
                .integer => error.ExpectedInteger,
                .string => error.ExpectedString,
                .colon => error.ExpectedColon,
                .open_paren => error.ExpectedOpenParen,
                .close_paren => error.ExpectedCloseParen,
                .eof => error.ExpectedEndOfExpression,
            };
        }
        _ = self.advance();
    }

    fn peek(self: *const Parser, offset: usize) Token {
        const target = self.index + offset;
        if (target >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[target];
    }
};

fn evaluateSource(ctx: *EvalContext, source: Source) anyerror!Value {
    return switch (source) {
        .base => |name| .{ .string = try resolveBase(ctx, name) },
        .env => |name| .{ .string = try resolveEnv(ctx, name) },
        .args_all => .{ .list = try ctx.allocator.dupe([]const u8, ctx.args) },
        .args_index => |index| try resolveArgIndex(ctx, ctx.args, index),
    };
}

fn resolveBase(ctx: *EvalContext, name: []const u8) ![]const u8 {
    const metadata = ctx.metadata;
    if (std.mem.eql(u8, name, "exe_path")) return metadata.exe_path;
    if (std.mem.eql(u8, name, "exe_dir")) return metadata.exe_dir;
    if (std.mem.eql(u8, name, "exe_filename")) return metadata.exe_filename;
    if (std.mem.eql(u8, name, "exe_filename_noext")) return metadata.exe_filename_noext;
    if (std.mem.eql(u8, name, "exe_ext")) return metadata.exe_ext;
    if (std.mem.eql(u8, name, "exe_ext_dot")) return metadata.exe_ext_dot;
    if (std.mem.eql(u8, name, "exe_drive")) return metadata.exe_drive;
    if (std.mem.eql(u8, name, "exe_root")) return metadata.exe_root;
    if (std.mem.eql(u8, name, "exe_parent")) return metadata.exe_parent;
    if (std.mem.eql(u8, name, "args0")) return metadata.args0;
    if (std.mem.eql(u8, name, "cwd")) return metadata.cwd;
    if (std.mem.eql(u8, name, "temp_dir")) return metadata.temp_dir;
    if (std.mem.eql(u8, name, "home_dir")) return metadata.home_dir;
    if (std.mem.eql(u8, name, "appdata_dir")) return metadata.appdata_dir;
    if (std.mem.eql(u8, name, "localappdata_dir")) return metadata.localappdata_dir;
    if (std.mem.eql(u8, name, "programdata_dir")) return metadata.programdata_dir;
    if (std.mem.eql(u8, name, "program_files_dir")) return metadata.program_files_dir;
    if (std.mem.eql(u8, name, "program_files_x86_dir")) return metadata.program_files_x86_dir;
    if (std.mem.eql(u8, name, "documents_dir")) return metadata.documents_dir;
    if (std.mem.eql(u8, name, "downloads_dir")) return metadata.downloads_dir;
    if (std.mem.eql(u8, name, "desktop_dir")) return metadata.desktop_dir;
    if (std.mem.eql(u8, name, "os")) return metadata.os;
    if (std.mem.eql(u8, name, "arch")) return metadata.arch;
    if (std.mem.eql(u8, name, "dir_sep")) return metadata.dir_sep;
    if (std.mem.eql(u8, name, "path_sep")) return metadata.path_sep;
    return error.UnknownBase;
}

fn resolveEnv(ctx: *EvalContext, name: []const u8) ![]const u8 {
    return ctx.env.get(name) orelse {
        if (ctx.strictness.error_on_missing_env) return error.MissingEnvironmentVariable;
        return "";
    };
}

fn resolveArgIndex(ctx: *EvalContext, args: []const []const u8, index: usize) !Value {
    if (index == 0 or index > args.len) {
        if (ctx.strictness.error_on_arg_out_of_bounds) return error.ArgumentOutOfBounds;
        return .{ .string = "" };
    }
    return .{ .string = args[index - 1] };
}

fn applyTransform(ctx: *EvalContext, value: Value, transform: Transform) anyerror!Value {
    return switch (transform) {
        .index => |index| switch (value) {
            .list => |items| try resolveArgIndex(ctx, items, index),
            else => error.WrongTransformType,
        },
        .named => |named| try applyNamedTransform(ctx, value, named),
    };
}

fn applyNamedTransform(ctx: *EvalContext, value: Value, transform: NamedTransform) anyerror!Value {
    const name = transform.name;

    if (isNoArgStringTransform(name) or isNoArgPathTransform(name)) {
        try expectNoArgument(transform.argument);
        const input = try expectString(value);
        return .{ .string = try applyStringLikeNoArg(ctx, input, name) };
    }

    if (std.mem.eql(u8, name, "join")) {
        const input = try expectString(value);
        const part = try argumentString(ctx, transform.argument orelse return error.MissingTransformArgument);
        return .{ .string = try joinPath(ctx, input, part) };
    }

    if (std.mem.eql(u8, name, "prefix")) {
        const input = try expectString(value);
        const prefix = try argumentString(ctx, transform.argument orelse return error.MissingTransformArgument);
        return .{ .string = try concat2(ctx, prefix, input) };
    }

    if (std.mem.eql(u8, name, "suffix")) {
        const input = try expectString(value);
        const suffix = try argumentString(ctx, transform.argument orelse return error.MissingTransformArgument);
        return .{ .string = try concat2(ctx, input, suffix) };
    }

    if (std.mem.eql(u8, name, "prepend_env")) {
        const input = try expectString(value);
        const entry = try argumentString(ctx, transform.argument orelse return error.MissingTransformArgument);
        return .{ .string = try prependEnv(ctx, input, entry) };
    }

    if (std.mem.eql(u8, name, "append_env")) {
        const input = try expectString(value);
        const entry = try argumentString(ctx, transform.argument orelse return error.MissingTransformArgument);
        return .{ .string = try appendEnv(ctx, input, entry) };
    }

    if (std.mem.eql(u8, name, "remove_env")) {
        const input = try expectString(value);
        const entry = try argumentString(ctx, transform.argument orelse return error.MissingTransformArgument);
        return .{ .string = try removeEnv(ctx, input, entry) };
    }

    if (std.mem.eql(u8, name, "unique_env")) {
        try expectNoArgument(transform.argument);
        const input = try expectString(value);
        return .{ .string = try uniqueEnv(ctx, input) };
    }

    if (isListTransform(name)) {
        const items = try expectList(value);
        return try applyListTransform(ctx, items, name, transform.argument);
    }

    return error.UnknownTransform;
}

fn applyStringLikeNoArg(ctx: *EvalContext, input: []const u8, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "parent")) return pathParent(input);
    if (std.mem.eql(u8, name, "filename")) return pathFilename(input);
    if (std.mem.eql(u8, name, "filename_noext")) return pathFilenameNoExt(input);
    if (std.mem.eql(u8, name, "ext")) return pathExt(input, false);
    if (std.mem.eql(u8, name, "ext_dot")) return pathExt(input, true);
    if (std.mem.eql(u8, name, "drive")) return pathDrive(input);
    if (std.mem.eql(u8, name, "root")) return pathRoot(input);
    if (std.mem.eql(u8, name, "normalize")) return normalizePath(ctx, input);
    if (std.mem.eql(u8, name, "slash")) return replaceByte(ctx, input, '\\', '/');
    if (std.mem.eql(u8, name, "backslash")) return replaceByte(ctx, input, '/', '\\');
    if (std.mem.eql(u8, name, "lower")) return asciiLower(ctx, input);
    if (std.mem.eql(u8, name, "upper")) return asciiUpper(ctx, input);
    if (std.mem.eql(u8, name, "trim")) return std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.eql(u8, name, "json")) return jsonEscape(ctx, input);
    return error.UnknownTransform;
}

fn applyListTransform(
    ctx: *EvalContext,
    items: []const []const u8,
    name: []const u8,
    argument: ?Argument,
) anyerror!Value {
    if (std.mem.eql(u8, name, "last") and argument == null) {
        return try resolveArgIndex(ctx, items, items.len);
    }

    const count = if (argument) |arg|
        try argumentInteger(ctx, arg)
    else
        return error.MissingTransformArgument;

    if (std.mem.eql(u8, name, "from")) {
        if (count <= 1) return .{ .list = try ctx.allocator.dupe([]const u8, items) };
        if (count > items.len) return .{ .list = &.{} };
        return .{ .list = try ctx.allocator.dupe([]const u8, items[count - 1 ..]) };
    }

    if (std.mem.eql(u8, name, "take")) {
        const end = @min(count, items.len);
        return .{ .list = try ctx.allocator.dupe([]const u8, items[0..end]) };
    }

    if (std.mem.eql(u8, name, "drop")) {
        const start = @min(count, items.len);
        return .{ .list = try ctx.allocator.dupe([]const u8, items[start..]) };
    }

    if (std.mem.eql(u8, name, "last")) {
        const start = items.len - @min(count, items.len);
        return .{ .list = try ctx.allocator.dupe([]const u8, items[start..]) };
    }

    if (std.mem.eql(u8, name, "drop_last")) {
        const end = items.len - @min(count, items.len);
        return .{ .list = try ctx.allocator.dupe([]const u8, items[0..end]) };
    }

    return error.UnknownTransform;
}

fn expectString(value: Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.WrongTransformType,
    };
}

fn expectList(value: Value) ![]const []const u8 {
    return switch (value) {
        .list => |items| items,
        else => error.WrongTransformType,
    };
}

fn expectNoArgument(argument: ?Argument) !void {
    if (argument != null) return error.UnexpectedTransformArgument;
}

fn argumentString(ctx: *EvalContext, argument: Argument) anyerror![]const u8 {
    return switch (argument) {
        .string => |s| s,
        .integer => error.WrongTransformType,
        .expression => |expression| expectString(try expression.evaluate(ctx)),
    };
}

fn argumentInteger(ctx: *EvalContext, argument: Argument) anyerror!usize {
    return switch (argument) {
        .integer => |i| i,
        .string => error.WrongTransformType,
        .expression => |expression| switch (try expression.evaluate(ctx)) {
            .integer => |i| i,
            else => error.WrongTransformType,
        },
    };
}

fn isNoArgPathTransform(name: []const u8) bool {
    const names = [_][]const u8{
        "parent",
        "filename",
        "filename_noext",
        "ext",
        "ext_dot",
        "drive",
        "root",
        "normalize",
        "slash",
        "backslash",
    };
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn isNoArgStringTransform(name: []const u8) bool {
    const names = [_][]const u8{
        "lower",
        "upper",
        "trim",
        "json",
    };
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn isListTransform(name: []const u8) bool {
    const names = [_][]const u8{
        "from",
        "take",
        "drop",
        "last",
        "drop_last",
    };
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn concat2(ctx: *EvalContext, a: []const u8, b: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(ctx.allocator, a);
    try out.appendSlice(ctx.allocator, b);
    return try out.toOwnedSlice(ctx.allocator);
}

fn asciiLower(ctx: *EvalContext, input: []const u8) ![]const u8 {
    const out = try ctx.allocator.dupe(u8, input);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

fn asciiUpper(ctx: *EvalContext, input: []const u8) ![]const u8 {
    const out = try ctx.allocator.dupe(u8, input);
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return out;
}

fn replaceByte(ctx: *EvalContext, input: []const u8, from: u8, to: u8) ![]const u8 {
    const out = try ctx.allocator.dupe(u8, input);
    std.mem.replaceScalar(u8, out, from, to);
    return out;
}

fn jsonEscape(ctx: *EvalContext, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (input) |c| {
        if (c == '"') {
            try out.appendSlice(ctx.allocator, "\\\"");
        } else if (c == '\\') {
            try out.appendSlice(ctx.allocator, "\\\\");
        } else if (c == '\n') {
            try out.appendSlice(ctx.allocator, "\\n");
        } else if (c == '\r') {
            try out.appendSlice(ctx.allocator, "\\r");
        } else if (c == '\t') {
            try out.appendSlice(ctx.allocator, "\\t");
        } else if (c == 0x08) {
            try out.appendSlice(ctx.allocator, "\\b");
        } else if (c == 0x0c) {
            try out.appendSlice(ctx.allocator, "\\f");
        } else if (c < 0x20) {
            try out.writer(ctx.allocator).print("\\u{x:0>4}", .{c});
        } else {
            try out.append(ctx.allocator, c);
        }
    }
    return try out.toOwnedSlice(ctx.allocator);
}

fn pathParent(input: []const u8) []const u8 {
    const trimmed = trimTrailingPathSeparators(input);
    const root_len = pathRootLength(trimmed);
    if (trimmed.len <= root_len) return trimmed;

    var i = trimmed.len;
    while (i > root_len) {
        i -= 1;
        if (isPathSeparator(trimmed[i])) {
            if (i < root_len) return trimmed[0..root_len];
            return trimmed[0..i];
        }
    }
    return ".";
}

fn pathFilename(input: []const u8) []const u8 {
    const trimmed = trimTrailingPathSeparators(input);
    const root_len = pathRootLength(trimmed);
    if (trimmed.len <= root_len) return "";

    var i = trimmed.len;
    while (i > root_len) {
        i -= 1;
        if (isPathSeparator(trimmed[i])) return trimmed[i + 1 ..];
    }
    return trimmed;
}

fn pathFilenameNoExt(input: []const u8) []const u8 {
    const filename = pathFilename(input);
    const dot = lastExtensionDot(filename) orelse return filename;
    return filename[0..dot];
}

fn pathExt(input: []const u8, with_dot: bool) []const u8 {
    const filename = pathFilename(input);
    const dot = lastExtensionDot(filename) orelse return "";
    return if (with_dot) filename[dot..] else filename[dot + 1 ..];
}

fn pathDrive(input: []const u8) []const u8 {
    if (input.len >= 2 and isAsciiAlpha(input[0]) and input[1] == ':') return input[0..2];
    if (input.len >= 2 and isPathSeparator(input[0]) and isPathSeparator(input[1])) {
        const share_end = uncShareEnd(input) orelse return input[0..0];
        return trimTrailingPathSeparators(input[0..share_end]);
    }
    return "";
}

fn pathRoot(input: []const u8) []const u8 {
    return input[0..pathRootLength(input)];
}

fn pathRootLength(input: []const u8) usize {
    if (input.len >= 2 and isPathSeparator(input[0]) and isPathSeparator(input[1])) {
        return uncShareEnd(input) orelse 2;
    }
    if (input.len >= 3 and isAsciiAlpha(input[0]) and input[1] == ':' and isPathSeparator(input[2])) return 3;
    if (input.len >= 2 and isAsciiAlpha(input[0]) and input[1] == ':') return 2;
    if (input.len >= 1 and isPathSeparator(input[0])) return 1;
    return 0;
}

fn uncShareEnd(input: []const u8) ?usize {
    var parts_seen: usize = 0;
    var i: usize = 2;
    while (i < input.len) {
        while (i < input.len and isPathSeparator(input[i])) i += 1;
        if (i >= input.len) break;
        parts_seen += 1;
        while (i < input.len and !isPathSeparator(input[i])) i += 1;
        if (parts_seen == 2) {
            if (i < input.len and isPathSeparator(input[i])) return i + 1;
            return i;
        }
    }
    return null;
}

fn trimTrailingPathSeparators(input: []const u8) []const u8 {
    var end = input.len;
    while (end > pathRootLength(input[0..end]) and isPathSeparator(input[end - 1])) {
        end -= 1;
    }
    return input[0..end];
}

fn lastExtensionDot(filename: []const u8) ?usize {
    var i = filename.len;
    while (i > 0) {
        i -= 1;
        if (filename[i] == '.') {
            if (i == 0) return null;
            return i;
        }
    }
    return null;
}

fn joinPath(ctx: *EvalContext, base: []const u8, part: []const u8) ![]const u8 {
    if (base.len == 0) return try ctx.allocator.dupe(u8, trimLeadingPathSeparators(part));

    const trimmed_base = trimTrailingPathSeparators(base);
    const trimmed_part = trimLeadingPathSeparators(part);
    if (trimmed_part.len == 0) return try ctx.allocator.dupe(u8, trimmed_base);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(ctx.allocator, trimmed_base);
    if (trimmed_base.len == 0 or !isPathSeparator(trimmed_base[trimmed_base.len - 1])) {
        try out.append(ctx.allocator, preferredDirSep(ctx, trimmed_base));
    }
    try out.appendSlice(ctx.allocator, trimmed_part);
    return try out.toOwnedSlice(ctx.allocator);
}

fn trimLeadingPathSeparators(input: []const u8) []const u8 {
    var start: usize = 0;
    while (start < input.len and isPathSeparator(input[start])) start += 1;
    return input[start..];
}

fn preferredDirSep(ctx: *EvalContext, path: []const u8) u8 {
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return '\\';
    if (std.mem.indexOfScalar(u8, path, '/') != null) return '/';
    if (ctx.metadata.dir_sep.len > 0) return ctx.metadata.dir_sep[0];
    return '\\';
}

fn normalizePath(ctx: *EvalContext, input: []const u8) ![]const u8 {
    if (input.len == 0) return "";

    const sep = if (ctx.metadata.dir_sep.len > 0) ctx.metadata.dir_sep[0] else '\\';
    const root_len = pathRootLength(input);
    var parts: std.ArrayList([]const u8) = .empty;

    var i = root_len;
    while (i < input.len) {
        while (i < input.len and isPathSeparator(input[i])) i += 1;
        const start = i;
        while (i < input.len and !isPathSeparator(input[i])) i += 1;
        const part = input[start..i];
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                parts.items.len -= 1;
            } else if (root_len == 0) {
                try parts.append(ctx.allocator, part);
            }
            continue;
        }
        try parts.append(ctx.allocator, part);
    }

    var out: std.ArrayList(u8) = .empty;
    if (root_len > 0) {
        try out.appendSlice(ctx.allocator, try replaceSeparators(ctx, input[0..root_len], sep));
    }

    for (parts.items, 0..) |part, index| {
        if (out.items.len > 0 and !isPathSeparator(out.items[out.items.len - 1])) {
            try out.append(ctx.allocator, sep);
        } else if (out.items.len == 0 and index > 0) {
            try out.append(ctx.allocator, sep);
        }
        try out.appendSlice(ctx.allocator, part);
    }

    if (out.items.len == 0 and root_len == 0) return ".";
    return try out.toOwnedSlice(ctx.allocator);
}

fn replaceSeparators(ctx: *EvalContext, input: []const u8, sep: u8) ![]const u8 {
    const out = try ctx.allocator.dupe(u8, input);
    for (out) |*c| {
        if (isPathSeparator(c.*)) c.* = sep;
    }
    return out;
}

fn prependEnv(ctx: *EvalContext, current: []const u8, entry: []const u8) ![]const u8 {
    if (entry.len == 0) return try ctx.allocator.dupe(u8, current);
    if (current.len == 0) return try ctx.allocator.dupe(u8, entry);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(ctx.allocator, entry);
    try out.appendSlice(ctx.allocator, ctx.metadata.path_sep);
    try out.appendSlice(ctx.allocator, current);
    return try out.toOwnedSlice(ctx.allocator);
}

fn appendEnv(ctx: *EvalContext, current: []const u8, entry: []const u8) ![]const u8 {
    if (entry.len == 0) return try ctx.allocator.dupe(u8, current);
    if (current.len == 0) return try ctx.allocator.dupe(u8, entry);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(ctx.allocator, current);
    try out.appendSlice(ctx.allocator, ctx.metadata.path_sep);
    try out.appendSlice(ctx.allocator, entry);
    return try out.toOwnedSlice(ctx.allocator);
}

fn removeEnv(ctx: *EvalContext, current: []const u8, entry: []const u8) ![]const u8 {
    const parts = try splitEnvList(ctx, current);
    var kept: std.ArrayList([]const u8) = .empty;
    for (parts.items) |part| {
        if (!std.mem.eql(u8, part, entry)) try kept.append(ctx.allocator, part);
    }
    return try joinEnvList(ctx, kept.items);
}

fn uniqueEnv(ctx: *EvalContext, current: []const u8) ![]const u8 {
    const parts = try splitEnvList(ctx, current);
    var seen = std.StringHashMap(void).init(ctx.allocator);
    var kept: std.ArrayList([]const u8) = .empty;
    for (parts.items) |part| {
        if (seen.contains(part)) continue;
        try seen.put(part, {});
        try kept.append(ctx.allocator, part);
    }
    return try joinEnvList(ctx, kept.items);
}

fn splitEnvList(ctx: *EvalContext, current: []const u8) !std.ArrayList([]const u8) {
    var parts: std.ArrayList([]const u8) = .empty;
    if (current.len == 0) return parts;

    var it = std.mem.splitSequence(u8, current, ctx.metadata.path_sep);
    while (it.next()) |part| {
        try parts.append(ctx.allocator, part);
    }
    return parts;
}

fn joinEnvList(ctx: *EvalContext, entries: []const []const u8) ![]const u8 {
    if (entries.len == 0) return "";
    var out: std.ArrayList(u8) = .empty;
    for (entries, 0..) |entry, index| {
        if (index > 0) try out.appendSlice(ctx.allocator, ctx.metadata.path_sep);
        try out.appendSlice(ctx.allocator, entry);
    }
    return try out.toOwnedSlice(ctx.allocator);
}

fn isIdentStart(c: u8) bool {
    return isAsciiAlpha(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAsciiAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isPathSeparator(c: u8) bool {
    return c == '\\' or c == '/';
}

const test_metadata = Metadata{
    .exe_path = "C:\\Bundle\\bin\\tool.exe",
    .exe_dir = "C:\\Bundle\\bin",
    .exe_filename = "tool.exe",
    .exe_filename_noext = "tool",
    .exe_ext = "exe",
    .exe_ext_dot = ".exe",
    .exe_drive = "C:",
    .exe_root = "C:\\",
    .exe_parent = "C:\\Bundle",
    .args0 = ".\\tool.exe",
    .cwd = "C:\\Users\\Simon",
    .temp_dir = "C:\\Users\\Simon\\AppData\\Local\\Temp",
    .home_dir = "C:\\Users\\Simon",
    .appdata_dir = "C:\\Users\\Simon\\AppData\\Roaming",
    .localappdata_dir = "C:\\Users\\Simon\\AppData\\Local",
    .programdata_dir = "C:\\ProgramData",
    .program_files_dir = "C:\\Program Files",
    .program_files_x86_dir = "C:\\Program Files (x86)",
    .documents_dir = "C:\\Users\\Simon\\Documents",
    .downloads_dir = "C:\\Users\\Simon\\Downloads",
    .desktop_dir = "C:\\Users\\Simon\\Desktop",
    .os = "windows",
    .arch = "x86_64",
    .dir_sep = "\\",
    .path_sep = ";",
};

fn testContext(
    allocator: std.mem.Allocator,
    env: *std.process.EnvMap,
    args: []const []const u8,
) EvalContext {
    return .{
        .allocator = allocator,
        .metadata = test_metadata,
        .env = env,
        .args = args,
    };
}

fn expectStringValue(expected: []const u8, value: Value) !void {
    try std.testing.expectEqualStrings(expected, switch (value) {
        .string => |s| s,
        else => return error.ExpectedStringValue,
    });
}

fn expectListValue(expected: []const []const u8, value: Value) !void {
    const actual = switch (value) {
        .list => |items| items,
        else => return error.ExpectedListValue,
    };
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_item, actual_item| {
        try std.testing.expectEqualStrings(expected_item, actual_item);
    }
}

test "tokenizer handles identifiers strings integers and punctuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tokens = try tokenize(allocator, "env:\"PA\\\"TH\":prepend_env(exe_dir:parent:join(\"python\")):1");

    try std.testing.expectEqual(TokenTag.identifier, tokens[0].tag);
    try std.testing.expectEqualStrings("env", tokens[0].lexeme);
    try std.testing.expectEqual(TokenTag.colon, tokens[1].tag);
    try std.testing.expectEqual(TokenTag.string, tokens[2].tag);
    try std.testing.expectEqualStrings("PA\"TH", tokens[2].string);
    try std.testing.expectEqual(TokenTag.identifier, tokens[4].tag);
    try std.testing.expectEqualStrings("prepend_env", tokens[4].lexeme);
    try std.testing.expectEqual(TokenTag.open_paren, tokens[5].tag);
    try std.testing.expectEqual(TokenTag.integer, tokens[tokens.len - 2].tag);
    try std.testing.expectEqual(@as(usize, 1), tokens[tokens.len - 2].integer);
    try std.testing.expectEqual(TokenTag.eof, tokens[tokens.len - 1].tag);
}

test "parser builds env lookup with nested transform argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const expression = try parse(allocator, "env:\"PATH\":prepend_env(exe_dir:parent:join(\"python\"))");

    try std.testing.expectEqual(Source.env, std.meta.activeTag(expression.source));
    try std.testing.expectEqual(@as(usize, 1), expression.transforms.len);
    const named = expression.transforms[0].named;
    try std.testing.expectEqualStrings("prepend_env", named.name);
    try std.testing.expect(named.argument != null);
}

test "evaluates base values and path transforms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    const args = [_][]const u8{};
    var ctx = testContext(allocator, &env, args[0..]);

    try expectStringValue("C:\\Bundle\\python\\python.exe", try evaluate("exe_dir:parent:join(\"python\"):join(\"python.exe\")", &ctx));
    try expectStringValue("tool.exe", try evaluate("exe_path:filename", &ctx));
    try expectStringValue("tool", try evaluate("exe_path:filename_noext", &ctx));
    try expectStringValue("exe", try evaluate("exe_path:ext", &ctx));
    try expectStringValue(".exe", try evaluate("exe_path:ext_dot", &ctx));
    try expectStringValue("C:", try evaluate("exe_path:drive", &ctx));
    try expectStringValue("C:\\", try evaluate("exe_path:root", &ctx));
    try expectStringValue("C:/Bundle/bin/tool.exe", try evaluate("exe_path:slash", &ctx));
    try expectStringValue("C:\\Bundle\\app", try evaluate("exe_dir:join(\"..\\\\app\"):normalize", &ctx));
}

test "evaluates string transforms and JSON escaping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    try env.put("NAME", "  Mixed \"Case\"  ");
    const args = [_][]const u8{};
    var ctx = testContext(allocator, &env, args[0..]);

    try expectStringValue("pre-mixed \"case\"-post", try evaluate("env:\"NAME\":trim:lower:prefix(\"pre-\"):suffix(\"-post\")", &ctx));
    try expectStringValue("Line\\n\\\"quoted\\\"", try evaluate("env:\"TEXT\":prefix(\"Line\\n\\\"quoted\\\"\"):json", &ctx));
}

test "environment lookups default empty and can be strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    const args = [_][]const u8{};
    var ctx = testContext(allocator, &env, args[0..]);

    try expectStringValue("", try evaluate("env:\"MISSING\"", &ctx));
    ctx.strictness.error_on_missing_env = true;
    try std.testing.expectError(error.MissingEnvironmentVariable, evaluate("env:\"MISSING\"", &ctx));
}

test "argument lookup and slicing are one based and forgiving" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    const args = [_][]const u8{ "alpha", "C:\\Input\\demo.txt", "gamma", "delta" };
    var ctx = testContext(allocator, &env, args[0..]);

    try expectStringValue("alpha", try evaluate("args:1", &ctx));
    try expectStringValue("demo.txt", try evaluate("args:2:filename", &ctx));
    try expectListValue(&.{ "C:\\Input\\demo.txt", "gamma", "delta" }, try evaluate("args:from(2)", &ctx));
    try expectListValue(&.{ "alpha", "C:\\Input\\demo.txt" }, try evaluate("args:take(2)", &ctx));
    try expectListValue(&.{ "gamma", "delta" }, try evaluate("args:drop(2)", &ctx));
    try expectStringValue("delta", try evaluate("args:last", &ctx));
    try expectListValue(&.{ "gamma", "delta" }, try evaluate("args:last(2)", &ctx));
    try expectStringValue("gamma", try evaluate("args:last(2):1", &ctx));
    try expectListValue(&.{ "alpha", "C:\\Input\\demo.txt", "gamma" }, try evaluate("args:drop_last(1)", &ctx));
    try expectListValue(&.{}, try evaluate("args:from(999999)", &ctx));
    try expectStringValue("", try evaluate("args:10", &ctx));
    ctx.strictness.error_on_arg_out_of_bounds = true;
    try std.testing.expectError(error.ArgumentOutOfBounds, evaluate("args:10", &ctx));
}

test "environment list transforms preserve order and avoid empty-list separators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    try env.put("PATH", "C:\\A;;C:\\B;C:\\A");
    try env.put("EMPTY", "");
    const args = [_][]const u8{};
    var ctx = testContext(allocator, &env, args[0..]);

    try expectStringValue("C:\\Bundle\\Python;C:\\A;;C:\\B;C:\\A", try evaluate("env:\"PATH\":prepend_env(exe_parent:join(\"Python\"))", &ctx));
    try expectStringValue("C:\\A;;C:\\B;C:\\A;C:\\Tools", try evaluate("env:\"PATH\":append_env(\"C:\\\\Tools\")", &ctx));
    try expectStringValue("C:\\A;;C:\\A", try evaluate("env:\"PATH\":remove_env(\"C:\\\\B\")", &ctx));
    try expectStringValue("C:\\A;;C:\\B", try evaluate("env:\"PATH\":unique_env", &ctx));
    try expectStringValue("C:\\Only", try evaluate("env:\"EMPTY\":prepend_env(\"C:\\\\Only\")", &ctx));
    try expectStringValue("", try evaluate("env:\"EMPTY\":append_env(\"\")", &ctx));
}

test "invalid syntax unknown names and wrong types fail explicitly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    const args = [_][]const u8{"alpha"};
    var ctx = testContext(allocator, &env, args[0..]);

    try std.testing.expectError(error.ExpectedString, evaluate("env:PATH", &ctx));
    try std.testing.expectError(error.ExpectedCloseParen, evaluate("exe_dir:join(\"python\"", &ctx));
    try std.testing.expectError(error.UnknownBase, evaluate("missing_base", &ctx));
    try std.testing.expectError(error.UnknownTransform, evaluate("exe_dir:no_such_transform", &ctx));
    try std.testing.expectError(error.WrongTransformType, evaluate("args:parent", &ctx));
    try std.testing.expectError(error.WrongTransformType, evaluate("exe_dir:from(2)", &ctx));
    try std.testing.expectError(error.WrongTransformType, evaluate("exe_dir:join(args)", &ctx));
    try std.testing.expectError(error.UnexpectedTransformArgument, evaluate("exe_dir:parent(\"ignored\")", &ctx));
    try std.testing.expectError(error.MissingTransformArgument, evaluate("exe_dir:join", &ctx));
}
