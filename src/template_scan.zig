const std = @import("std");

pub const SourceRange = struct {
    start: usize,
    end: usize,
};

pub const sentinel_key_len: usize = 39;
pub const spaced_sentinel_len: usize = sentinel_key_len + 2;

pub const Sentinel = struct {
    key: []const u8,
    expression: []const u8,
    source_range: SourceRange,
};

pub const ScanResult = struct {
    json: []const u8,
    sentinels: []const Sentinel,

    pub fn deinit(self: ScanResult, allocator: std.mem.Allocator) void {
        allocator.free(self.json);
        for (self.sentinels) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.expression);
        }
        allocator.free(self.sentinels);
    }
};

pub const SentinelSource = struct {
    context: *anyopaque,
    nextFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8,

    pub fn next(self: SentinelSource, allocator: std.mem.Allocator) ![]const u8 {
        return self.nextFn(self.context, allocator);
    }
};

var random_source_context: u8 = 0;

pub fn randomSentinelSource() SentinelSource {
    return .{
        .context = &random_source_context,
        .nextFn = randomNumericSentinel,
    };
}

pub fn scanWithRandomSentinels(allocator: std.mem.Allocator, input: []const u8) !ScanResult {
    return scan(allocator, input, randomSentinelSource());
}

pub fn scan(allocator: std.mem.Allocator, input: []const u8, sentinel_source: SentinelSource) !ScanResult {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var sentinels: std.ArrayList(Sentinel) = .empty;
    errdefer sentinels.deinit(allocator);
    errdefer freeSentinels(allocator, sentinels.items);

    var i: usize = 0;
    while (i < input.len) {
        if (startsWith(input[i..], "@@{")) {
            try out.appendSlice(allocator, "@{");
            i += 3;
            continue;
        }

        if (startsWith(input[i..], "@{")) {
            const parsed = try parseTemplate(input, i);
            const sentinel_index = try appendSentinel(
                allocator,
                input,
                &sentinels,
                sentinel_source,
                parsed,
            );
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, sentinels.items[sentinel_index].key);
            try out.append(allocator, ' ');
            i = parsed.template_end;
            continue;
        }

        try out.append(allocator, input[i]);
        i += 1;
    }

    const json = try out.toOwnedSlice(allocator);
    errdefer allocator.free(json);
    const sentinel_slice = try sentinels.toOwnedSlice(allocator);

    return .{
        .json = json,
        .sentinels = sentinel_slice,
    };
}

const ParsedTemplate = struct {
    expression_start: usize,
    expression_end: usize,
    template_start: usize,
    template_end: usize,
};

fn parseTemplate(input: []const u8, start: usize) !ParsedTemplate {
    std.debug.assert(startsWith(input[start..], "@{"));

    const expression_start = start + 2;
    var i = expression_start;
    var in_template_string = false;
    var paren_depth: usize = 0;

    while (i < input.len) {
        const byte = input[i];
        if (in_template_string) {
            if (byte == '\\') {
                i = try skipTemplateStringEscape(input, i);
                continue;
            }
            if (byte == '"') {
                in_template_string = false;
            }
            i += 1;
            continue;
        }

        switch (byte) {
            '"' => {
                in_template_string = true;
                i += 1;
            },
            '(' => {
                paren_depth += 1;
                i += 1;
            },
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
                i += 1;
            },
            '}' => {
                if (paren_depth == 0) {
                    if (i == expression_start) return error.EmptyTemplateExpression;
                    return .{
                        .expression_start = expression_start,
                        .expression_end = i,
                        .template_start = start,
                        .template_end = i + 1,
                    };
                }
                i += 1;
            },
            else => i += 1,
        }
    }

    if (in_template_string) return error.UnclosedTemplateString;
    if (paren_depth > 0) return error.UnclosedTemplateParenthesis;
    return error.UnclosedTemplateExpression;
}

