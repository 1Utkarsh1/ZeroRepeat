const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Limits = struct {
    max_event_bytes: usize = 1024 * 1024,
    max_response_bytes: usize = 8 * 1024 * 1024,
    max_tools: usize = 32,
    max_arguments_bytes: usize = 1024 * 1024,

    fn validate(self: Limits) !void {
        if (self.max_event_bytes == 0 or self.max_response_bytes == 0 or
            self.max_arguments_bytes == 0 or self.max_tools > 1024) return error.InvalidLimits;
    }
};

pub const FinishReason = enum { stop, tool_calls, length, content_filter };

pub const Usage = struct {
    input_tokens: u64,
    output_tokens: u64,
    cached_input_tokens: ?u64 = null,
    reasoning_tokens: ?u64 = null,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const Reply = struct {
    arena: std.heap.ArenaAllocator,
    id: []const u8,
    content: []const u8,
    reasoning: []const u8,
    tools: []const ToolCall,
    finish_reason: FinishReason,
    usage: ?Usage,

    pub fn deinit(self: *Reply) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Value = std.json.Value;
const ToolDelta = struct {
    index: Value,
    id: ?[]const u8 = null,
    type: ?[]const u8 = null,
    function: ?struct {
        name: ?[]const u8 = null,
        arguments: ?[]const u8 = null,
    } = null,
};
const Delta = struct {
    role: ?[]const u8 = null,
    content: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    refusal: ?[]const u8 = null,
    tool_calls: ?[]const ToolDelta = null,
    audio: ?Value = null,
    function_call: ?Value = null,
};
const WireUsage = struct {
    prompt_tokens: Value,
    completion_tokens: Value,
    total_tokens: ?Value = null,
    prompt_tokens_details: ?struct { cached_tokens: ?Value = null } = null,
    completion_tokens_details: ?struct { reasoning_tokens: ?Value = null } = null,
};
const Chunk = struct {
    id: ?[]const u8 = null,
    object: ?[]const u8 = null,
    choices: []const struct {
        index: Value,
        delta: Delta,
        finish_reason: ?[]const u8 = null,
    } = &.{},
    usage: ?WireUsage = null,
    @"error": ?struct { message: ?[]const u8 = null } = null,
};
const ToolState = struct {
    present: bool = false,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: std.ArrayList(u8) = .empty,
};

/// Chat Completions SSE only. No tools leave the decoder before finish validates all of them.
pub const Decoder = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    limits: Limits,
    line: std.ArrayList(u8) = .empty,
    event_data: std.ArrayList(u8) = .empty,
    event_bytes: usize = 0,
    response_bytes: usize = 0,
    has_data: bool = false,
    event_error: bool = false,
    first_line: bool = true,
    completion_id: ?[]const u8 = null,
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    tool_state: std.ArrayList(ToolState) = .empty,
    finish_reason: ?FinishReason = null,
    usage: ?Usage = null,
    done: bool = false,
    failed: bool = false,
    finished: bool = false,

    pub fn init(allocator: Allocator, limits: Limits) !Decoder {
        try limits.validate();
        return .{ .allocator = allocator, .arena = .init(allocator), .limits = limits };
    }

    pub fn deinit(self: *Decoder) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn feed(self: *Decoder, bytes: []const u8) !void {
        if (self.finished) return error.DecoderFinished;
        if (self.failed) return error.DecoderFailed;
        errdefer self.failed = true;
        if (bytes.len == 0) return;
        if (self.done) return error.DataAfterDone;
        if (bytes.len > self.limits.max_response_bytes - self.response_bytes) return error.ResponseTooLarge;
        self.response_bytes += bytes.len;
        const a = self.arena.allocator();
        for (bytes) |byte| {
            if (self.done) return error.DataAfterDone;
            if (self.event_bytes == self.limits.max_event_bytes) return error.EventTooLarge;
            self.event_bytes += 1;
            if (byte == '\n') {
                var text: []const u8 = self.line.items;
                if (std.mem.endsWith(u8, text, "\r")) text = text[0 .. text.len - 1];
                try self.processLine(text);
                self.line.clearRetainingCapacity();
            } else try self.line.append(a, byte);
        }
    }

    fn processLine(self: *Decoder, raw: []const u8) !void {
        var line = raw;
        if (self.first_line) {
            self.first_line = false;
            if (std.mem.startsWith(u8, line, "\xef\xbb\xbf")) line = line[3..];
        }
        if (line.len == 0) {
            if (self.event_error) return error.ProviderError;
            if (self.has_data) try self.processEvent(self.event_data.items);
            self.event_data.clearRetainingCapacity();
            self.has_data = false;
            self.event_error = false;
            self.event_bytes = 0;
            return;
        }
        if (line[0] == ':') return;
        const colon = std.mem.indexOfScalar(u8, line, ':');
        const field = if (colon) |index| line[0..index] else line;
        var value = if (colon) |index| line[index + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];
        if (std.mem.eql(u8, field, "event")) {
            if (std.mem.eql(u8, value, "error")) self.event_error = true;
        } else if (std.mem.eql(u8, field, "data")) {
            const a = self.arena.allocator();
            if (self.has_data) try self.event_data.append(a, '\n');
            try self.event_data.appendSlice(a, value);
            self.has_data = true;
        }
    }

    fn processEvent(self: *Decoder, bytes: []const u8) !void {
        if (std.mem.eql(u8, std.mem.trim(u8, bytes, " \t\r\n"), "[DONE]")) {
            if (self.finish_reason == null) return error.MissingFinishReason;
            self.done = true;
            return;
        }
        var parsed = std.json.parseFromSlice(Chunk, self.allocator, bytes, .{
            .ignore_unknown_fields = true,
            .parse_numbers = false,
            .max_value_len = self.limits.max_event_bytes,
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.MalformedChunk,
        };
        defer parsed.deinit();
        const chunk = parsed.value;
        if (chunk.@"error" != null) return error.ProviderError;
        if (chunk.object) |object| if (!std.mem.eql(u8, object, "chat.completion.chunk")) return error.UnsupportedObject;
        const id = chunk.id orelse return error.InvalidCompletionId;
        if (!validId(id)) return error.InvalidCompletionId;
        if (self.completion_id) |current| {
            if (!std.mem.eql(u8, current, id)) return error.ConflictingCompletionId;
        } else self.completion_id = try self.arena.allocator().dupe(u8, id);
        if (chunk.choices.len > 1) return error.UnsupportedChoiceCount;
        if (chunk.choices.len == 0) {
            if (chunk.usage == null or self.finish_reason == null) return error.InvalidUsageOrder;
        } else {
            if (self.finish_reason != null) return error.DataAfterFinish;
            const choice = chunk.choices[0];
            if (try unsigned(choice.index) != 0) return error.UnsupportedChoiceIndex;
            try self.applyDelta(choice.delta);
            if (choice.finish_reason) |reason| self.finish_reason = std.meta.stringToEnum(FinishReason, reason) orelse return error.UnsupportedFinishReason;
        }
        if (chunk.usage) |usage| {
            if (self.finish_reason == null) return error.InvalidUsageOrder;
            if (self.usage != null) return error.DuplicateUsage;
            const input = try unsigned(usage.prompt_tokens);
            const output = try unsigned(usage.completion_tokens);
            const total = std.math.add(u64, input, output) catch return error.InvalidUsage;
            if (usage.total_tokens) |value| if (try unsigned(value) != total) return error.InvalidUsage;
            const cached = if (usage.prompt_tokens_details) |details|
                if (details.cached_tokens) |value| try unsigned(value) else null
            else
                null;
            const reasoning = if (usage.completion_tokens_details) |details|
                if (details.reasoning_tokens) |value| try unsigned(value) else null
            else
                null;
            if ((cached != null and cached.? > input) or (reasoning != null and reasoning.? > output)) return error.InvalidUsage;
            self.usage = .{ .input_tokens = input, .output_tokens = output, .cached_input_tokens = cached, .reasoning_tokens = reasoning };
        }
    }

    fn applyDelta(self: *Decoder, delta: Delta) !void {
        if (delta.role) |role| if (!std.mem.eql(u8, role, "assistant")) return error.InvalidRole;
        if (delta.audio != null or delta.function_call != null) return error.UnsupportedDelta;
        const a = self.arena.allocator();
        if (delta.content) |text| try self.content.appendSlice(a, text);
        if (delta.refusal) |text| try self.content.appendSlice(a, text);
        if (delta.reasoning) |text| {
            if (delta.reasoning_content) |legacy| {
                if (text.len > 0 and legacy.len > 0 and !std.mem.eql(u8, text, legacy)) return error.ConflictingReasoning;
                try self.reasoning.appendSlice(a, if (text.len == 0) legacy else text);
            } else try self.reasoning.appendSlice(a, text);
        } else if (delta.reasoning_content) |text| try self.reasoning.appendSlice(a, text);
        if (delta.tool_calls) |tools| for (tools) |tool| {
            const index = try unsigned(tool.index);
            if (index >= self.limits.max_tools) return error.ToolLimitExceeded;
            while (self.tool_state.items.len <= index) try self.tool_state.append(a, .{});
            const state = &self.tool_state.items[@intCast(index)];
            state.present = true;
            if (tool.type) |kind| {
                if (!std.mem.eql(u8, kind, "function")) return error.UnsupportedToolType;
            }
            if (tool.id) |id| if (id.len > 0) {
                if (!validId(id)) return error.InvalidToolCall;
                if (state.id) |current| {
                    if (!std.mem.eql(u8, current, id)) return error.ConflictingToolCall;
                } else state.id = try a.dupe(u8, id);
            };
            if (tool.function) |function| {
                if (function.name) |name| if (name.len > 0) {
                    if (!validName(name)) return error.InvalidToolCall;
                    if (state.name) |current| {
                        if (!std.mem.eql(u8, current, name)) return error.ConflictingToolCall;
                    } else state.name = try a.dupe(u8, name);
                };
                if (function.arguments) |arguments| {
                    if (arguments.len > self.limits.max_arguments_bytes - state.arguments.items.len) return error.ArgumentsTooLarge;
                    try state.arguments.appendSlice(a, arguments);
                }
            }
        };
    }

    pub fn finish(self: *Decoder) !Reply {
        if (self.finished) return error.DecoderFinished;
        if (self.failed) return error.DecoderFailed;
        errdefer self.failed = true;
        if (!self.done or self.line.items.len != 0 or self.has_data) return error.TruncatedStream;
        const reason = self.finish_reason orelse return error.MissingFinishReason;
        if ((reason == .tool_calls) != (self.tool_state.items.len != 0)) return error.InconsistentFinishReason;
        for (self.tool_state.items, 0..) |tool, index| {
            if (!tool.present or tool.id == null or tool.name == null) return error.IncompleteToolCall;
            for (self.tool_state.items[0..index]) |other| if (other.id != null and std.mem.eql(u8, tool.id.?, other.id.?)) return error.DuplicateToolCallId;
            var arguments = std.json.parseFromSlice(Value, self.allocator, tool.arguments.items, .{
                .parse_numbers = false,
                .max_value_len = self.limits.max_arguments_bytes,
            }) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidToolArguments,
            };
            defer arguments.deinit();
            if (arguments.value != .object) return error.InvalidToolArguments;
        }
        const tools = try self.arena.allocator().alloc(ToolCall, self.tool_state.items.len);
        for (self.tool_state.items, tools) |state, *tool| tool.* = .{ .id = state.id.?, .name = state.name.?, .arguments = state.arguments.items };
        const result: Reply = .{
            .arena = self.arena,
            .id = self.completion_id orelse return error.InvalidCompletionId,
            .content = self.content.items,
            .reasoning = self.reasoning.items,
            .tools = tools,
            .finish_reason = reason,
            .usage = self.usage,
        };
        self.arena = .init(self.allocator);
        self.finished = true;
        return result;
    }
};

fn unsigned(value: Value) !u64 {
    if (value != .number_string or value.number_string.len == 0) return error.InvalidInteger;
    for (value.number_string) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidInteger;
    return std.fmt.parseInt(u64, value.number_string, 10) catch return error.InvalidInteger;
}

fn validId(value: []const u8) bool {
    if (value.len == 0 or value.len > 512 or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn validName(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    return true;
}

const test_a = std.testing.allocator;

fn stream(chunks: []const []const u8, done: bool) ![]u8 {
    var bytes: std.Io.Writer.Allocating = .init(test_a);
    defer bytes.deinit();
    for (chunks) |chunk| try bytes.writer.print("data: {s}\n\n", .{chunk});
    if (done) try bytes.writer.writeAll("data: [DONE]\n\n");
    return bytes.toOwnedSlice();
}

const text_chunk =
    \\{"id":"completion-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello 🐈","reasoning":"Consider carefully."},"finish_reason":null}]}
