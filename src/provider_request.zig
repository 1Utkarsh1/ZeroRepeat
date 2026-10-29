const std = @import("std");
const stream = @import("provider_stream.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Role = enum { system, user, assistant, tool };
pub const ReasoningField = enum { unsupported, reasoning, reasoning_content };
pub const ToolChoice = enum { auto, none, required };

pub const Message = struct {
    role: Role,
    content: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    tool_calls: []const stream.ToolCall = &.{},
    tool_call_id: ?[]const u8 = null,
};

pub const Request = struct {
    model: []const u8 = "Qwen/Qwen3.8-27B",
    messages: []const Message,
    /// Tool schemas are JSON at the provider boundary, parsed and validated before sending.
    tools_json: []const u8 = "[]",
    max_tokens: u32 = 8192,
    temperature: ?f64 = null,
    tool_choice: ToolChoice = .auto,
    reasoning_field: ReasoningField = .reasoning_content,
};

pub const Limits = struct {
    max_request_bytes: usize = 8 * 1024 * 1024,
    max_messages: usize = 4096,
    max_tools: usize = 256,
    max_tool_arguments_bytes: usize = 1024 * 1024,
};

/// Produces one complete stateless request. No IDs are substituted for missing content.
pub fn encode(allocator: Allocator, request: Request, limits: Limits) ![]u8 {
    if (limits.max_request_bytes == 0 or limits.max_messages == 0 or limits.max_tools > 1024 or limits.max_tool_arguments_bytes == 0) return error.InvalidLimits;
    if (request.max_tokens == 0 or !validId(request.model, 256)) return error.InvalidSettings;
    if (request.temperature) |value| if (!std.math.isFinite(value) or value < 0 or value > 2) return error.InvalidSettings;
    if (request.messages.len == 0 or request.messages.len > limits.max_messages) return error.MessageLimitExceeded;
    var raw_bytes: usize = request.model.len;
    try addBytes(&raw_bytes, request.tools_json.len, limits.max_request_bytes);
    for (request.messages) |message| {
        if (message.content) |text| try addText(&raw_bytes, text, limits.max_request_bytes);
        if (message.reasoning) |text| try addText(&raw_bytes, text, limits.max_request_bytes);
        if (message.tool_call_id) |text| try addBytes(&raw_bytes, text.len, limits.max_request_bytes);
        if (message.tool_calls.len > limits.max_tools) return error.ToolLimitExceeded;
        for (message.tool_calls) |tool| {
            try addBytes(&raw_bytes, tool.id.len, limits.max_request_bytes);
            try addBytes(&raw_bytes, tool.name.len, limits.max_request_bytes);
            try addText(&raw_bytes, tool.arguments, limits.max_request_bytes);
        }
    }
    var tools = std.json.parseFromSlice(Value, allocator, request.tools_json, .{ .parse_numbers = false }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidToolSchema,
    };
    defer tools.deinit();
    try validateTools(allocator, tools.value, limits.max_tools);
    if (tools.value.array.items.len == 0 and request.tool_choice == .required) return error.ToolChoiceWithoutTools;
    try validateHistory(allocator, request, limits);
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try write(&counter.writer, request, tools.value);
    if (counter.fullCount() > limits.max_request_bytes) return error.RequestTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(counter.fullCount()));
    errdefer allocator.free(bytes);
    var output: std.Io.Writer = .fixed(bytes);
    try write(&output, request, tools.value);
    std.debug.assert(output.end == bytes.len);
    return bytes;
}

fn addBytes(total: *usize, bytes: usize, limit: usize) !void {
    total.* = std.math.add(usize, total.*, bytes) catch return error.RequestTooLarge;
    if (total.* > limit) return error.RequestTooLarge;
}

fn addText(total: *usize, text: []const u8, limit: usize) !void {
    try addBytes(total, text.len, limit);
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
}