fn appendSentinel(
    allocator: std.mem.Allocator,
    input: []const u8,
    sentinels: *std.ArrayList(Sentinel),
    sentinel_source: SentinelSource,
    parsed: ParsedTemplate,
) !usize {
    const key = try nextSentinelKey(allocator, sentinel_source);
    errdefer allocator.free(key);

    const expression = try allocator.dupe(u8, input[parsed.expression_start..parsed.expression_end]);
    errdefer allocator.free(expression);

    try sentinels.append(allocator, .{
        .key = key,
        .expression = expression,
        .source_range = .{
            .start = parsed.template_start,
            .end = parsed.template_end,
        },
    });
    return sentinels.items.len - 1;
}

fn nextSentinelKey(
    allocator: std.mem.Allocator,
    sentinel_source: SentinelSource,
) ![]const u8 {
    const key = try sentinel_source.next(allocator);
    if (!isNumericSentinelKey(key)) {
        allocator.free(key);
        return error.InvalidSentinelKey;
    }
    return key;
}

fn skipTemplateStringEscape(input: []const u8, slash_index: usize) !usize {
    if (slash_index + 1 >= input.len) return error.UnclosedTemplateString;

    const escaped = input[slash_index + 1];
    switch (escaped) {
        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => return slash_index + 2,
        'u' => {
            if (slash_index + 6 > input.len) return error.InvalidTemplateStringEscape;
            for (input[slash_index + 2 .. slash_index + 6]) |byte| {
                if (!std.ascii.isHex(byte)) return error.InvalidTemplateStringEscape;
            }
            return slash_index + 6;
        },
        else => return error.InvalidTemplateStringEscape,
    }
}

fn randomNumericSentinel(context: *anyopaque, allocator: std.mem.Allocator) ![]const u8 {
    _ = context;

    const out = try allocator.alloc(u8, sentinel_key_len);
    out[0] = '1';
    for (out[1..]) |*byte| {
        byte.* = '0' + std.crypto.random.intRangeLessThan(u8, 0, 10);
    }
    return out;
}

pub fn isNumericSentinelKey(value: []const u8) bool {
    if (value.len != sentinel_key_len) return false;
    if (value[0] != '1') return false;
    for (value, 0..) |byte, index| {
        if (index == 0) continue;
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn startsWith(haystack: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, haystack, needle);
}

fn freeSentinels(allocator: std.mem.Allocator, sentinels: []const Sentinel) void {
    for (sentinels) |entry| {
        allocator.free(entry.key);
        allocator.free(entry.expression);
    }
}

const DeterministicSentinels = struct {
    values: []const []const u8,
    index: usize = 0,

    fn source(self: *@This()) SentinelSource {
        return .{
            .context = self,
            .nextFn = next,
        };
    }

    fn next(context: *anyopaque, allocator: std.mem.Allocator) ![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.index >= self.values.len) return error.TestSentinelExhausted;
        defer self.index += 1;
        return allocator.dupe(u8, self.values[self.index]);
    }
};

const test_key_1 = "100000000000000000000000000000000000001";
const test_key_2 = "100000000000000000000000000000000000002";
const test_key_3 = "100000000000000000000000000000000000003";

fn testSource(values: []const []const u8) DeterministicSentinels {
    return .{ .values = values };
}

test "literal escape emits at brace without a sentinel" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_key_1});

    const result = try scan(allocator, "{\"command\":[\"@@{exe_dir}\", @@{literal}]}", source.source());
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("{\"command\":[\"@{exe_dir}\", @{literal}]}", result.json);
    try std.testing.expectEqual(@as(usize, 0), result.sentinels.len);
}

test "raw template expression becomes a spaced numeric sentinel value" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_key_1});
    const input = "{\"command\":[@{args}]}";

    const result = try scan(allocator, input, source.source());
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("{\"command\":[ " ++ test_key_1 ++ " ]}", result.json);
    try std.testing.expectEqual(@as(usize, 1), result.sentinels.len);
    try std.testing.expectEqualStrings(test_key_1, result.sentinels[0].key);
    try std.testing.expectEqualStrings("args", result.sentinels[0].expression);
    try std.testing.expectEqual(@as(usize, 12), result.sentinels[0].source_range.start);
    try std.testing.expectEqual(@as(usize, 19), result.sentinels[0].source_range.end);
}