;
const stop_chunk =
    \\{"id":"completion-1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
;
const tools_first =
    \\{"id":"completion-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call-b","type":"function","function":{"name":"inspect","arguments":"{\"query\":"}},{"index":0,"id":"call-a","type":"function","function":{"name":"inspect","arguments":"{\"query\":\""}}]},"finish_reason":null}]}
;
const tools_last =
    \\{"id":"completion-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"auth\"}"}},{"index":1,"function":{"arguments":"\"tests\"}"}}]},"finish_reason":"tool_calls"}]}
;

test "every two-part network split and bytewise UTF-8 splits produce the same complete text reply" {
    const wire = try stream(&.{ text_chunk, stop_chunk }, true);
    defer test_a.free(wire);
    for (0..wire.len + 1) |split| {
        var decoder = try Decoder.init(test_a, .{});
        defer decoder.deinit();
        try decoder.feed(wire[0..split]);
        try decoder.feed(wire[split..]);
        var reply = try decoder.finish();
        defer reply.deinit();
        try std.testing.expectEqualStrings("Hello 🐈", reply.content);
        try std.testing.expectEqualStrings("Consider carefully.", reply.reasoning);
        try std.testing.expectEqual(FinishReason.stop, reply.finish_reason);
        try std.testing.expectEqual(@as(usize, 0), reply.tools.len);
        try std.testing.expect(reply.usage == null);
    }
    var decoder = try Decoder.init(test_a, .{});
    defer decoder.deinit();
    for (wire) |byte| try decoder.feed(&.{byte});
    var reply = try decoder.finish();
    defer reply.deinit();
    try std.testing.expectEqualStrings("Hello 🐈", reply.content);
}