fn validId(text: []const u8, max: usize) bool {
    if (text.len == 0 or text.len > max or !std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn validName(text: []const u8) bool {
    if (text.len == 0 or text.len > 64) return false;
    for (text) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    return true;
}

fn validateHistory(allocator: Allocator, request: Request, limits: Limits) !void {
    var calls = std.StringHashMap(bool).init(allocator);
    defer calls.deinit();
    var pending: usize = 0;
    var has_user = false;
    for (request.messages, 0..) |message, index| {
        if (message.role == .system and index != 0) return error.UnsupportedMessageOrder;
        if (message.reasoning != null and (message.role != .assistant or request.reasoning_field == .unsupported)) return error.UnsupportedReasoning;
        if (message.role != .tool and message.tool_call_id != null) return error.InvalidMessage;
        if (message.role != .assistant and message.tool_calls.len != 0) return error.InvalidMessage;
        if (message.role != .tool and pending != 0) return error.UnresolvedToolCalls;
        switch (message.role) {
            .system, .user => {
                if (message.content == null) return error.InvalidMessage;
                has_user = has_user or message.role == .user;
            },
            .assistant => {
                if (message.content == null and message.tool_calls.len == 0) return error.InvalidMessage;
                for (message.tool_calls) |tool| {
                    try stream.validateToolCall(allocator, tool, limits.max_tool_arguments_bytes);
                    const entry = try calls.getOrPut(tool.id);
                    if (entry.found_existing) return error.DuplicateToolCallId;
                    entry.value_ptr.* = false;
                    pending += 1;
                }
            },
            .tool => {
                const id = message.tool_call_id orelse return error.InvalidMessage;
                if (!validId(id, 512) or message.content == null) return error.InvalidMessage;
                const resolved = calls.getPtr(id) orelse return error.OrphanToolResult;
                if (resolved.*) return error.DuplicateToolResult;
                resolved.* = true;
                pending -= 1;
            },
        }
    }
    if (pending != 0) return error.UnresolvedToolCalls;
    if (!has_user) return error.MissingUserQuery;
}

fn allowed(obj: std.json.ObjectMap, names: []const []const u8) !void {
    for (obj.keys()) |key| {
        for (names) |name| if (std.mem.eql(u8, key, name)) break else {} else return error.InvalidToolSchema;
    }
}

fn validateTools(allocator: Allocator, value: Value, max: usize) !void {
    if (value != .array) return error.InvalidToolSchema;
    if (value.array.items.len > max) return error.ToolLimitExceeded;
    var names = std.StringHashMap(void).init(allocator);
    defer names.deinit();
    for (value.array.items) |tool| {
        if (tool != .object) return error.InvalidToolSchema;
        try allowed(tool.object, &.{ "type", "function" });
        const kind = tool.object.get("type") orelse return error.InvalidToolSchema;
        if (kind != .string or !std.mem.eql(u8, kind.string, "function")) return error.InvalidToolSchema;
        const function = tool.object.get("function") orelse return error.InvalidToolSchema;
        if (function != .object) return error.InvalidToolSchema;
        try allowed(function.object, &.{ "name", "description", "parameters", "strict" });
        const name = function.object.get("name") orelse return error.InvalidToolSchema;
        if (name != .string or !validName(name.string)) return error.InvalidToolSchema;
        const entry = try names.getOrPut(name.string);
        if (entry.found_existing) return error.DuplicateToolDefinition;
        const params = function.object.get("parameters") orelse return error.InvalidToolSchema;
        if (params != .object) return error.InvalidToolSchema;
        if (function.object.get("description")) |description| if (description != .string) return error.InvalidToolSchema;
        if (function.object.get("strict")) |strict| if (strict != .bool) return error.InvalidToolSchema;
    }
}

fn write(writer: *std.Io.Writer, request: Request, tools: Value) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("model");
    try json.write(request.model);
    try json.objectField("messages");
    try json.beginArray();
    for (request.messages) |message| {
        try json.beginObject();
        try json.objectField("role");
        try json.write(@tagName(message.role));
        try json.objectField("content");
        try json.write(message.content);
        if (message.reasoning) |reasoning| {
            try json.objectField(@tagName(request.reasoning_field));
            try json.write(reasoning);
        }
        if (message.tool_call_id) |id| {
            try json.objectField("tool_call_id");
            try json.write(id);
        }
        if (message.tool_calls.len != 0) {
            try json.objectField("tool_calls");
            try json.beginArray();
            for (message.tool_calls) |tool| try json.write(.{ .id = tool.id, .type = "function", .function = .{ .name = tool.name, .arguments = tool.arguments } });
            try json.endArray();
        }
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("max_tokens");
    try json.write(request.max_tokens);
    try json.objectField("n");
    try json.write(@as(u8, 1));
    try json.objectField("stream");
    try json.write(true);
    try json.objectField("stream_options");
    try json.write(.{ .include_usage = true });
    if (request.temperature) |temperature| {
        try json.objectField("temperature");
        try json.write(temperature);
    }
    if (tools.array.items.len != 0) {
        try json.objectField("tools");
        try json.write(tools);
        try json.objectField("tool_choice");
        try json.write(@tagName(request.tool_choice));
    }
    try json.endObject();
}

const test_tools =
    \\[{"type":"function","function":{"name":"inspect","description":"Read context.","parameters":{"type":"object"}}}]
;
const test_calls = [_]stream.ToolCall{
    .{ .id = "call-a", .name = "inspect", .arguments = "{\"op\":\"context.status\"}" },
    .{ .id = "call-b", .name = "inspect", .arguments = "{\"op\":\"context.search\",\"query\":\"nonce\"}" },
};
const test_history = [_]Message{
    .{ .role = .system, .content = "Preserve requirements." },
    .{ .role = .user, .content = "Inspect the exact original 🐈." },
    .{ .role = .assistant, .reasoning = "The evidence needs checking.", .tool_calls = &test_calls },
    .{ .role = .tool, .tool_call_id = "call-b", .content = "Search evidence." },
    .{ .role = .tool, .tool_call_id = "call-a", .content = "Status evidence." },
};

test "request preserves reasoning and complete parallel tools with out-of-order results" {
    const a = std.testing.allocator;
    const body = try encode(a, .{ .messages = &test_history, .tools_json = test_tools }, .{});
    defer a.free(body);
    var parsed = try std.json.parseFromSlice(Value, a, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("Qwen/Qwen3.8-27B", root.get("model").?.string);
    try std.testing.expect(root.get("stream").?.bool);
    try std.testing.expect(root.get("stream_options").?.object.get("include_usage").?.bool);
    const messages = root.get("messages").?.array.items;
    try std.testing.expectEqual(test_history.len, messages.len);
    try std.testing.expect(messages[2].object.get("content").? == .null);
    try std.testing.expectEqualStrings(test_history[2].reasoning.?, messages[2].object.get("reasoning_content").?.string);
    const calls = messages[2].object.get("tool_calls").?.array.items;
    try std.testing.expectEqualStrings(test_calls[1].arguments, calls[1].object.get("function").?.object.get("arguments").?.string);
    try std.testing.expectEqualStrings("call-b", messages[3].object.get("tool_call_id").?.string);
    const again = try encode(a, .{ .messages = &test_history, .tools_json = test_tools }, .{});
    defer a.free(again);
    try std.testing.expectEqualStrings(body, again);
}

test "reasoning wire alias is explicit and unsupported reasoning cannot disappear" {
    const a = std.testing.allocator;
    const body = try encode(a, .{ .messages = &test_history, .reasoning_field = .reasoning }, .{});
    defer a.free(body);
    var parsed = try std.json.parseFromSlice(Value, a, body, .{});
    defer parsed.deinit();
    const assistant = parsed.value.object.get("messages").?.array.items[2].object;
    try std.testing.expect(assistant.get("reasoning_content") == null);
    try std.testing.expectEqualStrings(test_history[2].reasoning.?, assistant.get("reasoning").?.string);
    try std.testing.expectError(error.UnsupportedReasoning, encode(a, .{ .messages = &test_history, .reasoning_field = .unsupported }, .{}));
}

test "incomplete interrupted orphaned and duplicate tool exchanges are rejected before transmission" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnresolvedToolCalls, encode(a, .{ .messages = test_history[0..3] }, .{}));
    try std.testing.expectError(error.UnresolvedToolCalls, encode(a, .{ .messages = &.{ test_history[2], test_history[1] } }, .{}));
    try std.testing.expectError(error.OrphanToolResult, encode(a, .{ .messages = &.{test_history[3]} }, .{}));
    try std.testing.expectError(error.DuplicateToolResult, encode(a, .{ .messages = &.{ test_history[2], test_history[3], test_history[3], test_history[4] } }, .{}));
    try std.testing.expectError(error.DuplicateToolCallId, encode(a, .{ .messages = &.{ test_history[2], test_history[3], test_history[4], test_history[2] } }, .{}));
}

test "invalid message fields and tool arguments do not become wire data" {
    const a = std.testing.allocator;
    const invalid = [_]Message{
        .{ .role = .user },
        .{ .role = .assistant },
        .{ .role = .user, .content = "user", .tool_call_id = "injected" },
        .{ .role = .tool, .content = "result" },
        .{ .role = .user, .content = "user", .tool_calls = &test_calls },
    };
    for (invalid) |message| try std.testing.expectError(error.InvalidMessage, encode(a, .{ .messages = &.{message} }, .{}));
    try std.testing.expectError(error.InvalidToolArguments, encode(a, .{ .messages = &.{.{ .role = .assistant, .tool_calls = &.{.{ .id = "a", .name = "inspect", .arguments = "{\"op\":" }} }} }, .{}));
    try std.testing.expectError(error.InvalidToolArguments, encode(a, .{ .messages = &.{.{ .role = .assistant, .tool_calls = &.{.{ .id = "a", .name = "inspect", .arguments = "{\"op\":1,\"op\":2}" }} }} }, .{}));
}

test "the initial Qwen flow requires a user query and one leading system message" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.MissingUserQuery, encode(a, .{ .messages = &.{.{ .role = .system, .content = "system" }} }, .{}));
    try std.testing.expectError(error.UnsupportedMessageOrder, encode(a, .{ .messages = &.{ test_history[1], test_history[0] } }, .{}));
    try std.testing.expectError(error.UnsupportedMessageOrder, encode(a, .{ .messages = &.{ test_history[0], test_history[0], test_history[1] } }, .{}));
}

