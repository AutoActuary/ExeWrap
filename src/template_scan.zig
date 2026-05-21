const std = @import("std");

pub const SourceRange = struct {
    start: usize,
    end: usize,
};

pub const SentinelPlacement = enum {
    raw_value,
    whole_string,
    partial_string,
};

pub const Sentinel = struct {
    uuid: []const u8,
    expression: []const u8,
    source_range: SourceRange,
    placement: SentinelPlacement,
};

pub const ScanResult = struct {
    json: []const u8,
    sentinels: []const Sentinel,

    pub fn deinit(self: ScanResult, allocator: std.mem.Allocator) void {
        allocator.free(self.json);
        for (self.sentinels) |entry| {
            allocator.free(entry.uuid);
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
        .nextFn = randomUuid,
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

    var in_json_string = false;
    var string_literal_bytes: usize = 0;
    var string_sentinel_count: usize = 0;
    var first_string_sentinel_index: usize = 0;

    var i: usize = 0;
    while (i < input.len) {
        if (in_json_string) {
            if (startsWith(input[i..], "@@{")) {
                try out.appendSlice(allocator, "@{");
                string_literal_bytes += 2;
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
                    .partial_string,
                );
                try out.appendSlice(allocator, sentinels.items[sentinel_index].uuid);
                if (string_sentinel_count == 0) first_string_sentinel_index = sentinel_index;
                string_sentinel_count += 1;
                i = parsed.template_end;
                continue;
            }

            if (input[i] == '\\' and i + 1 < input.len) {
                try out.append(allocator, input[i]);
                try out.append(allocator, input[i + 1]);
                string_literal_bytes += 2;
                i += 2;
                continue;
            }

            if (input[i] == '"') {
                if (string_literal_bytes == 0 and string_sentinel_count == 1) {
                    sentinels.items[first_string_sentinel_index].placement = .whole_string;
                }
                try out.append(allocator, input[i]);
                in_json_string = false;
                i += 1;
                continue;
            }

            try out.append(allocator, input[i]);
            string_literal_bytes += 1;
            i += 1;
            continue;
        }

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
                .raw_value,
            );
            try out.append(allocator, '"');
            try out.appendSlice(allocator, sentinels.items[sentinel_index].uuid);
            try out.append(allocator, '"');
            i = parsed.template_end;
            continue;
        }

        if (input[i] == '"') {
            in_json_string = true;
            string_literal_bytes = 0;
            string_sentinel_count = 0;
            first_string_sentinel_index = 0;
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
    placement: SentinelPlacement,
) !usize {
    const uuid = try nextUniqueSentinel(allocator, input, sentinels.items, sentinel_source);
    errdefer allocator.free(uuid);

    const expression = try allocator.dupe(u8, input[parsed.expression_start..parsed.expression_end]);
    errdefer allocator.free(expression);

    try sentinels.append(allocator, .{
        .uuid = uuid,
        .expression = expression,
        .source_range = .{
            .start = parsed.template_start,
            .end = parsed.template_end,
        },
        .placement = placement,
    });
    return sentinels.items.len - 1;
}

fn nextUniqueSentinel(
    allocator: std.mem.Allocator,
    input: []const u8,
    sentinels: []const Sentinel,
    sentinel_source: SentinelSource,
) ![]const u8 {
    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        const uuid = try sentinel_source.next(allocator);

        if (!isUuidString(uuid)) {
            allocator.free(uuid);
            return error.InvalidSentinelUuid;
        }
        if (std.mem.indexOf(u8, input, uuid) != null) {
            allocator.free(uuid);
            continue;
        }

        var collision = false;
        for (sentinels) |entry| {
            if (std.mem.eql(u8, entry.uuid, uuid)) {
                collision = true;
                break;
            }
        }
        if (collision) {
            allocator.free(uuid);
            continue;
        }

        return uuid;
    }
    return error.CouldNotGenerateUniqueSentinel;
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

fn randomUuid(context: *anyopaque, allocator: std.mem.Allocator) ![]const u8 {
    _ = context;

    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    var out = try allocator.alloc(u8, 36);
    var out_index: usize = 0;
    for (bytes, 0..) |byte, byte_index| {
        if (byte_index == 4 or byte_index == 6 or byte_index == 8 or byte_index == 10) {
            out[out_index] = '-';
            out_index += 1;
        }
        out[out_index] = hexDigit(byte >> 4);
        out[out_index + 1] = hexDigit(byte & 0x0f);
        out_index += 2;
    }
    return out;
}

fn isUuidString(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
            continue;
        }
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn hexDigit(nibble: u8) u8 {
    return "0123456789abcdef"[nibble & 0x0f];
}

fn startsWith(haystack: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, haystack, needle);
}

fn freeSentinels(allocator: std.mem.Allocator, sentinels: []const Sentinel) void {
    for (sentinels) |entry| {
        allocator.free(entry.uuid);
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

const test_uuid_1 = "11111111-1111-4111-8111-111111111111";
const test_uuid_2 = "22222222-2222-4222-8222-222222222222";
const test_uuid_3 = "33333333-3333-4333-8333-333333333333";

fn testSource(values: []const []const u8) DeterministicSentinels {
    return .{ .values = values };
}

test "literal escape emits at brace without a sentinel" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_uuid_1});

    const result = try scan(allocator, "{\"command\":[\"@@{exe_dir}\", @@{literal}]}", source.source());
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("{\"command\":[\"@{exe_dir}\", @{literal}]}", result.json);
    try std.testing.expectEqual(@as(usize, 0), result.sentinels.len);
}