test "CRLF comments, multiline data, BOM, and legacy reasoning survive bytewise framing" {
    const wire = "\xef\xbb\xbf: heartbeat\r\n\r\nevent: message\r\ndata: {\"id\":\"completion-1\",\r\ndata: \"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"think\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\r\n\r\ndata: [DONE]\r\n\r\n";
    var decoder = try Decoder.init(test_a, .{});
    defer decoder.deinit();
    for (wire) |byte| try decoder.feed(&.{byte});
    var reply = try decoder.finish();
    defer reply.deinit();
    try std.testing.expectEqualStrings("ok", reply.content);
    try std.testing.expectEqualStrings("think", reply.reasoning);
}

test "interleaved argument fragments become complete ordered tools with repeated function names" {
    const wire = try stream(&.{ tools_first, tools_last }, true);
    defer test_a.free(wire);
    for (0..wire.len + 1) |split| {
        var decoder = try Decoder.init(test_a, .{});
        defer decoder.deinit();
        try decoder.feed(wire[0..split]);
        try decoder.feed(wire[split..]);
        var reply = try decoder.finish();
        defer reply.deinit();
        try std.testing.expectEqual(FinishReason.tool_calls, reply.finish_reason);
        try std.testing.expectEqual(@as(usize, 2), reply.tools.len);
        try std.testing.expectEqualStrings("call-a", reply.tools[0].id);
        try std.testing.expectEqualStrings("call-b", reply.tools[1].id);
        try std.testing.expectEqualStrings("inspect", reply.tools[0].name);
        try std.testing.expectEqualStrings("inspect", reply.tools[1].name);
        try std.testing.expectEqualStrings("{\"query\":\"auth\"}", reply.tools[0].arguments);
        try std.testing.expectEqualStrings("{\"query\":\"tests\"}", reply.tools[1].arguments);
    }
}