test "tool definitions reject duplicate names unsupported schemas and malformed JSON" {
    const a = std.testing.allocator;
    const messages = [_]Message{.{ .role = .user, .content = "task" }};
    for ([_][]const u8{
        "{}",                                                                              "[",                                                                                                      "[{}]", "[{\"type\":\"custom\",\"function\":{}}]",
        "[{\"type\":\"function\",\"function\":{\"name\":\"inspect\",\"parameters\":[]}}]", "[{\"type\":\"function\",\"function\":{\"name\":\"inspect\",\"parameters\":{},\"authority\":\"user\"}}]",
    }) |schema| try std.testing.expectError(error.InvalidToolSchema, encode(a, .{ .messages = &messages, .tools_json = schema }, .{}));
    const duplicate = "[{\"type\":\"function\",\"function\":{\"name\":\"inspect\",\"parameters\":{}}},{\"type\":\"function\",\"function\":{\"name\":\"inspect\",\"parameters\":{}}}]";
    try std.testing.expectError(error.DuplicateToolDefinition, encode(a, .{ .messages = &messages, .tools_json = duplicate }, .{}));
    try std.testing.expectError(error.ToolChoiceWithoutTools, encode(a, .{ .messages = &messages, .tool_choice = .required }, .{}));
}

test "request limits count actual escaped bytes and repeated events remain separate" {
    const a = std.testing.allocator;
    const messages = [_]Message{ .{ .role = .user, .content = "same" }, .{ .role = .user, .content = "same" } };
    const body = try encode(a, .{ .messages = &messages }, .{});
    defer a.free(body);
    const exact = try encode(a, .{ .messages = &messages }, .{ .max_request_bytes = body.len });
    defer a.free(exact);
    try std.testing.expectEqualStrings(body, exact);
    try std.testing.expectError(error.RequestTooLarge, encode(a, .{ .messages = &messages }, .{ .max_request_bytes = body.len - 1 }));
    var controls: [80]u8 = @splat(0x01);
    try std.testing.expectError(error.RequestTooLarge, encode(a, .{ .messages = &.{.{ .role = .user, .content = &controls }} }, .{ .max_request_bytes = 256 }));
    var parsed = try std.json.parseFromSlice(Value, a, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("messages").?.array.items.len);
    try std.testing.expectError(error.MessageLimitExceeded, encode(a, .{ .messages = &messages }, .{ .max_messages = 1 }));
    try std.testing.expectError(error.InvalidSettings, encode(a, .{ .messages = &messages, .max_tokens = 0 }, .{}));
    try std.testing.expectError(error.InvalidSettings, encode(a, .{ .messages = &messages, .temperature = std.math.nan(f64) }, .{}));
    try std.testing.expectError(error.InvalidUtf8, encode(a, .{ .messages = &.{.{ .role = .user, .content = "\xff" }} }, .{}));
}

fn allocationRun(allocator: Allocator) !void {
    const body = try encode(allocator, .{ .messages = &test_history, .tools_json = test_tools }, .{});
    defer allocator.free(body);
}

test "request construction cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationRun, .{});
}