test "single template inside a JSON string becomes spaced sentinel text" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_key_1});

    const result = try scan(allocator, "{\"cwd\":\"@{exe_dir}\"}", source.source());
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("{\"cwd\":\" " ++ test_key_1 ++ " \"}", result.json);
    try std.testing.expectEqual(@as(usize, 1), result.sentinels.len);
    try std.testing.expectEqualStrings("exe_dir", result.sentinels[0].expression);
}

test "template mixed with literal JSON string text gets wrapper spaces" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_key_1});

    const result = try scan(allocator, "{\"path\":\"prefix @{exe_name} suffix\"}", source.source());
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("{\"path\":\"prefix  " ++ test_key_1 ++ "  suffix\"}", result.json);
    try std.testing.expectEqual(@as(usize, 1), result.sentinels.len);
}

test "multiple templates in one JSON string each get wrapper spaces" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{ test_key_1, test_key_2 });

    const result = try scan(allocator, "\"@{exe_dir}@{exe_name}\"", source.source());
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("\" " ++ test_key_1 ++ "  " ++ test_key_2 ++ " \"", result.json);
    try std.testing.expectEqual(@as(usize, 2), result.sentinels.len);
}

test "quoted braces and nested parentheses inside templates do not end the expression" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_key_1});

    const input = "\"@{env:\"PATH}\":prepend_env(exe_dir:parent:join(\"python}\"))}\"";
    const result = try scan(allocator, input, source.source());
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("\" " ++ test_key_1 ++ " \"", result.json);
    try std.testing.expectEqualStrings(
        "env:\"PATH}\":prepend_env(exe_dir:parent:join(\"python}\"))",
        result.sentinels[0].expression,
    );
}

test "JSON escapes inside template strings are consumed as part of the expression" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_key_1});

    const result = try scan(allocator, "\"@{exe_dir:join(\"quote\\\"brace}unicode\\u007d\")}\"", source.source());
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("\" " ++ test_key_1 ++ " \"", result.json);
    try std.testing.expectEqualStrings("exe_dir:join(\"quote\\\"brace}unicode\\u007d\")", result.sentinels[0].expression);
}

test "scanner does not retry when generated key appears in user text" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{ test_key_1, test_key_2 });
    const input = "{\"literal\":\"" ++ test_key_1 ++ "\",\"values\":[@{a},@{b}]}";

    const result = try scan(allocator, input, source.source());
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("{\"literal\":\"" ++ test_key_1 ++ "\",\"values\":[ " ++ test_key_1 ++ " , " ++ test_key_2 ++ " ]}", result.json);
    try std.testing.expectEqualStrings(test_key_1, result.sentinels[0].key);
    try std.testing.expectEqualStrings(test_key_2, result.sentinels[1].key);
}

test "empty template expression is rejected" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_key_1});

    try std.testing.expectError(error.EmptyTemplateExpression, scan(allocator, "@{}", source.source()));
}

test "unclosed template expression is rejected" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_key_1});

    try std.testing.expectError(error.UnclosedTemplateExpression, scan(allocator, "@{args", source.source()));
}

test "unclosed template string is rejected" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_key_1});

    try std.testing.expectError(error.UnclosedTemplateString, scan(allocator, "@{join(\"x)}", source.source()));
}

test "unclosed template parenthesis is rejected" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_key_1});

    try std.testing.expectError(error.UnclosedTemplateParenthesis, scan(allocator, "@{join(\"x\"}", source.source()));
}

test "invalid JSON string escape inside a template is rejected" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_key_1});

    try std.testing.expectError(error.InvalidTemplateStringEscape, scan(allocator, "\"@{join(\"\\q\")}\"", source.source()));
}

test "sentinel source rejects malformed numeric keys" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{"11111111-1111-4111-8111-111111111111"});

    try std.testing.expectError(error.InvalidSentinelKey, scan(allocator, "@{args}", source.source()));
}

test "random sentinel source generates numeric sentinel keys" {
    const allocator = std.testing.allocator;
    const key = try randomSentinelSource().next(allocator);
    defer allocator.free(key);

    try std.testing.expect(isNumericSentinelKey(key));
    try std.testing.expectEqual(@as(usize, sentinel_key_len), key.len);
    try std.testing.expectEqual(@as(u8, '1'), key[0]);
}