test "final usage-only chunk preserves cached and reasoning token counts without treating them as extra tokens" {
    const usage =
        \\{"id":"completion-1","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"prompt_tokens_details":{"cached_tokens":3},"completion_tokens_details":{"reasoning_tokens":2}}}
    ;
    const wire = try stream(&.{ text_chunk, stop_chunk, usage }, true);
    defer test_a.free(wire);
    var decoder = try Decoder.init(test_a, .{});
    defer decoder.deinit();
    try decoder.feed(wire);
    var reply = try decoder.finish();
    defer reply.deinit();
    try std.testing.expectEqualDeep(Usage{ .input_tokens = 10, .output_tokens = 5, .cached_input_tokens = 3, .reasoning_tokens = 2 }, reply.usage.?);
}

test "reply owns its memory after decoder deinit and neither decoder operation can be repeated" {
    const wire = try stream(&.{ text_chunk, stop_chunk }, true);
    defer test_a.free(wire);
    var decoder = try Decoder.init(test_a, .{});
    try decoder.feed(wire);
    var reply = try decoder.finish();
    defer reply.deinit();
    try std.testing.expectError(error.DecoderFinished, decoder.finish());
    try std.testing.expectError(error.DecoderFinished, decoder.feed("more"));
    decoder.deinit();
    try std.testing.expectEqualStrings("completion-1", reply.id);
    try std.testing.expectEqualStrings("Hello 🐈", reply.content);
}

test "truncated streams and data after DONE cannot yield a reply" {
    const no_done = try stream(&.{ text_chunk, stop_chunk }, false);
    defer test_a.free(no_done);
    var truncated = try Decoder.init(test_a, .{});
    defer truncated.deinit();
    try truncated.feed(no_done);
    try std.testing.expectError(error.TruncatedStream, truncated.finish());
    try std.testing.expectError(error.DecoderFailed, truncated.feed("data: [DONE]\n\n"));
    const valid = try stream(&.{stop_chunk}, true);
    defer test_a.free(valid);
    var trailing = try Decoder.init(test_a, .{});
    defer trailing.deinit();
    try trailing.feed(valid);
    try std.testing.expectError(error.DataAfterDone, trailing.feed("\n"));
    try std.testing.expectError(error.DecoderFailed, trailing.finish());
    var premature = try Decoder.init(test_a, .{});
    defer premature.deinit();
    try std.testing.expectError(error.MissingFinishReason, premature.feed("data: [DONE]\n\n"));
}

test "malformed, duplicate-key, non-object, and incomplete arguments never leave as executable tools" {
    for ([_][]const u8{ "{", "[]", "null", "{\"key\":1,\"key\":2}" }) |arguments| {
        const encoded = try std.json.Stringify.valueAlloc(test_a, arguments, .{});
        defer test_a.free(encoded);
        const chunk = try std.fmt.allocPrint(test_a, "{{\"id\":\"completion-1\",\"choices\":[{{\"index\":0,\"delta\":{{\"tool_calls\":[{{\"index\":0,\"id\":\"call\",\"type\":\"function\",\"function\":{{\"name\":\"inspect\",\"arguments\":{s}}}}}]}},\"finish_reason\":\"tool_calls\"}}]}}", .{encoded});
        defer test_a.free(chunk);
        const wire = try stream(&.{chunk}, true);
        defer test_a.free(wire);
        var decoder = try Decoder.init(test_a, .{});
        defer decoder.deinit();
        try decoder.feed(wire);
        try std.testing.expectError(error.InvalidToolArguments, decoder.finish());
        try std.testing.expectError(error.DecoderFailed, decoder.finish());
    }
}

test "duplicate tool IDs, missing metadata, and tool fragments with a text finish are rejected" {
    const duplicate =
        \\{"id":"completion-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"duplicate","type":"function","function":{"name":"inspect","arguments":"{}"}},{"index":1,"id":"duplicate","type":"function","function":{"name":"inspect","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}
    ;
    const missing =
        \\{"id":"completion-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{}"}}]},"finish_reason":"tool_calls"}]}
    ;
    const wrong_finish =
        \\{"id":"completion-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call","type":"function","function":{"name":"inspect","arguments":"{}"}}]},"finish_reason":"length"}]}
    ;
    const cases = [_]struct { chunk: []const u8, err: anyerror }{
        .{ .chunk = duplicate, .err = error.DuplicateToolCallId },
        .{ .chunk = missing, .err = error.IncompleteToolCall },
        .{ .chunk = wrong_finish, .err = error.InconsistentFinishReason },
    };
    for (cases) |case| {
        const wire = try stream(&.{case.chunk}, true);
        defer test_a.free(wire);
        var decoder = try Decoder.init(test_a, .{});
        defer decoder.deinit();
        try decoder.feed(wire);
        try std.testing.expectError(case.err, decoder.finish());
    }
}