test "raw template expression becomes a quoted sentinel value" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_uuid_1});
    const input = "{\"command\":[@{args}]}";

    const result = try scan(allocator, input, source.source());
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("{\"command\":[\"" ++ test_uuid_1 ++ "\"]}", result.json);
    try std.testing.expectEqual(@as(usize, 1), result.sentinels.len);
    try std.testing.expectEqualStrings(test_uuid_1, result.sentinels[0].uuid);
    try std.testing.expectEqualStrings("args", result.sentinels[0].expression);
    try std.testing.expectEqual(SentinelPlacement.raw_value, result.sentinels[0].placement);
    try std.testing.expectEqual(@as(usize, 12), result.sentinels[0].source_range.start);
    try std.testing.expectEqual(@as(usize, 19), result.sentinels[0].source_range.end);
}

test "single template inside a JSON string is marked as a whole string" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_uuid_1});

    const result = try scan(allocator, "{\"cwd\":\"@{exe_dir}\"}", source.source());
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("{\"cwd\":\"" ++ test_uuid_1 ++ "\"}", result.json);
    try std.testing.expectEqual(@as(usize, 1), result.sentinels.len);
    try std.testing.expectEqualStrings("exe_dir", result.sentinels[0].expression);
    try std.testing.expectEqual(SentinelPlacement.whole_string, result.sentinels[0].placement);
}

test "template mixed with literal JSON string text is marked partial" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_uuid_1});

    const result = try scan(allocator, "{\"path\":\"prefix @{exe_name} suffix\"}", source.source());
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("{\"path\":\"prefix " ++ test_uuid_1 ++ " suffix\"}", result.json);
    try std.testing.expectEqual(@as(usize, 1), result.sentinels.len);
    try std.testing.expectEqual(SentinelPlacement.partial_string, result.sentinels[0].placement);
}

test "multiple templates in one JSON string are both partial sentinels" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{ test_uuid_1, test_uuid_2 });

    const result = try scan(allocator, "\"@{exe_dir}@{exe_name}\"", source.source());
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("\"" ++ test_uuid_1 ++ test_uuid_2 ++ "\"", result.json);
    try std.testing.expectEqual(@as(usize, 2), result.sentinels.len);
    try std.testing.expectEqual(SentinelPlacement.partial_string, result.sentinels[0].placement);
    try std.testing.expectEqual(SentinelPlacement.partial_string, result.sentinels[1].placement);
}

test "quoted braces and nested parentheses inside templates do not end the expression" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_uuid_1});

    const input = "\"@{env:\"PATH}\":prepend_env(exe_dir:parent:join(\"python}\"))}\"";
    const result = try scan(allocator, input, source.source());
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("\"" ++ test_uuid_1 ++ "\"", result.json);
    try std.testing.expectEqualStrings(
        "env:\"PATH}\":prepend_env(exe_dir:parent:join(\"python}\"))",
        result.sentinels[0].expression,
    );
    try std.testing.expectEqual(SentinelPlacement.whole_string, result.sentinels[0].placement);
}

test "JSON escapes inside template strings are consumed as part of the expression" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_uuid_1});

    const result = try scan(allocator, "\"@{exe_dir:join(\"quote\\\"brace}unicode\\u007d\")}\"", source.source());
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("\"" ++ test_uuid_1 ++ "\"", result.json);
    try std.testing.expectEqualStrings("exe_dir:join(\"quote\\\"brace}unicode\\u007d\")", result.sentinels[0].expression);
}

test "sentinel source retries collisions with user text and previous sentinels" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{ test_uuid_1, test_uuid_1, test_uuid_2, test_uuid_3 });
    const input = "{\"literal\":\"" ++ test_uuid_1 ++ "\",\"values\":[@{a},@{b}]}";

    const result = try scan(allocator, input, source.source());
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("{\"literal\":\"" ++ test_uuid_1 ++ "\",\"values\":[\"" ++ test_uuid_2 ++ "\",\"" ++ test_uuid_3 ++ "\"]}", result.json);
    try std.testing.expectEqualStrings(test_uuid_2, result.sentinels[0].uuid);
    try std.testing.expectEqualStrings(test_uuid_3, result.sentinels[1].uuid);
}

test "empty template expression is rejected" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_uuid_1});

    try std.testing.expectError(error.EmptyTemplateExpression, scan(allocator, "@{}", source.source()));
}

test "unclosed template expression is rejected" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_uuid_1});

    try std.testing.expectError(error.UnclosedTemplateExpression, scan(allocator, "@{args", source.source()));
}

test "unclosed template string is rejected" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_uuid_1});

    try std.testing.expectError(error.UnclosedTemplateString, scan(allocator, "@{join(\"x)}", source.source()));
}

test "unclosed template parenthesis is rejected" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_uuid_1});

    try std.testing.expectError(error.UnclosedTemplateParenthesis, scan(allocator, "@{join(\"x\"}", source.source()));
}

test "invalid JSON string escape inside a template is rejected" {
    const allocator = std.testing.allocator;
    var source = testSource(&.{test_uuid_1});

    try std.testing.expectError(error.InvalidTemplateStringEscape, scan(allocator, "\"@{join(\"\\q\")}\"", source.source()));
}

test "random sentinel source generates UUID-shaped values" {
    const allocator = std.testing.allocator;
    const uuid = try randomSentinelSource().next(allocator);
    defer allocator.free(uuid);

    try std.testing.expect(isUuidString(uuid));
    try std.testing.expectEqual(@as(u8, '4'), uuid[14]);
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", uuid[19]) != null);
}