test "text length and content-filter finishes remain typed non-success outcomes" {
    for ([_][]const u8{ "length", "content_filter" }) |reason| {
        const chunk = try std.fmt.allocPrint(test_a, "{{\"id\":\"completion-1\",\"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"Partial output.\"}},\"finish_reason\":\"{s}\"}}]}}", .{reason});
        defer test_a.free(chunk);
        const wire = try stream(&.{chunk}, true);
        defer test_a.free(wire);
        var decoder = try Decoder.init(test_a, .{});
        defer decoder.deinit();
        try decoder.feed(wire);
        var reply = try decoder.finish();
        defer reply.deinit();
        try std.testing.expect(reply.finish_reason != .stop);
        try std.testing.expectEqual(@as(usize, 0), reply.tools.len);
    }
}

test "choice count, numeric types, completion identity, error events, and invalid JSON fail closed" {
    const cases = [_]struct { chunk: []const u8, err: anyerror }{
        .{ .chunk = "{", .err = error.MalformedChunk },
        .{ .chunk = "{\"error\":{\"message\":\"provider failure\"}}", .err = error.ProviderError },
        .{ .chunk = "{\"id\":\"completion-1\",\"choices\":[{\"index\":1,\"delta\":{}}]}", .err = error.UnsupportedChoiceIndex },
        .{ .chunk = "{\"id\":\"completion-1\",\"choices\":[{\"index\":\"0\",\"delta\":{}}]}", .err = error.InvalidInteger },
        .{ .chunk = "{\"id\":\"completion-1\",\"choices\":[{\"index\":0,\"delta\":{}},{\"index\":1,\"delta\":{}}]}", .err = error.UnsupportedChoiceCount },
        .{ .chunk = "{\"id\":\"completion-1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"system\"}}]}", .err = error.InvalidRole },
        .{ .chunk = "{\"id\":\"completion-1\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"function_call\"}]}", .err = error.UnsupportedFinishReason },
    };
    for (cases) |case| {
        const wire = try stream(&.{case.chunk}, false);
        defer test_a.free(wire);
        var decoder = try Decoder.init(test_a, .{});
        defer decoder.deinit();
        try std.testing.expectError(case.err, decoder.feed(wire));
        try std.testing.expectError(error.DecoderFailed, decoder.finish());
    }
    var identity = try Decoder.init(test_a, .{});
    defer identity.deinit();
    const wire = try stream(&.{ text_chunk, "{\"id\":\"another\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}" }, true);
    defer test_a.free(wire);
    try std.testing.expectError(error.ConflictingCompletionId, identity.feed(wire));
    var provider_error = try Decoder.init(test_a, .{});
    defer provider_error.deinit();
    try std.testing.expectError(error.ProviderError, provider_error.feed("event: error\ndata: {}\n\n"));
}

test "event, response, argument, and tool limits reject before any reply is available" {
    var event_limit = try Decoder.init(test_a, .{ .max_event_bytes = 8 });
    defer event_limit.deinit();
    try std.testing.expectError(error.EventTooLarge, event_limit.feed("data: 123456"));
    var response_limit = try Decoder.init(test_a, .{ .max_response_bytes = 8 });
    defer response_limit.deinit();
    try std.testing.expectError(error.ResponseTooLarge, response_limit.feed("123456789"));
    const wire = try stream(&.{ tools_first, tools_last }, true);
    defer test_a.free(wire);
    var tool_limit = try Decoder.init(test_a, .{ .max_tools = 1 });
    defer tool_limit.deinit();
    try std.testing.expectError(error.ToolLimitExceeded, tool_limit.feed(wire));
    var argument_limit = try Decoder.init(test_a, .{ .max_arguments_bytes = 4 });
    defer argument_limit.deinit();
    try std.testing.expectError(error.ArgumentsTooLarge, argument_limit.feed(wire));
    try std.testing.expectError(error.DecoderFailed, argument_limit.finish());
    const first = try stream(&.{tools_first}, false);
    defer test_a.free(first);
    const last = try stream(&.{tools_last}, true);
    defer test_a.free(last);
    var fragmented_arguments = try Decoder.init(test_a, .{ .max_arguments_bytes = 12 });
    defer fragmented_arguments.deinit();
    try fragmented_arguments.feed(first);
    try std.testing.expectError(error.ArgumentsTooLarge, fragmented_arguments.feed(last));
    try std.testing.expectError(error.DecoderFailed, fragmented_arguments.finish());
    try std.testing.expectError(error.InvalidLimits, Decoder.init(test_a, .{ .max_tools = 1025 }));
    try std.testing.expectError(error.InvalidLimits, Decoder.init(test_a, .{ .max_event_bytes = 0 }));
}

test "reasoning aliases are separate from content and cannot silently double or invent tools" {
    const chunk =
        \\{"id":"completion-1","choices":[{"index":0,"delta":{"reasoning":"inspect({})","reasoning_content":"inspect({})","content":"No tool was requested."},"finish_reason":"stop"}]}
    ;
    const wire = try stream(&.{chunk}, true);
    defer test_a.free(wire);
    var decoder = try Decoder.init(test_a, .{});
    defer decoder.deinit();
    try decoder.feed(wire);
    var reply = try decoder.finish();
    defer reply.deinit();
    try std.testing.expectEqualStrings("inspect({})", reply.reasoning);
    try std.testing.expectEqualStrings("No tool was requested.", reply.content);
    try std.testing.expectEqual(@as(usize, 0), reply.tools.len);
}

test "optional function type and repeated stable tool metadata remain compatible" {
    const first =
        \\{"id":"completion-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call","function":{"name":"inspect","arguments":"{"}}]},"finish_reason":null}]}
    ;
    const last =
        \\{"id":"completion-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call","function":{"name":"inspect","arguments":"}"}}]},"finish_reason":"tool_calls"}]}
    ;
    const wire = try stream(&.{ first, last }, true);
    defer test_a.free(wire);
    var decoder = try Decoder.init(test_a, .{});
    defer decoder.deinit();
    try decoder.feed(wire);
    var reply = try decoder.finish();
    defer reply.deinit();
    try std.testing.expectEqual(@as(usize, 1), reply.tools.len);
    try std.testing.expectEqualStrings("call", reply.tools[0].id);
    try std.testing.expectEqualStrings("inspect", reply.tools[0].name);
    try std.testing.expectEqualStrings("{}", reply.tools[0].arguments);
}

test "usage, finish ordering, and conflicting tool metadata reject ambiguous streams" {
    const cases = [_]struct { chunks: []const []const u8, err: anyerror }{
        .{ .chunks = &.{ stop_chunk, stop_chunk }, .err = error.DataAfterFinish },
        .{ .chunks = &.{"{\"id\":\"completion-1\",\"choices\":[],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}"}, .err = error.InvalidUsageOrder },
        .{ .chunks = &.{ stop_chunk, "{\"id\":\"completion-1\",\"choices\":[],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":3}}" }, .err = error.InvalidUsage },
        .{ .chunks = &.{ stop_chunk, "{\"id\":\"completion-1\",\"choices\":[],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"prompt_tokens_details\":{\"cached_tokens\":2}}}" }, .err = error.InvalidUsage },
        .{ .chunks = &.{ stop_chunk, "{\"id\":\"completion-1\",\"choices\":[],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"completion_tokens_details\":{\"reasoning_tokens\":2}}}" }, .err = error.InvalidUsage },
        .{ .chunks = &.{ stop_chunk, "{\"id\":\"completion-1\",\"choices\":[],\"usage\":{\"prompt_tokens\":-1,\"completion_tokens\":1}}" }, .err = error.InvalidInteger },
        .{ .chunks = &.{ stop_chunk, "{\"id\":\"completion-1\",\"choices\":[],\"usage\":{\"prompt_tokens\":\"1\",\"completion_tokens\":1}}" }, .err = error.InvalidInteger },
        .{ .chunks = &.{ stop_chunk, "{\"id\":\"completion-1\",\"choices\":[],\"usage\":{\"prompt_tokens\":18446744073709551615,\"completion_tokens\":1}}" }, .err = error.InvalidUsage },
        .{ .chunks = &.{ stop_chunk, "{\"id\":\"completion-1\",\"choices\":[],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}", "{\"id\":\"completion-1\",\"choices\":[],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}" }, .err = error.DuplicateUsage },
        .{ .chunks = &.{"{\"id\":\"completion-1\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"type\":\"custom\"}]}}]}"}, .err = error.UnsupportedToolType },
        .{ .chunks = &.{"{\"id\":\"completion-1\",\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"one\",\"reasoning_content\":\"different\"}}]}"}, .err = error.ConflictingReasoning },
        .{ .chunks = &.{ tools_first, "{\"id\":\"completion-1\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"changed\"}]}}]}" }, .err = error.ConflictingToolCall },
        .{ .chunks = &.{ tools_first, "{\"id\":\"completion-1\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"patch\"}}]}}]}" }, .err = error.ConflictingToolCall },
    };
    for (cases) |case| {
        const wire = try stream(case.chunks, false);
        defer test_a.free(wire);
        var decoder = try Decoder.init(test_a, .{});
        defer decoder.deinit();
        try std.testing.expectError(case.err, decoder.feed(wire));
        try std.testing.expectError(error.DecoderFailed, decoder.finish());
    }
}

fn allocationFailureFixture(allocator: Allocator) !void {
    var decoder = try Decoder.init(allocator, .{});
    defer decoder.deinit();
    try decoder.feed("data: " ++ tools_first ++ "\n\ndata: " ++ tools_last ++ "\n\ndata: [DONE]\n\n");
    var reply = try decoder.finish();
    defer reply.deinit();
    try std.testing.expectEqual(@as(usize, 2), reply.tools.len);
}

test "every allocation failure cleans decoder and transferred reply ownership" {
    try std.testing.checkAllAllocationFailures(test_a, allocationFailureFixture, .{});
}
